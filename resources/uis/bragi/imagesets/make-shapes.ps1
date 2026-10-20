# Generates the Bragi UI's rounded shapes (CEGUI draws only square boxes):
#
#   imagesets/BragiShapes.png + .xml   anti-aliased corner and edge pieces,
#                                      white, for each radius (imageset
#                                      "Bragi-Shapes")
#   looknfeel/Shapes.xml               a look per radius:
#                                        Bragi/Box<r>     a rounded box: FillColour,
#                                                         BorderColour
#                                        Bragi/Button<r>  a rounded push button:
#                                                         Normal/Hover/Pushed/Disabled
#                                                         FillColour and TextColour,
#                                                         BorderColour
#                                        Bragi/DashButton8  the same with a dashed
#                                                         border
#   schemes/Bragi.xml                  the window types for those looks
#   imagesets/BragiRows.png + .xml     selected list rows, rounded, per row
#                                      height and width (imageset "Bragi-Rows")
#
# Radius 4, 12 and 22 at twice their size are circles: the 8px status dot,
# 24px avatars, the 44px mic button. Colour defaults are theme tokens
# ($panel, ...; themes/*.ini).
#
# Run it after editing: powershell -ExecutionPolicy Bypass -File make-shapes.ps1
Add-Type -AssemblyName System.Drawing

$Radii = @(4, 6, 8, 10, 12, 16, 22)
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Package = Split-Path -Parent $Here

$W = 512; $H = 256
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)
$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1)

$regions = New-Object System.Collections.ArrayList
function Add($name, $x, $y, $w, $h) {
    [void]$regions.Add(@{ Name = $name; X = $x; Y = $y; W = $w; H = $h })
}

# A solid block; the image is its middle pixel, so filtering never picks up
# the transparent surroundings when CEGUI stretches it.
$g.FillRectangle($white, 1, 1, 3, 3)
Add "Solid" 2 2 1 1

$y = 8
foreach ($r in $Radii) {
    $x = 2
    $d = 2 * $r
    # Quarter discs (fill) and quarter rings (border), one per corner. The
    # full ellipse is drawn and clipped to the corner's square.
    $corners = @(
        @{ Name = "TL"; Dx = 0; Dy = 0 }, @{ Name = "TR"; Dx = - $r; Dy = 0 },
        @{ Name = "BL"; Dx = 0; Dy = - $r }, @{ Name = "BR"; Dx = - $r; Dy = - $r })
    foreach ($kind in @("Fill", "Ring")) {
        foreach ($c in $corners) {
            $g.SetClip((New-Object System.Drawing.RectangleF([single]$x, [single]$y, [single]$r, [single]$r)))
            if ($kind -eq "Fill") {
                $g.FillEllipse($white, [single]($x + $c.Dx), [single]($y + $c.Dy), [single]$d, [single]$d)
            } else {
                $g.DrawEllipse($pen, [single]($x + $c.Dx + 0.5), [single]($y + $c.Dy + 0.5), [single]($d - 1), [single]($d - 1))
            }
            $g.ResetClip()
            Add "R$r$kind$($c.Name)" $x $y $r $r
            $x += $r + 2
        }
    }
    # Fill edges: solid strips r thick, 3px long; the image is the middle
    # pixel's line. Horizontal (top and bottom edges) then vertical.
    $g.FillRectangle($white, $x, $y, 3, $r)
    Add "R$($r)FillH" ($x + 1) $y 1 $r
    $x += 5
    $g.FillRectangle($white, $x, $y, $r, 3)
    Add "R$($r)FillV" $x ($y + 1) $r 1
    $x += $r + 2
    # Border edges: a 1px line on the outer side of an r-thick strip.
    $g.FillRectangle($white, $x, $y, 3, 1)
    Add "R$($r)RingT" ($x + 1) $y 1 $r
    $x += 5
    $g.FillRectangle($white, $x, ($y + $r - 1), 3, 1)
    Add "R$($r)RingB" ($x + 1) $y 1 $r
    $x += 5
    $g.FillRectangle($white, $x, $y, 1, 3)
    Add "R$($r)RingL" $x ($y + 1) $r 1
    $x += $r + 2
    $g.FillRectangle($white, ($x + $r - 1), $y, 1, 3)
    Add "R$($r)RingR" $x ($y + 1) $r 1
    $x += $r + 2
    if ($x -gt $W) { throw "atlas too narrow for radius $r" }
    $y += [Math]::Max($r, 3) + 4
}
# Dashed border edges for radius 8 (Bragi/DashButton8): 3px dashes, 3px
# apart, on the outer side of an 8px strip, tiled along each edge.
$x = 2
$DashR = 8
foreach ($i in 0..2) {
    $g.FillRectangle($white, ($x + $i), $y, 1, 1)
}
Add "R$($DashR)DashT" $x $y 6 $DashR
$x += 8
foreach ($i in 0..2) {
    $g.FillRectangle($white, ($x + $i), ($y + $DashR - 1), 1, 1)
}
Add "R$($DashR)DashB" $x $y 6 $DashR
$x += 8
foreach ($i in 0..2) {
    $g.FillRectangle($white, $x, ($y + $i), 1, 1)
}
Add "R$($DashR)DashL" $x $y $DashR 6
$x += $DashR + 2
foreach ($i in 0..2) {
    $g.FillRectangle($white, ($x + $DashR - 1), ($y + $i), 1, 1)
}
Add "R$($DashR)DashR" $x $y $DashR 6
$y += $DashR + 4
if ($y -gt $H) { throw "atlas too short" }

