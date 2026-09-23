//
//  LoadSnapshot.swift
//  LambdaVision
//
//  Keeps the world in place while the engine loads a level.
//
//  A level change runs inside one engine frame (~100–140 ms on device, see
//  ISSUES.md), and the render loop used to wait for it: no frames went out,
//  so the headset held the last image to the face — a freeze. Now the frame
//  that starts a load is copied, colour and depth, with the pose it was
//  drawn from; the engine's next frames run without anyone waiting on them;
//  and every display frame redraws the copy from the current head pose
//  (SnapshotShaders.metal), so turning and leaning look right. When the
//  client is back in, the live view returns and the copy fades out over it.
//
//  Nothing here changes what the engine does or in what order: the load is
//  the stock one, it just no longer holds the display hostage.
//

import CompositorServices
import Metal
import simd

final class LoadSnapshot {
    enum Phase {
        case idle
        /// Showing the copy; the engine is loading.
        case holding(since: Double)
        /// The live view is back; the copy fades out over it.
        case fading(since: Double)
    }

    private(set) var phase: Phase = .idle
    /// Set when this frame's colorMap is to be copied: the pose the engine
    /// drew it from, per eye.
    private var pendingCapture: [(clipToWorld: float4x4, eye: SIMD4<Float>)]?
    private var capture: [(clipToWorld: float4x4, eye: SIMD4<Float>)] = []
    /// Mesh cells across and down the captured frame.
    private var pendingGrid = SIMD2<UInt32>(16, 16)
    private var grid = SIMD2<UInt32>(16, 16)
    /// Per eye: the engine's GL projection and the world → eye view, for the
    /// debug dump (vrdump format, read by Tools/SnapshotProbe --metres).
    private var pendingViews: [(projection: float4x4, view: float4x4)] = []
    private var dump: (views: [(projection: float4x4, view: float4x4)],
                       color: MTLBuffer, depth: MTLBuffer, width: Int, height: Int, frame: UInt64)?
    /// Debug: write the next capture to Caches/snapshot-eyeN.bin, for
    /// `Tools/SnapshotProbe --metres --reverse-z`. Off: ~190 MB of readback.
    static var dumpFirstCapture = false
    /// Readback buffers for that dump, allocated when the capture is armed
    /// so the frame can make them resident.
    private var dumpBuffers: (color: MTLBuffer, depth: MTLBuffer)?
    /// endFrameEvent value of the frame whose command buffer holds the copy:
    /// the engine may not draw into colorMap again before it completes.
    private(set) var captureFrame: UInt64 = 0

    /// Angular size of a mesh cell (the probe's tuning: fine enough that a
    /// torn cell at a depth edge does not read as a notch).
    static let cellDegrees: Float = 0.4
    static let tearRatio: Float = 1.08
    static let overscan: Float = 0.4
    static let fadeSeconds = 0.3
    /// A load that runs longer than this stops being held: the loop goes
    /// back to waiting on the engine (the old behaviour) rather than
    /// showing a stale room forever if something went wrong.
    static let maxHoldSeconds = 20.0

    private let device: MTLDevice
    private let meshPipeline: MTLRenderPipelineState
    private let backdropPipeline: MTLRenderPipelineState
    private let meshDepth: MTLDepthStencilState
    private let backdropDepth: MTLDepthStencilState
    private let flattenPipeline: MTLRenderPipelineState
    private let flattenDepth: MTLDepthStencilState
    private let vertexTable: MTL4ArgumentTable
    private let fragmentTable: MTL4ArgumentTable
    private let uniforms: [MTLBuffer]
    private(set) var color: MTLTexture?
    private(set) var depth: MTLTexture?
    /// The engine drew its depth into a texture we can read (ANGLE accepted
    /// it); without it the copy is held at infinity — turning is exact,
    /// leaning shows no parallax.
    var hasDepth = false

