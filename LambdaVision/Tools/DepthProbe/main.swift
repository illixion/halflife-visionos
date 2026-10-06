// Depth probe: runs the app's own composite shaders (Shaders.metal) on Mac
// engine dumps (vrdumpN.bin, r_vrdump N): the reprojection depth
// (fragmentShaderDepth, reprojectionDepthMerge), checked against the dump's
// own matrices, and the glass reflection (glassShade) on dumps that carry the
// engine's stencil and glass plane table (version 3, taken with r_vrglass 1),
// lit by environment probes (vrprobeN.bin, r_vrprobedump N).
//
// For every pixel the composite turns the engine's GL window depth into the
// compositor's reverse-Z depth. Unprojecting that through the compositor
// projection must land on the same eye-space point as unprojecting the GL
// depth through the engine's projection. Checked for an infinite and a
// finite-far reverse-Z projection (the layer's real depth range is only known
// on device), and the probe reports how many pixels took the far fallback or
// the flat-viewmodel cut-off. Then the merge: a square of overlay depth must
// replace the drawable's depth inside it and leave it alone outside.
//
// Glass, with the first probe given as the current one:
// - probe view: each probe looked up along every pixel's own view ray
//   (glassProbeView) must reproduce the engine image on static surfaces —
//   checks the face layout, the depth decode and, for a probe captured away
//   from the eye, that the parallax walk beats the plain direction lookup;
// - mask: only pixels the engine marked change, and some do;
// - gaze: dumps from the same origin (different yaw) must show the same
//   reflection at the same glass point;
// - stereo: dumps from origins an eye apart are compared the same way, and
//   both must take every glass pixel's reflection from the probe.
// With --png DIR it writes glass-<dump>.png (plain | glass over the
// reflection alone | the mask) for a look.
//
//   ./build.sh [--png DIR] vrdump1.bin [vrdump2.bin ...] [vrprobe1.bin ...]
//
// Exits non-zero on any mismatch.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

let inchesPerMetre: Float = 39.37

struct Dump {
    var width = 0, height = 0
    var projection = float4x4()
    var rgba = Data()
    var depth = [Float]()
    var stencil: [UInt8]?   // version 2 dumps (r_vrglass codes), bottom-up rows
    var origin = SIMD3<Float>(), angles = SIMD3<Float>()
    var planes: [SIMD4<Float>]? // version 3: the glass plane table the codes index
    var kinds: [UInt8] = []     // version 4: each row's kind (0 glass, 1 water)

    init(path: String) throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        func ints(_ at: Int, _ n: Int) -> [Int32] {
            d.subdata(in: at..<at + 4 * n).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        }
        func floats(_ at: Int, _ n: Int) -> [Float] {
            d.subdata(in: at..<at + 4 * n).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let header = ints(0, 4)
        guard header[0] == 0x4452_5656 else { throw NSError(domain: "not a vrdump", code: 1) }
        width = Int(header[2]); height = Int(header[3])
        let a = floats(16, 16)
        projection = float4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                                        SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
        rgba = d.subdata(in: 168..<168 + width * height * 4)
        depth = floats(168 + width * height * 4, width * height)   // bottom-up rows
        let stencilAt = 168 + width * height * 8
        if header[1] >= 2, d.count >= stencilAt + width * height {
            stencil = [UInt8](d.subdata(in: stencilAt..<stencilAt + width * height))
        }
        let o = floats(144, 6)
        origin = SIMD3(o[0], o[1], o[2]); angles = SIMD3(o[3], o[4], o[5])
        let tableAt = stencilAt + width * height
        if header[1] >= 3, d.count >= tableAt + 4 {
            let n = Int(ints(tableAt, 1)[0])
            let f = floats(tableAt + 4, n * 4)
            planes = (0..<n).map { SIMD4(f[$0 * 4], f[$0 * 4 + 1], f[$0 * 4 + 2], f[$0 * 4 + 3]) }
            let kindsAt = tableAt + 4 + n * 16
            if header[1] >= 4, d.count >= kindsAt + n { kinds = [UInt8](d.subdata(in: kindsAt..<kindsAt + n)) }
        }
    }

    /// The engine's AngleVectors: forward, right, up for this view.
    var axes: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) { angleVectors(angles) }
}

func angleVectors(_ a: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
    let r = a * .pi / 180
    let sp = sin(r.x), cp = cos(r.x), sy = sin(r.y), cy = cos(r.y), sr = sin(r.z), cr = cos(r.z)
    return (SIMD3(cp * cy, cp * sy, -sp),
            SIMD3(-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp),
            SIMD3(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp))
}

/// vrprobeN.bin: six faces (+X +Y −X −Y +Z −Z), RGBA8 then float GL depth, bottom-up rows.
struct Probe {
    var size = 0
    var origin = SIMD3<Float>(), clip = SIMD2<Float>()
    var rgba = Data(), depth = [Float]()

    init(path: String) throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        let header = d.subdata(in: 0..<16).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        guard header[0] == 0x5052_5656 else { throw NSError(domain: "not a vrprobe", code: 1) }
        size = Int(header[2])
        let f = d.subdata(in: 16..<36).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        origin = SIMD3(f[0], f[1], f[2]); clip = SIMD2(f[3], f[4])
        let n = size * size * 6
        rgba = d.subdata(in: 36..<36 + n * 4)
        depth = d.subdata(in: 36 + n * 4..<36 + n * 8).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let libraryPath = args.removeFirst()
var pngDir: String?
if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
    pngDir = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
func isProbe(_ path: String) -> Bool {
    guard let h = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? h.close() }
    return h.readData(ofLength: 4) == Data([0x56, 0x56, 0x52, 0x50])   // "VVRP"
}
let probePaths = args.filter(isProbe)
args = args.filter { !isProbe($0) }
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: libraryPath))
let queue = device.makeCommandQueue()!
var failures = 0

func compositePipeline() throws -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "fullscreenVertexShader")
    d.fragmentFunction = try library.makeFunction(name: "fragmentShaderDepth",
                                                  constantValues: MTLFunctionConstantValues())
    d.colorAttachments[0].pixelFormat = .rgba16Float
    d.depthAttachmentPixelFormat = .depth32Float
    return try device.makeRenderPipelineState(descriptor: d)
}

func mergePipeline() throws -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "fullscreenVertexShader")
    d.fragmentFunction = library.makeFunction(name: "reprojectionDepthMerge")
    d.depthAttachmentPixelFormat = .depth32Float
    return try device.makeRenderPipelineState(descriptor: d)
}

func depthState(_ compare: MTLCompareFunction) -> MTLDepthStencilState {
    let d = MTLDepthStencilDescriptor()
    d.depthCompareFunction = compare
    d.isDepthWriteEnabled = true
    return device.makeDepthStencilState(descriptor: d)!
}

/// A depth32Float texture (2D array of one slice when `array`) filled with `values` (top-down rows).
func depthTexture(_ w: Int, _ h: Int, _ values: [Float], array: Bool, renderTarget: Bool = false) -> MTLTexture {
    let td = MTLTextureDescriptor()
    td.textureType = array ? .type2DArray : .type2D
    td.pixelFormat = .depth32Float
    td.width = w; td.height = h
    td.usage = renderTarget ? [.renderTarget, .shaderRead] : [.shaderRead]
    td.storageMode = .private
    let tex = device.makeTexture(descriptor: td)!
    let staging = values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
    let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0,
              destinationLevel: 0, destinationOrigin: MTLOrigin())
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return tex
}

func readDepth(_ tex: MTLTexture) -> [Float] {
    let w = tex.width, h = tex.height
    let buf = device.makeBuffer(length: w * h * 4, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().bindMemory(to: Float.self, capacity: w * h), count: w * h))
}

/// DisplayParams outgrew setFragmentBytes' 4 KB (the glass plane tables).
func paramsBuffer(_ params: DisplayParams) -> MTLBuffer {
    var p = params
    return device.makeBuffer(bytes: &p, length: MemoryLayout<DisplayParams>.stride, options: .storageModeShared)!
}

let composite = try compositePipeline()
let merge = try mergePipeline()

struct Compositor {
    var name: String
    var near: Float, far: Float?   // metres; nil = infinite
    /// Reverse-Z z/w rows (DisplayParams.depthProjection layout).
    var rows: SIMD4<Float> {
        guard let far else { return SIMD4(0, near, -1, 0) }
        return SIMD4(near / (far - near), far * near / (far - near), -1, 0)
    }
    /// Distance along −z back from a reverse-Z depth.
    func distance(_ depth: Float) -> Float {
        guard let far else { return near / depth }
        return far * near / (depth * (far - near) + near)
    }
}

