# Plan — Modern lighting: reflections, glass and shadows

> **Status (2026-10-06): measurement plumbing and a tier-1 glass prototype
> built, both behind toggles; no headset numbers yet.** See "Progress" at the
> end. Numbers quoted from Oneiros are from its notes, not re-measured for
> this app.

## Goal

Bring modern lighting to the stock Half-Life look: believable windows and glass,
reflective floors and puddles, and eventually real-time shadows and ray-traced
reflections where the hardware allows. The art stays Half-Life's.

## Starting point

- The game is fixed-function: lightmapped BSP, studio models, sprites. `ref_gl`
  has no shaders of its own; under ANGLE the `gl-wes-v2` / `gl4es` shims
  generate GLSL to emulate fixed-function state.
- The engine renders into a colour map and a depth texture that **we own**: ANGLE
  draws both into Metal textures with per-eye slice views (`Renderer.swift`
  `colorMap`, `engineDepth`, `engineDepthLayerViews`). `LoadSnapshot` already
  reads that depth on device. So Metal passes can use real depth on the GPU,
  with no readback. (`R_DumpViewForVR` in `gl_rmain.c` is the desktop-only CPU
  dump of the same data, compiled out on visionOS; it documents the matrix and
  depth conventions and feeds `SnapshotProbe`.)
- The app already composites in Metal (`Shaders.metal` and friends), so extra
  passes can go between the engine's frame and the composite.
- Budget: stable 120 FPS stereo, foveated. The MetalFX attempt that was removed
  (`PLAN.md`, Phase 2d) is **not** evidence about the real budget: it was a poor
  choice of technique. MetalFX temporal scaling is also noted as unavailable on
  visionOS in Oneiros's notes. Measure the real headroom before sizing anything.

## What Oneiros already learned

Source: `~/Projects/Oneiros/.claude/rules/compositor-metal4-backend.md` and
`KNOWN_ISSUES.md`. Read the first before starting; it holds the pitfalls.

- Default shadows are raster cascaded shadow maps (three 1024² cascades shared
  by both eyes). They run on M2. Ray-traced shadows and emissive lights exist as
  optional reference paths only.
- Hardware ray tracing (`MTLAccelerationStructure`) is gated on Apple9+; Apple8
  (M2) traversal is too slow, so it falls back to raster. The M5 headset has
  ray tracing cores; the first-generation headset does not.
- On the M5: per-fragment RT about 30–45 ms GPU with serious thermals; low-res
  RT 29.3 ms median against 10.6 ms raster (short, throttled run, not a
  sustained 90 Hz test). Terrain baseline 120 fps at about 5–8 ms.
- Pitfalls: guessing normals from depth under foveation gives streaks and
  self-shadowing (fix: lift the ray origin toward the eye); depth must stay in
  the compositor's range (depth 0 showed black on device); resources allocated
  mid-frame must join the residency set; logical-space bloom handles foveation.
- Reflections, GI and god rays are only "planned" there. No reflection code to
  copy.

## Tiers, cheapest first

1. **Windows and glass.** Alpha-blended glass with a Fresnel term and an
   environment or cube-map sample. Runs on any chip. Same family as the Crossbow
   scope glass idea in `ISSUES.md`.
2. **Planar reflections** for flat floors and puddles: render the scene a second
   time per reflective plane. Doubles the cost for those views, so limit to
   visible planes.
3. **Screen-space reflections** from the engine depth and colour. Check
   Oneiros's normal-from-depth findings first. Needs a fallback to the
   environment sample for rays that leave the screen.
4. **Raster shadows**: cascaded shadow maps as Oneiros does them, from BSP and
   studio-model geometry in a Metal pass. M2-capable.
5. **Hardware ray-traced reflections / GI**, M5-only: build acceleration
   structures from BSP geometry on the Metal side (the GL path cannot), trace at
   reduced resolution for chosen materials only. Unverified idea; the GL stack
   itself cannot do it, but this app has its own Metal passes.

## Open questions

- Which chip(s) are we targeting, and do we gate by capability like Oneiros
  (`RTCapabilities`)?
- Real GPU headroom per frame at 120 FPS on the target device (profile a real
  frame before committing to a tier).
