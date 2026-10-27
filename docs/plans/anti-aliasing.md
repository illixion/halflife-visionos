# Plan — Anti-aliasing inside the headset's GPU budget

> **Status (2026-10-27): Phase 0 measured; Phase 1 (4× MSAA) built, off by
> default pending a headset check; Phase 2 (foveated engine render)
> built and checked on the headset (2D panel fixes too, 2026-10-26), thermal
> baseline still to measure.**
> Written after the glass mirror's 4× MSAA landed (`db2f854`) and the owner
> asked whether MSAA's reputation for cost means a more modern technique would
> suit the headset better, given its thermal limits, and what carries over to
> Oneiros. Phase 0's results (below) move the foveated render (Phase 2) ahead
> of MSAA in priority: it is the fix for the thermal throttle.

## Answer in brief

Keep MSAA; spend the effort on how many pixels the engine renders.

- **On Apple's tile-based GPUs, MSAA is the cheap anti-aliasing.** With
  memoryless multisample attachments resolved on tile at the end of the pass,
  the samples never reach memory: no extra pass, no extra bandwidth. The
  fragment shader still runs once per pixel; only edge pixels blend per
  sample. Measured on the M5: the rendered glass/water mirror costs the same
  at 4 samples as at 1, within noise. Oneiros draws its world with 4× memoryless
  MSAA and ran at 120 fps on device with GPU at 5–8 ms (2M triangles, Phase 1).
- **The reputation comes from desktop GPUs and deferred renderers**, where every
  sample goes to video memory and lighting runs per sample over a fat G-buffer.
  The one time MSAA was expensive here (+7 ms per frame, July) was exactly that
  path: ANGLE's explicit multisample renderbuffers, stored to memory and
  resolved with a blit. `GL_EXT_multisampled_render_to_texture` is the tile path.
- **Temporal techniques don't fit.** MetalFX's temporal scaler, temporal
  denoised scaler and frame interpolator are `API_UNAVAILABLE(visionos)` in the
  visionOS 27.0 SDK (only the spatial scaler exists). A home-made TAA would need
  motion vectors GoldSrc doesn't produce, smears under constant head motion,
  can disagree between the eyes, and adds a full-screen pass plus a history
  read and write per eye: more memory traffic, so more heat.
- **Post-process AA is already here and has hit its limit.** FXAA runs inside
  the composite (`fragmentShaderFXAA`). It softens visible stair-steps but
  cannot recover geometry thinner than a pixel, so thin parts (table legs,
  wires, grates) still crawl as the head moves. The earlier separate FXAA +
  MetalFX spatial chain cost 13–14 ms GPU per frame and was removed.
- **Where the heat goes: pixel count.** The engine renders 0.75× of the foveal
  (logical) resolution uniformly over the whole field of view, 3815×3061 per
  eye (23.4 Mpx per frame), while the foveated drawable it lands in is
  2048×1984 per eye (8.1 Mpx). The engine draws 2.9× the pixels the display
  can show. The composite then resamples that image down in the periphery with
  plain bilinear (no mips), which aliases there in its own right. At the c1a2
  flood (an earlier build) the engine cost 1.4 + 3.0 ms per eye and the
  composite 4.1 ms.

Valve's VR rendering talk reaches the same conclusion for forward renderers:
"4xMSAA Minimum Quality: forward renderers win for antialiasing because MSAA
just works" (GDC 2015, slide 27). So does Meta for Quest, also a tiler: use
MSAA almost always, but no more than 4×; 0.5–1.5 ms per frame there.

## Facts this rests on

