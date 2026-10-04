--- depot/views/depot.lua — the tree pane: Depot and Workspace tabs.
--
--   Depot      the repository's files as of the latest submitted changelist
--              (HEAD), with an icon for each file's state in your workspace
--   Workspace  the working tree: the same, plus untracked files and folders
--
-- Icons: edited (red check), added (red plus), deleted (red cross), not
-- added yet (?), conflicted (!), and out of date (yellow: changed on the
-- branch's upstream since you last got it). The address bar shows the
-- selection's depot path; typing one there walks the tree to it.

local C = require("core.palette")
local actions = require("depot.actions")
local app = require("core.app")
local changelists = require("depot.changelists")
local icons = require("depot.icons")
local log = require("depot.log")
local menu = require("ui.menu")
local repo = require("core.repo")
local selection = require("depot.selection")
local tabs = require("depot.tabs")
local text = require("core.text")
local tree = require("depot.tree")
local util = require("depot.util")

local depot = { name = "depot" }

local TREE = "DepotTree"

local mode = "depot"       -- "depot" | "workspace"
local statusByPath = {}    -- path -> status row
local outdated = {}        -- path -> true (changed upstream)
local expandedIds = {}     -- node id -> true, kept across refreshes

--- The node id for a path in the current mode.
local function idOf(path)
    return mode .. ":" .. path
end

--- A file node.
-- @param path  repository path
-- @param name  display name
-- @param size  bytes (or nil)
-- @return node
local function fileNode(path, name, size)
    local file = statusByPath[path]
    local icon = icons.forStatus(file and file.code)
    if not file and outdated[path] then
        icon = "FileOutdated"
    end
    local suffix = ""
    if file then
        local id = changelists.of(path)
        suffix = icons.actionName(file.code) .. (id ~= 0 and (" (change " .. id .. ")") or "")
    elseif outdated[path] then
        suffix = "out of date"
    end

    return {
        id = idOf(path),
        label = name,
        icon = icon,
        suffix = suffix,
        colour = file and (file.code == "D" and C.dim or C.text) or C.text,
        data = { path = path, folder = false, size = size },
    }
end

--- A folder node.
-- @param path  repository path
-- @param name  display name
-- @return node
local function folderNode(path, name)
    return {
        id = idOf(path),
        label = name,
        icon = "Folder",
        hasChildren = true,
        expanded = expandedIds[idOf(path)] == true,
        data = { path = path, folder = true },
    }
end

--- Children of a folder: the tree at HEAD, plus (in the workspace view)
-- files and folders that only exist locally.
-- @param node  folder node
-- @return array of nodes
local function children(node)
    local dir = node.data.path
    local folders, files = {}, {}
    local seenFolders, seenFiles = {}, {}

    if repo.state().headOid ~= "" then
        for _, entry in ipairs(gitgud.listTree("HEAD", dir) or {}) do
            if entry.isDir then
                folders[#folders + 1] = folderNode(entry.path, entry.name)
                seenFolders[entry.name] = true
            elseif not entry.isSubmodule then
                files[#files + 1] = fileNode(entry.path, entry.name, entry.size)
                seenFiles[entry.path] = true
            end
        end
    end

    -- Changed files the tree doesn't have (added, untracked, renamed).
    local prefix = dir == "" and "" or dir .. "/"
    for path, file in pairs(statusByPath) do
        if path:sub(1, #prefix) == prefix and (mode == "workspace" or file.code ~= "?") then
            local rest = path:sub(#prefix + 1)
            local first, remainder = rest:match("^([^/]+)/(.+)$")
            if first then
                if not seenFolders[first] then
                    seenFolders[first] = true
                    folders[#folders + 1] = folderNode(prefix .. first, first)
                end
            elseif not seenFiles[path] then
                seenFiles[path] = true
                files[#files + 1] = fileNode(path, rest)
            end
        end
    end

    table.sort(folders, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    table.sort(files, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    for _, file in ipairs(files) do
        folders[#folders + 1] = file
    end

    return folders
end

--- Rebuild the roots (after a refresh or a mode switch).
local function rebuild()
    local state = repo.state()
    if not state.open then
        tree.setRoots(TREE, { { id = "none", label = "No workspace open — Connection > Open Workspace…", colour = C.dim } })
        return
    end

    local rootId = idOf("")
    expandedIds[rootId] = true
    local root = {
        id = rootId,
        label = mode == "depot" and selection.depotPath("") or state.path,
        icon = mode == "depot" and "Depot" or "Workspace",
        hasChildren = true,
        expanded = true,
        data = { path = "", folder = true },
    }
    tree.setRoots(TREE, { root })
end

--- Remember which folders are open, so a refresh keeps them.
local function rememberExpanded()
    expandedIds = {}
    for _, entry in ipairs(tree.visible(TREE)) do
        if entry.node.expanded then
            expandedIds[entry.node.id] = true
        end
    end
end

--- The tree's selection as selection items.
-- @param nodes  selected nodes
-- @return items
local function itemsOf(nodes)
    local items = {}
    for _, node in ipairs(nodes) do
        if node.data then
            items[#items + 1] = { path = node.data.path, folder = node.data.folder, source = "tree" }
        end
    end

    return items
end

--- Right-click menu for tree items.
-- @param nodes  selected nodes
-- @return menu items
local function contextMenu(nodes)
    local items = itemsOf(nodes)
    local first = items[1]
    if not first then
        return {}
    end
    local files = util.pathsOf(items)
    local single = #items == 1 and not first.folder
    local file = single and statusByPath[first.path]
    local windows = require("depot.windows")

    return {
        { label = "Get Latest Revision", action = actions.getLatest },
        { label = "Get Revision…", action = function()
            actions.getRevision(first.folder and {} or files)
        end },
        { separator = true },
        { label = "Check Out", enabled = not first.folder, action = function()
            actions.checkOut(files)
        end },
        { label = "Mark for Add…", enabled = file ~= nil and file ~= false and file.code == "?", action = function()
            actions.markForAdd(files)
        end },
        { label = "Mark for Delete", enabled = not first.folder, action = function()
            actions.markForDelete(files)
        end },
        { label = "Rename/Move…", enabled = single, action = function()
            actions.rename(first.path)
        end },
        { label = "Revert", action = actions.revert },
        { separator = true },
        { label = "Diff Against Have Revision", enabled = single and file ~= nil and file ~= false, action = function()
            windows.diffHave(first.path)
        end },
        { label = "Diff Against…", enabled = single, action = function()
            windows.diffAgainstPrompt(first.path)
        end },
        { label = "Folder Diff Against Have Revision", enabled = first.folder, action = function()
            require("depot.windows.folderdiff").open(first.path, "HEAD", "workdir")
        end },
        { separator = true },
        { label = "File History", action = function()
            require("depot.views.history").show(first.path, first.folder)
        end },
        { label = "Time-lapse View", enabled = single, action = function()
            require("depot.windows.timelapse").open(first.path)
        end },
        { label = "Revision Graph", enabled = single, action = function()
            require("depot.windows.revgraph").open(first.path)
        end },
        { separator = true },
        { label = "Show in Explorer", action = function()
            require("core.shell").showInFolder(repo.state().path .. (first.path ~= "" and ("/" .. first.path) or ""))
        end },
        { label = "Open in Editor", enabled = single, action = function()
            require("core.shell").openInEditor(repo.state().path .. "/" .. first.path)
        end },
        { label = "Copy Depot Path", action = function()
            gitgud.setClipboard(selection.depotPath(first.path))
        end },
        { label = "Copy Local Path", action = function()
            gitgud.setClipboard(repo.state().path .. (first.path ~= "" and ("/" .. first.path) or ""))
        end },
        { separator = true },
        { label = "Refresh", shortcut = "f5", action = app.requestRefresh },
    }
end

--- Walk the tree to a path and select it.
-- @param path  repository path ("" = root)
-- @return true when found
function depot.reveal(path)
    local id = idOf("")
    tree.expand(TREE, id)
    local walked = ""
    for part in path:gmatch("[^/]+") do
        walked = walked == "" and part or (walked .. "/" .. part)
        local node = tree.expand(TREE, idOf(walked))
        if not node then
            return false
        end
    end

    return tree.select(TREE, idOf(path))
end

--- Switch between the Depot and Workspace views.
-- @param which  "depot" | "workspace"
function depot.setMode(which)
    rememberExpanded()
    mode = which
    rebuild()
end

--- After every refresh: statuses, out-of-date files, and the tree.
-- @param state  repository snapshot
function depot.refresh(state)
    statusByPath = {}
    for _, file in ipairs(state.files or {}) do
        statusByPath[file.path] = file
    end
    outdated = {}
    local ab = state.aheadBehind or {}
    if state.open and ab.hasUpstream and (ab.behind or 0) > 0 then
        if gitgud.backend() == "p4" then
            -- Perforce: files whose head revision is newer than the one you have.
            for _, file in ipairs(gitgud.p4FileStates("", true) or {}) do
                local deleted = file.headAction == "delete" or file.headAction == "move/delete"
                if file.haveRev < file.headRev and not (deleted and file.haveRev == 0) then
                    outdated[file.path] = true
                end
            end
        else
            for _, file in ipairs(gitgud.changedFiles("HEAD", ab.upstream) or {}) do
                outdated[file.path] = true
            end
        end
    end

    local branch = state.branch ~= "" and state.branch or (state.detached and "detached" or "")
    gitgud.setText("ConnectionButton", icons.inline("Workspace") .. " "
        .. text.colour(C.text, state.open and state.name or "No workspace")
        .. (branch ~= "" and text.colour(C.dim, "   " .. branch) or ""))

    local selected = selection.source() == "tree" and selection.primary()
    rememberExpanded()
    rebuild()
    if selected then
        depot.reveal(selected.path)
    end
end

function depot.init()
    tabs.create("LeftTabs", {
        { id = "depot", label = "Depot", icon = "Depot" },
        { id = "workspace", label = "Workspace", icon = "Workspace" },
    }, depot.setMode)

    tree.create(TREE, {
        multi = true,
        children = children,
        onSelect = function(nodes)
            selection.set("tree", itemsOf(nodes))
        end,
        onActivate = function(node)
            if not node.data or node.data.folder then
                return
            end
            if statusByPath[node.data.path] then
                require("depot.windows").diffHave(node.data.path)
            else
                require("depot.views.history").show(node.data.path, false)
            end
        end,
        onContext = function(nodes, x, y)
            menu.popup(contextMenu(nodes), x, y)
        end,
    })

    gitgud.on("TreeCollapseButton.clicked", function()
        tree.collapseAll(TREE)
    end)
    gitgud.on("TreeFilterButton.clicked", function()
        require("ui.dialog").prompt("Find File", "File name or part of its path", "", "Find", function(query)
            if query == "" then
                return false, "Type part of a file name."
            end
            local found = depot.find(query)
            if not found then
                return false, "No file matches '" .. query .. "'."
            end
            depot.reveal(found)
            return true
        end)
    end)
    gitgud.on("ConnectionButton.clicked", function()
        local x, y, _, h = gitgud.getRect("ConnectionButton")
        require("depot.views.workspaces").switchMenu(x, y + h)
    end)

    -- Address bar: Enter walks to the typed path.
    local go = function()
        local typed = gitgud.getText("AddressEdit")
        local path = selection.fromDepotPath(typed)
        if not path then
            log.warn(typed .. " is not in this workspace (" .. selection.depotPath("") .. ").")
            return
        end
        if not depot.reveal(path) then
            log.warn("No such file or folder: " .. selection.depotPath(path))
        end
    end
    gitgud.on("AddressEdit.accepted", go)
    gitgud.on("AddressGo.clicked", go)

    -- The address bar and status bar follow what's selected in the depot
    -- tree or the Files tab (the address bar belongs to the tree), not
    -- the other tabs.
    app.subscribe("selection.changed", function(items, source)
        if source ~= "tree" and source ~= "files" then
            return
        end
        local path = selection.coveringPath(items)
        gitgud.setText("AddressEdit", path)
        gitgud.setText("StatusPath", text.escape(path))
    end)
    app.subscribe("changelists.changed", function()
        depot.refresh(repo.state())
    end)
end

--- Find a file whose path contains `query` (HEAD's tree, then local files).
-- @param query  text
-- @return path or nil
function depot.find(query)
    local lowered = query:lower()
    for path in pairs(statusByPath) do
        if path:lower():find(lowered, 1, true) then
            return path
        end
    end
    local queue = { "" }
    local visited = 0
    while #queue > 0 and visited < 2000 do
        local dir = table.remove(queue, 1)
        for _, entry in ipairs(gitgud.listTree("HEAD", dir) or {}) do
            visited = visited + 1
            if entry.path:lower():find(lowered, 1, true) then
                return entry.path
            end
            if entry.isDir then
                queue[#queue + 1] = entry.path
            end
        end
    end

    return nil
end

return depot
