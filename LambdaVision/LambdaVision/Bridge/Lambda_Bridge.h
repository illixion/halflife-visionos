// Bridging header: C/Swift surface for the engine.
// Phase 2 will expose: lambda_engine_init, lambda_engine_frame, lambda_engine_shutdown,
// lambda_engine_set_view (per-eye matrices), lambda_engine_set_input (button state, motion).

#ifndef LAMBDA_BRIDGE_H
#define LAMBDA_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0xCAFE — confirms Swift→C linkage works.
int lambda_bridge_smoke_test(void);

// Creates a Vulkan instance via MoltenVK, enumerates physical devices, copies
// the first device's name into name_out. Returns the number of devices, or:
//   -1: vkCreateInstance failed
//   -2: vkEnumeratePhysicalDevices failed
//   -3: zero devices found
int lambda_vulkan_smoke_test(char *name_out, int name_cap);

// Phase 2 step 1: create VkInstance + VkDevice + graphics queue against the
// first physical device. Probes VK_EXT_metal_objects availability (needed for
// the zero-copy CompositorServices interop path).
//
// Writes a human-readable status line into status_out (device name, API
// version, graphics queue family index, metal_objects yes/no).
//
// Returns:
//   0  on success
//  -1  vkCreateInstance failed
//  -2  no physical devices
//  -3  no graphics-capable queue family
//  -4  vkCreateDevice failed
int lambda_vulkan_create_device(char *status_out, int status_cap);

// Tears down the device + instance created by lambda_vulkan_create_device.
// Safe to call if create wasn't called (no-op).
void lambda_vulkan_destroy_device(void);

// Phase 2 step 2 smoke: allocates an IOSurface (BGRA8, w x h), imports it as a
// VkImage via VK_EXT_metal_objects, clears it to (r,g,b,1.0) on the graphics
// queue, blocks until idle. Returns the IOSurface as `void*` (an IOSurfaceRef
// retained for the caller; release with CFRelease).
//
// Returns NULL on failure; status_out gets a human-readable result either way.
//
// Requires lambda_vulkan_create_device() to have succeeded *and* metal_objects
// to be enabled on the device.
void *lambda_vulkan_clear_iosurface(int width, int height,
                                    float r, float g, float b,
                                    char *status_out, int status_cap);

// Phase 2 step 3: pooled per-eye Vulkan render. Bridge owns IOSurface +
// VkImage + memory + command buffer per (slot, eye). On (slot, eye, w, h)
// match: re-records cmd buffer with new clear color, submits, waits idle,
// returns IOSurface (unretained — bridge owns lifecycle). On dimension change
// or first call: lazily reallocates the slot.
//
// slot ∈ [0, 3), eye ∈ [0, 2). Returns NULL on failure.
//
// Renders: clear (r,g,b,1) background + a rotating colored test triangle
// (rotation driven by `time` radians) using a real Vulkan graphics pipeline
// with dynamic rendering. Visible animation == per-frame rasterizer running.
const void *lambda_vulkan_render_eye_pooled(int slot, int eye,
                                            int width, int height,
                                            float r, float g, float b,
                                            float time);

// Releases all pooled per-eye resources. Safe before destroy_device.
void lambda_vulkan_release_pool(void);

// Stage C1: split the monolithic pooled-render call into begin/end so the
// engine's renderer (ref_vklite) can record its own draw commands between
// them. lambda_bridge_begin_frame:
//   - lazily allocates pool[slot][eye] for (w,h),
//   - resets the slot's command buffer + begins recording,
//   - transitions the VkImage UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL,
//   - opens a dynamic-rendering pass with load-op CLEAR (r,g,b,1).
// Returns 0 on success; <0 on failure.
//
// After this returns, the engine may issue draw commands by calling back
// into the bridge (lambda_bridge_record_*, added in C2+). Until those exist,
// the frame is clear-only — equivalent to the old lambda_vulkan_render_eye_pooled
// minus the test triangle.
int lambda_bridge_begin_frame(int slot, int eye, int width, int height,
                              float r, float g, float b);

