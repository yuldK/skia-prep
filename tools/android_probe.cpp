// Android용으로 세운 Skia가 기기에서 실제로 도는지 보는 도구다.
//
// 링크가 선다는 것은 심볼이 맞는다는 것까지다. 이 갈래는 두 NDK가 섞여
// 있어(rust 쪽 C++ 브리지는 Bazel이 받는 r21e, 나머지는 r27d) 실행해 봐야
// 아는 것이 남는다. 그래서 소비자가 실제로 밟을 길 넷을 기기 위에서 밟는다.
//
//   1. raster   CPU 래스터로 그리고 픽셀을 읽는다
//   2. png      rust 인코더로 쓰고 rust 디코더로 되읽어 픽셀을 맞댄다
//   3. fonts    SkFontMgr_android가 /system/etc/fonts.xml을 읽고 글자를 그린다
//   4. vulkan   화면 없이 장치를 만들어 Ganesh로 그리고 되읽는다
//
// 실행 파일 하나로 `adb shell`에서 돈다. 앱(APK)도 화면도 필요 없다.
// 하나라도 실패하면 0이 아닌 값으로 끝난다. Vulkan을 내지 않는 기기에서는
// 4를 건너뛴다고 적고 실패로 보지 않는다.
//
// Vulkan 메모리 할당기는 소비자가 넘겨야 한다 — M152의 GrVkGpu는 스스로
// 만들지 않는다. 만드는 함수가 Skia 내부 헤더에만 선언돼 있어 패키지에
// 들어가지 않으므로 여기서 직접 선언한다 (tools/skia_probe.cpp가 SkOpts를
// 다루는 것과 같은 방식이다).
//
// 세우는 법 (WSL, NDK r27d). 스크립트가 아직 Android를 모르는 동안의 기록이다.
// $out은 out/skia-ui-android-arm64-{release,debug}, 정의는 그 core.ninja의 -DSK*에서
// SKIA_IMPLEMENTATION만 뺀 것이다.
//
//   aarch64-linux-android26-clang++ -std=c++20 $defines -I<skia> android_probe.cpp \r
//       -Wl,--start-group $out/libskia.a $out/*.a -Wl,--end-group \r
//       -Wl,--allow-multiple-definition -landroid -llog -static-libstdc++
//
// 돌리는 법: adb push로 /data/local/tmp에 올리고 adb shell에서 실행한다.

#include "include/codec/SkCodec.h"
#include "include/codec/SkPngRustDecoder.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkRect.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/encode/SkPngRustEncoder.h"
#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/vk/GrVkDirectContext.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanExtensions.h"
#include "include/gpu/vk/VulkanMemoryAllocator.h"
#include "include/ports/SkFontMgr_android.h"
#include "include/ports/SkFontScanner_FreeType.h"

#include <dlfcn.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

// src/gpu/vk/vulkanmemoryallocator/VulkanMemoryAllocatorPriv.h와 같은 선언이다.
// ThreadSafe는 src/gpu/GpuTypesPriv.h에 있다 (kNo = false, kYes = true).
namespace skgpu {
enum class ThreadSafe : bool;
namespace VulkanMemoryAllocators {
sk_sp<VulkanMemoryAllocator> Make(const VulkanBackendContext&, ThreadSafe);
}  // namespace VulkanMemoryAllocators
}  // namespace skgpu

