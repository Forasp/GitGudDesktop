<#
.SYNOPSIS
    Packages the release build of GitGud Desktop into a self-contained folder
    and (with -Publish) stores it on the repository's `dist` branch.

.DESCRIPTION
    1. Builds the release preset (via setup.ps1) unless -SkipBuild.
    2. Assembles build\dist\GitGud: gitgud.exe, every DLL it needs (including
       the Visual C++ runtime, so no redistributable is required),
       resources\, docs\, and the stock CEGUI data files, plus BUILD-INFO.txt.
    3. Smoke-tests the package: starts the packaged exe from an empty folder
       with a throwaway settings folder and checks that the UI came up using
       the packaged files.
    4. With -Publish, replaces the local `dist` branch with ONE commit holding
       exactly the package. It is built in a temporary git worktree, so your
       own checkout, index, and branch are never touched. The branch never
       grows (each publish replaces it), so clones of the source stay small.
       With -Push it is also force-pushed to `origin` (a force push, because
       the branch is replaced, not appended to).

    Someone who only wants the app can then fetch just that branch:
        git clone --branch dist --single-branch --depth 1 <repository url> GitGud

.PARAMETER SkipBuild
    Package whatever is in build\release\bin without building first.

.PARAMETER Publish
    Commit the package to the local `dist` branch.

.PARAMETER Push
    With -Publish: force-push `dist` to origin afterwards.

.EXAMPLE
    .\package.cmd -Publish
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$Publish,
    [switch]$Push
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Bin = Join-Path $Root "build\release\bin"
$DistRoot = Join-Path $Root "build\dist"
$Package = Join-Path $DistRoot "GitGud"
$Branch = "dist"

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

# ------------------------------------------------------------------ build --

function Build-Release {
    Write-Step "Building (setup.ps1 -Preset release)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "setup.ps1") -Preset release
    if ($LASTEXITCODE -ne 0) {
        throw "The build failed."
    }
}

# --------------------------------------------------------------- assemble --

function New-Package {
    Write-Step "Assembling $Package"
    if (-not (Test-Path (Join-Path $Bin "gitgud.exe"))) {
        throw "build\release\bin\gitgud.exe doesn't exist. Run without -SkipBuild."
    }
    if (-not (Test-Path (Join-Path $Bin "cegui-datafiles\imagesets\Vanilla.imageset"))) {
        throw "build\release\bin\cegui-datafiles is missing. Rebuild (the resources step copies it)."
    }

    if (Test-Path $Package) {
        Remove-Item -Recurse -Force $Package
    }
    New-Item -ItemType Directory -Force $Package | Out-Null

    Copy-Item (Join-Path $Bin "gitgud.exe") $Package
    Get-ChildItem $Bin -Filter *.dll | Copy-Item -Destination $Package
    foreach ($folder in @("resources", "docs", "cegui-datafiles")) {
        Copy-Item -Recurse (Join-Path $Bin $folder) (Join-Path $Package $folder)
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
        "Run gitgud.exe from inside a repository folder, or start it anywhere and",
        "add a repository from the window. Everything it needs is in this folder;",
        "docs\USAGE.md is the tour. Settings live in %APPDATA%\Gitgud."
    )
    Set-Content -Path (Join-Path $Package "BUILD-INFO.txt") -Value $info -Encoding utf8

    $size = (Get-ChildItem -Recurse -File $Package | Measure-Object -Sum Length).Sum / 1MB
    Write-Note ("{0} files, {1:N1} MB" -f (Get-ChildItem -Recurse -File $Package).Count, $size)
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

    # The app writes files next to itself (CEGUI.log); keep them out of the package.
    $before = @(Get-ChildItem -Recurse -File $Package | ForEach-Object { $_.FullName })

    $saved = @{}
    foreach ($name in @("APPDATA", "GITGUD_SCRIPT", "GITGUD_LOG")) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        $env:APPDATA = $appData
        $env:GITGUD_SCRIPT = $script
        $env:GITGUD_LOG = $log
        $process = Start-Process -FilePath (Join-Path $Package "gitgud.exe") -WorkingDirectory $emptyDir -PassThru
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw "The packaged app didn't close within a minute (see $log)."
        }
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
        Get-ChildItem -Recurse -File $Package |
            Where-Object { $before -notcontains $_.FullName } |
            Move-Item -Destination $work -Force
    }

    $text = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
    $expectedData = (Join-Path $Package "cegui-datafiles") -replace "\\", "/"
    if ($text -notmatch "\[smoke\] ui up") {
        throw "The packaged app didn't start properly. Its log: $log"
    }
    if (($text -replace "\\", "/") -notmatch [regex]::Escape($expectedData)) {
        throw "The packaged app didn't use its own CEGUI data files. Its log: $log"
    }
    if ($text -match "failed to load|Lua error|\[lua\] error") {
        throw "The packaged app logged errors. Its log: $log"
    }
    Write-Note "started from an empty folder, used its own data files, closed cleanly"
}

