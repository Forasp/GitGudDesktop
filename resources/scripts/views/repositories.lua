--- views/repositories.lua — the "Current repository" dropdown.
--
-- Keeps the list of repositories you've added (persisted per user, most
-- recently opened first), lets you filter and switch between them, and adds
-- new ones: clone, create, or add an existing folder (also by dropping it on
-- the window). Right-click a repository to reveal it, open a terminal, copy
-- its path, or remove it from the list.
--
-- Public API: repositories.show(), repositories.clone(),
--   repositories.create(), repositories.addExisting(),
--   repositories.remove(path), repositories.open(path)

local C = require("core.palette")
local app = require("core.app")
local dialog = require("ui.dialog")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local popup = require("ui.popup")
local repo = require("core.repo")
local shell = require("core.shell")
local status = require("core.status")
local text = require("core.text")

local repositories = { name = "repositories" }

local LIST_FILE = "recent-repos"
local MAX_REPOS = 50

local known = {}          -- paths, most recently opened first
local rows = {}           -- list row -> path
local filterText = ""
local pendingSetup = nil  -- what to do once a newly created repo opens
local newTabMode = false  -- the dropdown was opened by the tab strip's "+"

--- Normalise a path for comparison (slashes, case, trailing separator).
-- @param path  a path
-- @return comparison key
local function key(path)
    return (path:gsub("\\", "/"):gsub("/+$", ""):lower())
end

