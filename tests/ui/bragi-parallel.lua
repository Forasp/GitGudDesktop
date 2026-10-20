--- tests/ui/bragi-parallel.lua: parallel sessions (G6): a session mid-turn
-- keeps running when you start another, its events stay in its own tab,
-- the sessions list marks it (running, finished, needs you), it asks for
-- you when it finishes or wants a permission, and picking it shows it
-- again (an idle tab you leave is closed).
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE set to
-- build\release\bin\gitgud_test_claude.exe, and CLAUDE_CONFIG_DIR set to a
-- scratch folder). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

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
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/parallel-" .. name .. ".png")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function lastOf(items, kind)
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
local notices = {}
gitgud.on("window.notify", function(detail)
    notices[#notices + 1] = detail
end)
local attentions = {}
app.subscribe("bragi.attention", function(a)
    attentions[#attentions + 1] = a
end)

local first      -- the tab left running
local firstName

step(1500, "start a long turn", function()
    shell.show("agent")
    say("wait")
end)

step(1200, "it runs", function()
    first = agent.tabs()[#agent.tabs()]
    firstName = agent.session().name
    check("a turn is running", agent.session().turn == true)
    check("its tab is marked running", agent.tabState(first) == "running")
end)

step(200, "start another session", function()
    agent.newSession()
    check("the first keeps running", first.session.running and first.session.turn)
    check("two live tabs", #agent.tabs() == 2)
    check("the new one is empty", #agent.items() == 0 and agent.session().name == nil)
    check("the first's items are hidden",
        first.page ~= nil and gitgud.getProperty(first.page, "Visible") == "false")
    say("hello")
end)

step(1500, "the second answers", function()
    check("the second has its own session", agent.session().name ~= nil and agent.session().name ~= firstName)
    local reply = lastOf(agent.items(), "assistant")
    check("its reply lands in its own tab", reply ~= nil and reply.text == "Hello")
    check("nothing leaked into the first", lastOf(first.items, "assistant") == nil)
    check("finishing the shown session doesn't mark it", agent.tabState(agent.tabs()[#agent.tabs()]) == nil)
    shot("01-two")
end)

local before = 0

step(200, "the first asks for a permission in the background", function()
    before = #notices
    gitgud.emit("agent.permission", gitgud.jsonEncode({ session = firstName, requestId = "bg-1", tool = "Bash",
        input = { command = "make" } }))
end)

step(200, "it needs you", function()
    check("the first needs you", agent.tabState(first) == "permission")
    check("the card went to the first", lastOf(first.items, "permission") ~= nil
        and lastOf(agent.items(), "permission") == nil)
    check("it asked for you", #notices == before + 1 and notices[#notices]:find("permission", 1, true) ~= nil)
    check("named in the app", attentions[#attentions] and attentions[#attentions].what == "permission")
    shot("02-needs-you")
end)

step(200, "answer it from its tab", function()
    -- The list: Bragi, then the project, newest first; pick the first's row.
    for i, row in ipairs(agent.sessionRows()) do
        if row.tab == first then
            gitgud.emit("AgentSessionList.selected", tostring(i - 1))
        end
    end
end)

step(300, "the first is shown", function()
    check("picking it shows it", agent.session().name == firstName)
    check("its items are visible", gitgud.getProperty(first.items[1].name, "Visible") == "true")
    check("the idle second was closed", #agent.tabs() == 1)
    local card = lastOf(agent.items(), "permission")
    agent.answer(card, true)
    check("answered", card.answer == "Allowed")
    check("running again", agent.tabState(first) == "running")
end)

step(200, "leave it running, and it finishes in the background", function()
    agent.newSession()
    before = #notices
    gitgud.emit("agent.result", gitgud.jsonEncode({ session = firstName, isError = false, interrupted = false,
        text = "All done", sessionId = "fake-session" }))
end)

step(200, "finished in the background", function()
    check("marked finished", agent.tabState(first) == "done")
    check("it asked for you", #notices == before + 1 and notices[#notices]:find("finished", 1, true) ~= nil)
    check("the shown tab didn't change", agent.session().name == nil)
    shot("03-finished")
end)

step(200, "looking at it clears the mark", function()
    agent.showTab(first)
    check("shown", agent.session().name == firstName)
    check("no longer marked", agent.tabState(first) == nil)
    say("wait")
end)

step(800, "notifications off", function()
    settings.set("bragi.notify", false)
    before = #notices
    agent.newSession()
    check("busy again, so kept", #agent.tabs() == 2)
    gitgud.emit("agent.result", gitgud.jsonEncode({ session = firstName, isError = true, interrupted = false,
        text = "Broke", sessionId = "fake-session" }))
end)

step(200, "failed in the background", function()
    check("no OS request when switched off", #notices == before)
    check("still marked failed", agent.tabState(first) == "failed")
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
