--- bragi/slash.lua: running a Claude Code slash command in a conversation
-- without typing it ("compact this conversation" by voice,
-- in the master or for another conversation it manages).
--
-- Two ways in:
--   - the master's tool, bragi_slash_command (bragi/master.lua), on itself
--     or on another conversation by id;
--   - the first-layer screening (prompts/route.md for typed messages,
--     prompts/heard-text.md for spoken ones) giving the route `command`
--     with the command line, for the conversation shown (bragi/agent.lua,
--     bragi/voice.lua). Never by keywords in code.
--
-- A command goes to Claude Code as typed ("/compact keep the plan"), alone.
-- One for a conversation mid-turn (or waiting on a permission or a
-- question) waits until its turn is over: a command sent mid-turn would be
-- taken as a message at its next step, and one the master runs on itself
-- comes from inside its own turn (the tool call), which has to finish
-- first. One waiting command per conversation; a closed conversation's is
-- dropped.
--
-- Only Claude Code's own commands (the session's list, when it has one).
-- The ones the app runs itself (/clear, /model, /help and the like:
-- agent.isAppCommand) are refused here: the app's screens and the settings
-- tool do those.
--
-- Public API: slash.parse(line), slash.check(name), slash.prepare(tab,
-- line), slash.run(tab, line, opts), slash.waiting(tab),
-- slash.answer(pending, question, line, opts)

local agent = require("bragi.agent")
local text = require("core.text")

local slash = { name = "bragi.slash" }

local POLL_MS = 200      -- how often a waiting command looks for its turn's end
local LISTED = 30        -- commands named when one isn't known

local queue = {}         -- { tab, line, opts }: commands waiting for a turn's end
local timer = nil

--- A command line's name and arguments ("/compact keep it" -> "compact",
-- "keep it"; the slash is optional), or nil.
function slash.parse(line)
    line = text.trim(tostring(line or ""))
    local name, args = line:match("^/?([%w][%w%-_:%.]*)%s*(.-)$")
    if not name then
        return nil
    end
    return name:lower(), text.trim(args)
end

--- Why a command can't run this way, or nil when it can.
-- @param name  the command without its slash
function slash.check(name)
    if agent.isAppCommand(name) then
        if name == "clear" or name == "new" then
            return "/" .. name .. " starts a new conversation; that's the New button, not a command to run here."
        elseif name == "model" or name == "effort" then
            return "/" .. name .. " is changed with bragi_settings_set (model, effort), not run as a command."
        end
        return "/" .. name .. " opens one of the app's screens; it isn't run as a command."
    end
    local known = {}
    for _, n in ipairs(agent.slashCommands()) do
        if not agent.isAppCommand(n) then
            known[#known + 1] = n
        end
    end
    -- Before any session has started there's no list: Claude Code says.
    if #known == 0 then
        return nil
    end
    for _, n in ipairs(known) do
        if n == name then
            return nil
        end
    end
    while #known > LISTED do
        table.remove(known)
    end
    return "There's no /" .. name .. " command. These are: /" .. table.concat(known, ", /") .. "."
end

local function live(tab)
    for _, t in ipairs(agent.tabs()) do
        if t == tab then
            return true
        end
    end
    return false
end

--- Whether a conversation is mid-turn (or waits on a permission or a
-- question, which keeps its turn open).
local function busy(tab)
    return tab.session and tab.session.turn == true
end

local function send(entry)
    local ok, err = agent.sendTo(entry.tab, entry.line)
    if entry.opts.onSent then
        entry.opts.onSent(ok, err)
    end
    if not ok then
        agent.noteIn(entry.tab, "Couldn't run " .. entry.line .. ": " .. tostring(err), { error = true })
    end
end

--- Send the waiting commands whose conversation's turn is over.
local function poll()
    local keep = {}
    for _, entry in ipairs(queue) do
        if not live(entry.tab) then
            -- Closed: nothing to run it in.
        elseif busy(entry.tab) then
            keep[#keep + 1] = entry
        else
            send(entry)
        end
    end
    queue = keep
    if #queue == 0 and timer then
        gitgud.cancelTimer(timer)
        timer = nil
    end
end

--- The command waiting for a conversation's turn to end, or nil.
function slash.waiting(tab)
    for _, entry in ipairs(queue) do
        if entry.tab == tab then
            return entry.line
        end
    end
    return nil
end

--- A command as it would be sent to a conversation ("/compact keep it"),
-- or nil and why it can't be.
function slash.prepare(tab, line)
    local name, args = slash.parse(line)
    if not name then
        return nil, "Which command? Give it like /compact."
    end
    local why = slash.check(name)
    if why then
        return nil, why
    end
    local already = slash.waiting(tab)
    if already then
        return nil, already .. " is already waiting to run there when its turn is over."
    end
    return "/" .. name .. (args ~= "" and (" " .. args) or "")
end

--- Run a command in a conversation: now when it's idle, else once its
-- turn is over.
-- @param tab   the conversation
-- @param line  the command ("/compact", "compact keep the plan")
-- @param opts  optional: wait (wait for the turn's end even if none runs
--              yet: the master's own, from its tool call), onSent(ok, err)
-- @return "now" or "queued" and the command as sent, or nil and why not
function slash.run(tab, line, opts)
    opts = opts or {}
    local command, why = slash.prepare(tab, line)
    if not command then
        return nil, why
    end
    local entry = { tab = tab, line = command, opts = opts }
    if not opts.wait and not busy(tab) then
        send(entry)
        return "now", command
    end
    queue[#queue + 1] = entry
    if not timer then
        timer = gitgud.every(POLL_MS, poll)
    end
    return "queued", command
end

--- The screening called a message a command (route `command`): run it in
-- the shown conversation, with a quiet row under the message. False when
-- it can't be one (unknown, or one the app runs itself): the caller sends
-- the message on the usual way.
-- @param pending   the message's item (agent.voicePending)
-- @param question  the message as asked
-- @param line      the command the screening gave
-- @param opts      optional: onRun(words) (a spoken one: say them)
function slash.answer(pending, question, line, opts)
    opts = opts or {}
    local log = require("bragi.helpers").log
    local tab = pending and pending.pending or agent.current()
    local command, why = slash.prepare(tab, line)
    if not command then
        log("command", { text = question, command = line, refused = why })
        return false
    end
    -- The row first: the command's own message and output go under it.
    local said = busy(tab) and ("Running " .. command .. " once this turn is done.")
        or ("Running " .. command .. ".")
    agent.pendingNoted(pending, question, said)
    local how = slash.run(tab, command)
    log("command", { text = question, command = command, how = how })
    if opts.onRun then
        opts.onRun(said)
    end
    return true
end

return slash
