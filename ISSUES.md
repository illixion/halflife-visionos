# Issue tracker

Internal backlog for the LambdaVision port. Roughly ordered by priority
within each section. Move items to *Resolved* with the fixing commit
instead of deleting them.

## Open — interaction

- **Barrel aim reads slightly to the right.** With `fireAimMode = barrel`,
  shots (and now the decals) land a bit right of the visible muzzle. The aim
  ray is `wrist→middle-knuckle` (`sampleDominantHand`), not the drawn gun
  barrel (the WeaponPass grip correction `C = gripYaw 180°, gripRoll 90°`), so
  the two disagree by a fixed rotation. Deferred on purpose: adding VR
  hands/arms will re-seat the grip and shift this again, so realign the aim
  axis to the drawn barrel then (derive it from the same `handWorld·C·B·
  inverse(handBone)` transform). Live aim readout is in the launcher's
  Diagnostics disclosure.
- **Hand-anchored weapon polish.** v1 is in (p_ model at the dominant hand,
  skeleton-aligned grip, hand-directed fire, gaze fallback; dominant hand +
  fire-along-gaze accessibility now in Settings): remaining items — muzzle
  flash is lost while the viewmodel is hidden (`CL_AddEntity` clears effects
  on index-0 entities, so `EF_MUZZLEFLASH` can't ride the gun entity as-is);
  bullets still originate at the eyes (only the direction follows the hand).
  This is the default engine-drawn path; an opt-in Metal renderer that fixes
  the rotation drift now exists — see "Weapon Metal-pass polish" under
  rendering.
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

- **Per-pixel reprojection depth.** We submit a constant depth; real
  depth would reduce jelly artifacts during head motion.
- **Weapon Metal-pass polish.** Weapon viewmodels can render in a Swift
  Metal pass over the engine image instead of the engine (`vr_weapon_external`
  cvar; `WeaponPass.swift` + `Bridge/Lambda_WeaponModel.c`), hand-anchored
  from the live ARKit hand frame and shaded by an `R_LightPoint` probe.
  RealityKit/`RealityRenderer` was ruled out — a CompositorLayer immersive
  space is CompositorLayer XOR RealityView — so it's a 2nd Metal pass into the
  drawable colour slice with its own depth (leaves `drawable.depthTextures`
  for reprojection). The pass now draws the **v_ viewmodel** (HEV hands, gun,
  separate magazine/pump/cylinder bones) skinned on the GPU from a per-tick
  bone palette that replays the engine's own sequence math
  (`R_StudioEstimateFrame`/`CalcBones` ported into `Lambda_WeaponModel.c`),
  with the posed `Bip01 R Hand` pinned to the tracked hand — so idle, shoot,
  reload and draw play as authored. Chrome meshes (`STUDIO_NF_CHROME`) build
  their sphere-map coords in the shader the way `R_StudioSetupChrome` does —
  the .mdl stores one degenerate texel for every chrome vertex, which drew the
  .357 (630 of 1007 gun tris are chrome) and every HEV glove as a black
  silhouette. The grip bone is whichever hand actually carries the weapon
  geometry, not always the right one — the satchel charge is skinned to
  `Bip01 L Hand`. Backlog: grip constants
  (`Renderer.gripRollDeg/gripYawDeg/gripPushM`) were tuned against the p_
  hand bone and want a re-check on device; the model's own right hand is
  rigid Valve animation, not the user's fingers (skin it to ARKit joints
  next); arms end mid-forearm (see "Arms" below); no muzzle flash, external
  `…T.mdl` textures fall back to magenta, classic `v_9mmAR`/`v_hgun` have no
  hand bone (origin-at-hand), and it's a manual cvar (wire into Settings).
  Physical per-weapon reloads can build on the exported bone table (mag =
  `Box02` / `clip`, pump = `Charger`, cylinder = `revolver` +
  `speed_loader`).
