# Sharp water reflections — handoff (2026-10-07, branch p8-water, round 12)

Self-contained state of the glass/water reflection work for the next agent.
Longer history: `docs/plans/modern-lighting.md` sections 3–3l, `ISSUES.md`.

## What exists

Settings → Graphics (all live, all also on the debug API `settingsTable` in
`DebugEndpoints.swift`): "Glass reflections" (`glassReflections`, engine
`r_vrglass`), "Water reflections" (`waterReflections`, `r_vrwater`), "Sharp
water reflections" (`sharpWaterReflections`, default **off**), "Reflection
strength" (0.5–4×, default 3×), "Water ripples" (0–3×, default 1×).
Diagnostics: "Water mirror view" (`waterMirrorView`: off / onWater /
confidence / whole). Rule from the user: every effect keeps its own named
knob; Modern/Original presets come later (`docs/plans/modern-lighting.md`
"Presets (planned)").

### Engine side (`VisionPort/xash3d-visionos.patch`, ref/gl)
- `gl_rsurf.c` `R_VRGlass*`: glass (TransTexture brush ents / `*glass*`
  textures) and water (SURF_DRAWTURB, r_vrwater) write stencil code 16+row of
  a per-eye world-plane table `vr_glass_planes[224][4]`, `vr_glass_kind[]`
  (1 = water, plane faces up). Table reset per eye view in `R_RenderFrame`.
- `gl_rmain.c` `R_VRProbeFace(origin, face, size, zn, zf)`: one 90° face of the
  environment probe (world + brush only, no glass/particles/dlights).
  Mac-only `r_vrdump N` (v4: + stencil, plane table, kinds) and
  `r_vrprobedump N`.
- Bridge `Lambda_Bridge.c`: `lambda_glass_get_eye`, staged probe faces
  (`lambda_gl_worker_set_probe_face`, kept FBO per slice), `lambda_gl_probe_ms`.
- Regenerate the patch with `git -C VisionPort/xash3d-fwgs diff HEAD
  --ignore-submodules > VisionPort/xash3d-visionos.patch`; rebuild device lib
  with `VisionPort/build_xash_libxash.sh && VisionPort/pack_libxash.sh`.
  (No engine change since the water round; current work is app-only.)

### App side
- `GlassProbe.swift`: probe schedule (128² faces, one per frame after eye 2,
  refresh after 160 units / 30 s while glass/water in sight, 3 slots, 0.3 s fade).
- `Shaders.metal` `glassShade` (composite, kGlass variant): stencil → plane
  row → world point P; occluder rule (engine depth nearer than plane → skip);
  water from below → skip; `waterRipple` (6 waves, 2.4–6.6 units, slope
  `Renderer.waterRippleSlope` 0.008 × "Water ripples", per-wave band limit by
  on-screen period, fold cap tilt ≤ 0.08·periodPx·pixTan); Fresnel × strength
  capped (`Renderer.reflectionCap` 0.7 glass / 0.85 water, head-on add
  0.06/0.04, water gets `waterStrengthScale` 0.6); water blend = lerp toward
  env tinted by water hue (sharp: full weight, 30% tint; probe-only: half
  weight, 50% tint). Sharp mirror read: coverage from un-rippled uv, colour
  from rippled uv (offset clamped to 1.5 mirror texels). Probe skipped where
  mirror ≥ 98% confident.
