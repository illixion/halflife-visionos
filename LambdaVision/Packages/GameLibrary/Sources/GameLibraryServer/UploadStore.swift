//
//  UploadStore.swift
//  GameLibraryServer
//
//  Where uploaded files wait before an import: a staging tree laid out as
//  `<gamedir>/<path>`, which "commit" hands to the importer as an unpacked
//  directory. Each upload streams into a part file beside the tree and is
//  renamed into place only once every byte arrived, so the tree holds only
//  whole files and an interrupted transfer resumes from the manifest. The
//  tree outlives the server: an upload interrupted by closing the modal
//  picks up where it stopped next time.
//
//  Paths follow the importer's rules (GameImporter.safeRelativePath): no
//  `..`, no absolute paths, junk (`__MACOSX`, `.DS_Store`) skipped. Nothing
//  here creates symlinks, and the importer rejects any it finds.
//

import CryptoKit
import Foundation
import GameLibrary

public struct ManifestFile: Sendable, Equatable, Codable {
    /// Relative to the gamedir, as on disk.
    public var path: String
    public var size: Int64
    /// Seconds since 1970.
    public var mtime: Double
    public var sha256: String?
}

final class UploadStore: @unchecked Sendable {
    let root: URL
    var tree: URL { root.appendingPathComponent("tree") }
    var parts: URL { root.appendingPathComponent("parts") }
    var zips: URL { root.appendingPathComponent("zips") }
    let hashes: FileHashCache
    let hashCacheURL: URL?

    init(root: URL, hashCacheURL: URL?) {
        self.root = root
        self.hashCacheURL = hashCacheURL
        var records: [String: FileHashCache.Record] = [:]
        if let hashCacheURL, let data = try? Data(contentsOf: hashCacheURL),
           let decoded = try? JSONDecoder().decode([String: FileHashCache.Record].self, from: data) {
            records = decoded
        }
        hashes = FileHashCache(records: records)
        let fm = FileManager.default
        try? fm.createDirectory(at: tree, withIntermediateDirectories: true)
        // Part files and zips are only ever whole within one server lifetime.
        try? fm.removeItem(at: parts)
        try? fm.removeItem(at: zips)
        try? fm.createDirectory(at: parts, withIntermediateDirectories: true)
        try? fm.createDirectory(at: zips, withIntermediateDirectories: true)
    }

    /// Drops part files and zips of uploads cut off by a stop.
    func discardIncomplete() {
        let fm = FileManager.default
        try? fm.removeItem(at: parts)
        try? fm.removeItem(at: zips)
    }

    func saveHashes() {
        guard let hashCacheURL else { return }
        // Only files that still exist; the cache is keyed by full path.
        let live = hashes.snapshot.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard let data = try? JSONEncoder().encode(live) else { return }
        try? FileManager.default.createDirectory(at: hashCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: hashCacheURL, options: .atomic)
    }

    // MARK: Paths

