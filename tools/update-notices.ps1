<#
.SYNOPSIS
    Regenerates THIRD_PARTY_NOTICES.txt: the license of every third-party
    component that ships with GitGud Desktop.

.DESCRIPTION
    Covers every vcpkg package in the release build (its license text from
    vcpkg_installed\<triplet>\share\<package>\copyright, or from
    tools\notices\<package>.txt where vcpkg's file only points elsewhere),
    plus CEGUI, the DejaVu font CEGUI's data files bring, the Inter,
    JetBrains Mono, and Manrope fonts, and the Bragi interface's speech
    engine (sherpa-onnx and ONNX Runtime, in the package's voice folder),
    with credits for the voice models it downloads on request. Build-only
    packages (tests, build tooling) are left out.

    Run it after adding or upgrading a dependency, and commit the result.
    package.ps1 runs it with -Check and refuses to package when the committed
    file doesn't match what the build actually ships.

.PARAMETER Check
    Don't write anything; fail if THIRD_PARTY_NOTICES.txt is out of date.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\update-notices.ps1
#>
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Output = Join-Path $Root "THIRD_PARTY_NOTICES.txt"
$Installed = Join-Path $Root "build\release\vcpkg_installed"
$Triplet = "x64-windows"
$Overrides = Join-Path $PSScriptRoot "notices"

# Packages that never ship: the test framework, vcpkg's own build helpers,
# and the stub that points at the Windows SDK's OpenGL.
$BuildOnly = @("catch2", "opengl", "vcpkg-cmake", "vcpkg-cmake-config", "vcpkg-cmake-get-vars")

$Rule = "=" * 78

# Read a text file as UTF-8 with LF line endings and no trailing blank lines.
function Read-Text($Path) {
    return (([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) -replace "`r`n", "`n").TrimEnd()
}

function Format-Section($Title, $Body) {
    return "$Rule`n$Title`n$Rule`n`n$Body`n"
}

$info = Join-Path $Installed "vcpkg\info"
if (-not (Test-Path $info)) {
    throw "build\release hasn't been built yet (no vcpkg_installed). Run setup.cmd first."
}

# vcpkg records each installed package as <name>_<version>_<triplet>.list.
$packages = Get-ChildItem $info -Filter "*_$Triplet.list" | ForEach-Object {
    if ($_.Name -match "^(.+)_([^_]+)_$([regex]::Escape($Triplet))\.list$") {
        [pscustomobject]@{ Name = $Matches[1]; Version = $Matches[2] }
    }
} | Where-Object { $BuildOnly -notcontains $_.Name } | Sort-Object Name

$libgit2 = $packages | Where-Object Name -eq "libgit2"
$sections = @()
$sections += @"
GitGud Desktop includes the third-party software listed below. Each part is
distributed under its own license, reproduced in full in its section.

Portions of this software are copyright (c) The FreeType Project
(https://freetype.org). All rights reserved.

libgit2 is distributed under the GNU General Public License version 2 with a
linking exception (see its section). The source of the version included is
at https://github.com/libgit2/libgit2/tree/v$($libgit2.Version).
"@

foreach ($package in $packages) {
    $override = Join-Path $Overrides "$($package.Name).txt"
    $copyright = Join-Path $Installed "$Triplet\share\$($package.Name)\copyright"
    $license = if (Test-Path $override) { $override } elseif (Test-Path $copyright) { $copyright } else { $null }
    if (-not $license) {
        throw "No license text for $($package.Name): add tools\notices\$($package.Name).txt."
    }
    $sections += Format-Section "$($package.Name) $($package.Version)" (Read-Text $license)
}

$cegui = (& git -C (Join-Path $Root "third_party\cegui") rev-parse --short=12 HEAD).Trim()
$fonts = Join-Path $Root "third_party\cegui\datafiles\fonts"
$sections += Format-Section "CEGUI (commit $cegui)" (Read-Text (Join-Path $Root "third_party\cegui\COPYING"))
$sections += Format-Section "DejaVu fonts (DejaVu Sans, from CEGUI's data files)" (Read-Text (Join-Path $fonts "LicenseDejaVu.txt"))
$sections += Format-Section "Inter font" (Read-Text (Join-Path $Root "resources\fonts\LICENSE-Inter.txt"))
$sections += Format-Section "JetBrains Mono font" (Read-Text (Join-Path $Root "resources\fonts\LICENSE-JetBrainsMono.txt"))
$sections += Format-Section "Manrope font (the Bragi interface)" (Read-Text (Join-Path $Root "resources\uis\bragi\fonts\LICENSE-Manrope.txt"))
$sections += Format-Section "sherpa-onnx 1.13.8 (the Bragi interface's speech engine, voice folder)" (Read-Text (Join-Path $Root "third_party\sherpa-onnx\LICENSE"))
$sections += Format-Section "ONNX Runtime 1.28.2 (used by sherpa-onnx, voice folder)" (Read-Text (Join-Path $Root "third_party\onnxruntime\LICENSE"))
$sections += Format-Section "ONNX Runtime 1.28.2 third-party notices" (Read-Text (Join-Path $Root "third_party\onnxruntime\ThirdPartyNotices.txt"))
$sections += Format-Section "Voice models (downloaded by the Bragi interface when you choose; not included)" @"
The Bragi interface's voice runs these models on your computer. They are
not part of GitGud Desktop: its welcome flow or Settings downloads them
from the sherpa-onnx project's releases when you choose to.

Speech recognition: Parakeet TDT 0.6B v2 by NVIDIA, under the Creative
Commons Attribution 4.0 International license (CC-BY-4.0,
https://creativecommons.org/licenses/by/4.0/), converted to int8 ONNX by
the sherpa-onnx project.

Speaker recognition: TitaNet-Large by NVIDIA, under CC-BY-4.0, converted to
ONNX by the sherpa-onnx project.

Speech detection: Silero VAD by the Silero team, under the MIT license.

Wake word spotter: the Zipformer keyword spotter (GigaSpeech, 3.3M) by the
Next-gen Kaldi project, under the Apache License 2.0.
"@
$sections += Format-Section "Voice pack for NVIDIA GPUs (downloaded by the Bragi interface when you choose; not included)" @"
The Bragi interface offers an optional voice pack on computers with a
suitable NVIDIA GPU. It is not part of GitGud Desktop and is never installed
with it: the Bragi interface's welcome flow or Settings downloads it, when
you choose to, from its makers' own downloads into your local app data
folder. GitGud Desktop does not distribute any of it.

ONNX Runtime 1.28.2's CUDA provider (onnxruntime_providers_cuda.dll, MIT),
from the sherpa-onnx project's CUDA release, the same build whose core
ships in the voice folder (its license text and third-party notices are
above).

NVIDIA's CUDA runtime, cuBLAS, cuFFT, cuRAND, NVRTC and nvJitLink, from
NVIDIA's own packages on PyPI (nvidia-cuda-runtime, nvidia-cublas,
nvidia-cufft, nvidia-curand, nvidia-cuda-nvrtc, nvidia-nvjitlink), under
the NVIDIA CUDA Toolkit End User License Agreement
(https://docs.nvidia.com/cuda/eula/index.html), and cuDNN, from
nvidia-cudnn-cu13, under the NVIDIA cuDNN Software License Agreement
(https://docs.nvidia.com/deeplearning/cudnn/latest/reference/eula.html).
They come to your computer from NVIDIA's packages with their license files,
which the voice pack keeps beside them. The CUDA agreement lets
applications distribute some runtime libraries (its Attachment A lists
cudart, cuBLAS, cuFFT, cuRAND and NVRTC, but not nvJitLink), and the cuDNN
agreement names only some of its runtime files; GitGud Desktop doesn't rely
on either grant, because it never distributes these files.

Chatterbox Turbo by Resemble AI, under the MIT license, from Resemble AI's
ONNX export on Hugging Face (ResembleAI/chatterbox-turbo-ONNX). After
download its quantized graphs are changed on your computer (an accuracy
setting on their quantized matrix multiplications, for speed); its weights
are not.

Baldr, the Bragi interface's voice for replies: the recording it is made
from (resources/uis/bragi/voices/baldr/ref.wav, which ships with the
interface) is the project's own.
"@

# LF throughout, even where this script was checked out with CRLF (the
# header above would otherwise carry them).
$text = ((($sections -join "`n") + "`n") -replace "`r`n", "`n")

if ($Check) {
    $current = if (Test-Path $Output) { ([IO.File]::ReadAllText($Output, [Text.Encoding]::UTF8)) -replace "`r`n", "`n" } else { "" }
    if ($current -ne $text) {
        # Say which sections differ, so the cause is clear from a CI log too.
        $expected = $text -split "\n"
        $actual = $current -split "\n"
        $count = [Math]::Max($expected.Count, $actual.Count)
        for ($i = 0; $i -lt $count; $i++) {
            $want = if ($i -lt $expected.Count) { $expected[$i] } else { "<end of file>" }
            $have = if ($i -lt $actual.Count) { $actual[$i] } else { "<end of file>" }
            if ($want -cne $have) {
                $section = "(header)"
                # A section title is the line between two rules.
                for ($j = [Math]::Min($i, $expected.Count - 2); $j -gt 0; $j--) {
                    if ($expected[$j - 1] -eq $Rule -and $expected[$j + 1] -eq $Rule) { $section = $expected[$j]; break }
                }
                Write-Host "First difference at line $($i + 1), in section: $section"
                Write-Host "  this build: $($want -replace "`r", '<CR>')"
                Write-Host "  committed:  $($have -replace "`r", '<CR>')"
                break
            }
        }
        Write-Host "Sections this build ships: $(($sections | ForEach-Object { ($_ -split "\n")[1] } | Select-Object -Skip 1) -join ', ')"
        throw "THIRD_PARTY_NOTICES.txt doesn't match what this build ships. Run tools\update-notices.ps1 and commit the result."
    }
    Write-Host "THIRD_PARTY_NOTICES.txt is up to date ($($packages.Count) packages, CEGUI, 4 fonts, the speech engine)."
    return
}

[IO.File]::WriteAllText($Output, $text, (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote THIRD_PARTY_NOTICES.txt ($($packages.Count) packages, CEGUI, 4 fonts, the speech engine)."
