# Feedback Assistant report: Mac Virtual Display breaks progressive immersion

## Title

visionOS: progressive immersion render-context mask stops working after connecting Mac Virtual Display

## Area

VisionOS, Compositor Services / Graphics & Games

## Type

Incorrect or Unexpected Behavior

## Description

Connecting Mac Virtual Display while a Compositor Services immersive app is in
use causes its progressive-immersion portal to stop tracking the Digital Crown.
The portal may become black or appear at a fixed size. The app continues to
receive fractional immersion changes, but the compositor's stencil mask becomes
empty and the virtual content is not displayed correctly.

Disconnecting Mac Virtual Display does not repair an already-open immersive
space. Closing and reopening the space restores progressive immersion. A headset
restart also restored it during investigation, but is not required when using
the disconnect-and-reopen workaround.

The behavior was reproduced in a minimal Metal 3 Compositor Services probe and
in a second Compositor Services app using a Metal 4 command queue. After Mac
Virtual Display was disconnected and its immersive space reopened, that app's
original renderer resized normally. This points to an interaction with the system compositor rather
than a renderer-specific failure.

## Steps to Reproduce

1. Use Apple Vision Pro with a Compositor Services app that supports
   `.progressive` immersion and uses a drawable render context. For example, the
   attached probe renders a blue field through the compositor's stencil mask.
2. Open the app's immersive space in progressive mode. Rotate the Digital Crown
   and verify that the portal resizes.
3. Connect Mac Virtual Display.
4. Rotate the Digital Crown again.
5. Observe that the portal becomes black, fixed-size, or otherwise stops
   following the Crown. In the probe, the rendered image is black and the
   compositor stencil readback contains only zero values.
6. Disconnect Mac Virtual Display. The already-open space remains broken.
7. Close and reopen the immersive space, then rotate the Crown. Progressive
   immersion works again.

The same failure occurred in an app using a Metal 4 command queue and the
drawable render-context API. After disconnecting Mac Virtual Display and
reopening its immersive space, the app's original renderer resized the portal
normally.

## Expected Results

Connecting Mac Virtual Display should not disable progressive immersion. The
compositor should continue to update the portal mask and edge effects as the
Digital Crown changes the immersion amount.

## Actual Results

After connecting Mac Virtual Display, the portal stops tracking the Crown and
may become black or binary. The `onImmersionChange` callback on the
`CompositorContent` continues to report fractional immersion amounts while the
probe's stencil readback contains only zeros. Disconnecting Mac Virtual Display
and reopening the immersive space restores the expected behavior.

## Configuration

- Device: Apple Vision Pro, visionOS 27.2.
- Mac Virtual Display: connected during failure; disconnecting and reopening
  the immersive space restores the feature.
- Mac host used for the investigation: macOS 27.0.1 (26A434).
- Reproduced in a standalone Metal 3 Compositor Services probe and in an app
  using a Metal 4 command queue. The probe showed the failure again after Mac
  Virtual Display was reconnected.

## Workaround

Disconnect Mac Virtual Display, then close and reopen the affected immersive
space. A renderer change or headset restart is not needed for this recovery.

## Attachments

The source-only probe archive contains a copy of Apple's Compositor Services
sample, a blue scene rendered through the progressive mask, and logging for
immersion amounts, device-anchor availability, stencil values, and a color
readback. It omits signing credentials.

This is a draft for review; it has not been submitted through Feedback Assistant.
