// Lambda_WeaponModel.h
//
// Skinned-mesh extractor + bone poser for GoldSrc studio (.mdl) weapon
// viewmodels. The engine still parses the .mdl and keeps a resident
// studiohdr_t; the client (cl_dll/entity.cpp, VR_AddHandWeapon) publishes a
// pointer to the active VIEWMODEL (v_*.mdl) plus its animation state (see the
// g_vr_weapon_* globals) whenever the vr_weapon_external cvar is on. This
// module runs on the GL worker thread right after the engine tick and
//
//   1. on model change, walks the header once and bakes a render-ready
//      triangle mesh in BONE-LOCAL space — every vertex carries the index of
//      the single bone it is rigidly bound to (GoldSrc has no weights) — plus
//      the bone table and the embedded palettized textures, into a
//      double-buffered snapshot;
//   2. every tick, replicates the engine's R_StudioEstimateFrame /
//      R_StudioCalcRotations math for the viewmodel's current sequence and
//      publishes the resulting bone→model matrices as a pose.
//
// The visionOS Metal pass uploads the mesh once per generation, refreshes the
// bone palette every frame and skins on the GPU. Coordinates stay in GoldSrc
// model space (units, Z-up); the axis/scale remap to Apple metres and the
// hand-anchor placement happen on the Swift side.

#ifndef LAMBDA_WEAPON_MODEL_H
#define LAMBDA_WEAPON_MODEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// GoldSrc MAXSTUDIOBONES. Must match WEAPON_MAX_BONES in ShaderTypes.h.
#define LAMBDA_WEAPON_MAX_BONES 128

// One baked vertex, in the LOCAL space of `bone` (not yet posed). UVs are
// normalized [0,1] against the owning submesh's texture. 36 bytes; the Metal
// vertex descriptor mirrors this layout (pos@0, normal@12, uv@24, bone@32).
typedef struct {
    float    pos[3];
    float    normal[3];
    float    uv[2];
    uint32_t bone;              // index into lambda_weapon_mesh_t.bones
} lambda_weapon_vertex_t;

// A run of triangles that share one texture. index_offset/index_count index
// into the snapshot's global index array; texture indexes the texture array.
typedef struct {
    uint32_t index_offset;
    uint32_t index_count;
    uint32_t texture;   // index into lambda_weapon_mesh_t.textures
    uint32_t flags;     // STUDIO_NF_* (masked/additive/chrome) for the shader
} lambda_weapon_submesh_t;

// RGBA8, tightly packed width*height*4. rgba is owned by the snapshot buffer
// and valid only between lambda_weapon_lock()/unlock().
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t flags;             // STUDIO_NF_* copied from the studio texture
    const uint8_t *rgba;
} lambda_weapon_texture_t;

// Bone table entry (mstudiobone_t name + parent), so the Swift side can find
// named bones — the grip hand, and later the detachable magazine / pump /
// cylinder parts — without knowing the studio format.
typedef struct {
    char    name[32];
    int32_t parent;             // -1 for a root bone
} lambda_weapon_bone_t;

// Immutable view of one baked model. All pointers are owned by the module and
// remain valid only while the lock is held.
typedef struct {
    uint32_t generation;        // bumps every time a new model is baked

    uint32_t vertex_count;
    const lambda_weapon_vertex_t *vertices;

    uint32_t index_count;
    const uint32_t *indices;

    uint32_t submesh_count;
    const lambda_weapon_submesh_t *submeshes;

    uint32_t texture_count;
    const lambda_weapon_texture_t *textures;

    uint32_t bone_count;
    const lambda_weapon_bone_t *bones;

    // Index of the grip hand bone — normally the right hand, but whichever
    // hand actually carries the weapon geometry (the satchel charge is
    // skinned to the LEFT hand), or -1 when the rig has no hand bone at all.
    // The Swift side pins this bone's POSED frame onto the tracked hand each
    // frame. See choose_grip_bone().
    int32_t hand_bone_index;

    // Model-space bounding box of the geometry in the bind pose (sanity/log).
    float bbmin[3];
    float bbmax[3];

    int modelindex;             // engine model index this was baked from
} lambda_weapon_mesh_t;

// Per-tick bone pose for the current snapshot: bone→model-space transforms
// (row-major 3x4, GoldSrc units) for the viewmodel's sequence at the estimated
// frame. `generation` names the mesh these bones belong to — a reader must
// ignore a pose whose generation differs from the mesh it has uploaded.
typedef struct {
    uint32_t generation;
    uint32_t bone_count;
    int32_t  sequence;
    float    frame;             // estimated frame within the sequence
    float    bones[LAMBDA_WEAPON_MAX_BONES][12];
} lambda_weapon_pose_t;

// Called on the GL worker thread after the engine tick. Reads the client-
// published g_vr_weapon_*; if they name a different model than the last bake,
// walks it and swaps in a fresh snapshot, then poses the bones for the
// published animation state. Cheap when nothing changed; a no-op when no
// external weapon is active. Never blocks the render thread for long (the
// pose publish holds the lock for one small memcpy).
void lambda_weapon_extract(void);

// Current snapshot generation without taking the lock — Swift polls this to
// decide whether to re-upload Metal buffers. 0 means nothing baked yet.
uint32_t lambda_weapon_generation(void);

// Nonzero when the client published an external weapon on the most recent
// frame (i.e. vr_weapon_external is on and a studio weapon is equipped). Swift
// gates drawing on this so it doesn't double-draw once external mode is off.
int lambda_weapon_active(void);

// World light (R_LightPoint at the eye, normalised 0..1) sampled by the client
// this frame; copied into rgb[3]. Used to shade the weapon to match the room.
void lambda_weapon_get_light(float rgb[3]);

// Lock the active snapshot for reading and fill *out with its pointers/counts.
// Returns the generation (0 if nothing baked, in which case *out is zeroed).
// Must be paired with lambda_weapon_unlock().
uint32_t lambda_weapon_lock(lambda_weapon_mesh_t *out);
void     lambda_weapon_unlock(void);

// Copy the latest published pose into *out (takes and releases the lock
// internally). Returns its generation, 0 if no pose has been published yet.
uint32_t lambda_weapon_copy_pose(lambda_weapon_pose_t *out);

#ifdef __cplusplus
}
#endif

#endif // LAMBDA_WEAPON_MODEL_H
