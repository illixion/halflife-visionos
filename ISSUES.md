# Issue tracker

Internal backlog for the LambdaVision port. Roughly ordered by priority
within each section. Move items to *Resolved* with the fixing commit
instead of deleting them.

## Open — interaction

- **Keyboard/mouse/gamepad follow-ups.** The flat mode is in (see
  Resolved, device check pending; so is the HEV ammo panel in flat modes,
  now a view-following overlay). Still open: the body still trails the
  head's yaw, not the mouse's; the default bindings show in Settings
  (Keyboard, mouse & gamepad > Controls) but nothing shows them on first
  run, and the list doesn't follow in-game rebinds. Mouse look-pitch is
  opt-in because the room-space passes (body, HEV holograms) can't follow a
  tilted world.

- **A mouse only works while the visionOS pointer is over one of the app's
  windows.** Seen on device (also in Longwave), even with a BLE mouse paired
  straight to the headset, every window closed and Mac Virtual Display off:
  with the pointer in the immersive space GCMouse delivers nothing, and
  clicks land in the launcher window. Findings (visionOS 26/27 SDK headers
  and docs, 2026-10-06), none tested on device:
  - No API claims the mouse for a full immersive space. `GCEventInteraction`
    / `.handlesGameControllerEvents` only take gamepad and stylus events
    (`GCUIEventTypes`, GCEventInteraction.h), and the SwiftUI modifier is
    View-only. A `CompositorLayer` scene has no view, no view controller and
    no input modifiers (the CompositorContent modifiers are overlays,
    immersion and limb visibility), and an ImmersiveSpace can't mix it with
    views. Pointer lock (`UIPointerLockState`, `prefersPointerLocked`) needs
    a full-screen view controller, which a visionOS window isn't.
    `pointerVisibility` is unavailable on visionOS. visionOS 27 adds nothing
    for mice. So no `RAVEMouseSource` change can fix it: its handlers are
    fine, the system just doesn't route the events.
  - `.pointer` spatial events (click-to-release sequences, no motion, no
    wheel) might reach the layer's `onSpatialEvent`; the app now logs the
    first few ("pointer event in the immersive space") to find out. Even if
    they do, they can't drive mouse look.
  - Left to try: an "input catcher" window kept in view while playing
    (`.plain` style, no glass, `Color.clear` with a content shape so clicks
    hit nothing). Windows are world-anchored, so it only covers part of the
    view. Otherwise the rule stands: keep a window under the pointer, or
    play with a keyboard or gamepad (README says so).
  Gamepads aren't affected the same way: `.handlesGameControllerEvents` on
  the window under the gaze is what keeps them from freezing, and every
  window now has it (see the stuck-forward item in Resolved).
- **Arm-swing walking needs tuning on device.** `RAVEArmSwinger` (RAVEInput)
  drives the same joy axes as the pinch joystick: both fists plus a swing
  pattern engage it, and the stroke-speed envelope maps 0.4–2.0 m/s onto
  0–1. Every constant is a host-test starting point, not a measured one;
  read the `swing:` and `ground speed:` diagnostics lines while jogging in
  place. Before a run starts, a fist on the off hand also stands the gun
  hand down (the entry into a swing would otherwise fire), so resting that
  hand clenched blocks fire. Once running, pointing the gun hand frees it
  and the off arm carries the run; watch that sweeping the aim while firing
  never reads as a rejoin (`rejoinHold` 0.3 s).
- **Gaze ray freezes during a held pinch** — visionOS only updates
  `selectionRay` with hand drift after the pinch starts (privacy: gaze is
  revealed at tap). Automatic fire tracks the pinch-start gaze, not the
  eyes. Acceptable for now; hand-anchored aim supersedes it.

## Open — rendering

