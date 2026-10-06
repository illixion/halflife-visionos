//
//  WeaponWheel.swift
//  LambdaVision
//
//  The 🤌 weapon wheel's contents and gesture, free of Metal, ARKit and the
//  engine so the host probe (Tools/HandsProbe) runs it as is.
//
//  Sectors come from the game, not a fixed list: one per weapon slot the
//  player owns anything in, as the client publishes it (cl_dll/vr/vr_hud.cpp
//  g_vr_wheel; Opposing Force has seven slots, Half-Life five), followed by
//  the non-weapon entries — the flashlight (`impulse 100`, once the suit is
//  on), quick save and quick load. 12 o'clock is the first entry, clockwise.
//  A weapon sector names the weapon a pick selects, the same one
//  hud_fastswitch's slotN would (the next usable weapon in that slot after
//  the one in hand), and the pick sends that classname, so repeated picks of
//  one slot cycle through it and the icon always shows what you get.
//
//  The gesture: pinch all four fingertips to the thumb to open (the fist
//  gate keeps a clenched fist out), move the hand toward a sector, release
//  to pick. Releasing inside the deadzone, losing the hand or the gesture
//  going off cancels. The entries are captured when the wheel opens, so the
//  layout can't shift under the hand. A sector stays armed until the hand
//  is clearly inside a neighbour (`stickiness`), so a boundary doesn't
//  flicker. Quick load only commits after it has been armed for
//  `Entry.confirmSeconds`: a stray pick there would throw progress away.
//
//  Choosing one weapon of a slot: push the hand on past the wheel's rim
//  over a slot holding more than one weapon, and the slot opens into an
//  outer arc of its own weapons, centred on it. Sliding along the arc picks
//  one; releasing selects exactly that weapon. Coming back inside the rim
//  folds the arc and the wheel works as before, so release-to-pick on the
//  inner ring is untouched. A slot with one weapon never opens.
//
//  The gamepad's wheel (GamepadWheel) shows the same entries: hold its
//  button, point the right stick, release to pick.
//

import simd

