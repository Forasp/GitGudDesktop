--- bragi/import.lua: bring in what's already set up for Claude Code and
-- Claude Desktop. Settings shows it as the Import section,
-- the palette has "Import from Claude Code", and the Agent view mentions
-- it once when the app knows no repositories yet but Claude Code does.
--
-- Read only, nothing changes at the source:
--   - Claude Code's project list (.claude.json: in CLAUDE_CONFIG_DIR when
--     that's set, else the home folder): each project's folder and its
--     MCP servers, plus the user's own MCP servers.
--   - Claude Desktop's config (claude_desktop_config.json in its folder
--     under APPDATA): its MCP servers, which Claude Code doesn't read.
--   - For each project: its CLAUDE.md files and auto memory
--     (gitgud.agentContextFiles) and saved sessions (gitgud.agentSessions).
--
-- Adding a project puts it in the repository list; its instructions,
-- memory, and sessions stay where Claude Code keeps them (one source of
-- truth: Claude Code reads them itself, and the Agent view lists the
-- sessions). A Claude Desktop MCP server is added to Claude Code with
-- `claude mcp add-json --scope user`, but only one without keys: a server
-- with env values or headers may hold secrets, which are never copied as
-- plain text, so the user adds it again with its keys.
--
-- Public API: import.scan(), import.addProject(path), import.addAllProjects(),
-- import.addServer(name), import.cards() (for bragi/settings.lua)

local repo = require("core.repo")
local settings = require("core.settings")
local text = require("core.text")

local import = { name = "bragi.import" }

local scanned = nil         -- the last scan (import.scan)

local function readJson(path)
    local f = path and io.open(path, "rb")
    if not f then
        return nil
    end
    local parsed = gitgud.jsonDecode(f:read("a"))
    f:close()
    return type(parsed) == "table" and parsed or nil
end

local function join(dir, name)
    return tostring(dir):gsub("[/\\]+$", "") .. "/" .. name
end

local function home()
    return os.getenv("USERPROFILE") or os.getenv("HOME") or ""
end

--- Where Claude Code keeps its project list.
local function claudeJsonPath()
    local configured = os.getenv("CLAUDE_CONFIG_DIR")
    if configured and configured ~= "" then
        return join(configured, ".claude.json")
    end
    return join(home(), ".claude.json")
end

