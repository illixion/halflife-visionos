//
//  ViewmodelShell.swift
//  LambdaVision
//
//  A complete hull for a viewmodel's gun, made from its third-person model.
//
//  Valve built v_ models for a fixed camera, so whatever faces away from it
//  was never modelled: the M4's stock, the underside of the shotgun's grip,
//  most of the gluon gun. The same weapon's p_ model is whole — it is seen
//  from every side in third person — but it is one rigid mesh with a single
//  idle sequence; the magazine, pump and cylinder are fused into it.
//
//  So the p_ gun is fitted onto the v_ gun (same weapon, different pose and
//  sometimes scale), each of its triangles is skinned to the v_ bone under
//  it, and it is drawn just inside the v_ surface with the v_ palette. Where
//  the viewmodel has a surface, the viewmodel is what shows; where it has a
//  hole, the hull does, and it moves with the magazine or the pump because
//  it is skinned to the same bones.
//
//  Skinning is per triangle, not per vertex: GoldSrc binds each vertex
//  rigidly to one bone, and a triangle whose corners follow two bones
//  stretches as they part. A triangle that straddles the magazine and the
//  receiver is given to one of them whole, which opens a clean cut instead;
//  the pass shades back faces as the gun's dark interior, so looking into the
//  cut shows solid metal, not the room behind.
//
//  No Metal, no engine: points in, transforms and bone indices out, so the
//  avatar probe runs the fit on every real model on the Mac.
//

import simd

