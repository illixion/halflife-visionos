//
//  LambdaVisionApp.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

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
                    print("[LambdaVision] audio session reclaimed — restarting queue")
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
                print("[LambdaVision] crash log path: \(path)")
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
                print("[LambdaVision] AVAudioSession activation failed: \(error)")
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
                        print("[LambdaVision] audio interruption began — pausing queue")
                        Task { @MainActor in AudioSessionRecovery.interruptionBegan() }
                    case .ended:
                        print("[LambdaVision] audio interruption ended — restarting queue")
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
                    print("[LambdaVision] media services reset — restarting audio")
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
                for event in events {
                    switch event.phase {
                    case .active:
                        // Stage the gaze ray BEFORE +attack so the shot
                        // aims where the eyes point (renderFrame converts
                        // it to an aim offset for the weapon code).
                        if let ray = event.selectionRay {
                            Renderer.setGazeRay(direction: SIMD3<Float>(
                                Float(ray.direction.x),
                                Float(ray.direction.y),
                                Float(ray.direction.z)))
                        }
                        if PinchFire.active.insert(event.id).inserted,
                           PinchFire.active.count == 1 {
                            _ = "+attack".withCString { lambda_gl_worker_cmd($0) }
                        }
                    case .ended, .cancelled:
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

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}