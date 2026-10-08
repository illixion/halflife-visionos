//
//  GameLibraryStore.swift
//  LambdaVision
//
//  The main window's view of the game library (GameLibrary package): the
//  installed games, which one launches, imports in flight, and the engine's
//  change-game requests. Scans and imports run off the main thread; their
//  results and events land here.
//

import Foundation
import GameLibrary
import DebugTrace

@MainActor
@Observable
final class GameLibraryStore {
    /// The store the engine's change-game request reaches (one per app).
    private(set) static var current: GameLibraryStore?

    /// The last scan; nil until the first refresh finishes.
    private(set) var scan: LibraryScan?
    var games: [GameEntry] { scan?.games ?? [] }
    /// Whether a refresh is running.
    private(set) var isScanning = false
    /// Bumped by every finished refresh (the warm-up keys on it).
    private(set) var scanVersion = 0

    /// The persisted choice, if it is installed; else Half-Life, else the
    /// first game.
    var selectedGame: GameEntry? {
        let wanted = (AppSettingsStore.selectedGame ?? "valve").lowercased()
        return games.first { $0.gamedir.lowercased() == wanted }
            ?? games.first { $0.kind == .base } ?? games.first
    }
    /// Bumped on selection so views re-read `selectedGame`.
    private(set) var selectionVersion = 0

    /// The game Xash is currently reloading after a selection change.
    private(set) var pendingSwitchTitle: String?

    // Import state.
    private(set) var isImporting = false
    private(set) var importProgress: Double?
    private(set) var importLog: [ImportLogLine] = []
    private(set) var importError: String?
    /// An import started over Wi-Fi is running (GameLibraryServer).
    var externalImportRunning = false
    private var refreshSoonTask: Task<Void, Never>?

    struct ImportLogLine: Identifiable, Hashable {
        let id = UUID()
        var text: String
        var isWarning = false
    }

    init() {
        GameLibraryStore.current = self
        lambda_set_game_change_handler { dir in
            guard let dir else { return }
            let gamedir = String(cString: dir)
            Task { @MainActor in GameLibraryStore.current?.engineRequestedGame(gamedir) }
        }
    }

    /// Whether the engine has started at least once in this app session.
    var engineRunning: Bool { GameData.runningGame != nil }

    /// Persists a choice and asks the running renderer to reload Xash.
    func select(_ game: GameEntry) {
        AppSettingsStore.selectedGame = game.gamedir
        Renderer.setLaunchGame(game)
        selectionVersion += 1
        AppLog.app.log("[Library] selected \(game.gamedir, privacy: .private) kind=\(game.kind.rawValue, privacy: .public)")
        if let running = GameData.runningGame, running.gamedir.lowercased() != game.gamedir.lowercased() {
            pendingSwitchTitle = game.title
        } else {
            pendingSwitchTitle = nil
        }
    }

    /// The engine's change-game path: from its own Custom Game menu.
    func engineRequestedGame(_ gamedir: String) {
        AppLog.app.log("[Library] engine requested game change to \(gamedir, privacy: .private)")
        AppSettingsStore.selectedGame = gamedir
        selectionVersion += 1
        Renderer.setLaunchGame(games.first { $0.gamedir.lowercased() == gamedir.lowercased() })
        if let running = GameData.runningGame,
           running.gamedir.lowercased() == gamedir.lowercased() {
            pendingSwitchTitle = nil
        } else {
            pendingSwitchTitle = games.first { $0.gamedir.lowercased() == gamedir.lowercased() }?.title ?? gamedir
        }
    }

    func engineDidSwitchGame() {
        pendingSwitchTitle = nil
    }

