<#
.SYNOPSIS
    Publishes docs\ to the GitHub wiki.

.DESCRIPTION
    docs\ stays the source of truth (the app ships it for its Help menu); the
    wiki is generated from it, so edit docs\ and run this afterwards.

    1. Clones the wiki repository (origin's URL with ".wiki.git") into a
       temporary folder.
    2. Replaces its pages with one page per file in docs\ (first heading
       dropped, since the wiki titles pages itself; mentions of other docs
       become wiki links) plus the Home, sidebar, and footer pages in
       tools\wiki\. Pages no longer generated are deleted.
    3. Commits with this repository's user.name / user.email and pushes,
       unless nothing changed.

.PARAMETER WikiUrl
    Wiki repository to publish to. Default: origin's URL with ".wiki.git".

.PARAMETER DryRun
    Generate and commit in the temporary clone, show what changed, but don't
    push.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\publish-wiki.ps1
#>
[CmdletBinding()]
param(
    [string]$WikiUrl,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Docs = Join-Path $Root "docs"
$Templates = Join-Path $PSScriptRoot "wiki"

# docs\ file -> wiki page (file name without .md) and its title.
$Pages = [ordered]@{
    "MODDING.md"    = @{ Page = "Modding"; Title = "Modding" }
    "LUA_API.md"    = @{ Page = "Lua-API"; Title = "Lua API" }
    "BUILDING.md"   = @{ Page = "Building"; Title = "Building" }
    "USAGE.md"      = @{ Page = "Using-the-Default-UI"; Title = "Using the Default UI" }
    "P4V.md"        = @{ Page = "Using-the-P4V-UI"; Title = "Using the P4V UI" }
    "PRINCIPLES.md" = @{ Page = "Principles"; Title = "Principles" }
}

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

# Read a text file as UTF-8 with LF line endings.
function Read-Text($Path) {
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) -replace "`r`n", "`n"
}

# Write UTF-8 without a BOM.
function Write-Text($Path, $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# One docs\ file as a wiki page.
function Convert-Doc($Text) {
    # The wiki shows the page name as the title; drop the doc's own heading.
    $Text = $Text -replace "^# [^\n]*\n+", ""

    # `docs/LUA_API.md` / `LUA_API.md` -> [Lua API](Lua-API)
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $target = $Pages[$m.Groups[1].Value + ".md"]
        return "[$($target.Title)]($($target.Page))"
    }
    $names = ($Pages.Keys | ForEach-Object { [regex]::Escape(($_ -replace "\.md$", "")) }) -join "|"
    return [regex]::Replace($Text, "``(?:docs/)?($names)\.md``", $evaluator)
}

if (-not $WikiUrl) {
    $origin = (Invoke-Git $Root @("config", "--get", "remote.origin.url")) | Select-Object -First 1
    $WikiUrl = ($origin -replace "\.git$", "") + ".wiki.git"
}
$name = (Invoke-Git $Root @("config", "user.name")) | Select-Object -First 1
$email = (Invoke-Git $Root @("config", "user.email")) | Select-Object -First 1

$work = Join-Path ([IO.Path]::GetTempPath()) ("gitgud-wiki-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
try {
    Write-Step "Cloning $WikiUrl"
    Invoke-Git $Root @("clone", "--quiet", $WikiUrl, $work) | Out-Null

    Write-Step "Generating pages"
    Get-ChildItem $work -File -Filter *.md | Remove-Item -Force
    foreach ($file in $Pages.Keys) {
        $source = Join-Path $Docs $file
        if (-not (Test-Path $source)) {
            throw "docs\$file is missing."
        }
        $page = $Pages[$file].Page
        Write-Text (Join-Path $work "$page.md") (Convert-Doc (Read-Text $source))
        Write-Note "docs\$file -> $page"
    }
    foreach ($template in Get-ChildItem $Templates -File -Filter *.md) {
        Write-Text (Join-Path $work $template.Name) (Read-Text $template.FullName)
        Write-Note "tools\wiki\$($template.Name)"
    }

    Invoke-Git $work @("add", "--all") | Out-Null
    $changes = Invoke-Git $work @("status", "--porcelain")
    if (-not $changes) {
        Write-Step "The wiki is already up to date"
        return
    }
    $changes | ForEach-Object { Write-Note $_ }

    Write-Step "Committing as $name <$email>"
    Invoke-Git $work @("-c", "user.name=$name", "-c", "user.email=$email", "commit", "--quiet", "-m", "Update documentation") | Out-Null

    if ($DryRun) {
        Write-Step "Dry run: not pushed"
        return
    }
    Write-Step "Pushing"
    Invoke-Git $work @("push", "--quiet", "origin", "HEAD") | Out-Null
    Write-Note "Done: $($WikiUrl -replace '\.wiki\.git$', '/wiki')"
}
finally {
    if (Test-Path $work) {
        Remove-Item -Recurse -Force $work
    }
}
