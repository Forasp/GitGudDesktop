--- tests/ui/bragi-decider.lua: the turn-taking model ending a spoken
-- message (bragi/decider.lua). With an engine that has the model (its
-- `ready` says so), Bragi asks it once the words have settled and the
-- speech has stopped, with the project line (the folder and its README),
-- Bragi's last words, and the message so far; it ends the message only
-- when the model is sure it's complete after enough silence, never on an
-- answer about older words, and the Haiku judge isn't asked meanwhile.
-- More words reset the wait. A model that fails, or that the engine won't
-- run, leaves the judge to it. A "done" the engine didn't take leaves the
-- message open, and the next sure answer sends it again.
-- The voice service is faked: voice.backend is replaced and the voice.*
-- events are emitted here; the model's answers are made up here.
--
-- Run it like bragi-voice.lua (GITGUD_UI=bragi, scratch APPDATA and
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

local decider = require("bragi.decider")
local settings = require("core.settings")
local shell = require("bragi.shell")
local voice = require("bragi.voice")

settings.set("bragi.claudeProgram", fake)

local calls = {}
local function called(name)
    local list = {}
    for _, c in ipairs(calls) do
        if c.name == name then
            list[#list + 1] = c
        end
    end
    return list
end
local function emit(kind, fields)
    gitgud.emit("voice." .. kind, gitgud.jsonEncode(fields))
end
local function logged(what)
    return table.concat(voice.logLines(), "\n"):find(what, 1, true) ~= nil
end
local function judged()
    local n = 0
    for _, line in ipairs(voice.logLines()) do
        if line:find(" judge ", 1, true) then
            n = n + 1
        end
    end
    return n
end
-- The model's answer to the newest request: complete with `p`, the rest
-- mid_thought, after `pause` seconds of silence.
local function answer(p, pause, extra)
    local req = called("decide")[#called("decide")]
    local fields = { id = req.request.id, pause = pause, speaking = false, tokens = 40, ms = 12, t = 1000,
        outputs = { p_state = { p, 1 - p, 0, 0 }, p_who = { 0.9, 0.05, 0.05 }, p_project = { 0.6, 0.3, 0.1 } } }
    for k, v in pairs(extra or {}) do
        fields[k] = v
    end
    emit("decision", fields)
end
local function sends()
    return #called("send")
end
local function count(what)
    local n = 0
    for _, line in ipairs(voice.logLines()) do
        if line:find(what, 1, true) then
            n = n + 1
        end
    end
    return n
end
-- The engine not taking a send, or not running the model.
local sendFails, decideFails = false, false

require("bragi.voicemodels").engine = function()
    return { installed = false }
end
voice.backend = {
    available = function()
        return true
    end,
    listen = function(options)
        calls[#calls + 1] = { name = "listen", options = options }
        return true
    end,
    stop = function()
        calls[#calls + 1] = { name = "stop" }
    end,
    send = function(reason)
        calls[#calls + 1] = { name = "send", reason = reason }
        if sendFails then
            return nil, "not listening"
        end
        return true
    end,
    decide = function(request)
        calls[#calls + 1] = { name = "decide", request = request }
        if decideFails then
            return nil, "busy"
        end
        return true
    end,
    lookback = function(id)
        gitgud.after(10, function()
            emit("lookback", { id = id, segments = {} })
        end)
        return true
    end,
    speak = function()
        return true
    end,
    health = function(onDone)
        onDone({ status = "ok", sttProvider = "stt", ttsProvider = "tts" })
    end,
    speakPrepare = function()
        return true
    end,
    speakStop = function() end,
    cancel = function()
        return true
    end,
    playing = function()
        return nil
    end,
    config = function()
        return true
    end,
    record = function()
        return true
    end,
}

step(300, "the Agent view", function()
    shell.show("agent")
end)

step(300, "listening, with an engine that has the model", function()
    voice.toggle()
    check("listening asked", #called("listen") == 1)
    emit("ready", { version = 0, keywords = true, vocabulary = true, decider = true })
end)

step(300, "a message starts", function()
    check("listening", voice.state() == "listening")
    check("the log says the model is there", logged('"decider":true'))
    emit("wake", { id = "m1", t = 0 })
    emit("vad", { speaking = true, t = 0 })
    emit("partial", { id = "m1", text = "Can you check whether the build passed?", t = 900 })
end)

step(1200, "while speech goes on, nothing is asked", function()
    check("no request while speaking", #called("decide") == 0)
    emit("vad", { speaking = false, t = 1200 })
    emit("pause", { id = "m1", text = "Can you check whether the build passed?", t = 1200 })
end)

step(1000, "the speech stopped: the model is asked", function()
    local list = called("decide")
    check("asked once (one answer at a time)", #list == 1)
    local r = list[1] and list[1].request or {}
    check("about the project: the folder and its README", tostring(r.first):find("^repo: A scratch repository") ~= nil)
    check("with the message and the pause for the engine to fill",
        r.second == "message: Can you check whether the build passed? | pause: {pause} s")
    check("the model's lengths", r.maxLength == 256 and r.firstMax == 40)
    check("the Haiku judge isn't asked", judged() == 0)
    answer(0.3, 0.7)
end)

step(700, "not sure yet: it waits and asks again", function()
    check("nothing sent", sends() == 0)
    check("the answer is logged", logged(" decide ") and logged("complete 0.30"))
    check("asked again", #called("decide") == 2)
    answer(0.92, 0.4)
end)

step(700, "sure, but not enough silence yet", function()
    check("nothing sent", sends() == 0)
    check("asked again", #called("decide") == 3)
    answer(0.92, 0.8)
end)

step(300, "sure after enough silence: the message ends", function()
    check("sent once, as done", sends() == 1 and called("send")[1].reason == "done")
    check("logged as the model's", logged('"by":"model"'))
end)

step(700, "no more requests for an ended message", function()
    local before = #called("decide")
    gitgud.after(600, function()
        check("none after it ended", #called("decide") == before)
    end)
    emit("cancelled", { id = "m1" })
end)

step(900, "a second message", function()
    emit("wake", { id = "m2", t = 5000 })
    emit("vad", { speaking = true, t = 5000 })
    emit("partial", { id = "m2", text = "So the thing with the parser is", t = 5800 })
    emit("vad", { speaking = false, t = 6000 })
end)

step(1000, "asked about the words so far", function()
    local r = called("decide")[#called("decide")].request
    check("about the first words", r.second:find("the parser is |", 1, true) ~= nil)
    -- More words come before it answers.
    emit("vad", { speaking = true, t = 6500 })
    emit("partial", { id = "m2", text = "So the thing with the parser is that it drops comments", t = 7000 })
    emit("vad", { speaking = false, t = 7200 })
    local before = sends()
    answer(0.95, 0.9)
    check("an answer about older words never ends it", sends() == before)
end)

step(300, "the words grew: the wait starts again", function()
    local r = called("decide")[#called("decide")].request
    check("not asked again before the words settle", r.second:find("drops comments", 1, true) == nil)
end)

step(800, "then asked about all of it", function()
    local r = called("decide")[#called("decide")].request
    check("with the new words", r.second:find("drops comments", 1, true) ~= nil)
    answer(0.9, 0.9, { outputs = { p_state = { 0.9, 0.1, 0, 0 } } })
end)

step(500, "an answer the model can't give is a failure", function()
    check("nothing sent", sends() == 1)
    check("logged", logged(" decide-failed "))
end)

step(300, "after a failure the judge decides", function()
    local before = #called("decide")
    emit("pause", { id = "m2", text = "So the thing with the parser is that it drops comments", t = 7200 })
    gitgud.after(2500, function()
        check("the model isn't asked again", #called("decide") == before)
        check("the Haiku judge is", judged() >= 1)
    end)
end)

step(3000, "a new connection with the model brings it back", function()
    emit("cancelled", { id = "m2" })
    emit("ready", { version = 0, decider = true })
    emit("wake", { id = "m3", t = 9000 })
    emit("partial", { id = "m3", text = "What time is it?", t = 9500 })
    emit("vad", { speaking = false, t = 9600 })
end)

local sentBefore, decideBefore, failedBefore, judgedBefore = 0, 0, 0, 0
step(1200, "asked again, with Bragi's last words when there are some", function()
    local r = called("decide")[#called("decide")].request
    check("asked about the new message", r.second:find("What time is it?", 1, true) ~= nil)
    check("the request builds the asked part", decider.request("x", "yes", "Want me to merge it?").second
        == "asked: Want me to merge it? | message: yes | pause: {pause} s")
    local long = {}
    for i = 1, 50 do
        long[#long + 1] = "w" .. i
    end
    local second = decider.request("x", "ok", table.concat(long, " ")).second
    check("only the last 40 of them", second:find("^asked: w11 w12") ~= nil and second:find("w10 ", 1, true) == nil)
    -- Sure, but the engine doesn't take the send.
    sendFails = true
    decideBefore = #called("decide")
    answer(0.95, 0.9)
end)

step(700, "the send failed: the message stays open", function()
    sentBefore = sends()
    check("it tried to send", sentBefore >= 1 and called("send")[sentBefore].reason == "done")
    check("logged", logged(" done-failed "))
    local list = called("decide")
    check("the model is asked again", #list > decideBefore
        and list[#list].request.second:find("What time is it?", 1, true) ~= nil)
    sendFails = false
    answer(0.95, 1.2)
end)

step(300, "the next sure answer sends it", function()
    check("sent again, as done", sends() == sentBefore + 1 and called("send")[sends()].reason == "done")
    emit("cancelled", { id = "m3" })
end)

step(300, "a message the engine won't run the model for", function()
    decideFails = true
    decideBefore = #called("decide")
    failedBefore = count(" decide-failed ")
    judgedBefore = judged()
    emit("wake", { id = "m4", t = 12000 })
    emit("partial", { id = "m4", text = "Is the release out yet?", t = 12500 })
    emit("vad", { speaking = false, t = 12600 })
end)

step(1500, "the request failed: the judge decides", function()
    check("asked once", #called("decide") == decideBefore + 1)
    check("logged once", count(" decide-failed ") == failedBefore + 1)
    local before = #called("decide")
    gitgud.after(2500, function()
        check("the model isn't asked again", #called("decide") == before)
        check("no more failures logged", count(" decide-failed ") == failedBefore + 1)
        check("the Haiku judge is asked", judged() > judgedBefore)
    end)
end)

step(3000, "stop", function()
    decideFails = false
    voice.stop()
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
