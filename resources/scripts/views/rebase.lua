--- views/rebase.lua — the interactive rebase editor.
--
-- Rewrite the commits after a chosen commit: reorder them (drag a row, the
-- arrow buttons, or Alt+Up/Down), and choose per commit:
--   Pick    keep it
--   Reword  keep the changes, change the message (edit it below)
--   Squash  fold it into the commit below it, joining both messages
--   Fixup   fold it into the commit below it, keeping only that message
--   Drop    leave it out
-- Newest is at the top, like History. Nothing happens until "Rewrite
-- history"; the engine then builds the new commits in memory first, so a
-- conflict leaves the branch exactly as it was. The rewrite is one Undo step.
--
-- Open it from a commit's right-click menu ("Interactive rebase from
-- here…") or Branch > Interactive rebase….
--
-- Public API: rebase.open(baseOid), rebase.openRecent()

local C = require("core.palette")
local app = require("core.app")
local dialog = require("ui.dialog")
local menu = require("ui.menu")
local repo = require("core.repo")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")

local rebase = { name = "rebase" }

local ACTIONS = {
    pick = { label = "PICK", colour = C.cyan },
    reword = { label = "REWORD", colour = C.blue },
    squash = { label = "SQUASH", colour = C.purple },
    fixup = { label = "FIXUP", colour = C.pink },
    drop = { label = "DROP", colour = C.err },
}

local base = nil          -- oid the rewritten commits sit on
local items = {}          -- newest first: { commit, action, message }
local selected = 1
local token = nil         -- Escape token while open
local loadingMessage = false

--- The commit message without trailing blank lines.
-- @param message  full message
-- @return trimmed message
local function trimMessage(message)
    return (message:gsub("%s+$", ""))
end

--- One list row.
-- @param item  plan entry
-- @param i     row number
-- @return markup
local function rowText(item, i)
    local action = ACTIONS[item.action]
    local folded = item.action == "squash" or item.action == "fixup"
    local summary = text.splitMessage(item.message)
    local summaryColour = item.action == "drop" and C.disabled or C.text

    return text.rowHeight(30) .. " "
        .. "[font='Gitgud-UI-Small']" .. text.colour(action.colour, string.format("%-7s", action.label)) .. "[font='']"
        .. text.colour(C.dim, (folded and "  ↓ " or "    ") .. item.commit.shortOid .. "  ")
        .. text.colour(summaryColour, summary)
end

