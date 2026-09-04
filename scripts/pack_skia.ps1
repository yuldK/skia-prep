# 손으로 빌드한 Skia에서 **배포할 것만** 골라 패키지를 만든다.
#
# 소비자는 Skia 소스 트리도, external submodule도, gn·ninja·bazelisk도 필요 없다.
# 필요한 것은 헤더와 정적 라이브러리와 고지뿐이고, 이 스크립트가 그것만 뽑는다.
# 실측: Skia 트리 1,891 MB → 패키지 111 MB (Release). 그 패키지만으로 skia-ui와
# 예제 실행 파일이 전부 빌드된다.
#
# 나오는 것의 배치는 **Skia 트리와 같다.** 그래서 소비자의
# cmake/dependencies/skia.cmake가 이 패키지를 Skia 트리와 구별하지 않는다 —
# SKIA_UI_SKIA_ROOT를 여기로 돌리는 것으로 끝난다.
#
#   package/
#     include/              Skia 공개 헤더 (include/third_party/ 는 뺀다)
#     modules/skcms/        공개 헤더가 include/ 밖에서 참조하는 유일한 것
#     LICENSE               Skia 원문. 헤더가 소스 형태로 나가므로 필수다
#     NOTICE.md             정적으로 들어간 모든 것의 고지를 모은 한 장
#     VERSION.json          Skia 밀번·commit·png 갈래·패치·파일별 SHA-256
#     out/skia-ui-release/  *.lib *.a args.gn
#     out/skia-ui-debug/    (Debug도 함께 만들 때)
#
# NOTICE.md를 패키지가 스스로 들고 다니는 이유는 고지 의무 때문이다.
# 소비자에게는 Skia의 third_party/externals가 없으므로 거기서 라이선스 원문을
# 읽을 수 없다. 그 자리에서 읽던 skia-ui의 generate_notices.cmake도 이 파일
# 하나를 읽는 쪽으로 옮겨 간다.

[CmdletBinding()]
param(
    [string]$SkiaRoot,
    [ValidateSet('Debug', 'Release')]
    [string[]]$Configuration = @('Release'),
    [string]$Destination,
    [switch]$Archive,
    [string]$BazeliskPath,
    [string]$RustLicenseRoot,
    # include/third_party/ 는 vulkan·dawn 헤더 20.7 MB다.
    # 이 저장소가 고정한 GN args는 vulkan을 끄므로 아무것도 그것을 열지 않는다
    # (헤더를 지운 트리로 clean 재빌드해 확인했다). 다른 backend로 빌드한 Skia를
    # 담을 때만 이 스위치를 준다.
    [switch]$IncludeVendorHeaders
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot
if (-not $SkiaRoot) {
    $SkiaRoot = Join-Path $repository_root 'third_party\skia'
}
if (-not (Test-Path -LiteralPath $SkiaRoot -PathType Container)) {
    throw "The Skia tree was not found: $SkiaRoot"
}
$skia_root = (Resolve-Path -LiteralPath $SkiaRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $skia_root 'include\core\SkCanvas.h'))) {
    throw @"
The Skia tree is incomplete: $skia_root
Run: git submodule update --init third_party/skia
"@
}
if (-not $Destination) {
    $Destination = Join-Path $repository_root 'build\skia-package'
}

# CMakeLists.txt의 SKIA_UI_SKIA_COMPONENTS와 같은 목록이다 (파일 이름 그대로).
# verify_skia_root.ps1도 같은 목록을 갖는다.
$components = @(
    'skia.lib', 'skcms.lib', 'spirv_cross.lib', 'd3d12allocator.lib',
    'libjpeg.lib', 'libjpeg12.lib', 'libjpeg16.lib',
    'libwebp.lib', 'libwebp_sse41.lib', 'wuffs.lib')
$libpng_components = @('libpng.lib', 'zlib.lib')
$rust_png_components = @('librust_png_ffi_rs.a', 'libcxx_cc.a')

$externals_root = Join-Path $skia_root 'third_party\externals'

