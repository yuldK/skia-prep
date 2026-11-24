// 패키지의 기능을 하나씩 떼어 링크하고 실제로 돌려 보는 도구다.
//
// 이 패키지의 원칙은 "기능을 쓰지 않는 소비자는 링크도 실행 파일 크기도 그대로"다.
// 그것을 재는 자리가 여기다. 같은 소스를 매크로로 갈라 기능마다 실행 파일을 따로
// 세우고, 그 기능의 아카이브만 더해 링크한다 (scripts/probe_features.ps1).
//
//   (매크로 없음)      base   png·jpeg·webp 디코드와 CPU 래스터. 기존 아카이브만 링크한다
//   PROBE_PNG_ENCODE   rust png 인코더로 쓰고 되읽는다 (무손실이므로 픽셀이 같아야 한다)
//   PROBE_JPEG_ENCODE  libjpeg-turbo 인코더로 쓰고 되읽는다
//   PROBE_SVG          SkSVGDOM -> SkPicture -> raster. path·gradient·<text>·viewBox 축소
//   PROBE_TEXT         HarfBuzz + SkUnicode(시스템 ICU)로 아랍어·힌디어·ZWJ 이모지·옛한글을
//                      모양 잡고 글리프와 클러스터를 센다. SkParagraph도 돌린다
//   PROBE_TEXT_FALLBACK  (PROBE_TEXT와 함께) ICU를 끄고 BestAvailableUnicode()가 libgrapheme
//                      백엔드로 물러선 뒤 같은 텍스트 시험을 돌린다
//   PROBE_AVIF         AVIF 디코더를 등록해 정지·애니메이션 AVIF를 읽는다
//   PROBE_SKOTTIE      Lottie JSON을 읽어 몇 프레임을 그린다
//   PROBE_D3D          (Windows) Direct3D 12 장치를 만들어 Ganesh로 그리고 되읽는다.
//                      Android의 Vulkan은 tools/android_probe.cpp가 본다
//   PROBE_METAL        (macOS) 시스템 기본 Metal 장치를 만들어 Ganesh로 그리고 되읽는다
//
// PROBE_SVG나 PROBE_SKOTTIE에 PROBE_TEXT를 함께 주면 그 모듈의 글자가 HarfBuzz 공장으로
// 모양 잡힌다. 하나라도 실패하면 0이 아닌 값으로 끝난다.
//
// 소비자와 같은 조건으로 세운다. Windows는 MSVC(/MT·/MTd), Android는 NDK clang과 lld,
// macOS는 Xcode의 clang과 ld다.
// 정의도 소비자와 같다 — SK_GANESH와 GPU 백엔드(SK_DIRECT3D·SK_VULKAN·SK_METAL), 텍스트를 켤 때만
// SK_SHAPER_HARFBUZZ_AVAILABLE·SK_SHAPER_UNICODE_AVAILABLE·SK_UNICODE_AVAILABLE·
// SK_UNICODE_ICU_IMPLEMENTATION. 시험 이미지는 tools/probe_assets.h에 박혀 있다.

// d3d12.h가 windows.h를 열어 min·max 매크로를 깐다. std::min·max를 쓰므로 막는다.
#if defined(_WIN32) && !defined(NOMINMAX)
#define NOMINMAX
#endif

#include "include/codec/SkCodec.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"

#if defined(PROBE_PNG_ENCODE)
#include "include/encode/SkPngRustEncoder.h"
#endif
#if defined(PROBE_JPEG_ENCODE)
#include "include/encode/SkJpegEncoder.h"
#endif
#if defined(PROBE_SVG)
#include "include/core/SkPicture.h"
#include "include/core/SkPictureRecorder.h"
#include "modules/svg/include/SkSVGDOM.h"
#include "modules/svg/include/SkSVGSVG.h"
#endif
#if defined(PROBE_SVG) || defined(PROBE_SKOTTIE)
#include "modules/skresources/include/SkResources.h"
#endif
#if defined(PROBE_SKOTTIE)
#include "modules/skottie/include/Skottie.h"
#endif
#if defined(PROBE_TEXT)
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skshaper/include/SkShaper.h"
#include "modules/skshaper/include/SkShaper_harfbuzz.h"
#include "modules/skshaper/include/SkShaper_skunicode.h"
#include "modules/skshaper/utils/FactoryHelpers.h"
#include "modules/skunicode/include/SkUnicode_icu.h"
#endif
#if defined(PROBE_AVIF)
#include "include/codec/SkAvifDecoder.h"
#endif
#if defined(PROBE_D3D)
#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/d3d/GrD3DBackendContext.h"
#include "include/gpu/ganesh/d3d/GrD3DDirectContext.h"
#include <dxgi1_4.h>
#endif
#if defined(PROBE_METAL)
#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include <objc/message.h>
#include <objc/runtime.h>
// Metal.framework의 C 함수다. 헤더(<Metal/Metal.h>)가 Objective-C라 이 파일을 C++로 두려고
// 선언만 옮긴다. 돌려주는 것은 +1로 retain된 id<MTLDevice>다.
extern "C" void* MTLCreateSystemDefaultDevice(void);
#endif

#if defined(PROBE_SVG) || defined(PROBE_TEXT) || defined(PROBE_SKOTTIE)
#if defined(_WIN32)
#include "include/ports/SkTypeface_win.h"
#elif defined(__ANDROID__)
#include "include/ports/SkFontMgr_android.h"
#include "include/ports/SkFontScanner_FreeType.h"
#elif defined(__APPLE__)
#include "include/ports/SkFontMgr_mac_ct.h"
#endif
#endif

