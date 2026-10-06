//
//  PathResolver.swift
//  GameLibrary
//
//  Game files are named for Windows, where case never matters: a mod asks
//  for `models/hgrunt03.mdl` and ships `models/Hgrunt03.mdl` (the HD pack
//  really does). The headset's filesystem is case-sensitive, so every
//  app-side open of a game file goes through here, the way the engine's own
//  filesystem fixes case (FS_FixFileCase). Files are never renamed.
//

import Foundation

public final class PathResolver: @unchecked Sendable {
    public static let shared = PathResolver()

    // Directory path → lowercased entry name → real entry name. Only
    // directories that needed a case-insensitive lookup are listed.
    private var listings: [String: [String: String]] = [:]
    private let lock = NSLock()
    private let exists: @Sendable (String) -> Bool

    public init() { exists = { FileManager.default.fileExists(atPath: $0) } }

    /// For tests on a case-insensitive Mac volume: a stricter existence check.
    init(exists: @escaping @Sendable (String) -> Bool) { self.exists = exists }

    /// The real path of `relative` under `root`, matching each component
    /// case-insensitively; nil when nothing matches. An exact match costs
    /// one stat; only a miss lists directories (and caches the listings).
    public func resolve(_ relative: String, in root: String) -> String? {
        let components = relative.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        guard !components.contains("..") else { return nil }
        let exact = components.isEmpty ? root : root + "/" + components.joined(separator: "/")
        if exists(exact) { return exact }
        var path = root
        for (i, component) in components.enumerated() {
            let candidate = path + "/" + component
            if exists(candidate) { path = candidate; continue }
            guard let real = entry(named: component, in: path, refresh: false)
                    ?? entry(named: component, in: path, refresh: true) else { return nil }
            path += "/" + real
            if i == components.count - 1 { return path }
        }
        return path
    }

    /// `resolve(_:in:)` for an absolute path whose case is only trusted up to
    /// `root`.
    public func resolve(absolute path: String, under root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return exists(path) ? path : nil }
        return resolve(String(path.dropFirst(root.count + 1)), in: root)
    }

    /// The first of `relative` found under each of `roots`, in order.
    public func firstMatch(_ relative: String, in roots: [String]) -> String? {
        for root in roots { if let p = resolve(relative, in: root) { return p } }
        return nil
    }

    /// Forgets cached listings (after an import changes the tree).
    public func invalidate() {
        lock.lock(); listings.removeAll(); lock.unlock()
    }

    private func entry(named name: String, in directory: String, refresh: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if refresh || listings[directory] == nil {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            var map: [String: String] = [:]
            // Sorted, so when two entries differ only by case the pick is stable.
            for n in names.sorted() where map[n.lowercased()] == nil { map[n.lowercased()] = n }
            listings[directory] = map
        }
        return listings[directory]?[name.lowercased()]
    }
}
