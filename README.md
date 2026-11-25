# skia-prep

`luil`이 쓰는 **Skia prebuilt 패키지를 만드는 저장소**다.

Skia를 소스로 세우는 데 드는 것 — submodule 5 GB, git 이력 4.7 GB, rust png를 쓰면
bazel 캐시 15 GB — 을 이 저장소 하나가 떠안는다. `luil`을 쓰는 사람은 이 저장소를
받지 않는다. 릴리스에 올라간 **자산(zip) 하나**만 받으면 된다.

| | 받는 것 |
| --- | --- |
| luil 소비자 | 대상·구성마다 릴리스 자산 zip 1개 |
| 이 저장소의 생산자 | submodule 전부 + gn·ninja·bazelisk, 그리고 대상의 컴파일러 |

| 대상 | 세우는 곳 | 컴파일러 | GPU | Release · Debug zip |
| --- | --- | --- | --- | --- |
| `win-x64` (157 r1) | Windows | clang-cl | Direct3D | 21.1 MB · 148.2 MB (+ Release 심볼 84.9 MB) |
| `android-arm64` (157 r1) | Linux (WSL2) | NDK r27d clang | Vulkan | 18.5 MB · 57.2 MB |
| `mac-arm64` (157 r1) | macOS (Apple Silicon) | Xcode clang | Metal | 11.5 MB · 177.3 MB |
| `ios-arm64` (157 r1) | macOS (Apple Silicon) | Xcode clang | Metal | 11.4 MB · 177.1 MB |
| `ios-arm64-simulator` (157 r1) | macOS (Apple Silicon) | Xcode clang | Metal | 11.5 MB · 177.2 MB |

Skia는 157(`b94213a11b`, chrome/m157)이다.

모든 대상이 SVG(`SkSVGDOM`), 텍스트 모양 잡기(HarfBuzz·시스템 ICU·SkParagraph),
ICU가 없는 플랫폼의 fallback(libgrapheme), Skottie, AVIF 디코드를 **기능별로 떨어진
아카이브**로 싣는다. 쓰지 않는 기능의 아카이브는 링크하지 않아도 되고, 기능 아카이브가
늘어도 기존 목록만 링크한 실행 파일의 크기는 그대로다. 표와 쓰는 법은
[docs/skia-build.md](docs/skia-build.md) 6장에 있다.

iOS는 iPhone·iPad 기기(`ios-arm64`)와 Apple Silicon Mac의 시뮬레이터(`ios-arm64-simulator`)
둘이다. 서로 링크되지 않는 플랫폼이라 패키지가 따로다.

> 이 저장소가 내는 것은 **Google과 무관한 비공식 빌드**다. Skia의 BSD-3-Clause 3항에
> 따라 저작권자와 기여자의 이름을 이 배포물의 홍보에 쓰지 않는다. Skia는 Google이
> 만들고 BSD-3-Clause로 배포하는 라이브러리이며, 원본은
> <https://skia.googlesource.com/skia> 에 있다.

## 패키지에 들어가는 것

배치가 **Skia 소스 트리와 같다.** 그래서 소비자의 빌드 체계는 이 패키지와 Skia 트리를
구별하지 않는다 — Skia 루트를 가리키는 변수를 여기로 돌리는 것으로 끝난다.

```
include/              Skia 공개 헤더 2.1 MB (include/third_party/ 는 뺀다)
modules/skcms/        공개 헤더가 include/ 밖에서 참조하는 것
modules/*/include/    기능의 공개 헤더 (svg·skshaper·skunicode·skparagraph·skottie·sksg·skresources)
src/core/ 등          그 헤더가 여는 Skia 내부 헤더 열하나 (pack_skia.ps1이 include를 따라 싣는다)
LICENSE               Skia 원문. 헤더가 소스 형태로 나가므로 필수다
NOTICE.md             정적으로 들어간 모든 것의 고지를 모은 한 장
NOTICE.json           아카이브마다 담긴 것과 기능마다 링크되는 것의 고지 id
licenses/rust/        rust 갈래에서만. Rust 표준 라이브러리 고지
VERSION.json          Skia commit·밀번·png 갈래·도구사슬·패키지 판번·파일별 SHA-256
out/skia-ui-release/  *.lib *.a args.gn toolchain.json   (Android·macOS·iOS는 *.a뿐이다)
out/skia-ui-debug/    (Debug 패키지)
```

