# Generates BragiIcons.png + BragiIcons.xml, the Bragi UI's images (imageset
# "Bragi-Icons").
#
#   Icons, 24x24, white so a Gitgud/Icon tints them (IconColour):
#     Gear Mic Send Stop Plus Chat Folder Agent Close Sidebar
#     Spark Repo Boards Wiki Search Sun Moon Read Pencil Terminal Rewind Fork
#     Speaker SpeakerOff (the mute button beside the mic) Copy
#   Row sprites, white, tinted inline by scripts/core/sprites.lua:
#     CheckRing CheckMark (14) GraphRing GraphDot (10) PillLeft PillMiddle
#     PillRight (a label's outline, 18 high) and the branch tree's
#     NavBranch NavRemote NavTag NavStash NavSubmodule NavWorktree NavOpen
#     NavClosed (16)
#   Plan sprites, 16x16, white (bragi/plan.lua): PlanDone (a filled circle
#     with the tick cut out), PlanPending (a dashed circle), PlanSpin0-7 (a
#     ring with a bright arc, turned 45 degrees a frame)
#   Mark, 32x32 and 64x64, full colour: a sunflower (title bar, empty state)
#   MarkPetals / MarkCentre (30 and 64): the design's logo in two white
#     layers, tinted with the theme's petal and logo-centre colours
#
# Run it after editing: powershell -ExecutionPolicy Bypass -File make-icons.ps1
Add-Type -AssemblyName System.Drawing

$W = 320; $H = 180
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)

$regions = New-Object System.Collections.ArrayList
$white = "FFFFFF"

function C($hex) {
    return [System.Drawing.ColorTranslator]::FromHtml("#" + $hex)
}
function Pen($hex, $w) {
    $p = New-Object System.Drawing.Pen((C $hex), $w)
    $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    return $p
}
function Brush($hex) { return New-Object System.Drawing.SolidBrush((C $hex)) }
function Line($ox, $oy, $x0, $y0, $x1, $y1, $w) {
    $g.DrawLine((Pen $white $w), [single]($ox + $x0), [single]($oy + $y0), [single]($ox + $x1), [single]($oy + $y1))
}
function Ellipse($ox, $oy, $x, $y, $w, $h, $fill, $stroke, $sw) {
    if ($fill) { $g.FillEllipse((Brush $fill), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h) }
    if ($stroke) { $g.DrawEllipse((Pen $stroke $sw), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h) }
}
function RoundRect($ox, $oy, $x, $y, $w, $h, $r, $fill, $stroke, $sw) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = $ox + $x; $y = $oy + $y; $d = 2 * $r
    $path.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $path.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $path.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
    $path.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
    $path.CloseFigure()
    if ($fill) { $g.FillPath((Brush $fill), $path) }
    if ($stroke) { $g.DrawPath((Pen $stroke $sw), $path) }
}
function Add($name, $x, $y, $w, $h) {
    [void]$regions.Add(@{ Name = $name; X = $x; Y = $y; W = $w; H = $h })
}

