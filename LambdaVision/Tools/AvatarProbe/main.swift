// Drives the real AvatarRig against the real gordon.mdl on the Mac.
//
// Compiles LambdaVision/AvatarRig.swift and Bridge/Lambda_WeaponModel.c
// verbatim — no copies, no reimplementation — so what passes here is what the
// app runs. Device looks are expensive; a solver that puts a hand in the wrong
// place should never need one to find out.
//
// Build and run with ./build.sh (see there for flags: --bones dumps the rest
// skeleton, --obj writes the posed, cut body as avatar_posed.obj in the
// current directory). Exits non-zero on the first failed check.

import Foundation
import RAVERig
import simd

func die(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let path = args.first
    ?? NSString(string: "~/Projects/halflife-visionos/HalfLifeAssets/valve/models/player/gordon/gordon.mdl").expandingTildeInPath
let dumpOBJ = CommandLine.arguments.contains("--obj")

guard path.withCString({ lambda_body_load($0, 1) }) != 0 else { die("lambda_body_load(\(path))") }

let rig: AvatarRig
do { rig = try AvatarRig() } catch { die("AvatarRig: \(error)") }

print("rig: \(rig.boneNames.count) bones")
print("  head   \(rig.head) '\(rig.boneNames[rig.head])' rest \(fmt(rig.restHeadPosition))")
print("  pelvis \(rig.pelvis) '\(rig.boneNames[rig.pelvis])' rest \(fmt(PoseSolver.translation(of: rig.restModel[rig.pelvis])))")
for (label, arm) in [("L", rig.leftArm), ("R", rig.rightArm)] {
    guard let arm else { print("  \(label) arm: MISSING"); continue }
    print("  \(label) arm: chain \(arm.chain.joints.map { rig.boneNames[$0] }) reach \(String(format: "%.2f", arm.reach)) units (\(String(format: "%.0f", arm.reach * 2.54)) cm)")
}

if CommandLine.arguments.contains("--bones") {
    print("\nrest bone positions (model space):")
    var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    for i in rig.boneNames.indices {
        let p = PoseSolver.translation(of: rig.restModel[i])
        lo = simd_min(lo, p); hi = simd_max(hi, p)
        print("  \(i) \(rig.boneNames[i]) parent \(rig.parents[i] ?? -1) \(fmt(p))")
    }
    print("  bone extent \(fmt(lo)) .. \(fmt(hi))")
}

func fmt(_ v: SIMD3<Float>) -> String {
    String(format: "(%.2f %.2f %.2f)", v.x, v.y, v.z)
}

// MARK: - The rest pose must survive a null solve untouched

do {
    // Hands given their own rest positions and frames, otherwise they relax.
    func restHand(_ arm: AvatarRig.Arm) -> (SIMD3<Float>, simd_quatf) {
        let m = rig.restModel[arm.hand]
        return (PoseSolver.translation(of: m),
                AvatarRig.handRotation(forward: SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                       back: -SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)))
    }
    let (lp, lr) = restHand(rig.leftArm!), (rp, rr) = restHand(rig.rightArm!)
    let targets = AvatarRig.Targets(headPosition: rig.restEyePosition, bodyYaw: 0,
                                    leftHand: lp, rightHand: rp,
                                    leftHandRotation: lr, rightHandRotation: rr)
    let pose = rig.pose(targets)
    // FABRIK owns the elbows — handed the rest wrist it puts the elbow where
    // the pole says, not where sequence 0 had it — so the round-trip is
    // judged on everything outside the arm chains plus the wrists themselves.
    let armJoints = Set(rig.leftArm!.chain.joints + rig.rightArm!.chain.joints)
    var worst: Float = 0, worstHand: Float = 0, elbowMove: Float = 0
    for i in rig.restModel.indices {
        let a = PoseSolver.translation(of: pose.root * pose.palette[i])
        let b = PoseSolver.translation(of: rig.restModel[i])
        if i == rig.leftArm!.hand || i == rig.rightArm!.hand { worstHand = max(worstHand, simd_distance(a, b)) }
        else if armJoints.contains(i) { elbowMove = max(elbowMove, simd_distance(a, b)) }
        else if !rig.subtree(of: rig.leftArm!.hand).contains(i), !rig.subtree(of: rig.rightArm!.hand).contains(i) {
            worst = max(worst, simd_distance(a, b))
        }
    }
    // The rest left arm hangs almost straight (99% of its length), so the
    // comfort limit legitimately holds its wrist short by the excess.
    var allowed: Float = 1e-2
    for arm in [rig.leftArm!, rig.rightArm!] {
        let sh = PoseSolver.translation(of: rig.restModel[arm.chain.joints[0]])
        let hd = PoseSolver.translation(of: rig.restModel[arm.hand])
        allowed = max(allowed, simd_distance(sh, hd) - arm.reach * 0.98 + 1e-2)
    }
    print(String(format: "\nrest pose round-trip: worst bone drift %.5f units, wrists %.5f (comfort limit allows %.3f), elbows re-placed by up to %.2f", worst, worstHand, allowed, elbowMove))
    if worst > 1e-3 || worstHand > allowed { die("the rest pose does not survive being rebuilt from local transforms") }

    // With no hands at all, both arms hang: hands below the shoulders,
    // reached, roughly by the sides.
    let hang = rig.pose(AvatarRig.Targets(headPosition: rig.restEyePosition, bodyYaw: 0,
                                          leftHand: nil, rightHand: nil))
    for (label, arm, report) in [("L", rig.leftArm!, hang.left), ("R", rig.rightArm!, hang.right)] {
        let sh = PoseSolver.translation(of: hang.root * hang.palette[arm.chain.joints[0]])
        let hd = PoseSolver.translation(of: hang.root * hang.palette[arm.hand])
        print(String(format: "  %@ arm untracked: hand %@ is %.1f units below the shoulder, reached %d",
                     label, fmt(hd), sh.z - hd.z, report?.reached == true ? 1 : 0))
        if sh.z - hd.z < arm.reach * 0.8 || report?.reached != true { die("an untracked arm does not hang") }
    }
}

