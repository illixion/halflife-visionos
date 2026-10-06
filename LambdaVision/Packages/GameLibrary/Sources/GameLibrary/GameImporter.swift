//
//  GameImporter.swift
//  GameLibrary
//
//  Installs what the user sends to the headset — a zip (AirDrop, Files) or
//  an already-unpacked tree (a folder picked in Files, or files uploaded
//  from a browser) — into GameData. Every route goes through here.
//
//  1. Validate: every zip entry is checked before anything is written. `..`,
//     absolute paths and symlinks fail the whole import; so does an archive
//     that wouldn't fit in free space.
//  2. Extract (zips only), streaming entry by entry into a staging dir on
//     the same volume as GameData, so the final move is a rename.
//  3. Locate gamedir roots at any depth: a single mod folder, a ModDB
//     wrapper folder around one, or a whole zipped HalfLifeAssets/ holding
//     several gamedirs and their overlays.
//  4. Install each gamedir: replace (swap the whole dir by rename) or merge
//     (move files in, matching existing dirs case-insensitively). Gamedirs
//     the running engine reads from are refused.
//  5. Rescan and normalize (vfs.cfg for HD overlays), then report each
//     installed game's kind.
//
//  Progress and everything worth telling the user arrive as `ImportEvent`s,
//  in order, from whichever thread runs the import.
//

import Foundation
import ZIPFoundation

public enum ImportSource: Sendable {
    /// A zip archive. `deleteWhenDone` removes it afterwards, whether the
    /// import succeeded or not — pass true only for a copy the app owns.
    case zip(URL, deleteWhenDone: Bool)
    /// An unpacked tree. `consume` moves its files instead of copying them
    /// (for upload staging the app owns).
    case directory(URL, consume: Bool)

    var url: URL {
        switch self { case .zip(let u, _), .directory(let u, _): return u }
    }
}

public enum ImportMode: String, Sendable, Codable, CaseIterable {
    /// Add and overwrite files, keep everything else in the gamedir.
    case merge
    /// The gamedir becomes exactly what was imported.
    case replace
}

public struct ImportOptions: Sendable {
    public var defaultMode: ImportMode
    /// Per-gamedir mode, keyed by lowercased gamedir name.
    public var modes: [String: ImportMode]
    /// Lowercased gamedir names that must not change (the running game's).
    public var protectedGamedirs: Set<String>
    /// How deep below the source's top level gamedir roots are looked for.
    public var maxDepth: Int

    public init(defaultMode: ImportMode = .merge, modes: [String: ImportMode] = [:],
                protectedGamedirs: Set<String> = [], maxDepth: Int = 6) {
        self.defaultMode = defaultMode; self.modes = modes
        self.protectedGamedirs = Set(protectedGamedirs.map { $0.lowercased() }); self.maxDepth = maxDepth
    }

    func mode(for gamedir: String) -> ImportMode { modes[gamedir.lowercased()] ?? defaultMode }
}

public enum ImportPhase: String, Sendable, Codable {
    case validating, extracting, locating, installing, normalizing, cleaningUp
}

public enum ImportWarning: Sendable, Equatable {
    /// Entries skipped as junk (`__MACOSX/`, `.DS_Store`).
    case ignoredEntries(count: Int)
    /// An overlay was installed whose base game isn't installed.
    case orphanOverlay(gamedir: String)
    case missingFallbackDir(gamedir: String, fallback: String)
    case postAnniversaryValve
    /// The game ships its own code; only its content runs (kind C).
    case customGameCode(gamedir: String)
}

public enum ImportEvent: Sendable, Equatable {
    case phase(ImportPhase)
    /// Bytes extracted or copied so far, of the total.
    case progress(completed: Int64, total: Int64)
    /// A gamedir root, with its path inside the source ("" for the top level).
    case foundGamedir(name: String, sourcePath: String)
    /// Not installed: the running engine reads from it.
    case refusedInUse(gamedir: String)
    case installed(gamedir: String, mode: ImportMode, files: Int)
    case normalized(NormalizeNote)
    case classified(gamedir: String, kind: GameKind)
    case warning(ImportWarning)
    case finished(ImportSummary)
}

public struct ImportSummary: Sendable, Equatable {
    /// Installed gamedirs, names as on disk.
    public var installed: [String]
    public var refused: [String]
    public var kinds: [String: GameKind]
}

