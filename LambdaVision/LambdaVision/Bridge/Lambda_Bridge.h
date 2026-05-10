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

#ifdef __cplusplus
}
#endif

#endif
