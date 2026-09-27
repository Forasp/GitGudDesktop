--- depot/views/files.lua — the Files tab: the folder selected in the tree (or
-- the folder of the selected file) as a table — name, action, changelist,
-- type, size, and state.

local C = require("core.palette")
local actions = require("depot.actions")
local app = require("core.app")
local changelists = require("depot.changelists")
local grid = require("depot.grid")
local icons = require("depot.icons")
local menu = require("ui.menu")
local panes = require("depot.views.panes")
local repo = require("core.repo")
local selection = require("depot.selection")
local settings = require("core.settings")
local text = require("core.text")
local util = require("depot.util")

local files = { name = "files" }

local GRID = "FilesGrid"

local folder = ""   -- the folder shown

--- Rebuild the table for the current folder.
local function render()
    if not panes.isShown("files") then
        return
    end
    local state = repo.state()
    gitgud.setText("FilesTitle", text.colour(C.text, "Files in " .. selection.depotPath(folder)))
    if not state.open then
        grid.setRows(GRID, {})
        return
    end

    local byPath = {}
    for _, file in ipairs(state.files) do
        byPath[file.path] = file
    end
    local showUntracked = settings.get("depot.filesUntracked", false)

    local rows = {}
    local seen = {}
    local function add(path, name, isDir, size)
        seen[path] = true
        local file = byPath[path]
        local icon = isDir and "Folder" or icons.forStatus(file and file.code)
        local id = (not isDir and file) and changelists.of(path) or nil
        rows[#rows + 1] = {
            icon = icons.inline(icon),
            cells = {
                name = name,
                action = file and icons.actionName(file.code) or "",
                change = id and (id == 0 and "default" or tostring(id)) or "",
                type = isDir and "folder" or util.fileType(path),
                size = isDir and "" or (size and util.size(size) or ""),
            },
            sort = { name = (isDir and "0" or "1") .. name:lower(), size = size or 0 },
            data = { path = path, folder = isDir },
        }
    end

    if state.headOid ~= "" then
        for _, entry in ipairs(gitgud.listTree("HEAD", folder) or {}) do
            if not entry.isSubmodule then
                add(entry.path, entry.name, entry.isDir, entry.size)
            end
        end
    end
    local prefix = folder == "" and "" or folder .. "/"
    for path, file in pairs(byPath) do
        if path:sub(1, #prefix) == prefix and not seen[path] and (file.code ~= "?" or showUntracked) then
            local rest = path:sub(#prefix + 1)
            local first = rest:match("^([^/]+)/")
            if first then
                if not seen[prefix .. first] then
                    add(prefix .. first, first, true)
                end
            else
                add(path, rest, false)
            end
        end
    end

    grid.setRows(GRID, rows, function(row)
        return row.data.path
    end)
end

--- Show a folder.
-- @param path  folder path ("" = root)
function files.show(path)
    folder = path or ""
    render()
end

function files.init()
    grid.create(GRID, "FilesGridHost", {
        columns = {
            { key = "name", title = "Name", width = 280 },
            { key = "action", title = "Action", width = 90 },
            { key = "change", title = "Change", width = 70 },
            { key = "type", title = "Type", width = 70 },
            { key = "size", title = "Size" },
        },
        multi = true,
        sortKey = "name",
        emptyText = "This folder is empty.",
        onSelect = function(rows)
            local items = {}
            for _, row in ipairs(rows) do
                items[#items + 1] = { path = row.data.path, folder = row.data.folder, source = "files" }
            end
            selection.set("files", items)
        end,
        onActivate = function(row)
            if row.data.folder then
                files.show(row.data.path)
                require("depot.views.depot").reveal(row.data.path)
            elseif repo.file(row.data.path) then
                require("depot.windows").diffHave(row.data.path)
            else
                require("depot.views.history").show(row.data.path, false)
            end
        end,
        onContext = function(rows, x, y)
            local paths = {}
            for _, row in ipairs(rows) do
                if not row.data.folder then
                    paths[#paths + 1] = row.data.path
                end
            end
            local single = #rows == 1 and not rows[1].data.folder and rows[1].data.path
            menu.popup({
                { label = "Check Out", enabled = #paths > 0, action = function()
                    actions.checkOut(paths)
                end },
                { label = "Mark for Add…", enabled = #paths > 0, action = function()
                    actions.markForAdd(paths)
                end },
                { label = "Mark for Delete", enabled = #paths > 0, action = function()
                    actions.markForDelete(paths)
                end },
                { label = "Revert", enabled = #paths > 0, action = function()
                    actions.revert(paths)
                end },
                { separator = true },
                { label = "Diff Against Have Revision", enabled = single and repo.file(single) ~= nil, action = function()
                    require("depot.windows").diffHave(single)
                end },
                { label = "File History", enabled = #rows == 1, action = function()
                    require("depot.views.history").show(rows[1].data.path, rows[1].data.folder)
                end },
                { label = "Time-lapse View", enabled = single ~= false and single ~= nil, action = function()
                    require("depot.windows.timelapse").open(single)
                end },
                { label = "Revision Graph", enabled = single ~= false and single ~= nil, action = function()
                    require("depot.windows.revgraph").open(single)
                end },
                { separator = true },
                { label = "Open in Editor", enabled = single ~= false and single ~= nil, action = function()
                    require("core.shell").openInEditor(repo.state().path .. "/" .. single)
                end },
                { label = "Show in Explorer", action = function()
                    require("core.shell").showInFolder(repo.state().path .. "/" .. rows[1].data.path)
                end },
            }, x, y)
        end,
    })

    gitgud.setChecked("FilesShowUntracked", settings.get("depot.filesUntracked", false))
    gitgud.on("FilesShowUntracked.toggled", function(value)
        settings.set("depot.filesUntracked", value == "1")
        render()
    end)

    app.subscribe("selection.changed", function(items, source)
        if source ~= "tree" then
            return
        end
        local first = items[1]
        if first then
            folder = first.folder and first.path or text.dirname(first.path)
            render()
        end
    end)
    app.subscribe("pane.shown", function(id)
        if id == "files" then
            render()
        end
    end)
end

function files.refresh()
    render()
end

return files