--- Fill the list and the summary line.
local function render()
    local rows = {}
    local kept = 0
    for i, item in ipairs(items) do
        rows[i] = rowText(item, i)
        if item.action ~= "drop" and item.action ~= "squash" and item.action ~= "fixup" then
            kept = kept + 1
        end
    end
    gitgud.setList("RebaseList", rows)
    gitgud.selectListItem("RebaseList", selected, true)

    gitgud.setText("RebaseSummaryLabel", text.escape(text.plural(#items, "commit") .. " → "
        .. text.plural(kept, "commit") .. " on " .. repo.state().branch))
end

--- Show the selected commit's message in the editor.
local function loadMessage()
    local item = items[selected]
    loadingMessage = true
    gitgud.setText("RebaseMessageEdit", item and item.message or "")
    loadingMessage = false

    local editable = item and (item.action == "reword" or item.action == "pick" or item.action == "squash")
    gitgud.setEnabled("RebaseMessageEdit", editable == true)
    local hint = "Message"
    if item and item.action == "squash" then
        hint = "Message (joined with the commit below when squashed)"
    elseif item and item.action == "fixup" then
        hint = "Message (dropped: fixup keeps the message of the commit below)"
    elseif item and item.action == "drop" then
        hint = "Message (this commit is dropped)"
    end
    gitgud.setText("RebaseMessageLabel", hint)
end

--- Select row i.
-- @param i  row
local function select(i)
    if #items == 0 then
        return
    end

    selected = math.max(1, math.min(#items, i))
    gitgud.selectListItem("RebaseList", selected, true)
    loadMessage()
end

--- Set the selected commit's action.
-- @param action  key of ACTIONS
local function setAction(action)
    local item = items[selected]
    if not item then
        return
    end

    item.action = action
    gitgud.setText("RebaseError", "")
    render()
    loadMessage()
end

--- Move the selected commit up (newer) or down (older).
-- @param delta  -1 up, +1 down
local function move(delta)
    local target = selected + delta
    if not items[selected] or target < 1 or target > #items then
        return
    end

    items[selected], items[target] = items[target], items[selected]
    selected = target
    render()
    loadMessage()
end

--- Close the editor.
local function close()
    if token then
        dialog.hideModal("RebaseDialog", token)
        token = nil
    end
end

--- Check the plan and run it.
local function start()
    if #items == 0 then
        return
    end
    local oldest = items[#items]
    if oldest.action == "squash" or oldest.action == "fixup" then
        gitgud.setText("RebaseError", text.escape("The oldest commit can't be squashed: nothing below it to fold into."))
        return
    end

    -- The engine wants oldest first.
    local steps = {}
    for i = #items, 1, -1 do
        local item = items[i]
        local changed = trimMessage(item.message) ~= trimMessage(item.commit.message)
        local action = item.action
        if action == "pick" and changed then
            action = "reword"
        end
        local message = ""
        if action == "reword" or (action == "squash" and changed) then
            message = trimMessage(item.message) .. "\n"
        end
        steps[#steps + 1] = { action = action, oid = item.commit.oid, message = message }
    end

    local result, err = undo.track("Interactive rebase", function()
        return gitgud.interactiveRebase(base, steps)
    end)
    if not result then
        gitgud.setText("RebaseError", text.escape(err or "The rebase failed."))
        return
    end
    if result.kind == "conflicts" then
        gitgud.setText("RebaseError", text.escape(result.message))
        return
    end

    close()
    app.requestRefresh()
    if result.kind == "uptodate" then
        status.info("Nothing to change.")
        return
    end
    local ab = repo.state().aheadBehind
    local extra = ""
    if ab.hasUpstream then
        extra = " If the branch was already pushed, force push to update it."
    end
    status.ok(result.message .. extra)
end

--- Open the editor for the commits after `baseOid`.
-- @param baseOid  the commit that stays; everything newer is rewritten
function rebase.open(baseOid)
    local state = repo.state()
    if state.branch == "" then
        status.warn("Check out a branch first: interactive rebase rewrites a branch.")
        return
    end
    if state.operation ~= "none" then
        status.warn("Finish or abort the " .. state.operation .. " in progress first.")
        return
    end

    local todo, err = gitgud.rebaseTodo(baseOid)
    if not todo then
        status.error(err or "Can't rebase from that commit.")
        return
    end
    if #todo == 0 then
        status.info("There are no commits after that one to rewrite.")
        return
    end

    base = baseOid
    items = {}
    for i = #todo, 1, -1 do
        items[#items + 1] = { commit = todo[i], action = "pick", message = trimMessage(todo[i].message) }
    end
    selected = 1

    gitgud.setText("RebaseTitle", text.escape("Interactive rebase — " .. state.branch))
    gitgud.setText("RebaseError", "")
    render()
    loadMessage()
    token = dialog.showModal("RebaseDialog", close)
end

--- Branch menu entry: rewrite the last N commits.
function rebase.openRecent()
    dialog.prompt("Interactive rebase", "How many of the latest commits?", "5", "Open editor", function(value)
        local count = tonumber(value)
        if not count or count < 1 then
            return false, "Enter a number."
        end
        count = math.floor(count)
        local commits = gitgud.history(count + 1)
        if #commits <= count then
            return false, "The branch has only " .. text.plural(#commits, "commit")
                .. "; the oldest can't be rewritten here."
        end
        -- Let the dialog close before the editor's modal opens.
        gitgud.after(1, function()
            rebase.open(commits[count + 1].oid)
        end)
        return true
    end)
end

--- Wire the editor.
function rebase.init()
    gitgud.on("RebaseList.selected", function(value)
        local row = tonumber(value)
        if row and row >= 0 then
            select(row + 1)
        end
    end)

    gitgud.on("RebaseList.dragged", function(value)
        local fromRow, toRow = value:match("^(%d+),(%d+)$")
        local from = tonumber(fromRow) + 1
        local to = tonumber(toRow) + 1
        local item = table.remove(items, from)
        if item then
            table.insert(items, to, item)
            selected = to
            render()
            loadMessage()
        end
    end)

    gitgud.on("RebaseList.rightClicked", function(value)
        local x, y, row = menu.parseClick(value)
        if not row or not items[row] then
            return
        end
        select(row)
        local entries = {}
        for _, key in ipairs({ "pick", "reword", "squash", "fixup", "drop" }) do
            entries[#entries + 1] = {
                label = key:sub(1, 1):upper() .. key:sub(2),
                checked = items[row].action == key,
                action = function()
                    setAction(key)
                end,
            }
        end
        menu.popup(entries, x, y)
    end)

    gitgud.on("RebaseMessageEdit.changed", function(value)
        local item = items[selected]
        if loadingMessage or not item then
            return
        end
        item.message = value
        if item.action == "pick" and trimMessage(value) ~= trimMessage(item.commit.message) then
            item.action = "reword"
            gitgud.setListItem("RebaseList", selected, rowText(item, selected))
        end
    end)

    for _, key in ipairs({ "pick", "reword", "squash", "fixup", "drop" }) do
        local button = "Rebase" .. key:sub(1, 1):upper() .. key:sub(2) .. "Button"
        gitgud.on(button .. ".clicked", function()
            setAction(key)
        end)
    end

    gitgud.on("RebaseUpButton.clicked", function()
        move(-1)
    end)
    gitgud.on("RebaseDownButton.clicked", function()
        move(1)
    end)
    gitgud.on("RebaseCancelButton.clicked", close)
    gitgud.on("RebaseStartButton.clicked", start)

    gitgud.on("key", function(combo)
        if not token or gitgud.textInputFocused() then
            return
        end
        if combo == "alt+up" then
            move(-1)
        elseif combo == "alt+down" then
            move(1)
        elseif combo == "up" then
            select(selected - 1)
        elseif combo == "down" then
            select(selected + 1)
        end
    end)
end

return rebase
