//
//  LambdaVisionApp.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import ARKit
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
            KeyboardInput.shared.start()
            Renderer.startRenderLoop(layerRenderer, appModel: appModel, arSession: ARKitSession())
        }
    }
}

extension ImmersiveSpaceContent: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)

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