- **HEV HUD next steps.** The holographic HUD (`HEVHUD.swift` on RAVEHolo;
  client state from `cl_dll/hud_redraw.cpp` `g_vr_hud_state`) replaces the
  stock health, suit, ammo and flashlight readouts: ammo beside the gun hand,
  vitals over the off-hand forearm (fades in as the back of the forearm faces
  the eyes). Outside hands mode the readouts default to a view-following
  overlay (see Resolved, device check pending). Panels stand off their anchor
  toward the eyes and draw over everything. Still stock: pain/damage arrows,
  pickup history, messages, console, menu. The hand weapon wheel draws its
  icons through the same renderer (see Resolved). Offsets and the fade
  angle are first guesses (`HEVHUD.forearmClearance` / `gunClearance`), as
  are the overlay's (`HEVHUD.overlay*`). The holograms write no depth, so
  reprojection warps them with whatever is behind; for the overlay at
  0.85 m that only matters for head translation inside one frame. If its
  numbers swim at depth edges on device, write the panels' own depth into
  the reprojection depth (gfx's `reprojectionDepthMerge`).

- **Gun-mounted flashlight: device check pending.** The flashlight now
  rides the weapon hand (`Renderer.flashlightOnGun`, Settings "Gun-mounted
  flashlight"): from the drawn muzzle along the barrel, or the grip along
  the hand for melee weapons; head-aimed as stock when the hand is not
  tracked. `cl_tent.c` traces from that beam and the renderer splats it as
  a cone (`R_AddFlashlightCone`, `cl_flashlight_cone 0` = stock disc).
  Brightness, range and battery are untouched. Verified on the Mac build
  only (head-aimed there, no bridge); on device, check the pool follows
  the barrel, the eye fallback behind walls, and brush-entity surfaces.

- **Dark-gradient banding fix: confirmed on device.** The colour map is
  16-bit normalized and the drawable is `rgba16Float` (linear, no dither
  needed); dim vents are smooth.

- **Linear colour: gamma retuned on device (2026-10-06).** The drawable is
  linear light and the engine's image is gamma-encoded; Settings "Linear
  colour" (default on, `Renderer.displayDecodeGamma` = 2.2) decodes every
  game colour before the drawable. With it on, the old 2.4 gamma read too
  dark; 3.0 (then the slider's top) looked right on the headset, so it is
  the new default and the slider reaches 3.6. Still to judge: whether
  above 3.0 is better, on/off in a dark vent vs a lit room, and the HUD's
  dark-room dimming against it. Existing installs keep their stored gamma.

- **HDR headroom re-test: pending.** Settings → Diagnostics "HDR headroom
  test": test values 0.5 1 1.25 1.5 1.75 2 2.5 3 4 over black, each above a
  1.0 reference, as small dots (point lights) or view-filling patches (the
  worst case for the panel's brightness limiter). Oneiros's 2026-09-05
  result (~1 stop, 2 = 4 = 8) used large bands and did not record thermal
  state; this logs `[HDR] test pattern …, thermal state …` and the
  settings row shows it live. Record the ceiling per layout and thermal
  state; it sets the tone map's peak for the HDR step (half-float engine
  target + Oneiros-style `tonemapDisplay`).

- **GPU budget: measure on device.** The Performance HUD now shows the
  GPU's own time per frame against the 8.3 ms a 120 Hz frame has
  (`GPUPassTimer`): our command buffer from Metal 4 commit feedback
  (`gpuQueue`, always on), and with Settings → Diagnostics → "GPU pass
  timing" on, ANGLE's time per eye from GL timer queries (`gEngine0/1`, if
  ANGLE exposes `GL_EXT_disjoint_timer_query`; the worker logs which) and
  each of our passes from counter-heap timestamps (composite, arms,
  gun+body, HUD, depth). The same numbers go to the log as `[FT] gpu(ms)`
  every 512 frames. The old `angleGPU`/`frameGPU` columns are CPU-observed
  latencies, not GPU time. Next: record p50/p95 in the tram ride, a dense
  room (c1a0 cafeteria) and a firefight, with the thermal state, into
  `docs/plans/modern-lighting.md`; check `gpuQueue` ≈ the sum of our
  passes (if it is much larger, commit feedback counts the wait on ANGLE).
- **Modern lighting tier 1 (glass): environment-probe reflections, device
  check pending.** Settings → Graphics "Glass reflections (prototype)"
  (default off, live; `Renderer.glassReflections` + the engine's
  `r_vrglass`). **What failed on device (first prototype):** the reflection
  was the eye's own frame — the reflected ray, as a direction, projected back
  into that eye's image, with a flat colour where it left the frame. In the
  c1a2 office lab (the flooded bench under the periodic-table poster) it
  showed mirrored on-screen content, flickered between that and nothing as
  the gaze moved, and de-synced between the eyes looking sideways (each eye's
  frame holds different content and a different edge). **Now:** the engine
  marks each glass pixel with a row of a per-eye world-space plane table
  (exact plane, not a quantised normal), and the reflection samples an
  environment probe the engine renders from the head — six 256² faces, world
  and brush entities only, one face per frame after the second eye, only
  while glass is in sight and the probe is stale (48 units moved or 4 s) —
  with a parallax-corrected lookup through the probe's depth, a 0.3 s fade
  between probes, and a faint tint on what is seen through the pane
  (`GlassProbe.swift`, `Shaders.metal` `glassShade`, ref/gl `R_VRGlass*` /
  `R_VRProbeFace`, bridge `lambda_glass_*`). Verified on the Mac build with
  `Tools/DepthProbe` (c1a2 bench): probe faces reproduce the engine view to
  4.9/255; a probe 58 units off: 27/255 plain vs 7/255 parallax-corrected;
  same glass point from two gazes 0.6/255 apart, from two eyes 2.5 units
  apart 4.1/255; every glass pixel gets a probe reflection. Device: libxash
  rebuild needed; read `gProbe` / `probeCPU` in the `[FT] gpu(ms)` line, and
  see `docs/plans/modern-lighting.md` for the spots to check. Studio models
  (scientists, items) do not appear in reflections.
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
  next); arms end mid-forearm (see "Arms" below).
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
  arm. The head is always cut (the camera is inside it) as whole triangles
  at upload, leaving an open neck (the legs, when off, go the same way —
  283 of 639 triangles with both). The body yaw trails the head yaw with a 0.35 s time
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
  "First-person body" is the arms-only fallback, and "Legs" (on by default)
  cuts the body at the hips when off. With the body
  drawn, the viewmodel's own hands are gone: `ViewmodelGrip` cuts every
  glove/sleeve/forearm-textured triangle that sits on an arm bone (texture,
  not bone, because stock models skin gun parts straight to `Bip01 R Hand`;
  arm bone as well as texture, because the crossbow's limbs and the satchel
  radio's aerial reuse the glove texture), the gun's grip bone is pinned onto
  the avatar's posed hand bone with no tuned correction — every stock
  viewmodel hand and Gordon's share one Bip01 convention (fingers +X, palm +Y,
  thumb +Z on the right), measured — and the avatar's fingers borrow the
  viewmodel's own curl around the gun (the middle finger drives Gordon's
  mitten). A gun going into the other hand from the one Valve animated is
  mirrored across the hand's XY plane. The MP5's unnamed `Bone01…` rig gets a
  synthesised Bip01 frame from its gloved finger chains (within 11–20° of the
  real frame on every Bip01 hand it was checked against). The wireframe arms
  are not drawn while the body is. The probe (`--grips`) renders Gordon's arm
  holding every viewmodel. Looking down no longer shows the inside of the
  body: it is back-face culled (GoldSrc winds outward faces clockwise —
  measured on gordon.mdl and every viewmodel; the gun stays unculled, since
  GoldSrc never actually culled studio models and thin parts rely on it),
  fragments within 9 cm of an eye are discarded, and past ~50° of pitch the
  rig steps the body back just far enough to keep every torso vertex 12 cm
  from the eye (exact per vertex; level gaze is 20 cm clear and moves
  nothing). The body now has legs, Boneworks-style: the client publishes the
  floor under the player, onground, water level and velocity each refdef
  (`g_vr_body_state`, `cl_dll/view.cpp`; the floor is measured from the
  refdef's vieworg, before the engine adds the headset's translation, so the
  app adds its head offset back), and `AvatarGait` runs RAVERig's new
  `FootPlanter` — feet planted until they drift from a stance beside the hips,
  then one step at a time, never crossing on a strafe, backpedal or turn — in
  a frame the game's velocity carries along, so thumbstick locomotion walks
  the legs while planted feet hold still against the world. Each leg is a
  FABRIK chain to its sole, knee toward the foot's heading, foot flat. Gordon
  stands 68 units to the eye and the game's camera 64, which would bend his
  knees ~56° at full extension, so thighs and shins are compressed ~12% (and
  squashed in the palette to match) until standing puts his eyes at 64 with a
  ~10° knee. Crouching folds the knees forward and moves the stance ahead of
  the pelvis; in the air or in water the legs hang. Probe: standing, crouch
  and duck reach the floor within 0.2 units, standing still never moves a
  foot, thumbstick walking at 150 u/s steps with zero planted-foot slip, and
  `--legs` renders the poses. Not yet on device: the eye offset, whether the
  grip reads right in the hand, and the legs as a whole — likely tuning is
  the step threshold (a fifth of a leg), step time (0.3 s, down to 0.14 s),
  and HL's 320 u/s run, which no gait makes look calm.
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
- **2D overlay minification (looked at, not changed).** The 2D layer's
  ortho keeps the full virtual screen (the engine render size, ~3800 px at
  0.75 scale) and `R_Set2DMode` squeezes it into the 50° box, 1/frac ≈ 2.15×
  smaller. HUD sprites and console glyphs are *not* texture-minified by
  that: `hud_scale 4` / `con_fontscale 3` magnify them first, so they land
  ~1.9× magnified. What does suffer is anything one virtual pixel thick (net
  graph lines, console cursor, menu outlines: ~0.46 px, so they flicker)
  and the stock menu if mainui rasterises its fonts at the virtual height.
  The fix is to give the 2D layer its own virtual size equal to the box
  (decoupled from `refState` width/height, which the 3D view also uses),
  with `hud_scale`/`con_fontscale` divided by the same factor and
  `Renderer.menuCursorFromGaze`'s render-target mapping switched to the
  box. That touches client HUD layout, mainui's VidInit and the cursor
  mapping, and can't be judged without the headset, so it is left for a
  device session; check first whether menu text actually looks aliased.
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

