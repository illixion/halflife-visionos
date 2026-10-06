// Drives the app's hand-gesture logic on the Mac: WeaponWheel.swift,
// JumpSequencer.swift and HUDIcon.swift are compiled verbatim (build.sh), so
// what passes here is what the app runs. Exits non-zero on the first failure.

import Foundation
import simd

func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
func check(_ ok: Bool, _ m: @autoclosure () -> String) { if !ok { die(m()) } }

let assets = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? ""
let ascii = CommandLine.arguments.contains("--ascii")

// MARK: Wheel layout

func slot(_ s: Int, _ name: String, owned: Int = 1, pick: Int = 0, empty: Bool = false) -> WeaponWheel.Slot {
    WeaponWheel.Slot(slot: s, weaponID: s + 1, pickIndex: pick, ownedCount: owned,
                     holding: false, empty: empty, name: name)
}
let hl = [slot(0, "weapon_crowbar"), slot(1, "weapon_9mmhandgun", owned: 2, pick: 1),
          slot(2, "weapon_shotgun", owned: 3), slot(3, "weapon_rpg"), slot(4, "weapon_handgrenade", empty: true)]
do {
    let e = WeaponWheel.entries(slots: hl, selectionAllowed: true, hasSuit: true, utilities: true)
    check(e.count == 8, "HL arsenal + 3 utilities = 8 sectors, got \(e.count)")
    check(e[0].action == .weapon("weapon_crowbar"), "12 o'clock is the lowest slot")
    check(e[1].pips == 2 && e[1].pip == 1, "a two-weapon slot shows 2 pips, the pick lit")
    check(e[0].pips == 0, "a one-weapon slot shows no pips")
    check(e[4].dim, "a slot with no ammo is dim")
    check(e[5].action == .flashlight && e[6].action == .quickSave && e[7].action == .quickLoad,
          "utilities follow the weapons: light, save, load")
    check(e[7].confirmSeconds > 0 && e[6].confirmSeconds == 0, "only quick load needs a confirm hold")
    check(e[2].iconKey == "weapon_shotgun" && e[5].iconKey == HUDIconStore.flashlightKey, "icon keys")

    // Opposing Force: seven slots, out of order on input.
    let of = (0..<7).reversed().map { slot($0, "weapon_of\($0)") }
    let o = WeaponWheel.entries(slots: of, selectionAllowed: true, hasSuit: true, utilities: true)
    check(o.count == 10, "OF's 7 slots + 3 = 10, got \(o.count)")
    check(o.prefix(7).map { $0.action } == (0..<7).map { .weapon("weapon_of\($0)") }, "sorted by slot")

    let noSuit = WeaponWheel.entries(slots: [], selectionAllowed: false, hasSuit: false, utilities: true)
    check(noSuit.map { $0.action } == [.quickSave, .quickLoad], "before the suit: save and load only")
    check(WeaponWheel.entries(slots: hl, selectionAllowed: false, hasSuit: true, utilities: false).isEmpty,
          "selection off and no utilities: nothing (the wheel stays shut)")
    check(WeaponWheel.entries(slots: hl, selectionAllowed: true, hasSuit: true, utilities: false).count == 5,
          "utilities off: weapons only")

    check(WeaponWheel.command(for: .weapon("weapon_9mmAR")) == "weapon_9mmAR", "weapon command is its classname")
    check(WeaponWheel.command(for: .flashlight) == "impulse 100", "flashlight = impulse 100")
    check(WeaponWheel.command(for: .quickSave) == "savequick", "quick save")
    check(WeaponWheel.command(for: .quickLoad) == "loadquick", "quick load")
    check(WeaponWheel.label(forWeapon: "weapon_9mmAR") == "9MMAR", "label")
    check(WeaponWheel.label(forWeapon: "weapon_") == "?", "empty label")
    print("wheel layout: ok")
}

// MARK: Sector picking