$g.Dispose()
$bmp.Save((Join-Path $Here "BragiShapes.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---- imageset ----------------------------------------------------------------
$xml = New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine('<!-- BragiShapes.xml - rounded corner and edge pieces. Generated by make-shapes.ps1; edit that, not this. -->')
[void]$xml.AppendLine('<Imageset version="2" name="Bragi-Shapes" imagefile="BragiShapes.png" resourceGroup="ui-imagesets" nativeHorzRes="1280" nativeVertRes="720" autoScaled="false">')
foreach ($r in $regions) {
    [void]$xml.AppendLine(('    <Image name="{0}" xPos="{1}" yPos="{2}" width="{3}" height="{4}"/>' -f $r.Name, $r.X, $r.Y, $r.W, $r.H))
}
[void]$xml.AppendLine('</Imageset>')
[System.IO.File]::WriteAllText((Join-Path $Here "BragiShapes.xml"), $xml.ToString(), $utf8)

# ---- selected list rows --------------------------------------------------------
# A list's selected row is one image stretched to the row (SelectionBrushImage),
# so its corners only stay round near the width it was drawn at: radius 8 rows
# for each list's row height, at widths 60px apart. scripts/bragi/rows.lua
# picks the nearest (imageset "Bragi-Rows").
$RowHeights = @(30, 44, 56, 61)
$RowWidths = @(180, 240, 300, 360, 420, 480, 540, 600, 660)
$rw = 664
$rh = 0
foreach ($h in $RowHeights) { $rh += ($h + 2) * $RowWidths.Count }
$rows = New-Object System.Drawing.Bitmap($rw, $rh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$rg = [System.Drawing.Graphics]::FromImage($rows)
$rg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$rg.Clear([System.Drawing.Color]::Transparent)
$rowRegions = New-Object System.Collections.ArrayList
$ry = 1
foreach ($h in $RowHeights) {
    foreach ($w in $RowWidths) {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = 16
        $path.AddArc(1, $ry, $d, $d, 180, 90)
        $path.AddArc(1 + $w - $d, $ry, $d, $d, 270, 90)
        $path.AddArc(1 + $w - $d, $ry + $h - $d, $d, $d, 0, 90)
        $path.AddArc(1, $ry + $h - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $rg.FillPath($white, $path)
        [void]$rowRegions.Add(@{ Name = "Row$($h)x$($w)"; X = 1; Y = $ry; W = $w; H = $h })
        $ry += $h + 2
    }
}
$rg.Dispose()
$rows.Save((Join-Path $Here "BragiRows.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$rows.Dispose()
$xml = New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine('<!-- BragiRows.xml - selected list rows. Generated by make-shapes.ps1; edit that, not this. -->')
[void]$xml.AppendLine('<Imageset version="2" name="Bragi-Rows" imagefile="BragiRows.png" resourceGroup="ui-imagesets" nativeHorzRes="1280" nativeVertRes="720" autoScaled="false">')
foreach ($r in $rowRegions) {
    [void]$xml.AppendLine(('    <Image name="{0}" xPos="{1}" yPos="{2}" width="{3}" height="{4}"/>' -f $r.Name, $r.X, $r.Y, $r.W, $r.H))
}
[void]$xml.AppendLine('</Imageset>')
[System.IO.File]::WriteAllText((Join-Path $Here "BragiRows.xml"), $xml.ToString(), $utf8)

# ---- looks -------------------------------------------------------------------
function Area() {
    return @'
                <Area>
                    <Dim type="LeftEdge"><AbsoluteDim value="0"/></Dim>
                    <Dim type="TopEdge"><AbsoluteDim value="0"/></Dim>
                    <Dim type="RightEdge"><UnifiedDim scale="1" type="RightEdge"/></Dim>
                    <Dim type="BottomEdge"><UnifiedDim scale="1" type="BottomEdge"/></Dim>
                </Area>
'@
}
function Frame($r, $kind) {
    $corner = if ($kind -eq "Dash") { "Ring" } else { $kind }
    $s = "            <FrameComponent>`r`n" + (Area)
    $s += "                <Image component=`"TopLeftCorner`" name=`"Bragi-Shapes/R$r$($corner)TL`"/>`r`n"
    $s += "                <Image component=`"TopRightCorner`" name=`"Bragi-Shapes/R$r$($corner)TR`"/>`r`n"
    $s += "                <Image component=`"BottomLeftCorner`" name=`"Bragi-Shapes/R$r$($corner)BL`"/>`r`n"
    $s += "                <Image component=`"BottomRightCorner`" name=`"Bragi-Shapes/R$r$($corner)BR`"/>`r`n"
    if ($kind -eq "Dash") {
        foreach ($edge in @(@("TopEdge", "T"), @("BottomEdge", "B"), @("LeftEdge", "L"), @("RightEdge", "R"))) {
            $s += "                <Image component=`"$($edge[0])`" name=`"Bragi-Shapes/R$($r)Dash$($edge[1])`"/>`r`n"
        }
        $s += "                <HorzFormat type=`"Tiled`" component=`"TopEdge`"/>`r`n"
        $s += "                <HorzFormat type=`"Tiled`" component=`"BottomEdge`"/>`r`n"
        $s += "                <VertFormat type=`"Tiled`" component=`"LeftEdge`"/>`r`n"
        $s += "                <VertFormat type=`"Tiled`" component=`"RightEdge`"/>`r`n"
    } elseif ($kind -eq "Fill") {
        $s += "                <Image component=`"TopEdge`" name=`"Bragi-Shapes/R$($r)FillH`"/>`r`n"
        $s += "                <Image component=`"BottomEdge`" name=`"Bragi-Shapes/R$($r)FillH`"/>`r`n"
        $s += "                <Image component=`"LeftEdge`" name=`"Bragi-Shapes/R$($r)FillV`"/>`r`n"
        $s += "                <Image component=`"RightEdge`" name=`"Bragi-Shapes/R$($r)FillV`"/>`r`n"
        $s += "                <Image component=`"Background`" name=`"Bragi-Shapes/Solid`"/>`r`n"
    } else {
        $s += "                <Image component=`"TopEdge`" name=`"Bragi-Shapes/R$($r)RingT`"/>`r`n"
        $s += "                <Image component=`"BottomEdge`" name=`"Bragi-Shapes/R$($r)RingB`"/>`r`n"
        $s += "                <Image component=`"LeftEdge`" name=`"Bragi-Shapes/R$($r)RingL`"/>`r`n"
        $s += "                <Image component=`"RightEdge`" name=`"Bragi-Shapes/R$($r)RingR`"/>`r`n"
    }
    $s += "            </FrameComponent>`r`n"
    return $s
}
function Prop($name, $value, $type = "ColourRect") {
    return "        <PropertyDefinition redrawOnWrite=`"true`" initialValue=`"$value`" type=`"$type`" name=`"$name`"/>`r`n"
}
function Layer($fill, $text) {
    $s = "            <Layer>`r`n"
    $s += "                <Section section=`"fill`"><ColourProperty name=`"$fill`"/></Section>`r`n"
    $s += "                <Section section=`"border`"><ColourProperty name=`"BorderColour`"/></Section>`r`n"
    if ($text) {
        $s += "                <Section section=`"label`"><ColourProperty name=`"$text`"/></Section>`r`n"
    }
    $s += "            </Layer>`r`n"
    return $s
}

$looks = New-Object System.Text.StringBuilder
[void]$looks.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$looks.AppendLine('<!-- Shapes.xml - the Bragi UI''s rounded boxes and buttons. Generated by imagesets/make-shapes.ps1; edit that, not this. -->')
[void]$looks.AppendLine('<Falagard version="7">')
foreach ($r in $Radii) {
    [void]$looks.AppendLine("    <WidgetLook name=`"Bragi/Box$r`">")
    [void]$looks.Append((Prop "FillColour" '$panel'))
    [void]$looks.Append((Prop "BorderColour" "00000000"))
    [void]$looks.AppendLine("        <ImagerySection name=`"fill`">")
    [void]$looks.Append((Frame $r "Fill"))
    [void]$looks.AppendLine("        </ImagerySection>")
    [void]$looks.AppendLine("        <ImagerySection name=`"border`">")
    [void]$looks.Append((Frame $r "Ring"))
    [void]$looks.AppendLine("        </ImagerySection>")
    foreach ($state in @("Enabled", "Disabled")) {
        [void]$looks.AppendLine("        <StateImagery name=`"$state`">")
        [void]$looks.Append((Layer "FillColour" $null))
        [void]$looks.AppendLine("        </StateImagery>")
    }
    [void]$looks.AppendLine("    </WidgetLook>")
    [void]$looks.AppendLine("")

    # Buttons: a solid outline, and for radius 8 a dashed one as well
    # (Bragi/DashButton8, a secondary action that asks the agent).
    $buttons = New-Object System.Collections.ArrayList
    [void]$buttons.Add(@("Button", "Ring"))
    if ($r -eq $DashR) { [void]$buttons.Add(@("DashButton", "Dash")) }
    foreach ($b in $buttons) {
        [void]$looks.AppendLine("    <WidgetLook name=`"Bragi/$($b[0])$r`">")
        [void]$looks.Append((Prop "NormalFillColour" '$panel'))
        [void]$looks.Append((Prop "HoverFillColour" '$hover'))
        [void]$looks.Append((Prop "PushedFillColour" '$sel'))
        [void]$looks.Append((Prop "DisabledFillColour" '$panel'))
        [void]$looks.Append((Prop "BorderColour" '$border'))
        [void]$looks.Append((Prop "NormalTextColour" '$text'))
        [void]$looks.Append((Prop "HoverTextColour" '$text'))
        [void]$looks.Append((Prop "PushedTextColour" '$text'))
        [void]$looks.Append((Prop "DisabledTextColour" '$disabled'))
        [void]$looks.Append((Prop "HorzFormatting" "CentreAligned" "HorizontalTextFormatting"))
        [void]$looks.AppendLine("        <Property name=`"Size`" value=`"{{0, 96}, {0, 36}}`"/>")
        [void]$looks.AppendLine("        <ImagerySection name=`"fill`">")
        [void]$looks.Append((Frame $r "Fill"))
        [void]$looks.AppendLine("        </ImagerySection>")
        [void]$looks.AppendLine("        <ImagerySection name=`"border`">")
        [void]$looks.Append((Frame $r $b[1]))
        [void]$looks.AppendLine("        </ImagerySection>")
        [void]$looks.AppendLine("        <ImagerySection name=`"label`">")
        [void]$looks.AppendLine("            <TextComponent>")
        [void]$looks.AppendLine("                <Area>")
        [void]$looks.AppendLine("                    <Dim type=`"LeftEdge`"><AbsoluteDim value=`"12`"/></Dim>")
        [void]$looks.AppendLine("                    <Dim type=`"TopEdge`"><AbsoluteDim value=`"0`"/></Dim>")
        [void]$looks.AppendLine("                    <Dim type=`"RightEdge`"><UnifiedDim scale=`"1`" offset=`"-12`" type=`"RightEdge`"/></Dim>")
        [void]$looks.AppendLine("                    <Dim type=`"BottomEdge`"><UnifiedDim scale=`"1`" type=`"BottomEdge`"/></Dim>")
        [void]$looks.AppendLine("                </Area>")
        [void]$looks.AppendLine("                <VertFormat type=`"CentreAligned`"/>")
        [void]$looks.AppendLine("                <HorzFormatProperty name=`"HorzFormatting`"/>")
        [void]$looks.AppendLine("            </TextComponent>")
        [void]$looks.AppendLine("        </ImagerySection>")
        foreach ($state in @(@("Normal", "Normal"), @("Hover", "Hover"), @("Pushed", "Pushed"), @("PushedOff", "Hover"), @("Disabled", "Disabled"))) {
            [void]$looks.AppendLine("        <StateImagery name=`"$($state[0])`">")
            [void]$looks.Append((Layer "$($state[1])FillColour" "$($state[1])TextColour"))
            [void]$looks.AppendLine("        </StateImagery>")
        }
        [void]$looks.AppendLine("    </WidgetLook>")
        [void]$looks.AppendLine("")
    }
}
[void]$looks.AppendLine('</Falagard>')
New-Item -ItemType Directory -Force (Join-Path $Package "looknfeel") | Out-Null
[System.IO.File]::WriteAllText((Join-Path $Package "looknfeel\Shapes.xml"), $looks.ToString(), $utf8)

# ---- scheme ------------------------------------------------------------------
$scheme = New-Object System.Text.StringBuilder
[void]$scheme.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$scheme.AppendLine('<!-- Bragi.xml - the Bragi UI''s own window types. Generated by imagesets/make-shapes.ps1; edit that, not this. -->')
[void]$scheme.AppendLine('<GUIScheme version="5" name="Bragi">')
foreach ($r in $Radii) {
    [void]$scheme.AppendLine("    <FalagardMapping windowType=`"Bragi/Box$r`" targetType=`"DefaultWindow`" renderer=`"Core/Default`" lookNFeel=`"Bragi/Box$r`" />")
    [void]$scheme.AppendLine("    <FalagardMapping windowType=`"Bragi/Button$r`" targetType=`"CEGUI/PushButton`" renderer=`"Core/Button`" lookNFeel=`"Bragi/Button$r`" />")
    if ($r -eq $DashR) {
        [void]$scheme.AppendLine("    <FalagardMapping windowType=`"Bragi/DashButton$r`" targetType=`"CEGUI/PushButton`" renderer=`"Core/Button`" lookNFeel=`"Bragi/DashButton$r`" />")
    }
}
[void]$scheme.AppendLine('</GUIScheme>')
New-Item -ItemType Directory -Force (Join-Path $Package "schemes") | Out-Null
[System.IO.File]::WriteAllText((Join-Path $Package "schemes\Bragi.xml"), $scheme.ToString(), $utf8)

Write-Host "Wrote BragiShapes.png/.xml, BragiRows.png/.xml, looknfeel/Shapes.xml, schemes/Bragi.xml"
