#include "Lambda_Bridge.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <IOSurface/IOSurfaceRef.h>
#include <CoreFoundation/CoreFoundation.h>
#include "shaders/tri_shaders.h"
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

static VkInstance       g_instance = VK_NULL_HANDLE;
static VkDevice         g_device   = VK_NULL_HANDLE;
static VkPhysicalDevice g_phys     = VK_NULL_HANDLE;
static VkQueue          g_gfxQueue = VK_NULL_HANDLE;
static uint32_t         g_gfxFamily = 0;
static VkCommandPool    g_cmdPool  = VK_NULL_HANDLE;
static bool             g_hasMetalObjects   = false;
static bool             g_hasDynamicRender  = false;
static VkPipelineLayout g_triPipelineLayout = VK_NULL_HANDLE;
static VkPipeline       g_triPipeline       = VK_NULL_HANDLE;
static PFN_vkDestroyInstance     g_pfnDestroyInstance     = NULL;
static PFN_vkDestroyDevice       g_pfnDestroyDevice       = NULL;
static PFN_vkGetDeviceProcAddr   g_pfnGetDeviceProcAddr   = NULL;
static PFN_vkDestroyCommandPool  g_pfnDestroyCommandPool  = NULL;
static PFN_vkCmdBeginRenderingKHR g_pfnCmdBeginRendering  = NULL;
static PFN_vkCmdEndRenderingKHR   g_pfnCmdEndRendering    = NULL;

#define LOAD_INST(name) \
    PFN_##name pfn_##name = (PFN_##name)vkGetInstanceProcAddr(instance, #name)

