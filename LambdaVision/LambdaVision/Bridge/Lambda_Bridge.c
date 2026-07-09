#include "Lambda_Bridge.h"
#include "Lambda_WeaponModel.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

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
static VkPipelineLayout g_quadPipelineLayout = VK_NULL_HANDLE;
static VkPipeline       g_quadPipeline       = VK_NULL_HANDLE;
static int      g_active_slot   = -1;
static int      g_active_eye    = -1;
static VkCommandBuffer g_active_cmd = VK_NULL_HANDLE;

#define TEX_POOL_MAX 1024
typedef struct {
    bool            used;
    VkImage         image;
    VkImageView     view;
    VkDeviceMemory  memory;
    VkDescriptorSet descSet;
    int             width;
    int             height;
} BridgeTexture;
static BridgeTexture g_textures[TEX_POOL_MAX];
static VkSampler             g_texSampler  = VK_NULL_HANDLE;
static VkDescriptorSetLayout g_texDSL      = VK_NULL_HANDLE;
static VkDescriptorPool      g_texDescPool = VK_NULL_HANDLE;
static VkPipelineLayout      g_texQuadPipelineLayout = VK_NULL_HANDLE;
static VkPipeline            g_texQuadPipeline       = VK_NULL_HANDLE;
static VkPipelineLayout      g_axesPipelineLayout    = VK_NULL_HANDLE;
static VkPipeline            g_axesPipeline          = VK_NULL_HANDLE;
static VkBuffer              g_axesVB                = VK_NULL_HANDLE;
static VkDeviceMemory        g_axesVBMem             = VK_NULL_HANDLE;
static VkPipelineLayout      g_worldPipelineLayout   = VK_NULL_HANDLE;
static VkPipeline            g_worldPipeline         = VK_NULL_HANDLE;
static VkBuffer              g_worldVB               = VK_NULL_HANDLE;
static VkDeviceMemory        g_worldVBMem            = VK_NULL_HANDLE;
static int                   g_worldVertexCount      = 0;
static lambda_bridge_world_batch *g_worldBatches    = NULL;
static int                   g_worldBatchCount      = 0;
static uint32_t              g_worldWhiteTex        = 0; // 1x1 white fallback
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
    VkImage         depthImage;
    VkImageView     depthView;
    VkDeviceMemory  depthMemory;
    VkCommandBuffer cmd;
    int             width;
    int             height;
} EyeSlot;

static EyeSlot g_pool[POOL_SLOTS][POOL_EYES];

static uint32_t find_memory_type(uint32_t typeBits, VkMemoryPropertyFlags required) {
    PFN_vkGetPhysicalDeviceMemoryProperties pfnMP =
        (PFN_vkGetPhysicalDeviceMemoryProperties)
        vkGetInstanceProcAddr(g_instance, "vkGetPhysicalDeviceMemoryProperties");
    if (!pfnMP) return UINT32_MAX;
    VkPhysicalDeviceMemoryProperties mp;
    pfnMP(g_phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
        if (!(typeBits & (1u << i))) continue;
        if ((mp.memoryTypes[i].propertyFlags & required) == required) return i;
    }
    return UINT32_MAX;
}

static void destroy_eye_slot(EyeSlot *e) {
    DEVFN(vkFreeCommandBuffers);
    DEVFN(vkDestroyImage);
    DEVFN(vkDestroyImageView);
    DEVFN(vkFreeMemory);
    if (e->cmd && g_cmdPool) {
        pfn_vkFreeCommandBuffers(g_device, g_cmdPool, 1, &e->cmd);
    }
    if (e->depthView) pfn_vkDestroyImageView(g_device, e->depthView, NULL);
    if (e->depthImage) pfn_vkDestroyImage(g_device, e->depthImage, NULL);
    if (e->depthMemory) pfn_vkFreeMemory(g_device, e->depthMemory, NULL);
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

    // Depth buffer (D32_SFLOAT, device-local). World 3D pipelines depth-test
    // against this; 2D pipelines explicitly disable depth.
    VkImage depthImage = VK_NULL_HANDLE;
    VkImageView depthView = VK_NULL_HANDLE;
    VkDeviceMemory depthMem = VK_NULL_HANDLE;
    {
        VkImageCreateInfo dici = {0};
        dici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        dici.imageType = VK_IMAGE_TYPE_2D;
        dici.format = VK_FORMAT_D32_SFLOAT;
        dici.extent.width = (uint32_t)w;
        dici.extent.height = (uint32_t)h;
        dici.extent.depth = 1;
        dici.mipLevels = 1;
        dici.arrayLayers = 1;
        dici.samples = VK_SAMPLE_COUNT_1_BIT;
        dici.tiling = VK_IMAGE_TILING_OPTIMAL;
        dici.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        dici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        DEVFN(vkCreateImage);
        if (pfn_vkCreateImage(g_device, &dici, NULL, &depthImage) != VK_SUCCESS) goto depth_fail;
        VkMemoryRequirements dreq;
        DEVFN(vkGetImageMemoryRequirements);
        pfn_vkGetImageMemoryRequirements(g_device, depthImage, &dreq);
        uint32_t dmt = find_memory_type(dreq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (dmt == UINT32_MAX) dmt = 0;
        VkMemoryAllocateInfo dmai = {0};
        dmai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        dmai.allocationSize = dreq.size;
        dmai.memoryTypeIndex = dmt;
        DEVFN(vkAllocateMemory);
        DEVFN(vkBindImageMemory);
        if (pfn_vkAllocateMemory(g_device, &dmai, NULL, &depthMem) != VK_SUCCESS) goto depth_fail;
        pfn_vkBindImageMemory(g_device, depthImage, depthMem, 0);
        VkImageViewCreateInfo divci = {0};
        divci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        divci.image = depthImage;
        divci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        divci.format = VK_FORMAT_D32_SFLOAT;
        divci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
        divci.subresourceRange.levelCount = 1;
        divci.subresourceRange.layerCount = 1;
        DEVFN(vkCreateImageView);
        if (pfn_vkCreateImageView(g_device, &divci, NULL, &depthView) != VK_SUCCESS) goto depth_fail;
    }

    e->surface = surface;
    e->image = image;
    e->view = view;
    e->memory = memory;
    e->depthImage = depthImage;
    e->depthView = depthView;
    e->depthMemory = depthMem;
    e->cmd = cb;
    e->width = w;
    e->height = h;
    return true;

depth_fail:
    { DEVFN(vkDestroyImageView); DEVFN(vkDestroyImage); DEVFN(vkFreeMemory);
      if (depthView) pfn_vkDestroyImageView(g_device, depthView, NULL);
      if (depthImage) pfn_vkDestroyImage(g_device, depthImage, NULL);
      if (depthMem) pfn_vkFreeMemory(g_device, depthMem, NULL);
      pfn_vkDestroyImageView(g_device, view, NULL);
      pfn_vkFreeMemory(g_device, memory, NULL);
      pfn_vkDestroyImage(g_device, image, NULL); }
    CFRelease(surface);
    return false;
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
    prCi.depthAttachmentFormat = VK_FORMAT_D32_SFLOAT;

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
    VkPipelineDepthStencilStateCreateInfo dsOff = {0};
    dsOff.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    gpCi.pDepthStencilState = &dsOff;
    gpCi.layout = g_triPipelineLayout;
    gpCi.renderPass = VK_NULL_HANDLE;  // dynamic rendering

    VkResult pres = pfn_vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpCi, NULL, &g_triPipeline);

    pfn_vkDestroyShaderModule(g_device, fsm, NULL);
    pfn_vkDestroyShaderModule(g_device, vsm, NULL);

    return pres == VK_SUCCESS;
}

static bool ensure_quad_pipeline(void) {
    if (g_quadPipeline != VK_NULL_HANDLE) return true;
    if (!g_hasDynamicRender) return false;

    DEVFN(vkCreateShaderModule);
    DEVFN(vkDestroyShaderModule);
    DEVFN(vkCreatePipelineLayout);
    DEVFN(vkCreateGraphicsPipelines);

    VkShaderModuleCreateInfo vsmCi = {0};
    vsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    vsmCi.codeSize = quad_vert_spv_len;
    vsmCi.pCode = (const uint32_t *)quad_vert_spv;
    VkShaderModule vsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &vsmCi, NULL, &vsm) != VK_SUCCESS) return false;

    VkShaderModuleCreateInfo fsmCi = {0};
    fsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    fsmCi.codeSize = quad_frag_spv_len;
    fsmCi.pCode = (const uint32_t *)quad_frag_spv;
    VkShaderModule fsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &fsmCi, NULL, &fsm) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPushConstantRange pcRange = {0};
    pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcRange.offset = 0;
    pcRange.size = sizeof(float) * 8; // vec4 rect + vec4 color

    VkPipelineLayoutCreateInfo plCi = {0};
    plCi.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCi.pushConstantRangeCount = 1;
    plCi.pPushConstantRanges = &pcRange;
    if (pfn_vkCreatePipelineLayout(g_device, &plCi, NULL, &g_quadPipelineLayout) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, fsm, NULL);
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vsm; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fsm; stages[1].pName = "main";

    VkPipelineVertexInputStateCreateInfo vi = {0};
    vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    VkPipelineInputAssemblyStateCreateInfo ia = {0};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkPipelineViewportStateCreateInfo vp = {0};
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1; vp.scissorCount = 1;

    VkPipelineRasterizationStateCreateInfo rs = {0};
    rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms = {0};
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    // Alpha blend so subsequent quads can layer; xash often draws translucent overlays.
    VkPipelineColorBlendAttachmentState blendAtt = {0};
    blendAtt.blendEnable = VK_TRUE;
    blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blendAtt.colorBlendOp = VK_BLEND_OP_ADD;
    blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAtt.alphaBlendOp = VK_BLEND_OP_ADD;
    blendAtt.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1; cb.pAttachments = &blendAtt;

    VkDynamicState dynStates[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = {0};
    dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn.dynamicStateCount = 2; dyn.pDynamicStates = dynStates;

    VkFormat colorFmt = VK_FORMAT_R16G16B16A16_SFLOAT;
    VkPipelineRenderingCreateInfoKHR prCi = {0};
    prCi.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    prCi.colorAttachmentCount = 1;
    prCi.pColorAttachmentFormats = &colorFmt;
    prCi.depthAttachmentFormat = VK_FORMAT_D32_SFLOAT;

    VkGraphicsPipelineCreateInfo gpCi = {0};
    gpCi.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gpCi.pNext = &prCi;
    gpCi.stageCount = 2; gpCi.pStages = stages;
    gpCi.pVertexInputState = &vi;
    gpCi.pInputAssemblyState = &ia;
    gpCi.pViewportState = &vp;
    gpCi.pRasterizationState = &rs;
    gpCi.pMultisampleState = &ms;
    gpCi.pColorBlendState = &cb;
    gpCi.pDynamicState = &dyn;
    VkPipelineDepthStencilStateCreateInfo dsOff = {0};
    dsOff.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    gpCi.pDepthStencilState = &dsOff;
    gpCi.layout = g_quadPipelineLayout;

    VkResult pres = pfn_vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpCi, NULL, &g_quadPipeline);
    pfn_vkDestroyShaderModule(g_device, fsm, NULL);
    pfn_vkDestroyShaderModule(g_device, vsm, NULL);
    return pres == VK_SUCCESS;
}

static bool ensure_tex_pipeline(void) {
    if (g_texQuadPipeline != VK_NULL_HANDLE) return true;
    if (!g_hasDynamicRender) return false;

    DEVFN(vkCreateSampler);
    DEVFN(vkCreateDescriptorSetLayout);
    DEVFN(vkCreateDescriptorPool);
    DEVFN(vkCreateShaderModule);
    DEVFN(vkDestroyShaderModule);
    DEVFN(vkCreatePipelineLayout);
    DEVFN(vkCreateGraphicsPipelines);

    VkSamplerCreateInfo sci = {0};
    sci.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sci.magFilter = VK_FILTER_LINEAR;
    sci.minFilter = VK_FILTER_LINEAR;
    sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sci.maxLod = 1.0f;
    if (pfn_vkCreateSampler(g_device, &sci, NULL, &g_texSampler) != VK_SUCCESS) return false;

    VkDescriptorSetLayoutBinding b = {0};
    b.binding = 0;
    b.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    b.descriptorCount = 1;
    b.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo dslCi = {0};
    dslCi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    dslCi.bindingCount = 1;
    dslCi.pBindings = &b;
    if (pfn_vkCreateDescriptorSetLayout(g_device, &dslCi, NULL, &g_texDSL) != VK_SUCCESS) return false;

    VkDescriptorPoolSize ps = {0};
    ps.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    ps.descriptorCount = TEX_POOL_MAX;
    VkDescriptorPoolCreateInfo dpCi = {0};
    dpCi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    dpCi.maxSets = TEX_POOL_MAX;
    dpCi.poolSizeCount = 1;
    dpCi.pPoolSizes = &ps;
    dpCi.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    if (pfn_vkCreateDescriptorPool(g_device, &dpCi, NULL, &g_texDescPool) != VK_SUCCESS) return false;

    VkShaderModuleCreateInfo vsmCi = {0};
    vsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    vsmCi.codeSize = quad_tex_vert_spv_len;
    vsmCi.pCode = (const uint32_t *)quad_tex_vert_spv;
    VkShaderModule vsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &vsmCi, NULL, &vsm) != VK_SUCCESS) return false;

    VkShaderModuleCreateInfo fsmCi = {0};
    fsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    fsmCi.codeSize = quad_tex_frag_spv_len;
    fsmCi.pCode = (const uint32_t *)quad_tex_frag_spv;
    VkShaderModule fsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &fsmCi, NULL, &fsm) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPushConstantRange pcRange = {0};
    pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcRange.offset = 0;
    pcRange.size = sizeof(float) * 12; // rect + uv + tint
    VkPipelineLayoutCreateInfo plCi = {0};
    plCi.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCi.setLayoutCount = 1;
    plCi.pSetLayouts = &g_texDSL;
    plCi.pushConstantRangeCount = 1;
    plCi.pPushConstantRanges = &pcRange;
    if (pfn_vkCreatePipelineLayout(g_device, &plCi, NULL, &g_texQuadPipelineLayout) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, fsm, NULL);
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vsm; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fsm; stages[1].pName = "main";

    VkPipelineVertexInputStateCreateInfo vi = {0};
    vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    VkPipelineInputAssemblyStateCreateInfo ia = {0};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vp = {0};
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1; vp.scissorCount = 1;
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
    blendAtt.blendEnable = VK_TRUE;
    blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blendAtt.colorBlendOp = VK_BLEND_OP_ADD;
    blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAtt.alphaBlendOp = VK_BLEND_OP_ADD;
    blendAtt.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1; cb.pAttachments = &blendAtt;
    VkDynamicState dynStates[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = {0};
    dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn.dynamicStateCount = 2; dyn.pDynamicStates = dynStates;

    VkFormat colorFmt = VK_FORMAT_R16G16B16A16_SFLOAT;
    VkPipelineRenderingCreateInfoKHR prCi = {0};
    prCi.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    prCi.colorAttachmentCount = 1;
    prCi.pColorAttachmentFormats = &colorFmt;
    prCi.depthAttachmentFormat = VK_FORMAT_D32_SFLOAT;

    VkGraphicsPipelineCreateInfo gpCi = {0};
    gpCi.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gpCi.pNext = &prCi;
    gpCi.stageCount = 2; gpCi.pStages = stages;
    gpCi.pVertexInputState = &vi;
    gpCi.pInputAssemblyState = &ia;
    gpCi.pViewportState = &vp;
    gpCi.pRasterizationState = &rs;
    gpCi.pMultisampleState = &ms;
    gpCi.pColorBlendState = &cb;
    gpCi.pDynamicState = &dyn;
    VkPipelineDepthStencilStateCreateInfo dsOff = {0};
    dsOff.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    gpCi.pDepthStencilState = &dsOff;
    gpCi.layout = g_texQuadPipelineLayout;
    VkResult pres = pfn_vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpCi, NULL, &g_texQuadPipeline);
    pfn_vkDestroyShaderModule(g_device, fsm, NULL);
    pfn_vkDestroyShaderModule(g_device, vsm, NULL);
    return pres == VK_SUCCESS;
}