// MARK: - Is the published rest pose the pose the mesh was baked against?

do {
    var mesh = lambda_weapon_mesh_t()
    guard lambda_body_lock(&mesh) != 0 else { die("lock") }
    defer { lambda_body_unlock() }
    var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    for i in 0..<Int(mesh.vertex_count) {
        let v = mesh.vertices![i]
        let bone = min(Int(v.bone), rig.restModel.count - 1)
        let p = (rig.restModel[bone] * SIMD4<Float>(v.pos.0, v.pos.1, v.pos.2, 1))
        let q = SIMD3<Float>(p.x, p.y, p.z)
        lo = simd_min(lo, q); hi = simd_max(hi, q)
    }
    print("\nskinned with the published rest pose: bbox \(fmt(lo)) .. \(fmt(hi))")
    print("  extractor reported at bake time:     bbox \(fmt(SIMD3(mesh.bbmin.0, mesh.bbmin.1, mesh.bbmin.2))) .. \(fmt(SIMD3(mesh.bbmax.0, mesh.bbmax.1, mesh.bbmax.2)))")
    print(String(format: "  height %.1f units (%.2f m)", hi.z - lo.z, (hi.z - lo.z) * 0.0254))
}

// MARK: - Placement: the eyes land exactly on the tracked head, whichever way it looks

