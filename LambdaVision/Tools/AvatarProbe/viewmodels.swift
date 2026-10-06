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
        for s in 0..<Int(mesh.submesh_count) {
            let sm = mesh.submeshes![s]
            var i = 0
            while i + 2 < Int(sm.index_count) {
                let vs = (0..<3).map { k -> (SIMD3<Float>, Int) in
                    let v = mesh.vertices![Int(mesh.indices![Int(sm.index_offset) + i + k])]
                    return (SIMD3(v.pos.0, v.pos.1, v.pos.2), Int(v.bone))
                }
                tris.append((Int(sm.texture), vs))
                i += 3
            }
        }
        let attachments: [(bone: Int, org: SIMD3<Float>)] = withUnsafeBytes(of: &mesh.attachments) { raw in
            let a = raw.bindMemory(to: lambda_weapon_attachment_t.self)
            return (0..<Int(mesh.attachment_count)).map { (Int(a[$0].bone), SIMD3(a[$0].org.0, a[$0].org.1, a[$0].org.2)) }
        }
        return ProbeModel(boneNames: names, parents: parents, textureNames: textures,
                          restPose: rest, handBone: Int(mesh.hand_bone_index), attachments: attachments,
                          triangles: tris)
    }
}

/// Each bone's vertices in its own bone space, for ViewmodelGrip.parkedBones.
func boneLocalPoints(_ model: ProbeModel) -> [[SIMD3<Float>]] {
    var out = [[SIMD3<Float>]](repeating: [], count: model.boneNames.count)
    for tri in model.triangles { for (p, b) in tri.v where b < out.count { out[b].append(p) } }
    return out
}

/// Which bones are hidden in the rest pose as parked parts (ViewmodelGrip).
func looseInRest(_ model: ProbeModel) -> [Bool] {
    ViewmodelGrip.looseParts(points: boneLocalPoints(model), restPose: model.restPose, boneNames: model.boneNames)
}

/// The gun's vertices in idle, without hands or loose parts — what the app
/// reads the muzzle from (ViewmodelGrip.muzzle).
func shownGunPoints(_ vm: ProbeModel, loose: [Bool]) -> [SIMD3<Float>] {
    let isHand = ViewmodelGrip.handTriangleFilter(textureNames: vm.textureNames, boneNames: vm.boneNames)
    return vm.triangles.filter { t in
        !isHand(t.texture, t.v[0].1, t.v[1].1, t.v[2].1) && !t.v.allSatisfy { $0.1 < loose.count && loose[$0.1] }
    }.flatMap { $0.v.map { (p, b) in (vm.restPose[min(b, vm.restPose.count - 1)] * SIMD4(p, 1)).xyz3 } }
}

