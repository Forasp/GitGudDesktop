--- p4/views/history.lua — the History tab: every revision of the selected
-- file or folder, newest first, with the selected revision's Details and
-- Files underneath.
--
-- A file's revisions are numbered along its history like P4V's #1…#n.
-- Double-click a revision to diff it against the previous one; select two
-- and choose Diff Revisions to compare them.

local C = require("core.palette")
local actions = require("p4.actions")
local app = require("core.app")
local commands = require("p4.commands")
local grid = require("p4.grid")
local icons = require("p4.icons")
local menu = require("ui.menu")
local panes = require("p4.views.panes")
local repo = require("core.repo")
local selection = require("p4.selection")
local text = require("core.text")
local util = require("p4.util")

local history = { name = "history" }

local GRID = "HistoryGrid"
local MAX = 300

local target = nil     -- { path, folder }
local stale = true     -- needs reloading when shown
local shown = nil      -- the revision in the details pane
local actionCache = {} -- "<oid> <path>" -> action (commits never change)
local details = nil    -- the Details / Files pane (changedetails)

--- What a revision did to a single file.
-- @param path    file
-- @param commit  history row
-- @return "add" | "delete" | "edit" | "integrate" | "move"
local function actionOf(path, commit)
    local key = commit.oid .. " " .. path
    if actionCache[key] then
        return actionCache[key]
    end
    local action = "edit"
    if #commit.parents > 1 then
        action = "integrate"
        actionCache[key] = action
        return action
    end
    local base = #commit.parents > 0 and (commit.oid .. "^") or ""
    for _, file in ipairs(gitgud.changedFiles(base, commit.oid, path) or {}) do
        if file.path == path or file.oldPath == path then
            local names = { A = "add", D = "delete", R = "move/add", T = "edit", M = "edit" }
            action = names[file.status] or "edit"
            break
        end
    end
    actionCache[key] = action

    return action
end

--- Show a revision below the table.
-- @param commit  history row, or nil
local function showDetails(commit)
    shown = commit
    if details then
        details.show(commit)
    end
end

--- Reload the table.
local function render()
    if not panes.isShown("history") then
        stale = true
        return
    end
    stale = false
    if not target or not repo.state().open then
        gitgud.setText("HistoryTitle", text.colour(C.dim, "Select a file or folder in the tree to see its history."))
        grid.setRows(GRID, {})
        showDetails(nil)
        return
    end

    local depotPath = selection.depotPath(target.path)
    gitgud.setText("HistoryTitle", text.colour(C.text,
        (target.folder and "History of folder: " or "History of file: ") .. depotPath
            .. (target.folder and "/..." or "")))

    local commits
    if target.path == "" then
        commits = gitgud.history({ max = MAX }) or {}
    else
        commits = gitgud.fileLog(target.path, MAX) or {}
    end
    local rows = {}
    for i, commit in ipairs(commits) do
        local revision = #commits - i + 1
        local action = (not target.folder) and actionOf(target.path, commit) or ""
        rows[#rows + 1] = {
            icon = icons.inline(target.folder and "ChangeSubmitted" or icons.forStatus(action == "add" and "A"
                or action == "delete" and "D" or "M")),
            cells = {
                revision = target.folder and "" or ("#" .. revision),
                change = util.change(commit.oid),
                date = util.dateTime(commit.time),
                user = commit.author,
                action = action,
                description = util.summary(commit.summary),
            },
            sort = { revision = revision, date = commit.time },
            data = commit,
        }
    end
    grid.setRows(GRID, rows, function(row)
        return row.data.oid
    end)
    local selected = grid.selected(GRID)
    showDetails(selected[1] and selected[1].data or (rows[1] and rows[1].data))
    if not selected[1] and rows[1] then
        grid.selectRows(GRID, { grid.rows(GRID)[1] })
    end
end

--- Show the history of a path (switching to the tab).
-- @param path    repository path
-- @param folder  true for a folder
function history.show(path, folder)
    target = { path = path, folder = folder == true }
    panes.show("history")
    render()
end

