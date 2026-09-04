# Skia 준비 안내

skia-ui는 Skia를 자동으로 내려받거나 빌드하지 않는다.

사용자가 1회 직접 빌드하고, CMake는 그 산출물을 검사해 연결만 한다.

이미 같은 인자로 빌드해 둔 Skia가 있다면 다시 빌드할 필요 없이 캐시 변수로 그 위치를 가리킨다.

```powershell
cmake --preset vs2026 `
    -DSKIA_UI_SKIA_ROOT=<기존 Skia 트리> `
    -DSKIA_UI_SKIA_BUILD_DEBUG=<Debug 산출물 디렉터리> `
    -DSKIA_UI_SKIA_BUILD_RELEASE=<Release 산출물 디렉터리>
```

## 1. 필요한 것

| 항목 | 비고 |
| --- | --- |
| submodule | `git submodule update --init` 한 번으로 Skia와 external을 모두 받는다 |
| `gn` | Skia 빌드 생성기. 스크립트가 로컬에서 찾는다 |
| `ninja` | 1.13 이상. 스크립트가 로컬에서 찾는다 |
| Python 3 | 3.9 이상. Skia의 GN 스크립트가 사용한다 |
| `bazelisk.exe` | **`-RustPng`을 줄 때만** 필요하다. 기본 구성에는 필요 없다. `.cmd`·`.ps1` launcher는 쓸 수 없다 (5.2) |

`gn`과 `ninja`만 submodule 밖에 있다. 둘은 PATH에 없는 것이 보통이므로 `build_skia.ps1`이 아래 순서로 찾는다. 대개 사용자가 할 일은 없다.

| 순서 | `gn` | `ninja` |
| --- | --- | --- |
| 1 | `-GnPath` 인자 | `-NinjaPath` 인자 |
| 2 | `third_party/skia-tools/gn.exe` | `third_party/skia-tools/ninja.exe` |
| 3 | `third_party/skia/bin/gn.exe` | `third_party/skia/third_party/ninja/ninja.exe` |
| 4 | `third_party/skia/third_party/gn/gn.exe` | `third_party/skia/bin/ninja.exe` |
| 5 | - | Visual Studio 설치본 (`vswhere`로 찾는다) |
| 6 | `PATH` | `PATH` |

3~4는 Skia의 `bin/fetch-gn`·`bin/fetch-ninja`가 두는 자리다. Skia의 `.gitignore`가 그 경로를 모두 무시하므로 submodule이 dirty로 표시되지 않는다. 5는 Visual Studio가 CMake 지원과 함께 설치하는 `ninja`다.

자동 탐색은 1.13 미만의 `ninja`를 건너뛴다. `-NinjaPath`로 직접 준 것은 경고만 하고 그대로 쓴다.

어느 자리에도 없으면 찾아본 자리를 모두 적어 실패한다. 다음 둘 중 하나로 한 번만 채우면 된다.

- 브라우저로 받아 `third_party/skia-tools/`에 둔다. 저장소는 이 디렉터리를 추적하지 않는다.
  - `ninja`: `github.com/ninja-build/ninja`의 releases에서 `ninja-win.zip`
  - `gn`: CIPD 패키지 페이지에서 `gn/gn/windows-amd64` 최신본
- `-FetchTools`를 준다. 없는 것만 Skia의 `bin/fetch-gn`·`bin/fetch-ninja`로 내려받는다. **자동 취득이므로 기본값이 아니다.** 사람이 인자로 지시했을 때만 동작하고, 취득이 통제된 환경에서는 실패한다. 그 환경에서는 위의 브라우저 경로를 쓴다.

## 2. submodule 초기화

기본 구성에 필요한 것은 아홉이다. 앞의 넷은 Skia와 렌더러가, 뒤의 다섯은 이미지 코덱이 쓴다.

```powershell
git submodule update --init third_party/skia
git submodule update --init third_party/skia-externals/d3d12allocator
git submodule update --init third_party/skia-externals/spirv-cross
git submodule update --init third_party/skia-externals/spirv-headers