nonisolated enum ViewmodelShell {

    // MARK: - Fitting the p_ gun onto the v_ gun

    struct Fit {
        /// p_ model space → v_ idle model space (rotation, uniform scale,
        /// translation).
        var transform: float4x4
        var scale: Float
        /// RMS distance from the kept viewmodel samples to the hull, units.
        var residual: Float
        /// Fraction of the v_ gun's surface within `coverageRadius` of the
        /// fitted hull — how much of the viewmodel the hull reproduces.
        var coverage: Float
    }

    static let coverageRadius: Float = 1.0
    /// Share of the viewmodel's surface samples the fit is judged on each
    /// iteration: its details the p_ model never had (a sight, a bolt
    /// handle) must not drag the hull toward them.
    static let trimKeep: Float = 0.85
    static let iterations = 40
    static let scaleRange: ClosedRange<Float> = 0.5...2
    /// Surface sampling pitch, units.
    static let sampleSpacing: Float = 0.6

    /// Fits the p_ gun onto the v_ gun. Both are given as triangle corners
    /// (three consecutive points per triangle), each in its own model space.
    ///
    /// Trimmed ICP for a similarity transform, run from every way the two
    /// guns' principal axes can be matched up, keeping the start that ends
    /// tightest. The error is measured from the viewmodel onto the hull —
    /// every surface the viewmodel has must lie on the hull, while the hull's
    /// extra parts (the stock the viewmodel lacks) cost nothing. Measured the
    /// other way round, shrinking the hull into one end of the gun scores
    /// better than fitting it.
    static func fit(hull: [SIMD3<Float>], gun: [SIMD3<Float>]) -> Fit? {
        let source = surfaceSamples(hull, spacing: sampleSpacing, max: 2500)
        let target = subsample(surfaceSamples(gun, spacing: sampleSpacing, max: 6000), max: 1500)
        guard source.count >= 16, target.count >= 16 else { return nil }

        let (cs, axesS) = principalAxes(source)
        let (ct, axesT) = principalAxes(target)
        var best: (m: float4x4, s: Float, err: Float)?
        for swap in [false, true] {
            let at = swap ? simd_float3x3(axesT.columns.0, axesT.columns.2, axesT.columns.1) : axesT
            for sx: Float in [1, -1] {
                for sy: Float in [1, -1] {
                    var r = at * simd_float3x3(diagonal: SIMD3(sx, sy, 1)) * axesS.transpose
                    if r.determinant < 0 { r = at * simd_float3x3(diagonal: SIMD3(sx, sy, -1)) * axesS.transpose }
                    let start = similarity(rotation: r, scale: 1, translation: ct - r * cs)
                    guard let (m, s, err) = icp(source, target, start: start) else { continue }
                    if best == nil || err < best!.err { best = (m, s, err) }
                }
            }
        }
        guard let best else { return nil }
        let fitted = PointGrid(source.map { transform(best.m, $0) }, cell: 1.5)
        let covered = target.filter { fitted.nearest(to: $0).distance <= coverageRadius }.count
        return Fit(transform: best.m, scale: best.s, residual: best.err,
                   coverage: Float(covered) / Float(target.count))
    }

    private static func icp(_ source: [SIMD3<Float>], _ target: [SIMD3<Float>], start: float4x4)
        -> (float4x4, Float, Float)? {
        var m = start
        var scale: Float = 1
        var err: Float = .infinity
        for _ in 0..<iterations {
            let moved = source.map { transform(m, $0) }
            let grid = PointGrid(moved, cell: 1.5)
            var pairs: [(SIMD3<Float>, SIMD3<Float>, Float)] = target.compactMap { q in
                guard let n = grid.nearest(to: q, within: 6) else { return nil }
                return (source[n.index], q, n.distance)
            }
            // A start this far off matches almost nothing; it is not the fit.
            guard pairs.count >= target.count / 4 else { return nil }
            pairs.sort { $0.2 < $1.2 }
            pairs = Array(pairs.prefix(max(8, Int(Float(target.count) * trimKeep))))
            guard let u = umeyama(pairs.map { $0.0 }, pairs.map { $0.1 }) else { return nil }
            scale = min(max(u.scale, scaleRange.lowerBound), scaleRange.upperBound)
            m = similarity(rotation: u.rotation, scale: scale,
                           translation: u.targetMean - u.rotation * u.sourceMean * scale)
            let e = sqrtf(pairs.reduce(0) { $0 + $1.2 * $1.2 } / Float(pairs.count))
            if abs(err - e) < 1e-4 { err = e; break }
            err = e
        }
        return (m, scale, err)
    }

    /// Points spread over a triangle soup's surface at about `spacing` apart
    /// (a triangular grid per triangle, corners and all), so a big flat
    /// panel weighs as much as the fine detail next to it. Thinned evenly to
    /// `max`.
    static func surfaceSamples(_ corners: [SIMD3<Float>], spacing: Float, max: Int) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for i in stride(from: 0, to: corners.count - 2, by: 3) {
            let a = corners[i], b = corners[i + 1], c = corners[i + 2]
            let longest = Swift.max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            let n = Swift.min(24, Swift.max(1, Int(ceilf(longest / spacing))))
            for u in 0...n {
                for v in 0...(n - u) {
                    let fu = Float(u) / Float(n), fv = Float(v) / Float(n)
                    out.append(a + (b - a) * fu + (c - a) * fv)
                }
            }
        }
        return subsample(out, max: max)
    }

    // MARK: - Skinning the hull to the viewmodel's bones

    /// The v_ bone for each hull triangle (three consecutive points each, in
    /// v_ idle model space): the bone most of its corners sit nearest to,
    /// the centre's nearest bone breaking a three-way tie.
    static func triangleBones(_ corners: [SIMD3<Float>], target: [SIMD3<Float>], targetBones: [Int]) -> [Int] {
        let grid = PointGrid(target, cell: 1.5)
        return stride(from: 0, to: corners.count - 2, by: 3).map { i in
            let b = (0..<3).map { targetBones[grid.nearest(to: corners[i + $0]).index] }
            if b[0] == b[1] || b[0] == b[2] { return b[0] }
            if b[1] == b[2] { return b[1] }
            let centre = (corners[i] + corners[i + 1] + corners[i + 2]) / 3
            return targetBones[grid.nearest(to: centre).index]
        }
    }

    // MARK: - Keeping only what the viewmodel lacks

    /// Half-angles of the view Valve modelled for (fov 90 at 4:3 is 45° ×
    /// 37°), widened so a part cut off at the screen edge still counts as
    /// seen only where it really was.
    static let viewHalfWidthTan: Float = tanf(50 * .pi / 180)
    static let viewHalfHeightTan: Float = tanf(42 * .pi / 180)

    /// Which hull triangles to draw: the ones the viewmodel cannot have.
    ///
    /// A v_ model contains what its camera — at the model origin, looking
    /// down +X — could see, and nothing else. A hull triangle is only needed
    /// where that camera could not see it: facing away, outside the view,
    /// or hidden behind other viewmodel geometry (Valve's hands included,
    /// which is why the grip under the glove was never modelled). Everything
    /// else the viewmodel already draws, better; keeping the hull there too
    /// would show it beside the real surface wherever the two models'
    /// proportions differ — the crossbow's limbs are drawn at a different
    /// flex in each.
    ///
    /// `hull` and `occluders` are triangle corners in v_ idle model space;
    /// GoldSrc front faces wind clockwise, so the outward normal is
    /// (c − a) × (b − a).
    static func needed(hull: [SIMD3<Float>], gun: [SIMD3<Float>], occluders: [SIMD3<Float>]) -> [Bool] {
        let surface = OrientedSamples(gun, spacing: sampleSpacing)
        return stride(from: 0, to: hull.count - 2, by: 3).map { i in
            let a = hull[i], b = hull[i + 1], c = hull[i + 2]
            let centre = (a + b + c) / 3
            let outward = simd_cross(c - a, b - a)
            guard simd_length(outward) > 1e-8 else { return false }
            let n = simd_normalize(outward)
            // The viewmodel already has this side here: its own surface is
            // better, and a second one beside it is the ghost to avoid. Judged
            // over the whole triangle — a p_ face can span a panel that the
            // viewmodel only partly modelled, and then it is still needed.
            let probes = surfaceSamples([a, b, c], spacing: sampleSpacing, max: 64)
            let covered = probes.filter { surface.hasSurface(near: $0, facing: n, within: redundantRadius) }.count
            if Float(covered) >= Float(probes.count) * redundantShare { return false }
            if simd_dot(n, -centre) <= 0 { return true }                       // faces away
            guard centre.x > 0.5,
                  abs(centre.y) < centre.x * viewHalfWidthTan,
                  abs(centre.z) < centre.x * viewHalfHeightTan else { return true } // out of view
            let distance = simd_length(centre)
            let ray = centre / distance
            for j in stride(from: 0, to: occluders.count - 2, by: 3) {
                if let t = rayHit(ray, occluders[j], occluders[j + 1], occluders[j + 2]),
                   t < distance - 0.75 { return true }                           // hidden
            }
            return false
        }
    }

    /// A hull triangle this close to a viewmodel surface facing the same way
    /// (units) is already covered by it.
    static let redundantRadius: Float = 1.0
    /// …over at least this share of its surface.
    static let redundantShare: Float = 0.9

    /// Möller–Trumbore from the origin along `dir`; distance to the hit.
    private static func rayHit(_ dir: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                               _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(dir, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-8 else { return nil }
        let inv = 1 / det
        let u = simd_dot(-a, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(-a, e1)
        let v = simd_dot(dir, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 0 ? t : nil
    }

    /// How far the hull is pulled in along its normals, so the viewmodel's
    /// own surface wins wherever both exist (units; 0.1 ≈ 2.5 mm).
    static let inset: Float = 0.12

    // MARK: - Building the hull

    /// The p_ gun as the build takes it: per triangle corner, in its idle
    /// model space.
    struct Hull {
        var corners: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        /// Per triangle: the p_ texture it samples.
        var textures: [Int]
    }

    /// The finished hull: per corner, a vertex local to the v_ bone its
    /// triangle rides on (so the viewmodel's palette skins it), grouped by
    /// the p_ texture of each triangle.
    struct Built {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var bones: [Int]
        var textures: [Int]
        var fit: Fit
        var kept: Int
        var total: Int
    }

    /// Fits below this are not the same gun — a p_ model from another
    /// weapon mid-switch, or one that shares nothing with its viewmodel (the
    /// hivehand's) — and get no hull.
    static let minCoverage: Float = 0.7
    static let maxResidual: Float = 1.5

    /// Fit, keep what the viewmodel lacks, skin each kept triangle to the v_
    /// bone under it, inset it, and express it in that bone's idle space.
    /// `gun`/`gunBones` are the v_ gun's corners (hands cut) and their
    /// bones, `occluders` every v_ corner (hands included), all in idle
    /// model space.
    static func build(hull: Hull, gun: [SIMD3<Float>], gunBones: [Int], occluders: [SIMD3<Float>],
                      idlePalette: [float4x4]) -> Built? {
        guard let fit = fit(hull: hull.corners, gun: gun),
              fit.coverage >= minCoverage, fit.residual <= maxResidual else { return nil }
        let corners = hull.corners.map { transform(fit.transform, $0) }
        let keep = needed(hull: corners, gun: gun, occluders: occluders)
        let bones = triangleBones(corners, target: gun, targetBones: gunBones)
        let rotation = simd_float3x3(columns: (xyz(fit.transform.columns.0), xyz(fit.transform.columns.1),
                                               xyz(fit.transform.columns.2)))
        var out = Built(positions: [], normals: [], uvs: [], bones: [], textures: [], fit: fit,
                        kept: 0, total: keep.count)
        for t in keep.indices where keep[t] {
            let b = bones[t]
            guard b < idlePalette.count else { continue }
            let inv = idlePalette[b].inverse
            out.kept += 1
            out.textures.append(hull.textures[t])
            for c in 0..<3 {
                let i = t * 3 + c
                let n = simd_normalize(rotation * hull.normals[i])
                let p = corners[i] - n * inset
                out.positions.append(xyz(inv * SIMD4(p, 1)))
                out.normals.append(simd_normalize(xyz(inv * SIMD4(n, 0))))
                out.uvs.append(hull.uvs[i])
                out.bones.append(b)
            }
        }
        return out.kept > 0 ? out : nil
    }

    private static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    // MARK: - Maths

    static func transform(_ m: float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    private static func similarity(rotation r: simd_float3x3, scale s: Float,
                                   translation t: SIMD3<Float>) -> float4x4 {
        let a = r * s
        return float4x4(columns: (SIMD4(a.columns.0, 0), SIMD4(a.columns.1, 0),
                                  SIMD4(a.columns.2, 0), SIMD4(t, 1)))
    }

    private static func subsample(_ points: [SIMD3<Float>], max n: Int) -> [SIMD3<Float>] {
        guard points.count > n else { return points }
        let step = Double(points.count) / Double(n)
        return (0..<n).map { points[Int(Double($0) * step)] }
    }

    /// Centroid and principal axes (columns, largest variance first).
    static func principalAxes(_ points: [SIMD3<Float>]) -> (SIMD3<Float>, simd_float3x3) {
        let c = points.reduce(.zero, +) / Float(points.count)
        var cov = simd_float3x3()
        for p in points { let d = p - c; cov += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z)) }
        let (values, vectors) = symmetricEigen3(cov)
        let order = (0..<3).sorted { values[$0] > values[$1] }
        return (c, simd_float3x3(vectors[order[0]], vectors[order[1]], vectors[order[2]]))
    }

    /// Least-squares similarity taking `x` onto `y` (Umeyama), via Horn's
    /// quaternion: the rotation is the top eigenvector of a 4×4 symmetric
    /// matrix built from the cross-covariance.
    static func umeyama(_ x: [SIMD3<Float>], _ y: [SIMD3<Float>])
        -> (rotation: simd_float3x3, scale: Float, sourceMean: SIMD3<Float>, targetMean: SIMD3<Float>)? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let n = Float(x.count)
        let mx = x.reduce(.zero, +) / n, my = y.reduce(.zero, +) / n
        var s = [[Float]](repeating: [0, 0, 0], count: 3)
        var varX: Float = 0
        for (a, b) in zip(x, y) {
            let p = a - mx, q = b - my
            varX += simd_length_squared(p)
            for i in 0..<3 { for j in 0..<3 { s[i][j] += p[i] * q[j] } }
        }
        guard varX > 1e-6 else { return nil }
        let (sxx, sxy, sxz) = (s[0][0], s[0][1], s[0][2])
        let (syx, syy, syz) = (s[1][0], s[1][1], s[1][2])
        let (szx, szy, szz) = (s[2][0], s[2][1], s[2][2])
        let nmat: [[Float]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        let (values, vectors) = jacobiEigen(nmat)
        let top = values.indices.max { values[$0] < values[$1] }!
        let v = vectors[top]
        let q = simd_normalize(simd_quatf(ix: v[1], iy: v[2], iz: v[3], r: v[0]))
        let r = simd_float3x3(q)
        var dot: Float = 0
        for (a, b) in zip(x, y) { dot += simd_dot(b - my, r * (a - mx)) }
        return (r, dot / varX, mx, my)
    }

    private static func symmetricEigen3(_ m: simd_float3x3) -> ([Float], [SIMD3<Float>]) {
        let a = (0..<3).map { i in (0..<3).map { j in m[j][i] } }
        let (values, vectors) = jacobiEigen(a)
        return (values, vectors.map { SIMD3($0[0], $0[1], $0[2]) })
    }

    /// Eigenvalues and eigenvectors of a small symmetric matrix (cyclic
    /// Jacobi). Vectors are returned one per eigenvalue.
    static func jacobiEigen(_ input: [[Float]]) -> ([Float], [[Float]]) {
        let n = input.count
        var a = input.map { $0.map(Double.init) }
        var v = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<60 {
            var off = 0.0
            for i in 0..<n { for j in (i + 1)..<n { off += a[i][j] * a[i][j] } }
            if off < 1e-18 { break }
            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p][q]) > 1e-20 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let values = (0..<n).map { Float(a[$0][$0]) }
        let vectors = (0..<n).map { j in (0..<n).map { Float(v[$0][j]) } }
        return (values, vectors)
    }
}

