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
        var dyn: Int?           // the studio slot it names
    }
    private struct DynSlot {
        let vertices: MTLBuffer
        let materials: MTLBuffer
        let structure: MTLAccelerationStructure?
        let capacity: Int
    }
    static let maxInstances = 512
    static let slotCount = 3
    private var slots: [Slot] = []
    private let tlasScratch: MTLBuffer
    private var current: Int?
    private var pending: [Instance]?
    private var built: [Instance]?
    private var builtDynamic = false
    // studio models: a ring of slots, each this frame's triangles and their BLAS
    static let maxDynamic = 65536
    static let maxDynTextures = 1024
    private var dynSlots: [DynSlot] = []
    private var dynCounts: [(Int, Int)] = Array(repeating: (0, 0), count: 3)
    private var dynScratch: MTLBuffer?
    private var dynSlotOf: [Int: Int] = [:]
    private var dynTextures: [MTLTexture] = []
    private var dynReady: [Bool] = []
    private let dynTextureTable: MTLBuffer
    private let storage: MTLStorageMode
    private var newAllocations: [MTLAllocation] = []
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
        self.storage = storage

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
        guard let dynTable = device.makeBuffer(length: Self.maxDynTextures * MemoryLayout<MTLResourceID>.stride, options: .storageModeShared) else { return nil }
        dynTable.label = "RTWaterSkinTable"
        dynTextureTable = dynTable
        // three studio slots, empty until the first studio model (the
        // trace still binds the first one's buffers)
        for i in 0..<3 {
            guard let v = device.makeBuffer(length: 72, options: .storageModeShared),
                  let m = device.makeBuffer(length: 4, options: .storageModeShared) else { return nil }
            v.label = "RTWaterStudioVertices\(i)"; m.label = "RTWaterStudioMaterials\(i)"
            dynSlots.append(DynSlot(vertices: v, materials: m, structure: nil, capacity: 0))
        }
        allocations = [vb, ib, mb, db, table, lmt, dynTable] + tex + slots.flatMap { [$0.structure, $0.info] as [MTLAllocation] }
            + dynSlots.flatMap { [$0.vertices, $0.materials] as [MTLAllocation] }
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

    // MARK: Studio models

    /// The frame's studio triangles as the engine captured them
    /// (vr_scene_dyntri_t: three RTDynVertex, then the engine texture
    /// index; 76 bytes each), opaque first.
    struct Dynamic {
        let triangles: UnsafeRawPointer
        let count: Int
        let numOpaque: Int
        static let stride = 76
    }

    /// A skin's slot in the dynamic texture table, made on first sight
    /// (returned as `created` so the caller fills it: a copy, an upload);
    /// it is sampled once marked ready.
    func dynamicTexture(engineIndex: Int, width: Int, height: Int) -> (slot: Int, created: MTLTexture?) {
        lock.lock(); defer { lock.unlock() }
        if let slot = dynSlotOf[engineIndex] { return (slot, nil) }
        guard dynTextures.count < Self.maxDynTextures, width > 0, height > 0 else { return (-1, nil) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        d.usage = [.shaderRead, .renderTarget, .pixelFormatView]
        d.storageMode = storage
        guard let t = device.makeTexture(descriptor: d) else { return (-1, nil) }
        t.label = "RTWaterSkin\(engineIndex)"
        let slot = dynTextures.count
        dynTextures.append(t)
        dynReady.append(false)
        dynSlotOf[engineIndex] = slot
        dynTextureTable.contents().bindMemory(to: MTLResourceID.self, capacity: Self.maxDynTextures)[slot] = t.gpuResourceID
        newAllocations.append(t)
        allocations.append(t)
        return (slot, t)
    }

    func markDynamicTextureReady(_ slot: Int) {
        lock.withLock { if slot >= 0, slot < dynReady.count { dynReady[slot] = true } }
    }

    /// Allocations made since the last call (skins, grown studio slots),
    /// for the caller's residency set.
    func takeNewAllocations() -> [MTLAllocation] {
        lock.withLock { defer { newAllocations = [] }; return newAllocations }
    }

    /// A studio slot that holds at least `count` triangles.
    private func ensureDynamicCapacity(_ slot: Int, _ count: Int, numOpaque: Int) -> Bool {
        if dynSlots[slot].capacity >= count { return true }
        var cap = max(dynSlots[slot].capacity, 4096)
        while cap < count { cap *= 2 }
        cap = min(cap, Self.maxDynamic)
        guard cap >= count,
              let v = device.makeBuffer(length: cap * 3 * MemoryLayout<RTDynVertex>.stride, options: .storageModeShared),
              let m = device.makeBuffer(length: cap * 4, options: .storageModeShared) else { return false }
        v.label = "RTWaterStudioVertices\(slot)"; m.label = "RTWaterStudioMaterials\(slot)"
        dynSlots[slot] = DynSlot(vertices: v, materials: m, structure: dynSlots[slot].structure, capacity: cap)
        newAllocations += [v, m]
        allocations += [v, m]
        return true
    }

    /// The studio slot's BLAS, big enough for this build (and its scratch).
    private func dynamicStructure(_ slot: Int, for desc: MTLPrimitiveAccelerationStructureDescriptor) -> MTLAccelerationStructure? {
        let sizes = device.accelerationStructureSizes(descriptor: desc)
        if dynScratch == nil || dynScratch!.length < Int(sizes.buildScratchBufferSize) {
            dynScratch = device.makeBuffer(length: Int(Double(sizes.buildScratchBufferSize) * 1.5) + 256, options: .storageModePrivate)
        }
        if let st = dynSlots[slot].structure, st.size >= Int(sizes.accelerationStructureSize) { return st }
        guard let st = device.makeAccelerationStructure(size: Int(Double(sizes.accelerationStructureSize) * 1.5)) else { return nil }
        st.label = "RTWaterStudioBLAS\(slot)"
        let old = dynSlots[slot]
        dynSlots[slot] = DynSlot(vertices: old.vertices, materials: old.materials, structure: st, capacity: old.capacity)
        newAllocations.append(st)
        allocations.append(st)
        return st
    }

    private func dynamicDescriptor(_ vertices: MTLBuffer, opaque: Int, alpha: Int) -> MTLPrimitiveAccelerationStructureDescriptor {
        func geometry(_ first: Int, _ count: Int, _ isOpaque: Bool) -> MTLAccelerationStructureTriangleGeometryDescriptor {
            let g = MTLAccelerationStructureTriangleGeometryDescriptor()
            g.vertexBuffer = vertices
            g.vertexBufferOffset = first * 3 * MemoryLayout<RTDynVertex>.stride
            g.vertexFormat = .float3
            g.vertexStride = MemoryLayout<RTDynVertex>.stride
            g.triangleCount = count
            g.opaque = isOpaque
            return g
        }
        var geometries: [MTLAccelerationStructureTriangleGeometryDescriptor] = []
        if opaque > 0 { geometries.append(geometry(0, opaque, true)) }
        if alpha > 0 { geometries.append(geometry(opaque, alpha, false)) }
        let d = MTLPrimitiveAccelerationStructureDescriptor()
        d.geometryDescriptors = geometries
        return d
    }

    // MARK: Per frame

    /// The instances to trace from the next build on (the world first) and
    /// the frame's studio triangles (their skins already given slots by
    /// dynamicTexture). Rebuilds the TLAS when either changed (studio models
    /// move every frame) and a slot is free; frame: the frame about to
    /// trace, completedFrame: the newest the GPU finished.
    func update(instances: [Instance], dynamic: Dynamic? = nil, frame: UInt64, completedFrame: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard blasReady else { return }
        let hasDynamic = (dynamic?.count ?? 0) > 0
        if !hasDynamic, !builtDynamic, instances == built || instances == pending { return }
        // a TLAS slot no frame in flight reads, and a studio slot no such TLAS names
        guard !slots.contains(where: { $0.building }),
              let free = slots.indices.first(where: { $0 != current && slots[$0].lastUsedFrame <= completedFrame }) else { return }
        var dynSlot: Int?
        if let dynamic, hasDynamic {
            let busy = Set(slots.indices.filter { $0 == current || slots[$0].lastUsedFrame > completedFrame }.compactMap { slots[$0].dyn })
            guard let ds = dynSlots.indices.first(where: { !busy.contains($0) }),
                  ensureDynamicCapacity(ds, min(dynamic.count, Self.maxDynamic), numOpaque: dynamic.numOpaque) else { return }
            let n = min(dynamic.count, Self.maxDynamic)
            let v = dynSlots[ds].vertices.contents(), m = dynSlots[ds].materials.contents().bindMemory(to: UInt32.self, capacity: n)
            for i in 0..<n {
                let src = dynamic.triangles + i * Dynamic.stride
                (v + i * 72).copyMemory(from: src, byteCount: 72)
                let texture = Int(src.load(fromByteOffset: 72, as: Int32.self))
                var flags: UInt32 = i >= dynamic.numOpaque ? 1 : 0     // masked (the shader knows by geometry)
                var slot: UInt32 = 0
                if let s = dynSlotOf[texture], dynReady[s] { slot = UInt32(s) } else { flags |= 4 }   // RT_UNTEXTURED
                m[i] = slot | (flags << 24)
            }
            dynSlot = ds
            dynCounts[ds] = (n, min(dynamic.numOpaque, n))
        }

        let stride = MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride
        let d = slots[free].descriptors.contents().bindMemory(to: MTLIndirectAccelerationStructureInstanceDescriptor.self, capacity: Self.maxInstances)
        let info = slots[free].info.contents().bindMemory(to: RTInstanceInfo.self, capacity: Self.maxInstances)
        var n = 0
        var used: [MTLAccelerationStructure] = []
        func add(_ structure: MTLAccelerationStructure, _ m: [Float], _ i: RTInstanceInfo, _ user: UInt32) {
            var desc = MTLIndirectAccelerationStructureInstanceDescriptor()
            desc.transformationMatrix = MTLPackedFloat4x3(columns: (
                MTLPackedFloat3Make(m[0], m[4], m[8]), MTLPackedFloat3Make(m[1], m[5], m[9]),
                MTLPackedFloat3Make(m[2], m[6], m[10]), MTLPackedFloat3Make(m[3], m[7], m[11])))
            desc.options = []
            desc.mask = 0xFF
            desc.intersectionFunctionTableOffset = 0
            desc.userID = user
            desc.accelerationStructureID = structure.gpuResourceID
            d[n] = desc
            info[n] = i
            used.append(structure)
            n += 1
        }
        for inst in instances where n < Self.maxInstances - 1 {
            guard inst.model >= 0, inst.model < models.count, let b = blas[inst.model], inst.matrix.count == 12 else { continue }
            let model = models[inst.model]
            add(b, inst.matrix, RTInstanceInfo(firstTri: UInt32(model.firstTri), numOpaque: UInt32(model.numOpaque),
                                               alphaGeometry: alphaGeometry[inst.model], flags: 0), UInt32(inst.model))
        }
        guard let cb = queue.makeCommandBuffer() else { return }
        if let ds = dynSlot {
            let (count, opaque) = dynCounts[ds]
            let desc = dynamicDescriptor(dynSlots[ds].vertices, opaque: opaque, alpha: count - opaque)
            guard let structure = dynamicStructure(ds, for: desc), let scratch = dynScratch,
                  let enc = cb.makeAccelerationStructureCommandEncoder() else { return }
            enc.build(accelerationStructure: structure, descriptor: desc, scratchBuffer: scratch, scratchBufferOffset: 0)
            enc.endEncoding()
            let alpha: UInt32 = count > opaque ? (opaque > 0 ? 1 : 0) : .max
            add(structure, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0],
                RTInstanceInfo(firstTri: 0, numOpaque: UInt32(opaque), alphaGeometry: alpha, flags: 1), 0xFFFF)
        }
        guard n > 0 else { return }
        let desc = MTLInstanceAccelerationStructureDescriptor()
        desc.instanceDescriptorType = .indirect
        desc.instanceDescriptorBuffer = slots[free].descriptors
        desc.instanceDescriptorStride = stride
        desc.instanceCount = n
        guard let enc = cb.makeAccelerationStructureCommandEncoder() else { return }
        cb.label = "RTWater TLAS"
        // indirect instances name their BLAS by resource ID only
        enc.useResources(used, usage: .read)
        enc.build(accelerationStructure: slots[free].structure, descriptor: desc, scratchBuffer: tlasScratch, scratchBufferOffset: 0)
        enc.endEncoding()
        slots[free].building = true
        slots[free].dyn = dynSlot
        pending = instances
        cb.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            self.lock.withLock {
                self.slots[free].building = false
                if cb.error == nil {
                    self.current = free
                    self.built = instances
                    self.builtDynamic = hasDynamic
                    self.tlasBuilds += 1
                    if cb.gpuEndTime > cb.gpuStartTime { self.lastBuildMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000 }
                }
                if self.pending == instances { self.pending = nil }
            }
        }
        cb.commit()
    }

    /// What the trace binds: the newest finished TLAS, its instance table and
    /// the studio slot it names (or the first, unread), marked as used by
    /// frame; nil until the first build is done.
    func structure(for frame: UInt64) -> (tlas: MTLAccelerationStructure, info: MTLBuffer,
                                          dynVertices: MTLBuffer, dynMaterials: MTLBuffer)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        slots[c].lastUsedFrame = max(slots[c].lastUsedFrame, frame)
        let ds = dynSlots[slots[c].dyn ?? 0]
        return (slots[c].structure, slots[c].info, ds.vertices, ds.materials)
    }

    /// The skins' table and textures (for useResources).
    var dynamicTextures: (table: MTLBuffer, textures: [MTLTexture]) {
        lock.withLock { (dynTextureTable, dynTextures) }
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
