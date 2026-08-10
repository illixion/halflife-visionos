//
//  HandMovement.swift
//  LambdaVision
//
//  Off-hand (non-dominant) interaction for the immersive gesture model:
//
//  • Locomotion (the pinch clutch and wrist joystick come from RAVE Engine's
//    RAVEInput, shared with Spatialcraft and Longwave): a thumb+index
//    pinch is a clutch that anchors the wrist; while held, wrist
//    displacement drives a head-relative analog joystick via the same joy
//    axes the gamepad uses. Vertical displacement past a deadzone triggers
//    +jump / +duck (with auto crouch-jump).
//
//  • Immersive +use: reaching the hand out forward with the index extended
//    (poke) or the whole palm open (rest on a charger) holds +use; the
//    eye→fingertip ray is returned to the caller, which stages it as the
//    PlayerUse cone override so the entity under the finger is what gets
//    used. Continuous-use stations (health/HEV chargers) work by keeping
//    the hand rested out; retracting or curling releases.
//
//  • Train throttle: while the server reports the player controlling a
//    train (lambda_train_state), locomotion is SUPPRESSED — the engine
//    dismounts on strafe/jump buttons, so the joystick would randomly
//    throw the player off the controls — and the pinch clutch becomes a
//    throttle stick instead: forward/back displacement from the grab
//    point (room-space axis captured at grab, immune to the train
//    rotating the game view) selects a target gear (-1..3) staged via
//    lambda_set_train_gear. A gear-ladder gauge is published for the
//    weapon pass to draw.
//
//  Runs once per frame on the render thread (like GamepadInput), gated by
//  the "Immersive gesture input" setting via Renderer.gestureInputEnabled.
//

import ARKit
import RAVEInput
import simd

