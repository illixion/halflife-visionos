//
//  ChapterPictureRunner.swift
//  LambdaVision
//
//  Makes the chapter pictures: for each marked spot (ChapterShotStore) it
//  loads the map, puts the engine's camera at the spot, and writes what the
//  engine renders (the left eye's colour map, upright, no overlays) as a
//  16:10 JPEG into Application Support (ChapterPictures).
//
//  The camera is placed with the engine's own tools, not by moving the head:
//    • the player is teleported (cheats, noclip, `ent_fire 1 set origin`) and
//      nudged until the camera the engine reports matches the spot;
//    • the view angles come from `Renderer.scriptedPitch` (pitch, no head
//      yaw or tilt, no head offset) and `lambda_add_view_yaw` for the yaw.
//  The player's head therefore doesn't matter while a run goes on.
//
//  The capture is the app's own (FrameCapture, engine source): it never
//  leaves the device and needs no approval.
//

import SwiftUI
import simd
import ImageIO
import UniformTypeIdentifiers
import GameLibrary

@MainActor
@Observable
final class ChapterPictureRunner {
    enum State: Equatable {
        case idle
        case running(done: Int, total: Int, map: String)
        case finished(made: Int, failed: [String])
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }

    /// Output size of a picture: 16:10.
    static let pictureWidth = 1600
    static let pictureHeight = 1000
    /// How much of the eye's width a picture keeps (the headset's field of
    /// view is wide; a little less reads as a normal picture).
    static let cropFraction = 0.85

    func cancel() { task?.cancel() }

    func start(appModel: AppModel, game: GameEntry, shots: [ChapterShot], leaveWhenDone: Bool = true) {
        guard !isRunning else { return }
        let list = shots.filter { $0.game.lowercased() == game.gamedir.lowercased() }
        guard !list.isEmpty else { state = .failed("No spots are marked for this game yet."); return }
        state = .running(done: 0, total: list.count, map: "starting")
        task = Task { @MainActor [weak self] in
            await self?.run(appModel: appModel, list: list, leaveWhenDone: leaveWhenDone)
        }
    }

    private func fail(_ message: String) {
        Renderer.scriptedPitch = nil
        state = .failed(message)
    }

