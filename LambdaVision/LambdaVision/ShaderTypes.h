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
// weapon origin. ambient.w doubles as the masked-alpha-test flag (>0.5).
typedef struct
{
    matrix_float4x4 modelMatrix;
    simd_float4     lightDir;    // xyz = world-space direction TO the light
    simd_float4     lightColor;  // rgb = directional term
    simd_float4     ambient;     // rgb = ambient term, w = alpha-test flag
} WeaponUniforms;

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

// Lambda engine bridge — only visible to Swift/ObjC, not to Metal shaders.
#ifndef __METAL_VERSION__
#include "Bridge/Lambda_Bridge.h"
#include "Bridge/Lambda_SpatialAudio.h"
#include "Bridge/Lambda_WeaponModel.h"
#endif

#endif /* ShaderTypes_h */

