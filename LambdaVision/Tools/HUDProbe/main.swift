// Drives the HEV HUD overlay's view follower on the Mac: LazyViewFollower.swift
// is compiled verbatim (build.sh), so what passes here is what the app runs.
// Exits non-zero on the first failure.

import Foundation
import simd

func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
func check(_ ok: Bool, _ m: @autoclosure () -> String) { if !ok { die(m()) } }

let deg = Float.pi / 180
func yaw(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) }
func pitch(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(1, 0, 0)) }
/// Signed yaw of q (radians), for single-axis runs.
func yawOf(_ q: simd_quatf) -> Float {
    let f = q.act(SIMD3<Float>(0, 0, -1))
    return atan2f(-f.x, -f.z)
}

// Spans the app's tuning (HEVHUD.overlayTimeConstant / overlayMaxLagDeg) and
// either side of it, so retuning on device stays covered.
let tunings: [LazyViewFollower.Tuning] = [
    .init(timeConstant: 0.05, maxLag: 6 * deg),
    .init(timeConstant: 0.07, maxLag: 8 * deg),
    .init(timeConstant: 0.12, maxLag: 12 * deg),
]
let rates: [Float] = [30, 72, 90, 96, 120, 240]

/// Runs `head(t)` for `seconds` at `hz` (with optional dt jitter) and
/// returns the follower's yaw sampled at `samples` times, plus the worst lag.
func run(_ tuning: LazyViewFollower.Tuning, hz: Float, seconds: Float, jitter: Bool = false,
         samples: [Float] = [], head: (Float) -> simd_quatf,
         each: ((Float, LazyViewFollower, simd_quatf) -> Void)? = nil) -> (yaws: [Float], worstLag: Float) {
    var f = LazyViewFollower(tuning: tuning)
    var t: Float = 0
    var out: [Float] = []
    var pending = samples
    var worst: Float = 0
    var rng = SystemRandomNumberGenerator()
    f.update(target: head(0), dt: 0)
    while t < seconds {
        var dt = 1 / hz
        if jitter { dt *= Float.random(in: 0.6...1.4, using: &rng) }
        // Sample exactly at the requested times: split the step there.
        if let s = pending.first, t + dt >= s {
            dt = s - t
            pending.removeFirst()
            t = s
            f.update(target: head(t), dt: dt)
            out.append(yawOf(f.orientation!))
        } else {
            t += dt
            f.update(target: head(t), dt: dt)
        }
        let lag = f.lag(behind: head(t))
        worst = max(worst, lag)
        each?(t, f, head(t))
    }
    return (out, worst)
}

// MARK: Bounded lag

for tn in tunings {
    for hz in rates {
        // 400°/s whip, well past the cap, on yaw and on a yaw+pitch diagonal.
        let whip = run(tn, hz: hz, seconds: 1.5) { t in yaw(min(t, 0.5) * 400 * deg) }
        check(whip.worstLag <= tn.maxLag + 1e-4,
              "yaw whip at \(hz) Hz trails \(whip.worstLag / deg)° > cap \(tn.maxLag / deg)°")
        let diag = run(tn, hz: hz, seconds: 1.5) { t in
            let a = min(t, 0.5)
            return yaw(a * 300 * deg) * pitch(a * -150 * deg)
        }
        check(diag.worstLag <= tn.maxLag + 1e-4,
              "diagonal whip at \(hz) Hz trails \(diag.worstLag / deg)° > cap \(tn.maxLag / deg)°")
        // Shaking the head back and forth, 3 Hz ±25°.
        let shake = run(tn, hz: hz, seconds: 2, jitter: true) { t in yaw(sinf(t * 2 * .pi * 3) * 25 * deg) }
        check(shake.worstLag <= tn.maxLag + 1e-4, "head shake at \(hz) Hz trails \(shake.worstLag / deg)°")
    }
}
print("bounded lag: ok")

// MARK: Convergence and no overshoot

for tn in tunings {
    for hz in rates {
        // Fast turn then stop: the follower must come in from behind and
        // never pass the head.
        var passed = false
        var lastLag: Float = .infinity
        var rising = false
        let stopAt: Float = 0.4
        let finalYaw: Float = stopAt * 250 * deg
        _ = run(tn, hz: hz, seconds: 2) { t in yaw(min(t, stopAt) * 250 * deg) } each: { t, f, head in
            let signed = yawOf(f.orientation!) - yawOf(head)
            if signed > 1e-5 { passed = true }   // turning +yaw, so behind is negative
            if t > stopAt + 1e-4 {
                let lag = f.lag(behind: head)
                if lag > lastLag + 1e-6 { rising = true }
                lastLag = lag
            }
        }
        check(!passed, "overshoot past the head after a stop at \(hz) Hz (τ \(tn.timeConstant))")
        check(!rising, "lag grew again after the head stopped at \(hz) Hz (τ \(tn.timeConstant))")
        let end = run(tn, hz: hz, seconds: 2, samples: [1.9]) { t in yaw(min(t, stopAt) * 250 * deg) }
        check(abs(end.yaws[0] - finalYaw) < 0.02 * deg,
              "not converged 1.5 s after the stop at \(hz) Hz: \((end.yaws[0] - finalYaw) / deg)°")
    }
}

