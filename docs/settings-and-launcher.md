# Settings, presets and the launcher

How the player-facing front end is put together (2026-10-28 rework). Source:
`LambdaVision/LambdaVision/Settings/`, `Settings/Presets/`, `Settings/Preview/`
and `Launcher/`.

## Presets

A preset is named values for some **categories** of settings: Graphics,
Reflections & Water, Immersion, Hands, Keyboard/Mouse/Gamepad, Audio
(`PresetCategory`). Applying one shows, per category it holds, what would
change (`Glass reflections  Off → On`) with a checkbox, so a look preset can
leave the controls alone. Settings › Presets lists the three that ship, the
player's own, and the actions: save the present settings (choosing the
categories), rename, delete, import a file, export a file.

- **Enhanced**: 4× MSAA with FXAA, glass and water reflections, body and legs,
  the weapon in the hand, holograms, gestures, the portal. Picks **ray-traced**
  reflections only where `DeviceCapability.hardwareRayTracing` (Apple GPU family
  10, the M5 headset); elsewhere the engine-rendered mirror.
- **Classic**: no reflections, no body, the engine's weapon, flashlight and flat
  HUD; invisible tech (foveation, reprojection depth) stays on.
- **Performance**: no reflections, no edge smoothing.

A built-in names only the settings that define it, so applying it doesn't touch
the player's hand, volumes or gamma. "In use" is whichever preset the settings
already match in every category it holds, else "Custom".

**Files**: `.lambdapreset`, JSON (`SettingsPreset`), type
`com.illixion.lambdavision.preset` exported in Info.plist, so a preset can be
AirDropped or opened from Files (`onOpenURL` keeps a copy and offers it). A file
is checked against `PresetSchema` (`sanitized`): unknown settings are dropped,
numbers clamped, a setting under the wrong category dropped, a newer file
version refused. Settings that belong to the device or session (developer mode,
debug server, chosen game) are not in the schema on purpose.

**Adding a setting**: a key + accessor in `AppSettingsStore`, a property in
`GameSettings`, then (to make it preset-able) an entry in `PresetSchema.specs`
with its title, and one in `SettingsBindings.table`. `Tools/PresetProbe/build.sh`
fails if the two disagree or a binding's property is missing.

## The Settings window

Sidebar of pages, the page's controls, and a **preview column** on the right
(`PreviewPane`). A control claims the column with `.previews("key", value:)`
(looking at it, tapping it, or changing it, from anywhere); the column shows the
picture or clip for the setting's present value, the other values to peek at
without changing anything, a few sentences on what it does (`SettingHelp`), and
"applies when the game restarts" where that is so. The long footers that used
to sit under the controls are in `SettingHelp`.

Pictures are files in `Previews/` found by name; `docs/settings-previews.md` is
the list, and `scripts/capture-preview.sh` takes the off/on pairs from the
running game. Until a picture exists the column shows a placeholder.

## The launcher

The main window: a banner (Play / Resume / Leave, the chapter being played, the
preset in use), quick actions (game menu, quick save, quick load, restart,
console log, settings), a chapter picker, saved games, a console line. All of
it goes through `GameLauncher`, which opens the immersive space and, for a
chapter or a save, runs `map <id>` / `load <name>` as soon as the engine is
ready.

- **Chapters** (`ChapterCatalog`): the first map of each chapter of Half-Life,
  Opposing Force and Blue Shift, from each game's `titles.txt`, shown when the
  map is installed. Other games get a map box. `Tools/LauncherProbe/build.sh`
  checks the lists against the installed maps.
- **Chapter art** (`ChapterArt`): a picture `Previews/chapter-<gamedir>-<map>`
  when there is one, else a drawn card. Chapter pictures are screenshots of the
  player's own game, so they are gitignored and not shipped.
- **Saved games** (`SaveStore`): the engine's save folder
  (`Application Support/xash3d/<gamedir>/save`), each with the picture the
  engine saved beside it and the map found in the file header.

## Chapter pictures made by the engine

The chapter cards show a picture the engine rendered on this device from a spot
you chose; without one they draw their own card.

- **Mark a spot:** turn on Developer mode, open the weapon wheel in the game and
  pick **SHOT** (after SAVE and LOAD). A blip confirms it. It records the map, the
  camera position and the view angles (`lambda_debug_view`; roll is dropped).
  Marking the same map again replaces its spot. `POST /markshot` does the same, `POST /setshot`
  sets one by numbers and `POST /removeshot` drops one.
- **Where the list lives:** `ChapterShotStore` reads the bundled
  `Launcher/ChapterShots.json` and puts the player's own
  `Application Support/LambdaVision/ChapterShots.json` on top. `GET /chaptershots`
  returns the list in the shape of the repo file: paste it into
  `Launcher/ChapterShots.json` to ship the spots. They are numbers only.
- **Make the pictures:** the launcher's *Chapter pictures* card (Developer mode) or
  `POST /makepictures` (optionally `map=`) runs `ChapterPictureRunner`. For each spot it
  loads the map, hides the HUD, crosshair and console lines, teleports the player
  (`sv_cheats`, `sv_enttools_enable`, noclip, `ent_fire 1 set origin`), nudges the position
  and yaw until the camera the engine reports matches the spot, waits for the engine console
  to finish sliding away and for any fade, then takes the engine's left-eye colour map
  (`FrameCapture`, source engine; this is the app's own capture, no approval), cuts a
  16:10 picture from its middle and writes
  `Application Support/LambdaVision/Chapter Pictures/<gamedir>-<map>.jpg`. It restores the
  cvars it changed and returns to the launcher.
- **Camera:** `Renderer.scriptedPitch` makes the renderer ignore the head for the run
  (this pitch, no head yaw or tilt, no head offset, no eye separation, no body), so the
  player moving their head doesn't matter.
- **Not shipped:** the pictures are made from the player's own game and stay on the device.

The plan this belongs to (windowed play, the engine core split from CompositorServices) is
in `docs/plans/windowed-mode-and-chapter-shots.md`.