namespace {

constexpr int kSize = 64;

int g_failures = 0;

void Report(const char* stage, bool ok, const char* detail) {
    std::printf("[%s] %-7s %s\n", ok ? "OK  " : "FAIL", stage, detail);
    if (!ok) {
        ++g_failures;
    }
}

void Skip(const char* stage, const char* detail) {
    std::printf("[SKIP] %-7s %s\n", stage, detail);
}

// 파랑 바탕에 빨강 사각형 하나다. 두 자리의 색으로 그림이 맞는지 판정한다.
void DrawScene(SkCanvas* canvas) {
    canvas->clear(SK_ColorBLUE);
    SkPaint paint;
    paint.setColor(SK_ColorRED);
    canvas->drawRect(SkRect::MakeXYWH(16, 16, 32, 32), paint);
}

bool SceneMatches(const SkPixmap& pixmap) {
    return pixmap.getColor(4, 4) == SK_ColorBLUE && pixmap.getColor(32, 32) == SK_ColorRED;
}

SkImageInfo SceneInfo() {
    return SkImageInfo::Make(kSize, kSize, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
}

void ProbeRaster(SkBitmap* out) {
    sk_sp<SkSurface> surface = SkSurfaces::Raster(SceneInfo());
    if (!surface) {
        Report("raster", false, "SkSurfaces::Raster returned null");
        return;
    }
    DrawScene(surface->getCanvas());
    out->allocPixels(SceneInfo());
    const bool read = surface->readPixels(out->pixmap(), 0, 0);
    Report("raster", read && SceneMatches(out->pixmap()), "64x64 blue with a red square");
}

void ProbePng(const SkBitmap& scene) {
    sk_sp<SkData> png = SkPngRustEncoder::Encode(scene.pixmap(), {});
    if (!png) {
        Report("png", false, "SkPngRustEncoder::Encode returned null");
        return;
    }
    std::unique_ptr<SkCodec> codec =
            SkPngRustDecoder::Decode(SkMemoryStream::Make(png), nullptr);
    if (!codec) {
        Report("png", false, "SkPngRustDecoder::Decode returned null");
        return;
    }
    SkBitmap decoded;
    decoded.allocPixels(SceneInfo());
    const SkCodec::Result result = codec->getPixels(decoded.pixmap());
    bool same = result == SkCodec::kSuccess;
    for (int y = 0; same && y < kSize; ++y) {
        for (int x = 0; same && x < kSize; ++x) {
            same = decoded.pixmap().getColor(x, y) == scene.pixmap().getColor(x, y);
        }
    }
    char detail[96];
    std::snprintf(detail, sizeof(detail), "%zu bytes, round trip %s", png->size(),
                  same ? "is pixel-exact" : "differs");
    Report("png", same, detail);
}

void ProbeFonts() {
    sk_sp<SkFontMgr> fonts = SkFontMgr_New_Android(nullptr, SkFontScanner_Make_FreeType());
    if (!fonts) {
        Report("fonts", false, "SkFontMgr_New_Android returned null");
        return;
    }
    const int families = fonts->countFamilies();
    sk_sp<SkTypeface> typeface = fonts->matchFamilyStyle(nullptr, SkFontStyle());
    if (!typeface) {
        typeface = fonts->legacyMakeTypeface(nullptr, SkFontStyle());
    }
    char detail[96];
    if (!typeface) {
        std::snprintf(detail, sizeof(detail), "%d families, no default typeface", families);
        Report("fonts", false, detail);
        return;
    }

    // 글자를 실제로 그려 본다. 흰 바탕 위에 검은 픽셀이 하나라도 남아야 한다 —
    // freetype이 글꼴을 열고 래스터라이즈까지 했다는 뜻이다.
    sk_sp<SkSurface> surface = SkSurfaces::Raster(SceneInfo());
    surface->getCanvas()->clear(SK_ColorWHITE);
    SkFont font(typeface, 40);
    SkPaint paint;
    paint.setColor(SK_ColorBLACK);
    surface->getCanvas()->drawString("Ag", 4, 48, font, paint);
    SkBitmap pixels;
    pixels.allocPixels(SceneInfo());
    surface->readPixels(pixels.pixmap(), 0, 0);
    int inked = 0;
    for (int y = 0; y < kSize; ++y) {
        for (int x = 0; x < kSize; ++x) {
            if (SkColorGetR(pixels.pixmap().getColor(x, y)) < 128) {
                ++inked;
            }
        }
    }
    std::snprintf(detail, sizeof(detail), "%d families, \"Ag\" inked %d px", families, inked);
    Report("fonts", families > 0 && inked > 0, detail);
}

// Vulkan 장치를 화면 없이 만든다. 소비자가 할 일의 최소형이다.
class VulkanDevice {
public:
    ~VulkanDevice() {
        if (fDevice != VK_NULL_HANDLE) {
            fDestroyDevice(fDevice, nullptr);
        }
        if (fInstance != VK_NULL_HANDLE) {
            fDestroyInstance(fInstance, nullptr);
        }
        if (fLibrary) {
            dlclose(fLibrary);
        }
    }

    // 실패하면 이유를 남기고 false다. Vulkan이 없는 기기는 여기서 걸러진다.
    bool create(const char** reason) {
        fLibrary = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
        if (!fLibrary) {
            *reason = "libvulkan.so is not available";
            return false;
        }
        fGetInstanceProc = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
                dlsym(fLibrary, "vkGetInstanceProcAddr"));
        if (!fGetInstanceProc) {
            *reason = "vkGetInstanceProcAddr is missing";
            return false;
        }

        auto enumerate_version = reinterpret_cast<PFN_vkEnumerateInstanceVersion>(
                fGetInstanceProc(VK_NULL_HANDLE, "vkEnumerateInstanceVersion"));
        uint32_t instance_version = VK_API_VERSION_1_0;
        if (enumerate_version) {
            enumerate_version(&instance_version);
        }
        // Skia가 요구하는 하한이 1.1이다 (VulkanBackendContext.h).
        if (instance_version < VK_API_VERSION_1_1) {
            *reason = "the Vulkan loader is older than 1.1";
            return false;
        }
        fApiVersion = VK_API_VERSION_1_1;

        auto create_instance = reinterpret_cast<PFN_vkCreateInstance>(
                fGetInstanceProc(VK_NULL_HANDLE, "vkCreateInstance"));
        VkApplicationInfo application{};
        application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application.pApplicationName = "skia-prep android_probe";
        application.apiVersion = fApiVersion;
        VkInstanceCreateInfo instance_info{};
        instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instance_info.pApplicationInfo = &application;
        if (create_instance(&instance_info, nullptr, &fInstance) != VK_SUCCESS) {
            *reason = "vkCreateInstance failed";
            return false;
        }
        fDestroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(
                fGetInstanceProc(fInstance, "vkDestroyInstance"));

        auto enumerate_devices = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
                fGetInstanceProc(fInstance, "vkEnumeratePhysicalDevices"));
        uint32_t device_count = 0;
        enumerate_devices(fInstance, &device_count, nullptr);
        if (device_count == 0) {
            *reason = "no Vulkan physical device";
            return false;
        }
        std::vector<VkPhysicalDevice> devices(device_count);
        enumerate_devices(fInstance, &device_count, devices.data());
        fPhysicalDevice = devices[0];

        auto get_properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
                fGetInstanceProc(fInstance, "vkGetPhysicalDeviceProperties"));
        get_properties(fPhysicalDevice, &fProperties);
        if (fProperties.apiVersion < VK_API_VERSION_1_1) {
            *reason = "the Vulkan device is older than 1.1";
            return false;
        }

