--- bragi/quick.lua: quick answers with Haiku.
--
-- Simple questions don't wait for the main model, and the main session's
-- model is never switched for them: each model has its own prompt cache,
-- so a switch makes the new one read the whole conversation again,
-- uncached. Every message gets a route:
--
--   quick  answerable by reading alone: the time or date, the branch, what
--          a file or the wiki says, where something is mentioned, a
--          board's status
--   main   anything that writes, edits, runs scripts or builds, takes
--          several steps, or needs judgment about the code
--   recap  how the conversations Bragi follows are doing, in any words
--          ("catch me up"): bragi/recap.lua answers from the app's own
--          state
--   command  run a Claude Code slash command in the conversation shown, in
--          any words ("compact this conversation"), with the command line
--          the screening gives: bragi/slash.lua runs it
--
-- Spoken messages get theirs from the pre-pass filter (heard-text.md's
-- `route`). Typed ones ask the router (prompts/route.md), a lean helper of
-- their own: its whole answer is a few words of JSON, so it's quicker than
-- the filter (which writes the message back out), and it never waits behind
-- a spoken message. Meanwhile the answerer already works on it, so a quick
-- one waits for the slower of the two, not both in turn; when the router
-- says main, that answer is dropped (or the answerer stopped). Some are
-- main without asking (localRoute): with
-- bragi.quickAnswers off, "ask Opus" (or the other models) and "think hard",
-- slash commands, code, and anything over ROUTE_MAX_WORDS words.
--
-- A quick message goes to the answerer (prompts/quick-answer.md): Haiku 5.5
-- in the open repository, kept warm (started and pinged when the Agent view
-- opens and when the mic turns on, pinged again after KEEP_WARM_MS idle
-- while either is in use), given a digest instead of the conversation (the
-- time, the repository and branch, the last few exchanges, files mentioned
-- lately) and read-only tools: Read, Grep, Glob, and the app's repo tools
-- (status, diff, log, show, branches). Only those are allowed: anything
-- else that asks (an edit, a command, computer use) is denied here,
-- whatever the prompt says. It answers, or hands back ("HANDOFF: why")
-- when it can't answer confidently or the question needs real work; then
-- the message goes to the agent as usual, and the transcript says
-- "Passing that to Opus" (the main model's name). The agent working on a
-- turn doesn't hold a quick question up.
--
-- An answer shows in the conversation as it comes, tagged "Answered by
-- Haiku", and the next message the agent gets carries it as a short note
-- (bragi/agent.lua: "Meanwhile, Haiku answered: ..."), which keeps the
-- agent's prompt cache intact. A spoken one is retold and spoken like any
-- reply ("bragi.reply" with voice); a typed one is published too (without
-- voice, with the conversation it was asked in), for bragi/voice.lua to
-- tell when that conversation is on screen.
--
-- Routes, answers, and hand-offs go to voice-log.txt: "route" (route, why,
-- by app, filter, or router, ms) and "quick" (ms, helper time, tools used,
-- handoff and why, or the answer).
--
-- Public API: quick.enabled(), quick.forced(text), quick.direct(text),
-- quick.route(text, done),
-- quick.decide(text, route, why, id, kind), quick.ask(question, opts),
-- quick.digest(), quick.warm(), quick.keepWarm(), quick.mainName()

local agent = require("bragi.agent")
local app = require("core.app")
local helpers = require("bragi.helpers")
local repo = require("core.repo")
local settings = require("core.settings")
local text = require("core.text")

local quick = { name = "bragi.quick" }

local ROUTE_MAX_WORDS = 40       -- longer messages go to the main model without asking
local SPECULATE = true           -- a typed question goes to the answerer while the router decides
local DISCARD_GRACE_MS = 4000    -- a dropped question still running this long is stopped
local QUICK_TURNS = 12           -- questions before the answerer starts afresh (tool results pile up)
local WARM_DELAY_MS = 1500       -- after the Agent view opens, before the helpers start
local KEEP_WARM_MS = 240000      -- idle this long while in use: a ping (the prompt cache lasts 5 min)
local KEEP_WARM_TICK_MS = 30000
local KEEP_ACTIVE_MS = 1800000   -- the Agent view counts as in use this long after the last message
local DIGEST_EXCHANGES = 3
local DIGEST_CHARS = 600
local DIGEST_FILES = 10

-- The tools the answerer may use: reading only.
local READ_ONLY = {
    Read = true, Grep = true, Glob = true, LS = true, NotebookRead = true,
    mcp__repo__status = true, mcp__repo__diff = true, mcp__repo__log = true, mcp__repo__show = true,
    mcp__repo__branches = true, mcp__repo__p4_changes = true,
    mcp__repo__bragi_wiki_list = true, mcp__repo__bragi_wiki_read = true, mcp__repo__bragi_wiki_search = true,
}

-- Saying one of these sends the message to the main model.
local FORCE = { "ask opus", "ask fable", "ask sonnet", "think hard" }

local ROUTE_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object with `message` and `recent`.
Answer each with exactly one JSON object as described under "You return",
and nothing else: no prose, no code fences, no tools.]]