uint32_t lambda_bridge_create_texture(const void *rgba_bytes,
                                      int width, int height) {
    if (!g_device || !g_cmdPool || width <= 0 || height <= 0 || !rgba_bytes) return 0;
    if (!ensure_tex_pipeline()) return 0;

    // Find free slot (1-indexed handle; 0 reserved for "none").
    int idx = -1;
    for (int i = 0; i < TEX_POOL_MAX; ++i) {
        if (!g_textures[i].used) { idx = i; break; }
    }
    if (idx < 0) return 0;
    BridgeTexture *t = &g_textures[idx];

    DEVFN(vkCreateImage);
    DEVFN(vkDestroyImage);
    DEVFN(vkGetImageMemoryRequirements);
    DEVFN(vkAllocateMemory);
    DEVFN(vkFreeMemory);
    DEVFN(vkBindImageMemory);
    DEVFN(vkCreateBuffer);
    DEVFN(vkDestroyBuffer);
    DEVFN(vkGetBufferMemoryRequirements);
    DEVFN(vkBindBufferMemory);
    DEVFN(vkMapMemory);
    DEVFN(vkUnmapMemory);
    DEVFN(vkAllocateCommandBuffers);
    DEVFN(vkFreeCommandBuffers);
    DEVFN(vkBeginCommandBuffer);
    DEVFN(vkEndCommandBuffer);
    DEVFN(vkCmdPipelineBarrier);
    DEVFN(vkCmdCopyBufferToImage);
    DEVFN(vkQueueSubmit);
    DEVFN(vkQueueWaitIdle);
    DEVFN(vkCreateImageView);
    DEVFN(vkDestroyImageView);
    DEVFN(vkAllocateDescriptorSets);
    DEVFN(vkUpdateDescriptorSets);

    size_t bytes = (size_t)width * (size_t)height * 4;

    // Staging buffer
    VkBufferCreateInfo bci = {0};
    bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = bytes;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer staging = VK_NULL_HANDLE;
    if (pfn_vkCreateBuffer(g_device, &bci, NULL, &staging) != VK_SUCCESS) return 0;

    VkMemoryRequirements bufReq;
    pfn_vkGetBufferMemoryRequirements(g_device, staging, &bufReq);
    uint32_t bufMemType = find_memory_type(bufReq.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (bufMemType == UINT32_MAX) bufMemType = 0;
    VkMemoryAllocateInfo bufMai = {0};
    bufMai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bufMai.allocationSize = bufReq.size;
    bufMai.memoryTypeIndex = bufMemType;
    VkDeviceMemory bufMem = VK_NULL_HANDLE;
    if (pfn_vkAllocateMemory(g_device, &bufMai, NULL, &bufMem) != VK_SUCCESS) {
        pfn_vkDestroyBuffer(g_device, staging, NULL);
        return 0;
    }
    pfn_vkBindBufferMemory(g_device, staging, bufMem, 0);

    void *mapped = NULL;
    if (pfn_vkMapMemory(g_device, bufMem, 0, bytes, 0, &mapped) != VK_SUCCESS) goto fail_staging;
    memcpy(mapped, rgba_bytes, bytes);
    pfn_vkUnmapMemory(g_device, bufMem);

    // Image (device-local, RGBA8_UNORM, tiling OPTIMAL)
    VkImageCreateInfo ici = {0};
    ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = VK_FORMAT_R8G8B8A8_UNORM;
    ici.extent.width = (uint32_t)width;
    ici.extent.height = (uint32_t)height;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage image = VK_NULL_HANDLE;
    if (pfn_vkCreateImage(g_device, &ici, NULL, &image) != VK_SUCCESS) goto fail_staging;

    VkMemoryRequirements imgReq;
    pfn_vkGetImageMemoryRequirements(g_device, image, &imgReq);
    uint32_t imgMemType = find_memory_type(imgReq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (imgMemType == UINT32_MAX) imgMemType = 0;
    VkMemoryAllocateInfo imgMai = {0};
    imgMai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    imgMai.allocationSize = imgReq.size;
    imgMai.memoryTypeIndex = imgMemType;
    VkDeviceMemory imgMem = VK_NULL_HANDLE;
    if (pfn_vkAllocateMemory(g_device, &imgMai, NULL, &imgMem) != VK_SUCCESS) {
        pfn_vkDestroyImage(g_device, image, NULL);
        goto fail_staging;
    }
    pfn_vkBindImageMemory(g_device, image, imgMem, 0);

    // One-shot cmd buffer: UNDEFINED → TRANSFER_DST, copy, TRANSFER_DST → SHADER_READ_ONLY.
    VkCommandBufferAllocateInfo cbai = {0};
    cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = g_cmdPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    pfn_vkAllocateCommandBuffers(g_device, &cbai, &cb);
    VkCommandBufferBeginInfo bbi = {0};
    bbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    pfn_vkBeginCommandBuffer(cb, &bbi);

    VkImageSubresourceRange range = {0};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1; range.layerCount = 1;

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

    VkBufferImageCopy copy = {0};
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = (uint32_t)width;
    copy.imageExtent.height = (uint32_t)height;
    copy.imageExtent.depth = 1;
    pfn_vkCmdCopyBufferToImage(cb, staging, image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);

    VkImageMemoryBarrier toShader = toDst;
    toShader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toShader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    toShader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toShader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    pfn_vkCmdPipelineBarrier(cb,
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0, 0, NULL, 0, NULL, 1, &toShader);

    pfn_vkEndCommandBuffer(cb);

    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    pfn_vkQueueSubmit(g_gfxQueue, 1, &si, VK_NULL_HANDLE);
    pfn_vkQueueWaitIdle(g_gfxQueue);

    pfn_vkFreeCommandBuffers(g_device, g_cmdPool, 1, &cb);
    pfn_vkDestroyBuffer(g_device, staging, NULL);
    pfn_vkFreeMemory(g_device, bufMem, NULL);

    VkImageViewCreateInfo ivci = {0};
    ivci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ivci.image = image;
    ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    ivci.format = VK_FORMAT_R8G8B8A8_UNORM;
    ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    ivci.subresourceRange.levelCount = 1;
    ivci.subresourceRange.layerCount = 1;
    VkImageView view = VK_NULL_HANDLE;
    pfn_vkCreateImageView(g_device, &ivci, NULL, &view);

    VkDescriptorSetAllocateInfo dsAi = {0};
    dsAi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    dsAi.descriptorPool = g_texDescPool;
    dsAi.descriptorSetCount = 1;
    dsAi.pSetLayouts = &g_texDSL;
    VkDescriptorSet ds = VK_NULL_HANDLE;
    pfn_vkAllocateDescriptorSets(g_device, &dsAi, &ds);

    VkDescriptorImageInfo di = {0};
    di.sampler = g_texSampler;
    di.imageView = view;
    di.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkWriteDescriptorSet w = {0};
    w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    w.dstSet = ds;
    w.dstBinding = 0;
    w.descriptorCount = 1;
    w.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    w.pImageInfo = &di;
    pfn_vkUpdateDescriptorSets(g_device, 1, &w, 0, NULL);

    t->used = true;
    t->image = image;
    t->view = view;
    t->memory = imgMem;
    t->descSet = ds;
    t->width = width;
    t->height = height;
    return (uint32_t)(idx + 1);

fail_staging:
    pfn_vkDestroyBuffer(g_device, staging, NULL);
    pfn_vkFreeMemory(g_device, bufMem, NULL);
    return 0;
}

void lambda_bridge_destroy_texture(uint32_t handle) {
    if (handle == 0 || handle > TEX_POOL_MAX) return;
    BridgeTexture *t = &g_textures[handle - 1];
    if (!t->used) return;

    DEVFN(vkDestroyImageView);
    DEVFN(vkDestroyImage);
    DEVFN(vkFreeMemory);
    DEVFN(vkFreeDescriptorSets);
    if (t->descSet && g_texDescPool) pfn_vkFreeDescriptorSets(g_device, g_texDescPool, 1, &t->descSet);
    if (t->view) pfn_vkDestroyImageView(g_device, t->view, NULL);
    if (t->image) pfn_vkDestroyImage(g_device, t->image, NULL);
    if (t->memory) pfn_vkFreeMemory(g_device, t->memory, NULL);
    memset(t, 0, sizeof(*t));
}

void lambda_bridge_record_draw_stretch_pic(float x, float y, float w, float h,
                                           float s1, float t1, float s2, float t2,
                                           uint8_t r, uint8_t g, uint8_t b, uint8_t a,
                                           uint32_t texture_handle) {
    if (g_active_slot < 0) return;
    if (texture_handle == 0 || texture_handle > TEX_POOL_MAX) return;
    BridgeTexture *t = &g_textures[texture_handle - 1];
    if (!t->used || !t->descSet) return;
    if (!ensure_tex_pipeline()) return;

    EyeSlot *e = &g_pool[g_active_slot][g_active_eye];
    float sw = (float)e->width, sh = (float)e->height;
    float x0 = (x / sw) * 2.0f - 1.0f;
    float y0 = (y / sh) * 2.0f - 1.0f;
    float x1 = ((x + w) / sw) * 2.0f - 1.0f;
    float y1 = ((y + h) / sh) * 2.0f - 1.0f;

    float pc[12] = { x0, y0, x1, y1,
                     s1, t1, s2, t2,
                     r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f };

    DEVFN(vkCmdBindPipeline);
    DEVFN(vkCmdBindDescriptorSets);
    DEVFN(vkCmdPushConstants);
    DEVFN(vkCmdDraw);

    pfn_vkCmdBindPipeline(g_active_cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_texQuadPipeline);
    pfn_vkCmdBindDescriptorSets(g_active_cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
        g_texQuadPipelineLayout, 0, 1, &t->descSet, 0, NULL);
    pfn_vkCmdPushConstants(g_active_cmd, g_texQuadPipelineLayout,
        VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(pc), pc);
    pfn_vkCmdDraw(g_active_cmd, 6, 1, 0, 0);
}

// === Stage D1: world-space line pipeline + debug axes ====================

static bool ensure_axes_buffer(void) {
    if (g_axesVB) return true;
    DEVFN(vkCreateBuffer);
    DEVFN(vkDestroyBuffer);
    DEVFN(vkGetBufferMemoryRequirements);
    DEVFN(vkAllocateMemory);
    DEVFN(vkBindBufferMemory);
    DEVFN(vkMapMemory);
    DEVFN(vkUnmapMemory);

    // 6 verts (3 line segments). Each vert: 3 floats pos + 4 floats color.
    // HL world coords: X forward, Y left, Z up. Use a very long length so
    // the axes cross close to the player no matter where they spawn; we
    // care about visibility, not realism.
    const float L = 4096.0f;
    const float verts[6 * 7] = {
        // X axis (red)
        0,0,0,  1,0,0,1,   L,0,0,  1,0,0,1,
        // Y axis (green)
        0,0,0,  0,1,0,1,   0,L,0,  0,1,0,1,
        // Z axis (blue)
        0,0,0,  0,0,1,1,   0,0,L,  0,0,1,1,
    };

    VkBufferCreateInfo bci = {0};
    bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = sizeof(verts);
    bci.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (pfn_vkCreateBuffer(g_device, &bci, NULL, &g_axesVB) != VK_SUCCESS) return false;

    VkMemoryRequirements req;
    pfn_vkGetBufferMemoryRequirements(g_device, g_axesVB, &req);
    uint32_t mt = find_memory_type(req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt == UINT32_MAX) mt = 0;
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = mt;
    if (pfn_vkAllocateMemory(g_device, &mai, NULL, &g_axesVBMem) != VK_SUCCESS) {
        pfn_vkDestroyBuffer(g_device, g_axesVB, NULL);
        g_axesVB = VK_NULL_HANDLE;
        return false;
    }
    pfn_vkBindBufferMemory(g_device, g_axesVB, g_axesVBMem, 0);
    void *mapped = NULL;
    pfn_vkMapMemory(g_device, g_axesVBMem, 0, sizeof(verts), 0, &mapped);
    memcpy(mapped, verts, sizeof(verts));
    pfn_vkUnmapMemory(g_device, g_axesVBMem);
    return true;
}

static bool ensure_axes_pipeline(void) {
    if (g_axesPipeline) return true;
    if (!g_hasDynamicRender) return false;
    if (!ensure_axes_buffer()) return false;

    DEVFN(vkCreateShaderModule);
    DEVFN(vkDestroyShaderModule);
    DEVFN(vkCreatePipelineLayout);
    DEVFN(vkCreateGraphicsPipelines);

    VkShaderModuleCreateInfo vsmCi = {0};
    vsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    vsmCi.codeSize = axes_vert_spv_len;
    vsmCi.pCode = (const uint32_t *)axes_vert_spv;
    VkShaderModule vsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &vsmCi, NULL, &vsm) != VK_SUCCESS) return false;
    VkShaderModuleCreateInfo fsmCi = {0};
    fsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    fsmCi.codeSize = axes_frag_spv_len;
    fsmCi.pCode = (const uint32_t *)axes_frag_spv;
    VkShaderModule fsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &fsmCi, NULL, &fsm) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPushConstantRange pcRange = {0};
    pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcRange.offset = 0;
    pcRange.size = sizeof(float) * 16; // mat4 mvp
    VkPipelineLayoutCreateInfo plCi = {0};
    plCi.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCi.pushConstantRangeCount = 1;
    plCi.pPushConstantRanges = &pcRange;
    if (pfn_vkCreatePipelineLayout(g_device, &plCi, NULL, &g_axesPipelineLayout) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, fsm, NULL);
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vsm; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fsm; stages[1].pName = "main";

    VkVertexInputBindingDescription vbind = {0};
    vbind.binding = 0;
    vbind.stride = sizeof(float) * 7;
    vbind.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
    VkVertexInputAttributeDescription vattrs[2] = {0};
    vattrs[0].location = 0; vattrs[0].format = VK_FORMAT_R32G32B32_SFLOAT;     vattrs[0].offset = 0;
    vattrs[1].location = 1; vattrs[1].format = VK_FORMAT_R32G32B32A32_SFLOAT;  vattrs[1].offset = sizeof(float) * 3;
    VkPipelineVertexInputStateCreateInfo vi = {0};
    vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vi.vertexBindingDescriptionCount = 1;
    vi.pVertexBindingDescriptions = &vbind;
    vi.vertexAttributeDescriptionCount = 2;
    vi.pVertexAttributeDescriptions = vattrs;

    VkPipelineInputAssemblyStateCreateInfo ia = {0};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST;

    VkPipelineViewportStateCreateInfo vp = {0};
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1; vp.scissorCount = 1;

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
    cb.attachmentCount = 1; cb.pAttachments = &blendAtt;

    VkDynamicState dynStates[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = {0};
    dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn.dynamicStateCount = 2; dyn.pDynamicStates = dynStates;

    VkPipelineDepthStencilStateCreateInfo ds = {0};
    ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_TRUE;
    ds.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;

    VkFormat colorFmt = VK_FORMAT_R16G16B16A16_SFLOAT;
    VkPipelineRenderingCreateInfoKHR prCi = {0};
    prCi.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    prCi.colorAttachmentCount = 1;
    prCi.pColorAttachmentFormats = &colorFmt;
    prCi.depthAttachmentFormat = VK_FORMAT_D32_SFLOAT;

    VkGraphicsPipelineCreateInfo gpCi = {0};
    gpCi.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gpCi.pNext = &prCi;
    gpCi.stageCount = 2; gpCi.pStages = stages;
    gpCi.pVertexInputState = &vi;
    gpCi.pInputAssemblyState = &ia;
    gpCi.pViewportState = &vp;
    gpCi.pRasterizationState = &rs;
    gpCi.pMultisampleState = &ms;
    gpCi.pColorBlendState = &cb;
    gpCi.pDynamicState = &dyn;
    gpCi.pDepthStencilState = &ds;
    gpCi.layout = g_axesPipelineLayout;
    VkResult pres = pfn_vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpCi, NULL, &g_axesPipeline);
    pfn_vkDestroyShaderModule(g_device, fsm, NULL);
    pfn_vkDestroyShaderModule(g_device, vsm, NULL);
    return pres == VK_SUCCESS;
}

