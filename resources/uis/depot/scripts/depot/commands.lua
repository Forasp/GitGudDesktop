--- depot/commands.lua — the branch, label, integration, and connection
-- commands, done with Git (the file-level ones are depot/actions.lua).
--
--   Branches      new, switch (Get), rename, delete, compare
--   Merge/Integrate  merge a branch into the current one (or squash, rebase)
--   Copy / Cherry-pick  apply one submitted changelist here
--   Back Out      revert a submitted changelist
--   Resolve       settle conflicted files: yours, theirs, or merged by hand
--   Labels        new (tag a changelist), delete, push
--   Connection    fetch, push, remotes, workspaces (repositories)
--
-- The branch commands reuse the default UI's views/branches.lua (dialogs,
-- stash-before-switch, undo); everything is logged as its git command.

local app = require("core.app")
local branches = require("views.branches")
local dialog = require("ui.dialog")
local log = require("depot.log")
local repo = require("core.repo")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")
local util = require("depot.util")

local commands = {}

local q = log.quote

-- ---- branches ------------------------------------------------------------------------

--- New branch from the current one (or a revision), optionally switching.
-- @param from  revision to branch from (nil = the current branch)
function commands.newBranch(from)
    local state = repo.state()
    if state.headOid == "" then
        status.warn("Submit a first changelist before creating branches.")
        return
    end
    dialog.show({
        title = "New Branch",
        message = "Branch from " .. (from and util.change(from) or (state.branch ~= "" and state.branch or "HEAD"))
            .. ". Your pending changes stay in the workspace.",
        fields = { { label = "Branch name", value = "" } },
        checks = { { label = "Switch the workspace to the new branch", value = true } },
        ok = "Create",
        onOk = function(v)
            local name = text.trim(v.fields[1]):gsub("%s+", "-")
            if name == "" then
                return false, "Enter a branch name."
            end
            log.command("git branch " .. q(name) .. (from and (" " .. util.change(from)) or ""))
            local ok, err = undo.track("New branch " .. name, function()
                return gitgud.createBranch(name, from)
            end)
            if not ok then
                return false, err
            end
            log.info("Branch " .. name .. " created.")
            if v.checks[1] then
                commands.switchBranch(name)
            end
            app.requestRefresh()
            return true
        end,
    })
end

