# Plan — Modern lighting: reflections, glass and shadows

> **Status (2026-10-06): measurement plumbing and tier-1 glass (environment
> probe reflections, after a failed screen-space first version) built, both
> behind toggles; no headset numbers yet.** See "Progress" at the
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

**Identification — an engine stencil mask with a plane table.** ref/gl marks
glass in the stencil aspect of the depth texture the app already owns
(`r_vrglass 1`, `gl_rsurf.c` `R_VRGlass*` in `xash3d-visionos.patch`):

- glass = a brush entity drawn with `kRenderTransTexture` (how GoldSrc maps
  make windows: `func_breakable` / `func_wall`, rendermode Texture,
  material Glass), or any non-additive brush surface whose texture name
  contains `glass`. Texture-name prefixes alone (`{`, `!`) mean alpha-test
  and water, not glass, and `kRenderTransColor` is mostly solid colour
  fades, so neither is used. (Translucent water boxes such as the c1a2
  sink count too, and get the same reflection.)
- GoldSrc glass writes no depth (`R_SetRenderMode` masks it), so the
  depth buffer holds what is behind the pane. The stencil value is
  16 + a row of that view's **glass plane table** (`vr_glass_planes`,
  world-space normal and distance, up to 224 rows; codes 16–239; the
  engine's own stencil users write small counts). Every eye view refills
  the table; the bridge copies it after each eye with the eye's view
  (`vr_glass_view`, `lambda_glass_get_eye`). The plane places each glass
  pixel in the world: the eye's ray meets it at the same point for both
  eyes. (The first version stored a 15 × 15 quantised eye-space normal
  instead, which could orient a reflection but not place it.)
- Translucent brush entities already bypass the VBO path; with `r_vrglass`
  on, every brush entity draws surface by surface so each glass surface gets
  its code. World (non-entity) surfaces are not marked. A view with more
  than 224 glass planes in its frustum leaves the rest unmarked.
- Mods: the same rules or nothing. A game whose windows are something else
  simply shows no effect.

**What failed on the headset (first shading, 2026-10-06).** The reflection
was the frame itself: the reflected ray, as a direction, projected back into
the *current eye's* frustum and the engine image sampled there, faded to a
flat ambient colour where it left the frame. In the c1a2 office lab (the
flooded bench under the periodic-table poster) the pane showed a mirrored copy
of on-screen content (the faucet, the poster), flickered between that and no
reflection as the gaze moved, and de-synced between the eyes looking
sideways. The code confirms the reading: the lookup depended on what was on
screen, so moving the gaze moved content in and out of the reflection; each
eye's frustum is asymmetric and canted, so the same reflected direction fell
inside one eye's frame and outside the other's; and treating the frame as
infinitely far gave the reflection no parallax.

**Shading now — an environment probe (option a).** Options weighed:
(b) planar reflection is exact but costs a mirrored engine view per plane per
eye, against an engine already at 2–4 ms per eye in an 8.3 ms frame; (c) a
sturdier screen-space trace still loses everything off screen and needs a
shared fallback anyway — which is the probe. So the probe *is* the
reflection:

- **Capture** (`GlassProbe.swift`, ref/gl `R_VRProbeFace`, bridge
  `lambda_gl_worker_set_probe_face`): six 256² faces, 90° each along ±X ±Y ±Z,
  rendered by the engine from the head (midway between the eyes) into a
  colour and a depth texture of ours (2D arrays, three probes × six faces).
  One face per frame, drawn on the GL worker right after the second eye and
  before its fence, so that frame's composite may read it. Like an envshot a
  face draws the world and brush entities only (`RF_DRAW_CUBEMAP`: no
  studio models, sprites or viewmodel), and the probe pass also skips glass,
  particles, beams and the client's triangle callbacks: the static room. It
  uses the eyes' depth range so its depth decodes like theirs.
- **When:** only while glass is in sight (either eye's plane table was
  non-empty within the last second) and the probe is stale: the head has
  moved 48 units (1.2 m) from where it was captured, or 4 s have passed
  (doors, lights). Otherwise nothing is drawn. A level load or teleport
  (512 units) drops the probes; until the first new one is in, glass shows
  the old ambient guess.
- **No popping:** three probe slots — current, fading out, filling — so the
  engine never draws into one the composite still reads (Metal 4 tracks no
  hazards; a freed slot also rests `maxBuffersInFlight` frames). A completed
  probe fades in over 0.3 s, and a new capture waits for the fade to end.
