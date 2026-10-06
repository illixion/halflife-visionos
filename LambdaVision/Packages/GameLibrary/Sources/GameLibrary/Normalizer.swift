//
//  Normalizer.swift
//  GameLibrary
//
//  Prepares an installed game for the engine, after an import and on launch
//  for gamedirs that changed — the on-device replacement for what
//  `scripts/push-assets.sh` did on the Mac.
//
//  - An HD overlay (`<dir>_hd`) only mounts with `fs_mount_hd 1`. vfs.cfg is
//    exec'd by FS_LoadGameInfo before the gamedir mounts, so writing it into
//    the game's own dir turns HD content on with no engine change. A
//    vfs.cfg the game already ships is left alone.
//  - A `valve/` from the 25th Anniversary Update is flagged: Xash and the mod
//    ecosystem target the `steam_legacy` build.
//

import Foundation

public enum NormalizeNote: Sendable, Equatable {
    /// Wrote `<gamedir>/vfs.cfg` with `fs_mount_hd "1"`.
    case wroteVFSConfig(gamedir: String)
    /// The game has an HD overlay and its own vfs.cfg, which was kept.
    case keptVFSConfig(gamedir: String)
    case postAnniversaryValve
}

public enum Normalizer {
    public static let vfsConfig = "fs_mount_hd \"1\"\n"

    /// Normalizes one game under `root`. Never overwrites files.
    public static func normalize(_ game: GameEntry, root: URL,
                                 resolver: PathResolver = .shared) throws -> [NormalizeNote] {
        var notes: [NormalizeNote] = []
        let dir = root.path + "/" + game.gamedir
        if game.hdOverlay != nil {
            if resolver.resolve("vfs.cfg", in: dir) != nil {
                notes.append(.keptVFSConfig(gamedir: game.gamedir))
            } else {
                try Data(vfsConfig.utf8).write(to: URL(fileURLWithPath: dir + "/vfs.cfg"), options: .withoutOverwriting)
                notes.append(.wroteVFSConfig(gamedir: game.gamedir))
            }
        }
        if game.warnings.contains(.postAnniversaryValve) { notes.append(.postAnniversaryValve) }
        return notes
    }

    /// Whether a `valve/` is from the 25th Anniversary Update (Nov 2023)
    /// rather than `steam_legacy`. Heuristic: its steam.inf `PatchVersion`
    /// is newer than legacy's 1.1.2.2, or it carries the Uplink maps the
    /// anniversary build folded into `valve/`.
    public static func isPostAnniversary(valveDir: String, resolver: PathResolver = .shared) -> Bool {
        if let inf = resolver.resolve("steam.inf", in: valveDir),
           let text = GameScanner.readText(inf),
           let line = text.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().hasPrefix("patchversion=") }) {
            let version = line.split(separator: "=").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if compare(version, "1.1.2.2") == .orderedDescending { return true }
        }
        return resolver.resolve("maps/hldemo1.bsp", in: valveDir) != nil
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
