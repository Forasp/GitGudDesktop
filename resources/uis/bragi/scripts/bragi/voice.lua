--- bragi/voice.lua: talking to Bragi.
--
-- The mic button turns listening on and off. Listening streams the
-- echo-cancelled microphone to the speech engine's `listen` channel
-- (docs/LUA_API.md, "Voice") with endBy "app": a pause never ends a
-- message by itself.
--
-- The engine runs inside the app (gitgud.voiceEngine), loaded only when
-- voice starts in this interface (never for the other interfaces). Its
-- models come from the welcome flow's voice step or Settings, on the
-- user's OK (bragi/voicemodels.lua); until they're installed, or in a
-- build without the engine, voice.available() is false and the mic button
-- says why (voice.unavailableText()). Spoken replies use the system's
-- voices for now.
--
--   off -> connecting -> listening (for the wake word)
--       -> hearing (a message: its text shows live in the prompt box)
--       -> listening again, while the message goes through the filter
--
-- A message ends with the closing phrase, Send, or when the user is logically
-- done. With the turn-taking model (bragi/decider.lua; the engine says it
-- has it in `ready`), the model is asked as the silence after your words
-- grows, and ends the message (`send` reason "done") once it's sure.
-- Without it, after each pause a Haiku helper judges the text so far, and
-- when it says complete, Bragi waits bragi.endWaitSeconds (2 to 10) and
-- ends it. Anything heard in that wait cancels it. Speech that starts
-- right after the model ended a message carries it on, without the wake
-- word ("Carrying on after a pause").
--
-- Every heard message goes through the pre-pass filter
-- (prompts/heard-text.md) on its own helper before anything else sees it.
-- The repaired text goes to the agent; what was heard and changed shows
-- under it only with bragi.showHeard (for troubleshooting; the log always
-- has it). Nothing heard is ever held in the prompt box:
-- a low-confidence message, words the filter couldn't place, or a filter
-- that can't run, and the message goes as heard (with a note saying what's
-- unclear only with bragi.showHeard). Words the filter left out without
-- saying are put back where they were heard, its repairs kept
-- (guard.restoreWords). When the filter asks for context,
-- the lookback is fetched (CONTEXT_SOME tokens, then CONTEXT_MORE) and
-- it's asked again.
--
-- Listening also starts the conversation's own session (agent.warm), so a
-- spoken message doesn't wait for Claude Code's start-up.
--
-- Helpers: lean Haiku 5.5 sessions (bragi/helpers.lua),
-- started and pinged when listening starts, and while listening, one idle
-- for KEEP_WARM_MS gets another ping. Each job has its own: the filter, the "are you
-- done" judge, the narrator, the summarizer, the barge-in classifier, and
-- the approval classifier, so none waits behind another. A judge call made stale by newer speech is
-- dropped, never waited on. Each call's time is logged ("helper").
--
-- Quick answers: the filter also gives a route. A
-- message it calls `quick` (answerable by reading) goes to bragi/quick.lua's
-- Haiku helper instead of the agent, even while the agent works; one that
-- helper hands back, or says "ask Opus" or "think hard", goes to the agent
-- as before. A spoken quick answer is retold and spoken like any reply.
-- One it calls `recap` (how the conversations Bragi follows are doing, in
-- any words) is told by bragi/recap.lua and spoken as it is ("Recaps").
--
-- The moment a message ends, the narrator (prompts/narration.md) makes an
-- opening line from the heard text ("Sure, checking the time"), side by
-- side with the filter, and it's spoken at once. Not for a message that
-- talks over a reply or the agent's work, nor once it's dropped.
-- While the agent works on a spoken message, or any conversation Bragi
-- manages works (its own, and those it follows), the narrator says what's
-- going on in short spoken updates ("Spoken updates", below; a message
-- without an opening line starts with one from the request): every step
-- ("bragi.step") goes into bragi/updates.lua, and what's new across all of
-- them becomes one line ("I'm searching the code for the parser", "The
-- wiki one is reading the theme code"): as it happens (bragi.updateSeconds
-- 0, the default), or every bragi.updateSeconds after the last line
-- finished playing. As it happens, a line follows on from the one playing,
-- and one not yet playing when something newer comes is made again with
-- both. None while you talk, and only when there's something new: no "still
-- working" filler (silence is fine), and never a line
-- that repeats one said lately, for this message or the ones just before
-- it (guard.repeats). Once the answer text streams, no new
-- snippet is made: one being made is dropped, one said already plays
-- (the answer's first words often come right after it), and the summary
-- follows (the engine plays says in order). A tool step after the text resumes narration.
-- News (done, failed, waiting on you) cuts in at once. bragi.narrate
-- turns it off.
--
-- A typed message is told like a spoken one: its work
-- narrated and its reply retold aloud, with the mic off too (when the speech
-- engine is there), unless Bragi is muted. Only the conversation on screen
-- is told ("Whose work is told", below).
--
-- Context: what the filter recovers from the lookback
-- (`context`) goes to the agent, or the quick answerer, with the message,
-- as context (agent.withContext: never shown as their words), noted only
-- with bragi.showHeard. A message about a long stretch ("did you get all
-- that?"), context cut off at its start, or an empty lookback fetches
-- CONTEXT_MORE before sending.
-- A short message (under HEARD.SHORT_WORDS words; "did
-- you get all that" sometimes went without enough) always fetches CONTEXT_SOME
-- before the filter (CONTEXT_MORE about a long stretch), and the lookback
-- goes with it as heard, whatever the filter thinks it refers to: without
-- the message's own words or Bragi's voice. Longer messages get context
-- only when the filter or the rules above ask.
--
-- Speech heard while a reply plays is the user's: the echo canceller keeps
-- the reply out of the microphone, so nothing is second-guessed as Bragi
-- hearing itself (an answer in the follow-up window that's mostly the
-- reply or what was just sent still is). Message events from a connection
-- that's gone (before the new one's `ready`) are ignored: the engine's ids
-- (m1, m2...) start again on each.
--
-- New messages don't interrupt work by default: typed
-- ones too go through the barge-in classifier while a turn runs
-- (voice.whileWorking); only a clear stop or steer interrupts, a note
-- waits, and Bragi says "I'll get to that next."
--
-- Permission cards are asked aloud and answered by voice ("Spoken
-- approvals", below), and so are Claude's multiple-choice questions
-- ("Spoken questions"). A spoken reply that ends with a question opens a
-- short window after it plays where the next words, without the wake
-- word, are the next message ("Follow-up answers").
--
-- The reply to a spoken message is always retold for speaking
-- (prompts/spoken-reply.md, bragi.summaryLength "short" or "medium") and
-- spoken through `speak` while bragi.speak is on; the full text stays on
-- screen. A long one is told a block at a time as it streams, and one
-- asked to be heard in full is read out ("Telling a long reply as it's
-- written"). A summary that says the reply again (echoes) is asked for once
-- more, strictly; if that echoes too, or the summarizer fails, the reply is
-- cut to its first sentence or two. Every `say` carries bragi.speechSpeed
-- as `speed`.
-- Saying the wake word while anything plays stops it.
--
-- The engine says who recognises and who speaks (its providers).
-- voice.providers() has what's in use, from the health check, `ready`, and
-- speech `start`, and "bragi.voiceProviders" is published when it changes.
-- When the engine fell back from one provider to another, a note says
-- why, once.
--
-- A spoken message shows in the transcript the moment it ends, with a
-- waiting row, before the filter has checked it (agent.voicePending).
-- Nothing canned is ever spoken. The log times each
-- message from its end ("timing" lines): shown, openingAsked, opening (the
-- opening line ready), filtered, started (sent to the agent), firstSound
-- (the first sound for it), firstEvent (the turn's first event), narration
-- (the first snippet in the turn), answer (the turn's result), summary (the
-- spoken summary ready), sound (its first sound); each snippet is a
-- "narrate" line.
--
-- A wake while a reply plays stops it at once (barge-in): the message that
-- follows goes on as any other. Whether the microphone is echo cancelled shows in
-- Settings (voice.micLine, from the "voice.mic" event), now or the last
-- time it was on: the capture and its route are kept in bragi/voice-mic.json in
-- the config folder, and every start logs the last one (`listen`).
--
-- Barge-in: a message that cut a reply short, or came while the agent is
-- still working, goes through a third Haiku session (prompts/barge-in.md)
-- after the filter, with the reply being spoken: stop (stop the turn,
-- send nothing), steer (stop the turn, then send it), or note (send it
-- once the turn is over). When the classifier fails it's a note.
--
-- Every heard text, filter answer, and timing goes to bragi/voice-log.txt in
-- the config folder, newest last (the last LOG_LINES lines). So does what
-- the mic heard, to tell "the engine thought you were silent" from "your
-- voice was quiet": each `vad` (speech started or stopped, at the engine's
-- `t`) and, every LEVEL_LINE_SECONDS while listening, a `level` line with
-- each second's RMS and loudest 20 ms in dBFS, from `t` on (the same times).
--
-- UI tests replace voice.backend (the gitgud.voice* calls) and emit the
-- voice.* events themselves; the helpers run bragi.claudeProgram.
--
-- Public API: voice.toggle(), voice.stop(), voice.state(), voice.hearing(),
-- voice.sendNow(), voice.filter(heard), voice.speakable(text), voice.logLines(),
-- voice.narrating(), voice.speechSpeed(), voice.whileWorking(body, opts),
-- voice.approving(), voice.approvalSeconds(), voice.followingUp(), voice.followUpSeconds(),
-- voice.endWait(), voice.tuning(), voice.providers(), voice.checkProviders(),
-- voice.providerLine(direction), voice.micLine(), voice.mentionsWakeWord(text), voice.say(text),
-- voice.voices(), voice.checkVoices(force), voice.chosenVoice(), voice.preview(id),
-- voice.syncHotwords(), voice.recordingChanged(), voice.unavailableText(), voice.noticeCrash(engine), voice.clearCrash(),
-- voice.muted(), voice.setMuted(on, opts), voice.speaks()

local agent = require("bragi.agent")
local app = require("core.app")
local devices = require("bragi.devices")
local helpers = require("bragi.helpers")
local quick = require("bragi.quick")
local repo = require("core.repo")
local settings = require("core.settings")
local text = require("core.text")
local updates = require("bragi.updates")
local vocab = require("bragi.vocabulary")
-- Made with the other helpers, so a hot-reload takes its session up.
require("bragi.recap")

local voice = { name = "bragi.voice" }

--- The speech engine, through the bindings. Tests swap these. health and
-- voices: the engine's providers and its voices list, onDone(table) or
-- onError(message).
voice.backend = {
    -- The engine is in this build, its models are installed, and it hasn't
    -- stopped after an internal error (bragi/voicemodels.lua).
    available = function()
        local info = gitgud.voiceInfo()
        if not (info ~= nil and info.available == true) then
            return false
        end
        local models = require("bragi.voicemodels")
        return not models.engine().faulted and models.installed()
    end,
    listen = function(options)
        -- Where the models are, each time (they may have been repaired).
        require("bragi.voicemodels").configure()
        return gitgud.voiceListen(options)
    end,
    health = function(onDone)
        local models = require("bragi.voicemodels")
        local test = models.engine().test
        local turbo = models.turboReady() and #models.voices() > 0
        local chosen = settings.get("bragi.voice", "")
        local tts = voice.PROVIDER_NAMES.windows
        if turbo and (chosen == "" or chosen:find("^turbo:")) then
            tts = voice.PROVIDER_NAMES[models.turboOnGpu() and "turbo" or "turbo-cpu"]
        end
        onDone({ sttProvider = test and "The test engine" or voice.PROVIDER_NAMES.parakeet,
            ttsProvider = test and "The test engine" or tts })
    end,
    -- The voices made from recordings (with Baldr's model) first, then the
    -- system's; the default is the first made voice, else the system's first.
    voices = function(onDone, onError)
        local models = require("bragi.voicemodels")
        local out = {}
        if models.turboReady() then
            for _, v in ipairs(models.voices()) do
                out[#out + 1] = { id = v.id, name = v.name, provider = "Made voice",
                    description = voice.PROVIDER_NAMES[models.turboOnGpu() and "turbo" or "turbo-cpu"] }
            end
        end
        local list, err = gitgud.voiceVoices()
        if not list and #out == 0 then
            onError(err)
            return
        end
        for _, v in ipairs(list or {}) do
            out[#out + 1] = { id = v.id, name = v.name, provider = "Windows",
                description = v.language ~= "" and ("Language " .. v.language) or nil }
        end
        onDone({ voices = out, default = out[1] and out[1].id or nil })
    end,
    record = function(path)
        return gitgud.voiceRecord(path)
    end,
    stop = function()
        gitgud.voiceStop()
    end,
    send = function(reason)
        return gitgud.voiceSend(reason)
    end,
    lookback = function(id, tokens)
        return gitgud.voiceLookback(id, tokens)
    end,
    decide = function(request)
        return gitgud.voiceDecide(request)
    end,
    speak = function(id, body, options)
        -- With the mic off nothing has told the engine where its models
        -- are yet (news is spoken then too).
        local models = require("bragi.voicemodels")
        if not models.engine().configured then
            models.configure()
        end
        return gitgud.voiceSpeak(id, body, options)
    end,
    speakPrepare = function()
        return gitgud.voiceSpeakPrepare()
    end,
    speakStop = function(id)
        gitgud.voiceSpeakStop(id)
    end,
    cancel = function()
        return gitgud.voiceCancel()
    end,
    playing = function()
        local info = gitgud.voiceInfo()
        return info and info.playing ~= "" and info.playing or nil
    end,
    listening = function()
        local info = gitgud.voiceInfo()
        return info ~= nil and info.listening == true
    end,
    config = function(fields)
        return gitgud.voiceConfig(fields)
    end,
    train = function(state)
        return gitgud.voiceTrain(state)
    end,
    enroll = function(state)
        return gitgud.voiceEnroll(state)
    end,
}

-- The engine's provider names (`ready.stt.provider`, `start.provider`) in words.
voice.PROVIDER_NAMES = {
    parakeet = "Speech recognition, on this computer",
    turbo = "Baldr's voice model, on the GPU",
    ["turbo-cpu"] = "Baldr's voice model, on the processor (slower)",
    windows = "Windows voices, on this computer",
}

-- What the mic button says while this build has no speech engine.
voice.UNAVAILABLE = "Voice isn't part of this build. Type to Bragi for now."

--- Why voice can't start now (the mic button's note).
function voice.unavailableText()
    local models = require("bragi.voicemodels")
    if not models.engineInstalled() then
        return voice.UNAVAILABLE
    end
    local engine = models.engine()
    if engine.faulted then
        return models.faultText(engine)
    end
    if models.installing() then
        return (models.updating() and "Updating the speech models for this version. "
            or "Installing the speech models. ") .. models.progressText()
    end
    local s = models.state()
    if s.phase == "failed" and s.group == "listen" and not models.installed() then
        return "The speech models didn't " .. (s.update and "update" or "install") .. ": " .. tostring(s.error)
            .. ". Settings, Appearance and voice, Voice models."
    end
    if not models.installed() then
        return "Voice needs its models first: about " .. models.size(models.downloadBytes(models.missing()))
            .. " to download. Settings, Appearance and voice, Voice models."
    end
    return voice.UNAVAILABLE
end

local LOG_FILE = "bragi/voice-log.txt"
local LOG_LINES = 400
-- The lookback and echoes (one table: this file is near Lua's 200 locals).
local HEARD = {
    CONTEXT_SOME = 1000,      -- tokens of lookback first
    CONTEXT_MORE = 5000,      -- as far back as it goes
    SHORT_WORDS = 25,         -- a message with fewer words always gets the lookback
    LOOKBACK_WAIT_MS = 5000,  -- a lookback not answered by then: the filter goes on without it
    ECHO_MIN_WORDS = 4,       -- fewer heard words ("yes") are never taken as an echo of a whole text
    -- A growing message's last decode, against its live text: a final
    -- decode that failed, or kept fewer words than this share of the live
    -- text's, lost words, so the live text is taken (words are never dropped).
    FINAL_MIN_WORDS = 0.8,
}
local LOOKBACK_TOKENS = HEARD.CONTEXT_MORE -- what the engine keeps for a lookback (listen hello)
local SPOKEN_MAX = 400      -- characters voice.speakable keeps
local SPOKEN_CUT = 160      -- characters kept when the summarizer fails or keeps echoing
local ECHO_REPLY_WORDS = 15 -- a reply shorter than this may be said nearly as it is
local ECHO_SUMMARY_WORDS = 10
local ECHO_TRIPLES = 0.6    -- of a summary's word triples found in the reply: said again, not retold
local SPEED_DEFAULT = 1.15  -- bragi.speechSpeed when unset (1 is the voice's normal pace)
local SPEED_MIN, SPEED_MAX = 0.8, 1.5
local LEVEL_BARS = 9
local LEVEL_MS = 110
local LEVEL_LINE_SECONDS = 10 -- seconds of mic level per log line

local FILTER_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object with `message`, `context`,
`vocabulary` (an array), and usually `conversation` (`{recent: [{you,
agent}], names: [...]}`) and `corrections` (an array of `{heard, meant}`).
Answer each with exactly one JSON object with the fields listed under "You
return", and nothing else: no prose, no code fences, no tools. `changes` is
an array of `{heard, text, why}`, `unclear` an array of `{heard, why}` (with
`maybe` when you had a second reading), `learned` an array of `{heard,
meant}`.]]

local BARGE_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object with `spoken`, `said`, and
`running`. Answer each with exactly one JSON object as described under
"You return", and nothing else: no prose, no code fences, no tools.]]

local SUMMARY_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object: `{"reply": "...", "length":
"short" | "medium"}`, often with `said`, and for a part of a long reply
`part`, `told`, `speaking`, and `replacing`. Answer with the words to say only, as plain text:
no JSON, no quotes, no Markdown, no tools. When it also has `"strict":
true`, your last answer was the reply again, nearly word for word: retell
it in your own words, shorter, the way you'd say it to a friend.]]

local NARRATION_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object: `{"request": "...", "steps":
[...], "others": [{"title", "project", "steps"}], "said": [...], "first":
true, "opening": true}` (`others` only when other conversations did
something, `first` only while nothing was said for the request, `opening`
only for the opening line), or `{"request": "...", "permission": {"tool", "summary",
"description"}}` for a permission question. Answer with exactly one JSON
object and nothing else: `{"say": "the one line"}` to speak, or
`{"skip": true}` when there's nothing worth saying. No prose, no code
fences, no Markdown, no tools. Anything else is never spoken.]]

local APPROVAL_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object: `{"asked": "...", "answer":
"..."}`. Answer with exactly one JSON object as described under "You
return", and nothing else: no prose, no code fences, no tools.]]

local CHOICE_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object: `{"asked": "...", "options":
[{"label", "description"}], "multiSelect": false, "answer": "..."}`.
Answer with exactly one JSON object as described under "You return", and
nothing else: no prose, no code fences, no tools.]]

local NARRATE_STALE_MS = 15000 -- narration not playing after this long is taken as played (or lost)
local NARRATE_TICK_MS = 400
local KEEP_WARM_MS = 240000  -- a helper idle this long while listening gets a ping (its prompt cache lasts 5 min)
local KEEP_WARM_TICK_MS = 30000

