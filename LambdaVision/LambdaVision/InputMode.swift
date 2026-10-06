//
//  InputMode.swift
//  LambdaVision
//
//  The one switch between hand tracking and a flat-game controller. With a
//  keyboard and mouse, or a gamepad, the game plays like desktop Half-Life
//  in stereo: the weapon is the stock viewmodel at the usual view offset,
//  shots go along the view (zero aim offset), the body's arms stop following
//  the tracked hands and the hand gestures stand down. In hands mode all of
//  that comes from the tracked hands, as before.
//
//  Auto picks the last device used. A key, a mouse move or click, or a
//  gamepad button or stick switches at once. Hands come back on a deliberate
//  hand action, a look-and-pinch, once no device has been touched for a
//  moment, or when the device in use disconnects. Resting idle never flips
//  the mode, so a keyboard player who stops to look around keeps the gun on
//  the view.
//
//  Written from the input threads, read by the render thread: plain scalars
//  with benign tearing, like Renderer's other cross-thread knobs.
//

import Foundation

nonisolated enum InputMode: String {
    case hands, keyboardMouse, gamepad

    var label: String {
        switch self {
        case .hands: "hands"
        case .keyboardMouse: "keyboard+mouse"
        case .gamepad: "gamepad"
        }
    }
}

/// The Settings override (Settings > Input > Input mode).
nonisolated enum InputModeSetting: String, CaseIterable, Identifiable {
    case auto, hands, keyboardMouse, gamepad
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .hands: "Hands"
        case .keyboardMouse: "Keyboard + mouse"
        case .gamepad: "Gamepad"
        }
    }

    /// The mode this setting pins, or nil for Auto.
    var forced: InputMode? {
        switch self {
        case .auto: nil
        case .hands: .hands
        case .keyboardMouse: .keyboardMouse
        case .gamepad: .gamepad
        }
    }
}

/// The auto-selection rule, kept free of clocks and globals.
nonisolated struct InputModeSelector {
    /// How long after the last keyboard, mouse or gamepad input a pinch
    /// still counts as a slip rather than a request for hands.
    static let handsReclaimSeconds: TimeInterval = 1.0

    private(set) var mode: InputMode = .hands
    private(set) var lastDeviceTime: TimeInterval = -.infinity

    mutating func deviceUsed(_ device: InputMode, now: TimeInterval) {
        guard device != .hands else { return handsUsed(now: now) }
        mode = device
        lastDeviceTime = now
    }

    /// A deliberate hand action. Takes hands back unless a device was used
    /// within the last `handsReclaimSeconds`.
    mutating func handsUsed(now: TimeInterval) {
        if now - lastDeviceTime >= Self.handsReclaimSeconds { mode = .hands }
    }

    /// The last device of a kind went away: back to hands if it was in use.
    mutating func deviceGone(_ device: InputMode) {
        if mode == device { mode = .hands }
    }
}

nonisolated enum InputModeState {
    nonisolated(unsafe) static var setting: InputModeSetting = .auto
    nonisolated(unsafe) private static var selector = InputModeSelector()
    nonisolated(unsafe) private static var lastDevice: [InputMode: TimeInterval] = [:]
    private static let lock = NSLock()

    /// The mode in force: the Settings override, else the auto pick.
    static var current: InputMode { setting.forced ?? selector.mode }

    static func deviceUsed(_ device: InputMode, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        selector.deviceUsed(device, now: now)
        lastDevice[device] = now
    }

    static func deviceGone(_ device: InputMode) {
        lock.lock(); defer { lock.unlock() }
        selector.deviceGone(device)
    }

    /// Diagnostics line: the mode, why, and when each device last spoke.
    static func diagLine(now: TimeInterval) -> String {
        lock.lock(); defer { lock.unlock() }
        func ago(_ m: InputMode) -> String {
            guard let t = lastDevice[m] else { return "—" }
            return String(format: "%.0fs", max(now - t, 0))
        }
        let mode = setting.forced ?? selector.mode
        return "input mode: \(mode.label) (\(setting == .auto ? "auto" : "set"))"
            + "  last kb/mouse \(ago(.keyboardMouse)) pad \(ago(.gamepad)) hands \(ago(.hands))"
    }
}