nonisolated enum WeaponWheel {
    /// One weapon slot as the client publishes it (lambda_wheel_slot_t).
    struct Slot: Equatable, Sendable {
        var slot: Int          // 0-based
        var weaponID: Int
        var pickIndex: Int     // the pick's position among the slot's owned weapons
        var ownedCount: Int
        var holding: Bool      // the weapon in hand is in this slot
        var empty: Bool        // nothing in the slot has ammo
        var name: String       // the pick's classname, e.g. weapon_shotgun
        /// Every weapon owned in the slot, in slot order (lambda_wheel_members);
        /// empty when the client doesn't publish them.
        var members: [Member] = []
    }

    /// One weapon owned in a slot.
    struct Member: Equatable, Sendable {
        var weaponID: Int
        var name: String
        var empty: Bool        // no ammo
        var inHand: Bool
    }

    enum Action: Equatable, Sendable {
        case weapon(String)
        case flashlight
        case quickSave
        case quickLoad
    }

    struct Entry: Equatable, Sendable {
        var action: Action
        /// Upper-case text: shown when there is no icon, and under the
        /// non-weapon entries.
        var label: String
        /// HUDIconStore key, nil for text only.
        var iconKey: String?
        /// Nothing usable (a slot without ammo): drawn faint, still sent
        /// (the game answers with its empty click).
        var dim = false
        /// Weapons owned in this slot when more than one (dots under the
        /// icon), and which of them this pick selects.
        var pips = 0
        var pip = 0
        /// How long the sector must stay armed before a release commits.
        var confirmSeconds: Double = 0
        /// A weapon slot's own weapons, when it holds more than one: the arc
        /// pushing past the rim opens. Each is a plain weapon entry.
        var members: [Entry] = []
        /// The weapon in hand (marked in the opened arc).
        var inHand = false
    }

    /// How long quick load must be armed before it commits.
    nonisolated(unsafe) static var quickLoadConfirmSeconds: Double = 0.6

    /// The wheel's entries, clockwise from 12 o'clock. `selectionAllowed`
    /// mirrors the client's own rule for weapon selection (suit on, alive,
    /// weapons HUD shown); `utilities` adds the flashlight and quick
    /// save/load.
    static func entries(slots: [Slot], selectionAllowed: Bool, hasSuit: Bool,
                        utilities: Bool) -> [Entry] {
        var out: [Entry] = []
        if selectionAllowed {
            for s in slots.sorted(by: { $0.slot < $1.slot }) where !s.name.isEmpty {
                let members = s.members.filter { !$0.name.isEmpty }
                out.append(Entry(action: .weapon(s.name), label: label(forWeapon: s.name),
                                 iconKey: s.name.lowercased(), dim: s.empty,
                                 pips: s.ownedCount > 1 ? s.ownedCount : 0,
                                 pip: min(max(0, s.pickIndex), max(0, s.ownedCount - 1)),
                                 members: members.count > 1 ? members.map { m in
                                     Entry(action: .weapon(m.name), label: label(forWeapon: m.name),
                                           iconKey: m.name.lowercased(), dim: m.empty, inHand: m.inHand)
                                 } : []))
            }
        }
        if utilities {
            if hasSuit {
                out.append(Entry(action: .flashlight, label: "LIGHT", iconKey: HUDIconStore.flashlightKey))
            }
            out.append(Entry(action: .quickSave, label: "SAVE"))
            out.append(Entry(action: .quickLoad, label: "LOAD", confirmSeconds: quickLoadConfirmSeconds))
        }
        return out
    }

    /// The console command a pick sends. A weapon goes by its classname,
    /// which the engine forwards to the server's ClientCommand ("weapon_*"
    /// selects it).
    static func command(for action: Action) -> String {
        switch action {
        case .weapon(let name): name
        case .flashlight: "impulse 100"
        case .quickSave: "savequick"
        case .quickLoad: "loadquick"
        }
    }

    /// "weapon_9mmAR" → "9MMAR": the classname without its prefix, in the
    /// characters the hologram font carries.
    static func label(forWeapon name: String) -> String {
        var n = Substring(name)
        if n.lowercased().hasPrefix("weapon_") { n = n.dropFirst(7) }
        let kept = n.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return kept.isEmpty ? "?" : String(kept.prefix(10))
    }

    /// Clockwise turns from 12 o'clock to (dx right, dy up), in [0, 1).
    static func turns(dx: Float, dy: Float) -> Float {
        var a = atan2f(dx, dy) / (2 * .pi)
        if a < 0 { a += 1 }
        return a >= 1 ? 0 : a
    }

    /// The sector under a hand offset (dx right, dy up, metres) on a wheel
    /// of `count` sectors, or -1 inside the deadzone. `current` stays armed
    /// until the hand is `stickiness` (a fraction of a sector) past its
    /// edge.
    static func sector(dx: Float, dy: Float, count: Int, deadzone: Float,
                       current: Int = -1, stickiness: Float = 0.15) -> Int {
        guard count > 0, (dx * dx + dy * dy).squareRoot() > deadzone else { return -1 }
        let t = turns(dx: dx, dy: dy) * Float(count)
        if current >= 0, current < count {
            // Distance in sectors from the current sector's span, wrapping.
            var d = t - Float(current)            // 0…1 inside
            if d < -Float(count) / 2 { d += Float(count) }
            if d > Float(count) / 2 { d -= Float(count) }
            if d >= -stickiness, d <= 1 + stickiness { return current }
        }
        return min(count - 1, Int(t))
    }

    /// The angle (turns clockwise from 12 o'clock) at a sector's middle.
    static func sectorCenterTurns(_ index: Int, count: Int) -> Float {
        (Float(index) + 0.5) / Float(max(count, 1))
    }

    /// Narrowest an opened slot's weapon may be, turns: room for its icon
    /// on the outer arc.
    static let minMemberTurns: Float = 0.06

    /// An opened slot's arc of `items` weapons around sector `entry` of
    /// `count`: where the first weapon starts and how wide each is (turns,
    /// clockwise from 12 o'clock). Each weapon gets the slot's share of the
    /// wheel, or `minMemberTurns` if that's wider, so the arc may overhang
    /// the neighbours.
    static func memberArc(entry: Int, count: Int, items: Int) -> (start: Float, item: Float) {
        let n = max(items, 1)
        let item = max(1 / Float(max(count, 1)) / Float(n), minMemberTurns)
        return (sectorCenterTurns(entry, count: count) - item * Float(n) / 2, item)
    }

    /// The weapon under a hand offset on an opened slot's arc, clamped to
    /// the arc's ends (so overshooting sideways keeps the end weapon).
    static func member(dx: Float, dy: Float, entry: Int, count: Int, items: Int) -> Int {
        guard items > 0 else { return -1 }
        let arc = memberArc(entry: entry, count: count, items: items)
        let half = arc.item * Float(items) / 2
        // Offset from the arc's middle, wrapped to (-0.5, 0.5].
        var rel = turns(dx: dx, dy: dy) - (arc.start + half)
        while rel > 0.5 { rel -= 1 }
        while rel <= -0.5 { rel += 1 }
        return min(items - 1, max(0, Int(((rel + half) / arc.item).rounded(.down))))
    }

    /// The armed entry's confirm hold (0…1), or nil when it needs none.
    static func confirmProgress(_ entries: [Entry], selected: Int, armedAt: Double, now: Double) -> Float? {
        guard selected >= 0, selected < entries.count else { return nil }
        let need = entries[selected].confirmSeconds
        guard need > 0 else { return nil }
        return Float(min(1, max(0, (now - armedAt) / need)))
    }

    /// Whether releasing now commits the armed entry (quick load waits out
    /// its confirm hold).
    static func commits(_ entries: [Entry], selected: Int, armedAt: Double, now: Double) -> Entry? {
        guard selected >= 0, selected < entries.count else { return nil }
        let e = entries[selected]
        return e.confirmSeconds <= 0 || now - armedAt >= e.confirmSeconds ? e : nil
    }

    /// What an open wheel draws, whichever input drives it: placed at
    /// `center`, facing along `right`/`up`.
    struct View {
        var center: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var entries: [Entry]
        var selected: Int
        var confirm: Float?
        /// The opened slot (an index into `entries`) and the weapon armed
        /// on its arc; nil while folded.
        var expansion: (entry: Int, selected: Int)?
    }
}

