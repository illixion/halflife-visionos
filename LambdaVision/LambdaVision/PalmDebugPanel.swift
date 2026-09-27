//
//  PalmDebugPanel.swift
//  LambdaVision
//
//  Developer mode's debug readout, drawn over the off-hand palm while that
//  palm faces the eyes: frame time (headline + graph + the eye-submit
//  pipeline's stages) and a few render toggles. It replaces reaching for the
//  Performance window mid-game.
//
//  Seeing it is deliberate, unlike the HEV vitals (which fade in as the back
//  of the same forearm turns toward the eyes — the opposite pose, so the two
//  never show together). The gate is RAVE's strict `.panel` rule (the palm
//  must point at the face, 0.12 s dwell), and it refuses to show or stay
//  while the off hand drives the movement joystick, which is the pinch most
//  likely to swing a palm past the face.
//
//  Built on the render thread into the HEV holograms' RAVEHolo scene; its
//  buttons are Compositor Services tracking areas (RAVEHoloCompositor), so
//  gaze hover is the system's and a pinch arrives in onSpatialEvent with a
//  `Control` raw value, before the trigger/menu handling there.
//

import CoreFoundation
import Foundation
import QuartzCore
import RAVEDiagnostics
import RAVEHolo
import RAVEInput
import simd

nonisolated final class PalmDebugPanel: @unchecked Sendable {
    /// Tracking-area identifiers (0 is reserved by RAVEHolo).
    enum Control: UInt64, CaseIterable {
        case hevHUD = 1
        case reticle
        case body
    }

    /// Press flashes: recorded on the main actor, read on the render thread.
    static let interaction = RAVEHoloInteraction()

    static let width: Float = 0.09
    private static let statsRefresh: CFTimeInterval = 0.25
    private static let budgetMs = 1000.0 / 90

    private var anchor = RAVEHoloPalmAnchor(gate: .panel, tuning: .overPalm)
    private var statRows: [RAVEHoloLayout.Item] = []
    private var statsAt: CFTimeInterval = -1

    /// Whether this frame's panel carries targets (the host then registers
    /// tracking areas and runs the target pass).
    private(set) var hasTargets = false

    /// This frame's panel, or nil while hidden. `offHand` is the palm hand's
    /// sample, `head` the eye point (both Apple world metres).
    func panel(offHand: RAVEHandSample?, head: SIMD3<Float>, joystickHeld: Bool,
               font: RAVEHoloFont) -> RAVEHoloPanel? {
        let now = CACurrentMediaTime()
        let pose = offHand.flatMap(RAVEPalmGeometry.palmPose(from:))
        anchor.update(pose: pose, head: head, now: now,
                      showAllowed: !joystickHeld, keepAllowed: !joystickHeld)
        guard anchor.isVisible, let transform = anchor.transform else {
            hasTargets = false
            return nil
        }
        if now - statsAt >= Self.statsRefresh || statRows.isEmpty {
            statsAt = now
            statRows = Self.statItems()
        }
        let reticle: String = switch Renderer.aimReticle {
        case .off: "Aim off"
        case .dot: "Aim dot"
        case .beam: "Aim beam"
        }
        let items = [RAVEHoloLayout.Item.title("Debug")] + statRows + [
            .buttons([
                .init(Control.hevHUD.rawValue, "HEV", isOn: Renderer.hevHUDEnabled),
                .init(Control.reticle.rawValue, reticle, isOn: Renderer.aimReticle != .off),
                .init(Control.body.rawValue, "Body", isOn: Renderer.avatarBodyEnabled),
            ]),
        ]
        let layout = RAVEHoloLayout(width: Self.width, items: items)
        hasTargets = true
        return layout.panel(transform: transform, font: font, opacity: anchor.opacity, seed: 3.7,
                            interaction: Self.interaction, now: now)
    }

    func reset() {
        anchor.reset()
        hasTargets = false
    }

    /// Frame time as the Performance window shows it, refreshed a few times a
    /// second (the snapshot reduces the whole window).
    private static func statItems() -> [RAVEHoloLayout.Item] {
        let snapshot = FrameTimingStats.liveSnapshot()
        func mean(_ key: String) -> String {
            snapshot[key].map { String(format: "%.1f", $0.mean) } ?? "-"
        }
        var items: [RAVEHoloLayout.Item] = []
        if let total = snapshot["total"], let fps = total.impliedRate {
            items.append(.row("Frame", String(format: "%.0f FPS  %.1f MS", fps, total.mean),
                              warn: total.mean > budgetMs))
        } else {
            items.append(.row("Frame", "-"))
        }
        let periods = FrameTimingStats.livePeriods().suffix(90).map(Float.init)
        items.append(.sparkline(Array(periods), max: 33.3, guide: Float(budgetMs),
                                warnAbove: Float(budgetMs), height: 0.010))
        items.append(.row("Wait 0/1", "\(mean("wait0")) / \(mean("wait1"))"))
        items.append(.row("Eyes", mean("eyes")))
        items.append(.row("GPU angle/frame", "\(mean("angleGPU")) / \(mean("frameGPU"))"))
        return items
    }
}