# 정적으로 들어가는 것의 고지다. 순서가 NOTICE.md의 순서다.
#
# 여기 담긴 것 중 셋은 skia-ui의 generate_notices.cmake에 **없던 것**이다.
#  - libjpeg-turbo의 README.ijg : LICENSE.md는 IJG 라이선스를 참조만 하고
#    원문은 이 파일에 있다. IJG 라이선스는 문서에 원문 동봉을 요구한다.
#  - d3d12allocator의 NOTICES.txt : LICENSE.txt만 읽고 있었다.
#  - rust crate 전부 : bazel 캐시에만 있어 트리에서 읽을 자리가 없었다.
#    아래 Get-RustCrateNotice가 캐시에서 걷는다.
$common_notices = @(
    @{ name = 'Skia'; path = (Join-Path $skia_root 'LICENSE') },
    @{ name = 'skcms'; path = (Join-Path $skia_root 'modules\skcms\README.chromium') },
    @{ name = 'SPIRV-Cross'; path = (Join-Path $externals_root 'spirv-cross\LICENSE') },
    @{ name = 'SPIRV-Headers'; path = (Join-Path $externals_root 'spirv-headers\LICENSE') },
    @{ name = 'D3D12 Memory Allocator'; path = (Join-Path $externals_root 'd3d12allocator\LICENSE.txt') },
    @{ name = 'D3D12 Memory Allocator - Notices'; path = (Join-Path $externals_root 'd3d12allocator\NOTICES.txt') },
    @{ name = 'libjpeg-turbo'; path = (Join-Path $externals_root 'libjpeg-turbo\LICENSE.md') },
    @{ name = 'libjpeg-turbo - IJG License'; path = (Join-Path $externals_root 'libjpeg-turbo\README.ijg') },
    @{ name = 'libwebp'; path = (Join-Path $externals_root 'libwebp\COPYING') },
    @{ name = 'Wuffs'; path = (Join-Path $externals_root 'wuffs\LICENSE') })
$libpng_notices = @(
    @{ name = 'libpng'; path = (Join-Path $externals_root 'libpng\LICENSE') },
    @{ name = 'zlib'; path = (Join-Path $externals_root 'zlib\LICENSE') })

