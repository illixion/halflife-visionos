# Plan — Anti-aliasing inside the headset's GPU budget

> **Status (2026-10-16): proposal, nothing built.** Written after the glass
> mirror's 4× MSAA landed (`db2f854`) and the owner asked whether MSAA's
> reputation for cost means a more modern technique would suit the headset
> better, given its thermal limits, and what carries over to Oneiros.

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
