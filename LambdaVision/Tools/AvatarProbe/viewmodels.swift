// Viewmodel checks: what ViewmodelGrip cuts, where it grips, which way the
// barrel points, and — for eyes — Gordon's posed hand holding each gun.
//
// Runs after the body checks, because the only file loader the extractor has
// is the body slot: each v_ model is loaded into it in turn, so everything
// needed from gordon.mdl is copied out first.

import Foundation
import RAVERig
import simd

/// A baked model copied out of the body slot, so the slot can be reused.
struct ProbeModel {
    var boneNames: [String]
    var parents: [Int?]
    var textureNames: [String]
    var restPose: [float4x4]
    var handBone: Int
    /// (bone, bone-local position) per studio attachment; 0 is the muzzle.
    var attachments: [(bone: Int, org: SIMD3<Float>)]
    /// (texture, three vertices as (bone-local position, bone))
    var triangles: [(texture: Int, v: [(SIMD3<Float>, Int)])]
    /// Bone-local vertex normals, per triangle, parallel to `triangles`.
    var normals: [[SIMD3<Float>]]

    static func fromBodySlot() -> ProbeModel {
        var mesh = lambda_weapon_mesh_t()
        guard lambda_body_lock(&mesh) != 0 else { die("lock") }
        defer { lambda_body_unlock() }
        var pose = lambda_weapon_pose_t()
        _ = lambda_body_copy_pose(&pose)
        var rest = [float4x4](repeating: matrix_identity_float4x4, count: Int(mesh.bone_count))
        withUnsafePointer(to: &pose.bones) { raw in
            raw.withMemoryRebound(to: Float.self, capacity: Int(LAMBDA_WEAPON_MAX_BONES) * 12) { f in
                for i in rest.indices { rest[i] = AvatarRig.matrix(fromRowMajor3x4: f + i * 12) }
            }
        }
        let names: [String] = (0..<Int(mesh.bone_count)).map { b in
            var e = mesh.bones![b]
            return withUnsafeBytes(of: &e.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        let parents: [Int?] = (0..<Int(mesh.bone_count)).map { mesh.bones![$0].parent >= 0 ? Int(mesh.bones![$0].parent) : nil }
        let textures: [String] = (0..<Int(mesh.texture_count)).map { t in
            var e = mesh.textures![t]
            return withUnsafeBytes(of: &e.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        var tris: [(texture: Int, v: [(SIMD3<Float>, Int)])] = []
        var norms: [[SIMD3<Float>]] = []
        for s in 0..<Int(mesh.submesh_count) {
            let sm = mesh.submeshes![s]
            var i = 0
            while i + 2 < Int(sm.index_count) {
                let vs = (0..<3).map { k -> (SIMD3<Float>, Int) in
                    let v = mesh.vertices![Int(mesh.indices![Int(sm.index_offset) + i + k])]
                    return (SIMD3(v.pos.0, v.pos.1, v.pos.2), Int(v.bone))
                }
                tris.append((Int(sm.texture), vs))
                norms.append((0..<3).map { k in
                    let v = mesh.vertices![Int(mesh.indices![Int(sm.index_offset) + i + k])]
                    return SIMD3(v.normal.0, v.normal.1, v.normal.2)
                })
                i += 3
            }
        }
        let attachments: [(bone: Int, org: SIMD3<Float>)] = withUnsafeBytes(of: &mesh.attachments) { raw in
            let a = raw.bindMemory(to: lambda_weapon_attachment_t.self)
            return (0..<Int(mesh.attachment_count)).map { (Int(a[$0].bone), SIMD3(a[$0].org.0, a[$0].org.1, a[$0].org.2)) }
        }
        return ProbeModel(boneNames: names, parents: parents, textureNames: textures,
                          restPose: rest, handBone: Int(mesh.hand_bone_index), attachments: attachments,
                          triangles: tris, normals: norms)
    }
}

/// Writes posed triangles as "label|x y z|x y z|x y z" lines (render with
/// render_tri.py beside this file).
func triLines(_ model: ProbeModel, palette: [float4x4], transform: float4x4, label: String,
              keep: (_ texture: Int, _ bones: [Int]) -> Bool) -> [String] {
    model.triangles.compactMap { tri in
        guard keep(tri.texture, tri.v.map { $0.1 }) else { return nil }
        let ps = tri.v.map { (p, b) -> SIMD3<Float> in
            let w = transform * palette[min(b, palette.count - 1)] * SIMD4<Float>(p, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        return label + ps.map { String(format: "|%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined()
    }
}

func runViewmodelChecks(rig: AvatarRig, gordon: ProbeModel, modelsDir: String, dumpDir: String?) {
    print("\n— viewmodels —")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: modelsDir)) ?? [])
        .filter { $0.hasPrefix("v_") && $0.hasSuffix(".mdl") }.sorted()
    guard !files.isEmpty else { print("no v_*.mdl under \(modelsDir), skipped"); return }

    // The pose the avatar holds a gun in: right hand forward at chest
    // height, fingers forward and a little down, back of the hand outward.
    let eye = SIMD3<Float>(0, 0, 64)
    let rest = rig.pose(AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil))
    let shoulder = PoseSolver.translation(of: rest.root * rest.palette[rig.rightArm!.chain.joints[0]])
    let handTarget = shoulder + SIMD3<Float>(15, 2, -5)
    let handRotation = AvatarRig.handRotation(forward: simd_normalize(SIMD3<Float>(1, 0, -0.35)),
                                              back: SIMD3<Float>(0, -1, 0))
    let armBones = rig.subtree(of: rig.rightArm!.chain.joints[0])

    var worstSynth: Float = 0
    for file in files {
        let path = modelsDir + "/" + file
        guard path.withCString({ lambda_body_load($0, 0) }) != 0 else { print("  \(file): failed to load"); continue }
        let vm = ProbeModel.fromBodySlot()
        let isHand = ViewmodelGrip.handTriangleFilter(textureNames: vm.textureNames, boneNames: vm.boneNames)
        let cut = vm.triangles.filter { isHand($0.texture, $0.v[0].1, $0.v[1].1, $0.v[2].1) }.count
        let geometry = ViewmodelGrip.boneGeometry(
            boneCount: vm.boneNames.count, textureNames: vm.textureNames,
            vertices: vm.triangles.flatMap { tri in tri.v.map { (tri.texture, $0.1) } })
        let grip = ViewmodelGrip.grip(boneNames: vm.boneNames, parents: vm.parents, pose: vm.restPose,
                                      extractorChoice: vm.handBone, geometry: geometry)
        let fingerChains = ViewmodelGrip.fingerChains(parents: vm.parents, geometry: geometry)

        // The synthesised hand frame, built for a hand that has a real Bip01
        // frame, must land on it — that is the evidence it is right on the
        // one rig (the MP5) that has no Bip01 frame to compare against.
        var synthNote = ""
        for (i, name) in vm.boneNames.enumerated() where name.hasSuffix(" Hand") && i < vm.restPose.count {
            let fingers = fingerChains[i]
            guard fingers.count >= 4,
                  let f = ViewmodelGrip.synthesisedHandFrame(hand: i, fingers: fingers, pose: vm.restPose,
                                                             isLeft: name.hasSuffix(" L Hand")) else { continue }
            let delta = PoseSolver.rotation(of: f) * PoseSolver.rotation(of: vm.restPose[i]).inverse
            let deg = abs(delta.angle) * 180 / .pi
            let d = deg > 180 ? 360 - deg : deg
            worstSynth = max(worstSynth, d)
            synthNote += String(format: " synth-vs-%@ %.0f°", name.hasSuffix(" L Hand") ? "L" : "R", d)
        }

        guard let grip else {
            print(String(format: "  %-20@ cut %3d/%3d tris  grip: none%@", file, cut, vm.triangles.count, synthNote))
            continue
        }
        let valveBarrel = ViewmodelGrip.barrelInGrip(grip: grip, idlePalette: vm.restPose)
        let offFingers = acosf(max(-1, min(1, valveBarrel.x))) * 180 / .pi
        let hold = ViewmodelGrip.hold(grip: grip, idlePalette: vm.restPose)
        let barrel = ViewmodelGrip.barrel(grip: grip, hold: hold, idlePalette: vm.restPose, handIsLeft: false)
        let gunPoints = vm.triangles.filter { !isHand($0.texture, $0.v[0].1, $0.v[1].1, $0.v[2].1) }
            .flatMap { $0.v.map { (p, b) in (vm.restPose[min(b, vm.restPose.count - 1)] * SIMD4(p, 1)).xyz3 } }
        let muzzle = ViewmodelGrip.muzzle(attachment: vm.attachments.first, idlePalette: vm.restPose,
                                          gunPoints: gunPoints)
        let muzzleInHand = muzzle.map { ViewmodelGrip.muzzleInHand($0, grip: grip, idlePalette: vm.restPose,
                                                                   handIsLeft: false) }
        print(String(format: "  %-20@ cut %3d/%3d tris  grip %@%@  Valve's hand %.0f° off the barrel → %@%@",
                     file, cut, vm.triangles.count, vm.boneNames[grip.bone],
                     grip.fingerPrefix == nil ? " (synthesised)" : "", offFingers,
                     hold == .aimed ? "aimed" : "held", synthNote))
        if let m = muzzleInHand {
            print(String(format: "      muzzle in hand (%.1f %.1f %.1f) units, from %@", m.x, m.y, m.z,
                         vm.attachments.isEmpty ? "the front of the gun" : "attachment 0"))
        }
        // Guns must come out aimed with the muzzle ahead of the hand. Thrown
        // and placed items may go either way: the split only matters where
        // Valve's hand is far off +X (the classic grenade, 45°), and there
        // they are held.
        let stem = file.replacingOccurrences(of: ".mdl", with: "")
        let guns: Set = ["v_357", "v_9mmar", "v_9mmhandgun", "v_crossbow", "v_egon", "v_gauss", "v_rpg", "v_shotgun"]
        if guns.contains(stem) {
            if hold != .aimed { die("\(file) is a gun but was not aimed") }
            guard let m = muzzleInHand, m.x > 8, abs(m.y) < 6 else { die("\(file): muzzle not ahead of the hand") }
        }

        if CommandLine.arguments.contains("--measure") {
            // Gun-only vertices in idle model space.
            var pts: [SIMD3<Float>] = []
            for tri in vm.triangles where !isHand(tri.texture, tri.v[0].1, tri.v[1].1, tri.v[2].1) {
                for (p, b) in tri.v { pts.append((vm.restPose[min(b, vm.restPose.count - 1)] * SIMD4(p, 1)).xyz3) }
            }
            let mean = pts.reduce(.zero, +) / Float(max(1, pts.count))
            var cov = simd_float3x3()
            for p in pts { let d = p - mean; cov += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z)) }
            var axis = SIMD3<Float>(1, 0, 0)
            for _ in 0..<64 { axis = simd_normalize(cov * axis) }
            if axis.x < 0 { axis = -axis }
            let gp = PoseSolver.translation(of: grip.frame(in: vm.restPose))
            var line = String(format: "      PCA axis (%.2f %.2f %.2f) %.1f° from +X; grip at (%.1f %.1f %.1f)",
                              axis.x, axis.y, axis.z, acosf(min(1, axis.x)) * 180 / .pi, gp.x, gp.y, gp.z)
            for (i, a) in vm.attachments.enumerated() {
                let w = (vm.restPose[a.bone] * SIMD4(a.org, 1)).xyz3
                let d = simd_normalize(w - gp)
                line += String(format: "\n      att%d %@ at (%.1f %.1f %.1f); grip→it (%.2f %.2f %.2f) yaw %.1f° pitch %.1f°", i, vm.boneNames[a.bone],
                               w.x, w.y, w.z, d.x, d.y, d.z, atan2f(d.y, d.x) * 180 / .pi, asinf(d.z) * 180 / .pi)
            }
            print(line)
        }
        guard let dumpDir else { continue }
        // Gordon's right arm holding the gun-only viewmodel, fingers curled
        // by the viewmodel's own idle grip.
        var t = AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: handTarget)
        t.rightHandRotation = handRotation
        t.rightFingers = ViewmodelGrip.fingerPose(boneNames: vm.boneNames, palette: vm.restPose,
                                                  grip: grip, handIsLeft: false)
        let pose = rig.pose(t)
        let hand = rig.handMatrix(pose, left: false)!
        let model = ViewmodelGrip.modelMatrix(hand: hand, grip: grip, hold: hold, palette: vm.restPose,
                                              idlePalette: vm.restPose, handIsLeft: false)
        var lines = triLines(gordon, palette: pose.palette, transform: pose.root, label: "body") { _, bones in
            bones.allSatisfy { armBones.contains($0) }
        }
        lines += triLines(vm, palette: vm.restPose, transform: model, label: "gun") { tex, b in
            !isHand(tex, b[0], b[1], b[2])
        }
        // The barrel ray, as a thin sliver from the hand.
        let origin = PoseSolver.translation(of: hand)
        let dir = simd_normalize((hand * SIMD4<Float>(barrel, 0)).xyz3)
        let side = simd_normalize(simd_cross(dir, SIMD3<Float>(0, 0, 1))) * 0.15
        let tip = origin + dir * 30
        lines.append("ray" + [origin - side, origin + side, tip].map { String(format: "|%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined())
        let out = dumpDir + "/grip_" + file.replacingOccurrences(of: ".mdl", with: ".tri")
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
    print(String(format: "  synthesised hand frames vs real Bip01 hands: worst %.0f°", worstSynth))
    if worstSynth > 30 { die("the synthesised hand frame does not match a real Bip01 hand") }
}

extension SIMD4 where Scalar == Float {
    var xyz3: SIMD3<Float> { SIMD3(x, y, z) }
}
