<#
.SYNOPSIS
    Sets up the GitGud Desktop build on Windows: finds Visual Studio, fetches
    and patches CEGUI, builds CEGUI, then builds the app.

.DESCRIPTION
    Safe to run again at any time: every step checks what's already done.

      1. Finds Visual Studio (with the C++ workload) and loads its developer
         environment, which provides MSVC, CMake, Ninja, and vcpkg.
      2. Checks out the third_party/cegui submodule if it isn't yet.
      3. Applies every patch in third_party/patches/cegui (in name order),
         skipping the ones already applied.
      4. Builds and installs CEGUI for the configuration(s) the chosen preset
         needs. A stamp file in each install remembers the submodule commit
         and the patches it was built from, so CEGUI is only rebuilt when
         one of those changes (or with -Force).
      5. Configures and builds the app with the chosen CMake preset, and
         optionally runs the engine tests.

    The first run downloads and builds the vcpkg dependencies (OpenSSL among
    them) and CEGUI, which takes a while. Later runs take seconds.

.PARAMETER Preset
    The app preset to build: release (default, day-to-day), full (Debug, for
    the debugger), or nogui (engine and tests only, no CEGUI needed).

.PARAMETER AllConfigurations
    Build both the Release and the Debug CEGUI, whatever the preset.

.PARAMETER SkipApp
    Stop after setting up CEGUI.

.PARAMETER Test
    Run the engine tests after building.

.PARAMETER Force
    Rebuild CEGUI even if it looks up to date.

.EXAMPLE
    .\setup.cmd
    .\setup.cmd -Preset full -Test
#>
[CmdletBinding()]
param(
    [ValidateSet("release", "full", "nogui")]
    [string]$Preset = "release",
    [switch]$AllConfigurations,
    [switch]$SkipApp,
    [switch]$Test,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$CeguiSource = Join-Path $Root "third_party\cegui"
$PatchDir = Join-Path $Root "third_party\patches\cegui"

# ---------------------------------------------------------------- helpers --

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note($Message) {
    Write-Host "    $Message" -ForegroundColor DarkGray
}

# Run a native command; stop the script if it fails.
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Program $($Arguments -join ' ')' failed (exit code $LASTEXITCODE)"
    }
}

# Run a native command quietly and report whether it succeeded.
function Test-Command {
    param([string]$Program, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Program @Arguments *> $null
    $ok = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previous
    return $ok
}

# ------------------------------------------------------- 1. Visual Studio --

function Enter-DevEnvironment {
    Write-Step "Visual Studio"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git isn't on PATH. Install Git for Windows (https://git-scm.com) and rerun."
    }

    if ($env:VCPKG_ROOT -and (Get-Command cl -ErrorAction SilentlyContinue)) {
        Write-Note "already in a developer shell (VCPKG_ROOT=$env:VCPKG_ROOT)"
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "Visual Studio wasn't found. Install Visual Studio 2022 or newer with 'Desktop development with C++'."
    }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) {
        throw "Visual Studio is installed without the C++ tools. Add the 'Desktop development with C++' workload in the Visual Studio Installer."
    }
    Write-Note $vs

    # Launch-VsDevShell looks for vswhere on PATH; give it the installer's copy.
    # It may point VCPKG_ROOT at Visual Studio's own vcpkg; one set beforehand wins.
    $ownVcpkg = $env:VCPKG_ROOT
    $env:PATH = "$(Split-Path $vswhere);$env:PATH"
    & (Join-Path $vs "Common7\Tools\Launch-VsDevShell.ps1") -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    Set-Location $Root
    if ($ownVcpkg) {
        $env:VCPKG_ROOT = $ownVcpkg
    }

    if (-not $env:VCPKG_ROOT) {
        $bundled = Join-Path $vs "VC\vcpkg"
        if (-not (Test-Path (Join-Path $bundled "scripts\buildsystems\vcpkg.cmake"))) {
            throw "vcpkg wasn't found. Add the 'vcpkg package manager' component in the Visual Studio Installer, or set VCPKG_ROOT."
        }
        $env:VCPKG_ROOT = $bundled
    }
    foreach ($tool in @("cmake", "ninja", "cl")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' isn't available in the Visual Studio environment. Make sure the C++ workload includes 'C++ CMake tools for Windows'."
        }
    }
    Write-Note "vcpkg: $env:VCPKG_ROOT"
}

# ----------------------------------------------------- 2. CEGUI submodule --

