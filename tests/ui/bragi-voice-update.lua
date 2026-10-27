--- tests/ui/bragi-voice-update.lua: an app update that pins a new speech
-- recognition model, on a computer that had voice set up. The models it
-- had are in the scratch local app data, recorded as installed, the speech
-- model being an older one: the new one comes in by itself (downloaded for
-- real, about 108 MB) a few seconds after start, without asking. The mic
-- pressed meanwhile says so in one note, kept up to date (pressing again
-- doesn't add another), and voice turns on once the models are in. Needs a
-- build with the speech engine and the network. Not in the default suite.
--
-- Run it like bragi-voice.lua, with a scratch LOCALAPPDATA whose
-- Gitgud\bragi\voice\models holds vad, kws, speaker (the current files)
-- and asr (an older model's), and installed.json naming all four. Prints
-- "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local localData = os.getenv("LOCALAPPDATA") or ""
if gitgud.currentUi().id ~= "bragi" or not localData:lower():find("sandbox", 1, true)
    or not gitgud.voiceEngine().installed then
    check("needs GITGUD_UI=bragi, a scratch LOCALAPPDATA, and the speech engine", false)
    gitgud.emit("window.close", "")
    return
end

local voice = require("bragi.voice")
local voicemodels = require("bragi.voicemodels")
local agent = require("bragi.agent")

-- The notes about the speech models.
local function modelNotes()
    local list = {}
    for _, item in ipairs(agent.items()) do
        if item.kind == "note" and (item.text or ""):find("speech models", 1, true) then
            list[#list + 1] = item
        end
    end
    return list
end

local function finished()
    local phase = voicemodels.state().phase
    return phase == "done" or phase == "failed"
end

step(500, "an update replaced the speech model", function()
    local outdated = voicemodels.outdated()
    check("only the speech model is missing", #voicemodels.missing() == 1 and voicemodels.missing()[1].id == "asr")
    check("and it was installed before", #outdated == 1 and outdated[1].id == "asr")
    check("voice can't start yet", not voice.available())
end)
step(10000, "it comes in by itself", function()
    check("the update started without asking", voicemodels.updating())
    voice.toggle()
end)
step(500, "the mic says so", function()
    local notes = modelNotes()
    check("one note", #notes == 1)
    check("saying the models are updating, and that voice turns on after",
        notes[1] ~= nil and notes[1].text:find("^Updating the speech models") ~= nil
        and notes[1].text:find("Voice turns on when they're in.", 1, true) ~= nil)
    voice.toggle()
end)
step(500, "pressed again", function()
    check("still one note", #modelNotes() == 1)
    check("voice still off", voice.state() == "off")
end)
step(600000, "updated and checked", function()
    check("the update finished", finished())
    check("and passed its check", voicemodels.state().phase == "done")
    check("nothing missing", #voicemodels.missing() == 0)
    check("voice is available", voice.available())
end)
step(15000, "voice turned on", function()
    check("listening without another press", voice.state() ~= "off")
    local notes = modelNotes()
    check("the note says they're in", #notes == 1 and notes[1].text == "The speech models are updated.")
end)
step(500, "done", function()
    voice.stop()
    gitgud.emit("window.close", "")
end)

harness.run()
