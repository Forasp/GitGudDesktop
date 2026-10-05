--- views/branches.lua — the "Current branch" dropdown and branch operations.
--
-- The popup lists branches in sections (default, recent, other, remote) and
-- works in one of several modes:
--   switch   (default) picking a branch checks it out
--   merge    picking a branch merges it into the current one
--   squash   ... squash-merges it into the current one
--   rebase   ... rebases the current branch onto it
--   pick     picking calls back into whoever asked (e.g. History compare)
-- Right-click a branch for everything else.
--
-- Public API: branches.show(), branches.create(), branches.rename(name),
--   branches.delete(name), branches.merge(name), branches.squash(name),
--   branches.rebase(name), branches.updateFromDefault(),
--   branches.pick(title, callback), branches.defaultBranch(),
--   branches.checkoutByName(name), branches.branchMenu(branch)
--
-- Every operation that moves a branch is recorded for Undo (core/undo.lua).

local C = require("core.palette")
local app = require("core.app")
local dialog = require("ui.dialog")
local localchanges = require("views.localchanges")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local popup = require("ui.popup")
local repo = require("core.repo")
local shell = require("core.shell")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")

local branches = { name = "branches" }

local RECENT_COUNT = 5

local all = {}           -- gitgud.branches()
local rows = {}          -- list row -> branch (nil for section headers)
local mode = "switch"
local pickCallback = nil
local filterText = ""

--- The repository's default branch: init.defaultBranch if it exists,
-- else "main", else "master", else the current branch.
-- @return branch name
function branches.defaultBranch()
    local names = {}
    for _, branch in ipairs(all) do
        if not branch.isRemote then
            names[branch.name] = true
        end
    end

    local configured = gitgud.config("init.defaultBranch")
    if configured ~= "" and names[configured] then
        return configured
    end
    if names.main then
        return "main"
    end
    if names.master then
        return "master"
    end

    return repo.state().branch
end

--- Title and hint for the current mode.
-- @return title text
local function modeTitle()
    local current = repo.state().branch

    if mode == "merge" then
        return "Merge into " .. current
    end
    if mode == "squash" then
        return "Squash and merge into " .. current
    end
    if mode == "rebase" then
        return "Rebase " .. current .. " onto…"
    end
    if mode == "pick" and pickCallback then
        return pickCallback.title
    end

    return "Branches"
end

--- A branch row: check mark for the current branch, ahead/behind counts.
-- @param branch  gitgud.branches() row
-- @return markup
local function branchRow(branch)
    local markup = text.rowHeight(26)

    if branch.isHead then
        markup = markup .. text.colour(C.cyan, " ✓ ") .. text.colour(C.text, branch.name)
    elseif branch.isRemote then
        markup = markup .. "    " .. text.colour(C.text2, branch.name)
    else
        markup = markup .. "    " .. text.colour(C.text, branch.name)
    end

    local counts = ""
    if (branch.ahead or 0) > 0 then
        counts = counts .. " ↑" .. branch.ahead
    end
    if (branch.behind or 0) > 0 then
        counts = counts .. " ↓" .. branch.behind
    end
    if counts ~= "" then
        markup = markup .. text.colour(C.dim, "  " .. counts)
    end

    return markup
end

--- A section header row.
-- @param title  section name
-- @return markup
local function sectionRow(title)
    return text.rowHeight(24) .. " " .. text.colour(C.dim, title:upper())
end

