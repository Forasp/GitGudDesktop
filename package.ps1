<#
.SYNOPSIS
    Packages the release build of GitGud Desktop into a self-contained folder
    and a zip ready to attach to a release.

.DESCRIPTION
    1. Builds the release preset (via setup.ps1) unless -SkipBuild.
    2. Assembles build\dist\GitGud: gitgud.exe, every DLL it needs (including
       the Visual C++ runtime, so no redistributable is required),
       resources\, docs\, and the stock CEGUI data files, plus BUILD-INFO.txt,
       LICENSE, and THIRD_PARTY_NOTICES.txt (checked first against what the
       build ships; see tools\update-notices.ps1).
    3. Checks that every DLL the package's binaries import is in the package
       or part of Windows, then smoke-tests it: starts a copy from an empty
       folder with a throwaway settings folder and checks that the UI came up
       using the packaged files.
    4. Zips the folder as build\dist\GitGud-win64.zip (one GitGud\ folder
       inside).
    5. Compiles installer\gitgud.iss into build\dist\GitGud-win64-setup.exe
       when Inno Setup (6 or later) is installed.
    6. Writes the update files installed copies patch themselves from:
       build\dist\GitGud-win64.pack and update-manifest.txt, signed with
       GITGUD_UPDATE_SIGNING_KEY when it's set. The release workflow attaches
       the zip, the installer, and both update files to the release.

.PARAMETER SkipBuild
    Package whatever is in build\release\bin without building first.

.PARAMETER Installer
    Fail when Inno Setup isn't installed instead of skipping the installer.

.PARAMETER RequireSigned
    Fail when GITGUD_UPDATE_SIGNING_KEY isn't set (releases).

.PARAMETER UpdatePackUrl
    Where the manifest says the pack is. Default: the release's download URL
    for this version. A bare file name means "next to the manifest" (tests).

.PARAMETER OpenGLRuntime
    A folder of OpenGL DLLs (e.g. Mesa's opengl32.dll and libgallium_wgl.dll)
    for smoke-testing on a machine without a GPU, such as a CI runner. They
    are copied next to the smoke test's copy of the app only, never into the
    package.

.EXAMPLE
    .\package.cmd
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$Installer,
    [switch]$RequireSigned,
    [string]$UpdatePackUrl,
    [string]$OpenGLRuntime
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Bin = Join-Path $Root "build\release\bin"
$DistRoot = Join-Path $Root "build\dist"
$Package = Join-Path $DistRoot "GitGud"
$Zip = Join-Path $DistRoot "GitGud-win64.zip"
$SetupName = "GitGud-win64-setup"
$PackName = "GitGud-win64.pack"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note($Message) {
    Write-Host "    $Message" -ForegroundColor DarkGray
}

# Run git in a folder; stop the script if it fails. Returns its output.
function Invoke-Git {
    param([string]$Directory, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git -C $Directory @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return $output
}

# The app version, from CMakeLists.txt's project(... VERSION x.y.z).
function Get-Version {
    $match = Select-String -Path (Join-Path $Root "CMakeLists.txt") -Pattern "^\s*VERSION\s+([0-9.]+)" | Select-Object -First 1
    if ($match) {
        return $match.Matches[0].Groups[1].Value
    }
    return "0.0.0"
}

# The Visual C++ runtime DLLs to ship next to the exe (app-local deployment,
# which Microsoft's redistribution terms allow for these files).
function Get-CrtFolder {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $redist = Join-Path $vs "VC\Redist\MSVC"
    $crt = Get-ChildItem $redist -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^\d" } |
        Sort-Object { [version]($_.Name -replace "[^\d.].*$", "") } -Descending |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName "x64") -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $crt) {
        throw "The Visual C++ runtime DLLs weren't found under $redist."
    }
    return $crt.FullName
}

