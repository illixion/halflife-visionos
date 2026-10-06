// Drives the app's hand-gesture logic on the Mac: WeaponWheel.swift,
// JumpSequencer.swift, ThumbGestures.swift, HUDIcon.swift and InputMode.swift
// are compiled verbatim (build.sh), so what passes here is what the app runs.
// Exits non-zero on the first failure.

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

// MARK: Opening a slot into its weapons

do {
    func member(_ name: String, empty: Bool = false, inHand: Bool = false) -> WeaponWheel.Member {
        WeaponWheel.Member(weaponID: 0, name: name, empty: empty, inHand: inHand)
    }
    var pistols = slot(1, "weapon_357", owned: 2, pick: 1)
    pistols.members = [member("weapon_9mmhandgun", inHand: true), member("weapon_357")]
    var heavy = slot(2, "weapon_shotgun", owned: 3)
    heavy.members = [member("weapon_shotgun"), member("weapon_9mmAR"), member("weapon_crossbow", empty: true)]
    var lone = slot(0, "weapon_crowbar")
    lone.members = [member("weapon_crowbar")]
    let slots = [lone, pistols, heavy, slot(3, "weapon_rpg")]   // the RPG slot publishes no members
    let e = WeaponWheel.entries(slots: slots, selectionAllowed: true, hasSuit: true, utilities: true)
    check(e.count == 7, "4 slots + 3 utilities")
    check(e[0].members.isEmpty, "a one-weapon slot has nothing to open")
    check(e[1].members.map(\.action) == [.weapon("weapon_9mmhandgun"), .weapon("weapon_357")], "pistol members in slot order")
    check(e[1].members[0].inHand && !e[1].members[1].inHand, "the weapon in hand is marked")
    check(e[2].members[2].dim, "an empty member is dim")
    check(e[3].members.isEmpty, "no published members: nothing to open")

    // Arc layout: centred on the slot, each weapon at least minMemberTurns wide.
    for (entry, items) in [(1, 2), (2, 3), (6, 5)] {
        let arc = WeaponWheel.memberArc(entry: entry, count: 7, items: items)
        let mid = arc.start + arc.item * Float(items) / 2
        check(abs(mid - WeaponWheel.sectorCenterTurns(entry, count: 7)) < 1e-5, "arc centred on slot \(entry)")
        check(arc.item >= WeaponWheel.minMemberTurns - 1e-6, "arc items wide enough")
        for k in 0..<items {
            let t = (arc.start + arc.item * (Float(k) + 0.5)) * 2 * .pi
            check(WeaponWheel.member(dx: sinf(t) * 0.15, dy: cosf(t) * 0.15, entry: entry, count: 7, items: items) == k,
                  "slot \(entry): centre of weapon \(k)")
        }
        // Overshooting the ends clamps.
        let before = (arc.start - 0.05) * 2 * .pi, after = (arc.start + arc.item * Float(items) + 0.05) * 2 * .pi
        check(WeaponWheel.member(dx: sinf(before), dy: cosf(before), entry: entry, count: 7, items: items) == 0, "clamp start")
        check(WeaponWheel.member(dx: sinf(after), dy: cosf(after), entry: entry, count: 7, items: items) == items - 1, "clamp end")
    }

    var g = WeaponWheelGesture()
    var t = WeaponWheelGesture.Tuning()
    let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
    let origin = SIMD3<Float>(0, 1.2, -0.4)
    func dir(_ turns: Float) -> SIMD3<Float> { SIMD3(sinf(turns * 2 * .pi), cosf(turns * 2 * .pi), 0) }
    func step(_ spread: Float, _ hand: SIMD3<Float>, now: Double) -> WeaponWheel.Entry? {
        g.update(live: true, spread: spread, middleCurl: 0.08, triggerHeld: false, grip: hand,
                 right: right, up: up, now: now, tuning: t, makeEntries: { e })
    }
    let heavyMid = WeaponWheel.sectorCenterTurns(2, count: 7)
    // Inner ring: release-to-pick unchanged.
    _ = step(0.03, origin, now: 0); _ = step(0.03, origin + dir(heavyMid) * 0.07, now: 0.1)
    check(g.selected == 2 && !g.expanded, "inside the rim: slot armed, not opened")
    check(step(0.10, origin + dir(heavyMid) * 0.07, now: 0.2)?.action == .weapon("weapon_shotgun"),
          "inner-ring release picks the slot's pick")
    // Past the rim: opens; the angle picks along the arc; release takes that weapon.
    _ = step(0.03, origin, now: 1); _ = step(0.03, origin + dir(heavyMid) * 0.07, now: 1.1)
    _ = step(0.03, origin + dir(heavyMid) * 0.14, now: 1.2)
    check(g.expanded && g.memberSelected == 1, "past the rim opens the slot, middle weapon armed")
    let arc = WeaponWheel.memberArc(entry: 2, count: 7, items: 3)
    _ = step(0.03, origin + dir(arc.start + arc.item * 2.5) * 0.14, now: 1.3)
    check(g.expanded && g.selected == 2 && g.memberSelected == 2, "sliding along the arc arms the last weapon")
    let v = g.view(right: right, up: up, now: 1.3)
    check(v?.expansion?.entry == 2 && v?.expansion?.selected == 2, "view carries the expansion")
    check(step(0.10, origin + dir(arc.start + arc.item * 2.5) * 0.14, now: 1.4)?.action == .weapon("weapon_crossbow"),
          "release picks exactly the armed weapon")
    // Opened, then back inside the rim: folds, and the inner ring works again.
    _ = step(0.03, origin, now: 2); _ = step(0.03, origin + dir(heavyMid) * 0.07, now: 2.1)
    _ = step(0.03, origin + dir(heavyMid) * 0.14, now: 2.2); check(g.expanded, "opened")
    _ = step(0.03, origin + dir(heavyMid) * 0.10, now: 2.3); check(g.expanded, "hysteresis: still open at 10 cm")
    _ = step(0.03, origin + dir(heavyMid) * 0.07, now: 2.4); check(!g.expanded && g.selected == 2, "folds inside the rim")
    check(step(0.10, origin + dir(heavyMid) * 0.07, now: 2.5)?.action == .weapon("weapon_shotgun"), "folded: slot pick")
    // A one-weapon slot never opens.
    let loneMid = WeaponWheel.sectorCenterTurns(0, count: 7)
    _ = step(0.03, origin, now: 3); _ = step(0.03, origin + dir(loneMid) * 0.15, now: 3.1)
    check(g.selected == 0 && !g.expanded, "one weapon: nothing opens")
    check(step(0.10, origin + dir(loneMid) * 0.15, now: 3.2)?.action == .weapon("weapon_crowbar"), "one weapon: picks it")
    // Setting off: never opens.
    t.expand = false
    _ = step(0.03, origin, now: 4); _ = step(0.03, origin + dir(heavyMid) * 0.15, now: 4.1)
    check(!g.expanded, "expand off: never opens")
    check(step(0.10, origin + dir(heavyMid) * 0.15, now: 4.2)?.action == .weapon("weapon_shotgun"), "expand off: slot pick")
    print("wheel expansion: ok")
}