void lambda_bridge_record_debug_axes(const float mvp[16]) {
    if (g_active_slot < 0) return;
    if (!ensure_axes_pipeline()) return;

    DEVFN(vkCmdBindPipeline);
    DEVFN(vkCmdBindVertexBuffers);
    DEVFN(vkCmdPushConstants);
    DEVFN(vkCmdDraw);

    pfn_vkCmdBindPipeline(g_active_cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_axesPipeline);
    VkDeviceSize zero = 0;
    pfn_vkCmdBindVertexBuffers(g_active_cmd, 0, 1, &g_axesVB, &zero);
    pfn_vkCmdPushConstants(g_active_cmd, g_axesPipelineLayout,
        VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(float) * 16, mvp);
    pfn_vkCmdDraw(g_active_cmd, 6, 1, 0, 0);
}

// === Stage D2: textured world pipeline + uploaded geometry ================

static bool ensure_world_pipeline(void) {
    if (g_worldPipeline) return true;
    if (!g_hasDynamicRender) return false;
    // Reuses g_texDSL + g_texSampler + g_texDescPool from the 2D textured
    // path, so make sure those exist.
    if (!ensure_tex_pipeline()) return false;

    DEVFN(vkCreateShaderModule);
    DEVFN(vkDestroyShaderModule);
    DEVFN(vkCreatePipelineLayout);
    DEVFN(vkCreateGraphicsPipelines);

    VkShaderModuleCreateInfo vsmCi = {0};
    vsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    vsmCi.codeSize = world_vert_spv_len;
    vsmCi.pCode = (const uint32_t *)world_vert_spv;
    VkShaderModule vsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &vsmCi, NULL, &vsm) != VK_SUCCESS) return false;
    VkShaderModuleCreateInfo fsmCi = {0};
    fsmCi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    fsmCi.codeSize = world_frag_spv_len;
    fsmCi.pCode = (const uint32_t *)world_frag_spv;
    VkShaderModule fsm = VK_NULL_HANDLE;
    if (pfn_vkCreateShaderModule(g_device, &fsmCi, NULL, &fsm) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPushConstantRange pcRange = {0};
    pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcRange.offset = 0;
    pcRange.size = sizeof(float) * 16;
    VkPipelineLayoutCreateInfo plCi = {0};
    plCi.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plCi.setLayoutCount = 1;
    plCi.pSetLayouts = &g_texDSL;
    plCi.pushConstantRangeCount = 1;
    plCi.pPushConstantRanges = &pcRange;
    if (pfn_vkCreatePipelineLayout(g_device, &plCi, NULL, &g_worldPipelineLayout) != VK_SUCCESS) {
        pfn_vkDestroyShaderModule(g_device, fsm, NULL);
        pfn_vkDestroyShaderModule(g_device, vsm, NULL);
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vsm; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fsm; stages[1].pName = "main";

    VkVertexInputBindingDescription vbind = {0};
    vbind.binding = 0; vbind.stride = sizeof(float) * 5;
    vbind.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
    VkVertexInputAttributeDescription vattrs[2] = {0};
    vattrs[0].location = 0; vattrs[0].format = VK_FORMAT_R32G32B32_SFLOAT; vattrs[0].offset = 0;
    vattrs[1].location = 1; vattrs[1].format = VK_FORMAT_R32G32_SFLOAT;    vattrs[1].offset = sizeof(float) * 3;
    VkPipelineVertexInputStateCreateInfo vi = {0};
    vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vi.vertexBindingDescriptionCount = 1;
    vi.pVertexBindingDescriptions = &vbind;
    vi.vertexAttributeDescriptionCount = 2;
    vi.pVertexAttributeDescriptions = vattrs;

    VkPipelineInputAssemblyStateCreateInfo ia = {0};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vp = {0};
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1; vp.scissorCount = 1;
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
    cb.attachmentCount = 1; cb.pAttachments = &blendAtt;
    VkDynamicState dynStates[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = {0};
    dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn.dynamicStateCount = 2; dyn.pDynamicStates = dynStates;
    VkPipelineDepthStencilStateCreateInfo ds = {0};
    ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_TRUE;
    ds.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;

    VkFormat colorFmt = VK_FORMAT_R16G16B16A16_SFLOAT;
    VkPipelineRenderingCreateInfoKHR prCi = {0};
    prCi.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    prCi.colorAttachmentCount = 1;
    prCi.pColorAttachmentFormats = &colorFmt;
    prCi.depthAttachmentFormat = VK_FORMAT_D32_SFLOAT;

    VkGraphicsPipelineCreateInfo gpCi = {0};
    gpCi.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gpCi.pNext = &prCi;
    gpCi.stageCount = 2; gpCi.pStages = stages;
    gpCi.pVertexInputState = &vi;
    gpCi.pInputAssemblyState = &ia;
    gpCi.pViewportState = &vp;
    gpCi.pRasterizationState = &rs;
    gpCi.pMultisampleState = &ms;
    gpCi.pColorBlendState = &cb;
    gpCi.pDynamicState = &dyn;
    gpCi.pDepthStencilState = &ds;
    gpCi.layout = g_worldPipelineLayout;

    VkResult pres = pfn_vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpCi, NULL, &g_worldPipeline);
    pfn_vkDestroyShaderModule(g_device, fsm, NULL);
    pfn_vkDestroyShaderModule(g_device, vsm, NULL);
    if (pres != VK_SUCCESS) return false;

    // 1x1 white fallback texture for surfaces whose texture didn't resolve.
    if (!g_worldWhiteTex) {
        uint8_t px[4] = { 255, 255, 255, 255 };
        g_worldWhiteTex = lambda_bridge_create_texture(px, 1, 1);
    }
    return true;
}

void lambda_bridge_world_clear(void) {
    if (!g_device) return;
    DEVFN(vkDestroyBuffer);
    DEVFN(vkFreeMemory);
    if (g_worldVB) pfn_vkDestroyBuffer(g_device, g_worldVB, NULL);
    if (g_worldVBMem) pfn_vkFreeMemory(g_device, g_worldVBMem, NULL);
    g_worldVB = VK_NULL_HANDLE; g_worldVBMem = VK_NULL_HANDLE;
    g_worldVertexCount = 0;
    free(g_worldBatches);
    g_worldBatches = NULL;
    g_worldBatchCount = 0;
}

void lambda_bridge_world_upload(const float *verts_pos_uv,
                                int vertex_count,
                                const lambda_bridge_world_batch *batches,
                                int batch_count) {
    if (!g_device) return;
    if (vertex_count <= 0 || batch_count <= 0 || !verts_pos_uv || !batches) return;
    if (!ensure_world_pipeline()) return;

    lambda_bridge_world_clear();

    size_t bytes = (size_t)vertex_count * 5 * sizeof(float);
    DEVFN(vkCreateBuffer);
    DEVFN(vkDestroyBuffer);
    DEVFN(vkGetBufferMemoryRequirements);
    DEVFN(vkAllocateMemory);
    DEVFN(vkFreeMemory);
    DEVFN(vkBindBufferMemory);
    DEVFN(vkMapMemory);
    DEVFN(vkUnmapMemory);

    VkBufferCreateInfo bci = {0};
    bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = bytes;
    bci.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (pfn_vkCreateBuffer(g_device, &bci, NULL, &g_worldVB) != VK_SUCCESS) return;
    VkMemoryRequirements req;
    pfn_vkGetBufferMemoryRequirements(g_device, g_worldVB, &req);
    uint32_t mt = find_memory_type(req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt == UINT32_MAX) mt = 0;
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = mt;
    if (pfn_vkAllocateMemory(g_device, &mai, NULL, &g_worldVBMem) != VK_SUCCESS) {
        pfn_vkDestroyBuffer(g_device, g_worldVB, NULL);
        g_worldVB = VK_NULL_HANDLE;
        return;
    }
    pfn_vkBindBufferMemory(g_device, g_worldVB, g_worldVBMem, 0);
    void *mapped = NULL;
    pfn_vkMapMemory(g_device, g_worldVBMem, 0, bytes, 0, &mapped);
    memcpy(mapped, verts_pos_uv, bytes);
    pfn_vkUnmapMemory(g_device, g_worldVBMem);

    g_worldVertexCount = vertex_count;
    g_worldBatches = (lambda_bridge_world_batch *)malloc(sizeof(*batches) * batch_count);
    if (g_worldBatches) {
        memcpy(g_worldBatches, batches, sizeof(*batches) * batch_count);
        g_worldBatchCount = batch_count;
    }
}

void lambda_bridge_record_world_range(const float mvp[16],
                                      int first_batch, int batch_count) {
    if (g_active_slot < 0) return;
    if (!g_worldVB || !g_worldBatches || g_worldBatchCount == 0) return;
    if (!ensure_world_pipeline()) return;
    if (first_batch < 0 || batch_count <= 0) return;
    if (first_batch + batch_count > g_worldBatchCount)
        batch_count = g_worldBatchCount - first_batch;

    DEVFN(vkCmdBindPipeline);
    DEVFN(vkCmdBindVertexBuffers);
    DEVFN(vkCmdBindDescriptorSets);
    DEVFN(vkCmdPushConstants);
    DEVFN(vkCmdDraw);

    pfn_vkCmdBindPipeline(g_active_cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_worldPipeline);
    VkDeviceSize zero = 0;
    pfn_vkCmdBindVertexBuffers(g_active_cmd, 0, 1, &g_worldVB, &zero);
    pfn_vkCmdPushConstants(g_active_cmd, g_worldPipelineLayout,
        VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(float) * 16, mvp);

    VkDescriptorSet lastDS = VK_NULL_HANDLE;
    int end = first_batch + batch_count;
    for (int i = first_batch; i < end; ++i) {
        lambda_bridge_world_batch *b = &g_worldBatches[i];
        if (b->vertex_count == 0) continue;
        uint32_t h = b->texture_handle;
        if (h == 0 || h > TEX_POOL_MAX || !g_textures[h - 1].used) h = g_worldWhiteTex;
        if (h == 0) continue;
        VkDescriptorSet ds = g_textures[h - 1].descSet;
        if (ds != lastDS) {
            pfn_vkCmdBindDescriptorSets(g_active_cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                g_worldPipelineLayout, 0, 1, &ds, 0, NULL);
            lastDS = ds;
        }
        pfn_vkCmdDraw(g_active_cmd, b->vertex_count, 1, b->first_vertex, 0);
    }
}

void lambda_bridge_record_world(const float mvp[16]) {
    lambda_bridge_record_world_range(mvp, 0, g_worldBatchCount);
}

void lambda_bridge_record_fill_rgba(float x, float y, float w, float h,
                                    uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    if (g_active_slot < 0) return;
    if (!ensure_quad_pipeline()) return;

    EyeSlot *e = &g_pool[g_active_slot][g_active_eye];
    float sw = (float)e->width, sh = (float)e->height;
    // Pixel -> NDC. Xash 2D origin is top-left, +y down. NDC y is +down in
    // Vulkan with default viewport, so we DON'T flip y here.
    float x0 = (x / sw) * 2.0f - 1.0f;
    float y0 = (y / sh) * 2.0f - 1.0f;
    float x1 = ((x + w) / sw) * 2.0f - 1.0f;
    float y1 = ((y + h) / sh) * 2.0f - 1.0f;

    float pc[8] = { x0, y0, x1, y1,
                    r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f };

    DEVFN(vkCmdBindPipeline);
    DEVFN(vkCmdPushConstants);
    DEVFN(vkCmdDraw);

    pfn_vkCmdBindPipeline(g_active_cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_quadPipeline);
    pfn_vkCmdPushConstants(g_active_cmd, g_quadPipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(pc), pc);
    pfn_vkCmdDraw(g_active_cmd, 6, 1, 0, 0);
}

// Legacy entry retained only for Renderer.swift's makeVulkanColorMap, which
// needs an IOSurface handle bound into the demo cube/panel before the engine
// runs its first frame. Stage C1 split rendering into begin_frame/end_frame;
// this fn now just primes the slot and hands back the IOSurface. (r,g,b,time)
// arguments are ignored.
const void *lambda_vulkan_render_eye_pooled(int slot, int eye,
                                            int width, int height,
                                            float r, float g, float b,
                                            float time) {
    (void)r; (void)g; (void)b; (void)time;
    if (!g_device || !g_cmdPool || !g_hasMetalObjects) return NULL;
    if (!g_hasDynamicRender) return NULL;
    if (slot < 0 || slot >= POOL_SLOTS || eye < 0 || eye >= POOL_EYES) return NULL;

    EyeSlot *e = &g_pool[slot][eye];
    if (e->surface && (e->width != width || e->height != height)) {
        destroy_eye_slot(e);
    }
    if (!e->surface) {
        if (!alloc_eye_slot(e, width, height)) return NULL;
    }
    return (const void *)e->surface;
}

// Old body retained below temporarily for diff clarity; unreachable.
#if 0

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
#endif

// =====================================================================
// Stage C1: engine-driven recording. begin_frame/end_frame bracket a
// dynamic-rendering pass into pool[slot][eye]; the engine's renderer
// records draws via future bridge fns between these two. Until those
// fns exist, the frame is just a clear.
// =====================================================================

int lambda_bridge_begin_frame(int slot, int eye, int width, int height,
                              float r, float g, float b) {
    if (!g_device || !g_cmdPool || !g_hasMetalObjects) return -1;
    if (!g_hasDynamicRender) return -2;
    if (slot < 0 || slot >= POOL_SLOTS || eye < 0 || eye >= POOL_EYES) return -3;
    if (g_active_slot != -1) return -5;    // frame already in progress

    EyeSlot *e = &g_pool[slot][eye];
    if (e->surface && (e->width != width || e->height != height)) {
        destroy_eye_slot(e);
    }
    if (!e->surface) {
        if (!alloc_eye_slot(e, width, height)) return -6;
    }

    DEVFN(vkBeginCommandBuffer);
    DEVFN(vkCmdPipelineBarrier);
    DEVFN(vkResetCommandBuffer);
    DEVFN(vkCmdSetViewport);
    DEVFN(vkCmdSetScissor);

    pfn_vkResetCommandBuffer(e->cmd, 0);

    VkCommandBufferBeginInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    pfn_vkBeginCommandBuffer(e->cmd, &bi);

    VkImageSubresourceRange range = {0};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    VkImageMemoryBarrier toAtt[2] = {0};
    toAtt[0].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toAtt[0].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    toAtt[0].newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    toAtt[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toAtt[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toAtt[0].image = e->image;
    toAtt[0].subresourceRange = range;
    toAtt[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    toAtt[1] = toAtt[0];
    toAtt[1].newLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    toAtt[1].image = e->depthImage;
    toAtt[1].dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    toAtt[1].subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    toAtt[1].subresourceRange.levelCount = 1;
    toAtt[1].subresourceRange.layerCount = 1;
    pfn_vkCmdPipelineBarrier(e->cmd,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        0, 0, NULL, 0, NULL, 2, toAtt);

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

    VkRenderingAttachmentInfoKHR depthAtt = {0};
    depthAtt.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR;
    depthAtt.imageView = e->depthView;
    depthAtt.imageLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    depthAtt.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    depthAtt.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    depthAtt.clearValue.depthStencil.depth = 1.0f;

    VkRenderingInfoKHR ri = {0};
    ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO_KHR;
    ri.renderArea.extent.width = (uint32_t)width;
    ri.renderArea.extent.height = (uint32_t)height;
    ri.layerCount = 1;
    ri.colorAttachmentCount = 1;
    ri.pColorAttachments = &colorAtt;
    ri.pDepthAttachment = &depthAtt;
    g_pfnCmdBeginRendering(e->cmd, &ri);

    VkViewport vpRect = {0};
    vpRect.width = (float)width; vpRect.height = (float)height;
    vpRect.maxDepth = 1.0f;
    pfn_vkCmdSetViewport(e->cmd, 0, 1, &vpRect);

    VkRect2D scissor = {0};
    scissor.extent.width = (uint32_t)width;
    scissor.extent.height = (uint32_t)height;
    pfn_vkCmdSetScissor(e->cmd, 0, 1, &scissor);

    g_active_slot = slot;
    g_active_eye  = eye;
    g_active_cmd  = e->cmd;
    return 0;
}

const void *lambda_bridge_end_frame(void) {
    if (g_active_slot < 0) return NULL;
    EyeSlot *e = &g_pool[g_active_slot][g_active_eye];
    VkCommandBuffer cb = g_active_cmd;

    DEVFN(vkCmdPipelineBarrier);
    DEVFN(vkEndCommandBuffer);
    DEVFN(vkQueueSubmit);
    DEVFN(vkQueueWaitIdle);

    g_pfnCmdEndRendering(cb);

    VkImageSubresourceRange range = {0};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    VkImageMemoryBarrier toGen = {0};
    toGen.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toGen.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    toGen.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    toGen.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toGen.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toGen.image = e->image;
    toGen.subresourceRange = range;
    toGen.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    toGen.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    pfn_vkCmdPipelineBarrier(cb,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0, 0, NULL, 0, NULL, 1, &toGen);

    pfn_vkEndCommandBuffer(cb);

    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    VkResult subRes = pfn_vkQueueSubmit(g_gfxQueue, 1, &si, VK_NULL_HANDLE);
    VkResult waitRes = (subRes == VK_SUCCESS) ? pfn_vkQueueWaitIdle(g_gfxQueue) : subRes;

    IOSurfaceRef out = e->surface;
    g_active_slot = -1;
    g_active_eye  = -1;
    g_active_cmd  = VK_NULL_HANDLE;

    if (subRes != VK_SUCCESS || waitRes != VK_SUCCESS) return NULL;
    return (const void *)out;
}

void lambda_vulkan_release_pool(void) {
    if (!g_device) return;
    for (int s = 0; s < POOL_SLOTS; ++s) {
        for (int e = 0; e < POOL_EYES; ++e) {
            destroy_eye_slot(&g_pool[s][e]);
        }
    }
    for (int i = 0; i < TEX_POOL_MAX; ++i) {
        if (g_textures[i].used) lambda_bridge_destroy_texture((uint32_t)(i + 1));
    }
    lambda_bridge_world_clear();
    if (g_worldPipeline || g_worldPipelineLayout) {
        DEVFN(vkDestroyPipeline);
        DEVFN(vkDestroyPipelineLayout);
        if (g_worldPipeline) pfn_vkDestroyPipeline(g_device, g_worldPipeline, NULL);
        if (g_worldPipelineLayout) pfn_vkDestroyPipelineLayout(g_device, g_worldPipelineLayout, NULL);
        g_worldPipeline = VK_NULL_HANDLE;
        g_worldPipelineLayout = VK_NULL_HANDLE;
    }
    if (g_axesVB || g_axesVBMem || g_axesPipeline) {
        DEVFN(vkDestroyBuffer);
        DEVFN(vkFreeMemory);
        DEVFN(vkDestroyPipeline);
        DEVFN(vkDestroyPipelineLayout);
        if (g_axesPipeline) pfn_vkDestroyPipeline(g_device, g_axesPipeline, NULL);
        if (g_axesPipelineLayout) pfn_vkDestroyPipelineLayout(g_device, g_axesPipelineLayout, NULL);
        if (g_axesVB) pfn_vkDestroyBuffer(g_device, g_axesVB, NULL);
        if (g_axesVBMem) pfn_vkFreeMemory(g_device, g_axesVBMem, NULL);
        g_axesPipeline = VK_NULL_HANDLE; g_axesPipelineLayout = VK_NULL_HANDLE;
        g_axesVB = VK_NULL_HANDLE; g_axesVBMem = VK_NULL_HANDLE;
    }
    if (g_triPipeline || g_quadPipeline || g_texQuadPipeline) {
        DEVFN(vkDestroyPipeline);
        DEVFN(vkDestroyPipelineLayout);
        DEVFN(vkDestroyDescriptorPool);
        DEVFN(vkDestroyDescriptorSetLayout);
        DEVFN(vkDestroySampler);
        if (g_triPipeline) pfn_vkDestroyPipeline(g_device, g_triPipeline, NULL);
        if (g_triPipelineLayout) pfn_vkDestroyPipelineLayout(g_device, g_triPipelineLayout, NULL);
        if (g_quadPipeline) pfn_vkDestroyPipeline(g_device, g_quadPipeline, NULL);
        if (g_quadPipelineLayout) pfn_vkDestroyPipelineLayout(g_device, g_quadPipelineLayout, NULL);
        if (g_texQuadPipeline) pfn_vkDestroyPipeline(g_device, g_texQuadPipeline, NULL);
        if (g_texQuadPipelineLayout) pfn_vkDestroyPipelineLayout(g_device, g_texQuadPipelineLayout, NULL);
        if (g_texDescPool) pfn_vkDestroyDescriptorPool(g_device, g_texDescPool, NULL);
        if (g_texDSL) pfn_vkDestroyDescriptorSetLayout(g_device, g_texDSL, NULL);
        if (g_texSampler) pfn_vkDestroySampler(g_device, g_texSampler, NULL);
        g_triPipeline = VK_NULL_HANDLE; g_triPipelineLayout = VK_NULL_HANDLE;
        g_quadPipeline = VK_NULL_HANDLE; g_quadPipelineLayout = VK_NULL_HANDLE;
        g_texQuadPipeline = VK_NULL_HANDLE; g_texQuadPipelineLayout = VK_NULL_HANDLE;
        g_texDescPool = VK_NULL_HANDLE; g_texDSL = VK_NULL_HANDLE;
        g_texSampler = VK_NULL_HANDLE;
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

// Engine reaches the renderer's GetRefAPI via dlsym(RTLD_DEFAULT) at
// runtime (xash's COM_LoadLibrary returns RTLD_DEFAULT on visionOS).
// Without a reference here, ld dead-strips the symbol from the final
// exec and the dlsym lookup returns NULL → "Can't initialize renderer".
extern int GetRefAPI( int version, void *funcs, void *engfuncs, void *globals );
__attribute__((used, visibility("default")))
static void *const _anchor_GetRefAPI = (void *)GetRefAPI;

// Engine render-target size, read by the engine's R_Init_Video
// (engine/platform/visionos/vid_visionos.c) when the renderer comes up.
// Must be set BEFORE lambda_engine_init; defaults keep the historical
// 2048x2048 if the app never calls the setter.
int lambda_vid_render_width  = 2048;
int lambda_vid_render_height = 2048;

// vid_visionos.c reads these into refState only at R_Init_Video (engine init).
// So a size change AFTER init (render-scale setting + immersive-space reopen,
// which reallocates the colorMap) leaves refState stale — the engine renders
// at the old dimensions/aspect into the new-size buffer, which looks like a
// warped FOV. Flag the change; the GL worker pushes it into refState live via
// R_ChangeDisplaySettings before the next tick.
// Plain flag (stdatomic.h isn't included until lower in this file). The apply
// reads the current size regardless, so a torn set/clear at worst applies the
// already-current size a frame early/late — benign.
static volatile int g_render_size_dirty;

void lambda_engine_set_render_size(int width, int height) {
    if (width > 0)  lambda_vid_render_width  = width;
    if (height > 0) lambda_vid_render_height = height;
    g_render_size_dirty = 1;
}

// GL worker, before the tick: sync refState to the current render size.
static void lambda_render_size_apply(void) {
    extern int  R_ChangeDisplaySettings(int width, int height, int window_mode);
    extern void SCR_VidInit(void);
    if (!g_engine_inited) return;                       // R_Init_Video handles first run
    if (!g_render_size_dirty) return;
    g_render_size_dirty = 0;
    R_ChangeDisplaySettings(lambda_vid_render_width, lambda_vid_render_height, 0);
    // Tell the client dll (HUD) about the new resolution so its text/sprite
    // scaling recomputes — otherwise HUD/credits keep the old scale factors
    // and render microscopic at low render scale (the console, drawn engine-
    // side from refState, was already correct).
    SCR_VidInit();
}

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
    // Keep the compass heading fixed while riding rotating pushers
    // (func_tracktrain sends svc_addangle to yaw the rider's view — in
    // a headset the world must not rotate under the user's head).
    {
        extern int cl_stereo_no_addangle;
        cl_stereo_no_addangle = 1;
    }
    // Enable cheats so debug binds (e.g. V → noclip) work.
    // fps_max 0: the compositor paces Host_DoFrame externally (90 Hz);
    // with the default cap (72) Host_FilterTime silently drops ~1 in 5
    // frames, presenting a cleared texture for that eye — visible judder.
    {
        extern void Cbuf_AddText( const char *text );
        Cbuf_AddText("sv_cheats 1\n");
        Cbuf_AddText("fps_max 0\n");
        // gl_vbo 1: the immediate-mode world path costs thousands of tiny
        // GL2-shim→ANGLE draws per eye per frame — measured p50 7-13 ms for
        // the stereo pair (misses the 11.1 ms 90 Hz budget in busy scenes).
        // The VBO path halves that (p50 5-7 ms, <15% frames over budget)
        // with no observed glitches on ANGLE/Metal.
        Cbuf_AddText("gl_vbo 1\n");
        // Max anisotropic filtering: ANGLE/Metal exposes
        // GL_EXT_texture_filter_anisotropic and Apple GPUs do 16x nearly
        // free — HL's oblique floors/walls smear badly without it.
        Cbuf_AddText("gl_anisotropy 16\n");
        // The 2D virtual screen is the eye render target (~3000 px wide);
        // HL HUD art and engine fonts draw at pixel sizes designed for
        // 640-1024-wide screens and are microscopic without scaling.
        // hud_scale 4 gives the HUD a ~768 px virtual screen.
        Cbuf_AddText("hud_scale 4\n");
        Cbuf_AddText("con_fontscale 3\n");
        // net_graph draws in raw virtual-screen pixels; at ~3000 px wide
        // (further minified into the angular 2D box) the 192x64 default is
        // an unreadable postage stamp.
        Cbuf_AddText("net_graphwidth 512\n");
        Cbuf_AddText("net_graphheight 160\n");
        // Number keys switch weapons directly (no HUD picker confirm) —
        // there's no comfortable "confirm" input in the headset.
        Cbuf_AddText("hud_fastswitch 1\n");
        // No client weapon prediction: shot EFFECTS (decals, tracers,
        // muzzle flash) are traced by client event playback using the raw
        // view angles, which ignores the VR aim-ray offset the server
        // applies (hlsdk ItemPostFrame) — bullets would damage where you
        // look but visibly hit screen center. With cl_lw 0 the server
        // plays the events with its (offset) angles. Latency is a
        // non-issue: single player, local loop.
        Cbuf_AddText("cl_lw 0\n");
        // Minimize mix-ahead: the mixer bakes each sound's L/R pan into the
        // DMA ring, so however far it paints ahead is how long a pan change
        // (head turn / strafe) takes to be heard. Default 0.12 s is very
        // audible as pan lag in VR. 0.04 s keeps a safe cushion above the
        // ~8 ms engine tick while making panning feel responsive.
        Cbuf_AddText("_snd_mixahead 0.04\n");
        // Default keyboard binds. We forward hardware-keyboard input as real
        // engine key events (Lambda_Bridge lambda_key_event), so the stock
        // bind system is the source of truth. No config.cfg with binds ships,
        // so establish the standard HL layout — but ONLY on first run. Once a
        // config.cfg exists (written on pause via host_writeconfig), the
        // engine's `exec config.cfg` restores the player's binds and we must
        // not clobber them. Z/X stay app-side (snap turn) and are unbound.
        char cfg_path[1024];
        snprintf(cfg_path, sizeof cfg_path, "%s/valve/config.cfg", writable_dir);
        int first_run = (access(cfg_path, F_OK) != 0);
        if (first_run) Cbuf_AddText(
            "bind \"w\" \"+forward\"\n"       "bind \"s\" \"+back\"\n"
            "bind \"a\" \"+moveleft\"\n"      "bind \"d\" \"+moveright\"\n"
            "bind \"uparrow\" \"+forward\"\n" "bind \"downarrow\" \"+back\"\n"
            "bind \"leftarrow\" \"+left\"\n"  "bind \"rightarrow\" \"+right\"\n"
            "bind \"space\" \"+jump\"\n"      "bind \"ctrl\" \"+duck\"\n"
            "bind \"shift\" \"+speed\"\n"     "bind \"e\" \"+use\"\n"
            "bind \"r\" \"+reload\"\n"        "bind \"f\" \"impulse 100\"\n"
            "bind \"q\" \"lastinv\"\n"        "bind \"t\" \"impulse 201\"\n"
            "bind \"mouse1\" \"+attack\"\n"   "bind \"mouse2\" \"+attack2\"\n"
            "bind \"1\" \"slot1\"\n" "bind \"2\" \"slot2\"\n" "bind \"3\" \"slot3\"\n"
            "bind \"4\" \"slot4\"\n" "bind \"5\" \"slot5\"\n" "bind \"6\" \"slot6\"\n"
            "bind \"7\" \"slot7\"\n" "bind \"8\" \"slot8\"\n" "bind \"9\" \"slot9\"\n"
            "bind \"0\" \"slot10\"\n"
            "bind \"[\" \"invprev\"\n"        "bind \"]\" \"invnext\"\n");
    }
    if (status_out) snprintf(status_out, status_cap,
                             "engine init ok (argc=%d, basedir=%s)", argc, writable_dir);
    return 0;
}

int lambda_engine_frame(void) {
    if (!g_engine_inited) return -1;
    return Host_DoFrame();
}

// ---- Gamepad → engine joystick axes ----------------------------------------
// Swift polls GCController on the render thread; the engine's joystick
// state (joyaxis[], in_joy.c) is only safe to touch on the GL worker that
// runs the tick. Values are staged here atomically and applied by the
// worker right before each Host_DoFrame. Axis ids match engineAxis_t:
// 0=SIDE 1=FWD 2=PITCH 3=YAW 4=RT 5=LT; values are SDL-style -32768..32767.
#include <stdatomic.h>
#define LAMBDA_JOY_AXES 6
static _Atomic int g_joy_axis[LAMBDA_JOY_AXES];
static _Atomic int g_joy_dirty;

void lambda_joy_set_axis(int axis, int value) {
    if (axis < 0 || axis >= LAMBDA_JOY_AXES) return;
    if (value < -32768) value = -32768;
    if (value >  32767) value =  32767;
    atomic_store(&g_joy_axis[axis], value);
    atomic_store(&g_joy_dirty, 1);
}

// Called on the GL worker before each engine tick.
static void lambda_joy_apply(void) {
    extern void Joy_AxisMotionEvent(int engineAxis, short value);
    if (!atomic_exchange(&g_joy_dirty, 0)) return;
    for (int i = 0; i < LAMBDA_JOY_AXES; i++)
        Joy_AxisMotionEvent(i, (short)atomic_load(&g_joy_axis[i]));
}

// Snap turn: exact yaw steps added to the engine's own view yaw
// (cl.viewangles, xash convention: +yaw = CCW/left) so the movement basis
// turns together with the rendered view. Accumulated from any thread in
// centidegrees (atomics are integer-only), consumed on the GL worker
// before each tick.
static _Atomic int g_pending_view_yaw_centideg;

void lambda_add_view_yaw(float yaw_deg) {
    atomic_fetch_add(&g_pending_view_yaw_centideg, (int)lroundf(yaw_deg * 100.0f));
}

static void lambda_view_yaw_apply(void) {
    extern void CL_StereoAddViewYaw(float deg);
    int cd = atomic_exchange(&g_pending_view_yaw_centideg, 0);
    if (cd) CL_StereoAddViewYaw((float)cd / 100.0f);
}

// Gaze/hand aim: angular offset of the aim ray from the view direction
// (degrees, xash conventions: pitch positive down, yaw CCW). hlsdk's
// CBasePlayer::ItemPostFrame (dlls/player.cpp) applies it to v_angle
// around the weapon frame only, so every weapon fires along the ray
// while view/movement/pmove stay on the real view angles. Staged in
// centidegrees (atomics are integer-only), published to the hlsdk-read
// globals on the GL worker at tick start.
extern float g_vr_aim_offset[2];  // defined in hlsdk dlls/player.cpp
static _Atomic int g_pending_aim_pitch_cd;
static _Atomic int g_pending_aim_yaw_cd;

void lambda_set_aim_offset(float pitch_deg, float yaw_deg) {
    atomic_store(&g_pending_aim_pitch_cd, (int)lroundf(pitch_deg * 100.0f));
    atomic_store(&g_pending_aim_yaw_cd,   (int)lroundf(yaw_deg * 100.0f));
}

static void lambda_aim_offset_apply(void) {
    g_vr_aim_offset[0] = (float)atomic_load(&g_pending_aim_pitch_cd) / 100.0f;
    g_vr_aim_offset[1] = (float)atomic_load(&g_pending_aim_yaw_cd) / 100.0f;
}

// Hand-anchored weapon: the tracked hand pose, camera-local in xash axes
// (x forward, y left, z up), position in xash units, forward/up unit
// vectors. hlsdk's cl_dll composes it with the rendered camera each frame
// and draws the current p_ model there (HUD_CreateEntities, entity.cpp),
// hiding the camera-locked viewmodel while active. Positions staged in
// centi-units, directions in milli (atomics are integer-only).
extern float g_vr_hand_pose[9];      // defined in hlsdk cl_dll/view.cpp
extern int   g_vr_hand_pose_active;  // ditto
extern float g_vr_cam_override[7];   // ditto: mirror of the engine's stereo
                                     // view override for the cl_dll (which
                                     // can't link engine symbols itself)
static _Atomic int g_pending_hand[9];
static _Atomic int g_pending_hand_active;

void lambda_set_hand_pose(float px, float py, float pz,
                          float fx, float fy, float fz,
                          float ux, float uy, float uz) {
    const float v[9] = { px, py, pz, fx, fy, fz, ux, uy, uz };
    for (int i = 0; i < 9; i++) {
        float scale = (i < 3) ? 100.0f : 1000.0f;
        atomic_store(&g_pending_hand[i], (int)lroundf(v[i] * scale));
    }
    atomic_store(&g_pending_hand_active, 1);
}

void lambda_clear_hand_pose(void) {
    atomic_store(&g_pending_hand_active, 0);
}

static void lambda_hand_pose_apply(void) {
    extern int   cl_stereo_view_angles_override_active;
    extern float cl_stereo_view_angles_override[3];
    extern float cl_stereo_view_origin_offset[3];
    for (int i = 0; i < 9; i++) {
        float scale = (i < 3) ? 100.0f : 1000.0f;
        g_vr_hand_pose[i] = (float)atomic_load(&g_pending_hand[i]) / scale;
    }
    g_vr_hand_pose_active = atomic_load(&g_pending_hand_active);
    // Mirror the engine's stereo view override for the cl_dll, which
    // composes the rendered camera from it (entity.cpp) but can't link
    // engine symbols at its intermediate dylib link.
    g_vr_cam_override[0] = cl_stereo_view_angles_override_active ? 1.0f : 0.0f;
    for (int i = 0; i < 3; i++) {
        g_vr_cam_override[1 + i] = cl_stereo_view_angles_override[i];
        g_vr_cam_override[4 + i] = cl_stereo_view_origin_offset[i];
    }
}

// ---- Stock menu (gameui) gaze+pinch input ---------------------------------
// The Half-Life menu polls a mouse we don't have on AVP. We synthesize it:
// Swift maps a pinch's gaze ray to a render-target pixel and stages it here;
// the GL worker feeds it to the menu each frame (UI_MouseMove) and delivers
// queued clicks (UI_KeyEvent K_MOUSE1 down+up). Applied BEFORE the engine
// tick so the menu draws with the right cursor — and because we launch with
// -noenginemouse, the engine's own IN_MouseMove is a no-op and never
// overwrites it. UI_IsVisible() is cached per frame so Swift can decide
// whether a pinch drives the menu or fires the weapon.
#define LAMBDA_K_MOUSE1 241
static _Atomic int g_menu_cursor_x, g_menu_cursor_y, g_menu_cursor_dirty;
static _Atomic int g_menu_clicks;   // queued click count (down+up pairs)
static _Atomic int g_menu_active;   // cached UI_IsVisible(), read by Swift

void lambda_menu_set_cursor(int x, int y) {
    atomic_store(&g_menu_cursor_x, x);
    atomic_store(&g_menu_cursor_y, y);
    atomic_store(&g_menu_cursor_dirty, 1);
}

void lambda_menu_click(void) {
    atomic_fetch_add(&g_menu_clicks, 1);
}

int lambda_menu_active(void) {
    return atomic_load(&g_menu_active);
}

// GL worker, each frame BEFORE the tick.
static void lambda_menu_input_apply(void) {
    extern void UI_MouseMove(int x, int y);
    extern void UI_KeyEvent(int key, int down);
    if (!atomic_load(&g_menu_active)) { atomic_store(&g_menu_clicks, 0); return; }
    if (atomic_exchange(&g_menu_cursor_dirty, 0))
        UI_MouseMove(atomic_load(&g_menu_cursor_x), atomic_load(&g_menu_cursor_y));
    int n = atomic_exchange(&g_menu_clicks, 0);
    for (int i = 0; i < n; i++) {
        UI_KeyEvent(LAMBDA_K_MOUSE1, 1);
        UI_KeyEvent(LAMBDA_K_MOUSE1, 0);
    }
}

// GL worker, each frame AFTER the tick — publish menu visibility for Swift.
static void lambda_menu_state_publish(void) {
    extern int UI_IsVisible(void);
    atomic_store(&g_menu_active, UI_IsVisible());
}

// ---- Hardware keyboard → engine key/char events ---------------------------
// visionOS delivers keyboard input via GameController (KeyboardInput.swift),
// not SDL. We forward it straight to the engine's input path so the stock
// bind system, console, and menu text fields all work: Key_Event(keynum,down)
// drives binds + navigation, CL_CharEvent(ch) drives console/menu text (it's
// a no-op in game). Events are queued from the event thread and drained on
// the GL worker before each tick (same thread the engine input path expects).
#include <pthread.h>   // key queue mutex (pthread is used by the GL worker too)
#define LAMBDA_KEYQ 256
typedef struct { int is_char; int code; int down; } lambda_key_ev_t;
static lambda_key_ev_t g_keyq[LAMBDA_KEYQ];
static int g_keyq_head, g_keyq_tail;
static pthread_mutex_t g_keyq_mtx = PTHREAD_MUTEX_INITIALIZER;

static void lambda_key_enqueue(int is_char, int code, int down) {
    pthread_mutex_lock(&g_keyq_mtx);
    int n = (g_keyq_head + 1) % LAMBDA_KEYQ;
    if (n != g_keyq_tail) {          // drop on overflow rather than block
        g_keyq[g_keyq_head].is_char = is_char;
        g_keyq[g_keyq_head].code = code;
        g_keyq[g_keyq_head].down = down;
        g_keyq_head = n;
    }
    pthread_mutex_unlock(&g_keyq_mtx);
}

void lambda_key_event(int key, int down) { lambda_key_enqueue(0, key, down); }
void lambda_char_event(int ch)           { lambda_key_enqueue(1, ch, 0); }

// GL worker, each frame BEFORE the tick.
static void lambda_key_queue_apply(void) {
    extern void Key_Event(int key, int down);
    extern void CL_CharEvent(int key);
    for (;;) {
        pthread_mutex_lock(&g_keyq_mtx);
        if (g_keyq_tail == g_keyq_head) { pthread_mutex_unlock(&g_keyq_mtx); break; }
        lambda_key_ev_t e = g_keyq[g_keyq_tail];
        g_keyq_tail = (g_keyq_tail + 1) % LAMBDA_KEYQ;
        pthread_mutex_unlock(&g_keyq_mtx);
        if (e.is_char) CL_CharEvent(e.code);
        else           Key_Event(e.code, e.down);
    }
}

// Pause/resume the engine's audio output. The AudioQueue backend
// (snd_visionos.c) streams the DMA ring on its own thread — when the
// render loop stops ticking (immersive space closed/paused) the mixer
// stops painting and the queue would loop the last ~0.4 s of stale
// samples forever. SNDDMA_Activate is a no-op before audio init.
void lambda_snd_activate(int active) {
    extern void SNDDMA_Activate(int active); // engine qboolean == int
    SNDDMA_Activate(active);
}

// Re-render the current world state without ticking the sim. Used by the
// stereo path: Host_DoFrame produces eye 0, then we rebind the FBO to the
// other slice and call this to produce eye 1 from the same simulation tick.
// V_PostRender draws the 2D layer (HUD, console, menu, debug graphs) —
// without it the right eye had no HUD at all. Its logic side effects
// (screenshot capture, extra sound mix) are idempotent within a frame:
// eye 0's full Host frame already consumed any pending one-shot actions.
extern void V_RenderView( void );
extern void V_PostRender( void );
extern float cl_stereo_eye_offset;
void lambda_engine_render_view_only(void) {
    if (!g_engine_inited) return;
    V_RenderView();
    V_PostRender();
}
void lambda_engine_set_stereo_offset(float off) {
    cl_stereo_eye_offset = off;
}

// Head-tracked view angles, degrees in xash convention (yaw=0 → +X;
// +yaw → left; +pitch → down; +roll → tilt right). Semantics match the
// engine-side override in cl_view.c: pitch and roll are ABSOLUTE (they
// replace the game's values with the headset orientation, decomposed in
// the engine's own yaw·pitch·roll Euler order), yaw is a DELTA added to
// the game's yaw so spawn orientation and keyboard turning still apply.
extern int   cl_stereo_view_angles_override_active;
extern float cl_stereo_view_angles_override[3];
extern float cl_stereo_view_origin_offset[3];
void lambda_engine_set_view_angles(float pitch_abs, float yaw_delta, float roll_abs) {
    cl_stereo_view_angles_override[0] = pitch_abs;
    cl_stereo_view_angles_override[1] = yaw_delta;
    cl_stereo_view_angles_override[2] = roll_abs;
    cl_stereo_view_angles_override_active = 1;
}
// Positional tracking: head translation since baseline, xash units, expressed
// in the baseline-forward frame (x = toward where the user faced at start,
// y = left, z = up). The engine rotates it by the game's yaw and adds it to
// vieworigin, detaching the camera from the player origin.
void lambda_engine_set_view_offset(float x, float y, float z) {
    cl_stereo_view_origin_offset[0] = x;
    cl_stereo_view_origin_offset[1] = y;
    cl_stereo_view_origin_offset[2] = z;
}
void lambda_engine_clear_view_angles(void) {
    cl_stereo_view_angles_override_active = 0;
}

// Per-eye 2D-layer viewport (GL pixels, origin bottom-left). NULL disables
// (2D layer spans the full render target, desktop behavior).
extern int   cl_stereo_2d_viewport_active;
extern float cl_stereo_2d_viewport[4];
static void lambda_engine_set_2d_viewport(const float *rect4) {
    if (rect4) {
        memcpy(cl_stereo_2d_viewport, rect4, sizeof(cl_stereo_2d_viewport));
        cl_stereo_2d_viewport_active = 1;
    } else {
        cl_stereo_2d_viewport_active = 0;
    }
}

// Step 3b.1: asymmetric per-eye projection from CompositorServices.
// tangents4 is (tan_left, tan_right, tan_top, tan_bottom), all positive
// magnitudes; the resulting frustum spans -left..+right and -bottom..+top
// at the near plane. Forward-Z OpenGL convention (xash's depth pipeline).
extern int   cl_stereo_proj_override_active;
extern float cl_stereo_proj_override[16];
extern float cl_stereo_cull_tangents[4];
void lambda_engine_set_projection_tangents(const float *tangents4,
                                           float zNear, float zFar) {
    memcpy(cl_stereo_cull_tangents, tangents4, sizeof cl_stereo_cull_tangents);
    float l = -tangents4[0] * zNear;
    float r =  tangents4[1] * zNear;
    float t =  tangents4[2] * zNear;
    float b = -tangents4[3] * zNear;
    float *P = cl_stereo_proj_override;
    memset(P, 0, sizeof cl_stereo_proj_override);
    P[0]  = (2.0f * zNear) / (r - l);
    P[5]  = (2.0f * zNear) / (t - b);
    P[8]  = (r + l) / (r - l);
    P[9]  = (t + b) / (t - b);
    P[10] = -(zFar + zNear) / (zFar - zNear);
    P[11] = -1.0f;
    P[14] = -(2.0f * zFar * zNear) / (zFar - zNear);
    cl_stereo_proj_override_active = 1;
}
void lambda_engine_clear_projection_override(void) {
    cl_stereo_proj_override_active = 0;
}

void lambda_engine_shutdown(void) {
    if (!g_engine_inited) return;
    Host_Shutdown();
    g_engine_inited = 0;
}

// ---- ANGLE / EGL smoke test ----------------------------------------------
//
// ANGLE's Metal backend is requested via eglGetPlatformDisplay with
// EGL_PLATFORM_ANGLE_TYPE_ANGLE_METAL. We make a context current on a 1x1
// pbuffer surface (avoids needing EGL_KHR_surfaceless_context) and read
// back the GL strings to confirm the libGLESv2_static + libEGL_static .a
// objects link, dispatch, and produce a working Metal-backed context inside
// the visionOS app sandbox. No CompositorServices integration yet.

#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>

int lambda_gl_smoke_test(char *status_out, int status_cap) {
    // eglGetPlatformDisplay (EGL 1.5) takes EGLAttrib (intptr-sized), unlike
    // eglChooseConfig which takes EGLint. Mixing them is a clang warning
    // under -Werror=incompatible-pointer-types.
    const EGLAttrib disp_attribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };
    EGLDisplay disp = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                            (void *)EGL_DEFAULT_DISPLAY,
                                            disp_attribs);
    if (disp == EGL_NO_DISPLAY) {
        snprintf(status_out, status_cap,
                 "eglGetPlatformDisplay → NO_DISPLAY (err=0x%x)", eglGetError());
        return -1;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(disp, &major, &minor)) {
        snprintf(status_out, status_cap,
                 "eglInitialize failed (err=0x%x)", eglGetError());
        return -2;
    }

    // Probe how many configs ANGLE Metal exposes total — diagnostic for
    // visionOS where the surface model is non-standard.
    EGLint total_cfgs = 0;
    eglGetConfigs(disp, NULL, 0, &total_cfgs);

    const EGLint cfg_attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_NONE
    };
    EGLConfig cfg = NULL;
    EGLint num_cfgs = 0;
    if (!eglChooseConfig(disp, cfg_attribs, &cfg, 1, &num_cfgs) || num_cfgs < 1) {
        // ANGLE Metal may not enumerate ES2+pbuffer configs by default —
        // try ES3 with no surface-type filter.
        const EGLint loose_attribs[] = {
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_NONE
        };
        if (!eglChooseConfig(disp, loose_attribs, &cfg, 1, &num_cfgs) || num_cfgs < 1) {
            // Last resort: pick the very first config eglGetConfigs returns,
            // whatever it is.
            if (total_cfgs > 0) {
                EGLConfig probe[1] = { NULL };
                EGLint got = 0;
                if (eglGetConfigs(disp, probe, 1, &got) && got >= 1) {
                    cfg = probe[0];
                    num_cfgs = got;
                }
            }
            if (num_cfgs < 1) {
                snprintf(status_out, status_cap,
                         "eglChooseConfig: 0 matches (total=%d, err=0x%x)",
                         total_cfgs, eglGetError());
                eglTerminate(disp);
                return -3;
            }
        }
    }

    const EGLint ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    EGLContext ctx = eglCreateContext(disp, cfg, EGL_NO_CONTEXT, ctx_attribs);
    if (ctx == EGL_NO_CONTEXT) {
        snprintf(status_out, status_cap,
                 "eglCreateContext failed (err=0x%x)", eglGetError());
        eglTerminate(disp);
        return -4;
    }

    const EGLint surf_attribs[] = {
        EGL_WIDTH,  1,
        EGL_HEIGHT, 1,
        EGL_NONE
    };
    EGLSurface surf = eglCreatePbufferSurface(disp, cfg, surf_attribs);
    if (surf == EGL_NO_SURFACE) {
        snprintf(status_out, status_cap,
                 "eglCreatePbufferSurface failed (err=0x%x)", eglGetError());
        eglDestroyContext(disp, ctx);
        eglTerminate(disp);
        return -5;
    }

    if (!eglMakeCurrent(disp, surf, surf, ctx)) {
        snprintf(status_out, status_cap,
                 "eglMakeCurrent failed (err=0x%x)", eglGetError());
        eglDestroySurface(disp, surf);
        eglDestroyContext(disp, ctx);
        eglTerminate(disp);
        return -6;
    }

    const char *ver = (const char *)glGetString(GL_VERSION);
    const char *rnd = (const char *)glGetString(GL_RENDERER);
    const char *ven = (const char *)glGetString(GL_VENDOR);
    snprintf(status_out, status_cap,
             "EGL %d.%d / %s / %s / %s",
             major, minor,
             ven ? ven : "?", rnd ? rnd : "?", ver ? ver : "?");

    eglMakeCurrent(disp, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(disp, surf);
    eglDestroyContext(disp, ctx);
    eglTerminate(disp);
    return 0;
}

// ---- Persistent GL state for the ANGLE → CompositorServices bridge ------
//
// One EGLDisplay + EGLContext for the app lifetime. The pbuffer surface
// here is a placeholder so eglMakeCurrent succeeds before any drawable is
// available; actual frame rendering targets the drawable's MTLTexture
// wrapped via EGL_ANGLE_metal_texture_client_buffer.

static EGLDisplay g_gl_disp = EGL_NO_DISPLAY;
static EGLContext g_gl_ctx  = EGL_NO_CONTEXT;
static EGLSurface g_gl_surf = EGL_NO_SURFACE;
static EGLConfig  g_gl_cfg  = NULL;

int lambda_gl_setup(char *status_out, int status_cap) {
    if (g_gl_disp != EGL_NO_DISPLAY) {
        snprintf(status_out, status_cap, "already initialized");
        return 0;
    }

    const EGLAttrib disp_attribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };
    g_gl_disp = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                      (void *)EGL_DEFAULT_DISPLAY,
                                      disp_attribs);
    if (g_gl_disp == EGL_NO_DISPLAY) {
        snprintf(status_out, status_cap,
                 "eglGetPlatformDisplay → NO_DISPLAY (err=0x%x)", eglGetError());
        return -1;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(g_gl_disp, &major, &minor)) {
        snprintf(status_out, status_cap,
                 "eglInitialize failed (err=0x%x)", eglGetError());
        g_gl_disp = EGL_NO_DISPLAY;
        return -2;
    }

    const EGLint cfg_attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_NONE
    };
    EGLint num_cfgs = 0;
    if (!eglChooseConfig(g_gl_disp, cfg_attribs, &g_gl_cfg, 1, &num_cfgs)
        || num_cfgs < 1) {
        // Fall back to whatever config eglGetConfigs returns first.
        EGLint total = 0;
        eglGetConfigs(g_gl_disp, NULL, 0, &total);
        EGLConfig probe[1] = { NULL };
        if (total > 0 && eglGetConfigs(g_gl_disp, probe, 1, &num_cfgs)
            && num_cfgs >= 1) {
            g_gl_cfg = probe[0];
        } else {
            snprintf(status_out, status_cap,
                     "eglChooseConfig: 0 matches (total=%d, err=0x%x)",
                     total, eglGetError());
            eglTerminate(g_gl_disp);
            g_gl_disp = EGL_NO_DISPLAY;
            return -3;
        }
    }

    // ES 3.0 is what ANGLE/Metal supports on visionOS. gl2_shim's default
    // shader version (310) is patched to 300 in the visionOS port so its
    // GLSL ES output matches the context.
    const EGLint ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    g_gl_ctx = eglCreateContext(g_gl_disp, g_gl_cfg, EGL_NO_CONTEXT, ctx_attribs);
    if (g_gl_ctx == EGL_NO_CONTEXT) {
        snprintf(status_out, status_cap,
                 "eglCreateContext failed (err=0x%x)", eglGetError());
        eglTerminate(g_gl_disp);
        g_gl_disp = EGL_NO_DISPLAY;
        return -4;
    }

    const EGLint surf_attribs[] = {
        EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE
    };
    g_gl_surf = eglCreatePbufferSurface(g_gl_disp, g_gl_cfg, surf_attribs);
    if (g_gl_surf == EGL_NO_SURFACE) {
        snprintf(status_out, status_cap,
                 "eglCreatePbufferSurface failed (err=0x%x)", eglGetError());
        eglDestroyContext(g_gl_disp, g_gl_ctx);
        eglTerminate(g_gl_disp);
        g_gl_disp = EGL_NO_DISPLAY;
        g_gl_ctx  = EGL_NO_CONTEXT;
        return -5;
    }

    if (!eglMakeCurrent(g_gl_disp, g_gl_surf, g_gl_surf, g_gl_ctx)) {
        snprintf(status_out, status_cap,
                 "eglMakeCurrent failed (err=0x%x)", eglGetError());
        eglDestroySurface(g_gl_disp, g_gl_surf);
        eglDestroyContext(g_gl_disp, g_gl_ctx);
        eglTerminate(g_gl_disp);
        g_gl_disp = EGL_NO_DISPLAY;
        g_gl_ctx  = EGL_NO_CONTEXT;
        g_gl_surf = EGL_NO_SURFACE;
        return -6;
    }

    // DO NOT release the context here. ANGLE/Metal on visionOS leaves the
    // context in a non-functional state after release+rebind, even on the
    // same thread (glGetString → null, glCreateShader → 0). The GL worker
    // thread that called this owns the binding for the process lifetime.

    snprintf(status_out, status_cap, "EGL %d.%d / context ES%d.%d ready",
             major, minor, 3, 0);
    return 0;
}