--- The revisions selected in the table.
-- @return array of history rows
function history.selectedCommits()
    local out = {}
    for _, row in ipairs(grid.selected(GRID)) do
        out[#out + 1] = row.data
    end

    return out
end

--- Context menu for revisions.
-- @param rows  selected grid rows
-- @param x     position
-- @param y     position
local function contextMenu(rows, x, y)
    local commit = rows[1] and rows[1].data
    if not commit then
        return
    end
    local isFile = target and not target.folder
    local path = target and target.path
    local windows = require("p4.windows")
    menu.popup({
        { label = "Diff Against Previous Revision", enabled = isFile, action = function()
            windows.diffRevisions(path, commit.oid .. "^", path, commit.oid)
        end },
        { label = "Diff Against Workspace File", enabled = isFile, action = function()
            windows.diffRevisions(path, commit.oid, path, "workdir")
        end },
        { label = "Diff Revisions", enabled = #rows == 2, action = function()
            local a, b = rows[2].data, rows[1].data
            if a.time > b.time then
                a, b = b, a
            end
            if isFile then
                windows.diffRevisions(path, a.oid, path, b.oid)
            else
                require("p4.windows.folderdiff").open(path, a.oid, b.oid)
            end
        end },
        { label = "Folder Diff Against Previous", enabled = not isFile, action = function()
            require("p4.windows.folderdiff").open(path, commit.oid .. "^", commit.oid)
        end },
        { separator = true },
        { label = "Get This Revision", enabled = isFile, action = function()
            actions.getRevision({ path }, commit.oid)
        end },
        { label = "Time-lapse View", enabled = isFile, action = function()
            require("p4.windows.timelapse").open(path, commit.oid)
        end },
        { label = "Revision Graph", enabled = isFile, action = function()
            require("p4.windows.revgraph").open(path)
        end },
        { separator = true },
        { label = "Show Changelist in Submitted", action = function()
            require("p4.views.submitted").reveal(commit.oid)
        end },
        { label = "Branch from This Changelist…", action = function()
            commands.newBranch(commit.oid)
        end },
        { label = "Label This Changelist…", action = function()
            commands.newLabel(commit.oid)
        end },
        { label = "Copy Changelist to Current Branch (Cherry-pick)", action = function()
            commands.cherryPick(commit.oid)
        end },
        { label = "Back Out Changelist…", action = function()
            commands.backOut(commit.oid)
        end },
        { separator = true },
        { label = "Copy Change ID", action = function()
            gitgud.setClipboard(commit.oid)
        end },
    }, x, y)
end

function history.init()
    grid.create(GRID, "HistoryGridHost", {
        columns = {
            { key = "revision", title = "Revision", width = 76, descending = true },
            { key = "change", title = "Change", width = 84 },
            { key = "date", title = "Date Submitted", width = 140, descending = true },
            { key = "user", title = "Submitted By", width = 140 },
            { key = "action", title = "Action", width = 80 },
            { key = "description", title = "Description" },
        },
        multi = true,
        emptyText = "No revisions.",
        onSelect = function(rows)
            showDetails(rows[1] and rows[1].data)
            local items = {}
            for _, row in ipairs(rows) do
                items[#items + 1] = { path = target and target.path, folder = target and target.folder,
                    revision = row.data.oid, source = "history" }
            end
            selection.set("history", items)
        end,
        onActivate = function(row)
            if target and not target.folder then
                require("p4.windows").diffRevisions(target.path, row.data.oid .. "^", target.path, row.data.oid)
            else
                require("p4.windows.folderdiff").open(target and target.path or "", row.data.oid .. "^", row.data.oid)
            end
        end,
        onContext = contextMenu,
    })

    details = require("p4.views.changedetails").create("History")

    require("p4.frame").splitPanel({
        bar = "HistorySplit",
        container = "HistoryPanel",
        top = "HistoryGridHost",
        bottom = "HistoryDetailHost",
        offset = 26,
        setting = "p4.historySplit",
        default = 0.6,
    })

    app.subscribe("selection.changed", function(items, source)
        if source == "tree" or source == "files" then
            local first = items[1]
            if first then
                target = { path = first.path, folder = first.folder }
                stale = true
                render()
            end
        end
    end)
    app.subscribe("pane.shown", function(id)
        if id == "history" and stale then
            render()
        end
    end)
end

function history.refresh()
    stale = true
    render()
end

return history
