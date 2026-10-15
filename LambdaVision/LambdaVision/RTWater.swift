//
//  RTWater.swift
//  LambdaVision
//
//  The ray-traced water mirror (Renderer.waterMirrorMethod .rayTraced): its
//  scene (RTWaterScene) from the GL worker's snapshot of the engine's world
//  triangles, the engine's textures and lightmap pages copied into it by the
//  worker (Lambda_Bridge.c worker_scene_frame), the brush entities' current
//  transforms, and the trace itself (Shaders.metal rtWaterTrace) into a
//  target the composite reads like the screen-space mirror's: premultiplied,
//  empty where the ray leaves the map or meets the sky, so the probe fills
//  in there. One dispatch for both eyes, before the composite, on frames
//  where an eye has horizontal water below it. Timed as gMirror.
//
//  The scene appears a few frames into a map: the snapshot, the BLAS build
//  and the texture copies (32 a frame) come first; until then the composite
//  shows the probe.
//

import DebugTrace
import Metal

final class RTWater {
    let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let argumentTable: MTL4ArgumentTable
    private(set) var color: MTLTexture?
    private var size = (w: 0, h: 0)
    private(set) var scene: RTWaterScene?
    /// Scenes replaced by a newer map, kept until no frame can read them.
    private var retired: [(scene: RTWaterScene, after: UInt64)] = []
    private var mipsDone = false
    private var instances: [lambda_scene_instance_t]
    /// Skins: each one's level-0 view (the worker's copy target, kept alive
    /// until the copy is done) and the ones copied, waiting for mipmaps.
    private var skinViews: [Int: (slot: Int, texture: MTLTexture, view: MTLTexture)] = [:]
    private var skinsToMip: [MTLTexture] = []
    private var copied = [Int32](repeating: 0, count: 256)

    init?(device: MTLDevice, library: MTLLibrary) {
        guard device.supportsRaytracing,
              let f = library.makeFunction(name: "rtWaterTrace"),
              let pipeline = try? device.makeComputePipelineState(function: f) else { return nil }
        self.device = device
        self.pipeline = pipeline
        let at = MTL4ArgumentTableDescriptor()
        at.maxBufferBindCount = 11       // TLAS @ 0 … skin table @ 10, DisplayParams @ BufferIndexUniforms
        at.maxTextureBindCount = 5       // colorMap @ 0, mirror @ 2, engine stencil @ 3, lightmaps @ 4
        guard let table = try? device.makeArgumentTable(descriptor: at) else { return nil }
        argumentTable = table
        instances = Array(repeating: lambda_scene_instance_t(), count: Int(LAMBDA_SCENE_MAX_INSTANCES))
    }

    /// The target for this colour map size (divided by divisor, as
    /// DisplayParams.sspr.w tells the kernel), made on first use or when it
    /// changes. Returns the new allocations for the residency set.
    func ensureTarget(colorMap: MTLTexture, divisor: Int) -> [MTLAllocation] {
        let w = (colorMap.width + divisor - 1) / divisor, h = (colorMap.height + divisor - 1) / divisor
        if color != nil, size.w == w, size.h == h { return [] }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rgba16Float
        d.width = w; d.height = h; d.arrayLength = 2
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        color = device.makeTexture(descriptor: d)
        color?.label = "RTWaterMirror"
        size = (w, h)
        return color.map { [$0] } ?? []
    }