- `SharpWater.swift` + `Shaders.metal` (SSPR, compute, both eyes in one grid,
  target = engine size / `Renderer.sharpWaterDivisor` (4)):
  1. `ssprClear` — keys = 0xFFFFFFFF (uint4/thread). Timer `gMirrorFill`.
  2. `ssprProject` — per target-grid source texel: engine depth → W; drop
     viewmodel (z<6), W below plane; mirror W in plane `sspr[eye].y`,
     project, keep only targets that are this plane's water (stencil).
     **Back faces → occluders**: facing from the engine depth's +x/+y
     neighbours (the other side where one steps off an edge) against the
     mirrored eye (`SSPR_BACKFACE` 0.1); a table/counter top is one. Glass/
     water-marked sources (stencil ≥ 16) keep only occluders (the counter
     under the sink's water box). atomic_min key = 11-bit log distance |
     occluder flag | 10-bit src y | 10-bit src x (a surface wins a tie).
     **Occluder claims** (round 12): an occluder also writes its key along
     the line to its +y source neighbour's image (and to its ±x neighbour's
     at the top's side edges); past the top's edge that neighbour is taken
     where its ray meets the top's plane (≤ 256 units), at most `SSPR_SPAN`
     (48) texels. Timer `gMirrorProject`.
  3. `ssprResolve` (threadgroups of 16 × 8, which the tile below assumes) —
     the group's keys plus `SSPR_FILL` (6) texels around are loaded into
     threadgroup memory once. Candidates: own key, the **nearest** (by
     distance) surface key up and down within 6, left/right; the nearest
     occluder key in each of the four directions within 6; surfaces merged
     if same distance, occluders if same height (≤ 5 surfaces, ≤ 3 occluder
     heights). **Occluder test** (`ssprOcclude`) once per texel on its centre
     ray: where the ray climbs to an occluder's height − `SSPR_SLAB` (4) and
     to its height, a surface on screen on or in front of that point, at the
     occluder's height (between hz − 5 and hz + 1: the top or rim, not a leg)
     → blocked; results shared through threadgroup memory. `SSPR_SUB_X×Y`
     (2×2) exact mirrored rays per texel: each surface's depth → exact source
     coord → verify with engine depth (smallest miss wins; single surface
     skips verify unless a block is near; surfaces whose real distance lies
     past the texel's block skipped; none → first surface's own source,
     unless blocked). A sub-ray whose texel and three neighbours toward it
     agree takes the texel's block; at an outline it runs its own test.
     Blocked nearer than the shown surface → **underside**: the top right
     above the point reached, × `waterDebug.y` ("waterUnderside", 0.35; 0 =
     probe), confidence from that sample's frame edge. Surface colour = 4
     bilinear taps ±0.5 px (2×2 box); confidence = edge fade (15%) of the
     **mean exact projection of all surfaces**. Timer `gMirror`.
  Plane choice: `SharpWater.planes` = highest horizontal water row below the
  eye. Renderer encodes it before the composite only when an eye has one.
- GPU timers: `GPUPassTimer` marks start, mirrorFill, mirrorProject, mirror,
  composite…; `/perf` and `[FT] gpu(ms)` line, needs "GPU pass timing".

## Device-reported bugs and status

| Bug | Status |
|---|---|
| Frame-sampled glass reflection popped with gaze / desynced eyes | fixed (probe) |
| Glass too faint | fixed (strength 3×, head-on add) |
| Ripple "oily" | fixed (fine, slow, band-limited) |
| Models over water tinted (c2a3a ichthyosaur) | fixed (occluder depth rule) |
| Water washed grey / mirror invisible | fixed (hue-tinted Fresnel lerp; ratio blend cancelled mid-grey) |
| Point-splat SSPR 5.4 ms, empty mirror | replaced by compute SSPR |
| Vent grate flicker (sub-pixel snapping) | fixed (exact rays, 2×2, verified candidates) |
| Moiré in mirrored sink water box | fixed on device per first capture (glass/water sources rejected + 2×2 box) |
| Prefilter pass 1.75 ms | fixed (box taps in resolve) |
| Wavy lines following ripple (comb) | reduced in 96c7ddc (composite neighbour search removed, 8-row fill); **b2e7e18 untested on device**: smooth confidence + ripple-free coverage |
| Comb across the whole mirrored table underside | fixed on device by round 11 (3c8241d) |
| Underside looks transparent, depends on head pitch | jagged see-through fixed on device by round 11 |
| Underside a blur showing the cabinet (probe fallback) | **round 12 untested**: underside fill (`waterUnderside`) |
| Close, crouched: row of blocks at the table's mirrored edge, stair-stepped rim/underside outline | **round 12 untested**: occluder claims to the top's edges, 4-way occluder gather, outline tests per sub-ray; view 91 see-through 9.5% → 0.05% |
| Right eye only: dark stipple near the far legs (strong roll) | **not reproduced offline**; round 12's both-eye and rolled-stereo checks pass on 3c8241d and now; see round 12 |
| Both eyes: blocky occluder edges under the near table | **round 12 untested**: as the close-up row |

### Round 11: why the table was transparent, and the fix
The eye sees the steel table's top; the reflected ray always climbs, so it
meets that top from below — a back face, behind the underside no frame
holds. b2e7e18 mirrored the top as a colour; seen more head-on in the mirror
than on screen, its texels landed on every other mirror row, and the room
behind (the locker) won the rows between by atomic min: the comb, the
transparency, and its change with pitch (the magnification changes). The
8-step march could not catch it: its steps (reach/9, ~12 units of climb)
jumped over a layer a few units thick, and it marched only the texel centre.
Fix (`Shaders.metal`, project + resolve, above): back faces are stored as
occluders, so they win those texels without a colour, and each sub-ray is
tested exactly where it climbs to an occluder's height (a table top is
level; the ray's nearest point to one sparse texel can sit 20 units under
it). Two details mattered: the sample's real distance (`length(A − P)` at
bestSrc, not the candidate's projection on the ray — an unverified candidate
showed the far wall from "28 units" away) and choosing among surfaces short
of the block (else rows alternated between the bench's cabinet face and the
wall behind, and the block turned that into rows of probe).

