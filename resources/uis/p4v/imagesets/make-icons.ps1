# Generates P4Icons.png + P4Icons.xml — the P4V-style UI's colour icons
# (imageset "P4-Icons"). Unlike the default UI's white-and-tinted atlas,
# these are drawn in colour for the Dagobah theme (light strokes on dark).
#
#   Toolbar icons, 24x24, first rows:  Refresh GetLatest Submit Checkout Add
#     Delete Revert Diff Timelapse Revgraph Shelve Unshelve Push Fetch Cancel
#     Branch Merge Label Console Settings Search Folder24 History Graph24
#   Tree and list icons, 16x16, after: Folder FolderOpen File Depot Workspace
#     ChangePending ChangeSubmitted ChangeShelved ChangeDefault Branch16
#     RemoteBranch Label16 Stash Remote Worktree Submodule TreeOpen TreeClosed
#     FileEdit FileAdd FileDelete FileUntracked FileConflict FileMoved
#     FileOutdated FileSynced FileShelved CheckOn CheckOff Dot Warning Info
#
# Run it after editing: powershell -ExecutionPolicy Bypass -File make-icons.ps1
Add-Type -AssemblyName System.Drawing

$W = 256; $H = 128
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)

$regions = New-Object System.Collections.ArrayList

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
function Pts($ox, $oy, $list) {
    $pts = @()
    for ($i = 0; $i -lt $list.Count; $i += 2) {
        $pts += New-Object System.Drawing.PointF(($ox + $list[$i]), ($oy + $list[$i + 1]))
    }
    return , $pts
}
function Poly($ox, $oy, $list, $fill, $stroke) {
    $pts = Pts $ox $oy $list
    if ($fill) { $g.FillPolygon((Brush $fill), $pts) }
    if ($stroke) { $g.DrawPolygon((Pen $stroke 1), $pts) }
}
function Line($ox, $oy, $x0, $y0, $x1, $y1, $hex, $w) {
    $g.DrawLine((Pen $hex $w), [single]($ox + $x0), [single]($oy + $y0), [single]($ox + $x1), [single]($oy + $y1))
}
function Rect($ox, $oy, $x, $y, $w, $h, $fill, $stroke) {
    if ($fill) { $g.FillRectangle((Brush $fill), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h) }
    if ($stroke) { $g.DrawRectangle((Pen $stroke 1), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h) }
}
function Ellipse($ox, $oy, $x, $y, $w, $h, $fill, $stroke, $sw) {
    if ($fill) { $g.FillEllipse((Brush $fill), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h) }
    if ($stroke) { $g.DrawEllipse((Pen $stroke $sw), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h) }
}
function Arc($ox, $oy, $x, $y, $w, $h, $start, $sweep, $hex, $sw) {
    $g.DrawArc((Pen $hex $sw), [single]($ox + $x), [single]($oy + $y), [single]$w, [single]$h, [single]$start, [single]$sweep)
}
function Add($name, $x, $y, $w, $h) {
    [void]$regions.Add(@{ Name = $name; X = $x; Y = $y; W = $w; H = $h })
}

