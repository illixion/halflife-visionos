//
//  LambdaVisionApp.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import RAVEConsole
import ARKit
import AVFAudio
import CompositorServices
import GameController
import SwiftUI

// Audio-session interruption recovery. visionOS interrupts the session on
// events as mundane as closing the app's 2D window, and the matching
// `.ended` notification is NOT guaranteed to arrive (observed: repeated
// `began` with no `ended` → permanent silence). So on interruption, poll:
// try to reclaim the session every second and restart the AudioQueue as
// soon as the system permits.
@MainActor
enum AudioSessionRecovery {
    private static var retry: Task<Void, Never>?

    static func interruptionBegan() {
        lambda_snd_activate(0)
        retry?.cancel()
        retry = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if (try? AVAudioSession.sharedInstance().setActive(true)) != nil {
                    AppLog.app.line("[LambdaVision] audio session reclaimed — restarting queue")
                    lambda_snd_activate(1)
                    return
                }
            }
        }
    }

    static func interruptionEnded() {
        retry?.cancel()
        retry = nil
        try? AVAudioSession.sharedInstance().setActive(true)
        lambda_snd_activate(1)
    }
}

// Held-pinch state for the fire trigger (IDs of in-flight pinches).
// Spatial events arrive serially, so a plain Set is fine.
private enum PinchFire {
    static var active = Set<SpatialEventCollection.Event.ID>()
}

// IDs of menu pinches that have already registered their single click. The
// .active phase repeats every frame while the pinch is held, so without this
// a held pinch would rapid-fire menu selections (one per frame).
private enum MenuPinch {
    static var clicked = Set<SpatialEventCollection.Event.ID>()
}

struct ImmersiveSpaceContent: CompositorContent {

    var appModel: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: self) { @MainActor layerRenderer in
            // Crash dump goes here; pull via `xcrun devicectl ... pull` or
            // the Files app. Overwritten on each crash.
            if let docs = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true) {
                let path = docs.appendingPathComponent("crash.log").path
                path.withCString { lambda_set_crash_log_path($0) }
                AppLog.app.line("[LambdaVision] crash log path: \(path)")
            }
            // The engine's AudioQueue backend (snd_visionos.c) plays into
            // the app's audio session; without an explicitly activated
            // .playback session the system can leave the queue's I/O
            // thread suspended (observed on device: the first render
            // callback never completes).
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.mixWithOthers])
                // Bypass the system's spatializer. By default visionOS
                // spatializes the app's audio and anchors it to the app's
                // first window — sitting ON TOP of the mixes we already
                // produce. That double layer is what made PHASE's own
                // binaural output deafening while the window was open and
                // silent when it was closed (no window = no anchor), and it
                // window-pinned the AudioQueue bed. Bypassed = our stereo/
                // binaural output plays through unmodified; PHASE does the
                // spatialization, the bed stays head-locked.
                try session.setIntendedSpatialExperience(.bypassed)
                try session.setActive(true)
            } catch {
                AppLog.app.line("[LambdaVision] AVAudioSession activation failed: \(error)")
            }
            // System interruptions (Siri, alerts, route changes) stop the
            // AudioQueue and nothing restarts it — the game goes silent
            // until the user hides/shows the immersive space. Drive the
            // same pause/resume machinery from the session notifications.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main) { note in
                    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    switch type {
                    case .began:
                        AppLog.app.line("[LambdaVision] audio interruption began — pausing queue")
                        Task { @MainActor in AudioSessionRecovery.interruptionBegan() }
                    case .ended:
                        AppLog.app.line("[LambdaVision] audio interruption ended — restarting queue")
                        Task { @MainActor in AudioSessionRecovery.interruptionEnded() }
                    @unknown default:
                        break
                    }
                }
            // Media services daemon crash/reset: the session and queue are
            // both orphaned — reactivate and restart.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil, queue: .main) { _ in
                    AppLog.app.line("[LambdaVision] media services reset — restarting audio")
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.playback, options: [.mixWithOthers])
                    try? session.setActive(true)
                    lambda_snd_activate(0)
                    lambda_snd_activate(1)
                }
            // Gaze + pinch = trigger. CompositorServices delivers indirect
            // pinch events straight to the layer in a full immersive space.
            // A held pinch holds +attack (HL's automatic weapons fire while
            // the trigger is down); release/cancel lets go.
            layerRenderer.onSpatialEvent = { events in
                // When the stock Half-Life menu is up it owns gaze+pinch: a
                // pinch clicks the item the eyes are on (like a visionOS
                // window), and must NOT fire the weapon.
                let menuActive = lambda_menu_active() != 0
                for event in events {
                    switch event.phase {
                    case .active:
                        let dir = event.selectionRay.map {
                            SIMD3<Float>(Float($0.direction.x),
                                         Float($0.direction.y),
                                         Float($0.direction.z))
                        }
                        if menuActive {
                            // Keep the cursor under the gaze while held (for
                            // highlight), but click only ONCE per pinch —
                            // .active repeats each frame.
                            if let d = dir, let (mx, my) = Renderer.menuCursorFromGaze(d) {
                                lambda_menu_set_cursor(Int32(mx), Int32(my))
                                if MenuPinch.clicked.insert(event.id).inserted {
                                    lambda_menu_click()
                                }
                            }
                            continue
                        }
                        // When immersive gesture input is on, the render-thread
                        // gestures own both hands (dominant index-curl fires,
                        // off-hand pinch drives the joystick), so the pinch must
                        // NOT also fire. Gate the press only — a release still
                        // clears below, so toggling mid-pinch can't stick fire.
                        if Renderer.gestureInputEnabled { continue }
                        // Stage the gaze ray BEFORE +attack so the shot
                        // aims where the eyes point (renderFrame converts
                        // it to an aim offset for the weapon code).
                        if let d = dir { Renderer.setGazeRay(direction: d) }
                        if PinchFire.active.insert(event.id).inserted,
                           PinchFire.active.count == 1 {
                            _ = "+attack".withCString { lambda_gl_worker_cmd($0) }
                        }
                    case .ended, .cancelled:
                        if menuActive { MenuPinch.clicked.remove(event.id); continue }
                        if PinchFire.active.remove(event.id) != nil,
                           PinchFire.active.isEmpty {
                            _ = "-attack".withCString { lambda_gl_worker_cmd($0) }
                            Renderer.setGazeRay(direction: nil)
                        }
                    @unknown default:
                        break
                    }
                }
            }
            KeyboardInput.shared.start()
            Renderer.startRenderLoop(layerRenderer, appModel: appModel, arSession: ARKitSession())
        }
    }
}