git submodule update --init third_party/skia-externals/libjpeg-turbo
git submodule update --init third_party/skia-externals/libwebp
git submodule update --init third_party/skia-externals/wuffs
git submodule update --init third_party/skia-externals/libpng
git submodule update --init third_party/skia-externals/zlib
```

`libpng`과 `zlib`은 기본(libpng) png 구성만 쓴다. `-RustPng`으로 빌드한다면 둘은
필요하지 않다 (5.2).

commit은 Skia의 `DEPS`에 적힌 것과 같게 고정한다. `libjpeg-turbo`·`libwebp`·`zlib`은
GitHub 대응물이 Skia의 `BUILD.gn`이 기대하는 구조와 달라(chromium 포크가 `jconfig.h`
같은 생성 파일을 함께 담는다) `chromium.googlesource.com`을, `libpng`은
`skia.googlesource.com`을 그대로 쓴다. `wuffs`만 GitHub 원본
(`google/wuffs-mirror-release-c`)이 같은 commit을 담고 있어 그쪽을 본다.

test를 빌드할 때만 Catch2가 추가로 필요하다. 라이브러리만 빌드한다면 초기화하지 않아도 된다.

```powershell
git submodule update --init third_party/catch2
```

## 3. 빌드

```powershell
scripts\build_skia.ps1 -Configuration Release
scripts\build_skia.ps1 -Configuration Debug
```

이미 준비해 둔 Skia 트리가 다른 자리에 있으면 `-SkiaRoot`로 가리킨다. CMake 쪽의
`SKIA_UI_SKIA_ROOT`와 짝이 되는 손잡이다.

```powershell
scripts\build_skia.ps1 -Configuration Release -SkiaRoot D:\src\skia
```

이 스크립트는 external 배치, 패치 적용, `gn gen`, `ninja`를 순서대로 수행한다. **CMake와 CTest는 이 스크립트를 호출하지 않는다.** 빌드 체계가 자동으로 취득하는 경로를 만들지 않기 위한 구분이다.

`gn`과 `ninja`는 1장의 순서로 찾는다. 어느 자리에도 없으면 한 번 받거나 경로를 직접 준다.

```powershell
scripts\build_skia.ps1 -Configuration Release -FetchTools
scripts\build_skia.ps1 -Configuration Release -GnPath D:\tools\gn.exe -NinjaPath D:\tools\ninja.exe
```

`-FetchTools`는 없는 것만 받는다. 받은 자리는 다음 실행에서 그대로 찾으므로 처음 한 번이면 된다.

산출물은 `third_party/skia/out/skia-ui-release`와 `third_party/skia/out/skia-ui-debug`에 생긴다. CMake는 그 configure가 실제로 빌드하는 구성에 필요한 쪽만 요구한다 — Visual Studio generator는 기본 구성 목록에 Debug와 Release가 모두 있어 둘 다 필요하고, 단일 구성(Ninja 등)이나 `CMAKE_CONFIGURATION_TYPES`를 줄인 빌드는 그 구성의 것 하나면 된다.

빌드가 끝나면 검사할 수 있다.

```powershell
scripts\verify_skia_root.ps1
```

## 4. 스크립트가 하는 일

손으로 수행하거나 다른 환경에 옮길 때를 위해 내용을 남긴다.

### 4.1 external 배치

Skia는 `third_party/externals/<이름>`에서 external을 찾는다. Skia submodule을 수정하지 않기 위해 junction으로 연결한다.

```text
third_party/skia/third_party/externals/d3d12allocator  ->  third_party/skia-externals/d3d12allocator
third_party/skia/third_party/externals/spirv-cross     ->  third_party/skia-externals/spirv-cross
third_party/skia/third_party/externals/spirv-headers   ->  third_party/skia-externals/spirv-headers
third_party/skia/third_party/externals/libjpeg-turbo   ->  third_party/skia-externals/libjpeg-turbo
third_party/skia/third_party/externals/libwebp         ->  third_party/skia-externals/libwebp
third_party/skia/third_party/externals/wuffs           ->  third_party/skia-externals/wuffs
third_party/skia/third_party/externals/libpng          ->  third_party/skia-externals/libpng
third_party/skia/third_party/externals/zlib            ->  third_party/skia-externals/zlib
```

무엇이 필요한지는 GN args가 정한다. 스크립트가 인자 파일을 읽어 켜진 코덱의
external만 요구하므로, `-RustPng` 구성에서는 `libpng`·`zlib`을 묻지 않는다.

Skia 저장소의 `.gitignore`가 `third_party/externals`를 무시하므로 submodule이 dirty로 표시되지 않는다. junction을 만들 수 없는 환경은 `-CopyExternals`로 복사한다.

`tools/git-sync-deps`는 사용하지 않는다. DEPS의 나머지 external은 아래 GN args에서 전부 꺼져 있어 필요하지 않다.

### 4.2 패치

**기본 구성에는 패치가 없다.** Skia 152는 손대지 않고 그대로 선다.

148이 요구하던 Direct3D `operator==` 패치는 152에서 필요 없어졌다 — `GrD3DBackendSurface.cpp`가 더 이상 가드 밖에서 그것을 부르지 않는다. Debug로 실측했다(그 실패는 `SK_DEBUG`가 켜진 구성에서만 드러난다).

`-RustPng` 구성만 두 개가 필요하다.

```powershell
git -C third_party\skia apply ..\patches\skia-152-bazel-rust-windows-outputs.patch
git -C third_party\skia apply ..\patches\skia-152-bazel-rust-windows-debug-crt.patch
```

Windows bazel은 `rust/png/ffi_rs.lib`과 `…/cxx_cc.lib`(MSVC 이름)을 내는데 GN의 복사 단계는 `libffi_rs.a`·`libcxx_cc.a`(Linux·mac 이름)를 찾는다. **bazel이 성공한 뒤** 복사에서 죽으므로 원인이 멀어 보인다. 출처 경로 두 줄만 바꾸고 목적지 이름은 그대로 두어, 이 저장소의 산출물 목록(`SKIA_UI_SKIA_RUST_PNG_COMPONENTS`)은 바뀌지 않는다.

두 번째 패치는 Debug의 Bazel C++ bridge에도 `_DEBUG`와
`_ITERATOR_DEBUG_LEVEL=2`를 넘긴다. Skia의 Windows hermetic Clang toolchain은
`--compilation_mode=dbg`에서도 C++ CRT ABI를 `/MT`로 고정하므로, 이 인자가 없으면
Rust archive만 `MT_StaticRelease`·iterator level 0으로 남고 `/MTd` 소비자 링크가
LNK2038로 실패한다.

패치를 적용하면 Skia 작업 트리가 수정되므로 `git submodule status`에 `+`가 표시된다. 정상이다.

### 4.3 `gn gen`과 `ninja`

```powershell
gn gen third_party\skia\out\skia-ui-release `
    --script-executable=<python 경로> `
    --args="<third_party\skia-args\skia-ui-release.gn 내용을 한 줄로>"
