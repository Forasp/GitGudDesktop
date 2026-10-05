--- views/navigator.lua — the branch tree on the left.
--
-- One list (NavList) with collapsible sections:
--   LOCAL        local branches (✓ the checked-out one, ↑↓ vs upstream)
--   REMOTE       every remote, with its remote-tracking branches
--   TAGS         tags
--   STASHES      every stash (not just this branch's)
--   SUBMODULES   when the repository has any
--   WORKTREES    when there is more than the main one
--
-- Click a section header to fold it. Click a branch or tag to find its
-- commit in the graph; double-click a branch to check it out (a worktree or
-- submodule to open it in a new tab). Right-click anything for its actions.
-- Drag one branch onto another to merge or rebase them.
--
-- Public API: navigator.toggle(), navigator.reload()

local C = require("core.palette")
local app = require("core.app")
local dialog = require("ui.dialog")
local frame = require("views.frame")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("core.shell")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")

local navigator = { name = "navigator" }

local ROW_HEIGHT = 26
local SECTION_HEIGHT = 30

local rows = {}           -- list row -> { kind, ... }
local filterText = ""
local ignoreClicksUntil = 0

--- Is a section folded?
-- @param id  section id
-- @return boolean
local function collapsed(id)
    if filterText ~= "" then
        return false -- filtering shows every match
    end

    return settings.get("navCollapsed." .. id, id == "tags" or id == "stashes")
end

--- Inline sprite markup.
-- @param name  image in Gitgud-Images
-- @return markup
local function sprite(name)
    return "[vert-formatting='CentreAligned'][image-size='w:16 h:16'][image='Gitgud-Images/" .. name .. "']"
end

--- A section header row.
-- @param id     section id
-- @param title  caption
-- @param count  number of entries
-- @return markup
local function sectionText(id, title, count)
    local chevron = collapsed(id) and "NavClosed" or "NavOpen"

    return text.rowHeight(SECTION_HEIGHT) .. " " .. sprite(chevron) .. " "
        .. "[font='Gitgud-UI-Small']" .. text.colour(C.dim, title:upper())
        .. text.colour(C.disabled, "  " .. tostring(count)) .. "[font='']"
end

--- An entry row.
-- @param depth   indentation level (1 = directly under a section)
-- @param icon    sprite name
-- @param label   markup of the name part (already escaped)
-- @param suffix  optional dim markup after it
-- @return markup
local function entryText(depth, icon, label, suffix)
    return text.rowHeight(ROW_HEIGHT) .. string.rep("    ", depth) .. sprite(icon) .. "  " .. label
        .. (suffix or "")
end

--- Does a name pass the filter?
-- @param name  entry name
-- @return boolean
local function visible(name)
    return text.contains(name, filterText)
end

--- Build the row model and the list texts.
local function build()
    rows = {}
    local items = {}
    local state = repo.state()

    --- Append one row.
    local function add(markup, row)
        items[#items + 1] = markup
        rows[#items] = row
    end

    if not state.open then
        add(text.colour(C.dim, "  No repository"), { kind = "none" })
        gitgud.setList("NavList", items)
        return
    end

    -- Every remote gets a group, even before its first fetch.
    local groups = {}
    local byRemote = {}
    for _, remote in ipairs(state.remotes) do
        local group = { remote = remote.name, branches = {} }
        groups[#groups + 1] = group
        byRemote[remote.name] = group
    end
    table.sort(groups, function(a, b)
        if (a.remote == "origin") ~= (b.remote == "origin") then
            return a.remote == "origin"
        end
        return a.remote:lower() < b.remote:lower()
    end)

    local locals = {}
    local remoteCount = 0
    for _, branch in ipairs(gitgud.branches()) do
        if branch.isRemote then
            -- Longest remote name that prefixes it (names may contain "/").
            local group = nil
            for name, candidate in pairs(byRemote) do
                if branch.name:sub(1, #name + 1) == name .. "/" and (not group or #name > #group.remote) then
                    group = candidate
                end
            end
            if group and visible(branch.name) then
                local short = branch.name:sub(#group.remote + 2)
                group.branches[#group.branches + 1] = { branch = branch, short = short }
                remoteCount = remoteCount + 1
            end
        elseif visible(branch.name) then
            locals[#locals + 1] = branch
        end
    end
    table.sort(locals, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    for _, group in ipairs(groups) do
        table.sort(group.branches, function(a, b)
            return a.short:lower() < b.short:lower()
        end)
    end

    -- LOCAL
    add(sectionText("local", "Local", #locals), { kind = "section", id = "local" })
    if not collapsed("local") then
        for _, branch in ipairs(locals) do
            local label = branch.isHead and ("[font='Gitgud-UI-Bold']" .. text.colour(C.text, branch.name) .. "[font='']")
                or text.colour(C.text2, branch.name)
            local counts = ""
            if (branch.ahead or 0) > 0 then
                counts = counts .. " ↑" .. branch.ahead
            end
            if (branch.behind or 0) > 0 then
                counts = counts .. " ↓" .. branch.behind
            end
            local mark = branch.isHead and text.colour(C.cyan, "  ✓") or ""
            add(entryText(1, "NavBranch", label, mark .. text.colour(C.dim, counts)),
                { kind = "branch", branch = branch })
        end
    end

    -- REMOTE, one group per remote (the current branch's upstream marked)
    add(sectionText("remote", "Remote", remoteCount), { kind = "section", id = "remote" })
    if not collapsed("remote") then
        local tracked = state.aheadBehind.upstreamRemote
        for _, group in ipairs(groups) do
            if #group.branches > 0 or visible(group.remote) then
                local note = group.remote == tracked and text.colour(C.dim, "  tracked") or ""
                if #group.branches == 0 then
                    note = note .. text.colour(C.disabled, "  not fetched")
                end
                add(entryText(1, "NavRemote", text.colour(C.text2, group.remote), note),
                    { kind = "remoteHeader", remote = group.remote })
                for _, entry in ipairs(group.branches) do
                    add(entryText(2, "NavBranch", text.colour(C.text2, entry.short)), { kind = "branch", branch = entry.branch })
                end
            end
        end
    end

    -- TAGS
    local tags = {}
    for _, tag in ipairs(gitgud.tags()) do
        if visible(tag.name) then
            tags[#tags + 1] = tag
        end
    end
    table.sort(tags, function(a, b)
        return a.name:lower() > b.name:lower()
    end)
    add(sectionText("tags", "Tags", #tags), { kind = "section", id = "tags" })
    if not collapsed("tags") then
        for _, tag in ipairs(tags) do
            add(entryText(1, "NavTag", text.colour(C.text2, tag.name)), { kind = "tag", tag = tag })
        end
    end

    -- STASHES
    local stashes = {}
    for _, entry in ipairs(state.stashes) do
        if visible(entry.message) then
            stashes[#stashes + 1] = entry
        end
    end
    add(sectionText("stashes", "Stashes", #stashes), { kind = "section", id = "stashes" })
    if not collapsed("stashes") then
        for _, entry in ipairs(stashes) do
            local message = entry.message:gsub("^gitgud: ", "")
            add(entryText(1, "NavStash", text.colour(C.text2, message)), { kind = "stash", stash = entry })
        end
    end

    -- SUBMODULES (only when there are any)
    local subs = gitgud.submodules() or {}
    if #subs > 0 then
        add(sectionText("submodules", "Submodules", #subs), { kind = "section", id = "submodules" })
        if not collapsed("submodules") then
            for _, sub in ipairs(subs) do
                local note = ""
                if not sub.initialized then
                    note = text.colour(C.warn, "  not cloned")
                elseif sub.modified then
                    note = text.colour(C.warn, "  moved")
                elseif sub.dirty then
                    note = text.colour(C.warn, "  changed")
                end
                add(entryText(1, "NavSubmodule", text.colour(C.text2, sub.path), note), { kind = "submodule", sub = sub })
            end
        end
    end

    -- WORKTREES (only when there are linked ones)
    local trees = gitgud.worktrees() or {}
    if #trees > 1 then
        add(sectionText("worktrees", "Worktrees", #trees), { kind = "section", id = "worktrees" })
        if not collapsed("worktrees") then
            for _, tree in ipairs(trees) do
                local here = text.basename(tree.path):lower() == text.basename(state.path):lower()
                    and tree.path:lower() == state.path:lower()
                local label = text.colour(here and C.text or C.text2, tree.name)
                local note = text.colour(C.dim, "  " .. (tree.branch ~= "" and tree.branch or "detached"))
                if not tree.valid then
                    note = text.colour(C.err, "  missing")
                end
                add(entryText(1, "NavWorktree", label, note), { kind = "worktree", tree = tree })
            end
        end
    end

    gitgud.setList("NavList", items)
end

--- Rebuild the tree (keeps the scroll position).
function navigator.reload()
    if frame.navigatorVisible() then
        build()
    end
end

--- Show or hide the tree.
function navigator.toggle()
    frame.setNavigator(not frame.navigatorVisible())
    navigator.reload()
end

--- Pixel offset of row `index`'s top inside the list's content.
-- @param index  1-based row
-- @return pixels
local function rowTop(index)
    local y = 0
    for i = 1, index - 1 do
        y = y + ((rows[i] and rows[i].kind == "section") and SECTION_HEIGHT or ROW_HEIGHT)
    end

    return y
end

--- Open a folder as a repository in a new tab.
-- @param path  folder
local function openInTab(path)
    require("views.tabs").openInNewTab(path)
end

--- Actions offered when one branch is dropped on another.
-- @param source  branch row dragged
-- @param target  branch row dropped on
-- @return item list
local function dropMenu(source, target)
    local branches = require("views.branches")
    local current = repo.state().branch
    local from = source.name
    local onto = target.name
    local items = {}

    if onto == current then
        items[#items + 1] = {
            label = "Merge " .. from .. " into " .. onto,
            action = function()
                branches.merge(from)
            end,
        }
        items[#items + 1] = {
            label = "Squash and merge " .. from .. " into " .. onto,
            action = function()
                branches.squash(from)
            end,
        }
    elseif from == current then
        items[#items + 1] = {
            label = "Rebase " .. from .. " onto " .. onto,
            action = function()
                branches.rebase(onto)
            end,
        }
        items[#items + 1] = {
            label = "Merge " .. onto .. " into " .. from,
            action = function()
                branches.merge(onto)
            end,
        }
    else
        items[#items + 1] = {
            label = "Check out " .. onto .. " and merge " .. from .. " into it",
            action = function()
                if branches.checkoutByName(onto) then
                    branches.merge(from)
                end
            end,
        }
        items[#items + 1] = {
            label = "Check out " .. onto .. " and rebase it onto " .. from,
            action = function()
                if branches.checkoutByName(onto) then
                    branches.rebase(from)
                end
            end,
        }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = {
        label = "Compare " .. onto .. " with " .. from,
        enabled = onto == current,
        action = function()
            require("views.history").compareWith(from)
        end,
    }

    return items
end

--- Right-click menu for a tag.
-- @param tag  gitgud.tags() row
-- @return item list
local function tagMenu(tag)
    return {
        {
            label = "Show in graph",
            action = function()
                require("views.graph").selectOid(tag.oid)
            end,
        },
        {
            label = "Check out tag (detached)",
            action = function()
                status.report("Checked out " .. tag.name .. ".", undo.track("Checkout " .. tag.name, function()
                    return gitgud.checkoutCommit(tag.oid)
                end))
                app.requestRefresh()
            end,
        },
        {
            label = "Create branch from tag…",
            action = function()
                dialog.prompt("Create a branch from " .. tag.name, "Branch name", "", "Create branch", function(name)
                    if name == "" then
                        return false, "Enter a branch name."
                    end
                    local ok, err = undo.track("Create branch " .. name, function()
                        return gitgud.createBranch(name, tag.oid)
                    end)
                    if not ok then
                        return false, err
                    end
                    status.ok("Created " .. name .. ".")
                    app.requestRefresh()
                    return true
                end)
            end,
        },
        { separator = true },
        {
            label = "Push tags",
            action = function()
                require("views.sync").pushTags()
            end,
        },
        {
            label = "Delete tag…",
            action = function()
                dialog.confirm("Delete tag " .. tag.name .. "?",
                    "The tag is removed locally. Tags already pushed stay on the remote.", "Delete tag",
                    function()
                        status.report("Deleted tag " .. tag.name .. ".", gitgud.deleteTag(tag.name))
                        app.requestRefresh()
                    end, true)
            end,
        },
        { separator = true },
        {
            label = "Copy tag name",
            action = function()
                shell.copy(tag.name, "tag name")
            end,
        },
    }
end

--- Right-click menu for a stash.
-- @param entry  stash row { index, message, oid }
-- @return item list
local function stashMenu(entry)
    local stash = require("views.stash")

    return {
        {
            label = "View",
            action = function()
                stash.viewEntry(entry)
            end,
        },
        {
            label = "Apply (keep the stash)",
            action = function()
                status.report("Applied the stash.", gitgud.stashApply(entry.index))
                app.requestRefresh()
            end,
        },
        {
            label = "Pop (apply and delete)",
            action = function()
                status.report("Restored the stash.", gitgud.stashPop(entry.index))
                app.requestRefresh()
            end,
        },
        { separator = true },
        {
            label = "Delete stash…",
            action = function()
                dialog.confirm("Delete this stash?", "Its changes are permanently deleted.", "Delete stash", function()
                    status.report("Deleted the stash.", gitgud.stashDrop(entry.index))
                    app.requestRefresh()
                end, true)
            end,
        },
    }
end

--- Right-click menu for a submodule.
-- @param sub  gitgud.submodules() row
-- @return item list
local function submoduleMenu(sub)
    local path = repo.state().path .. "/" .. sub.path

    return {
        {
            label = sub.initialized and "Update to the recorded commit" or "Clone (initialize) submodule",
            action = function()
                navigator.updateSubmodule(sub)
            end,
        },
        {
            label = "Open in a new tab",
            enabled = sub.initialized,
            action = function()
                openInTab(path)
            end,
        },
        { separator = true },
        {
            label = "Show in " .. shell.names.fileManager,
            enabled = sub.initialized,
            action = function()
                shell.showInFolder(path)
            end,
        },
        {
            label = "Copy URL",
            action = function()
                shell.copy(sub.url, "URL")
            end,
        },
    }
end

--- Right-click menu for a worktree.
-- @param tree  gitgud.worktrees() row
-- @return item list
local function worktreeMenu(tree)
    return {
        {
            label = "Open in a new tab",
            enabled = tree.valid,
            action = function()
                openInTab(tree.path)
            end,
        },
        {
            label = "Show in " .. shell.names.fileManager,
            enabled = tree.valid,
            action = function()
                shell.showInFolder(tree.path)
            end,
        },
        { separator = true },
        {
            label = "Remove worktree…",
            enabled = not tree.main,
            action = function()
                dialog.confirm("Remove worktree " .. tree.name .. "?",
                    "Its folder (" .. tree.path .. ") is deleted. Its branch stays. This is refused if "
                        .. "the worktree has uncommitted changes.",
                    "Remove worktree",
                    function()
                        status.report("Removed worktree " .. tree.name .. ".", gitgud.removeWorktree(tree.name))
                        app.requestRefresh()
                    end, true)
            end,
        },
    }
end

--- Clone / update a submodule on a worker.
-- @param sub  gitgud.submodules() row
function navigator.updateSubmodule(sub)
    if gitgud.updateSubmodule(sub.name, true) then
        status.info("Updating submodule " .. sub.path .. "…")
    end
end

--- Ask for a name and folder, then add a worktree.
function navigator.addWorktree()
    local state = repo.state()
    local parent = text.dirname(state.path)

    dialog.show({
        title = "Add a worktree",
        message = "A worktree is a second working folder for this repository, with another "
            .. "branch checked out — work on two branches at once without stashing.",
        fields = {
            { label = "Branch (created from HEAD if it doesn't exist)", value = "" },
            { label = "Folder", value = parent, browse = true },
        },
        checks = { { label = "Open it in a new tab", value = true } },
        ok = "Add worktree",
        onOk = function(v)
            local branch = text.trim(v.fields[1]):gsub("%s+", "-")
            local folder = text.trim(v.fields[2])
            if branch == "" then
                return false, "Enter a branch name."
            end
            if folder == "" then
                return false, "Choose a folder."
            end
            local name = branch:gsub("[/\\]", "-")
            local path = folder:gsub("[/\\]+$", "") .. "/" .. state.name .. "-" .. name
            local ok, err = gitgud.addWorktree(name, path, branch)
            if not ok then
                return false, err
            end
            status.ok("Added worktree " .. name .. " at " .. path .. ".")
            app.requestRefresh()
            if v.checks[1] then
                openInTab(path)
            end
            return true
        end,
    })
end

--- Menu for a section header.
-- @param id  section id
-- @return item list (may be empty)
local function sectionMenu(id)
    if id == "local" then
        return {
            { label = "New branch…", action = require("views.branches").create },
        }
    end
    if id == "remote" then
        return {
            { label = "Add remote…", action = require("views.remotes").add },
            {
                label = "Fetch all remotes",
                enabled = #repo.state().remotes > 0,
                action = function()
                    require("views.sync").fetch()
                end,
            },
        }
    end
    if id == "worktrees" then
        return {
            { label = "Add worktree…", action = navigator.addWorktree },
        }
    end
    if id == "submodules" then
        return {
            {
                label = "Update all submodules",
                action = function()
                    for _, sub in ipairs(gitgud.submodules() or {}) do
                        navigator.updateSubmodule(sub)
                    end
                end,
            },
        }
    end
    if id == "tags" then
        return {
            {
                label = "Push tags",
                action = function()
                    require("views.sync").pushTags()
                end,
            },
        }
    end

    return {}
end

--- Left click on a row.
-- @param row  row model
local function onClick(row)
    if row.kind == "section" then
        settings.set("navCollapsed." .. row.id, not collapsed(row.id))
        build()
        return
    end
    if row.kind == "branch" and frame.graphMode() then
        require("views.graph").selectOid(row.branch.oid)
    elseif row.kind == "tag" and frame.graphMode() then
        require("views.graph").selectOid(row.tag.oid)
    elseif row.kind == "stash" then
        require("views.stash").viewEntry(row.stash)
    end
end

--- Double click on a row.
-- @param row  row model
local function onDoubleClick(row)
    if row.kind == "branch" and not row.branch.isHead then
        require("views.branches").checkoutByName(row.branch.name)
    elseif row.kind == "worktree" and row.tree.valid then
        openInTab(row.tree.path)
    elseif row.kind == "submodule" and row.sub.initialized then
        openInTab(repo.state().path .. "/" .. row.sub.path)
    end
end

--- Refresh from a new snapshot.
function navigator.refresh()
    navigator.reload()
end

--- Wire the tree.
function navigator.init()
    placeholder.bind("NavFilterEdit", "NavFilterPlaceholder")

    gitgud.on("NavFilterEdit.changed", function(value)
        filterText = text.trim(value)
        build()
    end)

    gitgud.on("NavList.clicked", function(value)
        if gitgud.now() < ignoreClicksUntil then
            return
        end
        local _, _, index = menu.parseClick(value)
        local row = index and rows[index]
        if row then
            onClick(row)
        end
    end)

    gitgud.on("NavList.doubleClicked", function(value)
        local index = tonumber(value)
        local row = index and rows[index + 1]
        if row then
            onDoubleClick(row)
        end
    end)

    gitgud.on("NavList.rightClicked", function(value)
        local x, y, index = menu.parseClick(value)
        local row = index and rows[index]
        if not row then
            return
        end
        gitgud.selectListItem("NavList", index, false)

        local items = {}
        if row.kind == "section" then
            items = sectionMenu(row.id)
        elseif row.kind == "branch" then
            items = require("views.branches").branchMenu(row.branch)
        elseif row.kind == "remoteHeader" then
            items = require("views.remotes").menu(row.remote)
        elseif row.kind == "tag" then
            items = tagMenu(row.tag)
        elseif row.kind == "stash" then
            items = stashMenu(row.stash)
        elseif row.kind == "submodule" then
            items = submoduleMenu(row.sub)
        elseif row.kind == "worktree" then
            items = worktreeMenu(row.tree)
        end
        if #items > 0 then
            menu.popup(items, x, y)
        end
    end)

    -- Drag a branch onto another: offer merge / rebase.
    gitgud.on("NavList.dragged", function(value)
        ignoreClicksUntil = gitgud.now() + 400
        local fromRow, toRow = value:match("^(%d+),(%d+)$")
        local source = rows[(tonumber(fromRow) or -1) + 1]
        local target = rows[(tonumber(toRow) or -1) + 1]
        if not source or not target or source.kind ~= "branch" or target.kind ~= "branch" then
            return
        end
        if target.branch.isRemote then
            status.info("Drop onto a local branch to merge or rebase.")
            return
        end
        if source.branch.name == target.branch.name then
            return
        end

        local lx, ly, lw = gitgud.getRect("NavList")
        local y = ly + rowTop(tonumber(toRow) + 1) - gitgud.getScroll("NavList") + ROW_HEIGHT
        gitgud.selectListItem("NavList", tonumber(toRow) + 1, false)
        menu.popup(dropMenu(source.branch, target.branch), lx + math.min(lw - 40, 60), y)
    end)

    gitgud.on("updateSubmodule.done", function(detail)
        status.ok(detail)
        app.requestRefresh()
    end)
    gitgud.on("updateSubmodule.error", function(detail)
        status.error("Submodule update failed: " .. tostring(detail))
    end)

    app.subscribe("frame.changed", function()
        navigator.reload()
    end)
end

return navigator
