//
//  Renderer.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import CompositorServices
import Metal
import MetalKit
import simd

// The 256 byte aligned size of our uniform structure
nonisolated let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
nonisolated let alignedViewProjectionArraySize = (MemoryLayout<ViewProjectionArray>.size + 0xFF) & -0x100

nonisolated let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}

extension MTLDevice {
    nonisolated var supportsMSAA: Bool {
        supports32BitMSAA && supportsTextureSampleCount(4)
    }

    nonisolated var rasterSampleCount: Int {
        supportsMSAA ? 4 : 1
    }
}

extension LayerRenderer.Clock.Instant {
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

final class RendererTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
          job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    static var shared: RendererTaskExecutor = RendererTaskExecutor()
}

actor Renderer {

    let device: MTLDevice
    let commandQueue: MTL4CommandQueue
    let commandBuffer: MTL4CommandBuffer
    let commandAllocators: [MTL4CommandAllocator]
    let vertexArgumentTable: MTL4ArgumentTable
    let fragmentArgumentTable: MTL4ArgumentTable
    #if !targetEnvironment(simulator)
    let residencySets: [MTLResidencySet]
    let commandQueueResidencySet: MTLResidencySet
    #endif

    let dynamicUniformBuffer: MTLBuffer
    let pipelineState: MTLRenderPipelineState
    let fullscreenPipelineState: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let colorMap: MTLTexture        // 2-layer array (layer 0 = left eye, 1 = right)
    let colorMapLayerViews: [MTLTexture] // per-slice 2D views handed to ANGLE
    private var engineInited = false

    let endFrameEvent: MTLSharedEvent
    var committedFrameIndex: UInt64 = 0

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<Uniforms>

    var perDrawableTarget = [LayerRenderer.Drawable.Target: DrawableTarget]()

    var rotation: Float = 0

    var mesh: MTKMesh

    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    let appModel: AppModel
    // Head yaw at the first valid sample. Only yaw needs a baseline:
    // pitch and roll are sent to the engine as absolute values (they
    // replace the game's), while yaw is sent as a delta from this
    // baseline so the game's spawn orientation and keyboard turning
    // remain in effect.
    private var headBaselineYaw: Float? = nil
    // Head position (xash basis, meters) captured together with the yaw
    // baseline; physical movement is delivered as a delta from here.
    private var headBaselinePos: SIMD3<Float>? = nil

    init(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.appModel = appModel

        let device = self.device
        self.commandQueue = layerRenderer.commandQueue
        self.commandBuffer = device.makeCommandBuffer()!
        self.commandAllocators = (0...maxBuffersInFlight).map { _ in device.makeCommandAllocator()! }

        let argTableDesc = MTL4ArgumentTableDescriptor()
        argTableDesc.maxBufferBindCount = 4
        self.vertexArgumentTable = try! device.makeArgumentTable(descriptor: argTableDesc)
        argTableDesc.maxBufferBindCount = 0
        argTableDesc.maxTextureBindCount = 1
        self.fragmentArgumentTable = try! device.makeArgumentTable(descriptor: argTableDesc)

        #if !targetEnvironment(simulator)
        let residencySetDesc = MTLResidencySetDescriptor()
        residencySetDesc.initialCapacity = 3 // color + depth + view projection buffer
        self.residencySets = (0...maxBuffersInFlight).map { _ in try! device.makeResidencySet(descriptor: residencySetDesc) }
        #endif

        self.endFrameEvent = device.makeSharedEvent()!
        // Start the signal value + committed frames index at
        // max buffers in flight to avoid negative values
        self.endFrameEvent.signaledValue = UInt64(maxBuffersInFlight)
        committedFrameIndex = UInt64(maxBuffersInFlight)

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(length: uniformBufferSize,
                                                           options: [MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to: Uniforms.self, capacity: 1)

        let mtlVertexDescriptor = Self.buildMetalVertexDescriptor()

        do {
            pipelineState = try Self.buildRenderPipeline(device: device,
                                                         layerRenderer: layerRenderer,
                                                         mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        do {
            fullscreenPipelineState = try Self.buildFullscreenPipeline(device: device,
                                                                       layerRenderer: layerRenderer)
        } catch {
            fatalError("Unable to compile fullscreen pipeline state. Error info: \(error)")
        }

        self.depthState = Self.buildDepthStencilState(device: device)

        do {
            mesh = try Self.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to build MetalKit Mesh. Error info: \(error)")
        }

        do {
            colorMap = try Self.makeVulkanColorMap(device: device)
        } catch {
            fatalError("Unable to build Vulkan colorMap. Error info: \(error)")
        }

        // 2D slice views (one per eye) over the 2D-array colorMap. ANGLE/Metal
        // interop wraps these as plain 2D MTLTextures so the existing
        // EGL_METAL_TEXTURE_ANGLE path keeps working unchanged. Writes through
        // a view land in the underlying array slice, which the display shader
        // samples via texture2d_array.
        let cm = colorMap
        colorMapLayerViews = (0..<2).map { slice in
            cm.makeTextureView(pixelFormat: cm.pixelFormat,
                               textureType: .type2D,
                               levels: 0..<1,
                               slices: slice..<(slice + 1))!
        }

        #if !targetEnvironment(simulator)
        // Add all persistent resources to the command queue residency set,
        // must be done after loading all resources.
        residencySetDesc.initialCapacity = mesh.vertexBuffers.count + mesh.submeshes.count + 2 // color map + uniforms buffer
        let residencySet = try! self.device.makeResidencySet(descriptor: residencySetDesc)
        residencySet.addAllocations(mesh.vertexBuffers.map { $0.buffer })
        residencySet.addAllocations(mesh.submeshes.map { $0.indexBuffer.buffer })
        residencySet.addAllocations([colorMap, dynamicUniformBuffer])
        residencySet.commit()
        commandQueueResidencySet = residencySet
        commandQueue.addResidencySet(residencySet)
        #endif

        worldTracking = WorldTrackingProvider()
    }

    private func startARSession(_ arSession: ARKitSession) async {
        do {
            try await arSession.run([worldTracking])
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, arSession: ARKitSession) {
        Task(executorPreference: RendererTaskExecutor.shared) {
            let renderer = Renderer(layerRenderer, appModel: appModel)
            await renderer.startARSession(arSession)
            await renderer.renderLoop()
        }
    }

    static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    static func buildRenderPipeline(device: MTLDevice,
                                    layerRenderer: LayerRenderer,
                                    mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = device.rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // Fullscreen pipeline: 3-vertex triangle covering [-1,1]², no vertex
    // buffers, no model uniforms. Samples colorMap per-eye via amp_id and
    // writes to the drawable's color slice for that eye (via amplification).
    // Replaces the plane-mesh sampler — colorMap now fills the entire
    // headset eye viewport, which (combined with per-eye AVP tangents) is
    // the fully-immersive path.
    static func buildFullscreenPipeline(device: MTLDevice,
                                        layerRenderer: LayerRenderer) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "FullscreenPipeline"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertexShader")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "fragmentShader")
        pipelineDescriptor.rasterSampleCount = device.rasterSampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    static func buildDepthStencilState(device: MTLDevice) -> MTLDepthStencilState {
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptor.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    static func buildMesh(device: MTLDevice,
                          mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        // Single flat plane (no side/back faces) so both eyes always see
        // the same texture region. With a box, each eye sees slivers of
        // different side faces, making 2D engine artifacts (HUD glyphs,
        // intro text) appear in different positions per eye.
        // newPlane lays the mesh in XZ; updateGameState rotates 90° around
        // X so the plane faces -Z (toward the viewer).
        let mdlMesh = MDLMesh.newPlane(withDimensions: SIMD2<Float>(4, 4),
                                       segments: SIMD2<UInt32>(1, 1),
                                       geometryType: MDLGeometryType.triangles,
                                       allocator: metalAllocator)

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh: mdlMesh, device: device)
    }

    enum VulkanColorMapError: Error {
        case deviceInit(Int32)
        case clearFailed(String)
        case wrapFailed
    }

    // Matches AVP drawable's native per-eye resolution (~2048² with some
    // headroom). 1024² was the previous value, chosen when the engine was
    // sampled onto a small floating plane; with the fullscreen-quad
    // immersive display, every colorMap texel maps to roughly one
    // drawable fragment, so we need the source at native resolution to
    // avoid visible blur. 4× the fragment work for the engine GL renderer.
    static let vulkanColorMapSize = 2048

    /// Phase 2 step 2/3: produce a colorMap whose pixels are rendered by
    /// Vulkan into an IOSurface (rgba16Float), imported by Metal. Uses the
    /// pooled bridge API at (slot=0, eye=0) so render() can re-render the
    /// same IOSurface in-place each frame.
    static func makeVulkanColorMap(device: MTLDevice) throws -> MTLTexture {
        // Smoke test removed: its eglTerminate appears to poison ANGLE's
        // process-global state on visionOS, breaking the subsequent
        // persistent context. The persistent setup below is itself a
        // sufficient probe.

        // ANGLE/Metal on visionOS can't migrate the EGL context across
        // OS threads, and Swift's task executor moves us between threads.
        // Spin up a dedicated worker pthread that owns the context for
        // the rest of the process and serves all GL work synchronously.
        var workerStatus = [CChar](repeating: 0, count: 384)
        let workerRc = workerStatus.withUnsafeMutableBufferPointer { buf in
            lambda_gl_worker_setup(buf.baseAddress, Int32(buf.count))
        }
        print("[LambdaVision] gl-worker setup rc=\(workerRc): \(String(cString: workerStatus))")

        var devStatus = [CChar](repeating: 0, count: 384)
        let rc = devStatus.withUnsafeMutableBufferPointer { buf in
            lambda_vulkan_create_device(buf.baseAddress, Int32(buf.count))
        }
        if rc != 0 { throw VulkanColorMapError.deviceInit(rc) }

        // Option A: drop the Vulkan colorMap entirely. ANGLE renders into a
        // Swift-allocated MTLTexture each frame; the existing Metal pipeline
        // samples it just like before. Same scaffolding, GL is now the only
        // pixel producer for the colorMap.
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .bgra8Unorm
        desc.width = vulkanColorMapSize
        desc.height = vulkanColorMapSize
        desc.arrayLength = 2
        desc.mipmapLevelCount = 1
        desc.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        desc.storageMode = .private

        guard let tex = device.makeTexture(descriptor: desc) else {
            throw VulkanColorMapError.wrapFailed
        }
        tex.label = "AngleColorMap"
        print("[LambdaVision] GL colorMap: \(vulkanColorMapSize)x\(vulkanColorMapSize) bgra8Unorm via ANGLE")
        return tex
    }

    static func loadTexture(device: MTLDevice,
                            textureName: String) throws -> MTLTexture {
        /// Load texture data with optimal parameters for sampling

        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
        ]

        return try textureLoader.newTexture(name: textureName,
                                            scaleFactor: 1.0,
                                            bundle: nil,
                                            options: textureLoaderOptions)
    }

    private func ensureEngineInitialized() {
        guard !engineInited else { return }
        engineInited = true
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        let basedir = (appSupport as NSString).appendingPathComponent("xash3d")
        let rodir = (Bundle.main.resourcePath ?? "") + "/GameData"
        let extra = ["-dev", "2", "-console", "-noip", "-rodir", rodir, "-game", "valve",
                     "+map", "c1a0"]
        let cArgs = extra.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var buf = [CChar](repeating: 0, count: 384)
        // Runs on the GL worker thread that owns the EGL context.
        let rc = basedir.withCString { dir -> Int32 in
            cArgs.withUnsafeBufferPointer { argv -> Int32 in
                let argvPtrs = argv.baseAddress?.withMemoryRebound(
                    to: UnsafePointer<CChar>?.self, capacity: argv.count) { $0 }
                return buf.withUnsafeMutableBufferPointer { b in
                    lambda_gl_worker_engine_init(dir, Int32(extra.count), argvPtrs,
                                                 b.baseAddress, Int32(b.count))
                }
            }
        }
        print("[LambdaVision] Engine: rc=\(rc) \(String(cString: buf))")
    }

    private func updateDynamicBufferState(frameIndex: UInt64) {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to: Uniforms.self, capacity: 1)

        /// Reset resources used in previous frame

        #if !targetEnvironment(simulator)
        residencySets[uniformBufferIndex].removeAllAllocations()
        residencySets[uniformBufferIndex].commit()
        #endif
        commandAllocators[uniformBufferIndex].reset()

        /// Remove all per drawable target resources that are older than 90 frames

        perDrawableTarget = perDrawableTarget.filter { $0.value.lastUsedFrameIndex + 90 > frameIndex }
    }

    private func updateGameState() {
        /// Update any game state before rendering

        // Plane mesh lies flat in XZ; tilt it up so its surface faces -Z
        // (toward the viewer). Then translate out 8 units in front.
        let tilt = matrix4x4_rotation(radians: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let translate = matrix4x4_translation(0.0, 0.0, -8.0)
        self.uniforms[0].modelMatrix = translate * tilt
    }

    private func copyEyeSlice(from src: Int, to dst: Int) {
        commandBuffer.beginCommandBuffer(allocator: commandAllocators[uniformBufferIndex])
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.copy(sourceTexture: colorMap, sourceSlice: src, sourceLevel: 0,
                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                 sourceSize: MTLSize(width: colorMap.width,
                                     height: colorMap.height, depth: 1),
                 destinationTexture: colorMap,
                 destinationSlice: dst, destinationLevel: 0,
                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        enc.endEncoding()
        commandBuffer.endCommandBuffer()
        commandQueue.commit([commandBuffer])
    }

    func renderFrame() {
        /// Per frame updates hare

        guard let frame = layerRenderer.queryNextFrame() else { return }

        guard self.endFrameEvent.wait(untilSignaledValue: committedFrameIndex - UInt64(maxBuffersInFlight), timeoutMS: 10000) else {
            return
        }

        frame.startUpdate()

        // Perform frame independent work

        self.updateDynamicBufferState(frameIndex: frame.frameIndex)

        self.updateGameState()

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        frame.startSubmission()

        // Tick the engine ONCE per real frame and write to colorMap once.
        // Without this, each drawable in the loop below would re-tick the
        // engine (running it at 2× speed) and the eyes would sample
        // different moments in time — visible as per-eye divergent
        // transients (e.g. HUD glyphs, particles).
        ensureEngineInitialized()
        // Each eye is rendered with AVP's actual asymmetric frustum
        // (drawable.views[i].tangents) so the engine output matches what
        // the headset wants to display. The plane-display pass below still
        // resamples colorMap onto a small floating plane — fixing the
        // engine projection on its own won't make this immersive, but it's
        // the foundation: once we swap the plane for a fullscreen blit,
        // the per-eye images will stereo-fuse correctly only because each
        // was rendered through the matching frustum.
        // zNear/zFar in xash world units (HL inches ≈ 39.37/meter).
        let zNear: Float = 4.0
        let zFar:  Float = 4096.0
        // Use the first drawable's tangents (built-in target). Capture
        // target may have different tangents but for now match builtIn.
        let primary = drawables.first { $0.target == .builtIn } ?? drawables[0]
        // Apple→xash unit scale (HL inches per meter).
        let appleToXash: Float = 39.37

        // Head-tracked viewangles. Query at the drawable's presentation
        // time so the engine renders from where the head will be when
        // photons hit the user, not where it was when we started this
        // frame. queryDeviceAnchor may return nil during a tracking
        // dropout; we skip the override in that case so mouse-look still
        // works as a fallback.
        // Build the head's rotation matrix in xash basis (+X forward,
        // +Y left, +Z up). Columns are head's forward/left/up vectors,
        // each derived from the head transform's basis vectors in Apple
        // coords and converted via apple(x,y,z) → xash(-z,-x,y).
        // Query the anchor ONCE and use it for both the game camera and
        // drawable.deviceAnchor. Re-querying at present time yields a
        // fresher estimate for the same target timestamp; the compositor
        // then reprojects assuming the image matches the newer pose, and
        // the mismatch shows up as overshoot/snap-back during head motion.
        let presentTime = primary.frameTiming.presentationTime.timeInterval
        let frameDeviceAnchor: DeviceAnchor? =
            worldTracking.state == .running
                ? worldTracking.queryDeviceAnchor(atTimestamp: presentTime)
                : nil
        let headPose: (rot: simd_float3x3, pos: SIMD3<Float>)? = {
            guard let anchor = frameDeviceAnchor else { return nil }
            let m = anchor.originFromAnchorTransform
            // Apple-basis head axes: forward = -col2, up = +col1, right = +col0.
            let fwdA   = SIMD3<Float>(-m.columns.2.x, -m.columns.2.y, -m.columns.2.z)
            let upA    = SIMD3<Float>( m.columns.1.x,  m.columns.1.y,  m.columns.1.z)
            let rightA = SIMD3<Float>( m.columns.0.x,  m.columns.0.y,  m.columns.0.z)
            func a2x(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-v.z, -v.x, v.y) }
            let fwdX  = a2x(fwdA)
            let upX   = a2x(upA)
            let leftX = -a2x(rightA)  // xash +Y = left
            let posX  = a2x(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
            return (simd_float3x3(fwdX, leftX, upX), posX)
        }()

        // Decompose the ABSOLUTE head orientation into the engine's own
        // Euler order. xash builds its view as R = Rz(yaw)·Ry(pitch)·Rx(roll)
        // with fwd = (cp·cy, cp·sy, -sp), left.z = sr·cp, up.z = cr·cp
        // (see AngleVectors in xash3d_mathlib.h), which inverts exactly to:
        //   yaw   = atan2(fwd.y, fwd.x)
        //   pitch = atan2(-fwd.z, |fwd.xy|)
        //   roll  = atan2(left.z, up.z)
        // Pitch and roll are fed to the engine as absolutes; yaw as a
        // delta from the baseline. Because yaw composes on the left in
        // this Euler order, gameYaw + Δyaw reproduces the head rotation
        // exactly — compound moves (turn left, then look up) stay pure,
        // with no roll leakage and nothing to drift.
        var headAngles: SIMD3<Float>? = nil  // (abs pitch, delta yaw, abs roll) deg
        var headOffset = SIMD3<Float>(0, 0, 0)  // baseline-forward frame, xash units
        if let cur = headPose {
            let fwd  = cur.rot.columns.0
            let left = cur.rot.columns.1
            let up   = cur.rot.columns.2
            let rad2deg: Float = 180.0 / .pi
            let horizLen = sqrtf(fwd.x * fwd.x + fwd.y * fwd.y)
            let pitchDeg = atan2f(-fwd.z, horizLen) * rad2deg
            let yawDeg   = atan2f(fwd.y, fwd.x) * rad2deg
            let rollDeg  = atan2f(left.z, up.z) * rad2deg
            if headBaselineYaw == nil {
                headBaselineYaw = yawDeg
                headBaselinePos = cur.pos
            }
            var dyaw = yawDeg - headBaselineYaw!
            if dyaw > 180 { dyaw -= 360 } else if dyaw < -180 { dyaw += 360 }
            headAngles = SIMD3<Float>(pitchDeg, dyaw, rollDeg)

            // Positional tracking: room-space translation since baseline,
            // re-expressed in the baseline-forward frame (rotate by
            // -baselineYaw about Z) so the engine can map it into the game
            // world with the player's yaw. Scaled meters → xash units.
            let d = (cur.pos - headBaselinePos!) * appleToXash
            let baseRad = headBaselineYaw! * .pi / 180.0
            let s = sinf(baseRad), c = cosf(baseRad)
            headOffset = SIMD3<Float>(d.x * c + d.y * s, -d.x * s + d.y * c, d.z)
        }

        for eye in 0..<2 {
            // Per-eye position in head-local space, X = right (meters).
            // view[0] vs [1] left/right ordering isn't formally guaranteed,
            // so reading the actual x value auto-derives the sign instead
            // of assuming view[0] = left eye.
            let eyeApple_x = primary.views[eye].transform.columns.3.x
            let off: Float = eyeApple_x * appleToXash
            let eyePtr = Unmanaged.passUnretained(colorMapLayerViews[eye]).toOpaque()
            var tang = primary.views[eye].tangents  // (left, right, top, bottom)
            let rc: Int32 = withUnsafePointer(to: &tang) { tp in
                tp.withMemoryRebound(to: Float.self, capacity: 4) { fp -> Int32 in
                    if var angles = headAngles {
                        var offset = headOffset
                        return withUnsafePointer(to: &angles) { ap in
                            ap.withMemoryRebound(to: Float.self, capacity: 3) { afp in
                                withUnsafePointer(to: &offset) { op in
                                    op.withMemoryRebound(to: Float.self, capacity: 3) { ofp in
                                        lambda_gl_worker_render_eye_full(
                                            Int32(eye), off,
                                            fp, zNear, zFar, afp, ofp,
                                            eyePtr, Int32(colorMap.width), Int32(colorMap.height),
                                            0.1, 0.1, 0.1)
                                    }
                                }
                            }
                        }
                    } else {
                        return lambda_gl_worker_render_eye_tangents(
                            Int32(eye), off,
                            fp, zNear, zFar,
                            eyePtr, Int32(colorMap.width), Int32(colorMap.height),
                            0.1, 0.1, 0.1)
                    }
                }
            }
            if rc != 0 {
                print("[LambdaVision] GL worker render eye=\(eye) rc=\(rc)")
            }
        }

        for drawable in drawables {
            render(drawable: drawable, frameIndex: frame.frameIndex,
                   deviceAnchor: frameDeviceAnchor)
        }

        committedFrameIndex += 1

        commandQueue.signalEvent(self.endFrameEvent, value: committedFrameIndex)

        frame.endSubmission()
    }

    func render(drawable: LayerRenderer.Drawable, frameIndex: UInt64,
                deviceAnchor: DeviceAnchor?) {
        // Must be the SAME anchor the engine camera rendered with — the
        // compositor reprojects the image from this pose to display time.
        drawable.deviceAnchor = deviceAnchor

        if perDrawableTarget[drawable.target] == nil {
            perDrawableTarget[drawable.target] = .init(drawable: drawable)
        }
        let drawableTarget = perDrawableTarget[drawable.target]!

        drawableTarget.updateBufferState(uniformBufferIndex: uniformBufferIndex, frameIndex: frameIndex)

        drawableTarget.updateViewProjectionArray(drawable: drawable)

        // colorMap was filled once by renderFrame() before this loop; both
        // eyes sample the same engine tick.

        let renderPassDescriptor = MTL4RenderPassDescriptor()

        if device.supportsMSAA {
            let renderTargets = drawableTarget.memorylessTargets[uniformBufferIndex]
            assert(renderTargets.color.width == drawable.colorTextures[0].width)
            assert(renderTargets.color.height == drawable.colorTextures[0].height)

            renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].texture = renderTargets.color
            renderPassDescriptor.depthAttachment.resolveTexture = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.texture = renderTargets.depth

            renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
            renderPassDescriptor.depthAttachment.storeAction = .multisampleResolve
        } else {
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]

            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.storeAction = .store
        }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }

        #if !targetEnvironment(simulator)
        let residencySet = self.residencySets[uniformBufferIndex]
        residencySet.addAllocations([
            drawable.colorTextures[0],
            drawable.depthTextures[0],
            drawableTarget.viewProjectionBuffer
        ])
        residencySet.commit()
        #endif

        let commandAllocator = self.commandAllocators[uniformBufferIndex]
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)
        commandBuffer.useResidencySet(residencySet)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"
        renderEncoder.pushDebugGroup("Fullscreen engine pass")
        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(fullscreenPipelineState)
        // Depth must still be set since the pass has a depth attachment;
        // fullscreen triangle outputs z=1 which wins under reverse-Z
        // (drawable cleared to 0, compareFunction = greater).
        renderEncoder.setDepthStencilState(depthState)

        let viewports = drawable.views.map { $0.textureMap.viewport }
        renderEncoder.setViewports(viewports)

        if drawable.views.count > 1 {
            let viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewMappings)
        }

        renderEncoder.setArgumentTable(self.fragmentArgumentTable, stages: .fragment)
        self.fragmentArgumentTable.setTexture(colorMap.gpuResourceID, index: TextureIndex.color.rawValue)

        renderEncoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)

        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()

        commandBuffer.endCommandBuffer()

        self.commandQueue.commit([commandBuffer])

        drawable.encodePresent()
    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            } else {
                Task { @MainActor in
                    if appModel.immersiveSpaceState != .open {
                        appModel.immersiveSpaceState = .open
                    }
                }
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

extension Renderer {
    class DrawableTarget {
        var lastUsedFrameIndex: UInt64

        let memorylessTargets: [(color: MTLTexture, depth: MTLTexture)]

        let viewProjectionBuffer: MTLBuffer

        var viewProjectionBufferOffset = 0

        var viewProjectionArray: UnsafeMutablePointer<ViewProjectionArray>

        nonisolated init(drawable: LayerRenderer.Drawable) {
            lastUsedFrameIndex = 0

            let device = drawable.colorTextures[0].device
            nonisolated func renderTarget(resolveTexture: MTLTexture) -> MTLTexture {
                assert(device.supportsMSAA)

                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: resolveTexture.pixelFormat,
                                                                          width: resolveTexture.width,
                                                                          height: resolveTexture.height,
                                                                          mipmapped: false)
                descriptor.usage = .renderTarget
                descriptor.textureType = .type2DMultisampleArray
                descriptor.sampleCount = device.rasterSampleCount
                descriptor.storageMode = .memoryless
                descriptor.arrayLength = resolveTexture.arrayLength
                return device.makeTexture(descriptor: descriptor)!
            }

            if device.supportsMSAA {
                memorylessTargets = .init(repeating: (renderTarget(resolveTexture: drawable.colorTextures[0]),
                                                      renderTarget(resolveTexture: drawable.depthTextures[0])),
                                          count: maxBuffersInFlight)
            } else {
                memorylessTargets = []
            }

            let bufferSize = alignedViewProjectionArraySize * maxBuffersInFlight

            viewProjectionBuffer = device.makeBuffer(length: bufferSize,
                                                     options: [MTLResourceOptions.storageModeShared])!
            viewProjectionArray = UnsafeMutableRawPointer(viewProjectionBuffer.contents() + viewProjectionBufferOffset).bindMemory(to: ViewProjectionArray.self, capacity: 1)
        }
    }
}

