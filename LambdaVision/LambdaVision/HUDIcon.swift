//
//  HUDIcon.swift
//  LambdaVision
//
//  The stock HUD's weapon icons (the `640hud*.spr` sprites that each
//  `sprites/weapon_*.txt` points at) and the flashlight icon (`hud.txt`),
//  turned into something the holographic HUD can draw. RAVEHolo draws
//  rounded rectangles and glyphs, not textures, so an icon becomes a small
//  set of rectangles: the sprite is box-filtered down to a coarse grid,
//  thresholded into two brightness layers, and each layer's runs are merged
//  row to row into as few rectangles as possible. The HUD sprites are
//  additive, monochrome-ish art that the game tints with its HUD colour, so
//  brightness alone is the whole look.
//
//  Decoded in the pre-game warm-up (HUDIconWarmup), never on first sight; a
//  weapon the warm-up didn't see shows its name instead. Pure Swift, so the
//  host probe (Tools/HandsProbe) decodes the real sprites with this file.
//

import Foundation
import os

nonisolated struct HUDIcon: Sendable, Equatable {
    /// One rectangle in unit icon space: x right and y up, both 0…1 of the
    /// icon's width and height. Layer 0 is everything lit, layer 1 the
    /// bright core drawn over it.
    struct Rect: Sendable, Equatable {
        var x: Float, y: Float, w: Float, h: Float
        var layer: Int
    }
    /// Width over height of the sprite rectangle.
    var aspect: Float
    var rects: [Rect]
}

