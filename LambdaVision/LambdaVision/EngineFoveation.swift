//
//  EngineFoveation.swift
//  LambdaVision
//
//  How the engine image covers each eye's screen, and the rate maps for its
//  foveated render (docs/plans/anti-aliasing.md, Phase 2).
//
//  The compositor foveates the drawable through one rasterization rate map
//  with a layer per eye. ANGLE draws each eye into its own 2D slice of the
//  engine's colour map, and Metal applies layer 0 of whatever map a pass
//  binds, so each eye needs a one-layer map of its own (VisionPort/
//  angle-metal-rate-map.patch binds it to the eye's framebuffer). Metal can't
//  copy a compiled map's layers, so each eye's map is rebuilt from the
//  compositor's. A rate map is separable, so its screen-to-physical mapping
//  along one row and one column gives the quality at every screen pixel, and
//  those become the new map's piecewise-linear samples. The vertical samples
//  run in reverse, because ANGLE stores the GL image bottom-up: row 0 of the
//  engine's screen is the bottom of the eye's view, as the composite's
//  fullscreen-triangle uv is.
//
//  Metal rounds quality up when it compiles a map, never down. So a copy is
//  at least as sharp as the compositor's everywhere, for a few percent more
//  pixels (8–9% on a synthetic two-eye map on the Mac). Where both maps run
//  at full rate their layouts differ by a whole number of pixels, so the
//  composite's read there lands on texel centres: the fovea is copied 1:1.
//
//  Shaders find a screen position's texel through per-eye tables
//  (ShaderTypes.h engineTexelPos): a map is separable and its breakpoints fall
//  on whole pixels, so a table per axis, interpolated, is exact. A uniform
//  image (foveation off) gets identity tables, so the shaders have one path.
//

import Metal
import QuartzCore
import DebugTrace

final class EngineFoveation {
    /// What the debug server's /foveation reports: the last layout and the
    /// compositor map it followed. Written on the render thread, read on the
    /// main actor; a torn read at worst shows one rebuild's mix.
    struct Report {
        var foveated = false
        var screen = MTLSize()
        var texture = MTLSize()
        var eyes: [MTLSize] = []
        var qualityScale: Float = 1
        var rebuilds = 0
        var lastRebuildMs: Double = 0
        var compositorLayers = 0
        var compositorScreen = MTLSize()
        var compositorPhysical: [MTLSize] = []
        var granularity = MTLSize()
        /// Physical texels per screen pixel at 33 even steps across each axis
        /// (top-down), per compositor layer and per eye map. The maps are
        /// separable, so one profile per axis describes the whole map.
        var compositorRates: [Profile] = []
        var eyeRates: [Profile] = []
    }
    struct Profile {
        var x: [Float] = []
        var y: [Float] = []
    }
    nonisolated(unsafe) static var report = Report()

    /// The share of the screen the mirror targets' divisors divide when the
    /// image is foveated: the uniform engine image's default size, so the
    /// mirrors keep the resolution and cost they had at render scale 0.75 (and
    /// the screen-space mirror's 10-bit texel keys still fit).
    static let mirrorBaseScale = 0.75

    struct Maps {
        /// One layer each, the engine's (bottom-up) orientation: what ANGLE
        /// rasterises eye i through.
        let eye: [MTLRasterizationRateMap]
        /// The largest physical size of the two eyes.
        let physicalSize: MTLSize
        /// Quality scale applied to fit the targets (1 = the compositor's).
        let qualityScale: Float
    }

    /// How the engine image covers each eye's screen: what the GL worker
    /// renders at and the shaders read with.
    final class Layout {
        /// The engine's render size: its viewport, its 2D layer, the menu's
        /// cursor space (logical pixels when foveated).
        let screen: MTLSize
        /// The texels each slice of the engine targets holds.
        let texture: MTLSize
        /// What the mirror targets' divisors divide.
        let mirrorBase: MTLSize
        /// nil: a uniform image.
        let maps: Maps?
        /// Per-eye screen ↔ texel tables (ShaderTypes.h engineTexelPos).
        let tables: MTLBuffer

        init(screen: MTLSize, texture: MTLSize, mirrorBase: MTLSize, maps: Maps?, tables: MTLBuffer) {
            self.screen = screen
            self.texture = texture
            self.mirrorBase = mirrorBase
            self.maps = maps
            self.tables = tables
        }

