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