do {
    let dz: Float = 0.04
    let r: Float = 0.08
    func at(_ turns: Float) -> (Float, Float) { (r * sinf(turns * 2 * .pi), r * cosf(turns * 2 * .pi)) }
    for n in [3, 5, 8, 10, 12] {
        for i in 0..<n {
            let (x, y) = at(WeaponWheel.sectorCenterTurns(i, count: n))
            check(WeaponWheel.sector(dx: x, dy: y, count: n, deadzone: dz) == i, "n=\(n) centre of \(i)")
        }
    }
    check(WeaponWheel.sector(dx: 0.01, dy: 0.02, count: 8, deadzone: dz) == -1, "inside the deadzone")
    check(WeaponWheel.sector(dx: 0, dy: 0.08, count: 8, deadzone: dz) == 0, "12 o'clock")
    check(WeaponWheel.sector(dx: 0.08, dy: 0, count: 8, deadzone: dz) == 2, "3 o'clock on 8 = sector 2")
    check(WeaponWheel.sector(dx: -0.08, dy: 0.0001, count: 8, deadzone: dz) == 5 || WeaponWheel.sector(dx: -0.08, dy: 0.0001, count: 8, deadzone: dz) == 6, "9 o'clock")
    // Stickiness: just past sector 1's far edge (0.25 turns on 8) stays 1,
    // well past goes to 2.
    var (x, y) = at(0.25 + 0.01)
    check(WeaponWheel.sector(dx: x, dy: y, count: 8, deadzone: dz) == 2, "fresh: past the edge is 2")
    check(WeaponWheel.sector(dx: x, dy: y, count: 8, deadzone: dz, current: 1) == 1, "sticky: stays 1")
    (x, y) = at(0.25 + 0.03)
    check(WeaponWheel.sector(dx: x, dy: y, count: 8, deadzone: dz, current: 1) == 2, "clearly into 2")
    // Wrap: last sector stays armed just past 12 o'clock.
    (x, y) = at(0.005)
    check(WeaponWheel.sector(dx: x, dy: y, count: 8, deadzone: dz, current: 7) == 7, "sticky across 12 o'clock")
    check(WeaponWheel.sector(dx: x, dy: y, count: 8, deadzone: dz) == 0, "fresh across 12 o'clock")
    print("sector picking: ok")
}

// MARK: Wheel gesture

do {
    var g = WeaponWheelGesture()
    let t = WeaponWheelGesture.Tuning()
    let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
    let origin = SIMD3<Float>(0.2, 1.2, -0.4)
    let entries = WeaponWheel.entries(slots: hl, selectionAllowed: true, hasSuit: true, utilities: true)
    var asked = 0
    func step(_ spread: Float, _ hand: SIMD3<Float>, now: Double, live: Bool = true, trigger: Bool = false,
              curl: Float = 0.08, list: [WeaponWheel.Entry]? = nil) -> WeaponWheel.Entry? {
        g.update(live: live, spread: spread, middleCurl: curl, triggerHeld: trigger, grip: hand,
                 right: right, up: up, now: now, tuning: t, makeEntries: { asked += 1; return list ?? entries })
    }
    // Trigger held or a fist: no open.
    _ = step(0.03, origin, now: 0, trigger: true); check(!g.isOpen, "trigger held keeps it shut")
    _ = step(0.03, origin, now: 0, curl: 0.03); check(!g.isOpen, "a fist keeps it shut")
    _ = step(0.03, origin, now: 0, list: []); check(!g.isOpen, "no entries keeps it shut")
    asked = 0
    _ = step(0.03, origin, now: 0); check(g.isOpen && asked == 1, "opens on the pinch, asks once")
    _ = step(0.07, origin, now: 0.02); check(g.isOpen && asked == 1, "inside the hysteresis band: still open")
    // Move up: sector 0 (crowbar). Release commits it.
    _ = step(0.03, origin + up * 0.06, now: 0.1)
    check(g.selected == 0, "moved up arms sector 0")
    let picked = step(0.10, origin + up * 0.06, now: 0.2)
    check(picked?.action == .weapon("weapon_crowbar") && !g.isOpen, "release picks crowbar and closes")
    // Release inside the deadzone: cancel.
    _ = step(0.03, origin, now: 1)
    check(step(0.10, origin + right * 0.01, now: 1.1) == nil && !g.isOpen, "release in the deadzone cancels")
    // Lost hand cancels.
    _ = step(0.03, origin, now: 2); _ = step(0.03, origin + up * 0.06, now: 2.1)
    check(step(1, .zero, now: 2.2, live: false) == nil && !g.isOpen, "lost hand cancels")
    // Quick load (last sector, just left of 12 o'clock): needs the hold.
    let loadDir = SIMD3<Float>(sinf(WeaponWheel.sectorCenterTurns(7, count: 8) * 2 * .pi),
                               cosf(WeaponWheel.sectorCenterTurns(7, count: 8) * 2 * .pi), 0)
    _ = step(0.03, origin, now: 3); _ = step(0.03, origin + loadDir * 0.07, now: 3.1)
    check(g.selected == 7, "armed quick load")
    check((g.confirmProgress(now: 3.1 + WeaponWheel.quickLoadConfirmSeconds / 2) ?? 0) > 0.4, "confirm progress")
    check(step(0.10, origin + loadDir * 0.07, now: 3.2) == nil, "quick load released early does nothing")
    _ = step(0.03, origin, now: 4); _ = step(0.03, origin + loadDir * 0.07, now: 4.1)
    let load = step(0.10, origin + loadDir * 0.07, now: 4.1 + WeaponWheel.quickLoadConfirmSeconds + 0.01)
    check(load?.action == .quickLoad, "quick load held armed long enough commits")
    // Entries are a snapshot: a different list mid-gesture changes nothing.
    _ = step(0.03, origin, now: 5)
    _ = step(0.03, origin + up * 0.06, now: 5.1, list: [])
    check(g.entries.count == entries.count, "entries captured at open")
    print("wheel gesture: ok")
}

