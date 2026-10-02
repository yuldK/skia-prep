# Skia 준비 안내

luil은 Skia를 자동으로 내려받거나 빌드하지 않는다.

1~7장은 Windows 대상(`win-x64`)의 것이다. Android 대상(`android-arm64`)은 Linux에서
세우고, 다른 것만 8장에 모았다.

사용자가 1회 직접 빌드하고, CMake는 그 산출물을 검사해 연결만 한다.

이미 같은 인자로 빌드해 둔 Skia가 있다면 다시 빌드할 필요 없이 캐시 변수로 그 위치를 가리킨다.

```powershell
cmake --preset vs2026 `
    -DLUIL_SKIA_ROOT=<기존 Skia 트리> `
    -DLUIL_SKIA_BUILD_DEBUG=<Debug 산출물 디렉터리> `
    -DLUIL_SKIA_BUILD_RELEASE=<Release 산출물 디렉터리>
```

## 1. 필요한 것

| 항목 | 비고 |
| --- | --- |
| submodule | `git submodule update --init` 한 번으로 Skia와 external을 모두 받는다 |
| `gn` | Skia 빌드 생성기. 스크립트가 로컬에서 찾는다 |
| `ninja` | 1.13 이상. 스크립트가 로컬에서 찾는다 |
| Python 3 | 3.9 이상. Skia의 GN 스크립트가 사용한다 |
| `clang-cl` | **Skia를 컴파일하는 것이 이것이다** (5.4). Visual Studio의 "C++ Clang tools for Windows" 구성 요소면 된다. 스크립트가 로컬에서 찾는다 |
| MSVC | 헤더와 CRT는 여전히 MSVC의 것을 쓴다. clang-cl이 `-imsvc`로 읽는다 (5.4) |
| `bazelisk.exe` | **`-RustPng`을 줄 때만** 필요하다. 기본 구성에는 필요 없다. `.cmd`·`.ps1` launcher는 쓸 수 없다 (5.2) |

`clang-cl`을 찾는 순서는 아래와 같다. Visual Studio에 Clang 구성 요소가 깔려 있으면
대개 사용자가 할 일은 없다.

| 순서 | 자리 |
| --- | --- |
| 1 | `-ClangPath` 인자 |
| 2 | `third_party/skia-tools/llvm` |
| 3 | `gn/find_msvc.py`가 고른 VC 안의 `Tools/Llvm/x64` |
| 4 | 다른 Visual Studio 설치본의 같은 자리 (`vswhere`로 찾는다) |
| 5 | `Program Files/LLVM` |
| 6 | `PATH`의 `clang-cl.exe`에서 두 단계 올라간 자리 |

3이 먼저인 것이 중요하다. clang-cl은 자기 표준 라이브러리를 들고 오지 않고 MSVC의
헤더를 읽으므로, **Skia가 컴파일에 쓰는 MSVC와 같은 설치본의 clang**을 고르면 헤더와
컴파일러가 어긋날 자리가 없다.

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

Skia 자신은 **clang-cl로 컴파일된다** (5.4). 헤더와 CRT는 MSVC의 것을 그대로 쓰므로
소비자 쪽은 아무것도 바뀌지 않는다. MSVC로 세우려면 `-Toolchain msvc`를 준다. 그쪽은
CPU 래스터 파이프라인이 폭 1의 scalar 경로로 서므로, 견주어 볼 때가 아니면 쓰지
않는다.

두 도구사슬의 산출물을 나란히 두려면 `-OutputSuffix`로 자리를 가른다. `bench_skia.ps1`이
받는 것도 같은 값이다.

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng -Toolchain msvc -OutputSuffix '-msvc'
scripts\bench_skia.ps1 -Configuration Release -Baseline '-msvc' -Candidate ''
```

이미 준비해 둔 Skia 트리가 다른 자리에 있으면 `-SkiaRoot`로 가리킨다. CMake 쪽의
`LUIL_SKIA_ROOT`와 짝이 되는 손잡이다.

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

Skia 저장소의 `.gitignore`가 `third_party/externals`를 무시하므로 submodule이 dirty로 표시되지 않는다. junction을 만들 수 없는 환경은 `-CopyExternals`로 복사한다. Linux(Android 대상)에서는 junction 대신 symlink를 놓는다.

`tools/git-sync-deps`는 사용하지 않는다. DEPS의 나머지 external은 아래 GN args에서 전부 꺼져 있어 필요하지 않다.

### 4.2 패치

**기본 구성에는 패치가 없다.** Skia 152는 손대지 않고 그대로 선다.

148이 요구하던 Direct3D `operator==` 패치는 152에서 필요 없어졌다 — `GrD3DBackendSurface.cpp`가 더 이상 가드 밖에서 그것을 부르지 않는다. Debug로 실측했다(그 실패는 `SK_DEBUG`가 켜진 구성에서만 드러난다).

`-RustPng` 구성만 두 개가 필요하다.