do {
    let eyeOffset = AvatarRig.defaultEyeOffset
    func eye(_ pose: AvatarRig.Pose) -> SIMD3<Float> {
        let restHead = PoseSolver.rotation(of: rig.restModel[rig.head])
        let m = pose.root * pose.palette[rig.head]
        let p = m * SIMD4<Float>(restHead.inverse.act(eyeOffset), 1)
        return SIMD3(p.x, p.y, p.z)
    }
    for yaw in [Float(0), .pi / 4, .pi, -1.2] {
        let target = SIMD3<Float>(120, -45, 64)
        let pose = rig.pose(AvatarRig.Targets(headPosition: target, bodyYaw: yaw,
                                              leftHand: nil, rightHand: nil))
        let err = simd_distance(eye(pose), target)
        print(String(format: "placement yaw %+.2f rad: eye at %@ err %.5f", yaw, fmt(eye(pose)), err))
        if err > 1e-3 { die("eye placement is off by \(err) units") }
    }

    // Looking down 45°: the eyes stay put, the skull pitches about the neck,
    // and the neck itself moves by exactly the chord the eye offset sweeps
    // (2·|offset|·sin 22.5°), not by a body-length's worth of torso.
    let target = SIMD3<Float>(0, 0, 64)
    let level = rig.pose(AvatarRig.Targets(headPosition: target, bodyYaw: 0, leftHand: nil, rightHand: nil,
                                           headRotation: AvatarRig.headRotation(forward: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1))))
    let c = cosf(.pi / 4), sn = sinf(.pi / 4)
    let down = rig.pose(AvatarRig.Targets(headPosition: target, bodyYaw: 0, leftHand: nil, rightHand: nil,
                                          headRotation: AvatarRig.headRotation(forward: SIMD3(c, 0, -sn), up: SIMD3(sn, 0, c))))
    let e1 = simd_distance(eye(level), target), e2 = simd_distance(eye(down), target)
    let neck = rig.parents[rig.head]!
    let neckMove = simd_distance(PoseSolver.translation(of: level.root * level.palette[neck]),
                                 PoseSolver.translation(of: down.root * down.palette[neck]))
    // The head bone's world rotation must have turned by exactly the tracked delta.
    let restHead = PoseSolver.rotation(of: rig.restModel[rig.head])
    let turned = PoseSolver.rotation(of: down.root * down.palette[rig.head]) * restHead.inverse
    let fwd = turned.act(SIMD3<Float>(1, 0, 0))
    print(String(format: "head pitch: eye err level %.5f down %.5f, neck moved %.2f units, head forward now %@",
                 e1, e2, neckMove, fmt(fwd)))
    if e1 > 1e-3 || e2 > 1e-3 { die("the eye left its target when the head turned") }
    let chord = 2 * simd_length(eyeOffset) * sinf(.pi / 8)
    if abs(neckMove - chord) > 0.05 { die(String(format: "pitching the head moved the neck %.2f units, expected the %.2f chord", neckMove, chord)) }
    if simd_distance(fwd, SIMD3(c, 0, -sn)) > 1e-3 { die("the head bone did not take the tracked pitch") }
    // A level head must leave the head bone exactly at rest.
    let levelDelta = PoseSolver.rotation(of: level.root * level.palette[rig.head]) * restHead.inverse
    if abs(levelDelta.angle) > 1e-3 { die("a level head rotated the head bone by \(levelDelta.angle) rad") }
}

// MARK: - Wrists: the tracked frame lands on the bone, the rest frame is a no-op

