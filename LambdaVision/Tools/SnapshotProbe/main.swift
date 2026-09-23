// Snapshot probe: redraws Mac engine dumps (vrdumpN.bin) from moved heads
// with the app's own SnapshotShaders.metal, the way the app holds the last
// frame of a level still while the next one loads.
//
// Dump layout (ref/gl R_DumpViewForVR): int magic 'VVRD', version, width,
// height; GL projection and world-view matrices, column-major; view origin
// and angles; RGBA8 colour then float window depth, both bottom-up rows.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

let inchesPerMetre: Float = 39.37

struct Dump {
    var width = 0, height = 0
    var projection = float4x4(), view = float4x4()
    var rgba = Data(), depth = [Float]()

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
        func matrix(_ a: [Float]) -> float4x4 {
            float4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                               SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
        }
        projection = matrix(floats(16, 16))
        view = matrix(floats(80, 16))
        let pixels = 168
        rgba = d.subdata(in: pixels..<pixels + width * height * 4)
        depth = floats(pixels + width * height * 4, width * height)
    }
}

/// A head motion from the captured pose, in the captured eye's frame
/// (x right, y up, −z forward), metres and degrees.
struct Motion {
    var name: String
    var move = SIMD3<Float>(0, 0, 0)
    var yawDeg: Float = 0
    var pitchDeg: Float = 0

    /// The moved eye's pose in the captured eye's space.
    var pose: float4x4 {
        let t = move * inchesPerMetre
        var m = float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0))
                         * simd_quatf(angle: pitchDeg * .pi / 180, axis: SIMD3(1, 0, 0)))
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}

let motions: [Motion] = [
    Motion(name: "0_still"),
    Motion(name: "1_right5cm", move: SIMD3(0.05, 0, 0)),
    Motion(name: "2_right15cm", move: SIMD3(0.15, 0, 0)),
    Motion(name: "3_forward15cm", move: SIMD3(0, 0, -0.15)),
    Motion(name: "4_up10cm", move: SIMD3(0, 0.10, 0)),
    Motion(name: "5_yaw15", yawDeg: 15),
    Motion(name: "6_turn_and_step", move: SIMD3(0.10, 0, -0.10), yawDeg: -20, pitchDeg: 8),
]

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
let libraryPath = args.removeFirst()
var grid = 16          // pixels per mesh cell
var tear: Float = 1.08 // depth ratio across a triangle that tears it
var overscan: Float = 0.25
var dumps: [String] = []
var outDir = ""
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--grid": grid = Int(args.removeFirst())!
    case "--tear": tear = Float(args.removeFirst())!
    case "--overscan": overscan = Float(args.removeFirst())!
    default: if outDir.isEmpty { outDir = a } else { dumps.append(a) }
    }
}
guard !outDir.isEmpty, !dumps.isEmpty else {
    print("usage: build.sh out_dir vrdump.bin... [--grid px] [--tear ratio]"); exit(2)
}
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - Metal

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: libraryPath))

func pipeline(_ vertex: String, blend: Bool) throws -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: vertex)
    d.fragmentFunction = library.makeFunction(name: "snapshotFragment")
    d.colorAttachments[0].pixelFormat = .rgba8Unorm
    d.depthAttachmentPixelFormat = .depth32Float
    if blend {
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    }
    return try device.makeRenderPipelineState(descriptor: d)
}
let meshPipeline = try pipeline("snapshotMeshVertex", blend: true)
let backdropPipeline = try pipeline("snapshotBackdropVertex", blend: true)

func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
    let d = MTLDepthStencilDescriptor()
    d.depthCompareFunction = compare
    d.isDepthWriteEnabled = write
    return device.makeDepthStencilState(descriptor: d)!
}
let backdropDepth = depthState(.always, write: false)
let meshDepth = depthState(.less, write: true)

// GL clip z (−w…w) → Metal (0…w).
let glToMetalClip = float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                    SIMD4(0, 0, 0.5, 0.5), SIMD4(0, 0, 0, 1)])