# A document page (w x h) at (x, y) with a folded corner.
function Doc($ox, $oy, $x, $y, $w, $h, $fill) {
    $f = [Math]::Max(3, [int]($w / 3))
    Poly $ox $oy @($x, $y, ($x + $w - $f), $y, ($x + $w), ($y + $f), ($x + $w), ($y + $h), $x, ($y + $h)) $fill "6E6E6E"
    Poly $ox $oy @(($x + $w - $f), $y, ($x + $w - $f), ($y + $f), ($x + $w), ($y + $f)) "D8D8D8" "6E6E6E"
}
# An arrow shaft from (x0,y0) to (x1,y1) with a filled head.
function Arrow($ox, $oy, $x0, $y0, $x1, $y1, $hex, $w, $head) {
    $dx = $x1 - $x0; $dy = $y1 - $y0
    $len = [Math]::Sqrt($dx * $dx + $dy * $dy)
    $ux = $dx / $len; $uy = $dy / $len
    $bx = $x1 - $ux * $head; $by = $y1 - $uy * $head
    Line $ox $oy $x0 $y0 $bx $by $hex $w
    $hw = $head * 0.6
    Poly $ox $oy @($x1, $y1, ($bx - $uy * $hw), ($by + $ux * $hw), ($bx + $uy * $hw), ($by - $ux * $hw)) $hex $null
}
function Folder($ox, $oy, $s, $open) {
    $k = $s / 16.0
    Poly $ox $oy @((1 * $k), (3 * $k), (6 * $k), (3 * $k), (7.5 * $k), (4.5 * $k), (15 * $k), (4.5 * $k), (15 * $k), (13.5 * $k), (1 * $k), (13.5 * $k)) "E8B64A" "B98A26"
    if ($open) {
        Poly $ox $oy @((3 * $k), (7 * $k), (16 * $k), (7 * $k), (14 * $k), (13.5 * $k), (1 * $k), (13.5 * $k)) "F7D27A" "B98A26"
    } else {
        Poly $ox $oy @((1 * $k), (6.5 * $k), (15 * $k), (6.5 * $k), (15 * $k), (13.5 * $k), (1 * $k), (13.5 * $k)) "F5CC66" "B98A26"
    }
}
function Check($ox, $oy, $x, $y, $s, $hex, $w) {
    $pts = Pts $ox $oy @($x, ($y + $s * 0.55), ($x + $s * 0.38), ($y + $s * 0.9), ($x + $s), ($y + $s * 0.1))
    $g.DrawLines((Pen $hex $w), $pts)
}
function Cross($ox, $oy, $x, $y, $s, $hex, $w) {
    Line $ox $oy $x $y ($x + $s) ($y + $s) $hex $w
    Line $ox $oy ($x + $s) $y $x ($y + $s) $hex $w
}
function Plus($ox, $oy, $cx, $cy, $r, $hex, $w) {
    Line $ox $oy ($cx - $r) $cy ($cx + $r) $cy $hex $w
    Line $ox $oy $cx ($cy - $r) $cx ($cy + $r) $hex $w
}

