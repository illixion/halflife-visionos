# Windowed mode, a frame loop of our own, and engine-made chapter pictures

Written 2026-10-28. Nothing here is built yet; this is what the code and Apple's
material say, and the order I would build it in.

## 1. What we want

1. **Windowed play** ("TV mode"): Half-Life in a visionOS window, in stereo, with
   depth that follows your head like a window into the map, the viewmodel held
   where it is for comfort. Controller or keyboard and mouse, so it plays from a couch.
2. **A frame loop that is not CompositorServices'**, so the engine can run in a window, and so
   pictures can be made without entering the immersive space.
3. **Chapter pictures made by the engine** from camera spots you choose, with a quick
   button in-game to record the spot.

## 2. What Apple supports (WWDC24 10093 and the sample "Rendering a windowed game in stereo")

Apple's sample does close to what you describe, on visionOS 2 and later, Vision Pro only (not the simulator).

- **Output:** Metal draws into a RealityKit `LowLevelTexture` (or a `CAMetalLayer`). Apple
  recommends the texture for the most control. A `ZStack` can put a `RealityView` frame around it.
- **Stereo:** two images, one per eye, shown through a RealityKit ShaderGraph material
  using the `CameraIndex` node to pick the left or right texture. Apple advises against
  content beyond infinity (parallax larger than the eye distance diverges your eyes), a stereo-strength
  slider (distance between the two virtual cameras), and, for maximum comfort, showing
  the image on an infinitely far plane through a portal so everything sits in front of it.
- **Head tracking needs an `ImmersiveSpace`.** In the Shared Space there is no head position.
  The sample opens an immersive space next to the window, reads `WorldTrackingProvider.queryDeviceAnchor`
  every frame (predicting about 33 ms ahead), and converts the head into the window's coordinates with
  `entity.transformMatrix(relativeTo: .immersiveSpace)`. It then builds an **off-axis projection through
  the window rectangle**, so the picture looks like a physical window. The near plane can lie on the window plane.
- **Resolution:** variable rasterization rate maps, built from the head pose, or in the Shared
  Space from `AdaptiveResolutionComponent` values on a grid over the window.
- **Input:** game controllers work in windows out of the box (WWDC24 10094, Explore game input).

**So "windowed, with head follow" is a window plus a small immersive space that stays open.**
The space would be mixed or progressive, with passthrough and no Compositor content, only to
let ARKit run. Not verified here: that our app can switch between this space and the existing
CompositorLayer spaces cleanly (only one immersive space is open at a time), and how mouse capture
behaves with a window instead of the immersive `InputCatcher`.

## 3. Where our frame loop depends on CompositorServices

`Renderer.renderFrame` (`Renderer.swift` around lines 2400 to 3310) is the loop. Reading it:

- **Already independent of the compositor:** the engine render call. `lambda_gl_worker_render_eye_full`
  takes eye offset, frustum tangents, near and far, view angles, head offset, the target
  texture and its size. The engine draws both eyes into our own `colorMap` texture array through ANGLE.
- **What it takes from the drawable:** per-eye `views[i].transform` (eye offset) and `frustumTangents`;
  the rasterization rate maps (foveation: `EngineFoveation`); `frameTiming.presentationTime` and the `DeviceAnchor`
  (head pose, which also feeds the avatar, mirror and reprojection); `colorTextures` size (`ensureColorMap`);
  the layered render target format and view count in every pipeline.
- **Frame pacing:** `queryNextFrame`, `startUpdate`, `endUpdate`, `predictTiming`, `queryDrawables`,
  `startSubmission`, `endSubmission`. Only these set the cadence.
- **What the composite (`render(drawable:)`, around lines 3345 to 4080) does:** samples `colorMap` into the
  drawable with FXAA, dither and gamma, then the weapon pass, avatar, HUD, arms, reprojection depth and
  the progressive pass. That is about 750 lines tied to a drawable.
- **The HUD box** is placed by the eye's tangents (`lambda_gl_worker_set_2d_viewport`), 50 degrees wide at
  2 m. In a window it would fill the window instead.

### The split

