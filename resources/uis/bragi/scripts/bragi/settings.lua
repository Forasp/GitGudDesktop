--- bragi/settings.lua: the Settings view (layouts/bragi/settings.xml).
--
-- A list of sections on the left; the open section's cards on the right,
-- built from the SECTIONS table with bragi/ui.lua. Every control saves as
-- it changes, under "bragi.*" in core/settings.lua:
--
--   bragi.model, bragi.mode   the agent's model and permission mode
--   bragi.effort, bragi.outputStyle
--                             effort (a running session takes it at once) and
--                             output style (from the next session)
--   bragi.mute                Bragi's voice muted (bragi/voice.lua)
--   bragi.notify              ask for you when a session finishes or needs a
--                             permission while the app is in the background
--   bragi.quickAnswers        simple questions answered by Haiku, reading
--                             only (bragi/quick.lua; on)
--   bragi.listen              listen for the wake word
--   bragi.wakeWord            what wakes it ("Bragi")
--   bragi.closingPhrase       what ends dictation ("over and out"; "" = Send only)
--   bragi.endWaitSeconds      the wait once you seem done (2 to 10, from your pause)
--   bragi.showHeard           show what was heard and changed under a spoken
--                             message (for troubleshooting; off)
--   bragi.voiceApprovals      ask permission cards aloud and take a spoken
--                             yes or no (on)
--   bragi.approvalSeconds     how long it listens for that answer (5 to 60, "12")
--   bragi.followUpSeconds     how long it listens, without the wake word, after
--                             a spoken reply that asks something (3 to 30,
--                             "8"; bragi/voice.lua)
--   bragi.speak              speak replies (a summary, never the full text)
--   bragi.summaryLength       how long that summary is ("short", "medium")
--   bragi.narrate             say what the agent is doing while it works
--   bragi.narrateAway         keep telling a conversation's work after you
--                             switch to another, until you send to another
--                             (off; bragi/voice.lua, "Whose work is told")
--   bragi.updateSeconds       how often Bragi says what its conversations are
--                             doing (3 to 120, "10"; bragiSettings.updateSeconds)
--   bragi.speechSpeed         how fast Bragi speaks ("0.8" to "1.5"; unset, the
--                             voice's own: "1.3" for the built-in voice, "1.15")
--   bragi.voice               the voice replies speak with: an id from the
--                             engine's voices list, picked with Preview and
--                             Use ("" = its default)
--   bragi.recordVoice         save the mic audio the engine gets, as WAV files
--                             (Troubleshooting; off, bragi/voice.lua)
--   bragi.corrections         learned corrections of what was heard
--                             (bragi/vocabulary.lua), listed with Remove
--   bragi.userName            your name, for the prompts (bragi/user.lua; "" =
--                             "the user")
--   bragi.projectsFolder      where Bragi clones repositories you name by
--                             address (default: Projects in the home folder)
--   bragi.mishearings, bragi.wakeThreshold
--                             what wake word training saved (bragi/training.lua)
--   bragi.voiceOff            why voice is off after the app closed inside
--                             the speech engine ("" when it isn't; Voice
--                             models, Turn on, clears it)
--
-- bragi/voice.lua reads the voice settings (listening itself is the mic in the
-- Agent view; its helpers run bragi.helperModel, "claude-haiku-5-5"). The voice
-- cards show which provider the speech engine uses each way
-- (voice.providerLine). Until voice is available (a build with the speech
-- engine, its models installed), the voice cards and Voice training say
-- why instead; Appearance and voice has the Voice models card and the
-- models' credits whenever the engine is there (voiceGated,
-- bragi/voicemodels.lua).
--
-- A section's cards may be a function, asked at each build (Voice training).
-- bragiSettings.edit opens a text file in place of the section's cards
-- (Save, Cancel); Instructions and memory edits Claude Code's files there.
--
-- Public API: bragiSettings.open(section), bragiSettings.close(),
-- bragiSettings.rebuild(section), bragiSettings.edit({ title, path | body, save }),
-- bragiSettings.cards(root, cards, width, y) (the card builder, for
-- bragi/welcome.lua), bragiSettings.widget(card, row, part),
-- bragiSettings.editor(part) (for tests)
--
-- Signals (app.publish): "bragi.section" (id) when a section asks to be
-- rebuilt, so the welcome flow can follow the same changes.

local C = require("core.palette")
local agent = require("bragi.agent")
local app = require("core.app")
local commands = require("ui.commands")
local settings = require("core.settings")
local settingsView = require("views.settings")
local shell = require("bragi.shell")
local text = require("core.text")
local ui = require("bragi.ui")

local bragiSettings = { name = "bragi.settings" }

local MAX_WIDTH = 760   -- the content column, padding included
local PAD_X = 40
local PAD_Y = 28

