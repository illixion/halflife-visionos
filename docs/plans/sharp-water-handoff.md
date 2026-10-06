# Sharp water reflections — handoff (2026-10-07, branch p8-water, round 11)

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
     Timer `gMirrorProject`.
  3. `ssprResolve` — candidates: own key, the **nearest** (by distance)
     surface key and the nearest occluder key up and down within `SSPR_FILL`
     (8) rows, left/right; surfaces merged if same distance, occluders if same
     height (≤ 5 surfaces, ≤ 2 occluder heights). `SSPR_SUB_X×Y` (2×2) exact
     mirrored rays per texel: each surface's depth → exact source coord →
     verify with engine depth (smallest miss wins; single surface skips
     verify; none → first surface's own source). **Occluder test**, only
     short of the chosen sample's real distance: where the ray climbs to the
     occluder's height − `SSPR_SLAB` (4) and to its height, a surface on
     screen on or in front of that point and no higher than the occluder →
     blocked; then the nearest-checking surface short of the block, else the
     sub-ray is empty (probe). Colour = 4 bilinear taps ±0.5 px (2×2 box);
     confidence = edge fade (15%) of the **mean exact projection of all
     surfaces**. Timer `gMirror`.
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
| Comb across the whole mirrored table underside | b2e7e18 failed on device (rows of locker); **round 11 untested**: occluders, see below |
| Underside looks transparent, depends on head pitch | b2e7e18 failed on device; **round 11 untested**: see-through 1.5–2.2% over −5…33° offline (b2e7e18 6–19%) |

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
  b2e7e18: 81–88 6–19%, 41 12%, 71–73 4–6.5%, 33 4%; round 11 ≤ 2.9%.
Tool switches: `SHADERS=path` runs another Shaders.metal (A/B; add the
`SSPR_DEBUG` blocks to an old one), `SSPR_TIMING=1` times project/resolve on
the Mac GPU (50 dispatches per command buffer; only ratios carry over),
`SSPR_KEYS=prefix` dumps the key buffer and the debug record.
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
  Groups as run: 9 10 11 +probe9; 31 32 33 +31; 41 +41; 51 +51; 61 +61;
  62 63 +62; 71–74 +71; 81–88 +81 (one probe per run: the first).
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

## Rules that bit before
- Mac engine runs must use the background/no-mouse flags above.
- Never write files into the repo root; dumps live in `build/mac-run/`.
- Metal 4 has no hazard tracking: barriers between the SSPR dispatches and
  before the composite are required (present in `SharpWater.encode`).
- A precise timestamp after a buffer fill command never recorded; use a
  dispatch.
- Commit to p8-water only; never push.
