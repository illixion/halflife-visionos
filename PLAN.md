# Lambda VisionPro — Half-Life on Apple Vision Pro

Port of [Lambda1VR](https://github.com/DrBeef/Lambda1VR) (Quest VR Half-Life
based on Xash3D-FWGS) to Apple Vision Pro. GitHub-only distribution; no App
Store target. User supplies their own `valve/` PAK.

## Status snapshot

| Phase | What | State |
|---|---|---|
| 0a | xash3d-fwgs cross-compiles to arm64-apple-xros2.0-simulator | ✅ |
| 0b | GPU rendering path identified | ✅ Vulkan via MoltenVK |
| 1 | visionOS Xcode app shell with C bridge, runs on AVP | ✅ |
| 1b | visionOS platform shim (subsumed by Vulkan path) | ✅ |
| 2 | Vulkan rendering driven from CompositorServices | 🔜 |
| 2b | Pick: w23 ref_vk vs custom minimal Vulkan ref | 🔜 |
| 3 | Switch Pro controller (incl. gyro) + ARKit hands | 🔜 |
| 4 | SwiftUI launcher, asset import, settings | 🔜 |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ SwiftUI launcher (LambdaVision/LambdaVisionApp.swift)   │
│   - WindowGroup → ContentView                           │
│   - ImmersiveSpace → CompositorLayer                    │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │ Renderer.swift (CompositorServices)  │
        │   - Owns frame loop                  │
        │   - ARKit world tracking             │
        │   - Per-eye Metal drawables          │
        └──────────────────┬───────────────────┘
                           │  Lambda_Bridge.{h,c}
                           ▼
        ┌──────────────────────────────────────┐
        │ Lambda C bridge                      │
        │   - lambda_engine_init/frame/shutdown│
        │   - lambda_engine_set_view (matrices)│
        │   - input event injection            │
        └──────────────────┬───────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Xash3D-FWGS engine (static lib via waf cross-compile)  │
