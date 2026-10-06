//
//  ThumbGestures.swift
//  LambdaVision
//
//  The gun hand's two thumb gestures, free of ARKit and the engine so the
//  host probe (Tools/HandsProbe) runs it as is:
//
//  • Reload: curl the thumb down (thumb tip↔index knuckle over palm length
//    below `thumbCurlOn`) with the index extended, and hold for
//    `reloadHoldSeconds` while a ring fills. Unchanged from before; it only
//    moved here so it can be checked against alt-fire.
//
//  • Alt-fire (+attack2): touch the thumb tip to the side of the middle
//    finger, the side nearest the thumb, and hold it there. The thumb moves
//    on its own muscles (the thenar group), so the aim stays put. Contact is
//    measured from the thumb tip to the middle finger's radial side: the
//    polyline knuckle → intermediate base → intermediate tip, shifted
//    `radialOffset` toward the index knuckle (ARKit joints sit on the bone's
//    centre line). The closest point's position along it is `along`: 0 at
//    the knuckle, 1 at the intermediate base, 2 at the intermediate tip.
//
//  How the two are told apart. Both are a thumb moving down with the index
//  out, and in a finger gun the curled middle finger's knuckle sits right
//  beside the index knuckle the reload metric measures to, so distance
//  alone can't separate them. The rules:
//
//  1. Where on the middle finger. A reload curl ends at the index knuckle,
//     which is next to the middle knuckle, so it reads `along` ≈ 0. Contact
//     only counts at `along ≥ minAlong` (past the middle of the proximal
//     phalanx, toward the PIP joint), where a curl in place doesn't reach.
//  2. Three zones: contact (closer than `contactOn`), near (closer than
//     `contactOff`, the hysteresis band) and clear. Alt-fire engages only
//     after `settleSeconds` in contact. Near or in contact, the reload hold
//     is vetoed (its timer resets, the ring goes away), so the ring can
//     never complete while the thumb is on the middle finger.
//  3. Each locks the other out until the thumb re-extends (thumb ratio
//     above `thumbCurlOff`): a reload that fired blocks alt-fire, and an
//     alt-fire that was pressed blocks the reload hold.
//  4. Ambiguous: the thumb reaches the middle finger after a reload hold
//     has already run for `reloadPathGrace` (the ring was visibly filling,
//     so a reload was meant). Then neither fires until the thumb leaves the
//     middle finger. A quick thumb move to the middle finger passes through
//     the reload curl on the way, which is why there's a grace at all.
//
//  Guards for alt-fire, so a fist or a pinch can't press it:
//  • the index must be extended (ratio above `indexExtended`) when it
//    engages. Once held, a trigger pull keeps it down, so fire and alt-fire
//    together are both buttons held, as in stock HL. A fist (index curled,
//    thumb wrapped over the middle finger) therefore never starts it.
//  • the thumb tip must be at least `pinchGuard` from the index tip, which
//    rules out the movement pinch (thumb to index tip, 2.5 cm) and the 🤌
//    weapon wheel (every tip within 5.5 cm of the thumb), whichever hand
//    they're made with.
//  The caller also forces both off while the wheel is open, the arm swing
//    owns the hand, or the hand is lost.
//
//  Press and hold: +attack2 is down for as long as contact holds, so the
//  gauss charges and the MP5's grenade or the crossbow's zoom are taps. A
//  press lasts at least `minHoldSeconds` (an engine frame has to see it, see
//  the gesture_input notes on +x/-x pulses) and releases after
//  `releaseSeconds` clear of the middle finger, so tracking jitter doesn't
//  drop a gauss charge early.
//

import simd

nonisolated enum ThumbContact {
    /// Thumb tip → middle finger radial side: the distance (m) and where
    /// along the finger the closest point lies (0 knuckle, 1 intermediate
    /// base, 2 intermediate tip). `towardIndex` is the index knuckle; the
    /// line is shifted `radialOffset` toward it from the middle knuckle.
    static func measure(thumbTip p: SIMD3<Float>,
                        knuckle: SIMD3<Float>, intermediateBase: SIMD3<Float>,
                        intermediateTip: SIMD3<Float>, towardIndex: SIMD3<Float>,
                        radialOffset: Float) -> (distance: Float, along: Float) {
        let side = towardIndex - knuckle
        let shift = simd_length(side) > 1e-5 ? simd_normalize(side) * radialOffset : .zero
        let a = knuckle + shift, b = intermediateBase + shift, c = intermediateTip + shift
        let (d1, t1) = segment(p, a, b)
        let (d2, t2) = segment(p, b, c)
        return d1 <= d2 ? (d1, t1) : (d2, 1 + t2)
    }

    /// Distance from p to segment a–b, and the closest point's 0…1 position.
    static func segment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (Float, Float) {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        let t = len2 > 1e-10 ? min(max(simd_dot(p - a, ab) / len2, 0), 1) : 0
        return (simd_distance(p, a + ab * t), t)
    }
}