- **First-person avatar (in progress).** The viewmodel sleeve stops mid-forearm
  and is rigidly driven by Valve's sequence, so it neither reaches nor follows
  the player's real arm. Rather than extend the sleeve, draw the whole player
  body and let the arms come with it. The extractor now has a second model
  slot and loads `valve/models/player/gordon/gordon.mdl` at startup
  (`lambda_body_load`): 343 source vertices, 42 bones with both full arm
  chains, embedded textures, life-size at 72 units with a 55 cm shoulder-to-
  wrist reach. `AvatarRig.swift` now poses it: the root is placed so the rest
  head lands on the tracked head under a damped yaw (deliberately *not*
  parented to the head, which would swing the torso every time you looked
  down), and both arms are solved with FABRIK. Verified on the Mac against the
  real `gordon.mdl` — rest pose round-trips to 0.00002 units, head placement is
  exact at every yaw, and over 277 hand targets the worst miss is 1.76 mm with
  the elbow correctly dropping 7.3 units below the shoulder-hand line. The IK
  is `RAVERig`, a framework-free target of the shared `RAVEEngine` package
  (`../../RAVEEngine`, which this app already linked for `RAVEInput` and
  `RAVEDiagnostics`) split out of spatial-ai-character so both games share one
  solver; everything GoldSrc —
  Z-up inches, `Bip01` names, the row-major palette — stops at `AvatarRig`.
  Solving happens in GoldSrc model space, so the palette stays native and no
  axis conversion sits between the tracker and the bones. It now draws:
  `WeaponPass` renders the body through the same pipeline and depth buffer as
  the gun (so the two occlude each other), from a `StudioMesh` upload shared
  with the viewmodel. Placement hangs the rig from the *eyes* — measured 4.4
  units forward and 3.4 up of the head bone, off the glasses bone — with the
  head bone taking the tracked orientation, so looking down pivots the skull
  about the neck and the neck moves only by the eye offset's chord (4.3 units
  at 45°, verified). Wrists take the tracked orientation outright, built from
  the fingers' direction and the back of the hand; Bip01 hands measure X along
  the fingers and +Y out of the palm on both sides, so one frame
  (`AvatarRig.handRotation`) serves both with no per-hand tunable. An
  untracked hand hangs by the side rather than holding sequence 0's raised
  arm. The head is always cut (the camera is inside it) and the legs are cut
  by default, as whole triangles at upload — 283 of 639 dropped — leaving an
  open neck and hips. The body yaw trails the head yaw with a 0.35 s time
  constant. First device look: tracking reads well, but the elbows folded the
  wrong way. Two causes, both fixed: RAVERig's pole only fixed the bend
  *plane* and kept the seed's side (right for an animated leg, wrong for an
  arm seeded from sequence 0's raised right arm), so it gained a
  `bendTowardPole` option; and the pole itself was mostly *back*, nearly
  anti-parallel to any hand held forward, so the plane tilted sideways. It is
  now mostly down with a little back and outward, and the probe asserts the
  elbow's side for six hand positions per arm. Second look: still not the
  player's elbow — because it was still a guess. ARKit's hand skeleton carries
  the forearm (`.forearmArm` is the elbow end; the wireframe already drew it),
  so the rig now takes the tracked elbow as the pole direction and the
  synthetic pole is only the fallback for an untracked hand. Settings > Input >
  "First-person body" is the arms-only fallback
  (`Renderer.avatarLegsVisible` shows the legs; no UI yet). Not yet on device:
  the eye offset, the cull mode (none, like the weapon), the wireframe hands
  overlapping the avatar's, and the viewmodel's own hands/sleeve still drawing
  beside the body's — suppressing those so the gun alone grips the avatar's
  hand is the next step.
  - Gotcha found on the way: the pose the body slot publishes is sequence 0
    frame 0, not the studio bind pose — origin at the pelvis, one arm already
    raised, and rotated 90° from the bind pose. That is harmless, because
    vertices are baked bone-local and skin correctly against any palette, but
    the bbox the bake logs is measured in the *other* pose, so the two never
    agree and neither is wrong.
  Rejected: Half-Life: Source and Half-Life Deathmatch: Source ship
  recompiles, not remakes — their player models are 595 and 755 vertices with
  *single-bone* rigid skinning, exactly like GoldSrc, so a whole Source asset
  pipeline buys a 1.7x vertex bump and nothing else.
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

