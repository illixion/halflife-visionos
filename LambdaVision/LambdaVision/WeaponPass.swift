//
//  WeaponPass.swift
//  LambdaVision
//
//  Draws the weapon viewmodel baked by Lambda_WeaponModel.c as a second Metal
//  pass over the engine image. The mesh is uploaded once per model in
//  bone-local space (GoldSrc rigid single-bone skinning: one bone index per
//  vertex); every frame the extractor's published pose — the viewmodel's
//  current idle/shoot/reload sequence at the engine's estimated frame — is
//  copied into a per-frame bone palette and the vertex shader skins with it.
//  Renders into the drawable's colour slice (loadAction .load) with its OWN
//  depth buffer, so the weapon self-occludes correctly and composites on top
//  without disturbing drawable.depthTextures, which the compositor uses for
//  reprojection.
//
//  Coordinates: the baked mesh is in GoldSrc model space (units, Z-up). The
//  caller supplies the model→world (metres, Apple/RealityKit basis) transform,
//  so placement (hand anchor, grip) lives in Renderer, not here; `handBone`
//  exposes the POSED grip-bone frame the caller pins to the tracked hand.
//

import Metal
import CompositorServices
import simd

final class WeaponPass {
    /// UI arc drawn at the tail of the weapon pass: a world-anchored arc
    /// billboard (see ringVertexShader). Used for the reload-progress ring
    /// and the radial weapon menu's sectors. All lengths in Apple world
    /// metres; angles in turns clockwise from 12 o'clock.
    struct Arc {
        var center: SIMD3<Float>
        var right: SIMD3<Float>   // billboard axes (unit)
        var up: SIMD3<Float>
        var innerR: Float
        var outerR: Float
        var color: SIMD4<Float>
        var startTurns: Float
        var sweepTurns: Float
    }
    static let maxArcs = 16
    private static let arcSlotStride = 256   // constant-buffer slot alignment

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let ringPipeline: MTLRenderPipelineState
    private let ringDepthState: MTLDepthStencilState
    private let vertexArgTable: MTL4ArgumentTable
    private let fragmentArgTable: MTL4ArgumentTable
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let layered: Bool

    // Uploaded mesh (deindexed into a flat vertex buffer for drawPrimitives).
    // `flags` are the studio STUDIO_NF_* bits; they differ per submesh, which
    // is why the uniforms are a per-submesh array rather than one struct.
    private struct Submesh {
        var vertexStart: Int
        var vertexCount: Int
        var texture: Int
        var flags: UInt32
    }
    private static let studioChrome: UInt32 = 0x0002
    private static let studioMasked: UInt32 = 0x0040
    private var vertexBuffer: MTLBuffer?
    private var submeshes: [Submesh] = []
    private var textures: [MTLTexture] = []
    private var uploadedGeneration: UInt32 = 0

    // Bone table of the uploaded model and the index of its grip hand bone
    // ("Bip01 R Hand"; -1 when the model has none — then handBone stays
    // identity and the model origin lands on the hand).
    private(set) var boneNames: [String] = []
    private(set) var handBoneIndex: Int = -1
    var hasHandBone: Bool { handBoneIndex >= 0 }

    // Current pose: bone→model-space transforms from the extractor (GoldSrc
    // units), refreshed each frame by update(). `handBone` is the POSED grip
    // bone's frame, so pinning it to the tracked hand keeps the gun and the
    // off-hand animating exactly as authored around a fixed grip.
    private var palette: [float4x4] = []
    private var pose = lambda_weapon_pose_t()
    private(set) var handBone = matrix_identity_float4x4
    private(set) var poseSequence: Int = 0
    private(set) var poseFrame: Float = 0
    private(set) var bbmin = SIMD3<Float>(repeating: 0)
    private(set) var bbmax = SIMD3<Float>(repeating: 0)

    // Per-eye depth, sized to the drawable. Recreated on size change.
    private var depth: MTLTexture?
    private var depthW = 0, depthH = 0, depthSlices = 0

    // Uniform ring (one WeaponUniforms + one bone palette per in-flight frame).
    private var uniformBuffers: [MTLBuffer]
    private var boneBuffers: [MTLBuffer] = []
    private var ringUniformBuffers: [MTLBuffer] = []

    var isReady: Bool { vertexBuffer != nil && !submeshes.isEmpty }

