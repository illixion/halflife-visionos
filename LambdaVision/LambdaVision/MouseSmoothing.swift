//
//  MouseSmoothing.swift
//  LambdaVision
//
//  visionOS hands GCMouse motion over at its own, lower and uneven, rate
//  (the pointer itself looks low-FPS), so a mouse that moves steadily lands
//  in the 90 Hz render as a delta on some frames and nothing on others: the
//  view or the free-aimed gun moves in steps. `MotionSmoother` spreads each
//  delta over the following frames through two first-order stages of τ/2
//  each — a critically damped response with mean delay τ — and conserves
//  every count, so the total turn or aim is exactly what the mouse moved.
//
//  `EventIntervalStats` measures the event rate and its jitter for GET /state.
//
//  Pure simd, no frameworks: Tools/FreeAimProbe compiles this file verbatim.
//

import simd

nonisolated struct MotionSmoother {
    /// Mean delay (s); 0 passes motion straight through.
    var timeConstant: Float
    private var stage1 = SIMD2<Float>(repeating: 0)
    private var stage2 = SIMD2<Float>(repeating: 0)

    init(timeConstant: Float) { self.timeConstant = timeConstant }

    /// Motion still to come out (counts), for diagnostics.
    var pending: SIMD2<Float> { stage1 + stage2 }

    /// Adds this frame's raw motion and returns what this frame applies.
    mutating func step(_ input: SIMD2<Float>, dt: Float) -> SIMD2<Float> {
        guard timeConstant > 0 else { return input + flush() }
        stage1 += input
        guard dt > 0, dt.isFinite else { return .zero }
        let k = 1 - expf(-dt / (timeConstant / 2))
        let o1 = stage1 * k
        stage1 -= o1
        stage2 += o1
        var out = stage2 * k
        stage2 -= out
        // Don't trickle the last hundredth of a count for ever.
        if simd_length(stage1) + simd_length(stage2) < 1e-2 {
            out += stage1 + stage2
            stage1 = .zero
            stage2 = .zero
        }
        return out
    }

    /// Everything still held, at once (smoothing turned off).
    mutating func flush() -> SIMD2<Float> {
        let rest = stage1 + stage2
        stage1 = .zero
        stage2 = .zero
        return rest
    }

    /// Drop what is held (the menu or console took the mouse).
    mutating func reset() { stage1 = .zero; stage2 = .zero }
}

/// Arrival times of an event stream over a recent window: rate, mean
/// interval, jitter (the intervals' standard deviation) and the worst gap.
nonisolated struct EventIntervalStats {
    struct Summary: Equatable {
        var rateHz: Double
        var meanIntervalMs: Double
        var jitterMs: Double
        var maxIntervalMs: Double
    }

    private var times: [Double] = []
    private let capacity: Int

    init(capacity: Int = 512) { self.capacity = capacity }

    mutating func record(_ t: Double) {
        times.append(t)
        if times.count > capacity { times.removeFirst(times.count - capacity) }
    }

    /// Over events within `window` seconds of `now`; nil with fewer than two.
    func summary(now: Double, window: Double = 1) -> Summary? {
        let recent = times.filter { now - $0 <= window && $0 <= now }
        guard recent.count >= 2 else { return nil }
        var intervals: [Double] = []
        for i in 1..<recent.count { intervals.append(recent[i] - recent[i - 1]) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)
        return Summary(rateHz: Double(recent.count) / window, meanIntervalMs: mean * 1000,
                       jitterMs: variance.squareRoot() * 1000, maxIntervalMs: (intervals.max() ?? 0) * 1000)
    }
}
