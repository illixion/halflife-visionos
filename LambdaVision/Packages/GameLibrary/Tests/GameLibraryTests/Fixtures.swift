//
//  Fixtures.swift
//  GameLibraryTests
//
//  Builds fake game trees and zips on the fly — no Valve files in the repo.
//

import Foundation
import Testing
import ZIPFoundation
@testable import GameLibrary

/// A temp dir removed when the test's `Sandbox` goes away.
final class Sandbox {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gl-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    var gameData: URL { url.appendingPathComponent("GameData") }
    var staging: URL { url.appendingPathComponent("staging") }

    func path(_ rel: String) -> String { url.appendingPathComponent(rel).path }

    /// Writes files given as relative path → contents.
    func write(_ files: [String: String], under rel: String = "") throws {
        let base = rel.isEmpty ? url : url.appendingPathComponent(rel)
        for (p, text) in files {
            let f = base.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: f)
        }
    }

    func read(_ rel: String) -> String? {
        FileManager.default.contents(atPath: path(rel)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    /// Real on-disk names below a dir (case preserved), for case checks on a
    /// case-insensitive Mac volume.
    func names(_ rel: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path(rel))) ?? []).sorted()
    }

    enum ZipItem {
        case file(String, String)
        case dir(String)
        case symlink(String, target: String)
    }

    /// Writes a zip whose entries are exactly `items`, in order — including
    /// paths no well-behaved zipper would produce.
    @discardableResult
    func zip(_ name: String, _ items: [ZipItem]) throws -> URL {
        let out = url.appendingPathComponent(name)
        let archive = try Archive(url: out, accessMode: .create)
        for item in items {
            switch item {
            case .file(let p, let text):
                let data = Data(text.utf8)
                try archive.addEntry(with: p, type: .file, uncompressedSize: Int64(data.count),
                                     compressionMethod: .deflate) { pos, size in
                    data.subdata(in: Int(pos)..<Int(pos) + size)
                }
            case .dir(let p):
                try archive.addEntry(with: p.hasSuffix("/") ? p : p + "/", type: .directory,
                                     uncompressedSize: Int64(0)) { _, _ in Data() }
            case .symlink(let p, let target):
                let data = Data(target.utf8)
                try archive.addEntry(with: p, type: .symlink, uncompressedSize: Int64(data.count)) { pos, size in
                    data.subdata(in: Int(pos)..<Int(pos) + size)
                }
            }
        }
        return out
    }
}

let hlLiblist = """
// Valve Game Info file
game "Half-Life"
startmap "c0a0"
gamedll "dlls\\hl.dll"
gamedll_linux "dlls/hl.so"
gamedll_osx "dlls/hl.dylib"
type "singleplayer_only"
"""

let opforLiblist = """
game "Opposing Force"
gamedll "dlls\\opfor.dll"
gamedll_linux "dlls/opfor.so"
gamedll_osx "dlls/opfor.dylib"
startmap "of0a0"
trainmap "ofboot0"
"""

// Blue Shift really does name hl.dll for Windows and bshift elsewhere, and
// ships no dlls/ at all in the macOS depot.
let bshiftLiblist = """
// Blue Shift resource listing file
game "Blue Shift"
startmap "ba_tram1"
gamedll "dlls\\hl.dll"
gamedll_osx "dlls/bshift.dylib"
gamedll_linux "dlls/bshift.so"
type "singleplayer_only"
"""

/// A minimal valve/ (+ valve_hd/) under `rel`.
func writeValve(_ box: Sandbox, under rel: String = "GameData", hd: Bool = true) throws {
    var files = [
        "valve/liblist.gam": hlLiblist,
        "valve/dlls/hl.dll": "HL-WINDOWS-CODE",
        "valve/dlls/hl.dylib": "HL-MAC-CODE",
        "valve/steam.inf": "PatchVersion=1.1.2.2\nProductName=valve\n",
        "valve/models/v_9mmhandgun.mdl": "mdl",
    ]
    if hd { files["valve_hd/models/Hgrunt03.mdl"] = "hd" }
    try box.write(files, under: rel)
}

func collect(_ importer: GameImporter, _ source: ImportSource,
             _ options: ImportOptions = ImportOptions()) async throws -> (ImportSummary, [ImportEvent]) {
    let box = EventBox()
    let summary = try await importer.run(source, options: options) { box.append($0) }
    return (summary, box.events)
}

final class EventBox: @unchecked Sendable {
    private var list: [ImportEvent] = []
    private let lock = NSLock()
    func append(_ e: ImportEvent) { lock.lock(); list.append(e); lock.unlock() }
    var events: [ImportEvent] { lock.lock(); defer { lock.unlock() }; return list }
}
