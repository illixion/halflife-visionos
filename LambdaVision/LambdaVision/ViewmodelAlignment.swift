//
//  ViewmodelAlignment.swift
//  LambdaVision
//
//  How far a viewmodel's gun is toed in off its own axes.
//
//  An aimed viewmodel is laid in the hand by its model axes (+X the barrel,
//  +Z up — ViewmodelGrip.modelMatrix), which holds for most guns to a few
//  degrees. Not all: Valve toed some guns in toward the middle of the flat
//  screen, the crossbows worst (about 6° left), so in the hand the gun points
//  one way and the shots go another. Nothing in the viewmodel says by how
//  much.
//
//  The weapon's world (p_) model does: laid out by ViewmodelGrip.worldLayout,
//  its barrel is on +X and it sits upright. So the viewmodel's gun is fitted
//  onto it — rigidly, starting from the axes as they are, measured from the
//  viewmodel onto the world model (every surface the viewmodel has should lie
//  on the other, whose extra stock and far side cost nothing).
//
//  Only the yaw of the rotation found is used. It is the one part that is
//  plainly Valve's doing: every stock and HD gun whose fit holds points left
//  of its world model (crossbows 5.6–6°, the M4 2–4°, the RPG and gauss
//  about 2.5°), toward the old screen's middle. Pitch and roll come out
//  mixed, and the world model's own barrel is only known to its long axis —
//  a pistol's raked grip tips that by 20° — so they stay as authored. The
//  grip stays where Valve's hand put it.
//
//  A fit that ends far from where it started, or that leaves much of the
//  viewmodel off the world model, is a different shape and not a correction
//  (the 357's two models differ a great deal); the axes as they are are kept.
//
//  No Metal, no engine: plain points in, a rotation out, so the probe runs
//  it on every stock and HD model.
//

import simd