- How to know which BSP surfaces are windows, glass or reflective: texture
  name conventions (`{` transparent, `!` water) and render modes may be enough
  for glass; floors need a name list or a per-map override.
- Where the passes sit relative to foveation (render in logical space, as
  Oneiros does for bloom).
- Compatibility with other games and mods the app can load (`ISSUES.md`,
  "compiled games and mods"): effects must degrade, not break.

## Progress

### 1. Measuring the budget (built, device numbers pending)

The old `[FT]` columns could not size anything: `angleGPU` and `frameGPU`
are CPU wall times from eye submission to a shared-event listener firing,
so they add queueing and listener latency to GPU work (Oneiros hit the same
trap). `GPUPassTimer` now reports GPU execution itself:

| Column | What | Source | When |
|---|---|---|---|
| `gpuQueue` | our command buffer, start → end | Metal 4 commit feedback | always |
| `gEngine0`, `gEngine1` | ANGLE's GPU time per eye | `GL_EXT_disjoint_timer_query` on the GL worker | "GPU pass timing" on |
| `gComposite` | composite (engine image → drawable) | counter-heap timestamps | "GPU pass timing" on |
| `gArms` | wireframe arms | " | " |
| `gWeapon` | gun + body | " | " |
| `gHUD` | HEV holograms (precise timestamp inside the weapon encoder) | " | " |
| `gDepth` | reprojection-depth merge | " | " |

The Performance HUD sums engine + ours at p50 and p95 against 8.33 ms
(120 Hz) and prints the headroom; the log gets `[FT] gpu(ms)` every 512
frames. Settings → Diagnostics → "GPU pass timing" turns on the per-pass
and engine timers (off by default: the HUD split can split the weapon
encoder). If ANGLE does not expose the timer extension, the worker logs
`[FT] GL timer queries unavailable` and the engine columns stay empty.

**To fill in on device** (p50 / p95 ms, with the thermal state):

| Scene | engine (both eyes) | ours | headroom |
|---|---|---|---|
| c0a0 tram ride | | | |
| c1a0 lobby | | | |
| c1a0d test chamber | | | |
| firefight (c2a1 / c2a5) | | | |

Sanity check: `gpuQueue` should be close to the sum of our passes. If it is
much larger, commit feedback is counting the queue's wait on ANGLE's fence.

### 2. Per-pixel reprojection depth (built, default off)

Not lighting, but it shares the plumbing and the depth conventions every
later tier needs. The composite converts the engine's GL window depth to
eye distance and back through the compositor's own projection
(`Shaders.metal` `compositorDepth`), and the gun/body depth is merged over
it (`ReprojectionDepth.swift`). `Tools/DepthProbe` runs the real shaders on
Mac `r_vrdump` frames: every pixel unprojects to within 3e-4 (relative) of
the engine's point for an infinite and a finite reverse-Z projection. The
engine's GL depth is standard Z with near 4 units (10 cm) and far
28,343 units (720 m); the flat viewmodel is squeezed into the front 30% of
the range and decodes under 16 cm, which is how it is told apart.

### 3. Tier 1, windows and glass (prototype, default off)

**Identification — decided: an engine stencil mask.** ref/gl marks glass in
the stencil aspect of the depth texture the app already owns
(`r_vrglass 1`, `gl_rsurf.c` `R_VRGlass*` in `xash3d-visionos.patch`):

- glass = a brush entity drawn with `kRenderTransTexture` (how GoldSrc maps
  make windows: `func_breakable` / `func_wall`, rendermode Texture,
  material Glass), or any non-additive brush surface whose texture name
  contains `glass`. Texture-name prefixes alone (`{`, `!`) mean alpha-test
  and water, not glass, and `kRenderTransColor` is mostly solid colour
  fades, so neither is used.
- GoldSrc glass writes no depth (`R_SetRenderMode` masks it), so the
  depth buffer holds what is behind the pane and cannot give a normal. The
  stencil value carries it instead: 16 + the eye-space normal's x and y
  quantised to 15 steps each (codes 16–240; the engine's own stencil users
  write small counts). A pane is planar, so it gets one code; the ~6°
  quantisation only biases its Fresnel angle.
