# 두 Skia 빌드를 같은 자리에서 재어 맞대어 본다.
#
# 도구사슬을 바꾸는 것이 실제로 무엇을 바꾸는지 재는 것이 목적이다. 재는 것은 셋이다.
#   1. 실제로 고른 SIMD 경로 (SkOpts의 래스터 파이프라인 처리 폭)
#   2. 시간 (디코딩·cubic 축소)
#   3. 결과 (색상·알파 처리의 픽셀 값)
#
# **재는 프로그램(tools/skia_probe.cpp)은 언제나 MSVC로 컴파일한다.** 소비자가
# MSVC이기 때문이다. 그러므로 이 스크립트가 통과하는 것은 성능 비교인 동시에
# clang-cl로 세운 Skia와 MSVC 소비자 사이의 호환성 검사다 — CRT도, C++ ABI도,
# 실제 런타임 동작도 여기서 함께 걸린다.
#
#   scripts\bench_skia.ps1 -Baseline '-msvc' -Candidate ''
#
# 두 인자는 build_skia.ps1의 -OutputSuffix와 같은 값이다.

[CmdletBinding()]
param(
    [string]$SkiaRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    # 맞댈 두 산출 디렉터리의 접미사다. build_skia.ps1 -OutputSuffix와 짝이다.
    [string]$Baseline = '-msvc',
    [string]$Candidate = '',
    [string]$WorkDirectory,
    [int]$Repetitions = 5,
    # 두 빌드를 번갈아 도는 횟수다. 아래 실행 구간의 주석에 이유가 있다.
    [int]$Rounds = 3,
    # 재는 프로세스를 묶어 둘 논리 코어의 비트마스크다. 0이면 묶지 않는다.
    # P코어와 E코어가 섞인 CPU에서 이것을 주면 편차가 크게 줄어든다 — 이를테면
    # 논리 코어 2번 하나에 묶으려면 4(=1 shl 2)를 준다. 어느 번호가 P코어인지는
    # 기계마다 다르므로 기본값을 두지 않는다.
    [long]$AffinityMask = 0,
    # 채널 하나가 어긋나도 좋은 최대치다. 2인 이유는 Skia 자신에게 있다.
    #
    # scalar 모드에서 Skia는 lowp(8비트 고정소수) 스테이지를 **아예 만들지 않고**
    # 전부 highp(float)로 돌린다 — src/opts/SkRasterPipeline_opts.h가 그렇게
    # 적어 두었다("We don't bother generating the lowp stages ... in scalar mode
    # (MSVC, old clang, etc...)"). 벡터 코드에서는 그 lowp가 살아나고, 그쪽의
    # div255가 "never wrong by more than 1"인 근사다. 프리멀티와 SrcOver처럼
    # 그 연산이 두 번 겹치는 자리에서 최대 2가 난다.
    #
    # 곧 이것은 도구사슬이 낸 오차가 아니라 **Skia가 벡터 경로에서 늘 내는 값**이다.
    # AVX2를 지원하는 기계와 SSE2뿐인 기계가 같은 실행 파일에서 이미 이만큼 갈린다
    # (SkOpts::Init의 실행 시점 판정). 그보다 크게 어긋나는 것은 다른 이야기다.
    [int]$MaxChannelDelta = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot
if (-not $SkiaRoot) {
    $SkiaRoot = Join-Path $repository_root 'third_party\skia'
}
$skia_root = (Resolve-Path -LiteralPath $SkiaRoot).Path
$source = Join-Path $repository_root 'tools\skia_probe.cpp'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "The probe source was not found: $source"
}
if (-not $WorkDirectory) {
    $WorkDirectory = Join-Path $repository_root 'build\bench'
}
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$work = (Resolve-Path -LiteralPath $WorkDirectory).Path
$assets = Join-Path $work 'assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null

