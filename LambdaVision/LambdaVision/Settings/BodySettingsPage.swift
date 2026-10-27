//
//  BodySettingsPage.swift
//  LambdaVision
//
//  Settings › Body & Weapon: what the player sees of themselves — the
//  weapon in the hand, Gordon's body, and the HEV holograms and reticle
//  that replace the flat HUD. Where the holograms go with a keyboard, mouse
//  or gamepad is on the Keyboard, Mouse & Gamepad page, beside that mode's
//  other options.
//

import SwiftUI

struct BodySettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Body & Weapon") {
            Section {
                Toggle("Hand-tracked weapon model", isOn: $settings.weaponExternal)
                Picker("Weapon model", selection: $settings.weaponModel) {
                    ForEach(WeaponModelStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.weaponExternal)
                Toggle("Hide parked weapon parts", isOn: $settings.hideParkedParts)
                    .disabled(!settings.weaponExternal)
                Toggle("Gun-mounted flashlight", isOn: $settings.flashlightOnGun)
                Toggle("Fast weapon switch", isOn: $settings.fastWeaponSwitch)
            } header: {
                Text("Weapon")
            } footer: {
                Text("“Hand-tracked weapon model” draws the weapon in your hand, tracking it directly (world-lit); off falls back to the classic engine-drawn weapon. “Weapon model” picks which of the game’s two models of each weapon you hold: the viewmodel is animated but was only ever modelled on the side the old flat camera saw, so turning it over shows it open; the world model (the one other players see) is whole from every side but has no animation, so a reload shows only as the ring above the weapon filling. The Gluon Gun has no world model you can hold and keeps its viewmodel. “Hide parked weapon parts” hides what the old flat view kept just out of frame until an animation needed it — the pistol’s spare magazine, the shotgun’s shell — so it doesn’t float beside the gun in your hand.")
            }

            Section {
                Toggle("First-person body", isOn: $settings.avatarBody)
                Toggle("Legs", isOn: $settings.avatarLegs)
                    .disabled(!settings.avatarBody)
            } header: {
                Text("Body")
            } footer: {
                Text("“First-person body” draws Gordon under your head, following your hands and holding the weapon; “Legs” stands him on the game’s floor, stepping as you walk, turn or move with the stick.")
            }

            Section {
                Toggle("HEV suit holograms", isOn: $settings.hevHUD)
                Picker("Aim reticle", selection: $settings.aimReticle) {
                    ForEach(AimReticle.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("HUD")
            } footer: {
                Text("“HEV suit holograms” replaces the flat HUD: ammo floats beside the weapon, and health and suit charge appear over your other forearm when you turn it toward you. “Aim reticle” marks where the gun’s shot would land; “Dot and beam” adds a faint line from the muzzle.")
            }
        }
    }
}
