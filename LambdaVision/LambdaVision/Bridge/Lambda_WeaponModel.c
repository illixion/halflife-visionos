// Lambda_WeaponModel.c — see Lambda_WeaponModel.h.
//
// Walks a resident GoldSrc studiohdr_t and bakes its bind pose into a triangle
// mesh. The studio struct layout and the bone math are replicated locally
// (rather than pulling engine headers onto the app target's include path) so
// this stays a self-contained unit; the layouts are the frozen v10 format and
// the math is copied verbatim from the engine's matrixlib/mathlib so the bind
// pose matches what R_StudioSetupBones would produce.

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

// ---------------------------------------------------------------------------
// Bone math, copied verbatim from the engine (public/matrixlib.c) and
// gl_studio.c's studio-quaternion convention, so the bind pose is identical.
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

static void Matrix3x4_Rotate(const matrix3x4 m, const float v[3], float out[3]) {
    out[0] = v[0]*m[0][0] + v[1]*m[0][1] + v[2]*m[0][2];
    out[1] = v[0]*m[1][0] + v[1]*m[1][1] + v[2]*m[1][2];
    out[2] = v[0]*m[2][0] + v[1]*m[2][1] + v[2]*m[2][2];
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
    float hand_bone[12]; int has_hand_bone;
    float bbmin[3], bbmax[3];
    int   modelindex;
    uint32_t generation;
} snapshot_t;

static snapshot_t      g_snap[2];
static int             g_active = -1;          // index of the readable snapshot
static uint32_t        g_generation = 0;
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;

// Change key so we only re-bake when the model actually changes.
static void   *g_last_hdr = NULL;
static int      g_last_modelindex = -1;
static int      g_last_body = -1;

// Published by the hlsdk client (cl_dll/view.cpp) each frame when
// vr_weapon_external is on; read here on the same (GL worker) thread.
extern void *g_vr_weapon_hdr;
extern int   g_vr_weapon_modelindex;
extern int   g_vr_weapon_body;

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
    s->vcount = s->icount = s->scount = s->tcount = 0;
    s->texbytes = 0;
    s->has_hand_bone = 0;
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
// Bind-pose bone world matrices (model space; entity transform = identity).
// ---------------------------------------------------------------------------
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

static void account_bbox(snapshot_t *s, const float p[3]) {
    for (int k = 0; k < 3; k++) {
        if (p[k] < s->bbmin[k]) s->bbmin[k] = p[k];
        if (p[k] > s->bbmax[k]) s->bbmax[k] = p[k];
    }
}

