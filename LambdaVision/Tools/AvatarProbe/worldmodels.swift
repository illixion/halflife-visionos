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