| Fact | Where it comes from |
|---|---|
| Memoryless MSAA resolved on tile is ~free on the M5 | gPlanar0/1 at 1 vs 4 samples, c1a2 window, 2026-10-16 |
| Oneiros: 4× memoryless MSAA, 120 fps, GPU 5–8 ms on device | Oneiros `KNOWN_ISSUES.md`, 2026-08-27 |
| Explicit ANGLE MSAA (renderbuffer + blit) cost +7 ms per frame | `display_chain_resolution` memory, July |
| ANGLE's tile MSAA fails silently into RGBA16Unorm on visionOS | `angle_msrtt_resolve_formats` memory; mirror target is now RGBA8 |
| ANGLE allows tile MSAA only on `GL_COLOR_ATTACHMENT0` unless `GL_EXT_multisampled_render_to_texture2` is exposed; the Metal backend doesn't expose it, though it auto-resolves depth and stencil | `validationES2.cpp`, `DisplayMtl.mm` (`hasDepthAutoResolve`, `hasStencilAutoResolve`) |
| MetalFX temporal, temporal denoised and frame interpolation unavailable on visionOS | `MetalFX.framework` headers, XROS27.0 SDK |
| Compositor Services can generate **flipped** rate maps (+Y up) for intermediate passes, visionOS 1.0+ | `cp_layer_renderer_configuration_set_generate_flipped_rasterization_rate_maps`, `cp_drawable_get_flipped_rasterization_rate_map` |
| Compositor Services has a live `renderQuality` (visionOS 26+), ramped by the system; neither app uses it | `layer_renderer.h`; grep of both apps and RAVEEngine |
| Engine textures already use 16× anisotropic filtering | `Lambda_Bridge.c` (`gl_anisotropy 16`) |
| Water ripples are already band-limited per wave by screen period | `Shaders.metal` `waterRipple` |

## Plan

Each phase has a device gate. Nothing moves to RAVEEngine or Oneiros until it
has passed its gate and been frozen (the standing rule for the mirror work).

### Phase 0 — Measure the split (headset, no code)

With Settings → Diagnostics → "GPU pass timing" on, record p50/p95 of
`gEngine0`, `gEngine1`, `gPlanar0`, `gPlanar1`, `gComposite`, `gpuQueue` and the
thermal state at the four scenes in `modern-lighting.md` §1, plus the c1a2
window. Then the same at the window with `fxaaEnabled` off: that delta is what
FXAA costs. The app has held 60 fps at the window in every recent run; if
engine + ours exceeds 11.1 ms there, the GPU is what halves the frame rate.

#### Results (2026-10-17)

Build `3501f58` (Release), M5 headset, visionOS 27.2, Mac Virtual Display off,
launched cold (thermal "nominal"). Defaults: render scale 0.75, FXAA on, mirror
method rendered, sharp water and sharp glass on, reprojection depth on, mirror
at 4 samples. Each cell is p50/p95 in ms over whole 512-frame `[FT]` windows
taken after the map had loaded (two to four windows per row). Every row ran at
90 fps (frame time p50 11.1 ms), except the throttle row.

| Scene | Thermal | gEngine0 | gEngine1 | gPlanar0 + 1 | gComposite | gpuQueue |
|---|---|---|---|---|---|---|
| c0a0 tram | nominal | 2.5/3.0 | 3.1–3.2/3.7–4.1 | 2.5 + 3.6 (when in view) | 2.7–3.1/3.2 | 3.3–3.7/3.8–3.9 |
| c1a0 lobby | nominal | 2.5/2.9 | 2.9/3.8 | — | 3.2/3.4 | 3.8/4.1 |
| c1a0d lab lobby | nominal | 2.5/3.0 | 3.3/4.2 | — | 3.2/3.5 | 3.9/4.2 |
| c2a5 spawn corridor (gate shut, no fight) | nominal | 2.5/3.1 | 3.1/4.1 | — | 3.0/3.1 | 3.6/3.8 |
| c1a2 window, facing the glass | ↓ | 1.4/1.8 | 2.5/3.0 | 1.5 + 2.3 | 3.0/3.1 | 3.5/3.6 |
| … FXAA off | ↓ | 1.4/1.9 | 2.5/3.0 | 1.4 + 2.3 | 3.0/3.1 | 3.5/3.7 |
| … sharp glass off (the mirror moves to the flood behind the glass) | ↓ | 1.7/2.2 | 2.8/3.4 | 1.7 + 2.6 | 2.6/2.7 | 3.1/3.3 |
| … screen-space water (no rendered mirror) | ↓ | 1.3/1.6 | 2.1/2.5 | — | 3.9/4.0 | 5.0/5.2 |
| **throttle, 45 fps** (c1a2 window, any setting) | fair | 1.8/2.1–2.9 | 2.8–3.2/4.2–4.8 (rendered) | 1.6 + 2.9 | 4.8–6.5/6.5–9.0 | 6.0–8.3/8.0–11.4 |
| c1a2 window after the throttle lifted | fair | 1.5/2.1 | 2.6/3.1 | 1.6 + 2.4 | 3.0/3.1 | 3.5/3.7 |
| c1a0e spawn lobby (chamber door shut) | fair | 2.1/2.8 | 2.8/3.6 | — | 3.2/3.5 | 3.9/4.2 |
| c2a5b, in the river (much water, no fight) | fair | 2.1/2.4 | 3.3/3.6 | 1.9 + 3.3 | 3.4/3.7 | 4.1/4.3 |

