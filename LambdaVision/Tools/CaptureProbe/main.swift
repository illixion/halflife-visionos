// Drives the debug server's frame-capture image path on the Mac:
// FrameImage.swift is compiled verbatim (build.sh), so what passes here is
// what the app runs off its render thread. Exits non-zero on the first
// failure. With --serve it then answers GET /screenshot with a synthetic
// stereo frame (DebugTrace's envelope for errors), so
// scripts/avp-screenshot.sh can be tested without a headset.

import CoreGraphics
import Foundation
import ImageIO
import Network

func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
func check(_ ok: Bool, _ m: @autoclosure () -> String) { if !ok { die(m()) } }

typealias Plane = FrameImage.Plane

func near(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), _ tol: Int) -> Bool {
    abs(Int(a.0) - Int(b.0)) <= tol && abs(Int(a.1) - Int(b.1)) <= tol && abs(Int(a.2) - Int(b.2)) <= tol
}

/// A test card: red/green gradients plus a blue grid, so geometry errors show.
func card(_ w: Int, _ h: Int) -> Plane {
    var p = Plane(width: w, height: h)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            p.rgba[i] = UInt8(x * 255 / max(w - 1, 1))
            p.rgba[i + 1] = UInt8(y * 255 / max(h - 1, 1))
            p.rgba[i + 2] = (x % 32 < 2 || y % 32 < 2) ? 255 : 0
        }
    }
    return p
}

// MARK: Decode

do {
    // One BGRA8 pixel, one RGBA8 pixel.
    let bgra: [UInt8] = [10, 20, 30, 0]
    let p = bgra.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 1, bytesPerRow: 4, layout: .bgra8) }
    check(p.pixel(0, 0) == (30, 20, 10) && p.rgba[3] == 255, "bgra8 swizzle/alpha: \(p.rgba)")
    let q = bgra.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 1, bytesPerRow: 4, layout: .rgba8) }
    check(q.pixel(0, 0) == (10, 20, 30), "rgba8: \(q.rgba)")

    // rgba16Unorm narrows by rounding.
    let wide: [UInt16] = [65535, 32768, 0, 65535]
    let r = wide.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 1, bytesPerRow: 8, layout: .rgba16Unorm) }
    check(r.pixel(0, 0) == (255, 128, 0), "rgba16Unorm: \(r.rgba)")

    // Half floats are linear: 0.5 → sRGB 188; > 1 clamps; negative/NaN → 0.
    let halves: [UInt16] = [Float16(0.5).bitPattern, Float16(4).bitPattern, Float16(-1).bitPattern, 0]
    let f = halves.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 1, bytesPerRow: 8, layout: .rgba16Float) }
    check(f.pixel(0, 0) == (188, 255, 0), "rgba16Float: \(f.rgba)")

    // 10-bit: red low (rgb10a2) vs blue low (bgr10a2).
    let packed: [UInt32] = [1023 | (512 << 10) | (0 << 20)]
    let a = packed.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 1, bytesPerRow: 4, layout: .rgb10a2) }
    let b = packed.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 1, bytesPerRow: 4, layout: .bgr10a2) }
    check(a.pixel(0, 0) == (255, 128, 0) && b.pixel(0, 0) == (0, 128, 255), "10-bit: \(a.rgba) \(b.rgba)")

    // Row padding and the vertical flip (GL rows run bottom-up).
    let rows: [UInt8] = [1, 1, 1, 0, 9, 9, 9, 9,   // row 0 + 4 bytes padding
                         2, 2, 2, 0, 9, 9, 9, 9]   // row 1
    let up = rows.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 2, bytesPerRow: 8, layout: .rgba8) }
    let down = rows.withUnsafeBytes { FrameImage.decode($0, width: 1, height: 2, bytesPerRow: 8, layout: .rgba8, flipVertically: true) }
    check(up.pixel(0, 0).0 == 1 && up.pixel(0, 1).0 == 2, "row stride: \(up.rgba)")
    check(down.pixel(0, 0).0 == 2 && down.pixel(0, 1).0 == 1, "flip: \(down.rgba)")

    // A short buffer yields an image of the right size, not a crash.
    let short = [UInt8](repeating: 7, count: 4).withUnsafeBytes {
        FrameImage.decode($0, width: 4, height: 4, bytesPerRow: 16, layout: .rgba8)
    }
    check(short.width == 4 && short.rgba.count == 64, "short buffer")
    print("ok: decode (bgra8, rgba8, rgba16Unorm, rgba16Float, 10-bit, stride, flip)")
}

