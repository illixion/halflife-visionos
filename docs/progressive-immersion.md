# Progressive immersion: Mac Virtual Display conflict

Settings › Graphics › Immersion › "Progressive immersion (experimental)"
opens the game in a second immersive space (`AppModel.progressiveSpaceID`,
`.immersionStyle(... in: .progressive)`) whose layer is configured for the
compositor's drawable render context. Off by default while compatibility testing continues. Oneiros parked the same feature for the same symptoms
(`~/Projects/Oneiros/KNOWN_ISSUES.md`, 2026-08-27).

## Verified workaround (2026-10-28)

**Disconnect Mac Virtual Display, then close and reopen the immersive space.**
Disconnecting alone did not recover the existing probe space. After reopening,
the blue portal resized with the Crown. LambdaVision's original Metal 4 renderer
also resized normally after opening with Mac Virtual Display disconnected; no
renderer code changes were needed. Reconnecting Mac Virtual Display reproduced
the failure in the separate Metal 3 probe.

Treat this as a system interaction, not evidence that either game's renderer
needs replacing. Full immersion remains the fallback while Mac Virtual Display
is connected. A headset restart initially restored the probe too, but is not
necessary for the verified disconnect-and-reopen workaround. Oneiros has the
same historical symptoms; its implementation was inspected, but Oneiros itself
was not retested during this investigation.

## What is wired (all in `ProgressivePass.swift` plus the space and layer config)

- The layer asks for a stencil format and `drawableRenderContextRasterSampleCount = 1`
  (`ImmersiveSpaceContent.makeConfiguration`, only when `progressive`).
- Per drawable, after `deviceAnchor` is set: `drawable.addRenderContext()`.
- The last pass of the frame (before the debug screenshot copy): colour and depth
  loaded and stored, a memoryless stencil, `drawMaskOnStencilAttachment`, then one
  fullscreen triangle that fails the stencil test inside the portal and writes
  transparent black outside it, then `endEncoding(commandEncoder:)`.

## What the headset showed (2026-10-27)

1. Context added, no erase: the composite pass's picture is cut off outside a
   world-fixed portal, in 32 px tiles, and what is outside shows as a black void.
   The engine's own image (`screenshot source=engine`) is complete, so the engine
   and the rate map are not at fault.
2. With the erase pass: the room shows through outside the portal and the
   compositor's soft edge draws. The edge flickers.
3. The Digital Crown does not scale the portal. It is "binary": a portal of one
   size, or black at the top. Allowing only `.progressive` (no `.full`) changed
   nothing. A screenshot taken with the crown at the top shows the same ellipse as
   one taken lower, so the mask the compositor draws does not follow the dial.
4. System log: `com.apple.Compositor/client: layer supports progressive style 1`,
   and `Immersion state did change: 1.000000` on every crown event (that
   channel belongs to a window scene, so it may say nothing about the layer).

## Ideas recorded before the investigation

- Apple's own pattern in the draws: the mask goes in the encoder that draws the
  scene, and the scene's draws test the stencil, so only the visible pixels are
  shaded (this is what Oneiros does; the erase here is a stand-in).
- The parameterised style, `.progressive(range, initialAmount:, aspectRatio:)`
  (the plain `.progressive` is portrait, 0.3...1.0 starting at 0.7).
- A frame-by-frame log of `drawable.rasterizationRateMaps`, the views'
  viewports and tangents, to see whether the compositor changes them with the dial.
- The sample project "Interacting with virtual content blended with passthrough"
  (Apple), if it can be downloaded: it is the only reference for render-context use.
- A Feedback report if a minimal Compositor Services app shows the same.


## Investigation on 2026-10-28

The downloaded Apple sample at
`~/Downloads/InteractingWithVirtualContentBlendedWithPassthrough` implements
**mixed and full**, not progressive immersion. Its unmodified renderer is not
an example of the drawable render-context API. The relevant current guide is
[Controlling Metal rendering immersion level](https://developer.apple.com/documentation/compositorservices/controlling-metal-rendering-immersion-level).

A separate Metal 3 probe was built from a scratch copy of that sample, installed
as `com.illixion.ProgressiveProbe`. It draws a constant blue fullscreen triangle
through the system stencil, with valid reverse-Z depth, then calls the render
context's `endEncoding`. This removes both game engines and Metal 4 from the
reproduction. Device: AVP running visionOS 27.2.

Observed controls and results:

- Full style: blue visible on the headset; all 4,063,232 left-eye stencil bytes
  equal 1. Center RGBA readback approximately `(0.1, 0.5, 0.8, 1)`.
- Progressive style: black/binary Crown behavior; all left-eye stencil bytes
  equal 0 after the system finishing pass, and center RGBA is transparent black.
- Tracking is running, device anchors are present, and frames advance normally.
- `onImmersionChange` **on the CompositorContent**, rather than a window, receives
  fractional Crown amounts. The earlier window-scene log of 1.0 did not measure
  the immersive scene.
- Disabling foveation does not fix it. Neither does an explicit 0.1...1 range,
  initial amount 0.5 and mutable style binding, nor a finite 1000 m far plane
  (the default far plane is infinity).
- Drawing blue with stencil comparison `always` still results in transparent
  black after the system finishing pass. This is not merely a bad application
  stencil comparison.
- Omitting the system finishing pass is rejected at presentation: "need to end
  encoding on drawable render context when supporting progressive style".
- No shader compilation or command-buffer GPU errors were reported.

The owner then isolated **Mac Virtual Display** as the trigger: after restarting
the headset the probe worked, reconnecting Mac Virtual Display broke it again,
and disconnecting followed by reopening the immersive space restored it. The
working probe's stencil contains both 0 and 1 and changes with the Crown. Finally,
the owner confirmed normal Crown resizing in the original LambdaVision renderer
with Mac Virtual Display disconnected. No renderer changes are required for this
workaround. Keep the toggle experimental until broader device/OS testing.

The source-only probe is saved locally as `build/ProgressiveImmersionProbe.zip`
(no signing configuration); its working directory is
`/tmp/ProgressiveImmersionProbe`. It has Full/Progressive buttons and logs
immersion amounts, anchor presence, stencil counts, and center color readback.
The final probe starts full for the control; LambdaVision's successful test opens
directly progressive, so starting full is not required by the verified workaround.

An attempted Metal 3 final pass on LambdaVision's Metal 4 layer built, but aborted
on the headset. That experiment was reverted; Metal 3 alone also reproduced the
progressive failure, so migrating the game renderer is not justified by the
evidence. The experiment patch is `/tmp/lambda-metal3-portal-experiment.patch`.

### Crash investigation caveat

`build/device-console.log` captured SIGABRT (signal 6), followed by seven
"no debug info" messages and exit 134. Xash installs its own SIGABRT handler
(`engine/platform/posix/crash_posix.c`), which prevents this output from being a
useful native Apple crash report. The engine's `-noch` argument disables that
handler for a future native crash-report reproduction. Do not confuse the
simulator probe's separate `CPImmersiveScene layer` configuration abort with this
headset abort.

The simulator probe initially failed layer creation with configuration error -7.
Its advertised context stencil format is combined depth32Float/stencil8, unlike
the headset's standalone stencil8 support. Using the combined format for both
the drawable depth and stencil attachments let the Metal 3 probe run in Simulator.
The simulator run alone does not validate physical Crown/portal behavior.