        auto get_queues = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
                fGetInstanceProc(fInstance, "vkGetPhysicalDeviceQueueFamilyProperties"));
        uint32_t family_count = 0;
        get_queues(fPhysicalDevice, &family_count, nullptr);
        std::vector<VkQueueFamilyProperties> families(family_count);
        get_queues(fPhysicalDevice, &family_count, families.data());
        bool found = false;
        for (uint32_t i = 0; i < family_count; ++i) {
            if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                fGraphicsQueueIndex = i;
                found = true;
                break;
            }
        }
        if (!found) {
            *reason = "no graphics queue family";
            return false;
        }

        const float priority = 1.0f;
        VkDeviceQueueCreateInfo queue_info{};
        queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = fGraphicsQueueIndex;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;
        // 기능은 아무것도 켜지 않는다. Skia에 그렇게 알리려고 0으로 채운 것을 넘긴다.
        VkDeviceCreateInfo device_info{};
        device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        device_info.pEnabledFeatures = &fFeatures;
        auto create_device = reinterpret_cast<PFN_vkCreateDevice>(
                fGetInstanceProc(fInstance, "vkCreateDevice"));
        if (create_device(fPhysicalDevice, &device_info, nullptr, &fDevice) != VK_SUCCESS) {
            *reason = "vkCreateDevice failed";
            return false;
        }
        auto get_device_proc = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
                fGetInstanceProc(fInstance, "vkGetDeviceProcAddr"));
        fGetDeviceProc = get_device_proc;
        fDestroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(
                get_device_proc(fDevice, "vkDestroyDevice"));
        auto get_queue = reinterpret_cast<PFN_vkGetDeviceQueue>(
                get_device_proc(fDevice, "vkGetDeviceQueue"));
        get_queue(fDevice, fGraphicsQueueIndex, 0, &fQueue);
        return true;
    }

    skgpu::VulkanBackendContext backendContext() {
        PFN_vkGetInstanceProcAddr instance_proc = fGetInstanceProc;
        PFN_vkGetDeviceProcAddr device_proc = fGetDeviceProc;
        fExtensions.init(
                [instance_proc, device_proc](const char* name, VkInstance instance,
                                             VkDevice device) -> PFN_vkVoidFunction {
                    if (device != VK_NULL_HANDLE) {
                        return device_proc(device, name);
                    }
                    return instance_proc(instance, name);
                },
                fInstance, fPhysicalDevice, 0, nullptr, 0, nullptr);

        skgpu::VulkanBackendContext context;
        context.fInstance = fInstance;
        context.fPhysicalDevice = fPhysicalDevice;
        context.fDevice = fDevice;
        context.fQueue = fQueue;
        context.fGraphicsQueueIndex = fGraphicsQueueIndex;
        context.fMaxAPIVersion = fApiVersion;
        context.fVkExtensions = &fExtensions;
        context.fDeviceFeatures = &fFeatures;
        context.fGetProc = [instance_proc, device_proc](const char* name, VkInstance instance,
                                                        VkDevice device) -> PFN_vkVoidFunction {
            if (device != VK_NULL_HANDLE) {
                return device_proc(device, name);
            }
            return instance_proc(instance, name);
        };
        context.fMemoryAllocator = skgpu::VulkanMemoryAllocators::Make(
                context, static_cast<skgpu::ThreadSafe>(false));
        return context;
    }

    const char* deviceName() const { return fProperties.deviceName; }

