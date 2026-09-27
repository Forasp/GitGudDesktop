--- depot/views/changedetails.lua — the Details / Files pane under the History
-- and Submitted tables: a submitted changelist's description and metadata,
-- and the files it changed (double-click one to diff it).
--
--     local details = changedetails.create("History")   -- widgets History*
--     details.show(commit)                              -- a history row, or nil

local grid = require("depot.grid")
local icons = require("depot.icons")
local selection = require("depot.selection")
local tabs = require("depot.tabs")
local util = require("depot.util")

local changedetails = {}

--- The Details text of a changelist.
-- @param commit  history row
-- @return plain text
local function detailsText(commit)
    local labels = {}
    for _, ref in ipairs(gitgud.refLabels() or {}) do
        if ref.oid == commit.oid then
            labels[#labels + 1] = ref.name
        end
    end
    local parents = {}
    for _, parent in ipairs(commit.parents) do
        parents[#parents + 1] = util.change(parent)
    end

    return "Change:      " .. commit.oid .. "\n"
        .. "Date:        " .. util.dateTime(commit.time) .. "\n"
        .. "User:        " .. commit.author .. " <" .. commit.email .. ">\n"
        .. (#labels > 0 and ("Labels:      " .. table.concat(labels, ", ") .. "\n") or "")
        .. "Parents:     " .. (#parents > 0 and table.concat(parents, ", ") or "(none)") .. "\n\n"
        .. commit.message
end

--- Build the pane for a prefix: expects <prefix>DetailTabs,
-- <prefix>DetailText, and <prefix>FilesHost in the layout.
-- @param prefix  e.g. "History"
-- @return { show = function(commit), layout = function() }
function changedetails.create(prefix)
    local filesGrid = prefix .. "FilesGrid"

    grid.create(filesGrid, prefix .. "FilesHost", {
        columns = {
            { key = "path", title = "File", width = 460 },
            { key = "action", title = "Action" },
        },
        multi = true,
        emptyText = "No files.",
        onActivate = function(row)
            local commit = row.data.commit
            require("depot.windows").diffRevisions(row.data.oldPath, commit.oid .. "^", row.data.path, commit.oid)
        end,
        onContext = function(rows, x, y)
            local row = rows[1]
            if not row then
                return
            end
            local commit = row.data.commit
            require("ui.menu").popup({
                { label = "Diff Against Previous Revision", action = function()
                    require("depot.windows").diffRevisions(row.data.oldPath, commit.oid .. "^", row.data.path, commit.oid)
                end },
                { label = "Diff Against Workspace File", action = function()
                    require("depot.windows").diffRevisions(row.data.path, commit.oid, row.data.path, "workdir")
                end },
                { label = "File History", action = function()
                    require("depot.views.history").show(row.data.path, false)
                end },
                { label = "Time-lapse View", action = function()
                    require("depot.windows.timelapse").open(row.data.path, commit.oid)
                end },
                { label = "Revision Graph", action = function()
                    require("depot.windows.revgraph").open(row.data.path)
                end },
                { label = "Get This Revision", action = function()
                    require("depot.actions").getRevision({ row.data.path }, commit.oid)
                end },
            }, x, y)
        end,
    })

    tabs.create(prefix .. "DetailTabs", {
        { id = "details", label = "Details" },
        { id = "files", label = "Files" },
    }, function(id)
        gitgud.setVisible(prefix .. "DetailText", id == "details")
        gitgud.setVisible(prefix .. "FilesHost", id == "files")
        grid.layout(filesGrid)
    end)

    local pane = {}

    --- Show a changelist (or clear with nil).
    -- @param commit  history row
    function pane.show(commit)
        if not commit then
            gitgud.setText(prefix .. "DetailText", "")
            grid.setRows(filesGrid, {})
            return
        end
        gitgud.setText(prefix .. "DetailText", detailsText(commit))
        local base = #commit.parents > 0 and (commit.oid .. "^") or ""
        local rows = {}
        for _, file in ipairs(gitgud.changedFiles(base, commit.oid) or {}) do
            rows[#rows + 1] = {
                icon = icons.inline(icons.forStatus(file.status)),
                cells = {
                    path = selection.depotPath(file.path),
                    action = icons.actionName(file.status),
                },
                data = { path = file.path, oldPath = file.oldPath, status = file.status, commit = commit },
            }
        end
        grid.setRows(filesGrid, rows)
    end

    return pane
end

return changedetails
