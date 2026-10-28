# Feedback Assistant report: nested depth-stencil texture views misaddress the stencil plane

## Title

Metal: depth32Float_stencil8 view of a view of a 2D-array texture writes stencil to the wrong slice and corrupts another slice's depth

## Area

Metal, Graphics & Games

## Type

Incorrect/Unexpected Behavior

## Description

When a `depth32Float_stencil8` 2D-array texture is viewed twice, root R, then a 2D slice view V1 of slice N, then a view V2 of V1 (same format, 2D, level 0, slice 0), the stencil plane of V2 is addressed incorrectly when V2 is used as a depth-stencil attachment or as a multisample resolve target.

- Depth writes land correctly in slice N of R.
- Stencil writes for slice 1 land in slice 0's stencil plane, and slice 1's stencil plane is left untouched.
- Stencil writes for slice 0 do not land in slice 0's stencil plane either, and overrun part of slice 1's depth plane (blocky near-white garbage: depth values {0.5 x 49152, 0 x 12288, 1.14e-28 x 4096} with stencil 96 x 2048 in a 256x256 slice).
- Reading back through V2 itself returns the correct data, because the read uses the same wrong address. A producer that verifies its own output sees nothing wrong. Any consumer that reads through the root texture, or a view made from it, sees stale or foreign data.

One level of view (V1 alone) is correct. `depth32Float` and `rgba8Unorm` nested the same way are correct. The failure is the same at 1 sample (plain render pass, no resolve) and at 4 samples with `multisampleResolve`.

Real-world impact: a Metal-backed graphics library imports a client `MTLTexture` as an EGLImage, attaches it as a GL texture (`EXT_multisampled_render_to_texture`), and builds its level-0 image as a view of the imported texture. The application hands it per-eye slice views of a depth-stencil array, so the nested view is exactly this case. Stencil marks written by the rendering engine vanish and the other eye's depth turns into a grid of near-white blocks. The same symptoms were seen on Apple Vision Pro (M5, visionOS 27; exact build number not recorded). The attached program reproduces the issue headless on a Mac.

## Steps to Reproduce

1. Save the attached `repro.swift` and run: `swiftc -O repro.swift -o repro && ./repro`
2. The program creates a 256x256, 2-slice `depth32Float_stencil8` 2D-array texture R (private storage, usage renderTarget | shaderRead | pixelFormatView) and clears both slices through R (depth 0.5, stencil 3).
3. It draws a full-screen triangle (depth 0.25, stencil replace with reference 17) into either V1 (a direct slice view of R) or V2 (a view of V1), at 1 sample, and at 4 samples with `multisampleResolve` into the view.
4. It blits both slices of R back and counts pixels that differ from the expected values. Expected: the drawn slice holds depth 0.25 and stencil 17, the other slice is unchanged.
5. Exit status is 1 when any configuration is wrong.

The relevant API calls are only:

```swift
let v1 = root.makeTextureView(pixelFormat: .depth32Float_stencil8, textureType: .type2D, levels: 0..<1, slices: n..<(n+1))!
let v2 = v1.makeTextureView(pixelFormat: .depth32Float_stencil8, textureType: .type2D, levels: 0..<1, slices: 0..<1)!
// render with v2 as depthAttachment.texture and stencilAttachment.texture
```

## Expected Results

Rendering into a view of a view addresses the same texels as rendering into the equivalent view made directly from the root. Slice N of the root receives depth 0.25 and stencil 17, and no other plane or slice changes.

## Actual Results

Real output of the attached program (below), run on the machine listed under Configuration:

