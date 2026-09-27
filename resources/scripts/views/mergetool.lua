--- views/mergetool.lua — the 3-pane conflict resolver.
--
-- Opens over the content pane for a conflicted file (click it in Changes,
-- "Open merge tool" in its menu, or the banner during a merge/rebase):
--
--   MINE (left)      your side, the checked-out branch
--   THEIRS (right)   the incoming side
--   RESULT (bottom)  what the file will contain
--
-- Text both sides agree on is already merged. For every conflict, click the
-- block on the left and/or right to take it (both = both, in the order you
-- clicked; click again to drop it). "All mine" / "All theirs" decide every
-- conflict at once, and "Edit result" turns the bottom pane into an editor
-- for anything else. "Save and mark resolved" writes the file and stages it.
--
-- Binary files and "changed here, deleted there" can't be merged by line:
-- then the tool offers keeping one side.
--
-- Public API: mergetool.open(path), mergetool.close()

local C = require("core.palette")
local app = require("core.app")
local content = require("views.content")
local dialog = require("ui.dialog")
local menu = require("ui.menu")
local repo = require("core.repo")
local status = require("core.status")
local text = require("core.text")

local mergetool = { name = "mergetool" }

local MAX_PAD = 200

local file = nil          -- gitgud.readConflict() result
local choices = {}        -- chunk index -> { "ours" | "theirs", ... }
local oursRows = {}       -- MergeOursList row -> chunk index (conflicts only)
local theirsRows = {}     -- MergeTheirsList row -> chunk index
local chunkRow = {}       -- chunk index -> first row in the top panes
local outputRows = {}     -- MergeOutputList row -> chunk index
local editing = false
local focusConflict = 0   -- the conflict Prev/Next last moved to

--- Tabs to spaces, no line terminators.
-- @param s  raw line
-- @return display text
local function clean(s)
    return (s:gsub("\r$", ""):gsub("\t", "    "))
end

