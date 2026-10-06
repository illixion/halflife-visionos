//
//  GameSettings.swift
//  LambdaVision
//
//  The player-facing settings model + the layer that applies them to the
//  engine. SettingsView binds to these properties; each `didSet` persists to
//  AppSettingsStore and pushes the change to the running game.
//
//  Two apply mechanisms:
//    • cvar settings  → `lambda_gl_worker_cmd("name value")`, which posts to
//      the GL worker. This DEADLOCKS if called before the worker exists
//      (worker_post_and_wait waits on a ticket no thread will complete), so
//      cvar pushes are gated behind `engineReady` and flushed once from
//      Renderer.ensureEngineInitialized() via engineDidStart().
//    • Renderer-static settings → assign the nonisolated statics directly.
//      Two of them (engineScale, useMetalFXChain) size the render targets and
//      are only read at drawable setup, so they take effect on the next
//      immersive-space open; applyRendererStatics() runs at init so the first
//      setup already sees the stored values. The rest (including
//      compositeFXAA) are read per frame and so apply live.
//

import Foundation
import DebugTrace

enum DominantHand: String, CaseIterable, Identifiable {
    case right, left
    var id: String { rawValue }
    var label: String { self == .right ? "Right" : "Left" }
}

enum FireAimMode: String, CaseIterable, Identifiable {
    case barrel, gaze
    var id: String { rawValue }
    var label: String { self == .barrel ? "Weapon barrel" : "Where I look" }
}

/// The aim reticle: where the barrel's shot would land, marked in the world.
enum AimReticle: String, CaseIterable, Identifiable {
    case off, dot, beam
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .dot: "Dot"
        case .beam: "Dot and beam"
        }
    }
    var style: HEVHUD.Reticle {
        switch self {
        case .off: .off
        case .dot: .dot
        case .beam: .beam
        }
    }
}

/// Where the HEV holograms go with a keyboard, mouse or gamepad.
enum FlatHUDPlacement: String, CaseIterable, Identifiable {
    case followView, hands
    var id: String { rawValue }
    var label: String { self == .followView ? "Follow view (lazy)" : "Attached to hands" }
}

/// Which model of the weapon is held: the first-person viewmodel, animated
/// but modelled only for the side the old camera saw, or the third-person
/// world model, whole but rigid (reloads then show as the ring alone).
enum WeaponModelStyle: String, CaseIterable, Identifiable {
    case viewmodel, world
    var id: String { rawValue }
    var label: String { self == .viewmodel ? "Viewmodel" : "World model" }
}

/// Which way arm-swing walking goes (RAVEArmSwingDirection, as a setting).
enum ArmSwingDirection: String, CaseIterable, Identifiable {
    case head, hands
    var id: String { rawValue }
    var label: String { self == .head ? "Where I look" : "Where my fists point" }
}

@MainActor
@Observable
final class GameSettings {

    /// True once the engine (and its GL worker) is up and cvar/console
    /// commands are safe to dispatch (worker_post_and_wait deadlocks before
    /// the worker exists). Flipped by engineDidStart(); observed by SettingsView
    /// so the Advanced console/menu/map actions stay disabled until the game
    /// is running.
    private(set) var isEngineReady = false

    // MARK: Graphics
    /// Render scale above this leaves nothing for MetalFX to upscale. Only
    /// meaningful if the (currently hidden) MetalFX setting ever returns.
    static let metalFXMaxScale = 0.75