## Open — compiled games and mods

- **Opposing Force weapons: device check pending.** OF and BS build, load
  and spawn their own entities (Mac: of0a0, of1a1, ba_tram1, ba_canal1, no
  missing factories). Done offline:
  - *Grips:* every OF, BS and HD viewmodel goes through `ViewmodelGrip` in
    the avatar probe (`build.sh --grips --anchor=…/gearbox/models`, renders
    under `<game>/`), and all of them hold in the hand. The PCV, Barney and
    HD hand textures were already cut; Blue Shift's `L_wristbone` sleeve now
    is too. Fixed on the way: the sniper rifle (`v_m40a1` opens with its draw
    sequence, so the rest pose is now the first idle sequence), and the shock
    roach and gluon gun (their grip bone sits 16.5 and 8 units off the gun;
    such a gun is pulled into the hand, `ViewmodelGrip.pulledIn`).
  - *Client barrel aim:* `vr_events.cpp` adds `penguinfire`, `snarkfire`,
    `tripfire` (throw checks along the barrel, matching the server),
    `crossbow2` and the spore launcher's spit spray, which a new origin mode
    moves onto the muzzle. The displacer's event draws nothing from the view,
    and the shock roach's arcs and the gluon beam start from the gun's
    attachments, which now follow the drawn gun (see Resolved, muzzle flash).
  - *Exemptions:* none needed. The displacer and shock rifle hold in the hand
    like any gun; only a gun drawn flat fires along the view
    (`g_vr_weapon_flat`).
  - *Weapon ids:* nothing app-side keys on weapon ids (the HUD reads clip
    sizes from the game, `VR_WeaponMaxClip`); the VR layer's last one, the
    egon exemption, is gone.
  Still open: projectile weapons spawn at the stock offset from the gun
  position (`GetGunPosition() + forward·16 + right·8 − up·8`: RPG, hornet
  gun, spore launcher, shock rifle), i.e. 8–9 units right of and below the
  drawn muzzle. A fix needs a per-weapon offset table in `VR_GunPosition`
  that would also shift the RPG's laser trace, so it's not done. On device:
  each OF weapon in the hand, its fire, arcs and projectiles, the sniper zoom,
  the Desert Eagle's laser spot, and the barnacle grapple (held, gap 6).