nonisolated final class HandMovement {
    nonisolated(unsafe) static let shared = HandMovement()

    // Pinch/joystick tuning lives in RAVEInput now — `.clutch` is the shared
    // tuning for exactly this shape of gesture: index finger only, engaging the
    // instant the fingers touch, with the 2.5/4.5cm enter/exit hysteresis as
    // the whole filter. A hold debounce would read as input lag on locomotion,
    // which is why the shared `.standard` tuning (used where a pinch presses a
    // button) is the wrong one here.
    private let fistCurl: Float = 0.06         // fingertip↔metacarpal < 6cm = curled
    nonisolated(unsafe) static var deadzoneM: Float = 0.03  // <3cm wrist travel = no move

    // Vertical jump/duck thresholds (our addition). Live-tunable.
    nonisolated(unsafe) static var jumpRiseM: Float = 0.13   // wrist up from anchor → +jump
    nonisolated(unsafe) static var duckDropM: Float = 0.13   // wrist down from anchor → +duck
    // Auto crouch-jump: HL needs a duck mid-jump to clear most ledges. On a
    // jump we hold +jump and add +duck a beat later (once airborne), so a
    // plain up-flick performs a full crouch-jump.
    nonisolated(unsafe) static var autoCrouchJump = true
    nonisolated(unsafe) static var autoDuckDelay: TimeInterval = 0.06

    // Immersive +use tuning. "Reach" is the fingertip's FORWARD distance
    // from the head (projected on head-forward, so hands hanging at the
    // sides never trigger), with hysteresis. The pose gate needs the index
    // extended (poke) or the whole hand open (palm rest); the ray must
    // also roughly agree with where the player looks.
    nonisolated(unsafe) static var useReachOn: Float = 0.35
    nonisolated(unsafe) static var useReachOff: Float = 0.28
    nonisolated(unsafe) static var useFingerExt: Float = 0.08  // tip↔metacarpal > this = extended
    nonisolated(unsafe) static var useGazeDot: Float = 0.75    // eye→tip vs head-forward agreement

    // Train throttle tuning: gear zones every 6cm of forward/back travel
    // from the grab point, relative to the gear held when grabbed.
    nonisolated(unsafe) static var throttleNotchM: Float = 0.06

    /// Gear-ladder gauge for the weapon pass: world position of the grab
    /// point, current gear and armed target (-1..3). nil = no throttle held.
    struct ThrottleGauge {
        var center: SIMD3<Float>
        var gear: Int
        var target: Int
    }
    nonisolated(unsafe) static var throttleGauge: ThrottleGauge? = nil

    private var pinchDetector = RAVEPinchDetector(tuning: .clutch)
    private var joystick = RAVEHandJoystick(
        fullScaleMeters: 0.18,                 // wrist 18cm from anchor = full speed
        deadzoneMeters: HandMovement.deadzoneM
    )
    private var jumpStart: TimeInterval = 0
    private var clutchHeld = false
    private var jumpHeld = false
    private var duckHeld = false
    private var useHeld = false
    private var axesActive = false   // wrote a non-zero joystick last frame
    private var trainGearStaged = false  // lambda_set_train_gear ≠ 99 outstanding
    private var throttleAnchor: SIMD3<Float>?
    private var throttleAxis = SIMD3<Float>(0, 0, -1)
    private var throttleGrabGear = 0
    private var logTick = 0          // throttle for [HM] debug logs

    /// Poll once per frame. `movementHand` is the non-dominant hand's anchor;
    /// `headForward`/`headRight` are Apple-world head axes (Y is flattened
    /// for locomotion), `headPos` the head position. `active` = gesture
    /// input enabled AND not in a menu. `onTrain`/`trainGear` mirror the
    /// server's lambda_train_state. Returns the eye→fingertip use ray
    /// (Apple world) while +use is held, else nil.
    func poll(active: Bool,
              movementHand: HandAnchor?,
              headForward: SIMD3<Float>,
              headRight: SIMD3<Float>,
              headPos: SIMD3<Float>,
              onTrain: Bool,
              trainGear: Int,
              now: TimeInterval) -> SIMD3<Float>? {
        logTick += 1
        let doLog = (logTick % 30 == 0)   // ~3×/s, avoids per-frame spam

        // One framework-free snapshot of the joints, taken once per frame. Every
        // measurement below reads from it instead of re-walking the skeleton,
        // and it is what lets the shared pinch/joystick code run here at all —
        // both are plain value types with no isolation, so they work the same
        // on this render thread as they do on another app's main actor.
        guard active,
              let anchor = movementHand, anchor.isTracked,
              let hand = RAVEHandSample(anchor) else {
            if doLog {
                print("[HM] inactive/no-hand: active=\(active) hand=\(movementHand != nil) "
                    + "tracked=\(movementHand?.isTracked ?? false) skel=\(movementHand?.handSkeleton != nil)")
            }
            Renderer.aimDiag.moveHandSeen = false
            Renderer.aimDiag.pinchDist = -1
            Renderer.aimDiag.fistCount = 0
            fullReset()
            return nil
        }

        // Per-finger curl (tip↔metacarpal). Used by the fist suppressor,
        // the poke pose (index out, rest curled is FINE) and the palm pose.
        let curled = hand.curledFingerCount(threshold: fistCurl)
        let extended = hand.extendedFingerCount(threshold: HandMovement.useFingerExt)
        let indexExtended = hand.index.extension_ > HandMovement.useFingerExt

        let wrist = hand.wrist
        let idxDist = hand.pinchDistance(to: .index)
        Renderer.aimDiag.moveHandSeen = true
        Renderer.aimDiag.pinchDist = idxDist
        Renderer.aimDiag.fistCount = curled

        // --- Immersive +use (independent of the clutch) ---------------------
        // Poke = index extended; palm = everything extended. Both need the
        // fingertip reached out forward and the ray to agree with the view.
        // The pinch clutch and +use are mutually exclusive: a pinched hand
        // is driving (or throttling), not pressing.
        let indexTip = hand.index.tip
        let toTip = indexTip - headPos
        let fwdReach = simd_dot(toTip, headForward)
        let rayDir = simd_normalize(toTip)
        let gazeAgree = simd_dot(rayDir, simd_normalize(headForward))
        let poseOK = indexExtended || extended >= 4
        var wantUse = useHeld
        if clutchHeld || !poseOK || gazeAgree < HandMovement.useGazeDot {
            wantUse = false
        } else if fwdReach > HandMovement.useReachOn {
            wantUse = true
        } else if fwdReach < HandMovement.useReachOff {
            wantUse = false
        }
        setHold(&useHeld, want: wantUse, cmd: "use")
        Renderer.aimDiag.useReach = fwdReach
        Renderer.aimDiag.useHeld = useHeld

        if doLog {
            print(String(format: "[HM] hand=seen pinch=%.3f fist=%d reach=%.2f use=%@ train=%@",
                         idxDist, curled, fwdReach, useHeld ? "Y" : "N", onTrain ? "Y" : "N"))
        }

        // --- Clutch (locomotion or throttle) --------------------------------
        // The shared detector owns the fist suppressor (3+ curled fingertips =
        // a clenched hand, or a poke pose — never a pinch) and the enter/exit
        // hysteresis. Feeding it `nil` while +use is held is how "a pressing
        // hand is not a driving hand" is expressed: the clutch drops, +use
        // above is untouched, and the hysteresis resets cleanly rather than
        // half-remembering a pinch through the press.
        clutchHeld = pinchDetector.update(sample: useHeld ? nil : hand, now: now).held != nil
        guard clutchHeld else {
            zeroMovement()
            releaseThrottle()
            return useHeld ? rayDir : nil
        }

        if onTrain {
            // Throttle stick: grab anywhere, push forward / pull back to
            // step gears relative to the gear you grabbed at. The axis is
            // captured at grab time in ROOM space, so a turning train
            // (which rotates the rendered world while driving) can't make
            // the stick drift under the hand.
            zeroMovement()   // never feed joystick/jump/duck to a train
            if throttleAnchor == nil {
                throttleAnchor = wrist
                throttleAxis = simd_normalize(SIMD3(headForward.x, 0, headForward.z))
                throttleGrabGear = trainGear
            }
            let d = simd_dot(wrist - throttleAnchor!, throttleAxis)
            let target = max(-1, min(3, throttleGrabGear + Int((d / HandMovement.throttleNotchM).rounded())))
            lambda_set_train_gear(Int32(target))
            trainGearStaged = true
            HandMovement.throttleGauge = ThrottleGauge(center: throttleAnchor!,
                                                       gear: trainGear, target: target)
            Renderer.aimDiag.moveClutch = true
            Renderer.aimDiag.moveVert = "gear \(target)"
            return nil
        }
        releaseThrottle()

        // Horizontal wrist delta → analog joystick, projected onto the
        // head-facing frame (Y flattened) so it moves relative to gaze and
        // survives snap turns. The anchor is captured on the first engaged
        // frame; a small deadzone keeps a stationary pinch from drifting.
        joystick.deadzoneMeters = HandMovement.deadzoneM   // live-tunable
        let stick = joystick.update(
            wristWorld: wrist,
            engaged: true,
            worldForward: headForward,
            worldRight: headRight
        )
        let x = stick.vector.x
        let y = stick.vector.y
        lambda_joy_set_axis(0, Int32((x * 32767).rounded()))    // side, + = right
        lambda_joy_set_axis(1, Int32((-y * 32767).rounded()))   // fwd (engine forward is negative)
        axesActive = true

        // Vertical → jump / duck past a deadzone, with auto crouch-jump:
        // a jump also holds +duck after a short delay (once airborne) so a
        // plain up-flick clears ledges the way a manual crouch-jump would.
        // Read off the raw delta, which the horizontal deadzone must not eat.
        let dy = stick.delta.y
        let wantJump = dy > HandMovement.jumpRiseM
        if wantJump && !jumpHeld { jumpStart = now }   // rising edge
        let autoDuck = HandMovement.autoCrouchJump && wantJump
                     && (now - jumpStart) >= HandMovement.autoDuckDelay
        setHold(&jumpHeld, want: wantJump, cmd: "jump")
        setHold(&duckHeld, want: (dy < -HandMovement.duckDropM) || autoDuck, cmd: "duck")

        Renderer.aimDiag.moveClutch = true
        Renderer.aimDiag.joyX = x
        Renderer.aimDiag.joyY = y
        Renderer.aimDiag.moveVert = jumpHeld ? "jump" : (duckHeld ? "duck" : "—")
        return nil
    }

    /// Stop driving movement (zero joystick, drop jump/duck, re-anchor next
    /// engage) WITHOUT touching the clutch state machine — used while a pinch
    /// is disengaged, so the enter/exit hysteresis stays coherent. Idempotent.
    private func zeroMovement() {
        joystick.release()
        if axesActive {
            lambda_joy_set_axis(0, 0)
            lambda_joy_set_axis(1, 0)
            axesActive = false
        }
        setHold(&jumpHeld, want: false, cmd: "jump")
        setHold(&duckHeld, want: false, cmd: "duck")
        Renderer.aimDiag.moveClutch = false
        Renderer.aimDiag.joyX = 0
        Renderer.aimDiag.joyY = 0
        Renderer.aimDiag.moveVert = "—"
    }

    /// Drop the throttle grab: un-stage the target gear (99 = no gesture)
    /// and hide the gauge. Idempotent.
    private func releaseThrottle() {
        if trainGearStaged {
            lambda_set_train_gear(99)
            trainGearStaged = false
        }
        throttleAnchor = nil
        HandMovement.throttleGauge = nil
    }

    /// Full reset: drop the clutch, throttle and +use too. Only for a
    /// lost/inactive hand — never mid-hold, or the hysteresis would restart
    /// every frame.
    private func fullReset() {
        pinchDetector.reset()
        clutchHeld = false
        zeroMovement()
        releaseThrottle()
        setHold(&useHeld, want: false, cmd: "use")
        Renderer.aimDiag.useHeld = false
    }

    private func setHold(_ held: inout Bool, want: Bool, cmd: String) {
        guard want != held else { return }
        held = want
        let full = (want ? "+" : "-") + cmd
        _ = full.withCString { lambda_gl_worker_cmd($0) }
    }

}