/// How far an aimed gun's muzzle strays from where the aim reads it (the
/// idle pose) while it plays its sequences in the hand: the worst angle of
/// the muzzle's bone's idle +X, the worst muzzle displacement, and the
/// sequence each happens in. The muzzle rides attachment 0's bone when it
/// was read from it, else the gun's body. Draw and holster are skipped (the
/// game holds no aim through them).
func sequenceDrift(_ vm: ProbeModel, grip: ViewmodelGrip.Grip, muzzle: SIMD3<Float>, loose: [Bool])
    -> (degrees: Float, degreesIn: String, units: Float, unitsIn: String, carrier: String) {
    let n = vm.boneNames.count
    let geometry = ViewmodelGrip.boneGeometry(
        boneCount: n, textureNames: vm.textureNames,
        vertices: vm.triangles.flatMap { tri in tri.v.map { (tri.texture, $0.1) } })
    let onAttachment = vm.attachments.first.map {
        $0.bone < n && simd_distance((vm.restPose[$0.bone] * SIMD4($0.org, 1)).xyz3, muzzle) < 1e-4 } == true
    let carrier = onAttachment ? vm.attachments[0].bone
        : ViewmodelGrip.gunBody(geometry: geometry, loose: loose) ?? grip.bone
    guard carrier < n else { return (0, "-", 0, "-", "-") }
    let barrelLocal = (vm.restPose[carrier].inverse * SIMD4<Float>(1, 0, 0, 0)).xyz3
    let muzzleLocal = (vm.restPose[carrier].inverse * SIMD4(muzzle, 1)).xyz3
    let rest = ViewmodelGrip.modelMatrix(hand: matrix_identity_float4x4, grip: grip, hold: .aimed,
                                         palette: vm.restPose, idlePalette: vm.restPose, handIsLeft: false)
    let restMuzzle = (rest * SIMD4(muzzle, 1)).xyz3
    var out: (degrees: Float, degreesIn: String, units: Float, unitsIn: String, carrier: String) = (0, "-", 0, "-", vm.boneNames[carrier])
    var seq: Int32 = 0
    var name = [CChar](repeating: 0, count: 32)
    var frames: Int32 = 0
    var pose = lambda_weapon_pose_t()
    while lambda_body_sequence(seq, &name, &frames) != 0 {
        defer { seq += 1 }
        let label = String(cString: name)
        let l = label.lowercased()
        if l.contains("draw") || l.contains("holster") || l.contains("deploy") || l == "up" || l == "down" { continue }
        for f in 0..<max(1, Int(frames)) where lambda_body_pose_at(seq, Float(f), &pose) != 0 {
            var live = [float4x4](repeating: matrix_identity_float4x4, count: n)
            withUnsafePointer(to: &pose.bones) { raw in
                raw.withMemoryRebound(to: Float.self, capacity: Int(LAMBDA_WEAPON_MAX_BONES) * 12) { p in
                    for i in live.indices { live[i] = AvatarRig.matrix(fromRowMajor3x4: p + i * 12) }
                }
            }
            let m = ViewmodelGrip.modelMatrix(hand: matrix_identity_float4x4, grip: grip, hold: .aimed,
                                              palette: live, idlePalette: vm.restPose, handIsLeft: false)
            let b = simd_normalize((m * live[carrier] * SIMD4(barrelLocal, 0)).xyz3)
            let deg = acosf(max(-1, min(1, b.x))) * 180 / .pi
            let d = simd_distance((m * live[carrier] * SIMD4(muzzleLocal, 1)).xyz3, restMuzzle)
            if deg > out.degrees { out.degrees = deg; out.degreesIn = label }
            if d > out.units { out.units = d; out.unitsIn = label }
        }
    }
    return out
}

