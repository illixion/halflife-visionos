//
//  SharpWater.swift
//  LambdaVision
//
//  Sharp water reflections (Renderer.sharpWaterReflections, under
//  Renderer.waterReflections): a screen-space planar reflection for
//  horizontal water. The probe alone gives a soft room; this mirrors each
//  eye's own engine image in the exact water plane and the composite reads
//  it at water pixels, falling back to the probe where it is empty or its
//  source was near the frame's edge (glassShade). Each eye mirrors its own
//  image, so the stereo parallax is exactly a mirror's.
//
//  Two compute dispatches at 1/3 of the engine's resolution (Shaders.metal
//  ssprProject: projection with an atomic-min key per target texel;
//  ssprResolve: decode, gap fill, write), both eyes in one grid, before the
//  composite, only on frames where an eye has horizontal water below it.
//  The first version splatted one point per half-resolution texel through
//  the rasteriser and measured 5.4 ms on the headset. Timed as gMirror.
//

import Metal
import simd

final class SharpWater {
    let device: MTLDevice
    private let project: MTLComputePipelineState
    private let resolve: MTLComputePipelineState
    private let argumentTable: MTL4ArgumentTable
    private(set) var color: MTLTexture?
    private var keys: MTLBuffer?
    private var size = (w: 0, h: 0)

    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        guard let pf = library.makeFunction(name: "ssprProject"),
              let rf = library.makeFunction(name: "ssprResolve"),
              let project = try? device.makeComputePipelineState(function: pf),
              let resolve = try? device.makeComputePipelineState(function: rf) else { return nil }
        self.project = project
        self.resolve = resolve
        let at = MTL4ArgumentTableDescriptor()
        at.maxBufferBindCount = 3        // keys @ 0, DisplayParams @ BufferIndexUniforms
        at.maxTextureBindCount = 3       // colorMap @ 0, engine depth @ 1, mirror @ 2
        guard let table = try? device.makeArgumentTable(descriptor: at) else { return nil }
        argumentTable = table
    }

    /// The target and key buffer for this colour map size (divided by
    /// divisor, as DisplayParams.sspr.w tells the shaders), made on first use
    /// or when it changes. Returns the new allocations for the residency set.
    func ensureTargets(colorMap: MTLTexture, divisor: Int) -> [MTLAllocation] {
        let w = (colorMap.width + divisor - 1) / divisor, h = (colorMap.height + divisor - 1) / divisor
        if color != nil, size.w == w, size.h == h { return [] }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rgba16Float
        d.width = w; d.height = h; d.arrayLength = 2
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        color = device.makeTexture(descriptor: d)
        color?.label = "SharpWaterMirror"
        keys = device.makeBuffer(length: w * h * 2 * 4, options: .storageModePrivate)
        keys?.label = "SharpWaterKeys"
        size = (w, h)
        return [color, keys].compactMap { $0 as MTLAllocation? }
    }

    /// Mirrors both eyes' images. paramsAddress: this frame's DisplayParams
    /// (sspr, the eyes' views and tangents), which the caller fills before
    /// the command buffer is committed.
    func encode(commandBuffer: MTL4CommandBuffer, colorMap: MTLTexture, engineDepth: MTLTexture,
                paramsAddress: UInt64) {
        guard let color, let keys, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "SharpWater"
        // ANGLE's colour and depth (ordered by the queue's wait on its fence),
        // and last frame's composite reading the mirror
        enc.barrier(afterQueueStages: .all, beforeStages: [.dispatch, .blit], visibilityOptions: .device)
        enc.fill(buffer: keys, range: 0..<keys.length, value: 0xFF)
        enc.barrier(afterEncoderStages: .blit, beforeEncoderStages: .dispatch, visibilityOptions: .device)
        argumentTable.setAddress(keys.gpuAddress, index: 0)
        argumentTable.setAddress(paramsAddress, index: BufferIndex.uniforms.rawValue)
        argumentTable.setTexture(colorMap.gpuResourceID, index: 0)
        argumentTable.setTexture(engineDepth.gpuResourceID, index: 1)
        argumentTable.setTexture(color.gpuResourceID, index: 2)
        enc.setArgumentTable(argumentTable)
        let grid = MTLSize(width: size.w, height: size.h, depth: 2)
        let group = MTLSize(width: 16, height: 8, depth: 1)
        enc.setComputePipelineState(project)
        enc.dispatchThreads(threadsPerGrid: grid, threadsPerThreadgroup: group)
        enc.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
        enc.setComputePipelineState(resolve)
        enc.dispatchThreads(threadsPerGrid: grid, threadsPerThreadgroup: group)
        enc.barrier(afterStages: .dispatch, beforeQueueStages: .all, visibilityOptions: .device)
        enc.endEncoding()
    }

    /// DisplayParams.sspr for each eye: the highest horizontal water row
    /// below the eye in that eye's plane table, or off.
    static func planes(_ eyes: [lambda_glass_eye_t]) -> (SIMD4<Float>, SIMD4<Float>) {
        func pick(_ e: lambda_glass_eye_t) -> SIMD4<Float> {
            var e = e
            let n = Int(min(max(e.count, 0), LAMBDA_GLASS_MAX_PLANES))
            var best: (row: Int, height: Float)?
            withUnsafeBytes(of: &e.planes) { planes in
                withUnsafeBytes(of: &e.kind) { kinds in
                    let p = planes.bindMemory(to: Float.self)
                    for row in 0..<n where kinds[row] == 1 && p[row * 4 + 2] > 0.99 {
                        let height = p[row * 4 + 3] / p[row * 4 + 2]
                        if height < e.origin.2 - 1, height > (best?.height ?? -.infinity) {
                            best = (row, height)
                        }
                    }
                }
            }
            guard let best else { return SIMD4(0, 0, 0, 0) }
            return SIMD4(Float(best.row), best.height, 1, 0)
        }
        guard eyes.count == 2 else { return (.zero, .zero) }
        return (pick(eyes[0]), pick(eyes[1]))
    }
}
