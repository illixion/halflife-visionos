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
    ///
    /// The expansions' hands are named by whole texture name instead: Opposing
    /// Force's `hand` / `skin` / `fatigues`, its HD pack's `soldier_hand`, and
    /// Blue Shift's `barney_hand` (its `sleeve` already matches). Never a
    /// substring — `handle` and `v_9mmhandgun`'s textures are gun.
    static func isHandTexture(_ name: String) -> Bool {
        let n = name.lowercased()
        let stem = n.split(separator: ".").first.map(String.init) ?? n
        return n.hasPrefix("player_")
            || ["glove", "sleeve", "forearm", "cuff", "handpak", "knuckle"].contains { n.contains($0) }
            || ["hand", "skin", "fatigues"].contains(stem) || stem.hasSuffix("_hand")
    }

    /// Whether a bone belongs to an arm: clavicle, upper arm, forearm, hand
    /// or finger, whatever the rig's prefix or naming (`Bip01 L Arm1`,
    /// `Xbow biped R Hand`, and the HD pack's `Bip01 L UpperArm`,
    /// `Bip01 L Forearm` and `L_Arm_bone`, which carries its sleeve, and
    /// Blue Shift's `L_wristbone`).
    ///
    /// Judged by whole name tokens, split on spaces and underscores, not by
    /// substring: the crossbow's bow limbs are `LeftArm`/`RightArm`, and are
    /// drawn with the glove texture too.
    static func isArmBone(_ name: String) -> Bool {
        let tokens = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" })
        return tokens.contains { t in
            ["arm", "arm1", "arm2", "upperarm", "forearm", "hand", "clavicle"].contains(String(t))
                || t.hasPrefix("finger") || t.hasPrefix("wrist")
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
        /// Where an aimed gun is held, relative to the grip bone's idle
        /// position, in model space: zero unless Valve's hand never touches
        /// the gun (see `pulledIn`).
        var pull: SIMD3<Float> = .zero
        /// The bone an aimed gun is held still by, when it is not the grip
        /// bone itself: the gun's body (see `gunBody`). Nil for a gun skinned
        /// straight to the hand, for a model that marks no muzzle, and for
        /// anything held.
        var body: Int?

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
    ///
    /// `gunPoints` (the gun's vertices without hands, posed in idle) let an
    /// aimed gun that the grip hand does not actually touch be pulled into
    /// it (`pulledIn`); without them the grip is as the bones say.
    ///
    /// `hasAttachment` (the model marks a muzzle) makes an aimed gun held by
    /// its body (`gunBody`, `Grip.body`); `loose` (per bone, `looseParts`)
    /// keeps a parked spare magazine from being taken for that body. Thrown
    /// things (grenades, snarks) and melee weapons mark none, so their throws
    /// and swings still leave the hand as Valve animated them.
    static func grip(boneNames: [String], parents: [Int?], pose: [float4x4],
                     extractorChoice: Int, geometry: [(hand: Int, other: Int)],
                     gunPoints: [SIMD3<Float>] = [], hasAttachment: Bool = false,
                     loose: [Bool] = []) -> Grip? {
        guard var g = boneGrip(boneNames: boneNames, parents: parents, pose: pose,
                               extractorChoice: extractorChoice, geometry: geometry) else { return nil }
        guard hold(grip: g, idlePalette: pose) == .aimed else { return g }
        if hasAttachment, let body = gunBody(geometry: geometry, loose: loose), body != g.bone, body < pose.count {
            g.body = body
        }
        guard !gunPoints.isEmpty else { return g }
        return pulledIn(g, idlePalette: pose, gunPoints: gunPoints)
    }

    /// The bone that carries the most of the gun (vertices not drawn with a
    /// hand texture), leaving out loose parts — the gun's body, which the
    /// barrel, sights and muzzle ride on. It is the hand bone itself where
    /// Valve skinned the gun straight to it (the Glock, the shotgun), and a
    /// bone of its own elsewhere (the .357's `python`, the HD MP5's
    /// `carbine`, the sniper rifle's `m40a1_stock`).
    static func gunBody(geometry: [(hand: Int, other: Int)], loose: [Bool]) -> Int? {
        let candidates = geometry.indices.filter { !(($0 < loose.count) && loose[$0]) && geometry[$0].other > 0 }
        return candidates.max { geometry[$0].other < geometry[$1].other }
    }

    private static func boneGrip(boneNames: [String], parents: [Int?], pose: [float4x4],
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
        if hands.isEmpty, let worn = wornGrip(parents: parents, pose: pose, geometry: geometry) { return worn }
        guard let hand = hands.min(by: { pose[$0].columns.3.y < pose[$1].columns.3.y }),
              let frame = synthesisedHandFrame(hand: hand, fingers: fingers[hand], pose: pose,
                                               isLeft: pose[hand].columns.3.y > 0)
        else { return nil }
        return Grip(bone: hand, fixup: pose[hand].inverse * frame,
                    isLeft: pose[hand].columns.3.y > 0, fingerPrefix: nil)
    }

    /// How far from the gun the grip bone may sit and still be holding it,
    /// in units. Every stock, HD and expansion grip whose hand visibly holds
    /// its gun sits within 1–5 of the nearest gun vertex in idle (the wrist
    /// is behind the fist); the gluon gun's right hand reads 8 and Opposing
    /// Force's shock roach 16.5 — their guns hang off a hand Valve never drew
    /// on them (the egon is held by a side bar in the left hand, the roach is
    /// worn over a hidden right hand), so pinning that bone floated the gun
    /// in front of the player's fist.
    static let holdingGapLimit: Float = 6
    /// The gap a pulled-in gun is left at: a typical hold's.
    static let pulledGap: Float = 3

    /// An aimed gun whose grip bone is further than `holdingGapLimit` from
    /// it, moved toward the hand along the line to its nearest vertex until
    /// that vertex is `pulledGap` away. Otherwise unchanged.
    static func pulledIn(_ grip: Grip, idlePalette: [float4x4], gunPoints: [SIMD3<Float>]) -> Grip {
        guard grip.bone < idlePalette.count else { return grip }
        let origin = xyz(idlePalette[grip.bone].columns.3)
        guard let nearest = gunPoints.min(by: { simd_distance($0, origin) < simd_distance($1, origin) })
        else { return grip }
        let gap = simd_distance(nearest, origin)
        guard gap > holdingGapLimit else { return grip }
        var g = grip
        g.pull = (nearest - origin) * (1 - pulledGap / gap)
        return g
    }

    /// A viewmodel with no hand drawn at all is worn over the fist: the
    /// hivehand, a creature whose own skeleton (`Bip01 Pelvis`…`Head`) runs
    /// forward from the wrist. Its root sits on the creature's centre line at
    /// the rear, which is where fitting it onto its world model puts that
    /// model's hand (2 units off on the classic model). So the root is the
    /// grip, with the model's axes as authored: the frame is the root's
    /// position with no rotation, so the hold reads as aimed. Nil when the
    /// model draws any hand, or has no root.
    static func wornGrip(parents: [Int?], pose: [float4x4],
                         geometry: [(hand: Int, other: Int)]) -> Grip? {
        guard geometry.allSatisfy({ $0.hand == 0 }),
              let root = parents.firstIndex(where: { $0 == nil }), root < pose.count else { return nil }
        var at = matrix_identity_float4x4
        at.columns.3 = pose[root].columns.3
        return Grip(bone: root, fixup: pose[root].inverse * at, isLeft: false, fingerPrefix: nil)
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

    // MARK: - Whether the hand can hold it at all

    /// Whether a viewmodel can be anchored in the hand, or has to be drawn
    /// the stock flat way (locked to the head, as authored in view space).
    ///
    /// Deliberately narrow, so Half-Life's own weapons keep their hold:
    /// every stock and HD v_ model has a grip, an idle pose and gun geometry
    /// left after the hand cut (the probe checks all three). What fails is a
    /// mod's viewmodel the grip rules can't read: no hand bone, no finger
    /// chains and no bare root to wear (`grip == nil` — the old fallback
    /// pinned its origin to the palm, which floats the gun anywhere), no
    /// idle pose to place it from, or a hand cut that leaves nothing of the
    /// gun while the body's hands would replace the viewmodel's.
    static func canAnchorInHand(grip: Grip?, idlePalette: [float4x4], gunVertexCount: Int) -> Bool {
        guard let grip, !idlePalette.isEmpty, grip.bone < idlePalette.count else { return false }
        return gunVertexCount > 0
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
    /// bone only says where: its idle position lands on the hand.
    ///
    /// What is held still is the gun's body (`Grip.body`, else the grip
    /// bone): its motion since idle is taken back out, so the pump, the
    /// cylinder and the magazine animate around a barrel that stays on the
    /// hand's aim. Holding the grip bone still instead lets every animation
    /// in which Valve's hand moves on the gun swing the gun off the aim: the
    /// HD .357's fidget raises it 8° for four seconds, the sniper rifle's
    /// bolt cycle turns it 47° after every shot, and the HD MP5's grenade
    /// flips it while the hand works the launcher.
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
            let held = grip.body ?? grip.bone
            var toGrip = matrix_identity_float4x4
            toGrip.columns.3 = SIMD4(-(xyz(bone(grip.bone, in: idlePalette).columns.3) + grip.pull), 1)
            return hand * flip * yaw(yawCorrection) * toGrip
                * bone(held, in: idlePalette) * bone(held, in: palette).inverse
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
    /// Attachment 0 when the model has one and it lies on the barrel —
    /// stock viewmodels put the muzzle flash there. Otherwise (the crossbow,
    /// the RPG, and an attachment off the barrel) the front of the gun: the
    /// centre of the gun geometry within an inch of its furthest-forward
    /// point. `gunPoints` are the gun's vertices (no hands, no parked parts)
    /// posed in idle.
    ///
    /// An attachment is on the barrel when, seen down the barrel (+X), it
    /// falls inside the outline of the gun's front `muzzleSlabDepth` units
    /// (`muzzleSlabMargin` of slack): a shot from it then leaves through the
    /// gun's front. Every stock and HD Half-Life gun's attachment does, but
    /// not all of the packs' copies: the HD .357 kept the classic model's
    /// offset on a bone that sits differently, which puts its attachment 4
    /// units ahead of and 4 above the barrel, so the shots and the reticle
    /// ran 11 cm above the drawn barrel. Opposing Force's Desert Eagle (above
    /// the slide), M249 (on the hand, 21 units back), sniper rifle (on the
    /// stock) and displacer (its spinner), and the HD shotgun (above the
    /// receiver) are off it too.
    static func muzzle(attachment: (bone: Int, org: SIMD3<Float>)?, idlePalette: [float4x4],
                       gunPoints: [SIMD3<Float>]) -> SIMD3<Float>? {
        if let a = attachment, a.bone < idlePalette.count {
            let p = xyz(idlePalette[a.bone] * SIMD4(a.org, 1))
            if gunPoints.isEmpty || isOnBarrel(p, gunPoints: gunPoints) { return p }
        }
        guard let front = gunPoints.map(\.x).max() else { return nil }
        let tip = gunPoints.filter { $0.x > front - 1 }
        return tip.reduce(.zero, +) / Float(tip.count)
    }

    /// How much of the gun's front an attachment is judged against, and the
    /// slack around its outline, in units. Measured over every stock, HD and
    /// expansion gun: attachments on the barrel sit inside the outline, the
    /// misplaced ones 1.3 (the HD shotgun) to 19 units outside it.
    static let muzzleSlabDepth: Float = 6
    static let muzzleSlabMargin: Float = 0.5

    /// Whether `p` (idle model space) lies within the outline of the gun's
    /// front, seen down +X (see `muzzle`).
    static func isOnBarrel(_ p: SIMD3<Float>, gunPoints: [SIMD3<Float>]) -> Bool {
        guard let front = gunPoints.map(\.x).max() else { return false }
        let slab = gunPoints.filter { $0.x > front - muzzleSlabDepth }
        let m = muzzleSlabMargin
        return p.y >= slab.map(\.y).min()! - m && p.y <= slab.map(\.y).max()! + m
            && p.z >= slab.map(\.z).min()! - m && p.z <= slab.map(\.z).max()! + m
    }

    /// The muzzle in the holding hand's frame, for an aimed gun: where shots
    /// leave from, fixed per model (the idle pose, like the barrel).
    static func muzzleInHand(_ muzzle: SIMD3<Float>, grip: Grip, idlePalette: [float4x4],
                             handIsLeft: Bool, yawCorrection: Float = 0) -> SIMD3<Float> {
        let flip = grip.isLeft != handIsLeft ? mirror : matrix_identity_float4x4
        let g = xyz(bone(grip.bone, in: idlePalette).columns.3) + grip.pull
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

    // MARK: - What the flat viewmodel would not have shown

    /// The flat viewmodel's frame. Viewmodels are authored in view space —
    /// eye at the origin, looking down +X, +Z up — and drawn at Half-Life's
    /// 90° (4:3) field of view: tan 0.75 vertically. Horizontally this allows
    /// for 16:9 (tan 4/3), so nothing a widescreen player saw is lost.
    static let flatFrameTan = SIMD2<Float>(4.0 / 3.0, 0.75)

    /// Whether a viewmodel-space point lies outside the flat frame (or
    /// behind the eye), with `margin` units of slack on every side.
    static func outsideFlatFrame(_ p: SIMD3<Float>, margin: Float = 1) -> Bool {
        p.x < 1 || abs(p.y) > p.x * flatFrameTan.x + margin || abs(p.z) > p.x * flatFrameTan.y + margin
    }

    /// Whether every one of `points` (bone space) lies outside the flat frame
    /// under the bone transform `m`.
    static func outsideFlatFrame(_ points: [SIMD3<Float>], _ m: float4x4) -> Bool {
        !points.isEmpty && points.allSatisfy { outsideFlatFrame(xyz(m * SIMD4($0, 1))) }
    }

    /// How far a loose part rests from everything in shot, at least, in
    /// units. Measured over every stock, HD and expansion viewmodel: the
    /// parked parts (spare magazines, speed loaders, shells, the spore
    /// launcher's spare spore) rest 9.3–55 units clear of the shot; bones
    /// that merely run off the frame edge (the hivehand's rear, the classic
    /// MP5's unnamed off-hand bones) are within 5.2 of it.
    static let looseGap: Float = 7

    /// Per bone, whether it is a loose part: something Valve parks out of
    /// shot until an animation needs it — the Glock's spare magazine
    /// (`Box02`), the .357's speed loader, the shotgun's shell. In the rest
    /// pose it lies wholly outside the flat frame and clear of everything in
    /// it. Arm bones never are: the hands are the hand cut's business (and a
    /// visible avatar's), and a held gun's own hand often sits off-frame.
    /// `points` is each bone's vertices in its own bone space.
    static func looseParts(points: [[SIMD3<Float>]], restPose: [float4x4], boneNames: [String]) -> [Bool] {
        let out = points.indices.map { b in
            b < restPose.count && b < boneNames.count && !isArmBone(boneNames[b])
                && outsideFlatFrame(points[b], restPose[b])
        }
        let shown = points.indices.filter { $0 < restPose.count && !outsideFlatFrame(points[$0], restPose[$0]) }
            .flatMap { b in points[b].map { xyz(restPose[b] * SIMD4($0, 1)) } }
        guard !shown.isEmpty else { return out.map { _ in false } }
        return points.indices.map { b in
            out[b] && points[b].allSatisfy { p in
                let w = xyz(restPose[b] * SIMD4(p, 1))
                return shown.allSatisfy { simd_distance($0, w) >= looseGap }
            }
        }
    }

    /// Per bone, whether to hide it in this pose: a loose part (`looseParts`)
    /// that is out of shot right now. A gun held in the hand has no frame
    /// edge to hide a parked part behind, so it would float beside the gun;
    /// once the reload brings it into shot it shows, and moves as authored.
    static func parkedBones(loose: [Bool], points: [[SIMD3<Float>]], palette: [float4x4]) -> [Bool] {
        loose.indices.map { b in
            loose[b] && b < points.count && b < palette.count && outsideFlatFrame(points[b], palette[b])
        }
    }

    /// `palette` with every parked bone collapsed to a point, so the GPU draws
    /// nothing of it (its triangles become degenerate).
    static func hidingParked(_ palette: [float4x4], parked: [Bool]) -> [float4x4] {
        var out = palette
        for (b, hide) in parked.enumerated() where hide && b < out.count {
            out[b] = float4x4(columns: (.zero, .zero, .zero, out[b].columns.3))
        }
        return out
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
