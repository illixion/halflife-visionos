//
//  FrameImage.swift
//  LambdaVision
//
//  The CPU half of the debug server's frame capture (FrameCapture): raw
//  texture bytes read back from the GPU → an RGBA8 image a person or a model
//  can look at. Decodes the pixel formats the drawable and the engine's
//  colour map use, undoes the drawable's foveation (the rasterization rate
//  map squeezes the periphery into fewer physical pixels), resizes, puts the
//  two eyes side by side and encodes a PNG.
//
//  Pure Foundation + CoreGraphics: no Metal, no app state, so
//  Tools/CaptureProbe compiles this file as it is and checks it on the Mac.
//  Runs off the render thread (FrameCapture's work queue).
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum FrameImage {

    /// How a texel is stored. The 8- and 10-bit formats are taken as already
    /// display-encoded (an sRGB drawable stores encoded bytes; the engine's
    /// colour map is gamma-space); half floats are linear light and are
    /// sRGB-encoded here.
    nonisolated enum Layout: String, Sendable {
        case bgra8, rgba8, rgba16Unorm, rgba16Float, bgr10a2, rgb10a2

        var bytesPerPixel: Int {
            switch self {
            case .bgra8, .rgba8, .bgr10a2, .rgb10a2: 4
            case .rgba16Unorm, .rgba16Float: 8
            }
        }
    }

    /// An opaque RGBA8 image, rows top-down.
    nonisolated struct Plane: Sendable, Equatable {
        var width: Int
        var height: Int
        var rgba: [UInt8]

        init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width
            self.height = height
            self.rgba = rgba
        }

        init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
            self.width = width
            self.height = height
            var px = [UInt8](repeating: 255, count: width * height * 4)
            for i in stride(from: 0, to: px.count, by: 4) {
                px[i] = fill.0; px[i + 1] = fill.1; px[i + 2] = fill.2
            }
            rgba = px
        }

        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (rgba[i], rgba[i + 1], rgba[i + 2])
        }
    }

    // MARK: Decode

    /// Linear → sRGB-encoded byte, over [0, 1] in 4096 steps.
    private static let srgbLUT: [UInt8] = (0...4095).map { i in
        let l = Float(i) / 4095
        let s = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }

    /// Raw texels → RGBA8, alpha forced opaque (the drawable's alpha is the
    /// composite's business, not the picture's). `flipVertically` for GL-
    /// written images, whose rows run bottom-up.
    static func decode(_ raw: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                       layout: Layout, flipVertically: Bool = false) -> Plane {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        guard let base = raw.baseAddress, raw.count >= bytesPerRow * max(0, height - 1) + width * layout.bytesPerPixel else {
            return Plane(width: width, height: height, rgba: out)
        }
        let lut = srgbLUT
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<height {
                let srcRow = base + (flipVertically ? height - 1 - y : y) * bytesPerRow
                var d = y * width * 4
                switch layout {
                case .bgra8, .rgba8:
                    let p = srcRow.assumingMemoryBound(to: UInt8.self)
                    let swap = layout == .bgra8
                    for x in 0..<width {
                        let s = x * 4
                        o[d] = p[s + (swap ? 2 : 0)]; o[d + 1] = p[s + 1]; o[d + 2] = p[s + (swap ? 0 : 2)]
                        d += 4
                    }
                case .rgba16Unorm:
                    let p = srcRow.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let s = x * 4
                        for c in 0..<3 { o[d + c] = UInt8((UInt32(p[s + c]) * 255 + 32767) / 65535) }
                        d += 4
                    }
                case .rgba16Float:
                    let p = srcRow.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let s = x * 4
                        for c in 0..<3 {
                            let f = Float(Float16(bitPattern: p[s + c]))
                            o[d + c] = f.isFinite && f > 0 ? lut[Int(min(f, 1) * 4095 + 0.5)] : 0
                        }
                        d += 4
                    }
                case .bgr10a2, .rgb10a2:
                    let p = srcRow.assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width {
                        let v = p[x]
                        let lo = UInt8(((v & 0x3FF) * 255 + 511) / 1023)
                        let mid = UInt8((((v >> 10) & 0x3FF) * 255 + 511) / 1023)
                        let hi = UInt8((((v >> 20) & 0x3FF) * 255 + 511) / 1023)
                        // rgb10a2: red in the low bits; bgr10a2: blue.
                        if layout == .rgb10a2 { o[d] = lo; o[d + 2] = hi } else { o[d] = hi; o[d + 2] = lo }
                        o[d + 1] = mid
                        d += 4
                    }
                }
            }
        }
        return Plane(width: width, height: height, rgba: out)
    }

    // MARK: Foveation

    /// Where each output column / row samples the source, in source pixels
    /// (continuous coordinates: pixel i covers [i, i + 1)). The drawable's
    /// rasterization rate map is separable — physical x depends on screen x
    /// alone, physical y on screen y — so two 1-D tables describe it.
    nonisolated struct AxisMap: Sendable, Equatable {
        var columns: [Float]
        var rows: [Float]

        /// No foveation: output pixel centres spread evenly over the source.
        static func uniform(output: (width: Int, height: Int), source: (width: Int, height: Int)) -> AxisMap {
            func axis(_ n: Int, _ m: Int) -> [Float] {
                (0..<n).map { (Float($0) + 0.5) * Float(m) / Float(max(n, 1)) }
            }
            return AxisMap(columns: axis(output.width, source.width), rows: axis(output.height, source.height))
        }

        /// Through a screen → physical mapping (the rate map's
        /// `mapScreenToPhysicalCoordinates`), sampled at each output pixel's
        /// centre in screen space. `screen` is the rate map's screen size.
        static func mapped(output: (width: Int, height: Int), screen: (width: Int, height: Int),
                           toPhysical: (_ x: Float, _ y: Float) -> (x: Float, y: Float)) -> AxisMap {
            let midX = Float(screen.width) / 2, midY = Float(screen.height) / 2
            let columns = (0..<output.width).map { i in
                toPhysical((Float(i) + 0.5) * Float(screen.width) / Float(max(output.width, 1)), midY).x
            }
            let rows = (0..<output.height).map { j in
                toPhysical(midX, (Float(j) + 0.5) * Float(screen.height) / Float(max(output.height, 1))).y
            }
            return AxisMap(columns: columns, rows: rows)
        }
    }

    /// Resamples `source` at the map's coordinates, bilinear, edges clamped.
    static func remap(_ source: Plane, _ map: AxisMap) -> Plane {
        let w = map.columns.count, h = map.rows.count
        var out = [UInt8](repeating: 255, count: w * h * 4)
        guard source.width > 0, source.height > 0 else { return Plane(width: w, height: h, rgba: out) }
        // Per-axis taps and weights, computed once.
        func taps(_ coords: [Float], _ size: Int) -> [(Int, Int, Float)] {
            coords.map { c in
                let t = max(0, min(Float(size - 1), c - 0.5))
                let i0 = Int(t), i1 = min(i0 + 1, size - 1)
                return (i0, i1, t - Float(i0))
            }
        }
        let xt = taps(map.columns, source.width), yt = taps(map.rows, source.height)
        let sw = source.width
        source.rgba.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let (y0, y1, fy) = yt[y]
                    var d = y * w * 4
                    for x in 0..<w {
                        let (x0, x1, fx) = xt[x]
                        let a = (y0 * sw + x0) * 4, b = (y0 * sw + x1) * 4
                        let c = (y1 * sw + x0) * 4, e = (y1 * sw + x1) * 4
                        for k in 0..<3 {
                            let top = Float(s[a + k]) * (1 - fx) + Float(s[b + k]) * fx
                            let bottom = Float(s[c + k]) * (1 - fx) + Float(s[e + k]) * fx
                            o[d + k] = UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
                        }
                        d += 4
                    }
                }
            }
        }
        return Plane(width: w, height: h, rgba: out)
    }

    // MARK: Resize, compose, encode

    /// Area-average resize (each output pixel is the mean of the source area
    /// it covers), separable. Upscales fall back to the nearest source pixel.
    static func resize(_ source: Plane, width: Int, height: Int) -> Plane {
        guard width > 0, height > 0, source.width > 0, source.height > 0 else {
            return Plane(width: max(width, 0), height: max(height, 0), rgba: [])
        }
        if width == source.width && height == source.height { return source }
        // Weights of the source pixels each output pixel covers along one axis.
        func spans(_ n: Int, _ m: Int) -> [[(Int, Float)]] {
            let scale = Float(m) / Float(n)
            return (0..<n).map { i in
                let a = Float(i) * scale, b = Float(i + 1) * scale
                if scale <= 1 { return [(min(Int(a + scale / 2), m - 1), 1)] }
                var out: [(Int, Float)] = []
                var j = Int(a)
                while Float(j) < b && j < m {
                    let lo = max(a, Float(j)), hi = min(b, Float(j + 1))
                    if hi > lo { out.append((j, (hi - lo) / scale)) }
                    j += 1
                }
                return out
            }
        }
        let xs = spans(width, source.width), ys = spans(height, source.height)
        // Horizontal pass into floats, then vertical.
        var mid = [Float](repeating: 0, count: width * source.height * 3)
        source.rgba.withUnsafeBufferPointer { s in
            for y in 0..<source.height {
                for x in 0..<width {
                    var acc: (Float, Float, Float) = (0, 0, 0)
                    for (j, wgt) in xs[x] {
                        let i = (y * source.width + j) * 4
                        acc.0 += Float(s[i]) * wgt; acc.1 += Float(s[i + 1]) * wgt; acc.2 += Float(s[i + 2]) * wgt
                    }
                    let m = (y * width + x) * 3
                    mid[m] = acc.0; mid[m + 1] = acc.1; mid[m + 2] = acc.2
                }
            }
        }
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var acc: (Float, Float, Float) = (0, 0, 0)
                for (j, wgt) in ys[y] {
                    let m = (j * width + x) * 3
                    acc.0 += mid[m] * wgt; acc.1 += mid[m + 1] * wgt; acc.2 += mid[m + 2] * wgt
                }
                let d = (y * width + x) * 4
                out[d] = UInt8(max(0, min(255, acc.0.rounded())))
                out[d + 1] = UInt8(max(0, min(255, acc.1.rounded())))
                out[d + 2] = UInt8(max(0, min(255, acc.2.rounded())))
            }
        }
        return Plane(width: width, height: height, rgba: out)
    }

    /// The eyes next to each other, left first, top-aligned; a shorter one
    /// is padded with black.
    static func sideBySide(_ left: Plane, _ right: Plane) -> Plane {
        let w = left.width + right.width, h = max(left.height, right.height)
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            let d = y * w * 4
            if y < left.height {
                out.rgba.replaceSubrange(d..<(d + left.width * 4),
                                         with: left.rgba[(y * left.width * 4)..<((y + 1) * left.width * 4)])
            }
            if y < right.height {
                let r = d + left.width * 4
                out.rgba.replaceSubrange(r..<(r + right.width * 4),
                                         with: right.rgba[(y * right.width * 4)..<((y + 1) * right.width * 4)])
            }
        }
        return out
    }

    /// The size an image gets when its width is capped at `maxWidth`
    /// (0 = no cap), keeping the aspect ratio.
    static func fitted(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard maxWidth > 0, width > maxWidth else { return (width, height) }
        return (maxWidth, max(1, Int((Double(height) * Double(maxWidth) / Double(width)).rounded())))
    }

    /// PNG bytes, tagged sRGB.
    static func png(_ plane: Plane) -> Data? {
        guard plane.width > 0, plane.height > 0, plane.rgba.count == plane.width * plane.height * 4,
              let provider = CGDataProvider(data: Data(plane.rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: plane.width, height: plane.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: plane.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
