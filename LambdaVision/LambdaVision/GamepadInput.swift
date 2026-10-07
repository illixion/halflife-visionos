//
//  GamepadInput.swift
//  LambdaVision
//
//  Extended-gamepad support, polled once per frame from the render loop
//  (a pattern carried over from an earlier app). Analog sticks feed the
//  engine's joystick axes via the bridge; buttons dispatch +/- console
//  commands on rising/falling edges; right-stick X turns the view, smoothly
//  by default (stock joy_yaw rate) or in snap-turn steps. Holding the left
//  shoulder opens the radial weapon menu (GamepadWheel). The layout is in
//  ControlsReference and the README.
//
//  visionOS gotcha: a persistent valueChangedHandler must be registered and
//  the SwiftUI hierarchy needs .handlesGameControllerEvents(matching: .gamepad),
//  or the system keeps the pad for focus navigation and polled values freeze.
//  That goes on EVERY window: whichever one the gaze rests on decides, so
//  one window without it (the Performance HUD stays open in play) is enough
//  to freeze a pushed stick.
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

    // Held +commands (released together on a handoff) and one-shot edges.
    private var holds = HeldCommands()
    private var edges = RAVEEdgeTracker<String>()
    private var prevSnapAxis: Float = 0
    private var hadPad = false
    /// Wrote a non-zero movement axis last poll (see `poll`).
    private var axesActive = false
    /// Right-stick click latches a crouch; B (hold) clears it.
    private var duckLatched = false
    /// Buttons down on the last poll, for edge-only activity (noteActivity).
    private var prevButtons: UInt32 = 0
    // View/Options button: tap = quick save, hold = quick load.
    private var optionsDownAt: TimeInterval?
    private var optionsLoadFired = false

    /// The radial weapon menu: hold the left shoulder, point the right stick,
    /// release to pick. Renderer draws it while open.
    private(set) var wheel = GamepadWheel()

    private static let deadzone: Float = 0.15
    static let snapThreshold: Float = 0.5
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
    /// `typing` = the game's menu or console is up (the wheel stays shut).
    /// `snapTurn` receives ±1 on a right-stick snap edge; `turn` a smooth
    /// turn in degrees (+ = right) and `look` a pitch change in degrees
    /// (+ = down, xash), both already scaled by the frame time `dt`.
    /// With `aim` (free aim, FreeAim.swift) the right stick goes there instead,
    /// smooth turning or not: yaw (+ = right) and pitch (+ = up) degrees at
    /// the turn speed, plus the raw stick X so the caller can snap-turn when
    /// the aim is pinned at the zone's edge.
    func poll(dt: Float, typing: Bool = false, snapTurn: (Float) -> Void, turn: (Float) -> Void, look: (Float) -> Void,
              aim: ((_ yaw: Float, _ pitch: Float, _ stickX: Float) -> Void)? = nil) {
        // Discovery is cheap enough to re-check per frame; GCController state
        // reads are snapshot-based and thread-agnostic.
        guard let pad = source.extendedGamepad() else {
            if hadPad {
                hadPad = false
                releaseAll()
                InputModeState.deviceGone(.gamepad)
            }
            return
        }
        hadPad = true
        noteActivity(pad)
        let now = CACurrentMediaTime()

        // --- movement: left stick → engine joystick axes ---
        // Written every poll while the pad is the input mode; otherwise only
        // while the stick is pushed (and once more as it returns), so a
        // resting pad doesn't keep zeroing the hand stick, which writes the
        // same axes.
        let ax = Self.axisValue(pad.leftThumbstick.xAxis.value)    // SIDE (strafe)
        let ay = Self.axisValue(-pad.leftThumbstick.yAxis.value)   // FWD (engine: forward is negative)
        if InputModeState.current == .gamepad || ax != 0 || ay != 0 || axesActive {
            lambda_joy_set_axis(0, ax)
            lambda_joy_set_axis(1, ay)
            axesActive = ax != 0 || ay != 0
        }

        // --- radial weapon menu: left shoulder held. While it is open the
        // right stick points at a sector instead of turning.
        let rs = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        if let picked = wheel.update(held: pad.leftShoulder.isPressed && !typing, stick: rs, now: now,
                                     makeEntries: { Renderer.weaponWheelEntries() }) {
            _ = WeaponWheel.command(for: picked.action).withCString { lambda_gl_worker_cmd($0) }
            AppLog.input.debug("[Wheel] pad picked \(picked.label, privacy: .public)")
        }

        // --- turn: right stick X, smooth (linear, like the engine's
        // joystick yaw) or edge-triggered snap; Y looks up/down when the
        // "Look up/down" setting allows it (Renderer applies it outside
        // hands mode only).
        let sx = wheel.isOpen ? 0 : rs.x
        if let aim {
            // Free aim: the stick swings the aim (rate control); the caller
            // turns the body with what spills past the zone.
            let vx = Self.shaped(sx), vy = wheel.isOpen ? 0 : Self.shaped(rs.y)
            aim(vx * Self.turnSpeed * dt, vy * Self.turnSpeed * dt, sx)
        } else {
            if Self.smoothTurn {
                let v = Self.shaped(sx)
                if v != 0 { turn(v * Self.turnSpeed * dt) }
            } else if abs(sx) >= Self.snapThreshold, abs(prevSnapAxis) < Self.snapThreshold {
                snapTurn(sx > 0 ? 1 : -1)
            }
            let sy = wheel.isOpen ? 0 : Self.shaped(rs.y)
            if sy != 0 { look(-sy * Self.turnSpeed * dt) }
        }
        prevSnapAxis = sx

        // --- buttons/triggers → engine commands ---
        hold(pad.rightTrigger.isPressed,       "attack")
        hold(pad.leftTrigger.isPressed,        "attack2")
        hold(pad.buttonA.isPressed,            "jump")
        hold(pad.buttonX.isPressed,            "reload")
        hold(pad.buttonY.isPressed,            "use")
        // Left-stick click: walk while held (+speed, the desktop Shift).
        hold(pad.leftThumbstickButton?.isPressed ?? false, "speed")
        // Crouch: B holds it; a right-stick click toggles it on or off, and
        // pressing B drops a toggled crouch (it stays down while B is held).
        if edges.pressed("duckToggle", pad.rightThumbstickButton?.isPressed ?? false) { duckLatched.toggle() }
        if edges.pressed("duckHold", pad.buttonB.isPressed) { duckLatched = false }
        hold(pad.buttonB.isPressed || duckLatched, "duck")

        oneShot(pad.rightShoulder.isPressed,   held: "lastinv",   cmd: "lastinv")
        oneShot(pad.dpad.left.isPressed,       held: "invprev",   cmd: "invprev")
        oneShot(pad.dpad.right.isPressed,      held: "invnext",   cmd: "invnext")
        oneShot(pad.dpad.up.isPressed,         held: "flash",     cmd: "impulse 100")
        oneShot(pad.dpad.down.isPressed,       held: "spray",     cmd: "impulse 201")
        oneShot(pad.buttonMenu.isPressed,      held: "escape",    cmd: "escape")
        quickSaveLoad(pad.buttonOptions?.isPressed ?? false)
    }

    /// Let go of everything the pad holds: the input mode moved to another
    /// device (InputHandoff) or the pad went away. Buttons still held stay
    /// quiet until they are pressed again (HeldCommands), the wheel closes
    /// without picking, and the movement axes are zeroed.
    func releaseAll() {
        for cmd in holds.releaseAll() { _ = cmd.withCString { lambda_gl_worker_cmd($0) } }
        duckLatched = false
        wheel.cancel()
        optionsDownAt = nil
        if axesActive {
            lambda_joy_set_axis(0, 0)
            lambda_joy_set_axis(1, 0)
            axesActive = false
        }
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

    /// A button press, or a stick or trigger past the activity threshold,
    /// makes the gamepad the device in use (InputModeState). Buttons count
    /// on the press only: a trigger left held while the mouse moves would
    /// otherwise pull the mode straight back every frame.
    private func noteActivity(_ pad: GCExtendedGamepad) {
        let t = Self.activityThreshold
        let sticks = [pad.leftThumbstick, pad.rightThumbstick]
        let moved = sticks.contains { abs($0.xAxis.value) > t || abs($0.yAxis.value) > t }
            || pad.leftTrigger.value > t || pad.rightTrigger.value > t
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.leftShoulder, pad.rightShoulder, pad.buttonMenu, pad.buttonOptions,
            pad.leftThumbstickButton, pad.rightThumbstickButton,
            pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right]
        var down: UInt32 = 0
        for (i, b) in buttons.enumerated() where b?.isPressed == true { down |= 1 << i }
        let pressed = down & ~prevButtons != 0
        prevButtons = down
        if moved || pressed { InputModeState.deviceUsed(.gamepad, now: CACurrentMediaTime()) }
    }

    /// Deadzone, then rescaled so the live range still reaches ±1.
    private static func shaped(_ v: Float) -> Float {
        let a = abs(v)
        guard a >= deadzone else { return 0 }
        return (v < 0 ? -1 : 1) * min((a - deadzone) / (1 - deadzone), 1)
    }

    /// +cmd on press, -cmd on release (HeldCommands).
    private func hold(_ pressed: Bool, _ cmd: String) {
        if let full = holds.update(cmd, pressed: pressed) {
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
