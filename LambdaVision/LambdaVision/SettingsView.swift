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

    @State private var consoleText = ""

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
                    Toggle("MetalFX upscaling", isOn: $settings.metalFXEnabled)
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
                    Text("Render scale and MetalFX resize the render targets — they take effect the next time you enter the immersive space.")
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
                    Toggle("Fast weapon switch", isOn: $settings.fastWeaponSwitch)
                    Toggle("Immersive gesture input", isOn: $settings.gestureInputEnabled)
                } header: {
                    Text("Input")
                } footer: {
                    Text("“Fire aims at → Where I look” is an accessibility option: shots follow your gaze instead of the weapon barrel. Finger-gun and gesture controls arrive in a later update.")
                }

                Section {
                    HStack {
                        Button("Main menu") { settings.command("menu_main") }
                        Spacer()
                        Button("Options") { settings.command("menu_options") }
                        Spacer()
                        Button("Multiplayer") { settings.command("menu_multiplayer") }
                    }
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
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 640)
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
