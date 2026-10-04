--- depot/menus.lua — the menu bar: File, Edit, Search, View, Actions,
-- Connection, Tools, Window, Help, with the familiar keyboard shortcuts where they
-- make sense. Built on the shared ui/menu (menus are data: mods add items
-- with menu.addItem("actions", {...})); every item is also in the command
-- palette (Ctrl+K).

local actions = require("depot.actions")
local app = require("core.app")
local commands = require("depot.commands")
local dialog = require("ui.dialog")
local frame = require("depot.frame")
local menu = require("ui.menu")
local panes = require("depot.views.panes")
local repo = require("core.repo")
local selection = require("depot.selection")
local settings = require("core.settings")
local shell = require("core.shell")
local text = require("core.text")
local undo = require("core.undo")

local menus = { name = "depotmenus" }

local function isOpen()
    return repo.state().open
end

local function hasFiles()
    return isOpen() and #selection.files() > 0
end

local function oneFile()
    return isOpen() and #selection.files() == 1
end

local function hasRemote()
    return isOpen() and repo.primaryRemote() ~= nil
end

--- A Perforce workspace (p4-only commands show; Git-only ones hide).
local function isP4()
    return gitgud.backend() == "p4"
end

local function isGit()
    return not isP4()
end

--- Preferences (Edit > Preferences…): identity, this UI's options, and the
-- way to another interface.
function menus.preferences()
    dialog.show({
        title = "Preferences",
        width = 580,
        fields = {
            { label = "Name (for your changelists)", value = gitgud.globalConfig("user.name") },
            { label = "Email", value = gitgud.globalConfig("user.email") },
            { label = "Shelf branches ({user} is your user name)", value = settings.get("depot.shelfPrefix", "shelves/{user}/") },
            { label = 'External editor command — e.g. code "%s" (blank: the default program)', value = settings.get("editorCommand", "") },
        },
        checks = {
            { label = "Show new (untracked) files in the default changelist", value = settings.get("depot.untrackedInPending", false) },
            { label = "Share shelves by default (push the shelf branch)", value = settings.get("depot.pushShelves", true) },
            { label = "Ask before reverting files", value = settings.get("confirmDiscard", true) },
            { label = "Check for updates automatically", value = settings.get("updateCheck", true) },
        },
        alt = {
            label = "Switch User Interface…",
            action = function()
                require("views.settings").switchInterface()
            end,
        },
        ok = "OK",
        onOk = function(v)
            local identity = { { "user.name", text.trim(v.fields[1]) }, { "user.email", text.trim(v.fields[2]) } }
            for _, entry in ipairs(identity) do
                if entry[2] ~= gitgud.globalConfig(entry[1]) then
                    local ok, err = gitgud.setGlobalConfig(entry[1], entry[2])
                    if not ok then
                        return false, err
                    end
                end
            end
            local prefix = text.trim(v.fields[3])
            if prefix == "" then
                prefix = "shelves/{user}/"
            end
            if not prefix:match("/$") then
                prefix = prefix .. "/"
            end
            settings.set("depot.shelfPrefix", prefix)
            settings.set("editorCommand", text.trim(v.fields[4]))
            settings.set("depot.untrackedInPending", v.checks[1])
            settings.set("depot.pushShelves", v.checks[2])
            settings.set("confirmDiscard", v.checks[3])
            settings.set("updateCheck", v.checks[4])
            app.requestRefresh()
            return true
        end,
    })
end

local function fileMenu()
    menu.addMenu("file", "File")
    menu.addItems("file", {
        { label = "New Pending Changelist…", shortcut = "ctrl+n", enabled = isOpen, action = function()
            actions.newChangelist({})
        end },
        { label = "New Branch…", enabled = isOpen, action = function()
            commands.newBranch(nil)
        end },
        { label = "New Label…", enabled = isOpen, action = function()
            commands.newLabel(nil)
        end },
        { separator = true },
        { label = "Open Workspace…", shortcut = "ctrl+o", action = require("views.repositories").addExisting },
        { label = "Clone Workspace…", shortcut = "ctrl+shift+o", action = require("views.repositories").clone },
        { label = "New Workspace (Repository)…", action = require("views.repositories").create },
        { label = "Switch Workspace…", action = function()
            require("depot.views.workspaces").switchMenu(40, 30)
        end },
        { separator = true },
        { label = "Open File in Editor", enabled = oneFile, action = function()
            shell.openInEditor(repo.state().path .. "/" .. selection.files()[1])
        end },
        { label = "Show in Explorer", enabled = isOpen, action = function()
            local item = selection.primary()
            shell.showInFolder(repo.state().path .. ((item and item.path and item.path ~= "") and ("/" .. item.path) or ""))
        end },
        { separator = true },
        { label = "Switch User Interface…", action = function()
            require("views.settings").switchInterface()
        end },
        { separator = true },
        { label = "Exit", shortcut = "alt+f4", action = function()
            gitgud.emit("window.close", "")
        end },
    })