    /// Rescans GameData and normalizes gamedirs that changed since last time.
    func refresh() async {
        guard let root = GameData.documentsRoot else { return }
        isScanning = true
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Bundled assets (BUNDLE_HL_ASSETS) are read-only: scan, never normalize.
        let docsHasGames = GameData.hasAnyGame(root.path)
        let bundled = (Bundle.main.resourcePath ?? "") + "/GameData"
        let result: (LibraryScan, LibraryRefresh?) = await Task.detached(priority: .userInitiated) {
            if docsHasGames || !GameData.hasAnyGame(bundled) {
                let r = GameData.library(root: root.path).refresh()
                return (r.scan, r)
            }
            let scan = GameScanner(root: URL(fileURLWithPath: bundled), compiledGames: GameData.compiledGames).scan()
            return (scan, nil)
        }.value
        scan = result.0
        scanVersion += 1
        isScanning = false
        if let r = result.1 { log(refresh: r) }
    }

    /// Cheap change check for the slow home-screen rescan: GameData's entries
    /// and their modification dates, so a folder copied on from the Mac (or a
    /// new file inside one) shows up without a relaunch.
    private var lastRootSignature: String?

    func refreshIfChanged() async {
        guard !isScanning, let root = GameData.documentsRoot else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        let sig = entries.map { url -> String in
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let inner = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
            let innerSig = inner.map { "\($0.lastPathComponent)@\((try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate)?.timeIntervalSince1970 ?? 0)" }.sorted().joined(separator: ",")
            return "\(url.lastPathComponent)@\(date)[\(innerSig)]"
        }.sorted().joined(separator: "|")
        guard sig != lastRootSignature else { return }
        lastRootSignature = sig
        await refresh()
    }