// Stage C1: closes the rendering pass opened by begin_frame, transitions to
// GENERAL so Metal can sample the IOSurface, submits + waits idle, returns
// the IOSurface (bridge-owned). NULL on failure or if no frame is active.
const void *lambda_bridge_end_frame(void);

// Stage C2: record one solid-color quad into the active frame. Coords are
// in the engine's 2D pixel space (origin top-left, +x right, +y down) and
// get converted to NDC against the active slot's width/height. Color is
// 0..255 per channel. No-op if no frame is active.
void lambda_bridge_record_fill_rgba(float x, float y, float w, float h,
                                    uint8_t r, uint8_t g, uint8_t b, uint8_t a);

// Stage C3: textures. Upload a tightly-packed RGBA8 buffer (width*height*4
// bytes) into a new VkImage with an attached descriptor set. Returns a
// non-zero opaque handle on success, 0 on failure. The bridge owns the
// underlying VkImage; destroy with lambda_bridge_destroy_texture.
uint32_t lambda_bridge_create_texture(const void *rgba_bytes,
                                      int width, int height);

// Frees a texture previously created via lambda_bridge_create_texture.
// Safe to call with handle 0 (no-op).
void lambda_bridge_destroy_texture(uint32_t handle);

// Stage C3: record one textured quad into the active frame. Coordinates
// match record_fill_rgba (engine 2D pixel space). uv_* are 0..1 normalized.
// Tint is multiplied by the sampled color (rgba 0..255).
void lambda_bridge_record_draw_stretch_pic(float x, float y, float w, float h,
                                           float s1, float t1, float s2, float t2,
                                           uint8_t r, uint8_t g, uint8_t b, uint8_t a,
                                           uint32_t texture_handle);

// Stage D1: render 3 colored debug-axis lines through the origin (X=red,
// Y=green, Z=blue, +/- 64 world units) using the supplied column-major
// MVP matrix. Requires an active frame; the slot now has a depth buffer
// so 3D draws z-occlude correctly.
void lambda_bridge_record_debug_axes(const float mvp_col_major[16]);

// Stage D2: per-batch entry describing a contiguous run of textured world
// vertices to draw with a specific texture handle.
typedef struct {
    uint32_t texture_handle;  // 0 == draw untextured (white)
    uint32_t first_vertex;
    uint32_t vertex_count;
} lambda_bridge_world_batch;

// Stage D2: upload (or replace) the world geometry. Vertex layout is
// 5 floats: x,y,z,u,v. Batches reference contiguous spans inside the
// vertex array and the texture each span uses. The bridge keeps a copy
// of the batch list. Subsequent uploads release the prior buffers.
void lambda_bridge_world_upload(const float *verts_pos_uv,
                                int          vertex_count,
                                const lambda_bridge_world_batch *batches,
                                int          batch_count);

// Free the uploaded world. Safe to call when nothing's uploaded.
void lambda_bridge_world_clear(void);

// Stage D2: record draws for the uploaded world geometry into the active
// frame. No-op if no world is uploaded.
void lambda_bridge_record_world(const float mvp_col_major[16]);

// Stage E1: draw a contiguous sub-range of the uploaded batches with the
// supplied MVP. Lets a brush entity (door, button) be drawn from the same
// world VB at its current transform.
void lambda_bridge_record_world_range(const float mvp_col_major[16],
                                      int first_batch, int batch_count);

// Phase 2c: xash3d-fwgs engine wiring. The engine normally owns main()
// + a while loop calling COM_Frame; we patched it into a frame-driven
// surface (Host_DoInit / Host_DoFrame / Host_Shutdown) so visionOS can
// drive it from CompositorServices. These wrappers add argv assembly,
// sandbox setup, and shielded re-entry.
//
// lambda_engine_init: writable_dir is a path under the app sandbox the
//   engine can read+write (becomes XASH3D_BASEDIR + cwd). extra_argv is
//   appended after argv[0]="xash"; pass NULL/0 for default. Returns 0
//   on success, <0 on failure (status_out gets a one-line reason).
int lambda_engine_init(const char *writable_dir,
                       int extra_argc, const char *const *extra_argv,
                       char *status_out, int status_cap);

