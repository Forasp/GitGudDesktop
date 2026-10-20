--- bragi/projects.lua: the projects Bragi knows, for the Agent view's
-- grouped conversations list (bragi/sessionlist.lua) and the master
-- conversation's tools (bragi/master.lua).
--
-- A project is a working folder. They come from:
--   conversations   Claude Code's saved conversations, every project
--                   folder (gitgud.agentProjects); a folder whose
--                   transcripts don't name it is matched to a known path
--                   by Claude Code's folder name for it
--   recent          the repository list (views/repositories.lua)
--   claudeCode      Claude Code's own project list (.claude.json)
--
-- The projects folder is bragi.projectsFolder, by default "Projects" in
-- the home folder, made when something is first cloned there.
-- The master conversation's own folder (projects.masterDir)
-- is never a project, nor is the folder of conversations of no project
-- (projects.loneDir), listed as "Uncategorized" (it was
-- "No project", whose conversations list there too).
--
-- Public API: projects.key(path), projects.name(path), projects.masterDir(), projects.loneDir(),
-- projects.isLone(path), projects.setTitle(id, title), projects.titleOf(id),
-- projects.isMaster(path), projects.projectsFolder(), projects.conversations(force),
-- projects.find(nameOrPath), projects.locals(), projects.clone(repo, onDone),
-- projects.isRepo(path)

local settings = require("core.settings")
local text = require("core.text")

local projects = { name = "bragi.projects" }

local PER_PROJECT = 30    -- conversations read per project
local LONE_NAME = "Uncategorized" -- the folder of conversations of no project, and its group
local OLD_LONE_NAME = "No project" -- its name before 2026-10-18
local MAX_PROJECTS = 60   -- projects read

local cached = nil        -- the last conversations listing
local TITLES_FILE = "bragi/titles.json" -- conversation id -> the title the app gave it
local titles = nil        -- TITLES_FILE, read on first use

local function loadTitles()
    if not titles then
        local saved = gitgud.jsonDecode(gitgud.configRead(TITLES_FILE) or "")
        titles = type(saved) == "table" and saved or {}
    end
    return titles
end