for path in args {
    let dump = try Dump(path: path)
    let w = dump.width, h = dump.height
    // Engine near/far from the dump's GL projection: P22 = −(f+n)/(f−n), P32 = −2fn/(f−n).
    let p22 = dump.projection.columns.2.z, p32 = dump.projection.columns.3.z
    let n = p32 / (p22 - 1) / inchesPerMetre, f = p32 / (p22 + 1) / inchesPerMetre
    let invP = dump.projection.inverse
    print("\((path as NSString).lastPathComponent): \(w)x\(h), engine near \(n) m far \(f) m")

    let colorDesc = MTLTextureDescriptor()
    colorDesc.textureType = .type2DArray
    colorDesc.pixelFormat = .rgba16Unorm
    colorDesc.width = w; colorDesc.height = h
    colorDesc.usage = .shaderRead
    let color = device.makeTexture(descriptor: colorDesc)!   // contents irrelevant here
    let engineDepth = depthTexture(w, h, dump.depth, array: true)

    for compositor in [Compositor(name: "infinite, near 0.1 m", near: 0.1, far: nil),
                       Compositor(name: "finite, 0.1–100 m", near: 0.1, far: 100)] {
        var params = DisplayParams()
        params.decodeGamma = 2.2
        params.engineClip = SIMD4(2 * n * f, f + n, f - n, 0)
        params.depthProjection = (compositor.rows, compositor.rows)
        params.depthLimits = SIMD4(0.0001, 1, 0.16, 0)

        let rtd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        rtd.usage = .renderTarget; rtd.storageMode = .private
        let target = device.makeTexture(descriptor: rtd)!
        let out = depthTexture(w, h, [Float](repeating: 0, count: w * h), array: false, renderTarget: true)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .dontCare
        rpd.depthAttachment.texture = out
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 0
        rpd.depthAttachment.storeAction = .store
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(composite)
        enc.setDepthStencilState(depthState(.greater))
        enc.setFragmentBuffer(paramsBuffer(params), offset: 0, index: BufferIndex.uniforms.rawValue)
        enc.setFragmentTexture(color, index: TextureIndex.color.rawValue)
        enc.setFragmentTexture(engineDepth, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let result = readDepth(out)

        var worst: Float = 0, far = 0, viewmodel = 0, belowRange = 0, checked = 0
        var histogram = [Int](repeating: 0, count: 6)   // <0.5, <1, <2, <5, <20, ≥20 m
        for row in 0..<h {
            for col in 0..<w {
                let d = result[row * w + col]
                // Output row 0 is the top; the dump's rows run bottom-up.
                let gl = dump.depth[(h - 1 - row) * w + col]
                let ndcX = (Float(col) + 0.5) / Float(w) * 2 - 1
                let ndcY = 1 - (Float(row) + 0.5) / Float(h) * 2
                let v = invP * SIMD4(ndcX, ndcY, gl * 2 - 1, 1)
                let expected = -(v.z / v.w) / inchesPerMetre      // metres along the forward axis
                if d <= 0 || d > 1 { belowRange += 1; continue }
                if expected < 0.16 { viewmodel += 1; if d != 0.0001 { failures += 1 }; continue }
                if d == 0.0001 { far += 1; continue }
                let got = compositor.distance(d)
                worst = max(worst, abs(got - expected) / expected)
                checked += 1
                let bucket = expected < 0.5 ? 0 : expected < 1 ? 1 : expected < 2 ? 2 : expected < 5 ? 3 : expected < 20 ? 4 : 5
                histogram[bucket] += 1
            }
        }
        let total = Float(w * h)
        print(String(format: "  %@: worst relative distance error %.2e over %d px; far %.1f%%, viewmodel cut-off %.1f%%, out of range %d",
                     compositor.name, worst, checked, Float(far) / total * 100, Float(viewmodel) / total * 100, belowRange))
        print("    distances <0.5 / <1 / <2 / <5 / <20 / ≥20 m: \(histogram.map { String(format: "%.1f%%", Float($0) / total * 100) }.joined(separator: " / "))")
        if worst > 1e-3 || belowRange > 0 { failures += 1 }
    }
}

// Glass: the composite with and without glassShade, lit by the probes given.
func glassPipeline(_ glass: Bool, fragment: String = "fragmentShader") throws -> MTLRenderPipelineState {
    let constants = MTLFunctionConstantValues()
    var srgb = false, lsb: Float = 0, on = glass
    constants.setConstantValue(&srgb, type: .bool, index: 20)
    constants.setConstantValue(&lsb, type: .float, index: 21)
    constants.setConstantValue(&on, type: .bool, index: 22)
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "fullscreenVertexShader")
    d.fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
    d.colorAttachments[0].pixelFormat = .rgba8Unorm
    return try device.makeRenderPipelineState(descriptor: d)
}

func writePNG(_ rgba: [UInt8], _ w: Int, _ h: Int, _ path: String) {
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func array2D(_ format: MTLPixelFormat, _ w: Int, _ h: Int, slices: Int, _ bytes: UnsafeRawPointer, _ bpp: Int) -> MTLTexture {
    let td = MTLTextureDescriptor()
    td.textureType = .type2DArray
    td.pixelFormat = format
    td.width = w; td.height = h; td.arrayLength = slices
    td.usage = .shaderRead
    td.storageMode = format == .depth32Float ? .private : .shared
    let t = device.makeTexture(descriptor: td)!
    if format == .depth32Float {
        let staging = device.makeBuffer(bytes: bytes, length: w * h * bpp * slices)!
        let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
        for i in 0..<slices {
            blit.copy(from: staging, sourceOffset: w * h * bpp * i, sourceBytesPerRow: w * bpp,
                      sourceBytesPerImage: w * h * bpp, sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: t, destinationSlice: i, destinationLevel: 0, destinationOrigin: MTLOrigin())
        }
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    } else {
        for i in 0..<slices {
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: i,
                      withBytes: bytes + w * h * bpp * i, bytesPerRow: w * bpp, bytesPerImage: w * h * bpp)
        }
    }
    return t
}

