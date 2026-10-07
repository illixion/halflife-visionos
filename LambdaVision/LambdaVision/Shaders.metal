//
//  Shaders.metal
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
    ushort eye;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant ViewProjectionArray & viewProjectionArray [[ buffer(BufferIndexViewProjection) ]])
{
    ColorInOut out;
    float4 position = float4(in.position, 1.0);
    out.position = viewProjectionArray.viewProjectionMatrix[amp_id] * uniforms.modelMatrix * position;
    out.texCoord = in.texCoord;
    out.eye = amp_id;
    return out;
}

// Fullscreen-triangle. 3 verts, no buffers. Each eye's render already
// matches that eye's AVP frustum, so plastering it across the viewport is
// the geometrically-correct display path.
vertex ColorInOut fullscreenVertexShader(uint vid [[vertex_id]],
                                         ushort amp_id [[amplification_id]])
{
    ColorInOut out;
    float2 pos = float2((vid == 1) ? 3.0 : -1.0,
                        (vid == 2) ? 3.0 : -1.0);
    // Reverse-Z depth (drawable clear=0, compare=greater). The compositor
    // uses the drawable's depth buffer for positional reprojection: z=1
    // (near plane) tells it the whole image sits millimeters from the
    // viewer's face, so every head translation produces a huge corrective
    // warp — visible as pulsating/jelly. Emit a small value (≈far) instead;
    // TODO: resolve the engine's real per-pixel depth for exact reprojection.
    out.position = float4(pos, 0.0001, 1.0);
    out.texCoord = pos * 0.5 + 0.5;
    out.eye = amp_id;
    return out;
}

// FXAA (compact quality variant, Lottes). The engine has no AA of its own
// (GL MSAA through ANGLE costs ~7 ms/pair) and the composite pass bilinearly
// upsamples a sub-logical engine render, so edges stairstep twice over.
//
// The kernel lives here as an inline helper with two entry points:
//   • fragmentShaderFXAA — the DEFAULT path. Runs inside the composite pass,
//     so edge smoothing costs zero extra passes and zero intermediate
//     textures (only the neighbourhood taps).
//   • fxaaFragmentShader — the standalone pass that feeds the (currently
//     hidden) MetalFX upscale chain. Kept compiled; see Renderer.
//
// Every tap is a symmetric pair about `uv`, so the filter is invariant under
// a vertical mirror of the sample space: the two entry points may disagree
// on the V flip and still produce identical output.
static inline half fxaaLuma(half3 c)
{
    return dot(c, half3(0.299h, 0.587h, 0.114h));
}

// `px` must be ONE TEXEL of the sampled texture (engine resolution when the
// raw colorMap is bound), never a drawable-resolution pixel — the edges being
// smoothed are engine-raster edges.
static inline half3 fxaaResolve(texture2d_array<half> tex, sampler s,
                                float2 uv, float2 px, ushort eye,
                                half3 rgbM)
{
    half lM  = fxaaLuma(rgbM);
    half lNW = fxaaLuma(tex.sample(s, uv + float2(-px.x, -px.y), eye).rgb);
    half lNE = fxaaLuma(tex.sample(s, uv + float2( px.x, -px.y), eye).rgb);
    half lSW = fxaaLuma(tex.sample(s, uv + float2(-px.x,  px.y), eye).rgb);
    half lSE = fxaaLuma(tex.sample(s, uv + float2( px.x,  px.y), eye).rgb);

    half lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    half lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));

    // Early out on low local contrast (flat area — nothing to smooth). Most
    // pixels take this branch, which is what keeps the folded cost low.
    if (lMax - lMin < max(0.0312h, lMax * 0.125h))
        return rgbM;

    float2 dir = float2(-float((lNW + lNE) - (lSW + lSE)),
                         float((lNW + lSW) - (lNE + lSE)));
    float dirReduce = max(float(lNW + lNE + lSW + lSE) * 0.25 * 0.125, 1.0 / 128.0);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, -8.0, 8.0) * px;

    half3 rgbA = 0.5h * (tex.sample(s, uv + dir * (1.0 / 3.0 - 0.5), eye).rgb
                       + tex.sample(s, uv + dir * (2.0 / 3.0 - 0.5), eye).rgb);
    half3 rgbB = rgbA * 0.5h + 0.25h * (tex.sample(s, uv + dir * -0.5, eye).rgb
                                      + tex.sample(s, uv + dir *  0.5, eye).rgb);
    half lB = fxaaLuma(rgbB);
    return (lB < lMin || lB > lMax) ? rgbA : rgbB;
}

fragment float4 fxaaFragmentShader(ColorInOut in [[stage_in]],
                                   texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    // Flip V: the fullscreen-triangle texCoord carries one implicit
    // vertical flip (GL bottom-up FBO vs Metal top-down render target),
    // which the display pass already accounts for. Without this flip the
    // FXAA pass would apply it a second time, writing fxaaMap upside down.
    // Flipping here keeps fxaaMap in colorMap's orientation so the display
    // shader works identically with either texture.
    const float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    const float2 px = float2(1.0 / colorMap.get_width(), 1.0 / colorMap.get_height());
    half3 rgbM = colorMap.sample(s, uv, in.eye).rgb;
    return float4(float3(fxaaResolve(colorMap, s, uv, px, in.eye, rgbM)), 1.0);
}

// Output dither for the composite. The engine image is 16-bit, so a
// dark gradient arrives smooth; the drawable is what rounds it, and at
// 8 bits a dim vent spans a handful of codes that read as flat splotches.
// Half a code of fixed per-pixel noise before that rounding turns the
// steps into grain far finer than a pixel. The noise is added in the
// drawable's STORED encoding (an _srgb drawable quantizes after the
// hardware encode), and scaled to its code size; a float drawable needs
// none. Set per pipeline from the layer's colour format (Renderer).
// Optional: fragmentShader is also the template pipeline's fragment
// function (buildRenderPipeline), specialized there with no values, which
// must compile to no dither. Any function using these must still be made
// with makeFunction(name:constantValues:) — plain makeFunction(name:) fails
// pipeline validation (crashed at launch).
constant bool  kOutputSRGBValue [[function_constant(20)]];
constant float kOutputLSBValue  [[function_constant(21)]]; // one stored code; 0 = no dither
constant bool  kOutputSRGB = is_function_constant_defined(kOutputSRGBValue) && kOutputSRGBValue;
constant float kOutputLSB  = is_function_constant_defined(kOutputLSBValue) ? kOutputLSBValue : 0.0;

static inline float3 srgbEncode(float3 c)
{
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static inline float3 srgbDecode(float3 c)
{
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static inline float3 ditherOutput(float3 c, float2 pixel)
{
    if (kOutputLSB <= 0.0)
        return c;
    // interleaved gradient noise (Jimenez 2014): fixed per physical pixel,
    // so it cannot shimmer between frames or between the two eyes' passes
    const float n = fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715)))) - 0.5;
    c = max(c, 0.0);
    if (kOutputSRGB)
        return srgbDecode(max(srgbEncode(c) + n * kOutputLSB, 0.0));
    return max(c + n * kOutputLSB, 0.0);
}

// HDR headroom test (Settings → Diagnostics). No SDK API reports how far
// above SDR white (1.0) the display goes; Oneiros measured about one stop
// (0.5 < 1 < 2, and 2 = 4 = 8) with large grey bands, which an OLED may
// dim as a whole by area (its brightness limiter). So two layouts over
// black, each a row of test values over a row of 1.0 references:
//   1  small dots — a point light's area, the case highlights will be
//   2  patches filling the view — the worst case for the limiter
// Values left to right: 0.5 1 1.25 1.5 1.75 2 2.5 3 4. Written raw, past
// the decode and the dither, so the drawable receives exactly these.
constant float kHDRTestValues[9] = { 0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0 };

static inline float3 hdrTestPattern(float2 uv, float mode, float aspect)
{
    const int n = 9;
    if (mode > 1.5) {
        const int i = clamp(int(uv.x * n), 0, n - 1);
        // a thin black gap between patches keeps them tellable apart
        const float f = fract(uv.x * n);
        if (f < 0.04 || f > 0.96 || abs(uv.y - 0.5) < 0.01)
            return 0.0;
        return uv.y > 0.5 ? kHDRTestValues[i] : 1.0;
    }
    const float spacing = 0.06;                     // centre to centre, view widths
    const float radius = 0.012;                     // view heights: ~1.2° on the AVP
    const float x0 = 0.5 - spacing * (n - 1) * 0.5;
    const int i = clamp(int(round((uv.x - x0) / spacing)), 0, n - 1);
    const float2 d = float2((uv.x - (x0 + spacing * i)) * aspect, 0.0);
    const float dTop = length(d + float2(0.0, uv.y - 0.54));
    const float dRef = length(d + float2(0.0, uv.y - 0.46));
    if (dTop < radius) return kHDRTestValues[i];
    if (dRef < radius) return 1.0;
    return 0.0;
}