```powershell
git -C third_party\skia apply ..\patches\skia-152-bazel-rust-windows-outputs.patch
git -C third_party\skia apply ..\patches\skia-152-bazel-rust-windows-debug-crt.patch
```

Windows bazel은 `rust/png/ffi_rs.lib`과 `…/cxx_cc.lib`(MSVC 이름)을 내는데 GN의 복사 단계는 `libffi_rs.a`·`libcxx_cc.a`(Linux·mac 이름)를 찾는다. **bazel이 성공한 뒤** 복사에서 죽으므로 원인이 멀어 보인다. 출처 경로 두 줄만 바꾸고 목적지 이름은 그대로 두어, 소비자의 산출물 목록(luil의 `LUIL_SKIA_COMPONENTS`)은 바뀌지 않는다.

두 번째 패치는 Debug의 Bazel C++ bridge에도 `_DEBUG`와
`_ITERATOR_DEBUG_LEVEL=2`를 넘긴다. Skia의 Windows hermetic Clang toolchain은
`--compilation_mode=dbg`에서도 C++ CRT ABI를 `/MT`로 고정하므로, 이 인자가 없으면
Rust archive만 `MT_StaticRelease`·iterator level 0으로 남고 `/MTd` 소비자 링크가
LNK2038로 실패한다.

패치를 적용하면 Skia 작업 트리가 수정되므로 `git submodule status`에 `+`가 표시된다. 정상이다.

`MODULE.bazel.lock`도 함께 수정된 것으로 보인다. **이것은 패치와 무관하고 되돌릴
필요도 없다.** bazel이 입력 파일의 해시를 lock에 적어 두는데, `bazel/external/cxx/
BUILD.bazel.skia` 같은 파일이 Windows 체크아웃에서 CRLF로 놓이기 때문에 upstream이
LF로 계산해 둔 값과 어긋난다. 줄바꿈 하나의 문제이고, 이 저장소가 고정하는 것은
submodule의 commit이지 그 작업 트리가 아니다.

### 4.3 `gn gen`과 `ninja`

```powershell
gn gen third_party\skia\out\skia-ui-release `
    --script-executable=<python 경로> `
    --args="<third_party\skia-args\skia-ui-release.gn 내용을 한 줄로> clang_win=\"<LLVM 루트>\""
ninja -C third_party\skia\out\skia-ui-release skia
```

`clang_win` 한 줄이 Windows 도구사슬을 통째로 바꾼다 — `cl.exe`가 `clang-cl.exe`로,
`lib.exe`·`link.exe`가 `lld-link.exe`로 간다 (`gn/toolchain/BUILD.gn`). 짝이 되는
`clang_win_version`은 `$clang_win/lib/clang`의 최신 디렉터리에서 GN이 스스로 구하므로
주지 않는다. 인자 파일이 아니라 스크립트가 이 한 줄을 붙이는 이유는 값이 **이 기계의
경로**이기 때문이다. GN 문자열에서 역슬래시가 이스케이프 문자이므로 슬래시로 바꿔
넘긴다.

`ninja`가 끝나면 스크립트가 `toolchain.json`을 산출 디렉터리에 쓴다 (5.4).

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
| `extra_cflags = [ "/MT" ]` / `[ "/MTd" ]` | 라이브러리의 `CMAKE_MSVC_RUNTIME_LIBRARY`와 맞춰야 한다. 어긋나면 LNK2038로 드러난다. clang-cl도 같은 스위치를 받는다 |
| `skia_enable_fontmgr_win` | 명시하지 않는다. Windows 기본값 `true`이며 `SkFontMgr_New_DirectWrite`가 여기에 의존한다 |
| `is_trivial_abi = false` | **clang으로 세우는 동안의 ABI 계약이다** (5.4). MSVC에서는 값이 무엇이든 무해했다 |
| `skia_use_partition_alloc = false` | 기본값이 `is_clang`이다. 도구사슬을 바꾸는 것만으로 켜져 `partition_alloc` external을 새로 요구하고 (없으면 `gn gen`이 거기서 죽는다), Skia 안의 `raw_ptr`을 noop에서 실물로 바꾼다 (실측) |

코덱을 켜면 산출물도 늘어난다. luil `CMakeLists.txt`의 `LUIL_SKIA_COMPONENTS`가 그
목록이고 `scripts/verify_skia_root.ps1`이 같은 목록을 검사한다.

| 산출물 | 무엇인가 |
| --- | --- |
| `libjpeg.lib`·`libjpeg12.lib`·`libjpeg16.lib` | libjpeg-turbo 3.x가 정밀도(8·12·16bit)별로 같은 소스를 다시 컴파일해 셋이 난다 |
| `libwebp.lib`·`libwebp_sse41.lib` | SSE4.1 조각이 따로 난다 |
| `wuffs.lib` | gif 디코더다 |
| `libpng.lib`·`zlib.lib` | 기본(libpng) png 구성만 낸다 |
| `librust_png_ffi_rs.a`·`libcxx_cc.a` | `-RustPng` 구성만 낸다. bazel 산출물이라 확장자가 `.a`다 |