/// Writes a dump's view and plane table into both eyes' glass fields (the
/// probe renders one eye at a time).
func setGlassView(_ params: inout DisplayParams, _ dump: Dump) {
    let (f, r, u) = dump.axes
    let view: [SIMD4<Float>] = [SIMD4(dump.origin, 0), SIMD4(f, 0), SIMD4(r, 0), SIMD4(u, 0)]
    let planes = dump.planes ?? []
    withUnsafeMutableBytes(of: &params) { raw in
        let eyeAt = MemoryLayout<DisplayParams>.offset(of: \DisplayParams.glassEye)!
        let planesAt = MemoryLayout<DisplayParams>.offset(of: \DisplayParams.glassPlanes)!
        let v = (raw.baseAddress! + eyeAt).bindMemory(to: SIMD4<Float>.self, capacity: 8)
        let pl = (raw.baseAddress! + planesAt).bindMemory(to: SIMD4<Float>.self, capacity: 448)
        for eye in 0..<2 {
            for i in 0..<4 { v[eye * 4 + i] = view[i] }
            for (i, p) in planes.prefix(224).enumerated() { pl[eye * 224 + i] = p }
        }
        let kindsAt = MemoryLayout<DisplayParams>.offset(of: \DisplayParams.glassKinds)!
        let words = (raw.baseAddress! + kindsAt).bindMemory(to: UInt32.self, capacity: 16)
        for i in 0..<16 { words[i] = 0 }
        for (row, k) in dump.kinds.prefix(224).enumerated() where k == 1 {
            words[row >> 5] |= 1 << UInt32(row & 31)
            words[8 + (row >> 5)] |= 1 << UInt32(row & 31)
        }
    }
    let p = dump.projection   // tangents from the GL projection (DrawableProjection's formula)
    let t = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                  (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    params.eyeTangents = (t, t)
}

/// A probe's textures: colour (rgba8, sampled as half like the app's) and depth, six slices.
struct ProbeTextures {
    let probe: Probe, color: MTLTexture, depth: MTLTexture
    init(_ probe: Probe) {
        self.probe = probe
        let s = probe.size
        color = probe.rgba.withUnsafeBytes { array2D(.rgba8Unorm, s, s, slices: 6, $0.baseAddress!, 4) }
        depth = probe.depth.withUnsafeBytes { array2D(.depth32Float, s, s, slices: 6, $0.baseAddress!, 4) }
    }
    func use(_ params: inout DisplayParams, iterations: Float = 0) {
        params.probe = (SIMD4(0, 0, 0, -1), SIMD4(probe.origin, 0))
        params.probeMix = SIMD4(1, probe.clip.x, probe.clip.y, iterations)
    }
}

func render(_ pipeline: MTLRenderPipelineState, _ w: Int, _ h: Int, _ params: DisplayParams,
            _ textures: [Int: MTLTexture]) -> [UInt8] {
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    td.usage = .renderTarget
    let target = device.makeTexture(descriptor: td)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = target
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentBuffer(paramsBuffer(params), offset: 0, index: BufferIndex.uniforms.rawValue)
    for (i, t) in textures { enc.setFragmentTexture(t, index: i) }
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var out = [UInt8](repeating: 0, count: w * h * 4)
    target.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return out
}

let probes = try probePaths.map { ProbeTextures(try Probe(path: $0)) }
let plainPipeline = try glassPipeline(false)
let glassOnPipeline = try glassPipeline(true)
let probeViewPipeline = try glassPipeline(false, fragment: "glassProbeView")
// Sharp water (ssprProject + ssprResolve): the app's two dispatches, one eye.
let sharpProject = try device.makeComputePipelineState(function: library.makeFunction(name: "ssprProject")!)
let sharpResolve = try device.makeComputePipelineState(function: library.makeFunction(name: "ssprResolve")!)
let sharpPrefilter = library.makeFunction(name: "ssprPrefilter").flatMap { try? device.makeComputePipelineState(function: $0) }
let sharp = ProcessInfo.processInfo.environment["SHARP"] != "0"

/// The highest horizontal water row below the eye (SharpWater.planes).
func sharpPlane(_ dump: Dump) -> SIMD4<Float> {
    guard let planes = dump.planes else { return .zero }
    var best: (Int, Float)?
    for (row, p) in planes.enumerated() where row < dump.kinds.count && dump.kinds[row] == 1 && p.z > 0.99 {
        let height = p.w / p.z
        if height < dump.origin.z - 1, height > (best?.1 ?? -.infinity) { best = (row, height) }
    }
    guard let best else { return .zero }
    return SIMD4(Float(best.0), best.1, 1, 0)
}

/// The resolve's per-sub-ray record of the last renderSharp (build.sh compiles
/// the shaders with SSPR_DEBUG): the mirrored path length each sub-ray shows,
/// and its confidence (0 where it shows nothing).
var lastSharpDebug: MTLBuffer?

/// The mirror target (one slice, shared for read-back), as the app makes it.
func renderSharp(_ params: DisplayParams, _ color: MTLTexture, _ engineDepth: MTLTexture,
                 _ stencil: MTLTexture) -> MTLTexture {
    let div = params.sspr.0.w > 0.5 ? Int(params.sspr.0.w) : 4
    let w = (color.width + div - 1) / div, h = (color.height + div - 1) / div
    let d = MTLTextureDescriptor()
    d.textureType = .type2DArray
    d.pixelFormat = .rgba16Float
    d.width = w; d.height = h
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .shared
    let out = device.makeTexture(descriptor: d)!
    let keys = device.makeBuffer(bytes: [UInt32](repeating: .max, count: w * h * 2), length: w * h * 8)!
    let debug = device.makeBuffer(length: w * h * 2 * 4 * 8, options: .storageModeShared)!
    lastSharpDebug = debug
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    let pb = paramsBuffer(params)
    enc.setBuffer(pb, offset: 0, index: BufferIndex.uniforms.rawValue)
    enc.setBuffer(keys, offset: 0, index: 0)
    enc.setTexture(color, index: 0)
    enc.setTexture(engineDepth, index: 1)
    enc.setTexture(out, index: 2)
    enc.setTexture(stencil, index: 3)
    if let sharpPrefilter {                              // older shaders have none
        let pd = MTLTextureDescriptor()
        pd.textureType = .type2DArray
        pd.pixelFormat = .rgba16Float
        pd.width = (color.width + 1) / 2; pd.height = (color.height + 1) / 2
        pd.usage = [.shaderRead, .shaderWrite]
        let pre = device.makeTexture(descriptor: pd)!
        enc.setTexture(pre, index: 4)
        enc.setComputePipelineState(sharpPrefilter)
        enc.dispatchThreads(MTLSize(width: pd.width, height: pd.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        enc.memoryBarrier(scope: .textures)
    }
    let grid = MTLSize(width: w, height: h, depth: 1), group = MTLSize(width: 16, height: 8, depth: 1)
    enc.setComputePipelineState(sharpProject)
    enc.dispatchThreads(grid, threadsPerThreadgroup: group)
    enc.memoryBarrier(scope: .buffers)
    enc.setComputePipelineState(sharpResolve)
    enc.setBuffer(debug, offset: 0, index: 5)
    enc.dispatchThreads(grid, threadsPerThreadgroup: group)
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if let path = ProcessInfo.processInfo.environment["SSPR_KEYS"], !FileManager.default.fileExists(atPath: "\(path).\(w)x\(h).keys") {   // the key buffer, for offline digging
        try? Data(bytes: keys.contents(), count: w * h * 4).write(to: URL(fileURLWithPath: "\(path).\(w)x\(h).keys"))
        try? Data(bytes: debug.contents(), count: w * h * 32).write(to: URL(fileURLWithPath: "\(path).\(w)x\(h).dbg"))
    }
    return out
}

/// "Transparent underside" (the headset, a table standing in the c1a2 flood):
/// the mirror showing the room behind an object where the reflection must
/// show the object's underside, which is never on screen. Ground truth is a
/// fine trace of each sub-ray's reflected ray through the engine's depth,
/// with every visible surface taken as a slab `thickness` units deep below
/// it: the ray "meets a hidden underside" where it passes behind a surface
/// with that surface less than `thickness` above it (climbing to it, the
/// visible depth must stay continuous, so the region a table's edge hides
/// behind it does not count). Of those sub-rays, the
/// share (weighted by the mirror's confidence) whose shown surface (the
/// resolve's SSPR_DEBUG record) is clearly farther along the ray than that
/// hit is the leak. Rays that meet a visible surface first, or leave the
/// frame, are not counted: the mirror may show them or fall to the probe.
func seeThrough(_ dump: Dump, _ plane: SIMD4<Float>, _ mw: Int, _ mh: Int, _ dbg: MTLBuffer,
                thickness: Float = 4) -> (occluded: Int, share: Float, leak: Float, leakTable: Float, image: [UInt8]) {
    let w = dump.width, h = dump.height
    guard let stencil = dump.stencil else { return (0, 0, 0, 0, []) }
    let (f, r, u) = dump.axes
    let p = dump.projection
    let t = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                  (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    let p22 = p.columns.2.z, p32 = p.columns.3.z
    let near = p32 / (p22 - 1), far = p32 / (p22 + 1)
    let E = dump.origin, height = plane.y, waterCode = UInt8(Int(plane.x) + 16)
    let rec = dbg.contents().bindMemory(to: SIMD2<Float>.self, capacity: mw * mh * 4)
    func ray(_ uv: SIMD2<Float>) -> SIMD3<Float> {
        simd_normalize(f + (-t.x + (t.x + t.y) * uv.x) * r + (-t.w + (t.z + t.w) * uv.y) * u)
    }
    func project(_ X: SIMD3<Float>) -> (SIMD2<Float>, Float)? {
        let q = X - E, qz = simd_dot(q, f)
        guard qz > 4 else { return nil }
        let uv = SIMD2((simd_dot(q, r) / qz + t.x) / (t.x + t.y), (simd_dot(q, u) / qz + t.w) / (t.z + t.w))
        guard uv.x >= 0, uv.x < 1, uv.y >= 0, uv.y < 1 else { return nil }
        return (uv, qz)
    }
    func visible(_ uv: SIMD2<Float>) -> (z: Float, V: SIMD3<Float>) {
        let i = min(Int(uv.y * Float(h)), h - 1) * w + min(Int(uv.x * Float(w)), w - 1)
        let ndc = dump.depth[i] * 2 - 1
        let z = 2 * near * far / ((far + near) - ndc * (far - near))
        let d = ray(uv)
        return (z, E + d * (z / simd_dot(d, f)))
    }
    var occluded = 0, water = 0
    var leak: Float = 0, leakNear: Float = 0, occNear = 0
    var image = [UInt8](repeating: 0, count: mw * mh * 4)
    for gy in 0..<mh {
        for gx in 0..<mw {
            var texelLeak: Float = 0, texelOcc = false
            for sj in 0..<2 { for si in 0..<2 {
                let uv = SIMD2((Float(gx) + (Float(si) + 0.5) / 2) / Float(mw), (Float(gy) + (Float(sj) + 0.5) / 2) / Float(mh))
                let si0 = min(Int(uv.y * Float(h)), h - 1) * w + min(Int(uv.x * Float(w)), w - 1)
                guard stencil[si0] == waterCode else { continue }
                var d = ray(uv)
                if d.z > -1e-4 { d.z = -1e-4 }
                let P = E + d * ((height - E.z) / d.z)
                let rr = SIMD3(d.x, d.y, -d.z)
                let base = simd_length(P - E)
                water += 1
                var s: Float = 0.5, hit: Float = -1
                while s < 4000 {
                    let X = P + rr * s
                    guard let (xs, qz) = project(X) else { break }
                    let (zv, V) = visible(xs)
                    let tol = 0.5 + 0.005 * zv
                    if V.z > height + 1 {
                        if abs(qz - zv) <= tol { break }                       // a visible surface
                        // under a surface: X behind it, and climbing from X
                        // within `thickness` reaches a point in front of or
                        // on it, the visible depth continuous across that
                        // step (the same surface, not the room past its edge)
                        if qz > zv + tol {
                            var lastZ = zv, inside = false
                            for j in 1...4 {
                                guard let (ys, qy) = project(X + SIMD3(0, 0, thickness * Float(j) / 4)) else { break }
                                let zy = visible(ys).z
                                if abs(zy - lastZ) > 8 + 0.05 * zv { break }
                                if qy <= zy + tol { inside = true; break }
                                lastZ = zy
                            }
                            if inside { hit = base + s; break }
                        }
                    }
                    s += max(0.5, 0.005 * (base + s))
                }
                guard hit > 0 else { continue }
                occluded += 1; texelOcc = true
                let k = (gy * mw + gx) * 4 + sj * 2 + si
                let shown = rec[k]
                let bad = shown.y > 0 && shown.x > hit * 1.05 + 8 ? shown.y : 0
                leak += bad; texelLeak += bad
                if hit - base < 120 { occNear += 1; leakNear += bad }
            } }
            // top-down: red = leak, dark blue = hidden underside handled
            let o = ((mh - 1 - gy) * mw + gx) * 4
            image[o] = UInt8(min(texelLeak / 4 * 255, 255)); image[o + 2] = texelOcc ? 90 : 0; image[o + 3] = 255
        }
    }
    return (occluded, Float(occluded) / Float(max(water, 1)), leak / Float(max(occluded, 1)),
            leakNear / Float(max(occNear, 1)), image)
}

/// Mac GPU time of the two mirror dispatches (SSPR_TIMING=1): per dispatch,
/// the fastest of 10 command buffers of 50 dispatches each. Only the ratio between two
/// versions carries over to the headset.
func timeSharp(_ params: DisplayParams, _ color: MTLTexture, _ engineDepth: MTLTexture, _ stencil: MTLTexture) -> (Double, Double) {
    let div = params.sspr.0.w > 0.5 ? Int(params.sspr.0.w) : 4
    let w = (color.width + div - 1) / div, h = (color.height + div - 1) / div
    let d = MTLTextureDescriptor()
    d.textureType = .type2DArray; d.pixelFormat = .rgba16Float; d.width = w; d.height = h
    d.usage = [.shaderRead, .shaderWrite]
    let out = device.makeTexture(descriptor: d)!
    let keys = device.makeBuffer(length: w * h * 8)!
    let debug = device.makeBuffer(length: w * h * 2 * 4 * 8)!
    let pb = paramsBuffer(params)
    let grid = MTLSize(width: w, height: h, depth: 1), group = MTLSize(width: 16, height: 8, depth: 1)
    var tp: [Double] = [], tr: [Double] = []
    memset(keys.contents(), 0xFF, w * h * 8)
    for run in 0..<12 {
        for (pipe, sink) in [(sharpProject, 0), (sharpResolve, 1)] {
            let cb = queue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setBuffer(pb, offset: 0, index: BufferIndex.uniforms.rawValue)
            enc.setBuffer(keys, offset: 0, index: 0)
            enc.setBuffer(debug, offset: 0, index: 5)
            enc.setTexture(color, index: 0); enc.setTexture(engineDepth, index: 1)
            enc.setTexture(out, index: 2); enc.setTexture(stencil, index: 3)
            enc.setComputePipelineState(pipe)
            // 50 back to back (the projection's atomic min and the resolve
            // are idempotent), so the GPU's clock ramp and the command
            // buffer's overhead wash out
            for _ in 0..<50 { enc.dispatchThreads(grid, threadsPerThreadgroup: group) }
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000 / 50
            if run < 2 { continue }
            if sink == 0 { tp.append(ms) } else { tr.append(ms) }
        }
    }
    return (tp.min()!, tr.min()!)
}

struct GlassView {
    let name: String, dump: Dump, glass: [UInt8], env: [UInt8], envFlat: [UInt8]
    var sharp: (w: Int, h: Int, rgba: [Float16], plane: SIMD4<Float>)?
}
var glassViews: [GlassView] = []

for path in args {
    let dump = try Dump(path: path)
    guard let stencil = dump.stencil, dump.planes != nil, let current = probes.first else { continue }
    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let w = dump.width, h = dump.height
    let color = dump.rgba.withUnsafeBytes { array2D(.rgba8Unorm, w, h, slices: 1, $0.baseAddress!, 4) }
    let stencilTex = stencil.withUnsafeBytes { array2D(.r8Uint, w, h, slices: 1, $0.baseAddress!, 1) }
    var params = DisplayParams()
    params.glass = SIMD4(3, 0.04, 0.7, 0.35)           // the app's defaults (Renderer)
    params.water = SIMD4(1.8, 0.02, 0.85, Float(ProcessInfo.processInfo.environment["RIPPLE"] ?? "") ?? 0.008)
    params.reflectExtra = SIMD4(0.06, 0.04, 12.5, 1)  // a fixed moment of the ripples
    params.glassAmbient = SIMD4(1, 0, 1, 0)          // magenta: shows any pixel the probe missed
    params.glassTint = SIMD4(0.80, 0.90, 0.88, 0.35)   // w: the room's light (luma)
    setGlassView(&params, dump)

    // Probe view: each probe along the eye's own rays, on static world pixels
    // (not glass, not the flat viewmodel, which decodes nearer than 6 units).
    let p22 = dump.projection.columns.2.z, p32 = dump.projection.columns.3.z
    let near = p32 / (p22 - 1), far = p32 / (p22 + 1)
    for probe in probes {
        let offset = simd_length(probe.probe.origin - dump.origin)
        var errors: [Float] = []
        for iterations: Float in [0, 3] {
            var pp = params
            probe.use(&pp, iterations: iterations)
            let out = render(probeViewPipeline, w, h, pp, [3: probe.color, 4: probe.depth])
            var sum = 0, n = 0
            for row in stride(from: 0, to: h, by: 2) {
                for col in stride(from: 0, to: w, by: 2) {
                    let src = (h - 1 - row) * w + col
                    let code = stencil[src]
                    let ndc = dump.depth[src] * 2 - 1
                    let dist = 2 * near * far / ((far + near) - ndc * (far - near))
                    if (code >= 16 && code <= 239) || dist < 6 || dump.depth[src] >= 1 { continue }
                    let i = (row * w + col) * 4, j = src * 4
                    sum += (0..<3).reduce(0) { $0 + abs(Int(out[i + $1]) - Int(dump.rgba[j + $1])) }
                    n += 1
                }
            }
            errors.append(Float(sum) / Float(max(n * 3, 1)))
        }
        print(String(format: "%@ probe view, probe %.0f units from the eye: mean error %.1f/255 plain, %.1f/255 parallax-corrected",
                     name, offset, errors[0], errors[1]))
        // At the eye both lookups must match the image to within the probe's
        // resolution; away from it the parallax walk must do clearly better.
        if offset < 1 ? errors[1] > 12 : errors[1] > errors[0] * 0.8 { failures += 1 }
    }

    current.use(&params, iterations: 3)
    let engineDepthTex = depthTexture(w, h, dump.depth, array: true)
    var textures: [Int: MTLTexture] = [TextureIndex.color.rawValue: color, 1: engineDepthTex, 2: stencilTex,
                                       3: current.color, 4: current.depth]
    var sharpRead: (w: Int, h: Int, rgba: [Float16], plane: SIMD4<Float>)?
    if sharp {
        var plane = sharpPlane(dump)
        plane.w = Float(ProcessInfo.processInfo.environment["SSPRDIV"] ?? "") ?? 0
        params.sspr = (plane, plane)
        if plane.z > 0 {
            let t = renderSharp(params, color, engineDepthTex, stencilTex)
            textures[5] = t
            var px = [Float16](repeating: 0, count: t.width * t.height * 4)
            t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
            sharpRead = (t.width, t.height, px, plane)
            print(String(format: "%@ sharp water: plane row %.0f at z %.1f", name, plane.x, plane.y))
            if ProcessInfo.processInfo.environment["SSPR_TIMING"] == "1" {
                let (tp, tr) = timeSharp(params, color, engineDepthTex, stencilTex)
                print(String(format: "%@ sharp timing (Mac GPU): project %.3f ms, resolve %.3f ms", name, tp, tr))
            }
            if let dbg = lastSharpDebug {
                let r = seeThrough(dump, plane, t.width, t.height, dbg)
                print(String(format: "%@ see-through: %d sub-rays meet a hidden underside first (%.1f%% of the mirror's water); mirror shows something farther on %.2f%% of them (confidence-weighted), %.2f%% where the hit is within 120 units",
                             name, r.occluded, r.share * 100, r.leak * 100, r.leakTable * 100))
                // b2e7e18 at the c1a2 table (dumps 81–88): 6–18% (fails)
                if r.occluded > 500 && r.leak > 0.03 { failures += 1 }
                if let dir = pngDir { writePNG(r.image, t.width, t.height, "\(dir)/seethrough-\(name).png") }
            }
        }
    }
    let plain = render(plainPipeline, w, h, params, textures)
    let glass = render(glassOnPipeline, w, h, params, textures)

    // Temporal stability: a sub-pixel head turn, emulated by shifting the
    // engine's frame (colour bilinear, depth and stencil nearest) by δ pixels
    // and widening its frustum to match, must move the final image by δ and
    // change nothing else. Thin bright features (the c1a2 vent grate)
    // reflected through an undersampled mirror pop instead. Compared on
    // water pixels away from the mask's edge: the composite of the shifted
    // frame against this one resampled by δ, and the same for the plain
    // composite (the shift's own resampling noise) as the baseline.
    // Hatching: fine horizontal lines on the water (the headset showed them
    // with the ripple on): the mean vertical second difference of the
    // composite over water pixels away from the mask edge, against the same
    // with the ripple off. Aliased or folding ripple raises it.
    if sharp, params.sspr.0.z > 0 {
        func hatching(_ img: [UInt8]) -> Float {
            var sum: Float = 0, n = 0
            for row in stride(from: 3, to: h - 3, by: 1) {
                for x in stride(from: 3, to: w - 3, by: 2) {
                    let sy = h - 1 - row
                    let c = Int(stencil[sy * w + x])
                    guard c == Int(params.sspr.0.x) + 16, Int(stencil[(sy + 3) * w + x]) == c, Int(stencil[(sy - 3) * w + x]) == c else { continue }
                    let i = (row * w + x) * 4
                    for k in 0..<3 {
                        sum += abs(2 * Float(img[i + k]) - Float(img[i - w * 4 + k]) - Float(img[i + w * 4 + k]))
                    }
                    n += 3
                }
            }
            return sum / Float(max(n, 1))
        }
        // where the mirror shows glass or water (the c1a2 sink's water box):
        // each marked pixel's point on its plane, mirrored in the water and
        // projected back, dilated by two pixels
        var mirroredGlass = [Bool](repeating: false, count: w * h)
        if let planes = dump.planes {
            let (f, r, u) = dump.axes
            let p = dump.projection
            let tg = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                           (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
            let height = params.sspr.0.y
            for y in 0..<h {
                for x in 0..<w {
                    let code = Int(stencil[y * w + x])
                    guard code >= 16, code - 16 < planes.count, code - 16 != Int(params.sspr.0.x) else { continue }
                    let pl = planes[code - 16], n = SIMD3(pl.x, pl.y, pl.z)
                    let uu = (Float(x) + 0.5) / Float(w), vv = (Float(y) + 0.5) / Float(h)
                    let d = simd_normalize(f + (-tg.x + (tg.x + tg.y) * uu) * r + (-tg.w + (tg.z + tg.w) * vv) * u)
                    let nd = simd_dot(n, d)
                    guard abs(nd) > 1e-3 else { continue }
                    let P = dump.origin + d * ((pl.w - simd_dot(n, dump.origin)) / nd)
                    guard P.z > height + 1 else { continue }
                    let q = SIMD3(P.x, P.y, 2 * height - P.z) - dump.origin
                    let qz = simd_dot(q, f)
                    guard qz > 4 else { continue }
                    let mx = Int((simd_dot(q, r) / qz + tg.x) / (tg.x + tg.y) * Float(w))
                    let my = Int((simd_dot(q, u) / qz + tg.w) / (tg.z + tg.w) * Float(h))
                    guard mx >= 2, mx < w - 2, my >= 2, my < h - 2 else { continue }
                    for yy in (my - 2)...(my + 2) { for xx in (mx - 2)...(mx + 2) { mirroredGlass[yy * w + xx] = true } }
                }
            }
        }
        // measured on a composite at twice the engine's resolution per axis,
        // as on the headset (the drawable is ~2.3× the engine image at the
        // centre), where the mirror's texels are magnified most
        func hatchingInMirroredGlass(_ img: [UInt8]) -> (Float, Int) {
            let W = w * 2, H = h * 2
            var sum: Float = 0, n = 0
            for row in 6..<(H - 6) {
                for x in 6..<(W - 6) {
                    let sy = h - 1 - row / 2, sx = x / 2
                    guard sy >= 3, sy < h - 3 else { continue }
                    let c = Int(stencil[sy * w + sx])
                    guard mirroredGlass[sy * w + sx], c == Int(params.sspr.0.x) + 16,
                          Int(stencil[(sy + 3) * w + sx]) == c, Int(stencil[(sy - 3) * w + sx]) == c else { continue }
                    let i = (row * W + x) * 4
                    for k in 0..<3 { sum += abs(2 * Float(img[i + k]) - Float(img[i - W * 4 + k]) - Float(img[i + W * 4 + k])) }
                    n += 3
                }
            }
            return (sum / Float(max(n, 1)), n / 3)
        }
        var still = params
        still.water.w = 0
        let calm = hatching(render(glassOnPipeline, w, h, still, textures))
        var rough = params
        rough.water.w *= 3                                  // "Water ripples" 3×
        let at3 = hatching(render(glassOnPipeline, w, h, rough, textures))
        let at1 = hatching(glass)
        print(String(format: "%@ hatching: ripple 0× %.2f, 1× %.2f, 3× %.2f /255", name, calm, at1, at3))
        // d7868d3 at the c1a2 device view: 0× 1.77, 1× 2.10, 3× 3.18 (fails)
        if at1 > calm + 0.2 || at3 > calm + 0.6 { failures += 1 }
        // in the mirrored glass/water, sharp against soft (probe only), both
        // with the ripple off: the mirror must add no fine lines there
        var soft = still
        soft.sspr = (.zero, .zero)
        let (hSharp, nPx) = hatchingInMirroredGlass(render(glassOnPipeline, w * 2, h * 2, still, textures))
        let (hSoft, _) = hatchingInMirroredGlass(render(glassOnPipeline, w * 2, h * 2, soft, textures))
        if let dir = pngDir {
            writePNG(render(glassOnPipeline, w * 2, h * 2, still, textures), w * 2, h * 2, "\(dir)/mirror2x-\(name).png")
        }
        if nPx > 200 {
            print(String(format: "%@ mirrored glass/water: %d px, hatching sharp %.2f vs soft %.2f /255 (ripple off)", name, nPx, hSharp, hSoft))
            if hSharp > hSoft + 0.5 { failures += 1 }
        }
        // the same over all the water the mirror covers, ripple on, at 2×:
        // a comb of rows where a surface the eye barely sees (a face just
        // above the water, the underside of an overhang) must fill many
        // mirror rows
        do {
            let W2 = w * 2, H2 = h * 2
            let sharpImg = render(glassOnPipeline, W2, H2, params, textures)
            var softP = params
            softP.sspr = (.zero, .zero)
            let softImg = render(glassOnPipeline, W2, H2, softP, textures)
            var mirrorAlpha: (Int, Int) -> Float = { _, _ in 0 }
            if let sr = sharpRead {
                mirrorAlpha = { x, sy in        // engine pixel (x, bottom-up row) → mirror alpha
                    let mx = min(x * sr.w / w, sr.w - 1), my = min(sy * sr.h / h, sr.h - 1)
                    return Float(sr.rgba[(my * sr.w + mx) * 4 + 3])
                }
            }
            // per 48 × 48-pixel tile, so a local patch is not averaged away
            let tile = 48, tw = W2 / tile + 1
            func comb(_ img: [UInt8]) -> (Float, Int, [Float], [Int]) {
                var sum: Float = 0, n = 0
                var tSum = [Float](repeating: 0, count: tw * (H2 / tile + 1)), tN = [Int](repeating: 0, count: tSum.count)
                for row in 8..<(H2 - 8) {
                    for x in stride(from: 8, to: W2 - 8, by: 2) {
                        let sy = h - 1 - row / 2, sx = x / 2
                        guard sy >= 4, sy < h - 4 else { continue }
                        let c = Int(stencil[sy * w + sx])
                        guard c == Int(params.sspr.0.x) + 16, Int(stencil[(sy + 4) * w + sx]) == c,
                              Int(stencil[(sy - 4) * w + sx]) == c, mirrorAlpha(sx, sy) > 0.05 else { continue }
                        let i = (row * W2 + x) * 4
                        var e: Float = 0
                        for k in 0..<3 { e += abs(2 * Float(img[i + k]) - Float(img[i - W2 * 4 + k]) - Float(img[i + W2 * 4 + k])) }
                        sum += e; n += 3
                        let t = (row / tile) * tw + x / tile
                        tSum[t] += e / 3; tN[t] += 1
                    }
                }
                return (sum / Float(max(n, 1)), n / 3, tSum, tN)
            }
            let (cSharp, cn, ts, tn) = comb(sharpImg), (cSoft, _, ts0, _) = comb(softImg)
            var worstTile: Float = 0, worstAt = 0
            for t in ts.indices where tn[t] >= 300 {
                let v = (ts[t] - ts0[t]) / Float(tn[t])
                if v > worstTile { worstTile = v; worstAt = t }
            }
            print(String(format: "%@ worst tile at x %d y %d (2× image, top-down)", name, (worstAt % tw) * tile, (worstAt / tw) * tile))
            print(String(format: "%@ mirror rows: %d px, hatching sharp %.2f vs soft %.2f /255, worst tile +%.2f (ripple on, 2×)",
                         name, cn, cSharp, cSoft, worstTile))
            if cn > 200 && (cSharp > cSoft + 0.25 || worstTile > 2.0) { failures += 1 }
            if let dir = pngDir {
                writePNG(sharpImg, W2, H2, "\(dir)/sharp2x-\(name).png")
                if let sr = sharpRead {     // the mirror target: colour | alpha, top-down
                    var img = [UInt8](repeating: 0, count: sr.w * 2 * sr.h * 4)
                    for y in 0..<sr.h { for x in 0..<sr.w {
                        let j = ((sr.h - 1 - y) * sr.w + x) * 4
                        let a = Float(sr.rgba[j + 3])
                        let o = (y * sr.w * 2 + x) * 4, o2 = (y * sr.w * 2 + sr.w + x) * 4
                        for k in 0..<3 { img[o + k] = UInt8(min(max(a > 0.004 ? Float(sr.rgba[j + k]) / a * 255 : 0, 0), 255)) }
                        for k in 0..<3 { img[o2 + k] = UInt8(min(max(a * 255, 0), 255)) }
                        img[o + 3] = 255; img[o2 + 3] = 255
                    } }
                    writePNG(img, sr.w * 2, sr.h, "\(dir)/mirror-\(name).png")
                }
            }
        }
    }
    if sharp, params.sspr.0.z > 0 {
        func shifted(_ dx: Float, _ dy: Float, dt: Float = 0) -> (DisplayParams, [Int: MTLTexture], [UInt8]) {
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            var depth = [Float](repeating: 1, count: w * h)
            var st = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let fx = Float(x) - dx, fy = Float(y) - dy           // bottom-up rows
                    let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                    let ax = fx - Float(x0), ay = fy - Float(y0)
                    func c(_ xx: Int, _ yy: Int, _ k: Int) -> Float {
                        Float(dump.rgba[(min(max(yy, 0), h - 1) * w + min(max(xx, 0), w - 1)) * 4 + k])
                    }
                    for k in 0..<4 {
                        let v = (c(x0, y0, k) * (1 - ax) + c(x0 + 1, y0, k) * ax) * (1 - ay)
                              + (c(x0, y0 + 1, k) * (1 - ax) + c(x0 + 1, y0 + 1, k) * ax) * ay
                        rgba[(y * w + x) * 4 + k] = UInt8(min(max(v.rounded(), 0), 255))
                    }
                    let nx = min(max(Int(fx.rounded()), 0), w - 1), ny = min(max(Int(fy.rounded()), 0), h - 1)
                    depth[y * w + x] = dump.depth[ny * w + nx]
                    st[y * w + x] = stencil[ny * w + nx]
                }
            }
            var pp = params
            pp.reflectExtra.z += dt                       // the ripples a frame later
            let t = pp.eyeTangents.0
            let sx = (t.x + t.y) / Float(w), sy = (t.z + t.w) / Float(h)
            let t2 = SIMD4(t.x + dx * sx, t.y - dx * sx, t.z - dy * sy, t.w + dy * sy)
            pp.eyeTangents = (t2, t2)
            let colorT = rgba.withUnsafeBytes { array2D(.rgba8Unorm, w, h, slices: 1, $0.baseAddress!, 4) }
            let stT = st.withUnsafeBytes { array2D(.r8Uint, w, h, slices: 1, $0.baseAddress!, 1) }
            let depthT = depthTexture(w, h, depth, array: true)
            var tx: [Int: MTLTexture] = [TextureIndex.color.rawValue: colorT, 1: depthT, 2: stT,
                                         3: current.color, 4: current.depth]
            tx[5] = renderSharp(pp, colorT, depthT, stT)
            return (pp, tx, st)
        }
        func sampleShifted(_ img: [UInt8], _ x: Int, _ row: Int, _ dx: Float, _ dy: Float, _ k: Int) -> Float {
            // img rows are top-down; the shift is in bottom-up rows, so +dy moves up
            let fx = Float(x) - dx, fr = Float(row) + dy
            let x0 = Int(fx.rounded(.down)), r0 = Int(fr.rounded(.down))
            let ax = fx - Float(x0), ar = fr - Float(r0)
            func c(_ xx: Int, _ rr: Int) -> Float {
                Float(img[(min(max(rr, 0), h - 1) * w + min(max(xx, 0), w - 1)) * 4 + k])
            }
            return (c(x0, r0) * (1 - ax) + c(x0 + 1, r0) * ax) * (1 - ar) + (c(x0, r0 + 1) * (1 - ax) + c(x0 + 1, r0 + 1) * ax) * ar
        }
        let waterRow = Int(params.sspr.0.x) + 16
        var worst: (Float, Float) = (0, 0)
        // the last two: a frame later at 90 Hz with the ripples moving, and
        // a tenth of a second later — moving water must still not sparkle
        for (dx, dy, dt) in [(Float(0.3), Float(0), Float(0)), (0, 0.3, 0), (0.5, 0.5, 0),
                             (0.3, 0.3, 1.0 / 90), (0.3, 0.3, 0.1)] {
            let (pp, tx, st) = shifted(dx, dy, dt: dt)
            let g2 = render(glassOnPipeline, w, h, pp, tx)
            let p2 = render(plainPipeline, w, h, pp, tx)
            var errs: [Float] = [], base: [Float] = []
            for row in stride(from: 2, to: h - 2, by: 1) {
                for x in 2..<(w - 2) {
                    let sy = h - 1 - row
                    guard Int(st[sy * w + x]) == waterRow, Int(st[(sy + 2) * w + x]) == waterRow,
                          Int(st[(sy - 2) * w + x]) == waterRow, Int(st[sy * w + x + 2]) == waterRow,
                          Int(st[sy * w + x - 2]) == waterRow else { continue }
                    let i = (row * w + x) * 4
                    var e: Float = 0, b: Float = 0
                    for k in 0..<3 {
                        e = max(e, abs(Float(g2[i + k]) - sampleShifted(glass, x, row, dx, dy, k)))
                        b = max(b, abs(Float(p2[i + k]) - sampleShifted(plain, x, row, dx, dy, k)))
                    }
                    errs.append(e); base.append(b)
                }
            }
            if let dir = pngDir {
                // where the shifted reflection departs from the resampled one (×8)
                var img = [UInt8](repeating: 0, count: w * h * 4)
                for row in 0..<h { for x in 0..<w {
                    let i = (row * w + x) * 4
                    var e: Float = 0
                    for k in 0..<3 { e = max(e, abs(Float(g2[i + k]) - sampleShifted(glass, x, row, dx, dy, k))) }
                    let v = UInt8(min(e * 8, 255))
                    img[i] = v; img[i + 1] = UInt8(Float(glass[i + 1]) / 4); img[i + 2] = UInt8(Float(glass[i + 2]) / 4)
                } }
                writePNG(img, w, h, String(format: "%@/stability-%@-%.1f-%.1f-%.3f.png", dir, name, dx, dy, dt))
            }
            errs.sort(); base.sort()
            let p99 = errs.isEmpty ? 0 : errs[errs.count * 99 / 100], b99 = base.isEmpty ? 0 : base[base.count * 99 / 100]
            let mean = errs.reduce(0, +) / Float(max(errs.count, 1)), bmean = base.reduce(0, +) / Float(max(base.count, 1))
            print(String(format: "%@ stability, shift (%.1f, %.1f) px, +%.3f s: water mean %.1f p99 %.0f /255 (plain image: mean %.1f p99 %.0f) over %d px",
                         name, dx, dy, dt, mean, p99, bmean, b99, errs.count))
            worst = (max(worst.0, p99 - b99), max(worst.1, mean - bmean))
        }
        // the shifted reflection may differ from the resampled one by the
        // image's own resampling noise plus a little, not pop
        // 963b205 / 190007a (one sample at the winning source texel): p99
        // +21, mean +1.7 over the plain image's own noise; the
        // depth-verified, supersampled resolve: about +8 to +11 and +0.8
        if worst.0 > 14 || worst.1 > 1.2 { failures += 1 }
    }
    var envParams = params                             // the reflection alone
    envParams.glass = SIMD4(100, 0.04, 1, 0)
    envParams.water.x = 100; envParams.water.z = 1
    // over flat grey, so water's reflection (which modulates the surface's
    // own colour) depends on the reflection alone
    let grey = [UInt8](repeating: 128, count: w * h * 4)
    var envTextures = textures
    envTextures[TextureIndex.color.rawValue] = grey.withUnsafeBytes { array2D(.rgba8Unorm, w, h, slices: 1, $0.baseAddress!, 4) }
    let env = render(glassOnPipeline, w, h, envParams, envTextures)
    var flatParams = envParams                         // and with still water
    flatParams.water.w = 0
    let envFlat = render(glassOnPipeline, w, h, flatParams, envTextures)
    var marked = 0, changedOutside = 0, changedInside = 0, missed = 0
    for row in 0..<h {
        for col in 0..<w {
            let code = stencil[(h - 1 - row) * w + col]      // output row 0 is the top
            let isGlass = code >= 16 && code <= 239
            let i = (row * w + col) * 4
            let changed = (0..<3).contains { abs(Int(plain[i + $0]) - Int(glass[i + $0])) > 1 }
            if isGlass {
                marked += 1
                if changed { changedInside += 1 }
                if env[i] > 250 && env[i + 1] < 5 && env[i + 2] > 250 { missed += 1 }
            } else if changed { changedOutside += 1 }
        }
    }
    // From below: the eye moved under every water plane must leave water alone.
    let waterRows = Set(dump.kinds.enumerated().filter { $0.element == 1 }.map { $0.offset })
    if !waterRows.isEmpty, let planes = dump.planes {
        var under = params
        let lowest = waterRows.map { planes[$0].w / max(planes[$0].z, 0.01) }.min()!
        let (f, r, u) = dump.axes
        withUnsafeMutableBytes(of: &under) { raw in
            let v = (raw.baseAddress! + MemoryLayout<DisplayParams>.offset(of: \DisplayParams.glassEye)!)
                .bindMemory(to: SIMD4<Float>.self, capacity: 8)
            let o = SIMD3(dump.origin.x, dump.origin.y, lowest - 40)
            for eye in 0..<2 { v[eye * 4] = SIMD4(o, 0); v[eye * 4 + 1] = SIMD4(f, 0); v[eye * 4 + 2] = SIMD4(r, 0); v[eye * 4 + 3] = SIMD4(u, 0) }
        }
        let below = render(glassOnPipeline, w, h, under, textures)
        var waterPx = 0, changed = 0
        for row in 0..<h {
            for col in 0..<w {
                let code = Int(stencil[(h - 1 - row) * w + col])
                guard code >= 16, waterRows.contains(code - 16) else { continue }
                waterPx += 1
                let i = (row * w + col) * 4
                if (0..<3).contains(where: { abs(Int(plain[i + $0]) - Int(below[i + $0])) > 1 }) { changed += 1 }
            }
        }
        print("\(name) water: \(waterPx) px, \(changed) changed with the eye below the surface")
        if changed > 0 { failures += 1 }
    }
    // Occluders: a model or sprite drawn after a marked surface keeps its
    // stencil code. Put a fake one 30 units from the eye over the middle of
    // the view (its depth only): marked pixels under it must come out as
    // plain, and everything else as before. Then the real one in the dump:
    // marked pixels whose depth is the flat viewmodel's (under 6 units).
    do {
        let zOcc: Float = 30
        let occDepth = ((far + near - 2 * near * far / zOcc) / (far - near) + 1) / 2
        var fake = dump.depth
        let box = (x: w * 3 / 8..<w * 5 / 8, y: h / 4..<h * 3 / 4)    // bottom-up rows
        for y in box.y { for x in box.x { fake[y * w + x] = occDepth } }
        var t2 = textures
        t2[1] = depthTexture(w, h, fake, array: true)
        let occluded = render(glassOnPipeline, w, h, params, t2)
        var under = 0, wrongUnder = 0, wrongElsewhere = 0, viewmodel = 0, wrongViewmodel = 0
        for row in 0..<h {
            for col in 0..<w {
                let src = (h - 1 - row) * w + col
                let code = stencil[src]
                guard code >= 16 && code <= 239 else { continue }
                let i = (row * w + col) * 4
                let inBox = box.x.contains(col) && box.y.contains(h - 1 - row)
                func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool { (0..<3).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 1 } }
                if inBox { under += 1; if differs(occluded, plain) { wrongUnder += 1 } }
                else if differs(occluded, glass) { wrongElsewhere += 1 }
                let ndc = dump.depth[src] * 2 - 1
                if 2 * near * far / ((far + near) - ndc * (far - near)) < 6 {
                    viewmodel += 1; if differs(glass, plain) { wrongViewmodel += 1 }
                }
            }
        }
        print("\(name) occluders: \(under) marked px under a fake model, \(wrongUnder) shaded; \(wrongElsewhere) changed elsewhere; \(viewmodel) marked px under the viewmodel, \(wrongViewmodel) shaded")
        if wrongUnder > 0 || wrongElsewhere > 0 || wrongViewmodel > 0 { failures += 1 }
    }
    print("\(name) glass+water: \(marked) px marked, \(changedInside) changed, \(changedOutside) changed outside the mask, \(missed) without a probe reflection")
    if changedOutside > 0 || (marked > 0 && changedInside == 0) || missed > 0 { failures += 1 }
    glassViews.append(GlassView(name: name, dump: dump, glass: glass, env: env, envFlat: envFlat, sharp: sharpRead))
    if let pngDir {
        // plain | glass on top, the reflection alone | the mask below
        var sheet = [UInt8](repeating: 0, count: w * 2 * h * 2 * 4)
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let code = stencil[(h - 1 - row) * w + col]
                let tint = code >= 16 && code <= 239
                for (k, src) in [plain, glass].enumerated() {
                    let o = (row * w * 2 + k * w + col) * 4
                    for c in 0..<3 { sheet[o + c] = src[i + c] }
                }
                let e = ((row + h) * w * 2 + col) * 4, m = ((row + h) * w * 2 + w + col) * 4
                for c in 0..<3 { sheet[e + c] = tint ? env[i + c] : plain[i + c] / 4 }
                sheet[m] = tint ? 255 : plain[i] / 3
                sheet[m + 1] = plain[i + 1] / 3; sheet[m + 2] = plain[i + 2] / 3
            }
        }
        writePNG(sheet, w * 2, h * 2, "\(pngDir)/glass-\(name).png")
    }
}

