//
//  Renderer.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import CompositorServices
import Metal
import MetalFX
import MetalKit
import QuartzCore
import RAVEDiagnostics
import RAVEInput
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
/// The per-column store, the 512-frame window and the p50/p95/max reduction all
/// come from RAVE Engine now — four apps had grown four copies of that same
/// shape. What stays here is this renderer's column vocabulary and its console
/// line, which are specific to a CompositorServices eye-submit pipeline.
///
/// The collector underneath is lock-guarded rather than an actor for this
/// caller's sake: `add` is a synchronous call on the render thread and cannot
/// await anything.
enum FrameTimingStats {
    private static let order = ["wait0", "wait1", "eyes", "angleGPU", "frameGPU", "total"]

    static let shared: RAVEFrameProfiler = {
        let profiler = RAVEFrameProfiler(
            subsystem: "com.illixion.lambdavision",
            category: "Frame",
            window: .frames(count: 512),
            capacity: 512
        )
        profiler.onWindowClosed = { snapshot in
            AppLog.perf.line("[FT] app(ms) " + snapshot.percentileLine(keys: order))
        }
        return profiler
    }()

    /// Raw per-frame "total" samples, oldest first — what the Performance
    /// window's scrolling graph plots.
    static func livePeriods() -> [Double] { shared.collector.samples(for: "total") }

    /// The full per-stage reduction (wait0/wait1/eyes/angleGPU/frameGPU/total),
    /// polled live rather than waiting for the 512-frame window to close.
    static func liveSnapshot() -> RAVEMetricSnapshot { shared.snapshot() }
}

extension RAVEFrameProfiler {
    /// Spelled `add` to match the ~8 render-thread call sites this replaced.
    @inline(__always)
    func add(_ name: String, _ ms: Double) { record(name, ms: ms) }

    @inline(__always)
    func frameDone() { frameEnded() }
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
    // Same composite pass with the FXAA kernel folded into its fragment
    // shader — the default. Selected per frame from Renderer.compositeFXAA,
    // so the Settings toggle is live without adding a pass or a uniform.
    let fullscreenFXAAPipelineState: MTLRenderPipelineState
    let fxaaPipelineState: MTLRenderPipelineState
    let fxaaArgumentTable: MTL4ArgumentTable
    let depthState: MTLDepthStencilState
    // Engine render target: 2-layer array (layer 0 = left eye, 1 = right).
    // Allocated on the first frame from the actual drawable's dimensions
    // (see ensureColorMap) rather than at init — the size isn't known until
    // CompositorServices hands us a drawable.
    var colorMap: MTLTexture!
    var colorMapLayerViews: [MTLTexture] = [] // per-slice 2D views handed to ANGLE
    // Normal path: colorMap (engine render, sub-logical) → composite pass,
    // which samples it directly and applies FXAA in the same fragment shader
    // (fragmentShaderFXAA) — no intermediate texture, no extra pass.
    // Parked path (Renderer.useMetalFXChain, no longer reachable from
    // Settings): colorMap → FXAA pass → fxaaMap → MetalFX spatial →
    // displayMap (full logical), which the composite samples instead. That
    // chain measured ~13-14 ms GPU/frame — see the note in ensureColorMap.
    var fxaaMap: MTLTexture!
    var displayMap: MTLTexture!
    private var spatialScalers: [any MTL4FXSpatialScaler] = []
    private var engineInited = false
    // Weapon model rendered by RealityKit-style Metal pass instead of the
    // engine (see WeaponPass). Lazily created on the first frame.
    private var weaponPass: WeaponPass!
    // Wireframe hand+forearm skeleton drawn in place of the real passthrough
    // arms, which visionOS otherwise always composites over full immersion
    // (a safety feature independent of immersionStyle) — see ArmPass and
    // .upperLimbVisibility(.hidden) in LambdaVisionApp. Lazily created on
    // the first frame, like weaponPass.
    private var armPass: ArmPass!

    // First-person body: the rig is built once from the body slot after the
    // engine loads gordon.mdl; the mesh is uploaded once per bake (and again
    // when the legs toggle flips, since hidden bones are cut at upload). The
    // body yaw trails the head yaw so the torso follows a turn, not a glance.
    private var avatarRig: AvatarRig?
    private var avatarRigFailed = false
    private var avatarMesh: StudioMesh?
    private var avatarMeshLegs = false
    private var avatarBodyYaw: Float? = nil
    private var avatarLastTime: Double? = nil
    // The legs: planted feet carried between frames, and the freshness of
    // the engine's body state (a paused game stops publishing, and a stale
    // velocity would walk the feet away forever).
    private var avatarGait: AvatarGait?
    private var avatarBodySequence: UInt32 = 0
    private var avatarBodySeenAt: Double = 0
    // The vertical head offset sent to the engine this frame (units): the
    // engine's eye height is measured before it is added.
    private var avatarHeadOffsetZ: Float = 0
    private var avatarLastGroundTime: Double? = nil

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
    // Settings-driven knobs, assigned from GameSettings on the main actor and
    // read on the render/input threads. Simple value types with benign
    // tearing (like the other cross-thread scalars here) — no lock needed.
    nonisolated(unsafe) static var snapTurnDegrees: Float = 30
    // Engine render scale and the FXAA+MetalFX upscale chain size the render
    // targets, so these are read once at drawable setup — a change applies on
    // the next immersive-space open, not live.
    nonisolated(unsafe) static var engineScale: Float = 0.75
    // Hidden in Settings and forced false at startup (see GameSettings): the
    // FXAA-pass → MetalFX-spatial chain adds two full-logical-resolution
    // passes per eye for ~13-14 ms GPU/frame (~50 FPS), and upscaling to the
    // full drawable fights the compositor's own foveated upsampling. Code
    // kept compiled in case it returns behind a cheaper configuration.
    nonisolated(unsafe) static var useMetalFXChain: Bool = false
    // FXAA inside the composite fragment shader (the replacement for the
    // chain above). Read on the render thread every frame, so the Settings
    // toggle applies live — it only picks between two pipeline states.
    nonisolated(unsafe) static var compositeFXAA: Bool = true
    // Dominant hand for the weapon anchor + aim, and the accessibility switch
    // that fires along gaze instead of the weapon barrel. Both live.
    nonisolated(unsafe) static var dominantHandIsLeft: Bool = false
    nonisolated(unsafe) static var fireAlongGaze: Bool = false
    // Immersive gesture input (pass 2, opt-in via Settings). When on, curling
    // the dominant hand's index finger pulls the trigger (finger-gun fire).
    // Pinch fire (LambdaVisionApp) stays available as a fallback. The trigger
    // uses the index EXTENSION ratio from sampleDominantHand with hysteresis:
    // fire below `fireCurlOn`, release above `fireCurlOff`. Tuned live.
    nonisolated(unsafe) static var gestureInputEnabled: Bool = false
    nonisolated(unsafe) static var fireCurlOn: Float = 0.55   // extension below this → +attack
    nonisolated(unsafe) static var fireCurlOff: Float = 0.75  // extension above this → -attack
    // Reload gesture (dominant hand): curl the thumb down while the index
    // stays extended (off the trigger), hold for reloadHoldSeconds → +reload.
    // A progress ring above the weapon fills during the hold, so a stray
    // curl is visible before it fires. Hysteresis mirrors the finger-gun.
    nonisolated(unsafe) static var thumbCurlOn: Float = 0.45   // extension below this → hold begins
    nonisolated(unsafe) static var thumbCurlOff: Float = 0.60  // extension above this → hold cancels
    nonisolated(unsafe) static var reloadHoldSeconds: Double = 0.75
    // 🤌 radial weapon menu (dominant hand): pinch ALL fingertips to the
    // thumb to open, move the hand toward a sector, release to select
    // (slot1..slot5, 12 o'clock = slot1, clockwise). Enter/exit hysteresis
    // on the tip spread; the fist gate keeps a clenched fist from opening
    // it; the deadzone means release-in-place cancels.
    nonisolated(unsafe) static var menuPinchEnter: Float = 0.055  // max tip↔thumb spread, m
    nonisolated(unsafe) static var menuPinchExit: Float = 0.085
    nonisolated(unsafe) static var menuFistGate: Float = 0.05     // middle tip↔metacarpal must exceed
    nonisolated(unsafe) static var menuDeadzoneM: Float = 0.04    // hand travel before a sector arms
    // Weapon grip correction (applied in the hand-bone-local frame between the
    // world hand frame and the GoldSrc→metres basis). GoldSrc hand bones and
    // ARKit hand frames don't line up perfectly; these Euler degrees + push
    // (metres, along the hand's forward) tune how the gun sits in the hand.
    // Tuned live; start neutral and adjust from device.
    // Set once at engine init: whether the player-avatar model was found and
    // baked (see lambda_body_load). Read by the body pass to decide whether a
    // first-person body can be drawn at all.
    nonisolated(unsafe) static var avatarAvailable = false
    /// Draw the first-person body (Settings > Input). Off = arms-only
    /// fallback: the wireframe hands and the viewmodel, as before.
    nonisolated(unsafe) static var avatarBodyEnabled = true
    /// Draw the avatar's legs, planted on the game's floor and stepping as
    /// the player moves (AvatarGait). Off leaves an open waist, as before.
    nonisolated(unsafe) static var avatarLegsVisible = true

