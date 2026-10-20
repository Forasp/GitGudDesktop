--- tests/ui/bragi-slash.lua: slash commands run without typing them
-- (bragi/slash.lua): the master's bragi_slash_command on
-- itself (it waits until the turn that called it is over, which ends
-- normally), on another conversation (now when idle, after its turn when
-- it works), refused for the app's own commands and unknown ones; and a
-- typed request in words that the router calls `command` ("compact this
-- conversation"), run in the conversation shown, while one it can't run
-- goes on as a message.
--
-- Run it like bragi-master.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT,
-- GITGUD_SHOTS, GITGUD_TEST_CLAUDE, a scratch CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
local config = os.getenv("CLAUDE_CONFIG_DIR")
if gitgud.currentUi().id ~= "bragi" or not fake or not config then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local master = require("bragi.master")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")
local slash = require("bragi.slash")

settings.set("bragi.claudeProgram", fake)
settings.set("bragi.userName", "Sam")
local f = assert(io.open(config .. "/fake-transcripts", "wb"))
f:write("on\n")
f:close()
agent.IN_USE_SECONDS = 0

local here = repo.state().path:gsub("[/\\]+$", "")

local SAVED = "5555eeee-0000-0000-0000-000000000005"
local function writeSaved(cwd, id, title)
    local dir = config .. "/projects/" .. cwd:gsub("[^%w]", "-")
    gitgud.makeDir(dir)
    local out = assert(io.open(dir .. "/" .. id .. ".jsonl", "wb"))
    out:write(gitgud.jsonEncode({ type = "user", cwd = cwd, message = { role = "user", content = title } }), "\n")
    out:write(gitgud.jsonEncode({ type = "assistant", cwd = cwd, message = { role = "assistant",
        content = { { type = "text", text = "Looked at the loot table." } } } }), "\n")
    out:close()
end

local function shot(name)
    gitgud.screenshot(OUT .. "/slash-" .. name .. ".png")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function has(s, part)
    return tostring(s or ""):find(part, 1, true) ~= nil
end
local function lastOf(items, kind)
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
local function reply()
    local item = lastOf(agent.items(), "assistant")
    return item and item.text or ""
end
local function compactions(items)
    local n = 0
    for _, item in ipairs(items) do
        n = n + ((item.kind == "note" and has(item.text, "Compacted the conversation")) and 1 or 0)
    end
    return n
end
--- The index of the last item of a kind with this text, or 0.
local function indexOf(items, kind, body)
    for i = #items, 1, -1 do
        if items[i].kind == kind and items[i].text == body then
            return i
        end
    end
    return 0
end
local function tabTitled(title)
    for _, tab in ipairs(agent.tabs()) do
        if tab.title == title then
            return tab
        end
    end
    return nil
end

local bragi

step(1200, "Bragi", function()
    writeSaved(here, SAVED, "Fix the loot table")
    shell.show("agent")
    agent.refreshSessions(true)
    bragi = master.open()
    check("the master conversation", bragi ~= nil and bragi.master == true)
    say('call bragi_slash_command {"command":"/compact keep the plan"}')
end)

-- On itself: the command comes from inside the master's turn (the tool
-- call), so it waits until that turn is over, which ends as usual.
step(2500, "compacted itself after its turn", function()
    local items = bragi.items
    local answered = indexOf(items, "assistant", reply())
    check("the tool answered, not refused", has(reply(), "/compact keep the plan runs in this conversation as "
        .. "soon as this turn is over") and not has(reply(), "Refused"))
    check("the turn ended normally", not has(lastOf(items, "note") and lastOf(items, "note").text, "error"))
    local sent = indexOf(items, "user", "/compact keep the plan")
    check("then the command went as typed, after the reply", sent > answered and answered > 0)
    check("and Claude Code compacted", compactions(items) == 1)
    check("nothing left waiting", slash.waiting(bragi) == nil and not bragi.session.turn)
    shot("01-self")
    say('call bragi_slash_command {"command":"compact","id":"' .. SAVED .. '"}')
end)

step(2500, "on another conversation, idle", function()
    check("Bragi says it ran there", has(reply(), "Ran /compact in \"Fix the loot table\" in repo"))
    local tab = tabTitled("Fix the loot table")
    check("it resumed in the background", tab ~= nil and tab ~= agent.current())
    check("it got /compact", tab and lastOf(tab.items, "user") and lastOf(tab.items, "user").text == "/compact")
    check("and compacted", tab and compactions(tab.items) == 1)
    check("Bragi follows it", tab and master.followed(tab))
    -- Working: it waits for the turn's end.
    tab.session.turn = true
    say('call bragi_slash_command {"command":"/compact","id":"' .. SAVED .. '"}')
end)

step(2000, "on another conversation, working", function()
    local tab = tabTitled("Fix the loot table")
    -- Its reply, wherever a followed conversation's news landed around it.
    local said = false
    local items = agent.items()
    for i = #items, math.max(1, #items - 4), -1 do
        said = said or (items[i].kind == "assistant" and has(items[i].text, "\"Fix the loot table\" in repo is running: "
            .. "/compact runs there once its turn is over"))
    end
    check("Bragi says it waits for its turn", said)
    check("not sent yet", compactions(tab.items) == 1 and slash.waiting(tab) == "/compact")
    tab.session.turn = false
end)

step(2000, "its turn is over", function()
    local tab = tabTitled("Fix the loot table")
    check("then it runs", compactions(tab.items) == 2 and slash.waiting(tab) == nil)
    say('call bragi_slash_command {"command":"/model sonnet"}')
end)

step(1800, "the model isn't a command here", function()
    check("refused, pointing to the settings tool", has(reply(), "Refused: /model is changed with "
        .. "bragi_settings_set"))
    say('call bragi_slash_command {"command":"/clear"}')
end)

step(1800, "nor starting over", function()
    check("/clear is refused", has(reply(), "Refused: /clear starts a new conversation"))
    say('call bragi_slash_command {"command":"/frobnicate"}')
end)

step(1800, "an unknown command", function()
    check("refused, with the commands there are", has(reply(), "Refused: There's no /frobnicate command.")
        and has(reply(), "/compact"))
    say('call bragi_slash_command {"command":"/compact","id":"nope"}')
end)

step(1800, "an unknown conversation", function()
    check("refused", has(reply(), "Refused: No conversation nope."))
    check("nothing ran on Bragi meanwhile", compactions(bragi.items) == 1)
    -- Typed in words, in a project conversation: the router says `command`.
    agent.newSession()
    say("hello")
end)

local plain
step(1800, "a project conversation", function()
    plain = agent.current()
    check("a conversation of its own", not plain.master and reply() == "Hello")
    say("compact this conversation")
end)

step(2500, "compacted from words", function()
    local items = plain.items
    local asked = indexOf(items, "user", "compact this conversation")
    local noted = indexOf(items, "note", "Running /compact.")
    local sent = indexOf(items, "user", "/compact")
    check("the words stay as typed", asked > 0)
    check("with a quiet row under them", noted == asked + 1)
    check("then /compact went", sent > noted)
    check("and compacted", compactions(items) == 1)
    check("not a turn of its own", reply() == "Hello")
    shot("02-typed")
    say("frobnicate this conversation")
end)

step(2500, "one it can't run goes on as a message", function()
    check("sent as typed", lastOf(agent.items(), "user").text == "frobnicate this conversation")
    check("the agent got it", reply() == "You said: frobnicate this conversation")
    check("nothing ran", compactions(plain.items) == 1)
end)

step(300, "done", function()
    print("[ui-test] done")
    gitgud.emit("window.close", "")
end)

harness.run()