# Skia가 내는 정적 라이브러리다. verify_skia_root.ps1의 목록과 같다.
$components = @(
    'skia.lib', 'skcms.lib', 'spirv_cross.lib', 'd3d12allocator.lib',
    'libjpeg.lib', 'libjpeg12.lib', 'libjpeg16.lib',
    'libwebp.lib', 'libwebp_sse41.lib', 'wuffs.lib')
$libpng_components = @('libpng.lib', 'zlib.lib')
$rust_png_components = @('librust_png_ffi_rs.a', 'libcxx_cc.a')
# Skia의 BUILD.gn이 Windows에서 libs로 다는 것들이다.
$system_libraries = @(
    'Ole32.lib', 'OleAut32.lib', 'User32.lib', 'Usp10.lib', 'FontSub.lib', 'Gdi32.lib',
    'd3d12.lib', 'dxgi.lib', 'd3dcompiler.lib')
# rust 갈래만 요구한다. rustc가 std에 심는 #[link] 지시가 정적 아카이브를 직접
# 링크할 때는 링커에 닿지 않기 때문이다 (docs/skia-build.md 5.3).
$rust_system_libraries = @('ws2_32.lib', 'userenv.lib', 'ntdll.lib')

# MSVC 환경이다. cl.exe와 link.exe는 vcvars가 깔아 주는 환경 변수 없이는 돌지 않는다.
function Import-MsvcEnvironment {
    if (Get-Command cl -CommandType Application -ErrorAction SilentlyContinue) {
        return
    }
    $program_files = ${env:ProgramFiles(x86)}
    $vswhere = Join-Path $program_files 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'vswhere.exe was not found, so the MSVC environment cannot be located.'
    }
    $installation = & $vswhere -products '*' -prerelease -latest `
        -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' `
        -property installationPath |
        Select-Object -First 1
    if (-not $installation) {
        throw 'No Visual Studio installation with the MSVC toolset was found.'
    }
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
        throw "vcvars64.bat was not found: $vcvars"
    }
    # 자식 cmd에서 환경을 걷어 이 세션에 옮긴다.
    $lines = & cmd /c "call `"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $lines) {
        $index = $line.IndexOf('=')
        if ($index -gt 0) {
            Set-Item -Path ('env:' + $line.Substring(0, $index)) -Value $line.Substring($index + 1)
        }
    }
    Write-Output "msvc           : $installation"
}

function Get-PngCodec {
    param([string]$directory)

    $arguments_file = Join-Path $directory 'args.gn'
    if (-not (Test-Path -LiteralPath $arguments_file -PathType Leaf)) {
        throw @"
The Skia build was not found: $directory
Build it first with scripts\build_skia.ps1 (-OutputSuffix picks the directory).
"@
    }
    $text = Get-Content -Raw -LiteralPath $arguments_file
    if ($text -match 'skia_use_rust_png_decode\s*=\s*true') { return 'rust' }
    return 'libpng'
}

