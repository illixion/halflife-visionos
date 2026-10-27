//
//  GameMenuSettingsPage.swift
//  LambdaVision
//
//  Settings › Menu, Maps & Console: the Xash menu portal, the map loader and
//  a console line. Each issues a console command, so all of them are
//  disabled until the engine is up (settings.isEngineReady) — dispatching to
//  the GL worker before it exists would deadlock.
//

import SwiftUI

struct GameMenuSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    @State private var consoleText = ""

    // A handful of chapter-start maps for the loader.
    private let maps: [(id: String, name: String)] = [
        ("c0a0", "Black Mesa Inbound (tram)"),
        ("c1a0", "Anomalous Materials"),
        ("c1a1", "Unforeseen Consequences"),
        ("c2a1", "Power Up"),
        ("c3a1", "Forget About Freeman"),
    ]

    var body: some View {
        let settings = appModel.gameSettings
        SettingsPage("Menu, Maps & Console") {
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
            } footer: {
                Text(settings.isEngineReady
                     ? "The menu buttons open the stock Half-Life menu inside the immersive space — use it for Configuration, Multiplayer, and other tabs not surfaced here."
                     : "Start the game (Show Immersive Space) to enable the menu and console.")
            }
        }
    }

    private func runConsole(_ settings: GameSettings) {
        settings.command(consoleText)
        consoleText = ""
    }
}