```
device: Apple M2 Max   ProcessInfo: Version 27.0.1 (Build 26A434)
--- headline: depth32Float_stencil8 2D array, 1 sample, plain render pass (no MSAA, no resolve)
[PASS] direct slice view V1, slice 0, 1 sample              all planes of both slices as expected
[PASS] direct slice view V1, slice 1, 1 sample              all planes of both slices as expected
[FAIL] NESTED view V2 of V1, slice 0, 1 sample              stencil slice0: 65536/65536 px wrong; depth slice1: 16384/65536 px wrong; stencil slice1: 2048/65536 px wrong
       (stencil read back through the written view: correct)
[FAIL] NESTED view V2 of V1, slice 1, 1 sample              stencil slice0: 65536/65536 px wrong; stencil slice1: 65536/65536 px wrong
       (stencil read back through the written view: correct)
--- 4x multisample render, resolve into the view
[PASS] direct slice view V1, slice 0, 4x resolve            all planes of both slices as expected
[PASS] direct slice view V1, slice 1, 4x resolve            all planes of both slices as expected
[FAIL] NESTED view V2 of V1, slice 0, 4x resolve            stencil slice0: 65536/65536 px wrong; depth slice1: 16384/65536 px wrong; stencil slice1: 2048/65536 px wrong
       (stencil read back through the written view: correct)
[FAIL] NESTED view V2 of V1, slice 1, 4x resolve            stencil slice0: 65536/65536 px wrong; stencil slice1: 65536/65536 px wrong
       (stencil read back through the written view: correct)
--- controls: nested views of other formats
[PASS] depth32Float only, NESTED, slice 1, 1 sample(s)      all planes of both slices as expected
[PASS] rgba8Unorm colour, NESTED, slice 1, 1 sample(s)      all planes of both slices as expected
[PASS] depth32Float only, NESTED, slice 1, 4 sample(s)      all planes of both slices as expected
[PASS] rgba8Unorm colour, NESTED, slice 1, 4 sample(s)      all planes of both slices as expected

RESULT: FAIL - at least one configuration produced wrong data
```

Summary of what the run shows (all rows measured by `repro.swift` on the Mac below; the Vision Pro was not re-run with this program):

| View configuration | Samples | Result |
|---|---|---|
| `depth32Float_stencil8`, direct slice view of root (slice 0 and 1) | 1 and 4 (resolve) | OK |
| `depth32Float_stencil8`, view of a slice view (slice 0) | 1 and 4 (resolve) | BAD: stencil never reaches slice 0; slice 1 depth partly overwritten (16384 px) and slice 1 stencil (2048 px) |
| `depth32Float_stencil8`, view of a slice view (slice 1) | 1 and 4 (resolve) | BAD: stencil lands in slice 0, slice 1 stencil untouched; depth is correct |
| `depth32Float`, view of a slice view (slice 1) | 1 and 4 (resolve) | OK |
| `rgba8Unorm`, view of a slice view (slice 1) | 1 and 4 (resolve) | OK |

The nested-view stencil plane reads back as correct through the nested view itself, so the producer's own verification passes.

Metal validation: running the same binary with `METAL_DEVICE_WRAPPER_TYPE=1` alone, and with `METAL_DEVICE_WRAPPER_TYPE=1 MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER=1`, gives identical PASS/FAIL results and identical mismatch counts and the same exit status 1. The API and shader validation layers print no warning or error about the nested view. (The only extra output is the "Metal API Validation Enabled" banner lines.) The nested view is therefore accepted as valid but misaddressed.

## Configuration

- Reproduced locally (every table row above): Mac14,6, Apple M2 Max, `sw_vers` reports macOS 27.0.1 (build 26A434), Xcode 27.1 (build 27A9275), Apple Swift 6.4 (swiftlang-6.4.0.34.1), target arm64-apple-macosx27.0.0.
- Seen in a real app, not re-run with the attached program: Apple Vision Pro with an M5 chip, visionOS 27 (exact build number not recorded). Only the symptoms were observed there (stencil marks missing, other eye's depth corrupted). The M2 Max earlier showed the same pattern, on macOS 26 as the developer recalled; the macOS 27.0.1 above is what `sw_vers` reports today and is what the attached output comes from.
- Not tested: other GPU families, other depth-stencil formats (`depth24Unorm_stencil8`, `stencil8`), array lengths other than 2, or mip levels above 0. This report does not claim the bug is specific to, or absent from, any GPU family beyond the two devices named.

## Workaround

Create each per-slice view directly from the root texture, never from another view (or use `depthAttachment.slice` / `resolveSlice` on the pass descriptor). If a library wraps the texture you hand it in another view, pass the root texture handle instead or preserve that handle for level 0 of a one-level texture.

## Attachments

- `repro.swift`: single-file headless command-line repro, 137 lines, self-contained.
- `repro-output.txt`: real output of `./repro` (also pasted above), with validation off.
- `repro-output-validation.txt`: output with `METAL_DEVICE_WRAPPER_TYPE=1 MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER=1`.

## README: running the repro

```
swiftc -O repro.swift -o repro && ./repro
```

Headless (no window, no app bundle), needs only a Metal device. Exit status 0 means every configuration is correct, 1 means the bug appeared. With validation: `METAL_DEVICE_WRAPPER_TYPE=1 MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER=1 ./repro`. Do not run the validation variant expecting a diagnostic: none is emitted.