private:
    void* fLibrary = nullptr;
    PFN_vkGetInstanceProcAddr fGetInstanceProc = nullptr;
    PFN_vkGetDeviceProcAddr fGetDeviceProc = nullptr;
    PFN_vkDestroyInstance fDestroyInstance = nullptr;
    PFN_vkDestroyDevice fDestroyDevice = nullptr;
    VkInstance fInstance = VK_NULL_HANDLE;
    VkPhysicalDevice fPhysicalDevice = VK_NULL_HANDLE;
    VkDevice fDevice = VK_NULL_HANDLE;
    VkQueue fQueue = VK_NULL_HANDLE;
    uint32_t fGraphicsQueueIndex = 0;
    uint32_t fApiVersion = 0;
    VkPhysicalDeviceProperties fProperties{};
    VkPhysicalDeviceFeatures fFeatures{};
    skgpu::VulkanExtensions fExtensions;
};

void ProbeVulkan() {
    VulkanDevice device;
    const char* reason = "";
    if (!device.create(&reason)) {
        Skip("vulkan", reason);
        return;
    }
    char detail[192];
    {
        skgpu::VulkanBackendContext backend = device.backendContext();
        if (!backend.fMemoryAllocator) {
            std::snprintf(detail, sizeof(detail), "%s: no memory allocator", device.deviceName());
            Report("vulkan", false, detail);
            return;
        }
        sk_sp<GrDirectContext> context = GrDirectContexts::MakeVulkan(backend);
        if (!context) {
            std::snprintf(detail, sizeof(detail), "%s: GrDirectContexts::MakeVulkan returned null",
                          device.deviceName());
            Report("vulkan", false, detail);
            return;
        }
        sk_sp<SkSurface> surface = SkSurfaces::RenderTarget(
                context.get(), skgpu::Budgeted::kNo, SceneInfo(), 1, kTopLeft_GrSurfaceOrigin,
                nullptr);
        if (!surface) {
            std::snprintf(detail, sizeof(detail), "%s: no render target", device.deviceName());
            Report("vulkan", false, detail);
            return;
        }
        DrawScene(surface->getCanvas());
        context->flushAndSubmit(GrSyncCpu::kYes);
        SkBitmap pixels;
        pixels.allocPixels(SceneInfo());
        const bool read = surface->readPixels(pixels.pixmap(), 0, 0);
        std::snprintf(detail, sizeof(detail), "%s: Ganesh drew and read back", device.deviceName());
        Report("vulkan", read && SceneMatches(pixels.pixmap()), detail);
        // 장치를 부수기 전에 Skia가 쥔 자원을 먼저 놓는다.
        surface.reset();
        context->releaseResourcesAndAbandonContext();
    }
}

}  // namespace

int main() {
    SkBitmap scene;
    ProbeRaster(&scene);
    if (!scene.drawsNothing()) {
        ProbePng(scene);
    }
    ProbeFonts();
    ProbeVulkan();

    std::printf("%s\n", g_failures == 0 ? "android_probe passed" : "android_probe failed");
    return g_failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
