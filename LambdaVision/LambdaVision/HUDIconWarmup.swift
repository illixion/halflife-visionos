//
//  HUDIconWarmup.swift
//  LambdaVision
//
//  The weapon wheel's icons, decoded before the game starts (the warm-up
//  rule: nothing derived from game assets on first sight). Every
//  `sprites/weapon_*.txt` along the game's content chain names its HUD icon
//  (the "weapon" line, 640 layout); a mod's own list wins over the one it
//  inherits from Half-Life. `hud.txt` gives the flashlight. A few dozen
//  small sprites: milliseconds, so nothing is cached across launches.
//

import Foundation
import DebugTrace
import GameLibrary

nonisolated enum HUDIconWarmup {
    static func run(gameDirectory: String, game: GameEntry) {
        let t0 = Date()
        var lists: [String: String] = [:]   // weapon_x → its .txt, first in the chain wins
        for dir in game.contentChain(root: gameDirectory) {
            guard let sprites = PathResolver.shared.resolve(dir + "/sprites", in: gameDirectory) else { continue }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: sprites)) ?? [] {
                let lower = f.lowercased()
                guard lower.hasPrefix("weapon_"), lower.hasSuffix(".txt") else { continue }
                let name = String(lower.dropLast(4))
                if lists[name] == nil { lists[name] = sprites + "/" + f }
            }
        }
        var images: [String: HUDSprite.Image] = [:]
        func image(_ sprite: String) -> HUDSprite.Image? {
            let key = sprite.lowercased()
            if let i = images[key] { return i }
            guard let path = GameData.resolve("sprites/\(sprite).spr", for: game, in: gameDirectory),
                  let data = FileManager.default.contents(atPath: path),
                  let i = HUDSprite.decode(data) else { return nil }
            images[key] = i
            return i
        }
        func icon(_ entry: HUDSprite.ListEntry?) -> HUDIcon? {
            guard let e = entry, let img = image(e.sprite) else { return nil }
            return HUDSprite.icon(from: img, x: e.x, y: e.y, width: e.width, height: e.height)
        }
        var icons: [String: HUDIcon] = [:]
        for (name, path) in lists {
            guard let text = try? String(contentsOfFile: path, encoding: .isoLatin1) else { continue }
            if let i = icon(HUDSprite.entry("weapon", in: HUDSprite.parseList(text))) { icons[name] = i }
        }
        if let path = GameData.resolve("sprites/hud.txt", for: game, in: gameDirectory),
           let text = try? String(contentsOfFile: path, encoding: .isoLatin1),
           let i = icon(HUDSprite.entry("flash_full", in: HUDSprite.parseList(text))) {
            icons[HUDIconStore.flashlightKey] = i
        }
        HUDIconStore.shared.replaceAll(icons)
        let quads = icons.values.reduce(0) { $0 + $1.rects.count }
        AppLog.render.log("[HUDIcons] \(icons.count) of \(lists.count) weapon lists, \(quads) rects, \(images.count) sprites in \(Date().timeIntervalSince(t0), format: .fixed(precision: 3)) s")
    }
}