### 5.1 toolset과 Skia 빌드의 관계

Skia를 컴파일하는 것은 **clang-cl**이지만, 헤더와 CRT와 Windows SDK는 여전히 MSVC의
것이다 (5.4). 한 번 빌드한 산출물을 두 generator(VS2022·VS2026)가 공유한다.

MSVC는 v14x 계열 안에서 이진 호환을 보장하므로 이것이 성립한다. 정적 CRT를 양쪽 모두
`/MT`·`/MTd`로 맞추는 것이 전제다. MSVC의 주 버전이 바뀌어 이진 호환이 끊기면 Skia를
다시 빌드한다.

실측한 조합을 적어 둔다 (2026-09-11). Skia는 MSVC 14.44의 헤더로 컴파일했고,
그것에 링크한 소비자는 MSVC 14.51이었다 — v14x 안의 이진 호환이 실제로 성립하는 것을
`bench_skia.ps1`이 링크와 실행으로 확인했다.

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
(`frame_count() == 2`, 표시 시간 120 ms) 당시 소비자였던 skia-ui의 test가 전부 통과하는 것까지
확인했다. 필요한 것은 넷이다.

1. **`bazelisk.exe`** (1장). launcher로는 안 된다 — 5.2에 이유가 있다.
2. **`skia-152-bazel-rust-windows-outputs.patch`** — 스크립트가 `-RustPng`일 때만
   적용한다 (4.2).
3. **`skia-152-bazel-rust-windows-debug-crt.patch`** — Debug에서 Bazel C++ bridge를
   `/MTd` ABI(iterator level 2)로 맞춘다.
4. **`ws2_32`·`userenv`·`ntdll`** — `LUIL_SKIA_RUST_PNG_SYSTEM_LIBRARIES`가 rust
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

### 5.4 도구사슬은 clang-cl이다 (2026-09-11)

**Skia 자신은 clang-cl로 컴파일한다. 소비자는 그대로 MSVC다.**

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng                    # clang-cl (기본)
scripts\build_skia.ps1 -Configuration Release -RustPng -Toolchain msvc    # 견줄 때만
```

#### 왜인가 — 처리 폭이 1이었다

Skia의 CPU 래스터 파이프라인(`SkRasterPipeline`)은 한 번에 여러 픽셀을 처리하도록
쓰여 있다. 그 "여러"를 만드는 벡터 형이 clang과 gcc의 확장이다.

```cpp
// src/opts/SkRasterPipeline_opts.h
#if defined(__clang__)
    template <int N, typename T> using Vec = T __attribute__((ext_vector_type(N)));
#elif defined(__GNUC__)
    ...
#endif

#if ...
#elif !defined(__clang__) && !defined(__GNUC__)
    #define SKRP_CPU_SCALAR
