# 사용자가 빌드한 Skia가 skia-ui와 맞는지 검사한다.
# CMake의 configure 검사와 같은 판정을 사람이 먼저 돌려볼 수 있게 하는 것이 목적이다.
# docs/skia-build.md를 본다.

[CmdletBinding()]
param(
    [string]$SkiaRoot,
    [string[]]$Configurations = @('Debug', 'Release')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot
if (-not $SkiaRoot) {
    $SkiaRoot = Join-Path $repository_root 'third_party\skia'
}

# CMakeLists.txt의 SKIA_UI_SKIA_COMPONENTS와 같은 목록이다 (파일 이름 그대로).
$components = @(
    'skia.lib', 'skcms.lib', 'spirv_cross.lib', 'd3d12allocator.lib',
    'libjpeg.lib', 'libjpeg12.lib', 'libjpeg16.lib',
    'libwebp.lib', 'libwebp_sse41.lib', 'wuffs.lib')
# png 코덱에 따라 갈리는 산출물이다.
$libpng_components = @('libpng.lib', 'zlib.lib')
$rust_png_components = @('librust_png_ffi_rs.a', 'libcxx_cc.a')
# 이 저장소가 고정한 Skia의 밀번이다 (docs/skia-build.md 7).
# rust png 갈래는 152 아래에서 아예 서지 않는다 (5.3).
$minimum_milestone = 152
# CMakeLists.txt의 SKIA_UI_SKIA_REQUIRED_ARGUMENTS와 같은 목록이다.
# png은 둘 중 하나라 여기 없다 — 아래에서 따로 판정한다.
$required_arguments = @(
    @{ name = 'skia_use_direct3d'; reason = 'required by the renderer' },
    @{ name = 'skia_use_libjpeg_turbo_decode'; reason = 'jpeg decoding' },
    @{ name = 'skia_use_libwebp_decode'; reason = 'webp decoding, still and animated' },
    @{ name = 'skia_use_wuffs'; reason = 'gif decoding' })
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Result {
    param([string]$item, [bool]$ok, [string]$detail)

    $mark = if ($ok) { 'OK  ' } else { 'FAIL' }
    Write-Output ("[{0}] {1,-42} {2}" -f $mark, $item, $detail)
    if (-not $ok) {
        $script:failures.Add($item)
    }
}

Write-Output "Skia root: $SkiaRoot"
Write-Output ''

$header = Join-Path $SkiaRoot 'include\core\SkCanvas.h'
Add-Result 'source tree' (Test-Path -LiteralPath $header) $header

# 밀번 확인. 이 저장소가 고정한 것과 다른 Skia는 API가 어긋날 수 있다.
$milestone_header = Join-Path $SkiaRoot 'include\core\SkMilestone.h'
if (Test-Path -LiteralPath $milestone_header) {
    $milestone_text = Get-Content -Raw -LiteralPath $milestone_header
    $milestone = if ($milestone_text -match 'SK_MILESTONE\s+(\d+)') { [int]$Matches[1] } else { 0 }
    Add-Result 'milestone' ($milestone -ge $minimum_milestone) `
        "SK_MILESTONE $milestone (needs $minimum_milestone or newer)"
}

function Find-Dumpbin {
    $command = Get-Command dumpbin -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $program_files = ${env:ProgramFiles(x86)}
    if (-not $program_files) {
        return ''
    }
    $vswhere = Join-Path $program_files 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        return ''
    }
    $installations = & $vswhere -products '*' -prerelease -property installationPath
    foreach ($installation in $installations) {
        $tools_root = Join-Path $installation 'VC\Tools\MSVC'
        $candidate = Get-ChildItem -LiteralPath $tools_root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($candidate) {
            return $candidate
        }
    }
    return ''
}

$dumpbin = Find-Dumpbin

foreach ($configuration in $Configurations) {
    Write-Output ''
    $directory = Join-Path $SkiaRoot ('out\skia-ui-{0}' -f $configuration.ToLowerInvariant())
    Write-Output "-- $configuration : $directory"

    # png 코덱을 먼저 정한다 — 요구할 산출물이 그것으로 갈린다.
    $arguments_file = Join-Path $directory 'args.gn'
    $arguments_text = ''
    $png_codec = ''
    if (Test-Path -LiteralPath $arguments_file) {
        $arguments_text = Get-Content -Raw -LiteralPath $arguments_file
        $uses_rust = $arguments_text -match 'skia_use_rust_png_decode\s*=\s*true'
        $uses_libpng = $arguments_text -match 'skia_use_libpng_decode\s*=\s*true'
        if ($uses_rust -and $uses_libpng) {
            $png_codec = 'both'
        }
        elseif ($uses_rust) {
            $png_codec = 'rust'
        }
        elseif ($uses_libpng) {
            $png_codec = 'libpng'
        }
    }

    $expected = $components
    if ($png_codec -eq 'rust') {
        $expected = $components + $rust_png_components
    }
    elseif ($png_codec -eq 'libpng') {
        $expected = $components + $libpng_components
    }

    foreach ($component in $expected) {
        $library = Join-Path $directory $component
        $exists = Test-Path -LiteralPath $library
        $detail = if ($exists) {
            '{0:N1} MB' -f ((Get-Item -LiteralPath $library).Length / 1MB)
        }
        else {
            'missing'
        }
        Add-Result "$configuration/$component" $exists $detail
    }

    if ($arguments_text) {
        foreach ($requirement in $required_arguments) {
            Add-Result "$configuration/$($requirement.name)" `
                ($arguments_text -match ('{0}\s*=\s*true' -f $requirement.name)) $requirement.reason
        }
        # png은 둘 중 정확히 하나여야 한다.
        # rust 쪽만 APNG(움직이는 png)를 읽는다.
        $png_detail = switch ($png_codec) {
            'libpng' { 'libpng — APNG decodes as a still image' }
            'rust' { 'rust — APNG animates' }
            'both' { 'both decoders are enabled; pick one' }
            default { 'no png decoder' }
        }
        Add-Result "$configuration/png codec" ($png_codec -in @('libpng', 'rust')) $png_detail
    }
    else {
        Add-Result "$configuration/args.gn" $false 'missing'
    }

    # 정적 CRT가 skia-ui와 어긋나면 LNK2038로 드러난다.
    # 미리 잡는다.
    $library = Join-Path $directory 'skia.lib'
    if ($dumpbin -and (Test-Path -LiteralPath $library)) {
        $expected = if ($configuration -eq 'Debug') { 'LIBCMTD' } else { 'LIBCMT' }
        $directives = & $dumpbin /directives $library 2>$null |
            Select-String 'DEFAULTLIB' |
            ForEach-Object { $_.Line.Trim() } |
            Sort-Object -Unique
        $matched = $directives | Where-Object { $_ -match "/DEFAULTLIB:$expected$" }
        Add-Result "$configuration/static CRT" ([bool]$matched) "expects /DEFAULTLIB:$expected"
    }

    # Bazel의 Windows C++ toolchain은 dbg에서도 기본이 release CRT다. rust png
    # archive 안의 bridge object까지 검사하지 않으면 skia.lib 검사를 통과한 뒤
    # 소비자 링크에서야 LNK2038이 난다.
    if ($dumpbin -and $png_codec -eq 'rust') {
        $expected_iterator = if ($configuration -eq 'Debug') { '2' } else { '0' }
        $expected_runtime = if ($configuration -eq 'Debug') {
            'MTd_StaticDebug'
        }
        else {
            'MT_StaticRelease'
        }
        foreach ($component in $rust_png_components) {
            $library = Join-Path $directory $component
            if (-not (Test-Path -LiteralPath $library)) {
                continue
            }
            $directives = & $dumpbin /directives $library 2>$null |
                Select-String 'FAILIFMISMATCH' |
                ForEach-Object { $_.Line.Trim() } |
                Sort-Object -Unique
            $iterator_ok = $directives |
                Where-Object { $_ -match "_ITERATOR_DEBUG_LEVEL=$expected_iterator$" }
            $runtime_ok = $directives |
                Where-Object { $_ -match "RuntimeLibrary=$expected_runtime$" }
            Add-Result "$configuration/$component C++ ABI" `
                ([bool]$iterator_ok -and [bool]$runtime_ok) `
                "expects iterator $expected_iterator, $expected_runtime"
        }
    }
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output "Skia verification failed: $($failures.Count) item(s)."
    Write-Output 'Build Skia as described in docs/skia-build.md.'
    exit 1
}

Write-Output 'Skia verification passed.'
