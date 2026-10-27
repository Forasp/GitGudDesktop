--- bragi/decider.lua: when you're done talking, from the turn-taking model.
--
-- The model (bragi/voicemodels.lua, "decide"; the engine runs it) reads the
-- message so far, Bragi's last words before it, the open project, and the
-- silence since the speech ended, and answers with three sets of
-- probabilities: the turn state (complete, mid_thought, holding,
-- still_going), who it's for (bragi, someone_else, nobody), and whether it's
-- about the project (yes, partly, no). It was trained on how its owner
-- talks, pauses included: a message isn't more than half complete under
-- half a second of silence, and a long pause after an unfinished thought
-- still waits.
--
-- How voice.lua uses it: once the words have stopped growing for SETTLE_MS,
-- it's asked every EVERY_MS with the message as it is; when the turn state
-- is complete at THRESHOLD or more, after at least MIN_SILENCE seconds of
-- silence, the message ends ("done"). Who and project are only logged for
-- now. Without the model (not installed, or the engine couldn't load or run
-- it), a Haiku helper judges when you're done, as before.
--
-- Public API: decider.THRESHOLD, decider.MIN_SILENCE, decider.SETTLE_MS,
-- decider.EVERY_MS, decider.WAIT_MS, decider.projectLine(), decider.request(id, message, asked),
-- decider.read(e), decider.done(d), decider.summary(d)

local repo = require("core.repo")
local text = require("core.text")

local decider = { name = "bragi.decider" }

decider.THRESHOLD = 0.8    -- complete at least this sure
decider.MIN_SILENCE = 0.6  -- seconds of silence before a message can end
decider.SETTLE_MS = 500    -- the words stopped growing this long before asking
decider.EVERY_MS = 500     -- asked again this often while the silence grows
decider.WAIT_MS = 2000     -- an answer not back by then: ask again

local ABOUT_WORDS = 40      -- the project line's description, at most
local projectCache = { path = nil, line = nil }

--- What the project's README says it is: its first paragraph of prose.
local function readmeAbout()
    local body = gitgud.readRepoFile("README.md") or gitgud.readRepoFile("readme.md") or ""
    local para = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = text.trim(line)
        local prose = trimmed ~= "" and not trimmed:find("^#") and not trimmed:find("^[!<%[|>`=-]")
            and not trimmed:find("^%*%*?$")
        if prose then
            para[#para + 1] = trimmed
        elseif #para > 0 then
            break
        end
    end
    local s = table.concat(para, " ")
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1"):gsub("[`*_]", "")
    local list = {}
    for w in s:gmatch("%S+") do
        list[#list + 1] = w
        if #list >= ABOUT_WORDS then
            break
        end
    end
    return table.concat(list, " ")
end

--- "<name>: <what it is>" for the open repository (its README's first
-- paragraph), "<name>" without one; "" with none open.
function decider.projectLine()
    local s = repo.state()
    if not s.open or s.path == "" then
        return ""
    end
    if projectCache.path ~= s.path then
        local about = readmeAbout()
        projectCache.path = s.path
        projectCache.line = about ~= "" and (s.name .. ": " .. about) or s.name
    end
    return projectCache.line
end

--- The engine's `decide` request for a message so far.
-- @param id       the request's id
-- @param message  the message so far, as heard
-- @param asked    Bragi's last words before it ("" or nil for none)
function decider.request(id, message, asked)
    local spec = require("bragi.voicemodels").DECIDER
    local body = ""
    local last = {}
    for w in tostring(asked or ""):gmatch("%S+") do
        last[#last + 1] = w
    end
    if #last > 0 then
        local from = math.max(1, #last - spec.askedWords + 1)
        body = "asked: " .. table.concat(last, " ", from) .. " | "
    end
    body = body .. "message: " .. text.trim(tostring(message or "")) .. " | pause: {pause} s"
    return { id = id, first = decider.projectLine(), second = body, maxLength = spec.maxLength,
        firstMax = spec.firstMax }
end

--- A `decision` as labels: { state = {complete = p, ...}, who, project,
-- top (the likeliest state), pause, speaking, ms }, or nil and the error.
function decider.read(e)
    if type(e.error) == "string" then
        return nil, e.error
    end
    if type(e.outputs) ~= "table" then
        return nil, "no outputs"
    end
    local spec = require("bragi.voicemodels").DECIDER
    local out = {}
    for name, labels in pairs(spec.outputs) do
        local values = e.outputs[name]
        if type(values) ~= "table" or #values ~= #labels then
            return nil, "output " .. name .. " isn't what the model gives"
        end
        local set = {}
        for i, label in ipairs(labels) do
            set[label] = tonumber(values[i]) or 0
        end
        out[name:gsub("^p_", "")] = set
    end
    local top, best = nil, -1
    for _, label in ipairs(spec.outputs.p_state) do
        if out.state[label] > best then
            top, best = label, out.state[label]
        end
    end
    out.top = top
    out.pause = tonumber(e.pause) or 0
    out.speaking = e.speaking == true
    out.ms = tonumber(e.ms)
    return out
end

--- Whether a decision ends the message.
function decider.done(d)
    return d.top == "complete" and d.state.complete >= decider.THRESHOLD and d.pause >= decider.MIN_SILENCE
        and not d.speaking
end

-- A set as "label 0.12, ..." in its order, for the log.
local function rounded(set, labels)
    local parts = {}
    for _, label in ipairs(labels) do
        parts[#parts + 1] = string.format("%s %.2f", label, set[label] or 0)
    end
    return table.concat(parts, ", ")
end

--- A decision in one line for the log.
function decider.summary(d)
    local spec = require("bragi.voicemodels").DECIDER
    return string.format("pause %.1f s: %s; who: %s; project: %s", d.pause,
        rounded(d.state, spec.outputs.p_state), rounded(d.who, spec.outputs.p_who),
        rounded(d.project, spec.outputs.p_project))
end

return decider
