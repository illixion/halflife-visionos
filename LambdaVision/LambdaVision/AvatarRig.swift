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
        /// The finger bones below the hand, parents first, each with the name
        /// a finger pose is keyed by ("Finger0", "Finger11", …). GoldSrc
        /// player models carry a thumb and one mitten for the other four.
        var fingers: [(bone: Int, key: String)]
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

    struct Leg {
        /// Thigh, shin, foot — the chain FABRIK bends. The foot joint is the
        /// ankle, which is what the solver puts on its target.
        var chain: PoseSolver.Chain
        var thigh: Int
        var shin: Int
        var foot: Int
        /// The ankle's height above the sole, units: the lowest foot vertex
        /// of the rest pose, which stands flat.
        var ankleHeight: Float
        /// Thigh plus shin once compressed by `compression`, units.
        var length: Float
        /// Factor on the thigh and shin that makes Gordon's legs fit the
        /// game's eye height (see `gameEyeHeight`).
        var compression: Float
        /// Unit bone-local directions along the thigh and the shin, which the
        /// compression squashes the mesh along.
        var thighAxis: SIMD3<Float>
        var shinAxis: SIMD3<Float>
        /// The foot's model-space rotation at rest, flat on the floor and
        /// facing the model's +X.
        var restFootRotation: simd_quatf
        /// The hip joint at rest, model space.
        var restHip: SIMD3<Float>
    }
    let leftLeg: Leg?
    let rightLeg: Leg?

    /// Half the distance between the hip joints, units.
    var hipHalfWidth: Float {
        guard let l = leftLeg, let r = rightLeg else { return 3.7 }
        return simd_distance(l.restHip, r.restHip) / 2
    }

    /// The eye height the game stands the player at: VEC_VIEW (28) above an
    /// origin 36 above the floor, units. Gordon's own eyes stand 68 up, so a
    /// body hung from the game's camera would have to bend its knees ~56° to
    /// stand — at full extension a little height costs a lot of knee.
    /// Instead his thighs and shins are shortened until standing straight
    /// puts his eyes at 64: about 12%, which first-person, looking down along
    /// the legs, does not read.
    static let gameEyeHeight: Float = 64

    /// Torso vertices (bone, bone-local position) the eye must keep clear
    /// of: pelvis, spine, neck and clavicles — everything that rides with
    /// the root and can end up in front of a camera looking down. Arms and
    /// hands are left out on purpose; bringing a hand to the face is the
    /// player's choice and must not shove the body around.
    let clearanceVertices: [(bone: Int, position: SIMD3<Float>)]

    /// Where the head bone sits in the rest pose. The eyes, which the avatar
    /// actually hangs from, are `Targets.eyeOffset` forward and up of here.
    var restHeadPosition: SIMD3<Float> { PoseSolver.translation(of: restModel[head]) }

    /// Where the eyes sit in the rest pose with the default eye offset.
    var restEyePosition: SIMD3<Float> { restHeadPosition + AvatarRig.defaultEyeOffset }

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

        var vertices: [(bone: Int, position: SIMD3<Float>)] = []
        if let verts = mesh.vertices {
            vertices.reserveCapacity(Int(mesh.vertex_count))
            for i in 0..<Int(mesh.vertex_count) {
                let v = verts[i]
                vertices.append((Int(v.bone), SIMD3(v.pos.0, v.pos.1, v.pos.2)))
            }
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

        try self.init(boneNames: names, parents: parents, restModel: model, vertices: vertices)
    }

    /// The bones whose vertices the eye keeps clear of (`clearanceVertices`).
    static func isTorsoBone(_ name: String) -> Bool {
        name == "Bip01 Pelvis" || name.hasPrefix("Bip01 Spine") || name == "Bip01 Neck"
            || name == "Bip01 L Arm" || name == "Bip01 R Arm"
    }

    /// The real initialiser, taking plain values so it can be exercised
    /// without the engine or a model file.
    ///
    /// `vertices` (bone, bone-local position) are the mesh's, for the few
    /// things the rig measures off the surface rather than the bones: the
    /// torso the eye keeps clear of, and where the soles are.
    init(boneNames: [String], parents: [Int?], restModel: [float4x4],
         vertices: [(bone: Int, position: SIMD3<Float>)] = []) throws {
        precondition(boneNames.count == parents.count && boneNames.count == restModel.count)
        self.clearanceVertices = vertices.filter { $0.bone < boneNames.count && AvatarRig.isTorsoBone(boneNames[$0.bone]) }
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

        let eyeHeight = PoseSolver.translation(of: restModel[head]).z + AvatarRig.defaultEyeOffset.z
        self.leftLeg = AvatarRig.leg("L", index: index, solver: solver, restModel: restModel,
                                     restLocal: restLocal, vertices: vertices, restEyeZ: eyeHeight)
        self.rightLeg = AvatarRig.leg("R", index: index, solver: solver, restModel: restModel,
                                      restLocal: restLocal, vertices: vertices, restEyeZ: eyeHeight)
    }

    private static func arm(_ side: String, index: [String: Int],
                            solver: PoseSolver, restModel: [float4x4]) -> Arm? {
        guard let upper = index["Bip01 \(side) Arm1"],
              let fore = index["Bip01 \(side) Arm2"],
              let hand = index["Bip01 \(side) Hand"],
              let chain = solver.chain([upper, fore, hand]) else { return nil }
        let p = [upper, fore, hand].map { PoseSolver.translation(of: restModel[$0]) }
        let reach = simd_distance(p[0], p[1]) + simd_distance(p[1], p[2])
        let prefix = "Bip01 \(side) "
        let fingers = solver.order.compactMap { i -> (bone: Int, key: String)? in
            guard let name = index.first(where: { $0.value == i })?.key,
                  name.hasPrefix(prefix + "Finger") else { return nil }
            return (i, String(name.dropFirst(prefix.count)))
        }
        return Arm(chain: chain, hand: hand, reach: reach, fingers: fingers)
    }

    private static func leg(_ side: String, index: [String: Int], solver: PoseSolver,
                            restModel: [float4x4], restLocal: [JointPose],
                            vertices: [(bone: Int, position: SIMD3<Float>)],
                            restEyeZ: Float) -> Leg? {
        guard let thigh = index["Bip01 \(side) Leg"], let shin = index["Bip01 \(side) Leg1"],
              let foot = index["Bip01 \(side) Foot"],
              let chain = solver.chain([thigh, shin, foot]) else { return nil }
        let p = [thigh, shin, foot].map { PoseSolver.translation(of: restModel[$0]) }
        // The sole: the lowest point of anything below the ankle.
        let below = Set(solver.order.filter { i in
            var j: Int? = i
            while let k = j { if k == foot { return true }; j = solver.parents[k] }
            return false
        })
        let sole = vertices.filter { below.contains($0.bone) }
            .map { (restModel[$0.bone] * SIMD4<Float>($0.position, 1)).z }.min() ?? (p[2].z - 3)
        let ankleHeight = max(p[2].z - sole, 0)
        // Standing straight must put the eyes at the game's eye height, so
        // the hip-to-ankle distance gives up exactly the difference.
        // Standing is sized to `standingExtension` of the chain rather than
        // to the rest pose's own hip-ankle distance: near full extension a
        // knee is extraordinarily sensitive — at 97% of its length a leg is
        // already bent 28° — so the one number is chosen for the knee it
        // gives, a standing person's slight flex.
        let segments = simd_distance(p[0], p[1]) + simd_distance(p[1], p[2])
        // Standing, the hip is the eye's height less the rest eye-to-hip
        // drop, and the ankle stands its own height off the floor, straight
        // below — the rest pose's slightly staggered stance does not count.
        let standingHipAnkle = AvatarRig.gameEyeHeight - (restEyeZ - p[0].z) - ankleHeight
        let compression = min(1, max(0.7, standingHipAnkle / (AvatarRig.standingExtension * segments)))
        let length = segments * compression
        func axis(_ child: Int) -> SIMD3<Float> {
            let t = restLocal[child].translation
            return simd_length(t) > 1e-4 ? simd_normalize(t) : SIMD3(1, 0, 0)
        }
        return Leg(chain: chain, thigh: thigh, shin: shin, foot: foot,
                   ankleHeight: ankleHeight, length: length, compression: compression,
                   thighAxis: axis(shin), shinAxis: axis(foot),
                   restFootRotation: PoseSolver.rotation(of: restModel[foot]), restHip: p[0])
    }

    // MARK: - What not to draw

    /// Every bone in the subtree rooted at `bone`, including `bone`.
    func subtree(of bone: Int) -> Set<Int> {
        var set: Set<Int> = [bone]
        // Parents precede children in GoldSrc bone tables, so one forward
        // pass closes the set; the loop is only insurance against a rig that
        // breaks that rule.
        var grew = true
        while grew {
            grew = false
            for i in parents.indices where !set.contains(i) {
                if let p = parents[i], set.contains(p) { set.insert(i); grew = true }
            }
        }
        return set
    }

    /// Bones whose triangles the body upload leaves out.
    ///
    /// The head always: the camera sits inside it, so drawing it means a
    /// skull's inner faces a few centimetres from each eye. The legs until
    /// they are tracked — a leg standing where the player's is not reads
    /// worse than no leg. Everything under the thigh bones goes, so the cut
    /// falls at the hips.
    func hiddenBones(legs: Bool) -> Set<Int> {
        var hidden = subtree(of: head)
        if !legs {
            for name in ["Bip01 L Leg", "Bip01 R Leg"] {
                if let i = boneNames.firstIndex(of: name) { hidden.formUnion(subtree(of: i)) }
            }
        }
        return hidden
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
        /// How far the body was stepped back to keep the torso clear of the
        /// eye, units. Zero whenever the player is not looking down.
        var stepBack: Float = 0
    }

    /// How close the torso may come to the eye, units (12 cm — outside a
    /// typical 10 cm near plane, so nothing is sliced open). A camera
    /// pitched down pivots forward and down about the neck and would
    /// otherwise end up level with the collar, and inside the chest of a
    /// player built deeper than Gordon; the rig steps the body back instead,
    /// which is what a person looking at their own feet does anyway. Level
    /// gaze keeps well clear of it: on gordon.mdl the nearest torso vertex is
    /// 20 cm off level and 12 cm at 51° down, so the step starts near 50°.
    static let eyeClearance: Float = 4.7

    /// Where the eyes sit relative to the head bone, in the rest facing
    /// (forward, left, up; GoldSrc units). Measured on gordon.mdl: the head
    /// bone is at the base of the skull and the glasses' bone sits 5.2 units
    /// forward and 3.5 up of it, so the eyes are a touch behind that.
    static let defaultEyeOffset = SIMD3<Float>(4.4, 0, 3.4)

    /// Targets for one frame, in world space (GoldSrc units, Z-up, +X the
    /// direction a yaw of zero faces).
    struct Targets {
        /// Where the player's eyes are. The rig hangs from this point, not
        /// from the head bone, so looking down pivots the skull about the
        /// neck instead of dragging the torso forward.
        var headPosition: SIMD3<Float>
        /// Which way the body faces, radians about the up axis. The caller
        /// damps this off the head's yaw — the body should follow a turn, not
        /// mirror every glance.
        var bodyYaw: Float
        var leftHand: SIMD3<Float>?
        var rightHand: SIMD3<Float>?
        /// Full head orientation, from `AvatarRig.headRotation(forward:up:)`.
        /// nil leaves the head bone at rest.
        var headRotation: simd_quatf? = nil
        /// Wrist orientations, from `AvatarRig.handRotation(forward:back:)`.
        /// nil leaves the hand in its rest orientation on the forearm.
        var leftHandRotation: simd_quatf? = nil
        var rightHandRotation: simd_quatf? = nil
        /// Tracked elbows. ARKit's hand skeleton carries the forearm, so the
        /// elbow's position is known, not guessed: the bend plane goes
        /// through it and the bend lands on its side. nil falls back to a
        /// pole that puts the elbow where elbows usually are.
        var leftElbow: SIMD3<Float>? = nil
        var rightElbow: SIMD3<Float>? = nil
        /// Finger rotations relative to the hand, keyed "Finger0",
        /// "Finger21", … — the grip a viewmodel animates around its gun (see
        /// `ViewmodelGrip.fingerPose`). nil leaves the fingers at rest.
        var leftFingers: [String: simd_quatf]? = nil
        var rightFingers: [String: simd_quatf]? = nil
        var eyeOffset: SIMD3<Float> = AvatarRig.defaultEyeOffset
    }

    /// Where a foot goes this frame, in world space.
    struct FootTarget {
        /// The sole, on the floor while planted.
        var sole: SIMD3<Float>
        /// Which way the foot points, unit, horizontal.
        var forward: SIMD3<Float>
    }

    /// Supplies the feet once the body is placed: handed the pelvis and the
    /// body's facing (world), it returns where each sole goes, or nil for
    /// legs that hang (in the air, in water). See AvatarGait.
    typealias FeetProvider = (_ hips: SIMD3<Float>, _ forward: SIMD3<Float>)
        -> (left: FootTarget, right: FootTarget)?

    /// The head's world rotation from its forward and up axes (unit, GoldSrc
    /// world). Identity faces +X and is level.
    static func headRotation(forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        let f = simd_normalize(forward)
        let l = simd_normalize(simd_cross(up, f))          // GoldSrc +Y is left
        let u = simd_cross(f, l)
        return simd_normalize(simd_quatf(simd_float3x3(f, l, u)))
    }

    /// A wrist's world rotation from the direction the fingers point and the
    /// normal out of the back of the hand (unit, GoldSrc world). Same call
    /// for both hands.
    ///
    /// Bip01 hands put X along the fingers, +Y out of the palm and Z across
    /// the palm — toward the thumb on the right hand, away from it on the
    /// left — measured on the rest pose rather than assumed. Those two
    /// mirrored conventions collapse to one right-handed frame: X = fingers,
    /// Y = −back, Z = back × fingers.
    static func handRotation(forward: SIMD3<Float>, back: SIMD3<Float>) -> simd_quatf {
        let f = simd_normalize(forward)
        let z = simd_normalize(simd_cross(back, f))
        let y = simd_cross(z, f)                            // = −back, re-orthogonalised
        return simd_normalize(simd_quatf(simd_float3x3(f, y, z)))
    }

    /// Places the avatar under the tracked head and bends both arms to the
    /// tracked hands.
    ///
    /// The placement is deliberately not "parent the body to the head". A head
    /// anchor carries pitch and roll, and a body rigidly hung from it would
    /// swing bodily every time the player looked down at their feet. Instead
    /// the head bone takes the tracked orientation, the root is positioned so
    /// the *eyes* of that turned head land at the tracked position, and the
    /// root is rotated by yaw alone; the body then hangs below a head that
    /// can look anywhere without dragging the torso with it.
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

    /// Iterations per leg. The legs start near straight and bend mostly in
    /// one plane, where FABRIK converges fast.
    static let legIterations = 16

    /// How much of its length a standing leg uses: 99.6%, a knee bent ~10°.
    static let standingExtension: Float = 0.996
    /// The solver's reach limit for a leg. The arms keep RAVERig's 98% —
    /// an arm held that straight reads as locked — but a leg that may not
    /// straighten past 98% stands with its knees bent 23°.
    static let legReachLimit: Float = 0.999

    /// Poses the body with the legs at rest — what a body drawn without legs
    /// wants.
    func pose(_ targets: Targets, iterations: Int = AvatarRig.armIterations) -> Pose {
        solve(targets, iterations: iterations, drivesLegs: false) { _, _ in nil }
    }

    /// Poses the body and drives the legs from `feet`: they are compressed
    /// to the game's eye height (`gameEyeHeight`) and solved to the soles it
    /// returns, or left to hang when it returns nil.
    func pose(_ targets: Targets, iterations: Int = AvatarRig.armIterations,
              feet: FeetProvider) -> Pose {
        solve(targets, iterations: iterations, drivesLegs: true, feet: feet)
    }

    private func solve(_ targets: Targets, iterations: Int, drivesLegs: Bool,
                       feet: FeetProvider) -> Pose {
        let yaw = simd_quatf(angle: targets.bodyYaw, axis: AvatarRig.up)
        let worldToModelRotation = yaw.inverse

        var joints = restLocal
        var model = solver.modelMatrices(of: joints)

        // Head first, because the eyes hang off it and the root hangs off
        // the eyes. The tracked rotation is relative to "facing +X, level",
        // which is what the rest head does, so it composes onto the rest
        // orientation directly once brought into model space.
        let restHead = PoseSolver.rotation(of: restModel[head])
        if let tracked = targets.headRotation {
            let delta = worldToModelRotation * tracked
            setModelRotation(of: head, to: simd_normalize(delta * restHead), joints: &joints, model: &model)
        }

        let eyeLocal = restHead.inverse.act(targets.eyeOffset)
        let eyeModel = (model[head] * SIMD4<Float>(eyeLocal, 1)).xyz
        var root = float4x4(yaw)
        root.columns.3 = SIMD4<Float>(targets.headPosition - yaw.act(eyeModel), 1)
        let stepBack = clearance(root: root, model: model, eye: targets.headPosition,
                                 forward: yaw.act(SIMD3<Float>(1, 0, 0)))
        root.columns.3 -= SIMD4<Float>(yaw.act(SIMD3<Float>(stepBack, 0, 0)), 0)
        let toModel = root.inverse

        // The pole is the side the elbow bends toward, and it has to be a
        // direction the arm is rarely asked to point along, or the bend plane
        // is ill-defined exactly when it matters. Mostly down, since an
        // elbow hangs; a little back, so an arm hanging straight down still
        // has a plane and bends backward as elbows do; a little outward, so
        // a hand held in front puts its elbow down-and-out rather than
        // pinned under the wrist. An earlier mostly-back pole was nearly
        // anti-parallel to any hand held forward, and a hand raised to the
        // face got its elbow up behind the shoulder. The body's own axes
        // rather than world constants, so it holds when the player turns.
        let back = yaw.act(SIMD3<Float>(-1, 0, 0))
        let leftward = yaw.act(SIMD3<Float>(0, 1, 0))
        func pole(side: Float) -> SIMD3<Float> {
            simd_normalize(-AvatarRig.up + back * 0.5 + leftward * (0.3 * side))
        }

        // An untracked hand hangs by the side instead of holding whatever
        // sequence 0 froze it in (the right arm raised, as it happens). The
        // target is in model space — a little forward and out from the
        // shoulder, most of the arm's length down — with the palm inward.
        func relaxed(_ arm: Arm, side: Float) -> (target: SIMD3<Float>, rotation: simd_quatf) {
            let shoulder = PoseSolver.translation(of: model[arm.chain.joints[0]])
            let target = shoulder + SIMD3<Float>(3, 2 * side, -arm.reach * 0.88)
            let rotation = AvatarRig.handRotation(forward: SIMD3<Float>(0.1, 0, -1),
                                                  back: SIMD3<Float>(0, side, 0))
            return (target, rotation)
        }

        func solve(_ arm: Arm?, _ worldTarget: SIMD3<Float>?, _ worldRotation: simd_quatf?,
                   _ worldElbow: SIMD3<Float>?, _ fingers: [String: simd_quatf]?,
                   side: Float) -> PoseSolver.Report? {
            guard let arm else { return nil }
            let target: SIMD3<Float>
            let rotation: simd_quatf?
            if let worldTarget {
                target = (toModel * SIMD4<Float>(worldTarget, 1)).xyz
                rotation = worldRotation.map { worldToModelRotation * $0 }
            } else {
                (target, rotation) = relaxed(arm, side: side)
            }
            // The pole: shoulder → tracked elbow when there is one, so the
            // bend plane holds the real elbow and the bend lands on its side
            // (the solver drops the component along the shoulder–hand line
            // itself). Otherwise the synthetic down-back-out direction.
            var poleModel = (toModel * SIMD4<Float>(pole(side: side), 0)).xyz
            if worldTarget != nil, let worldElbow {
                let shoulder = PoseSolver.translation(of: model[arm.chain.joints[0]])
                let toElbow = (toModel * SIMD4<Float>(worldElbow, 1)).xyz - shoulder
                if simd_length(toElbow) > 1e-3 { poleModel = simd_normalize(toElbow) }
            }
            // bendTowardPole: the seed is one frozen frame of sequence 0,
            // whose elbows sit wherever that frame left them (the right one
            // raised). Only the pole knows which side the bend belongs on.
            let report = solver.solve(chain: arm.chain, target: target,
                                      pole: poleModel,
                                      bendTowardPole: true,
                                      iterations: iterations,
                                      pose: &joints, model: &model)
            // The wrist takes the tracked orientation outright. FABRIK only
            // decides where the hand is; which way it faces is the tracker's
            // call, and the fingers ride along as children.
            if let rotation {
                setModelRotation(of: arm.hand, to: rotation, joints: &joints, model: &model)
            }
            if let fingers { curl(arm, fingers, joints: &joints, model: &model) }
            return report
        }
        let left = solve(leftArm, targets.leftHand, targets.leftHandRotation, targets.leftElbow,
                         targets.leftFingers, side: 1)
        let right = solve(rightArm, targets.rightHand, targets.rightHandRotation, targets.rightElbow,
                          targets.rightFingers, side: -1)

        var compressed: [Leg] = []
        if drivesLegs {
            compressed = [leftLeg, rightLeg].compactMap { $0 }
            for leg in compressed {
                joints[leg.shin].translation *= leg.compression
                joints[leg.foot].translation *= leg.compression
            }
            model = solver.modelMatrices(of: joints)
            let hips = PoseSolver.translation(of: root * model[pelvis])
            let forward = yaw.act(SIMD3<Float>(1, 0, 0))
            let placed = feet(hips, forward)
            for (leg, target, side) in [(leftLeg, placed?.left, Float(1)), (rightLeg, placed?.right, Float(-1))] {
                guard let leg else { continue }
                solveLeg(leg, target, side: side, yaw: yaw, root: root, toModel: toModel,
                         joints: &joints, model: &model)
            }
        }

        // The chains wrote their own matrices as they went, but joints hanging
        // off them — the fingers below each hand — are stale. One clean pass
        // is cheaper than reasoning about which ones moved.
        var palette = solver.modelMatrices(of: joints)
        // A compressed leg's bones sit closer together; squash the thigh and
        // shin meshes along their length to match, or they would overlap at
        // the knee and poke out below it. Rigid skinning puts each vertex on
        // exactly one bone, so a per-bone scale is all it takes.
        for leg in compressed {
            palette[leg.thigh] = palette[leg.thigh] * AvatarRig.squash(leg.thighAxis, leg.compression)
            palette[leg.shin] = palette[leg.shin] * AvatarRig.squash(leg.shinAxis, leg.compression)
        }
        return Pose(palette: palette, root: root,
                    left: left, right: right, stepBack: stepBack)
    }

    /// A scale by `k` along the unit `axis` and none across it.
    static func squash(_ axis: SIMD3<Float>, _ k: Float) -> float4x4 {
        let a = axis
        let m = simd_float3x3(diagonal: SIMD3<Float>(repeating: 1))
            + (k - 1) * simd_float3x3(columns: (a * a.x, a * a.y, a * a.z))
        return float4x4(columns: (SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0),
                                  SIMD4(m.columns.2, 0), SIMD4(0, 0, 0, 1)))
    }

    /// Puts one leg's ankle over its sole, knee toward where the foot points,
    /// and the foot flat on the floor facing that way. A nil target hangs
    /// the leg: nearly straight below the hip, knee a little forward, as legs
    /// hang in a jump.
    private func solveLeg(_ leg: Leg, _ target: FootTarget?, side: Float, yaw: simd_quatf,
                          root: float4x4, toModel: float4x4,
                          joints: inout [JointPose], model: inout [float4x4]) {
        let worldToModel = yaw.inverse
        let hip = PoseSolver.translation(of: model[leg.thigh])
        let ankle: SIMD3<Float>
        let footForward: SIMD3<Float>
        if let target {
            let a = target.sole + AvatarRig.up * leg.ankleHeight
            ankle = (toModel * SIMD4<Float>(a, 1)).xyz
            footForward = worldToModel.act(target.forward)
        } else {
            ankle = hip + SIMD3<Float>(3, 0, -leg.length * 0.94)
            footForward = SIMD3(1, 0, 0)
        }
        // Knees go the way the foot points, a touch outward — the direction
        // a leg is never asked to reach along, so the bend plane holds.
        let pole = simd_normalize(footForward + SIMD3<Float>(0, 0.25 * side, 0))
        _ = solver.solve(chain: leg.chain, target: ankle, pole: pole, bendTowardPole: true,
                         iterations: AvatarRig.legIterations, reachLimit: AvatarRig.legReachLimit,
                         pose: &joints, model: &model)
        // The foot lies flat, turned to its heading: its rest orientation
        // (flat, facing +X) yawed onto the heading.
        let heading = atan2f(footForward.y, footForward.x)
        let turn = simd_quatf(angle: heading, axis: AvatarRig.up)
        setModelRotation(of: leg.foot, to: simd_normalize(turn * leg.restFootRotation),
                         joints: &joints, model: &model)
    }

    /// How far back along `forward` the body must move so no torso vertex is
    /// nearer the eye than `eyeClearance`.
    ///
    /// Per vertex this is exact: moving the body back by δ puts the vertex at
    /// d − δ·f from the eye, which leaves the clearance sphere at
    /// δ = d·f + √(r² − |d⊥|²), and a vertex whose |d⊥| is already r or more
    /// never enters it. The largest δ over the torso is the step. Only ever
    /// backward: forward is where the player is looking, and the body should
    /// yield out of the view, not into it.
    private func clearance(root: float4x4, model: [float4x4], eye: SIMD3<Float>,
                           forward f: SIMD3<Float>) -> Float {
        let r2 = AvatarRig.eyeClearance * AvatarRig.eyeClearance
        var step: Float = 0
        for (bone, local) in clearanceVertices where bone < model.count {
            let w = root * model[bone] * SIMD4<Float>(local, 1)
            let d = SIMD3<Float>(w.x, w.y, w.z) - eye
            let along = simd_dot(d, f)
            let across2 = simd_length_squared(d) - along * along
            guard across2 < r2 else { continue }
            step = max(step, along + (r2 - across2).squareRoot())
        }
        return step
    }

    /// Poses a hand's fingers from rotations relative to the hand.
    ///
    /// Only rotations transfer: each finger keeps this rig's own bone
    /// lengths, so a pose taken off a viewmodel's longer fingers still closes
    /// this hand's own fist rather than stretching it. A four-finger pose on
    /// a mitten — which every GoldSrc player model's hand is — drives the
    /// mitten with the middle finger, the one that best stands for the other
    /// three wrapped around a grip (the index is on the trigger).
    private func curl(_ arm: Arm, _ pose: [String: simd_quatf],
                      joints: inout [JointPose], model: inout [float4x4]) {
        let mitten = !arm.fingers.contains { $0.key.hasPrefix("Finger2") }
        let hand = PoseSolver.rotation(of: model[arm.hand])
        for (bone, key) in arm.fingers {
            let source = mitten && key.hasPrefix("Finger1") ? "Finger2" + key.dropFirst("Finger1".count) : key
            guard let q = pose[source] ?? pose[key] else { continue }
            setModelRotation(of: bone, to: simd_normalize(hand * q), joints: &joints, model: &model)
        }
    }

    /// The world transform of a posed hand bone (GoldSrc units): the frame a
    /// held gun is pinned to.
    func handMatrix(_ pose: Pose, left: Bool) -> float4x4? {
        guard let arm = left ? leftArm : rightArm, arm.hand < pose.palette.count else { return nil }
        return pose.root * pose.palette[arm.hand]
    }

    /// Gives `bone` the model-space rotation `rotation` by rewriting its
    /// local rotation against its parent's *current* model matrix, then
    /// refreshes `model` for the bone and everything below it.
    private func setModelRotation(of bone: Int, to rotation: simd_quatf,
                                  joints: inout [JointPose], model: inout [float4x4]) {
        let parentRotation: simd_quatf
        if let p = parents[bone] { parentRotation = PoseSolver.rotation(of: model[p]) }
        else { parentRotation = simd_quatf(angle: 0, axis: AvatarRig.up) }
        joints[bone].rotation = simd_normalize(parentRotation.inverse * rotation)
        let below = subtree(of: bone)
        for i in solver.order where below.contains(i) {
            let local = joints[i].matrix
            model[i] = parents[i].map { model[$0] * local } ?? local
        }
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

// MARK: - Gait

/// The feet's memory: where each is planted, carried from frame to frame.
///
/// AvatarRig is a pure function of one frame's tracking; feet are not — a
/// planted foot is where it was last frame. This holds RAVERig's
/// FootPlanter and feeds it from the game.
///
/// The feet stand in the *game* world, not the room. When the thumbstick
/// carries the player forward, the room — and the body in it — stays put
/// while the world slides past, so a foot planted in the room would glide
/// with the player. The planter is instead run in a frame that the game's
/// own velocity carries along: `travelled` is how far the world has moved
/// under the player, a planted foot holds still in that frame, and in the
/// room it slides backward as it should, until the stance has left it far
/// enough behind to take a step. Walking on the spot in the room steps the
/// same way, because there it is the hips that move.
struct AvatarGait {
    private var planter: FootPlanter
    private let legLength: Float
    private let ankleHeight: Float
    /// Where the game world has carried the player since the gait began,
    /// room space (GoldSrc axes, units). Horizontal only.
    private var travelled = SIMD3<Float>.zero
    private var wasGrounded = false

    init(rig: AvatarRig) {
        let leg = rig.leftLeg ?? rig.rightLeg
        legLength = leg?.length ?? 31
        ankleHeight = leg?.ankleHeight ?? 3.8
        planter = FootPlanter.forLeg(length: legLength, hipWidth: rig.hipHalfWidth * 2)
    }

    /// What the game says about the player's feet this frame.
    struct Ground {
        /// Height of the floor under the player, room space (GoldSrc Z).
        var floor: Float
        /// Standing on something and not swimming.
        var grounded: Bool
        /// The player's velocity through the game world, rotated into room
        /// space (GoldSrc axes), units/s.
        var velocity: SIMD3<Float>
        var deltaTime: Float
    }

    /// The feet for one frame, as AvatarRig.pose's `feet` wants them.
    mutating func feet(hips: SIMD3<Float>, forward: SIMD3<Float>, ground: Ground)
        -> (left: AvatarRig.FootTarget, right: AvatarRig.FootTarget)? {
        guard ground.grounded else {
            // In the air the legs hang; on landing the feet plant where they
            // come down rather than where they took off.
            wasGrounded = false
            return nil
        }
        if !wasGrounded { planter.reset(); wasGrounded = true }

        travelled += SIMD3(ground.velocity.x, ground.velocity.y, 0) * ground.deltaTime
        // Crouching folds the hips back over the heels, so the stance moves
        // forward of the pelvis as it drops — standing straight it is right
        // underneath.
        let standing = legLength * AvatarRig.standingExtension + ankleHeight
        let crouch = max(0, standing - (hips.z - ground.floor))
        let stanceHips = hips + simd_normalize(SIMD3(forward.x, forward.y, 0)) * min(crouch * 0.35, legLength * 0.25)

        let anchored = stanceHips + travelled
        let floor = ground.floor
        let placed = planter.update(hips: AvatarGait.yUp(anchored), forward: AvatarGait.yUp(forward),
                                    velocity: AvatarGait.yUp(ground.velocity), deltaTime: ground.deltaTime,
                                    floor: { _ in floor })
        func target(_ p: FootPlanter.Placement) -> AvatarRig.FootTarget {
            let sole = AvatarGait.zUp(p.position) - travelled
            return AvatarRig.FootTarget(sole: sole, forward: AvatarGait.zUp(p.forward))
        }
        return (target(placed.left), target(placed.right))
    }

    /// GoldSrc (X forward, Y left, Z up) → the planter's Y-up frame, and
    /// back. A cyclic permutation, so handedness survives: GoldSrc forward
    /// becomes the planter's +Z and GoldSrc left its +X, which is the side
    /// it puts the left foot on.
    static func yUp(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.y, v.z, v.x) }
    static func zUp(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.z, v.x, v.y) }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