# dumpbin.exe from the newest MSVC toolset.
function Get-Dumpbin {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $tool = Get-ChildItem (Join-Path $vs "VC\Tools\MSVC") -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "bin\Hostx64\x64\dumpbin.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $tool) {
        throw "dumpbin.exe wasn't found under $vs."
    }
    return $tool
}

# ------------------------------------------------------------------ build --

function Build-Release {
    Write-Step "Building (setup.ps1 -Preset release)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "setup.ps1") -Preset release
    if ($LASTEXITCODE -ne 0) {
        throw "The build failed."
    }
}

# --------------------------------------------------------------- assemble --

# Every file in the package as {Path ('/'-separated, relative), Size, Sha256},
# in a stable order.
function Get-PackageFiles {
    $prefix = (Resolve-Path $Package).Path.TrimEnd("\") + "\"
    Get-ChildItem -Recurse -File $Package |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName.Substring($prefix.Length).Replace("\", "/")
                Full = $_.FullName
                Size = $_.Length
                Sha256 = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
            }
        } |
        Sort-Object { $_.Path } -CaseSensitive
}

# UTF-8 without a BOM and with "\n" line ends: manifests are hashed and
# signed byte for byte.
function Write-TextLf($Path, $Text) {
    [IO.File]::WriteAllBytes($Path, (New-Object Text.UTF8Encoding($false)).GetBytes($Text))
}

function New-Package {
    Write-Step "Assembling $Package"
    if (-not (Test-Path (Join-Path $Bin "gitgud.exe"))) {
        throw "build\release\bin\gitgud.exe doesn't exist. Run without -SkipBuild."
    }
    if (-not (Test-Path (Join-Path $Bin "cegui-datafiles\imagesets\Vanilla.imageset"))) {
        throw "build\release\bin\cegui-datafiles is missing. Rebuild (the resources step copies it)."
    }

    # The licenses of everything shipped must match what's actually shipped.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "tools\update-notices.ps1") -Check
    if ($LASTEXITCODE -ne 0) {
        throw "THIRD_PARTY_NOTICES.txt is out of date (see above)."
    }

    if (Test-Path $Package) {
        Remove-Item -Recurse -Force $Package
    }
    New-Item -ItemType Directory -Force $Package | Out-Null

    Copy-Item (Join-Path $Bin "gitgud.exe") $Package
    Copy-Item (Join-Path $Bin "gitgud-patcher.exe") $Package
    Get-ChildItem $Bin -Filter *.dll | Copy-Item -Destination $Package
    foreach ($folder in @("resources", "docs", "cegui-datafiles")) {
        Copy-Item -Recurse (Join-Path $Bin $folder) (Join-Path $Package $folder)
    }
    foreach ($file in @("LICENSE", "THIRD_PARTY_NOTICES.txt")) {
        Copy-Item (Join-Path $Root $file) $Package
    }

    $crt = Get-CrtFolder
    Get-ChildItem $crt -Filter *.dll | Copy-Item -Destination $Package
    Write-Note "Visual C++ runtime from $crt"

    $commit = (Invoke-Git $Root @("rev-parse", "HEAD")) | Select-Object -First 1
    $dirty = (Invoke-Git $Root @("status", "--porcelain", "--untracked-files=no", "--ignore-submodules")) -ne $null
    $info = @(
        "GitGud Desktop $(Get-Version) (Windows x64, release build)",
        "",
        "Built from:  $commit$(if ($dirty) { ' plus uncommitted changes' })",
        "Built on:    $((Get-Date).ToString('yyyy-MM-dd HH:mm'))",
        "",
        "Run gitgud.exe and add a repository from the window; it reopens the last",
        "one next time. 'gitgud.exe <path>' opens a given repository ('.' for the",
        "current folder). Everything it needs is in this folder; docs\USAGE.md is",
        "the tour. Settings and logs live in %APPDATA%\Gitgud.",
        "",
        "GitGud Desktop is MIT licensed (LICENSE). The third-party software it",
        "includes, and their licenses, are listed in THIRD_PARTY_NOTICES.txt."
    )
    Set-Content -Path (Join-Path $Package "BUILD-INFO.txt") -Value $info -Encoding utf8

    # What this version installs: the updater compares against it to find
    # files a later version drops, and files the user edited.
    $lines = @("gitgud-package 1", "version $(Get-Version)")
    foreach ($file in Get-PackageFiles) {
        $lines += "file $($file.Sha256) $($file.Size) 0 0 $($file.Path)"
    }
    Write-TextLf (Join-Path $Package "package-manifest.txt") (($lines -join "`n") + "`n")

    $size = (Get-ChildItem -Recurse -File $Package | Measure-Object -Sum Length).Sum / 1MB
    Write-Note ("{0} files, {1:N1} MB" -f (Get-ChildItem -Recurse -File $Package).Count, $size)
}