# ---------------------------------------------------------------- 24px icons
$toolbar = @(
    "Refresh", "GetLatest", "Submit", "Checkout", "Add", "Delete", "Revert", "Diff",
    "Timelapse", "Revgraph", "Shelve", "Unshelve", "Push", "Fetch", "Cancel", "Branch",
    "Merge", "Label", "Console", "Settings", "Search", "Folder24", "History", "Graph24"
)
for ($i = 0; $i -lt $toolbar.Count; $i++) {
    $ox = ($i % 10) * 24; $oy = [Math]::Floor($i / 10) * 24
    $name = $toolbar[$i]
    switch ($name) {
        "Refresh" {
            Arc $ox $oy 4 4 16 16 200 250 "2E8B3D" 2.4
            Poly $ox $oy @(4, 3, 10, 5, 4, 10) "2E8B3D" $null
        }
        "GetLatest" {
            Rect $ox $oy 3 16 18 5 "D9E8F5" "4F7FAF"
            Arrow $ox $oy 12 2 12 16 "2E8B3D" 3 7
        }
        "Submit" {
            Rect $ox $oy 3 16 18 5 "D9E8F5" "4F7FAF"
            Arrow $ox $oy 12 17 12 2 "2A6EBB" 3 7
        }
        "Checkout" {
            Doc $ox $oy 4 2 13 18 "FFFFFF"
            Check $ox $oy 9 11 12 "D02A2A" 2.6
        }
        "Add" {
            Doc $ox $oy 4 2 13 18 "FFFFFF"
            Plus $ox $oy 16 16 5 "2E8B3D" 2.6
        }
        "Delete" {
            Doc $ox $oy 4 2 13 18 "FFFFFF"
            Cross $ox $oy 11 11 9 "D02A2A" 2.6
        }
        "Revert" {
            Arc $ox $oy 5 5 15 14 270 220 "2A6EBB" 2.4
            Poly $ox $oy @(3, 12, 10, 8, 10, 16) "2A6EBB" $null
        }
        "Diff" {
            Doc $ox $oy 2 2 11 15 "FFFFFF"
            Doc $ox $oy 11 7 11 15 "FFF6D5"
            Line $ox $oy 4 7 9 7 "D02A2A" 1.3
            Line $ox $oy 13 13 19 13 "2E8B3D" 1.3
            Line $ox $oy 13 16 19 16 "2E8B3D" 1.3
        }
        "Timelapse" {
            Ellipse $ox $oy 3 3 18 18 "FFFFFF" "A0A485" 1.6
            Line $ox $oy 12 12 12 6 "A0A485" 1.8
            Line $ox $oy 12 12 16 14 "D02A2A" 1.8
        }
        "Revgraph" {
            Rect $ox $oy 2 4 8 5 "A9A9EE" "5B5BBF"
            Rect $ox $oy 14 4 8 5 "A9A9EE" "5B5BBF"
            Rect $ox $oy 8 15 8 5 "A9A9EE" "5B5BBF"
            Arrow $ox $oy 6 9 10 15 "ECF1C1" 1.2 4
            Line $ox $oy 10 6.5 14 6.5 "ECF1C1" 1.2
        }
        "Shelve" {
            Rect $ox $oy 3 11 18 9 "D9B77E" "8A6A2E"
            Line $ox $oy 3 14 21 14 "8A6A2E" 1
            Arrow $ox $oy 12 2 12 12 "2A6EBB" 2.6 6
        }
        "Unshelve" {
            Rect $ox $oy 3 11 18 9 "D9B77E" "8A6A2E"
            Line $ox $oy 3 14 21 14 "8A6A2E" 1
            Arrow $ox $oy 12 12 12 1 "2E8B3D" 2.6 6
        }
        "Push" {
            Ellipse $ox $oy 3 8 18 11 "E4EEF9" "4F7FAF" 1.2
            Arrow $ox $oy 12 20 12 2 "2A6EBB" 2.6 6
        }
        "Fetch" {
            Ellipse $ox $oy 3 3 18 11 "E4EEF9" "4F7FAF" 1.2
            Arrow $ox $oy 12 5 12 22 "2E8B3D" 2.6 6
        }
        "Cancel" {
            Ellipse $ox $oy 3 3 18 18 "E25555" "A32020" 1.2
            Cross $ox $oy 8.5 8.5 7 "FFFFFF" 2.2
        }
        "Branch" {
            Line $ox $oy 7 4 7 20 "A0A485" 2
            Arc $ox $oy 7 6 10 10 0 90 "A0A485" 2
            Ellipse $ox $oy 4 2 6 6 "7EC8F2" "2A6EBB" 1.2
            Ellipse $ox $oy 4 16 6 6 "7EC8F2" "2A6EBB" 1.2
            Ellipse $ox $oy 14 5 6 6 "9BE08F" "2E8B3D" 1.2
        }
        "Merge" {
            Line $ox $oy 7 4 7 20 "A0A485" 2
            Arc $ox $oy 7 5 12 12 270 90 "A0A485" 2
            Ellipse $ox $oy 4 16 6 6 "7EC8F2" "2A6EBB" 1.2
            Ellipse $ox $oy 14 3 6 6 "9BE08F" "2E8B3D" 1.2
        }
        "Label" {
            Poly $ox $oy @(3, 11, 11, 3, 21, 3, 21, 13, 13, 21) "F7D27A" "B98A26"
            Ellipse $ox $oy 15 6 3 3 "FFFFFF" "B98A26" 1
        }
        "Console" {
            Rect $ox $oy 2 4 20 16 "1E1E1E" "A0A485"
            Line $ox $oy 5 9 8 12 "E8E8E8" 1.4
            Line $ox $oy 8 12 5 15 "E8E8E8" 1.4
            Line $ox $oy 10 15 15 15 "E8E8E8" 1.4
        }
        "Settings" {
            Ellipse $ox $oy 5 5 14 14 "B8B8B8" "A0A485" 1.6
            Ellipse $ox $oy 9 9 6 6 "FFFFFF" "A0A485" 1.2
            for ($k = 0; $k -lt 8; $k++) {
                $a = $k * [Math]::PI / 4
                Line $ox $oy (12 + 7 * [Math]::Cos($a)) (12 + 7 * [Math]::Sin($a)) (12 + 10 * [Math]::Cos($a)) (12 + 10 * [Math]::Sin($a)) "A0A485" 2.4
            }
        }
        "Search" {
            Ellipse $ox $oy 3 3 12 12 "FFFFFF" "A0A485" 2
            Line $ox $oy 13 13 20 20 "A0A485" 2.8
        }
        "Folder24" { Folder $ox $oy 24 $false }
        "History" {
            Doc $ox $oy 3 2 14 18 "FFFFFF"
            Ellipse $ox $oy 10 10 12 12 "FFFFFF" "2A6EBB" 1.6
            Line $ox $oy 16 16 16 12.5 "2A6EBB" 1.4
            Line $ox $oy 16 16 18.5 17 "2A6EBB" 1.4
        }
        "Graph24" {
            Line $ox $oy 6 3 6 21 "7373C9" 2
            Arc $ox $oy 6 6 12 12 270 90 "7373C9" 2
            Ellipse $ox $oy 3 3 6 6 "A9A9EE" "5B5BBF" 1.2
            Ellipse $ox $oy 3 15 6 6 "A9A9EE" "5B5BBF" 1.2
            Ellipse $ox $oy 15 9 6 6 "A9A9EE" "5B5BBF" 1.2
        }
    }
    Add $name $ox $oy 24 24
}

