--- depot/views/labels.lua — the Labels tab: Git tags as labels — the
-- changelist each marks, its date, and its description.

local app = require("core.app")
local commands = require("depot.commands")
local grid = require("depot.grid")
local icons = require("depot.icons")
local menu = require("ui.menu")
local panes = require("depot.views.panes")
local repo = require("core.repo")
local text = require("core.text")
local util = require("depot.util")

local labels = { name = "labels" }

local GRID = "LabelsGrid"
local stale = true

local function render()
    if not panes.isShown("labels") then
        stale = true
        return
    end
    stale = false
    if not repo.state().open then
        grid.setRows(GRID, {})
        return
    end

    local filter = text.trim(gitgud.getText("LabelsFilterEdit"))
    local rows = {}
    for _, tag in ipairs(gitgud.tags() or {}) do
        if text.contains(tag.name, filter) then
            local commit = (gitgud.history({ max = 1, from = tag.oid }) or {})[1] or {}
            rows[#rows + 1] = {
                icon = icons.inline("Label16"),
                cells = {
                    name = tag.name,
                    change = util.change(tag.oid),
                    date = util.dateTime(commit.time),
                    owner = commit.author or "",
                    description = tag.message ~= "" and util.summary(tag.message) or util.summary(commit.summary),
                },
                sort = { date = commit.time or 0 },
                data = tag,
            }
        end
    end
    grid.setRows(GRID, rows, function(row)
        return row.data.name
    end)
end

function labels.init()
    grid.create(GRID, "LabelsGridHost", {
        columns = {
            { key = "name", title = "Label", width = 200 },
            { key = "change", title = "Change", width = 100 },
            { key = "date", title = "Date", width = 150, descending = true },
            { key = "owner", title = "Owner", width = 140 },
            { key = "description", title = "Description" },
        },
        sortKey = "date",
        sortDescending = true,
        emptyText = "No labels. Right-click a submitted changelist to label it.",
        onActivate = function(row)
            require("depot.views.submitted").reveal(row.data.oid)
        end,
        onContext = function(rows, x, y)
            local tag = rows[1] and rows[1].data
            if not tag then
                return
            end
            menu.popup({
                { label = "Show Changelist", action = function()
                    require("depot.views.submitted").reveal(tag.oid)
                end },
                { label = "Get Revision (Workspace to This Label)…", action = function()
                    require("depot.actions").getRevision({}, tag.name)
                end },
                { label = "Compare with Workspace (Folder Diff)", action = function()
                    require("depot.windows.folderdiff").open("", tag.name, "workdir")
                end },
                { label = "New Branch from This Label…", action = function()
                    commands.newBranch(tag.oid)
                end },
                { separator = true },
                { label = "Delete Label…", action = function()
                    commands.deleteLabel(tag.name)
                end },
                { label = "Copy Name", action = function()
                    gitgud.setClipboard(tag.name)
                end },
            }, x, y)
        end,
    })
    gitgud.on("LabelsFilterEdit.changed", render)
    gitgud.on("LabelsNewButton.clicked", function()
        commands.newLabel(nil)
    end)
    gitgud.on("LabelsPushButton.clicked", commands.pushLabels)
    app.subscribe("pane.shown", function(id)
        if id == "labels" and stale then
            render()
        end
    end)
end

function labels.refresh()
    stale = true
    render()
end

return labels
