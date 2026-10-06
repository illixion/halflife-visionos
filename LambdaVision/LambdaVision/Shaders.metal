//
//  Shaders.metal
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
    ushort eye;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant ViewProjectionArray & viewProjectionArray [[ buffer(BufferIndexViewProjection) ]])
{
    ColorInOut out;
    float4 position = float4(in.position, 1.0);
    out.position = viewProjectionArray.viewProjectionMatrix[amp_id] * uniforms.modelMatrix * position;
    out.texCoord = in.texCoord;
    out.eye = amp_id;
    return out;
}

// Fullscreen-triangle. 3 verts, no buffers. Each eye's render already
// matches that eye's AVP frustum, so plastering it across the viewport is
// the geometrically-correct display path.
vertex ColorInOut fullscreenVertexShader(uint vid [[vertex_id]],
                                         ushort amp_id [[amplification_id]])
{
    ColorInOut out;
    float2 pos = float2((vid == 1) ? 3.0 : -1.0,
                        (vid == 2) ? 3.0 : -1.0);
    // Reverse-Z depth (drawable clear=0, compare=greater). The compositor
    // uses the drawable's depth buffer for positional reprojection: z=1
    // (near plane) tells it the whole image sits millimeters from the
    // viewer's face, so every head translation produces a huge corrective
    // warp — visible as pulsating/jelly. Emit a small value (≈far) instead;
    // TODO: resolve the engine's real per-pixel depth for exact reprojection.
    out.position = float4(pos, 0.0001, 1.0);
    out.texCoord = pos * 0.5 + 0.5;
    out.eye = amp_id;
    return out;
}

// FXAA (compact quality variant, Lottes). The engine has no AA of its own
// (GL MSAA through ANGLE costs ~7 ms/pair) and the composite pass bilinearly
// upsamples a sub-logical engine render, so edges stairstep twice over.
//
// The kernel lives here as an inline helper with two entry points:
//   • fragmentShaderFXAA — the DEFAULT path. Runs inside the composite pass,
//     so edge smoothing costs zero extra passes and zero intermediate
//     textures (only the neighbourhood taps).
//   • fxaaFragmentShader — the standalone pass that feeds the (currently
//     hidden) MetalFX upscale chain. Kept compiled; see Renderer.
//
// Every tap is a symmetric pair about `uv`, so the filter is invariant under
// a vertical mirror of the sample space: the two entry points may disagree
// on the V flip and still produce identical output.
static inline half fxaaLuma(half3 c)
{
    return dot(c, half3(0.299h, 0.587h, 0.114h));
}

// `px` must be ONE TEXEL of the sampled texture (engine resolution when the
// raw colorMap is bound), never a drawable-resolution pixel — the edges being
// smoothed are engine-raster edges.
static inline half3 fxaaResolve(texture2d_array<half> tex, sampler s,
                                float2 uv, float2 px, ushort eye,
                                half3 rgbM)
{
    half lM  = fxaaLuma(rgbM);
    half lNW = fxaaLuma(tex.sample(s, uv + float2(-px.x, -px.y), eye).rgb);
    half lNE = fxaaLuma(tex.sample(s, uv + float2( px.x, -px.y), eye).rgb);
    half lSW = fxaaLuma(tex.sample(s, uv + float2(-px.x,  px.y), eye).rgb);
    half lSE = fxaaLuma(tex.sample(s, uv + float2( px.x,  px.y), eye).rgb);

    half lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    half lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));

    // Early out on low local contrast (flat area — nothing to smooth). Most
    // pixels take this branch, which is what keeps the folded cost low.
    if (lMax - lMin < max(0.0312h, lMax * 0.125h))
        return rgbM;

    float2 dir = float2(-float((lNW + lNE) - (lSW + lSE)),
                         float((lNW + lSW) - (lNE + lSE)));
    float dirReduce = max(float(lNW + lNE + lSW + lSE) * 0.25 * 0.125, 1.0 / 128.0);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, -8.0, 8.0) * px;

    half3 rgbA = 0.5h * (tex.sample(s, uv + dir * (1.0 / 3.0 - 0.5), eye).rgb
                       + tex.sample(s, uv + dir * (2.0 / 3.0 - 0.5), eye).rgb);
    half3 rgbB = rgbA * 0.5h + 0.25h * (tex.sample(s, uv + dir * -0.5, eye).rgb
                                      + tex.sample(s, uv + dir *  0.5, eye).rgb);
    half lB = fxaaLuma(rgbB);
    return (lB < lMin || lB > lMax) ? rgbA : rgbB;
}

