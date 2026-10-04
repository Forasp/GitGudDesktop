--- depot/windows/timelapse.lua — the Time-lapse View window: a file at each of
-- its revisions, every line annotated with the revision that last changed it
-- (blame). Two shadings, as modes:
--   age        newer lines brighter, the oldest plain
--   changes    only the lines this revision changed
-- Drag the slider, use First / Prev / Next / Last, or Page Up / Page Down.
-- Double-click a line to open that revision's diff.
--
--     timelapse.open(path, startRevision?)

local C = require("core.palette")
local geometry = require("ui.geometry")
local selection = require("depot.selection")
local text = require("core.text")
local util = require("depot.util")
local windows = require("depot.windows")

local timelapse = {}

local ROW = 18
local THUMB = 14

--- Mix two AARRGGBB colours.
-- @param a  colour at t = 0
-- @param b  colour at t = 1
-- @param t  0..1
-- @return AARRGGBB
local function mix(a, b, t)
    local out = "FF"
    for i = 3, 7, 2 do
        local x = tonumber(a:sub(i, i + 1), 16)
        local y = tonumber(b:sub(i, i + 1), 16)
        out = out .. string.format("%02X", math.floor(x + (y - x) * t + 0.5))
    end

    return out
end

--- Place the slider thumb on the current revision.
-- @param state  window state
local function placeThumb(state)
    local id = state.id
    local x, _, width = gitgud.getRect(id .. ":SliderTrack")
    local rootX = gitgud.getRect(id .. ":Root") or 0
    if not x then
        return
    end
    local n = #state.revisions
    local t = n > 1 and (state.index - 1) / (n - 1) or 1
    local left = (x - rootX) + math.floor((width - THUMB) * t)
    gitgud.setProperty(id .. ":SliderThumb", "Area", geometry.rect(left, 8, THUMB, 24))
end

