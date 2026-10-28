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