    /// After the eyes, before encode: a new map's scene from the worker's
    /// snapshot (and the worker told where to copy its textures), this
    /// frame's brush instances, and the scenes no frame reads any more.
    /// frame: this frame's end value; completedFrame: the newest the GPU
    /// finished. Returns allocations to add to and to drop from the
    /// residency set.
    func prepare(frame: UInt64, completedFrame: UInt64) -> (add: [MTLAllocation], remove: [MTLAllocation]) {
        var add: [MTLAllocation] = [], remove: [MTLAllocation] = []
        var s = lambda_scene_t()
        let generation = Int(lambda_scene_acquire(&s))
        if generation != 0, generation != scene?.generation, s.num_tris > 0,
           let verts = s.verts, let indices = s.indices, let materials = s.materials,
           let density = s.texel_density, let models = s.models, let textures = s.textures {
            let m = (0..<Int(s.num_models)).map {
                RTWaterScene.Model(firstTri: Int(models[$0].first_tri), numTris: Int(models[$0].num_tris),
                                   numOpaque: Int(models[$0].num_opaque))
            }
            let sizes = (0..<Int(s.num_textures)).map { (Int(textures[$0].width), Int(textures[$0].height)) }
            if let next = RTWaterScene(device: device, generation: generation,
                                       vertices: verts, vertexCount: Int(s.num_verts),
                                       indices: indices, materials: materials, density: density, triangleCount: Int(s.num_tris),
                                       models: m, textureSizes: sizes, lightmapPages: Int(s.num_lightmaps),
                                       blockSize: Int(s.block_size), lightmapScale: s.lightmap_scale) {
                if let old = scene { retired.append((old, frame)) }
                scene = next
                mipsDone = false
                skinViews = [:]
                skinsToMip = []
                add = next.allocations
                AppLog.render.log("[RTWater] map scene \(generation, privacy: .public): \(s.num_tris, privacy: .public) triangles, \(s.num_models, privacy: .public) models, \(s.num_textures, privacy: .public) textures, \(s.num_lightmaps, privacy: .public) lightmap pages")
            }
        }
        lambda_scene_release()
        if let scene, add.count > 0 {
            func ptr(_ t: MTLTexture) -> UnsafeMutableRawPointer? { Unmanaged.passUnretained(t).toOpaque() }
            let tex: [UnsafeMutableRawPointer?] = scene.textureLevel0.map(ptr)
            let lm: [UnsafeMutableRawPointer?] = scene.lightmapSlices.map(ptr)
            tex.withUnsafeBufferPointer { tp in
                lm.withUnsafeBufferPointer { lp in
                    lambda_gl_worker_set_scene_targets(Int32(scene.generation), tp.baseAddress, Int32(tp.count),
                                                       lp.baseAddress, Int32(lp.count))
                }
            }
        }
        // the old scene's allocations go once no frame in flight can read them
        retired.removeAll { r in
            guard r.after <= completedFrame else { return false }
            remove += r.scene.allocations
            return true
        }
        if let scene {
            // skins the worker copied since last frame: mipmapped in this
            // frame's encode, sampled from the next TLAS on
            let ncopied = copied.withUnsafeMutableBufferPointer { Int(lambda_scene_skins_copied($0.baseAddress, Int32($0.count))) }
            for i in copied.prefix(ncopied) {
                guard let skin = skinViews[Int(i)] else { continue }
                skinsToMip.append(skin.texture)
                scene.markDynamicTextureReady(skin.slot)
            }
            let n = instances.withUnsafeMutableBufferPointer {
                Int(lambda_scene_instances($0.baseAddress, Int32($0.count)))
            }
            let list: [RTWaterScene.Instance] = instances.prefix(n).map { i in
                var i = i
                let m = withUnsafeBytes(of: &i.matrix) { Array($0.bindMemory(to: Float.self)) }
                return RTWaterScene.Instance(model: Int(i.model), matrix: m)
            }
            // the studio models eye 0 drew, and a copy of each new skin
            var count: Int32 = 0, opaque: Int32 = 0, skinCount: Int32 = 0
            var skins: UnsafePointer<lambda_scene_skin_t>?
            let tris = lambda_scene_studio_acquire(&count, &opaque, &skins, &skinCount)
            if let skins {
                for k in 0..<Int(skinCount) where skinViews[Int(skins[k].index)] == nil {
                    let info = skins[k]
                    let (slot, created) = scene.dynamicTexture(engineIndex: Int(info.index), width: Int(info.width), height: Int(info.height))
                    guard let t = created,
                          let v = t.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D, levels: 0..<1, slices: 0..<1) else { continue }
                    skinViews[Int(info.index)] = (slot, t, v)
                    lambda_gl_worker_copy_skin(info.index, Unmanaged.passUnretained(v).toOpaque())
                }
            }
            let dynamic = tris.map { RTWaterScene.Dynamic(triangles: $0, count: Int(count), numOpaque: Int(opaque)) }
            scene.update(instances: list, dynamic: dynamic, frame: frame, completedFrame: completedFrame)
            lambda_scene_studio_release()
            add += scene.takeNewAllocations()
        }
        return (add, remove)
    }

    /// Traces both eyes' water into the target, once the scene is ready
    /// (built, textures copied, a TLAS done). paramsAddress: this frame's
    /// DisplayParams (sspr, rtWater, the eyes' views and tangents), which the
    /// caller fills before the command buffer is committed. Returns whether
    /// it traced (else the composite has nothing to read).
    func encode(commandBuffer: MTL4CommandBuffer, colorMap: MTLTexture, engineStencil: MTLTexture,
                paramsAddress: UInt64, frame: UInt64,
                mark: (GPUPassTimer.Mark, MTL4ComputeCommandEncoder) -> Void) -> Bool {
        guard let color, let scene, scene.isReady, Int(lambda_scene_copied()) == scene.generation,
              let bound = scene.structure(for: frame),
              let enc = commandBuffer.makeComputeCommandEncoder() else { return false }
        enc.label = "RTWater"
        // ANGLE's colour, stencil and texture copies (ordered by the queue's
        // wait on its fence), and last frame's composite reading the mirror
        enc.barrier(afterQueueStages: .all, beforeStages: [.dispatch, .blit], visibilityOptions: .device)
        if !mipsDone || !skinsToMip.isEmpty {
            // the copies wrote level 0 only
            if !mipsDone { for t in scene.textures { enc.generateMipmaps(texture: t) } }
            for t in skinsToMip { enc.generateMipmaps(texture: t) }
            enc.barrier(afterEncoderStages: .blit, beforeEncoderStages: .dispatch, visibilityOptions: .device)
            mipsDone = true
            skinsToMip = []
        }
        mark(.mirrorFill, enc)
        argumentTable.setResource(bound.tlas.gpuResourceID, bufferIndex: 0)
        argumentTable.setAddress(scene.vertices.gpuAddress, index: 1)
        argumentTable.setAddress(paramsAddress, index: BufferIndex.uniforms.rawValue)
        argumentTable.setAddress(scene.indices.gpuAddress, index: 3)
        argumentTable.setAddress(scene.materials.gpuAddress, index: 4)
        argumentTable.setAddress(scene.density.gpuAddress, index: 5)
        argumentTable.setAddress(bound.info.gpuAddress, index: 6)
        argumentTable.setAddress(scene.textureTable.gpuAddress, index: 7)
        argumentTable.setAddress(bound.dynVertices.gpuAddress, index: 8)
        argumentTable.setAddress(bound.dynMaterials.gpuAddress, index: 9)
        argumentTable.setAddress(scene.dynamicTextures.table.gpuAddress, index: 10)
        argumentTable.setTexture(colorMap.gpuResourceID, index: 0)
        argumentTable.setTexture(color.gpuResourceID, index: 2)
        argumentTable.setTexture(engineStencil.gpuResourceID, index: 3)
        argumentTable.setTexture(scene.lightmaps.gpuResourceID, index: 4)
        enc.setArgumentTable(argumentTable)
        enc.setComputePipelineState(pipeline)
        enc.dispatchThreads(threadsPerGrid: MTLSize(width: size.w, height: size.h, depth: 2),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        mark(.mirror, enc)
        enc.barrier(afterStages: .dispatch, beforeQueueStages: .all, visibilityOptions: .device)
        enc.endEncoding()
        return true
    }
}
