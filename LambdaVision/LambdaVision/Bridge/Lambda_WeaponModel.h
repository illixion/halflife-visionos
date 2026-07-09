// Lambda_WeaponModel.h
//
// Bind-pose extractor for GoldSrc studio (.mdl) weapon viewmodels. The engine
// still parses the .mdl and keeps a resident studiohdr_t; the client publishes
// a pointer to the active weapon model (see g_vr_weapon_* below) whenever the
// vr_weapon_external cvar is on. This module walks that header on the GL worker
// thread and bakes a render-ready, bind-pose triangle mesh into a
// double-buffered snapshot that the visionOS Metal pass consumes on the render
// thread under a lock.
//
// Phase 1 scope: geometry + UVs + embedded palettized textures + the hand-bone
// bind transform, at bind pose only (no sequence animation). Coordinates stay
// in GoldSrc model space (units, Z-up); the axis/scale remap to RealityKit
// meters happens on the Swift side so the hand anchor can drive placement.

#ifndef LAMBDA_WEAPON_MODEL_H
#define LAMBDA_WEAPON_MODEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One baked, bone-transformed vertex. Positions/normals are in GoldSrc model
// space (bind pose already applied). UVs are normalized [0,1] against the
// owning submesh's texture.
typedef struct {
    float pos[3];
    float normal[3];
    float uv[2];
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

    // Bind-pose world transform (row-major 3x4, GoldSrc model space) of the
    // "Bip01 R Hand" bone, or identity if the model has no such bone.
    float hand_bone[12];
    int   has_hand_bone;

    // Model-space bounding box of the baked geometry (sanity/placement).
    float bbmin[3];
    float bbmax[3];

    int modelindex;             // engine model index this was baked from
} lambda_weapon_mesh_t;

// Called on the GL worker thread after the engine tick. Reads the client-
// published g_vr_weapon_hdr; if it names a different model than the last bake,
// walks it and swaps in a fresh snapshot. Cheap no-op when nothing changed or
// when no external weapon is active. Never blocks the render thread.
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

#ifdef __cplusplus
}
#endif

#endif // LAMBDA_WEAPON_MODEL_H
