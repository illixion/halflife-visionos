# Progressive immersion (experimental, not working yet)

Settings › Graphics › Immersion › "Progressive immersion (experimental)"
opens the game in a second immersive space (`AppModel.progressiveSpaceID`,
`.immersionStyle(... in: .progressive)`) whose layer is configured for the
compositor's drawable render context. Off by default, and it stays off until
the dial works. Oneiros parked the same feature for the same symptoms
(`~/Projects/Oneiros/KNOWN_ISSUES.md`, 2026-08-27).

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

## Not tried yet

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
