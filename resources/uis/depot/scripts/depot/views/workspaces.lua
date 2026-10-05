--- depot/views/workspaces.lua — the Workspaces tab. A workspace is a
-- client mapping of the depot onto your disk; here it's a working tree:
-- this repository's worktrees plus every other repository you've opened.
-- Double-click one to switch to it; the connection button above the tree
-- offers the same list.

local C = require("core.palette")
local app = require("core.app")
local grid = require("depot.grid")
local icons = require("depot.icons")
local log = require("depot.log")
local menu = require("ui.menu")
local panes = require("depot.views.panes")
local repo = require("core.repo")
local repositories = require("views.repositories")
local text = require("core.text")

local workspaces = { name = "workspaces" }

local GRID = "WorkspacesGrid"
local stale = true

--- Normalise a path for comparison.
local function key(path)
    return require("core.shell").pathKey(path)
end

--- Every workspace: this repository's worktrees, then known repositories.
-- @return array of { name, path, branch, kind, current }
local function list()
    local out = {}
    local seen = {}
    local here = key(repo.state().path)
    if repo.state().open then
        for _, tree in ipairs(gitgud.worktrees() or {}) do
            seen[key(tree.path)] = true
            out[#out + 1] = {
                name = tree.main and repo.state().name or tree.name,
                path = tree.path,
                branch = tree.branch,
                kind = tree.main and "repository" or (tree.valid and "worktree" or "worktree (missing)"),
                current = key(tree.path) == here,
                worktree = not tree.main and tree.name or nil,
            }
        end
    end
    for _, path in ipairs(repositories.known()) do
        if not seen[key(path)] then
            out[#out + 1] = { name = text.basename(path), path = path, branch = "", kind = "repository",
                current = key(path) == here }
        end
    end

    return out
end

local function render()
    if not panes.isShown("workspaces") then
        stale = true
        return
    end
    stale = false
    local rows = {}
    for _, ws in ipairs(list()) do
        rows[#rows + 1] = {
            icon = icons.inline(ws.worktree and "Worktree" or "Workspace"),
            cells = {
                name = ws.current and { markup = text.colour(C.link, ws.name .. "  (current)") } or ws.name,
                root = ws.path,
                branch = ws.branch or "",
                kind = ws.kind,
            },
            data = ws,
        }
    end
    grid.setRows(GRID, rows)
end

--- Switch to a workspace.
-- @param ws  a list() entry
local function open(ws)
    if ws.current then
        return
    end
    log.command("cd " .. log.quote(ws.path))
    repositories.open(ws.path)
end

--- The connection button's menu: every workspace, plus open/clone/new.
-- @param x  position
-- @param y  position
function workspaces.switchMenu(x, y)
    local items = { { label = "Switch Workspace", enabled = false } }
    for _, ws in ipairs(list()) do
        items[#items + 1] = {
            label = ws.name .. "   " .. text.truncateLeft(ws.path, 48),
            checked = ws.current,
            action = function()
                open(ws)
            end,
        }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Open Workspace…", action = repositories.addExisting }
    items[#items + 1] = { label = "Clone…", action = repositories.clone }
    items[#items + 1] = { label = "New Workspace (Repository)…", action = repositories.create }
    menu.popup(items, x, y)
end

function workspaces.init()
    grid.create(GRID, "WorkspacesGridHost", {
        columns = {
            { key = "name", title = "Workspace", width = 200 },
            { key = "root", title = "Root", width = 380 },
            { key = "branch", title = "Branch", width = 140 },
            { key = "kind", title = "Type" },
        },
        emptyText = "No workspaces yet: Open Existing or Clone one.",
        onActivate = function(row)
            open(row.data)
        end,
        onContext = function(rows, x, y)
            local ws = rows[1] and rows[1].data
            if not ws then
                return
            end
            menu.popup({
                { label = "Switch to This Workspace", enabled = not ws.current, action = function()
                    open(ws)
                end },
                { label = "Show in " .. require("core.shell").names.fileManager, action = function()
                    require("core.shell").showInFolder(ws.path)
                end },
                { label = "Open Terminal Here", action = function()
                    require("core.shell").openTerminal(ws.path)
                end },
                { separator = true },
                { label = "Delete Worktree…", enabled = ws.worktree ~= nil and not ws.current, action = function()
                    require("ui.dialog").confirm("Delete Worktree " .. ws.name,
                        "Delete the worktree folder " .. ws.path .. "? (Refused if it has pending changes.)",
                        "Delete", function()
                            log.command("git worktree remove " .. log.quote(ws.worktree))
                            log.report("Worktree deleted.", gitgud.removeWorktree(ws.worktree))
                            app.requestRefresh()
                        end, true)
                end },
                { label = "Remove from List", enabled = ws.worktree == nil and not ws.current, action = function()
                    repositories.remove(ws.path)
                    render()
                end },
            }, x, y)
        end,
    })

    gitgud.on("WorkspacesAddButton.clicked", repositories.addExisting)
    gitgud.on("WorkspacesCloneButton.clicked", repositories.clone)
    gitgud.on("WorkspacesNewButton.clicked", function()
        if repo.state().headOid == "" then
            log.warn("Submit a first changelist before adding worktrees.")
            return
        end
        require("ui.dialog").show({
            title = "New Worktree",
            message = "A second workspace for this repository, on its own branch, in its own folder.",
            fields = {
                { label = "Name", value = "" },
                { label = "Folder", value = text.dirname(repo.state().path), browse = true },
                { label = "Branch (created from the current one if new)", value = "" },
            },
            ok = "Create",
            onOk = function(v)
                local name = text.trim(v.fields[1])
                local folder = text.trim(v.fields[2])
                local branch = text.trim(v.fields[3])
                if name == "" or folder == "" then
                    return false, "Enter a name and a folder."
                end
                local path = folder:gsub("[/\\]+$", "") .. "/" .. name
                log.command("git worktree add " .. log.quote(path) .. " " .. (branch ~= "" and branch or name))
                local ok, err = gitgud.addWorktree(name, path, branch ~= "" and branch or name)
                if not ok then
                    return false, err
                end
                log.info("Worktree " .. name .. " created at " .. path .. ".")
                render()
                return true
            end,
        })
    end)
    app.subscribe("pane.shown", function(id)
        if id == "workspaces" and stale then
            render()
        end
    end)
end

function workspaces.refresh()
    stale = true
    render()
end

return workspaces
