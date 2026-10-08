# Installing Lambda VisionPro on Apple Vision Pro

Lambda VisionPro is Half-Life running natively on Apple Vision Pro: the [Xash3D-FWGS](https://github.com/FWGS/xash3d-fwgs) engine and [hlsdk-portable](https://github.com/FWGS/hlsdk-portable), with Xash3D's `ref_gl` renderer running on Metal through [ANGLE](https://github.com/google/angle) and presented with Compositor Services. You play in a full immersive space, with hand-tracked weapons and locomotion. It is distributed on GitHub only, as source and as an unsigned `.ipa` you re-sign yourself; either way you bring your own copy of Half-Life.

## Quickest route: the unsigned .ipa

Every change to `main` that isn't docs-only is built into its own GitHub release (`v0.1.0-<commit>`, all kept). The newest one carries `LambdaVision-unsigned.ipa`; the stable link is `releases/latest/download/LambdaVision-unsigned.ipa`. It already contains the engine, ANGLE and the Opposing Force and Blue Shift ports, so nothing else needs building. Re-sign it with your own Apple ID or developer team (Sideloadly, AltStore, or Xcode's Devices window after re-signing) and install it on the headset, then follow Your game files below to get Half-Life onto the device. Skip What you need and Build from source unless you want to change the code.

## What you need

- A Mac with Xcode 26.4 or later (visionOS 26.4 SDK), and Python 3 (for waf, the Xash3D-FWGS build system)
- An Apple developer signing identity
- LLVM's `llvm-objcopy`, which the engine build needs (`brew install llvm`)
- Apple Vision Pro. The app builds for the device only: Metal 4 (`CompositorServices.MTL4`) isn't available in the visionOS Simulator.
- A Steam account that owns Half-Life. `scripts/fetch-assets.sh` downloads SteamCMD to `~/bin/steamcmd` if it isn't there yet.
- Room for the sources and, if no release carries a matching ANGLE, its first ~12 GiB `gclient sync` (see Build from source)

## Your game files

Nothing from Half-Life is in this repository or in the app. Xash3D-FWGS expects the **pre-25th-anniversary** game data, which Valve keeps on the `steam_legacy` beta branch of Half-Life (app 70); the README's [Half-Life assets](README.md#half-life-assets--pre-25th-anniversary-build) section explains why.

1. From the repository root, fetch it with your own Steam account:

   ```bash
   ./scripts/fetch-assets.sh YOUR_STEAM_USERNAME
   ```

   SteamCMD asks for your password and any Steam Guard code; the script never takes them as arguments or stores them. About 507 MB lands in `HalfLifeAssets/` (gitignored): `valve/`, plus the official HD pack in `valve_hd/`.

   For Opposing Force (app 50) and Blue Shift (app 130), add them to the same call, optionally with `--zip` to write files for importing on the headset:

   ```bash
   ./scripts/fetch-assets.sh --zip YOUR_STEAM_USERNAME 50 130
   ```

   Both expansions need your Steam account to own them. Their folders (`gearbox*`, `bshift*`) go into `HalfLifeAssets/` alongside `valve/`, and their zips into `build/asset-zips/`.
2. Build and install the app once (see below), so its data container exists on the headset.
3. Copy `scripts/build-signing.conf.example` to `scripts/build-signing.conf` (gitignored) and set:
   - `DEVICE_NAME`: your headset's name as `xcrun devicectl list devices` shows it (the example uses `Apple Vision Pro`)
   - `BUILD_BUNDLE_ID`: the app's bundle identifier, `com.illixion.LambdaVision` unless you changed it
4. Push the game files to the headset:

   ```bash
   ./scripts/push-assets.sh
   ```

   This copies every gamedir (`valve/`, `valve_hd/`, `gearbox/`, `bshift/`, mods) into the app's `Documents/GameData` with `devicectl`, and turns the HD pack on with a `vfs.cfg`. Later pushes skip unchanged files, and the data survives reinstalling over the existing app. Deleting the app from the headset wipes it; the app then shows a warning, and you run `push-assets.sh` again.

   Without a cable, send the same folders from the headset: open **Manage over Wi-Fi** in the app, or AirDrop the zips from `build/asset-zips/` and choose *Open in LambdaVision*. The README's [Expansions and mods](README.md#expansions-and-mods) section covers all routes.

