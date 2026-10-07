// Drives the free-aim zone on the Mac: FreeAim.swift and LazyViewFollower.swift
// are compiled verbatim (build.sh), so what passes here is what the app runs.
// Exits non-zero on the first failure.

import Foundation
import simd

var checks = 0
func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
func check(_ ok: Bool, _ m: @autoclosure () -> String) { checks += 1; if !ok { die(m()) } }
func near(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) <= eps }
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-3) -> Bool { simd_length(a - b) <= eps }
func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ eps: Float = 1e-3) -> Bool { simd_length(a - b) <= eps }

typealias Zone = FreeAimZone
func zone(_ yaw: Float = 20, _ pitch: Float = 15, _ shape: Zone.Shape = .ellipse,
          anchor: Zone.Anchor = .body, recenter: Bool = false) -> Zone {
    var c = Zone.Config()
    c.yawLimit = yaw; c.pitchLimit = pitch; c.shape = shape; c.anchor = anchor; c.recenter = recenter
    return Zone(config: c)
}

// MARK: Offset inside the zone

do {
    var z = zone()
    let o = z.move(yaw: 5, pitch: 3)
    check(o == .zero, "a move inside the zone overflows nothing: \(o)")
    check(near(z.yaw, 5) && near(z.pitch, 3), "offset accumulates: \(z.yaw), \(z.pitch)")
    z.move(yaw: -12, pitch: -6)
    check(near(z.yaw, -7) && near(z.pitch, -3), "and goes both ways: \(z.yaw), \(z.pitch)")
}

// MARK: Yaw past the edge turns the body, and the world aim is continuous

for shape in Zone.Shape.allCases {
    var z = zone(20, 15, shape)
    var turned: Float = 0
    var input: Float = 0
    // 60 small right steps of 0.7° (42° in all): 20 fill the zone, 22 turn.
    for _ in 0..<60 {
        let o = z.move(yaw: 0.7, pitch: 0)
        check(o.yaw >= 0 && o.pitch == 0, "\(shape): a right move only overflows right: \(o)")
        turned += o.yaw
        input += 0.7
    }
    check(near(z.yaw, 20), "\(shape): yaw pinned at the edge: \(z.yaw)")
    check(near(turned, input - 20, 1e-3), "\(shape): overflow is exactly the excess: \(turned) vs \(input - 20)")
    check(near(turned + z.yaw, input), "\(shape): body + offset = input (world aim continuous)")
    check(z.pinnedYaw(), "\(shape): reports pinned")
    // Coming back leaves the edge at once: no overflow until the far edge.
    let back = z.move(yaw: -10, pitch: 0)
    check(back == .zero && near(z.yaw, 10), "\(shape): moving back un-pins without turning: \(back) \(z.yaw)")
    check(!z.pinnedYaw(), "\(shape): no longer pinned")
    let far = z.move(yaw: -35, pitch: 0)
    check(near(far.yaw, -5) && near(z.yaw, -20), "\(shape): left overflow is negative: \(far) \(z.yaw)")
    // One big flick: same split as many small steps.
    var z2 = zone(20, 15, shape)
    let flick = z2.move(yaw: 42, pitch: 0)
    check(near(flick.yaw, 22) && near(z2.yaw, 20), "\(shape): a single flick splits the same: \(flick)")
}

// MARK: Pitch clamps (never turns the body)

for shape in Zone.Shape.allCases {
    var z = zone(20, 15, shape)
    let o = z.move(yaw: 0, pitch: 40)
    check(near(z.pitch, 15) && near(o.pitch, 25) && o.yaw == 0, "\(shape): pitch clamps at the edge, excess returned: \(o) \(z.pitch)")
    let d = z.move(yaw: 0, pitch: -50)
    check(near(z.pitch, -15) && near(d.pitch, -20), "\(shape): and at the bottom: \(d) \(z.pitch)")
}

// MARK: Ellipse vs rectangle at the corners

do {
    // Rectangle: independent limits, corners reachable.
    var r = zone(20, 15, .rectangle)
    r.move(yaw: 0, pitch: 15)
    let o = r.move(yaw: 30, pitch: 0)
    check(near(r.yaw, 20) && near(o.yaw, 10), "rectangle: full yaw at full pitch: \(r.yaw) \(o)")

    // Ellipse: at pitch p the yaw limit is a·√(1 − (p/b)²).
    var e = zone(20, 15, .ellipse)
    e.move(yaw: 0, pitch: 9)                       // p/b = 0.6 → √0.64 = 0.8 → 16°
    check(near(e.yawLimit(atPitch: 9), 16), "ellipse yaw limit at 9°: \(e.yawLimit(atPitch: 9))")
    let eo = e.move(yaw: 30, pitch: 0)
    check(near(e.yaw, 16) && near(eo.yaw, 14), "ellipse clamps yaw at the narrowed edge: \(e.yaw) \(eo)")
    // A vertical move at a yaw edge never turns the body; pitch takes the
    // narrowed limit instead (b·√(1 − (y/a)²) = 9 at y = 16).
    let up = e.move(yaw: 0, pitch: 10)
    check(up.yaw == 0, "ellipse: an up move never turns: \(up)")
    check(near(e.pitch, 9) && near(up.pitch, 10), "ellipse: pitch clamps at the yaw-narrowed edge: \(e.pitch) \(up)")
    // Every reachable offset lies inside the ellipse.
    var rng = SystemRandomNumberGenerator()
    var w = zone(20, 15, .ellipse)
    for _ in 0..<5000 {
        w.move(yaw: Float.random(in: -8...8, using: &rng), pitch: Float.random(in: -8...8, using: &rng))
        let r2 = (w.yaw / 20) * (w.yaw / 20) + (w.pitch / 15) * (w.pitch / 15)
        check(r2 <= 1 + 1e-3, "ellipse: offset escaped the zone (\(w.yaw), \(w.pitch))")
    }
}