int lambda_vulkan_create_device(char *status_out, int status_cap) {
    if (status_out && status_cap > 0) status_out[0] = '\0';
    if (g_device != VK_NULL_HANDLE) {
        if (status_out && status_cap > 0) {
            snprintf(status_out, (size_t)status_cap, "already initialized (metal_objects=%s)",
                     g_hasMetalObjects ? "yes" : "no");
        }
        return 0;
    }

    PFN_vkCreateInstance pfnCreateInstance =
        (PFN_vkCreateInstance)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
    if (!pfnCreateInstance) return -1;

    VkApplicationInfo appInfo = {0};
    appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "LambdaVision";
    appInfo.pEngineName = "Xash3D";
    appInfo.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo ici = {0};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &appInfo;

    VkInstance instance = VK_NULL_HANDLE;
    if (pfnCreateInstance(&ici, NULL, &instance) != VK_SUCCESS) return -1;

    LOAD_INST(vkEnumeratePhysicalDevices);
    LOAD_INST(vkGetPhysicalDeviceProperties);
    LOAD_INST(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_INST(vkEnumerateDeviceExtensionProperties);
    LOAD_INST(vkCreateDevice);
    LOAD_INST(vkGetDeviceQueue);
    LOAD_INST(vkDestroyInstance);
    LOAD_INST(vkDestroyDevice);

    g_pfnDestroyInstance = pfn_vkDestroyInstance;
    g_pfnDestroyDevice   = pfn_vkDestroyDevice;

    uint32_t devCount = 0;
    pfn_vkEnumeratePhysicalDevices(instance, &devCount, NULL);
    if (devCount == 0) {
        pfn_vkDestroyInstance(instance, NULL);
        return -2;
    }
    VkPhysicalDevice phys = VK_NULL_HANDLE;
    {
        VkPhysicalDevice devs[8];
        if (devCount > 8) devCount = 8;
        pfn_vkEnumeratePhysicalDevices(instance, &devCount, devs);
        phys = devs[0];
    }

    VkPhysicalDeviceProperties props;
    pfn_vkGetPhysicalDeviceProperties(phys, &props);

    uint32_t qfCount = 0;
    pfn_vkGetPhysicalDeviceQueueFamilyProperties(phys, &qfCount, NULL);
    if (qfCount == 0) {
        pfn_vkDestroyInstance(instance, NULL);
        return -3;
    }
    VkQueueFamilyProperties qfs[16];
    if (qfCount > 16) qfCount = 16;
    pfn_vkGetPhysicalDeviceQueueFamilyProperties(phys, &qfCount, qfs);

    uint32_t gfxFamily = UINT32_MAX;
    for (uint32_t i = 0; i < qfCount; ++i) {
        if (qfs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { gfxFamily = i; break; }
    }
    if (gfxFamily == UINT32_MAX) {
        pfn_vkDestroyInstance(instance, NULL);
        return -3;
    }

    bool hasMetalObjects = false;
    bool hasDynamicRender = false;
    {
        uint32_t extCount = 0;
        pfn_vkEnumerateDeviceExtensionProperties(phys, NULL, &extCount, NULL);
        if (extCount > 0) {
            VkExtensionProperties *exts = (VkExtensionProperties *)calloc(extCount, sizeof(*exts));
            if (exts) {
                pfn_vkEnumerateDeviceExtensionProperties(phys, NULL, &extCount, exts);
                for (uint32_t i = 0; i < extCount; ++i) {
                    if (strcmp(exts[i].extensionName, "VK_EXT_metal_objects") == 0)
                        hasMetalObjects = true;
                    if (strcmp(exts[i].extensionName, "VK_KHR_dynamic_rendering") == 0)
                        hasDynamicRender = true;
                }
                free(exts);
            }
        }
    }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {0};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = gfxFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    const char *enabledExts[2];
    uint32_t enabledExtCount = 0;
    if (hasMetalObjects)  enabledExts[enabledExtCount++] = "VK_EXT_metal_objects";
    if (hasDynamicRender) enabledExts[enabledExtCount++] = "VK_KHR_dynamic_rendering";

    VkPhysicalDeviceDynamicRenderingFeaturesKHR dynFeat = {0};
    dynFeat.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR;
    dynFeat.dynamicRendering = VK_TRUE;

    VkDeviceCreateInfo dci = {0};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    if (hasDynamicRender) dci.pNext = &dynFeat;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = enabledExtCount;
    dci.ppEnabledExtensionNames = enabledExts;

    VkDevice device = VK_NULL_HANDLE;
    if (pfn_vkCreateDevice(phys, &dci, NULL, &device) != VK_SUCCESS) {
        pfn_vkDestroyInstance(instance, NULL);
        return -4;
    }

    VkQueue q = VK_NULL_HANDLE;
    pfn_vkGetDeviceQueue(device, gfxFamily, 0, &q);

    PFN_vkGetDeviceProcAddr pfnGetDevAddr =
        (PFN_vkGetDeviceProcAddr)vkGetInstanceProcAddr(instance, "vkGetDeviceProcAddr");
    PFN_vkCreateCommandPool pfnCreatePool =
        (PFN_vkCreateCommandPool)pfnGetDevAddr(device, "vkCreateCommandPool");
    PFN_vkDestroyCommandPool pfnDestroyPool =
        (PFN_vkDestroyCommandPool)pfnGetDevAddr(device, "vkDestroyCommandPool");

    VkCommandPoolCreateInfo cpci = {0};
    cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = gfxFamily;
    VkCommandPool pool = VK_NULL_HANDLE;
    if (pfnCreatePool(device, &cpci, NULL, &pool) != VK_SUCCESS) {
        pfn_vkDestroyDevice(device, NULL);
        pfn_vkDestroyInstance(instance, NULL);
        return -4;
    }

    g_instance = instance;
    g_device   = device;
    g_phys     = phys;
    g_gfxQueue = q;
    g_gfxFamily = gfxFamily;
    g_cmdPool  = pool;
    g_hasMetalObjects  = hasMetalObjects;
    g_hasDynamicRender = hasDynamicRender;
    g_pfnGetDeviceProcAddr  = pfnGetDevAddr;
    g_pfnDestroyCommandPool = pfnDestroyPool;
    if (hasDynamicRender) {
        g_pfnCmdBeginRendering = (PFN_vkCmdBeginRenderingKHR)pfnGetDevAddr(device, "vkCmdBeginRenderingKHR");
        g_pfnCmdEndRendering   = (PFN_vkCmdEndRenderingKHR)pfnGetDevAddr(device, "vkCmdEndRenderingKHR");
    }

    if (status_out && status_cap > 0) {
        snprintf(status_out, (size_t)status_cap,
                 "%s api %u.%u.%u, gfx qfam=%u, metal_objects=%s",
                 props.deviceName,
                 VK_VERSION_MAJOR(props.apiVersion),
                 VK_VERSION_MINOR(props.apiVersion),
                 VK_VERSION_PATCH(props.apiVersion),
                 gfxFamily,
                 hasMetalObjects ? "yes" : "no");
    }
    return 0;
}

void lambda_vulkan_destroy_device(void) {
    if (g_cmdPool && g_device && g_pfnDestroyCommandPool) {
        g_pfnDestroyCommandPool(g_device, g_cmdPool, NULL);
    }
    if (g_device && g_pfnDestroyDevice) {
        g_pfnDestroyDevice(g_device, NULL);
    }
    if (g_instance && g_pfnDestroyInstance) {
        g_pfnDestroyInstance(g_instance, NULL);
    }
    g_cmdPool = VK_NULL_HANDLE;
    g_device = VK_NULL_HANDLE;
    g_instance = VK_NULL_HANDLE;
    g_phys = VK_NULL_HANDLE;
    g_gfxQueue = VK_NULL_HANDLE;
    g_pfnGetDeviceProcAddr = NULL;
    g_pfnDestroyCommandPool = NULL;
    g_hasMetalObjects = false;
}

#define DEVFN(name) PFN_##name pfn_##name = (PFN_##name)g_pfnGetDeviceProcAddr(g_device, #name)

// fourcc: 'BGRA' (32BGRA, 4 bpp) or 'RGhA' (64RGBAHalf, 8 bpp).
static IOSurfaceRef create_iosurface_fmt(int w, int h, uint32_t fourcc, int bytesPerElement) {
    const size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * (size_t)bytesPerElement);
    const size_t totalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * (size_t)h);

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
#define SET_INT(key, val) do { \
    int v = (int)(val); CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v); \
    CFDictionarySetValue(props, key, n); CFRelease(n); \
} while (0)
    SET_INT(kIOSurfaceWidth, w);
    SET_INT(kIOSurfaceHeight, h);
    SET_INT(kIOSurfaceBytesPerElement, bytesPerElement);
    SET_INT(kIOSurfaceBytesPerRow, (int)bpr);
    SET_INT(kIOSurfaceAllocSize, (int)totalBytes);
    SET_INT(kIOSurfacePixelFormat, (int)fourcc);