- **Lookup** (`Shaders.metal` `glassShade` / `probeLookup`): per glass pixel,
  the eye ray meets the pane's plane at P; r = reflect(ray, n); the probe is
  walked three steps: read its distance where the current hit guess lies and
  move the hit to the ray's crossing of that sphere about the probe origin.
  That parallax correction is what makes a reflection from a probe captured
  away from the pane land in the right place, and gives each eye the mirrored
  room at its true distance. Same probe, same world point for both eyes:
  stereo-consistent by construction, gaze-independent by construction.
- **Tint:** what is seen through the pane is multiplied toward a faint glass
  green (`Renderer.glassTint` (0.80, 0.90, 0.88) at `glassTintAmount` 0.35),
  so panes read as glass head-on; the reflection then replaces
  F × strength of the pixel (Schlick, F0 0.04, capped at 0.85).
- **Cost:** per glass pixel one stencil read, three depth reads and one
  colour sample (twice during a fade); other pixels one stencil read. The
  face's ANGLE GPU time and the worker's CPU time for it log as `gProbe` and
  `probeCPU` in the `[FT] gpu(ms)` line (GPU side needs "GPU pass timing").

**Verified offline** on the Mac build (`r_vrdump` version 3 appends the plane
table; `r_vrprobedump N` writes the probe from the current view;
`Tools/DepthProbe` runs the real shaders), at the c1a2 bench and the c1a0
lobby windows:

| Check | c1a2 bench | c1a0 lobby |
|---|---|---|
| probe along the eye's own rays vs the engine image (probe at the eye) | 4.9 / 255 | 2.3 / 255 |
| same, probe 58 units away: plain lookup → parallax-corrected | 27.1 → 7.1 | — |
| same glass point, two gaze directions (same origin) | 0.6 / 255 | 0.4 / 255 |
| same glass point, two eyes 2.5 units (6.4 cm) apart | 4.2 / 255 | 4.8 / 255 |
| glass pixels without a probe reflection | 0 | 0 |
| pixels changed outside the mask | 0 | 0 |

The first row checks the face layout and depth decode against the engine;
the gaze row is the device bug's opposite (the reflection no longer depends
on where the eye looks); the stereo row differs only by true parallax.
Camera placement on the Mac is now exact: `sv_enttools_enable 1; noclip;
ent_fire 1 set origin "x y z"` (turn with `+left` and `host_framerate 0.01`).
Run the Mac engine with `SDL_MAC_BACKGROUND_APP=1` and `-noenginemouse
-window +m_ignore 1` so it never takes the mouse.

