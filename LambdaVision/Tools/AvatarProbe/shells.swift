// Shell checks: the p_ model fitted onto each viewmodel's gun and skinned to
// its bones (ViewmodelShell), then — for eyes — the gun and its hull drawn in
// idle and mid-reload from every side.
//
// Like the viewmodel checks this reuses the body slot, loading the v_ and
// the p_ model in turn and copying each out.

import Foundation
import RAVERig
import simd

/// A p_ model's gun: the triangles skinned under its right hand (the arm and
/// torso bones carry nothing but, on the egon, the backpack).
func gunTriangles(_ m: ProbeModel) -> [Int] {
    var underHand = Set<Int>()
    for i in m.boneNames.indices {
        var b: Int? = i
        while let c = b {
            if m.boneNames[c].hasSuffix(" R Hand") { underHand.insert(i); break }
            b = m.parents[c]
        }
    }
    return m.triangles.indices.filter { t in m.triangles[t].v.allSatisfy { underHand.contains($0.1) } }
}

func posed(_ m: ProbeModel, _ palette: [float4x4], _ p: SIMD3<Float>, _ bone: Int) -> SIMD3<Float> {
    (palette[min(bone, palette.count - 1)] * SIMD4(p, 1)).xyz3
}

func runShellChecks(modelsDir: String, dumpDir: String?) {
    print("\n— shells (p_ hull on the v_ gun) in \((modelsDir as NSString).lastPathComponent) —")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: modelsDir)) ?? [])
        .filter { $0.hasPrefix("v_") && $0.hasSuffix(".mdl") }.sorted()
    if let dumpDir { try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true) }
    var worstGunResidual: Float = 0
    for file in files {
        let stem = String(file.dropFirst(2).dropLast(4))
        let pPath = modelsDir + "/p_" + stem + ".mdl"
        guard FileManager.default.fileExists(atPath: pPath),
              (modelsDir + "/" + file).withCString({ lambda_body_load($0, 0) }) != 0 else { continue }
        let vm = ProbeModel.fromBodySlot()
        var reload: (seq: Int, frames: Int)?
        var name = [CChar](repeating: 0, count: 32), frames: Int32 = 0
        for seq in 0..<64 where lambda_body_sequence(Int32(seq), &name, &frames) != 0 {
            if reload == nil, String(cString: name).lowercased().contains("reload") { reload = (seq, Int(frames)) }
        }
        var reloadPalette: [float4x4]?
        if let reload {
            var pose = lambda_weapon_pose_t()
            if lambda_body_pose_at(Int32(reload.seq), Float(reload.frames) * 0.45, &pose) != 0 {
                reloadPalette = withUnsafePointer(to: &pose.bones) { raw in
                    raw.withMemoryRebound(to: Float.self, capacity: Int(LAMBDA_WEAPON_MAX_BONES) * 12) { f in
                        (0..<vm.boneNames.count).map { AvatarRig.matrix(fromRowMajor3x4: f + $0 * 12) }
                    }
                }
            }
        }
        guard pPath.withCString({ lambda_body_load($0, 0) }) != 0 else { continue }
        let pm = ProbeModel.fromBodySlot()

        let isHand = ViewmodelGrip.handTriangleFilter(textureNames: vm.textureNames, boneNames: vm.boneNames)
        let gunTris = vm.triangles.indices.filter { t in
            let v = vm.triangles[t].v
            return !isHand(vm.triangles[t].texture, v[0].1, v[1].1, v[2].1)
        }
        var target: [SIMD3<Float>] = [], targetBones: [Int] = []
        for t in gunTris { for (p, b) in vm.triangles[t].v { target.append(posed(vm, vm.restPose, p, b)); targetBones.append(b) } }
        let shellTris = gunTriangles(pm)
        let source = shellTris.flatMap { t in pm.triangles[t].v.map { posed(pm, pm.restPose, $0.0, $0.1) } }

        let everything = vm.triangles.flatMap { tri in tri.v.map { posed(vm, vm.restPose, $0.0, $0.1) } }
        var hull = ViewmodelShell.Hull(corners: source, normals: [], uvs: [], textures: [])
        for t in shellTris {
            hull.textures.append(pm.triangles[t].texture)
            for c in 0..<3 {
                hull.normals.append((pm.restPose[pm.triangles[t].v[c].1] * SIMD4(pm.normals[t][c], 0)).xyz3)
                hull.uvs.append(.zero)
            }
        }
        let t0 = Date()
        let built = ViewmodelShell.build(hull: hull, gun: target, gunBones: targetBones,
                                         occluders: everything, idlePalette: vm.restPose)
        let ms = Date().timeIntervalSince(t0) * 1000
        guard let built else {
            let fit = ViewmodelShell.fit(hull: source, gun: target)
            let fits = fit.map { $0.coverage >= ViewmodelShell.minCoverage && $0.residual <= ViewmodelShell.maxResidual } ?? false
            print(String(format: "  %-11@ %@ (%d hull tris; fit covers %.0f%%, residual %.2f)", stem,
                         fits ? "complete, no hull needed" : "no hull: not the same shape",
                         shellTris.count, (fit?.coverage ?? 0) * 100, fit?.residual ?? .nan))
            if ["9mmar", "shotgun", "gauss"].contains(stem) { die("\(stem) got no hull") }
            continue
        }
        var perBone: [String: Int] = [:]
        for k in stride(from: 0, to: built.bones.count, by: 3) { perBone[vm.boneNames[built.bones[k]], default: 0] += 1 }
        let boneList = perBone.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print(String(format: "  %-11@ hull %3d/%3d tris  scale %.2f  residual %.2f u  covers %3.0f%%  built in %4.0f ms  bones: %@",
                     stem, built.kept, built.total, built.fit.scale, built.fit.residual, built.fit.coverage * 100, ms, boneList))
        if ["9mmar", "shotgun", "crossbow", "357", "rpg", "gauss", "9mmhandgun"].contains(stem) {
            worstGunResidual = max(worstGunResidual, built.fit.residual)
        }

        guard let dumpDir else { continue }
        for (label, palette) in [("idle", vm.restPose), ("reload", reloadPalette)] {
            guard let palette else { continue }
            var lines: [String] = []
            for t in gunTris {
                let ps = vm.triangles[t].v.map { posed(vm, palette, $0.0, $0.1) }
                lines.append("gun" + ps.map { String(format: "|%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined())
            }
            for k in stride(from: 0, to: built.positions.count, by: 3) {
                let ps = (0..<3).map { posed(vm, palette, built.positions[k + $0], built.bones[k + $0]) }
                lines.append("shell" + ps.map { String(format: "|%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined())
            }
            try? lines.joined(separator: "\n").write(toFile: "\(dumpDir)/shell_\(stem)_\(label).tri",
                                                     atomically: true, encoding: .utf8)
        }
    }
    print(String(format: "  worst gun residual %.2f units", worstGunResidual))
    if worstGunResidual > 1.5 { die("a p_ hull did not fit its viewmodel") }
}