ninja -C third_party\skia\out\skia-ui-release skia
```

`--script-executable`이 필요한 이유는 Skia의 `.gn`이 `script_executable = "python3"`로 되어 있는데 Windows의 `python3.exe`가 Microsoft Store 스텁인 경우가 많기 때문이다.

## 5. GN args에서 주의할 점

인자는 **두 파일이 한 벌**이다. 기본 파일(`skia-ui-release.gn`·`skia-ui-debug.gn`·
`skia-ui-release-text.gn`)에는 png와 zlib이 없고, `png-libpng.gn`이나 `png-rust.gn`
중 하나를 뒤에 이어 붙여 완성한다 (5.2). 스크립트가 이어 붙이며, 한 변수에 두 번
대입하면 gn이 거부하므로 겹치는 줄은 어느 쪽에도 없다.

스크립트는 이어 붙인 글에서 **주석을 지운 뒤** 한 줄로 만들어 `--args=`에 넘긴다.
한 줄이 되고 나면 `#` 뒤의 모든 것이 주석이 되어 그 아래 인자가 통째로 사라지는데,
사라진 인자는 오류가 아니라 **Skia의 기본값**이 된다 — 코덱은 기본이 켜짐이고
`skia_use_system_*`도 Release에서 켜짐이라, 증상이 "libpng의 `png.h`를 찾지 못한다"
같은 엉뚱한 자리에서 난다 (실측).

