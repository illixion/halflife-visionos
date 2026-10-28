//
//  TroubleshootingSettingsPage.swift
//  LambdaVision
//
//  Settings › Troubleshooting: switches for things that depend on the
//  system around the game and may need to change when the picture looks
//  wrong. It holds a second copy of the progressive-immersion switch (the
//  first is on the Immersion page) so a player looking for a fix finds it
//  here.
//

import SwiftUI

/// The progressive-immersion switch, shown on Immersion and Troubleshooting.
struct ProgressiveImmersionToggle: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        Toggle("Progressive immersion", isOn: $settings.progressiveImmersion)
    }
}

struct TroubleshootingSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SettingsPage("Troubleshooting", preview: "progressiveImmersion") {
            Section {
                ProgressiveImmersionToggle()
                    .previews("progressiveImmersion", value: appModel.gameSettings.progressiveImmersion)
            } header: {
                Text("The game is a portal that stays one size, shows black or is missing")
            } footer: {
                Text("While Mac Virtual Display is connected the portal can misbehave. Disconnect Mac Virtual Display, then reload the game, or turn this off to fill your whole view instead.")
            }
        }
    }
}
