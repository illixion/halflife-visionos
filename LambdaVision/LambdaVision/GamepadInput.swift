//
//  GamepadInput.swift
//  LambdaVision
//
//  Extended-gamepad support, polled once per frame from the render loop
//  (a pattern carried over from an earlier app). Analog sticks feed the
//  engine's joystick axes via the bridge; buttons dispatch +/- console
//  commands on rising/falling edges; right-stick X does 30° snap turns.
//
//  visionOS gotcha: a persistent valueChangedHandler must be registered and
//  the SwiftUI hierarchy needs .handlesGameControllerEvents(matching: .gamepad),
//  or the system keeps the pad for focus navigation and polled values freeze.
//  Two apps found that trap independently; RAVEGamepadSource now owns the
//  claiming half of the fix, and the view modifier remains the app's half.
//

import GameController
import RAVEInput

nonisolated final class GamepadInput {
    nonisolated(unsafe) static let shared = GamepadInput()

    private let source = RAVEGamepadSource { controller in
        AppLog.input.line("[LambdaVision] gamepad connected: \(controller.vendorName ?? "unknown")")
    }

    // Rising/falling edge state, keyed by command name.
    private var edges = RAVEEdgeTracker<String>()
    private var prevSnapAxis: Float = 0

    private static let deadzone: Float = 0.15
    private static let snapThreshold: Float = 0.5

    /// Poll the current controller. Called every frame on the render thread.
    /// `snapTurn` receives ±1 on a right-stick snap edge.
    func poll(snapTurn: (Float) -> Void) {
        // Discovery is cheap enough to re-check per frame; GCController state
        // reads are snapshot-based and thread-agnostic.
        guard let pad = source.extendedGamepad() else { return }

        // --- movement: left stick → engine joystick axes ---
        let mx = pad.leftThumbstick.xAxis.value
        let my = pad.leftThumbstick.yAxis.value
        lambda_joy_set_axis(0, Self.axisValue(mx))   // SIDE (strafe)
        lambda_joy_set_axis(1, Self.axisValue(-my))  // FWD (engine: forward is negative)

        // --- snap turn: right stick X, edge-triggered ---
        let sx = pad.rightThumbstick.xAxis.value
        if abs(sx) >= Self.snapThreshold, abs(prevSnapAxis) < Self.snapThreshold {
            snapTurn(sx > 0 ? 1 : -1)
        }
        prevSnapAxis = sx

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