**To check on the headset** (Settings → Graphics glass toggle on; libxash
rebuilt; capture both eyes with the debug server's frame capture):

1. c1a2 office lab, the flooded bench under the periodic-table poster
   (the device screenshots; the sink's water box at about x 1225, y −260,
   z −555): stand about 1.5 m back, at x 1110, y −330, facing the poster
   (yaw ≈ 33°), looking down ≈ 17°. Capture both eyes: the sink top should
   show the ceiling and the poster's edge, the front face the floor behind
   you, the same in both eyes apart from a small shift.
2. Same spot, turn the head ±40° keeping the sink in view, then put it at the
   left and the right edge of the view: the reflection must not change or
   vanish, and both eye captures must show it.
3. c1a0 lobby, the interior windows along x −776 (y −690 to −450): from
   x −700, y −380 look along the wall (yaw ≈ 250°) for a grazing view, then
   walk along it: the corridor shows in the panes; a refresh (every 1.2 m)
   should only ever fade, never jump.
4. `[FT] gpu(ms)`: `gProbe` and `probeCPU` (expect well under 1 ms) and
   `gComposite` with the toggle on vs off.

**Left for tier 1:** tune strength, tint and the 0.85 cap on device; studio
models (scientists, items) do not reflect, and sprites drawn after the glass
still inherit its mark; worldspawn glass is not marked.

### 3b. Strength, and water (default off)

**Headset verdict on the glass probe (2026-10-06):** stereo and gaze fixed,
"looks good, but so faint and hard to notice" — at the c1a2 sink the
reflection was a faint lighter patch on the top and a barely visible floor
on the front. Physical glass (F0 0.04, nothing added head-on) disappears in
this art.

**Strength.** Settings → Graphics "Reflection strength", 0.5–4×, live,
default **3×** (`Renderer.reflectionStrength`, shared by glass and water).
The reflectance is (Schlick + a head-on floor) × strength, capped:

| | F0 | added head-on | cap | head-on at 3× | grazing |
|---|---|---|---|---|---|
| glass | 0.04 | 0.06 | 0.70 | 0.30 | 0.70 |
| water | 0.02 | 0.04 | 0.60 | 0.11 (× 0.6 share) | 0.60 |

The cap is what keeps a pane from ever turning opaque at the highest setting.
Water takes 0.6 of the strength: seen at grazing angles at 3× it washed its
own blue out to grey on the Mac dumps.

**Water** (Settings → Graphics "Water reflections (prototype)", default off;
`Renderer.waterReflections` + the engine's `r_vrwater`):

- **Marking:** every warp surface (`SURF_DRAWTURB`, the `!` textures) is
  marked as it is drawn — world water in `R_RenderBrushPoly` and the
  translucent-water pass `R_DrawWaterSurfaces`, brush entities (`func_water`,
  the c1a2 flood) in the brush-model loop — into the same plane table and
  codes as glass, with `vr_glass_kind` 1 for its row (bridge
  `lambda_glass_eye_t.kind`, packed as bits in `DisplayParams.glassKinds`).
  Additive water and the probe pass are left out.
- **Underwater:** water planes are stored facing up out of the water; a
  pixel whose eye is on the far side of its plane gets no reflection (the
  view from below the surface, or a vertical water face seen from inside).
- **Ripples:** four travelling sine waves of the world point (wavelengths
  11–39 units, speeds 1.7–4.3 rad/s) tilt the normal by slope 0.08
  (`Renderer.waterRippleSlope`), fading with distance so far water does not
  alias. World-space and a function of the point and time only, so both eyes
  see the same ripple; a ripple never sends the ray below the surface.
- **Probe above a water floor:** the probe sits at head height, above the
  water; every reflected ray leaves the surface upward, so its hit H lies
  above the plane and the line from the probe to H never crosses the water —
  the probe's view of the water itself is never sampled. The parallax walk
  handles the probe being far from a given water point. Water rows count as
  "in sight", so a flooded room keeps the probe fresh.

**Verified offline** (c1a2 flooded office lab, the device-capture view and
the same eye 25° turned and 2.5 units right; `Tools/DepthProbe`):

| Check | result |
|---|---|
| probe faces vs the engine view | 5.3 / 255 |
| water and glass pixels changed / outside the mask | 688 k / 0 |
| water pixels changed with the eye moved below the surface | 0 of 609 k |
| same surface point, two gaze directions | 1.3 / 255 |
| same surface point, two eyes (true parallax, larger on water near the feet) | 13.8 / 255 |
| each eye at the mirror image of the same reflected point | 1.3 / 255 |

The last row is the stereo check that matters for a mirror: it walks each
reflected ray to the point it shows, mirrors that in the plane and looks
where the image falls in the other eye.

**Cost.** Probe capture unchanged (one 256² world-only face per frame while
glass or water is in sight and the probe is stale; `gProbe` / `probeCPU`).
Composite: every pixel one stencil read; each glass or water pixel adds three
depth reads, one colour sample and the ripple's four sines (twice during a
0.3 s probe fade). The flooded floor covers about 30% of that view, so the
composite does roughly 1.3 extra texture fetches per pixel on average there;
expect a few tenths of a millisecond on `gComposite` at worst, nothing where
no glass or water is visible. Read `gComposite` with the toggles on and off
in that room to confirm.

**To check on the headset:** the c1a2 view from the device capture (x 1110,
y −330, yaw ≈ 33°, looking down ≈ 17°) with both toggles on: the flood in
front should show the shimmering, mirrored poster, fridge and ceiling, in
both eyes at a depth behind the water; the sink box's top clearly reflective.
Try strength 1×, 3× and 4×; duck the head toward the water and the
reflection should stay above it, never flip.

### 3c. Headset round 2: occluders, water colour, probe cost

**Occluders (fixed).** In c2a3a's ichthyosaur tank the fish, over the water,
was shaded as if under it. Only glass and water draws write the stencil code
(`GL_REPLACE`) and nothing drawn later clears it, so a model, sprite or brush
entity in front of a marked surface kept the code. The composite now
intersects the eye ray with the pixel's plane and skips the effect where the
engine depth is nearer than the plane (by 2 units + 2%): glass and
translucent water write no depth, so what is behind reads farther; opaque
water writes its own depth at the plane; the flat viewmodel decodes a few
units away. This also covers sprites drawn over a pane and NPCs crossing one.
`Tools/DepthProbe` puts a fake occluder 30 units from the eye over the middle
of the view: 122 k marked pixels under it, 0 shaded, 0 changed elsewhere.

**Water washed out (fixed).** Water on vs off (`build/screenshots/ab-water.png`
in the main checkout): the flood turned grey and pale with only blurry dark
smudges. Mixing the room's colour in, as glass does, replaced the water's
blue. Water now keeps its colour: the reflection modulates it by how bright
the reflected room is against the room's light (the engine's light at the
eye), clamped 0.2–3×, and only bright things (lamps) add light on top.
The mirror image reads as darker and lighter water.