        var foveated: Bool { maps != nil }
        /// DisplayParams.engineImage
        var engineImage: SIMD4<Float> {
            SIMD4(Float(screen.width), Float(screen.height), Float(texture.width), Float(texture.height))
        }
        var mirrorBaseParam: SIMD4<Float> {
            SIMD4(Float(mirrorBase.width), Float(mirrorBase.height), 0, 0)
        }
    }

    /// Residency changes for the renderer's set.
    struct Change {
        var add: [MTLAllocation] = []
        var remove: [MTLAllocation] = []
    }

    private let device: MTLDevice
    private(set) var layout: Layout?
    /// Replaced layouts, kept until the last frame that read them completes
    /// (a Metal 4 command buffer doesn't keep its resources alive).
    private var retired: [(layout: Layout, frame: UInt64)] = []
    /// The compositor map's mapping at a few points per axis and layer: a
    /// cheap test of whether it changed since the last rebuild.
    private var fingerprint: [Float] = []
    /// Times the foveated maps were built.
    private(set) var rebuilds = 0
    /// CPU time of the last rebuild, ms.
    private(set) var lastRebuildMs: Double = 0

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Configuration (when the engine targets are made)

    /// A uniform image of `size`: identity tables.
    func configureUniform(size: MTLSize) -> Layout? {
        guard let tables = Self.tables(device: device, screen: size, texture: size, eyeMaps: nil) else { return nil }
        let l = Layout(screen: size, texture: size, mirrorBase: size, maps: nil, tables: tables)
        layout = l
        fingerprint = []
        Self.report = Report(foveated: false, screen: size, texture: size)
        return l
    }

    /// A foveated image following `source`, the compositor's map: its texture
    /// size is the per-eye maps' largest physical size (rounded up to the
    /// map's granularity), and later rebuilds scale quality down to fit it.
    /// nil when the source can't be copied.
    func configureFoveated(source: MTLRasterizationRateMap) -> Layout? {
        guard device.supportsRasterizationRateMap(layerCount: 1),
              let maps = build(from: source, limit: nil) else { return nil }
        let g = max(source.physicalGranularity.width, 1), gh = max(source.physicalGranularity.height, 1)
        let texture = MTLSize(width: (maps.physicalSize.width + g - 1) / g * g,
                              height: (maps.physicalSize.height + gh - 1) / gh * gh, depth: 1)
        let screen = source.screenSize
        let base = MTLSize(width: Int((Double(screen.width) * Self.mirrorBaseScale).rounded()),
                           height: Int((Double(screen.height) * Self.mirrorBaseScale).rounded()), depth: 1)
        guard let tables = Self.tables(device: device, screen: screen, texture: texture, eyeMaps: maps.eye) else { return nil }
        let l = Layout(screen: screen, texture: texture, mirrorBase: base, maps: maps, tables: tables)
        layout = l
        fingerprint = Self.fingerprint(of: source)
        rebuilds += 1
        log(l, source: source)
        return l
    }

    // MARK: - Per frame

    /// Follows the compositor's map: rebuilds the per-eye maps and tables when
    /// it changed. `frame` is the frame about to be encoded (its tables are
    /// what this frame's passes bind), `completedFrame` the last one the GPU
    /// finished, which releases what older frames held.
    func update(from source: MTLRasterizationRateMap?, frame: UInt64, completedFrame: UInt64) -> Change {
        var change = Change()
        while let first = retired.first, first.frame <= completedFrame {
            change.remove.append(first.layout.tables)
            retired.removeFirst()
        }
        guard let current = layout, current.foveated, let source else { return change }
        let print = Self.fingerprint(of: source)
        guard print != fingerprint else { return change }
        let start = CACurrentMediaTime()
        guard let maps = build(from: source, limit: current.texture),
              let tables = Self.tables(device: device, screen: current.screen, texture: current.texture, eyeMaps: maps.eye)
        else { return change }
        let l = Layout(screen: current.screen, texture: current.texture, mirrorBase: current.mirrorBase,
                       maps: maps, tables: tables)
        // The frame being encoded still reads the old tables only if it
        // already bound them, which it hasn't: they're picked up below. The
        // previous frame may still be on the GPU.
        retired.append((current, frame))
        layout = l
        fingerprint = print
        rebuilds += 1
        lastRebuildMs = (CACurrentMediaTime() - start) * 1000
        change.add.append(tables)
        log(l, source: source)
        return change
    }