// MARK: Gamepad wheel

do {
    var w = GamepadWheel()
    let entries = WeaponWheel.entries(slots: hl, selectionAllowed: true, hasSuit: true, utilities: true)
    var asked = 0
    func poll(_ held: Bool, _ x: Float, _ y: Float, now: Double, list: [WeaponWheel.Entry]? = nil) -> WeaponWheel.Entry? {
        w.update(held: held, stick: SIMD2(x, y), now: now, makeEntries: { asked += 1; return list ?? entries })
    }
    check(poll(true, 0, 0, now: 0, list: []) == nil && !w.isOpen, "no entries: stays shut")
    _ = poll(false, 0, 0, now: 0.1)
    _ = poll(true, 0, 0, now: 1); check(w.isOpen && asked == 2, "press opens, asks once per press")
    _ = poll(true, 0, 0, now: 1.05); check(asked == 2, "held: not asked again")
    _ = poll(true, 0.1, 0.2, now: 1.1); check(w.selected == -1, "inside the deadzone: nothing armed")
    _ = poll(true, 0, 1, now: 1.2); check(w.selected == 0, "stick up arms 12 o'clock")
    _ = poll(true, 0, 0, now: 1.3); check(w.selected == 0, "stick springs back: stays armed")
    check(poll(false, 0, 0, now: 1.4)?.action == .weapon("weapon_crowbar") && !w.isOpen, "release picks")
    _ = poll(true, 0, 0, now: 2)
    check(poll(false, 0, 0, now: 2.1) == nil, "release with nothing armed cancels")
    // Quick load (sector 7 of 8) needs its hold.
    let t7 = WeaponWheel.sectorCenterTurns(7, count: 8) * 2 * .pi
    _ = poll(true, 0, 0, now: 3); _ = poll(true, sinf(t7), cosf(t7), now: 3.1)
    check(w.selected == 7 && (w.confirmProgress(now: 3.1) ?? -1) == 0, "quick load armed, hold starts")
    check(poll(false, 0, 0, now: 3.2) == nil, "quick load released early does nothing")
    _ = poll(true, 0, 0, now: 4); _ = poll(true, sinf(t7), cosf(t7), now: 4.1)
    check(poll(false, 0, 0, now: 4.1 + WeaponWheel.quickLoadConfirmSeconds + 0.01)?.action == .quickLoad,
          "quick load held long enough commits")
    // Cancel while held: stays shut until pressed again.
    _ = poll(true, 0, 1, now: 5); w.cancel()
    _ = poll(true, 0, 1, now: 5.1); check(!w.isOpen, "cancelled: held button doesn't reopen")
    check(poll(false, 0, 0, now: 5.2) == nil, "cancelled: release picks nothing")
    _ = poll(true, 0, 0, now: 5.3); check(w.isOpen, "a fresh press reopens")
    print("gamepad wheel: ok")
}