│   - ref_vk → MoltenVK → Metal                          │
│   - HLSDK statically linked                            │
└────────────────────────────────────────────────────────┘
```

### Why Vulkan / MoltenVK

Confirmed running on AVP M5: **MoltenVK 1.4.1 / Vulkan 1.4.334 / 151
extensions** including swapchain, dynamic_rendering, sync2, descriptor
indexing. xrOS slices ship prebuilt in MoltenVK's official xcframework — no
ANGLE, no GN/depot_tools, no fork to maintain.

Half-Life is software-renderable on a 1998 CPU; on M5 it runs trivially via
Vulkan. ref_vk gives us a tested rasterizer aligned with the engine's existing
abstraction.

### Renderer↔CompositorServices interop

CompositorServices owns the per-eye Metal drawables. Two viable paths:

- **Option A (MVP):** Vulkan renders to a `VkImage` backed by an `IOSurface`,
  Metal blits the IOSurface into the cp_drawable. One extra fullscreen quad
  per eye per frame (sub-ms on M5).
- **Option B (optimization):** `VK_EXT_metal_objects` lets Vulkan import the
  cp_drawable's `MTLTexture` directly as a `VkImage`. Zero copy. Trickier
  layout/foveation handling.

Start with A. Move to B if measurement justifies it.

## Repository layout

```
Lambda_VisionPro/                   ← this repo
├── LambdaVision/                   ← Xcode project (visionOS app)
│   ├── LambdaVision.xcodeproj
│   ├── LambdaVision/
│   │   ├── LambdaVisionApp.swift   ← @main, ImmersiveSpace
│   │   ├── ContentView.swift       ← launcher window
│   │   ├── Renderer.swift          ← CompositorServices frame loop
│   │   ├── ShaderTypes.h           ← bridging header (#includes Lambda_Bridge.h)
│   │   └── Bridge/
│   │       ├── Lambda_Bridge.h     ← Swift↔C surface
│   │       └── Lambda_Bridge.c     ← engine entrypoints + Vulkan smoke
│   └── Vendor/
│       ├── MoltenVK.xcframework/   ← gitignored, fetched by setup.sh
│       └── MoltenVK_include/       ← Vulkan headers (tracked)
├── VisionPort/                     ← engine cross-compile workspace
│   ├── setup.sh                    ← fetches xash3d-fwgs, hlsdk, MoltenVK
│   ├── xash3d-visionos.patch       ← waf patch adding --xros / --xros-simulator
│   ├── build_xash_xrsim.sh         ← one-shot smoke build for simulator
│   └── xash3d-fwgs/                ← gitignored clone
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

### Phase 0b — Renderer decision ✅

Decided: **Vulkan via MoltenVK**. Verified end-to-end on AVP M5 — `VkInstance`
+ `vkEnumeratePhysicalDevices` returns the M5 GPU. ANGLE, native ref_metal,
and ref_soft are all dropped from the plan.

### Phase 1 — App shell ✅

- Xcode "visionOS App / Metal 4 Renderer" template
- Build for **device** only (Metal 4 isn't available on visionOS simulator —
  `CP_MTL4_AVAILABLE = !TARGET_OS_SIMULATOR`)
- C bridge linked, MoltenVK xcframework linked statically via
  `OTHER_LDFLAGS = -force_load $(SRCROOT)/Vendor/MoltenVK.xcframework/xros-arm64/libMoltenVK.a`
- HEADER_SEARCH_PATHS = `$(SRCROOT)/Vendor/MoltenVK_include`

### Phase 2 — Vulkan rendering 🔜

1. `lambda_vulkan_create_device()` — pick M5, create VkDevice + queues, query
   `VK_EXT_metal_objects` availability.
2. Per-frame from CompositorServices: render Vulkan into `IOSurface`-backed
   `VkImage`, blit to cp_drawable.
3. Replace template's MTL4 Renderer.swift with a Metal-3 presenter that just
   composites the IOSurface output.
4. Stereo via `cp_view` matrices fed to engine's view setup.

### Phase 2b — ref_vk choice

Options:
- **w23/xash3d-fwgs ref_vk** — full rasterizer, ~36K LOC, RT path unused
  (MoltenVK lacks Vulkan RT). Fork drift cost, but production-tested.
- **ref_vk_lite** — write minimal Vulkan ref against `engine/ref_api.h`'s 128
  function surface. Estimate ~5–8K LOC. More work, no fork drift, simpler.

Decide after Phase 2 confirms the present pipeline shape.

### Phase 3 — Input

- `GameController.framework` for Switch Pro Controller (buttons, sticks).
- `GCMotion` gyro for aim — primary VR-feel input.
- `ARKit HandTrackingProvider` for menu/UI gestures (pinch, palm-up menu).
- Map to Half-Life input events via `lambda_engine_inject_input()`.

### Phase 4 — Launcher / asset import

- `UIDocumentPickerViewController` for `valve/` import into app sandbox.
- Settings persistence (resolution scale, motion options, controller binds).
- (Optional) mod selection from imported `valve/`-likes.

## Build & run

```bash
# One-time
./VisionPort/setup.sh

# Build engine for visionOS (smoke test)
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
Renderer ambition can size up accordingly (MSAA, supersampling, post).

## Open risks

- **ref_vk integration scope** — w23's fork is sizable; Phase 2b decides.
- **Foveation interaction** — CompositorServices foveation is at the Metal
  layer. Vulkan-rendered IOSurface + Metal blit composites fine; direct
  `VK_EXT_metal_objects` import (Option B) needs investigation.
- **Engine main loop ownership** — Xash3D expects to own `main()`. We need
  to refactor to a frame-callback model (`lambda_engine_frame(dt)`) called
  from Renderer.swift. Significant Phase 2 work.
- **HLSDK static link** — visionOS forbids loading dylibs from outside the
  bundle. Sign HL game logic into the app binary statically; can't hot-load
  mods built as separate dylibs.

## Distribution

GitHub-only. User supplies `valve/` from their own Half-Life install on first
launch. GPL terms satisfied by source publication; HL assets never
redistributed.