    nonisolated(unsafe) static var gripRollDeg: Float = 90  // grip points down into the fist
    nonisolated(unsafe) static var gripPitchDeg: Float = 0
    nonisolated(unsafe) static var gripYawDeg: Float = 180   // barrel points along fingers
    nonisolated(unsafe) static var gripPushM: Float = 0  // seat grip back into the hand

    // Live aim diagnostics, published from the render thread each frame and
    // read by the launcher's Diagnostics disclosure (which stays visible while
    // the game runs). Purpose: see in real time WHY a shot went where it did —
    // which hand-sample gate dropped, whether fire used barrel/gaze/center, and
    // the resulting pitch/yaw offset. Plain struct copy across threads; a torn
    // read is harmless for a readout. The n* counters accumulate so a gate that
    // only drops intermittently (e.g. during the firing pose) shows up as a
    // climbing count rather than a single fleeting string.
    struct AimDiag {
        var handOutcome = "—"     // last sampleDominantHand result
        var aimSource   = "—"     // barrel / gaze(hand) / gaze(fallback) / center(no-dir)
        var fireAlongGaze = false // the "Fire aims at" setting, as the render thread sees it
        var pitch: Float = 0      // offset actually sent to the engine (deg)
        var yaw: Float = 0
        var nTracked = 0, nNotTracked = 0, nNoSkeleton = 0, nNoAnchor = 0, nProviderDown = 0
        var gestureOn = false     // "Immersive gesture input" setting, render-thread view
        var indexExt: Float = 0   // live index extension ratio (finger-gun trigger)
        var fireGesture = false   // finger-gun trigger currently held
        var thumbExt: Float = 0   // live thumb extension ratio (reload gesture)
        var reloadProg: Float = 0 // reload hold progress 0..1 (0 = idle/fired)
        var menuSpread: Float = 0 // live 🤌 fingertip spread, m
        var menuOpen = false      // radial weapon menu currently up
        var menuSel = -1          // armed sector (0-based; -1 = none/cancel)
        var useReach: Float = 0   // off-hand fingertip forward reach, m
        var useHeld = false       // +use currently held by the reach gesture
        var onTrain = false       // server says we're controlling a train
        var trainGear = 0         // current gear (-1..3) while on a train
        var moveClutch = false    // off-hand joystick clutch engaged
        var joyX: Float = 0       // joystick strafe (-1..1, + = right)
        var joyY: Float = 0       // joystick forward (-1..1, + = forward)
        var moveVert = "—"        // jump / duck / —
        var moveHandSeen = false  // off-hand anchor tracked this frame
        var pinchDist: Float = -1 // thumb↔index distance, m (-1 = no hand)
        var fistCount = 0         // fingers curled to metacarpal (>=3 = suppressed)
        var nRecenter = 0         // head-baseline re-anchors (resume / origin jump)
    }
    nonisolated(unsafe) static var aimDiag = AimDiag()

    /// Human-readable snapshot of the live aim diagnostics for the launcher's
    /// Diagnostics disclosure. Read from the main thread; the underlying struct
    /// is written on the render thread (torn read tolerated for a readout).
    nonisolated static func aimDiagLines() -> [String] {
        let d = aimDiag
        return [
            "hand: \(d.handOutcome)   dom: \(dominantHandIsLeft ? "L" : "R")",
            "fire aims at: \(d.fireAlongGaze ? "gaze (setting)" : "barrel (setting)")",
            "aim source: \(d.aimSource)",
            String(format: "offset: pitch %+.1f°  yaw %+.1f°", d.pitch, d.yaw),
            "gate hits — tracked:\(d.nTracked) notTracked:\(d.nNotTracked) "
              + "noSkel:\(d.nNoSkeleton) noAnchor:\(d.nNoAnchor) provDown:\(d.nProviderDown)",
            String(format: "finger-gun: %@  indexExt %.2f  trigger %@",
                   d.gestureOn ? "on" : "off", d.indexExt, d.fireGesture ? "DOWN" : "up"),
            String(format: "reload: thumbExt %.2f  hold %d%%",
                   d.thumbExt, Int(d.reloadProg * 100)),
            String(format: "wpn menu: spread %.3f  %@  sel %@",
                   d.menuSpread, d.menuOpen ? "OPEN" : "—",
                   d.menuSel >= 0 ? "slot\(d.menuSel + 1)" : "—"),
            String(format: "use: reach %.2f  %@   train: %@",
                   d.useReach, d.useHeld ? "HELD" : "—",
                   d.onTrain ? "gear \(d.trainGear)" : "—"),
            String(format: "move: clutch %@  joy(%+.2f,%+.2f)  vert %@",
                   d.moveClutch ? "on" : "off", d.joyX, d.joyY, d.moveVert),
            String(format: "move dbg: hand %@  pinchDist %.3f  fist %d  recenter %d",
                   d.moveHandSeen ? "seen" : "—", d.pinchDist, d.fistCount, d.nRecenter),
        ]
    }

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

    // Menu gaze-cursor mapping. The stock Half-Life menu is displayed in the
    // 2D overlay box (hudDistance forward, 50° wide — see the overlay
    // placement in renderFrame). A pinch's gaze ray is mapped through the SAME
    // box to a render-target pixel, which the engine's menu treats as the
    // mouse (Lambda_Bridge lambda_menu_*). These inputs are refreshed each
    // frame from the render thread; the map runs on the spatial-event thread.
    nonisolated(unsafe) static var latestHeadTransform: simd_float4x4? = nil
    nonisolated(unsafe) static var renderTargetW: Int = 0
    nonisolated(unsafe) static var renderTargetH: Int = 0
    nonisolated(unsafe) static var hudBoxAspect: Float = 0.75   // box tan height / width (sumV/sumH)
    static let hudHalfTan: Float = tanf(50.0 / 2.0 * .pi / 180.0)  // matches the 50°-wide overlay

    /// Map an ARKit world-space gaze direction to a menu pixel (render-target
    /// coords, origin top-left), or nil if it falls outside the overlay box or
    /// behind the head. The box is centred on the head-forward axis both axes
    /// (the overlay's x0/y0 place tan(0,0) at the box centre), so head-local
    /// tangents map linearly to the box.
    nonisolated static func menuCursorFromGaze(_ worldDir: SIMD3<Float>) -> (Int, Int)? {
        guard let head = latestHeadTransform, renderTargetW > 0, renderTargetH > 0 else { return nil }
        let d4 = head.inverse * SIMD4<Float>(worldDir, 0)   // world → head-local (rotation only)
        guard d4.z < -1e-4 else { return nil }               // must look forward (-Z)
        let htan = d4.x / -d4.z                               // + = right
        let vtan = d4.y / -d4.z                               // + = up
        let hH = hudHalfTan
        let vH = hudHalfTan * hudBoxAspect
        let u = (htan + hH) / (2 * hH)
        let v = (vH - vtan) / (2 * vH)                        // screen y is down
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return (Int(u * Float(renderTargetW)), Int(v * Float(renderTargetH)))
    }

    // Hand-anchored weapon: the dominant hand's gun pose, sampled from the
    // hand skeleton each frame. Forward runs wrist → middle knuckle (where
    // the fingers point), up is derived from the across-palm direction so
    // the grip's roll carries over. Returned both as an Apple-world aim
    // direction (for the fire-ray offset) and head-local in xash camera
    // axes (meters; the bridge/hlsdk compose it with the rendered camera).
    private struct HandSample {
        var worldForward: SIMD3<Float>            // Apple world basis, unit
        var worldUp: SIMD3<Float>                 // Apple world basis, unit
        var worldGrip: SIMD3<Float>               // Apple world, wrist (grip point)
        var localPos: SIMD3<Float>                // xash cam axes, meters
        var localFwd: SIMD3<Float>
        var localUp: SIMD3<Float>
        var indexExtension: Float                 // index tip↔knuckle / palm length; low = curled (trigger)
        var thumbExtension: Float                 // thumb tip↔index knuckle / palm length; low = curled (reload)
        var pinchAllSpread: Float                 // max fingertip↔thumb-tip distance, m; low = 🤌 (weapon menu)
        var middleCurlM: Float                    // middle tip↔metacarpal, m; low = fist (menu suppressor)
    }