--- Right-pad so tinted rows form solid blocks.
-- @param s      display text
-- @param width  columns
-- @return padded text
local function padTo(s, width)
    if #s < width then
        return s .. string.rep(" ", width - #s)
    end

    return s
end

--- Indices of the conflict chunks.
-- @return array of chunk indices
local function conflictIndices()
    local out = {}
    for i, chunk in ipairs(file.chunks) do
        if chunk.conflict then
            out[#out + 1] = i
        end
    end

    return out
end

--- Has a side been taken for chunk i?
-- @param i     chunk index
-- @param side  "ours" | "theirs"
-- @return boolean
local function taken(i, side)
    for _, choice in ipairs(choices[i] or {}) do
        if choice == side then
            return true
        end
    end

    return false
end

--- Conflicts still undecided.
-- @return count
local function unresolved()
    local n = 0
    for _, i in ipairs(conflictIndices()) do
        if #(choices[i] or {}) == 0 then
            n = n + 1
        end
    end

    return n
end

--- The result's lines (unresolved conflicts become standard markers).
-- @param withMarkers  write <<<<<<< markers for undecided conflicts
-- @return array of lines
local function resultLines(withMarkers)
    local out = {}
    for i, chunk in ipairs(file.chunks) do
        if not chunk.conflict then
            for _, line in ipairs(chunk.lines) do
                out[#out + 1] = line
            end
        elseif #(choices[i] or {}) > 0 then
            for _, side in ipairs(choices[i]) do
                for _, line in ipairs(chunk[side]) do
                    out[#out + 1] = line
                end
            end
        elseif withMarkers then
            out[#out + 1] = "<<<<<<< mine"
            for _, line in ipairs(chunk.ours) do
                out[#out + 1] = line
            end
            out[#out + 1] = "======="
            for _, line in ipairs(chunk.theirs) do
                out[#out + 1] = line
            end
            out[#out + 1] = ">>>>>>> theirs"
        end
    end

    return out
end

--- The widest line (for padding), capped — at least the pane's width so
-- tinted blocks run edge to edge.
-- @return columns
local function widest()
    local _, _, paneWidth = gitgud.getRect("MergeOursList")
    local width = math.floor(((paneWidth or 400) - 24) / 7.2) - 8
    for _, chunk in ipairs(file.chunks) do
        for _, key in ipairs({ "lines", "ours", "theirs" }) do
            for _, line in ipairs(chunk[key]) do
                width = math.max(width, #clean(line))
            end
        end
    end

    return math.min(width + 4, MAX_PAD)
end

--- Paint the header (title, progress, Save state).
local function paintHeader()
    local total = #conflictIndices()
    local left = unresolved()
    local progress = left == 0
        and text.colour(C.ok, "   resolved")
        or text.colour(C.warn, "   " .. left .. " to go")

    gitgud.setText("MergeTitle", text.colour(C.text, text.basename(file.path)) .. progress)
    gitgud.setProperty("MergeTitle", "TooltipText", file.path .. ": " .. (total - left) .. " of "
        .. text.plural(total, "conflict") .. " resolved")
    gitgud.setEnabled("MergeSaveButton", editing or left == 0)
    gitgud.setText("MergeEditButton", editing and "Back to picking" or "Edit result")
end

--- Fill the two top panes.
local function renderSides()
    local width = widest()
    local ours = {}
    local theirs = {}
    oursRows = {}
    theirsRows = {}
    chunkRow = {}
    local number = 0

    for i, chunk in ipairs(file.chunks) do
        chunkRow[i] = #ours + 1
        if not chunk.conflict then
            for _, line in ipairs(chunk.lines) do
                number = number + 1
                local row = text.colour(C.disabled, string.format(" %5d  ", number))
                    .. text.colour(C.text2, clean(line))
                ours[#ours + 1] = row
                theirs[#theirs + 1] = row
            end
        else
            local height = math.max(#chunk.ours, #chunk.theirs, 1)
            local takeOurs = taken(i, "ours")
            local takeTheirs = taken(i, "theirs")
            local undecided = #(choices[i] or {}) == 0

            --- One side's rows for this conflict.
            local function side(lines, isTaken, colour, rowsOut, mapOut)
                local tint = isTaken and ("40" .. colour:sub(3)) or (undecided and "26FFCF6E" or "10FFFFFF")
                local marker = isTaken and "✓" or " "
                for r = 1, height do
                    local line = lines[r]
                    local body = line and clean(line) or (r == 1 and #lines == 0 and "(nothing)" or "")
                    local lineColour = line and C.text or C.dim
                    rowsOut[#rowsOut + 1] = "[bg-colour='" .. tint .. "']"
                        .. text.colour(colour, " " .. marker .. "     ")
                        .. text.colour(lineColour, padTo(body, width))
                        .. "[bg-colour='00000000']"
                    mapOut[#rowsOut] = i
                end
            end

            side(chunk.ours, takeOurs, C.cyan, ours, oursRows)
            side(chunk.theirs, takeTheirs, C.pink, theirs, theirsRows)
        end
    end

    gitgud.setList("MergeOursList", ours)
    gitgud.setList("MergeTheirsList", theirs)
end

--- Fill the result pane (picking mode).
local function renderOutput()
    local rows = {}
    outputRows = {}
    local number = 0
    local ordinal = 0

    for i, chunk in ipairs(file.chunks) do
        if not chunk.conflict then
            for _, line in ipairs(chunk.lines) do
                number = number + 1
                rows[#rows + 1] = text.colour(C.disabled, string.format(" %5d  ", number))
                    .. text.colour(C.text2, clean(line))
                outputRows[#rows] = i
            end
        else
            ordinal = ordinal + 1
            local picked = choices[i] or {}
            if #picked == 0 then
                rows[#rows + 1] = "[bg-colour='26FFCF6E']"
                    .. text.colour(C.warn, "        ── conflict " .. ordinal .. ": click the block you want above ──")
                    .. "[bg-colour='00000000']"
                outputRows[#rows] = i
            else
                for _, side in ipairs(picked) do
                    local colour = side == "ours" and C.cyan or C.pink
                    for _, line in ipairs(chunk[side]) do
                        number = number + 1
                        rows[#rows + 1] = text.colour(colour, string.format(" %5d  ", number))
                            .. text.colour(C.text, clean(line))
                        outputRows[#rows] = i
                    end
                end
            end
        end
    end

    gitgud.setList("MergeOutputList", rows)
end

--- Repaint everything.
local function render()
    paintHeader()
    renderSides()
    if not editing then
        renderOutput()
    end
end

--- Take or drop one side of conflict i.
-- @param i     chunk index
-- @param side  "ours" | "theirs"
local function toggle(i, side)
    if editing then
        status.info("Switch back to picking to choose sides, or keep editing the result.")
        return
    end

    choices[i] = choices[i] or {}
    for n, choice in ipairs(choices[i]) do
        if choice == side then
            table.remove(choices[i], n)
            render()
            return
        end
    end
    table.insert(choices[i], side)
    render()
end

--- Scroll the panes to conflict number `n` (1-based among conflicts).
-- @param n  ordinal
local function goToConflict(n)
    local list = conflictIndices()
    if #list == 0 then
        return
    end

    focusConflict = (n - 1) % #list + 1
    local row = chunkRow[list[focusConflict]]
    gitgud.selectListItem("MergeOursList", row, true)
    gitgud.selectListItem("MergeTheirsList", row, true)
    gitgud.selectListItem("MergeOursList", nil, false)
    gitgud.selectListItem("MergeTheirsList", nil, false)
end

--- Leave the tool without writing anything.
function mergetool.close()
    if content.currentOverlay() == "MergeToolPanel" then
        content.closeOverlay()
    end
end

--- Resolve by taking one side whole (binary, deleted, or "All …" on a
-- file the user never needs to look at).
-- @param side  "ours" | "theirs"
local function resolveWhole(side)
    local path = file.path
    local ok, err = gitgud.resolveConflict(path, side)
    if status.report((side == "ours" and "Kept your version of " or "Took their version of ") .. path .. ".", ok, err) then
        mergetool.close()
        app.requestRefresh()
    end
end

--- Write the result and stage it.
local function save()
    local body = nil
    if editing then
        body = gitgud.getText("MergeOutputEdit")
        if not file.trailingNewline then
            body = body:gsub("\n$", "")
        end
    else
        if unresolved() > 0 then
            status.warn("Pick a side for every conflict first (or edit the result).")
            return
        end
        body = table.concat(resultLines(false), "\n")
        if file.trailingNewline then
            body = body .. "\n"
        end
    end

    --- Write, stage, report.
    local function commit()
        local path = file.path
        local ok, err = gitgud.writeRepoFile(path, body)
        if ok then
            ok, err = gitgud.stage(path)
        end
        if not status.report(nil, ok, err) then
            return
        end
        mergetool.close()
        app.requestRefresh()
        local left = #repo.load().conflicts
        if left == 0 then
            status.ok("Resolved " .. path .. ". All conflicts are resolved: commit (or continue) to finish.")
        else
            status.ok("Resolved " .. path .. ". " .. text.plural(left, "conflicted file") .. " to go.")
        end
    end

    if editing and (body:find("\n<<<<<<< ") or body:find("^<<<<<<< ") or body:find("\n>>>>>>> ")) then
        dialog.confirm("Conflict markers are still in the file",
            "The result still contains <<<<<<< / >>>>>>> lines. Save it like that anyway?",
            "Save anyway", commit, true)
        return
    end
    commit()
end

--- Switch between picking sides and editing the result by hand.
local function toggleEditing()
    editing = not editing
    gitgud.setVisible("MergeOutputList", not editing)
    gitgud.setVisible("MergeOutputEdit", editing)
    if editing then
        local body = table.concat(resultLines(true), "\n")
        gitgud.setText("MergeOutputEdit", body)
        gitgud.focus("MergeOutputEdit")
    end
    render()
end

--- Open the tool for a conflicted file.
-- @param path  repository-relative path
function mergetool.open(path)
    local conflict, err = gitgud.readConflict(path)
    if not conflict then
        status.error(err or "That file isn't conflicted.")
        return
    end

    file = conflict
    choices = {}
    editing = false
    focusConflict = 0
    content.openOverlay("MergeToolPanel")

    local whole = file.binary or file.oursDeleted or file.theirsDeleted
    gitgud.setVisible("MergeChoicePanel", whole)
    for _, name in ipairs({ "MergePrevButton", "MergeNextButton", "MergeAllOursButton",
        "MergeAllTheirsButton", "MergeSaveButton" }) do
        gitgud.setVisible(name, not whole)
    end
    gitgud.setVisible("MergeOutputList", not whole)
    gitgud.setVisible("MergeOutputEdit", false)

    if whole then
        local why = "This file is binary, so it can't be merged line by line."
        if file.oursDeleted then
            why = "Your branch deleted this file; the incoming side changed it."
        elseif file.theirsDeleted then
            why = "The incoming side deleted this file; your branch changed it."
        end
        gitgud.setText("MergeTitle", text.colour(C.text, path))
        gitgud.setText("MergeChoiceText", text.escape(why .. " Which version do you want?"))
        gitgud.setText("MergeChoiceOurs", file.oursDeleted and "Delete it (mine)" or "Keep mine")
        gitgud.setText("MergeChoiceTheirs", file.theirsDeleted and "Delete it (theirs)" or "Take theirs")
        return
    end

    render()
    goToConflict(1)
end

--- Wire the tool.
function mergetool.init()
    gitgud.linkScroll("MergeOursList", "MergeTheirsList")

    for _, spec in ipairs({ { list = "MergeOursList", side = "ours" }, { list = "MergeTheirsList", side = "theirs" } }) do
        gitgud.on(spec.list .. ".clicked", function(value)
            local _, _, row = menu.parseClick(value)
            local map = spec.side == "ours" and oursRows or theirsRows
            local chunk = row and map[row]
            if chunk then
                toggle(chunk, spec.side)
            end
        end)
    end

    gitgud.on("MergeOutputList.clicked", function(value)
        local _, _, row = menu.parseClick(value)
        local chunk = row and outputRows[row]
        if chunk and chunkRow[chunk] then
            gitgud.selectListItem("MergeOursList", chunkRow[chunk], true)
            gitgud.selectListItem("MergeOursList", nil, false)
        end
    end)

    gitgud.on("MergeAllOursButton.clicked", function()
        for _, i in ipairs(conflictIndices()) do
            choices[i] = { "ours" }
        end
        render()
    end)
    gitgud.on("MergeAllTheirsButton.clicked", function()
        for _, i in ipairs(conflictIndices()) do
            choices[i] = { "theirs" }
        end
        render()
    end)

    gitgud.on("MergePrevButton.clicked", function()
        goToConflict(focusConflict - 1)
    end)
    gitgud.on("MergeNextButton.clicked", function()
        goToConflict(focusConflict + 1)
    end)

    gitgud.on("MergeEditButton.clicked", toggleEditing)
    gitgud.on("MergeSaveButton.clicked", save)
    gitgud.on("MergeCloseButton.clicked", mergetool.close)

    gitgud.on("MergeChoiceOurs.clicked", function()
        resolveWhole("ours")
    end)
    gitgud.on("MergeChoiceTheirs.clicked", function()
        resolveWhole("theirs")
    end)
end

return mergetool
