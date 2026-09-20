//
//  AvatarRig.swift
//  LambdaVision
//
//  The first-person avatar's skeleton: GoldSrc studio bones on one side,
//  RAVERig's framework-free IK on the other.
//
//  `RAVERig` is a target of the RAVEEngine sibling package shared with
//  spatial-ai-character, which poses a RealityKit character with the same
//  arithmetic. Everything specific to GoldSrc — the bone table, the row-major
//  3x4 palette, the `Bip01` naming, Z-up inches — stops here. Everything
//  general — FABRIK, the conversion from solved positions back to joint
//  rotations — lives over there and is tested on the Mac in half a second.
//
//  Spaces: this file works entirely in GoldSrc model space (Z-up, inches) and
//  a "world" that is the same space with the avatar placed in it. The remap to
//  Apple metres happens where it already happens for the weapon, in Renderer.
//  Solving here rather than in metres keeps the bone palette native — it is
//  handed to the vertex shader as-is — and avoids an axis conversion on every
//  target and back on every bone, which is exactly the kind of thing that goes
//  wrong silently and only shows up as a limb bending the wrong way.
//

import Foundation
import RAVERig
import simd

/// A player model adapted for IK: the bone tree, its rest pose, and the
/// landmark bones the solver drives.
struct AvatarRig {

    /// GoldSrc's up axis. Named rather than spelled `SIMD3(0, 0, 1)` at each
    /// use, because a Z-up skeleton inside a Y-up platform is a standing
    /// invitation to mix the two.
    static let up = SIMD3<Float>(0, 0, 1)

    struct Arm {
        /// Upper arm, forearm, hand — the chain FABRIK bends. The clavicle is
        /// deliberately left out: including it lets the shoulder swing toward
        /// a far target, which reads as a shrug on every reach rather than
        /// only on the ones that need it.
        var chain: PoseSolver.Chain
        var hand: Int
        /// Straight-line length of the chain in its rest pose. Anything the
        /// solver is asked to reach beyond this is the caller's bug.
        var reach: Float
    }

    let boneNames: [String]
    let parents: [Int?]
    let solver: PoseSolver
    /// Rest transforms, each relative to its parent.
    let restLocal: [JointPose]
    /// Rest transforms in model space — what the extractor published.
    let restModel: [float4x4]

    let head: Int
    let pelvis: Int
    let leftArm: Arm?
    let rightArm: Arm?

    /// Where the head sits in the rest pose. The avatar is hung from this
    /// point, so it is the one measurement the whole placement depends on.
    var restHeadPosition: SIMD3<Float> { PoseSolver.translation(of: restModel[head]) }

    // MARK: - Construction

    enum LoadError: Error, CustomStringConvertible {
        case noModel
        case noBones
        case missingBone(String)

        var description: String {
            switch self {
            case .noModel: return "no avatar model is loaded"
            case .noBones: return "the avatar model has no bone table"
            case .missingBone(let name): return "the avatar rig has no bone named '\(name)'"
            }
        }
    }

