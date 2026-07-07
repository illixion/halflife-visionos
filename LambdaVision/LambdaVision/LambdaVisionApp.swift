//
//  LambdaVisionApp.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import ARKit
import AVFAudio
import CompositorServices
import SwiftUI

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
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}