#undef SET_INT
    IOSurfaceRef s = IOSurfaceCreate(props);
    CFRelease(props);
    return s;
}

static IOSurfaceRef create_bgra8_iosurface(int w, int h) {
    return create_iosurface_fmt(w, h, 'BGRA', 4);
}

static IOSurfaceRef create_rgba16f_iosurface(int w, int h) {
    return create_iosurface_fmt(w, h, 'RGhA', 8);  // kCVPixelFormatType_64RGBAHalf
}

void *lambda_vulkan_clear_iosurface(int width, int height,
                                    float r, float g, float b,
                                    char *status_out, int status_cap) {
    if (status_out && status_cap > 0) status_out[0] = '\0';
    if (!g_device || !g_cmdPool || !g_pfnGetDeviceProcAddr) {
        if (status_out) snprintf(status_out, (size_t)status_cap, "device not initialized");
        return NULL;
    }
    if (!g_hasMetalObjects) {
        if (status_out) snprintf(status_out, (size_t)status_cap, "VK_EXT_metal_objects unavailable");
        return NULL;
    }

    IOSurfaceRef surface = create_bgra8_iosurface(width, height);
    if (!surface) {
        if (status_out) snprintf(status_out, (size_t)status_cap, "IOSurfaceCreate failed");
        return NULL;
    }

    DEVFN(vkCreateImage);
    DEVFN(vkDestroyImage);
    DEVFN(vkGetImageMemoryRequirements);
    DEVFN(vkAllocateMemory);
    DEVFN(vkFreeMemory);
    DEVFN(vkBindImageMemory);
    DEVFN(vkAllocateCommandBuffers);
    DEVFN(vkFreeCommandBuffers);
    DEVFN(vkBeginCommandBuffer);
    DEVFN(vkEndCommandBuffer);
    DEVFN(vkCmdPipelineBarrier);
    DEVFN(vkCmdClearColorImage);
    DEVFN(vkQueueSubmit);
    DEVFN(vkQueueWaitIdle);

    VkImportMetalIOSurfaceInfoEXT importInfo = {0};
    importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT;
    importInfo.ioSurface = surface;

    VkImageCreateInfo ici = {0};
    ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ici.pNext = &importInfo;
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = VK_FORMAT_B8G8R8A8_UNORM;
    ici.extent.width = (uint32_t)width;
    ici.extent.height = (uint32_t)height;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkImage image = VK_NULL_HANDLE;
    if (pfn_vkCreateImage(g_device, &ici, NULL, &image) != VK_SUCCESS) {
        if (status_out) snprintf(status_out, (size_t)status_cap, "vkCreateImage failed");
        CFRelease(surface);
        return NULL;
    }

    VkMemoryRequirements memReq;
    pfn_vkGetImageMemoryRequirements(g_device, image, &memReq);

    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = memReq.size ? memReq.size : 1;
    mai.memoryTypeIndex = 0;  // MoltenVK ignores for IOSurface-backed images

    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (pfn_vkAllocateMemory(g_device, &mai, NULL, &memory) != VK_SUCCESS) {
        if (status_out) snprintf(status_out, (size_t)status_cap, "vkAllocateMemory failed");
        pfn_vkDestroyImage(g_device, image, NULL);
        CFRelease(surface);
        return NULL;
    }
    if (pfn_vkBindImageMemory(g_device, image, memory, 0) != VK_SUCCESS) {
        if (status_out) snprintf(status_out, (size_t)status_cap, "vkBindImageMemory failed");
        pfn_vkFreeMemory(g_device, memory, NULL);
        pfn_vkDestroyImage(g_device, image, NULL);
        CFRelease(surface);
        return NULL;
    }

    VkCommandBufferAllocateInfo cbai = {0};
    cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = g_cmdPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    pfn_vkAllocateCommandBuffers(g_device, &cbai, &cb);

    VkCommandBufferBeginInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    pfn_vkBeginCommandBuffer(cb, &bi);

    VkImageSubresourceRange range = {0};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    VkImageMemoryBarrier toDst = {0};
    toDst.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toDst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    toDst.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toDst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toDst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toDst.image = image;
    toDst.subresourceRange = range;
    toDst.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    pfn_vkCmdPipelineBarrier(cb,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &toDst);

    VkClearColorValue clear = {0};
    clear.float32[0] = r; clear.float32[1] = g;
    clear.float32[2] = b; clear.float32[3] = 1.0f;
    pfn_vkCmdClearColorImage(cb, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                             &clear, 1, &range);

    VkImageMemoryBarrier toGen = toDst;
    toGen.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toGen.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    toGen.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toGen.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    pfn_vkCmdPipelineBarrier(cb,
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0, 0, NULL, 0, NULL, 1, &toGen);

    pfn_vkEndCommandBuffer(cb);

    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    VkResult subRes = pfn_vkQueueSubmit(g_gfxQueue, 1, &si, VK_NULL_HANDLE);
    VkResult waitRes = (subRes == VK_SUCCESS) ? pfn_vkQueueWaitIdle(g_gfxQueue) : subRes;

    pfn_vkFreeCommandBuffers(g_device, g_cmdPool, 1, &cb);
    pfn_vkFreeMemory(g_device, memory, NULL);
    pfn_vkDestroyImage(g_device, image, NULL);

    if (subRes != VK_SUCCESS || waitRes != VK_SUCCESS) {
        if (status_out) snprintf(status_out, (size_t)status_cap,
                                 "submit=%d wait=%d", subRes, waitRes);
        CFRelease(surface);
        return NULL;
    }

    if (status_out) snprintf(status_out, (size_t)status_cap,
                             "ok %dx%d (rgba=%.2f,%.2f,%.2f,1)",
                             width, height, r, g, b);
    return (void *)surface;  // caller releases with CFRelease
}