--- The title the app gave a conversation (a fork's), or nil.
function projects.titleOf(id)
    local t = id and loadTitles()[id]
    return type(t) == "string" and t or nil
end

--- Give a saved conversation a title of the app's: the list shows it
-- instead of the one its transcript has.
function projects.setTitle(id, title)
    if not id or id == "" then
        return
    end
    loadTitles()[id] = title
    local json = gitgud.jsonEncode(titles)
    if json then
        gitgud.configWrite(TITLES_FILE, json)
    end
    if cached then
        for _, p in ipairs(cached) do
            for _, s in ipairs(p.sessions) do
                if s.id == id then
                    s.title = title
                end
            end
        end
    end
end

--- A path as a comparison key ("" for none).
function projects.key(path)
    if not path or path == "" then
        return ""
    end
    return require("core.shell").pathKey(path)
end

--- A project's name: its folder's.
function projects.name(path)
    if projects.isLone(path) then
        return LONE_NAME
    end
    return text.basename((tostring(path or ""):gsub("[/\\]+$", "")))
end

--- Claude Code's folder name for a working folder, trailing dashes left
-- out (a path with a trailing slash names the same folder).
local function folderName(path)
    return (tostring(path or ""):gsub("[/\\]+$", ""):gsub("[^%w]", "-"))
end

--- The master conversation's folder (made when it first starts).
function projects.masterDir()
    return ((gitgud.configPath() .. "/bragi/master"):gsub("\\", "/"))
end

function projects.isMaster(path)
    return projects.key(path) == projects.key(projects.masterDir())
end

--- The folder of conversations that belong to no project (a fork from the
-- master conversation about none, bragi/rewind.lua): not
-- the master's, and listed as its own group, but never a project to work in.
function projects.loneDir()
    return ((gitgud.configPath() .. "/bragi/" .. LONE_NAME):gsub("\\", "/"))
end

--- Whether a folder is the one of conversations of no project (or its
-- old one).
function projects.isLone(path)
    local key = projects.key(path)
    return key ~= "" and (key == projects.key(projects.loneDir())
        or key == projects.key((gitgud.configPath() .. "/bragi/" .. OLD_LONE_NAME):gsub("\\", "/")))
end

--- Where bragi_clone clones repositories.
function projects.projectsFolder()
    local folder = text.trim(settings.get("bragi.projectsFolder", ""))
    if folder == "" then
        folder = gitgud.homeDir():gsub("[/\\]+$", "") .. "/Projects"
    end
    return folder
end

--- Whether a folder is a Git repository or a Perforce workspace the app
-- can open.
function projects.isRepo(path)
    if not path or path == "" then
        return false
    end
    local root = tostring(path):gsub("[/\\]+$", "")
    return gitgud.pathExists(root .. "/.git") or gitgud.pathExists(root .. "/.p4config")
        or gitgud.pathExists(root .. "/P4CONFIG")
end

--- Read Claude Code's project list (.claude.json): its folders.
local function claudeCodeFolders()
    local dir = os.getenv("CLAUDE_CONFIG_DIR")
    local file = (dir and dir ~= "") and (dir .. "/.claude.json")
        or ((os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.claude.json")
    local f = io.open(file, "rb")
    if not f then
        return {}
    end
    local parsed = gitgud.jsonDecode(f:read("a"))
    f:close()
    local list = {}
    for path in pairs(type(parsed) == "table" and type(parsed.projects) == "table" and parsed.projects or {}) do
        list[#list + 1] = path
    end
    table.sort(list)
    return list
end

--- Paths the app knows, for naming a project folder its transcripts don't.
local function knownPaths()
    local list = {}
    local open = require("core.repo").state().path
    if open ~= "" then
        list[#list + 1] = open
    end
    for _, path in ipairs(require("views.repositories").known()) do
        list[#list + 1] = path
    end
    for _, path in ipairs(claudeCodeFolders()) do
        list[#list + 1] = path
    end
    return list
end

--- Claude Code's conversations by project, the most recently active first
-- (the master's left out): { {key, cwd, name, folder, updated, sessions =
-- { {id, title, updated, active, cwd} } } } (gitgud.agentProjects'). Kept
-- until read again with `force`.
function projects.conversations(force)
    if cached and not force then
        return cached
    end
    local byFolder = nil
    local list = {}
    local lone = nil
    local masterFolder = folderName(projects.masterDir())
    for _, p in ipairs(gitgud.agentProjects and gitgud.agentProjects(PER_PROJECT, MAX_PROJECTS) or {}) do
        local cwd = p.cwd or ""
        local folder = (p.folder or ""):gsub("%-+$", "")
        if cwd == "" then
            if not byFolder then
                byFolder = {}
                for _, path in ipairs(knownPaths()) do
                    byFolder[folderName(path):gsub("%-+$", "")] = path
                end
            end
            cwd = byFolder[folder] or ""
        end
        if folder ~= masterFolder:gsub("%-+$", "") and not projects.isMaster(cwd) then
            for _, s in ipairs(p.sessions or {}) do
                if (s.cwd or "") == "" then
                    s.cwd = cwd
                end
                s.title = projects.titleOf(s.id) or s.title
            end
            local entry = {
                key = cwd ~= "" and projects.key(cwd) or ("folder:" .. folder),
                cwd = cwd,
                name = cwd ~= "" and projects.name(cwd) or folder,
                folder = p.folder,
                updated = p.updated or 0,
                sessions = p.sessions or {},
            }
            if projects.isLone(cwd) then
                -- The old folder's conversations (each keeps its own cwd)
                -- list in the one group.
                entry.key, entry.cwd = projects.key(projects.loneDir()), projects.loneDir()
                if lone then
                    for _, s in ipairs(entry.sessions) do
                        lone.sessions[#lone.sessions + 1] = s
                    end
                    table.sort(lone.sessions, function(a, b)
                        return (a.active or a.updated or 0) > (b.active or b.updated or 0)
                    end)
                    lone.updated = math.max(lone.updated, entry.updated)
                    entry = nil
                else
                    lone = entry
                end
            end
            list[#list + 1] = entry
        end
    end
    cached = list
    return list
end

--- Every project on this machine: { {key, name, path, sources = {...},
-- conversations, updated, repo} }, the most recently active first, then
-- by name. Sources: "conversations", "recent", "claudeCode".
function projects.locals()
    local byKey, list = {}, {}
    local function add(path, source, extra)
        if not path or path == "" or projects.isMaster(path) or projects.isLone(path) then
            return nil
        end
        local key = projects.key(path)
        local p = byKey[key]
        if not p then
            p = { key = key, name = projects.name(path), path = path, sources = {}, conversations = 0,
                updated = 0 }
            byKey[key] = p
            list[#list + 1] = p
        end
        if not p.sources[source] then
            p.sources[source] = true
        end
        for k, v in pairs(extra or {}) do
            p[k] = v
        end
        return p
    end
    for _, c in ipairs(projects.conversations()) do
        if c.cwd ~= "" then
            add(c.cwd, "conversations", { conversations = #c.sessions, updated = c.updated })
        end
    end
    for _, path in ipairs(require("views.repositories").known()) do
        add(path, "recent")
    end
    for _, path in ipairs(claudeCodeFolders()) do
        add(path, "claudeCode")
    end
    for _, p in ipairs(list) do
        p.exists = gitgud.pathExists(p.path)
        p.repo = projects.isRepo(p.path)
    end
    table.sort(list, function(a, b)
        if a.updated ~= b.updated then
            return a.updated > b.updated
        end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

--- A local project by name (any case) or path, or nil.
function projects.find(what)
    what = text.trim(tostring(what or ""))
    if what == "" then
        return nil
    end
    local key = projects.key(what)
    local lower = what:lower()
    for _, p in ipairs(projects.locals()) do
        if p.key == key then
            return p
        end
    end
    local list = projects.locals()
    for _, p in ipairs(list) do
        if p.name:lower() == lower then
            return p
        end
    end
    -- As said aloud: "star trader" for "Star-Trader".
    local squashed = lower:gsub("[^%w]", "")
    for _, p in ipairs(list) do
        if squashed ~= "" and p.name:lower():gsub("[^%w]", "") == squashed then
            return p
        end
    end
    return nil
end

local cloning = {}        -- destination key -> callbacks waiting

--- Clone into the projects folder (made on demand) and add it to the
-- repository list. onDone(path) when it's there, or onDone(nil, err).
-- @param repo  { url, name? } (name: the folder's, else from the URL)
function projects.clone(repo, onDone)
    local url = repo.url or ""
    if url == "" then
        onDone(nil, "No address to clone from.")
        return
    end
    local name = repo.name or projects.name((url:gsub("%.git$", "")))
    local folder = projects.projectsFolder()
    local path = folder .. "/" .. name
    if projects.isRepo(path) then
        require("views.repositories").remember(path)
        onDone(path)
        return
    end
    if gitgud.pathExists(path) then
        onDone(nil, path .. " already exists and isn't a repository.")
        return
    end
    local ok, err = gitgud.makeDir(folder)
    if not ok then
        onDone(nil, err)
        return
    end
    if text.trim(settings.get("bragi.projectsFolder", "")) == "" then
        settings.set("bragi.projectsFolder", folder) -- where it went, to see in Settings
    end
    local key = projects.key(path)
    if cloning[key] then
        table.insert(cloning[key], onDone)
        return
    end
    cloning[key] = { onDone }
    -- Cloned for later: the open repository stays as it is (opening it is
    -- bragi_open_project's, when asked).
    require("views.sync").dontOpen[key] = true
    gitgud.clone(url, path)
end

--- A clone finished (or failed) somewhere: tell whoever waits for it.
local function cloneFinished(path, err)
    local key = projects.key(path or "")
    local waiting = cloning[key]
    if not waiting and err then
        -- clone.error doesn't say which: everything waiting failed.
        for k, list in pairs(cloning) do
            cloning[k] = nil
            for _, fn in ipairs(list) do
                fn(nil, err)
            end
        end
        return
    end
    cloning[key] = nil
    if not err then
        require("views.repositories").remember(path)
        cached = nil
    end
    for _, fn in ipairs(waiting or {}) do
        fn(not err and path or nil, err)
    end
end

function projects.init()
    gitgud.on("clone.done", function(path)
        cloneFinished(path)
    end)
    gitgud.on("clone.error", function(detail)
        cloneFinished(nil, tostring(detail or "The clone failed."))
    end)
end

return projects
