//
//  StudioMesh.swift
//  LambdaVision
//
//  One baked GoldSrc studio model on the GPU: the extractor's bone-local
//  vertices deindexed into a flat buffer, its submeshes, its textures and its
//  bone table. WeaponPass draws two of these — the viewmodel and the player
//  body — through the same pipeline, so the upload lives here rather than in
//  the pass.
//
//  Vertices stay in bone-local space (GoldSrc rigid single-bone skinning) and
//  are posed on the GPU from a bone palette. Which palette is the caller's
//  business: the weapon's comes from the engine's sequence maths, the body's
//  from AvatarRig's IK.
//

import Metal
import simd

final class StudioMesh {
    /// A run of triangles sharing one texture. `flags` are the studio
    /// STUDIO_NF_* bits of that texture, which the shader reads per draw.
    struct Submesh {
        var vertexStart: Int
        var vertexCount: Int
        var texture: Int
        var flags: UInt32
    }
    static let studioChrome: UInt32 = 0x0002
    static let studioMasked: UInt32 = 0x0040

    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let submeshes: [Submesh]
    let textures: [MTLTexture]
    let boneNames: [String]
    let boneParents: [Int?]
    /// The extractor's choice of grip bone, or -1.
    let handBoneIndex: Int
    let bbmin: SIMD3<Float>
    let bbmax: SIMD3<Float>
    /// Which bake this came from; the caller re-uploads when it moves.
    let generation: UInt32

    var hasHandBone: Bool { handBoneIndex >= 0 }

    /// Deindexes and uploads a locked extractor snapshot. Returns nil for a
    /// snapshot with no geometry.
    ///
    /// `hiddenBones`: any triangle with a vertex on one of these bones is
    /// left out. That is how the avatar loses its head (the camera is inside
    /// it) and, until they can be tracked, its legs. Cutting whole triangles
    /// rather than collapsing bones in the shader avoids slivers stretching
    /// from the cut to wherever the hidden bone was put; the price is an
    /// open edge at the neck and the hips, which is how every first-person
    /// body ends anyway.
    init?(device: MTLDevice, mesh: lambda_weapon_mesh_t, generation: UInt32,
          label: String, hiddenBones: Set<Int> = []) {
        guard mesh.vertex_count > 0, mesh.index_count > 0,
              let verts = mesh.vertices, let idx = mesh.indices,
              let subsPtr = mesh.submeshes else { return nil }

        var flat = [lambda_weapon_vertex_t]()
        flat.reserveCapacity(Int(mesh.index_count))
        var subs: [Submesh] = []
        for s in 0..<Int(mesh.submesh_count) {
            let sm = subsPtr[s]
            let start = flat.count
            let base = Int(sm.index_offset)
            var i = 0
            while i + 2 < Int(sm.index_count) {
                let a = verts[Int(idx[base + i])]
                let b = verts[Int(idx[base + i + 1])]
                let c = verts[Int(idx[base + i + 2])]
                i += 3
                if !hiddenBones.isEmpty,
                   hiddenBones.contains(Int(a.bone)) || hiddenBones.contains(Int(b.bone))
                    || hiddenBones.contains(Int(c.bone)) { continue }
                flat.append(a); flat.append(b); flat.append(c)
            }
            if flat.count > start {
                subs.append(Submesh(vertexStart: start, vertexCount: flat.count - start,
                                    texture: Int(sm.texture), flags: sm.flags))
            }
        }
        guard !flat.isEmpty,
              let vbuf = device.makeBuffer(bytes: flat,
                                           length: flat.count * MemoryLayout<lambda_weapon_vertex_t>.stride,
                                           options: .storageModeShared) else { return nil }
        vbuf.label = "\(label)Vertices"

        var names: [String] = []
        var parents: [Int?] = []
        if let bones = mesh.bones {
            for b in 0..<Int(mesh.bone_count) {
                var entry = bones[b]
                let name = withUnsafePointer(to: &entry.name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
                names.append(name)
                parents.append(entry.parent >= 0 ? Int(entry.parent) : nil)
            }
        }

        // Textures: expand each RGBA8 blob into its own texture.
        var texs: [MTLTexture] = []
        if let texPtr = mesh.textures {
            for t in 0..<Int(mesh.texture_count) {
                let tx = texPtr[t]
                let td = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm,
                    width: Int(tx.width), height: Int(tx.height), mipmapped: false)
                td.usage = .shaderRead
                guard let tex = device.makeTexture(descriptor: td), let rgba = tx.rgba else { continue }
                tex.label = "\(label)Texture\(t)"
                tex.replace(region: MTLRegionMake2D(0, 0, Int(tx.width), Int(tx.height)),
                            mipmapLevel: 0, withBytes: rgba,
                            bytesPerRow: Int(tx.width) * 4)
                texs.append(tex)
            }
        }

        self.vertexBuffer = vbuf
        self.vertexCount = flat.count
        self.submeshes = subs
        self.textures = texs
        self.boneNames = names
        self.boneParents = parents
        self.handBoneIndex = Int(mesh.hand_bone_index)
        self.bbmin = SIMD3(mesh.bbmin.0, mesh.bbmin.1, mesh.bbmin.2)
        self.bbmax = SIMD3(mesh.bbmax.0, mesh.bbmax.1, mesh.bbmax.2)
        self.generation = generation
    }

    /// Everything the pass must make resident to draw this mesh.
    var resources: [MTLResource] { [vertexBuffer] + textures }

    /// GoldSrc bone transforms arrive row-major 3x4 (12 floats per bone).
    /// Build column-major float4x4s (bottom row 0,0,0,1).
    static func palette(from pose: inout lambda_weapon_pose_t) -> [float4x4] {
        let count = min(Int(pose.bone_count), Int(WEAPON_MAX_BONES))
        var pal = [float4x4](repeating: matrix_identity_float4x4, count: count)
        withUnsafePointer(to: &pose.bones) { raw in
            raw.withMemoryRebound(to: Float.self, capacity: Int(WEAPON_MAX_BONES) * 12) { f in
                for i in 0..<count { pal[i] = matrix(fromRowMajor3x4: f + i * 12) }
            }
        }
        return pal
    }

    static func matrix(fromRowMajor3x4 m: UnsafePointer<Float>) -> float4x4 {
        float4x4(columns: (
            SIMD4(m[0], m[4], m[8],  0),
            SIMD4(m[1], m[5], m[9],  0),
            SIMD4(m[2], m[6], m[10], 0),
            SIMD4(m[3], m[7], m[11], 1)))
    }
}