    private func sampleDominantHand(headTransform m: simd_float4x4) -> HandSample? {
        guard handTracking.state == .running else {
            Renderer.aimDiag.handOutcome = "provider \(handTracking.state)"
            Renderer.aimDiag.nProviderDown &+= 1
            return nil
        }
        let left = Renderer.dominantHandIsLeft
        // Split what used to be one compound guard so the diagnostics can name
        // exactly which gate failed (anchor missing vs anchor-not-tracked vs
        // skeleton missing) — that's how we tell "shooting needs all fingers"
        // apart from a lost anchor.
        guard let hand = left ? handTracking.latestAnchors.leftHand
                              : handTracking.latestAnchors.rightHand else {
            Renderer.aimDiag.handOutcome = "no anchor"
            Renderer.aimDiag.nNoAnchor &+= 1
            return nil
        }
        guard hand.isTracked else {
            Renderer.aimDiag.handOutcome = "not tracked"
            Renderer.aimDiag.nNotTracked &+= 1
            return nil
        }
        guard let skel = hand.handSkeleton else {
            Renderer.aimDiag.handOutcome = "no skeleton"
            Renderer.aimDiag.nNoSkeleton &+= 1
            return nil
        }
        Renderer.aimDiag.handOutcome = "tracked"
        Renderer.aimDiag.nTracked &+= 1
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
        // The left hand's little finger is on the opposite side, so negate
        // to keep `up` pointing the same way out of the palm.
        let acrossRaw = worldPos(litK) - worldPos(idxK)
        let across = simd_normalize(left ? -acrossRaw : acrossRaw)
        let up     = simd_normalize(simd_cross(across, fwd))

        // Index-finger curl for the finger-gun trigger: tip↔knuckle distance
        // normalised by palm length (wrist→middle knuckle), so it's scale-
        // invariant across hand sizes. Extended ≈ 1, curled (trigger pulled)
        // drops toward ~0.3. The knuckle barely moves when the finger curls,
        // so this doesn't disturb the wrist→knuckle aim ray.
        let palmLen = simd_length(pMid - pWrist)
        let idxExt  = palmLen > 1e-4
            ? simd_length(worldPos(skel.joint(.indexFingerTip)) - worldPos(idxK)) / palmLen
            : 1.0
        // Thumb curl for the reload gesture: thumb tip↔index knuckle,
        // normalised like the index. Extended/raised thumb reads high
        // (~0.5+); curled down onto the fist it approaches the index
        // knuckle and drops (~0.3). Tuned live via the diagnostics line.
        let thumbExt = palmLen > 1e-4
            ? simd_length(worldPos(skel.joint(.thumbTip)) - worldPos(idxK)) / palmLen
            : 1.0
        // 🤌 pinched-fingers for the radial weapon menu: how far the
        // farthest fingertip sits from the thumb tip — all tips converged
        // reads low (~0.02-0.04m). A fist also brings tips near the thumb,
        // so middleCurlM (middle tip↔metacarpal) doubles as a suppressor:
        // in 🤌 the fingers arch up to the pinch point (high), in a fist
        // they collapse onto the palm (low).
        let pThumbTip = worldPos(skel.joint(.thumbTip))
        var spread: Float = 0
        for tip: HandSkeleton.JointName in [.indexFingerTip, .middleFingerTip,
                                            .ringFingerTip, .littleFingerTip] {
            spread = max(spread, simd_distance(worldPos(skel.joint(tip)), pThumbTip))
        }
        let middleCurl = simd_distance(worldPos(skel.joint(.middleFingerTip)),
                                       worldPos(skel.joint(.middleFingerMetacarpal)))

        // World → head-local (rotation only for directions), then Apple →
        // xash camera basis: (x,y,z) → (-z,-x,y).
        let hInv = m.inverse
        func headLocalDir(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let r = hInv * SIMD4<Float>(v, 0)
            return SIMD3(-r.z, -r.x, r.y)
        }
        let p4 = hInv * SIMD4<Float>(pMid, 1)
        return HandSample(worldForward: fwd,
                          worldUp: up,
                          worldGrip: pWrist,
                          localPos: SIMD3(-p4.z, -p4.x, p4.y),
                          localFwd: headLocalDir(fwd),
                          localUp: headLocalDir(up),
                          indexExtension: idxExt,
                          thumbExtension: thumbExt,
                          pinchAllSpread: spread,
                          middleCurlM: middleCurl)
    }

    /// The dominant hand as a Bip01 hand frame in GoldSrc world (inches,
    /// Z-up): X along the fingers, +Y out of the palm, at the wrist. The same
    /// frame the avatar's hand bone is given, so a gun pinned to either sits
    /// the same way in the hand.
    private func trackedHandFrame(_ hand: HandSample) -> float4x4 {
        let r = AvatarRig.handRotation(forward: studioDirection(hand.worldForward),
                                       back: studioDirection(hand.worldUp))
        var m = float4x4(r)
        m.columns.3 = SIMD4<Float>(studioPoint(hand.worldGrip), 1)
        return m
    }

    /// Where the drawn gun's barrel points, in the Apple world, for this
    /// tracked hand — nil with no external weapon or no grip to read it from.
    private func barrelDirection(_ hand: HandSample) -> SIMD3<Float>? {
        guard lambda_weapon_active() != 0, let pass = weaponPass, let grip = pass.grip,
              !pass.idlePalette.isEmpty else { return nil }
        let local = ViewmodelGrip.barrel(grip: grip, idlePalette: pass.idlePalette,
                                         handIsLeft: Renderer.dominantHandIsLeft)
        let r = AvatarRig.handRotation(forward: studioDirection(hand.worldForward),
                                       back: studioDirection(hand.worldUp))
        return appleDirection(r.act(local))
    }