#define POOL_SLOTS 3
#define POOL_EYES 2

typedef struct {
    IOSurfaceRef    surface;
    VkImage         image;
    VkImageView     view;
    VkDeviceMemory  memory;
    VkCommandBuffer cmd;
    int             width;
    int             height;
} EyeSlot;

static EyeSlot g_pool[POOL_SLOTS][POOL_EYES];

static void destroy_eye_slot(EyeSlot *e) {
    DEVFN(vkFreeCommandBuffers);
    DEVFN(vkDestroyImage);
    DEVFN(vkDestroyImageView);
    DEVFN(vkFreeMemory);
    if (e->cmd && g_cmdPool) {
        pfn_vkFreeCommandBuffers(g_device, g_cmdPool, 1, &e->cmd);
    }
    if (e->view) pfn_vkDestroyImageView(g_device, e->view, NULL);
    if (e->image) pfn_vkDestroyImage(g_device, e->image, NULL);
    if (e->memory) pfn_vkFreeMemory(g_device, e->memory, NULL);
    if (e->surface) CFRelease(e->surface);
    memset(e, 0, sizeof(*e));
}

static bool alloc_eye_slot(EyeSlot *e, int w, int h) {
    DEVFN(vkCreateImage);
    DEVFN(vkGetImageMemoryRequirements);
    DEVFN(vkAllocateMemory);
    DEVFN(vkBindImageMemory);
    DEVFN(vkAllocateCommandBuffers);

    // Use 64-bit RGBA-half format to match the visionOS CompositorServices
    // drawable color texture (rgba16Float), so MTL copy works without
    // format/stride mismatches.
    IOSurfaceRef surface = create_rgba16f_iosurface(w, h);
    if (!surface) return false;

    VkImportMetalIOSurfaceInfoEXT importInfo = {0};
    importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT;
    importInfo.ioSurface = surface;

    VkImageCreateInfo ici = {0};
    ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ici.pNext = &importInfo;
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = VK_FORMAT_R16G16B16A16_SFLOAT;
    ici.extent.width = (uint32_t)w;
    ici.extent.height = (uint32_t)h;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkImage image = VK_NULL_HANDLE;
    if (pfn_vkCreateImage(g_device, &ici, NULL, &image) != VK_SUCCESS) {
        CFRelease(surface);
        return false;
    }

    VkMemoryRequirements memReq;
    pfn_vkGetImageMemoryRequirements(g_device, image, &memReq);
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = memReq.size ? memReq.size : 1;
    mai.memoryTypeIndex = 0;

    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (pfn_vkAllocateMemory(g_device, &mai, NULL, &memory) != VK_SUCCESS) {
        DEVFN(vkDestroyImage);
        pfn_vkDestroyImage(g_device, image, NULL);
        CFRelease(surface);
        return false;
    }
    if (pfn_vkBindImageMemory(g_device, image, memory, 0) != VK_SUCCESS) {
        DEVFN(vkDestroyImage);
        DEVFN(vkFreeMemory);
        pfn_vkFreeMemory(g_device, memory, NULL);
        pfn_vkDestroyImage(g_device, image, NULL);
        CFRelease(surface);
        return false;
    }

    VkCommandBufferAllocateInfo cbai = {0};
    cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = g_cmdPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    if (pfn_vkAllocateCommandBuffers(g_device, &cbai, &cb) != VK_SUCCESS) {
        DEVFN(vkDestroyImage);
        DEVFN(vkFreeMemory);
        pfn_vkFreeMemory(g_device, memory, NULL);
        pfn_vkDestroyImage(g_device, image, NULL);
        CFRelease(surface);
        return false;
    }

    DEVFN(vkCreateImageView);
    DEVFN(vkDestroyImage);
    DEVFN(vkFreeMemory);
    VkImageViewCreateInfo ivci = {0};
    ivci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ivci.image = image;
    ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    ivci.format = VK_FORMAT_R16G16B16A16_SFLOAT;
    ivci.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
    ivci.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
    ivci.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
    ivci.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
    ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    ivci.subresourceRange.levelCount = 1;
    ivci.subresourceRange.layerCount = 1;
    VkImageView view = VK_NULL_HANDLE;
    if (pfn_vkCreateImageView(g_device, &ivci, NULL, &view) != VK_SUCCESS) {
        pfn_vkFreeMemory(g_device, memory, NULL);
        pfn_vkDestroyImage(g_device, image, NULL);
        CFRelease(surface);
        return false;
    }

    e->surface = surface;
    e->image = image;
    e->view = view;
    e->memory = memory;
    e->cmd = cb;
    e->width = w;
    e->height = h;
    return true;
}

