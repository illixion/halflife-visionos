//
//  AvatarModel.swift
//  LambdaVision
//
//  Which player model the first-person body wears: the game's own player
//  when there is one — Shephard in Opposing Force, Barney in Blue Shift, a
//  mod's single shipped player model — else the deathmatch Gordon every
//  install has. Gordon wears his lab coat until he has the HEV suit, when Blue
//  Shift is installed to lend it. A candidate must build the avatar rig (a
//  full Bip01 skeleton with both arm chains); one that doesn't falls through
//  to the next, so a mod's odd player model never costs the player their body.
//

import Foundation
import GameLibrary
import DebugTrace

nonisolated enum AvatarModel {
    /// Player models of the compiled-in games, by gamedir.
    static let gamePlayers: [String: String] = ["gearbox": "shephard", "bshift": "barney"]

    /// Loads the avatar into the body slot. `suit`: whether the player has the
    /// HEV suit, which decides Gordon's clothes. Returns the model's name, or
    /// nil when no candidate loaded.
    static func load(for game: GameEntry, in rodir: String, suit: Bool) -> String? {
        var candidates: [(name: String, path: String?, body: Int32)] = []
        let own = ownPlayer(of: game, in: rodir)
        if let own {
            candidates.append((own, GameData.resolve("models/player/\(own)/\(own).mdl", for: game, in: rodir), 0))
        }
        if own == nil, !suit, let coat = labCoat(in: rodir) {
            candidates.append(("gordon_scientist", coat, 0))
        }
        // Body value 1 selects Gordon's high-detail submodel over the low.
        candidates.append(("gordon", GameData.resolve("models/player/gordon/gordon.mdl", for: game, in: rodir), 1))
        for c in candidates {
            guard let path = c.path else { continue }
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

    /// Whether the body changes when the player gets the suit: the player is
    /// Gordon and the lab coat is installed.
    static func followsSuit(for game: GameEntry, in rodir: String) -> Bool {
        ownPlayer(of: game, in: rodir) == nil && labCoat(in: rodir) != nil
    }

    /// Gordon in his lab coat: Blue Shift's NPC of its crossover scenes
    /// (`models/gordon_scientist.mdl`, a 3ds Max Biped rig, see
    /// `AvatarRig.canonicalBoneName`), from its HD pack when installed, as the
    /// content chain prefers.
    static func labCoat(in rodir: String) -> String? {
        PathResolver.shared.firstMatch("models/gordon_scientist.mdl",
                                       in: ["bshift_hd", "bshift"].map { rodir + "/" + $0 })
    }

    /// The game's own player model, nil when the player is Gordon.
    private static func ownPlayer(of game: GameEntry, in rodir: String) -> String? {
        gamePlayers[game.gamedir.lowercased()] ?? singleShippedPlayer(of: game, in: rodir)
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