func savePNG(_ texture: MTLTexture, _ path: String) {
    let w = texture.width, h = texture.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

var failed = false
for path in dumps {
    let dump = try Dump(path: path)
    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let w = dump.width, h = dump.height

    // Captured colour and depth, rows bottom-up as GL wrote them (flipV).
    let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    colorDesc.textureType = .type2DArray
    let color = device.makeTexture(descriptor: colorDesc)!
    dump.rgba.withUnsafeBytes {
        color.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: w * 4, bytesPerImage: w * h * 4)
    }
    let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
    depthDesc.textureType = .type2DArray
    depthDesc.storageMode = .private
    let depth = device.makeTexture(descriptor: depthDesc)!
    let staging = dump.depth.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
    do {
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: depth, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
    }

    let captureView = dump.view
    let captureClipToWorld = (dump.projection * captureView).inverse
    let captureEye = captureView.inverse.columns.3

    var sheet: [String] = []
    for motion in motions {
        let view = motion.pose.inverse * captureView
        var u = SnapshotUniforms()
        u.captureClipToWorld = (captureClipToWorld, captureClipToWorld)
        let worldToClip = glToMetalClip * dump.projection * view
        u.worldToClip = (worldToClip, worldToClip)
        u.captureEye = (captureEye, captureEye)
        u.grid = SIMD2(UInt32((w + grid - 1) / grid), UInt32((h + grid - 1) / grid))
        u.eyeBase = 0
        u.flipV = 1
        u.farZ = 0.99999
        u.tearRatio = tear
        u.alpha = 1
        u.minDistance = 4
        u.overscan = overscan

        let targetDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        targetDesc.usage = [.renderTarget, .shaderRead]
        let target = device.makeTexture(descriptor: targetDesc)!
        let zDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        zDesc.usage = .renderTarget; zDesc.storageMode = .private
        let z = device.makeTexture(descriptor: zDesc)!

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.6, green: 0, blue: 0.6, alpha: 1) // holes show magenta
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = z
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setCullMode(.none)
        let vertexCount = Int(u.grid.x * u.grid.y) * 6
        enc.setVertexBytes(&u, length: MemoryLayout<SnapshotUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        enc.setFragmentBytes(&u, length: MemoryLayout<SnapshotUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        enc.setVertexTexture(depth, index: 1)
        enc.setFragmentTexture(color, index: Int(TextureIndex.color.rawValue))
        enc.setRenderPipelineState(backdropPipeline)
        enc.setDepthStencilState(backdropDepth)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(meshDepth)
        let t0 = Date()
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        _ = t0

        let out = "\(outDir)/\(stem)_\(motion.name).png"
        savePNG(target, out)
        sheet.append(out)

        // The unmoved redraw must match the dump: mean absolute error per
        // channel against the captured colour (rows flipped to top-down).
        if motion.name == "0_still" {
            var got = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&got, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            var err = 0.0, magenta = 0
            dump.rgba.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    let sy = h - 1 - y
                    for x in 0..<w {
                        let i = (y * w + x) * 4, j = (sy * w + x) * 4
                        if got[i] == 153, got[i + 1] == 0, got[i + 2] == 153 { magenta += 1 }
                        for c in 0..<3 { err += abs(Double(got[i + c]) - Double(src[j + c])) }
                    }
                }
            }
            let mae = err / Double(w * h * 3)
            print(String(format: "%@ still: mean error %.2f/255, holes %.3f%%, gpu %.2f ms (%d vertices)",
                         stem, mae, 100 * Double(magenta) / Double(w * h), gpuMs, vertexCount * 2))
            if mae > 3 || magenta > 0 { print("  FAIL: the unmoved redraw does not reproduce the dump"); failed = true }
        } else {
            var got = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&got, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            var magenta = 0
            for i in stride(from: 0, to: got.count, by: 4) where got[i] == 153 && got[i + 1] == 0 && got[i + 2] == 153 { magenta += 1 }
            print(String(format: "%@ %@: outside capture %.2f%%", stem, motion.name, 100 * Double(magenta) / Double(w * h)))
        }
    }
    print("  wrote \(sheet.count) views for \(stem)")
}
exit(failed ? 1 : 0)
