# 릴리스 발행 절차

이 저장소는 CI로 발행하지 않는다. **생산자가 자기 기계에서 빌드해 자산을 올린다.**

이유는 rust png다. Skia의 rust 코덱은 Bazel로 서고, bazel이 hermetic clang과 Windows
SDK 묶음까지 받아 캐시가 15 GB까지 자란다. GitHub의 호스팅 Windows 러너는 SSD가
14 GB뿐이라 그 구성이 들어가지 않는다. 그리고 **발행하는 것은 rust 갈래다** —
skia-ui가 `skia_use_rust_png_decode=true`를 요구 인자로 못 박았고, APNG를 읽는 코덱이
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

산출물·GN args·CRT·C++ ABI를 모두 본다. 여기서 걸린 것을 패키징하지 않는다.

## 4. 패키징

```powershell
scripts\pack_skia.ps1 -Configuration Release -Archive
scripts\pack_skia.ps1 -Configuration Debug -Destination build\skia-package-debug -Archive
```

구성마다 zip이 하나씩 나온다. 헤더와 고지는 양쪽에 같은 것이 들어 있고, 소비자의
`fetch_skia.ps1`이 둘을 한 루트로 합친다.

실측 (Skia 152):

| 자산 | 압축 | 푼 뒤 |
| --- | --- | --- |
| `...-release.zip` | 26 MB | 111 MB |
| `...-debug.zip` | 204 MB | 896 MB |

`pack_skia.ps1`은 각 zip의 SHA-256을 마지막에 찍는다. **그 값이 다음 단계에 필요하다.**

crate 고지를 걷지 못하면 스크립트는 **멈춘다.** 고지 없이 배포하지
않는 것이 이 스크립트의 목적 중 하나다.

## 5. 릴리스

태그는 Skia의 밀번과 commit으로 짓는다: `skia-152-0873ec164a06`.

```powershell
gh release create skia-152-0873ec164a06 `
    build\skia-prep-0873ec164a06-win-x64-release.zip `
    build\skia-prep-0873ec164a06-win-x64-debug.zip `
    --title "Skia 152 (0873ec164a06) win-x64" `
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

`skia-ui`의 `third_party/skia-prep.json`을 새 값으로 고친다.

```json
{
    "tag": "skia-152-0873ec164a06",
    "asset_base_url": "https://github.com/yuldK/skia-prep/releases/download/skia-152-0873ec164a06",
    "png_codec": "rust",
    "skia_commit": "0873ec164a06966b90ae0d43ef783cfb180084ae",
    "assets": {
        "Release": { "file": "...", "size": 26978273, "sha256": "..." },
        "Debug":   { "file": "...", "size": 214147927, "sha256": "..." }
    }
}
```

`sha256`은 4단계가 찍은 값 그대로다. 값이 어긋나면 `fetch_skia.ps1`이 받은 파일을
버리고 멈춘다 — 판번 고정이 이 파일 하나로 끝나는 이유다.

마지막으로 소비자 쪽에서 한 번 돌려 본다.

```powershell
scripts\fetch_skia.ps1 -Configuration Debug,Release -Force
```