# 한 산출 디렉터리에 링크한 probe를 세운다.
function Build-Probe {
    param([string]$label, [string]$directory)

    $codec = Get-PngCodec -directory $directory
    $libraries = $components + $(if ($codec -eq 'rust') { $rust_png_components } else { $libpng_components })
    foreach ($component in $libraries) {
        if (-not (Test-Path -LiteralPath (Join-Path $directory $component) -PathType Leaf)) {
            throw "A Skia build output is missing: $directory\$component"
        }
    }

    $object_directory = Join-Path $work ('obj-' + $label)
    if (Test-Path -LiteralPath $object_directory) {
        Remove-Item -LiteralPath $object_directory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $object_directory | Out-Null
    $executable = Join-Path $work ('skia_probe-' + $label + '.exe')

    # 소비자와 같은 조건으로 컴파일한다. Skia의 공개 헤더가 요구하는 것이
    # /std:c++20과 /EHsc 없음(_HAS_EXCEPTIONS=0)이다.
    $crt = if ($Configuration -eq 'Debug') { '/MTd' } else { '/MT' }
    $arguments = @(
        '/nologo', '/c', $crt, '/std:c++20', '/EHsc', '/utf-8', '/bigobj', '/W3',
        # Skia 자신의 Windows 빌드가 끄는 것과 같다. 공개 헤더가 int -> float
        # 축소를 곳곳에서 하므로, 끄지 않으면 경고가 수백 줄 쏟아진다.
        # /wd5030은 Skia 공개 헤더의 [[clang::reinitializes]]다. MSVC가 모르는
        # 특성이라 경고가 나지만, 무시하는 것이 정확한 처리다.
        '/wd4244', '/wd4267', '/wd5030',
        "/Fo$object_directory\", "/I$skia_root")
    if ($Configuration -eq 'Debug') {
        $arguments += @('/Od', '/Zi', "/Fd$object_directory\probe.pdb")
    }
    else {
        $arguments += @('/O2', '/DNDEBUG')
    }
    # Skia의 공개 헤더는 빌드할 때 켠 기능을 스스로 알지 못한다.
    # SK_DIRECT3D는 args.gn의 skia_use_direct3d와 짝이다.
    $arguments += @('/DSK_DIRECT3D', '/DSK_GANESH')
    $arguments += $source

    # cl과 link이 내는 것은 화면에만 보낸다. 이 함수의 반환값은 실행 파일 경로
    # 하나이며, 여기 섞이면 그 경고 줄까지 경로로 돌아간다.
    & cl @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cl.exe failed for $label."
    }

    $link_arguments = @('/nologo', "/OUT:$executable", "$object_directory\skia_probe.obj")
    foreach ($component in $libraries) {
        $link_arguments += (Join-Path $directory $component)
    }
    $link_arguments += $system_libraries
    if ($codec -eq 'rust') {
        $link_arguments += $rust_system_libraries
    }
    if ($Configuration -eq 'Debug') {
        $link_arguments += '/DEBUG'
    }
    & link @link_arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "link.exe failed for $label. That is the compatibility test, so read the errors above."
    }
    return $executable
}

# raw RGBA 두 장을 채널 단위로 비교한다.
# 길이가 128 MB에 이르므로 PowerShell의 반복문으로는 재지 못한다.
Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class RawPixelCompare {
    public struct Result {
        public long Length;
        public long DifferingBytes;
        public int MaxDelta;
    }

    public static Result Compare(string left, string right) {
        Result result = new Result();
        using (FileStream a = File.OpenRead(left))
        using (FileStream b = File.OpenRead(right)) {
            if (a.Length != b.Length) {
                result.Length = -1;
                return result;
            }
            result.Length = a.Length;
            byte[] bufferA = new byte[1 << 20];
            byte[] bufferB = new byte[1 << 20];
            int read;
            while ((read = a.Read(bufferA, 0, bufferA.Length)) > 0) {
                int offset = 0;
                while (offset < read) {
                    offset += b.Read(bufferB, offset, read - offset);
                }
                for (int i = 0; i < read; i++) {
                    int delta = bufferA[i] - bufferB[i];
                    if (delta != 0) {
                        result.DifferingBytes++;
                        if (delta < 0) { delta = -delta; }
                        if (delta > result.MaxDelta) { result.MaxDelta = delta; }
                    }
                }
            }
        }
        return result;
    }
}
'@

