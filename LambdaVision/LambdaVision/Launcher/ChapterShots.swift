//
//  ChapterShots.swift
//  LambdaVision
//
//  Where each chapter's picture is taken. The player marks a spot in the
//  game (weapon wheel, Developer mode) and the engine renders the pictures
//  from those spots (ChapterPictureRunner). A spot is numbers only (map,
//  camera position, view angles), so the list can live in the repo; the
//  pictures are made on the player's own device from their own game and
//  never shipped.
//
//  The list is the bundle's `ChapterShots.json` with the player's own
//  `Application Support/LambdaVision/ChapterShots.json` on top (a spot in
//  the second file replaces the one for the same chapter).
//

import Foundation
import SwiftUI
import GameLibrary

struct ChapterShot: Codable, Equatable, Sendable, Identifiable {
    var game: String
    var map: String
    /// Camera position, engine units (x, y, z).
    var origin: [Float]
    /// Pitch (down is positive), yaw, roll, degrees. Roll is kept at 0.
    var angles: [Float]
    var note: String?

    var id: String { "\(game.lowercased())/\(map.lowercased())" }
    var isValid: Bool { origin.count == 3 && angles.count == 3 && !map.isEmpty && !game.isEmpty }
}

struct ChapterShotFile: Codable, Sendable {
    var format = "lambdavision.chaptershots"
    var version = 1
    var shots: [ChapterShot]
}

@MainActor
@Observable
final class ChapterShotStore {
    static let shared = ChapterShotStore()

    private(set) var shots: [ChapterShot] = []
    /// What the last mark said, for the launcher.
    private(set) var lastMessage: String?

    init() { reload() }

    static var localURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("LambdaVision/ChapterShots.json")
    }

    func shot(game: String, map: String) -> ChapterShot? {
        let key = "\(game.lowercased())/\(map.lowercased())"
        return shots.first { $0.id == key }
    }

    func reload() {
        var byID: [String: ChapterShot] = [:]
        var order: [String] = []
        func add(_ list: [ChapterShot]) {
            for s in list where s.isValid {
                if byID[s.id] == nil { order.append(s.id) }
                byID[s.id] = s
            }
        }
        if let url = Bundle.main.url(forResource: "ChapterShots", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(ChapterShotFile.self, from: data) {
            add(file.shots)
        }
        if let url = Self.localURL, let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(ChapterShotFile.self, from: data) {
            add(file.shots)
        }
        shots = order.compactMap { byID[$0] }
    }

    /// The player's own spots, as the file the app keeps (and what
    /// `Launcher/ChapterShots.json` in the repo holds, once chosen).
    func exportJSON() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(ChapterShotFile(shots: shots))) ?? Data()
    }

    func set(_ shot: ChapterShot) {
        guard shot.isValid else { return }
        if let i = shots.firstIndex(where: { $0.id == shot.id }) { shots[i] = shot } else { shots.append(shot) }
        saveLocal()
    }

    func remove(_ id: String) {
        shots.removeAll { $0.id == id }
        saveLocal()
    }

    /// Everything the player marked goes to the local file; the bundled list
    /// stays as shipped.
    private func saveLocal() {
        guard let url = Self.localURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? exportJSON().write(to: url, options: .atomic)
    }

    /// Marks the engine's current camera as this chapter's picture spot.
    /// Returns nil, with `lastMessage` saying why, when the game isn't in a map.
    @discardableResult
    func markHere() -> ChapterShot? {
        guard let game = GameData.runningGame?.gamedir, let map = GameStatus.currentMap() else {
            lastMessage = "Not in a map"
            return nil
        }
        var origin: [Float] = [0, 0, 0]
        var angles: [Float] = [0, 0, 0]
        guard lambda_debug_view(&origin, &angles) != 0 else {
            lastMessage = "The engine isn't up"
            return nil
        }
        // Roll is the head's tilt: a picture stands upright.
        let shot = ChapterShot(game: game.lowercased(), map: map.lowercased(),
                               origin: origin.map { (Float($0) * 10).rounded() / 10 },
                               angles: [(angles[0] * 10).rounded() / 10, (angles[1] * 10).rounded() / 10, 0])
        set(shot)
        lastMessage = "Marked \(map)"
        return shot
    }
}

/// The pictures the engine made, on this device.
@MainActor
@Observable
final class ChapterPictures {
    static let shared = ChapterPictures()

    /// Bumped when a picture is written, so the cards redraw.
    private(set) var version = 0

    static var directory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("LambdaVision/Chapter Pictures", isDirectory: true)
    }

    nonisolated static func fileURL(gamedir: String, map: String) -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
        else { return nil }
        return dir.appendingPathComponent("LambdaVision/Chapter Pictures/\(gamedir.lowercased())-\(map.lowercased()).jpg")
    }

    /// The picture for a chapter, if one was made.
    static func existing(gamedir: String, map: String) -> URL? {
        guard let url = fileURL(gamedir: gamedir, map: map),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func write(_ jpeg: Data, gamedir: String, map: String) -> Bool {
        guard let dir = Self.directory, let url = Self.fileURL(gamedir: gamedir, map: map) else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpeg.write(to: url, options: .atomic)
        } catch { return false }
        version += 1
        return true
    }
}