function Get-FileHashText {
    param([string]$path)

    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# 어느 png 코덱으로 세운 빌드인지는 args.gn이 말한다.
# 발행하는 것은 rust 갈래뿐이지만 libpng 갈래는 물러설 자리로 남아 있으므로
# (skia-prep의 README) 여기서는 둘 다 만들 수 있어야 한다.
# 소비자 쪽은 rust를 요구 인자로 못 박아 이 판정을 하지 않는다.
function Get-PngCodec {
    param([string]$arguments_file)

    $text = Get-Content -Raw -LiteralPath $arguments_file
    $uses_rust = $text -match 'skia_use_rust_png_decode\s*=\s*true'
    $uses_libpng = $text -match 'skia_use_libpng_decode\s*=\s*true'
    if ($uses_rust -and $uses_libpng) {
        throw "The Skia build enables both png decoders: $arguments_file"
    }
    if (-not $uses_rust -and -not $uses_libpng) {
        throw "The Skia build has no png decoder: $arguments_file"
    }
    if ($uses_rust) { return 'rust' }
    return 'libpng'
}

# rust 갈래의 crate 고지가 놓인 자리를 찾는다.
# 원본은 bazel이 자기 output base에 받아 두는 것이고, 그 자리를 묻는 길은 bazel
# 자신뿐이라 bazelisk를 부른다. 어디에서도 찾지 못하면 rust 갈래는 고지를 채울 수
# 없으므로 **조용히 넘기지 않는다** — 고지 없이 배포하는 것이 바로 막으려는 구멍이다.
#
# 찾는 순서는 셋이다.
#   1. -RustLicenseRoot
#   2. third_party/rust-licenses  ← 이 저장소가 떠 둔 사본
#   3. bazelisk info output_base
#
# 2가 있는 이유는 bazel 캐시가 15 GB까지 자라 평소에 지우기 때문이다. 지우고 나면
# 3은 **전체 재빌드 없이는 되살아나지 않는데**, 필요한 것은 텍스트 0.7 MB뿐이라
# 저장소가 들고 있는 편이 싸다. 배치는 bazel의 것과 같게 두어 아래 걷는 함수 둘이
# 두 자리를 구별하지 않는다.
#  - crate 목록이 바뀌면(Skia의 MODULE.bazel) 이 사본도 다시 떠야 한다. 캐시가
#    살아 있는 기계에서 3으로 한 번 돌려 대조한다.
function Resolve-RustLicenseRoot {
    if ($RustLicenseRoot) {
        if (-not (Test-Path -LiteralPath $RustLicenseRoot -PathType Container)) {
            throw "The given -RustLicenseRoot was not found: $RustLicenseRoot"
        }
        return (Resolve-Path -LiteralPath $RustLicenseRoot).Path
    }

    $vendored = Join-Path $repository_root 'third_party\rust-licenses'
    if (Test-Path -LiteralPath $vendored -PathType Container) {
        return (Resolve-Path -LiteralPath $vendored).Path
    }

    $bazelisk = $BazeliskPath
    if (-not $bazelisk) {
        $local = Join-Path $repository_root 'third_party\skia-tools\bazelisk.exe'
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            $bazelisk = (Resolve-Path -LiteralPath $local).Path
        }
        else {
            $command = Get-Command -Name 'bazelisk' -CommandType Application -ErrorAction SilentlyContinue |
                Where-Object { [System.IO.Path]::GetExtension($_.Source) -eq '.exe' } |
                Select-Object -First 1
            if ($command) {
                $bazelisk = $command.Source
            }
        }
    }
    if (-not $bazelisk) {
        throw @"
This is a rust png build, and its crate notices were not found.

Looked in:
  third_party\rust-licenses          (this repository's copy - it is missing)
  bazelisk info output_base          (bazelisk.exe was not found)

Do one of these:
  1. Restore third_party\rust-licenses from git - it is the cheap path and
     needs no Bazel at all.
  2. Pass -BazeliskPath <path to bazelisk.exe>.
  3. Pass -RustLicenseRoot <the "external" directory of the Bazel output base>.
     Find it with: bazelisk info output_base   (run inside $skia_root)

Packaging the rust flavour without those notices is exactly the gap this
script exists to close, so it will not continue without them.
"@
    }

    Push-Location $skia_root
    try {
        $output_base = & $bazelisk info output_base
        if ($LASTEXITCODE -ne 0 -or -not $output_base) {
            throw "bazelisk info output_base failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
    $external = Join-Path ("$output_base" -replace '/', '\') 'external'
    if (-not (Test-Path -LiteralPath $external -PathType Container)) {
        throw "The Bazel output base has no external directory: $external"
    }
    return (Resolve-Path -LiteralPath $external).Path
}

# crate 하나의 고지를 만든다.
# crate는 대개 MIT과 Apache-2.0을 함께 두고 소비자가 고르게 하므로 둘 다 싣는다.
function Get-RustCrateNotice {
    param([string]$external_root)

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    # `crates__*` 가 //rust/png:ffi_rs 의 crate 집합이다.
    # (`cargo_bindeps__*` 는 cxxbridge-cmd 도구라 산출물에 링크되지 않는다.
    #  다만 걷는 쪽이 넘치는 편이 모자란 것보다 안전하므로 판단은 하지 않고
    #  링크되는 집합만 정확히 고른다.)
    $directories = Get-ChildItem -LiteralPath $external_root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*crate+crates__*' -and $_.Name -notlike '*crate+crates' } |
        Sort-Object Name
    foreach ($directory in $directories) {
        $crate = ($directory.Name -split 'crates__')[-1]
        $license_files = Get-ChildItem -LiteralPath $directory.FullName -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' } |
            Sort-Object Name
        foreach ($license_file in $license_files) {
            $entries.Add(@{
                    name = "Rust crate: $crate ($($license_file.Name))"
                    path = $license_file.FullName
                })
        }
    }
    if ($entries.Count -eq 0) {
        throw "No crate licenses were found under: $external_root"
    }
    return $entries.ToArray()
}

# Rust 표준 라이브러리의 고지다.
# 원문이 html뿐이라 NOTICE.md에 본문으로 싣지 못한다 — 파일로 옮기고 가리킨다.
#
# 가져오는 것은 `COPYRIGHT-library.html`(0.43 MB) **하나**다.
# 같은 자리의 `COPYRIGHT.html`(11.8 MB)은 rustc·cargo까지 포함한 도구사슬 전체의
# 고지인데, 우리가 배포하는 것은 컴파일된 라이브러리 코드뿐이라 그쪽은 배포물에
# 들어가지 않는다. Rust 프로젝트가 그 경계로 파일을 나눠 두었다.
function Copy-RustRuntimeNotice {
    param([string]$external_root, [string]$package_root)

    $documents = Get-ChildItem -LiteralPath $external_root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*rust_host_tools*' } |
        ForEach-Object { Join-Path $_.FullName 'share\doc\rust' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $documents) {
        throw @"
The Rust standard library notices were not found under: $external_root
Expected: <rust_host_tools>/share/doc/rust/COPYRIGHT.html
The static archive links the Rust standard library, so its notice is required.
"@
    }

    $target = Join-Path $package_root 'licenses\rust'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $name = 'COPYRIGHT-library.html'
    $source = Join-Path $documents $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "The Rust library notice was not found: $source"
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
    return "licenses/rust/$name"
}

# ---------------------------------------------------------------------------
# 1. 구성별 산출물을 확인하고 png 갈래를 정한다.
# ---------------------------------------------------------------------------
$configurations = @($Configuration | Sort-Object -Unique)
$builds = [System.Collections.Generic.List[hashtable]]::new()
$png_codec = ''
foreach ($name in $configurations) {
    $build_directory = Join-Path $skia_root ('out\skia-ui-{0}' -f $name.ToLowerInvariant())
    $arguments_file = Join-Path $build_directory 'args.gn'
    if (-not (Test-Path -LiteralPath $arguments_file -PathType Leaf)) {
        throw @"
The Skia $name build was not found: $build_directory
Build it first: scripts\build_skia.ps1 -Configuration $name
"@
    }

    $codec = Get-PngCodec -arguments_file $arguments_file
    if ($png_codec -and $codec -ne $png_codec) {
        throw @"
The Skia builds use different png codecs (already seen: $png_codec, $name : $codec).
Build both the same way - give -RustPng to both or to neither.
"@
    }
    $png_codec = $codec

    $required = $components + $(if ($codec -eq 'rust') { $rust_png_components } else { $libpng_components })
    foreach ($component in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $build_directory $component) -PathType Leaf)) {
            throw @"
A Skia $name build output is missing: $build_directory\$component
Build it first: scripts\build_skia.ps1 -Configuration $name
"@
        }
    }

    $builds.Add(@{
            name      = $name
            directory = $build_directory
            arguments = $arguments_file
            required  = $required
        })
}

Write-Output "Skia root      : $skia_root"
Write-Output "Configurations : $($configurations -join ', ')"
Write-Output "png codec      : $png_codec"
Write-Output "Destination    : $Destination"

# ---------------------------------------------------------------------------
# 2. 패키지 디렉터리를 새로 만든다.
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$package_root = (Resolve-Path -LiteralPath $Destination).Path

# ---------------------------------------------------------------------------
# 3. 헤더.
# ---------------------------------------------------------------------------
$include_target = Join-Path $package_root 'include'
New-Item -ItemType Directory -Force -Path $include_target | Out-Null
$include_source = Join-Path $skia_root 'include'
foreach ($item in Get-ChildItem -LiteralPath $include_source -Force) {
    if ($item.PSIsContainer -and $item.Name -eq 'third_party' -and -not $IncludeVendorHeaders) {
        continue
    }
    Copy-Item -LiteralPath $item.FullName -Destination $include_target -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $package_root 'modules') | Out-Null
Copy-Item -LiteralPath (Join-Path $skia_root 'modules\skcms') `
    -Destination (Join-Path $package_root 'modules\skcms') -Recurse -Force
Write-Output 'headers        : include, modules/skcms'

# ---------------------------------------------------------------------------
# 4. 산출물.
# ---------------------------------------------------------------------------
$configuration_records = [ordered]@{}
foreach ($build in $builds) {
    $target = Join-Path $package_root ('out\skia-ui-{0}' -f $build.name.ToLowerInvariant())
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -LiteralPath $build.arguments -Destination $target -Force

    $files = [ordered]@{}
    foreach ($component in ($build.required | Sort-Object)) {
        $source = Join-Path $build.directory $component
        Copy-Item -LiteralPath $source -Destination $target -Force
        $files[$component] = [ordered]@{
            size   = (Get-Item -LiteralPath $source).Length
            sha256 = Get-FileHashText -path $source
        }
    }
    $configuration_records[$build.name] = [ordered]@{
        args_sha256 = Get-FileHashText -path $build.arguments
        files       = $files
    }
    $total = ($build.required | ForEach-Object { (Get-Item -LiteralPath (Join-Path $build.directory $_)).Length } |
        Measure-Object -Sum).Sum
    Write-Output ('libraries      : {0,-8} {1,3} files, {2:N1} MB' -f $build.name, $build.required.Count, ($total / 1MB))
}

# ---------------------------------------------------------------------------
# 5. 고지.
# ---------------------------------------------------------------------------
Copy-Item -LiteralPath (Join-Path $skia_root 'LICENSE') -Destination $package_root -Force

$notices = [System.Collections.Generic.List[hashtable]]::new()
foreach ($entry in $common_notices) { $notices.Add($entry) }
$rust_document = ''
if ($png_codec -eq 'rust') {
    $external_root = Resolve-RustLicenseRoot
    Write-Output "rust notices   : $external_root"
    foreach ($entry in (Get-RustCrateNotice -external_root $external_root)) { $notices.Add($entry) }
    $rust_document = Copy-RustRuntimeNotice -external_root $external_root -package_root $package_root
}
else {
    foreach ($entry in $libpng_notices) { $notices.Add($entry) }
}

$missing = @($notices | Where-Object { -not (Test-Path -LiteralPath $_.path -PathType Leaf) })
if ($missing) {
    throw @"
A third-party licence file is missing:
  $(($missing | ForEach-Object { $_.path }) -join "`n  ")
The externals junctions are made by build_skia.ps1, so build Skia first.
"@
}

