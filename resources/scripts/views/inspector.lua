--- views/inspector.lua — file history and blame, over the content pane.
--
-- History   every commit that changed the file (left) and what that commit
--           did to it (right, a unified diff)
-- Blame     the file line by line, each run of lines labelled with the
--           commit, author, and age of its last change; newer changes are
--           brighter. Lines you haven't committed yet say so.
--
-- Open with a file's right-click menu (Changes, a commit's file list) or
-- the command palette; switch modes with the two buttons, Escape closes.
-- Click a commit (either mode) to find it in the graph; right-click for
-- "blame as of this commit" and more.
--
-- Public API: inspector.history(path), inspector.blame(path, revision)

local C = require("core.palette")
local content = require("views.content")
local diff = require("views.diff")
local menu = require("ui.menu")
local shell = require("core.shell")
local status = require("core.status")
local text = require("core.text")

local inspector = { name = "inspector" }

-- Blame ages, newest to oldest.
local AGE_COLOURS = { "FF7EF2D6", "FF6EDBFF", "FF7C93FF", "FFB06BFF", "FF766A9C" }

local path = nil
local mode = "history"
local revision = "workdir"   -- what blame shows
local commits = {}           -- history mode rows
local blameHunks = {}        -- blame mode: gutter row -> hunk

--- Paint the header and show one mode's lists.
local function paintMode()
    local history = mode == "history"

    gitgud.setVisible("InspectorCommitList", history)
    gitgud.setVisible("InspectorDiffList", history)
    gitgud.setVisible("BlameGutterList", not history)
    gitgud.setVisible("BlameCodeList", not history)
    gitgud.setProperty("InspectorHistoryTab", "NormalFillColour", history and C.bg4 or C.bg2)
    gitgud.setProperty("InspectorBlameTab", "NormalFillColour", history and C.bg2 or C.bg4)

    local what = history and "History of " or "Blame of "
    local suffix = ""
    if not history and revision ~= "workdir" then
        suffix = text.colour(C.dim, "   as of " .. revision:sub(1, 7))
    end
    gitgud.setText("InspectorTitle", text.colour(C.dim, what) .. text.colour(C.text, path) .. suffix)
end

--- "3d" / "5mo" / "2y": a short age.
-- @param timestamp  seconds since the epoch
-- @return short text
local function shortAge(timestamp)
    local seconds = math.max(0, os.time() - timestamp)
    local days = seconds / 86400
    if days < 1 then
        return math.floor(seconds / 3600) .. "h"
    end
    if days < 45 then
        return math.floor(days) .. "d"
    end
    if days < 365 then
        return math.floor(days / 30) .. "mo"
    end

    return math.floor(days / 365) .. "y"
end

--- Show one commit's change to the file.
-- @param i  1-based row in the commit list
local function showHistoryCommit(i)
    local commit = commits[i]
    if not commit then
        gitgud.setList("InspectorDiffList", {})
        return
    end

    local files, err = gitgud.commitDiff(commit.oid, { path = path, ignoreWhitespace = diff.ignoreWhitespace() })
    if not files then
        status.error(err or "Could not read that commit.")
        return
    end
    local fileDiff = files[1]
    if not fileDiff or #fileDiff.hunks == 0 then
        local note = fileDiff and fileDiff.binary and "Binary file changed." or "No text changes (mode or rename only)."
        gitgud.setList("InspectorDiffList", { text.colour(C.dim, "  " .. note) })
        return
    end
    gitgud.setList("InspectorDiffList", diff.unifiedRows(fileDiff))
    gitgud.setScroll("InspectorDiffList", 0)
end

--- Fill history mode.
local function loadHistory()
    local list, err = gitgud.fileLog(path, 500)
    if not list then
        status.error(err or "Could not read the file's history.")
        list = {}
    end
    commits = list

    local rows = {}
    for i, commit in ipairs(commits) do
        rows[i] = text.rowHeight(22) .. text.colour(C.text, commit.summary) .. "\n"
            .. text.colour(C.dim, commit.author .. " · " .. text.ago(commit.time) .. " · " .. commit.shortOid)
    end
    if #rows == 0 then
        rows[1] = text.colour(C.dim, "  No commits touch this file yet.")
    end
    gitgud.setList("InspectorCommitList", rows)

    if commits[1] then
        gitgud.selectListItem("InspectorCommitList", 1)
    end
    showHistoryCommit(1)
end