↓: the thermal state read "nominal" at 22:43:05 UTC and "fair" at 22:46:21;
these rows fall between.

What it shows:

- **The frame rate is 90 Hz, not 120.** Every full-speed window had an 11.1 ms
  frame time.
- **The scene barely matters.** The engine costs 4.8–5.9 ms for both eyes in
  the tram, three lobbies and the outdoor corridor: it is
  bound by the pixel count, not by GoldSrc's geometry.
- **FXAA costs nothing measurable** (composite 3.0/3.1 ms with and without),
  so it can stay on until MSAA earns its place. The composite's 3 ms is the
  read of the oversized engine image (colour, depth and stencil at 3815×3061
  per eye), not the filter.
- **The rendered mirror is the largest optional cost**: 3.8 ms of engine time
  at the window, 5.2 ms in the river, whenever a mirror plane is in view.
  Screen-space water instead costs about 1.5 ms more in our queue.
- **The GPU timers overlap, so their sum is not GPU busy time.** In the river,
  engine 5.4 + mirror 5.2 + ours 4.1 = 14.7 ms of timed work fits in a steady
  11.1 ms frame: ANGLE's command buffers and ours run partly at the same time.
  So the test above ("if engine + ours exceeds 11.1 ms") can't decide
  anything; use the frame time, and same-spot A/Bs of single passes.
  `gEngine1` also reads 0.5–1.2 ms above `gEngine0` in every scene, and
  `gPlanar1` above `gPlanar0` by as much, which no scene difference explains.
  Check it before using `gEngine` as a gate.
- **What halves the frame rate is heat, not content.** About 6.5 minutes after
  the cold launch (22:45:45 UTC), the frame rate fell to 45 fps for 2.8 minutes,
  with the thermal state "fair". The passes that stream full-size textures from
  memory went up 1.6–2× (composite 3.0 → 4.8–6.3 ms with the rendered mirror,
  3.9 → 6.5 in screen-space mode; depth merge 0.4 → 0.6–0.8; weapon 0.1 → 0.2),
  while the engine's tile rendering rose about 10–30%. That is consistent with
  the system lowering the GPU and memory clocks. Turning glass and water
  reflections off didn't lift it. The cap lifted on its own, still at "fair",
  and every pass went back to its earlier time. The earlier 60 fps at the window
  (thermal "fair", Mac Virtual Display on) fits the same picture.

So the order changes. The composite and the depth merge read 23.4 Mpx of
engine image every frame, and those passes are what the thermal mitigation hurts
most. Phase 2 reads the engine image 1:1 at the drawable's 8.1 Mpx, a third of
that traffic, and cuts the engine's fill by the same factor. Phase 1 (MSAA)
stays, for quality, and gets cheaper after Phase 2. The gate for Phase 2 now has
a baseline: from a cold start, how long until the frame rate first halves
(6.5 minutes today, touring these scenes).

On the headset the view belongs to the head: `vr_setangles` exists only in
the desktop build. Place the player with `ent_fire 1 set origin "x y z"`
(`sv_cheats 1; sv_enttools_enable 1`) and let the wearer face the subject;
the c1a2 window is eye 1399.8 −610.06 −499.45, so origin z −527.45, facing −x.