    private func run(appModel: AppModel, list: [ChapterShot], leaveWhenDone: Bool) async {
        let launcher = appModel.launcher
        let settings = appModel.gameSettings
        launcher.start()
        for _ in 0..<160 where !launcher.isRunning {
            if Task.isCancelled { fail("Stopped"); return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard launcher.isRunning else { fail("The game didn't start."); return }

        // What the player had, to put back.
        let keep = ["crosshair", "hud_draw", "sv_cheats", "scr_conspeed", "con_notifytime"].map { ($0, Self.cvar($0)) }
        for line in ["sv_cheats 1", "sv_enttools_enable 1", "crosshair 0", "hud_draw 0", "scr_conspeed 5000", "con_notifytime 0"] { settings.command(line) }

        var made = 0
        var failed: [String] = []
        for (index, shot) in list.enumerated() {
            if Task.isCancelled { break }
            state = .running(done: index, total: list.count, map: shot.map)
            if await capture(shot, settings: settings) { made += 1 } else { failed.append(shot.map) }
        }

        Renderer.scriptedPitch = nil
        for (name, value) in keep { if let value { settings.command("\(name) \(value)") } }
        state = Task.isCancelled ? .failed("Stopped") : .finished(made: made, failed: failed)
        if leaveWhenDone { launcher.leave() }
    }

    // MARK: One picture

    private func capture(_ shot: ChapterShot, settings: GameSettings) async -> Bool {
        settings.command("map \(shot.map)")
        try? await Task.sleep(for: .seconds(1))
        // The load: the map is the one asked for, the engine is no longer
        // loading and its worker is idle.
        var loaded = false
        for _ in 0..<200 {
            if Task.isCancelled { return false }
            if GameStatus.currentMap()?.lowercased() == shot.map.lowercased(),
               lambda_engine_loading() == 0, lambda_gl_worker_busy() == 0 { loaded = true; break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard loaded else { return false }

        for line in ["sv_cheats 1", "sv_enttools_enable 1", "god", "notarget", "ent_fire 1 movetype 8",
                     "crosshair 0", "hud_draw 0"] { settings.command(line) }
        Renderer.scriptedPitch = shot.angles[0]
        var spot = SIMD3<Float>(shot.origin[0], shot.origin[1], shot.origin[2])
        settings.command("ent_fire 1 set origin \"\(spot.x) \(spot.y) \(spot.z)\"")

        // Nudge until the engine's camera is on the spot and facing the way
        // marked (the engine reports the camera it last rendered).
        var aligned = false
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return false }
            guard let view = Self.view() else { continue }
            let errPos = SIMD3<Float>(shot.origin[0], shot.origin[1], shot.origin[2]) - view.origin
            var errYaw = shot.angles[1] - view.angles[1]
            while errYaw > 180 { errYaw -= 360 }
            while errYaw < -180 { errYaw += 360 }
            if simd_length(errPos) < 1.5, abs(errYaw) < 0.5 { aligned = true; break }
            if simd_length(errPos) >= 1.5 {
                spot += errPos
                settings.command("ent_fire 1 set origin \"\(spot.x) \(spot.y) \(spot.z)\"")
            }
            if abs(errYaw) >= 0.5 { lambda_add_view_yaw(errYaw) }
        }
        guard aligned else { return false }

        // The engine opens its console at every map start and slides it away;
        // wait for that to finish (it only moves while frames are drawn).
        for _ in 0..<60 where lambda_console_active() != 0 {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard lambda_console_active() == 0 else { return false }
        // Let the fade, lighting and particles settle; a dark frame (a
        // fade still running) is tried again a couple of times.
        try? await Task.sleep(for: .seconds(1.5))
        for attempt in 0..<3 {
            if Task.isCancelled { return false }
            guard let png = try? await FrameCapture.shared.capture(
                    .init(eye: .left, source: .engine, maxWidth: 2800, unwarp: true), timeout: .seconds(8)),
                  let result = Self.picture(fromPNG: png) else { return false }
            if result.meanLuma < 0.02, attempt < 2 {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            return ChapterPictures.shared.write(result.jpeg, gamedir: shot.game, map: shot.map)
        }
        return false
    }

    // MARK: Engine reads

    private static func view() -> (origin: SIMD3<Float>, angles: [Float])? {
        var o: [Float] = [0, 0, 0], a: [Float] = [0, 0, 0]
        guard lambda_debug_view(&o, &a) != 0 else { return nil }
        return (SIMD3(o[0], o[1], o[2]), a)
    }

    private static func cvar(_ name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        let exists = buf.withUnsafeMutableBufferPointer { lambda_debug_cvar(name, $0.baseAddress, Int32($0.count)) }
        guard exists != 0 else { return nil }
        let s = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return s.isEmpty ? nil : s
    }

    // MARK: Image

    /// A 16:10 JPEG cut from the middle of the eye's picture, and how bright it is.
    nonisolated static func picture(fromPNG png: Data) -> (jpeg: Data, meanLuma: Double)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = Double(image.width), h = Double(image.height)
        let aspect = Double(pictureWidth) / Double(pictureHeight)
        var cropW = w * cropFraction
        var cropH = cropW / aspect
        if cropH > h { cropH = h; cropW = h * aspect }
        let crop = CGRect(x: ((w - cropW) / 2).rounded(), y: ((h - cropH) / 2).rounded(),
                          width: cropW.rounded(), height: cropH.rounded())
        guard let cut = image.cropping(to: crop) else { return nil }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pictureWidth, height: pictureHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: pictureWidth, height: pictureHeight))
        guard let out = ctx.makeImage() else { return nil }

        // Mean brightness from a coarse sample of the output.
        var luma = 0.0, n = 0.0
        if let data = ctx.data {
            let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * pictureHeight)
            for y in stride(from: 0, to: pictureHeight, by: 20) {
                for x in stride(from: 0, to: pictureWidth, by: 20) {
                    let i = y * ctx.bytesPerRow + x * 4
                    luma += (0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2])) / 255
                    n += 1
                }
            }
        }

        let jpeg = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (jpeg as Data, n > 0 ? luma / n : 0)
    }
}
