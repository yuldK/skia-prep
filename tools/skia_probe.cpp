// 빌드한 Skia 하나를 재어 보고하는 도구다. `scripts/bench_skia.ps1`이 두 번 세워
// (MSVC로 빌드한 Skia와 clang-cl로 빌드한 Skia에 각각 링크해) 결과를 맞대어 본다.
//
// **이 파일은 언제나 MSVC(cl.exe)로 컴파일한다.** 그것이 이 도구의 절반이다:
// 소비자가 MSVC이므로, clang-cl로 세운 Skia가 MSVC 소비자와 링크되고 실제로
// 도는지를 재는 것과 같은 자리에서 함께 확인한다. `-Toolchain clang`이 성립하려면
// 여기서 LNK2038도, 런타임 붕괴도 나지 않아야 한다.
//
// 재는 것은 셋이다.
//   1. 실제로 고른 SIMD 경로 — SkOpts의 래스터 파이프라인 처리 폭
//   2. 시간 — 디코딩과 cubic 축소
//   3. 결과 — 색상·알파 처리의 픽셀 값
//
// 1은 SkOpts의 전역 둘을 그대로 읽는다. 그 값이 곧
// src/opts/SkRasterPipeline_opts.h가 고른 경로다 (scalar면 1).
// SkOpts.h를 열지 않고 직접 선언하는 이유는 그것이 Skia 내부 헤더라 패키지에
// 들어가지 않기 때문이다 — 소비자가 실제로 볼 수 있는 자리만 쓰는 편이 정직하다.
//
// 3은 raw RGBA를 파일로 떨어뜨린다. 사람이 읽을 해시도 함께 찍지만, 두 빌드가
// 어긋났을 때 "얼마나" 어긋났는지는 스크립트가 그 raw를 채널 단위로 비교해 답한다.
//
// 원본 png는 이 도구가 만들지 않는다. tools/make_bench_source.py가 Skia 없이
// 만들어 두고, 여기서는 그것을 읽어 jpeg와 webp만 파생시킨다. 그래야 맞대어 볼
// 두 빌드가 같은 바이트를 디코딩하는 것이 "어느 쪽이 먼저 돌았는가"에 매이지
// 않는다. (SkPngRustEncoder는 아예 쓸 수 없다 — docs/skia-build.md 5.5.)

#include "include/codec/SkCodec.h"
#include "include/codec/SkGifDecoder.h"
#include "include/codec/SkJpegDecoder.h"
#include "include/codec/SkPngRustDecoder.h"
#include "include/codec/SkWebpDecoder.h"
#include "include/core/SkAlphaType.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkBlendMode.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkColorType.h"
#include "include/core/SkData.h"
#include "include/core/SkGraphics.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPoint.h"
#include "include/core/SkRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTileMode.h"
#include "include/core/SkShader.h"
#include "include/core/SkSpan.h"
#include "include/effects/SkGradient.h"
#include "include/encode/SkJpegEncoder.h"
#include "include/encode/SkWebpEncoder.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// src/core/SkOpts.h의 전역이다. SkGraphics::Init()이 SkOpts::Init()을 부르고,
// 그것이 CPU를 보고 더 나은 갈래로 이 값들을 바꿔 끼운다.
namespace SkOpts {
extern size_t raster_pipeline_lowp_stride;
extern size_t raster_pipeline_highp_stride;
}  // namespace SkOpts