    // Bone list for the wireframe arm skeleton: parent→child joint pairs,
    // drawn as line segments. Forearm (elbow→wrist) plus a full per-finger
    // chain from the wrist outward. Deliberately not gated on per-joint
    // isTracked, same reasoning as sampleDominantHand above — anchor-level
    // tracking is enough; self-occluded joints still carry a usable
    // estimated pose.
    private static let armBones: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
        (.forearmArm, .forearmWrist), (.forearmWrist, .wrist),
        (.wrist, .thumbKnuckle),
        (.thumbKnuckle, .thumbIntermediateBase),
        (.thumbIntermediateBase, .thumbIntermediateTip),
        (.thumbIntermediateTip, .thumbTip),
        (.wrist, .indexFingerMetacarpal),
        (.indexFingerMetacarpal, .indexFingerKnuckle),
        (.indexFingerKnuckle, .indexFingerIntermediateBase),
        (.indexFingerIntermediateBase, .indexFingerIntermediateTip),
        (.indexFingerIntermediateTip, .indexFingerTip),
        (.wrist, .middleFingerMetacarpal),
        (.middleFingerMetacarpal, .middleFingerKnuckle),
        (.middleFingerKnuckle, .middleFingerIntermediateBase),
        (.middleFingerIntermediateBase, .middleFingerIntermediateTip),
        (.middleFingerIntermediateTip, .middleFingerTip),
        (.wrist, .ringFingerMetacarpal),
        (.ringFingerMetacarpal, .ringFingerKnuckle),
        (.ringFingerKnuckle, .ringFingerIntermediateBase),
        (.ringFingerIntermediateBase, .ringFingerIntermediateTip),
        (.ringFingerIntermediateTip, .ringFingerTip),
        (.wrist, .littleFingerMetacarpal),
        (.littleFingerMetacarpal, .littleFingerKnuckle),
        (.littleFingerKnuckle, .littleFingerIntermediateBase),
        (.littleFingerIntermediateBase, .littleFingerIntermediateTip),
        (.littleFingerIntermediateTip, .littleFingerTip),
    ]
    private static let leftArmColor  = SIMD4<Float>(0.25, 0.95, 1.00, 1.0)  // cyan
    private static let rightArmColor = SIMD4<Float>(0.35, 1.00, 0.55, 1.0)  // green

    // MARK: First-person body

    /// The player body for this frame — mesh, bone palette and placement — or
    /// nil when there is nothing to draw (feature off, no model, no head).
    ///
    /// Everything the rig needs is converted into GoldSrc world axes (inches,
    /// Z-up, +X the tracking origin's forward) up front, solved there, and
    /// the result converted back once through `studioToWorld`. The palette
    /// never leaves GoldSrc space; only the root does.
    private func avatarBodyDraw(deviceAnchor: DeviceAnchor?, time: Double,
                                gripFingers: [String: simd_quatf]? = nil) -> WeaponPass.BodyDraw? {
        guard Renderer.avatarBodyEnabled, Renderer.avatarAvailable, let deviceAnchor else { return nil }
        if avatarRig == nil && !avatarRigFailed {
            do {
                avatarRig = try AvatarRig()
            } catch {
                avatarRigFailed = true
                AppLog.render.line("[Avatar] rig unavailable: \(error)")
            }
        }
        guard let rig = avatarRig else { return nil }

        // Upload the mesh once per bake, and again if the legs toggle moved,
        // since hidden bones are cut out of the vertex buffer.
        let gen = lambda_body_generation()
        if gen != 0, avatarMesh?.generation != gen || avatarMeshLegs != Renderer.avatarLegsVisible {
            var raw = lambda_weapon_mesh_t()
            if lambda_body_lock(&raw) != 0 {
                let legs = Renderer.avatarLegsVisible
                avatarMesh = StudioMesh(device: device, mesh: raw, generation: gen, label: "Body",
                                        hiddenBones: rig.hiddenBones(legs: legs))
                avatarMeshLegs = legs
                if let m = avatarMesh {
                    AppLog.render.line("[Avatar] uploaded gen=\(gen) verts=\(m.vertexCount) submeshes=\(m.submeshes.count) textures=\(m.textures.count) legs=\(legs)")
                }
            }
            lambda_body_unlock()
        }
        guard let mesh = avatarMesh else { return nil }

        // Head: eyes and gaze, in GoldSrc world.
        let h = deviceAnchor.originFromAnchorTransform
        let fwd = studioDirection(-SIMD3(h.columns.2.x, h.columns.2.y, h.columns.2.z))
        let up = studioDirection(SIMD3(h.columns.1.x, h.columns.1.y, h.columns.1.z))
        let eye = studioPoint(SIMD3(h.columns.3.x, h.columns.3.y, h.columns.3.z))

        // Body yaw trails head yaw (~0.35 s time constant). The render loop
        // calls this once per drawable, so only advance on a new frame time.
        let headYaw = atan2f(fwd.y, fwd.x)
        var yaw = avatarBodyYaw ?? headYaw
        if let last = avatarLastTime, time > last {
            let dt = Float(min(time - last, 0.1))
            var d = headYaw - yaw
            d = atan2f(sinf(d), cosf(d))
            yaw += d * (1 - expf(-dt / 0.35))
        }
        if avatarLastTime != time { avatarLastTime = time; avatarBodyYaw = yaw }

        var targets = AvatarRig.Targets(headPosition: eye, bodyYaw: yaw, leftHand: nil, rightHand: nil,
                                        headRotation: AvatarRig.headRotation(forward: fwd, up: up))
        if let l = avatarWrist(handTracking.latestAnchors.leftHand, left: true) {
            targets.leftHand = l.position; targets.leftHandRotation = l.rotation; targets.leftElbow = l.elbow
        }
        if let r = avatarWrist(handTracking.latestAnchors.rightHand, left: false) {
            targets.rightHand = r.position; targets.rightHandRotation = r.rotation; targets.rightElbow = r.elbow
        }
        // The hand holding the gun closes around it the way the viewmodel's
        // own hand did — only a tracked one, since an untracked hand hangs
        // and holds nothing.
        if let gripFingers {
            if Renderer.dominantHandIsLeft, targets.leftHand != nil { targets.leftFingers = gripFingers }
            if !Renderer.dominantHandIsLeft, targets.rightHand != nil { targets.rightFingers = gripFingers }
        }
        let pose: AvatarRig.Pose
        if Renderer.avatarLegsVisible, let ground = avatarGround(eye: eye, time: time) {
            if avatarGait == nil { avatarGait = AvatarGait(rig: rig) }
            var gait = avatarGait!
            pose = rig.pose(targets) { hips, forward in gait.feet(hips: hips, forward: forward, ground: ground) }
            avatarGait = gait
        } else {
            pose = rig.pose(targets)
        }
        return WeaponPass.BodyDraw(mesh: mesh, palette: pose.palette, model: studioToWorld * pose.root,
                                   leftHand: rig.handMatrix(pose, left: true),
                                   rightHand: rig.handMatrix(pose, left: false))
    }

    /// What the game says about the ground under the player, in the rig's
    /// room space (GoldSrc axes, inches): the floor's height, whether the
    /// player stands on it, and the velocity the game world is carrying them
    /// at. nil before the first publish.
    ///
    /// The engine measures its eye height from the refdef, before the
    /// headset's own translation is added, so the head offset goes back on
    /// top; the floor then sits exactly where the rendered world has it.
    /// Velocity arrives in the player-yaw frame, and the room maps onto the
    /// game by the yaw baseline alone (the engine rotates the head offset by
    /// player yaw after removing the baseline), so one rotation by the
    /// baseline brings it into the room.
    private func avatarGround(eye: SIMD3<Float>, time: Double) -> AvatarGait.Ground? {
        var state = lambda_body_state_t()
        lambda_body_state(&state)
        if state.sequence != avatarBodySequence {
            avatarBodySequence = state.sequence
            avatarBodySeenAt = time
        }
        guard avatarBodySequence != 0 else { return nil }
        let stale = time - avatarBodySeenAt > 0.25
        let dt = Float(min(max(time - (avatarLastGroundTime ?? time), 0), 0.1))
        avatarLastGroundTime = time
        let yaw = (headBaselineYaw ?? 0) * .pi / 180
        let c = cosf(yaw), sn = sinf(yaw)
        let vf = state.velocity.0, vl = state.velocity.1
        let velocity = stale ? .zero : SIMD3<Float>(vf * c - vl * sn, vf * sn + vl * c, 0)
        return AvatarGait.Ground(floor: eye.z - (state.eye_height + avatarHeadOffsetZ),
                                 grounded: state.on_ground != 0 && state.water_level < 2,
                                 velocity: velocity, deltaTime: dt)
    }

    /// A tracked arm as the rig wants it, in GoldSrc world: the wrist, the
    /// wrist rotation built from where the fingers point and the back of the
    /// hand — the same two axes the weapon grip uses, so the body's hand and
    /// the gun agree on which way the hand faces — and the elbow, which
    /// ARKit's hand skeleton carries as the far end of the forearm.
    private func avatarWrist(_ hand: HandAnchor?, left: Bool)
        -> (position: SIMD3<Float>, rotation: simd_quatf, elbow: SIMD3<Float>)? {
        guard handTracking.state == .running, let hand, hand.isTracked,
              let skel = hand.handSkeleton else { return nil }
        let handT = hand.originFromAnchorTransform
        func worldPos(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let t = handT * skel.joint(name).anchorFromJointTransform
            return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        let wrist = worldPos(.wrist)
        let fwd = simd_normalize(worldPos(.middleFingerKnuckle) - wrist)
        // Index → little knuckle runs across the palm; negated on the left
        // hand so the cross product gives the back of the hand on both.
        let acrossRaw = worldPos(.littleFingerKnuckle) - worldPos(.indexFingerKnuckle)
        let across = simd_normalize(left ? -acrossRaw : acrossRaw)
        let back = simd_normalize(simd_cross(across, fwd))
        return (studioPoint(wrist),
                AvatarRig.handRotation(forward: studioDirection(fwd), back: studioDirection(back)),
                studioPoint(worldPos(.forearmArm)))
    }

    /// Flat [pos.xyz, color.rgba] x N array (world space, metres) for every
    /// tracked hand's skeleton — see ArmPass. Empty when hand tracking isn't
    /// running or neither hand is currently tracked.
    private func armSkeletonVertices() -> [Float] {
        guard handTracking.state == .running else { return [] }
        var verts: [Float] = []
        verts.reserveCapacity(Renderer.armBones.count * 2 * ArmPass.floatsPerVertex * 2)
        for (hand, color) in [(handTracking.latestAnchors.leftHand, Renderer.leftArmColor),
                              (handTracking.latestAnchors.rightHand, Renderer.rightArmColor)] {
            guard let hand, hand.isTracked, let skel = hand.handSkeleton else { continue }
            let handT = hand.originFromAnchorTransform
            func worldPos(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
                let t = handT * skel.joint(name).anchorFromJointTransform
                return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
            for (a, b) in Renderer.armBones {
                let pa = worldPos(a), pb = worldPos(b)
                verts.append(contentsOf: [pa.x, pa.y, pa.z, color.x, color.y, color.z, color.w])
                verts.append(contentsOf: [pb.x, pb.y, pb.z, color.x, color.y, color.z, color.w])
            }
        }
        return verts
    }

    // Head position (xash basis, meters) captured together with the yaw
    // baseline; physical movement is delivered as a delta from here.
    private var headBaselinePos: SIMD3<Float>? = nil

    // Recenter support. The baselines above are captured once and normally
    // never move, but the ARKit world origin CAN move under them: a
    // crown-hold recenter swaps the origin outright, and hiding the
    // immersive space long enough for visionOS to drop tracking makes it
    // relocalize to a shifted origin on resume. Either way the stale
    // baseline turns into a huge headOffset and the camera "teleports"
    // into neighboring rooms. `recenterPending` (render thread only) is
    // set by renderLoop when the layer resumes from .paused; origin swaps
    // mid-session are self-detected in renderFrame as an implausible
    // pose jump between samples (there is no public recenter callback).
    private var recenterPending = false
    private var lastHeadSample: (pos: SIMD3<Float>, yaw: Float, time: Double)? = nil

    // Finger-gun trigger state (render thread): true while +attack is held via
    // the index-curl gesture, so we only send +attack/-attack on transitions.
    private var fireGestureDown = false

    // Reload gesture state (render thread). reloadStart is the timestamp the
    // thumb-curl hold began (nil = not holding); reloadLatched blocks repeat
    // fires until the thumb re-extends; reloadRingProgress is what the
    // weapon pass draws this frame (0 = no ring).
    private var reloadStart: Double? = nil
    private var reloadLatched = false
    private var reloadRingProgress: Float = 0

    // Radial weapon menu state (render thread). Non-nil anchor = menu open,
    // holding the wrist position where the 🤌 engaged; selection is the
    // armed sector index (-1 inside the deadzone). Selection commits on a
    // clean release (spread past exit); a lost hand or engine menu cancels.
    private var weaponMenuAnchor: SIMD3<Float>? = nil
    private var weaponMenuSelected = -1

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
                                                                       layerRenderer: layerRenderer,
                                                                       fxaa: false)
            fullscreenFXAAPipelineState = try Self.buildFullscreenPipeline(device: device,
                                                                          layerRenderer: layerRenderer,
                                                                          fxaa: true)
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
            // Per-source spatial audio. PHASE (PhaseAudioEngine) is the live
            // renderer; the older AVAudioEnvironmentNode path
            // (SpatialAudioEngine) is parked — that node outputs silence on
            // visionOS. Whichever registers the SoundAPI callbacks intercepts
            // world channels for spatial rendering; the engine's stock stereo
            // mixer keeps the bed (music/UI/player-own sounds). If neither is
            // enabled, HUD_GetSoundInterface declines and the mixer does
            // everything head-locked.
            // Must precede engine init (first renderFrame): the engine
            // captures the spatial-audio SoundAPI callbacks during S_Init.
            if PhaseAudioEngine.enabled {
                PhaseAudioEngine.shared.register()
            } else if SpatialAudioEngine.enabled {
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
    // `fxaa` picks the fragment function: the plain sampler, or the same
    // composite with the FXAA kernel folded in (zero extra passes — just the
    // neighbourhood taps at the sampled texture's texel size). Everything
    // else about the two pipelines is identical.
    static func buildFullscreenPipeline(device: MTLDevice,
                                        layerRenderer: LayerRenderer,
                                        fxaa: Bool) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = fxaa ? "FullscreenFXAAPipeline" : "FullscreenPipeline"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertexShader")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(
            name: fxaa ? "fragmentShaderFXAA" : "fragmentShader")
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
        AppLog.render.line("[LambdaVision] gl-worker setup rc=\(workerRc): \(String(cString: workerStatus))")

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
            AppLog.render.line("[LambdaVision] rateMaps=\(drawable.rasterizationRateMaps.count) "
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
        // 0.7 if busy scenes judder. Now driven by the Graphics settings
        // (Renderer.engineScale); read here so a change takes effect on the
        // next immersive-space open.
        let engineScale = Double(Renderer.engineScale)
        let maxDim = 4096
        var s = engineScale
        if Double(max(w, h)) * s > Double(maxDim) {
            s = Double(maxDim) / Double(max(w, h))
        }
        w = Int((Double(w) * s).rounded())
        h = Int((Double(h) * s).rounded())
        AppLog.render.line("[LambdaVision] drawable physical=\(physW)x\(physH) → colorMap \(w)x\(h) bgra8Unorm via ANGLE")

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
        // DISABLED (and no longer reachable from Settings — the toggle is
        // hidden and GameSettings forces it false at startup): frame timing
        // showed the FXAA+MetalFX+composite chain costs ~13-14 ms GPU/frame
        // (angleGPU p50 0.7 ms vs frameGPU p50 14-16 ms) — the whole app was
        // GPU-bound at ~50 FPS on the post chain alone. At 0.75x engine scale
        // the scaler's win over the composite pass's bilinear sample doesn't
        // justify two extra full-res passes per eye, and upscaling to the
        // full drawable fights the compositor's own foveated upsampling.
        // Edge smoothing now happens inside the composite pass instead
        // (fragmentShaderFXAA / Renderer.compositeFXAA).
        let useMetalFXChain = Renderer.useMetalFXChain
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
                    AppLog.render.line("[LambdaVision] FXAA + MetalFX spatial upscale \(w)x\(h) → \(logicalW)x\(logicalH)")
                }
            }
        }
        if displayMap == nil {
            AppLog.render.line("[LambdaVision] MetalFX upscale inactive — displaying colorMap directly")
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
        // Game assets: prefer a copy pushed to Documents/GameData (one-time
        // `scripts/push-assets.sh` — survives plain reinstalls, so code-only
        // installs stay small/fast, but lives in the data container and is
        // wiped by an uninstall). Fall back to assets bundled into the app
        // (`build-and-sign.sh --set BUNDLE_HL_ASSETS=1`), and if neither is
        // present, tell the player instead of letting the engine fail.
        let docsGameData = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("GameData").path }
        let bundleGameData = (Bundle.main.resourcePath ?? "") + "/GameData"
        let rodir: String
        if let d = docsGameData,
           FileManager.default.fileExists(atPath: d + "/valve/liblist.gam") {
            rodir = d
        } else if FileManager.default.fileExists(atPath: bundleGameData + "/valve/liblist.gam") {
            rodir = bundleGameData
        } else {
            // Neither the Documents copy (scripts/push-assets.sh) nor a
            // bundled copy (build-and-sign.sh --set BUNDLE_HL_ASSETS=1) is
            // present. Most commonly: the app's data container was wiped by
            // an uninstall/reinstall, which push-assets.sh's copy doesn't
            // survive. Don't bother calling into the engine — it will just
            // fail the same way — and tell the player how to fix it instead.
            AppLog.render.line("[LambdaVision] GameData missing (checked \(docsGameData ?? "<no docs dir>") and \(bundleGameData)) — skipping engine init")
            Task { @MainActor [appModel] in
                appModel.engineFailureMessage =
                    "Half-Life game data not found on this headset. From your Mac, run ./scripts/push-assets.sh (fetch it first with ./scripts/fetch-assets.sh if you haven't already), then relaunch."
            }
            return
        }
        AppLog.render.line("[LambdaVision] rodir: \(rodir)")
        let extra = ["-dev", "2", "-console", "-noip", "-noenginemouse",
                     "-rodir", rodir, "-game", "valve",
                     "+map", "c0a0"] // tram ride (Black Mesa Inbound)
        // -noenginemouse: no real mouse on AVP. Keeps in_mouseinitialized
        // false so the engine's per-frame IN_MouseMove is a no-op and can't
        // overwrite the synthetic menu cursor we inject (Lambda_Bridge
        // lambda_menu_*). We drive weapon aim / menu clicks ourselves.
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
        AppLog.render.line("[LambdaVision] Engine: rc=\(rc) \(String(cString: buf))")

        // First-person avatar. Nothing in the engine publishes a player model
        // (you never see yourself in single-player), so load it straight off
        // the read-only game data. The deathmatch Gordon is the best body we
        // have: 343 source vertices, a full Bip01 skeleton with both arm
        // chains, embedded textures, and life-size at 72 units. Body value 1
        // selects its high-detail submodel over the low-detail one.
        // Non-fatal: without it we simply draw no body.
        let bodyModel = rodir + "/valve/models/player/gordon/gordon.mdl"
        let bodyLoaded = bodyModel.withCString { lambda_body_load($0, 1) } != 0
        Renderer.avatarAvailable = bodyLoaded
        AppLog.render.line("[LambdaVision] avatar model \(bodyLoaded ? "loaded" : "MISSING"): \(bodyModel)")
        if rc == 0 {
            // Engine + GL worker are now up, so cvar commands are safe to post.
            // Flush the archived Graphics/Audio/Input cvars and enable live pushes.
            Task { @MainActor [appModel] in appModel.gameSettings.engineDidStart() }
        } else {
            let detail = String(cString: buf)
            Task { @MainActor [appModel] in
                appModel.engineFailureMessage = "Half-Life engine failed to start (rc=\(rc))"
                    + (detail.isEmpty ? "." : ": \(detail)")
            }
        }
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

            // Recenter: drop the baselines so they re-capture at the CURRENT
            // pose below — headOffset collapses to 0 (camera lands back on
            // the player entity) and the yaw delta resets (head-forward maps
            // onto the engine's current view yaw). Triggered by renderLoop
            // on resume from a paused layer, or self-detected here when the
            // head "moves" faster than a head physically can between samples
            // — the signature of an ARKit origin swap (crown-hold recenter
            // or relocalization after tracking loss). Thresholds scale with
            // the sample gap so a real walk during a tracking dropout isn't
            // mistaken for a jump.
            var recenter = recenterPending
            recenterPending = false
            if !recenter, let last = lastHeadSample {
                let dt = Float(min(max(presentTime - last.time, 0.001), 10.0))
                var dY = yawDeg - last.yaw
                if dY > 180 { dY -= 360 } else if dY < -180 { dY += 360 }
                let moved = simd_distance(cur.pos, last.pos)
                if moved > 0.3 + 1.5 * dt || abs(dY) > 25 + 180 * dt {
                    recenter = true
                }
            }
            lastHeadSample = (cur.pos, yawDeg, presentTime)
            if recenter, headBaselineYaw != nil {
                headBaselineYaw = nil
                headBaselinePos = nil
                Renderer.aimDiag.nRecenter += 1
                AppLog.render.line("[LambdaVision] recenter: re-anchoring head baseline "
                    + "(#\(Renderer.aimDiag.nRecenter))")
            }

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
            avatarHeadOffsetZ = d.z

            // Aim ray + hand-anchored weapon. With the dominant hand
            // tracked, the weapon renders at the hand (p_ model, composed
            // hlsdk-side) and fires along the hand's pointing direction;
            // otherwise fall back to the pinch gaze ray, then view center.
            // Offsets in xash conventions (pitch positive down, yaw CCW).
            var aimDir: SIMD3<Float>? = nil  // Apple world basis
            let handSample = frameDeviceAnchor.flatMap {
                sampleDominantHand(headTransform: $0.originFromAnchorTransform)
            }
            if let hand = handSample {
                let p = hand.localPos * appleToXash
                lambda_set_hand_pose(p.x, p.y, p.z,
                                     hand.localFwd.x, hand.localFwd.y, hand.localFwd.z,
                                     hand.localUp.x, hand.localUp.y, hand.localUp.z)
                // Fire follows the weapon barrel by default — the drawn one,
                // read off the viewmodel's idle grip (barrelDirection), or the
                // wrist→knuckle ray for a viewmodel with no hand to hold it
                // by. The accessibility option aims along gaze instead, for
                // players who can't comfortably point with the hand.
                aimDir = Renderer.fireAlongGaze ? Renderer.currentGazeDir()
                                                : (barrelDirection(hand) ?? hand.worldForward)
                Renderer.aimDiag.aimSource = Renderer.fireAlongGaze ? "gaze(hand)" : "barrel"
            } else {
                lambda_clear_hand_pose()
                aimDir = Renderer.currentGazeDir()
                Renderer.aimDiag.aimSource = "gaze(fallback)"
            }
            Renderer.aimDiag.fireAlongGaze = Renderer.fireAlongGaze
            if let g = aimDir {
                let gx = SIMD3<Float>(-g.z, -g.x, g.y)  // Apple → xash basis
                let gPitch = atan2f(-gx.z, sqrtf(gx.x * gx.x + gx.y * gx.y)) * rad2deg
                let gYaw   = atan2f(gx.y, gx.x) * rad2deg
                var dy = gYaw - yawDeg
                if dy > 180 { dy -= 360 } else if dy < -180 { dy += 360 }
                lambda_set_aim_offset(gPitch - pitchDeg, dy)
                Renderer.aimDiag.pitch = gPitch - pitchDeg
                Renderer.aimDiag.yaw = dy
            } else {
                lambda_set_aim_offset(0, 0)
                // aimDir nil means "gaze fallback but no active pinch ray": the
                // offset collapses to zero, so shots go along the head view =
                // screen center. This is the "shoots at crosshair" symptom.
                Renderer.aimDiag.aimSource = "center(no-dir)"
                Renderer.aimDiag.pitch = 0
                Renderer.aimDiag.yaw = 0
            }

            // 🤌 radial weapon menu (opt-in, dominant hand). Runs BEFORE the
            // fire/reload reconciliation so an open menu owns the hand:
            // firing and reload are forced off while it's up (the converging
            // fingertips would otherwise read as index/thumb curls). Opening
            // requires all four fingertips near the thumb tip AND the fist
            // gate (a clenched fist keeps tips near the thumb too, but its
            // middle finger collapses to the palm). While open, wrist travel
            // from the engagement point arms a sector (12 o'clock = slot1,
            // clockwise); releasing the pinch commits it, releasing inside
            // the deadzone or losing the hand cancels.
            let hadWeaponMenu = weaponMenuAnchor != nil
            if Renderer.gestureInputEnabled, lambda_menu_active() == 0,
               let hand = handSample {
                Renderer.aimDiag.menuSpread = hand.pinchAllSpread
                if !hadWeaponMenu {
                    if hand.pinchAllSpread < Renderer.menuPinchEnter,
                       hand.middleCurlM > Renderer.menuFistGate,
                       !fireGestureDown {
                        weaponMenuAnchor = hand.worldGrip
                        weaponMenuSelected = -1
                    }
                } else if hand.pinchAllSpread > Renderer.menuPinchExit {
                    if weaponMenuSelected >= 0 {
                        _ = "slot\(weaponMenuSelected + 1)".withCString { lambda_gl_worker_cmd($0) }
                    }
                    weaponMenuAnchor = nil
                    weaponMenuSelected = -1
                } else if let mAnchor = weaponMenuAnchor, let da = frameDeviceAnchor {
                    let hm = da.originFromAnchorTransform
                    let hr = SIMD3<Float>(hm.columns.0.x, hm.columns.0.y, hm.columns.0.z)
                    let hu = SIMD3<Float>(hm.columns.1.x, hm.columns.1.y, hm.columns.1.z)
                    let d = hand.worldGrip - mAnchor
                    let dx = simd_dot(d, hr)
                    let dy = simd_dot(d, hu)
                    if (dx * dx + dy * dy).squareRoot() > Renderer.menuDeadzoneM {
                        var ang = atan2f(dx, dy)   // 0 = up, clockwise positive
                        if ang < 0 { ang += 2 * .pi }
                        weaponMenuSelected = Int(ang / (2 * .pi / 5)) % 5
                    } else {
                        weaponMenuSelected = -1
                    }
                }
            } else if hadWeaponMenu {
                weaponMenuAnchor = nil     // hand lost / gesture off → cancel
                weaponMenuSelected = -1
            }
            let weaponMenuOpen = weaponMenuAnchor != nil
            Renderer.aimDiag.menuOpen = weaponMenuOpen
            Renderer.aimDiag.menuSel = weaponMenuSelected

            // Finger-gun trigger (opt-in). Reconcile the held +attack state
            // with the current index curl each frame: pull below fireCurlOn,
            // release above fireCurlOff (hysteresis), and force-release when
            // the gesture is off, the menu is up, or the hand sample is gone —
            // so a lost hand mid-trigger can't leave fire stuck on. Edge-only
            // console commands, so this costs a worker round-trip only on a
            // press/release, not every frame. Pinch fire stays independent.
            var wantFire = fireGestureDown
            if Renderer.gestureInputEnabled, lambda_menu_active() == 0,
               !weaponMenuOpen, let hand = handSample {
                Renderer.aimDiag.indexExt = hand.indexExtension
                if hand.indexExtension < Renderer.fireCurlOn { wantFire = true }
                else if hand.indexExtension > Renderer.fireCurlOff { wantFire = false }
                // else: within the hysteresis band — hold the current state.
            } else {
                wantFire = false
            }
            if wantFire != fireGestureDown {
                fireGestureDown = wantFire
                _ = (wantFire ? "+attack" : "-attack").withCString { lambda_gl_worker_cmd($0) }
            }
            Renderer.aimDiag.gestureOn = Renderer.gestureInputEnabled
            Renderer.aimDiag.fireGesture = fireGestureDown

            // Reload gesture (opt-in, dominant hand): thumb curled down while
            // the index stays extended (off the trigger). The hold must last
            // reloadHoldSeconds before +reload fires — the progress ring the
            // weapon pass draws makes a stray curl visible before it commits.
            // Hysteresis on the thumb metric; curling the index (firing)
            // cancels the hold outright. Latched until the thumb re-extends
            // so one hold = one reload.
            var thumbHold = reloadStart != nil
            if Renderer.gestureInputEnabled, lambda_menu_active() == 0,
               !weaponMenuOpen, let hand = handSample {
                Renderer.aimDiag.thumbExt = hand.thumbExtension
                if hand.indexExtension < Renderer.fireCurlOn {
                    thumbHold = false   // trigger pulled — never reload mid-fire
                } else if hand.thumbExtension < Renderer.thumbCurlOn,
                          hand.indexExtension > Renderer.fireCurlOff {
                    thumbHold = true
                } else if hand.thumbExtension > Renderer.thumbCurlOff {
                    thumbHold = false
                }
                // else: inside a hysteresis band — keep the current state.
            } else {
                thumbHold = false
            }
            if thumbHold {
                if reloadStart == nil { reloadStart = presentTime }
                let prog = Float(min((presentTime - reloadStart!) / Renderer.reloadHoldSeconds, 1.0))
                if prog >= 1, !reloadLatched {
                    reloadLatched = true
                    _ = "+reload".withCString { lambda_gl_worker_cmd($0) }
                    _ = "-reload".withCString { lambda_gl_worker_cmd($0) }
                }
                // Hide the ring once fired: the full ring vanishing is the
                // "it took" cue; holding longer must not re-arm.
                reloadRingProgress = reloadLatched ? 0 : prog
            } else {
                reloadStart = nil
                reloadLatched = false
                reloadRingProgress = 0
            }
            Renderer.aimDiag.reloadProg = reloadRingProgress

            // Off-hand (non-dominant) locomotion joystick. Head axes in Apple
            // world (forward = -col2, right = +col0); HandMovement flattens Y.
            // Movement hand is the opposite of the dominant (gun) hand.
            if let anchor = frameDeviceAnchor {
                let hm = anchor.originFromAnchorTransform
                let headFwd = SIMD3<Float>(-hm.columns.2.x, -hm.columns.2.y, -hm.columns.2.z)
                let headRight = SIMD3<Float>(hm.columns.0.x, hm.columns.0.y, hm.columns.0.z)
                let headPos = SIMD3<Float>(hm.columns.3.x, hm.columns.3.y, hm.columns.3.z)
                let moveHand = Renderer.dominantHandIsLeft
                    ? handTracking.latestAnchors.rightHand
                    : handTracking.latestAnchors.leftHand
                // Train status from the server (0 = free; else 0x100 | gear+1).
                let trainState = Int(lambda_train_state())
                let onTrain = (trainState & 0x100) != 0
                let trainGear = onTrain ? (trainState & 0xFF) - 1 : 0
                Renderer.aimDiag.onTrain = onTrain
                Renderer.aimDiag.trainGear = trainGear
                let useRay = HandMovement.shared.poll(
                    active: Renderer.gestureInputEnabled && lambda_menu_active() == 0,
                    movementHand: moveHand,
                    headForward: headFwd,
                    headRight: headRight,
                    headPos: headPos,
                    onTrain: onTrain,
                    trainGear: trainGear,
                    now: CACurrentMediaTime())
                // Stage the eye→fingertip ray as the PlayerUse cone override,
                // converted to pitch/yaw offsets from the current view — the
                // same composition the fire aim offset uses.
                if let u = useRay {
                    let ux = SIMD3<Float>(-u.z, -u.x, u.y)  // Apple → xash basis
                    let uPitch = atan2f(-ux.z, sqrtf(ux.x * ux.x + ux.y * ux.y)) * rad2deg
                    let uYaw   = atan2f(ux.y, ux.x) * rad2deg
                    var duy = uYaw - yawDeg
                    if duy > 180 { duy -= 360 } else if duy < -180 { duy += 360 }
                    lambda_set_use_offset(uPitch - pitchDeg, duy, 1)
                } else {
                    lambda_set_use_offset(0, 0, 0)
                }
            }

            // Inputs for gaze→menu cursor mapping (used off-thread when a
            // pinch targets the stock menu). hudBoxAspect is set per frame in
            // the eye loop below.
            Renderer.latestHeadTransform = frameDeviceAnchor?.originFromAnchorTransform
            Renderer.renderTargetW = colorMap.width
            Renderer.renderTargetH = colorMap.height
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
                // The box's tan height/width ratio, for the gaze→menu mapper.
                if eye == 0 { Renderer.hudBoxAspect = sumV / sumH }
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
                AppLog.render.line("[LambdaVision] GL worker render eye=\(eye) rc=\(rc)")
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

        // Weapon pass: upload any freshly-baked mesh, pull this tick's bone
        // pose, gate on external mode, and size the weapon depth to the
        // drawable colour slice.
        if weaponPass == nil {
            weaponPass = WeaponPass(device: device, layerRenderer: layerRenderer,
                                    maxBuffersInFlight: maxBuffersInFlight)
        }
        weaponPass.update()
        let weaponActive = weaponPass.isReady && lambda_weapon_active() != 0
        let joystickVisible = HandMovement.joystickVisualization != nil
        var gripFingers: [String: simd_quatf]? = nil
        if weaponActive, let grip = weaponPass.grip, !weaponPass.palette.isEmpty {
            gripFingers = ViewmodelGrip.fingerPose(boneNames: weaponPass.boneNames,
                                                   palette: weaponPass.palette, grip: grip,
                                                   handIsLeft: Renderer.dominantHandIsLeft)
        }
        let body = avatarBodyDraw(deviceAnchor: deviceAnchor,
                                  time: drawable.frameTiming.presentationTime.timeInterval,
                                  gripFingers: gripFingers)
        // The body's hands replace the viewmodel's: its gloves, floating off
        // hand and sleeve are cut, and the gun alone goes into the avatar's
        // hand. Without a grip there is nothing to pin the gun by, so the
        // viewmodel keeps its hands.
        weaponPass.hideHands = body != nil && weaponPass.grip != nil
        let supplementalPassActive = weaponActive || joystickVisible || body != nil
        if supplementalPassActive {
            weaponPass.ensureDepth(width: drawable.colorTextures[0].width,
                                   height: drawable.colorTextures[0].height,
                                   slices: drawable.views.count)
        }

        // Wireframe arm skeleton: always active whenever a hand is tracked
        // (independent of weapon/joystick state) — real passthrough arms are
        // hidden for the whole immersive space via .upperLimbVisibility, so
        // this is the only visual replacement for the user's hands/forearms.
        if armPass == nil {
            armPass = ArmPass(device: device, layerRenderer: layerRenderer,
                              maxBuffersInFlight: maxBuffersInFlight)
        }
        // The avatar's arms are the replacement when the body is drawn.
        let armVertices = body == nil ? armSkeletonVertices() : []
        if !armVertices.isEmpty {
            armPass.ensureDepth(width: drawable.colorTextures[0].width,
                                height: drawable.colorTextures[0].height,
                                slices: drawable.views.count)
        }

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
        if supplementalPassActive {
            residencySet.addAllocations(weaponPass.residentResources(uniformBufferIndex: uniformBufferIndex,
                                                                     body: body?.mesh))
        }
        if !armVertices.isEmpty {
            residencySet.addAllocations(armPass.residentResources(uniformBufferIndex: uniformBufferIndex))
        }
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
        // FXAA rides along in this pass's fragment shader. Skipped when the
        // MetalFX chain is live: that path already ran a dedicated FXAA pass
        // into fxaaMap, and displayMap is what we'd be filtering here.
        let compositeFXAA = Renderer.compositeFXAA && spatialScalers.isEmpty
        renderEncoder.setRenderPipelineState(compositeFXAA ? fullscreenFXAAPipelineState
                                                           : fullscreenPipelineState)
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

        if !armVertices.isEmpty {
            armPass.encode(commandBuffer: commandBuffer, drawable: drawable,
                           viewProjectionBuffer: drawableTarget.viewProjectionBuffer,
                           viewProjectionOffset: drawableTarget.viewProjectionBufferOffset,
                           uniformBufferIndex: uniformBufferIndex,
                           vertexFloats: armVertices)
        }

        if supplementalPassActive {
            let anchorM = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            let headRight = SIMD3<Float>(anchorM.columns.0.x, anchorM.columns.0.y, anchorM.columns.0.z)
            let headUp = SIMD3<Float>(anchorM.columns.1.x, anchorM.columns.1.y, anchorM.columns.1.z)
            var model = matrix_identity_float4x4
            var drawWeapon = false
            var arcs: [WeaponPass.Arc] = []

            // World light sampled at the eye by the engine (R_LightPoint),
            // split into an ambient floor + a soft top-down directional so
            // the gun and the body match room brightness/tint yet keep some
            // shape.
            var lrgb: [Float] = [0.5, 0.5, 0.5]
            lrgb.withUnsafeMutableBufferPointer { lambda_weapon_get_light($0.baseAddress!) }
            let lc = SIMD3<Float>(lrgb[0], lrgb[1], lrgb[2])
            let lightColor = lc * 0.7
            let ambient = lc * 0.6

            if let stick = HandMovement.joystickVisualization {
                let visualRadius: Float = 0.065
                let fullScale = max(stick.fullScaleMeters, 0.0001)
                let displacement = stick.handle - stick.center
                let x = simd_dot(displacement, stick.basis.right) / fullScale
                let y = simd_dot(displacement, stick.basis.forward) / fullScale
                let center = stick.center + SIMD3<Float>(0, 0.08, 0)
                let deadzoneRadius = visualRadius
                    * min(1, max(0, stick.deadzoneMeters / fullScale))
                let handle = center + headRight * (x * visualRadius) + headUp * (y * visualRadius)
                let active = simd_length(stick.value) > 0.001

                arcs.append(WeaponPass.Arc(
                    center: center,
                    right: headRight,
                    up: headUp,
                    innerR: visualRadius - 0.004,
                    outerR: visualRadius,
                    color: SIMD4(0.55, 0.58, 0.64, 1),
                    startTurns: 0,
                    sweepTurns: 1
                ))
                arcs.append(WeaponPass.Arc(
                    center: center,
                    right: headRight,
                    up: headUp,
                    innerR: max(0, deadzoneRadius - 0.002),
                    outerR: deadzoneRadius,
                    color: SIMD4(0.35, 0.37, 0.42, 1),
                    startTurns: 0,
                    sweepTurns: 1
                ))
                arcs.append(WeaponPass.Arc(
                    center: handle,
                    right: headRight,
                    up: headUp,
                    innerR: 0,
                    outerR: 0.011,
                    color: active
                        ? SIMD4(1.0, 0.78, 0.25, 1)
                        : SIMD4(0.72, 0.74, 0.78, 1),
                    startTurns: 0,
                    sweepTurns: 1
                ))
            }

            // Hand-anchored placement from the LIVE hand frame this frame — no
            // engine round-trip, so head rotation can't shear it (the drift the
            // engine-side path had). Skip drawing when the hand isn't tracked.
            if weaponActive, let hand = sampleDominantHand(headTransform: anchorM) {
                drawWeapon = true
                let fwd = hand.worldForward
                let up  = hand.worldUp
                let right = simd_normalize(simd_cross(up, fwd))
                // World hand frame: local (x=right, y=up, z=forward) → world.
                var handWorld = matrix_identity_float4x4
                handWorld.columns.0 = SIMD4<Float>(right, 0)
                handWorld.columns.1 = SIMD4<Float>(up, 0)
                handWorld.columns.2 = SIMD4<Float>(fwd, 0)
                handWorld.columns.3 = SIMD4<Float>(hand.worldGrip, 1)

                if let grip = weaponPass.grip {
                    // Pin the viewmodel's grip bone onto a Bip01 hand frame —
                    // the avatar's posed hand when the body is drawn (so the
                    // gun stays in the visible hand even where the arm cannot
                    // quite reach the tracked one), else the tracked hand
                    // itself. Both are the same Bip01 convention every stock
                    // viewmodel hand uses, so no tuned correction sits in
                    // between. The grip bone is this tick's pose, so recoil,
                    // the pump and the magazine animate around a still hand.
                    let left = Renderer.dominantHandIsLeft
                    let bodyHand = left ? body?.leftHand : body?.rightHand
                    let handFrame = bodyHand ?? trackedHandFrame(hand)
                    model = studioToWorld * ViewmodelGrip.modelMatrix(hand: handFrame, grip: grip,
                                                                      palette: weaponPass.palette,
                                                                      handIsLeft: left)
                } else {
                    // No hand to hold it by (the hivehand): the old tuned
                    // placement of the viewmodel origin at the hand.
                    let B = studioToWorld   // GoldSrc (x fwd, y left, z up, inches) → Apple metres
                    let C = matrix4x4_translation(0, 0, Renderer.gripPushM)
                          * matrix4x4_rotation(radians: Renderer.gripYawDeg   * .pi/180, axis: SIMD3(0,1,0))
                          * matrix4x4_rotation(radians: Renderer.gripPitchDeg * .pi/180, axis: SIMD3(1,0,0))
                          * matrix4x4_rotation(radians: Renderer.gripRollDeg  * .pi/180, axis: SIMD3(0,0,1))
                    model = handWorld * C * B
                }

                // UI arcs, billboarded to the head so they read from any
                // angle: the reload-hold ring floats above the weapon; the
                // radial weapon menu draws five sector wedges around the
                // point where the 🤌 engaged, the armed one highlighted.
                if reloadRingProgress > 0 {
                    arcs.append(WeaponPass.Arc(center: hand.worldGrip + SIMD3<Float>(0, 0.13, 0),
                                               right: headRight, up: headUp,
                                               innerR: 0.022, outerR: 0.030,
                                               color: SIMD4(1.0, 0.78, 0.25, 1),  // HL amber
                                               startTurns: 0, sweepTurns: reloadRingProgress))
                }
                if let mAnchor = weaponMenuAnchor {
                    let gap: Float = 0.012   // turns of separation between sectors
                    for i in 0..<5 {
                        let armed = (i == weaponMenuSelected)
                        arcs.append(WeaponPass.Arc(center: mAnchor,
                                                   right: headRight, up: headUp,
                                                   innerR: armed ? 0.050 : 0.055,
                                                   outerR: armed ? 0.098 : 0.088,
                                                   color: armed ? SIMD4(1.0, 0.78, 0.25, 1)
                                                                : SIMD4(0.45, 0.47, 0.52, 1),
                                                   startTurns: Float(i) / 5 + gap,
                                                   sweepTurns: 1.0 / 5 - 2 * gap))
                    }
                }
                // Train-throttle gear ladder: five rings stacked above the
                // grab point (R at the bottom, full speed on top); the ring
                // for the CURRENT gear fills amber, the armed target (while
                // the train steps toward it) shows as a brighter outline.
                if let gauge = HandMovement.throttleGauge {
                    for g in -1...3 {
                        let pos = gauge.center + SIMD3<Float>(0, 0.06 + Float(g + 1) * 0.035, 0)
                        let isCur = (g == gauge.gear)
                        let isTgt = (g == gauge.target)
                        arcs.append(WeaponPass.Arc(center: pos,
                                                   right: headRight, up: headUp,
                                                   innerR: isCur ? 0.002 : 0.009,
                                                   outerR: isCur ? 0.013 : (isTgt ? 0.014 : 0.012),
                                                   color: isCur ? SIMD4(1.0, 0.78, 0.25, 1)
                                                        : (isTgt ? SIMD4(0.95, 0.95, 0.95, 1)
                                                                 : SIMD4(0.45, 0.47, 0.52, 1)),
                                                   startTurns: 0, sweepTurns: 1))
                    }
                }
            }

            if drawWeapon || body != nil || !arcs.isEmpty {
                // Per-eye camera position + right axis in world metres, for the
                // chrome environment map (GoldSrc builds its sphere map from
                // the viewer→surface vector and the camera's right axis).
                var eyePositions: [SIMD3<Float>] = []
                var eyeRights: [SIMD3<Float>] = []
                for view in drawable.views {
                    let eyeToWorld = anchorM * view.transform
                    eyePositions.append(SIMD3(eyeToWorld.columns.3.x,
                                              eyeToWorld.columns.3.y,
                                              eyeToWorld.columns.3.z))
                    eyeRights.append(simd_normalize(SIMD3(eyeToWorld.columns.0.x,
                                                          eyeToWorld.columns.0.y,
                                                          eyeToWorld.columns.0.z)))
                }
                weaponPass.encode(commandBuffer: commandBuffer, drawable: drawable,
                                  viewProjectionBuffer: drawableTarget.viewProjectionBuffer,
                                  viewProjectionOffset: drawableTarget.viewProjectionBufferOffset,
                                  uniformBufferIndex: uniformBufferIndex,
                                  model: model,
                                  lightDir: normalize(SIMD3<Float>(0.2, 1.0, 0.3)),
                                  lightColor: lightColor,
                                  ambient: ambient,
                                  eyePositions: eyePositions,
                                  eyeRights: eyeRights,
                                  drawWeapon: drawWeapon,
                                  body: body,
                                  arcs: arcs)
            }
        }

        commandBuffer.endCommandBuffer()

        self.commandQueue.commit([commandBuffer])

        drawable.encodePresent()
    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                AppLog.render.line("Layer is invalidated")
                // Persist binds/cvars while the engine is still up (visionOS
                // may kill us without a clean Host_Shutdown).
                _ = "host_writeconfig".withCString { lambda_gl_worker_cmd($0) }
                // The engine stops ticking here but the AudioQueue would
                // keep streaming the DMA ring — the last painted samples
                // loop audibly forever. Pause output with the renderer.
                // PHASE runs on its own engine (not the DMA ring), so its
                // loops sustain unless we stop it too.
                lambda_snd_activate(0)
                PhaseAudioEngine.shared.setActive(false)
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                // Backgrounded/hidden — a good moment to persist config.
                _ = "host_writeconfig".withCString { lambda_gl_worker_cmd($0) }
                lambda_snd_activate(0)
                PhaseAudioEngine.shared.setActive(false)
                layerRenderer.waitUntilRunning()
                lambda_snd_activate(1)
                PhaseAudioEngine.shared.setActive(true)
                // While hidden, visionOS may have lost tracking and
                // relocalized to a shifted origin (or the user recentered) —
                // re-anchor the head baselines on the first resumed frame so
                // the camera resumes on the player entity, not a stale
                // room-space offset. The user also physically moved the
                // headset meanwhile in most cases, so a resume-recenter is
                // the right behavior even when the origin didn't shift.
                recenterPending = true
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
/// GoldSrc axes (x forward, y left, z up; inches) → Apple world (metres).
/// The one place the two bases meet for skinned models: weapon placement
/// and the avatar root both go through it, and `studioDirection` /
/// `studioPoint` are its inverse for taking tracking data the other way.
nonisolated let studioToWorld: float4x4 = {
    let s: Float = 1.0 / 39.37
    return float4x4(columns: (
        SIMD4<Float>(0,  0, -s, 0),
        SIMD4<Float>(-s, 0,  0, 0),
        SIMD4<Float>(0,  s,  0, 0),
        SIMD4<Float>(0,  0,  0, 1)))
}()

/// Apple world direction → GoldSrc axes (unit length preserved).
nonisolated func studioDirection(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-v.z, -v.x, v.y) }

/// GoldSrc axes → Apple world direction; the inverse of `studioDirection`.
nonisolated func appleDirection(_ s: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-s.y, s.z, -s.x) }

/// Apple world point (metres) → GoldSrc axes (inches).
nonisolated func studioPoint(_ p: SIMD3<Float>) -> SIMD3<Float> { studioDirection(p) * 39.37 }

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