1. **Engine core** (host-independent): engine init, input polling, game state, level-load snapshot,
   per-eye engine render, glass probe and water passes, GPU fences. Input is a `ViewSet`: eye offsets,
   tangents, optional head pose, present time, optional rate maps. Output is `colorMap` plus fences.
2. **`CompositorHost`**: today's loop. It builds the `ViewSet` from the drawable and keeps the composite.
3. **`WindowHost`**: a display link at the window's cadence, a `ViewSet` from the head pose
   (off-axis frustum through the window, two virtual cameras), and a small display pass that writes
   `colorMap` into two `LowLevelTexture`s (FXAA, dither, gamma only).

Risks. `Renderer` is a 4,259-line class with many `nonisolated(unsafe)` statics, and it is a frame-budget
app: each step must leave the immersive path unchanged and be measured on the headset. The weapon, avatar and arms
passes are immersive-only and stay with `CompositorHost`.

### Viewmodel comfort

In the immersive path the weapon is drawn outside the engine (`weaponExternal`, `WeaponPass`). In window mode
the engine's own viewmodel is drawn in view space. With an off-axis camera that follows the head it would
slide across the window as you move. To hold it still, draw it with the camera before the head offset (a second engine pass or an
engine option); this is the first thing to prototype.

## 4. Chapter pictures from the engine

### Recording a spot

- **Trigger (in-game):** a weapon-wheel utility entry next to SAVE and LOAD (`WeaponWheel.entries`,
  `utilities`), a gamepad chord, and a console command. The launcher window is not visible in the immersive space, so
  the trigger has to be in the game.
- **What is recorded:** the map, the engine's camera origin and angles (`lambda_debug_view` already reads
  `refState.vieworg` and `viewangles`), the game folder and an optional note. Several spots per map are allowed.
- **Where it goes:** a JSON shot list. The positions are our data, not Valve's, so the list can be
  committed to the repo (`LambdaVision/LambdaVision/Launcher/ChapterShots.json`). A local file in Application
  Support overrides it while you are choosing.
- **Feedback:** a short on-screen confirmation ("Shot saved for c1a2") and a debug endpoint listing the list.

### Making the picture

- **Camera:** one new bridge call that sets an absolute render camera (origin and angles), instead of moving the player. It
  does not exist yet (`lambda_engine_set_view_offset` is relative to the head baseline).
- **Run:** a "Make chapter pictures" command loads each map once, waits for the level to settle, renders the
  engine's frame for each saved spot at a fixed 16:10, writes a JPEG to Application Support, and
  `ChapterArt` shows it. A map is loaded once per shot list entry group, so about 40 maps take a few
  minutes.
- **No approval prompt:** the app captures its own `colorMap`, never the compositor screen.
- **Licensing:** the pictures are made from the player's own installed game and stay on the device. The
  shot list contains only numbers.
- The same runner makes the **settings preview pictures** (a scene list with setting values to flip, off and on).

## 5. Order I would build it in

1. **Shot list, record button, absolute-camera bridge call, picture runner on today's loop.** It needs the immersive space
   open for the run, but nothing else, and it gives the launcher real chapter pictures immediately.
   Also useful for the settings pictures.
2. **Extract the engine core and `ViewSet`.** A pure refactor, device-checked at each step; the immersive path stays identical.
3. **`WindowHost` mono:** window plus display pass, no head tracking, controller and keyboard input.
   This is also what lets step 1 run without entering the immersive space.
4. **Stereo and head follow:** second texture, `CameraIndex` material in Reality Composer Pro, the small
   immersive space for ARKit, window-space conversion, off-axis frustum, stereo-strength slider.
5. **Viewmodel hold, the frame, comfort tuning, optional rate maps.**

## 6. Open questions

- Does switching between the head-tracking space and the Compositor spaces leave the engine and its
  state intact (the engine runs on its own GL worker, so it should)?
- Mouse and keyboard in a window: pointer lock and raw motion. `InputCatcher` is built for the immersive space.
- Can the engine run at the window's display-link cadence, and does ANGLE need a context change when the host changes?
- How much of `PhaseAudioEngine` depends on the head pose; in a window it would use the virtual camera.