# ---- 24x24 icons, row 0 ----------------------------------------------------
$names = @("Gear", "Mic", "Send", "Stop", "Plus", "Chat", "Folder", "Agent", "Close", "Sidebar")
for ($i = 0; $i -lt $names.Count; $i++) {
    $ox = ($i % 10) * 24; $oy = 0
    Add $names[$i] $ox $oy 24 24
    switch ($names[$i]) {
        "Gear" {
            for ($k = 0; $k -lt 8; $k++) {
                $a = $k * [Math]::PI / 4
                Line $ox $oy (12 + 6.5 * [Math]::Cos($a)) (12 + 6.5 * [Math]::Sin($a)) (12 + 9.5 * [Math]::Cos($a)) (12 + 9.5 * [Math]::Sin($a)) 3
            }
            Ellipse $ox $oy 5.5 5.5 13 13 $null $white 2
            Ellipse $ox $oy 9.5 9.5 5 5 $null $white 1.6
        }
        "Mic" {
            RoundRect $ox $oy 8.5 2.5 7 12 3.5 $null $white 1.8
            $g.DrawArc((Pen $white 1.8), [single]($ox + 5), [single]($oy + 7), [single]14, [single]11, 0, 180)
            Line $ox $oy 12 18 12 21.5 1.8
            Line $ox $oy 8.5 21.5 15.5 21.5 1.8
        }
        "Send" {
            Line $ox $oy 12 20 12 5 2.2
            Line $ox $oy 6 11 12 4.5 2.2
            Line $ox $oy 18 11 12 4.5 2.2
        }
        "Stop" {
            RoundRect $ox $oy 6 6 12 12 2 $white $null 0
        }
        "Plus" {
            Line $ox $oy 12 5 12 19 2
            Line $ox $oy 5 12 19 12 2
        }
        "Chat" {
            RoundRect $ox $oy 3.5 4.5 17 12 3.5 $null $white 1.8
            Line $ox $oy 8 16.5 6.5 20.5 1.8
            Line $ox $oy 6.5 20.5 11.5 16.5 1.8
        }
        "Folder" {
            $pts = @(
                (New-Object System.Drawing.PointF(($ox + 3.5), ($oy + 6.5))),
                (New-Object System.Drawing.PointF(($ox + 9.5), ($oy + 6.5))),
                (New-Object System.Drawing.PointF(($ox + 11.5), ($oy + 8.5))),
                (New-Object System.Drawing.PointF(($ox + 20.5), ($oy + 8.5))),
                (New-Object System.Drawing.PointF(($ox + 20.5), ($oy + 18.5))),
                (New-Object System.Drawing.PointF(($ox + 3.5), ($oy + 18.5))))
            $g.DrawPolygon((Pen $white 1.8), $pts)
        }
        "Agent" {
            # The design's rail glyph: a speech bubble with a tail.
            $pts = @(
                (New-Object System.Drawing.PointF(($ox + 4), ($oy + 5))),
                (New-Object System.Drawing.PointF(($ox + 20), ($oy + 5))),
                (New-Object System.Drawing.PointF(($ox + 20), ($oy + 16))),
                (New-Object System.Drawing.PointF(($ox + 10), ($oy + 16))),
                (New-Object System.Drawing.PointF(($ox + 5), ($oy + 20))),
                (New-Object System.Drawing.PointF(($ox + 5), ($oy + 16))),
                (New-Object System.Drawing.PointF(($ox + 4), ($oy + 16))))
            $g.DrawPolygon((Pen $white 1.8), $pts)
        }
        "Close" {
            Line $ox $oy 6.5 6.5 17.5 17.5 2
            Line $ox $oy 17.5 6.5 6.5 17.5 2
        }
        "Sidebar" {
            RoundRect $ox $oy 3.5 4.5 17 15 2.5 $null $white 1.8
            Line $ox $oy 9.5 5 9.5 19 1.8
        }
    }
}

# ---- 24x24 icons after row 0 (x 244 on): the speaker, on and muted ----------
function SpeakerBody($ox, $oy) {
    $pts = @(
        (New-Object System.Drawing.PointF(($ox + 3.5), ($oy + 9))),
        (New-Object System.Drawing.PointF(($ox + 7.5), ($oy + 9))),
        (New-Object System.Drawing.PointF(($ox + 12.5), ($oy + 4.5))),
        (New-Object System.Drawing.PointF(($ox + 12.5), ($oy + 19.5))),
        (New-Object System.Drawing.PointF(($ox + 7.5), ($oy + 15))),
        (New-Object System.Drawing.PointF(($ox + 3.5), ($oy + 15))))
    $g.DrawPolygon((Pen $white 1.8), $pts)
}
$ox = 244; $oy = 0
Add "Speaker" $ox $oy 24 24
SpeakerBody $ox $oy
$g.DrawArc((Pen $white 1.8), [single]($ox + 11), [single]($oy + 8), [single]6, [single]8, -55, 110)
$g.DrawArc((Pen $white 1.8), [single]($ox + 11), [single]($oy + 4.5), [single]10, [single]15, -55, 110)
$ox = 270
Add "SpeakerOff" $ox $oy 24 24
SpeakerBody $ox $oy
Line $ox $oy 15.5 9 21 15 1.8
Line $ox $oy 21 9 15.5 15 1.8
# Copy: two sheets, the front one whole, the back one peeking out above left.
$ox = 296
Add "Copy" $ox $oy 24 24
RoundRect $ox $oy 8.5 8.5 11 12 2 $null $white 1.8
Line $ox $oy 4.5 15.5 4.5 5.5 1.8
Line $ox $oy 6.5 3.5 13.5 3.5 1.8
$g.DrawArc((Pen $white 1.8), [single]($ox + 4.5), [single]($oy + 3.5), [single]4, [single]4, 180, 90)