#include "probe_assets.h"

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void Report(const char* stage, bool ok, const char* format, ...) {
    char detail[256];
    va_list args;
    va_start(args, format);
    std::vsnprintf(detail, sizeof(detail), format, args);
    va_end(args);
    std::printf("[%s] %-9s %s\n", ok ? "OK  " : "FAIL", stage, detail);
    if (!ok) {
        ++g_failures;
    }
}

// 판정하지 않고 남겨 두는 관찰이다. 글꼴처럼 기계마다 다른 것에 쓴다.
void Info(const char* stage, const char* format, ...) {
    char detail[256];
    va_list args;
    va_start(args, format);
    std::vsnprintf(detail, sizeof(detail), format, args);
    va_end(args);
    std::printf("[INFO] %-9s %s\n", stage, detail);
}

int ChannelDelta(SkColor a, SkColor b) {
    const int dr = std::abs(int(SkColorGetR(a)) - int(SkColorGetR(b)));
    const int dg = std::abs(int(SkColorGetG(a)) - int(SkColorGetG(b)));
    const int db = std::abs(int(SkColorGetB(a)) - int(SkColorGetB(b)));
    return std::max(dr, std::max(dg, db));
}

const SkColor kRed = SkColorSetRGB(220, 20, 30);
const SkColor kBlue = SkColorSetRGB(20, 40, 220);

sk_sp<SkData> Asset(const uint8_t* data, size_t size) {
    return SkData::MakeWithoutCopy(data, size);
}

// 디코드해 N32 premul 비트맵으로 받는다. 디코더 목록을 주지 않으면 skia의 기본 목록이다.
bool Decode(std::unique_ptr<SkCodec> codec, SkBitmap* out, int frame = 0) {
    if (!codec) {
        return false;
    }
    const SkImageInfo info = codec->getInfo().makeColorType(kN32_SkColorType)
                                     .makeAlphaType(kPremul_SkAlphaType);
    out->allocPixels(info);
    SkCodec::Options options;
    options.fFrameIndex = frame;
    return codec->getPixels(out->pixmap(), &options) == SkCodec::kSuccess;
}

bool HalvesMatch(const SkBitmap& bitmap, int tolerance) {
    const int w = bitmap.width();
    const int h = bitmap.height();
    return ChannelDelta(bitmap.getColor(w / 8, h / 2), kRed) <= tolerance &&
           ChannelDelta(bitmap.getColor(w - 1 - w / 8, h / 2), kBlue) <= tolerance;
}

int CountInk(const SkPixmap& pixmap, const SkIRect& area) {
    int ink = 0;
    for (int y = area.top(); y < area.bottom(); ++y) {
        for (int x = area.left(); x < area.right(); ++x) {
            const SkColor c = pixmap.getColor(x, y);
            if (SkColorGetR(c) < 96 && SkColorGetG(c) < 96 && SkColorGetB(c) < 96) {
                ++ink;
            }
        }
    }
    return ink;
}

// ---------------------------------------------------------------------------
// base: 기존 아카이브 목록만으로 서야 하는 것.
// ---------------------------------------------------------------------------
void ProbeBase() {
    struct Case {
        const char* name;
        const uint8_t* data;
        size_t size;
        int tolerance;
    };
    const Case cases[] = {
            {"png", probe_assets::kPng, sizeof(probe_assets::kPng), 0},
            {"jpeg", probe_assets::kJpeg, sizeof(probe_assets::kJpeg), 24},
            {"webp", probe_assets::kWebp, sizeof(probe_assets::kWebp), 0},
    };
    for (const Case& c : cases) {
        SkBitmap bitmap;
        const bool decoded = Decode(SkCodec::MakeFromData(Asset(c.data, c.size)), &bitmap);
        Report("decode", decoded && HalvesMatch(bitmap, c.tolerance), "%s %dx%d", c.name,
               bitmap.width(), bitmap.height());
    }

    // 래스터: png를 4배로 키워 그리고 두 자리를 읽는다.
    SkBitmap png;
    Decode(SkCodec::MakeFromData(Asset(probe_assets::kPng, sizeof(probe_assets::kPng))), &png);
    sk_sp<SkSurface> surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(64, 64));
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorWHITE);
    canvas->drawImageRect(png.asImage(), SkRect::MakeWH(64, 64), SkSamplingOptions());
    SkPaint paint;
    paint.setColor(SK_ColorBLACK);
    canvas->drawCircle(32, 32, 4, paint);
    SkBitmap result;
    result.allocPixels(surface->imageInfo());
    surface->readPixels(result.pixmap(), 0, 0);
    Report("raster", ChannelDelta(result.getColor(4, 8), kRed) == 0 &&
                             ChannelDelta(result.getColor(60, 8), kBlue) == 0 &&
                             result.getColor(32, 32) == SK_ColorBLACK,
           "64x64 scaled png and a circle");
}

#if defined(PROBE_PNG_ENCODE) || defined(PROBE_JPEG_ENCODE)
// 64x64 가로·세로 기울기다. jpeg가 블록 경계에서 크게 틀리지 않을 만큼 부드럽다.
SkBitmap GradientBitmap() {
    SkBitmap bitmap;
    bitmap.allocPixels(SkImageInfo::MakeN32Premul(64, 64));
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 64; ++x) {
            *bitmap.getAddr32(x, y) = SkPreMultiplyColor(
                    SkColorSetARGB(255, x * 4, y * 4, 255 - x * 2));
        }
    }
    return bitmap;
}

int MaxDelta(const SkBitmap& a, const SkBitmap& b) {
    int worst = 0;
    for (int y = 0; y < a.height(); ++y) {
        for (int x = 0; x < a.width(); ++x) {
            worst = std::max(worst, ChannelDelta(a.getColor(x, y), b.getColor(x, y)));
        }
    }
    return worst;
}
#endif