    var renderScale: Double = AppSettingsStore.renderScale {
        didSet { AppSettingsStore.renderScale = renderScale
                 Renderer.engineScale = Float(renderScale)
                 // MetalFX only makes sense when we're upscaling.
                 if renderScale > GameSettings.metalFXMaxScale && metalFXEnabled {
                     metalFXEnabled = false
                 }
        }
    }
    /// HIDDEN from SettingsView and deliberately NOT seeded from
    /// AppSettingsStore: the optional FXAA-pass → MetalFX-spatial-upscale
    /// chain adds two full-logical-resolution passes per eye and measured
    /// ~13-14 ms GPU/frame (frameGPU p50 14-16 ms vs angleGPU p50 0.7 ms),
    /// pinning the app at ~50 FPS; upscaling to the full drawable also fights
    /// the compositor's own foveated upsampling. Starting from `false` rather
    /// than the stored value means a user who enabled it before the toggle
    /// disappeared isn't stranded at 50 FPS. The scaler code path stays
    /// compiled (Renderer.useMetalFXChain / ensureColorMap) in case it
    /// returns; edge smoothing now lives in the composite pass instead
    /// (`fxaaEnabled`).
    var metalFXEnabled: Bool = false {
        didSet { AppSettingsStore.metalFXEnabled = metalFXEnabled
                 Renderer.useMetalFXChain = metalFXEnabled }
    }
    /// FXAA folded into the composite/display fragment shader — the cheap
    /// replacement for the chain above (no extra pass, no intermediate
    /// texture, just the neighbourhood taps at engine texel size). Live: the
    /// renderer picks between two pipeline states per frame.
    var fxaaEnabled: Bool = AppSettingsStore.fxaaEnabled {
        didSet { AppSettingsStore.fxaaEnabled = fxaaEnabled
                 Renderer.compositeFXAA = fxaaEnabled }
    }
    /// The drawable is linear light; the engine's image is gamma-encoded.
    /// On, every game colour is decoded before it lands there (true darks);
    /// off writes the engine's values as they are, which lifts everything
    /// under white. Live.
    var linearColor: Bool = AppSettingsStore.linearColor {
        didSet { AppSettingsStore.linearColor = linearColor
                 Renderer.displayDecodeGamma = linearColor ? Renderer.linearDecodeGamma : 0 }
    }
    /// Hand the compositor each pixel's real depth (engine, gun and body)
    /// for reprojection instead of one constant far depth. Live.
    var reprojectionDepth: Bool = AppSettingsStore.reprojectionDepth {
        didSet { AppSettingsStore.reprojectionDepth = reprojectionDepth
                 Renderer.reprojectionDepth = reprojectionDepth }
    }
    /// Modern lighting tier 1: Fresnel reflections on the glass the engine
    /// marks (r_vrglass, pushed with it). Live.
    var glassReflections: Bool = AppSettingsStore.glassReflections {
        didSet { AppSettingsStore.glassReflections = glassReflections
                 Renderer.glassReflections = glassReflections
                 cvar("r_vrglass", glassReflections ? 1 : 0) }
    }
    /// The same probe reflection on water, rippled (r_vrwater). Live.
    var waterReflections: Bool = AppSettingsStore.waterReflections {
        didSet { AppSettingsStore.waterReflections = waterReflections
                 Renderer.waterReflections = waterReflections
                 cvar("r_vrwater", waterReflections ? 1 : 0) }
    }
    /// Water reflections mirror the screen in horizontal water (SharpWater)
    /// on top of the probe. Live.
    var sharpWaterReflections: Bool = AppSettingsStore.sharpWaterReflections {
        didSet { AppSettingsStore.sharpWaterReflections = sharpWaterReflections
                 Renderer.sharpWaterReflections = sharpWaterReflections }
    }
    /// Water ripple strength, 0–3× (0 = a still mirror). Live.
    var waterRipples: Double = AppSettingsStore.waterRipples {
        didSet { AppSettingsStore.waterRipples = waterRipples
                 Renderer.waterRipples = Float(waterRipples) }
    }
    /// Glass and water reflectance scale, 0.5–4×. Live.
    var reflectionStrength: Double = AppSettingsStore.reflectionStrength {
        didSet { AppSettingsStore.reflectionStrength = reflectionStrength
                 Renderer.reflectionStrength = Float(reflectionStrength) }
    }
    /// HDR headroom test pattern over the whole view. Not stored: a
    /// diagnostic, and a black screen on the next launch would look broken.
    /// Sharp-water debug view (needs Water reflections on). Not stored.
    var waterMirrorView: WaterMirrorView = .off {
        didSet { Renderer.waterMirrorView = waterMirrorView.rawValue }
    }
    /// Sharp water: an object's underside in the mirror, as a share of its
    /// top's brightness (Renderer.waterUnderside); 0 = the probe. Not stored:
    /// a tuning knob for the debug API until a value is settled.
    var waterUnderside: Double = Double(Renderer.waterUnderside) {
        didSet { Renderer.waterUnderside = Float(waterUnderside) }
    }
    var hdrTest: HDRTestPattern = .off {
        didSet { Renderer.hdrTestMode = hdrTest.rawValue
                 AppLog.render.log("[HDR] test pattern \(hdrTest.label, privacy: .public), thermal state \(ProcessInfo.processInfo.thermalState.label, privacy: .public)") }
    }
    /// Per-pass GPU timestamps and the engine's GL timer queries
    /// (GPUPassTimer) for the Performance HUD. Not stored: a diagnostic with
    /// a small cost of its own (the HUD split can split the weapon encoder).
    var gpuPassTiming: Bool = false {
        didSet { GPUPassTimer.enabled = gpuPassTiming }
    }
    var gamma: Double = AppSettingsStore.gamma {
        didSet { AppSettingsStore.gamma = gamma; cvar("gamma", gamma) }
    }
    var brightness: Double = AppSettingsStore.brightness {
        didSet { AppSettingsStore.brightness = brightness; cvar("brightness", brightness) }
    }
    var snapTurnDegrees: Double = AppSettingsStore.snapTurnDegrees {
        didSet { AppSettingsStore.snapTurnDegrees = snapTurnDegrees
                 Renderer.snapTurnDegrees = Float(snapTurnDegrees) }
    }

