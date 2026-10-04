--- depot/p4actions.lua: the workspace commands on a Perforce server.
--
-- depot/actions.lua hands these calls here when the open workspace is a
-- Perforce one (gitgud.backend() == "p4"); every other action (new / edit /
-- delete changelist, move to changelist) works unchanged through
-- depot/p4changelists.lua. Each command is the p4 command it names:
--
--   Get Latest / Get Revision   p4 sync (files you changed without opening
--                               them are left alone and listed)
--   Check Out                   p4 edit        Mark for Add     p4 add
--   Mark for Delete             p4 delete      Rename/Move      p4 move
--   Revert                      p4 revert      Revert Unchanged p4 revert -a
--   Reconcile Offline Work      opens what you changed without checking out
--   Submit                      p4 submit (unchecked files move to default)
--   Shelve / Unshelve           p4 shelve / unshelve (shelves are on the
--                               server, so everyone can see them)
--   Lock / Unlock               p4 lock / unlock

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

local p4actions = {}

local q = log.quote

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

local function changeArg(id)
    return (id == nil or id == 0) and "default" or tostring(id)
end

local function clName(id)
    return (id == nil or id == 0) and "the default changelist" or ("changelist " .. id)
end

local function needRepo()
    if not repo.state().open then
        status.warn("Open a workspace first: Connection > Open Workspace.")
        return false
    end

    return true
end

--- Log a p4 call's outcome; refresh after a change. Returns its result.
local function run(command, fn, ...)
    log.command(command)
    local result, err = fn(...)
    if result == nil then
        log.error(tostring(err))
        return nil, err
    end
    changelists.reload()
    app.requestRefresh()

    return result
end

local function workspaceInfo()
    local state = repo.state()
    return "Workspace: " .. gitgud.config("p4.client") .. "      Stream: "
        .. (state.branch ~= "" and state.branch or "(none)") .. "      User: " .. gitgud.config("p4.user")
end

function p4actions.userSlug()
    return gitgud.config("p4.user")
end

function p4actions.shelfBranch(id)
    return "change " .. tostring(id)
end

-- ---- getting files ----------------------------------------------------------------