실측에서 걸린 항목만 기록한다.

| 항목 | 이유 |
| --- | --- |
| `skia_use_system_harfbuzz = false`<br>`skia_use_system_icu = false`<br>`skia_use_system_libjpeg_turbo = false`<br>`skia_use_system_libwebp = false`<br>`skia_use_system_libpng = false`<br>`skia_use_system_zlib = false` | 기본값이 `is_official_build && !is_canvaskit`(zlib은 `is_official_build`)이라 Release에서 자동으로 켜지고, 있지도 않은 시스템 라이브러리를 참조해 실패한다. 코덱 쪽은 include 경로가 통째로 비어 `png.h`·`jpeglib.h`를 못 찾는 컴파일 오류로 드러난다 |
| `skia_use_dng_sdk = false`<br>`skia_use_piex = false` | `skia_use_dng_sdk`의 기본값이 `!is_wasm && skia_use_libjpeg_turbo_decode && skia_use_zlib`이다. jpeg를 켠 뒤로는 명시하지 않으면 저절로 켜져 `dng_sdk`·`piex` external을 더 끌어온다 |
| `skia_use_jpeg_gainmaps = false` | 기본값이 `is_skia_dev_build`라 Debug 구성에서 켜지고, `optional("xml")`을 통해 expat external을 끌어온다 |
| `extra_cflags = [ "/MT" ]` / `[ "/MTd" ]` | 라이브러리의 `CMAKE_MSVC_RUNTIME_LIBRARY`와 맞춰야 한다. 어긋나면 LNK2038로 드러난다 |
| `skia_enable_fontmgr_win` | 명시하지 않는다. Windows 기본값 `true`이며 `SkFontMgr_New_DirectWrite`가 여기에 의존한다 |

코덱을 켜면 산출물도 늘어난다. `CMakeLists.txt`의 `SKIA_UI_SKIA_COMPONENTS`가 그
목록이고 `scripts/verify_skia_root.ps1`이 같은 목록을 검사한다.

| 산출물 | 무엇인가 |
| --- | --- |
| `libjpeg.lib`·`libjpeg12.lib`·`libjpeg16.lib` | libjpeg-turbo 3.x가 정밀도(8·12·16bit)별로 같은 소스를 다시 컴파일해 셋이 난다 |
| `libwebp.lib`·`libwebp_sse41.lib` | SSE4.1 조각이 따로 난다 |
| `wuffs.lib` | gif 디코더다 |
| `libpng.lib`·`zlib.lib` | 기본(libpng) png 구성만 낸다 |
| `librust_png_ffi_rs.a`·`libcxx_cc.a` | `-RustPng` 구성만 낸다. bazel 산출물이라 확장자가 `.a`다 |

### 5.1 toolset과 Skia 빌드의 관계

Skia는 `build_skia.ps1`을 실행한 셸의 MSVC로 빌드된다. 한 번 빌드한 산출물을 두 generator(VS2022·VS2026)가 공유한다.

MSVC는 v14x 계열 안에서 이진 호환을 보장하므로 이것이 성립한다. 정적 CRT를 양쪽 모두 `/MT`·`/MTd`로 맞추는 것이 전제다. MSVC의 주 버전이 바뀌어 이진 호환이 끊기면 Skia를 다시 빌드한다.

### 5.2 png 코덱은 둘 중 하나다

