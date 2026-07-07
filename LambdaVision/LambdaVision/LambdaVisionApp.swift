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
        WindowGroup {
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