--- Colour for an age between the newest and oldest hunk.
-- @param time    the hunk's time
-- @param newest  newest time in the file
-- @param oldest  oldest time in the file
-- @return AARRGGBB
local function ageColour(time, newest, oldest)
    if newest <= oldest then
        return AGE_COLOURS[1]
    end

    local t = (newest - time) / (newest - oldest)
    local index = math.floor(t * (#AGE_COLOURS - 1) + 0.5) + 1

    return AGE_COLOURS[math.max(1, math.min(#AGE_COLOURS, index))]
end

--- Fill blame mode.
local function loadBlame()
    local result, err = gitgud.blame(path, revision)
    if not result then
        gitgud.setList("BlameGutterList", { text.colour(C.err, " " .. (err or "Blame failed.")) })
        gitgud.setList("BlameCodeList", {})
        return
    end

    local newest = 0
    local oldest = math.huge
    for _, hunk in ipairs(result.hunks) do
        if not hunk.uncommitted then
            newest = math.max(newest, hunk.time)
            oldest = math.min(oldest, hunk.time)
        end
    end

    local gutter = {}
    local code = {}
    blameHunks = {}
    local byLine = {}
    for index, hunk in ipairs(result.hunks) do
        for line = hunk.start, hunk.start + hunk.count - 1 do
            byLine[line] = { hunk = hunk, first = line == hunk.start, index = index }
        end
    end

    local width = #tostring(#result.lines)
    local _, _, codeWidth = gitgud.getRect("BlameCodeList")
    local columns = math.floor(((codeWidth or 800) - 24) / 7.2) - width - 3
    for _, line in ipairs(result.lines) do
        columns = math.max(columns, #line + 2)
    end
    columns = math.min(columns, 400)
    for n, line in ipairs(result.lines) do
        local info = byLine[n]
        local band = info and (info.index % 2 == 0) and "14FFFFFF" or "00000000"
        local label = ""
        if info and info.first then
            local hunk = info.hunk
            if hunk.uncommitted then
                label = text.colour(C.warn, " Not committed yet")
            else
                local author = hunk.author
                if #author > 14 then
                    author = author:sub(1, 13) .. "…"
                end
                label = text.colour(ageColour(hunk.time, newest, oldest),
                    string.format(" %s %-14s %4s", hunk.shortOid, author, shortAge(hunk.time)))
            end
        end
        gutter[n] = "[bg-colour='" .. band .. "']" .. (label ~= "" and label or " ") .. string.rep(" ", 40)
        blameHunks[n] = info and info.hunk or nil

        local stripe = info and info.hunk.uncommitted and "26FFCF6E" or band
        code[n] = "[bg-colour='" .. stripe .. "']"
            .. text.colour(C.disabled, string.format(" %" .. width .. "d  ", n))
            .. text.colour(C.text, (line:gsub("\t", "    ")))
            .. string.rep(" ", math.max(0, columns - #line))
    end
    if #code == 0 then
        gutter[1] = " "
        code[1] = text.colour(C.dim, "  (empty file)")
    end

    gitgud.setList("BlameGutterList", gutter)
    gitgud.setList("BlameCodeList", code)
    gitgud.setScroll("BlameCodeList", 0)
end

--- Open file history for a file.
-- @param file  repository-relative path
function inspector.history(file)
    path = file
    mode = "history"
    content.openOverlay("InspectorPanel")
    paintMode()
    loadHistory()
end

--- Open blame for a file.
-- @param file  repository-relative path
-- @param rev   "workdir" (default) or a commit id
function inspector.blame(file, rev)
    path = file
    mode = "blame"
    revision = rev or "workdir"
    content.openOverlay("InspectorPanel")
    paintMode()
    loadBlame()
end

--- Menu for a commit shown in either mode.
-- @param oid       commit id
-- @param shortOid  7-char id
-- @return item list
local function commitMenu(oid, shortOid)
    return {
        {
            label = "Show commit in graph",
            action = function()
                content.closeOverlay(true)
                require("views.graph").selectOid(oid)
            end,
        },
        {
            label = "Blame as of this commit",
            action = function()
                inspector.blame(path, oid)
            end,
        },
        {
            label = "Blame before this commit",
            action = function()
                inspector.blame(path, oid .. "^")
            end,
        },
        { separator = true },
        {
            label = "Copy SHA",
            action = function()
                shell.copy(oid, "SHA " .. shortOid)
            end,
        },
    }
end

--- Wire the panel.
function inspector.init()
    gitgud.linkScroll("BlameGutterList", "BlameCodeList")

    gitgud.on("InspectorHistoryTab.clicked", function()
        if path then
            inspector.history(path)
        end
    end)
    gitgud.on("InspectorBlameTab.clicked", function()
        if path then
            inspector.blame(path, revision)
        end
    end)
    gitgud.on("InspectorCloseButton.clicked", function()
        content.closeOverlay()
    end)

    gitgud.on("InspectorCommitList.selected", function(value)
        local row = tonumber(value)
        if row and row >= 0 then
            showHistoryCommit(row + 1)
        end
    end)
    gitgud.on("InspectorCommitList.rightClicked", function(value)
        local x, y, row = menu.parseClick(value)
        local commit = row and commits[row]
        if commit then
            gitgud.selectListItem("InspectorCommitList", row)
            showHistoryCommit(row)
            menu.popup(commitMenu(commit.oid, commit.shortOid), x, y)
        end
    end)

    for _, list in ipairs({ "BlameGutterList", "BlameCodeList" }) do
        gitgud.on(list .. ".rightClicked", function(value)
            local x, y, row = menu.parseClick(value)
            local hunk = row and blameHunks[row]
            if hunk and not hunk.uncommitted then
                menu.popup(commitMenu(hunk.oid, hunk.shortOid), x, y)
            end
        end)
        gitgud.on(list .. ".doubleClicked", function(value)
            local row = tonumber(value)
            local hunk = row and blameHunks[row + 1]
            if hunk and not hunk.uncommitted then
                content.closeOverlay(true)
                require("views.graph").selectOid(hunk.oid)
            end
        end)
    end

    gitgud.on("BlameGutterList.selected", function(value)
        local row = tonumber(value)
        local hunk = row and blameHunks[row + 1]
        if hunk then
            local who = hunk.uncommitted and "Not committed yet"
                or (hunk.shortOid .. "  " .. hunk.summary .. "  —  " .. hunk.author .. ", " .. text.ago(hunk.time))
            status.info(who .. (hunk.uncommitted and "" or "   (double-click to open the commit)"))
        end
    end)
end

return inspector
