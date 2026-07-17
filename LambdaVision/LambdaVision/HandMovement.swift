//
//  HandMovement.swift
//  LambdaVision
//
//  Left-hand (non-dominant) locomotion for the immersive gesture model.
//  Ported from an earlier app: a thumb+index pinch on the
//  off hand is a clutch that anchors the wrist; while held, the wrist's
//  displacement from that anchor drives a head-relative analog joystick,
//  fed to the engine via the same joy axes the gamepad uses. Our addition:
//  vertical wrist displacement past a deadzone triggers +jump (up) / +duck (down).
//
//  Runs once per frame on the render thread (like GamepadInput), gated by
//  the "Immersive gesture input" setting via Renderer.gestureInputEnabled.
//  Pinch detection is by ARKit joint proximity — hand-specific (no reliance
//  on spatial-event chirality) — with the same hysteresis / hold debounce /
//  fist suppressor so a clenched hand can't pinch by accident.
//

import ARKit
import simd

nonisolated final class HandMovement {
    nonisolated(unsafe) static let shared = HandMovement()

    // Pinch/joystick tuning. Enter/exit hysteresis is the "deadzone" that
    // rejects accidental pinches — the clutch engages immediately on a clean
    // pinch (no hold delay); a small joystick deadzone keeps a stationary
    // pinch from drifting.
    private let pinchEnter: Float = 0.025      // 2.5cm thumb↔index → engage
    private let pinchExit: Float  = 0.045      // 4.5cm → release (hysteresis)
    private let fistCurl: Float = 0.06         // fingertip↔metacarpal < 6cm = curled
    private let fullScaleM: Float = 0.18       // wrist 18cm from anchor = full speed
    nonisolated(unsafe) static var deadzoneM: Float = 0.03  // <3cm wrist travel = no move

    // Vertical jump/duck thresholds (our addition). Live-tunable.
    nonisolated(unsafe) static var jumpRiseM: Float = 0.13   // wrist up from anchor → +jump
    nonisolated(unsafe) static var duckDropM: Float = 0.13   // wrist down from anchor → +duck
    // Auto crouch-jump: HL needs a duck mid-jump to clear most ledges. On a
    // jump we hold +jump and add +duck a beat later (once airborne), so a
    // plain up-flick performs a full crouch-jump.
    nonisolated(unsafe) static var autoCrouchJump = true
    nonisolated(unsafe) static var autoDuckDelay: TimeInterval = 0.06

    private struct Pinch { var startTime: TimeInterval; var fired: Bool }
    private var jumpStart: TimeInterval = 0
    private var pinch: Pinch?
    private var anchorWrist: SIMD3<Float>?
    private var jumpHeld = false
    private var duckHeld = false
    private var axesActive = false   // wrote a non-zero joystick last frame
    private var logTick = 0          // throttle for [HM] debug logs

    /// Poll once per frame. `movementHand` is the non-dominant hand's anchor;
    /// `headForward`/`headRight` are Apple-world head axes (Y is flattened
    /// here). `active` = gesture input enabled AND not in a menu.
    func poll(active: Bool,
              movementHand: HandAnchor?,
              headForward: SIMD3<Float>,
              headRight: SIMD3<Float>,
              now: TimeInterval) {
        logTick += 1
        let doLog = (logTick % 30 == 0)   // ~3×/s, avoids per-frame spam

        guard active,
              let anchor = movementHand, anchor.isTracked,
              let skel = anchor.handSkeleton else {
            if doLog {
                print("[HM] inactive/no-hand: active=\(active) hand=\(movementHand != nil) "
                    + "tracked=\(movementHand?.isTracked ?? false) skel=\(movementHand?.handSkeleton != nil)")
            }
            Renderer.aimDiag.moveHandSeen = false
            Renderer.aimDiag.pinchDist = -1
            Renderer.aimDiag.fistCount = 0
            fullReset()
            return
        }

        let o = anchor.originFromAnchorTransform
        func jw(_ j: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = o * skel.joint(j).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        // Fist suppressor: 3+ fingertips curled to their metacarpal → a
        // clenched hand, not a pinch. Prevents accidental thumb brushes.
        let curls: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
            (.indexFingerTip,  .indexFingerMetacarpal),
            (.middleFingerTip, .middleFingerMetacarpal),
            (.ringFingerTip,   .ringFingerMetacarpal),
            (.littleFingerTip, .littleFingerMetacarpal),
        ]
        var curled = 0
        for (tip, meta) in curls where simd_distance(jw(tip), jw(meta)) < fistCurl { curled += 1 }

        // Thumb+index clutch with hysteresis + hold debounce.
        let idxDist = simd_distance(jw(.indexFingerTip), jw(.thumbTip))
        Renderer.aimDiag.moveHandSeen = true
        Renderer.aimDiag.pinchDist = idxDist
        Renderer.aimDiag.fistCount = curled

        if doLog {
            print(String(format: "[HM] hand=seen pinchDist=%.3f fist=%d fired=%@",
                         idxDist, curled, (pinch?.fired ?? false) ? "Y" : "N"))
        }

        if curled >= 3 { fullReset(); return }

        // Clutch: engage immediately on a clean pinch (no hold delay — the
        // enter/exit hysteresis is the deadzone that rejects accidental taps).
        // Still persist `pinch` across frames; only zeroMovement() (not
        // fullReset()) runs when disengaged, so the hysteresis stays coherent.
        if pinch != nil {
            if idxDist > pinchExit { pinch = nil }
        } else if idxDist < pinchEnter {
            pinch = Pinch(startTime: now, fired: true)
        }
        guard pinch != nil else { zeroMovement(); return }

        // Wrist delta from the anchor captured on the first engaged frame.
        let wrist = jw(.wrist)
        if anchorWrist == nil { anchorWrist = wrist }
        let delta = wrist - (anchorWrist ?? wrist)

        // Horizontal → analog joystick, projected onto the head-facing frame
        // (Y flattened) so it moves relative to gaze and survives snap turns.
        // A small deadzone keeps a stationary pinch from drifting.
        let fwd = normalizeSafe(SIMD3(headForward.x, 0, headForward.z))
        let right = normalizeSafe(SIMD3(headRight.x, 0, headRight.z))
        let s = simd_dot(delta, right)
        let f = simd_dot(delta, fwd)
        var x: Float = 0, y: Float = 0
        if (s * s + f * f).squareRoot() > HandMovement.deadzoneM {
            let scale = 1.0 / fullScaleM
            x = s * scale
            y = f * scale
            let mag = (x * x + y * y).squareRoot()
            if mag > 1 { x /= mag; y /= mag }
        }
        lambda_joy_set_axis(0, Int32((x * 32767).rounded()))    // side, + = right
        lambda_joy_set_axis(1, Int32((-y * 32767).rounded()))   // fwd (engine forward is negative)
        axesActive = true

        // Vertical → jump / duck past a deadzone, with auto crouch-jump:
        // a jump also holds +duck after a short delay (once airborne) so a
        // plain up-flick clears ledges the way a manual crouch-jump would.
        let dy = delta.y
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
    }

    /// Stop driving movement (zero joystick, drop jump/duck, re-anchor next
    /// engage) WITHOUT touching the clutch state machine — used while a pinch
    /// is still counting toward its hold, so the debounce can actually elapse.
    /// Idempotent.
    private func zeroMovement() {
        anchorWrist = nil
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

    /// Full reset: drop the clutch too. Only for a lost/inactive hand or a
    /// fist — never mid-hold, or the debounce would restart every frame.
    private func fullReset() {
        pinch = nil
        zeroMovement()
    }

    private func setHold(_ held: inout Bool, want: Bool, cmd: String) {
        guard want != held else { return }
        held = want
        let full = (want ? "+" : "-") + cmd
        _ = full.withCString { lambda_gl_worker_cmd($0) }
    }

    private func normalizeSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = simd_length(v)
        return l > 1e-5 ? v / l : SIMD3(0, 0, -1)
    }
}