배치는 대상과 무관하게 같다. 대상은 패키지마다 하나이고 `VERSION.json`의 `target`과
자산 이름이 그것을 말한다.

`args.gn`을 함께 싣는 것이 구성 계약이다. 소비자는 그것을 읽어 자기가 요구하는
기능(Direct3D·코덱)으로 빌드된 패키지인지 configure 시점에 판정한다.

`toolchain.json`은 그 곁의 사실이다 — **무엇이 컴파일했는가**는 `args.gn`이 적지
못한다. 같은 Skia commit을 다른 컴파일러로 세우면 성능이 다른 물건이 나오므로
(아래), 자산 이름과 태그에도 패키지 판번이 붙는다.

## 생산자 절차

```bash
git submodule update --init third_party/skia
git submodule update --init third_party/skia-externals/d3d12allocator
git submodule update --init third_party/skia-externals/spirv-cross
git submodule update --init third_party/skia-externals/spirv-headers
git submodule update --init third_party/skia-externals/libjpeg-turbo
git submodule update --init third_party/skia-externals/libwebp
git submodule update --init third_party/skia-externals/wuffs
git submodule update --init third_party/skia-externals/libpng
git submodule update --init third_party/skia-externals/zlib
git submodule update --init third_party/skia-externals/expat
git submodule update --init third_party/skia-externals/harfbuzz
git submodule update --init third_party/skia-externals/icu
git submodule update --init third_party/skia-externals/libavif
git submodule update --init third_party/skia-externals/libgav1
git submodule update --init third_party/skia-externals/libyuv
git submodule update --init third_party/skia-externals/libgrapheme
```

