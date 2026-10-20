--- bragi/boards.lua: the Boards view (layouts/bragi/boards.xml, design D).
--
-- A board is a project in Bragi's store (bragi/server.lua; on this
-- computer, bragi/store.lua): columns of cards, each card a task. The title button
-- picks the board (the open repository's boards, yours, and your
-- organisations'); the choice is kept in bragi.board. A card's menu moves
-- it to another column, opens it in the store, or takes it off the board;
-- New task (or a column's + Add) opens an issue and puts it on the board.
-- "Work on this with Bragi" hands an open issue to the agent
-- (agent.workOn); cards show its sessions' state. The store's events
-- reload the board when cards, issues, or sessions change.
--
-- The store only keeps the board; how it looks is the app's: a column's
-- colour picks the nearest theme colour (tone), never the raw value. List
-- and Backlog aren't designed yet, so the switch stays on Board.

local C = require("core.palette")
local app = require("core.app")
local commands = require("ui.commands")
local dialog = require("ui.dialog")
local menu = require("ui.menu")
local repo = require("core.repo")
local server = require("bragi.server")
local settings = require("core.settings")
local shell = require("bragi.shell")
local status = require("core.status")
local text = require("core.text")
local ui = require("bragi.ui")

local boards = { name = "bragi.boards" }

local PAD = 20
local GAP = 12
local MIN_COLUMN = 210
local CARD_HEIGHT = 100

local API = "/api/bragi/v0"

local mode = "board"
local projects = {}       -- boards to choose from: { id, title, type, repo, owner }
local board = nil         -- the open board (GET /projects/{id})
local sessionsByCard = {} -- "owner/name#number" -> its newest agent session
local state = "idle"      -- idle | loading | ready | error
local problem = nil       -- what went wrong, for the empty state
local built = 0
local reloadTimer = nil

local MODES = { { id = "board", label = "Board" }, { id = "list", label = "List" }, { id = "backlog", label = "Backlog" } }

-- ===================================================================
-- Colours
-- ===================================================================

--- The theme colour nearest a "#rrggbb" from the server, by hue; nil for
-- greys and "".
function boards.tone(hex)
    local r, g, b = (hex or ""):match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then
        return nil
    end
    r, g, b = tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
    local hi, lo = math.max(r, g, b), math.min(r, g, b)
    if hi - lo < 0.15 then
        return nil
    end
    local h
    if hi == r then
        h = ((g - b) / (hi - lo)) % 6
    elseif hi == g then
        h = (b - r) / (hi - lo) + 2
    else
        h = (r - g) / (hi - lo) + 4
    end
    h = h * 60
    if h < 40 or h >= 330 then
        return C.warn
    elseif h < 70 then
        return C.accent
    elseif h < 170 then
        return C.add
    elseif h < 260 then
        return C.link
    end
    return C.accentText
end

-- ===================================================================
-- Loading
-- ===================================================================

--- "owner/name" of the open repository in the store: the store's own name
-- for it (the local store), or its remote's when that is on the server.
function boards.serverRepo()
    local own = server.repoOf(repo.state().path)
    if own then
        return own
    end
    local info = server.info()
    local host = (info.url or ""):match("^https?://([^/:]+)")
    local remote = repo.remote(repo.primaryRemote() or "")
    if not host or not remote then
        return nil
    end
    local url = remote.url or ""
    -- "scheme://[user@]host[:port]/owner/name": the user part only when
    -- there is an "@" before the first "/" ("http://host:8080/x/y" read
    -- "0" as the host before).
    local rest = url:match("^%a+://(.+)$")
    local remoteHost, path = nil, nil
    if rest then
        local authority, tail = rest:match("^([^/]+)/(.+)$")
        if authority then
            remoteHost, path = authority:gsub("^.*@", ""):match("^([^:]+)"), tail
        end
    else
        remoteHost, path = url:match("^[^@]+@([^:]+):(.+)$")
    end
    if not remoteHost or remoteHost:lower() ~= host:lower() then
        return nil
    end
    path = path:gsub("%.git$", ""):gsub("/$", "")
    if not path:match("^[^/]+/[^/]+$") then
        return nil
    end
    return path
end

local build

local function show()
    if shell.view() == "boards" then
        build()
    end
end

local function fail(message)
    state = "error"
    problem = message
    show()
end

--- Fetch the agent sessions of the board's repositories: the newest per
-- issue, shown on its card.
local function loadSessions()
    local repos = {}
    for _, col in ipairs(board and board.columns or {}) do
        for _, card in ipairs(col.cards or {}) do
            if card.repo then
                repos[card.repo] = true
            end
        end
    end
    local forBoard = board
    for name in pairs(repos) do
        server.request("GET", API .. "/repos/" .. name .. "/sessions?limit=50", nil, function(list)
            if board ~= forBoard then
                return
            end
            local changed = false
            for _, s in ipairs(type(list) == "table" and list or {}) do
                local key = (s.repo or name) .. "#" .. tostring(s.issue)
                local known = sessionsByCard[key]
                if not known or (s.updated or "") > (known.updated or "") then
                    sessionsByCard[key] = s
                    changed = true
                end
            end
            if changed then
                show()
            end
        end)
    end
end

--- Open board `id`.
function boards.open(id)
    settings.set("bragi.board", tostring(id))
    state = "loading"
    show()
    server.request("GET", API .. "/projects/" .. id, nil, function(value)
        if type(value) ~= "table" then
            fail("No board came back.")
            return
        end
        board = value
        sessionsByCard = {}
        state = "ready"
        show()
        loadSessions()
    end, fail)
end

--- The open board again (after a change here or on the server).
function boards.reload()
    if board then
        boards.open(board.id)
    end
end

--- Find the boards to choose from, then open the remembered one.
function boards.load()
    if not server.info().signedIn then
        state, board, projects = "idle", nil, {}
        show()
        return
    end
    state = "loading"
    show()

    local found, pending = {}, 0
    local function add(list)
        for _, p in ipairs(type(list) == "table" and list or {}) do
            if p.id and not found[p.id] then
                found[p.id] = true
                projects[#projects + 1] = p
            end
        end
    end
    local function settle()
        pending = pending - 1
        if pending > 0 then
            return
        end
        if #projects == 0 then
            board = nil
            state = "ready"
            show()
            return
        end
        local saved = tonumber(settings.get("bragi.board", ""))
        local pick = projects[1].id
        for _, p in ipairs(projects) do
            if p.id == saved then
                pick = saved
            end
        end
        boards.open(pick)
    end
    local function ask(path, then_)
        pending = pending + 1
        server.request("GET", path, nil, function(value)
            if then_ then
                then_(value)
            else
                add(value)
            end
            settle()
        end, function()
            settle() -- one source failing still shows the others
        end)
    end

    projects = {}
    local own = boards.serverRepo()
    if own then
        ask(API .. "/repos/" .. own .. "/projects?state=open&limit=50")
    end
    ask(API .. "/users/" .. server.info().user .. "/projects?state=open&limit=50")
    ask("/api/v1/user/orgs?limit=50", function(orgs)
        for _, org in ipairs(type(orgs) == "table" and orgs or {}) do
            if org.username then
                ask(API .. "/orgs/" .. org.username .. "/projects?state=open&limit=50")
            end
        end
    end)
end

--- Reload soon (several feed events in a row make one reload).
local function reloadSoon()
    if reloadTimer then
        gitgud.cancelTimer(reloadTimer)
    end
    reloadTimer = gitgud.after(400, function()
        reloadTimer = nil
        boards.reload()
    end)
end

-- ===================================================================
-- Actions
-- ===================================================================

local function column(id)
    for _, col in ipairs(board and board.columns or {}) do
        if col.id == id then
            return col
        end
    end
    return nil
end

local function defaultColumn()
    for _, col in ipairs(board and board.columns or {}) do
        if col.default then
            return col
        end
    end
    return board and board.columns and board.columns[1]
end

--- Move a card to a column (last place).
function boards.move(card, columnId)
    server.request("POST", API .. "/projects/" .. board.id .. "/cards/" .. card.issue_id .. "/move",
        { column_id = columnId }, function()
            local col = column(columnId)
            status.ok("Moved #" .. card.number .. " to " .. (col and col.title or "the column") .. ".")
            boards.reload()
        end, function(msg)
            status.error(msg)
        end)
end

local function removeCard(card)
    server.request("DELETE", API .. "/projects/" .. board.id .. "/cards/" .. card.issue_id, nil, function()
        boards.reload()
    end, function(msg)
        status.error(msg)
    end)
end

--- Ask for a task's title, open the issue, and put it on the board.
function boards.newTask(columnId)
    if not board then
        return
    end
    local fixedRepo = board.type == "repository" and board.repo or nil
    local fields = {
        { label = "Title", value = "" },
        { label = "Description (optional)", value = "" },
    }
    if not fixedRepo then
        fields[3] = { label = "Repository (owner/name)", value = boards.serverRepo() or "" }
    end
    dialog.show({
        title = "New task",
        message = "On " .. (board.title or "the board") .. (fixedRepo and (", in " .. fixedRepo) or "") .. ".",
        fields = fields,
        ok = "Add task",
        canSubmit = function(v)
            return text.trim(v.fields[1]) ~= "" and (fixedRepo or text.trim(v.fields[3] or ""):match("^[^/%s]+/[^/%s]+$"))
                and true or false
        end,
        onOk = function(v)
            local target = fixedRepo or text.trim(v.fields[3])
            local col = columnId or (defaultColumn() or {}).id
            server.request("POST", "/api/v1/repos/" .. target .. "/issues",
                { title = text.trim(v.fields[1]), body = v.fields[2] }, function(issue)
                    server.request("POST", API .. "/projects/" .. board.id .. "/cards",
                        { issue_id = issue and issue.id, column_id = col }, function()
                            status.ok("Added #" .. tostring(issue and issue.number) .. ".")
                            boards.reload()
                        end, function(msg)
                            status.error("The issue was opened, but not put on the board: " .. msg)
                        end)
                end, function(msg)
                    status.error(msg)
                end)
            return true
        end,
    })
end

--- Make a board of your own.
local function newBoard()
    dialog.prompt("New board", "Name", "", "Create", function(title)
        if title == "" then
            return false, "Give the board a name."
        end
        server.request("POST", API .. "/users/" .. server.info().user .. "/projects",
            { title = title, description = "", template = "basic_kanban" }, function(project)
                projects[#projects + 1] = project
                boards.open(project.id)
            end, function(msg)
                status.error(msg)
            end)
        return true
    end)
end

local function pickBoard()
    local items = {}
    for _, p in ipairs(projects) do
        local where = p.type == "repository" and p.repo or p.owner or ""
        items[#items + 1] = {
            label = p.title .. (where ~= "" and ("  (" .. where .. ")") or ""),
            checked = board and board.id == p.id,
            action = function()
                boards.open(p.id)
            end,
        }
    end
    if #items > 0 then
        items[#items + 1] = { separator = true }
    end
    items[#items + 1] = { label = "New board", action = newBoard, enabled = server.info().signedIn }
    items[#items + 1] = { label = "Reload", action = boards.load, enabled = server.info().signedIn }
    local x, y, _, h = gitgud.getRect("BoardsTitle")
    menu.popup(items, x or 0, (y or 0) + (h or 40))
end

--- Hand an issue to the agent: fetch its text, then start a session on it.
function boards.workOn(card)
    local task = { repo = card.repo, number = card.number, title = card.title }
    server.request("GET", "/api/v1/repos/" .. card.repo .. "/issues/" .. card.number, nil, function(issue)
        task.body = type(issue) == "table" and issue.body or ""
        require("bragi.agent").workOn(task)
    end, function()
        require("bragi.agent").workOn(task) -- the title alone will do
    end)
end

local function cardMenu(card, widget)
    local items = {}
    if card.state ~= "closed" and not card.is_pull then
        items[#items + 1] = {
            label = "Work on this with Bragi",
            action = function()
                boards.workOn(card)
            end,
        }
        items[#items + 1] = { separator = true }
    end
    for _, col in ipairs(board.columns or {}) do
        if col.id ~= card.column_id then
            items[#items + 1] = {
                label = "Move to " .. col.title,
                action = function()
                    boards.move(card, col.id)
                end,
            }
        end
    end
    items[#items + 1] = { separator = true }
    if (card.html_url or "") ~= "" then
        items[#items + 1] = {
            label = "Open in the browser",
            action = function()
                gitgud.openExternal(card.html_url)
            end,
        }
    end
    items[#items + 1] = {
        label = "Take off the board",
        action = function()
            removeCard(card)
        end,
    }
    local x, y, _, h = gitgud.getRect(widget)
    menu.popup(items, x or 0, (y or 0) + (h or 0))
end

-- ===================================================================
-- Drawing
-- ===================================================================

local function paintModes()
    for _, m in ipairs(MODES) do
        local name = "BoardsMode_" .. m.id
        local active = m.id == mode
        gitgud.setProperty(name, "NormalFillColour", active and C.sel or C.transparent)
        gitgud.setProperty(name, "HoverFillColour", active and C.sel or C.hover)
        gitgud.setProperty(name, "NormalTextColour", active and C.text or C.sub)
    end
end

--- A note card (empty states), with an optional button.
local function note(root, w, title, body, button, action)
    local name = root .. "Note"
    local width = math.min(w - 2 * PAD, 640)
    local height = button and 140 or 92
    ui.card(name, root, { PAD, PAD, width, height })
    ui.label(name .. "Title", name, { 18, 16, width - 36, 20 }, title, { font = "Bragi-14-Bold" })
    ui.paragraph(name .. "Text", name, { 18, 42, width - 36, 40 }, body, { font = "Bragi-13", colour = C.sub })
    if button then
        local b = ui.button(name .. "Button", name, { 18, 92, 160, 34 }, button, { primary = true })
        gitgud.on(b .. ".clicked", action)
    end
    gitgud.setProperty(root, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}", width + 2 * PAD, height + 2 * PAD))
end

local function drawCard(cname, parent, card, x, y, width)
    ui.button(cname, parent, { x, y, width, CARD_HEIGHT }, "", { radius = 10 })
    gitgud.setProperty(cname, "NormalFillColour", C.panel)
    gitgud.setProperty(cname, "HoverFillColour", C.hover)
    gitgud.setProperty(cname, "PushedFillColour", C.sel)
    gitgud.setProperty(cname, "TooltipText", "Move, open, or take off the board")

    local key = (board.type == "repository" and card.repo == board.repo) and ("#" .. card.number)
        or ((card.repo or "") .. "#" .. tostring(card.number))
    local label = card.labels and card.labels[1]
    local closed = card.state == "closed"
    local markup = "[font='Bragi-Mono-11'][colour='" .. C.sub .. "']" .. text.escape(key)
    if card.is_pull then
        markup = markup .. "   [font='Bragi-12-Bold'][colour='" .. C.link .. "']Pull request"
    end
    if label then
        markup = markup .. "   [font='Bragi-12-Bold'][colour='" .. (boards.tone(label.color) or C.sub) .. "']"
            .. text.escape(label.name)
    end
    if closed then
        markup = markup .. "   [font='Bragi-12-Bold'][colour='" .. C.sub .. "']Closed"
    end
    ui.label(cname .. "Key", cname, { 12, 10, width - 24, 16 }, markup, { markup = true })
    ui.paragraph(cname .. "Title", cname, { 12, 32, width - 24, 40 }, card.title or "",
        { font = "Bragi-14-Bold", colour = closed and C.sub or C.text })

    -- The agent's state on it, when a session works on it; else more labels.
    local agentSession = sessionsByCard[(card.repo or "") .. "#" .. tostring(card.number)]
    local AGENT_STATE = { working = { "Bragi is working", C.accentText }, waiting = { "Bragi is waiting", C.link },
        failed = { "Bragi got stuck", C.err } }
    local shown = agentSession and AGENT_STATE[agentSession.status]
    if shown then
        ui.label(cname .. "More", cname, { 12, 74, width - 80, 16 }, shown[1],
            { font = "Bragi-12-Bold", colour = shown[2] })
    else
        local more = card.labels and #card.labels > 1 and ("+" .. (#card.labels - 1) .. " labels") or ""
        ui.label(cname .. "More", cname, { 12, 74, width - 80, 16 }, more, { font = "Bragi-12", colour = C.sub })
    end
    for i, who in ipairs(card.assignees or {}) do
        if i > 3 then
            break
        end
        local bragi = who == "bragi"
        local avatar = cname .. "Who" .. i
        ui.box(avatar, cname, { width - 12 - i * 28 + 4, 68, 24, 24 }, { radius = 12,
            fill = bragi and C.accent or C.sel, border = C.transparent })
        gitgud.setProperty(avatar, "CursorPassThroughEnabled", "true")
        gitgud.setProperty(avatar, "TooltipText", who)
        ui.label(avatar .. "Letter", avatar, { 0, 0, 24, 24 }, who:sub(1, 1):upper(),
            { font = "Bragi-12-Bold", colour = bragi and C.onAccent or C.text, align = "CentreAligned" })
    end

    gitgud.on(cname .. ".clicked", function()
        cardMenu(card, cname)
    end)
end

--- Build the columns (or an empty state) into BoardsColumns.
build = function()
    if built > 0 then
        gitgud.destroyWindow("BoardsBody" .. built)
    end
    built = built + 1
    local root = "BoardsBody" .. built
    gitgud.createWindow("DefaultWindow", root, "BoardsColumns")
    local _, _, w = gitgud.getRect("BoardsColumns")
    w = w or 1000

    gitgud.setText("BoardsTitle", text.escape(board and board.title or "Boards"))
    gitgud.setEnabled("BoardsNewTask", board ~= nil and state == "ready")

    if not server.info().signedIn then
        note(root, w, "Boards are coming",
            "Tasks and boards will live on this computer, beside your projects. They aren't in this build yet.")
        return
    end
    if state == "loading" and not board then
        local url = server.info().url or ""
        note(root, w, "Loading boards", url ~= "" and ("Asking " .. url .. ".") or "One moment.")
        return
    end
    if state == "error" then
        note(root, w, "The board couldn't be loaded", problem or "", "Try again", boards.load)
        return
    end
    if not board then
        note(root, w, "No boards yet",
            "Make one for your tasks; it starts with the usual columns. Boards of your repositories and organisations show here too.",
            "New board", newBoard)
        return
    end

    local cols = board.columns or {}
    local count = math.max(1, #cols)
    local colWidth = math.max(MIN_COLUMN, math.floor((w - 2 * PAD - (count - 1) * GAP) / count))
    local tallest = 0
    for i, col in ipairs(cols) do
        local x = PAD + (i - 1) * (colWidth + GAP)
        local name = root .. "Col" .. i
        local cards = col.cards or {}
        local height = 44 + #cards * (CARD_HEIGHT + 8) + 44
        tallest = math.max(tallest, height)
        ui.box(name, root, { x, PAD, colWidth, height }, { radius = 12, fill = C.rail, border = C.border })
        local tone = boards.tone(col.color)
        local nameX = 14
        if tone then
            ui.box(name .. "Tone", name, { 14, 17, 8, 8 }, { radius = 4, fill = tone, border = C.transparent })
            nameX = 32
        end
        ui.label(name .. "Name", name, { nameX, 12, colWidth - nameX - 44, 18 }, (col.title or ""):upper(),
            { font = "Bragi-Caps" })
        ui.label(name .. "Count", name, { colWidth - 44, 12, 30, 18 }, tostring(#cards),
            { font = "Bragi-13", colour = C.sub, align = "RightAligned" })
        local cy = 40
        for k, card in ipairs(cards) do
            drawCard(name .. "Card" .. k, name, card, 10, cy, colWidth - 20)
            cy = cy + CARD_HEIGHT + 8
        end
        local add = ui.button(name .. "Add", name, { 10, cy, colWidth - 20, 36 }, "+ Add",
            { font = "Bragi-13", colour = C.sub, quiet = true })
        local columnId = col.id
        gitgud.on(add .. ".clicked", function()
            boards.newTask(columnId)
        end)
    end
    gitgud.setProperty(root, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}",
        2 * PAD + count * colWidth + (count - 1) * GAP, PAD + tallest + PAD))
end

--- The open board, for scripts and tests.
function boards.current()
    return board
end

function boards.init()
    for i, m in ipairs(MODES) do
        local name = "BoardsMode_" .. m.id
        ui.button(name, "BoardsModes", { 3 + (i - 1) * 88, 3, 86, 32 }, m.label,
            { quiet = true, font = "Bragi-13-Bold" })
        if m.id == "board" then
            gitgud.on(name .. ".clicked", function()
                mode = m.id
                paintModes()
            end)
        else
            gitgud.setEnabled(name, false)
            gitgud.setProperty(name, "TooltipText", "Not designed yet")
        end
    end
    paintModes()
    gitgud.setEnabled("BoardsFilter", false)
    gitgud.on("BoardsSearch.clicked", commands.open)
    gitgud.on("BoardsTitle.clicked", pickBoard)
    gitgud.on("BoardsNewTask.clicked", function()
        boards.newTask(nil)
    end)

    app.subscribe("bragi.view", function(view)
        if view == "boards" then
            if state == "idle" and server.info().signedIn then
                boards.load()
            else
                build()
            end
        end
    end)
    local signedAs = nil
    app.subscribe("bragi.server", function(info)
        local now = info.signedIn and (info.url .. " " .. info.user) or ""
        if now == signedAs then
            return -- the same sign-in (the address field connects as you type)
        end
        signedAs = now
        board, projects = nil, {}
        state = "idle"
        if shell.view() == "boards" then
            if info.signedIn then
                boards.load()
            else
                build()
            end
        end
    end)
    app.subscribe("bragi.serverEvent", function(event)
        local kind = event.type or ""
        if board and (kind:match("^board") or kind:match("^issue") or kind:match("^pull") or kind:match("^agent")
            or kind == "feed.reset") then
            reloadSoon()
        end
    end)
    gitgud.on("window.resized", show)
end

return boards