// Decode one mesh's tricmd list (tristrips/trifans) into the global triangle
// list, baking each trivert through its bone. Winding follows GL's strip rule
// so faces stay consistently oriented in the emitted index list.
static void bake_mesh(snapshot_t *s, const uint8_t *base, const mstudiomesh_t *mesh,
                      const float *verts, const uint8_t *vertbone,
                      const float *norms, const uint8_t *normbone,
                      const matrix3x4 *bones, float inv_w, float inv_h) {
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
            Matrix3x4_Transform(bones[vertbone[vi]], &verts[vi*3], v.pos);
            Matrix3x4_Rotate(bones[normbone ? normbone[ni] : vertbone[vi]], &norms[ni*3], v.normal);
            // normalize normal
            float nl = sqrtf(v.normal[0]*v.normal[0] + v.normal[1]*v.normal[1] + v.normal[2]*v.normal[2]);
            if (nl > 1e-6f) { v.normal[0]/=nl; v.normal[1]/=nl; v.normal[2]/=nl; }
            v.uv[0] = cmd[2] * inv_w;
            v.uv[1] = cmd[3] * inv_h;
            push_vertex(s, &v);
            account_bbox(s, v.pos);
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
// Optional OBJ dump for off-device verification (Phase 1). Written to the
// engine basedir (cwd) whenever a new model is baked. Cheap, and only fires on
// model change while the external weapon is active.
// ---------------------------------------------------------------------------
static void dump_obj(const snapshot_t *s) {
    FILE *f = fopen("weapon_dump.obj", "w");
    if (!f) return;
    fprintf(f, "# LambdaVision weapon bind-pose dump (modelindex=%d)\n", s->modelindex);
    for (uint32_t i = 0; i < s->vcount; i++)
        fprintf(f, "v %.4f %.4f %.4f\n", s->vertices[i].pos[0], s->vertices[i].pos[1], s->vertices[i].pos[2]);
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

void lambda_weapon_extract(void) {
    void *hdrp = g_vr_weapon_hdr;
    int   modelindex = g_vr_weapon_modelindex;
    int   body = g_vr_weapon_body;

    g_weapon_active = (hdrp != NULL);                   // published this frame?
    if (!hdrp) return;                                  // no external weapon
    if (hdrp == g_last_hdr && modelindex == g_last_modelindex && body == g_last_body)
        return;                                         // unchanged since last bake

    const studiohdr_t *hdr = (const studiohdr_t *)hdrp;
    const uint8_t *base = (const uint8_t *)hdrp;
    if (hdr->ident != IDSTUDIOHEADER || hdr->version != STUDIO_VERSION) {
        fprintf(stderr, "[lambda_weapon] bad studio header (ident=%d ver=%d)\n",
                hdr->ident, hdr->version);
        g_last_hdr = hdrp; g_last_modelindex = modelindex; g_last_body = body;
        return;
    }

    // Bake into the back buffer (the one that isn't currently active).
    int back = (g_active == 0) ? 1 : 0;
    snapshot_t *s = &g_snap[back];
    snapshot_reset(s);
    s->modelindex = modelindex;

    matrix3x4 *bones = (matrix3x4 *)malloc(sizeof(matrix3x4) * (hdr->numbones > 0 ? hdr->numbones : 1));
    compute_bind_bones(base, hdr, bones);

    bake_textures(s, base, hdr);

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
        const uint8_t *normbone = sm->norminfoindex ? (const uint8_t *)(base + sm->norminfoindex) : NULL;
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
            bake_mesh(s, base, &meshes[m], verts, vertbone, norms, normbone, bones, inv_w, inv_h);

            lambda_weapon_submesh_t *ss = push_submesh(s);
            ss->index_offset = idx0;
            ss->index_count  = s->icount - idx0;
            ss->texture      = (uint32_t)texidx;
            ss->flags        = flags;
        }
    }

    // Hand-bone bind transform for grip alignment on the Swift side.
    {
        const mstudiobone_t *pb = (const mstudiobone_t *)(base + hdr->boneindex);
        for (int i = 0; i < hdr->numbones; i++) {
            if (strcmp(pb[i].name, "Bip01 R Hand") == 0) {
                memcpy(s->hand_bone, bones[i], sizeof(s->hand_bone));
                s->has_hand_bone = 1;
                break;
            }
        }
    }

    free(bones);

    if (s->vcount == 0) {
        fprintf(stderr, "[lambda_weapon] modelindex=%d produced no geometry\n", modelindex);
    }

    // Publish: bump generation and flip the active buffer under the lock.
    pthread_mutex_lock(&g_mtx);
    s->generation = ++g_generation;
    g_active = back;
    pthread_mutex_unlock(&g_mtx);

    fprintf(stderr,
        "[lambda_weapon] baked modelindex=%d gen=%u verts=%u tris=%u submeshes=%u "
        "textures=%u handbone=%d bbox=[%.1f %.1f %.1f]..[%.1f %.1f %.1f]\n",
        modelindex, g_generation, s->vcount, s->icount/3, s->scount, s->tcount,
        s->has_hand_bone, s->bbmin[0], s->bbmin[1], s->bbmin[2],
        s->bbmax[0], s->bbmax[1], s->bbmax[2]);

    dump_obj(s);

    g_last_hdr = hdrp; g_last_modelindex = modelindex; g_last_body = body;
}

uint32_t lambda_weapon_generation(void) {
    return g_generation;
}

uint32_t lambda_weapon_lock(lambda_weapon_mesh_t *out) {
    pthread_mutex_lock(&g_mtx);
    if (g_active < 0) {
        memset(out, 0, sizeof(*out));
        return 0;
    }
    const snapshot_t *s = &g_snap[g_active];
    out->generation   = s->generation;
    out->vertex_count = s->vcount;   out->vertices  = s->vertices;
    out->index_count  = s->icount;   out->indices   = s->indices;
    out->submesh_count= s->scount;   out->submeshes = s->submeshes;
    out->texture_count= s->tcount;   out->textures  = s->textures;
    memcpy(out->hand_bone, s->hand_bone, sizeof(out->hand_bone));
    out->has_hand_bone = s->has_hand_bone;
    memcpy(out->bbmin, s->bbmin, sizeof(out->bbmin));
    memcpy(out->bbmax, s->bbmax, sizeof(out->bbmax));
    out->modelindex = s->modelindex;
    return s->generation;
}

void lambda_weapon_unlock(void) {
    pthread_mutex_unlock(&g_mtx);
}