#if defined(PROBE_PNG_ENCODE)
void ProbePngEncode() {
    const SkBitmap source = GradientBitmap();
    sk_sp<SkData> png = SkPngRustEncoder::Encode(source.pixmap(), {});
    SkBitmap decoded;
    const bool ok = png && Decode(SkCodec::MakeFromData(png), &decoded);
    const int delta = ok ? MaxDelta(source, decoded) : -1;
    Report("png enc", ok && delta == 0, "%zu bytes, max channel delta %d (must be 0)",
           png ? png->size() : 0, delta);
}
#endif

#if defined(PROBE_JPEG_ENCODE)
void ProbeJpegEncode() {
    const SkBitmap source = GradientBitmap();
    SkJpegEncoder::Options options;
    options.fQuality = 95;
    SkDynamicMemoryWStream stream;
    const bool encoded = SkJpegEncoder::Encode(&stream, source.pixmap(), options);
    sk_sp<SkData> jpeg = stream.detachAsData();
    SkBitmap decoded;
    const bool ok = encoded && Decode(SkCodec::MakeFromData(jpeg), &decoded);
    const int delta = ok ? MaxDelta(source, decoded) : -1;
    Report("jpeg enc", ok && delta >= 0 && delta <= 16, "%zu bytes at q95, max channel delta %d",
           jpeg ? jpeg->size() : 0, delta);
}
#endif

#if defined(PROBE_SVG) || defined(PROBE_TEXT) || defined(PROBE_SKOTTIE)
sk_sp<SkFontMgr> MakeFontMgr() {
#if defined(_WIN32)
    return SkFontMgr_New_DirectWrite();
#elif defined(__ANDROID__)
    return SkFontMgr_New_Android(nullptr, SkFontScanner_Make_FreeType());
#elif defined(__APPLE__)
    return SkFontMgr_New_CoreText(nullptr);
#else
#error "No font manager for this platform."
#endif
}

const char* SansFamily() {
#if defined(_WIN32)
    return "Segoe UI";
#elif defined(__APPLE__)
    // CoreText는 "sans-serif" 같은 총칭 이름을 모른다.
    return "Helvetica";
#else
    return "sans-serif";
#endif
}
#endif

#if defined(PROBE_TEXT)
sk_sp<SkUnicode> g_unicode;

// 👨‍👩‍👧‍👦 사람 넷과 ZWJ 셋.
constexpr const char* kFamilyEmoji = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d"
                                     "\xf0\x9f\x91\xa7\xe2\x80\x8d\xf0\x9f\x91\xa6";
// 👩‍💻 여자, ZWJ, 노트북.
constexpr const char* kWomanTechnologist = "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb";
// ᄒᆞᆫ 초성 ㅎ(U+1112), 중성 아래아(U+119E), 종성 ㄴ(U+11AB).
constexpr const char* kOldHangul = "\xe1\x84\x92\xe1\x86\x9e\xe1\x86\xab";

sk_sp<SkShapers::Factory> ShapingFactory() {
    return sk_make_sp<SkShapers::HarfbuzzFactory>(g_unicode);
}
#endif

#if defined(PROBE_SVG) || defined(PROBE_SKOTTIE)
// 파일도 네트워크도 열지 않는다. 불린 횟수만 센다.
class DenyResources final : public skresources::ResourceProvider {
public:
    sk_sp<SkData> load(const char[], const char[]) const override {
        ++fCalls;
        return nullptr;
    }
    sk_sp<skresources::ImageAsset> loadImageAsset(const char[], const char[],
                                                  const char[]) const override {
        ++fCalls;
        return nullptr;
    }
    sk_sp<SkData> loadFont(const char[], const char[]) const override {
        ++fCalls;
        return nullptr;
    }
    sk_sp<SkTypeface> loadTypeface(const char[], const char[]) const override {
        ++fCalls;
        return nullptr;
    }
    mutable int fCalls = 0;
};
#endif

#if defined(PROBE_SVG)
// viewBox는 400x200이고 컨테이너는 200x100이다 (절반으로 축소). 기록한 picture를
// 화면 배율 2로 그리면 viewBox 좌표가 그대로 픽셀 좌표가 된다.
constexpr char kSvg[] = R"svg(<svg xmlns="http://www.w3.org/2000/svg"
     xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 400 200">
  <defs>
    <linearGradient id="lg" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ff0000"/>
      <stop offset="1" stop-color="#0000ff"/>
    </linearGradient>
    <radialGradient id="rg" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#00ff00"/>
      <stop offset="1" stop-color="#003300"/>
    </radialGradient>
  </defs>
  <rect x="0" y="0" width="200" height="100" fill="url(#lg)"/>
  <circle cx="300" cy="50" r="50" fill="url(#rg)"/>
  <path d="M0 200 L100 110 L200 200 Z" fill="#ffcc00"/>
  <text x="220" y="175" font-family="sans-serif" font-size="48" fill="#000000">%s</text>
  <image x="0" y="0" width="20" height="20" xlink:href="https://example.com/a.png"/>
  <image x="20" y="0" width="20" height="20" xlink:href="file:///etc/hosts"/>
</svg>)svg";