void lambda_gl_teardown(void) {
    if (g_gl_disp == EGL_NO_DISPLAY) return;
    eglMakeCurrent(g_gl_disp, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (g_gl_surf != EGL_NO_SURFACE) eglDestroySurface(g_gl_disp, g_gl_surf);
    if (g_gl_ctx  != EGL_NO_CONTEXT) eglDestroyContext(g_gl_disp, g_gl_ctx);
    eglTerminate(g_gl_disp);
    g_gl_disp = EGL_NO_DISPLAY;
    g_gl_ctx  = EGL_NO_CONTEXT;
    g_gl_surf = EGL_NO_SURFACE;
    g_gl_cfg  = NULL;
}

int lambda_gl_clear_mtl_texture(void *mtl_texture, int width, int height,
                                float r, float g, float b,
                                char *status_out, int status_cap) {
    if (g_gl_disp == EGL_NO_DISPLAY || g_gl_ctx == EGL_NO_CONTEXT) {
        snprintf(status_out, status_cap, "gl_setup not called");
        return -1;
    }
    if (!mtl_texture) {
        snprintf(status_out, status_cap, "null mtl_texture");
        return -2;
    }

    // Wrap the Metal texture as an EGLImage. EGL_METAL_TEXTURE_ANGLE accepts
    // any MTLTexture with MTLTextureUsageRenderTarget set.
    const EGLAttrib img_attribs[] = { EGL_NONE };
    EGLImage img = eglCreateImage(g_gl_disp, EGL_NO_CONTEXT,
                                  EGL_METAL_TEXTURE_ANGLE,
                                  (EGLClientBuffer)mtl_texture,
                                  img_attribs);
    if (img == EGL_NO_IMAGE) {
        snprintf(status_out, status_cap,
                 "eglCreateImage(METAL_TEXTURE) failed (err=0x%x)", eglGetError());
        return -3;
    }

    // Attach via a GL renderbuffer (more direct than texture target for FBO
    // color writes). glEGLImageTargetRenderbufferStorageOES is in
    // GL_OES_EGL_image, exposed by ANGLE on all backends.
    typedef void (*PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC)(GLenum, void*);
    PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC pglEGLImageTargetRenderbufferStorageOES =
        (PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC)
            eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");
    if (!pglEGLImageTargetRenderbufferStorageOES) {
        snprintf(status_out, status_cap,
                 "glEGLImageTargetRenderbufferStorageOES not exposed");
        eglDestroyImage(g_gl_disp, img);
        return -4;
    }

    GLuint rbo = 0, fbo = 0;
    glGenRenderbuffers(1, &rbo);
    glBindRenderbuffer(GL_RENDERBUFFER, rbo);
    pglEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER, img);

    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_RENDERBUFFER, rbo);

    GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbo_status != GL_FRAMEBUFFER_COMPLETE) {
        snprintf(status_out, status_cap,
                 "FBO not complete (0x%x)", fbo_status);
        glDeleteFramebuffers(1, &fbo);
        glDeleteRenderbuffers(1, &rbo);
        eglDestroyImage(g_gl_disp, img);
        return -5;
    }

    glViewport(0, 0, width, height);
    glClearColor(r, g, b, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // Flush to Metal command queue. eglWaitUntilWorkScheduledANGLE is the
    // ANGLE-recommended hand-off primitive when passing the underlying
    // resource back to a Metal consumer (the CompositorServices encoder).
    typedef EGLBoolean (*PFNEGLWAITUNTILWORKSCHEDULEDANGLEPROC)(EGLDisplay);
    PFNEGLWAITUNTILWORKSCHEDULEDANGLEPROC pegl_wait =
        (PFNEGLWAITUNTILWORKSCHEDULEDANGLEPROC)
            eglGetProcAddress("eglWaitUntilWorkScheduledANGLE");
    if (pegl_wait) pegl_wait(g_gl_disp);
    else           glFinish();

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);
    glDeleteRenderbuffers(1, &rbo);
    eglDestroyImage(g_gl_disp, img);

    snprintf(status_out, status_cap, "cleared %dx%d to (%.2f,%.2f,%.2f)",
             width, height, r, g, b);
    return 0;
}

