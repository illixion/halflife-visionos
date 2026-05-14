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

#ifdef __cplusplus
}
#endif

#endif
