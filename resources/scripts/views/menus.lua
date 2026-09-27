--- views/menus.lua — the title-bar menus and their keyboard shortcuts.
--
-- Everything the app can do, in one place: File, Edit,
-- View, Repository, Branch, Help. Items call into the feature modules; menu
-- shortcuts are bound automatically (ui/menu.lua), and every item is also
-- in the command palette (Ctrl+K). Mods add their own menus or items the
-- same way — see docs/MODDING.md.

local about = require("views.about")
local app = require("core.app")
local commands = require("ui.commands")
local console = require("views.console")
local frame = require("views.frame")
local graph = require("views.graph")
local lfs = require("views.lfs")
local navigator = require("views.navigator")
local rebase = require("views.rebase")
local ssh = require("views.ssh")
local toolbar = require("views.toolbar")
local undo = require("core.undo")
local branches = require("views.branches")
local changes = require("views.changes")
local diff = require("views.diff")
local dialog = require("ui.dialog")
local history = require("views.history")
local menu = require("ui.menu")
local repo = require("core.repo")
local repositories = require("views.repositories")
local settingsView = require("views.settings")
local shell = require("core.shell")
local sidebar = require("views.sidebar")
local stash = require("views.stash")
local status = require("core.status")
local sync = require("views.sync")

local menus = { name = "menus" }

--- True when a repository is open.
-- @return boolean
local function isOpen()
    return repo.state().open
end

--- True when a repository is open and HEAD is a branch with commits.
-- @return boolean
local function onBranch()
    local state = repo.state()
    return state.open and state.branch ~= "" and state.headOid ~= ""
end

--- True when there are uncommitted changes.
-- @return boolean
local function hasChanges()
    return #repo.state().files > 0
end

--- True when the repository has a remote to talk to.
-- @return boolean
local function hasRemote()
    return isOpen() and repo.primaryRemote() ~= nil
end

--- Define File.
local function fileMenu()
    menu.addMenu("file", "File")
    menu.addItems("file", {
        { label = "New repository…", shortcut = "ctrl+n", action = repositories.create },
        { label = "Add local repository…", shortcut = "ctrl+o", action = repositories.addExisting },
        { label = "Clone repository…", shortcut = "ctrl+shift+o", action = repositories.clone },
        { separator = true },
        { label = "Options…", shortcut = "ctrl+,", action = settingsView.options },
        { label = "Switch user interface…", action = settingsView.switchInterface },
        { label = "SSH keys…", action = ssh.keys },
        { label = "Commit signing…", action = settingsView.signing },
        { separator = true },
        {
            label = "Exit",
            shortcut = "alt+f4",
            action = function()
                gitgud.emit("window.close", "")
            end,
        },
    })
end