# ---- 24x24 icons, row 2 (y 100) ---------------------------------------------
$names2 = @("Spark", "Repo", "Boards", "Wiki", "Search", "Sun", "Moon", "Read", "Pencil", "Terminal", "Rewind", "Fork")
for ($i = 0; $i -lt $names2.Count; $i++) {
    $ox = $i * 26; $oy = 100
    Add $names2[$i] $ox $oy 24 24
    switch ($names2[$i]) {
        "Spark" {
            $pts = @(
                (New-Object System.Drawing.PointF(($ox + 12), ($oy + 2.5))),
                (New-Object System.Drawing.PointF(($ox + 14), ($oy + 10))),
                (New-Object System.Drawing.PointF(($ox + 21.5), ($oy + 12))),
                (New-Object System.Drawing.PointF(($ox + 14), ($oy + 14))),
                (New-Object System.Drawing.PointF(($ox + 12), ($oy + 21.5))),
                (New-Object System.Drawing.PointF(($ox + 10), ($oy + 14))),
                (New-Object System.Drawing.PointF(($ox + 2.5), ($oy + 12))),
                (New-Object System.Drawing.PointF(($ox + 10), ($oy + 10))))
            $g.FillPolygon((Brush $white), $pts)
        }
        "Repo" {
            # A branch: trunk, and a curve out to a second line.
            Line $ox $oy 7 4 7 20 1.8
            $g.DrawBezier((Pen $white 1.8), [single]($ox + 7), [single]($oy + 9), [single]($ox + 14), [single]($oy + 9),
                [single]($ox + 17), [single]($oy + 10), [single]($ox + 17), [single]($oy + 15))
            Line $ox $oy 17 15 17 20 1.8
        }
        "Boards" {
            $g.DrawRectangle((Pen $white 1.8), [single]($ox + 4), [single]($oy + 4), [single]6, [single]16)
            $g.DrawRectangle((Pen $white 1.8), [single]($ox + 14), [single]($oy + 4), [single]6, [single]10)
        }
        "Wiki" {
            $pts = @(
                (New-Object System.Drawing.PointF(($ox + 5), ($oy + 4))),
                (New-Object System.Drawing.PointF(($ox + 16), ($oy + 4))),
                (New-Object System.Drawing.PointF(($ox + 19), ($oy + 7))),
                (New-Object System.Drawing.PointF(($ox + 19), ($oy + 20))),
                (New-Object System.Drawing.PointF(($ox + 5), ($oy + 20))))
            $g.DrawPolygon((Pen $white 1.8), $pts)
            Line $ox $oy 9 11 15 11 1.8
            Line $ox $oy 9 15 15 15 1.8
        }
        "Search" {
            Ellipse $ox $oy 4.5 4.5 11 11 $null $white 1.8
            Line $ox $oy 14 14 19.5 19.5 1.8
        }
        "Sun" {
            Ellipse $ox $oy 8 8 8 8 $null $white 1.8
            for ($k = 0; $k -lt 8; $k++) {
                $a = $k * [Math]::PI / 4
                Line $ox $oy (12 + 6.5 * [Math]::Cos($a)) (12 + 6.5 * [Math]::Sin($a)) (12 + 9 * [Math]::Cos($a)) (12 + 9 * [Math]::Sin($a)) 1.6
            }
        }
        "Moon" {
            # A crescent: a disc with a smaller disc cut out of it.
            $g.FillEllipse((Brush $white), [single]($ox + 4), [single]($oy + 4), [single]16, [single]16)
            $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Transparent)), [single]($ox + 9), [single]($oy + 1), [single]14, [single]14)
            $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        }
        "Read" {
            # An open page.
            $g.DrawRectangle((Pen $white 1.6), [single]($ox + 5), [single]($oy + 4), [single]14, [single]16)
            Line $ox $oy 8 9 16 9 1.6
            Line $ox $oy 8 12.5 16 12.5 1.6
            Line $ox $oy 8 16 13 16 1.6
        }
        "Pencil" {
            Line $ox $oy 5 19 7 13 1.8
            Line $ox $oy 7 13 16 4 1.8
            Line $ox $oy 16 4 20 8 1.8
            Line $ox $oy 20 8 11 17 1.8
            Line $ox $oy 11 17 5 19 1.8
        }
        "Terminal" {
            Line $ox $oy 5 7 10 12 1.8
            Line $ox $oy 10 12 5 17 1.8
            Line $ox $oy 12 18 19 18 1.8
        }
        "Rewind" {
            # A circle that turns back: open at the top left, its arrow at the top.
            $g.DrawArc((Pen $white 2), [single]($ox + 4.5), [single]($oy + 5), [single]15, [single]15, 270, 290)
            Line $ox $oy 12 5 8 5 2
            Line $ox $oy 8 5 11.5 1.5 2
            Line $ox $oy 8 5 11.5 8.5 2
        }
        "Fork" {
            # Two ends joining into one: a conversation that splits.
            Ellipse $ox $oy 4.5 2.5 5 5 $null $white 1.8
            Ellipse $ox $oy 14.5 2.5 5 5 $null $white 1.8
            Ellipse $ox $oy 9.5 16.5 5 5 $null $white 1.8
            Line $ox $oy 7 7.5 7 9.5 1.8
            Line $ox $oy 17 7.5 17 9.5 1.8
            Line $ox $oy 7 9.5 12 13 1.8
            Line $ox $oy 17 9.5 12 13 1.8
            Line $ox $oy 12 13 12 16.5 1.8
        }
    }
}