// ---- Glass (modern lighting tier 1; Renderer.glassReflections) -----------
// The engine marks glass in the stencil aspect of the depth texture we gave
// it (r_vrglass, ref/gl gl_rsurf.c R_VRGlass*): 16 + the row of that eye's
// glass plane table (DisplayParams.glassPlanes) holding the surface's world
// plane. Glass in GoldSrc writes no depth, so the plane is what places the
// pixel: the eye's view ray (from the view the engine drew it with, glassEye)
// meets it at P, in the world, the same point for both eyes.
//
// The reflection is Schlick's Fresnel over an environment probe: six 90°
// views of the room the engine renders from the player's head, one face per
// frame, while glass is in sight (GlassProbe.swift, ref/gl R_VRProbeFace).
// The probe is fixed in the world, so what a pane reflects no longer depends
// on where the eye looks — the old lookup projected the reflected ray into the
// eye's own frame and fell back to a flat colour where it left the frame,
// which popped with gaze and differed between the eyes. The probe also keeps
// its depth, so the lookup is parallax-corrected: the reflected ray from P is
// walked to where it meets the probe's surroundings (probeLookup), and each
// eye sees the mirrored room at its true distance. Two probes are blended
// across a refresh (probeMix.x), so a new capture fades in rather than pops.
// What is seen through the pane takes on its tint (glassTint). Water rows
// (r_vrwater, the warp surfaces) use the same probe with their own Fresnel and
// an animated ripple (waterRipple), and none from below the surface. The
// reflectance is exaggerated on purpose (Settings "Reflection strength", plus
// a little head-on): physically correct glass at 4% vanishes in this art.
//
// Per glass pixel: one stencil read, then three depth reads and a colour
// sample per probe (two probes only while a refresh fades in). None elsewhere.
constant bool kGlassValue [[function_constant(22)]];
constant bool kGlass = is_function_constant_defined(kGlassValue) && kGlassValue;

// The probe face a world (xash) direction falls on, and where in it (each
// axis −1…1, v up; GL rows are bottom-up, so uv = ab·0.5 + 0.5 unflipped).
// Faces 0–5 look along +X +Y −X −Y +Z −Z, right/up as AngleVectors gives
// them for the angles R_VRProbeFace renders each with.
static inline uint probeFace(float3 d, thread float2 &ab)
{
    const float3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z) {
        if (d.x > 0.0) { ab = float2(-d.y, d.z) / a.x; return 0; }
        ab = float2(d.y, d.z) / a.x; return 2;
    }
    if (a.y >= a.z) {
        if (d.y > 0.0) { ab = float2(d.x, d.z) / a.y; return 1; }
        ab = float2(-d.x, d.z) / a.y; return 3;
    }
    if (d.z > 0.0) { ab = float2(-d.y, -d.x) / a.z; return 4; }
    ab = float2(-d.y, d.x) / a.z; return 5;
}

// What the probe saw along the ray from P in direction r (unit). probe.xyz is
// where it was captured, probe.w its first slice; clip = zNear, zFar.
// `iterations` 0 is the plain direction lookup (the room taken as infinitely
// far); each step re-reads the probe's distance where the current hit guess
// lies and moves the hit to the ray's crossing of that sphere about the probe.
static inline float3 probeLookup(texture2d_array<half> probeColor, depth2d_array<float> probeDepth,
                                 sampler s, float3 P, float3 r, float4 probe, float2 clip,
                                 int iterations)
{
    const uint size = probeDepth.get_width();
    const uint base = uint(probe.w);
    const float3 PC = P - probe.xyz;
    const float b = dot(r, PC), c0 = dot(PC, PC);
    const float n = clip.x, f = clip.y;
    float3 dir = r;
    float2 ab;
    for (int i = 0; i < iterations; i++) {
        const uint face = probeFace(dir, ab);
        const uint2 texel = min(uint2((ab * 0.5 + 0.5) * float(size)), uint2(size - 1));
        const float ndc = probeDepth.read(texel, base + face) * 2.0 - 1.0;
        // GL depth → distance along the face's axis → along the texel's ray
        const float D = 2.0 * n * f / ((f + n) - ndc * (f - n)) * sqrt(1.0 + dot(ab, ab));
        const float t = -b + sqrt(max(b * b - (c0 - D * D), 0.0));
        dir = PC + r * max(t, 1.0);
    }
    const uint face = probeFace(dir, ab);
    return float3(probeColor.sample(s, ab * 0.5 + 0.5, base + face).rgb);
}

// What a probe saw along a direction from its origin: GL depth → distance.
static inline float probeDistance(depth2d_array<float> probeDepth, float3 dir, uint base, uint size,
                                  float n, float f)
{
    float2 ab;
    const uint face = probeFace(dir, ab);
    const uint2 texel = min(uint2((ab * 0.5 + 0.5) * float(size)), uint2(size - 1));
    const float ndc = probeDepth.read(texel, base + face) * 2.0 - 1.0;
    return 2.0 * n * f / ((f + n) - ndc * (f - n)) * sqrt(1.0 + dot(ab, ab));
}

// The reflection the composite takes from a probe: probeLookup's walk, with
// a fallback where the walk has not settled. A probe is recaptured only after
// the head moves GlassProbeSchedule.refreshDistance or 30 s pass, so it is
// usually taken from somewhere else, and a walk from there can jump across
// one of its depth edges at every step: the hit then lands on different
// surfaces in neighbouring pixels (shards, saw teeth, faint diagonal stripes;
// the headset showed the c1a2 sink basin full of poster shards until the next
// recapture, 15–30 s later, and teeth on the sink's falling sheet). Where the
// last step still moved the hit, the plain direction lookup (soft but
// continuous) takes over, fully once it moved half the distance.
static inline float3 probeReflect(texture2d_array<half> probeColor, depth2d_array<float> probeDepth,
                                  sampler s, float3 P, float3 r, float4 probe, float2 clip, int iterations)
{
    const uint size = probeDepth.get_width();
    const uint base = uint(probe.w);
    const float3 PC = P - probe.xyz;
    const float b = dot(r, PC), c0 = dot(PC, PC);
    float3 dir = r;
    float t = 0.0, tPrev = 0.0;
    for (int i = 0; i < iterations; i++) {
        const float D = probeDistance(probeDepth, dir, base, size, clip.x, clip.y);
        tPrev = t;
        t = -b + sqrt(max(b * b - (c0 - D * D), 0.0));
        dir = PC + r * max(t, 1.0);
    }
    float2 ab;
    uint face = probeFace(dir, ab);
    float3 rgb = float3(probeColor.sample(s, ab * 0.5 + 0.5, base + face).rgb);
    if (iterations >= 2) {
        const float settled = 1.0 - smoothstep(0.1 * t + 4.0, 0.5 * t + 16.0, abs(t - tPrev));
        if (settled < 1.0) {
            face = probeFace(r, ab);
            rgb = mix(float3(probeColor.sample(s, ab * 0.5 + 0.5, base + face).rgb), rgb, settled);
        }
    }
    return rgb;
}

// The view ray through engine-image uv for this eye, in xash world axes.
static inline float3 glassViewRay(float2 uv, ushort eye, constant DisplayParams &p)
{
    // GL eye space: x right, y up, the eye looking down −z; uv.y = 0 is the
    // bottom row (the engine image is bottom-up, sampled unflipped).
    const float4 t = p.eyeTangents[eye];   // left, right, top, bottom
    const float2 v = float2(mix(-t.x, t.y, uv.x), mix(-t.w, t.z, uv.y));
    return normalize(p.glassEye[eye][1].xyz + v.x * p.glassEye[eye][2].xyz + v.y * p.glassEye[eye][3].xyz);
}