public enum ImportError: Error, Equatable, Sendable {
    /// An entry path escaping the destination (`..`, absolute).
    case unsafePath(String)
    case symlink(String)
    case unreadableArchive
    /// Nothing in the source looks like a gamedir.
    case noGamedirs
    case insufficientSpace(needed: Int64, available: Int64)
    /// Every gamedir found is in use by the running game.
    case gameInUse([String])
    case io(String)
}

public final class GameImporter: Sendable {
    public let library: GameLibrary
    /// Where work dirs are made. Must be on the same volume as GameData.
    public let stagingRoot: URL

    public init(library: GameLibrary, stagingRoot: URL) {
        self.library = library
        self.stagingRoot = stagingRoot
    }

    /// Content folders that mark an overlay or a known gamedir as a root.
    static let contentDirs: Set<String> = ["models", "maps", "sound", "sprites", "gfx", "media",
                                            "resource", "events", "cl_dlls", "dlls"]
    static let junk: Set<String> = ["__macosx", ".ds_store", "thumbs.db"]

    /// The events of an import, ending with `.finished` or an error.
    public func events(_ source: ImportSource, options: ImportOptions = ImportOptions())
        -> AsyncThrowingStream<ImportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    _ = try await self.run(source, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs an import, reporting through `onEvent`. Cancellable between files.
    @discardableResult
    public func run(_ source: ImportSource, options: ImportOptions = ImportOptions(),
                    onEvent: @escaping @Sendable (ImportEvent) -> Void) async throws -> ImportSummary {
        let fm = FileManager.default
        let work = stagingRoot.appendingPathComponent("import-" + UUID().uuidString)
        func cleanUp() {
            onEvent(.phase(.cleaningUp))
            try? fm.removeItem(at: work)
            if case .zip(let url, true) = source { try? fm.removeItem(at: url) }
        }
        let summary: ImportSummary
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            summary = try await perform(source, options: options, work: work, onEvent: onEvent)
        } catch {
            cleanUp()
            throw error
        }
        cleanUp()
        onEvent(.finished(summary))
        return summary
    }

    private func perform(_ source: ImportSource, options: ImportOptions, work: URL,
                         onEvent: @escaping @Sendable (ImportEvent) -> Void) async throws -> ImportSummary {
        let fm = FileManager.default

        // 1–2. Validate and extract, or take the tree as it is.
        let tree: URL, consume: Bool
        switch source {
        case .zip(let url, _):
            tree = work.appendingPathComponent("extract")
            try extract(zip: url, to: tree, onEvent: onEvent)
            consume = true
        case .directory(let url, let move):
            onEvent(.phase(.validating))
            try Self.rejectSymlinks(in: url)
            tree = url
            consume = move
        }

        // 3. Locate.
        onEvent(.phase(.locating))
        let installed = Set(((try? fm.contentsOfDirectory(atPath: library.root.path)) ?? []).map { $0.lowercased() })
        let stem = source.url.deletingPathExtension().lastPathComponent
        let roots = Self.findRoots(in: tree, topLevelName: stem, installed: installed, maxDepth: options.maxDepth)
        guard !roots.isEmpty else { throw ImportError.noGamedirs }
        for r in roots {
            let rel = r.url.path == tree.path ? "" : String(r.url.path.dropFirst(tree.path.count + 1))
            onEvent(.foundGamedir(name: r.name, sourcePath: rel))
        }

        // 4. Install.
        onEvent(.phase(.installing))
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        var done: [String] = [], refused: [String] = []
        let total = roots.reduce(Int64(0)) { $0 + (consume ? 0 : Self.treeSize($1.url)) }
        var bytesDone: Int64 = 0
        for root in roots {
            try Task.checkCancellation()
            let lower = root.name.lowercased()
            let base = GameScanner.overlayBase(of: root.name)?.lowercased()
            if options.protectedGamedirs.contains(lower) || base.map(options.protectedGamedirs.contains) == true {
                refused.append(root.name)
                onEvent(.refusedInUse(gamedir: root.name))
                continue
            }
            let mode = options.mode(for: root.name)
            let (name, files) = try install(root.url, as: root.name, mode: mode, consume: consume, work: work) { bytes in
                bytesDone += bytes
                if total > 0 { onEvent(.progress(completed: bytesDone, total: total)) }
            }
            done.append(name)
            onEvent(.installed(gamedir: name, mode: mode, files: files))
        }
        if done.isEmpty && !refused.isEmpty { throw ImportError.gameInUse(refused) }

        // 5. Normalize and classify.
        onEvent(.phase(.normalizing))
        let refresh = library.refresh()
        for note in refresh.notes { onEvent(.normalized(note)) }
        var kinds: [String: GameKind] = [:]
        for name in done {
            if let game = refresh.scan.game(name) {
                kinds[game.gamedir] = game.kind
                onEvent(.classified(gamedir: game.gamedir, kind: game.kind))
                if game.kind == .custom { onEvent(.warning(.customGameCode(gamedir: game.gamedir))) }
                for w in game.warnings {
                    switch w {
                    case .missingFallbackDir(let fb): onEvent(.warning(.missingFallbackDir(gamedir: game.gamedir, fallback: fb)))
                    case .postAnniversaryValve: onEvent(.warning(.postAnniversaryValve))
                    }
                }
            } else if refresh.scan.orphanOverlays.contains(where: { $0.lowercased() == name.lowercased() }) {
                onEvent(.warning(.orphanOverlay(gamedir: name)))
            }
        }
        return ImportSummary(installed: done, refused: refused, kinds: kinds)
    }

