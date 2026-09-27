--- views/diff.lua — renders a text diff into the diff lists.
--
-- Two display modes (View menu / "View ▾" button, remembered in settings):
--   split    DiffListOld | HunkGutter | DiffListNew — removed lines on the
--            left, added lines on the right, changed lines paired up
--   unified  DiffListUnified — one column with both line numbers
--
-- When the diff is of the working tree, lines are toggleable: click a
-- changed row to include/exclude it in the next commit (in split view a row
-- pairing a removal with an addition toggles both; unified view toggles
-- single lines). Every block of consecutive changed lines has its own small
-- box (in the split view's middle gutter, or at the start of the block's
-- first row in unified view), and each hunk header a big one for the whole
-- hunk. Included lines get a solid neon line-number gutter; excluded ones
-- keep a plain one.
--
-- Lines are identified by their 1-based position in the flattened list of
-- every hunk's lines — the same indexing gitgud.stagedLines /
-- setStagedLines use, so toggles map straight onto the engine.
--
-- A removed line paired with the added line that replaced it gets word-level
-- highlighting (core/worddiff.lua): the words that actually changed are
-- tinted more strongly. View > Highlight changed words turns it off.
--
-- Public API (used by views/content.lua and the menus):
--   diff.render(fileDiff, staging)   staging = nil (read-only) or
--                                    { staged = {[idx]=true}, onChange = fn(list) }
--   diff.clear()                     diff.lineCount(fileDiff)
--   diff.mode() / diff.setMode(m)    diff.ignoreWhitespace() / diff.setIgnoreWhitespace(b)
--   diff.wordDiff() / diff.setWordDiff(b)   diff.unifiedRows(fileDiff)

local C = require("core.palette")
local app = require("core.app")
local geometry = require("ui.geometry")
local settings = require("core.settings")
local text = require("core.text")
local worddiff = require("core.worddiff")

local diff = { name = "diff" }

local GUTTER_WIDTH = 44
-- Spacers that centre the toggles in the gutter (the list pads its rows by
-- about 6px on the left): 26px hunk boxes and 16px block boxes.
local HUNK_BOX_INDENT = "[image-size='w:3 h:1'][image='Gitgud-Images/Spacer']"
local BLOCK_BOX_INDENT = "[image-size='w:8 h:1'][image='Gitgud-Images/Spacer']"
-- Unified view: the column the block boxes sit in.
local UNIFIED_BOX_COLUMN = 24
local MAX_PAD = 240
local CHAR_WIDTH = 7.2        -- JetBrains Mono at 12px

-- Row tints (translucent over the list background).
local TINT_ADD = "265EF2A6"
local TINT_DEL = "26FF5EC4"
-- The words that changed inside a paired line.
local WORD_ADD = "665EF2A6"
local WORD_DEL = "70FF5EC4"
-- Line-number gutter of an included line (solid) / excluded line (none).
local GUTTER_ADD = "FF2E8A6E"
local GUTTER_DEL = "FF9A3A7C"

local current = nil       -- { rows, staging, hunks, pad, rowsOfIndex, unified }

--- Replace tabs, strip line terminators.
-- @param s  raw line content
-- @return display text
local function expand(s)
    return (s:gsub("[\r\n]+$", ""):gsub("\t", "    "))
end