do {
    guard let right = rig.rightArm, let left = rig.leftArm else { die("no arms") }
    let headTarget = rig.restEyePosition
    let rest = rig.pose(AvatarRig.Targets(headPosition: headTarget, bodyYaw: 0, leftHand: nil, rightHand: nil))
    func axes(_ m: float4x4) -> (x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) {
        (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
         SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
         SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }
    for (label, arm) in [("L", left), ("R", right)] {
        // Feed the rest hand's own frame back in: X = fingers, +Y = palm,
        // so back of hand = -Y. Nothing should move.
        let a = axes(rest.root * rest.palette[arm.hand])
        let q = AvatarRig.handRotation(forward: a.x, back: -a.y)
        var t = AvatarRig.Targets(headPosition: headTarget, bodyYaw: 0, leftHand: nil, rightHand: nil)
        if label == "L" { t.leftHandRotation = q } else { t.rightHandRotation = q }
        let p = rig.pose(t)
        var drift: Float = 0
        for i in rig.boneNames.indices {
            drift = max(drift, simd_distance(PoseSolver.translation(of: p.root * p.palette[i]),
                                             PoseSolver.translation(of: rest.root * rest.palette[i])))
        }
        print(String(format: "%@ wrist rest frame round-trip: worst bone drift %.5f", label, drift))
        if drift > 1e-3 { die("feeding the rest wrist frame back moved the rig") }

        // Now a real pose: hand forward at chest height, palm down. The
        // hand bone's X must point where the fingers were told to, its -Y
        // must be the back of the hand, and the fingertips must follow.
        let shoulder = PoseSolver.translation(of: rest.root * rest.palette[arm.chain.joints[0]])
        let handTarget = shoulder + SIMD3<Float>(14, label == "L" ? 3 : -3, -6)
        let fwd = simd_normalize(SIMD3<Float>(1, label == "L" ? -0.2 : 0.2, -0.1))
        let back = simd_normalize(SIMD3<Float>(0.1, 0, 1) - fwd * simd_dot(SIMD3<Float>(0.1, 0, 1), fwd))
        let q2 = AvatarRig.handRotation(forward: fwd, back: back)
        var t2 = AvatarRig.Targets(headPosition: headTarget, bodyYaw: 0.3, leftHand: nil, rightHand: nil)
        if label == "L" { t2.leftHand = handTarget; t2.leftHandRotation = q2 }
        else { t2.rightHand = handTarget; t2.rightHandRotation = q2 }
        let p2 = rig.pose(t2)
        let b = axes(p2.root * p2.palette[arm.hand])
        let posErr = simd_distance(PoseSolver.translation(of: p2.root * p2.palette[arm.hand]), handTarget)
        let fwdErr = simd_distance(simd_normalize(b.x), fwd)
        let backErr = simd_distance(simd_normalize(-b.y), back)
        let finger = rig.boneNames.firstIndex(of: "Bip01 \(label) Finger1")!
        let fingerDir = simd_normalize(PoseSolver.translation(of: p2.root * p2.palette[finger])
                                       - PoseSolver.translation(of: p2.root * p2.palette[arm.hand]))
        print(String(format: "%@ wrist posed: pos err %.4f, fingers axis err %.4f, back-of-hand err %.4f, index bone leaves along %@ (%.0f° off fingers)",
                     label, posErr, fwdErr, backErr, fmt(fingerDir), acosf(min(1, simd_dot(fingerDir, fwd))) * 180 / .pi))
        if posErr > 0.05 { die("orienting the wrist moved it off its target") }
        if fwdErr > 1e-3 || backErr > 1e-3 { die("the wrist did not take the tracked frame") }
    }
}

// MARK: - What the body upload leaves out

do {
    var mesh = lambda_weapon_mesh_t()
    guard lambda_body_lock(&mesh) != 0 else { die("lock") }
    defer { lambda_body_unlock() }
    for legs in [false, true] {
        let hidden = rig.hiddenBones(legs: legs)
        var touching = 0, total = 0
        var i = 0
        while i + 2 < Int(mesh.index_count) {
            total += 1
            let bones = (0..<3).map { Int(mesh.vertices![Int(mesh.indices![i + $0])].bone) }
            if bones.contains(where: { hidden.contains($0) }) { touching += 1 }
            i += 3
        }
        print("hidden bones (legs \(legs ? "shown" : "hidden")): \(hidden.count) bones — \(hidden.sorted().map { rig.boneNames[$0] }.joined(separator: ", "))")
        print("  drops \(touching) of \(total) triangles")
        if !hidden.contains(rig.head) { die("the head is not hidden") }
        if legs == false, !hidden.contains(rig.boneNames.firstIndex(of: "Bip01 L Foot")!) { die("the feet are not hidden") }
        if hidden.contains(rig.pelvis) || hidden.contains(rig.rightArm!.hand) { die("hiding took the torso or a hand with it") }
    }
}

// MARK: - Reach: hands land on their targets across the working volume

do {
    guard let right = rig.rightArm, let left = rig.leftArm else { die("no arms") }
    let headTarget = SIMD3<Float>(0, 0, 64)
    let yaw: Float = 0
    // Targets are WORLD space, so the shoulder has to be read out of a placed
    // pose — the model-space position is ~35 units lower and every target
    // built from it would read as out of reach.
    let placed = rig.pose(AvatarRig.Targets(headPosition: headTarget, bodyYaw: yaw,
                                            leftHand: nil, rightHand: nil))
    func world(_ bone: Int) -> SIMD3<Float> {
        PoseSolver.translation(of: placed.root * placed.palette[bone])
    }
    let shoulder = world(right.chain.joints[0])
    print("\nworld shoulder \(fmt(shoulder)), rest hand \(fmt(world(right.hand)))")

    // How hard the fold is, versus how well it converges, versus how many
    // iterations it took. FABRIK is known to converge slowly near full
    // extension; the other end — a deeply folded chain — is the one that
    // shows up here, because a wrist really can come within a hand's breadth
    // of its own shoulder.
    // Error against how folded the arm is, at the iteration count we would
    // actually ship. The minimum reach of a 2-segment chain is |l1 - l2|; the
    // question is how much clearance above it the solver needs.
    do {
        let ls = zip(right.chain.joints, right.chain.joints.dropFirst()).map {
            simd_distance(PoseSolver.translation(of: rig.restModel[$0]),
                          PoseSolver.translation(of: rig.restModel[$1]))
        }
        let minReach = max(0, 2 * ls.max()! - ls.reduce(0, +))
        print(String(format: "  segments %@ total %.2f, geometric minimum reach %.2f units",
                     ls.map { String(format: "%.2f", $0) }.joined(separator: " + "),
                     ls.reduce(0, +), minReach))
      for iters in [8, 32, 128] {
        var band = [Int: Float]()
        for r in stride(from: Float(1), through: 21, by: 1) {
            for dy in stride(from: Float(-1), through: 1, by: 0.5) {
                for dz in stride(from: Float(-1), through: 1, by: 0.5) {
                    var dir = SIMD3<Float>(1, dy, dz)
                    dir = simd_normalize(dir)
                    let t = shoulder + dir * r
                    let p = rig.pose(AvatarRig.Targets(headPosition: headTarget, bodyYaw: yaw,
                                                       leftHand: nil, rightHand: t), iterations: iters)
                    let e = simd_distance(PoseSolver.translation(of: p.root * p.palette[right.hand]), t)
                    band[Int(r)] = max(band[Int(r)] ?? 0, e)
                }
            }
        }
        print("  worst error (mm) by distance from shoulder, \(iters) iterations:")
        print("    " + band.keys.sorted().map { String(format: "%.0f:%.1f", Float($0), band[$0]! * 25.4) }.joined(separator: "  "))
      }
    }

    for iters in [4, 8, 16, 32] {
        var w: Float = 0, at = SIMD3<Float>(), n = 0
        for dx in stride(from: Float(2), through: 20, by: 3) {
            for dy in stride(from: Float(-12), through: 12, by: 4) {
                for dz in stride(from: Float(-14), through: 10, by: 4) {
                    let t = shoulder + SIMD3<Float>(dx, dy, dz)
                    if simd_distance(t, shoulder) > right.reach * 0.97 { continue }
                    n += 1
                    let p = rig.pose(AvatarRig.Targets(headPosition: headTarget, bodyYaw: yaw,
                                                       leftHand: nil, rightHand: t),
                                     iterations: iters)
                    let e = simd_distance(PoseSolver.translation(of: p.root * p.palette[right.hand]), t)
                    if e > w { w = e; at = t }
                }
            }
        }
        print(String(format: "  %2d iterations: worst %.4f units (%.1f mm) at %@ over %d targets",
                     iters, w, w * 25.4, fmt(at), n))
    }

    var worst: Float = 0
    var worstAt = SIMD3<Float>()
    var extended = 0, unreachable = 0, folded = 0, samples = 0
    // A grid through the space a seated player's hands actually occupy:
    // forward of the shoulder, within arm's length.
    for dx in stride(from: Float(2), through: 20, by: 3) {
        for dy in stride(from: Float(-12), through: 12, by: 4) {
            for dz in stride(from: Float(-14), through: 10, by: 4) {
                let t = shoulder + SIMD3<Float>(dx, dy, dz)
                if simd_distance(t, shoulder) > right.reach * 0.97 { continue }
                samples += 1
                let pose = rig.pose(AvatarRig.Targets(headPosition: headTarget, bodyYaw: yaw,
                                                      leftHand: nil, rightHand: t))
                let hand = PoseSolver.translation(of: pose.root * pose.palette[right.hand])
                let err = simd_distance(hand, t)
                if pose.right?.extended == true { extended += 1 }
                if pose.right?.outOfReach == true { unreachable += 1 }
                // A folded target is one the arm is not allowed to reach —
                // the hand stops at the limit and says so. Judging the solver
                // on those would be judging it for obeying.
                if pose.right?.folded == true { folded += 1; continue }
                if err > worst { worst = err; worstAt = t }

                // Segments must keep their rest lengths — a solver that
                // stretches the arm hides its own failure to reach.
                let j = right.chain.joints.map { PoseSolver.translation(of: pose.palette[$0]) }
                let restJ = right.chain.joints.map { PoseSolver.translation(of: rig.restModel[$0]) }
                for k in 0..<(j.count - 1) {
                    let now = simd_distance(j[k], j[k + 1])
                    let was = simd_distance(restJ[k], restJ[k + 1])
                    if abs(now - was) > 1e-2 {
                        die(String(format: "segment %d stretched %.4f -> %.4f reaching %@", k, was, now, fmt(t)))
                    }
                }
            }
        }
    }
    print(String(format: "\nright-hand reach: %d targets, worst error %.4f units (%.2f mm) at %@",
                 samples, worst, worst * 25.4, fmt(worstAt)))
    print("  \(extended) at the comfort limit, \(unreachable) out of reach, \(folded) folded past the limit")
    if worst > 0.15 { die("the hand does not reach its target") }   // 0.15 units = 3.8 mm

    // Both arms at once, to be sure one does not undo the other.
    let lShoulder = world(left.chain.joints[0])
    let lt = lShoulder + SIMD3<Float>(14, 4, -6)
    let rt = shoulder + SIMD3<Float>(14, -4, -6)
    let pose = rig.pose(AvatarRig.Targets(headPosition: headTarget, bodyYaw: 0,
                                          leftHand: lt, rightHand: rt))
    let lh = PoseSolver.translation(of: pose.root * pose.palette[left.hand])
    let rh = PoseSolver.translation(of: pose.root * pose.palette[right.hand])
    print(String(format: "both arms: L err %.4f  R err %.4f", simd_distance(lh, lt), simd_distance(rh, rt)))
    if simd_distance(lh, lt) > 0.05 || simd_distance(rh, rt) > 0.05 { die("two arms interfere") }
}

// MARK: - Elbows go where elbows go

do {
    let eye = SIMD3<Float>(0, 0, 64)
    let base = rig.pose(AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil))
    print("\nelbow placement (offset from the shoulder–hand midpoint, units):")
    for (label, arm, side) in [("L", rig.leftArm!, Float(1)), ("R", rig.rightArm!, Float(-1))] {
        let sh = PoseSolver.translation(of: base.root * base.palette[arm.chain.joints[0]])
        // Hand offsets from the shoulder: forward, outward, up. Each case
        // names where a human elbow goes, and the assertion is that shape:
        // below the line always, and never up behind the shoulder — which is
        // exactly what a pole that only fixed the plane produced for a hand
        // raised to the face, seeded from sequence 0's raised right arm.
        let cases: [(String, SIMD3<Float>, (SIMD3<Float>) -> Bool)] = [
            ("forward at chest",   SIMD3(16, 0, -2),        { $0.z < -4 }),
            ("raised to the face", SIMD3(8, 0, 8),          { $0.z < -2 && $0.x > 0 }),
            ("folded at shoulder", SIMD3(5, 2 * side, 2),   { $0.z < -4 && $0.x > -1 }),
            ("hanging",            SIMD3(2, 1 * side, -19), { $0.x < -2 }),
            ("out to the side",    SIMD3(4, 14 * side, -6), { $0.z < -3 }),
            ("across the chest",   SIMD3(10, -10 * side, -4), { $0.z < -4 }),
        ]
        for (name, off, ok) in cases {
            var t = AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil)
            if label == "L" { t.leftHand = sh + off } else { t.rightHand = sh + off }
            let p = rig.pose(t)
            let j = arm.chain.joints.map { PoseSolver.translation(of: p.root * p.palette[$0]) }
            var e = j[1] - (j[0] + j[2]) / 2
            e.y *= side   // report "outward" for both arms
            print(String(format: "  %@ %-19@ fwd %+6.2f  out %+6.2f  up %+6.2f%@",
                         label, name, e.x, e.y, e.z, ok(e) ? "" : "   <-- WRONG"))
            if !ok(e) { die("the \(label) elbow is in the wrong place with the hand \(name)") }
        }
    }
}

