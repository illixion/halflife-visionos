//
//  GameLibrary.swift
//  GameLibrary
//
//  The launch-time pass: scan GameData, normalize only the gamedirs that
//  changed since the last launch, and remember what was seen. Change is
//  judged from a stored manifest of sizes and modification times (of each
//  gamedir, its info files and its libraries) — nothing is read in bulk,
//  and a library is hashed once per change, not once per launch.
//

import Foundation

public struct LibraryManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = LibraryManifest.currentVersion
    /// Gamedir name (lowercased) → fingerprint at the last normalize.
    public var gamedirs: [String: String] = [:]
    public var hashes: [String: FileHashCache.Record] = [:]

    public init() {}
}

public struct LibraryRefresh: Sendable {
    public var scan: LibraryScan
    /// Gamedirs new or changed since the last refresh (names as on disk).
    public var changed: [String]
    public var notes: [NormalizeNote]
    /// Gamedirs whose normalize failed, with the error's description.
    public var failures: [String: String]
}

public final class GameLibrary: @unchecked Sendable {
    public let root: URL
    public let manifestURL: URL?
    public let compiledGames: [CompiledGame]
    public let resolver: PathResolver
    private let lock = NSLock()

    public init(root: URL, manifestURL: URL?, compiledGames: [CompiledGame],
                resolver: PathResolver = .shared) {
        self.root = root
        self.manifestURL = manifestURL
        self.compiledGames = compiledGames.isEmpty ? CompiledGame.fallback : compiledGames
        self.resolver = resolver
    }

    /// Scans, normalizes what changed (all of it with `force`), saves the
    /// manifest. Safe to call off the main thread; calls are serialised.
    public func refresh(force: Bool = false) -> LibraryRefresh {
        lock.lock()
        defer { lock.unlock() }
        resolver.invalidate()
        var manifest = loadManifest()
        let hashes = FileHashCache(records: manifest.hashes)
        let scanner = GameScanner(root: root, compiledGames: compiledGames, hashes: hashes, resolver: resolver)
        let scan = scanner.scan()
        var changed: [String] = [], notes: [NormalizeNote] = [], failures: [String: String] = [:]
        var fingerprints: [String: String] = [:]
        for game in scan.games {
            let key = game.gamedir.lowercased()
            var print = fingerprint(game)
            if force || manifest.gamedirs[key] != print {
                changed.append(game.gamedir)
                do {
                    notes += try Normalizer.normalize(game, root: root, resolver: resolver)
                    print = fingerprint(game)   // writing vfs.cfg moved the dir's mtime
                } catch {
                    failures[game.gamedir] = String(describing: error)
                }
            }
            fingerprints[key] = print
        }
        manifest.gamedirs = fingerprints
        // Keep only hashes of files that still exist.
        manifest.hashes = hashes.snapshot.filter { FileManager.default.fileExists(atPath: $0.key) }
        saveManifest(manifest)
        return LibraryRefresh(scan: scan, changed: changed, notes: notes, failures: failures)
    }

    /// Sizes and mtimes of what decides a game's kind and normalize state.
    func fingerprint(_ game: GameEntry) -> String {
        let dir = root.path + "/" + game.gamedir
        var parts: [String] = []
        func add(_ path: String?) {
            guard let path, let s = FileHashCache.stat(path) else { parts.append("-"); return }
            parts.append("\(s.size)@\(s.mtime)")
        }
        add(dir)
        add(resolver.resolve("liblist.gam", in: dir))
        add(resolver.resolve("gameinfo.txt", in: dir))
        add(resolver.resolve("vfs.cfg", in: dir))
        if let dlls = resolver.resolve("dlls", in: dir) {
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: dlls)) ?? []).sorted() { add(dlls + "/" + f) }
        }
        parts.append(game.overlays.sorted().joined(separator: ","))
        parts.append(compiledGames.map { "\($0.gamedir):\($0.dll)" }.joined(separator: ","))
        return parts.joined(separator: "|")
    }

    private func loadManifest() -> LibraryManifest {
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(LibraryManifest.self, from: data),
              m.version == LibraryManifest.currentVersion else { return LibraryManifest() }
        return m
    }

    private func saveManifest(_ m: LibraryManifest) {
        guard let manifestURL, let data = try? JSONEncoder().encode(m) else { return }
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }
}