- **FreeVGUI clients on this engine pin.** hlsdk-portable branches after
  2026-08-19 link FreeVGUI into the client, which needs the VGUI
  `SetPaintOffset` entry our xash3d-fwgs pin predates (NULL call on the
  first panel paint). The engine now has the entry as a no-op, so HUD
  sprites drawn from inside a VGUI panel (multiplayer menus) land off by
  the panel's position, and FreeVGUI's panels have never run on the
  headset. The built-in ports are pinned before the switch
  (`VisionPort/games.list`); user-compiled current mods take the FreeVGUI
  path. Proper fix: implement the offset in the engine's 2D draw calls, or
  bump the xash3d-fwgs pin.
- **Kind C runs on Half-Life's code.** A gamedir with no compiled-in match
  (by gamedir, then gamedll_linux / gamedll_osx, then gamedll) gets
  Half-Life's (`Lambda_FindCompiledGame`, lib_posix.c); that includes an
  OF or BS install on a build that didn't compile their port.
- **Game change needs an app restart.** `Sys_NewInstance` hands the
  gamedir to `Lambda_RequestGameChange` instead of `execv`; restarting
  the engine in-process (static globals in engine + games) is unexplored.

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

- **Modern lighting** (glass, reflections, shadows, eventually ray tracing).
  Plan and tiers: [docs/plans/modern-lighting.md](docs/plans/modern-lighting.md).
- **Speedrunner mode.** An in-game run timer and a speed gauge. Unblocked:
  build it as another RAVEHolo panel in `HEVHUD.swift` (the native HEV HUD
  replaced the stock readouts), not in the stock 2D HUD. The ground speed is
  already published (`g_vr_body_state.velocity`, shown in the diagnostics as
  `ground speed:`).

- CS-style fastswitch (slot key cycles weapons directly with multiple
  weapons per bucket — small `ammo.cpp` patch; stock HL only fast-switches
  single-weapon slots).
- Joy-Con / Switch Pro gyro aim mode (3-DoF orientation + drift recenter;
  physical trigger). Hand tracking stays primary.
- Sense-controller support if availability ever improves — same anchor
  code as hand tracking, different input source.

- **Near-instant level transitions.** A changelevel still runs inside one
  engine frame (device 2026-09-23: 120–140 ms, one 457 ms outlier; Mac native
  build 76–110 ms). What changed: the render loop no longer waits for it. The
  frame that starts a load is copied with its depth and pose, the engine's
  frames run unawaited (`lambda_gl_worker_tick_async`), and every display
  frame redraws the copy from the live head pose (`LoadSnapshot.swift`,
  `SnapshotShaders.metal`; tuned on Mac dumps with
  `Tools/SnapshotProbe`). The engine defers tearing the old level down until
  both eyes of that frame are drawn and draws no plaque
  (`SCR_BeginLoadingPlaque`/`SCR_FinishLoadingPlaque`, visionOS only). Needs
  device confirmation that it reads as holding still. Where the time goes, per
  `[LT]` log lines (Mac, c1a0→c1a0d): world textures 16 ms, server activate
  10 ms, BSP tree/hulls 5 ms, save old level 4–7 ms, restore entities 5–8 ms,
  client precache 3–7 ms, sky 3 ms, first frame 5–7 ms; a first visit builds
  the node graph a few frames later (29 ms hitch, `[LT] late hitch`). Next,
  if still wanted: prepare the next map's files in the background from the
  trigger and swap once ready (the player keeps moving meanwhile; landmark
  save already carries position and velocity), and check every map's files in
  the pre-game warm-up so a broken map is refused with a message instead of
  ending the session.
- **Crossbow scope glass.** Draw the scope lens as a magnified sample of the
  eye's own frame along the scope's line of sight (cheap; exact when the
  scope is at the eye, which is the only time it is useful) instead of the
  opaque red texture. A true second narrow-FOV engine view would cost a third
  world render per frame.