// MARK: - A tracked elbow overrides the guess

do {
    let eye = SIMD3<Float>(0, 0, 64)
    let base = rig.pose(AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil))
    for (label, arm, side) in [("L", rig.leftArm!, Float(1)), ("R", rig.rightArm!, Float(-1))] {
        let sh = PoseSolver.translation(of: base.root * base.palette[arm.chain.joints[0]])
        let hand = sh + SIMD3<Float>(14, 0, 0)
        // Deliberately unnatural: the real elbow held UP and inward, the
        // opposite of where the synthetic pole would put it. The tracked
        // elbow must win, and its distance from the line is the rig's, not
        // the player's — a hint about direction, not a position to copy.
        let elbowHint = sh + SIMD3<Float>(7, -3 * side, 6)
        var t = AvatarRig.Targets(headPosition: eye, bodyYaw: 0, leftHand: nil, rightHand: nil)
        if label == "L" { t.leftHand = hand; t.leftElbow = elbowHint } else { t.rightHand = hand; t.rightElbow = elbowHint }
        let p = rig.pose(t)
        let j = arm.chain.joints.map { PoseSolver.translation(of: p.root * p.palette[$0]) }
        let e = j[1] - (j[0] + j[2]) / 2
        let handErr = simd_distance(j[2], hand)
        print(String(format: "%@ elbow hinted up-inward: elbow off-line fwd %+.2f out %+.2f up %+.2f, hand err %.4f", label, e.x, e.y * side, e.z, handErr))
        if e.z < 2 || e.y * side > 0 { die("the tracked elbow did not take the bend with it") }
        if handErr > 0.05 { die("the elbow hint moved the hand") }
        // Segment lengths still the rig's own.
        let rest = arm.chain.joints.map { PoseSolver.translation(of: rig.restModel[$0]) }
        for k in 0..<2 where abs(simd_distance(j[k], j[k + 1]) - simd_distance(rest[k], rest[k + 1])) > 1e-2 {
            die("the elbow hint stretched the arm")
        }
    }
}

