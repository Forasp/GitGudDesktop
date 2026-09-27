# Regenerates the app-icon assets from gitgud-mark.jpg (the user-provided
# Jera-rune mark — real art, never redrawn; see the design kit's brand rules):
#   gitgud.ico                     multi-size (16..256, PNG-compressed
#                                  entries) — embedded into gitgud.exe via
#                                  gitgud.rc for Explorer / taskbar pins
#   gitgud.bmp                     64x64 — SDL_SetWindowIcon at runtime
#                                  (running window, alt-tab)
#   ../imagesets/GitgudLogo.png    64x64 — the title-bar mark (Gitgud-Logo
#                                  imageset, drawn by a Gitgud/Icon widget)
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::FromFile((Join-Path $PSScriptRoot "gitgud-mark.jpg"))

function Resize([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.DrawImage($src, 0, 0, $size, $size)
  $g.Dispose()
  return $bmp
}

# ---- title-bar PNG + window-icon BMP (24bpp so SDL_LoadBMP is happy) ----
$logo = Resize 64
$logo.Save((Join-Path $PSScriptRoot "..\imagesets\GitgudLogo.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$opaque = New-Object System.Drawing.Bitmap(64, 64, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($opaque)
$g.DrawImage($logo, 0, 0, 64, 64)
$g.Dispose()
$opaque.Save((Join-Path $PSScriptRoot "gitgud.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
$opaque.Dispose()
$logo.Dispose()

# ---- .ico container with PNG-compressed entries (Vista+) ----
$sizes = 16, 24, 32, 48, 64, 256
$blobs = foreach ($s in $sizes) {
  $bmp = Resize $s
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  , $ms.ToArray()
}

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                  # ICONDIRENTRYs
  $s = $sizes[$i]
  $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))  # width (0 = 256)
  $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))  # height
  $w.Write([byte]0); $w.Write([byte]0)                    # palette, reserved
  $w.Write([uint16]1); $w.Write([uint16]32)               # planes, bpp
  $w.Write([uint32]$blobs[$i].Length)
  $w.Write([uint32]$offset)
  $offset += $blobs[$i].Length
}
foreach ($b in $blobs) { $w.Write($b) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot "gitgud.ico"), $out.ToArray())
$w.Dispose(); $out.Dispose()
$src.Dispose()
Write-Host "wrote gitgud.ico, gitgud.bmp, ../imagesets/GitgudLogo.png"