extension Renderer.DrawableTarget {
    nonisolated func updateBufferState(uniformBufferIndex: Int, frameIndex: UInt64) {
        viewProjectionBufferOffset = alignedViewProjectionArraySize * uniformBufferIndex

        viewProjectionArray = UnsafeMutableRawPointer(viewProjectionBuffer.contents() + viewProjectionBufferOffset).bindMemory(to: ViewProjectionArray.self, capacity: 1)

        lastUsedFrameIndex = frameIndex
    }

    nonisolated func updateViewProjectionArray(drawable: LayerRenderer.Drawable) {
        let simdDeviceAnchor = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        nonisolated func viewProjection(forViewIndex viewIndex: Int) -> float4x4 {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: viewIndex)

            return projectionMatrix * viewMatrix
        }

        viewProjectionArray[0].viewProjectionMatrix.0 = viewProjection(forViewIndex: 0)
        if drawable.views.count > 1 {
            viewProjectionArray[0].viewProjectionMatrix.1 = viewProjection(forViewIndex: 1)
        }
    }
}

// Generic matrix math utility functions
nonisolated func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return .init(columns: (vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                           vector_float4(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
                           vector_float4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
                           vector_float4(                  0, 0, 0, 1)))
}

nonisolated func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return .init(columns: (vector_float4(1, 0, 0, 0),
                           vector_float4(0, 1, 0, 0),
                           vector_float4(0, 0, 1, 0),
                           vector_float4(translationX, translationY, translationZ, 1)))
}