// Per-frame state — kept across begin/end so engine code in between can
// just issue GL calls.
static GLuint    g_frame_fbo   = 0;     // FBO the engine renders into (MSAA when available)
static GLuint    g_frame_resolve_fbo = 0; // single-sample FBO wrapping the target MTLTexture
static GLuint    g_frame_rbo   = 0;     // EGLImage-backed RBO (the MTLTexture)
static GLuint    g_frame_msaa_color = 0;
static GLuint    g_frame_depth = 0;
static int       g_frame_depth_w = 0;
static int       g_frame_depth_h = 0;
static int       g_frame_w = 0, g_frame_h = 0;
static int       g_frame_samples = -1;  // -1 = not yet queried
static EGLImage  g_frame_image = EGL_NO_IMAGE;

// GPU-side frame fence (EGL_ANGLE_metal_shared_event_sync). When the app
// supplies an MTLSharedEvent + value, end_frame encodes a signal of that
// value on ANGLE's internal command queue instead of blocking the CPU in
// glFinish. The app's own MTLCommandQueue then waits for the value before
// reading colorMap — same ordering guarantee as glFinish, but the GL
// worker keeps running while the GPU finishes the eye: CPU sim/submission
// and GPU render overlap instead of serializing (~4-6 ms/frame saved).
static void              *g_frame_fence_event = NULL; // id<MTLSharedEvent>, borrowed
static unsigned long long g_frame_fence_value = 0;

