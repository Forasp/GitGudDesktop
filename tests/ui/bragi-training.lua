--- tests/ui/bragi-training.lua: Settings, Voice training (E9, the app's
-- half): wake word training (samples as they come; the suggested
-- mishearings as checkboxes, everyday words unchecked; a threshold never
-- below 0.15; removing a sample; Apply saving the checked mishearings and
-- the threshold and sending them to the server) and voice enrollment
-- (seconds so far, too short, enrolled, forgotten). The voice service is
-- faked: voice.backend is replaced and the voice.* events are emitted
-- here. gitgud.isDictionaryWord is stubbed, so the machine's dictionary
-- doesn't matter.
--
-- Run it like bragi.lua (GITGUD_UI=bragi, scratch APPDATA and LOCALAPPDATA,
-- a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing here,
-- GITGUD_SHOTS). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

if gitgud.currentUi().id ~= "bragi" then
    check("needs GITGUD_UI=bragi", false)
    gitgud.emit("window.close", "")
    return
end

local bragiSettings = require("bragi.settings")
local settings = require("core.settings")
local training = require("bragi.training")
local voice = require("bragi.voice")

-- The fake voice service: every call is recorded.
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
local function recorder(name)
    return function(arg)
        calls[#calls + 1] = { name = name, arg = arg }
        return true
    end
end
-- Whether a speech engine is there (none is built in yet).
local engineOn = true
voice.backend = {
    available = function()
        return engineOn
    end,
    listen = recorder("listen"),
    stop = recorder("stop"),
    send = recorder("send"),
    lookback = recorder("lookback"),
    speak = recorder("speak"),
    speakStop = recorder("speakStop"),
    playing = function()
        return nil
    end,
    config = recorder("config"),
    train = recorder("train"),
    enroll = recorder("enroll"),
}
local function emit(kind, fields)
    gitgud.emit("voice." .. kind, gitgud.jsonEncode(fields))
end

-- The dictionary: "Roger" and "Right" are words, "Froggy" isn't, and
-- "Braggy" gets no answer (as on a machine without a spell checker).
local asked = {}
gitgud.isDictionaryWord = function(word)
    asked[#asked + 1] = word
    local l = word:lower()
    if l == "roger" or l == "right" then
        return true
    elseif l == "froggy" then
        return false
    end
    return nil
end


local function shot(name)
    gitgud.screenshot(OUT .. "/training-" .. name .. ".png")
end
local function w(card, row, part)
    return bragiSettings.widget(card, row, part)
end
local function textOf(card, row, part)
    return gitgud.getText(w(card, row, part)) or ""
end
local function click(card, row, part)
    local x, y, width, h = gitgud.getRect(w(card, row, part or "Action"))
    gitgud.simulateClick(x + width / 2, y + h / 2, "left")
end
--- Scroll Settings down (the samples are below the fold) or back up.
local function scroll(down)
    local x, y, width, h = gitgud.getRect("SettingsContent")
    gitgud.simulateScroll(x + width / 2, y + h / 2, down and -40 or 80)
end
local function checked(card, row)
    return gitgud.getProperty(w(card, row, "Check"), "Selected") == "true"
end
local function pick(word)
    for _, p in ipairs(training.state().picks) do
        if p.word == word then
            return p
        end
    end
    return {}
end
local function same(list, expected)
    if type(list) ~= "table" or #list ~= #expected then
        return false
    end
    for i, v in ipairs(expected) do
        if list[i] ~= v then
            return false
        end
    end
    return true
end
local function last(name)
    local list = called(name)
    return list[#list]
end

step(1500, "open Voice training", function()
    bragiSettings.open("training")
end)

step(300, "the section", function()
    check("training is offered", textOf(1, 1, "Title") == "Train the wake word")
    check("enrollment is offered", textOf(2, 1, "Title") == "Enroll your voice")
    check("Forget is off without a voiceprint", gitgud.getProperty(w(2, 2, "Action"), "Disabled") == "true")
    check("and says the voiceprint is on this computer",
        gitgud.getText(w(2, 2, "Sub")) == "Deletes your voiceprint from this computer.")
    shot("01-section")
end)

step(200, "Start turns voice on first", function()
    click(1, 1)
    check("listening was asked", #called("listen") == 1)
    check("training waits for ready", training.state().mode == "starting-train" and #called("train") == 0)
end)

step(200, "the server is ready", function()
    emit("ready", { version = 0, speaker = { enrolled = false } })
end)

step(300, "training runs", function()
    check("train start sent", last("train") ~= nil and last("train").arg == "start")
    check("training", training.state().mode == "training")
    check("the button stops it", textOf(1, 1, "Action") == "Stop")
    emit("trainSample", { n = 1, text = "Bragi", score = 0.8, detected = true, t0 = 1, t1 = 2 })
    emit("trainSample", { n = 2, text = "Froggy", score = 0.4, detected = true, t0 = 3, t1 = 4 })
    emit("trainSample", { n = 3, text = "Roger", score = 0.2, detected = true, t0 = 5, t1 = 6 })
    emit("trainSample", { n = 4, text = "Right", score = 0.1, detected = false, t0 = 7, t1 = 8 })
    emit("trainSample", { n = 5, text = "Braggy", score = 0.3, detected = true, t0 = 9, t1 = 10 })
end)

step(300, "samples show as they come", function()
    check("five samples", #training.state().samples == 5)
    check("the first sample's transcript", textOf(2, 1, "Title") == "\u{201C}Bragi\u{201D}")
    check("its score", textOf(2, 1, "Sub"):find("Score 0.80, would wake", 1, true) ~= nil)
    check("a quiet one wouldn't wake", textOf(2, 4, "Sub"):find("would not wake", 1, true) ~= nil)
    shot("02-samples")
end)

step(200, "Stop", function()
    click(1, 1)
    check("train stop sent", last("train").arg == "stop")
    emit("trainResult", { samples = 5, mishearings = { "Froggy", "Roger", "Right", "Braggy" }, threshold = 0.05 })
end)

-- Card 2, "What was learned": the four mishearings, the threshold, Apply.
-- The samples move down to card 3.
step(300, "the suggestion", function()
    check("trained", training.state().mode == "trained")
    check("the dictionary was asked about each", #asked == 4)
    check("a row per mishearing", textOf(2, 1, "Title") == "\u{201C}Froggy\u{201D}"
        and textOf(2, 2, "Title") == "\u{201C}Roger\u{201D}" and textOf(2, 3, "Title") == "\u{201C}Right\u{201D}"
        and textOf(2, 4, "Title") == "\u{201C}Braggy\u{201D}")
    check("a made-up word starts checked", checked(2, 1) and pick("Froggy").checked == true)
    check("everyday words start unchecked", not checked(2, 2) and not checked(2, 3)
        and pick("Roger").checked == false and pick("Right").checked == false)
    check("without an answer it starts checked", checked(2, 4) and pick("Braggy").checked == true)
    check("everyday words say why", textOf(2, 2, "Sub"):find("everyday word", 1, true) ~= nil
        and textOf(2, 3, "Sub"):find("everyday word", 1, true) ~= nil)
    check("the others don't", textOf(2, 1, "Sub"):find("everyday", 1, true) == nil
        and textOf(2, 4, "Sub"):find("everyday", 1, true) == nil)
    local s = training.suggestion()
    check("only the checked would be saved", s and same(s.mishearings, { "Froggy", "Braggy" }))
    check("the threshold is raised to 0.15", s and math.abs(s.threshold - 0.15) < 1e-6 and s.raised
        and math.abs(s.suggested - 0.05) < 1e-6)
    check("the row shows what will be saved", textOf(2, 5, "Title") == "Wake threshold 0.15")
    check("and that it was raised", textOf(2, 5, "Sub"):find("Raised from the suggested 0.05", 1, true) ~= nil)
    check("Apply is offered", textOf(2, 6, "Title") == "Save what was learned")
    shot("03-result")
end)

step(200, "check an everyday word", function()
    click(2, 2, "Check")
end)

step(700, "it's checked", function()
    check("Roger checked", checked(2, 2) and pick("Roger").checked == true)
    check("it would be saved", same(training.suggestion().mishearings, { "Froggy", "Roger", "Braggy" }))
    click(2, 2, "Check")
end)

step(700, "and unchecked again", function()
    check("Roger unchecked", not checked(2, 2) and pick("Roger").checked == false)
    click(2, 1, "Check")
end)

step(700, "uncheck a made-up word", function()
    check("Froggy unchecked", not checked(2, 1) and pick("Froggy").checked == false)
    check("only Braggy left", same(training.suggestion().mishearings, { "Braggy" }))
end)

step(200, "remove the quiet sample", function()
    check("the samples are below", textOf(3, 4, "Title") == "\u{201C}Right\u{201D}")
    scroll(true)
    click(3, 4)
end)

step(300, "the suggestion follows", function()
    local s = training.suggestion()
    check("its transcript left the mishearings", s and #s.picks == 3
        and textOf(2, 3, "Title") == "\u{201C}Braggy\u{201D}")
    check("the threshold sits the same margin below the weakest kept", s and math.abs(s.threshold - 0.15) < 1e-6
        and not s.raised)
    check("not raised now", textOf(2, 4, "Title") == "Wake threshold 0.15"
        and textOf(2, 4, "Sub"):find("Raised", 1, true) == nil)
    check("the choices survive the rebuild", not checked(2, 1) and not checked(2, 2) and checked(2, 3))
    check("four samples shown", textOf(3, 4, "Title") == "\u{201C}Braggy\u{201D}")
end)

step(200, "Apply", function()
    scroll(false)
    click(2, 5)
    check("only the checked mishearings saved", settings.get("bragi.mishearings", "") == '["Braggy"]')
    check("the raised threshold saved", settings.get("bragi.wakeThreshold", "") == "0.150")
    local config = last("config")
    check("sent to the server", config ~= nil and math.abs((config.arg.wakeThreshold or 0) - 0.15) < 1e-6
        and same(config.arg.mishearings, { "Braggy" }))
    check("back to idle", training.state().mode == "idle")
end)

step(300, "saved", function()
    check("the row says what was saved", textOf(1, 1, "Sub"):find("Saved 1 mishearing and threshold 0.15.", 1, true) ~= nil)
    check("the learned card is gone", textOf(2, 1, "Title") == "Enroll your voice")
    shot("04-saved")
end)

step(200, "enroll", function()
    click(2, 1)
    check("enroll start sent", last("enroll") ~= nil and last("enroll").arg == "start")
    check("enrolling", training.state().mode == "enrolling")
    emit("enrollSample", { n = 1, text = "hello there", seconds = 6, t0 = 1, t1 = 7 })
end)

step(300, "seconds so far", function()
    check("the seconds show", textOf(2, 1, "Sub"):find("6 s of speech so far", 1, true) ~= nil)
    check("training is off meanwhile", gitgud.getProperty(w(1, 1, "Action"), "Disabled") == "true")
    shot("05-enrolling")
    click(2, 1)
    check("enroll stop sent", last("enroll").arg == "stop")
    emit("enrollResult", { samples = 1, seconds = 6, enrolled = false, reason = "too-short" })
end)

step(300, "too short", function()
    check("it says it was too short", textOf(2, 1, "Sub"):find("Not enough speech", 1, true) ~= nil)
    click(2, 1)
    emit("enrollSample", { n = 1, text = "talking", seconds = 14, t0 = 1, t1 = 15 })
end)

step(300, "enough speech", function()
    click(2, 1)
    emit("enrollResult", { samples = 2, seconds = 14, enrolled = true })
end)

step(300, "enrolled", function()
    check("enrolled", training.state().enrolled == true)
    check("it says so", textOf(2, 1, "Sub"):find("Your voice is enrolled", 1, true) ~= nil)
    check("Forget is on", gitgud.getProperty(w(2, 2, "Action"), "Disabled") == "false")
    shot("06-enrolled")
    click(2, 2)
    check("enroll clear sent", last("enroll").arg == "clear")
    emit("enrollResult", { samples = 0, seconds = 0, enrolled = false })
end)

step(300, "forgotten", function()
    check("not enrolled", training.state().enrolled == false)
    check("it says so", textOf(2, 1, "Sub"):find("forgotten", 1, true) ~= nil)
end)

step(200, "a busy server", function()
    click(1, 1)
    emit("error", { code = "busy", message = "Enrollment is running" })
end)

step(300, "busy", function()
    check("training stops", training.state().mode == "idle")
    check("it says why", textOf(1, 1, "Sub"):find("Enrollment is running", 1, true) ~= nil)
end)

step(200, "the next listen carries what was saved", function()
    voice.stop()
    voice.toggle()
    local listen = last("listen")
    check("hello has the mishearings", listen ~= nil and same(listen.arg.mishearings, { "Braggy" }))
    check("and the threshold", listen ~= nil and math.abs((listen.arg.wakeThreshold or 0) - 0.15) < 1e-6)
    voice.stop()
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