void ProbeSvg() {
#if defined(PROBE_TEXT)
    // 아랍어 셋 글자. HarfBuzz 공장을 넘긴 SVG가 오른쪽에서 왼쪽으로 이어 쓴다.
    const char* text = "\xd8\xb3\xd9\x84\xd8\xa7\xd9\x85";
#else
    const char* text = "Ag";
#endif
    char source[2048];
    std::snprintf(source, sizeof(source), kSvg, text);

    auto resources = sk_make_sp<DenyResources>();
    SkMemoryStream stream(source, std::strlen(source));
    SkSVGDOM::Builder builder;
    builder.setFontManager(MakeFontMgr()).setResourceProvider(resources);
#if defined(PROBE_TEXT)
    builder.setTextShapingFactory(ShapingFactory());
#endif
    sk_sp<SkSVGDOM> dom = builder.make(stream);
    if (!dom) {
        Report("svg", false, "SkSVGDOM::Builder::make returned null");
        return;
    }
    dom->setContainerSize(SkSize::Make(200, 100));

    SkPictureRecorder recorder;
    dom->render(recorder.beginRecording(SkRect::MakeWH(200, 100)));
    sk_sp<SkPicture> picture = recorder.finishRecordingAsPicture();

    sk_sp<SkSurface> surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(400, 200));
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorWHITE);
    canvas->scale(2, 2);
    canvas->drawPicture(picture);
    SkBitmap bitmap;
    bitmap.allocPixels(surface->imageInfo());
    surface->readPixels(bitmap.pixmap(), 0, 0);

    const SkColor left = bitmap.getColor(10, 60);
    const SkColor right = bitmap.getColor(190, 60);
    const bool linear = SkColorGetR(left) > 200 && SkColorGetB(left) < 60 &&
                        SkColorGetB(right) > 200 && SkColorGetR(right) < 60;
    Report("svg", linear, "linear gradient red -> blue across the rect");

    const SkColor center = bitmap.getColor(300, 50);
    const SkColor rim = bitmap.getColor(300, 96);
    Report("svg", SkColorGetG(center) > 220 && SkColorGetG(rim) < SkColorGetG(center) - 100,
           "radial gradient center g=%d, rim g=%d", SkColorGetG(center), SkColorGetG(rim));

    const SkColor path = bitmap.getColor(100, 190);
    Report("svg", ChannelDelta(path, SkColorSetRGB(0xff, 0xcc, 0x00)) <= 2, "path fill");

    const int ink = CountInk(bitmap.pixmap(), SkIRect::MakeLTRB(215, 110, 400, 190));
    Report("svg", ink > 200, "<text> inked %d px", ink);

    // 두 <image>는 거절당했다. 그 자리는 기울기 그대로 빨강이어야 한다.
    const bool denied = resources->fCalls >= 2 &&
                        SkColorGetR(bitmap.getColor(5, 5)) > 200 &&
                        SkColorGetR(bitmap.getColor(30, 5)) > 200;
    Report("svg", denied, "resource provider refused %d requests", resources->fCalls);
}
#endif

#if defined(PROBE_TEXT)
// 모양 잡은 결과를 그대로 받아 둔다.
class Collect final : public SkShaper::RunHandler {
public:
    struct Run {
        uint8_t level;
        std::vector<SkGlyphID> glyphs;
        std::vector<uint32_t> clusters;
    };

    void beginLine() override {}
    void runInfo(const RunInfo&) override {}
    void commitRunInfo() override {}
    Buffer runBuffer(const RunInfo& info) override {
        fRuns.push_back({info.fBidiLevel, std::vector<SkGlyphID>(info.glyphCount),
                         std::vector<uint32_t>(info.glyphCount)});
        fPositions.resize(info.glyphCount);
        Run& run = fRuns.back();
        return {run.glyphs.data(), fPositions.data(), nullptr, run.clusters.data(), {0, 0}};
    }
    void commitRunBuffer(const RunInfo&) override {}
    void commitLine() override {}

    size_t glyphCount() const {
        size_t count = 0;
        for (const Run& run : fRuns) {
            count += run.glyphs.size();
        }
        return count;
    }
    size_t clusterCount() const {
        std::set<uint32_t> clusters;
        for (const Run& run : fRuns) {
            clusters.insert(run.clusters.begin(), run.clusters.end());
        }
        return clusters.size();
    }
    std::vector<SkGlyphID> glyphs() const {
        std::vector<SkGlyphID> all;
        for (const Run& run : fRuns) {
            all.insert(all.end(), run.glyphs.begin(), run.glyphs.end());
        }
        return all;
    }

    std::vector<Run> fRuns;
    std::vector<SkPoint> fPositions;
};

// 옛한글 조합을 가진다고 아는 글꼴인가. Android의 대체 글꼴은 "NN##fallback"으로
// 이름이 붙는데, 한글의 대체 글꼴은 시스템의 Noto Sans CJK다. 그래서 Android에서는
// 언제나 판정한다.
bool HangulComposes(const SkString& family) {
#if defined(__ANDROID__)
    return true;
#else
    return family.contains("Noto") || family.contains("Source Han");
#endif
}

// typeface를 주지 않으면 기본 글꼴에서 시작해 글자마다 대체 글꼴로 넘어간다
// (MakeFontMgrRunIterator). 그 반복자는 **글자 단위**로 글꼴을 고르므로, 기본 글꼴에도
// 있는 ZWJ나 자모 일부가 다른 run으로 떨어져 하나로 묶이지 못한다 (Windows의 Segoe UI에서
// 실측: 가족 이모지가 글리프 일곱, 옛한글이 클러스터 셋). 그래서 둘은 그 글자를 가진
// 글꼴을 직접 준다. 글자소 단위로 대체 글꼴을 고르는 것은 SkParagraph다 (아래).
Collect Shape(const sk_sp<SkFontMgr>& fonts, const char* utf8,
              sk_sp<SkTypeface> typeface = nullptr) {
    const size_t bytes = std::strlen(utf8);
    if (!typeface) {
        typeface = fonts->matchFamilyStyle(SansFamily(), SkFontStyle());
    }
    SkFont font(typeface, 32);
    std::unique_ptr<SkShaper> shaper = SkShapers::HB::ShaperDrivenWrapper(g_unicode, fonts);
    auto font_runs = SkShaper::MakeFontMgrRunIterator(utf8, bytes, font, fonts);
    auto bidi = SkShapers::unicode::BidiRunIterator(g_unicode, utf8, bytes, 0);
    auto script = SkShapers::HB::ScriptRunIterator(utf8, bytes);
    auto language = SkShaper::MakeStdLanguageRunIterator(utf8, bytes);
    Collect collect;
    shaper->shape(utf8, bytes, *font_runs, *bidi, *script, *language, nullptr, 0, 100000,
                  &collect);
    return collect;
}