// Water (r_vrwater rows): the plane's normal tilted by fine travelling
// sine waves of the world point, tuned to a calm lake (the headset showed the
// first, 11–39-unit waves at slope 0.12 as "thick, like an oil spill"):
// wavelengths of a few units, slow, six directions so no pattern shows, and a
// small slope (p.water.w; Settings "Water ripples"). GoldSrc's water texture
// already warps, so this adds only a little. The tilt is biased toward the
// view direction along the surface, which breaks reflections up vertically
// (streaks) rather than sideways, and it calms with distance and toward
// grazing angles, as a lake does toward the horizon. A function of the world
// point and time (the view bias differs between the eyes only by their
// separation's angle), so both eyes see the same ripple at the same spot.
static inline float3 waterRipple(float3 n, float3 P, float3 d, float dist, float cosTheta, float pixTan,
                                 constant DisplayParams &p)
{
    const float slope = p.water.w / (1.0 + dist / 120.0) * saturate(cosTheta * 4.0);
    if (slope <= 0.0)
        return n;
    const float3 t1 = normalize(cross(n, abs(n.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0)));
    const float3 t2 = cross(n, t1);
    const float scale = max(p.reflectExtra.w, 0.05);
    const float2 q = float2(dot(P, t1), dot(P, t2)) / scale;
    const float t = p.reflectExtra.z;
    // the view direction along the surface, and across it
    const float3 along = normalize(d - dot(d, n) * n + 1e-5 * t1);
    const float3 across = cross(n, along);
    const float2 alongB = float2(dot(along, t1), dot(along, t2)), acrossB = float2(dot(across, t1), dot(across, t2));
    const float cosV = max(cosTheta, 0.05);
    // direction (unit), spatial frequency (rad / unit), speed (rad / s)
    const float4 waves[6] = { float4( 0.89,  0.45, 0.95, 0.40), float4(-0.31,  0.95, 1.21, 0.55),
                              float4( 0.98, -0.20, 1.53, 0.65), float4(-0.77, -0.64, 1.87, 0.80),
                              float4( 0.20, -0.98, 2.23, 0.95), float4(-0.95,  0.31, 2.61, 1.10) };
    const float amp[6] = { 0.26, 0.22, 0.18, 0.14, 0.11, 0.09 };
    float2 g = 0.0;
    for (int i = 0; i < 6; i++) {
        // Band limit (the headset showed fine hatching): the wave's period
        // on screen, in engine pixels — foreshortened along the view by the
        // grazing angle — fades it out between 5 and 2.5 pixels, and its
        // tilt is capped so the mirror's ripple offset never folds over
        // (offset gradient under 1: tilt ≤ 0.08 · period in px · pixTan).
        const float2 k = waves[i].xy;
        const float lambda = 6.2831853 * scale / waves[i].z;
        const float screenFreq = dist / lambda * length(float2(dot(k, alongB) / cosV, dot(k, acrossB)));
        const float periodPx = 1.0 / max(screenFreq * pixTan, 1e-6);
        const float band = saturate(periodPx / 2.5 - 1.0);
        if (band <= 0.0)
            continue;                        // no cos for a wave too fine to show
        const float a = min(slope * amp[i], 0.08 * periodPx * pixTan) * band;
        g += a * k * cos(dot(k, q) * waves[i].z + waves[i].w * t);
    }
    const float3 tilt = g.x * t1 + g.y * t2;
    // along the view (vertical on screen) in full, across it a quarter
    return normalize(n - (dot(tilt, along) * along + 0.25 * dot(tilt, across) * across));
}

static inline float3 glassShade(float3 rgb, float2 uv, ushort eye,
                                texture2d_array<uint> engineStencil, depth2d_array<float> engineDepth,
                                texture2d_array<half> probeColor, depth2d_array<float> probeDepth,
                                texture2d_array<half> sharpWater,
                                sampler s, constant DisplayParams &p)
{
    // Settings → Diagnostics "Water mirror view" 3: the sharp-water target
    // over the whole view (magenta = empty), to see what the mirror holds
    if (p.waterDebug.x > 2.5) {
        const half4 c = sharpWater.sample(s, uv, eye);
        return c.a > 0.004h ? float3(c.rgb) / float(c.a) : float3(0.3, 0.0, 0.3);
    }
    const uint2 size = uint2(engineStencil.get_width(), engineStencil.get_height());
    const uint code = engineStencil.read(min(uint2(uv * float2(size)), size - 1), eye).r;
    if (code < 16 || code > 239)
        return rgb;
    const uint row = code - 16;
    const bool water = (p.glassKinds[eye][row >> 7][(row >> 5) & 3] >> (row & 31)) & 1;
    const float4 plane = p.glassPlanes[eye][row];
    const float3 E = p.glassEye[eye][0].xyz;
    const float3 d = glassViewRay(uv, eye, p);
    float3 n = plane.xyz;
    const float nd = dot(n, d);
    if (abs(nd) < 1e-4)
        return rgb;
    const float side = dot(n, E) - plane.w;
    // water's plane faces up out of it: from below (underwater) no reflection
    if (water && side <= 0.0)
        return rgb;
    const float dist = max(-side / nd, 0.0);
    const float3 P = E + d * dist;
    // Something drawn after the surface (a model, a sprite, the viewmodel)
    // keeps its stencil code: the engine depth there is nearer than the
    // plane. Glass and translucent water write no depth (what is behind
    // reads farther); opaque water writes its own, at the plane.
    {
        const uint2 dsize = uint2(engineDepth.get_width(), engineDepth.get_height());
        const float ndc = engineDepth.read(min(uint2(uv * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
        const float zn = p.probeMix.y, zf = p.probeMix.z;
        const float zEngine = 2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn));
        const float zPlane = dist * dot(d, p.glassEye[eye][1].xyz);
        if (zEngine < zPlane - (2.0 + 0.02 * zPlane))
            return rgb;
    }
    if (nd > 0.0)
        n = -n;                              // the side facing the viewer
    const float pixTan = (p.eyeTangents[eye].z + p.eyeTangents[eye].w) / float(size.y);   // one engine pixel
    const float3 shape = water ? waterRipple(n, P, d, dist, saturate(-dot(d, n)), pixTan, p) : n;
    const float4 k = water ? p.water : p.glass;   // strength, F0, cap
    const float cosTheta = saturate(-dot(d, shape));
    const float F = k.y + (1.0 - k.y) * pow(1.0 - cosTheta, 5.0)
        + (water ? p.reflectExtra.y : p.reflectExtra.x);
    float3 r = reflect(d, shape);
    if (dot(r, n) < 0.0)
        r -= 2.0 * dot(r, n) * n;            // a ripple never sends it below the surface
    const float2 clip = p.probeMix.yz;
    float3 env = p.glassAmbient.rgb;
    // Sharp water (ssprScatter): this eye's own image mirrored in the water
    // plane, read where this pixel is, nudged by the ripple's tilt (a tilt δ
    // turns the reflected ray by 2δ: vertical on screen along the view).
    // Where it has nothing, or only content from near the frame's edge, the
    // probe fills in.
    float sharpWeight = 0.0;
    float3 sharp = 0.0;
    if (water && p.sspr[eye].z > 0.5 && row == uint(p.sspr[eye].x)) {
        const float4 t = p.eyeTangents[eye];
        const float3 along = normalize(d - dot(d, n) * n + 1e-5);
        const float3 across = cross(n, along);
        const float3 tilt = shape - n;
        float2 offset = 2.0 * float2(dot(tilt, across) / (t.x + t.y), -dot(tilt, along) / (t.z + t.w));
        // never more than a mirror texel and a half: where the mirror is
        // coarse a larger nudge jumps between its texels
        const float2 texel = 1.0 / float2(sharpWater.get_width(), sharpWater.get_height());
        offset = clamp(offset, -1.5 * texel, 1.5 * texel);
        const float2 suv = uv + offset;
        // One bilinear read, premultiplied, so coverage fades smoothly into the
        // probe. (A search a texel up and down where coverage was low, kept
        // from the point-splat days, switched hard between neighbours as the
        // ripple moved the read across a coverage edge: the wavy lines on the
        // headset. The resolve fills the mirror's gaps itself now.)
        // Coverage from the un-rippled position, colour from the rippled one:
        // the ripple must never decide whether the mirror is there, or a
        // coverage edge strobes in ripple-shaped bands.
        const half4 c = sharpWater.sample(s, suv, eye);
        const half4 c0 = sharpWater.sample(s, uv, eye);
        sharpWeight = saturate(float(c0.a));
        sharp = c.a > 0.02h ? float3(c.rgb) / float(c.a) : float3(c0.rgb) / max(float(c0.a), 1e-3);
    }
    if (sharpWeight < 0.98 && p.probe[1].w >= 0.0) {
        const float w = p.probeMix.x;
        float3 older = env;
        // the ripples hide what a third step of the walk would fix
        const int steps = water ? 2 : 3;
        if (w < 1.0 && p.probe[0].w >= 0.0)
            older = probeReflect(probeColor, probeDepth, s, P, r, p.probe[0], clip, steps);
        const float3 cur = probeReflect(probeColor, probeDepth, s, P, r, p.probe[1], clip, steps);
        env = mix(older, cur, w);
    }
    // "Water mirror view" 1: the mirror where the water is (magenta = the
    // probe fills in); 2: its confidence
    if (water && p.waterDebug.x > 0.5)
        return p.waterDebug.x < 1.5 ? (sharpWeight > 0.0 ? sharp : float3(1, 0, 1)) : float3(sharpWeight);
    env = sharpWeight >= 0.98 ? sharp : mix(env, sharp, sharpWeight);
    const float amount = min(F * k.x, k.z);
    if (water) {
        // Water blends toward its reflection by Fresnel, the reflection
        // tinted by the water's own hue so it stays watery. The headset
        // showed both earlier blends failing: mixing the probe's soft room in
        // at full weight washed the flood grey, and modulating the water by
        // the reflection's brightness against the room's light cancelled a
        // mid-grey room to nothing even with a crisp mirror. The sharp mirror
        // gets the full Fresnel weight and a light tint, so at grazing angles
        // it dominates as on a calm lake; the probe's blurry room alone gets
        // half the weight and more tint, which keeps the water's colour.
        const float3 hue = rgb / max(max(rgb.r, max(rgb.g, rgb.b)), 0.05);
        const float3 tinted = env * mix(float3(1.0), hue, mix(0.5, 0.3, sharpWeight));
        return mix(rgb, tinted, amount * mix(0.5, 1.0, sharpWeight));
    }
    const float3 seen = rgb * mix(float3(1.0), p.glassTint.rgb, p.glass.w);
    return mix(seen, env, amount);
}

// ---- Sharp water: screen-space planar reflection (Renderer.sharpWaterReflections)
// For horizontal water (one plane per eye, DisplayParams.sspr: the highest
// water row below the eye), each eye's own engine image mirrored in that
// plane, in two compute passes at a fraction of the engine's resolution
// (sspr.w, default 1/4) — a projection-hash SSPR in the manner of Remedy's
// and Far Cry 5's. The first point-splat version measured 5.4 ms on the
// headset; this does two light dispatches instead.
//
// ssprProject: every target texel stands for a source point: engine depth →
// world point W; W below the plane (the water, what is under it), the flat
// viewmodel or anything mirrored behind the eye is dropped; W is mirrored to
// W' = (W.x, W.y, 2h − W.z) and projected back into the same eye, and the
// texel it lands on keeps, by atomic min, the key of the nearest such point:
// its mirrored distance (10 bits, log scale), a seen-through-glass-or-water
// flag, an occluder flag (a back face, below) and its source texel (10 + 10).
// ssprResolve: each target texel decodes its key (or, if empty, the nearest
// of its four neighbours', filling the gaps a forward projection leaves),
// samples the engine image at the source and writes it premultiplied by a
// confidence that falls off as the source nears the frame's edge, where the
// next head turn cuts it off, so the composite blends to the probe there.
// Each eye mirrors its own image: the parallax is exactly a mirror's.
// The projection skips mirrored points that land off this plane's water in
// the engine's stencil (never read, so no atomic), which also lets the
// resolve tell water from the rest by its keys alone.
// A pixel's view ray, not normalised (forward + tangent offsets): with unit
// forward and orthogonal axes, dot(ray, forward) is 1, so a point at view
// depth z is just eye + ray · z. The depth reconstructions here use it and
// skip glassViewRay's normalise.
static inline float3 ssprRay(float2 uv, ushort eye, constant DisplayParams &p)
{
    const float4 t = p.eyeTangents[eye];
    const float2 v = float2(mix(-t.x, t.y, uv.x), mix(-t.w, t.z, uv.y));
    return p.glassEye[eye][1].xyz + v.x * p.glassEye[eye][2].xyz + v.y * p.glassEye[eye][3].xyz;
}

static inline bool ssprIsWater(texture2d_array<uint> engineStencil, float2 uv, ushort eye,
                               constant DisplayParams &p)
{
    const uint2 size = uint2(engineStencil.get_width(), engineStencil.get_height());
    const uint code = engineStencil.read(min(uint2(uv * float2(size)), size - 1), eye).r;
    return code >= 16 && code - 16 == uint(p.sspr[eye].x);
}

static inline uint3 ssprSize(texture2d_array<half> colorMap, constant DisplayParams &p, ushort eye)
{
    const uint div = p.sspr[eye].w > 0.5 ? uint(p.sspr[eye].w) : 4;
    return uint3((colorMap.get_width() + div - 1) / div, (colorMap.get_height() + div - 1) / div, div);
}

#ifndef SSPR_SPAN
#define SSPR_SPAN 48    // most mirror texels an occluder claims toward its neighbour's image
#endif
#ifndef SSPR_BACKFACE
#define SSPR_BACKFACE 0.1   // cosine past which a source faces away from the mirrored eye (an occluder)
#endif

// The world point an engine pixel shows (its depth along its own ray).
static inline float3 ssprPoint(depth2d_array<float> engineDepth, int2 pix, ushort eye, constant DisplayParams &p)
{
    const int2 dsize = int2(engineDepth.get_width(), engineDepth.get_height());
    pix = clamp(pix, int2(0), dsize - 1);
    const float ndc = engineDepth.read(uint2(pix), eye) * 2.0 - 1.0;
    const float zn = p.probeMix.y, zf = p.probeMix.z;
    const float z = 2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn));
    const float3 d = ssprRay((float2(pix) + 0.5) / float2(dsize), eye, p);
    return p.glassEye[eye][0].xyz + d * (z / dot(d, p.glassEye[eye][1].xyz));
}