function Invoke-Probe {
    param([string]$executable, [string]$output_directory)

    if (Test-Path -LiteralPath $output_directory) {
        Remove-Item -LiteralPath $output_directory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $output_directory | Out-Null

    # 재는 것은 전부 한 갈래(single thread)로 돈다. 그래서 이 프로세스가 어느 코어에
    # 놓이는지가 결과를 좌우한다 — P코어와 E코어가 섞인 요즘 CPU에서는 그것만으로
    # 두 배가 갈린다. 우선순위를 올리고, -AffinityMask를 준 경우 코어도 고정한다.
    # 그러지 않으면 같은 빌드를 두 번 잰 값이 40 %까지 흔들린다 (실측).
    $standard_output = Join-Path $output_directory 'probe.out'
    $standard_error = Join-Path $output_directory 'probe.err'
    $process = Start-Process -FilePath $executable `
        -ArgumentList @('--bench', "`"$assets`"", "`"$output_directory`"", $Repetitions) `
        -NoNewWindow -PassThru -RedirectStandardOutput $standard_output `
        -RedirectStandardError $standard_error
    try {
        $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        if ($AffinityMask) {
            $process.ProcessorAffinity = [System.IntPtr]$AffinityMask
        }
    }
    catch {
        # 프로세스가 이미 끝났거나 권한이 없으면 그대로 둔다. 재는 것은 성립한다.
        Write-Verbose "could not pin the probe: $_"
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath $standard_error -ErrorAction SilentlyContinue | Out-Host
        throw "The probe failed: $executable"
    }
    $lines = Get-Content -LiteralPath $standard_output
    $values = [ordered]@{}
    foreach ($line in $lines) {
        $index = "$line".IndexOf('=')
        if ($index -gt 0) {
            $values["$line".Substring(0, $index)] = "$line".Substring($index + 1)
        }
    }
    return $values
}

Import-MsvcEnvironment
$compiler = (& cl 2>&1 | Select-String 'Version' | Select-Object -First 1).Line.Trim()
Write-Output "cl.exe         : $compiler"
Write-Output "Configuration  : $Configuration"
Write-Output "Work directory : $work"
Write-Output ''

$builds = [ordered]@{}
foreach ($entry in @(@{ label = 'baseline'; suffix = $Baseline }, @{ label = 'candidate'; suffix = $Candidate })) {
    $directory = Join-Path $skia_root `
        ('out\skia-ui-{0}{1}' -f $Configuration.ToLowerInvariant(), $entry.suffix)
    Write-Output ("{0,-14} : {1}" -f $entry.label, $directory)
    $builds[$entry.label] = @{
        directory  = $directory
        executable = (Build-Probe -label $entry.label -directory $directory)
    }
}
Write-Output ''

# 자산은 한 번만 만든다. 두 빌드가 **같은 바이트**를 디코딩해야 하기 때문이다.
#
# 원본 png는 Skia가 아니라 tools/make_bench_source.py가 만든다. 어느 빌드로도
# 만들 수 없기도 하다 — 이 저장소의 args가 skia_use_rust_png_encode = true인데도
# SkPngRustEncoder가 아카이브에 들어가지 않는다 (docs/skia-build.md 5.5).
# jpeg와 webp만 그 png에서 파생시킨다.
if (-not (Test-Path -LiteralPath (Join-Path $assets 'source.png') -PathType Leaf)) {
    Write-Output 'assets         : generating source.png (python, no Skia)'
    $generator = Join-Path $repository_root 'tools\make_bench_source.py'
    $python = Get-Command -Name 'python' -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } |
        Select-Object -First 1
    if (-not $python) {
        throw 'A real Python 3 interpreter was not found; it makes the benchmark source image.'
    }
    & $python.Source $generator (Join-Path $assets 'source.png')
    if ($LASTEXITCODE -ne 0) {
        throw 'Generating source.png failed.'
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $assets 'source.jpg') -PathType Leaf)) {
    Write-Output 'assets         : deriving jpeg and webp'
    & $builds['baseline'].executable --emit-assets $assets
    if ($LASTEXITCODE -ne 0) {
        throw 'Deriving the benchmark assets failed.'
    }
}
else {
    Write-Output 'assets         : reusing'
}
Write-Output ''

# 두 빌드를 **번갈아** 돌린다.
#
# 한쪽을 다 돌고 다른 쪽을 돌면, 그 사이에 기계가 변한 만큼이 그대로 두 빌드의
# 차이로 읽힌다 (열, 다른 프로세스, 파일 캐시). 실측에서 같은 빌드의 같은 항목이
# 두 번 재는 사이에 40 %까지 흔들렸다. 번갈아 돌리고 회차마다 가장 빠른 값을
# 남기면 그 흔들림이 두 쪽에 고르게 실린다.
#
# 대푯값으로 중앙값이 아니라 최소값을 쓰는 이유도 같다. 방해는 시간을 늘리기만
# 하므로, 가장 빠른 값이 "방해가 가장 적었을 때의 이 코드"에 가장 가깝다.
$results = [ordered]@{}
for ($round = 1; $round -le $Rounds; $round++) {
    foreach ($label in @($builds.Keys)) {
        Write-Output "running        : $label (round $round of $Rounds)"
        $values = Invoke-Probe -executable $builds[$label].executable `
            -output_directory (Join-Path $work ('pixels-' + $label))
        if (-not $results.Contains($label)) {
            $results[$label] = $values
            continue
        }
        $previous = $results[$label]
        foreach ($key in @($values.Keys)) {
            if ($key -like 'time.*' -and $previous.Contains($key)) {
                $previous[$key] = [Math]::Min([double]$previous[$key], [double]$values[$key])
            }
            else {
                $previous[$key] = $values[$key]
            }
        }
    }
}
Write-Output ''