void ProbeText() {
#if defined(PROBE_TEXT_FALLBACK)
    // 플랫폼 ICU가 없는 기기를 흉내 낸다. 로더의 시험용 손잡이(skia-157-runtime-icu-system.patch)로
    // ICU를 열지 않게 하고, 소비자가 쓸 길(BestAvailableUnicode)이 libgrapheme으로 물러서는지 본다.
#if defined(_WIN32)
    _putenv_s("SKIA_PREP_ICU_DISABLE", "1");
#else
    setenv("SKIA_PREP_ICU_DISABLE", "1", 1);
#endif
    Report("unicode", SkUnicodes::ICU::Make() == nullptr, "ICU disabled: SkUnicodes::ICU::Make returns null");
    g_unicode = SkShapers::BestAvailableUnicode();
    Report("unicode", g_unicode != nullptr, "BestAvailableUnicode fell back to libgrapheme");
#else
    g_unicode = SkUnicodes::ICU::Make();
    Report("unicode", g_unicode != nullptr, "SkUnicodes::ICU::Make (system ICU)");
#endif
    if (!g_unicode) {
        return;
    }
    sk_sp<SkFontMgr> fonts = MakeFontMgr();

    // 아랍어 سلام. 오른쪽에서 왼쪽으로 놓이고(홀수 레벨, 클러스터가 줄어든다),
    // 첫 글자 س은 어두형이라 홀로 쓸 때와 다른 글리프다.
    {
        const Collect word = Shape(fonts, "\xd8\xb3\xd9\x84\xd8\xa7\xd9\x85");
        const Collect alone = Shape(fonts, "\xd8\xb3");
        bool rtl = !word.fRuns.empty();
        for (const auto& run : word.fRuns) {
            rtl = rtl && (run.level & 1) == 1;
        }
        const auto& first = word.fRuns.empty() ? Collect::Run{} : word.fRuns.front();
        const bool descending = first.clusters.size() >= 2 &&
                                first.clusters.front() > first.clusters.back();
        SkGlyphID seen_in_word = 0;
        for (size_t i = 0; i < first.clusters.size(); ++i) {
            if (first.clusters[i] == 0) {
                seen_in_word = first.glyphs[i];
            }
        }
        const SkGlyphID seen_alone = alone.glyphs().empty() ? 0 : alone.glyphs().front();
        Report("arabic", rtl && descending && seen_in_word != 0 && seen_in_word != seen_alone,
               "%zu glyphs, %zu clusters, rtl %d, joined form %u vs isolated %u",
               word.glyphCount(), word.clusterCount(), rtl, seen_in_word, seen_alone);
    }

    // 힌디어 कि. 모음 기호 ि가 자음 앞으로 옮겨 가고, 둘이 한 클러스터다.
    {
        const Collect syllable = Shape(fonts, "\xe0\xa4\x95\xe0\xa4\xbf");
        const Collect ka = Shape(fonts, "\xe0\xa4\x95");
        const auto glyphs = syllable.glyphs();
        const SkGlyphID ka_glyph = ka.glyphs().empty() ? 0 : ka.glyphs().front();
        const bool reordered = glyphs.size() == 2 && glyphs[0] != ka_glyph && glyphs[1] == ka_glyph;
        Report("hindi", reordered && syllable.clusterCount() == 1,
               "%zu glyphs, %zu cluster(s), matra placed before the consonant: %d",
               glyphs.size(), syllable.clusterCount(), reordered);
    }

    // ZWJ 시퀀스. 이모지 글꼴로 모양 잡으면 글리프 하나, 클러스터 하나다.
    //   👩‍💻 (여자 + ZWJ + 노트북)은 판정한다.
    //   👨‍👩‍👧‍👦 (가족 넷)은 글꼴이 그 합자를 가질 때만 하나가 된다. Windows 11의 Segoe UI
    //   Emoji에는 없어 글리프 넷으로 나온다 (2026-10 실측. 같은 글꼴에서 👩‍💻·🏳️‍🌈은
    //   하나다). Android의 Noto Color Emoji에는 있으므로 Android에서만 판정한다.
    {
        sk_sp<SkTypeface> emoji = fonts->matchFamilyStyleCharacter(nullptr, SkFontStyle(),
                                                                   nullptr, 0, 0x1F468);
        SkString family_name;
        if (emoji) {
            emoji->getFamilyName(&family_name);
        }
        const Collect coder = Shape(fonts, kWomanTechnologist, emoji);
        Report("emoji", emoji && coder.glyphCount() == 1 && coder.clusterCount() == 1,
               "ZWJ woman technologist (%s): %zu glyph(s), %zu cluster(s)", family_name.c_str(),
               coder.glyphCount(), coder.clusterCount());
        const Collect family = Shape(fonts, kFamilyEmoji, emoji);
        const bool one = family.glyphCount() == 1 && family.clusterCount() == 1;
#if defined(__ANDROID__)
        Report("emoji", one, "ZWJ family of four: %zu glyph(s), %zu cluster(s)",
               family.glyphCount(), family.clusterCount());
#else
        Info("emoji", "ZWJ family of four: %zu glyph(s), %zu cluster(s)%s", family.glyphCount(),
             family.clusterCount(), one ? "" : " - this emoji font has no ligature for it");
#endif
    }

    // 옛한글 ᄒᆞᆫ (조합형 자모 셋). 옛한글 조합을 가진 글꼴(ljmo·vjmo·tjmo)이면 한
    // 클러스터다. Windows 기본 한글 글꼴(맑은 고딕·바탕·굴림·돋움·궁서)은 자모 글리프는
    // 있어도 조합이 없어 셋으로 남는다 (2026-10 실측). 그래서 조합을 가진 글꼴을 찾아
    // 판정하고, 없으면 기록만 한다. Android는 Noto Sans CJK가 시스템 글꼴이다.
    sk_sp<SkTypeface> hangul;
    for (const char* family : {"Noto Sans KR", "Noto Serif KR", "Noto Sans CJK KR",
                               "Source Han Sans K"}) {
        if ((hangul = fonts->matchFamilyStyle(family, SkFontStyle()))) {
            break;
        }
    }
    if (!hangul) {
        const char* korean[] = {"ko"};
        hangul = fonts->matchFamilyStyleCharacter(nullptr, SkFontStyle(), korean, 1, 0x1112);
    }
    SkString hangul_name;
    if (hangul) {
        hangul->getFamilyName(&hangul_name);
    }
    {
        const Collect jamo = Shape(fonts, kOldHangul, hangul);
        const bool one = jamo.glyphCount() >= 1 && jamo.clusterCount() == 1;
        const bool capable = HangulComposes(hangul_name);
        if (capable) {
            Report("hangul", one, "old hangul jamo (%s): %zu glyph(s), %zu cluster(s)",
                   hangul_name.c_str(), jamo.glyphCount(), jamo.clusterCount());
        } else {
            Info("hangul", "old hangul jamo (%s): %zu glyph(s), %zu cluster(s) - no font with "
                 "old hangul composition", hangul_name.c_str(), jamo.glyphCount(),
                 jamo.clusterCount());
        }
    }

    // SkParagraph는 대체 글꼴을 글자소 단위로 고른다. 기본 글꼴에서 시작해도 ZWJ 시퀀스가
    // 쪼개지지 않는다. 옛한글은 위에서 고른 글꼴을 글꼴 목록의 둘째로 준다.
    using namespace skia::textlayout;
    auto collection = sk_make_sp<FontCollection>();
    collection->setDefaultFontManager(fonts, SansFamily());
    auto layout = [&](const char* utf8, TextDirection direction) {
        ParagraphStyle style;
        style.setTextDirection(direction);
        style.setTextAlign(TextAlign::kStart);
        TextStyle text_style;
        text_style.setColor(SK_ColorBLACK);
        text_style.setFontSize(32);
        text_style.setFontFamilies({SkString(SansFamily()), hangul_name});
        style.setTextStyle(text_style);
        auto builder = ParagraphBuilder::make(style, collection, g_unicode);
        builder->pushStyle(text_style);
        builder->addText(utf8);
        auto paragraph = builder->Build();
        paragraph->layout(600);
        return paragraph;
    };
    for (const char* utf8 : {kWomanTechnologist, kOldHangul}) {
        auto paragraph = layout(utf8, TextDirection::kLtr);
        int glyphs = 0;
        std::set<uint32_t> clusters;
        paragraph->visit([&](int, const Paragraph::VisitorInfo* info) {
            if (info) {
                glyphs += info->count;
                clusters.insert(info->utf8Starts, info->utf8Starts + info->count);
            }
        });
        const bool hangul_case = utf8 == kOldHangul;
        const bool judged = !hangul_case || HangulComposes(hangul_name);
        if (judged) {
            Report("paragraph", glyphs >= 1 && clusters.size() == 1,
                   "%s from the default font: %d glyph(s), %zu cluster(s)",
                   hangul_case ? "old hangul" : "ZWJ woman technologist", glyphs, clusters.size());
        } else {
            Info("paragraph", "old hangul: %d glyph(s), %zu cluster(s)", glyphs, clusters.size());
        }
    }

    // 오른쪽에서 왼쪽 문단은 시작 정렬이 오른쪽이다.
    {
        auto paragraph = layout("\xd9\x85\xd8\xb1\xd8\xad\xd8\xa8\xd8\xa7 "
                                "\xed\x95\x9c\xea\xb8\x80 "
                                "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d"
                                "\xf0\x9f\x91\xa7",
                                TextDirection::kRtl);

        sk_sp<SkSurface> surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(600, 60));
        surface->getCanvas()->clear(SK_ColorWHITE);
        paragraph->paint(surface->getCanvas(), 0, 0);
        SkBitmap bitmap;
        bitmap.allocPixels(surface->imageInfo());
        surface->readPixels(bitmap.pixmap(), 0, 0);
        const int left = CountInk(bitmap.pixmap(), SkIRect::MakeLTRB(0, 0, 300, 60));
        const int right = CountInk(bitmap.pixmap(), SkIRect::MakeLTRB(300, 0, 600, 60));
        Report("paragraph", paragraph->lineNumber() == 1 && right > 100 && left == 0,
               "rtl: %zu line(s), ink left %d / right %d (start aligns right)",
               paragraph->lineNumber(), left, right);
    }
}
#endif

