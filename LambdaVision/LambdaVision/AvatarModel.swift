//
//  AvatarModel.swift
//  LambdaVision
//
//  Which player model the first-person body wears: the game's own player
//  when there is one — Shephard in Opposing Force, Barney in Blue Shift, a
//  mod's single shipped player model — else the deathmatch Gordon every
//  install has. A candidate must build the avatar rig (a full Bip01
//  skeleton with both arm chains); one that doesn't falls through to the
//  next, so a mod's odd player model never costs the player their body.
//

import Foundation
import GameLibrary
import DebugTrace

nonisolated enum AvatarModel {
    /// Player models of the compiled-in games, by gamedir.
    static let gamePlayers: [String: String] = ["gearbox": "shephard", "bshift": "barney"]

    /// Loads the avatar into the body slot. Returns the model's name, or nil
    /// when no candidate loaded.
    static func load(for game: GameEntry, in rodir: String) -> String? {
        var candidates: [(name: String, body: Int32)] = []
        if let name = gamePlayers[game.gamedir.lowercased()] ?? singleShippedPlayer(of: game, in: rodir) {
            candidates.append((name, 0))
        }
        // Body value 1 selects Gordon's high-detail submodel over the low.
        candidates.append(("gordon", 1))
        for c in candidates {
            guard let path = GameData.resolve("models/player/\(c.name)/\(c.name).mdl", for: game, in: rodir)
            else { continue }
            guard path.withCString({ lambda_body_load($0, c.body) }) != 0 else {
                AppLog.render.log("[Avatar] \(c.name, privacy: .private) failed to load")
                continue
            }
            if c.name != "gordon" {
                do { _ = try AvatarRig() } catch {
                    AppLog.render.log("[Avatar] \(c.name, privacy: .private) can't be rigged (\(error, privacy: .public)), trying the next model")
                    continue
                }
            }
            return c.name
        }
        return nil
    }

    /// A mod's own player model when its gamedir ships exactly one
    /// (`models/player/<name>/<name>.mdl`); nil for Half-Life, or a choice.
    static func singleShippedPlayer(of game: GameEntry, in rodir: String) -> String? {
        guard game.kind != .base,
              let dir = PathResolver.shared.resolve(game.gamedir + "/models/player", in: rodir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let players = names.filter { PathResolver.shared.resolve("\($0)/\($0).mdl", in: dir) != nil }
        return players.count == 1 ? players[0] : nil
    }
}