```

**둘 중 어느 것도 아니면 첫 판정에서 `SKRP_CPU_SCALAR`로 떨어진다.** MSVC로 세운
Skia는 여기 걸려 한 번에 픽셀 하나를 처리했다. `SkOpts::Init()`의 실행 시점 판정도
소용이 없다 — AVX2용으로 따로 컴파일되는 `SkOpts_ml3.cpp`(`/arch:AVX2`)조차 같은
판정에 걸려 scalar로 서기 때문이다. 게다가 그 판정에 걸리면 8비트 고정소수 경로
(`lowp`)는 **아예 만들어지지 않는다.** Skia가 그렇게 적어 두었다:

> We don't bother generating the lowp stages if we are: ... in scalar mode
> (MSVC, old clang, etc...)

clang-cl로 세우면 기본이 SSE2(폭 4)이고, `SkOpts::Init()`이 CPU를 보고 AVX2를
지원하면 `ml3` 갈래(폭 8, `lowp`는 16)로 바꿔 끼운다. 실측한 값이다.

| | MSVC | clang-cl |
| --- | --- | --- |
| `raster_pipeline_highp_stride` | 1 | 8 |
| `raster_pipeline_lowp_stride` | 1 | 16 |

시간은 아래와 같다 (Release, i9-13900KF의 P코어 하나에 묶어 5회 × 5반복 중 최소값,
`bench_skia.ps1`). 맞댄 두 산출물은 **`args.gn`이 `clang_win` 한 줄만 다르다** —
같은 Skia commit, 같은 인자, 같은 MSVC 헤더다.

| 재는 것 | MSVC | clang-cl | |
| --- | ---: | ---: | ---: |
| 4000×7000 → 1000×1750 cubic | 799.8 ms | 13.6 ms | **58.9배** |
| 같은 것, 표면 할당까지 포함 | 838.1 ms | 14.1 ms | 59.4배 |
| 4000×7000 → 500×875 cubic | 210.7 ms | 3.9 ms | 53.9배 |
| 4000×7000 → 1000×1750 linear | 317.9 ms | 4.1 ms | 78.1배 |
| png 디코딩 (37 MB) | 228.3 ms | 226.4 ms | 1.01배 |
| jpeg 디코딩 | 172.1 ms | 154.1 ms | 1.12배 |
| webp 디코딩 | 371.2 ms | 351.8 ms | 1.06배 |

Debug도 같은 방향이다 (`bench_skia.ps1 -Configuration Debug`). 4000×7000 cubic 축소가
2,587 ms에서 217 ms로 줄었다 (11.9배). Debug에서 배수가 작은 것은 `/Od`에서 벡터
코드가 손해를 크게 보기 때문이며, `/MTd` 링크와 실행이 성립하는 것을 여기서
확인한다.

폭이 8배인데 시간이 59배 줄어든 것이 이상해 보인다면, 파이프라인의 생김새가
답이다. 스테이지 하나하나가 간접 호출이고 그 호출이 **묶음 하나마다** 한 번이다.
폭이 1이면 픽셀마다 그 값을 온전히 치르므로, 벡터로 가며 줄어드는 것은 산술
8배만이 아니라 픽셀당 호출 횟수까지다.

바뀌지 않는 것도 분명하다. **디코딩은 거의 그대로다** — jpeg는 libjpeg-turbo의
어셈블리가, webp는 libwebp가, png는 bazel이 자기 clang으로 세우는 rust crate가
하는 일이라 GN 도구사슬과 무관하다. 이 변경이 사는 자리는 래스터 파이프라인이다.

#### MSVC 소비자와 어떻게 함께 서는가

clang-cl은 자기 표준 라이브러리를 들고 오지 않는다. Skia의 GN이 MSVC의 헤더를
`-imsvc`로 읽히고 링크할 CRT도 MSVC의 것을 가리키므로(`gn/skia/BUILD.gn`의
`_include_dirs`·`lib_dirs`), 나오는 아카이브의 C++ ABI는 MSVC의 것이다. 실측한
COFF 지시문이 두 도구사슬에서 **같다.**

```
/FAILIFMISMATCH:RuntimeLibrary=MT_StaticRelease     (Debug는 MTd_StaticDebug)
/FAILIFMISMATCH:_ITERATOR_DEBUG_LEVEL=0             (Debug는 2)
/FAILIFMISMATCH:_MSC_VER=1900
```

이름만 갈린다. MSVC의 CRT 헤더는 `/DEFAULTLIB:LIBCMT`를 pragma로 심고, clang-cl은
`/MT`를 보고 스스로 `/DEFAULTLIB:libcmt.lib`를 심는다. 가리키는 것은 같은
라이브러리이며 `verify_skia_root.ps1`이 두 형태를 모두 받는다.

여기에 **`is_trivial_abi = false`가 계약으로 붙는다.** 그 인자가 참이면 clang에서만
`SK_TRIVIAL_ABI=[[clang::trivial_abi]]`로 펼쳐져 `sk_sp` 같은 형의 호출 규약이
바뀌는데, MSVC로 컴파일되는 소비자에게는 그 속성이 없다. 같은 형이 서로 다른 ABI가
되고 링크는 성립한 채 런타임에 깨진다. MSVC로 세우던 동안에는 값이 무엇이든
무해했으므로 이 줄이 필요 없었다. GN 기본값도 `false`지만, 무해하지 않게 된 지금은
`third_party/skia-args/`가 명시하고 `verify_skia_root.ps1`이 참이면 실패시킨다.

`skia_use_partition_alloc`은 반대쪽 함정이다. 기본값이 `is_clang`이라 **도구사슬을
바꾸는 것만으로 저절로 켜진다.** 켜지면 `third_party/externals/partition_alloc`을
새로 요구해 `gn gen`이 그 자리에서 죽고(실측), 서더라도 Skia 안의 `raw_ptr`이 noop에서
실물로 바뀐다. 바꾸려는 것은 컴파일러 하나이므로 끈다.

#### 무엇으로 세웠는지 어떻게 아는가

`args.gn`은 "그렇게 gen했다"는 말이지 산출물의 사실이 아니고, CRT 지시문은 두
도구사슬이 똑같이 낸다. 그래서 검사가 셋이다.

1. `args.gn`의 `clang_win`이 비어 있지 않다.
2. `skia.lib`에 `.llvm_addrsig` section이 있다 — clang이 `-faddrsig`(기본값)로
   내는 LLVM 고유 section이다. 이름이 여덟 자를 넘어 COFF 문자열 테이블에 그대로
   들어가므로 바이트를 훑는 것만으로 판정된다 (32 MB에 50 ms).
3. `toolchain.json`이 산출물 옆에 있다. `build_skia.ps1`이 컴파일러·판번·MSVC·
   Windows SDK를 적어 두고, `pack_skia.ps1`이 그것을 패키지와 `VERSION.json`에
   싣는다. `args.gn`이 적지 못하는 것이 이것이라 파일을 따로 둔다.

앞의 둘은 `verify_skia_root.ps1`이 검사하며, **MSVC로 세운 산출물은 여기서 실패한다.**
의도한 것이다 — 링크는 되지만 소비자가 받는 물건으로는 다른 것이고, 그것을 모르고
발행하는 것이 이 스크립트가 막으려는 일이다. 견주려고 만든 MSVC 산출물은
`-OutputSuffix`로 다른 자리에 두고 검사에서 빼면 된다.

#### 재는 자리

```powershell
scripts\bench_skia.ps1 -Configuration Release
```

`tools/skia_probe.cpp`를 **MSVC로** 컴파일해 두 산출 디렉터리에 각각 링크하고
번갈아 돌린다. 그래서 이 스크립트가 통과하는 것은 성능 비교인 동시에
**MSVC 소비자와의 호환성 검사**다 — CRT도, C++ ABI도, 실제 런타임 동작도 여기서
함께 걸린다. 원본 이미지는 `tools/make_bench_source.py`가 Skia 없이 만든다.

재는 값이 흔들리면 `-AffinityMask`로 논리 코어 하나에 묶는다. 재는 것은 모두 한
갈래로 돌기 때문에, P코어와 E코어가 섞인 CPU에서는 어느 코어에 놓이는가만으로 몇 배가
갈린다 (실측한 기계가 그랬다). 스크립트는 늘 우선순위를 High로 올린다.

픽셀도 맞대어 본다. 채널 하나가 최대 2까지 갈리는 것을 통과로 두는데, 그것이
도구사슬의 오차가 아니라 **Skia가 벡터 경로에서 늘 내는 값**이기 때문이다. 위에
적은 대로 scalar에서는 `lowp`가 만들어지지 않아 8비트 블렌드까지 float로 돌지만,
벡터 코드에서는 그 `lowp`가 살아나고 그쪽의 `div255`가 "never wrong by more than 1"인
근사다. 프리멀티와 SrcOver처럼 그 연산이 겹치는 자리에서 최대 2가 난다. 실측에서
색 공간 변환(Display P3 → sRGB)과 디코딩 결과는 **바이트까지 같았다.**

### 5.5 알려진 구멍: rust png 인코더가 아카이브에 없다 (2026-09-11 실측)

`args.gn`에 `skia_use_rust_png_encode = true`가 있는데도 `SkPngRustEncoder::Encode`가
`skia.lib`에 들어가지 않는다. 부르면 LNK2019가 난다.

Skia 152의 `BUILD.gn`에서 `:png_encode_rust`를 deps에 넣는 target이 `optional("xml")`
하나뿐이고(legacy SVG factory를 위한 자리다), 이 저장소는 `skia_use_expat = false`·
`skia_use_jpeg_gainmaps = false`로 그 target을 끈다. libpng 쪽(`:png_encode_libpng`)은
`:skia` component가 직접 들고 있어 대칭이 아니다.

**도구사슬과 무관하다.** MSVC로 세운 것과 clang-cl로 세운 것에서 똑같이 비어 있는
것을 확인했다. luil이 png를 인코딩하지 않으므로 지금 막히는 자리는 없고, 필요해질
때 `:skia`의 deps에 한 줄을 더하는 패치로 푼다.

**뒷 판번에서도 그대로다** (2026-09-11에 upstream의 `BUILD.gn`을 직접 읽어 확인했다).
`chrome/m153`·`chrome/m154`·`main` 모두 `skia_component("skia")`의 deps에
`:png_decode_rust`는 있고 `:png_encode_rust`는 없다 — 디코더 쪽만 대칭이 맞춰져
있다. 버전을 올린다고 저절로 풀리지 않으므로, 그때 다시 뒤지지 않도록 적어 둔다.

**Android 갈래에서는 이 구멍이 없다** (2026-10-02 실측). 시스템 폰트를 읽으려고
`skia_use_expat = true`를 켜는데, 그것이 바로 `:xml`을 켜서 `:png_encode_rust`가
함께 들어온다. `libskia.a`에 `SkPngRustEncoder::Encode`가 정의돼 있고, Android용
시험 프로그램(`tools/android_probe.cpp`)이 그것을 불러 링크된다. 같은 심볼이 rust
아카이브에 함께 담긴 Skia 오브젝트에서 온 것이 아님도 `llvm-nm`으로 확인했다.
Windows 갈래만의 구멍이라는 뜻이다. Windows에서 expat을 켜서 풀지는 않는다 —
쓰지 않는 xml 파서와 그 고지를 들이게 된다.

## 6. 텍스트 처리 구성 (선택)

현재 luil은 `drawSimpleText`와 `measureText`만 사용해 shaping engine이 필요하지 않다. `SkShaper`나 `SkParagraph`를 도입할 때 이 구성을 쓴다.

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
- `scripts/pack_skia.ps1`의 `$package_revisions` — 대상마다 따로 세며, commit이 바뀌면 모두 1로 되돌린다 (5.4)
- `third_party/rust-licenses/<대상>` — crate 목록이 바뀌면 대상마다 다시 뜬다 (8.4)

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

## 8. Android 대상 (2026-10-02)

`-Target android-arm64`가 Android용 패키지를 세운다. 발행하는 갈래는 Windows와 같은
rust png다. 이 장의 실측은 WSL2 Ubuntu 24.04, NDK r27d, Skia 152(`0873ec164a`)의
것이고, 결과물이 arm64 실기기에서 돈다 (8.6).

### 8.1 왜 Linux에서 세우는가

rust png 코덱은 Bazel로 서는데, Skia의 Bazel NDK 도구사슬
(`toolchain/BUILD.bazel`의 `linux_amd64_ndk_arm64_toolchain`)은 실행 환경이
`linux x86_64`로 묶여 있다. 그래서 이 대상은 **Windows에서 세울 수 없다.** WSL2면
된다. 스크립트는 같은 PowerShell 스크립트를 Linux의 `pwsh`로 돌린다 —
`build_skia.ps1`이 호스트를 보고 맞지 않으면 시작 전에 멈춘다.

Skia 본체(GN 쪽)는 Windows 호스트의 NDK로도 선다 (`gn/BUILDCONFIG.gn`이
`host_os == "win"`을 안다). 막히는 것은 rust 쪽 하나다.

### 8.2 준비 (WSL)

소스와 Bazel 캐시는 **Linux 파일 시스템(`~/`)에 둔다.** `/mnt/e`를 거치면 Bazel이
느리고 symlink가 어긋난다. Bazel 캐시는 이 대상에서도 14 GB까지 자란다.

| 항목 | 비고 |
| --- | --- |
| `unzip`·`zip`·`build-essential` | apt. Bazel의 bootstrap이 쓴다 |
| `pwsh` | 7 이상. Microsoft의 apt 저장소에서 받는다 |
| `bazelisk` | `bazelisk-linux-amd64`를 `~/bin/bazelisk`로. 스크립트가 그 자리를 직접 본다 |
| NDK r27d | `android-ndk-r27d-linux.zip`을 `~/ndk`에 푼다. Skia CI가 쓰는 판번이다 |
| `gn`·`ninja` | Skia의 `bin/fetch-gn`·`bin/fetch-ninja`가 Linux판을 받는다. ninja는 Skia가 고정한 1.12.1이다 |

NDK를 찾는 순서는 `-NdkPath`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`,
`third_party/skia-tools/ndk`, `~/ndk/android-ndk-r27d`다. r27이 아니면 경고만 한다.

