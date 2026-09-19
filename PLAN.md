# Lambda VisionPro — Half-Life on Apple Vision Pro

Half-Life on Apple Vision Pro, built on Xash3D-FWGS + hlsdk-portable.
GitHub-only distribution; no App Store target. User supplies their own
`valve/` PAK. Inspired by [Lambda1VR](https://github.com/DrBeef/Lambda1VR)
(the Quest VR Half-Life port) but built independently — no Lambda1VR code
is reused.

## Status snapshot

The project is playable end-to-end on AVP. The original plan below (Phase
0–2) targeted a from-scratch Vulkan renderer via MoltenVK; that was
abandoned 2026-05-14 in favor of Xash3D's own `ref_gl` driven by
[ANGLE](https://github.com/google/angle) (GLES → Metal) — `ref_gl` is the
complete, production renderer (studio models, lighting, particles, decals,
sprites, skybox), where the Vulkan prototype only ever reached ~5% feature
parity. Phases below reflect that pivot; see [ISSUES.md](ISSUES.md) for
the live, granular list of what's open.

| Phase | What | State |
|---|---|---|
| 0a | xash3d-fwgs cross-compiles to arm64-apple-xros2.0-simulator | ✅ |
| 0b | GPU rendering path identified | ✅ (superseded — see below) |
| 1 | visionOS Xcode app shell with C bridge, runs on AVP | ✅ |
| 1b | visionOS platform shim (subsumed by Vulkan path) | ✅ |
| 2 | Vulkan rendering driven from CompositorServices | ⛔ abandoned, see pivot |
| 2b | Pick: w23 ref_vk vs custom minimal Vulkan ref | ⛔ moot after pivot |
| 2c | Renderer pivot: `ref_gl` driven by ANGLE (GLES → Metal) | ✅ |
| 2d | Display chain: foveation + FXAA (folded into composite) + tuned to stable 120 FPS | ✅ |
| 3 | Hand-tracked VR input: aim, locomotion joystick, gestures (pinch/gaze menu, radial weapon menu, finger-gun fire) | ✅ (PoC quality — rough edges, see [ISSUES.md](ISSUES.md)) |
| 3b | Metal weapon pass: hand-anchored viewmodels rendered outside the engine | ✅ |
| 4 | SwiftUI launcher, settings window (graphics/audio/input), asset import via `push-assets.sh` | ✅ |
| 5 | Spatial-ish audio (AudioQueue backend), performance HUD, console | ✅ |
| 6 | Per-source spatial audio (AVAudioEnvironmentNode / PHASE) | ⛔ abandoned — both unusable on visionOS 26, see `.claude/research/visionos-spatial-audio.md` |
| — | Reprojection depth (constant depth submitted; real per-pixel depth would reduce head-motion jelly) | 🔜 open |
| — | Switch Pro controller / gyro aim as an alternative input | 🔜 idea, not started |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ SwiftUI launcher (LambdaVision/LambdaVisionApp.swift)   │
│   - WindowGroup → ContentView, Settings, Performance HUD│
│   - ImmersiveSpace → CompositorLayer                    │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │ Renderer.swift (CompositorServices)  │
        │   - Owns frame loop                  │
        │   - ARKit world + hand tracking       │
        │   - Per-eye Metal drawables, foveation│
        │   - Weapon Metal pass (WeaponPass.swift)│
        └──────────────────┬───────────────────┘
                           │  Lambda_Bridge.{h,c}
                           ▼
        ┌──────────────────────────────────────┐
        │ Lambda C bridge                      │
        │   - lambda_engine_init/frame/shutdown│
        │   - lambda_engine_set_view (matrices)│
        │   - input event injection            │
        │   - lambda_gl_worker_cmd (cvars)     │
        └──────────────────┬───────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Xash3D-FWGS engine (static lib via waf cross-compile)  │
│   - ref_gl → ANGLE (GLES) → Metal                      │
│   - HLSDK statically linked                            │
└────────────────────────────────────────────────────────┘
```

The engine renders into a GL color map (via ANGLE); the composite/display
Metal pass samples it (bilinear, with the FXAA kernel folded in) into the
CompositorServices drawable per eye, applying the foveation rate map. See
[ISSUES.md](ISSUES.md) and the `display-chain-resolution` /
`avp-reprojection-depth` research notes for the tuning history (MSAA,
MetalFX, frame-fence synchronization) that got this to a stable 120 FPS.

### Why ref_gl / ANGLE (superseded the original Vulkan/MoltenVK plan)

The sections below (through "Renderer↔CompositorServices interop") describe
the **original, abandoned** plan, kept for history. The actual pivot,
decided 2026-05-14: Xash3D's `ref_gl` is the complete, production renderer
(studio models, lighting, decals, particles, sprites, skybox — 25.5k LOC),
while the from-scratch Vulkan `ref_vk_lite` path only ever reached ~5%
feature parity (no studio models, no lighting, no decals/particles/
sprites/skybox) after the effort budgeted for Phase 2. ANGLE on visionOS
is a proven combination — WebKit ships it, and upstream Google ANGLE
maintainers confirmed the porting approach — so it was patched to target
visionOS directly (`VisionPort/angle-visionos.patch`,
`VisionPort/build_angle_visionos.sh`) rather than carved out of WebKit's
own CMake-based build. `MoltenVK.xcframework` is still fetched and linked
(see `VisionPort/setup.sh`), but only backs a leftover Vulkan smoke-test
diagnostic in the launcher UI, not the render path.

<details>
<summary>Original Vulkan/MoltenVK plan (superseded, kept for history)</summary>

#### Why Vulkan / MoltenVK

Confirmed running on AVP M5: **MoltenVK 1.4.1 / Vulkan 1.4.334 / 151
extensions** including swapchain, dynamic_rendering, sync2, descriptor
indexing. xrOS slices ship prebuilt in MoltenVK's official xcframework — no
ANGLE, no GN/depot_tools, no fork to maintain.

Half-Life is software-renderable on a 1998 CPU; on M5 it runs trivially via
Vulkan. ref_vk gives us a tested rasterizer aligned with the engine's existing
abstraction.

#### Renderer↔CompositorServices interop

CompositorServices owns the per-eye Metal drawables. Two viable paths:

- **Option A (MVP):** Vulkan renders to a `VkImage` backed by an `IOSurface`,
  Metal blits the IOSurface into the cp_drawable. One extra fullscreen quad
  per eye per frame (sub-ms on M5).
- **Option B (optimization):** `VK_EXT_metal_objects` lets Vulkan import the
  cp_drawable's `MTLTexture` directly as a `VkImage`. Zero copy. Trickier
  layout/foveation handling.

Start with A. Move to B if measurement justifies it.

</details>

## Repository layout

```
Lambda_VisionPro/                   ← this repo
├── LambdaVision/                   ← Xcode project (visionOS app)
│   ├── LambdaVision.xcodeproj
│   ├── LambdaVision/
│   │   ├── LambdaVisionApp.swift   ← @main, ImmersiveSpace
│   │   ├── ContentView.swift       ← launcher window
│   │   ├── Renderer.swift          ← CompositorServices frame loop, display chain
│   │   ├── WeaponPass.swift        ← hand-anchored viewmodel Metal pass
│   │   ├── SettingsView.swift / GameSettings.swift  ← settings sheet + cvar plumbing
│   │   ├── PerformanceHUDView.swift ← live perf HUD window
│   │   ├── ShaderTypes.h           ← bridging header (#includes Lambda_Bridge.h)
│   │   └── Bridge/
│   │       ├── Lambda_Bridge.h/.c  ← engine entrypoints, GL worker, Vulkan smoke (legacy)
│   │       └── Lambda_WeaponModel.h/.c ← bind-pose .mdl extractor for WeaponPass
│   └── Vendor/
│       ├── angle/                  ← gitignored, built by build_angle_visionos.sh
│       ├── libxash/                ← gitignored, built by build_xash_libxash.sh
│       ├── MoltenVK.xcframework/   ← gitignored, fetched by setup.sh (legacy smoke test only)
│       └── MoltenVK_include/       ← Vulkan headers (tracked)
├── VisionPort/                     ← engine cross-compile workspace
│   ├── setup.sh                    ← fetches xash3d-fwgs, hlsdk-portable, MoltenVK
│   ├── xash3d-visionos.patch       ← waf patch adding --xros / --xros-simulator
│   ├── hlsdk-visionos.patch        ← VR aim ray + xcompile tweaks
│   ├── angle-visionos.patch        ← visionOS target support for ANGLE's gn build
│   ├── build_xash_libxash.sh       ← builds libxash.a for device
│   ├── build_angle_visionos.sh     ← builds libEGL/libGLESv2 for device+simulator
│   ├── build_xash_xrsim.sh         ← one-shot smoke build for simulator
│   └── xash3d-fwgs/                ← gitignored clone
├── ISSUES.md                       ← live, granular open/resolved issue list
└── PLAN.md                         ← this file
```

## Phase details

### Phase 0a — xash3d-fwgs cross-compile ✅

Patch in `VisionPort/xash3d-visionos.patch` adds `visionOS` class to
`scripts/waifulib/xcompile.py` plus `--xros` / `--xros-simulator` waf options.
Build:

```bash
cd VisionPort/xash3d-fwgs
python3 ./waf configure --xros-simulator -d --disable-gl
python3 ./waf build
file build/engine/xash   # → Mach-O 64-bit executable arm64
otool -l build/engine/xash | grep platform  # → 12 (XROS_SIMULATOR)
```

### Phase 0b — Renderer decision ✅ (superseded — see pivot above)

Originally decided: Vulkan via MoltenVK, verified end-to-end on AVP M5.
Superseded 2026-05-14 by the `ref_gl`/ANGLE pivot (see "Why ref_gl / ANGLE"
above) once Vulkan's feature gap became clear.

### Phase 1 — App shell ✅

- Xcode "visionOS App / Metal 4 Renderer" template
- Build for **device** only (Metal 4 isn't available on visionOS simulator —
  `CP_MTL4_AVAILABLE = !TARGET_OS_SIMULATOR`)
- C bridge linked, MoltenVK xcframework linked statically (now backing only
  the legacy Vulkan smoke-test diagnostic, not the render path)

### Phase 2c — `ref_gl` via ANGLE ✅

1. Build ANGLE for visionOS (`VisionPort/build_angle_visionos.sh`) —
   `libEGL`/`libGLESv2`, Metal backend, ~12 GiB one-time gclient sync.
2. Build the engine (`VisionPort/build_xash_libxash.sh`) with `ref_gl`
   enabled, linked against ANGLE's static archives.
3. Engine renders into an EGL/GL context sized at the first drawable
   (`lambda_engine_set_render_size`); Metal blits/composites the resulting
   color map into the CompositorServices drawable per eye.
4. Stereo via `cp_view` matrices fed to the engine's view setup, same as
   originally planned for the Vulkan path.

Engine main-loop ownership (Xash3D expects to own `main()`) was solved with
a frame-callback model (`lambda_engine_frame(dt)`) called from
`Renderer.swift` — carried over unchanged from the original Vulkan plan.

### Phase 2d — Display chain tuning ✅

Foveation + FXAA (folded into the composite fragment shader) + frame-fence
GPU/GPU sync (`EGL_ANGLE_metal_shared_event_sync`) got the display chain to
a stable 120 FPS. MetalFX upscaling was tried and removed (cost outweighed
benefit at this resolution). Full tuning history, including two hazard-
tracking/V-flip traps, is in the `display-chain-resolution` research note
and [ISSUES.md](ISSUES.md)'s resolved section.

### Phase 3 — Input ✅ (PoC quality)

Delivered via `ARKit HandTrackingProvider`, not the originally-planned
Switch Pro controller/gyro path (that's now a "someday" idea, not started):
hand-tracked aim, an off-hand locomotion joystick (rendered via
`RAVEInput`'s shared visualization), gaze+pinch menu navigation, a radial
weapon menu, finger-gun fire, and gesture-based interactions (poke buttons,
grab-throttle trains, thumb-curl reload). Functional but rough — see
[ISSUES.md](ISSUES.md) for the specific known issues (aim offset, egon
viewmodel workaround, shell-casing angles, gaze-ray freeze during pinch).

### Phase 4 — Launcher / asset import ✅

- Assets ship out-of-band via `scripts/push-assets.sh` (`devicectl`-based
  incremental copy into `Documents/GameData`), not
  `UIDocumentPickerViewController` as originally planned — simpler given
  `steamcmd` is already required to fetch the pre-anniversary build.
- Settings sheet (`SettingsView.swift`/`GameSettings.swift`): render scale,
  gamma/brightness, snap-turn angle, audio volumes, dominant hand,
  accessibility fire-along-gaze, gesture toggles, plus an "Advanced" section
  exposing the stock HL menu and console.
- Mod selection from imported `valve/`-likes: not implemented, not currently
  planned.

## Build & run

```bash
# One-time
./VisionPort/setup.sh
./VisionPort/build_xash_libxash.sh
./VisionPort/build_angle_visionos.sh

# Build engine for visionOS (smoke test only, no GL — device build uses
# build_xash_libxash.sh above)
./VisionPort/build_xash_xrsim.sh

# Build & install app on AVP
xcodebuild -project LambdaVision/LambdaVision.xcodeproj \
  -scheme LambdaVision \
  -destination 'id=<YOUR_AVP_UDID>' \
  -configuration Debug build

xcrun devicectl device install app \
  --device <YOUR_AVP_UDID> \
  ~/Library/Developer/Xcode/DerivedData/LambdaVision-*/Build/Products/Debug-xros/LambdaVision.app
```

## Hardware target

User's AVP is the **2025 hardware refresh with M5 SoC**, not the original M2.
Renderer ambition can size up accordingly (MSAA, supersampling, post) —
though in practice MSAA through ANGLE cost +7ms/pair and was dropped in
favor of FXAA; see the display-chain tuning note above.

## Open risks

Most of the risks from the original Vulkan plan were resolved or made moot
by the `ref_gl`/ANGLE pivot: engine main-loop ownership (solved via
`lambda_engine_frame(dt)`), foveation interaction (solved, see Phase 2d),
and HLSDK static linking (settled — HL game logic is signed into the app
binary statically, since visionOS forbids loading dylibs from outside the
bundle; this also means mods built as separate dylibs can't be hot-loaded).
What's still genuinely open, per [ISSUES.md](ISSUES.md):

- **Reprojection depth** — a constant depth is submitted per frame; real
  per-pixel depth would reduce head-motion jelly artifacts.
- **VR input polish** — aim offset (barrel vs. drawn gun), egon viewmodel
  is a workaround not a true fix, shell-casing eject angles are cosmetic-
  wrong, gaze ray freezes during a held pinch.

## Distribution

GitHub-only. User supplies `valve/` from their own Half-Life install on first
launch. GPL terms satisfied by source publication; HL assets never
redistributed.
