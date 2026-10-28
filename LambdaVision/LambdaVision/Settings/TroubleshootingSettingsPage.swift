//
//  TroubleshootingSettingsPage.swift
//  LambdaVision
//
//  Settings › Troubleshooting: switches for things that depend on the
//  system around the game and may need to change when the picture looks
//  wrong. It holds a second copy of the progressive-immersion switch (the
//  first is in Graphics) so a player looking for a fix finds it here.
//

import SwiftUI

/// The progressive-immersion switch, shown in Graphics and Troubleshooting.
struct ProgressiveImmersionToggle: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        Toggle("Progressive immersion", isOn: $settings.progressiveImmersion)
    }
}

struct TroubleshootingSettingsPage: View {
    var body: some View {
        SettingsPage("Troubleshooting") {
            Section {
                ProgressiveImmersionToggle()
            } header: {
                Text("Immersion")
            } footer: {
                Text("On, the game is a portal you widen or narrow with the Digital Crown, with your room showing around it. While Mac Virtual Display is connected the portal can stay one size, show black or go missing. Disconnect Mac Virtual Display, then reload the game, or turn this off to fill your whole view instead. It applies when the immersive space restarts.")
            }
        }
    }
}