submodule은 Windows의 셋(D3D12MA·SPIRV 둘) 대신 아래를 받는다. 셋은 DEPS의
commit에 고정한 GitHub 원본이다.

```bash
git submodule update --init third_party/skia
git submodule update --init third_party/skia-externals/vulkanmemoryallocator
git submodule update --init third_party/skia-externals/freetype
git submodule update --init third_party/skia-externals/expat
git submodule update --init third_party/skia-externals/libjpeg-turbo
git submodule update --init third_party/skia-externals/libwebp
git submodule update --init third_party/skia-externals/wuffs
git submodule update --init third_party/skia-externals/libpng
git submodule update --init third_party/skia-externals/zlib
```

`libpng`·`zlib`은 **rust 갈래여도 필요하다.** freetype이 컬러 이모지 때문에 libpng을,
libpng이 zlib을 끌어온다 (`third_party/freetype2/BUILD.gn`). 코덱이 아니라 freetype의
의존으로서 들어간다.

### 8.3 빌드·검증·패키징

```bash
pwsh scripts/build_skia.ps1 -Target android-arm64 -Configuration Release -RustPng
pwsh scripts/build_skia.ps1 -Target android-arm64 -Configuration Debug   -RustPng
pwsh scripts/verify_skia_root.ps1 -Target android-arm64
pwsh scripts/pack_skia.ps1 -Target android-arm64 -Configuration Release -Archive
pwsh scripts/pack_skia.ps1 -Target android-arm64 -Configuration Debug -Destination build/skia-package-debug -Archive
```