local QUICK_FORMAT = [[

## How the app talks to you

Each message you get is one JSON object with `question` and `digest`, and
sometimes `context`: what {user} said just before the question, heard by
voice, when the question refers back to it. Answer with the answer itself, as short Markdown, or with `HANDOFF: ` and
a few words why.]]

local lastActive = nil      -- gitgud.now() of the last sign the Agent view is in use

local function repoPath()
    return repo.state().path or ""
end

--- Whether the answerer may run a tool: reading only.
local function allowTool(tool)
    if READ_ONLY[tool] then
        return true
    end
    return false, "Quick answers can only read. Answer HANDOFF if this needs " .. tostring(tool) .. "."
end

--- Whether quick answers are on (Settings, Claude: bragi.quickAnswers).
function quick.enabled()
    return settings.get("bragi.quickAnswers", true) ~= false
end

local router = helpers.new({ prefix = "bragi-route", file = "route.md", format = ROUTE_FORMAT,
    wanted = quick.enabled })
local answerer = helpers.new({ prefix = "bragi-quick", file = "quick-answer.md", format = QUICK_FORMAT,
    tools = "Read,Grep,Glob", mcp = true, uiTools = true, cwd = repoPath, allow = allowTool, turns = QUICK_TURNS,
    wanted = quick.enabled })
local ALL = { router, answerer }

--- The main model's short name: "Opus" for "Opus 5.5".
function quick.mainName()
    local label = agent.choiceLabel(agent.MODELS, "bragi.model", "opus")
    return label:match("^(%S+)") or label
end

--- Whether a message asks for the main model ("ask Opus", "think hard").
function quick.forced(s)
    local lower = " " .. tostring(s or ""):lower():gsub("%s+", " ") .. " "
    for _, phrase in ipairs(FORCE) do
        if lower:find(phrase, 1, true) then
            return true
        end
    end
    return lower:find("ask " .. quick.mainName():lower(), 1, true) ~= nil
end

--- The route decided without asking a model: "main" and why, or nil.
local function localRoute(s)
    if not quick.enabled() then
        return "main", "quick answers are off"
    elseif quick.forced(s) then
        return "main", "asked for " .. quick.mainName()
    elseif s:match("^%s*/") then
        return "main", "a slash command"
    elseif s:find("```", 1, true) then
        return "main", "it has code"
    end
    local count = 0
    for _ in s:gmatch("%S+") do
        count = count + 1
    end
    if count > ROUTE_MAX_WORDS then
        return "main", "long"
    end
    return nil
end

local function logRoute(fields)
    helpers.log("route", fields)
end

--- The agent's last words in the shown conversation, for the router.
local function lastAgentText()
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == "assistant" and (items[i].text or "") ~= "" then
            return items[i].text:sub(-DIGEST_CHARS)
        end
    end
    return ""
end

--- A typed message's route when it needs no model: "main" (logged), or nil
-- (ask quick.route).
function quick.direct(s)
    lastActive = gitgud.now()
    local route, why = localRoute(s)
    if route then
        logRoute({ text = s, route = route, why = why, by = "app" })
    end
    return route
end

