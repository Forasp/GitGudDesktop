# Generates resources/imagesets/Gitgud.png — the Gitgud-Images atlas.
# Most art is drawn WHITE on transparent so CEGUI can tint it per widget
# state; the Hunk* toggles are baked in palette colours because they render
# inline in list text ([image=...] tags) where no state tinting exists.
# Layout (128x160):
#   (0,0)-(32,32)    glow tile: 8px quadratic alpha falloff around a 16x16 core
#   (32,0) 24x24     checkmark
#   (56,0) 24x24     radial blob (icon drop-shadow glow)
#   (80,0) 24x24     repo icon (house)
#   (104,0) 24x24    branch icon (git fork)
#   (0,32) 24x24     sync icon (circular arrow)
#   (32,32) 26x26    HunkOn — checked stage toggle (cyan box+glow, dark check)
#   (64,32) 26x26    HunkOff — unchecked stage toggle (hairline square)
#   (96,32) 26x26    HunkPart — partially staged toggle (cyan outline, cyan minus)
#   (126,62) 1x1     Spacer — transparent, pads diff hunk-header rows to 26px
#   (0,64) 24x24     search icon (magnifier; filter boxes)
#   (24,64) 24x24    push icon (arrow up to a bar)
#   (48,64) 24x24    pull icon (arrow down to a bar)
#   (72,64) 24x24    plus icon (new branch / add)
#   (96,64) 12x8     chevron (dropdown indicator, inline in button text)
#   (0,96) 24x24     undo icon (arrow curling back)
#   (24,96) 24x24    redo icon (arrow curling forward)
#   (48,96) 24x24    graph icon (three commits, a fork)
#   (72,96) 24x24    terminal icon (window with a prompt)
#   (96,96) 24x24    command icon (2x2 tiles: the command palette)
#   (0,128)..        16x16 inline sprites for the branch tree, colours baked:
#                    NavBranch cyan, NavRemote purple, NavTag yellow,
#                    NavStash blue, NavSubmodule pink, NavWorktree green,
#                    NavOpen (chevron down) / NavClosed (chevron right) dim
#   (0,144)..        16x16 BlockOn / BlockOff / BlockPart: compact per-block
#                    stage toggles for the diff gutter (colours baked)
Add-Type -AssemblyName System.Drawing

$bmp = New-Object System.Drawing.Bitmap(128, 160, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

# ---- glow tile: per-pixel falloff outside core rect [8,24) ----
for ($y = 0; $y -lt 32; $y++) {
  for ($x = 0; $x -lt 32; $x++) {
    $cx = $x + 0.5; $cy = $y + 0.5
    $dx = [Math]::Max([Math]::Max(8.0 - $cx, $cx - 24.0), 0.0)
    $dy = [Math]::Max([Math]::Max(8.0 - $cy, $cy - 24.0), 0.0)
    $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
    $t = [Math]::Max(0.0, 1.0 - $d / 8.0)
    $a = [int][Math]::Round(255.0 * $t * $t)
    if ($a -gt 0) { $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($a, 255, 255, 255)) }
  }
}

# ---- blob: radial falloff, centre (12,12) in the 24x24 cell at (56,0) ----
for ($y = 0; $y -lt 24; $y++) {
  for ($x = 0; $x -lt 24; $x++) {
    $dx = ($x + 0.5) - 12.0; $dy = ($y + 0.5) - 12.0
    $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
    $t = [Math]::Max(0.0, 1.0 - $d / 11.5)
    $a = [int][Math]::Round(255.0 * [Math]::Pow($t, 1.6))
    if ($a -gt 0) { $bmp.SetPixel(56 + $x, $y, [System.Drawing.Color]::FromArgb($a, 255, 255, 255)) }
  }
}