산출 자리는 `out/skia-ui-android-arm64-{구성}`이다. 패키지 안에서는 Windows와 같은
`out/skia-ui-{구성}`으로 놓인다 — 소비자가 읽는 경로가 그것이다.

깨끗한 상태 — 패치가 걸리지 않은 Skia 트리, 빈 산출 디렉터리, external을 걷어 내고
submodule로 다시 받은 저장소 — 에서 이 다섯 줄이 패치를 걸고, external을 symlink로
놓고, 두 구성을 세우고, 검증하고, 압축하는 데 88초였다 (32코어, Bazel 캐시가 데워진
상태). Bazel 캐시가 비어 있으면 첫 빌드가 도구사슬과 crate를 받느라 몇 분 더 든다.

| 자산 | 압축 | 푼 뒤 |
| --- | --- | --- |
| `...-r1-android-arm64-release.zip` | 16.3 MB | 54 MB |
| `...-r1-android-arm64-debug.zip` | 48.1 MB | 225 MB |

rust 아카이브(`librust_png_ffi_rs.a`)가 크기의 대부분이다. 빌드 자리에서는 Release
196 MB인데 대부분이 디버그 정보라, 걷어 내고 실으면 줄어든다 (8.7).

`verify_skia_root.ps1`이 Android에서 따로 보는 것은 **아카이브의 CPU**다. ar member를
하나씩 걸어 ELF의 `e_machine`을 센다. `libskia.a`는 GN이 NDK로 세우므로 언제나
맞고, 어긋날 수 있는 것은 rust 아카이브다 — 8.4의 플랫폼 패치가 빠지면 그것만
조용히 x86_64로 서고, 소비자의 링크에서야 드러난다.

