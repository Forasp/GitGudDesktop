--- tests/ui/bragi-narrate-live.lua: spoken updates as they happen
-- (bragi.updateSeconds 0, the default). A step is told at once, also while
-- a line plays: the narrator gets the line playing (`speaking`) and its line
-- follows it. A narration line still waiting to play when something newer
-- comes is dropped and made again with its steps and the new ones
-- (`replacing`), at most twice; the line playing is never cut. A line made
-- again whose new line doesn't come (here a line about narrating, which is
-- never said) stays queued and plays. Against the
-- fake claude (tests/fake_claude.cpp: "work on <topic>" reads a file, then
-- searches) and a fake voice service that plays says one after another,
-- as the engine does.
--
-- Run it like bragi-narrate.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints "[check] ...".

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
local settings = require("core.settings")
local shell = require("bragi.shell")
local voice = require("bragi.voice")

settings.set("bragi.claudeProgram", fake)

-- What the narrator was asked. With `quietRewrites`, a request to make a
-- line again gets "quietly" (the fake narrator then talks about staying
-- quiet, a line that's never said).
local asks = {}
local quietRewrites = false
local realAgentSend = gitgud.agentSend
gitgud.agentSend = function(name, body)
    if tostring(name):find("^bragi%-narrate") then
        local payload = type(body) == "string" and gitgud.jsonDecode(body) or body
        if type(payload) == "table" and payload.steps then
            asks[#asks + 1] = payload
            if quietRewrites and payload.replacing then
                payload.request = tostring(payload.request or "") .. " quietly"
                body = type(body) == "string" and gitgud.jsonEncode(payload) or payload
            end
        end
    end
    return realAgentSend(name, body)
end

-- The fake voice service: says play one after another, PLAY_MS each,
-- while `hold` keeps the one playing going.
local PLAY_MS = 300
local calls = {}
local queue = {}
local playing = nil
local hold = false
local started = {}
require("bragi.voicemodels").engine = function()
    return { installed = false }
end
local function playback(state, id)
    gitgud.emit("voice.playback", gitgud.jsonEncode({ state = state, id = id }))
end
local playNext
local function finish(id)
    if playing == id then
        playing = nil
        playback("stopped", id)
        gitgud.after(10, playNext)
    end
end
playNext = function()
    if playing or #queue == 0 then
        return
    end
    local item = table.remove(queue, 1)
    playing = item.id
    started[item.id] = true
    playback("started", item.id)
    if not hold then
        gitgud.after(PLAY_MS, function()
            finish(item.id)
        end)
    end
end
voice.backend = {
    available = function()
        return true
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
    speak = function(id, body)
        calls[#calls + 1] = { name = "speak", id = id, text = body }
        queue[#queue + 1] = { id = id, text = body }
        gitgud.after(10, playNext)
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
        for i, item in ipairs(queue) do
            if item.id == id then
                table.remove(queue, i)
                return
            end
        end
        finish(id)
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

local function said(prefix)
    for _, c in ipairs(calls) do
        if c.name == "speak" and tostring(c.text):find(prefix, 1, true) == 1 then
            return c
        end
    end
    return nil
end
local function stopped(id)
    for _, c in ipairs(calls) do
        if c.name == "speakStop" and c.id == id then
            return true
        end
    end
    return false
end
local function hasStep(steps, name, summary)
    for _, s in ipairs(steps or {}) do
        if s.name == name and (not summary or tostring(s.summary or ""):find(summary, 1, true)) then
            return true
        end
    end
    return false
end

local first

step(1500, "as it happens is the default", function()
    shell.show("agent")
    check("updates as they happen", bragiSettings.updateSeconds() == 0)
    check("shown that way", bragiSettings.showSeconds(0) == "As it happens")
    hold = true -- the first line keeps playing
    voice.guard.saidLately = {}
    agent.send("work on alpha")
end)

step(3500, "told while the first line plays", function()
    first = said("Looking into: work on alpha")
    check("the first line plays", first ~= nil and playing == first.id)
    local followed = false
    for _, a in ipairs(asks) do
        if a.speaking == "Looking into: work on alpha" and #a.steps > 0 then
            followed = true
        end
    end
    check("the narrator was asked while it played, and told what plays", followed)
    -- A line waiting behind it, made again when the next step came.
    local rewrote = nil
    for _, a in ipairs(asks) do
        if a.replacing and not rewrote then
            rewrote = a
        end
    end
    check("a line not said yet was made again", rewrote ~= nil)
    check("with its steps and the new one", rewrote ~= nil and hasStep(rewrote.steps, "Read")
        and hasStep(rewrote.steps, "Grep"))
    local most = 0
    for _, line in ipairs(voice.logLines()) do
        local n = tonumber(line:match('narrate%-rewrite .*"rewrites":(%d+)'))
        most = math.max(most, n or 0)
    end
    check("made again at most twice", most >= 1 and most <= 2)
    check("the line playing was never cut", first ~= nil and not stopped(first.id))
    hold = false
    if first then
        finish(first.id)
    end
end)

step(6500, "the rest plays in order, then the reply", function()
    check("the turn ended", not agent.current().session.turn)
    local after = said("Now: callers of alpha")
    check("the newest step was told", after ~= nil)
    check("the reply is retold", said("Summary: Worked through it.") ~= nil)
    local cutPlaying = false
    for _, c in ipairs(calls) do
        if c.name == "speakStop" and started[c.id] and c.id ~= (said("Summary:") or {}).id then
            cutPlaying = true
        end
    end
    check("only lines not yet playing were dropped", not cutPlaying)
end)

-- The log lines with `what` in them.
local function logCount(what)
    local n = 0
    for _, line in ipairs(voice.logLines()) do
        if line:find(what, 1, true) then
            n = n + 1
        end
    end
    return n
end

local quietFrom, rewritesBefore, droppedBefore, opening, waiting = 0, 0, 0, nil, nil
step(300, "a line made again that doesn't come", function()
    hold = true
    quietRewrites = true
    voice.guard.saidLately = {}
    quietFrom, rewritesBefore = #calls, logCount(" narrate-rewrite ")
    droppedBefore = logCount("about narrating")
    agent.send("work on beta")
end)

step(3500, "the line waiting is kept", function()
    opening = said("Looking into: work on beta")
    check("the first line plays", opening ~= nil and playing == opening.id)
    for i = quietFrom + 1, #calls do
        local c = calls[i]
        if not waiting and c.name == "speak" and tostring(c.text):find("Now: ", 1, true) == 1 then
            waiting = c
        end
    end
    check("a line waits behind it", waiting ~= nil and not started[waiting.id])
    local asked = false
    for _, a in ipairs(asks) do
        asked = asked or (waiting ~= nil and a.replacing == waiting.text)
    end
    check("it was to be made again", asked)
    check("the new line wasn't said", logCount("about narrating") > droppedBefore)
    check("so it wasn't replaced", logCount(" narrate-rewrite ") == rewritesBefore)
    check("and wasn't stopped", waiting ~= nil and not stopped(waiting.id))
    quietRewrites = false
    hold = false
    if opening then
        finish(opening.id)
    end
end)

step(1000, "it plays", function()
    check("the line kept played", waiting ~= nil and started[waiting.id] == true and not stopped(waiting.id))
end)

step(6000, "the turn ends", function()
    check("the turn ended", not agent.current().session.turn)
end)

step(300, "timed updates still work", function()
    settings.set("bragi.updateSeconds", "1")
    check("1 counts as 3", bragiSettings.updateSeconds() == 3 and voice.guard.updateMs() == 3000)
    settings.set("bragi.updateSeconds", "0")
    check("0 is as it happens", voice.guard.updateMs() == 0)
end)

step(300, "done", function()
    for _, t in ipairs(agent.tabs()) do
        if t.session.name then
            gitgud.agentStop(t.session.name)
        end
    end
    gitgud.emit("window.close", "")
end)

harness.run()