static bool ensure_tri_pipeline(void) {
    if (g_triPipeline != VK_NULL_HANDLE) return true;
    if (!g_hasDynamicRender) return false;

    DEVFN(vkCreateShaderModule);
    DEVFN(vkDestroyShaderModule);
    DEVFN(vkCreatePipelineLayout);
    DEVFN(vkCreateGraphicsPipelines);

    VkShaderModuleCreateInfo vsmCi = {0};
    vsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    vsmCi.codeSize = tri_vert_spv_len;
    vsmCi.pCode = (const uint32_t *)tri_vert_spv;

    VkShaderModule vsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &vsmCi, NULL, &vsm) != VK_SUCCESS) return false;

    VkShaderModuleCreateInfo fsmCi = {0};
    fsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    fsmCi.codeSize = tri_frag_spv_len;
    fsmCi.pCode = (const uint32_t *)tri_frag_spv;

    VkShaderModule fsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &fsmCi, NULL, &fsm) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPushConstantRange pcRange = {0};
    pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcRange.offset = 0;
    pcRange.size = sizeof(float);

    VkPipelineLayoutCreateInfo plCi = {0};
    plCi.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCi.pushConstantRangeCount = 1;
    plCi.pPushConstantRanges = &pcRange;
    if (pfn_vkCreatePipelineLayout(g_device, &plCi, NULL, &g_triPipelineLayout) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, fsm, NULL);
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vsm;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fsm;
    stages[1].pName = "main";

    VkPipelineVertexInputStateCreateInfo vi = {0};
    vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    VkPipelineInputAssemblyStateCreateInfo ia = {0};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkPipelineViewportStateCreateInfo vp = {0};
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1;
    vp.scissorCount = 1;

    VkPipelineRasterizationStateCreateInfo rs = {0};
    rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms = {0};
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineColorBlendAttachmentState blendAtt = {0};
    blendAtt.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1;
    cb.pAttachments = &blendAtt;

    VkDynamicState dynStates[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = {0};
    dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn.dynamicStateCount = 2;
    dyn.pDynamicStates = dynStates;

    VkFormat colorFmt = VK_FORMAT_R16G16B16A16_SFLOAT;
    VkPipelineRenderingCreateInfoKHR prCi = {0};
    prCi.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    prCi.colorAttachmentCount = 1;
    prCi.pColorAttachmentFormats = &colorFmt;

    VkGraphicsPipelineCreateInfo gpCi = {0};
    gpCi.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gpCi.pNext = &prCi;
    gpCi.stageCount = 2;
    gpCi.pStages = stages;
    gpCi.pVertexInputState = &vi;
    gpCi.pInputAssemblyState = &ia;
    gpCi.pViewportState = &vp;
    gpCi.pRasterizationState = &rs;
    gpCi.pMultisampleState = &ms;
    gpCi.pColorBlendState = &cb;
    gpCi.pDynamicState = &dyn;
    gpCi.layout = g_triPipelineLayout;
    gpCi.renderPass = VK_NULL_HANDLE;  // dynamic rendering

    VkResult pres = pfn_vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpCi, NULL, &g_triPipeline);

    pfn_vkDestroyShaderModule(g_device, fsm, NULL);
    pfn_vkDestroyShaderModule(g_device, vsm, NULL);

    return pres == VK_SUCCESS;
}

