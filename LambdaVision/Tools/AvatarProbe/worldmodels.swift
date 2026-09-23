// World-model checks: every p_ model laid out by ViewmodelGrip.worldLayout,
// the way the "World model" weapon option holds it — guns aimed along the
// fingers with the muzzle ahead of the hand, held items as authored, the egon
// (no right hand) left to its viewmodel. --grips also writes world_<w>.tri:
// Gordon's right arm holding each one.
//
// Like the viewmodel checks this reuses the body slot, so it runs last.

import Foundation
import RAVERig
import simd

func runWorldModelChecks(rig: AvatarRig, gordon: ProbeModel, modelsDir: String, dumpDir: String?) {
    print("\n— world models in \((modelsDir as NSString).lastPathComponent) —")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: modelsDir)) ?? [])
        .filter { $0.hasPrefix("p_") && $0.hasSuffix(".mdl") }.sorted()
    guard !files.isEmpty else { print("no p_*.mdl under \(modelsDir), skipped"); return }

    // The same held-forward arm as the viewmodel dumps.
    let eye = SIMD3<Float>(0, 0, 64)
    let rest = rig.pose(AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil))
    let shoulder = PoseSolver.translation(of: rest.root * rest.palette[rig.rightArm!.chain.joints[0]])
    var targets = AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil,
                                    rightHand: shoulder + SIMD3<Float>(15, 2, -5))
    targets.rightHandRotation = AvatarRig.handRotation(forward: simd_normalize(SIMD3<Float>(1, 0, -0.35)),
                                                       back: SIMD3<Float>(0, -1, 0))
    let pose = rig.pose(targets)
    let hand = rig.handMatrix(pose, left: false)!
    let armBones = rig.subtree(of: rig.rightArm!.chain.joints[0])

    let guns: Set = ["357", "9mmar", "9mmhandgun", "glock", "crossbow", "gauss", "hgun", "rpg", "shotgun"]
    let heldItems: Set = ["crowbar", "grenade", "satchel", "satchel_radio", "squeak", "tripmine"]
    for file in files {
        guard (modelsDir + "/" + file).withCString({ lambda_body_load($0, 0) }) != 0 else { continue }
        let m = ProbeModel.fromBodySlot()
        let stem = String(file.dropFirst(2).dropLast(4))
        let points = m.triangles.flatMap { tri in
            tri.v.map { (p, b) in (m.restPose[min(b, m.restPose.count - 1)] * SIMD4(p, 1)).xyz3 }
        }
        guard let layout = ViewmodelGrip.worldLayout(boneNames: m.boneNames, restPose: m.restPose,
                                                     points: points) else {
            print(String(format: "  %-13@ no right hand: keeps its viewmodel", stem))
            if stem != "egon" { die("\(file) has no right hand") }
            continue
        }
        var line = String(format: "  %-13@ %@", stem, layout.hold == .aimed ? "aimed" : "held")
        if let mz = layout.muzzle { line += String(format: "  muzzle in hand (%.1f %.1f %.1f)", mz.x, mz.y, mz.z) }
        print(line)
        if guns.contains(stem) {
            if layout.hold != .aimed { die("\(file) is a gun but was not aimed") }
            guard let mz = layout.muzzle, mz.x > 6, abs(mz.y) < 6, abs(mz.z) < 8 else {
                die("\(file): muzzle not ahead of the hand")
            }
        }
        if heldItems.contains(stem), layout.hold != .held { die("\(file) is held but was aimed") }

        // The viewmodel's gun fitted onto this world model: Valve's toe-in,
        // which the app takes out (ViewmodelAlignment).
        let vPath = modelsDir + "/v_" + stem + ".mdl"
        if layout.hold == .aimed, FileManager.default.fileExists(atPath: vPath),
           vPath.withCString({ lambda_body_load($0, 0) }) != 0 {
            let vm = ProbeModel.fromBodySlot()
            let isHand = ViewmodelGrip.handTriangleFilter(textureNames: vm.textureNames, boneNames: vm.boneNames)
            let geometry = ViewmodelGrip.boneGeometry(
                boneCount: vm.boneNames.count, textureNames: vm.textureNames,
                vertices: vm.triangles.flatMap { tri in tri.v.map { (tri.texture, $0.1) } })
            if let grip = ViewmodelGrip.grip(boneNames: vm.boneNames, parents: vm.parents, pose: vm.restPose,
                                             extractorChoice: vm.handBone, geometry: geometry),
               ViewmodelGrip.hold(grip: grip, idlePalette: vm.restPose) == .aimed {
                let g = PoseSolver.translation(of: vm.restPose[grip.bone])
                let gun = vm.triangles.filter { !isHand($0.texture, $0.v[0].1, $0.v[1].1, $0.v[2].1) }
                    .flatMap { $0.v.map { (p, b) in (vm.restPose[min(b, vm.restPose.count - 1)] * SIMD4(p, 1)).xyz3 - g } }
                let world = m.triangles.flatMap { $0.v.map { (p, b) in (layout.palette[min(b, layout.palette.count - 1)] * SIMD4(p, 1)).xyz3 } }
                let t0 = Date()
                if let r = ViewmodelAlignment.fit(gun: gun, world: world) {
                    let yaw = ViewmodelAlignment.accepted(r) ? r.yaw * 180 / .pi : 0
                    print(String(format: "      viewmodel onto it: %.1f° off, covers %.0f%%, residual %.2f in %.0f ms → toe-in correction %+.1f°",
                                 r.degrees, r.coverage * 100, r.residual, Date().timeIntervalSince(t0) * 1000, yaw))
                    // Valve toes guns in to the left; a correction the other
                    // way, or a large one, means the fit found a wrong pose.
                    if yaw > 3 || yaw < -8 { die("\(file): toe-in correction \(yaw)° is implausible") }
                    if stem == "crossbow", yaw > -4 { die("\(file): the crossbow's toe-in was not found") }
                    if let dumpDir {
                        // The viewmodel held with the correction, beside the aim ray.
                        let model = ViewmodelGrip.modelMatrix(hand: hand, grip: grip, hold: .aimed, palette: vm.restPose,
                                                              idlePalette: vm.restPose, handIsLeft: false,
                                                              yawCorrection: yaw * .pi / 180)
                        var lines = triLines(vm, palette: vm.restPose, transform: model, label: "gun") { tex, b in
                            !isHand(tex, b[0], b[1], b[2])
                        }
                        let origin = PoseSolver.translation(of: hand)
                        let dir = simd_normalize((hand * SIMD4<Float>(1, 0, 0, 0)).xyz3)
                        let side = simd_normalize(simd_cross(dir, SIMD3<Float>(0, 0, 1))) * 0.15
                        lines.append("ray" + [origin - side, origin + side, origin + dir * 40]
                            .map { String(format: "|%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined())
                        try? lines.joined(separator: "\n").write(toFile: "\(dumpDir)/aligned_v_\(stem).tri",
                                                                 atomically: true, encoding: .utf8)
                    }
                } else {
                    print("      viewmodel onto it: no fit")
                }
            }
        }

        guard let dumpDir else { continue }
        let model = ViewmodelGrip.modelMatrix(hand: hand, grip: layout.grip, hold: layout.hold,
                                              palette: layout.palette, idlePalette: layout.palette,
                                              handIsLeft: false)
        var lines = triLines(gordon, palette: pose.palette, transform: pose.root, label: "body") { _, bones in
            bones.allSatisfy { armBones.contains($0) }
        }
        lines += triLines(m, palette: layout.palette, transform: model, label: "gun") { _, _ in true }
        // The barrel ray, as a thin sliver from the hand.
        let origin = PoseSolver.translation(of: hand)
        let dir = simd_normalize((hand * SIMD4<Float>(1, 0, 0, 0)).xyz3)
        let side = simd_normalize(simd_cross(dir, SIMD3<Float>(0, 0, 1))) * 0.15
        lines.append("ray" + [origin - side, origin + side, origin + dir * 30]
            .map { String(format: "|%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined())
        try? lines.joined(separator: "\n").write(toFile: "\(dumpDir)/world_\(stem).tri",
                                                 atomically: true, encoding: .utf8)
    }
}
