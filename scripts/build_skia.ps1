# Skia를 손으로 1회 빌드하는 보조 스크립트다.
#
# 이 스크립트는 사용자가 직접 실행한다.
# CMake와 CTest는 절대 이 스크립트를 호출하지 않는다.
# 빌드 체계가 스스로 의존성을 취득하지 않는다는 것이 이 프로젝트의 전제이며, 그 경계가 바로 여기다.
# 자세한 내용은 docs/skia-build.md를 본다.
#
# 취득은 submodule과 gn·ninja 두 실행 파일로 끝난다.
# 두 실행 파일은 PATH에 없는 것이 보통이므로 알려진 로컬 경로를 먼저 훑는다.
# 그래도 없고 사람이 -FetchTools를 준 경우에만 Skia의 bin/fetch-gn·bin/fetch-ninja로 내려받는다.
# 기본 동작은 여전히 아무것도 내려받지 않는 것이다.
#
# png 코덱은 둘 중 하나로 선다.
#   기본     : libpng(C). 추가 도구가 없다.
#   -RustPng : rust 코덱. APNG(움직이는 png)를 읽는 유일한 길이고 bazelisk가 필요하다.
# 나머지 코덱(jpeg-turbo·webp·gif)은 두 경우 모두 켜진다.
#
# Skia 자신을 컴파일하는 것은 **clang-cl이 기본이다** (-Toolchain msvc로 되돌린다).
# 이유는 CPU 래스터 파이프라인의 처리 폭 하나다. src/opts/SkRasterPipeline_opts.h가
# 벡터를 clang·gcc의 확장(ext_vector_type)으로만 만들고, 그 둘이 아니면
# SKRP_CPU_SCALAR로 떨어져 한 번에 픽셀 하나를 처리한다. MSVC로 세운 Skia는
# /arch:AVX2로 컴파일되는 SkOpts_ml3.cpp까지 포함해 전부 그 scalar 경로다.
# clang-cl로 세우면 기본이 SSE2(폭 4)이고, SkOpts::Init()의 실행 시점 판정이
# AVX2를 지원하는 CPU에서 ml3 갈래(폭 8)로 바꿔 끼운다.
#
# 소비자는 여전히 MSVC로 빌드한다. 그 경계가 성립하는 것은 clang-cl이 MSVC의
# 헤더와 CRT를 그대로 쓰고(-imsvc), is_trivial_abi를 false로 못 박기 때문이다
# (third_party/skia-args의 그 줄과 docs/skia-build.md 5.4).
#
# 대상은 -Target이 정한다. 기본은 win-x64이고, 그때는 위의 모든 것이 그대로다.
#   win-x64       : Windows에서 돈다. clang-cl, Direct3D.
#   android-arm64 : **Linux에서 돈다** (WSL2면 된다). NDK clang, Vulkan.
# Android가 Linux를 요구하는 것은 rust png 때문이다. Skia의 Bazel NDK 도구사슬이
# linux x86_64 호스트에서만 돈다 (docs/skia-build.md 8). -Toolchain·-ClangPath는
# Windows 대상에서만 뜻이 있고, Android에서는 -NdkPath가 그 자리다.

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('win-x64', 'android-arm64')]
    [string]$Target = 'win-x64',
    [string]$NdkPath,
    [string]$SkiaRoot,
    [string]$ArgumentFile,
    [ValidateSet('clang', 'msvc')]
    [string]$Toolchain = 'clang',
    [string]$ClangPath,
    # 산출 디렉터리 이름 뒤에 붙는다. 같은 Skia 트리에서 두 도구사슬의 산출물을
    # 나란히 두고 비교할 때 쓴다: -Toolchain msvc -OutputSuffix '-msvc'.
    [string]$OutputSuffix,
    [string]$GnPath,
    [string]$NinjaPath,
    [string]$PythonPath,
    [switch]$CopyExternals,
    [switch]$FetchTools,
    [switch]$RustPng
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot

# 호스트 판정에 $IsWindows를 쓰지 않는다. Windows PowerShell 5.1에는 그 변수가
# 없어 StrictMode가 읽는 순간 던진다. $env:OS는 5.1·7·Linux에서 모두 읽힌다.
$windows_host = $env:OS -eq 'Windows_NT'
$is_android = $Target -like 'android-*'
if ($is_android -and $windows_host) {
    throw @"
-Target $Target must run on Linux (WSL2 is enough).

Skia builds its rust png codec through Bazel, and Skia's Bazel NDK toolchain
only runs on a linux x86_64 host (toolchain/BUILD.bazel). Run this script with
pwsh inside WSL, against a Skia tree on the Linux file system.
"@
}
if (-not $is_android -and -not $windows_host) {
    throw "-Target $Target must run on Windows. It compiles with clang-cl against MSVC."
}
if ($is_android -and ($PSBoundParameters.ContainsKey('Toolchain') -or $ClangPath)) {
    throw "-Toolchain and -ClangPath apply to win-x64 only. Android compiles with the NDK's clang (-NdkPath)."
}
$executable_suffix = if ($windows_host) { '.exe' } else { '' }

# 기본은 submodule이지만, 이미 준비해 둔 Skia 트리를 가리킬 수도 있다.
# verify_skia_root.ps1이 같은 이름의 인자를 이미 받고 있고, docs/skia-build.md도
# CMake 쪽에서 기존 트리를 재사용하는 길을 적어 두었다 — 빌드 쪽에만 없던 손잡이다.
if ($SkiaRoot) {
    if (-not (Test-Path -LiteralPath $SkiaRoot -PathType Container)) {
        throw "The Skia tree was not found at the given path: $SkiaRoot"
    }
    $skia_root = (Resolve-Path -LiteralPath $SkiaRoot).Path
}
else {
    $skia_root = Join-Path $repository_root 'third_party\skia'
}
$externals_source = Join-Path $repository_root 'third_party\skia-externals'
$externals_target = Join-Path $skia_root 'third_party\externals'

