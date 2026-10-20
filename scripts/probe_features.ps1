# 패키지의 기능을 하나씩 떼어 링크하고, 돌리고, 실행 파일의 크기를 잰다.
#
# 이 패키지의 원칙은 "기능을 쓰지 않는 소비자는 링크도 실행 파일 크기도 그대로"다.
# tools/feature_probe.cpp를 기능마다 다른 매크로로 컴파일하고, third_party/features.json에
# 적힌 그 기능의 아카이브**만** 더해 링크한다. 그래서 여기서 링크가 서는 것이 곧
# "그 목록이면 충분하다"는 확인이고, 링크 맵에 남은 표지(HarfBuzz·expat·AVIF·인코더)가
# "부르지 않은 것은 들어오지 않았다"는 확인이다.
#
#   scripts\probe_features.ps1 -PackageRoot build\skia-package -Configuration Release `
#       -BaselineRoot <r2 패키지>
#
# -BaselineRoot를 주면 base 갈래를 그 패키지에도 링크해 크기를 맞댄다.
#
# Windows(win-x64)에서는 소비자와 같이 **MSVC**로 컴파일하고 돌린다. Linux에서
# -Target android-arm64로 부르면 NDK clang과 lld로 세우기만 한다 — 실행은 adb로
# 기기에서 한다 (docs/skia-build.md 8.6).

[CmdletBinding()]
param(
    [string]$PackageRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('win-x64', 'android-arm64')]
    [string]$Target = 'win-x64',
    [string]$BaselineRoot,
    [string]$WorkDirectory,
    [string]$NdkPath,
    [string[]]$Only,
    # 목록에서 빼고 링크해 본다. 그 아카이브가 정말 필요한지 확인할 때 쓴다.
    [string[]]$Without
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot
$is_android = $Target -like 'android-*'
if (-not $PackageRoot) {
    $PackageRoot = Join-Path $repository_root 'build\skia-package'
}
$package_root = (Resolve-Path -LiteralPath $PackageRoot).Path
if (-not $WorkDirectory) {
    $WorkDirectory = Join-Path $repository_root ('build\features-{0}-{1}' -f $Target, $Configuration.ToLowerInvariant())
}
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$work = (Resolve-Path -LiteralPath $WorkDirectory).Path
$source = Join-Path $repository_root 'tools\feature_probe.cpp'
$features = (Get-Content -Raw -LiteralPath (Join-Path $repository_root 'third_party\features.json') |
        ConvertFrom-Json).features

# 갈래마다 켜는 기능과 매크로다. 앞의 일곱이 하나씩 켠 것, 뒤의 둘이 text와 겹친 것이다.
$base_variant = @{ features = @('core'); defines = @() }
$variants = [ordered]@{
    'base'         = $base_variant
    'png_encode'   = @{ features = @('core'); defines = @('PROBE_PNG_ENCODE') }
    'jpeg_encode'  = @{ features = @('core'); defines = @('PROBE_JPEG_ENCODE') }
    'svg'          = @{ features = @('core', 'svg'); defines = @('PROBE_SVG') }
    'text'         = @{ features = @('core', 'text'); defines = @('PROBE_TEXT') }
    'avif'         = @{ features = @('core', 'avif'); defines = @('PROBE_AVIF') }
    'skottie'      = @{ features = @('core', 'skottie'); defines = @('PROBE_SKOTTIE') }
    'svg_text'     = @{ features = @('core', 'svg', 'text'); defines = @('PROBE_SVG', 'PROBE_TEXT') }
    'skottie_text' = @{ features = @('core', 'skottie', 'text'); defines = @('PROBE_SKOTTIE', 'PROBE_TEXT') }
}
# 기존 GPU 백엔드다. Windows에서만 — Android의 Vulkan은 tools/android_probe.cpp가 기기에서 본다.
if (-not $is_android) {
    $variants['d3d'] = @{ features = @('core'); defines = @('PROBE_D3D') }
}
if ($Only) {
    foreach ($name in @($variants.Keys)) {
        if ($name -notin $Only) {
            $variants.Remove($name)
        }
    }
}

# 링크 맵에서 찾는 표지다. 그 기능을 부르지 않은 갈래에 나오면 원칙이 깨진 것이다.
$markers = [ordered]@{
    'harfbuzz'   = 'hb_shape_full'
    'expat'      = 'XML_ParserCreate'
    'avif'       = 'avifDecoderCreate'
    'png encode' = 'SkPngRustEncoder'
    'jpeg encode' = 'jpeg_start_compress'
    'svg'        = 'SkSVGDOM'
    'skottie'    = 'skottie'
}

