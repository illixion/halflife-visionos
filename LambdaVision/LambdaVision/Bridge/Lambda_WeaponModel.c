// Lambda_WeaponModel.c — see Lambda_WeaponModel.h.
//
// Walks a resident GoldSrc studiohdr_t and bakes it into a bone-local triangle
// mesh (once per model), then poses the bones every tick from the viewmodel's
// published animation state. The studio struct layout and the bone math are
// replicated locally (rather than pulling engine headers onto the app target's
// include path) so this stays a self-contained unit; the layouts are the frozen
// v10 format and the math is copied from the engine's matrixlib / mathlib /
// gl_studio.c (R_StudioEstimateFrame, R_StudioCalcRotations, R_StudioCalcBones)
// so the pose matches what the engine would have drawn.

#include "Lambda_WeaponModel.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// ---------------------------------------------------------------------------
// GoldSrc studio v10 format (subset, exact byte layout — see engine/studio.h).
// ---------------------------------------------------------------------------
#define IDSTUDIOHEADER   (('T'<<24)+('S'<<16)+('D'<<8)+'I') // "IDST"
#define STUDIO_VERSION   10
#define MAXSTUDIONAME    32

#define STUDIO_NF_CHROME    0x0002
#define STUDIO_NF_ADDITIVE  0x0020
#define STUDIO_NF_MASKED    0x0040
#define STUDIO_NF_UV_COORDS (1U<<31)

// sequence flags / motion types
#define STUDIO_LOOPING   0x0001
#define STUDIO_X         0x0001
#define STUDIO_Y         0x0002
#define STUDIO_Z         0x0004

typedef struct {
    int32_t ident, version;
    char    name[64];
    int32_t length;
    float   eyeposition[3];
    float   min[3], max[3];
    float   bbmin[3], bbmax[3];
    int32_t flags;
    int32_t numbones, boneindex;
    int32_t numbonecontrollers, bonecontrollerindex;
    int32_t numhitboxes, hitboxindex;
    int32_t numseq, seqindex;
    int32_t numseqgroups, seqgroupindex;
    int32_t numtextures, textureindex, texturedataindex;
    int32_t numskinref, numskinfamilies, skinindex;
    int32_t numbodyparts, bodypartindex;
    int32_t numattachments, attachmentindex;
    int32_t studiohdr2index;
    int32_t unused, unused2, unused3;
    int32_t numtransitions, transitionindex;
} studiohdr_t;

typedef struct {
    char    name[MAXSTUDIONAME];
    int32_t parent;
    int32_t unused;
    int32_t bonecontroller[6];
    float   value[6];   // [0..2] default pos, [3..5] default euler rot (rad)
    float   scale[6];
} mstudiobone_t;

typedef struct {
    char    label[MAXSTUDIONAME];
    float   fps;
    int32_t flags;
    int32_t activity, actweight;
    int32_t numevents, eventindex;
    int32_t numframes;
    int32_t numpivots, pivotindex;
    int32_t motiontype, motionbone;
    float   linearmovement[3];
    int32_t automoveposindex, automoveangleindex;
    float   bbmin[3], bbmax[3];
    int32_t numblends;
    int32_t animindex;      // -> mstudioanim_t[numblends][numbones], hdr-relative when seqgroup == 0
    int32_t blendtype[2];
    float   blendstart[2], blendend[2];
    int32_t blendparent;
    int32_t seqgroup;
    int32_t entrynode, exitnode, nodeflags;
    int32_t nextseq;
} mstudioseqdesc_t;

// Per-bone, per-DOF offsets (relative to this struct) to RLE animvalue runs.
typedef struct {
    uint16_t offset[6];
} mstudioanim_t;

typedef union {
    struct { uint8_t valid, total; } num;
    int16_t value;
} mstudioanimvalue_t;

typedef struct {
    char    name[64];
    int32_t nummodels;
    int32_t base;
    int32_t modelindex;
} mstudiobodyparts_t;

typedef struct {
    char    name[64];
    int32_t unused;
    float   unused2;
    int32_t nummesh, meshindex;
    int32_t numverts, vertinfoindex, vertindex;
    int32_t numnorms, norminfoindex, normindex;
    int32_t blendvertinfoindex, blendnorminfoindex;
} mstudiomodel_t;

typedef struct {
    int32_t numtris, triindex;
    int32_t skinref;
    int32_t numnorms, unused;
} mstudiomesh_t;

typedef struct {
    char     name[64];
    uint32_t flags;
    int32_t  width, height;
    int32_t  index;     // offset to palettized image data, relative to hdr base
} mstudiotexture_t;

_Static_assert(sizeof(studiohdr_t) == 244,        "studiohdr_t layout");
_Static_assert(sizeof(mstudiobone_t) == 112,      "mstudiobone_t layout");
_Static_assert(sizeof(mstudioseqdesc_t) == 176,   "mstudioseqdesc_t layout");
_Static_assert(sizeof(mstudioanim_t) == 12,       "mstudioanim_t layout");
_Static_assert(sizeof(mstudioanimvalue_t) == 2,   "mstudioanimvalue_t layout");
_Static_assert(sizeof(mstudiobodyparts_t) == 76,  "mstudiobodyparts_t layout");
_Static_assert(sizeof(mstudiomodel_t) == 112,     "mstudiomodel_t layout");
_Static_assert(sizeof(mstudiomesh_t) == 20,       "mstudiomesh_t layout");
_Static_assert(sizeof(mstudiotexture_t) == 80,    "mstudiotexture_t layout");
_Static_assert(sizeof(lambda_weapon_vertex_t) == 36, "vertex layout mirrored by WeaponPass");