// Drives one engine frame (one COM_Frame call). Returns 0 normally,
// -1 if init wasn't called or engine has crashed.
int lambda_engine_frame(void);

// Tears engine down. Idempotent.
void lambda_engine_shutdown(void);

// ---- ANGLE / EGL bridge ----

// One-shot setup: creates a long-lived EGLDisplay + EGLContext bound to
// ANGLE's Metal backend, makes the context current on a 1x1 pbuffer so
// subsequent GL calls are valid even before any drawable arrives.
// Returns 0 on success, negative on failure (with diagnostic in status_out).
int lambda_gl_setup(char *status_out, int status_cap);

// Per-frame proof: wraps a Swift-owned MTLTexture (id<MTLTexture> cast to
// void*) as an EGLImage via EGL_ANGLE_metal_texture_client_buffer, attaches
// to an FBO color attachment, glClears to (r,g,b,1), then schedules the
// Metal work so the texture is presentable. Use to verify the GL→Metal
// interop path before bringing the full xash R_RenderFrame pipeline in.
//
// Returns 0 on success.
int lambda_gl_clear_mtl_texture(void *mtl_texture, int width, int height,
                                float r, float g, float b,
                                char *status_out, int status_cap);

// Tears down the long-lived context/display. Idempotent.
void lambda_gl_teardown(void);

// ---- GL worker thread ----
// ANGLE/Metal on visionOS doesn't support cross-thread context migration
// even when eglMakeCurrent succeeds. These wrappers run the GL setup +
// engine init + per-frame work on a single dedicated pthread that owns
// the EGL context for the process lifetime. Call from any Swift thread;
// each function blocks until the worker finishes the requested work.
int lambda_gl_worker_setup(char *status_out, int status_cap);
int lambda_gl_worker_engine_init(const char *writable_dir,
                                 int extra_argc, const char *const *extra_argv,
                                 char *status_out, int status_cap);
int lambda_gl_worker_render_frame(void *mtl_texture, int width, int height,
                                  float r, float g, float b);

// Stereo render. eye_index=0 ticks the simulation and renders the left eye
// (same as lambda_gl_worker_render_frame, but with a stereo offset).
// eye_index=1 re-runs only the renderer (no sim tick) with the supplied
// offset, producing the right-eye image. eye_offset is in xash world units
// applied along the view-right axis (positive = camera moves right).
int lambda_gl_worker_render_eye(int eye_index, float eye_offset,
                                void *mtl_texture, int width, int height,
                                float r, float g, float b);

// Same as lambda_gl_worker_render_eye, but additionally installs AVP's
// per-eye asymmetric projection (via lambda_engine_set_projection_tangents)
// around the engine call. tangents4 = (tan_left, tan_right, tan_top, tan_bottom),
// all positive magnitudes; zNear/zFar in xash world units.
int lambda_gl_worker_render_eye_tangents(int eye_index, float eye_offset,
                                         const float *tangents4,
                                         float zNear, float zFar,
                                         void *mtl_texture, int width, int height,
                                         float r, float g, float b);

// Full per-eye render: AVP frustum + head-tracked viewangles + head
// translation installed for the duration of the engine call.
// view_angles3 = (absolute pitch, yaw DELTA added to the game's yaw,
// absolute roll) in xash degrees — see lambda_engine_set_view_angles for
// why pitch/roll are absolute. view_offset3 = head translation since
// baseline in the baseline-forward frame (x forward, y left, z up; xash
// units); the engine rotates it by the game's yaw and adds it to the view
// origin (camera detaches from the player entity). NULL for none.
int lambda_gl_worker_render_eye_full(int eye_index, float eye_offset,
                                     const float *tangents4,
                                     float zNear, float zFar,
                                     const float *view_angles3,
                                     const float *view_offset3,
                                     void *mtl_texture, int width, int height,
                                     float r, float g, float b);

