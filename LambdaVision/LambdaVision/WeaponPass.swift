//
//  WeaponPass.swift
//  LambdaVision
//
//  Draws the bind-pose weapon mesh baked by Lambda_WeaponModel.c as a second
//  Metal pass over the engine image. Renders into the drawable's colour slice
//  (loadAction .load) with its OWN depth buffer, so the weapon self-occludes
//  correctly and composites on top without disturbing drawable.depthTextures,
//  which the compositor uses for reprojection.
//
//  Coordinates: the baked mesh is in GoldSrc model space (units, Z-up). The
//  caller supplies the model→world (metres, Apple/RealityKit basis) transform,
//  so placement (hand anchor, grip) lives in Renderer, not here.
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
    private struct Submesh { var vertexStart: Int; var vertexCount: Int; var texture: Int }
    private var vertexBuffer: MTLBuffer?
    private var submeshes: [Submesh] = []
    private var textures: [MTLTexture] = []
    private var uploadedGeneration: UInt32 = 0

    // Model-space bind transform of the "Bip01 R Hand" bone, for grip
    // alignment by the caller (identity if the model has none).
    private(set) var handBone = matrix_identity_float4x4
    private(set) var hasHandBone = false
    private(set) var bbmin = SIMD3<Float>(repeating: 0)
    private(set) var bbmax = SIMD3<Float>(repeating: 0)

    // Per-eye depth, sized to the drawable. Recreated on size change.
    private var depth: MTLTexture?
    private var depthW = 0, depthH = 0, depthSlices = 0

    // Uniform ring (one WeaponUniforms per in-flight frame).
    private var uniformBuffers: [MTLBuffer]
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
        vd.layouts[BufferIndex.meshPositions.rawValue].stride = 32   // matches lambda_weapon_vertex_t

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
        vDesc.maxBufferBindCount = 4            // vertex@0, uniforms@2, viewProj@3
        self.vertexArgTable = try! device.makeArgumentTable(descriptor: vDesc)
        let fDesc = MTL4ArgumentTableDescriptor()
        fDesc.maxBufferBindCount = 3            // uniforms@2
        fDesc.maxTextureBindCount = 1           // colour@0
        self.fragmentArgTable = try! device.makeArgumentTable(descriptor: fDesc)

        self.uniformBuffers = (0..<maxBuffersInFlight).map { _ in
            device.makeBuffer(length: MemoryLayout<WeaponUniforms>.stride,
                              options: .storageModeShared)!
        }
        self.ringUniformBuffers = (0..<maxBuffersInFlight).map { _ in
            device.makeBuffer(length: WeaponPass.arcSlotStride * WeaponPass.maxArcs,
                              options: .storageModeShared)!
        }
    }

    /// Poll the extractor and, if a new model was baked, deindex + upload it.
    func uploadIfNeeded() {
        let gen = lambda_weapon_generation()
        if gen == 0 || gen == uploadedGeneration { return }

        var mesh = lambda_weapon_mesh_t()
        let locked = lambda_weapon_lock(&mesh)
        defer { lambda_weapon_unlock() }
        if locked == 0 || mesh.vertex_count == 0 || mesh.index_count == 0 { return }

        // Each lambda_weapon_vertex_t is 8 contiguous floats (pos3,norm3,uv2).
        let vfloats = mesh.vertices!.withMemoryRebound(to: Float.self,
                                                       capacity: Int(mesh.vertex_count) * 8) { $0 }
        let idx = mesh.indices!

        var flat = [Float]()
        flat.reserveCapacity(Int(mesh.index_count) * 8)
        var subs: [Submesh] = []
        let subsPtr = mesh.submeshes!
        for s in 0..<Int(mesh.submesh_count) {
            let sm = subsPtr[s]
            let start = flat.count / 8
            let base = Int(sm.index_offset)
            for i in 0..<Int(sm.index_count) {
                let vi = Int(idx[base + i]) * 8
                for k in 0..<8 { flat.append(vfloats[vi + k]) }
            }
            subs.append(Submesh(vertexStart: start,
                                vertexCount: Int(sm.index_count),
                                texture: Int(sm.texture)))
        }

        let vbuf = device.makeBuffer(bytes: flat, length: flat.count * 4,
                                     options: .storageModeShared)
        vbuf?.label = "WeaponVertices"

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
        self.hasHandBone = (mesh.has_hand_bone != 0)
        self.handBone = WeaponPass.matrix(fromRowMajor3x4: mesh.hand_bone)
        self.bbmin = SIMD3(mesh.bbmin.0, mesh.bbmin.1, mesh.bbmin.2)
        self.bbmax = SIMD3(mesh.bbmax.0, mesh.bbmax.1, mesh.bbmax.2)
        self.uploadedGeneration = gen

        AppLog.render.line("[WeaponPass] uploaded gen=\(gen) verts=\(flat.count/8) submeshes=\(subs.count) textures=\(texs.count) handbone=\(hasHandBone)")
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
                drawWeapon: Bool = true,
                arcs: [Arc] = []) {
        guard let depth else { return }

        let ub = uniformBuffers[uniformBufferIndex]
        var u = WeaponUniforms(modelMatrix: model,
                               lightDir: SIMD4(lightDir, 0),
                               lightColor: SIMD4(lightColor, 0),
                               ambient: SIMD4(ambient, 0))
        memcpy(ub.contents(), &u, MemoryLayout<WeaponUniforms>.size)

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
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.none)   // GoldSrc winding varies; cull nothing for now
            vertexArgTable.setAddress(
                vertexBuffer.gpuAddress,
                index: BufferIndex.meshPositions.rawValue
            )
            for sm in submeshes {
                guard !textures.isEmpty else { break }
                let tex = textures[min(sm.texture, textures.count - 1)]
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

    // GoldSrc bind transform arrives row-major 3x4 (12 floats). Build a
    // column-major float4x4 (bottom row 0,0,0,1).
    private static func matrix(fromRowMajor3x4 m: (Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,Float)) -> float4x4 {
        return float4x4(columns: (
            SIMD4(m.0, m.4, m.8,  0),
            SIMD4(m.1, m.5, m.9,  0),
            SIMD4(m.2, m.6, m.10, 0),
            SIMD4(m.3, m.7, m.11, 1)))
    }
}