- **Viewmodels are open on the far side.** Valve built v_ models for a fixed
  camera, so the faces away from it (the gun's right side, the M4's stock)
  were never modelled. Mitigated, not solved: Settings > Weapon model > World
  model holds the whole p_ model instead (rigid, so a reload shows only as the
  ring; the egon has no hand-held p_ model and keeps its viewmodel). Tried and
  dropped: fitting the p_ model onto the viewmodel as a hull (ICP + per-
  triangle cuts) — the two are different shapes on several guns and the 357
  landed badly off. Real fix is custom all-round weapon models; WeaponPass
  already swaps between two meshes, so a third source slots in there.

## Resolved

- ~~Stuck walking forward after connecting a controller~~ (device check
  pending; cause not proven). Seen once: hand-stick movement, then a mouse
  bump switched to keyboard+mouse and the Pro Controller to gamepad, and
  the player kept walking forward for a while. The code paths all zeroed
  the hand axes on the switch, so the fix covers every candidate:
  - **Most likely, a frozen stick.** Only the launcher window had
    `.handlesGameControllerEvents`; with the gaze on the Performance or
    Console window the system takes the pad for focus navigation and polled
    values freeze, a pushed stick staying pushed. Every window has it now.
  - **Release on every mode switch** (`InputHandoff`, `InputMode.swift`):
    each device that isn't the new owner lets go of what it holds. Hands:
    clutch, swing, throttle, +jump/+duck/+use and both axes
    (`HandMovement.releaseAll`). Gamepad: every held +command, the crouch
    toggle, the wheel and its axes (`GamepadInput.releaseAll`, buttons via
    `HeldCommands`, which keeps a still-held button quiet until pressed
    again). Keyboard and mouse: key-ups for held keys and the mouse buttons.
    The axes are zeroed outright, and entering hands or gamepad queues a
    bare `-forward/-back/-moveleft/-moveright/-left/-right`, so a key whose
    release went to another window can't keep walking.
  - The gamepad no longer writes its (centred) axes every frame outside
    gamepad mode, where it raced the hand stick's writes; a button counts as
    gamepad activity on the press only, so a held trigger can't pull the
    mode back each frame.
  `Tools/HandsProbe` checks the handoff plan and `HeldCommands`.
- ~~Gamepad: missing binds, no weapon wheel~~ (device check pending). New
  layout (ControlsReference, README): left-stick click walks (+speed, was the
  left shoulder), right-stick click toggles crouch (B drops it), D-pad down
  sprays. Holding the left shoulder opens the hand wheel's entries as a
  radial ahead of the view (`GamepadWheel` in `WeaponWheel.swift`): the
  right stick arms a sector and stays armed when it springs back, releasing
  selects, LOAD keeps its confirm hold, and the stick doesn't turn while it
  is open. It hangs off the HEV overlay's lazy follower, 0.45 m out
  (`Renderer.padWheelOffset`). The hand and gamepad wheels now draw through
  one `WeaponWheel.View` (`WeaponWheelPanel.panel(view:)` / `arcs(for:)`).
  On device: placement and size, flick-and-release, LOAD hold, and the
  shoulder no longer walking.
- ~~Weapon wheel can't pick a specific weapon in a slot~~ (device check
  pending; the owner's idea). Push the hand on past the rim (11.8 cm, just
  outside the armed wedge) over a slot holding several weapons and it opens
  into an outer arc of them (12.4–17.6 cm), centred on the slot, at least
  0.06 turns per weapon, the weapon in hand underlined. Sliding along the
  arc arms one, release selects exactly it, and coming back inside 9.5 cm
  folds it, so release-to-pick on the inner ring is unchanged. A one-weapon
  slot never opens. The client now publishes every owned weapon
  (`g_vr_wheel_members` in `vr_hud.cpp`, read through
  `lambda_wheel_members`, same seqlock). Settings: *Wheel: reach past the
  rim to pick a weapon*. `Tools/HandsProbe` checks the arc layout, opening,
  folding, clamping and the setting. On device: the reach (radii in
  `WeaponWheelGesture.Tuning` / `WeaponWheelPanel.member*R`) and legibility.
- ~~.357 off the finger-gun aim and the crosshair~~ (device check pending).
  The models stream's recent changes didn't cause it: the probe's output
  for the Python is the same before and after them. Two faults in the HD
  model's data did. Both are now fixed by general rules:
  - *Fidget.* In `fidget1`, Valve's hand raises the HD Python 8° for about
    four seconds. The grip bone was the part held still, so the drawn gun
    tipped off the aim. An aimed gun that marks a muzzle is now held by its
    body, the bone carrying the most of the gun (`ViewmodelGrip.gunBody`,
    `Grip.body`). The pump, the cylinder and the magazines still animate
    around it. The same rule fixes the sniper rifle's bolt cycle, which
    turned the gun 47° after every shot, and the HD MP5's grenade, which
    flipped it. Thrown items and melee weapons mark no muzzle, so they keep
    the old hold, and their throws and swings still leave the hand. The
    RPG's reload (11°) and the spore launcher's `idle2` (10°) still move
    their guns, for the same reason.
  - *Muzzle.* The HD Python reuses the classic model's attachment offset
    on a bone that sits differently, so attachment 0 sits 4 units ahead of
    the barrel and 4 above it. Shots and the reticle left 11 cm above the
    drawn barrel. Attachment 0 is now the muzzle only when it falls inside
    the outline of the gun's front 6 units, seen down the barrel
    (`ViewmodelGrip.isOnBarrel`); otherwise the gun's front is used. The
    rule also corrects the HD shotgun, OF's Desert Eagle, M249, sniper rifle
    and displacer. Muzzle flashes still draw at attachment 0.
  The probe prints each gun's holding bone and how far its barrel strays
  through every sequence. It fails if a gun that marks a muzzle strays.

