--- p4/views/pending.lua — the Pending tab: your pending changelists as a
-- tree. Each changelist lists its open files (edit / add / delete /
-- unresolved) and, once shelved, its shelved files. "Show changelists: All
-- users" adds the shelves other people shared (remote shelf branches).
--
-- Drag files onto another changelist to move them there (Ctrl/Shift+click
-- selects several). Right-click for Submit, Shelve, Unshelve, Revert, Diff,
-- and the rest.

local C = require("core.palette")
local actions = require("p4.actions")
local app = require("core.app")
local changelists = require("p4.changelists")
local commands = require("p4.commands")
local icons = require("p4.icons")
local menu = require("ui.menu")
local panes = require("p4.views.panes")
local repo = require("core.repo")
local selection = require("p4.selection")
local settings = require("core.settings")
local text = require("core.text")
local tree = require("p4.tree")
local util = require("p4.util")

local pending = { name = "pending" }

local TREE = "PendingTree"

local stale = true
local collapsed = {}   -- node id -> true for changelists the user closed

--- A file row under a changelist.
-- @param clId  changelist id
-- @param file  { path, code, opened }
-- @return node
local function fileNode(clId, file)
    local action = file.opened and "edit (unchanged)" or icons.actionName(file.code)
    if file.code == "?" then
        action = changelists.isMarkedForAdd(file.path) and "add" or "not added"
    end

    return {
        id = "f:" .. clId .. ":" .. file.path,
        label = selection.depotPath(file.path),
        icon = file.opened and "FileEdit" or icons.forStatus(file.code == "?" and "A" or file.code),
        suffix = "#" .. action,
        colour = file.code == "U" and C.err or C.text,
        data = { kind = "file", change = clId, path = file.path, code = file.code, opened = file.opened },
    }
end

