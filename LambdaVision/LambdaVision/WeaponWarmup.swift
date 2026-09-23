//
//  WeaponWarmup.swift
//  LambdaVision
//
//  Works out, before the game starts, what the weapon pass would otherwise
//  compute the first time each weapon is drawn — the way games compile their
//  shaders on the loading screen instead of stuttering through the first
//  level. Once in the immersive space nothing about a weapon is computed on
//  first sight, so nothing visibly settles after a switch.
//
//  Today that is Valve's toe-in on each viewmodel (ViewmodelAlignment), a fit
//  of tens to a few hundred milliseconds per gun. Every viewmodel and world
//  model under the game's model directories is baked from disk exactly as
//  the weapon slots will bake it, the pairs are fitted in parallel, and the
//  results are kept in `WeaponPrepCache` under a key both sides compute from
//  the baked mesh. The cache is written to disk, so a later launch only bakes
//  (milliseconds) and fits nothing it has seen before.
//
//  A weapon the warm-up did not see (another mod's models, a bodygroup other
//  than the default) still works: the weapon pass fits it in the background
//  on first sight, as before, and adds it to the cache.
//

import Foundation
import os
import simd

enum WeaponWarmup {

    /// What the weapon pass keys a viewmodel's or world model's prepared
    /// data by: the baked mesh's shape, the same whether the engine or the
    /// warm-up baked it.
    static func key(of mesh: lambda_weapon_mesh_t) -> String {
        "\(mesh.vertex_count).\(mesh.index_count).\(mesh.bone_count)"
    }

    /// The viewmodel's gun as triangle corners in its idle model space — the
    /// fit's input — or empty when it is not an aimed gun (held items keep
    /// Valve's grip and need no correction).
    static func viewmodelCorners(_ raw: lambda_weapon_mesh_t, idle: [float4x4]) -> [SIMD3<Float>] {
        let names = StudioMesh.textureNames(of: raw), bones = StudioMesh.boneNames(of: raw)
        let isHand = ViewmodelGrip.handTriangleFilter(textureNames: names, boneNames: bones)
        var parents: [Int?] = []
        if let b = raw.bones { for i in 0..<Int(raw.bone_count) { parents.append(b[i].parent >= 0 ? Int(b[i].parent) : nil) } }
        let geometry = ViewmodelGrip.boneGeometry(boneCount: bones.count, textureNames: names,
                                                  vertices: StudioMesh.vertexTextureBones(of: raw))
        guard let grip = ViewmodelGrip.grip(boneNames: bones, parents: parents, pose: idle,
                                            extractorChoice: Int(raw.hand_bone_index), geometry: geometry),
              ViewmodelGrip.hold(grip: grip, idlePalette: idle) == .aimed else { return [] }
        return StudioMesh.posedPoints(of: raw, palette: idle) { !isHand($0, $1, $2, $3) }
    }

    /// The world model laid out in its hand, and its triangle corners in that
    /// layout when it is an aimed gun.
    static func worldLayout(_ raw: lambda_weapon_mesh_t, restPose: [float4x4])
        -> (layout: ViewmodelGrip.WorldLayout?, corners: [SIMD3<Float>]) {
        let layout = ViewmodelGrip.worldLayout(
            boneNames: StudioMesh.boneNames(of: raw), restPose: restPose,
            points: StudioMesh.posedPoints(of: raw, palette: restPose) { _, _, _, _ in true })
        guard let layout, layout.hold == .aimed else { return (layout, []) }
        return (layout, StudioMesh.posedPoints(of: raw, palette: layout.palette) { _, _, _, _ in true })
    }

    /// Bakes every v_/p_ pair under the game's model directories and fits
    /// the ones the cache does not already hold. `progress` gets (done,
    /// total) on the main actor. Returns how many pairs were fitted fresh.
    @discardableResult
    static func run(gameDirectory: String, progress: @escaping (Int, Int) -> Void) async -> Int {
        let t0 = Date()
        var jobs: [(key: String, gun: [SIMD3<Float>], world: [SIMD3<Float>])] = []
        var seen = 0
        for dir in GameData.modelDirectories(in: gameDirectory) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for v in files where v.hasPrefix("v_") && v.hasSuffix(".mdl") {
                let p = "p_" + v.dropFirst(2)
                guard files.contains(p),
                      let viewmodel = bake(dir + "/" + v, corners: { viewmodelCorners($0, idle: $1) }),
                      !viewmodel.corners.isEmpty,
                      let world = bake(dir + "/" + p, corners: { worldLayout($0, restPose: $1).corners }),
                      !world.corners.isEmpty else { continue }
                seen += 1
                let key = viewmodel.key + "|" + world.key
                if WeaponPrepCache.shared.yaw(for: key) == nil {
                    jobs.append((key, viewmodel.corners, world.corners))
                }
                await Task.yield()   // one model at a time; keep the window responsive
            }
        }
        let total = jobs.count
        progress(0, total)
        var done = 0
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask(priority: .userInitiated) {
                    let yaw = ViewmodelAlignment.yawCorrection(gun: job.gun, world: job.world)
                    WeaponPrepCache.shared.set(yaw: yaw, for: job.key)
                }
            }
            for await _ in group {
                done += 1
                progress(done, total)
            }
        }
        if total > 0 { WeaponPrepCache.shared.save() }
        AppLog.render.line(String(format: "[WeaponWarmup] %d weapons, %d fitted in %.2f s", seen, total,
                                  Date().timeIntervalSince(t0)))
        return total
    }

    /// Reads a model into the scratch slot and extracts what the fit needs.
    private static func bake(_ path: String,
                             corners: (lambda_weapon_mesh_t, [float4x4]) -> [SIMD3<Float>])
        -> (key: String, corners: [SIMD3<Float>])? {
        guard path.withCString({ lambda_scratch_load($0, 0) }) != 0 else { return nil }
        var raw = lambda_weapon_mesh_t()
        let gen = lambda_scratch_lock(&raw)
        defer { lambda_scratch_unlock() }
        var pose = lambda_weapon_pose_t()
        guard gen != 0, lambda_scratch_copy_pose(&pose) == gen else { return nil }
        return (key(of: raw), corners(raw, StudioMesh.palette(from: &pose)))
    }
}

/// Prepared weapon data by key, shared by the warm-up (which fills it before
/// the game starts) and the weapon pass (which reads it on the render thread
/// and adds anything it had to fit itself). Persisted in Caches, so it
/// survives relaunches but may be purged by the system — then the next
/// warm-up simply fits again.
nonisolated final class WeaponPrepCache: Sendable {
    static let shared = WeaponPrepCache()

    /// Bump whenever the fit or its inputs change, to drop stale results.
    private static let version = 1
    private let yaws = OSAllocatedUnfairLock<[String: Float]>(initialState: [:])
    private let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("weapon-prep-v\(version).json")

    private init() {
        if let url, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Float].self, from: data) {
            yaws.withLock { $0 = stored }
        }
    }

    func yaw(for key: String) -> Float? { yaws.withLock { $0[key] } }
    func set(yaw: Float, for key: String) { yaws.withLock { $0[key] = yaw } }

    func save() {
        guard let url, let data = try? JSONEncoder().encode(yaws.withLock { $0 }) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