$notice_text = [System.Text.StringBuilder]::new()
[void]$notice_text.AppendLine('# Third-party notices')
[void]$notice_text.AppendLine()
[void]$notice_text.AppendLine('이 패키지의 정적 라이브러리에 들어간 제3자 구성요소의 라이선스 원문이다.')
[void]$notice_text.AppendLine('원문은 Skia 소스 트리와 그 external, 그리고 rust 갈래의 경우 Bazel이 받아 둔')
[void]$notice_text.AppendLine('crate에서 그대로 읽었다.')
[void]$notice_text.AppendLine()
[void]$notice_text.AppendLine('이 패키지는 Google과 무관한 비공식 빌드다. Skia의 BSD-3-Clause 3항에 따라')
[void]$notice_text.AppendLine('저작권자와 기여자의 이름을 이 배포물의 홍보에 쓰지 않는다.')
[void]$notice_text.AppendLine()
[void]$notice_text.AppendLine('Skia 소스에는 이 저장소의 패치가 적용되어 있을 수 있다 (VERSION.json의 patches).')
if ($png_codec -eq 'rust') {
    [void]$notice_text.AppendLine('rust 갈래의 `png` crate에는 Skia의 captured-chunks.patch가 적용되어 있다.')
    [void]$notice_text.AppendLine(
        "Rust 표준 라이브러리(MIT OR Apache-2.0)의 고지는 ``$rust_document`` 에 있다.")
}