### Phase 1 — 4× MSAA on the engine view

- ANGLE (`VisionPort/angle-visionos.patch`): expose
  `GL_EXT_multisampled_render_to_texture2` on Metal, so the engine's depth/stencil
  texture can be a multisampled attachment too. The backend already
  auto-resolves depth (sample 0) and stencil for multisampled renderbuffers;
  the same for a depth texture is the part to verify.
- Colour map RGBA16Unorm → RGBA16Float, which resolves on every Apple GPU. The
  composite clamps its read to 1, as Unorm did; what changes is blending past
  1 inside a frame (an additive sprite later alpha-blended over), which can
  read a little brighter.
- Bridge: attach the eye's colour and depth with
  `glFramebufferTexture2DMultisampleEXT`, check `glGetError` after the first
  pass and fall back to one sample, as `mirror_fbo_for` does.
- Setting "Edge smoothing": FXAA / 4× MSAA / both.
- **Gate:** `gEngine` within noise of 1 sample; table legs, grates and wires
  steady under head motion. MSAA is free only while ANGLE keeps each eye in
  one render pass. Each split (a mid-frame lightmap upload through a blit, a
  framebuffer switch) costs a full-screen "unresolve" draw of colour and depth.
  Count render passes per eye (a counter in the ANGLE patch, or a programmatic
  GPU capture) before concluding anything from the timings.
- Then: alpha-to-coverage for `{` cutout textures (fences, grates) in the
  fixed-function shim, which is free once MSAA is on. And an A/B of render
  scale 0.6–0.65 with MSAA against 0.75 with FXAA: clean edges may let the
  scale drop by a third of the pixels.

#### Built (2026-10-27)

- ANGLE: `VisionPort/angle-metal-msrtt2.patch`, applied on top of the
  rate-map patch. It exposes `EXT_multisampled_render_to_texture2` on Metal
  (the backend already gave every attachment a memoryless multisampled image
  and resolved depth and stencil from sample 0). It also adds
  `ANGLE_GetRenderPassStats`: render encoders started, and multisampled
  attachments unresolved after a split.
- Bridge (`engine_ms_fbo_for`): the eye's colour slice and the app's
  depth-stencil slice, wrapped as GL textures and attached with
  `glFramebufferTexture2DMultisampleEXT`. There is one framebuffer per slice,
  kept while the textures last, because the implicit multisampled images
  belong to the GL textures. A refused attachment, or a GL error in the first
  pass, means one sample from then on.
- Colour map: RGBA16Float when MSAA is on, RGBA16Unorm otherwise. The
  engine-source screenshot and the snapshot dump decode the half-float map
  as gamma-space values.
- Setting `engineMSAA`, stored, off by default until judged on the headset.
  It applies when the immersive space reopens. `/foveation` reports
  `engineSamples` and `engineRenderPasses`.
- c1a0 lobby, foveated, console open: **one render pass per eye, no
  unresolves.** First same-spot A/B (120 fps, head still), p50: gEngine
  1.0 + 1.3 ms at one sample, 1.2 + 1.8 ms at four. frameGPU was 4.6 ms both
  ways, so the GPU clock may hide or inflate part of the difference. Repeat
  the A/B with the wearer settled before calling it.
- **Splits garble the foveated eye.** ANGLE's unresolve
  (`FramebufferMtl::unresolveIfNeeded`) draws the resolved image back at
  screen-normalized coordinates, while that image is stored in the rate
  map's physical layout. Each split frame shows black tiles and ghosting.
  On c1a1 this beat with the light styles: two flashes, a pause, one flash.
  The sources found so far, and what keeps each one out of the eye's pass:
  - A GPU timer query begun after the clear (gpuPassTiming). The timers now
    start before it.
  - Light-style lightmaps (`R_CheckLightMap`), uploaded mid-pass into
    textures the pass had drawn with. `R_VRBeginEyeLightmaps` uploads the
    changed ones before the pass. On the eye that ticks, the bridge's clear,
    which opens the pass, waits for the engine's `R_BeginFrame`
    (`vr_begin_frame_hook`). By then `CL_EmitEntities` has run the styles,
    so the prepass goes there. A prepass before the tick missed every style
    step, so eye 0 kept splitting from `R_DrawBrushModel`.
  - Dynamic lightmap blocks (flicker styles, dlights). Each fill goes into a
    fresh texture from a 16-deep ring (`R_VRNextDlightTexture`).
