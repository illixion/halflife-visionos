//
//  InputSettingsPages.swift
//  LambdaVision
//
//  Settings › Hands (hand tracking: the finger gun, movement gestures and
//  the weapon wheel) and Settings › Keyboard, Mouse & Gamepad (the desktop
//  devices, free aim and the mouse-capture window). Which of the two drives
//  the game at a given moment is the Input mode picker on the second page
//  (InputMode.swift). What each control does is said in the preview column
//  (SettingHelp), so the footers here are short.
//

import SwiftUI

struct HandSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Hands", preview: "gestureInputEnabled") {
            Section {
                Picker("Dominant hand", selection: $settings.dominantHand) {
                    ForEach(DominantHand.allCases) { Text($0.label).tag($0) }
                }
                .previews("dominantHand", value: settings.dominantHand)
                Picker("Fire aims at", selection: $settings.fireAimMode) {
                    ForEach(FireAimMode.allCases) { Text($0.label).tag($0) }
                }
                .previews("fireAimMode", value: settings.fireAimMode)
            }

            Section {
                Toggle("Immersive gesture input", isOn: $settings.gestureInputEnabled)
                    .previews("gestureInputEnabled", value: settings.gestureInputEnabled)
                Toggle("Alt-fire: thumb to middle finger", isOn: $settings.altFireGesture)
                    .disabled(!settings.gestureInputEnabled)
                    .previews("altFireGesture", value: settings.altFireGesture)
                SettingsSlider("Alt-fire sensitivity", $settings.altFireSensitivity, 0.5...2, 0.1) {
                    String(format: "%.1f×", $0)
                }
                .disabled(!settings.gestureInputEnabled || !settings.altFireGesture)
                .previews("altFireSensitivity", value: settings.altFireSensitivity)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Fire with a finger gun, reload with your thumb, press buttons by poking them.")
            }

            Section {
                Toggle("Arm-swing walking", isOn: $settings.armSwingEnabled)
                    .disabled(!settings.gestureInputEnabled)
                    .previews("armSwingEnabled", value: settings.armSwingEnabled)
                Picker("Swing direction", selection: $settings.armSwingDirection) {
                    ForEach(ArmSwingDirection.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.gestureInputEnabled || !settings.armSwingEnabled)
                .previews("armSwingDirection", value: settings.armSwingDirection)
                SettingsSlider("Swing sensitivity", $settings.armSwingSensitivity, 0.5...2, 0.1) {
                    String(format: "%.1f×", $0)
                }
                .disabled(!settings.gestureInputEnabled || !settings.armSwingEnabled)
                .previews("armSwingSensitivity", value: settings.armSwingSensitivity)
                Toggle("Long jump at a run", isOn: $settings.handLongJump)
                    .disabled(!settings.gestureInputEnabled)
                    .previews("handLongJump", value: settings.handLongJump)
            } header: {
                Text("Movement")
            } footer: {
                Text("Move with the other hand: pinch thumb and index and drag like a joystick; raise or drop the pinched hand to jump or crouch.")
            }

            Section {
                Toggle("Wheel: flashlight, quick save/load", isOn: $settings.wheelUtilities)
                    .previews("wheelUtilities", value: settings.wheelUtilities)
                Toggle("Wheel: reach past the rim to pick a weapon", isOn: $settings.wheelExpand)
                    .disabled(!settings.gestureInputEnabled)
                    .previews("wheelExpand", value: settings.wheelExpand)
            } header: {
                Text("Weapon wheel")
            } footer: {
                Text("Pinch all fingertips together, move your hand toward a sector, release to pick.")
            }
        }
    }
}