--- Right-pad to the widest line so row tints form a solid block.
-- @param s  display text
-- @return padded text
local function pad(s)
    if #s < current.pad then
        return s .. string.rep(" ", current.pad - #s)
    end

    return s
end

--- Is flat line `idx` included in the next commit?
-- @param idx  flat line index
-- @return boolean
local function isStaged(idx)
    return current.staging ~= nil and current.staging.staged[idx] == true
end

--- "On", "Off", or "Part": how much of a set of lines is included.
-- @param changes  flat indices
-- @return state suffix for the sprite names
local function inclusion(changes)
    local included = 0
    for _, idx in ipairs(changes) do
        if isStaged(idx) then
            included = included + 1
        end
    end

    if included == #changes and included > 0 then
        return "On"
    end
    if included > 0 then
        return "Part"
    end

    return "Off"
end

--- The toggle sprite for a hunk: on / off / partially included.
-- @param hunk  row-model hunk ({ changes = {idx...} })
-- @return an [image=...] markup string
local function hunkSprite(hunk)
    return "[vert-formatting='CentreAligned'][image-size='w:26 h:26'][image='Gitgud-Images/Hunk"
        .. inclusion(hunk.changes) .. "']"
end

--- The line-height toggle sprite for one block of changed lines.
-- @param block  row-model block ({ changes = {idx...} })
-- @return an [image=...] markup string
local function blockSprite(block)
    return "[vert-formatting='CentreAligned'][image-size='w:16 h:16'][image='Gitgud-Images/Block"
        .. inclusion(block.changes) .. "']"
end

--- A hunk header row: dim blue "@@ ... @@" text, 26px tall to match the
-- gutter sprite so all three lists stay row-aligned.
-- @param header  the hunk's header line (or "" for a blank twin)
-- @return markup
local function headerText(header)
    return "[vert-formatting='CentreAligned'][image-size='w:1 h:26'][image='Gitgud-Images/Spacer']"
        .. text.colour(C.blue, expand(header))
end

--- Line-number cell + marker for one side of a line.
-- @param number  line number (or -1/nil for none)
-- @param origin  "+", "-", or " "
-- @param idx     flat index (for staging state)
-- @return markup for the gutter cell
local function numberCell(number, origin, idx)
    local label = string.format(" %5s ", (number and number > 0) and tostring(number) or "")
    local changed = origin == "+" or origin == "-"

    if changed and current.staging then
        if isStaged(idx) then
            local fill = origin == "+" and GUTTER_ADD or GUTTER_DEL
            return "[bg-colour='" .. fill .. "'][colour='" .. C.text .. "']" .. label
        end
        return "[bg-colour='00000000'][colour='" .. C.dim .. "']" .. label
    end

    return "[bg-colour='00000000'][colour='" .. C.dim .. "']" .. label
end

--- Word segments of a changed line against its partner (cached on the
-- entry), or nil.
-- @param entry  row-model entry { line, partner }
-- @return array of { text, changed } or nil
local function wordSegments(entry)
    if not entry or not entry.partner or not diff.wordDiff() then
        return nil
    end
    if entry.words == nil then
        local mine = expand(entry.line.content)
        local theirs = expand(entry.partner.line.content)
        local oldSegs = nil
        local newSegs = nil
        if entry.line.origin == "-" then
            oldSegs, newSegs = worddiff.segments(mine, theirs)
            entry.words = oldSegs or false
            entry.partner.words = newSegs or false
        else
            oldSegs, newSegs = worddiff.segments(theirs, mine)
            entry.words = newSegs or false
            entry.partner.words = oldSegs or false
        end
    end

    return entry.words or nil
end

--- The text part of a line: marker + content, tinted for changes.
-- @param line   diff line table
-- @param entry  optional row-model entry (for word highlighting)
-- @return markup
local function lineBody(line, entry)
    local origin = line.origin
    local tint = "00000000"
    local colour = C.text2

    if origin == "+" then
        tint = TINT_ADD
        colour = C.text
    elseif origin == "-" then
        tint = TINT_DEL
        colour = C.text
    end

    local markerColour = origin == "+" and C.add or (origin == "-" and C.del or C.dim)
    local prefix = "[bg-colour='" .. tint .. "'][colour='" .. markerColour .. "'] " .. origin .. " "
        .. "[colour='" .. colour .. "']"

    local segments = wordSegments(entry)
    if not segments then
        return prefix .. text.escape(pad(expand(line.content)))
    end

    local strong = origin == "+" and WORD_ADD or WORD_DEL
    local body = ""
    local length = 0
    for _, segment in ipairs(segments) do
        body = body .. "[bg-colour='" .. (segment.changed and strong or tint) .. "']" .. text.escape(segment.text)
        length = length + #segment.text
    end
    if length < current.pad then
        body = body .. "[bg-colour='" .. tint .. "']" .. string.rep(" ", current.pad - length)
    end

    return prefix .. body
end

--- A blank half for a row that only has content on the other side.
-- @return markup of the right width
local function blankHalf()
    return "[bg-colour='00000000']" .. string.rep(" ", current.pad + 10)
end

--- Render one split row's left and right halves.
-- @param row  split row
-- @return leftMarkup, rightMarkup
local function splitTexts(row)
    if row.kind == "header" then
        return headerText(row.hunk.header), headerText("")
    end

    local left = blankHalf()
    local right = blankHalf()
    if row.left then
        left = numberCell(row.left.line.oldLineno, row.left.line.origin, row.left.idx)
            .. lineBody(row.left.line, row.left)
    end
    if row.right then
        right = numberCell(row.right.line.newLineno, row.right.line.origin, row.right.idx)
            .. lineBody(row.right.line, row.right)
    end

    return left, right
end

--- Render one unified row.
-- @param row  unified row
-- @return markup
local function unifiedText(row)
    if row.kind == "header" then
        local sprite = current.staging and hunkSprite(row.hunk) or ""
        return sprite .. " " .. headerText(row.hunk.header)
    end

    local line = row.entry.line
    local idx = row.entry.idx
    local box = ""
    if current.staging then
        local block = row.entry.block
        if block and block.unifiedRow == row.index then
            box = blockSprite(block) .. "[image-size='w:8 h:1'][image='Gitgud-Images/Spacer']"
        else
            box = "[image-size='w:24 h:1'][image='Gitgud-Images/Spacer']"
        end
    end

    return box .. numberCell(line.oldLineno, line.origin, idx)
        .. "[bg-colour='00000000']" .. numberCell(line.newLineno, line.origin, idx)
        .. lineBody(line, row.entry)
end

--- The gutter cell of a split row: the hunk's box on its header row, a
-- block's box on the block's first row.
-- @param row  split row
-- @return markup
local function gutterText(row)
    if row.kind == "header" and current.staging then
        return HUNK_BOX_INDENT .. hunkSprite(row.hunk)
    end
    if row.kind == "header" then
        return "[image-size='w:1 h:26'][image='Gitgud-Images/Spacer']"
    end
    if current.staging and row.block and row.block.splitRow == row.index then
        return BLOCK_BOX_INDENT .. blockSprite(row.block)
    end

    return " "
end

--- How many text columns fit in a diff half (or the unified list), so row
-- tints run the full width even when every line is short.
-- @return column count
local function visibleColumns()
    local list = diff.mode() == "unified" and "DiffListUnified" or "DiffListNew"
    local _, _, width = gitgud.getRect(list)
    if not width then
        return 0
    end

    local gutter = diff.mode() == "unified" and 22 or 11
    return math.max(0, math.floor((width - 24) / CHAR_WIDTH) - gutter)
end

--- Build the row models (split + unified) for a diff.
-- @param fileDiff  a gitgud diff table
-- @return model table
local function buildModel(fileDiff)
    local model = {
        split = {},
        unified = {},
        hunks = {},
        blocks = {},
        pad = 0,
        rowsOfIndex = {},   -- flat idx -> { split = rowNo, unified = rowNo }
        blockOfIndex = {},  -- flat idx -> block { changes, splitRow, unifiedRow }
    }

    local idx = 0
    for _, hunk in ipairs(fileDiff.hunks) do
        for _, line in ipairs(hunk.lines) do
            model.pad = math.max(model.pad, #expand(line.content))
        end
    end
    model.pad = math.min(math.max(model.pad, visibleColumns()), MAX_PAD)

    for _, hunk in ipairs(fileDiff.hunks) do
        local h = { header = hunk.header, changes = {}, splitRow = 0, unifiedRow = 0 }
        model.hunks[#model.hunks + 1] = h

        model.split[#model.split + 1] = { kind = "header", hunk = h }
        h.splitRow = #model.split
        model.unified[#model.unified + 1] = { kind = "header", hunk = h }
        h.unifiedRow = #model.unified

        local dels = {}
        local adds = {}
        local block = nil   -- the run of changed lines being collected

        --- Pair up pending removals/additions into split rows.
        local function flush()
            for i = 1, math.min(#dels, #adds) do
                dels[i].partner = adds[i]
                adds[i].partner = dels[i]
            end
            for i = 1, math.max(#dels, #adds) do
                local row = { kind = "change", left = dels[i], right = adds[i], hunk = h, block = block }
                model.split[#model.split + 1] = row
                row.index = #model.split
                if block and not block.splitRow then
                    block.splitRow = #model.split
                end
                if dels[i] then
                    model.rowsOfIndex[dels[i].idx].split = #model.split
                end
                if adds[i] then
                    model.rowsOfIndex[adds[i].idx].split = #model.split
                end
            end
            dels = {}
            adds = {}
        end

        for _, line in ipairs(hunk.lines) do
            idx = idx + 1
            local entry = { line = line, idx = idx }
            local origin = line.origin

            if origin == "+" or origin == "-" then
                if not block then
                    block = { changes = {}, unifiedRow = #model.unified + 1 }
                    model.blocks[#model.blocks + 1] = block
                end
                block.changes[#block.changes + 1] = idx
                entry.block = block
                model.blockOfIndex[idx] = block
            end

            if origin == "+" or origin == "-" or origin == " " then
                model.rowsOfIndex[idx] = {}
                model.unified[#model.unified + 1] = { kind = "line", entry = entry, hunk = h, index = #model.unified + 1 }
                model.rowsOfIndex[idx].unified = #model.unified
            end

            if origin == "-" then
                dels[#dels + 1] = entry
                h.changes[#h.changes + 1] = idx
            elseif origin == "+" then
                adds[#adds + 1] = entry
                h.changes[#h.changes + 1] = idx
            elseif origin == " " then
                flush()
                block = nil
                model.split[#model.split + 1] = { kind = "context", left = entry, right = entry, hunk = h,
                    index = #model.split + 1 }
                model.rowsOfIndex[idx].split = #model.split
            end
            -- EOF-newline markers ("=", ">", "<") aren't displayed, but they
            -- still occupy a flat index so numbering matches the engine.
        end
        flush()
        block = nil
    end

    return model
end

--- Place the three split lists (with or without the staging gutter).
-- @param withGutter  show the hunk toggle column
local function placeSplit(withGutter)
    local half = withGutter and GUTTER_WIDTH / 2 or 0

    gitgud.setProperty("DiffListOld", "Area", geometry.area(0, 0, 0, 0, 0.5, -half, 1, 0))
    gitgud.setProperty("HunkGutter", "Area", geometry.area(0.5, -half, 0, 0, 0.5, half, 1, 0))
    gitgud.setProperty("DiffListNew", "Area", geometry.area(0.5, half + 1, 0, 0, 1, 0, 1, 0))
    gitgud.setVisible("HunkGutter", withGutter)
end

--- Show the lists for the current mode, hide the others.
local function showMode()
    local unified = diff.mode() == "unified"

    gitgud.setVisible("DiffListOld", not unified)
    gitgud.setVisible("DiffListNew", not unified)
    gitgud.setVisible("DiffListUnified", unified)
    if unified then
        gitgud.setVisible("HunkGutter", false)
    else
        placeSplit(current ~= nil and current.staging ~= nil)
    end
end

--- Fill the lists from the current model.
local function fillLists()
    if diff.mode() == "unified" then
        local rows = {}
        for i, row in ipairs(current.unified) do
            rows[i] = unifiedText(row)
        end
        gitgud.setList("DiffListUnified", rows)
        return
    end

    local left = {}
    local right = {}
    local gutter = {}
    for i, row in ipairs(current.split) do
        left[i], right[i] = splitTexts(row)
        gutter[i] = gutterText(row)
    end
    gitgud.setList("DiffListOld", left)
    gitgud.setList("DiffListNew", right)
    gitgud.setList("HunkGutter", gutter)
end

--- Re-render just the rows showing the given flat indices (and their hunk
-- headers) — keeps scroll position and is O(changed rows).
-- @param indices  array of flat indices
local function refreshRows(indices)
    local unified = diff.mode() == "unified"
    local hunksTouched = {}
    local blocksTouched = {}

    for _, idx in ipairs(indices) do
        if current.blockOfIndex[idx] then
            blocksTouched[current.blockOfIndex[idx]] = true
        end
        local where = current.rowsOfIndex[idx]
        if where then
            if unified and where.unified then
                local row = current.unified[where.unified]
                gitgud.setListItem("DiffListUnified", where.unified, unifiedText(row))
                hunksTouched[row.hunk] = true
            elseif not unified and where.split then
                local row = current.split[where.split]
                local left, right = splitTexts(row)
                gitgud.setListItem("DiffListOld", where.split, left)
                gitgud.setListItem("DiffListNew", where.split, right)
                hunksTouched[row.hunk] = true
            end
        end
    end

    for hunk, _ in pairs(hunksTouched) do
        if unified then
            gitgud.setListItem("DiffListUnified", hunk.unifiedRow, unifiedText(current.unified[hunk.unifiedRow]))
        else
            gitgud.setListItem("HunkGutter", hunk.splitRow, gutterText(current.split[hunk.splitRow]))
        end
    end

    for block, _ in pairs(blocksTouched) do
        if unified then
            gitgud.setListItem("DiffListUnified", block.unifiedRow, unifiedText(current.unified[block.unifiedRow]))
        elseif block.splitRow then
            gitgud.setListItem("HunkGutter", block.splitRow, gutterText(current.split[block.splitRow]))
        end
    end
end

--- Flip the inclusion of some lines and tell the owner.
-- @param indices  flat indices to toggle together
local function toggle(indices)
    if not current or not current.staging or #indices == 0 then
        return
    end

    -- A mixed set (a partially included hunk) becomes fully included.
    local include = false
    for _, idx in ipairs(indices) do
        if not isStaged(idx) then
            include = true
        end
    end

    for _, idx in ipairs(indices) do
        current.staging.staged[idx] = include or nil
    end
    refreshRows(indices)

    local list = {}
    for idx, _ in pairs(current.staging.staged) do
        list[#list + 1] = idx
    end
    table.sort(list)
    current.staging.onChange(list)
end

--- Handle a click on row `row` (1-based) of a list.
-- @param list    "old" | "new" | "gutter" | "unified"
-- @param row     1-based row number
-- @param inBox   unified view: the click landed in the block-box column
local function onRowClicked(list, row, inBox)
    if not current or not current.staging then
        return
    end

    if list == "unified" then
        local r = current.unified[row]
        if not r then
            return
        end
        local block = r.kind == "line" and r.entry.block
        if r.kind == "header" then
            toggle(r.hunk.changes)
        elseif inBox and block and block.unifiedRow == row then
            toggle(block.changes)
        elseif r.entry.line.origin ~= " " then
            toggle({ r.entry.idx })
        end
        return
    end

    local r = current.split[row]
    if not r then
        return
    end
    if r.kind == "header" then
        toggle(r.hunk.changes)
        return
    end
    if list == "gutter" then
        -- Anywhere beside a block toggles that block.
        if r.block then
            toggle(r.block.changes)
        end
        return
    end

    -- A row pairing a removal with an addition is one modification: toggle
    -- both halves together (unified view gives per-line precision).
    local indices = {}
    for _, entry in ipairs({ r.left, r.right }) do
        if entry and entry.line.origin ~= " " then
            indices[#indices + 1] = entry.idx
        end
    end
    toggle(indices)
end

--- Number of flat lines in a diff (what setStagedLines expects).
-- @param fileDiff  a gitgud diff table
-- @return count
function diff.lineCount(fileDiff)
    local n = 0
    for _, hunk in ipairs(fileDiff.hunks) do
        n = n + #hunk.lines
    end

    return n
end

--- Count added and removed lines.
-- @param fileDiff  a gitgud diff table
-- @return added, removed
function diff.stats(fileDiff)
    local added = 0
    local removed = 0

    for _, hunk in ipairs(fileDiff.hunks) do
        for _, line in ipairs(hunk.lines) do
            if line.origin == "+" then
                added = added + 1
            elseif line.origin == "-" then
                removed = removed + 1
            end
        end
    end

    return added, removed
end

--- Show a diff.
-- @param fileDiff  a gitgud diff table (hunks -> lines)
-- @param staging   nil for read-only, or { staged = {[idx]=true},
--                  onChange = function(sortedIndexList) }
function diff.render(fileDiff, staging)
    current = buildModel(fileDiff)
    current.staging = staging

    showMode()
    fillLists()
end

--- Unified-diff rows for any list (the file history view uses this), styled
-- like the main diff but read-only.
-- @param fileDiff  a gitgud diff table
-- @return array of row markup
function diff.unifiedRows(fileDiff)
    local saved = current
    current = buildModel(fileDiff)
    current.staging = nil

    local rows = {}
    for i, row in ipairs(current.unified) do
        rows[i] = unifiedText(row)
    end

    current = saved
    return rows
end

--- Scroll every diff list back to the top (showing a different file).
function diff.scrollToTop()
    gitgud.setScroll("DiffListOld", 0)
    gitgud.setScroll("DiffListNew", 0)
    gitgud.setScroll("HunkGutter", 0)
    gitgud.setScroll("DiffListUnified", 0)
end

--- Empty the lists (e.g. before showing an empty state).
function diff.clear()
    current = nil
    gitgud.setList("DiffListOld", {})
    gitgud.setList("DiffListNew", {})
    gitgud.setList("HunkGutter", {})
    gitgud.setList("DiffListUnified", {})
end

--- Show or hide every text-diff list at once.
-- @param visible  boolean
function diff.setVisible(visible)
    if visible then
        showMode()
        return
    end

    gitgud.setVisible("DiffListOld", false)
    gitgud.setVisible("DiffListNew", false)
    gitgud.setVisible("HunkGutter", false)
    gitgud.setVisible("DiffListUnified", false)
end

--- "split" or "unified".
-- @return the display mode
function diff.mode()
    return settings.get("diffMode", "split")
end

--- Switch display mode (re-renders the current diff).
-- @param mode  "split" | "unified"
function diff.setMode(mode)
    settings.set("diffMode", mode)

    if current then
        showMode()
        fillLists()
    end
end

--- Whether changed words inside a line are highlighted.
-- @return boolean
function diff.wordDiff()
    return settings.get("wordDiff", true)
end

--- Turn word highlighting on or off (re-renders the current diff).
-- @param on  boolean
function diff.setWordDiff(on)
    settings.set("wordDiff", on)
    if current then
        fillLists()
    end
end

--- Whether whitespace-only changes are hidden.
-- @return boolean
function diff.ignoreWhitespace()
    return settings.get("hideWhitespace", false)
end

--- Hide or show whitespace-only changes (the owner re-queries the diff).
-- @param hide  boolean
function diff.setIgnoreWhitespace(hide)
    settings.set("hideWhitespace", hide)
    app.publish("diff.optionsChanged")
end

--- Diff options for gitgud.diff / gitgud.commitDiff.
-- @return options table
function diff.queryOptions()
    return { ignoreWhitespace = diff.ignoreWhitespace() }
end

--- Wire list clicks and scroll linking.
function diff.init()
    local lists = {
        { name = "DiffListOld", kind = "old" },
        { name = "DiffListNew", kind = "new" },
        { name = "HunkGutter", kind = "gutter" },
        { name = "DiffListUnified", kind = "unified" },
    }

    for _, list in ipairs(lists) do
        gitgud.on(list.name .. ".selected", function(value)
            local row = tonumber(value)
            if row and row >= 0 then
                -- Clear the selection so clicking the same row again fires.
                gitgud.selectListItem(list.name, nil)
                if list.kind ~= "unified" then
                    onRowClicked(list.kind, row + 1)
                end
            end
        end)
    end

    -- Unified rows need the click position: the block box sits at the start
    -- of a block's first row, and the rest of the row toggles one line.
    gitgud.on("DiffListUnified.clicked", function(value)
        local x, _, row = require("ui.menu").parseClick(value)
        if not row then
            return
        end
        local listX = gitgud.getRect("DiffListUnified")
        onRowClicked("unified", row, listX and (x - listX) < UNIFIED_BOX_COLUMN + 6)
    end)

    -- Keep the split halves and the gutter vertically in step. Every pair is
    -- linked directly: the mirror handlers have a reentrancy guard, so
    -- chained propagation would stop after one hop.
    gitgud.linkScroll("DiffListOld", "DiffListNew")
    gitgud.linkScroll("DiffListOld", "HunkGutter")
    gitgud.linkScroll("DiffListNew", "HunkGutter")
end

return diff