func parkedInRest(_ model: ProbeModel) -> [Bool] {
    let pts = boneLocalPoints(model)
    let loose = ViewmodelGrip.looseParts(points: pts, restPose: model.restPose, boneNames: model.boneNames)
    return ViewmodelGrip.parkedBones(loose: loose, points: pts, palette: model.restPose)
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
        let gunPoints = vm.triangles.filter { !isHand($0.texture, $0.v[0].1, $0.v[1].1, $0.v[2].1) }
            .flatMap { $0.v.map { (p, b) in (vm.restPose[min(b, vm.restPose.count - 1)] * SIMD4(p, 1)).xyz3 } }
        let loose = looseInRest(vm)
        let grip = ViewmodelGrip.grip(boneNames: vm.boneNames, parents: vm.parents, pose: vm.restPose,
                                      extractorChoice: vm.handBone, geometry: geometry, gunPoints: gunPoints,
                                      hasAttachment: !vm.attachments.isEmpty, loose: loose)
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

        // Every stock and HD viewmodel must stay hand-anchored; only a mod's
        // unreadable one falls back to the flat viewmodel.
        if !ViewmodelGrip.canAnchorInHand(grip: grip, idlePalette: vm.restPose,
                                          gunVertexCount: vm.triangles.count - cut) {
            die("\(file) would fall back to the flat viewmodel")
        }
        guard let grip else {
            print(String(format: "  %-20@ cut %3d/%3d tris  grip: none%@", file, cut, vm.triangles.count, synthNote))
            if CommandLine.arguments.contains("--measure") {
                var per: [Int: Int] = [:]
                for tri in vm.triangles { for (_, b) in tri.v { per[b, default: 0] += 1 } }
                for (i, n) in vm.boneNames.enumerated() {
                    let p = PoseSolver.translation(of: vm.restPose[i])
                    print(String(format: "      %2d %@ parent %@ verts %d at (%.1f %.1f %.1f)", i, n,
                                 vm.parents[i].map { "\($0)" } ?? "-", per[i] ?? 0, p.x, p.y, p.z))
                }
                print("      textures \(vm.textureNames)")
            }
            continue
        }
        let valveBarrel = ViewmodelGrip.barrelInGrip(grip: grip, idlePalette: vm.restPose)
        let offFingers = acosf(max(-1, min(1, valveBarrel.x))) * 180 / .pi
        let hold = ViewmodelGrip.hold(grip: grip, idlePalette: vm.restPose)
        let barrel = ViewmodelGrip.barrel(grip: grip, hold: hold, idlePalette: vm.restPose, handIsLeft: false)
        let muzzle = ViewmodelGrip.muzzle(attachment: vm.attachments.first, idlePalette: vm.restPose,
                                          gunPoints: shownGunPoints(vm, loose: loose))
        let muzzleInHand = muzzle.map { ViewmodelGrip.muzzleInHand($0, grip: grip, idlePalette: vm.restPose,
                                                                   handIsLeft: false) }
        print(String(format: "  %-20@ cut %3d/%3d tris  grip %@%@  Valve's hand %.0f° off the barrel → %@%@",
                     file, cut, vm.triangles.count, vm.boneNames[grip.bone],
                     grip.fingerPrefix == nil ? " (synthesised)" : "", offFingers,
                     hold == .aimed ? "aimed" : "held", synthNote))
        let fromAttachment = muzzle != nil && vm.attachments.first.map {
            simd_distance((vm.restPose[$0.bone] * SIMD4($0.org, 1)).xyz3, muzzle!) < 1e-4 } == true
        if let m = muzzleInHand {
            print(String(format: "      muzzle in hand (%.1f %.1f %.1f) units, from %@", m.x, m.y, m.z,
                         fromAttachment ? "attachment 0" : vm.attachments.isEmpty ? "the front of the gun"
                             : "the front of the gun (attachment 0 is off the barrel)"))
        }
        // Held still by its body: whatever Valve's hand does on the gun, the
        // barrel must stay on the aim through every sequence it fires,
        // idles and reloads in.
        if hold == .aimed, let muzzle {
            let drift = sequenceDrift(vm, grip: grip, muzzle: muzzle, loose: loose)
            print(String(format: "      held by %@; in the hand the barrel (%@) strays at most %.1f° (%@), the muzzle %.1f units (%@)",
                         vm.boneNames[grip.body ?? grip.bone], drift.carrier, drift.degrees, drift.degreesIn, drift.units, drift.unitsIn))
            // A gun that marks its muzzle is held by its body, so nothing it
            // plays outside draw and holster may turn it off the aim.
            if !vm.attachments.isEmpty, drift.degrees > 1 || drift.units > 0.5 {
                die("\(file): the held gun strays off the aim in \(drift.degreesIn)")
            }
        }
        // Guns must come out aimed with the muzzle ahead of the hand. Thrown
        // and placed items may go either way: the split only matters where
        // Valve's hand is far off +X (the classic grenade, 45°), and there
        // they are held.
        let stem = file.replacingOccurrences(of: ".mdl", with: "")
        let guns: Set = ["v_357", "v_9mmar", "v_9mmhandgun", "v_crossbow", "v_egon", "v_gauss", "v_rpg", "v_shotgun", "v_hgun"]
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
            // Rear-to-front: centroids of the rearmost and frontmost 1.5 units.
            let xs = pts.map(\.x)
            if let lo = xs.min(), let hi = xs.max() {
                let r = pts.filter { $0.x < lo + 1.5 }, f = pts.filter { $0.x > hi - 1.5 }
                let d = simd_normalize(f.reduce(.zero, +) / Float(f.count) - r.reduce(.zero, +) / Float(r.count))
                print(String(format: "      rear→front (%.2f %.2f %.2f) yaw %.1f° pitch %.1f°; PCA yaw %.1f° pitch %.1f°; length %.1f",
                             d.x, d.y, d.z, atan2f(d.y, d.x) * 180 / .pi, asinf(d.z) * 180 / .pi,
                             atan2f(axis.y, axis.x) * 180 / .pi, asinf(axis.z) * 180 / .pi, hi - lo))
            }
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
        writeGripDump(rig: rig, gordon: gordon, vm: vm, grip: grip, hold: hold, barrel: barrel,
                      file: file, dumpDir: dumpDir)
    }
    print(String(format: "  synthesised hand frames vs real Bip01 hands: worst %.0f°", worstSynth))
    if worstSynth > 30 { die("the synthesised hand frame does not match a real Bip01 hand") }
}

