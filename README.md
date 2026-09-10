# skia-prep

`skia-ui`가 쓰는 **Skia prebuilt 패키지를 만드는 저장소**다.

Skia를 소스로 세우는 데 드는 것 — submodule 5 GB, git 이력 4.7 GB, rust png를 쓰면
bazel 캐시 15 GB — 을 이 저장소 하나가 떠안는다. `skia-ui`를 쓰는 사람은 이 저장소를
받지 않는다. 릴리스에 올라간 **자산(zip) 하나**만 받으면 된다.

| | 받는 것 |
| --- | --- |
| skia-ui 소비자 | 릴리스 자산 zip 1개 (Release 20 MB · Debug 136 MB) |
| 이 저장소의 생산자 | submodule 전부 + clang-cl·gn·ninja (+ rust png면 bazelisk) |

> 이 저장소가 내는 것은 **Google과 무관한 비공식 빌드**다. Skia의 BSD-3-Clause 3항에
> 따라 저작권자와 기여자의 이름을 이 배포물의 홍보에 쓰지 않는다. Skia는 Google이
> 만들고 BSD-3-Clause로 배포하는 라이브러리이며, 원본은
> <https://skia.googlesource.com/skia> 에 있다.

## 패키지에 들어가는 것

배치가 **Skia 소스 트리와 같다.** 그래서 소비자의 빌드 체계는 이 패키지와 Skia 트리를
구별하지 않는다 — Skia 루트를 가리키는 변수를 여기로 돌리는 것으로 끝난다.

```
include/              Skia 공개 헤더 2.1 MB (include/third_party/ 는 뺀다)
modules/skcms/        공개 헤더가 include/ 밖에서 참조하는 유일한 것
LICENSE               Skia 원문. 헤더가 소스 형태로 나가므로 필수다
NOTICE.md             정적으로 들어간 모든 것의 고지를 모은 한 장
licenses/rust/        rust 갈래에서만. Rust 표준 라이브러리 고지
VERSION.json          Skia commit·밀번·png 갈래·도구사슬·패키지 판번·파일별 SHA-256
out/skia-ui-release/  *.lib *.a args.gn toolchain.json
out/skia-ui-debug/    (Debug 패키지)
```

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
```

`libpng`과 `zlib`은 **물러설 자리인 libpng 갈래**에만 필요하다.
`harfbuzz`·`libgrapheme`·`unicodetools`·`icu`는 텍스트 구성에서만 쓰며, 작업 트리가
3.3 GB라 평소에는 받지 않는다.

```powershell
scripts\build_skia.ps1 -Configuration Release -RustPng
scripts\build_skia.ps1 -Configuration Debug   -RustPng
scripts\verify_skia_root.ps1
scripts\pack_skia.ps1 -Configuration Release -Archive
scripts\pack_skia.ps1 -Configuration Debug -Destination build\skia-package-debug -Archive
```

**Skia 자신은 clang-cl로 컴파일한다.** 소비자는 그대로 MSVC이고, 헤더와 CRT도 여전히
MSVC의 것을 쓴다 — 바뀌는 것은 Skia를 컴파일하는 컴파일러 하나다.

이유는 CPU 래스터 파이프라인의 처리 폭이다. `SkRasterPipeline_opts.h`가 벡터를
clang·gcc의 확장으로만 만들어, MSVC로 세운 Skia는 한 번에 픽셀 **하나**를 처리했다.
clang-cl로 세우면 `SkOpts::Init()`의 실행 시점 판정이 AVX2 갈래(폭 8, 8비트 경로는
16)로 바꿔 끼운다. 4000×7000 이미지의 cubic 축소가 실측에서 800 ms에서 14 ms로
줄었다. 자세한 것과 재는 법은 [docs/skia-build.md](docs/skia-build.md) 5.4에 있다.

**`-RustPng`이 발행하는 갈래다.** skia-ui가 그것을 요구 인자로 못 박았다 —
APNG(움직이는 png)를 읽는 코덱이 rust뿐이기 때문이다. 그쪽은 bazelisk가 필요하고
캐시가 15 GB까지 자라므로 **GitHub Actions의 호스팅 러너(SSD 14 GB)에서는 세울 수
없다.** 그래서 이 저장소는 CI로 발행하지 않고 생산자가 자기 기계에서 빌드해 릴리스를
올린다.

`-RustPng` 없이 세우는 libpng 갈래는 **물러설 자리로만** 남겨 둔다. Skia의 rust
경로는 148~151에서 서지 않았고(152가 고쳤다) 뒷날 다시 막힐 수 있다. 그때 이쪽으로
패키지를 만들고 skia-ui에서 요구 인자 한 줄을 뺀다. 그 갈래의 zip은 이름에
`-libpng`이 붙어 rust 갈래와 구별된다 — 서로 링크 호환되지 않는다.

발행 절차는 [docs/publishing.md](docs/publishing.md)에 있다.

## 라이선스

이 저장소 자신의 것은 스크립트와 GN args와 패치와 벤치마크 도구뿐이다. 릴리스 자산에
담기는 제3자 구성요소의 고지는 `pack_skia.ps1`이 걷어 패키지의 `NOTICE.md`에 싣는다 —
Skia와 그 external, rust 갈래에서는 crate와 Rust 표준 라이브러리까지 담는다.

담기는 것은 모두 permissive다: BSD-3-Clause(Skia·libwebp·skcms), Apache-2.0(SPIRV-Cross·
Wuffs), MIT(SPIRV-Headers·D3D12MemoryAllocator), IJG + BSD-3(libjpeg-turbo),
PNG Reference Library License v2(libpng), Zlib(zlib), 그리고 rust 갈래의
MIT / Apache-2.0 / 0BSD / Zlib crate들. 상호주의 조항은 없다.