    // MARK: Audio
    var sfxVolume: Double = AppSettingsStore.sfxVolume {
        didSet { AppSettingsStore.sfxVolume = sfxVolume; cvar("volume", sfxVolume) }
    }
    var musicVolume: Double = AppSettingsStore.musicVolume {
        didSet { AppSettingsStore.musicVolume = musicVolume; cvar("MP3Volume", musicVolume) }
    }

    // MARK: Input
    var dominantHand: DominantHand = AppSettingsStore.dominantHand {
        didSet { AppSettingsStore.dominantHand = dominantHand
                 Renderer.dominantHandIsLeft = (dominantHand == .left) }
    }
    var fireAimMode: FireAimMode = AppSettingsStore.fireAimMode {
        didSet { AppSettingsStore.fireAimMode = fireAimMode
                 Renderer.fireAlongGaze = (fireAimMode == .gaze)
                 cvar("crosshair", stockCrosshair) }
    }
    /// The engine's own crosshair marks the middle of the view, which is
    /// where shots go only when they follow the gaze; with barrel aim it is
    /// a mark stuck on the view that nothing lands on (the aim reticle does
    /// that job, and stands down in gaze mode).
    /// Outside hands mode shots follow the view, so it is the aim mark
    /// there too (the render thread re-pushes it when the mode changes).
    private var stockCrosshair: Int { fireAimMode == .gaze || InputModeState.current != .hands ? 1 : 0 }
    /// Flashlight mounted on the weapon hand (default) or the stock headlamp.
    var flashlightOnGun: Bool = AppSettingsStore.flashlightOnGun {
        didSet { AppSettingsStore.flashlightOnGun = flashlightOnGun
                 Renderer.flashlightOnGun = flashlightOnGun }
    }
    /// Immersive gesture input (pass 2). When on, curling the dominant hand's
    /// index finger fires (finger-gun) in place of gaze+pinch fire. Read
    /// live by the render thread via Renderer.gestureInputEnabled.
    var gestureInputEnabled: Bool = AppSettingsStore.gestureInputEnabled {
        didSet { AppSettingsStore.gestureInputEnabled = gestureInputEnabled
                 Renderer.gestureInputEnabled = gestureInputEnabled }
    }
    /// Arm-swing walking (H3VR's arm swinger): fists closed, pump the arms.
    /// Read live by the render thread via HandMovement's statics; only does
    /// anything while gesture input is on.
    var armSwingEnabled: Bool = AppSettingsStore.armSwingEnabled {
        didSet { AppSettingsStore.armSwingEnabled = armSwingEnabled
                 HandMovement.armSwingEnabled = armSwingEnabled }
    }
    var armSwingDirection: ArmSwingDirection = AppSettingsStore.armSwingDirection {
        didSet { AppSettingsStore.armSwingDirection = armSwingDirection
                 HandMovement.armSwingFollowsHands = (armSwingDirection == .hands) }
    }
    /// How little swinging it takes to walk and to reach full speed. Scales
    /// the effort only: full speed is stock run speed at every setting.
    var armSwingSensitivity: Double = AppSettingsStore.armSwingSensitivity {
        didSet { AppSettingsStore.armSwingSensitivity = armSwingSensitivity
                 HandMovement.armSwingSensitivity = Float(armSwingSensitivity) }
    }
    /// A jump gesture at a run, with the long jump module, presses duck
    /// first so the module fires (JumpSequencer). Off: always a crouch-jump.
    var handLongJump: Bool = AppSettingsStore.handLongJump {
        didSet { AppSettingsStore.handLongJump = handLongJump
                 HandMovement.longJumpEnabled = handLongJump }
    }
    /// The weapon wheel's flashlight, quick save and quick load sectors.
    var wheelUtilities: Bool = AppSettingsStore.wheelUtilities {
        didSet { AppSettingsStore.wheelUtilities = wheelUtilities
                 Renderer.weaponWheelUtilities = wheelUtilities }
    }
    /// Pushing the hand past the weapon wheel's rim opens a slot into its
    /// weapons (WeaponWheelGesture).
    var wheelExpand: Bool = AppSettingsStore.wheelExpand {
        didSet { AppSettingsStore.wheelExpand = wheelExpand
                 Renderer.weaponWheelExpand = wheelExpand }
    }
    /// Thumb tip to the side of the middle finger holds +attack2
    /// (ThumbGestures). Only does anything while gesture input is on.
    var altFireGesture: Bool = AppSettingsStore.altFireGesture {
        didSet { AppSettingsStore.altFireGesture = altFireGesture
                 Renderer.altFireGestureEnabled = altFireGesture }
    }
    /// Scales the alt-fire contact distances: higher presses from farther.
    var altFireSensitivity: Double = AppSettingsStore.altFireSensitivity {
        didSet { AppSettingsStore.altFireSensitivity = altFireSensitivity
                 Renderer.altFireSensitivity = Float(altFireSensitivity) }
    }
    var fastWeaponSwitch: Bool = AppSettingsStore.fastWeaponSwitch {
        didSet { AppSettingsStore.fastWeaponSwitch = fastWeaponSwitch
                 cvar("hud_fastswitch", fastWeaponSwitch ? 1 : 0) }
    }
    /// Draw the weapon model in the app's Metal pass (hand-anchored, world-lit)
    /// instead of the engine. On = the `vr_weapon_external` path.
    var weaponExternal: Bool = AppSettingsStore.weaponExternal {
        didSet { AppSettingsStore.weaponExternal = weaponExternal
                 cvar("vr_weapon_external", weaponExternal ? 1 : 0) }
    }
    /// Draw the first-person body (the player model posed from head and hand
    /// tracking, see AvatarRig). Off leaves the wireframe hands alone.
    var avatarBody: Bool = AppSettingsStore.avatarBody {
        didSet { AppSettingsStore.avatarBody = avatarBody
                 Renderer.avatarBodyEnabled = avatarBody }
    }
    /// Give the body legs that stand on the game's floor and step as the
    /// player moves (AvatarGait). Off cuts the body at the hips.
    var avatarLegs: Bool = AppSettingsStore.avatarLegs {
        didSet { AppSettingsStore.avatarLegs = avatarLegs
                 Renderer.avatarLegsVisible = avatarLegs }
    }

