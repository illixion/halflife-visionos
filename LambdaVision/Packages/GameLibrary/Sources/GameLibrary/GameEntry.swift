//
//  GameEntry.swift
//  GameLibrary
//
//  One installed game as the library lists it, and the kinds a game can be.
//

import Foundation

/// A game whose code is linked into the app (contract 2's table).
public struct CompiledGame: Sendable, Equatable, Codable, Hashable {
    /// Canonical gamedir: "valve", "gearbox", "bshift".
    public var gamedir: String
    /// Game library basename: "hl", "opfor", "bshift".
    public var dll: String
    public var title: String

    public init(gamedir: String, dll: String, title: String) {
        self.gamedir = gamedir; self.dll = dll; self.title = title
    }

    /// What the app assumes when the engine publishes no table: Half-Life only.
    public static let fallback = [CompiledGame(gamedir: "valve", dll: "hl", title: "Half-Life")]
}

/// How much of a game can run, decided from its files on every scan.
public enum GameKind: String, Sendable, Codable, CaseIterable {
    /// Half-Life itself (`valve`).
    case base
    /// Kind A: maps, models and sounds only, or a library identical to
    /// Half-Life's — runs fully on Half-Life's code.
    case contentOnly
    /// Kind B: its code is one of the compiled-in ports.
    case compiledIn
    /// Kind C: ships its own game code, which can't run here; its content is
    /// tried on Half-Life's code (maps load, the mod's own entities are missing).
    case custom
}

/// Something about a game the player should know.
public enum GameWarning: Sendable, Equatable, Codable, Hashable {
    /// `fallback_dir` names a gamedir that isn't installed.
    case missingFallbackDir(String)
    /// This `valve/` is from the 25th Anniversary Update, not `steam_legacy`.
    case postAnniversaryValve
}

public struct GameEntry: Sendable, Equatable, Codable, Identifiable {
    /// The gamedir's name on disk — what `-game` gets.
    public var gamedir: String
    public var info: GameInfo
    /// Overlay dirs attached to this game (`valve_hd`, `valve_addon`), as on disk.
    public var overlays: [String]
    public var kind: GameKind
    /// The compiled-in port it runs on (kind B, and `valve` for the base game).
    public var compiledGame: CompiledGame?
    /// Why it got its kind, for logs (no paths, no user names).
    public var kindReason: String
    public var warnings: [GameWarning]

    public var id: String { gamedir }

    public var title: String {
        if let t = info.title, !t.isEmpty { return t }
        return compiledGame?.title ?? gamedir
    }

    /// The HD overlay's dir name, when installed.
    public var hdOverlay: String? { overlays.first { $0.lowercased().hasSuffix("_hd") } }

    public init(gamedir: String, info: GameInfo, overlays: [String], kind: GameKind,
                compiledGame: CompiledGame?, kindReason: String, warnings: [GameWarning]) {
        self.gamedir = gamedir; self.info = info; self.overlays = overlays; self.kind = kind
        self.compiledGame = compiledGame; self.kindReason = kindReason; self.warnings = warnings
    }

    /// The gamedirs studio models are looked up in, most preferred first:
    /// `<mod>_hd` → `<mod>` → `fallback_dir` → `valve_hd` → `valve`, keeping
    /// only those installed under `root` (names as on disk).
    public func contentChain(root: String, resolver: PathResolver = .shared) -> [String] {
        var wanted: [String] = []
        if let hd = hdOverlay { wanted.append(hd) }
        wanted.append(gamedir)
        if let fb = info.fallbackDir, !fb.isEmpty { wanted.append(fb) }
        wanted += ["valve_hd", "valve"]
        var out: [String] = []
        for name in wanted {
            guard let path = resolver.resolve(name, in: root) else { continue }
            let real = (path as NSString).lastPathComponent
            if !out.contains(where: { $0.lowercased() == real.lowercased() }) { out.append(real) }
        }
        return out
    }

    /// The gamedirs a running engine on this game reads from: the content
    /// chain plus every overlay of the dirs in it.
    public func dirsInUse(root: String, library: [GameEntry]) -> Set<String> {
        var dirs = Set(contentChain(root: root).map { $0.lowercased() })
        for g in library where dirs.contains(g.gamedir.lowercased()) {
            for o in g.overlays { dirs.insert(o.lowercased()) }
        }
        return dirs
    }
}
