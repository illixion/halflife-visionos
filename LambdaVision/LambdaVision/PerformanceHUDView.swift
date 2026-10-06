//
//  PerformanceHUDView.swift
//  LambdaVision
//
//  A live frame-time readout, in its own suppressed-launch window — the same
//  pattern as the "Console" window. The immersive space is raw
//  CompositorServices content with no attachment mechanism to composite a
//  SwiftUI overlay into, but a separate 2D window stays open and visible
//  alongside full immersion (nothing here ever calls dismissWindow), which is
//  how this app already gets 2D UI in front of a running game.
//

import SwiftUI
import RAVEDiagnostics

/// One-line "60 FPS · 16.7 ms · pk 20 ms" summary of the "total" frame-time
/// column, tinted past the 90Hz frame budget.
struct PerformanceReadout: View {
    let stats: RAVEMetricStat?

    private static let warnMeanMs: Double = 1000 / 90

    var body: some View {
        Text(summary)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
    }

    private var summary: String {
        guard let stats, let fps = stats.impliedRate else { return "—" }
        return String(format: "%.0f FPS · %.1f ms · pk %.0f ms", fps, stats.mean, stats.peak)
    }

    private var tint: Color {
        guard let stats else { return .secondary }
        return stats.mean > Self.warnMeanMs ? .orange : .primary
    }
}

/// The GPU budget: what the engine's two eyes (ANGLE's queue) and our own
/// command buffer cost per frame at p50 / p95, summed against the 120 Hz
/// frame. The two queues mostly run one after the other (ours waits on the
/// engine's eyes), so the sum is the frame's GPU time; what is left of
/// 8.3 ms is the headroom new passes can spend.
struct GPUBudgetReadout: View {
    let snapshot: RAVEMetricSnapshot

    private static let budgetMs = 1000.0 / 120

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GPU budget (120 Hz = 8.3 ms)")
                .font(.headline)
            Text(line(\.p50, "p50"))
            Text(line(\.p95, "p95"))
            Text(passes)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13, design: .monospaced))
    }

    private func value(_ key: String, _ path: KeyPath<RAVEMetricStat, Double>) -> Double? {
        snapshot[key].map { $0[keyPath: path] }
    }

    private func line(_ path: KeyPath<RAVEMetricStat, Double>, _ label: String) -> String {
        guard let queue = value("gpuQueue", path) else { return "\(label): —" }
        let engine = (value("gEngine0", path) ?? 0) + (value("gEngine1", path) ?? 0)
        let total = engine + queue
        let engineText = snapshot["gEngine0"] == nil ? "engine —" : String(format: "engine %.2f", engine)
        return String(format: "%@: %@ + ours %.2f = %.2f ms, headroom %.2f",
                      label, engineText, queue, total, Self.budgetMs - total)
    }

    private var passes: String {
        let names = [("gComposite", "composite"), ("gArms", "arms"), ("gWeapon", "gun+body"),
                     ("gHUD", "HUD"), ("gDepth", "depth")]
        let parts = names.compactMap { key, name in
            value(key, \.p50).map { String(format: "%@ %.2f", name, $0) }
        }
        return parts.isEmpty ? "per pass: turn on Settings → Diagnostics → GPU pass timing"
                             : "per pass p50: " + parts.joined(separator: " · ")
    }
}

/// Headline readout, scrolling frame-time graph, and the per-stage breakdown
/// (wait0/wait1/eyes/angleGPU/frameGPU/total) Lambda's eye-submit pipeline
/// already collects — polled on the same TimelineView cadence as the
/// launcher's "Aim" diagnostics readout.
struct PerformanceHUDScreen: View {
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let snapshot = FrameTimingStats.liveSnapshot()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PerformanceReadout(stats: snapshot["total"])
                        RAVEFrameTimeGraph(periodsMs: Array(FrameTimingStats.livePeriods().suffix(180)))
                            .frame(height: 90)
                        GPUBudgetReadout(snapshot: snapshot)
                        RAVEMetricTable(snapshot: snapshot, warnThresholdMs: 1000 / 90)
                    }
                    .padding()
                }
            }
            .navigationTitle("Performance")
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

#Preview(windowStyle: .automatic) {
    PerformanceHUDScreen()
}
