--- bragi/training.lua: wake word training and voice enrollment (the app's
-- half; the speech engine does the rest). Settings shows it as the Voice
-- training section.
--
-- Both run on the listen socket, so starting either turns listening on
-- first (bragi/voice.lua) and waits for the speech engine to be ready.
--
-- Training: each utterance comes back as a sample (what speech-to-text
-- heard, the spotter's score, whether it would wake). Stop ends the
-- session and the engine suggests mishearings and a threshold. Each
-- mishearing shows as a checkbox: ordinary dictionary words ("Roger",
-- "Right", asked of gitgud.isDictionaryWord) start unchecked, since the
-- text wake would fire on them in normal talk. Removing a sample takes its
-- transcript off the mishearings and moves the threshold to sit the same
-- margin below the weakest sample kept; it's never saved below
-- MIN_THRESHOLD. Apply saves the checked mishearings and the threshold
-- (bragi.mishearings, bragi.wakeThreshold) and sends them to the engine;
-- they go with every later `hello` too.
--
-- Enrollment: the user talks normally; the seconds of speech so far show as
-- they go. Stop makes the voiceprint (kept on this computer, no audio); Forget
-- deletes it.
--
-- Public API: training.state(), training.startTraining(), training.stopTraining(),
-- training.remove(n), training.pick(word, on), training.suggestion(), training.apply(),
-- training.startEnroll(), training.stopEnroll(),
-- training.forget(), training.cards() (for bragi/settings.lua)

local app = require("core.app")
local settings = require("core.settings")
local voice = require("bragi.voice")

local training = { name = "bragi.training" }

local ENROLL_NEEDED = 10    -- seconds of speech the engine needs (its default)

-- The lowest wake threshold Apply saves. Noise, the TV, and other voices
-- reach spotter scores around 0.1, so below this false wakes are likely;
-- the engine's suggestion can go lower (a margin under the weakest sample,
-- down to its 0.05 floor) when some samples were quiet or far away.
local MIN_THRESHOLD = 0.15

-- mode: idle, starting-train, training, trained (a result to apply),
-- starting-enroll, enrolling.
local state = {
    mode = "idle",
    samples = {},       -- { n, text, score, detected, removed }
    result = nil,       -- the engine's trainResult
    picks = {},         -- its mishearings: { word, everyday, checked }
    enrolled = nil,     -- true / false once the engine said
    seconds = 0,        -- enrollment speech so far
    message = nil,      -- the last outcome, shown in its row
    messageFor = nil,   -- "train" or "enroll"
}

local function rebuild()
    require("bragi.settings").rebuild("training")
end

--- The current state (for tests and the section).
function training.state()
    return state
end

--- Send the waiting start, once listening.
local function startNow()
    if state.mode == "starting-train" then
        state.mode = "training"
        voice.backend.train("start")
    elseif state.mode == "starting-enroll" then
        state.mode = "enrolling"
        voice.backend.enroll("start")
    end
end

--- Start training ("train") or enrollment ("enroll"), turning voice on first.
local function begin(what)
    state.mode = "starting-" .. what
    state.message = nil
    if voice.state() == "listening" or voice.state() == "hearing" then
        startNow()
    elseif voice.state() == "off" then
        voice.toggle()
        if voice.state() == "off" then
            state.mode = "idle" -- not signed in, or it didn't start
        end
    end
    rebuild()
end

function training.startTraining()
    state.samples = {}
    state.result = nil
    state.picks = {}
    begin("train")
end

function training.stopTraining()
    if state.mode == "training" then
        voice.backend.train("stop")
    end
    if state.mode ~= "training" then
        state.mode = "idle"
        rebuild()
    end
end

function training.startEnroll()
    state.seconds = 0
    begin("enroll")
end

function training.stopEnroll()
    if state.mode == "enrolling" then
        voice.backend.enroll("stop")
    else
        state.mode = "idle"
        rebuild()
    end
end

