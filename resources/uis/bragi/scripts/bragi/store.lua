--- bragi/store.lua: Bragi's local store. Tasks, boards, agent sessions, and
-- wikis live on this computer, in the app's config folder under bragi/, and
-- this answers bragi/server.lua's requests: the same paths and JSON the
-- views send (Boards, Wiki, the agent's task sessions), with the same
-- events published (server.publishEvent), so the views work unchanged.
--
-- Projects: one per repository, keyed by the repository's path (its
-- folder, compared as core/shell.pathKey does). Each gets a short readable
-- id when first seen, its folder name ("app", "app-2" when two share a
-- name), and appears to the views as the repository "local/<id>". A
-- repository that moves is a new project; the old one's data stays.
--
-- Files (every JSON write is atomic: gitgud.configWrite writes a temporary
-- file and renames it over the old one, so a crash leaves one or the other):
--   bragi/store/index.json          the projects { [id] = {path, key, name} },
--                                   the next ids, and which project holds
--                                   each task, board, and session
--   bragi/store/<id>/tasks.json     numbered tasks: title, body, state,
--                                   labels, comments (each with its
--                                   author, when one was given), assignee
--                                   ("bragi" or a person's name), events
--                                   (what happened to it, oldest first:
--                                   created, moved, closed, reopened,
--                                   assigned, agent; the task view's
--                                   activity)
--   bragi/store/<id>/boards.json    the project's boards: columns, each with
--                                   its cards' task ids in order
--   bragi/store/<id>/sessions.json  agent sessions on its tasks (with the
--                                   agent's conversation each runs in)
--   bragi/store/user/boards.json    boards of your own (any project's tasks)
--   bragi/wikis/<id>.wiki.git       each project's wiki, a bare Git
--   bragi/wikis/shared.wiki.git     repository (gitgud.bare*): pages as
--                                   Name.md in folders, images as files,
--                                   each edit a commit (the layout a Git
--                                   host uses: a plain push moves one)
--
-- Answers come on a timer (never inside the call), like a server's.
-- Search scans every page; fine for one person's wikis.
--
-- Public API: store.info(), store.request(method, path, body, onDone,
-- onError), store.repoOf(path), store.answer(method, path, body) (the same,
-- at once: value or nil, message; for tests)

local server = require("bragi.server")
local shellUtil = require("core.shell")
local text = require("core.text")

local store = { name = "bragi.store" }

local OWNER = "local"          -- the views' "owner/name": local/<project id>
local USER = "me"              -- boards of your own: /users/me/projects
local SHARED = "shared"        -- the shared wiki: local/shared
local RESERVED = { [SHARED] = true, user = true, index = true }
local INDEX = "bragi/store/index.json"
local API = "/api/bragi/v0"
local V1 = "/api/v1"
local MAX_HITS = 500

-- ===================================================================
-- Files
-- ===================================================================

local function readJson(name, default)
    local raw = gitgud.configRead(name)
    local value = raw and gitgud.jsonDecode(raw) or nil
    if type(value) ~= "table" then
        return default
    end
    return value
end

local function writeJson(name, value)
    local encoded, err = gitgud.jsonEncode(value)
    if not encoded then
        error("could not save " .. name .. ": " .. tostring(err), 0)
    end
    local ok, werr = gitgud.configWrite(name, encoded)
    if not ok then
        error("could not save " .. name .. ": " .. tostring(werr), 0)
    end
end

local function now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- A list read from JSON ({} decodes as an empty table either way).
local function list(t)
    return type(t) == "table" and t or {}
end

local function loadIndex()
    local index = readJson(INDEX, {})
    index.projects = list(index.projects)
    index.next = list(index.next)
    index.tasks = list(index.tasks)
    index.boards = list(index.boards)
    index.sessions = list(index.sessions)
    return index
end

--- The next id of a kind ("task", "board", "column", "comment", "session").
local function nextId(index, kind)
    local n = tonumber(index.next[kind]) or 1
    index.next[kind] = n + 1
    return n
end

-- ===================================================================
-- Projects
-- ===================================================================

local function repoName(id)
    return OWNER .. "/" .. id
end

--- The project id for "local/<id>", or nil.
local function projectOf(index, owner, name)
    if owner ~= OWNER or not name or not index.projects[name] then
        return nil
    end
    return name
end

--- The repository name ("local/<id>") of the project for the repository at
-- `path`, made the first time; nil for no path.
function store.repoOf(path)
    if not path or path == "" then
        return nil
    end
    local key = shellUtil.pathKey(path)
    local index = loadIndex()
    for id, p in pairs(index.projects) do
        if p.key == key then
            return repoName(id)
        end
    end
    local base = (path:gsub("[/\\]+$", ""):match("([^/\\]+)$") or "project"):lower():gsub("[^%w%-_]", "-")
    if base == "" or RESERVED[base] then
        base = "project-" .. base
    end
    local id, n = base, 1
    while index.projects[id] do
        n = n + 1
        id = base .. "-" .. n
    end
    index.projects[id] = { path = path, key = key, name = path:gsub("[/\\]+$", ""):match("([^/\\]+)$") or id }
    writeJson(INDEX, index)
    return repoName(id)
end

local function tasksFile(project)
    return "bragi/store/" .. project .. "/tasks.json"
end

local function boardsFile(where)
    return "bragi/store/" .. where .. "/boards.json"
end

local function sessionsFile(project)
    return "bragi/store/" .. project .. "/sessions.json"
end

local function loadTasks(project)
    local data = readJson(tasksFile(project), {})
    data.tasks = list(data.tasks)
    return data
end

local function loadBoards(where)
    local data = readJson(boardsFile(where), {})
    data.boards = list(data.boards)
    return data
end

local function loadSessions(project)
    local data = readJson(sessionsFile(project), {})
    data.sessions = list(data.sessions)
    return data
end

-- ===================================================================
-- Errors
-- ===================================================================

local NotFound = "Not found"

local function fail(message)
    error({ message = message }, 0)
end

-- ===================================================================
-- Tasks (issues) and comments
-- ===================================================================

local function labelsOf(value)
    local out = {}
    for _, l in ipairs(list(value)) do
        if type(l) == "string" and l ~= "" then
            out[#out + 1] = { name = l, color = "" }
        elseif type(l) == "table" and type(l.name) == "string" then
            out[#out + 1] = { name = l.name, color = type(l.color) == "string" and l.color or "" }
        end
    end
    return out
end

local MAX_EVENTS = 50 -- a task's history keeps this many, the newest

--- Note what happened to a task (its activity): kind (created, moved,
-- closed, reopened, assigned, agent) and the words shown ("Moved to Done").
local function noteEvent(t, kindName, words, stamp)
    if t.events == nil and t.created and kindName ~= "created" then
        -- A task from before histories: it starts with when it was made.
        t.events = { { kind = "created", text = "Created", at = t.created } }
    end
    t.events = list(t.events)
    t.events[#t.events + 1] = { kind = kindName, text = words, at = stamp or now() }
    while #t.events > MAX_EVENTS do
        table.remove(t.events, 1)
    end
end

--- A task's history, newest first; a task from before histories says only
-- when it was made.
local function eventsOut(t)
    local out = {}
    local events = list(t.events)
    for i = #events, 1, -1 do
        local e = events[i]
        out[#out + 1] = { kind = e.kind, text = e.text, at = e.at }
    end
    if #out == 0 and t.created then
        out[1] = { kind = "created", text = "Created", at = t.created }
    end
    return out
end

--- Who a task is assigned to, as a list (the API's shape): "bragi" or a
-- person's name; empty when no one.
local function assigneesOf(t)
    return (t.assignee and t.assignee ~= "") and { t.assignee } or {}
end

--- The assignee a request asks for: body.assignee, or the first of
-- body.assignees; "" for no one; nil when it doesn't say.
local function assigneeIn(body)
    local value = body.assignee
    if value == nil and body.assignees ~= nil then
        value = list(body.assignees)[1] or ""
    end
    if value == nil then
        return nil
    end
    return text.trim(tostring(value))
end

local function assignedWords(who)
    if who == "" then
        return "Unassigned"
    end
    return "Assigned to " .. (who:lower() == "bragi" and "Bragi" or who)
end

local function issueOut(project, t)
    return {
        id = t.id, number = t.number, title = t.title, body = t.body or "", state = t.state,
        labels = list(t.labels), comments = #list(t.comments), created_at = t.created, updated_at = t.updated,
        closed_at = t.closed, html_url = "", is_pull = false, assignees = assigneesOf(t), events = eventsOut(t),
        repository = { full_name = repoName(project) },
    }
end

local function findTask(data, number)
    for _, t in ipairs(data.tasks) do
        if t.number == number then
            return t
        end
    end
    return nil
end

--- The task with global id `id`: project, its tasks data, the task.
local function taskById(index, id)
    local project = index.tasks[tostring(id)]
    if not project then
        return nil
    end
    local data = loadTasks(project)
    for _, t in ipairs(data.tasks) do
        if t.id == id then
            return project, data, t
        end
    end
    return nil
end

local function createTask(project, body)
    local title = text.trim(tostring(body and body.title or ""))
    if title == "" then
        fail("A task needs a title")
    end
    local index = loadIndex()
    local data = loadTasks(project)
    local number = (tonumber(data.next) or 1)
    data.next = number + 1
    local stamp = now()
    local t = {
        id = nextId(index, "task"), number = number, title = title, body = tostring(body.body or ""),
        state = "open", labels = labelsOf(body.labels), comments = {}, created = stamp, updated = stamp,
    }
    local who = assigneeIn(list(body))
    if who and who ~= "" then
        t.assignee = who
    end
    noteEvent(t, "created", "Created", stamp)
    data.tasks[#data.tasks + 1] = t
    writeJson(tasksFile(project), data)
    index.tasks[tostring(t.id)] = project
    writeJson(INDEX, index)
    server.publishEvent({ type = "issue.created", repo = repoName(project), number = number })
    return issueOut(project, t)
end

local function patchTask(project, number, body)
    local data = loadTasks(project)
    local t = findTask(data, number) or fail(NotFound)
    body = list(body)
    if body.title ~= nil then
        local title = text.trim(tostring(body.title))
        if title == "" then
            fail("A task needs a title")
        end
        t.title = title
    end
    if body.body ~= nil then
        t.body = tostring(body.body)
    end
    if body.state == "open" or body.state == "closed" then
        if body.state ~= t.state then
            t.closed = body.state == "closed" and now() or nil
            noteEvent(t, body.state == "closed" and "closed" or "reopened",
                body.state == "closed" and "Closed" or "Reopened")
        end
        t.state = body.state
    end
    if body.labels ~= nil then
        t.labels = labelsOf(body.labels)
    end
    local who = assigneeIn(body)
    if who and who ~= (t.assignee or "") then
        t.assignee = who ~= "" and who or nil
        noteEvent(t, "assigned", assignedWords(who))
    end
    t.updated = now()
    writeJson(tasksFile(project), data)
    server.publishEvent({ type = "issue.updated", repo = repoName(project), number = number })
    return issueOut(project, t)
end

local function commentOut(c)
    return { id = c.id, body = c.body, author = c.author, created_at = c.created, updated_at = c.updated }
end

local function addComment(project, number, body)
    local index = loadIndex()
    local data = loadTasks(project)
    local t = findTask(data, number) or fail(NotFound)
    local stamp = now()
    local c = { id = nextId(index, "comment"), body = tostring(list(body).body or ""), created = stamp, updated = stamp }
    local author = list(body).author
    if type(author) == "string" and text.trim(author) ~= "" then
        c.author = text.trim(author)
    end
    t.comments = list(t.comments)
    t.comments[#t.comments + 1] = c
    t.updated = stamp
    writeJson(tasksFile(project), data)
    writeJson(INDEX, index)
    server.publishEvent({ type = "issue.comment", repo = repoName(project), number = number })
    return commentOut(c)
end

local function editComment(project, id, body)
    local data = loadTasks(project)
    for _, t in ipairs(data.tasks) do
        for _, c in ipairs(list(t.comments)) do
            if c.id == id then
                c.body = tostring(list(body).body or "")
                c.updated = now()
                writeJson(tasksFile(project), data)
                server.publishEvent({ type = "issue.comment", repo = repoName(project), number = t.number })
                return commentOut(c)
            end
        end
    end
    fail(NotFound)
end

-- ===================================================================
-- Boards
-- ===================================================================

local TEMPLATES = {
    basic_kanban = { "To do", "In progress", "Done" },
    bug_triage = { "Needs triage", "High priority", "Low priority", "Closed" },
    none = { "To do" },
}

local function projectOut(b)
    return {
        id = b.id, title = b.title, description = b.description or "", type = b.type,
        repo = b.repo, owner = b.owner, is_closed = b.closed == true, html_url = "",
        created_at = b.created, updated_at = b.updated,
    }
end

--- A board with its columns and cards (tasks that are gone are left out).
local function boardOut(b)
    local out = projectOut(b)
    out.columns = {}
    local index = loadIndex()
    local loaded = {}
    for _, col in ipairs(list(b.columns)) do
        local cards = {}
        for _, issueId in ipairs(list(col.cards)) do
            local project = index.tasks[tostring(issueId)]
            if project then
                loaded[project] = loaded[project] or loadTasks(project)
                for _, t in ipairs(loaded[project].tasks) do
                    if t.id == issueId then
                        cards[#cards + 1] = {
                            issue_id = t.id, repo = repoName(project), number = t.number, title = t.title,
                            state = t.state, is_pull = false, column_id = col.id, sorting = #cards,
                            labels = list(t.labels), assignees = assigneesOf(t), html_url = "", updated_at = t.updated,
                        }
                    end
                end
            end
        end
        out.columns[#out.columns + 1] = { id = col.id, title = col.title, color = col.color or "",
            default = col.default == true, sorting = #out.columns, cards = cards }
    end
    return out
end

local function listBoards(where, state)
    local out = {}
    for _, b in ipairs(loadBoards(where).boards) do
        local closed = b.closed == true
        if state == "all" or (state == "closed") == closed then
            out[#out + 1] = projectOut(b)
        end
    end
    return out
end

local function createBoard(where, body, extra)
    body = list(body)
    local title = text.trim(tostring(body.title or ""))
    if title == "" then
        fail("A board needs a name")
    end
    local index = loadIndex()
    local data = loadBoards(where)
    local stamp = now()
    local b = { id = nextId(index, "board"), title = title, description = tostring(body.description or ""),
        type = extra.type, repo = extra.repo, owner = extra.owner, closed = false, columns = {},
        created = stamp, updated = stamp }
    for i, name in ipairs(TEMPLATES[body.template] or TEMPLATES.basic_kanban) do
        b.columns[#b.columns + 1] = { id = nextId(index, "column"), title = name, color = "", default = i == 1, cards = {} }
    end
    data.boards[#data.boards + 1] = b
    writeJson(boardsFile(where), data)
    index.boards[tostring(b.id)] = where
    writeJson(INDEX, index)
    server.publishEvent({ type = "board.created", project_id = b.id })
    return projectOut(b)
end

--- The board `id`: where it's kept, that file's data, the board.
local function boardById(id)
    local where = loadIndex().boards[tostring(id)]
    if not where then
        fail(NotFound)
    end
    local data = loadBoards(where)
    for _, b in ipairs(data.boards) do
        if b.id == id then
            return where, data, b
        end
    end
    fail(NotFound)
end

local function saveBoard(where, data, b, event)
    b.updated = now()
    writeJson(boardsFile(where), data)
    server.publishEvent({ type = event or "board.updated", project_id = b.id, repo = b.repo })
end

local function columnOf(b, id)
    for _, col in ipairs(list(b.columns)) do
        if col.id == id then
            return col
        end
    end
    return nil
end

local function defaultColumn(b)
    for _, col in ipairs(list(b.columns)) do
        if col.default then
            return col
        end
    end
    return b.columns[1]
end

--- Take a card off whatever column holds it; its column, or nil.
local function takeCard(b, issueId)
    for _, col in ipairs(list(b.columns)) do
        col.cards = list(col.cards)
        for i, id in ipairs(col.cards) do
            if id == issueId then
                table.remove(col.cards, i)
                return col
            end
        end
    end
    return nil
end

local function putCard(col, issueId, position)
    col.cards = list(col.cards)
    local at = tonumber(position)
    if at and at >= 0 and at < #col.cards then
        table.insert(col.cards, math.floor(at) + 1, issueId)
    else
        col.cards[#col.cards + 1] = issueId
    end
end

local function cardOut(b, issueId)
    for _, col in ipairs(boardOut(b).columns) do
        for _, card in ipairs(col.cards) do
            if card.issue_id == issueId then
                return card
            end
        end
    end
    return nil
end

local function addCard(boardId, body)
    body = list(body)
    local where, data, b = boardById(boardId)
    local index = loadIndex()
    local issueId = tonumber(body.issue_id)
    if not issueId and body.repo and body.number then
        local owner, name = tostring(body.repo):match("^([^/]+)/([^/]+)$")
        local project = projectOf(index, owner, name) or fail(NotFound)
        local t = findTask(loadTasks(project), tonumber(body.number)) or fail(NotFound)
        issueId = t.id
    end
    local project = issueId and index.tasks[tostring(issueId)] or fail(NotFound)
    if b.type == "repository" and repoName(project) ~= b.repo then
        fail("This board takes tasks of " .. tostring(b.repo) .. " only")
    end
    takeCard(b, issueId)
    local col = (body.column_id and columnOf(b, tonumber(body.column_id))) or defaultColumn(b) or fail(NotFound)
    putCard(col, issueId, body.position)
    saveBoard(where, data, b, "board.card.moved")
    return cardOut(b, issueId)
end

local function moveCard(boardId, issueId, body)
    body = list(body)
    local where, data, b = boardById(boardId)
    local from = takeCard(b, issueId) or fail(NotFound)
    local col = from
    if body.column_id then
        col = columnOf(b, tonumber(body.column_id)) or fail(NotFound)
    end
    putCard(col, issueId, body.position)
    saveBoard(where, data, b, "board.card.moved")
    if col ~= from then
        local project, tasks, t = taskById(loadIndex(), issueId)
        if t then
            noteEvent(t, "moved", "Moved to " .. tostring(col.title or "another column"))
            writeJson(tasksFile(project), tasks)
        end
    end
    return cardOut(b, issueId)
end

local function removeCard(boardId, issueId)
    local where, data, b = boardById(boardId)
    if not takeCard(b, issueId) then
        fail(NotFound)
    end
    saveBoard(where, data, b, "board.card.moved")
    return nil
end

local function patchBoard(boardId, body)
    body = list(body)
    local where, data, b = boardById(boardId)
    if body.title ~= nil and text.trim(tostring(body.title)) ~= "" then
        b.title = text.trim(tostring(body.title))
    end
    if body.description ~= nil then
        b.description = tostring(body.description)
    end
    if body.state == "open" or body.state == "closed" then
        b.closed = body.state == "closed"
    end
    saveBoard(where, data, b)
    return projectOut(b)
end

local function deleteBoard(boardId)
    local where, data, b = boardById(boardId)
    for i, x in ipairs(data.boards) do
        if x == b then
            table.remove(data.boards, i)
            break
        end
    end
    writeJson(boardsFile(where), data)
    local index = loadIndex()
    index.boards[tostring(boardId)] = nil
    writeJson(INDEX, index)
    server.publishEvent({ type = "board.deleted", project_id = boardId })
    return nil
end

local function addColumn(boardId, body)
    body = list(body)
    local title = text.trim(tostring(body.title or ""))
    if title == "" then
        fail("A column needs a name")
    end
    local where, data, b = boardById(boardId)
    local index = loadIndex()
    local col = { id = nextId(index, "column"), title = title, color = tostring(body.color or ""), default = false,
        cards = {} }
    if body.default == true then
        for _, c in ipairs(list(b.columns)) do
            c.default = false
        end
        col.default = true
    end
    b.columns[#b.columns + 1] = col
    writeJson(INDEX, index)
    saveBoard(where, data, b)
    return { id = col.id, title = col.title, color = col.color, default = col.default, sorting = #b.columns - 1 }
end

-- ===================================================================
-- Agent sessions
-- ===================================================================

local SESSION_FIELDS = { "status", "summary", "branch", "title", "machine", "comment_id", "conversation" }

--- What a session's status says on its task's history, or nil (waiting
-- and working come and go with every turn: not noted).
local SESSION_WORDS = { done = "Bragi finished", failed = "Bragi got stuck" }

--- Note an agent session's news on its task.
local function noteSession(project, number, words)
    local tasks = loadTasks(project)
    local t = findTask(tasks, number)
    if t and words then
        noteEvent(t, "agent", words)
        writeJson(tasksFile(project), tasks)
    end
end

local function sessionOut(project, s)
    local out = { id = s.id, repo = repoName(project), issue = s.issue, created = s.created, updated = s.updated }
    for _, k in ipairs(SESSION_FIELDS) do
        out[k] = s[k]
    end
    return out
end

local function listSessions(project, number, limit)
    local out = {}
    local all = loadSessions(project).sessions
    table.sort(all, function(a, b)
        if (a.updated or "") ~= (b.updated or "") then
            return (a.updated or "") > (b.updated or "")
        end
        return (a.id or 0) > (b.id or 0) -- the same second: the later one
    end)
    for _, s in ipairs(all) do
        if not number or s.issue == number then
            out[#out + 1] = sessionOut(project, s)
            if limit and #out >= limit then
                break
            end
        end
    end
    return out
end

local function createSession(project, number, body)
    if not findTask(loadTasks(project), number) then
        fail(NotFound)
    end
    local index = loadIndex()
    local data = loadSessions(project)
    local stamp = now()
    local s = { id = nextId(index, "session"), issue = number, created = stamp, updated = stamp }
    for _, k in ipairs(SESSION_FIELDS) do
        s[k] = list(body)[k]
    end
    data.sessions[#data.sessions + 1] = s
    writeJson(sessionsFile(project), data)
    index.sessions[tostring(s.id)] = project
    writeJson(INDEX, index)
    noteSession(project, number, "Bragi started working")
    server.publishEvent({ type = "agent.session.created", repo = repoName(project), issue = number, id = s.id })
    return sessionOut(project, s)
end

local function patchSession(id, body)
    local project = loadIndex().sessions[tostring(id)] or fail(NotFound)
    local data = loadSessions(project)
    for _, s in ipairs(data.sessions) do
        if s.id == id then
            local was = s.status
            for _, k in ipairs(SESSION_FIELDS) do
                if list(body)[k] ~= nil then
                    s[k] = body[k]
                end
            end
            s.updated = now()
            writeJson(sessionsFile(project), data)
            if s.status ~= was then
                noteSession(project, s.issue, SESSION_WORDS[s.status])
            end
            server.publishEvent({ type = "agent.session.updated", repo = repoName(project), issue = s.issue, id = id })
            return sessionOut(project, s)
        end
    end
    fail(NotFound)
end

-- ===================================================================
-- Wikis
-- ===================================================================

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, #B64 do
    B64_VALUE[B64:byte(i)] = i - 1
end

--- Text from base64 (the wiki API sends page text this way).
function store.unbase64(s)
    local out = {}
    local bits, count = 0, 0
    for i = 1, #s do
        local v = B64_VALUE[s:byte(i)]
        if v then
            bits = bits * 64 + v
            count = count + 6
            if count >= 8 then
                count = count - 8
                out[#out + 1] = string.char(bits // (1 << count) % 256)
                bits = bits % (1 << count)
            end
        end
    end
    return table.concat(out)
end

--- The store folder of wiki "local/<name>", or nil.
local function wikiStore(index, owner, name)
    if owner ~= OWNER then
        return nil
    end
    if name == SHARED then
        return "bragi/wikis/" .. SHARED .. ".wiki.git"
    end
    if index.projects[name] then
        return "bragi/wikis/" .. name .. ".wiki.git"
    end
    return nil
end

local function author()
    local name = require("bragi.user").current()
    return name ~= "" and name or "GitGud", "bragi@localhost"
end

--- A page's sub_url from a title: spaces to dashes, nothing a path can't take.
function store.subUrl(title)
    local parts = {}
    for raw in tostring(title):gmatch("[^/]+") do
        local part = text.trim(raw):gsub("%s+", "-"):gsub("[^%w%-_.]", "-"):gsub("^%.+", "")
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

local function titleOf(sub)
    return ((sub:match("([^/]+)$") or sub):gsub("%-", " "))
end

local function commitOut(c)
    return c and { id = c.id, message = text.trim(c.message or ""), author = c.author, created = c.time } or nil
end

local function pagesOf(storeName)
    local out = {}
    for _, f in ipairs(gitgud.bareFiles(storeName) or {}) do
        local sub = f.path:match("^(.+)%.md$")
        if sub then
            out[#out + 1] = { title = titleOf(sub), sub_url = sub, path = f.path,
                last_commit = commitOut((gitgud.bareLog(storeName, f.path, 1) or {})[1]) }
        end
    end
    return out
end

local function pageOut(storeName, sub, ref)
    local path = sub .. ".md"
    local content, err = gitgud.bareRead(storeName, path, ref)
    if err then
        fail(err)
    end
    if not content then
        fail(NotFound)
    end
    local head = (gitgud.bareLog(storeName, "", 1) or {})[1]
    return { title = titleOf(sub), sub_url = sub, path = path, ref = (ref and ref ~= "") and ref or (head and head.id),
        content = content, last_commit = commitOut((gitgud.bareLog(storeName, path, 1) or {})[1]) }
end

local function wikiOut(name, shared)
    return { repo = repoName(name), shared = shared, private = true, can_write = true, default_branch = "main",
        html_url = "", clone_url = gitgud.configPath("bragi/wikis/" .. name .. ".wiki.git") }
end

--- The wikis: the shared one first, then every project's that has a page,
-- and the open repository's even before it has one.
local function listWikis()
    local index = loadIndex()
    local out = { wikiOut(SHARED, true) }
    local open = require("core.repo").state().path
    local openRepo = (open and open ~= "") and store.repoOf(open) or nil
    index = loadIndex()
    local names = {}
    for id in pairs(index.projects) do
        names[#names + 1] = id
    end
    table.sort(names)
    for _, id in ipairs(names) do
        if repoName(id) == openRepo or #(gitgud.bareFiles("bragi/wikis/" .. id .. ".wiki.git") or {}) > 0 then
            out[#out + 1] = wikiOut(id, false)
        end
    end
    return out
end

local function commitPage(storeName, changes, message)
    local name, email = author()
    local id, err = gitgud.bareCommit(storeName, changes, message, name, email)
    if not id then
        fail(err)
    end
    return id
end

local function newPage(owner, name, body)
    body = list(body)
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    local sub = store.subUrl(body.title or "")
    if sub == "" then
        fail("A page needs a title")
    end
    if gitgud.bareRead(storeName, sub .. ".md") then
        fail("There's a page called " .. titleOf(sub) .. " already")
    end
    local content = body.content_base64 and store.unbase64(body.content_base64) or tostring(body.content or "")
    commitPage(storeName, { { path = sub .. ".md", content = content } }, tostring(body.message or ("Add " .. sub)))
    server.publishEvent({ type = "wiki.page.updated", repo = owner .. "/" .. name, sub_url = sub })
    return pageOut(storeName, sub)
end

local function editPage(owner, name, sub, body)
    body = list(body)
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    local old = gitgud.bareRead(storeName, sub .. ".md") or fail(NotFound)
    local target = body.title and store.subUrl(body.title) or sub
    if target == "" then
        target = sub
    end
    local content = body.content_base64 and store.unbase64(body.content_base64) or old
    local changes = { { path = target .. ".md", content = content } }
    if target ~= sub then
        if gitgud.bareRead(storeName, target .. ".md") then
            fail("There's a page called " .. titleOf(target) .. " already")
        end
        changes[#changes + 1] = { path = sub .. ".md", content = false }
    end
    commitPage(storeName, changes, tostring(body.message or ("Update " .. target)))
    server.publishEvent({ type = "wiki.page.updated", repo = owner .. "/" .. name, sub_url = target })
    return pageOut(storeName, target)
end

local function deletePage(owner, name, sub)
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    if not gitgud.bareRead(storeName, sub .. ".md") then
        fail(NotFound)
    end
    commitPage(storeName, { { path = sub .. ".md", content = false } }, "Remove " .. sub)
    server.publishEvent({ type = "wiki.page.updated", repo = owner .. "/" .. name, sub_url = sub })
    return nil
end

local function revisions(owner, name, sub)
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    local commits = {}
    for _, c in ipairs(gitgud.bareLog(storeName, sub .. ".md", 50) or {}) do
        commits[#commits + 1] = { sha = c.id, message = text.trim(c.message or ""), created = c.time,
            author = { name = c.author, date = os.date("!%Y-%m-%dT%H:%M:%SZ", c.time) } }
    end
    return { count = #commits, commits = commits }
end

--- The wiki's pages with their summaries and [[links]] (bragi/wikilinks.lua):
-- { pages = { { sub_url, title, summary, words, last_commit, links = {
-- { sub_url, line, context } }, missing = { { title, line, context } } } } }
local function wikiLinks(owner, name)
    local wikilinks = require("bragi.wikilinks")
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    local pages = pagesOf(storeName)
    local index = wikilinks.index(pages)
    for _, p in ipairs(pages) do
        local content = gitgud.bareRead(storeName, p.path) or ""
        local _, words = content:gsub("%S+", "")
        p.summary, p.words, p.links, p.missing = wikilinks.summary(content), words, {}, {}
        local seen = {}
        for _, l in ipairs(wikilinks.find(content)) do
            local sub = wikilinks.resolve(index, l.target)
            local key = sub or ("?" .. wikilinks.key(l.target))
            if sub ~= p.sub_url and not seen[key] then
                seen[key] = true
                if sub then
                    p.links[#p.links + 1] = { sub_url = sub, line = l.line, context = l.context }
                else
                    p.missing[#p.missing + 1] = { title = l.target, line = l.line, context = l.context }
                end
            end
        end
    end
    return { pages = pages }
end

--- The wiki's latest changes, newest first: { { id, message, author, created } }.
local function wikiActivity(owner, name, limit)
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    local out = {}
    for _, c in ipairs(gitgud.bareLog(storeName, "", math.min(tonumber(limit) or 20, 100)) or {}) do
        out[#out + 1] = commitOut(c)
    end
    return out
end

local function putFile(owner, name, path, body)
    local storeName = wikiStore(loadIndex(), owner, name) or fail(NotFound)
    if path:find("%.md$") or path:find("^%.") or path:find("/%.") then
        fail("Pages go through the page API; no hidden files")
    end
    local content = type(body) == "string" and body or (type(body) == "table" and body.content_base64
        and store.unbase64(body.content_base64)) or fail("No file content")
    commitPage(storeName, { { path = path, content = content } }, "Upload " .. path)
    server.publishEvent({ type = "wiki.page.updated", repo = owner .. "/" .. name, path = path })
    return { path = path, url = API .. "/repos/" .. owner .. "/" .. name .. "/wiki/files/" .. path, size = #content }
end

local function search(q)
    local words = {}
    for w in tostring(q or ""):lower():gmatch("%S+") do
        words[#words + 1] = w
    end
    if #words == 0 then
        return {}
    end
    local hits = {}
    local index = loadIndex()
    local names = { SHARED }
    for id in pairs(index.projects) do
        names[#names + 1] = id
    end
    for _, name in ipairs(names) do
        local storeName = "bragi/wikis/" .. name .. ".wiki.git"
        for _, f in ipairs(gitgud.bareFiles(storeName) or {}) do
            local sub = f.path:match("^(.+)%.md$")
            if sub and #hits < MAX_HITS then
                local title = titleOf(sub)
                local content = gitgud.bareRead(storeName, f.path) or ""
                local haystack = (title .. "\n" .. content):lower()
                local all = true
                for _, w in ipairs(words) do
                    all = all and haystack:find(w, 1, true) ~= nil
                end
                if all then
                    local lines, n = {}, 0
                    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
                        n = n + 1
                        local lower = line:lower()
                        for _, w in ipairs(words) do
                            if lower:find(w, 1, true) and #lines < 5 then
                                lines[#lines + 1] = { number = n, text = line }
                                break
                            end
                        end
                    end
                    hits[#hits + 1] = { repo = repoName(name), shared = name == SHARED, title = title, sub_url = sub,
                        path = f.path, lines = lines }
                end
            end
        end
    end
    return hits
end

-- ===================================================================
-- Routing
-- ===================================================================

local function decode(s)
    return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function parse(path)
    local bare, query = path:match("^([^?]*)%??(.*)$")
    local q = {}
    for k, v in query:gmatch("([^&=]+)=?([^&]*)") do
        q[decode(k)] = decode(v)
    end
    return bare, q
end

--- Routes: { method, pattern (on the path without its query), handler(captures..., body, query) }.
local ROUTES = {
    -- Boards
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/projects$", function(o, n, _, q)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return listBoards(project, q.state or "open")
    end },
    { "POST", "^" .. API .. "/repos/([^/]+)/([^/]+)/projects$", function(o, n, body)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return createBoard(project, body, { type = "repository", repo = repoName(project) })
    end },
    { "GET", "^" .. API .. "/users/([^/]+)/projects$", function(u, _, q)
        if u ~= USER then
            fail(NotFound)
        end
        return listBoards("user", q.state or "open")
    end },
    { "POST", "^" .. API .. "/users/([^/]+)/projects$", function(u, body)
        if u ~= USER then
            fail(NotFound)
        end
        return createBoard("user", body, { type = "user", owner = USER })
    end },
    { "GET", "^" .. API .. "/orgs/([^/]+)/projects$", function()
        return {}
    end },
    { "GET", "^" .. V1 .. "/user/orgs$", function()
        return {}
    end },
    { "GET", "^" .. API .. "/projects/(%d+)$", function(id)
        local _, _, b = boardById(tonumber(id))
        return boardOut(b)
    end },
    { "PATCH", "^" .. API .. "/projects/(%d+)$", function(id, body)
        return patchBoard(tonumber(id), body)
    end },
    { "DELETE", "^" .. API .. "/projects/(%d+)$", function(id)
        return deleteBoard(tonumber(id))
    end },
    { "GET", "^" .. API .. "/projects/(%d+)/columns$", function(id)
        local _, _, b = boardById(tonumber(id))
        local out = {}
        for i, col in ipairs(boardOut(b).columns) do
            out[i] = { id = col.id, title = col.title, color = col.color, default = col.default, sorting = col.sorting }
        end
        return out
    end },
    { "POST", "^" .. API .. "/projects/(%d+)/columns$", function(id, body)
        return addColumn(tonumber(id), body)
    end },
    { "POST", "^" .. API .. "/projects/(%d+)/cards$", function(id, body)
        return addCard(tonumber(id), body)
    end },
    { "POST", "^" .. API .. "/projects/(%d+)/cards/(%d+)/move$", function(id, issue, body)
        return moveCard(tonumber(id), tonumber(issue), body)
    end },
    { "DELETE", "^" .. API .. "/projects/(%d+)/cards/(%d+)$", function(id, issue)
        return removeCard(tonumber(id), tonumber(issue))
    end },

    -- Tasks
    { "GET", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues$", function(o, n, _, q)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        local out = {}
        for _, t in ipairs(loadTasks(project).tasks) do
            if (q.state or "open") == "all" or t.state == (q.state or "open") then
                out[#out + 1] = issueOut(project, t)
            end
        end
        return out
    end },
    { "POST", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues$", function(o, n, body)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return createTask(project, list(body))
    end },
    { "GET", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues/(%d+)$", function(o, n, number)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        local t = findTask(loadTasks(project), tonumber(number)) or fail(NotFound)
        return issueOut(project, t)
    end },
    { "PATCH", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues/(%d+)$", function(o, n, number, body)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return patchTask(project, tonumber(number), body)
    end },
    { "GET", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues/(%d+)/comments$", function(o, n, number)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        local t = findTask(loadTasks(project), tonumber(number)) or fail(NotFound)
        local out = {}
        for i, c in ipairs(list(t.comments)) do
            out[i] = commentOut(c)
        end
        return out
    end },
    { "POST", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues/(%d+)/comments$", function(o, n, number, body)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return addComment(project, tonumber(number), body)
    end },
    { "PATCH", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/issues/comments/(%d+)$", function(o, n, id, body)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return editComment(project, tonumber(id), body)
    end },

    -- Agent sessions
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/sessions$", function(o, n, _, q)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return listSessions(project, nil, tonumber(q.limit))
    end },
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/issues/(%d+)/sessions$", function(o, n, number, _, q)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return listSessions(project, tonumber(number), tonumber(q.limit))
    end },
    { "POST", "^" .. API .. "/repos/([^/]+)/([^/]+)/issues/(%d+)/sessions$", function(o, n, number, body)
        local project = projectOf(loadIndex(), o, n) or fail(NotFound)
        return createSession(project, tonumber(number), body)
    end },
    { "PATCH", "^" .. API .. "/sessions/(%d+)$", function(id, body)
        return patchSession(tonumber(id), body)
    end },

    -- Wikis
    { "GET", "^" .. API .. "/wikis$", function()
        return listWikis()
    end },
    { "GET", "^" .. API .. "/wikis/search$", function(_, q)
        return search(q.q)
    end },
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/wiki/pages$", function(o, n)
        local storeName = wikiStore(loadIndex(), o, n) or fail(NotFound)
        return pagesOf(storeName)
    end },
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/wiki/links$", function(o, n)
        return wikiLinks(o, n)
    end },
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/wiki/activity$", function(o, n, _, q)
        return wikiActivity(o, n, q.limit)
    end },
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/wiki/page/(.+)$", function(o, n, sub, _, q)
        local storeName = wikiStore(loadIndex(), o, n) or fail(NotFound)
        return pageOut(storeName, sub, q.ref)
    end },
    { "GET", "^" .. API .. "/repos/([^/]+)/([^/]+)/wiki/files/(.+)$", function(o, n, path, _, q)
        local storeName = wikiStore(loadIndex(), o, n) or fail(NotFound)
        return gitgud.bareRead(storeName, path, q.ref) or fail(NotFound)
    end },
    { "PUT", "^" .. API .. "/repos/([^/]+)/([^/]+)/wiki/files/(.+)$", function(o, n, path, body)
        return putFile(o, n, path, body)
    end },
    { "POST", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/wiki/new$", function(o, n, body)
        return newPage(o, n, body)
    end },
    { "PATCH", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/wiki/page/(.+)$", function(o, n, sub, body)
        return editPage(o, n, sub, body)
    end },
    { "DELETE", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/wiki/page/(.+)$", function(o, n, sub)
        return deletePage(o, n, sub)
    end },
    { "GET", "^" .. V1 .. "/repos/([^/]+)/([^/]+)/wiki/revisions/(.+)$", function(o, n, sub)
        return revisions(o, n, sub)
    end },
}

--- Answer a request at once: the value (nil when there's none), or nil and
-- the reason.
function store.answer(method, path, body)
    local bare, query = parse(tostring(path or ""))
    for _, route in ipairs(ROUTES) do
        if route[1] == method then
            local matched = bare:match(route[2])
            -- A pattern without captures matches as the whole path: no arguments.
            local captures = route[2]:find("(", 1, true) and { bare:match(route[2]) } or {}
            if matched then
                for i, c in ipairs(captures) do
                    captures[i] = decode(c)
                end
                local n = #captures
                captures[n + 1] = body
                captures[n + 2] = query
                local ok, result = pcall(route[3], table.unpack(captures, 1, n + 2))
                if ok then
                    return result
                end
                return nil, type(result) == "table" and result.message or tostring(result)
            end
        end
    end
    return nil, "No such request: " .. tostring(method) .. " " .. tostring(path)
end

function store.request(method, path, body, onDone, onError)
    if type(body) == "string" and body:find("^%s*[{%[]") then
        body = gitgud.jsonDecode(body) or body
    end
    local value, err = store.answer(method, path, body)
    gitgud.after(0, function()
        if err then
            if onError then
                onError(err)
            end
        elseif onDone then
            onDone(value)
        end
    end)
end

function store.info()
    return { url = "", user = USER, signedIn = true, ["local"] = true }
end

function store.init()
    server.setBackend(store)
end

return store