// ---------------------------------------------------------------------------
// Bone math, copied from the engine (public/matrixlib.c, xash3d_mathlib.c) and
// gl_studio.c's studio-quaternion convention, so the pose is identical.
// ---------------------------------------------------------------------------
typedef float matrix3x4[3][4];

static void AngleQuaternionStudio(const float angles[3], float q[4]) {
    // studio=true branch of the engine's AngleQuaternion: ROLL->y, YAW->p,
    // PITCH->r, angles already in radians.
    float sr, sp, sy, cr, cp, cy;
    sy = sinf(angles[2] * 0.5f); cy = cosf(angles[2] * 0.5f);
    sp = sinf(angles[1] * 0.5f); cp = cosf(angles[1] * 0.5f);
    sr = sinf(angles[0] * 0.5f); cr = cosf(angles[0] * 0.5f);
    q[0] = sr * cp * cy - cr * sp * sy;
    q[1] = cr * sp * cy + sr * cp * sy;
    q[2] = cr * cp * sy - sr * sp * cy;
    q[3] = cr * cp * cy + sr * sp * sy;
}

// QuaternionSlerp = QuaternionAlign + QuaternionSlerpNoAlign (xash3d_mathlib.c).
static void QuaternionSlerp(const float p[4], const float q0[4], float t, float qt[4]) {
    float q[4];
    float a = 0.0f, b = 0.0f;
    for (int i = 0; i < 4; i++) {
        a += (p[i] - q0[i]) * (p[i] - q0[i]);
        b += (p[i] + q0[i]) * (p[i] + q0[i]);
    }
    for (int i = 0; i < 4; i++) q[i] = (a > b) ? -q0[i] : q0[i];

    float cosom = p[0]*q[0] + p[1]*q[1] + p[2]*q[2] + p[3]*q[3];
    if ((1.0f + cosom) > 0.000001f) {
        float sclp, sclq;
        if ((1.0f - cosom) > 0.000001f) {
            float omega = acosf(cosom);
            float sinom = sinf(omega);
            sclp = sinf((1.0f - t) * omega) / sinom;
            sclq = sinf(t * omega) / sinom;
        } else {
            sclp = 1.0f - t;
            sclq = t;
        }
        for (int i = 0; i < 4; i++) qt[i] = sclp * p[i] + sclq * q[i];
    } else {
        qt[0] = -q[1]; qt[1] = q[0]; qt[2] = -q[3]; qt[3] = q[2];
        float sclp = sinf((1.0f - t) * (0.5f * (float)M_PI));
        float sclq = sinf(t * (0.5f * (float)M_PI));
        for (int i = 0; i < 3; i++) qt[i] = sclp * p[i] + sclq * qt[i];
    }
}

static void Matrix3x4_FromOriginQuat(matrix3x4 out, const float q[4], const float o[3]) {
    out[0][0] = 1.0f - 2.0f*q[1]*q[1] - 2.0f*q[2]*q[2];
    out[1][0] = 2.0f*q[0]*q[1] + 2.0f*q[3]*q[2];
    out[2][0] = 2.0f*q[0]*q[2] - 2.0f*q[3]*q[1];
    out[0][1] = 2.0f*q[0]*q[1] - 2.0f*q[3]*q[2];
    out[1][1] = 1.0f - 2.0f*q[0]*q[0] - 2.0f*q[2]*q[2];
    out[2][1] = 2.0f*q[1]*q[2] + 2.0f*q[3]*q[0];
    out[0][2] = 2.0f*q[0]*q[2] + 2.0f*q[3]*q[1];
    out[1][2] = 2.0f*q[1]*q[2] - 2.0f*q[3]*q[0];
    out[2][2] = 1.0f - 2.0f*q[0]*q[0] - 2.0f*q[1]*q[1];
    out[0][3] = o[0]; out[1][3] = o[1]; out[2][3] = o[2];
}

static void Matrix3x4_Concat(matrix3x4 out, const matrix3x4 a, const matrix3x4 b) {
    out[0][0] = a[0][0]*b[0][0] + a[0][1]*b[1][0] + a[0][2]*b[2][0];
    out[0][1] = a[0][0]*b[0][1] + a[0][1]*b[1][1] + a[0][2]*b[2][1];
    out[0][2] = a[0][0]*b[0][2] + a[0][1]*b[1][2] + a[0][2]*b[2][2];
    out[0][3] = a[0][0]*b[0][3] + a[0][1]*b[1][3] + a[0][2]*b[2][3] + a[0][3];
    out[1][0] = a[1][0]*b[0][0] + a[1][1]*b[1][0] + a[1][2]*b[2][0];
    out[1][1] = a[1][0]*b[0][1] + a[1][1]*b[1][1] + a[1][2]*b[2][1];
    out[1][2] = a[1][0]*b[0][2] + a[1][1]*b[1][2] + a[1][2]*b[2][2];
    out[1][3] = a[1][0]*b[0][3] + a[1][1]*b[1][3] + a[1][2]*b[2][3] + a[1][3];
    out[2][0] = a[2][0]*b[0][0] + a[2][1]*b[1][0] + a[2][2]*b[2][0];
    out[2][1] = a[2][0]*b[0][1] + a[2][1]*b[1][1] + a[2][2]*b[2][1];
    out[2][2] = a[2][0]*b[0][2] + a[2][1]*b[1][2] + a[2][2]*b[2][2];
    out[2][3] = a[2][0]*b[0][3] + a[2][1]*b[1][3] + a[2][2]*b[2][3] + a[2][3];
}