What to look at on the headset (c1a2, 963 −471 −542, yaw 15, pitch −5…30):
under the table the mirror should fall smoothly to the probe (watery room)
with straight edges along the table's outline, the legs and rim still
reflected, no locker; at the bench (1110 −330 −540) no comb under the
counter, `waterMirrorView=confidence` without step-shaped strips. Residuals
offline: 1-texel strips at the bench's waterline and the table's far
corners (≤ 2.9% of hidden-underside rays), and sparse light dots in the
counter's shadow band at view 62.

If it still shows: `SSPR_SLAB` (4) is the assumed thickness (thicker tops
need more); `SSPR_BACKFACE` (0.1) decides what counts as a top.

### Round 12: underside, close-up stairs, roll, cost
Device on 3c8241d: see-through gone; resolve 1.25 ms (project 0.44, fill
0.03, total 1.72). Four reports and what came of them:
1. *Underside a blur showing the cabinet.* The probe is a world-fixed cube
   that knows nothing of the table. A blocked sub-ray now shows the top
   right above the point it reached (on screen, continuous, the same world
   spot for either test height, so stereo-consistent) at `waterUnderside`
   (0.35) of its brightness; the debug API key A/Bs it live (0 = round 11's
   probe). The first try sampled the occluder's own source pixel or the
   crossing's screen point: bands, since rim and top alternated per texel.
2. *Close, crouched (view 91: eye level with the top).* The top is a few
   source rows seen edge-on that mirror across dozens of rows; the resolve's
   8-row fill missed most, and the room behind won (see-through 9.5%). The
   occluder claims (project) fill between rows; the first version stopped a
   source row short of the top's edge at every row, so the claimed patch,
   and with it the underside, was a staircase. Claims now run to where the
   neighbour's ray meets the top's plane, the resolve gathers occluders four
   ways, and the occluder hit must be a surface at the occluder's height (a
   leg in front had produced stripes beside the table). The underside's
   confidence comes from its own sample (the surfaces' projections ran off
   the frame and the probe showed through in steps).
3. *Right eye only, strong roll: dark stipple.* Not reproduced. New checks:
   rolled stereo pairs (93/94 @+30°, 93/95 @−30°, @±55° by hand) and both
   eye slices dispatched together; both pass on 3c8241d and on round 12. The
   both-eye check did catch one real slip during this round (the key tile
   loaded with a fixed thread stride; groups at the grid's edge have fewer
   threads, garbage differed per slice) — fixed before commit. An early
   roll synthesis with nearest-sampled depth made a grazing top's facing
   flip in rows (stripes like the report); natively rendered depth does not
   do that, so if the stipple returns, check `waterMirrorView=onWater` in
   that eye and the occluder keys (`SSPR_KEYS`) with a dump of that pose.
4. *Blocky occluder edges under the near table.* Same family as 2.
Cost: per-sub-ray occluder tests were half the resolve; now one test per
texel plus outline sub-rays, the key tile in threadgroup memory, and
`SSPR_FILL` 8 → 6 (4 fails the comb check at 91: +2.67). Per-surface
arrays for re-choosing were dropped (register pressure: the whole sub-ray
loop slowed with them even when nothing was blocked).

What to look at on the headset: under the table (81–88 pose, 963 −471
−542) a darker, slightly textured underside instead of the locker blur;
`waterUnderside` 0…1 on the debug API to taste. Crouched close (1023 −479,
eye −543.5, pitch 13, yaw −10.5): one smooth underside between the legs,
no row of blocks at the mirrored edge, no stairs. Rolled head: no stipple
in either eye. Residuals offline: stretched side-rim texels beside the
underside at view 91 (dark, reads as underside), a few light dots near the
far edge there.

## Hypotheses ruled out (and why)
- Device rasterisation/data bug for the empty splat mirror: "whole" mirror
  view on device was correct; the blend cancelled it.
- 963b205's stencil-free fill causing the grate flicker: 190007a and 963b205
  give identical water pixels offline; cause was per-texel snapping.