// MARK: A zero zone is today's behaviour

do {
    var z = zone(0, 0)
    let o = z.move(yaw: 3.3, pitch: -2)
    check(near(o.yaw, 3.3) && near(o.pitch, -2) && z.yaw == 0 && z.pitch == 0,
          "zero zone: everything overflows (mouse turns the body directly): \(o)")
}

// MARK: Shrinking the zone clamps, turning the body by the yaw excess

do {
    var z = zone(20, 15, .rectangle)
    z.move(yaw: 18, pitch: 12)
    z.config.yawLimit = 10
    z.config.pitchLimit = 5
    let o = z.clampToZone()
    check(near(z.yaw, 10) && near(z.pitch, 5) && near(o.yaw, 8) && near(o.pitch, 7),
          "shrink: offset clamped, excess reported: \(z.yaw) \(z.pitch) \(o)")
    check(z.clampToZone() == .zero, "a second clamp does nothing")
}

// MARK: Recentre

do {
    var off = zone(recenter: false)
    off.move(yaw: 10, pitch: 6)
    for _ in 0..<300 { off.step(dt: 1.0 / 90, hadInput: false) }
    check(near(off.yaw, 10) && near(off.pitch, 6), "recentre off: the offset stays put: \(off.yaw)")

    var on = zone(recenter: true)
    on.move(yaw: 10, pitch: 6)
    // Inside the delay nothing moves.
    let delay = on.config.recenterDelay
    var t: Float = 0
    while t + 1.0 / 90 < delay { on.step(dt: 1.0 / 90, hadInput: false); t += 1.0 / 90 }
    check(near(on.yaw, 10) && near(on.pitch, 6), "recentre waits out its delay: \(on.yaw)")
    // Then one time constant later it's 1/e of the way.
    var a = on, b = on
    let tau = on.config.recenterTime
    let rest = delay - t
    a.step(dt: rest + tau, hadInput: false)
    check(near(a.yaw, 10 / expf(1), 0.02), "recentre: 1/e after one time constant: \(a.yaw)")
    // Frame-rate independent: many small steps land the same as one.
    var tt: Float = 0
    let total = rest + tau
    while tt < total { let dt = min(1.0 / 120, total - tt); b.step(dt: dt, hadInput: false); tt += dt }
    check(near(a.yaw, b.yaw, 1e-3) && near(a.pitch, b.pitch, 1e-3), "recentre: frame-rate independent: \(a.yaw) vs \(b.yaw)")
    // Input resets the idle clock.
    var c = zone(recenter: true)
    c.move(yaw: 10, pitch: 0)
    for _ in 0..<200 {
        c.step(dt: 1.0 / 90, hadInput: true)
    }
    check(near(c.yaw, 10), "recentre never runs while input keeps coming: \(c.yaw)")
    for _ in 0..<900 { c.step(dt: 1.0 / 90, hadInput: false) }
    check(abs(c.yaw) < 0.01, "recentre settles at the centre: \(c.yaw)")
    // It never turns the body: step() has no overflow to give.
}

// MARK: Anchor

do {
    var body = zone(anchor: .body)
    let c0 = body.updateCenter(bodyYaw: 30, headYaw: 75, dt: 1.0 / 90)
    check(near(c0, 30), "body anchor: the centre is the body, wherever the head is: \(c0)")
    var turned = body
    for _ in 0..<90 { turned.updateCenter(bodyYaw: 30, headYaw: 120, dt: 1.0 / 90) }
    check(near(turned.centerYaw!, 30), "body anchor: head turning never drags it")

    var head = zone(anchor: .head)
    head.config.followTime = 0.3
    head.config.followMaxLag = 25
    head.updateCenter(bodyYaw: 0, headYaw: 0, dt: 0)
    // A quick 60° head turn: the centre lags but never by more than the cap,
    // and settles on the head without overshoot.
    var worst: Float = 0, over: Float = 0
    var headYaw: Float = 0
    for i in 0..<360 {
        headYaw = min(Float(i) * 2, 60)           // 180°/s to 60°
        let c = head.updateCenter(bodyYaw: 0, headYaw: headYaw, dt: 1.0 / 90)
        worst = max(worst, abs(Zone.wrap(headYaw - c)))
        over = max(over, c - 60)
    }
    check(worst <= 25 + 0.05, "head anchor: lag capped at followMaxLag: \(worst)")
    check(worst > 5, "head anchor: it does lag (lazy): \(worst)")
    check(near(head.centerYaw!, 60, 0.05), "head anchor: settles on the head: \(head.centerYaw!)")
    check(over < 0.05, "head anchor: no overshoot: \(over)")
    // Wraps across ±180 the short way.
    var wrapZ = zone(anchor: .head)
    wrapZ.updateCenter(bodyYaw: 0, headYaw: 170, dt: 0)
    for _ in 0..<270 { wrapZ.updateCenter(bodyYaw: 0, headYaw: -170, dt: 1.0 / 90) }
    check(near(abs(wrapZ.centerYaw!), 170, 0.1), "head anchor: crosses ±180 the short way: \(wrapZ.centerYaw!)")
    // Switching anchors: body → head starts on the head, no swing.
    var sw = zone(anchor: .body)
    sw.updateCenter(bodyYaw: 0, headYaw: 40, dt: 1.0 / 90)
    sw.config.anchor = .head
    let first = sw.updateCenter(bodyYaw: 0, headYaw: 40, dt: 1.0 / 90)
    check(near(first, 40, 0.05), "anchor switch to head starts at the head: \(first)")
}