    init(device: MTLDevice, layerRenderer: LayerRenderer, slots: Int) {
        self.device = device
        let library = device.makeDefaultLibrary()
        func pipeline(_ vertex: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = "Snapshot " + vertex
            d.vertexFunction = library?.makeFunction(name: vertex)
            d.fragmentFunction = library?.makeFunction(name: "snapshotFragment")
            d.rasterSampleCount = device.rasterSampleCount
            d.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
            d.maxVertexAmplificationCount = layerRenderer.properties.viewCount
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        meshPipeline = pipeline("snapshotMeshVertex")
        backdropPipeline = pipeline("snapshotBackdropVertex")
        // Depth only: the live frame's constant far depth over the whole view.
        let fd = MTLRenderPipelineDescriptor()
        fd.label = "Snapshot depth flatten"
        fd.vertexFunction = library?.makeFunction(name: "fullscreenVertexShader")
        fd.rasterSampleCount = device.rasterSampleCount
        fd.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        fd.colorAttachments[0].writeMask = []
        fd.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        fd.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        flattenPipeline = try! device.makeRenderPipelineState(descriptor: fd)

        let md = MTLDepthStencilDescriptor()
        md.depthCompareFunction = .greater      // reverse-Z
        md.isDepthWriteEnabled = true
        meshDepth = device.makeDepthStencilState(descriptor: md)!
        let bd = MTLDepthStencilDescriptor()
        bd.depthCompareFunction = .always
        bd.isDepthWriteEnabled = false
        backdropDepth = device.makeDepthStencilState(descriptor: bd)!
        let fdd = MTLDepthStencilDescriptor()
        fdd.depthCompareFunction = .always
        fdd.isDepthWriteEnabled = true
        flattenDepth = device.makeDepthStencilState(descriptor: fdd)!

        let vt = MTL4ArgumentTableDescriptor()
        vt.maxBufferBindCount = 3               // uniforms@2
        vt.maxTextureBindCount = 2              // depth@1
        vertexTable = try! device.makeArgumentTable(descriptor: vt)
        let ft = MTL4ArgumentTableDescriptor()
        ft.maxBufferBindCount = 3
        ft.maxTextureBindCount = 1              // colour@0
        fragmentTable = try! device.makeArgumentTable(descriptor: ft)

        let stride = (MemoryLayout<SnapshotUniforms>.stride + 0xFF) & -0x100
        uniforms = (0..<slots).map { _ in
            device.makeBuffer(length: stride, options: .storageModeShared)!
        }
    }

    var isHolding: Bool { if case .holding = phase { return true }; return false }

    /// Snapshot textures the size of the engine's.
    func ensureTextures(colorMap: MTLTexture, engineDepth: MTLTexture) -> [MTLResource] {
        guard color == nil else { return [] }
        let cd = MTLTextureDescriptor()
        cd.textureType = .type2DArray
        cd.pixelFormat = colorMap.pixelFormat
        cd.width = colorMap.width; cd.height = colorMap.height
        cd.arrayLength = 2
        cd.usage = .shaderRead
        cd.storageMode = .private
        color = device.makeTexture(descriptor: cd)
        color?.label = "LoadSnapshotColor"
        cd.pixelFormat = engineDepth.pixelFormat
        depth = device.makeTexture(descriptor: cd)
        depth?.label = "LoadSnapshotDepth"
        return [color!, depth!]
    }

    /// The engine just started a load: copy this frame (encoded by the next
    /// `encodeCapture`) and hold it until the load is done. `views` are the
    /// drawable views and `anchor` the pose the engine drew this frame from.
    func arm(views: [LayerRenderer.Drawable.View], anchor: float4x4,
             zNear: Float, zFar: Float, now: Double) {
        let n = zNear / 39.37, f = zFar / 39.37
        if Self.dumpFirstCapture, dumpBuffers == nil, let color {
            let bytes = color.width * color.height * 4 * 2
            if let cb = device.makeBuffer(length: bytes, options: .storageModeShared),
               let db = device.makeBuffer(length: bytes, options: .storageModeShared) {
                dumpBuffers = (cb, db)
            }
        }
        pendingViews = []
        pendingCapture = views.map { view in
            let eye = anchor * view.transform
            let t = view.tangents   // left, right, top, bottom
            let l = -t.x * n, r = t.y * n, top = t.z * n, b = -t.w * n
            // The engine's own projection (Lambda_Bridge.c
            // lambda_engine_set_projection_tangents), in metres.
            let p = float4x4(columns: (
                SIMD4(2 * n / (r - l), 0, 0, 0),
                SIMD4(0, 2 * n / (top - b), 0, 0),
                SIMD4((r + l) / (r - l), (top + b) / (top - b), -(f + n) / (f - n), -1),
                SIMD4(0, 0, -2 * f * n / (f - n), 0)))
            pendingViews.append((p, eye.inverse))
            return (eye * p.inverse, eye.columns.3)
        }
        // Cells of about cellDegrees across the frame's field of view.
        if let t = views.first?.tangents {
            let degrees = { (a: Float, b: Float) in (atanf(a) + atanf(b)) * 180 / .pi }
            pendingGrid = SIMD2(UInt32(ceilf(degrees(t.x, t.y) / Self.cellDegrees)),
                                UInt32(ceilf(degrees(t.z, t.w) / Self.cellDegrees)))
        }
        phase = .holding(since: now)
    }

    /// Copies colorMap and the engine's depth into the snapshot, into the
    /// frame's command buffer before its render passes. `frame` is the
    /// endFrameEvent value this command buffer signals.
    func encodeCapture(commandBuffer: MTL4CommandBuffer, colorMap: MTLTexture,
                       engineDepth: MTLTexture, frame: UInt64) {
        guard let pose = pendingCapture, let color, let depth,
              let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        pendingCapture = nil
        capture = pose
        grid = pendingGrid
        captureFrame = frame
        let size = MTLSize(width: colorMap.width, height: colorMap.height, depth: 1)
        for (src, dst) in [(colorMap, color), (engineDepth, depth)] {
            for slice in 0..<2 {
                enc.copy(sourceTexture: src, sourceSlice: slice, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(), sourceSize: size,
                         destinationTexture: dst, destinationSlice: slice,
                         destinationLevel: 0, destinationOrigin: MTLOrigin())
            }
        }
        if Self.dumpFirstCapture {
            Self.dumpFirstCapture = false
            let w = colorMap.width, h = colorMap.height, image = w * h * 4
            if let (cb, db) = dumpBuffers {
                for slice in 0..<2 {
                    enc.copy(sourceTexture: colorMap, sourceSlice: slice, sourceLevel: 0,
                             sourceOrigin: MTLOrigin(), sourceSize: size,
                             destinationBuffer: cb, destinationOffset: slice * image,
                             destinationBytesPerRow: w * 4, destinationBytesPerImage: image)
                    enc.copy(sourceTexture: engineDepth, sourceSlice: slice, sourceLevel: 0,
                             sourceOrigin: MTLOrigin(), sourceSize: size,
                             destinationBuffer: db, destinationOffset: slice * image,
                             destinationBytesPerRow: w * 4, destinationBytesPerImage: image,
                             options: .depthFromDepthStencil)
                }
                dump = (pendingViews, cb, db, w, h, frame)
            }
        }
        enc.barrier(afterStages: .blit, beforeQueueStages: .all, visibilityOptions: .device)
        enc.endEncoding()
    }

    /// Writes the debug dump once the GPU has finished the capture frame.
    func flushDump(completedFrame: UInt64) {
        guard let d = dump, completedFrame >= d.frame else { return }
        dump = nil
        dumpBuffers = nil
        DispatchQueue.global(qos: .utility).async {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let image = d.width * d.height * 4
            for (eye, v) in d.views.enumerated() where eye < 2 {
                var out = Data()
                for x in [Int32(0x4452_5656), 1, Int32(d.width), Int32(d.height)] { withUnsafeBytes(of: x) { out.append(contentsOf: $0) } }
                for m in [v.projection, v.view] {
                    for c in 0..<4 { for r in 0..<4 { withUnsafeBytes(of: m[c][r]) { out.append(contentsOf: $0) } } }
                }
                out.append(Data(count: 24))   // view origin + angles: unused
                // BGRA → RGBA
                var rgba = Data(bytes: d.color.contents() + eye * image, count: image)
                rgba.withUnsafeMutableBytes { p in
                    let b = p.bindMemory(to: UInt8.self)
                    for i in stride(from: 0, to: image, by: 4) { b.swapAt(i, i + 2) }
                }
                out.append(rgba)
                out.append(Data(bytes: d.depth.contents() + eye * image, count: image))
                try? out.write(to: dir.appendingPathComponent("snapshot-eye\(eye).bin"))
            }
            AppLog.render.line("[LoadSnapshot] wrote debug dump to Caches/snapshot-eye0/1.bin")
        }
    }

    /// The load is over and the live view is back: fade the copy out.
    func release(now: Double) { phase = .fading(since: now) }

    /// Stop showing the copy at once.
    func drop() { phase = .idle; pendingCapture = nil }

    /// Opacity of the copy this frame, or nil when there is nothing to draw.
    func alpha(now: Double) -> Float? {
        switch phase {
        case .idle: return nil
        case .holding: return 1
        case .fading(let since):
            let t = (now - since) / Self.fadeSeconds
            if t >= 1 { phase = .idle; return nil }
            return Float(1 - t)
        }
    }

    /// Draws the copy into the primary pass, over whatever it already holds.
    /// `viewProjections` are the current world → clip matrices per view.
    func encode(encoder: MTL4RenderCommandEncoder, viewProjections: [float4x4],
                slot: Int, alpha: Float) {
        guard capture.count == viewProjections.count, let color, let depth else { return }
        var u = SnapshotUniforms()
        u.captureClipToWorld = (capture[0].clipToWorld, capture[min(1, capture.count - 1)].clipToWorld)
        u.worldToClip = (viewProjections[0], viewProjections[min(1, viewProjections.count - 1)])
        u.captureEye = (capture[0].eye, capture[min(1, capture.count - 1)].eye)
        u.grid = grid
        u.eyeBase = 0
        u.flipV = 1
        // Just inside the reverse-Z far plane: exactly 0 sits on the clip
        // boundary and the backdrop is clipped away, leaving torn edges black.
        u.farZ = 0.0001
        u.tearRatio = hasDepth ? Self.tearRatio : .infinity
        u.alpha = alpha
        u.minDistance = 0.1
        u.overscan = Self.overscan

        let buffer = uniforms[slot % uniforms.count]
        buffer.contents().storeBytes(of: u, as: SnapshotUniforms.self)

        // The copy was made by an earlier command buffer on this queue.
        encoder.barrier(afterQueueStages: .all, beforeStages: [.vertex, .fragment], visibilityOptions: .device)
        encoder.setArgumentTable(vertexTable, stages: .vertex)
        encoder.setArgumentTable(fragmentTable, stages: .fragment)
        vertexTable.setAddress(buffer.gpuAddress, index: BufferIndex.uniforms.rawValue)
        vertexTable.setTexture(depth.gpuResourceID, index: 1)
        fragmentTable.setAddress(buffer.gpuAddress, index: BufferIndex.uniforms.rawValue)
        fragmentTable.setTexture(color.gpuResourceID, index: TextureIndex.color.rawValue)

        let vertices = Int(grid.x * grid.y) * 6
        encoder.setRenderPipelineState(backdropPipeline)
        encoder.setDepthStencilState(backdropDepth)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: vertices)
        if hasDepth {
            encoder.setRenderPipelineState(meshPipeline)
            encoder.setDepthStencilState(meshDepth)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: vertices)
        }
        // The compositor re-warps what we submit by its depth. The mesh's
        // depth next to the backdrop's "infinitely far" tears opened gaps
        // along every torn edge — black outlines on each head move. The
        // parallax is already drawn in; hand it the live frame's constant
        // far depth so it only corrects for rotation, as it does live.
        encoder.setRenderPipelineState(flattenPipeline)
        encoder.setDepthStencilState(flattenDepth)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func residentResources(slot: Int) -> [MTLResource] {
        [uniforms[slot % uniforms.count]] + [color, depth, dumpBuffers?.color, dumpBuffers?.depth].compactMap { $0 }
    }
}