static void Matrix3x4_Transform(const matrix3x4 m, const float v[3], float out[3]) {
    out[0] = v[0]*m[0][0] + v[1]*m[0][1] + v[2]*m[0][2] + m[0][3];
    out[1] = v[0]*m[1][0] + v[1]*m[1][1] + v[2]*m[1][2] + m[1][3];
    out[2] = v[0]*m[2][0] + v[1]*m[2][1] + v[2]*m[2][2] + m[2][3];
}

// ---------------------------------------------------------------------------
// Snapshot storage: double-buffered, mutex-guarded. Writers (GL worker) fill
// the back buffer then flip; readers (render thread) hold the lock briefly.
// ---------------------------------------------------------------------------
typedef struct {
    lambda_weapon_vertex_t  *vertices;  uint32_t vcount, vcap;
    uint32_t                *indices;   uint32_t icount, icap;
    lambda_weapon_submesh_t *submeshes; uint32_t scount, scap;
    lambda_weapon_texture_t *textures;  uint32_t tcount, tcap;
    uint8_t                 *texdata;   size_t   texbytes;  // packed RGBA blobs
    lambda_weapon_bone_t    *bones;     uint32_t bcount, bcap;
    int   hand_bone_index;
    float bbmin[3], bbmax[3];
    int   modelindex;
    uint32_t generation;
} snapshot_t;

static snapshot_t      g_snap[2];
static int             g_active = -1;          // index of the readable snapshot
static uint32_t        g_generation = 0;
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;

// Latest pose for the active snapshot (written every tick under g_mtx).
static lambda_weapon_pose_t g_pose;

// Change key so we only re-bake when the model actually changes.
static void   *g_last_hdr = NULL;
static int      g_last_modelindex = -1;
static int      g_last_body = -1;
static int      g_last_valid = 0;   // last bake succeeded (header sane)

// Published by the hlsdk client (cl_dll/entity.cpp) each frame when
// vr_weapon_external is on; read here on the same (GL worker) thread.
extern void *g_vr_weapon_hdr;
extern int   g_vr_weapon_modelindex;
extern int   g_vr_weapon_body;
extern int   g_vr_weapon_sequence;
extern float g_vr_weapon_frame;
extern float g_vr_weapon_animtime;
extern float g_vr_weapon_framerate;
extern float g_vr_weapon_time;

// --- dynamic-array helpers -------------------------------------------------
static uint32_t push_vertex(snapshot_t *s, const lambda_weapon_vertex_t *v) {
    if (s->vcount == s->vcap) {
        s->vcap = s->vcap ? s->vcap * 2 : 1024;
        s->vertices = (lambda_weapon_vertex_t *)realloc(s->vertices, s->vcap * sizeof(*s->vertices));
    }
    s->vertices[s->vcount] = *v;
    return s->vcount++;
}
static void push_index(snapshot_t *s, uint32_t idx) {
    if (s->icount == s->icap) {
        s->icap = s->icap ? s->icap * 2 : 2048;
        s->indices = (uint32_t *)realloc(s->indices, s->icap * sizeof(*s->indices));
    }
    s->indices[s->icount++] = idx;
}
static lambda_weapon_submesh_t *push_submesh(snapshot_t *s) {
    if (s->scount == s->scap) {
        s->scap = s->scap ? s->scap * 2 : 16;
        s->submeshes = (lambda_weapon_submesh_t *)realloc(s->submeshes, s->scap * sizeof(*s->submeshes));
    }
    return &s->submeshes[s->scount++];
}

static void snapshot_reset(snapshot_t *s) {
    // Keep allocations, reset counts (buffers are reused across bakes).
    s->vcount = s->icount = s->scount = s->tcount = s->bcount = 0;
    s->texbytes = 0;
    s->hand_bone_index = -1;
    s->bbmin[0] = s->bbmin[1] = s->bbmin[2] =  1e30f;
    s->bbmax[0] = s->bbmax[1] = s->bbmax[2] = -1e30f;
}