/// The wheel's gesture state, run once per frame on the render thread.
nonisolated struct WeaponWheelGesture {
    struct Tuning {
        var pinchEnter: Float = 0.055   // max fingertip↔thumb spread to open, m
        var pinchExit: Float = 0.085    // spread past this releases
        var fistGate: Float = 0.05      // middle tip↔metacarpal must exceed (not a fist)
        var deadzone: Float = 0.04      // hand travel before a sector arms, m
        var stickiness: Float = 0.15    // sectors of overshoot before the armed one changes
        /// Pushing past the rim opens a multi-weapon slot. Past `expandRadius`
        /// (just outside the armed wedge, WeaponWheelPanel.armedOuterR) it
        /// opens; back inside `collapseRadius` it folds.
        var expand = true
        var expandRadius: Float = 0.118
        var collapseRadius: Float = 0.095
    }

    /// Where the wheel opened (world metres); nil while closed.
    private(set) var anchor: SIMD3<Float>?
    private(set) var entries: [WeaponWheel.Entry] = []
    private(set) var selected = -1
    /// The armed slot is opened into its weapons (only ever the armed one),
    /// and which of them is armed.
    private(set) var expanded = false
    private(set) var memberSelected = -1
    private var armedAt: Double = 0

    var isOpen: Bool { anchor != nil }

    /// How far the armed sector's confirm hold has run (0…1), or nil when
    /// the armed entry needs none.
    func confirmProgress(now: Double) -> Float? {
        WeaponWheel.confirmProgress(entries, selected: selected, armedAt: armedAt, now: now)
    }

    /// What to draw, facing along the head's `right`/`up`; nil while closed.
    func view(right: SIMD3<Float>, up: SIMD3<Float>, now: Double) -> WeaponWheel.View? {
        guard let anchor else { return nil }
        return WeaponWheel.View(center: anchor, right: right, up: up, entries: entries, selected: selected,
                                confirm: confirmProgress(now: now),
                                expansion: expanded ? (selected, memberSelected) : nil)
    }

    mutating func cancel() {
        anchor = nil
        entries = []
        selected = -1
        expanded = false
        memberSelected = -1
    }

    /// Advance one frame. `live` = the gesture may run (gestures on, hand
    /// sampled, not swinging, no menu); `spread` is the largest fingertip↔
    /// thumb-tip distance, `middleCurl` the middle tip↔metacarpal distance,
    /// `triggerHeld` whether the finger gun is firing. `grip` is the hand,
    /// `right`/`up` the head's axes (world). `makeEntries` is asked once, as
    /// the wheel opens; an empty list keeps it closed. Returns the entry a
    /// release committed.
    mutating func update(live: Bool, spread: Float, middleCurl: Float, triggerHeld: Bool,
                         grip: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                         now: Double, tuning: Tuning,
                         makeEntries: () -> [WeaponWheel.Entry]) -> WeaponWheel.Entry? {
        guard live else {
            if isOpen { cancel() }
            return nil
        }
        guard let a = anchor else {
            if spread < tuning.pinchEnter, middleCurl > tuning.fistGate, !triggerHeld {
                let e = makeEntries()
                if !e.isEmpty {
                    anchor = grip
                    entries = e
                    selected = -1
                }
            }
            return nil
        }
        if spread > tuning.pinchExit {
            var picked = WeaponWheel.commits(entries, selected: selected, armedAt: armedAt, now: now)
            if expanded, let p = picked, memberSelected >= 0, memberSelected < p.members.count {
                picked = p.members[memberSelected]
            }
            cancel()
            return picked
        }
        let d = grip - a
        let dx = simd_dot(d, right), dy = simd_dot(d, up)
        let r = (dx * dx + dy * dy).squareRoot()
        // Opened: the angle picks along the slot's arc until the hand comes
        // back inside the rim; the armed slot can't change meanwhile.
        if expanded {
            if tuning.expand, r >= tuning.collapseRadius {
                memberSelected = WeaponWheel.member(dx: dx, dy: dy, entry: selected, count: entries.count,
                                                    items: entries[selected].members.count)
                return nil
            }
            expanded = false
            memberSelected = -1
        }
        let s = WeaponWheel.sector(dx: dx, dy: dy,
                                   count: entries.count, deadzone: tuning.deadzone,
                                   current: selected, stickiness: tuning.stickiness)
        if s != selected {
            selected = s
            armedAt = now
        }
        if tuning.expand, s >= 0, entries[s].members.count > 1, r > tuning.expandRadius {
            expanded = true
            memberSelected = WeaponWheel.member(dx: dx, dy: dy, entry: s, count: entries.count,
                                                items: entries[s].members.count)
        }
        return nil
    }
}