--- Define Edit.
local function editMenu()
    menu.addMenu("edit", "Edit")
    menu.addItems("edit", {
        {
            label = "Undo",
            shortcut = "ctrl+z",
            enabled = function()
                return undo.peekUndo() ~= nil and not gitgud.textInputFocused()
            end,
            action = toolbar.undo,
        },
        {
            label = "Redo",
            shortcut = "ctrl+shift+z",
            enabled = function()
                return undo.peekRedo() ~= nil and not gitgud.textInputFocused()
            end,
            action = toolbar.redo,
        },
        { separator = true },
        { label = "Find changed file", shortcut = "ctrl+f", enabled = isOpen, action = changes.focusFilter },
        {
            label = "Include all changes",
            shortcut = "ctrl+shift+a",
            enabled = hasChanges,
            action = function()
                local paths = {}
                for _, file in ipairs(repo.state().files) do
                    paths[#paths + 1] = file.path
                end
                status.report(nil, gitgud.stage(paths))
            end,
        },
        { separator = true },
        { label = "Undo last commit", enabled = onBranch, action = changes.undoLastCommit },
        {
            label = "Discard all changes…",
            shortcut = "ctrl+shift+backspace",
            enabled = hasChanges,
            action = changes.discardAll,
        },
    })
end

--- Define View.
local function viewMenu()
    menu.addMenu("view", "View")
    menu.addItems("view", {
        {
            label = "Changes",
            shortcut = "ctrl+1",
            checked = function()
                return sidebar.tab() == "changes"
            end,
            action = function()
                sidebar.select("changes")
            end,
        },
        {
            label = "History",
            shortcut = "ctrl+2",
            checked = function()
                return sidebar.tab() == "history"
            end,
            action = function()
                sidebar.select("history")
            end,
        },
        {
            label = "Commit graph",
            shortcut = "ctrl+3",
            enabled = isOpen,
            checked = frame.graphMode,
            action = graph.toggle,
        },
        { separator = true },
        {
            label = "Branch tree",
            shortcut = "ctrl+shift+l",
            checked = frame.navigatorVisible,
            action = navigator.toggle,
        },
        {
            label = "Console",
            shortcut = "ctrl+j",
            checked = frame.consoleVisible,
            action = console.toggle,
        },
        { label = "Command palette…", shortcut = "ctrl+k", action = commands.open },
        { separator = true },
        { label = "Repository list", shortcut = "ctrl+t", action = repositories.show },
        { label = "Branches list", shortcut = "ctrl+b", enabled = isOpen, action = branches.show },
        { separator = true },
        {
            label = "Split diff",
            checked = function()
                return diff.mode() == "split"
            end,
            action = function()
                diff.setMode("split")
            end,
        },
        {
            label = "Unified diff",
            checked = function()
                return diff.mode() == "unified"
            end,
            action = function()
                diff.setMode("unified")
            end,
        },
        {
            label = "Hide whitespace changes",
            checked = diff.ignoreWhitespace,
            action = function()
                diff.setIgnoreWhitespace(not diff.ignoreWhitespace())
            end,
        },
        {
            label = "Highlight changed words",
            checked = diff.wordDiff,
            action = function()
                diff.setWordDiff(not diff.wordDiff())
            end,
        },
        { separator = true },
        {
            label = "Toggle maximized",
            shortcut = "f11",
            action = function()
                gitgud.emit("window.toggleMaximize", "")
            end,
        },
        { label = "Refresh", shortcut = "f5", action = app.requestRefresh },
    })
end

--- Define Repository.
local function repositoryMenu()
    menu.addMenu("repository", "Repository")
    menu.addItems("repository", {
        { label = "Push", shortcut = "ctrl+p", enabled = hasRemote, action = sync.push },
        { label = "Pull", shortcut = "ctrl+shift+p", enabled = hasRemote, action = sync.pull },
        { label = "Fetch all", shortcut = "ctrl+shift+t", enabled = hasRemote, action = sync.fetch },
        {
            label = "Push to…",
            enabled = function()
                return hasRemote() and onBranch()
            end,
            action = sync.choosePushRemote,
        },
        {
            label = "Pull from…",
            enabled = function()
                return hasRemote() and onBranch()
            end,
            action = sync.choosePullRemote,
        },
        { label = "Force push…", enabled = hasRemote, action = sync.forcePush },
        {
            label = "Push tags",
            enabled = hasRemote,
            action = function()
                sync.pushTags()
            end,
        },
        { separator = true },
        { label = "Add remote…", enabled = isOpen, action = require("views.remotes").add },
        { separator = true },
        { label = "Stash all changes", shortcut = "ctrl+shift+s", enabled = hasChanges, action = stash.stashAll },
        {
            label = "View stashed changes",
            enabled = function()
                return stash.latest() ~= nil
            end,
            action = function()
                sidebar.select("changes")
                stash.view()
            end,
        },
        {
            label = "Restore stashed changes",
            enabled = function()
                return stash.latest() ~= nil
            end,
            action = stash.restore,
        },
        { separator = true },
        {
            label = "Open in terminal",
            shortcut = "ctrl+`",
            enabled = isOpen,
            action = function()
                shell.openTerminal(repo.state().path)
            end,
        },
        {
            label = "Show in Explorer",
            shortcut = "ctrl+shift+f",
            enabled = isOpen,
            action = function()
                shell.showInFolder(repo.state().path)
            end,
        },
        {
            label = "Open in external editor",
            shortcut = "ctrl+shift+e",
            enabled = isOpen,
            action = function()
                shell.openInEditor(repo.state().path)
            end,
        },
        { separator = true },
        {
            label = "Open merge tool",
            enabled = function()
                return #repo.state().conflicts > 0
            end,
            action = function()
                require("views.mergetool").open(repo.state().conflicts[1])
            end,
        },
        { separator = true },
        { label = "Git LFS: track files…", enabled = isOpen, action = lfs.trackPrompt },
        { label = "Git LFS: pull files", enabled = isOpen, action = lfs.pull },
        { label = "Git LFS: status", enabled = isOpen, action = lfs.status },
        { separator = true },
        { label = "Add worktree…", enabled = onBranch, action = navigator.addWorktree },
        {
            label = "Update submodules",
            enabled = function()
                return isOpen() and #(gitgud.submodules() or {}) > 0
            end,
            action = function()
                for _, sub in ipairs(gitgud.submodules() or {}) do
                    navigator.updateSubmodule(sub)
                end
            end,
        },
        { separator = true },
        { label = "Repository settings…", enabled = isOpen, action = settingsView.repository },
        {
            label = "Remove from list…",
            enabled = isOpen,
            action = function()
                local state = repo.state()
                dialog.confirm("Remove " .. state.name .. "?",
                    "It's removed from GitGud's list only. The folder on disk isn't touched.",
                    "Remove",
                    function()
                        repositories.remove(state.path)
                    end)
            end,
        },
    })
end

--- Define Branch.
local function branchMenu()
    menu.addMenu("branch", "Branch")
    menu.addItems("branch", {
        { label = "New branch…", shortcut = "ctrl+shift+n", enabled = isOpen, action = branches.create },
        {
            label = "Rename…",
            shortcut = "ctrl+shift+r",
            enabled = onBranch,
            action = function()
                branches.rename()
            end,
        },
        {
            label = "Delete…",
            shortcut = "ctrl+shift+d",
            enabled = onBranch,
            action = function()
                branches.pick("Delete which branch?", branches.delete)
            end,
        },
        { separator = true },
        { label = "Update from default branch", shortcut = "ctrl+shift+u", enabled = onBranch, action = branches.updateFromDefault },
        {
            label = "Compare to branch…",
            shortcut = "ctrl+shift+b",
            enabled = onBranch,
            action = function()
                branches.pick("Compare with", history.compareWith)
            end,
        },
        {
            label = "Merge into current branch…",
            shortcut = "ctrl+shift+m",
            enabled = onBranch,
            action = function()
                branches.pick("Merge into " .. repo.state().branch, branches.merge)
            end,
        },
        {
            label = "Squash and merge into current branch…",
            shortcut = "ctrl+shift+h",
            enabled = onBranch,
            action = function()
                branches.pick("Squash and merge into " .. repo.state().branch, branches.squash)
            end,
        },
        {
            label = "Rebase current branch…",
            shortcut = "ctrl+shift+i",
            enabled = onBranch,
            action = function()
                branches.pick("Rebase " .. repo.state().branch .. " onto…", branches.rebase)
            end,
        },
        {
            label = "Interactive rebase…",
            shortcut = "ctrl+alt+i",
            enabled = onBranch,
            action = rebase.openRecent,
        },
    })
end

--- Define Help.
local function helpMenu()
    menu.addMenu("help", "Help")
    menu.addItems("help", {
        { expand = about.docItems },
        { separator = true },
        { label = "Show keyboard shortcuts", action = menus.showShortcuts },
        { label = "About GitGud Desktop", action = about.show },
    })
end

--- A dialog listing every menu shortcut.
function menus.showShortcuts()
    dialog.alert("Keyboard shortcuts",
        "Ctrl+1 / Ctrl+2 / Ctrl+3   Changes / History / Commit graph\n"
            .. "Ctrl+K or F1   Command palette      Ctrl+Z / Ctrl+Shift+Z   Undo / Redo\n"
            .. "Ctrl+J   Console      Ctrl+Shift+L   Branch tree\n"
            .. "Ctrl+Tab   Next repository tab      Ctrl+W   Close tab\n"
            .. "Ctrl+Alt+I   Interactive rebase\n"
            .. "Ctrl+T   Repositories      Ctrl+B   Branches\n"
            .. "Ctrl+Enter   Commit      Ctrl+F   Filter changed files\n"
            .. "Ctrl+P   Push      Ctrl+Shift+P   Pull      Ctrl+Shift+T   Fetch\n"
            .. "Ctrl+Shift+N   New branch      Ctrl+Shift+M   Merge into current\n"
            .. "Ctrl+Shift+S   Stash all changes      F5   Refresh\n"
            .. "Ctrl+N / Ctrl+O / Ctrl+Shift+O   New / Add / Clone repository\n"
            .. "Ctrl+,   Options      Escape   Close popups and dialogs")
end

--- The palette's live entries: check out a branch, show a changed file,
-- open a repository from the list.
-- @param add  commands.addSource's add(group, label, action, detail)
local function paletteEntries(add)
    if gitgud.isOpen() then
        local current = gitgud.currentBranch()
        for _, branch in ipairs(gitgud.branches()) do
            if branch.name ~= current then
                local name = branch.name
                add("Branch", "Check out " .. name, function()
                    branches.checkoutByName(name)
                end, branch.isRemote and "remote" or "local")
            end
        end

        for _, file in ipairs(repo.state().files) do
            local path = file.path
            add("File", "Show " .. path, function()
                sidebar.select("changes")
                changes.select(path)
            end, "changed")
        end
    end

    local here = gitgud.repoPath():lower()
    for _, path in ipairs(repositories.known()) do
        if path:lower() ~= here then
            add("Repository", "Open " .. require("core.text").basename(path), function()
                repositories.open(path)
            end, path)
        end
    end
end

--- Build every menu.
function menus.init()
    commands.addSource(paletteEntries)

    require("core.keys").bind("ctrl+y", function()
        if undo.peekRedo() and not gitgud.textInputFocused() then
            toolbar.redo()
        end
    end, "Redo")

    fileMenu()
    editMenu()
    viewMenu()
    repositoryMenu()
    branchMenu()
    helpMenu()
end

return menus