foreach ($entry in $notices) {
    [void]$notice_text.AppendLine()
    [void]$notice_text.AppendLine('----------------------------------------')
    [void]$notice_text.AppendLine("Component: $($entry.name)")
    [void]$notice_text.AppendLine('----------------------------------------')
    [void]$notice_text.AppendLine()
    [void]$notice_text.AppendLine((Get-Content -Raw -LiteralPath $entry.path))
}
$notice_path = Join-Path $package_root 'NOTICE.md'
Set-Content -LiteralPath $notice_path -Value $notice_text.ToString() -Encoding UTF8
Write-Output ('notices        : {0} components -> NOTICE.md' -f $notices.Count)

# ---------------------------------------------------------------------------
# 6. VERSION.json.
# ---------------------------------------------------------------------------
$skia_commit = ''
& git -C $skia_root rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $skia_commit = (& git -C $skia_root rev-parse HEAD).Trim()
}
$milestone = ''
$milestone_file = Join-Path $skia_root 'include\core\SkMilestone.h'
if (Test-Path -LiteralPath $milestone_file -PathType Leaf) {
    if ((Get-Content -Raw -LiteralPath $milestone_file) -match 'SK_MILESTONE\s+(\d+)') {
        $milestone = $Matches[1]
    }
}
$patches = @()
if ($png_codec -eq 'rust') {
    $patches = @(
        'skia-152-bazel-rust-windows-outputs.patch',
        'skia-152-bazel-rust-windows-debug-crt.patch')
}