// ---------------------------------------------------------------------------
// Texture expansion: 8-bit palettized (embedded) -> RGBA8. Falls back to a
// flat magenta 2x2 when the data isn't embedded/in range, so the geometry is
// still visible and the gap is obvious.
// ---------------------------------------------------------------------------
static void bake_textures(snapshot_t *s, const uint8_t *base, const studiohdr_t *hdr) {
    const mstudiotexture_t *tex = (const mstudiotexture_t *)(base + hdr->textureindex);
    uint32_t n = hdr->numtextures > 0 ? (uint32_t)hdr->numtextures : 1;

    s->tcount = 0;
    if (n > s->tcap) { s->tcap = n; s->textures = realloc(s->textures, n * sizeof(*s->textures)); }

    // First pass: sum required RGBA bytes so texdata is a single stable blob
    // (pointers into it stay valid; realloc can't move it mid-bake).
    size_t need = 0;
    for (uint32_t i = 0; i < n; i++) {
        if ((int)i < hdr->numtextures && tex[i].width > 0 && tex[i].height > 0)
            need += (size_t)tex[i].width * tex[i].height * 4;
        else
            need += 2 * 2 * 4;
    }
    if (need > s->texbytes) { s->texdata = realloc(s->texdata, need); s->texbytes = need; }

    // The engine overwrites each mstudiotexture_t.index with a GL texture
    // handle after upload (ref/gl/gl_studio.c R_StudioLoadTexture), so the
    // per-texture offset is no longer usable. Reconstruct the original file
    // layout from hdr->texturedataindex (left intact) plus cumulative sizes:
    // the image blocks follow the texture headers contiguously, in order.
    int64_t cursor = hdr->texturedataindex;
    size_t off = 0;
    for (uint32_t i = 0; i < n; i++) {
        lambda_weapon_texture_t *out = &s->textures[s->tcount++];
        uint8_t *dst = s->texdata + off;

        int have = ((int)i < hdr->numtextures) && tex[i].width > 0 && tex[i].height > 0;
        int64_t pxoff = cursor;
        int64_t pxcnt = have ? (int64_t)tex[i].width * tex[i].height : 0;
        int in_range = have && cursor > 0 &&
                       pxoff + pxcnt + 256 * 3 <= (int64_t)hdr->length;

        if (in_range) {
            const uint8_t *pix = base + pxoff;
            const uint8_t *pal = pix + pxcnt;
            uint32_t masked = tex[i].flags & STUDIO_NF_MASKED;
            for (int64_t p = 0; p < pxcnt; p++) {
                uint8_t idx = pix[p];
                const uint8_t *c = pal + idx * 3;
                dst[p*4+0] = c[0]; dst[p*4+1] = c[1]; dst[p*4+2] = c[2];
                dst[p*4+3] = (masked && idx == 255) ? 0 : 255;
            }
            out->width  = tex[i].width;
            out->height = tex[i].height;
            out->flags  = tex[i].flags;
            off += (size_t)pxcnt * 4;
        } else {
            // 2x2 magenta fallback.
            for (int p = 0; p < 4; p++) {
                dst[p*4+0] = 255; dst[p*4+1] = 0; dst[p*4+2] = 255; dst[p*4+3] = 255;
            }
            out->width = out->height = 2;
            out->flags = 0;
            off += 2 * 2 * 4;
        }
        // Advance the source cursor past this texture's image + palette so the
        // next texture reads from the right place (even if this one fell back).
        if (have) cursor += pxcnt + 256 * 3;
        out->rgba = dst;
    }
}

// ---------------------------------------------------------------------------
// Bone posing.
// ---------------------------------------------------------------------------

// Bind-pose bone world matrices (model space; entity transform = identity):
// each bone at its mstudiobone_t default values. Used for the bbox and the
// debug dump, and as the fallback pose when a sequence can't be decoded.
static void compute_bind_bones(const uint8_t *base, const studiohdr_t *hdr,
                               matrix3x4 *bones /* [numbones] */) {
    const mstudiobone_t *pb = (const mstudiobone_t *)(base + hdr->boneindex);
    for (int i = 0; i < hdr->numbones; i++) {
        float q[4];
        AngleQuaternionStudio(&pb[i].value[3], q);
        matrix3x4 local;
        Matrix3x4_FromOriginQuat(local, q, pb[i].value);
        if (pb[i].parent < 0)
            memcpy(bones[i], local, sizeof(local));
        else
            Matrix3x4_Concat(bones[i], bones[pb[i].parent], local);
    }
}

// R_StudioEstimateFrame (gl_studio.c), interpolate=true: fractional frame of
// `seq` for an entity whose animation state is (frame, animtime, framerate)
// at client time `time`.
static float estimate_frame(const mstudioseqdesc_t *seq, float frame,
                            float animtime, float framerate, float time) {
    double dfdt, f;
    if (time < animtime) dfdt = 0.0;
    else dfdt = (double)(time - animtime) * framerate * seq->fps;

    if (seq->numframes <= 1) f = 0.0;
    else f = (frame * (seq->numframes - 1)) / 256.0;

    f += dfdt;

    if (seq->flags & STUDIO_LOOPING) {
        if (seq->numframes > 1)
            f -= (int)(f / (seq->numframes - 1)) * (seq->numframes - 1);
        if (f < 0) f += (seq->numframes - 1);
    } else {
        if (f >= seq->numframes - 1.001) f = seq->numframes - 1.001;
        if (f < 0.0) f = 0.0;
    }
    return (float)f;
}

// R_StudioCalcBones (xash3d_mathlib.c) with no bone controllers (adj = NULL —
// no HL viewmodel has any): decode the RLE animvalue runs of one bone for
// integer frame `frame`, lerp toward frame+1 by `s`, and emit pos + quat.
static void calc_bone(int frame, float s, const mstudiobone_t *pbone,
                      const mstudioanim_t *panim, float pos[3], float q[4]) {
    float v1[6], v2[6];

    for (int i = 0; i < 6; i++) {
        if (panim->offset[i] == 0) {
            v1[i] = v2[i] = pbone->value[i];
            continue;
        }
        const mstudioanimvalue_t *pv =
            (const mstudioanimvalue_t *)((const uint8_t *)panim + panim->offset[i]);
        int j = frame;
        int guard = 0;

        if (pv->num.total < pv->num.valid) j = 0;
        while (pv->num.total <= j) {
            j -= pv->num.total;
            pv += pv->num.valid + 1;
            if (pv->num.total < pv->num.valid) j = 0;
            if (++guard > 4096) { j = 0; break; }   // malformed run list
        }

        float a, b;
        if (pv->num.valid > j) {
            a = pv[j + 1].value;
            if (pv->num.valid > j + 1)      b = pv[j + 2].value;
            else if (pv->num.total > j + 1) b = a;
            else                            b = pv[pv->num.valid + 2].value;
        } else {
            a = pv[pv->num.valid].value;
            if (pv->num.total > j + 1)      b = a;
            else                            b = pv[pv->num.valid + 2].value;
        }
        v1[i] = pbone->value[i] + a * pbone->scale[i];
        v2[i] = pbone->value[i] + b * pbone->scale[i];
    }

    for (int k = 0; k < 3; k++)
        pos[k] = (v1[k] == v2[k]) ? v1[k] : v1[k] + s * (v2[k] - v1[k]);

    if (v1[3] == v2[3] && v1[4] == v2[4] && v1[5] == v2[5]) {
        AngleQuaternionStudio(&v1[3], q);
    } else {
        float q1[4], q2[4];
        AngleQuaternionStudio(&v1[3], q1);
        AngleQuaternionStudio(&v2[3], q2);
        QuaternionSlerp(q1, q2, s, q);
    }
}

