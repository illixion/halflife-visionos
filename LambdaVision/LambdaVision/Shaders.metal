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

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);

    // Fullscreen-quad UV: vertex emits texCoord = pos*0.5+0.5 in Metal NDC.
    // ANGLE/GL writes the FBO with (0,0) at bottom-left and Metal samples
    // textures with (0,0) at bottom-left too, so no flip needed here.
    float2 uv = in.texCoord;
    half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);

    return float4(colorSample);
}
