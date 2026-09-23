//
//  ViewmodelGrip.swift
//  LambdaVision
//
//  What of a v_ viewmodel is the gun and what is Valve's pair of HEV hands,
//  and where on the gun a hand holds it.
//
//  With the first-person body drawn, the player already has hands — the
//  avatar's, driven by tracking. The viewmodel's own hands then only get in
//  the way: its right glove sits inside the avatar's, its left hand floats
//  wherever the animation put it, and its sleeve ends mid-forearm tracking
//  nothing. So they are cut out at upload, the gun is pinned into the
//  avatar's hand by the viewmodel's own grip bone, and the avatar's fingers
//  borrow the grip Valve animated around that gun.
//
//  No Metal, no engine: plain values in, plain values out, so the probe runs
//  every rule here against the real models on the Mac.
//

import RAVERig
import simd

enum ViewmodelGrip {

    // MARK: - Which triangles are hands

    /// Whether a studio texture is one Valve draws hands and sleeves with.
    ///
    /// Bones cannot separate hand from gun: stock viewmodels skin the pistol
    /// slide, the crowbar and the shotgun receiver straight to `Bip01 R Hand`.
    /// Textures can — every stock hand is drawn with the same small family
    /// (`rubbergloveCHROME`, `GLOVED_knuckle`, `GLOVE_handpak`,
    /// `GLOVED_sleeve`, `xbow_sleeve`, `HAND_ForeArm1`, the MP5's `PLAYER_*`
    /// set, and the HD pack's `gordon_glove` / `gordon_sleeve`), and no gun
    /// texture uses those words.
    static func isHandTexture(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("player_")
            || ["glove", "sleeve", "forearm", "cuff", "handpak", "knuckle"].contains { n.contains($0) }
    }

    /// Whether a bone belongs to an arm: clavicle, upper arm, forearm, hand
    /// or finger, whatever the rig's prefix or naming (`Bip01 L Arm1`,
    /// `Xbow biped R Hand`, and the HD pack's `Bip01 L UpperArm`,
    /// `Bip01 L Forearm` and `L_Arm_bone`, which carries its sleeve).
    ///
    /// Judged by whole name tokens, split on spaces and underscores, not by
    /// substring: the crossbow's bow limbs are `LeftArm`/`RightArm`, and are
    /// drawn with the glove texture too.
    static func isArmBone(_ name: String) -> Bool {
        let tokens = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" })
        return tokens.contains { t in
            ["arm", "arm1", "arm2", "upperarm", "forearm", "hand", "clavicle"].contains(String(t))
                || t.hasPrefix("finger")
        }
    }

    /// A predicate for StudioMesh: true for a triangle that is part of the
    /// viewmodel's hands.
    ///
    /// A hand texture alone is not enough. The crossbow draws its bow limbs
    /// and string with `rubbergloveCHROME`, and the satchel radio its aerial,
    /// both skinned to weapon bones — so on a rig that has arm bones at all, a
    /// glove-textured triangle is only a hand when it sits on one. Rigs with
    /// no named arm bones (the MP5's `Bone01…`) are judged by texture alone,
    /// which on those models is exactly right.
    static func handTriangleFilter(textureNames: [String], boneNames: [String])
        -> (_ texture: Int, _ a: Int, _ b: Int, _ c: Int) -> Bool {
        let handTextures = Set(textureNames.indices.filter { isHandTexture(textureNames[$0]) })
        let armBones = Set(boneNames.indices.filter { isArmBone(boneNames[$0]) })
        let byTextureAlone = armBones.isEmpty
        return { texture, a, b, c in
            guard handTextures.contains(texture) else { return false }
            return byTextureAlone || armBones.contains(a) || armBones.contains(b) || armBones.contains(c)
        }
    }

    // MARK: - Where the gun is held