### 8.4 Windows와 다른 것

**args**는 `skia-ui-android-arm64-{release,debug}.gn`이다. 계약은 같다
(`is_trivial_abi = false`, partition_alloc 끔, 코덱 구성). 다른 것은 아래다.

| | Windows | Android |
| --- | --- | --- |
| GPU | Direct3D | Vulkan (Ganesh) |
| 글꼴 | DirectWrite | freetype + expat (`SkFontMgr_android`가 `/system/etc/fonts.xml`을 읽는다) |
| 컴파일러 | clang-cl, `clang_win` | NDK r27d의 clang, `ndk` |
| 하한 | — | `ndk_api = 26` (Android 8.0). 소비자의 minSdkVersion 하한이다 |

`skia_use_perfetto`·`skia_use_ndk_images`는 기본값이 `is_android`라 저절로 켜지므로
끈다. 뒤엣것은 `ndk_api >= 30`에서 png·jpeg 디코드를 플랫폼 코덱으로 바꾼다.

**패치**도 대상마다 다른 둘이다. 서로 섞지 않는다.

```bash
git -C third_party/skia apply ../patches/skia-152-bazel-rust-android-triples.patch
git -C third_party/skia apply ../patches/skia-152-bazel-rust-android-platform.patch
```

- `android-triples` — `MODULE.bazel`의 두 목록(Rust 표준 라이브러리의 대상, crate의
  지원 플랫폼)에 `aarch64-linux-android`가 없다. 뒤엣것이 없으면 crate_universe가
  `cxx`부터 모든 crate를 incompatible로 표시해 분석에서 멈춘다.
- `android-platform` — GN이 Bazel에 `--platforms`를 mac에만 넘긴다. Android도
  넘기게 한다. arm64만 다룬다.

**crate 판번이 Windows와 다르다.** crate 확장의 입력이 바뀌면 lock에 적힌 결과가
무효가 되고, Bazel이 고정되지 않은 전이 crate를 그날의 crates.io로 다시 푼다
(2026-10-02: crate 저장소 158 → 161, `cc` 1.4.4 → 1.5.1 등). 그래서
`android-triples` 패치가 **`MODULE.bazel.lock`째** 담는다 — 다시 세워도 같은
crate가 선다. lock에서 달라진 것은 crate 확장의 항목 하나뿐이다. crate 고지 사본도
대상마다 따로다 (`third_party/rust-licenses/<대상>`).

**두 NDK가 섞인다.** rust 쪽 C++ 브리지(`cxx`)는 Bazel이 받는 NDK **r21e**로,
나머지는 r27d로 컴파일된다. 링크와 실행 모두 문제없었다 (8.6). `toolchain.json`이
둘을 함께 적는다 (`ndk_revision`, `rust_bridge_ndk_revision`).

### 8.5 소비자가 지킬 것

1. **`-Wl,--allow-multiple-definition`으로 링크한다.** Bazel의 `rust_static_library`가
   의존하는 Skia C++ 오브젝트까지 아카이브에 담는다 (실측 441개). 같은 심볼이
   `libskia.a`와 겹치고, lld는 그것을 오류로 본다. Skia의 `BUILD.gn`도
   `rust_ffi_libs_config`에서 같은 플래그를 요구한다. 먼저 찾은 정의가 쓰이므로
   **`libskia.a`를 앞에 둔다.** (Windows의 `link.exe`는 같은 겹침을 조용히 넘긴다.
   그래서 Windows 패키지에서는 드러나지 않았다.)
2. **`-landroid -llog`를 링크한다.** 앞엣것은 `AHardwareBuffer`(Vulkan), 뒤엣것은
   Skia의 로그다. 빼면 링크가 깨진다. 그 밖에 요구하는 시스템 라이브러리는
   `libm`·`libdl`·`libc`뿐이다.
