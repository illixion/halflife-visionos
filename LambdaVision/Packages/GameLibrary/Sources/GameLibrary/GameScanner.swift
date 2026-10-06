//
//  GameScanner.swift
//  GameLibrary
//
//  Lists the games under GameData and classifies each one.
//
//  A gamedir is a directory holding liblist.gam or gameinfo.txt. SteamPipe
//  overlays (`<dir>_hd`, `<dir>_addon`) belong to their base game and are
//  attached to it rather than listed.
//
//  Game code is static on this platform: whatever library a mod names, the
//  engine runs one of the compiled-in games. So the question per mod is
//  whether its own code matters:
//  - B, compiled-in: its gamedir, or the basename of any `gamedll*` field
//    (macOS/Linux before Windows — Blue Shift's Windows field says `hl.dll`),
//    is in the compiled-games table.
//  - A, content-only: every `gamedll*` field names Half-Life's library (or
//    reaches into `../valve`), and any such library it actually ships is
//    byte-identical to Half-Life's. A dll-less mod naming `bshift` is not A.
//  - C, custom: anything else.
//

import CryptoKit
import Foundation

public struct LibraryScan: Sendable, Equatable {
    public var games: [GameEntry]
    /// Overlay dirs whose base game isn't installed.
    public var orphanOverlays: [String]

    public func game(_ gamedir: String) -> GameEntry? {
        games.first { $0.gamedir.lowercased() == gamedir.lowercased() }
    }
}

public struct GameScanner: Sendable {
    public var root: URL
    public var compiledGames: [CompiledGame]
    public var hashes: FileHashCache
    public var resolver: PathResolver

    public init(root: URL, compiledGames: [CompiledGame], hashes: FileHashCache = FileHashCache(),
                resolver: PathResolver = .shared) {
        self.root = root
        self.compiledGames = compiledGames.isEmpty ? CompiledGame.fallback : compiledGames
        self.hashes = hashes
        self.resolver = resolver
    }

    static let overlaySuffixes = ["_hd", "_addon"]

    /// The base gamedir name an overlay belongs to, or nil for a non-overlay.
    public static func overlayBase(of name: String) -> String? {
        let lower = name.lowercased()
        for s in overlaySuffixes where lower.hasSuffix(s) && lower.count > s.count {
            return String(name.dropLast(s.count))
        }
        return nil
    }

    /// Reads a gamedir's liblist.gam (preferred) or gameinfo.txt.
    public static func readInfo(gamedir: String, resolver: PathResolver = .shared) -> GameInfo? {
        if let p = resolver.resolve("liblist.gam", in: gamedir), let text = readText(p) {
            return GameInfo.parseLiblist(text)
        }
        if let p = resolver.resolve("gameinfo.txt", in: gamedir), let text = readText(p) {
            return GameInfo.parseGameInfo(text)
        }
        return nil
    }

    static func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    public func scan() -> LibraryScan {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && isDirectory(root.path + "/" + $0) }
            .sorted()
        var infos: [String: GameInfo] = [:]
        for name in names {
            if let info = Self.readInfo(gamedir: root.path + "/" + name, resolver: resolver) {
                infos[name] = info
            }
        }
        var overlays: [String: [String]] = [:]
        var orphans: [String] = []
        for name in names {
            guard let base = Self.overlayBase(of: name) else { continue }
            // An overlay that has its own liblist but no base game is a game.
            if let real = infos.keys.first(where: { $0.lowercased() == base.lowercased() }) {
                overlays[real, default: []].append(name)
                infos[name] = nil
            } else if infos[name] == nil {
                orphans.append(name)
            }
        }
        let valveDir = names.first { $0.lowercased() == "valve" }
        var games: [GameEntry] = []
        for name in names {
            guard let info = infos[name] else { continue }
            var entry = classify(gamedir: name, info: info, valveDir: valveDir)
            entry.overlays = overlays[name] ?? []
            if let fb = info.fallbackDir, !fb.isEmpty,
               !names.contains(where: { $0.lowercased() == fb.lowercased() }) {
                entry.warnings.append(.missingFallbackDir(fb))
            }
            if name.lowercased() == "valve", Normalizer.isPostAnniversary(valveDir: root.path + "/" + name, resolver: resolver) {
                entry.warnings.append(.postAnniversaryValve)
            }
            games.append(entry)
        }
        // Half-Life first, then by title.
        games.sort { a, b in
            if (a.kind == .base) != (b.kind == .base) { return a.kind == .base }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return LibraryScan(games: games, orphanOverlays: orphans)
    }