// Gaze and stereo: every glass pixel of one view is carried to the other
// through its world point (the plane), and the reflections compared there.
// Same origin (only the yaw differs): the reflection is a function of the
// world point and the eye position alone, so it must agree — the old
// frame-sampled reflection changed with where the eye looked. Origins an eye
// apart: it may differ by true parallax only, which is small.
func compare(_ a: GlassView, _ b: GlassView, _ image: KeyPath<GlassView, [UInt8]> = \.env) -> (n: Int, mean: Float)? {
    guard let pa = a.dump.planes, let pb = b.dump.planes, let sa = a.dump.stencil, let sb = b.dump.stencil else { return nil }
    let w = a.dump.width, h = a.dump.height
    let (fa, ra, ua) = a.dump.axes, (fb, rb, ub) = b.dump.axes
    let p = a.dump.projection
    let t = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                  (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    var sum = 0, n = 0
    for row in stride(from: 1, to: h - 1, by: 3) {
        for col in stride(from: 1, to: w - 1, by: 3) {
            let code = Int(sa[(h - 1 - row) * w + col])
            guard code >= 16, code - 16 < pa.count else { continue }
            let plane = pa[code - 16]
            let u = (Float(col) + 0.5) / Float(w), v = 1 - (Float(row) + 0.5) / Float(h)
            let x = -t.x + (t.x + t.y) * u, y = -t.w + (t.z + t.w) * v
            let d = simd_normalize(fa + x * ra + y * ua)
            let nd = simd_dot(SIMD3(plane.x, plane.y, plane.z), d)
            guard abs(nd) > 1e-3 else { continue }
            let P = a.dump.origin + d * ((plane.w - simd_dot(SIMD3(plane.x, plane.y, plane.z), a.dump.origin)) / nd)
            let q = P - b.dump.origin
            let z = simd_dot(q, fb)
            guard z > 1 else { continue }
            let ub2 = (simd_dot(q, rb) / z + t.x) / (t.x + t.y), vb = (simd_dot(q, ub) / z + t.w) / (t.z + t.w)
            let cb = Int(ub2 * Float(w)), rbow = Int(vb * Float(h))       // bottom-up row
            guard cb > 1, cb < w - 2, rbow > 1, rbow < h - 2 else { continue }
            let codeB = Int(sb[rbow * w + cb])
            guard codeB >= 16, codeB - 16 < pb.count, simd_distance(pb[codeB - 16], plane) < 0.01 else { continue }
            let i = (row * w + col) * 4, j = ((h - 1 - rbow) * w + cb) * 4
            let ia = a[keyPath: image], ib = b[keyPath: image]
            sum += (0..<3).reduce(0) { $0 + abs(Int(ia[i + $1]) - Int(ib[j + $1])) }
            n += 1
        }
    }
    return n > 0 ? (n, Float(sum) / Float(n * 3)) : nil
}

// Stereo, properly: each eye must see a reflected point where its mirror image
// lies. For still surfaces, walk each sampled glass/water pixel's reflected ray
// through the probe on the CPU (the same face layout and depth decode the
// probe-view check validated) to the point H it shows, mirror H in the plane,
// and look where that image falls in the other eye: that pixel must show the
// same colour. The same-point comparison above cannot tell parallax from
// disagreement; this can.
func probeDistance(_ probe: Probe, _ dir: SIMD3<Float>) -> Float {
    let a = abs(dir)
    var face = 0, ab = SIMD2<Float>()
    if a.x >= a.y && a.x >= a.z {
        if dir.x > 0 { face = 0; ab = SIMD2(-dir.y, dir.z) / a.x } else { face = 2; ab = SIMD2(dir.y, dir.z) / a.x }
    } else if a.y >= a.z {
        if dir.y > 0 { face = 1; ab = SIMD2(dir.x, dir.z) / a.y } else { face = 3; ab = SIMD2(-dir.x, dir.z) / a.y }
    } else {
        if dir.z > 0 { face = 4; ab = SIMD2(-dir.y, -dir.x) / a.z } else { face = 5; ab = SIMD2(-dir.y, dir.x) / a.z }
    }
    let s = probe.size
    let uv = ab * 0.5 + 0.5
    let x = min(Int(uv.x * Float(s)), s - 1), y = min(Int(uv.y * Float(s)), s - 1)
    let ndc = probe.depth[face * s * s + y * s + x] * 2 - 1
    let n = probe.clip.x, f = probe.clip.y
    return 2 * n * f / ((f + n) - ndc * (f - n)) * (1 + simd_dot(ab, ab)).squareRoot()
}

func compareVirtual(_ a: GlassView, _ b: GlassView, _ probe: Probe) -> (n: Int, mean: Float)? {
    guard let pa = a.dump.planes, let pb = b.dump.planes, let sa = a.dump.stencil, let sb = b.dump.stencil else { return nil }
    let w = a.dump.width, h = a.dump.height
    let (fa, ra, ua) = a.dump.axes, (fb, rb, ub) = b.dump.axes
    let p = a.dump.projection
    let t = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                  (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    var sum = 0, n = 0
    for row in stride(from: 1, to: h - 1, by: 5) {
        for col in stride(from: 1, to: w - 1, by: 5) {
            let code = Int(sa[(h - 1 - row) * w + col])
            guard code >= 16, code - 16 < pa.count else { continue }
            let plane = pa[code - 16]
            var nrm = SIMD3(plane.x, plane.y, plane.z)
            let u = (Float(col) + 0.5) / Float(w), v = 1 - (Float(row) + 0.5) / Float(h)
            let d = simd_normalize(fa + (-t.x + (t.x + t.y) * u) * ra + (-t.w + (t.z + t.w) * v) * ua)
            let nd = simd_dot(nrm, d)
            guard abs(nd) > 1e-3 else { continue }
            let P = a.dump.origin + d * ((plane.w - simd_dot(nrm, a.dump.origin)) / nd)
            if nd > 0 { nrm = -nrm }
            let r = d - 2 * simd_dot(d, nrm) * nrm
            let PC = P - probe.origin, bq = simd_dot(r, PC), c0 = simd_dot(PC, PC)
            var dir = r, tHit: Float = 1
            for _ in 0..<3 {
                let D = probeDistance(probe, simd_normalize(dir))
                tHit = max(-bq + max(bq * bq - (c0 - D * D), 0).squareRoot(), 1)
                dir = PC + r * tHit
            }
            let H = P + r * tHit
            let V = H - 2 * (simd_dot(H, SIMD3(plane.x, plane.y, plane.z)) - plane.w) * SIMD3(plane.x, plane.y, plane.z)
            let q = V - b.dump.origin
            let z = simd_dot(q, fb)
            guard z > 1 else { continue }
            let ubx = (simd_dot(q, rb) / z + t.x) / (t.x + t.y), vb = (simd_dot(q, ub) / z + t.w) / (t.z + t.w)
            let cb = Int(ubx * Float(w)), rbow = Int(vb * Float(h))
            guard cb > 1, cb < w - 2, rbow > 1, rbow < h - 2 else { continue }
            let codeB = Int(sb[rbow * w + cb])
            guard codeB >= 16, codeB - 16 < pb.count, simd_distance(pb[codeB - 16], plane) < 0.01 else { continue }
            let i = (row * w + col) * 4, j = ((h - 1 - rbow) * w + cb) * 4
            sum += (0..<3).reduce(0) { $0 + abs(Int(a.envFlat[i + $1]) - Int(b.envFlat[j + $1])) }
            n += 1
        }
    }
    return n > 0 ? (n, Float(sum) / Float(n * 3)) : nil
}

// Sharp water, directly: every static point W above the water in view A,
// mirrored in the plane, must show the same colour in A's and B's mirror
// textures wherever both took it from well inside their frames (confidence
// over 0.95). Same origin: gaze independence of the mirror itself. Origins an
// eye apart: each eye mirrors its own image, and the two must agree on W.
// Returns the points compared, the mean difference, and the share of water
// pixels the mirror covers fully in A.
func compareSharp(_ a: GlassView, _ b: GlassView) -> (n: Int, mean: Float, baseline: Float)? {
    guard let sa = a.sharp, let sb = b.sharp else { return nil }
    let w = a.dump.width, h = a.dump.height
    let p = a.dump.projection
    let t = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                  (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    let p22 = p.columns.2.z, p32 = p.columns.3.z
    let near = p32 / (p22 - 1), far = p32 / (p22 + 1)
    let (fa, ra, ua) = a.dump.axes
    let height = sa.plane.y
    func project(_ v: SIMD3<Float>, _ dump: Dump) -> SIMD2<Float>? {
        let (f, r, u) = dump.axes
        let q = v - dump.origin, z = simd_dot(q, f)
        guard z > 4 else { return nil }
        return SIMD2((simd_dot(q, r) / z + t.x) / (t.x + t.y), (simd_dot(q, u) / z + t.w) / (t.z + t.w))
    }
    func read(_ s: (w: Int, h: Int, rgba: [Float16], plane: SIMD4<Float>), _ uv: SIMD2<Float>) -> SIMD4<Float>? {
        // row 0 holds uv.y 0, the engine's bottom row (ssprScatter writes NDC +y there)
        let x = Int(uv.x * Float(s.w)), y = Int(uv.y * Float(s.h))
        guard x >= 0, x < s.w, y >= 0, y < s.h else { return nil }
        let i = (y * s.w + x) * 4
        return SIMD4(Float(s.rgba[i]), Float(s.rgba[i + 1]), Float(s.rgba[i + 2]), Float(s.rgba[i + 3]))
    }
    var sum: Float = 0, n = 0, base: Float = 0
    for row in stride(from: 0, to: h, by: 4) {                 // bottom-up rows
        for col in stride(from: 0, to: w, by: 4) {
            let ndc = a.dump.depth[row * w + col] * 2 - 1
            let z = 2 * near * far / ((far + near) - ndc * (far - near))
            guard z > 6, a.dump.depth[row * w + col] < 1 else { continue }
            let u = (Float(col) + 0.5) / Float(w), v = (Float(row) + 0.5) / Float(h)
            let d = simd_normalize(fa + (-t.x + (t.x + t.y) * u) * ra + (-t.w + (t.z + t.w) * v) * ua)
            let W = a.dump.origin + d * (z / simd_dot(d, fa))
            guard W.z > height + 1 else { continue }
            let mirrored = SIMD3(W.x, W.y, 2 * height - W.z)
            guard let uvA = project(mirrored, a.dump), let uvB = project(mirrored, b.dump),
                  let ca = read(sa, uvA), let cb = read(sb, uvB), ca.w > 0.95, cb.w > 0.95 else { continue }
            let da = SIMD3(ca.x, ca.y, ca.z) / ca.w, db = SIMD3(cb.x, cb.y, cb.z) / cb.w
            // only where A's mirror shows W itself (W is not hidden in the
            // mirror, e.g. a bench top seen from below): A's mirror colour
            // matches A's engine colour at W
            let i0 = (row * w + col) * 4
            let engineA = SIMD3(Float(a.dump.rgba[i0]), Float(a.dump.rgba[i0 + 1]), Float(a.dump.rgba[i0 + 2])) / 255
            guard simd_reduce_max(abs(da - engineA)) < 0.05 else { continue }
            sum += simd_reduce_add(abs(da - db)) / 3 * 255
            n += 1
            // the same point unmirrored, straight from both engine images: how
            // much two views of one surface differ by sampling alone
            if let ub = project(W, b.dump) {
                let xb = min(max(Int(ub.x * Float(w)), 0), w - 1), yb = min(max(Int(ub.y * Float(h)), 0), h - 1)
                let i = (row * w + col) * 4, j = (yb * w + xb) * 4
                base += Float((0..<3).reduce(0) { $0 + abs(Int(a.dump.rgba[i + $1]) - Int(b.dump.rgba[j + $1])) }) / 3
            }
        }
    }
    return n > 0 ? (n, sum / Float(n), base / Float(n)) : nil
}

for (i, a) in glassViews.enumerated() {
    for b in glassViews[(i + 1)...] {
        let apart = simd_distance(a.dump.origin, b.dump.origin)
        // an eye apart means the same gaze too: a pair that differs in both
        // mixes the mirror's frame dependence into the stereo check
        let sameGaze = simd_distance(a.dump.angles, b.dump.angles) < 0.01
        if apart < 4, apart < 0.01 || sameGaze, let m = compareSharp(a, b) {
            print(String(format: "%@ vs %@ sharp mirror (%@): %d mirrored points both hold, mean difference %.1f/255 (the same points unmirrored in the engine images: %.1f/255)",
                         a.name, b.name, apart < 0.01 ? "same origin" : "an eye apart", m.n, m.mean, m.baseline))
            if apart >= 0.01, m.mean > m.baseline * 1.5 + 2 { failures += 1 }
        }
        // gaze, on what reaches the eye: the composite at the same glass and
        // water points (the mirror holds only what is on screen, so it shifts
        // a little with gaze where an occluder enters or leaves the frame)
        if apart < 0.01, a.sharp != nil, let c = compare(a, b, \.glass) {
            print(String(format: "%@ vs %@ gaze, final image: %d glass/water points, mean difference %.1f/255", a.name, b.name, c.n, c.mean))
            if c.mean > 3 { failures += 1 }
        }
    }
}
for (i, a) in glassViews.enumerated() where a.sharp == nil {
    for b in glassViews[(i + 1)...] {
        let apart = simd_distance(a.dump.origin, b.dump.origin)
        guard apart < 4, let r = compare(a, b) else { continue }
        if apart < 0.01 {
            print(String(format: "%@ vs %@ gaze (same origin): %d glass/water points, mean reflection difference %.1f/255", a.name, b.name, r.n, r.mean))
            if r.mean > 3 { failures += 1 }
        } else if let probe = probes.first?.probe, let v = compareVirtual(a, b, probe) {
            print(String(format: "%@ vs %@ stereo (%.1f units apart): same surface point %.1f/255 (true parallax); where each eye sees the mirror image of the same point %.1f/255 over %d points",
                         a.name, b.name, apart, r.mean, v.mean, v.n))
            if v.mean > 6 { failures += 1 }
        }
    }
}

// Merge: drawable depth 0.25 everywhere, overlay 0.5 in a square, 0 elsewhere.
do {
    let w = 64, h = 64
    var overlay = [Float](repeating: 0, count: w * h)
    for y in 16..<32 { for x in 8..<40 { overlay[y * w + x] = 0.5 } }
    let overlayTex = depthTexture(w, h, overlay, array: true)
    let target = depthTexture(w, h, [Float](repeating: 0.25, count: w * h), array: false, renderTarget: true)
    let rpd = MTLRenderPassDescriptor()
    rpd.depthAttachment.texture = target
    rpd.depthAttachment.loadAction = .load
    rpd.depthAttachment.storeAction = .store
    rpd.renderTargetWidth = w; rpd.renderTargetHeight = h
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(merge)
    enc.setDepthStencilState(depthState(.always))
    enc.setFragmentTexture(overlayTex, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let result = readDepth(target)
    let wrong = zip(result, overlay).filter { got, o in got != (o > 0 ? o : 0.25) }.count
    print("merge: \(wrong) of \(w * h) texels wrong")
    if wrong > 0 { failures += 1 }
}

print(failures == 0 ? "OK" : "FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
