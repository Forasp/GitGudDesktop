--- bragi/textselect.lua: selecting and copying a conversation's text,
-- as in any chat app: drag across a message, or several, to
-- select; double-click selects a word and triple-click a paragraph;
-- Ctrl+C or the right-click menu copies.
--
-- The transcript's text is static text, which can't be selected, so this
-- draws the selection itself: gitgud.watchPointer reports the mouse over
-- the transcript, gitgud.textIndexAt finds the character under it,
-- gitgud.shownRects where a run of characters is drawn, and a see-through
-- box in the selection colour goes over each line of it. What's copied is
-- the text as it shows (gitgud.shownText), in the order it shows.
--
--   textselect.attach(pane, opts)    start, once. opts:
--       segments()   the shown conversation's texts in order:
--                    { { name, key, item, gap, prefix, inButton }, ... }
--                    key stays the same while the widget is redrawn under
--                    a new name; gap goes before it when copied after a
--                    text of the same item ("\n" or "\n\n"); prefix before
--                    it when copied from its start (a list's "- "); with
--                    inButton, a press on it selects though it's in a
--                    button (a step's details)
--       menu(item)   more right-click menu items for the item under the
--                    mouse ({ label, action }, ...)
--       drawAll()    draw every text first (Select all, in a long
--                    conversation that draws only what's near the view)
--   textselect.text()                the selected text ("" when none)
--   textselect.copy()                copy it; false when nothing is selected
--   textselect.selectAll() / clear()
--   textselect.refresh()             draw it again (after a layout)
--   textselect.touches(item)         whether the selection is in an item
--   textselect.boxes()               the boxes drawn: { { x, y, w, h } } (tests)
--   textselect.copyButton(name, parent, x, y, getText, tip)
--                                    a small Copy button

local C = require("core.palette")
local geometry = require("ui.geometry")

local textselect = {}

local BUTTON = 22             -- a Copy button's size
local SCROLL_EDGE = 24        -- dragging this near the pane's edge scrolls it
local SCROLL_EVERY = 30       -- ms between scroll steps while dragging there
local SCROLL_MOST = 40        -- the most it scrolls at a step

local WORD = "[%w_]"
local OBJECT = "\u{FFFC}"     -- what a picture shows as (gitgud.shownText)

local pane = nil
local opts = {}
local anchor = nil            -- { key, caret }: where the selection started
local focus = nil             -- { key, caret }: where it reaches
local dragging = false
local pressedOn = nil         -- the item a right press was over
local lastX, lastY = 0, 0
local scrollTimer = nil
local drawn = {}              -- text widget -> boxes drawn over it
local cache = {}              -- "name|from|to" -> rects, until a refresh
local copies = {}             -- Copy button -> { getText, what }
local dragged = nil           -- the texts, kept while a drag lasts

-- ===================================================================
-- Texts and characters
-- ===================================================================

local function chars(s)
    local out = {}
    for _, code in utf8.codes(s) do
        out[#out + 1] = utf8.char(code)
    end
    return out
end

local function length(seg)
    return utf8.len(gitgud.shownText(seg.name)) or 0
end

--- Characters from+1..to of a string (by character, not byte).
local function slice(s, from, to)
    if to <= from then
        return ""
    end
    local first = utf8.offset(s, from + 1) or (#s + 1)
    local after = utf8.offset(s, to + 1) or (#s + 1)
    return s:sub(first, after - 1)
end

local function segments()
    if dragged then
        return dragged
    end
    local list = opts.segments and opts.segments() or {}
    local shown = {}
    for _, seg in ipairs(list) do
        local _, _, w, h = gitgud.getRect(seg.name)
        if w and h > 0 and gitgud.getProperty(seg.name, "Visible") ~= "false" then
            shown[#shown + 1] = seg
        end
    end
    if dragging then
        dragged = shown
    end
    return shown
end

local function indexOf(segs, key)
    for i, seg in ipairs(segs) do
        if seg.key == key then
            return i
        end
    end
    return nil
end

--- The selection in text order: segments, its start and its end as
-- { i, caret }; nil when there's none (or it's empty).
local function ordered()
    if not anchor or not focus then
        return nil
    end
    local segs = segments()
    local ai, fi = indexOf(segs, anchor.key), indexOf(segs, focus.key)
    if not ai or not fi then
        return nil
    end
    local a = { i = ai, caret = anchor.caret }
    local b = { i = fi, caret = focus.caret }
    if b.i < a.i or (b.i == a.i and b.caret < a.caret) then
        a, b = b, a
    end
    if a.i == b.i and a.caret == b.caret then
        return nil
    end
    return segs, a, b
end

--- The text and caret at a point: the text level with it (the nearest
-- one across), else the first text below it (its start), else the end
-- of the last. Also whether the point is on the text itself.
local function hit(segs, x, y)
    local best, bestDx, below = nil, nil, nil
    for i, seg in ipairs(segs) do
        local sx, sy, sw, sh = gitgud.getRect(seg.name)
        if y >= sy and y < sy + sh then
            local dx = x < sx and sx - x or (x > sx + sw and x - sx - sw or 0)
            if not best or dx < bestDx then
                best, bestDx = i, dx
            end
        elseif y < sy and not below and not best then
            below = i
        end
    end
    if best then
        return best, gitgud.textIndexAt(segs[best].name, x, y) or 0, bestDx == 0
    end
    if below then
        return below, 0, false
    end
    if #segs == 0 then
        return nil
    end
    return #segs, length(segs[#segs]), false
end

-- ===================================================================
-- Drawing it
-- ===================================================================

local function rectsOf(name, from, to)
    local key = name .. "|" .. from .. "|" .. to
    if not cache[key] then
        cache[key] = gitgud.shownRects(name, from, to - 1)
    end
    return cache[key]
end

local function paint()
    local want = {}
    local segs, a, b = ordered()
    if segs then
        for i = a.i, b.i do
            local seg = segs[i]
            local from = i == a.i and a.caret or 0
            local to = i == b.i and b.caret or length(seg)
            if to > from then
                want[seg.name] = rectsOf(seg.name, from, to)
            end
        end
    end
    for name, count in pairs(drawn) do
        if not want[name] then
            for k = 1, count do
                if gitgud.getRect(name .. "Sel" .. k) then
                    gitgud.setVisible(name .. "Sel" .. k, false)
                end
            end
            drawn[name] = nil
        end
    end
    for name, rects in pairs(want) do
        for k, r in ipairs(rects) do
            local box = name .. "Sel" .. k
            if not gitgud.getRect(box) then
                gitgud.createWindow("Gitgud/StaticText", box, name)
                gitgud.setProperty(box, "PanelColour", C.textSelect)
                gitgud.setProperty(box, "CursorPassThroughEnabled", "true")
                gitgud.setText(box, "")
            end
            gitgud.setProperty(box, "Area", geometry.rect(math.floor(r[1]), math.floor(r[2]),
                math.ceil(r[3]) + 1, math.ceil(r[4])))
            gitgud.setVisible(box, true)
        end
        for k = #rects + 1, drawn[name] or 0 do
            if gitgud.getRect(name .. "Sel" .. k) then
                gitgud.setVisible(name .. "Sel" .. k, false)
            end
        end
        drawn[name] = math.max(#rects, drawn[name] or 0)
    end
end

--- Draw the selection again, where its texts are now.
function textselect.refresh()
    cache = {}
    dragged = nil
    paint()
end

function textselect.clear()
    anchor, focus = nil, nil
    paint()
end

-- ===================================================================
-- Words and paragraphs
-- ===================================================================

local function isWord(ch)
    return ch ~= nil and (#ch > 1 and ch ~= OBJECT or ch:match(WORD) ~= nil)
end

--- The word around a caret: its first and last-but-one carets.
local function wordAt(seg, caret)
    local cs = chars(gitgud.shownText(seg.name))
    -- The character under the mouse: after the caret, or before it when
    -- the press was on a word's right half.
    local at = caret + 1
    if not isWord(cs[at]) and isWord(cs[at - 1]) then
        at = at - 1
    end
    if not cs[at] then
        return caret, caret
    end
    if not isWord(cs[at]) then
        return at - 1, at
    end
    local first, last = at, at
    while isWord(cs[first - 1]) do
        first = first - 1
    end
    while isWord(cs[last + 1]) do
        last = last + 1
    end
    return first - 1, last
end

-- ===================================================================
-- The mouse
-- ===================================================================

local function stopScrolling()
    if scrollTimer then
        gitgud.cancelTimer(scrollTimer)
        scrollTimer = nil
    end
end

local function extendTo(x, y)
    local segs = segments()
    local i, caret = hit(segs, x, y)
    if i then
        focus = { key = segs[i].key, caret = caret }
        paint()
    end
end

--- While dragging past the pane's top or bottom, scroll it along.
local function scrollStep()
    if not dragging then
        stopScrolling()
        return
    end
    local _, py, _, ph = gitgud.getRect(pane)
    local delta = 0
    if lastY < py + SCROLL_EDGE then
        delta = -math.min(SCROLL_MOST, py + SCROLL_EDGE - lastY)
    elseif lastY > py + ph - SCROLL_EDGE then
        delta = math.min(SCROLL_MOST, lastY - (py + ph - SCROLL_EDGE))
    end
    if delta == 0 then
        stopScrolling()
        return
    end
    local top = math.max(0, math.min(gitgud.getScrollMax(pane), gitgud.getScroll(pane) + delta))
    gitgud.setScroll(pane, top)
    extendTo(lastX, lastY)
end

local function pressed(x, y, clicks, control)
    dragged = nil
    local segs = segments()
    local i, caret, onText = hit(segs, x, y)
    if control and not (i and onText and segs[i].inButton) then
        return -- a button's press, not ours
    end
    stopScrolling()
    -- The focus leaves the prompt box, so Ctrl+C copies this.
    gitgud.focus(pane)
    if not i then
        textselect.clear()
        return
    end
    local key = segs[i].key
    if clicks == 2 then
        local first, last = wordAt(segs[i], caret)
        anchor, focus = { key = key, caret = first }, { key = key, caret = last }
        dragging = false
    elseif clicks >= 3 then
        anchor, focus = { key = key, caret = 0 }, { key = key, caret = length(segs[i]) }
        dragging = false
    else
        anchor, focus = { key = key, caret = caret }, { key = key, caret = caret }
        dragging = true
    end
    paint()
end

--- The item whose text is under a point (its row, not just near it).
local function itemAt(x, y)
    local segs = segments()
    local i = hit(segs, x, y)
    local item = i and segs[i].item
    local ix, iy, iw, ih = gitgud.getRect(item and item.name or "")
    if not ix or x < ix or x > ix + iw or y < iy or y > iy + ih then
        return nil
    end
    return item
end

local function openMenu(x, y)
    local items = {
        { label = "Copy", shortcut = "ctrl+c", enabled = textselect.text() ~= "", action = function()
            textselect.copy()
        end },
    }
    for _, extra in ipairs(opts.menu and opts.menu(pressedOn) or {}) do
        items[#items + 1] = extra
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Select all", action = textselect.selectAll }
    require("ui.menu").popup(items, x, y)
end

local function numbers(value)
    local out = {}
    for n in tostring(value or ""):gmatch("-?%d+") do
        out[#out + 1] = tonumber(n)
    end
    return out
end

--- Start selecting in a pane (the transcript); see the header for opts.
function textselect.attach(name, options)
    pane = name
    opts = options or {}
    gitgud.watchPointer(pane)
    gitgud.on(pane .. ".pointerDown", function(value)
        local v = numbers(value)
        local x, y, button, clicks, control = v[1], v[2], v[3], v[4], v[5] == 1
        lastX, lastY = x, y
        if button == 3 then
            pressedOn = itemAt(x, y)
            return
        end
        pressed(x, y, clicks or 1, control)
    end)
    gitgud.on(pane .. ".pointerMoved", function(value)
        if not dragging then
            return
        end
        local v = numbers(value)
        lastX, lastY = v[1], v[2]
        extendTo(lastX, lastY)
        if not scrollTimer then
            local _, py, _, ph = gitgud.getRect(pane)
            if lastY < py + SCROLL_EDGE or lastY > py + ph - SCROLL_EDGE then
                scrollTimer = gitgud.every(SCROLL_EVERY, scrollStep)
            end
        end
    end)
    gitgud.on(pane .. ".pointerUp", function(value)
        local v = numbers(value)
        if v[3] == 3 then
            openMenu(v[1], v[2])
            return
        end
        dragging = false
        dragged = nil
        stopScrolling()
    end)
end

-- ===================================================================
-- What's selected
-- ===================================================================

function textselect.text()
    local segs, a, b = ordered()
    if not segs then
        return ""
    end
    local out = {}
    for i = a.i, b.i do
        local seg = segs[i]
        local from = i == a.i and a.caret or 0
        local to = i == b.i and b.caret or length(seg)
        local piece = slice(gitgud.shownText(seg.name), from, to):gsub(OBJECT, "")
        if from == 0 and seg.prefix and to > 0 then
            piece = seg.prefix .. piece
        end
        if i > a.i then
            out[#out + 1] = segs[i - 1].item == seg.item and (seg.gap or "\n") or "\n\n"
        end
        out[#out + 1] = piece
    end
    return table.concat(out)
end

--- Copy the selection to the clipboard. False when nothing is selected.
function textselect.copy()
    local s = textselect.text()
    if s == "" then
        return false
    end
    textselect.put(s)
    return true
end

--- Put text on the clipboard and say so.
function textselect.put(s, what)
    if gitgud.setClipboard(s) then
        require("core.status").info("Copied " .. (what or "") .. (what and " " or "") .. "to the clipboard.")
    else
        require("core.status").error("Could not copy to the clipboard.")
    end
end

--- Select all of the shown conversation's text.
function textselect.selectAll()
    -- A long conversation draws only what's near the view: all of it first.
    if opts.drawAll then
        opts.drawAll()
    end
    local segs = segments()
    if #segs == 0 then
        return
    end
    anchor = { key = segs[1].key, caret = 0 }
    focus = { key = segs[#segs].key, caret = length(segs[#segs]) }
    paint()
end

--- Whether some of an item's text is selected.
function textselect.touches(item)
    local segs, a, b = ordered()
    if not segs then
        return false
    end
    for i = a.i, b.i do
        if segs[i].item == item then
            return true
        end
    end
    return false
end

--- The boxes drawn now, on screen: { { x, y, width, height }, ... }.
function textselect.boxes()
    local out = {}
    for name, count in pairs(drawn) do
        for k = 1, count do
            local box = name .. "Sel" .. k
            if gitgud.getRect(box) and gitgud.getProperty(box, "Visible") == "true" then
                local x, y, w, h = gitgud.getRect(box)
                out[#out + 1] = { x, y, w, h }
            end
        end
    end
    return out
end

-- ===================================================================
-- Copy buttons
-- ===================================================================

--- A small Copy button (code blocks, messages). Returns its name.
-- @param getText  function() -> what it copies
-- @param what     what the status line says was copied ("the code")
function textselect.copyButton(name, parent, x, y, getText, tip, what)
    if not gitgud.getRect(name) then
        gitgud.createWindow("Bragi/Button8", name, parent)
        gitgud.setProperty(name, "Text", "")
        gitgud.setProperty(name, "NormalFillColour", C.transparent)
        gitgud.setProperty(name, "HoverFillColour", C.hover)
        gitgud.setProperty(name, "BorderColour", C.transparent)
        gitgud.createWindow("Gitgud/Icon", name .. "Icon", name)
        gitgud.setProperty(name .. "Icon", "Area", geometry.rect(3, 3, BUTTON - 6, BUTTON - 6))
        gitgud.setProperty(name .. "Icon", "IconImage", "Bragi-Icons/Copy")
        gitgud.setProperty(name .. "Icon", "IconColour", C.disabled)
        gitgud.setProperty(name .. "Icon", "GlowColour", "00000000")
        gitgud.setProperty(name .. "Icon", "CursorPassThroughEnabled", "true")
        gitgud.setCursor(name, "arrow") -- not the text's I-beam around it
    end
    if not copies[name] then
        gitgud.on(name .. ".clicked", function()
            local copy = copies[name]
            textselect.put(copy.getText(), copy.what)
        end)
    end
    copies[name] = { getText = getText, what = what }
    gitgud.setProperty(name, "TooltipText", tip or "Copy")
    gitgud.setProperty(name, "Area", geometry.rect(x, y, BUTTON, BUTTON))
    return name
end

textselect.BUTTON = BUTTON

return textselect
