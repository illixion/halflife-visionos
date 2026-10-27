//
//  ProgressivePass.swift
//  LambdaVision
//
//  Progressive immersion (the Digital Crown dial: a portal into the game with
//  passthrough around it) makes the compositor's drawable render context
//  mandatory: the first present aborts without it ("need to use drawable
//  render context when supporting progressive style"). The context masks the
//  portal into a stencil attachment and draws its edge effects at the end of
//  an encoder the app hands it.
//
//  The game's own passes don't use the mask, so the context gets a pass of
//  its own at the very end of the frame: the drawable's colour and depth
//  loaded and stored as they are, a memoryless stencil. The mask goes in
//  first, then one fullscreen triangle that fails the stencil test inside
//  the portal and writes transparent black outside it, then the system draws
//  the portal's edge and ends the pass. Without that erase the composite
//  pass's opaque black over the pixels it has no engine image for (outside
//  the portal, where the compositor's rate map spends nothing) shows as a
//  black void instead of the room. Single-sample, which is also what the
//  layer is configured with (`ImmersiveSpaceContent.makeConfiguration`).
//
//  Oneiros parked its progressive mode after a stuck partial portal on
//  device; see its KNOWN_ISSUES.md. The first thing to rule out there was a
//  frame without a device anchor, which the context masks against.
//

import CompositorServices
import Metal

final class ProgressivePass {
    private var stencil: MTLTexture?
    private var erasePipeline: MTLRenderPipelineState?
    private var eraseDepthStencil: MTLDepthStencilState?

    /// The stencil formats the compositor offers, best first, for the layer
    /// configuration; nil when it offers none (the space then stays full).
    static func stencilFormat(for capabilities: LayerRenderer.Capabilities) -> MTLPixelFormat? {
        let formats = capabilities.drawableRenderContextSupportedStencilFormats
        guard !formats.isEmpty else { return nil }
        return formats.contains(.stencil8) ? .stencil8 : formats[0]
    }

    /// Whether the layer was configured for a render context.
    static func isActive(_ layerRenderer: LayerRenderer) -> Bool {
        layerRenderer.configuration.drawableRenderContextStencilFormat != .invalid
            && layerRenderer.configuration.layout == .layered
    }

    private func stencilTexture(device: MTLDevice, format: MTLPixelFormat, like color: MTLTexture,
                                slices: Int) -> MTLTexture? {
        if let stencil, stencil.pixelFormat == format, stencil.width == color.width,
           stencil.height == color.height, stencil.arrayLength == slices {
            return stencil
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = format
        d.width = color.width
        d.height = color.height
        d.arrayLength = slices
        d.usage = .renderTarget
        d.storageMode = .memoryless
        d.sampleCount = 1
        stencil = device.makeTexture(descriptor: d)
        stencil?.label = "Progressive mask stencil"
        return stencil
    }

    private func prepareErase(layerRenderer: LayerRenderer, format: MTLPixelFormat, device: MTLDevice) -> Bool {
        if erasePipeline != nil, eraseDepthStencil != nil { return true }
        guard let library = device.makeDefaultLibrary() else { return false }
        let p = MTLRenderPipelineDescriptor()
        p.label = "ProgressiveErase"
        p.vertexFunction = library.makeFunction(name: "fullscreenVertexShader")
        p.fragmentFunction = library.makeFunction(name: "progressiveEraseFragment")
        p.rasterSampleCount = 1
        p.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        p.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        p.stencilAttachmentPixelFormat = format
        p.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        erasePipeline = try? device.makeRenderPipelineState(descriptor: p)
        let s = MTLStencilDescriptor()
        s.stencilCompareFunction = .notEqual
        s.stencilFailureOperation = .keep
        s.depthFailureOperation = .keep
        s.depthStencilPassOperation = .keep
        s.readMask = 0xFF
        s.writeMask = 0
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .always
        d.isDepthWriteEnabled = false
        d.frontFaceStencil = s
        d.backFaceStencil = s
        eraseDepthStencil = device.makeDepthStencilState(descriptor: d)
        return erasePipeline != nil && eraseDepthStencil != nil
    }

    /// The frame's last pass. `context` came from `drawable.addRenderContext()`,
    /// called after the drawable's device anchor was set.
    func encode(commandBuffer: MTL4CommandBuffer, drawable: LayerRenderer.Drawable,
                context: LayerRenderer.Drawable.RenderContext, layerRenderer: LayerRenderer) {
        let format = layerRenderer.configuration.drawableRenderContextStencilFormat
        let color = drawable.colorTextures[0]
        guard let stencil = stencilTexture(device: color.device, format: format, like: color,
                                           slices: drawable.views.count) else { return }
        let d = MTL4RenderPassDescriptor()
        d.colorAttachments[0].texture = color
        d.colorAttachments[0].loadAction = .load
        d.colorAttachments[0].storeAction = .store
        d.depthAttachment.texture = drawable.depthTextures[0]
        d.depthAttachment.loadAction = .load
        d.depthAttachment.storeAction = .store
        d.stencilAttachment.texture = stencil
        d.stencilAttachment.loadAction = .clear
        d.stencilAttachment.clearStencil = 0
        d.stencilAttachment.storeAction = .dontCare
        d.rasterizationRateMap = drawable.rasterizationRateMaps.first
        d.renderTargetArrayLength = drawable.views.count
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: d) else { return }
        enc.label = "Progressive render context"
        context.drawMaskOnStencilAttachment(commandEncoder: enc, value: 1)
        // The mask draw clobbers the encoder's state: set it all again.
        if prepareErase(layerRenderer: layerRenderer, format: format, device: color.device),
           let erasePipeline, let eraseDepthStencil {
            enc.setRenderPipelineState(erasePipeline)
            enc.setDepthStencilState(eraseDepthStencil)
            enc.setStencilReferenceValue(1)
            enc.setCullMode(.none)
            enc.setViewports(drawable.views.map { $0.textureMap.viewport })
            if drawable.views.count > 1 {
                enc.setVertexAmplificationCount((0..<drawable.views.count).map {
                    MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                      renderTargetArrayIndexOffset: UInt32($0))
                })
            }
            enc.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }
        context.endEncoding(commandEncoder: enc)
    }
}
