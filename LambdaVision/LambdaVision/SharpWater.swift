//
//  SharpWater.swift
//  LambdaVision
//
//  Sharp water reflections (Renderer.sharpWaterReflections, under
//  Renderer.waterReflections): a screen-space planar reflection for
//  horizontal water. The probe alone gives a soft room; this mirrors each
//  eye's own engine image in the exact water plane (Shaders.metal
//  ssprScatter), at half resolution, and the composite reads it at water
//  pixels and falls back to the probe where it is empty or its source was
//  near the frame's edge (glassShade). Each eye mirrors its own image, so the
//  stereo parallax is exactly a mirror's, and the depth test keeps the
//  nearest mirrored point. One draw of points (one per half-resolution
//  texel) into a 2-slice colour + depth target, before the composite, only
//  on frames where an eye has horizontal water below it in its plane table.
//

import Metal
import simd

final class SharpWater {
    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private(set) var color: MTLTexture?
    private var depth: MTLTexture?

    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        let d = MTLRenderPipelineDescriptor()
        d.label = "SharpWater"
        d.vertexFunction = library.makeFunction(name: "ssprScatter")
        d.fragmentFunction = library.makeFunction(name: "ssprWrite")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.depthAttachmentPixelFormat = .depth32Float
        d.inputPrimitiveTopology = .point
        d.maxVertexAmplificationCount = 2
        guard d.vertexFunction != nil, d.fragmentFunction != nil,
              let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.pipeline = pipeline
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: ds) else { return nil }
        self.depthState = depthState
        let at = MTL4ArgumentTableDescriptor()
        at.maxBufferBindCount = 3        // DisplayParams @ BufferIndexUniforms
        at.maxTextureBindCount = 2       // colorMap @ 0, engine depth @ 1
        guard let table = try? device.makeArgumentTable(descriptor: at) else { return nil }
        argumentTable = table
    }

    /// The targets for this colour map size (divided by divisor, as
    /// DisplayParams.sspr.w tells the shader), made on first use or when it
    /// changes. Returns the new allocations for the residency set.
    func ensureTargets(colorMap: MTLTexture, divisor: Int) -> [MTLAllocation] {
        let w = (colorMap.width + divisor - 1) / divisor, h = (colorMap.height + divisor - 1) / divisor
        if let color, color.width == w, color.height == h { return [] }
        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = w; d.height = h; d.arrayLength = 2
            d.usage = format == .depth32Float ? [.renderTarget] : [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        color = target(.rgba16Float)
        depth = target(.depth32Float)
        color?.label = "SharpWaterColor"
        depth?.label = "SharpWaterDepth"
        return [color, depth].compactMap { $0 }
    }

    /// Mirrors both eyes' images. paramsAddress: this frame's DisplayParams
    /// (sspr, the eyes' views and tangents), which the caller fills before
    /// the command buffer is committed.
    func encode(commandBuffer: MTL4CommandBuffer, colorMap: MTLTexture, engineDepth: MTLTexture,
                paramsAddress: UInt64) {
        guard let color, let depth else { return }
        let rpd = MTL4RenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .dontCare
        rpd.renderTargetArrayLength = 2
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.label = "SharpWater"
        // ANGLE's colour and depth (ordered by the queue's wait on its fence)
        enc.barrier(afterQueueStages: .all, beforeStages: .vertex, visibilityOptions: .device)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(color.width),
                                    height: Double(color.height), znear: 0, zfar: 1))
        enc.setVertexAmplificationCount((0..<2).map {
            MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: UInt32($0))
        })
        argumentTable.setTexture(colorMap.gpuResourceID, index: 0)
        argumentTable.setTexture(engineDepth.gpuResourceID, index: 1)
        argumentTable.setAddress(paramsAddress, index: BufferIndex.uniforms.rawValue)
        enc.setArgumentTable(argumentTable, stages: .vertex)
        enc.drawPrimitives(primitiveType: .point, vertexStart: 0, vertexCount: color.width * color.height)
        enc.barrier(afterStages: .fragment, beforeQueueStages: .all, visibilityOptions: .device)
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