/// Gordon's right arm holding the gun-only viewmodel, fingers curled by the
/// viewmodel's own idle grip, as grip_<model>.tri in `dumpDir`.
func writeGripDump(rig: AvatarRig, gordon: ProbeModel, vm: ProbeModel, grip: ViewmodelGrip.Grip,
                   hold: ViewmodelGrip.Hold, barrel: SIMD3<Float>, file: String, dumpDir: String) {
    let isHand = ViewmodelGrip.handTriangleFilter(textureNames: vm.textureNames, boneNames: vm.boneNames)
    // The pose the avatar holds a gun in: right hand forward at chest
    // height, fingers forward and a little down, back of the hand outward.
    let eye = SIMD3<Float>(0, 0, 64)
    let rest = rig.pose(AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil))
    let shoulder = PoseSolver.translation(of: rest.root * rest.palette[rig.rightArm!.chain.joints[0]])
    let handTarget = shoulder + SIMD3<Float>(15, 2, -5)
    let handRotation = AvatarRig.handRotation(forward: simd_normalize(SIMD3<Float>(1, 0, -0.35)),
                                              back: SIMD3<Float>(0, -1, 0))
    let armBones = rig.subtree(of: rig.rightArm!.chain.joints[0])
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
    // Parked parts are not drawn (ViewmodelGrip.parkedBones), as in the app.
    let parked = parkedInRest(vm)
    lines += triLines(vm, palette: vm.restPose, transform: model, label: "gun") { tex, b in
        !isHand(tex, b[0], b[1], b[2]) && !b.allSatisfy { $0 < parked.count && parked[$0] }
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

extension SIMD4 where Scalar == Float {
    var xyz3: SIMD3<Float> { SIMD3(x, y, z) }
}

/// `--anchor=<models dir>`: which viewmodels in another game's models dir
/// the weapon pass would hold in the hand and which it would draw flat
/// (ViewmodelGrip.canAnchorInHand). Reports only; mods may fail. With a
/// `dumpDir` (--grips), also writes each held one's grip_<model>.tri there.
func runAnchorChecks(modelsDir: String, rig: AvatarRig, gordon: ProbeModel, dumpDir: String?) {
    print("\n— hand anchoring in \((modelsDir as NSString).abbreviatingWithTildeInPath) —")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: modelsDir)) ?? [])
        .filter { $0.lowercased().hasPrefix("v_") && $0.lowercased().hasSuffix(".mdl") }.sorted()
    for file in files {
        guard (modelsDir + "/" + file).withCString({ lambda_body_load($0, 0) }) != 0 else {
            print("  \(file): failed to load (external textures?)"); continue
        }
        let vm = ProbeModel.fromBodySlot()
        let isHand = ViewmodelGrip.handTriangleFilter(textureNames: vm.textureNames, boneNames: vm.boneNames)
        let cut = vm.triangles.filter { isHand($0.texture, $0.v[0].1, $0.v[1].1, $0.v[2].1) }.count
        let geometry = ViewmodelGrip.boneGeometry(
            boneCount: vm.boneNames.count, textureNames: vm.textureNames,
            vertices: vm.triangles.flatMap { tri in tri.v.map { (tri.texture, $0.1) } })
        let gunPoints = vm.triangles.filter { !isHand($0.texture, $0.v[0].1, $0.v[1].1, $0.v[2].1) }
            .flatMap { $0.v.map { (p, b) in (vm.restPose[min(b, vm.restPose.count - 1)] * SIMD4(p, 1)).xyz3 } }
        let loose = looseInRest(vm)
        let grip = ViewmodelGrip.grip(boneNames: vm.boneNames, parents: vm.parents, pose: vm.restPose,
                                      extractorChoice: vm.handBone, geometry: geometry, gunPoints: gunPoints,
                                      hasAttachment: !vm.attachments.isEmpty, loose: loose)
        let ok = ViewmodelGrip.canAnchorInHand(grip: grip, idlePalette: vm.restPose,
                                               gunVertexCount: vm.triangles.count - cut)
        let hold = grip.map { ViewmodelGrip.hold(grip: $0, idlePalette: vm.restPose) == .aimed ? "aimed" : "held" } ?? "-"
        // How far each hand bone sits from the nearest gun vertex in idle: a
        // grip that holds the gun is within a few units of it. The grip's own
        // gap is after any pull-in (ViewmodelGrip.pulledIn), marked "pulled".
        func gap(_ bone: Int, pull: SIMD3<Float> = .zero) -> Float {
            let o = PoseSolver.translation(of: vm.restPose[bone]) + pull
            return gunPoints.map { simd_distance($0, o) }.min() ?? .infinity
        }
        let gaps = vm.boneNames.indices.filter { vm.boneNames[$0].hasSuffix(" Hand") && $0 < vm.restPose.count }
            .map { String(format: "%@ %.1f", vm.boneNames[$0].hasSuffix(" L Hand") ? "L" : "R", gap($0)) }
            .joined(separator: " ")
        print(String(format: "  %-24@ cut %4d/%4d  grip %@  %@  → %@  gap %@", file, cut, vm.triangles.count,
                     grip.map { vm.boneNames[$0.bone] + ($0.fingerPrefix == nil ? " (synth)" : "") } ?? "none",
                     hold, ok ? "hand" : "FLAT", grip.map { String(format: "%.1f%@", gap($0.bone, pull: $0.pull), $0.pull == .zero ? "" : " pulled") } ?? "-")
              + (gaps.isEmpty ? "" : " (\(gaps))"))
        let parked = parkedInRest(vm)
        if parked.contains(true) {
            print("      parked out of shot (hidden): " + parked.indices.filter { parked[$0] }.map { vm.boneNames[$0] }.joined(separator: ", "))
        }
        if ok, let grip, ViewmodelGrip.hold(grip: grip, idlePalette: vm.restPose) == .aimed,
           let muzzle = ViewmodelGrip.muzzle(attachment: vm.attachments.first, idlePalette: vm.restPose,
                                             gunPoints: shownGunPoints(vm, loose: loose)) {
            let m = ViewmodelGrip.muzzleInHand(muzzle, grip: grip, idlePalette: vm.restPose, handIsLeft: false)
            let drift = sequenceDrift(vm, grip: grip, muzzle: muzzle, loose: loose)
            let fromAttachment = vm.attachments.first.map {
                simd_distance((vm.restPose[$0.bone] * SIMD4($0.org, 1)).xyz3, muzzle) < 1e-4 } == true
            print(String(format: "      muzzle in hand (%.1f %.1f %.1f) from %@; held by %@, barrel (%@) strays %.1f° (%@), muzzle %.1f units (%@)",
                         m.x, m.y, m.z, fromAttachment ? "attachment 0" : vm.attachments.isEmpty ? "the gun's front" : "the gun's front (attachment 0 off the barrel)",
                         vm.boneNames[grip.body ?? grip.bone], drift.carrier, drift.degrees, drift.degreesIn, drift.units, drift.unitsIn))
        }
        if let dumpDir {
            // The viewmodel as authored, in its idle model space: hands as
            // "cut", the rest as "gun".
            let raw = triLines(vm, palette: vm.restPose, transform: matrix_identity_float4x4, label: "gun") { t, b in
                !isHand(t, b[0], b[1], b[2]) }
                + triLines(vm, palette: vm.restPose, transform: matrix_identity_float4x4, label: "cut") { t, b in
                isHand(t, b[0], b[1], b[2]) }
            try? raw.joined(separator: "\n").write(toFile: dumpDir + "/raw_" + file.replacingOccurrences(of: ".mdl", with: ".tri"),
                                                   atomically: true, encoding: .utf8)
        }
        if let dumpDir, ok, let grip {
            let h = ViewmodelGrip.hold(grip: grip, idlePalette: vm.restPose)
            writeGripDump(rig: rig, gordon: gordon, vm: vm, grip: grip, hold: h,
                          barrel: ViewmodelGrip.barrel(grip: grip, hold: h, idlePalette: vm.restPose,
                                                       handIsLeft: false),
                          file: file, dumpDir: dumpDir)
        }
    }
}