namespace {

constexpr int kSourceWidth = 4000;
constexpr int kSourceHeight = 7000;

using Clock = std::chrono::steady_clock;

double MillisecondsSince(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

// FNV-1a. 사람이 눈으로 대조하기 위한 것이다. 판정은 raw 비교가 한다.
std::string HashPixels(const SkPixmap& pixmap) {
    uint64_t hash = 1469598103934665603ull;
    const uint8_t* base = static_cast<const uint8_t*>(pixmap.addr());
    const size_t row_bytes = static_cast<size_t>(pixmap.width()) * pixmap.info().bytesPerPixel();
    for (int y = 0; y < pixmap.height(); ++y) {
        const uint8_t* row = base + static_cast<size_t>(y) * pixmap.rowBytes();
        for (size_t i = 0; i < row_bytes; ++i) {
            hash = (hash ^ row[i]) * 1099511628211ull;
        }
    }
    char text[32];
    std::snprintf(text, sizeof(text), "%016llx", static_cast<unsigned long long>(hash));
    return text;
}

bool WritePixels(const std::string& path, const SkPixmap& pixmap) {
    SkFILEWStream stream(path.c_str());
    if (!stream.isValid()) {
        return false;
    }
    const size_t row_bytes = static_cast<size_t>(pixmap.width()) * pixmap.info().bytesPerPixel();
    for (int y = 0; y < pixmap.height(); ++y) {
        if (!stream.write(pixmap.addr(0, y), row_bytes)) {
            return false;
        }
    }
    return true;
}

bool WriteData(const std::string& path, const sk_sp<SkData>& data) {
    if (!data) {
        return false;
    }
    SkFILEWStream stream(path.c_str());
    return stream.isValid() && stream.write(data->data(), data->size());
}

// 원본 png에서 jpeg와 webp를 파생시킨다.
// 셋을 같은 픽셀에서 얻어야 디코더 셋의 시간을 나란히 놓을 수 있다.
int EmitAssets(const std::string& directory) {
    sk_sp<SkData> data = SkData::MakeFromFileName((directory + "\\source.png").c_str());
    if (!data) {
        std::fprintf(stderr,
                     "source.png is missing in %s.\n"
                     "Make it first: python tools/make_bench_source.py <that path>\n",
                     directory.c_str());
        return 1;
    }
    std::unique_ptr<SkCodec> codec = SkCodec::MakeFromData(data);
    SkBitmap source;
    if (!codec || !source.tryAllocPixels(codec->getInfo()
                                                 .makeColorType(kRGBA_8888_SkColorType)
                                                 .makeAlphaType(kUnpremul_SkAlphaType)
                                                 .makeColorSpace(SkColorSpace::MakeSRGB())) ||
        codec->getPixels(source.pixmap()) != SkCodec::kSuccess) {
        std::fprintf(stderr, "cannot decode source.png\n");
        return 1;
    }
    if (source.width() != kSourceWidth || source.height() != kSourceHeight) {
        std::fprintf(stderr, "source.png is %dx%d; expected %dx%d\n", source.width(),
                     source.height(), kSourceWidth, kSourceHeight);
        return 1;
    }
    const SkPixmap pixmap = source.pixmap();

    SkDynamicMemoryWStream jpeg;
    SkJpegEncoder::Options jpeg_options;
    jpeg_options.fQuality = 90;
    if (!SkJpegEncoder::Encode(&jpeg, pixmap, jpeg_options) ||
        !WriteData(directory + "\\source.jpg", jpeg.detachAsData())) {
        std::fprintf(stderr, "jpeg encode failed\n");
        return 1;
    }

    SkDynamicMemoryWStream webp;
    SkWebpEncoder::Options webp_options;
    webp_options.fCompression = SkWebpEncoder::Compression::kLossy;
    webp_options.fQuality = 90.0f;
    if (!SkWebpEncoder::Encode(&webp, pixmap, webp_options) ||
        !WriteData(directory + "\\source.webp", webp.detachAsData())) {
        std::fprintf(stderr, "webp encode failed\n");
        return 1;
    }
    std::printf("assets written to %s\n", directory.c_str());
    return 0;
}

struct Timing {
    double best_ms = 0;
    double median_ms = 0;
};

Timing Summarize(std::vector<double> samples) {
    std::sort(samples.begin(), samples.end());
    Timing timing;
    timing.best_ms = samples.front();
    timing.median_ms = samples[samples.size() / 2];
    return timing;
}

void ReportTiming(const char* name, const Timing& timing) {
    std::printf("time.%s.best_ms=%.2f\n", name, timing.best_ms);
    std::printf("time.%s.median_ms=%.2f\n", name, timing.median_ms);
}

sk_sp<SkData> ReadFile(const std::string& path) {
    sk_sp<SkData> data = SkData::MakeFromFileName(path.c_str());
    if (!data) {
        std::fprintf(stderr, "cannot read: %s\n", path.c_str());
    }
    return data;
}

// 목적지는 **반복 밖에서 한 번만** 잡는다.
// 4000x7000 RGBA는 112 MB고, 그것을 반복마다 새로 잡으면 재는 시간의 상당 부분이
// 페이지 폴트가 된다 — 도구사슬과 아무 상관 없는 값이 섞여 편차만 커진다.
// 재려는 것은 디코딩이지 할당이 아니다.
bool BenchmarkDecode(const char* name, const std::string& path, int repetitions,
                     SkBitmap* last) {
    sk_sp<SkData> data = ReadFile(path);
    if (!data) {
        return false;
    }
    std::printf("asset.%s.bytes=%zu\n", name, data->size());

    std::unique_ptr<SkCodec> probe = SkCodec::MakeFromData(data);
    if (!probe) {
        std::fprintf(stderr, "no codec for: %s\n", path.c_str());
        return false;
    }
    SkBitmap bitmap;
    if (!bitmap.tryAllocPixels(probe->getInfo()
                                       .makeColorType(kRGBA_8888_SkColorType)
                                       .makeAlphaType(kPremul_SkAlphaType)
                                       .makeColorSpace(SkColorSpace::MakeSRGB()))) {
        return false;
    }

    std::vector<double> samples;
    for (int i = 0; i < repetitions; ++i) {
        const Clock::time_point start = Clock::now();
        std::unique_ptr<SkCodec> codec = SkCodec::MakeFromData(data);
        if (!codec || codec->getPixels(bitmap.pixmap()) != SkCodec::kSuccess) {
            std::fprintf(stderr, "decode failed: %s\n", path.c_str());
            return false;
        }
        samples.push_back(MillisecondsSince(start));
    }
    ReportTiming(name, Summarize(std::move(samples)));
    *last = bitmap;
    return true;
}

// 이 저장소가 좇는 지연 그 자체다. 4000x7000을 CPU에서 cubic으로 줄인다.
// 그 경로가 SkImageShader -> SkRasterPipeline이고, 파이프라인의 처리 폭이 곧
// 이 시간이다.
//
// 여기서도 표면은 한 번만 잡고, snapshot은 반복이 모두 끝난 뒤에 한 번 뜬다.
// 반복마다 snapshot을 뜨면 다음 그리기가 copy-on-write를 깨워, 재는 값에 7 MB
// 복사가 붙는다. 블렌드가 kSrc라 같은 그리기를 몇 번 겹쳐도 결과는 같다.
bool BenchmarkDownscale(const char* name, const sk_sp<SkImage>& source, int width, int height,
                        const SkSamplingOptions& sampling, int repetitions,
                        sk_sp<SkImage>* last) {
    const SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType,
                                               kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    if (!surface) {
        std::fprintf(stderr, "cannot make a raster surface: %s\n", name);
        return false;
    }
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    const SkRect from = SkRect::MakeIWH(source->width(), source->height());
    const SkRect to = SkRect::MakeIWH(width, height);

    std::vector<double> samples;
    for (int i = 0; i < repetitions; ++i) {
        const Clock::time_point start = Clock::now();
        surface->getCanvas()->drawImageRect(source.get(), from, to, sampling, &paint,
                                            SkCanvas::kFast_SrcRectConstraint);
        samples.push_back(MillisecondsSince(start));
    }
    ReportTiming(name, Summarize(std::move(samples)));
    *last = surface->makeImageSnapshot();
    return true;
}

// 위의 것이 재는 것은 래스터화뿐이다. 그런데 응용이 큰 이미지를 한 번 줄일 때
// 실제로 치르는 값에는 목적지 표면을 잡는 값과 결과를 떠 가는 값이 함께 든다.
// 도구사슬을 바꿔도 그 둘은 줄지 않으므로, 래스터화만 재면 실제로 사람이 겪는
// 개선을 과장하게 된다. 두 값을 다 적어 두고 어느 쪽인지 이름으로 밝힌다.
bool BenchmarkDownscaleCold(const char* name, const sk_sp<SkImage>& source, int width, int height,
                            const SkSamplingOptions& sampling, int repetitions) {
    const SkImageInfo info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType,
                                               kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    const SkRect from = SkRect::MakeIWH(source->width(), source->height());
    const SkRect to = SkRect::MakeIWH(width, height);

    std::vector<double> samples;
    for (int i = 0; i < repetitions; ++i) {
        const Clock::time_point start = Clock::now();
        sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
        if (!surface) {
            return false;
        }
        surface->getCanvas()->drawImageRect(source.get(), from, to, sampling, &paint,
                                            SkCanvas::kFast_SrcRectConstraint);
        sk_sp<SkImage> scaled = surface->makeImageSnapshot();
        samples.push_back(MillisecondsSince(start));
    }
    ReportTiming(name, Summarize(std::move(samples)));
    return true;
}

bool RecordImage(const char* name, const std::string& directory, const sk_sp<SkImage>& image) {
    SkBitmap bitmap;
    const SkImageInfo info = SkImageInfo::Make(image->width(), image->height(),
                                               kRGBA_8888_SkColorType, kPremul_SkAlphaType,
                                               SkColorSpace::MakeSRGB());
    if (!bitmap.tryAllocPixels(info) || !image->readPixels(bitmap.pixmap(), 0, 0)) {
        std::fprintf(stderr, "readPixels failed: %s\n", name);
        return false;
    }
    std::printf("pixels.%s.size=%dx%d\n", name, bitmap.width(), bitmap.height());
    std::printf("pixels.%s.hash=%s\n", name, HashPixels(bitmap.pixmap()).c_str());
    return WritePixels(directory + "\\" + name + ".raw", bitmap.pixmap());
}

bool RecordBitmap(const char* name, const std::string& directory, const SkBitmap& bitmap) {
    std::printf("pixels.%s.size=%dx%d\n", name, bitmap.width(), bitmap.height());
    std::printf("pixels.%s.hash=%s\n", name, HashPixels(bitmap.pixmap()).c_str());
    return WritePixels(directory + "\\" + name + ".raw", bitmap.pixmap());
}

// 색상과 알파를 다루는 경로를 한 장에 모은다. 전부 SkRasterPipeline을 지나므로
// 처리 폭이 바뀌었을 때 값이 흔들리는지 여기서 드러난다.
//
//   윗줄  : 반투명 위에 반투명을 SrcOver로 얹는다 (프리멀티 알파)
//   가운데: 알파가 섞인 경사 (보간과 디더)
//   아랫줄: 색 공간 변환 (sRGB -> Display P3로 그린 뒤 sRGB로 읽는다)
bool RenderColorSuite(const std::string& directory) {
    constexpr int kWidth = 512;
    constexpr int kHeight = 384;
    const SkImageInfo info = SkImageInfo::Make(kWidth, kHeight, kRGBA_8888_SkColorType,
                                               kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    if (!surface) {
        return false;
    }
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);

    SkPaint paint;
    paint.setAntiAlias(true);
    for (int i = 0; i < 8; ++i) {
        paint.setColor(SkColorSetARGB(32 * (i + 1) - 1, 240, 40, 80));
        canvas->drawRect(SkRect::MakeXYWH(i * 56.0f, 8.0f, 96.0f, 104.0f), paint);
        paint.setColor(SkColorSetARGB(255 - 28 * i, 30, 90, 220));
        canvas->drawCircle(i * 56.0f + 48.0f, 60.0f, 34.0f, paint);
    }

    const SkPoint gradient_points[2] = {{0.0f, 128.0f}, {kWidth, 256.0f}};
    // 알파가 0에서 1까지 훑는다. 경사의 보간은 unpremul로 하고 합성은 premul로
    // 하므로, 그 왕복이 어긋나면 여기서 값이 흔들린다.
    const SkColor4f gradient_colors[4] = {{1.0f, 0.0f, 0.0f, 0.0f},
                                          {0.0f, 1.0f, 0.0f, 0.5f},
                                          {0.0f, 0.0f, 1.0f, 0.78f},
                                          {1.0f, 1.0f, 0.0f, 1.0f}};
    const SkGradient linear_gradient(SkGradient::Colors(gradient_colors, SkTileMode::kClamp),
                                     SkGradient::Interpolation{});
    SkPaint gradient;
    gradient.setShader(SkShaders::LinearGradient(gradient_points, linear_gradient));
    canvas->drawRect(SkRect::MakeXYWH(0.0f, 128.0f, kWidth, 128.0f), gradient);

    // 색 공간 변환. P3에서 그린 것을 sRGB 표면으로 읽어 오면 파이프라인의
    // transfer function과 gamut 행렬을 모두 지난다.
    const SkImageInfo wide = SkImageInfo::Make(
            kWidth, 128, kRGBA_8888_SkColorType, kPremul_SkAlphaType,
            SkColorSpace::MakeRGB(SkNamedTransferFn::kSRGB, SkNamedGamut::kDisplayP3));
    sk_sp<SkSurface> wide_surface = SkSurfaces::Raster(wide);
    if (!wide_surface) {
        return false;
    }
    SkPaint wide_paint;
    for (int i = 0; i < 16; ++i) {
        wide_paint.setColor(SkColorSetARGB(255, 255 - 16 * i, 16 * i, 128));
        wide_surface->getCanvas()->drawRect(SkRect::MakeXYWH(i * 32.0f, 0.0f, 32.0f, 128.0f),
                                            wide_paint);
    }
    sk_sp<SkImage> wide_image = wide_surface->makeImageSnapshot();
    canvas->drawImage(wide_image.get(), 0.0f, 256.0f);

    SkBitmap bitmap;
    if (!bitmap.tryAllocPixels(info) ||
        !surface->makeImageSnapshot()->readPixels(bitmap.pixmap(), 0, 0)) {
        return false;
    }
    return RecordBitmap("color_suite", directory, bitmap);
}

int Usage() {
    std::fprintf(stderr,
                 "usage:\n"
                 "  skia_probe --emit-assets <asset directory>\n"
                 "  skia_probe --bench <asset directory> <output directory> [repetitions]\n");
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    SkGraphics::Init();
    SkCodecs::Register(SkPngRustDecoder::Decoder());
    SkCodecs::Register(SkJpegDecoder::Decoder());
    SkCodecs::Register(SkWebpDecoder::Decoder());
    SkCodecs::Register(SkGifDecoder::Decoder());

    if (argc >= 3 && std::strcmp(argv[1], "--emit-assets") == 0) {
        return EmitAssets(argv[2]);
    }
    if (argc < 4 || std::strcmp(argv[1], "--bench") != 0) {
        return Usage();
    }
    const std::string assets = argv[2];
    const std::string output = argv[3];
    const int repetitions = argc >= 5 ? std::atoi(argv[4]) : 5;

    // 이 도구를 컴파일한 것과 링크한 Skia는 서로 다른 컴파일러일 수 있고,
    // 그것이 이 실험의 요점이다. 여기 찍히는 것은 **이 도구 쪽**이다.
#if defined(__clang__)
    std::printf("probe.compiler=clang-cl %d.%d.%d\n", __clang_major__, __clang_minor__,
                __clang_patchlevel__);
#else
    std::printf("probe.compiler=MSVC %d\n", _MSC_VER);
#endif
#if defined(_DEBUG)
    std::printf("probe.crt=/MTd\n");
#else
    std::printf("probe.crt=/MT\n");
#endif

    // 링크한 Skia가 실제로 고른 SIMD 경로다. 1이면 scalar,
    // 4면 SSE2, 8이면 AVX2(ml3)다 (lowp는 그 두 배).
    std::printf("skia.raster_pipeline_highp_stride=%zu\n", SkOpts::raster_pipeline_highp_stride);
    std::printf("skia.raster_pipeline_lowp_stride=%zu\n", SkOpts::raster_pipeline_lowp_stride);
    std::printf("bench.repetitions=%d\n", repetitions);

    SkBitmap png_bitmap;
    SkBitmap jpeg_bitmap;
    SkBitmap webp_bitmap;
    if (!BenchmarkDecode("decode_png", assets + "\\source.png", repetitions, &png_bitmap) ||
        !BenchmarkDecode("decode_jpeg", assets + "\\source.jpg", repetitions, &jpeg_bitmap) ||
        !BenchmarkDecode("decode_webp", assets + "\\source.webp", repetitions, &webp_bitmap)) {
        return 1;
    }
    if (!RecordBitmap("decode_png", output, png_bitmap) ||
        !RecordBitmap("decode_jpeg", output, jpeg_bitmap) ||
        !RecordBitmap("decode_webp", output, webp_bitmap)) {
        return 1;
    }

    sk_sp<SkImage> source = SkImages::RasterFromBitmap(png_bitmap);
    if (!source) {
        std::fprintf(stderr, "RasterFromBitmap failed\n");
        return 1;
    }

    const SkSamplingOptions cubic(SkCubicResampler::Mitchell());
    const SkSamplingOptions linear(SkFilterMode::kLinear, SkMipmapMode::kNone);
    sk_sp<SkImage> cubic_quarter;
    sk_sp<SkImage> cubic_eighth;
    sk_sp<SkImage> linear_quarter;
    if (!BenchmarkDownscale("cubic_1000x1750", source, 1000, 1750, cubic, repetitions,
                            &cubic_quarter) ||
        !BenchmarkDownscale("cubic_500x875", source, 500, 875, cubic, repetitions,
                            &cubic_eighth) ||
        !BenchmarkDownscale("linear_1000x1750", source, 1000, 1750, linear, repetitions,
                            &linear_quarter)) {
        return 1;
    }
    if (!BenchmarkDownscaleCold("cubic_1000x1750_cold", source, 1000, 1750, cubic, repetitions)) {
        return 1;
    }
    if (!RecordImage("cubic_1000x1750", output, cubic_quarter) ||
        !RecordImage("cubic_500x875", output, cubic_eighth) ||
        !RecordImage("linear_1000x1750", output, linear_quarter)) {
        return 1;
    }

    if (!RenderColorSuite(output)) {
        std::fprintf(stderr, "color suite failed\n");
        return 1;
    }

    std::printf("probe.status=ok\n");
    return 0;
}