// Pose every bone of `hdr` for `sequence` at fractional frame `f`
// (R_StudioCalcRotations + the parent concat of R_StudioSetupBones, entity
// transform = identity). Falls back to the bind pose — and returns 0 — when
// the sequence lives in an external sequence-group file (never the case for
// the stock HL viewmodels) or the model has no sequences at all.
static int compute_pose_bones(const uint8_t *base, const studiohdr_t *hdr,
                              int sequence, float f, matrix3x4 *bones) {
    if (hdr->numseq <= 0) { compute_bind_bones(base, hdr, bones); return 0; }
    if (sequence < 0 || sequence >= hdr->numseq) sequence = 0;
    const mstudioseqdesc_t *seq = (const mstudioseqdesc_t *)(base + hdr->seqindex) + sequence;
    if (seq->seqgroup != 0 || seq->animindex <= 0 || seq->animindex >= hdr->length) {
        compute_bind_bones(base, hdr, bones);
        return 0;
    }
    // Blend 0 only: viewmodels don't use blend controllers.
    const mstudioanim_t *panim = (const mstudioanim_t *)(base + seq->animindex);
    const mstudiobone_t *pb = (const mstudiobone_t *)(base + hdr->boneindex);

    // "bah, fix this bug with changing sequences too fast" — engine clamps.
    if (f > seq->numframes - 1) f = 0.0f;
    else if (f < -0.01f) f = -0.01f;
    int frame = (int)f;
    float s = f - (float)frame;

    float pos[LAMBDA_WEAPON_MAX_BONES][3];
    float q[LAMBDA_WEAPON_MAX_BONES][4];
    for (int i = 0; i < hdr->numbones; i++)
        calc_bone(frame, s, &pb[i], &panim[i], pos[i], q[i]);

    if (seq->motionbone >= 0 && seq->motionbone < hdr->numbones) {
        if (seq->motiontype & STUDIO_X) pos[seq->motionbone][0] = 0.0f;
        if (seq->motiontype & STUDIO_Y) pos[seq->motionbone][1] = 0.0f;
        if (seq->motiontype & STUDIO_Z) pos[seq->motionbone][2] = 0.0f;
    }

    for (int i = 0; i < hdr->numbones; i++) {
        matrix3x4 local;
        Matrix3x4_FromOriginQuat(local, q[i], pos[i]);
        if (pb[i].parent < 0)
            memcpy(bones[i], local, sizeof(local));
        else
            Matrix3x4_Concat(bones[i], bones[pb[i].parent], local);
    }
    return 1;
}

static void account_bbox(snapshot_t *s, const float p[3]) {
    for (int k = 0; k < 3; k++) {
        if (p[k] < s->bbmin[k]) s->bbmin[k] = p[k];
        if (p[k] > s->bbmax[k]) s->bbmax[k] = p[k];
    }
}

// Decode one mesh's tricmd list (tristrips/trifans) into the global triangle
// list. Vertices stay in their bone's local space (the GPU skins them); the
// bind pose is only used here to grow the bounding box. Winding follows GL's
// strip rule so faces stay consistently oriented in the emitted index list.
// Normals share the vertex's bone: verified over every stock v_*.mdl that
// normbone[ni] == vertbone[vi] for all tricmd entries, so a single bone index
// per vertex is exact.
static void bake_mesh(snapshot_t *s, const uint8_t *base, const mstudiomesh_t *mesh,
                      const float *verts, const uint8_t *vertbone,
                      const float *norms, const matrix3x4 *bind_bones, int numbones,
                      float inv_w, float inv_h) {
    const int16_t *cmd = (const int16_t *)(base + mesh->triindex);
    int n;
    while ((n = *cmd++)) {
        int fan = 0;
        if (n < 0) { fan = 1; n = -n; }

        // Emit this run's verts, remembering their global indices.
        uint32_t first = s->vcount;
        for (int k = 0; k < n; k++, cmd += 4) {
            int vi = cmd[0], ni = cmd[1];
            lambda_weapon_vertex_t v;
            int bone = vertbone[vi];
            if (bone < 0 || bone >= numbones) bone = 0;
            v.bone = (uint32_t)bone;
            memcpy(v.pos, &verts[vi*3], sizeof(v.pos));
            memcpy(v.normal, &norms[ni*3], sizeof(v.normal));
            float nl = sqrtf(v.normal[0]*v.normal[0] + v.normal[1]*v.normal[1] + v.normal[2]*v.normal[2]);
            if (nl > 1e-6f) { v.normal[0]/=nl; v.normal[1]/=nl; v.normal[2]/=nl; }
            v.uv[0] = cmd[2] * inv_w;
            v.uv[1] = cmd[3] * inv_h;
            push_vertex(s, &v);

            float world[3];
            Matrix3x4_Transform(bind_bones[bone], v.pos, world);
            account_bbox(s, world);
        }

        // Assemble triangles from the run.
        for (int k = 0; k + 2 < n; k++) {
            uint32_t a, b, c;
            if (fan) {
                a = first; b = first + k + 1; c = first + k + 2;
            } else if (k & 1) {
                a = first + k + 1; b = first + k; c = first + k + 2;
            } else {
                a = first + k; b = first + k + 1; c = first + k + 2;
            }
            push_index(s, a); push_index(s, b); push_index(s, c);
        }
    }
}