struct KeyboardMouseSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Keyboard, Mouse & Gamepad", preview: "inputMode") {
            Section {
                Picker("Input mode", selection: $settings.inputMode) {
                    ForEach(InputModeSetting.allCases) { Text($0.label).tag($0) }
                }
                .previews("inputMode", value: settings.inputMode)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Now: \(InputModeState.current.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Auto follows the last thing you used.")
            }

            Section {
                SettingsSlider("Mouse sensitivity", $settings.mouseSensitivity, 0.5...10, 0.5) {
                    String(format: "%.1f", $0)
                }
                Toggle("Mouse smoothing", isOn: $settings.mouseSmoothing)
                    .previews("mouseSmoothing", value: settings.mouseSmoothing)
                SettingsSlider("Mouse smoothing time", $settings.mouseSmoothingMs, 5...100, 5) {
                    String(format: "%.0f ms", $0)
                }
                .disabled(!settings.mouseSmoothing)
                .previews("mouseSmoothing", value: settings.mouseSmoothingMs)
            } header: {
                Text("Mouse")
            }

            Section {
                // Z/X, the stick on snap turning and free aim's zone edge all
                // turn by this angle (Renderer.requestSnapTurn).
                SettingsSlider("Snap-turn angle", $settings.snapTurnDegrees, 15...45, 5) {
                    String(format: "%.0f°", $0)
                }
                .previews("snapTurnDegrees", value: settings.snapTurnDegrees)
                Toggle("Smooth stick turning", isOn: $settings.stickSmoothTurn)
                SettingsSlider("Stick turn speed", $settings.stickTurnSpeed, 45...240, 15) {
                    String(format: "%.0f°/s", $0)
                }
                .disabled(!settings.stickSmoothTurn)
                Toggle("Look up/down with mouse and stick", isOn: $settings.lookPitch)
                    .previews("lookPitch", value: settings.lookPitch)
            } header: {
                Text("Turning")
            } footer: {
                Text("Z and X always snap-turn.")
            }

            Section {
                Toggle("Free aim", isOn: $settings.freeAim)
                    .previews("freeAim", value: settings.freeAim)
                Group {
                    SettingsSlider("Free-aim zone width", $settings.freeAimYaw, 0...45, 1) {
                        String(format: "±%.0f°", $0)
                    }
                    SettingsSlider("Free-aim zone height", $settings.freeAimPitch, 0...60, 1) {
                        String(format: "±%.0f°", $0)
                    }
                    Picker("Zone shape", selection: $settings.freeAimShape) {
                        ForEach(FreeAimShape.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Zone centred on", selection: $settings.freeAimAnchor) {
                        ForEach(FreeAimAnchor.allCases) { Text($0.label).tag($0) }
                    }
                    SettingsSlider("Head follow lag", $settings.freeAimFollow, 0.1...1.5, 0.05) {
                        String(format: "%.2f s", $0)
                    }
                    .disabled(settings.freeAimAnchor != .head)
                    Toggle("Turn the zone toward a turned head", isOn: $settings.freeAimRealign)
                        .disabled(settings.freeAimAnchor != .body)
                    SettingsSlider("…once the head is past", $settings.freeAimRealignAngle, 15...90, 5) {
                        String(format: "%.0f°", $0)
                    }
                    .disabled(settings.freeAimAnchor != .body || !settings.freeAimRealign)
                    SettingsSlider("…catching up over", $settings.freeAimRealignTime, 0.3...5, 0.1) {
                        String(format: "%.1f s", $0)
                    }
                    .disabled(settings.freeAimAnchor != .body || !settings.freeAimRealign)
                    Picker("Weapon turns about", selection: $settings.freeAimPivot) {
                        ForEach(FreeAimPivot.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Re-centre the aim when idle", isOn: $settings.freeAimRecenter)
                    SettingsSlider("Re-centre speed", $settings.freeAimRecenterTime, 0.2...3, 0.1) {
                        String(format: "%.1f s", $0)
                    }
                    .disabled(!settings.freeAimRecenter)
                    Toggle("Use (E) picks what the gun points at", isOn: $settings.freeAimUse)
                }
                .previews("freeAim", value: settings.freeAimShape)
                // weaponExternal is on the Immersion page.
                .disabled(!settings.freeAim || !settings.weaponExternal)
            } header: {
                Text("Free aim")
            } footer: {
                Text("Free aim needs “Hand-tracked weapon model” (Immersion).")
            }

            Section {
                // hevHUD is on the Immersion page.
                Picker("HEV holograms", selection: $settings.flatHUDPlacement) {
                    ForEach(FlatHUDPlacement.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.hevHUD)
                .previews("flatHUDPlacement", value: settings.flatHUDPlacement)
            }

            Section {
                Toggle("Mouse capture window", isOn: $settings.inputCatcher)
                    .previews("inputCatcher", value: settings.inputCatcher)
                Toggle("Ask before locking the mouse", isOn: $settings.inputCatcherAskBeforeLock)
                    .disabled(!settings.inputCatcher)
                Toggle("Re-centre it when the pointer leaves", isOn: $settings.inputCatcherRecenter)
                    .disabled(!settings.inputCatcher || settings.inputCatcherAskBeforeLock)
                SettingsSlider("Capture window opacity", $settings.inputCatcherAlpha, 0...0.1, 0.001) {
                    String(format: "%.3f", $0)
                }
                .disabled(!settings.inputCatcher)
            } header: {
                Text("Mouse capture")
            } footer: {
                Text("“Ask before locking the mouse” shows a small “Click to lock mouse” pane first; click it, or pinch it, to hand the mouse to the game. Moving the pointer off the game, or Esc, releases it. The pointer only counts what a window draws, so the window keeps a faint fill; if the mouse goes unheard it turns the fill up a little on its own.")
            }

            Section {
                DisclosureGroup("Controls") {
                    ControlsReferenceView()
                }
            } footer: {
                Text("Rebind keys in the game’s menu (Configuration › Controls).")
            }
        }
    }
}
