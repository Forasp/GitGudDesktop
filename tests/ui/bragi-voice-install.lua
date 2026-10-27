--- tests/ui/bragi-voice-install.lua: the voice models installed for real,
-- from a folder with the downloads (GITGUD_TEST_VOICE_FOLDER: the four
-- files as the sherpa-onnx releases have them), into the scratch local app
-- data; checked by the engine (every model loaded and run once). Then the
-- turn-taking model on its own, from GITGUD_TEST_DECIDER_FOLDER when it's
-- set (its two files), else from the same folder (where it isn't): an
-- install of its own, never Baldr's. Then removed, the turn-taking model
-- with the rest. Needs a build with the speech engine. Not in the default
-- suite: it unpacks about 260 MB.
--
-- Run it like bragi-voice.lua, with GITGUD_TEST_VOICE_FOLDER set and a
-- scratch LOCALAPPDATA. Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local folder = os.getenv("GITGUD_TEST_VOICE_FOLDER")
local localData = os.getenv("LOCALAPPDATA") or ""
if gitgud.currentUi().id ~= "bragi" or not folder or not localData:lower():find("sandbox", 1, true)
    or not gitgud.voiceEngine().installed then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_VOICE_FOLDER, a scratch LOCALAPPDATA, and the speech engine", false)
    gitgud.emit("window.close", "")
    return
end

local voice = require("bragi.voice")
local voicemodels = require("bragi.voicemodels")

-- How long each step took (printed as "[timing] ..."), and that every
-- measured step reported numbers that moved.
local app = require("core.app")
local phaseKey, phaseAt = nil, nil
local moved = {}
app.subscribe("bragi.voiceModels", function(s)
    local key = s.phase .. " " .. tostring(s.package and (s.package.id or s.package.title) or "")
    if (s.done or 0) > 0 then
        moved[s.phase] = true
    end
    if key ~= phaseKey then
        local now = gitgud.now()
        if phaseKey then
            print(string.format("[timing] %s: %d ms", phaseKey, now - phaseAt))
        end
        phaseKey, phaseAt = key, now
    end
end)

local function finished()
    local phase = voicemodels.state().phase
    return phase == "done" or phase == "failed"
end

step(1000, "nothing installed", function()
    check("all four missing", #voicemodels.missing() == 4)
    check("voice isn't available", not voice.available())
    voicemodels.installFrom(folder)
end)
step(600000, "installed and checked", function()
    check("the install finished", finished())
    check("and passed its check", voicemodels.state().phase == "done")
    check("checking and unpacking reported their progress", moved.verify == true and moved.unpack == true)
    check("nothing missing", #voicemodels.missing() == 0)
    check("voice is available", voice.available())
    check("released after the check", not gitgud.voiceEngine().loaded)
    check("the downloads folder is empty", #gitgud.localDataList("bragi/voice/staging") == 0)
end)
local deciderFolder = os.getenv("GITGUD_TEST_DECIDER_FOLDER")
step(300, "the turn-taking model on its own", function()
    voicemodels.installFrom(deciderFolder or folder, "decide")
end)
step(60000, "its own install", function()
    local s = voicemodels.state()
    check("the install finished", finished())
    check("as the turn-taking model's", s.group == "decide")
    if deciderFolder then
        check("installed", s.phase == "done" and voicemodels.deciderReady())
        check("with its own note", s.note == "Installed. Bragi uses it the next time listening starts.")
    else
        check("not in that folder", s.phase == "failed" and tostring(s.error):find("none of the files", 1, true) ~= nil)
    end
    check("Baldr isn't made", #voicemodels.voices() == 0)
end)
step(500, "removed", function()
    voicemodels.remove()
    check("all four missing again", #voicemodels.missing() == 4)
    check("the models folder is gone", gitgud.localDataInfo("bragi/voice/models") == nil)
    local kept = gitgud.jsonDecode(gitgud.localDataRead("bragi/voice/installed.json") or "") or {}
    local packages = type(kept.packages) == "table" and kept.packages or {}
    check("the turn-taking model isn't listed as installed", packages.decide == nil)
    check("nor the listening models", packages.asr == nil and packages.vad == nil)
end)
step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