function Initialize-Cegui {
    Write-Step "CEGUI source (third_party/cegui)"

    $checkedOut = Test-Path (Join-Path $CeguiSource "cegui\src")
    if (-not $checkedOut) {
        Write-Note "checking out the submodule"
        Invoke-Checked git @("-C", $Root, "submodule", "update", "--init", "third_party/cegui")
        return
    }

    # Already there: make sure it's the commit this repository expects. A
    # different commit with local edits is left alone rather than lost.
    $expected = (& git -C $Root ls-tree HEAD third_party/cegui).Split()[2]
    $actual = (& git -C $CeguiSource rev-parse HEAD).Trim()
    if ($expected -and $actual -ne $expected) {
        $dirty = & git -C $CeguiSource status --porcelain --untracked-files=no
        if ($dirty) {
            throw "third_party/cegui is at $($actual.Substring(0,9)) but this repository expects $($expected.Substring(0,9)), and it has local edits. Revert them (git -C third_party/cegui checkout -- .) and rerun."
        }
        Write-Note "moving to the expected commit $($expected.Substring(0,9))"
        Invoke-Checked git @("-C", $Root, "submodule", "update", "--init", "third_party/cegui")
    } else {
        Write-Note "at $($actual.Substring(0,9)) as expected"
    }
}

# ----------------------------------------------------------- 3. Patches --

function Install-Patches {
    Write-Step "CEGUI patches (third_party/patches/cegui)"

    $patches = Get-ChildItem $PatchDir -Filter *.patch | Sort-Object Name
    foreach ($patch in $patches) {
        # Already applied if it can be applied in reverse.
        if (Test-Command git @("-C", $CeguiSource, "apply", "--check", "--reverse", "--ignore-whitespace", $patch.FullName)) {
            Write-Note "$($patch.Name): already applied"
            continue
        }
        if (-not (Test-Command git @("-C", $CeguiSource, "apply", "--check", "--ignore-whitespace", $patch.FullName))) {
            throw "$($patch.Name) doesn't apply to third_party/cegui (it has other local edits?). Revert them with 'git -C third_party/cegui checkout -- .' and rerun."
        }
        Invoke-Checked git @("-C", $CeguiSource, "apply", "--ignore-whitespace", $patch.FullName)
        Write-Note "$($patch.Name): applied"
    }
    return $patches
}

# -------------------------------------------------------- 4. Build CEGUI --

# CEGUI's build options. Everything CEGUI would otherwise switch on by itself
# when it finds a library on the build machine is set explicitly, so every
# machine builds the same CEGUI. Part of the fingerprint below: changing one
# rebuilds CEGUI.
$CeguiOptions = @(
    "-DCEGUI_BUILD_RENDERER_OPENGL3=ON", "-DCEGUI_BUILD_RENDERER_OPENGL=OFF",
    "-DCEGUI_BUILD_RENDERER_OPENGLES=OFF", "-DCEGUI_BUILD_RENDERER_OPENGLES2_ALTERNATE=OFF",
    "-DCEGUI_BUILD_RENDERER_OGRE=OFF", "-DCEGUI_BUILD_RENDERER_IRRLICHT=OFF",
    "-DCEGUI_BUILD_RENDERER_DIRECT3D11=OFF",
    "-DCEGUI_BUILD_XMLPARSER_PUGIXML=ON", "-DCEGUI_BUILD_XMLPARSER_EXPAT=OFF",
    "-DCEGUI_BUILD_XMLPARSER_LIBXML2=OFF", "-DCEGUI_BUILD_XMLPARSER_XERCES=OFF",
    "-DCEGUI_BUILD_XMLPARSER_TINYXML2=OFF",
    "-DCEGUI_BUILD_IMAGECODEC_STB=ON", "-DCEGUI_BUILD_IMAGECODEC_SILLY=OFF",
    "-DCEGUI_BUILD_IMAGECODEC_DEVIL=OFF", "-DCEGUI_BUILD_IMAGECODEC_FREEIMAGE=OFF",
    "-DCEGUI_BUILD_IMAGECODEC_CORONA=OFF", "-DCEGUI_BUILD_IMAGECODEC_PVR=OFF",
    "-DCEGUI_BUILD_IMAGECODEC_SDL2=OFF",
    "-DCEGUI_BUILD_RESOURCE_PROVIDER_MINIZIP=OFF", "-DCEGUI_REGEX_MATCHER=std",
    "-DCEGUI_USE_FREETYPE=ON", "-DCEGUI_USE_RAQM=OFF", "-DCEGUI_USE_FRIBIDI=OFF",
    "-DCEGUI_BUILD_SAMPLES=OFF",
    "-DCEGUI_BUILD_APPLICATION_TEMPLATES=OFF", "-DCEGUI_BUILD_LUA_MODULE=OFF",
    # Off even where Python and SWIG are installed (they'd switch it on).
    "-DCEGUI_BUILD_PYTHON_MODULES_SWIG=OFF", "-DCEGUI_BUILD_PYTHON_MODULES_PYPLUSPLUS=OFF",
    # Nor search for what only those modules and CEGUI's tests use.
    "-DCMAKE_DISABLE_FIND_PACKAGE_PythonLibs=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_PythonInterp=ON",
    "-DCMAKE_DISABLE_FIND_PACKAGE_Boost=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_SWIG=ON",
    "-DCEGUI_STRING_CLASS=UTF-32"
)

