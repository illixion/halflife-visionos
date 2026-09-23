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
//  The player body (see AvatarRig) is drawn by the same pass, through the
//  same pipeline and into the same depth buffer, so the gun and the hand that
//  holds it occlude each other properly. The pass knows nothing about how the
//  body is posed: it takes an uploaded StudioMesh, a palette and a model
//  matrix, exactly as for the weapon.
//
//  Coordinates: the baked meshes are in GoldSrc model space (units, Z-up). The
//  caller supplies each model→world (metres, Apple/RealityKit basis)
//  transform, so placement (hand anchor, grip, avatar root) lives in Renderer,
//  not here; `handBone` exposes the POSED grip-bone frame the caller pins to
//  the tracked hand.
//

import Metal
import CompositorServices
import QuartzCore
import os
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

    /// A second skinned model drawn alongside the weapon: the player body.
    /// `palette` is bone→model in GoldSrc units, `model` is model→world in
    /// Apple metres, the same contract as the weapon's. `leftHand` /
    /// `rightHand` are the posed hand bones in the world (model→world ·
    /// palette), the frames a held gun is pinned to.
    struct BodyDraw {
        var mesh: StudioMesh
        var palette: [float4x4]
        var model: float4x4
        var leftHand: float4x4?
        var rightHand: float4x4?
    }

    /// How close to an eye the body may be drawn, metres. Anything nearer is
    /// discarded rather than shown sliced open by the near plane — the last
    /// line of defence behind back-face culling and the rig's own clearance.
    static let bodyNearClip: Float = 0.09

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

    // The uploaded viewmodel, replaced whenever the extractor bakes a new one.
    // `gunMesh` is the same bake with Valve's hands cut out (ViewmodelGrip),
    // drawn instead whenever the first-person body supplies the hands.
    private var mesh: StudioMesh?
    private var gunMesh: StudioMesh?

    // The hull filling the viewmodel's unmodelled side from the weapon's p_
    // model (ViewmodelShell), drawn with the viewmodel's palette. Built off
    // the render thread — a fit takes about a second — and cached per model
    // pair, so switching back to a weapon is instant.
    private(set) var shell: StudioMesh?
    private var shellKey: String?
    private var shellCache: [String: StudioMesh?] = [:]
    private let shellResult = OSAllocatedUnfairLock<(key: String, mesh: StudioMesh?)?>(initialState: nil)
    private static let shellQueue = DispatchQueue(label: "WeaponShell", qos: .utility)
    private var uploadedGeneration: UInt32 = 0

    /// Draw the gun without the viewmodel's own hands and sleeves. Set by the
    /// caller each frame: on while the avatar's hands are the ones holding it.
    var hideHands = false
    private var drawnMesh: StudioMesh? { hideHands ? (gunMesh ?? mesh) : mesh }

    /// Where the gun is held, read off the idle pose at upload; nil for a
    /// viewmodel with no hand to hold it by (the hivehand).
    private(set) var grip: ViewmodelGrip.Grip?
    /// The bake's idle pose (sequence 0, frame 0): the reference for the
    /// barrel's direction in the hand.
    private(set) var idlePalette: [float4x4] = []
    /// Gun or held object (see ViewmodelGrip.Hold); meaningless without a grip.
    private(set) var hold: ViewmodelGrip.Hold = .held
    /// The muzzle in idle model space (GoldSrc units), nil when the model
    /// has neither an attachment nor gun geometry to find one from.
    private(set) var muzzle: SIMD3<Float>?

    // Bone table of the uploaded model and the index of its grip hand bone
    // ("Bip01 R Hand"; -1 when the model has none — then handBone stays
    // identity and the model origin lands on the hand).
    var boneNames: [String] { mesh?.boneNames ?? [] }
    var hasHandBone: Bool { mesh?.hasHandBone ?? false }

    // Current pose: bone→model-space transforms from the extractor (GoldSrc
    // units), refreshed each frame by update(). `handBone` is the POSED grip
    // bone's frame, so pinning it to the tracked hand keeps the gun and the
    // off-hand animating exactly as authored around a fixed grip.
    private(set) var palette: [float4x4] = []
    private var pose = lambda_weapon_pose_t()
    private(set) var handBone = matrix_identity_float4x4
    private(set) var poseSequence: Int = 0
    private(set) var poseFrame: Float = 0
    var bbmin: SIMD3<Float> { mesh?.bbmin ?? .zero }
    var bbmax: SIMD3<Float> { mesh?.bbmax ?? .zero }

    // Per-eye depth, sized to the drawable. Recreated on size change.
    private var depth: MTLTexture?
    private var depthW = 0, depthH = 0, depthSlices = 0

    // Per in-flight frame: one WeaponUniforms array + one bone palette for
    // each skinned model, and the ring slots.
    private struct SkinnedBuffers {
        var uniforms: [MTLBuffer]
        var bones: [MTLBuffer]
    }
    private let weaponBuffers: SkinnedBuffers
    private let bodyBuffers: SkinnedBuffers
    private let shellBuffers: SkinnedBuffers
    private var ringUniformBuffers: [MTLBuffer] = []

    var isReady: Bool { mesh != nil }

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

        self.weaponBuffers = WeaponPass.makeSkinnedBuffers(device: device, count: maxBuffersInFlight,
                                                           label: "Weapon")
        self.bodyBuffers = WeaponPass.makeSkinnedBuffers(device: device, count: maxBuffersInFlight,
                                                         label: "Body")
        self.shellBuffers = WeaponPass.makeSkinnedBuffers(device: device, count: maxBuffersInFlight,
                                                          label: "Shell")
        self.ringUniformBuffers = (0..<maxBuffersInFlight).map { _ in
            device.makeBuffer(length: WeaponPass.arcSlotStride * WeaponPass.maxArcs,
                              options: .storageModeShared)!
        }
    }

    private static func makeSkinnedBuffers(device: MTLDevice, count: Int, label: String) -> SkinnedBuffers {
        let uniforms = (0..<count).map { i in
            let b = device.makeBuffer(length: Int(WEAPON_UNIFORM_STRIDE) * Int(WEAPON_MAX_SUBMESHES),
                                      options: .storageModeShared)!
            b.label = "\(label)Uniforms\(i)"
            return b
        }
        let bones = (0..<count).map { i in
            let b = device.makeBuffer(length: MemoryLayout<WeaponBonePalette>.stride,
                                      options: .storageModeShared)!
            b.label = "\(label)Bones\(i)"
            // Identity palette until the first pose lands.
            let ident = [float4x4](repeating: matrix_identity_float4x4, count: Int(WEAPON_MAX_BONES))
            ident.withUnsafeBytes { _ = memcpy(b.contents(), $0.baseAddress, $0.count) }
            return b
        }
        return SkinnedBuffers(uniforms: uniforms, bones: bones)
    }

    /// Per-frame: poll the extractor — upload a freshly baked model if the
    /// generation moved, then refresh the bone palette from the latest pose.
    func update() {
        uploadIfNeeded()
        refreshPose()
        updateShell()
    }

    // MARK: - Hull

    /// Everything a hull build needs, copied out of both snapshots so the
    /// build runs with no lock held.
    private struct ShellJob: @unchecked Sendable {
        var hull: ViewmodelShell.Hull
        var gun: [SIMD3<Float>]
        var gunBones: [Int]
        var occluders: [SIMD3<Float>]
        var idle: [float4x4]
        var textures: [StudioMesh.TextureCopy]
    }

    /// Start a hull build when the viewmodel or the p_ model changes, and
    /// pick up a finished one.
    private func updateShell() {
        let world = lambda_weapon_world_generation()
        guard uploadedGeneration != 0, world != 0, let mesh, !idlePalette.isEmpty else {
            shell = nil
            shellKey = nil
            return
        }
        if let done = shellResult.withLock({ r -> (key: String, mesh: StudioMesh?)? in
            defer { r = nil }
            return r
        }) {
            shellCache[done.key] = done.mesh
            if done.key == shellKey { shell = done.mesh }
        }
        var w = lambda_weapon_mesh_t()
        _ = lambda_weapon_world_lock(&w)
        let key = "\(mesh.generation == uploadedGeneration ? mesh.vertexCount : 0)|\(mesh.boneNames.count)|\(w.vertex_count)|\(w.index_count)|\(w.bone_count)"
        lambda_weapon_world_unlock()
        guard key != shellKey else { return }
        shellKey = key
        if let cached = shellCache[key] {
            shell = cached
            return
        }
        shell = nil
        guard let job = shellJob() else { shellCache[key] = .some(nil); return }
        let device = self.device, result = self.shellResult
        let generation = uploadedGeneration
        Self.shellQueue.async {
            let t0 = CACurrentMediaTime()
            let built = ViewmodelShell.build(hull: job.hull, gun: job.gun, gunBones: job.gunBones,
                                             occluders: job.occluders, idlePalette: job.idle)
            let hull = built.flatMap { WeaponPass.shellMesh($0, textures: job.textures, device: device,
                                                            generation: generation) }
            result.withLock { $0 = (key, hull) }
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            let line = built.map {
                String(format: "kept %d/%d tris, scale %.2f, residual %.2f, covers %.0f%%", $0.kept, $0.total,
                       $0.fit.scale, $0.fit.residual, $0.fit.coverage * 100)
            } ?? "none (complete, or not the same shape)"
            Task { @MainActor in AppLog.render.line("[WeaponPass] hull \(line) in \(ms) ms") }
        }
    }

    /// Copies the viewmodel's gun (idle pose, hands cut) and the p_ model's
    /// gun — the triangles under its right hand; the arm and torso bones
    /// carry nothing else but, on the egon, the backpack.
    private func shellJob() -> ShellJob? {
        var raw = lambda_weapon_mesh_t()
        guard lambda_weapon_lock(&raw) == uploadedGeneration, let mesh else { lambda_weapon_unlock(); return nil }
        let isHand = ViewmodelGrip.handTriangleFilter(textureNames: mesh.textureNames, boneNames: mesh.boneNames)
        var gun: [SIMD3<Float>] = [], gunBones: [Int] = [], occluders: [SIMD3<Float>] = []
        WeaponPass.forEachTriangle(raw) { texture, v in
            let ps = v.map { WeaponPass.posed($0, idlePalette) }
            occluders += ps
            if !isHand(texture, Int(v[0].bone), Int(v[1].bone), Int(v[2].bone)) {
                gun += ps
                gunBones += v.map { Int($0.bone) }
            }
        }
        lambda_weapon_unlock()

        var w = lambda_weapon_mesh_t()
        guard lambda_weapon_world_lock(&w) != 0 else { lambda_weapon_world_unlock(); return nil }
        defer { lambda_weapon_world_unlock() }
        var pose = lambda_weapon_pose_t()
        guard lambda_weapon_world_copy_pose(&pose) == w.generation else { return nil }
        let palette = StudioMesh.palette(from: &pose)
        let names = StudioMesh.boneNames(of: w)
        var parents: [Int?] = []
        if let bones = w.bones { for b in 0..<Int(w.bone_count) { parents.append(bones[b].parent >= 0 ? Int(bones[b].parent) : nil) } }
        let underHand = Set(names.indices.filter { i in
            var b: Int? = i
            while let c = b { if names[c].hasSuffix(" R Hand") { return true }; b = parents[c] }
            return false
        })
        var hull = ViewmodelShell.Hull(corners: [], normals: [], uvs: [], textures: [])
        WeaponPass.forEachTriangle(w) { texture, v in
            guard v.allSatisfy({ underHand.contains(Int($0.bone)) }) else { return }
            hull.textures.append(texture)
            for x in v {
                hull.corners.append(WeaponPass.posed(x, palette))
                let n = palette[min(Int(x.bone), palette.count - 1)] * SIMD4(x.normal.0, x.normal.1, x.normal.2, 0)
                hull.normals.append(SIMD3(n.x, n.y, n.z))
                hull.uvs.append(SIMD2(x.uv.0, x.uv.1))
            }
        }
        guard !gun.isEmpty, !hull.corners.isEmpty else { return nil }
        return ShellJob(hull: hull, gun: gun, gunBones: gunBones, occluders: occluders,
                        idle: idlePalette, textures: StudioMesh.textureCopies(of: w))
    }

    /// The built hull as a drawable mesh: one submesh per p_ texture.
    nonisolated private static func shellMesh(_ b: ViewmodelShell.Built, textures: [StudioMesh.TextureCopy],
                                  device: MTLDevice, generation: UInt32) -> StudioMesh? {
        var flat: [lambda_weapon_vertex_t] = []
        var subs: [StudioMesh.Submesh] = []
        for texture in Set(b.textures).sorted() where texture < textures.count {
            let start = flat.count
            for t in b.textures.indices where b.textures[t] == texture {
                for c in 0..<3 {
                    let i = t * 3 + c
                    let p = b.positions[i], n = b.normals[i], uv = b.uvs[i]
                    flat.append(lambda_weapon_vertex_t(pos: (p.x, p.y, p.z), normal: (n.x, n.y, n.z),
                                                       uv: (uv.x, uv.y), bone: UInt32(b.bones[i])))
                }
            }
            subs.append(StudioMesh.Submesh(vertexStart: start, vertexCount: flat.count - start,
                                           texture: texture, flags: textures[texture].flags))
        }
        return StudioMesh(device: device, vertices: flat, submeshes: subs, textures: textures,
                          generation: generation, label: "WeaponShell")
    }

    nonisolated private static func forEachTriangle(_ m: lambda_weapon_mesh_t,
                                        _ body: (_ texture: Int, _ v: [lambda_weapon_vertex_t]) -> Void) {
        guard let verts = m.vertices, let idx = m.indices, let subs = m.submeshes else { return }
        for s in 0..<Int(m.submesh_count) {
            let sm = subs[s]
            var i = 0
            while i + 2 < Int(sm.index_count) {
                body(Int(sm.texture), (0..<3).map { verts[Int(idx[Int(sm.index_offset) + i + $0])] })
                i += 3
            }
        }
    }

    nonisolated private static func posed(_ v: lambda_weapon_vertex_t, _ palette: [float4x4]) -> SIMD3<Float> {
        let p = palette[min(Int(v.bone), palette.count - 1)] * SIMD4(v.pos.0, v.pos.1, v.pos.2, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// Copy the extractor's latest pose into `palette` / `handBone`. A pose
    /// for a generation other than the uploaded mesh is ignored (the mesh
    /// upload lags the bake by at most a frame, and the bake seeds a matching
    /// pose, so this only skips the hand-over frame).
    private func refreshPose() {
        guard let mesh, uploadedGeneration != 0 else { return }
        let gen = lambda_weapon_copy_pose(&pose)
        guard gen == uploadedGeneration else { return }
        palette = StudioMesh.palette(from: &pose)
        poseSequence = Int(pose.sequence)
        poseFrame = pose.frame
        let h = mesh.handBoneIndex
        handBone = (h >= 0 && h < palette.count) ? palette[h] : matrix_identity_float4x4
    }

    /// If a new model was baked, deindex + upload it.
    private func uploadIfNeeded() {
        let gen = lambda_weapon_generation()
        if gen == 0 || gen == uploadedGeneration { return }

        var raw = lambda_weapon_mesh_t()
        let locked = lambda_weapon_lock(&raw)
        defer { lambda_weapon_unlock() }
        guard locked != 0,
              let uploaded = StudioMesh(device: device, mesh: raw, generation: gen, label: "Weapon")
        else { return }
        let isHand = ViewmodelGrip.handTriangleFilter(textureNames: uploaded.textureNames,
                                                      boneNames: uploaded.boneNames)
        let gunOnly = StudioMesh(device: device, mesh: raw, generation: gen, label: "WeaponGun",
                                 omit: isHand)

        var rest = lambda_weapon_pose_t()
        let idle = lambda_weapon_copy_rest_pose(&rest) == gen ? StudioMesh.palette(from: &rest) : []

        self.mesh = uploaded
        self.gunMesh = gunOnly
        self.idlePalette = idle
        let geometry = ViewmodelGrip.boneGeometry(boneCount: uploaded.boneNames.count,
                                                  textureNames: uploaded.textureNames,
                                                  vertices: StudioMesh.vertexTextureBones(of: raw))
        self.grip = ViewmodelGrip.grip(boneNames: uploaded.boneNames, parents: uploaded.boneParents,
                                       pose: idle, extractorChoice: uploaded.handBoneIndex,
                                       geometry: geometry)
        self.hold = grip.map { ViewmodelGrip.hold(grip: $0, idlePalette: idle) } ?? .held
        self.muzzle = ViewmodelGrip.muzzle(
            attachment: StudioMesh.attachments(of: raw).first, idlePalette: idle,
            gunPoints: StudioMesh.posedPoints(of: raw, palette: idle) { !isHand($0, $1, $2, $3) })
        self.palette = []          // refreshPose() fills it for this generation
        self.handBone = matrix_identity_float4x4
        self.uploadedGeneration = gen

        AppLog.render.line("[WeaponPass] uploaded gen=\(gen) verts=\(uploaded.vertexCount) gun-only=\(gunOnly?.vertexCount ?? 0) submeshes=\(uploaded.submeshes.count) textures=\(uploaded.textures.count) bones=\(uploaded.boneNames.count) handbone=\(uploaded.handBoneIndex) grip=\(grip.map { "\(uploaded.boneNames[$0.bone])\($0.fingerPrefix == nil ? " (synthesised)" : "")" } ?? "none") hold=\(hold) muzzle=\(muzzle.map { "\($0)" } ?? "none")")
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
    func residentResources(uniformBufferIndex: Int, body: StudioMesh? = nil) -> [MTLResource] {
        var r: [MTLResource] = []
        if let mesh = drawnMesh { r.append(contentsOf: mesh.resources) }
        if let shell { r.append(contentsOf: shell.resources) }
        r.append(shellBuffers.uniforms[uniformBufferIndex])
        r.append(shellBuffers.bones[uniformBufferIndex])
        if let body { r.append(contentsOf: body.resources) }
        if let depth { r.append(depth) }
        r.append(weaponBuffers.uniforms[uniformBufferIndex])
        r.append(weaponBuffers.bones[uniformBufferIndex])
        r.append(bodyBuffers.uniforms[uniformBufferIndex])
        r.append(bodyBuffers.bones[uniformBufferIndex])
        r.append(ringUniformBuffers[uniformBufferIndex])
        return r
    }

    /// The lighting and camera terms shared by every skinned draw this frame.
    private struct Shading {
        var lightDir: SIMD3<Float>
        var lightColor: SIMD3<Float>
        var ambient: SIMD3<Float>
        var eye0: SIMD3<Float>, eye1: SIMD3<Float>
        var right0: SIMD3<Float>, right1: SIMD3<Float>
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
                body: BodyDraw? = nil,
                arcs: [Arc] = [],
                hud: ((MTL4RenderCommandEncoder) -> Void)? = nil) {
        guard let depth else { return }

        let eye0 = eyePositions.first ?? .zero
        let shading = Shading(
            lightDir: lightDir, lightColor: lightColor, ambient: ambient,
            eye0: eye0,
            eye1: eyePositions.count > 1 ? eyePositions[1] : eye0,
            right0: eyeRights.first ?? SIMD3<Float>(1, 0, 0),
            right1: eyeRights.count > 1 ? eyeRights[1] : (eyeRights.first ?? SIMD3<Float>(1, 0, 0)))

        // Slot 0 of the weapon uniforms doubles as the arcs' binding, so it is
        // written even on a frame with no weapon.
        let ub = weaponBuffers.uniforms[uniformBufferIndex]
        let mesh = drawnMesh
        if drawWeapon, let mesh {
            writeUniforms(mesh: mesh, model: model, shading: shading, into: ub,
                          interior: WeaponPass.interiorSign(model))
        } else {
            writeUniforms(mesh: nil, model: model, shading: shading, into: ub)
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

        let drawingSkinned = (drawWeapon && mesh != nil) || body != nil
        if drawingSkinned {
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
        }

        // Body first, weapon second: both write depth, so order only matters
        // for the ordering of overdraw, and the body is the larger of the two.
        //
        // The body is back-face culled. Its camera sits in the neck, so the
        // open collar and anything the near plane slices are seen from the
        // inside, and those faces all face away — culled, they vanish instead
        // of reading as the inside of a torso. GoldSrc winds outward faces
        // clockwise (measured: 355 of 356 single-bone triangles of
        // gordon.mdl, and every stock viewmodel alike — the reason the engine
        // culls GL_FRONT), and Metal judges winding in NDC as GL does.
        if let body {
            enc.setCullMode(.back)
            enc.setFrontFacing(.clockwise)
            let bu = bodyBuffers.uniforms[uniformBufferIndex]
            writeUniforms(mesh: body.mesh, model: body.model, shading: shading, into: bu,
                          nearClip: WeaponPass.bodyNearClip)
            drawSkinned(enc, mesh: body.mesh, palette: body.palette,
                        uniforms: bu, bones: bodyBuffers.bones[uniformBufferIndex])
        }
        // The gun is not culled: GoldSrc itself never enabled face culling
        // for studio models (a long-standing engine quirk xash reproduces),
        // so thin single-sided parts — the crossbow string — rely on being
        // drawn from both sides. It also means a mirrored grip needs no
        // winding flip.
        //
        // Its back faces, though, are shaded as the gun's dark interior: a
        // one-sided model seen from behind, or through a cut the hull leaves
        // where the magazine parts from the receiver, then reads as solid
        // metal in shadow rather than the inside of a paper shell. Clockwise
        // is front, as for the body; a mirrored grip flips it, which the
        // interior flag's sign carries.
        enc.setCullMode(.none)
        enc.setFrontFacing(.clockwise)
        if drawWeapon, let mesh {
            drawSkinned(enc, mesh: mesh, palette: palette,
                        uniforms: ub, bones: weaponBuffers.bones[uniformBufferIndex])
            if let shell {
                let su = shellBuffers.uniforms[uniformBufferIndex]
                writeUniforms(mesh: shell, model: model, shading: shading, into: su,
                              interior: WeaponPass.interiorSign(model))
                drawSkinned(enc, mesh: shell, palette: palette,
                            uniforms: su, bones: shellBuffers.bones[uniformBufferIndex])
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
        // HEV holograms last: over the gun and the body (see HEVHUD), and
        // last because they bind their own argument table (the arcs above
        // reuse this pass's).
        hud?(enc)
        enc.endEncoding()
    }

    /// One WeaponUniforms per submesh — the chrome/masked flags are
    /// per-submesh state, and rebinding the address per draw is cheaper than
    /// splitting the pipeline. With no mesh, slot 0 alone is written.
    /// Which winding is the outside of a gun face under `model`: +1 as
    /// authored (clockwise), -1 when the grip mirrors the gun.
    private static func interiorSign(_ model: float4x4) -> Float {
        let m = simd_float3x3(columns: (SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
                                        SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
                                        SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)))
        return m.determinant < 0 ? -1 : 1
    }

    private func writeUniforms(mesh: StudioMesh?, model: float4x4, shading s: Shading,
                               into buffer: MTLBuffer, nearClip: Float = 0, interior: Float = 0) {
        let slotStride = Int(WEAPON_UNIFORM_STRIDE)
        let count = min(mesh?.submeshes.count ?? 0, Int(WEAPON_MAX_SUBMESHES))
        for k in 0..<max(count, 1) {
            let flags = k < count ? mesh!.submeshes[k].flags : 0
            var u = WeaponUniforms(
                modelMatrix: model,
                lightDir: SIMD4(s.lightDir, 0),
                lightColor: SIMD4(s.lightColor, 0),
                ambient: SIMD4(s.ambient, 0),
                eyePos: (SIMD4(s.eye0, 1), SIMD4(s.eye1, 1)),
                eyeRight: (SIMD4(s.right0, 0), SIMD4(s.right1, 0)),
                renderFlags: SIMD4((flags & StudioMesh.studioMasked) != 0 ? 1 : 0,
                                   (flags & StudioMesh.studioChrome) != 0 ? 1 : 0,
                                   nearClip, interior))
            memcpy(buffer.contents() + k * slotStride, &u, MemoryLayout<WeaponUniforms>.size)
        }
    }

    /// Draw one skinned model: upload its palette into this frame's bone
    /// buffer, then one draw per submesh against that submesh's uniform slot
    /// and texture. Pipeline, depth state and cull mode are already set.
    private func drawSkinned(_ enc: MTL4RenderCommandEncoder, mesh: StudioMesh,
                             palette: [float4x4], uniforms: MTLBuffer, bones: MTLBuffer) {
        guard !mesh.textures.isEmpty else { return }
        if !palette.isEmpty {
            let count = min(palette.count, Int(WEAPON_MAX_BONES))
            palette.withUnsafeBytes {
                _ = memcpy(bones.contents(), $0.baseAddress, count * MemoryLayout<float4x4>.stride)
            }
        }
        let slotStride = Int(WEAPON_UNIFORM_STRIDE)
        vertexArgTable.setAddress(mesh.vertexBuffer.gpuAddress, index: BufferIndex.meshPositions.rawValue)
        vertexArgTable.setAddress(bones.gpuAddress, index: BufferIndex.bones.rawValue)
        for (k, sm) in mesh.submeshes.prefix(Int(WEAPON_MAX_SUBMESHES)).enumerated() {
            let tex = mesh.textures[min(sm.texture, mesh.textures.count - 1)]
            let slot = uniforms.gpuAddress + UInt64(k * slotStride)
            vertexArgTable.setAddress(slot, index: BufferIndex.uniforms.rawValue)
            fragmentArgTable.setAddress(slot, index: BufferIndex.uniforms.rawValue)
            fragmentArgTable.setTexture(tex.gpuResourceID, index: TextureIndex.color.rawValue)
            enc.drawPrimitives(primitiveType: .triangle,
                               vertexStart: sm.vertexStart, vertexCount: sm.vertexCount)
        }
    }
}