    /// The HEV suit's holographic readouts (HEVHUD): ammo beside the weapon,
    /// health and suit charge over the off-hand forearm. Off brings the stock
    /// 2D readouts back.
    var hevHUD: Bool = AppSettingsStore.hevHUD {
        didSet { AppSettingsStore.hevHUD = hevHUD
                 applyHEVHUD() }
    }

    /// The holographic aim point where the barrel's shot would land (and,
    /// with the beam, the line to it from the muzzle).
    var aimReticle: AimReticle = AppSettingsStore.aimReticle {
        didSet { AppSettingsStore.aimReticle = aimReticle
                 Renderer.aimReticle = aimReticle.style }
    }

    /// Outside hands mode: the HEV readouts in the lower corners of the view,
    /// trailing the head a little, or left on the hands as in hands mode.
    var flatHUDPlacement: FlatHUDPlacement = AppSettingsStore.flatHUDPlacement {
        didSet { AppSettingsStore.flatHUDPlacement = flatHUDPlacement
                 Renderer.flatHUDFollowsView = (flatHUDPlacement == .followView) }
    }

    /// Developer mode: the palm debug panel (frame time and render toggles
    /// over the off-hand palm while it faces you) and the engine's verbose
    /// developer message stream (`developer 2`, off otherwise).
    var developerMode: Bool = AppSettingsStore.developerMode {
        didSet { AppSettingsStore.developerMode = developerMode
                 Renderer.debugPanelEnabled = developerMode
                 cvar("developer", developerMode ? 2 : 0) }
    }

