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
    // The studio texture's file name ("rubbergloveCHROME.bmp"). The only
    // reliable way to tell a viewmodel's HEV hands from its gun: stock v_
    // models skin gun parts straight to `Bip01 R Hand`, so bones cannot
    // separate the two, but every hand is drawn with a glove/sleeve texture.
    char name[64];
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

// Copy the current bake's sequence 0 / frame 0 pose — a viewmodel's idle —
// into *out. Unlike lambda_weapon_copy_pose this does not follow playback, so
// it is the stable reference for how the gun sits in the hand. Returns its
// generation, 0 before the first bake.
uint32_t lambda_weapon_copy_rest_pose(lambda_weapon_pose_t *out);

// --- player body -----------------------------------------------------------
//
// The first-person avatar. Unlike the weapon, no engine entity publishes it,
// so it is read straight off disk once: pass the full path to a GoldSrc v10
// .mdl with embedded textures, plus the `body` bodygroup value used to pick
// submodels (the deathmatch player models put their high-detail body at 1).
// Returns nonzero on success. Safe to call again to swap models; the previous
// buffer is released.
//
// The pose this slot publishes is the model's REST pose, not an animation —
// the avatar is posed by the platform's head/hand IK, so the rest pose serves
// only as the reference the solver builds rotations against.
int      lambda_body_load(const char *path, int body);
uint32_t lambda_body_generation(void);
uint32_t lambda_body_lock(lambda_weapon_mesh_t *out);
void     lambda_body_unlock(void);
uint32_t lambda_body_copy_pose(lambda_weapon_pose_t *out);

// Where the player's feet are, published by the client each normal refdef
// (cl_dll/view.cpp g_vr_body_state) for the avatar's legs. Plain floats read
// across threads; a torn read costs one frame of one leg.
typedef struct {
    float eye_height;       // eye above the floor under the player, units,
                            // before the headset's own translation is added
    int   on_ground;
    int   water_level;      // 0 dry .. 3 submerged
    float velocity[3];      // forward, left (player-yaw frame), up; units/s
    uint32_t sequence;      // bumps on every publish; stalls while paused
} lambda_body_state_t;

void lambda_body_state(lambda_body_state_t *out);

// What the native (Metal) HUD shows, published by the client every HUD redraw
// (cl_dll/hud_redraw.cpp g_vr_hud_state). -1 marks "not applicable": no
// weapon, no clip, no primary / secondary ammo, unknown max clip.
typedef struct {
    int   has_suit;
    int   health;
    int   battery;          // suit charge, 0..100
    int   hide_flags;       // HIDEHUD_* bits the game set (1 weapons, 2 flashlight, 4 all, 8 health)
    int   weapon_id;
    int   clip;
    int   max_clip;         // the weapon's own GetItemInfo; -1 when unknown
    int   ammo1;            // primary reserve
    int   ammo1_max;
    int   ammo2;            // secondary (MP5 grenades)
    int   ammo2_max;
    int   flashlight_on;
    float flashlight_charge; // 0..1
    int   intermission;
} lambda_hud_state_t;

void lambda_hud_state(lambda_hud_state_t *out);
// 1 = the native HUD is shown, so the stock health, suit, ammo and
// flashlight readouts in the 2D layer stand down.
void lambda_hud_set_native(int on);

#ifdef __cplusplus
}
#endif

#endif // LAMBDA_WEAPON_MODEL_H