`libpng`과 `zlib`은 **물러설 자리인 libpng 갈래**에만 필요하다. 뒤의 일곱과
`unicodetools`는 기능별 아카이브의 것이다 — `icu`는 헤더와 BiDi 조각으로만 쓴다 (ICU는
실행 시점에 플랫폼의 것을 연다). `unicodetools`는 수 GB라 libgrapheme이 읽는 UCD
디렉터리만 sparse로 받는다 — 명령은 [docs/skia-build.md](docs/skia-build.md) 2장에 있다.

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng
scripts\build_skia.ps1 -Configuration Debug   -RustPng
scripts\verify_skia_root.ps1
scripts\pack_skia.ps1 -Configuration Release -Archive
scripts\pack_skia.ps1 -Configuration Debug -Destination build\skia-package-debug -Archive
scripts\probe_features.ps1 -PackageRoot build\skia-package -Configuration Release
```

Release 심볼 자산은 `build_skia.ps1 -DebugInfo`로 따로 세운다 (docs/skia-build.md 6.7).

**Skia 자신은 clang-cl로 컴파일한다.** 소비자는 그대로 MSVC이고, 헤더와 CRT도 여전히
MSVC의 것을 쓴다 — 바뀌는 것은 Skia를 컴파일하는 컴파일러 하나다.

이유는 CPU 래스터 파이프라인의 처리 폭이다. `SkRasterPipeline_opts.h`가 벡터를
clang·gcc의 확장으로만 만들어, MSVC로 세운 Skia는 한 번에 픽셀 **하나**를 처리했다.
clang-cl로 세우면 `SkOpts::Init()`의 실행 시점 판정이 AVX2 갈래(폭 8, 8비트 경로는
16)로 바꿔 끼운다. 4000×7000 이미지의 cubic 축소가 실측에서 800 ms에서 14 ms로
줄었다. 자세한 것과 재는 법은 [docs/skia-build.md](docs/skia-build.md) 5.4에 있다.

**`-RustPng`이 발행하는 갈래다.** luil이 그것을 요구 인자로 못 박았다 —
APNG(움직이는 png)를 읽는 코덱이 rust뿐이기 때문이다. 그쪽은 bazelisk가 필요하고
캐시가 15 GB까지 자라므로 **GitHub Actions의 호스팅 러너(SSD 14 GB)에서는 세울 수
없다.** 그래서 이 저장소는 CI로 발행하지 않고 생산자가 자기 기계에서 빌드해 릴리스를
올린다.

`-RustPng` 없이 세우는 libpng 갈래는 **물러설 자리로만** 남겨 둔다. Skia의 rust
경로는 148~151에서 서지 않았고(152가 고쳤다) 뒷날 다시 막힐 수 있다. 그때 이쪽으로
패키지를 만들고 luil에서 요구 인자 한 줄을 뺀다. 그 갈래의 zip은 이름에
`-libpng`이 붙어 rust 갈래와 구별된다 — 서로 링크 호환되지 않는다.

### Android

같은 스크립트를 **Linux에서** `pwsh`로 돌린다. rust png의 Bazel NDK 도구사슬이 linux
x86_64 호스트에서만 돌기 때문이다 — WSL2면 된다. submodule은 Windows의 셋(D3D12MA·
SPIRV 둘) 대신 `vulkanmemoryallocator`·`freetype`·`expat`을 받는다.

```bash
pwsh scripts/build_skia.ps1 -Target android-arm64 -Configuration Release -RustPng
pwsh scripts/build_skia.ps1 -Target android-arm64 -Configuration Debug   -RustPng
pwsh scripts/verify_skia_root.ps1 -Target android-arm64
pwsh scripts/pack_skia.ps1 -Target android-arm64 -Configuration Release -Archive
pwsh scripts/pack_skia.ps1 -Target android-arm64 -Configuration Debug -Destination build/skia-package-debug -Archive
```

Skia 157을 그대로는 세울 수 없어 패치 셋을 건다 (Bazel이 쓰는 NDK, Rust·crate의 대상
목록, Bazel에 넘기는 플랫폼). 소비자는 `-landroid -llog`로 링크해야 하고, Vulkan 메모리
할당기를 직접 넘겨야 한다. `-Wl,--allow-multiple-definition`은 157 r1부터 필요 없다.
준비와 실측과 소비자의 계약은 [docs/skia-build.md](docs/skia-build.md) 8장에 있다.
`tools/android_probe.cpp`가 기기 위에서 래스터·rust png·시스템 글꼴·Vulkan을 밟아
확인한다 (실기기에서 통과).

### macOS

같은 스크립트를 **Apple Silicon Mac에서** `pwsh`로 돌린다. Xcode(Command Line Tools만으로는
안 된다)가 컴파일하고, rust png의 Bazel mac 도구사슬도 그 Xcode의 SDK를 쓴다.
submodule은 GPU·글꼴의 것이 하나도 들지 않는다 — Metal·CoreText·ICU(`libicucore`)가
모두 시스템의 것이다.

```bash
pwsh scripts/build_skia.ps1 -Target mac-arm64 -Configuration Release -RustPng
pwsh scripts/build_skia.ps1 -Target mac-arm64 -Configuration Debug   -RustPng
pwsh scripts/verify_skia_root.ps1 -Target mac-arm64
pwsh scripts/pack_skia.ps1 -Target mac-arm64 -Configuration Release -Archive
pwsh scripts/pack_skia.ps1 -Target mac-arm64 -Configuration Debug -Destination build/skia-package-debug -Archive
pwsh scripts/probe_features.ps1 -Target mac-arm64 -PackageRoot build/skia-package -Configuration Release
```

배포 하한은 macOS 11이다. rust 갈래에는 패치가 하나 든다 — Skia가 받아 쓰는 lld 22가
macOS 27 SDK의 `.tbd`를 읽지 못해 Bazel이 Xcode의 `ld`로 링크하게 하고, Bazel C++의
하한을 GN과 같은 11로 맞춘다. 소비자는 framework 다섯(`CoreFoundation`·`CoreGraphics`·
`CoreText`·`Metal`·`Foundation`)을 링크하고 `SK_METAL`을 정의한다. 기능 probe가 그 Mac에서
바로 돌아 열한 갈래(Metal 포함)가 Release·Debug 모두 통과했다. 자세한 것은
[docs/skia-build.md](docs/skia-build.md) 9장에 있다.

### iOS

macOS와 같은 Mac에서, Xcode의 iOS 플랫폼을 더해 같은 스크립트를 돌린다. 대상은 둘이다 —
`ios-arm64`(iPhone·iPad 기기)와 `ios-arm64-simulator`. 배포 하한은 iOS 15.0이다.

```bash
pwsh scripts/build_skia.ps1 -Target ios-arm64 -Configuration Release -RustPng
pwsh scripts/build_skia.ps1 -Target ios-arm64 -Configuration Debug   -RustPng
pwsh scripts/verify_skia_root.ps1 -Target ios-arm64
pwsh scripts/pack_skia.ps1 -Target ios-arm64 -Configuration Release -Destination build/skia-package-ios-arm64 -Archive
pwsh scripts/pack_skia.ps1 -Target ios-arm64 -Configuration Debug -Destination build/skia-package-ios-arm64-debug -Archive
```

패치가 셋 더 든다 — arm64e를 빼는 것(Skia는 iOS arm64를 arm64 + arm64e fat으로 세운다),
runtime ICU가 iOS의 `libicucore`도 여는 것, 그리고 rust png를 iOS용으로 세우는 것(Skia 157의
iOS Bazel 도구사슬은 등록조차 되지 않아, mac의 clang 22에 iOS SDK를 물린다. crate lock째 담는다).
mac과 iOS를 한 Skia 트리에서 번갈아 세워도 된다 — 스크립트가 그 빌드가 쓰지 않는 패치를 먼저
뺀다. 소비자가 링크할 framework는 mac과 같은 다섯이다. 기능 probe가 시뮬레이터(iPhone·iPad)에서
열한 갈래 모두 돌았고, 기기용은 링크까지 확인했다. 자세한 것은
[docs/skia-build.md](docs/skia-build.md) 10장에 있다.

발행 절차는 [docs/publishing.md](docs/publishing.md)에 있다.

## 라이선스

이 저장소 자신의 것은 스크립트와 GN args와 패치와 벤치마크 도구뿐이다. 릴리스 자산에
담기는 제3자 구성요소의 고지는 `pack_skia.ps1`이 걷어 패키지의 `NOTICE.md`에 싣는다 —
Skia와 그 external, rust 갈래에서는 crate와 Rust 표준 라이브러리까지 담는다.

담기는 것은 모두 permissive다: BSD-3-Clause(Skia·libwebp·skcms), Apache-2.0(SPIRV-Cross·
Wuffs), MIT(SPIRV-Headers·D3D12MemoryAllocator), IJG + BSD-3(libjpeg-turbo),
PNG Reference Library License v2(libpng), Zlib(zlib), 그리고 rust 갈래의
MIT / Apache-2.0 / 0BSD / Zlib crate들. 상호주의 조항은 없다.

기능별 아카이브가 더하는 것: Old MIT(HarfBuzz), Unicode License V3(ICU — 컴파일한
헤더의 몫이다. 데이터는 싣지 않는다), BSD-2(libavif), Apache-2.0(libgav1),
BSD-3 + 특허 허여(libyuv), ISC(libgrapheme), MIT(Windows·macOS의 Expat). 앱이 실을 고지는 쓰는 기능에 따라
다르다 — 패키지의 `NOTICE.json`이 기능마다 적는다.

macOS·iOS 패키지는 더하는 것이 없다 — GPU·글꼴·ICU가 모두 시스템의 것이다.

Android 패키지에는 넷이 더 들어간다: MIT(Vulkan Memory Allocator·Expat),
Apache-2.0(NDK의 cpu-features), 그리고 FreeType. FreeType은 FTL과 GPLv2 중 하나를
고르는 이중 라이선스이고 이 패키지는 **FTL을 고른다.** FTL은 상호주의가 아니지만
**제품 문서에 FreeType을 밝히라고 요구한다** — 그 의무는 이 패키지로 앱을 내는
쪽이 진다. 권하는 문구는 패키지의 `NOTICE.md` 머리에 있다.
