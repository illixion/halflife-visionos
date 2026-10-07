//
//  MouseInput.swift
//  LambdaVision
//
//  A Bluetooth/USB mouse, read through RAVEInput's `RAVEMouseSource` (which
//  owns the GCMouse handlers: raw deltas, no pointer capture, events on the
//  main queue). This file is only the game's policy on top. Buttons and the wheel go
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
import RAVEInput

nonisolated final class MouseInput {
    nonisolated(unsafe) static let shared = MouseInput()

    /// Half-Life's `sensitivity` (Settings > Input > Mouse sensitivity).
    nonisolated(unsafe) static var sensitivity: Float = 3
    /// Stock `m_yaw` / `m_pitch`: degrees per count at sensitivity 1.
    static let degreesPerCount: Float = 0.022
    /// Spread each GCMouse delta over the render frames after it
    /// (MotionSmoother; Settings > Mouse smoothing). Read by the render thread.
    nonisolated(unsafe) static var smoothing = true
    /// The smoothing's mean delay, seconds.
    nonisolated(unsafe) static var smoothingSeconds: Float = 0.03

    // Arrival times of motion events (main queue), for GET /state.
    private var moveTimes = EventIntervalStats()

    // Motion accumulated between frames, GCMouse convention (+y = up).
    private let motion = RAVEMouseMotionAccumulator()
    // Main queue only (RAVEMouseSource delivers there).
    private var scroll = RAVEMouseStepAccumulator()
    private var subscription: RAVEMouseSubscription?
    // Buttons pressed while the lock prompt was up: their release is the
    // prompt's too (main queue only).
    private var swallowedButtons = Set<Int32>()

    /// Whether any mouse is connected (spatial pointer events stand down).
    static var connected: Bool { RAVEMouseSource.shared.isConnected }

    @MainActor func start() {
        guard subscription == nil else { return }
        subscription = RAVEMouseSource.shared.subscribe { event in
            MouseInput.shared.handle(event)
        }
    }

    @MainActor private func handle(_ event: RAVEMouseEvent) {
        // Counted for the input catcher's diagnostics (GET /state).
        InputCatcher.shared.recordMouse(event)
        switch event {
        case .connected(let name, _):
            AppLog.input.log("[LambdaVision] mouse connected: \(name ?? "unknown", privacy: .public)")
        case .disconnected(_, let count):
            AppLog.input.log("[LambdaVision] mouse disconnected")
            if count == 0, GCKeyboard.coalesced == nil {
                InputModeState.deviceGone(.keyboardMouse)
            }
        case .moved(let dx, let dy):
            moveTimes.record(CACurrentMediaTime())
            if InputCatcher.shared.swallowsGameMouse { return }
            motion.add(dx: dx, dy: dy)
            Self.used()
        case .button(let button, let pressed):
            let keynum: Int32
            switch button {
            case .left: keynum = 241                                   // K_MOUSE1
            case .right: keynum = 242                                  // K_MOUSE2
            case .middle: keynum = 243                                 // K_MOUSE3
            case .auxiliary(let i) where i < 2: keynum = Int32(244 + i) // K_MOUSE4/5
            case .auxiliary: return
            }
            if pressed, InputCatcher.shared.swallowsGameMouse { swallowedButtons.insert(keynum); return }
            if !pressed, swallowedButtons.remove(keynum) != nil { return }
            lambda_key_event(keynum, pressed ? 1 : 0)
            Self.used()
        case .scroll(_, let y):
            if InputCatcher.shared.swallowsGameMouse { return }
            // One wheel notch ≈ 1.0 of axis value. Each whole step is a press and
            // release of the wheel key, like a desktop wheel. Vertical only.
            let steps = scroll.add(y)
            guard steps != 0 else { return }
            let key: Int32 = steps > 0 ? 240 : 239   // K_MWHEELUP / K_MWHEELDOWN
            for _ in 0..<min(abs(steps), 4) {
                lambda_key_event(key, 1)
                lambda_key_event(key, 0)
            }
            Self.used()
        }
    }

    private static func used() {
        InputModeState.deviceUsed(.keyboardMouse, now: CACurrentMediaTime())
    }

    /// GCMouse motion events over the last second: rate, mean interval,
    /// jitter and worst gap (GET /state › mouseMotion). Main queue.
    @MainActor func moveStats() -> EventIntervalStats.Summary? {
        moveTimes.summary(now: CACurrentMediaTime())
    }

    /// The motion since the last call, in GCMouse units (+y = up). Render
    /// thread, once a frame.
    func takeMotion() -> (dx: Float, dy: Float) {
        motion.take()
    }
}
