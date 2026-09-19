//
//  ArmShaders.metal
//  LambdaVision
//
//  Procedural wireframe hand+forearm skeleton: unlit world-space line
//  segments between ARKit hand-skeleton joints (see ArmPass.swift and
//  Renderer.armSkeletonVertices). No model matrix — vertex positions arrive
//  already in Apple world space; per-vertex colour distinguishes the hands.
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

struct ArmVertex
{
    float3 position [[attribute(VertexAttributePosition)]];
    float4 color    [[attribute(VertexAttributeColor)]];
};

struct ArmInOut
{
    float4 position [[position]];
    float4 color;
};

vertex ArmInOut armVertexShader(ArmVertex in [[stage_in]],
                                ushort amp_id [[amplification_id]],
                                constant ViewProjectionArray & vp [[ buffer(BufferIndexViewProjection) ]])
{
    ArmInOut out;
    out.position = vp.viewProjectionMatrix[amp_id] * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 armFragmentShader(ArmInOut in [[stage_in]])
{
    return in.color;
}