--- Switch the workspace to a branch (get the branch's files).
-- @param name  local or remote-tracking branch
function commands.switchBranch(name)
    log.command("git switch " .. q(name))
    if branches.checkoutByName(name) then
        log.info("Workspace switched to " .. name .. ".")
    end
end

--- Rename a local branch.
-- @param name  branch
function commands.renameBranch(name)
    log.command("git branch -m " .. q(name) .. " …")
    branches.rename(name)
end

--- Delete a local branch (asks; can delete the remote copy too).
-- @param name  branch
function commands.deleteBranch(name)
    log.command("git branch -d " .. q(name))
    branches.delete(name)
end

--- Delete a remote branch.
-- @param remoteName  e.g. "origin/topic"
function commands.deleteRemoteBranch(remoteName)
    local remote, branch = repo.splitRemoteBranch(remoteName)
    if not remote then
        return
    end
    dialog.confirm("Delete " .. remoteName .. "?", "The branch is deleted on " .. remote .. " for everyone.",
        "Delete", function()
            log.command("git push " .. remote .. " --delete " .. q(branch))
            gitgud.deleteRemoteBranch(remote, branch)
        end, true)
end

--- Make a local branch track a remote branch.
-- @param name      local branch
-- @param upstream  "origin/x" or nil to stop tracking
function commands.track(name, upstream)
    log.command("git branch --set-upstream-to=" .. tostring(upstream) .. " " .. q(name))
    branches.track(name, upstream)
end

--- Merge/Integrate: bring a branch into the current one.
-- @param source  branch name (nil: ask)
-- @param how     "merge" (default), "squash", or "rebase"
function commands.integrate(source, how)
    local state = repo.state()
    if state.branch == "" then
        status.warn("Switch to a branch first.")
        return
    end
    local run = function(name, mode)
        if mode == "rebase" then
            log.command("git rebase " .. q(name))
            branches.rebase(name)
        elseif mode == "squash" then
            log.command("git merge --squash " .. q(name))
            branches.squash(name)
        else
            log.command("git merge " .. q(name))
            branches.merge(name)
        end
    end
    if source then
        run(source, how)
        return
    end

    dialog.show({
        title = "Merge/Integrate",
        message = "Integrate another branch's submitted changes into " .. state.branch
            .. ". Conflicts, if any, show in the Pending tab: resolve them, then submit.",
        fields = { { label = "Source branch (local or remote, e.g. origin/main)", value = branches.defaultBranch() or "" } },
        checks = {
            { label = "Squash everything into one changelist", value = false },
            { label = "Rebase instead (replay " .. state.branch .. " on top of the source)", value = false },
        },
        ok = "Integrate",
        onOk = function(v)
            local name = text.trim(v.fields[1])
            if name == "" then
                return false, "Enter the source branch."
            end
            run(name, v.checks[2] and "rebase" or (v.checks[1] and "squash" or "merge"))
            return true
        end,
    })
end

--- Compare two branches: a folder diff of their tips.
-- @param a  branch/revision (older side)
-- @param b  branch/revision (newer side; default the current branch)
function commands.compare(a, b)
    b = b or "HEAD"
    require("depot.windows.folderdiff").open("", a, b)
end

-- ---- submitted changelists -----------------------------------------------------------

--- Copy (cherry-pick) a submitted changelist onto the current branch.
-- @param oid  commit
function commands.cherryPick(oid)
    log.command("git cherry-pick " .. util.change(oid))
    local result, err = undo.track("Cherry-pick " .. util.change(oid), function()
        return gitgud.cherryPick(oid)
    end)
    if result == nil then
        log.error(err or "Cherry-pick failed.")
    elseif result == "" then
        log.warn("The changelist conflicts with this branch: resolve the files, then submit.")
    else
        log.info("Copied as change " .. util.change(result) .. ".")
    end
    app.requestRefresh()
end

--- Back Out a submitted changelist (a new changelist undoing it).
-- @param oid  commit
function commands.backOut(oid)
    dialog.confirm("Back Out Changelist " .. util.change(oid),
        "Submit a new changelist that undoes " .. util.change(oid) .. "?", "Back Out",
        function()
            log.command("git revert " .. util.change(oid))
            local result, err = undo.track("Back out " .. util.change(oid), function()
                return gitgud.revert(oid)
            end)
            if result == nil then
                log.error(err or "Back out failed.")
            elseif result == "" then
                log.warn("Backing out conflicts with later changes: resolve the files, then submit.")
            else
                log.info("Backed out as change " .. util.change(result) .. ".")
            end
            app.requestRefresh()
        end)
end

--- Move the current branch to a changelist (the workspace follows).
-- @param oid   commit
-- @param mode  "soft" | "mixed" | "hard"
function commands.resetTo(oid, mode)
    dialog.confirm("Roll Back to " .. util.change(oid),
        mode == "hard" and "Move " .. repo.state().branch .. " back to " .. util.change(oid)
                .. " and DISCARD your pending changes? Later changelists stay reachable through Undo."
            or "Move " .. repo.state().branch .. " back to " .. util.change(oid)
                .. "? The later changelists' changes stay in your workspace as pending changes.",
        "Roll Back", function()
            log.command("git reset --" .. mode .. " " .. util.change(oid))
            log.report("Rolled back to " .. util.change(oid) .. ".", undo.track("Roll back to " .. util.change(oid),
                function()
                    return gitgud.resetTo(oid, mode)
                end, { soft = mode ~= "hard" }))
            app.requestRefresh()
        end, mode == "hard")
end

-- ---- resolve ------------------------------------------------------------------------------

--- Resolve conflicted files: accept yours, theirs, or the merged file as
-- edited; the default UI's merge tool is not part of this layout, so
-- "merged" means you edited the conflict markers out in your editor.
-- @param paths  conflicted files (default: all)
function commands.resolve(paths)
    paths = paths and #paths > 0 and paths or repo.state().conflicts
    if #paths == 0 then
        log.info("There are no files to resolve.")
        return
    end
    dialog.show({
        title = "Resolve",
        message = text.plural(#paths, "file") .. " to resolve: " .. table.concat(paths, ", ")
            .. "\n\nAccept Yours keeps your version, Accept Theirs takes the incoming one, "
            .. "Accept Merged keeps the file as you edited it (conflict markers removed).",
        fields = { { label = "Accept (yours, theirs, merged)", value = "merged" } },
        alt = {
            label = "Edit Files",
            action = function()
                local shell = require("core.shell")
                for _, path in ipairs(paths) do
                    shell.openInEditor(repo.state().path .. "/" .. path)
                end
            end,
        },
        ok = "Resolve",
        onOk = function(v)
            local choice = text.trim(v.fields[1]):lower()
            for _, path in ipairs(paths) do
                if choice == "yours" or choice == "theirs" then
                    log.command("git checkout --" .. (choice == "yours" and "ours" or "theirs") .. " " .. q(path))
                    local ok, err = gitgud.resolveConflict(path, choice == "yours" and "ours" or "theirs")
                    if not ok then
                        return false, err
                    end
                elseif choice == "merged" then
                    local content = gitgud.readRepoFile(path) or ""
                    if content:find("\n<<<<<<< ", 1, true) or content:sub(1, 8) == "<<<<<<< " then
                        return false, path .. " still has conflict markers."
                    end
                    log.command("git add " .. q(path))
                    local ok, err = gitgud.stage(path)
                    if not ok then
                        return false, err
                    end
                else
                    return false, "Type yours, theirs, or merged."
                end
            end
            log.info("Resolved " .. text.plural(#paths, "file") .. ".")
            app.requestRefresh()
            return true
        end,
    })
end

--- Abandon a merge / rebase / cherry-pick in progress.
function commands.abort()
    dialog.confirm("Abort", "Abandon the " .. repo.state().operation .. " in progress and put the workspace back?",
        "Abort", function()
            log.command("git " .. repo.state().operation .. " --abort")
            log.report("Aborted.", gitgud.abortOperation())
            app.requestRefresh()
        end, true)
end

-- ---- labels -------------------------------------------------------------------------------

--- New label (tag) on a changelist.
-- @param target  revision (default HEAD)
function commands.newLabel(target)
    dialog.show({
        title = "New Label",
        message = "Label changelist " .. (target and util.change(target) or "HEAD") .. ".",
        fields = {
            { label = "Label name", value = "" },
            { label = "Description (optional: makes an annotated label)", value = "" },
        },
        ok = "Create",
        onOk = function(v)
            local name = text.trim(v.fields[1]):gsub("%s+", "-")
            if name == "" then
                return false, "Enter a label name."
            end
            local message = text.trim(v.fields[2])
            log.command("git tag " .. (message ~= "" and ("-a -m " .. q(message) .. " ") or "") .. q(name)
                .. (target and (" " .. util.change(target)) or ""))
            local ok, err = gitgud.createTag(name, target, message ~= "" and message or nil)
            if not ok then
                return false, err
            end
            log.info("Label " .. name .. " created.")
            app.requestRefresh()
            return true
        end,
    })
end

--- Delete a label.
-- @param name  tag
function commands.deleteLabel(name)
    dialog.confirm("Delete Label " .. name, "Delete the label locally? (A pushed label stays on the remote.)",
        "Delete", function()
            log.command("git tag -d " .. q(name))
            log.report("Label " .. name .. " deleted.", gitgud.deleteTag(name))
            app.requestRefresh()
        end, true)
end

--- Push every label.
function commands.pushLabels()
    local remote = repo.primaryRemote()
    if not remote then
        log.warn("No remote to push labels to.")
        return
    end
    log.command("git push " .. remote .. " --tags")
    require("views.sync").pushTags(remote)
end

-- ---- connection ------------------------------------------------------------------------------

--- Fetch every remote (a centralized server has no equivalent).
function commands.fetch()
    log.command("git fetch --all")
    require("views.sync").fetch()
end

--- Push the current branch.
function commands.push()
    log.command("git push")
    require("views.sync").push()
end

--- Force push (after rewriting history).
function commands.forcePush()
    log.command("git push --force-with-lease")
    require("views.sync").forcePush()
end

--- Pull (Get Latest).
function commands.pull()
    require("depot.actions").getLatest()
end

--- Open another workspace (repository).
-- @param path  folder
function commands.openWorkspace(path)
    log.command("cd " .. q(path))
    require("views.repositories").open(path)
end

--- Remotes dialog: list, add, edit, remove.
function commands.remotes()
    local remotes = require("views.remotes")
    local items = {}
    for _, remote in ipairs(repo.state().remotes) do
        items[#items + 1] = remote.name .. "  —  " .. remote.url
    end
    dialog.show({
        title = "Remotes",
        message = #items > 0 and table.concat(items, "\n") or "This workspace has no remotes.",
        fields = { { label = "Remote to edit or remove (blank to add a new one)", value = repo.primaryRemote() or "" } },
        alt = {
            label = "Remove",
            action = function(v)
                local name = text.trim(v.fields[1])
                if name ~= "" then
                    remotes.remove(name)
                end
            end,
        },
        ok = "Add / Edit…",
        onOk = function(v)
            local name = text.trim(v.fields[1])
            -- The next dialog replaces this one.
            gitgud.after(1, function()
                if name == "" or not repo.remote(name) then
                    remotes.add()
                else
                    remotes.edit(name)
                end
            end)
            return true
        end,
    })
end

return commands