    /// An upload path split into its gamedir and the path inside it; nil for
    /// junk that is skipped. Throws for anything unsafe, or a file outside
    /// any gamedir.
    static func split(_ raw: String) throws -> (gamedir: String, relative: String)? {
        guard let safe = try GameImporter.safeRelativePath(raw) else { return nil }
        let parts = safe.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw HTTPError(422, "a path must start with its game folder, like valve/maps/c0a0.bsp") }
        guard isGamedirName(parts[0]) else { throw HTTPError(422, "not a game folder name: \(parts[0])") }
        return (parts[0], parts[1])
    }

    /// A single path component naming a top-level game folder.
    static func isGamedirName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && name != ".." && !name.contains(":")
    }

    var isEmpty: Bool { stagedSummary().files == 0 }

    func stagedSummary() -> (files: Int, bytes: Int64, gamedirs: [String]) {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: tree.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var files = 0, bytes: Int64 = 0
        for d in dirs {
            for f in Self.listFiles(tree.appendingPathComponent(d)) { files += 1; bytes += f.size }
        }
        return (files, bytes, dirs)
    }

    func clearTree() {
        let fm = FileManager.default
        try? fm.removeItem(at: tree)
        try? fm.createDirectory(at: tree, withIntermediateDirectories: true)
    }

    // MARK: Manifests

    /// Every regular file below `dir` (symlinks skipped), relative paths.
    static func listFiles(_ dir: URL) -> [(path: String, size: Int64, mtime: Double)] {
        let fm = FileManager.default
        var out: [(String, Int64, Double)] = []
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        while let rel = e.nextObject() as? String {
            let attrs = e.fileAttributes
            guard attrs?[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append((rel, size, mtime))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    func manifest(of dir: URL, hashes withHashes: Bool) -> [ManifestFile] {
        Self.listFiles(dir).map { f in
            ManifestFile(path: f.path, size: f.size, mtime: f.mtime,
                         sha256: withHashes ? hashes.hash(dir.path + "/" + f.path) : nil)
        }
    }

    /// The staged copy of a gamedir, matched case-insensitively.
    func stagedDir(_ gamedir: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tree.path)) ?? []
        return names.first { $0.lowercased() == gamedir.lowercased() }.map { tree.appendingPathComponent($0) }
    }

    // MARK: Uploading

    /// A sink writing one file of `size` bytes to `staging/<gamedir>/<relative>`.
    func fileSink(gamedir: String, relative: String, size: Int, mtime: Double?, sha256: String?,
                  progress: @escaping @Sendable (Int) -> Void,
                  completed: @escaping @Sendable (Bool) -> Void) throws -> HTTPBodySink {
        // Reuse a staged gamedir's case so two spellings don't split it.
        let dirName = stagedDir(gamedir)?.lastPathComponent ?? gamedir
        let target = tree.appendingPathComponent(dirName).appendingPathComponent(relative)
        let part = parts.appendingPathComponent(UUID().uuidString)
        return try FileSink(part: part, target: target, expected: size, mtime: mtime,
                            sha256: sha256?.lowercased(), progress: progress, completed: completed)
    }

    /// A sink writing an uploaded zip, named as the user's file (the importer
    /// names a gamedir at the archive's top level after it).
    func zipSink(name: String, size: Int, completed: @escaping @Sendable (URL?) -> Void) throws -> HTTPBodySink {
        var base = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        if base.isEmpty || base.hasPrefix(".") { base = "upload.zip" }
        if !base.lowercased().hasSuffix(".zip") { base += ".zip" }
        let dir = zips.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(base)
        let part = parts.appendingPathComponent(UUID().uuidString)
        return try FileSink(part: part, target: target, expected: size, mtime: nil, sha256: nil,
                            progress: { _ in }, completed: { ok in completed(ok ? target : nil) })
    }
}

/// Streams a body into a part file, then renames it into place.
final class FileSink: HTTPBodySink, @unchecked Sendable {
    private let part: URL
    private let target: URL
    private let expected: Int
    private let mtime: Double?
    private let sha256: String?
    private let handle: FileHandle
    private var hasher = SHA256()
    private var written = 0
    private var done = false
    private let progress: @Sendable (Int) -> Void
    private let completed: @Sendable (Bool) -> Void

    init(part: URL, target: URL, expected: Int, mtime: Double?, sha256: String?,
         progress: @escaping @Sendable (Int) -> Void, completed: @escaping @Sendable (Bool) -> Void) throws {
        self.part = part; self.target = target; self.expected = expected
        self.mtime = mtime; self.sha256 = sha256
        self.progress = progress; self.completed = completed
        let fm = FileManager.default
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: part.path, contents: nil) else { throw HTTPError(500, "couldn't create a temporary file") }
        handle = try FileHandle(forWritingTo: part)
    }

    func write(_ data: Data) throws {
        guard written + data.count <= expected else { throw HTTPError(400, "more data than Content-Length") }
        do { try handle.write(contentsOf: data) } catch {
            throw HTTPError(507, "couldn't write the file (is the headset full?)")
        }
        if sha256 != nil { hasher.update(data: data) }
        written += data.count
        progress(data.count)
    }

    func finish() async -> HTTPResponse {
        done = true
        try? handle.close()
        let fm = FileManager.default
        if let sha256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == sha256 else {
                try? fm.removeItem(at: part)
                completed(false)
                return .error(422, "checksum mismatch; the file was not saved")
            }
        }
        do {
            let parent = target.deletingLastPathComponent()
            var isDir: ObjCBool = false
            // A file where a folder of the path should be: the folder wins.
            var p = parent
            while !fm.fileExists(atPath: p.path, isDirectory: &isDir) { p = p.deletingLastPathComponent() }
            if !isDir.boolValue { try fm.removeItem(at: p) }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // Replace an earlier upload of the same file, whatever its case.
            let name = target.lastPathComponent.lowercased()
            for existing in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where existing.lowercased() == name {
                try fm.removeItem(at: parent.appendingPathComponent(existing))
            }
            try fm.moveItem(at: part, to: target)
            if let mtime {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: target.path)
            }
        } catch {
            try? fm.removeItem(at: part)
            completed(false)
            return .error(500, "couldn't save the file")
        }
        completed(true)
        return .json(200, ["saved": true, "size": written])
    }

    func abort() {
        guard !done else { return }
        done = true
        try? handle.close()
        try? FileManager.default.removeItem(at: part)
        completed(false)
    }
}