# ---- HunkOn at (32,32): 14px cyan box (core [6,20)) with baked halo ----
# Same falloff math as the glow tile, tinted --neon-cyan at the checkbox
# glow's .6 intensity; the core is the solid checked fill.
for ($y = 0; $y -lt 26; $y++) {
  for ($x = 0; $x -lt 26; $x++) {
    $cx = $x + 0.5; $cy = $y + 0.5
    if ($cx -gt 6 -and $cx -lt 20 -and $cy -gt 6 -and $cy -lt 20) {
      $bmp.SetPixel(32 + $x, 32 + $y, [System.Drawing.Color]::FromArgb(255, 126, 242, 214))
    } else {
      $dx = [Math]::Max([Math]::Max(6.0 - $cx, $cx - 20.0), 0.0)
      $dy = [Math]::Max([Math]::Max(6.0 - $cy, $cy - 20.0), 0.0)
      $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
      $t = [Math]::Max(0.0, 1.0 - $d / 6.0)
      $a = [int][Math]::Round(153.0 * $t * $t)   # 153 = .6 intensity
      if ($a -gt 0) { $bmp.SetPixel(32 + $x, 32 + $y, [System.Drawing.Color]::FromArgb($a, 126, 242, 214)) }
    }
  }
}

$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$white = [System.Drawing.Color]::White
$brush = New-Object System.Drawing.SolidBrush($white)

function New-Pen([float]$w) {
  $p = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $w)
  $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  return $p
}

# ---- checkmark at (32,0) ----
$pen = New-Pen 2.6
$pts = @(
  (New-Object System.Drawing.PointF(37.0, 12.5)),
  (New-Object System.Drawing.PointF(41.8, 17.5)),
  (New-Object System.Drawing.PointF(51.0, 6.5)))
$g.DrawLines($pen, $pts)
$pen.Dispose()

# ---- repo (house) at (80,0) ----
$pen = New-Pen 1.8
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(84.5, 11.5)),
  (New-Object System.Drawing.PointF(92.0, 4.5)),
  (New-Object System.Drawing.PointF(99.5, 11.5))))
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(86.5, 10.5)),
  (New-Object System.Drawing.PointF(86.5, 19.0)),
  (New-Object System.Drawing.PointF(97.5, 19.0)),
  (New-Object System.Drawing.PointF(97.5, 10.5))))
$pen.Dispose()

# ---- branch (git fork) at (104,0) ----
$pen = New-Pen 1.8
$g.DrawEllipse($pen, 108.6, 3.1, 4.8, 4.8)     # top node on the main line
$g.DrawEllipse($pen, 108.6, 16.1, 4.8, 4.8)    # bottom node
$g.DrawEllipse($pen, 118.6, 5.1, 4.8, 4.8)     # branch node
$g.DrawLine($pen, 111.0, 8.2, 111.0, 15.8)     # main line
$g.DrawBezier($pen, 121.0, 10.2, 121.0, 14.0, 116.0, 15.6, 113.2, 16.4)
$pen.Dispose()

# ---- sync (circular arrow) at (0,32) ----
$pen = New-Pen 2.0
$g.DrawArc($pen, 5.0, 37.0, 14.0, 14.0, -50.0, 285.0)
$g.FillPolygon($brush, @(
  (New-Object System.Drawing.PointF(10.9, 36.2)),
  (New-Object System.Drawing.PointF(9.3, 40.2)),
  (New-Object System.Drawing.PointF(6.7, 36.4))))
$pen.Dispose()

# ---- HunkOn checkmark: dark (--bg-0) over the cyan fill ----
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 14, 10, 26), 1.8)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(41.2, 45.0)),
  (New-Object System.Drawing.PointF(44.2, 48.0)),
  (New-Object System.Drawing.PointF(49.8, 41.5))))
$pen.Dispose()

# ---- HunkOff at (64,32): crisp 1px hairline square (--border-strong-ish) ----
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(102, 196, 181, 253), 1)
$g.DrawRectangle($pen, 70, 38, 13, 13)
$pen.Dispose()

# ---- HunkPart at (96,32): cyan hairline box + cyan minus (partially staged) ----
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 126, 242, 214), 1)
$g.DrawRectangle($pen, 102, 38, 13, 13)
$pen.Dispose()
$g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 126, 242, 214))), 105, 44, 8, 2)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

# ---- search (magnifier) at (0,64) ----
$pen = New-Pen 1.8
$g.DrawEllipse($pen, 4.5, 68.5, 11.0, 11.0)
$g.DrawLine($pen, 14.0, 78.0, 19.5, 83.5)
$pen.Dispose()