#if defined(PROBE_AVIF)
void ProbeAvif() {
    sk_sp<SkData> still = Asset(probe_assets::kAvifStill, sizeof(probe_assets::kAvifStill));

    // 등록하기 전에는 skia의 기본 목록이 AVIF를 모른다. 그래야 AVIF를 쓰지 않는
    // 소비자가 libavif 없이 링크된다.
    Report("avif", SkCodec::MakeFromData(still) == nullptr,
           "default decoder list does not know AVIF");

    // 목록을 직접 넘기는 길.
    const SkCodecs::Decoder decoders[] = {SkAvifDecoder::LibAvif::Decoder()};
    SkBitmap bitmap;
    bool ok = Decode(SkCodec::MakeFromData(still, decoders), &bitmap);
    Report("avif", ok && HalvesMatch(bitmap, 24), "explicit decoder list: still %dx%d",
           bitmap.width(), bitmap.height());

    // 등록하는 길. 이후로는 기본 목록이 AVIF를 읽는다.
    SkCodecs::Register(SkAvifDecoder::LibAvif::Decoder());
    ok = Decode(SkCodec::MakeFromData(still), &bitmap);
    Report("avif", ok && HalvesMatch(bitmap, 24), "SkCodecs::Register: still");

    sk_sp<SkData> animated = Asset(probe_assets::kAvifAnimated, sizeof(probe_assets::kAvifAnimated));
    std::unique_ptr<SkCodec> codec = SkCodec::MakeFromData(animated);
    const int frames = codec ? codec->getFrameCount() : 0;
    const std::vector<SkCodec::FrameInfo> info = codec ? codec->getFrameInfo()
                                                       : std::vector<SkCodec::FrameInfo>{};
    const SkColor expected[] = {SkColorSetRGB(220, 20, 30), SkColorSetRGB(20, 200, 40),
                                SkColorSetRGB(20, 40, 220)};
    bool colors = frames == 3;
    for (int i = 0; colors && i < frames; ++i) {
        SkBitmap frame;
        colors = Decode(SkCodec::MakeFromData(animated), &frame, i) &&
                 ChannelDelta(frame.getColor(16, 16), expected[i]) <= 24 &&
                 info[i].fDuration == 100;
    }
    Report("avif", colors, "animated: %d frames, %d ms each, colors match", frames,
           info.empty() ? 0 : info[0].fDuration);
}
#endif