# 텍스트 기능의 공개 정의다. skshaper·skunicode의 public_config가 붙이는 것과 같고,
# SkShaper.h와 FactoryHelpers.h가 이것으로 선언을 가른다. 기능을 켜는 소비자만 준다.
$text_defines = @('SK_SHAPER_PRIMITIVE_AVAILABLE', 'SK_SHAPER_HARFBUZZ_AVAILABLE',
    'SK_SHAPER_UNICODE_AVAILABLE', 'SK_UNICODE_AVAILABLE', 'SK_UNICODE_ICU_IMPLEMENTATION')

function Import-MsvcEnvironment {
    if (Get-Command cl -CommandType Application -ErrorAction SilentlyContinue) {
        return
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installation = & $vswhere -products '*' -prerelease -latest `
        -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath |
        Select-Object -First 1
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    foreach ($line in (& cmd /c "call `"$vcvars`" >nul 2>&1 && set")) {
        $index = $line.IndexOf('=')
        if ($index -gt 0) {
            Set-Item -Path ('env:' + $line.Substring(0, $index)) -Value $line.Substring($index + 1)
        }
    }
}

function Get-Libraries {
    param([string[]]$names)

    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        foreach ($library in $features.$name.libraries.$Target) {
            if (-not $list.Contains($library)) {
                $list.Add($library)
            }
        }
    }
    # core가 맨 앞이다 (libskia.a가 먼저). rust 아카이브는 맨 뒤로 보낸다 — 그 안에 담긴
    # Skia 오브젝트보다 libskia.a·skia.lib의 것이 먼저 쓰이게 한다 (docs/skia-build.md 8.5).
    $list = [System.Collections.Generic.List[string]]@($list | Where-Object { $_ -notin $Without })
    $rust = @($list | Where-Object { $_ -like 'librust_png_ffi_rs.a' -or $_ -like 'libcxx_cc.a' })
    return @($list | Where-Object { $_ -notin $rust }) + $rust
}

function Get-SystemLibraries {
    param([string[]]$names)

    return @($names | ForEach-Object { $features.$_.system_libraries.$Target } | Select-Object -Unique)
}

if ($is_android) {
    if (-not $NdkPath) {
        $NdkPath = Join-Path $HOME 'ndk/android-ndk-r27d'
    }
    $clang = Join-Path $NdkPath 'toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++'
    if (-not (Test-Path -LiteralPath $clang -PathType Leaf)) {
        throw "The NDK clang was not found: $clang"
    }
}
else {
    Import-MsvcEnvironment
}