- ~~HEV HUD in flat modes: ammo panel stuck at the resting gun hand~~
  (device check pending). Outside hands mode the HEV readouts become a
  Half-Life 2 style overlay (`HEVHUD.swift`): vitals 21° left and ammo 21°
  right of the view centre, 17° down, 0.85 m out at 1.6× scale. They hang
  off `LazyViewFollower`, a critically damped spring on head orientation
  (time constant 0.07 s, stepped in closed form so it's framerate
  independent and never overshoots a stopped head), clamped to 8° of lag so
  a fast turn drags the panels along rather than leaving them behind.
  Position stays on the head: translating the panels too would only make
  them swim in stereo. Mode switches crossfade the hand and overlay
  placements, the overlay rising 3° into place. Draw-over-everything, no
  depth writes and the dark-room dimming are unchanged. Settings >
  Keyboard, mouse & gamepad > HEV holograms: *Follow view (lazy)* (default)
  or *Attached to hands* (the old behaviour) for A/B.
  `LambdaVision/Tools/HUDProbe/build.sh` checks the follower on the Mac:
  the lag cap under 300–400°/s whips and head shakes, no overshoot and
  convergence after a stop, the 2Ωτ steady lag, and the same motion at
  30–240 Hz with jittered frame times. On device: judge the angles,
  distance, lag and cap (`HEVHUD.overlay*`), the crossfade on switching
  modes, and readability in a dark vent.
- ~~No alt-fire with hand tracking~~ (4303092; device check pending). The
  owner's gesture: touch the dominant thumb tip to the side of the curled
  middle finger, index still pointing. `+attack2` is held while contact
  holds (gauss charge, Glock rapid fire; taps zoom or launch a grenade), and
  a trigger pull while held keeps both buttons down, as in stock HL. Contact
  is the thumb tip's distance to the middle finger's thumb side (knuckle →
  PIP → DIP, shifted toward the index). `ThumbGestures.swift` also took over
  the reload hold, so the separation rules live in one place and
  `Tools/HandsProbe` checks them on a synthetic finger gun: contact only
  counts past mid proximal phalanx (a reload curl ends by the knuckle); near
  or in contact vetoes the reload hold; each gesture locks the other out
  until the thumb lifts; a reload hold already past 0.3 s when contact
  starts is ambiguous, so neither fires. Index extended and thumb ≥ 6 cm
  from the index tip are required to engage (no fist, pinch or 🤌).
  Settings "Alt-fire: thumb to middle finger" (default on) and "Alt-fire
  sensitivity" (scales the distances). Diagnostics line `alt-fire:` shows
  the live contact (cm), on/off thresholds, `along` (0 knuckle, 1 PIP, 2
  DIP) and the state (settle / HELD / near / index curled / pinch guard /
  locked / ambiguous). Knobs, all unverified on device:
  `Renderer.altFireContactOn/Off` (2.0 / 3.2 cm), `altFireSettleSeconds`
  (0.05), `altFireRadialOffset` (0.8 cm), and `ThumbGestures.Tuning`
  `minAlong` (0.5), `pinchGuard`, `reloadPathGrace`, `releaseSeconds`,
  `minHoldSeconds`. On device: read `contact`/`along` for a real reload curl
  versus a press; if a reload shows `near`, raise `minAlong` or lower the
  sensitivity.

- ~~Keyboard + mouse and controller play ("flat HL1 in 3D")~~ (79a6bf7, 43a028a; device check
  pending). One input mode (`InputMode.swift`: hands / keyboard+mouse /
  gamepad; Settings > Keyboard, mouse & gamepad > Input mode, Auto by
  default) switches the weapon pass (stock viewmodel drawn flat at the
  view), the aim source (zero aim offset, so `VR_ItemPostFrame` and the
  client events fire along the view; stock crosshair on) and the body IK
  (arms hang) together. Auto follows the last device; a look-and-pinch takes
  hands back after a second of device silence, as does unplugging it.
  Gestures pause in flat modes (and still on keyboard use in a pinned Hands
  mode). Mouse via `GCMouse` (`MouseInput.swift`): buttons/wheel as engine
  key events (stock `mouse1`/`mouse2` binds, wheel = `invprev`/`invnext`),
  motion applied app-side (`-noenginemouse` stays): menu cursor while the
  menu is up, nothing while the console is down, else smooth yaw through the
  snap-turn path at HL scale (sensitivity × 0.022°/count). Right stick turns
  smoothly (stock `joy_yaw` 100°/s, adjustable, or snap). Opt-in mouse/stick
  look-pitch. Keyboard binds for fire/alt-fire without a mouse and quick
  save/load via a versioned bind migration (`lambda_binds_migrate`,
  `lambdavision_binds.txt` beside `config.cfg`, unbound keys only). The
  diagnostics' first line shows the mode. On device: confirm GCMouse
  reaches a full immersive space (and no duplicate pointer clicks), mouse
  turn feel and sensitivity, the flat viewmodel's placement, the menu
  cursor, and the auto switches both ways.