- Ripple causing the c1a2 box moiré: user A/B showed sharp mirror, ripple 0.
- The resolve's choice between unverified candidates causing the comb: a
  miss-rejection variant changed nothing offline; the composite's ±1-texel
  coverage search was the cause.

## DepthProbe (`LambdaVision/Tools/DepthProbe`, `./build.sh [--png DIR] dumps… probes…`)
Runs the real shaders on Mac dumps. Env: `SHARP=0` (probe only), `RIPPLE=x`
(slope), `SSPRDIV=n`. Checks and pass rules:
- probe view vs engine image (≤12/255 at the eye; parallax walk beats plain)
- mask: 0 px changed outside glass/water; 0 water px changed with eye below
- occluders: fake model 30 units over view centre → 0 marked px shaded
- gaze (same origin): final image ≤3/255; stereo (same gaze, 2.5 units):
  mirror-image comparison ≤ baseline·1.5+2
- sub-pixel stability (shift 0.3/0.5 px, +1/90 s, +0.1 s ripple): p99 ≤
  plain+14, mean ≤ plain+1.2 (old 190007a/963b205 fail: p99 +21)
- hatching (vertical 2nd difference on water, ripple 0/1/3×): 1× ≤ 0×+0.2,
  3× ≤ 0×+0.6 (d7868d3 fails at dump 41)
- mirrored glass/water region at 2× composite, sharp vs soft ≤ +0.5
  (does **not** reproduce the device moiré; guard only)
- mirror rows comb: 2× composite, ripple on, worst 48-px tile ≤ soft+2.0
  (aadfa42 fails +2.86 at dump 51)