fragment float4 fxaaFragmentShader(ColorInOut in [[stage_in]],
                                   texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    // Flip V: the fullscreen-triangle texCoord carries one implicit
    // vertical flip (GL bottom-up FBO vs Metal top-down render target),
    // which the display pass already accounts for. Without this flip the
    // FXAA pass would apply it a second time, writing fxaaMap upside down.
    // Flipping here keeps fxaaMap in colorMap's orientation so the display
    // shader works identically with either texture.
    const float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    const float2 px = float2(1.0 / colorMap.get_width(), 1.0 / colorMap.get_height());
    half3 rgbM = colorMap.sample(s, uv, in.eye).rgb;
    return float4(float3(fxaaResolve(colorMap, s, uv, px, in.eye, rgbM)), 1.0);
}

// Output dither for the composite. The engine image is 16-bit, so a
// dark gradient arrives smooth; the drawable is what rounds it, and at
// 8 bits a dim vent spans a handful of codes that read as flat splotches.
// Half a code of fixed per-pixel noise before that rounding turns the
// steps into grain far finer than a pixel. The noise is added in the
// drawable's STORED encoding (an _srgb drawable quantizes after the
// hardware encode), and scaled to its code size; a float drawable needs
// none. Set per pipeline from the layer's colour format (Renderer).
// Optional: fragmentShader is also the template pipeline's fragment
// function (buildRenderPipeline), specialized there with no values, which
// must compile to no dither. Any function using these must still be made
// with makeFunction(name:constantValues:) — plain makeFunction(name:) fails
// pipeline validation (crashed at launch).
constant bool  kOutputSRGBValue [[function_constant(20)]];
constant float kOutputLSBValue  [[function_constant(21)]]; // one stored code; 0 = no dither
constant bool  kOutputSRGB = is_function_constant_defined(kOutputSRGBValue) && kOutputSRGBValue;
constant float kOutputLSB  = is_function_constant_defined(kOutputLSBValue) ? kOutputLSBValue : 0.0;

static inline float3 srgbEncode(float3 c)
{
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static inline float3 srgbDecode(float3 c)
{
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static inline float3 ditherOutput(float3 c, float2 pixel)
{
    if (kOutputLSB <= 0.0)
        return c;
    // interleaved gradient noise (Jimenez 2014): fixed per physical pixel,
    // so it cannot shimmer between frames or between the two eyes' passes
    const float n = fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715)))) - 0.5;
    c = max(c, 0.0);
    if (kOutputSRGB)
        return srgbDecode(max(srgbEncode(c) + n * kOutputLSB, 0.0));
    return max(c + n * kOutputLSB, 0.0);
}

// HDR headroom test (Settings → Diagnostics). No SDK API reports how far
// above SDR white (1.0) the display goes; Oneiros measured about one stop
// (0.5 < 1 < 2, and 2 = 4 = 8) with large grey bands, which an OLED may
// dim as a whole by area (its brightness limiter). So two layouts over
// black, each a row of test values over a row of 1.0 references:
//   1  small dots — a point light's area, the case highlights will be
//   2  patches filling the view — the worst case for the limiter
// Values left to right: 0.5 1 1.25 1.5 1.75 2 2.5 3 4. Written raw, past
// the decode and the dither, so the drawable receives exactly these.
constant float kHDRTestValues[9] = { 0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0 };

static inline float3 hdrTestPattern(float2 uv, float mode, float aspect)
{
    const int n = 9;
    if (mode > 1.5) {
        const int i = clamp(int(uv.x * n), 0, n - 1);
        // a thin black gap between patches keeps them tellable apart
        const float f = fract(uv.x * n);
        if (f < 0.04 || f > 0.96 || abs(uv.y - 0.5) < 0.01)
            return 0.0;
        return uv.y > 0.5 ? kHDRTestValues[i] : 1.0;
    }
    const float spacing = 0.06;                     // centre to centre, view widths
    const float radius = 0.012;                     // view heights: ~1.2° on the AVP
    const float x0 = 0.5 - spacing * (n - 1) * 0.5;
    const int i = clamp(int(round((uv.x - x0) / spacing)), 0, n - 1);
    const float2 d = float2((uv.x - (x0 + spacing * i)) * aspect, 0.0);
    const float dTop = length(d + float2(0.0, uv.y - 0.54));
    const float dRef = length(d + float2(0.0, uv.y - 0.46));
    if (dTop < radius) return kHDRTestValues[i];
    if (dRef < radius) return 1.0;
    return 0.0;
}