    init(device: MTLDevice, layerRenderer: LayerRenderer, maxBuffersInFlight: Int) {
        self.device = device
        self.colorFormat = layerRenderer.configuration.colorFormat
        self.depthFormat = layerRenderer.configuration.depthFormat
        self.layered = (layerRenderer.configuration.layout == .layered)

        let library = device.makeDefaultLibrary()

        let vd = MTLVertexDescriptor()
        vd.attributes[VertexAttribute.position.rawValue].format = .float3
        vd.attributes[VertexAttribute.position.rawValue].offset = 0
        vd.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vd.attributes[VertexAttribute.normal.rawValue].format = .float3
        vd.attributes[VertexAttribute.normal.rawValue].offset = 12
        vd.attributes[VertexAttribute.normal.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vd.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        vd.attributes[VertexAttribute.texcoord.rawValue].offset = 24
        vd.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vd.attributes[VertexAttribute.boneIndex.rawValue].format = .uint
        vd.attributes[VertexAttribute.boneIndex.rawValue].offset = 32
        vd.attributes[VertexAttribute.boneIndex.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        // The vertex buffer is a straight copy of lambda_weapon_vertex_t
        // (pos@0, normal@12, uv@24, bone@32 — 36 bytes).
        vd.layouts[BufferIndex.meshPositions.rawValue].stride = MemoryLayout<lambda_weapon_vertex_t>.stride

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "WeaponPipeline"
        pd.vertexFunction = library?.makeFunction(name: "weaponVertexShader")
        pd.fragmentFunction = library?.makeFunction(name: "weaponFragmentShader")
        pd.vertexDescriptor = vd
        pd.rasterSampleCount = 1
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat = depthFormat
        pd.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        self.pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .greater   // reverse-Z, matches the engine
        dsd.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsd)!

        // Ring: procedural arc, no vertex descriptor, always on top (it's a
        // UI readout — the weapon must not be able to occlude it).
        let rpdsc = MTLRenderPipelineDescriptor()
        rpdsc.label = "ReloadRingPipeline"
        rpdsc.vertexFunction = library?.makeFunction(name: "ringVertexShader")
        rpdsc.fragmentFunction = library?.makeFunction(name: "ringFragmentShader")
        rpdsc.rasterSampleCount = 1
        rpdsc.colorAttachments[0].pixelFormat = colorFormat
        rpdsc.depthAttachmentPixelFormat = depthFormat
        rpdsc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        self.ringPipeline = try! device.makeRenderPipelineState(descriptor: rpdsc)
        let rdsd = MTLDepthStencilDescriptor()
        rdsd.depthCompareFunction = .always
        rdsd.isDepthWriteEnabled = false
        self.ringDepthState = device.makeDepthStencilState(descriptor: rdsd)!

        let vDesc = MTL4ArgumentTableDescriptor()
        vDesc.maxBufferBindCount = 5            // vertex@0, uniforms@2, viewProj@3, bones@4
        self.vertexArgTable = try! device.makeArgumentTable(descriptor: vDesc)
        let fDesc = MTL4ArgumentTableDescriptor()
        fDesc.maxBufferBindCount = 3            // uniforms@2
        fDesc.maxTextureBindCount = 1           // colour@0
        self.fragmentArgTable = try! device.makeArgumentTable(descriptor: fDesc)

        self.uniformBuffers = (0..<maxBuffersInFlight).map { _ in
            device.makeBuffer(length: Int(WEAPON_UNIFORM_STRIDE) * Int(WEAPON_MAX_SUBMESHES),
                              options: .storageModeShared)!
        }
        self.boneBuffers = (0..<maxBuffersInFlight).map { i in
            let b = device.makeBuffer(length: MemoryLayout<WeaponBonePalette>.stride,
                                      options: .storageModeShared)!
            b.label = "WeaponBones\(i)"
            // Identity palette until the first pose lands.
            let ident = [float4x4](repeating: matrix_identity_float4x4, count: Int(WEAPON_MAX_BONES))
            ident.withUnsafeBytes { _ = memcpy(b.contents(), $0.baseAddress, $0.count) }
            return b
        }
        self.ringUniformBuffers = (0..<maxBuffersInFlight).map { _ in
            device.makeBuffer(length: WeaponPass.arcSlotStride * WeaponPass.maxArcs,
                              options: .storageModeShared)!
        }
    }

    /// Per-frame: poll the extractor — upload a freshly baked model if the
    /// generation moved, then refresh the bone palette from the latest pose.
    func update() {
        uploadIfNeeded()
        refreshPose()
    }

    /// Copy the extractor's latest pose into `palette` / `handBone`. A pose
    /// for a generation other than the uploaded mesh is ignored (the mesh
    /// upload lags the bake by at most a frame, and the bake seeds a matching
    /// pose, so this only skips the hand-over frame).
    private func refreshPose() {
        guard uploadedGeneration != 0 else { return }
        let gen = lambda_weapon_copy_pose(&pose)
        guard gen == uploadedGeneration else { return }
        let count = min(Int(pose.bone_count), Int(WEAPON_MAX_BONES))
        var pal = [float4x4](repeating: matrix_identity_float4x4, count: count)
        withUnsafePointer(to: &pose.bones) { raw in
            raw.withMemoryRebound(to: Float.self, capacity: Int(WEAPON_MAX_BONES) * 12) { f in
                for i in 0..<count {
                    pal[i] = WeaponPass.matrix(fromRowMajor3x4: f + i * 12)
                }
            }
        }
        palette = pal
        poseSequence = Int(pose.sequence)
        poseFrame = pose.frame
        handBone = (handBoneIndex >= 0 && handBoneIndex < count) ? palette[handBoneIndex]
                                                                  : matrix_identity_float4x4
    }

    /// If a new model was baked, deindex + upload it.
    private func uploadIfNeeded() {
        let gen = lambda_weapon_generation()
        if gen == 0 || gen == uploadedGeneration { return }

        var mesh = lambda_weapon_mesh_t()
        let locked = lambda_weapon_lock(&mesh)
        defer { lambda_weapon_unlock() }
        if locked == 0 || mesh.vertex_count == 0 || mesh.index_count == 0 { return }

        // Deindex straight into a flat lambda_weapon_vertex_t array — the
        // vertex descriptor mirrors the C struct byte-for-byte.
        let verts = mesh.vertices!
        let idx = mesh.indices!

        var flat = [lambda_weapon_vertex_t]()
        flat.reserveCapacity(Int(mesh.index_count))
        var subs: [Submesh] = []
        let subsPtr = mesh.submeshes!
        for s in 0..<Int(mesh.submesh_count) {
            let sm = subsPtr[s]
            let start = flat.count
            let base = Int(sm.index_offset)
            for i in 0..<Int(sm.index_count) {
                flat.append(verts[Int(idx[base + i])])
            }
            subs.append(Submesh(vertexStart: start,
                                vertexCount: Int(sm.index_count),
                                texture: Int(sm.texture),
                                flags: sm.flags))
        }

        let vbuf = device.makeBuffer(bytes: flat,
                                     length: flat.count * MemoryLayout<lambda_weapon_vertex_t>.stride,
                                     options: .storageModeShared)
        vbuf?.label = "WeaponVertices"

        // Bone table (names for the grip bone now; part bones later).
        var names: [String] = []
        if let bones = mesh.bones {
            for b in 0..<Int(mesh.bone_count) {
                var entry = bones[b]
                let name = withUnsafePointer(to: &entry.name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
                names.append(name)
            }
        }

        // Textures: expand each RGBA8 blob into a private texture.
        var texs: [MTLTexture] = []
        let texPtr = mesh.textures!
        for t in 0..<Int(mesh.texture_count) {
            let tx = texPtr[t]
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: Int(tx.width), height: Int(tx.height), mipmapped: false)
            td.usage = .shaderRead
            guard let tex = device.makeTexture(descriptor: td), let rgba = tx.rgba else { continue }
            tex.replace(region: MTLRegionMake2D(0, 0, Int(tx.width), Int(tx.height)),
                        mipmapLevel: 0, withBytes: rgba,
                        bytesPerRow: Int(tx.width) * 4)
            texs.append(tex)
        }

        self.vertexBuffer = vbuf
        self.submeshes = subs
        self.textures = texs
        self.boneNames = names
        self.handBoneIndex = Int(mesh.hand_bone_index)
        self.palette = []          // refreshPose() fills it for this generation
        self.handBone = matrix_identity_float4x4
        self.bbmin = SIMD3(mesh.bbmin.0, mesh.bbmin.1, mesh.bbmin.2)
        self.bbmax = SIMD3(mesh.bbmax.0, mesh.bbmax.1, mesh.bbmax.2)
        self.uploadedGeneration = gen

        AppLog.render.line("[WeaponPass] uploaded gen=\(gen) verts=\(flat.count) submeshes=\(subs.count) textures=\(texs.count) bones=\(names.count) handbone=\(handBoneIndex)")
    }

    /// Allocate/resize the weapon depth to match the drawable colour slice.
    func ensureDepth(width: Int, height: Int, slices: Int) {
        if depth != nil && depthW == width && depthH == height && depthSlices == slices { return }
        let td = MTLTextureDescriptor()
        td.textureType = slices > 1 ? .type2DArray : .type2D
        td.pixelFormat = depthFormat
        td.width = width; td.height = height
        td.arrayLength = max(1, slices)
        td.usage = .renderTarget
        td.storageMode = .private
        depth = device.makeTexture(descriptor: td)
        depth?.label = "WeaponDepth"
        depthW = width; depthH = height; depthSlices = slices
    }

    /// Resources that must be resident this frame (MTL4 has no auto tracking).
    func residentResources(uniformBufferIndex: Int) -> [MTLResource] {
        var r: [MTLResource] = []
        if let vertexBuffer { r.append(vertexBuffer) }
        if let depth { r.append(depth) }
        r.append(uniformBuffers[uniformBufferIndex])
        r.append(boneBuffers[uniformBufferIndex])
        r.append(ringUniformBuffers[uniformBufferIndex])
        r.append(contentsOf: textures)
        return r
    }

    /// Encode the weapon pass. Call after the fullscreen engine pass has been
    /// encoded on the same command buffer (it loads drawable.colorTextures[0]).
    func encode(commandBuffer: MTL4CommandBuffer,
                drawable: LayerRenderer.Drawable,
                viewProjectionBuffer: MTLBuffer,
                viewProjectionOffset: Int,
                uniformBufferIndex: Int,
                model: float4x4,
                lightDir: SIMD3<Float>,
                lightColor: SIMD3<Float>,
                ambient: SIMD3<Float>,
                eyePositions: [SIMD3<Float>],
                eyeRights: [SIMD3<Float>],
                drawWeapon: Bool = true,
                arcs: [Arc] = []) {
        guard let depth else { return }

        // One WeaponUniforms per submesh — the chrome/masked flags are
        // per-submesh state, and rebinding the address per draw is cheaper
        // than splitting the pipeline. Slot 0 doubles as the arcs' binding.
        let ub = uniformBuffers[uniformBufferIndex]
        let slotStride = Int(WEAPON_UNIFORM_STRIDE)
        let eye0 = eyePositions.first ?? .zero
        let eye1 = eyePositions.count > 1 ? eyePositions[1] : eye0
        let right0 = eyeRights.first ?? SIMD3<Float>(1, 0, 0)
        let right1 = eyeRights.count > 1 ? eyeRights[1] : right0
        let drawnSubmeshes = drawWeapon ? min(submeshes.count, Int(WEAPON_MAX_SUBMESHES)) : 0
        for k in 0..<max(drawnSubmeshes, 1) {
            let flags = k < drawnSubmeshes ? submeshes[k].flags : 0
            var u = WeaponUniforms(
                modelMatrix: model,
                lightDir: SIMD4(lightDir, 0),
                lightColor: SIMD4(lightColor, 0),
                ambient: SIMD4(ambient, 0),
                eyePos: (SIMD4(eye0, 1), SIMD4(eye1, 1)),
                eyeRight: (SIMD4(right0, 0), SIMD4(right1, 0)),
                renderFlags: SIMD4((flags & WeaponPass.studioMasked) != 0 ? 1 : 0,
                                   (flags & WeaponPass.studioChrome) != 0 ? 1 : 0,
                                   0, 0))
            memcpy(ub.contents() + k * slotStride, &u, MemoryLayout<WeaponUniforms>.size)
        }

        let rpd = MTL4RenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.colorTextures[0]
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 0.0    // reverse-Z far
        rpd.depthAttachment.storeAction = .dontCare
        rpd.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layered { rpd.renderTargetArrayLength = drawable.views.count }

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.label = "Weapon Encoder"
        // Order this pass's colour load after the fullscreen engine pass's
        // colour writes on the same queue (MTL4 = no hazard tracking).
        enc.barrier(afterQueueStages: .all, beforeStages: .fragment, visibilityOptions: .device)

        enc.setViewports(drawable.views.map { $0.textureMap.viewport })
        if drawable.views.count > 1 {
            enc.setVertexAmplificationCount((0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            })
        }

        enc.setArgumentTable(vertexArgTable, stages: .vertex)
        enc.setArgumentTable(fragmentArgTable, stages: .fragment)
        vertexArgTable.setAddress(ub.gpuAddress, index: BufferIndex.uniforms.rawValue)
        vertexArgTable.setAddress(viewProjectionBuffer.gpuAddress + UInt64(viewProjectionOffset),
                                  index: BufferIndex.viewProjection.rawValue)
        fragmentArgTable.setAddress(ub.gpuAddress, index: BufferIndex.uniforms.rawValue)

        if drawWeapon, isReady, let vertexBuffer {
            // Bone palette for this frame's pose (this in-flight slot's copy).
            let bb = boneBuffers[uniformBufferIndex]
            if !palette.isEmpty {
                palette.withUnsafeBytes { _ = memcpy(bb.contents(), $0.baseAddress, $0.count) }
            }
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.none)   // GoldSrc winding varies; cull nothing for now
            vertexArgTable.setAddress(
                vertexBuffer.gpuAddress,
                index: BufferIndex.meshPositions.rawValue
            )
            vertexArgTable.setAddress(bb.gpuAddress, index: BufferIndex.bones.rawValue)
            for (k, sm) in submeshes.prefix(drawnSubmeshes).enumerated() {
                guard !textures.isEmpty else { break }
                let tex = textures[min(sm.texture, textures.count - 1)]
                // This submesh's own uniform slot (chrome/masked flags).
                let slot = ub.gpuAddress + UInt64(k * slotStride)
                vertexArgTable.setAddress(slot, index: BufferIndex.uniforms.rawValue)
                fragmentArgTable.setAddress(slot, index: BufferIndex.uniforms.rawValue)
                fragmentArgTable.setTexture(tex.gpuResourceID, index: TextureIndex.color.rawValue)
                enc.drawPrimitives(primitiveType: .triangle,
                                   vertexStart: sm.vertexStart, vertexCount: sm.vertexCount)
            }
        }

        // UI arcs (reload ring, weapon-menu sectors), drawn last with depth
        // test off so the weapon can't hide them. Each arc is one strip of
        // 2*(RING_SEGMENTS+1) vertices generated in the vertex shader — the
        // count must match RING_SEGMENTS in WeaponShaders.metal. One slot of
        // the per-frame ring buffer per arc.
        if !arcs.isEmpty {
            let rub = ringUniformBuffers[uniformBufferIndex]
            enc.setRenderPipelineState(ringPipeline)
            enc.setDepthStencilState(ringDepthState)
            for (k, arc) in arcs.prefix(WeaponPass.maxArcs).enumerated() {
                let offset = k * WeaponPass.arcSlotStride
                var ru = RingUniforms(center: SIMD4(arc.center, 1),
                                      right: SIMD4(arc.right, arc.outerR),
                                      up: SIMD4(arc.up, arc.innerR),
                                      color: arc.color,
                                      startTurns: arc.startTurns,
                                      sweepTurns: arc.sweepTurns)
                memcpy(rub.contents() + offset, &ru, MemoryLayout<RingUniforms>.size)
                vertexArgTable.setAddress(rub.gpuAddress + UInt64(offset),
                                          index: BufferIndex.uniforms.rawValue)
                enc.drawPrimitives(primitiveType: .triangleStrip,
                                   vertexStart: 0, vertexCount: 2 * (48 + 1))
            }
        }
        enc.endEncoding()
    }

    // GoldSrc bone transforms arrive row-major 3x4 (12 floats). Build a
    // column-major float4x4 (bottom row 0,0,0,1).
    private static func matrix(fromRowMajor3x4 m: UnsafePointer<Float>) -> float4x4 {
        return float4x4(columns: (
            SIMD4(m[0], m[4], m[8],  0),
            SIMD4(m[1], m[5], m[9],  0),
            SIMD4(m[2], m[6], m[10], 0),
            SIMD4(m[3], m[7], m[11], 1)))
    }
}
