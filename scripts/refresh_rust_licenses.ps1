# third_party/rust-licenses/<대상>을 Bazel 캐시에서 다시 뜬다.
#
# pack_skia.ps1은 rust 갈래의 crate 고지를 이 저장소의 사본에서 먼저 읽는다 (Bazel
# 캐시는 15 GB까지 자라 지우게 되고, 지우면 전체 재빌드 없이는 되살아나지 않는다).
# 그래서 **crate 목록이 바뀌면 사본을 다시 떠야 한다** — Skia의 MODULE.bazel이 crate를
# 더하거나 빼거나, lock이 다시 풀렸을 때다. 이 스크립트가 그 일을 한다.
#
#   scripts\refresh_rust_licenses.ps1 -Target win-x64          (Windows에서)
#   pwsh scripts/refresh_rust_licenses.ps1 -Target android-arm64   (WSL에서)
#   pwsh scripts/refresh_rust_licenses.ps1 -Target mac-arm64       (Mac에서)
#   pwsh scripts/refresh_rust_licenses.ps1 -Target ios-arm64       (Mac에서, 시뮬레이터도 이 사본을 쓴다)
#
# build_skia.ps1 -RustPng로 그 대상을 한 번 세운 뒤에 돈다 — 그래야 Bazel의 output base에
# 그 대상의 crate가 받아져 있다. 배치는 Bazel의 것과 같다. 걷는 것은 crate 저장소마다
# LICENSE·COPYING·NOTICE로 시작하는 파일과, Rust 표준 라이브러리의
# share/doc/rust/COPYRIGHT-library.html이다 (pack_skia.ps1이 읽는 것이 그것뿐이다).

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'android-arm64', 'mac-arm64', 'ios-arm64', 'ios-arm64-simulator')]
    [string]$Target,
    [string]$SkiaRoot,
    [string]$BazeliskPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot
if (-not $SkiaRoot) {
    $SkiaRoot = Join-Path $repository_root 'third_party\skia'
}
$skia_root = (Resolve-Path -LiteralPath $SkiaRoot).Path
$windows_host = $env:OS -eq 'Windows_NT'
$mac_host = (Test-Path -LiteralPath 'variable:IsMacOS') -and $IsMacOS
$built_here = switch ($Target) {
    'win-x64' { $windows_host }
    'mac-arm64' { $mac_host }
    'ios-arm64' { $mac_host }
    'ios-arm64-simulator' { $mac_host }
    default { -not $windows_host -and -not $mac_host }
}
if (-not $built_here) {
    throw "-Target $Target must run where it is built (win-x64 on Windows, android-arm64 on Linux, mac-arm64 and ios-* on macOS)."
}

$bazelisk = $BazeliskPath
if (-not $bazelisk) {
    $candidates = @((Join-Path $repository_root ('third_party\skia-tools\bazelisk' + $(if ($windows_host) { '.exe' } else { '' }))))
    if (-not $windows_host -and $HOME) {
        $candidates += Join-Path $HOME 'bin/bazelisk'
    }
    $bazelisk = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $bazelisk) {
        $command = Get-Command bazelisk -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $bazelisk = $command.Source }
    }
}
if (-not $bazelisk) {
    throw 'bazelisk was not found. Pass -BazeliskPath.'
}

Push-Location $skia_root
try {
    $output_base = "$(& $bazelisk info output_base)".Trim()
}
finally {
    Pop-Location
}
$external = Join-Path $output_base 'external'
if (-not (Test-Path -LiteralPath $external -PathType Container)) {
    throw "The Bazel output base has no external directory: $external. Build with -RustPng first."
}

# 캐시에는 지난 빌드의 crate가 남아 있다 (lock이 다시 풀리면 옛 판번과 새 판번이 함께
# 있다). 지금 Skia 트리의 MODULE.bazel.lock에 적힌 것만 고른다 — 그것이 이번 빌드가 쓴
# crate다.
$lock = Get-Content -Raw -LiteralPath (Join-Path $skia_root 'MODULE.bazel.lock')
$crates = @(Get-ChildItem -LiteralPath $external -Directory |
        Where-Object { $_.Name -like '*crate+crates__*' } |
        Where-Object { $lock.Contains('"crates__' + ($_.Name -split 'crates__')[-1] + '"') } |
        Sort-Object Name)
if ($crates.Count -eq 0) {
    throw "No crate repositories under $external. Build with build_skia.ps1 -RustPng first."
}
# Windows·Linux에서는 rust_host_tools에 있다. macOS(arm64)는 호스트와 대상이 같아 그 저장소가
# 없고, 대상의 도구사슬 저장소(rust_macos_aarch64__aarch64-apple-darwin__stable_tools)에 있다.
$host_tools = Get-ChildItem -LiteralPath $external -Directory |
    Where-Object { $_.Name -like '*rust_host_tools*' -or $_.Name -like '*__stable_tools' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'share/doc/rust/COPYRIGHT-library.html') -PathType Leaf } |
    Sort-Object { $_.Name -notlike '*rust_host_tools*' }, Name |
    Select-Object -First 1
$library_notice = if ($host_tools) { Join-Path $host_tools.FullName 'share/doc/rust/COPYRIGHT-library.html' } else { '' }
if (-not $library_notice -or -not (Test-Path -LiteralPath $library_notice -PathType Leaf)) {
    throw "The Rust standard library notice was not found under $external."
}

# iOS 기기와 시뮬레이터는 같은 lock으로 같은 crate가 서서 사본 하나(ios-arm64)를 함께 쓴다
# (pack_skia.ps1의 $license_target).
$license_target = if ($Target -like 'ios-*') { 'ios-arm64' } else { $Target }
$destination = Join-Path $repository_root (Join-Path 'third_party\rust-licenses' $license_target)
$before = @()
if (Test-Path -LiteralPath $destination) {
    $before = @(Get-ChildItem -LiteralPath $destination -Directory | ForEach-Object Name)
    Remove-Item -LiteralPath $destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $destination | Out-Null

foreach ($crate in $crates) {
    $files = @(Get-ChildItem -LiteralPath $crate.FullName -File |
            Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' })
    $crate_directory = Join-Path $destination $crate.Name
    New-Item -ItemType Directory -Force -Path $crate_directory | Out-Null
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination $crate_directory
    }
    if ($files.Count -eq 0) {
        Write-Warning "$($crate.Name) has no LICENSE/COPYING/NOTICE file; NOTICE.md will not cover it."
    }
}
$doc_directory = Join-Path $destination (Join-Path $host_tools.Name 'share/doc/rust')
New-Item -ItemType Directory -Force -Path $doc_directory | Out-Null
Copy-Item -LiteralPath $library_notice -Destination $doc_directory

$after = @(Get-ChildItem -LiteralPath $destination -Directory | ForEach-Object Name)
Write-Output "rust licenses  : $destination ($($crates.Count) crate repositories)"
foreach ($name in (Compare-Object $before $after | Sort-Object InputObject)) {
    Write-Output ('  {0} {1}' -f $(if ($name.SideIndicator -eq '=>') { '+' } else { '-' }), $name.InputObject)
}