// MARK: Remap and foveation

do {
    let src = card(96, 64)
    let same = FrameImage.remap(src, .uniform(output: (96, 64), source: (96, 64)))
    check(same == src, "uniform remap at the same size must be the identity")

    // A synthetic foveation map in the shape of a rasterization rate map:
    // full rate in the middle half of each axis, half rate outside. Screen
    // (logical) 256 → physical 192 per axis, monotonic and separable.
    let screen = 256
    func toPhysical(_ s: Float) -> Float {
        if s < 64 { return s / 2 }
        if s < 192 { return 32 + (s - 64) }
        return 160 + (s - 192) / 2
    }
    func toScreen(_ p: Float) -> Float {
        if p < 32 { return p * 2 }
        if p < 160 { return 64 + (p - 32) }
        return 192 + (p - 160) * 2
    }
    let logical = card(screen, screen)
    // "Render" the warped physical image: each physical pixel shows the
    // logical content at its screen position (what the GPU does with a rate
    // map bound).
    let phys = 192
    let physMap = FrameImage.AxisMap(columns: (0..<phys).map { toScreen(Float($0) + 0.5) },
                                     rows: (0..<phys).map { toScreen(Float($0) + 0.5) })
    let physical = FrameImage.remap(logical, physMap)
    check(physical.width == phys, "physical size")

    let unwarp = FrameImage.AxisMap.mapped(output: (screen, screen), screen: (screen, screen)) { x, y in
        (toPhysical(x), toPhysical(y))
    }
    let back = FrameImage.remap(physical, unwarp)
    // Full-rate centre comes back exactly; the half-rate rim within the
    // interpolation error of a 2:1 squeeze of a gradient (grid lines blur).
    var worstCentre = 0, worstRim = 0
    for y in stride(from: 1, to: screen - 1, by: 3) {
        for x in stride(from: 1, to: screen - 1, by: 3) {
            let a = back.pixel(x, y), b = logical.pixel(x, y)
            let e = max(abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1)))
            if x >= 72 && x < 184 && y >= 72 && y < 184 { worstCentre = max(worstCentre, e) } else { worstRim = max(worstRim, e) }
        }
    }
    check(worstCentre <= 1, "unwarped centre differs by \(worstCentre)")
    check(worstRim <= 3, "unwarped rim gradient differs by \(worstRim)")
    // The plain physical image is NOT the logical one (the test would be
    // vacuous otherwise): the centre is magnified relative to the rim.
    let naive = FrameImage.resize(physical, width: screen, height: screen)
    check(!near(naive.pixel(40, 128), logical.pixel(40, 128), 4), "warp should be visible without the unwarp")
    print("ok: remap identity; foveation unwarp centre Δ\(worstCentre), rim Δ\(worstRim)")
}

// MARK: Resize, side by side, fit

