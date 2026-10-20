<#
.SYNOPSIS
    Updates an installed GitGud Desktop from a packaged build without closing it,
    when only its resources changed.

.DESCRIPTION
    Compares a packaged build (package.ps1 -SkipBuild makes build\dist\GitGud)
    with an installed copy. When everything outside resources\ is the same
    (the exe, its libraries, docs), it mirrors resources\ into the copy; a
    running GitGud hot-reloads it once the files settle, and its Claude Code
    sessions, voice, and open conversations carry on. When the program
    itself changed, it copies nothing and says a restart is needed: close
    GitGud and update the whole folder.

    Exit codes: 0 updated (or nothing to update), 2 the program changed (a
    restart is needed), 1 failed.

.PARAMETER To
    The installed copy (the folder with gitgud.exe).

.PARAMETER From
    The packaged build. Default: build\dist\GitGud beside this script's repo.

.PARAMETER DryRun
    Say what would happen, copy nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\update-running.ps1 -To C:\Apps\GitGud
#>
param(
    [Parameter(Mandatory = $true)][string]$To,
    [string]$From = (Join-Path (Split-Path $PSScriptRoot -Parent) "build\dist\GitGud"),
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"

try {
    $From = (Resolve-Path $From).Path.TrimEnd('\')
    $To = (Resolve-Path $To).Path.TrimEnd('\')
    if (-not (Test-Path (Join-Path $From "gitgud.exe"))) { throw "$From has no gitgud.exe: run package.ps1 -SkipBuild first." }
    if (-not (Test-Path (Join-Path $To "gitgud.exe"))) { throw "$To has no gitgud.exe: it isn't a GitGud folder." }

    # Every file outside resources\ the build has must be in the copy, the same.
    $changed = @()
    foreach ($file in Get-ChildItem $From -Recurse -File) {
        $rel = $file.FullName.Substring($From.Length + 1)
        if ($rel -like "resources\*") { continue }
        $there = Join-Path $To $rel
        if (-not (Test-Path $there)) { $changed += "$rel (new)"; continue }
        $other = Get-Item $there
        if ($other.Length -ne $file.Length -or
            (Get-FileHash $there).Hash -ne (Get-FileHash $file.FullName).Hash) {
            $changed += $rel
        }
    }

    $running = @(Get-Process gitgud -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$To\*" })
    if ($changed.Count -gt 0) {
        Write-Host "The program changed, not only its resources:"
        $changed | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if ($changed.Count -gt 20) { Write-Host "  ... and $($changed.Count - 20) more" }
        if ($running.Count -gt 0) {
            Write-Host "Restart needed: close GitGud, then update the whole folder."
        } else {
            Write-Host "Restart needed: GitGud isn't running, so update the whole folder now."
        }
        exit 2
    }

    $what = if ($running.Count -gt 0) { "running copy (it reloads its UI by itself)" } else { "copy" }
    if ($DryRun) {
        Write-Host "Only resources differ: would mirror $From\resources into the $what at $To."
        exit 0
    }
    robocopy "$From\resources" "$To\resources" /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy $LASTEXITCODE)." }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Nothing to update: the resources are the same."
    } else {
        Write-Host "Updated the resources of the $what at $To."
    }
    exit 0
} catch {
    Write-Host "Update failed: $($_.Exception.Message)"
    exit 1
}
