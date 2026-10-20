--- tests/ui/bragi-voice-exit.lua: closing GitGud with Baldr loaded, on
-- the real speech engine (not in the default suite). Voice on, one reply in
-- Baldr, then the window closes; the runner starts it again and checks that
-- the app exited cleanly and left no crash for the next start (the engine's
-- markers clear, "exit: models released" in its log), ten times on the
-- processor and ten on the GPU.
--
-- Needs the real models in the scratch LOCALAPPDATA (bragi/voice, as the
-- Bragi interface installs them; with the GPU libraries for the GPU runs),
-- GITGUD_TEST_QUIET_AUDIO=1 (quiet microphone and speaker: nothing plays in
-- the room), and GITGUD_TEST_EXIT_DEVICE=cpu|gpu. Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local device = os.getenv("GITGUD_TEST_EXIT_DEVICE") or "cpu"
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

local function baldrMade()
    for _, v in ipairs(voicemodels.voices()) do
        if v.id == "turbo:baldr" then
            return true
        end
    end
    return false
end

step(1500, "voice on", function()
    check("the models and Baldr's are in", voicemodels.installed() and voicemodels.installed("turbo"))
    check("the GPU libraries as expected", voicemodels.installed("gpu") == (device == "gpu"))
    check("no crash noted from last time", (require("core.settings").get("bragi.voiceOff", "")) == "")
    voice.toggle()
end)
step(60000, "listening, and Baldr made", function()
    check("listening", voice.state() == "listening")
    check("Baldr is there", baldrMade())
    gitgud.voiceSpeak("exit1", "Done. Closing now.", { voice = "turbo:baldr" })
end)
step(120000, "one reply in Baldr", function()
    check("spoken", ended("exit1"))
    check("by Baldr on the " .. device, startOf("exit1") ~= nil
        and startOf("exit1").provider == (device == "gpu" and "turbo" or "turbo-cpu"))
end)
step(300, "close the window", function()
    gitgud.emit("window.close", "")
end)

harness.run()