const void *lambda_vulkan_render_eye_pooled(int slot, int eye,
                                            int width, int height,
                                            float r, float g, float b,
                                            float time) {
    if (!g_device || !g_cmdPool || !g_hasMetalObjects) return NULL;
    if (!g_hasDynamicRender) return NULL;
    if (slot < 0 || slot >= POOL_SLOTS || eye < 0 || eye >= POOL_EYES) return NULL;
    if (!ensure_tri_pipeline()) return NULL;

    EyeSlot *e = &g_pool[slot][eye];
    if (e->surface && (e->width != width || e->height != height)) {
        destroy_eye_slot(e);
    }
    if (!e->surface) {
        if (!alloc_eye_slot(e, width, height)) return NULL;
    }

    DEVFN(vkBeginCommandBuffer);
    DEVFN(vkEndCommandBuffer);
    DEVFN(vkCmdPipelineBarrier);
    DEVFN(vkCmdBindPipeline);
    DEVFN(vkCmdSetViewport);
    DEVFN(vkCmdSetScissor);
    DEVFN(vkCmdPushConstants);
    DEVFN(vkCmdDraw);
    DEVFN(vkResetCommandBuffer);
    DEVFN(vkQueueSubmit);
    DEVFN(vkQueueWaitIdle);

    pfn_vkResetCommandBuffer(e->cmd, 0);

    VkCommandBufferBeginInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    pfn_vkBeginCommandBuffer(e->cmd, &bi);

    VkImageSubresourceRange range = {0};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    // UNDEFINED → COLOR_ATTACHMENT_OPTIMAL
    VkImageMemoryBarrier toAtt = {0};
    toAtt.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toAtt.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    toAtt.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    toAtt.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toAtt.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toAtt.image = e->image;
    toAtt.subresourceRange = range;
    toAtt.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    pfn_vkCmdPipelineBarrier(e->cmd,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        0, 0, NULL, 0, NULL, 1, &toAtt);

    // Begin dynamic-rendering pass with clear (r,g,b,1).
    VkRenderingAttachmentInfoKHR colorAtt = {0};
    colorAtt.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR;
    colorAtt.imageView = e->view;
    colorAtt.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAtt.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAtt.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    colorAtt.clearValue.color.float32[0] = r;
    colorAtt.clearValue.color.float32[1] = g;
    colorAtt.clearValue.color.float32[2] = b;
    colorAtt.clearValue.color.float32[3] = 1.0f;

    VkRenderingInfoKHR ri = {0};
    ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO_KHR;
    ri.renderArea.offset.x = 0;
    ri.renderArea.offset.y = 0;
    ri.renderArea.extent.width = (uint32_t)width;
    ri.renderArea.extent.height = (uint32_t)height;
    ri.layerCount = 1;
    ri.colorAttachmentCount = 1;
    ri.pColorAttachments = &colorAtt;
    g_pfnCmdBeginRendering(e->cmd, &ri);

    VkViewport vpRect = {0};
    vpRect.x = 0; vpRect.y = 0;
    vpRect.width = (float)width; vpRect.height = (float)height;
    vpRect.minDepth = 0.0f; vpRect.maxDepth = 1.0f;
    pfn_vkCmdSetViewport(e->cmd, 0, 1, &vpRect);

    VkRect2D scissor = {0};
    scissor.extent.width = (uint32_t)width;
    scissor.extent.height = (uint32_t)height;
    pfn_vkCmdSetScissor(e->cmd, 0, 1, &scissor);

    pfn_vkCmdBindPipeline(e->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_triPipeline);
    pfn_vkCmdPushConstants(e->cmd, g_triPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                           0, sizeof(float), &time);
    pfn_vkCmdDraw(e->cmd, 3, 1, 0, 0);

    g_pfnCmdEndRendering(e->cmd);

    // COLOR_ATTACHMENT_OPTIMAL → GENERAL (so Metal can sample on the way out)
    VkImageMemoryBarrier toGen = toAtt;
    toGen.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    toGen.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    toGen.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    toGen.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    pfn_vkCmdPipelineBarrier(e->cmd,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0, 0, NULL, 0, NULL, 1, &toGen);

    pfn_vkEndCommandBuffer(e->cmd);

    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &e->cmd;
    if (pfn_vkQueueSubmit(g_gfxQueue, 1, &si, VK_NULL_HANDLE) != VK_SUCCESS) return NULL;
    if (pfn_vkQueueWaitIdle(g_gfxQueue) != VK_SUCCESS) return NULL;

    return (const void *)e->surface;
}

