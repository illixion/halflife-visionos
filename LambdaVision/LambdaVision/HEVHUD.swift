//
//  HEVHUD.swift
//  LambdaVision
//
//  The HEV suit's holographic readouts, replacing the stock 2D HUD's health,
//  suit, ammo and flashlight numbers (the client stands those down through
//  lambda_hud_set_native; pain arrows, pickup history, text messages, the
//  console and the menu stay stock). Nothing is pinned to the user's vision:
//
//  - ammo floats beside the weapon, on the side of the gun hand toward the
//    body, facing the eyes;
//  - health, suit charge and flashlight charge float over the off-hand
//    forearm and fade in as the back of that forearm turns toward the eyes,
//    like checking a watch;
//  - the aim reticle sits where the barrel's shot would land, the distance
//    traced by the client along the very ray the server fires (cl_dll/view.cpp
//    V_PublishAimHit), sized to a fixed angle so it reads the same near or
//    far; optionally with a faint beam from the muzzle.
//
//  Each panel sits on the line from its anchor toward the eyes, clear of the
//  arm or gun it belongs to, so it is genuinely in front of them in stereo;
//  it is also drawn over everything (no depth test) for what that offset
//  cannot cover, like the barrel swinging across. Drawing on top alone would
//  put a panel that is behind the arm in front of it — a depth conflict the
//  eyes cannot fuse. Built on the render thread from the client's published HUD state
//  (cl_dll/hud_redraw.cpp g_vr_hud_state) and the live hand skeleton.
//

import CoreFoundation
import Foundation
import Metal
import RAVEHolo
import os
import simd