    /// Settings › Advanced › Debug server (LambdaDebugServer in
    /// DebugEndpoints): starts or stops the debug API at once.
    var debugServer: DebugServerMode = AppSettingsStore.debugServer {
        didSet { AppSettingsStore.debugServer = debugServer
                 LambdaDebugServer.apply(debugServer) }
    }

    /// Hold the weapon's viewmodel or its world model (WeaponPass).
    var weaponModel: WeaponModelStyle = AppSettingsStore.weaponModel {
        didSet { AppSettingsStore.weaponModel = weaponModel
                 Renderer.weaponWorldModel = (weaponModel == .world) }
    }

    // MARK: Keyboard, mouse and gamepad
    /// Hands / keyboard+mouse / gamepad, or Auto from the last device used
    /// (InputModeState).
    var inputMode: InputModeSetting = AppSettingsStore.inputMode {
        didSet { AppSettingsStore.inputMode = inputMode
                 InputModeState.setting = inputMode }
    }
    /// Half-Life's mouse `sensitivity` scale (degrees per count = × 0.022).
    var mouseSensitivity: Double = AppSettingsStore.mouseSensitivity {
        didSet { AppSettingsStore.mouseSensitivity = mouseSensitivity
                 MouseInput.sensitivity = Float(mouseSensitivity) }
    }
    /// Right stick turns smoothly; off = snap turn by the snap-turn angle.
    var stickSmoothTurn: Bool = AppSettingsStore.stickSmoothTurn {
        didSet { AppSettingsStore.stickSmoothTurn = stickSmoothTurn
                 GamepadInput.smoothTurn = stickSmoothTurn }
    }
    /// Smooth-turn rate at full stick, degrees per second.
    var stickTurnSpeed: Double = AppSettingsStore.stickTurnSpeed {
        didSet { AppSettingsStore.stickTurnSpeed = stickTurnSpeed
                 GamepadInput.turnSpeed = Float(stickTurnSpeed) }
    }
    /// Mouse and right-stick Y look up and down (outside hands mode).
    var lookPitch: Bool = AppSettingsStore.lookPitch {
        didSet { AppSettingsStore.lookPitch = lookPitch
                 Renderer.lookPitchEnabled = lookPitch }
    }
    /// Hide the viewmodel parts Valve parks out of the flat view's shot
    /// (spare magazines, shells) while they are out of it (WeaponPass).
    var hideParkedParts: Bool = AppSettingsStore.hideParkedParts {
        didSet { AppSettingsStore.hideParkedParts = hideParkedParts
                 Renderer.hideParkedParts = hideParkedParts }
    }

    init() {
        applyRendererStatics()
    }

