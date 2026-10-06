//
//  LazyViewFollower.swift
//  LambdaVision
//
//  An orientation that trails the head with a short, bounded delay: the
//  frame the HEV HUD overlay hangs its panels in when a keyboard, mouse or
//  gamepad is in use (HEVHUD). A panel stamped onto the view reads as a
//  sticker on the lens; one that eases after the head, but never far, reads
//  as a hologram the suit projects beside Gordon's head.
//
//  The follow is a critically damped spring on the rotation from the head to
//  the follower, stepped in closed form (exact for a still target over the
//  step), so it settles the same at 90 or 120 Hz and never overshoots a head
//  that has stopped. On top of that the lag is clamped: however fast the
//  head turns, the follower is never more than `maxLag` behind it, so a
//  panel can't be flung out of view. While turning steadily at Ω rad/s it
//  trails by 2Ω·timeConstant, until that reaches the cap.
//
//  Pure simd, no frameworks: Tools/HUDProbe compiles this file verbatim.
//
//  RAVE candidate: generic (nothing here knows about Half-Life or panels);
//  belongs in RAVEHolo beside RAVEHoloPanel.facing as a lazy-follow anchor.
//

import simd

nonisolated struct LazyViewFollower {
    struct Tuning {
        /// The spring's time constant (s): 1/ω of the critically damped
        /// response. A still target is 95% caught up after ~4.7 of these.
        var timeConstant: Float
        /// The most the follower may trail the target (radians).
        var maxLag: Float
        /// A gap between updates longer than this (s) snaps to the target
        /// instead of swinging across from a stale pose.
        var resetGap: Float = 0.25
    }

    var tuning: Tuning
    /// nil until the first update.
    private(set) var orientation: simd_quatf?
    /// World-frame angular velocity (rad/s, rotation vector).
    private(set) var velocity = SIMD3<Float>(repeating: 0)

    init(tuning: Tuning) { self.tuning = tuning }

    mutating func reset(to target: simd_quatf) {
        orientation = simd_normalize(target)
        velocity = .zero
    }

    /// Advance by `dt` seconds toward `target`; returns the new orientation.
    @discardableResult
    mutating func update(target rawTarget: simd_quatf, dt: Float) -> simd_quatf {
        let target = simd_normalize(rawTarget)
        guard let current = orientation, dt <= tuning.resetGap, dt.isFinite else {
            reset(to: target)
            return target
        }
        guard dt > 0 else { return current }
        let omega = 1 / max(tuning.timeConstant, 1e-4)

        // Displacement from the target as a world-frame rotation vector:
        // follower = exp(d) * target.
        let d = Self.rotationVector(current * target.inverse)
        // x(t) = (x0 + (v0 + ωx0)t)e^(-ωt), applied per axis.
        let decay = expf(-omega * dt)
        let k = velocity + omega * d
        var d1 = (d + k * dt) * decay
        var v1 = (velocity - omega * k * dt) * decay

        var lag = simd_length(d1)
        if lag > tuning.maxLag {
            // Held at the cap: drop any velocity carrying it further out.
            d1 *= tuning.maxLag / lag
            lag = tuning.maxLag
            let n = d1 / lag
            let outward = simd_dot(v1, n)
            if outward > 0 { v1 -= n * outward }
        }
        if lag > 1e-6 {
            // Moving back faster than ωx would carry it past the target
            // once the head stops; the critical rate is the most it may have.
            let n = d1 / lag
            let toward = -simd_dot(v1, n)
            if toward > omega * lag { v1 += n * (toward - omega * lag) }
        }

        let q = simd_normalize(Self.quaternion(rotationVector: d1) * target)
        orientation = q
        velocity = v1
        return q
    }

    /// Angle between the follower and `target` (radians); 0 before the
    /// first update.
    func lag(behind target: simd_quatf) -> Float {
        guard let orientation else { return 0 }
        return simd_length(Self.rotationVector(orientation * simd_normalize(target).inverse))
    }

    static func rotationVector(_ q: simd_quatf) -> SIMD3<Float> {
        // Shortest way round: q and -q are the same rotation.
        let s = q.real < 0 ? -q : q
        let sinHalf = simd_length(s.imag)
        guard sinHalf > 1e-7 else { return s.imag * 2 }
        let angle = 2 * atan2f(sinHalf, s.real)
        return s.imag / sinHalf * angle
    }

    static func quaternion(rotationVector v: SIMD3<Float>) -> simd_quatf {
        let angle = simd_length(v)
        guard angle > 1e-7 else { return simd_quatf(real: 1, imag: v / 2) }
        return simd_quatf(angle: angle, axis: v / angle)
    }
}
