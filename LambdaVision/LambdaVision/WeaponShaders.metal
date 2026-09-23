//
//  WeaponShaders.metal
//  LambdaVision
//
//  Renders the skinned weapon viewmodel (baked from the GoldSrc .mdl by
//  Lambda_WeaponModel.c, posed per frame through a bone palette) as a second
//  pass over the engine image, hand-anchored and lit by a single
//  ambient+directional probe sampled from the game world.
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

struct WeaponVertex
{
    float3 position [[attribute(VertexAttributePosition)]];   // bone-local
    float3 normal   [[attribute(VertexAttributeNormal)]];     // bone-local
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
    uint   bone     [[attribute(VertexAttributeBoneIndex)]];
};

struct WeaponInOut
{
    float4 position [[position]];
    float3 normal;
    float2 texCoord;
    float3 worldPos;
    ushort eye;
};

vertex WeaponInOut weaponVertexShader(WeaponVertex in [[stage_in]],
                                      ushort amp_id [[amplification_id]],
                                      constant WeaponUniforms & u [[ buffer(BufferIndexUniforms) ]],
                                      constant ViewProjectionArray & vp [[ buffer(BufferIndexViewProjection) ]],
                                      constant WeaponBonePalette & pal [[ buffer(BufferIndexBones) ]])
{
    WeaponInOut out;
    // GoldSrc skinning is rigid single-bone: bone-local → model space via
    // the palette, then model → world via the hand-anchor transform.
    float4x4 m = u.modelMatrix * pal.bones[min(in.bone, uint(WEAPON_MAX_BONES - 1))];
    float4 world = m * float4(in.position, 1.0);
    out.position = vp.viewProjectionMatrix[amp_id] * world;
    out.worldPos = world.xyz;
    // Both factors are rotation (+ uniform scale in modelMatrix), so the
    // upper 3x3 rotates normals correctly (no inverse-transpose needed).
    out.normal = (m * float4(in.normal, 0.0)).xyz;
    out.eye = amp_id;

    if (u.renderFlags.y > 0.5) {
        // STUDIO_NF_CHROME: the .mdl stores NO usable texcoords on a chrome
        // mesh — every vertex carries the same (s,t), so sampling them gives
        // one flat texel (a black corner of the sphere map, which is why the
        // .357 read as a black silhouette). GoldSrc synthesises the coords
        // instead: build a basis from the viewer→surface vector and the
        // camera's right axis, then project the normal onto it
        // (R_StudioSetupChrome, engine ref/gl/gl_studio.c). The engine uses
        // the owning bone's origin for the view vector; per-vertex position
        // is the same construction, just smoother across a large mesh.
        float3 toSurface = normalize(world.xyz - u.eyePos[amp_id].xyz);
        float3 chromeUp    = normalize(cross(toSurface, u.eyeRight[amp_id].xyz));
        float3 chromeRight = normalize(cross(toSurface, chromeUp));
        float3 n = normalize(out.normal);
        out.texCoord = float2(dot(n, chromeRight), dot(n, chromeUp)) * 0.5 + 0.5;
    } else {
        out.texCoord = in.texCoord;
    }
    return out;
}

fragment float4 weaponFragmentShader(WeaponInOut in [[stage_in]],
                                     constant WeaponUniforms & u [[ buffer(BufferIndexUniforms) ]],
                                     texture2d<float> tex [[ texture(TextureIndexColor) ]])
{
    // Chrome coords are generated in [0,1] and must not wrap at the seam.
    constexpr sampler repeatS(mag_filter::linear, min_filter::linear,
                              mip_filter::linear, address::repeat);
    constexpr sampler clampS(mag_filter::linear, min_filter::linear,
                             mip_filter::linear, address::clamp_to_edge);
    bool chrome = u.renderFlags.y > 0.5;
    float4 c = chrome ? tex.sample(clampS, in.texCoord)
                      : tex.sample(repeatS, in.texCoord);

    // Masked textures (STUDIO_NF_MASKED) use alpha as a 1-bit cutout.
    if (u.renderFlags.x > 0.5 && c.a < 0.5)
        discard_fragment();

    // Near clip (the player body): nothing closer to this eye than the
    // radius is drawn, so the camera never shows a surface sliced open by
    // the near plane or a collar a centimetre from the lens.
    if (u.renderFlags.z > 0.0 && distance(in.worldPos, u.eyePos[in.eye].xyz) < u.renderFlags.z)
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

// ---- Screen fade over the gun and body ------------------------------------
// The engine fades its own image (world) before the weapon pass runs, so the
// gun and body drawn here would stay bright through a fade to black. A
// full-view triangle, depth-tested against this pass's own depth so it lands
// only where the gun or body drew, lays the same fade over them. Colour from
// RingUniforms.color: the fade's rgb and alpha for a blended fade, or the
// modulating colour (alpha 1) for FFADE_MODULATE, which a second pipeline
// multiplies in.

vertex RingInOut fadeVertexShader(uint vid [[vertex_id]],
                                  constant RingUniforms & r [[ buffer(BufferIndexUniforms) ]])
{
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;   // covers the view
    RingInOut out;
    out.position = float4(p, 0.0, 1.0);   // the depth clear value (see fadeDepthState)
    out.color = r.color;
    return out;
}