- Still splitting:
  - A level's first frames: about 20 passes an eye at launch and a few
    2-pass frames after a map load.
  - The dropped-down console with a screen of text. `CL_DrawCharacter`
    flushes one draw per character through the GL2 shim, and the stream
    exhausts ANGLE's vertex buffer pool, which flushes the command buffer.
- **The safety net.** Three split frames under multisampling within 180
  frames mean one sample for the rest of the run. Only frames of a level
  that has been in play for 180 frames count. `/foveation` lists the last
  eight splits (`recentSplits`), each with a backtrace taken where the
  pass ended (`ANGLE_SetRenderPassEndHook` in the msrtt2 patch). To
  symbolicate, run `atos -o <dSYM> -l 0x100000000` on 0x100000000 plus
  each offset.
- **Blocker: MSAA loses the stencil (2026-10-27).** With four samples, no
  glass or water reflection shows. The colour and depth reach the app's
  textures, but the stencil codes that mark glass and water
  (`R_VRGlassBegin`) don't.
  - The marks view showed it: Settings › Developer › Water mirror view ›
    "Glass and water marks", the engine's depth in grey wherever no mark
    is. With MSAA it shows no marks anywhere, and the depth is the scene.
  - Rate map on or off makes no difference.
  - The framebuffer's stencil is attached (8 bits, a texture).
  - ANGLE hands Metal a correct descriptor. Depth and stencil share one
    memoryless 4x depth32Float_stencil8 texture, both store with
    `MultisampleResolve`, with the stencil filter at sample 0, into the
    same slice view.
  - Not known yet: whether the stencil writes happen in the multisampled
    pass at all, or whether Metal drops the stencil resolve here. A GPU
    capture, or a small Metal reproduction of the same attachment setup,
    would tell them apart.
  - Also seen: with MSAA on, the right eye's depth shows a regular grid of
    near-white blocks, with or without the rate map. Not yet explained.
  - MSAA stays off by default until this is fixed.

### Phase 2 — Render the engine foveated (the thermal win)

The compositor already tells us where pixels matter; the engine ignores it.

- ANGLE: `mtl::RenderPassDesc` carries an `MTLRasterizationRateMap`, copied in
  `convertToMetalDesc`; `FramebufferMtl` holds it, set from the bridge through a
  small exported function; the render area, viewport flip height and scissor
  (`getCompleteRenderArea`, `ContextMtl::updateViewport`, `updateScissor`) use
  the map's screen size instead of the attachment's physical size.
- Each eye renders into its own 2D slice, where Metal applies layer 0 of a map.
  So build a one-layer map per eye from the compositor's, by sampling
  `mapScreenToPhysicalCoordinates` along each axis into a
  `MTLRasterizationRateLayerDescriptor`, and rebuild them when the compositor's
  map changes. Build them flipped: ANGLE stores framebuffer images GL-side up,
  the case Compositor Services' flipped maps exist for, so those are the
  reference to check against.
- The colour map, depth and stencil become physical-size and foveated. The
  composite reads the engine image through `rasterization_rate_map_decoder`, a
  1:1 read wherever the per-eye maps reproduce the compositor's layout (Oneiros
  reads its scene target 1:1 at `[[position]]`). Every other pass that looks up
  the engine image at a screen position decodes the same way: screen-space
  water, the glass probe, the reprojection depth, the mirror composites and the
  screenshot.
- Audit the engine for reads of its own framebuffer (`glCopyTexSubImage2D`,
  `glReadPixels`): under a rate map those return the physical layout.
- `renderScale` retires: the rate map sets the density, and render quality
  becomes the knob.
