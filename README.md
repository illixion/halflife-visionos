# Lambda VisionPro

Half-Life on Apple Vision Pro — a port of [Lambda1VR](https://github.com/DrBeef/Lambda1VR)
(Quest VR Half-Life built on Xash3D-FWGS) to visionOS, using **MoltenVK** for
GPU rendering and **CompositorServices** for the immersive frame loop.

GitHub-only distribution. No App Store target. Bring your own Half-Life copy.

See [PLAN.md](PLAN.md) for architecture, phase plan, and risks.

## Status

Phase 1 complete: app shell builds and runs on AVP, Vulkan via MoltenVK
verified end-to-end (Vulkan 1.4.334, 151 extensions). Phase 2 (engine
rendering) in progress.

## Prerequisites

* macOS with **Xcode 26.4+** (visionOS 26.4 SDK)
* Apple Vision Pro for testing (Metal 4 / `CompositorServices.MTL4` is not
  available on the visionOS simulator — see Phase 1 notes)
* Apple developer signing identity
* `steamcmd` for fetching Half-Life assets
* Python 3 (for waf, the xash3d-fwgs build system)

## First-time setup

```bash
git clone <this-repo> Lambda_VisionPro
cd Lambda_VisionPro

# Fetch xash3d-fwgs, hlsdk-portable, and MoltenVK.xcframework
./VisionPort/setup.sh

# Open the Xcode project
open LambdaVision/LambdaVision.xcodeproj
```

Update `DEVELOPMENT_TEAM` in the LambdaVision target's signing settings to
your team ID, then build & run on your AVP.

## Half-Life assets — pre-25th anniversary build

Half-Life's **25th Anniversary Update** (Nov 2023) made breaking changes to
the engine and game files: shader format changes, asset reorganisation, and
mod-compatibility breaks. Xash3D-FWGS and the Half-Life mod ecosystem expect
the **pre-anniversary** game data.

Valve archived the pre-anniversary build to a public Steam beta branch
called **`steam_legacy`** ("Pre-25th Anniversary Build") for app **70**
(Half-Life). Download it via SteamCMD:

```bash
~/bin/steamcmd/steamcmd.sh \
  +force_install_dir "$PWD/HalfLifeAssets" \
  +login YOUR_STEAM_USERNAME \
  +app_update 70 -beta steam_legacy validate \
  +quit
```

This grabs ~507 MB across 5 depots:

| Depot | Manifest                | Size   | Contents                         |
|-------|-------------------------|--------|----------------------------------|
| 1     | 5928322771446233610     | 430 MB | Main `valve/` (BSPs, WADs, dlls) |
| 3     | 8096513071444961518     | 0.9 MB | Shared launcher bits             |
| 71    | 9183617604528345869     | 15 MB  | Multi-platform binaries          |
| 96    | 8007990985538868417     | 8 MB   | macOS-specific runtime           |
| 9     | 5920416249792874591     | 53 MB  | Misc shared content              |

(Build ID **5433873**, captured 2026-05-10. Valve does occasionally re-mint
the legacy build; manifests may shift.)

The folder we care about is `HalfLifeAssets/valve/` — that's the directory
the engine and Lambda VisionPro's importer will accept on first launch. It
is NOT redistributable; ignore it from git (already in `.gitignore`).

### Why pre-anniversary specifically

* The **25th-anniversary engine** changes the renderer/shader pipeline. Xash3D
  is built against the pre-anniversary engine model.
* Many existing HL mods break on the 25th-anniversary build for the same
  reason; Lambda1VR (our reference) targets the pre-anniversary game.
* Xash3D-FWGS will load 25th-anniversary `valve/` BSPs but rendering and
  some game logic edge-cases differ. Don't fight it; use legacy.

## Build & run cheat sheet

```bash
# Engine smoke build for visionOS simulator (dedicated server only, no GL)
./VisionPort/build_xash_xrsim.sh

# App build for AVP device
xcodebuild -project LambdaVision/LambdaVision.xcodeproj \
  -scheme LambdaVision \
  -destination 'id=YOUR_AVP_UDID' \
  -configuration Debug build

# Install
xcrun devicectl device install app \
  --device YOUR_AVP_UDID \
  ~/Library/Developer/Xcode/DerivedData/LambdaVision-*/Build/Products/Debug-xros/LambdaVision.app

# Launch and stream logs
xcrun devicectl device process launch \
  --device YOUR_AVP_UDID --console com.illixion.LambdaVision
```

Find your AVP's UDID with `xcrun xctrace list devices`.

## Layout

```
LambdaVision/      Xcode visionOS app (Swift + C bridge + MoltenVK)
VisionPort/        Engine cross-compile workspace (xash3d-fwgs + patch + setup)
PLAN.md            Architecture, phase plan, risks
README.md          You are here
```

## Licensing

Source under GPL (matches Xash3D-FWGS). Half-Life game assets remain Valve's
property; users supply their own copy. See
[Half-Life Legacy](https://developer.valvesoftware.com/wiki/Half-Life_Legacy)
for Valve's policy.
