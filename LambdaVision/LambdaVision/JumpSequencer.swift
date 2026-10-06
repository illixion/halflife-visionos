//
//  JumpSequencer.swift
//  LambdaVision
//
//  Turns the hand-tracking jump gesture (the off hand's up-flick on the pinch
//  joystick, or both fists flicked up in an arm swing) into +jump/+duck
//  timing. Pure logic, so the host probe (Tools/HandsProbe) checks the
//  timing.
//
//  Two shapes:
//
//  • Crouch-jump (stock behaviour): +jump at once, +duck a beat later
//    (`autoDuckDelay`) once airborne, which HL needs to clear most ledges.
//
//  • Long jump: the module fires in PM_Jump (pm_shared.c) only when +duck is
//    already down with its timer open (flDuckTime > 0, the first second
//    after the press) as +jump arrives, moving faster than 50 u/s, and the
//    server's "slj" physinfo is set. So at a run with the module, the
//    sequence reverses: +duck first, +jump `duckLead` later with the duck
//    still held. The jump is then committed for at least `minJumpHold` even
//    if the flick ends sooner, so a quick flick still launches.
//
//  The choice is made once, as the gesture starts, and held to its end. A
//  long jump needs all of: the setting on, the module owned (the client's
//  copy of "slj", lambda_has_longjump), the gesture's own speed past
//  `longJumpIntent` (stick deflection or arm-swing speed, 0…1) and the
//  player actually moving at `longJumpMinSpeed`.
//
//  Ledge jumps: a long jump also goes higher than a crouch-jump (56 units of
//  rise instead of 45) and keeps the duck held through the flight, so it
//  still clears a ledge; it just carries ~560 u/s forward. The intent
//  threshold sits near full deflection so a ledge approached at anything
//  short of a full run keeps the crouch-jump, and the setting turns long
//  jumps off outright. Nothing here changes a speed: it only orders the two
//  buttons a keyboard player presses by hand.
//

nonisolated struct JumpSequencer {
    struct Tuning {
        var autoCrouchJump = true
        var autoDuckDelay: Double = 0.06
        var longJump = true
        /// Gesture speed (0…1: stick deflection, or arm-swing speed) at or
        /// above which a jump with the module becomes a long jump. 0.85 of
        /// the 18 cm stick is ~15 cm of reach: a deliberate full run.
        var longJumpIntent: Float = 0.85
        /// Ground speed (u/s) the player must already have. PM_Jump's own
        /// floor is 50; 200 is a run (stock full speed is sv_maxspeed 320).
        var longJumpMinSpeed: Float = 200
        /// +duck leads +jump by this much. Must cover at least one usercmd
        /// so PM_Duck sees the press first, and stay well under the duck
        /// timer's 1 s window.
        var duckLead: Double = 0.1
        /// The jump stays down at least this long once a long jump starts.
        var minJumpHold: Double = 0.1
    }

    enum Kind: Equatable { case idle, crouchJump, longJump }
    private(set) var kind: Kind = .idle
    private var start: Double = 0

    mutating func reset() { kind = .idle }

    /// One frame. `jump` = the gesture wants a jump now; `intent` its speed
    /// 0…1; `groundSpeed` the player's horizontal speed (u/s); `hasModule`
    /// whether the long jump module is owned. Returns the buttons to hold.
    mutating func update(jump: Bool, intent: Float, groundSpeed: Float, hasModule: Bool,
                         now: Double, tuning: Tuning) -> (jump: Bool, duck: Bool) {
        if kind == .idle {
            guard jump else { return (false, false) }
            start = now
            kind = (tuning.longJump && hasModule && intent >= tuning.longJumpIntent
                    && groundSpeed >= tuning.longJumpMinSpeed) ? .longJump : .crouchJump
        }
        let t = now - start
        switch kind {
        case .idle:
            return (false, false)
        case .crouchJump:
            guard jump else { kind = .idle; return (false, false) }
            return (true, tuning.autoCrouchJump && t >= tuning.autoDuckDelay)
        case .longJump:
            if !jump, t >= tuning.duckLead + tuning.minJumpHold {
                kind = .idle
                return (false, false)
            }
            return (t >= tuning.duckLead, true)
        }
    }
}
