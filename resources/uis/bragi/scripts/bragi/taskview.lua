--- bragi/taskview.lua: a task's details, in a dialog over the board.
--
-- A click on a card (bragi/boards.lua) opens it, centred over the dimmed
-- board: the task's key and Copy link in the header; its title, description
-- (Markdown), steps and comments on the left; the primary action, Status,
-- Assignee, Board and the task's activity on the right (below, when the
-- window is narrow). The × button, a click on the dimmed area, or Escape
-- closes it; the card it came from has an accent outline meanwhile.
--
-- Steps are the description's checklist ("- [ ] ..."): ticking one saves
-- the description. The primary action is Open session while Bragi works
-- on the task, Reopen when it's closed, else Ask Bragi to start. Status
-- moves the card to another column (or closes the task), Assignee picks
-- Bragi, you, or no one. A comment that mentions @Bragi is also handed to
-- Bragi, as a session on the task. Copy link copies bragi://task/<owner>/
-- <name>/<number>; a click on such a link (bragi/links.lua) opens it here.
-- Everything goes through the store (bragi/server.lua's requests), and the
-- dialog draws itself again on the store's events for the task.
--
-- Public API: taskview.open(card, board), taskview.openLink(link),
-- taskview.close(), taskview.isOpen(), taskview.openFor(card),
-- taskview.current() (for tests: { issue, comments, sessions })

local C = require("core.palette")
local app = require("core.app")
local keys = require("core.keys")
local markdown = require("bragi.markdown")
local menu = require("ui.menu")
local popup = require("ui.popup")
local server = require("bragi.server")
local status = require("core.status")
local text = require("core.text")
local ui = require("bragi.ui")
local user = require("bragi.user")

local taskview = { name = "bragi.taskview" }

local SCRIM = "TaskViewScrim"
local DIALOG = "TaskView"
local API = "/api/bragi/v0"
local V1 = "/api/v1"
local MAX_WIDTH = 760
local TOP = 72
local SIDE = 240
local NARROW = 640        -- below this dialog width the side column goes under the main one
local HEADER = 60

local shown = nil   -- { card, board, issue, comments, sessions, token, reload, painted }
local built = 0     -- body windows made so far (each paint makes a new one)
local draft = ""    -- the comment being written (kept while the dialog redraws)
local typing = nil  -- { caret } while a paint redraws the comment box being typed in

-- ===================================================================
-- Data
-- ===================================================================

local function ago(iso)
    local t = text.isoTime(iso)
    return t and text.ago(t) or ""
end

--- The description and its checklist: { text = the rest, steps = { {text,
-- done, line} } } (line: the checklist line's number in the body).
local function split(body)
    local rest, steps = {}, {}
    local n = 0
    for line in (tostring(body or "") .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local mark, words = line:match("^%s*[-*+]%s+%[([ xX])%]%s+(.*)$")
        if mark then
            steps[#steps + 1] = { text = words, done = mark ~= " ", line = n }
        else
            rest[#rest + 1] = line
        end
    end
    -- A "Steps" heading the checklist came under goes with it.
    while #rest > 0 and (text.trim(rest[#rest]) == "" or rest[#rest]:match("^#*%s*[Ss]teps:?%s*$")) do
        rest[#rest] = nil
    end
    return { text = table.concat(rest, "\n"), steps = steps }
end

--- The body with checklist line `n` ticked or not.
local function withStep(body, n, done)
    local out, i = {}, 0
    for line in (tostring(body or "") .. "\n"):gmatch("([^\n]*)\n") do
        i = i + 1
        local l = line
        if i == n then
            l = l:gsub("%[[ xX]%]", done and "[x]" or "[ ]", 1)
        end
        out[#out + 1] = l
    end
    if out[#out] == "" then
        out[#out] = nil
    end
    return table.concat(out, "\n")
end

local function assigneeLabel(issue)
    local who = issue and issue.assignees and issue.assignees[1]
    if not who or who == "" then
        return "Unassigned"
    end
    return who:lower() == "bragi" and "Bragi" or who
end

--- The newest agent session on the task, or nil.
local function latestSession()
    local best = nil
    for _, s in ipairs(shown and shown.sessions or {}) do
        if not best or (s.updated or "") > (best.updated or "") then
            best = s
        end
    end
    return best
end

local function working()
    local s = latestSession()
    return s and (s.status == "working" or s.status == "waiting") and s or nil
end

--- The board column the card is in.
local function columnOf(board, card)
    for _, col in ipairs(board and board.columns or {}) do
        if col.id == card.column_id then
            return col
        end
    end
    return nil
end

local function taskPath()
    return V1 .. "/repos/" .. shown.card.repo .. "/issues/" .. shown.card.number
end

local function link()
    return "bragi://task/" .. shown.card.repo .. "/" .. shown.card.number
end

--- What a paint draws from, as text: a load that brings nothing new draws
-- nothing (nil when it can't tell).
local function drawn()
    local col = columnOf(shown.board, shown.card)
    return (gitgud.jsonEncode({ issue = shown.issue or false, comments = shown.comments, live = working() ~= nil,
        board = shown.board and shown.board.title or "", column = col and col.title or "" }))
end

local paint

--- Fetch the task, its comments and sessions; draw when all are back.
local function load()
    if not shown then
        return
    end
    local mine = shown
    local pending = 3
    local function settle()
        pending = pending - 1
        if pending == 0 and shown == mine then
            local now = drawn()
            if not now or now ~= mine.painted then
                paint()
            end
        end
    end
    server.request("GET", taskPath(), nil, function(issue)
        mine.issue = type(issue) == "table" and issue or mine.issue
        settle()
    end, function(msg)
        if not mine.issue and shown == mine then
            -- A link to a task that isn't there (any more).
            taskview.close()
            status.error("Couldn't open " .. mine.card.repo .. "#" .. mine.card.number .. ": " .. tostring(msg))
        end
        settle()
    end)
    server.request("GET", taskPath() .. "/comments", nil, function(list)
        mine.comments = type(list) == "table" and list or {}
        settle()
    end, settle)
    server.request("GET", API .. "/repos/" .. mine.card.repo .. "/issues/" .. mine.card.number .. "/sessions", nil,
        function(list)
            mine.sessions = type(list) == "table" and list or {}
            settle()
        end, settle)
end

--- Change the task; the store's event for it draws the change.
local function patch(body, okWords)
    server.request("PATCH", taskPath(), body, function()
        if okWords then
            status.ok(okWords)
        end
    end, function(msg)
        status.error(msg)
    end)
end

-- ===================================================================
-- Actions
-- ===================================================================

local function openSession(s)
    local agent = require("bragi.agent")
    local shell = require("bragi.shell")
    local id = s and s.conversation
    taskview.close()
    if id and id ~= "" then
        local tab = agent.tabFor(id)
        shell.show("agent")
        if tab then
            agent.showTab(tab)
        else
            agent.resume(id)
        end
        return
    end
    -- An older session that didn't say its conversation: a live tab on the task.
    for _, tab in ipairs(agent.tabs()) do
        local task = tab.session and tab.session.task
        if task and task.repo == s.repo and tonumber(task.number) == tonumber(s.issue) then
            shell.show("agent")
            agent.showTab(tab)
            return
        end
    end
    status.error("That session isn't open here any more.")
end

local function primary()
    local issue = shown.issue or {}
    local live = working()
    if live then
        openSession(live)
    elseif issue.state == "closed" then
        patch({ state = "open" }, "Reopened #" .. shown.card.number .. ".")
    else
        local card = shown.card
        server.request("PATCH", taskPath(), { assignee = "bragi" })
        taskview.close()
        require("bragi.boards").workOn(card)
    end
end

local function pickStatus(anchor)
    local items = {}
    local current = columnOf(shown.board, shown.card)
    for _, col in ipairs(shown.board and shown.board.columns or {}) do
        items[#items + 1] = {
            label = col.title,
            checked = current and current.id == col.id,
            action = function()
                if not current or current.id ~= col.id then
                    shown.card.column_id = col.id
                    require("bragi.boards").move(shown.card, col.id)
                end
            end,
        }
    end
    items[#items + 1] = { separator = true }
    local closed = shown.issue and shown.issue.state == "closed"
    items[#items + 1] = {
        label = closed and "Reopen the task" or "Close the task",
        action = function()
            patch({ state = closed and "open" or "closed" })
        end,
    }
    local x, y, _, h = gitgud.getRect(anchor)
    menu.popup(items, x or 0, (y or 0) + (h or 0))
end

local function pickAssignee(anchor)
    local now = shown.issue and shown.issue.assignees and shown.issue.assignees[1] or ""
    local function item(label, value)
        return {
            label = label,
            checked = (now or ""):lower() == value:lower(),
            action = function()
                patch({ assignee = value })
            end,
        }
    end
    local items = { item("Bragi", "bragi") }
    if user.current() ~= "" then
        items[#items + 1] = item(user.current(), user.current())
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = item("Unassigned", "")
    local x, y, _, h = gitgud.getRect(anchor)
    menu.popup(items, x or 0, (y or 0) + (h or 0))
end

local function postComment(edit)
    local body = text.trim(gitgud.getText(edit) or "")
    if body == "" then
        return
    end
    local card, issue = shown.card, shown.issue or {}
    local name = user.current()
    server.request("POST", taskPath() .. "/comments", { body = body, author = name ~= "" and name or nil }, function()
        draft = ""
        if (" " .. body:lower()):find("[^%w_]@bragi%f[^%w_]") then
            -- Asked of Bragi: a session on the task, with the comment.
            local ask = (issue.body or "") .. "\n\n" .. user.fill("{User} asks, in a comment on the task: ") .. body
            taskview.close()
            require("bragi.agent").workOn({ repo = card.repo, number = card.number, title = card.title, body = ask })
        end
    end, function(msg)
        status.error(msg)
    end)
end

-- ===================================================================
-- Drawing
-- ===================================================================

--- A plain square fill (the side column's corners).
local function fill(name, parent, a, colour)
    gitgud.createWindow("Gitgud/StaticText", name, parent)
    gitgud.setProperty(name, "Area", require("ui.geometry").rect(a[1], a[2], a[3], a[4]))
    gitgud.setProperty(name, "PanelColour", colour)
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    gitgud.setText(name, "")
    return name
end

--- The height a wrapped text drew at.
local function measured(name, fallback)
    local h = tonumber(gitgud.getProperty(name, "VertExtent") or "")
    return h and math.ceil(h) or fallback
end

local function section(name, parent, x, y, w, words)
    ui.label(name, parent, { x, y, w, 16 }, words:upper(), { font = "Bragi-Caps", colour = C.sub })
    return y + 16
end

--- A field button: a small label over the value, ▾ when it opens a picker.
local function field(name, parent, x, y, w, label, value, picks, onClick)
    ui.button(name, parent, { x, y, w, 50 }, "", { radius = 8 })
    gitgud.setProperty(name, "NormalFillColour", C.panel)
    gitgud.setProperty(name, "HoverFillColour", picks and C.hover or C.panel)
    gitgud.setProperty(name, "BorderColour", C.border)
    ui.label(name .. "Label", name, { 11, 7, w - 22, 15 }, label, { font = "Bragi-12", colour = C.sub })
    ui.label(name .. "Value", name, { 11, 24, w - 22, 18 },
        "[font='Bragi-13-Bold'][colour='" .. C.text .. "']" .. text.escape(value)
        .. (picks and ("  [colour='" .. C.sub .. "'][image-size='w:10 h:7'][vert-formatting='CentreAligned']"
            .. "[image='Gitgud-Images/Chevron']") or ""), { markup = true })
    if onClick then
        gitgud.on(name .. ".clicked", function()
            onClick(name)
        end)
    end
    return y + 50
end

--- The main column: title, description, steps, comments, the comment box.
local function drawMain(root, x, w)
    local issue = shown.issue or {}
    local y = 20
    local title = ui.paragraph(root .. "Title", root, { x, y, w, 30 }, issue.title or shown.card.title or "",
        { font = "Bragi-22-Bold" })
    local th = measured(title, 30)
    gitgud.setProperty(title, "Area", require("ui.geometry").rect(x, y, w, th))
    y = y + th + 12

    local parts = split(issue.body)
    if text.trim(parts.text) ~= "" then
        y = y + markdown.render(markdown.parse(parts.text), root, root .. "Desc", { x = x, y = y, width = w,
            font = "Bragi-14", bold = "Bragi-14-Bold", links = true }) + 6
    end

    y = section(root .. "StepsHead", root, x, y + 8, w, "Steps") + 10
    if #parts.steps == 0 then
        ui.label(root .. "NoSteps", root, { x, y, w, 20 }, "No steps yet. Ask Bragi to plan this task.",
            { font = "Bragi-13", colour = C.sub })
        y = y + 24
    end
    for i, step in ipairs(parts.steps) do
        local box = root .. "Step" .. i
        ui.box(box, root, { x, y + 4, 16, 16 }, { radius = 4, fill = step.done and C.accent or C.well,
            border = step.done and C.accent or C.borderStrong })
        if step.done then
            local tick = box .. "Tick"
            gitgud.createWindow("Gitgud/Icon", tick, box)
            gitgud.setProperty(tick, "Area", "{{0,0},{0,0},{1,0},{1,0}}")
            gitgud.setProperty(tick, "GlowColour", "00000000")
            gitgud.setProperty(tick, "CursorPassThroughEnabled", "true")
            gitgud.setProperty(tick, "IconImage", "Bragi-Icons/CheckMark")
            gitgud.setProperty(tick, "IconColour", C.onAccent)
        end
        local words = ui.paragraph(box .. "Text", root, { x + 28, y + 2, w - 28, 20 }, step.text,
            { font = "Bragi-14", colour = step.done and C.sub or C.text })
        local h = math.max(22, measured(words, 20))
        gitgud.setProperty(words, "Area", require("ui.geometry").rect(x + 28, y + 2, w - 28, h))
        -- The whole row toggles it.
        local hit = ui.button(box .. "Hit", root, { x - 4, y, w + 8, h + 4 }, "", { quiet = true })
        gitgud.setProperty(hit, "HoverFillColour", C.transparent)
        gitgud.setProperty(hit, "PushedFillColour", C.transparent)
        local line, done, words = step.line, step.done, step.text
        gitgud.on(hit .. ".clicked", function()
            -- Ticked in the description as it is now (Bragi may have changed
            -- it since this paint): the step with these words nearest its line.
            local mine = shown
            server.request("GET", taskPath(), nil, function(now)
                if shown ~= mine then
                    return
                end
                local current = type(now) == "table" and now.body or ""
                local best = nil
                for _, s in ipairs(split(current).steps) do
                    if s.text == words and (not best or math.abs(s.line - line) < math.abs(best.line - line)) then
                        best = s
                    end
                end
                if best then
                    patch({ body = withStep(current, best.line, not done) })
                end
            end, function(msg)
                status.error(msg)
            end)
        end)
        y = y + h + 10
    end

    local comments = shown.comments or {}
    y = section(root .. "CommentsHead", root, x, y + 8, w, #comments > 0 and ("Comments  " .. #comments) or "Comment")
        + 10
    for i, c in ipairs(comments) do
        local who = c.author and c.author ~= "" and (c.author:lower() == "bragi" and "Bragi" or c.author) or "Comment"
        ui.label(root .. "CommentWho" .. i, root, { x, y, w, 18 },
            "[font='Bragi-13-Bold'][colour='" .. (who == "Bragi" and C.accentText or C.text) .. "']"
            .. text.escape(who) .. "[font='Bragi-12'][colour='" .. C.sub .. "']   " .. text.escape(ago(c.created_at)),
            { markup = true })
        y = y + 22
        y = y + markdown.render(markdown.parse(c.body or ""), root, root .. "Comment" .. i .. "_",
            { x = x, y = y, width = w, font = "Bragi-14", bold = "Bragi-14-Bold", links = true }) + 12
    end

    local boxName = root .. "Write"
    ui.box(boxName, root, { x, y, w, 64 }, { radius = 8, fill = C.well, border = C.border })
    local edit = boxName .. "Edit"
    gitgud.createWindow("Gitgud/MultiLineEditbox", edit, boxName)
    gitgud.setProperty(edit, "Area", "{{0,6},{0,4},{1,-6},{1,-4}}")
    gitgud.setProperty(edit, "Font", "Bragi-14")
    gitgud.setProperty(edit, "BgColour", C.transparent)
    gitgud.setProperty(edit, "BorderColour", C.transparent)
    gitgud.setText(edit, draft)
    if typing then
        gitgud.focus(edit)
        if typing.caret then
            gitgud.setProperty(edit, "CaretIndex", tostring(typing.caret))
        end
    end
    local hint = ui.label(boxName .. "Hint", boxName, { 12, 10, w - 24, 18 }, "Write a comment, or @Bragi to ask it",
        { font = "Bragi-14", colour = C.sub })
    gitgud.setVisible(hint, draft == "")
    local send = ui.button(root .. "Send", root, { x + w - 96, y + 72, 96, 34 }, "Comment", { primary = true })
    gitgud.setVisible(send, draft ~= "")
    gitgud.on(edit .. ".changed", function()
        draft = gitgud.getText(edit) or ""
        gitgud.setVisible(hint, draft == "")
        gitgud.setVisible(send, text.trim(draft) ~= "")
    end)
    gitgud.on(send .. ".clicked", function()
        postComment(edit)
    end)
    y = y + 64 + 50
    return y
end

--- The side column: primary action, fields, activity.
local function drawSide(root, x, y0, w)
    local issue = shown.issue or {}
    local y = y0 + 20
    local inner = w - 40
    local live = working()
    local label = live and "Open session" or (issue.state == "closed" and "Reopen" or "Ask Bragi to start")
    local act = ui.button(root .. "Primary", root, { x + 20, y, inner, 44 }, label, { primary = true,
        font = "Bragi-14-Bold" })
    gitgud.on(act .. ".clicked", primary)
    y = y + 44 + 10

    local col = columnOf(shown.board, shown.card)
    local statusWords = issue.state == "closed" and "Closed" or (col and col.title or "Open")
    y = field(root .. "Status", root, x + 20, y, inner, "Status", statusWords, true, pickStatus) + 10
    y = field(root .. "Assignee", root, x + 20, y, inner, "Assignee", assigneeLabel(issue), true, pickAssignee) + 10
    y = field(root .. "Board", root, x + 20, y, inner, "Board", shown.board and shown.board.title or "", false) + 18

    y = section(root .. "ActivityHead", root, x + 20, y, inner, "Activity") + 8
    local events = issue.events or {}
    if #events == 0 then
        -- A store with no history (bragi/store.lua's says Created itself).
        events = { { text = "Created", at = issue.created_at } }
    end
    for i, e in ipairs(events) do
        if i > 8 then
            break
        end
        local line = ui.paragraph(root .. "Activity" .. i, root, { x + 20, y, inner, 18 },
            (e.text or "") .. (e.at and e.at ~= "" and (" \u{00B7} " .. ago(e.at)) or ""),
            { font = "Bragi-13", colour = C.sub })
        local h = math.max(18, measured(line, 18))
        gitgud.setProperty(line, "Area", require("ui.geometry").rect(x + 20, y, inner, h))
        y = y + h + 6
    end
    return y + 14
end

--- Draw the body (both columns) into `root`; its height.
local function drawBody(root, width, narrow)
    local geometry = require("ui.geometry")
    local mainW = narrow and width or (width - SIDE)
    local mainH = drawMain(root, 24, mainW - 48)
    local side = root .. "Side"
    local bodyH
    if narrow then
        -- Under the main column: rounded at the dialog's bottom corners only.
        ui.box(side, root, { 0, mainH, width - 2, 10 }, { radius = 16, fill = C.rail, border = C.transparent })
        gitgud.setProperty(side, "CursorPassThroughEnabled", "true")
        local sideH = drawSide(root, 0, mainH, width - 2) - mainH
        bodyH = mainH + sideH
        gitgud.setProperty(side, "Area", geometry.rect(0, mainH, width - 2, sideH))
        fill(side .. "CornerL", root, { 0, mainH, 16, 16 }, C.rail)
        fill(side .. "CornerR", root, { width - 18, mainH, 16, 16 }, C.rail)
        ui.rule(side .. "Rule", root, { 0, mainH, width, 1 })
    else
        -- Beside it: its top corners and bottom-left squared, its
        -- bottom-right following the dialog's.
        ui.box(side, root, { mainW, 0, SIDE - 2, 10 }, { radius = 16, fill = C.rail, border = C.transparent })
        gitgud.setProperty(side, "CursorPassThroughEnabled", "true")
        local sideH = drawSide(root, mainW, 0, SIDE - 2)
        bodyH = math.max(mainH, sideH)
        gitgud.setProperty(side, "Area", geometry.rect(mainW, 0, SIDE - 2, bodyH))
        fill(side .. "CornerTL", root, { mainW, 0, 16, 16 }, C.rail)
        fill(side .. "CornerTR", root, { mainW + SIDE - 18, 0, 16, 16 }, C.rail)
        fill(side .. "CornerBL", root, { mainW, bodyH - 16, 16, 16 }, C.rail)
        ui.rule(side .. "Rule", root, { mainW, 0, 1, bodyH })
    end
    return bodyH
end

paint = function()
    if not shown then
        return
    end
    local geometry = require("ui.geometry")
    local _, _, rootW, rootH = gitgud.getRect("Root")
    rootW, rootH = rootW or 1360, rootH or 860
    local width = math.min(MAX_WIDTH, rootW - 48)
    local x0 = math.floor((rootW - width) / 2)
    local narrow = width < NARROW

    gitgud.setProperty(SCRIM, "Area", "{{0,0},{0,0},{1,0},{1,0}}")
    local key = (shown.board and shown.board.title and (shown.board.title .. "  /  ") or "") .. shown.card.repo
        .. "#" .. shown.card.number
    gitgud.setText(DIALOG .. "Key", text.escape(key))

    -- The body, drawn anew each time: in the dialog itself when it fits;
    -- in the scroll pane (sized first) only when it doesn't, so a pane never
    -- shows scrollbars for content that fits.
    local maxH = rootH - TOP - 24
    -- Typing in the comment box: the new one gets the focus and the caret.
    local edit = built > 0 and (DIALOG .. "Body" .. built .. "WriteEdit") or nil
    typing = edit and gitgud.getRect(edit) and gitgud.textInputFocused()
        and { caret = tonumber(gitgud.getProperty(edit, "CaretIndex") or "") } or nil
    local function body(parent)
        if built > 0 then
            gitgud.destroyWindow(DIALOG .. "Body" .. built)
        end
        built = built + 1
        local root = DIALOG .. "Body" .. built
        gitgud.createWindow("DefaultWindow", root, parent)
        gitgud.setProperty(root, "Area", parent == DIALOG and geometry.rect(1, HEADER, width - 2, 10)
            or geometry.rect(0, 0, width - 2, 10))
        local bodyH = drawBody(root, width, narrow)
        gitgud.setProperty(root, "Area", parent == DIALOG and geometry.rect(1, HEADER, width - 2, bodyH)
            or geometry.rect(0, 0, width - 2, bodyH))
        return bodyH
    end
    local height
    gitgud.setVisible(DIALOG .. "Scroll", false)
    local bodyH = body(DIALOG)
    if HEADER + bodyH + 2 > maxH then
        height = maxH
        gitgud.setProperty(DIALOG .. "Scroll", "Area", geometry.rect(1, HEADER, width - 2, height - HEADER - 1))
        gitgud.setVisible(DIALOG .. "Scroll", true)
        body(DIALOG .. "Scroll")
    else
        height = HEADER + bodyH + 2
    end
    gitgud.setProperty(DIALOG, "Area", geometry.rect(x0, TOP, width, height))
    gitgud.setProperty(DIALOG .. "Key", "Area", geometry.rect(20, 0, width - 200, HEADER))
    gitgud.setProperty(DIALOG .. "Copy", "Area", geometry.rect(width - 148, 13, 96, 34))
    gitgud.setProperty(DIALOG .. "Close", "Area", geometry.rect(width - 46, 14, 32, 32))
    gitgud.setProperty(DIALOG .. "Rule", "Area", geometry.rect(0, HEADER - 1, width, 1))
    shown.painted = drawn()
end

-- ===================================================================
-- Opening and closing
-- ===================================================================

local function create()
    if gitgud.getRect(DIALOG) then
        return
    end
    -- Its own backdrop: a click on it closes the dialog (the shared one
    -- ignores clicks).
    ui.button(SCRIM, "Root", "{{0,0},{0,0},{1,0},{1,0}}", "", { quiet = true })
    gitgud.setProperty(SCRIM, "NormalFillColour", C.shade)
    gitgud.setProperty(SCRIM, "HoverFillColour", C.shade)
    gitgud.setProperty(SCRIM, "PushedFillColour", C.shade)
    gitgud.setProperty(SCRIM, "AlwaysOnTop", "true")
    gitgud.setVisible(SCRIM, false)
    gitgud.on(SCRIM .. ".clicked", taskview.close)

    ui.box(DIALOG, "Root", { 0, 0, 100, 100 }, { radius = 16, fill = C.panel, border = C.border })
    gitgud.setProperty(DIALOG, "AlwaysOnTop", "true")
    gitgud.setVisible(DIALOG, false)
    ui.label(DIALOG .. "Key", DIALOG, { 20, 0, 400, HEADER }, "", { font = "Bragi-Mono-11", colour = C.sub })
    ui.button(DIALOG .. "Copy", DIALOG, { 0, 13, 96, 34 }, "Copy link", { font = "Bragi-13-Bold" })
    ui.button(DIALOG .. "Close", DIALOG, { 0, 14, 32, 32 }, "\u{00D7}", { quiet = true, font = "Bragi-18-Bold",
        colour = C.sub, tooltip = "Close details" })
    ui.rule(DIALOG .. "Rule", DIALOG, { 0, HEADER - 1, 100, 1 })
    gitgud.createWindow("Gitgud/ScrollablePane", DIALOG .. "Scroll", DIALOG)
    gitgud.on(DIALOG .. "Close.clicked", taskview.close)
    gitgud.on(DIALOG .. "Copy.clicked", function()
        if shown and gitgud.setClipboard(link()) then
            status.ok("Copied " .. link() .. ".")
        end
    end)
end

local function outline()
    -- The card's accent outline: the board draws it while its task is open.
    local boards = require("bragi.boards")
    if boards.repaint then
        boards.repaint()
    end
end

--- Open a card's task over the board.
-- @param card   a board card: { issue_id, repo, number, title, column_id, ... }
-- @param board  the board it's on (GET /projects/{id})
function taskview.open(card, board)
    create()
    if shown then
        keys.popEscape(shown.token)
    end
    draft = ""
    shown = { card = card, board = board, comments = {}, sessions = {} }
    shown.token = keys.pushEscape(taskview.close)
    gitgud.setVisible(SCRIM, true)
    gitgud.bringToFront(SCRIM)
    gitgud.setVisible(DIALOG, true)
    gitgud.bringToFront(DIALOG)
    paint()
    outline()
    load()
end

--- Open a task link (bragi://task/<owner>/<name>/<number>): on the board
-- it's on, when the open board has it.
function taskview.openLink(l)
    local repo, number = tostring(l.target or ""):match("^bragi://task/([^/]+/[^/]+)/(%d+)")
    if not repo then
        return false
    end
    local shell = require("bragi.shell")
    local boards = require("bragi.boards")
    shell.show("boards")
    local board = boards.current()
    for _, col in ipairs(board and board.columns or {}) do
        for _, card in ipairs(col.cards or {}) do
            if card.repo == repo and tonumber(card.number) == tonumber(number) then
                taskview.open(card, board)
                return true
            end
        end
    end
    -- Not on the open board: the task alone.
    taskview.open({ repo = repo, number = tonumber(number), title = "" }, nil)
    return true
end

function taskview.close()
    if not shown then
        return
    end
    keys.popEscape(shown.token)
    shown = nil
    popup.close()
    gitgud.setVisible(DIALOG, false)
    gitgud.setVisible(SCRIM, false)
    outline()
end

function taskview.isOpen()
    return shown ~= nil
end

--- Whether `card`'s task is the one open.
function taskview.openFor(card)
    return shown ~= nil and card ~= nil and shown.card.repo == card.repo
        and tonumber(shown.card.number) == tonumber(card.number)
end

--- What's shown, for tests.
function taskview.current()
    return shown
end

function taskview.init()
    app.subscribe("bragi.serverEvent", function(event)
        if not shown then
            return
        end
        local kind = event.type or ""
        local ours = (event.repo == nil or event.repo == shown.card.repo)
            and (event.number == nil and event.issue == nil
                or tonumber(event.number or event.issue) == tonumber(shown.card.number))
        if kind:match("^board") then
            -- Only the open board's: the card may be on it.
            local open = require("bragi.boards").current()
            ours = ours and (event.project_id == nil or (open and tonumber(open.id) == tonumber(event.project_id)))
        end
        if ours and (kind:match("^issue") or kind:match("^agent") or kind:match("^board")) then
            if shown.reload then
                gitgud.cancelTimer(shown.reload)
            end
            shown.reload = gitgud.after(250, function()
                if shown then
                    shown.reload = nil
                    -- The card may have moved, or come onto the open board,
                    -- or gone off it: take its column from the board.
                    local board = require("bragi.boards").current()
                    local found = nil
                    for _, col in ipairs(board and board.columns or {}) do
                        for _, card in ipairs(col.cards or {}) do
                            if taskview.openFor(card) then
                                found = card
                                shown.card.column_id = col.id
                            end
                        end
                    end
                    if found then
                        shown.card.issue_id = shown.card.issue_id or found.issue_id
                        shown.board = board
                    elseif board and shown.board and shown.board.id == board.id then
                        shown.board = nil
                    end
                    load()
                end
            end)
        end
    end)
    gitgud.on("window.resized", function()
        if shown then
            paint()
        end
    end)
    require("bragi.links").onTask(taskview.openLink)
end

return taskview