void lambda_gl_set_frame_fence(void *mtl_shared_event, unsigned long long signal_value) {
    g_frame_fence_event = mtl_shared_event;
    g_frame_fence_value = signal_value;
}

int lambda_gl_begin_frame_into_mtl_texture(void *mtl_texture,
                                           int width, int height,
                                           float r, float g, float b) {
    if (g_gl_disp == EGL_NO_DISPLAY) return -1;
    if (!mtl_texture)                return -2;
    // Worker thread holds the context current for the process lifetime;
    // no rebind needed here.

    const EGLAttrib img_attribs[] = { EGL_NONE };
    g_frame_image = eglCreateImage(g_gl_disp, EGL_NO_CONTEXT,
                                   EGL_METAL_TEXTURE_ANGLE,
                                   (EGLClientBuffer)mtl_texture,
                                   img_attribs);
    if (g_frame_image == EGL_NO_IMAGE) return -3;

    typedef void (*PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC)(GLenum, void*);
    static PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC pglEGLImg = NULL;
    if (!pglEGLImg)
        pglEGLImg = (PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC)
            eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");
    if (!pglEGLImg) { eglDestroyImage(g_gl_disp, g_frame_image);
                      g_frame_image = EGL_NO_IMAGE; return -4; }

    glGenRenderbuffers(1, &g_frame_rbo);
    glBindRenderbuffer(GL_RENDERBUFFER, g_frame_rbo);
    pglEGLImg(GL_RENDERBUFFER, g_frame_image);

    // Optional MSAA: render into multisampled renderbuffers, resolve into
    // the MTLTexture at end_frame. OFF by default — measured on-device
    // (M5, 2911×2332): 4× costs ~+7 ms per stereo pair, because ANGLE
    // realizes ES MSAA renderbuffers as full memory store + blit resolve
    // rather than Metal's free on-tile resolve. Edge smoothing comes from
    // the MetalFX spatial upscale in the display path instead. Also note:
    // glCopyTex*/glReadPixels from a multisample FBO is invalid in ES3
    // (affects the engine's screen-copy effects, e.g. underwater warp).
    static const int msaa_requested = 0;
    if (g_frame_samples < 0) {
        GLint max_samples = 0;
        glGetIntegerv(GL_MAX_SAMPLES, &max_samples);
        g_frame_samples = (msaa_requested > 1 && max_samples >= 2)
                        ? (msaa_requested < max_samples ? msaa_requested : max_samples)
                        : 0;
    }

    // Multisampled color + depth-stencil renderbuffers, kept across frames
    // while the size is stable (colorMap size is fixed after first frame).
    // xash's BSP/studio rendering relies on z-test and skybox/decals on
    // stencil; without depth every fragment passes and far geometry
    // overwrites near geometry.
    if (g_frame_depth == 0
        || g_frame_depth_w != width
        || g_frame_depth_h != height) {
        if (g_frame_depth)      { glDeleteRenderbuffers(1, &g_frame_depth);      g_frame_depth = 0; }
        if (g_frame_msaa_color) { glDeleteRenderbuffers(1, &g_frame_msaa_color); g_frame_msaa_color = 0; }
        glGenRenderbuffers(1, &g_frame_depth);
        glBindRenderbuffer(GL_RENDERBUFFER, g_frame_depth);
        if (g_frame_samples > 1) {
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, g_frame_samples,
                                             GL_DEPTH24_STENCIL8, width, height);
            glGenRenderbuffers(1, &g_frame_msaa_color);
            glBindRenderbuffer(GL_RENDERBUFFER, g_frame_msaa_color);
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, g_frame_samples,
                                             GL_RGBA8, width, height);
        } else {
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
        }
        g_frame_depth_w = width;
        g_frame_depth_h = height;
    }

    glGenFramebuffers(1, &g_frame_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g_frame_fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_RENDERBUFFER,
                              g_frame_samples > 1 ? g_frame_msaa_color : g_frame_rbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                              GL_RENDERBUFFER, g_frame_depth);

    if (g_frame_samples > 1) {
        // Single-sample FBO wrapping the target texture; blit target for
        // the resolve at end_frame.
        glGenFramebuffers(1, &g_frame_resolve_fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, g_frame_resolve_fbo);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_RENDERBUFFER, g_frame_rbo);
        glBindFramebuffer(GL_FRAMEBUFFER, g_frame_fbo);
    }

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &g_frame_fbo);   g_frame_fbo = 0;
        if (g_frame_resolve_fbo) { glDeleteFramebuffers(1, &g_frame_resolve_fbo); g_frame_resolve_fbo = 0; }
        glDeleteRenderbuffers(1, &g_frame_rbo);  g_frame_rbo = 0;
        eglDestroyImage(g_gl_disp, g_frame_image); g_frame_image = EGL_NO_IMAGE;
        return -5;
    }

    g_frame_w = width;
    g_frame_h = height;
    glViewport(0, 0, width, height);
    glClearColor(r, g, b, 1.0f);
    glClearDepthf(1.0f);
    glClearStencil(0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    return 0;
}

