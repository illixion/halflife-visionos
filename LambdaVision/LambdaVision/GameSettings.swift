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
//      setup already sees the stored values.
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
    /// Render scale above this leaves nothing for MetalFX to upscale, so the
    /// toggle is disabled/forced-off above it (SettingsView greys it out).
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
    var metalFXEnabled: Bool = AppSettingsStore.metalFXEnabled {
        didSet { AppSettingsStore.metalFXEnabled = metalFXEnabled
                 Renderer.useMetalFXChain = metalFXEnabled }
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
    /// Gate for the upcoming finger-gun / gesture input model (pass 2). Stored
    /// now so the preference persists; not yet consumed at runtime.
    var gestureInputEnabled: Bool = AppSettingsStore.gestureInputEnabled {
        didSet { AppSettingsStore.gestureInputEnabled = gestureInputEnabled }
    }
    var fastWeaponSwitch: Bool = AppSettingsStore.fastWeaponSwitch {
        didSet { AppSettingsStore.fastWeaponSwitch = fastWeaponSwitch
                 cvar("hud_fastswitch", fastWeaponSwitch ? 1 : 0) }
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
        Renderer.snapTurnDegrees   = Float(snapTurnDegrees)
        Renderer.dominantHandIsLeft = (dominantHand == .left)
        Renderer.fireAlongGaze     = (fireAimMode == .gaze)
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
