//
//  GlassProbe.swift
//  LambdaVision
//
//  Modern lighting tier 1: the environment the glass and water reflect
//  (Renderer.glassReflections / waterReflections; Shaders.metal glassShade).
//  Water rows of the engine's plane table (r_vrwater) count as "glass in
//  sight" here too, so a flooded room keeps the probe fresh.
//
//  The first prototype reflected the eye's own frame: the reflected ray was
//  projected back into that eye's image and sampled there, with a flat colour
//  where it left the frame. On the headset that popped between a reflection
//  and none as the gaze moved, and since each eye's frame holds different
//  content, the two eyes disagreed (worst looking sideways). This replaces it
//  with an environment probe fixed in the world: six 90° views of the room
//  rendered by the engine from the player's head (ref/gl R_VRProbeFace) into
//  textures of ours, colour and depth, sampled by both eyes with
//  parallax-corrected lookups. Same reflection whatever the gaze, same for
//  both eyes but for true parallax.
//
//  Cost control: the engine draws one 256² face per frame, after the second
//  eye, and only while glass is in sight (the engine's plane table is not
//  empty) and the probe is stale — the head has moved 48 units from where it
//  was captured, or 4 s have passed (doors, lights). Otherwise nothing. A face
//  is world and brush entities only (no studio models, sprites, particles or
//  glass), so the extra view is cheap; its GPU and worker CPU times are logged
//  as gProbe / probeCPU. Three probe slots: the current one, the one fading
//  out, and the one being filled, so nothing the composite still reads is
//  ever drawn into; a completed probe fades in over 0.3 s instead of popping.
//

import Metal
import simd

/// Which probe face the engine draws each frame, and which probes the
/// composite blends. Pure state, no Metal.
struct GlassProbeSchedule {
    static let slotCount = 3
    /// Head movement (xash units) after which the probe is recaptured.
    static let refreshDistance: Float = 48
    /// Recapture this often while glass is in sight (doors open, lights change).
    static let refreshAge: Double = 4
    /// Keep capturing this long after the last glass left the view.
    static let glassMemory: Double = 1
    /// A completed probe fades in over this long.
    static let fadeSeconds: Double = 0.3
    /// A probe this far from the head (a teleport, a level change) is dropped
    /// at once rather than faded out.
    static let dropDistance: Float = 512
    /// Frames a freed slot rests before it is drawn into again: the composite
    /// of frames still in flight may be reading it (Metal 4 tracks no hazards).
    static let restFrames = maxBuffersInFlight

    struct Slot {
        var origin = SIMD3<Float>()
        var faces = 0
        var startedAt = 0.0
    }
    private(set) var slots = [Slot](repeating: Slot(), count: slotCount)
    private(set) var current: Int?
    private(set) var older: Int?
    private(set) var filling: Int?
    private var swappedAt = -Double.infinity
    private var lastGlass = -Double.infinity
    private var rest = 0

    mutating func reset() {
        current = nil; older = nil; filling = nil
        swappedAt = -.infinity
        rest = Self.restFrames
    }

    /// The face to draw this frame, if any: its slot, face (0–5) and origin.
    mutating func next(now: Double, head: SIMD3<Float>, glassInSight: Bool) -> (slot: Int, face: Int, origin: SIMD3<Float>)? {
        if glassInSight { lastGlass = now }
        if let c = current, simd_distance(slots[c].origin, head) > Self.dropDistance {
            reset()
        }
        if rest > 0 { rest -= 1; return nil }
        if let f = filling { return (f, slots[f].faces, slots[f].origin) }
        guard now - lastGlass <= Self.glassMemory, now - swappedAt >= Self.fadeSeconds else { return nil }
        if let c = current, simd_distance(slots[c].origin, head) <= Self.refreshDistance,
           now - slots[c].startedAt < Self.refreshAge {
            return nil
        }
        guard let f = (0..<Self.slotCount).first(where: { $0 != current && $0 != older }) else { return nil }
        slots[f] = Slot(origin: head, faces: 0, startedAt: now)
        filling = f
        return (f, 0, head)
    }

    /// The face staged by next() was drawn (the frame's second eye ran). The
    /// sixth completes the probe, which starts fading in this frame: the
    /// eye's fence orders the composite after it.
    mutating func faceDrawn(now: Double) {
        guard let f = filling else { return }
        slots[f].faces += 1
        guard slots[f].faces == 6 else { return }
        older = current
        current = f
        filling = nil
        swappedAt = now
        rest = Self.restFrames
    }