Skia에는 png 디코더가 둘 있고 **동시에 켤 수 없다.** 어느 쪽으로 세웠는지는
`args.gn`에 남고, CMake가 그것을 읽어 링크할 산출물과 APNG 지원 여부를 정한다.

| | 기본 (`png-libpng.gn`) | `-RustPng` (`png-rust.gn`) |
| --- | --- | --- |
| 추가 도구 | 없다 | `bazelisk` |
| external | `libpng`·`zlib` | 없다 (bazel이 crate를 받는다) |
| APNG (움직이는 png) | **읽지 못한다.** 첫 frame만 나온다 | 읽는다 |
| 산출물 | `libpng.lib`·`zlib.lib` | `librust_png_ffi_rs.a`·`libcxx_cc.a` |

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng
```

- **cargo가 아니라 Bazel이다.** Skia 148의 `BUILD.gn`은
  `action("rust_all_ffi_bazel_build")`에서 `gn/bazel_build.py`를 부르고, 그 script가
  `bazelisk build //rust/png:ffi_rs`를 실행한다. rust 도구사슬은 bazel이 `rules_rust`로
  스스로 받으므로 rustup을 따로 깔지 않아도 된다. 대신 **bazel이 crate를 받을 수 있는
  네트워크**가 필요하다. 스크립트는 시작하기 전에 `bazelisk.exe`를 찾고, 없으면 설치
  방법을 적어 실패한다 — ninja가 한참 돌다가 죽는 것보다 낫다.
- **`bazelisk.exe`여야 한다. launcher로는 안 된다** (실측).
  `bazel_build.py`가 부르는 방식이 `subprocess.run(["bazelisk", ...])`, 곧
  CreateProcess다. `npm i -g @bazel/bazelisk`는 `bazelisk.cmd`·`bazelisk.ps1`만 두고
  실제 실행 파일은 `node_modules/@bazel/bazelisk/bazelisk-windows_amd64.exe`라는
  다른 이름으로 두는데, CreateProcess는 셸의 PATHEXT를 보지 않아 그 launcher를 찾지
  못한다 — 증상이 ninja 한복판의 `FileNotFoundError: [WinError 2]`다.
  가장 쉬운 길은 `gn`·`ninja`와 같은 자리에 두는 것이다.

  ```powershell
  copy node_modules\@bazel\bazelisk\bazelisk-windows_amd64.exe third_party\skia-tools\bazelisk.exe
  ```

  스크립트는 `third_party/skia-tools/bazelisk.exe`를 먼저 보고, 없으면 PATH에서
  **확장자가 `.exe`인 것만** 고른다. 찾은 자리는 ninja를 부르기 전에 PATH 앞에 세운다
  (`bazel_build.py`가 이름만으로 부르기 때문이다).
- **APNG를 읽는 코덱은 이쪽뿐이다.** `SkPngCodec.cpp`가 스스로 적어 두었다
  ("`SkPngCodec` doesn't support APNG"). gif와 webp의 애니메이션은 두 구성 모두에서
  된다 — 그쪽은 wuffs와 libwebp가 한다.
- **Debug와 Release는 같은 쪽으로 세운다.** 한쪽만 rust로 빌드하면 같은 실행 파일이
  구성에 따라 APNG를 읽거나 못 읽게 되므로 configure가 거른다.
- **알려진 구멍: rust crate의 라이선스 고지가 비어 있다.** 실행 파일에 넣는 제3자
  고지는 Skia 트리의 `third_party/externals/*`에서 원문을 읽는데
  (`cmake/generate_notices.cmake`), rust crate는 bazel이 자기 캐시에 받아 그 자리에
  없다. `-RustPng` 구성으로 배포한다면 `png`·`cxx` crate의 고지를 손으로 채워야 한다.
### 5.3 `-RustPng`이 요구하는 것 (2026-09-03 실측)

이 저장소가 고정한 Skia(152)에서 rust png는 **선다.** APNG가 두 장으로 디코드되고
(`frame_count() == 2`, 표시 시간 120 ms) skia-ui의 test가 전부 통과하는 것까지
확인했다. 필요한 것은 넷이다.

