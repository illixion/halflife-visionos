//
//  FreeAim.swift
//  LambdaVision
//
//  Razer Hydra / Sixense-style free aim for keyboard+mouse and gamepad play.
//  The headset already is the camera, so the mouse and the right stick stop
//  turning it directly: they move an aim offset that swings the weapon (and
//  its shots) around inside a zone ahead of the body. Only what pushes past
//  the zone's edge turns the body; excess pitch is clamped (or, with "Look
//  up/down" on, tilts the view as before).
//
//  Angles here are degrees. The offset is in screen terms (yaw + = right,
//  pitch + = up), relative to the zone's centre. Room yaws (the centre, the
//  head) use xash's convention: counter-clockwise positive, as Renderer's
//  `yawDeg` and `headBaselineYaw` do.
//
//  Moving the aim to an edge and turning the body by the excess keeps the
//  world aim continuous: body + offset is what the player pointed at.
//
//  Pure simd, no frameworks: Tools/FreeAimProbe compiles this file verbatim
//  (with LazyViewFollower.swift, which the head anchor follows through).
//
//  App-local on purpose: one consumer. The zone maths knows nothing about
//  Half-Life, but no sibling (Longwave, Oneiros) aims a held gun; move it to
//  RAVEInput if a second one does.
//

import simd