end

local function editMenu()
    menu.addMenu("edit", "Edit")
    menu.addItems("edit", {
        { label = "Undo", shortcut = "ctrl+z", enabled = function()
            return undo.peekUndo() ~= nil and not gitgud.textInputFocused()
        end, action = function()
            require("depot.log").report("Undone.", undo.undo())
            app.requestRefresh()
        end },
        { label = "Redo", shortcut = "ctrl+y", enabled = function()
            return undo.peekRedo() ~= nil and not gitgud.textInputFocused()
        end, action = function()
            require("depot.log").report("Redone.", undo.redo())
            app.requestRefresh()
        end },
        { separator = true },
        { label = "Copy Depot Path", shortcut = "ctrl+shift+c", enabled = function()
            return selection.primary() ~= nil and selection.primary().path ~= nil
        end, action = function()
            local paths = {}
            for _, item in ipairs(selection.items()) do
                if item.path then
                    paths[#paths + 1] = selection.depotPath(item.path)
                end
            end
            gitgud.setClipboard(table.concat(paths, "\n"))
        end },
        { label = "Edit Pending Changelist…", enabled = function()
            local item = selection.primary()
            return item ~= nil and item.change ~= nil
        end, action = function()
            actions.editChangelist(selection.primary().change)
        end },
        { separator = true },
        { label = "Preferences…", shortcut = "ctrl+,", action = menus.preferences },
    })
end

local function searchMenu()
    menu.addMenu("search", "Search")
    menu.addItems("search", {
        { label = "Find File…", shortcut = "ctrl+f", enabled = isOpen, action = function()
            gitgud.emit("TreeFilterButton.clicked", "")
        end },
        { label = "Go to Depot Path…", shortcut = "ctrl+l", enabled = isOpen, action = function()
            gitgud.focus("AddressEdit")
        end },
        { label = "Go to Changelist…", shortcut = "ctrl+g", enabled = isOpen, action = function()
            dialog.prompt("Go to Changelist", "Change id (the first digits are enough), label, or branch", "", "Go",
                function(value)
                    local found = (gitgud.history({ max = 1, from = value }) or {})[1]
                    if not found then
                        return false, "No changelist '" .. value .. "'."
                    end
                    require("depot.views.submitted").reveal(found.oid)
                    return true
                end)
        end },
        { label = "Command Palette…", shortcut = "ctrl+k", action = require("ui.commands").open },
    })
end

local function viewMenu()
    menu.addMenu("view", "View")
    local items = {}
    for _, tab in ipairs(panes.tabs()) do
        local id = tab.id
        items[#items + 1] = {
            label = tab.label,
            checked = function()
                return panes.tabVisible(id)
            end,
            action = function()
                if panes.tabVisible(id) and not panes.isShown(id) then
                    panes.show(id)
                else
                    panes.toggleTab(id)
                end
            end,
        }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Toolbar", checked = frame.toolbarVisible, action = frame.toggleToolbar }
    items[#items + 1] = { label = "Address Bar", checked = frame.addressVisible, action = frame.toggleAddress }
    items[#items + 1] = { label = "Tree Pane", shortcut = "ctrl+shift+l", checked = frame.leftVisible, action = frame.toggleLeft }
    items[#items + 1] = { label = "Log Pane", shortcut = "ctrl+j", checked = frame.bottomVisible, action = frame.toggleBottom }
    items[#items + 1] = { label = "Dashboard", action = function()
        if not frame.bottomVisible() then
            frame.toggleBottom()
        end
        panes.showBottom("dashboard")
    end }
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Depot Tree", shortcut = "ctrl+1", action = function()
        require("depot.tabs").select("LeftTabs", "depot")
    end }
    items[#items + 1] = { label = "Workspace Tree", shortcut = "ctrl+2", action = function()
        require("depot.tabs").select("LeftTabs", "workspace")
    end }
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Refresh", shortcut = "f5", action = app.requestRefresh }
    menu.addItems("view", items)
end

local function actionsMenu()
    menu.addMenu("actions", "Actions")
    menu.addItems("actions", {
        { label = "Get Latest Revision", shortcut = "ctrl+shift+g", enabled = isOpen, action = function() actions.getLatest() end },
        { label = "Get Revision…", enabled = isOpen, action = function()
            actions.getRevision()
        end },
        { separator = true },
        { label = "Check Out", shortcut = "ctrl+e", enabled = hasFiles, action = function()
            actions.checkOut()
        end },
        { label = "Mark for Add", enabled = hasFiles, action = function()
            actions.markForAdd()
        end },
        { label = "Mark for Delete", enabled = hasFiles, action = function()
            actions.markForDelete()
        end },
        { label = "Rename/Move…", enabled = oneFile, action = function()
            actions.rename()
        end },
        { label = "Revert Files…", shortcut = "ctrl+r", enabled = isOpen, action = function()
            actions.revert()
        end },
        { label = "Revert Unchanged Files", enabled = isOpen, action = function()
            actions.revertUnchanged()
        end },
        { label = "Reconcile Offline Work…", visible = isP4, enabled = isOpen, action = function()
            actions.reconcile(selection.files())
        end },
        { label = "Lock", visible = isP4, enabled = hasFiles, action = function()
            actions.lock(nil, true)
        end },
        { label = "Unlock", visible = isP4, enabled = hasFiles, action = function()
            actions.lock(nil, false)
        end },
        { separator = true },
        { label = "Submit…", shortcut = "ctrl+s", enabled = isOpen, action = function()
            actions.submit()
        end },
        { label = "Shelve…", enabled = isOpen, action = function()
            actions.shelve()
        end },
        { label = "Unshelve…", enabled = function()
            local item = selection.primary()
            local cl = item and item.change and require("depot.changelists").get(item.change)
            return cl ~= nil and cl.shelf ~= nil
        end, action = function()
            local cl = require("depot.changelists").get(selection.primary().change)
            actions.unshelve({ branch = cl.shelf.branch, oid = cl.shelf.oid, change = cl.id })
        end },
        { label = "Resolve…", enabled = function()
            return isOpen() and #repo.state().conflicts > 0
        end, action = function()
            commands.resolve()
        end },
        { label = "Abort Merge/Rebase", enabled = function()
            return isOpen() and repo.state().operation ~= "none"
        end, action = commands.abort },
        { separator = true },
        { label = "Diff Against Have Revision", shortcut = "ctrl+d", enabled = oneFile, action = function()
            require("depot.windows").diffSelection()
        end },
        { label = "Diff Against…", shortcut = "ctrl+shift+d", enabled = oneFile, action = function()
            require("depot.windows").diffAgainstPrompt(selection.files()[1])
        end },
        { label = "Folder Diff Against Have Revision", enabled = isOpen, action = function()
            local item = selection.primary()
            require("depot.windows.folderdiff").open(item and item.folder and item.path or "", "HEAD", "workdir")
        end },
        { label = "File History", shortcut = "ctrl+t", enabled = function()
            return isOpen() and selection.primary() ~= nil and selection.primary().path ~= nil
        end, action = function()
            local item = selection.primary()
            require("depot.views.history").show(item.path, item.folder)
        end },
        { label = "Time-lapse View", shortcut = "ctrl+shift+t", enabled = oneFile, action = function()
            require("depot.windows.timelapse").open(selection.files()[1])
        end },
        { label = "Revision Graph", shortcut = "ctrl+shift+r", enabled = oneFile, action = function()
            require("depot.windows.revgraph").open(selection.files()[1])
        end },
        { separator = true },
        { label = "Merge/Integrate…", shortcut = "ctrl+shift+i", enabled = isOpen, action = function()
            commands.integrate()
        end },
        { label = "Compare Branches…", enabled = isOpen, action = function()
            dialog.prompt("Compare Branches", "Compare the workspace's branch with", "", "Compare", function(value)
                if value == "" then
                    return false, "Enter a branch or label."
                end
                commands.compare(value, "HEAD")
                return true
            end)
        end },
    })
end

local function connectionMenu()
    menu.addMenu("connection", "Connection")
    menu.addItems("connection", {
        { label = "Fetch", shortcut = "ctrl+shift+f", visible = isGit, enabled = hasRemote, action = commands.fetch },
        { label = "Get Latest (Pull)", enabled = hasRemote, action = function() actions.getLatest() end },
        { label = "Push", shortcut = "ctrl+p", visible = isGit, enabled = hasRemote, action = commands.push },
        { label = "Force Push…", visible = isGit, enabled = hasRemote, action = commands.forcePush },
        { label = "Push Labels", visible = isGit, enabled = hasRemote, action = commands.pushLabels },
        { separator = true },
        { label = "Remotes…", visible = isGit, enabled = isOpen, action = commands.remotes },
        { label = "SSH Keys…", visible = isGit, action = require("views.ssh").keys },
        { separator = true },
        { label = "Open Workspace…", action = require("views.repositories").addExisting },
        { label = "New Perforce Workspace…", action = function()
            require("views.repositories").p4Workspace(false)
        end },
        { label = "New Perforce Stream…", action = function()
            require("views.repositories").p4Workspace(true)
        end },
        { label = "Git or Perforce by Default…", action = function()
            require("core.p4setup").askDefaultBackend(nil)
        end },
        { label = "Switch Workspace…", action = function()
            require("depot.views.workspaces").switchMenu(120, 30)
        end },
    })
end

local function toolsMenu()
    menu.addMenu("tools", "Tools")
    menu.addItems("tools", {
        { label = "Open Terminal in Workspace", shortcut = "ctrl+`", enabled = isOpen, action = function()
            shell.openTerminal(repo.state().path)
        end },
        { label = "Show Workspace in Explorer", enabled = isOpen, action = function()
            shell.showInFolder(repo.state().path)
        end },
        { separator = true },
        { label = "Stash Pending Changes", enabled = function()
            return isOpen() and #repo.state().files > 0
        end, action = function()
            require("depot.log").command("git stash push --include-untracked")
            require("depot.log").report("Pending changes stashed.", gitgud.stashSave("Depot: stashed pending changes"))
            app.requestRefresh()
        end },
        { label = "Restore Stashed Changes", enabled = function()
            return isOpen() and #repo.state().stashes > 0
        end, action = function()
            require("depot.log").command("git stash pop")
            require("depot.log").report("Stashed changes restored.", gitgud.stashPop(1))
            app.requestRefresh()
        end },
        { separator = true },
        { label = "Git LFS: Track Files…", enabled = isOpen, action = require("views.lfs").trackPrompt },
        { label = "Git LFS: Pull Files", enabled = isOpen, action = require("views.lfs").pull },
        { label = "Commit Signing…", action = require("views.settings").signing },
        { label = "GitGud Options…", action = require("views.settings").options },
    })
end

local function windowMenu()
    menu.addMenu("window", "Window")
    menu.addItems("window", {
        { expand = function()
            local items = {}
            for _, id in ipairs(gitgud.windows()) do
                items[#items + 1] = { label = require("depot.windows").titleOf(id), action = function()
                    gitgud.focusWindow(id)
                end }
            end
            if #items == 0 then
                items[1] = { label = "No windows open", enabled = false, action = function() end }
            end
            return items
        end },
        { separator = true },
        { label = "Close All Windows", enabled = function()
            return #gitgud.windows() > 0
        end, action = function()
            for _, id in ipairs(gitgud.windows()) do
                gitgud.closeWindow(id)
            end
        end },
        { label = "Toggle Maximized", shortcut = "f11", action = function()
            gitgud.emit("window.toggleMaximize", "")
        end },
    })
end

local function helpMenu()
    menu.addMenu("help", "Help")
    menu.addItems("help", {
        { expand = require("views.about").docItems },
        { separator = true },
        { label = "Keyboard Shortcuts", action = function()
            dialog.alert("Keyboard shortcuts",
                "Ctrl+Shift+G  Get Latest      Ctrl+E  Check Out      Ctrl+R  Revert\n"
                    .. "Ctrl+S  Submit      Ctrl+N  New Pending Changelist\n"
                    .. "Ctrl+D  Diff Against Have      Ctrl+Shift+D  Diff Against…\n"
                    .. "Ctrl+T  File History      Ctrl+Shift+T  Time-lapse      Ctrl+Shift+R  Revision Graph\n"
                    .. "Ctrl+Shift+I  Merge/Integrate      Ctrl+Shift+F  Fetch      Ctrl+P  Push\n"
                    .. "Ctrl+F  Find File      Ctrl+L  Go to Depot Path      Ctrl+G  Go to Changelist\n"
                    .. "Ctrl+1 / Ctrl+2  Depot / Workspace tree      Ctrl+J  Log pane\n"
                    .. "Ctrl+K  Command palette      Ctrl+,  Preferences      F5  Refresh\n"
                    .. "Ctrl+Z / Ctrl+Y  Undo / Redo branch moves")
        end },
        require("views.updates").menuItem(),
        { label = "About GitGud Desktop", action = require("views.about").show },
    })
end

function menus.init()
    fileMenu()
    editMenu()
    searchMenu()
    viewMenu()
    actionsMenu()
    connectionMenu()
    toolsMenu()
    windowMenu()
    helpMenu()

    -- The palette's live entries: workspaces, branches, open files.
    require("ui.commands").addSource(function(add)
        if isOpen() then
            local current = repo.state().branch
            for _, branch in ipairs(gitgud.branches()) do
                if branch.name ~= current and not branch.name:find("shelves/", 1, true) then
                    local name = branch.name
                    add("Branch", "Switch workspace to " .. name, function()
                        commands.switchBranch(name)
                    end, branch.isRemote and "remote" or "local")
                end
            end
            for _, file in ipairs(repo.state().files) do
                local path = file.path
                add("File", "Diff " .. path, function()
                    require("depot.windows").diffHave(path)
                end, "open")
            end
        end
        for _, path in ipairs(require("views.repositories").known()) do
            add("Workspace", "Open " .. text.basename(path), function()
                commands.openWorkspace(path)
            end, path)
        end
    end)
end

return menus