1. **`bazelisk.exe`** (1장). launcher로는 안 된다 — 5.2에 이유가 있다.
2. **`skia-152-bazel-rust-windows-outputs.patch`** — 스크립트가 `-RustPng`일 때만
   적용한다 (4.2).
3. **`skia-152-bazel-rust-windows-debug-crt.patch`** — Debug에서 Bazel C++ bridge를
   `/MTd` ABI(iterator level 2)로 맞춘다.
4. **`ws2_32`·`userenv`·`ntdll`** — `SKIA_UI_SKIA_RUST_PNG_SYSTEM_LIBRARIES`가 rust
   갈래에서만 링크한다. rustc는 std가 쓰는 시스템 라이브러리를 `#[link]` 지시로
   심는데, bazel이 낸 정적 아카이브를 CMake가 직접 링크하면 그 지시가 링커에 닿지
   않는다. 실측한 미해결 기호 열여덟 개가 정확히 이 셋으로 떨어진다 — 소켓
   열다섯이 ws2_32, `GetUserProfileDirectoryW`가 userenv,
   `NtReadFile`·`RtlNtStatusToDosError`가 ntdll이다.

bazel은 rust 도구사슬과 crate를 스스로 받는다(rustup은 필요 없다). 대신 **네트워크와
디스크**가 든다 — hermetic clang과 Windows SDK 묶음까지 받아 캐시가 수십 GB까지
자란다. 쓰지 않을 구성이면 `bazel clean --expunge`로 통째로 비워도 된다.

#### 148에서는 왜 서지 않았는가 (기록)

버전을 되돌릴 일이 생기면 같은 자리를 두 번 파지 않도록 남긴다. 148의 Bazel Windows
toolchain은 Bzlmod 전환이 덜 되어 **길 둘이 모두 막혔다.**

- **hermetic clang**: `.bazelrc`가 늘 등록하는 `//toolchain:clang_windows_x64_toolchain`이
  쓰는 `@clang_windows_amd64`가 `MODULE.bazel`에 주석으로만 있었다. 되살려도
  `windows_toolchain_config.bzl`이 `external/clang_windows_amd64`를 문자열로 박아
  Bzlmod가 만드는 실제 이름과 어긋나 모든 컴파일이 죽었다.
- **MSVC**: `bazel/user/buildrc`(Skia가 `try-import`로 연 자리)에서 platform과 자동
  감지를 되돌리면 `@crates//:cxx_cc`까지 컴파일되지만, `//rust/png:ffi_rs`가 Skia
  자신의 C++를 끌어오고 Skia의 Bazel copts가 clang 전용이라 `cl.exe`가 거부했다.

152가 앞엣것을 고쳤다 — `MODULE.bazel`이 저장소를 선언하고,
`windows_toolchain_config.bzl`이 경로를 `label.repo_name`으로 분석 시점에 구한다.
149~151에는 둘 다 없다.

#### Debug CRT

rust 갈래의 Debug도 `/MTd` 소비자와 실제 링크했다. Bazel의 `dbg`는 최적화·디버그
정보 구성을 고를 뿐, 이 Skia 버전의 Windows hermetic Clang이 고정한 `/MT` ABI를
바꾸지 않는다. 두 번째 패치가 C++ bridge와 `cxx` archive에 `_DEBUG`와 iterator
level 2를 명시하고, `verify_skia_root.ps1`이 두 archive의 COFF 지시문을 검사한다.

## 6. 텍스트 처리 구성 (선택)

현재 skia-ui는 `drawSimpleText`와 `measureText`만 사용해 shaping engine이 필요하지 않다. `SkShaper`나 `SkParagraph`를 도입할 때 이 구성을 쓴다.

`third_party/skia-args/skia-ui-release-text.gn`이 `skia_use_harfbuzz = true`와 `skia_use_libgrapheme = true`를 켠 변형이다. submodule 셋을 추가로 받는다.

