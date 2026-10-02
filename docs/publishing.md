# 릴리스 발행 절차

이 저장소는 CI로 발행하지 않는다. **생산자가 자기 기계에서 빌드해 자산을 올린다.**

이유는 rust png다. Skia의 rust 코덱은 Bazel로 서고, bazel이 hermetic clang과 Windows
SDK 묶음까지 받아 캐시가 15 GB까지 자란다. GitHub의 호스팅 Windows 러너는 SSD가
14 GB뿐이라 그 구성이 들어가지 않는다. 그리고 **발행하는 것은 rust 갈래다** —
luil이 `skia_use_rust_png_decode=true`를 요구 인자로 못 박았고, APNG를 읽는 코덱이
그것뿐이다.

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
`$package_revision`에 있고 `-PackageRevision`으로 덮어쓸 수 있다.

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
    --notes-file build\skia-package\VERSION.json
```

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