void lambda_vulkan_release_pool(void) {
    if (!g_device) return;
    for (int s = 0; s < POOL_SLOTS; ++s) {
        for (int e = 0; e < POOL_EYES; ++e) {
            destroy_eye_slot(&g_pool[s][e]);
        }
    }
    if (g_triPipeline || g_triPipelineLayout) {
        DEVFN(vkDestroyPipeline);
        DEVFN(vkDestroyPipelineLayout);
        if (g_triPipeline) pfn_vkDestroyPipeline(g_device, g_triPipeline, NULL);
        if (g_triPipelineLayout) pfn_vkDestroyPipelineLayout(g_device, g_triPipelineLayout, NULL);
        g_triPipeline = VK_NULL_HANDLE;
        g_triPipelineLayout = VK_NULL_HANDLE;
    }
}

// =====================================================================
// Phase 2c: xash3d-fwgs engine wiring.
// =====================================================================
//
// Engine entrypoints exposed by our patched Host_Main (libxash.a):
//   Host_DoInit  — init body of the original Host_Main minus its loop
//   Host_DoFrame — one iteration (one COM_Frame call)
//   Host_Shutdown
extern int Host_DoInit(int argc, char **argv, const char *progname,
                       int bChangeGame, void (*pChangeGame)(const char *));