**Probe cost.** Headset, c1a2 flood, first build: `gProbe` 2.2 ms GPU p50 /
4.0 ms p95 per 256² face, `probeCPU` 0.6 ms; frame 11.6 ms p50 (~86 fps)
against 8.3; `gComposite` 4.1, `gEngine0` 1.4, `gEngine1` 3.0. Changes:

- 128² faces (4× fewer pixels; the reflection is soft anyway).
- No dynamic lights in the probe pass: dlit surfaces (the gun's flashlight
  cone) used to rebuild and re-upload their lightmaps for every face.
- One EGLImage / renderbuffer / FBO kept per probe slice instead of a new
  render target per face (the app tells the worker when the probe textures
  are new).
- Refresh after 160 units (4 m) of head movement or 30 s, not 48 units / 4 s:
  standing in a room, one capture of six frames; running through the flood,
  one every ~0.6 s.

Not measurable on the Mac (desktop GL, not ANGLE on Metal). Expected on the
headset: `gProbe` well under 1 ms p50 per face (a quarter of the pixels, no
lightmap uploads, no render-target churn) and `probeCPU` ~0.3 ms, on 6 frames
per capture only; averaged, under 0.1 ms per frame. `gComposite` with the
toggles on vs off in the flood will show what the water shading itself
costs (per water pixel: one engine-depth read, two probe-walk depth reads, a
colour sample and four sines); the 4.1 ms includes the FXAA composite at
the drawable's resolution.

**Proposal, not built: screen-space planar reflection for large flat water.**
For horizontal water the plane is known exactly, so the sharp option is not a
generic ray-marched SSR but a screen-space *planar* reflection (as Far Cry 5
did): a compute pass per eye at half logical resolution mirrors each engine
pixel's world position across the water plane, projects it into that eye and
writes it into a reflection buffer (atomic min on depth to keep the nearest),
then the composite reads that buffer at water pixels and falls back to the
probe where it is empty.

- Quality: a sharp mirror of everything on screen, models included, with
  exactly the right per-eye parallax because each eye mirrors its own image.
  Looking along a flooded floor, most of what the water reflects (walls,
  doorways, NPCs ahead) is on screen. What is not — the ceiling right above,
  things behind the eye — comes from the probe, blended over a wide fade by
  how close the source was to the screen edge, so the hand-off cannot pop
  the way the first glass prototype did. The ripples apply as an offset to
  the lookup.
- Cost estimate: one scatter and one resolve over about 1.5 Mpx per eye at
  half resolution, roughly 0.3–0.6 ms GPU for both eyes; nothing on frames
  with no water marked. A ray-marched SSR (16–32 depth steps per water pixel)
  would cost 1–2 ms on a floor covering 30% of the view and still be blurrier
  near edges.
- Limits: horizontal planes only (one or a few per view); vertical glass
  stays probe-lit; reflections of things the eye cannot see stay soft.

### 3d. Calm ripples and sharp water (built, device check pending)

**Headset verdict on cebb5c0:** "nice reflections, but the movement is just
too active — thick and moving on its own, like an oil spill." Reference: the
visionOS lake environment — a near-mirror, crisp near the shore, fine slow
horizontal streaks that stretch reflections vertically, calmer toward the
horizon, no blobs.

**Ripple retune** (`Shaders.metal` `waterRipple`): six waves in different
directions, wavelengths 2.4–6.6 units (were 11–39), 0.4–1.1 rad/s, slope
0.008 at 1× (`Renderer.waterRippleSlope`, was 0.12); the tilt is applied in
full along the view direction on the surface and a quarter across it, so
reflections break up into vertical streaks; it fades as 1/(1 + d/120) with
distance and with grazing angle. GoldSrc's warp texture keeps its own
motion; the ripple adds little on top. Much of the "thick" look was the
lookup being bent by the old 0.12 slope through the probe walk. Settings →
Graphics "Water ripples" (0–3×, 0 = still mirror; debug API `waterRipples`).

