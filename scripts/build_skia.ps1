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

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$SkiaRoot,
    [string]$ArgumentFile,
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
$minimum_ninja_version = [version]'1.13'

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

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $tool_directory ('{0}.exe' -f $name)))
    if ($name -eq 'gn') {
        $candidates.Add((Join-Path $skia_root 'bin\gn.exe'))
        $candidates.Add((Join-Path $skia_root 'third_party\gn\gn.exe'))
    }
    else {
        $candidates.Add((Join-Path $skia_root 'third_party\ninja\ninja.exe'))
        $candidates.Add((Join-Path $skia_root 'bin\ninja.exe'))
        foreach ($path in (Get-VisualStudioNinjaPath)) {
            $candidates.Add($path)
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

if (-not (Test-Path -LiteralPath (Join-Path $skia_root 'include\core\SkCanvas.h'))) {
    throw @"
The Skia submodule is not initialized: $skia_root
Run: git submodule update --init third_party/skia
"@
}

if (-not $ArgumentFile) {
    $ArgumentFile = Join-Path $repository_root ('third_party\skia-args\skia-ui-{0}.gn' -f $Configuration.ToLowerInvariant())
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
function Resolve-Bazelisk {
    $local = Join-Path $tool_directory 'bazelisk.exe'
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        return (Resolve-Path -LiteralPath $local).Path
    }
    $command = Get-Command -Name 'bazelisk' -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { [System.IO.Path]::GetExtension($_.Source) -eq '.exe' } |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

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
    $env:PATH = '{0};{1}' -f (Split-Path -Parent $bazelisk), $env:PATH
}

# 필요한 external은 GN args가 정한다.
# 최소 구성은 셋이고, 코덱과 텍스트 처리 구성이 그 위에 더한다.
# 쓰지 않는 external은 요구하지 않는다.
$required_externals = [System.Collections.Generic.List[string]]@(
    'd3d12allocator', 'spirv-cross', 'spirv-headers')
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
$gn = Resolve-Tool -given $GnPath -name 'gn' -fetch_script 'fetch-gn' `
    -hint 'The CIPD package page for gn/gn/windows-amd64 has it.'
$ninja = Resolve-Tool -given $NinjaPath -name 'ninja' -fetch_script 'fetch-ninja' `
    -hint 'The ninja-build releases page has ninja-win.zip.' `
    -accept { param($path) Test-NinjaVersion -path $path }
if ($NinjaPath -and -not (Test-NinjaVersion -path $ninja)) {
    Write-Warning "The given ninja is older than $minimum_ninja_version or reported no version: $ninja"
}

Write-Output "Skia root      : $skia_root"
Write-Output "Configuration  : $Configuration"
Write-Output "Argument file  : $ArgumentFile"
Write-Output "png codec      : $png_flavor ($png_argument_file)"
if ($bazelisk) {
    Write-Output "bazelisk       : $bazelisk"
}
Write-Output "gn             : $gn"
Write-Output "ninja          : $ninja"
Write-Output "python         : $python"

# 1. external 배치.
#    Skia 저장소를 수정하지 않도록 junction으로 연결한다.
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

    $target = Join-Path $externals_target $name
    if (Test-Path -LiteralPath $target) {
        Write-Output "external ready : $name"
        continue
    }
    if ($CopyExternals) {
        Copy-Item -Recurse -LiteralPath $source -Destination $target
        Write-Output "external copied: $name"
    }
    else {
        New-Item -ItemType Junction -Path $target -Target $source | Out-Null
        Write-Output "external linked: $name"
    }
}

# 2. 패치.
#    **기본 구성에는 패치가 없다.** Skia 152는 손대지 않고 그대로 선다 —
#    148이 요구하던 Direct3D `operator==` 패치는 152에서 필요 없어졌다
#    (`GrD3DBackendSurface.cpp`가 더 이상 가드 밖에서 부르지 않는다. Debug로 실측).
#    rust png 구성만 둘이 필요하다. 하나는 Windows bazel 산출물 이름을 고치고,
#    다른 하나는 Debug bazel C++ 산출물을 /MTd ABI로 맞춘다
#    (docs/skia-build.md 5.3).
if ($RustPng) {
    $patches = @(
        @{
            path = Join-Path $repository_root `
                'third_party\patches\skia-152-bazel-rust-windows-outputs.patch'
            label = 'rust png outputs'
        },
        @{
            path = Join-Path $repository_root `
                'third_party\patches\skia-152-bazel-rust-windows-debug-crt.patch'
            label = 'rust png debug CRT'
        }
    )
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
$output_directory = Join-Path $skia_root ('out\skia-ui-{0}' -f $Configuration.ToLowerInvariant())
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

Write-Output ''
Write-Output "Skia build finished: $output_directory"
Write-Output 'Verify it with: scripts\verify_skia_root.ps1'