```powershell
git submodule update --init third_party/skia-externals/harfbuzz
git submodule update --init third_party/skia-externals/libgrapheme
git submodule update --init third_party/skia-externals/unicodetools
git submodule update --init third_party/skia-externals/icu
```

full ICU(`skia_use_icu = true`)는 쓰지 않는다. Skia의 번들 ICU는 Windows에서만 `icudtl.dat`를 실행 파일 옆에서 런타임에 읽어, 단일 `.exe` 원칙과 충돌한다. `libgrapheme` backend는 데이터 파일을 만들지 않는다.

다만 libgrapheme backend도 BiDi는 ICU **소스** 20여 개 파일을 컴파일하므로 `icu` submodule은 필요하다. 데이터 파일은 쓰지 않는다.

`unicodetools`는 libgrapheme의 표 생성에만 쓰이며 작업 트리가 3.1 GB다. 실제로 읽는 것은 `unicodetools/data/ucd/15.0.0`(52 MB)뿐이므로 sparse-checkout을 권한다.

```powershell
git -C third_party\skia-externals\unicodetools sparse-checkout set unicodetools/data/ucd/15.0.0
```

`icu`만 GitHub 대응물이 없어 `chromium.googlesource.com/chromium/deps/icu`를 원격으로 쓴다. 접근이 막히면 브라우저로 `+archive/<commit>.tar.gz`를 받아 풀거나, GN 인자인 `skia_icu_bidi_third_party_dir`을 `github.com/unicode-org/icu`를 가리키는 자체 `BUILD.gn`으로 바꾼다.

## 7. Skia 버전 갱신

버전 갱신은 기능 변경과 분리한다. 한 변경에서 다음을 함께 갱신한다.

- `third_party/skia` submodule commit
- external submodule commit (Skia의 `DEPS`와 대조)
- `third_party/patches/`의 패치가 여전히 필요하고 적용되는지
- `third_party/skia-args/`의 GN args
- `scripts/verify_skia_root.ps1`의 `$minimum_milestone`

갱신 후에는 configure, 빌드, 전체 CTest, 한국어와 Codicon 렌더링 육안 검증을 모두 수행한다.

### 7.1 실측 — 148 → 152 (2026-09-03)

다음 갱신에서 무엇을 보게 되는지의 본보기로 남긴다. 이 갱신은 **놀랄 만큼 조용했다.**

| 볼 자리 | 실제 |
| --- | --- |
| external commit | 열둘 중 **둘만** 바뀌었다. 기본 구성이 드는 여덟에서는 `spirv-headers` 하나(`6dd7ba99…` → `29981f65…`), text 구성 전용에서는 `icu` 하나(`364118a1…` → `d578f2e8…`)다. 나머지 열은 148과 152의 `DEPS`가 같은 commit을 가리킨다 |
| GN args | 우리가 쓰는 인자 전부가 이름도 기본값도 그대로다. `skia_use_system_*`의 함정도 그대로다 |
| 산출물 | 링크하는 `.lib` 목록이 그대로다 |
| 공개 API | 우리가 쓰는 것(`SkCodec`·`SkEncodedOrigin`·`SkImage`·Ganesh D3D)이 그대로 컴파일된다 |
| 패치 | **하나 없어지고 하나 생겼다.** Direct3D `operator==`는 필요 없어졌고, rust png의 Windows 산출물 이름이 새로 필요하다 (4.2) |

갱신하며 얻은 것은 rust png다 — 148에서는 어떤 길로도 서지 않았다 (5.3).

**`icu`는 핀만 맞추고 빌드하지 않았다.** text 구성(6장)은 이 저장소가 아직 쓰지 않아
submodule이 초기화되어 있지 않다. 그래도 맞춰 두는 이유는 m152의
`third_party/icu/icu.gni`가 `common/fixedstring.cpp`·`.h`를 새로 요구해 **옛 핀으로는
그 구성이 깨지기** 때문이다 — 쓰기 시작하는 날 원인을 다시 찾지 않게 한다.