# ---- push (arrow up to a bar) at (24,64) ----
$pen = New-Pen 1.8
$g.DrawLine($pen, 29.0, 68.0, 43.0, 68.0)
$g.DrawLine($pen, 36.0, 72.0, 36.0, 84.0)
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(31.5, 76.5)),
  (New-Object System.Drawing.PointF(36.0, 72.0)),
  (New-Object System.Drawing.PointF(40.5, 76.5))))
$pen.Dispose()

# ---- pull (arrow down to a bar) at (48,64) ----
$pen = New-Pen 1.8
$g.DrawLine($pen, 53.0, 84.0, 67.0, 84.0)
$g.DrawLine($pen, 60.0, 68.0, 60.0, 80.0)
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(55.5, 75.5)),
  (New-Object System.Drawing.PointF(60.0, 80.0)),
  (New-Object System.Drawing.PointF(64.5, 75.5))))
$pen.Dispose()

# ---- plus at (72,64) ----
$pen = New-Pen 2.0
$g.DrawLine($pen, 84.0, 69.0, 84.0, 83.0)
$g.DrawLine($pen, 77.0, 76.0, 91.0, 76.0)
$pen.Dispose()

# ---- chevron at (96,64): small downward "v" ----
$pen = New-Pen 1.6
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(98.0, 66.0)),
  (New-Object System.Drawing.PointF(102.0, 70.0)),
  (New-Object System.Drawing.PointF(106.0, 66.0))))
$pen.Dispose()

# ---- undo at (0,96): arrow curling back to the left ----
$pen = New-Pen 1.8
$g.DrawArc($pen, 6.0, 102.0, 13.0, 12.0, -90.0, 200.0)
$g.DrawLine($pen, 12.5, 102.0, 6.5, 102.0)
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(9.5, 99.0)),
  (New-Object System.Drawing.PointF(6.5, 102.0)),
  (New-Object System.Drawing.PointF(9.5, 105.0))))
$pen.Dispose()

# ---- redo at (24,96): the mirror image ----
$pen = New-Pen 1.8
$g.DrawArc($pen, 29.0, 102.0, 13.0, 12.0, -90.0, -200.0)
$g.DrawLine($pen, 35.5, 102.0, 41.5, 102.0)
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(38.5, 99.0)),
  (New-Object System.Drawing.PointF(41.5, 102.0)),
  (New-Object System.Drawing.PointF(38.5, 105.0))))
$pen.Dispose()

# ---- graph at (48,96): a lane with a branch curving off ----
$pen = New-Pen 1.8
$g.DrawLine($pen, 55.0, 100.0, 55.0, 116.0)
$g.DrawBezier($pen, 55.0, 113.0, 55.0, 108.0, 65.0, 109.0, 65.0, 103.0)
$g.FillEllipse($brush, 52.0, 97.5, 6.0, 6.0)
$g.FillEllipse($brush, 52.0, 113.5, 6.0, 6.0)
$g.FillEllipse($brush, 62.0, 99.5, 6.0, 6.0)
$pen.Dispose()

# ---- terminal at (72,96): a window with ">_" ----
$pen = New-Pen 1.6
$g.DrawRectangle($pen, 75.5, 100.5, 17.0, 15.0)
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(79.0, 105.0)),
  (New-Object System.Drawing.PointF(82.0, 108.0)),
  (New-Object System.Drawing.PointF(79.0, 111.0))))
$g.DrawLine($pen, 84.0, 111.5, 89.0, 111.5)
$pen.Dispose()

# ---- command palette at (96,96): four rounded tiles ----
foreach ($t in @(@(100.0, 100.0), @(109.0, 100.0), @(100.0, 109.0), @(109.0, 109.0))) {
  $g.FillRectangle($brush, $t[0], $t[1], 7.0, 7.0)
}

# ---- inline branch-tree sprites (colours baked: list text can't tint) ----
function New-ColourPen($r, $gr, $b, [float]$w) {
  $p = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, $r, $gr, $b), $w)
  $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  return $p
}
function New-ColourBrush($r, $gr, $b) {
  return New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $r, $gr, $b))
}