nonisolated enum ViewmodelAlignment {

    /// Largest whole-fit rotation trusted, degrees.
    static let maxCorrectionDeg: Float = 30
    /// Share of the viewmodel's surface that must end within `coverageRadius`
    /// of the world model.
    static let minCoverage: Float = 0.6
    static let coverageRadius: Float = 1.5
    /// Share of the closest pairs each iteration is solved on, so details
    /// the world model never had (a sight, Valve's bolt) do not pull.
    static let trimKeep: Float = 0.8
    static let iterations = 30

    struct Result {
        /// Viewmodel gun space → world-model layout space (rotation only).
        var rotation: simd_quatf
        /// World-model layout = rotation · viewmodel + offset.
        var offset: SIMD3<Float>
        var coverage: Float
        var residual: Float
        var degrees: Float { abs(rotation.angle) * 180 / .pi }
        /// Where the world model's hand lands in the viewmodel's space.
        var handPoint: SIMD3<Float> { rotation.inverse.act(-offset) }
        /// The rotation's turn about the up axis, radians: where the
        /// viewmodel's +X lands, seen from above (negative = to the right,
        /// i.e. the gun was toed in to the left).
        var yaw: Float {
            let x = rotation.act(SIMD3<Float>(1, 0, 0))
            return atan2f(x.y, x.x)
        }
    }

    /// The yaw correction for a viewmodel, radians, or 0 when the fit is not
    /// trusted.
    static func yawCorrection(gun: [SIMD3<Float>], world: [SIMD3<Float>]) -> Float {
        guard let r = fit(gun: gun, world: world), accepted(r) else { return 0 }
        return r.yaw
    }

    /// Fits the viewmodel's gun (triangle corners, three per triangle, in
    /// its idle model space with the grip at the origin) onto the world
    /// model's (the same, in its layout space). Nil when either is empty.
    /// The result may still be rejected — check `accepted`.
    static func fit(gun: [SIMD3<Float>], world: [SIMD3<Float>]) -> Result? {
        let source = subsample(surfaceSamples(gun, spacing: 0.8), max: 800)
        let target = surfaceSamples(world, spacing: 0.6)
        guard source.count >= 16, target.count >= 16 else { return nil }
        let grid = PointGrid(target, cell: 1.5)

        // Start from the axes as they are, the gun's centre on the world
        // model's. Rigid: let the scale float and the gun shrinks into the
        // other's middle, where every point has a neighbour.
        let (lo, hi) = extent(source), (wlo, whi) = extent(target)
        var rotation = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
        var offset = (wlo + whi) / 2 - (lo + hi) / 2
        var residual: Float = .infinity
        for _ in 0..<iterations {
            var pairs: [(SIMD3<Float>, SIMD3<Float>, Float)] = source.compactMap { p in
                let moved = rotation.act(p) + offset
                guard let n = grid.nearest(to: moved, within: 6) else { return nil }
                return (p, n.point, n.distance)
            }
            guard pairs.count >= source.count / 3 else { return nil }
            pairs.sort { $0.2 < $1.2 }
            pairs = Array(pairs.prefix(max(8, Int(Float(pairs.count) * trimKeep))))
            guard let u = horn(pairs.map(\.0), pairs.map(\.1)) else { return nil }
            rotation = u.rotation
            offset = u.targetMean - rotation.act(u.sourceMean)
            let e = sqrtf(pairs.reduce(0) { $0 + $1.2 * $1.2 } / Float(pairs.count))
            if abs(residual - e) < 1e-4 { residual = e; break }
            residual = e
        }
        let covered = source.filter {
            grid.nearest(to: rotation.act($0) + offset, within: coverageRadius) != nil
        }.count
        return Result(rotation: rotation, offset: offset,
                      coverage: Float(covered) / Float(source.count), residual: residual)
    }

    static func accepted(_ r: Result) -> Bool {
        r.degrees <= maxCorrectionDeg && r.coverage >= minCoverage
    }

    // MARK: - Maths

    private static func extent(_ p: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>) {
        (p.reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) },
         p.reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) })
    }

    /// Points spread over a triangle soup about `spacing` apart, so a big
    /// flat panel weighs as much as the fine detail beside it.
    static func surfaceSamples(_ corners: [SIMD3<Float>], spacing: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for i in stride(from: 0, to: corners.count - 2, by: 3) {
            let a = corners[i], b = corners[i + 1], c = corners[i + 2]
            let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            let n = min(24, max(1, Int(ceilf(longest / spacing))))
            for u in 0...n {
                for v in 0...(n - u) {
                    out.append(a + (b - a) * (Float(u) / Float(n)) + (c - a) * (Float(v) / Float(n)))
                }
            }
        }
        return out
    }

    private static func subsample(_ points: [SIMD3<Float>], max n: Int) -> [SIMD3<Float>] {
        guard points.count > n else { return points }
        let step = Double(points.count) / Double(n)
        return (0..<n).map { points[Int(Double($0) * step)] }
    }

    /// Least-squares rotation taking `x` onto `y` (Horn's quaternion: the
    /// top eigenvector of a 4×4 symmetric matrix built from the
    /// cross-covariance).
    static func horn(_ x: [SIMD3<Float>], _ y: [SIMD3<Float>])
        -> (rotation: simd_quatf, sourceMean: SIMD3<Float>, targetMean: SIMD3<Float>)? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let n = Float(x.count)
        let mx = x.reduce(.zero, +) / n, my = y.reduce(.zero, +) / n
        var s = [[Float]](repeating: [0, 0, 0], count: 3)
        for (a, b) in zip(x, y) {
            let p = a - mx, q = b - my
            for i in 0..<3 { for j in 0..<3 { s[i][j] += p[i] * q[j] } }
        }
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
        return (q, mx, my)
    }

    /// Eigenvalues and eigenvectors of a small symmetric matrix (cyclic
    /// Jacobi), one vector per value.
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
        return ((0..<n).map { Float(a[$0][$0]) }, (0..<n).map { j in (0..<n).map { Float(v[$0][j]) } })
    }
}

/// Nearest-point queries over a fixed set, bucketed on a uniform grid.
nonisolated struct PointGrid {
    private let points: [SIMD3<Float>]
    private let cell: Float
    private var buckets: [SIMD3<Int32>: [Int]] = [:]

    init(_ points: [SIMD3<Float>], cell: Float) {
        self.points = points
        self.cell = cell
        for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
    }

    private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(floorf(p.x / cell)), Int32(floorf(p.y / cell)), Int32(floorf(p.z / cell)))
    }

    /// Nearest point within `radius`, or nil.
    func nearest(to q: SIMD3<Float>, within radius: Float) -> (point: SIMD3<Float>, distance: Float)? {
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
            // Anything in a further ring is at least r·cell away.
            if best >= 0, sqrtf(bestD2) <= Float(r) * cell { break }
        }
        return best >= 0 ? (points[best], sqrtf(bestD2)) : nil
    }
}