--- Where Claude Desktop keeps its config.
local function desktopConfigPath()
    local appData = os.getenv("APPDATA")
    if appData and appData ~= "" then
        return join(appData, "Claude/claude_desktop_config.json")
    end
    return join(home(), "Library/Application Support/Claude/claude_desktop_config.json")
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(type(t) == "table" and t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

--- A server's settings may hold secrets: env values or headers.
local function hasKeys(server)
    return type(server) == "table" and ((type(server.env) == "table" and next(server.env) ~= nil)
        or (type(server.headers) == "table" and next(server.headers) ~= nil))
end

--- Read what's on the machine. Returns the scan:
-- { projects = { {path, name, exists, git, known, instructions, memory,
--   sessions, servers} }, desktopServers = { {name, command, keys, added} },
--   claudeJson, desktopConfig }
function import.scan()
    local claudeJson = readJson(claudeJsonPath()) or {}
    local desktop = readJson(desktopConfigPath()) or {}
    local known = {}
    for _, path in ipairs(require("views.repositories").known()) do
        known[require("core.shell").pathKey(path)] = true
    end

    local inClaudeCode = {}
    for name in pairs(type(claudeJson.mcpServers) == "table" and claudeJson.mcpServers or {}) do
        inClaudeCode[name] = true
    end

    local projects = {}
    for _, path in ipairs(sortedKeys(claudeJson.projects)) do
        local entry = claudeJson.projects[path]
        local p = {
            path = path,
            name = text.basename((path:gsub("[/\\]+$", ""))),
            exists = gitgud.pathExists(path),
            git = gitgud.pathExists(join(path, ".git")),
            known = known[require("core.shell").pathKey(path)] == true,
            instructions = 0,
            memory = 0,
            sessions = 0,
            servers = sortedKeys(type(entry) == "table" and entry.mcpServers),
        }
        for _, name in ipairs(p.servers) do
            inClaudeCode[name] = true
        end
        if p.exists then
            for _, file in ipairs(gitgud.agentContextFiles(path)) do
                if file.kind == "memory" then
                    p.memory = p.memory + 1
                elseif file.kind == "project" or file.kind == "local" or file.kind == "projectRule" then
                    p.instructions = p.instructions + 1
                end
            end
            p.sessions = #gitgud.agentSessions(path)
        end
        projects[#projects + 1] = p
    end

    local servers = {}
    for _, name in ipairs(sortedKeys(desktop.mcpServers)) do
        local s = desktop.mcpServers[name]
        servers[#servers + 1] = {
            name = name,
            config = s,
            command = type(s) == "table" and (s.command or s.url or "") or "",
            keys = hasKeys(s),
            added = inClaudeCode[name] == true,
        }
    end

    scanned = { projects = projects, desktopServers = servers, claudeJson = claudeJsonPath(),
        desktopConfig = desktopConfigPath() }
    return scanned
end

local function rebuild()
    import.scan()
    require("bragi.settings").rebuild("import")
end

--- Put a project in the repository list.
function import.addProject(path)
    require("views.repositories").remember(path)
    rebuild()
end

--- Add every project whose folder exists.
function import.addAllProjects()
    for _, p in ipairs((scanned or import.scan()).projects) do
        if p.exists and not p.known then
            require("views.repositories").remember(p.path)
        end
    end
    rebuild()
end

--- Quote one argument for a Windows command line.
local function quoteArg(s)
    return '"' .. tostring(s):gsub('(\\*)"', '%1%1\\"'):gsub("(\\+)$", "%1%1") .. '"'
end

--- Add a Claude Desktop MCP server (one without keys) to Claude Code.
-- @return true, or nil and why not
function import.addServer(name)
    for _, s in ipairs((scanned or import.scan()).desktopServers) do
        if s.name == name then
            if s.keys then
                return nil, "It has keys: add it again with them (claude mcp add)."
            end
            local program = require("bragi.claude").program()
            local ok, err = gitgud.spawn(program .. " mcp add-json --scope user " .. quoteArg(name) .. " "
                .. quoteArg(gitgud.jsonEncode(s.config)))
            gitgud.after(2500, rebuild)
            return ok ~= false, err
        end
    end
    return nil, "No such server"
end

-- ===================================================================
-- The settings section
-- ===================================================================

local function plural(n, one, many)
    return n .. " " .. (n == 1 and one or many)
end

local function projectRow(p)
    local parts = {}
    if p.sessions > 0 then
        parts[#parts + 1] = plural(p.sessions, "session", "sessions")
    end
    if p.instructions > 0 then
        parts[#parts + 1] = plural(p.instructions, "instruction file", "instruction files")
    end
    if p.memory > 0 then
        parts[#parts + 1] = plural(p.memory, "memory file", "memory files")
    end
    if #p.servers > 0 then
        parts[#parts + 1] = "MCP: " .. table.concat(p.servers, ", ")
    end
    if not p.exists then
        parts[#parts + 1] = "the folder is gone"
    elseif not p.git then
        parts[#parts + 1] = "not a Git repository"
    end
    local where = p.path:gsub("\\", "/")
    if #parts > 0 then
        parts[1] = parts[1]:sub(1, 1):upper() .. parts[1]:sub(2)
    end
    return {
        kind = "action",
        title = p.name ~= "" and p.name or where,
        sub = where .. (#parts > 0 and (". " .. table.concat(parts, ", ") .. ".") or "."),
        button = p.known and "Added" or (p.exists and "Add" or "Missing"),
        enabled = p.exists and not p.known,
        run = function()
            import.addProject(p.path)
        end,
    }
end

local function serverRow(s)
    return {
        kind = "action",
        title = s.name,
        sub = (s.command ~= "" and (s.command .. ". ") or "")
            .. (s.added and "Claude Code has it." or (s.keys and "It has keys: add it again with them (claude mcp add)."
                or "Claude Code doesn't read Claude Desktop's servers; add it to Claude Code.")),
        button = s.added and "Added" or (s.keys and "Has keys" or "Add"),
        enabled = not s.added and not s.keys,
        run = function()
            import.addServer(s.name)
        end,
    }
end

--- The Import section's cards, from a fresh scan.
function import.cards()
    local scan = import.scan()
    local projects = {}
    local addable = 0
    for _, p in ipairs(scan.projects) do
        projects[#projects + 1] = projectRow(p)
        if p.exists and not p.known then
            addable = addable + 1
        end
    end
    if #projects == 0 then
        projects[1] = { kind = "info", title = "No projects found",
            sub = "Claude Code's project list (" .. scan.claudeJson:gsub("\\", "/") .. ") has none." }
    elseif addable > 1 then
        table.insert(projects, 1, { kind = "action", title = "Add all " .. addable .. " projects",
            sub = "Their instructions, memory, and sessions stay where Claude Code keeps them.",
            button = "Add all", primary = true, run = import.addAllProjects })
    end
    local servers = {}
    for _, s in ipairs(scan.desktopServers) do
        servers[#servers + 1] = serverRow(s)
    end
    if #servers == 0 then
        servers[1] = { kind = "info", title = "None found",
            sub = "Claude Desktop's config (" .. scan.desktopConfig:gsub("\\", "/") .. ") has no MCP servers." }
    end
    return {
        { heading = "Projects from Claude Code", rows = projects },
        { heading = "MCP servers from Claude Desktop", rows = servers },
    }
end

function import.init()
    require("ui.commands").register({ label = "Import from Claude Code", keywords = "claude desktop projects mcp",
        action = function()
            require("bragi.settings").open("import")
        end })
    -- First start: offer it once, when Claude Code knows projects and the app none.
    gitgud.after(2500, function()
        -- First-time setup has Import as a step.
        if settings.get("bragi.importOffered", false) or #require("views.repositories").known() > 0
            or require("bragi.welcome").showing() then
            return
        end
        local scan = import.scan()
        if #scan.projects > 0 then
            settings.set("bragi.importOffered", true)
            require("bragi.agent").addMessage("note", "Claude Code knows " .. plural(#scan.projects, "project", "projects")
                .. " on this machine. Settings, Import brings them in.")
        end
    end)
end

function import.refresh()
end

return import
