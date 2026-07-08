//
//  PhaseAudioEngine.swift
//  LambdaVision
//
//  Per-source spatial rendering for engine sound channels via PHASE
//  (Apple's Physical Audio Spatialization Engine), fed by
//  Lambda_SpatialAudio.c through the same callback table the parked
//  AVAudioEnvironmentNode renderer used (see SpatialAudioEngine.swift).
//  That node outputs silence on visionOS 26; PHASE renders behind the
//  identical plumbing. The engine's own stereo mix ("the bed": music, UI,
//  player-own sounds) keeps playing through the AudioQueue backend.
//
//  Space: xash world basis (right-handed, +Z up), scaled inches→meters.
//  The listener transform is built from the game camera's forward/up
//  (already head-tracked), and automatic head tracking is DISABLED on the
//  listener so PHASE doesn't double-apply the headset pose. This is what
//  detaches game audio from the 2D window — the listener is our camera,
//  not the window.
//
//  Loudness is entirely ours: sources sit on a fixed-radius sphere (real
//  direction for HRTF, constant distance so PHASE's distance/near-field
//  response never varies) and HL's linear attenuation is folded into
//  source.gain. See ../.claude/research/visionos-spatial-audio.md for why
//  this is PARKED (enabled=false) — the whole saga and dead ends.
//
//  Callbacks arrive on the GL worker; PCM is copied synchronously, then
//  all PHASE-graph work hops to a serial control queue.
//

import PHASE
import AVFAudio
import simd

