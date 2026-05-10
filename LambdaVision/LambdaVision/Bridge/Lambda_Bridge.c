#include "Lambda_Bridge.h"
#include <string.h>
#include <stdio.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
// MoltenVK exposes the standard ICD entrypoints; we link statically against
// libMoltenVK.a, so the core Vulkan symbols resolve at link time.

int lambda_bridge_smoke_test(void) {
    return 0xCAFE;
}

// Forward-declare the entrypoints we use, then dlsym-style resolve via
// vkGetInstanceProcAddr. Avoids static-link order pitfalls and works whether
// MoltenVK is wired as a static archive or a dylib.
typedef PFN_vkVoidFunction (VKAPI_PTR *PFN_vkGetInstanceProcAddr_t)(VkInstance, const char*);

// MoltenVK exports vkGetInstanceProcAddr directly.
extern PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char* pName);

int lambda_vulkan_smoke_test(char *name_out, int name_cap) {
    if (name_out && name_cap > 0) name_out[0] = '\0';

    PFN_vkCreateInstance pfnCreateInstance =
        (PFN_vkCreateInstance)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
    if (!pfnCreateInstance) return -1;

    VkApplicationInfo appInfo = {0};
    appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "LambdaVision";
    appInfo.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
    appInfo.pEngineName = "Xash3D";
    appInfo.engineVersion = VK_MAKE_VERSION(0, 99, 0);
    appInfo.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo ci = {0};
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = &appInfo;
    // MoltenVK on visionOS exposes Vulkan 1.4 directly — no portability shim needed.
    ci.enabledExtensionCount = 0;
    ci.ppEnabledExtensionNames = NULL;

    VkInstance instance = VK_NULL_HANDLE;
    if (pfnCreateInstance(&ci, NULL, &instance) != VK_SUCCESS) return -1;

    PFN_vkEnumeratePhysicalDevices pfnEnum =
        (PFN_vkEnumeratePhysicalDevices)vkGetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties pfnProps =
        (PFN_vkGetPhysicalDeviceProperties)vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties");
    PFN_vkDestroyInstance pfnDestroy =
        (PFN_vkDestroyInstance)vkGetInstanceProcAddr(instance, "vkDestroyInstance");
    if (!pfnEnum || !pfnProps || !pfnDestroy) {
        if (pfnDestroy) pfnDestroy(instance, NULL);
        return -2;
    }

    uint32_t count = 0;
    if (pfnEnum(instance, &count, NULL) != VK_SUCCESS) {
        pfnDestroy(instance, NULL);
        return -2;
    }
    if (count == 0) {
        pfnDestroy(instance, NULL);
        return -3;
    }

    VkPhysicalDevice devs[8];
    if (count > 8) count = 8;
    pfnEnum(instance, &count, devs);

    if (name_out && name_cap > 0) {
        VkPhysicalDeviceProperties p;
        pfnProps(devs[0], &p);
        snprintf(name_out, (size_t)name_cap, "%s (api %u.%u.%u)",
                 p.deviceName,
                 VK_VERSION_MAJOR(p.apiVersion),
                 VK_VERSION_MINOR(p.apiVersion),
                 VK_VERSION_PATCH(p.apiVersion));
    }

    pfnDestroy(instance, NULL);
    return (int)count;
}
