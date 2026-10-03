<#
.SYNOPSIS
    Make a throwaway Perforce server and workspace for UI tests.

.DESCRIPTION
    Creates <Dir>\server (a p4d root, run in rsh mode: no port, nothing
    left running), a stream depot //proj with streams //proj/main and
    //proj/dev, a few submitted changes, and the workspace <Dir>\ws with a
    .p4config GitGud opens (gitgud.exe <Dir>\ws).

    The test user "tim" gets a password and a ticket in <Dir>\p4tickets.txt.
    Launch GitGud with P4TICKETS (and P4TRUST, P4ENVIRO) pointing into <Dir>,
    as the script prints, so the app never needs Windows Credential Manager.

.EXAMPLE
    .\tests\ui\make-p4workspace.ps1 -Dir $env:TEMP\gg-p4 -P4 C:\tools\p4.exe -P4D C:\tools\p4d.exe
#>
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [string]$P4 = $env:GITGUD_P4,
    [string]$P4D = $env:GITGUD_TEST_P4D
)

$ErrorActionPreference = "Continue"
if (-not $P4 -or -not (Test-Path $P4)) { throw "Pass -P4 (or set GITGUD_P4) to p4.exe" }
if (-not $P4D -or -not (Test-Path $P4D)) { throw "Pass -P4D (or set GITGUD_TEST_P4D) to p4d.exe" }

if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
New-Item -ItemType Directory -Force "$Dir\server", "$Dir\ws", "$Dir\tmp" | Out-Null
$Dir = (Resolve-Path $Dir).Path

foreach ($var in "P4PORT", "P4USER", "P4CLIENT", "P4CONFIG", "P4PASSWD", "P4CHARSET") {
    Remove-Item "env:$var" -ErrorAction SilentlyContinue
}
$env:P4TICKETS = "$Dir\p4tickets.txt"
$env:P4TRUST = "$Dir\p4trust.txt"
$env:P4ENVIRO = "$Dir\p4enviro.txt"

$port = "rsh:$P4D -r $Dir\server -L log -i"
$password = "Secret-123"

function Invoke-P4 {
    param([string]$Client, [string]$Cwd, [string]$Stdin, [string[]]$Arguments)
    # A Process of our own: PowerShell's pipe would send CRLF line ends,
    # which p4 passwd rejects.
    $all = @("-p", $port, "-u", "tim", "-c", $Client, "-d", $Cwd) + $Arguments
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $P4
    $psi.Arguments = ($all | ForEach-Object { '"' + $_ + '"' }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Process gives stdin Console.InputEncoding; a UTF-8 one writes a BOM.
    try { [Console]::InputEncoding = New-Object System.Text.ASCIIEncoding } catch {}
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Stdin) {
        # Raw bytes: the stream writer would start with a UTF-8 BOM.
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Stdin)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "p4 $($Arguments -join ' ') failed: $out" }
    $out
}

Invoke-P4 -Client none -Cwd "$Dir\tmp" -Stdin "$password`n$password`n" -Arguments @("passwd") | Out-Null
Invoke-P4 -Client none -Cwd "$Dir\tmp" -Stdin "$password`n" -Arguments @("login") | Out-Null

Invoke-P4 -Client none -Cwd "$Dir\tmp" -Arguments @("depot", "-i") `
    -Stdin "Depot: proj`nType: stream`nMap: proj/...`nStreamDepth: //proj/1`n" | Out-Null
Invoke-P4 -Client none -Cwd "$Dir\tmp" -Arguments @("stream", "-i") `
    -Stdin "Stream: //proj/main`nOwner: tim`nName: main`nParent: none`nType: mainline`nParentView: inherit`nPaths:`n`tshare ...`n" | Out-Null

$ws = "$Dir\ws"
Invoke-P4 -Client ws -Cwd $ws -Arguments @("client", "-i") `
    -Stdin "Client: ws`nOwner: tim`nRoot: $ws`nOptions: allwrite noclobber nocompress unlocked nomodtime rmdir`nStream: //proj/main`nLineEnd: local`n" | Out-Null

[System.IO.File]::WriteAllText("$ws\README.md", "# Test project`n")
New-Item -ItemType Directory -Force "$ws\src" | Out-Null
[System.IO.File]::WriteAllText("$ws\src\main.cpp", "int main()`n{`n    return 0;`n}`n")
Invoke-P4 -Client ws -Cwd $ws -Arguments @("reconcile", "$ws\...") | Out-Null
Invoke-P4 -Client ws -Cwd $ws -Arguments @("submit", "-d", "Initial files") | Out-Null

[System.IO.File]::WriteAllText("$ws\src\main.cpp", "#include <cstdio>`n`nint main()`n{`n    std::puts(`"hi`");`n    return 0;`n}`n")
Invoke-P4 -Client ws -Cwd $ws -Arguments @("reconcile", "$ws\...") | Out-Null
Invoke-P4 -Client ws -Cwd $ws -Arguments @("submit", "-d", "Say hi") | Out-Null

Invoke-P4 -Client ws -Cwd $ws -Arguments @("stream", "-i") `
    -Stdin "Stream: //proj/dev`nOwner: tim`nName: dev`nParent: //proj/main`nType: development`nParentView: inherit`nPaths:`n`tshare ...`n" | Out-Null
Invoke-P4 -Client ws -Cwd $ws -Arguments @("populate", "-d", "Branch dev", "-S", "//proj/dev", "-r") | Out-Null
Invoke-P4 -Client ws -Cwd $ws -Arguments @("label", "-i") `
    -Stdin "Label: v1`nOwner: tim`nDescription:`n`tFirst release`nOptions: unlocked noautoreload`nRevision: @2`nView:`n`t//proj/main/...`n" | Out-Null

# Local edits for the Changes view: one modified, one new.
[System.IO.File]::AppendAllText("$ws\README.md", "More text.`n")
[System.IO.File]::WriteAllText("$ws\notes.txt", "a new file`n")

[System.IO.File]::WriteAllText("$ws\.p4config", "P4PORT=$port`nP4USER=tim`nP4CLIENT=ws`n")

Write-Output "Workspace: $ws"
Write-Output "Launch with:"
Write-Output "  `$env:P4TICKETS='$Dir\p4tickets.txt'; `$env:P4TRUST='$Dir\p4trust.txt'; `$env:P4ENVIRO='$Dir\p4enviro.txt'; `$env:GITGUD_P4='$P4'"