// @unchecked: all mutable state is confined to the serial control queue.
nonisolated final class PhaseAudioEngine: @unchecked Sendable {
    // PHASE is disabled: on visionOS its engine output was uncontrollably
    // hot here (deafening) even with the system spatializer confirmed
    // bypassed and every source/listener/calibration knob exhausted. The
    // stock xash mixer already does head-tracked L/R panning (HL's own
    // positional model) and, with AVAudioSession .bypassed, plays
    // head-locked through the AudioQueue — no window-pinning, no deafening.
    // Kept in the tree in case a future visionOS makes PHASE viable.
    static let enabled = false

    nonisolated(unsafe) static let shared = PhaseAudioEngine()

    private static let metersPerUnit: Float = 0.0254

    private let queue = DispatchQueue(label: "com.illixion.LambdaVision.phaseaudio")
    private let engine = PHASEEngine(updateMode: .automatic)
    private var listener: PHASEListener!
    private var spatialMixer: PHASESpatialMixerDefinition!
    private static let mixerID = "spatialMixer"
    private var running = false

    // MARK: source pool

    // A reusable positioned scene object. Each playback creates a transient
    // PHASESoundEvent bound to this source + the shared listener; the source
    // itself is repositioned and re-gained across playbacks.
    private final class Source {
        let src: PHASESource
        var event: PHASESoundEvent?
        var gen: UInt32 = 0
        var looped = false
        var distMult: Float = 0
        var baseVolume: Float = 1   // master_vol (pre-attenuation)
        // Bumped on every (re)schedule AND on release: completion handlers
        // capture the epoch and no-op if the source has moved on.
        var epoch: UInt64 = 0
        // One-shots/sentences: expected end (+margin). The per-frame sweep
        // reclaims the node even if the completion callback was dropped.
        var deadline: DispatchTime = .distantFuture
        // True while parked in the pool. Guards against double-release: a
        // source released twice would sit in the pool twice, get handed to
        // two concurrent sound events, and orphan the earlier one (playing
        // forever, uncontrolled) — the deafening never-freed drone.
        var pooled = true
        init(engine: PHASEEngine) { src = PHASESource(engine: engine) }
    }

    private static let poolSize = 40
    private var pool: [Source] = []
    private var byChannel: [Int32: Source] = [:]   // engine channel idx → source
    private var bySentence: [Int32: Source] = [:]  // sentence slot → source
    private var listenerPos = SIMD3<Float>(0, 0, 0)

    // Looping channels beyond hearing range are PARKED (node returned to the
    // pool, revived on approach). HL maps keep dozens of ambient loops alive
    // — more than we render concurrently; the stock mixer culls the same way.
    private struct LoopInfo {
        var gen: UInt32
        var handle: Int32
        var entnum: Int32
        var distMult: Float
        var volume: Float
        var origin: SIMD3<Float>
    }
    private var loopInfo: [Int32: LoopInfo] = [:]
    private var parkedLoops: [Int32: LoopInfo] = [:]
    // HL attenuation is silent at unit-distance |Δ|·dist_mult >= 1. Park
    // loops a hair past that; revive with hysteresis. One-shots past 1.0
    // are inaudible and skipped.
    private static let parkUnitDist: Float = 1.05
    private static let reviveUnitDist: Float = 0.9

    // Freed loops linger here briefly, still playing: the engine's STOP+EMIT
    // refresh (trains, doors) frees the channel a tick before restarting the
    // same sound — adopting from limbo keeps audio continuous.
    private var limboLoops: [(source: Source, info: LoopInfo, deadline: DispatchTime)] = []
    private static let limboSeconds = 0.25

    // One-shots/sentences evicted while still playing drain here to deadline.
    private var draining: [(source: Source, deadline: DispatchTime)] = []

    // Decoded mono Float32 PCM per engine sfx handle.
    private struct CachedSound {
        var samples: [Float]
        var rate: Double
        var loopStart: Int
    }
    private var cache: [Int32: CachedSound] = [:]

    // Which PHASE asset identifiers we've registered (registering a
    // duplicate identifier throws). Sound assets are keyed by sfx handle;
    // sound-event assets by (handle, looped).
    private var soundAssets = Set<Int32>()
    private var eventAssets = Set<String>()
    // Unique id generator for transient (per-instance) sentence assets.
    private var transientCounter: UInt64 = 0

    // Base linear gain for the sampler's .none calibration (see ensureEventAsset).
    private static let samplerGain: Float = 1.0

    // MARK: registration (call BEFORE engine init)

    private var didRegister = false

    func register() {
        // Idempotent: the immersive-space lifecycle can run the render-loop
        // start (and thus this) more than once. A second pass built a second
        // engine graph — two listeners and two spatial mixers sharing the
        // "spatialMixer" identifier, so every sound routed through BOTH mixer
        // paths and played doubled/deafening (pool grew to ~80). Run once.
        if didRegister { return }
        didRegister = true
        engine.unitsPerMeter = 1.0

        // Output our OWN binaural mix directly. The default (.automatic)
        // lets visionOS re-spatialize the app's audio anchored to the 2D
        // window — so PHASE's already-binaural output got double-spatialized
        // and proximity-boosted to a deafening level when the window was
        // open, and vanished when it was closed (no window = no anchor).
        // We drive the listener from the head-tracked game camera ourselves;
        // .alwaysUseBinaural bypasses the system layer entirely.
        engine.outputSpatializationMode = .alwaysUseBinaural

        // Spatial pipeline: direct path only for now (no early reflections
        // or reverb — the game has no room geometry to feed PHASE).
        guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission]) else {
            print("[LambdaVision] PHASE: spatial pipeline init failed, stock sound only")
            return
        }
        pipeline.entries[.directPathTransmission]?.sendLevel = 1.0

        spatialMixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline,
                                                   identifier: Self.mixerID)
        // FLAT distance model (rolloffFactor 0 → no distance-based gain).
        // PHASE's geometric spreading is inverse-distance, so a source at
        // the listener (on-player loops like the tram) would blow the gain
        // up into clipping ("brown noise"). Instead we place sources at
        // their true positions for correct direction/HRTF and fold HL's
        // own LINEAR attenuation into source.gain ourselves (applySpatial).
        // The engine only hands us master_vol, not an attenuated volume, so
        // reproducing HL's curve is our job either way.
        let dm = PHASEGeometricSpreadingDistanceModelParameters()
        dm.rolloffFactor = 0.0
        spatialMixer.distanceModelParameters = dm

        listener = PHASEListener(engine: engine)
        // We drive the listener transform from the game camera each frame;
        // that camera is ALREADY head-tracked. Let PHASE also head-track and
        // the headset pose applies twice → audio swims. Off.
        listener.automaticHeadTrackingFlags = []
        listener.transform = matrix_identity_float4x4
        do {
            try engine.rootObject.addChild(listener)
        } catch {
            print("[LambdaVision] PHASE: addChild(listener) failed (\(error)), stock sound only")
            return
        }

        for _ in 0..<Self.poolSize {
            let s = Source(engine: engine)
            try? engine.rootObject.addChild(s.src)
            pool.append(s)
        }

        do {
            try engine.start()
        } catch {
            print("[LambdaVision] PHASE: engine start failed (\(error)), stock sound only")
            return
        }

        var cbs = lambda_spatial_callbacks_t(
            channel_start: { idx, gen, handle, pcm, sizeBytes, samples, loopStart, rate, width, channels, origin, distMult, entnum, volume, pitch, looped in
                PhaseAudioEngine.shared.onChannelStart(
                    idx: idx, gen: gen, handle: handle,
                    pcm: pcm, sizeBytes: sizeBytes, samples: samples,
                    loopStart: loopStart, rate: rate,
                    width: width, channels: channels,
                    origin: PhaseAudioEngine.v3(origin), distMult: distMult,
                    entnum: entnum, volume: volume, looped: looped != 0)
            },
            sentence_start: { slot, words, count, origin, distMult, _, volume in
                PhaseAudioEngine.shared.onSentenceStart(
                    slot: slot, words: words, count: count,
                    origin: PhaseAudioEngine.v3(origin),
                    distMult: distMult, volume: volume)
            },
            channel_update: { idx, gen, origin, volume in
                PhaseAudioEngine.shared.onChannelUpdate(
                    idx: idx, gen: gen,
                    origin: PhaseAudioEngine.v3(origin), volume: volume)
            },
            channel_free: { idx, gen in
                PhaseAudioEngine.shared.onChannelFree(idx: idx, gen: gen)
            },
            sentence_move: { slot, origin in
                PhaseAudioEngine.shared.onSentenceMove(
                    slot: slot, origin: PhaseAudioEngine.v3(origin))
            },
            listener_update: { origin, forward, _, up in
                PhaseAudioEngine.shared.onListener(
                    origin: PhaseAudioEngine.v3(origin),
                    forward: PhaseAudioEngine.v3(forward),
                    up: PhaseAudioEngine.v3(up))
            },
            sfx_free: { handle in
                PhaseAudioEngine.shared.onSfxFree(handle: handle)
            })
        lambda_spatial_set_callbacks(&cbs)
        running = true
        print("[LambdaVision] PHASE spatial audio ready")
    }

    private static func v3(_ p: UnsafePointer<Float>?) -> SIMD3<Float> {
        guard let p else { return .zero }
        return SIMD3(p[0], p[1], p[2])
    }

    // MARK: PCM decode (u8/s16 → mono Float32)

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

    /// Linear-interp resample (used only for sentence words — world sounds
    /// register at native rate and ignore HL pitch shift for v1).
    private static func resample(_ samples: [Float], from rate: Double,
                                 toRate: Double, pitch: Int) -> [Float] {
        let step = (rate / toRate) * (Double(max(pitch, 1)) / 100.0)
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

    // MARK: PHASE asset registration (control queue only)

    /// Canonical PCM for PHASE: single-channel INTERLEAVED Int16. Float32
    /// non-interleaved (the previous format) is the least-tested path and
    /// renders as noise here; Int16 interleaved is what every wav — and the
    /// AudioQueue bed — already uses.
    private static func pcm16(_ samples: [Float]) -> Data {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i]))
            out[i] = Int16(v * 32767)
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func int16Format(_ rate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                      channels: 1, interleaved: true)
    }

    /// Register (once) a mono Int16 sound asset for this sfx handle.
    private func ensureSoundAsset(handle: Int32, samples: [Float], rate: Double) -> String? {
        let id = "snd\(handle)"
        if soundAssets.contains(handle) { return id }
        guard !samples.isEmpty, let fmt = Self.int16Format(rate) else { return nil }
        let data = Self.pcm16(samples)
        do {
            _ = try engine.assetRegistry.registerSoundAsset(
                data: data, identifier: id, format: fmt, normalizationMode: .none)
            soundAssets.insert(handle)
            return id
        } catch {
            print("[LambdaVision] PHASE: registerSoundAsset(\(handle)) failed: \(error)")
            return nil
        }
    }

    /// Register (once) a sound-event asset (sampler → spatial mixer) for
    /// this (handle, looped) pair, returning its identifier.
    private func ensureEventAsset(soundID: String, handle: Int32, looped: Bool) -> String? {
        let id = "ev\(handle)_\(looped ? 1 : 0)"
        if eventAssets.contains(id) { return id }
        let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: soundID,
                                                 mixerDefinition: spatialMixer)
        sampler.playbackMode = looped ? .looping : .oneShot
        sampler.cullOption = .sleepWakeAtRealtimeOffset
        // .none = pure LINEAR gain, no SPL loudness model. The SPL modes
        // (relativeSpl/absoluteSpl) render sounds far hotter than 0 dBFS —
        // a single source clipped the output regardless of source/listener
        // gain. We do our own HL attenuation, so we want a flat linear base.
        sampler.setCalibrationMode(calibrationMode: .none, level: Double(Self.samplerGain))
        do {
            _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: id)
            eventAssets.insert(id)
            return id
        } catch {
            print("[LambdaVision] PHASE: registerSoundEventAsset(\(id)) failed: \(error)")
            return nil
        }
    }

    // MARK: lifecycle

    // Tie PHASE to the render loop: when the immersive space is hidden the
    // GL worker stops ticking, so no channel_free/update callbacks fire and
    // loops would sustain forever (PHASE runs on its own thread, unlike the
    // AudioQueue bed which lambda_snd_activate pauses). Stop the engine on
    // hide, restart on show. Called from Renderer alongside lambda_snd_activate.
    func setActive(_ active: Bool) {
        queue.async { [self] in
            guard running else { return }
            if active { try? engine.start() }
            else { engine.stop() }
        }
    }

    // MARK: source management (control queue only)

    private func acquireSource() -> Source? {
        guard let s = pool.popLast() else { return nil }
        s.pooled = false
        return s
    }

    /// Guarantee at most one live loop per (entnum, handle): stop any
    /// existing instance across every container before starting a fresh one.
    /// The adopt/rebind paths already reuse a match seamlessly and return
    /// before reaching this; it only fires when they missed (first-boot
    /// startup races), preventing the loop pile-up that stacks into a
    /// deafening, never-freed drone.
    private func stopLoops(entnum: Int32, handle: Int32) {
        for (i, s) in byChannel where s.looped
            && loopInfo[i]?.entnum == entnum && loopInfo[i]?.handle == handle {
            byChannel.removeValue(forKey: i)
            loopInfo.removeValue(forKey: i)
            release(s)
        }
        limboLoops.removeAll {
            if $0.info.entnum == entnum && $0.info.handle == handle {
                release($0.source); return true
            }
            return false
        }
        for (i, info) in parkedLoops where info.entnum == entnum && info.handle == handle {
            parkedLoops.removeValue(forKey: i)
        }
    }

    private func release(_ s: Source) {
        if s.pooled { return } // already released — never double-pool
        s.epoch &+= 1
        s.event?.stopAndInvalidate()
        s.event = nil
        s.gen = 0
        s.looped = false
        s.deadline = .distantFuture
        s.pooled = true
        pool.append(s)
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }

    /// HL's attenuation distance: |Δ|·dist_mult, dimensionless (silent >= 1).
    private func unitDist(_ worldPos: SIMD3<Float>, distMult: Float) -> Float {
        simd_length(worldPos - listenerPos) * distMult
    }

    // Every source sits on a sphere of this radius around the listener:
    // direction is real (for HRTF), distance is constant. This sidesteps
    // PHASE's near-field gain singularity — a source placed AT the listener
    // (first-boot: sound fires while listener is still at the origin and the
    // emitter is near the origin too) gets a huge near-field boost that
    // rolloffFactor=0 does NOT suppress. Loudness is entirely ours, via
    // source.gain (HL's linear curve); PHASE only pans.
    private static let fixedRadiusM: Float = 2.0

    /// Point the source in the emitter's real direction at the fixed radius,
    /// and fold HL's linear attenuation (silent at unit-distance 1) into gain.
    private func applySpatial(_ s: Source, worldPos: SIMD3<Float>) {
        let delta = worldPos - listenerPos
        let distUnits = simd_length(delta)
        let atten = max(0, 1 - distUnits * s.distMult)
        s.src.gain = Double(s.baseVolume * atten)
        let dir = distUnits > 1e-4 ? delta / distUnits : SIMD3<Float>(1, 0, 0)
        let p = listenerPos * Self.metersPerUnit + dir * Self.fixedRadiusM
        guard Self.isFinite(p), simd_length_squared(p) < 1e12 else { return }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        s.src.transform = t
    }

    /// Create + start a sound event on `s` for the given event asset.
    /// completion (one-shots only) hops to the queue and reclaims the node.
    @discardableResult
    private func startEvent(_ s: Source, assetID: String, idx: Int32?, slot: Int32?,
                            epoch: UInt64, oneShot: Bool) -> Bool {
        let mp = PHASEMixerParameters()
        mp.addSpatialMixerParameters(identifier: Self.mixerID, source: s.src, listener: listener)
        let ev: PHASESoundEvent
        do {
            ev = try PHASESoundEvent(engine: engine, assetIdentifier: assetID, mixerParameters: mp)
        } catch {
            print("[LambdaVision] PHASE: soundEvent(\(assetID)) create failed: \(error)")
            return false
        }
        s.event = ev
        ev.start { [weak self, weak s] _ in
            guard oneShot, let self, let s else { return }
            self.queue.async {
                guard s.epoch == epoch else { return } // superseded
                if let idx, self.byChannel[idx] === s { self.byChannel.removeValue(forKey: idx) }
                if let slot, self.bySentence[slot] === s { self.bySentence.removeValue(forKey: slot) }
                self.release(s)
            }
        }
        return true
    }

    // MARK: callbacks (arrive on GL worker; copy, then hop)

    private func onChannelStart(idx: Int32, gen: UInt32, handle: Int32,
                                pcm: UnsafeRawPointer?, sizeBytes: UInt32,
                                samples: UInt32, loopStart: UInt32, rate: UInt32,
                                width: Int32, channels: Int32,
                                origin: SIMD3<Float>, distMult: Float,
                                entnum: Int32, volume: Float, looped: Bool) {
        guard running, let pcm else { return }
        guard Self.isFinite(origin), volume.isFinite, distMult.isFinite else { return }
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
            // Slot reuse: detach whatever was there.
            if let old = byChannel.removeValue(forKey: idx) {
                old.epoch &+= 1
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

            guard let soundID = ensureSoundAsset(handle: handle, samples: sound.samples, rate: sound.rate)
            else { return }

            if looped {
                var info = LoopInfo(gen: gen, handle: handle, entnum: entnum,
                                    distMult: distMult, volume: volume, origin: origin)

                // The engine RESTARTS a loop for pitch/origin refreshes
                // (trains STOP+EMIT constantly). Rebind/adopt the existing
                // playback rather than restart from sample 0.
                if let oldIdx = loopInfo.first(where: {
                        $0.value.entnum == entnum && $0.value.handle == handle
                   })?.key,
                   let s = byChannel[oldIdx] {
                    byChannel.removeValue(forKey: oldIdx)
                    loopInfo.removeValue(forKey: oldIdx)
                    s.gen = gen; s.distMult = distMult; s.baseVolume = volume
                    applySpatial(s, worldPos: origin)
                    info.gen = gen
                    byChannel[idx] = s; loopInfo[idx] = info
                    return
                }
                if let li = limboLoops.firstIndex(where: {
                        $0.info.entnum == entnum && $0.info.handle == handle
                   }) {
                    let s = limboLoops.remove(at: li).source
                    s.gen = gen; s.distMult = distMult; s.baseVolume = volume
                    applySpatial(s, worldPos: origin)
                    info.gen = gen
                    byChannel[idx] = s; loopInfo[idx] = info
                    return
                }
                if let oldIdx = parkedLoops.first(where: {
                        $0.value.entnum == entnum && $0.value.handle == handle
                   })?.key {
                    parkedLoops.removeValue(forKey: oldIdx)
                }

                if unitDist(origin, distMult: distMult) > Self.parkUnitDist {
                    parkedLoops[idx] = info
                    return
                }
                // Reached only when adopt/rebind above missed — kill any
                // stray instance of this exact loop so it can't stack.
                stopLoops(entnum: entnum, handle: handle)
                guard let evID = ensureEventAsset(soundID: soundID, handle: handle, looped: true),
                      let s = acquireSource() else {
                    parkedLoops[idx] = info
                    return
                }
                s.gen = gen; s.looped = true; s.distMult = distMult; s.baseVolume = volume
                s.epoch &+= 1; s.deadline = .distantFuture
                applySpatial(s, worldPos: origin)
                if startEvent(s, assetID: evID, idx: idx, slot: nil, epoch: s.epoch, oneShot: false) {
                    loopInfo[idx] = info
                    byChannel[idx] = s
                } else {
                    release(s)
                    parkedLoops[idx] = info
                }
                return
            }

            // One-shot: skip if inaudible (map scripts fire these map-wide).
            if distMult > 0, unitDist(origin, distMult: distMult) >= 1.0 {
                return
            }
            guard let evID = ensureEventAsset(soundID: soundID, handle: handle, looped: false),
                  let s = acquireSource() else {
                return
            }
            s.gen = gen; s.looped = false; s.distMult = distMult; s.baseVolume = volume
            s.epoch &+= 1
            s.deadline = .now() + Double(sound.samples.count) / sound.rate + 0.5
            applySpatial(s, worldPos: origin)
            if startEvent(s, assetID: evID, idx: idx, slot: nil, epoch: s.epoch, oneShot: true) {
                byChannel[idx] = s
            } else {
                release(s)
            }
        }
    }

    private func onSentenceStart(slot: Int32, words: UnsafePointer<lambda_spatial_word_t>?,
                                 count: Int32, origin: SIMD3<Float>,
                                 distMult: Float, volume: Float) {
        guard running, let words, count > 0,
              Self.isFinite(origin), volume.isFinite, distMult.isFinite else { return }
        // Stitch synchronously (PCM pointers die after return): trim, gain,
        // and resample each word to a common rate. Per-word pitch is kept
        // (sentences are transient assets, so no cache-explosion concern).
        let sentRate: Double = 22050
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
            s = Self.resample(s, from: Double(w.rate), toRate: sentRate, pitch: Int(w.pitch))
            let gain = Float(w.volume) / 100.0
            if gain != 1.0 { for j in 0..<s.count { s[j] *= gain } }
            stitched.append(contentsOf: s)
        }
        guard !stitched.isEmpty else { return }

        queue.async { [self] in
            if let old = bySentence.removeValue(forKey: slot) {
                old.epoch &+= 1
                draining.append((old, old.deadline))
            }
            guard let s = acquireSource() else { return }
            // Transient per-instance assets (unregistered on completion).
            transientCounter &+= 1
            let tag = transientCounter
            let soundID = "sent\(tag)"
            let evID = "sentev\(tag)"
            guard let fmt = Self.int16Format(sentRate) else { release(s); return }
            let data = Self.pcm16(stitched)
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: soundID,
                                                     mixerDefinition: spatialMixer)
            sampler.playbackMode = .oneShot
            sampler.setCalibrationMode(calibrationMode: .none, level: Double(Self.samplerGain))
            do {
                _ = try engine.assetRegistry.registerSoundAsset(
                    data: data, identifier: soundID, format: fmt, normalizationMode: .none)
                _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: evID)
            } catch {
                release(s); return
            }
            s.distMult = distMult; s.looped = false; s.baseVolume = volume
            s.epoch &+= 1
            s.deadline = .now() + Double(stitched.count) / sentRate + 0.5
            applySpatial(s, worldPos: origin)
            let epoch = s.epoch
            let mp = PHASEMixerParameters()
            mp.addSpatialMixerParameters(identifier: Self.mixerID, source: s.src, listener: listener)
            guard let ev = try? PHASESoundEvent(engine: engine, assetIdentifier: evID,
                                                mixerParameters: mp) else {
                unregister(soundID, evID); release(s); return
            }
            s.event = ev
            bySentence[slot] = s
            ev.start { [weak self, weak s] _ in
                guard let self, let s else { return }
                self.queue.async {
                    self.unregister(soundID, evID)
                    guard s.epoch == epoch else { return }
                    if self.bySentence[slot] === s { self.bySentence.removeValue(forKey: slot) }
                    self.release(s)
                }
            }
        }
    }

    private func unregister(_ ids: String...) {
        for id in ids {
            engine.assetRegistry.unregisterAsset(identifier: id, completion: nil)
        }
    }

    private func onChannelUpdate(idx: Int32, gen: UInt32, origin: SIMD3<Float>, volume: Float) {
        guard running, Self.isFinite(origin), volume.isFinite else { return }
        queue.async { [self] in
            if var info = parkedLoops[idx], info.gen == gen {
                info.origin = origin; info.volume = volume
                if unitDist(origin, distMult: info.distMult) < Self.reviveUnitDist,
                   let sound = cache[info.handle],
                   let soundID = ensureSoundAsset(handle: info.handle, samples: sound.samples, rate: sound.rate),
                   let evID = ensureEventAsset(soundID: soundID, handle: info.handle, looped: true),
                   let s = acquireSource() {
                    parkedLoops.removeValue(forKey: idx)
                    stopLoops(entnum: info.entnum, handle: info.handle) // no stacking on revive
                    s.gen = gen; s.looped = true; s.distMult = info.distMult; s.baseVolume = volume
                    s.epoch &+= 1; s.deadline = .distantFuture
                    applySpatial(s, worldPos: origin)
                    if startEvent(s, assetID: evID, idx: idx, slot: nil, epoch: s.epoch, oneShot: false) {
                        loopInfo[idx] = info
                        byChannel[idx] = s
                    } else {
                        release(s); parkedLoops[idx] = info
                    }
                } else {
                    parkedLoops[idx] = info
                }
                return
            }

            guard let s = byChannel[idx], s.gen == gen else { return }
            s.baseVolume = volume
            applySpatial(s, worldPos: origin)

            if var info = loopInfo[idx], info.gen == gen {
                info.origin = origin; info.volume = volume
                if unitDist(origin, distMult: info.distMult) > Self.parkUnitDist {
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
                if let info = loopInfo[idx] {
                    limboLoops.append((s, info, .now() + Self.limboSeconds))
                } else {
                    release(s)
                }
            } else {
                // One-shots play out (engine frees muted channels 0.1s in —
                // not a stop request) but stay tracked so they don't leak.
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
            applySpatial(s, worldPos: origin)
        }
    }

    private func onListener(origin: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        guard running else { return }
        queue.async { [self] in
            let now = DispatchTime.now()
            while let i = limboLoops.firstIndex(where: { $0.deadline < now }) {
                release(limboLoops.remove(at: i).source)
            }
            while let i = draining.firstIndex(where: { $0.deadline < now }) {
                release(draining.remove(at: i).source)
            }
            // Collect-then-remove: mutating a dictionary mid-iteration is
            // unsafe in Swift.
            for idx in byChannel.compactMap({ (k, s) in !s.looped && s.deadline < now ? k : nil }) {
                if let s = byChannel.removeValue(forKey: idx) { release(s) }
            }
            for slot in bySentence.compactMap({ (k, s) in s.deadline < now ? k : nil }) {
                if let s = bySentence.removeValue(forKey: slot) { release(s) }
            }

            let fLen = simd_length(forward), uLen = simd_length(up)
            guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
                  fLen.isFinite, uLen.isFinite, fLen > 0.5, uLen > 0.5 else { return }
            listenerPos = origin
            // Build the listener transform in PHASE's audio basis (local -Z
            // forward, +Y up, +X right) from the game camera's world axes.
            // right = forward × up (xash right-handed: for fwd=+X, up=+Z this
            // is -Y = player's right, matching PHASE +X). If left/right come
            // out mirrored on device, negate `right` (and swap the -forward
            // sign) — the only handedness knob here.
            let f = simd_normalize(forward)
            let u = simd_normalize(up)
            let r = simd_normalize(simd_cross(f, u))
            let p = origin * Self.metersPerUnit
            var t = matrix_identity_float4x4
            t.columns.0 = SIMD4<Float>(r, 0)
            t.columns.1 = SIMD4<Float>(u, 0)
            t.columns.2 = SIMD4<Float>(-f, 0)
            t.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
            listener.transform = t
        }
    }

    private func onSfxFree(handle: Int32) {
        queue.async { [self] in
            cache.removeValue(forKey: handle)
            // Note: PHASE sound/event assets for this handle stay registered
            // (unregistering while an event references them is unsafe); they
            // are reused if the sfx reloads under the same handle.
        }
    }
}