# NavBranch (0,128): a small fork, cyan
$pen = New-ColourPen 126 242 214 1.5
$g.DrawLine($pen, 5.0, 131.0, 5.0, 141.0)
$g.DrawBezier($pen, 5.0, 139.0, 5.0, 135.0, 11.0, 136.0, 11.0, 132.0)
$g.DrawEllipse($pen, 3.0, 139.5, 4.0, 4.0)
$g.DrawEllipse($pen, 9.0, 130.0, 4.0, 4.0)
$pen.Dispose()

# NavRemote (16,128): a cloud, purple
$b = New-ColourBrush 176 107 255
$g.FillEllipse($b, 18.0, 135.0, 7.0, 6.0)
$g.FillEllipse($b, 21.0, 132.0, 8.0, 8.0)
$g.FillEllipse($b, 25.0, 135.0, 7.0, 6.0)
$g.FillRectangle($b, 21.5, 137.0, 7.0, 4.0)
$b.Dispose()

# NavTag (32,128): a tag, yellow
$b = New-ColourBrush 255 207 110
$g.FillPolygon($b, @(
  (New-Object System.Drawing.PointF(34.0, 131.0)),
  (New-Object System.Drawing.PointF(41.0, 131.0)),
  (New-Object System.Drawing.PointF(46.0, 136.0)),
  (New-Object System.Drawing.PointF(41.0, 141.0)),
  (New-Object System.Drawing.PointF(34.0, 141.0))))
$b.Dispose()
$g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 31, 23, 56))), 36.0, 134.5, 3.0, 3.0)

# NavStash (48,128): a box, blue
$pen = New-ColourPen 124 147 255 1.5
$g.DrawRectangle($pen, 50.5, 134.5, 11.0, 7.0)
$g.DrawLine($pen, 50.5, 131.5, 61.5, 131.5)
$g.DrawLine($pen, 54.0, 137.5, 58.0, 137.5)
$pen.Dispose()

# NavSubmodule (64,128): a folder, pink
$b = New-ColourBrush 255 126 219
$g.FillRectangle($b, 66.0, 133.0, 12.0, 8.0)
$g.FillRectangle($b, 66.0, 131.0, 5.0, 3.0)
$b.Dispose()

# NavWorktree (80,128): two stacked sheets, green
$pen = New-ColourPen 94 242 166 1.4
$g.DrawRectangle($pen, 84.5, 130.5, 8.0, 9.0)
$g.DrawRectangle($pen, 82.0, 133.0, 8.0, 9.0)
$pen.Dispose()

# NavOpen (96,128) / NavClosed (112,128): dim chevrons
$pen = New-ColourPen 118 106 156 1.6
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(100.0, 134.0)),
  (New-Object System.Drawing.PointF(104.0, 138.0)),
  (New-Object System.Drawing.PointF(108.0, 134.0))))
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(118.0, 132.0)),
  (New-Object System.Drawing.PointF(122.0, 136.0)),
  (New-Object System.Drawing.PointF(118.0, 140.0))))
$pen.Dispose()

# ---- compact change-block boxes at (0,144) (16,144) (32,144) ----
# Line-height versions of HunkOn / HunkOff / HunkPart for the diff gutter's
# per-block toggles (a 12px box, no halo, so they fit a 16px text row).
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$cyan = [System.Drawing.Color]::FromArgb(255, 126, 242, 214)
$g.FillRectangle((New-Object System.Drawing.SolidBrush($cyan)), 2, 146, 12, 12)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(102, 196, 181, 253), 1)
$g.DrawRectangle($pen, 18, 146, 11, 11)
$pen.Dispose()
$pen = New-Object System.Drawing.Pen($cyan, 1)
$g.DrawRectangle($pen, 34, 146, 11, 11)
$pen.Dispose()
$g.FillRectangle((New-Object System.Drawing.SolidBrush($cyan)), 37, 151, 6, 2)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 14, 10, 26), 1.6)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawLines($pen, @(
  (New-Object System.Drawing.PointF(4.8, 152.0)),
  (New-Object System.Drawing.PointF(7.2, 154.4)),
  (New-Object System.Drawing.PointF(11.4, 149.4))))
$pen.Dispose()

$g.Dispose()
$brush.Dispose()

$out = Join-Path $PSScriptRoot "Gitgud.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "wrote $out"