$version = [ordered]@{
    schema                 = 1
    packaged_at            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    skia                   = [ordered]@{
        commit    = $skia_commit
        milestone = $milestone
        patches   = $patches
    }
    png_codec              = $png_codec
    target                 = 'win-x64'
    include_vendor_headers = [bool]$IncludeVendorHeaders
    configurations         = $configuration_records
}
Set-Content -LiteralPath (Join-Path $package_root 'VERSION.json') `
    -Value ($version | ConvertTo-Json -Depth 8) -Encoding UTF8

# ---------------------------------------------------------------------------
# 7. 압축 (선택).
# ---------------------------------------------------------------------------
$package_size = (Get-ChildItem -LiteralPath $package_root -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Output ''
Write-Output ('Package: {0} ({1:N1} MB)' -f $package_root, ($package_size / 1MB))

if ($Archive) {
    $suffix = if ($skia_commit) { $skia_commit.Substring(0, 12) } else { 'unknown' }
    $flavour = ($configurations | ForEach-Object { $_.ToLowerInvariant() }) -join '-'
    # png 갈래는 이름에 넣지 **않는다** — 발행하는 것은 rust 코덱 갈래 하나뿐이고
    # (skia-ui의 SKIA_UI_SKIA_REQUIRED_ARGUMENTS가 그것을 요구한다), 소비자에게
    # 고를 것이 없는 값을 파일 이름에 담아 봐야 "Rust로 빌드한 Skia"로 오해될 뿐이다.
    #
    # libpng 갈래는 물러설 자리로만 남아 있다. 그쪽으로 만들면 이름이 갈려야 한다 —
    # 같은 Skia commit에서 서로 링크 호환되지 않는 두 패키지가 나오기 때문이다.
    $codec_part = if ($png_codec -eq 'rust') { '' } else { "-$png_codec" }
    $archive_name = 'skia-prep-{0}-win-x64{1}-{2}.zip' -f $suffix, $codec_part, $flavour
    $archive_path = Join-Path (Split-Path -Parent $package_root) $archive_name
    if (Test-Path -LiteralPath $archive_path) {
        Remove-Item -LiteralPath $archive_path -Force
    }
    Compress-Archive -Path (Join-Path $package_root '*') -DestinationPath $archive_path -CompressionLevel Optimal
    $archive_size = (Get-Item -LiteralPath $archive_path).Length
    Write-Output ('Archive: {0} ({1:N1} MB)' -f $archive_path, ($archive_size / 1MB))
    Write-Output ('SHA-256: {0}' -f (Get-FileHashText -path $archive_path))
}
