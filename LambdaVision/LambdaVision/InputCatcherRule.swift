//
//  InputCatcherRule.swift
//  LambdaVision
//
//  The input catcher's pure parts (InputCatcher.swift is the window and its
//  lifecycle): when the catcher should be up, and a rolling events-per-second
//  counter for the mouse diagnostics. Foundation only, no clocks or globals,
//  so Tools/CatcherProbe checks them on the Mac against this very file.
//

import Foundation

/// Everything the "should the catcher be up?" decision reads, sampled on the
/// main actor a few times a second.
nonisolated struct InputCatcherInputs: Equatable {
    var enabled: Bool
    var immersiveOpen: Bool
    var engineReady: Bool
    var inGame: Bool
    var loading: Bool
    var menuOpen: Bool
    var consoleOpen: Bool
    var mode: InputMode
    var setting: InputModeSetting
    var mouseConnected: Bool
    /// When a mouse last connected, and when the hands last bid for the
    /// input mode (a look-and-pinch), on one clock. nil = never.
    var mouseConnectedAt: TimeInterval?
    var lastHandsAt: TimeInterval?
}

nonisolated enum InputCatcherRule {
    /// Whether the catcher should be up, and a short reason for the logs and
    /// GET /state.
    ///
    /// Up in game, in the immersive space, with no menu or console, when
    /// either the mode is keyboard+mouse, or (Auto) a mouse is connected and
    /// the hands haven't bid since it connected. The second case breaks a
    /// chicken-and-egg: mouse events are what switch Auto to keyboard+mouse,
    /// and without the catcher they never arrive. A look-and-pinch on the
    /// catcher is a hands bid, so a hands player takes it down with the
    /// first pinch (which doesn't fire; see InputCatcher).
    static func evaluate(_ i: InputCatcherInputs) -> (wanted: Bool, reason: String) {
        guard i.enabled else { return (false, "off in Settings") }
        guard i.immersiveOpen else { return (false, "immersive space closed") }
        guard i.engineReady, i.inGame, !i.loading else { return (false, "not in game") }
        guard !i.menuOpen else { return (false, "menu open") }
        guard !i.consoleOpen else { return (false, "console open") }
        switch i.mode {
        case .keyboardMouse:
            return (true, "keyboard+mouse")
        case .gamepad:
            return (false, "gamepad mode")
        case .hands:
            guard i.setting == .auto, i.mouseConnected else { return (false, "hands mode") }
            if let hands = i.lastHandsAt, hands >= (i.mouseConnectedAt ?? -.infinity) {
                return (false, "hands mode (pinched since the mouse connected)")
            }
            return (true, "mouse connected, waiting for it to move")
        }
    }
}

/// Events in the last second, in tenth-of-a-second buckets. Not thread-safe:
/// one owner (the main actor here).
nonisolated struct RollingRate {
    static let buckets = 10
    static let bucketSeconds = 0.1

    private var counts = [Int](repeating: 0, count: RollingRate.buckets)
    /// Index of the newest bucket, as an absolute bucket number.
    private var head: Int?
    private(set) var total = 0
    private(set) var lastAt: TimeInterval?

    mutating func record(at now: TimeInterval, count: Int = 1) {
        advance(to: now)
        counts[Self.slot(Self.bucket(now))] += count
        total += count
        lastAt = now
    }

    /// Events in the last second up to `now`.
    mutating func lastSecond(at now: TimeInterval) -> Int {
        advance(to: now)
        return counts.reduce(0, +)
    }

    private mutating func advance(to now: TimeInterval) {
        let b = Self.bucket(now)
        guard let h = head else { head = b; return }
        guard b > h else { return }
        // Clear every bucket that fell out of the window (all of them after a
        // gap of a second or more).
        for n in (h + 1)...min(b, h + Self.buckets) { counts[Self.slot(n)] = 0 }
        head = b
    }

    private static func bucket(_ t: TimeInterval) -> Int { Int((t / bucketSeconds).rounded(.down)) }
    private static func slot(_ b: Int) -> Int { ((b % buckets) + buckets) % buckets }
}
