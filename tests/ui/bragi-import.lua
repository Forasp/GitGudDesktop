--- tests/ui/bragi-import.lua: Settings, Import (B6): projects from Claude
-- Code's project list (their sessions, instructions, memory, MCP servers;
-- added to the repository list, one at a time or all), and Claude
-- Desktop's MCP servers (one without keys added to Claude Code, one with
-- keys left for the user). Reads only scratch copies of both configs.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, CLAUDE_CONFIG_DIR set to a scratch folder). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local config = os.getenv("CLAUDE_CONFIG_DIR")
local appData = os.getenv("APPDATA")
if gitgud.currentUi().id ~= "bragi" or not config or not appData or not appData:lower():find("sandbox", 1, true) then
    check("needs GITGUD_UI=bragi, CLAUDE_CONFIG_DIR, and a scratch APPDATA", false)
    gitgud.emit("window.close", "")
    return
end

local bragiSettings = require("bragi.settings")
local import = require("bragi.import")
local repo = require("core.repo")
local repositories = require("views.repositories")

local function shot(name)
    gitgud.screenshot(OUT .. "/import-" .. name .. ".png")
end
local function textOf(card, row, part)
    return gitgud.getText(bragiSettings.widget(card, row, part)) or ""
end
local function disabled(card, row)
    return gitgud.getProperty(bragiSettings.widget(card, row, "Action"), "Disabled") == "true"
end
local function clickName(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function write(path, body)
    os.execute('mkdir "' .. path:gsub("/[^/]*$", ""):gsub("/", "\\") .. '" 2>nul')
    local f = assert(io.open(path, "wb"))
    f:write(body)
    f:close()
end
local function knows(path)
    local k = require("core.shell").pathKey(path)
    for _, p in ipairs(repositories.known()) do
        if require("core.shell").pathKey(p) == k then
            return true
        end
    end
    return false
end

local here, other, gone, other2
local spawned = nil
local realSpawn = gitgud.spawn

step(1500, "configs on the machine", function()
    here = repo.state().path:gsub("\\", "/")
    local base = here:gsub("/[^/]*$", "")
    other = base .. "/another"
    other2 = base .. "/third"
    gone = base .. "/gone-project"
    os.execute('mkdir "' .. (other .. "/.git"):gsub("/", "\\") .. '" 2>nul')
    os.execute('mkdir "' .. (other2 .. "/.git"):gsub("/", "\\") .. '" 2>nul')
    write(other .. "/CLAUDE.md", "# Another\n")
    write(config .. "/.claude.json", gitgud.jsonEncode({
        projects = {
            [here] = { mcpServers = {} },
            [other] = { mcpServers = { docs = { command = "node", args = { "docs.js" } } } },
            [other2] = {},
            [gone] = {},
        },
        mcpServers = { already = { command = "x" } },
    }))
    write(appData .. "/Claude/claude_desktop_config.json", gitgud.jsonEncode({
        mcpServers = {
            files = { command = "npx", args = { "files-server", "C:/work" } },
            keyed = { command = "tracker", env = { TOKEN = "not-a-real-token" } },
            already = { command = "x" },
        },
    }))
    bragiSettings.open("import")
end)

step(500, "the preview", function()
    local scan = import.scan()
    check("four projects", #scan.projects == 4)
    check("Add all offered for the two new ones", textOf(1, 1, "Title") == "Add all 2 projects")
    local function row(name)
        for i = 2, 5 do
            if textOf(1, i, "Title") == name then
                return i
            end
        end
    end
    local a, g, h = row("another"), row("gone-project"), row("repo")
    check("a project with its instructions and MCP servers", a and textOf(1, a, "Sub"):find("1 instruction file", 1, true) ~= nil
        and textOf(1, a, "Sub"):find("MCP: docs", 1, true) ~= nil)
    check("a gone folder can't be added", g and textOf(1, g, "Action") == "Missing" and disabled(1, g))
    check("the open repository is already in", h and textOf(1, h, "Action") == "Added")
    shot("01-preview")
    if a then
        clickName(bragiSettings.widget(1, a, "Action"))
    end
end)

step(400, "added one", function()
    check("it's in the repository list", knows(other))
    check("the third isn't yet", not knows(other2))
    check("Add all is gone with one left", textOf(1, 1, "Title") ~= "Add all 1 projects")
end)

step(200, "Claude Desktop's servers", function()
    local function row(name)
        for i = 1, 3 do
            if textOf(2, i, "Title") == name then
                return i
            end
        end
    end
    local f, k, al = row("files"), row("keyed"), row("already")
    check("one Claude Code has", al and textOf(2, al, "Action") == "Added" and disabled(2, al))
    check("one with keys is left for the user", k and textOf(2, k, "Action") == "Has keys" and disabled(2, k))
    check("one without keys can be added", f and textOf(2, f, "Action") == "Add" and not disabled(2, f))
    gitgud.spawn = function(cmd)
        spawned = cmd
        return true
    end
    if f then
        clickName(bragiSettings.widget(2, f, "Action"))
    end
end)

step(400, "adding a server", function()
    gitgud.spawn = realSpawn
    check("claude mcp add-json, user scope", spawned ~= nil
        and spawned:find("mcp add-json --scope user \"files\"", 1, true) ~= nil)
    check("its settings go as JSON", spawned ~= nil and spawned:find('\\"command\\":\\"npx\\"', 1, true) ~= nil)
    local ok, err = import.addServer("keyed")
    check("keys are never copied", ok == nil and (err or ""):find("keys", 1, true) ~= nil)
end)

step(200, "add all", function()
    import.addAllProjects()
    check("the rest are in", knows(other2) and not knows(gone))
end)

step(3000, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