nonisolated struct ThumbGestures {
    struct Tuning {
        // Reload (the existing gesture; Renderer.thumbCurlOn/Off, reloadHoldSeconds).
        var thumbCurlOn: Float = 0.45       // thumb ratio below this → hold begins
        var thumbCurlOff: Float = 0.60      // above this → hold cancels, locks clear
        var reloadHoldSeconds: Double = 0.75
        // Finger-gun index (Renderer.fireCurlOn/Off).
        var indexCurled: Float = 0.55       // below: trigger pulled
        var indexExtended: Float = 0.75     // above: index out (finger gun)
        // Alt-fire.
        var altFire = true                  // Settings "Alt-fire: thumb to middle finger"
        var contactOn: Float = 0.020        // m, thumb tip ↔ radial side to press
        var contactOff: Float = 0.032       // m, past this (after releaseSeconds) releases
        var minAlong: Float = 0.5           // contact only past mid proximal phalanx
        var alongSlack: Float = 0.10        // along may drop this far while held
        var settleSeconds: Double = 0.05    // in contact this long before it presses
        var releaseSeconds: Double = 0.05   // clear this long before it releases
        var minHoldSeconds: Double = 0.06   // a press lasts at least this long
        var pinchGuard: Float = 0.06        // m, thumb tip must be this far from the index tip
        var reloadPathGrace: Double = 0.3   // a reload hold older than this makes contact ambiguous
    }

    /// One frame of the gun hand, from the hand sample.
    struct Input {
        var indexExt: Float          // index tip↔knuckle / palm
        var thumbExt: Float          // thumb tip↔index knuckle / palm
        var contact: Float           // m, ThumbContact.measure distance
        var along: Float             // ThumbContact.measure position
        var thumbToIndexTip: Float   // m
    }

    enum AltState: String {
        case off = "off", idle = "—", noIndex = "index curled", pinch = "pinch guard",
             near = "near", settle = "settle", held = "HELD", releasing = "release",
             lockedReload = "locked (reload)", ambiguous = "ambiguous"
    }

    /// +attack2 should be down.
    private(set) var altFire = false
    /// +reload should be down (from the hold completing until the thumb re-extends).
    private(set) var reload = false
    /// The reload ring this frame (0 = none).
    private(set) var reloadRing: Float = 0
    private(set) var altState: AltState = .idle
    /// Reload is locked until the thumb re-extends (an alt-fire was pressed).
    private(set) var reloadLocked = false

    private var reloadStart: Double? = nil
    private var reloadLatched = false
    private var altLocked = false        // a reload fired; cleared when the thumb re-extends
    private var wasNear = false
    private var ambiguous = false
    private var contactSince: Double? = nil
    private var clearSince: Double? = nil
    private var pressedAt: Double = 0

    mutating func reset() {
        self = ThumbGestures()
    }

    /// Advance one frame. nil input = the gestures may not run (off, menu
    /// open, swing, hand lost): everything releases at once.
    mutating func update(_ input: Input?, now: Double, tuning t: Tuning) {
        guard let h = input else {
            reset()
            if !t.altFire { altState = .off }
            return
        }
        let thumbOut = h.thumbExt > t.thumbCurlOff
        if thumbOut { reloadLocked = false; altLocked = false }

        // Alt-fire geometry, with hysteresis while it's pressed or settling.
        var near = false
        if t.altFire {
            let engaged = altFire || contactSince != nil
            let minAlong = engaged ? t.minAlong - t.alongSlack : t.minAlong
            let onFinger = h.along >= minAlong
            let contact = onFinger && h.contact < t.contactOn
            near = onFinger && h.contact < t.contactOff
            if near, !wasNear, !reloadLatched, let s = reloadStart, now - s > t.reloadPathGrace { ambiguous = true }
            if !near { ambiguous = false }
            wasNear = near

            if altFire {
                if near { clearSince = nil; altState = .held }
                else {
                    if clearSince == nil { clearSince = now }
                    if now - clearSince! >= t.releaseSeconds, now - pressedAt >= t.minHoldSeconds {
                        altFire = false
                        clearSince = nil
                        reloadLocked = !thumbOut
                        altState = .idle
                    } else {
                        altState = .releasing
                    }
                }
            } else {
                let indexOut = h.indexExt > t.indexExtended
                let pinchFree = h.thumbToIndexTip > t.pinchGuard
                if !contact || !indexOut || !pinchFree || altLocked || ambiguous {
                    contactSince = nil
                    altState = !near ? .idle
                        : ambiguous ? .ambiguous
                        : altLocked ? .lockedReload
                        : !indexOut ? .noIndex
                        : !pinchFree ? .pinch : .near
                } else {
                    if contactSince == nil { contactSince = now }
                    if now - contactSince! >= t.settleSeconds {
                        altFire = true
                        pressedAt = now
                        contactSince = nil
                        altState = .held
                    } else {
                        altState = .settle
                    }
                }
            }
        } else {
            altFire = false
            contactSince = nil
            wasNear = false
            ambiguous = false
            altState = .off
        }

        // Reload hold, as before, plus the veto and the lock.
        var hold = reloadStart != nil
        if h.indexExt < t.indexCurled {
            hold = false        // trigger pulled — never reload mid-fire
        } else if h.thumbExt < t.thumbCurlOn, h.indexExt > t.indexExtended {
            hold = true
        } else if thumbOut {
            hold = false
        }
        // else: inside a hysteresis band — keep the current state.
        if !reloadLatched, near || altFire || reloadLocked { hold = false }
        if hold {
            if reloadStart == nil { reloadStart = now }
            let prog = Float(min((now - reloadStart!) / t.reloadHoldSeconds, 1.0))
            if prog >= 1, !reloadLatched {
                reloadLatched = true
                altLocked = true
                reload = true
            }
            // Hide the ring once fired: the full ring vanishing is the
            // "it took" cue; holding longer must not re-arm.
            reloadRing = reloadLatched ? 0 : prog
        } else {
            reloadStart = nil
            reloadLatched = false
            reloadRing = 0
            reload = false
        }
    }
}
