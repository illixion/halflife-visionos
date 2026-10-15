//
//  PlanarWater.swift
//  LambdaVision
//
//  The engine-rendered water mirror (Renderer.waterMirrorMethod .rendered):
//  after each eye, the engine draws that eye's view again from the eye
//  mirrored in the water below it (gl_rmain.c R_VRMirrorView, called by the
//  GL worker before the eye's fence) into this target's slice. The composite
//  reads it where it would read the screen-space mirror (SharpWater), at the
//  same uv: the mirrored camera keeps the eye's projection, so each water
//  pixel's reflection is where the eye sees the water. Unlike the
//  screen-space mirror it holds what no pixel on screen does, such as a
//  table's underside seen from beside its top. It costs a second engine
//  view per eye on frames with water, at a quarter of the pixels.
//

import Metal

final class PlanarWater {
    let device: MTLDevice
    private(set) var color: MTLTexture?
    private var depth: MTLTexture?
    private var colorSlices: [MTLTexture] = []
    private var depthSlices: [MTLTexture] = []
    private var size = (w: 0, h: 0)
    private var staged = false

    init(device: MTLDevice) {
        self.device = device
    }

    /// The target for this colour map size (divided by divisor), made on
    /// first use or when it changes. Returns the new allocations for the
    /// residency set.
    func ensureTargets(colorMap: MTLTexture, divisor: Int) -> [MTLAllocation] {
        let w = (colorMap.width + divisor - 1) / divisor, h = (colorMap.height + divisor - 1) / divisor
        if color != nil, size.w == w, size.h == h { return [] }
        func array(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = w; d.height = h; d.arrayLength = 2
            d.usage = [.renderTarget, .shaderRead, .pixelFormatView]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // the colour map's format: ANGLE is known to render into it
        guard let c = array(colorMap.pixelFormat), let d = array(.depth32Float_stencil8) else { return [] }
        c.label = "PlanarWaterColor"
        d.label = "PlanarWaterDepth"
        color = c
        depth = d
        colorSlices = (0..<2).map {
            c.makeTextureView(pixelFormat: c.pixelFormat, textureType: .type2D, levels: 0..<1, slices: $0..<($0 + 1))!
        }
        depthSlices = (0..<2).map {
            d.makeTextureView(pixelFormat: .depth32Float_stencil8, textureType: .type2D, levels: 0..<1, slices: $0..<($0 + 1))!
        }
        size = (w, h)
        staged = false
        // the worker keeps a render target per slice view: drop the old ones
        lambda_gl_worker_forget_probe_targets()
        return [c, d]
    }

    /// Before the eyes' renders: hand the engine the targets (on), or take
    /// them back (off). Kept by the engine until changed.
    func stage(_ on: Bool) {
        guard on != staged else { return }
        if on, colorSlices.count == 2 {
            func ptr(_ t: MTLTexture) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(t).toOpaque() }
            lambda_gl_worker_set_mirror_targets(ptr(colorSlices[0]), ptr(depthSlices[0]),
                                                ptr(colorSlices[1]), ptr(depthSlices[1]),
                                                Int32(size.w), Int32(size.h))
            staged = true
        } else {
            lambda_gl_worker_set_mirror_targets(nil, nil, nil, nil, 0, 0)
            staged = false
        }
    }

    /// After the eyes: the mirror's GPU and CPU time into the frame stats
    /// (gPlanar0 / gPlanar1 / planarCPU).
    static func recordTiming() {
        var ms: [Float] = [0, 0, 0]
        let fresh = lambda_gl_mirror_ms(&ms)
        if fresh & 1 != 0 { FrameTimingStats.shared.add("gPlanar0", Double(ms[0])) }
        if fresh & 2 != 0 { FrameTimingStats.shared.add("gPlanar1", Double(ms[1])) }
        if fresh & 4 != 0 { FrameTimingStats.shared.add("planarCPU", Double(ms[2])) }
    }

    /// DisplayParams.sspr for the eyes the engine mirrored this frame: the
    /// screen-space pick (the same rule the engine used), marked rendered
    /// (z = 2) where the engine drew that eye in that water, else off.
    static func planes(_ picked: (SIMD4<Float>, SIMD4<Float>)) -> (SIMD4<Float>, SIMD4<Float>) {
        func mark(_ p: SIMD4<Float>, _ eye: Int32) -> SIMD4<Float> {
            var z: Float = 0
            guard p.z > 0.5, lambda_gl_mirror_eye(eye, &z) != 0, abs(z - p.y) < 0.5 else { return .zero }
            return SIMD4(p.x, p.y, 2, p.w)
        }
        return (mark(picked.0, 0), mark(picked.1, 1))
    }
}
