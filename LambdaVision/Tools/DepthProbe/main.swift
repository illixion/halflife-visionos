// Depth probe: runs the app's own composite shaders (Shaders.metal) on Mac
// engine dumps (vrdumpN.bin, r_vrdump N): the reprojection depth
// (fragmentShaderDepth, reprojectionDepthMerge), checked against the dump's
// own matrices, and the glass reflection (glassShade) on dumps that carry the
// engine's stencil (version 2, taken with r_vrglass 1).
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
// Glass: renders the plain and the glass composite and checks that only
// pixels the engine marked changed, and that some did; with --png DIR it
// writes glass-<dump>.png (plain left, glass right, marked pixels tinted
// below) for a look.
//
//   ./build.sh [--png DIR] vrdump1.bin [vrdump2.bin ...]
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
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let libraryPath = args.removeFirst()
var pngDir: String?
if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
    pngDir = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
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
        enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: BufferIndex.uniforms.rawValue)
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

// Glass: the plain composite against the glass one, on dumps with a stencil.
func glassPipeline(_ glass: Bool) throws -> MTLRenderPipelineState {
    let constants = MTLFunctionConstantValues()
    var srgb = false, lsb: Float = 0, on = glass
    constants.setConstantValue(&srgb, type: .bool, index: 20)
    constants.setConstantValue(&lsb, type: .float, index: 21)
    constants.setConstantValue(&on, type: .bool, index: 22)
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "fullscreenVertexShader")
    d.fragmentFunction = try library.makeFunction(name: "fragmentShader", constantValues: constants)
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

let plainPipeline = try glassPipeline(false)
let glassOnPipeline = try glassPipeline(true)
for path in args {
    let dump = try Dump(path: path)
    guard let stencil = dump.stencil else { continue }
    let w = dump.width, h = dump.height
    func array2D(_ format: MTLPixelFormat, _ bytes: UnsafeRawPointer, _ bpp: Int) -> MTLTexture {
        let td = MTLTextureDescriptor()
        td.textureType = .type2DArray
        td.pixelFormat = format
        td.width = w; td.height = h
        td.usage = .shaderRead
        let t = device.makeTexture(descriptor: td)!
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: 0,
                  withBytes: bytes, bytesPerRow: w * bpp, bytesPerImage: w * h * bpp)
        return t
    }
    let color = dump.rgba.withUnsafeBytes { array2D(.rgba8Unorm, $0.baseAddress!, 4) }
    let stencilTex = stencil.withUnsafeBytes { array2D(.r8Uint, $0.baseAddress!, 1) }
    // The engine frustum's tangents from its GL projection (DrawableProjection's formula).
    let p = dump.projection
    let t = SIMD4((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                  (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    var params = DisplayParams()
    params.glass = SIMD4(1, 0.04, 0.85, 0)
    params.glassAmbient = SIMD4(0.15, 0.15, 0.15, 0)
    params.eyeTangents = (t, t)

    func render(_ pipeline: MTLRenderPipelineState) -> [UInt8] {
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
        enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: BufferIndex.uniforms.rawValue)
        enc.setFragmentTexture(color, index: TextureIndex.color.rawValue)
        enc.setFragmentTexture(stencilTex, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return out
    }
    let plain = render(plainPipeline), glass = render(glassOnPipeline)
    var marked = 0, changedOutside = 0, changedInside = 0
    for row in 0..<h {
        for col in 0..<w {
            let code = stencil[(h - 1 - row) * w + col]      // output row 0 is the top
            let isGlass = code >= 16 && code <= 240
            let i = (row * w + col) * 4
            let changed = (0..<3).contains { abs(Int(plain[i + $0]) - Int(glass[i + $0])) > 1 }
            if isGlass { marked += 1; if changed { changedInside += 1 } } else if changed { changedOutside += 1 }
        }
    }
    print("\((path as NSString).lastPathComponent) glass: \(marked) px marked, \(changedInside) changed by the reflection, \(changedOutside) changed outside the mask")
    if changedOutside > 0 || (marked > 0 && changedInside == 0) { failures += 1 }
    if let pngDir {
        // plain | glass on top, the mask tinted under each
        var sheet = [UInt8](repeating: 0, count: w * 2 * h * 2 * 4)
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let code = stencil[(h - 1 - row) * w + col]
                let tint = code >= 16 && code <= 240
                for (k, src) in [plain, glass].enumerated() {
                    let o = (row * w * 2 + k * w + col) * 4
                    for c in 0..<3 { sheet[o + c] = src[i + c] }
                    let u = ((row + h) * w * 2 + k * w + col) * 4
                    sheet[u] = tint ? 255 : src[i] / 3
                    sheet[u + 1] = src[i + 1] / 3; sheet[u + 2] = src[i + 2] / 3
                }
            }
        }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        writePNG(sheet, w * 2, h * 2, "\(pngDir)/glass-\(name).png")
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