--- Load the persisted repository list.
local function load()
    known = {}
    local raw = gitgud.configRead(LIST_FILE) or ""

    for line in raw:gmatch("[^\r\n]+") do
        if line ~= "" and #known < MAX_REPOS then
            known[#known + 1] = line
        end
    end
end

--- Persist the repository list.
local function save()
    gitgud.configWrite(LIST_FILE, table.concat(known, "\n"))
end

--- Move (or add) a path to the top of the list.
-- @param path  repository root
local function remember(path)
    if not path or path == "" then
        return
    end

    local list = { path }
    for _, existing in ipairs(known) do
        if key(existing) ~= key(path) and #list < MAX_REPOS then
            list[#list + 1] = existing
        end
    end
    known = list
    save()
end

--- Rebuild the list for the filter.
local function renderList()
    local current = key(repo.state().path)
    local items = {}
    rows = {}

    for _, path in ipairs(known) do
        if text.contains(path, filterText) then
            local isCurrent = key(path) == current
            local name = text.basename(path)
            local mark = isCurrent and text.colour(C.cyan, "✓ ") or "   "

            items[#items + 1] = text.rowHeight(22) .. mark .. text.colour(C.text, name) .. "\n"
                .. text.colour(C.dim, "    " .. text.truncateLeft(text.dirname(path), 46))
            rows[#items] = path
        end
    end

    if #items == 0 then
        local hint = #known == 0 and "No repositories yet — use Add." or "No repositories match."
        items[1] = text.colour(C.dim, hint)
    end

    gitgud.setList("RepoList", items)
end

--- Every repository in the list, most recently opened first.
-- @return array of paths
function repositories.known()
    return known
end

--- Open a repository by path (C++ swaps it in and fires repo.changed).
-- @param path  folder inside a repository
function repositories.open(path)
    local inNewTab = newTabMode
    popup.close()
    if inNewTab then
        require("views.tabs").openInNewTab(path)
        return
    end
    gitgud.openRepo(path)
end

--- Show the dropdown.
-- @param opts  optional { newTab = true }: picking opens a new tab
function repositories.show(opts)
    newTabMode = opts ~= nil and opts.newTab == true
    filterText = ""
    placeholder.setText("RepoFilterEdit", "")
    renderList()
    gitgud.setText("RepoPopupTitle", newTabMode and "Open in a new tab" or "Repositories")

    gitgud.setProperty("RepoButton", "NormalFillColour", C.bg3)
    popup.open("RepoPopup", {
        anchor = "RepoButton",
        focus = "RepoFilterEdit",
        onClose = function()
            gitgud.setProperty("RepoButton", "NormalFillColour", C.bg1)
            newTabMode = false
        end,
    })
end

--- Remove a repository from the list (the folder is untouched).
-- @param path  repository root
function repositories.remove(path)
    local list = {}
    for _, existing in ipairs(known) do
        if key(existing) ~= key(path) then
            list[#list + 1] = existing
        end
    end
    known = list
    save()
    local switched = require("views.tabs").forget(path)

    if key(path) == key(repo.state().path) and not switched then
        gitgud.closeRepo()
    end
    status.ok("Removed " .. text.basename(path) .. " from the list.")
end

--- Add a folder that's already a repository.
function repositories.addExisting()
    popup.close()
    dialog.show({
        title = "Add an existing repository",
        fields = { { label = "Local path", value = "", browse = true } },
        ok = "Add repository",
        onOk = function(v)
            local path = text.trim(v.fields[1])
            if path == "" then
                return false, "Choose a folder."
            end
            if not gitgud.pathExists(path) then
                return false, "That folder doesn't exist."
            end
            repositories.open(path)
            return true
        end,
    })
end

--- Clone a repository (runs on a worker; clone.done opens it).
function repositories.clone()
    popup.close()
    local parent = text.dirname(repo.state().path)

    dialog.show({
        title = "Clone a repository",
        message = "Any Git URL works (HTTPS, or a local path). The folder is created for you.",
        fields = {
            { label = "Repository URL or path", value = "" },
            { label = "Local path", value = parent, browse = true },
        },
        ok = "Clone",
        onOk = function(v)
            local url = text.trim(v.fields[1])
            local target = text.trim(v.fields[2])
            if url == "" then
                return false, "Enter the URL to clone."
            end
            if target == "" then
                return false, "Choose where to put it."
            end

            -- Cloning into a parent folder: add the repository's own name.
            local name = text.basename(url):gsub("%.git$", "")
            if gitgud.pathExists(target) and name ~= "" then
                target = target:gsub("[/\\]+$", "") .. "/" .. name
            end

            local sync = require("views.sync")
            sync.clone(url, target)
            return true
        end,
    })
end

--- The starter .gitignore for a template name.
-- @param template  "", "C++", "Node", "Python", "VisualStudio" (case-insensitive)
-- @return file content ("" for none)
local function gitignoreTemplate(template)
    local templates = {
        ["c++"] = "build/\nout/\n*.o\n*.obj\n*.exe\n*.pdb\n*.ilk\n.vs/\n",
        node = "node_modules/\ndist/\n.env\nnpm-debug.log*\n",
        python = "__pycache__/\n*.pyc\n.venv/\nvenv/\n.env\ndist/\n*.egg-info/\n",
        visualstudio = ".vs/\nbin/\nobj/\n*.user\n*.suo\n*.pdb\n",
    }

    return templates[template:lower()] or ""
end

--- Create a new repository (optionally with a README and .gitignore).
function repositories.create()
    popup.close()

    dialog.show({
        title = "Create a new repository",
        fields = {
            { label = "Name", value = "" },
            { label = "Local path (the repository folder is created inside)", value = "", browse = true },
            { label = "Git ignore template: none, C++, Node, Python, VisualStudio", value = "" },
        },
        checks = { { label = "Initialize with a README", value = true } },
        ok = "Create repository",
        onOk = function(v)
            local name = text.trim(v.fields[1])
            local parent = text.trim(v.fields[2])
            if name == "" then
                return false, "Enter a name."
            end
            if parent == "" then
                return false, "Choose where to create it."
            end

            local template = text.trim(v.fields[3])
            if template ~= "" and template:lower() ~= "none" and gitignoreTemplate(template) == "" then
                return false, "Unknown template '" .. template .. "'."
            end

            pendingSetup = {
                name = name,
                readme = v.checks[1],
                gitignore = gitignoreTemplate(template),
            }
            gitgud.initRepo(parent:gsub("[/\\]+$", "") .. "/" .. name)
            return true
        end,
    })
end

--- After a create: write the starter files and make the first commit.
local function finishSetup()
    local setup = pendingSetup
    pendingSetup = nil

    local files = {}
    if setup.readme then
        gitgud.writeRepoFile("README.md", "# " .. setup.name .. "\n")
        files[#files + 1] = "README.md"
    end
    if setup.gitignore ~= "" then
        gitgud.writeRepoFile(".gitignore", setup.gitignore)
        files[#files + 1] = ".gitignore"
    end

    if #files > 0 then
        gitgud.stage(files)
        local oid, err = gitgud.commit("Initial commit")
        if not oid then
            status.warn("Created the repository, but the first commit failed: " .. tostring(err))
        end
    end
end

--- Right-click menu for a repository row.
-- @param path  repository root
-- @return item list
local function repoMenu(path)
    return {
        {
            label = "Open",
            action = function()
                repositories.open(path)
            end,
        },
        {
            label = "Open in a new tab",
            action = function()
                popup.close()
                require("views.tabs").openInNewTab(path)
            end,
        },
        { separator = true },
        {
            label = "Show in Explorer",
            action = function()
                shell.showInFolder(path)
            end,
        },
        {
            label = "Open in terminal",
            action = function()
                shell.openTerminal(path)
            end,
        },
        {
            label = "Open in external editor",
            action = function()
                shell.openInEditor(path)
            end,
        },
        {
            label = "Copy repository path",
            action = function()
                shell.copy(path, "path")
            end,
        },
        { separator = true },
        {
            label = "Remove from list",
            action = function()
                repositories.remove(path)
            end,
        },
    }
end

--- The "Add ▾" menu.
-- @return item list
local function addMenu()
    return {
        { label = "Clone repository…", shortcut = "ctrl+shift+o", action = repositories.clone },
        { label = "Create new repository…", shortcut = "ctrl+n", action = repositories.create },
        { label = "Add existing repository…", shortcut = "ctrl+o", action = repositories.addExisting },
    }
end

--- Wire the popup and repository lifecycle events.
function repositories.init()
    load()
    placeholder.bind("RepoFilterEdit", "RepoFilterPlaceholder")

    gitgud.on("RepoButton.clicked", function()
        if popup.isOpen("RepoPopup") then
            popup.close()
        else
            repositories.show()
        end
    end)

    gitgud.on("RepoFilterEdit.changed", function(value)
        filterText = text.trim(value)
        renderList()
    end)

    gitgud.on("RepoFilterEdit.accepted", function()
        for i = 1, #rows do
            if rows[i] then
                repositories.open(rows[i])
                return
            end
        end
    end)

    gitgud.on("RepoList.selected", function(value)
        local row = tonumber(value)
        local path = row and rows[row + 1]
        if path then
            repositories.open(path)
        end
    end)

    gitgud.on("RepoList.rightClicked", function(value)
        local x, y, row = menu.parseClick(value)
        local path = row and rows[row]
        if path then
            menu.popup(repoMenu(path), x, y)
        end
    end)

    gitgud.on("AddRepoButton.clicked", function()
        local x, y, _, h = gitgud.getRect("AddRepoButton")
        menu.popup(addMenu(), x, y + h)
    end)

    gitgud.on("app.fileDropped", function(path)
        repositories.open(path)
    end)

    gitgud.on("repo.changed", function(path)
        if path ~= "" then
            remember(path)
            status.ok("Opened " .. text.basename(path) .. ".")
        end
        if pendingSetup then
            finishSetup()
        end
        app.requestRefresh()
    end)

    gitgud.on("repo.error", function(detail)
        pendingSetup = nil
        status.error(detail or "Could not open that repository.")
    end)

    -- The repository opened from the launch directory never fires
    -- repo.changed, so add it here.
    if gitgud.isOpen() then
        remember(gitgud.repoPath())
    end
end

return repositories
