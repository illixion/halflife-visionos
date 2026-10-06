//
//  GPUPassTimer.swift
//  LambdaVision
//
//  GPU execution time of each pass of a frame, for the Performance HUD and
//  the `[FT] gpu(ms)` line: the per-frame budget, measured rather than
//  guessed (docs/plans/modern-lighting.md sizes everything from it).
//
//  Three sources, because the frame runs on two GPU queues:
//
//  - `gpuQueue`: our command buffer's GPU start → end, from Metal 4 commit
//    feedback. Always on (one callback per frame). The old `frameGPU`
//    column is NOT this: it is the CPU wall time from eye submission to the
//    frame-end event firing, so it adds ANGLE's work, queueing and listener
//    latency (Oneiros found the same trap in its own `[FT]` numbers).
//  - Per pass inside that command buffer (sharp-water mirror, composite, arms, weapon + body,
//    HUD holograms, reprojection depth): Metal 4 counter-heap timestamps at
//    pass boundaries, while Settings → Diagnostics → "GPU pass timing" is on.
//    The HUD split sits inside the weapon encoder and needs a precise
//    timestamp, which may split the encoder, so this is off by default.
//  - `gEngine0` / `gEngine1`: ANGLE's GPU time for each eye's engine frame,
//    from GL_EXT_disjoint_timer_query on the GL worker (Lambda_Bridge.c
//    lambda_gl_gpu_eye_ms), under the same toggle. Absent if ANGLE does not
//    expose the extension (the bridge logs which).
//
//  Timestamps are resolved on the CPU when a frame-in-flight slot comes
//  round again, by which time renderFrame has waited for that frame.
//

import Metal
import QuartzCore
import DebugTrace

final class GPUPassTimer {
    /// Timestamp marks within one frame's slot, in encoding order. Each
    /// mark after `start` closes the pass named by its key; a pass that
    /// did not run this frame writes no mark and records nothing.
    enum Mark: Int, CaseIterable {
        case start = 0, mirrorFill, mirrorProject, mirror, composite, arms, weapon, hud, depth

        /// FrameTimingStats column for the pass this mark closes.
        var key: String? {
            switch self {
            case .start:     return nil
            // sharp water (SharpWater), before the composite: the key-buffer
            // fill, the projection (atomics) and the resolve
            case .mirrorFill:    return "gMirrorFill"
            case .mirrorProject: return "gMirrorProject"
            case .mirror:        return "gMirror"
            case .composite: return "gComposite"
            case .arms:      return "gArms"
            case .weapon:    return "gWeapon"
            case .hud:       return "gHUD"
            case .depth:     return "gDepth"
            }
        }
    }

    /// Per-pass timestamps and the engine's GL timer queries (Settings →
    /// Diagnostics → "GPU pass timing"). Read on the render thread.
    nonisolated(unsafe) static var enabled = false

    private static let marksPerSlot = 12
    private let heap: MTL4CounterHeap?
    private let msPerTick: Double
    private let slots: Int
    /// Slots with marks written by a frame that has not been resolved yet.
    private var pending: [Bool]
    /// The slot the frame being encoded writes into, nil when not timing.
    private(set) var activeSlot: Int?

    init(device: MTLDevice, slots: Int) {
        self.slots = slots
        pending = Array(repeating: false, count: slots)
        let d = MTL4CounterHeapDescriptor()
        d.type = .timestamp
        d.count = slots * Self.marksPerSlot
        heap = try? device.makeCounterHeap(descriptor: d)
        heap?.label = "GPUPassTimer"
        let hz = Double(device.queryTimestampFrequency())
        msPerTick = hz > 0 ? 1000.0 / hz : 0
        if heap == nil || msPerTick == 0 {
            AppLog.perf.log("[FT] GPU pass timestamps unavailable (counter heap \(self.heap != nil ? "ok" : "nil", privacy: .public), \(hz, privacy: .public) Hz)")
        }
    }

    /// Start a frame on `slot`: first resolves what that slot's previous
    /// frame wrote (complete by now — renderFrame waited for it), then arms
    /// the slot for this frame when timing is on.
    func beginFrame(slot: Int) {
        if pending[slot] { resolve(slot: slot) }
        activeSlot = (Self.enabled && heap != nil && msPerTick > 0) ? slot : nil
    }

    /// The command buffer's first timestamp, before any pass.
    func markStart(_ commandBuffer: MTL4CommandBuffer) {
        guard let slot = activeSlot, let heap else { return }
        commandBuffer.writeTimestamp(counterHeap: heap, index: index(slot, .start))
        pending[slot] = true
    }

    /// A pass boundary between encoders: after all work encoded so far in
    /// the command buffer has finished.
    func mark(_ mark: Mark, _ commandBuffer: MTL4CommandBuffer) {
        guard let slot = activeSlot, let heap else { return }
        commandBuffer.writeTimestamp(counterHeap: heap, index: index(slot, mark))
    }

    /// A pass boundary inside a render encoder: after everything drawn so
    /// far has finished its fragment work. `precise` for a mark in the middle
    /// of an encoder (a relaxed one may only sample at encoder boundaries).
    func mark(_ mark: Mark, _ encoder: MTL4RenderCommandEncoder, precise: Bool = false) {
        guard let slot = activeSlot, let heap else { return }
        encoder.writeTimestamp(granularity: precise ? .precise : .relaxed,
                               after: .fragment, counterHeap: heap, index: index(slot, mark))
    }

    /// A pass boundary inside a compute encoder (precise: between dispatches).
    func mark(_ mark: Mark, _ encoder: MTL4ComputeCommandEncoder) {
        guard let slot = activeSlot, let heap else { return }
        encoder.writeTimestamp(granularity: .precise, counterHeap: heap, index: index(slot, mark))
    }

    private func index(_ slot: Int, _ mark: Mark) -> Int { slot * Self.marksPerSlot + mark.rawValue }

    private func resolve(slot: Int) {
        pending[slot] = false
        guard let heap else { return }
        let first = slot * Self.marksPerSlot
        let range = first..<(first + Mark.allCases.count)
        defer { heap.invalidateCounterRange(range) }
        guard let data = try? heap.resolveCounterRange(range) else { return }
        let ticks: [UInt64] = data.withUnsafeBytes { raw in
            (0..<Mark.allCases.count).map { i in
                raw.load(fromByteOffset: i * MemoryLayout<MTL4TimestampHeapEntry>.stride,
                         as: MTL4TimestampHeapEntry.self).timestamp
            }
        }
        // Invalidated (never written) entries resolve to 0.
        guard var previous = ticks.first, previous != 0 else { return }
        for mark in Mark.allCases.dropFirst() {
            let t = ticks[mark.rawValue]
            guard t != 0, t >= previous, let key = mark.key else { continue }
            FrameTimingStats.shared.add(key, Double(t - previous) * msPerTick)
            previous = t
        }
    }
}