# ------------------------------------------------------------ dependencies --

# Every DLL the packaged exe and DLLs import must be in the package or part of
# Windows. A missing one otherwise shows up as the app failing to start (on a
# machine with no one to click the error dialog: a hang).
function Test-Imports {
    Write-Step "Checking DLL imports"
    $dumpbin = Get-Dumpbin
    $system = Join-Path $env:WINDIR "System32"
    $present = @{}
    Get-ChildItem $Package -File | ForEach-Object { $present[$_.Name.ToLowerInvariant()] = $true }

    $missing = @()
    foreach ($binary in Get-ChildItem $Package -File | Where-Object { $_.Extension -in ".exe", ".dll" }) {
        $inList = $false
        foreach ($line in & $dumpbin /nologo /dependents $binary.FullName) {
            if ($line -match "Image has the following (delay load )?dependencies") {
                $inList = $true
                continue
            }
            if ($inList -and $line -match "^\s+(\S+\.dll)\s*$") {
                $name = $Matches[1].ToLowerInvariant()
                $known = $present.ContainsKey($name) -or $name -like "api-ms-win-*" -or $name -like "ext-ms-*" -or
                    (Test-Path (Join-Path $system $name))
                if (-not $known) {
                    $missing += "$name (needed by $($binary.Name))"
                }
            } elseif ($inList -and $line -match "^\s*Summary") {
                $inList = $false
            }
        }
    }
    if ($missing) {
        throw "The package is missing DLLs: $(($missing | Sort-Object -Unique) -join ', ')"
    }
    Write-Note "every import is in the package or part of Windows"
}

# ------------------------------------------------------------- smoke test --

