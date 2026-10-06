# Plan — Modern lighting: reflections, glass and shadows

> **Status: idea, not started** (2026-10-06). Nothing here is built or measured.
> Numbers quoted from Oneiros are from its notes, not re-measured for this app.

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