--- Show revision `index`.
-- @param state  window state
-- @param index  1-based (oldest first)
local function show(state, index)
    local id = state.id
    local n = #state.revisions
    if n == 0 then
        gitgud.setList(id .. ":Content", { text.colour(C.dim, "  This file has no submitted revisions yet.") })
        return
    end
    index = math.max(1, math.min(n, index))
    state.index = index
    local commit = state.revisions[index]

    state.blames[commit.oid] = state.blames[commit.oid] or gitgud.blame(state.path, commit.oid) or { lines = {}, hunks = {} }
    local blame = state.blames[commit.oid]

    local gutter, content = {}, {}
    state.lineOids = {}
    local pad = 0
    for _, line in ipairs(blame.lines) do
        pad = math.max(pad, #line:gsub("\t", "    "))
    end
    pad = math.min(pad, 300)

    for _, hunk in ipairs(blame.hunks) do
        local rev = state.indexOf[hunk.oid]
        local age = rev and (rev / index) or 0
        local tint
        if state.mode == "changes" then
            tint = hunk.oid == commit.oid and C.diffAdd or "00000000"
        else
            tint = mix(C.panel, "FF34796A", math.max(0, math.min(1, age)) ^ 2 * 0.85)
        end
        for k = 0, hunk.count - 1 do
            local lineNo = hunk.start + k
            local lineText = (blame.lines[lineNo] or ""):gsub("[\r\n]+$", ""):gsub("\t", "    ")
            local label = ""
            if k == 0 then
                label = text.colour(C.text, rev and ("#" .. rev) or "?") .. "  "
                    .. text.colour(C.text2, hunk.shortOid .. "  " .. hunk.author) .. "  "
                    .. text.colour(C.dim, util.date(hunk.time))
            end
            gutter[lineNo] = text.rowHeight(ROW) .. " " .. label
            content[lineNo] = text.rowHeight(ROW) .. "[bg-colour='00000000'][colour='" .. C.dim .. "']"
                .. string.format("%5d ", lineNo) .. "[bg-colour='" .. tint .. "'][colour='" .. C.text .. "'] "
                .. text.escape(lineText) .. string.rep(" ", math.max(0, pad - #lineText))
            state.lineOids[lineNo] = hunk.oid
        end
    end
    for i = 1, #blame.lines do
        gutter[i] = gutter[i] or text.rowHeight(ROW)
        content[i] = content[i] or text.rowHeight(ROW)
    end
    gitgud.setList(id .. ":Gutter", gutter)
    gitgud.setList(id .. ":Content", content)

    gitgud.setText(id .. ":Info", text.colour(C.text, "Revision #" .. index .. " of " .. n .. "   ")
        .. text.colour(C.text2, util.change(commit.oid) .. "   " .. commit.author .. "   " .. util.dateTime(commit.time))
        .. text.colour(C.dim, "   " .. util.summary(commit.summary)))
    gitgud.setText(id .. ":Description", commit.message)
    gitgud.setText(id .. ":ModeButton", state.mode == "changes" and "Show: this revision's changes"
        or "Show: line age")
    placeThumb(state)
end

--- Open a Time-lapse View window.
-- @param path   file
-- @param start  revision to show first (default: the latest)
-- @return window id
function timelapse.open(path, start)
    local log = gitgud.fileLog(path, 300) or {}
    local revisions = {}
    for i = #log, 1, -1 do
        revisions[#revisions + 1] = log[i]
    end
    local id = windows.open("timelapse", "Time-lapse View: " .. selection.depotPath(path), "windows/timelapse.xml", 1180, 780)
    if not id then
        return nil
    end
    local state = { id = id, path = path, revisions = revisions, indexOf = {}, blames = {}, mode = "age", index = #revisions }
    for i, commit in ipairs(revisions) do
        state.indexOf[commit.oid] = i
        if start and (commit.oid == start or commit.oid:sub(1, #start) == start) then
            state.index = i
        end
    end

    gitgud.linkScroll(id .. ":Gutter", id .. ":Content")
    gitgud.on(id .. ":FirstButton.clicked", function()
        show(state, 1)
    end)
    gitgud.on(id .. ":PrevButton.clicked", function()
        show(state, state.index - 1)
    end)
    gitgud.on(id .. ":NextButton.clicked", function()
        show(state, state.index + 1)
    end)
    gitgud.on(id .. ":LastButton.clicked", function()
        show(state, #state.revisions)
    end)
    gitgud.on(id .. ":ModeButton.clicked", function()
        state.mode = state.mode == "age" and "changes" or "age"
        show(state, state.index)
    end)

    gitgud.setDraggable(id .. ":SliderThumb", true, "horizontal")
    gitgud.on(id .. ":SliderThumb.dragging", function(value)
        local x = tonumber(value:match("^(-?%d+)"))
        local tx, _, tw = gitgud.getRect(id .. ":SliderTrack")
        if not x or not tx or #state.revisions < 2 then
            return
        end
        local t = math.max(0, math.min(1, (x - tx - THUMB / 2) / (tw - THUMB)))
        local index = 1 + math.floor(t * (#state.revisions - 1) + 0.5)
        if index ~= state.index then
            show(state, index)
        end
    end)
    gitgud.on(id .. ":SliderThumb.dragEnded", function()
        placeThumb(state)
    end)

    gitgud.on(id .. ":Content.doubleClicked", function(value)
        local line = (tonumber(value) or -1) + 1
        local oid = state.lineOids and state.lineOids[line]
        if oid and not oid:match("^0+$") then
            windows.diffRevisions(path, oid .. "^", path, oid)
        end
    end)

    windows.onKey(id, function(combo)
        if combo == "escape" then
            windows.close(id)
        elseif combo == "pageup" or combo == "ctrl+left" then
            show(state, state.index - 1)
        elseif combo == "pagedown" or combo == "ctrl+right" then
            show(state, state.index + 1)
        elseif combo == "ctrl+home" then
            show(state, 1)
        elseif combo == "ctrl+end" then
            show(state, #state.revisions)
        end
    end)
    gitgud.on("window.popOutResized", function(detail)
        if detail:match("^([^|]+)") == id then
            placeThumb(state)
        end
    end)

    show(state, state.index)
    return id
end

return timelapse
