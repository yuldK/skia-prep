# 릴리스 발행 절차

이 저장소는 CI로 발행하지 않는다. **생산자가 자기 기계에서 빌드해 자산을 올린다.**

이유는 rust png다. Skia의 rust 코덱은 Bazel로 서고, bazel이 hermetic clang과 Windows
SDK 묶음까지 받아 캐시가 15 GB까지 자란다. GitHub의 호스팅 Windows 러너는 SSD가
14 GB뿐이라 그 구성이 들어가지 않는다. 그리고 **발행하는 것은 rust 갈래다** —
luil이 `skia_use_rust_png_decode=true`를 요구 인자로 못 박았고, APNG를 읽는 코덱이
그것뿐이다.

1~6장은 `win-x64`의 절차다. `android-arm64`는 같은 스크립트를 Linux에서 돌리며,
다른 것만 7장에 모았다.

## 1. 준비

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
```

`gn`과 `ninja`는 `build_skia.ps1`이 알려진 자리에서 찾는다. 없으면 `-FetchTools`를
주거나 `third_party/skia-tools/`에 넣는다.

**`clang-cl`도 필요하다.** Skia 자신을 컴파일하는 것이 그것이다
(docs/skia-build.md 5.4). Visual Studio의 "C++ Clang tools for Windows" 구성 요소면
되고, 스크립트가 `gn/find_msvc.py`가 고른 VC 안에서 먼저 찾는다.

rust png 갈래는 `bazelisk.exe` 하나가 더 필요하다. **launcher(.cmd·.ps1)로는 안 된다** —
Skia의 `bazel_build.py`가 CreateProcess로 부르기 때문이다.

```powershell
winget install Bazel.Bazelisk
```

## 2. 빌드

두 구성을 **같은 png 갈래로** 세운다. 갈래가 어긋나면 소비자의 configure가 거른다.

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng
scripts\build_skia.ps1 -Configuration Debug   -RustPng
```

`-RustPng`을 빼면 libpng 갈래가 선다. **발행하는 것은 그쪽이 아니다** — 물러설
자리로만 둔다 (README). 그쪽으로 만든 zip은 이름에 `-libpng`이 붙어 구별된다.

## 3. 검증

```powershell
scripts\verify_skia_root.ps1
```

산출물·GN args·도구사슬·CRT·C++ ABI를 모두 본다. 여기서 걸린 것을 패키징하지 않는다.

