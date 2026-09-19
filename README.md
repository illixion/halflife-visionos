# Lambda VisionPro

Half-Life on Apple Vision Pro — [Xash3D-FWGS](https://github.com/FWGS/xash3d-fwgs)
running its `ref_gl` renderer via [ANGLE](https://github.com/google/angle)
(GLES → Metal) under **CompositorServices**, with a Swift/Metal launcher,
settings, and hand-tracked VR input layered on top. Inspired by
[Lambda1VR](https://github.com/DrBeef/Lambda1VR) (the Quest VR Half-Life
port); built independently from Xash3D-FWGS and hlsdk-portable, no
Lambda1VR code is reused.

GitHub-only distribution. No App Store target. Bring your own Half-Life copy.

See [PLAN.md](PLAN.md) for architecture, phase plan, and risks.

## Status

Playable end-to-end on AVP: engine rendering (foveated, 120 FPS stable),
hand-tracked weapons and locomotion, gaze/pinch menu navigation, a settings
window (graphics/audio/input), spatial-ish audio, and a live performance
HUD are all in and working. The renderer pivoted from an early Vulkan/
MoltenVK prototype to Xash3D's own `ref_gl` driven by ANGLE in May 2026 —
`ref_gl` is the complete, production renderer (studio models, lighting,
particles, decals), whereas the from-scratch Vulkan path only ever reached
~5% feature parity. A Vulkan/MoltenVK smoke test still lives in the
launcher UI as a leftover diagnostic from that earlier phase; it's not
part of the render path.

**Known limitations:** VR input (aiming, locomotion, gestures) is
proof-of-concept quality — functional enough to play, but rough around the
edges compared to the rest of the app. See [ISSUES.md](ISSUES.md) for
specifics, and [PLAN.md](PLAN.md) for the full phase history.

## Prerequisites

* macOS with **Xcode 26.4+** (visionOS 26.4 SDK)
* Apple Vision Pro for testing (Metal 4 / `CompositorServices.MTL4` is not
  available on the visionOS simulator — see Phase 1 notes)
* Apple developer signing identity
* `steamcmd` for fetching Half-Life assets
* Python 3 (for waf, the xash3d-fwgs build system)

## First-time setup

```bash
# This repo and both RAVE packages must sit in the same parent directory
git clone <this-repo> Lambda_VisionPro
git clone https://github.com/illixion/RAVESDK.git
git clone https://github.com/illixion/RAVEEngine.git

cd Lambda_VisionPro

# Open the Xcode project
open LambdaVision/LambdaVision.xcodeproj
```

### RAVE packages

Lambda VisionPro links two shared packages:

| Package | Products used |
|---|---|
| [`RAVESDK`](https://github.com/illixion/RAVESDK) | `RAVEConsole` |
| [`RAVEEngine`](https://github.com/illixion/RAVEEngine) | `RAVEInput`, `RAVEDiagnostics` |

Both are referenced as **local** Swift packages by relative path —
`../../RAVESDK` and `../../RAVEEngine`, resolved against the directory holding
`LambdaVision.xcodeproj` — not as versioned remote dependencies. A clone
therefore does not fetch them, which is why the commands above clone all three
side by side:

```
some-parent/
├── RAVESDK/
├── RAVEEngine/
└── Lambda_VisionPro/
```

The requirement is only that this repo's parent directory also contains
directories named exactly `RAVESDK` and `RAVEEngine`; this repo's own directory
name does not matter. Get it wrong and Xcode fails at package resolution, before
compiling anything — and before the build phase that fetches xash3d-fwgs runs.

Why path references and not versions: the packages and the apps co-evolve
continuously — the hand input this app uses was converged into `RAVEInput` out of
this app and two others — and a path reference keeps "move this into the package
and update its callers" a single atomic edit.

While the off-hand locomotion clutch is held, LambdaVision renders RAVEInput's
shared joystick visualization as a head-facing outer ring, deadzone ring, and
handle above the movement wrist. It uses the existing Metal weapon/UI arc pass,
so the feedback remains stereoscopic and world-anchored without adding a
RealityKit overlay to the Compositor Services renderer.

Update `DEVELOPMENT_TEAM` in the LambdaVision target's signing settings to
your team ID. Before the first build, two engine artifacts need to exist —
Xcode's pre-build hook fetches source (`xash3d-fwgs`, `hlsdk-portable`,
`MoltenVK.xcframework`) automatically and idempotently, but it only
_checks_ for these, it doesn't build them:

```bash
./VisionPort/build_xash_libxash.sh   # libxash.a — pre-build hook errors if this is missing
./VisionPort/build_angle_visionos.sh # ANGLE (libEGL/libGLESv2) — ~12 GiB gclient sync,
                                      # first run is slow; pre-build hook does NOT check
                                      # for this one, so skipping it fails as a linker
                                      # error instead of a clear message
```

Both are idempotent — rerunning after the first successful build is a
fast no-op. After that, build & run on your AVP from Xcode as normal.

## Half-Life assets — pre-25th anniversary build

Half-Life's **25th Anniversary Update** (Nov 2023) made breaking changes to
the engine and game files: shader format changes, asset reorganisation, and
mod-compatibility breaks. Xash3D-FWGS and the Half-Life mod ecosystem expect
the **pre-anniversary** game data.

Valve archived the pre-anniversary build to a public Steam beta branch
called **`steam_legacy`** ("Pre-25th Anniversary Build") for app **70**
(Half-Life). Fetch it with:

```bash
./scripts/fetch-assets.sh YOUR_STEAM_USERNAME       # macOS / Linux
.\scripts\fetch-assets.ps1 -SteamUsername YOUR_STEAM_USERNAME   # Windows
```

Either script downloads SteamCMD to `~/bin/steamcmd` first if it isn't
there already, then runs it non-interactively except for the password /
Steam Guard prompts (never passed as an argument, never stored). Equivalent
manual invocation, if you'd rather run SteamCMD yourself:

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

The folder we care about is `HalfLifeAssets/valve/`. Assets reach the
device out of band: after installing the app once, run
`./scripts/push-assets.sh` to copy every gamedir (valve/, valve_hd/,
mods…) into the app's `Documents/GameData` via `devicectl`. The copy is
incremental (unchanged files are skipped; `--delete` mirrors removals), it
survives plain reinstalls (rebuilding over the existing app), and code-only
rebuilds no longer re-send ~450 MB per install. It does NOT survive
deleting the app from the headset first — that wipes the data container,
so `Documents/GameData` is empty again and the app shows an on-screen
warning to re-run `push-assets.sh`. The engine prefers `Documents/GameData`
as `-rodir` when `valve/liblist.gam` is present there.

For a self-contained app (assets baked into the bundle — e.g. handing a
build to someone), build with `BUNDLE_HL_ASSETS=1` set (re-enables the
"Bundle HalfLifeAssets" Run Script phase), e.g.
`xcodebuild ... build BUNDLE_HL_ASSETS=1`, or add it as a build setting in
Xcode; the engine falls back to `<bundle>/GameData` when no Documents copy
exists.

The folder is NOT redistributable; it's already gitignored.

### Why pre-anniversary specifically

* The **25th-anniversary engine** changes the renderer/shader pipeline. Xash3D
  is built against the pre-anniversary engine model.
* Many existing HL mods break on the 25th-anniversary build for the same
  reason; Lambda1VR (our reference) targets the pre-anniversary game.
* Xash3D-FWGS will load 25th-anniversary `valve/` BSPs but rendering and
  some game logic edge-cases differ. Don't fight it; use legacy.

## Build & run cheat sheet

```bash
# One-time engine builds (see First-time setup above for details)
./VisionPort/build_xash_libxash.sh
./VisionPort/build_angle_visionos.sh

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
LambdaVision/      Xcode visionOS app (Swift + C bridge + ANGLE)
VisionPort/        Engine cross-compile workspace (xash3d-fwgs + patch + setup)
PLAN.md            Architecture, phase plan, risks
README.md          You are here

../RAVESDK/        Shared package, cloned as a sibling (see First-time setup)
../RAVEEngine/     Shared package, cloned as a sibling (see First-time setup)
```

## Licensing

This repo doesn't contain a single license — three different bodies of code
are involved, and they're licensed separately:

* **This repo's own source** (Swift app, Metal passes, build scripts,
  patches against xash3d-fwgs) — **GPLv3**, see [LICENSE](LICENSE). This
  isn't just a style choice: `xash3d-fwgs` is GPLv3, and this app statically
  links the engine into a single binary rather than running it as a separate
  process, so the combined binary is a derivative work and GPLv3's copyleft
  applies to the whole thing.
* **`hlsdk-portable`** (cloned by `VisionPort/setup.sh`, patched by
  `VisionPort/hlsdk-visionos.patch`) — Valve's original **Half-Life 1 SDK
  LICENSE**, not GPL. It permits free copying, modification, and
  distribution of the SDK and your modifications, in source or object form,
  but only for free (no charge) and only distributed together with that
  LICENSE file. `hlsdk-visionos.patch` is a derivative of Valve's SDK code
  and is bound by those same terms, not GPLv3.
* **Half-Life game assets** (`HalfLifeAssets/`) — Valve's property, never
  redistributed here (gitignored; fetched by each user from their own Steam
  account via `scripts/fetch-assets.sh`). See
  [Half-Life Legacy](https://developer.valvesoftware.com/wiki/Half-Life_Legacy)
  for Valve's policy.

This project is a fan-made, non-commercial port and is not affiliated with
or endorsed by Valve Corporation. Half-Life is a trademark of Valve
Corporation.

This app also links [RAVESDK](https://github.com/illixion/RAVESDK) and
[RAVEEngine](https://github.com/illixion/RAVEEngine) as local Swift package
dependencies; both are MIT-licensed (unaffected by the GPLv3 obligation
above, since that only reaches the combined LambdaVision distribution, not
the packages' own repos). See [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)
for their license text.
