//
//  ReprojectionDepth.swift
//  LambdaVision
//
//  What depth the compositor gets for each pixel it re-warps (see the
//  avp_reprojection_depth notes): CompositorServices moves the submitted
//  image from the pose it was drawn at to the pose at display time, and the
//  drawable's depth decides how far each pixel moves when the head
//  translates. Wrong depth is "jelly"; too near is violent.
//
//  With Renderer.reprojectionDepth on (Settings → Graphics, default off):
//
//  - Engine pixels: the composite writes the engine's own per-pixel depth,
//    converted to the compositor's convention (Shaders.metal
//    compositorDepth). Off: the old constant far depth, rotation only.
//  - Gun and body: WeaponPass keeps its depth buffer and this pass copies it
//    over the drawable's wherever they drew (reprojectionDepthMerge), since
//    they are what the eye sees there and they always draw on top.
//  - HUD holograms, UI arcs and the wireframe arms write no depth and keep
//    what is behind them: they are small, sit at arm's length, and rotation
//    — the bulk of reprojection — is exact whatever the depth.
//  - The engine's 2D layer (HUD numbers, console, menu) is in the engine's
//    image with the world's depth under it. While the menu is up the whole
//    frame takes the old constant depth (Renderer decides).
//  - The level-load snapshot keeps flattening to the constant depth: its
//    parallax is already drawn in (LoadSnapshot.encode explains the torn-edge
//    outlines real depth gave it).
//

import CompositorServices
import Metal

final class ReprojectionDepth {
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let fragmentTable: MTL4ArgumentTable

    init(device: MTLDevice, layerRenderer: LayerRenderer) {
        let library = device.makeDefaultLibrary()
        let d = MTLRenderPipelineDescriptor()
        d.label = "ReprojectionDepthMerge"
        d.vertexFunction = library?.makeFunction(name: "fullscreenVertexShader")
        d.fragmentFunction = library?.makeFunction(name: "reprojectionDepthMerge")
        d.rasterSampleCount = 1
        d.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        d.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        pipeline = try! device.makeRenderPipelineState(descriptor: d)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .always
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)!

        let t = MTL4ArgumentTableDescriptor()
        t.maxTextureBindCount = 1
        fragmentTable = try! device.makeArgumentTable(descriptor: t)
    }

    /// Copy `overlayDepth` (the weapon pass's depth, same size and layout as
    /// the drawable's) into the drawable's depth wherever it holds anything.
    /// Encoded after the weapon pass on the same command buffer.
    func encodeMerge(commandBuffer: MTL4CommandBuffer, drawable: LayerRenderer.Drawable,
                     overlayDepth: MTLTexture) {
        let rpd = MTL4RenderPassDescriptor()
        rpd.depthAttachment.texture = drawable.depthTextures[0]
        rpd.depthAttachment.loadAction = .load
        rpd.depthAttachment.storeAction = .store
        rpd.rasterizationRateMap = drawable.rasterizationRateMaps.first
        rpd.renderTargetArrayLength = drawable.views.count
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.label = "Reprojection depth merge"
        // After the weapon pass's depth writes and the composite's depth
        // resolve on this queue (Metal 4 tracks no hazards).
        enc.barrier(afterQueueStages: .all, beforeStages: [.vertex, .fragment], visibilityOptions: .device)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setViewports(drawable.views.map { $0.textureMap.viewport })
        if drawable.views.count > 1 {
            enc.setVertexAmplificationCount((0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            })
        }
        enc.setArgumentTable(fragmentTable, stages: .fragment)
        fragmentTable.setTexture(overlayDepth.gpuResourceID, index: 0)
        enc.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