# 브라우저로 받은 실행 파일을 두는 자리다.
# 저장소는 이 디렉터리를 추적하지 않는다.
$tool_directory = Join-Path $repository_root 'third_party\skia-tools'
# Linux의 하한은 Skia가 DEPS에 고정한 판번(1.12.1)이다. bin/fetch-ninja가 그것을
# 받고, Android 갈래는 그것으로 섰다 (2026-10-02 실측). Windows의 1.13은 이
# 저장소가 처음부터 둔 값이다.
$minimum_ninja_version = if ($windows_host) { [version]'1.13' } else { [version]'1.12' }

# Visual Studio는 CMake 지원의 일부로 ninja를 함께 설치한다.
# 이미 있는 것을 쓰면 ninja는 받을 필요가 없다.
# 버전이 낮은 설치본은 뒤의 검사에서 걸러진다.
function Get-VisualStudioNinjaPath {
    $program_files = ${env:ProgramFiles(x86)}
    if (-not $program_files) {
        return @()
    }
    $vswhere = Join-Path $program_files 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        return @()
    }

    try {
        $installations = & $vswhere -products '*' -prerelease -property installationPath
    }
    catch {
        return @()
    }
    if ($LASTEXITCODE -ne 0 -or -not $installations) {
        return @()
    }
    return @($installations |
        Where-Object { $_ } |
        ForEach-Object {
            Join-Path $_ 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
        })
}

# 찾을 자리는 고정이다.
# 사람이 둔 자리가 먼저고, 다음이 Skia의 fetch 스크립트가 두는 자리, 마지막이 Visual Studio다.
# 순서가 곧 우선순위다.
function Get-ToolCandidate {
    param([string]$name)

    # Linux에서는 확장자가 없고 Visual Studio 자리도 없다. 나머지 순서는 같다 —
    # fetch-gn·fetch-ninja가 Linux에서도 같은 자리에 둔다.
    $file = $name + $executable_suffix
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $tool_directory $file))
    if ($name -eq 'gn') {
        $candidates.Add((Join-Path $skia_root (Join-Path 'bin' $file)))
        $candidates.Add((Join-Path $skia_root (Join-Path 'third_party\gn' $file)))
    }
    else {
        $candidates.Add((Join-Path $skia_root (Join-Path 'third_party\ninja' $file)))
        $candidates.Add((Join-Path $skia_root (Join-Path 'bin' $file)))
        if ($windows_host) {
            foreach ($path in (Get-VisualStudioNinjaPath)) {
                $candidates.Add($path)
            }
        }
    }
    return $candidates.ToArray()
}

function Test-NinjaVersion {
    param([string]$path)

    try {
        $output = & $path --version
    }
    catch {
        return $false
    }
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $false
    }
    if (@($output)[0] -notmatch '(\d+(?:\.\d+){1,2})') {
        return $false
    }
    return ([version]$Matches[1] -ge $minimum_ninja_version)
}

function Find-Tool {
    param([string]$name, [string[]]$candidates, [scriptblock]$accept)

    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ($accept -and -not (& $accept $resolved)) {
            Write-Verbose "$name rejected: $resolved"
            continue
        }
        return $resolved
    }

    $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        if (-not $accept -or (& $accept $command.Source)) {
            return $command.Source
        }
        Write-Verbose "$name rejected: $($command.Source)"
    }
    return ''
}

# Skia의 fetch 스크립트는 사람이 -FetchTools로 지시했을 때만 돈다.
# 산출 위치는 bin/gn.exe와 third_party/ninja/ninja.exe이며 Skia의 .gitignore가 둘 다 무시한다.
function Invoke-SkiaFetch {
    param([string]$fetch_script)

    $script_path = Join-Path $skia_root ('bin\{0}' -f $fetch_script)
    if (-not (Test-Path -LiteralPath $script_path -PathType Leaf)) {
        throw "The Skia fetch script was not found: $script_path"
    }

    # Resolve-Tool의 반환 스트림에 섞이면 진행 메시지까지 실행 파일 경로로
    # 대입된다. 화면에만 표시하고 pipeline에는 쓰지 않는다.
    Write-Host "fetching       : bin/$fetch_script"
    & $python $script_path
    if ($LASTEXITCODE -ne 0) {
        throw @"
bin/$fetch_script failed with exit code $LASTEXITCODE.
It downloads from chrome-infra-packages.appspot.com. If that is blocked, fetch the
executable with a browser and put it in: $tool_directory
"@
    }
}

function Resolve-Tool {
    param([string]$given, [string]$name, [string]$fetch_script, [string]$hint,
        [scriptblock]$accept)

    if ($given) {
        if (-not (Test-Path -LiteralPath $given -PathType Leaf)) {
            throw "$name was not found at the given path: $given"
        }
        return (Resolve-Path -LiteralPath $given).Path
    }

    $candidates = Get-ToolCandidate -name $name
    $found = Find-Tool -name $name -candidates $candidates -accept $accept
    if ($found) {
        return $found
    }

    if ($FetchTools) {
        Invoke-SkiaFetch -fetch_script $fetch_script
        $found = Find-Tool -name $name -candidates $candidates -accept $accept
        if ($found) {
            return $found
        }
        throw "bin/$fetch_script reported success but $name was still not found."
    }

    $searched = (@($candidates) + '(PATH)') -join "`n  "
    throw @"
$name was not found. Searched:
  $searched

Do one of these:
  1. Re-run with -FetchTools to let Skia's bin/$fetch_script download it.
     It needs access to chrome-infra-packages.appspot.com.
  2. Fetch it with a browser and put it in: $tool_directory
     $hint
  3. Pass the path with -GnPath or -NinjaPath.
"@
}

