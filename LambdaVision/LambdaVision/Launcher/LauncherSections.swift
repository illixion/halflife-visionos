//
//  LauncherSections.swift
//  LambdaVision
//
//  The launcher window's panels, top to bottom: the banner with the play
//  button, the quick actions, the chapter picker, saved games, and a console
//  line. Everything that talks to the engine goes through GameLauncher, and
//  waits for the engine to be up (settings.isEngineReady): dispatching to
//  the GL worker before it exists would deadlock.
//

import SwiftUI
import GameLibrary

/// What the engine is showing right now, for the banner.
enum GameStatus {
    /// The loaded map, from `cl_levelshot_name` ("levelshots/<map>_16x9"),
    /// which the client sets on every map load, changelevel included.
    static func currentMap() -> String? {
        guard lambda_debug_in_game() != 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        let exists = buf.withUnsafeMutableBufferPointer {
            lambda_debug_cvar("cl_levelshot_name", $0.baseAddress, Int32($0.count))
        }
        guard exists != 0 else { return nil }
        var shot = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard shot.hasPrefix("levelshots/") else { return nil }
        shot.removeFirst("levelshots/".count)
        for suffix in ["_16x9", "_4x3"] where shot.hasSuffix(suffix) { shot.removeLast(suffix.count) }
        return shot.isEmpty ? nil : shot
    }
}

// MARK: - Banner