    private func log(_ l: Layout, source: MTLRasterizationRateMap) {
        guard let maps = l.maps else { return }
        Self.report = Report(foveated: true, screen: l.screen, texture: l.texture,
                             eyes: maps.eye.map { $0.physicalSize(layer: 0) }, qualityScale: maps.qualityScale,
                             rebuilds: rebuilds, lastRebuildMs: lastRebuildMs,
                             compositorLayers: source.layerCount, compositorScreen: source.screenSize,
                             compositorPhysical: (0..<source.layerCount).map { source.physicalSize(layer: $0) },
                             granularity: source.physicalGranularity,
                             compositorRates: (0..<source.layerCount).map { Self.profile(source, layer: $0, bottomUp: false) },
                             eyeRates: maps.eye.map { Self.profile($0, layer: 0, bottomUp: true) })
        let e0 = maps.eye[0].physicalSize(layer: 0), e1 = maps.eye[1].physicalSize(layer: 0)
        let s0 = source.physicalSize(layer: 0), s1 = source.physicalSize(layer: min(1, source.layerCount - 1))
        AppLog.render.log("[Foveation] maps #\(self.rebuilds): screen \(l.screen.width)x\(l.screen.height), texture \(l.texture.width)x\(l.texture.height), eyes \(e0.width)x\(e0.height) / \(e1.width)x\(e1.height) (compositor \(s0.width)x\(s0.height) / \(s1.width)x\(s1.height)), quality ×\(maps.qualityScale, format: .fixed(precision: 3)), \(self.lastRebuildMs, format: .fixed(precision: 2)) ms")
    }

    // MARK: - Map construction

    private func build(from source: MTLRasterizationRateMap, limit: MTLSize?) -> Maps? {
        guard source.layerCount >= 2, source.screenSize.width > 1, source.screenSize.height > 1 else { return nil }
        let screen = source.screenSize
        var curves: [(h: [Float], v: [Float])] = []
        for eye in 0..<2 {
            curves.append((Self.quality(source, layer: eye, horizontal: true),
                           Array(Self.quality(source, layer: eye, horizontal: false).reversed())))
        }
        // Scale quality down until both eyes fit the targets: the copies
        // start within a few percent of the compositor's.
        var scale: Float = 1
        for _ in 0..<12 {
            let layers = curves.map { Self.layer(h: $0.h, v: $0.v, scale: scale) }
            let eyeMaps = layers.compactMap { Self.compile(device, screen, $0) }
            guard eyeMaps.count == 2 else { return nil }
            let p0 = eyeMaps[0].physicalSize(layer: 0), p1 = eyeMaps[1].physicalSize(layer: 0)
            let physical = MTLSize(width: max(p0.width, p1.width), height: max(p0.height, p1.height), depth: 1)
            guard let limit else { return Maps(eye: eyeMaps, physicalSize: physical, qualityScale: scale) }
            if physical.width <= limit.width && physical.height <= limit.height {
                return Maps(eye: eyeMaps, physicalSize: physical, qualityScale: scale)
            }
            let over = max(Float(physical.width) / Float(limit.width), Float(physical.height) / Float(limit.height))
            scale *= min(0.98, 1 / over)
        }
        AppLog.render.error("[Foveation] the per-eye maps don't fit the engine targets")
        return nil
    }