    // MARK: - Zip

    /// A zip entry path made safe: `\` read as `/`, and nil for junk.
    /// Throws for anything that would land outside the destination.
    public static func safeRelativePath(_ raw: String) throws -> String? {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") || path.hasPrefix("~") { throw ImportError.unsafePath(raw) }
        if path.count >= 2, path[path.index(after: path.startIndex)] == ":" { throw ImportError.unsafePath(raw) }   // C:
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") { throw ImportError.unsafePath(raw) }
        let kept = parts.filter { $0 != "." }
        if kept.isEmpty { return nil }
        if kept.contains(where: { junk.contains($0.lowercased()) || $0.hasPrefix("._") }) { return nil }
        return kept.joined(separator: "/")
    }

    func extract(zip url: URL, to dest: URL, onEvent: @Sendable (ImportEvent) -> Void) throws {
        onEvent(.phase(.validating))
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw ImportError.unreadableArchive }
        var plan: [(Entry, String)] = [], ignored = 0, total: Int64 = 0
        for entry in archive {
            if entry.type == .symlink { throw ImportError.symlink(entry.path) }
            guard let rel = try Self.safeRelativePath(entry.path) else { ignored += 1; continue }
            plan.append((entry, rel))
            total += Int64(clamping: entry.uncompressedSize)
        }
        if ignored > 0 { onEvent(.warning(.ignoredEntries(count: ignored))) }
        if let available = Self.availableCapacity(at: dest.deletingLastPathComponent()), available < total {
            throw ImportError.insufficientSpace(needed: total, available: available)
        }