# ---- Row sprites (y 130), white, tinted inline by core/sprites.lua ------------
#   CheckRing, CheckMark  14x14: a checkbox's outline and its tick
#   GraphRing, GraphDot   10x10: a History row's commit (hollow, filled)
#   Nav*                  16x16: the branch tree's icons
$oy = 130
# The outline has a faint inner line, so it still shows when a diff row
# puts it at half a pixel (filtering halves a lone 1px line).
$faint = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 255, 255, 255))
$g.FillRectangle($faint, 1, ($oy + 1), 12, 1)
$g.FillRectangle($faint, 1, ($oy + 12), 12, 1)
$g.FillRectangle($faint, 1, ($oy + 2), 1, 10)
$g.FillRectangle($faint, 12, ($oy + 2), 1, 10)
$g.FillRectangle((Brush $white), 0, $oy, 14, 1)
$g.FillRectangle((Brush $white), 0, ($oy + 13), 14, 1)
$g.FillRectangle((Brush $white), 0, $oy, 1, 14)
$g.FillRectangle((Brush $white), 13, $oy, 1, 14)
Add "CheckRing" 0 $oy 14 14
$tick = Pen $white 2
$g.DrawLines($tick, [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF(19.5, ($oy + 7.5))),
        (New-Object System.Drawing.PointF(22.5, ($oy + 10.5))),
        (New-Object System.Drawing.PointF(28, ($oy + 4)))))
Add "CheckMark" 16 $oy 14 14
Ellipse 32 $oy 1 1 8 8 $null $white 2
Add "GraphRing" 32 $oy 10 10
Ellipse 44 $oy 0 0 10 10 $white $null 0
Add "GraphDot" 44 $oy 10 10

# A label's outline (History's branch and tag names), 18px high, radius 5,
# in three slices: the round ends and a 1px middle that stretches.
RoundRect 210 $oy 0.5 0.5 10 17 4.5 $null $white 1
Add "PillLeft" 210 $oy 5 18
Add "PillMiddle" 215 $oy 1 18
Add "PillRight" 216 $oy 5 18