extern int Host_DoFrame(void);
extern void Host_Shutdown(void);

#include <unistd.h>
#include <sys/stat.h>

static int g_engine_inited = 0;
static char *g_engine_argv_storage[32];
static char  g_engine_argv0[16];

// IN_ActivateMouse / IN_DeactivateMouse / IN_MouseEvent are renamed in the
// engine prelink (build_xash_libxash.sh) and hidden in the cl_dll prelink.
// We supply the canonical no-op symbols here so that:
//   - intra-engine callers (in_keys.c) resolve safely on visionOS,
//   - dlsym(RTLD_DEFAULT, "IN_*") in cl_game.c finds non-NULL pointers to
//     satisfy the cdll_exports[] mandatory check (cl_dll's mouse path is
//     not wired up yet — Phase 3 will replace these with real handlers).
__attribute__((used, visibility("default")))
void IN_ActivateMouse(void) {}

__attribute__((used, visibility("default")))
void IN_DeactivateMouse(void) {}

__attribute__((used, visibility("default")))
void IN_MouseEvent(int mstate, int down) { (void)mstate; (void)down; }

int lambda_engine_init(const char *writable_dir,
                       int extra_argc, const char *const *extra_argv,
                       char *status_out, int status_cap) {
    if (status_out && status_cap > 0) status_out[0] = '\0';
    if (g_engine_inited) {
        if (status_out) snprintf(status_out, status_cap, "engine already initialized");
        return 0;
    }
    if (!writable_dir || !*writable_dir) {
        if (status_out) snprintf(status_out, status_cap, "writable_dir required");
        return -1;
    }

    // Engine wants getcwd() to point at the data root, OR XASH3D_BASEDIR env.
    // Set both — belt and suspenders.
    mkdir(writable_dir, 0755);
    setenv("XASH3D_BASEDIR", writable_dir, 1);
    if (chdir(writable_dir) != 0) {
        if (status_out) snprintf(status_out, status_cap, "chdir(%s) failed", writable_dir);
        return -2;
    }

    // Build argv[]. argv[0] is the binary name; engine inspects it.
    snprintf(g_engine_argv0, sizeof(g_engine_argv0), "xash");
    int argc = 0;
    g_engine_argv_storage[argc++] = g_engine_argv0;

    int cap = (int)(sizeof(g_engine_argv_storage)/sizeof(g_engine_argv_storage[0])) - 2;
    if (extra_argc > cap) extra_argc = cap;
    for (int i = 0; i < extra_argc; ++i) {
        g_engine_argv_storage[argc++] = (char *)extra_argv[i];
    }
    g_engine_argv_storage[argc] = NULL;

    int rc = Host_DoInit(argc, g_engine_argv_storage, "valve",
                         /*bChangeGame=*/0, /*pChangeGame=*/NULL);
    if (rc != 0) {
        if (status_out) snprintf(status_out, status_cap, "Host_DoInit returned %d", rc);
        return -3;
    }

    g_engine_inited = 1;
    if (status_out) snprintf(status_out, status_cap,
                             "engine init ok (argc=%d, basedir=%s)", argc, writable_dir);
    return 0;
}

int lambda_engine_frame(void) {
    if (!g_engine_inited) return -1;
    return Host_DoFrame();
}

void lambda_engine_shutdown(void) {
    if (!g_engine_inited) return;
    Host_Shutdown();
    g_engine_inited = 0;
}
