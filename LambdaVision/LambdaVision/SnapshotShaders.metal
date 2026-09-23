//
//  SnapshotShaders.metal
//  LambdaVision
//
//  Redraws the last engine frame before a level load from wherever the head
//  is now, so the world holds still in the room while the engine is busy
//  instead of the view freezing to the face.
//
//  Two draws per eye, both over a grid laid across the captured image:
//
//  - The backdrop puts every texel at infinity: turning the head is exact,
//    moving it shows no parallax. It fills whatever the mesh leaves open.
//  - The mesh lifts every grid point to where its depth says it was in the
//    world and projects it into the current view, so near walls slide
//    against far ones as the head moves. A triangle spanning a depth edge
//    (a door frame against the room behind) would stretch into a sheet
//    between the two; instead it is pushed back whole to its farthest
//    corner's depth, so the far side smears across the gap the near side
//    uncovers. The mesh alone covers the captured view; the backdrop only
//    shows past its edges. (Leaving torn triangles open over the backdrop
//    drew black outlines on the headset, never reproduced on the Mac.)
//
//  Shared with Tools/SnapshotProbe, which tunes it on dumps from the Mac
//  engine build, so it names no app state: everything arrives in
//  SnapshotUniforms.
//

#include <metal_stdlib>
#include <simd/simd.h>

#import "ShaderTypes.h"

using namespace metal;

struct SnapshotOut
{
    float4 position [[position]];
    float2 uv;          // captured texture coordinate
    ushort eye;
    float torn;         // 1 on a triangle that spans a depth edge
    float outside;      // how far past the captured frame (backdrop overscan)
};

// Grid point (cx, cy) of the captured image, as screen coordinates with y
// running down, and the texture coordinate that holds it.
static inline float2 snapshotScreen(uint2 cell, uint corner, uint2 grid)
{
    // Two triangles per cell: (0,0) (1,0) (0,1) and (1,0) (1,1) (0,1).
    const uint2 offsets[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1),
                               uint2(1, 0), uint2(1, 1), uint2(0, 1) };
    return float2(cell + offsets[corner]) / float2(grid);
}

static inline float2 snapshotUV(float2 screen, uint flipV)
{
    return float2(screen.x, flipV ? 1.0 - screen.y : screen.y);
}

// The captured depth under a screen point, as GL window depth (0 near, 1 far).
static inline float snapshotDepth(depth2d_array<float> depth, float2 screen, uint flipV, ushort eye)
{
    const uint2 size = uint2(depth.get_width(), depth.get_height());
    const float2 uv = snapshotUV(screen, flipV);
    const uint2 texel = min(uint2(uv * float2(size)), size - 1);
    return depth.read(texel, eye);
}

// Where a captured screen point at a given depth was, in world space.
static inline float3 snapshotWorld(constant SnapshotUniforms &u, ushort eye, float2 screen, float depth)
{
    const float4 clip = float4(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, depth * 2.0 - 1.0, 1.0);
    const float4 world = u.captureClipToWorld[eye] * clip;
    return world.xyz / world.w;
}

vertex SnapshotOut snapshotMeshVertex(uint vid [[vertex_id]],
                                      ushort amp_id [[amplification_id]],
                                      constant SnapshotUniforms &u [[buffer(BufferIndexUniforms)]],
                                      depth2d_array<float> depth [[texture(1)]])
{
    const ushort eye = ushort(u.eyeBase + amp_id);
    const uint cellIndex = vid / 6, corner = vid % 6;
    const uint2 cell = uint2(cellIndex % u.grid.x, cellIndex / u.grid.x);
    const uint first = corner < 3 ? 0 : 3;

    // All three corners of this vertex's triangle, so every vertex of it
    // reaches the same verdict on tearing.
    float nearest = INFINITY, farthest = 0.0, farthestDepth = 0.0, mineDepth = 0.0;
    for (uint k = 0; k < 3; k++) {
        const float2 s = snapshotScreen(cell, first + k, u.grid);
        const float z = snapshotDepth(depth, s, u.flipV, eye);
        const float d = max(distance(snapshotWorld(u, eye, s, z), u.captureEye[eye].xyz), u.minDistance);
        nearest = min(nearest, d);
        if (d > farthest) { farthest = d; farthestDepth = z; }
        if (first + k == corner) mineDepth = z;
    }
    const bool torn = farthest > nearest * u.tearRatio;

    const float2 screen = snapshotScreen(cell, corner, u.grid);
    const float3 world = snapshotWorld(u, eye, screen, torn ? farthestDepth : mineDepth);
    SnapshotOut out;
    out.position = u.worldToClip[eye] * float4(world, 1.0);
    out.uv = snapshotUV(screen, u.flipV);
    out.eye = eye;
    out.torn = 0.0;
    out.outside = 0.0;
    return out;
}

vertex SnapshotOut snapshotBackdropVertex(uint vid [[vertex_id]],
                                          ushort amp_id [[amplification_id]],
                                          constant SnapshotUniforms &u [[buffer(BufferIndexUniforms)]])
{
    const ushort eye = ushort(u.eyeBase + amp_id);
    const uint cellIndex = vid / 6, corner = vid % 6;
    const uint2 cell = uint2(cellIndex % u.grid.x, cellIndex / u.grid.x);
    // Past the captured frame the edge texels smear outward, fading to
    // black, so turning beyond it shows no hard window edge.
    const float2 screen = snapshotScreen(cell, corner, u.grid) * (1.0 + 2.0 * u.overscan) - u.overscan;

    // The far plane is hundreds of metres out; seen from the current eye it
    // is as good as infinity, and its depth is pinned there.
    const float3 onFarPlane = snapshotWorld(u, eye, screen, 1.0);
    const float3 direction = normalize(onFarPlane - u.captureEye[eye].xyz);
    float4 clip = u.worldToClip[eye] * float4(direction, 0.0);
    clip.z = u.farZ * clip.w;

    SnapshotOut out;
    out.position = clip;
    out.uv = snapshotUV(screen, u.flipV);
    out.eye = eye;
    out.torn = 0.0;
    out.outside = max(max(-screen.x, screen.x - 1.0), max(-screen.y, screen.y - 1.0));
    return out;
}

fragment float4 snapshotFragment(SnapshotOut in [[stage_in]],
                                 constant SnapshotUniforms &u [[buffer(BufferIndexUniforms)]],
                                 texture2d_array<half> color [[texture(TextureIndexColor)]])
{
    if (in.torn > 0.5)
        discard_fragment();
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const half3 rgb = color.sample(s, in.uv, in.eye).rgb;
    const float fade = in.outside > 0.0 ? saturate(1.0 - in.outside / max(u.overscan, 1e-3)) * 0.5 : 1.0;
    return float4(displayLinearize(float3(rgb), u.decodeGamma) * fade, u.alpha);
}