// ---- Glass (modern lighting tier 1; Renderer.glassReflections) -----------
// The engine marks glass in the stencil aspect of the depth texture we gave
// it (r_vrglass, ref/gl gl_rsurf.c R_VRGlass*): 16 + the surface's eye-space
// normal, x and y quantised to 15 steps each, facing the viewer. Glass in
// GoldSrc writes no depth, so the normal has to come from there rather than
// from the depth buffer, which holds whatever is behind the pane.
//
// The reflection is Schlick's Fresnel over a "distant environment" made of
// the frame itself: the reflected ray, taken as a direction, is projected
// back into this eye's frustum and the engine image sampled there. Looking
// along a glass wall that shows the corridor ahead — the case where real
// glass reflects most; facing a pane head-on the ray points behind the eye,
// F is 4%, and the ambient colour stands in. One stencil read per pixel and
// one extra colour sample on glass only; no extra pass.
constant bool kGlassValue [[function_constant(22)]];
constant bool kGlass = is_function_constant_defined(kGlassValue) && kGlassValue;

static inline float3 glassShade(float3 rgb, float2 uv, ushort eye,
                                texture2d_array<half> colorMap, sampler s,
                                texture2d_array<uint> engineStencil,
                                constant DisplayParams &p)
{
    const uint2 size = uint2(engineStencil.get_width(), engineStencil.get_height());
    const uint code = engineStencil.read(min(uint2(uv * float2(size)), size - 1), eye).r;
    if (code < 16 || code > 240)
        return rgb;
    const uint i = code - 16;
    const float2 nxy = float2(float(i / 15), float(i % 15)) / 7.0 - 1.0;
    const float3 n = normalize(float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy)))));
    // GL eye space: x right, y up, the eye looking down −z; uv.y = 0 is the
    // bottom row (the engine image is bottom-up, sampled unflipped).
    const float4 t = p.eyeTangents[eye];   // left, right, top, bottom
    const float3 v = normalize(float3(mix(-t.x, t.y, uv.x), mix(-t.w, t.z, uv.y), -1.0));
    const float cosTheta = saturate(dot(-v, n));
    const float F = p.glass.y + (1.0 - p.glass.y) * pow(1.0 - cosTheta, 5.0);
    const float3 r = reflect(v, n);
    float3 env = p.glassAmbient.rgb;
    if (r.z < -0.05) {
        const float2 tanR = r.xy / -r.z;
        const float2 ruv = float2((tanR.x + t.x) / (t.x + t.y), (tanR.y + t.w) / (t.z + t.w));
        const float2 edge = min(ruv, 1.0 - ruv);
        // fade out toward the frame's edges and as the ray turns sideways
        const float w = saturate(min(edge.x, edge.y) * 8.0) * saturate((-r.z - 0.05) * 4.0);
        if (w > 0.0)
            env = mix(env, float3(colorMap.sample(s, saturate(ruv), eye).rgb), w);
    }
    return mix(rgb, env, min(F * p.glass.x, p.glass.z));
}

static inline float4 displayOutput(float3 rgb, float alpha, float2 uv, float2 pixel,
                                   constant DisplayParams &p)
{
    if (p.hdrTest > 0.5)
        return float4(hdrTestPattern(uv, p.hdrTest, p.aspect), 1.0);
    return float4(ditherOutput(displayLinearize(rgb, p.decodeGamma), pixel), alpha);
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                               texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                               texture2d_array<uint> engineStencil [[ texture(2) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::clamp_to_edge);

    // Fullscreen-quad UV: vertex emits texCoord = pos*0.5+0.5 in Metal NDC.
    // ANGLE/GL writes the FBO with (0,0) at bottom-left and Metal samples
    // textures with (0,0) at bottom-left too, so no flip needed here.
    // The texture is the MetalFX-upscaled displayMap (full logical
    // resolution, already edge-reconstructed and sharpened), or the raw
    // engine colorMap when MetalFX is unavailable.
    float2 uv = in.texCoord;
    half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(colorSample.rgb);
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, colorMap, colorSampler, engineStencil, params);

    return displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
}

// Composite pass with FXAA folded in (Renderer.compositeFXAA, default on).
// Identical to fragmentShader apart from resolving rgb through the FXAA
// kernel at the SAMPLED texture's texel size; alpha still comes straight
// from the centre tap so the drawable's alpha behaviour is unchanged.
fragment float4 fragmentShaderFXAA(ColorInOut in [[stage_in]],
                                   constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                                   texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                                   texture2d_array<uint> engineStencil [[ texture(2) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::clamp_to_edge);

    // Same un-flipped UV convention as fragmentShader (see the note there).
    float2 uv = in.texCoord;
    const float2 px = float2(1.0 / colorMap.get_width(), 1.0 / colorMap.get_height());
    half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(fxaaResolve(colorMap, colorSampler, uv, px, in.eye, colorSample.rgb));
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, colorMap, colorSampler, engineStencil, params);
    return displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
}