도구사슬을 바꾸었거나 판번을 올린 뒤에는 한 번 더 잰다.

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng -Toolchain msvc -OutputSuffix '-msvc'
scripts\bench_skia.ps1 -Configuration Release -Baseline '-msvc' -Candidate ''
```

`bench_skia.ps1`은 `tools/skia_probe.cpp`를 **MSVC로** 컴파일해 두 산출물에 각각
링크한다. 그래서 이것이 통과하는 것은 성능 비교인 동시에 소비자와의 호환성
검사다 — 소비자는 MSVC로 빌드하기 때문이다. 픽셀 비교도 함께 본다
(docs/skia-build.md 5.4).

## 4. 패키징

```powershell
scripts\pack_skia.ps1 -Configuration Release -Archive
scripts\pack_skia.ps1 -Configuration Debug -Destination build\skia-package-debug -Archive
```

구성마다 zip이 하나씩 나온다. 헤더와 고지는 양쪽에 같은 것이 들어 있고, 소비자의
`fetch_skia.ps1`이 둘을 한 루트로 합친다.

이름에 **패키지 판번**이 들어간다 (`...-0873ec164a06-r2-win-x64-release.zip`).
Skia commit만으로는 같은 소스를 다시 세운 두 패키지를 가리지 못하기 때문이다 —
r1은 MSVC로 세운 것(번호를 붙이기 전이라 이름에 번호가 없다), r2는 clang-cl로 세워
CPU 래스터 파이프라인이 SIMD 경로로 서는 것이다. 번호는 `pack_skia.ps1`의
`$package_revisions`에 **대상마다 따로** 있고 `-PackageRevision`으로 덮어쓸 수 있다.

| 대상 | 판번 | 무엇인가 |
| --- | --- | --- |
| `win-x64` | r3 | Debug의 디버그 정보에서 생산자 경로를 걷었다 (아래) |
| `win-x64` | r2 | clang-cl로 세워 SIMD 경로로 선다 (r1은 MSVC). **Debug 자산에 사용자 이름이 실려 있다** |
| `android-arm64` | r1 | 첫 Android 패키지 |

r3은 기능이 r2와 같다 — 같은 시험 이미지 일곱 장의 픽셀이 바이트까지 같다. 그래서
r2를 다시 내지는 않고, 다음에 발행할 이유가 생길 때 r3으로 낸다. 무엇을 막았는지는
[skia-build.md](skia-build.md) 8.7에 있다.

| 자산 | 압축 | 푼 뒤 |
| --- | --- | --- |
| `...-r3-win-x64-release.zip` | 19.6 MB | 70 MB |
| `...-r3-win-x64-debug.zip` | 112.6 MB | 439 MB |

r2보다 작은 것은 rust 아카이브의 디버그 정보를 걷어 싣기 때문이다.

실측 (Skia 152, r2):

| 자산 | 압축 | 푼 뒤 |
| --- | --- | --- |
| `...-release.zip` | 20.5 MB | 75 MB |
| `...-debug.zip` | 136 MB | 541 MB |

r1(MSVC)보다 작다 — Release가 25.7 MB에서, Debug가 204 MB에서 줄었다. lld-link가
같은 코드를 더 작은 아카이브로 내기 때문이며, 담긴 것은 그대로다.

`pack_skia.ps1`은 각 zip의 SHA-256을 마지막에 찍는다. **그 값이 다음 단계에 필요하다.**

crate 고지를 걷지 못하면 스크립트는 **멈춘다.** 고지 없이 배포하지
않는 것이 이 스크립트의 목적 중 하나다.

## 5. 릴리스

태그는 Skia의 밀번과 commit과 패키지 판번으로 짓는다: `skia-152-0873ec164a06-r2`.
판번이 붙는 이유는 자산 이름과 같다 — 같은 Skia commit을 다시 세운 것이 서로 다른
물건일 수 있고, 태그가 자산이 놓이는 자리를 정하기 때문이다.

```powershell
gh release create skia-152-0873ec164a06-r2 `
    build\skia-prep-0873ec164a06-r2-win-x64-release.zip `
    build\skia-prep-0873ec164a06-r2-win-x64-debug.zip `
    --title "Skia 152 (0873ec164a06) win-x64 r2 - clang-cl SIMD" `
    --notes-file build\release\NOTES.md
```

**릴리스 본문은 Markdown으로 따로 쓴다.** `VERSION.json`을 `--notes-file`로 넘기면
JSON이 서식 없이 그대로 노출된다 (android-arm64 r1에서 그랬다). 본문에는 대상·Skia
commit·도구사슬·판번이 무엇을 바꿨는가·자산의 SHA-256·소비자가 지킬 것을 적고,
`VERSION.json` 자체는 패키지 안에 있으므로 본문에 싣지 않는다.

`gh`가 없으면 GitHub의 릴리스 화면에서 zip 둘을 끌어다 놓아도 된다. 릴리스 자산은
파일 하나에 2 GB까지라 204 MB짜리 Debug도 그대로 올라간다.

```powershell
winget install GitHub.cli
```

자산이 놓이는 자리는 태그로 정해진다.

```
https://github.com/yuldK/skia-prep/releases/download/<태그>/<파일 이름>
```

**저장소가 공개여야 한다.** 소비자의 `fetch_skia.ps1`은 인증 없이 내려받는다.

GitHub이 아닌 자리(사내 파일 서버 등)에 올려도 된다. 소비자 쪽이 보는 것은
`asset_base_url` 하나뿐이다.

## 6. 소비자 핀 갱신

`luil`의 `third_party/skia-prep.json`을 새 값으로 고친다.

```json
{
    "tag": "skia-152-0873ec164a06-r2",
    "asset_base_url": "https://github.com/yuldK/skia-prep/releases/download/skia-152-0873ec164a06-r2",
    "png_codec": "rust",
    "skia_commit": "0873ec164a06966b90ae0d43ef783cfb180084ae",
    "package_revision": 2,
    "assets": {
        "Release": {
            "file": "skia-prep-0873ec164a06-r2-win-x64-release.zip",
            "size": 21485418,
            "sha256": "4e944162ee1fd7b419bf16af3c760f70b496695fcdaebd9ceb96d4c258ac7f7e"
        },
        "Debug": {
            "file": "skia-prep-0873ec164a06-r2-win-x64-debug.zip",
            "size": 142808948,
            "sha256": "1a221b21b05408e793093b0b76934808ebc1b4f62834c8ac0419cb591cb25b67"
        }
    }
}
```

`skia_commit`이 그대로인데 `tag`와 파일 이름이 바뀐다. **그래서 판번이 있다** —
소스가 같고 빌드가 다른 두 패키지를 commit만으로는 가리키지 못한다.

`sha256`은 4단계가 찍은 값 그대로다. 값이 어긋나면 `fetch_skia.ps1`이 받은 파일을
버리고 멈춘다 — 판번 고정이 이 파일 하나로 끝나는 이유다.

마지막으로 소비자 쪽에서 한 번 돌려 본다.

```powershell
scripts\fetch_skia.ps1 -Configuration Debug,Release -Force
```

## 7. Android 패키지

준비와 이유는 [skia-build.md](skia-build.md) 8장에 있다. 요약하면 **WSL2에서**, 저장소를
Linux 파일 시스템(`~/`)에 받아 `pwsh`로 같은 스크립트를 돌린다.

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

pwsh scripts/build_skia.ps1 -Target android-arm64 -Configuration Release -RustPng
pwsh scripts/build_skia.ps1 -Target android-arm64 -Configuration Debug   -RustPng
pwsh scripts/verify_skia_root.ps1 -Target android-arm64
pwsh scripts/pack_skia.ps1 -Target android-arm64 -Configuration Release -Archive
pwsh scripts/pack_skia.ps1 -Target android-arm64 -Configuration Debug -Destination build/skia-package-debug -Archive
```

