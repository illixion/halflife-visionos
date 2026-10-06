//
//  ShaderTypes.h
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions  = 0,
    BufferIndexMeshGenerics   = 1,
    BufferIndexUniforms       = 2,
    BufferIndexViewProjection = 3,
    BufferIndexBones          = 4,
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition   = 0,
    VertexAttributeTexcoord   = 1,
    VertexAttributeNormal     = 2,
    VertexAttributeColor      = 3,
    VertexAttributeBoneIndex  = 4,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor         = 0,
};

typedef struct
{
    matrix_float4x4 viewProjectionMatrix[2];
} ViewProjectionArray;

typedef struct
{
    matrix_float4x4 modelMatrix;
} Uniforms;

// Weapon pass uniforms: model→world transform plus a single-probe lighting
// term (ambient + one dominant directional), sampled from the engine at the
// weapon origin, plus the per-eye camera data the chrome environment map
// needs. One of these is written PER SUBMESH (the render flags differ per
// submesh), at WEAPON_UNIFORM_STRIDE spacing in the per-frame buffer.
typedef struct
{
    matrix_float4x4 modelMatrix;
    simd_float4     lightDir;    // xyz = world-space direction TO the light
    simd_float4     lightColor;  // rgb = directional term
    simd_float4     ambient;     // rgb = ambient term
    // Per-eye (vertex amplification id) camera position and right axis, in
    // Apple world metres — the basis GoldSrc builds its chrome sphere map
    // from (see R_StudioSetupChrome).
    simd_float4     eyePos[2];
    simd_float4     eyeRight[2];
    // x = masked alpha test (STUDIO_NF_MASKED), y = chrome (STUDIO_NF_CHROME),
    // z = near clip: discard fragments closer than this to the eye, metres (0 = off),
    // w = displayLinearize exponent (0 = off).
    simd_float4     renderFlags;
} WeaponUniforms;

// Level-load snapshot (SnapshotShaders.metal): the last engine frame before a
// load, kept as colour + depth, redrawn every frame from the current head pose
// so the world stays put while the engine is busy. Per eye, `captureClipToWorld`
// takes the captured frame's GL clip space (x, y from the texel, z = 2·depth − 1)
// to world space; `worldToClip` is the current view's world → Metal clip.
typedef struct
{
    matrix_float4x4 captureClipToWorld[2];
    matrix_float4x4 worldToClip[2];
    simd_float4     captureEye[2];  // xyz = where the captured eye was, world units
    simd_uint2      grid;           // mesh cells across, down
    uint32_t        eyeBase;        // eye of amplification id 0
    uint32_t        flipV;          // texture rows run bottom-up (GL-written)
    float           farZ;           // output NDC depth for "infinitely far"
    float           tearRatio;      // a triangle whose far corner is this much farther than its near one tears
    float           alpha;          // opacity over whatever is behind
    float           minDistance;    // world units: nearer than this counts as this near (no divide blow-ups)
    float           overscan;       // the backdrop reaches this far past the captured frame (fraction of it), edge texels smeared and darkened
    float           decodeGamma;    // displayLinearize exponent (0 = write the engine's values as they are)
    float           pad[2];
} SnapshotUniforms;

// Constant-buffer slot spacing for the per-submesh WeaponUniforms array, and
// the number of submeshes one draw may bind (stock viewmodels top out at 11).
#define WEAPON_UNIFORM_STRIDE 256
#define WEAPON_MAX_SUBMESHES  32

// Weapon bone palette: bone→model-space transforms for the current pose,
// indexed by each vertex's bone attribute (GoldSrc rigid single-bone
// skinning). 128 = GoldSrc MAXSTUDIOBONES = LAMBDA_WEAPON_MAX_BONES in
// Bridge/Lambda_WeaponModel.h.
#define WEAPON_MAX_BONES 128
typedef struct
{
    matrix_float4x4 bones[WEAPON_MAX_BONES];
} WeaponBonePalette;

// UI arc (reload-progress ring, radial-menu sectors): an unlit
// world-anchored arc billboard drawn at the end of the weapon pass. The
// arc is generated procedurally in the vertex shader (no vertex buffer);
// center/right/up define the billboard frame in Apple world metres.
// Angles are in "turns" clockwise from 12 o'clock (start 0, sweep 1 =
// full circle), so a progress ring is start=0/sweep=progress and a menu
// sector is start=i/N/sweep=1/N.
typedef struct
{
    simd_float4 center;      // xyz = world-space ring center
    simd_float4 right;       // xyz = billboard right axis, w = outer radius (m)
    simd_float4 up;          // xyz = billboard up axis,    w = inner radius (m)
    simd_float4 color;       // rgba (no blending; drawn opaque)
    float       startTurns;  // arc start, turns clockwise from 12 o'clock
    float       sweepTurns;  // arc sweep, turns
} RingUniforms;