nonisolated final class HEVHUD: @unchecked Sendable {
    /// One arm as the HUD anchors to it, Apple world metres.
    struct Arm {
        var wrist: SIMD3<Float>
        var elbow: SIMD3<Float>
        /// Wrist → middle knuckle.
        var forward: SIMD3<Float>
        /// Out of the back of the hand.
        var back: SIMD3<Float>
        /// Across the hand toward the thumb side's opposite on the right
        /// hand, i.e. toward the body for either hand held out front.
        var inward: SIMD3<Float>
    }

    /// The aim ray as the renderer knows it, Apple world metres: from the
    /// drawn muzzle along the barrel, and how far a shot would travel (nil
    /// when the trace found nothing to show).
    struct Aim {
        var muzzle: SIMD3<Float>
        var direction: SIMD3<Float>
        var distance: Float?
    }

    enum Reticle { case off, dot, beam }

    static let amber = SIMD3<Float>(1.0, 0.56, 0.12)
    static let red = SIMD3<Float>(1.0, 0.20, 0.10)
    static let backing = SIMD4<Float>(0.015, 0.010, 0.006, 0.42)

    // The atlas takes a few hundred milliseconds to build: off the render
    // thread, once per process, and the HUD simply waits for it.
    private static let fontLock = OSAllocatedUnfairLock<RAVEHoloFont?>(initialState: nil)
    private static let fontRequested: Void = {
        DispatchQueue.global(qos: .userInitiated).async {
            let font = RAVEHoloFont()
            fontLock.withLock { $0 = font }
            Task { @MainActor in
                AppLog.render.line("[HEVHUD] glyph atlas \(font.width)×\(font.height), font \(font.fontName)")
            }
        }
    }()

    private(set) var renderer: RAVEHoloRenderer?
    private var rendererFailed = false

    // Render-thread state.
    private var lastHealth: Int?
    private var hurtAt: Double = -10
    private var armOpacity: Float = 0
    private var ammoOpacity: Float = 0
    private var lastTime: Double?
    /// Hologram brightness adapted to the room, eased like eye adaptation.
    private var adaptedBrightness: Float = 1

    /// How bright the holograms glow for the world light at the eye (0…1,
    /// R_LightPoint scale): full in a lit room, down to `darkBrightness` in
    /// a dark vent, where full strength glares against the OLED black.
    static let darkBrightness: Float = 0.35
    static func brightness(forAmbient luma: Float) -> Float {
        let t = max(0, min(1, (luma - 0.03) / (0.40 - 0.03)))
        return darkBrightness + (1 - darkBrightness) * t * t * (3 - 2 * t)
    }

    init() { _ = Self.fontRequested }

    /// The renderer once the atlas exists; nil until then (or if Metal
    /// refused the pipeline, logged once).
    func ensureRenderer(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
                        viewCount: Int, slots: Int) -> RAVEHoloRenderer? {
        if let renderer { return renderer }
        guard !rendererFailed, let font = Self.fontLock.withLock({ $0 }) else { return nil }
        do {
            renderer = try RAVEHoloRenderer(device: device,
                                            configuration: .init(colorFormat: colorFormat, depthFormat: depthFormat,
                                                                 maxViewCount: viewCount, slots: slots,
                                                                 depthTest: false),
                                            font: font)
        } catch {
            rendererFailed = true
            let message = "\(error)"
            Task { @MainActor in AppLog.render.line("[HEVHUD] renderer failed: \(message)") }
        }
        return renderer
    }

    /// This frame's panels, or nil when nothing shows.
    func scene(state s: lambda_hud_state_t, readouts: Bool, gunArm: Arm?, offArm: Arm?,
               aim: Aim?, reticle: Reticle, head: SIMD3<Float>, ambient: Float?,
               time: Double) -> RAVEHoloScene? {
        guard let font = renderer?.font else { return nil }
        let dt = Float(min(0.1, max(0, time - (lastTime ?? time))))
        lastTime = time
        // No probe this frame (it rides the external weapon): hold the level.
        if let ambient {
            adaptedBrightness = approach(adaptedBrightness, Self.brightness(forAmbient: ambient), rate: 2, dt: dt)
        }

        // HIDEHUD_* from the game (hud.h): 1 weapons, 2 flashlight, 4 all, 8 health.
        let hideAll = !readouts || s.has_suit == 0 || (s.hide_flags & 4) != 0 || s.intermission != 0
        if let last = lastHealth, s.health < last { hurtAt = time }
        lastHealth = Int(s.health)

        var scene = RAVEHoloScene()

        // Off-hand forearm: health / suit / flashlight, shown while the back
        // of the forearm faces the eyes.
        var armTarget: Float = 0
        if !hideAll, (s.hide_flags & 8) == 0, let arm = offArm {
            let toHead = simd_normalize(head - arm.wrist)
            armTarget = smoothstep(-0.05, 0.35, simd_dot(arm.back, toHead))
        }
        armOpacity = approach(armOpacity, armTarget, rate: 8, dt: dt)
        if armOpacity > 0.01, let arm = offArm {
            let anchor = Self.towardEyes(arm.wrist + (arm.elbow - arm.wrist) * 0.38, head: head,
                                         by: Self.forearmClearance)
            var panel = RAVEHoloPanel(transform: RAVEHoloPanel.facing(position: anchor, viewer: head),
                                      opacity: armOpacity, seed: 1.7)
            vitals(&panel, state: s, font: font, hurt: Float(max(0, 1 - (time - hurtAt) / 0.6)))
            scene.panels.append(panel)
        }

        // Gun hand: ammo, whenever the weapon carries any.
        let hasAmmo = s.ammo1 >= 0 || s.ammo2 >= 0
        let ammoTarget: Float = (!hideAll && (s.hide_flags & 1) == 0 && hasAmmo && gunArm != nil) ? 1 : 0
        ammoOpacity = approach(ammoOpacity, ammoTarget, rate: 10, dt: dt)
        if ammoOpacity > 0.01, let arm = gunArm {
            let anchor = Self.towardEyes(arm.wrist + arm.inward * 0.06 + arm.forward * 0.03, head: head,
                                         by: Self.gunClearance)
            var panel = RAVEHoloPanel(transform: RAVEHoloPanel.facing(position: anchor, viewer: head),
                                      opacity: ammoOpacity, seed: 4.2)
            ammo(&panel, state: s, font: font)
            scene.panels.append(panel)
        }

        if reticle != .off, s.intermission == 0, let aim {
            reticlePanels(aim, style: reticle, head: head, into: &scene)
        }
        for i in scene.panels.indices { scene.panels[i].brightness = adaptedBrightness }
        return scene.panels.isEmpty ? nil : scene
    }

    /// Angular sizes of the reticle, degrees: the ring's outer diameter, its
    /// line, the centre dot. Fixed angles, so it is as readable on a far wall
    /// as on a crate at arm's length.
    static let reticleRingDeg: Float = 0.9
    static let reticleLineDeg: Float = 0.09
    static let reticleDotDeg: Float = 0.22
    /// How far the beam reaches when the trace hits nothing (metres).
    static let beamMissLength: Float = 12

    private func reticlePanels(_ aim: Aim, style: Reticle, head: SIMD3<Float>, into scene: inout RAVEHoloScene) {
        if let d = aim.distance {
            let hit = aim.muzzle + aim.direction * d
            let range = simd_distance(head, hit)
            func size(_ deg: Float) -> Float { 2 * range * tanf(deg * .pi / 360) }
            var p = RAVEHoloPanel(transform: RAVEHoloPanel.facing(position: hit, viewer: head),
                                  opacity: 1, seed: 2.9)
            let ring = size(Self.reticleRingDeg), line = size(Self.reticleLineDeg), dot = size(Self.reticleDotDeg)
            p.fill(x: -ring / 2, y: -ring / 2, width: ring, height: ring, corner: ring / 2,
                   color: SIMD4(Self.backing.x, Self.backing.y, Self.backing.z, 0.25))
            p.frame(x: -ring / 2, y: -ring / 2, width: ring, height: ring, corner: ring / 2, line: line,
                    color: SIMD4(Self.amber, 0.9))
            p.fill(x: -dot / 2, y: -dot / 2, width: dot, height: dot, corner: dot / 2,
                   color: SIMD4(Self.amber, 1))
            scene.panels.append(p)
        }
        guard style == .beam else { return }
        // A ribbon along the ray, turned about it to face the eyes.
        let length = aim.distance ?? Self.beamMissLength
        let x = aim.direction
        var z = head - aim.muzzle
        z -= x * simd_dot(z, x)
        guard simd_length(z) > 1e-4, length > 0.05 else { return }
        z = simd_normalize(z)
        let y = simd_cross(z, x)
        let m = simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(aim.muzzle, 1))
        var beam = RAVEHoloPanel(transform: m, opacity: aim.distance == nil ? 0.5 : 1, seed: 6.1)
        let width: Float = 0.0012
        beam.fill(x: 0, y: -width / 2, width: length, height: width, corner: width / 2,
                  color: SIMD4(Self.amber, 0.28))
        scene.panels.append(beam)
    }

    /// How far each panel stands off its anchor toward the eyes: past the
    /// HEV sleeve for the forearm, past the gun body for the ammo.
    static let forearmClearance: Float = 0.08
    /// Corner radius of each gauge segment (m): rounded like the panels.
    static let segmentCorner: Float = 0.0006
    static let gunClearance: Float = 0.05

    private static func towardEyes(_ point: SIMD3<Float>, head: SIMD3<Float>, by distance: Float) -> SIMD3<Float> {
        let d = head - point
        let length = simd_length(d)
        return length > distance * 2 ? point + d / length * distance : point
    }

    // MARK: Layout (panel metres, centre origin)

    private func vitals(_ p: inout RAVEHoloPanel, state s: lambda_hud_state_t, font: RAVEHoloFont, hurt: Float) {
        let showLight = s.flashlight_on != 0 || s.flashlight_charge < 0.99
        let w: Float = 0.080, rowH: Float = 0.020
        let h: Float = rowH * (showLight ? 2.45 : 2) + 0.008
        let x0 = -w / 2, top = h / 2
        let healthColor = s.health <= 25 ? Self.red : Self.amber
        var back = Self.backing
        back.x += 0.35 * hurt
        p.fill(x: x0, y: -h / 2, width: w, height: h, corner: 0.004, color: back)
        p.frame(x: x0, y: -h / 2, width: w, height: h, corner: 0.004, line: 0.0006,
                color: SIMD4(mix(Self.amber, Self.red, t: hurt), 0.85))

        func row(_ label: String, value: String, fraction: Float, color: SIMD3<Float>, y: Float, big: Bool) {
            p.text(label, font: font, x: x0 + 0.005, y: y - 0.0065, capHeight: 0.0034, tracking: 0.0006,
                   color: SIMD4(color * 0.8, 0.9))
            p.text(value, font: font, x: w / 2 - 0.005, y: y - (big ? 0.0135 : 0.011),
                   capHeight: big ? 0.0105 : 0.007, alignment: .trailing, color: SIMD4(color, 1))
            p.bar(x: x0 + 0.005, y: y - 0.0175, width: w * 0.62, height: 0.0028,
                  fraction: fraction, segments: 10, gap: 0.0007, corner: Self.segmentCorner,
                  color: SIMD4(color, 0.95))
        }
        row("HEALTH", value: "\(max(0, s.health))", fraction: Float(s.health) / 100,
            color: healthColor, y: top - 0.003, big: true)
        row("SUIT", value: "\(max(0, s.battery))", fraction: Float(s.battery) / 100,
            color: Self.amber, y: top - 0.003 - rowH, big: true)
        if showLight {
            let y = top - 0.003 - rowH * 2
            let c = s.flashlight_charge < 0.2 ? Self.red : Self.amber
            p.text("LIGHT", font: font, x: x0 + 0.005, y: y - 0.0055, capHeight: 0.0030, tracking: 0.0006,
                   color: SIMD4(c * (s.flashlight_on != 0 ? 0.9 : 0.55), 0.9))
            p.bar(x: x0 + 0.026, y: y - 0.0062, width: w * 0.62 - 0.021, height: 0.0022,
                  fraction: s.flashlight_charge, corner: 0.0011,   // capsule: half its height
                  color: SIMD4(c, s.flashlight_on != 0 ? 0.95 : 0.5))
        }
    }

    private func ammo(_ p: inout RAVEHoloPanel, state s: lambda_hud_state_t, font: RAVEHoloFont) {
        let w: Float = 0.066, h: Float = 0.034
        let x0 = -w / 2
        let hasClip = s.clip >= 0
        let fraction: Float
        if hasClip, s.max_clip > 0 { fraction = Float(s.clip) / Float(s.max_clip) }
        else if s.ammo1 >= 0, s.ammo1_max > 0 { fraction = Float(s.ammo1) / Float(s.ammo1_max) }
        else { fraction = 1 }
        let empty = hasClip ? (s.clip == 0 && s.ammo1 <= 0) : (s.ammo1 == 0)
        let color = (fraction <= 0.25 || empty) ? Self.red : Self.amber

        p.fill(x: x0, y: -h / 2, width: w, height: h, corner: 0.004, color: Self.backing)
        p.frame(x: x0, y: -h / 2, width: w, height: h, corner: 0.004, line: 0.0006,
                color: SIMD4(Self.amber, 0.85))
        p.text("AMMO", font: font, x: x0 + 0.005, y: h / 2 - 0.0085, capHeight: 0.0034, tracking: 0.0006,
               color: SIMD4(Self.amber * 0.8, 0.9))
        if s.ammo2 >= 0 {
            p.text("ALT \(s.ammo2)", font: font, x: w / 2 - 0.005, y: h / 2 - 0.0085, capHeight: 0.0034,
                   alignment: .trailing, tracking: 0.0005,
                   color: SIMD4(s.ammo2 == 0 ? Self.red : Self.amber, 0.95))
        }
        let baseline: Float = -0.0075
        if hasClip {
            p.text("\(s.clip)", font: font, x: 0.006, y: baseline, capHeight: 0.0145,
                   alignment: .trailing, color: SIMD4(color, 1))
            if s.ammo1 >= 0 {
                p.text("/ \(s.ammo1)", font: font, x: 0.010, y: baseline, capHeight: 0.0065,
                       color: SIMD4(Self.amber * 0.85, 0.95))
            }
        } else if s.ammo1 >= 0 {
            p.text("\(s.ammo1)", font: font, x: 0, y: baseline, capHeight: 0.0145,
                   alignment: .center, color: SIMD4(color, 1))
        }
        if s.ammo1 >= 0 || hasClip {
            // One segment per round up to a readable count; bigger clips
            // (the MP5's 50) read as a continuous gauge.
            let segments = hasClip && s.max_clip > 0 && s.max_clip <= 20 ? Int(s.max_clip) : 0
            p.bar(x: x0 + 0.005, y: -h / 2 + 0.004, width: w - 0.010, height: 0.0028,
                  fraction: fraction, segments: segments, gap: 0.0006,
                  corner: segments > 0 ? Self.segmentCorner : 0.0014,   // continuous: capsule
                  color: SIMD4(color, 0.95))
        }
    }

    private func approach(_ v: Float, _ target: Float, rate: Float, dt: Float) -> Float {
        v + (target - v) * min(1, rate * dt)
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

nonisolated private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> { a + (b - a) * t }
