//
//  WeaponWheelPanel.swift
//  LambdaVision
//
//  The weapon wheel's icons and labels as a RAVEHolo panel, drawn by the HEV
//  HUD's renderer over the sector wedges (the wedges themselves are weapon-
//  pass arcs, see Renderer). Each sector carries its weapon's HUD icon
//  (HUDIcon, from the warm-up) or, failing that, its name; a slot holding
//  several weapons gets a dot per weapon with the one a pick selects lit.
//  The armed sector's name reads in the middle of the wheel. Pure layout:
//  the host probe builds it too.
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

    static let amber = SIMD3<Float>(1.0, 0.56, 0.12)
    static let ink = SIMD3<Float>(0.05, 0.03, 0.01)

    /// The panel for an open wheel centred on `center`, facing along the
    /// head's `right`/`up` like the wedges. `confirm` is the armed entry's
    /// confirm-hold progress, if it needs one.
    static func panel(entries: [WeaponWheel.Entry], selected: Int, center: SIMD3<Float>,
                      right: SIMD3<Float>, up: SIMD3<Float>, font: RAVEHoloFont,
                      confirm: Float?, icon: (String) -> HUDIcon?) -> RAVEHoloPanel {
        let n = simd_normalize(simd_cross(right, up))   // toward the viewer
        let m = simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(n, 0), SIMD4(center + n * 0.004, 1))
        var p = RAVEHoloPanel(transform: m, opacity: 1, seed: 3.3)
        let count = entries.count
        guard count > 0 else { return p }
        let rMid = (innerR + outerR) / 2
        let chord = 2 * rMid * sinf(.pi / Float(count))
        for (i, e) in entries.enumerated() {
            let armed = i == selected
            let theta = WeaponWheel.sectorCenterTurns(i, count: count) * 2 * .pi
            let c = SIMD2<Float>(sinf(theta), cosf(theta)) * rMid
            let tint = armed ? ink : amber
            let fade: Float = e.dim ? 0.35 : 1
            var bottom = c.y
            let iconImage = e.iconKey.flatMap(icon)
            if let ic = iconImage {
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
        if selected >= 0, selected < count {
            let e = entries[selected]
            let pending = confirm.map { $0 < 1 } ?? false
            p.text(pending ? "HOLD" : e.label, font: font, x: 0, y: -0.003, capHeight: 0.006,
                   alignment: .center, tracking: 0.0006, color: SIMD4(amber, 1))
        }
        return p
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
