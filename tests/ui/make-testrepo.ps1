# Builds a throwaway repository for tests/ui/walkthrough.lua (and for poking
# at the UI by hand): history, two branches, a tag, a bare "remote", an image,
# and a mix of working-tree changes.
#
#   powershell -File tests\ui\make-testrepo.ps1 -Dir C:\temp\gg-test
#
# The folder (and <Dir>-remote.git) are deleted and recreated.
param([Parameter(Mandatory = $true)][string]$Dir)

$ErrorActionPreference = "Stop"
$remote = "$Dir-remote.git"
foreach ($d in @($Dir, $remote)) {
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
}
New-Item -ItemType Directory $Dir | Out-Null
Push-Location $Dir

# git prints progress on stderr; don't let PowerShell treat that as an error.
function Invoke-Git {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git.exe @args *> $null
    $ErrorActionPreference = $previous
    if ($LASTEXITCODE -ne 0) { throw "git $args failed" }
}
function Write-Lf($path, $text) { [IO.File]::WriteAllText((Join-Path $Dir $path), $text) }

Add-Type -AssemblyName System.Drawing
function New-Png($path, $r, $g, $b, $dot) {
    $bmp = New-Object System.Drawing.Bitmap(96, 64)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.Clear([System.Drawing.Color]::FromArgb(255, 30, 20, 60))
    $gfx.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $r, $g, $b))), 16, 8, 48, 48)
    if ($dot) { $gfx.FillRectangle([System.Drawing.Brushes]::Yellow, 70, 20, 14, 14) }
    $gfx.Dispose()
    $bmp.Save((Join-Path $Dir $path), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

Invoke-Git init -b main
Invoke-Git config user.name "Test User"
Invoke-Git config user.email "test@example.com"
Invoke-Git config core.autocrlf false

New-Item -ItemType Directory src, assets | Out-Null
Write-Lf "README.md" "# Test project`n`nA scratch repository for GitGud testing.`n"
$lines = 1..40 | ForEach-Object { "int line$_ = $_;" }
Write-Lf "src/main.cpp" (($lines -join "`n") + "`n")
Write-Lf "obsolete.txt" "old file`n"
New-Png "assets/logo.png" 126 242 214 $false
Invoke-Git add -A
Invoke-Git commit -m "Initial commit"

foreach ($i in 1..6) {
    Add-Content -NoNewline -Path (Join-Path $Dir "README.md") -Value "change $i`n"
    Invoke-Git commit -am "Update README ($i)" -m "Some body text for commit $i."
}
Invoke-Git tag v1.0

Invoke-Git checkout -b feature/login
Write-Lf "src/login.cpp" "login code`n"
Invoke-Git add -A
Invoke-Git commit -m "Add login module"
Invoke-Git checkout main
Invoke-Git checkout -b feature/theme
Write-Lf "src/theme.cpp" "theme`n"
Invoke-Git add -A
Invoke-Git commit -m "Add theme support"
Invoke-Git checkout main

Invoke-Git init --bare $remote
Invoke-Git remote add origin $remote
Invoke-Git push -u origin main
Invoke-Git push origin feature/login

# Working-tree changes: two hunks in main.cpp, a new file, an image edit, a deletion.
$lines[1] = "int line2 = 200;  // changed"
$lines[34] = "int line35 = 3500;  // changed"
Write-Lf "src/main.cpp" (($lines -join "`n") + "`n")
Write-Lf "notes.txt" "brand new notes`nsecond line`n"
New-Png "assets/logo.png" 255 94 196 $true
Remove-Item (Join-Path $Dir "obsolete.txt")

Pop-Location
Write-Host "test repository ready: $Dir"
