--- tests/ui/bragi-small-voice.lua: Bragi's built-in voice end to end, on the
-- real speech engine: the engine set up with the interface's small voice
-- only (no listening models are needed for this), a reply given to
-- voice.backend.speak as text, made phonemes there (bragi.phonemes), and
-- spoken by the engine on the processor at the voice's rate: speech.start
-- (provider "small", sampleRate 21120), the audio played, speech.end.
--
-- Run it like bragi-voice-exit.lua: GITGUD_UI=bragi, GITGUD_TEST_QUIET_AUDIO
-- (nothing plays aloud), a scratch APPDATA and LOCALAPPDATA ("sandbox" in
-- the path), a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, and a build with the speech engine (voice/ beside the exe). Prints
-- "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local localData = os.getenv("LOCALAPPDATA") or ""
if gitgud.currentUi().id ~= "bragi" or not os.getenv("GITGUD_TEST_QUIET_AUDIO")
    or not localData:lower():find("sandbox", 1, true) or not gitgud.voiceEngine().installed then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_QUIET_AUDIO, a scratch LOCALAPPDATA, and the speech engine", false)
    gitgud.emit("window.close", "")
    return
end

local voice = require("bragi.voice")
local voicemodels = require("bragi.voicemodels")

local started, ended, errors, played = {}, {}, {}, 0
gitgud.on("voice.speech.start", function(detail)
    started[#started + 1] = gitgud.jsonDecode(detail or "") or {}
end)
gitgud.on("voice.speech.end", function(detail)
    ended[#ended + 1] = gitgud.jsonDecode(detail or "") or {}
end)
gitgud.on("voice.speech.error", function(detail)
    errors[#errors + 1] = gitgud.jsonDecode(detail or "") or {}
end)
gitgud.on("voice.playback", function()
    played = played + 1
end)

step(300, "the built-in voice is there", function()
    check("ready", voicemodels.smallReady())
    check("its folder", voicemodels.smallVoicesDir() ~= nil)
    check("its dictionaries", voicemodels.phonemesDir() ~= nil)
    -- The engine needs the listening models' paths; they're only loaded
    -- when listening starts, which this never does.
    local scratch = localData .. "/small-voice-test"
    local ok, err = gitgud.voiceEngineSetup({
        vadModel = scratch .. "/vad.onnx", asrDir = scratch .. "/asr", kwsDir = scratch .. "/kws",
        workDir = scratch .. "/work",
        small = { voicesDir = voicemodels.smallVoicesDir(), threads = voicemodels.SMALL.threads },
    })
    check("the engine takes it", ok == true)
    if not ok then
        print("[small] setup: " .. tostring(err))
    end
end)

-- No checks in this step: the harness tries a step's `local x = ...` lines
-- ahead of time, which would say it twice.
local sent = {}
step(200, "speak a reply", function()
    sent.ok, sent.err = voice.backend.speak("s1", "Okay, I've started the tests on the rebase branch.",
        { voice = voicemodels.smallVoiceId(), speed = voicemodels.SMALL.speed })
end)

step(20000, "spoken", function()
    check("sent", sent.ok == true)
    check("it ended", ended[1] ~= nil and ended[1].id == "s1")
    check("said once", #started == 1 and #ended == 1)
    local s = started[1] or {}
    print("[small] start: " .. (gitgud.jsonEncode(s) or "") .. ", played " .. played .. ", errors "
        .. (gitgud.jsonEncode(errors) or "") .. ", sent " .. tostring(sent.ok) .. " " .. tostring(sent.err or ""))
    check("by the built-in voice", s.provider == "small")
    check("at its rate", s.sampleRate == voicemodels.SMALL.rate)
    check("no errors", #errors == 0)
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