**Sharp water reflections** (Settings "Sharp water reflections", on by
default under Water reflections; `Renderer.sharpWaterReflections`,
`SharpWater.swift`, `Shaders.metal` `ssprScatter`): the screen-space planar
reflection proposed in 3c.

- Each eye's plane: the highest horizontal water row (normal z > 0.99)
  below the eye in its plane table (`SharpWater.planes`).
- Scatter: one point per texel of a half-resolution target per eye
  (`Renderer.sharpWaterDivisor` 2), vertex amplification for both eyes in
  one draw: engine depth → world point W; W below the plane, the flat
  viewmodel, or anything mirrored behind the eye is dropped; W mirrored in
  the plane and projected back into the same eye; the depth test keeps the
  nearest mirrored point. Colour premultiplied by a confidence that falls
  off over the outer 15% of the frame (where the next head turn cuts the
  source off).
- Composite: at that plane's water pixels, read the target at the pixel,
  nudged by the ripple's tilt (2δ, vertical along the view), look a texel
  above and below to fill scatter gaps, and blend to the probe by the
  confidence. Occluder, underwater and mask rules unchanged.
- Each eye mirrors its own image, so the parallax is exactly a mirror's.

**Verified offline** (c1a2 flood, capture view; same eye 25° turned; an eye
apart; `Tools/DepthProbe` runs the scatter):

| Check | result |
|---|---|
| pixels changed outside glass/water | 0 |
| water pixels changed with the eye below the surface | 0 of 609 k |
| marked pixels under a fake occluder that got shaded | 0 of 122 k |
| final image at the same glass/water points, two gazes | 1.7 / 255 |
| a point mirrored, both eyes' mirrors (sampling baseline of the same point unmirrored) | 7.5 / 255 (6.6) |
| the same, two gazes (baseline) | 7.2 / 255 (1.7) |
| c1a0 glass: gaze / mirror-image stereo (probe path) | 0.4 / 0.3 / 255 |

The mirror differs more between gazes than its baseline because it holds
only what is on screen: when an occluder enters or leaves the frame the
mirror behind it changes. In the final image that is 1.7/255.

**Cost estimate** (not measurable on the Mac): about 1 M points per eye at
half resolution (an engine image of ~2200 × 1750), each one depth read, one
colour sample and a 2×2-pixel point with a depth test: roughly 0.5–1 ms GPU
for both eyes, only on frames where an eye has horizontal water below it in
view; the composite adds one to three samples per sharp-water pixel. If it
is too dear, `sharpWaterDivisor` 4 quarters it (~0.15–0.3 ms) at a softer
mirror. Read `gComposite` / `gpuQueue` with the toggle on and off.

**To check on the headset:** the c1a2 capture view, Water reflections and
Sharp water on, Water ripples 1×: the fridge, bench and fallen panel should
mirror crisply in the flood, broken only into fine vertical streaks; turn the
head: the mirror should not jump, and near the frame edge it should soften
into the probe rather than cut off. Try ripples 0× and 3×, sharp on and off.

### 3e. Sharp water, round 2: compute SSPR, mirror view, gMirror

**Headset (9a94b5d, c1a2 capture spot, p50):** water off gComposite 3.6 /
gpuQueue 4.6 / frame 9.9 ms; soft (probe) 4.3 / 5.3 / 11.2; sharp 9.7 /
10.3 / 17.4 (~57 fps). The point splat cost ~5.4 ms, not the 0.5–1
estimated, and the capture showed almost no mirror (a hint of the bench
legs), unlike the Mac renders. The calmer ripple and the colour retune
read well.

**Replaced the splat with a compute SSPR** (`Shaders.metal` `ssprProject` /
`ssprResolve`, `SharpWater.swift`): a fill of the key buffer and two
dispatches over a 1/3-resolution grid (`Renderer.sharpWaterDivisor` 3) for
both eyes. Project: each target texel's source point is mirrored and
projected, and the texel it lands on keeps, by 32-bit atomic min, the key
of the nearest one (12-bit log distance over the 10 + 10-bit source texel).
Resolve: decode (or take the nearest of four neighbours to fill gaps),
sample the engine image at the source, write premultiplied by the edge
confidence. No rasteriser, no depth target, no overdraw. Same composite,
same rules (occluder, underwater, mask, probe fallback).