// MARK: Long jump timing

do {
    var tune = JumpSequencer.Tuning()
    func run(intent: Float, speed: Float, module: Bool, holdFor: Double, tuning: JumpSequencer.Tuning = tune)
        -> [(t: Double, jump: Bool, duck: Bool)] {
        var s = JumpSequencer()
        var out: [(Double, Bool, Bool)] = []
        var t = 0.0
        while t < 0.5 {
            let b = s.update(jump: t < holdFor, intent: intent, groundSpeed: speed, hasModule: module,
                             now: t, tuning: tuning)
            out.append((t, b.jump, b.duck))
            t += 1.0 / 90
        }
        return out
    }
    func firstTime(_ f: [(t: Double, jump: Bool, duck: Bool)], _ k: KeyPath<(t: Double, jump: Bool, duck: Bool), Bool>) -> Double? {
        f.first { $0[keyPath: k] }?.t
    }
    // Crouch-jump: jump first, duck ~0.06 s later.
    var f = run(intent: 1, speed: 320, module: false, holdFor: 0.3)
    check(firstTime(f, \.jump) == 0, "crouch-jump: jump at once")
    check(abs((firstTime(f, \.duck) ?? 9) - 0.0667) < 0.012, "crouch-jump: duck after the delay")
    check(!(f.last!.jump || f.last!.duck), "crouch-jump releases with the gesture")
    // Long jump: duck first, jump duckLead later with the duck still down.
    f = run(intent: 1, speed: 320, module: true, holdFor: 0.3)
    check(firstTime(f, \.duck) == 0, "long jump: duck at once")
    let lj = firstTime(f, \.jump) ?? 9
    check(lj >= tune.duckLead && lj < tune.duckLead + 0.012, "long jump: jump after the lead (\(lj))")
    check(f.allSatisfy { !$0.jump || $0.duck }, "long jump: duck held whenever jump is")
    check(!(f.last!.jump || f.last!.duck), "long jump releases after the gesture")
    // A quick flick (0.03 s) still launches and holds the jump minJumpHold.
    f = run(intent: 1, speed: 320, module: true, holdFor: 0.03)
    let jumpFrames = f.filter { $0.jump }
    check(!jumpFrames.isEmpty, "a quick flick still long-jumps")
    check((jumpFrames.last!.t - jumpFrames.first!.t) >= tune.minJumpHold - 0.012, "jump held its minimum")
    // Each gate falls back to the crouch-jump.
    for (name, i, s, m) in [("no module", Float(1), Float(320), false), ("walking stick", 0.6, 320, true),
                            ("standing still", 1, 40, true)] {
        f = run(intent: i, speed: s, module: m, holdFor: 0.3)
        check(firstTime(f, \.jump) == 0, "\(name): plain crouch-jump")
    }
    tune.longJump = false
    f = run(intent: 1, speed: 320, module: true, holdFor: 0.3, tuning: tune)
    check(firstTime(f, \.jump) == 0, "setting off: crouch-jump")
    tune.longJump = true
    tune.autoCrouchJump = false
    f = run(intent: 0.2, speed: 320, module: true, holdFor: 0.3, tuning: tune)
    check(firstTime(f, \.duck) == nil, "auto crouch off: plain jump")
    // The choice is latched at the start.
    var s = JumpSequencer()
    _ = s.update(jump: true, intent: 1, groundSpeed: 320, hasModule: true, now: 0, tuning: JumpSequencer.Tuning())
    _ = s.update(jump: true, intent: 0, groundSpeed: 0, hasModule: false, now: 0.05, tuning: JumpSequencer.Tuning())
    check(s.kind == .longJump, "latched at the start")
    print("long jump timing: ok")
}

// MARK: HUD icons from the real sprites