// MARK: Engine offset

do {
    var z = zone()
    z.move(yaw: 10, pitch: 5)                     // 10° right, 5° up
    let a = z.aim(centerYaw: 30)
    check(near(a.yaw, 20) && near(a.pitchDown, -5), "aim: right is clockwise, up is negative xash pitch: \(a)")
    let e = Zone.engineOffset(aimYaw: a.yaw, aimPitchDown: a.pitchDown, headYaw: 50, headPitchDown: 10)
    check(near(e.yaw, -30) && near(e.pitch, -15), "engine offset: aim less head: \(e)")
    let w = Zone.engineOffset(aimYaw: 175, aimPitchDown: 0, headYaw: -175, headPitchDown: 0)
    check(near(w.yaw, -10), "engine offset wraps: \(w.yaw)")
    // Head view + offset reproduces the aim direction (what the server does
    // to v_angle in VR_ItemPostFrame): pitch and yaw add as Euler angles.
    let fwd = Zone.rotation(yaw: 50 + e.yaw, pitchDown: 10 + e.pitch).columns.0
    let aimFwd = Zone.rotation(yaw: a.yaw, pitchDown: a.pitchDown).columns.0
    check(near(SIMD3(fwd.x, fwd.y, fwd.z), SIMD3(aimFwd.x, aimFwd.y, aimFwd.z)), "view + offset = aim direction")
    // Matches xash's AngleVectors: fwd = (cp·cy, cp·sy, −sp).
    let r = Zone.rotation(yaw: 30, pitchDown: 20).columns.0
    let cp = cosf(20 * .pi / 180), sp = sinf(20 * .pi / 180), cy = cosf(30 * .pi / 180), sy = sinf(30 * .pi / 180)
    check(near(SIMD3(r.x, r.y, r.z), SIMD3(cp * cy, cp * sy, -sp)), "rotation matches AngleVectors")
}

// MARK: Gun transform

do {
    let eye = SIMD3<Float>(100, -40, 64)
    let shoulder = SIMD3<Float>(-4, -7, -9)
    // No offset, head on the centre: exactly the head-locked flat placement.
    let g0 = Zone.gunTransform(eye: eye, centerYaw: 35, aimYaw: 35, aimPitchDown: 0, pivot: shoulder)
    let flat = { () -> float4x4 in var m = Zone.rotation(yaw: 35, pitchDown: 0); m.columns.3 = SIMD4(eye, 1); return m }()
    for c in 0..<4 { check(near(g0[c], flat[c], 1e-4), "zero offset = flat viewmodel placement (column \(c))") }
    func p(_ m: float4x4, _ v: SIMD3<Float>) -> SIMD3<Float> { let r = m * SIMD4(v, 1); return SIMD3(r.x, r.y, r.z) }
    // Any offset: the pivot stays put, and the model's +X is the aim.
    for (ay, ap) in [(Float(55), Float(0)), (15, -12), (35, 14)] {
        let g = Zone.gunTransform(eye: eye, centerYaw: 35, aimYaw: ay, aimPitchDown: ap, pivot: shoulder)
        check(near(p(g, shoulder), p(g0, shoulder), 1e-3), "pivot fixed at (\(ay), \(ap))")
        let f = g.columns.0, want = Zone.rotation(yaw: ay, pitchDown: ap).columns.0
        check(near(SIMD3(f.x, f.y, f.z), SIMD3(want.x, want.y, want.z)), "gun +X follows the aim at (\(ay), \(ap))")
        check(near(simd_determinant(g), 1, 1e-4), "rigid (no scale/shear)")
    }
    // Eye pivot: the eye stays at the eye.
    let ge = Zone.gunTransform(eye: eye, centerYaw: 0, aimYaw: 20, aimPitchDown: 10, pivot: .zero)
    check(near(p(ge, .zero), eye), "eye pivot keeps the model origin on the eye")
}

print("free-aim probe: \(checks) checks passed")
