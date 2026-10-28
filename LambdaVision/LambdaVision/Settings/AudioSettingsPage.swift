//
//  AudioSettingsPage.swift
//  LambdaVision
//
//  Settings › Audio: the engine's two volume cvars.
//

import SwiftUI

struct AudioSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Audio", preview: "sfxVolume") {
            Section {
                SettingsSlider("Sound effects", $settings.sfxVolume, 0...1, 0.05, format: SettingsSlider.percent)
                    .previews("sfxVolume", value: settings.sfxVolume)
                SettingsSlider("Music (MP3)", $settings.musicVolume, 0...1, 0.05, format: SettingsSlider.percent)
                    .previews("musicVolume", value: settings.musicVolume)
            }
        }
    }
}