$navNames = @("NavBranch", "NavRemote", "NavTag", "NavStash", "NavSubmodule", "NavWorktree", "NavOpen", "NavClosed")
for ($i = 0; $i -lt $navNames.Count; $i++) {
    $ox = 60 + $i * 18
    Add $navNames[$i] $ox $oy 16 16
    switch ($navNames[$i]) {
        "NavBranch" {
            Ellipse $ox $oy 2.7 1.7 3.6 3.6 $null $white 1.4
            Ellipse $ox $oy 2.7 10.7 3.6 3.6 $null $white 1.4
            Ellipse $ox $oy 9.7 2.7 3.6 3.6 $null $white 1.4
            Line $ox $oy 4.5 5.5 4.5 10.5 1.4
            $g.DrawBezier((Pen $white 1.4), [single]($ox + 11.5), [single]($oy + 6.5), [single]($ox + 11.5), [single]($oy + 9.5),
                [single]($ox + 4.5), [single]($oy + 8), [single]($ox + 4.5), [single]($oy + 10.5))
        }
        "NavRemote" {
            Ellipse $ox $oy 1.5 6.5 6 6 $white $null 0
            Ellipse $ox $oy 4.5 3 7.5 7.5 $white $null 0
            Ellipse $ox $oy 9 5.5 5.5 5.5 $white $null 0
            $g.FillRectangle((Brush $white), [single]($ox + 4.5), [single]($oy + 8.5), [single]8, [single]4)
        }
        "NavTag" {
            $pts = @(
                (New-Object System.Drawing.PointF(($ox + 2.5), ($oy + 3.5))),
                (New-Object System.Drawing.PointF(($ox + 9), ($oy + 3.5))),
                (New-Object System.Drawing.PointF(($ox + 13.5), ($oy + 8))),
                (New-Object System.Drawing.PointF(($ox + 9), ($oy + 12.5))),
                (New-Object System.Drawing.PointF(($ox + 2.5), ($oy + 12.5))))
            $g.DrawPolygon((Pen $white 1.4), $pts)
            Ellipse $ox $oy 4.5 6.8 2.4 2.4 $white $null 0
        }
        "NavStash" {
            $g.DrawRectangle((Pen $white 1.4), [single]($ox + 2.5), [single]($oy + 3.5), [single]11, [single]3)
            $g.DrawRectangle((Pen $white 1.4), [single]($ox + 3.5), [single]($oy + 6.5), [single]9, [single]6)
            Line $ox $oy 6.5 9.5 9.5 9.5 1.4
        }
        "NavSubmodule" {
            $pts = @(
                (New-Object System.Drawing.PointF(($ox + 2.5), ($oy + 3.5))),
                (New-Object System.Drawing.PointF(($ox + 6.5), ($oy + 3.5))),
                (New-Object System.Drawing.PointF(($ox + 8), ($oy + 5.5))),
                (New-Object System.Drawing.PointF(($ox + 13.5), ($oy + 5.5))),
                (New-Object System.Drawing.PointF(($ox + 13.5), ($oy + 12.5))),
                (New-Object System.Drawing.PointF(($ox + 2.5), ($oy + 12.5))))
            $g.DrawPolygon((Pen $white 1.4), $pts)
        }
        "NavWorktree" {
            $g.DrawRectangle((Pen $white 1.4), [single]($ox + 2.5), [single]($oy + 5.5), [single]7, [single]7)
            $g.DrawRectangle((Pen $white 1.4), [single]($ox + 6.5), [single]($oy + 2.5), [single]7, [single]7)
        }
        "NavOpen" {
            Line $ox $oy 4.5 6 8 9.5 1.6
            Line $ox $oy 8 9.5 11.5 6 1.6
        }
        "NavClosed" {
            Line $ox $oy 6.5 4.5 10 8 1.6
            Line $ox $oy 10 8 6.5 11.5 1.6
        }
    }
}

# ---- Plan sprites (y 162), 16x16: the plan box's steps ----------------------
$oy = 162
Ellipse 0 $oy 1 1 14 14 $white $null 0
# The tick cut out of the circle, so the box shows through it.
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$cut = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 255, 255, 255), 1.9)
$cut.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$cut.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$cut.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawLines($cut, [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF(4.6, ($oy + 8.2))),
        (New-Object System.Drawing.PointF(7, ($oy + 10.6))),
        (New-Object System.Drawing.PointF(11.4, ($oy + 5.6)))))
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
Add "PlanDone" 0 $oy 16 16
for ($k = 0; $k -lt 8; $k++) {
    $g.DrawArc((Pen $white 1.5), [single](18 + 2), [single]($oy + 2), [single]12, [single]12, [single]($k * 45 + 8), [single]26)
}
Add "PlanPending" 18 $oy 16 16
$track = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 255, 255, 255), 1.8)
for ($f = 0; $f -lt 8; $f++) {
    $ox = 36 + $f * 18
    $g.DrawEllipse($track, [single]($ox + 2), [single]($oy + 2), [single]12, [single]12)
    $g.DrawArc((Pen $white 1.8), [single]($ox + 2), [single]($oy + 2), [single]12, [single]12, [single]($f * 45 - 90), [single]110)
    Add ("PlanSpin" + $f) $ox $oy 16 16
}

