--- tests/ui/bragi-voice-engine.lua: voice through the real bindings and
-- sessions, with the stand-in speech engine (gitgud.voiceTestEngine: the
-- speech/FakeEngine links and quiet devices, so no microphone or speaker
-- opens). Before it: what the mic button says with no models. With it:
-- voice on (hello, ready, listening), a message started and sent (wake,
-- message), a reply spoken (start, speech, end, playback), voice off.
-- With the voice pack: Baldr made without asking and the default for
-- replies; your own voice made (optional), chosen, in Settings, removed.
-- Then
-- the engine faulting on hello: voice stops with the restart message. And
-- the app having closed in the engine last time: voice stays off with the
-- reason until Settings turns it back on. Last, the mic pressed before the
-- models are in, then an install played through (the models' state stood
-- in for): the mic's note follows it (at most twice a second, the last
-- state always), says why it failed, and once they're in says so and is
-- left as it is.
--
-- Run it like bragi-voice.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_TEST_CLAUDE). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

if gitgud.currentUi().id ~= "bragi" or not gitgud.voiceTestEngine then
    check("needs GITGUD_UI=bragi and a build with gitgud.voiceTestEngine", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local app = require("core.app")
local bragiSettings = require("bragi.settings")
local settings = require("core.settings")
local shell = require("bragi.shell")
local voice = require("bragi.voice")
local voicemodels = require("bragi.voicemodels")

-- What came from the engine, by type.
local events = {}
for _, kind in ipairs({ "ready", "wake", "message", "error", "closed", "speech.start", "speech.end", "playback",
    "mic" }) do
    gitgud.on("voice." .. kind, function(detail)
        events[kind] = events[kind] or {}
        table.insert(events[kind], gitgud.jsonDecode(detail or "") or {})
    end)
end
local function lastOf(kind)
    local list = events[kind] or {}
    return list[#list] or {}
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

step(1500, "no models yet", function()
    shell.show("agent")
    settings.set("bragi.voiceOff", nil)
    local engine = gitgud.voiceEngine()
    if engine.installed then
        -- This build has the engine: without models, voice says what's missing.
        check("voice needs its models", not voice.available())
        check("the mic says how big they are",
            voice.unavailableText():find("^Voice needs its models first: about 228 MB") ~= nil)
    else
        check("no engine: voice isn't in this build", voice.unavailableText() == voice.UNAVAILABLE)
    end
    check("nothing loaded", not engine.loaded)
end)

step(300, "the stand-in engine", function()
    check("switched", gitgud.voiceTestEngine("fake") == true)
    check("it says so", gitgud.voiceEngine().test == "fake")
    check("voice is available with it", voice.available())
    check("its models count as installed", voicemodels.installed())
    voice.toggle()
end)
step(800, "listening", function()
    check("hello answered", lastOf("ready").version == 0 and lastOf("ready").keywords == true)
    check("the quiet microphone opened", lastOf("mic").state == "on"
        and tostring(lastOf("mic").device):find("Test microphone", 1, true) ~= nil)
    check("listening", voice.state() == "listening")
    check("the providers known", voice.providerLine("stt") == "test.")
    gitgud.voiceWake()
end)
step(500, "a message", function()
    check("woken", lastOf("wake").id == "m1")
    check("hearing", voice.state() == "hearing")
    gitgud.voiceSend("button")
end)
step(800, "sent", function()
    check("the message came", lastOf("message").text == "hello from the test engine"
        and lastOf("message").endedBy == "send")
    check("listening again", voice.state() == "listening")
    check("it's in the voice log", (table.concat(voice.logLines(), "\n")):find("hello from the test engine", 1, true)
        ~= nil)
    check("speaking", gitgud.voiceSpeak("t1", "Hello there.") == true)
end)
step(800, "spoken", function()
    check("speech started", lastOf("speech.start").id == "t1" and lastOf("speech.start").provider == "test")
    check("and ended", lastOf("speech.end").id == "t1")
    check("played", #(events.playback or {}) >= 1)
    voice.stop()
end)
step(800, "voice off", function()
    check("off", voice.state() == "off")
    check("the session closed", lastOf("closed").code ~= nil)
    check("nothing listening", not gitgud.voiceInfo().listening)
end)

-- With the voice pack (the stand-in counts as having it): Baldr, Bragi's
-- own voice, is made without asking and is the default for replies.
step(300, "the voice pack is in", function()
    check("replies can use Turbo", voicemodels.turboReady())
    settings.set("bragi.voice", "")
    app.publish("bragi.voiceAvailable")
end)
step(800, "Baldr is there", function()
    check("made without asking", voicemodels.voices()[1] ~= nil and voicemodels.voices()[1].id == "turbo:baldr"
        and voicemodels.voices()[1].name == "Baldr" and voicemodels.voices()[1].builtin)
    check("nothing chosen", settings.get("bragi.voice", "") == "")
    voice.checkVoices(true)
end)
step(300, "Baldr speaks replies", function()
    local list = voice.voices().list or {}
    check("first in the list, as a made voice", list[1] ~= nil and list[1].id == "turbo:baldr"
        and list[1].provider == "Made voice")
    check("the default", voice.voices().default == "turbo:baldr")
    check("in use", voice.chosenVoice() ~= nil and voice.chosenVoice().id == "turbo:baldr")
end)

-- Settings: the device Baldr runs on, and a Windows voice for faster replies.
local function repliesCard()
    for _, c in ipairs(voicemodels.cards({ settings = true })) do
        if c.heading == "Voice for replies" then
            return c
        end
    end
    return nil
end
local function rowTitled(card, title)
    for _, row in ipairs(card and card.rows or {}) do
        if row.title == title then
            return row
        end
    end
    return nil
end
step(300, "a Windows voice instead", function()
    local card = repliesCard()
    check("Baldr says where it runs", card ~= nil and card.rows[1].title == "Baldr"
        and card.rows[1].sub:find("^Bragi's own voice, on the ") ~= nil)
    local switch = rowTitled(card, "Faster replies: use a Windows voice")
    check("Settings offers a Windows voice", switch ~= nil and switch.button == "Use Windows voice")
    if switch and (gitgud.voiceVoices() or {})[1] then
        switch.run()
    end
end)
step(300, "replies in a Windows voice", function()
    local windows = (gitgud.voiceVoices() or {})[1]
    if windows then
        check("a Windows voice is chosen", settings.get("bragi.voice", "") == windows.id)
        local back = rowTitled(repliesCard(), "Replies use a Windows voice")
        check("and Baldr is one click away", back ~= nil and back.button == "Use Baldr")
        if back then
            back.run()
        end
    end
end)
step(300, "back to Baldr", function()
    check("Baldr again", settings.get("bragi.voice", "") == "")
end)

-- Making your own voice: optional, in Settings.
local madeVoice = nil
step(300, "make your own voice", function()
    voicemodels.makeVoice("no-such-recording.wav", "Test voice", function(ok, label)
        madeVoice = { ok = ok, label = label }
    end)
end)
step(500, "the voice is made", function()
    check("made", madeVoice ~= nil and madeVoice.ok and madeVoice.label == "Test voice")
    check("listed after Baldr", voicemodels.voices()[2] ~= nil and voicemodels.voices()[2].id == "turbo:test-voice"
        and voicemodels.voices()[2].name == "Test voice")
    check("chosen for replies", settings.get("bragi.voice", "") == "turbo:test-voice")
    voice.checkVoices(true)
end)
step(300, "in Settings", function()
    check("chosen", voice.chosenVoice() ~= nil and voice.chosenVoice().id == "turbo:test-voice")
    local card = nil
    for _, c in ipairs(voicemodels.cards({ settings = true })) do
        if c.heading == "Voice for replies" then
            card = c
        end
    end
    check("Baldr first, without Remove", card ~= nil and card.rows[1].title == "Baldr" and card.rows[1].kind == "info")
    check("then yours, with Remove", card ~= nil and card.rows[2].title == "Test voice" and card.rows[2].button == "Remove")
    check("the Windows voices one click away", card ~= nil and card.rows[3].title == "Faster replies: use a Windows voice")
    check("making one stays optional", card ~= nil and card.rows[4].title == "Make your own voice (optional)")
    check("the welcome flow doesn't ask for a voice", (function()
        for _, c in ipairs(voicemodels.cards()) do
            if c.heading == "Voice for replies" then
                return false
            end
        end
        return true
    end)())
    voicemodels.removeVoice("test-voice")
end)
step(300, "your voice removed", function()
    check("Baldr stays", #voicemodels.voices() == 1 and voicemodels.voices()[1].id == "turbo:baldr")
    check("back to Baldr", settings.get("bragi.voice", "") == "")
    -- Voice starts afresh: its voices list isn't known yet when the first
    -- reply goes out.
    voice.voices().list = nil
    voice.toggle()
end)
step(800, "listening again", function()
    check("listening", voice.state() == "listening")
    voice.voices().list = nil -- still not known
    voice.say("Done, the first reply.")
end)
step(800, "the first reply is Baldr's", function()
    local spoke = nil
    for _, line in ipairs(voice.logLines()) do
        if line:find(" speak ", 1, true) and line:find("Done, the first reply.", 1, true) then
            spoke = line
        end
    end
    check("it named Baldr, not the system's default", spoke ~= nil and spoke:find("\"voice\":\"turbo:baldr\"", 1, true) ~= nil)
    voice.stop()
end)

step(300, "an engine that faults", function()
    events = {}
    check("switched", gitgud.voiceTestEngine("fault") == true)
    voice.toggle()
end)
step(1000, "voice stopped", function()
    check("the fault came", lastOf("error").code == "engine-fault" and lastOf("error").restart == true)
    check("voice is off", voice.state() == "off")
    local note = last("note")
    check("it says to restart", note ~= nil
        and note.text == "Voice stopped after an internal error in the speech engine. Restart GitGud to use voice again.")
end)

local WHY = "Last time, GitGud closed while voice was transcribing, so voice is off for now. "
    .. "Press the mic button to turn it back on."
local function notesSaying(s)
    local n = 0
    for _, item in ipairs(agent.items()) do
        if item.kind == "note" and item.text == s then
            n = n + 1
        end
    end
    return n
end

-- A release while the app was closing isn't a crash: the engine doesn't
-- report it (lastCrash is nil), and voice stays as it was.
step(300, "the app closed during an exit-time release", function()
    gitgud.voiceTestEngine("fake")
    voice.noticeCrash({ installed = true })
end)
step(300, "nothing to say", function()
    check("voice isn't turned off", settings.get("bragi.voiceOff", "") == "")
    check("and no note", notesSaying(WHY) == 0)
    voice.noticeCrash({ installed = true, lastCrash = { call = "transcribe", log = "ort: failed\n" } })
end)
step(300, "the app closed in the engine while in use", function()
    check("the conversation says why, once", notesSaying(WHY) == 1)
    check("without sending you to repair the models", not WHY:find("repair", 1, true))
    check("remembered", settings.get("bragi.voiceOff", "") == WHY)
    events = {}
    voice.toggle()
end)
step(800, "the mic turns it back on", function()
    check("listening", voice.state() == "listening" and events.ready ~= nil)
    check("the switch is cleared", settings.get("bragi.voiceOff", "") == "")
    check("and the note wasn't said again", notesSaying(WHY) == 1)
    voice.stop()
end)
step(500, "off again; another crash", function()
    voice.noticeCrash({ installed = true, lastCrash = { call = "transcribe", log = "ort: failed\n" } })
    bragiSettings.open("appearance")
end)
step(600, "Settings, scrolled to its end", function()
    local x, y, w, h = gitgud.getRect("SettingsContent")
    gitgud.simulateScroll(x + w / 2, y + h / 2, -40)
end)
step(400, "Settings turns it back on", function()
    -- Voice models, before the credits (the stand-in counts as installed):
    -- its last row is the switch.
    local found = nil
    for card = 1, 12 do
        for row = 1, 8 do
            if gitgud.getText(bragiSettings.widget(card, row, "Action")) == "Turn on" then
                found = { card, row }
            end
        end
    end
    check("Settings shows voice is off, with Turn on", found ~= nil)
    if found then
        -- Scrolled back up until the button shows.
        local name = bragiSettings.widget(found[1], found[2], "Action")
        local cx, cy, cw, ch = gitgud.getRect("SettingsContent")
        for _ = 1, 30 do
            local _, by, _, bh = gitgud.getRect(name)
            if by >= cy and by + bh <= cy + ch then
                break
            end
            gitgud.simulateScroll(cx + cw / 2, cy + ch / 2, by < cy and 2 or -2)
        end
        local x, y, w, h = gitgud.getRect(name)
        gitgud.simulateClick(x + w / 2, y + h / 2, "left")
    end
end)
step(600, "on again", function()
    check("the switch is cleared", settings.get("bragi.voiceOff", "") == "")
    shell.show("agent")
    voice.toggle()
end)
step(800, "listening after all", function()
    check("listening", voice.state() == "listening")
    voice.stop()
    gitgud.voiceTestEngine(nil)
end)

-- The install, played here: the models' state and what's asked of it.
local played = { phase = "idle" }
local realModels = {}
local realAvailable = voice.backend.available
local function play(s)
    played = s
    app.publish("bragi.voiceModels", s)
end
local function noteText()
    local note = last("note")
    return note and note.text or ""
end
local INSTALLING = "Installing the speech models. "
step(300, "the mic pressed before the models are in", function()
    for _, name in ipairs({ "engineInstalled", "engine", "state", "installing", "updating", "installed", "update",
        "progressText" }) do
        realModels[name] = voicemodels[name]
    end
    local function busy()
        return played.phase ~= "idle" and played.phase ~= "done" and played.phase ~= "failed"
    end
    voicemodels.engineInstalled = function()
        return true
    end
    voicemodels.engine = function()
        return { installed = true }
    end
    voicemodels.state = function()
        return played
    end
    voicemodels.installing = function()
        return busy() and played.group == "listen"
    end
    voicemodels.updating = function()
        return false
    end
    voicemodels.installed = function()
        return played.phase == "done"
    end
    voicemodels.update = function()
        return false
    end
    voicemodels.progressText = function()
        return played.line or ""
    end
    voice.backend.available = function()
        return played.phase == "done"
    end
    voice.toggle()
    check("voice stays off", voice.state() == "off")
    check("the note says what's missing", noteText():find("^Voice needs its models first: about ") ~= nil)
end)
step(700, "installed from Settings", function()
    play({ phase = "download", group = "listen", line = "Downloading 10%." })
    check("the note follows", noteText() == INSTALLING .. "Downloading 10%.")
    check("as a first install, not an update", noteText():find("Updating", 1, true) == nil)
    play({ phase = "download", group = "listen", line = "Downloading 20%." })
    check("not twice in half a second", noteText() == INSTALLING .. "Downloading 10%.")
end)
step(700, "the last state follows", function()
    check("then the newer one", noteText() == INSTALLING .. "Downloading 20%.")
    play({ phase = "download", group = "listen", line = "Downloading 90%." })
    play({ phase = "failed", group = "listen", error = "the network went away" })
end)
step(700, "it failed", function()
    check("the failure isn't lost", noteText()
        == "The speech models didn't install: the network went away. Settings, Appearance and voice, Voice models.")
    check("and doesn't say voice turns on", noteText():find("turns on", 1, true) == nil)
    play({ phase = "download", group = "listen", line = "Downloading 50%." })
    play({ phase = "check", group = "listen", line = "Loading every model once to check them." })
    play({ phase = "done", group = "listen" })
end)
step(700, "they're in", function()
    check("the note says so", noteText() == "The speech models are in. Press the mic to talk.")
    check("voice is still off", voice.state() == "off")
    play(played) -- a voice being made publishes too
end)
step(700, "left as it is", function()
    check("the note stays", noteText() == "The speech models are in. Press the mic to talk.")
    for name, fn in pairs(realModels) do
        voicemodels[name] = fn
    end
    voice.backend.available = realAvailable
end)

step(500, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