    /// Classifies one gamedir (see the file comment).
    public func classify(gamedir name: String, info: GameInfo, valveDir: String?) -> GameEntry {
        func entry(_ kind: GameKind, _ game: CompiledGame?, _ reason: String) -> GameEntry {
            GameEntry(gamedir: name, info: info, overlays: [], kind: kind, compiledGame: game,
                      kindReason: reason, warnings: [])
        }
        let lower = name.lowercased()
        let base = compiledGames.first { $0.gamedir.lowercased() == "valve" } ?? CompiledGame.fallback[0]
        if lower == "valve" { return entry(.base, base, "Half-Life") }
        if let game = compiledGames.first(where: { $0.gamedir.lowercased() == lower }) {
            return entry(.compiledIn, game, "gamedir in compiled-games table")
        }
        let hlDll = base.dll.lowercased()
        let libraries = info.gamedllPaths
        for b in info.gamedllBasenames where b != hlDll {
            if let game = compiledGames.first(where: { $0.dll.lowercased() == b }) {
                return entry(.compiledIn, game, "game library in compiled-games table")
            }
        }
        // Content-only needs every named library to be Half-Life's…
        let foreign = libraries.filter {
            !GameInfo.pointsIntoValve($0) && GameInfo.basename(ofLibrary: $0) != hlDll
        }
        if !foreign.isEmpty { return entry(.custom, nil, "names its own game library") }
        // …and any copy it ships to match Half-Life's byte for byte.
        let modPath = root.path + "/" + name
        for lib in libraries where !GameInfo.pointsIntoValve(lib) {
            guard let shipped = resolver.resolve(lib, in: modPath) else { continue }
            guard let valveDir, let stock = resolver.resolve(lib, in: root.path + "/" + valveDir),
                  hashes.sameContents(shipped, stock) else {
                return entry(.custom, nil, "ships a modified Half-Life library")
            }
        }
        // Libraries it ships under other names (dlls/*.dll), when gamedll is
        // unset: still its own code unless identical to one of Half-Life's.
        if libraries.isEmpty, let dlls = resolver.resolve("dlls", in: modPath),
           let files = try? FileManager.default.contentsOfDirectory(atPath: dlls) {
            let stockDir = valveDir.flatMap { resolver.resolve("dlls", in: root.path + "/" + $0) }
            let stock = stockDir.map { d in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).map { d + "/" + $0 } } ?? []
            for f in files where Self.isLibrary(f) {
                let p = dlls + "/" + f
                if !stock.contains(where: { hashes.sameContents(p, $0) }) {
                    return entry(.custom, nil, "ships its own game library")
                }
            }
        }
        return entry(.contentOnly, base, libraries.isEmpty ? "no game library" : "uses Half-Life's game library")
    }

    static func isLibrary(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.hasSuffix(".dll") || l.hasSuffix(".so") || l.hasSuffix(".dylib")
    }

    private func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

/// SHA-256 of files, remembered by (path, size, mtime) so a launch never
/// rehashes a library that hasn't changed. Thread-safe; persisted in the
/// library manifest.
public final class FileHashCache: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var sha256: String
    }

    private var records: [String: Record]
    private let lock = NSLock()

    public init(records: [String: Record] = [:]) { self.records = records }

    public var snapshot: [String: Record] { lock.lock(); defer { lock.unlock() }; return records }

    /// Whether two files have identical contents. Different sizes never hash.
    public func sameContents(_ a: String, _ b: String) -> Bool {
        guard let sa = Self.stat(a), let sb = Self.stat(b), sa.size == sb.size else { return false }
        guard let ha = hash(a, stat: sa), let hb = hash(b, stat: sb) else { return false }
        return ha == hb
    }

    public func hash(_ path: String) -> String? {
        guard let s = Self.stat(path) else { return nil }
        return hash(path, stat: s)
    }

    private func hash(_ path: String, stat s: (size: Int64, mtime: Double)) -> String? {
        lock.lock()
        if let r = records[path], r.size == s.size, r.mtime == s.mtime { lock.unlock(); return r.sha256 }
        lock.unlock()
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // Each chunk is autoreleased; without a pool per chunk a whole
        // gamedir's worth of buffers stays alive until the caller's pool drains.
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.lock()
        records[path] = Record(size: s.size, mtime: s.mtime, sha256: digest)
        lock.unlock()
        return digest
    }

    public static func stat(_ path: String) -> (size: Int64, mtime: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.int64Value else { return nil }
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }
}