nonisolated struct FreeAimZone {
    enum Shape: String, CaseIterable, Sendable { case ellipse, rectangle }
    /// What the zone is centred on: the body (snap/mouse turns move it, the
    /// head does not), or the head's yaw with a lazy follow.
    enum Anchor: String, CaseIterable, Sendable { case body, head }

    struct Config: Equatable, Sendable {
        /// Half-width of the zone (degrees either side of its centre).
        var yawLimit: Float = 20
        /// Half-height of the zone.
        var pitchLimit: Float = 15
        var shape: Shape = .ellipse
        var anchor: Anchor = .body
        /// Head anchor: the follow's spring time constant (s).
        var followTime: Float = 0.35
        /// Head anchor: the most the centre may trail the head (degrees).
        var followMaxLag: Float = 30
        /// Ease the offset back to the centre while there is no input.
        var recenter: Bool = false
        /// Seconds without input before the recentre starts.
        var recenterDelay: Float = 0.4
        /// The recentre's time constant (s): 63% of the way back after this.
        var recenterTime: Float = 0.8
    }

    /// What a move pushed past the zone (same convention as the offset):
    /// yaw turns the body, pitch is the caller's to clamp or tilt the view by.
    struct Overflow: Equatable {
        var yaw: Float = 0
        var pitch: Float = 0
        static let zero = Overflow()
    }

    var config: Config
    /// The aim offset from the zone's centre (+ right, + up).
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0
    /// Seconds since the last input (for the recentre).
    private(set) var idleTime: Float = 0
    /// Room yaw of the zone's centre from the last `updateCenter`.
    private(set) var centerYaw: Float?
    private var follower: LazyViewFollower

    init(config: Config = Config()) {
        self.config = config
        follower = LazyViewFollower(tuning: .init(timeConstant: config.followTime,
                                                  maxLag: config.followMaxLag * .pi / 180))
    }

    // MARK: Zone limits

    /// The yaw limit at a given pitch: the ellipse narrows toward its top and
    /// bottom; a rectangle doesn't.
    func yawLimit(atPitch p: Float) -> Float {
        let a = max(config.yawLimit, 0), b = max(config.pitchLimit, 0)
        guard config.shape == .ellipse, b > 0 else { return a }
        let t = min(abs(p) / b, 1)
        return a * (1 - t * t).squareRoot()
    }

    /// The pitch limit at a given yaw (same rule, the other way).
    func pitchLimit(atYaw y: Float) -> Float {
        let a = max(config.yawLimit, 0), b = max(config.pitchLimit, 0)
        guard config.shape == .ellipse, a > 0 else { return b }
        let t = min(abs(y) / a, 1)
        return b * (1 - t * t).squareRoot()
    }

    /// Whether the offset sits on the zone's yaw edge (within `slack`°).
    func pinnedYaw(slack: Float = 0.01) -> Bool { abs(yaw) >= yawLimit(atPitch: pitch) - slack }
    func pinnedPitch(slack: Float = 0.01) -> Bool { abs(pitch) >= pitchLimit(atYaw: yaw) - slack }

    // MARK: Input

    /// Moves the aim by a mouse or stick delta and returns what pushed past
    /// the edge. Yaw goes first, limited at the current pitch; then pitch,
    /// limited at the new yaw. So an up/down move never turns the body, even
    /// on the ellipse's narrowing sides.
    @discardableResult
    mutating func move(yaw dy: Float, pitch dp: Float) -> Overflow {
        var out = Overflow.zero
        if dy != 0 || dp != 0 { idleTime = 0 }
        if dy != 0 {
            let lim = yawLimit(atPitch: pitch)
            let want = yaw + dy
            let clamped = min(max(want, -lim), lim)
            // Only what this move pushed past the edge spills out; an offset
            // already outside (the zone shrank) is the clamp's to settle.
            out.yaw = want - clamped
            yaw = clamped
        }
        if dp != 0 {
            let lim = pitchLimit(atYaw: yaw)
            let want = pitch + dp
            let clamped = min(max(want, -lim), lim)
            out.pitch = want - clamped
            pitch = clamped
        }
        return out
    }

    /// Brings an offset left outside a zone that shrank (a settings change)
    /// back inside. The yaw excess turns the body, as an overflowing move's
    /// would, so the world aim holds.
    @discardableResult
    mutating func clampToZone() -> Overflow {
        var out = Overflow.zero
        let pl = max(config.pitchLimit, 0)
        let p = min(max(pitch, -pl), pl)
        out.pitch = pitch - p
        pitch = p
        let yl = yawLimit(atPitch: pitch)
        let y = min(max(yaw, -yl), yl)
        out.yaw = yaw - y
        yaw = y
        return out
    }

    /// Advances the idle clock and, when the recentre is on and the input
    /// has been still for its delay, eases the offset back toward the
    /// centre. Exact for any frame time (exponential decay).
    mutating func step(dt: Float, hadInput: Bool) {
        guard dt > 0, dt.isFinite else { return }
        if hadInput { idleTime = 0; return }
        idleTime += dt
        guard config.recenter, idleTime > config.recenterDelay else { return }
        // Only the part of this step past the delay decays.
        let active = min(dt, idleTime - config.recenterDelay)
        let k = expf(-active / max(config.recenterTime, 1e-3))
        yaw *= k
        pitch *= k
        if abs(yaw) < 1e-3 { yaw = 0 }
        if abs(pitch) < 1e-3 { pitch = 0 }
    }

    /// The zone's centre this frame, a room yaw (CCW +, degrees): the body's
    /// forward, or the head's yaw seen through a lazy follow.
    @discardableResult
    mutating func updateCenter(bodyYaw: Float, headYaw: Float, dt: Float) -> Float {
        switch config.anchor {
        case .body:
            centerYaw = bodyYaw
            follower.reset(to: Self.yawQuat(headYaw))   // a switch to head starts at the head
        case .head:
            follower.tuning.timeConstant = config.followTime
            follower.tuning.maxLag = config.followMaxLag * .pi / 180
            let q = follower.update(target: Self.yawQuat(headYaw), dt: dt)
            centerYaw = Self.yawOf(q)
        }
        return centerYaw!
    }

    /// Back to the centre, idle, the follow forgotten.
    mutating func reset() {
        yaw = 0
        pitch = 0
        idleTime = 0
        centerYaw = nil
        follower = LazyViewFollower(tuning: follower.tuning)
    }

    // MARK: Engine and drawing

    /// Room-frame aim: the yaw (CCW +) and pitch (+ down, xash) the gun
    /// points along, for a centre yaw.
    func aim(centerYaw c: Float) -> (yaw: Float, pitchDown: Float) {
        (Self.wrap(c - yaw), -pitch)
    }

    /// The offset the engine's weapon frame adds to the composed head view
    /// (lambda_set_aim_offset: pitch + down, yaw CCW): the room aim less the
    /// head's own yaw and pitch.
    static func engineOffset(aimYaw: Float, aimPitchDown: Float,
                             headYaw: Float, headPitchDown: Float) -> (pitch: Float, yaw: Float) {
        (aimPitchDown - headPitchDown, wrap(aimYaw - headYaw))
    }

    /// The flat viewmodel's model transform with the aim applied, in GoldSrc
    /// room axes and units (x forward, y left, z up, inches): the viewmodel is
    /// authored in view space (eye at the origin, looking down +X), so with no
    /// offset and the head on the centre this is the head-locked placement.
    /// The gun turns about `pivot` (view space: a shoulder, the hand, or the
    /// eye at zero), which stays where the body holds it — ahead of the
    /// centre, not the head — so looking around doesn't drag it.
    static func gunTransform(eye: SIMD3<Float>, centerYaw: Float, aimYaw: Float, aimPitchDown: Float,
                             pivot: SIMD3<Float>) -> float4x4 {
        let rc = rotation(yaw: centerYaw, pitchDown: 0)
        let ra = rotation(yaw: aimYaw, pitchDown: aimPitchDown)
        let p = rc * SIMD4<Float>(pivot, 0)
        var t = ra
        let o = SIMD3(p.x, p.y, p.z) + eye - xyz(ra * SIMD4<Float>(pivot, 0))
        t.columns.3 = SIMD4<Float>(o, 1)
        return t
    }

    /// Rz(yaw)·Ry(pitch): xash's view rotation without roll (AngleVectors),
    /// so column 0 is the forward the engine derives from these angles.
    static func rotation(yaw: Float, pitchDown: Float) -> float4x4 {
        let y = yaw * .pi / 180, p = pitchDown * .pi / 180
        let cy = cosf(y), sy = sinf(y), cp = cosf(p), sp = sinf(p)
        return float4x4(columns: (
            SIMD4<Float>(cp * cy, cp * sy, -sp, 0),    // forward
            SIMD4<Float>(-sy, cy, 0, 0),               // left
            SIMD4<Float>(sp * cy, sp * sy, cp, 0),     // up
            SIMD4<Float>(0, 0, 0, 1)))
    }

    static func wrap(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    private static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    /// A yaw about GoldSrc's +Z (up), for the follower.
    static func yawQuat(_ deg: Float) -> simd_quatf {
        simd_quatf(angle: deg * .pi / 180, axis: SIMD3(0, 0, 1))
    }

    static func yawOf(_ q: simd_quatf) -> Float {
        let f = q.act(SIMD3<Float>(1, 0, 0))
        return atan2f(f.y, f.x) * 180 / .pi
    }
}
