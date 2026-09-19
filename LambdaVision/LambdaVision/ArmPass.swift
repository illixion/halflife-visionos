//
//  ArmPass.swift
//  LambdaVision
//
//  Draws a procedural wireframe skeleton (forearm + full per-finger chain)
//  for each tracked hand, as a stand-in for the real passthrough arms.
//  visionOS composites the user's real hands/forearms over full immersion
//  as a safety feature independent of anything we render — see
//  .upperLimbVisibility(.hidden) in LambdaVisionApp — and that passthrough
//  layer sits ON TOP of our content, occluding any weapon model drawn "in"
//  the hand. With the real arms hidden, this pass is the only visual
//  substitute for the user's hands, so it runs whenever a hand is tracked,
//  independent of weapon/joystick state.
//
//  Pure line geometry between ARKit hand-skeleton joints — no mesh, no
//  assets. Caller (Renderer.armSkeletonVertices) supplies vertex positions
//  already in Apple world space (metres) plus a per-vertex colour, so no
//  model matrix is needed here.
//

import Metal
import CompositorServices
import simd

final class ArmPass {
    // Packed float layout per vertex: pos.xyz, color.rgba (28 bytes) — a
    // plain [Float] array like WeaponPass's deindexed mesh buffer, so the
    // vertex descriptor's byte offsets can't desync against SIMD3<Float>'s
    // 16-byte Swift stride padding.
    static let floatsPerVertex = 7
    static let maxVertices = 512   // 2 hands x 26 bones x 2 endpoints, generous headroom

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexArgTable: MTL4ArgumentTable
    private let depthFormat: MTLPixelFormat
    private let layered: Bool

    private var vertexBuffers: [MTLBuffer]

    // Per-eye depth, sized to the drawable. Recreated on size change.
    private var depth: MTLTexture?
    private var depthW = 0, depthH = 0, depthSlices = 0

    init(device: MTLDevice, layerRenderer: LayerRenderer, maxBuffersInFlight: Int) {
        self.device = device
        let colorFormat = layerRenderer.configuration.colorFormat
        self.depthFormat = layerRenderer.configuration.depthFormat
        self.layered = (layerRenderer.configuration.layout == .layered)

        let library = device.makeDefaultLibrary()

        let vd = MTLVertexDescriptor()
        vd.attributes[VertexAttribute.position.rawValue].format = .float3
        vd.attributes[VertexAttribute.position.rawValue].offset = 0
        vd.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vd.attributes[VertexAttribute.color.rawValue].format = .float4
        vd.attributes[VertexAttribute.color.rawValue].offset = 12
        vd.attributes[VertexAttribute.color.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vd.layouts[BufferIndex.meshPositions.rawValue].stride = ArmPass.floatsPerVertex * 4

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "ArmSkeletonPipeline"
        pd.vertexFunction = library?.makeFunction(name: "armVertexShader")
        pd.fragmentFunction = library?.makeFunction(name: "armFragmentShader")
        pd.vertexDescriptor = vd
        pd.rasterSampleCount = 1
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat = depthFormat
        pd.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        self.pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .greater   // reverse-Z, matches the engine
        dsd.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsd)!

        let vDesc = MTL4ArgumentTableDescriptor()
        vDesc.maxBufferBindCount = 4   // vertex@0, viewProj@3
        self.vertexArgTable = try! device.makeArgumentTable(descriptor: vDesc)

        self.vertexBuffers = (0..<maxBuffersInFlight).map { _ in
            device.makeBuffer(length: ArmPass.maxVertices * ArmPass.floatsPerVertex * 4,
                              options: .storageModeShared)!
        }
    }

    /// Allocate/resize the arm depth to match the drawable colour slice.
    func ensureDepth(width: Int, height: Int, slices: Int) {
        if depth != nil && depthW == width && depthH == height && depthSlices == slices { return }
        let td = MTLTextureDescriptor()
        td.textureType = slices > 1 ? .type2DArray : .type2D
        td.pixelFormat = depthFormat
        td.width = width; td.height = height
        td.arrayLength = max(1, slices)
        td.usage = .renderTarget
        td.storageMode = .private
        depth = device.makeTexture(descriptor: td)
        depth?.label = "ArmSkeletonDepth"
        depthW = width; depthH = height; depthSlices = slices
    }

    /// Resources that must be resident this frame (MTL4 has no auto tracking).
    func residentResources(uniformBufferIndex: Int) -> [MTLResource] {
        var r: [MTLResource] = [vertexBuffers[uniformBufferIndex]]
        if let depth { r.append(depth) }
        return r
    }

    /// `vertexFloats` is a flat, packed [pos.xyz, color.rgba] x N array
    /// (N = 2 per line segment), world-space positions — no model matrix.
    /// No-op if the depth target hasn't been sized yet or there's nothing
    /// to draw (e.g. no hand currently tracked). Draws after (on top of)
    /// the fullscreen engine pass, and expects any later pass (WeaponPass)
    /// to composite over it in turn — this pass does not itself depth-test
    /// against the weapon.
    func encode(commandBuffer: MTL4CommandBuffer,
                drawable: LayerRenderer.Drawable,
                viewProjectionBuffer: MTLBuffer,
                viewProjectionOffset: Int,
                uniformBufferIndex: Int,
                vertexFloats: [Float]) {
        guard let depth else { return }
        let vertexCount = min(vertexFloats.count / ArmPass.floatsPerVertex, ArmPass.maxVertices)
        guard vertexCount > 0 else { return }

        let vb = vertexBuffers[uniformBufferIndex]
        vertexFloats.withUnsafeBytes { raw in
            _ = memcpy(vb.contents(), raw.baseAddress, min(raw.count, vb.length))
        }

        let rpd = MTL4RenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.colorTextures[0]
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 0.0    // reverse-Z far
        rpd.depthAttachment.storeAction = .dontCare
        rpd.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layered { rpd.renderTargetArrayLength = drawable.views.count }

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.label = "Arm Skeleton Encoder"
        // Order this pass's colour load after the fullscreen engine pass's
        // colour writes on the same queue (MTL4 = no hazard tracking).
        enc.barrier(afterQueueStages: .all, beforeStages: .fragment, visibilityOptions: .device)

        enc.setViewports(drawable.views.map { $0.textureMap.viewport })
        if drawable.views.count > 1 {
            enc.setVertexAmplificationCount((0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            })
        }

        enc.setArgumentTable(vertexArgTable, stages: .vertex)
        vertexArgTable.setAddress(vb.gpuAddress, index: BufferIndex.meshPositions.rawValue)
        vertexArgTable.setAddress(viewProjectionBuffer.gpuAddress + UInt64(viewProjectionOffset),
                                  index: BufferIndex.viewProjection.rawValue)

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.drawPrimitives(primitiveType: .line, vertexStart: 0, vertexCount: vertexCount)

        enc.endEncoding()
    }
}