// MARK: - A posed body, for eyes

if dumpOBJ {
    guard let right = rig.rightArm, let left = rig.leftArm else { die("no arms") }
    var mesh = lambda_weapon_mesh_t()
    guard lambda_body_lock(&mesh) != 0 else { die("lock") }
    defer { lambda_body_unlock() }

    let lShoulder = PoseSolver.translation(of: rig.restModel[left.chain.joints[0]])
    let rShoulder = PoseSolver.translation(of: rig.restModel[right.chain.joints[0]])
    let c = cosf(0.5), sn = sinf(0.5)
    let pose = rig.pose(AvatarRig.Targets(
        headPosition: rig.restEyePosition, bodyYaw: 0,
        leftHand: lShoulder + SIMD3<Float>(15, 5, -8),
        rightHand: rShoulder + SIMD3<Float>(15, -5, -8),
        headRotation: AvatarRig.headRotation(forward: SIMD3(c, 0, -sn), up: SIMD3(sn, 0, c)),
        leftHandRotation: AvatarRig.handRotation(forward: SIMD3(1, 0, 0), back: SIMD3(0, 0, 1)),
        rightHandRotation: AvatarRig.handRotation(forward: SIMD3(1, 0, 0), back: SIMD3(0, 0, 1))))
    let hidden = rig.hiddenBones(legs: false)

    var out = "# gordon.mdl posed by AvatarRig (head and legs cut as the body pass cuts them)\n"
    for i in 0..<Int(mesh.vertex_count) {
        let v = mesh.vertices![i]
        let local = SIMD4<Float>(v.pos.0, v.pos.1, v.pos.2, 1)
        let bone = min(Int(v.bone), pose.palette.count - 1)
        let p = (pose.root * pose.palette[bone] * local)
        out += String(format: "v %.4f %.4f %.4f\n", p.x, p.y, p.z)
    }
    var i = 0
    var kept = 0
    while i + 2 < Int(mesh.index_count) {
        let bones = (0..<3).map { Int(mesh.vertices![Int(mesh.indices![i + $0])].bone) }
        if !bones.contains(where: { hidden.contains($0) }) {
            out += "f \(mesh.indices![i] + 1) \(mesh.indices![i + 1] + 1) \(mesh.indices![i + 2] + 1)\n"
            kept += 1
        }
        i += 3
    }
    let dst = FileManager.default.currentDirectoryPath + "/avatar_posed.obj"
    try? out.write(toFile: dst, atomically: true, encoding: .utf8)
    print("\nwrote \(dst) (\(mesh.vertex_count) verts, \(kept) of \(mesh.index_count / 3) tris)")
}

print("\nOK")
