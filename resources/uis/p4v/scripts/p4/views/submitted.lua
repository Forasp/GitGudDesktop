--- p4/views/submitted.lua — the Submitted tab: submitted changelists
-- (commits), newest first, filtered by folder, user, and branch (the
-- current one, or every branch). "More…" loads older ones. The selected
-- changelist's Details and Files show below.

local C = require("core.palette")
local app = require("core.app")
local commands = require("p4.commands")
local grid = require("p4.grid")
local icons = require("p4.icons")
local menu = require("ui.menu")
local panes = require("p4.views.panes")
local repo = require("core.repo")
local selection = require("p4.selection")
local settings = require("core.settings")
local text = require("core.text")
local util = require("p4.util")

local submitted = { name = "submitted" }

local GRID = "SubmittedGrid"
local PAGE = 200

local limit = PAGE
local stale = true
local details = nil
local revealOid = nil   -- select this one after the next load

--- The branch scope: "current" or "all".
local function scope()
    return settings.get("p4.submittedScope", "current")
end

--- Load the changelists for the filters.
-- @return array of history rows
local function load()
    local folder = selection.fromDepotPath(gitgud.getText("SubmittedPathEdit")) or ""
    local commits = {}
    if folder ~= "" then
        -- A folder's history follows the current branch (file logs walk
        -- from HEAD).
        commits = gitgud.fileLog(folder, limit) or {}
    elseif scope() == "all" then
        local seen = {}
        for _, branch in ipairs(gitgud.branches() or {}) do
            for _, commit in ipairs(gitgud.history({ max = limit, from = branch.oid }) or {}) do
                if not seen[commit.oid] then
                    seen[commit.oid] = true
                    commits[#commits + 1] = commit
                end
            end
        end
        table.sort(commits, function(a, b)
            return a.time > b.time
        end)
        while #commits > limit do
            table.remove(commits)
        end
    else
        commits = gitgud.history({ max = limit }) or {}
    end

    local user = text.trim(gitgud.getText("SubmittedUserEdit")):lower()
    if user ~= "" then
        local filtered = {}
        for _, commit in ipairs(commits) do
            if commit.author:lower():find(user, 1, true) or commit.email:lower():find(user, 1, true) then
                filtered[#filtered + 1] = commit
            end
        end
        commits = filtered
    end

    return commits
end

--- Rebuild the table (when visible).
local function render()
    if not panes.isShown("submitted") then
        stale = true
        return
    end
    stale = false
    gitgud.setText("SubmittedBranchButton", (scope() == "all" and "All branches"
        or ("Branch: " .. (repo.state().branch ~= "" and repo.state().branch or "HEAD"))) .. icons.dropdown())
    if not repo.state().open then
        grid.setRows(GRID, {})
        details.show(nil)
        return
    end

    local labels = {}
    for _, ref in ipairs(gitgud.refLabels() or {}) do
        labels[ref.oid] = labels[ref.oid] or {}
        table.insert(labels[ref.oid], ref.name)
    end

    local rows = {}
    for _, commit in ipairs(load()) do
        local refs = labels[commit.oid]
        local description = util.summary(commit.summary)
        rows[#rows + 1] = {
            icon = icons.inline("ChangeSubmitted"),
            cells = {
                change = util.change(commit.oid),
                date = util.dateTime(commit.time),
                user = commit.author,
                description = refs and { markup = text.colour(C.link, "[" .. table.concat(refs, ", ") .. "] ")
                    .. text.colour(C.text, description) } or description,
            },
            sort = { date = commit.time, description = description:lower() },
            data = commit,
        }
    end
    grid.setRows(GRID, rows, function(row)
        return row.data.oid
    end)

    if revealOid then
        local oid = revealOid
        revealOid = nil
        if not grid.selectWhere(GRID, function(row)
                return row.data.oid == oid
            end) then
            require("p4.log").warn("Change " .. util.change(oid) .. " isn't in this list (widen the filters).")
        end
    end
end

--- Select a changelist in the Submitted tab (switching to it).
-- @param oid  commit id
function submitted.reveal(oid)
    revealOid = oid
    panes.show("submitted")
    render()
end

--- Context menu for changelists.
-- @param rows  selected rows
-- @param x     position
-- @param y     position
local function contextMenu(rows, x, y)
    local commit = rows[1] and rows[1].data
    if not commit then
        return
    end
    menu.popup({
        { label = "Folder Diff Against Previous Changelist", action = function()
            require("p4.windows.folderdiff").open("", commit.oid .. "^", commit.oid)
        end },
        { label = "Diff Changelists", enabled = #rows == 2, action = function()
            local a, b = rows[2].data, rows[1].data
            if a.time > b.time then
                a, b = b, a
            end
            require("p4.windows.folderdiff").open("", a.oid, b.oid)
        end },
        { separator = true },
        { label = "Get Revision (Workspace to This Changelist)…", action = function()
            require("p4.actions").getRevision({}, commit.oid)
        end },
        { label = "Branch from This Changelist…", action = function()
            commands.newBranch(commit.oid)
        end },
        { label = "Label This Changelist…", action = function()
            commands.newLabel(commit.oid)
        end },
        { label = "Copy to Current Branch (Cherry-pick)", action = function()
            commands.cherryPick(commit.oid)
        end },
        { label = "Back Out Changelist…", action = function()
            commands.backOut(commit.oid)
        end },
        { label = "Roll Back Branch to Here (keep changes)…", action = function()
            commands.resetTo(commit.oid, "mixed")
        end },
        { separator = true },
        { label = "Copy Change ID", action = function()
            gitgud.setClipboard(commit.oid)
        end },
        { label = "Copy Description", action = function()
            gitgud.setClipboard(commit.message)
        end },
    }, x, y)
end

function submitted.init()
    grid.create(GRID, "SubmittedGridHost", {
        columns = {
            { key = "change", title = "Change", width = 90 },
            { key = "date", title = "Date Submitted", width = 150, descending = true },
            { key = "user", title = "Submitted By", width = 150 },
            { key = "description", title = "Description" },
        },
        multi = true,
        emptyText = "No submitted changelists match.",
        onSelect = function(rows)
            details.show(rows[1] and rows[1].data)
            local items = {}
            for _, row in ipairs(rows) do
                items[#items + 1] = { revision = row.data.oid, source = "submitted" }
            end
            selection.set("submitted", items)
        end,
        onActivate = function(row)
            require("p4.windows.folderdiff").open("", row.data.oid .. "^", row.data.oid)
        end,
        onContext = contextMenu,
    })
    details = require("p4.views.changedetails").create("Submitted")

    require("p4.frame").splitPanel({
        bar = "SubmittedSplit",
        container = "SubmittedPanel",
        top = "SubmittedGridHost",
        bottom = "SubmittedDetailHost",
        offset = 30,
        setting = "p4.submittedSplit",
        default = 0.6,
    })

    gitgud.on("SubmittedPathEdit.accepted", function()
        limit = PAGE
        render()
    end)
    gitgud.on("SubmittedUserEdit.accepted", render)
    gitgud.on("SubmittedMoreButton.clicked", function()
        limit = limit + PAGE
        render()
    end)
    gitgud.on("SubmittedBranchButton.clicked", function()
        local x, y, _, h = gitgud.getRect("SubmittedBranchButton")
        menu.popup({
            { label = "Current branch", checked = scope() == "current", action = function()
                settings.set("p4.submittedScope", "current")
                render()
            end },
            { label = "All branches", checked = scope() == "all", action = function()
                settings.set("p4.submittedScope", "all")
                render()
            end },
        }, x, y + h)
    end)
    app.subscribe("pane.shown", function(id)
        if id == "submitted" and stale then
            render()
        end
    end)
end

function submitted.refresh()
    stale = true
    render()
end

return submitted