// Steady slow turn: trails by 2Ωτ (under the cap).
do {
    let tn = tunings[1]
    let omega: Float = 20 * deg
    let r = run(tn, hz: 90, seconds: 2, samples: [1.5]) { t in yaw(t * omega) }
    let lag = 1.5 * omega - r.yaws[0]
    let expected = 2 * omega * tn.timeConstant
    // Within one frame of head motion (the target is sampled per frame).
    check(abs(lag - expected) < omega / 90,
          "steady 20°/s lag \(lag / deg)°, expected \(expected / deg)°")
}
print("convergence, no overshoot: ok")

// MARK: Framerate independence

for tn in tunings {
    // A still head from a resting offset: the closed form is exact, so every
    // rate lands on the same curve.
    var curves: [[Float]] = []
    for hz in rates {
        var f = LazyViewFollower(tuning: tn)
        f.reset(to: yaw(tn.maxLag * 0.9))
        var t: Float = 0, out: [Float] = []
        let marks: [Float] = [0.05, 0.1, 0.2, 0.4]
        var next = 0
        while next < marks.count {
            let dt = min(1 / hz, marks[next] - t)
            t += dt
            f.update(target: yaw(0), dt: dt)
            if abs(t - marks[next]) < 1e-6 { out.append(yawOf(f.orientation!)); next += 1 }
        }
        curves.append(out)
    }
    for c in curves.dropFirst() {
        for (a, b) in zip(c, curves[0]) {
            check(abs(a - b) < 0.002 * deg, "still-target settle differs by \((a - b) / deg)° across rates")
        }
    }

    // A moving head: rates agree to within a small fraction of the cap.
    let marks: [Float] = [0.15, 0.35, 0.6, 0.9]
    let head: (Float) -> simd_quatf = { t in yaw(sinf(min(t, 0.75) * 2.2) * 70 * deg) }
    let ref = run(tn, hz: 960, seconds: 1, samples: marks, head: head).yaws
    for hz in rates {
        for jitter in [false, true] {
            let r = run(tn, hz: hz, seconds: 1, jitter: jitter, samples: marks, head: head).yaws
            for (i, (a, b)) in zip(r, ref).enumerated() {
                let tol: Float = hz < 60 ? 1.0 * deg : 0.4 * deg   // jittered ±40%: 30 Hz has 47 ms steps
                check(abs(a - b) < tol,
                      "\(hz) Hz\(jitter ? " jittered" : "") at t=\(marks[i]) is \((a - b) / deg)° off 960 Hz (τ \(tn.timeConstant))")
            }
        }
    }
}
print("framerate independence: ok")

// MARK: Edges

do {
    var f = LazyViewFollower(tuning: tunings[1])
    f.update(target: yaw(0), dt: 0)
    f.update(target: yaw(90 * deg), dt: 0.5)   // a stall longer than resetGap
    check(f.lag(behind: yaw(90 * deg)) < 1e-5, "a long gap snaps to the head")
    let before = f.orientation!
    f.update(target: yaw(120 * deg), dt: 0)
    check(simd_length((f.orientation! * before.inverse).imag) < 1e-6, "dt 0 changes nothing")
    var g = LazyViewFollower(tuning: tunings[1])
    check(g.lag(behind: yaw(1)) == 0, "no lag before the first update")
    g.update(target: yaw(40 * deg), dt: 1 / 90)
    check(g.lag(behind: yaw(40 * deg)) < 1e-5, "the first update snaps")
    // Half a turn and beyond: the shortest way round, still capped.
    g.update(target: yaw(40 * deg + 179 * deg), dt: 1 / 90)
    check(g.lag(behind: yaw(40 * deg + 179 * deg)) <= tunings[1].maxLag + 1e-4, "179° jump capped")
    let v = LazyViewFollower.rotationVector(LazyViewFollower.quaternion(rotationVector: SIMD3(0.1, -0.2, 0.3)))
    check(simd_distance(v, SIMD3(0.1, -0.2, 0.3)) < 1e-5, "exp/log round trip")
}
print("edges: ok")
print("all HUD follower checks passed")