--- Rebuild the list for the current filter and mode.
local function renderList()
    local state = repo.state()
    local default = branches.defaultBranch()
    local locals = {}
    local remotes = {}
    local localNames = {}

    for _, branch in ipairs(all) do
        local hidden = (mode ~= "switch" and mode ~= "pick") and branch.isHead
        if not hidden and text.contains(branch.name, filterText) then
            if branch.isRemote then
                remotes[#remotes + 1] = branch
            else
                locals[#locals + 1] = branch
                localNames[branch.name] = true
            end
        end
    end

    -- Remote branches that already have a local twin add nothing.
    local remoteOnly = {}
    for _, branch in ipairs(remotes) do
        local short = branch.name:match("^[^/]+/(.+)$") or branch.name
        if not localNames[short] then
            remoteOnly[#remoteOnly + 1] = branch
        end
    end

    local defaultRow = nil
    local others = {}
    for _, branch in ipairs(locals) do
        if branch.name == default then
            defaultRow = branch
        else
            others[#others + 1] = branch
        end
    end

    table.sort(others, function(a, b)
        return (a.time or 0) > (b.time or 0)
    end)
    local recent = {}
    local rest = {}
    for i, branch in ipairs(others) do
        if i <= RECENT_COUNT then
            recent[#recent + 1] = branch
        else
            rest[#rest + 1] = branch
        end
    end
    table.sort(rest, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    table.sort(remoteOnly, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    rows = {}
    local items = {}

    --- Append a titled section when it has any branches.
    local function section(title, list)
        if #list == 0 then
            return
        end
        items[#items + 1] = sectionRow(title)
        rows[#items] = false
        for _, branch in ipairs(list) do
            items[#items + 1] = branchRow(branch)
            rows[#items] = branch
        end
    end

    section("Default branch", defaultRow and { defaultRow } or {})
    section("Recent branches", recent)
    section("Other branches", rest)
    section("Remote branches", remoteOnly)

    if #items == 0 then
        items[1] = text.colour(C.dim, state.headOid == "" and "Make a commit to create branches." or "No branches match.")
        rows[1] = false
    end

    gitgud.setList("BranchList", items)
    gitgud.setText("BranchPopupTitle", text.escape(modeTitle()))

    local switching = mode == "switch"
    gitgud.setVisible("NewBranchButton", switching)
    gitgud.setVisible("MergeIntoButton", switching)
    gitgud.setVisible("RebaseOntoButton", switching)
end

--- Open the popup in a mode.
-- @param newMode  "switch" | "merge" | "squash" | "rebase" | "pick"
local function openIn(newMode)
    if not repo.state().open then
        status.warn("Open a repository first.")
        return
    end

    mode = newMode
    all = gitgud.branches()
    filterText = ""
    placeholder.setText("BranchFilterEdit", "")
    renderList()

    gitgud.setProperty("BranchButton", "NormalFillColour", C.bg3)
    popup.open("BranchPopup", {
        anchor = "BranchButton",
        focus = "BranchFilterEdit",
        onClose = function()
            gitgud.setProperty("BranchButton", "NormalFillColour", C.bg1)
            mode = "switch"
            pickCallback = nil
        end,
    })
end

--- Show the branch dropdown (switch mode).
function branches.show()
    openIn("switch")
end

--- Ask the user to pick a branch, then call back.
-- @param title     popup title
-- @param callback  function(branchName)
function branches.pick(title, callback)
    pickCallback = { title = title, fn = callback }
    openIn("pick")
end

--- Run a merge or squash-merge and report it, offering to stash when
-- uncommitted changes are in the way.
-- @param what  e.g. "Merging topic", for the stash offer
-- @param fn    function() -> gitgud.merge()-style results, under undo
local function runMerge(what, fn)
    local result, err, inTheWay = fn()
    if inTheWay then
        localchanges.offer(what, inTheWay, function()
            runMerge(what, fn)
        end)
    elseif not result then
        status.error(err or "Merge failed.")
    elseif result.kind == "conflicts" then
        status.warn(result.message .. " (" .. text.plural(#result.conflicts, "conflicted file") .. ")")
    else
        status.ok(result.message)
    end
    app.requestRefresh()
end

--- Merge a branch into the current one.
-- @param name  branch to merge
function branches.merge(name)
    runMerge("Merging " .. name, function()
        return undo.track("Merge " .. name, function()
            return gitgud.merge(name)
        end)
    end)
end

--- Squash-merge a branch into the current one.
-- @param name  branch to fold in
function branches.squash(name)
    runMerge("Squash-merging " .. name, function()
        return undo.track("Squash-merge " .. name, function()
            return gitgud.squashMerge(name)
        end)
    end)
end

--- Rebase the current branch onto another, after confirming.
-- @param name  upstream branch
function branches.rebase(name)
    local current = repo.state().branch

    dialog.confirm("Rebase " .. current .. " onto " .. name .. "?",
        "Your commits on " .. current .. " are replayed on top of " .. name .. ". This rewrites "
            .. current .. "'s history: if it's already pushed, you'll need to force push afterwards.",
        "Start rebase",
        function()
            local result, err = undo.track("Rebase onto " .. name, function()
                return gitgud.rebase(name)
            end)
            if not result then
                status.error(err or "Rebase failed.")
            elseif result.kind == "conflicts" then
                status.warn("Rebase paused on conflicts. Resolve them, then choose Continue rebase.")
            else
                status.ok(result.message)
            end
            app.requestRefresh()
        end)
end

--- Check out a branch; if local changes are in the way, offer to stash.
-- @param branch  gitgud.branches() row
-- @return true when the branch is now checked out
local function checkout(branch)
    local ok, err, inTheWay = undo.track("Checkout " .. branch.name, function()
        return gitgud.checkout(branch.name)
    end)
    if ok then
        status.ok("Switched to " .. branch.name .. ".")
        app.requestRefresh()
        return true
    end

    if inTheWay then
        localchanges.offer("Switching to " .. branch.name, inTheWay, function()
            status.report("Stashed your changes and switched to " .. branch.name .. ".",
                undo.track("Checkout " .. branch.name, function()
                    return gitgud.checkout(branch.name)
                end))
            app.requestRefresh()
        end)
        return false
    end

    status.error(err or "Checkout failed.")
    return false
end

--- Check out a branch by name (local, or remote-tracking: a local branch is
-- created for it), offering to stash when local changes are in the way.
-- @param name  branch name
-- @return true when it is now checked out
function branches.checkoutByName(name)
    return checkout({ name = name })
end

--- Handle a pick in the list according to the mode.
-- @param branch  gitgud.branches() row
local function onPicked(branch)
    local pickedMode = mode
    local callback = pickCallback
    popup.close()

    if pickedMode == "merge" then
        branches.merge(branch.name)
    elseif pickedMode == "squash" then
        branches.squash(branch.name)
    elseif pickedMode == "rebase" then
        branches.rebase(branch.name)
    elseif pickedMode == "pick" and callback then
        callback.fn(branch.name)
    elseif not branch.isHead then
        checkout(branch)
    end
end

--- Clean a user-typed branch name (spaces become dashes).
-- @param name  raw input
-- @return a valid-ish ref name
local function sanitize(name)
    return (text.trim(name):gsub("%s+", "-"))
end

--- Create a branch from the current one and switch to it.
function branches.create()
    local state = repo.state()
    if state.headOid == "" then
        status.warn("Make a first commit before creating branches.")
        return
    end

    popup.close()
    dialog.show({
        title = "Create a branch",
        message = "Based on " .. (state.branch ~= "" and state.branch or state.headOid:sub(1, 7))
            .. ". Your uncommitted changes come along.",
        fields = { { label = "Name", value = "" } },
        ok = "Create branch",
        onOk = function(v)
            local name = sanitize(v.fields[1])
            if name == "" then
                return false, "Enter a branch name."
            end

            local ok, err = undo.track("Create branch " .. name, function()
                local created, createErr = gitgud.createBranch(name)
                if not created then
                    return created, createErr
                end
                return gitgud.checkout(name)
            end)
            if not ok then
                return false, err
            end
            status.ok("Created and switched to " .. name .. ".")
            app.requestRefresh()
            return true
        end,
    })
end

--- Rename a branch.
-- @param name  branch to rename (default: the current branch)
function branches.rename(name)
    name = name or repo.state().branch
    if name == "" then
        return
    end

    dialog.prompt("Rename " .. name, "New name", name, "Rename", function(newName)
        newName = sanitize(newName)
        if newName == "" or newName == name then
            return false, "Enter a different name."
        end

        local ok, err = undo.track("Rename " .. name, function()
            return gitgud.renameBranch(name, newName)
        end)
        if not ok then
            return false, err
        end
        status.ok("Renamed " .. name .. " to " .. newName .. ".")
        app.requestRefresh()
        return true
    end)
end

--- Delete a local branch (optionally on the remote too), after confirming.
-- @param name  branch to delete (default: none — the current one can't be)
function branches.delete(name)
    local state = repo.state()
    name = name or state.branch

    if name == state.branch then
        status.warn("You can't delete the branch you're on. Switch to another branch first.")
        return
    end

    local upstream = nil
    for _, branch in ipairs(gitgud.branches()) do
        if branch.name == name then
            upstream = branch.upstream
        end
    end

    local checks = {}
    if upstream and upstream ~= "" then
        checks[1] = { label = "Also delete " .. upstream .. " on the remote", value = false }
    end

    dialog.show({
        title = "Delete " .. name .. "?",
        message = "The branch is removed locally. Commits that exist only on it become unreachable.",
        checks = checks,
        ok = "Delete branch",
        danger = true,
        onOk = function(v)
            local ok, err = undo.track("Delete branch " .. name, function()
                return gitgud.deleteBranch(name)
            end)
            if not ok then
                return false, err
            end

            if v.checks[1] then
                local remote, remoteBranch = repo.splitRemoteBranch(upstream)
                if remote then
                    gitgud.deleteRemoteBranch(remote, remoteBranch)
                end
            end
            status.ok("Deleted " .. name .. ".")
            app.requestRefresh()
            return true
        end,
    })
end

--- Merge the default branch into the current one.
function branches.updateFromDefault()
    all = gitgud.branches()
    local default = branches.defaultBranch()

    if default == repo.state().branch then
        status.info("You're on the default branch already.")
        return
    end
    branches.merge(default)
end

--- Make a local branch track a remote branch (push/pull go there).
-- @param name      local branch
-- @param upstream  remote-tracking branch ("origin/main"), or nil to stop
function branches.track(name, upstream)
    local ok, err = gitgud.setUpstream(name, upstream or "")
    if upstream then
        status.report(name .. " now tracks " .. upstream .. ".", ok, err)
    else
        status.report(name .. " no longer tracks a remote branch.", ok, err)
    end
    app.requestRefresh()
end

--- Right-click menu for a branch row (the dropdown and the branch tree).
-- @param branch  gitgud.branches() row
-- @return item list
function branches.branchMenu(branch)
    local current = repo.state().branch
    local localBranch = not branch.isRemote
    local other = not branch.isHead

    return {
        {
            label = "Checkout",
            enabled = other,
            action = function()
                popup.close()
                checkout(branch)
            end,
        },
        { separator = true },
        {
            label = "Merge into " .. current,
            enabled = other and current ~= "",
            action = function()
                branches.merge(branch.name)
            end,
        },
        {
            label = "Squash and merge into " .. current,
            enabled = other and current ~= "" and localBranch,
            action = function()
                branches.squash(branch.name)
            end,
        },
        {
            label = "Rebase " .. current .. " onto this",
            enabled = other and current ~= "" and localBranch,
            action = function()
                branches.rebase(branch.name)
            end,
        },
        {
            label = "Compare with " .. current,
            enabled = other,
            action = function()
                local history = require("views.history")
                history.compareWith(branch.name)
            end,
        },
        { separator = true },
        {
            label = "Rename…",
            enabled = localBranch,
            action = function()
                branches.rename(branch.name)
            end,
        },
        {
            label = "Delete…",
            enabled = localBranch and other,
            action = function()
                branches.delete(branch.name)
            end,
        },
        {
            label = "Show in graph",
            action = function()
                popup.close()
                require("views.graph").selectOid(branch.oid)
            end,
        },
        { separator = true },
        {
            label = "Track from " .. (current ~= "" and current or "the current branch"),
            visible = branch.isRemote,
            enabled = current ~= "" and repo.state().aheadBehind.upstream ~= branch.name,
            action = function()
                branches.track(current, branch.name)
            end,
        },
        {
            label = "Stop tracking " .. (branch.upstream or ""),
            visible = localBranch and (branch.upstream or "") ~= "",
            action = function()
                branches.track(branch.name, nil)
            end,
        },
        {
            label = "Copy branch name",
            action = function()
                shell.copy(branch.name, "branch name")
            end,
        },
    }
end

--- Show the current branch on the toolbar button's tooltip-free parts.
-- @param state  repository snapshot
function branches.refresh(state)
    if popup.isOpen("BranchPopup") then
        all = gitgud.branches()
        renderList()
    end
end

--- Wire the popup.
function branches.init()
    placeholder.bind("BranchFilterEdit", "BranchFilterPlaceholder")

    gitgud.on("BranchButton.clicked", function()
        if popup.isOpen("BranchPopup") then
            popup.close()
        else
            branches.show()
        end
    end)

    gitgud.on("BranchFilterEdit.changed", function(value)
        filterText = text.trim(value)
        renderList()
    end)

    gitgud.on("BranchFilterEdit.accepted", function()
        for _, branch in ipairs(rows) do
            if branch then
                onPicked(branch)
                return
            end
        end
    end)

    gitgud.on("BranchList.selected", function(value)
        local row = tonumber(value)
        local branch = row and rows[row + 1]
        if branch then
            onPicked(branch)
        end
    end)

    gitgud.on("BranchList.rightClicked", function(value)
        local x, y, row = menu.parseClick(value)
        local branch = row and rows[row]
        if branch then
            menu.popup(branches.branchMenu(branch), x, y)
        end
    end)

    gitgud.on("NewBranchButton.clicked", branches.create)

    gitgud.on("MergeIntoButton.clicked", function()
        openIn("merge")
    end)

    gitgud.on("RebaseOntoButton.clicked", function()
        openIn("rebase")
    end)
end

return branches