int lambda_gl_end_frame(void) {
    if (g_gl_disp == EGL_NO_DISPLAY) return -1;
    if (g_frame_fbo == 0)            return 0; // begin was never called

    // Resolve the multisampled render into the target MTLTexture.
    if (g_frame_samples > 1 && g_frame_resolve_fbo) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, g_frame_fbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_frame_resolve_fbo);
        glBlitFramebuffer(0, 0, g_frame_w, g_frame_h,
                          0, 0, g_frame_w, g_frame_h,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }

    // ANGLE renders on its OWN internal MTLCommandQueue, while the app's
    // FXAA/upscale/display passes run on a separate queue — without a
    // fence the consumer races the producer and reads the previous
    // frame's contents. Preferred path: encode an MTLSharedEvent signal
    // on ANGLE's queue (EGL_ANGLE_metal_shared_event_sync) that the app
    // queue waits on GPU-side. Only when the app never registered a
    // fence event do we fall back to the old CPU-blocking glFinish.
    if (g_frame_fence_event) {
        const EGLAttrib sync_attribs[] = {
            EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE,
            (EGLAttrib)g_frame_fence_event,
            EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE,
            (EGLAttrib)(g_frame_fence_value & 0xffffffffull),
            EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE,
            (EGLAttrib)(g_frame_fence_value >> 32),
            EGL_NONE
        };
        EGLSync sync = eglCreateSync(g_gl_disp, EGL_SYNC_METAL_SHARED_EVENT_ANGLE,
                                     sync_attribs);
        if (sync != EGL_NO_SYNC) {
            // Fence syncs signal when the commands issued so far complete;
            // make sure those commands are actually committed to the GPU.
            typedef EGLBoolean (*PFNEGLWAITUNTILWORKSCHEDULEDANGLEPROC)(EGLDisplay);
            static PFNEGLWAITUNTILWORKSCHEDULEDANGLEPROC pegl_sched = NULL;
            if (!pegl_sched)
                pegl_sched = (PFNEGLWAITUNTILWORKSCHEDULEDANGLEPROC)
                    eglGetProcAddress("eglWaitUntilWorkScheduledANGLE");
            if (pegl_sched) pegl_sched(g_gl_disp);
            else            glFlush();
            eglDestroySync(g_gl_disp, sync);
        } else {
            // Sync creation failed (extension missing?) — stay correct.
            glFinish();
        }
    } else {
        glFinish();
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &g_frame_fbo);   g_frame_fbo = 0;
    if (g_frame_resolve_fbo) { glDeleteFramebuffers(1, &g_frame_resolve_fbo); g_frame_resolve_fbo = 0; }
    glDeleteRenderbuffers(1, &g_frame_rbo);  g_frame_rbo = 0;
    eglDestroyImage(g_gl_disp, g_frame_image); g_frame_image = EGL_NO_IMAGE;
    return 0;
}

// ---- GL worker thread -----------------------------------------------------
//
// ANGLE's Metal backend on visionOS doesn't tolerate cross-thread context
// migration: eglMakeCurrent on a second thread succeeds, but the actual GL
// machinery stays bound to the original thread, so glGetString and every
// downstream call (glCreateShader → 0) silently fails. Swift's Task
// executor on a DispatchQueue moves between OS threads across suspension
// points, which makes the engine init thread different from the setup
// thread. The fix is a dedicated pthread that owns the EGL context for
// the process lifetime; all GL + engine work runs on it via a synchronous
// work-queue posted from any Swift thread.

#include <pthread.h>
#include <signal.h>
#include <execinfo.h>
#include <fcntl.h>

// Where the crash handler writes the backtrace. Set by Swift at launch
// via lambda_set_crash_log_path; usually <app sandbox>/Documents/crash.log
// so it survives the process death and can be inspected later.
static char g_crash_log_path[1024] = "";

void lambda_set_crash_log_path(const char *path) {
    if (path) snprintf(g_crash_log_path, sizeof(g_crash_log_path), "%s", path);
}

