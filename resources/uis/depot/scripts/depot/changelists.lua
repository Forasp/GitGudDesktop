--- depot/changelists.lua — pending changelists, kept locally.
--
-- Git has no changelists, so they live only on this machine (one file per
-- repository in the per-user config folder, never in the repository):
--
--   * the default changelist (id 0) holds every changed file that isn't in
--     a numbered one — Git needs no "check out", so an edited file is simply
--     open for edit
--   * numbered changelists (1, 2, …) group files with a description;
--     "Check Out" also opens an unchanged file in one
--   * untracked files join only when marked for add (or when the "show
--     untracked files" preference is on)
--   * a shelved changelist remembers its shelf: a branch holding a commit of
--     the shelved files (see depot/actions.lua), shared by pushing it
--
-- Submitting commits exactly a changelist's files (depot/actions.lua).

local app = require("core.app")
local repo = require("core.repo")
local settings = require("core.settings")

local changelists = {}

local data = nil        -- { next, lists = { [id] = cl }, added = { path = true } }
local loadedFor = nil   -- repository path the data belongs to

--- A config-file name for this repository.
-- @param path  repository root
-- @return "depot-changes-<name>-<hash>"
local function fileName(path)
    local key = path:gsub("\\", "/"):lower()
    local hash = 5381
    for i = 1, #key do
        hash = (hash * 33 + key:byte(i)) % 4294967296
    end
    local base = key:match("([^/]+)/*$") or "repo"
    base = base:gsub("[^%w%-_]", "_")

    return string.format("depot-changes-%s-%08x", base, hash)
end

--- Escape one field for the file format (tab-separated lines).
local function escape(s)
    return (s:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", ""))
end

local function unescape(s)
    return (s:gsub("\\(.)", function(c)
        if c == "t" then
            return "\t"
        end
        if c == "n" then
            return "\n"
        end
        return c
    end))
end

--- Split a line on tabs.
local function fields(line)
    local out = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        out[#out + 1] = unescape(field)
    end

    return out
end

--- Parse the saved file.
-- Lines: "next\t<n>" | "cl\t<id>\t<time>\t<description>" |
--        "file\t<id>\t<path>" | "add\t<path>" |
--        "shelf\t<id>\t<branch>\t<oid>\t<pushedTo>\t<files joined by \n>"
local function parse(raw)
    local out = { next = 1, lists = {}, added = {} }
    out.lists[0] = { id = 0, description = "", files = {}, time = 0 }

    for line in (raw or ""):gmatch("[^\r\n]+") do
        local f = fields(line)
        local kind = f[1]
        if kind == "next" then
            out.next = tonumber(f[2]) or out.next
        elseif kind == "cl" then
            local id = tonumber(f[2])
            if id then
                out.lists[id] = { id = id, time = tonumber(f[3]) or 0, description = f[4] or "", files = {} }
            end
        elseif kind == "file" then
            local cl = out.lists[tonumber(f[2]) or -1]
            if cl and f[3] and f[3] ~= "" then
                cl.files[f[3]] = true
            end
        elseif kind == "add" then
            out.added[f[2]] = true
        elseif kind == "shelf" then
            local cl = out.lists[tonumber(f[2]) or -1]
            if cl then
                local files = {}
                for path in (f[6] or ""):gmatch("[^\n]+") do
                    files[#files + 1] = path
                end
                cl.shelf = { branch = f[3], oid = f[4], pushedTo = f[5] or "", files = files }
            end
        end
    end

    return out
end

--- Serialise the model.
local function serialise()
    local lines = { "next\t" .. data.next }
    local ids = {}
    for id in pairs(data.lists) do
        ids[#ids + 1] = id
    end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local cl = data.lists[id]
        if id ~= 0 then
            lines[#lines + 1] = "cl\t" .. id .. "\t" .. (cl.time or 0) .. "\t" .. escape(cl.description or "")
        end
        local paths = {}
        for path in pairs(cl.files) do
            paths[#paths + 1] = path
        end
        table.sort(paths)
        for _, path in ipairs(paths) do
            lines[#lines + 1] = "file\t" .. id .. "\t" .. escape(path)
        end
        if cl.shelf then
            lines[#lines + 1] = "shelf\t" .. id .. "\t" .. escape(cl.shelf.branch) .. "\t"
                .. escape(cl.shelf.oid or "") .. "\t" .. escape(cl.shelf.pushedTo or "") .. "\t"
                .. escape(table.concat(cl.shelf.files or {}, "\n"))
        end
    end

    local added = {}
    for path in pairs(data.added) do
        added[#added + 1] = path
    end
    table.sort(added)
    for _, path in ipairs(added) do
        lines[#lines + 1] = "add\t" .. escape(path)
    end

    return table.concat(lines, "\n") .. "\n"
end

--- Load the current repository's changelists (once per repository).
local function ensure()
    local path = repo.state().path
    if data and loadedFor == path then
        return
    end

    loadedFor = path
    if path == "" then
        data = parse("")
        return
    end
    data = parse(gitgud.configRead(fileName(path)))
end

--- Save, and tell the views.
local function save()
    if loadedFor and loadedFor ~= "" then
        gitgud.configWrite(fileName(loadedFor), serialise())
    end
    app.publish("changelists.changed")
end

--- The status row of a changed file, or nil.
local function statusOf(path)
    return repo.file(path)
end

--- Which numbered changelist holds a file (0 = default).
-- @param path  repository-relative path
-- @return id
function changelists.of(path)
    ensure()
    for id, cl in pairs(data.lists) do
        if id ~= 0 and cl.files[path] then
            return id
        end
    end

    return 0
end

--- Is an untracked file marked for add?
-- @param path  file
-- @return boolean
function changelists.isMarkedForAdd(path)
    ensure()
    return data.added[path] == true
end

--- Would a changed file show in the pending lists?
-- @param file  status row
-- @return boolean
local function pendingVisible(file)
    if file.code ~= "?" then
        return true
    end

    return data.added[file.path] == true or settings.get("depot.untrackedInPending", false)
end

--- Every changelist in display order: default, then by number.
-- @return array of { id, description, time, shelf, files = { {path, code, opened} } }
function changelists.all()
    ensure()
    local out = {}
    local ids = {}
    for id in pairs(data.lists) do
        ids[#ids + 1] = id
    end
    table.sort(ids)

    local assigned = {}
    for _, id in ipairs(ids) do
        if id ~= 0 then
            for path in pairs(data.lists[id].files) do
                assigned[path] = id
            end
        end
    end

    for _, id in ipairs(ids) do
        local cl = data.lists[id]
        local files = {}
        if id == 0 then
            for _, file in ipairs(repo.state().files) do
                if not assigned[file.path] and pendingVisible(file) then
                    files[#files + 1] = { path = file.path, code = file.code, staged = file.staged }
                end
            end
            for path in pairs(cl.files) do
                if not statusOf(path) and not assigned[path] then
                    files[#files + 1] = { path = path, code = nil, opened = true }
                end
            end
        else
            for path in pairs(cl.files) do
                local file = statusOf(path)
                files[#files + 1] = { path = path, code = file and file.code or nil, opened = file == nil }
            end
        end
        table.sort(files, function(a, b)
            return a.path < b.path
        end)
        out[#out + 1] = {
            id = id,
            description = cl.description or "",
            time = cl.time or 0,
            shelf = cl.shelf,
            files = files,
        }
    end

    return out
end

--- One changelist (see all()).
-- @param id  changelist id
-- @return the changelist or nil
function changelists.get(id)
    for _, cl in ipairs(changelists.all()) do
        if cl.id == id then
            return cl
        end
    end

    return nil
end

--- Create a numbered changelist.
-- @param description  its description
-- @param paths        files to move into it (optional)
-- @return the new id
function changelists.create(description, paths)
    ensure()
    local id = data.next
    data.next = id + 1
    data.lists[id] = { id = id, description = description or "", files = {}, time = os.time() }
    for _, path in ipairs(paths or {}) do
        changelists.moveQuiet(path, id)
    end
    save()

    return id
end

--- Change a changelist's description.
-- @param id           changelist id (not 0)
-- @param description  new text
function changelists.setDescription(id, description)
    ensure()
    if data.lists[id] then
        data.lists[id].description = description
        save()
    end
end

--- Move one file without saving (helper).
function changelists.moveQuiet(path, id)
    ensure()
    for otherId, cl in pairs(data.lists) do
        if otherId ~= id then
            cl.files[path] = nil
        end
    end
    if data.lists[id] then
        -- The default list only records files that aren't changed (opened
        -- with Check Out); changed files are in it implicitly.
        if id ~= 0 or not statusOf(path) then
            data.lists[id].files[path] = true
        end
    end
end

--- Move files to a changelist (0 = default).
-- @param paths  files
-- @param id     target changelist
function changelists.move(paths, id)
    ensure()
    for _, path in ipairs(paths) do
        changelists.moveQuiet(path, id)
    end
    save()
end

--- Open files for edit ("Check Out"): they join a changelist even when
-- unchanged.
-- @param paths  files
-- @param id     changelist (default 0)
function changelists.open(paths, id)
    ensure()
    id = id or 0
    for _, path in ipairs(paths) do
        changelists.moveQuiet(path, id)
        if id == 0 then
            data.lists[0].files[path] = true
        end
    end
    save()
end

--- Take files out of every changelist (after revert / submit).
-- @param paths  files
function changelists.release(paths)
    ensure()
    for _, path in ipairs(paths) do
        for _, cl in pairs(data.lists) do
            cl.files[path] = nil
        end
        data.added[path] = nil
    end
    save()
end

--- Mark untracked files for add (and put them in a changelist).
-- @param paths  files
-- @param id     changelist (default 0)
function changelists.markForAdd(paths, id)
    ensure()
    for _, path in ipairs(paths) do
        data.added[path] = true
        if id and id ~= 0 then
            changelists.moveQuiet(path, id)
        end
    end
    save()
end

--- Delete an empty changelist (its files go back to the default one).
-- @param id  changelist id (not 0)
function changelists.delete(id)
    ensure()
    if id ~= 0 then
        data.lists[id] = nil
        save()
    end
end

--- Record (or clear, with nil) a changelist's shelf.
-- @param id     changelist id
-- @param shelf  { branch, oid, pushedTo, files } or nil
function changelists.setShelf(id, shelf)
    ensure()
    if data.lists[id] then
        data.lists[id].shelf = shelf
        save()
    end
end

--- Tidy up after a refresh: marks for add on files that are no longer
-- untracked (added, committed, deleted) are dropped.
function changelists.prune()
    ensure()
    local changed = false
    for path in pairs(data.added) do
        local file = statusOf(path)
        if not file or file.code ~= "?" then
            data.added[path] = nil
            changed = true
        end
    end
    if changed then
        save()
    end
end

--- Forget cached data (a different repository opened).
function changelists.reload()
    data = nil
    loadedFor = nil
    ensure()
    app.publish("changelists.changed")
end

return changelists