#if defined(PROBE_D3D)
// Direct3D 12 장치를 화면 없이 만들고 Ganesh로 그려 되읽는다. 하드웨어 어댑터가 없으면
// WARP(소프트웨어)로 내려간다 — 그때도 Skia의 D3D 백엔드 전체를 밟는다.
void ProbeD3D() {
    gr_cp<IDXGIFactory4> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
        Report("d3d", false, "CreateDXGIFactory1 failed");
        return;
    }
    GrD3DBackendContext backend;
    const char* kind = "hardware";
    for (UINT index = 0; !backend.fDevice; ++index) {
        gr_cp<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        DXGI_ADAPTER_DESC1 desc;
        adapter->GetDesc1(&desc);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
            continue;
        }
        if (SUCCEEDED(D3D12CreateDevice(adapter.get(), D3D_FEATURE_LEVEL_11_0,
                                        IID_PPV_ARGS(&backend.fDevice)))) {
            backend.fAdapter = std::move(adapter);
        }
    }
    if (!backend.fDevice) {
        kind = "WARP";
        gr_cp<IDXGIAdapter1> warp;
        if (FAILED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))) ||
            FAILED(D3D12CreateDevice(warp.get(), D3D_FEATURE_LEVEL_11_0,
                                     IID_PPV_ARGS(&backend.fDevice)))) {
            Report("d3d", false, "no Direct3D 12 device, not even WARP");
            return;
        }
        backend.fAdapter = std::move(warp);
    }
    D3D12_COMMAND_QUEUE_DESC queue_desc = {};
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (FAILED(backend.fDevice->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&backend.fQueue)))) {
        Report("d3d", false, "CreateCommandQueue failed");
        return;
    }
    sk_sp<GrDirectContext> context = GrDirectContexts::MakeD3D(backend);
    if (!context) {
        Report("d3d", false, "GrDirectContexts::MakeD3D returned null (%s adapter)", kind);
        return;
    }
    const SkImageInfo info = SkImageInfo::Make(64, 64, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    sk_sp<SkSurface> surface = SkSurfaces::RenderTarget(context.get(), skgpu::Budgeted::kNo, info);
    if (!surface) {
        Report("d3d", false, "SkSurfaces::RenderTarget returned null");
        return;
    }
    surface->getCanvas()->clear(SK_ColorBLUE);
    SkPaint paint;
    paint.setColor(SK_ColorRED);
    surface->getCanvas()->drawRect(SkRect::MakeXYWH(16, 16, 32, 32), paint);
    context->flushAndSubmit(surface.get(), GrSyncCpu::kYes);
    SkBitmap bitmap;
    bitmap.allocPixels(info);
    const bool read = surface->readPixels(bitmap.pixmap(), 0, 0);
    Report("d3d", read && bitmap.getColor(4, 4) == SK_ColorBLUE &&
                          bitmap.getColor(32, 32) == SK_ColorRED,
           "Ganesh on a %s Direct3D 12 adapter drew and read back", kind);
}
#endif

#if defined(PROBE_METAL)
template <typename R, typename... Args>
R Send(const void* receiver, const char* selector, Args... args) {
    return reinterpret_cast<R (*)(const void*, SEL, Args...)>(objc_msgSend)(
            receiver, sel_registerName(selector), args...);
}