# Skia의 .gn은 script_executable을 "python3"로 두는데,
# Windows의 python3.exe는 Microsoft Store 스텁인 경우가 많아 실행에 실패한다.
# 실제 인터프리터를 찾아 --script-executable로 넘긴다.
function Test-Python3 {
    param([string]$path)

    try {
        $version_output = & $path --version 2>&1
    }
    catch {
        return $false
    }
    return ($LASTEXITCODE -eq 0 -and "$version_output" -match '^Python 3(?:\.|$)')
}

function Resolve-Python {
    param([string]$given)

    if ($given) {
        if (-not (Test-Path -LiteralPath $given -PathType Leaf)) {
            throw "Python was not found at the given path: $given"
        }
        $resolved = (Resolve-Path -LiteralPath $given).Path
        if (-not (Test-Python3 -path $resolved)) {
            throw "The given path is not a working Python 3 interpreter: $resolved"
        }
        return $resolved
    }
    foreach ($candidate in @('python', 'python3')) {
        # 같은 이름의 WindowsApps 스텁 뒤에 실제 Python이 있을 수 있다.
        # Get-Command의 기본 결과 하나만 보면 그 설치를 놓친다.
        $commands = @(Get-Command $candidate -CommandType Application -All `
                -ErrorAction SilentlyContinue)
        foreach ($command in $commands) {
            if ($command.Source -like '*\WindowsApps\*') { continue }
            if (Test-Python3 -path $command.Source) {
                return $command.Source
            }
        }
    }
    throw 'A real Python 3 interpreter was not found. Pass -PythonPath explicitly.'
}

# Skia의 GN은 clang_win 하나로 Windows 도구사슬을 통째로 바꾼다 —
# cl.exe -> clang-cl.exe, lib.exe/link.exe -> lld-link.exe (gn/toolchain/BUILD.gn).
# 그리고 clang_win_version은 $clang_win/lib/clang의 최신 디렉터리에서 스스로 구한다.
# 그러므로 여기서 정할 것은 **LLVM 루트 하나**다.
#
# 첫 자리가 win_vc 옆의 clang인 이유는 ABI다. clang-cl은 자기 STL을 들고 오지
# 않고 -imsvc로 MSVC의 헤더를 읽으며, 링크되는 CRT도 그 MSVC의 것이다
# (gn/skia/BUILD.gn의 _include_dirs·lib_dirs). Skia가 컴파일에 쓰는 MSVC를 고르는
# 것은 gn/find_msvc.py이므로, 그것이 고른 VC 안의 clang을 먼저 본다 — 헤더와
# 컴파일러가 같은 설치본에서 나온다.
function Get-MsvcDirectory {
    $script_path = Join-Path $skia_root 'gn\find_msvc.py'
    if (-not (Test-Path -LiteralPath $script_path -PathType Leaf)) {
        return ''
    }
    try {
        $found = & $python $script_path
    }
    catch {
        return ''
    }
    if ($LASTEXITCODE -ne 0 -or -not $found) {
        return ''
    }
    return ("$found" | Select-Object -First 1).Trim()
}

function Get-VisualStudioClangPath {
    $program_files = ${env:ProgramFiles(x86)}
    if (-not $program_files) {
        return @()
    }
    $vswhere = Join-Path $program_files 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        return @()
    }
    try {
        $installations = & $vswhere -products '*' -prerelease -property installationPath
    }
    catch {
        return @()
    }
    if ($LASTEXITCODE -ne 0 -or -not $installations) {
        return @()
    }
    return @($installations |
        Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'VC\Tools\Llvm\x64' })
}

# 루트로 성립하는지는 셋으로 본다. clang-cl과 lld-link는 toolchain이 부르는
# 실행 파일이고, lib/clang/<판번>은 BUILDCONFIG가 clang_win_version을 읽는 자리다.
# 셋 중 하나라도 없으면 gn gen은 통과하고 ninja가 첫 컴파일에서 죽는다.
function Test-ClangWinRoot {
    param([string]$root)

    foreach ($relative in @('bin\clang-cl.exe', 'bin\lld-link.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) {
            return $false
        }
    }
    $versions = Join-Path $root 'lib\clang'
    if (-not (Test-Path -LiteralPath $versions -PathType Container)) {
        return $false
    }
    return [bool](Get-ChildItem -LiteralPath $versions -Directory -ErrorAction SilentlyContinue)
}

function Resolve-ClangWin {
    if ($ClangPath) {
        if (-not (Test-Path -LiteralPath $ClangPath -PathType Container)) {
            throw "-ClangPath was not found: $ClangPath"
        }
        $given = (Resolve-Path -LiteralPath $ClangPath).Path
        # bin을 가리켜도 받아 준다. 사람이 clang-cl.exe를 찾아간 자리가 그쪽이다.
        if (-not (Test-ClangWinRoot -root $given)) {
            $parent = Split-Path -Parent $given
            if ($parent -and (Test-ClangWinRoot -root $parent)) {
                return $parent
            }
            throw @"
-ClangPath is not an LLVM root: $given
It must be the directory that holds bin\clang-cl.exe, bin\lld-link.exe and
lib\clang\<version>.
"@
        }
        return $given
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    # 1. 브라우저로 받아 둔 자리. gn·ninja와 같은 규칙이다.
    $candidates.Add((Join-Path $tool_directory 'llvm'))
    # 2. Skia가 헤더와 CRT를 읽을 MSVC 옆의 clang.
    $msvc = Get-MsvcDirectory
    if ($msvc) {
        $candidates.Add((Join-Path $msvc 'Tools\Llvm\x64'))
    }
    # 3. 다른 Visual Studio 설치본.
    foreach ($path in (Get-VisualStudioClangPath)) {
        $candidates.Add($path)
    }
    # 4. 따로 설치한 LLVM.
    foreach ($program_files in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($program_files) {
            $candidates.Add((Join-Path $program_files 'LLVM'))
        }
    }
    # 5. PATH의 clang-cl.exe. 그 자리에서 bin을 한 단계 올라간 것이 루트다.
    $command = Get-Command -Name 'clang-cl' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        $candidates.Add((Split-Path -Parent (Split-Path -Parent $command.Source)))
    }

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and
            (Test-ClangWinRoot -root $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $searched = ($candidates | Where-Object { $_ } | Select-Object -Unique) -join "`n  "
    throw @"
-Toolchain clang needs clang-cl.exe, and no LLVM root was found. Searched:
  $searched

An LLVM root is the directory holding bin\clang-cl.exe, bin\lld-link.exe and
lib\clang\<version>.

Do one of these:
  1. Install the Visual Studio component "C++ Clang tools for Windows".
     It lands in <VS>\VC\Tools\Llvm\x64 and needs nothing else.
  2. Install LLVM for Windows from releases.llvm.org (or winget install LLVM.LLVM)
     and pass -ClangPath if it is not in Program Files.
  3. Unpack one into: $(Join-Path $tool_directory 'llvm')
  4. Build with MSVC instead: -Toolchain msvc.
     That works, but Skia's CPU raster pipeline then runs one pixel at a time -
     src/opts/SkRasterPipeline_opts.h has no vector type for MSVC.
"@
}

# Android 대상의 컴파일러는 NDK의 clang이다. clang_win과 같은 규칙으로, 정할 것은
# **NDK 루트 하나**이고 gn args의 ndk에 넘긴다 (gn/BUILDCONFIG.gn이 거기서
# toolchains/llvm/prebuilt/<host>를 고른다).
#
# 판번은 Skia CI가 쓰는 r27d를 기대한다 (infra/bots/assets/android_ndk_linux).
# 다른 판번도 받되 경고한다 — 이 저장소가 실측한 것은 그 하나뿐이다.
#
# rust 갈래의 C++ 브리지는 이것으로 컴파일되지 **않는다.** Bazel이 자기 NDK
# (r21e)를 받아 쓴다. 그 판번은 toolchain.json의 rust_bridge_ndk_revision에 적는다.
$expected_ndk_major = '27'
$expected_ndk_revision = '27.3.13750724'

function Get-NdkRevision {
    param([string]$root)

    $properties = Join-Path $root 'source.properties'
    if (-not (Test-Path -LiteralPath $properties -PathType Leaf)) {
        return ''
    }
    $text = Get-Content -Raw -LiteralPath $properties
    if ($text -match 'Pkg\.Revision\s*=\s*([0-9.]+)') {
        return $Matches[1]
    }
    return ''
}

function Test-NdkRoot {
    param([string]$root)

    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        return $false
    }
    $clang = Join-Path $root 'toolchains/llvm/prebuilt/linux-x86_64/bin/clang'
    return ((Test-Path -LiteralPath $clang -PathType Leaf) -and [bool](Get-NdkRevision -root $root))
}

function Resolve-Ndk {
    if ($NdkPath) {
        if (-not (Test-NdkRoot -root $NdkPath)) {
            throw @"
-NdkPath is not an NDK root: $NdkPath
It must hold source.properties and toolchains/llvm/prebuilt/linux-x86_64/bin/clang.
"@
        }
        return (Resolve-Path -LiteralPath $NdkPath).Path
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($variable in @('ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($variable)
        if ($value) {
            $candidates.Add($value)
        }
    }
    $candidates.Add((Join-Path $tool_directory 'ndk'))
    if ($HOME) {
        $candidates.Add((Join-Path $HOME 'ndk/android-ndk-r27d'))
    }
    foreach ($candidate in $candidates) {
        if (Test-NdkRoot -root $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw @"
-Target $Target needs the Android NDK (r$expected_ndk_major), and none was found. Searched:
  -NdkPath, ANDROID_NDK_HOME, ANDROID_NDK_ROOT
  $(($candidates | Select-Object -Unique) -join "`n  ")

Download android-ndk-r27d-linux.zip from dl.google.com/android/repository,
unzip it into ~/ndk, or pass -NdkPath.
"@
}

if (-not (Test-Path -LiteralPath (Join-Path $skia_root 'include\core\SkCanvas.h'))) {
    throw @"
The Skia submodule is not initialized: $skia_root
Run: git submodule update --init third_party/skia
"@
}

# win-x64의 파일·디렉터리 이름에는 대상이 없다. 대상이 하나이던 때의 이름을 그대로 둔다.
$target_part = if ($is_android) { "$Target-" } else { '' }
if (-not $ArgumentFile) {
    $ArgumentFile = Join-Path $repository_root ('third_party\skia-args\skia-ui-{0}{1}.gn' -f `
            $target_part, $Configuration.ToLowerInvariant())
}
if (-not (Test-Path -LiteralPath $ArgumentFile)) {
    throw "The GN argument file was not found: $ArgumentFile"
}

# png 코덱만 인자 파일이 갈린다.
# 기본 파일에는 png와 zlib이 없고, 두 조각 중 하나를 뒤에 이어 붙여 완성한다.
# 한 변수에 두 번 대입하면 gn이 거부하므로 겹치는 줄을 두지 않는 방식이다.
$png_flavor = if ($RustPng) { 'rust' } else { 'libpng' }
$png_argument_file = Join-Path $repository_root ('third_party\skia-args\png-{0}.gn' -f $png_flavor)
if (-not (Test-Path -LiteralPath $png_argument_file)) {
    throw "The png GN argument file was not found: $png_argument_file"
}
$argument_text = (Get-Content -Raw -LiteralPath $ArgumentFile) + "`n" +
    (Get-Content -Raw -LiteralPath $png_argument_file)

# rust 코덱은 cargo가 아니라 Bazel로 선다.
# Skia의 BUILD.gn이 gn/bazel_build.py를 부르고 그 script가 bazelisk를 실행한다.
# 없으면 ninja가 한참 돌다가 죽으므로 시작 전에 잡는다.
#
# **찾는 것은 `bazelisk.exe` 하나다.** bazel_build.py는
# `subprocess.run(["bazelisk", ...])`로 부르는데 그것이 CreateProcess라,
# npm(`@bazel/bazelisk`)이 두는 `bazelisk.cmd`·`bazelisk.ps1` 같은 launcher는
# 셸만 찾고 CreateProcess는 찾지 못한다. PowerShell의 `Get-Command`는 그 launcher도
# 찾아 주므로 여기서 확장자를 직접 본다 — 그러지 않으면 검사를 통과하고 나서
# ninja가 한참 돌다가 `FileNotFoundError: [WinError 2]`로 죽는다 (실측).
#
# Linux에서는 그 함정이 없다. 이름이 bazelisk인 실행 파일이면 된다. 다만
# `wsl -- pwsh`처럼 login shell을 거치지 않으면 ~/bin이 PATH에 없으므로 그 자리를
# 직접 본다.
function Resolve-Bazelisk {
    $locals = @(Join-Path $tool_directory ('bazelisk' + $executable_suffix))
    if (-not $windows_host -and $HOME) {
        $locals += Join-Path $HOME 'bin/bazelisk'
    }
    foreach ($local in $locals) {
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            return (Resolve-Path -LiteralPath $local).Path
        }
    }
    $command = Get-Command -Name 'bazelisk' -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { [System.IO.Path]::GetExtension($_.Source) -eq $executable_suffix } |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    if (-not $windows_host) {
        throw @"
-RustPng needs bazelisk, and it was not found. Searched:
  $($locals -join "`n  ")
  (PATH)

Download bazelisk-linux-amd64 from github.com/bazelbuild/bazelisk/releases,
rename it to bazelisk, chmod +x it and put it in ~/bin.
"@
    }
    $local = $locals[0]
    throw @"
-RustPng needs bazelisk.exe, and it was not found. Searched:
  $local
  (PATH, .exe entries only)

Skia builds its Rust png codec through Bazel, not cargo: BUILD.gn runs
gn/bazel_build.py, which calls `bazelisk build //rust/png:ffi_rs`. Bazel then
fetches the Rust toolchain itself through rules_rust, so rustup is not required.

That call is CreateProcess, so it needs a real executable named bazelisk.exe.
A .cmd/.ps1 launcher on PATH is NOT enough - `npm i -g @bazel/bazelisk` leaves
exactly that, and the build then dies inside ninja with WinError 2.

Do one of these:
  1. Put bazelisk.exe in: $tool_directory
     Download bazelisk-windows-amd64.exe from
     github.com/bazelbuild/bazelisk/releases and rename it to bazelisk.exe.
     (If npm installed it, the real binary is under
     node_modules/@bazel/bazelisk/bazelisk-windows_amd64.exe.)
  2. Install one that lands as an .exe on PATH:
       winget install Bazel.Bazelisk
  3. Drop -RustPng to build png with libpng instead. Everything works except
     APNG (an animated png then decodes as a still image).
"@
}

$bazelisk = ''
if ($RustPng) {
    $bazelisk = Resolve-Bazelisk
    # bazel_build.py는 이름만으로 부르므로 그 자리를 PATH 앞에 세운다.
    $env:PATH = '{0}{1}{2}' -f (Split-Path -Parent $bazelisk), [System.IO.Path]::PathSeparator, $env:PATH
}

# 필요한 external은 GN args가 정한다.
# 쓰지 않는 external은 요구하지 않는다.
$required_externals = [System.Collections.Generic.List[string]]::new()
# Direct3D backend의 것이다. spirv-cross는 SkSL을 HLSL로 옮기는 데 쓴다
# (BUILD.gn의 skia_use_direct3d 갈래).
if ($argument_text -match 'skia_use_direct3d\s*=\s*true') {
    $required_externals.Add('d3d12allocator')
    $required_externals.Add('spirv-cross')
    $required_externals.Add('spirv-headers')
}
# Vulkan 헤더는 Skia 트리 안(include/third_party/vulkan)에 있어 할당기만 든다.
if ($argument_text -match 'skia_use_vulkan\s*=\s*true') {
    $required_externals.Add('vulkanmemoryallocator')
}
# Android의 시스템 글꼴 길이다. freetype은 컬러 이모지 때문에 libpng을, libpng은
# zlib을 **png 갈래와 무관하게** 끌어온다 (third_party/freetype2/BUILD.gn).
if ($argument_text -match 'skia_use_freetype\s*=\s*true') {
    $required_externals.Add('freetype')
    $required_externals.Add('libpng')
    $required_externals.Add('zlib')
}
if ($argument_text -match 'skia_use_expat\s*=\s*true') {
    $required_externals.Add('expat')
}
if ($argument_text -match 'skia_use_libjpeg_turbo_decode\s*=\s*true' -or
    $argument_text -match 'skia_use_libjpeg_turbo_encode\s*=\s*true') {
    $required_externals.Add('libjpeg-turbo')
}
if ($argument_text -match 'skia_use_libwebp_decode\s*=\s*true' -or
    $argument_text -match 'skia_use_libwebp_encode\s*=\s*true') {
    $required_externals.Add('libwebp')
}
# gif 디코더다.
if ($argument_text -match 'skia_use_wuffs\s*=\s*true') {
    $required_externals.Add('wuffs')
}
if ($argument_text -match 'skia_use_libpng_decode\s*=\s*true' -or
    $argument_text -match 'skia_use_libpng_encode\s*=\s*true') {
    $required_externals.Add('libpng')
}
# zlib은 libpng이 쓴다. rust png 구성에는 없다.
if ($argument_text -match 'skia_use_zlib\s*=\s*true') {
    $required_externals.Add('zlib')
}
if ($argument_text -match 'skia_use_harfbuzz\s*=\s*true') {
    $required_externals.Add('harfbuzz')
}
if ($argument_text -match 'skia_use_libgrapheme\s*=\s*true') {
    $required_externals.Add('libgrapheme')
    $required_externals.Add('unicodetools')
    # libgrapheme backend도 BiDi는 ICU 소스를 컴파일한다.
    # 데이터 파일은 쓰지 않는다.
    $required_externals.Add('icu')
}
if ($argument_text -match 'skia_use_icu\s*=\s*true') {
    $required_externals.Add('icu')
}

# python을 먼저 정한다.
# -FetchTools가 fetch 스크립트를 돌릴 때 쓰는 것도 이것이다.
$python = Resolve-Python -given $PythonPath
$gn_hint = if ($windows_host) { 'The CIPD package page for gn/gn/windows-amd64 has it.' }
else { 'The CIPD package page for gn/gn/linux-amd64 has it.' }
$ninja_hint = if ($windows_host) { 'The ninja-build releases page has ninja-win.zip.' }
else { 'The ninja-build releases page has ninja-linux.zip.' }
$gn = Resolve-Tool -given $GnPath -name 'gn' -fetch_script 'fetch-gn' -hint $gn_hint
$ninja = Resolve-Tool -given $NinjaPath -name 'ninja' -fetch_script 'fetch-ninja' `
    -hint $ninja_hint -accept { param($path) Test-NinjaVersion -path $path }
if ($NinjaPath -and -not (Test-NinjaVersion -path $ninja)) {
    Write-Warning "The given ninja is older than $minimum_ninja_version or reported no version: $ninja"
}

# 도구사슬은 args 뒤에 한 줄을 덧붙이는 것으로 정해진다.
# GN 문자열에서 역슬래시는 이스케이프 문자이므로 슬래시로 바꿔 넘긴다 —
# clang-cl과 lld-link는 Windows에서도 슬래시 경로를 그대로 받는다.
$clang_win = ''
$compiler_version = ''
$ndk = ''
$ndk_revision = ''
if ($is_android) {
    $ndk = Resolve-Ndk
    $ndk_revision = Get-NdkRevision -root $ndk
    if ($ndk_revision -notmatch "^$expected_ndk_major\.") {
        Write-Warning ("NDK {0} is not r{1}. Skia's CI builds with r{1}d ({2}); others are untested here." -f `
                $ndk_revision, $expected_ndk_major, $expected_ndk_revision)
    }
    $ndk_clang = Join-Path $ndk 'toolchains/llvm/prebuilt/linux-x86_64/bin/clang'
    $compiler_version = (& $ndk_clang --version | Select-Object -First 1).Trim()
    $argument_text += "`nndk = `"{0}`"`n" -f $ndk

    # 이 기계의 절대 경로를 오브젝트에 박지 않는다. Debug의 DWARF가 산출 디렉터리,
    # external 소스, NDK 시스템 헤더를 절대 경로로 적어 생산자의 사용자 이름이 공개
    # 자산에 실렸다 (2026-10-02 실측, 13개 아카이브). -ffile-prefix-map이 디버그
    # 정보와 __FILE__ 양쪽에서 그 앞부분을 이름 하나로 바꾼다. 경로가 이 기계의
    # 것이므로 args 파일이 아니라 여기서 덧붙이고, pack_skia.ps1이 발행할 때
    # args.gn에서 그 경로를 다시 가린다. 겹치지 않는 자리만 넣는다 — Skia 트리가
    # 저장소 안에 있으면 저장소 하나로 덮인다.
    $prefix_maps = [ordered]@{}
    $prefix_maps[$repository_root] = 'skia-prep'
    if (-not $skia_root.StartsWith($repository_root + '/')) {
        $prefix_maps[$skia_root] = 'skia'
    }
    $prefix_maps[$ndk] = 'android-ndk'
    $prefix_flags = ($prefix_maps.Keys | ForEach-Object {
            '"-ffile-prefix-map={0}={1}"' -f $_, $prefix_maps[$_]
        }) -join ', '
    foreach ($name in @('extra_cflags_c', 'extra_cflags_cc', 'extra_asmflags')) {
        $argument_text += "{0} = [ {1} ]`n" -f $name, $prefix_flags
    }
}
elseif ($Toolchain -eq 'clang') {
    $clang_win = Resolve-ClangWin
    $compiler_version = (& (Join-Path $clang_win 'bin\clang-cl.exe') --version |
        Select-Object -First 1).Trim()
    $argument_text += "`nclang_win = `"{0}`"`n" -f ($clang_win -replace '\\', '/')
}

Write-Output "Skia root      : $skia_root"
Write-Output "Target         : $Target"
Write-Output "Configuration  : $Configuration"
Write-Output "Argument file  : $ArgumentFile"
Write-Output "png codec      : $png_flavor ($png_argument_file)"
if ($ndk) {
    Write-Output "ndk            : $ndk (r$ndk_revision)"
    Write-Output "clang          : $compiler_version"
}
else {
    Write-Output "toolchain      : $Toolchain"
}
if ($clang_win) {
    Write-Output "clang_win      : $clang_win"
    Write-Output "clang-cl       : $compiler_version"
}
if ($bazelisk) {
    Write-Output "bazelisk       : $bazelisk"
}
Write-Output "gn             : $gn"
Write-Output "ninja          : $ninja"
Write-Output "python         : $python"

# 1. external 배치.
#    Skia 저장소를 수정하지 않도록 junction(Linux에서는 symlink)으로 연결한다.
#    Skia의 .gitignore가 third_party/externals를 통째로 무시한다.
New-Item -ItemType Directory -Force -Path $externals_target | Out-Null
foreach ($name in ($required_externals | Sort-Object -Unique)) {
    $source = Join-Path $externals_source $name
    if (-not (Test-Path -LiteralPath $source) -or
        -not (Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -ne '.git' })) {
        throw @"
The external submodule is not initialized: third_party/skia-externals/$name
Run: git submodule update --init third_party/skia-externals/$name
"@
    }

    $link_path = Join-Path $externals_target $name
    if (Test-Path -LiteralPath $link_path) {
        Write-Output "external ready : $name"
        continue
    }
    if ($CopyExternals) {
        Copy-Item -Recurse -LiteralPath $source -Destination $link_path
        Write-Output "external copied: $name"
    }
    else {
        $link_type = if ($windows_host) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $link_type -Path $link_path -Target $source | Out-Null
        Write-Output "external linked: $name"
    }
}

# 2. 패치.
#    **기본 구성에는 패치가 없다.** Skia 152는 손대지 않고 그대로 선다 —
#    148이 요구하던 Direct3D `operator==` 패치는 152에서 필요 없어졌다
#    (`GrD3DBackendSurface.cpp`가 더 이상 가드 밖에서 부르지 않는다. Debug로 실측).
#    rust png 구성만 둘이 필요하고, **대상마다 다른 둘이다.** 서로 섞지 않는다 —
#    Windows의 산출물 이름 패치를 Linux에 걸면 GN의 복사 단계가 없는 .lib을 찾는다.
#      win-x64       : Windows bazel 산출물 이름을 고치고, Debug bazel C++
#                      산출물을 /MTd ABI로 맞춘다 (docs/skia-build.md 5.3).
#      android-arm64 : Rust·crate 목록에 aarch64-linux-android를 더하고(lock째
#                      고정한다), GN이 Bazel에 Android 플랫폼을 넘긴다
#                      (docs/skia-build.md 8).
if ($RustPng) {
    $patch_set = if ($is_android) {
        @(@('skia-152-bazel-rust-android-triples.patch', 'rust android triples'),
            @('skia-152-bazel-rust-android-platform.patch', 'rust android platform'))
    }
    else {
        @(@('skia-152-bazel-rust-windows-outputs.patch', 'rust png outputs'),
            @('skia-152-bazel-rust-windows-debug-crt.patch', 'rust png debug CRT'))
    }
    $patches = @($patch_set | ForEach-Object {
            @{
                path  = Join-Path $repository_root (Join-Path 'third_party\patches' $_[0])
                label = $_[1]
            }
        })
    foreach ($patch in $patches) {
        if (-not (Test-Path -LiteralPath $patch.path -PathType Leaf)) {
            throw "The rust png patch was not found: $($patch.path)"
        }
    }

    & git -C $skia_root rev-parse --is-inside-work-tree 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw @"
-RustPng needs a patch in the Skia tree, and $skia_root is not a git work tree,
so this script cannot manage it. Apply it by hand from a checkout of that tree:
  git apply $($patches[0].path)
  git apply $($patches[1].path)
"@
    }

    foreach ($patch in $patches) {
        # 이미 적용된 경우 다시 적용하지 않는다.
        & git -C $skia_root apply --reverse --check $patch.path 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "patch          : already applied ($($patch.label))"
        }
        else {
            & git -C $skia_root apply $patch.path
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to apply the $($patch.label) patch: $($patch.path)"
            }
            Write-Output "patch          : applied ($($patch.label))"
        }
    }
}
else {
    Write-Output 'patch          : none needed'
}