do {
    // 4×4 checkerboard → 2×2 averages to mid grey.
    var checker = Plane(width: 4, height: 4)
    for y in 0..<4 { for x in 0..<4 where (x + y) % 2 == 0 {
        let i = (y * 4 + x) * 4; checker.rgba[i] = 255; checker.rgba[i + 1] = 255; checker.rgba[i + 2] = 255
    } }
    let half = FrameImage.resize(checker, width: 2, height: 2)
    check(half.width == 2 && half.height == 2, "resize size")
    for y in 0..<2 { for x in 0..<2 { check(near(half.pixel(x, y), (128, 128, 128), 1), "area average: \(half.pixel(x, y))") } }
    // Non-integer ratio keeps a flat field flat.
    let flat = FrameImage.resize(Plane(width: 7, height: 5, fill: (50, 100, 150)), width: 3, height: 2)
    for y in 0..<2 { for x in 0..<3 { check(flat.pixel(x, y) == (50, 100, 150), "flat resize: \(flat.pixel(x, y))") } }
    // Upscale picks nearest.
    let up = FrameImage.resize(Plane(width: 1, height: 1, fill: (9, 8, 7)), width: 3, height: 3)
    check(up.pixel(2, 2) == (9, 8, 7), "upscale")

    let l = Plane(width: 3, height: 2, fill: (255, 0, 0)), r = Plane(width: 2, height: 3, fill: (0, 0, 255))
    let sbs = FrameImage.sideBySide(l, r)
    check(sbs.width == 5 && sbs.height == 3, "side-by-side size \(sbs.width)x\(sbs.height)")
    check(sbs.pixel(2, 1) == (255, 0, 0) && sbs.pixel(3, 2) == (0, 0, 255) && sbs.pixel(0, 2) == (0, 0, 0),
          "side-by-side placement")

    check(FrameImage.fitted(width: 4000, height: 2000, maxWidth: 1600) == (1600, 800), "fit cap")
    check(FrameImage.fitted(width: 800, height: 600, maxWidth: 1600) == (800, 600), "fit no upscale")
    check(FrameImage.fitted(width: 800, height: 600, maxWidth: 0) == (800, 600), "fit 0 = native")
    print("ok: resize, side-by-side, fit")
}

// MARK: PNG

func decodePNG(_ data: Data) -> Plane? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: img.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return true
    }
    return ok ? Plane(width: img.width, height: img.height, rgba: px) : nil
}

do {
    let src = card(64, 48)
    guard let data = FrameImage.png(src) else { die("png encode") }
    check(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG signature")
    guard let back = decodePNG(data) else { die("png decode") }
    check(back.width == 64 && back.height == 48, "png size")
    check(back == src, "png round trip must be lossless")
    check(FrameImage.png(Plane(width: 0, height: 0, rgba: [])) == nil, "empty image → nil")
    print("ok: PNG round trip (\(data.count) bytes)")
}

print("all capture checks passed")

// MARK: --serve

guard CommandLine.arguments.contains("--serve") else { exit(0) }

/// A stereo frame in the shape the app returns: two eyes with a small
/// horizontal disparity, side by side for eye=both.
func syntheticFrame(eye: String, width: Int) -> Data? {
    func one(_ shift: Int) -> Plane {
        var p = card(320, 240)
        for y in 100..<140 { for x in (140 + shift)..<(180 + shift) {
            let i = (y * 320 + x) * 4; p.rgba[i] = 255; p.rgba[i + 1] = 255; p.rgba[i + 2] = 255
        } }
        return p
    }
    var plane: Plane
    switch eye {
    case "left": plane = one(4)
    case "right": plane = one(-4)
    default: plane = FrameImage.sideBySide(one(4), one(-4))
    }
    let size = FrameImage.fitted(width: plane.width, height: plane.height, maxWidth: width)
    plane = FrameImage.resize(plane, width: size.width, height: size.height)
    return FrameImage.png(plane)
}

let port: NWEndpoint.Port = 8651
let listener = try NWListener(using: .tcp, on: port)
listener.newConnectionHandler = { conn in
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let comps = URLComponents(string: "http://x\(target)")
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        var status = "200 OK", type = "application/json", body = Data()
        if comps?.path == "/screenshot" {
            let eye = query["eye"] ?? "both"
            if !["left", "right", "both"].contains(eye) {
                status = "400 Bad Request"
                body = Data(#"{"ok":false,"error":{"code":"invalid_argument","message":"argument 'eye' of 'screenshot' must be one of left, right, both","hint":"did you mean 'left'?"}}"#.utf8)
            } else if let png = syntheticFrame(eye: eye, width: Int(query["width"] ?? "") ?? 1600) {
                type = "image/png"; body = png
            }
        } else {
            status = "404 Not Found"
            body = Data(#"{"ok":false,"error":{"code":"not_found","message":"no endpoint","hint":"GET /screenshot"}}"#.utf8)
        }
        var head = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        head.append(body)
        conn.send(content: head, completion: .contentProcessed { _ in conn.cancel() })
    }
}
listener.start(queue: .main)
print("serving a synthetic frame on http://127.0.0.1:\(port.rawValue)/screenshot (Ctrl-C to stop)")
dispatchMain()
