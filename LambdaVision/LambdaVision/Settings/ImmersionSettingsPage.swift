//
//  ImmersionSettingsPage.swift
//  LambdaVision
//
//  Settings › Immersion: how the game fills your view and what you see of
//  yourself in it: the portal or the full view, the weapon in your hand,
//  Gordon's body, and the HEV holograms and reticle that replace the flat
//  HUD. Where the holograms go with a keyboard, mouse or gamepad is on the
//  Keyboard, Mouse & Gamepad page, beside that mode's other options.
//

import SwiftUI

struct ImmersionSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Immersion", preview: "progressiveImmersion") {
            Section("View") {
                ProgressiveImmersionToggle()
                    .previews("progressiveImmersion", value: settings.progressiveImmersion)
            }

            Section("Weapon") {
                Toggle("Hand-tracked weapon model", isOn: $settings.weaponExternal)
                    .previews("weaponExternal", value: settings.weaponExternal)
                Picker("Weapon model", selection: $settings.weaponModel) {
                    ForEach(WeaponModelStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.weaponExternal)
                .previews("weaponModel", value: settings.weaponModel)
                Toggle("Hide parked weapon parts", isOn: $settings.hideParkedParts)
                    .disabled(!settings.weaponExternal)
                    .previews("hideParkedParts", value: settings.hideParkedParts)
                Toggle("Gun-mounted flashlight", isOn: $settings.flashlightOnGun)
                    .previews("flashlightOnGun", value: settings.flashlightOnGun)
                Toggle("Fast weapon switch", isOn: $settings.fastWeaponSwitch)
                    .previews("fastWeaponSwitch", value: settings.fastWeaponSwitch)
            }

            Section("Body") {
                Toggle("First-person body", isOn: $settings.avatarBody)
                    .previews("avatarBody", value: settings.avatarBody)
                Toggle("Legs", isOn: $settings.avatarLegs)
                    .disabled(!settings.avatarBody)
                    .previews("avatarLegs", value: settings.avatarLegs)
            }

            Section("HUD") {
                Toggle("HEV suit holograms", isOn: $settings.hevHUD)
                    .previews("hevHUD", value: settings.hevHUD)
                Picker("Aim reticle", selection: $settings.aimReticle) {
                    ForEach(AimReticle.allCases) { Text($0.label).tag($0) }
                }
                .previews("aimReticle", value: settings.aimReticle)
            }
        }
    }
}
