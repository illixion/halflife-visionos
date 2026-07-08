# visionOS spatial audio — what works, what doesn't (and the PHASE saga)

_Last updated: 2026-07-08. Context: LambdaVision (Half-Life / xash3d-fwgs on Apple Vision Pro)._

## TL;DR — the working configuration

Positional game audio on AVP is delivered by **xash's own stock mixer** (HL-style
head-tracked L/R volume panning) played through the **AudioQueue backend**, with:

1. **`AVAudioSession.setIntendedSpatialExperience(.bypassed)`** — the single most
   important line. Without it visionOS re-spatializes the app's audio and anchors
   it all to the app's **first window** (the "single-anchor" behavior). `.bypassed`
   makes our stereo output play head-locked/unmodified. This alone fixed the
   original "audio pinned to the window" bug.
2. **Small AudioQueue buffers + low mix-ahead** for responsive panning:
   `AQ_FRAMES_PER_BUF 512` (×3 buffers ≈ 35 ms) in `snd_visionos.c`, and
   `_snd_mixahead 0.04` (down from 0.12) set at engine init. The mixer bakes each
   sound's pan into the DMA ring, so paint-ahead == pan latency.
3. **Ring silenced on audio reactivate** (`SNDDMA_Activate` memsets `snd.buffer`
   and resets `samplepos`) so a resume can't replay the stale ring loop.
   **Do NOT `AudioQueueReset` there** — it drops the primed buffers without
   returning them via the callback, starving the queue into permanent silence.

PHASE (`PhaseAudioEngine.swift`) is present but **`enabled = false`** — parked.

## The goal

Per-source spatial audio (ideally HRTF, i.e. up/down cues) instead of xash's flat
L/R pan, plus fixing two visionOS bugs: audio pinned to the 2D window, and a ~1 s
audio loop on resume after suspend.

## Architecture background

- xash exposes a client **SoundAPI** (`common/sound_api.h`). `Lambda_SpatialAudio.c`
  installs it and forwards world sound channels (position, listener pose, sentences)
  to a Swift renderer, while the engine's stock mixer keeps producing the head-locked
  stereo **"bed"** (music, UI, the player's own sounds) into the AudioQueue.
- When the SoundAPI interface is **not** installed, the stock mixer does everything —
  including head-tracked L/R panning of world sounds (it reads the head-tracked
  listener vectors). This is the fallback we ended up shipping.

## Approaches tried

### 1. `AVAudioEnvironmentNode` (pre-existing, `SpatialAudioEngine.swift`)
Renders **silence** on visionOS 26 despite a provably correct graph. Parked before
this round. Its callback plumbing (pool, loop parking, limbo/draining, sentence
stitching) is sound and was reused by the PHASE attempt.

### 2. PHASE (`PhaseAudioEngine.swift`) — the long dead end
Swapped PHASE in behind the same plumbing. It **built and played**, but every
sound was **deafening / heavy clipping**, immune to every gain knob. Root causes
found and fixed *along the way* (all real bugs, worth keeping in mind):

- **AudioQueue starvation** (my own regression): `AudioQueueReset` in
  `SNDDMA_Activate` dropped the primed buffers → total silence. Symptom: "no audio
  at all" with PHASE disabled. Fix: don't reset; just memset the ring.
- **`register()` ran twice** (immersive-space lifecycle re-runs the render-loop
  start) → two engine graphs, two listeners, two spatial mixers sharing one
  identifier → doubled routing, `pool` grew to ~80. Fix: idempotency guard.
  Tell: the `pool` count in the census was ~2× its max.
- **Double-release** of pooled sources → same `PHASESource` handed to two events →
  the earlier one orphaned (plays forever, uncontrolled). Fix: `pooled` flag guard.
- **Near-field gain singularity**: placing a source at the listener's position (a
  sound emitted on the player, e.g. the tram, fired while the listener was still at
  the origin) → PHASE's inverse-distance model → gain → ∞. `rolloffFactor = 0`
  kills far-field rolloff but not this. Fix: fixed-radius placement (direction only).
- **SPL calibration**: samplers play uncalibrated/hot by default; `relativeSpl`
  runs an SPL loudness model that renders above 0 dBFS. Switched to `.none`.

None of these was the real culprit for the deafening. The decisive clue came from
the user: **the deafening was tied to the main window's existence** — window open →
deafening; window closed → *no PHASE audio at all*.

### The real reason PHASE is unusable here
On visionOS the system spatializes the app's audio and anchors it to the window.
PHASE renders **through that system spatializer**, so its already-binaural output
got double-spatialized and proximity-boosted to a deafening level (and had nowhere
to go with no window). We could **not** get out of it:
- `PHASESource.gain`, `PHASEListener.gain`, sampler calibration — no audible effect.
- `engine.outputSpatializationMode = .alwaysUseBinaural` — no change.
- `setIntendedSpatialExperience(.bypassed)` on the session — the log confirmed the
  session stayed `BypassedSpatialExperience()` before AND after PHASE start (PHASE
  did *not* override it), yet PHASE was **still deafening**. So even with the system
  spatializer provably bypassed, PHASE's engine output was uncontrollably hot.

Conclusion: PHASE-alongside-a-2D-window is not viable on visionOS 26 for this app.
Abandoned. Kept in-tree (`enabled=false`) in case a future visionOS changes this.

## Debugging technique that worked

The live `devicectl ... --console` tunnel was unreliable (connection invalidated).
**File-based logging** — append to the app container's `Documents/phasedbg.log`,
then `xcrun devicectl device copy from --domain-type appDataContainer
--domain-identifier <bundle> --source Documents/phasedbg.log --destination ...` —
was robust and let us read counts/asset-stats/session-state after each test.
The **per-second source census** (byChannel/loops/limbo/drain/pool/oneShots) is
what exposed the double-register (`pool≈80`) and proved counts were sane (ruling
out pile-up). A **PHASE-silent switch** (start no events, keep all tracking) cleanly
split "is it PHASE or the bed?".

## Key visionOS learnings (reusable)

- **App audio is window-anchored by default.** `setIntendedSpatialExperience(.bypassed)`
  disables the system spatializer for the app's output (fixes window-pinning for a
  plain AudioQueue/stereo path). `.headTracked(soundStageSize:anchoringStrategy:)`
  is the opposite (opt into system head-tracked spatialization).
- **PHASE routes through the system spatializer** and its level was uncontrollable
  in a windowed immersive app here. Don't assume PHASE's gains reach the output.
- **AudioQueue is a high-latency, buffered API.** Even minimal buffers + low
  mix-ahead leaves audible latency. For tight (<~40 ms) panning, the real fix is a
  low-latency backend (`AVAudioSourceNode` / `AURemoteIO` render callback pulling the
  same lock-free ring) — not yet done.
- **`AudioQueueReset` discards enqueued buffers without a callback** → starvation.
- The stock xash mixer already spatializes with the head-tracked listener, so simply
  *not* installing the SoundAPI gives working head-tracked L/R audio.

## Future paths (if revisited)

- **Tighter panning:** replace AudioQueue with `AVAudioSourceNode`/`AURemoteIO`.
- **True HRTF (up/down):** custom HRTF convolution mixed into the ring (sizable), or
  re-test PHASE on a newer visionOS. HL itself never had elevation cues, so L/R is
  faithful and shipping.
- **Window-lifecycle polish:** brief audio interrupt when closing the window; brief
  game-audio replay when reopening a window while the game is hidden.