// MARK: Input mode handoff

do {
    check(InputHandoff.between(nil, .gamepad) == nil, "first frame: nothing to release")
    check(InputHandoff.between(.hands, .hands) == nil, "no change: nothing")
    let toPad = InputHandoff.between(.hands, .gamepad)!
    check(toPad.releaseHands && toPad.releaseKeyboardMouse && !toPad.releaseGamepad, "hands → pad: hands and keys let go")
    check(toPad.zeroAxes && toPad.unstickKeyboardMoves, "hands → pad: axes zeroed, keyboard moves unstuck")
    let toKeys = InputHandoff.between(.gamepad, .keyboardMouse)!
    check(toKeys.releaseGamepad && toKeys.releaseHands && !toKeys.releaseKeyboardMouse, "pad → keys: pad and hands let go")
    check(toKeys.zeroAxes && !toKeys.unstickKeyboardMoves, "pad → keys: the key that switched isn't unstuck")
    let toHands = InputHandoff.between(.keyboardMouse, .hands)!
    check(toHands.releaseKeyboardMouse && toHands.releaseGamepad && !toHands.releaseHands, "keys → hands: keys and pad let go")
    check(toHands.unstickKeyboardMoves, "keys → hands: a lost key release can't keep walking")
    for c in InputHandoff.unstickCommands {
        check(c.hasPrefix("-") && !["-jump", "-duck", "-attack", "-attack2", "-use", "-speed", "-reload"].contains(c),
              "unstick never touches a button hands or the pad hold: \(c)")
    }

    var h = HeldCommands()
    check(h.update("attack", pressed: true) == "+attack", "press sends +")
    check(h.update("attack", pressed: true) == nil, "held: nothing")
    check(h.update("duck", pressed: true) == "+duck", "second button")
    check(h.releaseAll() == ["-attack", "-duck"], "handoff releases everything held, sorted")
    check(h.held.isEmpty, "nothing held after the handoff")
    check(h.update("attack", pressed: true) == nil, "still physically held: stays quiet")
    check(h.update("attack", pressed: false) == nil, "its release: quiet too")
    check(h.update("attack", pressed: true) == "+attack", "a fresh press works again")
    check(h.releaseAll() == ["-attack"] && h.releaseAll().isEmpty, "release is idempotent")
    print("input handoff: ok")
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

// MARK: Thumb gestures (reload vs alt-fire)

// A synthetic right hand in a finger gun, metres, in the hand's own frame:
// +z along the fingers, -x toward the thumb (the index sits on top in a gun
// grip), -y out of the palm (the curled fingers fold that way). Joint
// positions follow the ARKit names; the thumb tip is the only joint that
// moves between poses (and the index tip, for the fist).
struct FingerGun {
    var wrist = SIMD3<Float>(0, 0, 0)
    var idxK = SIMD3<Float>(-0.025, 0, 0.090)
    var idxTip = SIMD3<Float>(-0.025, 0, 0.175)          // extended
    var midK = SIMD3<Float>(-0.005, 0, 0.095)
    var midPIP = SIMD3<Float>(-0.005, -0.045, 0.095)     // proximal phalanx folds palmward
    var midDIP = SIMD3<Float>(-0.005, -0.045, 0.070)     // middle phalanx back toward the wrist
    var thumbTip = SIMD3<Float>(-0.080, -0.010, 0.070)   // cocked up above the index

    static let rest = SIMD3<Float>(-0.080, -0.010, 0.070)
    static let reloadCurl = SIMD3<Float>(-0.035, -0.012, 0.080)  // down onto the index base
    static let middleSide = SIMD3<Float>(-0.028, -0.042, 0.088)  // on the middle finger by the PIP

    func input(radialOffset: Float = 0.008) -> ThumbGestures.Input {
        let palm = simd_distance(midK, wrist)
        let c = ThumbContact.measure(thumbTip: thumbTip, knuckle: midK, intermediateBase: midPIP,
                                     intermediateTip: midDIP, towardIndex: idxK, radialOffset: radialOffset)
        return ThumbGestures.Input(indexExt: simd_distance(idxTip, idxK) / palm,
                                   thumbExt: simd_distance(thumbTip, idxK) / palm,
                                   contact: c.distance, along: c.along,
                                   thumbToIndexTip: simd_distance(thumbTip, idxTip))
    }
}

do {
    let dt = 1.0 / 90
    let tune = ThumbGestures.Tuning()
    // Contact geometry.
    let (d0, s0) = ThumbContact.segment(SIMD3(1, 1, 0), .zero, SIMD3(2, 0, 0))
    check(abs(d0 - 1) < 1e-5 && abs(s0 - 0.5) < 1e-5, "segment distance")
    var hand = FingerGun()
    let rest = hand.input()
    check(rest.thumbExt > tune.thumbCurlOff, "rest: thumb reads extended (\(rest.thumbExt))")
    check(rest.indexExt > tune.indexExtended, "rest: index extended (\(rest.indexExt))")
    hand.thumbTip = FingerGun.reloadCurl
    let curl = hand.input()
    check(curl.thumbExt < tune.thumbCurlOn, "reload curl reads curled (\(curl.thumbExt))")
    check(curl.along < tune.minAlong || curl.contact > tune.contactOff,
          "reload curl is off the middle finger's contact zone (d \(curl.contact) along \(curl.along))")
    hand.thumbTip = FingerGun.middleSide
    let side = hand.input()
    check(side.contact < tune.contactOn && side.along >= tune.minAlong,
          "thumb on the middle finger's side is contact (d \(side.contact) along \(side.along))")
    check(side.thumbExt < tune.thumbCurlOn, "…and also reads as a reload curl, so the veto matters")
    check(side.thumbToIndexTip > tune.pinchGuard, "…and is clear of the index tip")
    // The radial side, not the centre line: the same tip on the far (little
    // finger) side of the middle finger is farther than on the thumb side.
    let farSide = ThumbContact.measure(thumbTip: SIMD3(0.024, -0.042, 0.088), knuckle: hand.midK,
                                       intermediateBase: hand.midPIP, intermediateTip: hand.midDIP,
                                       towardIndex: hand.idxK, radialOffset: 0.008)
    check(farSide.distance > tune.contactOff, "the middle finger's far side doesn't count")

    // Drive a timeline of thumb positions; record what fired.
    struct Run { var alt = false, reload = false, maxRing: Float = 0, altFrames = 0, states: Set<String> = [] }
    func drive(_ g: inout ThumbGestures, _ frames: [ThumbGestures.Input?], t0: inout Double,
               tuning: ThumbGestures.Tuning = tune) -> Run {
        var r = Run()
        for f in frames {
            g.update(f, now: t0, tuning: tuning)
            t0 += dt
            r.alt = r.alt || g.altFire
            r.reload = r.reload || g.reload
            r.maxRing = max(r.maxRing, g.reloadRing)
            if g.altFire { r.altFrames += 1 }
            r.states.insert(g.altState.rawValue)
        }
        return r
    }
    func at(_ p: SIMD3<Float>, index: SIMD3<Float>? = nil) -> ThumbGestures.Input {
        var h = FingerGun(); h.thumbTip = p
        if let i = index { h.idxTip = i }
        return h.input()
    }
    func path(_ a: SIMD3<Float>, _ b: SIMD3<Float>, seconds: Double) -> [ThumbGestures.Input?] {
        let n = max(1, Int(seconds / dt))
        return (0...n).map { at(a + (b - a) * Float($0) / Float(n)) }
    }
    func hold(_ p: SIMD3<Float>, _ seconds: Double) -> [ThumbGestures.Input?] {
        Array(repeating: at(p), count: Int(seconds / dt))
    }

    // 1. Reload held well past its time: reload fires once, alt-fire never.
    var g = ThumbGestures(); var t = 0.0
    var r = drive(&g, hold(FingerGun.rest, 0.1) + path(FingerGun.rest, FingerGun.reloadCurl, seconds: 0.12)
                  + hold(FingerGun.reloadCurl, 1.2), t0: &t)
    check(r.reload && !r.alt, "a reload curl reloads and never alt-fires")
    // 2. Then sliding onto the middle finger without lifting the thumb: locked.
    r = drive(&g, path(FingerGun.reloadCurl, FingerGun.middleSide, seconds: 0.1) + hold(FingerGun.middleSide, 0.5), t0: &t)
    check(!r.alt && r.states.contains("locked (reload)"), "after a reload, alt-fire waits for the thumb to lift")
    // …and once the thumb lifts, contact presses it.
    r = drive(&g, path(FingerGun.middleSide, FingerGun.rest, seconds: 0.1) + hold(FingerGun.rest, 0.1), t0: &t)
    check(!g.reload && !g.altFire, "lifting the thumb releases reload")
    r = drive(&g, path(FingerGun.rest, FingerGun.middleSide, seconds: 0.12) + hold(FingerGun.middleSide, 0.3), t0: &t)
    check(r.alt && g.altFire && !r.reload, "thumb to the middle finger presses alt-fire")

    // 3. Alt-fire held longer than a reload hold: no reload, ring stays empty.
    g = ThumbGestures(); t = 0
    r = drive(&g, hold(FingerGun.rest, 0.1) + path(FingerGun.rest, FingerGun.middleSide, seconds: 0.15), t0: &t)
    let ringOnTheWay = r.maxRing
    r = drive(&g, hold(FingerGun.middleSide, 1.5), t0: &t)
    check(g.altFire && !r.reload && r.maxRing == 0, "a held alt-fire never fills the reload ring")
    check(ringOnTheWay < 0.5, "passing through the curl shows at most a flicker of ring (\(ringOnTheWay))")
    // Released by sliding back to a curl: alt-fire lets go, reload stays locked.
    r = drive(&g, path(FingerGun.middleSide, FingerGun.reloadCurl, seconds: 0.1) + hold(FingerGun.reloadCurl, 1.2), t0: &t)
    check(!g.altFire && !r.reload && g.reloadLocked, "after alt-fire, a curl doesn't reload until the thumb lifts")
    r = drive(&g, hold(FingerGun.rest, 0.1) + hold(FingerGun.reloadCurl, 1.0), t0: &t)
    check(r.reload, "after lifting, reload works again")

    // 4. Ambiguous: a reload hold that has visibly run, then contact → neither.
    g = ThumbGestures(); t = 0
    r = drive(&g, hold(FingerGun.rest, 0.1) + hold(FingerGun.reloadCurl, 0.45)
              + path(FingerGun.reloadCurl, FingerGun.middleSide, seconds: 0.05) + hold(FingerGun.middleSide, 0.8), t0: &t)
    check(!r.alt && !r.reload && r.states.contains("ambiguous"), "late slide onto the middle finger: neither")
    check(g.reloadRing == 0, "ambiguous: the ring is gone")

    // 5. Press and hold timing: a one-frame touch doesn't press; a tap does,
    //    and lasts at least minHoldSeconds.
    g = ThumbGestures(); t = 0
    r = drive(&g, hold(FingerGun.rest, 0.1) + [at(FingerGun.middleSide)] + hold(FingerGun.rest, 0.2), t0: &t)
    check(!r.alt, "a one-frame touch is noise")
    r = drive(&g, hold(FingerGun.middleSide, tune.settleSeconds + 2 * dt) + hold(FingerGun.rest, 0.3), t0: &t)
    check(r.alt && !g.altFire, "a tap presses and releases")
    check(Double(r.altFrames) * dt >= tune.minHoldSeconds - 1e-9, "a tap is held at least minHoldSeconds")

    // 6. Jitter inside the hysteresis band and a one-frame dropout keep it held.
    g = ThumbGestures(); t = 0
    _ = drive(&g, hold(FingerGun.middleSide, 0.2), t0: &t)
    check(g.altFire, "held")
    var jitter: [ThumbGestures.Input?] = []
    for i in 0..<60 {
        var f = at(FingerGun.middleSide)
        f.contact = (i % 2 == 0) ? tune.contactOn * 1.4 : tune.contactOn * 0.8
        if i == 30 { f.contact = tune.contactOff * 1.5 }     // a single bad frame
        jitter.append(f)
    }
    r = drive(&g, jitter, t0: &t)
    check(g.altFire && r.altFrames == jitter.count, "jitter and a dropout don't release (gauss charge survives)")

    // 7. Fire and alt-fire together: once held, a trigger pull keeps it.
    let curled = SIMD3<Float>(-0.025, -0.030, 0.100)   // index tip folded in
    r = drive(&g, Array(repeating: at(FingerGun.middleSide, index: curled), count: 30), t0: &t)
    check(g.altFire && !r.reload, "both buttons down while the index fires")
    // A fist (index curled first, thumb wrapped over the middle) never starts it.
    g = ThumbGestures(); t = 0
    r = drive(&g, Array(repeating: at(FingerGun.rest, index: curled), count: 10)
              + Array(repeating: at(FingerGun.middleSide, index: curled), count: 90), t0: &t)
    check(!r.alt && !r.reload && r.states.contains("index curled"), "a fist doesn't alt-fire")

    // 8. Pinch guard: thumb near the index tip (movement pinch, 🤌) never alt-fires.
    g = ThumbGestures(); t = 0
    var pinch = at(FingerGun.middleSide); pinch.thumbToIndexTip = 0.02
    r = drive(&g, Array(repeating: pinch, count: 60), t0: &t)
    check(!r.alt && r.states.contains("pinch guard"), "a pinch doesn't alt-fire")

    // 9. Lost hand / gestures off releases at once.
    g = ThumbGestures(); t = 0
    _ = drive(&g, hold(FingerGun.middleSide, 0.2), t0: &t)
    _ = drive(&g, [nil], t0: &t)
    check(!g.altFire && !g.reload, "nil input releases everything")

    // 10. Setting off: the old reload, even with the thumb on the middle finger.
    var off = tune; off.altFire = false
    g = ThumbGestures(); t = 0
    r = drive(&g, hold(FingerGun.rest, 0.1) + hold(FingerGun.middleSide, 1.0), t0: &t, tuning: off)
    check(!r.alt && r.reload && g.altState == .off, "alt-fire off: reload behaves as before")

    // 11. Sensitivity: scaling the distances down past the contact turns it off.
    var tight = tune; tight.contactOn *= 0.5; tight.contactOff *= 0.5
    g = ThumbGestures(); t = 0
    r = drive(&g, hold(FingerGun.middleSide, 0.5), t0: &t, tuning: tight)
    check(!r.alt, "low sensitivity needs firmer contact")
    print("thumb gestures: ok")
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