/// Nearest-point queries over a fixed set, bucketed on a uniform grid.
nonisolated struct PointGrid: Sendable {
    private let points: [SIMD3<Float>]
    private let cell: Float
    private var buckets: [SIMD3<Int32>: [Int]] = [:]

    init(_ points: [SIMD3<Float>], cell: Float) {
        self.points = points
        self.cell = cell
        for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
    }

    var cellSize: Float { cell }
    func cellKey(_ p: SIMD3<Float>) -> SIMD3<Int32> { key(p) }
    func bucket(_ k: SIMD3<Int32>) -> [Int]? { buckets[k] }
    func point(_ i: Int) -> SIMD3<Float> { points[i] }

    private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(floorf(p.x / cell)), Int32(floorf(p.y / cell)), Int32(floorf(p.z / cell)))
    }

    /// Nearest point within `radius`, or nil.
    func nearest(to q: SIMD3<Float>, within radius: Float) -> (index: Int, point: SIMD3<Float>, distance: Float)? {
        let k = key(q)
        var best = -1
        var bestD2 = radius * radius
        let rings = Int(ceilf(radius / cell))
        for r in 0...rings {
            for dx in -r...r { for dy in -r...r { for dz in -r...r
                where max(abs(dx), abs(dy), abs(dz)) == r {
                guard let list = buckets[k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                for i in list {
                    let d2 = simd_distance_squared(points[i], q)
                    if d2 < bestD2 { bestD2 = d2; best = i }
                }
            } } }
            if best >= 0, sqrtf(bestD2) <= Float(r) * cell { break }
        }
        return best >= 0 ? (best, points[best], sqrtf(bestD2)) : nil
    }

    /// Searches outward shell by shell; stops once no unsearched cell can
    /// hold anything nearer than the best found, falling back to every point.
    func nearest(to q: SIMD3<Float>) -> (index: Int, point: SIMD3<Float>, distance: Float) {
        let k = key(q)
        var best = -1
        var bestD2 = Float.infinity
        for r in 0...12 {
            for dx in -r...r { for dy in -r...r { for dz in -r...r
                where max(abs(dx), abs(dy), abs(dz)) == r {
                guard let list = buckets[k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                for i in list {
                    let d2 = simd_distance_squared(points[i], q)
                    if d2 < bestD2 { bestD2 = d2; best = i }
                }
            } } }
            if best >= 0, sqrtf(bestD2) <= Float(r) * cell { break }
        }
        if best < 0 {
            for (i, p) in points.enumerated() {
                let d2 = simd_distance_squared(p, q)
                if d2 < bestD2 { bestD2 = d2; best = i }
            }
        }
        return (best, points[best], sqrtf(bestD2))
    }
}

/// Surface samples of a triangle soup with each one's outward normal
/// (clockwise-front, as GoldSrc winds), for "is there a surface facing this
/// way near here" queries.
nonisolated struct OrientedSamples: Sendable {
    private let grid: PointGrid
    private let normals: [SIMD3<Float>]
    private let points: [SIMD3<Float>]

    init(_ corners: [SIMD3<Float>], spacing: Float) {
        var pts: [SIMD3<Float>] = [], ns: [SIMD3<Float>] = []
        for i in stride(from: 0, to: corners.count - 2, by: 3) {
            let a = corners[i], b = corners[i + 1], c = corners[i + 2]
            let outward = simd_cross(c - a, b - a)
            guard simd_length(outward) > 1e-8 else { continue }
            let n = simd_normalize(outward)
            for p in ViewmodelShell.surfaceSamples([a, b, c], spacing: spacing, max: .max) {
                pts.append(p); ns.append(n)
            }
        }
        points = pts
        normals = ns
        grid = PointGrid(pts, cell: 1.5)
    }

    func hasSurface(near p: SIMD3<Float>, facing n: SIMD3<Float>, within radius: Float) -> Bool {
        grid.anyIndex(near: p, within: radius) { simd_dot(normals[$0], n) > 0.5 }
    }
}

nonisolated extension PointGrid {
    /// Whether any point within `radius` passes `accept`.
    func anyIndex(near q: SIMD3<Float>, within radius: Float, _ accept: (Int) -> Bool) -> Bool {
        let rings = Int(ceilf(radius / cellSize))
        let k = cellKey(q)
        let r2 = radius * radius
        for dx in -rings...rings { for dy in -rings...rings { for dz in -rings...rings {
            guard let list = bucket(k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))) else { continue }
            for i in list where simd_distance_squared(point(i), q) <= r2 && accept(i) { return true }
        } } }
        return false
    }
}
