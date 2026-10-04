--- depot/p4changelists.lua: pending changelists on a Perforce server.
--
-- The same interface as depot/changelists.lua, which hands every call here
-- when the open workspace is a Perforce one (gitgud.backend() == "p4").
-- Nothing is kept locally: the default and numbered changelists, their open
-- files, and their shelved files all come from the server
-- (gitgud.p4Changes), and every change is a p4 command (reopen, edit, add,
-- change -d). As with any Perforce client, a file you edit without opening
-- it isn't in a changelist until you check it out or reconcile.

local app = require("core.app")
local log = require("depot.log")

local p4changelists = {}

local cache = nil -- gitgud.p4Changes() rows, nil until asked

--- p4 action -> the status letter the views draw.
local CODES = {
    edit = "M", integrate = "M",
    add = "A", branch = "A", ["move/add"] = "A", import = "A",
    delete = "D", ["move/delete"] = "D", purge = "D", archive = "D",
}

--- "default" or the number, for p4.
local function changeArg(id)
    return (id == nil or id == 0) and "default" or tostring(id)
end

--- Run a gitgud.p4* call; log a failure. Returns its first result.
local function call(fn, ...)
    local result, err = fn(...)
    if result == nil then
        log.error(tostring(err))
    end
    return result
end

--- Load (once per refresh) and shape the server's changelists.
local function load()
    if cache then
        return cache
    end
    cache = {}
    local rows, err = gitgud.p4Changes()
    if not rows then
        log.error("Couldn't read the pending changelists: " .. tostring(err))
        return cache
    end
    for _, row in ipairs(rows) do
        local id = row.change == "default" and 0 or tonumber(row.change)
        local files = {}
        for _, f in ipairs(row.files or {}) do
            files[#files + 1] = {
                path = f.path,
                code = f.unresolved and "U" or (CODES[f.action] or "M"),
                action = f.action .. (f.locked and " (locked)" or ""),
                opened = false,
                depotFile = f.depotFile,
            }
        end
        table.sort(files, function(a, b)
            return a.path < b.path
        end)
        local shelf = nil
        if #(row.shelved or {}) > 0 then
            local paths = {}
            for _, f in ipairs(row.shelved) do
                paths[#paths + 1] = f.path
            end
            shelf = {
                branch = "change " .. row.change,
                oid = "@=" .. row.change,
                files = paths,
                pushedTo = "the server",
                change = id,
                p4 = true,
            }
        end
        cache[#cache + 1] = {
            id = id,
            description = row.description or "",
            time = row.time or 0,
            user = row.user,
            shelf = shelf,
            files = files,
        }
    end

    return cache
end

--- Forget the cached rows and tell the views.
local function changed()
    cache = nil
    app.publish("changelists.changed")
end

function p4changelists.of(path)
    for _, cl in ipairs(load()) do
        for _, file in ipairs(cl.files) do
            if file.path == path then
                return cl.id
            end
        end
    end

    return 0
end

function p4changelists.isMarkedForAdd(path)
    for _, cl in ipairs(load()) do
        for _, file in ipairs(cl.files) do
            if file.path == path then
                return file.code == "A"
            end
        end
    end

    return false
end

function p4changelists.all()
    return load()
end

function p4changelists.get(id)
    for _, cl in ipairs(load()) do
        if cl.id == id then
            return cl
        end
    end

    return nil
end

function p4changelists.create(description, paths)
    log.command("p4 change   (new: " .. (description:match("^[^\n]*") or "") .. ")")
    local change = call(gitgud.p4NewChange, description ~= "" and description or "(no description)", paths or {})
    changed()

    return tonumber(change) or 0
end

function p4changelists.setDescription(id, description)
    if id == 0 then
        return
    end
    log.command("p4 change " .. id)
    call(gitgud.p4SetDescription, tostring(id), description)
    changed()
end

--- Open files go to `id` (reopen); others are opened there (edit/add).
local function openInto(paths, id)
    local opened = {}
    for _, cl in ipairs(load()) do
        for _, file in ipairs(cl.files) do
            opened[file.path] = true
        end
    end
    local reopen, edit, add = {}, {}, {}
    for _, path in ipairs(paths) do
        local status = require("core.repo").file(path)
        if opened[path] then
            reopen[#reopen + 1] = path
        elseif status and status.code == "?" then
            add[#add + 1] = path
        else
            edit[#edit + 1] = path
        end
    end
    if #reopen > 0 then
        log.command("p4 reopen -c " .. changeArg(id) .. " (" .. #reopen .. " files)")
        call(gitgud.p4Reopen, reopen, changeArg(id))
    end
    if #edit > 0 then
        log.command("p4 edit -c " .. changeArg(id) .. " (" .. #edit .. " files)")
        call(gitgud.p4Edit, edit, changeArg(id))
    end
    if #add > 0 then
        log.command("p4 add -c " .. changeArg(id) .. " (" .. #add .. " files)")
        call(gitgud.p4Add, add, changeArg(id))
    end
end

function p4changelists.moveQuiet(path, id)
    openInto({ path }, id)
    cache = nil
end

function p4changelists.move(paths, id)
    openInto(paths, id)
    changed()
end

function p4changelists.open(paths, id)
    openInto(paths, id or 0)
    changed()
end

--- Files leave changelists on the server (revert, submit); just reload.
function p4changelists.release()
    changed()
end

function p4changelists.markForAdd(paths, id)
    log.command("p4 add -c " .. changeArg(id) .. " (" .. #paths .. " files)")
    call(gitgud.p4Add, paths, changeArg(id))
    changed()
end

function p4changelists.delete(id)
    if id == 0 then
        return
    end
    log.command("p4 change -d " .. id)
    call(gitgud.p4DeleteChange, tostring(id))
    changed()
end

--- Shelves live on the server; nothing to record.
function p4changelists.setShelf()
    changed()
end

--- Called before every pending-view refresh: read the server again.
function p4changelists.prune()
    cache = nil
end

function p4changelists.reload()
    changed()
end

return p4changelists
