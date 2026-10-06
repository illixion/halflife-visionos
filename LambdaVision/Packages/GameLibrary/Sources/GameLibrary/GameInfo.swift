//
//  GameInfo.swift
//  GameLibrary
//
//  What a gamedir says about itself: Valve's liblist.gam, or Xash's own
//  gameinfo.txt. Both are `key "value"` lines with `//` comments; they differ
//  in key names (liblist's `game` is gameinfo's `title`), and liblist is the
//  one Valve and ModDB mods ship, so it wins when a dir has both — Xash
//  itself regenerates gameinfo.txt from liblist.gam.
//

import Foundation

public struct GameInfo: Sendable, Equatable, Codable {
    /// Display title (`game` / `title`).
    public var title: String?
    /// The Windows game DLL as written (`dlls\hl.dll`), slashes normalised.
    public var gamedll: String?
    public var gamedllLinux: String?
    public var gamedllOSX: String?
    /// The gamedir this one falls back to for missing content (`fallback_dir`).
    public var fallbackDir: String?
    /// `singleplayer_only`, `multiplayer_only`, …
    public var type: String?
    public var startMap: String?
    public var trainMap: String?
    /// Every key as read, lowercased, last one wins.
    public var raw: [String: String]

    public init(title: String? = nil, gamedll: String? = nil, gamedllLinux: String? = nil,
                gamedllOSX: String? = nil, fallbackDir: String? = nil, type: String? = nil,
                startMap: String? = nil, trainMap: String? = nil, raw: [String: String] = [:]) {
        self.title = title; self.gamedll = gamedll; self.gamedllLinux = gamedllLinux
        self.gamedllOSX = gamedllOSX; self.fallbackDir = fallbackDir; self.type = type
        self.startMap = startMap; self.trainMap = trainMap; self.raw = raw
    }

    /// Parses liblist.gam.
    public static func parseLiblist(_ text: String) -> GameInfo {
        let kv = keyValues(text)
        return GameInfo(title: kv["game"], gamedll: kv["gamedll"].map(normalisedPath),
                        gamedllLinux: kv["gamedll_linux"].map(normalisedPath),
                        gamedllOSX: kv["gamedll_osx"].map(normalisedPath),
                        fallbackDir: kv["fallback_dir"], type: kv["type"],
                        startMap: kv["startmap"], trainMap: kv["trainmap"], raw: kv)
    }

    /// Parses Xash's gameinfo.txt.
    public static func parseGameInfo(_ text: String) -> GameInfo {
        let kv = keyValues(text)
        return GameInfo(title: kv["title"], gamedll: kv["gamedll"].map(normalisedPath),
                        gamedllLinux: kv["gamedll_linux"].map(normalisedPath),
                        gamedllOSX: kv["gamedll_osx"].map(normalisedPath),
                        fallbackDir: kv["fallback_dir"], type: kv["type"],
                        startMap: kv["startmap"], trainMap: kv["trainmap"], raw: kv)
    }

    /// Every `gamedll*` field that is set, macOS and Linux before Windows:
    /// the Windows one is the least reliable (Blue Shift's says `hl.dll`
    /// while its macOS and Linux ones name `bshift`).
    public var gamedllPaths: [String] {
        [gamedllOSX, gamedllLinux, gamedll].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The basenames of `gamedllPaths`, without directories or extension, the
    /// way the compiled-games table names them: `dlls\opfor.dll` → `opfor`.
    public var gamedllBasenames: [String] {
        var seen: [String] = []
        for p in gamedllPaths {
            if let b = Self.basename(ofLibrary: p), !seen.contains(b) { seen.append(b) }
        }
        return seen
    }

    /// Whether a library path reaches into Half-Life's own dir (`../valve/dlls/hl.dll`).
    public static func pointsIntoValve(_ path: String) -> Bool {
        path.lowercased().hasPrefix("../valve/")
    }

    public static func basename(ofLibrary path: String) -> String? {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        let stem = last.split(separator: ".").first.map(String.init) ?? last
        return stem.isEmpty ? nil : stem.lowercased()
    }

    static func normalisedPath(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "/")
    }

    /// Tokenises `key value` pairs: values may be quoted or bare; `//`
    /// outside quotes starts a comment. Keys are lowercased.
    static func keyValues(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = tokenize(Substring(line))
            guard tokens.count >= 2 else { continue }
            out[tokens[0].lowercased()] = tokens[1]
        }
        return out
    }

    private static func tokenize(_ line: Substring) -> [String] {
        var tokens: [String] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == " " || c == "\t" { i = line.index(after: i); continue }
            if c == "/", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "/" { break }
            if c == "\"" {
                let start = line.index(after: i)
                let end = line[start...].firstIndex(of: "\"") ?? line.endIndex
                tokens.append(String(line[start..<end]))
                i = end < line.endIndex ? line.index(after: end) : end
            } else {
                let end = line[i...].firstIndex(where: { $0 == " " || $0 == "\t" }) ?? line.endIndex
                tokens.append(String(line[i..<end]))
                i = end
            }
        }
        return tokens
    }
}