--- A path as short as it reads: the home folder as ~.
local function shortPath(path)
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
    path = tostring(path):gsub("\\", "/")
    home = home:gsub("\\", "/")
    if home ~= "" and path:sub(1, #home):lower() == home:lower() then
        path = "~" .. path:sub(#home + 1)
    end
    return path
end

--- Names from a list of strings or of { name, status? } tables.
local function names(list, withStatus)
    local out = {}
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        if type(entry) == "table" then
            local name = tostring(entry.name or "?")
            out[#out + 1] = (withStatus and entry.status) and (name .. " (" .. tostring(entry.status) .. ")") or name
        else
            out[#out + 1] = tostring(entry)
        end
    end
    return out
end

--- The hook events set in a settings file (Claude Code's settings.json).
local function hooksIn(path)
    local f = io.open(path, "rb")
    if not f then
        return {}
    end
    local parsed = gitgud.jsonDecode(f:read("a"))
    f:close()
    local events = {}
    if type(parsed) == "table" and type(parsed.hooks) == "table" then
        for event in pairs(parsed.hooks) do
            events[#events + 1] = event
        end
    end
    table.sort(events)
    return events
end

--- The "What the agent loads" card, from the last session.
local function loadedCard()
    local l = agent.loaded()
    if not l then
        return { heading = "What the agent loads", rows = {
            { kind = "info", title = "No session yet", sub = "Start one in the Agent view to see what Claude Code loads: "
                .. "instructions, memory, MCP servers and connectors, skills, plugins, hooks." } } }
    end
    local function list(t, empty)
        return #t > 0 and table.concat(t, ", ") or empty
    end
    local instructions, memory, hooks = {}, {}, {}
    for _, file in ipairs(l.files or {}) do
        if file.kind == "memory" then
            memory[#memory + 1] = file.path:match("[^/\\]+$")
        elseif file.kind == "settings" then
            local events = hooksIn(file.path)
            if #events > 0 then
                hooks[#hooks + 1] = table.concat(events, ", ") .. " in " .. shortPath(file.path)
            end
        else
            instructions[#instructions + 1] = shortPath(file.path)
        end
    end
    local source = l.apiKeySource
    local signIn = (source == nil or source == "none") and "Your claude.ai sign-in."
        or ("An API key (" .. tostring(source) .. "): connectors, synced skills, and plugins don't load. "
            .. "Run claude and use /login with your subscription.")
    return { heading = "What the agent loads", rows = {
        { kind = "info", title = "Signed in with", sub = signIn },
        { kind = "info", title = "Claude Code", sub = "Version " .. tostring(l.version or "?") .. ", model "
            .. tostring(l.model or "?") .. ", output style " .. tostring(l.outputStyle or "default") .. "." },
        { kind = "info", title = "Instructions", sub = list(instructions, "No CLAUDE.md files or rules.") },
        { kind = "info", title = "Auto memory", sub = list(memory, "Nothing remembered for this folder yet.") },
        { kind = "info", title = "MCP servers and connectors", sub = list(names(l.mcpServers, true), "None.") },
        { kind = "info", title = "Skills", sub = list(names(l.skills), "None.") },
        { kind = "info", title = "Plugins", sub = list(names(l.plugins), "None.") },
        { kind = "info", title = "Subagents", sub = list(names(l.agents), "None.") },
        { kind = "info", title = "Hooks", sub = list(hooks, "None set in your settings files.") },
    } }
end

local current = "appearance"
local editing = nil     -- the file in the editor: { title, path, section, body, error }
local editorRoot = nil  -- the editor's widgets' prefix while it shows
local built = 0         -- sections built so far (names stay unique)
local picker = nil      -- the microphone and speaker rows (bragi.devices)

--- A choice row's current label.
local function choice(list, key, default)
    return function()
        return agent.choiceLabel(list, key, default)
    end
end

-- The Claude section's model and permission choices.
local CLAUDE_AGENT_CARD = {
    heading = "Agent",
    rows = {
        { kind = "choice", title = "Model", label = choice(agent.MODELS, "bragi.model", "opus"),
          pick = function(button)
              agent.pickChoice(button, agent.MODELS, "bragi.model", "opus")
          end },
        { kind = "choice", title = "Permissions", sub = "What the agent may do without asking.",
          label = choice(agent.MODES, "bragi.mode", "default"),
          pick = function(button)
              agent.pickChoice(button, agent.MODES, "bragi.mode", "default")
          end },
        { kind = "choice", title = "Effort", sub = "How hard it thinks. The conversation running takes it at once.",
          label = choice(agent.EFFORTS, "bragi.effort", ""),
          pick = function(button)
              agent.pickChoice(button, agent.EFFORTS, "bragi.effort", "")
          end },
        { kind = "choice", title = "Output style", sub = "How it writes its answers. From the next session.",
          label = choice(agent.STYLES, "bragi.outputStyle", "default"),
          pick = function(button)
              agent.pickChoice(button, agent.STYLES, "bragi.outputStyle", "default")
          end },
        { kind = "action", title = "Claude account",
          sub = "Sign in with your claude.ai subscription, so connectors, synced skills, and plugins load. "
              .. "Opens a window that finishes in your browser.",
          button = "Sign in",
          run = function()
              gitgud.spawn(require("bragi.claude").program() .. " auth login --claudeai")
          end },
        { kind = "toggle", title = "Notifications",
          sub = "When a session finishes or needs a permission while the app is in the background.",
          key = "bragi.notify", default = true },
        { kind = "toggle", title = "Answer simple questions with Haiku",
          sub = "The time, the branch, what a file says: answered at once, reading only. "
              .. "Say \u{201C}ask Opus\u{201D} or \u{201C}think hard\u{201D} to skip it.",
          key = "bragi.quickAnswers", default = true },
    },
}

-- Each section: a title, and cards of rows. Row kinds:
--   toggle  { title, sub, key, default }, or { title, sub, value, onToggle = fn(bool) }
--           for a choice that isn't a setting (value may be a function)
--   input   { title, sub, key, default, number, min, max, onChange = fn(value) }
--           (a number is kept to min..max when given; Enter shows what was
--           kept), or
--           { title, sub, value, secret, onChange } for a value that isn't a
--           setting (secret: masked, never saved)
--   slider  { title, sub, key, min, steps = { { upTo, step }, ... }, read = fn,
--           show = fn(n), onChange = fn(n) }: a track to drag along, the
--           value beside it (show(n)). Its positions are min, then each
--           step up to its upTo in turn (bragiSettings.sliderValues); read()
--           is the value now, which may lie between them (the thumb goes
--           to the nearest, the label says it exactly). Saves as it moves
--   choice  { title, sub, label = fn, pick = fn(button) }
--   action  { title, sub, button, run = fn, enabled = bool, primary }
--   info    { title, sub }: a line of text, the hint wrapping across the card
--   progress { title, sub, fraction = fn }: a step and its bar across the
--           card; fraction() is 0 to 1, or nil for a step with no numbers
--           (the bar pulses). bragiSettings.paintProgress() repaints every
--           progress row showing (its sub and bar) without a rebuild
--   themes  the two theme cards
--   custom  { height, build = fn(card, prefix, y, width) }: anything else
-- title, sub, button, and primary may be functions, asked at each build.
--- Who recognises ("stt") or speaks ("tts"), for the voice cards.
-- How long the spoken summary of a reply is (bragi/voice.lua).
local SUMMARY_LENGTHS = {
    { id = "short", label = "Short" },
    { id = "medium", label = "Medium" },
}

-- How fast Bragi speaks (bragi/voice.lua sends it as `speed`).
local SPEECH_SPEEDS = {
    { id = "0.8", label = "0.8x, slower" },
    { id = "0.9", label = "0.9x" },
    { id = "1", label = "1x, the voice's own pace" },
    { id = "1.15", label = "1.15x" },
    { id = "1.3", label = "1.3x" },
    { id = "1.5", label = "1.5x, fastest" },
}

--- The speaking speed's label: a listed one, else the number (the agent
-- may set any speed in range, bragi/settingstool.lua).
local function speedLabel()
    local speed = require("bragi.voice").speechSpeed()
    for _, s in ipairs(SPEECH_SPEEDS) do
        if math.abs(tonumber(s.id) - speed) < 0.001 then
            return s.label
        end
    end
    return (string.format("%.2f", speed):gsub("0+$", ""):gsub("%.$", "")) .. "x"
end

-- How often Bragi says what its conversations are doing
-- ("adjustable from 3 seconds to 2 minutes, default 10 seconds"). Finished
-- work and questions are said at once, whatever this is. Set with a slider
-- ("1-second steps up to 10, then 5 seconds"); a value
-- set by voice between the steps is kept as said.
bragiSettings.UPDATE_SECONDS = { default = 10, min = 3, max = 120,
    steps = { { upTo = 10, step = 1 }, { upTo = 120, step = 5 } } }

--- Seconds between spoken updates: the setting, kept to 3..120.
function bragiSettings.updateSeconds()
    local limits = bragiSettings.UPDATE_SECONDS
    local seconds = tonumber(settings.get("bragi.updateSeconds", "")) or limits.default
    return math.floor(math.max(limits.min, math.min(limits.max, seconds)) + 0.5)
end

--- Seconds as the slider shows them: "30 s", whole minutes as "2 min".
function bragiSettings.showSeconds(n)
    if n >= 60 and n % 60 == 0 then
        return math.floor(n / 60) .. " min"
    end
    return tostring(math.floor(n + 0.5)) .. " s"
end

local function providerLine(direction)
    local voice = require("bragi.voice")
    voice.checkProviders()
    return voice.providerLine(direction)
end

-- The voice picker (Voice output): a line saying what's chosen, then one
-- row per voice the engine offers, each with Preview and Use. An engine
-- with no voices list gets a field for a voice id.
local VOICE_HEAD = 64
local VOICE_ROW = 56

local function voicePickerHeight()
    local voices = require("bragi.voice").voices()
    if voices.error then
        return VOICE_HEAD + 18 -- the old field's hint wraps to two lines
    end
    return VOICE_HEAD + (voices.list and #voices.list * VOICE_ROW or 0)
end

local function voiceSub(v)
    local parts = { (v.provider or "") ~= "" and v.provider or "This computer" }
    if v.description then
        parts[#parts + 1] = v.description
    end
    if not v.available then
        parts[#parts + 1] = v.reason or "Not available now"
    end
    for i, part in ipairs(parts) do
        parts[i] = part:gsub("^%l", string.upper):gsub("%.$", "")
    end
    return table.concat(parts, ". ") .. "."
end

local function buildVoicePicker(card, prefix, y, width)
    local voice = require("bragi.voice")
    voice.checkVoices()
    local voices = voice.voices()
    local right = width - 20
    local controlX = math.floor(width / 2) + 8
    local labelWidth = voices.error and controlX - 28 or width - 40
    local sub
    if voices.error then
        sub = "A voice id for the speech engine. Empty: its default voice."
    elseif not voices.list then
        sub = "Asking the speech engine for its voices."
    elseif #voices.list == 0 then
        sub = "The speech engine offers no voices."
    else
        local chosen = voice.chosenVoice()
        sub = "Speaking with " .. (chosen and chosen.name or "the default voice")
            .. ". Preview plays a short sample."
    end
    ui.label(prefix .. "Title", card, { 20, y + 14, labelWidth, 20 },
        voices.error and "Voice id" or "Voice", { font = "Bragi-14-Bold" })
    ui.paragraph(prefix .. "Sub", card, { 20, y + 36, labelWidth, voicePickerHeight() - 40 }, sub,
        { font = "Bragi-13", colour = C.sub })
    if voices.error then
        local edit = ui.input(prefix .. "Input", card, { controlX, y + 12, right - controlX, 40 },
            settings.get("bragi.voice", ""))
        gitgud.on(edit .. ".changed", function(value)
            settings.set("bragi.voice", text.trim(value))
        end)
        return
    end
    local chosen = voice.chosenVoice()
    for i, v in ipairs(voices.list or {}) do
        local ry = y + VOICE_HEAD + (i - 1) * VOICE_ROW
        local name = prefix .. "Voice" .. i
        ui.rule(name .. "Rule", card, { 20, ry, width - 40, 1 })
        ui.label(name .. "Name", card, { 20, ry + 9, right - 250, 20 },
            v.name .. (v.id == voices.default and "  (default)" or ""), { font = "Bragi-14-Bold" })
        ui.label(name .. "Sub", card, { 20, ry + 29, right - 250, 18 }, voiceSub(v),
            { font = "Bragi-13", colour = C.sub })
        local preview = ui.button(name .. "Preview", card, { right - 220, ry + 10, 104, 36 }, "Preview")
        local inUse = chosen and chosen.id == v.id
        local use = ui.button(name .. "Use", card, { right - 104, ry + 10, 104, 36 }, inUse and "In use" or "Use",
            { primary = not inUse and v.available })
        if not v.available then
            gitgud.setEnabled(preview, false)
        else
            gitgud.on(preview .. ".clicked", function()
                local ok, err = voice.preview(v.id)
                if not ok then
                    gitgud.setText(name .. "Sub", text.escape("Couldn't play it: " .. err))
                end
            end)
        end
        if inUse or not v.available then
            gitgud.setEnabled(use, false)
        else
            gitgud.on(use .. ".clicked", function()
                settings.set("bragi.voice", v.id)
                gitgud.after(0, function()
                    bragiSettings.rebuild("appearance")
                end)
            end)
        end
    end
end

-- What the voice cards say in a build without the speech engine.
local VOICE_MISSING = { heading = "Voice", rows = {
    { kind = "info", title = "Not part of this build",
      sub = "This build of GitGud has no speech engine, so talking to Bragi and spoken replies are off. "
          .. "Type to Bragi." } } }

-- What voice training says before the models are installed.
local VOICE_NEEDS_MODELS = { heading = "Voice", rows = {
    { kind = "info", title = "The voice models come first",
      sub = "Install them in Appearance and voice, Voice models." } } }

-- Which card in Appearance and voice shows an install's progress (its
-- first row's sub), or nil.
local modelsCard = nil

--- A section's cards with voice in them: all of them while voice is
-- available, else the first `keep` cards. With `keep` (the section with
-- the voice models), the engine's cards (bragi/voicemodels.lua: Voice
-- models, the voice for replies, the credits) come last.
local function voiceGated(all, keep)
    return function()
        local models = require("bragi.voicemodels")
        local engine = models.engineInstalled()
        local list = type(all) == "function" and all() or all
        local cards = {}
        local available = require("bragi.voice").available()
        for i, card in ipairs(list) do
            if available or i <= (keep or 0) then
                cards[#cards + 1] = card
            end
        end
        if not available and not keep then
            cards[#cards + 1] = engine and VOICE_NEEDS_MODELS or VOICE_MISSING
        end
        if keep then
            modelsCard = nil
            if engine then
                for _, card in ipairs(models.cards({ settings = true })) do
                    cards[#cards + 1] = card
                    if card.progress then
                        modelsCard = #cards
                    end
                end
            elseif not available then
                cards[#cards + 1] = VOICE_MISSING
            end
        end
        return cards
    end
end

--- The "You" card: the name Bragi uses for you (Settings, Claude, and the
-- welcome flow's Claude Code step).
function bragiSettings.youCard()
    return { heading = "You", rows = {
        { kind = "input", title = "Your name",
          sub = "What Bragi and its helpers call you. Empty: \"the user\".",
          key = "bragi.userName", default = "" },
    } }
end

local SECTIONS = {
    {
        id = "appearance",
        label = "Appearance and voice",
        cards = voiceGated({
            { heading = "Appearance", rows = { { kind = "themes" } } },
            { heading = "Microphone and speakers", rows = function()
                  return picker.rows()
              end },
            {
                heading = "Voice input",
                rows = {
                    { kind = "toggle", title = "Listen for the wake word",
                      sub = "Speech is recognised on this computer.", key = "bragi.listen", default = false },
                    { kind = "info", title = "Speech recognition", sub = function()
                          return providerLine("stt")
                      end },
                    { kind = "info", title = "Echo cancellation", sub = function()
                          return require("bragi.voice").micLine()
                      end },
                    { kind = "input", title = "Wake word", key = "bragi.wakeWord", default = "Bragi" },
                    { kind = "input", title = "Closing phrase", sub = "Pauses never send. Say this phrase, or press Send.",
                      key = "bragi.closingPhrase", default = "over and out" },
                    { kind = "input", title = "Wait when you seem done",
                      sub = "When you seem finished, Bragi goes ahead this many seconds (2 to 10) after you paused.",
                      key = "bragi.endWaitSeconds", default = "3", number = true },
                    { kind = "toggle", title = "Show what was heard",
                      sub = "Under each spoken message: what was heard and what was changed. For troubleshooting.",
                      key = "bragi.showHeard", default = false },
                    { kind = "action", title = "Train the wake word and your voice",
                      sub = "Say it a few times so Bragi learns how it's misheard, and enroll your voice.",
                      button = "Open", run = function()
                          bragiSettings.open("training")
                      end },
                    { kind = "toggle", title = "Answer permissions and questions by voice",
                      sub = "Bragi asks aloud, and your next words without the wake word are the answer.",
                      key = "bragi.voiceApprovals", default = true },
                    { kind = "input", title = "Time to answer",
                      sub = "Seconds Bragi listens for your answer after asking (5 to 60).",
                      key = "bragi.approvalSeconds", default = "12", number = true },
                    { kind = "input", title = "Time to answer a question",
                      sub = "After a spoken reply that asks you something, seconds Bragi listens for your "
                          .. "answer without the wake word (3 to 30).",
                      key = "bragi.followUpSeconds", default = "8", number = true },
                },
            },
            {
                heading = "Voice output",
                rows = {
                    { kind = "toggle", title = "Speak replies",
                      sub = "A spoken summary; the full reply stays on screen.", key = "bragi.speak", default = true },
                    { kind = "toggle", title = "Mute Bragi",
                      sub = "Nothing is said aloud; everything still shows. The speaker button beside the mic "
                          .. "does the same.",
                      key = "bragi.mute", default = false, onToggle = function(on)
                          require("bragi.voice").setMuted(on, { fromSettings = true })
                      end },
                    { kind = "choice", title = "Summary length",
                      label = choice(SUMMARY_LENGTHS, "bragi.summaryLength", "short"),
                      pick = function(button)
                          agent.pickChoice(button, SUMMARY_LENGTHS, "bragi.summaryLength", "short")
                      end },
                    { kind = "choice", title = "Speaking speed",
                      label = speedLabel,
                      pick = function(button)
                          -- Unset, the voice's own pace (1.3 for the built-in voice).
                          agent.pickChoice(button, SPEECH_SPEEDS, "bragi.speechSpeed",
                              string.format("%g", require("bragi.voice").speechSpeed()))
                      end },
                    { kind = "toggle", title = "Narrate while it works",
                      sub = "Say in a few words what the agent is doing, as it goes.",
                      key = "bragi.narrate", default = true },
                    { kind = "slider", title = "Spoken updates every",
                      sub = "Time between updates on what your conversations are doing. "
                          .. "Finished work and questions for you are said at once.",
                      key = "bragi.updateSeconds", min = bragiSettings.UPDATE_SECONDS.min,
                      steps = bragiSettings.UPDATE_SECONDS.steps, read = bragiSettings.updateSeconds,
                      show = bragiSettings.showSeconds },
                    { kind = "info", title = "Speech output", sub = function()
                          return providerLine("tts")
                      end },
                    { kind = "custom", height = voicePickerHeight, build = buildVoicePicker },
                    { kind = "toggle", title = "Keep talking when you switch away",
                      sub = "Go on telling a conversation's work after you open another one, "
                          .. "until you send a message somewhere else.",
                      key = "bragi.narrateAway", default = false },
                },
            },
            { heading = "Learned corrections", rows = function()
                  return require("bragi.vocabulary").cards(function()
                      bragiSettings.rebuild("appearance")
                  end)
              end },
            {
                heading = "Troubleshooting",
                rows = {
                    { kind = "toggle", title = "Record what the engine hears",
                      sub = "While listening, the microphone audio the speech engine gets is saved as WAV "
                          .. "files in the voice-recordings folder. The last 10 are kept, up to 200 MB.",
                      key = "bragi.recordVoice", default = false, onToggle = function()
                          require("bragi.voice").recordingChanged()
                      end },
                    { kind = "action", title = "Recordings", sub = "The voice-recordings folder.",
                      button = "Show", run = function()
                          gitgud.showInFolder(gitgud.configPath("bragi/voice-recordings"))
                      end },
                },
            },
        }, 1),
    },
    {
        id = "training",
        label = "Voice training",
        cards = voiceGated(function()
            return require("bragi.training").cards()
        end),
    },
    {
        id = "memory",
        label = "Instructions and memory",
        cards = function()
            return require("bragi.memory").cards()
        end,
    },
    {
        id = "claude",
        label = "Claude",
        cards = function()
            return { CLAUDE_AGENT_CARD, loadedCard(), bragiSettings.youCard() }
        end,
    },
    {
        id = "routines",
        label = "Routines",
        cards = function()
            return require("bragi.routines").cards()
        end,
    },
    {
        id = "import",
        label = "Import",
        cards = function()
            return require("bragi.import").cards()
        end,
    },
    {
        id = "git",
        label = "Git",
        cards = {
            {
                heading = "Git",
                rows = {
                    { kind = "action", title = "Name, email, and default branch", button = "Edit",
                      run = function()
                          settingsView.options()
                      end },
                    { kind = "action", title = "Commit signing", sub = "Sign commits with gpg or an SSH key.",
                      button = "Set up", run = function()
                          settingsView.signing()
                      end },
                },
            },
            {
                heading = "Interface",
                rows = {
                    { kind = "action", title = "Switch interface", sub = "GitGud, Depot, or Bragi.",
                      button = "Choose", run = function()
                          settingsView.switchInterface()
                      end },
                    { kind = "action", title = "Setup",
                      sub = "Walk through Claude Code, the look, import, and voice again.",
                      button = "Run again", run = function()
                          require("bragi.welcome").start()
                      end },
                },
            },
            -- Your own changes to this interface (bragi/customize.lua).
            { heading = "Interface customizations", rows = function()
                  return require("bragi.customize").rows()
              end },
        },
    },
    {
        id = "projects",
        label = "Projects",
        cards = {
            {
                -- Where Bragi (bragi/master.lua) clones a repository you
                -- name by its address.
                heading = "Projects",
                rows = {
                    { kind = "input", title = "Projects folder",
                      sub = "Where Bragi clones a repository when you give it the address.",
                      key = "bragi.projectsFolder", default = require("bragi.projects").projectsFolder() },
                    { kind = "action", title = "Choose the folder", button = "Choose", run = function()
                          local folder = gitgud.pickFolder("Choose the projects folder")
                          if folder then
                              settings.set("bragi.projectsFolder", folder)
                              bragiSettings.rebuild("projects")
                          end
                      end },
                },
            },
        },
    },
    {
        id = "shortcuts",
        label = "Shortcuts",
        cards = {
            {
                heading = "Everywhere",
                rows = {
                    { kind = "note", title = "Search or run any command", sub = "Ctrl+K" },
                    { kind = "note", title = "Agent, Repo, Boards, Wiki", sub = "Ctrl+1, Ctrl+2, Ctrl+3, Ctrl+4" },
                    { kind = "note", title = "Settings", sub = "Ctrl+," },
                },
            },
            {
                heading = "Agent",
                rows = {
                    { kind = "note", title = "Send", sub = "Enter" },
                    { kind = "note", title = "New line", sub = "Shift+Enter" },
                    { kind = "note", title = "New session", sub = "Ctrl+N" },
                    { kind = "note", title = "Show or hide the sessions", sub = "Ctrl+B" },
                },
            },
            {
                heading = "Repository",
                rows = {
                    { kind = "note", title = "Branches, remotes, tags, stashes", sub = "Ctrl+Shift+B" },
                    { kind = "note", title = "Every other command",
                      sub = "In the command palette, with its shortcut" },
                },
            },
        },
    },
}

--- The content column's width for the window.
local function columnWidth()
    local _, _, w = gitgud.getRect("SettingsContent")
    return math.max(420, math.min(MAX_WIDTH, w or MAX_WIDTH)) - 2 * PAD_X
end

local ROW_HEIGHT = { toggle = 64, input = 64, choice = 64, action = 64, note = 52, themes = 76, info = 64,
    progress = 80, slider = 64 }
local BAR_HEIGHT = 6
local THUMB = 20         -- a slider's thumb
local SLIDER_VALUE = 64  -- the value beside it

--- The values a slider row stops at: min, then each { upTo, step } in turn.
function bragiSettings.sliderValues(row)
    local values = { row.min }
    for _, s in ipairs(row.steps) do
        while values[#values] + s.step <= s.upTo + 1e-9 do
            values[#values + 1] = values[#values] + s.step
        end
    end
    return values
end

--- The position (from 1) of the value nearest `n` (the lower on a tie).
local function nearestStop(values, n)
    local best = 1
    for i, v in ipairs(values) do
        if math.abs(v - n) < math.abs(values[best] - n) then
            best = i
        end
    end
    return best
end

--- A slider row's control: a track with the part up to the thumb filled,
-- and the value at its right. Pressing anywhere on it moves the thumb
-- there; dragging moves it on. Widgets: prefix .. "Slider" (what takes the
-- mouse), "SliderTrack", "SliderFill", "SliderThumb", and "Value".
local function buildSlider(card, prefix, row, y, x, right)
    local values = bragiSettings.sliderValues(row)
    local width = right - SLIDER_VALUE - 12 - x
    local span = width - THUMB
    local half = THUMB / 2
    local hit = ui.box(prefix .. "Slider", card, { x, y + 12, width, 40 },
        { radius = 4, fill = C.transparent, border = C.transparent })
    ui.box(prefix .. "SliderTrack", hit, { half, 17, span, BAR_HEIGHT }, { radius = 4, fill = C.border,
        border = C.transparent })
    local fill = ui.box(prefix .. "SliderFill", hit, { half, 17, 0, BAR_HEIGHT }, { radius = 4, fill = C.accent,
        border = C.transparent })
    local thumb = ui.box(prefix .. "SliderThumb", hit, { 0, 10, THUMB, THUMB }, { radius = 10, fill = C.accent,
        border = C.accentPressed })
    for _, part in ipairs({ "SliderTrack", "SliderFill", "SliderThumb" }) do
        gitgud.setProperty(prefix .. part, "CursorPassThroughEnabled", "true")
    end
    local label = ui.label(prefix .. "Value", card, { right - SLIDER_VALUE, y + 12, SLIDER_VALUE, 40 }, "",
        { align = "RightAligned" })

    local function paint(n)
        local px = #values > 1 and math.floor(span * (nearestStop(values, n) - 1) / (#values - 1) + 0.5) or 0
        gitgud.setProperty(thumb, "Area", string.format("{{0,%d},{0,10},{0,%d},{0,%d}}", px, px + THUMB, 10 + THUMB))
        gitgud.setProperty(fill, "Area", string.format("{{0,%d},{0,17},{0,%d},{0,%d}}", half, half + px,
            17 + BAR_HEIGHT))
        gitgud.setVisible(fill, px > 0)
        gitgud.setText(label, text.escape(row.show and row.show(n) or tostring(n)))
    end
    paint(row.read())

    -- The cursor's x ("x,y", window pixels) to the stop under it.
    local function moveTo(pos)
        local cx = tonumber(tostring(pos):match("^(-?%d+)"))
        local hx = gitgud.getRect(hit)
        if not cx or not hx then
            return
        end
        local t = span > 0 and math.max(0, math.min(1, (cx - hx - half) / span)) or 0
        local n = values[1 + math.floor(t * (#values - 1) + 0.5)]
        paint(n)
        if n ~= row.read() then
            settings.set(row.key, tostring(n))
            if row.onChange then
                row.onChange(n)
            end
        end
    end
    gitgud.setDraggable(hit, true)
    gitgud.setCursor(hit, "hand")
    gitgud.on(hit .. ".dragStarted", function(pos)
        gitgud.setProperty(thumb, "FillColour", C.accentHover)
        moveTo(pos)
    end)
    gitgud.on(hit .. ".dragging", moveTo)
    gitgud.on(hit .. ".dragEnded", function()
        gitgud.setProperty(thumb, "FillColour", C.accent)
    end)
end

-- The progress rows built and maybe still showing: name prefix -> { row, width }.
local bars = {}
local pulsing = false
local HINT_LINE = 18     -- each extra line a wrapped hint needs

--- A row field's value (fields may be functions).
local function field(value)
    if type(value) == "function" then
        return value()
    end
    return value
end

--- A row's height: its kind's, plus room for a hint that wraps.
-- @param row    the row
-- @param width  the card's width
local function rowHeight(row, width)
    if row.kind == "custom" then
        return field(row.height)
    end
    if row.kind == "themes" then
        -- Two to a line: Light and Dark, then any of your own.
        local n = math.max(2, #(gitgud.themes() or {}))
        return math.ceil(n / 2) * (ROW_HEIGHT.themes + 12) - 12
    end
    local h = ROW_HEIGHT[row.kind]
    local sub = field(row.sub)
    if sub and row.kind ~= "note" then
        local labelWidth = (row.kind == "toggle" and width - 80)
            or ((row.kind == "info" or row.kind == "progress") and width - 40) or math.floor(width / 2) - 28
        -- About 6.5px a character at 13px.
        local lines = math.max(1, math.ceil(#sub * 6.5 / math.max(80, labelWidth)))
        h = h + (lines - 1) * HINT_LINE
    end
    return h
end

--- Build one row into a card. Returns its height.
local function buildRow(card, prefix, row, y, width)
    local h = rowHeight(row, width)
    if row.kind == "custom" then
        row.build(card, prefix, y, width)
        return h
    end
    if row.kind == "themes" then
        local half = math.floor((width - 12) / 2)
        local chosen = gitgud.theme()
        local swatches = {
            { id = "light", title = "Light", sub = "Sage and oat", bg = "FFEDEEDF", text = "FF1F3B36",
              subColour = "FF4C645C", dot = "FFE3A83A", ring = "FFF7F7EC", edge = "FF8A5A12" },
            { id = "dark", title = "Dark", sub = "Spruce and honey", bg = "FF1B2A27", text = "FFECE7D8",
              subColour = "FFB9C2B0", dot = "FFE8B866", ring = "FF213330", edge = "FFE8B866" },
        }
        -- Your own themes (themes/<name>.ini in the customizations folder,
        -- bragi/customize.lua), in their own colours.
        for _, id in ipairs(gitgud.themes() or {}) do
            if id ~= "light" and id ~= "dark" then
                local c = require("bragi.customize").themeColours(id) or {}
                swatches[#swatches + 1] = { id = id, title = id:sub(1, 1):upper() .. id:sub(2), sub = "Your theme",
                    bg = c.bg or "FF1B2A27", text = c.text or "FFECE7D8", subColour = c.sub or "FFB9C2B0",
                    dot = c.accent or "FFE8B866", ring = c.panel or "FF213330", edge = c.accent or "FFE8B866" }
            end
        end
        local tile = ROW_HEIGHT.themes
        for i, s in ipairs(swatches) do
            local name = prefix .. "Theme" .. s.id
            local x = ((i - 1) % 2) * (half + 12)
            local ty = y + math.floor((i - 1) / 2) * (tile + 12)
            ui.button(name, card, { x, ty, half, tile }, "", { radius = 12 })
            gitgud.setProperty(name, "NormalFillColour", s.bg)
            gitgud.setProperty(name, "HoverFillColour", s.bg)
            gitgud.setProperty(name, "PushedFillColour", s.bg)
            gitgud.setProperty(name, "BorderColour", s.id == chosen and s.edge or C.border)
            ui.box(name .. "Ring", name, { 16, 24, 28, 28 }, { radius = 12, fill = s.ring, border = C.transparent })
            gitgud.setProperty(name .. "Ring", "CursorPassThroughEnabled", "true")
            ui.box(name .. "Dot", name .. "Ring", { 4, 4, 20, 20 }, { radius = 10, fill = s.dot, border = C.transparent })
            gitgud.setProperty(name .. "Dot", "CursorPassThroughEnabled", "true")
            ui.label(name .. "Title", name, { 56, 18, half - 70, 20 }, s.title, { font = "Bragi-14-Bold", colour = s.text })
            ui.label(name .. "Sub", name, { 56, 40, half - 70, 18 }, s.sub, { font = "Bragi-13", colour = s.subColour })
            gitgud.on(name .. ".clicked", function()
                if gitgud.theme() ~= s.id then
                    gitgud.setTheme(s.id)
                end
            end)
        end
        return h
    end

    local labelWidth = (row.kind == "toggle" and width - 80)
        or ((row.kind == "info" or row.kind == "progress") and width - 40) or math.floor(width / 2) - 28
    local sub = field(row.sub)
    local titleY = sub and y + 14 or y + math.floor((ROW_HEIGHT[row.kind] - 20) / 2)
    ui.label(prefix .. "Title", card, { 20, titleY, labelWidth, 20 }, field(row.title), { font = "Bragi-14-Bold" })
    if sub then
        -- Long hints wrap under the title.
        ui.paragraph(prefix .. "Sub", card, { 20, titleY + 22, labelWidth, h - 34 }, sub,
            { font = "Bragi-13", colour = C.sub })
    end

    local right = width - 20
    local controlX = math.floor(width / 2) + 8
    if row.kind == "toggle" then
        local checked
        if row.key then
            checked = settings.get(row.key, row.default)
        else
            checked = field(row.value)
        end
        local check = ui.check(prefix .. "Check", card, { right - 22, y + 21, 22, 22 }, checked)
        gitgud.on(check .. ".toggled", function(value)
            if row.key then
                settings.set(row.key, value == "1")
            end
            if row.onToggle then
                row.onToggle(value == "1")
            end
        end)
    elseif row.kind == "input" then
        local initial = row.key and settings.get(row.key, row.default) or field(row.value) or ""
        local edit = ui.input(prefix .. "Input", card, { controlX, y + 12, right - controlX, 40 }, initial)
        if row.secret then
            gitgud.setProperty(edit, "TextMaskingEnabled", "true")
            gitgud.setProperty(edit, "TextMaskingRevealTime", "1")
        end
        gitgud.on(edit .. ".changed", function(value)
            value = row.secret and (value or "") or text.trim(value)
            if row.number then
                local n = tonumber(value) or tonumber(row.default)
                if n and row.min then
                    n = math.max(row.min, n)
                end
                if n and row.max then
                    n = math.min(row.max, n)
                end
                value = n and tostring(n) or row.default
            end
            if row.key then
                settings.set(row.key, value)
            end
            if row.onChange then
                row.onChange(value)
            end
        end)
        if row.number and row.key and (row.min or row.max) then
            -- Kept as it's typed ("1" on the way to "15" is 3 for a moment);
            -- Enter shows the value kept.
            gitgud.on(edit .. ".accepted", function()
                gitgud.setText(edit, text.escape(settings.get(row.key, row.default)))
            end)
        end
    elseif row.kind == "slider" then
        buildSlider(card, prefix, row, y, controlX, right)
    elseif row.kind == "choice" then
        local button = ui.button(prefix .. "Choice", card, { controlX, y + 12, right - controlX, 40 }, row.label(),
            { align = "LeftAligned", font = "Bragi-14" })
        gitgud.on(button .. ".clicked", function()
            row.pick(button)
        end)
        app.subscribe("bragi.choices", function()
            gitgud.setText(button, text.escape(row.label()))
        end)
    elseif row.kind == "action" then
        local button = ui.button(prefix .. "Action", card, { right - 140, y + 14, 140, 36 }, field(row.button),
            { primary = field(row.primary) })
        if row.enabled == false then
            gitgud.setEnabled(button, false)
        else
            gitgud.on(button .. ".clicked", row.run)
        end
    elseif row.kind == "note" then
        ui.label(prefix .. "Keys", card, { controlX, y, right - controlX, h }, row.sub,
            { font = "Bragi-Mono-13", colour = C.sub, align = "RightAligned" })
    elseif row.kind == "progress" then
        local track = ui.box(prefix .. "Bar", card, { 20, y + h - 18, width - 40, BAR_HEIGHT },
            { radius = 4, fill = C.well, border = C.transparent })
        ui.box(prefix .. "BarFill", track, { 0, 0, 0, BAR_HEIGHT }, { radius = 4, fill = C.accent,
            border = C.transparent })
        bars[prefix] = { row = row, width = width - 40 }
        bragiSettings.paintProgress()
    end
    return h
end

local function paintBar(prefix, b, now)
    local fraction = b.row.fraction and b.row.fraction() or nil
    local fill = prefix .. "BarFill"
    if fraction then
        local w = math.floor(b.width * fraction + 0.5)
        gitgud.setProperty(fill, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}", w, BAR_HEIGHT))
        gitgud.setVisible(fill, w > 0)
        return false
    end
    -- No numbers: a block going back and forth, so it never looks stuck.
    local block = math.floor(b.width / 4)
    local span = b.width - block
    local t = (now % 2400) / 1200
    local x = math.floor(span * (t <= 1 and t or 2 - t) + 0.5)
    gitgud.setProperty(fill, "Area", string.format("{{0,%d},{0,0},{0,%d},{0,%d}}", x, x + block, BAR_HEIGHT))
    gitgud.setVisible(fill, true)
    return true
end

--- Repaint every progress row still showing: its line (sub) and its bar.
-- A row whose step has no numbers keeps pulsing (about 25 frames a second)
-- until it's gone or has numbers.
function bragiSettings.paintProgress()
    local now = gitgud.now()
    local pulse = false
    for prefix, b in pairs(bars) do
        if not gitgud.getRect(prefix .. "Bar") then
            bars[prefix] = nil
        else
            if type(b.row.sub) == "function" then
                gitgud.setText(prefix .. "Sub", text.escape(b.row.sub()))
            end
            pulse = paintBar(prefix, b, now) or pulse
        end
    end
    if pulse and not pulsing then
        pulsing = true
        local function tick()
            pulsing = false
            bragiSettings.paintProgress()
        end
        gitgud.after(40, tick)
    end
end

--- The progress rows showing (for tests): { { name, fraction, pulsing } }.
function bragiSettings.progressBars()
    local out = {}
    for prefix, b in pairs(bars) do
        if gitgud.getRect(prefix .. "Bar") then
            local fraction = b.row.fraction and b.row.fraction() or nil
            local _, _, w = gitgud.getRect(prefix .. "BarFill")
            out[#out + 1] = { name = prefix, fraction = fraction, pulsing = fraction == nil, fillWidth = w }
        end
    end
    return out
end

local build

--- Save the editor's text (to its file, or through its save function).
-- True when it was saved.
local function saveEditing()
    local body = gitgud.getText(editorRoot .. "Editor") or ""
    body = body:gsub("\n*$", "") .. "\n"
    if editing.save then
        local ok, err = editing.save(body)
        if ok == false then
            editing.error = err or "Couldn't save"
            editing.body = body
            return false
        end
        return true
    end
    local f = io.open(editing.path, "wb")
    if not f then
        -- A folder that doesn't exist yet (~/.claude, .claude/rules).
        local dir = editing.path:gsub("[/\\][^/\\]*$", "")
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
        f = io.open(editing.path, "wb")
    end
    if not f then
        editing.error = "Couldn't write " .. editing.path
        editing.body = body
        return false
    end
    f:write(body)
    f:close()
    return true
end

--- The editor, in place of the section's cards.
local function buildEditor(root, width)
    local _, _, _, h = gitgud.getRect("SettingsContent")
    local height = math.max(240, (h or 640) - 2 * PAD_Y - 100)
    ui.heading(root .. "EditHeading", root, { PAD_X, PAD_Y, width, 18 }, editing.title)
    editorRoot = root
    local editor = root .. "Editor"
    gitgud.createWindow("Gitgud/MultiLineEditbox", editor, root)
    gitgud.setProperty(editor, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}",
        PAD_X, PAD_Y + 28, PAD_X + width, PAD_Y + 28 + height))
    gitgud.setProperty(editor, "Font", "Bragi-Mono-13")
    gitgud.setText(editor, editing.body)
    local y = PAD_Y + 28 + height + 16
    if editing.error then
        ui.label(root .. "EditError", root, { PAD_X, y + 8, width - 300, 20 }, editing.error, { colour = C.err })
    else
        ui.label(root .. "EditHint", root, { PAD_X, y + 8, width - 300, 20 },
            "Claude Code reads it at the start of each session.", { colour = C.sub })
    end
    local save = ui.button(root .. "EditorSave", root, { PAD_X + width - 140, y, 140, 36 }, "Save", { primary = true })
    local cancel = ui.button(root .. "EditorCancel", root, { PAD_X + width - 292, y, 140, 36 }, "Cancel")
    gitgud.on(save .. ".clicked", function()
        if saveEditing() then
            editing = nil
        end
        build()
    end)
    gitgud.on(cancel .. ".clicked", function()
        editing = nil
        build()
    end)
    gitgud.setProperty(root, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}", width + 2 * PAD_X, y + 36 + PAD_Y))
    gitgud.focus(editor)
end

--- Build the open section into SettingsContent.
build = function()
    if built > 0 then
        gitgud.destroyWindow("SettingsSection" .. built)
    end
    built = built + 1
    local root = "SettingsSection" .. built
    local width = columnWidth()
    gitgud.createWindow("DefaultWindow", root, "SettingsContent")
    editorRoot = nil
    if editing and editing.section == current then
        buildEditor(root, width)
        return
    end

    local section
    for _, s in ipairs(SECTIONS) do
        if s.id == current then
            section = s
        end
    end

    local cards = type(section.cards) == "function" and section.cards() or section.cards
    local y = bragiSettings.cards(root, cards, width, PAD_Y)
    gitgud.setProperty(root, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}", width + 2 * PAD_X, y))
end

--- Build cards (headings, then rows) into a window, from `y` down.
-- @param root   the window; widget names start with it
-- @param cards  { { heading, rows }, ... } as in SECTIONS (rows may be a
--               function returning them)
-- @param width  the cards' width
-- @param y      where the first heading goes
-- @return the y below the last card
function bragiSettings.cards(root, cards, width, y)
    for ci, card in ipairs(cards) do
        if type(card.rows) == "function" then
            card = { heading = card.heading, rows = card.rows() }
        end
        ui.heading(root .. "H" .. ci, root, { PAD_X, y, width, 18 }, card.heading)
        y = y + 28
        local cardName = root .. "C" .. ci
        local rowsHeight = 0
        for _, row in ipairs(card.rows) do
            rowsHeight = rowsHeight + rowHeight(row, width)
        end
        local isThemes = card.rows[1].kind == "themes"
        if isThemes then
            gitgud.createWindow("DefaultWindow", cardName, root)
            gitgud.setProperty(cardName, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}",
                PAD_X, y, PAD_X + width, y + rowsHeight))
        else
            ui.card(cardName, root, { PAD_X, y, width, rowsHeight })
        end
        local ry = 0
        for ri, row in ipairs(card.rows) do
            if ri > 1 then
                ui.rule(cardName .. "Rule" .. ri, cardName, { 0, ry, width, 1 })
            end
            ry = ry + buildRow(cardName, cardName .. "R" .. ri, row, ry, width)
        end
        y = y + rowsHeight + 28
    end
    return y
end

--- Paint the section list.
local function paintNav()
    for _, s in ipairs(SECTIONS) do
        local name = "SettingsNav_" .. s.id
        local active = s.id == current
        gitgud.setProperty(name, "NormalFillColour", active and C.sel or C.transparent)
        gitgud.setProperty(name, "HoverFillColour", active and C.sel or C.hover)
        gitgud.setProperty(name, "NormalTextColour", active and C.text or C.sub)
        gitgud.setProperty(name, "HoverTextColour", C.text)
    end
end

--- Show the Settings view at a section.
-- @param section  a section id (default: the last one shown)
function bragiSettings.open(section)
    if section and section ~= current then
        editing = nil
    end
    current = section or current
    if shell.view() == "settings" then
        paintNav()
        build()
    else
        shell.show("settings") -- builds through the "bragi.view" signal
    end
end

--- Open a text in place of the section's cards (Save, Cancel): a file
-- (one that doesn't exist yet starts empty and is made on Save), or any
-- text with a save function.
-- @param spec  { title, path } or { title, body, save = fn(text) -> ok, err? }
function bragiSettings.edit(spec)
    local body = spec.body
    if spec.path then
        local f = io.open(spec.path, "rb")
        body = f and f:read("a") or ""
        if f then
            f:close()
        end
    end
    editing = { title = spec.title or spec.path, path = spec.path, save = spec.save, section = current,
        body = body or "" }
    build()
end

--- The editor's widget names while it shows, else nil (for tests).
-- @param part  "" (the text), "Save", or "Cancel"
function bragiSettings.editor(part)
    return editorRoot and (editorRoot .. "Editor" .. (part or "")) or nil
end

--- The name of a row's widget in the section showing (for tests).
-- @param card  card number, from 1
-- @param row   row number, from 1
-- @param part  "Title", "Sub", "Action", "Input", "Check", "Choice", or a
--              slider's "Slider", "SliderThumb", "SliderFill", "Value"
function bragiSettings.widget(card, row, part)
    return "SettingsSection" .. built .. "C" .. card .. "R" .. row .. part
end

--- Build a section again if it's the one showing.
function bragiSettings.rebuild(section)
    if shell.view() == "settings" and current == section then
        build()
    end
    app.publish("bragi.section", section)
end

--- The microphone level meter's state (for tests): { on, level, error }.
function bragiSettings.meter()
    return picker.meter()
end

function bragiSettings.close()
    shell.show("agent")
end

function bragiSettings.init()
    picker = require("bragi.devices").new({
        rebuild = function()
            bragiSettings.rebuild("appearance")
        end,
        micSub = "Voice listens with it. A new pick applies at once.",
    })
    for i, s in ipairs(SECTIONS) do
        local name = "SettingsNav_" .. s.id
        ui.button(name, "SettingsNav", { 12, 20 + (i - 1) * 44, 216, 40 }, s.label,
            { quiet = true, align = "LeftAligned", font = "Bragi-14-Bold" })
        gitgud.on(name .. ".clicked", function()
            bragiSettings.open(s.id)
        end)
    end
    gitgud.on("SettingsSearch.clicked", commands.open)
    commands.register({ label = "What Claude Code loaded", keywords = "memory instructions mcp skills plugins hooks",
        action = function()
            bragiSettings.open("claude")
        end })
    app.subscribe("bragi.loaded", function()
        bragiSettings.rebuild("claude")
    end)
    -- Later, not inside a build: the voice cards ask for the providers.
    app.subscribe("bragi.voiceProviders", function()
        gitgud.after(0, function()
            bragiSettings.rebuild("appearance")
        end)
    end)
    app.subscribe("bragi.voiceList", function()
        gitgud.after(0, function()
            bragiSettings.rebuild("appearance")
        end)
    end)
    app.subscribe("bragi.voiceMic", function()
        gitgud.after(0, function()
            bragiSettings.rebuild("appearance")
        end)
    end)
    -- The voice models' install: a new step rebuilds, progress just updates
    -- its line (the models card's first row).
    local phase = nil
    app.subscribe("bragi.voiceModels", function(s)
        if s.phase == phase and s.phase ~= "idle" and s.phase ~= "done" and s.phase ~= "failed" then
            bragiSettings.paintProgress()
            return
        end
        phase = s.phase
        gitgud.after(0, function()
            bragiSettings.rebuild("appearance")
            bragiSettings.rebuild("training")
        end)
    end)
    app.subscribe("bragi.voiceAvailable", function()
        gitgud.after(0, function()
            bragiSettings.rebuild("appearance")
            bragiSettings.rebuild("training")
        end)
    end)
    app.subscribe("bragi.voicesChanged", function()
        require("bragi.voice").checkVoices(true)
        gitgud.after(0, function()
            bragiSettings.rebuild("appearance")
        end)
    end)

    require("core.keys").bind("ctrl+,", function()
        bragiSettings.open()
    end, "Settings")

    app.subscribe("bragi.view", function(view)
        if view ~= "settings" then
            picker.setMeter(false)
        end
        if view == "settings" then
            paintNav()
            build()
        end
    end)
    gitgud.on("window.resized", function()
        if shell.view() == "settings" then
            build()
        end
    end)
    paintNav()
end

return bragiSettings