    /// The bone the gun is held by, and how to read it as a Bip01 hand.
    struct Grip: Equatable {
        /// Palette index of the gripping bone.
        var bone: Int
        /// Bone-local → hand frame. Identity for a Bip01 hand; for a rig
        /// without one it turns the synthesised frame into the Bip01
        /// convention (X along the fingers, +Y out of the palm, Z = X × Y).
        var fixup: float4x4
        /// The viewmodel holds the gun in its left hand (the satchel does).
        var isLeft: Bool
        /// The hand's name prefix ("Bip01 R "), for reading its fingers;
        /// nil for a synthesised grip, whose fingers have no names.
        var fingerPrefix: String?

        /// The hand frame in the viewmodel's model space for a pose.
        func frame(in palette: [float4x4]) -> float4x4 {
            (bone < palette.count ? palette[bone] : matrix_identity_float4x4) * fixup
        }
    }

    /// Finds the grip. `extractorChoice` is the extractor's own pick (the
    /// hand carrying the most geometry, or -1), which is trusted whenever it
    /// names a real hand; otherwise a hand is synthesised from the skeleton.
    ///
    /// The synthesised case exists for the MP5, whose unnamed rig
    /// (`Bone01…Bone33`) left the gun hanging off the camera origin: its right
    /// hand is still recognisable as the bone that the gloved finger chains
    /// leave from. The frame is built the way a Bip01 hand is laid out — X
    /// toward the fingers, Z toward the thumb on a right hand — and the probe
    /// checks that construction against every real Bip01 hand it can find.
    ///
    /// `geometry` is, per bone, how many hand-textured and how many other
    /// vertices it carries (see `boneGeometry`). A child only counts as a
    /// finger when its subtree is mostly glove: hands have gun parts hanging
    /// off them too — the Glock's slide under `Bip01 R Hand`, the whole MP5
    /// under its right hand — and taking one of those for the thumb turns the
    /// frame a quarter turn.
    static func grip(boneNames: [String], parents: [Int?], pose: [float4x4],
                     extractorChoice: Int, geometry: [(hand: Int, other: Int)]) -> Grip? {
        if extractorChoice >= 0, extractorChoice < boneNames.count,
           boneNames[extractorChoice].hasSuffix(" Hand") {
            let name = boneNames[extractorChoice]
            return Grip(bone: extractorChoice, fixup: matrix_identity_float4x4,
                        isLeft: name.hasSuffix(" L Hand"),
                        fingerPrefix: String(name.dropLast("Hand".count)))
        }
        // A hand is a bone with at least four finger chains; of those, the
        // right hand is the one furthest to the model's right (-Y, the
        // viewmodel being authored in view space).
        let fingers = fingerChains(parents: parents, geometry: geometry)
        let hands = boneNames.indices.filter { fingers[$0].count >= 4 && $0 < pose.count }
        guard let hand = hands.min(by: { pose[$0].columns.3.y < pose[$1].columns.3.y }),
              let frame = synthesisedHandFrame(hand: hand, fingers: fingers[hand], pose: pose,
                                               isLeft: pose[hand].columns.3.y > 0)
        else { return nil }
        return Grip(bone: hand, fixup: pose[hand].inverse * frame,
                    isLeft: pose[hand].columns.3.y > 0, fingerPrefix: nil)
    }

    /// Per bone, the children whose subtrees are mostly hand geometry — the
    /// candidate fingers.
    static func fingerChains(parents: [Int?], geometry: [(hand: Int, other: Int)]) -> [[Int]] {
        var children = [[Int]](repeating: [], count: parents.count)
        for (i, p) in parents.enumerated() { if let p, p < children.count { children[p].append(i) } }
        func total(_ bone: Int) -> (hand: Int, other: Int) {
            var t: (hand: Int, other: Int) = bone < geometry.count ? geometry[bone] : (0, 0)
            for c in children[bone] { let s = total(c); t.hand += s.hand; t.other += s.other }
            return t
        }
        return children.map { kids in
            kids.filter { let t = total($0); return t.hand > 0 && t.hand > t.other }
        }
    }