    /// The probes to blend: the one fading out (nil = the ambient colour),
    /// the current one (nil = none yet), and the current one's weight.
    func blend(now: Double) -> (older: Int?, current: Int?, weight: Float) {
        guard let c = current else { return (nil, nil, 0) }
        let w = Float(min(max((now - swappedAt) / Self.fadeSeconds, 0), 1))
        return (w < 1 ? older : nil, c, w)
    }
}

/// The probe textures and the per-frame calls into the engine.
final class GlassProbe {
    static let faceSize = 256
    static let slices = GlassProbeSchedule.slotCount * 6

    let color: MTLTexture
    let depth: MTLTexture
    private let colorFaces: [MTLTexture]
    private let depthFaces: [MTLTexture]
    private var schedule = GlassProbeSchedule()
    private var staged = false
    private var lastLog = 0.0

    /// colorFormat: the engine colour target's, which ANGLE is known to
    /// render into; depth is depth32Float_stencil8 like the eyes'.
    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        func array(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = Self.faceSize
            d.height = Self.faceSize
            d.arrayLength = Self.slices
            d.usage = [.renderTarget, .shaderRead, .pixelFormatView]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let color = array(colorFormat), let depth = array(.depth32Float_stencil8) else { return nil }
        color.label = "GlassProbeColor"
        depth.label = "GlassProbeDepth"
        self.color = color
        self.depth = depth
        colorFaces = (0..<Self.slices).map {
            color.makeTextureView(pixelFormat: colorFormat, textureType: .type2D, levels: 0..<1, slices: $0..<($0 + 1))!
        }
        depthFaces = (0..<Self.slices).map {
            depth.makeTextureView(pixelFormat: .depth32Float_stencil8, textureType: .type2D, levels: 0..<1, slices: $0..<($0 + 1))!
        }
    }

    /// A level load or the toggle going off: forget every capture.
    func reset() {
        schedule.reset()
        staged = false
        lambda_gl_worker_set_probe_face(nil, nil, 0, 0, nil)
    }

    /// Before the second eye's render: hand the engine this frame's face, if
    /// one is due. eyes: last frame's (the head is between them).
    func stageFace(now: Double, eyes: [lambda_glass_eye_t]) {
        guard eyes.count == 2 else { return }
        let head = (SIMD3(eyes[0].origin.0, eyes[0].origin.1, eyes[0].origin.2)
                    + SIMD3(eyes[1].origin.0, eyes[1].origin.1, eyes[1].origin.2)) * 0.5
        let glassInSight = eyes[0].count > 0 || eyes[1].count > 0
        staged = false
        guard let job = schedule.next(now: now, head: head, glassInSight: glassInSight) else { return }
        let slice = job.slot * 6 + job.face
        var origin = job.origin
        withUnsafePointer(to: &origin) { op in
            op.withMemoryRebound(to: Float.self, capacity: 3) { fp in
                lambda_gl_worker_set_probe_face(Unmanaged.passUnretained(colorFaces[slice]).toOpaque(),
                                                Unmanaged.passUnretained(depthFaces[slice]).toOpaque(),
                                                Int32(Self.faceSize), Int32(job.face), fp)
            }
        }
        staged = true
    }

    /// After the second eye: the staged face is drawn (or was not, when the
    /// eye did not run; it is staged again next frame).
    func eyesDone(now: Double, secondEyeRan: Bool) {
        guard staged else { return }
        staged = false
        if secondEyeRan {
            schedule.faceDrawn(now: now)
        }
        var ms: [Float] = [0, 0]
        let fresh = lambda_gl_probe_ms(&ms)
        if fresh & 1 != 0 { FrameTimingStats.shared.add("gProbe", Double(ms[0])) }
        if fresh & 2 != 0 { FrameTimingStats.shared.add("probeCPU", Double(ms[1])) }
    }

    /// DisplayParams.probe / probeMix for this frame's composite.
    func shaderParams(now: Double) -> (probe: (SIMD4<Float>, SIMD4<Float>), mix: SIMD4<Float>) {
        let b = schedule.blend(now: now)
        func entry(_ slot: Int?) -> SIMD4<Float> {
            guard let slot else { return SIMD4(0, 0, 0, -1) }
            return SIMD4(schedule.slots[slot].origin, Float(slot * 6))
        }
        return ((entry(b.older), entry(b.current)),
                SIMD4(b.weight, Renderer.engineZNear, Renderer.engineZFar, 0))
    }
}
