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
    // Reverse-Z depth (drawable clear=0, compare=greater): emit z=1 so the
    // fullscreen pass always wins the depth test.
    out.position = float4(pos, 1.0, 1.0);
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

    float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);

    return float4(colorSample);
}
