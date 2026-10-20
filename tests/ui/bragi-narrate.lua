--- tests/ui/bragi-narrate.lua: whose work Bragi tells aloud.
-- A typed message is told like a spoken one, with the mic
-- off: its work narrated from a first line, its reply retold; muted,
-- nothing is. Only the conversation on screen is told: switching away
-- stops what plays about it and drops what was on its way, its reply
-- waits, and coming back says it (or, while it still works, one line
-- picking up from the steps missed). With "Keep talking when you switch
-- away" on (off by default), it goes on being told until you send to
-- another conversation. Against the fake claude (tests/fake_claude.cpp:
-- "work on <topic>", "hello") and a fake voice service.
--
-- Run it like bragi-voice.lua (GITGUD_UI=bragi, scratch APPDATA and
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
local settings = require("core.settings")
local shell = require("bragi.shell")
local updates = require("bragi.updates")
local voice = require("bragi.voice")

settings.set("bragi.claudeProgram", fake)
settings.set("bragi.updateSeconds", 3)

-- The fake voice service. Every say plays for PLAY_MS (started, then
-- stopped), unless `hold` keeps it playing.
local PLAY_MS = 200
local calls = {}
local playing = nil
local hold = false
require("bragi.voicemodels").engine = function()
    return { installed = false }
end
local function playback(state, id)
    gitgud.emit("voice.playback", gitgud.jsonEncode({ state = state, id = id }))
end
voice.backend = {
    available = function()
        return true -- the speech engine is there, the mic is off
    end,
    listen = function()
        return true
    end,
    stop = function() end,
    send = function()
        return true
    end,
    lookback = function()
        return true
    end,
    speak = function(id, body, options)
        calls[#calls + 1] = { name = "speak", id = id, text = body, at = gitgud.now() }
        gitgud.after(10, function()
            playing = id
            playback("started", id)
            if not hold then
                gitgud.after(PLAY_MS, function()
                    if playing == id then
                        playing = nil
                        playback("stopped", id)
                    end
                end)
            end
        end)
        return true
    end,
    health = function(onDone)
        onDone({ status = "ok" })
    end,
    speakPrepare = function()
        return true
    end,
    speakStop = function(id)
        calls[#calls + 1] = { name = "speakStop", id = id }
        if playing == id then
            playing = nil
            playback("stopped", id)
        end
    end,
    cancel = function()
        return true
    end,
    playing = function()
        return playing
    end,
    config = function()
        return true
    end,
    record = function()
        return true
    end,
}

--- What was said since mark n (the index of calls), as text.
local function saidSince(n, kind)
    local list = {}
    for i = (n or 0) + 1, #calls do
        if calls[i].name == (kind or "speak") then
            list[#list + 1] = calls[i].text or calls[i].id
        end
    end
    return list
end
local function has(list, prefix)
    for _, s in ipairs(list) do
        if tostring(s):find(prefix, 1, true) == 1 then
            return s
        end
    end
    return nil
end
local function logged(what, since)
    local lines = voice.logLines()
    for i = (since or 0) + 1, #lines do
        if lines[i]:find(what, 1, true) then
            return lines[i]
        end
    end
    return nil
end
local function shot(name)
    gitgud.screenshot(OUT .. "/narrate-" .. name .. ".png")
end

local A, B, mark, logMark, cutId

step(1500, "a typed message, with the mic off", function()
    shell.show("agent")
    check("the mic is off", voice.state() == "off")
    check("keep talking when you switch away is off by default", settings.get("bragi.narrateAway", false) == false)
    A = agent.current()
    mark = #calls
    voice.guard.saidLately = {} -- each turn is told afresh
    agent.send("work on alpha")
end)

step(1500, "its work is told from its first line", function()
    check("a first line from the request", has(saidSince(mark), "Looking into: work on alpha") ~= nil)
    check("it's the thread", updates.thread == A)
end)

step(7000, "and its reply retold", function()
    local said = saidSince(mark)
    check("narrated as it works", has(said, "Now: callers of alpha") ~= nil)
    check("its reply summarized and spoken", has(said, "Summary: Worked through it.") ~= nil)
    shot("01-typed")
    voice.setMuted(true)
    mark = #calls
    voice.guard.saidLately = {} -- each turn is told afresh
    agent.send("work on beta")
end)

step(8000, "muted: nothing", function()
    check("the turn ended", not A.session.turn)
    check("nothing said while muted", #saidSince(mark) == 0)
    voice.setMuted(false)
    mark = #calls
    hold = true -- the first line keeps playing
    voice.guard.saidLately = {} -- each turn is told afresh
    agent.send("work on gamma")
end)

step(1200, "switch away mid-turn", function()
    local said = calls[#calls]
    check("its first line plays", said ~= nil and said.name == "speak" and playing == said.id)
    cutId = said and said.id
    logMark = #voice.logLines()
    hold = false
    mark = #calls
    agent.newSession()
    B = agent.current()
end)

step(300, "cut", function()
    check("another conversation is shown", B ~= A and updates.thread == B)
    check("what played about it stopped", has(saidSince(mark, "speakStop"), cutId) ~= nil and playing == nil)
    check("logged as cut", logged("speak-cut", logMark) ~= nil)
end)

step(7500, "nothing about it while it's not on screen", function()
    check("its turn ended", not A.session.turn)
    check("nothing said", #saidSince(mark) == 0)
    check("its reply waits", logged("reply-missed", logMark) ~= nil)
    mark = #calls
    agent.showTab(A)
end)

step(1500, "back: its reply is told", function()
    check("its reply is said now", has(saidSince(mark), "Summary: Worked through it.") ~= nil)
    check("it's the thread again", updates.thread == A)
    voice.guard.saidLately = {} -- each turn is told afresh
    agent.send("work on delta")
end)

step(1200, "away while it works", function()
    mark = #calls
    agent.showTab(B)
end)

step(2500, "back while it still works", function()
    check("still working", A.session.turn)
    check("nothing said while away", #saidSince(mark) == 0)
    mark = #calls
    logMark = #voice.logLines()
    agent.showTab(A)
end, { full = true }) -- in real time: the fake's steps come while you're away

step(1200, "picked up from what it missed", function()
    local line = logged("pick-up", logMark)
    check("picked up with the steps missed", line ~= nil and (tonumber(line:match('"steps":(%d+)')) or 0) >= 1)
    check("one line from them at once", has(saidSince(mark), "Now: callers of delta") ~= nil)
end)

step(7000, "and on to its reply", function()
    check("its reply", has(saidSince(mark), "Summary: Worked through it.") ~= nil)
    settings.set("bragi.narrateAway", true)
    mark = #calls
    voice.guard.saidLately = {} -- each turn is told afresh
    agent.send("work on epsilon")
end)

step(1200, "with keep talking on, switch away", function()
    agent.showTab(B)
end)

step(7500, "it goes on being told", function()
    check("still the thread while B is shown", agent.current() == B and (updates.thread == A or not A.session.turn))
    local said = saidSince(mark)
    check("narrated while away", has(said, "Now: callers of epsilon") ~= nil)
    check("its reply told while away", has(said, "Summary: Worked through it.") ~= nil)
    shot("02-kept")
    agent.showTab(A)
end)

step(800, "until you send to another conversation", function()
    voice.guard.saidLately = {} -- each turn is told afresh
    agent.send("work on zeta")
end)

step(1200, "send to B", function()
    agent.showTab(B)
end)

step(300, "B gets a message", function()
    check("A is still told", updates.thread == A)
    mark = #calls
    agent.send("hello")
end)

step(7000, "B is told now, A isn't", function()
    check("B is the thread", updates.thread == B)
    local said = saidSince(mark)
    check("B's reply told", has(said, "Summary: Hello") ~= nil)
    check("nothing more about A", has(said, "Summary: Worked through it.") == nil)
    shot("03-sent-elsewhere")
end)

step(300, "the setting in Settings", function()
    settings.set("bragi.narrateAway", false)
    require("bragi.settings").open("appearance")
end)

step(1000, "a toggle under Voice output, off", function()
    local s = require("bragi.settings")
    check("keep talking when you switch away is a toggle", gitgud.getText(s.widget(4, 9, "Title"))
        == "Keep talking when you switch away"
        and gitgud.getProperty(s.widget(4, 9, "Check"), "Selected") == "false")
    shot("04-setting")
end)

step(300, "done", function()
    for _, t in ipairs(agent.tabs()) do
        if t.session.name then
            gitgud.agentStop(t.session.name)
        end
    end
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