// ---------------------------------------------------------------------------
// Optional OBJ dump for off-device verification. Written to the engine
// basedir (cwd) whenever a new model is baked, posed at sequence 0 frame 0
// (the idle grip). Cheap, and only fires on model change while the external
// weapon is active.
// ---------------------------------------------------------------------------
static void dump_obj(const snapshot_t *s, const matrix3x4 *bones) {
    FILE *f = fopen("weapon_dump.obj", "w");
    if (!f) return;
    fprintf(f, "# LambdaVision weapon dump (modelindex=%d, seq 0 frame 0)\n", s->modelindex);
    for (uint32_t i = 0; i < s->vcount; i++) {
        float p[3];
        Matrix3x4_Transform(bones[s->vertices[i].bone], s->vertices[i].pos, p);
        fprintf(f, "v %.4f %.4f %.4f\n", p[0], p[1], p[2]);
    }
    for (uint32_t i = 0; i < s->vcount; i++)
        fprintf(f, "vt %.4f %.4f\n", s->vertices[i].uv[0], s->vertices[i].uv[1]);
    for (uint32_t i = 0; i + 2 < s->icount; i += 3)
        fprintf(f, "f %u/%u %u/%u %u/%u\n",
                s->indices[i]+1,   s->indices[i]+1,
                s->indices[i+1]+1, s->indices[i+1]+1,
                s->indices[i+2]+1, s->indices[i+2]+1);
    fclose(f);
    fprintf(stderr, "[lambda_weapon] dumped weapon_dump.obj (%u verts, %u tris)\n",
            s->vcount, s->icount / 3);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
static int g_weapon_active = 0;

int lambda_weapon_active(void) { return g_weapon_active; }

// Published by the client (cl_dll/entity.cpp) each frame in external mode.
extern float g_vr_weapon_light[3];

void lambda_weapon_get_light(float rgb[3]) {
    rgb[0] = g_vr_weapon_light[0];
    rgb[1] = g_vr_weapon_light[1];
    rgb[2] = g_vr_weapon_light[2];
}

static int name_ends_with(const char *name, const char *suffix) {
    size_t n = strnlen(name, MAXSTUDIONAME), s = strlen(suffix);
    return n >= s && strcmp(name + n - s, suffix) == 0;
}

// Right-hand bone: exact "Bip01 R Hand" first, else any bone whose name ends
// in " R Hand" (classic v_crossbow rigs "Xbow biped R Hand"). -1 if none.
static int find_right_hand_bone(const mstudiobone_t *pb, int numbones) {
    for (int i = 0; i < numbones; i++)
        if (strcmp(pb[i].name, "Bip01 R Hand") == 0) return i;
    for (int i = 0; i < numbones; i++)
        if (name_ends_with(pb[i].name, " R Hand")) return i;
    return -1;
}

// Nearest ancestor (including `bone` itself) whose name ends in "Hand", or -1
// when the chain reaches a root without passing through one — which is how a
// gun modelled on its own root bone (Box02, carbine, Reciever) reads.
static int nearest_hand_ancestor(const mstudiobone_t *pb, int numbones, int bone) {
    for (int guard = 0; bone >= 0 && bone < numbones && guard < LAMBDA_WEAPON_MAX_BONES; guard++) {
        if (name_ends_with(pb[bone].name, "Hand")) return bone;
        bone = pb[bone].parent;
    }
    return -1;
}

// Which hand bone to pin onto the player's tracked hand.
//
// Nearly every viewmodel is held in the right hand, but not all: the satchel
// charge is skinned entirely to "Bip01 L Hand" (and the classic v_satchel has
// no right-hand bone at all), so pinning the right hand put the charge ~50 cm
// away from the player's hand in the HD pack and ~1.5 m away in the classic
// one — i.e. invisible.
//
// So weight each hand by how much geometry hangs off it and prefer a clear
// winner. The shared Gordon-hands mesh contributes ~92 verts to each hand, so
// a hand that merely grips the weapon's far end (the SPAS-12's pump hand, 112
// vs 92) must NOT outvote the right hand — requiring twice the right hand's
// share separates that (1.2x) from a genuinely left-handed model (7x) with
// room to spare. Guns modelled on root bones contribute to neither hand and
// correctly leave the right hand winning by default.
static int choose_grip_bone(const uint8_t *base, const studiohdr_t *hdr, int body) {
    const mstudiobone_t *pb = (const mstudiobone_t *)(base + hdr->boneindex);
    const mstudiobodyparts_t *bp = (const mstudiobodyparts_t *)(base + hdr->bodypartindex);
    int right = find_right_hand_bone(pb, hdr->numbones);

    uint32_t counts[LAMBDA_WEAPON_MAX_BONES] = { 0 };
    int hand_of[LAMBDA_WEAPON_MAX_BONES];
    for (int i = 0; i < hdr->numbones; i++)
        hand_of[i] = nearest_hand_ancestor(pb, hdr->numbones, i);

    for (int b = 0; b < hdr->numbodyparts; b++) {
        int nmodels = bp[b].nummodels > 0 ? bp[b].nummodels : 1;
        int sel = bp[b].base ? (body / bp[b].base) % nmodels : 0;
        if (sel < 0 || sel >= nmodels) sel = 0;
        const mstudiomodel_t *sm =
            (const mstudiomodel_t *)(base + bp[b].modelindex) + sel;
        const uint8_t *vertbone = (const uint8_t *)(base + sm->vertinfoindex);
        for (int v = 0; v < sm->numverts; v++) {
            int bone = vertbone[v];
            if (bone < 0 || bone >= hdr->numbones) continue;
            int h = hand_of[bone];
            if (h >= 0) counts[h]++;
        }
    }

    int best = -1;
    uint32_t best_count = 0;
    for (int i = 0; i < hdr->numbones; i++) {
        if (counts[i] > best_count) { best = i; best_count = counts[i]; }
    }
    if (best < 0) return right;                 // no hand carries any geometry
    if (right < 0) return best;                 // no right hand in this rig
    if (best_count >= 2 * counts[right]) return best;
    return right;
}

// Bake `hdr` into the back snapshot and publish it. Returns 1 on success.
static int bake_model(const uint8_t *base, const studiohdr_t *hdr, int modelindex, int body) {
    if (hdr->numbones <= 0 || hdr->numbones > LAMBDA_WEAPON_MAX_BONES) {
        fprintf(stderr, "[lambda_weapon] modelindex=%d has %d bones (max %d)\n",
                modelindex, hdr->numbones, LAMBDA_WEAPON_MAX_BONES);
        return 0;
    }

    // Bake into the back buffer (the one that isn't currently active).
    int back = (g_active == 0) ? 1 : 0;
    snapshot_t *s = &g_snap[back];
    snapshot_reset(s);
    s->modelindex = modelindex;

    matrix3x4 bind[LAMBDA_WEAPON_MAX_BONES];
    compute_bind_bones(base, hdr, bind);

    bake_textures(s, base, hdr);

    // Bone table.
    const mstudiobone_t *pb = (const mstudiobone_t *)(base + hdr->boneindex);
    if ((uint32_t)hdr->numbones > s->bcap) {
        s->bcap = (uint32_t)hdr->numbones;
        s->bones = realloc(s->bones, s->bcap * sizeof(*s->bones));
    }
    for (int i = 0; i < hdr->numbones; i++) {
        memcpy(s->bones[i].name, pb[i].name, MAXSTUDIONAME);
        s->bones[i].name[MAXSTUDIONAME - 1] = '\0';
        s->bones[i].parent = pb[i].parent;
    }
    s->bcount = (uint32_t)hdr->numbones;
    s->hand_bone_index = choose_grip_bone(base, hdr, body);

    const int16_t *pskinref = (const int16_t *)(base + hdr->skinindex);
    const mstudiotexture_t *ptex = (const mstudiotexture_t *)(base + hdr->textureindex);
    const mstudiobodyparts_t *bp = (const mstudiobodyparts_t *)(base + hdr->bodypartindex);

    for (int b = 0; b < hdr->numbodyparts; b++) {
        // Select the active submodel for this bodypart from the body value.
        int nmodels = bp[b].nummodels > 0 ? bp[b].nummodels : 1;
        int sel = bp[b].base ? (body / bp[b].base) % nmodels : 0;
        if (sel < 0 || sel >= nmodels) sel = 0;
        const mstudiomodel_t *sm =
            (const mstudiomodel_t *)(base + bp[b].modelindex) + sel;

        const float   *verts    = (const float *)(base + sm->vertindex);
        const uint8_t *vertbone = (const uint8_t *)(base + sm->vertinfoindex);
        const float   *norms    = (const float *)(base + sm->normindex);
        const mstudiomesh_t *meshes = (const mstudiomesh_t *)(base + sm->meshindex);

        for (int m = 0; m < sm->nummesh; m++) {
            int texidx = 0;
            uint32_t flags = 0;
            if (hdr->numtextures > 0) {
                texidx = pskinref[meshes[m].skinref];
                if (texidx < 0 || texidx >= hdr->numtextures) texidx = 0;
                flags = ptex[texidx].flags;
            }
            float inv_w = 1.0f, inv_h = 1.0f;
            if (s->tcount && s->textures[texidx].width)  inv_w = 1.0f / (float)s->textures[texidx].width;
            if (s->tcount && s->textures[texidx].height) inv_h = 1.0f / (float)s->textures[texidx].height;

            uint32_t idx0 = s->icount;
            bake_mesh(s, base, &meshes[m], verts, vertbone, norms, bind, hdr->numbones, inv_w, inv_h);

            lambda_weapon_submesh_t *ss = push_submesh(s);
            ss->index_offset = idx0;
            ss->index_count  = s->icount - idx0;
            ss->texture      = (uint32_t)texidx;
            ss->flags        = flags;
        }
    }

    if (s->vcount == 0) {
        fprintf(stderr, "[lambda_weapon] modelindex=%d produced no geometry\n", modelindex);
    }

    // Publish: bump generation and flip the active buffer under the lock.
    // Seed the pose with sequence 0 / frame 0 so a reader that uploads this
    // generation always finds a matching pose, even before the next tick.
    matrix3x4 pose0[LAMBDA_WEAPON_MAX_BONES];
    compute_pose_bones(base, hdr, 0, 0.0f, pose0);

    pthread_mutex_lock(&g_mtx);
    s->generation = ++g_generation;
    g_active = back;
    g_pose.generation = s->generation;
    g_pose.bone_count = (uint32_t)hdr->numbones;
    g_pose.sequence = 0;
    g_pose.frame = 0.0f;
    memcpy(g_pose.bones, pose0, sizeof(matrix3x4) * (size_t)hdr->numbones);
    pthread_mutex_unlock(&g_mtx);

    fprintf(stderr,
        "[lambda_weapon] baked modelindex=%d gen=%u verts=%u tris=%u submeshes=%u "
        "textures=%u bones=%u handbone=%d seqs=%d bbox=[%.1f %.1f %.1f]..[%.1f %.1f %.1f]\n",
        modelindex, g_generation, s->vcount, s->icount/3, s->scount, s->tcount,
        s->bcount, s->hand_bone_index, hdr->numseq,
        s->bbmin[0], s->bbmin[1], s->bbmin[2], s->bbmax[0], s->bbmax[1], s->bbmax[2]);

    dump_obj(s, pose0);
    return 1;
}

void lambda_weapon_extract(void) {
    void *hdrp = g_vr_weapon_hdr;
    int   modelindex = g_vr_weapon_modelindex;
    int   body = g_vr_weapon_body;

    g_weapon_active = (hdrp != NULL);                   // published this frame?
    if (!hdrp) return;                                  // no external weapon

    const studiohdr_t *hdr = (const studiohdr_t *)hdrp;
    const uint8_t *base = (const uint8_t *)hdrp;

    if (hdrp != g_last_hdr || modelindex != g_last_modelindex || body != g_last_body) {
        g_last_hdr = hdrp; g_last_modelindex = modelindex; g_last_body = body;
        g_last_valid = 0;
        if (hdr->ident != IDSTUDIOHEADER || hdr->version != STUDIO_VERSION) {
            fprintf(stderr, "[lambda_weapon] bad studio header (ident=%d ver=%d)\n",
                    hdr->ident, hdr->version);
            return;
        }
        g_last_valid = bake_model(base, hdr, modelindex, body);
    }
    if (!g_last_valid) return;

    // Per-tick pose for the published animation state.
    int sequence = g_vr_weapon_sequence;
    if (sequence < 0 || sequence >= hdr->numseq) sequence = 0;
    float f = 0.0f;
    if (hdr->numseq > 0) {
        const mstudioseqdesc_t *seq = (const mstudioseqdesc_t *)(base + hdr->seqindex) + sequence;
        f = estimate_frame(seq, g_vr_weapon_frame, g_vr_weapon_animtime,
                           g_vr_weapon_framerate, g_vr_weapon_time);
    }
    matrix3x4 bones[LAMBDA_WEAPON_MAX_BONES];
    compute_pose_bones(base, hdr, sequence, f, bones);

    pthread_mutex_lock(&g_mtx);
    g_pose.generation = g_generation;
    g_pose.bone_count = (uint32_t)hdr->numbones;
    g_pose.sequence = sequence;
    g_pose.frame = f;
    memcpy(g_pose.bones, bones, sizeof(matrix3x4) * (size_t)hdr->numbones);
    pthread_mutex_unlock(&g_mtx);
}

uint32_t lambda_weapon_generation(void) {
    return g_generation;
}

uint32_t lambda_weapon_lock(lambda_weapon_mesh_t *out) {
    pthread_mutex_lock(&g_mtx);
    if (g_active < 0) {
        memset(out, 0, sizeof(*out));
        out->hand_bone_index = -1;
        return 0;
    }
    const snapshot_t *s = &g_snap[g_active];
    out->generation   = s->generation;
    out->vertex_count = s->vcount;   out->vertices  = s->vertices;
    out->index_count  = s->icount;   out->indices   = s->indices;
    out->submesh_count= s->scount;   out->submeshes = s->submeshes;
    out->texture_count= s->tcount;   out->textures  = s->textures;
    out->bone_count   = s->bcount;   out->bones     = s->bones;
    out->hand_bone_index = s->hand_bone_index;
    memcpy(out->bbmin, s->bbmin, sizeof(out->bbmin));
    memcpy(out->bbmax, s->bbmax, sizeof(out->bbmax));
    out->modelindex = s->modelindex;
    return s->generation;
}

void lambda_weapon_unlock(void) {
    pthread_mutex_unlock(&g_mtx);
}

uint32_t lambda_weapon_copy_pose(lambda_weapon_pose_t *out) {
    pthread_mutex_lock(&g_mtx);
    if (g_pose.generation == 0) {
        pthread_mutex_unlock(&g_mtx);
        memset(out, 0, sizeof(*out));
        return 0;
    }
    // Header + only the live bones; the tail of the array is left untouched.
    out->generation = g_pose.generation;
    out->bone_count = g_pose.bone_count;
    out->sequence   = g_pose.sequence;
    out->frame      = g_pose.frame;
    memcpy(out->bones, g_pose.bones, sizeof(g_pose.bones[0]) * g_pose.bone_count);
    pthread_mutex_unlock(&g_mtx);
    return out->generation;
}
