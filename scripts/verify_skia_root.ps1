# 사용자가 빌드한 Skia가 luil과 맞는지 검사한다.
# CMake의 configure 검사와 같은 판정을 사람이 먼저 돌려볼 수 있게 하는 것이 목적이다.
# docs/skia-build.md를 본다.

[CmdletBinding()]
param(
    [string]$SkiaRoot,
    [string[]]$Configurations = @('Debug', 'Release'),
    # build_skia.ps1의 -Target과 같은 값이다. 읽는 자리와 판정이 갈린다.
    [ValidateSet('win-x64', 'android-arm64')]
    [string]$Target = 'win-x64',
    # build_skia.ps1의 -OutputSuffix와 같은 값이다.
    [string]$OutputSuffix
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository_root = Split-Path -Parent $PSScriptRoot
if (-not $SkiaRoot) {
    $SkiaRoot = Join-Path $repository_root 'third_party\skia'
}
$is_android = $Target -like 'android-*'
$target_part = if ($is_android) { "$Target-" } else { '' }

# win-x64는 luil CMakeLists.txt의 LUIL_SKIA_COMPONENTS에서 png 갈래 몫을 뺀 목록이다
# (파일 이름 그대로). android-arm64는 build_skia.ps1이 내는 것 전부다 — libpng과
# zlib은 freetype이 끌어오므로 png 갈래와 무관하게 이쪽에 있고, cpu-features는
# NDK의 sources/android/cpufeatures를 Skia가 컴파일한 것이다.
if ($is_android) {
    $components = @(
        'libskia.a', 'libskcms.a',
        'libjpeg.a', 'libjpeg12.a', 'libjpeg16.a',
        'libwebp.a', 'libwebp_sse41.a', 'libwuffs.a',
        'libfreetype2.a', 'libexpat.a', 'libpng.a', 'libzlib.a', 'libcpu-features.a')
    $libpng_components = @()
}
else {
    $components = @(
        'skia.lib', 'skcms.lib', 'spirv_cross.lib', 'd3d12allocator.lib',
        'libjpeg.lib', 'libjpeg12.lib', 'libjpeg16.lib',
        'libwebp.lib', 'libwebp_sse41.lib', 'wuffs.lib')
    # png 코덱에 따라 갈리는 산출물이다.
    $libpng_components = @('libpng.lib', 'zlib.lib')
}
$rust_png_components = @('librust_png_ffi_rs.a', 'libcxx_cc.a')
# 이 저장소가 고정한 Skia의 밀번이다 (docs/skia-build.md 7).
# rust png 갈래는 152 아래에서 아예 서지 않는다 (5.3).
$minimum_milestone = 152
# win-x64는 luil CMakeLists.txt의 LUIL_SKIA_REQUIRED_ARGUMENTS와 같은 목록이다.
# android-arm64는 luil에 아직 짝이 없다 — 이 저장소의 Android args가 켜는 것을
# 그대로 요구한다 (docs/skia-build.md 8).
# png은 둘 중 하나라 여기 없다 — 아래에서 따로 판정한다.
$codec_arguments = @(
    @{ name = 'skia_use_libjpeg_turbo_decode'; reason = 'jpeg decoding' },
    @{ name = 'skia_use_libwebp_decode'; reason = 'webp decoding, still and animated' },
    @{ name = 'skia_use_wuffs'; reason = 'gif decoding' })
$required_arguments = if ($is_android) {
    @(
        @{ name = 'skia_use_vulkan'; reason = 'the Android GPU backend' },
        @{ name = 'skia_use_freetype'; reason = 'system fonts (SkFontMgr_android)' },
        @{ name = 'skia_use_expat'; reason = 'reads /system/etc/fonts.xml' }) + $codec_arguments
}
else {
    @(@{ name = 'skia_use_direct3d'; reason = 'required by the renderer' }) + $codec_arguments
}
# 반드시 꺼져 있어야 하는 것들이다. 둘 다 clang에서만 실물이 되고, 켜지면
# 소비자와 어긋난다 — is_trivial_abi는 ABI를(MSVC 소비자에게 그 속성이 없다),
# skia_use_partition_alloc은 external과 raw_ptr 구현을 바꾼다.
# 뒤엣것은 **기본값이 is_clang이라 명시하지 않으면 저절로 켜진다.**
$forbidden_arguments = @(
    @{ name = 'is_trivial_abi'; reason = 'would change the ABI seen by MSVC consumers' },
    @{ name = 'skia_use_partition_alloc'; reason = 'defaults to is_clang; pulls in a new external' })
$failures = [System.Collections.Generic.List[string]]::new()

# clang-cl이 낸 object인지 정적으로 판정한다.
#
# args.gn의 clang_win은 "그렇게 gen했다"는 말일 뿐 산출물의 사실이 아니고,
# CRT 지시문은 두 도구사슬이 똑같이 낸다(그것이 이 조합의 요점이다). 실제로
# 무엇이 컴파일했는지를 아카이브 자신에게 묻는 자리가 필요하다.
#
# .llvm_addrsig는 clang이 -faddrsig(기본값)로 내는 LLVM 고유 section이다.
# 이름이 여덟 자를 넘어 COFF 문자열 테이블에 그대로 들어가므로, 바이트를 훑는
# 것만으로 판정된다 — dumpbin도 필요 없고 32 MB에 50 ms면 끝난다.
Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class SkiaArchiveMarker {
    public static bool Contains(string path, string needle) {
        byte[] pattern = System.Text.Encoding.ASCII.GetBytes(needle);
        using (FileStream file = File.OpenRead(path)) {
            byte[] buffer = new byte[1 << 20];
            int carry = pattern.Length - 1;
            int offset = 0;
            int read;
            while ((read = file.Read(buffer, offset, buffer.Length - offset)) > 0) {
                int total = offset + read;
                for (int i = 0; i + pattern.Length <= total; i++) {
                    int j = 0;
                    while (j < pattern.Length && buffer[i + j] == pattern[j]) { j++; }
                    if (j == pattern.Length) { return true; }
                }
                if (total >= carry) {
                    Array.Copy(buffer, total - carry, buffer, 0, carry);
                    offset = carry;
                } else {
                    offset = total;
                }
            }
        }
        return false;
    }
}

// ar 아카이브의 ELF member가 무슨 CPU용인지 센다 (Android 대상).
//
// 바이트에서 "\x7fELF"를 훑지 않고 ar 머리를 따라 member를 하나씩 걷는다 —
// 그 네 바이트는 데이터 안에서도 나온다. member 머리는 60바이트이고 크기가
// 48번째부터 10자리 십진수이며, 본문은 짝수 경계로 채워진다. 이름이 "/"
// (심볼 표)·"//"(긴 이름 표)·"/SYM64/"인 member는 object가 아니다.
public static class SkiaArchiveElf {
    // 반환: [AArch64 member 수, 다른 CPU member 수, 첫 다른 e_machine 값].
    public static long[] CountMachines(string path) {
        long aarch64 = 0, other = 0, first_other = -1;
        using (FileStream file = File.OpenRead(path))
        using (BinaryReader reader = new BinaryReader(file)) {
            byte[] magic = reader.ReadBytes(8);
            if (System.Text.Encoding.ASCII.GetString(magic) != "!<arch>\n") {
                throw new InvalidDataException("not an ar archive: " + path);
            }
            while (file.Position + 60 <= file.Length) {
                byte[] header = reader.ReadBytes(60);
                string name = System.Text.Encoding.ASCII.GetString(header, 0, 16).TrimEnd(' ');
                long size = long.Parse(System.Text.Encoding.ASCII.GetString(header, 48, 10).Trim());
                long start = file.Position;
                bool special = name == "/" || name == "//" || name == "/SYM64/";
                if (!special && size >= 20) {
                    byte[] elf = reader.ReadBytes(20);
                    if (elf[0] == 0x7f && elf[1] == (byte)'E' && elf[2] == (byte)'L' && elf[3] == (byte)'F') {
                        int machine = elf[5] == 1 ? (elf[18] | (elf[19] << 8)) : ((elf[18] << 8) | elf[19]);
                        if (machine == 0xB7) {
                            aarch64++;
                        } else {
                            other++;
                            if (first_other < 0) { first_other = machine; }
                        }
                    }
                }
                file.Position = start + size + (size & 1);
            }
        }
        return new long[] { aarch64, other, first_other };
    }
}
'@

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

# COFF 지시문 검사는 Windows 대상의 것이다. Android 아카이브는 ELF라 dumpbin이 읽지 못한다.
$dumpbin = if ($is_android) { '' } else { Find-Dumpbin }

foreach ($configuration in $Configurations) {
    Write-Output ''
    $directory = Join-Path $SkiaRoot `
        ('out\skia-ui-{0}{1}{2}' -f $target_part, $configuration.ToLowerInvariant(), $OutputSuffix)
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

        foreach ($forbidden in $forbidden_arguments) {
            Add-Result "$configuration/$($forbidden.name)" `
                (-not ($arguments_text -match ('{0}\s*=\s*true' -f $forbidden.name))) `
                ('must stay false — ' + $forbidden.reason)
        }
        if ($is_android) {
            # Android의 도구사슬은 NDK다. args가 대상과 NDK를 함께 말해야 한다.
            $target_ok = $arguments_text -match 'target_os\s*=\s*"android"' -and
                $arguments_text -match 'target_cpu\s*=\s*"arm64"'
            Add-Result "$configuration/target" $target_ok 'target_os = "android", target_cpu = "arm64"'
            $ndk = if ($arguments_text -match '(?m)^\s*ndk\s*=\s*"([^"]+)"') { $Matches[1] } else { '' }
            Add-Result "$configuration/toolchain arg" ([bool]$ndk) `
                $(if ($ndk) { "ndk = $ndk" } else { 'ndk is not set; build with scripts/build_skia.ps1 -Target android-arm64' })
        }
        else {
            # 도구사슬이다. 이 저장소가 발행하는 것은 clang-cl 갈래 하나뿐이다.
            # MSVC로 세운 Skia도 링크는 되지만 CPU 래스터 파이프라인이 폭 1의
            # scalar 경로로 돌아, 소비자가 받는 물건으로는 다른 것이다
            # (docs/skia-build.md 5.4).
            $clang_win = if ($arguments_text -match 'clang_win\s*=\s*"([^"]+)"') { $Matches[1] } else { '' }
            Add-Result "$configuration/toolchain arg" ([bool]$clang_win) `
                $(if ($clang_win) { "clang_win = $clang_win" }
                    else { 'clang_win is not set; this was built with MSVC (-Toolchain msvc)' })
        }
    }
    else {
        Add-Result "$configuration/args.gn" $false 'missing'
    }

    # Android에서 아카이브에 물을 것은 CPU다. libskia.a는 GN이 NDK로 세우므로
    # 언제나 맞는다. 어긋나는 것은 rust 아카이브다 — GN이 Bazel에 Android
    # 플랫폼을 넘기지 않으면(skia-152-bazel-rust-android-platform.patch가 빠지면)
    # 그것만 조용히 호스트(x86_64)용으로 서고, 링크 단계에서야 드러난다.
    if ($is_android) {
        $elf_archives = @('libskia.a')
        if ($png_codec -eq 'rust') {
            $elf_archives += $rust_png_components
        }
        foreach ($component in $elf_archives) {
            $library = Join-Path $directory $component
            if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
                continue
            }
            $counts = [SkiaArchiveElf]::CountMachines($library)
            $ok = $counts[0] -gt 0 -and $counts[1] -eq 0
            $detail = if ($counts[1] -eq 0) { '{0} AArch64 objects' -f $counts[0] }
            else { '{0} objects are not AArch64 (e_machine 0x{1:X}); the rust build missed the Android platform' -f $counts[1], $counts[2] }
            Add-Result "$configuration/$component CPU" $ok $detail
        }
    }

    # args.gn은 "그렇게 gen했다"는 말이다. 아카이브 자신에게 무엇이 컴파일했는지
    # 묻는 자리가 따로 있어야 한다 — .llvm_addrsig가 clang만 내는 section이다.
    $archive = Join-Path $directory 'skia.lib'
    if (-not $is_android -and (Test-Path -LiteralPath $archive)) {
        $built_by_clang = [SkiaArchiveMarker]::Contains($archive, '.llvm_addrsig')
        Add-Result "$configuration/built by clang-cl" $built_by_clang `
            $(if ($built_by_clang) { 'skia.lib carries LLVM sections' }
                else { 'no LLVM sections; the raster pipeline is the scalar path' })
    }

    # 무엇으로 세웠는지를 build_skia.ps1이 적어 둔 자리다. 없어도 위의 두 검사가
    # 판정을 마치므로 실패로 보지 않는다 — 옛 산출 디렉터리에는 이 파일이 없다.
    $toolchain_file = Join-Path $directory 'toolchain.json'
    if (Test-Path -LiteralPath $toolchain_file -PathType Leaf) {
        $toolchain = Get-Content -Raw -LiteralPath $toolchain_file | ConvertFrom-Json
        $summary = if ($is_android) {
            'NDK r{0}, ndk_api {1}, rust bridge NDK r{2}' -f $toolchain.ndk_revision,
            $toolchain.ndk_api, $toolchain.rust_bridge_ndk_revision
        }
        else {
            '{0} {1}, MSVC {2}, Windows SDK {3}' -f $toolchain.compiler,
            $toolchain.compiler_version, $toolchain.msvc_version, $toolchain.windows_sdk
        }
        Write-Output ("[    ] {0,-42} {1}" -f "$configuration/toolchain.json", $summary)
    }

    # 정적 CRT가 luil과 어긋나면 LNK2038로 드러난다.
    # 미리 잡는다.
    #
    # 이름이 두 가지다. MSVC의 CRT 헤더는 `LIBCMT`를 pragma로 심고, clang-cl은
    # /MT를 보고 스스로 `libcmt.lib`를 심는다. 가리키는 라이브러리는 같은 것이므로
    # 확장자를 선택으로 둔다 — 그러지 않으면 clang 갈래가 여기서 헛되이 걸린다.
    # 함께 보는 FAILIFMISMATCH는 두 도구사슬이 똑같이 내는 값이고, 링커가 실제로
    # 대조하는 것도 그쪽이다.
    $library = Join-Path $directory 'skia.lib'
    if ($dumpbin -and (Test-Path -LiteralPath $library)) {
        $expected = if ($configuration -eq 'Debug') { 'LIBCMTD' } else { 'LIBCMT' }
        $expected_runtime = if ($configuration -eq 'Debug') { 'MTd_StaticDebug' } else { 'MT_StaticRelease' }
        $expected_iterator = if ($configuration -eq 'Debug') { '2' } else { '0' }
        $directives = & $dumpbin /directives $library 2>$null |
            Select-String 'DEFAULTLIB|FAILIFMISMATCH' |
            ForEach-Object { $_.Line.Trim() } |
            Sort-Object -Unique
        $matched = $directives | Where-Object { $_ -match "/DEFAULTLIB:$expected(\.lib)?$" }
        Add-Result "$configuration/static CRT" ([bool]$matched) "expects /DEFAULTLIB:$expected"
        $runtime_ok = $directives | Where-Object { $_ -match "RuntimeLibrary=$expected_runtime$" }
        $iterator_ok = $directives | Where-Object { $_ -match "_ITERATOR_DEBUG_LEVEL=$expected_iterator$" }
        Add-Result "$configuration/skia.lib C++ ABI" ([bool]$runtime_ok -and [bool]$iterator_ok) `
            "expects iterator $expected_iterator, $expected_runtime"
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