        onEvent(.phase(.extracting))
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var done: Int64 = 0, lastReported: Int64 = -1
        onEvent(.progress(completed: 0, total: total))
        for (entry, rel) in plan {
            try Task.checkCancellation()
            let target = dest.appendingPathComponent(rel)
            if entry.type == .directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // Two entries differing only in case, or a repeat: the later wins.
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            do {
                _ = try archive.extract(entry, to: target)
            } catch {
                throw ImportError.io("extract failed: \(error)")
            }
            done += Int64(clamping: entry.uncompressedSize)
            // At most ~200 progress events per archive.
            if total == 0 || done - lastReported >= total / 200 || done == total {
                lastReported = done
                onEvent(.progress(completed: done, total: total))
            }
        }
    }

    // MARK: - Locating

    struct Root: Equatable { var name: String; var url: URL }

    /// Gamedir roots in `tree`: the top level itself when it holds a
    /// liblist/gameinfo (named `topLevelName`), else every directory at any
    /// depth that does, that is an overlay, or that is named like an
    /// installed gamedir — both of the latter only when they hold game
    /// content. Roots aren't searched further.
    static func findRoots(in tree: URL, topLevelName: String, installed: Set<String>, maxDepth: Int) -> [Root] {
        if hasInfoFile(tree) { return [Root(name: sanitized(topLevelName), url: tree)] }
        var out: [Root] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            for name in subdirectories(dir) {
                let child = dir.appendingPathComponent(name)
                let lower = name.lowercased()
                let isRoot = hasInfoFile(child)
                    || ((GameScanner.overlayBase(of: name) != nil || installed.contains(lower)) && hasContent(child))
                if isRoot { out.append(Root(name: name, url: child)) } else { walk(child, depth: depth + 1) }
            }
        }
        walk(tree, depth: 0)
        // The same gamedir twice (two wrapper folders): keep the first.
        var seen = Set<String>()
        return out.filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "mod" : cleaned
    }

    static func subdirectories(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { name in
            guard !name.hasPrefix("."), !junk.contains(name.lowercased()) else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                && isDir.boolValue
        }.sorted()
    }

    static func hasInfoFile(_ dir: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() }
        return names.contains("liblist.gam") || names.contains("gameinfo.txt")
    }

    static func hasContent(_ dir: URL) -> Bool {
        subdirectories(dir).contains { contentDirs.contains($0.lowercased()) }
    }

    // MARK: - Installing

    /// Installs one gamedir; returns its name as on disk and the file count.
    func install(_ src: URL, as name: String, mode: ImportMode, consume: Bool, work: URL,
                 copied: (Int64) -> Void) throws -> (String, Int) {
        let fm = FileManager.default
        let existing = ((try? fm.contentsOfDirectory(atPath: library.root.path)) ?? [])
            .first { $0.lowercased() == name.lowercased() }
        let finalName = existing ?? name
        let dest = library.root.appendingPathComponent(finalName)
        do {
            if existing == nil || mode == .replace {
                // Prepare the whole dir beside GameData, then swap it in by rename.
                let prepared = work.appendingPathComponent("new-" + UUID().uuidString)
                if consume { try fm.moveItem(at: src, to: prepared) } else { try fm.copyItem(at: src, to: prepared) }
                let files = Self.fileCount(prepared)
                if !consume { copied(Self.treeSize(prepared)) }
                if existing != nil {
                    let old = work.appendingPathComponent("old-" + UUID().uuidString)
                    try fm.moveItem(at: dest, to: old)
                    do { try fm.moveItem(at: prepared, to: dest) } catch {
                        try? fm.moveItem(at: old, to: dest)   // put the original back
                        throw error
                    }
                    try? fm.removeItem(at: old)
                } else {
                    try fm.moveItem(at: prepared, to: dest)
                }
                return (finalName, files)
            }
            return (finalName, try merge(src, into: dest, consume: consume, copied: copied))
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.io("installing \(name): \(error)")
        }
    }

    /// Moves or copies every file of `src` into `dest`, following existing
    /// directories whatever their case and replacing files case-insensitively.
    func merge(_ src: URL, into dest: URL, consume: Bool, copied: (Int64) -> Void) throws -> Int {
        let fm = FileManager.default
        var count = 0
        func mergeDir(_ from: URL, _ to: URL) throws {
            let present = ((try? fm.contentsOfDirectory(atPath: to.path)) ?? [])
            var byLower: [String: String] = [:]
            for n in present.sorted() where byLower[n.lowercased()] == nil { byLower[n.lowercased()] = n }
            for name in ((try? fm.contentsOfDirectory(atPath: from.path)) ?? []).sorted() {
                try Task.checkCancellation()
                let item = from.appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &isDir)
                let match = byLower[name.lowercased()]
                if isDir.boolValue {
                    let target = to.appendingPathComponent(match ?? name)
                    var targetIsDir: ObjCBool = false
                    if fm.fileExists(atPath: target.path, isDirectory: &targetIsDir), !targetIsDir.boolValue {
                        try fm.removeItem(at: target)
                    }
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try mergeDir(item, target)
                } else {
                    if let match { try fm.removeItem(at: to.appendingPathComponent(match)) }
                    let target = to.appendingPathComponent(name)
                    let size = FileHashCache.stat(item.path)?.size ?? 0
                    if consume { try fm.moveItem(at: item, to: target) } else { try fm.copyItem(at: item, to: target); copied(size) }
                    count += 1
                }
            }
        }
        try mergeDir(src, dest)
        return count
    }

    // MARK: - Helpers

    public static func rejectSymlinks(in dir: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir.path) else { return }
        while let rel = e.nextObject() as? String {
            let type = (try? fm.attributesOfItem(atPath: dir.path + "/" + rel))?[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw ImportError.symlink(rel) }
        }
    }

    static func fileCount(_ dir: URL) -> Int {
        var n = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = e?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
        }
        return n
    }

    public static func treeSize(_ dir: URL) -> Int64 {
        var n: Int64 = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        while let url = e?.nextObject() as? URL {
            n += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return n
    }

    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 else { return nil }
        return v
    }
}
