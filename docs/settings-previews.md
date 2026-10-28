# Settings preview pictures

The Settings window's right-hand column shows a picture or looping clip for the
setting you are on (`SettingHelp.swift` has the words, this is the list of
names). Drop a file with the name below into
`LambdaVision/LambdaVision/Previews/` (any of `.jpg .jpeg .png .heic`, or
`.mp4 .mov .m4v` for a looping, muted clip; a clip wins over a picture of the
same name). Xcode bundles the folder automatically. A name with nothing behind
it shows a "Picture coming soon" placeholder, with the name on it when
Developer mode is on, so the column works before the pictures exist.

Pictures are shown 16:10 and cropped to fill, so shoot or crop 16:10 (1600×1000
is plenty). A setting with an `-off` / `-on` pair (or one picture per choice)
is shown as a segmented control: the picture for the setting's present value,
and the others to peek at without changing anything. Take the pair from the
same spot with the same view so only the setting differs.

Pictures of the game come from the player's own copy and shouldn't be
checked in if they are not ours to ship: keep them to what we may include, or
leave them out of the repository and bundle them in a release build only.

## Names wanted

| Name | Shows |
| --- | --- |
| `\(name)-off` |  |
| `\(name)-on` |  |
| `aimReticle-beam` |  |
| `aimReticle-dot` |  |
| `aimReticle-off` |  |
| `altFireGesture` |  |
| `armSwing` |  |
| `avatarBody-off` |  |
| `avatarBody-on` |  |
| `avatarLegs-off` |  |
| `avatarLegs-on` |  |
| `edgeSmoothing` |  |
| `engineMSAA-off` |  |
| `engineMSAA-on` |  |
| `fingerGun` | finger-gun fire loop (a drawn stand-in ships; a clip replaces it) |
| `flashlightOnGun-off` |  |
| `flashlightOnGun-on` |  |
| `foveatedEngine` |  |
| `freeAim` |  |
| `fxaaEnabled-off` |  |
| `fxaaEnabled-on` |  |
| `gamma` |  |
| `glassReflections-off` |  |
| `glassReflections-on` |  |
| `hevHUD-off` |  |
| `hevHUD-on` |  |
| `hideParkedParts-off` |  |
| `hideParkedParts-on` |  |
| `linearColor-off` |  |
| `linearColor-on` |  |
| `progressiveImmersion-off` |  |
| `progressiveImmersion-on` |  |
| `reflectionStrength` |  |
| `renderScale` |  |
| `reprojectionDepth-off` |  |
| `reprojectionDepth-on` |  |
| `sharpGlassReflections-off` |  |
| `sharpGlassReflections-on` |  |
| `sharpWaterReflections-off` |  |
| `sharpWaterReflections-on` |  |
| `waterMirrorMethod-rayTraced` |  |
| `waterMirrorMethod-rendered` |  |
| `waterMirrorMethod-screenSpace` |  |
| `waterReflections-off` |  |
| `waterReflections-on` |  |
| `waterRipples` |  |
| `weaponExternal-off` |  |
| `weaponExternal-on` |  |
| `weaponModel-viewmodel` |  |
| `weaponModel-world` |  |
| `weaponWheel` |  |