`verify_skia_root.ps1`이 Android에서 따로 보는 것은 아카이브의 CPU다 — rust 아카이브가
조용히 x86_64로 서는 실패를 여기서 잡는다. `pack_skia.ps1`은 압축 전에 이 기계의
경로가 패키지에 남았는지 훑고, 남았으면 멈춘다 (skia-build.md 8.7).

**기기에서 한 번 돌린다.** 링크까지는 스크립트가 보지만 실행은 보지 못한다.
`tools/android_probe.cpp`를 패키지에 링크해 `adb`로 올린다 (세우는 명령은 그 파일
머리에 있다). 넷이 모두 `OK`여야 올린다.

실측 (Skia 152, android-arm64 r1):

| 자산 | 압축 | 푼 뒤 |
| --- | --- | --- |
| `skia-prep-0873ec164a06-r1-android-arm64-release.zip` | 16.3 MB | 54 MB |
| `skia-prep-0873ec164a06-r1-android-arm64-debug.zip` | 48.1 MB | 225 MB |

**태그에 대상을 넣는다.** 판번을 대상마다 따로 세므로 `skia-152-0873ec164a06-r1`은
Windows의 r1과 겹친다.

```powershell
gh release create skia-152-0873ec164a06-android-arm64-r1 `
    \\wsl.localhost\Ubuntu-24.04\home\<사용자>\skia-prep\build\skia-prep-0873ec164a06-r1-android-arm64-release.zip `
    \\wsl.localhost\Ubuntu-24.04\home\<사용자>\skia-prep\build\skia-prep-0873ec164a06-r1-android-arm64-debug.zip `
    --title "Skia 152 (0873ec164a06) android-arm64 r1" `
    --notes-file NOTES.md
```

`NOTES.md`는 Markdown 본문이다 (5장). `--target`을 줄 때는 전체 SHA(40자)나 브랜치
이름을 준다 — 짧은 SHA는 GitHub API가 `HTTP 422`로 거부한다.

**Latest가 바뀐다.** `gh`는 새 릴리스를 Latest로 표시하므로, Android 릴리스를 내면
저장소 첫 화면의 Latest가 Android 자산이 된다. luil의 핀은 태그를 직접 가리키므로
받는 데는 영향이 없다. Windows 릴리스를 Latest로 두려면 `--latest=false`를 준다.

Windows의 태그(`skia-152-0873ec164a06-r2`)는 대상을 넣기 전에 지은 이름이라 그대로 둔다.

luil에는 아직 Android 핀이 없다. luil이 Android를 세우기 시작할 때 이 자산을 가리키는
핀을 따로 둔다 — Windows 핀(`third_party/skia-prep.json`)은 `target`이 `win-x64`로
고정돼 있다.
