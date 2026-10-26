//
//  PlanarWater.swift
//  LambdaVision
//
//  The engine-rendered mirror (Renderer.waterMirrorMethod .rendered), for
//  sharp water and sharp glass: after each eye, the engine draws that eye's
//  view again from the eye mirrored in the glass or water plane covering the
//  most of it (gl_rmain.c R_VRMirrorPick, R_VRMirrorView, called by the GL
//  worker before the eye's fence) into this target's slice. The composite
//  reads it on that plane's pixels where it would read the screen-space
//  mirror (SharpWater) or the probe, at the same uv: the mirrored camera
//  keeps the eye's projection, so each pixel's reflection is where the eye
//  sees the plane. Unlike the screen-space mirror it holds what no pixel on
//  screen does, such as a table's underside seen from beside its top or the
//  room behind the player in a window; unlike the probe it is exact, and
//  current every frame. It costs a second engine view per eye on frames
//  with sharp glass or water in sight, at a quarter of the pixels. One plane
//  per eye: other glass and water keep the probe.
//

import Metal

final class PlanarWater {
    let device: MTLDevice
    private(set) var color: MTLTexture?
    private var depth: MTLTexture?
    private var colorSlices: [MTLTexture] = []
    private var depthSlices: [MTLTexture] = []
    private var size = (w: 0, h: 0)
    private var staged: Int32 = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// The target for the mirror base (EngineFoveation.Layout) divided by
    /// divisor, made on first use or when it changes. Returns the new
    /// allocations for the residency set.
    func ensureTargets(base: MTLSize, divisor: Int) -> [MTLAllocation] {
        let w = (base.width + divisor - 1) / divisor, h = (base.height + divisor - 1) / divisor
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
        // RGBA8, not the colour map's 16-bit format: ANGLE renders into both,
        // but resolves multisampling (the bridge's mirror_fbo_for) into 16-bit
        // unorm only on Macs; on the headset every multisampled draw failed and
        // the mirror kept a stale frame. The reflection needs no more bits.
        guard let c = array(.rgba8Unorm), let d = array(.depth32Float_stencil8) else { return [] }
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
        staged = 0
        // the worker keeps a render target per slice view: drop the old ones
        lambda_gl_worker_forget_probe_targets()
        return [c, d]
    }

    /// Before the eyes' renders: hand the engine the targets and which rows
    /// it may mirror (kinds: bit 0 glass, bit 1 water), or take them back
    /// (0). Kept by the engine until changed.
    func stage(kinds: Int32) {
        guard kinds != staged else { return }
        if kinds != 0, colorSlices.count == 2 {
            func ptr(_ t: MTLTexture) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(t).toOpaque() }
            lambda_gl_worker_set_mirror_targets(ptr(colorSlices[0]), ptr(depthSlices[0]),
                                                ptr(colorSlices[1]), ptr(depthSlices[1]),
                                                Int32(size.w), Int32(size.h), kinds)
            staged = kinds
        } else {
            lambda_gl_worker_set_mirror_targets(nil, nil, nil, nil, 0, 0, 0)
            staged = 0
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
    /// row of that eye's glass table it mirrored, marked rendered (z = 2),
    /// else off. The rows are the frame's own (lambda_glass_get_eye).
    static func planes(divisor: Int) -> (SIMD4<Float>, SIMD4<Float>) {
        func mark(_ eye: Int32) -> SIMD4<Float> {
            var row: Int32 = 0
            guard lambda_gl_mirror_eye(eye, &row) != 0 else { return .zero }
            return SIMD4(Float(row), 0, 2, Float(divisor))
        }
        return (mark(0), mark(1))
    }
}
