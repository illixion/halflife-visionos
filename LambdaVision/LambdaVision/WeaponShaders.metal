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
