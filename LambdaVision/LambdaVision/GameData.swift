//
//  GameData.swift
//  LambdaVision
//
//  Where the games are on this headset, which one runs, and where its files
//  are looked up.
//

import Foundation
import GameLibrary

nonisolated enum GameData {
    /// Documents/GameData: where imports land (and where
    /// `scripts/push-assets.sh` copies to). Visible in the Files app.
    static var documentsRoot: URL? {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("GameData") }
    }

    /// The read-only game directory the engine is started with (`-rodir`):
    /// Documents/GameData when it holds a game (imported on the headset, or
    /// pushed with `scripts/push-assets.sh` — survives plain reinstalls but
    /// is wiped by an uninstall), else assets bundled into the app
    /// (`build-and-sign.sh --set BUNDLE_HL_ASSETS=1`). Nil when neither has
    /// any game.
    static var directory: String? {
        let docs = documentsRoot?.path
        let bundled = (Bundle.main.resourcePath ?? "") + "/GameData"
        return [docs, bundled].compactMap { $0 }.first { hasAnyGame($0) }
    }

    /// Whether `root` holds at least one gamedir (any case of liblist.gam /
    /// gameinfo.txt).
    static func hasAnyGame(_ root: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.contains { name in
            GameScanner.readInfo(gamedir: root + "/" + name) != nil
        }
    }

    /// The games linked into this build (contract 2), Half-Life first.
    static let compiledGames: [CompiledGame] = {
        var out: [CompiledGame] = []
        guard var p = Lambda_CompiledGames() else { return CompiledGame.fallback }
        while let dir = p.pointee.gamedir {
            out.append(CompiledGame(gamedir: String(cString: dir),
                                    dll: p.pointee.dll.map { String(cString: $0) } ?? "",
                                    title: p.pointee.title.map { String(cString: $0) } ?? String(cString: dir)))
            p += 1
        }
        return out.isEmpty ? CompiledGame.fallback : out
    }()

    /// The library over `root`, remembering what it saw in Application Support.
    static func library(root: String) -> GameLibrary {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return GameLibrary(root: URL(fileURLWithPath: root),
                           manifestURL: support?.appendingPathComponent("LambdaVision/library-manifest.json"),
                           compiledGames: compiledGames)
    }

    /// The game the engine was started with, set once before it starts; nil
    /// until then. Read from the render thread.
    nonisolated(unsafe) static var runningGame: GameEntry?

    /// Half-Life as the library would list it, for when there's no scan.
    static let halfLife = GameEntry(gamedir: "valve", info: GameInfo(title: "Half-Life", startMap: "c0a0"),
                                    overlays: [], kind: .base, compiledGame: CompiledGame.fallback[0],
                                    kindReason: "Half-Life", warnings: [])

    /// The gamedirs studio models are loaded from, most preferred first:
    /// `<mod>_hd` → `<mod>` → `fallback_dir` → `valve_hd` → `valve`, each's
    /// `models/` (whatever its case) when installed.
    static func modelDirectories(for game: GameEntry, in directory: String) -> [String] {
        game.contentChain(root: directory).compactMap { PathResolver.shared.resolve($0 + "/models", in: directory) }
    }

    /// A game file under the content chain, found case-insensitively.
    static func resolve(_ relative: String, for game: GameEntry, in directory: String) -> String? {
        PathResolver.shared.firstMatch(relative, in: game.contentChain(root: directory).map { directory + "/" + $0 })
    }
}