- ~~Bullet-hole decals + tracers lied about where barrel-mode shots landed~~
  — the server damage trace fired along the barrel (`pev->v_angle +
  g_vr_aim_offset` in `ItemPostFrame`), but the client event trace that draws
  the decal/tracer read `args->angles` (the head view, no offset), so the hole
  appeared along the gaze while the damage went along the gun. Fixed by
  applying the same offset client-side in `ev_hldm.cpp` (`EV_VR_ApplyAimOffset`
  in the six hitscan/beam events, local player only, egon exempt). The offset
  can't be folded into the usercmd view (that would swing the camera), so it's
  a separate client-side symbol `g_vr_aim_offset_cl` (`view.cpp`) the bridge
  writes alongside the server copy. Residual right-offset tracked above.
- ~~Hand-anchored weapon drifts off the hand under rotation~~ — the
  engine-side hand weapon (`VR_AddHandWeapon`) reconstructed a one-frame-stale
  camera, so head rotation sheared the gun off the hand. Added an opt-in
  Metal weapon renderer (`vr_weapon_external`): the engine draws no weapon and
  publishes the active `.mdl`; the app bakes a bind-pose mesh
  (`Lambda_WeaponModel.c`) and draws it in a Metal pass (`WeaponPass.swift`)
  at the live ARKit hand frame (`model = handWorld·C·B·inverse(handBone)`),
  shaded by an `R_LightPoint`/`LightAtPoint` probe. Drift gone; textures +
  world lighting verified on device. Commits 2d66b36 (cvar), 0674db6
  (extractor), 9216721 (Metal pass), a78ce01 (hand-anchor), 3ca6571 (light
  probe). Follow-ups tracked under "Weapon Metal-pass polish".
- ~~No settings window~~ — the 2D window is now a launcher with a gear →
  Settings sheet (sectioned `Form`): Graphics (render scale, MetalFX, gamma,
  brightness, snap-turn angle), Audio (SFX `volume` / MP3 `MP3Volume`), Input
  (dominant hand, fire-along-gaze accessibility, fast weapon switch, gesture
  toggle for pass 2), Advanced (stock HL menu portal via `menu_main`/
  `menu_options`/`menu_multiplayer` console cmds, map loader, console field).
  Plumbing: `AppSettingsStore` (UserDefaults) → `GameSettings` (@Observable;
  `didSet` persists + applies) → engine via `lambda_gl_worker_cmd` cvars
  (gated behind engine readiness — the GL-worker post deadlocks before init)
  and hoisted `Renderer` statics (render scale/MetalFX read at drawable setup,
  so they apply on next immersive open). FOV/anisotropy/sensitivity were
  dropped as no-ops on our pipeline (headset tangents fix the world
  projection; anisotropy is set at texture upload; look uses joy axes + snap).
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
  GPU/frame; disabled → stable 120 FPS. The Settings toggle is now gone:
  `GameSettings.metalFXEnabled` starts `false` regardless of what
  UserDefaults holds (a user who had enabled it isn't stranded at 50 FPS)
  and the scaler code stays compiled behind `Renderer.useMetalFXChain` in
  case a cheaper configuration brings it back. The aliasing it was hiding
  is now handled by folding the FXAA kernel into the composite/display
  fragment shader (`fragmentShaderFXAA`, selected per frame from
  `Renderer.compositeFXAA` via a second pipeline state) — zero extra
  passes, zero intermediate textures, offsets taken from the sampled
  texture's own texel size (engine resolution, not drawable). Exposed as
  Settings → Graphics → "Edge smoothing (FXAA)", default on, live (it only
  swaps the pipeline). Taps are per drawable fragment, so watch `frameGPU`
  in the `[FT]` line when A/B-ing it.
- ~~HUD left-eye-only / double vision / microscopic text~~ — per-eye
  V_PostRender + tangent-derived 2D viewport with convergence; hud_scale
  4, con_fontscale 3.
- ~~Snap turn desynced WASD~~ / ~~tram rotates view~~ — engine-yaw snap
  turn; `cl_stereo_no_addangle`.