nonisolated enum HUDSprite {
    /// One line of a sprite list (`weapon_*.txt`, `hud.txt`):
    /// `name resolution sprite x y width height`.
    struct ListEntry: Equatable, Sendable {
        var name: String
        var resolution: Int
        var sprite: String
        var x: Int, y: Int, width: Int, height: Int
    }

    /// Parses a sprite list. The first line is the entry count; malformed
    /// lines are skipped, as the client's own parser would.
    static func parseList(_ text: String) -> [ListEntry] {
        var out: [ListEntry] = []
        for (i, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if i == 0, f.count == 1 { continue }   // the count
            guard f.count >= 7, let res = Int(f[1]), let x = Int(f[3]), let y = Int(f[4]),
                  let w = Int(f[5]), let h = Int(f[6]) else { continue }
            out.append(ListEntry(name: String(f[0]), resolution: res, sprite: String(f[2]),
                                 x: x, y: y, width: w, height: h))
        }
        return out
    }

    /// The entry called `name`, at 640 if the list has it, else the
    /// highest resolution it has.
    static func entry(_ name: String, in list: [ListEntry]) -> ListEntry? {
        let m = list.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return m.first { $0.resolution == 640 } ?? m.max { $0.resolution < $1.resolution }
    }

    /// A sprite's first frame as brightness 0…1, row-major from the top.
    struct Image: Sendable {
        var width: Int
        var height: Int
        var value: [Float]
    }

    /// Decodes a Half-Life (version 2) sprite's first frame. Additive and
    /// normal sprites read as their brightest channel; index-alpha as the
    /// index; alpha-test as the colour except index 255 (transparent).
    static func decode(_ data: Data) -> Image? {
        let b = [UInt8](data)
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8
                             | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        guard b.count > 42, b[0] == 0x49, b[1] == 0x44, b[2] == 0x53, b[3] == 0x50,   // IDSP
              i32(4) == 2, let texFormat = i32(12) else { return nil }
        let paletteCount = Int(b[40]) | Int(b[41]) << 8
        let paletteAt = 42
        var o = paletteAt + paletteCount * 3
        guard paletteCount > 0, paletteCount <= 256, let frameType = i32(o) else { return nil }
        o += 4
        if frameType != 0 {   // a group: its count and intervals, then the frames
            guard let n = i32(o), n > 0, n < 1024 else { return nil }
            o += 4 + n * 4
        }
        guard let w = i32(o + 8), let h = i32(o + 12), w > 0, h > 0, w <= 4096, h <= 4096 else { return nil }
        o += 16
        guard o + w * h <= b.count else { return nil }
        var lum = [Float](repeating: 0, count: 256)
        for i in 0..<paletteCount {
            let p = paletteAt + i * 3
            lum[i] = Float(max(b[p], b[p + 1], b[p + 2])) / 255
        }
        var value = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let idx = Int(b[o + i])
            switch texFormat {
            case 2: value[i] = Float(idx) / 255                 // SPR_INDEXALPHA
            case 3: value[i] = idx == 255 ? 0 : lum[idx]        // SPR_ALPHTEST
            default: value[i] = lum[idx]                        // normal, additive
            }
        }
        return Image(width: w, height: h, value: value)
    }

    /// Brightness thresholds of the two layers.
    static let layerThresholds: [Float] = [0.22, 0.58]

    /// Vectorizes the `x, y, width, height` rectangle of `image` onto a grid
    /// at most `columns` cells wide. Nil when nothing in it is lit.
    static func icon(from image: Image, x: Int, y: Int, width: Int, height: Int,
                     columns: Int = 44) -> HUDIcon? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(image.width, x + width), y1 = min(image.height, y + height)
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return nil }
        let gw = max(1, min(w, columns))
        let gh = max(1, Int((Float(h) * Float(gw) / Float(w)).rounded()))
        // Box filter, leaning toward the cell's brightest pixel so one-pixel
        // outlines survive the reduction.
        var cells = [Float](repeating: 0, count: gw * gh)
        for cy in 0..<gh {
            let sy0 = y0 + cy * h / gh, sy1 = max(sy0 + 1, y0 + (cy + 1) * h / gh)
            for cx in 0..<gw {
                let sx0 = x0 + cx * w / gw, sx1 = max(sx0 + 1, x0 + (cx + 1) * w / gw)
                var sum: Float = 0, peak: Float = 0
                for sy in sy0..<sy1 {
                    for sx in sx0..<sx1 {
                        let v = image.value[sy * image.width + sx]
                        sum += v
                        peak = max(peak, v)
                    }
                }
                let mean = sum / Float((sy1 - sy0) * (sx1 - sx0))
                cells[cy * gw + cx] = (mean + peak) * 0.5
            }
        }
        var rects: [HUDIcon.Rect] = []
        for (layer, threshold) in layerThresholds.enumerated() {
            rects += merge(gw: gw, gh: gh) { cells[$1 * gw + $0] >= threshold }.map {
                HUDIcon.Rect(x: Float($0.x) / Float(gw), y: Float(gh - $0.y - $0.h) / Float(gh),
                             w: Float($0.w) / Float(gw), h: Float($0.h) / Float(gh), layer: layer)
            }
        }
        return rects.isEmpty ? nil : HUDIcon(aspect: Float(w) / Float(h), rects: rects)
    }

    /// Grid-cell rectangles covering the lit cells: each row's runs, merged
    /// down into the previous row's rectangle when it spans the same columns.
    /// (x, y from the top, w, h) in cells.
    static func merge(gw: Int, gh: Int, lit: (Int, Int) -> Bool) -> [(x: Int, y: Int, w: Int, h: Int)] {
        var done: [(x: Int, y: Int, w: Int, h: Int)] = []
        var open: [Int: (x: Int, y: Int, w: Int, h: Int)] = [:]   // keyed by x * 65536 + w
        for row in 0..<gh {
            var next: [Int: (x: Int, y: Int, w: Int, h: Int)] = [:]
            var cx = 0
            while cx < gw {
                guard lit(cx, row) else { cx += 1; continue }
                let start = cx
                while cx < gw, lit(cx, row) { cx += 1 }
                let key = start * 65536 + (cx - start)
                if var r = open.removeValue(forKey: key) {
                    r.h += 1
                    next[key] = r
                } else {
                    next[key] = (start, row, cx - start, 1)
                }
            }
            done += open.values
            open = next
        }
        done += open.values
        return done.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}

/// The icons the warm-up decoded, by key: a weapon's classname in lower
/// case, or `flashlightKey`. Written before the game starts, read on the
/// render thread.
nonisolated final class HUDIconStore: Sendable {
    static let shared = HUDIconStore()
    static let flashlightKey = "hud:flash_full"

    private let icons = OSAllocatedUnfairLock<[String: HUDIcon]>(initialState: [:])

    func icon(for key: String) -> HUDIcon? { icons.withLock { $0[key] } }
    func replaceAll(_ new: [String: HUDIcon]) { icons.withLock { $0 = new } }
    var count: Int { icons.withLock { $0.count } }
}
