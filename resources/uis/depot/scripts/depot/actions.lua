--- depot/actions.lua — the workspace commands, done with Git.
--
--   Get Latest       pull the current branch from its upstream
--   Get Revision     put a file (or the whole workspace) at a revision
--   Check Out        open files for edit in a changelist (no lock: Git has none)
--   Mark for Add     open untracked files for add
--   Mark for Delete  delete files (to the trash) and open the deletion
--   Rename/Move      move a file: the old path deleted, the new one added
--   Revert           throw away a file's changes (an added file stays on disk)
--   Revert Unchanged take unchanged files out of their changelists
--   Submit           commit exactly the changelist's checked files
--   Shelve           snapshot files onto a shelf branch, optionally shared
--   Unshelve         bring a shelf's files back, merging with local edits
--
-- Every action logs the git command it amounts to (depot/log.lua). Changelists
-- are depot/changelists.lua; branch, label, and history commands are in
-- depot/commands.lua.

local app = require("core.app")
local changedialog = require("depot.changedialog")
local changelists = require("depot.changelists")
local dialog = require("ui.dialog")
local log = require("depot.log")
local repo = require("core.repo")
local selection = require("depot.selection")
local settings = require("core.settings")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")

local actions = {}

local q = log.quote

--- A space-separated, quoted path list for a logged command (shortened).
-- @param paths  array
-- @return string
local function pathList(paths)
    local shown = {}
    for i, path in ipairs(paths) do
        if i > 4 then
            shown[#shown + 1] = "… (" .. #paths .. " files)"
            break
        end
        shown[#shown + 1] = q(path)
    end

    return table.concat(shown, " ")
end

--- The user's name for shelf branches ("shelves/<user>/<n>").
-- @return a branch-safe user name
function actions.userSlug()
    local name = gitgud.config("user.email"):match("^([^@]+)") or ""
    if name == "" then
        name = gitgud.config("user.name")
    end
    name = name:lower():gsub("[^%w%-_%.]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")

    return name ~= "" and name or "me"
end

--- The branch a changelist shelves to.
-- @param id  changelist id
-- @return branch name
function actions.shelfBranch(id)
    local prefix = settings.get("depot.shelfPrefix", "shelves/{user}/")
    prefix = prefix:gsub("{user}", actions.userSlug())

    return prefix .. tostring(id)
end

--- Changelist label: "default" or "change 3".
-- @param id  changelist id
-- @return label
local function clName(id)
    return id == 0 and "the default changelist" or ("changelist " .. id)
end

--- The status row of a path, or nil.
local function fileStatus(path)
    return repo.file(path)
end

--- Is the repository usable for these commands?
-- @return boolean (shows a message when not)
local function needRepo()
    if not repo.state().open then
        status.warn("Open a workspace (repository) first: Connection > Open Workspace.")
        return false
    end

    return true
end

-- ---- getting files ----------------------------------------------------------------

--- Get Latest Revision: pull the current branch.
function actions.getLatest()
    if not needRepo() then
        return
    end
    local remote = repo.upstreamRemote()
    if not remote then
        log.warn("This workspace has no remote to get from (Connection > Remotes).")
        return
    end
    log.command("git pull " .. remote)
    require("views.sync").pull()
end

--- Get Revision: a file at a revision (opened for edit in the default
-- changelist), or the whole workspace (a checkout).
-- @param paths  files (empty = the whole workspace)
-- @param rev    revision to offer first (default "HEAD")
function actions.getRevision(paths, rev)
    if not needRepo() then
        return
    end
    paths = paths or selection.files()
    dialog.show({
        title = "Get Revision",
        message = #paths > 0
                and ("Put " .. text.plural(#paths, "file") .. " at a revision. They open for edit so "
                    .. "you can submit the older content.")
            or "Check out the whole workspace at a revision: a branch, label, or changelist id.",
        fields = { { label = "Revision (changelist id, branch, or label)", value = rev or "HEAD" } },
        ok = "Get Revision",
        onOk = function(v)
            local revision = text.trim(v.fields[1])
            if revision == "" then
                return false, "Enter a revision."
            end
            if #paths == 0 then
                log.command("git checkout " .. q(revision))
                local ok, err = gitgud.checkout(revision)
                if not ok then
                    ok, err = gitgud.checkoutCommit(revision)
                end
                if not ok then
                    return false, err
                end
                log.info("Workspace is at " .. revision)
                return true
            end
            for _, path in ipairs(paths) do
                log.command("git show " .. q(revision .. ":" .. path) .. " > " .. q(path))
                local content = gitgud.fileAt(path, revision)
                if content == nil then
                    return false, path .. " doesn't exist at " .. revision .. "."
                end
                local ok, err = gitgud.writeRepoFile(path, content)
                if not ok then
                    return false, err
                end
            end
            changelists.open(paths, 0)
            log.info("Got " .. text.plural(#paths, "file") .. " at " .. revision .. ".")
            return true
        end,
    })
end

-- ---- opening files ------------------------------------------------------------------

--- Check Out: open files for edit (in a changelist).
-- @param paths  files (default: the selection)
-- @param id     changelist (default 0)
function actions.checkOut(paths, id)
    paths = paths or selection.files()
    if #paths == 0 then
        status.warn("Select the files to check out.")
        return
    end
    changelists.open(paths, id or 0)
    log.command("check out " .. pathList(paths) .. "   (git: no lock needed)")
    log.info(text.plural(#paths, "file") .. " opened for edit in " .. clName(id or 0) .. ".")
end

--- Mark for Add: open untracked files for add.
-- @param paths  files (default: the selection's untracked files)
-- @param id     changelist (default 0)
function actions.markForAdd(paths, id)
    paths = paths or selection.files()
    local adds = {}
    for _, path in ipairs(paths) do
        local file = fileStatus(path)
        if file and file.code == "?" then
            adds[#adds + 1] = path
        end
    end
    if #adds == 0 then
        status.warn("Select new (untracked) files to add.")
        return
    end
    changelists.markForAdd(adds, id)
    log.command("git add --intent-to-add " .. pathList(adds))
    log.info(text.plural(#adds, "file") .. " opened for add.")
end

--- Mark for Delete: delete files (to the trash) and open the deletions.
-- @param paths  files (default: the selection)
-- @param id     changelist (default 0)
function actions.markForDelete(paths, id)
    paths = paths or selection.files()
    if #paths == 0 then
        status.warn("Select the files to delete.")
        return
    end
    dialog.confirm("Mark for Delete",
        "Delete " .. text.plural(#paths, "file") .. " from the workspace (they go to the " .. require("core.shell").names.trash .. ") and open "
            .. "the deletion" .. (#paths == 1 and "" or "s") .. " in " .. clName(id or 0) .. "?",
        "Delete",
        function()
            log.command("git rm " .. pathList(paths))
            for _, path in ipairs(paths) do
                local ok, err = gitgud.trashRepoFile(path)
                if not ok then
                    log.error("Couldn't delete " .. path .. ": " .. tostring(err))
                end
            end
            changelists.open(paths, id or 0)
            log.info(text.plural(#paths, "file") .. " opened for delete.")
            app.requestRefresh()
        end,
        true)
end

--- Rename/Move a file: write it at the new path, delete the old one, and
-- open both in the old one's changelist (Git records a rename).
-- @param path  file (default: the selected file)
function actions.rename(path)
    path = path or selection.files()[1]
    if not path then
        status.warn("Select a file to rename or move.")
        return
    end
    dialog.prompt("Rename/Move", "New path (relative to the workspace root)", path, "Rename",
        function(target)
            target = target:gsub("\\", "/"):gsub("^/+", "")
            if target == "" or target == path then
                return false, "Enter a different path."
            end
            if gitgud.readRepoFile(target) ~= nil then
                return false, target .. " already exists."
            end
            local content = gitgud.readRepoFile(path)
            if content == nil then
                return false, "Couldn't read " .. path .. "."
            end
            log.command("git mv " .. q(path) .. " " .. q(target))
            local ok, err = gitgud.writeRepoFile(target, content)
            if not ok then
                return false, err
            end
            local trashed, trashErr = gitgud.trashRepoFile(path)
            if not trashed then
                return false, trashErr
            end
            local id = changelists.of(path)
            changelists.open({ path }, id)
            changelists.markForAdd({ target }, id)
            log.info("Moved " .. path .. " to " .. target .. ".")
            app.requestRefresh()
            return true
        end)
end

--- Revert: throw away the files' changes. A file opened for add is only
-- un-opened (it stays on disk).
-- @param paths  files (default: the selection's changed files)
function actions.revert(paths)
    paths = paths or selection.changedFiles()
    if #paths == 0 then
        paths = selection.files()
    end
    if #paths == 0 then
        status.warn("Select the files to revert.")
        return
    end

    local discard, unopen, unstage = {}, {}, {}
    for _, path in ipairs(paths) do
        local file = fileStatus(path)
        if not file then
            unopen[#unopen + 1] = path
        elseif file.code == "?" then
            unopen[#unopen + 1] = path
        elseif file.code == "A" then
            unstage[#unstage + 1] = path
        else
            discard[#discard + 1] = path
        end
    end

    local run = function()
        if #unstage > 0 then
            log.command("git rm --cached " .. pathList(unstage))
            log.report(nil, gitgud.unstage(unstage))
        end
        if #discard > 0 then
            log.command("git restore --staged --worktree " .. pathList(discard))
            log.report(nil, gitgud.discard(discard))
        end
        changelists.release(paths)
        log.info("Reverted " .. text.plural(#paths, "file") .. ".")
        app.requestRefresh()
    end

    if #discard == 0 or not settings.get("confirmDiscard", true) then
        run()
        return
    end
    dialog.confirm("Revert Files",
        "Revert " .. text.plural(#paths, "file") .. "? Your changes to "
            .. text.plural(#discard, "file") .. " are lost (new files keep their content).",
        "Revert", run, true)
end

--- Revert Unchanged Files: take opened-but-unchanged files out of their
-- changelists.
-- @param paths  files (default: every opened file)
function actions.revertUnchanged(paths)
    local unchanged = {}
    for _, cl in ipairs(changelists.all()) do
        for _, file in ipairs(cl.files) do
            if file.opened and (not paths or #paths == 0 or selection.files()[1]) then
                unchanged[#unchanged + 1] = file.path
            end
        end
    end
    if #unchanged == 0 then
        log.info("No unchanged files are open.")
        return
    end
    changelists.release(unchanged)
    log.command("revert unchanged " .. pathList(unchanged))
    log.info(text.plural(#unchanged, "unchanged file") .. " reverted.")
end

-- ---- changelists ---------------------------------------------------------------------

--- A form row for each file of a changelist.
-- @param cl  changelist (changelists.all() shape)
-- @return rows for changedialog
local function formFiles(cl)
    local rows = {}
    for _, file in ipairs(cl.files) do
        rows[#rows + 1] = { path = file.path, code = file.code, checked = true,
            action = file.opened and "edit (unchanged)" or nil }
    end

    return rows
end

--- "Workspace: repo    Branch: main".
local function workspaceInfo()
    local state = repo.state()
    local branch = state.branch ~= "" and state.branch or (state.detached and "(detached)" or "(none)")

    return "Workspace: " .. state.name .. "      Branch: " .. branch .. "      User: "
        .. gitgud.config("user.name")
end

--- New Pending Changelist (optionally moving files into it).
-- @param paths  files to move in (default: the selected opened files)
function actions.newChangelist(paths)
    if not needRepo() then
        return
    end
    paths = paths or selection.files()
    local candidates = {}
    for _, path in ipairs(paths) do
        candidates[#candidates + 1] = { path = path, code = fileStatus(path) and fileStatus(path).code, checked = true }
    end
    changedialog.show({
        title = "New Pending Changelist",
        info = workspaceInfo(),
        description = "",
        files = candidates,
        filesLabel = "Files to move into it:",
        ok = "Create",
        onOk = function(v)
            if text.trim(v.description) == "" then
                return false, "Enter a description."
            end
            local id = changelists.create(v.description, v.files)
            log.command("new changelist " .. id .. "   (local only)")
            log.info("Change " .. id .. " created" .. (#v.files > 0 and (" with " .. text.plural(#v.files, "file")) or "") .. ".")
            return true
        end,
    })
end

--- Edit a pending changelist's description and files.
-- @param id  changelist id
function actions.editChangelist(id)
    local cl = changelists.get(id)
    if not cl then
        return
    end
    if id == 0 then
        -- The default changelist has no description: editing it means
        -- making a numbered one.
        actions.newChangelist(require("depot.util").pathsOf(cl.files))
        return
    end
    changedialog.show({
        title = "Edit Pending Changelist " .. id,
        info = workspaceInfo(),
        description = cl.description,
        files = formFiles(cl),
        filesLabel = "Files (leave one unchecked to move it to the default changelist):",
        ok = "Save",
        onOk = function(v)
            changelists.setDescription(id, v.description)
            local keep = {}
            for _, path in ipairs(v.files) do
                keep[path] = true
            end
            local out = {}
            for _, file in ipairs(cl.files) do
                if not keep[file.path] then
                    out[#out + 1] = file.path
                end
            end
            if #out > 0 then
                changelists.move(out, 0)
            end
            log.info("Change " .. id .. " updated.")
            return true
        end,
    })
end

--- Delete an empty pending changelist.
-- @param id  changelist id
function actions.deleteChangelist(id)
    local cl = changelists.get(id)
    if not cl or id == 0 then
        return
    end
    if cl.shelf then
        dialog.alert("Delete Changelist", "Change " .. id .. " has shelved files. Delete the shelved files first.")
        return
    end
    if #cl.files > 0 then
        dialog.confirm("Delete Changelist", "Change " .. id .. " has open files. Move them to the default changelist and delete it?",
            "Delete", function()
                changelists.move(require("depot.util").pathsOf(cl.files), 0)
                changelists.delete(id)
                log.info("Change " .. id .. " deleted.")
            end)
        return
    end
    changelists.delete(id)
    log.info("Change " .. id .. " deleted.")
end

--- Move files to another changelist (a menu of targets at x, y).
-- @param paths  files
-- @param x      menu position
-- @param y      menu position
function actions.moveToChangelistMenu(paths, x, y)
    local items = { { label = "Move " .. text.plural(#paths, "file") .. " to…", enabled = false } }
    for _, cl in ipairs(changelists.all()) do
        local id = cl.id
        items[#items + 1] = {
            label = id == 0 and "Default" or (id .. "  " .. (cl.description:match("^[^\n]*") or "")),
            action = function()
                changelists.move(paths, id)
                log.command("move to changelist " .. (id == 0 and "default" or id) .. " " .. pathList(paths))
                log.info(text.plural(#paths, "file") .. " moved to " .. clName(id) .. ".")
            end,
        }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "New Changelist…", action = function()
        actions.newChangelist(paths)
    end }
    require("ui.menu").popup(items, x, y)
end

-- ---- submit ------------------------------------------------------------------------------

--- Commit exactly these files: the index is reset to HEAD for everything
-- else, then these are staged and committed.
-- @param paths    files
-- @param message  commit message
-- @return oid or nil, error
local function commitFiles(paths, message)
    local staged = {}
    local wanted = {}
    for _, path in ipairs(paths) do
        wanted[path] = true
    end
    for _, file in ipairs(repo.state().files) do
        if file.staged and not wanted[file.path] then
            staged[#staged + 1] = file.path
        end
    end
    if #staged > 0 and repo.state().operation == "none" then
        local ok, err = gitgud.unstage(staged)
        if not ok then
            return nil, err
        end
    end
    local ok, err = gitgud.stage(paths)
    if not ok then
        return nil, err
    end

    return gitgud.commit(message)
end

--- Submit a changelist.
-- @param id  changelist id (default: the selected changelist, else default)
function actions.submit(id)
    if not needRepo() then
        return
    end
    if id == nil then
        local item = selection.primary()
        id = item and item.change or 0
    end
    local cl = changelists.get(id)
    if not cl then
        return
    end
    local submittable = {}
    for _, file in ipairs(cl.files) do
        if not file.opened then
            submittable[#submittable + 1] = { path = file.path, code = file.code, checked = true }
        end
    end
    if #submittable == 0 then
        dialog.alert("Submit", clName(id):sub(1, 1):upper() .. clName(id):sub(2) .. " has no changed files to submit.")
        return
    end
    if cl.shelf then
        dialog.alert("Submit", "Change " .. id .. " has shelved files. Delete the shelved files (or unshelve them) before submitting.")
        return
    end
    if #repo.state().conflicts > 0 then
        dialog.alert("Submit", "Resolve the conflicted files first (Actions > Resolve).")
        return
    end

    local remote = repo.upstreamRemote()
    changedialog.show({
        title = "Submit " .. (id == 0 and "Default Changelist" or ("Changelist " .. id)),
        info = workspaceInfo(),
        description = cl.description,
        files = submittable,
        filesLabel = "Files to submit:",
        options = {
            { label = "Push to " .. (remote or "the remote") .. " after submitting", value = settings.get("depot.pushAfterSubmit", false) and remote ~= nil },
            { label = "Check out submitted files after submit", value = false },
        },
        ok = "Submit",
        onOk = function(v)
            if text.trim(v.description) == "" then
                return false, "Enter a description."
            end
            if #v.files == 0 then
                return false, "Check at least one file."
            end
            log.command("git commit -m " .. q(v.description:match("^[^\n]*")) .. " " .. pathList(v.files))
            local oid, err = undo.track("Submit " .. (id == 0 and "default changelist" or ("change " .. id)),
                function()
                    return commitFiles(v.files, v.description)
                end, { soft = true })
            if not oid then
                log.error("Submit failed: " .. tostring(err))
                return false, err
            end
            settings.set("depot.pushAfterSubmit", v.options[1])
            changelists.release(v.files)
            if v.options[2] then
                changelists.open(v.files, id)
            elseif id ~= 0 and #(changelists.get(id) or { files = {} }).files == 0 then
                changelists.delete(id)
            end
            log.info("Change " .. oid:sub(1, 8) .. " submitted.")
            status.ok("Submitted change " .. oid:sub(1, 8) .. ".")
            if v.options[1] and remote then
                log.command("git push " .. remote)
                require("views.sync").push()
            end
            app.requestRefresh()
            return true
        end,
    })
end

-- ---- shelving -------------------------------------------------------------------------------

--- Shelve a changelist's files onto its shelf branch.
-- @param id  changelist id
function actions.shelve(id)
    if not needRepo() then
        return
    end
    if id == nil then
        local item = selection.primary()
        id = item and item.change or 0
    end
    local cl = changelists.get(id)
    if not cl then
        return
    end
    if repo.state().headOid == "" then
        dialog.alert("Shelve", "Submit a first changelist before shelving: a shelf is built on top of the latest one.")
        return
    end
    local files = {}
    for _, file in ipairs(cl.files) do
        if not file.opened then
            files[#files + 1] = { path = file.path, code = file.code, checked = true }
        end
    end
    if #files == 0 then
        dialog.alert("Shelve", "There are no changed files to shelve in " .. clName(id) .. ".")
        return
    end

    local remote = repo.primaryRemote()
    changedialog.show({
        title = "Shelve " .. (id == 0 and "Default Changelist" or ("Changelist " .. id)),
        info = workspaceInfo(),
        description = cl.description ~= "" and cl.description or "",
        files = files,
        filesLabel = "Files to shelve:",
        options = {
            { label = "Revert checked out files after they are shelved", value = false },
            { label = "Share the shelf: push it to " .. (remote or "the remote"), value = remote ~= nil and settings.get("depot.pushShelves", true) },
        },
        ok = "Shelve",
        onOk = function(v)
            if text.trim(v.description) == "" then
                return false, "Enter a description."
            end
            if #v.files == 0 then
                return false, "Check at least one file."
            end
            -- Shelving the default changelist makes it a numbered one first.
            local target = id
            if target == 0 then
                target = changelists.create(v.description, v.files)
            else
                changelists.setDescription(target, v.description)
            end
            local branch = actions.shelfBranch(target)
            local message = v.description .. "\n\nShelved-Change: " .. target .. "\nShelved-By: "
                .. gitgud.config("user.name")
            log.command("git branch " .. branch .. "  (commit of " .. pathList(v.files) .. " on HEAD)")
            local oid, err = gitgud.shelve(branch, v.files, message)
            if not oid then
                log.error("Shelve failed: " .. tostring(err))
                return false, err
            end
            local share = v.options[2] and remote ~= nil
            settings.set("depot.pushShelves", v.options[2])
            changelists.setShelf(target, { branch = branch, oid = oid, pushedTo = share and remote or "", files = v.files })
            log.info("Change " .. target .. " shelved (" .. text.plural(#v.files, "file") .. ") on branch " .. branch .. ".")
            if share then
                log.command("git push --force " .. remote .. " " .. branch)
                gitgud.pushBranch(remote, branch, { force = true })
            end
            if v.options[1] then
                actions.revertQuiet(v.files)
                changelists.open(v.files, target)
            end
            app.requestRefresh()
            return true
        end,
    })
end

--- Revert without asking (after shelving).
-- @param paths  files
function actions.revertQuiet(paths)
    local discard, unstage = {}, {}
    for _, path in ipairs(paths) do
        local file = fileStatus(path)
        if file and file.code == "A" then
            unstage[#unstage + 1] = path
        elseif file and file.code ~= "?" then
            discard[#discard + 1] = path
        end
    end
    if #unstage > 0 then
        gitgud.unstage(unstage)
    end
    if #discard > 0 then
        log.command("git restore --staged --worktree " .. pathList(discard))
        log.report(nil, gitgud.discard(discard))
    end
end

--- The files a shelf commit changed.
-- @param oid  shelf commit
-- @return array of { path, code }
function actions.shelvedFiles(oid)
    local files = {}
    for _, file in ipairs(gitgud.changedFiles(oid .. "^", oid) or {}) do
        files[#files + 1] = { path = file.path, code = file.status }
    end

    return files
end

--- Unshelve: bring shelved files into the workspace.
-- @param shelf  { branch, oid, change? (the local changelist that owns it) }
function actions.unshelve(shelf)
    if not needRepo() then
        return
    end
    local oid = shelf.oid or shelf.branch
    local files = {}
    for _, file in ipairs(actions.shelvedFiles(oid)) do
        files[#files + 1] = { path = file.path, code = file.code, checked = true }
    end
    if #files == 0 then
        dialog.alert("Unshelve", "That shelf has no files.")
        return
    end

    local targets = { "Unshelve into the default changelist" }
    changedialog.show({
        title = "Unshelve " .. (shelf.change and ("Changelist " .. shelf.change) or shelf.branch),
        info = "Shelf: " .. shelf.branch .. "   (" .. oid:sub(1, 8) .. ")",
        files = files,
        filesLabel = "Shelved files to unshelve:",
        options = {
            { label = shelf.change and ("Unshelve into changelist " .. shelf.change) or targets[1], value = true },
            { label = "Delete the shelf after unshelving", value = false },
        },
        ok = "Unshelve",
        onOk = function(v)
            if #v.files == 0 then
                return false, "Check at least one file."
            end
            log.command("unshelve " .. (shelf.change or shelf.branch) .. "   (git: merge " .. shelf.branch .. "'s files)")
            local result, err = gitgud.unshelve(oid, v.files)
            if not result then
                log.error("Unshelve failed: " .. tostring(err))
                return false, err
            end
            local target = (v.options[1] and shelf.change) or 0
            local opened = {}
            for _, path in ipairs(result.applied) do
                opened[#opened + 1] = path
            end
            for _, path in ipairs(result.conflicted) do
                opened[#opened + 1] = path
            end
            changelists.open(opened, target)
            for _, path in ipairs(opened) do
                if gitgud.fileAt(path, "HEAD") == nil then
                    changelists.markForAdd({ path }, target)
                end
            end
            log.info("Unshelved " .. text.plural(#result.applied, "file") .. " into " .. clName(target) .. ".")
            if #result.conflicted > 0 then
                log.warn("Conflicts in " .. table.concat(result.conflicted, ", ")
                    .. " — both you and the shelf changed the same lines; edit the conflict markers.")
            end
            if #result.skipped > 0 then
                log.warn("Left alone (binary or deleted and edited): " .. table.concat(result.skipped, ", "))
            end
            if v.options[2] then
                actions.deleteShelf(shelf, true)
            end
            app.requestRefresh()
            return true
        end,
    })
end

--- Delete a shelf: its branch (and the pushed copy).
-- @param shelf  { branch, change?, pushedTo?, remote? (for someone else's) }
-- @param quiet  true: don't ask
function actions.deleteShelf(shelf, quiet)
    local run = function()
        local localBranch = shelf.branch
        if not shelf.remote then
            log.command("git branch -D " .. localBranch)
            gitgud.deleteBranch(localBranch)
        end
        local remote = shelf.remote or (shelf.pushedTo ~= "" and shelf.pushedTo) or nil
        if remote then
            log.command("git push " .. remote .. " --delete " .. localBranch)
            gitgud.deleteRemoteBranch(remote, localBranch)
        end
        if shelf.change then
            changelists.setShelf(shelf.change, nil)
        end
        log.info("Shelf " .. localBranch .. " deleted.")
        app.requestRefresh()
    end
    if quiet then
        run()
        return
    end
    dialog.confirm("Delete Shelved Files",
        "Delete the shelf " .. shelf.branch .. "? Its branch is deleted"
            .. ((shelf.remote or (shelf.pushedTo or "") ~= "") and ", on the remote too." or "."),
        "Delete", run, true)
end

--- Shelves other people pushed (remote branches under the shelf prefix),
-- and my own that aren't recorded locally.
-- @return array of { branch, remote, oid, user, change, summary, time }
function actions.remoteShelves()
    local out = {}
    for _, branch in ipairs(gitgud.branches()) do
        if branch.isRemote then
            local remote, name = repo.splitRemoteBranch(branch.name)
            if remote and name:match("^shelves/") then
                local commit = (gitgud.history({ max = 1, from = branch.oid }) or {})[1] or {}
                out[#out + 1] = {
                    branch = name,
                    remote = remote,
                    oid = branch.oid,
                    user = name:match("^shelves/([^/]+)/") or "",
                    change = tonumber((commit.message or ""):match("Shelved%-Change: (%d+)")),
                    summary = commit.summary or "",
                    author = commit.author or "",
                    time = commit.time or 0,
                }
            end
        end
    end

    return out
end

-- A Perforce workspace runs these as p4 commands (depot/p4actions.lua).
-- Actions it doesn't define (new / edit / delete changelist, move to
-- changelist) are the ones above, which work through depot/changelists.lua.
return setmetatable({}, {
    __index = function(_, key)
        if gitgud.backend() == "p4" then
            local p4action = require("depot.p4actions")[key]
            if p4action ~= nil then
                return p4action
            end
        end
        return actions[key]
    end,
})
