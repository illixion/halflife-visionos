//
//  RTWaterScene.swift
//  LambdaVision
//
//  The ray-traced water mirror's scene (Renderer.waterMirrorMethod
//  .rayTraced; Shaders.metal rtWaterTrace): the world model's brush
//  triangles as the engine hands them out (gl_vrscene.c R_VRScene), one
//  bottom-level acceleration structure per brush model (an opaque geometry
//  and an alpha-tested one for '{' textures), and a top-level structure over
//  the world and the brush entities where they are drawn this frame (doors,
//  lifts), rebuilt when that changes. Plus the textures and lightmap pages a
//  hit is shaded from: the app copies the engine's own into them (RTWater),
//  the Mac probe uploads a dump's pixels.
//
//  Pure Metal and the shared shader types, so DepthProbe compiles it too.
//  As in Oneiros's RayTracingSystem, every build runs on a plain
//  MTLCommandQueue with the Metal 3 encoder (Metal 4's address-driven builds
//  are Apple9+ only, and the M2 headset and Mac must run this), and a
//  structure is traced only after its build's command buffer completed.
//

import Metal
import simd

final class RTWaterScene {
    struct Model {
        var firstTri: Int
        var numTris: Int
        var numOpaque: Int
    }
    /// A brush model drawn at a transform (model to world, row-major 3×4).
    struct Instance: Equatable {
        var model: Int
        var matrix: [Float]
    }

    let device: MTLDevice
    let generation: Int
    let models: [Model]
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let materials: MTLBuffer
    let density: MTLBuffer
    /// rgba8, mipmapped, the engine's upload sizes, and each one's level 0
    /// (the target of a copy; regenerate the mips after it).
    let textures: [MTLTexture]
    let textureLevel0: [MTLTexture]
    /// One MTLResourceID per texture (RTTexture in the shader).
    let textureTable: MTLBuffer
    /// One slice per lightmap page, and each slice as its own 2D view.
    let lightmaps: MTLTexture
    let lightmapSlices: [MTLTexture]
    let lightmapScale: Float

    private let queue: MTLCommandQueue
    private var blas: [MTLAccelerationStructure?]
    private var alphaGeometry: [UInt32]
    private let lock = NSLock()
    private var blasReady = false
    private var blasDone = false

    // TLAS ring: a slot is rebuilt only once no frame that traced it can
    // still be running (lastUsedFrame <= the caller's completed frame).
    private struct Slot {
        let structure: MTLAccelerationStructure
        let descriptors: MTLBuffer
        let info: MTLBuffer
        var lastUsedFrame: UInt64 = 0
        var building = false
    }
    static let maxInstances = 512
    static let slotCount = 3
    private var slots: [Slot] = []
    private let tlasScratch: MTLBuffer
    private var current: Int?
    private var pending: [Instance]?
    private var built: [Instance]?
    private(set) var tlasBuilds = 0
    private(set) var lastBuildMs: Double = 0

    /// Everything the trace reads, for a residency set or useResources.
    private(set) var allocations: [MTLAllocation] = []