local current = "off"       -- see the header
local hearing = nil         -- the message being heard: { id, text }
local sentEndWait = nil     -- the endWaitSeconds the engine has (listen, config)
local sentHotwords = nil    -- the vocabulary the engine has, joined by "\n" (listen, config)
local queue = {}            -- heard messages waiting for the filter, oldest first
local active = nil          -- the one in the filter: { id, heard, context, fetched, started }
local lookbacks = {}        -- lookback id -> the message it's for
local lookbackCount = 0
local replyCount = 0
local levelTimer = nil
local doneTimer = nil       -- the "logically done" wait: { timer, id, text }
local log = nil             -- voice-log.txt's lines, read on first use
local providers = {}        -- stt, tts (the engine's provider names), sttFallback, ttsFallback
local providersChecked = nil -- gitgud.now() of the last health check
local PROVIDERS_RECHECK_MS = 30000
local voices = {}           -- the engine's voices (voice.voices)
local voicesChecked = nil   -- gitgud.now() of the last voices list asked
local previewCount = 0
local ECHO_AFTER_MS = 1500   -- a wake this soon after a reply stopped may be its echo
local ECHO_SHARE = 0.75      -- of the heard words found in the reply: an echo
-- Against echoes and old connections: lastSent (what was last sent to the
-- agent, as sent and as heard), connected (`ready` came on this
-- connection: events before it are an old one's).
local guard = { lastSent = nil, connected = false }
voice.guard = guard -- for tests (its repeat check)
local spokenText = {}       -- reply id -> { text, message, narration }: what each speak said
local playback = nil        -- { id, started, stopped }: the latest reply played
local lastEnded = nil       -- the latest spoken message: { id, at, stages, spoke, dropped }
local enrolled = false      -- the engine knows your voice (ready.speaker.enrolled)
-- The microphone (handlers.mic, voice.micLine): on, it's capturing ("voice.mic"
-- on, not off yet); last, the last capture, kept in FILE ({ at, device, route,
-- echo, why }; false: none), loaded on first use.
local mic = { FILE = "bragi/voice-mic.json", on = false, last = nil }
local levels = nil          -- mic levels waiting for their log line: { t, rms = {}, max = {} }
local warmTimer = nil       -- keeps the helpers warm while listening
local followUp = nil        -- a spoken reply that asked the user something (Follow-up answers, below)

-- ===================================================================
-- Log
-- ===================================================================

local function loadLog()
    if not log then
        log = {}
        for line in (gitgud.configRead(LOG_FILE) or ""):gmatch("[^\n]+") do
            log[#log + 1] = line
        end
    end
    return log
end

--- Add a line to voice-log.txt.
-- @param kind    what happened ("heard", "filter", "sent", ...)
-- @param fields  a table, written as JSON
-- The file is written at most once a second (and before a reload): writing
-- all of it, flushed to disk, at every line held up the app at each voice
-- event.
local LOG_WRITE_MS = 1000
local logDirty = false
local function writeLog()
    if logDirty then
        logDirty = false
        gitgud.configWrite(LOG_FILE, table.concat(log, "\n") .. "\n")
    end
end
gitgud.on("app.reloading", writeLog)

local function record(kind, fields)
    loadLog()
    log[#log + 1] = os.date("%Y-%m-%d %H:%M:%S") .. " " .. kind .. " " .. gitgud.jsonEncode(fields or {})
    if #log > LOG_LINES then
        local drop = #log - LOG_LINES
        table.move(log, drop + 1, #log, 1)
        for i = #log, LOG_LINES + 1, -1 do
            log[i] = nil
        end
    end
    if not logDirty then
        logDirty = true
        gitgud.after(LOG_WRITE_MS, writeLog)
    end
end

helpers.log = record -- the helpers' calls and bragi/quick.lua's routes go here too

--- The log's lines, oldest first.
function voice.logLines()
    return loadLog()
end

--- The last capture, kept in mic.FILE so it outlives the log's window and
-- the app (whether echo cancellation really runs).
function mic.lastCapture()
    if mic.last == nil then
        local saved = gitgud.jsonDecode(gitgud.configRead(mic.FILE) or "")
        mic.last = type(saved) == "table" and type(saved.device) == "string" and saved or false
    end
    return mic.last or nil
end

--- How a capture works, in words: "echo cancelled", or "plain capture
-- (echo cancellation failed: why)".
function mic.mode(m)
    if m.echo then
        return "echo cancelled"
    end
    return "plain capture" .. (m.why and (" (echo cancellation failed: " .. m.why .. ")") or "")
end

--- Log how long after the latest message ended a stage came, once each.
-- @param stage   "filtered", "started", "narration", ...
-- @param fields  optional extra fields
-- @param id      optional: only when the latest message is this one
local function timing(stage, fields, id)
    if not lastEnded or lastEnded.stages[stage] or (id and id ~= lastEnded.id) then
        return
    end
    lastEnded.stages[stage] = true
    fields = fields or {}
    fields.id = lastEnded.id
    fields.stage = stage
    fields.ms = gitgud.now() - lastEnded.at
    record("timing", fields)
end

--- The latest message won't be answered (not sent, or stopped).
local function dropped(id)
    if lastEnded and lastEnded.id == id then
        lastEnded.dropped = true
    end
end

-- ===================================================================
-- Helper sessions (bragi/helpers.lua): lean Haiku 5.5, one job each
-- ===================================================================

--- Voice's helpers start afresh only while listening.
local function listening()
    return current ~= "off"
end

local function newHelper(prefix, file, format)
    return helpers.new({ prefix = prefix, file = file, format = format, wanted = listening })
end

local filter = newHelper("bragi-heard", "heard-text.md", FILTER_FORMAT)
local judger = newHelper("bragi-judge", "heard-text.md", FILTER_FORMAT)
local summarizer = newHelper("bragi-spoken", "spoken-reply.md", SUMMARY_FORMAT)
local narrator = newHelper("bragi-narrate", "narration.md", NARRATION_FORMAT)
local barger = newHelper("bragi-barge", "barge-in.md", BARGE_FORMAT)
local approver = newHelper("bragi-approve", "approval.md", APPROVAL_FORMAT)
local chooser = newHelper("bragi-choose", "choice.md", CHOICE_FORMAT)
local ALL_HELPERS = { filter, judger, summarizer, narrator, barger, approver, chooser }
-- bragi/master.lua answers cards with the same two (a bragi_send).
voice.cardHelpers = { approve = approver, choose = chooser }

local askHelper = helpers.ask

--- When the recognizer's vocabulary (bragi/vocabulary.lua) changed since
-- the engine got it (a correction learned, new names in the conversation
-- or the repository), send it again in a `config`.
function voice.syncHotwords()
    if current == "off" or not sentHotwords or not voice.backend.config then
        return
    end
    local list = vocab.hotwords()
    local joined = table.concat(list, "\n")
    if joined == sentHotwords then
        return
    end
    sentHotwords = joined
    voice.backend.config({ vocabulary = list })
    record("hotwords", { count = #list, sent = "config", words = list })
end

--- While listening: ping every helper idle for KEEP_WARM_MS, so a call
-- after a quiet stretch is still warm. Not while a message is being heard.
-- The recognizer's vocabulary is brought up to date on the same tick.
local function keepWarm()
    if current == "off" or hearing then
        return
    end
    helpers.keepWarm(ALL_HELPERS, KEEP_WARM_MS)
    helpers.keepWarm({ require("bragi.recap").helper }, KEEP_WARM_MS)
    quick.keepWarm()
    voice.syncHotwords()
end

--- Start every helper that isn't running and warm it with a ping, so the
-- first real call is warm; then keep them warm while listening. The quick
-- answer helpers (bragi/quick.lua) too: spoken questions go to them.
local function warmHelpers()
    for _, h in ipairs(ALL_HELPERS) do
        helpers.warm(h)
    end
    helpers.warm(require("bragi.recap").helper) -- recaps (bragi/recap.lua)
    quick.warm()
    if not warmTimer then
        warmTimer = gitgud.every(KEEP_WARM_TICK_MS, keepWarm)
    end
end

-- ===================================================================
-- State
-- ===================================================================

local function paintLevel(on)
    if levelTimer then
        gitgud.cancelTimer(levelTimer)
        levelTimer = nil
    end
    if not on then
        agent.voiceLevel(nil)
        return
    end
    levelTimer = gitgud.every(LEVEL_MS, function()
        local levels = {}
        for i = 1, LEVEL_BARS do
            levels[i] = 0.25 + math.random() * 0.75
        end
        agent.voiceLevel(levels)
    end)
end

local function wakeWord()
    local word = text.trim(settings.get("bragi.wakeWord", "Bragi"))
    return word ~= "" and word or "Bragi"
end

local function closingPhrase()
    return text.trim(settings.get("bragi.closingPhrase", "over and out"))
end

--- What wake word training saved (bragi/training.lua), as `hello` or
-- `config` fields: mishearings, wakeThreshold (only what's set).
function voice.tuning()
    local fields = {}
    local list = gitgud.jsonDecode(settings.get("bragi.mishearings", ""))
    if type(list) == "table" and #list > 0 then
        fields.mishearings = list
    end
    local threshold = tonumber(settings.get("bragi.wakeThreshold", ""))
    if threshold then
        fields.wakeThreshold = threshold
    end
    return fields
end

--- Seconds Bragi waits once the user seems done (the setting, kept to 2..10).
function voice.endWait()
    local seconds = tonumber(settings.get("bragi.endWaitSeconds", "3")) or 3
    return math.max(2, math.min(10, seconds))
end

--- Change state and show it under the prompt box.
local function setState(state, line)
    current = state
    if state ~= "listening" and state ~= "hearing" then
        paintLevel(false)
    end
    if state == "off" and warmTimer then
        gitgud.cancelTimer(warmTimer)
        warmTimer = nil
    end
    if not line then
        if state == "off" then
            line = "Voice is off"
        elseif state == "connecting" then
            line = "Connecting to the voice service"
        elseif state == "hearing" then
            local phrase = closingPhrase()
            line = phrase ~= "" and ("Listening. Say \u{201C}" .. phrase .. "\u{201D} or press Send")
                or "Listening. Press Send when you're done"
        elseif followUp and followUp.open then
            line = "Listening for your answer"
        else
            line = "Say \u{201C}" .. wakeWord() .. "\u{201D} to talk"
        end
    end
    agent.voiceStatus(line, state ~= "off")
    app.publish("bragi.voice", state)
end

--- The current state: off, connecting, listening, or hearing.
function voice.state()
    return current
end

--- True while a message is being heard (Send ends it).
function voice.hearing()
    return hearing ~= nil
end

-- ===================================================================
-- The pre-pass filter
-- ===================================================================

--- Words the user uses, for repairing misheard terms (bragi/vocabulary.lua).
local function vocabulary()
    return vocab.words()
end

--- The filter's answer, or nil when it isn't one.
local function parseAnswer(reply)
    if type(reply) ~= "string" then
        return nil
    end
    local first = reply:find("{", 1, true)
    local last = reply:match(".*()}")
    if not first or not last then
        return nil
    end
    local answer = gitgud.jsonDecode(reply:sub(first, last))
    if type(answer) ~= "table" or type(answer.text) ~= "string" then
        return nil
    end
    return answer
end

--- Whether what was heard and what the filter changed show in the
-- transcript (bragi.showHeard, for troubleshooting; the log always has it).
local function showHeard()
    return settings.get("bragi.showHeard", false) == true
end

--- "lure" to "Lua", ... for the note under a sent message.
local function describeChanges(changes)
    local parts = {}
    for _, c in ipairs(type(changes) == "table" and changes or {}) do
        if type(c) == "table" and c.heard and c.text then
            parts[#parts + 1] = "\u{201C}" .. tostring(c.heard) .. "\u{201D} to \u{201C}"
                .. tostring(c.text) .. "\u{201D}"
        end
    end
    return table.concat(parts, ", ")
end

local filterNext
local startNarration
local speak
local expectFollowUp
local closeFollowUp
local takeMessage
local classify
local openAfterFilter
local typedCount = 0

--- Run fn once the agent's turn is over (now, when none runs).
local function afterTurn(fn)
    if not agent.session().turn then
        return fn()
    end
    local timer
    timer = gitgud.every(150, function()
        if not agent.session().turn then
            gitgud.cancelTimer(timer)
            fn()
        end
    end)
end

local BARGE_ACTIONS = { stop = true, steer = true, note = true, resume = true }

--- A message that talks over Bragi or its work, from when it's heard until
-- it's sent or the barge-in classifier says what it is: no narration
-- meanwhile ("never mind" would cut it off). Given up on after JUDGING_MS.
guard.JUDGING_MS = 15000
function guard.judgingNow()
    local j = guard.judging
    return j ~= nil and gitgud.now() - j.at < guard.JUDGING_MS
end

--- Send a checked message to the agent. One that cut a reply short, or
-- came while a turn runs, is classified first: stop, steer, or note.
-- @param m     the message (from the queue)
-- @param body  its checked text
-- @param opts  agent.send's options
local function deliver(m, body, opts)
    if guard.judging and guard.judging.id == m.id then
        guard.judging = nil -- classify takes it up again
    end
    m.delivered = true -- what it carries on with goes after it ("Carrying on after a pause")
    if m.readAloud then
        guard.readAloud[m.tab or agent.current()] = true
    end
    if m.barge and m.route ~= "main" then
        guard.endTelling("asked something else")
    end
    guard.lastSent = body .. "\n" .. (m.heard or "")
    if m.tab and m.tab ~= agent.current() then
        return guard.answerElsewhere(m, body, opts)
    end
    -- Pictures waiting in the prompt box go with it, to the agent: the
    -- quick answers can't see them.
    if m.route == "quick" and #agent.attachments() == 0 then
        -- Haiku answers it, even while the agent works; handed back, it
        -- goes on the usual way.
        timing("started", { quick = true }, m.id)
        return quick.ask(body, { pending = opts.pending, voice = true, id = m.id, context = opts.context,
            onHandoff = function(line)
                m.route = "main"
                speak(line, { handoff = true })
                deliver(m, body, opts)
            end })
    end
    if m.route == "recap" then
        -- How the conversations Bragi follows are doing (bragi/recap.lua),
        -- even while the agent works; when it can't tell, the agent does.
        timing("started", { recap = true }, m.id)
        return require("bragi.recap").answer(body, { pending = opts.pending,
            onAnswer = function(said)
                guard.sayRecap(m.id, said)
            end,
            onFail = function()
                m.route = "main"
                deliver(m, body, opts)
            end })
    end
    if m.route == "command" then
        -- A slash command in any words ("compact this conversation"): run
        -- here, now or once the turn is over (bragi/slash.lua); one it
        -- can't run goes on as a message.
        m.route = "main"
        if m.command and require("bragi.slash").answer(opts.pending, body, m.command, {
            onRun = function(said)
                guard.sayCommand(m.id, said)
            end }) then
            timing("started", { command = true }, m.id)
            return
        end
    end
    local running = agent.session().turn == true
    if m.carryOn and running then
        -- The rest of what was just sent: the turn stops, and it goes.
        record("barge", { id = m.id, text = body, action = "steer", why = "carried on after a pause",
            running = true })
        agent.stop()
        return afterTurn(function()
            record("sent", { id = m.id, text = body, action = "steer" })
            timing("started", { action = "steer" }, m.id)
            agent.send(body, opts)
            startNarration(body, m.id)
        end)
    end
    if not m.barge and not running then
        record("sent", { id = m.id, text = body, context = opts.context and #opts.context or nil })
        timing("started", nil, m.id)
        agent.send(body, opts)
        return startNarration(body, m.id)
    end
    classify(m, body, opts, running)
end

--- A message that came while the agent works, or that cut a reply short:
-- the barge-in classifier (prompts/barge-in.md) decides. Only a clear stop
-- or a clear change of direction interrupts the agent; anything else (and
-- a classifier that fails) is a note, sent once the turn is over, and
-- Bragi says it'll get to it next.
-- @param m        { id, typed }: the message (typed ones aren't narrated)
-- @param running  whether the agent's turn ran when it came
classify = function(m, body, opts, running)
    local started = gitgud.now()
    local judging = { id = m.id, at = started }
    guard.judging = judging
    askHelper(barger, { spoken = m.barge and m.barge.spoken or "", said = body, running = running },
        function(reply, err)
            if guard.judging == judging then
                guard.judging = nil
            end
            local answer = nil
            local first = type(reply) == "string" and reply:find("{", 1, true)
            local last = type(reply) == "string" and reply:match(".*()}")
            if first and last then
                answer = gitgud.jsonDecode(reply:sub(first, last))
            end
            local action = type(answer) == "table" and BARGE_ACTIONS[answer.action] and answer.action or "note"
            -- Go on with what was cut short ("never mind, keep going").
            if action == "resume" then
                if m.barge and guard.resumeTelling() then
                    record("barge", { id = m.id, text = body, action = "resume", why = answer.why,
                        running = running, ms = gitgud.now() - started })
                    dropped(m.id)
                    agent.dropPending(opts.pending)
                    return
                end
                action = "note"
            end
            if m.barge then
                guard.endTelling(action)
            end
            -- A card waits on the user: stopping the turn would cancel it, so only
            -- a clear stop does; a change of direction waits like a note.
            local card = action == "steer" and agent.session().turn and agent.waitingCard()
            if card then
                action = "note"
            end
            record("barge", { id = m.id, text = body, action = action, why = type(answer) == "table" and answer.why
                or err, running = running, typed = m.typed, ms = gitgud.now() - started,
                held = card and "card" or nil })
            if action == "stop" then
                voice.backend.speakStop(nil)
                dropped(m.id)
                agent.dropPending(opts.pending)
                if agent.session().turn then
                    agent.stop()
                else
                    agent.addMessage("note", showHeard() and ("Heard \u{201C}" .. body .. "\u{201D}: stopped.")
                        or "Stopped.")
                end
                return
            end
            if action == "steer" and agent.session().turn then
                agent.stop()
            elseif action == "note" and agent.session().turn then
                agent.waitingTitle("Sends when the agent is done")
                if voice.speaks() then
                    speak("I'll get to that next.", { queued = true })
                end
            end
            afterTurn(function()
                record("sent", { id = m.id, text = body, action = action, typed = m.typed })
                if m.typed then
                    return agent.send(body, opts)
                end
                timing("started", { action = action }, m.id)
                agent.send(body, opts)
                startNarration(body, m.id)
            end)
        end)
end

--- A typed message while the agent works (agent.submit): stop, steer, or
-- wait for the turn, like a spoken one.
-- @param opts  agent.send's options (pending: the message's waiting item)
function voice.whileWorking(body, opts)
    typedCount = typedCount + 1
    classify({ id = "t" .. typedCount, typed = true }, body, opts or {}, agent.session().turn == true)
end

-- The filter keeps every word, "um" and the wake word too ("I don't want us
-- cutting stuff that it heard"). A word it leaves out anyway is put back
-- where it was heard (guard.restoreWords), so a slip there doesn't cost
-- its repairs.

local function quoted(list)
    local parts = {}
    for _, s in ipairs(list) do
        parts[#parts + 1] = "\u{201C}" .. s .. "\u{201D}"
    end
    return table.concat(parts, ", ")
end

local function wordList(s)
    local list = {}
    for w in tostring(s or ""):lower():gmatch("[%w']+") do
        list[#list + 1] = w
    end
    return list
end

--- Whether a phrase the filter names is in the message, not the context
-- around it: at least half its words are in the message.
local function inMessage(phrase, message)
    local words = {}
    for _, w in ipairs(wordList(message)) do
        words[w] = true
    end
    local found, total = 0, 0
    for _, w in ipairs(wordList(phrase)) do
        total = total + 1
        found = found + (words[w] and 1 or 0)
    end
    return total > 0 and found * 2 >= total
end

--- The filter's `unclear`: what it couldn't place in the message (the
-- app asks), and what it kept as heard though another reading was
-- possible (`maybe`), or couldn't place in the context only
-- ("deer hair" in the lookback held a whole request back).
local function unclearOf(answer, message)
    local unplaced, maybes = {}, {}
    for _, u in ipairs(type(answer.unclear) == "table" and answer.unclear or {}) do
        local heard = type(u) == "table" and u.heard or u
        if type(heard) == "string" and text.trim(heard) ~= "" then
            local maybe = type(u) == "table" and type(u.maybe) == "string" and u.maybe ~= ""
            local list = (maybe or not inMessage(heard, message)) and maybes or unplaced
            list[#list + 1] = text.trim(heard)
        end
    end
    return unplaced, maybes
end

--- The filter's `context` as one string: it sometimes answers with a
-- list of lines instead (the list was dropped whole).
local function contextText(v)
    if type(v) == "table" then
        local lines = {}
        for _, line in ipairs(v) do
            if type(line) == "string" and text.trim(line) ~= "" then
                lines[#lines + 1] = text.trim(line)
            end
        end
        return table.concat(lines, "\n")
    end
    return type(v) == "string" and text.trim(v) or ""
end

--- Where the filter's text lost heard words without a word about them
-- ("My input and change the" vanished). Heard words are lined up against
-- its text in order (the longest common run of words); each stretch
-- between the words they share where heard words are missing is one of:
--   - only missing: they were left out, and go back there;
--   - missing, with words of reported repairs in their place (`changes`;
--     what `changes` or `unclear` name counts as accounted for): the
--     repairs stay, and the heard words they don't account for go back
--     beside them;
--   - with a word no repair accounts for ("failures" came back
--     "faiLuas"): a change it didn't report, so the stretch goes back to
--     the words as heard.
-- Returns the edits, in order ({ at (the index of the text's word it goes
-- before or starts at; one past the last at the end), upto (the last word
-- it replaces; nil to insert), words (as heard) }), the missing words as
-- heard, and the text's words { w (lower case), s, e (where in the text) }.
local function differences(heard, answer)
    local spare, repaired = {}, {}
    for _, field in ipairs({ "changes", "unclear" }) do
        for _, c in ipairs(type(answer[field]) == "table" and answer[field] or {}) do
            for _, w in ipairs(wordList(type(c) == "table" and c.heard or c)) do
                spare[w] = true
            end
            if type(c) == "table" then
                for _, w in ipairs(wordList(c.text)) do
                    repaired[w] = true
                end
            end
        end
    end
    local said = {}
    for w in tostring(heard or ""):gmatch("[%w']+") do
        said[#said + 1] = w
    end
    local words = {}
    for s, w, e in tostring(answer.text or ""):gmatch("()([%w']+)()") do
        words[#words + 1] = { w = w:lower(), s = s, e = e }
    end
    -- The longest common run of words, from the end (lcs[i][j]: said[i..],
    -- words[j..]).
    local lcs = {}
    for i = #said + 1, 1, -1 do
        lcs[i] = {}
        for j = #words + 1, 1, -1 do
            if i > #said or j > #words then
                lcs[i][j] = 0
            elseif said[i]:lower() == words[j].w then
                lcs[i][j] = lcs[i + 1][j + 1] + 1
            else
                lcs[i][j] = math.max(lcs[i + 1][j], lcs[i][j + 1])
            end
        end
    end
    local edits, missing = {}, {}
    -- The stretch since the last shared word: heard words (indexes) and the
    -- text's words from..to.
    local gap = { said = {}, from = 1, to = 0 }
    local function flush(nextShared)
        local lost, firstSpare = {}, nil
        for k, i in ipairs(gap.said) do
            if spare[said[i]:lower()] then
                firstSpare = firstSpare or k
            else
                lost[#lost + 1] = { k = k, word = said[i] }
            end
        end
        if #lost > 0 then
            local hasText = gap.to >= gap.from
            local unexplained = false
            for j = gap.from, gap.to do
                unexplained = unexplained or not repaired[words[j].w]
            end
            if hasText and unexplained then
                local all = {}
                for _, i in ipairs(gap.said) do
                    all[#all + 1] = said[i]
                end
                edits[#edits + 1] = { at = gap.from, upto = gap.to, words = all }
            else
                local before, after = {}, {}
                for _, l in ipairs(lost) do
                    local list = (hasText and firstSpare and l.k < firstSpare) and before or after
                    list[#list + 1] = l.word
                end
                if #before > 0 then
                    edits[#edits + 1] = { at = gap.from, words = before }
                end
                if #after > 0 then
                    edits[#edits + 1] = { at = nextShared, words = after }
                end
            end
            for _, l in ipairs(lost) do
                missing[#missing + 1] = l.word
            end
        end
        gap = { said = {}, from = nextShared + 1, to = nextShared }
    end
    local i, j = 1, 1
    while i <= #said or j <= #words do
        if i <= #said and j <= #words and said[i]:lower() == words[j].w then
            flush(j)
            i, j = i + 1, j + 1
        elseif j <= #words and (i > #said or lcs[i][j + 1] > lcs[i + 1][j]) then
            gap.to = j -- a word of the text's own
            j = j + 1
        else
            gap.said[#gap.said + 1] = i
            i = i + 1
        end
    end
    flush(#words + 1)
    return edits, missing, words
end

--- The words the filter lost, as heard, in one string; nil when none.
local function droppedWords(heard, answer)
    local _, missing = differences(heard, answer)
    return #missing > 0 and table.concat(missing, " ") or nil
end

--- The filter's text with what it lost put back where it was heard
-- (differences): reported repairs stay, a left-out word goes back in front
-- of the word it was heard before (at the end, ahead of the closing
-- punctuation), and a change it didn't report goes back to the words as
-- heard. The text keeps its own spacing and punctuation otherwise.
-- Returns the text and the words lost (nil when none were).
function guard.restoreWords(heard, answer)
    local txt = tostring(answer.text or "")
    local edits, missing, words = differences(heard, answer)
    if #edits == 0 then
        return txt, nil
    end
    local parts, pos = {}, 1
    for _, e in ipairs(edits) do
        local joined = table.concat(e.words, " ")
        if e.upto then
            parts[#parts + 1] = txt:sub(pos, words[e.at].s - 1)
            parts[#parts + 1] = joined
            pos = words[e.upto].e
        elseif e.at <= #words then
            parts[#parts + 1] = txt:sub(pos, words[e.at].s - 1)
            parts[#parts + 1] = joined .. " "
            pos = words[e.at].s
        else
            local cut = #words > 0 and words[#words].e or #txt + 1
            parts[#parts + 1] = txt:sub(pos, cut - 1)
            parts[#parts + 1] = (cut > 1 and " " or "") .. joined
            pos = cut
        end
    end
    parts[#parts + 1] = txt:sub(pos)
    return table.concat(parts), table.concat(missing, " ")
end

--- Corrections the filter heard the user make ("I said Claude, not cloud").
local function learnFrom(answer, id)
    for _, c in ipairs(type(answer.learned) == "table" and answer.learned or {}) do
        if type(c) == "table" and vocab.learn(c.heard, c.meant, "said") then
            record("learned", { id = id, heard = c.heard, meant = c.meant, how = "said" })
            agent.addMessage("note", "Noted: \u{201C}" .. tostring(c.heard) .. "\u{201D} means \u{201C}"
                .. tostring(c.meant) .. "\u{201D}.")
        end
    end
end

--- Something typed was sent (agent.submit).
local function onSubmitted(body)
    closeFollowUp("typed")
    if type(body) == "string" then
        guard.lastSent = body
    end
end

--- Send a message out of the filter, with its context and notes (shown
-- only with bragi.showHeard). Logs what context went with it. A short
-- one's context is the lookback as heard, and what the filter says it
-- refers to when that isn't in it; a longer one's, what
-- the filter recovered, when the lookback was fetched.
function guard.sendChecked(m, body, answer, notes)
    local context = answer and m.fetched > 0 and contextText(answer.context) or ""
    local heard = m.short and m.lookback or ""
    if heard ~= "" and context ~= "" and not heard:find(context, 1, true) then
        context = heard .. "\n\nWhat it refers back to: " .. context
    elseif heard ~= "" then
        context = heard
    end
    if context ~= "" then
        record("context", { id = m.id, tokens = m.fetched, segments = m.segments, why = m.contextWhy,
            short = m.short or nil, chars = #context })
        if showHeard() then
            notes[#notes + 1] = "Sent with what you said just before: \u{201C}" .. context .. "\u{201D}"
        end
    end
    deliver(m, body, {
        voice = true,
        pending = m.pending,
        context = context ~= "" and context or nil,
        note = #notes > 0 and table.concat(notes, "\n") or nil,
    })
end

--- The message is through the filter (answer) or the filter failed (err).
-- Nothing heard is held in the prompt box or dropped for being unclear
-- ("the text from that message just pops right back into
-- my text field"): it goes as heard.
local function finish(answer, err)
    local m = active
    active = nil
    if guard.carryWaits(m) then
        -- They went on after the pause: it waits for what comes
        -- ("Carrying on after a pause").
        m.held = { answer = answer, err = err }
        record("carry-on", { id = m.id, state = "held" })
        return filterNext()
    end
    guard.finishFor(m, answer, err)
    filterNext()
end

--- A message through the filter goes on: sent, or dropped.
function guard.finishFor(m, answer, err)
    local elapsed = gitgud.now() - m.started
    local sent = false
    timing("filtered", { ok = answer ~= nil }, m.id)
    if not answer then
        record("filter-failed", { id = m.id, heard = m.heard, error = err, ms = elapsed })
        sent = true
        m.route = quick.decide(m.heard, nil, nil, m.id)
        openAfterFilter(m, m.heard)
        guard.sendChecked(m, m.heard, nil, showHeard()
            and { "Sent as heard: couldn't check it (" .. tostring(err) .. ")" } or {})
    else
        record("filter", { id = m.id, heard = m.heard, answer = answer, ms = elapsed,
            context = m.context ~= "" and #m.context or 0 })
        learnFrom(answer, m.id)
        m.readAloud = answer.read_aloud == true
        local changed = describeChanges(answer.changes)
        local unplaced, maybes = unclearOf(answer, m.heard)
        local missing = droppedWords(m.heard, answer)
        if answer.kind == "not-for-bragi" then
            if missing then
                record("filter-dropped", { id = m.id, heard = m.heard, text = answer.text, missing = missing })
            end
            agent.addMessage("note", showHeard() and ("Heard \u{201C}" .. m.heard .. "\u{201D}, not meant for Bragi.")
                or "That didn't sound meant for Bragi, so it wasn't sent.")
        else
            sent = true
            -- Unsure, or words it couldn't place: sent as heard, never held
            -- (a closing "and that's it" held a whole check-in in the
            -- prompt box). The agent reads a raw transcript fine; a lost
            -- word it can't get back. Words it left out without saying
            -- are put back where they were heard, and its repairs stay.
            local unsure = answer.confidence == "low" or text.trim(answer.text) == "" or #unplaced > 0
            local body = answer.text
            if unsure then
                body = m.heard
            elseif missing then
                body = guard.restoreWords(m.heard, answer)
            end
            if missing then
                record("filter-dropped", { id = m.id, heard = m.heard, text = answer.text, missing = missing,
                    sent = body })
            end
            m.route = quick.decide(body, answer.route, answer.route_why, m.id, answer.kind)
            m.command = m.route == "command" and type(answer.command) == "string" and answer.command or nil
            local notes = {}
            if showHeard() then
                if unsure then
                    local why = {}
                    if #unplaced > 0 then
                        why[#why + 1] = "unclear: " .. quoted(unplaced)
                    end
                    if missing then
                        why[#why + 1] = "the cleanup left out " .. quoted({ missing })
                    elseif changed ~= "" then
                        why[#why + 1] = "it would have changed " .. changed
                    end
                    notes[#notes + 1] = "Sent as heard, not sure it was heard right"
                        .. (#why > 0 and (" (" .. table.concat(why, "; ") .. ")") or "")
                else
                    if changed ~= "" then
                        notes[#notes + 1] = "Heard \u{201C}" .. m.heard .. "\u{201D}, changed " .. changed
                    end
                    if missing then
                        notes[#notes + 1] = "Put back what the cleanup left out: " .. quoted({ missing })
                    end
                end
                if #maybes > 0 then
                    notes[#notes + 1] = "Kept as heard: " .. quoted(maybes)
                end
            end
            openAfterFilter(m, body)
            guard.sendChecked(m, body, answer, notes)
        end
    end
    if not sent then
        dropped(m.id)
        agent.dropPending(m.pending)
        if m.barge then
            guard.endTelling("not for Bragi")
        end
    end
end

-- Words that point back at a long stretch of what was said ("did you get
-- all that?"): the context is fetched as far back as the window goes.
local LONG_STRETCH = { "all that", "all of that", "all this", "all of this", "all those", "everything i",
    "everything you heard", "all i said", "all i just said", "the whole thing", "what i've been saying",
    "what i was saying", "what i was just saying" }

-- Words a thought rarely starts with: context that begins with one was cut
-- off mid-thought.
local CONTINUING = { ["and"] = true, ["but"] = true, ["so"] = true, ["or"] = true, ["about"] = true,
    ["because"] = true, ["which"] = true, ["that"] = true, ["then"] = true, ["also"] = true, ["plus"] = true,
    ["to"] = true, ["of"] = true, ["with"] = true, ["for"] = true }

--- Whether a message refers to a long stretch of what was said.
local function refersToLongStretch(s)
    local lower = " " .. tostring(s or ""):lower():gsub("[%p]", " "):gsub("%s+", " ") .. " "
    for _, phrase in ipairs(LONG_STRETCH) do
        if lower:find(" " .. phrase .. " ", 1, true) then
            return true
        end
    end
    return false
end

--- Whether recovered context starts mid-thought: lower case, "...", or a
-- word that carries on from something before it.
local function cutOff(context)
    local s = text.trim(tostring(context or ""))
    if s == "" then
        return false
    end
    if s:find("^%.%.%.") or s:find("^\u{2026}") or s:find("^%l") then
        return true
    end
    local first = s:match("^(%a+)")
    return first ~= nil and CONTINUING[first:lower()] == true
end

local ask

--- Ask the engine for the lookback for a message in the filter; the filter
-- is asked again when it comes (handlers.lookback), or after
-- HEARD.LOOKBACK_WAIT_MS without it. False when it can't be.
-- @param why  for the log: "short", "filter", "long", "cut-off", "empty"
local function fetchContext(m, tokens, why)
    if current == "off" then
        return false
    end
    lookbackCount = lookbackCount + 1
    local id = "lb" .. lookbackCount
    lookbacks[id] = m
    m.fetched = tokens
    m.contextWhy = why
    record("lookback", { id = m.id, tokens = tokens, why = why })
    local ok = voice.backend.lookback(id, tokens)
    if not ok then
        lookbacks[id] = nil
        return false
    end
    gitgud.after(HEARD.LOOKBACK_WAIT_MS, function()
        if lookbacks[id] == m then
            lookbacks[id] = nil
            record("lookback-timeout", { id = m.id, tokens = tokens })
            if m == active then
                ask(m)
            end
        end
    end)
    return true
end

local function onFilterAnswer(m, reply, err)
    if m ~= active then
        return
    end
    if m.again then
        -- It carried on while the filter checked it: checked again, all of it.
        m.again = nil
        return ask(m)
    end
    if not reply then
        return finish(nil, "the filter: " .. tostring(err))
    end
    local answer = parseAnswer(reply)
    if not answer then
        return finish(nil, "the filter's answer wasn't JSON")
    end
    local wanted = answer.needs_context
    local tokens, why = nil, "filter"
    if m.fetched < HEARD.CONTEXT_MORE then
        if wanted == "more" or (wanted == "some" and m.fetched > 0) then
            tokens = HEARD.CONTEXT_MORE
        elseif (wanted == "some" or m.fetched > 0) and refersToLongStretch(m.heard) then
            -- "Did you get all that?": as far back as the window goes.
            tokens, why = HEARD.CONTEXT_MORE, "long"
        elseif m.fetched > 0 and cutOff((m.short and m.lookback ~= "") and m.lookback
            or contextText(answer.context)) then
            tokens, why = HEARD.CONTEXT_MORE, "cut-off"
        elseif wanted == "some" then
            tokens = HEARD.CONTEXT_SOME
        end
    end
    if not tokens or not fetchContext(m, tokens, why) then
        return finish(answer)
    end
end

ask = function(m)
    local digest = vocab.digest()
    local corrections = {}
    for _, c in ipairs(vocab.corrections()) do
        corrections[#corrections + 1] = { heard = c.heard, meant = c.meant }
    end
    askHelper(filter, { message = m.heard, context = m.context, conversation = digest, corrections = corrections,
        vocabulary = vocab.words(digest) },
        function(reply, err)
            onFilterAnswer(m, reply, err)
        end)
end

--- Run the next queued message through the filter.
filterNext = function()
    if active or #queue == 0 then
        return
    end
    active = table.remove(queue, 1)
    -- A short message always has the lookback, from before the filter
    -- ("lookback essentially always needs to be sent in
    -- some capacity when the message I send is fairly short").
    if active.short then
        local long = refersToLongStretch(active.heard)
        if fetchContext(active, long and HEARD.CONTEXT_MORE or HEARD.CONTEXT_SOME, long and "long" or "short") then
            return
        end
    end
    ask(active)
end

--- Put a heard message through the filter (it then goes to the agent).
-- @param heard  the message as heard
-- @param id     optional message id from the engine
-- @param pending optional agent.voicePending item standing for it meanwhile
-- @param barge   optional { spoken }: it cut that reply short
-- @param t0      optional: when it started, in the engine's time (the
--                lookback keeps only what came before)
-- @param to      optional { tab, question }: an answer to what that
--                conversation (not the one shown) asked aloud goes there
-- @return the message, as it goes through
function voice.filter(heard, id, pending, barge, t0, to)
    local m = { id = id or "", heard = heard, context = "", lookback = "", fetched = 0,
        started = gitgud.now(), pending = pending, barge = barge, t0 = tonumber(t0),
        short = #wordList(heard) < HEARD.SHORT_WORDS, tab = to and to.tab, question = to and to.question }
    queue[#queue + 1] = m
    filterNext()
    return m
end

-- ===================================================================
-- Logically done
-- ===================================================================

local function cancelDone()
    if doneTimer then
        gitgud.cancelTimer(doneTimer.timer)
        doneTimer = nil
        if current == "hearing" then
            setState("hearing")
        end
    end
end

--- The last reply in the conversation, as written (the model reads its end
-- as what was asked: voicemodels.DECIDER's "Bragi's last words"). Not the
-- line last spoken, which may be a summary of it or a narration.
function guard.lastReply()
    local list = agent.items()
    for i = #list, 1, -1 do
        if list[i].kind == "assistant" then
            return tostring(list[i].text or "")
        end
    end
    return ""
end

--- After a pause: ask the judge whether the user is done with the text so far.
-- Its own helper: the filter never waits behind it, and a newer pause
-- drops the calls still waiting.
local function judge(id, sofar)
    local started = gitgud.now()
    -- The message itself, not its id: ids start again on a new connection.
    local h = hearing
    askHelper(judger, { message = sofar, context = "", vocabulary = vocabulary() }, function(reply)
        local answer = parseAnswer(reply)
        local still = h ~= nil and hearing == h and h.id == id and h.text == sofar
        record("judge", { id = id, text = sofar, complete = answer and answer.complete,
            ms = gitgud.now() - started, current = still or false })
        if not still or not answer or answer.complete ~= true or doneTimer then
            return
        end
        local seconds = voice.endWait()
        doneTimer = {
            id = id,
            timer = gitgud.after(seconds * 1000, function()
                doneTimer = nil
                if hearing == h then
                    record("done", { id = id, seconds = seconds })
                    voice.backend.send("done")
                end
            end),
        }
        setState("hearing", "Sounds done. Sending in " .. seconds .. " s unless you go on")
    end, { latest = true })
end

--- Ask the turn-taking model about the message being heard, every
-- EVERY_MS once its words have settled, until it ends (bragi/decider.lua).
-- Not while it may be Bragi's own voice, while speech goes on, or once
-- the message was ended.
function guard.startDeciding()
    local h = hearing
    if not guard.decider or not h or h.decideTimer then
        return
    end
    local decider = require("bragi.decider")
    h.grewAt = gitgud.now()
    h.decideTimer = gitgud.every(decider.EVERY_MS, function()
        if hearing ~= h or not guard.decider or h.ended then
            gitgud.cancelTimer(h.decideTimer)
            return
        end
        local now = gitgud.now()
        if guard.speaking or text.trim(h.text) == "" or now - h.grewAt < decider.SETTLE_MS
            or (h.asking and now - h.asking.at < decider.WAIT_MS) then
            return
        end
        guard.decideCount = (guard.decideCount or 0) + 1
        local id = "d" .. guard.decideCount
        h.asking = { id = id, at = now, text = h.text }
        local ok, err = voice.backend.decide(decider.request(id, h.text, guard.lastReply()))
        if not ok then
            -- The engine won't run it: the Haiku judge decides from here on
            -- (as when the model fails, handlers.decision).
            h.asking = nil
            record("decide-failed", { id = h.id, error = err })
            guard.decider = false
            gitgud.cancelTimer(h.decideTimer)
            judge(h.id, h.text)
        end
    end)
end

-- ===================================================================
-- Providers
-- ===================================================================

--- Whether voice can run here: a speech engine is built in.
function voice.available()
    return voice.backend.available ~= nil and voice.backend.available() == true
end

--- What the engine uses: { stt, tts, sttFallback, ttsFallback }, each
-- nil until known.
function voice.providers()
    return providers
end

--- Update what's known; publishes "bragi.voiceProviders" on a change.
-- A field left nil stays as it was; "" clears it. A fallback reason that's
-- new gets a note in the conversation.
local function setProviders(fields)
    local changed = false
    for _, key in ipairs({ "stt", "tts", "sttFallback", "ttsFallback" }) do
        local value = fields[key]
        if value == "" then
            value = nil
        end
        if fields[key] ~= nil then
            if providers[key] ~= value then
                providers[key] = value
                changed = true
                -- For troubleshooting only: Settings says it too.
                if value and key:find("Fallback") and showHeard() then
                    agent.addMessage("note", (key == "sttFallback" and "Speech recognition" or "Speech output")
                        .. " fell back: " .. tostring(value) .. ".")
                end
            end
        end
    end
    if changed then
        record("providers", providers)
        app.publish("bragi.voiceProviders", providers)
    end
end

--- Ask the engine's health check which providers it uses, when voice is
-- available and it wasn't asked in the last 30 s (Settings and the mic
-- call this).
function voice.checkProviders()
    local now = gitgud.now()
    if not voice.backend.health or not voice.available()
        or (providersChecked and now - providersChecked < PROVIDERS_RECHECK_MS) then
        return
    end
    providersChecked = now
    voice.backend.health(function(h)
        if type(h) == "table" then
            setProviders({
                stt = h.sttProvider,
                tts = h.ttsProvider,
                sttFallback = h.sttFallback or "",
                ttsFallback = h.ttsFallback or "",
            })
        end
    end, function()
        providersChecked = nil
    end)
end

--- One line for Settings: who recognises ("stt") or speaks ("tts").
function voice.providerLine(direction)
    local name = providers[direction]
    local fallback = providers[direction .. "Fallback"]
    if not voice.available() then
        return "Off. " .. voice.unavailableText()
    elseif not name then
        return "Not known yet."
    elseif fallback then
        return name .. ", in place of the usual one: " .. fallback .. "."
    end
    return name .. "."
end

-- ===================================================================
-- Voices (Settings, Voice output: the picker)
-- ===================================================================

--- What the engine offers: { list = { {id, name, provider, available,
-- description, reason}, ... }, default = id, error = text }; list is nil until
-- known. `reason` says why a voice isn't available.
function voice.voices()
    return voices
end

--- Ask the engine for its voices, when voice is available and it wasn't
-- asked in the last 30 s (force: ask now). Publishes "bragi.voiceList" with
-- the answer.
function voice.checkVoices(force)
    local now = gitgud.now()
    if not voice.backend.voices or not voice.available()
        or (not force and voicesChecked and now - voicesChecked < PROVIDERS_RECHECK_MS) then
        return
    end
    voicesChecked = now
    voice.backend.voices(function(v)
        local list = {}
        for _, item in ipairs(type(v) == "table" and type(v.voices) == "table" and v.voices or {}) do
            if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
                list[#list + 1] = {
                    id = item.id,
                    name = type(item.name) == "string" and item.name ~= "" and item.name or item.id,
                    provider = type(item.provider) == "string" and item.provider or "",
                    available = item.available ~= false,
                    description = type(item.description) == "string" and item.description or nil,
                    reason = type(item.reason) == "string" and item.reason ~= "" and item.reason or nil,
                }
            end
        end
        voices = { list = list, default = type(v) == "table" and v.default or nil }
        app.publish("bragi.voiceList", voices)
    end, function(err)
        voices = { error = tostring(err or "No answer") }
        app.publish("bragi.voiceList", voices)
    end)
end

--- The voice in use: the chosen one if the engine lists it, else its default.
-- @return the voice's entry, or nil while the list isn't known
function voice.chosenVoice()
    if not voices.list then
        return nil
    end
    local chosen = text.trim(settings.get("bragi.voice", ""))
    local fallback = nil
    for _, v in ipairs(voices.list) do
        if v.id == chosen then
            return v
        elseif v.id == voices.default then
            fallback = v
        end
    end
    return fallback
end

--- The `voice` a `say` carries, or nil for the system's default. With no
-- voice chosen, Baldr (the first made voice) whenever its model is in: that
-- comes from this computer's own list, so the first reply after voice
-- starts is Baldr's even before the engine's voices list arrives
-- (it went to the Windows voice).
local function sayVoice()
    local chosen = text.trim(settings.get("bragi.voice", ""))
    if chosen ~= "" then
        if not voices.list then
            return chosen -- what the user picked, checked by the engine
        end
        local v = voice.chosenVoice()
        if v and v.id == chosen and v.available then
            return chosen
        end
    end
    local models = require("bragi.voicemodels")
    if models.turboReady() then
        local made = models.voices()[1]
        if made then
            return made.id
        end
    end
    if voices.list then
        local default = voices.default
        return type(default) == "string" and default:find("^turbo:") and default or nil
    end
    return nil
end

local PREVIEW_TEXT = "Hello, I'm Bragi. This is how I sound when I tell you what I found."

--- How fast Bragi speaks: bragi.speechSpeed, kept to 0.8..1.5 (1 is the
-- voice's normal pace). Goes as `speed` with every `say`.
function voice.speechSpeed()
    local speed = tonumber(settings.get("bragi.speechSpeed", "")) or SPEED_DEFAULT
    return math.max(SPEED_MIN, math.min(SPEED_MAX, speed))
end

--- Speak a short sample with a voice, stopping whatever plays.
-- @param id  a voice id from voice.voices()
-- @return true, or nil and why not
function voice.preview(id)
    local playing = voice.backend.playing()
    if playing then
        voice.backend.speakStop(playing)
    end
    previewCount = previewCount + 1
    local sayId = "preview" .. previewCount
    record("preview", { id = sayId, voice = id })
    local ok, err = voice.backend.speak(sayId, PREVIEW_TEXT, { voice = id, speed = voice.speechSpeed() })
    if not ok then
        return nil, tostring(err or "Couldn't speak")
    end
    return true
end

-- ===================================================================
-- Speaking replies
-- ===================================================================

local function words(s)
    local list = {}
    for w in tostring(s or ""):lower():gmatch("[%w']+") do
        list[#list + 1] = w
    end
    return list
end

local function plain(body)
    local s = tostring(body or "")
    s = s:gsub("```.-```", " (code on screen) ")
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("`([^`]*)`", "%1")
    s = s:gsub("[*_#>|]", "")
    return text.trim((s:gsub("%s+", " ")))
end

--- A reply as it should sound: no Markdown, code left on screen, long
-- ones cut to their first sentences.
-- @param body  the reply's Markdown
-- @return the text to speak ("" for nothing)
-- @param max   optional: characters kept (SPOKEN_MAX)
function voice.speakable(body, max)
    max = max or SPOKEN_MAX
    local s = plain(body)
    if #s <= max then
        return s
    end
    local cut = s:sub(1, max)
    local stop = cut:match(".*[%.%?!]()%s")
    return text.trim(stop and cut:sub(1, stop - 1) or (cut .. "...")) .. " The rest is on screen."
end

--- Whether text says the wake word as a word: "I'm Bragi." yes,
-- "Bragging rights." no.
function voice.mentionsWakeWord(s)
    local pattern = wakeWord():gsub("%a", function(c)
        return "[" .. c:lower() .. c:upper() .. "]"
    end):gsub("%s+", "%%s+")
    return (" " .. tostring(s or "") .. " "):find("%f[%w]" .. pattern .. "%f[^%w]") ~= nil
end

local NUMBER_WORDS = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen" }
local TENS_WORDS = { [2] = "twenty", [3] = "thirty", [4] = "forty", [5] = "fifty" }

--- 1 to 59 in words: "seven", "thirty-four".
local function numberWords(n)
    if n < 20 then
        return NUMBER_WORDS[n]
    end
    local tens, ones = n // 10, n % 10
    return TENS_WORDS[tens] .. (ones > 0 and ("-" .. NUMBER_WORDS[ones]) or "")
end

--- A clock time in words: 3, 34, "PM" -> "three thirty-four PM"; 15, 0
-- -> "three PM"; 9, 5 -> "nine oh five". Seconds are left out.
local function timeWords(h, m, suffix)
    if suffix == "" then
        if h > 12 then
            h, suffix = h - 12, "PM"
        elseif h == 0 then
            h, suffix = 12, "AM"
        end
    elseif h == 0 then
        h = 12
    end
    local said = numberWords(h)
    if m > 0 then
        said = said .. " " .. (m < 10 and ("oh " .. numberWords(m)) or numberWords(m))
    elseif suffix == "" then
        said = said .. " o'clock"
    end
    return said .. (suffix ~= "" and (" " .. suffix) or "")
end

--- Text as the voice should read it: clock times in words, since the
-- voice reads "3:34" as "three thousand thirty-four".
function voice.forSpeech(s)
    s = tostring(s or "")
    local out, pos = {}, 1
    while true do
        local i, j, hh, mm = s:find("%f[%w](%d%d?):(%d%d)%f[%D]", pos)
        if not i then
            break
        end
        local h, m = tonumber(hh), tonumber(mm)
        if h > 23 or m > 59 then
            out[#out + 1] = s:sub(pos, j)
        else
            local after = j + 1
            local _, secEnd = s:find("^:%d%d%f[%D]", after)
            after = secEnd and secEnd + 1 or after
            local suffix = ""
            -- "p.m." keeps its last dot: it may end the sentence.
            local _, sufEnd, ap = s:find("^%s*([AaPp])%.?[Mm]%f[%W]", after)
            if sufEnd then
                suffix, after = ap:upper() .. "M", sufEnd + 1
            end
            out[#out + 1] = s:sub(pos, i - 1) .. timeWords(h, m, suffix)
            j = after - 1
        end
        pos = j + 1
    end
    out[#out + 1] = s:sub(pos)
    return table.concat(out)
end

--- Whether Bragi can speak now: it speaks (not muted), and with the mic
-- off, the speech engine is there.
function guard.canSpeak()
    return voice.speaks() and (current ~= "off" or voice.available())
end

--- Speak a line (a reply's summary, a snippet, a hand-off) through `speak`:
-- only while listening, unless fields.offOk (news, said with the mic off
-- too), and never while muted.
speak = function(spoken, fields)
    spoken = voice.forSpeech(text.trim(tostring(spoken or "")))
    -- The conversation it's about (guard.cut stops it when you switch away).
    local about = fields.tab
    fields.tab = nil
    if spoken == "" or (current == "off" and not fields.offOk) then
        return
    end
    if voice.muted() then
        record("speak-muted", { chars = #spoken })
        return
    end
    replyCount = replyCount + 1
    local id = "r" .. replyCount
    fields.id = id
    fields.chars = #spoken
    fields.said = spoken -- what the voice was given, after forSpeech
    spokenText[id] = { text = spoken, message = lastEnded and lastEnded.id, narration = fields.narration,
        opening = fields.opening, at = gitgud.now(), tab = about }
    guard.lastSpoken = id -- the update cycle counts from when it's over
    if lastEnded then
        lastEnded.spoke = true
    end
    spokenText["r" .. (replyCount - 20)] = nil
    local options = { speed = voice.speechSpeed() }
    fields.speed = options.speed
    local name = sayVoice()
    if name then
        options.voice = name
        fields.voice = name
    end
    record("speak", fields)
    -- Never over the user (a reply started while they were
    -- still talking, and the mic took it into their message): held until the
    -- message being heard ends, then said in order.
    if hearing then
        guard.held = guard.held or {}
        guard.held[#guard.held + 1] = { id = id, spoken = spoken, options = options }
        record("speak-held", { id = id, hearing = hearing.id })
        if not guard.heldTimer then
            guard.heldTimer = gitgud.after(guard.HOLD_MAX_MS, function()
                guard.heldTimer = nil
                guard.flushHeld("timeout")
            end)
        end
        return id
    end
    local ok, err = voice.backend.speak(id, spoken, options)
    if not ok then
        agent.addMessage("note", "Couldn't speak the reply: " .. tostring(err), { error = true })
    end
    return id
end

--- Say what was held while the user spoke (speak), in order; once the
-- message has ended, what waited for it (guard.whenFree) goes next.
guard.HOLD_MAX_MS = 30000 -- a message this long: say them anyway
function guard.flushHeld(why)
    local held = guard.held
    guard.held = nil
    if guard.heldTimer then
        gitgud.cancelTimer(guard.heldTimer)
        guard.heldTimer = nil
    end
    for _, h in ipairs((held and current ~= "off" and not voice.muted()) and held or {}) do
        record("speak-released", { id = h.id, why = why })
        if spokenText[h.id] then
            spokenText[h.id].at = gitgud.now()
        end
        local ok, err = voice.backend.speak(h.id, h.spoken, h.options)
        if not ok then
            agent.addMessage("note", "Couldn't speak the reply: " .. tostring(err), { error = true })
        end
    end
    local waiting = why ~= "timeout" and not hearing and guard.afterHearing
    if waiting then
        guard.afterHearing = nil
        for _, fn in ipairs(waiting) do
            guard.whenFree(fn)
        end
    end
end

--- Speak a line as Bragi (while listening), like a reply's summary.
-- @return the reply id, or nil when voice is off
function voice.say(line)
    return speak(line, {})
end

local function summaryLength()
    return settings.get("bragi.summaryLength", "short") == "medium" and "medium" or "short"
end

local stopNarration
local dropQueuedNarration
local answerStreaming
local opener = nil          -- the latest message's opening line: { id, asking, text, at, dropped }

--- Whether a summary says the reply again instead of retelling it: JSON
-- (the request echoed), or most of its word triples are the reply's. A
-- short reply may be said nearly as it is.
local function echoes(summary, reply)
    local s = text.trim(summary)
    if s:sub(1, 1) == "{" then
        return true
    end
    local said, wrote = words(s), words(plain(reply))
    if #wrote < ECHO_REPLY_WORDS or #said < ECHO_SUMMARY_WORDS then
        return false
    end
    local triples = {}
    for i = 1, #wrote - 2 do
        triples[wrote[i] .. " " .. wrote[i + 1] .. " " .. wrote[i + 2]] = true
    end
    local found = 0
    for i = 1, #said - 2 do
        if triples[said[i] .. " " .. said[i + 1] .. " " .. said[i + 2]] then
            found = found + 1
        end
    end
    return found / (#said - 2) >= ECHO_TRIPLES
end

--- The agent answered: speak a summary of the reply, never the reply. One
-- that echoes the reply is asked for again, strictly, once; then the reply
-- is cut to its first sentence or two. A quick answer (bragi/quick.lua)
-- is spoken the same way, and the agent's turn, if one runs, is still
-- narrated.
local function onReply(reply)
    local tab = reply.tab
    if not reply.quick and (not tab or not narration or narration.tab == nil or narration.tab == tab) then
        guard.turnOver()
    end
    -- Told: a spoken message's, or one you typed (sent, or a quick
    -- question asked on screen), never a turn nobody sent.
    local sent = tab ~= nil and guard.sentTurn[tab] == true
    if tab and not reply.quick then
        guard.sentTurn[tab] = nil
    end
    local typed = not reply.voice and (sent or (reply.quick and tab ~= nil and tab == agent.current()))
    if reply.voice and not reply.replayed then
        timing("answer", { turnMs = reply.ms, quick = reply.quick })
        if lastEnded then
            lastEnded.answered = true
        end
        -- The answer is here: nothing narrated starts now.
        if opener and opener.asking then
            opener.dropped = true
        end
        dropQueuedNarration("answer")
    end
    if not (reply.voice or typed) or not guard.canSpeak() or plain(reply.text) == "" then
        return
    end
    if tab and reply.quick and tab == agent.current() then
        guard.setThread(tab, "asked")
    end
    if tab and not guard.told(tab) then
        -- Not on screen: told when you come back to it (guard.pickUp).
        guard.missed[tab] = { reply = reply }
        record("reply-missed", { about = tab.title })
        return
    end
    -- Told in blocks as it streamed, or read out: the rest goes as the
    -- last block ("Telling a long reply as it's written").
    local read = tab and guard.readAloud[tab]
    if tab then
        guard.readAloud[tab] = nil
    end
    if tab and not guard.tellingReply(tab) and read then
        guard.telling = { tab = tab, text = "", told = 0, parts = 0, said = {}, read = true }
    end
    if tab and guard.tellingReply(tab) then
        return guard.tellRest(guard.telling, reply)
    end
    local started = gitgud.now()
    local fields = { ms = reply.ms, quick = reply.quick }
    guard.summaryPending = started -- no update goes before it
    local function done(short, err)
        guard.summaryPending = nil
        fields.summaryMs = gitgud.now() - started
        fields.summarized = short ~= nil and text.trim(short) ~= ""
        timing("summary", { summaryMs = fields.summaryMs, retried = fields.retried })
        if tab and not guard.told(tab) then
            -- You switched away while it was being made.
            guard.missed[tab] = { reply = reply }
            record("reply-missed", { about = tab.title, summarized = fields.summarized })
            return
        end
        -- Narration not playing yet is dropped; one playing finishes its
        -- sentence, and the summary follows it.
        dropQueuedNarration("summary")
        local spoken
        if fields.summarized then
            spoken = plain(short)
        else
            fields.error = err
            spoken = voice.speakable(reply.text, SPOKEN_CUT)
        end
        fields.offOk, fields.tab, fields.typed = true, tab, typed or nil
        expectFollowUp(speak(spoken, fields), spoken, reply.tab)
    end
    local function ask(strict)
        askHelper(summarizer, { reply = reply.text, length = summaryLength(), strict = strict,
            said = guard.lately(3) },
            function(short, err)
                if short and echoes(short, reply.text) then
                    record("summary-echo", { text = short, strict = strict == true })
                    if strict then
                        fields.echoedAgain = true
                        return done(nil, "it echoed the reply")
                    end
                    fields.echoed = true
                    fields.retried = true
                    return ask(true)
                end
                done(short, err)
            end)
    end
    ask(nil)
end

-- ===================================================================
-- Timing a message
-- ===================================================================

local function onAnswering(e)
    closeFollowUp("turn")
    if e.voice then
        timing("firstEvent", { turnMs = e.ms })
    end
end

-- ===================================================================
-- Narration: what the agent is doing, spoken while it works
-- ===================================================================

-- Spoken updates: every step of every conversation
-- Bragi manages goes into bragi/updates.lua as it happens. While any of
-- them works, the narrator gets what's new across all of them and makes
-- one line of it: Bragi's own work in the first person, another
-- conversation by its name. When depends on bragi.updateSeconds (read each
-- time):
--   0 (the default): as it happens. Something worth telling is told
--     at once (asks at least ASK_GAP_MS apart, one at a time), also while
--     a line plays: the narrator gets the line said just before its own
--     (`speaking`: the one playing, or the one about to) and follows on
--     from it. A narration line waiting behind another when something new
--     comes is dropped and made again with its steps and the new ones
--     (`replacing`: what it would have said), at most REWRITES times; then
--     it plays. The line playing always finishes, and the next one up
--     (nothing ahead of it, only being made) is never remade.
--   3 to 120: that long after the last thing Bragi said has finished
--     playing. Nothing new: nothing said, and it looks again an interval
--     later.
-- News (a conversation done, failed, or waiting on you; below) is said at
-- once and an interval counts from it. With no turn and no managed
-- conversation working, the cycle stops.

local narration = nil       -- the update cycle: { tab, id, request (the voice turn's: nil once it's
                            -- over), said, asking, answering (its answer streams: nothing new starts),
                            -- checked (the buffer was last looked at), timer }

--- Stop the cycle (nothing works any more, or voice went off).
stopNarration = function()
    if narration then
        gitgud.cancelTimer(narration.timer)
        narration = nil
    end
    updates.clear()
end

--- True while the update cycle runs.
function voice.narrating()
    return narration ~= nil
end

local function narrationOn()
    return settings.get("bragi.narrate", true) and guard.canSpeak()
end

local approval = nil        -- the permission being asked aloud (Spoken approvals, below)

--- The interval between updates, in ms: 0 for as it happens
-- (bragiSettings.updateSeconds: 0, or 3 to 120 s).
function guard.updateMs()
    return require("bragi.settings").updateSeconds() * 1000
end

guard.ASK_GAP_MS = 1000 -- as it happens: the narrator asked at most this often
guard.REWRITES = 2      -- as it happens: a line not yet said is made again at most this often

--- Lines said and not heard yet (not started, not dropped, not stale),
-- oldest first: { id, entry } each.
local function unheard()
    local now, out = gitgud.now(), {}
    for id, s in pairs(spokenText) do
        if not s.started and not s.dropped and now - (s.at or 0) < NARRATE_STALE_MS then
            out[#out + 1] = { id = id, entry = s }
        end
    end
    table.sort(out, function(a, b)
        return a.entry.at < b.entry.at
    end)
    return out
end

--- The narration line that can still be made again (not an opening
-- line): the newest one waiting behind another line, playing or about
-- to. Its id and entry, or nil. The next one up, with nothing ahead of
-- it, plays as soon as it's made: never remade.
function guard.queuedNarration()
    local waiting = unheard()
    local last = waiting[#waiting]
    if not last or not last.entry.narration or last.entry.opening then
        return nil
    end
    if #waiting == 1 and not voice.backend.playing() then
        return nil
    end
    return last.id, last.entry
end

--- The line said just before a new one: the newest not heard yet, else
-- the one playing; never `skip` (the line the new one may replace). Its
-- entry, or nil.
function guard.lineAhead(skip)
    local waiting = unheard()
    for i = #waiting, 1, -1 do
        if waiting[i].entry ~= skip then
            return waiting[i].entry
        end
    end
    local id = voice.backend.playing()
    local s = id and spokenText[id] or nil
    return s ~= skip and s or nil
end

guard.START_WAIT_MS = 2500 -- a line not playing by then, with nothing else playing, is taken as lost

--- When the last line Bragi said finished playing, or nil while it plays
-- or waits to.
function guard.spokenEnd()
    local s = guard.lastSpoken and spokenText[guard.lastSpoken]
    if not s then
        return 0
    end
    if s.stoppedAt or s.dropped then
        return s.stoppedAt or s.at
    end
    local now = gitgud.now()
    if s.started then
        if voice.backend.playing() == guard.lastSpoken then
            return nil
        end
        s.stoppedAt = now -- its stop never came
        return now
    end
    if hearing or voice.backend.playing() or now - s.at < guard.START_WAIT_MS then
        return nil -- held, or queued behind another
    end
    return s.at + guard.START_WAIT_MS
end

--- Whether news is on its way: it goes first, and an update never right after it.
function guard.newsComing()
    return guard.newsTimer ~= nil or guard.newsAsking or #guard.news > 0
end

--- Whether to ask the narrator now: an interval after the last line
-- finished (as it happens: at once, while a line plays too, ASK_GAP_MS
-- after the last ask, and not for a line waiting that was made again
-- REWRITES times), and only when something new happened (no
-- "still working" filler; silence is fine); never while the answer
-- streams or is being summarized, news is coming, or a permission is
-- being asked.
local function narrationDue(n, now)
    if n.asking or n.answering or approval or hearing or guard.judgingNow() or guard.newsComing()
        or (guard.summaryPending and now - guard.summaryPending < NARRATE_STALE_MS) then
        return false
    end
    if guard.updateMs() == 0 then
        -- As it happens: something new, told now (while a line plays too).
        if now - (n.askedAt or 0) < guard.ASK_GAP_MS or not updates.worth() then
            return false
        end
        local _, queued = guard.queuedNarration()
        return not queued or (queued.rewrites or 0) < guard.REWRITES
    end
    if voice.backend.playing() then
        return false
    end
    local ended = guard.spokenEnd()
    if not ended or now - math.max(ended, n.checked or 0) < guard.updateMs() then
        return false
    end
    if not updates.worth() then
        n.checked = now -- nothing new: say nothing, look again an interval later
        return false
    end
    return true
end

-- Lines about narrating itself (Bragi said aloud it would
-- stay quiet because nothing was new). Never spoken.
local ABOUT_NARRATING = { "nothing new", "stay quiet", "staying quiet", "keep quiet", "keeping quiet", "stay silent",
    "staying silent", "no update", "no new update", "nothing to report", "nothing to say", "nothing worth",
    "say nothing", "i'll skip", "still working", "still looking", "narrat" }

--- A narrator's answer as a line to say ("" for nothing). Only a valid
-- `{"say": ...}` is a line; `{"skip": true}` is silence; anything else
-- (prose, a line about narrating) is dropped and logged.
local function snippetOf(reply)
    local s = text.trim(tostring(reply or ""))
    local first, last = s:find("{", 1, true), s:match(".*()}")
    local answer = first and last and gitgud.jsonDecode(s:sub(first, last))
    if type(answer) ~= "table" or (answer.skip ~= true and type(answer.say) ~= "string") then
        if s ~= "" then
            record("narrate-dropped", { text = s, why = "not a say" })
        end
        return ""
    end
    if answer.skip == true or type(answer.say) ~= "string" then
        return ""
    end
    local snippet = plain(answer.say)
    snippet = text.trim((snippet:gsub("^[\"\u{201C}](.*)[\"\u{201D}]$", "%1")))
    local lower = snippet:lower():gsub("\u{2019}", "'")
    for _, phrase in ipairs(ABOUT_NARRATING) do
        if lower:find(phrase, 1, true) then
            record("narrate-dropped", { text = snippet, why = "about narrating" })
            return ""
        end
    end
    return snippet == "-" and "" or snippet
end

-- Repeats ("looking into conversations", then a moment
-- later "looking into other conversations"). Each message's narration
-- started with nothing said, and so did its opening line: a message sent
-- after a turn (a note that waited), or one right after another, never
-- saw the lines just spoken, and only the model kept them apart. Lines
-- said in the last NARRATE_RECENT_MS are kept across messages: they go to
-- the narrator as `said`, and a line whose words (without the small words
-- below, and their endings) are mostly those of one of them is dropped.
guard.NARRATE_RECENT_MS = 90000
guard.REPEAT_SHARE = 0.75 -- of the shorter line's words found in the other: the same idea
guard.saidLately = {}     -- { text, at }, oldest first
guard.SMALL_WORDS = {}
for w in ([[i im ill ive id me my mine we our us you your the a an to into onto of for on in at by and
    or but is are was were be been being am it its this that these those other others another some any all
    each more most still again also then so now just only with about from up out over here there what
    which who how why when where sure okay ok got right yes yeah well let lets going go gonna will can
    should would look check see find get take try dig work doing do does done thing things bit one
    something]]):gmatch("%S+") do
    guard.SMALL_WORDS[w] = true
end

--- A line's words that carry its idea: lower case, without the small
-- words, "conversations" as "conversation", "looking" as "look".
function guard.ideaWords(line)
    local set, count = {}, 0
    local s = tostring(line or ""):lower():gsub("\u{2019}", "'"):gsub("'", "")
    for w in s:gmatch("%w+") do
        local stem = w
        if #w > 5 and w:sub(-3) == "ing" then
            stem = w:sub(1, -4)
        elseif #w > 4 and w:sub(-2) == "ed" then
            stem = w:sub(1, -3)
        elseif #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
            stem = w:sub(1, -2)
        end
        if not guard.SMALL_WORDS[w] and not guard.SMALL_WORDS[stem] and not set[stem] then
            set[stem] = true
            count = count + 1
        end
    end
    return set, count
end

--- The lines said lately, oldest first (at most `max`), without `except`
-- (a line waiting to be made again).
function guard.lately(max, except)
    local now, list = gitgud.now(), {}
    for _, s in ipairs(guard.saidLately) do
        if now - s.at < guard.NARRATE_RECENT_MS and s.text ~= except then
            list[#list + 1] = s.text
        end
    end
    while #list > max do
        table.remove(list, 1)
    end
    return list
end

--- A line was said: kept for the narrator's `said` and the repeat check.
function guard.noteSaid(line)
    local now, kept = gitgud.now(), {}
    for _, s in ipairs(guard.saidLately) do
        if now - s.at < guard.NARRATE_RECENT_MS then
            kept[#kept + 1] = s
        end
    end
    kept[#kept + 1] = { text = line, at = now }
    guard.saidLately = kept
end

--- A line said lately wasn't said after all (made again before it played).
function guard.unsay(line)
    for i = #guard.saidLately, 1, -1 do
        if guard.saidLately[i].text == line then
            table.remove(guard.saidLately, i)
            return
        end
    end
end

--- A line's sentences.
function guard.sentences(line)
    local list = {}
    for piece in (tostring(line or ""):gsub("([%.!%?]+)%s+", "%1\n") .. "\n"):gmatch("([^\n]*)\n") do
        local s = text.trim(piece)
        if s:find("%w") then
            list[#list + 1] = s
        end
    end
    return list
end

--- The line said lately that `line` repeats, or nil: the same words; all
-- of the shorter one's with at most one word more ("Sure, I'll check
-- what's still in flight", then "I'm checking the conversation to see
-- what's still in flight"); or (two words or more) most
-- of the shorter one's. Each sentence of a longer line said counts as a
-- line too. `near`: only a line about as long as the one said (most of
-- its words the same), so a short line isn't taken for a part of a long
-- one (news: the same long news four times with one
-- count changed). `except`: a line not counted (the one `line` replaces).
function guard.repeats(line, near, except)
    local words, count = guard.ideaWords(line)
    for _, earlier in ipairs(guard.lately(math.huge, except)) do
        local pieces = guard.sentences(earlier)
        if #pieces > 1 then
            table.insert(pieces, 1, earlier)
        else
            pieces = { earlier }
        end
        for _, piece in ipairs(pieces) do
            local other, otherCount = guard.ideaWords(piece)
            local shared = 0
            for w in pairs(words) do
                if other[w] then
                    shared = shared + 1
                end
            end
            local shorter = math.min(count, otherCount)
            local longer = math.max(count, otherCount)
            if (not near or shared >= guard.REPEAT_SHARE * longer)
                and ((shorter > 0 and shared == shorter and longer <= shorter + 1)
                    or (shorter >= 2 and shared / shorter >= guard.REPEAT_SHARE)) then
                return earlier
            end
        end
    end
    return nil
end

--- News without what repeats a line said lately (guard.repeats, `near`):
-- the whole of it, or each sentence. "" when nothing is left.
function guard.freshNews(said)
    if guard.repeats(said, true) then
        return ""
    end
    local all, kept = guard.sentences(said), {}
    for _, s in ipairs(all) do
        if not guard.repeats(s, true) then
            kept[#kept + 1] = s
        end
    end
    return #kept == #all and said or table.concat(kept, " ")
end

--- Ask the narrator for a line about what's new and speak it: `steps`,
-- Bragi's own, and `others`, the other conversations'. One that comes back
-- once the answer has started streaming is dropped, never said, and so is
-- one that repeats a line said lately, and one made while something else
-- was said (news, a reply: the interval counts from that).
local function askNarrator(n, opts)
    local own, others, count = updates.take()
    n.asking = true
    n.askedAt = gitgud.now()
    -- As it happens: a line not said yet is made again with what's new, and
    -- the new line follows on from the one said just before it. The line
    -- waiting stays queued until the new one is in hand: a skip, a repeat,
    -- or a line dropped leaves it to play.
    local queuedId, queued, replacing, rewrites = nil, nil, nil, 0
    if guard.updateMs() == 0 then
        queuedId, queued = guard.queuedNarration()
        if queued then
            replacing, rewrites = queued.text, (queued.rewrites or 0) + 1
            local told = queued.steps or {}
            for i = #(told.own or {}), 1, -1 do
                table.insert(own, 1, told.own[i])
            end
            for i = #(told.others or {}), 1, -1 do
                table.insert(others, 1, told.others[i])
            end
        end
    end
    local playingLine = guard.updateMs() == 0 and guard.lineAhead(queued) or nil
    local forTurn, before = n.tab, guard.lastSpoken
    local saidHere = #n.said
    for _, line in ipairs(n.said) do
        if line == replacing then
            saidHere = saidHere - 1
            break
        end
    end
    -- `first`: nothing said for this message yet (its line from the request).
    local payload = { request = n.request or "", steps = own, others = #others > 0 and others or nil,
        said = guard.lately(3, replacing), first = (n.request and saidHere == 0) or nil,
        catchUp = opts and opts.catchUp or nil, speaking = playingLine and playingLine.text or nil,
        replacing = replacing }
    local started = gitgud.now()
    askHelper(narrator, payload, function(reply)
        n.asking = false
        n.checked = gitgud.now()
        if narration ~= n or not narrationOn() or (forTurn and not forTurn.session.turn) then
            return -- the turn is over: the summary speaks now
        end
        if forTurn and not guard.told(forTurn) then
            record("narrate", { text = snippetOf(reply), said = false, why = "switched away" })
            return
        end
        local snippet = snippetOf(reply)
        local since = guard.lastSpoken ~= before and spokenText[guard.lastSpoken]
        -- Saying a spoken answer was heard ("Okay, renaming it") may share
        -- the opening line's words, and goes even once the reply streams.
        local answered = false
        for _, s in ipairs(own) do
            answered = answered or (s.kind == "permission" and s.answer ~= "waiting")
        end
        if snippet ~= "" and ((n.answering and not answered) or approval or guard.newsComing()
            or (since and not since.narration)) then
            record("narrate", { text = snippet, said = false, why = n.answering and "answering"
                or approval and "asking" or "news" })
            return
        end
        if snippet == "" then
            -- Nothing to say (or nothing usable): logged, so a quiet stretch
            -- can be told from one where nothing was asked.
            record("narrate", { said = false, why = "skipped", steps = count,
                others = #others > 0 and #others or nil, speaking = payload.speaking })
            return
        end
        -- The line it replaces, if that's still waiting (not played meanwhile).
        local waiting = queued and not queued.started and not queued.dropped and replacing or nil
        local same = not answered and guard.repeats(snippet, nil, waiting)
        if same then
            record("narrate-dropped", { text = snippet, why = "repeats", said = same })
            return
        end
        if waiting then
            queued.dropped = true
            voice.backend.speakStop(queuedId)
            guard.unsay(waiting)
            for i = #n.said, 1, -1 do
                if n.said[i] == waiting then
                    table.remove(n.said, i)
                    break
                end
            end
            record("narrate-rewrite", { reply = queuedId, text = waiting, rewrites = rewrites })
        else
            rewrites = 0
        end
        n.said[#n.said + 1] = snippet
        guard.noteSaid(snippet)
        local id = speak(snippet, { narration = true, offOk = true, tab = forTurn })
        if id and spokenText[id] then
            -- What it told, should it be made again (as it happens).
            spokenText[id].steps = { own = own, others = others }
            spokenText[id].rewrites = rewrites
        end
        timing("narration", { text = snippet })
        record("narrate", { text = snippet, ms = lastEnded and (gitgud.now() - lastEnded.at) or nil,
            askMs = gitgud.now() - started, steps = count, others = #others > 0 and #others or nil,
            speaking = payload.speaking, replacing = replacing })
    end)
end

--- The voice turn is over (its answer came, or it ended): the cycle goes on
-- for the other conversations, if any work.
function guard.turnOver()
    local n = narration
    if n then
        if n.tab then
            updates.clear(n.tab)
        end
        n.tab, n.id, n.request, n.answering = nil, nil, nil, false
    end
end

local function narrateTick()
    local n = narration
    if not n then
        return
    end
    if not narrationOn() then
        return stopNarration()
    end
    if n.tab and not n.tab.session.turn then
        guard.turnOver()
    end
    if not n.tab and not updates.active() and not updates.waiting() then
        return stopNarration()
    end
    if narrationDue(n, gitgud.now()) then
        askNarrator(n)
    end
end

--- Start the cycle, when it isn't running. The first update comes an
-- interval from now at the soonest.
function guard.startCycle()
    if narration or not narrationOn() then
        return
    end
    narration = { said = {}, checked = gitgud.now(), timer = gitgud.every(NARRATE_TICK_MS, narrateTick) }
    record("updates", { on = true, seconds = guard.updateMs() / 1000 })
end

--- Narration said but not yet playing: dropped, so nothing starts once the
-- answer is coming. One already playing finishes (the engine plays says in
-- order, so the summary follows it); never cut mid-word.
dropQueuedNarration = function(why)
    local now = gitgud.now()
    for id, s in pairs(spokenText) do
        if s.narration and not s.started and not s.dropped and now - (s.at or 0) < NARRATE_STALE_MS then
            s.dropped = true
            voice.backend.speakStop(id)
            record("narrate-dropped", { reply = id, text = s.text, why = why })
        end
    end
end

--- The answer started streaming: no new narration from now until a new
-- tool step shows the model went back to work.
answerStreaming = function()
    local n = narration
    if n and n.tab and not n.answering then
        n.answering = true
        updates.clear(n.tab)
        -- Lines already said still play (the answer's first words often
        -- come a moment after a line about the work); nothing new starts.
    end
    if opener and opener.asking then
        opener.dropped = true
    end
end

-- ===================================================================
-- Telling a long reply as it's written
-- ===================================================================
--
-- A reply is told while it streams, a block at a time, so a long one
-- starts within seconds, not after the agent has finished: once
-- TELL_FIRST_WORDS words of the answer have come and a paragraph ends after
-- them (else, with twice that many, a sentence), that block is retold
-- (prompts/spoken-reply.md, its `part`) and spoken while the rest streams;
-- each block after it once it has TELL_WORDS. Each is told with what was
-- said of the reply before it (`told`) and the line playing (`speaking`),
-- so it carries on instead of starting over. As with narration as it
-- happens, a block's line still waiting behind another when the next
-- block is ready is made again with both (`replacing`), at most
-- guard.REWRITES times. The rest comes with the reply (onReply): the last
-- block, and only its line may open a follow-up. A reply shorter than a
-- block is retold whole, as before.
--
-- Read aloud: a reply to a message the filter says asks to hear something
-- in full (`read_aloud`: a story, a file read out) is read, not retold,
-- in the same blocks (no Markdown; a code block's text is read too).
--
-- A wake while a line plays pauses the telling (the lines waiting are
-- dropped), and the barge-in classifier says what comes of it: `resume`
-- picks it up again from the sentence it stopped in; anything else ends it
-- (the rest is on screen). Text before a tool step was the agent talking
-- while it works: what was told of it stays told, and the answer starts
-- again after the tool.

guard.TELL_FIRST_WORDS = 60
guard.TELL_WORDS = 120
guard.CHARS_PER_SECOND = 16 -- spoken at speed 1: how far a line got before it was cut (resume)
guard.readAloud = {}        -- tab -> true: its reply is read out (the filter's read_aloud)
guard.telling = nil         -- { tab, text, told (chars of text told), parts, said, asking, read, paused,
                            -- parked, over, final, lastId }

--- Where a block of `s` ends (its last character), or nil while it's
-- too short: after `min` words, at the first paragraph break; with twice
-- that many and no break, at the last sentence end after them. Never
-- inside a code block.
function guard.blockEnd(s, min)
    local count, at = 0, nil
    for pos in s:gmatch("()%S+") do
        count = count + 1
        if count == min then
            at = pos
        end
    end
    if not at then
        return nil
    end
    local function outside(i)
        local fences = 0
        for _ in s:sub(1, i):gmatch("```") do
            fences = fences + 1
        end
        return fences % 2 == 0
    end
    local from = at
    while true do
        local i, j = s:find("\n[ \t]*\n", from)
        if not i then
            break
        end
        if outside(i) then
            return j
        end
        from = j + 1
    end
    if count < 2 * min then
        return nil
    end
    local last = nil
    for e in s:gmatch("[%.!%?][\"')%]]*()%s", at) do
        if outside(e) then
            last = e - 1
        end
    end
    return last
end

--- A block as it's read out: what a code block holds is read too (a file
-- asked for is often in one), without its fences or the Markdown.
function guard.readable(s)
    return plain((tostring(s or ""):gsub("```[%w%-%+]*", "")))
end

--- The block line waiting behind another (playing, or waiting too), which
-- can still be made again: its id and entry, or nil.
function guard.queuedBlock()
    local waiting = unheard()
    local last = waiting[#waiting]
    if not last or not last.entry.telling then
        return nil
    end
    if #waiting == 1 and not voice.backend.playing() then
        return nil
    end
    return last.id, last.entry
end

--- Speak a block's line. The last one may open a follow-up.
function guard.tellLine(t, line, block, last, rewrites)
    if (guard.telling ~= t and not t.finishing) or t.over then
        return
    end
    if t.paused then
        t.parked = { line = line, block = block, last = last, rewrites = rewrites }
        return
    end
    if line ~= "" then
        t.said[#t.said + 1] = line
        local id = speak(line, { tell = t.parts, read = t.read or nil, last = last or nil, offOk = true,
            tab = t.tab })
        if id and spokenText[id] then
            spokenText[id].telling = true
            spokenText[id].block = block
            spokenText[id].rewrites = rewrites
            t.lastId = id
        end
    end
    if last then
        if guard.telling == t then
            guard.telling = nil
        end
        if t.lastId and spokenText[t.lastId] then
            expectFollowUp(t.lastId, spokenText[t.lastId].text, t.tab)
        end
    end
end

--- Tell what's come of the reply that makes a block, when nothing is
-- being made.
function guard.tellDue(t)
    if (guard.telling ~= t and not t.finishing) or t.asking or t.paused or t.over then
        return
    end
    if t.final then
        return guard.tellRest(t, t.final)
    end
    local rest = t.text:sub(t.told + 1)
    local e = guard.blockEnd(rest, t.parts == 0 and guard.TELL_FIRST_WORDS or guard.TELL_WORDS)
    if e then
        t.told = t.told + e
        guard.tellBlock(t, rest:sub(1, e), false)
    end
end

--- Tell a block: read out, or retold (with the line still waiting for the
-- one before it, made again with both).
function guard.tellBlock(t, block, last)
    local replacing, rewrites = nil, 0
    local queuedId, queued = guard.queuedBlock()
    if queued and not t.read and (queued.rewrites or 0) < guard.REWRITES then
        queued.dropped = true
        voice.backend.speakStop(queuedId)
        block = queued.block .. "\n\n" .. block
        replacing, rewrites = queued.text, (queued.rewrites or 0) + 1
        for i = #t.said, 1, -1 do
            if t.said[i] == queued.text then
                table.remove(t.said, i)
                break
            end
        end
        record("tell-rewrite", { reply = queuedId, text = queued.text, rewrites = rewrites })
    end
    t.parts = t.parts + 1
    if t.read then
        local line = guard.readable(block)
        record("tell", { part = t.parts, read = true, chars = #line, last = last or nil })
        return guard.tellLine(t, line, block, last, 0)
    end
    local part = (t.parts == 1 and not replacing) and "first" or "middle"
    if last then
        part = "last"
    end
    local ahead = guard.lineAhead()
    local payload = { reply = block, length = summaryLength(), part = part, request = t.request,
        told = #t.said > 0 and t.said or nil, speaking = ahead and ahead.text or nil, replacing = replacing }
    t.asking = true
    guard.summaryPending = gitgud.now()
    local started = gitgud.now()
    askHelper(summarizer, payload, function(reply, err)
        t.asking = false
        guard.summaryPending = nil
        local line = type(reply) == "string" and plain(reply) or ""
        if line == "" or line:sub(1, 1) == "{" then
            line = voice.speakable(block, SPOKEN_CUT)
        end
        if t.parts == 1 then
            timing("summary", { summaryMs = gitgud.now() - started, part = part })
        end
        record("tell", { part = t.parts, kind = part, ms = gitgud.now() - started, said = line, error = err,
            replacing = replacing, speaking = payload.speaking })
        guard.tellLine(t, line, block, last, rewrites)
        guard.tellDue(t)
    end)
end

--- A piece of a reply's text as it streams.
function guard.answerPiece(tab, piece)
    local t = guard.telling
    if t and t.tab == tab and t.over then
        return -- cut short: the rest is on screen
    end
    if not guard.canSpeak() or not guard.told(tab) then
        return
    end
    if not t or t.tab ~= tab or t.finishing then
        t = { tab = tab, text = "", told = 0, parts = 0, said = {}, read = guard.readAloud[tab] == true,
            request = narration and narration.tab == tab and narration.request or nil }
        guard.telling = t
    end
    t.text = t.text .. tostring(piece or "")
    guard.tellDue(t)
end

--- A tool step: the text before it was the agent talking while it works.
function guard.answerAgain(tab)
    local t = guard.telling
    if t and t.tab == tab and not t.over then
        t.text, t.told = "", 0
    end
end

--- Whether the reply to a conversation is being told in blocks.
function guard.tellingReply(tab)
    local t = guard.telling
    return t ~= nil and t.tab == tab and (t.parts > 0 or t.asking or t.read or t.over)
end

--- The reply came: what's left of it is told, as the last block. Waits
-- for a block being made, or for a pause to be settled.
function guard.tellRest(t, reply)
    t.final = reply
    if t.asking and guard.telling == t then
        t.finishing = true -- its last block goes, whatever comes next
    end
    if t.over then
        if guard.telling == t then
            guard.telling = nil
        end
        return
    end
    if t.asking or t.paused then
        return
    end
    t.final = nil
    local full = tostring(reply.text or "")
    local rest = full
    if t.told > 0 and full:sub(1, t.told) == t.text:sub(1, t.told) then
        rest = full:sub(t.told + 1)
    end
    if #words(plain(rest)) == 0 then
        return guard.tellLine(t, "", "", true, 0)
    end
    if t.read then
        -- Read out in blocks all the same: the voice starts on the first.
        while true do
            local e = guard.blockEnd(rest, guard.TELL_WORDS)
            if not e or e >= #rest then
                break
            end
            guard.tellBlock(t, rest:sub(1, e), false)
            rest = rest:sub(e + 1)
        end
    end
    guard.tellBlock(t, rest, true)
end

--- A reply told aloud was cut short by a wake: it waits for what the
-- message is (guard.resumeTelling, guard.endTelling).
function guard.pauseTelling(playing)
    local cut = playing and spokenText[playing]
    local waiting = {}
    for _, w in ipairs(unheard()) do
        if w.entry.telling and w.entry ~= cut then
            waiting[#waiting + 1] = w.entry.text
        end
    end
    local startedAt = cut and cut.startedAt
    guard.cutShort = cut and { text = cut.text, ms = startedAt and (gitgud.now() - startedAt) or 0,
        waiting = waiting } or nil
    local t = guard.telling
    if t and not t.over then
        t.paused = true
    end
end

--- The wake was to hear the rest ("never mind, go on"): the line cut short
-- again from the sentence it stopped in, the lines that waited, and the
-- telling goes on. False when nothing was cut short.
function guard.resumeTelling()
    local cut = guard.cutShort
    guard.cutShort = nil
    if not cut then
        return false
    end
    local sentences = guard.sentences(cut.text)
    local reached = cut.ms / 1000 * guard.CHARS_PER_SECOND * voice.speechSpeed()
    local from, chars = #sentences, 0
    for i, sentence in ipairs(sentences) do
        chars = chars + #sentence + 1
        if chars > reached then
            from = i
            break
        end
    end
    local again = table.concat(sentences, " ", math.max(1, from))
    record("resume", { from = from, sentences = #sentences, ms = cut.ms })
    local t = guard.telling
    local lines = { again }
    for _, line in ipairs(cut.waiting) do
        lines[#lines + 1] = line
    end
    local lastId = nil
    for _, line in ipairs(lines) do
        local id = speak(line, { resumed = true, offOk = true, tab = t and t.tab })
        if id and spokenText[id] then
            spokenText[id].telling = t ~= nil
            spokenText[id].block = line
            lastId = id
        end
    end
    if t then
        t.lastId = lastId or t.lastId
        t.paused = false
        local parked = t.parked
        t.parked = nil
        if parked then
            guard.tellLine(t, parked.line, parked.block, parked.last, parked.rewrites)
        end
        if guard.telling == t then
            guard.tellDue(t)
        end
    elseif lastId then
        expectFollowUp(lastId, spokenText[lastId].text)
    end
    return true
end

--- The wake was for something else: the rest of the reply stays on screen.
function guard.endTelling(why)
    guard.cutShort = nil
    local t = guard.telling
    if not t then
        return
    end
    t.over = true
    t.paused = false
    t.parked = nil
    record("tell-ended", { why = why, parts = t.parts })
    if t.final or not (t.tab and t.tab.session.turn) then
        guard.telling = nil
    end
end

--- A spoken message went to the agent: its turn joins the update cycle.
-- Its opening line (sayOpening) counts as the first snippet; a message
-- without one starts with a line from the request itself.
-- @param request  the message as sent
-- @param id       its message id
startNarration = function(request, id)
    local tab = agent.current()
    if not narrationOn() or not tab.session.turn then
        return
    end
    guard.startCycle()
    local n = narration
    n.tab, n.id, n.request, n.said, n.answering = tab, id, request, {}, false
    local o = opener
    if o and id and o.id == id then
        if o.asking then
            n.asking = true -- its line comes first; sayOpening clears this
        elseif o.text then
            n.said = { o.text }
        end
        return
    end
    if not n.asking then
        askNarrator(n)
    end
end

--- Say a message's opening line, once it's made and the filter passed the
-- message. Not once the message is dropped or answered, or while a new one
-- is being heard.
function guard.speakOpening(o)
    local line = o.line
    o.line = nil
    local ended = lastEnded
    if opener ~= o or o.dropped or not line or line == "" or current == "off" or hearing or not ended
        or ended.id ~= o.id or ended.dropped or ended.answered then
        record("opening", { id = o.id, text = line, said = false, askMs = o.askMs })
        return
    end
    local same = guard.repeats(line)
    if same then
        record("narrate-dropped", { text = line, why = "repeats", said = same, opening = true })
        return
    end
    o.text = line
    o.at = gitgud.now()
    local n = narration
    if n and n.id == o.id then
        n.said[#n.said + 1] = line
    end
    guard.noteSaid(line)
    speak(line, { narration = true, opening = true })
    timing("opening", { text = line, askMs = o.askMs, early = o.early or nil }, o.id)
    record("narrate", { text = line, ms = o.at - ended.at, askMs = o.askMs, opening = true, early = o.early or nil })
end

--- A message's opening line: that it was heard, in a line the narrator
-- makes ("Sure, checking the time"). Never canned. Asked the moment the
-- message ends, from the text as heard, side by side with the filter
-- (`early`), and said once the filter passes it, when what goes to the
-- agent has the same words; else made again from the checked text (a
-- line from the raw transcript said "Bot Desktop" for "Claude Desktop").
-- @param body   the message: as heard (early), or as it goes to the agent
-- @param id     its message id
-- @param early  asked before the filter answered
local function sayOpening(body, id, early)
    opener = nil
    if not narrationOn() then
        return
    end
    local o = { id = id, asking = true, wanted = true, from = body, early = early }
    opener = o
    local started = gitgud.now()
    timing("openingAsked", { early = early or nil }, id)
    askHelper(narrator, { request = body, steps = {}, said = guard.lately(3), opening = true }, function(reply)
        o.asking = false
        o.askMs = gitgud.now() - started
        o.line = snippetOf(reply)
        local n = narration
        if n and n.id == id then
            n.asking = false
        end
        if not early or o.passed then
            guard.speakOpening(o)
        end
    end)
end

--- Two texts with the same words (case and punctuation aside).
function guard.sameWords(a, b)
    return table.concat(words(a), " ") == table.concat(words(b), " ")
end

--- The filter passed a message on: its opening line, when takeMessage
-- wanted one: the early one when the checked text has the same words,
-- else one made from it.
-- @param m     the message
-- @param body  its checked text
openAfterFilter = function(m, body)
    local o = opener
    if not (o and o.wanted and o.id == m.id) then
        return
    end
    if o.early and guard.sameWords(o.from, body) then
        o.passed = true
        if not o.asking then
            guard.speakOpening(o)
        end
        return
    end
    if o.early then
        record("opening", { id = m.id, text = o.line, said = false, why = "repaired" })
    end
    sayOpening(body, m.id)
end

-- Commands that only serve the work itself (reading the clock to stamp a
-- check, the folder, who's signed in): never narrated, nor a sign the
-- model went back to work (a `date` was read out).
guard.SHELL_TOOLS = { Bash = true, PowerShell = true }
guard.INCIDENTAL = { "^date%f[%W]", "^get%-date", "^time%f[%W]", "^pwd%f[%W]", "^get%-location",
    "^whoami", "^hostname", "^echo %$pwd" }

function guard.incidental(step)
    if step.kind ~= "tool" or not guard.SHELL_TOOLS[step.name] or not step.summary then
        return false
    end
    local command = text.trim(tostring(step.summary)):lower()
    for _, pattern in ipairs(guard.INCIDENTAL) do
        if command:find(pattern) then
            return true
        end
    end
    return false
end

--- A step of the agent's voice turn ("bragi.activity", bragi/agent.lua).
local function onActivity(step)
    if type(step) ~= "table" then
        return
    end
    if step.kind == "text" then
        -- The answer is being written: nothing narrated starts over it.
        return answerStreaming()
    end
    if not narration or guard.incidental(step) then
        return
    end
    if step.kind == "tool" and not (step.starting and guard.SHELL_TOOLS[step.name]) then
        -- Back to work: that text wasn't the answer (a command, once it's
        -- known not to be incidental).
        narration.answering = false
    end
end

--- A step of any conversation ("bragi.step", bragi/agent.lua): kept for
-- the next update when Bragi manages it, unless it's incidental.
function guard.onStep(e)
    if type(e) ~= "table" or type(e.step) ~= "table" then
        return
    end
    -- The reply to what you sent is told as it's written.
    local tab = e.tab
    if tab and (guard.sentTurn[tab] or (tab.session and tab.session.voiceTurn)) then
        if e.step.kind == "text" then
            guard.answerPiece(tab, e.step.text)
        elseif e.step.kind == "tool" and not (e.step.starting and guard.SHELL_TOOLS[e.step.name])
            and not guard.incidental(e.step) then
            guard.answerAgain(tab)
        end
    end
    if not narrationOn() then
        return
    end
    if not updates.managed(e.tab) then
        -- Not told now: kept for when you come back to it, when it's one you
        -- sent work to.
        if e.tab and guard.sentTurn[e.tab] and e.step.kind ~= "text" and not guard.incidental(e.step) then
            local m = guard.missed[e.tab] or {}
            guard.missed[e.tab] = m
            m.steps = m.steps or {}
            local prev = m.steps[#m.steps]
            if prev and prev.starting and prev.name == e.step.name and not e.step.starting then
                m.steps[#m.steps] = e.step -- the tool that just started, now with its input
            else
                m.steps[#m.steps + 1] = e.step
            end
            while #m.steps > updates.MAX_STEPS do
                table.remove(m.steps, 1)
            end
        end
        return
    end
    if e.tab == updates.thread and narration and narration.tab == e.tab and not e.tab.session.voiceTurn then
        -- A typed turn's answer (a spoken one's comes as bragi.activity).
        if e.step.kind == "text" then
            return answerStreaming()
        elseif e.step.kind == "tool" then
            narration.answering = false
        end
    end
    if guard.incidental(e.step) then
        -- Its "starting" entry (name only) goes too.
        return updates.dropStarting(e.tab, e.step.name)
    end
    if e.step.kind ~= "text" then
        guard.startCycle()
        updates.add(e.tab, e.step)
    end
end

-- ===================================================================
-- Whose work is told
-- ===================================================================
--
-- Bragi tells one conversation's work as its own, in the first person:
-- the thread (updates.thread). A message you send there, typed or spoken
-- ("bragi.sent"), makes it the thread: its work is narrated, starting with
-- a line from the request, and its reply retold aloud. Only the
-- conversation on screen is told: showing another one cuts what's being
-- said about the old one (what plays stops, a line or summary on its way
-- is dropped) and makes the one shown the thread. Coming back picks up
-- where it is, newest first: its reply when it came while you were away,
-- else, while it still works, one line from the steps you missed
-- (`catchUp`), then updates as usual.
--
-- With bragi.narrateAway on, the thread keeps being told after you switch
-- away, until you send to another conversation, or it has nothing left
-- to tell (no turn, no summary on its way): then the one shown takes over.
-- The conversations Bragi follows (bragi/master.lua) are told as before:
-- their updates by name, their news at once.

guard.sentTurn = {} -- tab -> true: its turn was sent by you (its reply is told)
guard.missed = {}   -- tab -> { steps, reply }: what happened while it wasn't told

--- Whether to keep telling a conversation after you switch away.
function guard.keepAway()
    return settings.get("bragi.narrateAway", false) == true
end

--- Whether a conversation's own work is told now.
function guard.told(tab)
    return tab ~= nil and tab == updates.thread
end

--- Whether a conversation still has something to tell: its turn runs, or
-- its reply's summary is being made.
function guard.stillTelling(tab)
    return tab ~= nil and tab.session ~= nil and (tab.session.turn or guard.summaryPending ~= nil)
end

--- Stop telling a conversation: what plays about it stops, what waits to
-- play is dropped, and its updates go.
function guard.cut(tab, why)
    local now, playing = gitgud.now(), voice.backend.playing()
    for id, s in pairs(spokenText) do
        if s.tab == tab and not s.dropped and not s.stoppedAt
            and (id == playing or (not s.started and now - (s.at or 0) < NARRATE_STALE_MS)) then
            s.dropped = true
            voice.backend.speakStop(id)
            record("speak-cut", { reply = id, text = s.text, why = why })
        end
    end
    updates.clear(tab)
    local n = narration
    if n and n.tab == tab then
        guard.turnOver()
    end
    if guard.telling and guard.telling.tab == tab then
        guard.endTelling(why)
    end
end

--- Make a conversation the thread (nil: none), cutting the one before.
function guard.setThread(tab, why)
    local old = updates.thread
    if old == tab then
        return
    end
    updates.thread = tab
    if old then
        guard.cut(old, why)
    end
    record("thread", { about = tab and tab.title or nil, why = why })
end

--- The last thing you sent in a conversation, for the narrator's `request`.
function guard.lastAsked(tab)
    for i = #(tab.items or {}), 1, -1 do
        local item = tab.items[i]
        if item.kind == "user" and (item.text or "") ~= "" then
            return item.text
        end
    end
    return ""
end

--- Pick a conversation back up as it's shown: its missed reply, else
-- (while it works) a line from the steps missed, then updates as usual.
function guard.pickUp(tab)
    local m = guard.missed[tab]
    guard.missed[tab] = nil
    if not narrationOn() then
        return
    end
    if m and m.reply and not tab.session.turn then
        record("pick-up", { about = tab.title, reply = true })
        guard.sentTurn[tab] = true -- told as the reply to what you sent
        m.reply.replayed = true
        return onReply(m.reply)
    end
    if not tab.session.turn then
        return
    end
    guard.startCycle()
    local n = narration
    if not n then
        return
    end
    n.tab, n.id, n.request, n.said, n.answering = tab, nil, guard.lastAsked(tab), {}, false
    local steps = m and m.steps or {}
    record("pick-up", { about = tab.title, steps = #steps })
    if #steps > 0 then
        for _, step in ipairs(steps) do
            updates.add(tab, step)
        end
        if not n.asking then
            askNarrator(n, { catchUp = true })
        end
    end
end

--- Another conversation is on screen.
function guard.onShown(tab)
    local old = updates.thread
    if tab == old then
        return
    end
    if old and guard.keepAway() and guard.stillTelling(old) then
        record("thread", { about = old.title, why = "kept while away" })
        return
    end
    guard.setThread(tab, "switched")
    guard.pickUp(tab)
end

--- You sent a message: its conversation is the thread, and a typed one's
-- work is told from its first line (a spoken one's from its opening line).
function guard.onSent(e)
    if type(e) ~= "table" or not e.tab then
        return
    end
    local tab = e.tab
    guard.sentTurn[tab] = true
    guard.missed[tab] = nil
    local t = guard.telling
    if t and t.tab == tab then
        -- The last reply's: its last block may still be on its way, and
        -- this one's is told afresh.
        if t.final or t.asking then
            t.finishing = true
        else
            guard.telling = nil
        end
    end
    guard.setThread(tab, "sent")
    if e.voice or not narrationOn() or not tab.session.turn then
        return
    end
    guard.startCycle()
    local n = narration
    if not n then
        return
    end
    n.tab, n.id, n.request, n.said, n.answering = tab, nil, tostring(e.body or ""), {}, false
    if not n.asking then
        askNarrator(n)
    end
end

-- ===================================================================
-- Hearing itself
-- ===================================================================

--- Whether heard words are Bragi's own reply coming back.
local function isEcho(heard, spoken)
    local said = {}
    for _, w in ipairs(words(spoken)) do
        said[w] = true
    end
    local list = words(heard)
    if #list == 0 then
        return false
    end
    local found = 0
    for _, w in ipairs(list) do
        if said[w] then
            found = found + 1
        end
    end
    return found / #list >= ECHO_SHARE
end

--- What's playing, or played a moment ago: { id, text }, or nil.
local function recentSpeech()
    local id = voice.backend.playing()
    if not id and playback and playback.stopped and gitgud.now() - playback.stopped < ECHO_AFTER_MS then
        id = playback.id
    end
    if not id then
        return nil
    end
    local said = spokenText[id]
    return { id = id, text = said and said.text or "", playing = voice.backend.playing() ~= nil }
end

--- Whether a lookback line is Bragi's own voice: mostly something it said.
function guard.saidByBragi(line)
    if #words(line) < HEARD.ECHO_MIN_WORDS then
        return false
    end
    for _, said in pairs(spokenText) do
        if isEcho(line, said.text) then
            return true
        end
    end
    return false
end

-- ===================================================================
-- Spoken approvals
-- ===================================================================
--
-- While listening, outside auto mode, a permission card in the shown
-- conversation is also asked aloud: the narrator makes one short question
-- from the tool and its input ("Can I run git log to check the recent
-- commits?"). Once it has been said, an answer window opens
-- (bragi.approvalSeconds, 12 s): the next thing the user says, without the wake
-- word (an `ambient` utterance, whoever says it), is the answer. The approval classifier (prompts/approval.md) calls it allow,
-- deny, or unclear; it never allows on a guess. A yes with a remark ("Yes,
-- but it should already be dark.") is allow, and their words go to the
-- agent right after (agent.remark). Unclear: Bragi asks once more,
-- briefly, and the window opens again; unclear again, or no answer in
-- time: the card stays, and Bragi says once "I'll leave that on screen."
-- Clicking Allow or Deny closes the window. Several requests are asked one
-- at a time, in order. Logged as `ask`, `answer`, and `decision` lines.
-- bragi.voiceApprovals turns it off.
--
-- Anything said while a window is open counts, unless it's Bragi's own
-- words coming back. A message (wake word or not) while a card waits,
-- asked aloud or left on screen, goes to that card's classifier first: a
-- yes or no (or a pick) answers the card, anything else goes on as a
-- message, and then it only stops the agent when it's a clear stop (the
-- card stays for anything else).

local APPROVAL_SECONDS = 12     -- bragi.approvalSeconds when unset
local APPROVAL_START_MS = 8000  -- the question never started playing: open the window anyway
local APPROVAL_VERDICTS = { allow = true, deny = true }
local FILLER = { um = true, uh = true, erm = true, hmm = true, hm = true, mm = true, ah = true, er = true }

local approvals = {}        -- permission items waiting to be asked, oldest first
local approvalCount = 0
-- Helpers for answers to cards (2026-10-17), kept in a table: this chunk
-- is near Lua's limit of 200 locals.
local cards = {
    AGAIN = "Sorry, yes or no?",                  -- asked once more after an unclear answer
    AGAIN_QUESTION = "Sorry, what's your answer?", -- the same for a question card
}

--- Seconds the answer window stays open (the setting, kept to 5..60).
function voice.approvalSeconds()
    local seconds = tonumber(settings.get("bragi.approvalSeconds", "")) or APPROVAL_SECONDS
    return math.max(5, math.min(60, seconds))
end

--- Whether a card is asked aloud now: Claude's questions in any mode,
-- permissions outside auto mode.
local function approvalsOn(item)
    if current == "off" or settings.get("bragi.voiceApprovals", true) == false
        or not voice.speaks() then
        return false
    end
    if item and item.kind == "question" then
        return true
    end
    local mode = settings.get("bragi.mode", "default")
    return mode ~= "auto" and mode ~= "bypassPermissions"
end

--- True while a permission question is being asked or answered.
function voice.approving()
    return approval ~= nil
end

local askNextApproval

local function closeApproval(a)
    if approval ~= a then
        return
    end
    if a.timer then
        gitgud.cancelTimer(a.timer)
    end
    if a.fallback then
        gitgud.cancelTimer(a.fallback)
    end
    approval = nil
    if current ~= "off" and not hearing then
        setState(current)
    end
    askNextApproval()
end

--- The narrator is told how a permission was answered, so a tool refused
-- (or still waiting) is never told as running.
local function tellAnswer(a, answer, choice)
    local tab = narration and narration.tab or agent.current()
    if tab then
        updates.add(tab, { kind = "permission", tool = a.item.tool, summary = choice and a.question or a.item.summary,
            answer = answer, choice = choice })
    end
end

--- No answer, or one that wasn't yes or no: the card stays for a click.
local function leaveOnScreen(a, why, said)
    record("decision", { request = a.n, decision = "left", why = why, text = said })
    if not a.item.answer and a.item.kind ~= "question" then
        tellAnswer(a, "waiting")
    end
    if not a.item.answer then
        speak("I'll leave that on screen.", { approval = true })
    end
    closeApproval(a)
end

local decideChoice

--- Allow or deny by voice: the card is answered and marked. For a
-- question's "did you mean", yes takes the choice and no leaves the card.
-- @param note  optional: the remark that came with a yes (the classifier's
--              `note`); the user's words then go to the agent with the approval
local function decide(a, verdict, said, via, note)
    if a.confirm then
        if verdict == "allow" then
            return decideChoice(a, a.confirm, said, via)
        end
        return leaveOnScreen(a, "not confirmed", said)
    end
    local remark = verdict == "allow" and type(note) == "string" and text.trim(note) ~= "" and not a.item.answer
    local permission = not a.item.answer and a.item.kind ~= "question"
    if not a.item.answer then
        local allow = verdict == "allow"
        agent.answer(a.item, allow, (allow and "Allowed by voice: \u{201C}" or "Denied by voice: \u{201C}")
            .. said .. "\u{201D}")
    end
    record("decision", { request = a.n, decision = verdict, by = "voice", via = via, text = said,
        note = remark and note or nil })
    if permission then
        tellAnswer(a, verdict == "allow" and "allowed" or "refused")
    end
    if remark then
        -- His whole answer, every word, not the classifier's summary of it.
        agent.remark(a.item, "About allowing " .. tostring(a.item.tool) .. ", I said: \u{201C}" .. said .. "\u{201D}")
    end
    closeApproval(a)
end

--- The window's time ran out (an answer still being classified decides).
local function windowEnded(a)
    if approval ~= a then
        return
    end
    a.expired = true
    if not a.classifying then
        leaveOnScreen(a, "no answer")
    end
end

--- The question has been said: listen for the answer.
local function openWindow(a)
    if approval ~= a or a.open then
        return
    end
    if a.fallback then
        gitgud.cancelTimer(a.fallback)
        a.fallback = nil
    end
    a.open = true
    local seconds = voice.approvalSeconds()
    a.timer = gitgud.after(seconds * 1000, function()
        windowEnded(a)
    end)
    if not hearing then
        setState(current, a.confirm and "Did you mean that? Say yes or no"
            or (a.item.kind == "question" and "Say your answer" or ("Allow " .. a.item.tool .. "? Say yes or no")))
    end
end

local classifyChoice

--- Say a line that asks (a question, or "did you mean"); the answer
-- window opens once it has been said, or after a while if it never plays.
local function sayAsking(a, line)
    a.question = line
    a.open, a.playing, a.expired = false, false, false
    a.sayId = speak(line, { approval = true })
    a.fallback = gitgud.after(APPROVAL_START_MS, function()
        if approval == a and not a.playing then
            openWindow(a)
        end
    end)
end

--- An unclear answer: the card stays open and Bragi asks once more,
-- briefly, rather than going quiet. False when it
-- already did (or the window was opened for a message, not asked aloud).
function cards.again(a)
    if a.again or a.reopened or current == "off" then
        return false
    end
    if a.timer then
        gitgud.cancelTimer(a.timer)
        a.timer = nil
    end
    local asked = a.question
    a.again = (a.item.kind == "question" and not a.confirm) and cards.AGAIN_QUESTION or cards.AGAIN
    sayAsking(a, a.again)
    a.question = asked -- the classifier still gets the question itself
    record("ask", { request = a.n, tool = a.item.tool, text = a.again, reply = a.sayId, again = true })
    return true
end

--- Ask the classifier whether what the user said is yes or no.
-- @param via        "ambient", "wake", or "follow-up"
-- @param onUnclear  optional: run instead of asking again or leaving the
--                   card (a message that isn't an answer is a new message)
local function classifyAnswer(a, said, via, speaker, onUnclear)
    if a.item.kind == "question" and not a.confirm then
        return classifyChoice(a, said, via, speaker, onUnclear)
    end
    a.classifying = true
    record("answer", { request = a.n, text = said, via = via, speaker = speaker or "unknown",
        enrolled = enrolled })
    local started = gitgud.now()
    askHelper(approver, { asked = a.question or "", answer = said }, function(reply, err)
        a.classifying = false
        local answer = nil
        local first = type(reply) == "string" and reply:find("{", 1, true)
        local last = type(reply) == "string" and reply:match(".*()}")
        if first and last then
            answer = gitgud.jsonDecode(reply:sub(first, last))
        end
        answer = type(answer) == "table" and answer or {}
        local verdict = APPROVAL_VERDICTS[answer.answer] and answer.answer or "unclear"
        record("answer", { request = a.n, text = said, verdict = verdict, ms = gitgud.now() - started,
            why = answer.why or err, note = type(answer.note) == "string" and answer.note or nil })
        if approval ~= a then
            if onUnclear and verdict == "unclear" then
                onUnclear()
            end
            return -- answered meanwhile (a click)
        end
        if verdict ~= "unclear" then
            return decide(a, verdict, said, via, answer.note)
        end
        if onUnclear then
            if a.reopened then
                closeApproval(a) -- a card left on screen stays there, quietly
            end
            onUnclear()
            if not a.reopened and a.expired then
                leaveOnScreen(a, "no answer")
            end
            return
        end
        if not cards.again(a) then
            leaveOnScreen(a, "unclear", said)
        end
    end)
end

--- Whether an utterance is only a filler sound ("um"): not an answer.
local function onlyFiller(said)
    local list = words(said)
    for _, w in ipairs(list) do
        if not FILLER[w] then
            return false
        end
    end
    return true
end

--- Speech outside a message while the window is open: the answer.
local function ambientAnswer(e)
    local a = approval
    local said = text.trim(e.text or "")
    if not a or not a.open or a.classifying or onlyFiller(said) then
        return
    end
    -- A short answer to a question card repeats its words ("two", "blue"):
    -- only a longer stretch of the question heard back is its echo. Words
    -- are also checked against what Bragi just said (asking again, or a
    -- narration), longer than a word or two. Who says it doesn't matter.
    local count = #words(said)
    local short = a.item.kind == "question" and count < 4
    local recent = count >= 3 and recentSpeech()
    if (a.question and not short and isEcho(said, a.question))
        or (a.again and count >= 3 and isEcho(said, a.again)) or (recent and isEcho(said, recent.text)) then
        record("answer", { request = a.n, text = said, via = "ambient", ignored = "echo",
            speaker = e.speaker or "unknown" })
        return
    end
    classifyAnswer(a, said, "ambient", e.speaker)
end

--- Ask a permission aloud: the narrator makes the question.
local function askApproval(item)
    approvalCount = approvalCount + 1
    local a = { item = item, n = "p" .. approvalCount }
    approval = a
    local input = type(item.input) == "table" and item.input or {}
    askHelper(narrator, { request = narration and narration.request or "", permission = { tool = item.tool,
        summary = item.summary or "", description = type(input.description) == "string" and input.description
        or nil, helper = item.helper } }, function(reply)
        if approval ~= a then
            return
        end
        local line = snippetOf(reply)
        if item.answer or line == "" or current == "off" then
            record("ask", { request = a.n, tool = item.tool, said = false,
                why = item.answer and "answered" or (line == "" and "no question" or "voice off") })
            return closeApproval(a)
        end
        a.question = line
        item.asked = line -- for an answer once it's left on screen
        a.sayId = speak(line, { approval = true })
        record("ask", { request = a.n, tool = item.tool, text = line, reply = a.sayId })
        -- The window opens once it has been said (playback); if it never
        -- starts playing, after a while anyway.
        a.fallback = gitgud.after(APPROVAL_START_MS, function()
            if approval == a and not a.playing then
                openWindow(a)
            end
        end)
    end)
end

-- ===================================================================
-- Spoken questions
-- ===================================================================
--
-- Claude's multiple-choice questions (question cards, bragi/agent.lua)
-- go the way of spoken approvals, in any permission mode: Bragi reads the
-- question and its options, numbered ("Which colour do you prefer? One:
-- Red. Two: Blue. Or say your own."), and the next thing the user says answers
-- it: "the first one", the option's words, or their own answer. The choice
-- classifier (prompts/choice.md) maps it to the options; when it isn't
-- sure, Bragi asks "Did you mean Blue?" and a yes takes it (the approval
-- classifier), a no leaves the card. Not an answer, or none in time: the
-- card stays. Logged as `ask`, `answer`, and `decision` lines.

local NUMBERS = { "One", "Two", "Three", "Four" }

--- What Bragi says to ask a question card.
local function questionLine(item)
    local parts = { item.question }
    for i, o in ipairs(item.options) do
        parts[#parts + 1] = (NUMBERS[i] or tostring(i)) .. ": " .. o.label .. "."
    end
    parts[#parts + 1] = item.multi and "Pick any, or say your own." or "Or say your own."
    return table.concat(parts, " ")
end

--- A choice in words, for "did you mean": "Install and License".
local function choiceWords(choice)
    local parts = {}
    for _, label in ipairs(choice.labels) do
        parts[#parts + 1] = label
    end
    if choice.other ~= "" then
        parts[#parts + 1] = choice.other
    end
    return table.concat(parts, " and ")
end

--- Answer the card by voice and close the window.
decideChoice = function(a, choice, said, via)
    if not a.item.answer then
        agent.answerQuestion(a.item, choice, { by = "voice",
            note = "Answered by voice: \u{201C}" .. said .. "\u{201D}" })
        -- Said at once that it was heard (the narrator).
        tellAnswer(a, "answered", tostring(a.item.answer or ""))
    end
    record("decision", { request = a.n, decision = "answer", answer = a.item.answer, by = "voice", via = via,
        text = said })
    closeApproval(a)
end

--- Ask the choice classifier which option the user picked.
classifyChoice = function(a, said, via, speaker, onUnclear)
    a.classifying = true
    record("answer", { request = a.n, text = said, via = via, speaker = speaker or "unknown",
        enrolled = enrolled })
    local item = a.item
    local options, known = {}, {}
    for _, o in ipairs(item.options) do
        options[#options + 1] = { label = o.label, description = o.description }
        known[o.label] = true
    end
    local started = gitgud.now()
    askHelper(chooser, { asked = item.question, options = options, multiSelect = item.multi, answer = said },
        function(reply, err)
            a.classifying = false
            local answer = nil
            local first = type(reply) == "string" and reply:find("{", 1, true)
            local last = type(reply) == "string" and reply:match(".*()}")
            if first and last then
                answer = gitgud.jsonDecode(reply:sub(first, last))
            end
            answer = type(answer) == "table" and answer or {}
            local choice = { labels = {}, other = type(answer.other) == "string" and text.trim(answer.other) or "" }
            for _, label in ipairs(type(answer.choice) == "table" and answer.choice or {}) do
                if known[label] and (item.multi or #choice.labels == 0) then
                    choice.labels[#choice.labels + 1] = label
                end
            end
            local found = #choice.labels > 0 or choice.other ~= ""
            record("answer", { request = a.n, text = said, choice = choice.labels, other = choice.other,
                sure = answer.sure ~= false, ms = gitgud.now() - started, why = answer.why or err })
            if approval ~= a then
                if onUnclear and not found then
                    onUnclear()
                end
                return -- answered meanwhile (a click)
            end
            if not found then
                if onUnclear then
                    if a.reopened then
                        closeApproval(a) -- a card left on screen stays there, quietly
                    end
                    onUnclear()
                    if not a.reopened and a.expired then
                        leaveOnScreen(a, "no answer")
                    end
                    return
                end
                if cards.again(a) then
                    return
                end
                return leaveOnScreen(a, "unclear", said)
            end
            if answer.sure == false then
                -- Not sure: ask before taking it.
                if a.timer then
                    gitgud.cancelTimer(a.timer)
                    a.timer = nil
                end
                a.confirm = choice
                sayAsking(a, "Did you mean " .. choiceWords(choice) .. "?")
                record("ask", { request = a.n, tool = item.tool, text = a.question, reply = a.sayId, confirm = true })
                return
            end
            decideChoice(a, choice, said, via)
        end)
end

--- Ask a question card aloud.
local function askQuestion(item)
    approvalCount = approvalCount + 1
    local a = { item = item, n = "p" .. approvalCount }
    approval = a
    sayAsking(a, questionLine(item))
    record("ask", { request = a.n, tool = item.tool, text = a.question, reply = a.sayId })
end

askNextApproval = function()
    if approval then
        return
    end
    while #approvals > 0 do
        local item = table.remove(approvals, 1)
        if not item.answer and approvalsOn(item) then
            if item.kind == "question" then
                return askQuestion(item)
            end
            return askApproval(item)
        end
    end
end

--- A card waiting in the shown conversation, left on screen: taken up
-- again, without asking, for a message that may answer it
-- ("Hey Bragi, I said yes, go ahead" stopped the turn and
-- cancelled the card). Nil when none waits, or approvals are off.
function cards.reopen()
    local item = agent.waitingCard()
    if not item or not approvalsOn(item) then
        return nil
    end
    for i, queued in ipairs(approvals) do
        if queued == item then
            table.remove(approvals, i)
            break
        end
    end
    approvalCount = approvalCount + 1
    local a = { item = item, n = "p" .. approvalCount, reopened = true,
        question = item.kind == "question" and questionLine(item) or item.asked
            or ("Can I use " .. tostring(item.tool) .. "?") }
    approval = a
    record("ask", { request = a.n, tool = item.tool, text = a.question, said = false, why = "waiting" })
    return a
end

--- A permission or question card ("bragi.permission", bragi/agent.lua).
local function onPermission(e)
    if type(e) ~= "table" or not e.item or not e.shown then
        return
    end
    closeFollowUp("card")
    if not approvalsOn(e.item) then
        return
    end
    approvals[#approvals + 1] = e.item
    askNextApproval()
end

--- A card was answered by a click (or the turn ended): its window closes.
local function onPermissionAnswered(e)
    if type(e) ~= "table" or e.by == "voice" then
        return
    end
    for i, item in ipairs(approvals) do
        if item == e.item then
            table.remove(approvals, i)
            break
        end
    end
    local a = approval
    if a and a.item == e.item then
        record("decision", { request = a.n, decision = e.item.answer, by = e.by })
        closeApproval(a)
    end
end

--- Voice went off: nothing more is asked.
local function dropApprovals()
    approvals = {}
    if approval then
        local a = approval
        if a.timer then
            gitgud.cancelTimer(a.timer)
        end
        if a.fallback then
            gitgud.cancelTimer(a.fallback)
        end
        approval = nil
    end
end

-- ===================================================================
-- Follow-up answers
-- ===================================================================
--
-- "When you end with a question ... give me that chance to vocally
-- respond without having to use the wake word again, like we're having a
-- conversation." A reply's spoken summary that ends with a question (its
-- last sentence ends with "?") opens a follow-up window once it has
-- played, while listening and nothing else is asked or worked on:
-- bragi.followUpSeconds (FOLLOW_UP_SECONDS, 3 to 30). The next thing the user
-- says without the wake word (`ambient`) is their next message: it goes
-- through the filter and is sent like a wake-word message. Filler alone
-- ("um") and the reply heard back (four words or more, mostly its own)
-- are ignored. The window
-- closes on an answer, the wake word, a typed message, a new turn or
-- card, voice off, or when the time runs out. While it's open the status
-- says "Listening for your answer". Narration never opens one. Logged as
-- `follow-up` lines: open, ignored, answer, closed (with why).
--
-- The answer goes to the conversation that asked: when
-- that isn't the one shown (the master conversation's news, most often),
-- it's sent there in the background (as a spoken message: its reply is
-- spoken too), and the one shown gets a banner with the question and the
-- answer, and Open (bragi/answerbanner.lua).

--- Send an answer to the conversation that asked, which isn't shown.
function guard.answerElsewhere(m, body, opts)
    local tab = m.tab
    record("sent", { id = m.id, text = body, to = tab.title, context = opts.context and #opts.context or nil })
    timing("started", nil, m.id)
    local ok, err = agent.sendTo(tab, body, { voice = true, context = opts.context })
    if not ok then
        agent.addMessage("note", "Couldn't send your answer to " .. (tab.title or "the conversation") .. ": "
            .. tostring(err), { error = true })
        return
    end
    require("bragi.answerbanner").show(agent.current(), { target = tab, question = m.question, answer = body })
end

local FOLLOW_UP_SECONDS = 8 -- bragi.followUpSeconds when unset
local followUpCount = 0

--- Seconds the follow-up window stays open (the setting, kept to 3..30).
function voice.followUpSeconds()
    local seconds = tonumber(settings.get("bragi.followUpSeconds", "")) or FOLLOW_UP_SECONDS
    return math.max(3, math.min(30, seconds))
end

--- True while a follow-up window is open.
function voice.followingUp()
    return followUp ~= nil and followUp.open == true
end

--- Whether spoken text ends by asking: its last sentence ends with "?".
local function endsWithQuestion(s)
    s = text.trim(tostring(s or ""))
    return s:match("%?[\"')%]]*$") ~= nil or s:match("%?\u{201D}$") ~= nil
end

--- Close the follow-up window, or forget the reply that would open one.
-- @param why  "answer", "wake", "typed", "turn", "card", "new reply", "timeout", "off"
closeFollowUp = function(why)
    local f = followUp
    if not f then
        return
    end
    followUp = nil
    if f.timer then
        gitgud.cancelTimer(f.timer)
    end
    if f.open then
        record("follow-up", { n = f.n, reply = f.sayId, state = "closed", why = why })
        if current ~= "off" and not hearing and not approval then
            setState(current)
        end
    end
end

--- A reply's summary was said: when it asks something, its playback
-- ending opens the window.
-- @param tab  the conversation that asked (default: the one shown)
expectFollowUp = function(id, spoken, tab)
    if not id then
        return
    end
    closeFollowUp("new reply")
    if endsWithQuestion(spoken) then
        followUpCount = followUpCount + 1
        followUp = { n = "f" .. followUpCount, sayId = id, text = spoken, tab = tab or agent.current() }
    end
end

--- The question has been said (its playback stopped): listen for the answer.
local function openFollowUp(id)
    local f = followUp
    if not f or f.open or f.sayId ~= id then
        return
    end
    local busy = current ~= "listening" and "not listening" or hearing and "hearing" or approval and "card"
        or agent.session().turn and "turn" or nil
    if busy then
        record("follow-up", { n = f.n, reply = id, state = "skipped", why = busy })
        followUp = nil
        return
    end
    f.open = true
    local seconds = voice.followUpSeconds()
    f.timer = gitgud.after(seconds * 1000, function()
        if followUp == f then
            closeFollowUp("timeout")
        end
    end)
    record("follow-up", { n = f.n, reply = id, state = "open", seconds = seconds, text = f.text })
    setState(current)
end

--- Speech outside a message while the window is open: the user's next message.
local function followUpAnswer(e)
    local f = followUp
    local said = text.trim(e.text or "")
    if not f or not f.open or said == "" then
        return
    end
    local long = #words(said) >= HEARD.ECHO_MIN_WORDS
    -- Who says it doesn't matter.
    local ignored = onlyFiller(said) and "filler"
        or (long and isEcho(said, f.text)) and "echo"
        or (long and guard.lastSent and isEcho(said, guard.lastSent)) and "echo of what was sent"
        or nil
    if ignored then
        record("follow-up", { n = f.n, state = "ignored", text = said, speaker = e.speaker or "unknown",
            ignored = ignored })
        return
    end
    record("follow-up", { n = f.n, state = "answer", text = said, speaker = e.speaker or "unknown" })
    closeFollowUp("answer")
    local m = { id = "follow-" .. f.n, speaker = e.speaker, t0 = e.t0 }
    -- Asked from a conversation that isn't shown (the master's news, most
    -- often): the answer goes there.
    if f.tab and f.tab ~= agent.current() then
        for _, t in ipairs(agent.tabs()) do
            if t == f.tab then
                m.to = { tab = f.tab, question = f.text }
            end
        end
    end
    record("heard", { id = m.id, text = said, endedBy = "follow-up", t0 = e.t0, t1 = e.t1, speaker = e.speaker,
        speakerScore = e.speakerScore })
    -- A card waiting meanwhile hears it first.
    local a = cards.reopen()
    if a then
        return classifyAnswer(a, said, "follow-up", e.speaker, function()
            takeMessage(m, said, nil, false)
        end)
    end
    takeMessage(m, said, nil, false)
end

-- ===================================================================
-- Recording what the engine hears
-- ===================================================================

-- For troubleshooting: with bragi.recordVoice on, the
-- mic audio as the engine got it (each frame once it went out) is saved
-- while listening, a WAV file per start in recorder.FOLDER of the config
-- folder (16 kHz mono 16-bit, gitgud.voiceRecord). Only the newest
-- recorder.KEEP files are kept, and no more than recorder.MAX_BYTES of them.
-- The path is logged (`record`).

-- file: the one being written, its config name (nil: none).
local recorder = { FOLDER = "bragi/voice-recordings", KEEP = 10, MAX_BYTES = 200 * 1024 * 1024, file = nil }

--- Delete the oldest recordings until at most `keep` are left and they
-- take at most MAX_BYTES. Only .wav files are touched.
function recorder.prune(keep)
    local files = {}
    local total = 0
    for _, f in ipairs(gitgud.configList(recorder.FOLDER) or {}) do
        if f.name:lower():find("%.wav$") then
            files[#files + 1] = f
            total = total + (f.size or 0)
        end
    end
    -- Named by date and time: oldest first.
    local i = 1
    while i <= #files and (#files - i + 1 > keep or total > recorder.MAX_BYTES) do
        local name = recorder.FOLDER .. "/" .. files[i].name
        if name ~= recorder.file then
            gitgud.configRemove(name)
            total = total - (files[i].size or 0)
        end
        i = i + 1
    end
end

--- Start or stop recording to match bragi.recordVoice while listening
-- (the mic turning on, and the setting changing).
function voice.recordingChanged()
    local want = current ~= "off" and settings.get("bragi.recordVoice", false) == true
    if not voice.backend.record or want == (recorder.file ~= nil) then
        return
    end
    if not want then
        voice.backend.record(nil) -- "voice.record" says it ended
        recorder.file = nil
        return
    end
    recorder.prune(recorder.KEEP - 1)
    local name = recorder.FOLDER .. "/" .. os.date("%Y-%m-%d-%H%M%S") .. ".wav"
    local path = gitgud.configPath(name)
    local ok, err = voice.backend.record(path)
    if ok then
        recorder.file = name
    end
    record("record", { state = ok and "on" or "failed", path = path, error = err })
end

-- ===================================================================
-- Listening
-- ===================================================================

--- Voice can't start: why, in one note kept up to date (pressing the mic
-- again doesn't add another). Models an app update replaced come in again,
-- and voice turns on once they're in.
function guard.cannotStart()
    local models = require("bragi.voicemodels")
    if models.engineInstalled() and not models.installed() and models.update() then
        guard.startWhenReady = true
    end
    local text = voice.unavailableText()
    if guard.startWhenReady then
        text = text .. " Voice turns on when they're in."
    end
    local items = agent.items()
    if guard.modelsNote and items[#items] == guard.modelsNote then
        agent.updateNote(guard.modelsNote, text)
    else
        guard.modelsNote = agent.addMessage("note", text)
    end
end

--- Turn listening on or off (the mic button).
function voice.toggle()
    if current ~= "off" then
        voice.stop()
        return
    end
    if settings.get("bragi.voiceOff", "") ~= "" then
        -- Off after the app closed in the engine last time: pressing the mic
        -- is turning it back on (the note was shown once, at start).
        voice.clearCrash()
    end
    if not voice.available() then
        guard.cannotStart()
        return
    end
    local options = voice.tuning()
    options.endBy = "app"
    options.wakeWord = wakeWord()
    options.closingPhrase = closingPhrase()
    options.lookbackTokens = LOOKBACK_TOKENS
    options.endWaitSeconds = voice.endWait()
    sentEndWait = options.endWaitSeconds
    -- The recognizer is biased toward these; `ready.vocabulary` says
    -- whether it uses them.
    options.vocabulary = vocab.hotwords()
    sentHotwords = table.concat(options.vocabulary, "\n")
    guard.connected = false
    local ok, err = voice.backend.listen(options)
    if not ok then
        agent.addMessage("note", "Voice didn't start: " .. tostring(err), { error = true })
        return
    end
    -- The capture last time, so each start has it even if the mic doesn't
    -- open (the mic line says what this one does).
    local before = mic.lastCapture()
    record("listen", { wakeWord = wakeWord(), closingPhrase = closingPhrase(),
        lastCapture = before and (mic.mode(before) .. ", " .. tostring(before.at)) or nil })
    record("hotwords", { count = #options.vocabulary, sent = "hello", words = options.vocabulary })
    voice.recordingChanged()
    setState("connecting")
    voice.checkProviders()
    voice.checkVoices(true) -- the voices for replies, known before the first one
    warmHelpers()
    agent.warm()
    -- Connect for speech and open the speaker now, so the first reply
    -- doesn't wait for either.
    if settings.get("bragi.speak", true) and voice.backend.speakPrepare then
        voice.backend.speakPrepare()
    end
end

--- Forget the message being heard, and its live text in the prompt box
-- (a socket that closed mid-message left it there).
function guard.forgetHearing()
    cancelDone()
    if hearing then
        agent.setHeard("")
    end
    hearing = nil
    guard.flushHeld("ended")
end

--- Turn listening off.
function voice.stop()
    if current == "off" then
        return
    end
    voice.backend.stop()
    recorder.file = nil -- the session's end closes the file ("voice.record")
    mic.on = false
    guard.connected = false
    guard.forgetHearing()
    guard.releaseCarry("off")
    stopNarration()
    dropApprovals()
    record("stop", {})
    setState("off")
    closeFollowUp("off")
    for _, h in ipairs(ALL_HELPERS) do
        if not h.busy and #h.queue == 0 then
            helpers.stop(h)
        end
    end
end

--- End the message being heard now (Send).
function voice.sendNow()
    if hearing then
        cancelDone()
        voice.backend.send("button")
    end
end

local handlers = {}

--- A recording ended: logged, and the oldest pruned for its size.
function handlers.record(e)
    record("record", { state = e.state, path = e.path, seconds = e.seconds })
    if recorder.file and type(e.path) == "string" and e.path == gitgud.configPath(recorder.file) then
        recorder.file = nil
    end
    recorder.prune(recorder.KEEP)
end

function handlers.ready(e)
    guard.connected = true
    -- vocabulary: whether the recognizer uses the hotwords sent (absent
    -- from an engine that doesn't know them).
    -- decider: the turn-taking model is loaded (bragi/decider.lua).
    guard.decider = e.decider == true
    guard.speaking = false
    record("ready", { stt = e.stt, keywords = e.keywords, speaker = e.speaker, vocabulary = e.vocabulary,
        decider = e.decider, deciderError = e.deciderError })
    enrolled = type(e.speaker) == "table" and e.speaker.enrolled == true
    if type(e.stt) == "table" and e.stt.provider then
        setProviders({ stt = voice.PROVIDER_NAMES[e.stt.provider] or e.stt.provider, sttFallback = e.stt.fallback or "" })
    end
    setState("listening")
end

function handlers.enrollResult(e)
    enrolled = e.enrolled == true
end

function handlers.vad(e)
    record("vad", { speaking = e.speaking == true, t = e.t })
    guard.speaking = e.speaking == true
    if guard.speaking then
        guard.carryStarted(e.t)
    end
    paintLevel(e.speaking == true)
end

--- Log the mic levels gathered so far, as one line.
local function flushLevels()
    if levels and #levels.rms > 0 then
        record("level", levels)
    end
    levels = nil
end

--- A second of the mic ("voice.level": t, its end; rms, max in dBFS).
-- Gathered into a line per LEVEL_LINE_SECONDS; `t` there is the start of
-- the first second, so second i covers t + (i - 1) * 1000 on.
function handlers.level(e)
    if type(e.t) ~= "number" then
        return
    end
    local start = e.t - 1000
    if levels and start ~= levels.t + #levels.rms * 1000 then
        flushLevels() -- not the next second: a new connection
    end
    levels = levels or { t = start, rms = {}, max = {} }
    levels.rms[#levels.rms + 1] = e.rms
    levels.max[#levels.max + 1] = e.max
    if #levels.rms >= LEVEL_LINE_SECONDS then
        flushLevels()
    end
end

--- A wake while a reply plays: the reply stops at once. What's heard
-- meanwhile is the user (the echo canceller keeps the reply out of the
-- microphone), never second-guessed as Bragi's own voice.
local function bargeIn(playing)
    local said = spokenText[playing]
    hearing.barge = { spoken = said and said.text or "" }
    hearing.duringPlayback = true
    guard.pauseTelling(playing)
    for _, w in ipairs(unheard()) do
        w.entry.dropped = true
    end
    voice.backend.speakStop(nil) -- and the lines waiting after it
    record("barge-in", { id = hearing.id, reply = playing })
    setState("hearing")
end

function handlers.wake(e)
    record("wake", { id = e.id, t = e.t, at = gitgud.now(), playing = voice.backend.playing() })
    cancelDone()
    guard.releaseCarry("wake")
    -- An open window closes; one waiting for its question to finish
    -- playing stays until a message is taken (takeMessage): a wake
    -- dropped as Bragi's own voice mustn't lose it.
    if followUp and followUp.open then
        closeFollowUp("wake")
    end
    hearing = { id = e.id, text = "" }
    agent.setHeard("")
    guard.startDeciding()
    local playing = voice.backend.playing()
    if playing then
        return bargeIn(playing)
    end
    setState("hearing")
end

function handlers.partial(e)
    if hearing and e.id == hearing.id then
        -- More words: they weren't done. A message decoded again as it grows
        -- also corrects words it heard, which isn't more speech.
        local heard = guard.partialText(e)
        if #words(heard) > #words(hearing.text) then
            cancelDone()
            hearing.grewAt = gitgud.now()
        end
        hearing.text = heard
        agent.setHeard(hearing.text)
    end
end

function handlers.pause(e)
    if hearing and e.id == hearing.id then
        handlers.partial(e)
        -- With the turn-taking model, it decides (guard.startDeciding).
        if not guard.decider and text.trim(hearing.text) ~= "" then
            judge(hearing.id, hearing.text)
        end
    end
end

--- The turn-taking model's answer: logged when the words or its verdict
-- changed; it ends the message when sure (bragi/decider.lua). An error
-- (the model failed) leaves the Haiku judge to decide from here on.
function handlers.decision(e)
    local h = hearing
    if not h or not h.asking or h.asking.id ~= e.id then
        return
    end
    local asked = h.asking
    h.asking = nil
    local decider = require("bragi.decider")
    local d, err = decider.read(e)
    if not d then
        record("decide-failed", { id = h.id, error = err })
        guard.decider = false
        if text.trim(h.text) ~= "" then
            judge(h.id, h.text)
        end
        return
    end
    local done = decider.done(d) and h.text == asked.text and not h.ended
    local key = asked.text .. "|" .. d.top
    if done or h.decided ~= key then
        h.decided = key
        record("decide", { id = h.id, text = asked.text, decision = decider.summary(d), ms = d.ms,
            done = done or nil })
    end
    if done then
        record("done", { id = h.id, by = "model", pause = d.pause, complete = d.state.complete })
        local ok, sendErr = voice.backend.send("done")
        if ok then
            h.ended = true
        else
            -- Not ended: the model's next answer tries again.
            record("done-failed", { id = h.id, error = sendErr })
        end
    end
end

--- A message's text: its last decode; for a growing message whose last
-- decode failed or lost words, the live text, or the utterances' own texts
-- when those heard more.
function guard.finalText(e)
    local final = text.trim(e.text or "")
    if type(e.live) ~= "string" then
        return final
    end
    local live = text.trim(e.live)
    local chosen, why = final, nil
    if e.finalOk == false or #words(final) < HEARD.FINAL_MIN_WORDS * #words(live) then
        chosen, why = live, "live"
    end
    local utterances = text.trim(type(e.utterances) == "string" and e.utterances or "")
    if #words(chosen) < HEARD.FINAL_MIN_WORDS * #words(utterances) then
        chosen, why = utterances, "utterances"
    end
    if why then
        record("final-fallback", { id = e.id, final = final, live = live, utterances = utterances,
            ok = e.finalOk, took = why })
    end
    return chosen
end

--- A growing partial's text, or the utterances' own texts when the pass
-- heard much less than they did.
function guard.partialText(e)
    local s = e.text or ""
    if type(e.utterances) == "string" and #words(s) < HEARD.FINAL_MIN_WORDS * #words(e.utterances) then
        return e.utterances
    end
    return s
end

handlers["message"] = function(e)
    local heard = guard.finalText(e)
    local wasPlayback = hearing and hearing.id == e.id and hearing.duringPlayback
    local barge = hearing and hearing.id == e.id and hearing.barge or nil
    cancelDone()
    hearing = nil
    guard.flushHeld("ended")
    agent.setHeard("")
    setState(current == "off" and "off" or "listening")
    record("heard", { id = e.id, text = heard, endedBy = e.endedBy, t0 = e.t0, t1 = e.t1, speaker = e.speaker,
        speakerScore = e.speakerScore, live = e.live })
    if heard == "" then
        return
    end
    -- Said with the wake word while a card waits (asked aloud, or left on
    -- screen): a clear yes or no (or a pick) answers it; anything else is
    -- a new message.
    local a = approval
    if not a then
        a = cards.reopen()
    end
    if a and not a.classifying then
        a.question = a.question or a.item.asked or ("Can I use " .. tostring(a.item.tool) .. "?")
        return classifyAnswer(a, heard, "wake", e.speaker, function()
            takeMessage(e, heard, barge, wasPlayback)
        end)
    end
    takeMessage(e, heard, barge, wasPlayback)
end

--- A heard message goes on: shown, an opening line, the filter.
takeMessage = function(e, heard, barge, wasPlayback)
    closeFollowUp("wake")
    lastEnded = { id = e.id, at = gitgud.now(), stages = {} }
    judger.queue = {} -- the message ended: "are you done" is answered
    -- An answer that goes to another conversation (e.to) shows there, not here.
    local pending = not e.to and agent.voicePending(heard) or nil
    timing("shown")
    -- The opening line is asked now, and said once the filter passes the
    -- message (openAfterFilter). Not for a message that talks over a reply
    -- or the agent's work: that one is classified.
    if not barge and not wasPlayback and not agent.session().turn and not e.to then
        opener = { id = e.id, wanted = true }
        sayOpening(heard, e.id, true)
    else
        opener = nil
        guard.judging = { id = e.id, at = gitgud.now() }
    end
    local m = voice.filter(heard, e.id, pending, barge, e.t0, e.to)
    m.carryOn = e.carryOn
    guard.releaseCarry("new message")
    if e.endedBy == "done" and tonumber(e.t1) then
        guard.carry = { m = m, id = e.id, t1 = tonumber(e.t1) }
    end
end

-- ===================================================================
-- Carrying on after a pause
-- ===================================================================
--
-- The turn-taking model ends a message at a pause that sounds final, and
-- people go on after one ("I want to tidy up this project a little."
-- then "Can you start by telling me what's in the notes file?"). Speech
-- that starts within CARRY_ON_MS of the end of a message the model ended
-- carries it on, without the wake word:
--   * from when the engine says it started (`vad`, in the engine's time),
--     the message waits: once through the filter it isn't sent (nor its
--     opening line said) until that speech ends, at most CARRY_ON_WAIT_MS;
--   * the speech (`ambient`) joins the message, which goes through the
--     filter again with all of it, and may carry on again;
--   * a message already sent gets it as a message of its own: while the
--     turn runs, the turn stops and it's sent (a steer).
-- Speech in the window that's nothing (filler), or a wake, lets the
-- message go on as it was.

guard.CARRY_ON_MS = 2500
guard.CARRY_ON_WAIT_MS = 20000
guard.carry = nil -- { m, id, t1, resumed, timer }: the latest message the model ended

--- Whether a message waits for what its speaker went on to say.
function guard.carryWaits(m)
    return m ~= nil and guard.carry ~= nil and guard.carry.m == m and guard.carry.resumed == true
end

--- The message no longer carries on: one held goes on as it was.
-- @param why  for the log
function guard.releaseCarry(why)
    local c = guard.carry
    if not c then
        return
    end
    guard.carry = nil
    if c.timer then
        gitgud.cancelTimer(c.timer)
    end
    if c.resumed then
        record("carry-on", { id = c.id, state = "released", why = why })
    end
    local held = c.m.held
    if held then
        c.m.held = nil
        guard.finishFor(c.m, held.answer, held.err)
    end
end

--- Speech started: within the window, the message waits for it.
function guard.carryStarted(t)
    local c = guard.carry
    t = tonumber(t)
    if not c or c.resumed or hearing or not t then
        return
    end
    if t - c.t1 > guard.CARRY_ON_MS then
        guard.carry = nil -- too late to carry it on
        return
    end
    c.resumed = true
    record("carry-on", { id = c.id, state = "waiting", after = t - c.t1 })
    c.timer = gitgud.after(guard.CARRY_ON_WAIT_MS, function()
        c.timer = nil
        if guard.carry == c then
            guard.releaseCarry("timeout")
        end
    end)
end

--- Speech outside a message: the carry-on, when one is awaited. False
-- when it isn't one.
function guard.carryOn(e)
    local c = guard.carry
    local said = text.trim(e.text or "")
    if not c or not c.resumed then
        return false
    end
    if said == "" or onlyFiller(said) then
        guard.releaseCarry("nothing said")
        return true
    end
    guard.carry = nil
    if c.timer then
        gitgud.cancelTimer(c.timer)
    end
    local m = c.m
    record("carry-on", { id = c.id, state = "joined", text = said, sent = m.delivered or nil })
    if m.delivered then
        -- Sent already: it follows as a message of its own.
        local next = { id = c.id .. "+", t0 = e.t0, t1 = e.t1, speaker = e.speaker, carryOn = true }
        record("heard", { id = next.id, text = said, endedBy = "carry-on", t0 = e.t0, t1 = e.t1,
            speaker = e.speaker })
        takeMessage(next, said, nil, false)
        return true
    end
    m.heard = text.trim(m.heard .. " " .. said)
    m.short = #wordList(m.heard) < HEARD.SHORT_WORDS
    agent.rehearPending(m.pending, m.heard)
    if m.held then
        m.held = nil
        table.insert(queue, 1, m)
        filterNext()
    elseif m == active then
        m.again = true
    end
    -- It may go on again.
    guard.carry = { m = m, id = c.id, t1 = tonumber(e.t1) or c.t1 }
    return true
end

--- Speech outside a message: kept by the engine for the lookback; here
-- only the answer to a permission question, or to a reply that asked
-- something (Follow-up answers).
function handlers.ambient(e)
    if guard.carryOn(e) then
        return
    end
    if approval then
        return ambientAnswer(e)
    end
    followUpAnswer(e)
end

function handlers.cancelled(e)
    guard.forgetHearing()
    agent.setHeard("")
    record("cancelled", { id = e.id })
    if current ~= "off" then
        setState("listening")
    end
end

function handlers.lookback(e)
    local m = lookbacks[e.id]
    lookbacks[e.id] = nil
    if not m or m ~= active then
        return
    end
    local segments = e.segments or {}
    -- Nothing fit: one long utterance can be bigger than the budget.
    if #segments == 0 and m.fetched < HEARD.CONTEXT_MORE and fetchContext(m, HEARD.CONTEXT_MORE, "empty") then
        return
    end
    -- Only what came before the message, as heard: not the message itself
    -- (the newest segments can be it) and not Bragi's own voice.
    local lines = {}
    for _, seg in ipairs(segments) do
        local line = text.trim(tostring(seg.text or ""))
        local t0 = tonumber(seg.t0)
        local own = (m.t0 and t0 and t0 >= m.t0)
            or (#words(line) >= HEARD.ECHO_MIN_WORDS and isEcho(line, m.heard))
        if line ~= "" and not own and not guard.saidByBragi(line) then
            lines[#lines + 1] = line
        end
    end
    m.segments = #lines
    m.context = table.concat(lines, "\n")
    m.lookback = m.context
    ask(m)
end

function handlers.error(e)
    record("error", e)
    if type(e.code) == "string" and e.code:find("^engine%-") then
        -- The speech engine inside the app (bragi/voicemodels.lua words it).
        agent.addMessage("note", require("bragi.voicemodels").faultText(e), { error = true })
        voice.stop()
        app.publish("bragi.voiceAvailable")
    elseif e.code == "connect" or e.code == "no-ready" or e.code == "audio" then
        agent.addMessage("note", "Voice stopped: " .. tostring(e.message or e.code), { error = true })
        voice.stop()
    elseif e.code == "send" then
        return -- logged; the socket's close follows and says voice stopped
    elseif e.code == "no-message" then
        -- Send with no message open on the engine: the one shown is gone,
        -- and so are its words in the prompt box.
        if hearing then
            guard.forgetHearing()
            if current ~= "off" then
                setState("listening")
            end
        end
    elseif current ~= "off" then
        agent.addMessage("note", "Voice: " .. tostring(e.message or e.code), { error = true })
    end
end

--- Mic audio the network didn't take in time, dropped oldest first: when
-- (t to until, in the engine's times), how much, and how long the send in
-- progress had waited. At most a line a second while it lasts.
function handlers.drop(e)
    record("drop", { t = e.t, ["until"] = e["until"], count = e.count, queued = e.queued,
        sendingMs = e.sendingMs })
end

function handlers.mic(e)
    flushLevels() -- before the mic line, in time order
    local capture = nil
    if e.state == "on" and type(e.device) == "string" then
        mic.on = true
        mic.last = { at = os.date("%Y-%m-%d %H:%M"), device = e.device, route = e.route,
            echo = e.device:find("echo cancelled", 1, true) ~= nil,
            why = e.device:match("no echo cancellation: (.*)%)$") }
        gitgud.configWrite(mic.FILE, gitgud.jsonEncode(mic.last))
        capture = mic.mode(mic.last)
    elseif e.state == "off" then
        mic.on = false
    end
    -- Off carries what was captured (seconds, frames, dropped), so a
    -- session the engine heard nothing from shows here too.
    -- On names the microphone itself, so a wrong one shows in the log, and
    -- the route: the mic and echo reference opened and whether other apps'
    -- audio is kept from being turned down ("ducking opt-out"); `capture`
    -- says whether echo is cancelled.
    record("mic", { state = e.state, device = e.device, seconds = e.seconds,
        frames = e.frames, dropped = e.dropped, input = e.state == "on" and devices.inputName() or nil,
        route = e.route, capture = capture })
    app.publish("bragi.voiceMic", e.device)
end

--- For Settings: how the microphone captures, now or the last time it
-- was on (kept across restarts), with its route.
function voice.micLine()
    local m = mic.lastCapture()
    if not m then
        return "Turn on the mic in the Agent view to see."
    end
    local mode = mic.mode(m)
    local line = (mic.on and "Now: " or ("Last time (" .. tostring(m.at) .. "): ")) .. mode
        .. (m.echo and ". Bragi doesn't hear its own voice." or ". Bragi may hear its own voice; headphones help.")
    if type(m.route) == "string" and m.route ~= "" then
        line = line .. " Route: " .. m.route .. "."
    end
    return line
end

function handlers.closed(e)
    recorder.file = nil
    mic.on = false
    if current ~= "off" then
        record("closed", e)
        guard.connected = false
        guard.forgetHearing()
        dropApprovals()
        agent.addMessage("note", "Voice stopped" .. ((e.reason or "") ~= "" and (": " .. e.reason) or "."))
        setState("off")
        closeFollowUp("off")
    end
end

function handlers.playback(e)
    local now = gitgud.now()
    if e.state == "started" then
        playback = { id = e.id, started = now }
        local said = spokenText[e.id]
        if said then
            said.started = true
            said.startedAt = now
        end
        if approval and approval.sayId == e.id then
            approval.playing = true
        end
        if said and lastEnded and said.message == lastEnded.id then
            timing("firstSound", { reply = e.id, opening = said.opening })
        end
        if said and not said.narration then
            timing("sound", { reply = e.id })
        end
    elseif playback and playback.id == e.id then
        playback.stopped = now
    end
    if e.state ~= "started" and spokenText[e.id] then
        spokenText[e.id].stoppedAt = now
    end
    record("playback", { state = e.state, id = e.id, at = now })
    if current == "off" then
        return
    end
    -- The permission question has been said: listen for the answer.
    local asked = e.state ~= "started" and approval and approval.sayId == e.id and approval or nil
    if e.state == "started" then
        setState(current, "Speaking. Say \u{201C}" .. wakeWord() .. "\u{201D} to interrupt")
    else
        setState(current)
    end
    if asked then
        openWindow(asked)
    elseif e.state ~= "started" then
        openFollowUp(e.id)
    end
end

-- From the speak socket (voice.speech.<type>).
local speech = {}

--- A `say` from voice.preview, not a reply.
local function isPreview(id)
    return type(id) == "string" and id:find("^preview") ~= nil
end

--- Where replies play (the echo canceller's reference should be the same).
function speech.speaker(e)
    record("speaker", { device = e.device })
end

function speech.start(e)
    -- A preview's voice says nothing about what speaks replies.
    if e.provider and not isPreview(e.id) then
        setProviders({ tts = voice.PROVIDER_NAMES[e.provider] or e.provider, ttsFallback = e.fallback or "" })
    end
end

function speech.error(e)
    record("speech-error", e)
    agent.addMessage("note", (isPreview(e.id) and "Couldn't play the preview: " or "Couldn't speak the reply: ")
        .. tostring(e.message or e.code), { error = true })
end

-- Hot-reload: listening, the voice sockets, playback, and
-- the devices live in C++ and carry on through a reload. What this module
-- knew is kept ("app.reloading"), and once every module has started the
-- reloaded one takes listening up again where the backend still listens;
-- its helpers are taken up by bragi/helpers.lua. A message being filtered
-- at the time is sent as heard (bragi/agent.lua).
local KEPT = "bragi.voice"

local function keep()
    local json = gitgud.jsonEncode({ current = current, hearing = hearing, enrolled = enrolled,
        sentEndWait = sentEndWait, providers = providers, lastSent = guard.lastSent, decider = guard.decider })
    if json then
        gitgud.keepForReload(KEPT, json)
    end
end

local function reattach(kept)
    if not (voice.backend.listening and voice.backend.listening()) then
        return
    end
    kept = type(kept) == "table" and kept or {}
    -- The same connection goes on: its events aren't an old one's.
    guard.connected = true
    guard.lastSent = type(kept.lastSent) == "string" and kept.lastSent or nil
    -- `ready` isn't sent again: whether the turn-taking model is loaded is kept.
    guard.decider = kept.decider == true
    enrolled = kept.enrolled == true
    sentEndWait = tonumber(kept.sentEndWait) or voice.endWait()
    if type(kept.providers) == "table" then
        providers = kept.providers
    end
    hearing = type(kept.hearing) == "table" and kept.hearing or nil
    if hearing then
        -- The old scripts' timers and requests went with them: the model is
        -- asked again from here.
        hearing.decideTimer, hearing.asking = nil, nil
    end
    local state = (kept.current == "connecting" or kept.current == "hearing") and kept.current or "listening"
    if state == "hearing" and not hearing then
        state = "listening"
    end
    record("reattach", { state = state })
    setState(state)
    if hearing then
        agent.setHeard(hearing.text or "")
        guard.startDeciding()
    end
    warmHelpers()
end

--- The app closed while the engine was in a call last time
-- (gitgud.voiceEngine().lastCrash; a release while the app was closing
-- isn't one): voice stays off (bragi.voiceOff) until the mic button or
-- Settings turns it back on, and the conversation says why, once, with the
-- end of the engine's log in the voice log. The engine then forgets it, so
-- a reload doesn't say it again.
-- @param engine  gitgud.voiceEngine()'s table
function voice.noticeCrash(engine)
    if type(engine) ~= "table" or type(engine.lastCrash) ~= "table" then
        return
    end
    local why = require("bragi.voicemodels").crashText(engine.lastCrash)
    settings.set("bragi.voiceOff", why)
    record("engineCrash", { call = engine.lastCrash.call, log = engine.lastCrash.log })
    if gitgud.voiceEngineForgetCrash then
        gitgud.voiceEngineForgetCrash()
    end
    gitgud.after(0, function()
        agent.addMessage("note", why, { error = true })
    end)
end

--- Voice back on after a crash (the mic button, or Settings' Turn on).
function voice.clearCrash()
    settings.set("bragi.voiceOff", "")
    if gitgud.voiceEngineForgetCrash then
        gitgud.voiceEngineForgetCrash()
    end
    record("engineCrash", { cleared = true })
end

-- ===================================================================
-- Mute
-- ===================================================================
--
-- bragi.mute silences Bragi's voice and nothing else: replies, narration,
-- news and cards aren't said aloud (they still show), and listening goes
-- on. The button beside the mic and Settings (Voice output) both set it;
-- muting stops whatever is being said.

--- Whether Bragi's voice is muted.
function voice.muted()
    return settings.get("bragi.mute", false) == true
end

--- Whether Bragi speaks: Speak replies is on and it isn't muted.
function voice.speaks()
    return settings.get("bragi.speak", true) ~= false and not voice.muted()
end

--- Mute or unmute Bragi's voice.
-- @param opts  { fromSettings = true }: Settings set it (it isn't rebuilt)
function voice.setMuted(on, opts)
    on = on == true
    settings.set("bragi.mute", on)
    record("mute", { on = on })
    if on then
        guard.held = nil
        if voice.backend.playing() then
            voice.backend.speakStop(nil)
        end
        closeFollowUp("muted")
    end
    app.publish("bragi.muted", on)
    if not (opts and opts.fromSettings) then
        gitgud.after(0, function()
            require("bragi.settings").rebuild("appearance")
        end)
    end
end

-- ===================================================================
-- Recaps
-- ===================================================================
--
-- A spoken message the filter routes `recap` ("what's going on?", "catch
-- me up", in any words) is answered by bragi/recap.lua from the live state
-- of the conversations Bragi follows; its words are said as they are (the
-- helper writes them for speaking), never while you're talking or a card
-- is being asked (it waits), and a recap that asks something opens the
-- follow-up window like a reply.

--- Run fn now, or once you've stopped talking (the moment the message
-- ends: guard.flushHeld) and no card is being asked.
function guard.whenFree(fn)
    if approval then
        gitgud.after(1000, function()
            guard.whenFree(fn)
        end)
        return
    end
    if hearing then
        guard.afterHearing = guard.afterHearing or {}
        guard.afterHearing[#guard.afterHearing + 1] = fn
        return
    end
    fn()
end

--- A recap is ready for spoken message `id`: say it.
function guard.sayRecap(id, said)
    timing("answer", { recap = true }, id)
    if lastEnded and lastEnded.id == id then
        lastEnded.answered = true
    end
    if opener and opener.asking then
        opener.dropped = true
    end
    if not voice.speaks() then
        return
    end
    guard.whenFree(function()
        local spoken = plain(said)
        expectFollowUp(speak(spoken, { recap = true }), spoken)
    end)
end

--- A spoken slash command is running (bragi/slash.lua): say so, briefly.
function guard.sayCommand(id, said)
    timing("answer", { command = true }, id)
    if lastEnded and lastEnded.id == id then
        lastEnded.answered = true
    end
    if opener and opener.asking then
        opener.dropped = true
    end
    if not voice.speaks() then
        return
    end
    guard.whenFree(function()
        speak(plain(said), {})
    end)
end

-- ===================================================================
-- News from the conversations Bragi follows
-- ===================================================================
--
-- When a conversation the master started or sent work to finishes, fails,
-- or waits for a permission or an answer (bragi/master.lua's status rows,
-- "bragi.masterStatus"), Bragi says so aloud, several that come together
-- at once, never while you're talking or a card is being asked (it
-- waits). The quiet status rows stay as they are. With the mic off too
-- (dropping it then was unpleasant): the reply is written
-- into the master conversation and spoken all the same, when there's a
-- voice to speak it with; muted, it's only written.
--
-- saying it's done isn't enough; Bragi picks the
-- conversation back up the way a person would. bragi/recap.lua's helper
-- (prompts/recap.md, "News") is given each one's live state, its last
-- reply (its own sign-off) and what it waits on, and says what finished
-- and what it did, or what it's asking, then the likely next step or a
-- question for you. That goes into the master conversation as a reply
-- (riding along with the next message to it, so it carries on from
-- there), and is spoken; one that asks opens the follow-up window. When
-- the helper fails, a plain line says what happened instead.
--
-- the same long news four times, one count changed each
-- time. A done comes only once the work is over (bragi/master.lua,
-- master.holdDone: background tasks' reports go to the next update as
-- small items). The helper gets what Bragi last told about each one
-- (`told`) and its lines said lately (`said`), and says only what's new;
-- what it makes that repeats a line said lately is dropped here, a
-- sentence or the whole (guard.freshNews).

guard.NEWS_BATCH_MS = 1500 -- news this close together is told together
guard.news = {}            -- { what, tab, line }, one per conversation

-- "the loot tables" from a conversation's title: its first few words.
function guard.newsTitle(title)
    local list = {}
    for w in tostring(title or ""):gmatch("%S+") do
        list[#list + 1] = w
        if #list == 8 then
            list[#list] = w .. "..."
            break
        end
    end
    return #list > 0 and table.concat(list, " ") or "a conversation"
end

function guard.queueNews(e)
    if type(e) ~= "table" or type(e.tab) ~= "table" then
        return
    end
    local what = e.what
    local project = tostring(e.tab.cwd or ""):gsub("[\\/]+$", ""):match("([^\\/]+)$")
    local name = "\u{201C}" .. guard.newsTitle(e.tab.title) .. "\u{201D}" .. (project and (" in " .. project) or "")
    local line = (what == "done" and (name .. " is done"))
        or (what == "failed" and (name .. " stopped with an error"))
        or (what == "permission" and (name .. " needs your permission"))
        or (what == "question" and (name .. " has a question for you"))
    if not line then
        return
    end
    -- One per conversation: the latest news about it.
    for i, n in ipairs(guard.news) do
        if n.tab == e.tab then
            table.remove(guard.news, i)
            break
        end
    end
    guard.news[#guard.news + 1] = { what = what, tab = e.tab, line = line }
    updates.clear(e.tab) -- its steps are old news now
    if not guard.newsTimer then
        guard.newsTimer = gitgud.after(guard.NEWS_BATCH_MS, guard.sayNews)
    end
end

--- Say what the helper made (or the plain lines), once you're not talking:
-- at once, before any update not playing yet (news cuts
-- in, whenever the last update was).
function guard.speakNews(said, fields)
    guard.whenFree(function()
        record("news", fields)
        dropQueuedNarration("news")
        local spoken = plain(said)
        expectFollowUp(speak(spoken, { news = true, offOk = true }), spoken, require("bragi.master").tab())
    end)
end

--- Whether news is said aloud now: Bragi speaks (not muted), and with the
-- mic off, the speech engine is there.
function guard.newsSpoken()
    return voice.speaks() and (current ~= "off" or voice.available())
end

function guard.sayNews()
    guard.newsTimer = nil
    if #guard.news == 0 then
        return
    end
    if approval or guard.newsAsking then
        -- One telling at a time, never over a card: again in a moment.
        -- While you talk it's made all the same, and said once you stop
        -- (speakNews).
        guard.newsTimer = gitgud.after(1000, guard.sayNews)
        return
    end
    local batch = guard.news
    guard.news = {}
    local master = require("bragi.master")
    local list, lines = {}, {}
    for _, n in ipairs(batch) do
        -- `told`: what Bragi last said about it, so only what's new since
        -- is said.
        list[#list + 1] = { what = n.what, conversation = master.describe(n.tab), told = n.tab.bragiTold }
        lines[#lines + 1] = n.line
    end
    local started = gitgud.now()
    guard.newsAsking = true
    require("bragi.recap").ask({ news = list, said = guard.lately(3) }, function(said, err)
        guard.newsAsking = false
        local fields = { count = #batch, ms = gitgud.now() - started }
        if said ~= "" then
            -- Never the same sentence twice.
            local fresh = guard.freshNews(said)
            if fresh ~= said then
                record("news-dropped", { text = said, kept = fresh })
            end
            if fresh == "" then
                return
            end
            said = fresh
        end
        if said == "" then
            -- The helper couldn't: what happened, plainly.
            fields.failed = tostring(err)
            said = table.concat(lines, ". ") .. "."
        else
            -- A reply in the master conversation, so it carries on from it.
            local m = master.tab()
            if m then
                agent.quickAnswered(nil, nil, said, { tab = m, update = true })
            end
        end
        for _, n in ipairs(batch) do
            n.tab.bragiTold = said
        end
        guard.noteSaid(said)
        fields.text = said
        fields.mic = current == "off" and "off" or nil
        if guard.newsSpoken() then
            guard.speakNews(said, fields)
        else
            record("news", fields)
        end
    end)
end

function voice.init()
    gitgud.on("app.reloading", keep)
    app.subscribe("bragi.masterStatus", guard.queueNews)
    local kept = gitgud.jsonDecode(gitgud.takeKept(KEPT) or "")
    gitgud.after(0, function()
        reattach(kept)
    end)
    -- The microphone and speakers picked in Settings or setup ("" = the
    -- default), and the speaker delay. A new pick while listening restarts
    -- the capture with it.
    devices.apply()
    local function pickedNow()
        return settings.get("bragi.micDevice", "") .. "\n" .. settings.get("bragi.speakerDevice", "") .. "\n"
            .. devices.echoDelay()
    end
    local picked = pickedNow()
    app.subscribe("bragi.choices", function()
        -- A new wait (Settings, or the agent's settings tool) reaches the
        -- engine while listening.
        if current ~= "off" and voice.endWait() ~= sentEndWait and voice.backend.config then
            sentEndWait = voice.endWait()
            voice.backend.config({ endWaitSeconds = sentEndWait })
        end
        local now = pickedNow()
        if now == picked then
            return
        end
        picked = now
        devices.apply()
        if current ~= "off" then
            gitgud.after(0, function()
                if current ~= "off" then
                    record("devices", { input = devices.inputName() })
                    voice.stop()
                    voice.toggle()
                end
            end)
        end
    end)
    -- Events about the connection's speech: before its `ready`, they're an
    -- old connection's (the engine's message ids start again at m1 on
    -- each; old text could come back into the prompt box).
    local fromConnection = { wake = true, partial = true, pause = true, message = true, cancelled = true,
        lookback = true, ambient = true }
    for kind, fn in pairs(handlers) do
        gitgud.on("voice." .. kind, function(detail)
            local e = gitgud.jsonDecode(detail)
            e = type(e) == "table" and e or {}
            if fromConnection[kind] and not guard.connected then
                -- From a connection that's gone: its ids may be the new one's.
                record("stale", { kind = kind, id = e.id })
                return
            end
            fn(e)
        end)
    end
    for kind, fn in pairs(speech) do
        gitgud.on("voice.speech." .. kind, function(detail)
            local e = gitgud.jsonDecode(detail)
            fn(type(e) == "table" and e or {})
        end)
    end
    helpers.init()
    voice.noticeCrash(require("bragi.voicemodels").engine())
    -- A pack installed or a voice made: the voices for replies again.
    for _, signal in ipairs({ "bragi.voiceAvailable", "bragi.voicesChanged" }) do
        app.subscribe(signal, function()
            gitgud.after(0, function()
                voice.checkVoices(true)
            end)
        end)
    end
    -- Baldr, Bragi's own voice, once its model is in (made once,
    -- without asking).
    app.subscribe("bragi.voiceAvailable", function()
        require("bragi.voicemodels").ensureBaldr()
    end)
    gitgud.after(3000, function()
        local models = require("bragi.voicemodels")
        models.ensureBaldr()
        -- Models an app update replaced: in again without asking (the user
        -- said yes to them before).
        if models.engineInstalled() and (models.update() or models.update("decide")) then
            record("models", { update = true })
        end
    end)
    -- While they come in, the note about them follows (at most twice a
    -- second, the last state always); once they're in, voice starts if the
    -- mic was pressed meanwhile, else the note says they're in. Either way
    -- it's left as it is from then on.
    local noteAt, noteTimer = 0, nil
    local function followNote()
        noteTimer = nil
        local items = agent.items()
        if not guard.modelsNote or items[#items] ~= guard.modelsNote then
            return
        end
        noteAt = gitgud.now()
        local models = require("bragi.voicemodels")
        if models.installing() or not voice.available() then
            local text = voice.unavailableText()
            agent.updateNote(guard.modelsNote, guard.startWhenReady and text .. " Voice turns on when they're in."
                or text)
        elseif not guard.startWhenReady then
            agent.updateNote(guard.modelsNote, "The speech models are in. Press the mic to talk.")
            guard.modelsNote = nil
        end
    end
    app.subscribe("bragi.voiceModels", function()
        local s = require("bragi.voicemodels").state()
        if s.phase == "failed" and s.group == "listen" then
            guard.startWhenReady = false
        end
        local wait = 500 - (gitgud.now() - noteAt)
        if wait <= 0 then
            followNote()
        elseif not noteTimer then
            noteTimer = gitgud.after(wait, followNote)
        end
    end)
    app.subscribe("bragi.voiceAvailable", function()
        if not guard.startWhenReady then
            return
        end
        guard.startWhenReady = false
        if guard.modelsNote then
            agent.updateNote(guard.modelsNote, require("bragi.voicemodels").state().update
                and "The speech models are updated." or "The speech models are in.")
            guard.modelsNote = nil
        end
        gitgud.after(0, function()
            if current == "off" and voice.available() then
                voice.toggle()
            end
        end)
    end)
    -- A conversation shown while voice is on starts its session now, as
    -- the one shown when listening began did: the first spoken message
    -- doesn't wait out Claude Code's start-up (Bragi's
    -- conversation, opened after voice, waited 30 s for an MCP server).
    -- A moment later, once the master has configured its tab.
    app.subscribe("bragi.tabShown", function(tab)
        gitgud.after(0, function()
            if current ~= "off" and agent.current() == tab then
                agent.warm()
            end
        end)
    end)
    app.subscribe("bragi.tabShown", guard.onShown)
    app.subscribe("bragi.sent", guard.onSent)
    updates.thread = agent.current()
    app.subscribe("bragi.reply", onReply)
    app.subscribe("bragi.answering", onAnswering)
    app.subscribe("bragi.activity", onActivity)
    app.subscribe("bragi.step", guard.onStep)
    app.subscribe("bragi.permission", onPermission)
    app.subscribe("bragi.submitted", onSubmitted)
    app.subscribe("bragi.permissionAnswered", onPermissionAnswered)
    setState("off")
end

function voice.refresh()
end

return voice
