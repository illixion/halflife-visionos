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
                out.append(Entry(action: .weapon(s.name), label: label(forWeapon: s.name),
                                 iconKey: s.name.lowercased(), dim: s.empty,
                                 pips: s.ownedCount > 1 ? s.ownedCount : 0,
                                 pip: min(max(0, s.pickIndex), max(0, s.ownedCount - 1))))
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
}

/// The wheel's gesture state, run once per frame on the render thread.
nonisolated struct WeaponWheelGesture {
    struct Tuning {
        var pinchEnter: Float = 0.055   // max fingertip↔thumb spread to open, m
        var pinchExit: Float = 0.085    // spread past this releases
        var fistGate: Float = 0.05      // middle tip↔metacarpal must exceed (not a fist)
        var deadzone: Float = 0.04      // hand travel before a sector arms, m
        var stickiness: Float = 0.15    // sectors of overshoot before the armed one changes
    }

    /// Where the wheel opened (world metres); nil while closed.
    private(set) var anchor: SIMD3<Float>?
    private(set) var entries: [WeaponWheel.Entry] = []
    private(set) var selected = -1
    private var armedAt: Double = 0

    var isOpen: Bool { anchor != nil }

    /// How far the armed sector's confirm hold has run (0…1), or nil when
    /// the armed entry needs none.
    func confirmProgress(now: Double) -> Float? {
        guard selected >= 0, selected < entries.count else { return nil }
        let need = entries[selected].confirmSeconds
        guard need > 0 else { return nil }
        return Float(min(1, max(0, (now - armedAt) / need)))
    }

    mutating func cancel() {
        anchor = nil
        entries = []
        selected = -1
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
            var picked: WeaponWheel.Entry? = nil
            if selected >= 0, selected < entries.count {
                let e = entries[selected]
                if e.confirmSeconds <= 0 || now - armedAt >= e.confirmSeconds { picked = e }
            }
            cancel()
            return picked
        }
        let d = grip - a
        let s = WeaponWheel.sector(dx: simd_dot(d, right), dy: simd_dot(d, up),
                                   count: entries.count, deadzone: tuning.deadzone,
                                   current: selected, stickiness: tuning.stickiness)
        if s != selected {
            selected = s
            armedAt = now
        }
        return nil
    }
}