extension ImmersiveSpaceContent: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // Foveation on: the compositor samples our drawable at panel density
        // in the fovea, which is what lets the flat engine render reach
        // native-looking sharpness where the user looks. The display pass
        // binds drawable.rasterizationRateMaps.first and samples the colorMap
        // through interpolated varyings — with a rate map bound, varyings
        // interpolate in logical (screen) space, so each physical fragment
        // fetches the correct colorMap texel and the compositor's unwarp
        // reconstructs a straight image. (The V-shape artifact seen earlier
        // came from foveated presentation WITHOUT the rate map bound at
        // render time.)
        configuration.isFoveationEnabled = capabilities.supportsFoveation

        let supportedLayouts = capabilities.supportedLayouts(options: [])
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated

        configuration.supportsMTL4 = true
    }
}

@main
struct LambdaVisionApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        // Single-instance launcher/settings window — we only ever want one
        // copy of the start menu.
        Window("Lambda VisionPro", id: "main") {
            ContentView()
                .environment(appModel)
                // Route gamepad input to the app instead of system focus
                // navigation — without this, polled GCController values
                // freeze after a stick release (a known GCController quirk).
                .handlesGameControllerEvents(matching: .gamepad)
        }

        // In-app log viewer. This app renders through CompositorServices and
        // has no tab bar, so the console is its own window.
        Window("Console", id: "console") {
            RAVEConsoleScreen()
        }
        .defaultLaunchBehavior(.suppressed)

        // Live FPS/frame-time HUD, same window-based approach as Console —
        // stays visible over the immersive space since it's never dismissed.
        Window("Performance", id: "performance") {
            PerformanceHUDScreen()
        }
        .defaultLaunchBehavior(.suppressed)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}