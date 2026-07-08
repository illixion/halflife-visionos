//
//  Renderer.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import CompositorServices
import Metal
import QuartzCore
import MetalFX
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

/// Frame-time percentile logging (app side): where the milliseconds go
/// when the headset drops below 90 Hz. Pairs with the GL worker's
/// "[FT] cpu(ms)" line (per-eye engine CPU). Columns, ms, p50/p95/max:
///   wait0    — backpressure: GPU still busy maxBuffersInFlight ago
///   wait1    — colorMap race guard: previous frame's GPU not done
///   eyes     — CPU submit of both eyes (engine tick + GL, worker RTT)
///   angleGPU — eye-submit end → ANGLE's queue finished both eyes
///   frameGPU — eye-submit end → our compositor pass finished too
///   total    — whole renderFrame
final class FrameTimingStats {
    static let shared = FrameTimingStats()
    private let lock = NSLock()
    private var cols: [String: [Double]] = [:]
    private var frames = 0
    private static let order = ["wait0", "wait1", "eyes", "angleGPU", "frameGPU", "total"]

    func add(_ name: String, _ ms: Double) {
        lock.lock()
        cols[name, default: []].append(ms)
        lock.unlock()
    }

    func frameDone() {
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        guard frames >= 512 else { return }
        var line = "[FT] app(ms)"
        for key in FrameTimingStats.order {
            guard var v = cols[key], !v.isEmpty else { continue }
            v.sort()
            let p95 = v[min(Int(Double(v.count) * 0.95), v.count - 1)]
            line += String(format: " %@ %.1f/%.1f/%.1f", key, v[v.count / 2], p95, v.last!)
        }
        print(line)
        cols.removeAll(keepingCapacity: true)
        frames = 0
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
    let fxaaPipelineState: MTLRenderPipelineState
    let fxaaArgumentTable: MTL4ArgumentTable
    let depthState: MTLDepthStencilState
    // Engine render target: 2-layer array (layer 0 = left eye, 1 = right).
    // Allocated on the first frame from the actual drawable's dimensions
    // (see ensureColorMap) rather than at init — the size isn't known until
    // CompositorServices hands us a drawable.
    var colorMap: MTLTexture!
    var colorMapLayerViews: [MTLTexture] = [] // per-slice 2D views handed to ANGLE
    // AA + upscale chain: colorMap (engine render, sub-logical)
    // → FXAA → fxaaMap → MetalFX spatial → displayMap (full logical).
    // The display pass samples displayMap when the chain is active,
    // colorMap directly when MetalFX is unavailable.
    var fxaaMap: MTLTexture!
    var displayMap: MTLTexture!
    private var spatialScalers: [any MTL4FXSpatialScaler] = []
    private var engineInited = false

    let endFrameEvent: MTLSharedEvent
    var committedFrameIndex: UInt64 = 0

    // Signaled by ANGLE's command queue when an eye's GL render completes
    // (EGL_ANGLE_metal_shared_event_sync, registered with the bridge before
    // each eye). Our queue waits on it GPU-side before FXAA/display reads
    // colorMap — replaces the per-eye glFinish so the GL worker's CPU work
    // overlaps the GPU instead of serializing with it.
    let angleFenceEvent: MTLSharedEvent
    var angleFenceValue: UInt64 = 0
    // GPU-completion timestamps for FrameTimingStats (MTL4 command
    // buffers expose no gpuStart/EndTime; shared-event listeners do).
    let ftListener = MTLSharedEventListener(dispatchQueue: DispatchQueue(label: "LambdaVision.ft"))

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<Uniforms>

    var perDrawableTarget = [LayerRenderer.Drawable.Target: DrawableTarget]()

    var rotation: Float = 0

    var mesh: MTKMesh

    let worldTracking: WorldTrackingProvider
    let handTracking: HandTrackingProvider
    let layerRenderer: LayerRenderer
    let appModel: AppModel
    // Head yaw at the first valid sample. Only yaw needs a baseline:
    // pitch and roll are sent to the engine as absolute values (they
    // replace the game's), while yaw is sent as a delta from this
    // baseline so the game's spawn orientation and keyboard turning
    // remain in effect.
    private var headBaselineYaw: Float? = nil

    // Snap turn: inputs (gamepad right stick, Z/X keys) accumulate degrees
    // here from any thread; renderFrame consumes them by rotating the
    // engine's own view yaw (lambda_add_view_yaw) and re-anchoring the
    // position baseline. +30° = turn right.
    nonisolated(unsafe) private static var pendingSnapDeg: Float = 0
    private static let snapLock = NSLock()
    static let snapTurnDegrees: Float = 30

    nonisolated static func requestSnapTurn(_ direction: Float) {
        snapLock.lock()
        pendingSnapDeg += direction * snapTurnDegrees
        snapLock.unlock()
    }

    private static func takePendingSnap() -> Float {
        snapLock.lock()
        defer { pendingSnapDeg = 0; snapLock.unlock() }
        return pendingSnapDeg
    }

    // Gaze aim: the pinch handler stages the spatial event's selectionRay
    // (gaze direction, ARKit world space) from the event thread; renderFrame
    // converts it to a pitch/yaw offset from the current view direction and
    // hands it to the engine, where hlsdk applies it around the weapon
    // frame — shots land where the eyes point, not at screen center.
    // nil direction = no active pinch (offset returns to zero).
    nonisolated(unsafe) private static var pendingGazeDir: SIMD3<Float>? = nil
    private static let gazeLock = NSLock()

    nonisolated static func setGazeRay(direction: SIMD3<Float>?) {
        gazeLock.lock()
        pendingGazeDir = direction
        gazeLock.unlock()
    }

    private static func currentGazeDir() -> SIMD3<Float>? {
        gazeLock.lock()
        defer { gazeLock.unlock() }
        return pendingGazeDir
    }

    // Hand-anchored weapon: the dominant hand's gun pose, sampled from the
    // hand skeleton each frame. Forward runs wrist → middle knuckle (where
    // the fingers point), up is derived from the across-palm direction so
    // the grip's roll carries over. Returned both as an Apple-world aim
    // direction (for the fire-ray offset) and head-local in xash camera
    // axes (meters; the bridge/hlsdk compose it with the rendered camera).
    private struct HandSample {
        var worldForward: SIMD3<Float>            // Apple world basis, unit
        var localPos: SIMD3<Float>                // xash cam axes, meters
        var localFwd: SIMD3<Float>
        var localUp: SIMD3<Float>
    }

    private func sampleDominantHand(headTransform m: simd_float4x4) -> HandSample? {
        guard handTracking.state == .running else { return nil }
        guard let hand = handTracking.latestAnchors.rightHand,
              hand.isTracked,
              let skel = hand.handSkeleton else { return nil }
        // Anchor-level tracking is the only gate: per-joint isTracked goes
        // false whenever fingers self-occlude (fist, hand rotation), which
        // made the weapon flicker back to the viewmodel — the estimated
        // joint poses are plenty for a grip frame.
        let wrist = skel.joint(.wrist)
        let midK  = skel.joint(.middleFingerKnuckle)
        let idxK  = skel.joint(.indexFingerKnuckle)
        let litK  = skel.joint(.littleFingerKnuckle)

        let handT = hand.originFromAnchorTransform
        func worldPos(_ j: HandSkeleton.Joint) -> SIMD3<Float> {
            let t = handT * j.anchorFromJointTransform
            return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        let pWrist = worldPos(wrist)
        let pMid   = worldPos(midK)
        let fwd    = simd_normalize(pMid - pWrist)
        // Right hand: index → little knuckle runs across the palm toward
        // the hand's own right; right × forward = up (palm-roll included).
        let across = simd_normalize(worldPos(litK) - worldPos(idxK))
        let up     = simd_normalize(simd_cross(across, fwd))

        // World → head-local (rotation only for directions), then Apple →
        // xash camera basis: (x,y,z) → (-z,-x,y).
        let hInv = m.inverse
        func headLocalDir(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let r = hInv * SIMD4<Float>(v, 0)
            return SIMD3(-r.z, -r.x, r.y)
        }
        let p4 = hInv * SIMD4<Float>(pMid, 1)
        return HandSample(worldForward: fwd,
                          localPos: SIMD3(-p4.z, -p4.x, p4.y),
                          localFwd: headLocalDir(fwd),
                          localUp: headLocalDir(up))
    }
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
        // Separate table for the FXAA pass: MTL4 argument tables are live
        // GPU state, so sharing one table across two encoders that bind
        // different textures in the same frame would race.
        self.fxaaArgumentTable = try! device.makeArgumentTable(descriptor: argTableDesc)

        #if !targetEnvironment(simulator)
        let residencySetDesc = MTLResidencySetDescriptor()
        residencySetDesc.initialCapacity = 3 // color + depth + view projection buffer
        self.residencySets = (0...maxBuffersInFlight).map { _ in try! device.makeResidencySet(descriptor: residencySetDesc) }
        #endif

        self.endFrameEvent = device.makeSharedEvent()!
        self.angleFenceEvent = device.makeSharedEvent()!
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

        do {
            fxaaPipelineState = try Self.buildFXAAPipeline(device: device)
        } catch {
            fatalError("Unable to compile FXAA pipeline state. Error info: \(error)")
        }

        self.depthState = Self.buildDepthStencilState(device: device)

        do {
            mesh = try Self.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to build MetalKit Mesh. Error info: \(error)")
        }

        do {
            try Self.setupGLWorker()
        } catch {
            fatalError("Unable to set up GL worker. Error info: \(error)")
        }

        #if !targetEnvironment(simulator)
        // Add all persistent resources to the command queue residency set.
        // colorMap joins later (ensureColorMap) once its size is known.
        residencySetDesc.initialCapacity = mesh.vertexBuffers.count + mesh.submeshes.count + 2 // color map + uniforms buffer
        let residencySet = try! self.device.makeResidencySet(descriptor: residencySetDesc)
        residencySet.addAllocations(mesh.vertexBuffers.map { $0.buffer })
        residencySet.addAllocations(mesh.submeshes.map { $0.indexBuffer.buffer })
        residencySet.addAllocations([dynamicUniformBuffer])
        residencySet.commit()
        commandQueueResidencySet = residencySet
        commandQueue.addResidencySet(residencySet)
        #endif

        worldTracking = WorldTrackingProvider()
        handTracking = HandTrackingProvider()
    }

    private func startARSession(_ arSession: ARKitSession) async {
        do {
            // Hand tracking is optional: run without it if unsupported or
            // denied (weapon falls back to the camera-locked viewmodel).
            var providers: [any DataProvider] = [worldTracking]
            if HandTrackingProvider.isSupported {
                let auth = await arSession.requestAuthorization(for: [.handTracking])
                if auth[.handTracking] == .allowed {
                    providers.append(handTracking)
                }
            }
            try await arSession.run(providers)
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, arSession: ARKitSession) {
        Task(executorPreference: RendererTaskExecutor.shared) {
            // Per-source spatial audio is parked until the PHASE rewrite:
            // AVAudioEnvironmentNode renders silence on visionOS despite a
            // provably correct graph (see SpatialAudioEngine.swift). When
            // disabled, HUD_GetSoundInterface declines and the engine uses
            // its stock stereo mixer for everything.
            // Must precede engine init (first renderFrame): the engine
            // captures the spatial-audio SoundAPI callbacks during S_Init.
            if SpatialAudioEngine.enabled {
                SpatialAudioEngine.shared.register()
            }
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

    // FXAA pass: fullscreen triangle colorMap → fxaaMap (both eye slices
    // via vertex amplification). No depth attachment; runs at engine
    // resolution before the MetalFX upscale.
    static func buildFXAAPipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "FXAAPipeline"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertexShader")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "fxaaFragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.maxVertexAmplificationCount = 2
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

    /// One-time GL bring-up, independent of render-target size.
    static func setupGLWorker() throws {
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
    }

    /// Allocate the engine colorMap on the first frame, sized from the
    /// actual drawable. With foveation on, the rasterization rate map's
    /// logical (screen-space) size is the resolution the compositor samples
    /// our content at in the fovea — matching it makes an engine pixel ≈ a
    /// panel pixel where the user is looking. Without foveation, the
    /// drawable's physical size is the effective ceiling. Must run before
    /// engine init: R_Init_Video reads the size at renderer bring-up.
    private func ensureColorMap(drawable: LayerRenderer.Drawable) {
        guard colorMap == nil else { return }

        let physW = drawable.colorTextures[0].width
        let physH = drawable.colorTextures[0].height
        var w = physW
        var h = physH
        if let rateMap = drawable.rasterizationRateMaps.first {
            w = rateMap.screenSize.width
            h = rateMap.screenSize.height
            let p0 = rateMap.physicalSize(layer: 0)
            print("[LambdaVision] rateMaps=\(drawable.rasterizationRateMaps.count) "
                  + "logical=\(w)x\(h) physical(layer0)=\(p0.width)x\(p0.height)")
        }
        let logicalW = w
        let logicalH = h
        // Scale the engine render below the logical size: the GL world pass
        // cost is fill-bound and nearly linear in pixels — measured on the
        // M5 device, full logical (capped 4096×3282, 13.4 Mpx) costs
        // p50 13.3 ms/stereo pair (misses the 11.1 ms 90 Hz budget), while
        // 2048² (4.2 Mpx) costs ~6 ms. 0.6× logical ≈ 6.8 Mpx lands at
        // ~8 ms with p95 headroom. Preserves the drawable's aspect.
        // MetalFX below upscales the result back to full logical.
        // 0.75× (+56% pixels over 0.6×) projects to p50 ~10-11 ms by the
        // same linear model — near the 11.1 ms 90 Hz budget; drop back to
        // 0.7 if busy scenes judder.
        let engineScale = 0.75
        let maxDim = 4096
        var s = engineScale
        if Double(max(w, h)) * s > Double(maxDim) {
            s = Double(maxDim) / Double(max(w, h))
        }
        w = Int((Double(w) * s).rounded())
        h = Int((Double(h) * s).rounded())
        print("[LambdaVision] drawable physical=\(physW)x\(physH) → colorMap \(w)x\(h) bgra8Unorm via ANGLE")

        // ANGLE renders into this Swift-allocated MTLTexture each frame; the
        // display pass samples it. GL is the only pixel producer.
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .bgra8Unorm
        desc.width = w
        desc.height = h
        desc.arrayLength = 2
        desc.mipmapLevelCount = 1
        desc.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Unable to allocate \(w)x\(h) colorMap")
        }
        tex.label = "AngleColorMap"
        colorMap = tex

        // 2D slice views (one per eye) over the 2D-array colorMap. ANGLE/Metal
        // interop wraps these as plain 2D MTLTextures so the existing
        // EGL_METAL_TEXTURE_ANGLE path keeps working unchanged. Writes through
        // a view land in the underlying array slice, which the display shader
        // samples via texture2d_array.
        colorMapLayerViews = (0..<2).map { slice in
            tex.makeTextureView(pixelFormat: tex.pixelFormat,
                                textureType: .type2D,
                                levels: 0..<1,
                                slices: slice..<(slice + 1))!
        }

        #if !targetEnvironment(simulator)
        commandQueueResidencySet.addAllocations([tex])
        commandQueueResidencySet.commit()
        #endif

        lambda_engine_set_render_size(Int32(w), Int32(h))

        // MetalFX spatial upscale back to full logical resolution. Its
        // edge-directed reconstruction doubles as edge smoothing — the
        // engine render has no AA of its own (GL MSAA through ANGLE
        // measured +7 ms/pair; see Lambda_Bridge.c).
        // DISABLED: frame timing showed the FXAA+MetalFX+composite chain
        // costs ~13-14 ms GPU/frame (angleGPU p50 0.7 ms vs frameGPU p50
        // 14-16 ms) — the whole app was GPU-bound at ~50 FPS on the post
        // chain alone. At 0.75x engine scale the scaler's win over the
        // composite pass's bilinear sample doesn't justify two extra
        // full-res passes per eye.
        let useMetalFXChain = false
        if useMetalFXChain, logicalW > w, MTLFXSpatialScalerDescriptor.supportsMetal4FX(device),
           let compiler = try? device.makeCompiler(descriptor: MTL4CompilerDescriptor()) {
            let sd = MTLFXSpatialScalerDescriptor()
            sd.inputWidth = w
            sd.inputHeight = h
            sd.outputWidth = logicalW
            sd.outputHeight = logicalH
            sd.colorTextureFormat = .bgra8Unorm
            sd.outputTextureFormat = .bgra8Unorm
            sd.colorProcessingMode = .perceptual
            let scalers = (0..<2).compactMap { _ in
                sd.makeSpatialScaler(device: device, compiler: compiler)
            }
            if scalers.count == 2 {
                // Intermediate FXAA target at engine resolution — the
                // scaler reads this instead of the raw colorMap.
                let fd = MTLTextureDescriptor()
                fd.textureType = .type2DArray
                fd.pixelFormat = .bgra8Unorm
                fd.width = w
                fd.height = h
                fd.arrayLength = 2
                fd.mipmapLevelCount = 1
                fd.usage = scalers[0].colorTextureUsage.union([.renderTarget, .shaderRead, .pixelFormatView])
                fd.storageMode = .private

                let dd = MTLTextureDescriptor()
                dd.textureType = .type2DArray
                dd.pixelFormat = .bgra8Unorm
                dd.width = logicalW
                dd.height = logicalH
                dd.arrayLength = 2
                dd.mipmapLevelCount = 1
                dd.usage = scalers[0].outputTextureUsage.union([.shaderRead, .pixelFormatView])
                dd.storageMode = .private
                if let fm = device.makeTexture(descriptor: fd),
                   let dm = device.makeTexture(descriptor: dd) {
                    fm.label = "FXAAMap"
                    dm.label = "UpscaledDisplayMap"
                    for (i, scaler) in scalers.enumerated() {
                        scaler.colorTexture = fm.makeTextureView(
                            pixelFormat: fm.pixelFormat, textureType: .type2D,
                            levels: 0..<1, slices: i..<(i + 1))!
                        scaler.outputTexture = dm.makeTextureView(
                            pixelFormat: dm.pixelFormat, textureType: .type2D,
                            levels: 0..<1, slices: i..<(i + 1))!
                        scaler.inputContentWidth = w
                        scaler.inputContentHeight = h
                    }
                    fxaaMap = fm
                    displayMap = dm
                    spatialScalers = scalers
                    #if !targetEnvironment(simulator)
                    commandQueueResidencySet.addAllocations([fm, dm])
                    commandQueueResidencySet.commit()
                    #endif
                    print("[LambdaVision] FXAA + MetalFX spatial upscale \(w)x\(h) → \(logicalW)x\(logicalH)")
                }
            }
        }
        if displayMap == nil {
            print("[LambdaVision] MetalFX upscale inactive — displaying colorMap directly")
        }
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
                     "+map", "c0a0"] // tram ride (Black Mesa Inbound)
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

        let ftFrameStart = CACurrentMediaTime()
        guard self.endFrameEvent.wait(untilSignaledValue: committedFrameIndex - UInt64(maxBuffersInFlight), timeoutMS: 10000) else {
            return
        }
        FrameTimingStats.shared.add("wait0", (CACurrentMediaTime() - ftFrameStart) * 1000)

        frame.startUpdate()

        // Perform frame independent work

        // Poll the gamepad once per frame: sticks stage engine joystick
        // axes (applied on the GL worker at tick start), buttons dispatch
        // commands, right-stick X requests snap turns consumed below.
        GamepadInput.shared.poll { direction in
            Renderer.requestSnapTurn(direction)
        }

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
        // Each eye is rendered with AVP's actual asymmetric frustum
        // (drawable.views[i].tangents) so the engine output matches what
        // the headset wants to display. The plane-display pass below still
        // resamples colorMap onto a small floating plane — fixing the
        // engine projection on its own won't make this immersive, but it's
        // the foundation: once we swap the plane for a fullscreen blit,
        // the per-eye images will stereo-fuse correctly only because each
        // was rendered through the matching frustum.
        // zNear/zFar in xash world units (HL inches ≈ 39.37/meter).
        // zFar matches the engine's culling far clip (R_GetFarClip floors
        // zmax at 16384 × 1.73): worldspawn MaxRange (4096 on GoldSrc-era
        // maps) clips into view as gray in long halls like the tram ride.
        let zNear: Float = 4.0
        let zFar:  Float = 16384.0 * 1.73
        // Use the first drawable's tangents (built-in target). Capture
        // target may have different tangents but for now match builtIn.
        let primary = drawables.first { $0.target == .builtIn } ?? drawables[0]
        // Size the colorMap from the first real drawable, then bring the
        // engine up at that resolution. Order matters: engine init reads
        // the size ensureColorMap publishes.
        ensureColorMap(drawable: primary)
        ensureEngineInitialized()
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

            // Snap turn: hand the turn to the ENGINE as a change to its own
            // view yaw (cl.viewangles) so the movement basis turns with the
            // view — rotating only the render-side yaw baseline (the old
            // approach) turned the picture but left WASD moving along the
            // stale engine yaw. The yaw baseline stays put; the view turns
            // because gameYaw itself changes. +snap = turn right, xash yaw
            // is CCW-positive, hence the negation.
            //
            // The position baseline is still re-anchored so the CURRENT
            // head position maps to the same in-game offset before and
            // after the snap (the composite room→world rotation
            // gameYaw − baselineYaw changes by −snap, and Z-rotations
            // commute, so the fix is simply dNew = Rz(+snap)·dOld) —
            // otherwise a snap while standing away from the baseline
            // origin would swing the camera along an arc.
            let snap = Renderer.takePendingSnap()
            if snap != 0 {
                lambda_add_view_yaw(-snap)
                let sr = snap * Float.pi / 180
                let dOld = cur.pos - headBaselinePos!
                let dNew = SIMD3<Float>(dOld.x * cosf(sr) - dOld.y * sinf(sr),
                                        dOld.x * sinf(sr) + dOld.y * cosf(sr),
                                        dOld.z)
                headBaselinePos = cur.pos - dNew
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

            // Aim ray + hand-anchored weapon. With the dominant hand
            // tracked, the weapon renders at the hand (p_ model, composed
            // hlsdk-side) and fires along the hand's pointing direction;
            // otherwise fall back to the pinch gaze ray, then view center.
            // Offsets in xash conventions (pitch positive down, yaw CCW).
            var aimDir: SIMD3<Float>? = nil  // Apple world basis
            if let anchor = frameDeviceAnchor,
               let hand = sampleDominantHand(headTransform: anchor.originFromAnchorTransform) {
                let p = hand.localPos * appleToXash
                lambda_set_hand_pose(p.x, p.y, p.z,
                                     hand.localFwd.x, hand.localFwd.y, hand.localFwd.z,
                                     hand.localUp.x, hand.localUp.y, hand.localUp.z)
                aimDir = hand.worldForward
            } else {
                lambda_clear_hand_pose()
                aimDir = Renderer.currentGazeDir()
            }
            if let g = aimDir {
                let gx = SIMD3<Float>(-g.z, -g.x, g.y)  // Apple → xash basis
                let gPitch = atan2f(-gx.z, sqrtf(gx.x * gx.x + gx.y * gx.y)) * rad2deg
                let gYaw   = atan2f(gx.y, gx.x) * rad2deg
                var dy = gYaw - yawDeg
                if dy > 180 { dy -= 360 } else if dy < -180 { dy += 360 }
                lambda_set_aim_offset(gPitch - pitchDeg, dy)
            } else {
                lambda_set_aim_offset(0, 0)
            }
        }

        // colorMap is written by ANGLE on its own MTLCommandQueue; glFinish
        // in the GL worker fences only that queue. OUR queue's reads of
        // colorMap from the previous frame (FXAA/upscale/display) must have
        // completed before the engine overwrites it, or the reader picks up
        // tiles of the new frame mid-pass — visible as per-eye flicker and
        // stale rectangular patches during head motion. endFrameEvent is
        // signaled after each frame's queue work, so waiting for the
        // previous frame's value closes the race.
        let ftWait1Start = CACurrentMediaTime()
        guard self.endFrameEvent.wait(untilSignaledValue: committedFrameIndex, timeoutMS: 10000) else {
            return
        }
        let ftEyesStart = CACurrentMediaTime()
        FrameTimingStats.shared.add("wait1", (ftEyesStart - ftWait1Start) * 1000)

        for eye in 0..<2 {
            // GPU-side fence for this eye: the bridge signals angleFenceEvent
            // with this value on ANGLE's queue when the eye's render
            // completes, instead of blocking the GL worker in glFinish.
            angleFenceValue += 1
            lambda_gl_set_frame_fence(
                Unmanaged.passUnretained(angleFenceEvent).toOpaque(),
                angleFenceValue)
            // Per-eye position in head-local space, X = right (meters).
            // view[0] vs [1] left/right ordering isn't formally guaranteed,
            // so reading the actual x value auto-derives the sign instead
            // of assuming view[0] = left eye.
            let eyeApple_x = primary.views[eye].transform.columns.3.x
            let off: Float = eyeApple_x * appleToXash
            let eyePtr = Unmanaged.passUnretained(colorMapLayerViews[eye]).toOpaque()
            var tang = primary.views[eye].tangents  // (left, right, top, bottom)

            // 2D overlay (HUD/console/menu) placement: a box of fixed
            // ANGULAR size centered on the forward axis, computed per eye
            // from that eye's frustum tangents. Centering in the texture
            // double-images: the per-eye frustums are asymmetric, so the
            // texture center is a different view direction in each eye.
            // The horizontal convergence shift (-eyeX/dist) makes the
            // overlay fuse at hudDistance instead of optical infinity.
            do {
                let hudDistance: Float = 2.0                     // meters
                let hudHalfTan = tanf(50.0 / 2.0 * .pi / 180.0)  // 50° wide
                let tL = tang.x, tR = tang.y, tT = tang.z, tB = tang.w
                let sumH = tL + tR, sumV = tT + tB
                let conv = -eyeApple_x / hudDistance             // tan-space, toward the nose
                let fullW = Float(colorMap.width), fullH = Float(colorMap.height)
                // Same fraction of both axes keeps ortho pixels square.
                let frac = 2.0 * hudHalfTan / sumH
                let x0 = ((tL + conv) / sumH - frac / 2.0) * fullW
                let y0 = (tB / sumV - frac / 2.0) * fullH
                lambda_gl_worker_set_2d_viewport(x0, y0, fullW * frac, fullH * frac)
            }
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

        // Order our queue after ANGLE's colorMap writes for both eyes. The
        // wait is GPU-side (queue stalls, not the CPU), pairing with the
        // per-eye fence signals above; angleFenceValue is the last (eye 1)
        // value, which implies eye 0's earlier value on the same event.
        commandQueue.waitForEvent(angleFenceEvent, value: angleFenceValue)

        let ftEyesEnd = CACurrentMediaTime()
        FrameTimingStats.shared.add("eyes", (ftEyesEnd - ftEyesStart) * 1000)
        angleFenceEvent.notify(ftListener, atValue: angleFenceValue) { _, _ in
            FrameTimingStats.shared.add("angleGPU", (CACurrentMediaTime() - ftEyesEnd) * 1000)
        }

        for (i, drawable) in drawables.enumerated() {
            // FXAA + upscale are encoded once, into the first drawable's
            // command buffer; further drawables (capture) reuse displayMap.
            render(drawable: drawable, frameIndex: frame.frameIndex,
                   deviceAnchor: frameDeviceAnchor, encodeUpscale: i == 0)
        }

        committedFrameIndex += 1

        commandQueue.signalEvent(self.endFrameEvent, value: committedFrameIndex)

        endFrameEvent.notify(ftListener, atValue: committedFrameIndex) { _, _ in
            FrameTimingStats.shared.add("frameGPU", (CACurrentMediaTime() - ftEyesEnd) * 1000)
        }

        frame.endSubmission()
        FrameTimingStats.shared.add("total", (CACurrentMediaTime() - ftFrameStart) * 1000)
        FrameTimingStats.shared.frameDone()
    }

    func render(drawable: LayerRenderer.Drawable, frameIndex: UInt64,
                deviceAnchor: DeviceAnchor?, encodeUpscale: Bool) {
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

        if encodeUpscale && !spatialScalers.isEmpty {
            // FXAA: colorMap → fxaaMap, both eye slices in one pass via
            // vertex amplification.
            let fxaaPassDescriptor = MTL4RenderPassDescriptor()
            fxaaPassDescriptor.colorAttachments[0].texture = fxaaMap
            fxaaPassDescriptor.colorAttachments[0].loadAction = .dontCare
            fxaaPassDescriptor.colorAttachments[0].storeAction = .store
            fxaaPassDescriptor.renderTargetArrayLength = 2
            guard let fxaaEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fxaaPassDescriptor) else {
                fatalError("Failed to create FXAA encoder")
            }
            fxaaEncoder.label = "FXAA Encoder"
            fxaaEncoder.setRenderPipelineState(fxaaPipelineState)
            fxaaEncoder.setVertexAmplificationCount((0..<2).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0,
                                                  renderTargetArrayIndexOffset: UInt32($0))
            })
            fxaaEncoder.setArgumentTable(fxaaArgumentTable, stages: .fragment)
            fxaaArgumentTable.setTexture(colorMap.gpuResourceID, index: TextureIndex.color.rawValue)
            fxaaEncoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            // Producer barrier: fxaaMap writes must be visible to the
            // MetalFX scaler encoded next (MTL4 = no hazard tracking).
            fxaaEncoder.barrier(afterStages: .fragment, beforeQueueStages: .all,
                                visibilityOptions: .device)
            fxaaEncoder.endEncoding()

            // MetalFX spatial upscale: fxaaMap → displayMap, per eye.
            for scaler in spatialScalers {
                scaler.encode(commandBuffer: commandBuffer)
            }
        }

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"
        renderEncoder.pushDebugGroup("Fullscreen engine pass")
        // Metal 4 does no automatic hazard tracking: order this pass's
        // displayMap reads after the MetalFX upscale encoded above on the
        // same queue.
        if !spatialScalers.isEmpty {
            renderEncoder.barrier(afterQueueStages: .all, beforeStages: .fragment,
                                  visibilityOptions: .device)
        }
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
        let displayTexture: MTLTexture = displayMap ?? colorMap
        self.fragmentArgumentTable.setTexture(displayTexture.gpuResourceID, index: TextureIndex.color.rawValue)

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
                // The engine stops ticking here but the AudioQueue would
                // keep streaming the DMA ring — the last painted samples
                // loop audibly forever. Pause output with the renderer.
                lambda_snd_activate(0)
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                lambda_snd_activate(0)
                layerRenderer.waitUntilRunning()
                lambda_snd_activate(1)
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