- ~~No quick save / quick load~~ (device check pending) — hands: the weapon
  wheel's SAVE and LOAD sectors (LOAD commits after 0.6 s held armed);
  keyboard: F5/F6 save, F9/F7 load; gamepad: View/Options tap saves, a 1 s
  hold loads.
- ~~Weapon wheel is fixed at five sectors and has no icons~~ (device check
  pending) — the wheel has one sector per weapon slot the player owns
  anything in, published by the client (`cl_dll/vr/vr_hud.cpp`
  `g_vr_wheel`, read through `lambda_wheel_state`), so Opposing Force's
  seven slots and mods' slot counts just work. These follow the weapons:
  LIGHT (`impulse 100`, once the suit is on), SAVE and LOAD. Settings
  "Wheel: flashlight, quick save/load" turns those three off. Each weapon
  sector shows the weapon a pick selects, the way hud_fastswitch's `slotN`
  cycles a bucket (the next usable weapon after the one in hand). The pick
  sends that classname, so picking a slot again cycles it, and dots under
  the icon show the slot's weapons. Icons come from the `640hud*.spr`
  sprites the `weapon_*.txt` lists name. They are decoded in the warm-up
  (`HUDIconWarmup`) and vectorized into rectangles (`HUDIcon`), because
  RAVEHolo draws no textures, then drawn as a hologram over the wedges
  (`WeaponWheelPanel`); a weapon the warm-up didn't see shows its name.
  Entries are captured as the wheel opens, and an armed sector holds until
  the hand is clearly in a neighbour. Logic and real-sprite decoding are
  checked by `Tools/HandsProbe`. On device: check icon legibility and size,
  wheel radius (now 4.6–10.4 cm), the LOAD hold, and OF's 10-sector wheel.
- ~~No flashlight toggle with hand tracking~~ (device check pending) — the
  weapon wheel's LIGHT sector sends `impulse 100`.
- ~~Long jump unreachable with hand tracking~~ (device check pending) — the
  jump gesture now goes through `JumpSequencer`. At a run with the module,
  it presses `+duck` and then `+jump` 0.1 s later, with the duck held. The
  stick needs ≥ 0.85 deflection, the arm swing ≥ 0.75 of its speed, and
  the player ≥ 200 u/s ground speed. Every other jump keeps the old
  crouch-jump. The client publishes the server's `slj` physinfo
  (`g_vr_longjump`, `lambda_has_longjump`), so a player without the module
  never gets the duck-first order. Ledge jumps keep working: a long jump
  rises higher than a crouch-jump (56 vs 45 units) with the duck held
  through the flight, so it still clears a ledge, just with ~560 u/s of
  carry. A ledge approached short of a full run keeps the crouch-jump, and
  Settings "Long jump at a run" turns it off. No movement value changed.
  Where the module turns up: Half-Life's campaign hands it out in `c3a2d`
  (Lambda Core, just before Xen), and the hazard course `t0a0a` has one
  too. No Opposing Force or Blue Shift campaign map carries an
  `item_longjump`. Diagnostics: the `ground
  speed:` line shows the jump kind and whether the module is owned.
- ~~Per-pixel reprojection depth~~ — Settings → Graphics "Per-pixel
  reprojection depth" (default off, live; `Renderer.reprojectionDepth`,
  `ReprojectionDepth.swift`) gives the compositor each pixel's real depth
  instead of one constant far value. The composite converts the engine's GL
  window depth to distance and back through `drawable.computeProjection`
  (`Shaders.metal` `compositorDepth`), clamped inside the layer's range
  (far = the old 0.0001, since depth 0 drew black in Oneiros); the gun and
  body's own depth is then copied over it where they drew
  (`reprojectionDepthMerge`). The stock flat viewmodel (squeezed into the
  front 30% of GL depth, decoding under 16 cm) keeps the far depth, as do
  the menu, the HDR test, the level-load snapshot (its parallax is drawn in)
  and a frame without engine depth. HUD holograms, arcs and the wireframe
  arms write none and inherit what is behind them. `Tools/DepthProbe` runs
  the real shaders on Mac `r_vrdump` frames: every pixel unprojects to
  within 3e-4 of the GL point for infinite and finite reverse-Z
  projections, and the merge replaces exactly the overlay's texels. On
  device: A/B while leaning toward a near wall and a crate, and with the gun
  held close; look for jelly at depth edges (door frames) and for the HUD
  numbers swimming (device check pending).

- ~~`tangents` API deprecation~~ — `View.tangents` (deprecated since
  visionOS 2) is gone from Renderer and LoadSnapshot: the frustum tangents
  are read back from `drawable.computeProjection` instead
  (`Drawable.frustumTangents`, `DrawableProjection.swift`), whose x/y rows
  carry exactly the frustum. Each view's tangents are logged once at the
  first drawable (`[LambdaVision] viewN tangents …`); on device, check they
  match the old values (and the image fuses as before) (device check pending).
