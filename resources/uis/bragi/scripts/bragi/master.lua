--- bragi/master.lua: Bragi, the master conversation: one
-- conversation outside every project, pinned at the top of the Agent
-- view's list, for controlling everything. Say what you want done and
-- where; it finds the project and the conversation (or starts one, or
-- clones the project from an address you give), sends a cleaned-up request,
-- and tells you what it did. It acts, then tells: no confirmation step.
--
-- It's a Claude Code session like the others, in a folder of its own
-- (projects.masterDir(), made on demand), named "bragi-master", told
-- prompts/master.md after the main session's prompt. Its id is
-- remembered (bragi.masterSession), so it resumes across restarts. Its
-- Git and P4 tools act on the open repository (repository = false).
--
-- Its tools (UI tools kept to its session, bragi/uitools.lua) are allowed
-- without asking: listed in its folder's .claude/settings.local.json, and
-- granted by the app if Claude Code asks anyway (tab.allowTool).
--   bragi_projects           the projects on this machine
--   bragi_conversations      conversations, optionally of one project
--   bragi_read_conversation  the last few exchanges of one, capped
--   bragi_send               a message to a conversation (resumed if saved);
--                            one waiting on a card takes it as the answer
--   bragi_start              a new conversation in a project
--   bragi_clone              a repository, by its address, into the projects folder
--   bragi_open_project       a project as the Repo view's repository (a local
--                            repository folder by path, added to the projects)
--   bragi_restart_app        the app itself, closed and started again
--   bragi_slash_command      a Claude Code command (/compact) here or in
--                            another conversation (bragi/slash.lua)
--
-- A command run here ("compact this conversation" by
-- voice) comes from inside this conversation's own turn, the tool call:
-- it waits until that turn is over, then goes as if typed. One for a
-- conversation mid-turn waits for its turn's end the same way.
--
-- Restarting ("restart yourself" by voice after an
-- update): the call answers first, then once Claude Code has the answer
-- (its result shows here) the app closes the way closing its window does
-- (voice shut down properly) and starts again, the same build with the
-- same data (gitgud.restartApp). The new start reopens this conversation
-- with a quiet note, turns voice back on if it was listening, and says
-- "I'm back" when the restart was asked for by voice. It won't stop
-- other conversations' work unasked: with any mid-turn or waiting, or
-- background tasks running (this one's too), it says which and restarts
-- only when called again with force.
--
-- Conversations it sent something to report back as quiet rows in it
-- (notes, never spoken, never a model turn), with Open: done (and how many
-- files changed), stopped with an error, needs a permission, has a
-- question. Done only once its background tasks are over too ("Done once
-- the work is", below).
--
-- With no repository open, the Agent view starts in it, and New opens it
-- (agent.newFromButton): there's no folder to start anywhere else, and
-- it's the one that finds or clones projects.
--
-- Public API: master.open(), master.tab(), master.SESSION, master.TOOLS,
-- master.definitions(), master.handle(call, reply) (for tests),
-- master.follow(tab), master.followed(tab), master.followsId(id),
-- master.followedTabs(), master.followedSaved(), master.describe(tab) (for
-- bragi/recap.lua), master.holdDone(tab, unprompted), master.reloadFollows()
-- (tests), master.configure(tab),
-- master.afterRestart() (at start-up; for tests)

local agent = require("bragi.agent")
local projects = require("bragi.projects")
local settings = require("core.settings")
local text = require("core.text")

local master = { name = "bragi.master" }

master.SESSION = "bragi-master"

local MAX_READ_CHARS = 6000       -- of a conversation read back
local MAX_MESSAGE_CHARS = 1500    -- of one message in it
local MAX_EXCHANGES = 10
local READ_ENTRIES = 1000         -- transcript entries a saved conversation is read back from
local RECAP_ENTRIES = 60          -- and a followed one is recapped from (its last ask and reply)
local MAX_LISTED = 40             -- projects or conversations in a reply
local CLONE_WAIT_MS = 12000       -- before a clone's call says it goes on
local ANSWER_WAIT_MS = 10000      -- for a card's answer to be read, before the call says it goes on
local RESTART_WAIT_MS = 5000      -- for Claude Code to have a restart's answer, at most
local RESTART_SETTLE_MS = 500     -- after it has it, for its transcript
local RESTART_FRESH_SECONDS = 180 -- a restart note older than this is stale
local RESTART_KEY = "bragi.restarted"
local RESTARTED_NOTE = "The app restarted. Carry on where you left off."
local BACK_LINE = "I'm back."

local refCount = 0                -- ids for conversations not started yet

-- ===================================================================
-- The tab
-- ===================================================================

--- The master's live tab, or nil.
function master.tab()
    for _, tab in ipairs(agent.tabs()) do
        if tab.master then
            return tab
        end
    end
    return nil
end

-- The conversations Bragi started or sent work to are kept with its own
-- (bragi.masterFollows: { {id, cwd, title, at} }), so recaps and spoken
-- updates go on after a restart. The newest
-- FOLLOWS_KEPT, from the last FOLLOWS_DAYS.
local FOLLOWS_KEY = "bragi.masterFollows"
local FOLLOWS_KEPT = 30
local FOLLOWS_DAYS = 7
local ID_WAIT_MS = 1000     -- a new conversation's id comes with its start
local ID_TRIES = 120
local follows = nil         -- id -> { id, cwd, title, at }

local function loadFollows()
    if not follows then
        follows = {}
        local list = gitgud.jsonDecode(settings.get(FOLLOWS_KEY, "") or "")
        local oldest = os.time() - FOLLOWS_DAYS * 86400
        for _, f in ipairs(type(list) == "table" and list or {}) do
            if type(f) == "table" and type(f.id) == "string" and (tonumber(f.at) or 0) >= oldest then
                follows[f.id] = f
            end
        end
    end
    return follows
end

local function saveFollows()
    local list = {}
    for _, f in pairs(loadFollows()) do
        list[#list + 1] = f
    end
    table.sort(list, function(a, b)
        return (a.at or 0) > (b.at or 0)
    end)
    while #list > FOLLOWS_KEPT do
        follows[list[#list].id] = nil
        table.remove(list)
    end
    settings.set(FOLLOWS_KEY, gitgud.jsonEncode(list))
end

--- Keep a followed conversation, once Claude Code has given it an id.
local function keepFollow(tab, tries)
    local id = tab.session.id or tab.session.resume
    if not id or id == "" then
        if (tries or 0) < ID_TRIES then
            gitgud.after(ID_WAIT_MS, function()
                keepFollow(tab, (tries or 0) + 1)
            end)
        end
        return
    end
    loadFollows()[id] = { id = id, cwd = tab.cwd or "", title = tab.title or "", at = os.time() }
    saveFollows()
end

--- Bragi started this conversation or sent it work: it follows it, now and
-- after a restart.
function master.follow(tab)
    tab.bragiFollows = true
    keepFollow(tab)
end

--- Whether Bragi follows this conversation (one it followed before a
-- restart too, once it's open again).
function master.followed(tab)
    if tab.bragiFollows then
        return true
    end
    local id = tab.session and (tab.session.id or tab.session.resume)
    if not tab.master and id and loadFollows()[id] then
        tab.bragiFollows = true
        return true
    end
    return false
end

--- Whether a saved conversation (by id) is one Bragi follows.
function master.followsId(id)
    return id ~= nil and loadFollows()[id] ~= nil
end

--- Forget what was loaded (tests: the setting changed underneath).
function master.reloadFollows()
    follows = nil
end

local promptText = nil

--- prompts/master.md, read once ("" when missing).
local function prompt()
    if not promptText then
        promptText = ""
        for _, root in ipairs(require("bragi.customize").roots()) do
            local f = root and io.open(root .. "/prompts/master.md", "rb")
            if f then
                promptText = text.trim(f:read("a"))
                f:close()
                break
            end
        end
    end
    return require("bragi.user").fill(promptText)
end

master.TOOLS = { "bragi_projects", "bragi_conversations", "bragi_read_conversation", "bragi_send",
    "bragi_start", "bragi_clone", "bragi_open_project", "bragi_restart_app", "bragi_slash_command" }

local function isOwnTool(name)
    for _, tool in ipairs(master.TOOLS) do
        if name == "mcp__repo__" .. tool then
            return true
        end
    end
    return false
end

--- Its folder's Claude Code settings allow its tools (kept with whatever
-- else is there).
local function allowTools(dir)
    gitgud.makeDir(dir .. "/.claude")
    local path = dir .. "/.claude/settings.local.json"
    local current = {}
    local f = io.open(path, "rb")
    if f then
        current = gitgud.jsonDecode(f:read("a")) or {}
        f:close()
    end
    if type(current) ~= "table" then
        current = {}
    end
    current.permissions = type(current.permissions) == "table" and current.permissions or {}
    local allow, seen = {}, {}
    for _, rule in ipairs(type(current.permissions.allow) == "table" and current.permissions.allow or {}) do
        allow[#allow + 1] = rule
        seen[rule] = true
    end
    for _, tool in ipairs(master.TOOLS) do
        local rule = "mcp__repo__" .. tool
        if not seen[rule] then
            allow[#allow + 1] = rule
        end
    end
    current.permissions.allow = allow
    f = io.open(path, "wb")
    if f then
        f:write(gitgud.jsonEncode(current) or "{}")
        f:close()
    end
end

--- Make a tab the master's (bragi/agent.lua, after a hot-reload, too).
function master.configure(tab)
    tab.master = true
    tab.title = "Bragi"
    tab.sessionName = master.SESSION
    tab.extraPrompt = prompt()
    tab.startOptions = { repository = false }
    tab.allowTool = isOwnTool
    return tab
end

--- The saved id to resume, when its transcript is still there. One entry
-- tells (the whole transcript, read to say so, held up the UI for 600 ms).
local function savedId(dir)
    local id = settings.get("bragi.masterSession", "")
    if id ~= "" and #gitgud.agentHistory(dir, id, 1) > 0 then
        return id
    end
    return nil
end

--- Show the master conversation (made, or resumed, the first time).
function master.open()
    local tab = master.tab()
    if tab then
        agent.showTab(tab)
        return tab
    end
    local dir = projects.masterDir()
    gitgud.makeDir(dir)
    allowTools(dir)
    local id = savedId(dir)
    if id then
        agent.resume(id, { cwd = dir, master = true, title = "Bragi" })
    else
        agent.newSession({ cwd = dir, master = true, title = "Bragi" })
    end
    tab = master.configure(agent.current())
    gitgud.setText("AgentTitle", "Bragi")
    agent.refreshFolder()
    return tab
end

-- ===================================================================
-- Conversations, as the tools see them
-- ===================================================================

--- A conversation's id: its session's, or one of ours until it has one.
local function idOf(tab)
    local id = tab.session.id or tab.session.resume
    if id then
        return id
    end
    if not tab.ref then
        refCount = refCount + 1
        tab.ref = "new-" .. refCount
    end
    return tab.ref
end

local function findTab(id)
    local tab = agent.tabFor(id)
    if tab then
        return tab
    end
    for _, t in ipairs(agent.tabs()) do
        if t.ref == id then
            return t
        end
    end
    return nil
end

--- What a live conversation is doing, in words.
local function turnStateOf(tab)
    for _, item in ipairs(tab.items or {}) do
        if item.kind == "permission" and not item.answer then
            return "waiting for permission to run " .. tostring(item.tool)
                .. (item.helper and " (one of its helpers asks)" or "")
        elseif item.kind == "question" and not item.answer then
            return "waiting for an answer"
        end
    end
    if tab.session and tab.session.turn then
        return "running"
    elseif tab.unread == "failed" then
        return "stopped with an error"
    elseif tab.unread == "done" then
        return "finished, not looked at yet"
    end
    return "idle"
end

--- Its state, with background tasks still running (sub-agents, commands):
-- a conversation whose turn ended can still be working.
local function stateOf(tab)
    local state = turnStateOf(tab)
    local running = require("bragi.sidepanel").running(tab)
    if running > 0 then
        state = state .. ", " .. running .. " background task" .. (running == 1 and "" or "s") .. " still running"
    end
    return state
end

local function projectName(cwd)
    if not cwd or cwd == "" then
        return "no project"
    end
    return projects.name(cwd)
end

local function cut(s, n)
    s = tostring(s or "")
    local count = utf8.len(s)
    if count and count > n then
        return s:sub(1, utf8.offset(s, n + 1) - 1) .. "..."
    end
    return s
end

--- A project named in a call, or nil and why not.
local function projectArg(what)
    local p = projects.find(what)
    if not p then
        return nil, "No project called \"" .. tostring(what) .. "\" here. bragi_projects lists them; "
            .. "clone one with bragi_clone (its Git address) first."
    end
    if not p.exists then
        return nil, p.name .. "'s folder (" .. p.path .. ") isn't there anymore."
    end
    return p
end

--- Every conversation, live and saved, newest first (one project's when given).
local function conversationList(project)
    local key = project and project.key or nil
    local entries, live = {}, {}
    for _, tab in ipairs(agent.tabs()) do
        if not tab.master and (#tab.items > 0 or tab.session.running)
            and (not key or projects.key(tab.cwd or "") == key) then
            local id = idOf(tab)
            live[id] = true
            if tab.session.resume then
                live[tab.session.resume] = true
            end
            entries[#entries + 1] = { id = id, title = tab.title, cwd = tab.cwd, updated = tab.updated or os.time(),
                state = stateOf(tab), live = true, byBragi = master.followed(tab) }
        end
    end
    for _, p in ipairs(projects.conversations(true)) do
        if not key or p.key == key or projects.key(p.cwd) == key then
            for _, s in ipairs(p.sessions) do
                if not live[s.id] and agent.savedKind(s.asked or s.title) == nil then
                    entries[#entries + 1] = { id = s.id, title = s.title, cwd = (s.cwd or "") ~= "" and s.cwd or p.cwd,
                        updated = agent.activeAt(s), state = "idle", byBragi = master.followsId(s.id) }
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        return (a.updated or 0) > (b.updated or 0)
    end)
    return entries
end

--- Who a conversation's user messages are from, in what Bragi reads.
local function you()
    local name = require("bragi.user").current()
    return name ~= "" and name or "User"
end

--- The last `count` exchanges of a conversation as lines.
local function exchanges(entries, count)
    local starts = {}
    for i, e in ipairs(entries) do
        if e.you then
            starts[#starts + 1] = i
        end
    end
    local from = starts[#starts - count + 1] or 1
    local lines = {}
    for i = from, #entries do
        local e = entries[i]
        if e.who == "step" then
            lines[#lines + 1] = "  (" .. e.text .. ")"
        else
            lines[#lines + 1] = e.who .. ": " .. cut(text.trim(e.text), MAX_MESSAGE_CHARS)
        end
    end
    local body = table.concat(lines, "\n")
    if #body > MAX_READ_CHARS then
        body = "...\n" .. body:sub(#body - MAX_READ_CHARS + 1):gsub("^[^\n]*\n", "")
    end
    return body
end

local function liveEntries(tab)
    local list = {}
    for _, item in ipairs(tab.items) do
        if item.kind == "user" then
            list[#list + 1] = { who = you(), you = true, text = item.text }
        elseif item.kind == "assistant" and (item.text or "") ~= "" then
            list[#list + 1] = { who = item.tag and "Haiku" or "Claude", text = item.text }
        elseif item.kind == "step" and (item.parent or "") == "" then
            list[#list + 1] = { who = "step", text = tostring(item.title) .. " " .. cut(item.summary or "", 120) }
        elseif (item.kind == "permission" or item.kind == "question") and not item.answer then
            list[#list + 1] = { who = "Waiting", text = item.kind == "question" and tostring(item.question)
                or ("permission to run " .. tostring(item.tool) .. ": " .. cut(item.summary or "", 200)) }
        end
    end
    return list
end

--- A saved conversation's latest `max` transcript entries, as liveEntries
-- gives a live one's. Never the whole transcript: read on the UI thread, a
-- long one took over a second.
local function savedEntries(cwd, id, max)
    local list = {}
    for _, h in ipairs(gitgud.agentHistory(cwd or "", id, max)) do
        if h.kind == "user" then
            list[#list + 1] = { who = you(), you = true, text = h.text }
        elseif h.kind == "assistant" then
            list[#list + 1] = { who = "Claude", text = h.text }
        elseif h.kind == "tool" then
            list[#list + 1] = { who = "step", text = tostring(h.name) }
        end
    end
    return list
end

--- Files a conversation's last turn changed.
local function changedFiles(tab)
    local items = tab.items or {}
    local from = 1
    for i, item in ipairs(items) do
        if item.kind == "user" then
            from = i
        end
    end
    local seen, count = {}, 0
    for i = from, #items do
        local item = items[i]
        if item.kind == "step" and not item.error
            and (item.title == "Edit" or item.title == "Write" or item.title == "MultiEdit"
                or item.title == "NotebookEdit") then
            local input = gitgud.jsonDecode(item.inputText or "") or {}
            local path = type(input) == "table" and (input.file_path or input.notebook_path) or nil
            if path and not seen[path] then
                seen[path] = true
                count = count + 1
            end
        end
    end
    return count
end

local DESCRIBE_STEPS = 4          -- the latest steps of a conversation's turn, for a recap
local DESCRIBE_ASKED_CHARS = 400
local DESCRIBE_REPLY_CHARS = 1500 -- of its last reply: the end, where it signs off

--- The end of a long text: "..." and its last `n` bytes.
local function tail(s, n)
    s = text.trim(tostring(s or ""))
    if #s <= n then
        return s
    end
    return "..." .. s:sub(-n):gsub("^[\128-\191]+", "")
end

--- A live conversation as bragi/recap.lua tells it: its title, project,
-- state, what it was last asked, its latest steps, what it waits on (the
-- tool and its input, or the question and its options), its last reply's
-- end, its sign-off when background tasks reported after it, the files
-- its turn changed, and its plan (how far it got, the step it's on).
function master.describe(tab)
    local items = tab.items or {}
    local d = { title = tab.title or "", project = projectName(tab.cwd), state = stateOf(tab),
        updated = text.ago(tab.updated or os.time()) }
    local from = 1
    for i, item in ipairs(items) do
        if item.kind == "user" then
            from = i
            d.asked = cut(text.trim(item.text or ""), DESCRIBE_ASKED_CHARS)
        end
    end
    local steps = {}
    for i = from, #items do
        local item = items[i]
        if item.kind == "step" and (item.parent or "") == "" then
            steps[#steps + 1] = tostring(item.title) .. (item.summary and item.summary ~= ""
                and (" " .. cut(item.summary, 120)) or "")
        elseif item.kind == "assistant" and (item.text or "") ~= "" and not item.tag then
            d.reply = tail(item.text, DESCRIBE_REPLY_CHARS)
        elseif item.kind == "permission" and not item.answer and not d.waiting then
            d.waiting = { kind = "permission", tool = tostring(item.tool), input = cut(item.summary or "", 300),
                helper = item.helper }
        elseif item.kind == "question" and not item.answer and not d.waiting then
            local options = {}
            for _, o in ipairs(type(item.options) == "table" and item.options or {}) do
                options[#options + 1] = tostring(o.label or o)
            end
            d.waiting = { kind = "question", question = tostring(item.question), options = options }
        end
    end
    while #steps > DESCRIBE_STEPS do
        table.remove(steps, 1)
    end
    d.steps = #steps > 0 and steps or nil
    -- Its plan: how far it got and the step it's on (bragi/plan.lua).
    d.plan = tab.plan and require("bragi.plan").describe(tab.plan) or nil
    local files = changedFiles(tab)
    d.files = files > 0 and files or nil
    -- The reply that ended its work's turn, when its background tasks
    -- reported after it (master.holdDone).
    if tab.signoff and tab.signoff ~= "" then
        d.signoff = tail(tab.signoff, DESCRIBE_REPLY_CHARS)
        if d.signoff == d.reply then
            d.signoff = nil
        end
    end
    return d
end

--- The live conversations Bragi follows (open in this run).
function master.followedTabs()
    local list = {}
    for _, tab in ipairs(agent.tabs()) do
        if not tab.master and master.followed(tab) then
            list[#list + 1] = tab
        end
    end
    return list
end

--- The conversations Bragi follows that aren't open now (followed before
-- a restart, or closed since), as master.describe gives them: read from
-- their transcripts, newest first.
function master.followedSaved()
    local open = {}
    for _, tab in ipairs(agent.tabs()) do
        for _, id in ipairs({ tab.session.id or false, tab.session.resume or false }) do
            if id then
                open[id] = true
            end
        end
    end
    local list = {}
    for id, f in pairs(loadFollows()) do
        if not open[id] then
            list[#list + 1] = f
        end
    end
    table.sort(list, function(a, b)
        return (a.at or 0) > (b.at or 0)
    end)
    local out = {}
    for _, f in ipairs(list) do
        local entries = savedEntries(f.cwd, f.id, RECAP_ENTRIES)
        if #entries > 0 then
            local d = { title = f.title ~= "" and f.title or "Untitled", project = projectName(f.cwd),
                state = "idle", updated = text.ago(tonumber(f.at) or os.time()) }
            for _, e in ipairs(entries) do
                if e.you then
                    d.asked, d.reply = cut(text.trim(e.text or ""), DESCRIBE_ASKED_CHARS), nil
                elseif e.who == "Claude" and (e.text or "") ~= "" then
                    d.reply = tail(e.text, DESCRIBE_REPLY_CHARS)
                end
            end
            out[#out + 1] = d
        end
    end
    return out
end

-- ===================================================================
-- The tools
-- ===================================================================

local function def(name, description, properties, required, readOnly)
    return {
        name = name,
        description = description,
        sessions = { master.SESSION },
        inputSchema = { type = "object", properties = properties, required = required,
            additionalProperties = false },
        annotations = { readOnlyHint = readOnly == true },
        noCard = readOnly == true, -- the ones that only read (bragi/uitools.lua)
    }
end

local STRING = { type = "string" }

function master.definitions()
    local fill = require("bragi.user").fill
    return {
        def("bragi_projects", fill("{User}'s projects: every folder on this machine with Claude Code conversations, "
            .. "the app's repository list, and Claude Code's projects (name, folder, whether it's a "
            .. "repository, how many conversations, last activity), and the projects folder."),
            {}, nil, true),
        def("bragi_conversations", "The conversations, newest first: id, title, project, last activity, "
            .. "state (running, idle, waiting for permission or an answer, and background tasks still "
            .. "running), and whether you sent them something.",
            { project = { type = "string", description = "Only this project's (its name or folder)." },
              limit = { type = "number", description = "How many (default 20)." } },
            nil, true),
        def("bragi_read_conversation", fill("What a conversation said lately: its last exchanges ({user}'s "
            .. "message, the steps taken, the replies), and anything it waits for. Cut to a few "
            .. "thousand characters."),
            { id = { type = "string", description = "The conversation's id (bragi_conversations)." },
              exchanges = { type = "number", description = "How many of the last exchanges (default 3, at most 10)." } },
            { "id" }, true),
        def("bragi_send", fill("Send a message to a conversation as {user} would type it. A saved one resumes; "
            .. "one that's working takes it at its next step. Always send to the conversation the message "
            .. "belongs to, whether it's running, idle, or open somewhere else; never hold it back or redirect "
            .. "it because the conversation is busy. One waiting on a question or a permission takes it as "
            .. "the answer (an option, its own answer, or a yes or no); the reply says how."),
            { id = { type = "string", description = "The conversation's id." },
              message = { type = "string", description = fill("The message, cleaned up, in {user}'s voice.") } },
            { "id", "message" }),
        def("bragi_start", "Start a new conversation in a project with a first message.",
            { project = { type = "string", description = "The project's name or folder (bragi_projects)." },
              message = { type = "string", description = fill("The first message, cleaned up, in {user}'s voice.") },
              title = { type = "string", description = "A short title for it (optional)." } },
            { "project", "message" }),
        def("bragi_clone", fill("Clone a repository by its Git address into {user}'s projects folder and add it "
            .. "to the projects. Answers once it's there, or says it goes on when it takes long."),
            { url = { type = "string", description = "The repository's Git address (https:// or ssh)." },
              name = { type = "string", description = "The folder name in the projects folder (optional)." } },
            { "url" }),
        def("bragi_open_project", "Open a project in the app's Repo view (its repository becomes the one "
            .. "open). Given the full path of a local repository folder that isn't a project yet, it adds "
            .. "it to the projects first; a folder that isn't a repository is refused.",
            { project = { type = "string", description = "The project's name, or the full path of its "
                .. "folder (like C:\\Projects\\Moon Garden or ~/src/game)." },
              show = { type = "boolean", description = "Also switch to the Repo view (default false)." } },
            { "project" }),
        def("bragi_restart_app", fill("Restart the app: it closes cleanly and opens again with this "
            .. "conversation. Only when {user} asks. With other conversations working or waiting, or "
            .. "background tasks running, it doesn't restart and says which would be stopped."),
            { force = { type = "boolean", description = fill("Restart even so, stopping them (only once "
                .. "{user} said so).") } },
            nil),
        def("bragi_slash_command", fill("Run a Claude Code slash command, such as /compact (with optional "
            .. "instructions after it), in this conversation or in another one, as if {user} typed it. "
            .. "Use it when {user} asks for one in any words (\"compact this conversation\", \"compact the "
            .. "loot table one\"). Here, it runs once this turn is over: finish your reply in a sentence, "
            .. "don't wait for it. In a conversation that's working, it runs when its turn ends. Not for "
            .. "/model or /effort (bragi_settings_set) or the app's screens."),
            { command = { type = "string", description = "The command and its arguments, like \"/compact\" "
                .. "or \"/compact keep the release plan\"." },
              id = { type = "string", description = "The conversation's id (bragi_conversations); leave it "
                .. "out for this conversation." } },
            { "command" }),
    }
end

local tools = {}

function tools.bragi_projects(args, reply)
    local lines = { "Projects here, most recently active first:" }
    local open = projects.key(require("core.repo").state().path)
    local list = projects.locals()
    for i, p in ipairs(list) do
        if i > MAX_LISTED then
            lines[#lines + 1] = "- ... and " .. (#list - MAX_LISTED) .. " more"
            break
        end
        local about = {}
        about[#about + 1] = not p.exists and "folder missing" or (p.repo and "repository" or "not a repository")
        if p.conversations > 0 then
            about[#about + 1] = p.conversations .. (p.conversations == 1 and " conversation" or " conversations")
                .. ", last " .. text.ago(p.updated)
        end
        if p.key == open then
            about[#about + 1] = "open in the Repo view"
        end
        lines[#lines + 1] = "- " .. p.name .. ": " .. p.path .. " (" .. table.concat(about, "; ") .. ")"
    end
    if #list == 0 then
        lines[#lines + 1] = "- none yet"
    end
    lines[#lines + 1] = "Projects folder (bragi_clone clones there): " .. projects.projectsFolder()
    return table.concat(lines, "\n")
end

function tools.bragi_conversations(args)
    local project = nil
    if args.project ~= nil then
        local why
        project, why = projectArg(args.project)
        if not project then
            return why, true
        end
    end
    local limit = math.max(1, math.min(MAX_LISTED, math.floor(tonumber(args.limit) or 20)))
    local list = conversationList(project)
    local lines = {}
    for i, e in ipairs(list) do
        if i > limit then
            lines[#lines + 1] = "... and " .. (#list - limit) .. " older"
            break
        end
        lines[#lines + 1] = "- \"" .. e.title .. "\" [" .. e.id .. "] in " .. projectName(e.cwd) .. ": " .. e.state
            .. ", last " .. text.ago(e.updated) .. (e.byBragi and ", you sent it something" or "")
    end
    if #lines == 0 then
        return project and ("No conversations in " .. project.name .. " yet.") or "No conversations yet."
    end
    return table.concat(lines, "\n")
end

function tools.bragi_read_conversation(args)
    local id = text.trim(tostring(args.id or ""))
    local count = math.max(1, math.min(MAX_EXCHANGES, math.floor(tonumber(args.exchanges) or 3)))
    local tab = findTab(id)
    if tab and tab.master then
        return "That's this conversation.", true
    end
    if tab then
        return "\"" .. tab.title .. "\" in " .. projectName(tab.cwd) .. " (" .. stateOf(tab) .. "):\n"
            .. exchanges(liveEntries(tab), count)
    end
    projects.conversations(true)
    local saved = agent.savedSession(id)
    if not saved then
        return "No conversation " .. id .. ". bragi_conversations lists them.", true
    end
    return "\"" .. saved.title .. "\" in " .. projectName(saved.cwd) .. " (idle, last " .. text.ago(saved.updated)
        .. "):\n" .. exchanges(savedEntries(saved.cwd, id, READ_ENTRIES), count)
end

-- A message to a conversation that waits on a card answers the card, not
-- a new message after it ("go ahead with the button"
-- went as a message while the question still waited). The voice
-- classifiers read it: prompts/choice.md maps it to a question's options,
-- or it's the question's own answer ("Other"); prompts/approval.md reads
-- a yes or a no for a permission. Neither: nothing is answered or sent,
-- and the master is told to ask.

--- The card a live conversation waits on (its first), or nil.
local function waitingCard(tab)
    for _, item in ipairs(tab.items or {}) do
        if (item.kind == "permission" or item.kind == "question") and not item.answer then
            return item
        end
    end
    return nil
end

--- A classifier's JSON reply as a table ({} when there's none).
local function decoded(reply)
    local first = type(reply) == "string" and reply:find("{", 1, true)
    local last = type(reply) == "string" and reply:match(".*()}")
    local answer = first and last and gitgud.jsonDecode(reply:sub(first, last)) or nil
    return type(answer) == "table" and answer or {}
end

local function quoted(s)
    return "\u{201C}" .. s .. "\u{201D}"
end

local function sentState(tab)
    return " \"" .. tab.title .. "\" in " .. projectName(tab.cwd) .. " goes on (" .. stateOf(tab) .. ")."
end

--- Answer a question card's request: each question the message fits gets
-- its option (or its own answer); when it fits none, the first gets the
-- message as its own answer. The rest are skipped, so the request goes.
local function answerQuestions(tab, card, message, reply)
    local list = {}
    for _, q in ipairs(card.group and card.group.items or { card }) do
        if not q.answer then
            list[#list + 1] = q
        end
    end
    local choices, left = {}, #list
    local function finish()
        local none = true
        for i = 1, #list do
            none = none and choices[i] == nil
        end
        if none then
            choices[1] = { labels = {}, other = message }
        end
        local said, note = {}, "Answered from Bragi: " .. quoted(message)
        for i, q in ipairs(list) do
            if q.answer then
                said[#said + 1] = "'" .. q.question .. "' was answered meanwhile (" .. q.answer .. ")"
            else
                local choice = choices[i]
                agent.answerQuestion(q, choice, { by = "bragi", note = choice and note or nil })
                if not choice then
                    said[#said + 1] = "left '" .. q.question .. "' unanswered (the message didn't fit it)"
                elseif #choice.labels > 0 then
                    said[#said + 1] = "answered its question '" .. q.question .. "' with '" .. q.answer .. "'"
                else
                    said[#said + 1] = "answered its question '" .. q.question .. "' with its own answer '"
                        .. q.answer .. "' (no option fit)"
                end
            end
        end
        master.follow(tab)
        local line = table.concat(said, "; ")
        reply(line:sub(1, 1):upper() .. line:sub(2) .. ". Not sent as a message." .. sentState(tab))
    end
    local chooser = require("bragi.voice").cardHelpers.choose
    for i, q in ipairs(list) do
        local options, known = {}, {}
        for _, o in ipairs(q.options) do
            options[#options + 1] = { label = o.label, description = o.description }
            known[o.label] = true
        end
        require("bragi.helpers").ask(chooser, { asked = q.question, options = options, multiSelect = q.multi,
            answer = message }, function(r)
            local answer = decoded(r)
            local choice = { labels = {}, other = type(answer.other) == "string" and text.trim(answer.other) or "" }
            for _, label in ipairs(type(answer.choice) == "table" and answer.choice or {}) do
                if known[label] and (q.multi or #choice.labels == 0) then
                    choice.labels[#choice.labels + 1] = label
                end
            end
            if answer.sure == false and (#choice.labels > 0 or choice.other ~= "") then
                -- No one to ask "did you mean": the message is its own answer.
                choice = { labels = {}, other = message }
            end
            choices[i] = (#choice.labels > 0 or choice.other ~= "") and choice or nil
            left = left - 1
            if left == 0 then
                finish()
            end
        end)
    end
end

--- Allow or deny a permission card by the message; neither a clear yes
-- nor a clear no: nothing happens, and the master asks.
local function answerPermission(tab, card, message, reply)
    local summary = cut(card.summary, 80)
    local what = tostring(card.tool) .. (summary ~= "" and (" (" .. summary .. ")") or "")
    local asked = card.asked or ("Can I use " .. what .. "?")
    require("bragi.helpers").ask(require("bragi.voice").cardHelpers.approve, { asked = asked, answer = message },
        function(r)
            local answer = decoded(r)
            if card.answer then
                return reply("Its permission for " .. what .. " was answered meanwhile (" .. card.answer
                    .. "). Nothing sent.")
            end
            if answer.answer ~= "allow" and answer.answer ~= "deny" then
                return reply("Not sent: \"" .. tab.title .. "\" waits on a permission to run " .. what
                    .. ", and the message isn't a clear yes or no. "
                    .. require("bragi.user").fill("Ask {user} whether to allow it."))
            end
            local allow = answer.answer == "allow"
            agent.answer(card, allow, (allow and "Allowed from Bragi: " or "Denied from Bragi: ") .. quoted(message),
                "bragi")
            if allow and type(answer.note) == "string" and text.trim(answer.note) ~= "" then
                -- The remark with the yes, in full, as voice sends one.
                agent.remark(card, "About allowing " .. tostring(card.tool) .. ", I said: " .. quoted(message))
            end
            master.follow(tab)
            reply((allow and "Allowed" or "Denied") .. " its permission to run " .. what
                .. ". Not sent as a message." .. sentState(tab))
        end)
end

function tools.bragi_send(args, reply)
    local id = text.trim(tostring(args.id or ""))
    local message = text.trim(tostring(args.message or ""))
    if message == "" then
        return "The message is empty.", true
    end
    local tab = findTab(id)
    -- Only a live conversation can wait on a card.
    local card = tab and not tab.master and waitingCard(tab)
    if card then
        -- The call waits for the classifier, but not past the tool's own
        -- limit: a later answer is a quiet row here instead.
        local answered = false
        local function once(body, isError)
            if not answered then
                answered = true
                return reply(body, isError)
            end
            local m = master.tab()
            if m then
                agent.noteIn(m, body, { error = isError })
            end
        end
        gitgud.after(ANSWER_WAIT_MS, function()
            if not answered then
                answered = true
                reply("Reading the message as the answer to \"" .. tab.title .. "\"'s " .. card.kind
                    .. "; it takes a while. A row here says how it went.")
            end
        end)
        if card.kind == "question" then
            return answerQuestions(tab, card, message, once)
        end
        return answerPermission(tab, card, message, once)
    end
    if not tab then
        projects.conversations(true)
        local saved = agent.savedSession(id)
        if not saved then
            return "No conversation " .. id .. ". bragi_conversations lists them.", true
        end
        -- Always into the conversation meant, wherever else it's open.
        tab = agent.openTab({ id = id })
    end
    if tab.master then
        return "That's this conversation.", true
    end
    -- A running one takes it for its next step, as it does typed messages.
    local ok, err = agent.sendTo(tab, message)
    if not ok then
        return "Couldn't send it: " .. tostring(err), true
    end
    master.follow(tab)
    return "Sent to \"" .. tab.title .. "\" in " .. projectName(tab.cwd) .. " (" .. stateOf(tab)
        .. "). A status row here says when it's done or needs " .. require("bragi.user").label() .. "."
end

function tools.bragi_start(args)
    local project, why = projectArg(args.project)
    if not project then
        return why, true
    end
    local message = text.trim(tostring(args.message or ""))
    if message == "" then
        return "The first message is empty.", true
    end
    local title = text.trim(tostring(args.title or ""))
    local tab = agent.openTab({ cwd = project.path, title = title ~= "" and title or nil })
    local ok, err = agent.sendTo(tab, message)
    if not ok then
        return "Couldn't start it: " .. tostring(err), true
    end
    master.follow(tab)
    return "Started \"" .. tab.title .. "\" [" .. idOf(tab) .. "] in " .. project.name
        .. ". A status row here says when it's done or needs " .. require("bragi.user").label() .. "."
end

function tools.bragi_clone(args, reply)
    local url = text.trim(tostring(args.url or ""))
    if url == "" then
        return "Which repository? Give its Git address.", true
    end
    local name = text.trim(tostring(args.name or ""))
    local repo = { url = url, name = name ~= "" and name or nil }
    local where = projects.projectsFolder() .. "/" .. (repo.name or projects.name((url:gsub("%.git$", ""))))
    local answered = false
    local function answer(body, isError)
        if not answered then
            answered = true
            reply(body, isError)
            return true
        end
        return false
    end
    projects.clone(repo, function(path, cloneErr)
        local body = path and (url .. " is in " .. path .. ", ready to work in.")
            or ("Cloning " .. url .. " failed: " .. tostring(cloneErr))
        if not answer(body, path == nil) then
            -- It took longer than the call waits: say so here, quietly.
            local m = master.tab()
            if m then
                agent.noteIn(m, body, { error = path == nil })
            end
        end
    end)
    gitgud.after(CLONE_WAIT_MS, function()
        answer("Cloning " .. url .. " into " .. where .. "; it takes a while. A status "
            .. "row here says when it's there.", false)
    end)
end

--- A local folder's path as given (absolute: "C:\Projects\Moon Garden",
-- "D:/x", "/home/x", "~/x"), cleaned up; nil when it isn't one.
local function folderArg(what)
    local path = text.trim(tostring(what or "")):gsub('^"(.*)"$', "%1")
    if path:find("^~[/\\]") or path == "~" then
        path = gitgud.homeDir():gsub("[/\\]+$", "") .. path:sub(2)
    end
    if path:find("^%a:[/\\]") or path:find("^\\\\") then
        path = path:gsub("\\", "/")
    elseif not path:find("^/") then
        return nil
    end
    path = path:gsub("(.)/+$", "%1")
    return path
end

--- Open a repository folder by path, adding it to the projects (the
-- repository list, as bragi_clone does) when it isn't one yet. Never
-- makes a repository of a plain folder.
local function openFolder(path, show)
    if not gitgud.pathExists(path) then
        return "There's no folder " .. path .. ".", true
    end
    if not projects.isRepo(path) then
        return path .. " isn't a Git repository or a Perforce workspace, so it can't be a project. "
            .. "Nothing was changed.", true
    end
    require("views.repositories").remember(path)
    if projects.key(require("core.repo").state().path) ~= projects.key(path) then
        gitgud.openRepo(path)
    end
    if show == true then
        require("bragi.shell").show("repo")
    end
    return projects.name(path) .. " (" .. path .. ") is a project now, open in the Repo view."
end

function tools.bragi_open_project(args)
    local project, why = projectArg(args.project)
    if not project then
        local path = folderArg(args.project)
        if not path then
            return why, true
        end
        project = projects.find(path)
        if not project then
            return openFolder(path, args.show)
        end
        if not project.exists then
            return project.name .. "'s folder (" .. project.path .. ") isn't there anymore.", true
        end
    end
    if not project.repo then
        return project.name .. " (" .. project.path .. ") isn't a repository the Repo view can open.", true
    end
    if projects.key(require("core.repo").state().path) ~= project.key then
        gitgud.openRepo(project.path)
    end
    if args.show == true then
        require("bragi.shell").show("repo")
    end
    return project.name .. " is open in the Repo view."
end

function tools.bragi_slash_command(args)
    local slash = require("bragi.slash")
    local id = text.trim(tostring(args.id or ""))
    local tab
    if id == "" then
        tab = master.tab()
    else
        tab = findTab(id)
        if not tab then
            projects.conversations(true)
            if not agent.savedSession(id) then
                return "No conversation " .. id .. ". bragi_conversations lists them.", true
            end
            tab = agent.openTab({ id = id })
        end
    end
    if not tab then
        return "This conversation isn't open.", true
    end
    -- Here: never inside this turn, which is the one calling.
    local how, command = slash.run(tab, args.command, { wait = tab.master })
    if not how then
        return command, true
    end
    if tab.master then
        return command .. " runs in this conversation as soon as this turn is over. Say so in a few words "
            .. "and end your reply."
    end
    master.follow(tab)
    local where = "\"" .. tab.title .. "\" in " .. projectName(tab.cwd)
    if how == "now" then
        return "Ran " .. command .. " in " .. where .. ". A status row here says when it's done."
    end
    return where .. " is " .. stateOf(tab) .. ": " .. command .. " runs there once its turn is over. "
        .. "A status row here says when it's done."
end

--- What a restart would stop, in words: conversations mid-turn or
-- waiting, and background tasks (counted by the side panel, when it can).
local function wouldStop()
    local panel = require("bragi.sidepanel")
    local list = {}
    for _, tab in ipairs(agent.tabs()) do
        local what = {}
        if not tab.master and tab.session.turn then
            what[#what + 1] = stateOf(tab)
        end
        local tasks = panel.running and tonumber(panel.running(tab)) or 0
        if tasks > 0 then
            what[#what + 1] = tasks .. (tasks == 1 and " background task" or " background tasks")
        end
        if #what > 0 then
            list[#list + 1] = (tab.master and "this conversation" or ("\"" .. tab.title .. "\" in "
                .. projectName(tab.cwd))) .. " (" .. table.concat(what, ", ") .. ")"
        end
    end
    return list
end

local restarting = nil -- { timer, done }: a restart answered, the app not closed yet

--- Close the app and start it again; if it can't, say so here.
local function restartNow()
    if not restarting or restarting.done then
        return
    end
    restarting.done = true
    gitgud.cancelTimer(restarting.timer)
    local ok, err = gitgud.restartApp()
    if not ok then
        restarting = nil
        settings.set(RESTART_KEY, "")
        local m = master.tab()
        if m then
            agent.noteIn(m, "The app didn't restart: " .. tostring(err), { error = true })
        end
    end
end

function tools.bragi_restart_app(args)
    if restarting then
        return "It's restarting already.", true
    end
    if args.force ~= true then
        local busy = wouldStop()
        if #busy > 0 then
            return "Not restarted: it would stop " .. table.concat(busy, "; ") .. ". Tell "
                .. require("bragi.user").label() .. " which and ask; call again with force true to "
                .. "restart anyway.", true
        end
    end
    -- What the new start carries on with (master.afterRestart).
    local m = master.tab()
    settings.set(RESTART_KEY, gitgud.jsonEncode({ at = os.time(),
        listening = require("bragi.voice").state() ~= "off",
        byVoice = m ~= nil and m.session.voiceTurn == true }) or "")
    -- Closed once Claude Code has this answer (agent.toolResult, below), or
    -- after a while.
    restarting = {}
    restarting.timer = gitgud.after(RESTART_WAIT_MS, restartNow)
    return "Restarting now: the app closes in a moment and opens again with this conversation. "
        .. "Say nothing more until then."
end

--- Answer one call (bragi/uitools.lua checked it's the master's session).
function master.handle(call, reply)
    if call.session ~= master.SESSION then
        return "Only Bragi's own conversation can use " .. tostring(call.tool) .. ".", true
    end
    local fn = tools[call.tool or ""]
    if not fn then
        return "No tool named " .. tostring(call.tool) .. ".", true
    end
    local args = type(call.arguments) == "table" and call.arguments or {}
    return fn(args, reply)
end

-- ===================================================================
-- Status rows
-- ===================================================================

--- Show a conversation from a status row.
local function openConversation(tab)
    for _, t in ipairs(agent.tabs()) do
        if t == tab then
            agent.showTab(tab)
            return
        end
    end
    local id = tab.session.id or tab.session.resume
    if id then
        agent.resume(id, { cwd = tab.cwd })
    end
end

--- A conversation Bragi sent something to finished its turn, failed, or
-- waits for the user: a quiet row in Bragi's conversation.
local function statusRow(tab, what)
    local m = master.tab()
    if not m or not master.followed(tab) then
        return
    end
    -- Once per wait: several permissions in one turn are one row.
    if (what == "permission" or what == "question") and tab.lastStatus == what then
        return
    end
    tab.lastStatus = what
    local name = projectName(tab.cwd)
    local title = "\"" .. tab.title .. "\""
    local line
    if what == "done" then
        local files = changedFiles(tab)
        line = name .. ": done, " .. title
            .. (files > 0 and (" (" .. files .. (files == 1 and " file" or " files") .. " changed)") or "")
    elseif what == "failed" then
        line = name .. ": " .. title .. " stopped with an error"
    elseif what == "permission" then
        line = name .. ": " .. title .. " needs your permission"
    elseif what == "question" then
        line = name .. ": " .. title .. " has a question for you"
    else
        return
    end
    local item = agent.noteIn(m, line, { action = { label = "Open", run = function()
        openConversation(tab)
    end } })
    item.status = { tab = tab, what = what }
    require("core.app").publish("bragi.masterStatus", { tab = tab, what = what, line = line })
end

-- ===================================================================
-- Done once the work is
-- ===================================================================
--
-- a conversation that ended its turn with background
-- tasks running (a test run reporting each suite) was told done four
-- times in a row, each time Claude Code answered a task's report on its
-- own, restating everything with one count changed. Now a done is news
-- only once the conversation's work is over:
--   - A turn that ends with background tasks still running is held: no
--     row, no news. Its reply (what the work did) is kept as its sign-off.
--   - A turn nobody sent a message for (Claude Code answering a background
--     task's report) is never news by itself: its reply is a small item
--     for the next spoken update (bragi/updates.lua, "bragi-wiki passed"),
--     never a cut-in.
--   - Once the last background task has ended and the conversation is
--     idle, the held done is told, once.
-- A permission, a question, or an error is news as before.

master.HELD_POLL_MS = 1000
master.HELD_SETTLE_MS = 6000 -- idle this long with no task running (Claude Code usually answers the
                             -- last report first): the held done is told
master.SMALL_NEWS_CHARS = 240 -- of the reply that goes to the next update
local heldTimer = nil

--- The last reply of a conversation's latest turn and its item, or nil.
local function lastReply(tab)
    local items = tab.items or {}
    for i = #items, 1, -1 do
        local item = items[i]
        if item.kind == "user" then
            return nil
        elseif item.kind == "assistant" and (item.text or "") ~= "" and not item.tag then
            return text.trim(item.text), item
        end
    end
    return nil
end

--- Look at the held ones until none is left.
local function watchHeld()
    if heldTimer then
        return
    end
    heldTimer = gitgud.every(master.HELD_POLL_MS, function()
        local any = false
        local now = gitgud.now()
        for _, tab in ipairs(master.followedTabs()) do
            local held = tab.doneHeld
            if held then
                if tab.session.turn or tab.session.unprompted or require("bragi.sidepanel").running(tab) > 0 then
                    held.idleSince = nil
                    any = true
                elseif not held.idleSince then
                    held.idleSince = now
                    any = true
                elseif now - held.idleSince < master.HELD_SETTLE_MS then
                    any = true
                else
                    tab.doneHeld = nil
                    statusRow(tab, "done")
                end
            end
        end
        if not any then
            gitgud.cancelTimer(heldTimer)
            heldTimer = nil
        end
    end)
end

--- A followed conversation's turn ended without an error: whether its done
-- is held back (not news now).
-- @param unprompted  nobody sent the turn a message
function master.holdDone(tab, unprompted)
    local running = require("bragi.sidepanel").running(tab)
    if not unprompted then
        tab.signoff = nil
        if running == 0 then
            tab.doneHeld = nil
            return false
        end
        -- Its work goes on in the background: told once that's over.
        tab.signoff = lastReply(tab)
        tab.doneHeld = tab.doneHeld or {}
        watchHeld()
        return true
    end
    if running == 0 and tab.doneHeld then
        tab.doneHeld = nil -- the last task's report: the work is over
        return false
    end
    -- A background task's report: a small item for the next update (once:
    -- a turn that wrote nothing has no reply of its own).
    local reply, item = lastReply(tab)
    if reply and item ~= tab.smallTold then
        tab.smallTold = item
        require("core.app").publish("bragi.step", { tab = tab, step = { kind = "reply",
            text = cut(reply, master.SMALL_NEWS_CHARS) } })
    end
    if running > 0 and tab.doneHeld then
        watchHeld()
    end
    return true
end

-- ===================================================================
-- Start-up
-- ===================================================================

--- The first time the Agent view shows: with no repository open, start in
-- Bragi rather than an empty conversation with nowhere to work.
local defaulted = false
local function startHere()
    if defaulted or require("bragi.shell").view() ~= "agent" then
        return
    end
    defaulted = true
    local cur = agent.current()
    if require("core.repo").state().path == "" and not cur.master and #cur.items == 0
        and not cur.session.running then
        master.open()
    end
end

--- After a restart Bragi asked for (bragi_restart_app): its conversation
-- open again with a note, voice listening again if it was, and "I'm back"
-- when the restart was asked for by voice.
function master.afterRestart()
    local note = gitgud.jsonDecode(settings.get(RESTART_KEY, ""))
    if type(note) ~= "table" then
        return
    end
    settings.set(RESTART_KEY, "")
    if os.time() - (tonumber(note.at) or 0) > RESTART_FRESH_SECONDS then
        return
    end
    require("bragi.shell").show("agent")
    agent.noteIn(master.open(), RESTARTED_NOTE)
    local voice = require("bragi.voice")
    if not note.listening or voice.state() ~= "off" then
        return
    end
    voice.toggle()
    if note.byVoice then
        -- Said once it's listening (it connects in a moment).
        local said = false
        require("core.app").subscribe("bragi.voice", function(state)
            if state == "listening" and not said then
                said = true
                voice.say(BACK_LINE)
            end
        end)
    end
end

function master.init()
    local app = require("core.app")
    require("bragi.uitools").register(master.definitions(), master.handle)
    agent.addToolVerbs({
        mcp__repo__bragi_projects = { "Listed the projects", "Listing the projects" },
        mcp__repo__bragi_conversations = { "Listed the conversations", "Listing the conversations" },
        mcp__repo__bragi_read_conversation = { "Read a conversation", "Reading a conversation" },
        mcp__repo__bragi_send = { "Sent a message", "Sending a message" },
        mcp__repo__bragi_start = { "Started a conversation", "Starting a conversation" },
        mcp__repo__bragi_clone = { "Cloned", "Cloning" },
        mcp__repo__bragi_open_project = { "Opened a project", "Opening a project" },
        mcp__repo__bragi_restart_app = { "Restarted the app", "Restarting the app" },
        mcp__repo__bragi_slash_command = { "Ran a command", "Running a command" },
    })
    app.subscribe("bragi.view", function(view)
        if view == "agent" then
            startHere()
        end
    end)
    -- The view shows before this module starts: look once things settle.
    gitgud.after(300, function()
        master.afterRestart()
        startHere()
    end)
    -- A restart's answer reached Claude Code: close a moment later.
    gitgud.on("agent.toolResult", function(detail)
        local m = master.tab()
        local e = restarting and m and gitgud.jsonDecode(detail)
        local step = type(e) == "table" and e.session == m.session.name and m.byToolId[e.id or ""]
        if step and step.title == "mcp__repo__bragi_restart_app" then
            gitgud.after(RESTART_SETTLE_MS, restartNow)
        end
    end)
    app.subscribe("bragi.sessionState", function(state)
        local tab = state and state.tab
        if not tab then
            return
        end
        if tab.master then
            if tab.session.id then
                settings.set("bragi.masterSession", tab.session.id)
            end
            return
        end
        if state.what == "done" and master.followed(tab) and master.holdDone(tab, state.unprompted) then
            return
        end
        statusRow(tab, state.what)
    end)
end

return master