# ---------------------------------------------------------------- 16px icons
$small = @(
    "Folder", "FolderOpen", "File", "Depot", "Workspace", "ChangePending", "ChangeSubmitted",
    "ChangeShelved", "ChangeDefault", "Branch16", "RemoteBranch", "Label16", "Stash", "Remote",
    "Worktree", "Submodule", "TreeOpen", "TreeClosed", "FileEdit", "FileAdd", "FileDelete",
    "FileUntracked", "FileConflict", "FileMoved", "FileOutdated", "FileSynced", "FileShelved",
    "CheckOn", "CheckOff", "Dot", "Warning", "Info"
)
for ($i = 0; $i -lt $small.Count; $i++) {
    $ox = ($i % 16) * 16; $oy = 72 + [Math]::Floor($i / 16) * 16
    $name = $small[$i]
    switch ($name) {
        "Folder" { Folder $ox $oy 16 $false }
        "FolderOpen" { Folder $ox $oy 16 $true }
        "File" { Doc $ox $oy 3 1 10 14 "FFFFFF" }
        "Depot" {
            Ellipse $ox $oy 2 10 12 5 "8FB8E0" "3F6E9E" 1
            Rect $ox $oy 2 4 12 8.5 "A9CBEB" $null
            Line $ox $oy 2 4 2 12.5 "3F6E9E" 1
            Line $ox $oy 14 4 14 12.5 "3F6E9E" 1
            Ellipse $ox $oy 2 1.5 12 5 "D2E5F6" "3F6E9E" 1
        }
        "Workspace" {
            Rect $ox $oy 1.5 2 13 9 "BFE0F7" "3F6E9E"
            Rect $ox $oy 6 11 4 2 "A0A485" $null
            Rect $ox $oy 3.5 13 9 1.5 "A0A485" $null
        }
        "ChangePending" {
            Doc $ox $oy 2 1 11 14 "FFE9E9"
            Line $ox $oy 4 6 10 6 "C44A4A" 1
            Line $ox $oy 4 9 10 9 "C44A4A" 1
            Line $ox $oy 4 12 8 12 "C44A4A" 1
        }
        "ChangeSubmitted" {
            Doc $ox $oy 2 1 11 14 "EAF4FF"
            Line $ox $oy 4 6 10 6 "4F7FAF" 1
            Line $ox $oy 4 9 10 9 "4F7FAF" 1
            Check $ox $oy 7 9 7 "2E8B3D" 1.8
        }
        "ChangeShelved" {
            Rect $ox $oy 1.5 7 13 7.5 "D9B77E" "8A6A2E"
            Doc $ox $oy 4 1 8 8 "FFE9E9"
        }
        "ChangeDefault" {
            Doc $ox $oy 2 1 11 14 "FFF4D6"
            Line $ox $oy 4 6 10 6 "B98A26" 1
            Line $ox $oy 4 9 10 9 "B98A26" 1
        }
        "Branch16" {
            Line $ox $oy 5 3 5 13 "A0A485" 1.4
            Arc $ox $oy 5 4 6 6 0 90 "A0A485" 1.4
            Ellipse $ox $oy 3 1 4 4 "7EC8F2" "2A6EBB" 1
            Ellipse $ox $oy 3 11 4 4 "7EC8F2" "2A6EBB" 1
            Ellipse $ox $oy 9.5 3 4 4 "9BE08F" "2E8B3D" 1
        }
        "RemoteBranch" {
            Ellipse $ox $oy 1 2 14 9 "E4EEF9" "4F7FAF" 1
            Line $ox $oy 6 7 6 14 "A0A485" 1.4
            Ellipse $ox $oy 4 11 4 4 "7EC8F2" "2A6EBB" 1
        }
        "Label16" {
            Poly $ox $oy @(1.5, 8, 7.5, 2, 14.5, 2, 14.5, 9, 8.5, 15) "F7D27A" "B98A26"
            Ellipse $ox $oy 10.5 4 2 2 "FFFFFF" "B98A26" 1
        }
        "Stash" {
            Rect $ox $oy 1.5 6 13 8.5 "C7B8E8" "6A55A8"
            Line $ox $oy 1.5 9 14.5 9 "6A55A8" 1
            Rect $ox $oy 3.5 2 9 4 "E3DAF5" "6A55A8"
        }
        "Remote" {
            Ellipse $ox $oy 1 4 14 9 "E4EEF9" "4F7FAF" 1
            Ellipse $ox $oy 4 2 8 6 "E4EEF9" "4F7FAF" 1
        }
        "Worktree" {
            Folder $ox $oy 16 $false
            Ellipse $ox $oy 8 8 6 6 "9BE08F" "2E8B3D" 1
        }
        "Submodule" {
            Rect $ox $oy 1.5 3 9 9 "F3D9EF" "A34A98"
            Rect $ox $oy 5.5 6 9 9 "FBEAF8" "A34A98"
        }
        "TreeOpen" { Poly $ox $oy @(3.5, 5.5, 12.5, 5.5, 8, 11) "ECF1C1" $null }
        "TreeClosed" { Poly $ox $oy @(5.5, 3.5, 11, 8, 5.5, 12.5) "ECF1C1" $null }
        "FileEdit" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            Check $ox $oy 5 7 9 "D02A2A" 2
        }
        "FileAdd" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            Plus $ox $oy 10 11 3.5 "D02A2A" 2
        }
        "FileDelete" {
            Doc $ox $oy 3 1 10 14 "EDEDED"
            Cross $ox $oy 6 7 7 "D02A2A" 2
        }
        "FileUntracked" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            $g.DrawString("?", (New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)), (Brush "A0A485"), [single]($ox + 5), [single]($oy + 2))
        }
        "FileConflict" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            Poly $ox $oy @(9, 6, 15, 15, 3, 15) "F2C037" "8A6A00"
            Line $ox $oy 9 9 9 12 "000000" 1.4
        }
        "FileMoved" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            Arrow $ox $oy 4 10 13 10 "D02A2A" 1.6 4
        }
        "FileOutdated" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            Ellipse $ox $oy 8 8 7 7 "F2C037" "8A6A00" 1
        }
        "FileSynced" {
            Doc $ox $oy 3 1 10 14 "FFFFFF"
            Ellipse $ox $oy 9 9 6 6 "3DB54A" "1E7A2A" 1
        }
        "FileShelved" {
            Doc $ox $oy 3 1 10 10 "FFFFFF"
            Rect $ox $oy 1.5 9 13 5.5 "D9B77E" "8A6A2E"
        }
        "CheckOn" {
            Rect $ox $oy 2 2 12 12 "0078D7" "005A9E"
            Check $ox $oy 4.5 4.5 7 "FFFFFF" 1.8
        }
        "CheckOff" { Rect $ox $oy 2 2 12 12 "FFFFFF" "333333" }
        "Dot" { Ellipse $ox $oy 5 5 6 6 "3DB54A" "1E7A2A" 1 }
        "Warning" {
            Poly $ox $oy @(8, 1.5, 15, 14.5, 1, 14.5) "F2C037" "8A6A00"
            Line $ox $oy 8 6 8 10 "000000" 1.6
            Ellipse $ox $oy 7.2 11.5 1.6 1.6 "000000" $null 1
        }
        "Info" {
            Ellipse $ox $oy 1.5 1.5 13 13 "2A6EBB" "1E4F87" 1
            Line $ox $oy 8 7 8 12 "FFFFFF" 1.8
            Ellipse $ox $oy 7.1 3.6 1.8 1.8 "FFFFFF" $null 1
        }
    }
    Add $name $ox $oy 16 16
}

# A transparent 1x1 spacer (sizes rows / pads inline images).
Add "Spacer" 255 127 1 1

$g.Dispose()
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bmp.Save((Join-Path $here "P4Icons.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$xml = @()
$xml += '<?xml version="1.0" encoding="UTF-8"?>'
$xml += '<!-- P4Icons.xml - the P4V-style UI''s colour icons. Generated by make-icons.ps1; edit that, not this. -->'
$xml += '<Imageset version="2" name="P4-Icons" imagefile="P4Icons.png" resourceGroup="ui-imagesets" nativeHorzRes="1280" nativeVertRes="720" autoScaled="false">'
foreach ($r in $regions) {
    $xml += ('    <Image name="{0}" xPos="{1}" yPos="{2}" width="{3}" height="{4}"/>' -f $r.Name, $r.X, $r.Y, $r.W, $r.H)
}
$xml += '</Imageset>'
[System.IO.File]::WriteAllLines((Join-Path $here "P4Icons.xml"), $xml, (New-Object System.Text.UTF8Encoding($false)))
"Wrote P4Icons.png and P4Icons.xml ($($regions.Count) images)"