func findCI(_ dir: String, _ name: String) -> String? {
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return items.first { $0.lowercased() == name.lowercased() }.map { dir + "/" + $0 }
}
func resolve(_ rel: String, chain: [String]) -> String? {
    for d in chain {
        var p = d
        var ok = true
        for comp in rel.split(separator: "/") {
            guard let n = findCI(p, String(comp)) else { ok = false; break }
            p = n
        }
        if ok { return p }
    }
    return nil
}

if FileManager.default.fileExists(atPath: assets + "/valve/sprites") {
    let rectBudget = 260
    var worst = 0
    for game in ["valve", "gearbox", "bshift"] {
        let chain = [game, "valve"].map { assets + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        guard chain.count == 2 || game == "valve" else { continue }
        var lists: [String: String] = [:]
        for d in chain {
            guard let sp = findCI(d, "sprites") else { continue }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: sp)) ?? []
            where f.lowercased().hasPrefix("weapon_") && f.lowercased().hasSuffix(".txt") {
                let k = String(f.lowercased().dropLast(4))
                if lists[k] == nil { lists[k] = sp + "/" + f }
            }
        }
        var total = 0
        var line: [String] = []
        for (name, path) in lists.sorted(by: { $0.key < $1.key }) {
            let text = (try? String(contentsOfFile: path, encoding: .isoLatin1)) ?? ""
            guard let e = HUDSprite.entry("weapon", in: HUDSprite.parseList(text)) else {
                if name == "weapon_question" { continue }   // a placeholder list, no "weapon" line needed
                die("\(game)/\(name): no weapon line")
            }
            guard let sprPath = resolve("sprites/\(e.sprite).spr", chain: chain),
                  let data = FileManager.default.contents(atPath: sprPath),
                  let img = HUDSprite.decode(data) else { die("\(game)/\(name): can't decode \(e.sprite)") }
            guard let icon = HUDSprite.icon(from: img, x: e.x, y: e.y, width: e.width, height: e.height) else {
                die("\(game)/\(name): icon has nothing lit")
            }
            check(e.resolution == 640, "\(game)/\(name): picked the 640 layout")
            check(icon.rects.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.w <= 1.0001 && $0.y + $0.h <= 1.0001 },
                  "\(game)/\(name): rects inside the unit square")
            check(icon.rects.count <= rectBudget, "\(game)/\(name): \(icon.rects.count) rects > \(rectBudget)")
            worst = max(worst, icon.rects.count)
            total += icon.rects.count
            line.append("\(name.dropFirst(7)) \(icon.rects.count)")
            if ascii && game == "valve" {
                // Redraw the rects on a text grid.
                let cols = 60, rows = Int(Float(cols) / icon.aspect / 2 + 0.5)
                var grid = [[Character]](repeating: [Character](repeating: " ", count: cols), count: rows)
                for r in icon.rects {
                    let c: Character = r.layer == 0 ? "." : "#"
                    for yy in Int(((1 - r.y - r.h) * Float(rows)).rounded())..<Int(((1 - r.y) * Float(rows)).rounded()) {
                        for xx in Int((r.x * Float(cols)).rounded())..<Int(((r.x + r.w) * Float(cols)).rounded())
                        where yy >= 0 && yy < rows && xx >= 0 && xx < cols {
                            if c == "#" || grid[yy][xx] == " " { grid[yy][xx] = c }
                        }
                    }
                }
                print("--- \(name)")
                for row in grid { print(String(row)) }
            }
        }
        print("\(game): \(line.count) icons, \(total) rects  [\(line.joined(separator: ", "))]")
        if let hud = resolve("sprites/hud.txt", chain: chain),
           let e = HUDSprite.entry("flash_full", in: HUDSprite.parseList((try? String(contentsOfFile: hud, encoding: .isoLatin1)) ?? "")),
           let spr = resolve("sprites/\(e.sprite).spr", chain: chain),
           let img = HUDSprite.decode(FileManager.default.contents(atPath: spr) ?? Data()),
           let icon = HUDSprite.icon(from: img, x: e.x, y: e.y, width: e.width, height: e.height) {
            print("\(game): flashlight icon \(icon.rects.count) rects")
        } else {
            die("\(game): no flashlight icon")
        }
    }
    // A full wheel of the worst icons, plus labels, must fit RAVEHolo's
    // 4096-quad scene beside the HEV HUD (a few hundred).
    check(worst * 12 + 400 < 4096, "12 worst-case icons (\(worst) rects) overflow the HUD's quad budget")
    print("hud icons: ok (worst \(worst) rects)")
} else {
    print("hud icons: skipped (no game files at \(assets))")
}
print("all checks passed")