- Translucent brush entities already bypass the VBO path; with `r_vrglass`
  on, every brush entity draws surface by surface so each glass surface gets
  its code. World (non-entity) surfaces are not marked.
- Mods: the same rules or nothing. A game whose windows are something else
  simply shows no effect.

**Shading.** Inside the composite (a `kGlass` function-constant variant,
pipelines indexed by variant bits), no extra pass: one stencil read per
pixel, and on glass only, Schlick Fresnel (F0 0.04) mixing in an
environment sample. The environment is the frame itself: the reflected ray,
as a direction, is projected back into the eye's frustum and the engine
image sampled there, faded to the room's light (the engine's light probe at
the eye, halved) where it leaves the frame. That is right where glass
reflects most — looking along a glass wall, the reflection shows the
corridor ahead — and head-on the ray points behind the eye where F is 4%
anyway.

**Verified offline** on the Mac build in c1a0: `r_vrdump` now appends the
stencil (dump version 2); the mask lies exactly on the panes, the codes
decode to the wall's normal as seen from the dumped yaw (code 38 for a +x
wall at yaw 240°), and `Tools/DepthProbe --png` renders plain vs glass: only
marked pixels change, and at a grazing angle the pane shows the mirrored
frame and corridor. Deterministic camera placement on the Mac:
`sv_cheats 1; noclip; host_framerate 0.01; cl_yawspeed 100`, then `+left` /
`+forward` for a counted number of `wait`s (1° and ~3.2 units per frame).

**Left for tier 1:**

- A headset look: strength, F0, the 0.85 cap and the ambient guess are
  first values. Settings has only the toggle (`Renderer.glassStrength`).
- The device needs a libxash rebuild (`build_xash_libxash.sh`) to have
  `r_vrglass`; without it the toggle changes nothing.
- The pane's own tint: TransTexture glass is the texture at `renderamt`
  over the scene; the reflection is mixed over that result rather than
  under the glass colour.
- The "environment" is only what is on screen. A real one: a low-res cube
  probe per map, captured while the load snapshot holds the view (the engine
  renders six views of the new level during the load), or around the player
  on a slow cadence. That is also tier 3's fallback for rays that leave the
  screen.
- Sprites and particles drawn after the glass inherit its mark (they keep
  the reflection over them). Worldspawn glass is not marked.
- Cost: unmeasured — one `r8` read per pixel plus one sample per glass
  pixel should be a fraction of the composite; read `gComposite` with the
  toggle on and off.

### Decisions on the open questions

- **Target chips:** tiers 1–4 must hold 120 FPS on the first-generation
  (M2) headset as well as the M5; nothing so far needs gating. Hardware ray
  tracing (tier 5) stays out until the budget table says there is room, and
  then gates like Oneiros's `RTCapabilities`.
- **Headroom:** measured per pass by the HUD above; the table is the next
  step, before sizing tier 2 or 3.
- **Identifying surfaces:** glass via the engine's stencil (above). Floors
  and puddles for tier 2/3 need more than rendermode: a texture-name list
  per game plus a per-map override, and they do write depth, so their
  normals can come from depth.
- **Foveation:** the composite samples in logical space (interpolated uv
  with the rate map bound), so tier 1's lookups are already
  foveation-correct. Any blur or screen-space pass should run in logical
  space, as Oneiros's bloom does.
- **Mods:** every effect keys off engine data (rendermode, texture names,
  depth), never Half-Life's map or texture lists without a fallback, and
  shows nothing where its data is missing.

### What the next tier needs

- **Tier 2 (planar reflections):** a second engine render per reflective
  plane, mirrored, into a texture the composite reads — in ref/gl, since
  only the engine can redraw the world. Needs the floor list, a stencil or
  plane id for those surfaces, and `gEngine` headroom (it roughly doubles
  engine cost for the views that show a plane).
- **Tier 3 (screen-space reflections):** feasible in a Metal pass now: engine
  colour and depth are on the GPU, opaque surfaces write depth, and the
  depth→eye conversion is `compositorDepth`'s. Needs normals (from depth, with
  Oneiros's foveation caveat), the cube-probe fallback above, and a
  `gComposite`-sized slot in the budget.