function Test-Package {
    Write-Step "Smoke test"
    $work = Join-Path $DistRoot "smoke-test"
    if (Test-Path $work) {
        Remove-Item -Recurse -Force $work
    }
    $appData = Join-Path $work "appdata"
    $emptyDir = Join-Path $work "no-repo"
    New-Item -ItemType Directory -Force $appData, $emptyDir | Out-Null
    $script = Join-Path $work "close.lua"
    Set-Content -Path $script -Encoding ascii -Value @(
        'gitgud.after(1500, function()',
        '    print("[smoke] ui up")',
        '    gitgud.emit("window.close", "")',
        'end)'
    )
    $log = Join-Path $work "gitgud.log"

    # Run a copy: a GPU-less machine needs extra OpenGL DLLs, which must not
    # reach the package.
    $app = Join-Path $work "GitGud"
    Copy-Item -Recurse $Package $app
    if ($OpenGLRuntime) {
        Get-ChildItem $OpenGLRuntime -Filter *.dll | Copy-Item -Destination $app
        Write-Note "OpenGL from $OpenGLRuntime (test copy only)"
    }

    $saved = @{}
    foreach ($name in @("APPDATA", "GITGUD_SCRIPT", "GITGUD_LOG", "GALLIUM_DRIVER")) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        $env:APPDATA = $appData
        $env:GITGUD_SCRIPT = $script
        $env:GITGUD_LOG = $log
        if ($OpenGLRuntime) {
            # Mesa's plain software renderer; its D3D12 driver needs more DLLs.
            $env:GALLIUM_DRIVER = "llvmpipe"
        }
        $started = Get-Date
        $process = Start-Process -FilePath (Join-Path $app "gitgud.exe") -WorkingDirectory $emptyDir -PassThru
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw "The packaged app didn't close within a minute (see $log)."
        }
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }

    $text = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
    $expectedData = (Join-Path $app "cegui-datafiles") -replace "\\", "/"
    if ($text -notmatch "\[smoke\] ui up") {
        throw "The packaged app didn't start properly. Its log: $log"
    }
    if (($text -replace "\\", "/") -notmatch [regex]::Escape($expectedData)) {
        throw "The packaged app didn't use its own CEGUI data files. Its log: $log"
    }
    if ($text -match "failed to load|Lua error|\[lua\] error") {
        throw "The packaged app logged errors. Its log: $log"
    }
    # Installed under Program Files, the app's folder is read only: it may
    # write only to %APPDATA%\Gitgud.
    if (-not (Test-Path (Join-Path $appData "Gitgud\logs\CEGUI.log"))) {
        throw "The packaged app didn't write CEGUI.log to %APPDATA%\Gitgud\logs. Its log: $log"
    }
    $written = @(Get-ChildItem -Recurse -File $app | Where-Object { $_.LastWriteTime -gt $started })
    if ($written) {
        throw "The packaged app wrote into its own folder: $(($written | ForEach-Object { $_.Name }) -join ', ')"
    }
    Write-Note "started from an empty folder, used its own data files, wrote only to %APPDATA%, closed cleanly"
}

# -------------------------------------------------------------------- zip --