- Mac lab: give `Tools/DepthProbe` a synthetic rate map so the real shaders keep
  running on Mac dumps.
- **Expected:** about 65% less engine fill, 1.33× sharper where the user looks
  (1.0× logical instead of 0.75×), no periphery shimmer, and MSAA cost falls
  with the pixels. **Gate:** same-spot A/B of `gEngine` + `gComposite`, and the
  thermal state after 10 minutes at the window.

#### Built (2026-10-17)

- ANGLE: `VisionPort/angle-metal-rate-map.patch` (`1208a73`), exporting
  `ANGLE_SetFramebufferRasterizationRateMap`. The bridge binds each eye's map
  to the frame's framebuffer, which it rebuilds every eye.
- `EngineFoveation.swift` builds the per-eye maps from the compositor's
  (sampling its mapping per screen pixel, the larger step of each pixel's
  neighbours as quality, the vertical axis mirrored for ANGLE's bottom-up
  image) and rebuilds them when the compositor's map changes. The copies come
  out a little denser than the source (Metal rounds a sample up, never down).
- No `rasterization_rate_map_decoder`: every pass that reads the engine image
  goes through per-eye lookup tables (screen x/y → texel and back,
  `ShaderTypes.h` `engineTexelPos`). Interpolating between entries is exact,
  the fovea reads 1:1, and the uniform image (setting off) is identity tables
  through the same code.
- The mirrors keep their old size: their divisors divide 0.75 × the logical
  screen (`mirrorBase`), not the engine's screen.
- Setting "Foveated rendering" (default on); render scale applies only with it
  off. Both take effect when the immersive space reopens. MetalFX's spatial
  scaler is off while foveated.
- The 2D panel keeps its angular size at any render size (`hud_scale` as a
  virtual width, `con_fontscale` scaled from the width), and its non-additive
  draws clear the glass and water stencil codes under them (`R_VRPanelStencil`).

#### Measured (2026-10-17)

The compositor's map on the M5: 2 layers, screen 5087×4081, physical
2048×1984 per eye, granularity 32. It never changed during a session (one
build at open, no rebuilds). The per-eye maps come out 2144×2078 each (+10%
pixels over the compositor's), held in 2144×2080 slices: 4.5 Mpx per eye
against 11.7 Mpx uniform at 0.75.

Same spot, c1a0e spawn, thermal "nominal", head nearly still (p50/p95 ms):

| | gEngine0 + 1 | gComposite | gDepth | gWeapon | gpuQueue | frameGPU |
|---|---|---|---|---|---|---|
| uniform 3815×3061 | 1.9 + 2.6 | 3.2/3.4 | 0.5/0.5 | 0.1/0.1 | 3.9/4.0 | 6.6/8.0 |
| foveated | 1.3 + 1.2 | 3.9/4.7 | 0.8/1.1 | 0.2/0.4 | 5.2/5.8 | 6.6/7.6 |

- **The engine costs about half** (4.5 → 2.5 ms for both eyes).
- **Our queue looks slower, and that is the GPU clock.** The depth merge and the
  weapon pass do exactly the same work in both modes (neither reads the engine
  image) and still took 1.6× as long foveated, while frameGPU stayed at 6.6 ms.
  With less work per frame the system lowers the GPU clock until the GPU is
  busy for about as long as before: the saving shows up as power and heat, not
  as shorter passes. Scaled by that 1.6, the frame's work fell by about 40%.
  Uniform mode on this build matched Phase 0, so the identity tables cost
  nothing measurable.
- Checked by screenshot through the unwarp (engine and composited, both eyes):
  the tram, the c2a5b river with each mirror method (rendered, screen space, ray
  traced), the c1a2 window glass and the console. Straight edges stay straight
  across the rate steps, and reflections and glass sit where they should.
- **The 2D layer was the regression.** The console's text was hard to read
  toward the box's edge and washed over by glass behind it. Three causes: the
  panel drew 1.33× smaller (fixed `hud_scale` and `con_fontscale` against a
  5087-wide screen instead of 3815); the console font is nearest-filtered with
  no mips, so the low-rate band drops strokes; and the glass and water codes
  under the panel stayed in the stencil. The first and the last are fixed,
  and on the headset (2026-10-26) the console reads well and stays clear of
  the glass, so mipmapped 2D textures are not needed for now. `/foveation`
  `rates` and `panel` give the panel's rate profile if text softens again.
- Still to measure: the thermal baseline (minutes from a cold start until the
  frame rate first halves, 6.5 in Phase 0).
- Known gaps: Xash's own mirror surfaces (textures named `reflect*`, custom
  maps only) copy the framebuffer with `glCopyTexImage2D`, which under a rate
  map returns the physical layout; and the MSAA resolve blit in
  `lambda_gl_end_frame` (off today) would need the same care in Phase 1.

