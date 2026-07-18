//
//  WeaponShaders.metal
//  LambdaVision
//
//  Renders the bind-pose weapon mesh (baked from the GoldSrc .mdl by
//  Lambda_WeaponModel.c) as a second pass over the engine image, hand-anchored
//  and lit by a single ambient+directional probe sampled from the game world.
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

struct WeaponVertex
{
    float3 position [[attribute(VertexAttributePosition)]];
    float3 normal   [[attribute(VertexAttributeNormal)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
};

struct WeaponInOut
{
    float4 position [[position]];
    float3 normal;
    float2 texCoord;
    ushort eye;
};

vertex WeaponInOut weaponVertexShader(WeaponVertex in [[stage_in]],
                                      ushort amp_id [[amplification_id]],
                                      constant WeaponUniforms & u [[ buffer(BufferIndexUniforms) ]],
                                      constant ViewProjectionArray & vp [[ buffer(BufferIndexViewProjection) ]])
{
    WeaponInOut out;
    float4 world = u.modelMatrix * float4(in.position, 1.0);
    out.position = vp.viewProjectionMatrix[amp_id] * world;
    // modelMatrix is rotation + uniform scale, so the upper 3x3 rotates
    // normals correctly (no separate inverse-transpose needed).
    out.normal = (u.modelMatrix * float4(in.normal, 0.0)).xyz;
    out.texCoord = in.texCoord;
    out.eye = amp_id;
    return out;
}

fragment float4 weaponFragmentShader(WeaponInOut in [[stage_in]],
                                     constant WeaponUniforms & u [[ buffer(BufferIndexUniforms) ]],
                                     texture2d<float> tex [[ texture(TextureIndexColor) ]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        mip_filter::linear, address::repeat);
    float4 c = tex.sample(s, in.texCoord);

    // Masked textures (STUDIO_NF_MASKED) use alpha as a 1-bit cutout.
    if (u.ambient.w > 0.5 && c.a < 0.5)
        discard_fragment();

    float3 n = normalize(in.normal);
    float ndl = max(dot(n, normalize(u.lightDir.xyz)), 0.0);
    float3 lit = c.rgb * (u.ambient.rgb + u.lightColor.rgb * ndl);
    return float4(lit, 1.0);
}

// ---- UI arcs (reload ring, radial-menu sectors) ---------------------------
// Procedural arc billboard (triangle strip, no vertex buffer): vertex_id
// walks RING_SEGMENTS steps around the sweep, alternating inner/outer
// radius. startTurns/sweepTurns place the arc clockwise from 12 o'clock,
// so a progress ring "fills" by growing sweepTurns and a menu sector is a
// fixed wedge.

#define RING_SEGMENTS 48

struct RingInOut
{
    float4 position [[position]];
    float4 color;
};

vertex RingInOut ringVertexShader(uint vid [[vertex_id]],
                                  ushort amp_id [[amplification_id]],
                                  constant RingUniforms & r [[ buffer(BufferIndexUniforms) ]],
                                  constant ViewProjectionArray & vp [[ buffer(BufferIndexViewProjection) ]])
{
    uint  seg = vid >> 1;
    float t   = float(seg) / float(RING_SEGMENTS);
    float a   = M_PI_F * 0.5 - (r.startTurns + t * r.sweepTurns) * 2.0 * M_PI_F;
    float rad = (vid & 1) ? r.right.w : r.up.w;   // outer / inner
    float3 world = r.center.xyz
                 + (cos(a) * r.right.xyz + sin(a) * r.up.xyz) * rad;
    RingInOut out;
    out.position = vp.viewProjectionMatrix[amp_id] * float4(world, 1.0);
    out.color = r.color;
    return out;
}

fragment float4 ringFragmentShader(RingInOut in [[stage_in]])
{
    return in.color;
}