    /// Quality per screen pixel along one axis of a layer: the physical step
    /// per screen pixel, the largest of the steps on either side, since Metal
    /// rounds a sample up and a pixel must not fall below either neighbouring
    /// column's rate.
    private static func quality(_ map: MTLRasterizationRateMap, layer: Int, horizontal: Bool) -> [Float] {
        let screen = map.screenSize
        let n = horizontal ? screen.width : screen.height
        var physical = [Float](repeating: 0, count: n + 1)
        for i in 0...n {
            let c = horizontal ? MTLCoordinate2D(x: Float(i), y: 0) : MTLCoordinate2D(x: 0, y: Float(i))
            let p = map.physicalCoordinates(screenCoordinates: c, layer: layer)
            physical[i] = horizontal ? p.x : p.y
        }
        var q = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let step = physical[i + 1] - physical[i]
            let before = i > 0 ? physical[i] - physical[i - 1] : step
            let after = i + 1 < n ? physical[i + 2] - physical[i + 1] : step
            q[i] = min(1, max(step, max(before, after)))
        }
        return q
    }

    /// Report.Profile of one layer: the mean rate over a 1/32 window around
    /// each step. `bottomUp` reads an eye map's vertical axis top-down, as the
    /// compositor's runs.
    private static func profile(_ map: MTLRasterizationRateMap, layer: Int, bottomUp: Bool) -> Profile {
        let w = Float(map.screenSize.width), h = Float(map.screenSize.height)
        func rate(_ axis: Int, _ t: Float) -> Float {
            let n = axis == 0 ? w : h
            let a = max(0, t - 1 / 64) * n, b = min(1, t + 1 / 64) * n
            let ca = axis == 0 ? MTLCoordinate2D(x: a, y: 0) : MTLCoordinate2D(x: 0, y: a)
            let cb = axis == 0 ? MTLCoordinate2D(x: b, y: 0) : MTLCoordinate2D(x: 0, y: b)
            let pa = map.physicalCoordinates(screenCoordinates: ca, layer: layer)
            let pb = map.physicalCoordinates(screenCoordinates: cb, layer: layer)
            return ((axis == 0 ? pb.x - pa.x : pb.y - pa.y) / (b - a) * 1000).rounded() / 1000
        }
        let steps = (0...32).map { Float($0) / 32 }
        return Profile(x: steps.map { rate(0, $0) },
                       y: steps.map { rate(1, bottomUp ? 1 - $0 : $0) })
    }

    private static func layer(h: [Float], v: [Float], scale: Float) -> MTLRasterizationRateLayerDescriptor {
        let d = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: h.count, height: v.count, depth: 0))
        for (i, q) in h.enumerated() { d.horizontal[i] = min(1, q * scale) }
        for (i, q) in v.enumerated() { d.vertical[i] = min(1, q * scale) }
        return d
    }

    private static func compile(_ device: MTLDevice, _ screen: MTLSize,
                                _ layer: MTLRasterizationRateLayerDescriptor) -> MTLRasterizationRateMap? {
        let d = MTLRasterizationRateMapDescriptor(screenSize: screen, layer: layer)
        d.label = "EngineEyeRateMap"
        return device.makeRasterizationRateMap(descriptor: d)
    }

    private static func fingerprint(of map: MTLRasterizationRateMap) -> [Float] {
        let s = map.screenSize
        var out: [Float] = [Float(s.width), Float(s.height), Float(map.layerCount)]
        for layer in 0..<min(map.layerCount, 2) {
            for i in 0...32 {
                let fx = Float(s.width) * Float(i) / 32, fy = Float(s.height) * Float(i) / 32
                let p = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: fx, y: fy), layer: layer)
                out.append(p.x)
                out.append(p.y)
            }
        }
        return out
    }

    // MARK: - Tables

    /// Per eye: screen x → texel x (W + 1 entries), screen y → texel y
    /// (H + 1), texel x → screen x (TW + 1), texel y → screen y (TH + 1);
    /// identity for a uniform image. The order ShaderTypes.h engineTables
    /// reads.
    static func tables(device: MTLDevice, screen: MTLSize, texture: MTLSize,
                       eyeMaps: [MTLRasterizationRateMap]?) -> MTLBuffer? {
        let w = screen.width, h = screen.height, tw = texture.width, th = texture.height
        let perEye = w + h + tw + th + 4
        var t = [Float](repeating: 0, count: perEye * 2)
        for eye in 0..<2 {
            var o = eye * perEye
            if let m = eyeMaps?[eye] {
                for x in 0...w { t[o + x] = m.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(x), y: 0), layer: 0).x }
                o += w + 1
                for y in 0...h { t[o + y] = m.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: 0, y: Float(y)), layer: 0).y }
                o += h + 1
                for x in 0...tw {
                    t[o + x] = min(Float(w), m.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: Float(x), y: 0), layer: 0).x)
                }
                o += tw + 1
                for y in 0...th {
                    t[o + y] = min(Float(h), m.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: 0, y: Float(y)), layer: 0).y)
                }
            } else {
                for x in 0...w { t[o + x] = Float(x) }
                o += w + 1
                for y in 0...h { t[o + y] = Float(y) }
                o += h + 1
                for x in 0...tw { t[o + x] = Float(x) }
                o += tw + 1
                for y in 0...th { t[o + y] = Float(y) }
            }
        }
        let buffer = t.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        buffer?.label = eyeMaps == nil ? "EngineMapIdentity" : "EngineMapTables"
        return buffer
    }
}
