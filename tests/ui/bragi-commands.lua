--- tests/ui/bragi-commands.lua: slash commands and the app's screens for
-- Claude Code's interactive-only settings (G3): the "/" dropdown, commands
-- going to Claude Code as typed (alone, without voice context), a
-- command's output as the reply (/context), /compact's note and the output
-- it sends again shown once, the conversation opened again with its
-- commands, /model and /memory opening Settings, /help, /tasks, /rewind
-- and /resume opening the app's own screens, /clear
-- starting over, effort and output style reaching the command line, and
-- signing in.
-- Against the fake claude (tests/fake_claude.cpp).
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

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
local bragiSettings = require("bragi.settings")
local popup = require("ui.popup")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)
-- Sessions saved the way Claude Code saves them, to open one again.
local f = assert(io.open(os.getenv("CLAUDE_CONFIG_DIR") .. "/fake-transcripts", "wb"))
f:write("on\n")
f:close()

local function shot(name)
    gitgud.screenshot(OUT .. "/commands-" .. name .. ".png")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function last(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
local function count(kind)
    local n = 0
    for _, item in ipairs(agent.items()) do
        if item.kind == kind then
            n = n + 1
        end
    end
    return n
end
local function has(list, name)
    for _, v in ipairs(list) do
        if v == name then
            return true
        end
    end
    return false
end

step(1500, "a session", function()
    shell.show("agent")
    say("hello")
end)

step(1500, "the commands it offers", function()
    local list = agent.slashCommands()
    check("the session's commands", has(list, "review") and has(list, "fake-skill"))
    check("the app's", has(list, "model") and has(list, "memory") and has(list, "clear"))
    local once = {}
    local repeated = false
    for _, name in ipairs(list) do
        repeated = repeated or once[name]
        once[name] = true
    end
    check("each once", not repeated)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("/re")
end)

step(400, "the dropdown", function()
    check("it opens while typing a command", popup.current() ~= nil)
    shot("01-dropdown")
end)

step(200, "pick one", function()
    popup.close()
    agent.completeSlash("review")
    check("the command waits for its arguments", gitgud.getText("AgentPromptEdit") == "/review ")
end)

step(200, "its arguments", function()
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("the parser")
    gitgud.simulateKey("enter")
end)

step(1500, "it goes to Claude Code as typed", function()
    check("sent as typed", last("user") ~= nil and last("user").text == "/review the parser")
    check("Claude Code got it", last("assistant") ~= nil and last("assistant").text == "You said: /review the parser")
    check("terminal-only commands aren't offered", not has(agent.slashCommands(), "color"))
    say("/context")
end)

local CONTEXT = "## Context Usage"
local function countText(kind, part)
    local n = 0
    for _, item in ipairs(agent.items()) do
        if item.kind == kind and (item.text or ""):find(part, 1, true) then
            n = n + 1
        end
    end
    return n
end

step(1500, "a command's output shows", function()
    check("/context sent as typed", last("user").text == "/context")
    check("its output is the reply", last("assistant") ~= nil and last("assistant").text:sub(1, #CONTEXT) == CONTEXT)
    check("the turn ended", not agent.session().turn)
    say("/compact keep it short")
end)

local sessionId = nil

step(1500, "/compact", function()
    check("sent as typed", last("user").text == "/compact keep it short")
    local note = last("note")
    check("a note says it was compacted", note ~= nil
        and note.text:find("Compacted the conversation: 45.0k tokens down to 5.0k", 1, true) ~= nil)
    check("the output it kept shows once", countText("assistant", CONTEXT) == 1)
    check("its summary isn't a message", countText("user", "being continued") == 0)
    check("no waiting row left", last("waiting") == nil)
    sessionId = agent.session().id
    shot("03-compacted")
    -- What was heard before a spoken command isn't its arguments.
    agent.send("/review notes", { context = "something said before" })
end)

step(1500, "a command goes alone", function()
    check("without the voice context", last("assistant") ~= nil and last("assistant").text == "You said: /review notes")
    agent.newSession()
end)

step(300, "the conversation opens again", function()
    check("a session id came", sessionId ~= nil)
    if sessionId then
        agent.resume(sessionId, { cwd = require("core.repo").state().path })
    end
end)

step(1500, "with its commands", function()
    local texts = {}
    for _, item in ipairs(agent.items()) do
        texts[#texts + 1] = item.kind .. ": " .. (item.text or ""):match("^[^\n]*")
    end
    local seen = table.concat(texts, " | ")
    print("[ui-test] reopened: " .. seen)
    check("the commands as typed", seen:find("user: /context | assistant: " .. CONTEXT, 1, true) ~= nil)
    check("the compaction note", seen:find("note: Compacted the conversation: 45.0k tokens down to 5.0k", 1, true) ~= nil)
    check("/compact with its instructions", seen:find("user: /compact keep it short", 1, true) ~= nil)
    check("no summary", countText("user", "being continued") == 0)
    check("no command echo", countText("user", "<command-") == 0 and countText("user", "<local-command") == 0)
    shot("04-reopened")
    say("/model")
end)

step(400, "/model opens Settings, Claude", function()
    check("Settings shows", shell.view() == "settings")
    check("nothing was sent", last("user").text == "/review notes")
    check("the model row", (gitgud.getText(bragiSettings.widget(1, 1, "Title")) or "") == "Model")
    check("effort and output style rows", (gitgud.getText(bragiSettings.widget(1, 3, "Title")) or "") == "Effort"
        and (gitgud.getText(bragiSettings.widget(1, 4, "Title")) or "") == "Output style")
    shot("02-settings")
end)

local spawned = nil
local realSpawn = gitgud.spawn

step(200, "sign in", function()
    gitgud.spawn = function(cmd)
        spawned = cmd
        return true
    end
    local x, y, w, h = gitgud.getRect(bragiSettings.widget(1, 5, "Action"))
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end)

step(300, "signing in", function()
    gitgud.spawn = realSpawn
    check("sign-in runs auth login with the subscription", spawned ~= nil
        and spawned:find("auth login --claudeai", 1, true) ~= nil)
end)

step(200, "/memory", function()
    shell.show("agent")
    say("/memory")
end)

step(400, "/memory opens Instructions and memory", function()
    check("Settings shows", shell.view() == "settings")
    check("at Instructions and memory", (gitgud.getText(bragiSettings.widget(1, 1, "Title")) or ""):find("CLAUDE", 1, true) ~= nil)
end)

-- The CLI's own screens open the app's.
step(200, "/help", function()
    shell.show("agent")
    say("/help")
end)

step(400, "/help opens the shortcuts", function()
    check("Settings shows", shell.view() == "settings")
    check("at Shortcuts", (gitgud.getText(bragiSettings.widget(1, 1, "Title")) or "") == "Search or run any command")
    shell.show("agent")
    settings.set("bragi.panel", false)
    settings.set("bragi.panel.tasks", false)
    agent.relayout()
end)

step(300, "/tasks", function()
    check("the session panel is hidden", require("bragi.sidepanel").snapshot().visible == false)
    say("/tasks")
end)

step(400, "/tasks opens the background tasks", function()
    check("the session panel shows", require("bragi.sidepanel").snapshot().visible == true)
    check("its Background tasks card unfolded", settings.get("bragi.panel.tasks", false) == true)
    check("nothing was sent", last("user").text == "/review notes")
    shot("05-tasks")
    say("/rewind")
end)

step(400, "/rewind shows every message's Rewind and Fork", function()
    local rewind = require("bragi.rewind")
    local all, n = true, 0
    for _, item in ipairs(agent.items()) do
        if item.kind == "user" and item.sent then
            n = n + 1
            all = all and rewind.actionsShown(item)
        end
    end
    check("under each message", n > 1 and all)
    check("nothing was sent", last("user").text == "/review notes")
    shot("06-rewind")
    gitgud.emit("AgentSidebarButton.clicked", "")
end)

step(300, "/resume", function()
    check("the conversations list is hidden", gitgud.getProperty("AgentSidebar", "Visible") == "false")
    say("/resume")
end)

step(400, "/resume shows the conversations", function()
    check("the list shows", gitgud.getProperty("AgentSidebar", "Visible") == "true")
    check("nothing was sent", last("user").text == "/review notes")
    local offered = {}
    for _, name in ipairs(agent.slashCommands()) do
        offered[name] = true
    end
    check("the dropdown offers all four", offered.help and offered.resume and offered.rewind and offered.tasks)
end)

step(200, "effort and output style", function()
    settings.set("bragi.effort", "high")
    settings.set("bragi.outputStyle", "Explanatory")
    shell.show("agent")
    say("/clear")
end)

step(600, "/clear starts over", function()
    check("the transcript is empty", #agent.items() == 0)
    check("the session closed", agent.session().running == false)
    say("args")
end)

step(1500, "the next session gets them", function()
    local reply = last("assistant")
    check("--effort high", reply ~= nil and reply.text:find("--effort\nhigh\n", 1, true) ~= nil)
    local given = reply and reply.text:match("%-%-settings\n([^\n]*)") or ""
    local extra = gitgud.jsonDecode(given) or {}
    check("--settings with the output style", extra.outputStyle == "Explanatory")
    -- Bragi's own tools that need no card are allowed.
    local allow = type(extra.permissions) == "table" and extra.permissions.allow or {}
    local allowed = {}
    for _, rule in ipairs(allow) do
        allowed[rule] = true
    end
    check("and the allow list for Bragi's own tools", allowed["mcp__repo__bragi_settings_get"]
        and allowed["mcp__repo__bragi_settings_set"] and not allowed["mcp__repo__bragi_send"])
    check("one user message", count("user") == 1)
end)

step(300, "done", function()
    gitgud.agentStop(agent.session().name or "")
    gitgud.emit("window.close", "")
end)

harness.run()