/// The gamepad's radial weapon menu, the same entries as the hand wheel:
/// hold the wheel button to open it, point the right stick at a sector,
/// release the button to pick. The sector stays armed when the stick springs
/// back to the middle, so flick-and-release works; releasing with nothing
/// armed cancels. Quick load keeps its confirm hold. Drawn view-pinned in
/// front of the player (Renderer), since a gamepad has no hand to anchor to.
nonisolated struct GamepadWheel {
    struct Tuning {
        var deadzone: Float = 0.5       // stick deflection before a sector arms
        var stickiness: Float = 0.15
    }

    private(set) var isOpen = false
    private(set) var entries: [WeaponWheel.Entry] = []
    private(set) var selected = -1
    private var armedAt: Double = 0
    private var held = false

    func confirmProgress(now: Double) -> Float? {
        WeaponWheel.confirmProgress(entries, selected: selected, armedAt: armedAt, now: now)
    }

    func view(center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, now: Double) -> WeaponWheel.View? {
        guard isOpen else { return nil }
        return WeaponWheel.View(center: center, right: right, up: up, entries: entries, selected: selected,
                                confirm: confirmProgress(now: now), expansion: nil)
    }

    /// Close without picking. A button still held stays closed until it is
    /// pressed again.
    mutating func cancel() {
        isOpen = false
        entries = []
        selected = -1
    }

    /// Advance one poll. `held` is the wheel button (false while the menu or
    /// console is up), `stick` the right stick (x right, y up, ±1).
    /// `makeEntries` is asked once per press. Returns the entry a release
    /// committed.
    mutating func update(held: Bool, stick: SIMD2<Float>, now: Double, tuning: Tuning = Tuning(),
                         makeEntries: () -> [WeaponWheel.Entry]) -> WeaponWheel.Entry? {
        let wasHeld = self.held
        self.held = held
        if held, !wasHeld {
            let e = makeEntries()
            if !e.isEmpty {
                isOpen = true
                entries = e
                selected = -1
                armedAt = now
            }
            return nil
        }
        guard isOpen else { return nil }
        if !held {
            let picked = WeaponWheel.commits(entries, selected: selected, armedAt: armedAt, now: now)
            cancel()
            return picked
        }
        if simd_length(stick) > tuning.deadzone {
            let s = WeaponWheel.sector(dx: stick.x, dy: stick.y, count: entries.count,
                                       deadzone: tuning.deadzone, current: selected,
                                       stickiness: tuning.stickiness)
            if s != selected {
                selected = s
                armedAt = now
            }
        }
        return nil
    }
}