function p4actions.getLatest(paths)
    if not needRepo() then
        return
    end
    paths = paths or {}
    log.command("p4 sync " .. (#paths > 0 and pathList(paths) or "//" .. gitgud.config("p4.client") .. "/..."))
    gitgud.p4Sync(paths, "")
end

function p4actions.getRevision(paths, rev)
    if not needRepo() then
        return
    end
    paths = paths or selection.files()
    dialog.show({
        title = "Get Revision",
        message = #paths > 0 and ("Get " .. text.plural(#paths, "file") .. " at a revision.")
            or "Get the whole workspace at a revision.",
        fields = { { label = "Revision: changelist number, #rev, a label, or none (remove)", value = rev or "" } },
        ok = "Get Revision",
        onOk = function(v)
            local revision = text.trim(v.fields[1])
            if revision == "" or revision:lower() == "head" or revision:lower() == "latest" then
                revision = ""
            end
            log.command("p4 sync " .. (#paths > 0 and pathList(paths) or "...") .. (revision ~= "" and ("@" .. revision) or ""))
            gitgud.p4Sync(paths, revision)
            return true
        end,
    })
end

-- ---- opening files ------------------------------------------------------------------

function p4actions.checkOut(paths, id)
    paths = paths or selection.files()
    if #paths == 0 then
        status.warn("Select the files to check out.")
        return
    end
    if run("p4 edit -c " .. changeArg(id) .. " " .. pathList(paths), gitgud.p4Edit, paths, changeArg(id)) then
        log.info(text.plural(#paths, "file") .. " opened for edit in " .. clName(id) .. ".")
    end
end

function p4actions.markForAdd(paths, id)
    paths = paths or selection.files()
    local adds = {}
    for _, path in ipairs(paths) do
        local file = repo.file(path)
        if file and file.code == "?" then
            adds[#adds + 1] = path
        end
    end
    if #adds == 0 then
        status.warn("Select new files (not in the depot yet) to add.")
        return
    end
    if run("p4 add -c " .. changeArg(id) .. " " .. pathList(adds), gitgud.p4Add, adds, changeArg(id)) then
        log.info(text.plural(#adds, "file") .. " opened for add.")
    end
end

function p4actions.markForDelete(paths, id)
    paths = paths or selection.files()
    if #paths == 0 then
        status.warn("Select the files to delete.")
        return
    end
    dialog.confirm("Mark for Delete",
        "Open " .. text.plural(#paths, "file") .. " for delete in " .. clName(id) .. "? "
            .. "They're removed from the workspace now and from the depot when you submit.",
        "Delete",
        function()
            if run("p4 delete -c " .. changeArg(id) .. " " .. pathList(paths), gitgud.p4Delete, paths, changeArg(id)) then
                log.info(text.plural(#paths, "file") .. " opened for delete.")
            end
        end,
        true)
end

function p4actions.rename(path)
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
            local ok, err = run("p4 move " .. q(path) .. " " .. q(target), gitgud.p4Move, path, target,
                changeArg(changelists.of(path)))
            if not ok then
                return false, err
            end
            log.info("Moved " .. path .. " to " .. target .. ".")
            return true
        end)
end

function p4actions.revert(paths)
    paths = paths or selection.files()
    if #paths == 0 then
        status.warn("Select the files to revert.")
        return
    end
    local function go()
        if run("p4 revert " .. pathList(paths), gitgud.p4Revert, paths, false) then
            log.info("Reverted " .. text.plural(#paths, "file") .. ".")
        end
    end
    if not settings.get("confirmDiscard", true) then
        go()
        return
    end
    dialog.confirm("Revert Files",
        "Revert " .. text.plural(#paths, "file") .. "? Changes to files opened for edit are lost; "
            .. "files opened for add stay on disk.",
        "Revert", go, true)
end

function p4actions.revertQuiet(paths)
    run("p4 revert " .. pathList(paths), gitgud.p4Revert, paths, false)
end

function p4actions.revertUnchanged()
    local reverted = run("p4 revert -a", gitgud.p4RevertUnchanged)
    if reverted then
        log.info(#reverted == 0 and "No unchanged files are open."
            or (text.plural(#reverted, "unchanged file") .. " reverted."))
    end
end

--- Reconcile Offline Work: open what changed without being checked out.
-- @param paths  files or folders (default: the whole workspace)
function p4actions.reconcile(paths)
    if not needRepo() then
        return
    end
    paths = paths or {}
    if run("p4 reconcile " .. (#paths > 0 and pathList(paths) or "..."), gitgud.p4Reconcile, paths) then
        log.info("Offline work reconciled into the default changelist.")
    end
end

--- Lock or unlock open files.
function p4actions.lock(paths, locking)
    paths = paths or selection.files()
    if #paths == 0 then
        return
    end
    run((locking and "p4 lock " or "p4 unlock ") .. pathList(paths), gitgud.p4Lock, paths, locking)
end

-- ---- submit ------------------------------------------------------------------------------

function p4actions.submit(id)
    if not needRepo() then
        return
    end
    if id == nil then
        local item = selection.primary()
        id = item and item.change or 0
    end
    local cl = changelists.get(id)
    if not cl or #cl.files == 0 then
        dialog.alert("Submit", "There are no open files to submit in " .. clName(id) .. ".")
        return
    end
    local rows = {}
    for _, file in ipairs(cl.files) do
        rows[#rows + 1] = { path = file.path, code = file.code, checked = true, action = file.action }
    end

    changedialog.show({
        title = "Submit " .. (id == 0 and "Default Changelist" or ("Changelist " .. id)),
        info = workspaceInfo(),
        description = cl.description,
        files = rows,
        filesLabel = "Files to submit (unchecked files move to the default changelist):",
        options = {
            { label = "Check out submitted files after submit", value = settings.get("depot.reopenAfterSubmit", false) },
        },
        ok = "Submit",
        onOk = function(v)
            if text.trim(v.description) == "" then
                return false, "Enter a description."
            end
            if #v.files == 0 then
                return false, "Check at least one file."
            end
            local submitted, err = run("p4 submit -c " .. changeArg(id), gitgud.p4Submit, changeArg(id),
                v.description, v.files)
            if not submitted then
                return false, err
            end
            settings.set("depot.reopenAfterSubmit", v.options[1])
            if v.options[1] then
                run("p4 edit " .. pathList(v.files), gitgud.p4Edit, v.files, "default")
            end
            log.info("Change " .. submitted .. " submitted.")
            status.ok("Submitted change " .. submitted .. ".")
            return true
        end,
    })
end

-- ---- shelving -------------------------------------------------------------------------------

function p4actions.shelve(id)
    if not needRepo() then
        return
    end
    if id == nil then
        local item = selection.primary()
        id = item and item.change or 0
    end
    local cl = changelists.get(id)
    if not cl or #cl.files == 0 then
        dialog.alert("Shelve", "There are no open files to shelve in " .. clName(id) .. ".")
        return
    end
    local rows = {}
    for _, file in ipairs(cl.files) do
        rows[#rows + 1] = { path = file.path, code = file.code, checked = true, action = file.action }
    end

    changedialog.show({
        title = "Shelve " .. (id == 0 and "Default Changelist" or ("Changelist " .. id)),
        info = workspaceInfo(),
        description = cl.description,
        files = rows,
        filesLabel = "Files to shelve:",
        options = {
            { label = "Revert checked out files after they are shelved", value = false },
        },
        ok = "Shelve",
        onOk = function(v)
            if text.trim(v.description) == "" then
                return false, "Enter a description."
            end
            if #v.files == 0 then
                return false, "Check at least one file."
            end
            -- The default changelist can't hold a shelf: its files move to
            -- a new numbered changelist first.
            local target = id
            if target == 0 then
                target = changelists.create(v.description, v.files)
                if target == 0 then
                    return false, "Couldn't create a changelist for the shelf."
                end
            else
                changelists.setDescription(target, v.description)
            end
            local held, err = run("p4 shelve -f -c " .. target .. " " .. pathList(v.files), gitgud.p4Shelve,
                tostring(target), v.files, v.options[1])
            if not held then
                return false, err
            end
            log.info("Change " .. target .. " shelved (" .. text.plural(#v.files, "file") .. ").")
            return true
        end,
    })
end

--- The files of a shelf.
-- @param oid  "@=<change>" (or the change number)
-- @return array of { path, code }
function p4actions.shelvedFiles(oid)
    local change = tostring(oid):match("(%d+)")
    local out = {}
    if not change then
        return out
    end
    local codes = { add = "A", branch = "A", ["move/add"] = "A", delete = "D", ["move/delete"] = "D" }
    for _, f in ipairs(gitgud.p4ShelvedFiles(change) or {}) do
        out[#out + 1] = { path = f.path ~= "" and f.path or f.depotFile, code = codes[f.action] or "M" }
    end

    return out
end

function p4actions.unshelve(shelf)
    if not needRepo() then
        return
    end
    local change = tostring(shelf.oid or shelf.branch):match("(%d+)")
    if not change then
        return
    end
    local rows = {}
    for _, file in ipairs(p4actions.shelvedFiles(change)) do
        rows[#rows + 1] = { path = file.path, code = file.code, checked = true }
    end
    if #rows == 0 then
        dialog.alert("Unshelve", "Change " .. change .. " has no shelved files.")
        return
    end
    local mine = shelf.change ~= nil

    changedialog.show({
        title = "Unshelve Changelist " .. change,
        info = "Shelved in change " .. change .. (shelf.author and ("   by " .. shelf.author) or ""),
        files = rows,
        filesLabel = "Shelved files to unshelve:",
        options = {
            { label = mine and ("Unshelve into changelist " .. change) or "Unshelve into the default changelist", value = true },
            { label = "Delete the shelved files after unshelving", value = false },
        },
        ok = "Unshelve",
        onOk = function(v)
            if #v.files == 0 then
                return false, "Check at least one file."
            end
            local target = (mine and v.options[1]) and change or "default"
            local result, err = run("p4 unshelve -s " .. change .. " -c " .. target, gitgud.p4Unshelve, change,
                target, v.files)
            if not result then
                return false, err
            end
            log.info("Unshelved " .. text.plural(#result.applied + #result.conflicted, "file") .. ".")
            if #result.conflicted > 0 then
                log.warn("Resolve " .. table.concat(result.conflicted, ", ")
                    .. ": you and the shelf changed the same lines (Actions > Resolve).")
            end
            if v.options[2] and mine then
                run("p4 shelve -d -c " .. change, gitgud.p4DeleteShelf, change, {})
            end
            return true
        end,
    })
end

function p4actions.deleteShelf(shelf, quiet)
    local change = tostring(shelf.oid or shelf.branch):match("(%d+)")
    if not change then
        return
    end
    local function go()
        if run("p4 shelve -d -c " .. change, gitgud.p4DeleteShelf, change, {}) then
            log.info("Shelved files of change " .. change .. " deleted.")
        end
    end
    if quiet then
        go()
        return
    end
    dialog.confirm("Delete Shelved Files", "Delete the shelved files of change " .. change .. " from the server?",
        "Delete", go, true)
end

--- Other people's shelves (for "All users" in the Pending tab).
-- @return array of { branch, oid, change, summary, author, time, remote }
function p4actions.remoteShelves()
    local mine = {}
    for _, cl in ipairs(changelists.all()) do
        mine[cl.id] = true
    end
    local out = {}
    for _, s in ipairs(gitgud.p4Shelves(true) or {}) do
        local id = tonumber(s.change)
        if id and not mine[id] then
            out[#out + 1] = {
                branch = "change " .. s.change,
                oid = "@=" .. s.change,
                summary = (s.description or ""):match("^[^\n]*") or "",
                author = s.user,
                time = s.time,
                remote = "the server",
                user = (s.user or ""):match("^([^@]+)") or "",
            }
        end
    end

    return out
end

--- Worker events for get latest / get revision.
function p4actions.init()
    gitgud.on("p4Sync.done", function(detail)
        if detail and detail ~= "" then
            log.warn("Left alone because you changed them without checking out (reconcile first):\n" .. detail)
        else
            log.info("Workspace is up to date.")
        end
        changelists.reload()
        app.requestRefresh()
    end)
    gitgud.on("p4Sync.error", function(detail)
        log.error("Get failed: " .. tostring(detail))
        app.requestRefresh()
    end)
end

return p4actions
