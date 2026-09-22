//
//  SettingsView.swift
//  LambdaVision
//
//  Player-facing settings, presented as a sheet from the launcher's gear
//  button. A single scrolling Form with grouped sections (Graphics / Audio /
//  Input / Advanced), matching the shape of a sibling app's settings view.
//
//  Controls bind straight to the @Observable GameSettings; each property's
//  didSet persists to AppSettingsStore and pushes the change to the running
//  game, so there's no separate save step here. The Advanced actions (Xash
//  menu portal, map loader, console) issue console commands and are disabled
//  until the engine is up (settings.isEngineReady) — dispatching to the GL
//  worker before it exists would deadlock.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var consoleText = ""
    // Snapshot of the reload-requiring settings when the sheet opened, so we
    // can offer a reload on close if they changed.
    @State private var snapScale = 0.0
    @State private var showReloadPrompt = false

    // A handful of chapter-start maps for the Advanced loader.
    private let maps: [(id: String, name: String)] = [
        ("c0a0", "Black Mesa Inbound (tram)"),
        ("c1a0", "Anomalous Materials"),
        ("c1a1", "Unforeseen Consequences"),
        ("c2a1", "Power Up"),
        ("c3a1", "Forget About Freeman"),
    ]

    var body: some View {
        @Bindable var settings = appModel.gameSettings

        NavigationStack {
            Form {
                Section {
                    slider("Render scale", $settings.renderScale, 0.5...1.0, 0.05) {
                        String(format: "%.0f%%", $0 * 100)
                    }
                    // No MetalFX toggle here on purpose: the optional
                    // FXAA-pass → MetalFX-spatial chain added two
                    // full-logical-resolution passes per eye and measured
                    // ~13-14 ms GPU/frame (~50 FPS), and its upscale to the
                    // full drawable fought the compositor's own foveated
                    // upsampling. GameSettings.metalFXEnabled forces it off
                    // at startup; the scaler code stays compiled in case a
                    // cheaper configuration brings it back. Edge smoothing is
                    // the toggle below, folded into the composite pass.
                    Toggle("Edge smoothing (FXAA)", isOn: $settings.fxaaEnabled)
                    slider("Gamma", $settings.gamma, 1.8...3.0, 0.1) {
                        String(format: "%.1f", $0)
                    }
                    slider("Brightness", $settings.brightness, 0.0...1.0, 0.05) {
                        String(format: "%.2f", $0)
                    }
                    slider("Snap-turn angle", $settings.snapTurnDegrees, 15...45, 5) {
                        String(format: "%.0f°", $0)
                    }
                } header: {
                    Text("Graphics")
                } footer: {
                    Text("Render scale resizes the render targets, so it applies when the immersive space restarts — you'll be offered a reload on closing. Edge smoothing runs inside the pass that already draws the game to the display, so it applies immediately and costs no extra pass; turn it off if distant HUD or console text looks soft.")
                }

                Section("Diagnostics") {
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
                }

                Section("Audio") {
                    slider("Sound effects", $settings.sfxVolume, 0...1, 0.05, format: percent)
                    slider("Music (MP3)", $settings.musicVolume, 0...1, 0.05, format: percent)
                }

                Section {
                    Picker("Dominant hand", selection: $settings.dominantHand) {
                        ForEach(DominantHand.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Fire aims at", selection: $settings.fireAimMode) {
                        ForEach(FireAimMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Hand-tracked weapon model", isOn: $settings.weaponExternal)
                    Toggle("First-person body", isOn: $settings.avatarBody)
                    Toggle("Legs", isOn: $settings.avatarLegs)
                        .disabled(!settings.avatarBody)
                    Toggle("HEV suit holograms", isOn: $settings.hevHUD)
                    Picker("Aim reticle", selection: $settings.aimReticle) {
                        ForEach(AimReticle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Fast weapon switch", isOn: $settings.fastWeaponSwitch)
                    Toggle("Immersive gesture input", isOn: $settings.gestureInputEnabled)
                    Toggle("Arm-swing walking", isOn: $settings.armSwingEnabled)
                        .disabled(!settings.gestureInputEnabled)
                    Picker("Swing direction", selection: $settings.armSwingDirection) {
                        ForEach(ArmSwingDirection.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!settings.gestureInputEnabled || !settings.armSwingEnabled)
                    slider("Swing sensitivity", $settings.armSwingSensitivity, 0.5...2, 0.1) {
                        String(format: "%.1f×", $0)
                    }
                    .disabled(!settings.gestureInputEnabled || !settings.armSwingEnabled)
                } header: {
                    Text("Input")
                } footer: {
                    Text("“Hand-tracked weapon model” draws the weapon in your hand, tracking it directly (world-lit); off falls back to the classic engine-drawn weapon. “First-person body” draws Gordon under your head, following your hands and holding the weapon; “Legs” stands him on the game’s floor, stepping as you walk, turn or move with the stick. “HEV suit holograms” replaces the flat HUD: ammo floats beside the weapon, and health and suit charge appear over your other forearm when you turn it toward you. “Aim reticle” marks where the gun’s shot would land; “Dot and beam” adds a faint line from the muzzle. “Fire aims at → Where I look” is an accessibility option: shots follow your gaze instead of the weapon barrel. “Immersive gesture input” lets you fire with a finger-gun — curl your dominant index finger to pull the trigger (it replaces look-and-pinch fire). Reload by curling your thumb down (index extended) and holding until the ring above the weapon fills. Move with the other hand: pinch thumb+index and drag like a joystick; raise or drop the pinched hand to jump or crouch. Or, with “Arm-swing walking”, close both hands into fists and pump your arms like jogging: the harder you swing, the faster you go, up to full run speed (“Swing sensitivity” sets how hard you need to swing). Flick both fists up together to jump. Once you’re running, point your gun hand (finger gun) to aim and fire while the other arm keeps you running; that arm’s flick alone then jumps. Swing the gun hand as a fist again to put it back in the run. Switch weapons with the weapon wheel: pinch all fingertips together (🤌), move your hand toward a sector, release to pick that slot (works best with fast weapon switch on). Press buttons by reaching out and poking with the off-hand index finger; rest an open palm on health/HEV chargers to keep them running. On a train, poke the console to take the controls, then pinch and push/pull to work the throttle; poke again to let go.")
                }

                Section {
                    // Open the stock menu at its main screen and let the
                    // player navigate. (Jumping straight to menu_options /
                    // menu_multiplayer pops the first-run "player name" box.)
                    Button("Open Half-Life menu") { settings.command("menu_main") }
                        .disabled(!settings.isEngineReady)

                    Menu("Load map") {
                        ForEach(maps, id: \.id) { m in
                            Button("\(m.id) — \(m.name)") { settings.command("map \(m.id)") }
                        }
                    }
                    .disabled(!settings.isEngineReady)

                    Button("Restart current map") { settings.command("restart") }
                        .disabled(!settings.isEngineReady)

                    HStack {
                        TextField("Console command", text: $consoleText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { runConsole(settings) }
                        Button("Run") { runConsole(settings) }
                            .disabled(consoleText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .disabled(!settings.isEngineReady)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text(settings.isEngineReady
                         ? "The menu buttons open the stock Half-Life menu inside the immersive space — use it for Configuration, Multiplayer, and other tabs not surfaced here."
                         : "Start the game (Show Immersive Space) to enable these.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 640)
        .onAppear {
            snapScale = appModel.gameSettings.renderScale
        }
        .alert("Reload game to apply changes?", isPresented: $showReloadPrompt) {
            Button("Reload") { reloadImmersiveSpace(); dismiss() }
            Button("Later", role: .cancel) { dismiss() }
        } message: {
            Text("Render scale only takes effect when the immersive space restarts.")
        }
    }

    // Offer a reload only if a render-target setting actually changed and the
    // game is running (otherwise the next launch/open picks it up anyway).
    private func done() {
        let s = appModel.gameSettings
        let changed = s.renderScale != snapScale
        if changed && appModel.immersiveSpaceState == .open {
            showReloadPrompt = true
        } else {
            dismiss()
        }
    }

    // The hide/show "dance": dismiss + reopen the immersive space so a fresh
    // Renderer reallocates the render targets at the new scale.
    private func reloadImmersiveSpace() {
        Task { @MainActor in
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened: break
            default: appModel.immersiveSpaceState = .closed
            }
        }
    }

    private func runConsole(_ settings: GameSettings) {
        settings.command(consoleText)
        consoleText = ""
    }

    // MARK: - Slider row

    private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private func slider(_ title: String,
                        _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        _ step: Double,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

#Preview(windowStyle: .automatic) {
    SettingsView()
        .environment(AppModel())
}