### Phase 3 — Reflections in the same budget

- Rendered mirror: the composite reads it at screen positions too, so it can
  render through the same per-eye maps at its divisor. Fewer pixels, MSAA
  stays.
- Ray traced (3.5 ms on the M5 for ~2.3M rays at divisor 2): one ray per texel
  stair-steps. Add rays only where a 3×3 neighbourhood disagrees, the pattern
  of Oneiros's `rtShadowRefine` (+0.2 ms there), rather than supersampling
  everything, and trace foveated. (Alpha-tested geometry is already kept
  apart from opaque geometry in `RTWaterScene`.) If a temporal accumulator is
  ever worth it, it is here: the reflection lies on a known plane, so
  reprojection of static geometry is exact.

### Phase 4 — A frame-budget governor for both apps

Compositor Services' `renderQuality` is the platform's own thermal knob:
the system ramps a change over time so it doesn't show. A governor reads the
thermal state, GPU time per frame (`gpuQueue` + engine) and missed frames,
and steps render quality, then the reflection method, then effect tiers.
Build it in one app, device-check it, then hoist it into RAVEEngine next to
`RAVEFrameProfiler`. Lambda can use render quality only after Phase 2; Oneiros
can use it today.

## Oneiros

- Geometry AA is already the target architecture: the world renders through
  the drawable's rate map with 4× memoryless MSAA, resolved into the
  `rg11b10Float` scene target in physical layout, and the composite reads it
  1:1 (`.claude/rules/compositor-metal4-backend.md`, Post pass).
- Water has no reflections yet. When it gets them, start from Lambda's methods
  once frozen: a rendered planar mirror at reduced resolution through the rate
  map with MSAA, the ray-traced kernel's plane maths, and `waterRipple`'s band
  limit as specular AA as soon as water gets normals.
- Shared after the freeze: rate-map helpers (screen↔physical, per-eye map
  reconstruction), the memoryless MSAA target cache (Oneiros `MSAATargets` is
  already generic), mirror-plane maths, and the governor.
- Other platforms: Quest is a tiler too, so the same answer holds there. Desktop
  GPUs pay more for MSAA; a TAA path would only matter for a flat-screen
  desktop mode.
- M2 headsets: MSAA on tile and foveation work the same. M2 has no hardware ray
  tracing (M3 and later do), so ray-traced reflections stay opt-in.

## Not recommended

- TAA or any temporal upscaler on the main view (above).
- Standalone post-process passes: each one is a full-screen read and write per
  eye at engine resolution.
- 8× MSAA: twice the tile memory per pixel for little visible gain at this
  pixel density; Meta advises against going past 4× on Quest. Worth one
  measurement after Phase 2 at most.

## Sources

- Alex Vlachos, "Advanced VR Rendering", GDC 2015 (slide 27; geometric
  specular AA on slides 44–45):
  https://media.steampowered.com/apps/valve/2015/Alex_Vlachos_Advanced_VR_Rendering_GDC2015.pdf
- Meta, "Multisample Anti-Aliasing Analysis for Meta Quest":
  https://developers.meta.com/horizon/documentation/native/android/mobile-msaa-analysis/
- Apple, Tech Talk 606, tile memory and memoryless MSAA:
  https://developer.apple.com/videos/play/tech-talks/606/