    /// textureSizes: each texture's width and height; lightmapPages and
    /// blockSize: the lightmap pages (square); lightmapScale: what the
    /// engine multiplies their texels by (vr_scene_t.lightmap_scale). storage: .private for the
    /// app (filled by GPU copies), .shared for an upload from the CPU.
    init?(device: MTLDevice, generation: Int,
          vertices: UnsafeRawPointer, vertexCount: Int,
          indices: UnsafeRawPointer, materials: UnsafeRawPointer, density: UnsafeRawPointer, triangleCount: Int,
          models: [Model], textureSizes: [(Int, Int)], lightmapPages: Int, blockSize: Int, lightmapScale: Float,
          storage: MTLStorageMode = .private) {
        guard vertexCount > 0, triangleCount > 0, !models.isEmpty, let queue = device.makeCommandQueue(),
              let vb = device.makeBuffer(bytes: vertices, length: vertexCount * MemoryLayout<RTVertex>.stride),
              let ib = device.makeBuffer(bytes: indices, length: triangleCount * 12),
              let mb = device.makeBuffer(bytes: materials, length: triangleCount * 4),
              let db = device.makeBuffer(bytes: density, length: triangleCount * 4) else { return nil }
        queue.label = "RTWater.build"
        vb.label = "RTWaterVertices"; ib.label = "RTWaterIndices"; mb.label = "RTWaterMaterials"; db.label = "RTWaterDensity"
        self.device = device
        self.generation = generation
        self.queue = queue
        self.models = models
        self.vertices = vb; self.indices = ib; self.materials = mb; self.density = db
        self.lightmapScale = lightmapScale

        var tex: [MTLTexture] = [], level0: [MTLTexture] = []
        for (w, h) in textureSizes {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(w, 1), height: max(h, 1), mipmapped: true)
            d.usage = [.shaderRead, .renderTarget, .pixelFormatView]
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d),
                  let v = t.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D, levels: 0..<1, slices: 0..<1) else { return nil }
            tex.append(t); level0.append(v)
        }
        textures = tex; textureLevel0 = level0
        guard let table = device.makeBuffer(length: max(tex.count, 1) * MemoryLayout<MTLResourceID>.stride, options: .storageModeShared) else { return nil }
        let ids = table.contents().bindMemory(to: MTLResourceID.self, capacity: max(tex.count, 1))
        for (i, t) in tex.enumerated() { ids[i] = t.gpuResourceID }
        table.label = "RTWaterTextureTable"
        textureTable = table

        let ld = MTLTextureDescriptor()
        ld.textureType = .type2DArray
        ld.pixelFormat = .rgba8Unorm
        ld.width = max(blockSize, 1); ld.height = max(blockSize, 1); ld.arrayLength = max(lightmapPages, 1)
        ld.usage = [.shaderRead, .renderTarget, .pixelFormatView]
        ld.storageMode = storage
        guard let lmt = device.makeTexture(descriptor: ld) else { return nil }
        lmt.label = "RTWaterLightmaps"
        lightmaps = lmt
        lightmapSlices = (0..<max(lightmapPages, 1)).map {
            lmt.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D, levels: 0..<1, slices: $0..<($0 + 1))!
        }

        blas = Array(repeating: nil, count: models.count)
        alphaGeometry = Array(repeating: .max, count: models.count)

        let instStride = MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride
        let probe = MTLInstanceAccelerationStructureDescriptor()
        probe.instanceDescriptorType = .indirect
        probe.instanceCount = Self.maxInstances
        probe.instanceDescriptorStride = instStride
        let sizes = device.accelerationStructureSizes(descriptor: probe)
        guard let scratch = device.makeBuffer(length: max(Int(sizes.buildScratchBufferSize), 256), options: .storageModePrivate) else { return nil }
        tlasScratch = scratch
        for i in 0..<Self.slotCount {
            guard let s = device.makeAccelerationStructure(size: Int(sizes.accelerationStructureSize)),
                  let d = device.makeBuffer(length: instStride * Self.maxInstances, options: .storageModeShared),
                  let info = device.makeBuffer(length: MemoryLayout<RTInstanceInfo>.stride * Self.maxInstances, options: .storageModeShared)
            else { return nil }
            s.label = "RTWaterTLAS\(i)"
            slots.append(Slot(structure: s, descriptors: d, info: info))
        }
        allocations = [vb, ib, mb, db, table, lmt] + tex + slots.flatMap { [$0.structure, $0.info] as [MTLAllocation] }
        if !buildBLAS() { return nil }
    }

    /// One BLAS per model with triangles, all in one command buffer.
    private func buildBLAS() -> Bool {
        struct Job { let index: Int; let desc: MTLPrimitiveAccelerationStructureDescriptor; let structure: MTLAccelerationStructure; let scratchOffset: Int }
        var jobs: [Job] = []
        var scratchSize = 0
        for (i, m) in models.enumerated() where m.numTris > 0 {
            var geometries: [MTLAccelerationStructureTriangleGeometryDescriptor] = []
            func geometry(_ first: Int, _ count: Int, opaque: Bool) -> MTLAccelerationStructureTriangleGeometryDescriptor {
                let g = MTLAccelerationStructureTriangleGeometryDescriptor()
                g.vertexBuffer = vertices
                g.vertexFormat = .float3
                g.vertexStride = MemoryLayout<RTVertex>.stride
                g.indexBuffer = indices
                g.indexBufferOffset = first * 12
                g.indexType = .uint32
                g.triangleCount = count
                g.opaque = opaque
                return g
            }
            if m.numOpaque > 0 { geometries.append(geometry(m.firstTri, m.numOpaque, opaque: true)) }
            if m.numTris > m.numOpaque {
                alphaGeometry[i] = UInt32(geometries.count)
                geometries.append(geometry(m.firstTri + m.numOpaque, m.numTris - m.numOpaque, opaque: false))
            }
            let d = MTLPrimitiveAccelerationStructureDescriptor()
            d.geometryDescriptors = geometries
            let sizes = device.accelerationStructureSizes(descriptor: d)
            guard let s = device.makeAccelerationStructure(size: Int(sizes.accelerationStructureSize)) else { return false }
            s.label = "RTWaterBLAS\(i)"
            jobs.append(Job(index: i, desc: d, structure: s, scratchOffset: scratchSize))
            scratchSize += (Int(sizes.buildScratchBufferSize) + 255) & ~255
        }
        guard !jobs.isEmpty, let scratch = device.makeBuffer(length: max(scratchSize, 256), options: .storageModePrivate),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeAccelerationStructureCommandEncoder() else { return false }
        cb.label = "RTWater BLAS"
        for j in jobs {
            enc.build(accelerationStructure: j.structure, descriptor: j.desc, scratchBuffer: scratch, scratchBufferOffset: j.scratchOffset)
            blas[j.index] = j.structure
        }
        enc.endEncoding()
        allocations += jobs.map { $0.structure as MTLAllocation }
        cb.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            self.lock.withLock { self.blasReady = cb.error == nil; self.blasDone = true }
            _ = scratch   // kept alive until the builds are done
        }
        cb.commit()
        return true
    }

    /// The instances to trace from the next build on (the world first).
    /// Rebuilds the TLAS when they changed and a slot is free; frame: the
    /// frame about to trace, completedFrame: the newest the GPU finished.
    func update(instances: [Instance], frame: UInt64, completedFrame: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard blasReady else { return }
        if instances == built || instances == pending { return }
        guard !slots.contains(where: { $0.building }),
              let free = slots.indices.first(where: { $0 != current && slots[$0].lastUsedFrame <= completedFrame }) else { return }
        let stride = MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride
        let d = slots[free].descriptors.contents().bindMemory(to: MTLIndirectAccelerationStructureInstanceDescriptor.self, capacity: Self.maxInstances)
        let info = slots[free].info.contents().bindMemory(to: RTInstanceInfo.self, capacity: Self.maxInstances)
        var n = 0
        var used: [MTLAccelerationStructure] = []
        for inst in instances where n < Self.maxInstances {
            guard inst.model >= 0, inst.model < models.count, let b = blas[inst.model], inst.matrix.count == 12 else { continue }
            let m = inst.matrix
            var desc = MTLIndirectAccelerationStructureInstanceDescriptor()
            desc.transformationMatrix = MTLPackedFloat4x3(columns: (
                MTLPackedFloat3Make(m[0], m[4], m[8]), MTLPackedFloat3Make(m[1], m[5], m[9]),
                MTLPackedFloat3Make(m[2], m[6], m[10]), MTLPackedFloat3Make(m[3], m[7], m[11])))
            desc.options = []
            desc.mask = 0xFF
            desc.intersectionFunctionTableOffset = 0
            desc.userID = UInt32(inst.model)
            desc.accelerationStructureID = b.gpuResourceID
            d[n] = desc
            let model = models[inst.model]
            info[n] = RTInstanceInfo(firstTri: UInt32(model.firstTri), numOpaque: UInt32(model.numOpaque),
                                     alphaGeometry: alphaGeometry[inst.model], pad: 0)
            used.append(b)
            n += 1
        }
        guard n > 0 else { return }
        let desc = MTLInstanceAccelerationStructureDescriptor()
        desc.instanceDescriptorType = .indirect
        desc.instanceDescriptorBuffer = slots[free].descriptors
        desc.instanceDescriptorStride = stride
        desc.instanceCount = n
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeAccelerationStructureCommandEncoder() else { return }
        cb.label = "RTWater TLAS"
        // indirect instances name their BLAS by resource ID only
        enc.useResources(used, usage: .read)
        enc.build(accelerationStructure: slots[free].structure, descriptor: desc, scratchBuffer: tlasScratch, scratchBufferOffset: 0)
        enc.endEncoding()
        slots[free].building = true
        pending = instances
        cb.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            self.lock.withLock {
                self.slots[free].building = false
                if cb.error == nil {
                    self.current = free
                    self.built = instances
                    self.tlasBuilds += 1
                    if cb.gpuEndTime > cb.gpuStartTime { self.lastBuildMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000 }
                }
                if self.pending == instances { self.pending = nil }
            }
        }
        cb.commit()
    }

    /// The newest finished TLAS and its instance table, marked as used by
    /// frame; nil until the first build is done.
    func structure(for frame: UInt64) -> (tlas: MTLAccelerationStructure, info: MTLBuffer)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        slots[c].lastUsedFrame = max(slots[c].lastUsedFrame, frame)
        return (slots[c].structure, slots[c].info)
    }

    /// Whether the BLAS are built (a TLAS can follow).
    var isReady: Bool { lock.withLock { blasReady } }

    /// Blocks until the BLAS and any TLAS build are done, their completion
    /// handlers included (DepthProbe).
    func waitUntilBuilt() {
        let cb = queue.makeCommandBuffer()!
        cb.commit()
        cb.waitUntilCompleted()
        while lock.withLock({ !blasDone || slots.contains { $0.building } }) { usleep(1000) }
    }
}
