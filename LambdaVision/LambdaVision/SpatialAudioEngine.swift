//
//  SpatialAudioEngine.swift
//  LambdaVision
//
//  Per-source HRTF rendering for engine sound channels, fed by
//  Lambda_SpatialAudio.c through the callback table registered below.
//  AVAudioEngine + AVAudioEnvironmentNode; the engine's own stereo mix
//  ("the bed": music, UI, player-own sounds) keeps playing through the
//  AudioQueue backend in parallel.
//
//  Space: everything stays in xash's world basis (right-handed, +Z up),
//  scaled inches→meters. The environment node only needs listener and
//  sources to agree on one consistent right-handed frame.
//
//  HL attenuation (linear falloff, silent at 1000/attn units) is
//  reproduced exactly by scaling each source's DISTANCE from the listener
//  by dist_mult*1000 and configuring linear rolloff to 25.4 m (= 1000
//  units): direction is preserved, HL loudness curves are preserved.
//
//  Callbacks arrive on the GL worker; PCM is copied synchronously, then
//  all engine-graph work hops to a serial control queue.
//

import AVFAudio
import simd

// @unchecked: all mutable state is confined to the serial control queue.
nonisolated final class SpatialAudioEngine: @unchecked Sendable {
    /// Parked pending a PHASE-based rewrite: AVAudioEnvironmentNode renders
    /// silence on visionOS 26 even with a verified-correct graph (stereo
    /// output format, valid listener/source poses, advancing render clock —
    /// only non-environment connections produce audio). With this off the
    /// engine's stock stereo mixer handles all sound.
    static let enabled = false

    nonisolated(unsafe) static let shared = SpatialAudioEngine()

    private static let metersPerUnit: Float = 0.0254

    private let queue = DispatchQueue(label: "com.illixion.LambdaVision.spatialaudio")
    private let engine = AVAudioEngine()
    private let env = AVAudioEnvironmentNode()
    private var running = false

    // Every buffer is resampled to this rate at schedule time so all
    // player nodes connect ONCE with a single format. Reconnecting a
    // node on a running engine interrupts other players and drops their
    // completion handlers — the original design (per-sound native-rate
    // reconnects) leaked the whole pool within seconds of a map load.
    private static let mixRate: Double = 44100
    private let mixFormat = AVAudioFormat(standardFormatWithSampleRate: mixRate, channels: 1)!

    // MARK: source pool

    private final class Source {
        let player = AVAudioPlayerNode()
        var gen: UInt32 = 0
        var looped = false
        var distMult: Float = 0
        // Bumped on every schedule AND on release: completion handlers
        // capture the epoch and no-op if the source has moved on, so a
        // node is returned to the pool exactly once per playback.
        var epoch: UInt64 = 0
        // One-shots/sentences: expected playback end (+margin). The
        // per-frame sweep reclaims the node even if the completion
        // handler was dropped (stop/reroute can eat .dataPlayedBack).
        var deadline: DispatchTime = .distantFuture
    }

    private static let poolSize = 40
    private var pool: [Source] = []
    private var byChannel: [Int32: Source] = [:]   // engine channel idx → source
    private var bySentence: [Int32: Source] = [:]  // sentence slot → source
    private var listenerPos = SIMD3<Float>(0, 0, 0)

    // Looping channels beyond hearing range are PARKED: their node returns
    // to the pool and this record revives them on approach. HL maps keep
    // dozens of ambient loops alive at once — far more than we can (or
    // need to) render concurrently; the engine's own mixer culls the same
    // way via its inaudible-channel skip.
    private struct LoopInfo {
        var gen: UInt32
        var handle: Int32
        var entnum: Int32
        var pitch: Int32
        var distMult: Float
        var volume: Float
        var origin: SIMD3<Float>
    }
    private var loopInfo: [Int32: LoopInfo] = [:]   // active loops (node held)
    private var parkedLoops: [Int32: LoopInfo] = [:]
    private static let parkDistance: Float = 26.0   // meters, scaled space
    private static let reviveDistance: Float = 24.0 // hysteresis

    // Freed loops linger here briefly, still playing: the engine's
    // STOP+EMIT refresh pattern (trains, doors) frees the channel a tick
    // before restarting the same sound — adopting from limbo keeps the
    // audio continuous instead of restarting the wav from sample 0.
    private var limboLoops: [(source: Source, info: LoopInfo, deadline: DispatchTime)] = []
    private static let limboSeconds = 0.25

    // One-shots/sentences evicted from the maps above while still playing
    // (their engine channel was reused) drain here until their deadline.
    // Without this they leak: .dataPlayedBack completions are unreliable
    // and the sweep only walks the live maps.
    private var draining: [(source: Source, deadline: DispatchTime)] = []

    // Decoded mono Float32 PCM per engine sfx handle.
    private struct CachedSound {
        var samples: [Float]
        var rate: Double
        var loopStart: Int
    }
    private var cache: [Int32: CachedSound] = [:]

    // MARK: registration (call BEFORE engine init)

    func register() {
        engine.attach(env)
        // HRTF rendering REQUIRES a stereo output — never let the
        // connection negotiate anything else. .headphones: the AVP
        // speakers are acoustically near-ear drivers.
        let stereo = AVAudioFormat(standardFormatWithSampleRate: Self.mixRate, channels: 2)
        engine.connect(env, to: engine.mainMixerNode, format: stereo)
        env.outputType = .headphones
        env.distanceAttenuationParameters.distanceAttenuationModel = .linear
        env.distanceAttenuationParameters.referenceDistance = 0.3
        env.distanceAttenuationParameters.maximumDistance = 25.4 // 1000 units
        for _ in 0..<Self.poolSize {
            let s = Source()
            engine.attach(s.player)
            engine.connect(s.player, to: env, format: mixFormat)
            s.player.renderingAlgorithm = .HRTFHQ
            pool.append(s)
        }
        do {
            try engine.start()
        } catch {
            print("[LambdaVision] spatial audio: engine start failed (\(error)), stock sound only")
            return
        }

        var cbs = lambda_spatial_callbacks_t(
            channel_start: { idx, gen, handle, pcm, sizeBytes, samples, loopStart, rate, width, channels, origin, distMult, entnum, volume, pitch, looped in
                SpatialAudioEngine.shared.onChannelStart(
                    idx: idx, gen: gen, handle: handle,
                    pcm: pcm, sizeBytes: sizeBytes, samples: samples,
                    loopStart: loopStart, rate: rate,
                    width: width, channels: channels,
                    origin: SpatialAudioEngine.v3(origin), distMult: distMult,
                    entnum: entnum, volume: volume, pitch: pitch,
                    looped: looped != 0)
            },
            sentence_start: { slot, words, count, origin, distMult, _, volume in
                SpatialAudioEngine.shared.onSentenceStart(
                    slot: slot, words: words, count: count,
                    origin: SpatialAudioEngine.v3(origin),
                    distMult: distMult, volume: volume)
            },
            channel_update: { idx, gen, origin, volume in
                SpatialAudioEngine.shared.onChannelUpdate(
                    idx: idx, gen: gen,
                    origin: SpatialAudioEngine.v3(origin), volume: volume)
            },
            channel_free: { idx, gen in
                SpatialAudioEngine.shared.onChannelFree(idx: idx, gen: gen)
            },
            sentence_move: { slot, origin in
                SpatialAudioEngine.shared.onSentenceMove(
                    slot: slot, origin: SpatialAudioEngine.v3(origin))
            },
            listener_update: { origin, forward, _, up in
                SpatialAudioEngine.shared.onListener(
                    origin: SpatialAudioEngine.v3(origin),
                    forward: SpatialAudioEngine.v3(forward),
                    up: SpatialAudioEngine.v3(up))
            },
            sfx_free: { handle in
                SpatialAudioEngine.shared.onSfxFree(handle: handle)
            })
        lambda_spatial_set_callbacks(&cbs)
        running = true
        print("[LambdaVision] spatial audio: AVAudioEnvironmentNode ready (HRTF)")
    }

    private static func v3(_ p: UnsafePointer<Float>?) -> SIMD3<Float> {
        guard let p else { return .zero }
        return SIMD3(p[0], p[1], p[2])
    }

    // MARK: PCM decode (u8/s16, mono-downmix, optional nearest resample for pitch)

    private static func decode(pcm: UnsafeRawPointer, sizeBytes: Int,
                               samples: Int, width: Int, channels: Int) -> [Float] {
        let frames = min(samples, width > 0 && channels > 0 ? sizeBytes / (width * channels) : 0)
        var out = [Float](repeating: 0, count: frames)
        if width == 2 {
            let s16 = pcm.bindMemory(to: Int16.self, capacity: frames * channels)
            for i in 0..<frames {
                var v = Float(s16[i * channels])
                if channels == 2 { v = (v + Float(s16[i * 2 + 1])) * 0.5 }
                out[i] = v / 32768.0
            }
        } else {
            let u8 = pcm.bindMemory(to: UInt8.self, capacity: frames * channels)
            for i in 0..<frames {
                var v = Float(u8[i * channels]) - 128.0
                if channels == 2 { v = (v + Float(u8[i * 2 + 1]) - 128.0) * 0.5 }
                out[i] = v / 128.0
            }
        }
        return out
    }

    /// Linear-interp resample from the wav's native rate to mixRate, with
    /// HL's pitch shift (percent, 100 = normal) folded into the same step —
    /// the engine's mixer pitches the same way, by stepping the read
    /// cursor faster.
    private static func resample(_ samples: [Float], from rate: Double,
                                 pitch: Int) -> [Float] {
        let step = (rate / mixRate) * (Double(max(pitch, 1)) / 100.0)
        if abs(step - 1.0) < 0.0001 { return samples }
        let outCount = Int(Double(samples.count) / step)
        guard outCount > 0 else { return samples }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * step
            let j = min(Int(pos), samples.count - 1)
            let k = min(j + 1, samples.count - 1)
            let f = Float(pos - Double(j))
            out[i] = samples[j] + (samples[k] - samples[j]) * f
        }
        return out
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: $0.count) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        return buf
    }

    // MARK: source management (control queue only)

    private func acquireSource() -> Source? {
        pool.popLast()
    }

    private func release(_ s: Source) {
        s.epoch &+= 1 // invalidate any pending completion handlers
        s.player.stop()
        s.gen = 0
        s.looped = false
        s.deadline = .distantFuture
        pool.append(s)
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }

    /// HL linear attenuation via distance scaling (see file header).
    /// A single NaN position on ANY input silences the environment
    /// node's whole mix — never let one through.
    private func place(_ s: Source, worldPos: SIMD3<Float>) {
        let rel = (worldPos - listenerPos) * s.distMult * 1000.0
        let p = (listenerPos + rel) * Self.metersPerUnit
        guard Self.isFinite(p), simd_length_squared(p) < 1e10 else { return }
        s.player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    /// Distance in the scaled (attenuation-corrected) space, meters.
    private func scaledDistance(_ worldPos: SIMD3<Float>, distMult: Float) -> Float {
        simd_length((worldPos - listenerPos) * distMult * 1000.0) * Self.metersPerUnit
    }

    /// Schedule a loop: intro once (up to loop_start), then loop the tail.
    private func scheduleLoop(_ s: Source, sound: CachedSound, pitch: Int32) {
        let samples = Self.resample(sound.samples, from: sound.rate, pitch: Int(pitch))
        // loop_start is in native frames — rescale into the output.
        let step = (sound.rate / Self.mixRate) * (Double(max(Int(pitch), 1)) / 100.0)
        let loopStart = Int(Double(sound.loopStart) / step)
        if loopStart > 0, loopStart < samples.count {
            let intro = Array(samples[0..<loopStart])
            let tail = Array(samples[loopStart...])
            if let ib = makeBuffer(intro), let tb = makeBuffer(tail) {
                s.player.scheduleBuffer(ib)
                s.player.scheduleBuffer(tb, at: nil, options: .loops)
            }
        } else if let buf = makeBuffer(samples) {
            s.player.scheduleBuffer(buf, at: nil, options: .loops)
        }
    }

    // MARK: callbacks (arrive on GL worker; copy, then hop)

    private func onChannelStart(idx: Int32, gen: UInt32, handle: Int32,
                                pcm: UnsafeRawPointer?, sizeBytes: UInt32,
                                samples: UInt32, loopStart: UInt32, rate: UInt32,
                                width: Int32, channels: Int32,
                                origin: SIMD3<Float>, distMult: Float,
                                entnum: Int32, volume: Float, pitch: Int32,
                                looped: Bool) {
        guard running, let pcm else { return }
        // NaN/garbage anywhere would poison the whole env-node mix.
        guard Self.isFinite(origin), volume.isFinite, distMult.isFinite else { return }
        // Decode (or reuse) synchronously — the pointer dies after return.
        let sound: CachedSound
        if let cached = queue.sync(execute: { cache[handle] }) {
            sound = cached
        } else {
            let decoded = Self.decode(pcm: pcm, sizeBytes: Int(sizeBytes),
                                      samples: Int(samples),
                                      width: Int(width), channels: Int(channels))
            sound = CachedSound(samples: decoded, rate: Double(rate),
                                loopStart: Int(loopStart))
            queue.sync { cache[handle] = sound }
        }

        queue.async { [self] in
            // Slot reuse: detach whatever was there. Playing loops go to
            // limbo (the restart may be a refresh of the SAME sound, which
            // the adoption path below picks up seamlessly); one-shots keep
            // playing in `draining` until their deadline.
            if let old = byChannel.removeValue(forKey: idx) {
                old.epoch &+= 1 // sweep owns it now; stale completions no-op
                if old.looped, let info = loopInfo[idx] {
                    limboLoops.append((old, info, .now() + Self.limboSeconds))
                } else if old.looped {
                    release(old)
                } else {
                    draining.append((old, old.deadline))
                }
            }
            loopInfo.removeValue(forKey: idx)
            parkedLoops.removeValue(forKey: idx)

            if looped {
                var info = LoopInfo(gen: gen, handle: handle, entnum: entnum,
                                    pitch: pitch, distMult: distMult,
                                    volume: volume, origin: origin)

                // The engine RESTARTS an emitter's loop for pitch/origin
                // refreshes (trains do this constantly via STOP+EMIT,
                // often landing on a different channel index). Restarting
                // from sample 0 every time renders slow-attack rumbles
                // inaudible — rebind or adopt the existing playback.
                if let oldIdx = loopInfo.first(where: {
                        $0.value.entnum == entnum && $0.value.handle == handle
                   })?.key,
                   let s = byChannel[oldIdx] {
                    byChannel.removeValue(forKey: oldIdx)
                    loopInfo.removeValue(forKey: oldIdx)
                    s.gen = gen
                    s.distMult = distMult
                    s.player.volume = volume
                    place(s, worldPos: origin)
                    info.gen = gen
                    byChannel[idx] = s
                    loopInfo[idx] = info
                    return
                }
                if let li = limboLoops.firstIndex(where: {
                        $0.info.entnum == entnum && $0.info.handle == handle
                   }) {
                    let adopted = limboLoops.remove(at: li)
                    let s = adopted.source
                    s.gen = gen
                    s.distMult = distMult
                    s.player.volume = volume
                    place(s, worldPos: origin)
                    info.gen = gen
                    byChannel[idx] = s
                    loopInfo[idx] = info
                    return
                }
                if let oldIdx = parkedLoops.first(where: {
                        $0.value.entnum == entnum && $0.value.handle == handle
                   })?.key {
                    parkedLoops.removeValue(forKey: oldIdx)
                    // fall through to distance check with fresh params
                }

                // Out-of-range loops start parked — maps spawn dozens of
                // ambient loops at once, most far away.
                if scaledDistance(origin, distMult: distMult) > Self.parkDistance {
                    parkedLoops[idx] = info
                    return
                }
                guard let s = acquireSource() else {
                    parkedLoops[idx] = info // retry via channel_update
                    return
                }
                s.gen = gen
                s.looped = true
                s.distMult = distMult
                s.epoch &+= 1
                s.deadline = .distantFuture
                s.player.volume = volume
                place(s, worldPos: origin)
                scheduleLoop(s, sound: sound, pitch: pitch)
                loopInfo[idx] = info
                byChannel[idx] = s
                s.player.play()
                return
            }

            // Beyond the falloff radius the sound is inaudible — don't
            // spend a node on it (map scripts fire one-shots map-wide).
            if distMult > 0,
               scaledDistance(origin, distMult: distMult) > env.distanceAttenuationParameters.maximumDistance {
                return
            }
            guard let s = acquireSource() else {
                print("[LambdaVision] spatial audio: source pool dry, dropping sound")
                return
            }
            let samples = Self.resample(sound.samples, from: sound.rate, pitch: Int(pitch))
            guard let buf = makeBuffer(samples) else {
                release(s); return
            }
            s.gen = gen
            s.looped = false
            s.distMult = distMult
            s.epoch &+= 1
            let epoch = s.epoch
            s.deadline = .now() + Double(samples.count) / Self.mixRate + 0.5
            s.player.volume = volume
            place(s, worldPos: origin)
            s.player.scheduleBuffer(buf, at: nil,
                                    completionCallbackType: .dataPlayedBack) { [weak self, weak s] _ in
                guard let self, let s else { return }
                self.queue.async {
                    guard s.epoch == epoch else { return } // superseded
                    if self.byChannel[idx] === s { self.byChannel.removeValue(forKey: idx) }
                    self.release(s)
                }
            }
            byChannel[idx] = s
            s.player.play()
        }
    }

    private func onSentenceStart(slot: Int32, words: UnsafePointer<lambda_spatial_word_t>?,
                                 count: Int32, origin: SIMD3<Float>,
                                 distMult: Float, volume: Float) {
        guard running, let words, count > 0,
              Self.isFinite(origin), volume.isFinite, distMult.isFinite else { return }
        // Stitch synchronously (PCM pointers die after return): trim, gain,
        // and resample each word to the mix rate; mixed source rates are
        // fine since every word converts independently.
        var stitched: [Float] = []
        for i in 0..<Int(count) {
            let w = words[i]
            guard let pcm = w.pcm, w.rate > 0 else { continue }
            var s = Self.decode(pcm: pcm, sizeBytes: Int(w.size_bytes),
                                samples: Int(w.samples),
                                width: Int(w.width), channels: Int(w.channels))
            let lo = min(Int(w.start), 99) * s.count / 100
            let hi = max(lo + 1, Int(w.end) * s.count / 100)
            s = Array(s[lo..<min(hi, s.count)])
            s = Self.resample(s, from: Double(w.rate), pitch: Int(w.pitch))
            let gain = Float(w.volume) / 100.0
            if gain != 1.0 { for j in 0..<s.count { s[j] *= gain } }
            stitched.append(contentsOf: s)
        }
        guard !stitched.isEmpty else { return }

        queue.async { [self] in
            // Round-robin slot reuse: the previous sentence may still be
            // playing legitimately — drain it, don't cut it.
            if let old = bySentence.removeValue(forKey: slot) {
                old.epoch &+= 1
                draining.append((old, old.deadline))
            }
            guard let s = acquireSource() else {
                print("[LambdaVision] spatial audio: source pool dry, dropping sentence")
                return
            }
            guard let buf = makeBuffer(stitched) else {
                release(s); return
            }
            s.distMult = distMult
            s.looped = false
            s.epoch &+= 1
            let epoch = s.epoch
            s.deadline = .now() + Double(stitched.count) / Self.mixRate + 0.5
            s.player.volume = volume
            place(s, worldPos: origin)
            s.player.scheduleBuffer(buf, at: nil,
                                    completionCallbackType: .dataPlayedBack) { [weak self, weak s] _ in
                guard let self, let s else { return }
                self.queue.async {
                    guard s.epoch == epoch else { return } // superseded
                    if self.bySentence[slot] === s { self.bySentence.removeValue(forKey: slot) }
                    self.release(s)
                }
            }
            bySentence[slot] = s
            s.player.play()
        }
    }

    private func onChannelUpdate(idx: Int32, gen: UInt32, origin: SIMD3<Float>, volume: Float) {
        guard running, Self.isFinite(origin), volume.isFinite else { return }
        queue.async { [self] in
            // Parked loop: revive when back in range (with hysteresis).
            if var info = parkedLoops[idx], info.gen == gen {
                info.origin = origin
                info.volume = volume
                if scaledDistance(origin, distMult: info.distMult) < Self.reviveDistance,
                   let sound = cache[info.handle],
                   let s = acquireSource() {
                    parkedLoops.removeValue(forKey: idx)
                    s.gen = gen
                    s.looped = true
                    s.distMult = info.distMult
                    s.epoch &+= 1
                    s.deadline = .distantFuture
                    s.player.volume = volume
                    place(s, worldPos: origin)
                    scheduleLoop(s, sound: sound, pitch: info.pitch)
                    loopInfo[idx] = info
                    byChannel[idx] = s
                    s.player.play()
                } else {
                    parkedLoops[idx] = info
                }
                return
            }

            guard let s = byChannel[idx], s.gen == gen else { return }
            s.player.volume = volume
            place(s, worldPos: origin)

            // Active loop drifting out of range → park, free the node.
            if var info = loopInfo[idx], info.gen == gen {
                info.origin = origin
                info.volume = volume
                if scaledDistance(origin, distMult: info.distMult) > Self.parkDistance {
                    byChannel.removeValue(forKey: idx)
                    loopInfo.removeValue(forKey: idx)
                    release(s)
                    parkedLoops[idx] = info
                } else {
                    loopInfo[idx] = info
                }
            }
        }
    }

    private func onChannelFree(idx: Int32, gen: UInt32) {
        guard running else { return }
        queue.async { [self] in
            if let parked = parkedLoops[idx], parked.gen == gen {
                parkedLoops.removeValue(forKey: idx)
                return
            }
            guard let s = byChannel[idx], s.gen == gen else { return }
            byChannel.removeValue(forKey: idx)
            if s.looped {
                // Into limbo, still playing: the engine's STOP+EMIT
                // refresh may restart this sound within a tick (adopted
                // above); truly-stopped loops are released on expiry.
                if let info = loopInfo[idx] {
                    limboLoops.append((s, info, .now() + Self.limboSeconds))
                } else {
                    release(s)
                }
            } else {
                // One-shots keep playing (the engine frees muted channels
                // 0.1s in — this is not a stop request), but stay tracked:
                // completion handlers are unreliable under load, and a
                // node outside all containers leaks if its handler drops.
                s.epoch &+= 1
                draining.append((s, s.deadline))
            }
            loopInfo.removeValue(forKey: idx)
        }
    }

    private func onSentenceMove(slot: Int32, origin: SIMD3<Float>) {
        guard running, Self.isFinite(origin) else { return }
        queue.async { [self] in
            guard let s = bySentence[slot] else { return }
            place(s, worldPos: origin)
        }
    }

    private func onListener(origin: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        guard running else { return }
        queue.async { [self] in
            // Expire limbo loops nobody re-adopted.
            let now = DispatchTime.now()
            while let i = limboLoops.firstIndex(where: { $0.deadline < now }) {
                release(limboLoops.remove(at: i).source)
            }
            while let i = draining.firstIndex(where: { $0.deadline < now }) {
                release(draining.remove(at: i).source)
            }
            // Backstop sweep: reclaim finished one-shots/sentences whose
            // .dataPlayedBack completion never fired (stop() and engine
            // graph interruptions can silently drop those callbacks).
            for (idx, s) in byChannel where !s.looped && s.deadline < now {
                byChannel.removeValue(forKey: idx)
                release(s)
            }
            for (slot, s) in bySentence where s.deadline < now {
                bySentence.removeValue(forKey: slot)
                release(s)
            }
            // Reject degenerate poses (all-zero during map load, NaN):
            // an invalid listener orientation silences the environment
            // node — permanently, if NaN gets into its internal state.
            let fLen = simd_length(forward), uLen = simd_length(up)
            guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
                  fLen.isFinite, uLen.isFinite,
                  fLen > 0.5, uLen > 0.5 else { return }
            listenerPos = origin
            let p = origin * Self.metersPerUnit
            env.listenerPosition = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
            env.listenerVectorOrientation = AVAudio3DVectorOrientation(
                forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
                up: AVAudio3DVector(x: up.x, y: up.y, z: up.z))
        }
    }

    private func onSfxFree(handle: Int32) {
        queue.async { [self] in
            cache.removeValue(forKey: handle)
        }
    }
}