function Build-Variant {
    param([string]$label, [string]$root, [hashtable]$variant, [switch]$AllowMultipleDefinition)

    $library_directory = Join-Path $root ('out\skia-ui-{0}' -f $Configuration.ToLowerInvariant())
    $libraries = Get-Libraries -names $variant.features
    foreach ($library in $libraries) {
        if (-not (Test-Path -LiteralPath (Join-Path $library_directory $library) -PathType Leaf)) {
            throw "$label needs $library, and it is not in $library_directory"
        }
    }
    $defines = @($variant.defines)
    if ('PROBE_TEXT' -in $defines) {
        $defines += $text_defines
    }
    $executable = Join-Path $work ('feature_probe-{0}{1}' -f $label, $(if ($is_android) { '' } else { '.exe' }))
    $map = Join-Path $work ('feature_probe-{0}.map' -f $label)
    $object_directory = Join-Path $work ('obj-' + $label)
    New-Item -ItemType Directory -Force -Path $object_directory | Out-Null

    if ($is_android) {
        $arguments = @('-std=c++20', '-fno-exceptions', '-DSK_GANESH', '-DSK_VULKAN', "-I$root",
            "-I$(Join-Path $repository_root 'tools')")
        $arguments += if ($Configuration -eq 'Debug') { @('-O0', '-g') } else { @('-O2', '-DNDEBUG') }
        $arguments += ($defines | ForEach-Object { "-D$_" })
        $arguments += @($source, '-o', $executable)
        $arguments += @($libraries | ForEach-Object { Join-Path $library_directory $_ })
        # 157 r1부터 rust 아카이브에 Skia·libc++ 오브젝트가 겹쳐 들지 않아 이 플래그 없이 링크된다
        # (pack_skia.ps1의 Get-RedundantRustMembers). 그 전의 패키지(기준선)만 준다.
        if ($AllowMultipleDefinition) {
            $arguments += '-Wl,--allow-multiple-definition'
        }
        $arguments += @("-Wl,-Map=$map", '-static-libstdc++')
        $arguments += @(Get-SystemLibraries -names $variant.features | ForEach-Object { "-l$_" })
        & $clang @arguments 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "clang failed for $label."
        }
        return @{ executable = $executable; map = $map }
    }

    $crt = if ($Configuration -eq 'Debug') { '/MTd' } else { '/MT' }
    # bench_skia.ps1과 같은 조건이다. /wd는 Skia 공개 헤더의 축소 변환과 clang 특성이다.
    $arguments = @('/nologo', '/c', $crt, '/std:c++20', '/EHsc', '/utf-8', '/bigobj', '/W3',
        '/wd4244', '/wd4267', '/wd5030', "/Fo$object_directory\", "/I$root",
        "/I$(Join-Path $repository_root 'tools')", '/DSK_DIRECT3D', '/DSK_GANESH')
    $arguments += if ($Configuration -eq 'Debug') { @('/Od', '/Zi', "/Fd$object_directory\probe.pdb") }
    else { @('/O2', '/DNDEBUG') }
    $arguments += ($defines | ForEach-Object { "/D$_" })
    $arguments += $source
    & cl @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cl.exe failed for $label."
    }
    $link_arguments = @('/nologo', "/OUT:$executable", "/MAP:$map",
        (Join-Path $object_directory 'feature_probe.obj'))
    $link_arguments += @($libraries | ForEach-Object { Join-Path $library_directory $_ })
    $link_arguments += @(Get-SystemLibraries -names $variant.features | ForEach-Object { "$_.lib" })
    if ($Configuration -eq 'Debug') {
        $link_arguments += '/DEBUG'
    }
    & link @link_arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "link.exe failed for $label - its archive list in third_party/features.json is not enough."
    }
    return @{ executable = $executable; map = $map }
}

$results = [System.Collections.Generic.List[object]]::new()
$failures = 0
$builds = [ordered]@{}
if ($BaselineRoot) {
    $builds['baseline'] = @{ root = (Resolve-Path -LiteralPath $BaselineRoot).Path; variant = $base_variant }
}
foreach ($name in $variants.Keys) {
    $builds[$name] = @{ root = $package_root; variant = $variants[$name] }
}

foreach ($label in $builds.Keys) {
    Write-Output "== $label"
    $built = Build-Variant -label $label -root $builds[$label].root -variant $builds[$label].variant `
        -AllowMultipleDefinition:($label -eq 'baseline')
    $map_text = Get-Content -Raw -LiteralPath $built.map
    $present = @($markers.Keys | Where-Object { $map_text.Contains($markers[$_]) })
    $status = 'built'
    if (-not $is_android) {
        & $built.executable | Out-Host
        $status = if ($LASTEXITCODE -eq 0) { 'passed' } else { 'FAILED' }
        if ($LASTEXITCODE -ne 0) {
            $failures++
        }
    }
    $results.Add([pscustomobject]@{
            variant  = $label
            size     = (Get-Item -LiteralPath $built.executable).Length
            status   = $status
            linked   = ($present -join ', ')
            archives = (Get-Libraries -names $builds[$label].variant.features).Count
        })
}

Write-Output ''
Write-Output ("{0} {1} - executable sizes" -f $Target, $Configuration)
$base_result = $results | Where-Object variant -eq 'base' | Select-Object -First 1
$base_size = if ($base_result) { $base_result.size } else { 0 }
foreach ($result in $results) {
    $delta = if ($base_size) { $result.size - $base_size } else { 0 }
    Write-Output ('{0,-13} {1,12:N0} {2,11} {3,-7} {4,2} archives  {5}' -f $result.variant, $result.size,
        $(if ($result.variant -eq 'base') { '' } else { '{0:+#,0;-#,0;0}' -f $delta }),
        $result.status, $result.archives, $result.linked)
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $work 'results.json') -Encoding UTF8
if ($failures -gt 0) {
    Write-Output "feature probes failed: $failures"
    exit 1
}