--- The shelved-files node of a changelist or shelf.
-- @param id     node id
-- @param shelf  { branch, oid, files? }
-- @param owner  changelist id or nil (someone else's)
-- @return node
local function shelfNode(id, shelf, owner, count)
    return {
        id = id,
        label = "Shelved Files",
        icon = "ChangeShelved",
        suffix = "(" .. text.plural(count, "file") .. ")  " .. shelf.branch,
        hasChildren = true,
        expanded = not collapsed[id],
        data = { kind = "shelf", change = owner, shelf = shelf },
    }
end

--- Children of a shelf node: the shelved files.
-- @param node  shelf node
-- @return nodes
local function shelvedFiles(node)
    local shelf = node.data.shelf
    local out = {}
    for _, file in ipairs(actions.shelvedFiles(shelf.oid or shelf.branch)) do
        out[#out + 1] = {
            id = node.id .. ":" .. file.path,
            label = selection.depotPath(file.path),
            icon = "FileShelved",
            suffix = "#" .. icons.actionName(file.code),
            data = { kind = "shelvedFile", change = node.data.change, shelf = shelf, path = file.path, code = file.code },
        }
    end

    return out
end

--- Build the whole tree.
local function build()
    local roots = {}
    local state = repo.state()
    if not state.open then
        tree.setRoots(TREE, { { id = "none", label = "No workspace open.", colour = C.dim } })
        return
    end

    local user = gitgud.config("user.name")
    for _, cl in ipairs(changelists.all()) do
        local id = "cl:" .. cl.id
        local children = {}
        for _, file in ipairs(cl.files) do
            children[#children + 1] = fileNode(cl.id, file)
        end
        if cl.shelf then
            local count = cl.shelf.files and #cl.shelf.files or 0
            children[#children + 1] = shelfNode("shelf:" .. cl.id, cl.shelf, cl.id, count)
        end
        local summary = util.summary(cl.description)
        roots[#roots + 1] = {
            id = id,
            label = cl.id == 0 and "Default" or tostring(cl.id),
            markup = text.colour(C.text, cl.id == 0 and "Default" or tostring(cl.id))
                .. (summary ~= "" and text.colour(C.text2, "   " .. summary) or ""),
            icon = cl.shelf and "ChangeShelved" or (cl.id == 0 and "ChangeDefault" or "ChangePending"),
            suffix = "   " .. text.plural(#cl.files, "file") .. "   " .. user .. "@" .. state.name,
            hasChildren = #children > 0,
            expanded = not collapsed[id],
            children = children,
            activatable = true,
            data = { kind = "changelist", change = cl.id, description = cl.description, shelf = cl.shelf, files = cl.files },
        }
        for _, child in ipairs(children) do
            child.parent = roots[#roots]
        end
    end

    -- Shelves other people shared (and mine from another machine).
    if settings.get("p4.pendingScope", "mine") == "all" then
        local recorded = {}
        for _, cl in ipairs(changelists.all()) do
            if cl.shelf then
                recorded[cl.shelf.branch] = true
            end
        end
        for _, shelf in ipairs(actions.remoteShelves()) do
            if not recorded[shelf.branch] then
                local id = "remote:" .. shelf.remote .. "/" .. shelf.branch
                roots[#roots + 1] = {
                    id = id,
                    markup = text.colour(C.text, shelf.change and tostring(shelf.change) or shelf.branch)
                        .. text.colour(C.text2, "   " .. shelf.summary),
                    icon = "ChangeShelved",
                    suffix = "   " .. shelf.author .. " (shelved, " .. shelf.remote .. ")",
                    hasChildren = true,
                    expanded = collapsed[id] == false,
                    data = { kind = "shelf", shelf = shelf },
                }
            end
        end
    end

    tree.setRoots(TREE, roots)
end

--- Selection items for chosen nodes: files carry their changelist; a
-- changelist stands for its files.
-- @param nodes  selected nodes
-- @return items
local function itemsOf(nodes)
    local items = {}
    for _, node in ipairs(nodes) do
        local data = node.data or {}
        if data.kind == "file" then
            items[#items + 1] = { path = data.path, change = data.change, source = "pending" }
        elseif data.kind == "changelist" then
            if #data.files == 0 then
                items[#items + 1] = { change = data.change, source = "pending" }
            end
            for _, file in ipairs(data.files) do
                items[#items + 1] = { path = file.path, change = data.change, source = "pending" }
            end
        elseif data.kind == "shelvedFile" then
            items[#items + 1] = { path = data.path, change = data.change, shelf = data.shelf.branch, source = "pending" }
        end
    end

    return items
end

--- The details text for a node.
-- @param node  tree node
-- @return text
local function detailsOf(node)
    local data = node and node.data or {}
    local state = repo.state()
    if data.kind == "changelist" then
        local lines = {
            (data.change == 0 and "Default changelist" or ("Change " .. data.change)) .. "   (pending)",
            "Workspace: " .. state.name .. "   Branch: " .. (state.branch ~= "" and state.branch or "(detached)")
                .. "   User: " .. gitgud.config("user.name"),
            "",
            data.description ~= "" and data.description or "(no description)",
            "",
            text.plural(#data.files, "open file") .. ".",
        }
        if data.shelf then
            lines[#lines + 1] = "Shelved on branch " .. data.shelf.branch .. " (" .. util.change(data.shelf.oid) .. ")"
                .. ((data.shelf.pushedTo or "") ~= "" and (", shared on " .. data.shelf.pushedTo) or ", not shared")
                .. "."
        end
        return table.concat(lines, "\n")
    end
    if data.kind == "file" or data.kind == "shelvedFile" then
        return selection.depotPath(data.path) .. "\n" .. "Local: " .. state.path .. "/" .. data.path
            .. "\nChangelist: " .. (data.change == 0 and "default" or tostring(data.change or "-"))
            .. (data.shelf and ("\nShelf: " .. data.shelf.branch) or "")
    end
    if data.kind == "shelf" then
        local shelf = data.shelf
        return "Shelf " .. shelf.branch .. (shelf.remote and (" on " .. shelf.remote) or "") .. "\n"
            .. (shelf.author and ("By " .. shelf.author .. "   " .. util.dateTime(shelf.time) .. "\n") or "")
            .. "\n" .. (shelf.summary or "")
    end

    return ""
end

--- Context menu for the selection.
-- @param nodes  selected nodes
-- @param x      position
-- @param y      position
local function contextMenu(nodes, x, y)
    local node = nodes[1]
    if not node or not node.data then
        return
    end
    local data = node.data
    local items = itemsOf(nodes)
    local paths = util.pathsOf(items)
    local windows = require("p4.windows")

    if data.kind == "shelf" or data.kind == "shelvedFile" then
        local shelf = data.shelf
        local mine = data.change ~= nil
        menu.popup({
            { label = "Unshelve…", action = function()
                actions.unshelve({ branch = shelf.branch, oid = shelf.oid, change = data.change })
            end },
            { label = "Diff Shelved File Against Workspace", enabled = data.kind == "shelvedFile", action = function()
                windows.diffRevisions(data.path, shelf.oid or shelf.branch, data.path, "workdir")
            end },
            { label = "Diff Shelved File Against Its Base", enabled = data.kind == "shelvedFile", action = function()
                local oid = shelf.oid or shelf.branch
                windows.diffRevisions(data.path, oid .. "^", data.path, oid)
            end },
            { label = "Folder Diff of the Shelf", action = function()
                local oid = shelf.oid or shelf.branch
                require("p4.windows.folderdiff").open("", oid .. "^", oid)
            end },
            { separator = true },
            { label = mine and "Share Shelf (Push)" or "Shared on " .. tostring(shelf.remote), enabled = mine and repo.primaryRemote() ~= nil, action = function()
                local remote = repo.primaryRemote()
                require("p4.log").command("git push --force " .. remote .. " " .. shelf.branch)
                gitgud.pushBranch(remote, shelf.branch, { force = true })
                shelf.pushedTo = remote
                changelists.setShelf(data.change, shelf)
            end },
            { label = "Delete Shelved Files…", enabled = mine or shelf.user == actions.userSlug(), action = function()
                actions.deleteShelf({ branch = shelf.branch, change = data.change, pushedTo = shelf.pushedTo,
                    remote = (not mine) and shelf.remote or nil })
            end },
        }, x, y)
        return
    end

    local clId = data.change or 0
    local cl = changelists.get(clId)
    local hasShelf = cl and cl.shelf ~= nil
    local single = data.kind == "file" and #paths == 1 and paths[1]
    menu.popup({
        { label = "Submit…", action = function()
            actions.submit(clId)
        end },
        { label = "Shelve Files…", action = function()
            actions.shelve(clId)
        end },
        { label = "Unshelve Files…", enabled = hasShelf, action = function()
            actions.unshelve({ branch = cl.shelf.branch, oid = cl.shelf.oid, change = clId })
        end },
        { label = "Delete Shelved Files…", enabled = hasShelf, action = function()
            actions.deleteShelf({ branch = cl.shelf.branch, change = clId, pushedTo = cl.shelf.pushedTo })
        end },
        { separator = true },
        { label = "Move to Changelist…", enabled = #paths > 0, action = function()
            actions.moveToChangelistMenu(paths, x, y)
        end },
        { label = "Edit Pending Changelist " .. (clId == 0 and "(new)…" or (clId .. "…")), action = function()
            actions.editChangelist(clId)
        end },
        { label = "New Pending Changelist…", action = function()
            actions.newChangelist(paths)
        end },
        { label = "Delete Pending Changelist", enabled = clId ~= 0, action = function()
            actions.deleteChangelist(clId)
        end },
        { separator = true },
        { label = "Diff Against Have Revision", enabled = single ~= nil and single ~= false, action = function()
            windows.diffHave(single)
        end },
        { label = "Diff Files Against Have Revision", enabled = #paths > 1, action = function()
            require("p4.windows.folderdiff").open("", "HEAD", "workdir", paths)
        end },
        { label = "Resolve…", enabled = #repo.state().conflicts > 0, action = function()
            commands.resolve(single and { single } or nil)
        end },
        { label = "Mark for Add", enabled = single and repo.file(single) ~= nil and repo.file(single).code == "?", action = function()
            actions.markForAdd({ single }, clId)
        end },
        { label = "Revert Files…", enabled = #paths > 0, action = function()
            actions.revert(paths)
        end },
        { label = "Revert Unchanged Files", action = function()
            actions.revertUnchanged()
        end },
        { separator = true },
        { label = "File History", enabled = single ~= nil and single ~= false, action = function()
            require("p4.views.history").show(single, false)
        end },
        { label = "Open in Editor", enabled = single ~= nil and single ~= false, action = function()
            require("core.shell").openInEditor(repo.state().path .. "/" .. single)
        end },
        { label = "Show in Explorer", enabled = single ~= nil and single ~= false, action = function()
            require("core.shell").showInFolder(repo.state().path .. "/" .. single)
        end },
    }, x, y)
end

--- Rebuild when visible.
local function render()
    if not panes.isShown("pending") then
        stale = true
        return
    end
    stale = false
    build()
    gitgud.setText("PendingScopeButton", settings.get("p4.pendingScope", "mine") == "all"
        and ("All users (with shared shelves)" .. icons.dropdown()) or ("Mine" .. icons.dropdown()))
end

function pending.init()
    tree.create(TREE, {
        multi = true,
        children = shelvedFiles,
        onSelect = function(nodes)
            selection.set("pending", itemsOf(nodes))
            gitgud.setText("PendingDetailText", detailsOf(nodes[1]))
        end,
        onActivate = function(node)
            local data = node.data or {}
            if data.kind == "file" then
                if data.opened then
                    require("p4.views.history").show(data.path, false)
                else
                    require("p4.windows").diffHave(data.path)
                end
            elseif data.kind == "changelist" then
                actions.editChangelist(data.change)
            elseif data.kind == "shelvedFile" then
                local oid = data.shelf.oid or data.shelf.branch
                require("p4.windows").diffRevisions(data.path, oid .. "^", data.path, oid)
            end
        end,
        onContext = contextMenu,
        onToggle = function(node)
            collapsed[node.id] = not node.expanded
        end,
        onDrag = function(from, to)
            local target = to.data and to.data.change
            if not from.data or from.data.kind ~= "file" or target == nil or target == from.data.change then
                return
            end
            -- Dragging one of several selected files moves them all.
            local moving = {}
            for _, item in ipairs(selection.items()) do
                if item.path and item.change ~= nil and not item.shelf then
                    moving[#moving + 1] = item.path
                end
            end
            local included = false
            for _, path in ipairs(moving) do
                included = included or path == from.data.path
            end
            if not included then
                moving = { from.data.path }
            end
            changelists.move(moving, target)
            require("p4.log").info(text.plural(#moving, "file") .. " moved to "
                .. (target == 0 and "the default changelist" or ("change " .. target)) .. ".")
        end,
    })

    gitgud.on("PendingNewButton.clicked", function()
        actions.newChangelist({})
    end)
    gitgud.on("PendingScopeButton.clicked", function()
        local x, y, _, h = gitgud.getRect("PendingScopeButton")
        menu.popup({
            { label = "Mine", checked = settings.get("p4.pendingScope", "mine") == "mine", action = function()
                settings.set("p4.pendingScope", "mine")
                render()
            end },
            { label = "All users (with shared shelves)", checked = settings.get("p4.pendingScope", "mine") == "all", action = function()
                settings.set("p4.pendingScope", "all")
                render()
            end },
        }, x, y + h)
    end)

    require("p4.frame").splitPanel({
        bar = "PendingSplit",
        container = "PendingPanel",
        top = "PendingTree",
        bottom = "PendingDetailText",
        offset = 30,
        setting = "p4.pendingSplit",
        default = 0.72,
        inset = 4,
    })

    app.subscribe("changelists.changed", render)
    app.subscribe("pane.shown", function(id)
        if id == "pending" and stale then
            render()
        end
    end)
end

function pending.refresh()
    changelists.prune()
    render()
end

return pending
