# Issue tracker

Internal backlog for the LambdaVision port. Roughly ordered by priority
within each section. Move items to *Resolved* with the fixing commit
instead of deleting them.

## Open — interaction

- **Hand-anchored weapon polish.** v1 is in (p_ model at the right hand,
  skeleton-aligned grip, hand-directed fire, gaze fallback): remaining
  items — muzzle flash is lost while the viewmodel is hidden
  (`CL_AddEntity` clears effects on index-0 entities, so `EF_MUZZLEFLASH`
  can't ride the gun entity as-is); bullets still originate at the eyes
  (only the direction follows the hand); dominant-hand setting
  (left-handed players).
- **Egon renders/aims as a viewmodel, not hand-anchored** (workaround, not
  a true fix). The gluon gun's backpack is rigged to the player body and
  `p_egon` has no `Bip01 R Hand` bone, so hand-anchoring drives the pack
  into the player's chest. Current behavior: `VR_AddHandWeapon`
  (`entity.cpp`) skips the egon via `strstr(mdl->name, "egon")` and leaves
  the stock viewmodel up (`g_vr_hand_weapon_drawn = 0`); to keep the
  visuals and the hits consistent, `CBasePlayer::ItemPostFrame`
  (`player.cpp`) also exempts `WEAPON_EGON` from the aim offset so it fires
  along the view (where the player looks) instead of the hand ray. Two
  files must agree on "egon" — the render skip and the aim exemption. A
  proper fix would anchor only the gun portion to the hand (hide/detach
  the backpack submesh) so it behaves like every other weapon.
- **Gaze+pinch `+use`.** Off-hand pinch = use, dominant hand = fire, to
  avoid gesture ambiguity. Spatial events already reach the layer.
- **Finger-curl trigger.** Index-joint flexion with hysteresis as an
  immersive alternative to pinch fire. Risks: false fires, no haptics,
  fatigue — keep pinch as fallback.
- **Shell casings eject off-axis** relative to the aim ray (client event
  shell math uses its own attachment angles). Cosmetic.
- **Gaze ray freezes during a held pinch** — visionOS only updates
  `selectionRay` with hand drift after the pinch starts (privacy: gaze is
  revealed at tap). Automatic fire tracks the pinch-start gaze, not the
  eyes. Acceptable for now; hand-anchored aim supersedes it.

## Open — rendering

- **Settings pane.** Render-scale slider + MetalFX toggle (re-enable the
  FXAA+MetalFX chain for M2-class hardware; it costs ~13-14 ms GPU and is
  unnecessary on M5 — see `useMetalFXChain` in Renderer.swift), snap-turn
  angle, dominant hand.
- **Per-pixel reprojection depth.** We submit a constant depth; real
  depth would reduce jelly artifacts during head motion.
- **RealityRenderer body/arms.** Modern skinned hands/arms (converted
  HL:Source models?) drawn inside our compositor via RealityKit
  `RealityRenderer`: our camera, our depth (correct occlusion, wall
  clamping possible), IBL built from game lighting (`R_LightPoint`).
  Big; the payoff is properly IK'd limbs in a 1998 game.
- **2D overlay minification.** The HUD box is downsampled ~2.15×; could
  render the 2D layer at a matching smaller virtual resolution instead.
- **`tangents` API deprecation** warning in Renderer.swift.
- **Level-transition hitches** (~43 ms signon parse + 110-180 ms map
  spawn) are inherent HL; a fade/hold would mask them.

## Open — audio

- **Lower audio latency for tighter panning.** Panning is responsive now
  (small AudioQueue buffers + `_snd_mixahead 0.04`), but AudioQueue is a
  buffered/high-latency API. For ~40 ms panning, swap the backend to a
  low-latency `AVAudioSourceNode`/`AURemoteIO` render callback pulling the
  same lock-free ring (`snd_visionos.c`).
- **True HRTF (up/down cues).** Stock mixer + AudioQueue does HL-style L/R
  panning only. PHASE (the HRTF route) is unusable here — see
  `.claude/research/visionos-spatial-audio.md`. Real options: custom HRTF
  convolution into the ring, or re-test PHASE on a newer visionOS.
- **Window-lifecycle audio polish**: brief interrupt when closing the 2D
  window; brief game-audio replay when reopening a window while the game is
  hidden. Cosmetic.

## Open — upstream candidates (xash3d-fwgs)

- **gl2_shim BaseVertex workaround**: ANGLE's Metal backend advertises
  `GL_OES_draw_elements_base_vertex` but `glDrawRangeElementsBaseVertex`
  intermittently fails valid draws with GL_INVALID_OPERATION; the shim
  now prefers the plain entry point when basevertex would be 0. Includes
  a latent `end`-index off-by-one fix. (`gl2_shim.c`)
- **rodir overlay mount fix**: `FS_AddGameHierarchy` never mounted
  SteamPipe overlay dirs (`_hd`/`_addon`/`_lv`/`_l10n`) from `-rodir`.
  (`filesystem.c`, `FS_AddGameDirectoryOverlay`)

## Ideas / someday

- CS-style fastswitch (slot key cycles weapons directly with multiple
  weapons per bucket — small `ammo.cpp` patch; stock HL only fast-switches
  single-weapon slots).
- Joy-Con / Switch Pro gyro aim mode (3-DoF orientation + drift recenter;
  physical trigger). Hand tracking stays primary.
- Sense-controller support if availability ever improves — same anchor
  code as hand tracking, different input source.

## Resolved

- ~~Audio pinned to the 2D window~~ / ~~1 s loop on resume~~ — window-pinning
  was visionOS anchoring the app's audio to its first window; fixed with
  `AVAudioSession.setIntendedSpatialExperience(.bypassed)`. Resume loop fixed
  by silencing the DMA ring on reactivate (NOT `AudioQueueReset`, which
  starves the queue). Also cut pan latency (`_snd_mixahead 0.04`, 512-frame
  AQ buffers). PHASE spatial audio abandoned as unusable on visionOS 26 —
  full write-up in `.claude/research/visionos-spatial-audio.md`.
- ~~Gaze aim fires at screen center~~ — root cause: usercmd never carried
  the head-tracked view; server aimed along stale game yaw (also broke
  NPC view cones). Fixed by composing the stereo view override into the
  usercmd in `CL_CreateCmd`; gaze offset applies on top via hlsdk
  `ItemPostFrame`. Also `cl_lw 0` so effects trace server-side.
- ~~HD models don't load~~ — `valve_hd` mounted relative-only, invisible
  from rodir (app bundle); plus `Hgrunt03.mdl` capitalization crash on
  case-sensitive filesystems.
- ~~~50 FPS everywhere~~ — FXAA+MetalFX+composite chain cost ~13-14 ms
  GPU/frame; disabled → stable 120 FPS.
- ~~HUD left-eye-only / double vision / microscopic text~~ — per-eye
  V_PostRender + tangent-derived 2D viewport with convergence; hud_scale
  4, con_fontscale 3.
- ~~Snap turn desynced WASD~~ / ~~tram rotates view~~ — engine-yaw snap
  turn; `cl_stereo_no_addangle`.
