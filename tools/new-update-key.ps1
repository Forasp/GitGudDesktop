<#
.SYNOPSIS
    Makes the key pair that signs release update manifests.

.DESCRIPTION
    Run once (or to replace a leaked key). It:
      - writes the PUBLIC key into src\update\UpdateKey.h, which is compiled
        into GitGud so installed copies can verify updates (commit this);
      - writes the PRIVATE key to -PrivateKeyFile. Store it as the GitHub
        Actions secret GITGUD_UPDATE_SIGNING_KEY (repository Settings >
        Secrets and variables > Actions), then keep the file somewhere safe
        or delete it. Never commit it.

    Copies built with an older public key reject manifests signed with a new
    one, so replacing the key means those copies must update once with the
    installer or zip.

.PARAMETER PrivateKeyFile
    Where to write the private key. Must not already exist; keep it outside
    the repository.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\new-update-key.ps1 -PrivateKeyFile $HOME\gitgud-update-key.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PrivateKeyFile
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Header = Join-Path $Root "src\update\UpdateKey.h"

if (Test-Path $PrivateKeyFile) {
    throw "$PrivateKeyFile already exists; pick a new file name."
}
$fullKeyPath = [IO.Path]::GetFullPath($PrivateKeyFile)
if ($fullKeyPath.StartsWith([IO.Path]::GetFullPath($Root), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Keep the private key outside the repository."
}

$ecdsa = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
try {
    $parameters = $ecdsa.ExportParameters($true)
    $public = [Convert]::ToBase64String([byte[]]($parameters.Q.X + $parameters.Q.Y))
    $private = [Convert]::ToBase64String([byte[]]($parameters.D + $parameters.Q.X + $parameters.Q.Y))
} finally {
    $ecdsa.Dispose()
}

[IO.File]::WriteAllText($fullKeyPath, $private + "`n")

$text = [IO.File]::ReadAllText($Header)
$updated = [Text.RegularExpressions.Regex]::Replace($text,
    'constexpr const char\* kUpdatePublicKey = "[^"]*";',
    "constexpr const char* kUpdatePublicKey = `"$public`";")
if ($updated -eq $text -and $text -notmatch [Text.RegularExpressions.Regex]::Escape($public)) {
    throw "Couldn't find kUpdatePublicKey in $Header."
}
[IO.File]::WriteAllText($Header, $updated)

Write-Host "Public key written to src\update\UpdateKey.h (commit it)."
Write-Host "Private key written to $fullKeyPath."
Write-Host "Add its contents as the GitHub Actions secret GITGUD_UPDATE_SIGNING_KEY,"
Write-Host "then keep the file somewhere safe or delete it. Never commit it."