- **see-through** (round 11): each mirror sub-ray's reflected ray traced in
  fine steps through the engine depth, every visible surface a slab 4 units
  deep (climbing to it must keep the visible depth continuous, so the region
  behind a table's edge does not count); of the rays that meet a hidden
  underside first, the confidence-weighted share the mirror shows clearly
  farther (> 1.05·hit + 8; the resolve's `SSPR_DEBUG` record) must be ≤ 3%.
  b2e7e18: 81–88 6–19%, 41 12%, 71–73 4–6.5%, 33 4%; round 11 ≤ 2.9% but
  91 9.5%; round 12 ≤ 0.9% everywhere (91 0.05%).
- **both eyes** (round 12): project + resolve dispatched as the app does
  (grid depth 2, the same view in both slices): slices identical.
- **rolled heads** (round 12): `vrdumpN.bin@deg` re-renders a dump rolled
  about its forward axis; 93/94@30 and 93/95@−30 are stereo pairs an eye
  apart along the rolled right vector (stereo rule as above).
Tool switches: `SHADERS=path/Shaders.metal` runs another version (A/B; the
file must end in .metal; add the `SSPR_DEBUG` blocks to an old one),
`SSPR_DEFINES=-D…` overrides shader constants, `SSPR_TIMING=1` times
project/resolve on the Mac GPU (50 dispatches per command buffer; only
ratios carry over), `SSPR_KEYS=prefix` dumps the key buffer and the debug
record, `UNDERSIDE=x` the underside brightness (0.35), `MIRRORVIEW=1|2|3`.
Known failing, not regressions: gaze pairs that differ in pitch/yaw at
views 62/63, 71–74 and 81–88 (4–7/255; the mirror holds only what is on
screen) and the probe view at 63 (13.0, probe from 62's origin).
Known limit: the device composite runs at ~2.3× the engine resolution with
foveation; some artifacts (box moiré) never reproduced on the Mac.

### Harness views (Mac dumps in `build/mac-run/`, gitignored; regenerate)
c1a2 flooded office lab (water plane z −568, func_water; sink water box
func_illusionary rm2 near the periodic-table poster at x≈1281):
- 31 (eye 1110 −330, yaw 33, pitch 17) / 32 (same origin, yaw +25) / 33 (2.5
  units right of 31); probe 31. Gaze/stereo pairs.
- 41 (1250 −420, yaw 180: vent wall, bench, fridge — the device view).
- 51 (1160 −390, yaw ≈45, pitch ≈35: bench face meeting the flood — comb).
- 61 (1170 −330 looking down), 62/63 (1110 −330 −540, pitch ≈35).
- 71–74 (1230 −400, yaw 199, pitch 0/12/25/37: steel table, pitch series).
- 81–88 (eye 963 −471 −514 = origin z −542, yaw 15.2: the device's
  transparent-table view; pitch −2/3/8/15/23/33, 87 −5, 88 11.6); probe 81.
- 91 (eye 1023.4 −479.1 −543.5 = origin z −571.5, yaw 349.5, pitch 13: the
  device's close, crouched capture; eye level with the table top); probe 91.
- 93 (eye 1023 −479 −514, yaw 349.5, pitch 35), 94 / 95 (2.5 units along
  the right vector of that view rolled +30° / −30°); probe 93.
  Groups as run: 9 10 11 +probe9; 31 32 33 +31; 41 +41; 51 +51; 61 +61;
  62 63 +62; 71–74 +71; 81–88 +81; 91 +91; 93 94 93@30 94@30 93@-30 95@-30
  +93 (one probe per run: the first).
c1a0 lobby windows: 9/10/11 (−700 −380, yaw 251; glass regression).
Each dump needs its own probe (`r_vrprobedump`) from the same origin.

### Scene setup (Mac engine, background-safe — never omit these flags)
```
cd build/mac-run
SDL_MAC_BACKGROUND_APP=1 timeout 150 ./xash3d -game valve -dev 1 -window -nomsgbox \
  -noenginemouse -width 960 -height 540 +m_ignore 1 +exec <cfg>
```
Keep `valve/video.cfg` at `fullscreen "0"` (else dumps are 5120×2880).
cfg: `sv_cheats 1; sv_enttools_enable 1; r_vrglass 1; r_vrwater 1; map c1a2;`
wait chains (`alias w1 "wait;…×100"`), `noclip; god; host_framerate 0.01;
cl_yawspeed 100; ent_fire 1 set origin "x y z"` (exact; eye = origin+28;
`god` because the c1a2 flood is electrified and kills a player standing in
it mid-script; spawn view is yaw 180, pitch −2; at `cl_yawspeed 10` /
`cl_pitchspeed 10` a held key turns ≈0.1°/frame),
turn with `+left/+right` N waits (≈1°/frame after a ramp), pitch `+lookdown`,
then `r_vrdump N`, `r_vrprobedump N`, `quit`. A generator lives in the
session scratchpad only (mk.py); recreate as needed. `impulse 101` gives a
viewmodel.

## Device timer baselines (c1a2 bench 1110 −330 −540, p50, ms)
- water off: gComposite 3.6–4.3, gpuQueue 4.6–5.0, total ~11
- soft (probe): gComposite 4.3–4.6, gpuQueue 5.3–5.5
- sharp, 96c7ddc: fill 0.03, project 0.39, resolve 0.78, gComposite 4.55,
  gpuQueue 6.82, total 14.1 (ripple adds ~0.35 to gComposite)
- probe face (256², old): gProbe 2.2 GPU / 0.6 CPU; now 128², no dlights
- b2e7e18 adds the 8-step march per resolve texel near water: expect the
  resolve +0.2–0.4 ms (≈1.0–1.2), not measured.
- round 11 vs b2e7e18 on the Mac GPU (`SSPR_TIMING=1`): project ×1.25–1.4
  (four neighbour depth reads for facing), resolve ×0.9–1.2 (march gone;
  occluder tests only short of the chosen sample). Against the device's
  project 0.39 / resolve 0.77 / fill 0.03: expect ≈0.5 + ≈0.9 + 0.03 ≈
  1.45 ms. A first version that tested occluders on every sub-ray cost
  resolve ×2.2.
- round 11 on device (3c8241d, table): fill 0.03, project 0.44, resolve
  1.25, gComposite 4.62, gpuQueue 7.36 (total mirror 1.72; the Mac ratio
  had predicted ≈0.9 for the resolve).
- round 12 vs round 11 on the Mac GPU: resolve ×0.88–0.93 (31 0.065/0.070,
  62 0.063/0.069, 84 0.070/0.080, 88 0.073/0.085, 91 0.070/0.077 ms),
  project ×1.1–1.45 (claims; 91 is the worst). Expected device: project
  ≈0.5–0.6, resolve ≈1.1, total ≈1.65 ms — still over 1.6. The next cut,
  `SSPR_CANDIDATES` 3 (no left/right surface candidates), saves ≈12% of the
  resolve but takes view 91's comb to +1.93 (limit 2.0) and costs stability;
  not taken.

## Rules that bit before
- Mac engine runs must use the background/no-mouse flags above.
- Never write files into the repo root; dumps live in `build/mac-run/`.
- Metal 4 has no hazard tracking: barriers between the SSPR dispatches and
  before the composite are required (present in `SharpWater.encode`).
- A precise timestamp after a buffer fill command never recorded; use a
  dispatch.
- Commit to p8-water only; never push.