3. **Vulkan 메모리 할당기를 직접 넘긴다.** M152의 `GrVkGpu`는 그것을 스스로 만들지
   않는다. 만드는 함수 `skgpu::VulkanMemoryAllocators::Make`는 내부 헤더
   (`src/gpu/vk/vulkanmemoryallocator/VulkanMemoryAllocatorPriv.h`)에만 선언돼 있어
   패키지에 없다. 심볼은 `libskia.a`에 있으므로 선언을 소비자가 들고 있는다
   (`tools/android_probe.cpp`가 그렇게 한다).
4. **Vulkan 헤더는 NDK의 것으로 충분하다.** Skia 자신은 내부 헤더(VK_HEADER_VERSION
   347)로 섰지만, 그것을 여는 `SK_USE_INTERNAL_VULKAN_HEADERS`는 Skia의 컴파일에만
   붙는다. 소비자는 NDK r27d의 헤더(275)로 경고 없이 선다. 패키지는
   `include/third_party/`를 싣지 않는다.
5. **FreeType을 제품 문서에 밝힌다.** freetype은 FTL과 GPLv2 중 하나를 고르는
   이중 라이선스이고 이 패키지는 FTL을 고른다. FTL의 그 조항이 앱을 내는 쪽으로
   넘어간다. 권하는 문구는 `NOTICE.md` 머리에 있다.

### 8.6 기기에서 확인한다

링크가 서는 것은 심볼이 맞는다는 것까지다. `tools/android_probe.cpp`가 기기 위에서
소비자의 길 넷을 밟는다 — CPU 래스터, rust png 왕복, 시스템 글꼴, 화면 없는
Vulkan. 세우는 명령은 그 파일 머리에 있다. 앱(APK)도 화면도 필요 없다.

```powershell
adb push android_probe_release /data/local/tmp/
adb shell "chmod 755 /data/local/tmp/android_probe_release && /data/local/tmp/android_probe_release"
```

arm64 실기기(Vulkan 지원)에서 Release·Debug 모두 넷을 통과했다. 어느 기기인지는
적지 않는다.

```text
[OK  ] raster  64x64 blue with a red square
[OK  ] png     206 bytes, round trip is pixel-exact
[OK  ] fonts   <N> families, "Ag" inked <N> px
[OK  ] vulkan  <GPU 이름>: Ganesh drew and read back
android_probe passed
```

빌드 자리의 아카이브로 한 번, **패키지에 실린 아카이브**(디버그 정보를 걷은 것)로 한
번 링크해 둘 다 돌렸다. Debug는 `SkASSERT`가 켜진 구성이라 하나라도 걸리면 거기서
멈춘다. 기기 로그(`logcat`)에도 Skia의 경고가 없었다.

`adb`는 Windows 쪽에서 쓴다 (`winget install Google.PlatformTools`). WSL에서 USB를
보려면 usbipd가 더 든다. 시험 파일은 `\\wsl.localhost\<배포판>\...`로 바로 올린다.


### 8.7 생산자의 경로를 싣지 않는다

공개 자산이다. 처음 세운 Android 패키지에는 생산자의 홈 디렉터리
(`/home/<사용자>`)가 세 갈래로 실려 있었다. Windows 패키지에는 없던 일이다
(Release·Debug 모두 대조했다).

| 자리 | 무엇이 | 막는 법 |
| --- | --- | --- |
| `args.gn` | `ndk = "<NDK 경로>"` | `pack_skia.ps1`이 그 경로를 이름으로 바꿔 싣는다 |
| GN이 세운 Debug 아카이브 | DWARF의 컴파일 디렉터리, external 소스, NDK 시스템 헤더 | `build_skia.ps1`이 `-ffile-prefix-map`을 덧붙인다 (저장소 → `skia-prep`, NDK → `android-ndk`) |
| Bazel이 세운 rust 아카이브 둘 | DWARF의 컴파일 디렉터리 (Bazel sandbox, `_bazel_<사용자>`) — 449개 오브젝트 | `pack_skia.ps1`이 `llvm-objcopy --strip-debug`로 디버그 정보를 걷는다. 심볼은 남는다 |

rust 쪽을 빌드 때 고치지 않는 것은, Bazel의 C++과 rustc 양쪽에 경로 대응을 넣어야
하고 그것이 Skia 트리를 더 고치는 일이기 때문이다. 걷어 내는 쪽이 결정적이고
대상 하나에 갇힌다. 잃는 것은 rust 코덱과 그 아카이브에 함께 담긴 Skia 오브젝트의
디버그 정보다 — 앞엣것은 링크에서 `libskia.a`가 이기므로 원래 쓰이지 않는다.

마지막 그물은 `pack_skia.ps1`의 검사다. 압축하기 전에 패키지의 모든 파일에서
이 기계의 경로(`$HOME`·`_bazel_$USER`, Windows에서는 `%USERPROFILE%`)를 바이트로
찾고, 하나라도 있으면 **압축하지 않고 멈춘다.** 위의 표가 그 검사에 걸려 찾은
것이다.