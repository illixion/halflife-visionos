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
                 Renderer.fireAlongGaze = (fireAimMode == .gaze) }
    }
    /// Immersive gesture input (pass 2). When on, curling the dominant hand's
    /// index finger fires (finger-gun); pinch fire stays as a fallback. Read
    /// live by the render thread via Renderer.gestureInputEnabled.
    var gestureInputEnabled: Bool = AppSettingsStore.gestureInputEnabled {
        didSet { AppSettingsStore.gestureInputEnabled = gestureInputEnabled
                 Renderer.gestureInputEnabled = gestureInputEnabled }
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
        Renderer.snapTurnDegrees   = Float(snapTurnDegrees)
        Renderer.dominantHandIsLeft = (dominantHand == .left)
        Renderer.fireAlongGaze     = (fireAimMode == .gaze)
        Renderer.gestureInputEnabled = gestureInputEnabled
        Renderer.avatarBodyEnabled = avatarBody
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
