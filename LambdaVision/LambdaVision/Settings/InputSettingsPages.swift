//
//  InputSettingsPages.swift
//  LambdaVision
//
//  Settings › Hands (hand tracking: the finger gun, movement gestures and
//  the weapon wheel) and Settings › Keyboard, Mouse & Gamepad (the desktop
//  devices, free aim and the mouse-capture window). Which of the two drives
//  the game at a given moment is the Input mode picker on the second page
//  (InputMode.swift).
//

import SwiftUI

struct HandSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Hands") {
            Section {
                Picker("Dominant hand", selection: $settings.dominantHand) {
                    ForEach(DominantHand.allCases) { Text($0.label).tag($0) }
                }
                Picker("Fire aims at", selection: $settings.fireAimMode) {
                    ForEach(FireAimMode.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("“Fire aims at → Where I look” is an accessibility option: shots follow your gaze instead of the weapon barrel, and the game’s own crosshair marks where they go.")
            }

            Section {
                Toggle("Immersive gesture input", isOn: $settings.gestureInputEnabled)
                Toggle("Alt-fire: thumb to middle finger", isOn: $settings.altFireGesture)
                    .disabled(!settings.gestureInputEnabled)
                SettingsSlider("Alt-fire sensitivity", $settings.altFireSensitivity, 0.5...2, 0.1) {
                    String(format: "%.1f×", $0)
                }
                .disabled(!settings.gestureInputEnabled || !settings.altFireGesture)
            } header: {
                Text("Gestures")
            } footer: {
                Text("“Immersive gesture input” lets you fire with a finger-gun — curl your dominant index finger to pull the trigger (it replaces look-and-pinch fire). Reload by curling your thumb down (index extended) and holding until the ring above the weapon fills. With “Alt-fire: thumb to middle finger”, press the tip of your thumb against the side of your curled middle finger (index still pointing) for alt-fire: it’s held as long as the thumb stays there, so taps zoom or launch a grenade and a hold charges the gauss gun; curl the index while holding to fire both. “Alt-fire sensitivity” sets how close the thumb must come (higher reacts from farther away; lower it if alt-fire goes off when you reload). After either thumb gesture, lift the thumb before doing the other. Press buttons by reaching out and poking with the off-hand index finger; rest an open palm on health/HEV chargers to keep them running. On a train, poke the console to take the controls, then pinch and push/pull to work the throttle; poke again to let go.")
            }

            Section {
                Toggle("Arm-swing walking", isOn: $settings.armSwingEnabled)
                    .disabled(!settings.gestureInputEnabled)
                Picker("Swing direction", selection: $settings.armSwingDirection) {
                    ForEach(ArmSwingDirection.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.gestureInputEnabled || !settings.armSwingEnabled)
                SettingsSlider("Swing sensitivity", $settings.armSwingSensitivity, 0.5...2, 0.1) {
                    String(format: "%.1f×", $0)
                }
                .disabled(!settings.gestureInputEnabled || !settings.armSwingEnabled)
                Toggle("Long jump at a run", isOn: $settings.handLongJump)
                    .disabled(!settings.gestureInputEnabled)
            } header: {
                Text("Movement")
            } footer: {
                Text("Move with the other hand: pinch thumb+index and drag like a joystick; raise or drop the pinched hand to jump or crouch. Or, with “Arm-swing walking”, close both hands into fists and pump your arms like jogging: the harder you swing, the faster you go, up to full run speed (“Swing sensitivity” sets how hard you need to swing). Flick both fists up together to jump. Once you’re running, point your gun hand (finger gun) to aim and fire while the other arm keeps you running; that arm’s flick alone then jumps. Swing the gun hand as a fist again to put it back in the run. With the long jump module, “Long jump at a run” turns a jump made at a full run into a long jump.")
            }

            Section {
                Toggle("Wheel: flashlight, quick save/load", isOn: $settings.wheelUtilities)
                Toggle("Wheel: reach past the rim to pick a weapon", isOn: $settings.wheelExpand)
                    .disabled(!settings.gestureInputEnabled)
            } header: {
                Text("Weapon wheel")
            } footer: {
                Text("Switch weapons with the weapon wheel: pinch all fingertips together (🤌), move your hand toward a sector, release to pick. It has one sector per weapon slot you hold anything in, showing the weapon a pick selects (pick a slot again to cycle through it); “Wheel: flashlight, quick save/load” adds those three sectors (hold quick load armed until its outer arc fills).")
            }
        }
    }
}