# ---- The design's logo in two tintable layers ---------------------------------
function LogoLayers($ox, $oy, $size) {
    $s = $size / 24.0
    $c = $size / 2.0
    # Petals: 12 ellipses rx 2.1, ry 4.6, centred 6.6 out (design viewBox -12..12).
    for ($k = 0; $k -lt 12; $k++) {
        $state = $g.Save()
        $g.TranslateTransform([single]($ox + $c), [single]($oy + $c))
        $g.RotateTransform([single]($k * 30))
        $g.FillEllipse((Brush $white), [single](-2.1 * $s), [single]((-6.6 - 4.6) * $s), [single](4.2 * $s), [single](9.2 * $s))
        $g.Restore($state)
    }
}
LogoLayers 100 32 30
Add "MarkPetals" 100 32 30 30
Ellipse 132 32 (15 - 4.2 * 30 / 24) (15 - 4.2 * 30 / 24) (8.4 * 30 / 24) (8.4 * 30 / 24) $white $null 0
Add "MarkCentre" 132 32 30 30
LogoLayers 164 32 64
Add "MarkPetalsLarge" 164 32 64 64
Ellipse 232 32 (32 - 4.2 * 64 / 24) (32 - 4.2 * 64 / 24) (8.4 * 64 / 24) (8.4 * 64 / 24) $white $null 0
Add "MarkCentreLarge" 232 32 64 64

# ---- The mark: a sunflower, full colour -------------------------------------
function Sunflower($ox, $oy, $size) {
    $c = $size / 2
    $petal = "FCB31E"; $edge = "CB6F18"
    for ($k = 0; $k -lt 12; $k++) {
        $a = $k * 30
        $state = $g.Save()
        $g.TranslateTransform([single]($ox + $c), [single]($oy + $c))
        $g.RotateTransform([single]$a)
        $pw = $size * 0.16; $ph = $size * 0.30
        $g.FillEllipse((Brush $petal), [single](-$pw / 2), [single](-$c + $size * 0.04), [single]$pw, [single]$ph)
        $g.DrawEllipse((Pen $edge ([Math]::Max(0.6, $size / 48))), [single](-$pw / 2), [single](-$c + $size * 0.04), [single]$pw, [single]$ph)
        $g.Restore($state)
    }
    $r = $size * 0.21
    Ellipse $ox $oy ($c - $r) ($c - $r) (2 * $r) (2 * $r) "5A3A12" "414B0E" ([Math]::Max(0.8, $size / 32))
    $r2 = $size * 0.09
    Ellipse $ox $oy ($c - $r2) ($c - $r2) (2 * $r2) (2 * $r2) "7A5418" $null 0
}
Sunflower 0 32 32
Add "Mark" 0 32 32 32
Sunflower 32 32 64
Add "MarkLarge" 32 32 64 64

$g.Dispose()
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bmp.Save((Join-Path $here "BragiIcons.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$xml = New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine('<!-- BragiIcons.xml - the Bragi UI''s images. Generated by make-icons.ps1; edit that, not this. -->')
[void]$xml.AppendLine('<Imageset version="2" name="Bragi-Icons" imagefile="BragiIcons.png" resourceGroup="ui-imagesets" nativeHorzRes="1280" nativeVertRes="720" autoScaled="false">')
foreach ($r in $regions) {
    [void]$xml.AppendLine(('    <Image name="{0}" xPos="{1}" yPos="{2}" width="{3}" height="{4}"/>' -f $r.Name, $r.X, $r.Y, $r.W, $r.H))
}
[void]$xml.AppendLine('</Imageset>')
[System.IO.File]::WriteAllText((Join-Path $here "BragiIcons.xml"), $xml.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote BragiIcons.png and BragiIcons.xml"