$left = $results['baseline']
$right = $results['candidate']

Write-Output '-- SIMD path'
foreach ($key in @('skia.raster_pipeline_highp_stride', 'skia.raster_pipeline_lowp_stride')) {
    Write-Output ("{0,-36} {1,10} -> {2,10}" -f $key.Replace('skia.', ''), $left[$key], $right[$key])
}

Write-Output ''
Write-Output "-- Time (fastest of $Rounds x $Repetitions runs, ms)"
Write-Output ("{0,-36} {1,10} {2,10} {3,10}" -f 'case', 'baseline', 'candidate', 'speedup')
foreach ($key in @($left.Keys | Where-Object { $_ -like 'time.*.best_ms' })) {
    $name = $key -replace '^time\.', '' -replace '\.best_ms$', ''
    $a = [double]$left[$key]
    $b = [double]$right[$key]
    $ratio = if ($b -gt 0) { $a / $b } else { 0 }
    Write-Output ("{0,-36} {1,10:N2} {2,10:N2} {3,9:N2}x" -f $name, $a, $b, $ratio)
}

Write-Output ''
Write-Output '-- Pixels'
Write-Output ("{0,-36} {1,14} {2,10} {3,9}" -f 'image', 'bytes', 'differing', 'max delta')
$pixel_failures = 0
foreach ($key in @($left.Keys | Where-Object { $_ -like 'pixels.*.hash' })) {
    $name = $key -replace '^pixels\.', '' -replace '\.hash$', ''
    $comparison = [RawPixelCompare]::Compare(
        (Join-Path $work ('pixels-baseline\' + $name + '.raw')),
        (Join-Path $work ('pixels-candidate\' + $name + '.raw')))
    if ($comparison.Length -lt 0) {
        Write-Output ("{0,-36} {1,14}" -f $name, 'size mismatch')
        $pixel_failures++
        continue
    }
    Write-Output ("{0,-36} {1,14:N0} {2,10:N0} {3,9}" -f $name, $comparison.Length,
        $comparison.DifferingBytes, $comparison.MaxDelta)
    if ($comparison.MaxDelta -gt $MaxChannelDelta) {
        $pixel_failures++
    }
}

Write-Output ''
if ($pixel_failures -gt 0) {
    Write-Output ("Pixel comparison failed: {0} image(s) differ by more than {1} level(s)." -f `
            $pixel_failures, $MaxChannelDelta)
    exit 1
}
Write-Output ("Pixel comparison passed: no channel differs by more than {0} level(s)." -f `
        $MaxChannelDelta)