// 시스템 기본 Metal 장치를 화면 없이 만들고 Ganesh로 그려 되읽는다. 소비자가 하는 일과
// 같다 — 장치와 큐를 만들어 GrMtlBackendContext에 넘긴다. 둘 다 +1로 받으므로 sk_cfp가
// 그대로 가진다.
void ProbeMetal() {
    GrMtlBackendContext backend;
    backend.fDevice.reset(MTLCreateSystemDefaultDevice());
    if (!backend.fDevice) {
        Report("metal", false, "MTLCreateSystemDefaultDevice returned nil");
        return;
    }
    const void* name = Send<const void*>(backend.fDevice.get(), "name");
    const char* device_name = name ? Send<const char*>(name, "UTF8String") : "?";
    backend.fQueue.reset(Send<const void*>(backend.fDevice.get(), "newCommandQueue"));
    if (!backend.fQueue) {
        Report("metal", false, "newCommandQueue returned nil (%s)", device_name);
        return;
    }
    sk_sp<GrDirectContext> context = GrDirectContexts::MakeMetal(backend);
    if (!context) {
        Report("metal", false, "GrDirectContexts::MakeMetal returned null (%s)", device_name);
        return;
    }
    const SkImageInfo info = SkImageInfo::Make(64, 64, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    sk_sp<SkSurface> surface = SkSurfaces::RenderTarget(context.get(), skgpu::Budgeted::kNo, info);
    if (!surface) {
        Report("metal", false, "SkSurfaces::RenderTarget returned null");
        return;
    }
    surface->getCanvas()->clear(SK_ColorBLUE);
    SkPaint paint;
    paint.setColor(SK_ColorRED);
    surface->getCanvas()->drawRect(SkRect::MakeXYWH(16, 16, 32, 32), paint);
    context->flushAndSubmit(surface.get(), GrSyncCpu::kYes);
    SkBitmap bitmap;
    bitmap.allocPixels(info);
    const bool read = surface->readPixels(bitmap.pixmap(), 0, 0);
    Report("metal", read && bitmap.getColor(4, 4) == SK_ColorBLUE &&
                            bitmap.getColor(32, 32) == SK_ColorRED,
           "Ganesh on %s drew and read back", device_name);
}
#endif

#if defined(PROBE_SKOTTIE)
// 100x100, 30 fps, 30 프레임. 사각형의 색이 빨강에서 파랑으로 가고, 아래에 글자가 있다.
std::string LottieJson() {
    std::string json = R"json({"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,
"fonts":{"list":[{"fName":"probe","fFamily":"FAMILY","fStyle":"Regular","ascent":75}]},
"layers":[
{"ty":5,"nm":"label","ind":1,"ip":0,"op":30,"st":0,
 "ks":{"o":{"a":0,"k":100},"p":{"a":0,"k":[8,92]},"a":{"a":0,"k":[0,0]},
       "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0}},
 "t":{"d":{"k":[{"t":0,"s":{"t":"TEXT","f":"probe","s":24,"fc":[0,0,0],"j":0,"lh":28}}]},
      "p":{},"m":{"g":1,"a":{"a":0,"k":[0,0]}},"a":[]}},
{"ty":4,"nm":"box","ind":2,"ip":0,"op":30,"st":0,
 "ks":{"o":{"a":0,"k":100},"p":{"a":0,"k":[50,50]},"a":{"a":0,"k":[0,0]},
       "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0}},
 "shapes":[{"ty":"rc","p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0}},
           {"ty":"fl","o":{"a":0,"k":100},
            "c":{"a":1,"k":[{"t":0,"s":[1,0,0,1],"i":{"x":[1],"y":[1]},"o":{"x":[0],"y":[0]}},
                            {"t":29,"s":[0,0,1,1]}]}}]}
]})json";
    auto replace = [&json](const std::string& from, const std::string& to) {
        json.replace(json.find(from), from.size(), to);
    };
    replace("FAMILY", SansFamily());
#if defined(PROBE_TEXT)
    replace("TEXT", "\xd8\xb3\xd9\x84\xd8\xa7\xd9\x85");
#else
    replace("TEXT", "Ag");
#endif
    return json;
}

void ProbeSkottie() {
    const std::string json = LottieJson();
    skottie::Animation::Builder builder;
    builder.setFontManager(MakeFontMgr()).setResourceProvider(sk_make_sp<DenyResources>());
#if defined(PROBE_TEXT)
    builder.setTextShapingFactory(ShapingFactory());
#endif
    sk_sp<skottie::Animation> animation = builder.make(json.data(), json.size());
    if (!animation) {
        Report("skottie", false, "Animation::Builder::make returned null");
        return;
    }
    sk_sp<SkSurface> surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(100, 100));
    SkBitmap bitmap;
    bitmap.allocPixels(surface->imageInfo());
    auto frame = [&](double index) {
        surface->getCanvas()->clear(SK_ColorWHITE);
        animation->seekFrame(index);
        animation->render(surface->getCanvas());
        surface->readPixels(bitmap.pixmap(), 0, 0);
        return bitmap.getColor(50, 20);
    };
    const SkColor first = frame(0);
    const SkColor middle = frame(15);
    const SkColor last = frame(29);
    const int ink = CountInk(bitmap.pixmap(), SkIRect::MakeLTRB(0, 60, 100, 100));
    Report("skottie", SkColorGetR(first) > 240 && SkColorGetB(first) < 15 &&
                              SkColorGetB(last) > 240 && SkColorGetR(last) < 15 &&
                              SkColorGetR(middle) > 60 && SkColorGetB(middle) > 60,
           "%.1fs at %.0f fps; frame 0/15/29 r=%d/%d/%d b=%d/%d/%d", animation->duration(),
           animation->fps(), SkColorGetR(first), SkColorGetR(middle), SkColorGetR(last),
           SkColorGetB(first), SkColorGetB(middle), SkColorGetB(last));
    Report("skottie", ink > 50, "text layer inked %d px", ink);
}
#endif

}  // namespace

int main() {
    ProbeBase();
#if defined(PROBE_D3D)
    ProbeD3D();
#endif
#if defined(PROBE_METAL)
    ProbeMetal();
#endif
#if defined(PROBE_PNG_ENCODE)
    ProbePngEncode();
#endif
#if defined(PROBE_JPEG_ENCODE)
    ProbeJpegEncode();
#endif
#if defined(PROBE_TEXT)
    ProbeText();
#endif
#if defined(PROBE_SVG)
    ProbeSvg();
#endif
#if defined(PROBE_AVIF)
    ProbeAvif();
#endif
#if defined(PROBE_SKOTTIE)
    ProbeSkottie();
#endif
    std::printf(g_failures ? "feature_probe failed: %d\n" : "feature_probe passed\n", g_failures);
    return g_failures ? 1 : 0;
}
