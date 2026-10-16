# Plan — Anti-aliasing inside the headset's GPU budget

> **Status (2026-10-17): Phase 0 measured on the headset; nothing built.**
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
