--- bragi/rows.lua: helpers for list rows drawn in the design's style
-- (Changes, History, the branch tree, the Agent view's sessions).
--
--   rows.measure(markup)              width of some markup, in pixels
--   rows.fitText(font, s, width)      s cut with "…" to fit a width
--   rows.length / head / tail         UTF-8 aware string helpers
--   rows.select(list, height, count)  give a list the rounded selected row
--                                     that suits its width (imagesets/
--                                     BragiRows.xml, made by make-shapes.ps1)
--
-- A list draws its selected row as one stretched image, so the round
-- corners only hold near the width the image was drawn at: rows.select
-- picks the nearest of several. Call it again when the list's width
-- changes.

local text = require("core.text")

local rows = {}

-- Keep in step with $RowHeights and $RowWidths in imagesets/make-shapes.ps1.
local HEIGHTS = { 30, 44, 56, 61 }
local WIDTHS = { 180, 240, 300, 360, 420, 480, 540, 600, 660 }
local FRAME = 14            -- a list's items area is this much narrower than it
local SCROLLBAR = 14
local MEASURE = "BragiRowsMeasure"

--- Characters in a UTF-8 string.
function rows.length(s)
    return utf8.len(s) or #s
end

--- The first `n` characters of a UTF-8 string.
function rows.head(s, n)
    local stop = utf8.offset(s, n + 1)
    return stop and s:sub(1, stop - 1) or s
end

--- The last `n` characters of a UTF-8 string.
function rows.tail(s, n)
    local start = utf8.offset(s, -n)
    return start and s:sub(start) or s
end

--- Width of some markup in a hidden label.
-- @return pixels
function rows.measure(markup)
    if not gitgud.getRect(MEASURE) then
        gitgud.createWindow("Gitgud/StaticText", MEASURE, "Root")
        gitgud.setVisible(MEASURE, false)
        gitgud.setProperty(MEASURE, "Area", "{{0,0},{0,0},{0,4000},{0,60}}")
    end
    gitgud.setText(MEASURE, markup)
    return tonumber(gitgud.getProperty(MEASURE, "HorzExtent") or "") or 0
end

--- Text cut with "…" to fit a width in a font (plain text in and out).
function rows.fitText(font, s, width)
    local prefix = "[font='" .. font .. "']"
    if rows.measure(prefix .. text.escape(s)) <= width then
        return s
    end
    local lo, hi = 0, rows.length(s)
    while lo < hi do
        local mid = (lo + hi + 1) // 2
        if rows.measure(prefix .. text.escape(rows.head(s, mid) .. "…")) <= width then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return rows.head(s, lo) .. "…"
end

--- The selected-row image nearest to a row's size.
-- @param height  row height
-- @param width   selected row width
-- @return image name
function rows.brush(height, width)
    local h = HEIGHTS[1]
    for _, candidate in ipairs(HEIGHTS) do
        if math.abs(candidate - height) < math.abs(h - height) then
            h = candidate
        end
    end
    local w = WIDTHS[1]
    for _, candidate in ipairs(WIDTHS) do
        if math.abs(candidate - width) < math.abs(w - width) then
            w = candidate
        end
    end
    return "Bragi-Rows/Row" .. h .. "x" .. w
end

--- Give a list the rounded selected row for its width.
-- @param list    list widget
-- @param height  its row height
-- @param count   its number of rows (a scrollbar narrows the rows)
function rows.select(list, height, count)
    local _, _, w, h = gitgud.getRect(list)
    if not w then
        return
    end
    local scrollbar = (count or 0) * height > h - 4 and SCROLLBAR or 0
    gitgud.setProperty(list, "SelectionBrushImage", rows.brush(height, w - FRAME - scrollbar))
end

return rows
