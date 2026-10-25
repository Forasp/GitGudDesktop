--- bragi/settingstool.lua: the agent changes Bragi's own settings:
-- "speak 20% faster", typed or said.
--
-- The main agent session has two tools on the app's MCP server:
-- bragi_settings_get and bragi_settings_set. This module declares them
-- (through bragi/uitools.lua; the engine only carries them, agent/ToolServer.h),
-- with their descriptions and schema built from SETTINGS below, the
-- allow-list: nothing else can be read or changed. Each call comes here as
-- the event "tools.call" ({ id, tool, arguments }, as the agent sent them),
-- is checked here (settingsTool.check: ranges, choices, the arguments), and
-- answered with gitgud.toolReply. Helper sessions (the Haiku ones) don't
-- get the tools (only agentStart's uiTools session does).
--
-- A change applies at once, like a click in Settings: the setting is saved,
-- Settings shows it (rebuilt, and "bragi.choices"), and the conversation
-- gets a note ("Speaking speed 1.15x -> 1.38x") with Undo. The voice is
-- checked here against the speech engine's list (an id or a name).
--
-- The model and the thinking level are here too ("switch
-- to Sonnet", "think harder", said or typed): they set the same choices as
-- the model button and Settings, and the running conversation takes them
-- at once (bragi/agent.lua's showChoices). A slash command with arguments
-- ("/model sonnet") goes to Claude Code and doesn't move them.
--
-- The theme rebuilds the whole interface, which would leave a running turn
-- without its conversation, so it waits for the turn to end (and the
-- spoken reply to finish), then switches and reopens the conversation
-- (bragi.afterTheme carries it across) with the note.
--
-- How often Bragi speaks its updates is here too ("give
-- me updates every 30 seconds"); out of range it's kept to 3 or 120 and the
-- reply says so.
--
-- Neither asks with a permission card: get only reads,
-- and set only changes Bragi's own settings, each with its note and Undo
-- (bragi/uitools.lua's noCard puts them on every session's allow list).
--
-- Public API: settingsTool.handle(call) (for tests), settingsTool.check(tool, args),
-- settingsTool.definitions(), settingsTool.current(id),
-- settingsTool.apply(id, value, opts), settingsTool.SETTINGS, settingsTool.init()

local agent = require("bragi.agent")
local app = require("core.app")
local bragiSettings = require("bragi.settings")
local settings = require("core.settings")
local text = require("core.text")

local settingsTool = { name = "bragi.settingstool" }

local THEME_SETTLE_MS = 2000     -- after the turn ends, before the theme switches
local THEME_POLL_MS = 500
local THEME_MAX_WAIT_MS = 60000  -- a reply still speaking after this doesn't hold it up
local MAX_VOICE = 200            -- longest voice id or name taken

local function voice()
    return require("bragi.voice")
end

--- The ids of one of agent.lua's choice lists, and an id's label in it.
local function choiceIds(list)
    local out = {}
    for _, entry in ipairs(list) do
        out[#out + 1] = entry.id
    end
    return out
end
local function choiceLabel(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then
            return entry.label
        end
    end
    return tostring(id)
end

-- The thinking levels as the tools name them: Claude Code's own default
-- is "default" (stored as "").
local EFFORT_DEFAULT = "default"
local function effortIds()
    local out = {}
    for _, entry in ipairs(agent.EFFORTS) do
        out[#out + 1] = entry.id == "" and EFFORT_DEFAULT or entry.id
    end
    return out
end

--- A number as Settings shows it: 1.38, 1.2, 3.
local function short(n)
    local s = string.format("%.2f", tonumber(n) or 0):gsub("0+$", ""):gsub("%.$", "")
    return s
end

local function onOff(v)
    return v and "on" or "off"
end

local function voiceName(id)
    if id == "" then
        return "the default voice"
    end
    for _, v in ipairs(voice().voices().list or {}) do
        if v.id == id then
            return v.name
        end
    end
    return id
end

-- The allow-list: what the agent may read and change. For each: what the
-- tools say about it (about), what it takes (kind, and a number's range and
-- places, or the choices), and for the app: label, the setting's key, how it
-- reads now, and how it's shown. kind is "number" (in min..max, kept to
-- `decimals` places; with `clamp`, a value outside is set to the nearer
-- end instead of refused), "onOff" (true or false), "choice" (one of choices) or
-- "voice" (an id or name, checked against the server's list when it's set).
settingsTool.SETTINGS = {
    { id = "speechSpeed", label = "Speaking speed", key = "bragi.speechSpeed",
      about = "How fast Bragi speaks, 0.8 to 1.5 (1 is the voice's own pace).",
      kind = "number", min = 0.8, max = 1.5, decimals = 2,
      read = function()
          return short(voice().speechSpeed())
      end,
      show = function(v)
          return short(v) .. "x"
      end },
    { id = "voice", label = "Voice", key = "bragi.voice",
      about = "The voice Bragi speaks with: an id or name from the speech engine's voices "
          .. "(\"\" for its default).",
      kind = "voice",
      read = function()
          return text.trim(settings.get("bragi.voice", ""))
      end,
      show = voiceName },
    { id = "narrate", label = "Narration", key = "bragi.narrate",
      about = "Say in a few words what the agent is doing while it works.",
      kind = "onOff",
      read = function()
          return settings.get("bragi.narrate", true) ~= false
      end,
      show = onOff },
    { id = "narrateAway", label = "Keep talking when you switch away", key = "bragi.narrateAway",
      about = "Go on telling a conversation's work after another one is opened, until a message "
          .. "goes somewhere else.",
      kind = "onOff",
      read = function()
          return settings.get("bragi.narrateAway", false) == true
      end,
      show = onOff },
    { id = "summaryLength", label = "Spoken summary", key = "bragi.summaryLength",
      about = "How long the spoken summary of a reply is.",
      kind = "choice", choices = { "short", "medium" },
      read = function()
          return settings.get("bragi.summaryLength", "short") == "medium" and "medium" or "short"
      end },
    { id = "endWaitSeconds", label = "Wait when you seem done", key = "bragi.endWaitSeconds",
      about = "Seconds after you pause that Bragi goes ahead once you seem done speaking, 2 to 10.",
      kind = "number", min = 2, max = 10, decimals = 1,
      read = function()
          return short(voice().endWait())
      end,
      show = function(v)
          return short(v) .. " s"
      end },
    { id = "showHeard", label = "Show what was heard", key = "bragi.showHeard",
      about = "Show what was heard and changed under each spoken message.",
      kind = "onOff",
      read = function()
          return settings.get("bragi.showHeard", false) == true
      end,
      show = onOff },
    { id = "quickAnswers", label = "Quick answers", key = "bragi.quickAnswers",
      about = "Answer simple questions with Haiku, reading only.",
      kind = "onOff",
      read = function()
          return settings.get("bragi.quickAnswers", true) ~= false
      end,
      show = onOff },
    { id = "theme", label = "Theme",
      about = "The app's look.",
      kind = "choice", choices = { "light", "dark" },
      read = function()
          return gitgud.theme() or "light"
      end },
    { id = "model", label = "Model", key = "bragi.model",
      about = "The model conversations use, the model button under the prompt box (\"switch to Sonnet\"). "
          .. "The running conversation changes at once.",
      kind = "choice", choices = choiceIds(agent.MODELS),
      read = function()
          return settings.get("bragi.model", "opus")
      end,
      show = function(v)
          return choiceLabel(agent.MODELS, v)
      end },
    { id = "effort", label = "Effort", key = "bragi.effort",
      about = "How hard the model thinks, lowest to highest: low, medium, high, xhigh, max; default is "
          .. "Claude Code's own. \"Think harder\" is one level up from now (read it first), \"think less\" "
          .. "one down. The running conversation changes at once.",
      kind = "choice", choices = effortIds(),
      read = function()
          local v = settings.get("bragi.effort", "")
          return v == "" and EFFORT_DEFAULT or v
      end,
      store = function(v)
          return v == EFFORT_DEFAULT and "" or v
      end,
      show = function(v)
          return choiceLabel(agent.EFFORTS, v == EFFORT_DEFAULT and "" or v)
      end },
    -- Clamped rather than refused ("give me updates every
    -- 30 seconds", 3 seconds to 2 minutes): a value past either end is the end.
    { id = "updateSeconds", label = "Spoken updates every", key = "bragi.updateSeconds",
      about = "Seconds between Bragi's spoken updates on what its conversations are doing, "
          .. bragiSettings.UPDATE_SECONDS.min .. " to " .. bragiSettings.UPDATE_SECONDS.max
          .. " (\"updates every 30 seconds\"; two minutes is 120). Finished work and questions are said "
          .. "at once. A value past either end is set to that end.",
      kind = "number", min = bragiSettings.UPDATE_SECONDS.min, max = bragiSettings.UPDATE_SECONDS.max,
      decimals = 0, clamp = true,
      read = function()
          return tostring(bragiSettings.updateSeconds())
      end,
      show = function(v)
          return short(v) .. " s"
      end },
}

local byId = {}
for _, s in ipairs(settingsTool.SETTINGS) do
    byId[s.id] = s
end

-- ===================================================================
-- Checking a call
-- ===================================================================

--- A number written short to `decimals` places: 1.5, 1.38, 3 (never 1.50).
local function format(n, decimals)
    local s = string.format("%." .. decimals .. "f", n)
    if s:find(".", 1, true) then
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    return s == "-0" and "0" or s
end

--- `n` rounded to `decimals` places, halves away from zero.
local function round(n, decimals)
    local scale = 10 ^ decimals
    local x = n * scale
    x = x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5)
    return x / scale
end

local function finite(n)
    return n == n and n ~= math.huge and n ~= -math.huge
end

local function range(s)
    return format(s.min, s.decimals) .. " to " .. format(s.max, s.decimals)
end

local function choiceList(s)
    return table.concat(s.choices, " or ")
end

local function ids()
    local list = {}
    for _, s in ipairs(settingsTool.SETTINGS) do
        list[#list + 1] = s.id
    end
    return list
end

--- A number from a number or a text ("1.38", "1.38x", "4 s").
local function readNumber(v)
    if type(v) == "number" then
        return finite(v) and v or nil
    end
    if type(v) ~= "string" then
        return nil
    end
    local s = text.trim(v):lower()
    local last = s:sub(-1)
    if last == "x" or last == "s" then
        s = text.trim(s:sub(1, -2))
    end
    local n = s ~= "" and tonumber(s) or nil
    return n and finite(n) and n or nil
end

local function readOnOff(v)
    if type(v) == "boolean" then
        return v
    end
    local s = type(v) == "string" and text.trim(v):lower() or ""
    if s == "true" or s == "on" or s == "yes" then
        return true
    elseif s == "false" or s == "off" or s == "no" then
        return false
    end
    return nil
end

--- A value for setting `s`, as the app keeps it (a boolean for on/off, else
-- a string: numbers rounded and in range, choices lower case), or nil and
-- what's wrong. A clamped number also returns the number asked for.
local function checkValue(s, v)
    if s.kind == "number" then
        local n = readNumber(v)
        if not n then
            return nil, s.id .. " takes a number, " .. range(s) .. "."
        end
        local rounded = round(n, s.decimals)
        if s.clamp and (rounded < s.min or rounded > s.max) then
            return format(math.max(s.min, math.min(s.max, rounded)), s.decimals), nil, n
        end
        if rounded < s.min - 1e-9 or rounded > s.max + 1e-9 then
            return nil, s.id .. " must be from " .. range(s) .. "; " .. format(n, s.decimals + 2)
                .. " is outside it."
        end
        return format(rounded, s.decimals)
    elseif s.kind == "onOff" then
        local b = readOnOff(v)
        if b == nil then
            return nil, s.id .. " is on or off: true or false."
        end
        return b
    elseif s.kind == "choice" then
        local value = type(v) == "string" and text.trim(v):lower() or nil
        for _, choice in ipairs(s.choices) do
            if value == choice then
                return value
            end
        end
        return nil, s.id .. " must be " .. choiceList(s) .. "."
    elseif s.kind == "voice" then
        if type(v) ~= "string" then
            return nil, "voice takes a voice id or name (bragi_settings_get lists them)."
        end
        local value = text.trim(v)
        if #value > MAX_VOICE then
            return nil, "That voice id is too long."
        end
        if value:find("[\0\1-\31]") then
            return nil, "A voice id has no control characters."
        end
        return value
    end
    return nil, s.id .. " can't be set."
end

--- Check a call as the agent sent it. Returns the checked arguments
-- ({ setting? } for get, { setting, value, asked? } for set, asked being
-- the number asked for when it was clamped), or nil and what's wrong and
-- what's allowed.
function settingsTool.check(tool, args)
    if tool ~= "bragi_settings_get" and tool ~= "bragi_settings_set" then
        return nil, "No settings tool named '" .. tostring(tool) .. "'"
    end
    if args ~= nil and type(args) ~= "table" then
        return nil, "The arguments must be an object"
    end
    args = args or {}
    local set = tool == "bragi_settings_set"
    for key in pairs(args) do
        if key ~= "setting" and not (set and key == "value") then
            return nil, "Unknown argument '" .. tostring(key) .. "'"
        end
    end
    if not set and args.setting == nil then
        return {}
    end
    local s = type(args.setting) == "string" and byId[args.setting] or nil
    if not s then
        return nil, (type(args.setting) == "string"
            and ("'" .. args.setting .. "' isn't a setting you can " .. (set and "change" or "read"))
            or "Say which setting") .. ". Allowed: " .. table.concat(ids(), ", ") .. "."
    end
    if not set then
        return { setting = s.id }
    end
    if args.value == nil then
        return nil, "Say the new value."
    end
    local value, why, asked = checkValue(s, args.value)
    if value == nil then
        return nil, why
    end
    return { setting = s.id, value = value, asked = asked }
end

-- ===================================================================
-- The tools' definitions (gitgud.declareTools)
-- ===================================================================

--- One line per setting, for the tools' descriptions.
local function settingList()
    local lines = {}
    for _, s in ipairs(settingsTool.SETTINGS) do
        local line = "\n- " .. s.id .. ": " .. s.about
        if s.kind == "onOff" then
            line = line .. " true or false."
        elseif s.kind == "choice" then
            line = line .. " " .. choiceList(s) .. "."
        end
        lines[#lines + 1] = line
    end
    return table.concat(lines)
end

--- The MCP tools/list entries for bragi_settings_get and bragi_settings_set.
function settingsTool.definitions()
    local list = settingList()
    return {
        {
            name = "bragi_settings_get",
            description = "The app's own settings that you may change, with their current values, "
                .. "what each allows, and the voices to choose from. Read them before a relative "
                .. "change (\"speak 20% faster\" multiplies the current speed)." .. list,
            inputSchema = {
                type = "object",
                properties = {
                    setting = { type = "string", description = "Only this setting (default: all of them).",
                        enum = ids() },
                },
                additionalProperties = false,
            },
            annotations = { readOnlyHint = true },
            noCard = true,
        },
        {
            name = "bragi_settings_set",
            description = "Change one of the app's own settings when the user asks (\"speak faster\", "
                .. "\"dark theme\", \"stop narrating\", \"switch to Sonnet\", \"think harder\", \"give me "
                .. "updates every 30 seconds\"). It applies at once, and the conversation shows "
                .. "the change with an Undo. Values outside a setting's range or choices are refused "
                .. "(updateSeconds is set to the nearer end instead; say the value it got). "
                .. "Only these:" .. list,
            inputSchema = {
                type = "object",
                properties = {
                    setting = { type = "string", description = "Which setting.", enum = ids() },
                    value = { type = { "string", "number", "boolean" },
                        description = "The new value: a number in the setting's range, true or false, "
                            .. "or one of its choices." },
                },
                required = { "setting", "value" },
                additionalProperties = false,
            },
            annotations = { readOnlyHint = false, destructiveHint = false, idempotentHint = true },
            noCard = true, -- its note has Undo
        },
    }
end

local function show(s, v)
    return s.show and s.show(v) or tostring(v)
end

--- A setting's value now.
function settingsTool.current(id)
    local s = byId[id]
    return s and s.read() or nil
end

--- What a change says: "Speaking speed 1.15x -> 1.38x".
local function changeLine(s, old, new)
    return s.label .. " " .. show(s, old) .. " -> " .. show(s, new)
end

local function refreshSettings()
    app.publish("bragi.choices")
    gitgud.after(0, function()
        local view = require("bragi.settings")
        view.rebuild("appearance")
        view.rebuild("claude")
    end)
end

local addNote

-- ===================================================================
-- The theme: after the turn, across the rebuild
-- ===================================================================

local themeWanted = nil   -- { theme, old, line, waitedMs }

--- Switch now: the session ends (the next message resumes it), and the new
-- interface reopens the conversation with the note (bragi.afterTheme).
local function switchTheme(theme, old, line)
    local session = agent.session()
    settings.set("bragi.afterTheme", gitgud.jsonEncode({ resume = session.id or session.resume,
        line = line, old = old }))
    if session.name and session.running then
        gitgud.agentStop(session.name)
    end
    local ok, err = gitgud.setTheme(theme)
    if not ok then
        settings.set("bragi.afterTheme", "")
        addNote("Couldn't switch the theme: " .. tostring(err), nil, true)
    end
end

--- Switch once the turn is over and nothing is being said.
local function themeWhenIdle()
    local w = themeWanted
    if not w then
        return
    end
    local playing = voice().backend.playing and voice().backend.playing()
    if (agent.session().turn or playing) and w.waitedMs < THEME_MAX_WAIT_MS then
        w.waitedMs = w.waitedMs + THEME_POLL_MS
        gitgud.after(THEME_POLL_MS, themeWhenIdle)
        return
    end
    themeWanted = nil
    switchTheme(w.theme, w.old, w.line)
end

local function wantTheme(theme, old, line)
    themeWanted = { theme = theme, old = old, line = line, waitedMs = 0 }
    gitgud.after(THEME_SETTLE_MS, themeWhenIdle)
end

-- ===================================================================
-- Applying and Undo
-- ===================================================================

--- The note in the conversation, with Undo while it can be undone.
addNote = function(line, undo, isError)
    local opts = { error = isError }
    if undo then
        opts.action = { label = "Undo", run = undo }
    end
    return agent.addMessage("note", line, opts)
end

--- Set a setting (a checked value) and show it. Returns the line saying
-- what changed, or nil when it was already so.
-- @param opts  { note = false }: no note (an Undo, which rewrites its own)
function settingsTool.apply(id, value, opts)
    local s = byId[id]
    local old = s.read()
    if old == value then
        return nil
    end
    local line = changeLine(s, old, value)
    if id == "theme" then
        if agent.session().turn then
            wantTheme(value, old, line)
        else
            switchTheme(value, old, line)
        end
        return line
    end
    settings.set(s.key, s.store and s.store(value) or value)
    refreshSettings()
    if opts and opts.note == false then
        return line
    end
    local note
    note = addNote(line, function()
        settingsTool.apply(id, old, { note = false })
        agent.updateNote(note, s.label .. " back to " .. show(s, old))
    end)
    return line
end

-- ===================================================================
-- The tools
-- ===================================================================

--- The voice an id or name stands for, or nil and why not.
local function pickVoice(value)
    if value == "" then
        return ""
    end
    local voices = voice().voices()
    if not voices.list then
        voice().checkVoices()
        return nil, voices.error and "The speech engine has no voices list; choose the voice in Settings."
            or (voice().available() and "The voices list isn't known yet; try again in a moment."
                or voice().unavailableText())
    end
    local lower = value:lower()
    for _, v in ipairs(voices.list) do
        if v.id == value or v.name:lower() == lower then
            if not v.available then
                return nil, v.name .. " isn't available now" .. (v.reason and (": " .. v.reason) or ".")
            end
            return v.id
        end
    end
    local names = {}
    for _, v in ipairs(voices.list) do
        names[#names + 1] = v.name .. " (" .. v.id .. ")"
    end
    return nil, "No voice called \"" .. value .. "\". The voices: " .. table.concat(names, ", ") .. "."
end

local function describe(s)
    local v = s.read()
    local line = s.id .. ": " .. (type(v) == "string" and ("\"" .. v .. "\"") or tostring(v))
        .. " (" .. s.label .. ": " .. show(s, v) .. ")"
    if s.id == "voice" then
        local list = voice().voices().list
        if list then
            local names = {}
            for _, x in ipairs(list) do
                names[#names + 1] = x.name .. " = \"" .. x.id .. "\"" .. (x.available and "" or " (not available)")
            end
            line = line .. "; voices: " .. (#names > 0 and table.concat(names, ", ") or "none")
        else
            line = line .. (voice().available() and "; the voices list isn't known yet"
                or "; voice is off: " .. voice().unavailableText())
        end
    end
    return line
end

--- Answer one checked call: text, isError.
function settingsTool.handle(call)
    local args, why = settingsTool.check(call.tool, call.arguments)
    if not args then
        return why, true
    end
    if call.tool == "bragi_settings_get" then
        local lines = {}
        for _, s in ipairs(settingsTool.SETTINGS) do
            if not args.setting or args.setting == s.id then
                lines[#lines + 1] = describe(s)
            end
        end
        return table.concat(lines, "\n"), false
    end
    local s = byId[args.setting]
    local value = args.value
    if s.id == "voice" then
        local picked, why = pickVoice(value)
        if not picked then
            return why, true
        end
        value = picked
    end
    local kept = ""
    if args.asked then
        kept = " " .. show(s, format(args.asked, s.decimals + 2)) .. " is outside " .. range(s)
            .. ", so it's " .. show(s, value) .. "."
    end
    local line = settingsTool.apply(s.id, value)
    if not line then
        return s.label .. " is already " .. show(s, value) .. "." .. kept, false
    end
    if s.id == "theme" then
        return line .. ". It switches when this turn ends: the window rebuilds and reopens this "
            .. "conversation.", false
    end
    return line .. "." .. kept .. " Done; the conversation shows it with an Undo.", false
end

-- ===================================================================
-- Start-up
-- ===================================================================

--- After a theme switch: reopen the conversation and say what changed.
local function afterTheme()
    local saved = settings.get("bragi.afterTheme", "")
    if saved == "" then
        return
    end
    settings.set("bragi.afterTheme", "")
    local after = gitgud.jsonDecode(saved)
    if type(after) ~= "table" then
        return
    end
    gitgud.after(300, function()
        if after.resume then
            agent.resume(after.resume)
        end
        local note
        note = addNote(after.line or "Theme changed", after.old and function()
            agent.updateNote(note, "Theme back to " .. after.old)
            switchTheme(after.old, gitgud.theme(), "Theme " .. gitgud.theme() .. " -> " .. after.old)
        end or nil)
    end)
end

function settingsTool.init()
    -- Declared with the UI's other tools (bragi/uitools.lua), which hands
    -- each call here.
    require("bragi.uitools").register(settingsTool.definitions(), function(call)
        local reply, isError = settingsTool.handle(call)
        return reply or "", isError == true
    end)
    afterTheme()
end

return settingsTool
