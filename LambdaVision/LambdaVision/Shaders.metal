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

// FXAA (compact quality variant, Lottes). Runs on the engine render BEFORE
// the MetalFX upscale so stairstep edges are smoothed rather than magnified.
// The engine has no AA of its own (GL MSAA through ANGLE costs ~7 ms/pair).
static inline half fxaaLuma(half3 c)
{
    return dot(c, half3(0.299h, 0.587h, 0.114h));
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
    half lM  = fxaaLuma(rgbM);
    half lNW = fxaaLuma(colorMap.sample(s, uv + float2(-px.x, -px.y), in.eye).rgb);
    half lNE = fxaaLuma(colorMap.sample(s, uv + float2( px.x, -px.y), in.eye).rgb);
    half lSW = fxaaLuma(colorMap.sample(s, uv + float2(-px.x,  px.y), in.eye).rgb);
    half lSE = fxaaLuma(colorMap.sample(s, uv + float2( px.x,  px.y), in.eye).rgb);

    half lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    half lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));

    // Early out on low local contrast (flat area — nothing to smooth).
    if (lMax - lMin < max(0.0312h, lMax * 0.125h))
        return float4(float3(rgbM), 1.0);

    float2 dir = float2(-float((lNW + lNE) - (lSW + lSE)),
                         float((lNW + lSW) - (lNE + lSE)));
    float dirReduce = max(float(lNW + lNE + lSW + lSE) * 0.25 * 0.125, 1.0 / 128.0);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, -8.0, 8.0) * px;

    half3 rgbA = 0.5h * (colorMap.sample(s, uv + dir * (1.0 / 3.0 - 0.5), in.eye).rgb
                       + colorMap.sample(s, uv + dir * (2.0 / 3.0 - 0.5), in.eye).rgb);
    half3 rgbB = rgbA * 0.5h + 0.25h * (colorMap.sample(s, uv + dir * -0.5, in.eye).rgb
                                      + colorMap.sample(s, uv + dir *  0.5, in.eye).rgb);
    half lB = fxaaLuma(rgbB);
    return float4(float3((lB < lMin || lB > lMax) ? rgbA : rgbB), 1.0);
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]])
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

    return float4(colorSample);
}
