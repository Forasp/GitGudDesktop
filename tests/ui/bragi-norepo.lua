--- tests/ui/bragi-norepo.lua: the Bragi interface with no repository open
--: it starts in Bragi, the master conversation, every
-- view comes up without errors, New opens Bragi, and the first-time setup
-- asks for no server and no repository or folder, ending with Talk to
-- Bragi.
--
-- Run it with no repository argument (the scratch runner does for names
-- ending in "norepo"); with one, the script closes it first. Otherwise as
-- bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and LOCALAPPDATA,
-- GITGUD_SCRIPT, GITGUD_SHOTS, GITGUD_LOG, GITGUD_TEST_CLAUDE, a scratch
-- CLAUDE_CONFIG_DIR). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local LOG = os.getenv("GITGUD_LOG")

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local app = require("core.app")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")
local welcome = require("bragi.welcome")

settings.set("bragi.claudeProgram", fake)
local startedWithRepo = repo.state().path ~= ""
if startedWithRepo then
    gitgud.closeRepo()
end

local function shot(name)
    gitgud.screenshot(OUT .. "/norepo-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
--- Type into a setup row's box (replacing what's there).
local function typeInto(card, row, value)
    local edit = welcome.widget(card, row, "InputEdit")
    gitgud.focus(edit)
    gitgud.simulateKey("ctrl+a")
    gitgud.simulateKey("backspace")
    gitgud.simulateText(value)
end
local function textOf(card, row, part)
    return gitgud.getText(welcome.widget(card, row, part)) or ""
end

--- Lua errors logged since the last call.
local seen = 0
local function newErrors()
    local f = LOG and io.open(LOG, "rb")
    if not f then
        return {}
    end
    local lines, errors = 0, {}
    for line in f:read("a"):gmatch("[^\r\n]+") do
        lines = lines + 1
        if lines > seen and (line:find("[lua]", 1, true) or line:find("stack traceback", 1, true)) then
            errors[#errors + 1] = line
        end
    end
    f:close()
    seen = lines
    return errors
end
local function noErrors(label)
    local errors = newErrors()
    check(label, #errors == 0)
    for _, e in ipairs(errors) do
        print("[ui-test] error: " .. e)
    end
end

step(1500, "started without a repository", function()
    check("no repository is open", repo.state().path == "" and not repo.state().open)
    shell.show("agent")
end)

step(600, "Bragi is the default", function()
    check("the Agent view shows Bragi", agent.current().master == true)
    check("its title", gitgud.getText("AgentTitle") == "Bragi")
    check("Bragi is pinned on top", agent.sessionRows()[1] and agent.sessionRows()[1].master == true)
    noErrors("the Agent view came up without errors")
    shot("01-agent")
    shell.show("repo")
end)

step(600, "the Repo view", function()
    noErrors("the Repo view came up without errors")
    shell.show("boards")
end)

step(600, "Boards", function()
    noErrors("Boards came up without errors")
    shell.show("wiki")
end)

step(600, "Wiki", function()
    noErrors("the Wiki came up without errors")
    shell.show("settings")
end)

step(600, "Settings", function()
    local bragiSettings = require("bragi.settings")
    for _, section in ipairs({ "claude", "memory", "git", "import" }) do
        bragiSettings.open(section)
    end
    noErrors("Settings came up without errors")
    shell.show("agent")
end)

step(400, "New with no repository", function()
    agent.newSession()
    check("a plain new conversation", not agent.current().master)
    clickWidget("AgentNewButton")
end)

step(400, "New opens Bragi", function()
    check("the New button goes to Bragi when nothing is open", agent.current().master == true)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("hello")
    gitgud.simulateKey("enter")
end)

step(2000, "Bragi answers", function()
    local items = agent.items()
    local reply = nil
    for i = #items, 1, -1 do
        if items[i].kind == "assistant" then
            reply = items[i]
            break
        end
    end
    check("Bragi's session answered", reply ~= nil and reply.text == "Hello")
    check("in its own folder", agent.loaded() ~= nil and (agent.loaded().cwd or ""):lower():gsub("\\", "/")
        :find("/master$") ~= nil)
    check("the review, quick answers, and memory have nothing to trip on", pcall(function()
        require("bragi.review").files()
        require("bragi.quick").digest()
        require("bragi.memory").files()
    end))
    noErrors("a turn with no repository ran without errors")
end)

-- The first-time setup.
step(300, "setup starts", function()
    welcome.start()
end)

step(1500, "Claude Code step", function()
    check("starts at Claude Code", welcome.step() == "claude")
end)

--- Every title on the step showing (cards 1 to 3, rows 1 to 6).
local function stepTitles()
    local titles = {}
    for card = 1, 3 do
        for row = 1, 6 do
            local t = textOf(card, row, "Title")
            if t ~= "" then
                titles[#titles + 1] = t
            end
        end
    end
    return table.concat(titles, " "):lower()
end

local asked = {}
for _, id in ipairs({ "claude", "look", "import" }) do
    step(600, "the " .. id .. " step", function()
        welcome.go(id)
    end)
    step(600, "what the " .. id .. " step asks", function()
        check(id .. " step", welcome.step() == id)
        asked[#asked + 1] = stepTitles()
    end)
end

step(300, "on to the summary", function()
    local all = table.concat(asked, " ")
    check("no server asked", not all:find("home server", 1, true) and not all:find("address", 1, true)
        and not all:find("password", 1, true))
    check("no repository or folder asked", not all:find("repositor", 1, true) and not all:find("folder", 1, true))
    check("no server step", welcome.go("server") == nil and welcome.step() ~= "server")
    shot("02-steps")
    welcome.go("done")
end)

step(800, "the summary", function()
    check("done step", welcome.step() == "done")
    check("its action is Talk to Bragi", textOf(2, 1, "Title") == "Talk to Bragi"
        and textOf(2, 1, "Action") == "Talk to Bragi")
    shot("03-done")
    agent.newSession()
    clickWidget(welcome.widget(2, 1, "Action"))
end)

step(600, "Talk to Bragi", function()
    check("setup closed", not welcome.showing())
    check("the Agent view shows Bragi", shell.view() == "agent" and agent.current().master == true)
    noErrors("setup ran without errors")
end)

step(300, "done", function()
    print("[ui-test] done")
    gitgud.emit("window.close", "")
end)

harness.run()
