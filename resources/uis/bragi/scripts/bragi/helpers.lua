--- bragi/helpers.lua: the app's own Haiku 5.5 sessions.
--
-- Every helper is Haiku 5.5 by explicit id (bragi.helperModel), a lean
-- session (gitgud.agentStart's lean: its own short system prompt from
-- prompts/<file>, nothing else loaded, no transcript saved), fresh after
-- `turns` calls (its context only grows). Each answers one call at a time,
-- in order; each job has a helper of its own, so none waits behind
-- another. Starting one isn't enough to make its first call quick: warm()
-- starts it and pings it (`{"ping": true}`, answered "ok"), and
-- keepWarm() pings one idle for a while (its prompt cache lasts 5 min).
--
-- Most helpers have no tools. One may be given some (`tools`, built-in
-- tools by name; `mcp`, the app's own MCP tools) and a folder to work in
-- (`cwd`, a function: when it changes, the helper starts afresh there).
-- Whatever asks for a permission goes through `allow(tool, input)`; a
-- helper without it is denied everything.
--
-- Each call is logged as a "helper" line (helpers.log, voice-log.txt) with
-- its time, whether the helper was cold, and the tools it used.
--
-- Public API: helpers.new(spec), helpers.ask(h, payload, done, opts),
-- helpers.cancel(h, job), helpers.ping(h), helpers.warm(h), helpers.keepWarm(list, idleMs),
-- helpers.stop(h), helpers.idle(h), helpers.init()

local settings = require("core.settings")

local helpers = {}

helpers.MODEL = "claude-haiku-5-5"

--- Where helper lines go (bragi/voice.lua sets it: voice-log.txt).
helpers.log = function()
end

-- Every helper: the warm-up call.
local PING_FORMAT = [[

A message that is only `{"ping": true}` warms you up: answer `ok`.]]

local TURNS = 15            -- calls before a helper starts afresh

local byName = {}           -- session name -> helper
local inited = false

--- The helper's system prompt: prompts/<file> (read once) and its format,
-- with the user's name filled in each time (bragi/user.lua), so a new name
-- starts the helper afresh.
local function readPrompt(h)
    if not h.prompt then
        for _, root in ipairs(require("bragi.customize").roots()) do
            local f = root and io.open(root .. "/prompts/" .. h.file, "rb")
            if f then
                h.prompt = f:read("a") .. h.format
                f:close()
                break
            end
        end
    end
    return h.prompt and require("bragi.user").fill(h.prompt) or nil
end

--- Take up a helper's session still running from before a hot-reload
--: its newest one, warm, when it runs the same prompt
-- and model; the rest end. A call it was answering is taken as a ping
-- (whoever asked went with the reload).
local function adopt(h)
    local pattern = "^" .. h.prefix:gsub("%p", "%%%0") .. "(%d+)$"
    local best, bestN = nil, -1
    for _, info in ipairs(gitgud.agentList()) do
        local n = tonumber(info.name:match(pattern))
        if n then
            h.count = math.max(h.count, n)
            if info.running and n > bestN then
                if best then
                    gitgud.agentStop(best.name)
                end
                best, bestN = info, n
            elseif info.running then
                gitgud.agentStop(info.name)
            end
        end
    end
    if not best then
        return
    end
    if best.options.systemPrompt ~= readPrompt(h)
        or best.options.model ~= settings.get("bragi.helperModel", helpers.MODEL) then
        gitgud.agentStop(best.name) -- a new prompt: the next call starts afresh
        return
    end
    h.session = best.name
    h.startedIn = h.cwd and best.options.cwd or ""
    h.used = 0
    h.fresh = false
    h.lastUsed = gitgud.now()
    if best.turnActive then
        h.busy = { payload = "", done = function()
        end, ping = true, tools = {}, sent = gitgud.now() }
    end
    byName[best.name] = h
end

--- A helper (not started yet, unless it's taken up from before a
-- hot-reload).
-- @param spec  { prefix (its sessions' names), file (prompts/<file>),
--              format (how the app talks to it, after the prompt),
--              turns, tools ("Read,Grep,Glob"), mcp (the app's MCP tools),
--              uiTools (and the UI's own, bragi/uitools.lua),
--              cwd = fn() -> folder, allow = fn(tool, input) -> ok, why,
--              wanted = fn() -> whether to start afresh after `turns` }
function helpers.new(spec)
    local h = { count = 0, used = 0, queue = {} }
    for k, v in pairs(spec) do
        h[k] = v
    end
    h.format = (h.format or "") .. PING_FORMAT
    h.turns = h.turns or TURNS
    adopt(h)
    return h
end

--- Start a helper's session. True, or nil and why not.
function helpers.start(h)
    local prompt = readPrompt(h)
    if not prompt then
        return nil, "prompts/" .. h.file .. " is missing"
    end
    h.count = h.count + 1
    local name = h.prefix .. h.count
    local cwd = h.cwd and h.cwd() or ""
    -- Lean: the prompt replaces Claude Code's own, nothing else loads, and
    -- it runs in an empty folder (no project, no CLAUDE.md) unless given one.
    local options = {
        program = require("bragi.claude").program(),
        model = settings.get("bragi.helperModel", helpers.MODEL),
        permissionMode = "default",
        systemPrompt = prompt,
        lean = true,
        tools = h.tools,
        cwd = cwd ~= "" and cwd or nil,
        persist = false, -- no transcript: kept out of the sessions list
        uiTools = h.uiTools, -- the UI's tools too (bragi/uitools.lua), for those that read the wikis
    }
    if not h.mcp then
        options.mcpConfig = false
    end
    local ok, err = gitgud.agentStart(name, options)
    if not ok then
        return nil, err
    end
    h.session = name
    h.startedIn = cwd
    h.used = 0
    h.fresh = true
    h.lastUsed = gitgud.now()
    byName[name] = h
    return true
end

--- End a helper's session (its exit is ignored).
function helpers.stop(h)
    if h.session then
        byName[h.session] = nil
        gitgud.agentStop(h.session)
        h.session = nil
    end
end

local function pump(h)
    while not h.busy and #h.queue > 0 do
        local job = table.remove(h.queue, 1)
        local ok, err = true, nil
        if h.session and h.cwd and h.startedIn ~= h.cwd() then
            helpers.stop(h) -- its folder changed: start afresh there
        end
        if not h.session then
            ok, err = helpers.start(h)
        end
        if ok then
            job.sent = gitgud.now()
            job.cold = h.fresh
            h.fresh = false
            ok, err = gitgud.agentSend(h.session, job.payload)
        end
        if ok then
            h.busy = job
        else
            job.done(nil, err, job)
        end
    end
end

--- Ask a helper; done(reply, nil, job) or done(nil, err, job) is called
-- once (not at all for a call dropped as stale). job has ms, cold, and
-- tools (the names of the tools it used).
-- @param payload  a table, sent as JSON
-- @param opts     optional: latest (drop the calls still waiting: they're
--                 stale), ping (a warm-up call)
-- @return the job (for helpers.cancel)
function helpers.ask(h, payload, done, opts)
    opts = opts or {}
    if opts.latest then
        h.queue = {}
    end
    local job = { payload = gitgud.jsonEncode(payload), done = done, ping = opts.ping, tools = {} }
    h.queue[#h.queue + 1] = job
    pump(h)
    return job
end

--- Call a job off: one still waiting is dropped (done(nil, "cancelled")),
-- one running is interrupted (its done follows with what came of it).
function helpers.cancel(h, job)
    for i, j in ipairs(h.queue) do
        if j == job then
            table.remove(h.queue, i)
            job.done(nil, "cancelled", job)
            return
        end
    end
    if h.busy == job and h.session then
        gitgud.agentInterrupt(h.session)
    end
end

--- A tiny real call, so the model is loaded and the helper's next call is
-- warm (starting the process alone isn't enough).
function helpers.ping(h)
    helpers.ask(h, { ping = true }, function()
    end, { ping = true })
end

--- Start a helper that isn't running and ping it. True when it started.
function helpers.warm(h)
    if not h.session and readPrompt(h) and helpers.start(h) then
        helpers.ping(h)
        return true
    end
    return false
end

--- Milliseconds since a helper last answered (0 while it works or waits).
function helpers.idle(h)
    if h.busy or #h.queue > 0 then
        return 0
    end
    return gitgud.now() - (h.lastUsed or gitgud.now())
end

--- Ping every running helper in `list` idle for `idleMs` or more.
function helpers.keepWarm(list, idleMs)
    for _, h in ipairs(list) do
        if h.session and helpers.idle(h) >= idleMs then
            helpers.ping(h)
        end
    end
end

local function onEvent(kind)
    return function(detail)
        local e = gitgud.jsonDecode(detail)
        local h = type(e) == "table" and byName[e.session]
        if not h then
            return
        end
        if kind == "permission" then
            local ok, why = false, "Answer with the text only."
            if h.allow then
                ok, why = h.allow(e.tool, e.input)
            end
            helpers.log("helper-tool", { helper = h.prefix, tool = e.tool, allowed = ok == true })
            gitgud.agentRespond(e.session, e.requestId, ok == true, not ok and why or nil)
            return
        elseif kind == "tool" then
            if h.busy and (e.parent or "") == "" then
                h.busy.tools[#h.busy.tools + 1] = e.name
            end
            return
        end
        local job = h.busy
        h.busy = nil
        if job then
            job.ms = gitgud.now() - job.sent
            helpers.log("helper", { helper = h.prefix, ms = job.ms, cold = job.cold == true,
                ok = kind ~= "exit" and not e.isError, ping = job.ping, tools = #job.tools > 0 and job.tools or nil })
        end
        h.lastUsed = gitgud.now()
        if kind == "exit" then
            byName[e.session] = nil
            h.session = nil
            if job then
                job.done(nil, "it stopped (exit code " .. tostring(e.code) .. ")", job)
            end
        else
            h.used = h.used + 1
            if h.used >= h.turns then
                -- Its context only grows: start afresh, warm for the next call.
                helpers.stop(h)
                if (not h.wanted or h.wanted()) and helpers.start(h) then
                    helpers.ping(h)
                end
            end
            if job then
                if e.isError then
                    job.done(nil, (e.text or "") ~= "" and e.text or "it failed", job)
                else
                    job.done(e.text or "", nil, job)
                end
            end
        end
        pump(h)
    end
end

--- Listen for the helpers' events (once).
function helpers.init()
    if inited then
        return
    end
    inited = true
    for _, kind in ipairs({ "result", "permission", "exit", "tool" }) do
        gitgud.on("agent." .. kind, onEvent(kind))
    end
    -- Once every module has made its helpers: a helper session from before
    -- a hot-reload that none took up (lean ones are only ever helpers) ends.
    gitgud.after(0, function()
        for _, info in ipairs(gitgud.agentList()) do
            if info.running and info.options.lean and not byName[info.name] then
                gitgud.agentStop(info.name)
            end
        end
    end)
end

return helpers