5. Choose the game. The main window lists every installed game, Opposing Force and Blue Shift included. Pick one and the app starts it. Switching games needs an app relaunch, so relaunch after picking a different one.

To bake the assets into the app bundle instead, build with `BUNDLE_HL_ASSETS=1` (for example `xcodebuild ... build BUNDLE_HL_ASSETS=1`). Bundled assets are read-only; the app doesn't normalize them.

## Build from source

Start from a checkout of this repository. It links three local Swift packages by relative path, so they must sit next to your checkout, in the same parent folder, named exactly `RAVESDK`, `RAVEEngine` and `DebugTrace`:

```bash
cd ..        # the folder that holds your checkout
git clone https://github.com/illixion/RAVESDK.git
git clone https://github.com/illixion/RAVEEngine.git
git clone https://github.com/illixion/DebugTrace.git
cd -         # back into the checkout
```

Without them, Xcode fails at package resolution, before it compiles anything.

Building from source means building the engine yourself, unless a release already carries it. From the repository root, first try `./scripts/prebuilts.sh fetch` (seconds): it restores ANGLE, libxash and the Opposing Force / Blue Shift ports that were built from your exact sources, from the newest release that has them, and skips whatever you already have. Then fetch the pinned engine sources and build what's still missing. All the scripts are idempotent, so rerunning them later is a fast no-op. Ports not restored come from `./VisionPort/build_game.sh` (see the README):

```bash
./VisionPort/setup.sh                 # pinned xash3d-fwgs, hlsdk-portable and MoltenVK, with the visionOS patches
./VisionPort/build_xash_libxash.sh    # libxash.a
./VisionPort/build_angle_visionos.sh  # ANGLE (libEGL/libGLESv2); the first run is slow
```

Skipping the ANGLE step fails later as a linker error rather than a clear message.

1. Open `LambdaVision/LambdaVision.xcodeproj`.
2. In the LambdaVision target's signing settings, set `DEVELOPMENT_TEAM` to your own team. If Xcode reports that the bundle identifier isn't available to your team, change it to one of your own and use the same value for `BUILD_BUNDLE_ID` above.
3. Build and run on your Vision Pro. For playing, switch the scheme's Run action to Release (Product › Scheme › Edit Scheme › Run › Build Configuration): Debug builds are unoptimized (`-Onone`) and noticeably slower. Xcode's pre-build step (`scripts/pre-build.sh`) fetches the pinned xash3d-fwgs and hlsdk-portable sources and MoltenVK, applies the visionOS patches, and checks that `libxash.a` exists.

From the command line instead (find the UDID with `xcrun xctrace list devices`):

```bash
xcodebuild -project LambdaVision/LambdaVision.xcodeproj \
  -scheme LambdaVision \
  -destination 'id=YOUR_AVP_UDID' \
  -configuration Release build

xcrun devicectl device install app \
  --device YOUR_AVP_UDID \
  ~/Library/Developer/Xcode/DerivedData/LambdaVision-*/Build/Products/Release-xros/LambdaVision.app

# Optional: launch it and stream its log
xcrun devicectl device process launch \
  --device YOUR_AVP_UDID --console com.illixion.LambdaVision
```

Then push your game files as described above.

## Notes

- The main input is hand tracking: hand-tracked aim, an off-hand locomotion joystick, gaze-and-pinch menus, a radial weapon menu and finger-gun fire. The README describes the VR input as proof-of-concept quality, functional but rough; [ISSUES.md](ISSUES.md) lists the specifics.
- Keyboard, mouse and gamepad also work. With a mouse connected, a *Click to lock mouse* panel appears first; clicking it hands the mouse to the game, and moving the pointer off the game or opening the menu releases it. The Settings window's *Ask before locking the mouse* turns the panel off. Free aim moves the weapon inside a zone in front of you and only turns your body at the zone's edge; its size and centring are in Settings.
- The settings window covers render scale, gamma and brightness, snap-turn angle, audio volumes, dominant hand, gesture toggles, and the stock Half-Life menu and console.
- Half-Life is a trademark of Valve Corporation. This is a fan-made, non-commercial port, not affiliated with or endorsed by Valve.
