//
//  ChapterCatalog.swift
//  LambdaVision
//
//  The chapters of each game the launcher offers a "start here" card for:
//  the map a chapter begins on and its title, taken from each game's
//  titles.txt. Foundation only, shared with Tools/LauncherProbe, which
//  checks the lists and the save-file map sniffing on the Mac.
//
//  Only chapters whose map is installed are shown (a trimmed install or a
//  mod may lack some), and a game this file doesn't know shows a map box
//  instead.
//

import Foundation

nonisolated struct Chapter: Identifiable, Hashable, Sendable {
    /// The map the chapter starts on (`map <id>`).
    let map: String
    let title: String
    /// 1-based position in the game, for the number on its card.
    let number: Int
    var id: String { map }
}

nonisolated enum ChapterCatalog {
    private static func list(_ rows: [(String, String)]) -> [Chapter] {
        rows.enumerated().map { Chapter(map: $1.0, title: $1.1, number: $0 + 1) }
    }

    /// Keyed by gamedir, lowercased.
    static let games: [String: [Chapter]] = [
        "valve": list([
            ("t0a0", "Hazard Course"), ("c0a0", "Black Mesa Inbound"), ("c1a0", "Anomalous Materials"),
            ("c1a1", "Unforeseen Consequences"), ("c1a2", "Office Complex"), ("c1a3", "\"We've Got Hostiles\""),
            ("c1a4", "Blast Pit"), ("c2a1", "Power Up"), ("c2a2", "On A Rail"), ("c2a3", "Apprehension"),
            ("c2a4", "Residue Processing"), ("c2a5", "Surface Tension"), ("c3a1", "\"Forget About Freeman!\""),
            ("c3a2", "Lambda Core"), ("c4a1", "Xen"), ("c4a2", "Gonarch's Lair"), ("c4a3", "Nihilanth"),
            ("c5a1", "Endgame"),
        ]),
        "gearbox": list([
            ("of0a0", "Boot Camp"), ("of1a1", "Incoming"), ("of1a3", "Welcome to Black Mesa"),
            ("of1a5", "\"We Are Pulling Out\""), ("of2a1", "Missing in Action"), ("of2a4", "Friendly Fire"),
            ("of3a1", "We Are Not Alone"), ("of3a4", "Crush Depth"), ("of4a1", "Vicarious Reality"),
            ("of4a4", "Pit Worm's Nest"), ("of5a1", "Foxtrot Uniform"), ("of6a1", "\"The Package\""),
            ("of6a4", "Worlds Collide"), ("of7a0", "Conclusion"),
        ]),
        "bshift": list([
            ("ba_hazard1", "Hazard Course"), ("ba_tram1", "Living Quarters Outbound"),
            ("ba_security1", "Insecurity"), ("ba_canal1", "Duty Calls"), ("ba_yard1", "Captive Freight"),
            ("ba_xen1", "Focal Point"), ("ba_power1", "Power Struggle"), ("ba_teleport1", "A Leap of Faith"),
        ]),
    ]

    static func chapters(for gamedir: String) -> [Chapter] { games[gamedir.lowercased()] ?? [] }

    /// The chapter a map belongs to: the last one that starts at or before
    /// it in the game's map order, judged by the stock naming (c1a2d is in
    /// c1a2's chapter; of3a2 comes after of3a1). Nil for a map the catalog
    /// can't place.
    static func chapter(containing map: String, in gamedir: String) -> Chapter? {
        let chapters = chapters(for: gamedir)
        let name = map.lowercased()
        // The longest chapter map that prefixes the name wins (c1a2 in c1a2d);
        // else the same area's earlier chapter.
        if let exact = chapters.filter({ name.hasPrefix($0.map) }).max(by: { $0.map.count < $1.map.count }) {
            return exact
        }
        // Blue Shift names its areas (ba_tram1...3, ba_yard4a): the chapter
        // is the one starting in the same area.
        if name.hasPrefix("ba_") {
            let stem = String(name.prefix { !$0.isNumber })
            return chapters.first { $0.map.hasPrefix(stem) }
        }
        guard let key = areaKey(name) else { return nil }
        return chapters.last { (areaKey($0.map) ?? ("", 0, 0)) <= key }
    }

    /// (family, act, area): c1a2 → ("c", 1, 2), of3a1 → ("of", 3, 1). Nil for
    /// names that don't follow the pattern (ba_*, t0a0 variants are matched
    /// by prefix above).
    private static func areaKey(_ name: String) -> (String, Int, Int)? {
        let scalars = Array(name)
        var i = 0
        var family = ""
        while i < scalars.count, scalars[i].isLetter { family.append(scalars[i]); i += 1 }
        guard !family.isEmpty, i < scalars.count, let act = scalars[i].wholeNumberValue else { return nil }
        i += 1
        guard i < scalars.count, scalars[i] == "a" else { return nil }
        i += 1
        guard i < scalars.count, let area = scalars[i].wholeNumberValue else { return nil }
        return (family, act, area)
    }

    // MARK: Saves

    /// The map a saved game was made on, found in the start of the file,
    /// where Half-Life's header names it. Best effort: nil when nothing in
    /// the first few KB looks like a map of the stock naming.
    static func mapName(inSave data: Data) -> String? {
        let head = data.prefix(8192)
        let text = String(decoding: head.map { $0 >= 32 && $0 < 127 ? $0 : 0x20 }, as: UTF8.self)
        let patterns = ["\\b(c[0-5]a[0-9][a-z0-9]*)\\b", "\\b(of[0-9]a[0-9][a-z0-9]*)\\b",
                        "\\b(t0a0[a-z0-9]*)\\b", "\\b(ba_[a-z0-9_]+)\\b"]
        var best: (Int, String)?
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            let offset = text.distance(from: text.startIndex, to: r.lowerBound)
            if best == nil || offset < best!.0 { best = (offset, String(text[r])) }
        }
        return best?.1
    }
}
