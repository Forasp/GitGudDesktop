--- tests/ui/bragi-settingstool.lua: the agent changes Bragi's own settings
-- through its tools (bragi_settings_get/set, bragi/settingstool.lua), with
-- the fake claude's "settings" scenario calling them over the app's tool
-- pipe: the change applies live, Settings shows it, the conversation gets a
-- note with Undo, values outside the allow-list are refused, sessions
-- started without uiTools don't have the tools, the model and the
-- thinking level ("switch to Sonnet", "think harder") set
-- the model button and Settings and reach the running session at once, how
-- often Bragi speaks its updates ("updates every 30 seconds")
-- is kept to 3 to 120 seconds (a value between the Settings
-- slider's stops kept as said; the slider dragged and clicked), and the theme switches after the turn and reopens the conversation (the
-- script runs again then).
-- First, the tools' schema and checks, which live in the script: what it
-- declares and what each value may be.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake then
    check("needs GITGUD_UI=bragi and GITGUD_TEST_CLAUDE", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local app = require("core.app")
local bragiSettings = require("bragi.settings")
local settings = require("core.settings")
local settingsTool = require("bragi.settingstool")
local shell = require("bragi.shell")
local voice = require("bragi.voice")

-- A stand-in speech engine while Settings is checked, so it shows its voice
-- cards; it has no voices list. Otherwise the build has no engine.
require("bragi.voicemodels").engine = function()
    return { installed = false }
end
voice.backend.voices = nil
local realAvailable = voice.backend.available
local function engine(on)
    voice.backend.available = on and function()
        return true
    end or realAvailable
end

local PHASE = "test.settingstoolPhase"

-- What reaches the running session: set_model and the control requests.
local sent = { models = {}, controls = {} }
local realSetModel, realControl = gitgud.agentSetModel, gitgud.agentControl
gitgud.agentSetModel = function(name, model)
    sent.models[#sent.models + 1] = model
    return realSetModel(name, model)
end
gitgud.agentControl = function(name, subtype, fields)
    sent.controls[#sent.controls + 1] = { subtype = subtype, fields = fields }
    return realControl(name, subtype, fields)
end
local replies = {}
gitgud.on("agent.control", function(detail)
    replies[#replies + 1] = gitgud.jsonDecode(detail) or {}
end)

settings.set("bragi.claudeProgram", fake)

local steps = {}
-- A step runs once `ready()` is true (or after `wait` ms of trying).
local function step(label, fn, ready, wait)
    steps[#steps + 1] = { label = label, fn = fn, ready = ready, wait = wait or 8000 }
end
local function run(i)
    local s = steps[i]
    if not s then
        return
    end
    local waited = 0
    local function attempt()
        if s.ready and not s.ready() and waited < s.wait then
            waited = waited + 100
            gitgud.after(100, attempt)
            return
        end
        print("[ui-test] " .. i .. ": " .. s.label)
        local ok, err = pcall(s.fn)
        if not ok then
            print("[ui-test] step " .. i .. " failed: " .. tostring(err))
            check("step " .. i .. " (" .. s.label .. ") ran without errors", false)
        end
        gitgud.after(100, function()
            run(i + 1)
        end)
    end
    gitgud.after(100, attempt)
end
local function shot(name)
    gitgud.screenshot(OUT .. "/settingstool-" .. name .. ".png")
end
--- Scroll Settings so `widget` is in view, for a screenshot.
local function scrollTo(widget)
    local _, top = gitgud.getRect("SettingsContent")
    local _, y = gitgud.getRect(widget)
    gitgud.setScroll("SettingsContent", (gitgud.getScroll("SettingsContent") or 0) + y - top - 300)
end
--- The spoken updates slider (Appearance and voice, Voice output): the
-- stop (from 0) its thumb is at, and the point (x, y) over stop `i`
-- (from 1). The thumb is 20 pixels wide.
local function sliderStop()
    local x, _, w = gitgud.getRect(bragiSettings.widget(4, 6, "Slider"))
    local tx = gitgud.getRect(bragiSettings.widget(4, 6, "SliderThumb"))
    if not x or not tx then
        return -1
    end
    local n = #bragiSettings.sliderValues(bragiSettings.UPDATE_SECONDS)
    return math.floor((tx - x) / (w - 20) * (n - 1) + 0.5)
end
local function sliderPoint(i)
    local x, y, w = gitgud.getRect(bragiSettings.widget(4, 6, "Slider"))
    local n = #bragiSettings.sliderValues(bragiSettings.UPDATE_SECONDS)
    return x + 10 + (w - 20) * (i - 1) / (n - 1), y + 20
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
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
        n = n + (item.kind == kind and 1 or 0)
    end
    return n
end
local function lastText(kind)
    local item = last(kind)
    return item and item.text or ""
end
local function has(s, part)
    return tostring(s or ""):find(part, 1, true) ~= nil
end

-- The settings tools need no permission card: they're
-- on the session's allow list (bragi/uitools.lua's noCard).
-- The turn is over: the agent's answer is in.
local function turnDone()
    return not agent.session().turn
end

local phase = settings.get(PHASE, "")

if phase == "" then
    -- ===============================================================
    -- Phase 1: speed, Undo, refusals, the other settings
    -- ===============================================================
    local notes = 0
    local themeBefore = gitgud.theme()

    step("the schema the script declares", function()
        local tools = settingsTool.definitions()
        check("two tools", #tools == 2 and tools[1].name == "bragi_settings_get"
            and tools[2].name == "bragi_settings_set")
        check("get is read-only", tools[1].annotations.readOnlyHint == true)
        check("set is not", tools[2].annotations.readOnlyHint == false)
        local schema = tools[2].inputSchema
        check("set needs a setting and a value", schema.type == "object" and #schema.required == 2
            and schema.additionalProperties == false)
        check("the twelve settings are its choices", #schema.properties.setting.enum == 12
            and schema.properties.setting.enum[1] == "speechSpeed")
        check("keep talking when you switch away among them", schema.properties.setting.enum[4] == "narrateAway")
        check("the model and the thinking level among them", schema.properties.setting.enum[10] == "model"
            and schema.properties.setting.enum[11] == "effort")
        check("the update interval among them", schema.properties.setting.enum[12] == "updateSeconds"
            and has(tools[2].description, "- updateSeconds: Seconds between")
            and has(tools[2].description, "3 to 120") and has(tools[2].description, "updates every 30 seconds"))
        check("the description has the examples", has(tools[2].description, "switch to Sonnet")
            and has(tools[2].description, "think harder") and has(tools[2].description, "- model: ")
            and has(tools[2].description, "fable or opus or sonnet or haiku"))
        check("the description lists them", has(tools[2].description, "speechSpeed")
            and has(tools[2].description, "- theme: The app's look. light or dark."))
        check("declaring them again works", gitgud.declareTools(tools) == true)
        local ok, err = gitgud.declareTools({ { name = "status", description = "x",
            inputSchema = { type = "object" } } })
        check("a Git tool's name is refused", ok == nil and has(err, "already"))
        -- Back to every UI tool (bragi/uitools.lua: the master's too).
        check("still declared", gitgud.declareTools(require("bragi.uitools").definitions()) == true)
    end)

    step("the script checks each value", function()
        local function set(id, v)
            local args = settingsTool.check("bragi_settings_set", { setting = id, value = v })
            if args then
                return args.value
            end
            return nil
        end
        local function refused(id, v)
            local args, why = settingsTool.check("bragi_settings_set", { setting = id, value = v })
            return args == nil and why or ""
        end
        -- Speaking speed: 0.8 to 1.5, two places, written short.
        check("speed 1.38", set("speechSpeed", 1.38) == "1.38")
        check("speed rounded", set("speechSpeed", 1.383) == "1.38")
        check("speed as text with x", set("speechSpeed", "1.2x") == "1.2")
        check("speed trimmed and short", set("speechSpeed", " 1.50 ") == "1.5")
        check("speed at the ends", set("speechSpeed", 0.8) == "0.8" and set("speechSpeed", 1) == "1")
        check("speed too high", has(refused("speechSpeed", 1.6), "0.8 to 1.5"))
        check("speed too low", has(refused("speechSpeed", 0.79), "outside"))
        check("speed not a number", refused("speechSpeed", "fast") ~= "" and refused("speechSpeed", true) ~= ""
            and refused("speechSpeed", "1.2.3") ~= "" and refused("speechSpeed", "") ~= "")
        -- The "seems done" wait: 2 to 10 seconds, one place.
        check("wait 4", set("endWaitSeconds", 4) == "4")
        check("wait as text with s", set("endWaitSeconds", "2.5 s") == "2.5")
        check("wait rounded", set("endWaitSeconds", 10.04) == "10")
        check("wait out of range", refused("endWaitSeconds", 1.5) ~= "" and refused("endWaitSeconds", 11) ~= "")
        -- Spoken updates: 3 to 120 whole seconds, a value outside kept to the end.
        check("updates every 30", set("updateSeconds", 30) == "30" and set("updateSeconds", "45 s") == "45")
        check("updates rounded", set("updateSeconds", 12.4) == "12")
        check("updates clamped, not refused", set("updateSeconds", 1) == "3" and set("updateSeconds", 500) == "120"
            and set("updateSeconds", 2.6) == "3")
        local clamped = settingsTool.check("bragi_settings_set", { setting = "updateSeconds", value = 500 })
        check("clamped says what was asked", clamped ~= nil and clamped.asked == 500)
        check("updates not a number", refused("updateSeconds", "often") ~= "")
        -- On or off.
        check("off", set("narrate", false) == false and set("narrate", "off") == false)
        check("on", set("showHeard", "true") == true and set("quickAnswers", true) == true)
        check("neither", has(refused("narrate", "maybe"), "true or false") and refused("quickAnswers", 1) ~= "")
        -- Choices.
        check("a choice, lower case", set("summaryLength", "Medium") == "medium" and set("theme", "dark") == "dark")
        check("not a choice", has(refused("summaryLength", "long"), "short or medium")
            and has(refused("theme", "blue"), "light or dark") and refused("theme", false) ~= "")
        -- A voice: any short text here; it's checked against the engine's list when set.
        check("a model", set("model", "Sonnet") == "sonnet" and set("model", "haiku") == "haiku")
        check("not a model", has(refused("model", "gpt"), "fable or opus or sonnet or haiku"))
        check("a thinking level", set("effort", "high") == "high" and set("effort", "default") == "default"
            and set("effort", "XHigh") == "xhigh")
        check("not a thinking level", has(refused("effort", "harder"), "default or low or medium or high"))
        check("a voice, trimmed", set("voice", " Freya ") == "Freya" and set("voice", "") == "")
        check("not a voice", refused("voice", 3) ~= "" and refused("voice", string.rep("v", 300)) ~= ""
            and refused("voice", "a\nb") ~= "")
    end)

    step("the script checks each call", function()
        local function why(tool, args)
            local checked, err = settingsTool.check(tool, args)
            return checked == nil and err or ""
        end
        check("a setting not on the list", has(why("bragi_settings_set", { setting = "claudeProgram", value = "x" }),
            "Allowed: speechSpeed"))
        check("a key isn't a setting", has(why("bragi_settings_set", { setting = "bragi.speechSpeed", value = 1.2 }),
            "isn't a setting"))
        check("set needs a value", has(why("bragi_settings_set", { setting = "narrate" }), "new value"))
        check("set needs a setting", why("bragi_settings_set", { value = 1.2 }) ~= "")
        check("no other arguments", has(why("bragi_settings_set", { setting = "narrate", value = true,
            key = "bragi.claudeProgram" }), "Unknown argument"))
        check("no other tools", why("bragi_settings_delete", {}) ~= "")
        local all = settingsTool.check("bragi_settings_get", {})
        check("get: all of them", type(all) == "table" and all.setting == nil
            and type(settingsTool.check("bragi_settings_get", nil)) == "table")
        local one = settingsTool.check("bragi_settings_get", { setting = "theme" })
        check("get: one", one ~= nil and one.setting == "theme")
        check("get: not on the list", why("bragi_settings_get", { setting = "wakeWord" }) ~= ""
            and why("bragi_settings_get", { value = 1 }) ~= "")
        local text, isError = settingsTool.handle({ tool = "bragi_settings_set",
            arguments = { setting = "speechSpeed", value = 3 } })
        check("a refused call answers with why", isError == true and has(text, "0.8 to 1.5"))
    end)

    step("start in the Agent view", function()
        settings.set("bragi.quickAnswers", false) -- typed messages go straight to the agent
        settings.set("bragi.narrate", true)
        shell.show("agent")
        check("speaking speed starts at 1.15", voice.speechSpeed() == 1.15)
    end)

    step("ask to speak faster", function()
        say("settings set speechSpeed 1.38")
    end)

    step("applied live, with a note and Undo", function()
        check("no permission card: Bragi's own tool is allowed", count("permission") == 0)
        check("the setting changed", settings.get("bragi.speechSpeed", "") == "1.38")
        check("voice speaks at the new speed", voice.speechSpeed() == 1.38)
        local note = last("note")
        check("a note says what changed", note ~= nil and has(note.text, "Speaking speed 1.15x")
            and has(note.text, "1.38x"))
        check("the note has Undo", note ~= nil and note.action ~= nil and note.action.label == "Undo"
            and gitgud.getText(note.name .. "Action") == "Undo")
        check("the agent was told", has(lastText("assistant"), "Speaking speed 1.15x -> 1.38x"))
        notes = count("note")
        shot("02-note")
    end, turnDone)

    step("Settings shows it at once", function()
        engine(true)
        bragiSettings.open("appearance")
    end)

    step("the speed in Settings", function()
        local label = gitgud.getText(bragiSettings.widget(4, 4, "Choice")) or ""
        check("Settings shows 1.38x (" .. label .. ")", label == "1.38x")
        shot("03-settings")
        engine(false)
        shell.show("agent")
    end)

    step("Undo", function()
        local note = last("note")
        clickWidget(note.name .. "Action")
    end)

    step("undone", function()
        local note = last("note")
        check("the speed is back", voice.speechSpeed() == 1.15 and settings.get("bragi.speechSpeed", "") == "1.15")
        check("the note says so, without Undo", has(note.text, "back to 1.15x") and note.action == nil)
        check("the Undo button went", gitgud.getText(note.name .. "Action") == nil
            or gitgud.getProperty(note.name .. "Action", "Visible") ~= "true")
        shot("04-undone")
    end)

    step("too fast", function()
        say("settings set speechSpeed 3")
    end)
    step("refused", function()
        check("a speed outside 0.8 to 1.5 is refused", has(lastText("assistant"), "Refused")
            and has(lastText("assistant"), "0.8 to 1.5"))
        check("the speed didn't change", settings.get("bragi.speechSpeed", "") == "1.15")
        check("no note for a refusal", count("note") == notes)
    end, turnDone)

    step("a setting not on the list", function()
        say("settings set claudeProgram evil.exe")
    end)
    step("refused", function()
        check("a setting outside the allow-list is refused", has(lastText("assistant"), "Refused")
            and has(lastText("assistant"), "Allowed: speechSpeed"))
        check("the program didn't change", settings.get("bragi.claudeProgram", "") == fake)
    end, turnDone)

    step("a voice the engine can't check", function()
        say("settings set voice Nobody")
    end)
    step("refused", function()
        check("a voice that can't be checked is refused", has(lastText("assistant"), "Refused")
            and has(lastText("assistant"), "Voice isn't part of this build"))
        check("the voice didn't change", settings.get("bragi.voice", "") == "")
    end, turnDone)

    step("stop narrating", function()
        say("settings set narrate false")
    end)
    step("narration off", function()
        check("narration is off", settings.get("bragi.narrate", true) == false)
        check("its note", has(lastText("note"), "Narration on") and has(lastText("note"), "off"))
        say("settings set endWaitSeconds 4")
    end, turnDone)
    step("the wait", function()
        check("the wait is 4 s", voice.endWait() == 4 and settings.get("bragi.endWaitSeconds", "") == "4")
        check("its note", has(lastText("note"), "Wait when you seem done 3 s") and has(lastText("note"), "4 s"))
        engine(true)
        bragiSettings.open("appearance")
    end, turnDone)
    step("the wait in Settings", function()
        local value = gitgud.getText(bragiSettings.widget(3, 6, "InputEdit")) or ""
        check("Settings shows the wait as 4 (" .. value .. ")", value == "4")
        engine(false)
        shell.show("agent")
        say("settings set summaryLength Medium")
    end)
    step("medium summaries", function()
        check("summaries are medium", settings.get("bragi.summaryLength", "") == "medium")
        say("settings set showHeard true")
    end, turnDone)
    step("show what was heard", function()
        check("show what was heard is on", settings.get("bragi.showHeard", false) == true)
        sent.models = {}
        say("settings set model sonnet")
    end, turnDone)
    step("switched to Sonnet", function()
        check("the setting changed", settings.get("bragi.model", "") == "sonnet")
        check("the model button shows it", gitgud.getText("AgentModelButton") == "Sonnet 5.5")
        check("the running session got it", sent.models[#sent.models] == "sonnet")
        check("a note says so", has(lastText("note"), "Model Opus 5.5 -> Sonnet 5.5"))
        sent.controls = {}
        replies = {}
        say("settings set effort high")
    end, turnDone)
    step("thinking harder", function()
        check("the setting changed", settings.get("bragi.effort", "x") == "high")
        local c = sent.controls[#sent.controls]
        check("the running session got it", c ~= nil and c.subtype == "apply_flag_settings"
            and c.fields == '{"settings":{"effortLevel":"high"}}')
        check("Claude Code took it", #replies > 0 and replies[#replies].subtype == "apply_flag_settings"
            and replies[#replies].ok == true)
        check("a note says so", has(lastText("note"), "Effort Default -> High"))
        engine(true)
        bragiSettings.open("claude")
    end, turnDone)
    step("both in Settings", function()
        local found = {}
        for row = 1, 8 do
            local title = gitgud.getText(bragiSettings.widget(1, row, "Title")) or ""
            found[title] = gitgud.getText(bragiSettings.widget(1, row, "Choice")) or ""
        end
        check("Settings shows Sonnet", found["Model"] == "Sonnet 5.5")
        check("Settings shows High", found["Effort"] == "High")
        engine(false)
        shell.show("agent")
        sent.controls = {}
        say("settings set effort default")
    end)
    step("back to the default", function()
        check("the setting is cleared", settings.get("bragi.effort", "x") == "")
        local c = sent.controls[#sent.controls]
        check("the running session is told: null, its own default", c ~= nil
            and c.fields == '{"settings":{"effortLevel":null}}')
        settings.set("bragi.model", "opus")
        app.publish("bragi.choices")
        say("settings get speechSpeed")
    end, turnDone)
    step("get", function()
        check("get reads the current value", has(lastText("assistant"), "speechSpeed: \"1.15\""))
        check("spoken updates start at 10 s", bragiSettings.updateSeconds() == 10)
        say("settings set updateSeconds 30")
    end, turnDone)
    step("updates every 30 seconds", function()
        check("the setting changed", settings.get("bragi.updateSeconds", "") == "30"
            and bragiSettings.updateSeconds() == 30)
        check("a note says so", has(lastText("note"), "Spoken updates every 10 s -> 30 s"))
        check("the reply says the new value", has(lastText("assistant"), "Spoken updates every 10 s -> 30 s"))
        say("settings get updateSeconds")
    end, turnDone)
    step("read back", function()
        check("get reads 30", has(lastText("assistant"), "updateSeconds: \"30\"")
            and has(lastText("assistant"), "Spoken updates every: 30 s"))
        say("settings set updateSeconds 1")
    end, turnDone)
    step("1 is kept to 3", function()
        check("the shortest is 3", settings.get("bragi.updateSeconds", "") == "3" and bragiSettings.updateSeconds() == 3)
        check("the reply says it", has(lastText("assistant"), "30 s -> 3 s")
            and has(lastText("assistant"), "1 s is outside 3 to 120, so it's 3 s"))
        say("settings set updateSeconds 500")
    end, turnDone)
    step("500 is kept to 120", function()
        check("the longest is 120", settings.get("bragi.updateSeconds", "") == "120"
            and bragiSettings.updateSeconds() == 120)
        check("the reply says it", has(lastText("assistant"), "3 s -> 120 s")
            and has(lastText("assistant"), "500 s is outside 3 to 120, so it's 120 s"))
        engine(true)
        bragiSettings.open("appearance")
    end, turnDone)
    step("the interval in Settings", function()
        local row = bragiSettings.widget(4, 6, "Value")
        check("Settings shows Spoken updates every", gitgud.getText(bragiSettings.widget(4, 6, "Title"))
            == "Spoken updates every")
        check("Settings shows 2 min (" .. tostring(gitgud.getText(row)) .. ")", gitgud.getText(row) == "2 min")
        check("the slider's thumb at its end", sliderStop() == 29)
        engine(false)
        shell.show("agent")
        -- Between the slider's stops (35 is one): kept as said.
        say("settings set updateSeconds 33")
    end)
    step("33, between two stops", function()
        check("kept as 33", settings.get("bragi.updateSeconds", "") == "33" and bragiSettings.updateSeconds() == 33)
        check("the reply says it", has(lastText("assistant"), "120 s -> 33 s"))
        engine(true)
        bragiSettings.open("appearance")
    end, turnDone)
    step("33 in Settings", function()
        local row = bragiSettings.widget(4, 6, "Value")
        check("Settings shows 33 s (" .. tostring(gitgud.getText(row)) .. ")", gitgud.getText(row) == "33 s")
        check("the thumb at the nearest stop, 35", sliderStop() == 12)
        scrollTo(row)
    end)
    step("dragged with the mouse", function()
        local x1, y1 = sliderPoint(15)
        local x2, y2 = sliderPoint(5)
        gitgud.simulateDrag(x1, y1, x2, y2)
    end)
    step("dragged to 7 s", function()
        check("the drag set 7 (" .. tostring(settings.get("bragi.updateSeconds", "")) .. ")",
            settings.get("bragi.updateSeconds", "") == "7"
            and gitgud.getText(bragiSettings.widget(4, 6, "Value")) == "7 s" and sliderStop() == 4)
        local fill = gitgud.getProperty(bragiSettings.widget(4, 6, "SliderThumb"), "FillColour") or ""
        check("the thumb back to its colour after the drag (" .. fill .. ")",
            fill:upper():find(require("core.palette").accent:upper(), 1, true) ~= nil)
        shot("07-updates-dragged-" .. gitgud.theme())
    end)
    step("clicked at the end", function()
        local x, y = sliderPoint(30)
        gitgud.simulateClick(x, y, "left")
    end)
    step("a click at the end", function()
        check("the click set 120", settings.get("bragi.updateSeconds", "") == "120"
            and gitgud.getText(bragiSettings.widget(4, 6, "Value")) == "2 min" and sliderStop() == 29)
        settings.set("bragi.updateSeconds", "33")
        bragiSettings.rebuild("appearance")
        scrollTo(bragiSettings.widget(4, 6, "Value"))
    end)
    step("the interval shown", function()
        shot("07-updates-" .. gitgud.theme())
    end)
    step("back to the conversation", function()
        engine(false)
        shell.show("agent")
        say("settings set narrate false")
    end)
    step("already so", function()
        check("an unchanged value says so", has(lastText("assistant"), "already off"))
        say("args")
    end, turnDone)

    step("the main session's tools", function()
        check("the main session gets the UI tools' config, its own", has(lastText("assistant"), "-ui-s-"))
        -- A session started without uiTools (as the helpers are) has
        -- the Git and P4 tools only.
        local ok = gitgud.agentStart("settingstool-probe", { program = fake })
        check("a probe session started", ok == true)
        local replies = {}
        gitgud.on("agent.result", function(detail)
            local e = gitgud.jsonDecode(detail)
            if type(e) == "table" and e.session == "settingstool-probe" then
                replies[#replies + 1] = e.text or ""
            end
        end)
        gitgud.agentSend("settingstool-probe", "settings get")
        steps.probe = replies
    end, turnDone)

    step("other sessions don't get them", function()
        check("without uiTools there's no settings tool", has(steps.probe[1], "No such tool"))
        gitgud.agentStop("settingstool-probe")
        -- Last: the theme, which rebuilds the window after the turn.
        settings.set(PHASE, themeBefore == "dark" and "light" or "dark")
        say("settings set theme " .. (themeBefore == "dark" and "light" or "dark"))
    end, function()
        return steps.probe and #steps.probe > 0
    end)
    step("the theme waits for the turn", function()
        check("the agent was told it switches after the turn", has(lastText("assistant"), "switches when this turn ends"))
        check("still the old theme right away", gitgud.theme() == themeBefore)
        shot("05-theme-asked")
        -- The rebuild runs this script again (phase 2) and ends this timer.
        gitgud.after(20000, function()
            check("the theme switched after the turn", false)
            settings.set(PHASE, "")
            gitgud.emit("window.close", "")
        end)
    end, turnDone)
else
    -- ===============================================================
    -- Phase 2: after the theme switch
    -- ===============================================================
    step("after the switch", function()
        check("the theme is " .. phase, gitgud.theme() == phase)
        check("no permission card", count("permission") == 0)
        local note = last("note")
        check("the conversation shows the theme note", note ~= nil and has(note.text, "Theme")
            and has(note.text, phase))
        check("with Undo", note ~= nil and note.action ~= nil)
        check("the conversation reopened", agent.session().resume ~= nil)
        check("Settings kept the other changes", settings.get("bragi.summaryLength", "") == "medium"
            and settings.get("bragi.narrate", true) == false)
        shot("06-after-theme")
    end, function()
        return last("note") ~= nil
    end, 5000)
    step("Settings in this theme", function()
        engine(true)
        bragiSettings.open("appearance")
    end)
    step("the interval in Settings, this theme", function()
        local row = bragiSettings.widget(4, 6, "Value")
        check("still 33 after the switch", gitgud.getText(row) == "33 s" and sliderStop() == 12)
        scrollTo(row)
    end)
    step("the interval shown, this theme", function()
        shot("07-updates-" .. gitgud.theme())
        engine(false)
        settings.set(PHASE, "")
        gitgud.emit("window.close", "")
    end)
end

run(1)