    /// How many hand-textured and other vertices each bone carries, from
    /// (texture, bone) per vertex of each triangle.
    static func boneGeometry(boneCount: Int, textureNames: [String],
                             vertices: [(texture: Int, bone: Int)]) -> [(hand: Int, other: Int)] {
        var out = [(hand: Int, other: Int)](repeating: (0, 0), count: boneCount)
        for (texture, bone) in vertices where bone < boneCount {
            if texture < textureNames.count, isHandTexture(textureNames[texture]) { out[bone].hand += 1 }
            else { out[bone].other += 1 }
        }
        return out
    }

    /// A Bip01-convention frame for a hand from where its finger chains start:
    /// X toward their mean, Z toward the thumb (the chain furthest from that
    /// mean) on a right hand and away from it on a left one.
    static func synthesisedHandFrame(hand: Int, fingers: [Int], pose: [float4x4],
                                     isLeft: Bool) -> float4x4? {
        let origin = xyz(pose[hand].columns.3)
        let dirs = fingers.compactMap { f -> SIMD3<Float>? in
            let d = xyz(pose[f].columns.3) - origin
            return simd_length(d) > 1e-3 ? simd_normalize(d) : nil
        }
        guard dirs.count >= 4 else { return nil }
        let x = simd_normalize(dirs.reduce(.zero, +))
        guard let thumb = dirs.min(by: { simd_dot($0, x) < simd_dot($1, x) }) else { return nil }
        var z = thumb - x * simd_dot(thumb, x)
        guard simd_length(z) > 1e-3 else { return nil }
        z = simd_normalize(z) * (isLeft ? -1 : 1)
        let y = simd_cross(z, x)
        return float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1)))
    }

    // MARK: - Placing the gun

    /// Reflects a hand frame across its own XY plane — fingers and palm stay,
    /// thumb side flips — which is how a right hand's grip becomes a left
    /// hand's. Needed when the gun goes into the other hand from the one
    /// Valve animated it in: the dominant-hand setting, or the satchel.
    static let mirror = float4x4(diagonal: SIMD4<Float>(1, 1, -1, 1))

    /// How a viewmodel is carried.
    enum Hold: Equatable {
        /// A gun: its barrel is the viewmodel's +X, so it is laid along the
        /// hand's pointing direction, upright on the thumb side.
        case aimed
        /// A held object (grenade, satchel, tripmine): placed exactly as
        /// Valve's hand held it, because it has no barrel to line up.
        case held
    }

    /// The largest angle between the idle barrel and the grip hand's fingers
    /// for which a viewmodel is still a gun. Every stock and HD gun reads
    /// 2–21°; the hand grenade, satchel and tripmine read 40–75°.
    static let aimedHoldLimitDeg: Float = 30

    static func hold(grip: Grip, idlePalette: [float4x4]) -> Hold {
        let b = barrelInGrip(grip: grip, idlePalette: idlePalette)
        return acosf(max(-1, min(1, b.x))) * 180 / .pi <= aimedHoldLimitDeg ? .aimed : .held
    }

    /// Viewmodel model space → the world, given where the holding hand is.
    ///
    /// `hand` is a Bip01-convention hand frame in the world (the avatar's
    /// posed hand bone, or one built from tracking) in GoldSrc units — the
    /// caller composes the GoldSrc → Apple basis on the outside.
    ///
    /// A held object pins the grip bone to the hand exactly, the way Valve
    /// animated it. An aimed gun takes its orientation from the viewmodel's
    /// own axes instead: viewmodels are authored in view space, so in the
    /// idle pose +X is where the gun shoots and +Z is up, on every rig —
    /// unlike the grip bone, whose frame differs per model (the classic MP5
    /// has no named hand at all, and its synthesised frame sat the gun 17°
    /// high and rolled). Those axes go onto the hand's (+X along the
    /// fingers, +Z the thumb side, which a Bip01 hand shares), and the grip
    /// bone only says where: its idle position lands on the hand, and its
    /// motion since idle is taken back out, so recoil, the pump and the
    /// magazine animate around a hand that does not move.
    ///
    /// `yawCorrection` (radians, aimed only) turns the gun about the hand's
    /// up axis to take out Valve's toe-in (ViewmodelAlignment).
    static func modelMatrix(hand: float4x4, grip: Grip, hold: Hold, palette: [float4x4],
                            idlePalette: [float4x4], handIsLeft: Bool,
                            yawCorrection: Float = 0) -> float4x4 {
        let flip = grip.isLeft != handIsLeft ? mirror : matrix_identity_float4x4
        switch hold {
        case .held:
            return hand * flip * grip.frame(in: palette).inverse
        case .aimed:
            let idle = bone(grip.bone, in: idlePalette)
            var toGrip = matrix_identity_float4x4
            toGrip.columns.3 = SIMD4(-xyz(idle.columns.3), 1)
            return hand * flip * yaw(yawCorrection) * toGrip * idle * bone(grip.bone, in: palette).inverse
        }
    }

    /// The barrel, as a direction in the holding hand's frame: along the
    /// fingers for an aimed gun, by construction, and for a held object
    /// wherever Valve's hand pointed its +X.
    ///
    /// Taken from idle, not from the current frame: the shoot sequence kicks
    /// the gun against the camera origin, and letting that into the aim
    /// would walk automatic fire up.
    static func barrel(grip: Grip, hold: Hold, idlePalette: [float4x4], handIsLeft: Bool) -> SIMD3<Float> {
        switch hold {
        case .aimed: return SIMD3(1, 0, 0)
        case .held:
            let flip = grip.isLeft != handIsLeft ? mirror : matrix_identity_float4x4
            return simd_normalize(xyz(flip * SIMD4(barrelInGrip(grip: grip, idlePalette: idlePalette), 0)))
        }
    }

    /// Model +X in the grip hand's idle frame: how far Valve's hand points
    /// away from the gun.
    static func barrelInGrip(grip: Grip, idlePalette: [float4x4]) -> SIMD3<Float> {
        simd_normalize(xyz(grip.frame(in: idlePalette).inverse * SIMD4<Float>(1, 0, 0, 0)))
    }

    /// Where the muzzle is, in the viewmodel's idle model space.
    ///
    /// Attachment 0 when the model has one — stock viewmodels put the muzzle
    /// flash there. Otherwise (the crossbow, the RPG) the front of the gun:
    /// the centre of the gun geometry within an inch of its furthest-forward
    /// point. `gunPoints` are the gun's vertices (no hands) posed in idle.
    static func muzzle(attachment: (bone: Int, org: SIMD3<Float>)?, idlePalette: [float4x4],
                       gunPoints: [SIMD3<Float>]) -> SIMD3<Float>? {
        if let a = attachment, a.bone < idlePalette.count {
            return xyz(idlePalette[a.bone] * SIMD4(a.org, 1))
        }
        guard let front = gunPoints.map(\.x).max() else { return nil }
        let tip = gunPoints.filter { $0.x > front - 1 }
        return tip.reduce(.zero, +) / Float(tip.count)
    }

    /// The muzzle in the holding hand's frame, for an aimed gun: where shots
    /// leave from, fixed per model (the idle pose, like the barrel).
    static func muzzleInHand(_ muzzle: SIMD3<Float>, grip: Grip, idlePalette: [float4x4],
                             handIsLeft: Bool, yawCorrection: Float = 0) -> SIMD3<Float> {
        let flip = grip.isLeft != handIsLeft ? mirror : matrix_identity_float4x4
        let g = xyz(bone(grip.bone, in: idlePalette).columns.3)
        return xyz(flip * yaw(yawCorrection) * SIMD4(muzzle - g, 0))
    }

    /// A turn about the hand's up (+Z, the thumb side). Commutes with
    /// `mirror`, so a left hand takes the same correction.
    private static func yaw(_ radians: Float) -> float4x4 {
        radians == 0 ? matrix_identity_float4x4 : float4x4(simd_quatf(angle: radians, axis: SIMD3(0, 0, 1)))
    }

    private static func bone(_ i: Int, in palette: [float4x4]) -> float4x4 {
        i < palette.count ? palette[i] : matrix_identity_float4x4
    }

    // MARK: - World models

    /// A weapon's third-person (p_) model, laid out so it is placed exactly
    /// like a viewmodel: `palette` poses it into its own right hand's frame,
    /// turned so an aimed gun's barrel is +X, and `grip` is that hand.
    struct WorldLayout {
        var palette: [float4x4]
        var grip: Grip
        var hold: Hold
        var muzzle: SIMD3<Float>?
    }

    /// Lays out a p_ model from its rest pose and its posed vertices (model
    /// space, GoldSrc units), or nil when it has no right hand to be held by
    /// (the egon hangs off the forearm, its backpack off the spine).
    ///
    /// p_ models are rigged to the player's skeleton, gun skinned under
    /// `Bip01 R Hand`, and nothing in them marks the barrel. The gun's long
    /// axis does: every stock and HD long gun lies within 3–10° of the hand's
    /// fingers in its third-person grip, and the pistols within 25° (the
    /// grip's rake). A gun is turned about the hand onto that axis, so it
    /// points where the fingers do, as a viewmodel's barrel is laid; a held
    /// object — crowbar, grenade, satchel, tripmine, snarks, all 65–90° off —
    /// keeps the third-person grip as authored.
    static func worldLayout(boneNames: [String], restPose: [float4x4],
                            points: [SIMD3<Float>]) -> WorldLayout? {
        guard let hand = boneNames.firstIndex(where: { $0.hasSuffix(" R Hand") }),
              hand < restPose.count, points.count >= 3 else { return nil }
        let toHand = restPose[hand].inverse
        let local = points.map { xyz(toHand * SIMD4($0, 1)) }
        let mean = local.reduce(.zero, +) / Float(local.count)
        var cov = simd_float3x3()
        for p in local { let d = p - mean; cov += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z)) }
        var axis = SIMD3<Float>(1, 0, 0)
        for _ in 0..<64 {
            let next = cov * axis
            guard simd_length(next) > 1e-9 else { break }
            axis = simd_normalize(next)
        }
        if axis.x < 0 { axis = -axis }
        let aimed = acosf(min(1, axis.x)) * 180 / .pi <= aimedHoldLimitDeg
        let turn = aimed ? float4x4(simd_quatf(from: axis, to: SIMD3(1, 0, 0))) : matrix_identity_float4x4
        let palette = restPose.map { turn * toHand * $0 }
        let aligned = local.map { xyz(turn * SIMD4($0, 1)) }
        return WorldLayout(palette: palette,
                           grip: Grip(bone: hand, fixup: matrix_identity_float4x4, isLeft: false,
                                      fingerPrefix: nil),
                           hold: aimed ? .aimed : .held,
                           muzzle: aimed ? muzzle(attachment: nil, idlePalette: palette, gunPoints: aligned) : nil)
    }

    // MARK: - The grip's fingers

    /// Each finger bone of the gripping hand, as a rotation relative to the
    /// hand, keyed by its name after the hand's prefix ("Finger0",
    /// "Finger21", …). Mirrored when the gun is in the other hand, so a left
    /// avatar hand curls the way the right Valve hand did.
    static func fingerPose(boneNames: [String], palette: [float4x4], grip: Grip,
                           handIsLeft: Bool) -> [String: simd_quatf] {
        guard let prefix = grip.fingerPrefix else { return [:] }
        let handRotation = PoseSolver.rotation(of: grip.frame(in: palette))
        let flip = grip.isLeft != handIsLeft
        var out: [String: simd_quatf] = [:]
        for (i, name) in boneNames.enumerated() where i < palette.count && name.hasPrefix(prefix + "Finger") {
            var q = simd_normalize(handRotation.inverse * PoseSolver.rotation(of: palette[i]))
            // Conjugating a rotation by the Z mirror negates its X and Y
            // components; the result is again a proper rotation.
            if flip { q = simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: q.imag.z, r: q.real) }
            out[String(name.dropFirst(prefix.count))] = q
        }
        return out
    }

    private static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
}