# What a CEGUI install was built from: the submodule commit, its build
# options, and a hash of every patch. When it matches the install's stamp,
# nothing needs rebuilding.
function Get-CeguiFingerprint($Patches) {
    $parts = @((& git -C $CeguiSource rev-parse HEAD).Trim(), "options $($CeguiOptions -join ' ')")
    foreach ($patch in $Patches) {
        $parts += "$($patch.Name) $((Get-FileHash $patch.FullName -Algorithm SHA256).Hash)"
    }
    return ($parts -join "`n")
}

function Build-Cegui($Configuration, $Fingerprint) {
    $isDebug = $Configuration -eq "Debug"
    $buildDir = Join-Path $Root $(if ($isDebug) { "build\cegui" } else { "build\cegui-rel" })
    $installDir = Join-Path $Root $(if ($isDebug) { "third_party\cegui-install" } else { "third_party\cegui-install-release" })
    $stamp = Join-Path $installDir ".gitgud-stamp"

    Write-Step "CEGUI $Configuration -> $(Resolve-Path -Relative $installDir -ErrorAction SilentlyContinue)"
    if (-not $Force -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $Fingerprint.Trim())) {
        Write-Note "up to date (use -Force to rebuild)"
        return $false
    }

    $root = $Root -replace "\\", "/"
    $toolchain = "$($env:VCPKG_ROOT -replace '\\', '/')/scripts/buildsystems/vcpkg.cmake"
    Invoke-Checked cmake (@(
        "-S", "$root/third_party/cegui", "-B", ($buildDir -replace "\\", "/"), "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-DCMAKE_INSTALL_PREFIX=$($installDir -replace '\\', '/')",
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
        "-DVCPKG_MANIFEST_DIR=$root/third_party/cegui-manifest"
    ) + $CeguiOptions)
    Invoke-Checked cmake @("--build", $buildDir)
    Invoke-Checked cmake @("--install", $buildDir)
    Set-Content -Path $stamp -Value $Fingerprint -Encoding ascii
    return $true
}

# An app build that already exists only copies CEGUI's DLLs when gitgud.exe
# relinks; after a CEGUI rebuild, refresh them directly.
function Update-AppDlls($Configuration) {
    $isDebug = $Configuration -eq "Debug"
    $installBin = Join-Path $Root $(if ($isDebug) { "third_party\cegui-install\bin" } else { "third_party\cegui-install-release\bin" })
    $presets = if ($isDebug) { @("full") } else { @("release") }
    foreach ($name in $presets) {
        $appBin = Join-Path $Root "build\$name\bin"
        if (Test-Path $appBin) {
            try {
                Copy-Item -Force (Join-Path $installBin "*.dll") $appBin
                Write-Note "refreshed CEGUI DLLs in build\$name\bin"
            } catch {
                Write-Warning "Couldn't refresh the DLLs in build\$name\bin (is GitGud running?). Close it and rerun."
            }
        }
    }
}

# ---------------------------------------------------------------- 5. App --

function Build-App {
    Write-Step "GitGud ($Preset preset)"
    Invoke-Checked cmake @("--preset", $Preset)
    Invoke-Checked cmake @("--build", "--preset", $Preset)
    Write-Note "built: build\$Preset\bin"

    if ($Test) {
        Write-Step "Engine tests"
        Invoke-Checked (Join-Path $Root "build\$Preset\bin\gitgud_tests.exe") @()
    }
}

# ------------------------------------------------------------------ main --

$started = Get-Date
Push-Location $Root
try {
    Enter-DevEnvironment

    $configurations = @()
    if ($AllConfigurations) {
        $configurations = @("Release", "Debug")
    } elseif ($Preset -eq "release") {
        $configurations = @("Release")
    } elseif ($Preset -eq "full") {
        $configurations = @("Debug")
    }

    if ($configurations.Count -gt 0) {
        Initialize-Cegui
        $patches = Install-Patches
        $fingerprint = Get-CeguiFingerprint $patches
        foreach ($configuration in $configurations) {
            if (Build-Cegui $configuration $fingerprint) {
                Update-AppDlls $configuration
            }
        }
    }

    if (-not $SkipApp) {
        Build-App
    }

    $minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    Write-Host ""
    Write-Host "Done in $minutes min." -ForegroundColor Green
    if (-not $SkipApp -and $Preset -ne "nogui") {
        Write-Host "Run it (add a repository path to open one):  & `"$Root\build\$Preset\bin\gitgud.exe`""
    }
} catch {
    Write-Host ""
    Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