struct LauncherBanner: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    let game: GameEntry

    var body: some View {
        let launcher = appModel.launcher
        let chapters = ChapterCatalog.chapters(for: game.gamedir)
        ZStack(alignment: .bottomLeading) {
            Group {
                if let first = chapters.first {
                    ChapterArt(gamedir: game.gamedir, chapter: first, showsNumber: false)
                } else {
                    LinearGradient(colors: [ChapterArt.accent(for: game.gamedir).opacity(0.8), .black],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            LinearGradient(colors: [.black.opacity(0.78), .black.opacity(0.15)],
                           startPoint: .leading, endPoint: .trailing)

            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LAMBDA VISIONPRO").font(.caption.weight(.semibold)).tracking(2)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(game.title).font(.system(size: 46, weight: .bold, design: .rounded))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(status(chapters))
                            .font(.callout).foregroundStyle(.white.opacity(0.8))
                    }
                    HStack(spacing: 12) {
                        Button { playTapped() } label: {
                            Label(playTitle, systemImage: appModel.immersiveSpaceState == .open ? "xmark" : "play.fill")
                                .font(.title3.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ChapterArt.accent(for: game.gamedir))
                        .disabled(playDisabled)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    Button {
                        appModel.settingsPageRequest = .presets
                        openWindow(id: SettingsView.windowID)
                    } label: {
                        Label(appModel.presets.active(for: appModel.gameSettings)?.name ?? "Custom",
                              systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    KindBadge(kind: game.kind)
                }
            }
            .padding(28)
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .foregroundStyle(.white)
    }

    private var playTitle: String {
        if appModel.isPreparing {
            let p = appModel.preparationProgress
            return p.total > 0 ? "Preparing weapons… \(p.done)/\(p.total)" : "Preparing…"
        }
        switch appModel.immersiveSpaceState {
        case .open: return "Leave game"
        case .inTransition: return "One moment…"
        case .closed: return appModel.library.engineRunning ? "Resume" : "Play"
        }
    }

    private var playDisabled: Bool {
        appModel.isPreparing || appModel.immersiveSpaceState == .inTransition || appModel.library.isImporting
    }

    private func playTapped() {
        if appModel.immersiveSpaceState == .open { appModel.launcher.leave() } else { appModel.launcher.start() }
    }

    private func status(_ chapters: [Chapter]) -> String {
        guard appModel.immersiveSpaceState == .open, appModel.gameSettings.isEngineReady else {
            return appModel.library.engineRunning ? "Paused" : "Ready when you are"
        }
        guard let map = GameStatus.currentMap() else { return "In the game" }
        if let chapter = ChapterCatalog.chapter(containing: map, in: game.gamedir) {
            return "\(chapter.title) · \(map)"
        }
        return map
    }
}

// MARK: - Quick actions

struct QuickActions: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    private struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let needsGame: Bool
        let run: () -> Void
    }

    var body: some View {
        let launcher = appModel.launcher
        let ready = appModel.gameSettings.isEngineReady && appModel.immersiveSpaceState == .open
        let actions: [Action] = [
            Action(id: "menu", title: "Game menu", symbol: "line.3.horizontal", needsGame: true) { launcher.run("menu_main") },
            Action(id: "save", title: "Quick save", symbol: "square.and.arrow.down", needsGame: true) {
                launcher.run("savequick")
                Task { try? await Task.sleep(for: .seconds(1.5)); appModel.refreshSaves() }
            },
            Action(id: "load", title: "Quick load", symbol: "clock.arrow.circlepath", needsGame: true) { launcher.run("loadquick") },
            Action(id: "restart", title: "Restart level", symbol: "arrow.clockwise", needsGame: true) { launcher.run("restart") },
            Action(id: "log", title: "Console log", symbol: "terminal", needsGame: false) { openWindow(id: "console") },
            Action(id: "settings", title: "Settings", symbol: "gearshape", needsGame: false) { openWindow(id: SettingsView.windowID) },
        ]
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                ForEach(actions) { action in
                    let off = action.needsGame && !ready
                    Button(action: action.run) {
                        VStack(spacing: 8) {
                            Image(systemName: action.symbol).font(.title2)
                            Text(action.title).font(.footnote.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .hoverEffect()
                    .opacity(off ? 0.4 : 1)
                    .disabled(off)
                }
            }
            if !ready {
                Text("The game menu, saving and loading work once you are in the game.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Chapters

struct ChapterPicker: View {
    @Environment(AppModel.self) private var appModel
    let game: GameEntry

    @State private var pending: Chapter?
    @State private var mapName = ""

    private var installed: [Chapter] {
        guard let root = GameData.directory else { return [] }
        return ChapterCatalog.chapters(for: game.gamedir).filter { chapter in
            ([game.gamedir] + game.overlays).contains { dir in
                PathResolver.shared.resolve("\(dir)/maps/\(chapter.map).bsp", in: root) != nil
            }
        }
    }

    var body: some View {
        let chapters = installed
        VStack(alignment: .leading, spacing: 12) {
            Text("Chapters").font(.title3.weight(.semibold))
            if chapters.isEmpty {
                HStack {
                    TextField("Map name", text: $mapName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(loadTypedMap)
                    Button("Load map", action: loadTypedMap)
                        .disabled(mapName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("This game's chapters aren't listed here. Type a map to start on.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(chapters) { chapter in
                            Button { choose(chapter) } label: {
                                ChapterCard(gamedir: game.gamedir, chapter: chapter,
                                            isCurrent: GameStatus.currentMap().flatMap {
                                                ChapterCatalog.chapter(containing: $0, in: game.gamedir)
                                            } == chapter && appModel.launcher.isRunning)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert("Start “\(pending?.title ?? "")”?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("Start chapter", role: .destructive) {
                if let pending { appModel.launcher.start(then: "map \(pending.map)") }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Your progress in the level you are in is lost unless you have saved.")
        }
    }

    private func choose(_ chapter: Chapter) {
        if appModel.launcher.isRunning { pending = chapter } else { appModel.launcher.start(then: "map \(chapter.map)") }
    }

    private func loadTypedMap() {
        let name = mapName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return }
        appModel.launcher.start(then: "map \(name)")
        mapName = ""
    }
}

struct ChapterCard: View {
    let gamedir: String
    let chapter: Chapter
    var isCurrent = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ChapterArt(gamedir: gamedir, chapter: chapter)
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text("CHAPTER \(chapter.number)").font(.caption2.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text(chapter.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(14)
            if isCurrent {
                Label("Playing", systemImage: "play.fill").font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.green, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }
        }
        .frame(width: 280, height: 175)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(isCurrent ? 0.6 : 0.12), lineWidth: isCurrent ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Saved games

struct SavedGames: View {
    @Environment(AppModel.self) private var appModel
    let game: GameEntry
    @State private var pending: SaveSlot?

    var body: some View {
        let slots = appModel.saves.slots
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved games").font(.title3.weight(.semibold))
            if slots.isEmpty {
                Text("Nothing saved yet. Quick save from the weapon wheel or the button above, and it appears here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(slots) { slot in
                            Button { choose(slot) } label: { SaveCard(slot: slot, gamedir: game.gamedir) }
                                .buttonStyle(.plain)
                                .hoverEffect()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert("Load “\(pending?.title ?? "")”?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("Load", role: .destructive) {
                if let pending { appModel.launcher.start(then: "load \(pending.name)") }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Your progress in the level you are in is lost unless you have saved.")
        }
    }

    private func choose(_ slot: SaveSlot) {
        if appModel.launcher.isRunning { pending = slot } else { appModel.launcher.start(then: "load \(slot.name)") }
    }
}

struct SaveCard: View {
    let slot: SaveSlot
    let gamedir: String

    var body: some View {
        let chapter = slot.map.flatMap { ChapterCatalog.chapter(containing: $0, in: gamedir) }
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let thumbnail = slot.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else if let chapter {
                    ChapterArt(gamedir: gamedir, chapter: chapter)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 240, height: 130)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title).font(.headline)
                Text([chapter?.title ?? slot.map, slot.date.formatted(.relative(presentation: .named))]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(12)
            .frame(width: 240, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Console

struct ConsoleCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var text = ""

    var body: some View {
        let launcher = appModel.launcher
        let ready = appModel.gameSettings.isEngineReady
        VStack(alignment: .leading, spacing: 12) {
            Text("Console").font(.title3.weight(.semibold))
            HStack {
                TextField("Console command", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(send)
                Button("Run", action: send)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!ready)
            if !launcher.history.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(launcher.history, id: \.self) { line in
                            Button(line) { launcher.run(line) }
                                .buttonStyle(.bordered).font(.caption.monospaced())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .disabled(!ready)
            }
            if !ready {
                Text("Works once you are in the game.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func send() {
        appModel.launcher.run(text)
        text = ""
    }
}