function New-Zip {
    Write-Step "Zipping $Zip"
    if (Test-Path $Zip) {
        Remove-Item -Force $Zip
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($Package, $Zip,
        [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Note ("{0:N1} MB" -f ((Get-Item $Zip).Length / 1MB))
}

# -------------------------------------------------------------- installer --

# ISCC.exe from Inno Setup 6 or later: on PATH first (CI puts a pinned copy
# there), else the newest version in the standard install folders.
function Get-Iscc {
    $onPath = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA "Programs")) |
        Where-Object { $_ }
    return $roots |
        ForEach-Object { Get-ChildItem $_ -Directory -Filter "Inno Setup *" -ErrorAction SilentlyContinue } |
        Where-Object { $_.Name -match "^Inno Setup (\d+)$" -and [int]$Matches[1] -ge 6 } |
        Sort-Object { [int]($_.Name -replace "\D", "") } -Descending |
        ForEach-Object { Join-Path $_.FullName "ISCC.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

function New-Installer {
    $iscc = Get-Iscc
    if (-not $iscc) {
        if ($Installer) {
            throw "Inno Setup (ISCC.exe) wasn't found; see https://jrsoftware.org/isinfo.php."
        }
        Write-Step "Skipping the installer (Inno Setup isn't installed)"
        return
    }
    $setup = Join-Path $DistRoot "$SetupName.exe"
    Write-Step "Building $setup"
    if (Test-Path $setup) {
        Remove-Item -Force $setup
    }
    $output = & $iscc /Q "/DAppVersion=$(Get-Version)" "/DSourceDir=$Package" "/DOutputDir=$DistRoot" `
        "/DOutputBaseName=$SetupName" (Join-Path $Root "installer\gitgud.iss") 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed: $($output -join ' ')"
    }
    Write-Note ("{0:N1} MB, with {1}" -f ((Get-Item $setup).Length / 1MB), $iscc)
}

# ---------------------------------------------------------------- updates --

# ECDSA P-256 signature (IEEE P1363 r||s) of $Bytes with a key given as
# base64 of D||X||Y (tools\new-update-key.ps1 makes one).
function Get-UpdateSignature($Bytes, $KeyBase64) {
    $raw = [Convert]::FromBase64String($KeyBase64.Trim())
    if ($raw.Length -ne 96) {
        throw "GITGUD_UPDATE_SIGNING_KEY isn't a key from tools\new-update-key.ps1."
    }
    $point = New-Object Security.Cryptography.ECPoint
    $point.X = [byte[]]$raw[32..63]
    $point.Y = [byte[]]$raw[64..95]
    $parameters = New-Object Security.Cryptography.ECParameters
    $parameters.Curve = [Security.Cryptography.ECCurve+NamedCurves]::nistP256
    $parameters.Q = $point
    $parameters.D = [byte[]]$raw[0..31]
    $ecdsa = [Security.Cryptography.ECDsa]::Create($parameters)
    try {
        return [Convert]::ToBase64String($ecdsa.SignData($Bytes, [Security.Cryptography.HashAlgorithmName]::SHA256))
    } finally {
        $ecdsa.Dispose()
    }
}

# The release's update files: GitGud-win64.pack (every package file
# raw-deflated, back to back) and update-manifest.txt (where each file sits
# in the pack, with its hash), signed when GITGUD_UPDATE_SIGNING_KEY is set.
# Installed copies download only the files that changed (see src\app\Updater.h).
function New-UpdateFiles {
    Write-Step "Building the update files"
    $version = Get-Version
    $packPath = Join-Path $DistRoot $PackName
    $manifestPath = Join-Path $DistRoot "update-manifest.txt"
    $packUrl = if ($UpdatePackUrl) { $UpdatePackUrl } else {
        "https://github.com/Forasp/GitGudDesktop/releases/download/v$version/$PackName"
    }

    $fileLines = @()
    $pack = [IO.File]::Create($packPath)
    try {
        foreach ($file in Get-PackageFiles) {
            $buffer = New-Object IO.MemoryStream
            $deflate = New-Object IO.Compression.DeflateStream($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
            $bytes = [IO.File]::ReadAllBytes($file.Full)
            $deflate.Write($bytes, 0, $bytes.Length)
            $deflate.Dispose()
            $offset = $pack.Position
            $buffer.Position = 0
            $buffer.CopyTo($pack)
            $fileLines += "file $($file.Sha256) $($file.Size) $offset $($buffer.Length) $($file.Path)"
            $buffer.Dispose()
        }
    } finally {
        $pack.Dispose()
    }
    $packHash = (Get-FileHash -Algorithm SHA256 $packPath).Hash.ToLowerInvariant()
    $packSize = (Get-Item $packPath).Length

    $text = (@(
        "gitgud-update 1",
        "version $version",
        "published $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'))",
        "notes https://github.com/Forasp/GitGudDesktop/releases/tag/v$version",
        "pack $packUrl $packSize $packHash"
    ) + $fileLines) -join "`n"
    $text += "`n"

    $key = $env:GITGUD_UPDATE_SIGNING_KEY
    if ($key) {
        $signature = Get-UpdateSignature ((New-Object Text.UTF8Encoding($false)).GetBytes($text)) $key
        $text += "signature $signature`n"
        Write-Note "signed"
    } elseif ($RequireSigned) {
        throw "GITGUD_UPDATE_SIGNING_KEY isn't set; a release's update files must be signed."
    } else {
        Write-Note "NOT signed (GITGUD_UPDATE_SIGNING_KEY isn't set): installed copies won't accept it"
    }
    Write-TextLf $manifestPath $text
    Write-Note ("{0} files, pack {1:N1} MB" -f $fileLines.Count, ($packSize / 1MB))
}

# ------------------------------------------------------------------ main --

try {
    if (-not $SkipBuild) {
        Build-Release
    }
    New-Package
    Test-Imports
    Test-Package
    New-Zip
    New-Installer
    New-UpdateFiles
    Write-Host ""
    Write-Host "Package ready in $DistRoot" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "Packaging failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