# 3. gn gen.
#    인자 파일의 줄바꿈을 공백으로 바꿔 한 줄로 전달한다.
#    그 전에 주석을 지운다 — 한 줄이 되고 나면 `#` 뒤의 모든 것이 주석이 되어
#    그 아래 인자가 통째로 사라진다. 사라진 인자는 오류가 아니라 **Skia의 기본값**이
#    되므로(코덱은 기본이 켜짐·system 라이브러리) 링크나 컴파일이 엉뚱한 자리에서
#    깨진다. 값에 `#`을 쓰는 인자는 없다.
#    산출 자리는 win-x64가 out/skia-ui-{구성}, 다른 대상이 out/skia-ui-{대상}-{구성}이다.
#    pack_skia.ps1·verify_skia_root.ps1이 같은 식으로 읽는다. 패키지 안의 배치는
#    대상과 무관하게 out/skia-ui-{구성}이다 — 그쪽이 소비자의 계약이다.
$output_directory = Join-Path $skia_root `
    ('out\skia-ui-{0}{1}{2}' -f $target_part, $Configuration.ToLowerInvariant(), $OutputSuffix)
$flat_arguments = (($argument_text -split "`r?`n") |
    ForEach-Object { ($_ -replace '(^|\s)#.*$', '').Trim() } |
    Where-Object { $_ }) -join ' '
Push-Location $skia_root
try {
    & $gn gen $output_directory "--script-executable=$python" "--args=$flat_arguments"
    if ($LASTEXITCODE -ne 0) {
        throw 'gn gen failed.'
    }

    # 4. ninja.
    #    텍스트 처리 구성은 module 라이브러리도 함께 만든다.
    $targets = @('skia')
    if ($argument_text -match 'skia_use_harfbuzz\s*=\s*true') {
        $targets += 'modules'
    }
    & $ninja -C $output_directory @targets
    if ($LASTEXITCODE -ne 0) {
        throw 'ninja failed.'
    }
}
finally {
    Pop-Location
}

# 5. toolchain.json.
#    args.gn을 산출물 옆에 함께 싣는 것이 이 저장소의 구성 계약이다. 그런데
#    args.gn은 **무엇으로 컴파일했는지를 적지 못한다** — clang_win은 이 기계의
#    경로일 뿐이고, MSVC와 Windows SDK의 판번은 GN이 스스로 찾아 args에 남지도
#    않는다. 같은 Skia commit에서 나온 두 패키지를 나중에 구별할 근거가 필요하므로
#    (재빌드마다 패키지 판번을 새로 붙이는 이유가 그것이다) 실제로 쓴 도구사슬을
#    여기서 적어 둔다. gn이 방금 만든 ninja 파일이 그 사실을 들고 있다.
#    gn args --list로는 답이 나오지 않는다. win_toolchain_version과 win_sdk_version은
#    declare_args의 기본값이 ""이고 실제 값은 BUILDCONFIG가 그 뒤에 계산해 넣기
#    때문이다 — 그 계산 결과가 남는 자리는 컴파일 명령뿐이다. gn이 경로 안의
#    공백과 콜론을 `$ `·`$:`로 escape하므로 구분자만 느슨하게 본다.
#
#    Android의 기록은 갈래가 다르다. MSVC·SDK 대신 NDK 판번과 ndk_api를 적고,
#    rust 갈래에서는 C++ 브리지를 컴파일한 **Bazel 쪽 NDK의 판번**을 함께 적는다 —
#    한 아카이브 묶음 안에 두 NDK가 섞여 있다는 사실이 args.gn 어디에도 남지
#    않기 때문이다. ndk는 이 기계의 경로이므로 pack_skia.ps1이 발행할 때 뺀다.
if ($is_android) {
    $ndk_api = if ($argument_text -match '(?m)^\s*ndk_api\s*=\s*(\d+)') { [int]$Matches[1] } else { 21 }
    $rust_bridge_ndk_revision = ''
    if ($bazelisk) {
        Push-Location $skia_root
        try {
            $output_base = & $bazelisk info output_base 2>$null
        }
        finally {
            Pop-Location
        }
        if ($LASTEXITCODE -eq 0 -and $output_base) {
            $bazel_ndk = Get-ChildItem -LiteralPath (Join-Path "$output_base".Trim() 'external') `
                -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*ndk_linux_amd64*' } |
                Select-Object -First 1
            if ($bazel_ndk) {
                $rust_bridge_ndk_revision = Get-NdkRevision -root $bazel_ndk.FullName
            }
        }
        if (-not $rust_bridge_ndk_revision) {
            Write-Warning 'The NDK that Bazel used for the rust bridge was not found; toolchain.json leaves it empty.'
        }
    }
    $toolchain_record = [ordered]@{
        schema                   = 1
        target                   = $Target
        toolchain                = 'ndk'
        compiler                 = 'clang'
        compiler_version         = $compiler_version
        linker                   = 'lld'
        ndk                      = $ndk
        ndk_revision             = $ndk_revision
        ndk_api                  = $ndk_api
        rust_bridge_ndk_revision = $rust_bridge_ndk_revision
        configuration            = $Configuration
        png_codec                = $png_flavor
        built_at                 = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Set-Content -LiteralPath (Join-Path $output_directory 'toolchain.json') `
        -Value ($toolchain_record | ConvertTo-Json -Depth 4) -Encoding UTF8

    Write-Output ''
    Write-Output "Skia build finished: $output_directory"
    Write-Output ("toolchain      : clang ({0}), NDK r{1}, ndk_api {2}" -f $compiler_version, $ndk_revision, $ndk_api)
    if ($rust_bridge_ndk_revision) {
        Write-Output "rust bridge    : NDK r$rust_bridge_ndk_revision (Bazel's own)"
    }
    Write-Output "Verify it with: scripts/verify_skia_root.ps1 -Target $Target"
    return
}

$generated = @('toolchain.ninja', 'build.ninja', 'obj\core.ninja') |
    ForEach-Object { Join-Path $output_directory $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    ForEach-Object { Get-Content -Raw -LiteralPath $_ }
$generated = $generated -join "`n"
$msvc_version = if ($generated -match 'Tools[/\\]MSVC[/\\]([0-9.]+)') { $Matches[1] } else { '' }
$sdk_version = if ($generated -match 'Kits[/\\]10[/\\]Include[/\\]([0-9.]+)') { $Matches[1] } else { '' }
$toolchain_record = [ordered]@{
    schema           = 1
    toolchain        = $Toolchain
    compiler         = if ($Toolchain -eq 'clang') { 'clang-cl' } else { 'cl' }
    compiler_version = $compiler_version
    linker           = if ($Toolchain -eq 'clang') { 'lld-link' } else { 'link' }
    clang_win        = $clang_win
    msvc_version     = $msvc_version
    windows_sdk      = $sdk_version
    configuration    = $Configuration
    png_codec        = $png_flavor
    built_at         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
if ($Toolchain -ne 'clang') {
    $toolchain_record['compiler_version'] = "MSVC $msvc_version"
}
Set-Content -LiteralPath (Join-Path $output_directory 'toolchain.json') `
    -Value ($toolchain_record | ConvertTo-Json -Depth 4) -Encoding UTF8

Write-Output ''
Write-Output "Skia build finished: $output_directory"
Write-Output ("toolchain      : {0} ({1}), MSVC {2}, Windows SDK {3}" -f `
        $toolchain_record.compiler, $toolchain_record.compiler_version, $msvc_version, $sdk_version)
Write-Output 'Verify it with: scripts\verify_skia_root.ps1'