    /// Push the render-thread knobs. Safe to call any time (plain static
    /// assignment); run at init so the first drawable setup / hand sample
    /// already reflects stored values.
    func applyRendererStatics() {
        Renderer.engineScale       = Float(renderScale)
        Renderer.useMetalFXChain   = metalFXEnabled
        Renderer.compositeFXAA     = fxaaEnabled
        Renderer.displayDecodeGamma = linearColor ? Renderer.linearDecodeGamma : 0
        Renderer.reprojectionDepth = reprojectionDepth
        Renderer.glassReflections = glassReflections
        Renderer.waterReflections = waterReflections
        Renderer.reflectionStrength = Float(reflectionStrength)
        Renderer.sharpWaterReflections = sharpWaterReflections
        Renderer.waterRipples = Float(waterRipples)
        Renderer.snapTurnDegrees   = Float(snapTurnDegrees)
        Renderer.dominantHandIsLeft = (dominantHand == .left)
        Renderer.fireAlongGaze     = (fireAimMode == .gaze)
        Renderer.flashlightOnGun   = flashlightOnGun
        Renderer.gestureInputEnabled = gestureInputEnabled
        HandMovement.armSwingEnabled = armSwingEnabled
        HandMovement.armSwingFollowsHands = (armSwingDirection == .hands)
        HandMovement.armSwingSensitivity = Float(armSwingSensitivity)
        HandMovement.longJumpEnabled = handLongJump
        Renderer.weaponWheelUtilities = wheelUtilities
        Renderer.weaponWheelExpand = wheelExpand
        Renderer.altFireGestureEnabled = altFireGesture
        Renderer.altFireSensitivity = Float(altFireSensitivity)
        Renderer.avatarBodyEnabled = avatarBody
        Renderer.avatarLegsVisible = avatarLegs
        Renderer.aimReticle = aimReticle.style
        Renderer.flatHUDFollowsView = (flatHUDPlacement == .followView)
        Renderer.weaponWorldModel = (weaponModel == .world)
        Renderer.hideParkedParts = hideParkedParts
        Renderer.debugPanelEnabled = developerMode
        InputModeState.setting = inputMode
        MouseInput.sensitivity = Float(mouseSensitivity)
        GamepadInput.smoothTurn = stickSmoothTurn
        GamepadInput.turnSpeed = Float(stickTurnSpeed)
        Renderer.lookPitchEnabled = lookPitch
        applyHEVHUD()
    }

    /// A pinch on one of the palm debug panel's buttons (main actor, from
    /// the layer's spatial events). Goes through the settings so the choice
    /// persists and the Settings window agrees.
    func performDebugPanelControl(_ control: PalmDebugPanel.Control) {
        switch control {
        case .hevHUD: hevHUD.toggle()
        case .reticle:
            let all = AimReticle.allCases
            aimReticle = all[(all.firstIndex(of: aimReticle).map { $0 + 1 } ?? 0) % all.count]
        case .body: avatarBody.toggle()
        }
    }

    /// A plain flag in the client and a render static, so it is safe before
    /// the engine is up.
    private func applyHEVHUD() {
        Renderer.hevHUDEnabled = hevHUD
        lambda_hud_set_native(hevHUD ? 1 : 0)
    }

    /// Called from Renderer.ensureEngineInitialized() once the engine is up.
    /// Enables live cvar pushes and asserts every archived cvar value (we
    /// don't rely on config.cfg being written).
    func engineDidStart() {
        isEngineReady = true
        cvar("gamma", gamma)
        cvar("brightness", brightness)
        cvar("volume", sfxVolume)
        cvar("MP3Volume", musicVolume)
        cvar("hud_fastswitch", fastWeaponSwitch ? 1 : 0)
        cvar("vr_weapon_external", weaponExternal ? 1 : 0)
        cvar("crosshair", stockCrosshair)
        cvar("r_vrglass", glassReflections ? 1 : 0)
        cvar("r_vrwater", waterReflections ? 1 : 0)
    }

    /// Run an arbitrary console command (Advanced tab: the Xash menu portal,
    /// the console field, map/restart). No-op until the engine is up so the
    /// UI can't deadlock the worker post.
    func command(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEngineReady, !cmd.isEmpty else { return }
        send(cmd)
    }

    // MARK: cvar dispatch
    private func cvar(_ name: String, _ value: Double) {
        guard isEngineReady else { return }
        send("\(name) \(String(format: "%.3f", value))")
    }
    private func cvar(_ name: String, _ value: Int) {
        guard isEngineReady else { return }
        send("\(name) \(value)")
    }
    private func send(_ command: String) {
        _ = command.withCString { lambda_gl_worker_cmd($0) }
    }
}

/// Settings → Diagnostics: the HDR headroom test (Shaders.metal hdrTestPattern).
/// Settings → Diagnostics: what the sharp-water mirror holds
/// (Renderer.waterMirrorView, Shaders.metal glassShade). Not stored.
enum WaterMirrorView: Int, CaseIterable, Identifiable {
    case off = 0, onWater = 1, confidence = 2, whole = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .onWater: "Mirror on water"
        case .confidence: "Mirror confidence"
        case .whole: "Whole mirror"
        }
    }
}

enum HDRTestPattern: Int, CaseIterable, Identifiable {
    case off = 0, dots = 1, patches = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .dots: "Small dots"
        case .patches: "Large patches"
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