// Composite pass (Shaders.metal fragmentShader / fragmentShaderFXAA),
// fragment buffer BufferIndexUniforms.
typedef struct
{
    float decodeGamma;  // displayLinearize exponent (0 = off)
    float hdrTest;      // headroom test pattern: 0 off, 1 dots on black, 2 full-view patches
    float aspect;       // eye viewport width / height, so the test dots are round
    float pad;
    // Per-pixel reprojection depth (fragmentShaderDepth / fragmentShaderFXAADepth):
    // the engine's GL window depth → the compositor's reverse-Z depth.
    // x = 2·n·f, y = f + n, z = f − n of the engine's projection (metres),
    // so distance = x / (y − ndc·z).
    simd_float4 engineClip;
    // Per eye: the compositor projection's z and w rows at a view-space z,
    // (P[2].z, P[3].z, P[2].w, P[3].w): depth = (x·z + y) / (z·z + w).
    simd_float4 depthProjection[2];
    // x = depth for "far" (just inside the far plane: exactly 0 displays
    // black), y = nearest depth allowed, z = metres: anything the engine
    // puts nearer than this is its flat viewmodel (squeezed into the front
    // 30% of the depth range) and gets the far depth, as before.
    simd_float4 depthLimits;
    // Glass (the composite's kGlass variants, Shaders.metal glassShade): where
    // the engine marked glass in its stencil (r_vrglass), a Fresnel
    // reflection of the environment probe (GlassProbe.swift). x = strength
    // (Settings "Reflection strength"; scales the reflectance), y = F0
    // (normal-incidence reflectance), z = the most of the pixel the
    // reflection may replace, w = how far what is seen through the pane takes
    // on glassTint (0 = clear).
    simd_float4 glass;
    // Water rows of the same table (r_vrwater): x = strength, y = F0, z = cap,
    // w = ripple slope (0 = a flat mirror).
    simd_float4 water;
    // x = glass, y = water reflectance added head-on (before strength) so a
    // surface seen from the front still reads, z = seconds (wrapped, for the
    // ripples), w = ripple wavelength scale (1 = the default ~40-unit waves).
    simd_float4 reflectExtra;
    // rgb = what the reflection shows while no probe is ready, in the engine's
    // (gamma-encoded) colour space.
    simd_float4 glassAmbient;
    // rgb = the pane's own colour, multiplied into what is seen through it;
    // w unused.
    simd_float4 glassTint;
    // Per eye: the engine frustum's left, right, top, bottom tangents, for
    // each pixel's view ray.
    simd_float4 eyeTangents[2];
    // Per eye, the view the engine drew it from (lambda_glass_eye_t), xash
    // world units and axes: origin, forward, right, up (w unused).
    simd_float4 glassEye[2][4];
    // The two environment probes being blended (GlassProbe): [0] the one
    // fading out, [1] the current one. xyz = where it was captured (xash
    // units), w = the array slice of its first face, or −1 for none.
    simd_float4 probe[2];
    // x = probe[1]'s weight (0 → 1 over a swap), y, z = the probe depth's
    // zNear, zFar (xash units), w unused.
    simd_float4 probeMix;
    // Per eye: the glass planes the stencil codes name (code − 16), xash
    // world: normal xyz, distance (lambda_glass_eye_t.planes).
    simd_float4 glassPlanes[2][224];
    // Per eye: one bit per plane row, set for water (lambda_glass_eye_t.kind).
    // Row r is word r / 32 = glassKinds[eye][r / 128][(r / 32) % 4].
    simd_uint4 glassKinds[2][2];
    // Per eye, sharp water (Shaders.metal ssprScatter): x = the plane row it
    // mirrors in, y = that plane's height (xash z), z = 1 on / 0 off, w = the
    // target's size divisor against the engine image (0 = 3).
    simd_float4 sspr[2];
    // x = Settings → Diagnostics "Water mirror view": 0 off, 1 the mirror on
    // water, 2 its confidence, 3 the mirror target over the whole view.
    simd_float4 waterDebug;
} DisplayParams;

#ifdef __METAL_VERSION__
// The drawable is linear light (rgba16Float, extended range), but the
// engine's colours are gamma-encoded for a CRT the way every 8-bit game's
// are: its 0.5 means "looks half as bright", about 22% of the light. Written
// straight into the drawable they read as linear and everything under white
// is lifted, darks most. Every pass that puts a game colour on the drawable
// decodes it with this first; UI colours (HUD, arcs) are authored for the
// drawable as is and skip it. Clamped to SDR white: highlight expansion
// above 1.0 is the tone map's job, not the decode's.
static inline float3 displayLinearize(float3 c, float gamma)
{
    return gamma > 0.0 ? metal::pow(metal::saturate(c), gamma) : c;
}
#endif

// Lambda engine bridge — only visible to Swift/ObjC, not to Metal shaders.
#ifndef __METAL_VERSION__
#include "Bridge/Lambda_Bridge.h"
#include "Bridge/Lambda_SpatialAudio.h"
#include "Bridge/Lambda_WeaponModel.h"
#endif

#endif /* ShaderTypes_h */