**Why the device mirror was empty: not found from the code.** The splat's
geometry, conventions and data path match the Mac's, where DepthProbe runs
the same shaders and shows a full mirror (the device-like view: the vent,
wall and bench mirror clearly). Unverified suspects: point rasterisation
with vertex amplification into a layered target on the device, or the
mirror landing in place but reading as neutral under water's colour
modulation (a mirrored wall about as bright as the room's light changes
the water little; the Mac check uses a fixed room light). The splat is
gone; the compute path shares only the data path. To tell on device:
Settings → Diagnostics "Water mirror view" (debug API `waterMirrorView`):
`onWater` shows the mirror where the water is (magenta = probe fill),
`confidence` its weight, `whole` the target over the whole view (dim
magenta = empty).

**gMirror:** the mirror pass has its own counter-heap mark (`gMirror`, in
the `[FT] gpu(ms)` line and `GET /perf`, with GPU pass timing on), so
`gComposite` no longer includes it.

**Verified offline** (c1a2, same three views as 3d): 0 pixels changed
outside the mask, 0 underwater, 0 of 122 k under a fake occluder; final
image between gazes 2.0/255; one mirrored point in both eyes' mirrors
8.9/255 against a 5.8/255 sampling baseline. The mirror alone differs more
between gazes (13/255) because it holds only what is on screen.

**Expected cost:** ~0.4 M threads per eye per dispatch at 1/3 of a
~2200 × 1750 engine image, each one depth read and some ALU (project) or
one key read and a colour sample (resolve), plus a 3 MB fill: roughly
0.2–0.4 ms for both eyes, on frames with horizontal water below an eye.
`sharpWaterReflections` defaults off until `gMirror` confirms it. The
composite's extra sharp-water samples stay in `gComposite`.

### 3f. Sharp water, round 3: the blend, and a cheaper mirror

**Device (b9cdd6a, c1a2):** "Water mirror view" showed the mirror fully
populated and correctly mirrored (wall, vent, bench, ceiling grid, red
light; empty only where the source was off screen) — but the final image
showed plain blue water. The blend was the culprit: water was modulated by
the reflection's brightness against the room's light, which cancels a
mid-grey room to nothing however crisp the mirror. Cost: gMirror 1.24 ms
p50 / 2.91 p95, gComposite 3.79, gpuQueue 6.45 (4.63 with water off),
frame 12.2 ms.

**Blend, now:** water lerps toward its reflection by Fresnel × strength
(capped at 0.85, so at grazing angles the reflection dominates, as on the
lake), the reflection tinted by the water's own hue so it stays watery. The
sharp mirror gets the full weight and a light tint (30%); where only the
probe's soft room is available the weight halves and the tint rises to 50%,
which keeps the water's colour (the grey wash of round 1 came from that
soft room at full weight). "Reflection strength" still scales it. On the
Mac render of the device view the vent, bench and fridge now mirror clearly
in the flood, and the probe-only view stays blue with a soft room in it.

**Cost:** the mirror defaults to 1/4 resolution (`sharpWaterDivisor` 4, 56%
of the threads of 1/3), and both passes now skip texels that are not this
plane's water in the engine's stencil: a mirrored point that lands
elsewhere takes no atomic, and the resolve does nothing there (about 60% of
the texels at the c1a2 spot). Expected gMirror ≈ 0.5–0.7 ms p50. The pass is
split for profiling: `gMirrorFill` (the 0xFF fill of the key buffer),
`gMirrorProject` (projection + atomics) and `gMirror` (resolve), precise
timestamps between the dispatches. From the code the projection should
dominate (full depth decode and projection per texel, scattered atomics);
the fill is ~2 MB. Ship at 4 if gMirror lands near 0.5 ms; 3 only if the
mirror looks too soft and there is headroom.

**Verified offline:** 0 pixels changed outside the mask, 0 underwater,
0 of 122 k under a fake occluder; final image between gazes 2.1/255; a
mirrored point in both eyes' mirrors 8.0/255 against a 4.5 baseline.

### Presets (planned)

Graphics will collapse to two presets: **Modern** freely combines the new
techniques (reflections, sharp water, reprojection depth, linear colour and
later tiers), **Original** is the stock Half-Life look. Rule for every
feature until then and after: it stays its own setting with a clearly named
knob (toggle or slider, also on the debug API), so under either preset each
effect can still be changed individually, PC-style.

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
  `gComposite`-sized slot in the budget. The glass probe (tier 1) is
  already the fallback for rays that leave the screen.

