//
//  DeveloperSettingsPage.swift
//  LambdaVision
//
//  Settings › Developer: developer mode, the debug server, and the
//  diagnostics — the water-mirror and HDR test views, the Console and
//  Performance windows, and GPU pass timing. The diagnostic pickers and
//  GPU pass timing aren't stored (GameSettings), so they reset on launch.
//

import SwiftUI

struct DeveloperSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Developer") {
            Section {
                Toggle("Developer mode", isOn: $settings.developerMode)

                // The debug API for a Mac (DebugEndpoints). Development
                // builds only; App Store builds never serve it.
                if LambdaDebugServer.available {
                    Picker("Debug server", selection: $settings.debugServer) {
                        ForEach(DebugServerMode.allCases) { Text($0.label).tag($0) }
                    }
                }
            } footer: {
                Text("“Developer mode” shows a debug panel over your off-hand palm when you turn it to face you: frame time and a few render toggles to look at and pinch with your other hand. It stays away while that hand is driving the movement joystick. It also turns on the engine’s verbose developer messages in the log; with it off they stay quiet."
                     + (LambdaDebugServer.available
                        ? " “Debug server” serves screenshots, game state and console commands to a Mac on your network (scripts/avp-screenshot.sh, the apps MCP). Automatic serves in builds signed by build-and-sign; On also serves an Xcode run; Off serves only when a launch asks for it explicitly."
                        : ""))
            }

            Section("Diagnostics") {
                Picker("Water mirror view", selection: $settings.waterMirrorView) {
                    ForEach(WaterMirrorView.allCases) { Text($0.label).tag($0) }
                }
                Picker("HDR headroom test", selection: $settings.hdrTest) {
                    ForEach(HDRTestPattern.allCases) { Text($0.label).tag($0) }
                }
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text("Thermal state: \(ProcessInfo.processInfo.thermalState.label). Replaces the view with test values over black, each above a 1.0 reference, left to right 0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4. Note the rightmost that is still brighter than the one before it, in both layouts, and the thermal state when you did.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    openWindow(id: "console")
                } label: {
                    Label("Open Console", systemImage: "apple.terminal")
                }
                Text("Live view of this app's log output, readable on the headset without a cable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    openWindow(id: "performance")
                } label: {
                    Label("Open Performance HUD", systemImage: "speedometer")
                }
                Text("Live FPS, frame-time graph, and per-stage breakdown — keep it open in view while playing.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Toggle("GPU pass timing", isOn: $settings.gpuPassTiming)
                Text("Adds the GPU's own time per pass to the Performance HUD: the engine's two eyes, the composite, the arms, the gun and body, the HUD holograms and the reprojection depth, against the 8.3 ms a frame has at 120 Hz. Costs a little itself; leave it off when not measuring.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
