//
//  WeaponWheelPanel.swift
//  LambdaVision
//
//  The weapon wheel's icons and labels as a RAVEHolo panel, drawn by the HEV
//  HUD's renderer over the sector wedges (the wedges themselves are weapon-
//  pass arcs, see Renderer). Each sector carries its weapon's HUD icon
//  (HUDIcon, from the warm-up) or, failing that, its name; a slot holding
//  several weapons gets a dot per weapon with the one a pick selects lit.
//  The armed sector's name reads in the middle of the wheel. A slot opened
//  into its weapons (pushing past the rim) adds an outer arc with one icon
//  per weapon. Pure layout; `arcs(for:)` turns the same view into the
//  weapon pass's wedges, so the hand and gamepad wheels draw alike.
//

import RAVEHolo
import simd

nonisolated enum WeaponWheelPanel {
    /// Wedge radii, metres: resting, and the armed sector's (it grows).
    static let innerR: Float = 0.046
    static let outerR: Float = 0.104
    static let armedInnerR: Float = 0.042
    static let armedOuterR: Float = 0.112
    /// Gap between wedges, turns.
    static let gapTurns: Float = 0.008
    /// An opened slot's outer arc of weapons, metres (outside the armed
    /// wedge's rim, where the hand went to open it).
    static let memberInnerR: Float = 0.124
    static let memberOuterR: Float = 0.176

    static let amber = SIMD3<Float>(1.0, 0.56, 0.12)
    static let ink = SIMD3<Float>(0.05, 0.03, 0.01)

    /// The panel for an open wheel (`view`). `icon` looks up the warm-up's
    /// HUD icons.
    static func panel(view: WeaponWheel.View, font: RAVEHoloFont,
                      icon: (String) -> HUDIcon?) -> RAVEHoloPanel {
        let right = view.right, up = view.up
        let n = simd_normalize(simd_cross(right, up))   // toward the viewer
        let m = simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(n, 0), SIMD4(view.center + n * 0.004, 1))
        var p = RAVEHoloPanel(transform: m, opacity: 1, seed: 3.3)
        let entries = view.entries, selected = view.selected
        let count = entries.count
        guard count > 0 else { return p }
        let rMid = (innerR + outerR) / 2
        let chord = 2 * rMid * sinf(.pi / Float(count))
        for (i, e) in entries.enumerated() {
            let armed = i == selected
            let c = point(turns: WeaponWheel.sectorCenterTurns(i, count: count), radius: rMid)
            // An opened slot's own icon steps back: its weapons are the choice.
            let opened = view.expansion?.entry == i
            entry(e, at: c, chord: chord, armed: armed && !opened, fade: opened ? 0.5 : 1,
                  font: font, icon: icon, into: &p)
        }
        var title: String? = nil
        if let x = view.expansion, x.entry >= 0, x.entry < count {
            let members = entries[x.entry].members
            let arc = WeaponWheel.memberArc(entry: x.entry, count: count, items: members.count)
            let r = (memberInnerR + memberOuterR) / 2
            let mChord = 2 * r * sinf(.pi * arc.item)
            for (k, e) in members.enumerated() {
                let c = point(turns: arc.start + arc.item * (Float(k) + 0.5), radius: r)
                entry(e, at: c, chord: mChord, armed: k == x.selected, fade: 1, font: font, icon: icon, into: &p)
                if e.inHand {   // the weapon in hand: a bar under it
                    p.fill(x: c.x - 0.006, y: c.y - 0.019, width: 0.012, height: 0.0018,
                           color: SIMD4(k == x.selected ? ink : amber, 0.9))
                }
            }
            if x.selected >= 0, x.selected < members.count { title = members[x.selected].label }
        } else if selected >= 0, selected < count {
            let pending = view.confirm.map { $0 < 1 } ?? false
            title = pending ? "HOLD" : entries[selected].label
        }
        if let title {
            p.text(title, font: font, x: 0, y: -0.003, capHeight: 0.006,
                   alignment: .center, tracking: 0.0006, color: SIMD4(amber, 1))
        }
        return p
    }

    /// The wedges for an open wheel, in the weapon pass's arc list: one per
    /// entry (the armed one grown and lit), the confirm-hold fill outside
    /// the armed one, and an opened slot's arc of weapons.
    static func arcs(for view: WeaponWheel.View) -> [WeaponPass.Arc] {
        let n = view.entries.count
        guard n > 0 else { return [] }
        let lit = SIMD4<Float>(1.0, 0.78, 0.25, 1), rest = SIMD4<Float>(0.30, 0.31, 0.35, 1)
        func arc(_ inner: Float, _ outer: Float, _ color: SIMD4<Float>, _ start: Float, _ sweep: Float) -> WeaponPass.Arc {
            WeaponPass.Arc(center: view.center, right: view.right, up: view.up, innerR: inner, outerR: outer,
                           color: color, startTurns: start, sweepTurns: sweep)
        }
        var out: [WeaponPass.Arc] = []
        for i in 0..<n {
            let armed = i == view.selected
            out.append(arc(armed ? armedInnerR : innerR, armed ? armedOuterR : outerR, armed ? lit : rest,
                           Float(i) / Float(n) + gapTurns, 1.0 / Float(n) - 2 * gapTurns))
        }
        if let confirm = view.confirm, view.selected >= 0 {
            out.append(arc(armedOuterR + 0.003, armedOuterR + 0.008, SIMD4(0.95, 0.95, 0.95, 1),
                           Float(view.selected) / Float(n) + gapTurns, (1.0 / Float(n) - 2 * gapTurns) * confirm))
        }
        if let x = view.expansion, x.entry >= 0, x.entry < n {
            let items = view.entries[x.entry].members.count
            let a = WeaponWheel.memberArc(entry: x.entry, count: n, items: items)
            let gap = min(gapTurns, a.item * 0.1)
            for k in 0..<items {
                let armed = k == x.selected
                out.append(arc(memberInnerR - (armed ? 0.003 : 0), memberOuterR + (armed ? 0.006 : 0),
                               armed ? lit : rest, a.start + a.item * Float(k) + gap, a.item - 2 * gap))
            }
        }
        return out
    }

    /// A point on the wheel at `turns` clockwise from 12 o'clock.
    private static func point(turns: Float, radius: Float) -> SIMD2<Float> {
        let theta = turns * 2 * .pi
        return SIMD2(sinf(theta), cosf(theta)) * radius
    }

    /// One entry's icon (or name), its label for the non-weapon ones, and
    /// its pips, centred at `c`.
    private static func entry(_ e: WeaponWheel.Entry, at c: SIMD2<Float>, chord: Float, armed: Bool, fade dim: Float,
                              font: RAVEHoloFont, icon: (String) -> HUDIcon?, into p: inout RAVEHoloPanel) {
        let tint = armed ? ink : amber
        let fade: Float = (e.dim ? 0.35 : 1) * dim
        var bottom = c.y
        if let ic = e.iconKey.flatMap(icon) {
            let w = min(0.044, chord * 0.82, 0.026 * ic.aspect)
            let h = w / ic.aspect
            let labelled = !isWeapon(e.action)   // the flashlight: icon + "LIGHT"
            let cy = labelled ? c.y + 0.004 : c.y
            draw(ic, centre: SIMD2(c.x, cy), width: w, tint: tint, fade: fade, armed: armed, into: &p)
            bottom = cy - h / 2
            if labelled {
                p.text(e.label, font: font, x: c.x, y: bottom - 0.0062, capHeight: 0.0042,
                       alignment: .center, tracking: 0.0005, color: SIMD4(tint, 0.95 * fade))
                bottom -= 0.0065
            }
        } else {
            let cap: Float = e.label.count > 6 ? 0.0052 : 0.0068
            p.text(e.label, font: font, x: c.x, y: c.y - cap / 2, capHeight: cap,
                   alignment: .center, tracking: 0.0005, color: SIMD4(tint, 0.95 * fade))
            bottom = c.y - cap / 2
        }
        if e.pips > 1 {
            let d: Float = 0.0028, step: Float = 0.0052
            let x0 = c.x - step * Float(e.pips - 1) / 2
            for k in 0..<e.pips {
                p.fill(x: x0 + step * Float(k) - d / 2, y: bottom - 0.0045 - d, width: d, height: d,
                       corner: d / 2, color: SIMD4(tint, (k == e.pip ? 1 : 0.35) * fade))
            }
        }
    }

    private static func isWeapon(_ a: WeaponWheel.Action) -> Bool {
        if case .weapon = a { return true }
        return false
    }

    /// An icon's rectangles, centred at `centre`, `width` wide.
    static func draw(_ icon: HUDIcon, centre: SIMD2<Float>, width: Float, tint: SIMD3<Float>,
                     fade: Float, armed: Bool, into p: inout RAVEHoloPanel) {
        let h = width / icon.aspect
        let x0 = centre.x - width / 2, y0 = centre.y - h / 2
        let alphas: [Float] = armed ? [0.7, 0.95] : [0.5, 0.95]
        for r in icon.rects {
            p.fill(x: x0 + r.x * width, y: y0 + r.y * h, width: r.w * width, height: r.h * h,
                   color: SIMD4(tint, alphas[min(r.layer, 1)] * fade))
        }
    }
}