- ~~Muzzle flash lost while the viewmodel is hidden~~ (device check
  pending). The hidden viewmodel was hidden by clearing its model, which
  also stopped its animation events, and with them every muzzle flash,
  its light and the attachments beams start from. It is now drawn fully
  transparent instead (`VR_HideViewModel`), so the engine still runs its
  events, and `VR_StudioAttachments` (hook at the end of the client's
  `StudioCalcAttachments`) moves its attachments onto the drawn gun: the
  Metal pass's live attachment points (`lambda_set_weapon_draw`), or a point
  ahead of the engine-drawn p_ model. The flash sprite, its dynamic light,
  the gluon beam and the shock roach's arcs leave the gun in the hand. The
  headset renders each frame twice, so viewmodel events now run on the first
  render only (`VR_StudioDrawModel`; reload sounds would double too).
  Verified on the Mac build (flash, arcs, beam and spit all appear with the
  viewmodel hidden; head-locked there, no bridge). On device: the flash at
  the drawn muzzle for the Glock, MP5, shotgun, .357, M249 and Desert Eagle;
  the gluon beam from the nozzle; the shock roach's arcs on the roach; one
  reload sound, not two.
- ~~Egon renders/aims as a viewmodel~~ (device check pending). In the Metal
  pass the egon's viewmodel holds in the hand like any gun (its grip pulled
  in, see the OF item), and the two "egon" special cases are gone: one flag,
  `g_vr_weapon_flat_cl` (client, copied to the server's `g_vr_weapon_flat` by
  the bridge), says when the gun on screen is the head-locked viewmodel — the
  Metal pass's flat fallback, or the engine path's for a p_ model with no
  right hand (that rule replaced the `strstr("egon")`) — and the server aim,
  the bullet events and the reticle all follow it. On device: the egon in the
  hand, its beam and damage along the barrel.
- ~~Shell casings eject off-axis~~ (device check pending). Stock places the
  shell at an offset from the eye: a point on the flat viewmodel. The
  platform now publishes the drawn gun's model transform and
  `VR_EV_ShellInfo` carries that point (and the throw) onto it, so shells
  leave the gun in the hand. On device: MP5, Glock, shotgun, M249.
- ~~Viewmodel parts parked out of frame float beside the gun~~ (device
  check pending). Loose parts — bones wholly outside the flat viewmodel's 90°
  frame in the rest pose and at least 7 units from everything in it: the
  Glock's and Desert Eagle's `Box02`, the speed loaders, the shotgun's shell,
  the spore launcher's spare spore — are hidden while they are out of that
  frame, and show once a reload brings them in (`ViewmodelGrip.looseParts` /
  `parkedBones`). Settings > Input > "Hide parked weapon parts". On device:
  nothing floats beside the Glock, .357 or shotgun; reloads still show the
  magazine, speed loader and shell.
- ~~Weapon Metal-pass backlog: external `…T.mdl` textures, MP5/hivehand
  grips, Settings~~. A model whose textures live in a companion `<name>T.mdl`
  is baked from it (the client loads it through the engine's file system,
  `g_vr_weapon_tex_hdr`; the warm-up reads it beside the model). No stock or
  expansion weapon needs it; checked against Blue Shift HD's split
  `barney.mdl`. The classic MP5 and hivehand already hold by a synthesised
  and a worn grip, and the Metal pass is Settings > Input > "Hand-tracked
  weapon model".

- ~~Guns sit rolled/offset in the hand; the crossbow fires left~~ — the gun's
  orientation came from Valve's hand bone, which sits differently on every
  rig (the classic MP5's synthesised hand frame put it 17° high and rolled).
  Aimed guns now take the viewmodel's own view-space axes (+X is the barrel
  on every model, measured) onto the hand, the grip bone only placing it
  (`ViewmodelGrip.Hold`, `modelMatrix`); thrown/placed items keep Valve's
  grip. Shots, tracers, decals and projectiles leave the drawn muzzle
  (attachment 0, else the gun's front) instead of the eyes —
  `g_vr_muzzle_offset` in `GetGunPosition`, `EV_VR_ApplyMuzzle` client-side,
  both falling back to the eye when a wall sits between — which is what made
  bolts land left of the crossbow. An aim reticle (Settings > Input) marks the
  client's trace of that same ray (`V_PublishAimHit`). The avatar probe checks
  every gun comes out aimed with its muzzle ahead of the hand.

- ~~Gaze+pinch `+use`~~ — superseded by the off-hand reach/poke `+use` in
  `HandMovement`.
- ~~Finger-curl trigger~~ — shipped as the finger-gun under "Immersive
  gesture input" (`Renderer.fireCurlOn`/`Off`). It replaces gaze+pinch
  fire while it is on rather than sitting alongside it.
- ~~Barrel aim reads slightly to the right~~ — the aim ray was wrist→middle
  knuckle while the gun was drawn through a tuned grip correction, so the two
  disagreed by a fixed rotation. The aim now follows the drawn barrel:
  viewmodels are authored in view space, so model +X read in the grip frame
  of the idle pose is where the gun points relative to the hand
  (`ViewmodelGrip.barrel`, 2–11° off the finger axis for most stock guns,
  measured). Idle rather than the current frame, so the shoot sequence's kick
  does not walk automatic fire upward. Viewmodels with no grip (the
  hivehand) keep the wrist→knuckle ray.

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