static void crash_handler(int sig) {
    void *frames[64];
    int n = backtrace(frames, 64);
    int fds[2] = { 2 /*stderr*/, -1 };
    if (g_crash_log_path[0])
        fds[1] = open(g_crash_log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    for (int i = 0; i < 2; i++) {
        int fd = fds[i];
        if (fd < 0) continue;
        char hdr[128];
        int hl = snprintf(hdr, sizeof(hdr),
            "\n[LambdaVision] CRASH sig=%d on gl-worker; %d frames:\n", sig, n);
        write(fd, hdr, hl);
        backtrace_symbols_fd(frames, n, fd);
    }
    if (fds[1] >= 0) close(fds[1]);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_crash_handlers(void) {
    struct sigaction sa = {0};
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}

typedef enum {
    WORK_NONE = 0,
    WORK_SETUP,
    WORK_INIT,
    WORK_FRAME,
    WORK_FRAME_EYE2,
    WORK_CMD,
} gl_work_kind_t;

// engine console command (Cbuf_AddText) is the public C entry point.
// declared here so we don't have to pull engine headers in.
extern void Cbuf_AddText( const char *text );

static pthread_t       g_w_thread;
static pthread_mutex_t g_w_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_w_post = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  g_w_done = PTHREAD_COND_INITIALIZER;
static gl_work_kind_t  g_w_kind = WORK_NONE;
static int             g_w_started = 0;
// Ticket counters. Posters wait until any prior work completes before
// submitting their own (g_w_in_ticket == g_w_done_ticket), then bump
// g_w_in_ticket; the worker writes g_w_done_ticket and broadcasts so
// every blocked poster wakes and checks its own ticket. Without this,
// a second poster arriving while the worker is busy would overwrite
// g_w_kind and only one of the two posters would see the next done
// signal (pthread_cond_signal wakes one), losing the other forever.
static unsigned int    g_w_in_ticket = 0;
static unsigned int    g_w_done_ticket = 0;
// Held by lambda_gl_worker_* wrappers while they stage the payload and
// post — keeps two callers from racing on g_w_cmd / g_w_mtl / etc.
static pthread_mutex_t g_w_api_mtx = PTHREAD_MUTEX_INITIALIZER;

// Per-kind payloads (only one in flight at a time, so a flat union is fine).
static char       g_w_status[384];
static int        g_w_status_cap = sizeof(g_w_status);
static int        g_w_result = 0;
// init
static char       g_w_init_basedir[1024];
static int        g_w_init_argc = 0;
#define W_MAX_ARGV 64
static char       g_w_init_argv_storage[W_MAX_ARGV][128];
static const char *g_w_init_argv[W_MAX_ARGV];
// frame
static void      *g_w_mtl = NULL;
static int        g_w_w = 0, g_w_h = 0;
static float      g_w_r = 0, g_w_g = 0, g_w_b = 0;
// cmd
static char       g_w_cmd[256];
// stereo offset for the current/upcoming render
static float      g_w_eye_offset = 0.0f;
// per-eye AVP frustum tangents (left, right, top, bottom) + depth range.
// g_w_have_tangents == 0 means: do not override; engine uses its own projection.
static int        g_w_have_tangents = 0;
static float      g_w_tangents[4] = {0};
static float      g_w_znear = 4.0f, g_w_zfar = 4096.0f;
// Head-tracked viewangles override (abs pitch, delta yaw, abs roll —
// xash degrees). Same set/clear-around-engine pattern as tangents.
static int        g_w_have_view_angles = 0;
static float      g_w_view_angles[3] = {0};
// Per-eye 2D-layer viewport (GL pixels, origin bottom-left) — where the
// engine's HUD/console/menu overlay lands within this eye's render target.
static int        g_w_have_2d_rect = 0;
static float      g_w_2d_rect[4] = {0};
// Head translation since baseline (baseline-forward frame, xash units).
static float      g_w_view_offset[3] = {0};

// --- Frame timing instrumentation --------------------------------------
// Always-on, cheap (~one sorted copy every FT_WINDOW frames). Answers
// "where do the milliseconds go" when the headset drops below 90 Hz.
// Columns, all worker-thread CPU wall time in ms:
//   eng  = eye-0 Host frame (sim tick + client + scene GL submission)
//   end0 = eye-0 lambda_gl_end_frame (flush + GPU fence signal)
//   view = eye-1 V_RenderView + V_PostRender resubmission
//   end1 = eye-1 flush
#include <time.h>
#define FT_WINDOW 512
static double g_ft[4][FT_WINDOW];
static double g_ft_cur[4];
static int    g_ft_n = 0;

static double ft_now_ms(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-6;
}
static int ft_cmp(const void *a, const void *b) {
    double d = *(const double *)a - *(const double *)b;
    return (d > 0) - (d < 0);
}
// Called after the eye-1 columns are filled: commits the row, and every
// FT_WINDOW frames prints p50/p95/max per column to stderr.
static void ft_commit_row(void) {
    for (int c = 0; c < 4; c++) g_ft[c][g_ft_n] = g_ft_cur[c];
    if (++g_ft_n < FT_WINDOW) return;
    g_ft_n = 0;
    static const char *names[4] = { "eng", "end0", "view", "end1" };
    char line[256];
    int off = snprintf(line, sizeof(line), "[FT] cpu(ms)");
    for (int c = 0; c < 4; c++) {
        double tmp[FT_WINDOW];
        memcpy(tmp, g_ft[c], sizeof(tmp));
        qsort(tmp, FT_WINDOW, sizeof(double), ft_cmp);
        off += snprintf(line + off, sizeof(line) - (size_t)off,
                        " %s %.1f/%.1f/%.1f", names[c],
                        tmp[FT_WINDOW / 2], tmp[(int)(FT_WINDOW * 0.95)],
                        tmp[FT_WINDOW - 1]);
    }
    fprintf(stderr, "%s\n", line);
}

static void *gl_worker_main(void *arg) {
    (void)arg;
    pthread_setname_np("LambdaVision.gl-worker");
    install_crash_handlers();
    pthread_mutex_lock(&g_w_mtx);
    for (;;) {
        while (g_w_kind == WORK_NONE)
            pthread_cond_wait(&g_w_post, &g_w_mtx);
        gl_work_kind_t kind = g_w_kind;
        pthread_mutex_unlock(&g_w_mtx);

        switch (kind) {
        case WORK_SETUP:
            // lambda_gl_setup leaves the EGL context current on the
            // calling thread (us). Don't release; ANGLE/Metal can't
            // recover from rebind on visionOS.
            g_w_result = lambda_gl_setup(g_w_status, g_w_status_cap);
            break;
        case WORK_INIT:
            g_w_result = lambda_engine_init(g_w_init_basedir,
                                            g_w_init_argc,
                                            g_w_init_argv,
                                            g_w_status, g_w_status_cap);
            break;
        case WORK_FRAME: {
            lambda_joy_apply();
            lambda_view_yaw_apply();
            lambda_aim_offset_apply();
            int br = lambda_gl_begin_frame_into_mtl_texture(
                g_w_mtl, g_w_w, g_w_h, g_w_r, g_w_g, g_w_b);
            int er = 0;
            if (br == 0) {
                lambda_engine_set_stereo_offset(g_w_eye_offset);
                if (g_w_have_tangents)
                    lambda_engine_set_projection_tangents(g_w_tangents, g_w_znear, g_w_zfar);
                if (g_w_have_view_angles) {
                    lambda_engine_set_view_angles(g_w_view_angles[0],
                                                  g_w_view_angles[1],
                                                  g_w_view_angles[2]);
                    lambda_engine_set_view_offset(g_w_view_offset[0],
                                                  g_w_view_offset[1],
                                                  g_w_view_offset[2]);
                }
                // AFTER the view override is installed for THIS frame: the
                // hand-pose apply mirrors it into the cl_dll globals, and
                // the tick below composes the hand weapon from the mirror.
                // Mirroring before the set (the old order) handed the
                // entity a cleared/stale camera — the gun swam against
                // head motion instead of sticking to the hand.
                lambda_hand_pose_apply();
                lambda_engine_set_2d_viewport(g_w_have_2d_rect ? g_w_2d_rect : NULL);
                // Sync refState if the render size changed (scale setting +
                // immersive reopen), then feed keyboard + synthetic menu
                // cursor/clicks — all BEFORE the tick.
                lambda_render_size_apply();
                lambda_key_queue_apply();
                lambda_menu_input_apply();
                double t0 = ft_now_ms();
                lambda_engine_frame();
                double t1 = ft_now_ms();
                // The client (HUD_CreateEntities) just published the active
                // weapon's studio header when vr_weapon_external is on; bake a
                // fresh bind-pose mesh if the model changed. Cheap no-op
                // otherwise. Same thread as the publish, so the pointer is
                // sequenced; the snapshot swap is mutex-guarded for the reader.
                lambda_weapon_extract();
                // Publish menu visibility for the spatial-event router.
                lambda_menu_state_publish();
                if (g_w_have_view_angles)
                    lambda_engine_clear_view_angles();
                if (g_w_have_tangents)
                    lambda_engine_clear_projection_override();
                lambda_engine_set_stereo_offset(0.0f);
                er = lambda_gl_end_frame();
                g_ft_cur[0] = t1 - t0;
                g_ft_cur[1] = ft_now_ms() - t1;
            }
            g_w_result = (br != 0) ? br : er;
            break;
        }
        case WORK_FRAME_EYE2: {
            // Second eye: rebind FBO to the other slice and re-run only the
            // renderer (no sim tick). cl_stereo_eye_offset shifts the camera
            // along view-right inside V_RenderView.
            int br = lambda_gl_begin_frame_into_mtl_texture(
                g_w_mtl, g_w_w, g_w_h, g_w_r, g_w_g, g_w_b);
            int er = 0;
            if (br == 0) {
                lambda_engine_set_stereo_offset(g_w_eye_offset);
                if (g_w_have_tangents)
                    lambda_engine_set_projection_tangents(g_w_tangents, g_w_znear, g_w_zfar);
                if (g_w_have_view_angles) {
                    lambda_engine_set_view_angles(g_w_view_angles[0],
                                                  g_w_view_angles[1],
                                                  g_w_view_angles[2]);
                    lambda_engine_set_view_offset(g_w_view_offset[0],
                                                  g_w_view_offset[1],
                                                  g_w_view_offset[2]);
                }
                lambda_engine_set_2d_viewport(g_w_have_2d_rect ? g_w_2d_rect : NULL);
                double t0 = ft_now_ms();
                lambda_engine_render_view_only();
                double t1 = ft_now_ms();
                if (g_w_have_view_angles)
                    lambda_engine_clear_view_angles();
                if (g_w_have_tangents)
                    lambda_engine_clear_projection_override();
                lambda_engine_set_stereo_offset(0.0f);
                er = lambda_gl_end_frame();
                g_ft_cur[2] = t1 - t0;
                g_ft_cur[3] = ft_now_ms() - t1;
                ft_commit_row();
            }
            g_w_result = (br != 0) ? br : er;
            break;
        }
        case WORK_CMD:
            // Append "\n" so the engine treats it as a complete line.
            Cbuf_AddText(g_w_cmd);
            Cbuf_AddText("\n");
            g_w_result = 0;
            break;
        default: g_w_result = -1; break;
        }

        pthread_mutex_lock(&g_w_mtx);
        g_w_kind = WORK_NONE;
        g_w_done_ticket++;
        pthread_cond_broadcast(&g_w_done);
    }
    return NULL;
}

static int worker_post_and_wait(gl_work_kind_t kind) {
    pthread_mutex_lock(&g_w_mtx);
    // Wait until the worker is idle so we don't overwrite a pending kind.
    while (g_w_in_ticket != g_w_done_ticket)
        pthread_cond_wait(&g_w_done, &g_w_mtx);
    unsigned int my_ticket = ++g_w_in_ticket;
    g_w_kind = kind;
    pthread_cond_broadcast(&g_w_post);
    // Wait until OUR specific work finishes (broadcast wakes everyone;
    // each checks their own ticket).
    while (g_w_done_ticket < my_ticket)
        pthread_cond_wait(&g_w_done, &g_w_mtx);
    int rc = g_w_result;
    pthread_mutex_unlock(&g_w_mtx);
    return rc;
}

int lambda_gl_worker_setup(char *status_out, int status_cap) {
    pthread_mutex_lock(&g_w_api_mtx);
    if (!g_w_started) {
        g_w_started = 1;
        pthread_create(&g_w_thread, NULL, gl_worker_main, NULL);
    }
    int rc = worker_post_and_wait(WORK_SETUP);
    if (status_out && status_cap > 0)
        snprintf(status_out, status_cap, "%s", g_w_status);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}

int lambda_gl_worker_engine_init(const char *basedir,
                                 int argc, const char *const *argv,
                                 char *status_out, int status_cap) {
    pthread_mutex_lock(&g_w_api_mtx);
    snprintf(g_w_init_basedir, sizeof(g_w_init_basedir), "%s", basedir);
    g_w_init_argc = argc < W_MAX_ARGV ? argc : W_MAX_ARGV;
    for (int i = 0; i < g_w_init_argc; i++) {
        snprintf(g_w_init_argv_storage[i], sizeof(g_w_init_argv_storage[i]),
                 "%s", argv[i] ? argv[i] : "");
        g_w_init_argv[i] = g_w_init_argv_storage[i];
    }
    int rc = worker_post_and_wait(WORK_INIT);
    if (status_out && status_cap > 0)
        snprintf(status_out, status_cap, "%s", g_w_status);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}

int lambda_gl_worker_render_frame(void *mtl_texture, int width, int height,
                                  float r, float g, float b) {
    pthread_mutex_lock(&g_w_api_mtx);
    g_w_mtl = mtl_texture; g_w_w = width; g_w_h = height;
    g_w_r = r; g_w_g = g; g_w_b = b;
    g_w_eye_offset = 0.0f;
    int rc = worker_post_and_wait(WORK_FRAME);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}

int lambda_gl_worker_render_eye(int eye_index, float eye_offset,
                                void *mtl_texture, int width, int height,
                                float r, float g, float b) {
    pthread_mutex_lock(&g_w_api_mtx);
    g_w_mtl = mtl_texture; g_w_w = width; g_w_h = height;
    g_w_r = r; g_w_g = g; g_w_b = b;
    g_w_eye_offset = eye_offset;
    g_w_have_tangents = 0;
    g_w_have_view_angles = 0;
    int rc = worker_post_and_wait(eye_index == 0 ? WORK_FRAME : WORK_FRAME_EYE2);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}

// Same as lambda_gl_worker_render_eye, but additionally installs AVP's
// per-eye asymmetric projection for the duration of the engine call.
// tangents4 = (tan_left, tan_right, tan_top, tan_bottom), all positive
// magnitudes. zNear/zFar in xash world units (HL inches; ~39.37/m).
int lambda_gl_worker_render_eye_tangents(int eye_index, float eye_offset,
                                         const float *tangents4,
                                         float zNear, float zFar,
                                         void *mtl_texture, int width, int height,
                                         float r, float g, float b) {
    pthread_mutex_lock(&g_w_api_mtx);
    g_w_mtl = mtl_texture; g_w_w = width; g_w_h = height;
    g_w_r = r; g_w_g = g; g_w_b = b;
    g_w_eye_offset = eye_offset;
    g_w_tangents[0] = tangents4[0]; g_w_tangents[1] = tangents4[1];
    g_w_tangents[2] = tangents4[2]; g_w_tangents[3] = tangents4[3];
    g_w_znear = zNear; g_w_zfar = zFar;
    g_w_have_tangents = 1;
    g_w_have_view_angles = 0;
    int rc = worker_post_and_wait(eye_index == 0 ? WORK_FRAME : WORK_FRAME_EYE2);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}

// Stage the 2D-layer viewport for subsequent per-eye renders (GL pixels,
// origin bottom-left). Call before each render_eye with that eye's rect;
// pass w<=0 to disable (full-target 2D, desktop behavior).
void lambda_gl_worker_set_2d_viewport(float x, float y, float w, float h) {
    pthread_mutex_lock(&g_w_api_mtx);
    if (w > 0.0f && h > 0.0f) {
        g_w_2d_rect[0] = x; g_w_2d_rect[1] = y;
        g_w_2d_rect[2] = w; g_w_2d_rect[3] = h;
        g_w_have_2d_rect = 1;
    } else {
        g_w_have_2d_rect = 0;
    }
    pthread_mutex_unlock(&g_w_api_mtx);
}

// Full per-eye render: AVP frustum (tangents) + head-tracked viewangles +
// head translation. view_angles3 = (pitch, yaw, roll) in xash degrees;
// view_offset3 = head translation since baseline (baseline-forward frame,
// xash units), NULL for none.
int lambda_gl_worker_render_eye_full(int eye_index, float eye_offset,
                                     const float *tangents4,
                                     float zNear, float zFar,
                                     const float *view_angles3,
                                     const float *view_offset3,
                                     void *mtl_texture, int width, int height,
                                     float r, float g, float b) {
    pthread_mutex_lock(&g_w_api_mtx);
    g_w_mtl = mtl_texture; g_w_w = width; g_w_h = height;
    g_w_r = r; g_w_g = g; g_w_b = b;
    g_w_eye_offset = eye_offset;
    g_w_tangents[0] = tangents4[0]; g_w_tangents[1] = tangents4[1];
    g_w_tangents[2] = tangents4[2]; g_w_tangents[3] = tangents4[3];
    g_w_znear = zNear; g_w_zfar = zFar;
    g_w_have_tangents = 1;
    g_w_view_angles[0] = view_angles3[0];
    g_w_view_angles[1] = view_angles3[1];
    g_w_view_angles[2] = view_angles3[2];
    g_w_view_offset[0] = view_offset3 ? view_offset3[0] : 0.0f;
    g_w_view_offset[1] = view_offset3 ? view_offset3[1] : 0.0f;
    g_w_view_offset[2] = view_offset3 ? view_offset3[2] : 0.0f;
    g_w_have_view_angles = 1;
    int rc = worker_post_and_wait(eye_index == 0 ? WORK_FRAME : WORK_FRAME_EYE2);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}

int lambda_gl_worker_cmd(const char *cmd) {
    if (!cmd) return -1;
    pthread_mutex_lock(&g_w_api_mtx);
    snprintf(g_w_cmd, sizeof(g_w_cmd), "%s", cmd);
    int rc = worker_post_and_wait(WORK_CMD);
    pthread_mutex_unlock(&g_w_api_mtx);
    return rc;
}
