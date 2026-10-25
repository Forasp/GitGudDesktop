--- tests/ui/bragi-voice-exit.lua: closing GitGud with the built-in voice
-- loaded, on the real speech engine (not in the default suite). Voice on,
-- one reply in the built-in voice, then the window closes; the runner starts
-- it again and checks that the app exited cleanly and left no crash for the
-- next start (the engine's markers clear, "exit: models released" in its
-- log), ten times.
--
-- Needs the real models in the scratch LOCALAPPDATA (bragi/voice, as the
-- Bragi interface installs them) and GITGUD_TEST_QUIET_AUDIO=1 (quiet
-- microphone and speaker: nothing plays in the room). Prints "[check] ...".

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

local started = {}
local endedList = {}
gitgud.on("voice.speech.start", function(detail)
    started[#started + 1] = gitgud.jsonDecode(detail or "") or {}
end)
gitgud.on("voice.speech.end", function(detail)
    endedList[#endedList + 1] = gitgud.jsonDecode(detail or "") or {}
end)

-- The reply's own start (narration or notes may speak too).
local function startOf(id)
    for _, s in ipairs(started) do
        if s.id == id then
            return s
        end
    end
    return nil
end

local function ended(id)
    for _, e in ipairs(endedList) do
        if e.id == id then
            return true
        end
    end
    return false
end

step(1500, "voice on", function()
    check("the models are in, and the built-in voice", voicemodels.installed() and voicemodels.smallReady())
    check("no crash noted from last time", (require("core.settings").get("bragi.voiceOff", "")) == "")
    voice.toggle()
end)
step(60000, "listening", function()
    check("listening", voice.state() == "listening")
end)
step(300, "a reply", function()
    voice.backend.speak("exit1", "Done. Closing now.", { voice = voicemodels.smallVoiceId(), speed = 1.27 })
end)
step(30000, "one reply in the built-in voice", function()
    check("spoken", ended("exit1"))
    check("by the built-in voice", startOf("exit1") ~= nil and startOf("exit1").provider == "small")
end)
step(300, "close the window", function()
    gitgud.emit("window.close", "")
end)

harness.run()