function training.forget()
    if voice.state() == "off" then
        state.message, state.messageFor = "Turn voice on (the mic in the Agent view) first.", "enroll"
        rebuild()
        return
    end
    voice.backend.enroll("clear")
end

local function kept()
    local list = {}
    for _, s in ipairs(state.samples) do
        if not s.removed then
            list[#list + 1] = s
        end
    end
    return list
end

local function lowest(samples)
    local low = nil
    for _, s in ipairs(samples) do
        if type(s.score) == "number" and (not low or s.score < low) then
            low = s.score
        end
    end
    return low
end

--- Is a mishearing an ordinary word (it would wake Bragi in normal talk)?
-- True, false, or nil when the platform can't tell.
local function everyday(word)
    if type(gitgud.isDictionaryWord) ~= "function" then
        return nil
    end
    local ok, answer = pcall(gitgud.isDictionaryWord, word)
    if ok then
        return answer
    end
    return nil
end

--- What Apply would save: { mishearings, threshold, suggested, raised,
-- picks }. picks are the mishearings still offered (their samples weren't
-- removed), mishearings the checked ones; suggested is the threshold
-- before it's raised to MIN_THRESHOLD, raised whether it was.
function training.suggestion()
    local r = state.result
    if not r then
        return nil
    end
    local removedText = {}
    for _, s in ipairs(state.samples) do
        if s.removed and s.text then
            removedText[s.text:lower()] = true
        end
    end
    local picks, mishearings = {}, {}
    for _, p in ipairs(state.picks) do
        if not removedText[p.word:lower()] then
            picks[#picks + 1] = p
            if p.checked then
                mishearings[#mishearings + 1] = p.word
            end
        end
    end
    local threshold = tonumber(r.threshold)
    local allLow, keptLow = lowest(state.samples), lowest(kept())
    if threshold and allLow and keptLow then
        local margin = math.max(0, allLow - threshold)
        threshold = math.max(0, keptLow - margin)
    end
    local suggested, raised = threshold, false
    if threshold and threshold < MIN_THRESHOLD - 1e-9 then
        threshold, raised = MIN_THRESHOLD, true
    end
    return { mishearings = mishearings, threshold = threshold, suggested = suggested, raised = raised,
        picks = picks }
end

--- Check or uncheck a suggested mishearing (before Apply).
function training.pick(word, on)
    for _, p in ipairs(state.picks) do
        if p.word == word then
            p.checked = on and true or false
        end
    end
end

--- Take a sample out (before Apply).
function training.remove(n)
    for _, s in ipairs(state.samples) do
        if s.n == n then
            s.removed = true
        end
    end
    rebuild()
end

--- Save the mishearings and threshold, and tell the engine.
function training.apply()
    local s = training.suggestion()
    if not s then
        return
    end
    settings.set("bragi.mishearings", gitgud.jsonEncode(s.mishearings))
    if s.threshold then
        settings.set("bragi.wakeThreshold", string.format("%.3f", s.threshold))
    end
    if voice.state() ~= "off" then
        voice.backend.config(voice.tuning())
    end
    state.mode = "idle"
    state.result = nil
    state.samples = {}
    state.picks = {}
    state.messageFor = "train"
    state.message = "Saved " .. #s.mishearings .. (#s.mishearings == 1 and " mishearing" or " mishearings")
        .. (s.threshold and string.format(" and threshold %.2f.", s.threshold) or ".")
    rebuild()
end

local handlers = {}

function handlers.ready(e)
    if type(e.speaker) == "table" then
        state.enrolled = e.speaker.enrolled == true
    end
    startNow()
    rebuild()
end

function handlers.trainSample(e)
    if state.mode ~= "training" then
        return
    end
    state.samples[#state.samples + 1] = { n = e.n, text = e.text or "", score = e.score, detected = e.detected == true }
    rebuild()
end

function handlers.trainResult(e)
    state.result = e
    state.picks = {}
    local seen = {}
    for _, m in ipairs(type(e.mishearings) == "table" and e.mishearings or {}) do
        local word = tostring(m)
        if word ~= "" and not seen[word:lower()] then
            seen[word:lower()] = true
            local ordinary = everyday(word) == true
            state.picks[#state.picks + 1] = { word = word, everyday = ordinary, checked = not ordinary }
        end
    end
    state.mode = #state.samples > 0 and "trained" or "idle"
    if state.mode == "idle" then
        state.message, state.messageFor = "No samples were heard.", "train"
    end
    rebuild()
end

function handlers.enrollSample(e)
    if state.mode == "enrolling" then
        state.seconds = tonumber(e.seconds) or state.seconds
        rebuild()
    end
end

function handlers.enrollResult(e)
    state.mode = "idle"
    state.messageFor = "enroll"
    state.enrolled = e.enrolled == true
    if e.reason == "too-short" then
        state.message = string.format("Not enough speech (%.0f s of %d s). Try again and talk a little longer.",
            tonumber(e.seconds) or 0, ENROLL_NEEDED)
    elseif e.reason == "not-saved" then
        state.message = "The voiceprint couldn't be saved on this computer."
    else
        state.message = state.enrolled and "Your voice is enrolled." or "Your voice is forgotten."
    end
    rebuild()
end

function handlers.error(e)
    if state.mode == "idle" then
        return
    end
    if e.code == "busy" or e.code == "no-speaker-model" or e.code == "bad-user" then
        state.messageFor = state.mode:find("enroll") and "enroll" or "train"
        state.message = tostring(e.message or e.code)
        state.mode = "idle"
        rebuild()
    end
end

local function onVoice(now)
    if now == "off" and state.mode ~= "idle" and state.mode ~= "trained" then
        state.messageFor = state.mode:find("enroll") and "enroll" or "train"
        state.mode = "idle"
        state.message = "Voice stopped."
        rebuild()
    end
end

-- ===================================================================
-- The settings section
-- ===================================================================

local function sampleRow(s)
    local heard = s.text ~= "" and ("\u{201C}" .. s.text .. "\u{201D}") or "(nothing heard)"
    local score = type(s.score) == "number" and string.format("Score %.2f", s.score) or "No score"
    return {
        kind = "action",
        title = heard,
        sub = score .. (s.detected and ", would wake" or ", would not wake"),
        button = "Remove",
        run = function()
            training.remove(s.n)
        end,
    }
end

--- A suggested mishearing, as a checkbox row.
local function pickRow(p, word)
    return {
        kind = "toggle",
        title = "\u{201C}" .. p.word .. "\u{201D}",
        sub = p.everyday and "An everyday word: it may wake Bragi in normal talk."
            or ("Heard for \u{201C}" .. word .. "\u{201D}. Checked, it wakes Bragi too."),
        value = function()
            return p.checked
        end,
        onToggle = function(on)
            training.pick(p.word, on)
        end,
    }
end

--- The Voice training section's cards, built from the state.
function training.cards()
    local word = settings.get("bragi.wakeWord", "Bragi")
    local trainRows = {}
    local mode = state.mode
    local trainSub
    if mode == "training" then
        trainSub = "Listening. Say \u{201C}" .. word .. "\u{201D} again and again: facing different ways, "
            .. "near and far, loud and quiet. Press Stop when you're done."
    elseif mode == "starting-train" then
        trainSub = "Connecting to the voice service."
    else
        trainSub = "Say \u{201C}" .. word .. "\u{201D} 8 to 10 times so Bragi learns how it's misheard "
            .. "and how strongly it reacts to your voice. Only transcripts and scores are kept."
    end
    if state.message and state.messageFor == "train" and mode == "idle" then
        trainSub = state.message .. " " .. trainSub
    end
    trainRows[1] = {
        kind = "action",
        title = "Train the wake word",
        sub = trainSub,
        button = (mode == "training" or mode == "starting-train") and "Stop" or "Start",
        primary = mode ~= "training" and mode ~= "starting-train" and mode ~= "trained", -- Apply is, then
        enabled = mode ~= "enrolling" and mode ~= "starting-enroll",
        run = function()
            if mode == "training" or mode == "starting-train" then
                training.stopTraining()
            else
                training.startTraining()
            end
        end,
    }
    local sampleRows = {}
    for _, s in ipairs(state.samples) do
        if not s.removed then
            sampleRows[#sampleRows + 1] = sampleRow(s)
        end
    end
    local learnedRows = nil
    local suggestion = mode == "trained" and training.suggestion()
    if suggestion then
        learnedRows = {}
        for _, p in ipairs(suggestion.picks) do
            learnedRows[#learnedRows + 1] = pickRow(p, word)
        end
        if #suggestion.picks == 0 then
            learnedRows[1] = { kind = "info", title = "No mishearings",
                sub = "Every sample kept was heard as \u{201C}" .. word .. "\u{201D}." }
        end
        if suggestion.threshold then
            learnedRows[#learnedRows + 1] = {
                kind = "info",
                title = string.format("Wake threshold %.2f", suggestion.threshold),
                sub = suggestion.raised
                    and string.format("Raised from the suggested %.2f: lower lets noise and other voices wake Bragi.",
                        suggestion.suggested)
                    or "How strongly the spotter must react to your voice to wake.",
            }
        end
        learnedRows[#learnedRows + 1] = {
            kind = "action",
            title = "Save what was learned",
            sub = "The checked mishearings and the threshold.",
            button = "Apply",
            primary = true,
            run = training.apply,
        }
    end

    local enrollSub
    if mode == "enrolling" then
        enrollSub = string.format("Listening. Talk normally for 20 to 30 seconds. %.0f s of speech so far (%d s needed).",
            state.seconds, ENROLL_NEEDED)
    elseif mode == "starting-enroll" then
        enrollSub = "Connecting to the voice service."
    elseif state.enrolled == true then
        enrollSub = "Enrolled. Bragi tells your voice from others in the room."
    else
        enrollSub = "So Bragi can tell your voice from others in the room. Talk normally for 20 to 30 seconds."
    end
    if state.message and state.messageFor == "enroll" and mode == "idle" then
        enrollSub = state.message .. " " .. enrollSub
    end
    local enrollRows = {
        {
            kind = "action",
            title = "Enroll your voice",
            sub = enrollSub,
            button = (mode == "enrolling" or mode == "starting-enroll") and "Stop" or (state.enrolled and "Redo" or "Start"),
            primary = mode ~= "enrolling" and mode ~= "starting-enroll" and state.enrolled ~= true,
            enabled = mode ~= "training" and mode ~= "starting-train" and mode ~= "trained",
            run = function()
                if mode == "enrolling" or mode == "starting-enroll" then
                    training.stopEnroll()
                else
                    training.startEnroll()
                end
            end,
        },
        {
            kind = "action",
            title = "Forget my voice",
            sub = "Deletes your voiceprint from this computer.",
            button = "Forget",
            enabled = state.enrolled == true and mode == "idle",
            run = training.forget,
        },
    }

    -- What was learned goes above the samples, so Apply is in sight even
    -- after twenty of them.
    local cards = { { heading = "Wake word", rows = trainRows } }
    if learnedRows then
        cards[#cards + 1] = { heading = "What was learned", rows = learnedRows }
    end
    if #sampleRows > 0 then
        cards[#cards + 1] = { heading = "Samples", rows = sampleRows }
    end
    cards[#cards + 1] = { heading = "Your voice", rows = enrollRows }
    return cards
end

function training.init()
    for kind, fn in pairs(handlers) do
        gitgud.on("voice." .. kind, function(detail)
            local e = gitgud.jsonDecode(detail)
            fn(type(e) == "table" and e or {})
        end)
    end
    app.subscribe("bragi.voice", onVoice)
end

function training.refresh()
end

return training