// Step 3b.1: install/clear asymmetric per-eye projection. Call
// lambda_engine_set_projection_tangents() before each per-eye render and
// lambda_engine_clear_projection_override() once the pair is done (or leave
// active across frames — the renderer reads it every R_RenderFrame).
//
// tangents4: (tan(left), tan(right), tan(top), tan(bottom)) — all positive
// magnitudes; frustum spans -left..+right and -bottom..+top at the near
// plane (forward-Z OpenGL convention).
void lambda_engine_set_projection_tangents(const float *tangents4,
                                           float zNear, float zFar);
void lambda_engine_clear_projection_override(void);

// Head-tracked view: absolute pitch/roll + yaw delta (xash degrees), and
// head translation since baseline (baseline-forward frame, xash units).
// Normally driven via lambda_gl_worker_render_eye_full.
void lambda_engine_set_view_angles(float pitch_abs, float yaw_delta, float roll_abs);
void lambda_engine_set_view_offset(float x, float y, float z);
void lambda_engine_clear_view_angles(void);

// Engine render-target size (the colorMap the engine draws each eye into).
// Must be called BEFORE lambda_gl_worker_engine_init — R_Init_Video reads
// it once at renderer bring-up. Defaults to 2048x2048.
void lambda_engine_set_render_size(int width, int height);

// Posts an engine console command (Cbuf_AddText) onto the worker thread.
// Use to dispatch "+forward" / "-forward" / "+left" / etc. for input.
int lambda_gl_worker_cmd(const char *cmd);

// Sets where the crash handler writes the backtrace (one file, overwritten
// each crash). Call once at launch with a path inside the app sandbox.
void lambda_set_crash_log_path(const char *path);

// Per-frame begin/end. Wraps mtl_texture as the GL FBO color attachment,
// binds it, clears to (r,g,b,1). Any GL calls between begin and end go
// through ANGLE → Metal and land in mtl_texture. end_frame() finalises
// via eglWaitUntilWorkScheduledANGLE and detaches the FBO.
//
// Use this around lambda_engine_frame() to drive xash's renderer (via
// ref_gles3compat) into a Swift-owned MTLTexture.
//
// Returns 0 on success, negative on failure.
int lambda_gl_begin_frame_into_mtl_texture(void *mtl_texture,
                                           int width, int height,
                                           float r, float g, float b);
int lambda_gl_end_frame(void);

// Pause (0) / resume (1) the engine's audio output. Call when the render
// loop stops/resumes so the AudioQueue doesn't loop stale ring contents.
void lambda_snd_activate(int active);

// Stage a gamepad axis value for the engine's joystick input. Thread-safe;
// applied on the GL worker before the next tick. Axis: 0=SIDE (strafe),
// 1=FWD, 2=PITCH, 3=YAW, 4=RT, 5=LT. Value: SDL-style -32768..32767.
void lambda_joy_set_axis(int axis, int value);

// GPU-side frame fence. Register an MTLSharedEvent (borrowed, unretained)
// and the value end_frame should signal on ANGLE's command queue when the
// current eye's GPU work completes. The caller's MTLCommandQueue must
// waitForEvent(event, value) before reading the rendered texture. While a
// fence event is registered, end_frame no longer blocks in glFinish —
// call before EACH eye render with a strictly increasing value.
void lambda_gl_set_frame_fence(void *mtl_shared_event,
                               unsigned long long signal_value);

// ---- ANGLE / EGL smoke test ----
// Initializes EGL via ANGLE's Metal backend, makes a context current on a
// 1x1 pbuffer, reads GL_VERSION/GL_RENDERER/GL_VENDOR into status_out,
// tears down. Returns:
//   0 on success
//  -1 eglGetPlatformDisplay failed
//  -2 eglInitialize failed
//  -3 eglChooseConfig failed / no config
//  -4 eglCreateContext failed
//  -5 eglCreatePbufferSurface failed
//  -6 eglMakeCurrent failed
int lambda_gl_smoke_test(char *status_out, int status_cap);

#ifdef __cplusplus
}
#endif

#endif