    /// Rescans shortly, coalescing bursts (Wi-Fi imports and deletes).
    func refreshSoon() {
        refreshSoonTask?.cancel()
        refreshSoonTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            PathResolver.shared.invalidate()
            await refresh()
        }
    }

    private func log(refresh r: LibraryRefresh) {
        AppLog.app.log("[Library] \(r.scan.games.count) games, \(r.changed.count) changed, \(r.notes.count) normalize notes, \(r.scan.orphanOverlays.count) orphan overlays")
        for g in r.scan.games {
            AppLog.app.log("[Library] \(g.gamedir, privacy: .private): \(g.kind.rawValue, privacy: .public) (\(g.kindReason, privacy: .public)) overlays=\(g.overlays.count) warnings=\(g.warnings.count)")
        }
        for (dir, error) in r.failures {
            AppLog.app.error("[Library] normalize failed for \(dir, privacy: .private): \(error, privacy: .private)")
        }
    }

    // MARK: - Importing

    /// Imports files picked in the Files app (security-scoped URLs).
    func importPicked(_ urls: [URL]) {
        Task { for url in urls { await importItem(url) } }
    }

    /// Imports what AirDrop / "Open in" handed the app.
    func open(_ url: URL) {
        Task { await importItem(url) }
    }

    /// Imports one zip or folder. A zip is copied first (the original
    /// belongs to the user, or sits in our Inbox, and the importer deletes
    /// its copy); a folder is read in place while access lasts.
    func importItem(_ url: URL) async {
        guard !isImporting, !externalImportRunning else {
            importError = "An import is already running."
            return
        }
        guard let root = GameData.documentsRoot else { return }
        isImporting = true
        importProgress = nil
        importError = nil
        importLog = [ImportLogLine(text: "Importing \(url.lastPathComponent)…")]
        defer { isImporting = false; importProgress = nil }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("GameImport")
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let source: ImportSource
        if isDirectory {
            source = .directory(url, consume: false)
        } else {
            let copy = staging.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                fail("Couldn't read the file.", error)
                return
            }
            // AirDrop and "Open in" may leave their own copy in Documents/Inbox.
            if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
            source = .zip(copy, deleteWhenDone: true)
        }

        // While the engine runs, everything it reads from stays untouched.
        var options = ImportOptions()
        if let running = GameData.runningGame {
            options.protectedGamedirs = running.dirsInUse(root: root.path, library: games)
        }
        let importer = GameImporter(library: GameData.library(root: root.path), stagingRoot: staging)
        AppLog.app.log("[Import] start: \(isDirectory ? "folder" : "zip", privacy: .public) protected=\(options.protectedGamedirs.count)")
        do {
            for try await event in importer.events(source, options: options) { handle(event) }
        } catch let error as ImportError {
            fail(Self.describe(error), error)
        } catch {
            fail("Import failed.", error)
        }
        PathResolver.shared.invalidate()
        await refresh()
    }

    private func fail(_ message: String, _ error: Error) {
        importError = message
        importLog.append(ImportLogLine(text: message, isWarning: true))
        AppLog.app.error("[Import] failed: \(message, privacy: .public) — \(error, privacy: .private)")
    }

    private func handle(_ event: ImportEvent) {
        switch event {
        case .phase(let p):
            AppLog.app.log("[Import] phase \(p.rawValue, privacy: .public)")
        case .progress(let done, let total):
            importProgress = total > 0 ? Double(done) / Double(total) : nil
        case .foundGamedir(let name, _):
            importLog.append(ImportLogLine(text: "Found \(name)"))
            AppLog.app.log("[Import] found gamedir \(name, privacy: .private)")
        case .refusedInUse(let name):
            importLog.append(ImportLogLine(text: "Skipped \(name): the running game uses it. Reopen LambdaVision and import again.", isWarning: true))
            AppLog.app.log("[Import] refused \(name, privacy: .private): in use")
        case .installed(let name, let mode, let files):
            importLog.append(ImportLogLine(text: "Installed \(name) (\(files) files, \(mode == .merge ? "merged" : "replaced"))"))
            AppLog.app.log("[Import] installed \(name, privacy: .private) mode=\(mode.rawValue, privacy: .public) files=\(files)")
        case .normalized(let note):
            switch note {
            case .wroteVFSConfig(let g):
                importLog.append(ImportLogLine(text: "Turned on the HD pack for \(g)"))
            case .keptVFSConfig: break
            case .postAnniversaryValve: break   // reported as a warning below
            }
        case .classified(let name, let kind):
            importLog.append(ImportLogLine(text: "\(name): \(kind.badge)"))
            AppLog.app.log("[Import] \(name, privacy: .private) classified \(kind.rawValue, privacy: .public)")
        case .warning(let w):
            importLog.append(ImportLogLine(text: Self.describe(w), isWarning: true))
            AppLog.app.log("[Import] warning: \(String(describing: w), privacy: .private)")
        case .finished(let s):
            importLog.append(ImportLogLine(text: s.installed.isEmpty ? "Nothing was installed." : "Done."))
            AppLog.app.log("[Import] finished installed=\(s.installed.count) refused=\(s.refused.count)")
        }
    }

    static func describe(_ error: ImportError) -> String {
        switch error {
        case .unsafePath, .symlink:
            "This archive contains unsafe paths and was not imported."
        case .unreadableArchive:
            "This isn't a zip archive LambdaVision can read."
        case .noGamedirs:
            "No game folders found. A game folder holds a liblist.gam (like valve/ or gearbox/)."
        case .insufficientSpace(let needed, let available):
            "Not enough space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free."
        case .gameInUse(let dirs):
            "\(dirs.joined(separator: ", ")) is in use by the running game. Reopen LambdaVision, then import before starting the game."
        case .io:
            "Couldn't write the game files."
        }
    }

    static func describe(_ w: ImportWarning) -> String {
        switch w {
        case .ignoredEntries(let n): "Skipped \(n) macOS metadata files."
        case .orphanOverlay(let g): "\(g) is an add-on for a game that isn't installed yet."
        case .missingFallbackDir(let g, let fb): "\(g) needs \(fb), which isn't installed."
        case .postAnniversaryValve: "This Half-Life is the 25th Anniversary build. Use the steam_legacy branch for the best results."
        case .customGameCode(let g): "\(g) ships its own game code, which can't run here. Its maps run on Half-Life's code, so some of its own features will be missing."
        }
    }
}

extension GameKind {
    /// The library's badge for the kind.
    var badge: String {
        switch self {
        case .base: "Ready"
        case .contentOnly: "Content mod"
        case .compiledIn: "Compiled-in"
        case .custom: "Experimental"
        }
    }
}
