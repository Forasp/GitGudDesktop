--- tests/ui/bragi-voice.lua: talking to Bragi in the Agent view (E6, first
-- slice): the mic, the live text of a message being heard, Send ending
-- it, the heard-text filter (repairs, lookback, low confidence), the reply
-- summarized and spoken (a summary that echoes the reply asked for again,
-- then cut), the helpers warmed with a ping when the mic turns on, an
-- opening line from the repaired text once the filter answers, narration
-- while the agent works (tools as they start, a "still working" line when
-- it's quiet), nothing canned ever, the speaking speed with every `say`,
-- what was heard shown only with bragi.showHeard, the voice log, the
-- providers (the engine's, the voice id, a fallback), and the
-- speaker counting only once your voice is enrolled, and quick answers (E10:
-- a quick question answered by Haiku and spoken, a hand-off said aloud, a
-- quick question while the agent works, "ask Opus", the setting off), and
-- (2026-10-14) recovered context sent with the message (more lookback for
-- "all that" or a cut-off start, the quick answerer too), no "still
-- working" filler, no narration once the answer streams, typed messages
-- while it works waiting their turn, and permission cards asked aloud and
-- answered by voice (allow, deny, unclear, another speaker, a click, no
-- answer, a wake-word answer, two at once, the setting off), Claude's
-- multiple-choice questions read out and answered by voice (an option by
-- position, unsure then confirmed, their own words, two questions, no
-- answer), and narration about skipping never spoken, a fragment the
-- filter leaves out brought back, words it can't place sent as heard,
-- "cloud desktop" read from the conversation as Claude Desktop,
-- corrections learned (spoken), used, and
-- removed in Settings, the vocabulary (products, the repository's
-- words), and (2026-10-15) the main session's appended prompt (ask
-- decisions with a card) and the follow-up window after a spoken reply
-- that asks (the answer sent without the wake word; filler, its echo,
-- someone else, a reply that doesn't ask, the time running out, the wake
-- word), nothing heard ever held in the prompt box (low confidence, a
-- filter that fails), context sent after the message and never shown in
-- it, a short message always sent with the lookback as heard (without its
-- own words or Bragi's voice) and a long one without, an echo of the
-- reply or of what was just sent dropped, a queued note leaving what's
-- typed alone, and the live text cleared on no-message and close, with
-- an old connection's events ignored, and (2026-10-18) spoken updates: a
-- followed conversation's steps told every interval after the last line
-- finished playing (none when nothing is new, incidental steps and
-- repeats dropped), its news cutting in at once and restarting the
-- interval, news waiting while you talk and said the moment you stop. The voice service is faked: voice.backend is replaced and the
-- voice.* events are emitted here. The filter and the
-- agent run the fake claude (tests/fake_claude.cpp), never the real one.
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
local app = require("core.app")
local settings = require("core.settings")
local shell = require("bragi.shell")
local voice = require("bragi.voice")

settings.set("bragi.claudeProgram", fake)
-- Spoken updates every 3 s (the shortest), so the tests don't wait long.
settings.set("bragi.updateSeconds", 3)

-- The fake voice service: every call is recorded.
local calls = {}
local manualLookback = false -- the test answers lookbacks itself
-- The filter's helper can be made to fail.
local failFilter = false
local realAgentSend = gitgud.agentSend
gitgud.agentSend = function(name, body)
    if failFilter and tostring(name):find("^bragi%-heard") then
        return false, "the test broke it"
    end
    return realAgentSend(name, body)
end
local playing = nil
local function called(name)
    local list = {}
    for _, c in ipairs(calls) do
        if c.name == name then
            list[#list + 1] = c
        end
    end
    return list
end
-- Whether a speech engine is there (voice.backend, below). The app's own
-- engine counts as missing, so Settings has no Voice models card.
local engineOn = false
require("bragi.voicemodels").engine = function()
    return { installed = false }
end
voice.backend = {
    available = function()
        return engineOn
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
        return true
    end,
    lookback = function(id, tokens)
        calls[#calls + 1] = { name = "lookback", id = id, tokens = tokens }
        -- A short message always asks: answered at once with nothing
        -- before it, unless the test answers itself.
        if not manualLookback then
            gitgud.after(10, function()
                gitgud.emit("voice.lookback", gitgud.jsonEncode({ id = id, segments = {} }))
            end)
        end
        return true
    end,
    speak = function(id, body, options)
        calls[#calls + 1] = { name = "speak", id = id, text = body, options = options }
        return true
    end,
    health = function(onDone)
        calls[#calls + 1] = { name = "health" }
        onDone({ status = "ok", sttProvider = "stt-engine", ttsProvider = "tts-engine" })
    end,
    speakPrepare = function()
        calls[#calls + 1] = { name = "speakPrepare" }
        return true
    end,
    speakStop = function(id)
        calls[#calls + 1] = { name = "speakStop", id = id }
    end,
    cancel = function()
        calls[#calls + 1] = { name = "cancel" }
        return true
    end,
    playing = function()
        return playing
    end,
    config = function(fields)
        calls[#calls + 1] = { name = "config", fields = fields }
        return true
    end,
    record = function(path)
        calls[#calls + 1] = { name = "record", path = path }
        return true
    end,
}
-- The fake narrator's snippets start with one of these.
local NARRATION = { "Now: ", "Looking into: ", "Still on: ", "Can I use ", "I'll leave that on screen.",
    "I'll get to that next.", "Which colour", "Which sections", "Did you mean", "Sorry, " }
local function isNarration(c)
    for _, prefix in ipairs(NARRATION) do
        if c.text:find(prefix, 1, true) == 1 then
            return true
        end
    end
    return false
end
--- The speak calls that weren't narration.
local function replies()
    local list = {}
    for _, c in ipairs(called("speak")) do
        if not isNarration(c) then
            list[#list + 1] = c
        end
    end
    return list
end
--- The speak calls that were narration.
local function narrations()
    local list = {}
    for _, c in ipairs(called("speak")) do
        if isNarration(c) then
            list[#list + 1] = c
        end
    end
    return list
end
local function logged(what)
    return table.concat(voice.logLines(), "\n"):find(what, 1, true) ~= nil
end
local function emit(kind, fields)
    gitgud.emit("voice." .. kind, gitgud.jsonEncode(fields))
end


local function shot(name)
    gitgud.screenshot(OUT .. "/voice-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
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
local function prompt()
    return gitgud.getText("AgentPromptEdit") or ""
end
local function status()
    return gitgud.getText("AgentVoiceState") or ""
end

--- Where the first log line with all of `parts` is (nil: none).
local function logIndex(parts)
    for i, line in ipairs(voice.logLines()) do
        local all = true
        for _, part in ipairs(parts) do
            all = all and line:find(part, 1, true) ~= nil
        end
        if all then
            return i
        end
    end
    return nil
end

step(1500, "start in the Agent view", function()
    shell.show("agent")
    check("voice starts off", voice.state() == "off" and status() == "Voice is off")
end)

step(300, "the mic without a speech engine", function()
    check("the mic says voice is off", gitgud.getProperty("AgentMicButton", "TooltipText")
        == "Voice is off: click to see why")
    clickWidget("AgentMicButton")
    check("no listening without an engine", #called("listen") == 0 and voice.state() == "off")
    local note = last("note")
    check("it says voice isn't in this build", note ~= nil and note.text == voice.UNAVAILABLE)
end)

step(300, "back to the Agent view, with an engine", function()
    engineOn = true
    shell.show("agent")
end)

step(300, "the mic turns listening on", function()
    clickWidget("AgentMicButton")
    local listen = called("listen")[1]
    check("listen asked with endBy app", listen ~= nil and listen.options.endBy == "app")
    check("with the wake word and closing phrase", listen ~= nil and listen.options.wakeWord == "Bragi"
        and listen.options.closingPhrase == "over and out")
    check("with the lookback and the wait from the scripts", listen ~= nil
        and listen.options.lookbackTokens == 5000 and listen.options.endWaitSeconds == 3)
    check("connecting", voice.state() == "connecting")
    check("speech is prepared before the first reply", #called("speakPrepare") == 1)
    check("the providers were asked", #called("health") == 1)
    check("the engine's providers", voice.providers().stt == "stt-engine" and voice.providers().tts == "tts-engine")
end)

step(1500, "the helpers were warmed", function()
    for _, helper in ipairs({ "bragi-heard", "bragi-judge", "bragi-spoken", "bragi-narrate", "bragi-barge" }) do
        check(helper .. " was pinged at mic on, cold", logIndex({ " helper ", '"helper":"' .. helper .. '"',
            '"ping":true', '"cold":true' }) ~= nil)
    end
    emit("ready", { version = 0, keywords = true, vocabulary = true })
    check("the conversation shown was started at mic on", agent.session().running == true
        and agent.session().warm == true)
    -- One shown later starts too, so its first spoken message doesn't wait
    -- out Claude Code's start-up (30 s of silence).
    agent.newSession()
    check("a new one isn't started yet", not agent.session().running)
end)

step(600, "a conversation shown while voice is on is started", function()
    check("started before any message", agent.session().running == true and agent.session().warm == true
        and #agent.items() == 0)
end)

step(200, "listening", function()
    check("listening", voice.state() == "listening")
    check("the status says the wake word", status():find("Bragi", 1, true) ~= nil)
    check("the level meter shows", gitgud.getProperty("AgentLevel", "Visible") == "true")
    check("the mic says it stops listening", gitgud.getProperty("AgentMicButton", "TooltipText") == "Stop listening")
    local hello = called("listen")[1].options.vocabulary
    local inHello = {}
    for _, w in ipairs(type(hello) == "table" and hello or {}) do
        inHello[w] = true
    end
    check("the recognizer's vocabulary goes in the hello", inHello["Claude Code"] and inHello["GitGud"]
        and inHello["repo"] and inHello["main"] and #hello <= 200)
    check("as the recognizer takes it: no slashes or colons", not table.concat(hello or {}, "\n"):find("[/:]"))
    check("what was sent is logged", logIndex({ " hotwords ", '"sent":"hello"', '"Claude Code"' }) ~= nil)
    check("and whether the recognizer uses it", logIndex({ " ready ", '"vocabulary":true' }) ~= nil)
    emit("vad", { speaking = true, t = 1 })
end)

step(400, "listening shot", function()
    shot("01-listening")
    emit("vad", { speaking = false, t = 2 })
end)

--- A log line of `kind` with all of `parts` in it.
local function loggedLine(kind, parts)
    for _, line in ipairs(voice.logLines()) do
        local all = line:find(" " .. kind .. " ", 1, true) ~= nil
        for _, part in ipairs(parts) do
            all = all and line:find(part, 1, true) ~= nil
        end
        if all then
            return true
        end
    end
    return false
end

step(200, "the vad is logged", function()
    check("speech started, with its time", loggedLine("vad", { '"speaking":true', '"t":1' }))
    check("speech stopped, with its time", loggedLine("vad", { '"speaking":false', '"t":2' }))
    -- Twelve seconds of mic level: one line of ten, two waiting.
    for i = 1, 12 do
        emit("level", { t = i * 1000, rms = -40 - i, max = -30 })
    end
end)

step(200, "ten seconds of level on one line", function()
    check("the first ten seconds, from 0", loggedLine("level",
        { '"t":0', '"rms":[-41,-42,-43,-44,-45,-46,-47,-48,-49,-50]', '"max":[-30,' }))
    check("the rest waits", not loggedLine("level", { '"t":10000' }))
    -- A gap (a new connection): what waited goes out.
    emit("level", { t = 30000, rms = -60, max = -55 })
end)

step(200, "a gap ends the line", function()
    check("the two that waited", loggedLine("level", { '"t":10000', '"rms":[-51,-52]' }))
end)

step(200, "the wake word", function()
    emit("wake", { id = "m1", t = 3, t0 = 2.5 })
end)

step(200, "live text", function()
    check("hearing", voice.state() == "hearing" and voice.hearing())
    check("the status says how to end it", status():find("over and out", 1, true) ~= nil)
    emit("partial", { id = "m1", text = "fix the lure", t = 3.5 })
end)

step(200, "a pause", function()
    check("the partial text is in the prompt box", prompt() == "fix the lure")
    check("the caret follows the words",
        tonumber(gitgud.getProperty("AgentPromptEdit", "CaretIndex") or "") == utf8.len("fix the lure"))
    emit("pause", { id = "m1", text = "fix the lure parser", t = 4 })
end)

step(200, "another message's partial", function()
    check("a pause shows the text so far", prompt() == "fix the lure parser")
    emit("partial", { id = "m9", text = "someone else's", t = 4.1 })
end)

step(200, "still this message's text", function()
    check("another message's text is ignored", prompt() == "fix the lure parser")
end)

step(300, "hearing shot", function()
    shot("02-hearing")
end)

step(200, "Send ends the message", function()
    clickWidget("AgentSendButton")
    local send = called("send")[1]
    check("send asked with reason button", send ~= nil and send.reason == "button")
    check("nothing went to the agent yet", count("user") == 0)
end)

-- What the transcript held the moment a spoken message was shown (the
-- filter can answer before the next step).
local shown = nil
local realPending = agent.voicePending
agent.voicePending = function(heard)
    local item = realPending(heard)
    local waiting = last("waiting")
    shown = shown or { text = item.text, pending = item.pending ~= nil, waiting = waiting and waiting.title,
        speaks = #called("speak") }
    return item
end

step(200, "the message arrives", function()
    emit("message", { id = "m1", text = "fix the lure parser", endedBy = "send", t0 = 2.5, t1 = 4.2 })
end)

step(200, "the message is in the filter", function()
    check("the prompt box is cleared", prompt() == "")
    check("listening again", voice.state() == "listening")
    check("the message shows at once, as heard", shown ~= nil and shown.text == "fix the lure parser"
        and shown.pending)
    check("a waiting row shows at once", shown ~= nil and shown.waiting == "Checking what was heard")
    check("nothing canned is spoken at once", shown ~= nil and shown.speaks == 0)
    check("the log times it", logged('"stage":"shown"'))
end)

--- The notes in the transcript, as one text.
local function notesText()
    local notes = {}
    for _, item in ipairs(agent.items()) do
        if item.kind == "note" then
            notes[#notes + 1] = item.text
        end
    end
    return table.concat(notes, "\n")
end

step(2300, "the filtered message went to the agent", function()
    local user = last("user")
    check("the repaired text was sent", user ~= nil and user.text == "fix the Lua parser")
    check("what was heard isn't shown by default", notesText():find("lure", 1, true) == nil)
    check("but it's logged", logged('"heard":"fix the lure parser"'))
    local opening = narrations()[1]
    -- From the checked text: a line from the raw transcript said "Bot
    -- Desktop" for "Claude Desktop".
    check("an opening line from the repaired text", opening ~= nil and opening.text == "Looking into: fix the Lua parser")
    local asked = logIndex({ " timing ", '"stage":"openingAsked"', '"id":"m1"' })
    local filtered = logIndex({ " timing ", '"stage":"filtered"', '"id":"m1"' })
    check("asked once the filter answered", asked ~= nil and filtered ~= nil and asked > filtered)
    check("the opening line is timed", logged('"stage":"opening"'))
    local speeds = true
    for _, c in ipairs(called("speak")) do
        speeds = speeds and c.options ~= nil and c.options.speed == 1.15
    end
    check("every say carries the default speed", #called("speak") >= 2 and speeds)
    if opening then
        emit("playback", { state = "started", id = opening.id })
        emit("playback", { state = "stopped", id = opening.id })
    end
    local reply = last("assistant")
    check("the agent answered", reply ~= nil and reply.text == "You said: fix the Lua parser")
    check("one message, not two", count("user") == 1 and last("user").pending == nil)
    check("no waiting row once it answered", count("waiting") == 0)
    local speak = replies()[1]
    check("a summary of the reply is spoken", speak ~= nil and speak.text == "Summary: You said: fix the Lua parser")
    check("the log times each stage", logged('"stage":"filtered"') and logged('"stage":"started"')
        and logged('"stage":"firstEvent"') and logged('"stage":"answer"') and logged('"stage":"summary"'))
    check("each helper call is timed", logged(' helper {') and logged('"helper":"bragi-heard"')
        and logged('"helper":"bragi-spoken"'))
    shot("03-sent")
end)

step(1700, "the first sound is timed", function() -- and its echo window is over
    check("first sound, the opening line", loggedLine("timing", { '"stage":"firstSound"', '"opening":true' }))
end)

-- Context: it goes to the agent after the message, in a
-- block marked as context; the transcript shows only the message. A short
-- message always fetches the lookback first, and it goes as heard.
local lookbacksBefore = 0
--- The nth lookback asked since the context tests began.
local function lookbackCall(n)
    return called("lookback")[lookbacksBefore + n]
end
--- What the agent gets for a message with context.
local function withContext(body, context)
    return "You said: " .. body .. "\n\n<voice-context>\nSpeech heard before this message, for context only; "
        .. "it may or may not be relevant. It isn't part of the message.\n" .. context .. "\n</voice-context>"
end

step(200, "a message that refers back", function()
    manualLookback = true
    lookbacksBefore = #called("lookback")
    emit("wake", { id = "m2", t = 10, t0 = 10 })
    emit("message", { id = "m2", text = "do that thing", endedBy = "closing", t0 = 10, t1 = 11 })
end)

step(2500, "a short message fetches the lookback first", function()
    local lookback = lookbackCall(1)
    check("a lookback of 1000 tokens", lookback ~= nil and lookback.tokens == 1000
        and loggedLine("lookback", { '"id":"m2"', '"why":"short"' }))
    check("nothing sent before the context came", last("user").pending ~= nil)
    if lookback then
        emit("lookback", { id = lookback.id, segments = { { t0 = 1, t1 = 2, text = "The lure parser is slow." },
            { t0 = 10, t1 = 11, text = "do that thing" } } })
    end
end)

step(2500, "sent once the context came", function()
    local user = last("user")
    check("the row shows only the message", user ~= nil and user.text == "do that thing")
    check("only one lookback", #called("lookback") == lookbacksBefore + 1)
    local reply = last("assistant")
    check("the context went after it, marked as context", reply ~= nil
        and reply.text == withContext("do that thing", "The lure parser is slow."))
    check("the message's own words aren't in the context", reply ~= nil
        and select(2, reply.text:gsub("do that thing", "")) == 1)
    check("the context isn't shown by default", notesText():find("just before", 1, true) == nil)
    check("the log says context was sent", loggedLine("sent", { '"id":"m2"', '"context":24' })
        and loggedLine("context", { '"id":"m2"', '"why":"short"', '"segments":1', '"tokens":1000' }))
    settings.set("bragi.showHeard", true)
    emit("wake", { id = "m2l", t = 12, t0 = 12 })
    emit("message", { id = "m2l", text = "did you get all that Bragi", endedBy = "done", t0 = 12, t1 = 13 })
end)

step(2500, "\"all that\": as far back as the window goes", function()
    local lookback = lookbackCall(2)
    check("a lookback of 5000 tokens at once", lookback ~= nil and lookback.tokens == 5000
        and loggedLine("lookback", { '"id":"m2l"', '"why":"long"' }))
    if lookback then
        emit("lookback", { id = lookback.id, segments = {
            { t0 = 1, t1 = 2, text = "Narration repeats itself." },
            { t0 = 3, t1 = 4, text = "It also talks over the answer." } } })
    end
end)

step(2500, "sent with all of it", function()
    local reply = last("assistant")
    check("everything before went with it", reply ~= nil and reply.text == withContext("did you get all that Bragi",
        "Narration repeats itself.\nIt also talks over the answer."))
    check("only that one lookback", #called("lookback") == lookbacksBefore + 2)
    check("shown with Show what was heard", notesText():find("Sent with what you said just before: \u{201C}"
        .. "Narration repeats itself.", 1, true) ~= nil)
    settings.set("bragi.showHeard", false)
    emit("wake", { id = "m2c", t = 14, t0 = 14 })
    emit("message", { id = "m2c", text = "do that thing again", endedBy = "done", t0 = 14, t1 = 15 })
end)

step(2500, "context cut off at its start", function()
    local lookback = lookbackCall(3)
    check("first the usual lookback", lookback ~= nil and lookback.tokens == 1000)
    if lookback then
        emit("lookback", { id = lookback.id, segments = { { t0 = 1, t1 = 2, text = "and then the parser broke." } } })
    end
end)

step(2500, "more lookback for it", function()
    local lookback = lookbackCall(4)
    check("asked for more", lookback ~= nil and lookback.tokens == 5000
        and loggedLine("lookback", { '"id":"m2c"', '"why":"cut-off"' }))
    if lookback then
        emit("lookback", { id = lookback.id, segments = { { t0 = 0, t1 = 1, text = "First the tests ran." },
            { t0 = 1, t1 = 2, text = "and then the parser broke." } } })
    end
end)

-- What the quick answerer is asked (bragi/quick.lua calls helpers.ask).
local quickAsked = {}
local helpersModule = require("bragi.helpers")
local realAsk = helpersModule.ask
helpersModule.ask = function(h, payload, done, opts)
    if h.prefix == "bragi-quick" and not payload.ping then
        quickAsked[#quickAsked + 1] = payload
    end
    return realAsk(h, payload, done, opts)
end

step(2500, "the whole thought went with it", function()
    local reply = last("assistant")
    check("sent with the start of the thought", reply ~= nil and reply.text == withContext("do that thing again",
        "First the tests ran.\nand then the parser broke."))
    check("four lookbacks in all", #called("lookback") == lookbacksBefore + 4)
    emit("wake", { id = "m2d", t = 16, t0 = 16 })
    emit("message", { id = "m2d", text = "go back over that thing I said", endedBy = "done", t0 = 16, t1 = 17 })
end)

step(2500, "context with a phrase the filter can't place", function()
    local lookback = lookbackCall(5)
    check("the lookback was asked", lookback ~= nil)
    if lookback then
        emit("lookback", { id = lookback.id, segments = { { t0 = 1, t1 = 2, text = "Got hair in my deer hair." },
            { t0 = 2, t1 = 3, text = "The noise filter is too aggressive." } } })
    end
end)

step(2500, "sent anyway, the context as one string", function()
    -- the context came back as a list and was dropped,
    -- and "deer hair" in it held the request in the prompt box.
    local reply = last("assistant")
    check("sent with the context", reply ~= nil and reply.text == withContext("go back over that thing I said",
        "Got hair in my deer hair.\nThe noise filter is too aggressive."))
    check("not held in the prompt box", prompt() == "")
    emit("wake", { id = "m2q", t = 18, t0 = 18 })
    emit("message", { id = "m2q", text = "what time was that thing", endedBy = "done", t0 = 18, t1 = 19 })
end)

step(2500, "a quick question that refers back", function()
    local lookback = lookbackCall(6)
    check("the lookback was asked", lookback ~= nil)
    if lookback then
        emit("lookback", { id = lookback.id, segments = { { t0 = 1, t1 = 2, text = "The meeting is at three." } } })
    end
end)

step(2500, "the quick answerer gets the context", function()
    local asked = quickAsked[#quickAsked]
    check("context with the quick question", asked ~= nil and asked.question == "what time was that thing"
        and asked.context == "The meeting is at three.")
    check("answered by Haiku", last("assistant") ~= nil and last("assistant").tag == "Answered by Haiku")
    emit("wake", { id = "m2s", t = 20, t0 = 20 })
    emit("message", { id = "m2s", text = "fix the lure tokenizer", endedBy = "done", t0 = 20, t1 = 21 })
end)

step(2500, "a short message the filter needs no context for", function()
    local lookback = lookbackCall(7)
    check("still a lookback of 1000 tokens", lookback ~= nil and lookback.tokens == 1000)
    if lookback then
        -- Before it, the user; then Bragi's own latest reply coming back; then
        -- the message itself (no times on it).
        emit("lookback", { id = lookback.id, segments = {
            { t0 = 2, t1 = 3, text = "The tokenizer splits on dots." },
            { t0 = 4, t1 = 5, text = replies()[#replies()].text },
            { text = "fix the lure tokenizer" } } })
    end
end)

step(2500, "sent with the lookback as heard", function()
    check("the row shows only the message", last("user").text == "fix the Lua tokenizer")
    local reply = last("assistant")
    -- (Haiku's answer to the quick question rides along after it.)
    check("the lookback went with it, without Bragi's voice or the message", reply ~= nil
        and reply.text:find(withContext("fix the Lua tokenizer", "The tokenizer splits on dots.") .. "\n\n", 1,
            true) == 1)
    check("the filter had it too", loggedLine("filter", { '"id":"m2s"', '"context":29' }))
    lookbacksBefore = #called("lookback")
    emit("wake", { id = "m2w", t = 22, t0 = 22 })
    emit("message", { id = "m2w", text = "Please look through the parser and the tokenizer, find where the lure "
        .. "scripts are loaded at startup, and tell me which of them could be loaded later instead of now",
        endedBy = "done", t0 = 22, t1 = 30 })
end)

step(2500, "a long message fetches nothing", function()
    check("no lookback", #called("lookback") == lookbacksBefore)
    local reply = last("assistant")
    check("sent without context", reply ~= nil and reply.text == "You said: Please look through the parser and "
        .. "the tokenizer, find where the Lua scripts are loaded at startup, and tell me which of them could be "
        .. "loaded later instead of now")
    manualLookback = false
end)

-- Nothing heard is held in the prompt box: low
-- confidence, or a filter that fails, and it goes as heard.
step(200, "a message heard with low confidence", function()
    emit("wake", { id = "m3", t = 32, t0 = 32 })
    emit("message", { id = "m3", text = "maybe delete it", endedBy = "closing", t0 = 32, t1 = 33 })
end)

step(2500, "low confidence goes as heard", function()
    check("sent as heard", last("user").text == "maybe delete it" and last("user").pending == nil)
    check("the prompt box is left alone", prompt() == "")
    check("no note without Show what was heard", notesText():find("Not sure", 1, true) == nil
        and notesText():find("Sent as heard", 1, true) == nil)
    shot("04-unsure")
    failFilter = true
    emit("wake", { id = "m3f", t = 34, t0 = 34 })
    emit("message", { id = "m3f", text = "check the lure build", endedBy = "closing", t0 = 34, t1 = 35 })
end)

step(2500, "a filter that fails: sent as heard", function()
    failFilter = false
    check("logged", loggedLine("filter-failed", { '"id":"m3f"' }))
    check("sent as heard", last("user").text == "check the lure build" and last("user").pending == nil)
    check("the prompt box is left alone", prompt() == "")
    check("no note without Show what was heard", notesText():find("couldn't check", 1, true) == nil
        and notesText():find("Couldn't check", 1, true) == nil)
end)

-- Bragi hearing itself: a wake while its reply plays
-- never stops it on its own (with no words in time it's
-- only logged), and words that are the reply, or what was just sent, are
-- dropped, nothing in the prompt box.
local usersBefore = 0
step(200, "a wake while the reply plays, no words yet", function()
    usersBefore = count("user")
    playing = replies()[1].id -- "Summary: You said: fix the Lua parser"
    emit("playback", { state = "started", id = playing })
    emit("wake", { id = "e1", t = 36, t0 = 36 })
end)

step(1800, "no words in time: noted, not a barge-in", function()
    check("logged as ignored", loggedLine("wake-ignored", { '"id":"e1"', '"why":"no words yet"' }))
    check("not a barge-in", not loggedLine("barge-in", { '"id":"e1"' }))
    emit("message", { id = "e1", text = "you said fix the Lua parser", endedBy = "done", t0 = 36, t1 = 37 })
end)

step(500, "its own reply: an echo", function()
    check("dropped as an echo of the reply", loggedLine("self-wake", { '"id":"e1"', '"why":"words"' }))
    check("not sent", count("user") == usersBefore)
    check("nothing in the prompt box", prompt() == "" and not voice.hearing())
    emit("wake", { id = "e2", t = 38, t0 = 38 })
end)

step(1800, "again, with what was just sent", function()
    emit("message", { id = "e2", text = "check the lure build, check", endedBy = "done", t0 = 38, t1 = 39 })
end)

step(500, "what was just sent: an echo", function()
    check("dropped as an echo of what was sent", loggedLine("echo", { '"id":"e2"', '"of":"sent"' }))
    check("not sent", count("user") == usersBefore)
    check("nothing in the prompt box", prompt() == "")
    emit("playback", { state = "stopped", id = playing })
    playing = nil
end)

local echoStops = 0
local cancelsBefore = 0
step(200, "a wake while a reply plays", function()
    cancelsBefore = #called("cancel")
    -- The reply the fake played: "You said: fix the Lua parser".
    playing = replies()[1].id
    echoStops = #called("speakStop")
    emit("playback", { state = "started", id = playing })
    emit("wake", { id = "m4", t = 30, t0 = 30 })
end)

step(200, "the reply goes on until words are heard", function()
    check("not stopped on the wake alone", #called("speakStop") == echoStops)
    emit("partial", { id = "m4", text = "you said fix the", t = 30.5 })
end)

step(200, "its own words: an echo", function()
    check("the echo is dropped", #called("cancel") == cancelsBefore + 1 and not voice.hearing())
    check("the reply wasn't stopped", #called("speakStop") == echoStops)
    check("nothing in the prompt box", prompt() == "")
    emit("cancelled", { id = "m4" })
    emit("wake", { id = "m5e", t = 31, t0 = 31 })
end)

step(200, "other words while it plays", function()
    emit("partial", { id = "m5e", text = "Bragi stop there", t = 31.5 })
end)

step(200, "the wake word stops a reply being spoken", function()
    local stop = called("speakStop")[echoStops + 1]
    check("the playing reply stopped", stop ~= nil and stop.id == playing)
    check("the words show", prompt() == "Bragi stop there")
    emit("playback", { state = "stopped", id = playing })
    playing = nil
    emit("cancelled", { id = "m5e" })
end)

step(200, "the message was dropped", function()
    check("a dropped message leaves nothing", prompt() == "" and not voice.hearing())
    local all = table.concat(voice.logLines(), "\n")
    check("the log has the echo and the barge-in", all:find(" self-wake ", 1, true) ~= nil
        and all:find(" barge-in ", 1, true) ~= nil)
end)

-- News from conversations Bragi follows, said aloud:
-- together when they come together, never while you're talking.
-- Not only that it's done: the conversation is picked back up
-- from its own last reply (the fake helper repeats it), as a reply in the
-- master conversation that rides along with its next message.
local newsSpeaks = 0
local shownTab, masterTab = nil, nil
local lootTab = { title = "Investigating the loot tables", cwd = "C:/Games/StarTrader", items = {
    { kind = "user", text = "investigate the loot tables" },
    { kind = "assistant", text = "The drop rates were off by ten. Should I fix the vendors too?" } } }
local buildTab = { title = "Fix the build", cwd = "C:/src/lure", items = {} }
step(200, "two conversations finish", function()
    shownTab = agent.current()
    masterTab = require("bragi.master").open()
    agent.showTab(shownTab)
    newsSpeaks = #called("speak")
    app.publish("bragi.masterStatus", { tab = lootTab, what = "done" })
    app.publish("bragi.masterStatus", { tab = buildTab, what = "permission" })
end)
local wantNews = "Update: Investigating the loot tables done: The drop rates were off by ten. Should I fix the "
    .. "vendors too?; Fix the build permission"
step(2500, "told together", function()
    local speaks = called("speak")
    check("one telling for both", #speaks == newsSpeaks + 1 and speaks[#speaks].text == wantNews)
    local reply = masterTab.items[#masterTab.items]
    check("a reply in the master conversation", reply ~= nil and reply.kind == "assistant"
        and reply.text == wantNews and reply.tag == "Update by Haiku")
    local notes = masterTab.quickNotes or {}
    check("it rides along with the master's next message", #notes > 0 and notes[#notes].update == true
        and notes[#notes].a == wantNews)
    check("the shown conversation stays", agent.current() == shownTab)
    check("logged", loggedLine("news", { '"count":2', '"text":"Update: ' }))
    emit("wake", { id = "nw1", t = 40, t0 = 40 })
    app.publish("bragi.masterStatus", { tab = buildTab, what = "done" })
end)
step(2500, "not while you talk", function()
    check("held", #called("speak") == newsSpeaks + 1)
    emit("message", { id = "nw1", text = "what's new", endedBy = "done", t0 = 40, t1 = 41 })
end)
step(2500, "said once you're done", function()
    local speaks = called("speak")
    local said = false
    for i = newsSpeaks + 2, #speaks do
        said = said or speaks[i].text == "Update: Fix the build done"
    end
    check("said after", said)
end)

-- A recap: asked in any words, the filter routes it
-- `recap`; it's told from the conversations Bragi follows and spoken as it
-- is, with a quiet row under the message, never a turn of the agent's.
local recapTab = nil
step(200, "asked how things are going", function()
    recapTab = agent.current()
    recapTab.bragiFollows = true
    emit("wake", { id = "rc1", t = 42, t0 = 42 })
    emit("message", { id = "rc1", text = "catch me up on everything", endedBy = "closing", t0 = 42, t1 = 43 })
end)
step(2500, "a recap, spoken", function()
    local d = require("bragi.master").describe(recapTab)
    local want = "Recap: " .. d.title .. " is " .. d.state .. "."
    check("routed by the filter", loggedLine("route", { '"id":"rc1"', '"route":"recap"', '"by":"filter"' }))
    local spoken = replies()
    check("spoken as it is", #spoken > 0 and spoken[#spoken].text == want)
    check("a quiet row under the message", last("note") ~= nil and last("note").text == want
        and last("user").text == "catch me up on everything")
    check("not a turn of the agent's", agent.session().turn == false
        and (last("assistant") == nil or last("assistant").text ~= "You said: catch me up on everything"))
    check("logged", loggedLine("recap", { '"conversations":1', '"text":"Recap: ' }))
    recapTab.bragiFollows = nil
end)

-- A slash command asked for in words: the filter routes
-- it `command` with the command line, and it runs in the conversation
-- shown, with a quiet row and a short spoken line (bragi/slash.lua).
local compactNotes = 0
step(200, "asked to compact, in words", function()
    for _, item in ipairs(agent.items()) do
        compactNotes = compactNotes + ((item.kind == "note"
            and tostring(item.text):find("Compacted the conversation", 1, true)) and 1 or 0)
    end
    emit("wake", { id = "cm1", t = 44, t0 = 44 })
    emit("message", { id = "cm1", text = "compact this conversation please", endedBy = "closing", t0 = 44, t1 = 45 })
end)
step(2500, "the command ran", function()
    check("routed by the filter", loggedLine("route", { '"id":"cm1"', '"route":"command"', '"by":"filter"' }))
    local asked, noted, sent, compacted = nil, nil, nil, 0
    for _, item in ipairs(agent.items()) do
        if item.kind == "user" and item.text == "compact this conversation please" then
            asked = item
        elseif item.kind == "note" and item.text == "Running /compact." then
            noted = asked ~= nil
        elseif item.kind == "user" and item.text == "/compact" then
            sent = noted == true
        elseif item.kind == "note" and tostring(item.text):find("Compacted the conversation", 1, true) then
            compacted = compacted + 1
        end
    end
    check("the words stay, with a quiet row under them", asked ~= nil and noted == true)
    check("then /compact went as typed", sent == true)
    check("and Claude Code compacted", compacted == compactNotes + 1)
    local spoken = replies()
    check("said briefly", #spoken > 0 and spoken[#spoken].text == "Running /compact.")
    check("logged", loggedLine("command", { '"command":"/compact"', '"how":"now"' }))
end)

-- Once your voice is enrolled, a wake during a reply stops it only when
-- the engine says the speech is yours (the spotter heard
-- Baldr through the speakers and the reply cut itself off).
local enrolledStops = 0
step(200, "enrolled: a wake during a reply, someone else's words", function()
    emit("enrollResult", { enrolled = true })
    playing = replies()[1].id
    enrolledStops = #called("speakStop")
    emit("playback", { state = "started", id = playing })
    emit("wake", { id = "n1", t = 32, t0 = 32 })
    emit("partial", { id = "n1", text = "three things are open on the port", t = 32.5 })
end)
step(200, "not scored yet: the reply plays on", function()
    check("not stopped before the voice is known", #called("speakStop") == enrolledStops)
    emit("partial", { id = "n1", text = "three things are open on the port", t = 33, speaker = "other" })
end)
step(200, "not your voice: dropped, the reply plays on", function()
    check("never stopped", #called("speakStop") == enrolledStops)
    check("logged as not you", loggedLine("self-wake", { '"id":"n1"', '"why":"speaker"' }))
    check("nothing held", prompt() == "" and not voice.hearing())
    emit("cancelled", { id = "n1" })
    emit("wake", { id = "n2", t = 34, t0 = 34 })
    emit("partial", { id = "n2", text = "Bragi wait a second", t = 34.5, speaker = "user" })
end)
step(200, "your voice: the reply stops", function()
    local stop = called("speakStop")[enrolledStops + 1]
    check("stopped for you", stop ~= nil and stop.id == playing)
    check("logged as a barge-in", loggedLine("barge-in", { '"id":"n2"' }))
    emit("playback", { state = "stopped", id = playing })
    playing = nil
    emit("cancelled", { id = "n2" })
    emit("enrollResult", { enrolled = false })
end)

-- Never over the user: a reply that comes while a
-- message is being heard waits until it ends.
local heldSpeaks = 0
step(200, "you start talking", function()
    emit("wake", { id = "h1", t = 36, t0 = 36 })
end)
step(200, "a reply while you talk", function()
    check("hearing you", voice.hearing() ~= nil)
    heldSpeaks = #called("speak")
    voice.say("Here is the answer you asked for.")
end)
step(200, "held until you're done", function()
    check("not said over you", #called("speak") == heldSpeaks)
    check("logged as held", loggedLine("speak-held", { '"hearing":"h1"' }))
    emit("message", { id = "h1", text = "and one more thing", endedBy = "done", t0 = 36, t1 = 37,
        speaker = "user" })
end)
step(500, "then said", function()
    local speaks = called("speak")
    local said = false
    for i = heldSpeaks + 1, #speaks do
        said = said or speaks[i].text == "Here is the answer you asked for."
    end
    check("said once you finished", said)
    check("logged as released", loggedLine("speak-released", { '"why":"ended"' }))
end)

step(200, "Bragi may say its own name", function()
    check("the name is found as a word", voice.mentionsWakeWord("Done, bragi, all green.")
        and voice.mentionsWakeWord("I'm Bragi."))
    check("not inside other words", not voice.mentionsWakeWord("Bragging rights."))
end)

step(200, "the microphone's echo cancellation", function()
    check("unknown until the mic is on", voice.micLine():find("Turn on", 1, true) == 1)
    emit("mic", { state = "on", device = "Microphone (echo cancelled)" })
end)

step(200, "echo cancelled", function()
    check("echo cancelled shows", voice.micLine():find("Now: echo cancelled.", 1, true) == 1)
    check("the mic line sent the waiting level first", loggedLine("level", { '"t":29000', '"rms":[-60]' }))
    check("the log says how it captures", loggedLine("mic", { '"capture":"echo cancelled"' }))
    emit("mic", { state = "on", device = "Microphone (no echo cancellation: the DSP failed)",
        route = "mic: Webcam (default); tried before: (mic: Webcam): no audio" })
end)

step(200, "plain capture", function()
    local line = voice.micLine()
    check("plain capture shows why", line:find("Now: plain capture (echo cancellation failed: the DSP failed).", 1,
        true) == 1)
    check("and its route", line:find("Route: mic: Webcam (default); tried before:", 1, true) ~= nil)
    check("logged", loggedLine("mic", { '"capture":"plain capture (echo cancellation failed: the DSP failed)"' }))
    local saved = gitgud.jsonDecode(gitgud.configRead("bragi/voice-mic.json") or "")
    check("kept in the config folder", type(saved) == "table" and saved.echo == false
        and saved.why == "the DSP failed" and saved.route:find("tried before", 1, true) ~= nil)
    emit("mic", { state = "off", device = "Microphone (no echo cancellation: the DSP failed)", seconds = 1 })
end)

step(200, "the mic off: the last capture stays", function()
    check("shown as the last time's", voice.micLine():find("Last time (", 1, true) == 1
        and voice.micLine():find("): plain capture (echo cancellation failed: the DSP failed).", 1, true) ~= nil)
    emit("mic", { state = "on", device = "Microphone (echo cancelled)" })
end)

-- Recording what the engine hears (bragi.recordVoice): a WAV file per
-- start in voice-recordings, the newest 10 kept.
local function recordings()
    local names = {}
    for _, f in ipairs(gitgud.configList("bragi/voice-recordings")) do
        names[#names + 1] = f.name
    end
    return names
end
step(200, "recording is off by default", function()
    check("no recording", #called("record") == 0)
    for i = 1, 12 do
        gitgud.configWrite(string.format("bragi/voice-recordings/2026-01-01-0000%02d.wav", i), "old")
    end
    gitgud.configWrite("bragi/voice-recordings/notes.txt", "kept")
    settings.set("bragi.recordVoice", true)
    voice.recordingChanged()
end)

step(200, "turned on while listening", function()
    local rec = called("record")[1]
    local name = rec and rec.path and rec.path:match("[^/\\]+$") or ""
    check("it records to the config folder", rec ~= nil
        and rec.path == gitgud.configPath("bragi/voice-recordings/" .. name) and name:find("^%d+%-%d+%-%d+%-%d+%.wav$"))
    check("the path is logged", loggedLine("record", { '"state":"on"', "voice-recordings" }))
    local names = recordings()
    check("the oldest went, room for the new one", #names == 10 and names[1] == "2026-01-01-000004.wav"
        and names[9] == "2026-01-01-000012.wav" and names[10] == "notes.txt")
    settings.set("bragi.recordVoice", false)
    voice.recordingChanged()
    check("turned off, it stops", #called("record") == 2 and called("record")[2].path == nil)
    emit("record", { state = "off", path = rec and rec.path, seconds = 1.5 })
end)

step(200, "the recording ended", function()
    check("logged with its length", loggedLine("record", { '"state":"off"', '"seconds":1.5' }))
    voice.recordingChanged()
    check("not again while off", #called("record") == 2)
    check("config names stay inside the config folder", not pcall(gitgud.configList, "../x")
        and not pcall(gitgud.configPath, "a//b") and not pcall(gitgud.configRemove, "voice-recordings/./x")
        and not pcall(gitgud.configRead, "/abs") and pcall(gitgud.configPath, "voice-recordings/x.wav"))
end)

step(200, "clock times are said in words", function()
    -- "3:34 PM" was read as "three thousand thirty-four".
    check("with PM", voice.forSpeech("Restarted at 3:34 PM.") == "Restarted at three thirty-four PM.")
    check("24-hour", voice.forSpeech("at 15:34:18 today") == "at three thirty-four PM today")
    check("on the hour", voice.forSpeech("by 9:00") == "by nine o'clock")
    check("on the hour, PM", voice.forSpeech("3:00 p.m.") == "three PM.")
    check("oh minutes", voice.forSpeech("9:05 am") == "nine oh five AM")
    check("midnight", voice.forSpeech("00:15") == "twelve fifteen AM")
    check("not a time", voice.forSpeech("line 12:75, a 1:2 ratio, 123:45") == "line 12:75, a 1:2 ratio, 123:45")
end)

step(200, "replies are made speakable", function()
    local spoken = voice.speakable("**Done.** See `main.lua` and [the docs](http://server.test/x).\n\n```lua\nx = 1\n```")
    check("Markdown is stripped", spoken == "Done. See main.lua and the docs. (code on screen)")
    local long = voice.speakable(string.rep("This is a sentence. ", 40))
    check("long replies are cut at a sentence", #long < 460 and long:find("The rest is on screen.", 1, true) ~= nil)
end)

step(200, "the log has every step", function()
    local all = table.concat(voice.logLines(), "\n")
    for _, kind in ipairs({ " listen ", " ready ", " heard ", " filter ", " sent ", " lookback ", " speak ", " judge ",
        " timing ", " wake ", " playback ", " mic ", " helper " }) do
        check("the log has" .. kind:gsub(" $", ""), all:find(kind, 1, true) ~= nil)
    end
end)

step(200, "a pause mid-sentence", function()
    settings.set("bragi.endWaitSeconds", "2")
    app.publish("bragi.choices")
    local function waits()
        local list = {}
        for _, c in ipairs(called("config")) do
            list[#list + 1] = c.fields.endWaitSeconds
        end
        return list
    end
    local config = waits()
    check("a new wait reaches the engine while listening", #config == 1 and config[1] == 2)
    app.publish("bragi.choices")
    check("only once", #waits() == 1)
    emit("wake", { id = "m5", t = 40, t0 = 40 })
end)

step(200, "the filter judges it unfinished", function()
    emit("pause", { id = "m5", text = "check the build and", t = 41 })
end)

step(1500, "no wait while they're still going", function()
    check("no done wait for an unfinished sentence", status():find("Sounds done", 1, true) == nil)
    emit("pause", { id = "m5", text = "check the build", t = 42 })
end)

step(1500, "a finished sentence starts the wait", function()
    check("the done wait shows", status():find("Sounds done", 1, true) ~= nil)
    emit("partial", { id = "m5", text = "check the build again", t = 42.5 })
end)

step(200, "more speech cancels the wait", function()
    check("the wait is cancelled", status():find("Sounds done", 1, true) == nil)
    emit("pause", { id = "m5", text = "check the build again", t = 43 })
end)

-- A message decoded again as it grows corrects words in a pause: that
-- isn't more speech.
step(1500, "the wait starts again", function()
    check("the done wait shows again", status():find("Sounds done", 1, true) ~= nil)
    emit("partial", { id = "m5", text = "Check the build again.", t = 43.2, speechEnd = 43000 })
end)

step(200, "a corrected decode keeps the wait", function()
    check("the wait goes on through a correction", status():find("Sounds done", 1, true) ~= nil)
end)

step(2500, "the wait ran out", function()
    local sends = called("send")
    check("ended with reason done", #sends == 2 and sends[2].reason == "done")
    check("only after the wait", #sends == 2)
    emit("message", { id = "m5", text = "check the build again", endedBy = "done", t0 = 40, t1 = 43 })
end)

step(2500, "it went to the agent", function()
    check("the message was sent", last("user").text == "check the build again")
    check("the judge has a helper of its own", logged('"helper":"bragi-judge"'))
    settings.set("bragi.showHeard", true)
    emit("wake", { id = "m5h", t = 44, t0 = 44 })
    emit("message", { id = "m5h", text = "fix the lure tests", endedBy = "closing", t0 = 44, t1 = 44.5 })
end)

step(2500, "what was heard, shown when asked", function()
    check("sent repaired", last("user").text == "fix the Lua tests")
    check("the heard line shows with bragi.showHeard",
        notesText():find("Heard \u{201C}fix the lure tests\u{201D}, changed \u{201C}lure\u{201D} to \u{201C}Lua\u{201D}",
            1, true) ~= nil)
    settings.set("bragi.showHeard", false)
end)

-- Narration: the fake agent's "work" turn streams like the real one (its
-- thinking empty), opens a Read, waits 1.5 s, opens a Grep, waits 5 s, and
-- answers.
local narrated = 0
local before = 0
step(200, "a message the agent works on", function()
    before = #narrations()
    emit("wake", { id = "n1", t = 45, t0 = 45 })
    emit("message", { id = "n1", text = "work", endedBy = "closing", t0 = 45, t1 = 46 })
end)

-- These two wait their whole time: the fake's turn sleeps for real, and
-- which of its tools gets narrated depends on the time between them.
step(2000, "an opening line from the request", function()
    check("the agent is working", agent.session().turn == true and voice.narrating())
    local first = narrations()[before + 1]
    check("the first snippet comes from the request", first ~= nil and first.text == "Looking into: work")
    check("the log times the opening line", loggedLine("timing", { '"stage":"opening"', '"id":"n1"' })
        and logged(' narrate {'))
    narrated = #narrations()
end, { full = true })

step(800, "not too often", function()
    check("at most one snippet every few seconds", #narrations() == narrated)
end, { full = true })

step(6000, "the answer ends the narration", function()
    check("the turn is over", agent.session().turn == false and not voice.narrating())
    local list = narrations()
    check("its tools were narrated later", #list >= before + 2 and list[before + 2].text == "Now: parse")
    local speaks = called("speak")
    check("then the summary", speaks[#speaks].text == "Summary: Worked through it.")
    check("the narrator has a helper of its own", logged('"helper":"bragi-narrate"'))
end)

-- A turn that says nothing for 10 s: no "still working" filler
-- (a line only when there's something new).
step(200, "a slow turn", function()
    narrated = #narrations()
    emit("wake", { id = "n3", t = 46, t0 = 46 })
    emit("message", { id = "n3", text = "slow", endedBy = "closing", t0 = 46, t1 = 46.5 })
end)

step(2000, "opened", function()
    local list = narrations()
    check("the opening line", #list == narrated + 1 and list[#list].text == "Looking into: slow")
end)

step(7800, "quiet stays quiet", function()
    local list = narrations()
    check("no still-working filler while nothing new happens", agent.session().turn == true
        and #list == narrated + 1 and not logged('"quiet":true'))
end)

step(3000, "the slow answer", function()
    local speaks = called("speak")
    check("its summary", agent.session().turn == false and speaks[#speaks].text == "Summary: Took a while.")
    narrated = #narrations()
    emit("wake", { id = "r1", t = 47, t0 = 47 })
    emit("message", { id = "r1", text = "look into the conversations", endedBy = "closing", t0 = 47, t1 = 47.5 })
end)

-- Repeats ("looking into conversations", then "looking
-- into other conversations"): a line that repeats one said lately, for
-- any message, is dropped by the app, whatever the narrator answers.
step(2500, "an opening line", function()
    local list = narrations()
    check("said", #list == narrated + 1 and list[#list].text == "Looking into: look into the conversations")
    narrated = #list
    emit("wake", { id = "r2", t = 48, t0 = 48 })
    emit("message", { id = "r2", text = "look into the other conversations", endedBy = "closing", t0 = 48,
        t1 = 48.5 })
end)

step(2500, "the same idea again, in other words", function()
    check("not said", #narrations() == narrated)
    check("dropped as a repeat", loggedLine("narrate-dropped", { '"why":"repeats"', "other conversations",
        '"said":"Looking into: look into the conversations"' }))
    emit("wake", { id = "r3", t = 49, t0 = 49 })
    emit("message", { id = "r3", text = "look into the build logs", endedBy = "closing", t0 = 49, t1 = 49.5 })
end)

step(2500, "something new is still said", function()
    local list = narrations()
    check("a new idea is said", #list == narrated + 1 and list[#list].text == "Looking into: look into the build logs")
    narrated = #list
    emit("wake", { id = "r4", t = 50, t0 = 50 })
    emit("message", { id = "r4", text = "sure, I'll check what's still in flight", endedBy = "closing",
        t0 = 50, t1 = 50.5 })
end)

-- Two near-identical lines where small words leave one idea word
-- ("Sure, I'll check what's still in flight", then "I'm
-- checking the conversation to see what's still in flight").
step(2500, "a line with one idea word", function()
    local list = narrations()
    check("said", #list == narrated + 1 and list[#list].text
        == "Looking into: sure, I'll check what's still in flight")
    narrated = #list
    emit("wake", { id = "r5", t = 51, t0 = 51 })
    emit("message", { id = "r5", text = "I'm checking the worktree to see what's still in flight",
        endedBy = "closing", t0 = 51, t1 = 51.5 })
end)

step(2500, "the same line with one word more", function()
    check("not said", #narrations() == narrated)
    check("dropped as a repeat of it", loggedLine("narrate-dropped", { '"why":"repeats"', "worktree to see",
        '"said":"Looking into: sure' }))
    emit("wake", { id = "r6", t = 52, t0 = 52 })
    emit("message", { id = "r6", text = "the flight log shows two failures", endedBy = "closing",
        t0 = 52, t1 = 52.5 })
end)

step(2500, "sharing a word isn't a repeat", function()
    local list = narrations()
    check("a new idea is said (" .. tostring(#list - narrated) .. " new, the last "
        .. tostring(list[#list] and list[#list].text) .. ")", #list == narrated + 1 and list[#list].text
        == "Looking into: the flight log shows two failures")
end)

-- Narration and the answer: nothing narrated starts once it streams; a
-- line not yet playing is dropped; one playing finishes. The fake "wait"
-- turn runs a tool and waits; its steps are published here.
local queuedLine = nil
--- A step of the shown conversation's voice turn, as bragi/agent.lua publishes it.
local function activity(s)
    app.publish("bragi.activity", s)
    app.publish("bragi.step", { tab = agent.current(), step = s })
end
step(200, "a turn to narrate", function()
    emit("wake", { id = "n4", t = 48, t0 = 48 })
    emit("message", { id = "n4", text = "wait", endedBy = "closing", t0 = 48, t1 = 48.5 })
end)

step(7000, "a narrated step, not playing yet", function()
    local list = narrations()
    queuedLine = list[#list]
    check("its tool was narrated", agent.session().turn == true and queuedLine ~= nil
        and queuedLine.text == "Now: sleep 1000")
    narrated = #list
    activity({ kind = "text", text = "Here is what I found." })
end)

step(300, "the answer starts streaming", function()
    local dropped = false
    for _, c in ipairs(called("speakStop")) do
        dropped = dropped or (queuedLine ~= nil and c.id == queuedLine.id)
    end
    check("the line not yet playing is dropped", dropped and loggedLine("narrate-dropped", { '"why":"answering"' }))
    activity({ kind = "thinking", text = string.rep("weighing the parser ", 10) })
end)

step(4000, "nothing starts while it streams", function()
    check("no narration once the answer streams", #narrations() == narrated)
    -- Reading the clock to stamp a check is incidental:
    -- not narrated, and not a sign it went back to work.
    activity({ kind = "tool", name = "Bash", starting = true })
    activity({ kind = "tool", name = "Bash", summary = "date +%H:%M" })
end)

step(3500, "a date read isn't narrated", function()
    check("nothing said for it", #narrations() == narrated)
    activity({ kind = "tool", name = "PowerShell", summary = "Get-Date -Format o" })
    activity({ kind = "tool", name = "Grep", summary = "parser" })
end)

step(1500, "back to work: narrated again", function()
    local list = narrations()
    check("a new tool step is narrated", #list == narrated + 1 and list[#list].text == "Now: parser")
    -- The thinking and the search: with the two clock reads it would be four.
    check("the clock reads never reached the narrator", loggedLine("narrate", { '"text":"Now: parser"',
        '"steps":2' }))
    queuedLine = list[#list]
    emit("playback", { state = "started", id = queuedLine.id })
    playing = queuedLine.id
end)

step(200, "the answer while it plays", function()
    narrated = #called("speakStop")
    app.publish("bragi.reply", { text = "All done here.", voice = true })
end)

step(1500, "a line playing when the answer comes finishes", function()
    local cut = false
    for i = narrated + 1, #called("speakStop") do
        cut =cut or called("speakStop")[i].id == queuedLine.id or called("speakStop")[i].id == nil
    end
    check("it wasn't cut off", not cut)
    local speaks = called("speak")
    check("the summary follows it", speaks[#speaks].text == "Summary: All done here.")
    emit("playback", { state = "stopped", id = queuedLine.id })
    playing = nil
    agent.stop()
end)

step(1500, "the turn stopped", function()
    check("stopped", agent.session().turn == false)
end)

-- Spoken updates: the steps of a conversation Bragi
-- follows, working in the background, are kept as they come; every
-- bragi.updateSeconds (3 here) after the last line finished playing, what's
-- new is told in one line, naming it; nothing new, nothing said. News from
-- it cuts in at once, even right after an update, and the interval counts
-- from it; news waits while you talk and is said the moment you stop.
local homeTab, wikiTab = nil, nil
local updateLine = nil
local function wikiStep(s)
    app.publish("bragi.step", { tab = wikiTab, step = s })
end
local function lastNarration()
    local list = narrations()
    return list[#list]
end
step(200, "a followed conversation works in the background", function()
    homeTab = agent.current()
    agent.newSession()
    wikiTab = agent.current()
    agent.send("wait", {})
    wikiTab.bragiFollows = true
    agent.showTab(homeTab)
    narrated = #narrations()
end)

step(1500, "its steps are kept, the cycle runs", function()
    wikiTab.title = "Wiki"
    wikiStep({ kind = "tool", name = "Read", summary = "notes/start.txt" })
    check("it works, the shown one doesn't", wikiTab.session.turn == true and agent.session().turn == false)
    check("the cycle runs for it", voice.narrating())
    check("nothing said before the interval", #narrations() == narrated)
end)

step(3000, "an update an interval later, naming it", function()
    local line = lastNarration()
    check("one line for it", #narrations() == narrated + 1 and line.text == "Now: Wiki on notes/start.txt")
    check("logged with the other conversation", loggedLine("narrate", { '"others":1', "Wiki" }))
    updateLine = line
    narrated = #narrations()
end, { full = true })

step(4000, "nothing new: nothing said", function()
    check("silent", #narrations() == narrated)
    -- The update plays; meanwhile it reads something.
    playing = updateLine.id
    emit("playback", { state = "started", id = updateLine.id })
    wikiStep({ kind = "tool", name = "Read", summary = "docs/theme.md" })
end)

step(4000, "nothing while the update plays", function()
    check("not over it", #narrations() == narrated)
    emit("playback", { state = "stopped", id = updateLine.id })
    playing = nil
end, { full = true })

step(2200, "the interval counts from the end of playback", function()
    check("not yet", #narrations() == narrated)
end, { full = true })

step(2000, "then the next update", function()
    local line = lastNarration()
    check("said", #narrations() == narrated + 1 and line.text == "Now: Wiki on docs/theme.md")
    narrated = #narrations()
    newsSpeaks = #called("speak")
    -- It asks something, right after that update.
    app.publish("bragi.masterStatus", { tab = wikiTab, what = "question" })
end, { full = true })

step(2500, "news cuts in at once", function()
    local speaks = called("speak")
    check("said", #speaks == newsSpeaks + 1 and speaks[#speaks].text == "Update: Wiki question")
    check("the update not playing yet gave way", loggedLine("narrate-dropped", { '"why":"news"' }))
    wikiStep({ kind = "tool", name = "Grep", summary = "palette" })
end)

step(3000, "the interval counts from the news", function()
    check("no update right after it", #narrations() == narrated)
end, { full = true })

step(3500, "then an update", function()
    local line = lastNarration()
    check("said", #narrations() == narrated + 1 and line.text == "Now: Wiki on palette")
    narrated = #narrations()
    -- Reading the clock is incidental; the same idea again is a repeat.
    wikiStep({ kind = "tool", name = "Bash", starting = true })
    wikiStep({ kind = "tool", name = "Bash", summary = "date +%H:%M" })
end, { full = true })

step(4000, "an incidental step: nothing said", function()
    check("silent", #narrations() == narrated)
    wikiStep({ kind = "tool", name = "Grep", summary = "palette" })
end, { full = true })

step(4000, "a repeat: dropped", function()
    check("not said", #narrations() == narrated)
    check("dropped as a repeat", loggedLine("narrate-dropped", { '"why":"repeats"', "on palette" }))
    newsSpeaks = #called("speak")
    emit("wake", { id = "up1", t = 60, t0 = 60 })
    app.publish("bragi.masterStatus", { tab = wikiTab, what = "permission" })
end)

step(3000, "news waits while you talk", function()
    check("held", #called("speak") == newsSpeaks)
    emit("message", { id = "up1", text = "hmm let me think", endedBy = "done", t0 = 60, t1 = 61 })
end)

step(400, "and is said the moment you stop", function()
    local speaks = called("speak")
    check("said at once", #speaks >= newsSpeaks + 1 and speaks[newsSpeaks + 1].text
        == "Update: Wiki permission")
end)

step(2500, "the followed one is stopped", function()
    gitgud.agentInterrupt(wikiTab.session.name)
end)

step(1500, "the followed one stops: so does the cycle", function()
    wikiTab.bragiFollows = nil
    check("it stopped", wikiTab.session.turn == false)
    check("the cycle stopped", not voice.narrating())
end)

-- a followed conversation ended its turn with four
-- background tasks running, and each task's report got a turn of its own
-- (nobody sent it a message), each told as done news restating everything
-- with one count changed. Now: no done until the last task has ended;
-- each report is small news, folded into the next update in a few words,
-- never cutting in; never a sentence twice; one done at the end.
local suitesTab = nil
local suitesFrom = 0
local function suitesNews()
    local list = {}
    local speaks = called("speak")
    for i = suitesFrom + 1, #speaks do
        if speaks[i].text:find("Update: Suites", 1, true) == 1 then
            list[#list + 1] = speaks[i]
        end
    end
    return list
end
local function suitesUpdates()
    local list = {}
    local speaks = called("speak")
    for i = suitesFrom + 1, #speaks do
        if speaks[i].text:find("Now: Suites on ", 1, true) == 1 then
            list[#list + 1] = speaks[i]
        end
    end
    return list
end
local function suitesDoneRows()
    local n = 0
    for _, item in ipairs(masterTab.items) do
        if item.status and item.status.tab == suitesTab and item.status.what == "done" then
            n = n + 1
        end
    end
    return n
end
step(200, "a followed conversation runs four suites in the background", function()
    suitesFrom = #called("speak")
    suitesTab = agent.openTab({ title = "Suites" })
    suitesTab.bragiFollows = true
    agent.sendTo(suitesTab, "suites 4 2000")
end)

step(1800, "its turn ends with four tasks running: not done", function()
    check("its turn is over, its tasks run", suitesTab.session.turn == false
        and require("bragi.sidepanel").running(suitesTab) == 4)
    check("no done news", #suitesNews() == 0)
    check("no done row", suitesDoneRows() == 0)
end)

step(5000, "its tasks report, one by one: still not done", function()
    local running = require("bragi.sidepanel").running(suitesTab)
    check("some reported, some run", running > 0 and running < 4)
    check("no news for a report", #suitesNews() == 0)
    check("no done row", suitesDoneRows() == 0)
end, { full = true })

step(6000, "the last one reports: done, once", function()
    check("none run", require("bragi.sidepanel").running(suitesTab) == 0)
    local news = suitesNews()
    check("one done news", #news == 1 and news[1].text:find("done", 1, true) ~= nil
        and news[1].text:find("All 4 suites pass.", 1, true) ~= nil)
    check("one done row", suitesDoneRows() == 1)
end, { full = true })

step(4000, "the reports went to the updates, in a few words", function()
    check("still one done news", #suitesNews() == 1)
    local updates, folded, reports = suitesUpdates(), false, 0
    for _, u in ipairs(updates) do
        local _, n = u.text:gsub("suite%-%d passes", "")
        folded = folded or n >= 2
        reports = reports + n
        check("an update is only the reports: " .. u.text,
            not u.text:find("Running the suites", 1, true) and not u.text:find("done", 1, true))
    end
    check("the reports were told in updates", reports >= 2)
    check("several folded into one update", folded)
    -- Never the same sentence twice.
    local seen, again = {}, nil
    local speaks = called("speak")
    for i = suitesFrom + 1, #speaks do
        for _, s in ipairs(voice.guard.sentences(speaks[i].text)) do
            again = again or (seen[s] and s)
            seen[s] = true
        end
    end
    check("no sentence said twice", again == nil)
    suitesTab.bragiFollows = nil
end)

-- The repeat guard: a long line said again with one
-- count changed is a repeat; news keeps only its new sentences.
step(200, "news that repeats is dropped, sentence by sentence", function()
    local g = voice.guard
    g.noteSaid("The sidebars one is still finished but not looked at yet, with four background tasks running. "
        .. "Its latest reply says the bragi test suite passes, 54 of 54. "
        .. "I'd still wait for those four tasks before calling it done.")
    local again = "The sidebars one is still finished but not looked at yet, with four background tasks "
        .. "running. Its latest reply says the bragi-agent suite passes, 119 of 119. I'd still wait for "
        .. "those four tasks before calling it done."
    check("the same long line with one count changed repeats", g.repeats(again, true) ~= nil)
    check("so it isn't said at all", g.freshNews(again) == "")
    check("only the new sentence is kept", g.freshNews("I'd still wait for those four tasks before "
        .. "calling it done. The sidebars one found a bug in the wiki view.")
        == "The sidebars one found a bug in the wiki view.")
    check("a short line isn't taken for a part of a long one", g.repeats("The sidebars one is done.", true) == nil)
end)

step(200, "narration off, and a turn that says nothing", function()
    settings.set("bragi.narrate", false)
    narrated = #called("speak")
    emit("wake", { id = "n2", t = 47, t0 = 47 })
    emit("message", { id = "n2", text = "wait", endedBy = "closing", t0 = 47, t1 = 48 })
end)

step(5000, "nothing canned, ever", function()
    check("nothing narrated with narration off", agent.session().turn == true and not voice.narrating())
    check("nothing spoken at all while it works", #called("speak") == narrated)
    settings.set("bragi.narrate", true)
    agent.stop()
end)

step(1000, "a long reply", function()
    check("the turn was stopped", agent.session().turn == false)
    settings.set("bragi.summaryLength", "medium")
    emit("wake", { id = "m6", t = 50, t0 = 50 })
    emit("message", { id = "m6", text = "Here is the first point. " .. string.rep("More detail follows here. ", 25),
        endedBy = "closing", t0 = 50, t1 = 60 })
end)

step(4000, "the long reply was summarized before speaking", function()
    local speaks = called("speak")
    local spoken = speaks[#speaks]
    check("a medium summary is spoken", spoken ~= nil
        and spoken.text == "Summary: You said: Here is the first point. More.")
    settings.set("bragi.summaryLength", "short")
end)

step(200, "a summary that echoes the reply", function()
    emit("wake", { id = "w1", t = 62, t0 = 62 })
    emit("message", { id = "w1", text = "please say this word for word so the spoken summary is never the whole reply "
        .. "read out", endedBy = "closing", t0 = 62, t1 = 63 })
end)

step(2500, "asked again, strictly", function()
    local speaks = replies()
    check("the retold summary is spoken", speaks[#speaks].text == "Retold: You said: please")
    check("the echo is logged", logged(' summary-echo ') and logged('"echoed":true') and logged('"retried":true'))
    emit("wake", { id = "w2", t = 64, t0 = 64 })
    emit("message", { id = "w2", text = "please say this word for word always. Then it is cut to the first sentence "
        .. "or two. The rest of it stays on the screen for reading later, however long it happens to run.",
        endedBy = "closing", t0 = 64, t1 = 65 })
end)

step(2500, "echoed again: cut short", function()
    local speaks = replies()
    check("the reply cut to its first sentences", speaks[#speaks].text == "You said: please say this word for word "
        .. "always. Then it is cut to the first sentence or two. The rest is on screen.")
    check("logged", logged('"echoedAgain":true'))
end)

step(200, "a voice id set before the engine lists its voices", function()
    settings.set("bragi.voice", "voice-id-1")
    local speaks = called("speak")
    check("no voice id sent without a voices list", #speaks > 0 and speaks[#speaks].options.voice == nil)
    emit("speech.start", { id = "r9", sampleRate = 24000, provider = "tts-engine-2" })
    emit("ready", { version = 0, stt = { provider = "stt-engine-2", model = "m", device = "cpu" } })
end)

step(200, "the providers from ready and speech", function()
    check("speech output from the speech start", voice.providers().tts == "tts-engine-2")
    check("recognition from ready, in Settings' words", voice.providerLine("stt") == "stt-engine-2.")
    emit("wake", { id = "m7", t = 70, t0 = 70 })
    emit("message", { id = "m7", text = "say hello", endedBy = "closing", t0 = 70, t1 = 71 })
end)

step(2500, "a reply without a voices list", function()
    local speaks = called("speak")
    local spoken = speaks[#speaks]
    -- The chosen voice goes with it even before the engine's list is known
    -- (the engine checks it).
    check("spoken in the chosen voice", spoken ~= nil and spoken.text == "Summary: You said: say hello"
        and spoken.options ~= nil and spoken.options.voice == "voice-id-1")
    -- The note is for troubleshooting: only with Show
    -- what was heard.
    emit("speech.start", { id = "r10", sampleRate = 24000, provider = "tts-engine",
        fallback = "the voice model failed to load (HTTP 401)" })
end)

local function fallbackNotes()
    local notes = 0
    for _, item in ipairs(agent.items()) do
        if item.kind == "note" and item.text:find("Speech output fell back:", 1, true) then
            notes = notes + 1
        end
    end
    return notes
end

step(200, "no note by default", function()
    check("no fallback note", fallbackNotes() == 0)
    emit("speech.start", { id = "r10b", sampleRate = 24000, provider = "tts-engine-2" })
    settings.set("bragi.showHeard", true)
    emit("speech.start", { id = "r10c", sampleRate = 24000, provider = "tts-engine",
        fallback = "the voice model failed to load (HTTP 401)" })
    emit("speech.start", { id = "r11", sampleRate = 24000, provider = "tts-engine",
        fallback = "the voice model failed to load (HTTP 401)" })
end)

step(200, "the engine fell back", function()
    settings.set("bragi.showHeard", false)
    check("one note says why", fallbackNotes() == 1 and last("note").text:find("HTTP 401", 1, true) ~= nil)
    check("Settings says it too", voice.providerLine("tts"):find("HTTP 401", 1, true) ~= nil)
    emit("wake", { id = "m8", t = 80, t0 = 80 })
    emit("message", { id = "m8", text = "and again", endedBy = "closing", t0 = 80, t1 = 81 })
end)

step(2500, "no voice id after the fallback", function()
    local speaks = called("speak")
    local spoken = speaks[#speaks]
    check("still in the chosen voice", spoken ~= nil and spoken.text == "Summary: You said: and again"
        and spoken.options.voice == "voice-id-1")
    require("bragi.settings").open("appearance")
end)

--- The spoken updates slider's stops, as the row lays them out: the
-- cursor ("x,y") over stop `i` (from 1), and which stop (from 0) the thumb
-- is at. The thumb is 20 pixels wide.
local function updatesStop(s, i)
    local x, y, w = gitgud.getRect(s.widget(4, 6, "Slider"))
    local n = #s.sliderValues(s.UPDATE_SECONDS)
    return math.floor(x + 10 + (w - 20) * (i - 1) / (n - 1) + 0.5) .. "," .. math.floor(y + 20)
end

local function thumbAt(s)
    local x, _, w = gitgud.getRect(s.widget(4, 6, "Slider"))
    local tx = gitgud.getRect(s.widget(4, 6, "SliderThumb"))
    if not x or not tx then
        return -1
    end
    local n = #s.sliderValues(s.UPDATE_SECONDS)
    return math.floor((tx - x) / (w - 20) * (n - 1) + 0.5)
end

step(500, "the providers in Settings", function()
    shot("06-providers")
    check("a speaking speed choice", gitgud.getText(require("bragi.settings").widget(4, 4, "Title")) == "Speaking speed"
        and gitgud.getText(require("bragi.settings").widget(4, 4, "Choice")) == "1.15x")
    check("a show what was heard toggle", gitgud.getText(require("bragi.settings").widget(3, 7, "Title"))
        == "Show what was heard")
    check("a troubleshooting switch to record", gitgud.getText(require("bragi.settings").widget(6, 1, "Title"))
        == "Record what the engine hears" and gitgud.getProperty(require("bragi.settings").widget(6, 1, "Check"), "Selected") == "false")
    -- The follow-up window's seconds, next to the answer time.
    local followEdit = require("bragi.settings").widget(3, 11, "InputEdit")
    check("a follow-up time", gitgud.getText(require("bragi.settings").widget(3, 11, "Title"))
        == "Time to answer a question" and gitgud.getText(followEdit) == "8")
    gitgud.emit(followEdit .. ".changed", "15") -- arrives on the next drain
end)

step(200, "the follow-up time typed", function()
    check("it sets the follow-up window", settings.get("bragi.followUpSeconds", "") == "15"
        and voice.followUpSeconds() == 15)
    settings.set("bragi.followUpSeconds", "99")
    check("kept to 30", voice.followUpSeconds() == 30)
    settings.set("bragi.followUpSeconds", "")
    -- How often Bragi speaks its updates, under narration
    -- (as it happens by default, or 3 seconds to 2 minutes), on a slider:
    -- 0, then 1-second stops from 3 to 10, then 5 seconds. This run's own
    -- interval (3, set at the top) shows.
    local s = require("bragi.settings")
    check("a spoken updates row", gitgud.getText(s.widget(4, 6, "Title")) == "Spoken updates every"
        and gitgud.getText(s.widget(4, 6, "Value")) == "3 s" and s.updateSeconds() == 3)
    check("it says what it's for", (gitgud.getText(s.widget(4, 6, "Sub")) or ""):find("Time between updates", 1, true)
        ~= nil)
    local stops = s.sliderValues(s.UPDATE_SECONDS)
    check("its stops: 0, 3 to 10 by 1, then by 5 to 120 (" .. table.concat(stops, " ") .. ")", #stops == 31
        and stops[1] == 0 and stops[2] == 3 and stops[9] == 10 and stops[10] == 15 and stops[31] == 120)
    check("the thumb at 3", thumbAt(s) == 1)
    -- Pressing on the track moves the thumb there (arrives on the next drain).
    gitgud.emit(s.widget(4, 6, "Slider") .. ".dragStarted", updatesStop(s, 3))
end)

step(200, "pressed on the second stop", function()
    local s = require("bragi.settings")
    check("4 s, saved", settings.get("bragi.updateSeconds", "") == "4" and s.updateSeconds() == 4
        and gitgud.getText(s.widget(4, 6, "Value")) == "4 s")
    check("the thumb moved one stop", thumbAt(s) == 2)
    gitgud.emit(s.widget(4, 6, "Slider") .. ".dragging", updatesStop(s, 9))
end)

step(200, "dragged to 10", function()
    local s = require("bragi.settings")
    check("10 s", settings.get("bragi.updateSeconds", "") == "10" and gitgud.getText(s.widget(4, 6, "Value")) == "10 s")
    gitgud.emit(s.widget(4, 6, "Slider") .. ".dragging", updatesStop(s, 10))
end)

step(200, "one stop past 10", function()
    local s = require("bragi.settings")
    check("15 s: 5-second steps from 10", settings.get("bragi.updateSeconds", "") == "15"
        and gitgud.getText(s.widget(4, 6, "Value")) == "15 s" and thumbAt(s) == 9)
    local x, y = gitgud.getRect(s.widget(4, 6, "Slider"))
    gitgud.emit(s.widget(4, 6, "Slider") .. ".dragging", math.floor(x - 60) .. "," .. math.floor(y + 20))
end)

step(200, "dragged past the start", function()
    local s = require("bragi.settings")
    check("0: as it happens", settings.get("bragi.updateSeconds", "") == "0" and s.updateSeconds() == 0
        and thumbAt(s) == 0 and gitgud.getText(s.widget(4, 6, "Value")) == "As it happens")
    local x, y, w = gitgud.getRect(s.widget(4, 6, "Slider"))
    gitgud.emit(s.widget(4, 6, "Slider") .. ".dragging", math.floor(x + w + 60) .. "," .. math.floor(y + 20))
end)

step(200, "dragged past the end", function()
    local s = require("bragi.settings")
    check("120, the longest", settings.get("bragi.updateSeconds", "") == "120" and s.updateSeconds() == 120)
    check("shown as 2 min", gitgud.getText(s.widget(4, 6, "Value")) == "2 min")
    check("the thumb at the end", thumbAt(s) == 30)
    gitgud.emit(s.widget(4, 6, "Slider") .. ".dragEnded", "0,0")
    -- Set elsewhere (by voice) between two stops: kept as said, the thumb
    -- at the nearest stop.
    settings.set("bragi.updateSeconds", "33")
    s.rebuild("appearance")
    check("33 shows as 33 s", gitgud.getText(s.widget(4, 6, "Value")) == "33 s" and s.updateSeconds() == 33)
    check("its thumb at 35, the nearest stop", thumbAt(s) == 13)
    settings.set("bragi.updateSeconds", "abc")
    check("not a number is the default, as it happens", s.updateSeconds() == 0)
    settings.set("bragi.updateSeconds", 3) -- this run's, for the updates further on
    s.rebuild("appearance")
    check("back to 3", gitgud.getText(s.widget(4, 6, "Value")) == "3 s")
end)

-- The voice picker: the engine's voices, Preview, Use.
local picker = require("bragi.settings")
local function voiceWidget(i, part)
    return picker.widget(4, 8, "Voice" .. i .. part)
end
--- Scroll Settings to its end (the picker is below the fold), then click.
local function clickVoice(i, part)
    local x, y, w, h = gitgud.getRect("SettingsContent")
    gitgud.simulateScroll(x + w / 2, y + h / 2, -40)
    clickWidget(voiceWidget(i, part))
end
step(200, "the engine lists its voices", function()
    settings.set("bragi.voice", "")
    voice.backend.voices = function(onDone)
        calls[#calls + 1] = { name = "voices" }
        onDone({ default = "local:default", voices = {
            { id = "local:default", name = "Default", provider = "local" },
            { id = "local:baldr", name = "Baldr", provider = "local", description = "Deep and calm" },
            { id = "extra:baldr", name = "Baldr", provider = "extra", available = false },
            { id = "extra:other", name = "Other", provider = "extra", available = false,
              reason = "no model yet" },
        } })
    end
    voice.checkVoices(true)
end)

step(500, "the picker", function()
    check("the voices were asked", #called("voices") >= 1 and #voice.voices().list == 4)
    check("one row per voice", gitgud.getText(voiceWidget(2, "Name")) == "Baldr"
        and (gitgud.getText(voiceWidget(3, "Sub")) or ""):find("Not available now", 1, true) ~= nil
        and (gitgud.getText(voiceWidget(4, "Sub")) or ""):find("Extra. No model yet", 1, true) ~= nil)
    check("the default is in use", gitgud.getText(voiceWidget(1, "Use")) == "In use"
        and gitgud.getText(voiceWidget(2, "Use")) == "Use")
    settings.set("bragi.speechSpeed", "1.3")
    clickVoice(2, "Preview")
end)

step(300, "Preview speaks a sample with that voice", function()
    local speaks = called("speak")
    local spoken = speaks[#speaks]
    check("a preview with Baldr", spoken ~= nil and spoken.id:find("^preview") ~= nil
        and spoken.options ~= nil and spoken.options.voice == "local:baldr")
    check("at the speaking speed", spoken ~= nil and spoken.options.speed == 1.3)
    settings.set("bragi.speechSpeed", "1.15")
    shot("06b-voice-picker")
    clickVoice(3, "Use")
end)

step(300, "an unavailable voice can't be used", function()
    check("still the default", settings.get("bragi.voice", "") == "")
    clickVoice(2, "Use")
end)

step(300, "Use picks it", function()
    check("saved", settings.get("bragi.voice", "") == "local:baldr")
    check("shown in use", gitgud.getText(voiceWidget(2, "Use")) == "In use"
        and gitgud.getText(voiceWidget(1, "Use")) == "Use")
    clickVoice(2, "Name") -- scrolls down for the screenshot
    emit("wake", { id = "m9", t = 90, t0 = 90 })
    emit("message", { id = "m9", text = "with Baldr", endedBy = "closing", t0 = 90, t1 = 91, speakerScore = 0.42 })
end)

step(2500, "replies speak with the chosen voice", function()
    local speaks = replies()
    local spoken = speaks[#speaks]
    check("spoken with Baldr", spoken ~= nil and spoken.text == "Summary: You said: with Baldr"
        and spoken.options ~= nil and spoken.options.voice == "local:baldr")
    shot("06c-voice-chosen")
    check("the speaker score is logged", logged('"speakerScore":0.42'))
    voice.backend.voices = function(_, onError)
        onError("HTTP 404")
    end
    voice.checkVoices(true)
end)

step(300, "an engine with no voices list", function()
    check("the voice id field", gitgud.getText(picker.widget(4, 8, "Title")) == "Voice id")
    settings.set("bragi.voice", "")
end)

-- Microphone and speakers in Settings: pickers, the level meter, and a new
-- pick restarting the capture while listening.
local devices = require("bragi.devices")
local audioCalls = {}
devices.audio = {
    devices = function()
        return {
            inputs = { { id = "mic1", name = "Desk mic", default = true }, { id = "mic2", name = "Headset" } },
            outputs = { { id = "spk1", name = "Speakers", default = true } },
        }
    end,
    use = function(input, output)
        audioCalls[#audioCalls + 1] = { name = "use", input = input, output = output }
    end,
    test = function(on)
        audioCalls[#audioCalls + 1] = { name = "test", on = on }
        return true
    end,
}
local function lastAudio(name)
    for i = #audioCalls, 1, -1 do
        if audioCalls[i].name == name then
            return audioCalls[i]
        end
    end
end

step(300, "the devices card", function()
    local x, y, w, h = gitgud.getRect("SettingsContent")
    gitgud.simulateScroll(x + w / 2, y + h / 2, 80)
    picker.rebuild("appearance")
end)

step(300, "pickers and the meter", function()
    check("a microphone picker", gitgud.getText(picker.widget(2, 1, "Title")) == "Microphone")
    check("it shows the default", gitgud.getText(picker.widget(2, 1, "Choice")) == "System default")
    check("a speaker picker", gitgud.getText(picker.widget(2, 2, "Title")) == "Speakers")
    check("still listening", voice.state() ~= "off")
    clickWidget(picker.widget(2, 3, "Action"))
end)

step(300, "the meter runs", function()
    check("the meter opened the microphone", lastAudio("test").on == true and picker.meter().on)
    check("its button says Stop", gitgud.getText(picker.widget(2, 3, "Action")) == "Stop")
    gitgud.emit("audio.level", "0.5")
end)

step(200, "the bar follows the level", function()
    local _, _, trackW = gitgud.getRect(picker.widget(2, 3, "Track"))
    local _, _, fillW = gitgud.getRect(picker.widget(2, 3, "Fill"))
    check("the settings bar is about half", trackW and fillW and math.abs(fillW - trackW / 2) <= 2)
    shot("07-devices")
    calls = {}
    settings.set("bragi.micDevice", "mic2")
    app.publish("bragi.choices")
end)

step(300, "a new microphone", function()
    check("it goes to the audio layer", lastAudio("use").input == "mic2")
    check("its name shows", gitgud.getText(picker.widget(2, 1, "Choice")) == "Headset")
    check("the meter follows it", audioCalls[#audioCalls].name == "test" and audioCalls[#audioCalls].on == true)
    check("listening restarted with it", #called("stop") == 1 and #called("listen") == 1)
    check("the start logs the last capture", loggedLine("listen", { '"lastCapture":"echo cancelled, ' }))
    check("logged", logged('"input":"Headset"'))
    emit("ready", { version = 0, keywords = true })
    emit("mic", { state = "on", device = "Microphone (echo cancelled)",
        route = "mic: Headset; echo reference: Speakers (default); ducking opt-out: ok" })
end)

step(200, "the mic line names the device", function()
    check("listening again after the switch", voice.state() == "listening")
    local found = false
    for _, line in ipairs(voice.logLines()) do
        found = found or (line:find(" mic ", 1, true) and line:find('"input":"Headset"', 1, true)) ~= nil
    end
    check("mic on logs the microphone", found)
    check("mic on logs the route", logged("echo reference: Speakers (default); ducking opt-out: ok"))
    calls = {}
    app.publish("bragi.choices") -- nothing changed: no restart
end)

step(200, "the same pick again", function()
    check("no restart when nothing changed", #called("listen") == 0)
    settings.set("bragi.micDevice", "")
    app.publish("bragi.choices")
end)

step(300, "back to the default microphone", function()
    check("restarted once more", #called("listen") == 1)
    emit("ready", { version = 0, keywords = true })
end)

step(300, "back to the Agent view", function()
    shell.show("agent")
end)

step(200, "leaving Settings", function()
    check("the meter stopped", not picker.meter().on and lastAudio("test").on == false)
end)

-- Barge-in: talking while the agent works, or over a reply.
local function bargeLog(action)
    local n = 0
    for _, line in ipairs(voice.logLines()) do
        if line:find(" barge ", 1, true) and line:find('"action":"' .. action .. '"', 1, true) then
            n = n + 1
        end
    end
    return n
end

step(200, "a turn that runs until stopped", function()
    agent.send("wait")
end)

step(1200, "\"stop\" while it works", function()
    check("the turn runs", agent.session().turn == true)
    emit("wake", { id = "b1", t = 100, t0 = 100 })
    emit("message", { id = "b1", text = "please stop", endedBy = "closing", t0 = 100, t1 = 101 })
end)

step(3000, "stopped, nothing sent", function()
    check("classified as stop", bargeLog("stop") == 1)
    check("the turn stopped", agent.session().turn == false)
    check("nothing was sent", last("user").text == "wait")
    agent.send("wait")
end)

step(1200, "a correction while it works", function()
    check("the turn runs again", agent.session().turn == true)
    emit("wake", { id = "b2", t = 110, t0 = 110 })
    emit("message", { id = "b2", text = "use the other branch instead", endedBy = "closing", t0 = 110, t1 = 111 })
end)

step(3500, "steered: stopped, then sent", function()
    check("classified as steer", bargeLog("steer") == 1)
    check("the correction was sent", last("user").text == "use the other branch instead")
    local reply = last("assistant")
    check("and answered", reply ~= nil and reply.text == "You said: use the other branch instead")
    agent.send("wait")
end)

local notesBefore = 0
step(1200, "an extra detail while it works", function()
    check("the agent works", agent.session().turn == true)
    notesBefore = bargeLog("note")
    emit("wake", { id = "b3", t = 120, t0 = 120 })
    emit("message", { id = "b3", text = "also check the tests", endedBy = "closing", t0 = 120, t1 = 121 })
end)

step(3000, "a note waits for the turn", function()
    check("classified as note", bargeLog("note") == notesBefore + 1)
    check("the turn wasn't stopped", agent.session().turn == true)
    check("not sent yet", last("user").pending ~= nil)
    local waiting = last("waiting")
    check("the waiting row says when it goes", waiting ~= nil and waiting.title == "Sends when the agent is done")
    local speaks = called("speak")
    check("Bragi says it'll get to it next", speaks[#speaks].text == "I'll get to that next.")
    shot("07-note-waits")
    -- The user starts typing meanwhile.
    agent.setPrompt("half a thought")
    agent.stop()
end)

step(3000, "sent once the turn ended", function()
    check("the note was sent", last("user").text == "also check the tests" and last("user").pending == nil)
    local reply = last("assistant")
    check("and answered", reply ~= nil and reply.text == "You said: also check the tests")
    check("what the user was typing stays", prompt() == "half a thought")
    agent.setPrompt("")
    agent.send("wait")
end)

-- Typed while the agent works: the same classifier; a note waits.
step(1200, "a typed extra while it works", function()
    check("the turn runs", agent.session().turn == true)
    agent.setPrompt("also update the docs")
    agent.submit()
end)

step(3000, "the typed note waits", function()
    check("classified as a typed note", loggedLine("barge", { '"action":"note"', '"typed":true' }))
    check("the turn wasn't stopped", agent.session().turn == true)
    check("not sent yet", last("user").text == "also update the docs" and last("user").pending ~= nil)
    local speaks = called("speak")
    check("Bragi says it'll get to it next", speaks[#speaks].text == "I'll get to that next.")
    agent.stop()
end)

step(3000, "the typed note went after the turn", function()
    check("sent", last("user").pending == nil and last("assistant").text == "You said: also update the docs")
    agent.send("wait")
end)

step(1200, "a typed change of direction", function()
    check("the agent works", agent.session().turn == true)
    agent.setPrompt("do it in the other folder instead")
    agent.submit()
end)

step(3500, "steered", function()
    check("classified as a typed steer", loggedLine("barge", { '"action":"steer"', '"typed":true' }))
    local reply = last("assistant")
    check("the turn stopped and it was sent", agent.session().turn == false and reply ~= nil
        and reply.text == "You said: do it in the other folder instead")
end)

step(200, "\"stop\" over a reply", function()
    playing = replies()[1].id
    emit("playback", { state = "started", id = playing })
    emit("wake", { id = "b4", t = 130, t0 = 130 })
end)

step(200, "other words: the reply stops", function()
    emit("partial", { id = "b4", text = "Bragi stop", t = 130.5 })
    emit("message", { id = "b4", text = "Bragi stop", endedBy = "closing", t0 = 130, t1 = 131 })
end)

step(3000, "stopped speaking, nothing sent", function()
    check("classified as stop", bargeLog("stop") == 2)
    local stops = called("speakStop")
    check("all speech stopped", #stops >= 2 and stops[#stops].id == nil)
    check("nothing was sent", last("user").text == "do it in the other folder instead")
    emit("playback", { state = "stopped", id = playing })
    playing = nil
end)

-- The speaker: "other" only counts once your voice is enrolled.
step(200, "another speaker over a reply, not enrolled", function()
    playing = replies()[1].id
    emit("playback", { state = "started", id = playing })
    emit("wake", { id = "s1", t = 140, t0 = 140 })
end)

step(200, "the message, tagged other", function()
    emit("message", { id = "s1", text = "what about the docs", endedBy = "closing", t0 = 140, t1 = 141,
        speaker = "other" })
end)

step(3000, "taken: no voiceprint yet", function()
    check("not dropped as someone else", not logged('"why":"speaker"') and not logged(' not-you '))
    check("it was sent", last("user").text == "what about the docs")
    emit("playback", { state = "stopped", id = playing })
    emit("ready", { version = 0, speaker = { enrolled = true } })
    playing = replies()[1].id
    emit("playback", { state = "started", id = playing })
    emit("wake", { id = "s2", t = 150, t0 = 150 })
end)

step(200, "enrolled: another speaker", function()
    emit("message", { id = "s2", text = "what about the tests", endedBy = "closing", t0 = 150, t1 = 151,
        speaker = "other" })
end)

step(1000, "dropped as someone else", function()
    check("dropped once enrolled", logged('"why":"speaker"') and last("user").text == "what about the docs")
    emit("playback", { state = "stopped", id = playing })
    playing = nil
end)

-- Bragi says its own name: its echo must not cut it off, even when the
-- first words heard don't match; only your voice stops it.
local named, stopsBefore = nil, 0
-- A log line of this kind about message `id`.
local function loggedAbout(kind, id)
    for _, line in ipairs(voice.logLines()) do
        if line:find(" " .. kind .. " ", 1, true) and line:find('"id":"' .. id .. '"', 1, true) then
            return true
        end
    end
    return false
end
step(1000, "a reply that says the name", function()
    stopsBefore = #called("speakStop")
    named = voice.say("I'm Bragi, and the build on main is green.")
    check("it's spoken as written", named ~= nil and replies()[#replies()].text:find("Bragi", 1, true) ~= nil)
    playing = named
    emit("playback", { state = "started", id = named })
    emit("wake", { id = "n1", t = 160, t0 = 160 })
end)

step(200, "first words that don't match", function()
    emit("partial", { id = "n1", text = "brocky and the bill" })
end)

step(800, "not cut off by the first words", function()
    check("still speaking", #called("speakStop") == stopsBefore)
    check("no barge-in on the first words", not loggedAbout("barge-in", "n1"))
    emit("message", { id = "n1", text = "brocky and the bill on main is green", endedBy = "closing",
        t0 = 160, t1 = 162, speaker = "other" })
end)

step(1000, "its own voice is dropped", function()
    check("dropped as its own voice", loggedAbout("self-wake", "n1") and not loggedAbout("barge-in", "n1"))
    emit("playback", { state = "stopped", id = named })
    named = voice.say("Bragi here again.")
    playing = named
    emit("playback", { state = "started", id = named })
    emit("wake", { id = "n2", t = 170, t0 = 170 })
end)

step(200, "you interrupt it", function()
    emit("partial", { id = "n2", text = "stop" })
end)

step(800, "you, by speaker", function()
    emit("message", { id = "n2", text = "stop", endedBy = "closing", t0 = 170, t1 = 171, speaker = "user" })
end)

step(1000, "your voice stops it", function()
    check("a barge-in by you", loggedAbout("barge-in", "n2") and not loggedAbout("self-wake", "n2"))
    emit("playback", { state = "stopped", id = named })
    playing = nil
end)

-- Quick answers (E10): the filter's route sends a quick question to Haiku;
-- its answer is retold and spoken like a reply. The fake filter calls
-- "what time", "which branch", "readme", "todo", and "why does" quick.
local repliesBefore = 0
step(1700, "a spoken quick question", function() -- after the last reply's echo window (the app's clock)

    repliesBefore = #replies()
    emit("wake", { id = "q1", t = 160, t0 = 160 })
    emit("message", { id = "q1", text = "what time is it", endedBy = "closing", t0 = 160, t1 = 161 })
end, { clock = true })

step(2500, "answered by Haiku, and spoken", function()
    local reply = last("assistant")
    check("answered by Haiku", reply ~= nil and reply.tag == "Answered by Haiku"
        and reply.text:find("It's ", 1, true) == 1 and last("user").text == "what time is it")
    check("the agent wasn't asked", agent.session().turn == false)
    check("the route came from the filter", loggedLine("route", { '"id":"q1"', '"by":"filter"', '"route":"quick"' }))
    check("logged as spoken", loggedLine("quick", { '"id":"q1"', '"voice":true' }))
    local list = narrations()
    check("the opening line still came", list[#list].text == "Looking into: what time is it")
    local spoken = replies()
    check("its answer is retold and spoken", #spoken == repliesBefore + 1
        and spoken[#spoken].text:find("Summary: It's ", 1, true) == 1)
    check("timed", loggedLine("timing", { '"id":"q1"', '"stage":"answer"', '"quick":true' }))
    emit("wake", { id = "q2", t = 162, t0 = 162 })
    emit("message", { id = "q2", text = "tick off the todo", endedBy = "closing", t0 = 162, t1 = 163 })
end)

step(3000, "handed back, and said so", function()
    check("the write was denied", loggedLine("helper-tool", { '"tool":"Write"', '"allowed":false' }))
    local said = false
    for _, c in ipairs(called("speak")) do
        said = said or c.text == "Passing that to Opus."
    end
    check("Bragi says it's passing it on", said)
    local reply = last("assistant")
    check("the agent answered, with Haiku's answer as a note", reply ~= nil and reply.tag == nil
        and reply.text:find("You said: tick off the todo\n\nMeanwhile, Haiku answered:\nQ: what time is it", 1, true) == 1)
    agent.send("wait")
end)

step(1200, "a quick question while the agent works", function()
    check("the agent works", agent.session().turn == true)
    emit("wake", { id = "q3", t = 164, t0 = 164 })
    emit("message", { id = "q3", text = "which branch am I on", endedBy = "closing", t0 = 164, t1 = 165 })
end)

step(2500, "answered at once", function()
    local reply = last("assistant")
    check("answered by Haiku", reply ~= nil and reply.tag ~= nil and reply.text == "You're on `main`.")
    check("the agent still works", agent.session().turn == true)
    check("not held as a barge-in", not loggedLine("barge", { '"id":"q3"' }))
    local spoken = replies()
    check("spoken, as plain words", spoken[#spoken].text == "Summary: You're on main.")
    agent.stop()
end)

step(1500, "\"ask Opus\"", function()
    check("stopped", agent.session().turn == false)
    emit("wake", { id = "q4", t = 166, t0 = 166 })
    emit("message", { id = "q4", text = "ask Opus what time it is", endedBy = "closing", t0 = 166, t1 = 167 })
end)

step(2500, "goes to the agent", function()
    local reply = last("assistant")
    check("the agent answered", reply ~= nil and reply.tag == nil
        and reply.text:find("You said: ask Opus what time it is", 1, true) == 1)
    check("decided by the app", loggedLine("route", { '"id":"q4"', '"by":"app"', '"route":"main"' }))
    emit("wake", { id = "q6", t = 167, t0 = 167 })
    emit("message", { id = "q6", text = "hmm I wonder what time it is", endedBy = "closing", t0 = 167, t1 = 167.5 })
end)

step(2500, "a remark goes to the agent", function()
    local reply = last("assistant")
    check("the agent answered", reply ~= nil and reply.tag == nil and reply.text == "You said: hmm I wonder what time it is")
    check("logged why", loggedLine("route", { '"id":"q6"', '"why":"a remark, not a question"' }))
    settings.set("bragi.quickAnswers", false)
    emit("wake", { id = "q5", t = 168, t0 = 168 })
    emit("message", { id = "q5", text = "what time is it", endedBy = "closing", t0 = 168, t1 = 169 })
end)

step(2500, "quick answers off", function()
    local reply = last("assistant")
    check("the agent answered", reply ~= nil and reply.tag == nil and reply.text == "You said: what time is it")
    check("logged why", loggedLine("route", { '"id":"q5"', '"why":"quick answers are off"' }))
    settings.set("bragi.quickAnswers", true)
end)

-- Spoken approvals: a permission card is asked aloud; the next words
-- without the wake word answer it. The fake agent's "tool" turn asks to
-- run Bash `echo hi`, "tools" asks twice at once.
local function askedLines()
    local list = {}
    for _, c in ipairs(called("speak")) do
        if c.text:find("Can I use ", 1, true) == 1 then
            list[#list + 1] = c
        end
    end
    return list
end
local askedBefore, leftBefore, speaksBefore = 0, 0, 0
--- Was a line starting with `prefix` said since the last toolTurn?
local function saidSince(prefix)
    local list = called("speak")
    for i = speaksBefore + 1, #list do
        if list[i].text:find(prefix, 1, true) == 1 then
            return true
        end
    end
    return false
end
local function countSaid(line)
    local n = 0
    for _, c in ipairs(called("speak")) do
        n = n + (c.text == line and 1 or 0)
    end
    return n
end
--- Ask the fake agent for a tool; the question is said, then played.
local function toolTurn(id, t, body)
    askedBefore = #askedLines()
    speaksBefore = #called("speak")
    emit("wake", { id = id, t = t, t0 = t })
    emit("message", { id = id, text = body or "tool", endedBy = "closing", t0 = t, t1 = t + 0.5 })
end
local function questionPlayed()
    local q = askedLines()[#askedLines()]
    if q then
        emit("playback", { state = "started", id = q.id })
        emit("playback", { state = "stopped", id = q.id })
    end
    return q
end
local function clickCard(item, button)
    clickWidget(item.inner .. button)
end
--- Play the newest line starting with `prefix`; true when there was one.
local function playSaid(prefix)
    local list = called("speak")
    for i = #list, 1, -1 do
        if list[i].text:find(prefix, 1, true) == 1 then
            emit("playback", { state = "started", id = list[i].id })
            emit("playback", { state = "stopped", id = list[i].id })
            return true
        end
    end
    return false
end
local function anyNote(body)
    for _, item in ipairs(agent.items()) do
        if item.kind == "note" and item.text == body then
            return true
        end
    end
    return false
end

step(500, "a permission request while listening", function()
    emit("ready", { version = 0, speaker = { enrolled = true } })
    toolTurn("a1", 200)
end)

step(3000, "asked aloud", function()
    local card = last("permission")
    check("a permission card", card ~= nil and card.answer == nil and card.tool == "Bash")
    local q = askedLines()[askedBefore + 1]
    check("one short question from the narrator", q ~= nil and q.text == "Can I use Bash: echo hi?")
    check("logged as ask", loggedLine("ask", { '"tool":"Bash"', '"text":"Can I use Bash: echo hi?"' }))
    check("no window until it has been said", not status():find("Say yes or no", 1, true))
    questionPlayed()
end)

step(200, "the answer window opens", function()
    check("the window is open", voice.approving() and status():find("Say yes or no", 1, true) ~= nil)
    emit("ambient", { text = "Yeah, go ahead.", t0 = 201, t1 = 202, speaker = "user" })
end)

step(2000, "\"yeah go ahead\" allows", function()
    local card = last("permission")
    check("allowed", card.answer == "Allowed")
    check("marked as answered by voice", card.answerNote == "Allowed by voice: \u{201C}Yeah, go ahead.\u{201D}")
    check("logged as answer and decision", loggedLine("answer", { '"verdict":"allow"' })
        and loggedLine("decision", { '"decision":"allow"', '"by":"voice"', '"via":"ambient"' }))
    check("the tool ran", last("assistant").text == "Done")
    check("the window closed", not voice.approving())
    shot("08-allowed-by-voice")
    toolTurn("a2", 210)
end)

step(3000, "asked again", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("ambient", { text = "No, don't do that.", t0 = 211, t1 = 212, speaker = "user" })
end)

step(2000, "\"no don't\" denies", function()
    local card = last("permission")
    check("denied", card.answer == "Denied" and card.answerNote == "Denied by voice: \u{201C}No, don't do that.\u{201D}")
    check("the agent heard no", last("assistant").text == "Denied")
    leftBefore = countSaid("I'll leave that on screen.")
    toolTurn("a3", 220)
end)

step(3000, "an answer that isn't yes or no", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("ambient", { text = "What's for lunch today?", t0 = 221, t1 = 222, speaker = "user" })
end)

-- unclear, Bragi asks once more instead of going quiet.
step(2000, "unclear: asked once more, briefly", function()
    check("not answered", last("permission").answer == nil)
    check("asked again", saidSince("Sorry, yes or no?") and countSaid("I'll leave that on screen.") == leftBefore)
    check("logged as asked again", loggedLine("ask", { '"again":true', '"text":"Sorry, yes or no?"' }))
    check("the card is still asked", voice.approving())
    playSaid("Sorry, yes or no?")
    emit("ambient", { text = "What's for lunch today?", t0 = 222.5, t1 = 222.8, speaker = "user" })
end)

step(2000, "unclear again: the card stays", function()
    local card = last("permission")
    check("not answered", card.answer == nil)
    check("Bragi says it once", countSaid("I'll leave that on screen.") == leftBefore + 1)
    check("asked again only once", countSaid("Sorry, yes or no?") == 1)
    check("logged", loggedLine("decision", { '"decision":"left"', '"why":"unclear"' }))
    check("the window closed", not voice.approving())
    emit("ambient", { text = "Yeah, go ahead.", t0 = 223, t1 = 224, speaker = "user" })
end)

step(1500, "too late to answer by voice", function()
    check("still waiting for a click", last("permission").answer == nil)
    clickCard(last("permission"), "Allow")
end)

step(2000, "a click still works", function()
    local card = last("permission")
    check("allowed by the click", card.answer == "Allowed" and card.answerNote == nil
        and last("assistant").text == "Done")
    toolTurn("a4", 230)
end)

step(3000, "another speaker in the window", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("ambient", { text = "Yeah, go ahead.", t0 = 231, t1 = 232, speaker = "other" })
end)

step(1500, "only your voice answers", function()
    check("not taken from someone else", last("permission").answer == nil and voice.approving())
    check("logged as ignored", loggedLine("answer", { '"speaker":"other"', '"ignored":"not you"' }))
    clickCard(last("permission"), "Deny")
end)

step(2000, "a click during the window", function()
    check("denied by the click", last("permission").answer == "Denied" and last("assistant").text == "Denied")
    check("the window closed", not voice.approving())
    check("logged as a click", loggedLine("decision", { '"by":"click"' }))
    settings.set("bragi.approvalSeconds", "5")
    leftBefore = countSaid("I'll leave that on screen.")
    toolTurn("a5", 240)
end)

step(3000, "no answer at all", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
end)

step(5800, "the window runs out", function()
    check("the card stays", last("permission").answer == nil and not voice.approving())
    check("said once", countSaid("I'll leave that on screen.") == leftBefore + 1)
    check("logged", loggedLine("decision", { '"decision":"left"', '"why":"no answer"' }))
    settings.set("bragi.approvalSeconds", "")
    clickCard(last("permission"), "Allow")
end)

step(2000, "a wake-word answer", function()
    check("the clicked tool ran", last("assistant") ~= nil and last("assistant").text == "Done"
        and agent.session().turn == false)
    toolTurn("a6", 250)
end)

step(3000, "said with the name", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("wake", { id = "a6w", t = 251, t0 = 251 })
    emit("message", { id = "a6w", text = "Bragi, yeah go ahead", endedBy = "closing", t0 = 251, t1 = 252,
        speaker = "user" })
end)

step(2000, "a clear yes with the wake word answers it", function()
    check("allowed", last("permission").answer == "Allowed" and last("assistant").text == "Done")
    check("not sent as a message", last("user").text == "tool")
    check("logged via the wake word", loggedLine("decision", { '"via":"wake"' }))
    toolTurn("a7", 260, "tools")
end)

step(3000, "two requests at once", function()
    local q = askedLines()[askedBefore + 1]
    check("the first is asked first", q ~= nil and q.text == "Can I use Bash: git log?"
        and #askedLines() == askedBefore + 1)
    questionPlayed()
    emit("ambient", { text = "Sure.", t0 = 261, t1 = 262, speaker = "user" })
end)

step(2500, "then the second", function()
    local q = askedLines()[askedBefore + 2]
    check("the second is asked next", q ~= nil and q.text:find("Can I use Edit: ", 1, true) == 1)
    questionPlayed()
    emit("ambient", { text = "No.", t0 = 263, t1 = 264, speaker = "user" })
end)

step(2500, "both answered in order", function()
    check("one allowed, one denied", last("assistant").text == "Bash allow, Edit deny")
    settings.set("bragi.voiceApprovals", false)
    toolTurn("a8", 270)
end)

step(3000, "the setting off", function()
    check("not asked aloud", #askedLines() == askedBefore)
    check("the card waits", last("permission").answer == nil and not voice.approving())
    clickCard(last("permission"), "Allow")
    settings.set("bragi.voiceApprovals", true)
end)

step(1500, "answered by the click", function()
    check("allowed", last("permission").answer == "Allowed" and last("assistant").text == "Done")
end)

-- Answering by voice for real, a one-word "Yes." was
-- dropped as "not you" (too short to score), "Yes, but it should already
-- be dark." was taken as no, and "Hey Bragi, I said yes, go ahead" with a
-- card waiting stopped the turn and cancelled the card.
local function countNotes(body)
    local n = 0
    for _, item in ipairs(agent.items()) do
        n = n + ((item.kind == "note" and item.text == body) and 1 or 0)
    end
    return n
end
local stoppedBefore, cardsBefore = 0, 0

step(500, "a short answer, too short to score", function()
    toolTurn("a9", 280)
end)

step(3000, "said with no speaker known", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("ambient", { text = "Yes.", t0 = 281, t1 = 281.3, speaker = "unknown" })
end)

step(2000, "\"Yes.\" from an unknown speaker is theirs", function()
    local card = last("permission")
    check("allowed", card.answer == "Allowed" and card.answerNote == "Allowed by voice: \u{201C}Yes.\u{201D}")
    check("logged as their answer, not ignored", loggedLine("answer", { '"text":"Yes."', '"speaker":"unknown"',
        '"enrolled":true' }) and not loggedLine("answer", { '"text":"Yes."', '"ignored"' }))
    check("the tool ran", last("assistant").text == "Done")
    toolTurn("a10", 290)
end)

step(3000, "a maybe", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("ambient", { text = "Maybe.", t0 = 291, t1 = 291.4, speaker = "user" })
end)

step(2000, "\"maybe\" asks again", function()
    check("not answered", last("permission").answer == nil and voice.approving())
    check("asked once more", saidSince("Sorry, yes or no?"))
    playSaid("Sorry, yes or no?")
    stoppedBefore = countNotes("Stopped.")
    emit("ambient", { text = "Yes, but it should already be dark.", t0 = 292, t1 = 293, speaker = "user" })
end)

step(3500, "a yes with a remark allows, and the remark goes on", function()
    local card = last("permission")
    check("allowed", card.answer == "Allowed"
        and card.answerNote == "Allowed by voice: \u{201C}Yes, but it should already be dark.\u{201D}")
    check("logged with its note", loggedLine("decision", { '"decision":"allow"',
        '"note":"it should already be dark."' }))
    local remark = "About allowing Bash, I said: \u{201C}Yes, but it should already be dark.\u{201D}"
    check("their words went to the agent", last("user").text == remark)
    check("and it heard them", last("assistant").text == "You said: " .. remark)
    check("nothing was stopped", countNotes("Stopped.") == stoppedBefore)
    leftBefore = countSaid("I'll leave that on screen.")
    toolTurn("a11", 300)
end)

step(3000, "a card to leave on screen", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    emit("ambient", { text = "What's for lunch today?", t0 = 301, t1 = 302, speaker = "user" })
end)

step(2000, "still not an answer", function()
    check("asked once more", saidSince("Sorry, yes or no?"))
    playSaid("Sorry, yes or no?")
    emit("ambient", { text = "What's for lunch today?", t0 = 302.5, t1 = 302.8, speaker = "user" })
end)

step(2000, "left on screen; then the wake word and a yes", function()
    check("left on screen", last("permission").answer == nil and not voice.approving()
        and countSaid("I'll leave that on screen.") == leftBefore + 1)
    check("the turn waits on it", agent.session().turn == true)
    stoppedBefore = countNotes("Stopped.")
    emit("wake", { id = "a11w", t = 303, t0 = 303 })
    emit("message", { id = "a11w", text = "Hey Bragi, I said yes, go ahead.", endedBy = "closing", t0 = 303,
        t1 = 304, speaker = "user" })
end)

step(2500, "the waiting card is answered, the turn goes on", function()
    local card = last("permission")
    check("allowed", card.answer == "Allowed"
        and card.answerNote == "Allowed by voice: \u{201C}Hey Bragi, I said yes, go ahead.\u{201D}")
    check("taken up again for the message", loggedLine("ask", { '"why":"waiting"' }))
    check("logged via the wake word", loggedLine("decision", { '"decision":"allow"', '"via":"wake"',
        '"text":"Hey Bragi, I said yes, go ahead."' }))
    check("not stopped", countNotes("Stopped.") == stoppedBefore and last("assistant").text == "Done")
    check("not sent as a message", last("user").text == "tool")
    toolTurn("a12", 310)
end)

step(3000, "a change of direction while a card waits", function()
    check("the tool was asked about", #askedLines() > askedBefore)
    questionPlayed()
    cardsBefore = bargeLog("steer")
    emit("wake", { id = "a12w", t = 311, t0 = 311 })
    emit("message", { id = "a12w", text = "Bragi, do it in Lua instead", endedBy = "closing", t0 = 311,
        t1 = 312, speaker = "user" })
end)

step(4000, "it waits like a note; the card stays", function()
    local card = last("permission")
    check("the card still waits", card.answer == nil)
    check("not an answer to it", loggedLine("answer", { '"text":"Bragi, do it in Lua instead"',
        '"verdict":"unclear"' }))
    check("held as a note, not a steer", bargeLog("steer") == cardsBefore
        and loggedLine("barge", { '"action":"note"', '"held":"card"' }))
    check("the turn wasn't stopped", agent.session().turn == true and countNotes("Stopped.") == stoppedBefore)
    check("Bragi says it'll get to it next", saidSince("I'll get to that next."))
    clickCard(card, "Allow")
end)

step(3500, "sent once the card is answered and the turn is over", function()
    check("the tool ran", last("permission").answer == "Allowed")
    local user = last("user")
    check("then the message went", user ~= nil and user.text:find("do it in Lua instead", 1, true) ~= nil
        and user.pending == nil)
    check("and was answered", last("assistant").text:find("You said: ", 1, true) == 1)
    cardsBefore = count("permission")
    agent.send("settings get speechSpeed")
end)

step(3000, "Bragi's own settings tools need no card", function()
    check("no card", count("permission") == cardsBefore)
    check("the tool answered", (last("assistant").text or ""):find("speechSpeed", 1, true) ~= nil)
    check("no question asked aloud", not voice.approving())
end)

-- Spoken questions: Claude's multiple-choice questions are read out with
-- their options, numbered, in any permission mode; the next words answer
-- them through the choice classifier. The fake agent's "choose" asks
-- which colour (Red, Blue), "choose two" also which README sections
-- (multi-select); the fake classifier takes ordinals and labels, "maybe"
-- makes it unsure, "lunch" is no answer, anything else is the user's own words.
local COLOUR_LINE = "Which colour do you prefer? One: Red. Two: Blue. Or say your own."
--- The newest speak call starting with `prefix`; played when `play`.
local function spoken(prefix, play)
    local list = called("speak")
    for i = #list, 1, -1 do
        if list[i].text:find(prefix, 1, true) == 1 then
            if play then
                emit("playback", { state = "started", id = list[i].id })
                emit("playback", { state = "stopped", id = list[i].id })
            end
            return list[i]
        end
    end
    return nil
end
local spokenBefore = 0

step(500, "a question while listening, in auto mode", function()
    settings.set("bragi.mode", "auto")
    spokenBefore = #called("speak")
    toolTurn("c1", 300, "choose")
end)

step(3000, "read out with its options", function()
    local card = last("question")
    check("a question card", card ~= nil and card.answer == nil)
    local q = spoken("Which colour")
    check("the question and its options, numbered", q ~= nil and q.text == COLOUR_LINE)
    check("asked even in auto mode", #called("speak") > spokenBefore)
    check("logged as ask", loggedLine("ask", { '"tool":"AskUserQuestion"', '"text":"Which colour do you prefer?' }))
    spoken("Which colour", true)
end)

step(200, "the answer window", function()
    check("the window is open", voice.approving() and status():find("Say your answer", 1, true) ~= nil)
    emit("ambient", { text = "The second one.", t0 = 301, t1 = 302, speaker = "user" })
end)

step(2000, "\"the second one\" picks Blue", function()
    local card = last("question")
    check("answered", card.answer == "Blue")
    check("marked as answered by voice", card.answerNote == "Answered by voice: \u{201C}The second one.\u{201D}")
    check("Claude got it", last("assistant").text == "You chose: Blue")
    check("logged", loggedLine("answer", { '"choice":["Blue"]' })
        and loggedLine("decision", { '"decision":"answer"', '"answer":"Blue"', '"via":"ambient"' }))
    check("the window closed", not voice.approving())
    shot("09-question-by-voice")
    toolTurn("c2", 310, "choose")
end)

step(3000, "an unsure answer", function()
    check("the question was said", saidSince("Which colour"))
    spoken("Which colour", true)
    emit("ambient", { text = "Maybe the first one?", t0 = 311, t1 = 312, speaker = "user" })
end)

step(2000, "asked to confirm", function()
    local confirm = spoken("Did you mean")
    check("Bragi asks", confirm ~= nil and confirm.text == "Did you mean Red?")
    check("not answered yet", last("question").answer == nil)
    spoken("Did you mean", true)
end)

step(200, "the confirm window", function()
    check("says yes or no", status():find("Did you mean that? Say yes or no", 1, true) ~= nil)
    emit("ambient", { text = "Yeah.", t0 = 313, t1 = 314, speaker = "user" })
end)

step(2000, "a yes takes it", function()
    check("answered Red", last("question").answer == "Red" and last("assistant").text == "You chose: Red")
    toolTurn("c3", 320, "choose")
end)

step(3000, "an answer of their own", function()
    check("the question was said", saidSince("Which colour"))
    spoken("Which colour", true)
    emit("ambient", { text = "Green, actually.", t0 = 321, t1 = 322, speaker = "user" })
end)

step(2000, "their own words go back", function()
    check("answered in their words", last("question").answer == "Green, actually."
        and last("assistant").text == "You chose: Green, actually.")
    toolTurn("c4", 330, "choose two")
end)

step(3000, "two questions: asked one at a time", function()
    check("the first is asked first", saidSince("Which colour") and not saidSince("Which sections"))
    spoken("Which colour", true)
    emit("ambient", { text = "Two.", t0 = 331, t1 = 332, speaker = "user" })
end)

step(2500, "then the second", function()
    local q = spoken("Which sections")
    check("read with all three options", q ~= nil and q.text == "Which sections should the README have? "
        .. "One: Install. Two: Usage. Three: License. Pick any, or say your own.")
    spoken("Which sections", true)
    emit("ambient", { text = "Install and license.", t0 = 333, t1 = 334, speaker = "user" })
end)

step(2500, "both answered", function()
    check("several picked by voice", last("question").answer == "Install, License")
    check("Claude got both", last("assistant").text == "You chose: Blue; Install, License")
    leftBefore = countSaid("I'll leave that on screen.")
    toolTurn("c5", 340, "choose")
end)

step(3000, "not an answer", function()
    check("the question was said", saidSince("Which colour"))
    spoken("Which colour", true)
    emit("ambient", { text = "What's for lunch today?", t0 = 341, t1 = 342, speaker = "user" })
end)

step(2000, "asked once more", function()
    check("not answered, still asked", last("question").answer == nil and voice.approving())
    check("Bragi asks again, briefly", spoken("Sorry, what's your answer?") ~= nil
        and countSaid("I'll leave that on screen.") == leftBefore)
    spoken("Sorry, what's your answer?", true)
    emit("ambient", { text = "What's for lunch today?", t0 = 343, t1 = 344, speaker = "user" })
end)

step(2000, "the card stays", function()
    check("not answered", last("question").answer == nil and not voice.approving())
    check("Bragi says it once", countSaid("I'll leave that on screen.") == leftBefore + 1)
    clickWidget(last("question").inner .. "Option1")
end)

step(1500, "a click still answers it", function()
    check("answered by the click", last("question").answer == "Red" and last("assistant").text == "You chose: Red")
    settings.set("bragi.mode", "default")
end)

-- Narration that talks about skipping is never spoken
-- (Bragi said it would stay quiet because nothing was new). The fake
-- narrator answers "work quietly" with prose for the opening line and a
-- `say` about staying quiet for its steps.
local speaksBefore = 0
local function saidQuiet()
    local list = called("speak")
    for i = speaksBefore + 1, #list do
        if list[i].text:lower():find("quiet", 1, true) then
            return true
        end
    end
    return false
end
step(200, "a turn the narrator would talk about skipping", function()
    speaksBefore = #called("speak")
    emit("wake", { id = "q1", t = 400, t0 = 400 })
    emit("message", { id = "q1", text = "work quietly", endedBy = "closing", t0 = 400, t1 = 401 })
end)

step(2000, "prose instead of a say", function()
    check("the agent is working", agent.session().turn == true)
    check("prose isn't spoken", not saidQuiet())
    check("logged as dropped, not a say", loggedLine("narrate-dropped", { '"why":"not a say"', "stay quiet" }))
end)

step(7000, "a say about staying quiet", function()
    check("the turn is over", agent.session().turn == false)
    check("a line about narrating isn't spoken", not saidQuiet())
    check("logged as dropped, about narrating", loggedLine("narrate-dropped", { '"why":"about narrating"' }))
    local speaks = called("speak")
    check("the summary still comes", speaks[#speaks].text == "Summary: Worked through it.")
end)

-- The pre-pass never drops words: a fragment it leaves out comes back
-- ("My input and change the" vanished) where it was heard, and its
-- repairs stay ("lure" to "Lua"); never held (a closing "and that's it"
-- held a whole check-in in the prompt box).
step(200, "putting back what the filter left out", function()
    local restore = voice.guard.restoreWords
    local function back(heard, txt, changes)
        local out, words = restore(heard, { text = txt, changes = changes })
        return out, words
    end
    local out, words = back("set up the lure hooks", "Set up the Lua hooks.", { { heard = "lure", text = "Lua" } })
    check("nothing left out: the filter's text as it is", out == "Set up the Lua hooks." and words == nil)
    out, words = back("um set up the hooks", "Set up the hooks.")
    check("at the start (" .. out .. ")", out == "um Set up the hooks." and words == "um")
    out, words = back("set up the hooks please", "Set up the hooks.")
    check("at the end, before the full stop (" .. out .. ")", out == "Set up the hooks please." and words == "please")
    out, words = back("set up hmm the lure hooks", "Set up the Lua hooks.", { { heard = "lure", text = "Lua" } })
    check("in the middle, the repair kept (" .. out .. ")", out == "Set up hmm the Lua hooks." and words == "hmm")
    out = back("the uh the hooks", "The hooks.")
    check("a repeat and a filler (" .. out .. ")", out == "The uh the hooks.")
    out, words = back("two failures and the lure", "Two faiLuas and the Lua.", { { heard = "lure", text = "Lua" } })
    check("a change it didn't report goes back to what was heard, the reported one stays (" .. out .. ")",
        out == "Two failures and the Lua." and words == "failures")
end)

step(200, "a message with a fragment", function()
    emit("wake", { id = "f1", t = 410, t0 = 410 })
    emit("message", { id = "f1", text = "He has the ability to My input and change the The lure settings",
        endedBy = "closing", t0 = 410, t1 = 412 })
end)

step(2500, "the fragment isn't dropped", function()
    check("every word heard, put back where it was, and the repair kept (" .. tostring(last("user").text) .. ")",
        last("user").text == "He has the ability to My input and change The The Lua settings")
    check("not held in the prompt box", prompt() == "")
    check("logged", loggedLine("filter-dropped", { '"missing":"My input and change The"',
        '"sent":"He has the ability to My input and change The The Lua settings"' }))
    agent.setPrompt("")
    settings.set("bragi.showHeard", true)
    emit("wake", { id = "f2", t = 414, t0 = 414 })
    emit("message", { id = "f2", text = "open the zorp settings", endedBy = "closing", t0 = 414, t1 = 415 })
end)

local vocab = require("bragi.vocabulary")
step(2500, "words it can't place: sent as heard", function()
    check("sent as heard", last("user").text == "open the zorp settings" and last("user").pending == nil)
    check("never held in the prompt box", prompt() == "")
    check("the note says what's unclear", last("note").text:find("Sent as heard", 1, true) == 1
        and last("note").text:find("unclear: \u{201C}zorp\u{201D}", 1, true) ~= nil)
    settings.set("bragi.showHeard", false)
    emit("wake", { id = "f3", t = 416, t0 = 416 })
    emit("message", { id = "f3", text = "I said Zork, not zorp", endedBy = "closing", t0 = 416, t1 = 417 })
end)

step(2500, "a correction said with the unclear word", function()
    local c = vocab.corrections()[1]
    check("zorp means Zork", c ~= nil and c.heard == "zorp" and c.meant == "Zork" and c.how == "said")
    check("sent as heard too", last("user").text == "I said Zork, not zorp" and prompt() == "")
end)

-- Conversation-aware clean-up: "cloud desktop" is the Claude Desktop the
-- conversation talked about, never a project name.
step(200, "a conversation about Claude Desktop", function()
    agent.send("I moved here from Claude Desktop last week")
end)

step(2000, "the digest has its names", function()
    local digest = vocab.digest()
    local has = false
    for _, name in ipairs(digest.names) do
        has = has or name == "Claude Desktop"
    end
    check("Claude Desktop is a name in the conversation", has)
    check("the last exchange is in the digest", #digest.recent > 0
        and digest.recent[#digest.recent].you == "I moved here from Claude Desktop last week")
    emit("wake", { id = "v1", t = 420, t0 = 420 })
    emit("message", { id = "v1", text = "since I started using you instead of cloud desktop", endedBy = "closing",
        t0 = 420, t1 = 422 })
end)

step(2500, "cloud desktop is Claude Desktop", function()
    check("sent as Claude Desktop", last("user").text == "since I started using you instead of Claude Desktop")
    check("repaired from the conversation", loggedLine("filter", { '"id":"v1"', '"why":"said in the conversation"' }))
end)

-- A spoken correction is learned and used.
step(200, "I said X, not Y", function()
    emit("wake", { id = "v2", t = 424, t0 = 424 })
    emit("message", { id = "v2", text = "I said Bragi notes, not froggy notes", endedBy = "closing", t0 = 424,
        t1 = 426 })
end)

step(2500, "the correction is learned", function()
    local c = vocab.corrections()[1]
    check("froggy notes means Bragi notes", c ~= nil and c.heard == "froggy notes" and c.meant == "Bragi notes"
        and c.how == "said")
    check("a note says so", count("note") > 0 and notesText():find("Noted: \u{201C}froggy notes\u{201D} means", 1,
        true) ~= nil)
    emit("wake", { id = "v3", t = 428, t0 = 428 })
    emit("message", { id = "v3", text = "show the froggy notes", endedBy = "closing", t0 = 428, t1 = 429 })
end)

step(2500, "and used", function()
    check("sent corrected", last("user").text == "show the Bragi notes")
    local hot = vocab.hotwords()
    check("hotwords lead with what corrections meant", hot[1] == "Bragi notes" and hot[2] == "Zork")
    -- A changed vocabulary reaches the engine while listening (on the
    -- keep-warm tick; called here), once.
    local before = #called("config")
    voice.syncHotwords()
    local configs = called("config")
    local sent = configs[#configs]
    check("the new vocabulary goes in a config", #configs == before + 1 and sent.fields.vocabulary ~= nil
        and sent.fields.vocabulary[1] == "Bragi notes")
    check("logged", logIndex({ " hotwords ", '"sent":"config"', '"Bragi notes"' }) ~= nil)
    voice.syncHotwords()
    check("not again while it's the same", #called("config") == before + 1)
end)

-- The vocabulary: the products the user uses and the repository's words.
step(200, "the vocabulary", function()
    local words = {}
    for _, w in ipairs(vocab.words()) do
        words[w] = true
    end
    for _, w in ipairs(vocab.PRODUCTS) do
        check("the vocabulary has " .. w, words[w] == true)
    end
    check("the repository's name and branches", words["repo"] and words["main"] and words["feature/login"])
    check("its top-level folders", words["src"] and words["assets"])
    check("names from the conversation", words["Claude Desktop"] == true)
    require("bragi.settings").open("appearance")
end)

step(500, "corrections in Settings", function()
    local picker = require("bragi.settings")
    check("the newest correction is listed", gitgud.getText(picker.widget(5, 1, "Title"))
        == "\u{201C}froggy notes\u{201D} means \u{201C}Bragi notes\u{201D}")
    check("with Remove", gitgud.getText(picker.widget(5, 1, "Action")) == "Remove")
    local x, y, w, h = gitgud.getRect("SettingsContent")
    gitgud.simulateScroll(x + w / 2, y + h / 2, -40)
    shot("10-corrections")
    clickWidget(picker.widget(5, 1, "Action"))
end)

step(500, "removed", function()
    local list = vocab.corrections()
    check("forgotten", #list == 1 and list[1].heard == "zorp")
    check("the list shows the rest", gitgud.getText(require("bragi.settings").widget(5, 1, "Title"))
        == "\u{201C}zorp\u{201D} means \u{201C}Zork\u{201D}")
    shell.show("agent")
end)

-- Bragi's own settings are changed by the main session (its settings
-- tools), never the quick answerer.
step(200, "a settings request that looks quick, typed", function()
    agent.setPrompt("what time is it, and speak faster")
    agent.submit()
end)

step(2500, "typed: the main session", function()
    check("routed to the main session", loggedLine("route", { '"by":"router"', '"route":"main"',
        "Bragi's settings" }) and last("user").text == "what time is it, and speak faster")
    emit("wake", { id = "s1", t = 440, t0 = 440 })
    emit("message", { id = "s1", text = "which branch has the dark mode", endedBy = "closing", t0 = 440, t1 = 441 })
end)

step(2500, "spoken: the main session", function()
    check("spoken, routed to the main session", loggedLine("route", { '"id":"s1"', '"route":"main"', "Bragi's settings" })
        and last("user").text == "which branch has the dark mode" and last("assistant").tag == nil)
end)

-- Asking without the wake word: the main session is
-- told to ask its decisions with a question card, and a spoken reply
-- that ends with a question opens a short window where the next words,
-- without the wake word, are the next message.
step(200, "the main session's appended prompt", function()
    agent.send("args")
end)

step(1500, "it asks decisions with a card", function()
    local reply = last("assistant")
    check("--append-system-prompt goes to the main session", reply ~= nil
        and reply.text:find("--append-system-prompt", 1, true) ~= nil)
    check("with prompts/main-session.md", reply ~= nil and reply.text:find("AskUserQuestion", 1, true) ~= nil)
    emit("wake", { id = "w1", t = 450, t0 = 450 })
    emit("message", { id = "w1", text = "should I go ahead?", endedBy = "closing", t0 = 450, t1 = 451,
        speaker = "user" })
end)

local followed = nil -- the summary that asked
--- The follow-up log lines with all of `parts`.
local function followUpLines(parts)
    local n = 0
    for _, line in ipairs(voice.logLines()) do
        local all = line:find(" follow-up ", 1, true) ~= nil
        for _, part in ipairs(parts) do
            all = all and line:find(part, 1, true) ~= nil
        end
        n = n + (all and 1 or 0)
    end
    return n
end
local openedBefore = 0
step(2500, "a reply that ends with a question", function()
    check("the agent answered", last("assistant") ~= nil
        and last("assistant").text == "You said: should I go ahead?")
    followed = spoken("Summary: ")
    check("its summary asks", followed ~= nil and followed.text == "Summary: You said: should I go ahead?")
    check("no window before it's said", not voice.followingUp())
    -- The opening line asks too, but narration never opens one.
    spoken("Looking into: should I go ahead", true)
    check("not after narration", not voice.followingUp())
    openedBefore = followUpLines({ '"state":"open"' })
    spoken("Summary: ", true)
end)

step(200, "the window opens once it has played", function()
    check("open", voice.followingUp())
    check("the status says so", status() == "Listening for your answer")
    check("logged", followUpLines({ '"state":"open"', '"seconds":8' }) == openedBefore + 1)
    shot("11-follow-up")
    emit("ambient", { text = "Um.", t0 = 452, t1 = 452.5, speaker = "user" })
    emit("ambient", { text = "You said should I go ahead", t0 = 453, t1 = 454, speaker = "user" })
    emit("ambient", { text = "Yes, go ahead with it.", t0 = 455, t1 = 456, speaker = "other" })
end)

local usersBefore = 0
step(500, "filler, its echo, and someone else are ignored", function()
    check("still open", voice.followingUp())
    check("filler ignored", followUpLines({ '"ignored":"filler"' }) == 1)
    check("its echo ignored", followUpLines({ '"ignored":"echo"' }) == 1)
    check("someone else ignored", followUpLines({ '"ignored":"not you"' }) == 1)
    check("nothing sent", last("user").text == "should I go ahead?")
    usersBefore = count("user")
    -- Not scored ("unknown", too short to tell): theirs, as for a card.
    emit("ambient", { text = "Yes, go ahead with it.", t0 = 457, t1 = 458, speaker = "unknown" })
end)

step(2500, "the answer is the next message, without the wake word", function()
    check("sent like a spoken message", count("user") == usersBefore + 1
        and last("user").text == "Yes, go ahead with it.")
    check("no wake for it", not loggedLine("wake", { "follow-" }))
    check("heard and filtered", loggedLine("heard", { '"endedBy":"follow-up"' })
        and loggedLine("filter", { '"heard":"Yes, go ahead with it."' }))
    check("logged as the answer, then closed", followUpLines({ '"state":"answer"' }) == 1
        and followUpLines({ '"state":"closed"', '"why":"answer"' }) == 1)
    check("the agent answered it", last("assistant").text == "You said: Yes, go ahead with it.")
    openedBefore = followUpLines({ '"state":"open"' })
    spoken("Summary: ", true)
end)

step(200, "a reply that doesn't ask opens none", function()
    check("no window", not voice.followingUp() and followUpLines({ '"state":"open"' }) == openedBefore)
    check("the status is back to the wake word", status():find("to talk", 1, true) ~= nil)
    settings.set("bragi.followUpSeconds", "3")
end)

step(1700, "another question", function() -- after the last reply's echo window (the app's clock)
    emit("wake", { id = "w2", t = 460, t0 = 460 })
    emit("message", { id = "w2", text = "can you check it?", endedBy = "closing", t0 = 460, t1 = 461,
        speaker = "user" })
end, { clock = true })

step(2500, "asked again", function()
    check("its summary asks", spoken("Summary: ").text == "Summary: You said: can you check it?")
    spoken("Summary: ", true)
end)

step(200, "open again", function()
    check("open", voice.followingUp())
end)

step(3500, "no answer: it times out", function()
    check("closed", not voice.followingUp() and followUpLines({ '"why":"timeout"' }) == 1)
    check("the status is back to the wake word", status():find("to talk", 1, true) ~= nil)
    usersBefore = count("user")
    emit("ambient", { text = "Yes, go ahead with it.", t0 = 465, t1 = 466, speaker = "user" })
end)

step(2000, "too late: not sent", function()
    check("nothing sent", count("user") == usersBefore)
    settings.set("bragi.followUpSeconds", "")
    emit("wake", { id = "w3", t = 470, t0 = 470 })
    emit("message", { id = "w3", text = "shall I push it?", endedBy = "closing", t0 = 470, t1 = 471,
        speaker = "user" })
end)

step(2500, "asked once more", function()
    check("its summary was said", spoken("Summary: ") ~= nil
        and spoken("Summary: ").text == "Summary: You said: shall I push it?")
    -- A wake while it plays, dropped (its own voice): the window it will
    -- open isn't lost.
    emit("wake", { id = "w5", t = 471.5, t0 = 471.5 })
    emit("cancelled", { id = "w5" })
end)

step(200, "it finishes playing", function()
    spoken("Summary: ", true)
end)

step(200, "the wake word closes it", function()
    check("open", voice.followingUp())
    emit("wake", { id = "w4", t = 472, t0 = 472 })
end)

step(200, "closed by the wake", function()
    check("closed by the wake", not voice.followingUp() and followUpLines({ '"why":"wake"' }) == 1)
    emit("cancelled", { id = "w4" })
end)

-- An answer to what the master conversation asked aloud while another
-- conversation is shown: it goes to the master, and the
-- one shown gets a banner with the question and the answer, and Open.
local elsewhere = { shown = nil, master = nil, users = 0 }
local lootAsks = "Update: Investigating the loot tables done: The drop rates were off by ten. Should I fix the "
    .. "vendors too?"
step(200, "the master asks, another conversation shown", function()
    elsewhere.master = require("bragi.master").tab()
    elsewhere.shown = agent.current()
    check("another conversation is shown", elsewhere.master ~= nil and elsewhere.shown ~= elsewhere.master)
    elsewhere.users = count("user")
    app.publish("bragi.masterStatus", { tab = lootTab, what = "done" })
end)

step(2500, "asked aloud", function()
    local s = spoken("Update: Investigating the loot tables", true)
    check("the news asks", s ~= nil and s.text == lootAsks)
end)

step(200, "the answer window opens", function()
    check("open", voice.followingUp())
    emit("ambient", { text = "sure, go ahead with that", t0 = 490, t1 = 491, speaker = "user" })
end)

step(3000, "the answer went to the master", function()
    local m = elsewhere.master
    local mine, reply = nil, nil
    for _, item in ipairs(m.items) do
        if item.kind == "user" then
            mine = item
        elseif item.kind == "assistant" then
            reply = item
        end
    end
    check("sent to the master", mine ~= nil and mine.text == "sure, go ahead with that")
    check("the master answers it", reply ~= nil
        and reply.text:find("You said: sure, go ahead with that", 1, true) == 1)
    check("the news it answers rode along", m.quickNotes == nil)
    check("not into the conversation shown", agent.current() == elsewhere.shown and count("user") == elsewhere.users)
    local b = require("bragi.answerbanner").state()
    check("a banner with the question and the answer", b.shown and b.question == lootAsks
        and b.answer == "sure, go ahead with that" and b.target == m)
    check("its words", (gitgud.getText("AgentAnswerBannerAsked") or ""):find("Bragi asked: Update:", 1, true) == 1
        and gitgud.getText("AgentAnswerBannerAnswer") == "You answered: sure, go ahead with that")
    shot("11-answer-banner")
end)

step(300, "Open", function()
    clickWidget("AgentAnswerBannerOpen")
end)

step(500, "Open shows the master", function()
    check("the master is shown", agent.current() == elsewhere.master)
    check("the banner is gone", not require("bragi.answerbanner").state().shown
        and elsewhere.shown.answerBanner == nil)
    agent.showTab(elsewhere.shown)
end)

-- A spoken message goes only to the conversation it was said in
-- (said with another conversation shown, it reached the master
-- too): not to the master while its news is fresh (just told, asking, and
-- riding along with its next message), nor when the master is shown while
-- the message is checked.
local onlyShown = { tab = nil, masterUsers = 0, notes = 0 }
local function usersIn(tab, body)
    local n = 0
    for _, item in ipairs(tab.items) do
        if item.kind == "user" and (not body or item.text == body) then
            n = n + 1
        end
    end
    return n
end
local function lastReplyIn(tab)
    for i = #tab.items, 1, -1 do
        if tab.items[i].kind == "assistant" then
            return tab.items[i].text
        end
    end
    return nil
end
step(200, "master news, another conversation shown", function()
    -- A conversation of its own (the one above was closed when the master
    -- was shown).
    agent.newSession()
    onlyShown.tab = agent.current()
    check("another conversation is shown", onlyShown.tab ~= elsewhere.master and not onlyShown.tab.master)
    -- The same news was told above: as if a while had passed, so it isn't
    -- dropped as a repeat.
    voice.guard.saidLately = {}
    app.publish("bragi.masterStatus", { tab = lootTab, what = "done" })
end)

step(2500, "the news is told", function()
    check("told", spoken("Update: Investigating the loot tables", true) ~= nil)
end)

step(200, "a wake-word message while it's fresh", function()
    check("its answer window is open", voice.followingUp())
    onlyShown.masterUsers = usersIn(elsewhere.master)
    onlyShown.notes = #(elsewhere.master.quickNotes or {})
    check("the news waits for the master's next message", onlyShown.notes > 0)
    emit("wake", { id = "os1", t = 500, t0 = 500 })
    emit("message", { id = "os1", text = "go ahead and do all of these", endedBy = "send", t0 = 500, t1 = 501,
        speaker = "user" })
end)

step(3000, "it goes to the conversation shown only", function()
    check("sent there", usersIn(onlyShown.tab, "go ahead and do all of these") == 1
        and (lastReplyIn(onlyShown.tab) or ""):find("You said: go ahead and do all of these", 1, true) == 1)
    check("the master gets nothing", usersIn(elsewhere.master) == onlyShown.masterUsers
        and #(elsewhere.master.quickNotes or {}) == onlyShown.notes)
    check("logged as sent here", loggedLine("sent", { '"id":"os1"' })
        and not loggedLine("sent", { '"id":"os1"', '"to":' }))
    manualLookback = true
    lookbacksBefore = #called("lookback")
    emit("wake", { id = "os2", t = 510, t0 = 510 })
    emit("message", { id = "os2", text = "fix the vendors as well", endedBy = "send", t0 = 510, t1 = 511,
        speaker = "user" })
end)

step(300, "the master is shown while it's checked", function()
    local mine = last("user")
    check("waiting where it was said", agent.current() == onlyShown.tab and mine ~= nil
        and mine.text == "fix the vendors as well" and mine.pending ~= nil)
    agent.showTab(elsewhere.master)
    manualLookback = false
    local lookback = lookbackCall(1)
    if lookback then
        emit("lookback", { id = lookback.id, segments = {} })
    end
end)

step(3000, "it goes where it was said, never to the master", function()
    check("the master is shown", agent.current() == elsewhere.master)
    local listed = false
    for _, t in ipairs(agent.tabs()) do
        listed = listed or t == onlyShown.tab
    end
    check("the conversation it was said in stays open", listed)
    check("sent there once", usersIn(onlyShown.tab, "fix the vendors as well") == 1
        and (lastReplyIn(onlyShown.tab) or ""):find("You said: fix the vendors as well", 1, true) == 1)
    check("the master gets nothing", usersIn(elsewhere.master) == onlyShown.masterUsers
        and #(elsewhere.master.quickNotes or {}) == onlyShown.notes)
    agent.showTab(onlyShown.tab)
end)

step(200, "a send the engine has no message for", function()
    emit("wake", { id = "x1", t = 480, t0 = 480 })
    emit("partial", { id = "x1", text = "half a message", t = 480.5, speaker = "user" })
end)

step(200, "its words show", function()
    check("in the prompt box", prompt() == "half a message")
    emit("error", { code = "no-message", message = "no message to send" })
end)

step(200, "no-message clears them", function()
    check("the prompt box is cleared", prompt() == "" and not voice.hearing())
    check("listening again", voice.state() == "listening")
end)

step(200, "the mic turns listening off", function()
    local stops = #called("stop")
    clickWidget("AgentMicButton")
    check("stop asked", #called("stop") == stops + 1)
    check("off", voice.state() == "off" and status() == "Voice is off")
    check("the level meter hides", gitgud.getProperty("AgentLevel", "Visible") == "false")
end)

step(200, "on again: the old connection's events before ready", function()
    usersBefore = count("user")
    clickWidget("AgentMicButton")
    -- The engine's ids start again: the old connection's m1 isn't the new one's.
    emit("wake", { id = "m1", t = 3, t0 = 3 })
    emit("partial", { id = "m1", text = "old words", t = 3.5 })
    emit("message", { id = "m1", text = "old words from before", endedBy = "send", t0 = 3, t1 = 4 })
end)

step(1500, "ignored", function()
    check("nothing shown or sent", prompt() == "" and not voice.hearing() and count("user") == usersBefore)
    check("logged as stale", loggedLine("stale", { '"kind":"message"', '"id":"m1"' }))
    emit("ready", { version = 0 })
    emit("wake", { id = "m1", t = 1, t0 = 1 })
    emit("partial", { id = "m1", text = "a new thought", t = 1.5 })
end)

step(200, "the engine closing turns it off too", function()
    check("the new connection's words show", prompt() == "a new thought")
    emit("closed", { code = 1011, reason = "engine restarting" })
end)

step(300, "closed", function()
    check("off after the socket closed", voice.state() == "off")
    check("the words being heard are cleared", prompt() == "" and not voice.hearing())
    local note = last("note")
    check("it says why", note ~= nil and note.text:find("engine restarting", 1, true) ~= nil)
    shot("05-off")
end)

-- With the mic off, news is still picked back up in the master
-- conversation and spoken: the mic being off isn't a
-- reason to drop it. Something new to tell: the same news again would be
-- a repeat, never said.
local offSpeaks = 0
local wantLoot = "Update: Investigating the loot tables done: The vendor prices were off too. Should I fix the "
    .. "shops?"
step(200, "news with the mic off", function()
    check("the mic is off", voice.state() == "off")
    offSpeaks = #called("speak")
    lootTab.items[#lootTab.items].text = "The vendor prices were off too. Should I fix the shops?"
    app.publish("bragi.masterStatus", { tab = lootTab, what = "done" })
end)

step(2500, "written into the master and spoken", function()
    local m = require("bragi.master").tab()
    local reply = m and m.items[#m.items]
    check("a reply in the master conversation", reply ~= nil and reply.kind == "assistant" and reply.text == wantLoot)
    local speaks = called("speak")
    check("spoken all the same", #speaks == offSpeaks + 1 and speaks[#speaks].text == wantLoot)
    check("logged with the mic off", loggedLine("news", { '"mic":"off"', '"count":1' }))
    check("still off", voice.state() == "off")
end)

-- Mute: the speaker button beside the mic silences
-- Bragi's voice only; it's kept in settings and shows in Settings.
step(200, "the speaker button mutes", function()
    check("a speaker beside the mic", gitgud.getProperty("AgentMuteIcon", "IconImage") == "Bragi-Icons/Speaker")
    playing = "r-playing"
    offSpeaks = #called("speakStop")
    clickWidget("AgentMuteButton")
end)

step(300, "muted", function()
    check("kept in settings", settings.get("bragi.mute", false) == true and voice.muted())
    check("what was being said stops", #called("speakStop") == offSpeaks + 1)
    check("the button says so", gitgud.getProperty("AgentMuteIcon", "IconImage") == "Bragi-Icons/SpeakerOff"
        and gitgud.getProperty("AgentMuteButton", "TooltipText") == "Bragi is muted: click to unmute")
    playing = nil
    shot("06-muted")
    offSpeaks = #called("speak")
    app.publish("bragi.masterStatus", { tab = buildTab, what = "failed" })
end)

step(2500, "news while muted", function()
    local m = require("bragi.master").tab()
    local reply = m and m.items[#m.items]
    check("still written into the master", reply ~= nil and reply.kind == "assistant"
        and reply.text:find("Fix the build", 1, true) ~= nil)
    check("not spoken", #called("speak") == offSpeaks)
    check("speaking anything is skipped", voice.say("hello") == nil and #called("speak") == offSpeaks)
    require("bragi.settings").open("appearance")
end)

step(500, "Mute in Settings", function()
    local picker = require("bragi.settings")
    check("a Mute Bragi toggle under Speak replies", gitgud.getText(picker.widget(4, 2, "Title")) == "Mute Bragi"
        and gitgud.getText(picker.widget(4, 1, "Title")) == "Speak replies")
    check("it shows muted", gitgud.getProperty(picker.widget(4, 2, "Check"), "Selected") == "true")
    shot("07-mute-settings")
    gitgud.emit(picker.widget(4, 2, "Check") .. ".toggled", "0") -- arrives on the next drain
end)

step(300, "unmuted from Settings", function()
    check("not muted", settings.get("bragi.mute", true) == false and not voice.muted())
    check("the button follows", gitgud.getProperty("AgentMuteIcon", "IconImage") == "Bragi-Icons/Speaker")
    require("bragi.shell").show("agent")
end)

-- Typed text is yours (text they were typing vanished): a
-- wake, words heard, and a cancel (a false wake, Bragi hearing itself)
-- never replace or clear it, and Enter sends it as typed even while
-- something is being heard.
step(300, "typing while voice listens", function()
    emit("ready", { version = 0 })
    agent.setPrompt("my typed words")
    emit("wake", { id = "t1", t = 200, t0 = 200 })
end)

step(200, "a wake leaves typed text alone", function()
    check("typed text stays through a wake", prompt() == "my typed words")
    emit("partial", { id = "t1", text = "something heard", t = 200.5 })
end)

step(200, "words heard leave it alone", function()
    check("typed text stays while words are heard", prompt() == "my typed words")
    emit("cancelled", { id = "t1" })
end)

step(200, "a cancel leaves it alone", function()
    check("typed text stays through a cancel", prompt() == "my typed words")
    agent.setPrompt("")
    emit("wake", { id = "t2", t = 210, t0 = 210 })
end)

step(200, "heard into an empty box", function()
    check("it's being heard", voice.hearing())
    emit("partial", { id = "t2", text = "heard words", t = 210.5 })
end)

step(200, "the heard words show", function()
    check("an empty box shows what's heard", prompt() == "heard words")
    -- The user changes what was heard.
    agent.setPrompt("heard words, fixed by hand")
    emit("partial", { id = "t2", text = "heard words and more", t = 211 })
end)

step(200, "changed by hand", function()
    check("what you changed stays", prompt() == "heard words, fixed by hand")
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateKey("enter")
end)

step(2500, "Enter sent what was typed", function()
    local mine = last("user")
    check("the box's text was sent", mine ~= nil and (mine.text or ""):find("fixed by hand", 1, true) ~= nil)
    emit("cancelled", { id = "t2" })
    -- A growing message whose last decode lost words: the live text goes.
    emit("wake", { id = "g1", t = 220, t0 = 220 })
    emit("message", { id = "g1", text = "fix the", live = "fix the parser tests now", finalOk = true,
        endedBy = "button", t0 = 220, t1 = 223 })
end)

step(2500, "the live text stood in for a short final", function()
    check("the fallback is logged", logged('"final":"fix the"'))
    local mine = last("user")
    check("the live text was sent", mine ~= nil and mine.text == "fix the parser tests now")
    -- A last decode that failed: the live text goes too.
    emit("wake", { id = "g2", t = 230, t0 = 230 })
    emit("message", { id = "g2", text = "", live = "and run them twice", finalOk = false,
        endedBy = "button", t0 = 230, t1 = 232 })
end)

step(2500, "the live text stood in for a failed final", function()
    local mine = last("user")
    check("the live text was sent after a failed decode", mine ~= nil and mine.text == "and run them twice")
    -- A good last decode is taken as it is.
    emit("wake", { id = "g3", t = 240, t0 = 240 })
    emit("message", { id = "g3", text = "Fix the froggy tests.", live = "fix the doggy tests", finalOk = true,
        endedBy = "button", t0 = 240, t1 = 242 })
end)

step(2500, "a good final is taken", function()
    local mine = last("user")
    check("the last decode was sent", mine ~= nil and mine.text == "Fix the froggy tests.")
    -- Passes over the whole recording that heard less than its utterances
    -- did: the utterances' texts show, and go.
    emit("wake", { id = "g4", t = 250, t0 = 250 })
    emit("partial", { id = "g4", text = "", utterances = "run the parser tests twice", t = 251 })
end)

step(200, "the utterances show when a pass heard less", function()
    check("the utterances' text is shown", prompt() == "run the parser tests twice")
    emit("message", { id = "g4", text = "", live = "", utterances = "run the parser tests twice", finalOk = true,
        endedBy = "button", t0 = 250, t1 = 252 })
end)

step(2500, "the utterances stood in for an empty final", function()
    check("the fallback names the utterances", logged('"took":"utterances"'))
    local mine = last("user")
    check("the utterances' text was sent", mine ~= nil and mine.text == "run the parser tests twice")
end)

step(500, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