// ---- Per-pixel reprojection depth (Renderer.reprojectionDepth) ------------
// The compositor re-warps each frame from the pose it was drawn at to the
// pose at display time, using the drawable's depth for the positional part.
// The constant far depth (fullscreenVertexShader) makes that a pure rotation:
// right for distant walls, wrong for anything near when the head moves. These
// variants give every pixel the engine's own depth instead, converted from
// its GL window depth (standard Z, the projection Lambda_Bridge.c builds from
// the same frustum tangents, near/far in DisplayParams.engineClip) to the
// distance along the eye's forward axis and back through the compositor's
// projection, so both name the same point in the room.
//
// Kept inside the layer's depth range: exactly 0 (the far plane) displayed
// pure black on device in Oneiros, so sky, empty texels and anything past the
// compositor's far plane get depthLimits.x, the old constant. A pixel the
// engine puts nearer than depthLimits.z is its own flat viewmodel (the stock
// one is squeezed into the front 30% of the depth range, so it decodes a few
// centimetres from the eye) and gets the far depth too, as it always had: a
// head-locked image has no right depth, and the near one would warp it hard.
struct CompositeDepthOut
{
    float4 color [[color(0)]];
    float  depth [[depth(any)]];
};

static inline float compositorDepth(depth2d_array<float> engineDepth, float2 uv, ushort eye,
                                    constant DisplayParams &p)
{
    const uint2 size = uint2(engineDepth.get_width(), engineDepth.get_height());
    const uint2 texel = min(uint2(uv * float2(size)), size - 1);
    const float ndc = engineDepth.read(texel, eye) * 2.0 - 1.0;
    const float distance = p.engineClip.x / (p.engineClip.y - ndc * p.engineClip.z);
    if (distance < p.depthLimits.z)
        return p.depthLimits.x;
    const float4 P = p.depthProjection[eye];
    const float z = -distance;
    const float depth = (P.x * z + P.y) / (P.z * z + P.w);
    return clamp(depth, p.depthLimits.x, p.depthLimits.y);
}

fragment CompositeDepthOut fragmentShaderDepth(ColorInOut in [[stage_in]],
                                               constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                                               texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                                               depth2d_array<float> engineDepth [[ texture(1) ]],
                                               texture2d_array<uint> engineStencil [[ texture(2) ]])
{
    constexpr sampler colorSampler(mip_filter::linear, mag_filter::linear,
                                   min_filter::linear, address::clamp_to_edge);
    const float2 uv = in.texCoord;
    const half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(colorSample.rgb);
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, colorMap, colorSampler, engineStencil, params);
    CompositeDepthOut out;
    out.color = displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
    out.depth = compositorDepth(engineDepth, uv, in.eye, params);
    return out;
}

fragment CompositeDepthOut fragmentShaderFXAADepth(ColorInOut in [[stage_in]],
                                                   constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                                                   texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                                                   depth2d_array<float> engineDepth [[ texture(1) ]],
                                                   texture2d_array<uint> engineStencil [[ texture(2) ]])
{
    constexpr sampler colorSampler(mip_filter::linear, mag_filter::linear,
                                   min_filter::linear, address::clamp_to_edge);
    const float2 uv = in.texCoord;
    const float2 px = float2(1.0 / colorMap.get_width(), 1.0 / colorMap.get_height());
    const half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(fxaaResolve(colorMap, colorSampler, uv, px, in.eye, colorSample.rgb));
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, colorMap, colorSampler, engineStencil, params);
    CompositeDepthOut out;
    out.color = displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
    out.depth = compositorDepth(engineDepth, uv, in.eye, params);
    return out;
}

// The gun and body draw over the engine image with their own depth buffer
// (WeaponPass), so the drawable's depth still holds the engine's under them.
// This copies their depth over it wherever they drew: the drawable texel and
// the weapon depth texel are the same physical pixel (same size, same rate
// map), and both are the compositor's reverse-Z already. Untouched texels
// (the clear value, 0) keep the engine's depth.
struct DepthOnlyOut
{
    float depth [[depth(any)]];
};

fragment DepthOnlyOut reprojectionDepthMerge(ColorInOut in [[stage_in]],
                                             depth2d_array<float> overlayDepth [[ texture(0) ]])
{
    const float d = overlayDepth.read(uint2(in.position.xy), in.eye);
    if (d <= 0.0)
        discard_fragment();
    DepthOnlyOut out;
    out.depth = d;
    return out;
}