# ---------------------------------------------------------------- publish --

function Publish-Package {
    Write-Step "Publishing to the local '$Branch' branch"
    $worktree = Join-Path $DistRoot "worktree"
    $temporary = "gitgud-dist-staging"

    if (Test-Path $worktree) {
        Invoke-Git $Root @("worktree", "remove", "--force", $worktree) | Out-Null
    }
    Invoke-Git $Root @("worktree", "prune") | Out-Null

    Invoke-Git $Root @("worktree", "add", "--detach", $worktree, "HEAD") | Out-Null
    try {
        # A branch with no history, emptied, then filled with the package.
        Invoke-Git $worktree @("checkout", "--orphan", $temporary) | Out-Null
        Invoke-Git $worktree @("rm", "-r", "-f", "-q", "--cached", ".") | Out-Null
        Get-ChildItem -Force $worktree | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
        Copy-Item -Recurse -Force (Join-Path $Package "*") $worktree

        $version = Get-Version
        $source = ((Invoke-Git $Root @("rev-parse", "--short", "HEAD")) | Select-Object -First 1)
        $readme = @(
            "# GitGud Desktop $version (Windows build)",
            "",
            "This branch holds only the latest packaged release build (built from",
            "commit $source). It is replaced, not appended to, on every publish.",
            "",
            "Get just the app:",
            "",
            '```',
            "git clone --branch $Branch --single-branch --depth 1 <repository url> GitGud",
            '```',
            "",
            "Then run ``gitgud.exe``. See ``BUILD-INFO.txt`` and ``docs/USAGE.md``.",
            "To update later: ``git fetch --depth 1 origin $Branch`` and",
            "``git reset --hard origin/$Branch``.",
            "",
            "The source is on the ``main`` branch; build it with ``setup.cmd``."
        )
        Set-Content -Path (Join-Path $worktree "README.md") -Value $readme -Encoding utf8
        # Check out byte-for-byte whatever the reader's core.autocrlf says.
        Set-Content -Path (Join-Path $worktree ".gitattributes") -Value "* -text" -Encoding ascii

        # Byte-for-byte: no line-ending conversion of the packaged files.
        Invoke-Git $worktree @("-c", "core.autocrlf=false", "add", "-A", "--force", ".") | Out-Null
        Invoke-Git $worktree @("commit", "-q", "-m",
            "GitGud Desktop $version build from $source") | Out-Null
        $commit = (Invoke-Git $worktree @("rev-parse", "HEAD")) | Select-Object -First 1
    } finally {
        Invoke-Git $Root @("worktree", "remove", "--force", $worktree) | Out-Null
    }

    # Point `dist` at the new single commit, and drop the staging name.
    Invoke-Git $Root @("branch", "-f", $Branch, $commit) | Out-Null
    Invoke-Git $Root @("branch", "-D", $temporary) | Out-Null
    $files = (Invoke-Git $Root @("ls-tree", "-r", "--name-only", $Branch)).Count
    Write-Note "$Branch -> $($commit.Substring(0, 9)) ($files files, one commit)"

    if ($Push) {
        Write-Step "Pushing '$Branch' to origin"
        Invoke-Git $Root @("push", "--force", "origin", "$($Branch):$($Branch)") | Out-Null
        Write-Note "done"
    } else {
        Write-Note "not pushed; to share it: git push --force origin $Branch"
    }
}

# ------------------------------------------------------------------ main --

try {
    if (-not $SkipBuild) {
        Build-Release
    }
    New-Package
    Test-Package
    if ($Publish) {
        Publish-Package
    }
    Write-Host ""
    Write-Host "Package ready: $Package" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "Packaging failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