--- A spoken message's route, from the filter's answer (route, why, kind),
-- unless the app decides it first: a remark (a greeting, thinking aloud) is
-- for the agent whatever the route. Logged. Returns "quick", "recap",
-- "command" (the filter's `command` says which), or "main".
function quick.decide(s, route, why, id, kind)
    lastActive = gitgud.now()
    local r, w = localRoute(s)
    local by = "app"
    if route == "command" and (not r or w == "quick answers are off") then
        -- A slash command for the conversation shown (bragi/slash.lua):
        -- not a quick answer either.
        r, w, by = "command", why, "filter"
    elseif route == "recap" and (not r or w == "quick answers are off") then
        -- How the conversations Bragi follows are doing (bragi/recap.lua):
        -- not a quick answer, so not turned off with them.
        r, w, by = "recap", why, "filter"
    elseif not r and kind == "remark" then
        r, w = "main", "a remark, not a question"
    elseif not r then
        r = route == "quick" and "quick" or "main"
        w = why or (route == nil and "the filter gave no route" or nil)
        by = "filter"
    end
    logRoute({ id = id, text = s, route = r, why = w, by = by })
    return r
end

-- ===================================================================
-- The digest: what the answerer knows instead of the conversation
-- ===================================================================

local function cut(s, max)
    s = text.trim(tostring(s or ""))
    if #s > max then
        s = s:sub(1, max) .. "..."
    end
    return s
end

--- What the answerer is told about where the user is: the time, the
-- repository, the last few exchanges, files mentioned lately, and whether
-- the agent is working.
function quick.digest()
    local state = repo.state()
    local items = agent.items()
    -- The last few exchanges: a message of yours and what the agent wrote
    -- back (quick answers included).
    local exchanges = {}
    local currentEx = nil
    for _, item in ipairs(items) do
        if item.kind == "user" then
            currentEx = { you = cut(item.text, DIGEST_CHARS), agent = "" }
            exchanges[#exchanges + 1] = currentEx
        elseif item.kind == "assistant" and currentEx and (item.text or "") ~= "" then
            local said = currentEx.agent ~= "" and (currentEx.agent .. "\n") or ""
            currentEx.agent = said .. item.text
            if item.tag then
                currentEx.by = "Haiku"
            end
        end
    end
    local recent = {}
    for i = math.max(1, #exchanges - DIGEST_EXCHANGES + 1), #exchanges do
        local ex = exchanges[i]
        local agentText = ex.agent
        if #agentText > DIGEST_CHARS then
            agentText = "..." .. agentText:sub(-DIGEST_CHARS)
        end
        recent[#recent + 1] = { you = ex.you, agent = agentText, by = ex.by }
    end
    -- Files mentioned lately: what the agent's tools touched, newest first,
    -- then `names.ext` in what was said.
    local files, seen = {}, {}
    local function add(path)
        path = tostring(path or "")
        if path ~= "" and not seen[path] and #files < DIGEST_FILES then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    for i = #items, 1, -1 do
        local item = items[i]
        if item.kind == "step" and item.inputText then
            local input = gitgud.jsonDecode(item.inputText)
            if type(input) == "table" then
                add(input.file_path or input.notebook_path or input.path)
            end
        elseif (item.kind == "user" or item.kind == "assistant") and item.text then
            for name in item.text:gmatch("`([^`\n]+%.%w+)`") do
                add(name)
            end
        end
    end
    local changed = {}
    for _, f in ipairs(state.files or {}) do
        if #changed < DIGEST_FILES then
            changed[#changed + 1] = f.path
        end
    end
    return {
        time = os.date("%A %d %B %Y, %H:%M"),
        repository = state.open and {
            name = state.name,
            folder = state.path,
            branch = state.branch ~= "" and state.branch or "(detached)",
            changed = changed,
        } or nil,
        recent = recent,
        files = files,
        working = agent.session().turn == true,
    }
end

-- ===================================================================
-- Asking
-- ===================================================================

-- A question on its way through the answerer: { question, started, job,
-- done, reply, err, opts (once someone waits for it), discarded }. Typed
-- questions start there side by side with the router (SPECULATE), so a
-- quick one doesn't wait for both in turn; the router's "main" discards it.
local asked = {}

--- An answer is in and someone waits for it: show it, or hand back.
local function finish(a)
    local opts = a.opts
    local item = opts.pending
    local answer = text.trim(a.reply or "")
    local why = answer:match("^HANDOFF:?%s*(.*)$")
    if not a.reply then
        why = "it failed: " .. tostring(a.err)
    elseif answer == "" then
        why = "no answer"
    end
    local job = a.job
    local fields = { id = opts.id, question = a.question, ms = gitgud.now() - a.started, helperMs = job and job.ms,
        cold = job and job.cold == true, tools = job and #job.tools > 0 and job.tools or nil,
        voice = opts.voice == true, early = a.early }
    if why then
        fields.handoff = true
        fields.why = why ~= "" and why or nil
        helpers.log("quick", fields)
        local line = "Passing that to " .. quick.mainName() .. "."
        agent.quickHandoff(item, line)
        if opts.onHandoff then
            opts.onHandoff(line, why)
        else
            agent.send(a.question, { pending = item })
        end
        return
    end
    fields.answer = cut(answer, 300)
    helpers.log("quick", fields)
    agent.quickAnswered(item, a.question, answer)
    app.publish("bragi.reply", { text = answer, voice = opts.voice == true, quick = true,
        ms = gitgud.now() - a.started, tab = a.tab })
end

local function forget(a)
    for i, x in ipairs(asked) do
        if x == a then
            table.remove(asked, i)
            return
        end
    end
end

local function logDiscarded(a)
    local job = a.job
    helpers.log("quick", { question = a.question, discarded = true, helperMs = job and job.ms,
        tools = job and job.tools and #job.tools > 0 and job.tools or nil })
end

--- Send a question to the answerer. Its answer is shown once someone
-- waits for it (a.opts), now or later (quick.ask).
local function askAnswerer(a)
    asked[#asked + 1] = a
    local payload = { question = a.question, digest = quick.digest() }
    if (a.context or "") ~= "" then
        payload.context = a.context
    end
    a.job = helpers.ask(answerer, payload, function(reply, err, job)
        a.done, a.reply, a.err, a.job = true, reply, err, job
        if a.opts then
            forget(a)
            finish(a)
        elseif a.discarded then
            forget(a)
            logDiscarded(a)
            if a.restart and not answerer.busy and #answerer.queue == 0 then
                helpers.stop(answerer)
                helpers.warm(answerer)
            end
        end
    end)
end

--- Ask the router for a typed message's route: done(route, why, command)
-- once it answers ("main" when it fails; the command line with `command`).
-- The answerer starts on it meanwhile.
function quick.route(s, done)
    lastActive = gitgud.now()
    local started = gitgud.now()
    local a = nil
    if SPECULATE then
        a = { question = s, started = started, early = true }
        askAnswerer(a)
    end
    helpers.ask(router, { message = s, recent = lastAgentText() }, function(reply, err)
        local answer = nil
        local first = type(reply) == "string" and reply:find("{", 1, true)
        local last = type(reply) == "string" and reply:match(".*()}")
        if first and last then
            answer = gitgud.jsonDecode(reply:sub(first, last))
        end
        local r = type(answer) == "table" and (answer.route == "quick" or answer.route == "recap"
            or (answer.route == "command" and type(answer.command) == "string")) and answer.route or "main"
        local w = type(answer) == "table" and answer.why or (err or "the router's answer wasn't JSON")
        logRoute({ text = s, route = r, why = w, by = "router", ms = gitgud.now() - started })
        if a and r ~= "quick" and not a.opts then
            -- Not for Haiku after all: its answer is dropped. It usually
            -- hands back at once; one still busy after DISCARD_GRACE_MS is
            -- stopped, and the answerer starts afresh (an interrupted
            -- question would stay open in its conversation).
            a.discarded = true
            if a.done then
                forget(a)
                logDiscarded(a)
            else
                gitgud.after(DISCARD_GRACE_MS, function()
                    if not a.done then
                        a.restart = true
                        helpers.cancel(answerer, a.job)
                    end
                end)
            end
        end
        done(r, w, r == "command" and answer.command or nil)
    end)
end

--- Ask the answerer. The message is already in the conversation (opts.pending,
-- from agent.voicePending): its answer goes under it, tagged; a hand-off
-- says so and calls opts.onHandoff(line, why) to send it on (without one,
-- agent.send).
-- @param question  the message (typed, or spoken and checked)
-- @param opts      pending (its item), voice (it was spoken: the answer is
--                  spoken too), id (the voice message's id, for the log),
--                  onHandoff, context (what the user said just before, from the
--                  voice lookback: the answerer gets it with the question)
function quick.ask(question, opts)
    lastActive = gitgud.now()
    agent.waitingTitle("Asking Haiku")
    local context = opts and opts.context or ""
    -- Already on its way (quick.route started it)?
    for _, a in ipairs(asked) do
        if a.question == question and not a.opts and not a.discarded and context == "" then
            a.opts = opts or {}
            if a.done then
                forget(a)
                finish(a)
            end
            return
        end
    end
    askAnswerer({ question = question, context = context, started = gitgud.now(), opts = opts or {},
        tab = agent.current() })
end

-- ===================================================================
-- Warm
-- ===================================================================

--- Start the router and the answerer and ping them (the Agent view
-- opened, or the mic turned on).
function quick.warm()
    lastActive = gitgud.now()
    if quick.enabled() then
        for _, h in ipairs(ALL) do
            helpers.warm(h)
        end
    end
end

--- Ping the router and the answerer when idle for KEEP_WARM_MS.
function quick.keepWarm()
    if quick.enabled() then
        helpers.keepWarm(ALL, KEEP_WARM_MS)
    end
end

local function tick()
    if not quick.enabled() then
        for _, h in ipairs(ALL) do
            if helpers.idle(h) > 0 then
                helpers.stop(h)
            end
        end
        return
    end
    local shell = require("bragi.shell")
    if shell.view() == "agent" and lastActive and gitgud.now() - lastActive < KEEP_ACTIVE_MS then
        quick.keepWarm()
    end
end

--- The Agent view opened: warm the helpers a moment later, not in the way
-- of start-up (and a test script has set its program by then).
local function agentShown()
    lastActive = gitgud.now()
    gitgud.after(WARM_DELAY_MS, function()
        if require("bragi.shell").view() == "agent" then
            quick.warm()
        end
    end)
end

function quick.init()
    helpers.init()
    app.subscribe("bragi.view", function(view)
        if view == "agent" then
            agentShown()
        end
    end)
    if require("bragi.shell").view() == "agent" then
        agentShown() -- the app started in it
    end
    gitgud.every(KEEP_WARM_TICK_MS, tick)
end

function quick.refresh()
end

return quick