kernel void ssprProject(uint3 gid [[thread_position_in_grid]],
                        constant DisplayParams &p [[ buffer(BufferIndexUniforms) ]],
                        device atomic_uint *keys [[ buffer(0) ]],
                        texture2d_array<half> colorMap [[ texture(0) ]],
                        depth2d_array<float> engineDepth [[ texture(1) ]],
                        texture2d_array<uint> engineStencil [[ texture(3) ]])
{
    const ushort eye = ushort(gid.z);
    const uint3 size = ssprSize(colorMap, p, eye);
    if (gid.x >= size.x || gid.y >= size.y || p.sspr[eye].z < 0.5)
        return;
    const float2 uv = (float2(gid.xy) + 0.5) / float2(size.xy);
    const uint2 dsize = uint2(engineDepth.get_width(), engineDepth.get_height());
    const float ndc = engineDepth.read(min(uint2(uv * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
    const float zn = p.probeMix.y, zf = p.probeMix.z;
    const float z = 2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn));
    if (z < 6.0)                     // the flat viewmodel
        return;
    // Glass and water are the probe's to reflect, not the mirror's: their
    // pixels hold the pane's colour over what is behind it (they write no
    // depth), and the warped water texture mirrored at the grid's rate came
    // out as moiré on the headset (the c1a2 sink's water box in the flood).
    // What is behind them still occludes, though (below).
    bool marked;
    {
        const uint2 ssize = uint2(engineStencil.get_width(), engineStencil.get_height());
        marked = engineStencil.read(min(uint2(uv * float2(ssize)), ssize - 1), eye).r >= 16;
    }
    const float3 E = p.glassEye[eye][0].xyz, F = p.glassEye[eye][1].xyz;
    const float3 R = p.glassEye[eye][2].xyz, U = p.glassEye[eye][3].xyz;
    const float3 d = glassViewRay(uv, eye, p);
    const float3 W = E + d * (z / dot(d, F));
    const float height = p.sspr[eye].y;
    if (W.z < height + 1.0)
        return;
    const float3 q = float3(W.xy, 2.0 * height - W.z) - E;
    const float qz = dot(q, F);
    if (qz < 4.0)
        return;
    const float4 t = p.eyeTangents[eye];
    const float2 uv2 = float2((dot(q, R) / qz + t.x) / (t.x + t.y), (dot(q, U) / qz + t.w) / (t.z + t.w));
    if (any(uv2 < 0.0) || any(uv2 >= 1.0))
        return;
    const uint2 target = min(uint2(uv2 * float2(size.xy)), size.xy - 1);
    if (!ssprIsWater(engineStencil, (float2(target) + 0.5) / float2(size.xy), eye, p))
        return;
    // Back faces. The reflected ray always travels upward, so it meets a
    // surface the eye sees from above (a table top, a counter) from below —
    // its back. In the mirrored scene such a point is a back face behind the
    // object's underside, which is never on screen: mirrored as a colour, the
    // top showed through as the underside, and where its sparse texels left
    // gaps the room behind the table won them (the table looked transparent,
    // in rows, on the headset). Such a point is stored as an occluder instead
    // ("hole": nearer than the room behind it, so it wins those texels, and
    // the resolve sends rays it blocks to the probe). Facing comes from the
    // engine depth's neighbours (the other side of an axis where one side
    // steps off an edge, so the edge does not bend it), against the mirrored
    // eye: the reflected ray arrives from there.
    uint hole = 0;
    {
        const int2 c = int2(min(uint2(uv * float2(dsize)), dsize - 1));
        const float3 W0 = ssprPoint(engineDepth, c, eye, p);
        const float edge = 0.5 + 0.02 * z;      // a step this long between neighbours is an edge
        float3 dx = ssprPoint(engineDepth, c + int2(1, 0), eye, p) - W0;
        if (length_squared(dx) > edge * edge) dx = W0 - ssprPoint(engineDepth, c - int2(1, 0), eye, p);
        float3 dy = ssprPoint(engineDepth, c + int2(0, 1), eye, p) - W0;
        if (length_squared(dy) > edge * edge) dy = W0 - ssprPoint(engineDepth, c - int2(0, 1), eye, p);
        float3 n = cross(dx, dy);
        if (dot(n, E - W0) < 0.0) n = -n;                 // the side the eye sees
        const float3 mirroredEye = float3(E.xy, 2.0 * height - E.z);
        if (dot(normalize(n + 1e-9), normalize(mirroredEye - W0)) < -SSPR_BACKFACE)
            hole = 1;
    }
    // Behind glass or water (the c1a2 sink's water box) both are kept: the
    // occluder (the counter top under the box: without it the room showed
    // through the counter there) and the surface (the counter front behind
    // the sheet: without it the box's mirror image was a hole, which the
    // underside fill painted as a dark slab with notches at the waterline on
    // the headset). The resolve blurs what such a surface shows, since its
    // pixels hold the sheet's warped texture over it (the moiré).
    const uint dist = uint(saturate(log2(1.0 + length(q)) / 15.0) * 1023.0);
    const uint key = (dist << 22) | (uint(marked) << 21) | (hole << 20) | (min(gid.y, 1023u) << 10) | min(gid.x, 1023u);
    device atomic_uint *row = keys + uint(eye) * size.y * size.x;
    atomic_fetch_min_explicit(&row[target.y * size.x + target.x], key, memory_order_relaxed);
    // An occluder also claims the mirror between its own image and its
    // neighbours' (the same top, a little farther): a top seen nearly
    // edge-on (the eye close to and level with a table) is a few source rows
    // that mirror across dozens of target rows, far more than the resolve's
    // fill reaches, and the room behind won the rows between. Toward the next
    // source row up always; sideways only at the top's side edges. Past an
    // edge the claim runs to where the neighbour's ray meets the top's plane
    // (up to 256 units): the resolve's per-ray test trims an over-claim
    // exactly, but it can only run where a texel knows of the occluder, and a
    // claim that stopped a source row short of the edge stepped at every row
    // (the headset's stairs close to a table).
    if (hole != 0) {
        for (int dir = 0; dir < 3; dir++) {
            const int2 off = dir == 0 ? int2(0, 1) : dir == 1 ? int2(1, 0) : int2(-1, 0);
            const int2 g = int2(gid.xy) + off;
            if (g.x < 0 || g.y < 0 || g.x >= int(size.x) || g.y >= int(size.y)) continue;
            const float2 uvn = (float2(g) + 0.5) / float2(size.xy);
            const float ndcn = engineDepth.read(min(uint2(uvn * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
            const float zv = 2.0 * zn * zf / ((zf + zn) - ndcn * (zf - zn));
            const float3 dn = ssprRay(uvn, eye, p);
            float3 Wn = E + dn * (zv / dot(dn, F));
            const bool level = abs(Wn.z - W.z) < 1.0 + 0.01 * z;
            if (dir > 0 && level) continue;                 // inside the top: its neighbour claims
            if (!level) {
                if (abs(dn.z) < 1e-4) continue;
                Wn = E + dn * ((W.z - E.z) / dn.z);
            }
            const float3 qn = float3(Wn.xy, 2.0 * height - Wn.z) - E;
            const float qzn = dot(qn, F);
            if (length(Wn - W) > 256.0 || qzn < 4.0) continue;
            const float2 uvm = float2((dot(qn, R) / qzn + t.x) / (t.x + t.y), (dot(qn, U) / qzn + t.w) / (t.z + t.w));
            const int2 tn = int2(clamp(uvm, 0.0, 0.9999) * float2(size.xy));
            const int2 t0 = int2(target);
            const int steps = min(max(abs(tn.y - t0.y), abs(tn.x - t0.x)), SSPR_SPAN);
            for (int k = 1; k < steps; k++) {
                const int2 tk = t0 + int2(round(float2(tn - t0) * (float(k) / float(steps))));
                atomic_fetch_min_explicit(&row[tk.y * int(size.x) + tk.x], key, memory_order_relaxed);
            }
        }
    }
}

#ifndef SSPR_SUB_X
#define SSPR_SUB_X 2    // exact mirrored samples per target texel across
#endif
#ifndef SSPR_SUB_Y
#define SSPR_SUB_Y 2    // ... and down (1 × 2 with 3 candidates is cheaper but fails DepthProbe stability)
#endif
#ifndef SSPR_FILL
#define SSPR_FILL 6u    // texels searched up and down for a surface to fill a gap (and four ways for an occluder)
#endif
#ifndef SSPR_SLAB
#define SSPR_SLAB 4.0   // units under an occluder's surface where a ray counts as inside it (a steel table top's thickness)
#endif
#ifndef SSPR_CANDIDATES
#define SSPR_CANDIDATES 5   // surfaces: this texel's key, then the one below and above, then right and left (plus two occluders)
#endif

// The key buffer's reset to "empty", four keys per thread (a compute pass
// rather than a buffer fill, so the GPU timer can bracket it).
kernel void ssprClear(uint gid [[thread_position_in_grid]],
                      constant uint &count4 [[ buffer(1) ]],
                      device uint4 *keys [[ buffer(0) ]])
{
    if (gid < count4)
        keys[gid] = uint4(0xFFFFFFFFu);
}

// No stencil read here (the first version read the engine's stencil per
// texel and measured 1.23 ms p50 on the headset): ssprProject only stores
// keys on this plane's water, so a texel with a key is water, and an empty
// texel takes the nearest of its four neighbours' keys — a hole inside the
// water, or a texel just outside it that the composite's bilinear read at
// the water's edge then sees as continuous. Elsewhere it stays empty.
// The resolve's key tile: its 16 × 8 threadgroup's texels with SSPR_FILL
// texels around them, loaded once together (the gather below then reads the
// keys from threadgroup memory: strided reads of 18+ keys per texel straight
// from the buffer were most of the resolve's cost). The app and DepthProbe
// both dispatch 16 × 8 groups.
#define SSPR_TG_W 16
#define SSPR_TG_H 8
#define SSPR_TILE_W (SSPR_TG_W + 2 * SSPR_FILL)
#define SSPR_TILE_H (SSPR_TG_H + 2 * SSPR_FILL)

// Where a reflected ray (from P along r) runs into an occluder from below:
// where it climbs to each occluder height hz[k] and to SSPR_SLAB under it,
// a surface on screen there, on or in front of the ray's point and at the
// occluder's height (its top or rim: not a leg far below, which hid points
// beside the table and drew stripes of underside there), means the ray has
// gone into the object (a table's underside, which no frame holds). Returns how far along (1e30 if never),
// and in src where the top is right above that point (the same spot for
// either test height, so an underside drawn from it is as smooth as the top).
static inline float ssprOcclude(float3 P, float3 r, thread const float *hz, int nh,
                                depth2d_array<float> engineDepth, ushort eye,
                                constant DisplayParams &p, thread float2 &src)
{
    const float3 E = p.glassEye[eye][0].xyz, F = p.glassEye[eye][1].xyz;
    const float3 R = p.glassEye[eye][2].xyz, U = p.glassEye[eye][3].xyz;
    const float4 t = p.eyeTangents[eye];
    const float height = p.sspr[eye].y;
    const uint2 dsize = uint2(engineDepth.get_width(), engineDepth.get_height());
    const float zn = p.probeMix.y, zf = p.probeMix.z;
    float blocked = 1e30;
    src = float2(-1.0);
    for (int k = 0; k < nh; k++) {
        for (int lv = 1; lv >= 0; lv--) {
            const float along = max((hz[k] - SSPR_SLAB * float(lv) - P.z) / max(r.z, 1e-4), 0.0);
            if (along >= blocked) continue;
            const float3 q = P + r * along - E;
            const float qz = dot(q, F);
            if (qz < 4.0) continue;
            const float2 at = float2((dot(q, R) / qz + t.x) / (t.x + t.y), (dot(q, U) / qz + t.w) / (t.z + t.w));
            if (any(at < 0.0) || any(at >= 1.0)) continue;
            const float ndc = engineDepth.read(min(uint2(at * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
            const float zv = 2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn));
            const float3 ds = ssprRay(at, eye, p);
            const float Az = E.z + ds.z * (zv / dot(ds, F));
            if (Az > max(height + 1.0, hz[k] - SSPR_SLAB - 1.0) && qz > zv - (1.0 + 0.01 * zv) && Az < hz[k] + 1.0 + 0.01 * zv) {
                blocked = along;
                const float3 qt = q + float3(0.0, 0.0, SSPR_SLAB * float(lv));
                const float qzt = max(dot(qt, F), 4.0);
                src = float2((dot(qt, R) / qzt + t.x) / (t.x + t.y), (dot(qt, U) / qzt + t.w) / (t.z + t.w));
            }
        }
    }
    return blocked;
}

kernel void ssprResolve(uint3 gid [[thread_position_in_grid]],
                        uint3 lid [[thread_position_in_threadgroup]],
                        uint3 tgid [[threadgroup_position_in_grid]],
                        uint3 tpg [[threads_per_threadgroup]],
                        constant DisplayParams &p [[ buffer(BufferIndexUniforms) ]],
                        device const uint *keys [[ buffer(0) ]],
                        texture2d_array<half> colorMap [[ texture(0) ]],
                        depth2d_array<float> engineDepth [[ texture(1) ]],
                        texture2d_array<half, access::write> mirror [[ texture(2) ]]
#ifdef SSPR_DEBUG
                        , device float2 *dbg [[ buffer(5) ]]   // Tools/DepthProbe only: per sub-ray (path length shown, confidence)
#endif
                        )
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const ushort eye = ushort(gid.z);
    const uint3 size = ssprSize(colorMap, p, eye);
    const uint base = uint(eye) * size.y * size.x;
    threadgroup uint tile[SSPR_TILE_H][SSPR_TILE_W];
    {
        const int ox = int(tgid.x * SSPR_TG_W) - int(SSPR_FILL), oy = int(tgid.y * SSPR_TG_H) - int(SSPR_FILL);
        // (a group at the grid's edge can have fewer threads)
        for (uint n = lid.y * tpg.x + lid.x; n < SSPR_TILE_W * SSPR_TILE_H; n += tpg.x * tpg.y) {
            const int tx = int(n % SSPR_TILE_W), ty = int(n / SSPR_TILE_W);
            const int x = ox + tx, y = oy + ty;
            tile[ty][tx] = (x >= 0 && y >= 0 && x < int(size.x) && y < int(size.y))
                ? keys[base + uint(y) * size.x + uint(x)] : 0xFFFFFFFFu;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // every thread reaches the second barrier below (the occluder results
    // shared with the neighbours), so none returns before it
    const bool inside = gid.x < size.x && gid.y < size.y;
    const uint i = base + min(gid.y, size.y - 1) * size.x + min(gid.x, size.x - 1);
#ifdef SSPR_DEBUG
    if (inside)
        for (int k = 0; k < SSPR_SUB_X * SSPR_SUB_Y; k++) dbg[i * SSPR_SUB_X * SSPR_SUB_Y + k] = 0.0;
#endif
    // Candidate surfaces: this texel's key, the nearest key above and below
    // it within SSPR_FILL rows, and its left and right neighbours' (the
    // texel's footprint can straddle a boundary between surfaces). The
    // vertical search fills the gaps a forward projection leaves where a
    // surface the eye barely sees — a face just above the water, the
    // underside an overhang hides — must cover many mirror rows: the headset
    // showed those as a comb of alternating rows that the ripple then
    // dragged across the water. "Nearest" is by distance (the key's high
    // bits), not by rows: a gap the room behind a table filled must still
    // see the table's occluder a few rows away. Occluders are gathered apart,
    // the nearest in each of the four directions: the exact test below draws
    // an occluded patch's outline per ray, but only where the texel knows of
    // the occluder (left and right too, or the outline steps texel by texel
    // where the claimed region ends; the headset showed such stairs close
    // to a table). The exact-ray check below decides what each ray meets.
    const uint lx = lid.x + SSPR_FILL, ly = lid.y + SSPR_FILL;
    uint cand[9] = { tile[ly][lx], 0xFFFFFFFFu, 0xFFFFFFFFu, tile[ly][lx + 1], tile[ly][lx - 1],
                     0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu };
    for (uint k = 1; k <= SSPR_FILL; k++) {
        const uint up = tile[ly + k][lx], dn = tile[ly - k][lx];
        const uint rt = tile[ly][lx + k], lf = tile[ly][lx - k];
        if ((up >> 20) & 1u) cand[5] = min(cand[5], up); else cand[1] = min(cand[1], up);
        if ((dn >> 20) & 1u) cand[6] = min(cand[6], dn); else cand[2] = min(cand[2], dn);
        if ((rt >> 20) & 1u) cand[7] = min(cand[7], rt);
        if ((lf >> 20) & 1u) cand[8] = min(cand[8], lf);
    }
    uint nearest = 0xFFFFFFFFu;
    for (int k = 0; k < 9; k++) nearest = min(nearest, cand[k]);
    const bool live = inside && nearest != 0xFFFFFFFFu;
    // Each candidate's world point (its source texel's depth). Occluders
    // (ssprProject's back faces) are kept apart from surfaces.
    const float3 E = p.glassEye[eye][0].xyz, F = p.glassEye[eye][1].xyz;
    const float3 R = p.glassEye[eye][2].xyz, U = p.glassEye[eye][3].xyz;
    const float height = p.sspr[eye].y;
    const float4 t = p.eyeTangents[eye];
    const uint2 dsize = uint2(engineDepth.get_width(), engineDepth.get_height());
    const float zn = p.probeMix.y, zf = p.probeMix.z;
    // Surfaces (their world points and own sources) and occluders (their
    // heights: one is tested only at its height, so another at the same
    // height — the rest of a level top — adds nothing), packed.
    float3 Ws[5];
    float2 Wsrc[5];
    bool Wmk[5];                      // seen through glass or water
    float hz[3];
    int ns = 0, nh = 0;
    for (int k = 0; k < 9 && live; k++) {
        if (cand[k] == 0xFFFFFFFFu || (k >= SSPR_CANDIDATES && k < 5)) continue;
        const bool isHole = ((cand[k] >> 20) & 1u) != 0;
        const float2 src = (float2(cand[k] & 1023u, (cand[k] >> 10) & 1023u) + 0.5) / float2(size.xy);
        const float ndc = engineDepth.read(min(uint2(src * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
        const float3 dk = ssprRay(src, eye, p);
        const float3 W = E + dk * ((2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn))) / dot(dk, F));
        bool fresh = true;
        if (isHole) {
            for (int m = 0; m < nh; m++)
                if (abs(hz[m] - W.z) < 1.0) fresh = false;
            if (fresh && nh < 3) hz[nh++] = W.z;
        } else {
            // a neighbour on the same surface (about the same distance) adds
            // nothing: one candidate covers it
            for (int m = 0; m < ns; m++)
                if (abs(length(Ws[m] - E) - length(W - E)) < 2.0 + 0.02 * length(Ws[m] - E)) fresh = false;
            if (fresh && ns < 5) {
                Wmk[ns] = ((cand[k] >> 21) & 1u) != 0;
                Ws[ns] = W; Wsrc[ns] = src; ns++;
            }
        }
    }
    // Several surfaces: each candidate's point moved to where this texel's
    // centre ray meets it. A candidate is some point of its surface, from
    // whichever source texel won the key; the sub-rays' check below measures
    // how far each ray passes from it, and on a face struck at a slant (a
    // counter's front lip) that distance depended on which point the texel
    // happened to hold, so the choice between the lip and the room behind it
    // flipped texel by texel along the lip's mirrored edge: a staircase one
    // texel tall on the headset. One depth read per candidate, only here.
    if (ns >= 2) {
        float3 dc = glassViewRay((float2(gid.xy) + 0.5) / float2(size.xy), eye, p);
        if (dc.z > -1e-4) dc = float3(dc.xy, -1e-4);
        const float3 Pc = E + dc * ((height - E.z) / dc.z);
        const float3 rc = float3(dc.x, dc.y, -dc.z);
        for (int k = 0; k < ns; k++) {
            const float along = max(dot(Ws[k] - Pc, rc), 0.0);
            const float3 q = Pc + rc * along - E;
            const float qz = dot(q, F);
            if (qz < 4.0) continue;
            const float2 src = float2((dot(q, R) / qz + t.x) / (t.x + t.y), (dot(q, U) / qz + t.w) / (t.z + t.w));
            if (any(src < 0.0) || any(src >= 1.0)) continue;
            const float ndc = engineDepth.read(min(uint2(src * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
            const float3 ds = ssprRay(src, eye, p);
            const float3 A = E + ds * ((2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn))) / dot(ds, F));
            const float lk = length(Ws[k] - E);
            if (A.z > height + 1.0 && abs(length(A - E) - lk) < 2.0 + 0.02 * lk) Ws[k] = A;
        }
    }
    // The texel covers several engine pixels and the boundary between two
    // mirrored surfaces can cross it: one sample per texel, taken at the
    // winning source texel, made thin features (the c1a2 vent grate) and
    // horizontal edges pop by a whole texel as the head moved a fraction of
    // a pixel. Instead, SSPR_SUB_X × SSPR_SUB_Y exact mirrored rays per texel:
    // each, from the water point under it, is taken to every candidate's
    // depth (the point on the ray nearest the candidate's world point),
    // projected back into the eye, and checked against the engine's depth
    // there: the candidate whose check lands back on the ray is the surface
    // that ray really mirrors. Its colour is sampled at that exact,
    // continuously moving coordinate, and the samples are averaged.
    // Occluders, once per texel along its centre ray: where the ray climbs
    // to each occluder's height and to SSPR_SLAB under it, if a surface on
    // screen there is on or in front of the ray's point and no higher than
    // the occluder, the ray has run into the object from below — a table's
    // underside, which no frame holds (ssprOcclude). The results (how far
    // along, and where the top is right above that point) are shared through
    // the threadgroup: a sub-ray whose texel and neighbours toward it agree
    // takes the texel's result, and only one at an occluded patch's outline
    // runs its own test, so the outline still follows the geometry at
    // sub-ray steps (testing every sub-ray was half the resolve's cost).
    // (b2e7e18 marched each texel's centre ray in 8 even steps up to the
    // farthest candidate instead: the steps jumped over a thin table top.)
    threadgroup float tb[SSPR_TG_H][SSPR_TG_W];
    threadgroup float2 ts[SSPR_TG_H][SSPR_TG_W];
    {
        float blockedC = 1e30;
        float2 srcC = float2(-1.0);
        if (live && nh > 0) {
            float3 d = glassViewRay((float2(gid.xy) + 0.5) / float2(size.xy), eye, p);
            if (d.z > -1e-4) d = float3(d.xy, -1e-4);
            blockedC = ssprOcclude(E + d * ((height - E.z) / d.z), float3(d.x, d.y, -d.z), hz, nh, engineDepth, eye, p, srcC);
        }
        tb[lid.y][lid.x] = blockedC;
        ts[lid.y][lid.x] = srcC;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!inside)
        return;
    if (!live) {
        mirror.write(half4(0.0h), gid.xy, gid.z);
        return;
    }
    half3 sum = 0.0h;
    float conf = 0.0;
    for (int sj = 0; sj < SSPR_SUB_Y; sj++) {
        for (int si = 0; si < SSPR_SUB_X; si++) {
            const float2 sub = (float2(si, sj) + 0.5) / float2(SSPR_SUB_X, SSPR_SUB_Y);
            float3 d = glassViewRay((float2(gid.xy) + sub) / float2(size.xy), eye, p);
            if (d.z > -1e-4) d = float3(d.xy, -1e-4);
            const float3 P = E + d * ((height - E.z) / d.z);
            const float3 r = float3(d.x, d.y, -d.z);
            // The occluder results around this sub-ray: its texel's centre
            // and its three neighbours toward it.
            const int nx = si * 2 - 1, ny = sj * 2 - 1;      // toward this sub-ray (2 × 2)
            const uint ax = uint(clamp(int(lid.x) + nx, 0, SSPR_TG_W - 1));
            const uint ay = uint(clamp(int(lid.y) + ny, 0, SSPR_TG_H - 1));
            const float b0 = tb[lid.y][lid.x], b1 = tb[lid.y][ax], b2 = tb[ay][lid.x], b3 = tb[ay][ax];
            const bool nearBlock = min(min(b0, b1), min(b2, b3)) < 1e29;
            // This sub-ray's own block: inside an occluded patch (the texel
            // and its three neighbours toward it all blocked) the texel's
            // result, none where none of them is blocked, and at the patch's
            // outline its own exact test, so the outline follows the geometry
            // at sub-ray steps. Decided before the surfaces are chosen, since
            // the surface loop skips what lies past the block: with the
            // texel's block there, a free sub-ray at the outline of a blocked
            // texel lost every surface past the occluder and fell to the probe.
            float bSub = 1e30;
            float2 sSub = float2(-1.0);
            if (nearBlock) {
                if (max(max(b0, b1), max(b2, b3)) < 1e29) { bSub = b0; sSub = ts[lid.y][lid.x]; }
                else if (nh > 0) bSub = ssprOcclude(P, r, hz, nh, engineDepth, eye, p, sSub);
            }
            float best = 1e30, bestLen = 1e30;
            float2 bestSrc = float2(-1.0);
            bool bestMk = false;
            float2 exactSum = 0.0;
            float exactN = 0.0;
            for (int k = 0; k < ns; k++) {
                const float along = max(dot(Ws[k] - P, r), 0.0);
                const float3 q = P + r * along - E;
                const float qz = dot(q, F);
                if (qz < 4.0) continue;
                const float2 src = float2((dot(q, R) / qz + t.x) / (t.x + t.y), (dot(q, U) / qz + t.w) / (t.z + t.w));
                exactSum += src; exactN += 1.0;
                if (any(src < 0.0) || any(src >= 1.0)) continue;
                if (ns == 1 && !nearBlock) { bestSrc = src; best = 0.0; bestMk = Wmk[k]; continue; }   // one surface: no check needed
                const float ndc = engineDepth.read(min(uint2(src * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
                const float3 ds = ssprRay(src, eye, p);
                const float3 A = E + ds * ((2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn))) / dot(ds, F));
                const float3 off = A - P;
                if (A.z <= height) continue;
                // past this texel's occluder the ray never gets there: the
                // sample would show what is on screen at src, measured as the
                // ray's path to it (an unverified candidate can lie far past
                // its own distance). Skipping it lets a nearer surface win:
                // rows chose the bench's cabinet face and the wall behind in
                // turn, which the block turned into rows of probe.
                const float len = length(off);
                if (len > bSub + 2.0) continue;
                const float miss = length(off - r * dot(off, r)) + 0.01 * along;   // nearer wins a tie
                if (miss < best) { best = miss; bestSrc = src; bestLen = len; bestMk = Wmk[k]; }
            }
            // if no surface checks out (the ray's point lands on the water
            // itself, or off the frame), the first surface's own source
            // stands in, unless the texel's occluder stops the ray: a skipped
            // sample left the texel part-empty, and texels of uneven coverage
            // showed as fine horizontal hatching and dark smudges on the
            // headset
            if (bestSrc.x < 0.0 && ns > 0 && bSub > 1e29) { bestSrc = Wsrc[0]; bestMk = Wmk[0]; }
            // Occluded: blocked nearer than the surface this ray shows.
            float f = 0.0, blockedNear = 1e30;
            float2 blockSrc = float2(-1.0);
            if (bSub < (bestSrc.x >= 0.0 ? bestLen - 2.0 : 1e30)) { f = 1.0; blockSrc = sSub; blockedNear = bSub; }
            // Run into an object with nothing nearer: its underside. No frame
            // holds it, and the probe (world-fixed, blind to the table) showed
            // the room through it as a blur on the headset. Instead, what is
            // on screen right above the point the ray reached (the top, or its
            // rim) darkened by waterDebug.y ("waterUnderside": the underside's
            // brightness against the top; 0 = leave it to the probe).
            const float wSurf = bestSrc.x >= 0.0 ? 1.0 - f : 0.0;
            const float wUnder = f > 0.0 && blockSrc.x >= 0.0 && p.waterDebug.y > 0.0 ? f : 0.0;
            if (wSurf + wUnder <= 0.0) continue;
            // The confidence follows where this ray's mirrored point would be
            // in the frame — the mean of every surface's exact projection,
            // in the frame or not — which moves smoothly from texel to texel,
            // as neighbouring texels share candidates. Taken from the chosen
            // sample's source instead, it jumped between neighbouring rows
            // that chose surfaces at different distances from the frame's
            // edge: wavy bands of confidence in a sharp-edged patch on the
            // headset, where the mirror runs out at the top of the view.
            // The underside's own confidence comes from where its colour is
            // read (the top, on screen): taken from the surfaces' projections
            // instead, it faded where they ran off the frame and the probe
            // showed through in the steps of the occluder's claim.
            const float2 confAt = exactN > 0.0 ? exactSum / exactN : (bestSrc.x >= 0.0 ? bestSrc : blockSrc);
            const float2 edge = min(confAt, 1.0 - confAt);
            const float cs = smoothstep(0.0, 0.15, min(edge.x, edge.y));
            const float2 edgeU = min(blockSrc, 1.0 - blockSrc);
            const float cu = smoothstep(0.0, 0.15, min(edgeU.x, edgeU.y));
            const float c = (cs * wSurf + cu * wUnder) / (wSurf + wUnder);
            // A 2 × 2-pixel box around the sample (four bilinear taps half a
            // pixel out): the sub-rays sit two engine pixels apart, and a
            // point sample there aliased fine source texture into moiré.
            // This replaces a half-size prefiltered copy of the engine image,
            // whose extra pass measured 1.75 ms on the headset.
            // Seen through glass or water, an 8 × 8-pixel box instead: the
            // sheet's warped texture over the surface, mirrored at the
            // grid's rate, was moiré; blurred it reads as the sheet softly
            // over the counter front, continuous with the rest.
            const float2 h = (bestMk ? 3.0 : 0.5) / float2(colorMap.get_width(), colorMap.get_height());
            half3 col = 0.0h;
            if (wSurf > 0.0)
                col += half(wSurf * cs) * 0.25h * (colorMap.sample(s, bestSrc + float2(-h.x, -h.y), eye).rgb
                                            + colorMap.sample(s, bestSrc + float2( h.x, -h.y), eye).rgb
                                            + colorMap.sample(s, bestSrc + float2(-h.x,  h.y), eye).rgb
                                            + colorMap.sample(s, bestSrc + float2( h.x,  h.y), eye).rgb);
            if (wUnder > 0.0)
                col += half(wUnder * cu * p.waterDebug.y) * 0.5h * (colorMap.sample(s, blockSrc + float2(-h.x, 0.0), eye).rgb
                                                             + colorMap.sample(s, blockSrc + float2( h.x, 0.0), eye).rgb);
            sum += col;
            conf += cs * wSurf + cu * wUnder;
#ifdef SSPR_DEBUG
            if (wUnder >= wSurf)
                dbg[i * SSPR_SUB_X * SSPR_SUB_Y + sj * SSPR_SUB_X + si] = float2(length(P - E) + blockedNear, c * (wSurf + wUnder));
            else {
                const float ndc = engineDepth.read(min(uint2(bestSrc * float2(dsize)), dsize - 1), eye) * 2.0 - 1.0;
                const float3 ds = ssprRay(bestSrc, eye, p);
                const float3 A = E + ds * ((2.0 * zn * zf / ((zf + zn) - ndc * (zf - zn))) / dot(ds, F));
                dbg[i * SSPR_SUB_X * SSPR_SUB_Y + sj * SSPR_SUB_X + si] = float2(length(P - E) + length(A - P), c * wSurf);
            }
#endif
        }
    }
    const float n = float(SSPR_SUB_X * SSPR_SUB_Y);
    const half4 out = half4(sum / half(n), half(conf / n));
    mirror.write(out, gid.xy, gid.z);
}

// Test hook for Tools/DepthProbe: what the probe shows along each pixel's
// own view ray from the eye (no glass, no reflection), with or without the
// parallax walk (probeMix.w = iterations). Where the probe and the eye see the
// same static surface this reproduces the engine image, which checks the
// probe's face layout, depth decode and parallax correction against the
// engine. Not used by the app.
fragment float4 glassProbeView(ColorInOut in [[stage_in]],
                               constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                               texture2d_array<half> probeColor [[ texture(3) ]],
                               depth2d_array<float> probeDepth [[ texture(4) ]],
                               texture2d_array<half> sharpWater [[ texture(5) ]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float3 d = glassViewRay(in.texCoord, in.eye, params);
    const float3 rgb = probeLookup(probeColor, probeDepth, s, params.glassEye[in.eye][0].xyz, d,
                                   params.probe[1], params.probeMix.yz, int(params.probeMix.w));
    return float4(rgb, 1.0);
}

static inline float4 displayOutput(float3 rgb, float alpha, float2 uv, float2 pixel,
                                   constant DisplayParams &p)
{
    if (p.hdrTest > 0.5)
        return float4(hdrTestPattern(uv, p.hdrTest, p.aspect), 1.0);
    return float4(ditherOutput(displayLinearize(rgb, p.decodeGamma), pixel), alpha);
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                               texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                               depth2d_array<float> engineDepth [[ texture(1) ]],
                               texture2d_array<uint> engineStencil [[ texture(2) ]],
                               texture2d_array<half> probeColor [[ texture(3) ]],
                               depth2d_array<float> probeDepth [[ texture(4) ]],
                               texture2d_array<half> sharpWater [[ texture(5) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::clamp_to_edge);

    // Fullscreen-quad UV: vertex emits texCoord = pos*0.5+0.5 in Metal NDC.
    // ANGLE/GL writes the FBO with (0,0) at bottom-left and Metal samples
    // textures with (0,0) at bottom-left too, so no flip needed here.
    // The texture is the MetalFX-upscaled displayMap (full logical
    // resolution, already edge-reconstructed and sharpened), or the raw
    // engine colorMap when MetalFX is unavailable.
    float2 uv = in.texCoord;
    half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(colorSample.rgb);
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, engineStencil, engineDepth, probeColor, probeDepth, sharpWater, colorSampler, params);

    return displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
}

// Composite pass with FXAA folded in (Renderer.compositeFXAA, default on).
// Identical to fragmentShader apart from resolving rgb through the FXAA
// kernel at the SAMPLED texture's texel size; alpha still comes straight
// from the centre tap so the drawable's alpha behaviour is unchanged.
fragment float4 fragmentShaderFXAA(ColorInOut in [[stage_in]],
                                   constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                                   texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                                   depth2d_array<float> engineDepth [[ texture(1) ]],
                                   texture2d_array<uint> engineStencil [[ texture(2) ]],
                               texture2d_array<half> probeColor [[ texture(3) ]],
                               depth2d_array<float> probeDepth [[ texture(4) ]],
                               texture2d_array<half> sharpWater [[ texture(5) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::clamp_to_edge);

    // Same un-flipped UV convention as fragmentShader (see the note there).
    float2 uv = in.texCoord;
    const float2 px = float2(1.0 / colorMap.get_width(), 1.0 / colorMap.get_height());
    half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(fxaaResolve(colorMap, colorSampler, uv, px, in.eye, colorSample.rgb));
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, engineStencil, engineDepth, probeColor, probeDepth, sharpWater, colorSampler, params);
    return displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
}

// ---- Per-pixel reprojection depth (Renderer.reprojectionDepth) ------------
// The compositor re-warps each frame from the pose it was drawn at to the
// pose at display time, using the drawable's depth for the positional part.
// The constant far depth (fullscreenVertexShader) makes that a pure rotation:
// right for distant walls, wrong for anything near when the head moves. These
// variants give every pixel the engine's own depth instead, converted from
// its GL window depth (standard Z, the projection Lambda_Bridge.c builds from
// the same frustum tangents, near/far in DisplayParams.engineClip) to the
// distance along the eye's forward axis and back through the compositor's
// projection, so both name the same point in the room.
//
// Kept inside the layer's depth range: exactly 0 (the far plane) displayed
// pure black on device in Oneiros, so sky, empty texels and anything past the
// compositor's far plane get depthLimits.x, the old constant. A pixel the
// engine puts nearer than depthLimits.z is its own flat viewmodel (the stock
// one is squeezed into the front 30% of the depth range, so it decodes a few
// centimetres from the eye) and gets the far depth too, as it always had: a
// head-locked image has no right depth, and the near one would warp it hard.
struct CompositeDepthOut
{
    float4 color [[color(0)]];
    float  depth [[depth(any)]];
};

static inline float compositorDepth(depth2d_array<float> engineDepth, float2 uv, ushort eye,
                                    constant DisplayParams &p)
{
    const uint2 size = uint2(engineDepth.get_width(), engineDepth.get_height());
    const uint2 texel = min(uint2(uv * float2(size)), size - 1);
    const float ndc = engineDepth.read(texel, eye) * 2.0 - 1.0;
    const float distance = p.engineClip.x / (p.engineClip.y - ndc * p.engineClip.z);
    if (distance < p.depthLimits.z)
        return p.depthLimits.x;
    const float4 P = p.depthProjection[eye];
    const float z = -distance;
    const float depth = (P.x * z + P.y) / (P.z * z + P.w);
    return clamp(depth, p.depthLimits.x, p.depthLimits.y);
}

fragment CompositeDepthOut fragmentShaderDepth(ColorInOut in [[stage_in]],
                                               constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                                               texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                                               depth2d_array<float> engineDepth [[ texture(1) ]],
                                               texture2d_array<uint> engineStencil [[ texture(2) ]],
                               texture2d_array<half> probeColor [[ texture(3) ]],
                               depth2d_array<float> probeDepth [[ texture(4) ]],
                               texture2d_array<half> sharpWater [[ texture(5) ]])
{
    constexpr sampler colorSampler(mip_filter::linear, mag_filter::linear,
                                   min_filter::linear, address::clamp_to_edge);
    const float2 uv = in.texCoord;
    const half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(colorSample.rgb);
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, engineStencil, engineDepth, probeColor, probeDepth, sharpWater, colorSampler, params);
    CompositeDepthOut out;
    out.color = displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
    out.depth = compositorDepth(engineDepth, uv, in.eye, params);
    return out;
}

fragment CompositeDepthOut fragmentShaderFXAADepth(ColorInOut in [[stage_in]],
                                                   constant DisplayParams &params [[ buffer(BufferIndexUniforms) ]],
                                                   texture2d_array<half> colorMap [[ texture(TextureIndexColor) ]],
                                                   depth2d_array<float> engineDepth [[ texture(1) ]],
                                                   texture2d_array<uint> engineStencil [[ texture(2) ]],
                               texture2d_array<half> probeColor [[ texture(3) ]],
                               depth2d_array<float> probeDepth [[ texture(4) ]],
                               texture2d_array<half> sharpWater [[ texture(5) ]])
{
    constexpr sampler colorSampler(mip_filter::linear, mag_filter::linear,
                                   min_filter::linear, address::clamp_to_edge);
    const float2 uv = in.texCoord;
    const float2 px = float2(1.0 / colorMap.get_width(), 1.0 / colorMap.get_height());
    const half4 colorSample = colorMap.sample(colorSampler, uv, in.eye);
    float3 rgb = float3(fxaaResolve(colorMap, colorSampler, uv, px, in.eye, colorSample.rgb));
    if (kGlass)
        rgb = glassShade(rgb, uv, in.eye, engineStencil, engineDepth, probeColor, probeDepth, sharpWater, colorSampler, params);
    CompositeDepthOut out;
    out.color = displayOutput(rgb, float(colorSample.a), uv, in.position.xy, params);
    out.depth = compositorDepth(engineDepth, uv, in.eye, params);
    return out;
}

// The gun and body draw over the engine image with their own depth buffer
// (WeaponPass), so the drawable's depth still holds the engine's under them.
// This copies their depth over it wherever they drew: the drawable texel and
// the weapon depth texel are the same physical pixel (same size, same rate
// map), and both are the compositor's reverse-Z already. Untouched texels
// (the clear value, 0) keep the engine's depth.
struct DepthOnlyOut
{
    float depth [[depth(any)]];
};

fragment DepthOnlyOut reprojectionDepthMerge(ColorInOut in [[stage_in]],
                                             depth2d_array<float> overlayDepth [[ texture(0) ]])
{
    const float d = overlayDepth.read(uint2(in.position.xy), in.eye);
    if (d <= 0.0)
        discard_fragment();
    DepthOnlyOut out;
    out.depth = d;
    return out;
}