struct KeyboardMouseSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Keyboard, Mouse & Gamepad") {
            Section {
                Picker("Input mode", selection: $settings.inputMode) {
                    ForEach(InputModeSetting.allCases) { Text($0.label).tag($0) }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Now: \(InputModeState.current.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("“Input mode” on Auto follows the last thing you used: a key, the mouse or the gamepad switches to it at once, and a look-and-pinch brings the hands back (once the other device has been still for a second). With a keyboard, mouse or gamepad the game plays like the desktop original in stereo: the weapon is the classic viewmodel in front of you, the body’s arms stop following your hands and the hand gestures rest. Movement always reaches full run speed.")
            }

            Section {
                SettingsSlider("Mouse sensitivity", $settings.mouseSensitivity, 0.5...10, 0.5) {
                    String(format: "%.1f", $0)
                }
                Toggle("Mouse smoothing", isOn: $settings.mouseSmoothing)
                SettingsSlider("Mouse smoothing time", $settings.mouseSmoothingMs, 5...100, 5) {
                    String(format: "%.0f ms", $0)
                }
                .disabled(!settings.mouseSmoothing)
            } header: {
                Text("Mouse")
            } footer: {
                Text("“Mouse smoothing” spreads the mouse’s movement evenly across frames (visionOS delivers it less often than the game draws), at the cost of the set delay.")
            }

            Section {
                // Z/X, the stick on snap turning and free aim's zone edge all
                // turn by this angle (Renderer.requestSnapTurn).
                SettingsSlider("Snap-turn angle", $settings.snapTurnDegrees, 15...45, 5) {
                    String(format: "%.0f°", $0)
                }
                Toggle("Smooth stick turning", isOn: $settings.stickSmoothTurn)
                SettingsSlider("Stick turn speed", $settings.stickTurnSpeed, 45...240, 15) {
                    String(format: "%.0f°/s", $0)
                }
                .disabled(!settings.stickSmoothTurn)
                Toggle("Look up/down with mouse and stick", isOn: $settings.lookPitch)
            } header: {
                Text("Turning")
            } footer: {
                Text("Z and X always snap-turn. “Look up/down” adds mouse and stick pitch to your head’s; it tilts the game’s horizon away from the room’s, which some find uncomfortable, and hides the first-person body while a tilt is set.")
            }

            Section {
                Toggle("Free aim", isOn: $settings.freeAim)
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
                // weaponExternal is on the Body & Weapon page.
                .disabled(!settings.freeAim || !settings.weaponExternal)
            } header: {
                Text("Free aim")
            } footer: {
                Text("With “Free aim” (the Razer Hydra mods’ scheme) the mouse and the right stick swing the gun inside a zone ahead of your body, and only pushing past the zone’s edge turns you; the aim reticle marks where shots land, and looking around with your head doesn’t drag the gun. “Zone centred on → Head” lets the zone drift after your head instead. Centred on the body, “Turn the zone toward a turned head” brings it round to face you when you keep your head turned past the set angle (you turned in your seat, say); holding the Digital Crown to recentre also puts it back in front of you at once. Up/down past the zone is clamped, or tilts the view with “Look up/down” on. “Re-centre the aim when idle” eases the gun back to the middle when you stop moving the mouse. With the stick on snap turning, holding it at the zone’s edge snaps you once per push. Free aim off: the mouse and the right stick turn you directly and shots go where you look (the crosshair marks it). Free aim needs “Hand-tracked weapon model”.")
            }

            Section {
                // hevHUD is on the Body & Weapon page.
                Picker("HEV holograms", selection: $settings.flatHUDPlacement) {
                    ForEach(FlatHUDPlacement.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.hevHUD)
            } footer: {
                Text("“HEV holograms” on “Follow view” moves health and suit to the lower left of your view and ammo to the lower right, like Half-Life 2; they trail your head slightly, never far, instead of sticking to your eyes. “Attached to hands” keeps them on your hands as in hands mode.")
            }

            Section {
                Toggle("Mouse capture window", isOn: $settings.inputCatcher)
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
                Text("“Mouse capture window” keeps an invisible window in front of you while you play with a mouse: visionOS only lets the game read the mouse while the pointer is over one of its windows. It stays up while a mouse is connected and steps aside for the menu and the console; a look-and-pinch works through it as it does on the game, and brings the hands back. “Ask before locking the mouse” shows a small “Click to lock mouse” pane first; click it (or pinch it) to hand the mouse to the game. Moving the pointer off the game, or Esc (the game menu), releases it and the pane comes back. In Auto, the pane appears once you use the keyboard or the mouse. With asking off, the window takes over straight away and “Re-centre” reopens it in front of you when the pointer slips off it. The pointer only counts what a window draws, so the window keeps a faint fill (“Capture window opacity”); if the mouse goes unheard it turns the fill up a little on its own.")
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
