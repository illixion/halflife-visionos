//
//  GamepadInput.swift
//  LambdaVision
//
//  Extended-gamepad support, polled once per frame from the render loop
//  (a pattern carried over from an earlier app). Analog sticks feed the
//  engine's joystick axes via the bridge; buttons dispatch +/- console
//  commands on rising/falling edges; right-stick X turns the view, smoothly
//  by default (stock joy_yaw rate) or in snap-turn steps.
//
//  visionOS gotcha: a persistent valueChangedHandler must be registered and
//  the SwiftUI hierarchy needs .handlesGameControllerEvents(matching: .gamepad),
//  or the system keeps the pad for focus navigation and polled values freeze.
//  Two apps found that trap independently; RAVEGamepadSource now owns the
//  claiming half of the fix, and the view modifier remains the app's half.
//

import GameController
import QuartzCore
import RAVEInput
import DebugTrace

nonisolated final class GamepadInput {
    nonisolated(unsafe) static let shared = GamepadInput()

    private let source = RAVEGamepadSource { controller in
        AppLog.input.log("[LambdaVision] gamepad connected: \(controller.vendorName ?? "unknown", privacy: .public)")
    }

    // Rising/falling edge state, keyed by command name.
    private var edges = RAVEEdgeTracker<String>()
    private var prevSnapAxis: Float = 0
    private var hadPad = false
    // View/Options button: tap = quick save, hold = quick load.
    private var optionsDownAt: TimeInterval?
    private var optionsLoadFired = false

    private static let deadzone: Float = 0.15
    private static let snapThreshold: Float = 0.5
    /// Stick or trigger travel that counts as using the pad (input mode).
    private static let activityThreshold: Float = 0.3
    /// Hold the View/Options button this long to quick-load (a tap saves).
    static let quickLoadHoldSeconds: TimeInterval = 1.0

    /// Right stick turns smoothly (Settings > Input > Stick turning); off =
    /// snap turn by the snap-turn angle.
    nonisolated(unsafe) static var smoothTurn = true
    /// Smooth-turn rate at full deflection, degrees/second. The engine's own
    /// joystick turn (`joy_yaw`) defaults to 100.
    nonisolated(unsafe) static var turnSpeed: Float = 100

    /// Poll the current controller. Called every frame on the render thread.
    /// `snapTurn` receives ±1 on a right-stick snap edge; `turn` a smooth
    /// turn in degrees (+ = right) and `look` a pitch change in degrees
    /// (+ = down, xash), both already scaled by the frame time `dt`.
    func poll(dt: Float, snapTurn: (Float) -> Void, turn: (Float) -> Void, look: (Float) -> Void) {
        // Discovery is cheap enough to re-check per frame; GCController state
        // reads are snapshot-based and thread-agnostic.
        guard let pad = source.extendedGamepad() else {
            if hadPad {
                hadPad = false
                InputModeState.deviceGone(.gamepad)
            }
            return
        }
        hadPad = true
        noteActivity(pad)

        // --- movement: left stick → engine joystick axes ---
        let mx = pad.leftThumbstick.xAxis.value
        let my = pad.leftThumbstick.yAxis.value
        lambda_joy_set_axis(0, Self.axisValue(mx))   // SIDE (strafe)
        lambda_joy_set_axis(1, Self.axisValue(-my))  // FWD (engine: forward is negative)

        // --- turn: right stick X, smooth (linear, like the engine's
        // joystick yaw) or edge-triggered snap; Y looks up/down when the
        // "Look up/down" setting allows it (Renderer applies it outside
        // hands mode only).
        let sx = pad.rightThumbstick.xAxis.value
        if Self.smoothTurn {
            let v = Self.shaped(sx)
            if v != 0 { turn(v * Self.turnSpeed * dt) }
        } else if abs(sx) >= Self.snapThreshold, abs(prevSnapAxis) < Self.snapThreshold {
            snapTurn(sx > 0 ? 1 : -1)
        }
        prevSnapAxis = sx
        let sy = Self.shaped(pad.rightThumbstick.yAxis.value)
        if sy != 0 { look(-sy * Self.turnSpeed * dt) }

        // --- buttons/triggers → engine commands ---
        edge(pad.rightTrigger.isPressed,       "attack")
        edge(pad.leftTrigger.isPressed,        "attack2")
        edge(pad.buttonA.isPressed,            "jump")
        edge(pad.buttonB.isPressed,            "duck")
        edge(pad.buttonX.isPressed,            "reload")
        edge(pad.buttonY.isPressed,            "use")
        edge(pad.leftShoulder.isPressed,       "speed")

        oneShot(pad.rightShoulder.isPressed,   held: "lastinv",   cmd: "lastinv")
        oneShot(pad.dpad.left.isPressed,       held: "invprev",   cmd: "invprev")
        oneShot(pad.dpad.right.isPressed,      held: "invnext",   cmd: "invnext")
        oneShot(pad.dpad.up.isPressed,         held: "flash",     cmd: "impulse 100")
        oneShot(pad.buttonMenu.isPressed,      held: "escape",    cmd: "escape")
        quickSaveLoad(pad.buttonOptions?.isPressed ?? false)
    }

    /// View/Options: a tap quick-saves on release; holding it for
    /// `quickLoadHoldSeconds` quick-loads instead (and the release then does
    /// nothing), so a stray press never throws progress away.
    private func quickSaveLoad(_ pressed: Bool) {
        let now = CACurrentMediaTime()
        if pressed {
            if optionsDownAt == nil { optionsDownAt = now; optionsLoadFired = false }
            if !optionsLoadFired, let t = optionsDownAt, now - t >= Self.quickLoadHoldSeconds {
                optionsLoadFired = true
                _ = "loadquick".withCString { lambda_gl_worker_cmd($0) }
            }
        } else if optionsDownAt != nil {
            if !optionsLoadFired { _ = "savequick".withCString { lambda_gl_worker_cmd($0) } }
            optionsDownAt = nil
        }
    }

    /// Any button, or a stick or trigger past the activity threshold, makes
    /// the gamepad the device in use (InputModeState).
    private func noteActivity(_ pad: GCExtendedGamepad) {
        let t = Self.activityThreshold
        let sticks = [pad.leftThumbstick, pad.rightThumbstick]
        let moved = sticks.contains { abs($0.xAxis.value) > t || abs($0.yAxis.value) > t }
            || pad.leftTrigger.value > t || pad.rightTrigger.value > t
        let pressed = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
                       pad.leftShoulder, pad.rightShoulder, pad.buttonMenu]
            .contains { $0.isPressed }
            || pad.buttonOptions?.isPressed == true
            || pad.dpad.up.isPressed || pad.dpad.down.isPressed
            || pad.dpad.left.isPressed || pad.dpad.right.isPressed
        if moved || pressed { InputModeState.deviceUsed(.gamepad, now: CACurrentMediaTime()) }
    }

    /// Deadzone, then rescaled so the live range still reaches ±1.
    private static func shaped(_ v: Float) -> Float {
        let a = abs(v)
        guard a >= deadzone else { return 0 }
        return (v < 0 ? -1 : 1) * min((a - deadzone) / (1 - deadzone), 1)
    }

    /// +cmd on press, -cmd on release.
    private func edge(_ pressed: Bool, _ cmd: String) {
        switch edges.update(cmd, pressed: pressed) {
        case .steady: break
        case .began, .ended:
            let full = (pressed ? "+" : "-") + cmd
            _ = full.withCString { lambda_gl_worker_cmd($0) }
        }
    }

    /// Fire cmd once on the rising edge only.
    private func oneShot(_ pressed: Bool, held key: String, cmd: String) {
        guard edges.pressed(key, pressed) else { return }
        _ = cmd.withCString { lambda_gl_worker_cmd($0) }
    }

    private static func axisValue(_ v: Float) -> Int32 {
        if abs(v) < deadzone { return 0 }
        return Int32((max(-1, min(1, v)) * 32767).rounded())
    }
}