    /// Reads the body slot of the studio extractor.
    ///
    /// `lambda_body_load` must have succeeded first. The rest pose it
    /// publishes is the bind pose, not an animation — the avatar is posed by
    /// tracking, and the rest pose is only the reference the solver builds
    /// rotations against.
    init(fromBodySlot: Void = ()) throws {
        var mesh = lambda_weapon_mesh_t()
        let generation = lambda_body_lock(&mesh)
        defer { lambda_body_unlock() }
        guard generation != 0 else { throw LoadError.noModel }
        guard mesh.bone_count > 0, let bones = mesh.bones else { throw LoadError.noBones }

        var names: [String] = []
        var parents: [Int?] = []
        names.reserveCapacity(Int(mesh.bone_count))
        parents.reserveCapacity(Int(mesh.bone_count))
        for i in 0..<Int(mesh.bone_count) {
            var bone = bones[i]
            let name = withUnsafeBytes(of: &bone.name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            names.append(name)
            parents.append(bone.parent >= 0 ? Int(bone.parent) : nil)
        }

        var pose = lambda_weapon_pose_t()
        guard lambda_body_copy_pose(&pose) != 0 else { throw LoadError.noModel }
        let count = min(names.count, Int(pose.bone_count))
        var model = [float4x4](repeating: matrix_identity_float4x4, count: names.count)
        withUnsafePointer(to: &pose.bones) { raw in
            raw.withMemoryRebound(to: Float.self, capacity: Int(LAMBDA_WEAPON_MAX_BONES) * 12) { f in
                for i in 0..<count { model[i] = AvatarRig.matrix(fromRowMajor3x4: f + i * 12) }
            }
        }

        try self.init(boneNames: names, parents: parents, restModel: model)
    }

    /// The real initialiser, taking plain values so it can be exercised
    /// without the engine or a model file.
    init(boneNames: [String], parents: [Int?], restModel: [float4x4]) throws {
        precondition(boneNames.count == parents.count && boneNames.count == restModel.count)
        self.boneNames = boneNames
        self.parents = parents
        self.restModel = restModel
        self.solver = PoseSolver(parents: parents)

        // The extractor publishes model-space bone matrices; the solver needs
        // parent-relative ones. GoldSrc bones are rigid — rotation and
        // translation, never scale — so a plain inverse recovers them exactly.
        self.restLocal = restModel.indices.map { i in
            let local: float4x4
            if let p = parents[i], p >= 0, p < restModel.count {
                local = restModel[p].inverse * restModel[i]
            } else {
                local = restModel[i]
            }
            return JointPose(rotation: PoseSolver.rotation(of: local),
                             translation: PoseSolver.translation(of: local))
        }

        var index = [String: Int](minimumCapacity: boneNames.count)
        for (i, name) in boneNames.enumerated() { index[name] = i }
        func find(_ name: String) throws -> Int {
            guard let i = index[name] else { throw LoadError.missingBone(name) }
            return i
        }

        // Named lookup rather than RAVERig's `HumanoidInference`, which infers
        // landmarks from topology and skin weights and needs none of these
        // names. That generality is worth having for arbitrary user content;
        // every GoldSrc player model is a Bip01 rig, so here it would only add
        // a way to be wrong.
        self.head = try find("Bip01 Head")
        self.pelvis = (try? find("Bip01 Pelvis")) ?? (parents.firstIndex { $0 == nil } ?? 0)

        // Taken as parameters rather than read off `self`: a local function
        // that touches a stored property counts as using `self` before
        // initialisation is finished.
        self.leftArm = AvatarRig.arm("L", index: index, solver: solver, restModel: restModel)
        self.rightArm = AvatarRig.arm("R", index: index, solver: solver, restModel: restModel)
    }

    private static func arm(_ side: String, index: [String: Int],
                            solver: PoseSolver, restModel: [float4x4]) -> Arm? {
        guard let upper = index["Bip01 \(side) Arm1"],
              let fore = index["Bip01 \(side) Arm2"],
              let hand = index["Bip01 \(side) Hand"],
              let chain = solver.chain([upper, fore, hand]) else { return nil }
        let p = [upper, fore, hand].map { PoseSolver.translation(of: restModel[$0]) }
        let reach = simd_distance(p[0], p[1]) + simd_distance(p[1], p[2])
        return Arm(chain: chain, hand: hand, reach: reach)
    }

    // MARK: - Posing

    /// Where the avatar is and how it is bent, for one frame.
    struct Pose {
        /// Bone → model space, GoldSrc units. Goes straight into the palette.
        var palette: [float4x4]
        /// Model → world. The avatar's placement, kept out of the palette so
        /// the bones stay in the space the mesh was baked in.
        var root: float4x4
        var left: PoseSolver.Report?
        var right: PoseSolver.Report?
    }

    /// Targets for one frame, in world space (GoldSrc units, Z-up).
    struct Targets {
        var headPosition: SIMD3<Float>
        /// Which way the body faces, radians about the up axis. The caller
        /// damps this off the head's yaw — the body should follow a turn, not
        /// mirror every glance.
        var bodyYaw: Float
        var leftHand: SIMD3<Float>?
        var rightHand: SIMD3<Float>?
    }

    /// Places the avatar under the tracked head and bends both arms to the
    /// tracked hands.
    ///
    /// The placement is deliberately not "parent the body to the head". A head
    /// anchor carries pitch and roll, and a body rigidly hung from it would
    /// swing bodily every time the player looked down at their feet. Instead
    /// the root is positioned so the *rest* head lands at the tracked head
    /// position, and rotated by yaw alone; the body then hangs below a head
    /// that can look anywhere without dragging the torso with it.
    ///
    /// The head bone itself is left in its rest pose. In first person you
    /// cannot see your own head, and a wrong head rotation is only visible as
    /// a wrong neck — which is worth fixing after the arms read correctly,
    /// not before.
    /// Iterations per arm.
    ///
    /// Measured on this rig rather than guessed. Sweeping hand targets from
    /// the shoulder outward: eight iterations are exact past 23 cm but 130 mm
    /// adrift at 10 cm, where the elbow is deeply folded; thirty-two are
    /// within a fortieth of a millimetre everywhere FABRIK's own reach and
    /// fold limits leave in play. Two three-joint chains at thirty-two
    /// iterations is nothing next to a single draw call, so there is no reason
    /// to shave it.
    static let armIterations = 32

    func pose(_ targets: Targets, iterations: Int = AvatarRig.armIterations) -> Pose {
        let yaw = simd_quatf(angle: targets.bodyYaw, axis: AvatarRig.up)
        var root = float4x4(yaw)
        root.columns.3 = SIMD4<Float>(targets.headPosition - yaw.act(restHeadPosition), 1)
        let toModel = root.inverse

        var joints = restLocal
        var model = solver.modelMatrices(of: joints)

        // The pole is the direction the elbow is pushed toward — down and
        // back, which is where a human elbow sits when the hand is forward.
        // Passing the body's own backward axis rather than a world constant
        // keeps it right when the player turns.
        let back = yaw.act(SIMD3<Float>(-1, 0, 0))
        let pole = simd_normalize(back - AvatarRig.up * 0.5)

        func solve(_ arm: Arm?, _ worldTarget: SIMD3<Float>?) -> PoseSolver.Report? {
            guard let arm, let worldTarget else { return nil }
            let target = (toModel * SIMD4<Float>(worldTarget, 1)).xyz
            return solver.solve(chain: arm.chain, target: target,
                                pole: (toModel * SIMD4<Float>(pole, 0)).xyz,
                                iterations: iterations,
                                pose: &joints, model: &model)
        }
        let left = solve(leftArm, targets.leftHand)
        let right = solve(rightArm, targets.rightHand)

        // The chains wrote their own matrices as they went, but joints hanging
        // off them — the fingers below each hand — are stale. One clean pass
        // is cheaper than reasoning about which ones moved.
        return Pose(palette: solver.modelMatrices(of: joints), root: root,
                    left: left, right: right)
    }

    // MARK: - Conversions

    /// GoldSrc bone transforms arrive row-major 3x4 (12 floats). Build a
    /// column-major float4x4 (bottom row 0,0,0,1).
    static func matrix(fromRowMajor3x4 m: UnsafePointer<Float>) -> float4x4 {
        float4x4(columns: (
            SIMD4(m[0], m[4], m[8],  0),
            SIMD4(m[1], m[5], m[9],  0),
            SIMD4(m[2], m[6], m[10], 0),
            SIMD4(m[3], m[7], m[11], 1)))
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
