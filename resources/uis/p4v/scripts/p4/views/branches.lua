--- p4/views/branches.lua — the Branches tab: local and remote branches (P4V's
-- branch specs and streams, in Git terms) with their latest changelist,
-- owner, upstream, and how far ahead/behind they are. Double-click switches
-- the workspace to a branch; right-click for merge, compare, and the rest.

local C = require("core.palette")
local app = require("core.app")
local commands = require("p4.commands")
local grid = require("p4.grid")
local icons = require("p4.icons")
local menu = require("ui.menu")
local panes = require("p4.views.panes")
local repo = require("core.repo")
local settings = require("core.settings")
local text = require("core.text")
local util = require("p4.util")

local branchesView = { name = "p4branches" }

local GRID = "BranchesGrid"
local stale = true

--- Rebuild when visible.
local function render()
    if not panes.isShown("branches") then
        stale = true
        return
    end
    stale = false
    if not repo.state().open then
        grid.setRows(GRID, {})
        return
    end

    local filter = text.trim(gitgud.getText("BranchesFilterEdit"))
    local showRemote = settings.get("p4.branchesRemote", true)
    local rows = {}
    for _, branch in ipairs(gitgud.branches() or {}) do
        local isShelf = branch.name:find("shelves/", 1, true) ~= nil
        if (showRemote or not branch.isRemote) and text.contains(branch.name, filter) and not isShelf then
            local tip = (gitgud.history({ max = 1, from = branch.oid }) or {})[1] or {}
            local sync = ""
            if not branch.isRemote and branch.upstream ~= "" then
                sync = (branch.ahead > 0 or branch.behind > 0)
                    and (branch.ahead .. " ahead, " .. branch.behind .. " behind") or "up to date"
            end
            rows[#rows + 1] = {
                icon = icons.inline(branch.isRemote and "RemoteBranch" or "Branch16"),
                cells = {
                    name = branch.isHead and { markup = text.colour(C.link, branch.name .. "  (current)") } or branch.name,
                    change = util.change(branch.oid),
                    date = util.dateTime(branch.time),
                    owner = tip.author or "",
                    upstream = branch.upstream,
                    sync = sync,
                    description = util.summary(tip.summary),
                },
                sort = { name = (branch.isRemote and "1" or "0") .. branch.name:lower(), date = branch.time },
                data = branch,
            }
        end
    end
    grid.setRows(GRID, rows, function(row)
        return row.data.name
    end)
end

--- Context menu for a branch.
local function contextMenu(rows, x, y)
    local branch = rows[1] and rows[1].data
    if not branch then
        return
    end
    local current = repo.state().branch
    local remote = repo.splitRemoteBranch(branch.name)
    menu.popup({
        { label = "Switch Workspace to " .. branch.name, enabled = not branch.isHead, action = function()
            commands.switchBranch(branch.name)
        end },
        { label = "Merge/Integrate into " .. current .. "…", enabled = not branch.isHead and current ~= "", action = function()
            commands.integrate(branch.name, "merge")
        end },
        { label = "Squash into " .. current, enabled = not branch.isHead and current ~= "", action = function()
            commands.integrate(branch.name, "squash")
        end },
        { label = "Rebase " .. current .. " onto " .. branch.name .. "…", enabled = not branch.isHead and current ~= "", action = function()
            commands.integrate(branch.name, "rebase")
        end },
        { label = "Compare with " .. (current ~= "" and current or "HEAD") .. " (Folder Diff)", enabled = not branch.isHead, action = function()
            commands.compare(branch.name, "HEAD")
        end },
        { separator = true },
        { label = "New Branch from Here…", action = function()
            commands.newBranch(branch.oid)
        end },
        { label = "Label Its Latest Changelist…", action = function()
            commands.newLabel(branch.oid)
        end },
        { label = "Track a Remote Branch…", enabled = not branch.isRemote, action = function()
            require("ui.dialog").prompt("Track", "Remote branch (e.g. origin/" .. branch.name .. ")",
                branch.upstream ~= "" and branch.upstream or ((repo.primaryRemote() or "origin") .. "/" .. branch.name),
                "Track", function(upstream)
                    commands.track(branch.name, upstream ~= "" and upstream or nil)
                    return true
                end)
        end },
        { label = "Stop Tracking", enabled = not branch.isRemote and branch.upstream ~= "", action = function()
            commands.track(branch.name, nil)
        end },
        { separator = true },
        { label = "Rename…", enabled = not branch.isRemote, action = function()
            commands.renameBranch(branch.name)
        end },
        { label = "Delete…", enabled = not branch.isHead, action = function()
            if branch.isRemote and remote then
                commands.deleteRemoteBranch(branch.name)
            else
                commands.deleteBranch(branch.name)
            end
        end },
        { separator = true },
        { label = "Show Changelists on This Branch", action = function()
            settings.set("p4.submittedScope", "current")
            if not branch.isHead then
                require("p4.log").info("Submitted shows the current branch; switch to " .. branch.name .. " to list its changelists.")
            end
            panes.show("submitted")
        end },
        { label = "Copy Name", action = function()
            gitgud.setClipboard(branch.name)
        end },
    }, x, y)
end

function branchesView.init()
    grid.create(GRID, "BranchesGridHost", {
        columns = {
            { key = "name", title = "Branch", width = 220 },
            { key = "change", title = "Latest Change", width = 100 },
            { key = "date", title = "Date", width = 140, descending = true },
            { key = "owner", title = "Owner", width = 130 },
            { key = "upstream", title = "Upstream", width = 140 },
            { key = "sync", title = "Sync", width = 130 },
            { key = "description", title = "Description" },
        },
        sortKey = "name",
        emptyText = "No branches.",
        onActivate = function(row)
            if not row.data.isHead then
                commands.switchBranch(row.data.name)
            end
        end,
        onContext = contextMenu,
    })
    gitgud.setChecked("BranchesShowRemote", settings.get("p4.branchesRemote", true))
    gitgud.on("BranchesShowRemote.toggled", function(value)
        settings.set("p4.branchesRemote", value == "1")
        render()
    end)
    gitgud.on("BranchesFilterEdit.changed", render)
    gitgud.on("BranchesNewButton.clicked", function()
        commands.newBranch(nil)
    end)
    app.subscribe("pane.shown", function(id)
        if id == "branches" and stale then
            render()
        end
    end)
end

function branchesView.refresh()
    stale = true
    render()
end

return branchesView
