//
//  MouseInput.swift
//  LambdaVision
//
//  A Bluetooth/USB mouse via GameController's GCMouse, the only way to read
//  one on visionOS (raw deltas, no pointer capture). Buttons and the wheel go
//  to the engine as real key events (K_MOUSE1…5, K_MWHEELUP/DOWN), so the
//  stock binds apply in game (mouse1 = +attack, mouse2 = +attack2, the wheel
//  cycles weapons) and the engine routes clicks to the menu when it's up.
//
//  Motion is ours to apply, because the app launches with -noenginemouse
//  (the engine's own mouse path would overwrite the synthetic menu cursor;
//  see Renderer's engine args). The render thread drains it once a frame
//  (`takeMotion`): it moves the menu cursor while the menu is up, does
//  nothing while the console is down, and otherwise turns the view the way
//  snap turn does, smoothly, at stock Half-Life scale (sensitivity × m_yaw
//  0.022° per count).
//

import GameController
import QuartzCore
import DebugTrace

nonisolated final class MouseInput {
    nonisolated(unsafe) static let shared = MouseInput()

    /// Half-Life's `sensitivity` (Settings > Input > Mouse sensitivity).
    nonisolated(unsafe) static var sensitivity: Float = 3
    /// Stock `m_yaw` / `m_pitch`: degrees per count at sensitivity 1.
    static let degreesPerCount: Float = 0.022

    // Motion accumulated between frames, GCMouse convention (+y = up).
    private var dx: Float = 0
    private var dy: Float = 0
    private let lock = NSLock()
    private var scrollAccum: Float = 0
    private var mice: [GCMouse] = []
    private var observers: [NSObjectProtocol] = []

    /// Whether any mouse is connected (spatial pointer events stand down).
    nonisolated(unsafe) private(set) static var connected = false

    @MainActor func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect, object: nil, queue: .main) { note in
                guard let m = note.object as? GCMouse else { return }
                MouseInput.shared.attach(m)
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect, object: nil, queue: .main) { note in
                guard let m = note.object as? GCMouse else { return }
                MouseInput.shared.detach(m)
            })
        for m in GCMouse.mice() { attach(m) }
    }

    private func attach(_ mouse: GCMouse) {
        guard !mice.contains(where: { $0 === mouse }), let input = mouse.mouseInput else { return }
        mice.append(mouse)
        Self.connected = true
        AppLog.input.log("[LambdaVision] mouse connected: \(mouse.vendorName ?? "unknown", privacy: .public)")

        input.mouseMovedHandler = { _, x, y in
            let s = MouseInput.shared
            s.lock.lock()
            s.dx += x
            s.dy += y
            s.lock.unlock()
            MouseInput.used()
        }
        input.leftButton.pressedChangedHandler = Self.button(241)            // K_MOUSE1
        input.rightButton?.pressedChangedHandler = Self.button(242)          // K_MOUSE2
        input.middleButton?.pressedChangedHandler = Self.button(243)         // K_MOUSE3
        if let aux = input.auxiliaryButtons {
            for (i, b) in aux.prefix(2).enumerated() {
                b.pressedChangedHandler = Self.button(Int32(244 + i))         // K_MOUSE4/5
            }
        }
        // One wheel notch ≈ 1.0 of axis value. Each whole step is a press and
        // release of the wheel key, like a desktop wheel.
        input.scroll.yAxis.valueChangedHandler = { _, value in
            let s = MouseInput.shared
            s.lock.lock()
            s.scrollAccum += value
            let steps = Int(s.scrollAccum)
            s.scrollAccum -= Float(steps)
            s.lock.unlock()
            guard steps != 0 else { return }
            let key: Int32 = steps > 0 ? 240 : 239   // K_MWHEELUP / K_MWHEELDOWN
            for _ in 0..<min(abs(steps), 4) {
                lambda_key_event(key, 1)
                lambda_key_event(key, 0)
            }
            MouseInput.used()
        }
    }

    private func detach(_ mouse: GCMouse) {
        if let input = mouse.mouseInput {
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
            input.scroll.yAxis.valueChangedHandler = nil
        }
        mice.removeAll { $0 === mouse }
        Self.connected = !mice.isEmpty
        AppLog.input.log("[LambdaVision] mouse disconnected")
        if mice.isEmpty, GCKeyboard.coalesced == nil {
            InputModeState.deviceGone(.keyboardMouse)
        }
    }

    private static func button(_ keynum: Int32) -> GCControllerButtonValueChangedHandler {
        { _, _, pressed in
            lambda_key_event(keynum, pressed ? 1 : 0)
            MouseInput.used()
        }
    }

    private static func used() {
        InputModeState.deviceUsed(.keyboardMouse, now: CACurrentMediaTime())
    }

    /// The motion since the last call, in GCMouse units (+y = up). Render
    /// thread, once a frame.
    func takeMotion() -> (dx: Float, dy: Float) {
        lock.lock(); defer { lock.unlock() }
        let m = (dx, dy)
        dx = 0; dy = 0
        return m
    }
}
