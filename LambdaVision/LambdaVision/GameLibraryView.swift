//
//  GameLibraryView.swift
//  LambdaVision
//
//  The main window's game library: the installed games with their kind
//  badges, onboarding when there are none, and the import log.
//

import SwiftUI
import GameLibrary

/// The installed games; tapping one makes it the game that launches.
struct GameLibraryList: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let library = appModel.library
        let selected = library.selectedGame?.gamedir
        VStack(alignment: .leading, spacing: 8) {
            Text("Games").font(.headline)
            ForEach(library.games) { game in
                Button { library.select(game) } label: {
                    GameRow(game: game, isSelected: game.gamedir == selected)
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(game.gamedir == selected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .hoverEffect()
            }
            if let title = library.pendingSwitchTitle {
                Label("Reopen LambdaVision to switch to \(title).", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reads the version so a selection redraws the checkmarks.
        .id(library.selectionVersion)
    }
}

private struct GameRow: View {
    let game: GameEntry
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(game.title).font(.body.weight(.semibold))
                    KindBadge(kind: game.kind)
                    if game.hdOverlay != nil {
                        Text("HD").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(game.gamedir).font(.caption.monospaced()).foregroundStyle(.secondary)
                if game.kind == .custom {
                    Text("This mod's own game code can't run on Vision Pro. Its maps and content run on Half-Life's code, so its new weapons, enemies and features will be missing.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(game.warnings, id: \.self) { warning in
                    Text(Self.describe(warning)).font(.caption).foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    static func describe(_ w: GameWarning) -> String {
        switch w {
        case .missingFallbackDir(let fb): "Needs \(fb), which isn't installed."
        case .postAnniversaryValve: "25th Anniversary build: the steam_legacy branch works best."
        }
    }
}

struct KindBadge: View {
    let kind: GameKind

    var body: some View {
        Text(kind.badge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch kind {
        case .base: .green
        case .contentOnly: .blue
        case .compiledIn: .teal
        case .custom: .orange
        }
    }
}

/// Shown when no game is installed: how to get Half-Life onto the headset.
struct GameOnboarding: View {
    let onImport: () -> Void
    let onWiFi: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add Half-Life", systemImage: "square.and.arrow.down.on.square").font(.title3.weight(.semibold))
            Text("LambdaVision plays your own copy of Half-Life. On a computer, download the pre-anniversary build with SteamCMD:")
                .fixedSize(horizontal: false, vertical: true)
            Text("steamcmd +force_install_dir HalfLife +login YOUR_STEAM_NAME +app_update 70 -beta steam_legacy validate +quit")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("The easiest way: choose Manage over Wi-Fi and open the address it shows on that computer, then drop the HalfLife folder onto the page. Or zip the folder (or just its valve and valve_hd folders) and AirDrop it to Vision Pro, choosing LambdaVision, or put it in Files and import it here. Opposing Force (app 50) and Blue Shift (app 130) work the same way.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Manage over Wi-Fi…", systemImage: "wifi", action: onWiFi)
                    .buttonStyle(.borderedProminent)
                Button("Import…", systemImage: "folder", action: onImport)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Progress and log of the current or last import.
struct ImportStatusView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let library = appModel.library
        VStack(alignment: .leading, spacing: 6) {
            if library.isImporting {
                if let p = library.importProgress {
                    ProgressView(value: p) { Text("Importing…") }
                } else {
                    ProgressView { Text("Importing…") }
                }
            }
            ForEach(library.importLog.suffix(12)) { line in
                Label(line.text, systemImage: line.isWarning ? "exclamationmark.triangle" : "checkmark")
                    .font(.caption)
                    .foregroundStyle(line.isWarning ? .yellow : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
