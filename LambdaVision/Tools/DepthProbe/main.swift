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

struct GlassView {
    let name: String, dump: Dump, glass: [UInt8], env: [UInt8]
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
    params.glass = SIMD4(1, 0.04, 0.85, 0.35)
    params.glassAmbient = SIMD4(1, 0, 1, 0)          // magenta: shows any pixel the probe missed
    params.glassTint = SIMD4(0.80, 0.90, 0.88, 0)
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
    let textures: [Int: MTLTexture] = [TextureIndex.color.rawValue: color, 2: stencilTex, 3: current.color, 4: current.depth]
    let plain = render(plainPipeline, w, h, params, textures)
    let glass = render(glassOnPipeline, w, h, params, textures)
    var envParams = params                             // the reflection alone
    envParams.glass = SIMD4(100, 0.04, 1, 0)
    let env = render(glassOnPipeline, w, h, envParams, textures)
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
    print("\(name) glass: \(marked) px marked, \(changedInside) changed, \(changedOutside) changed outside the mask, \(missed) without a probe reflection")
    if changedOutside > 0 || (marked > 0 && changedInside == 0) || missed > 0 { failures += 1 }
    glassViews.append(GlassView(name: name, dump: dump, glass: glass, env: env))
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
func compare(_ a: GlassView, _ b: GlassView) -> (n: Int, mean: Float)? {
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
            sum += (0..<3).reduce(0) { $0 + abs(Int(a.env[i + $1]) - Int(b.env[j + $1])) }
            n += 1
        }
    }
    return n > 0 ? (n, Float(sum) / Float(n * 3)) : nil
}
for (i, a) in glassViews.enumerated() {
    for b in glassViews[(i + 1)...] {
        let apart = simd_distance(a.dump.origin, b.dump.origin)
        guard apart < 4, let r = compare(a, b) else { continue }
        let kind = apart < 0.01 ? "gaze (same origin)" : String(format: "stereo (%.1f units apart)", apart)
        print(String(format: "%@ vs %@ %@: %d glass points, mean reflection difference %.1f/255", a.name, b.name, kind, r.n, r.mean))
        if r.mean > (apart < 0.01 ? 3 : 8) { failures += 1 }
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
