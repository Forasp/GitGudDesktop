--- tests/ui/bragi-store.lua: the local store (bragi/store.lua) and the
-- Boards and Wiki views on it: projects keyed by repository; tasks, their
-- comments and states; boards, cards added, placed, moved, and taken off;
-- agent sessions; wikis as bare Git repositories (pages made, edited,
-- renamed, removed, their history and old revisions, images, search);
-- events; writes that are whole or not at all. Then the views draw it and
-- change it through the store, and without a store both say they're
-- coming. Also checks bragi/markdown.lua and Tab in a dialog's fields.
--
-- Run it like bragi.lua (GITGUD_UI=bragi, scratch APPDATA and LOCALAPPDATA,
-- a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing here,
-- GITGUD_SHOTS for screenshots). Prints "[check] ..." lines.

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

if gitgud.currentUi().id ~= "bragi" then
    print("[ui-test] needs GITGUD_UI=bragi")
    return
end

local C = require("core.palette")
local app = require("core.app")
local boards = require("bragi.boards")
local markdown = require("bragi.markdown")
local server = require("bragi.server")
local shell = require("bragi.shell")
local store = require("bragi.store")
local wiki = require("bragi.wiki")

local function shot(name)
    gitgud.screenshot(OUT .. "/store-" .. name .. ".png")
end
local function clickWidget(name, button)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, button or "left")
end
local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end
--- The text of the newest widget named prefix .. n .. suffix.
local function newest(prefix, suffix)
    for n = 200, 1, -1 do
        if gitgud.getRect(prefix .. n .. suffix) then -- getText gives "" for a missing widget
            return gitgud.getText(prefix .. n .. suffix)
        end
    end
    return nil
end

-- ===================================================================
-- The local store, recorded
-- ===================================================================

-- Requests go to the local store (bragi/store.lua); this keeps a list.
local sent = {}
local realRequest = server.request
server.request = function(method, path, body, onDone, onError)
    sent[#sent + 1] = { method = method, path = path, body = body }
    return realRequest(method, path, body, onDone, onError)
end

-- Events the store publishes.
local events = {}
app.subscribe("bragi.serverEvent", function(event)
    events[#events + 1] = event
end)

local function eventOf(kind)
    for i = #events, 1, -1 do
        if events[i].type == kind then
            return events[i]
        end
    end
    return nil
end

--- The store's answer at once (value, or nil and why).
local function ask(method, path, body)
    local value, err = store.answer(method, path, body)
    if err then
        print("[ui-test] " .. method .. " " .. path .. ": " .. err)
    end
    return value, err
end

local function why(method, path, body)
    local _, err = store.answer(method, path, body)
    return err
end

local seeded = {} -- what the store steps made, for the views' steps
local PAGE = table.concat({
    "Welcome to the **shared** wiki.",
    "",
    "## Setup",
    "",
    "1. Clone with `git clone`",
    "2. Read [the guide](guides/Deep-Dive)",
    "   - nested *point*",
    "- [x] done task",
    "",
    "```lua",
    "print('[hi]')",
    "```",
    "",
    "> a quote",
    "",
    "---",
    "",
    "| Name | Port |",
    "| ---- | ---- |",
    "| fork | 3001 |",
}, "\n")
local function lastSent(method, pattern)
    for i = #sent, 1, -1 do
        if sent[i].method == method and sent[i].path:match(pattern) then
            return sent[i]
        end
    end
    return nil
end
-- ===================================================================
-- The store itself
-- ===================================================================

local ISSUES = "/api/v1/repos/local/repo/issues"
local PROJECTS = "/api/bragi/v0/projects/"

step(300, "the store: projects and tasks", function()
    local here = require("core.repo").state().path
    local own = store.repoOf(here)
    check("the open repository is a project", own == "local/repo" and store.repoOf(here) == own
        and server.repoOf(here) == own and boards.serverRepo() == own)
    check("another folder of the same name is another project",
        store.repoOf(here .. "-elsewhere/repo") == "local/repo-2")
    local t1 = ask("POST", ISSUES, { title = "Fix the login form", body = "The form loses focus.", labels = { "bug" } })
    local t2 = ask("POST", ISSUES, { title = "Boards view" })
    check("tasks are numbered in their project", t1 and t1.number == 1 and t2 and t2.number == 2
        and t1.id ~= t2.id)
    check("with their labels", t1 and t1.labels[1] and t1.labels[1].name == "bug")
    check("an event says so", eventOf("issue.created") ~= nil and eventOf("issue.created").repo == "local/repo")
    check("a task needs a title", why("POST", ISSUES, { title = " " }) == "A task needs a title")
    local other = ask("POST", "/api/v1/repos/local/repo-2/issues", { title = "Elsewhere" })
    check("another project's tasks start at 1", other and other.number == 1)
    local got = ask("GET", ISSUES .. "/1")
    check("a task reads back", got and got.title == "Fix the login form" and got.body == "The form loses focus."
        and got.state == "open")
    local closed = ask("PATCH", ISSUES .. "/2", { state = "closed" })
    check("a task closes", closed and closed.state == "closed" and closed.closed_at ~= nil)
    check("tasks list by state", #ask("GET", ISSUES) == 1 and #ask("GET", ISSUES .. "?state=all") == 2)
    ask("PATCH", ISSUES .. "/2", { state = "open" })
    local c = ask("POST", ISSUES .. "/1/comments", { body = "Working on it." })
    local edited = ask("PATCH", "/api/v1/repos/local/repo/issues/comments/" .. tostring(c and c.id), { body = "Done soon." })
    local comments = ask("GET", ISSUES .. "/1/comments")
    check("comments added and edited", c and edited and edited.id == c.id and #comments == 1
        and comments[1].body == "Done soon.")
    check("what isn't there is not found", why("GET", "/api/v1/repos/local/nowhere/issues/1") == "Not found"
        and why("GET", ISSUES .. "/99") == "Not found" and why("GET", "/api/bragi/v0/what") ~= nil)
    seeded.t1, seeded.t2 = t1, t2
end, { full = true }) -- it acts on the store as it reads: never tried early

step(300, "the store: boards and cards", function()
    local b = ask("POST", "/api/bragi/v0/users/me/projects", { title = "Sprint", template = "basic_kanban" })
    local board = ask("GET", PROJECTS .. b.id)
    check("a board starts with the usual columns", #board.columns == 3 and board.columns[1].title == "To do"
        and board.columns[1].default and board.columns[3].title == "Done")
    local doing, done = board.columns[2].id, board.columns[3].id
    ask("POST", PROJECTS .. b.id .. "/cards", { issue_id = seeded.t1.id })
    ask("POST", PROJECTS .. b.id .. "/cards", { repo = "local/repo", number = 2, column_id = doing })
    board = ask("GET", PROJECTS .. b.id)
    check("a new card lands in the default column", board.columns[1].cards[1]
        and board.columns[1].cards[1].title == "Fix the login form" and board.columns[1].cards[1].repo == "local/repo")
    check("or in the column asked for", board.columns[2].cards[1] and board.columns[2].cards[1].number == 2)
    local t3 = ask("POST", ISSUES, { title = "Write the docs" })
    ask("POST", PROJECTS .. b.id .. "/cards", { issue_id = t3.id, position = 0 })
    board = ask("GET", PROJECTS .. b.id)
    check("a position puts a card before the one there", board.columns[1].cards[1].number == 3
        and board.columns[1].cards[2].number == 1)
    local moved = ask("POST", PROJECTS .. b.id .. "/cards/" .. t3.id .. "/move", { column_id = done })
    check("a card moves", moved and moved.column_id == done
        and eventOf("board.card.moved") and eventOf("board.card.moved").project_id == b.id)
    ask("DELETE", PROJECTS .. b.id .. "/cards/" .. t3.id)
    board = ask("GET", PROJECTS .. b.id)
    check("a card comes off", #board.columns[3].cards == 0 and #board.columns[1].cards == 1)
    local rb = ask("POST", "/api/bragi/v0/repos/local/repo/projects", { title = "Bugs", template = "bug_triage" })
    check("a project's board takes its own tasks only",
        (why("POST", PROJECTS .. rb.id .. "/cards", { repo = "local/repo-2", number = 1 }) or ""):find("local/repo", 1, true) ~= nil)
    check("boards are listed where they belong", #ask("GET", "/api/bragi/v0/users/me/projects") == 1
        and #ask("GET", "/api/bragi/v0/repos/local/repo/projects?state=open") == 1
        and #ask("GET", "/api/v1/user/orgs") == 0)
    ask("PATCH", PROJECTS .. rb.id, { state = "closed" })
    check("a closed board leaves the open list", #ask("GET", "/api/bragi/v0/repos/local/repo/projects") == 0
        and #ask("GET", "/api/bragi/v0/repos/local/repo/projects?state=all") == 1)
    ask("DELETE", PROJECTS .. rb.id)
    check("a deleted board is gone", why("GET", PROJECTS .. rb.id) == "Not found")
    seeded.board, seeded.done = b.id, done
end, { full = true }) -- it acts on the store as it reads: never tried early

step(300, "the store: agent sessions", function()
    local s = ask("POST", "/api/bragi/v0/repos/local/repo/issues/2/sessions",
        { status = "working", summary = "Drawing columns", title = "Boards view" })
    local patched = ask("PATCH", "/api/bragi/v0/sessions/" .. tostring(s and s.id), { status = "done", comment_id = 5 })
    local list = ask("GET", "/api/bragi/v0/repos/local/repo/sessions?limit=50")
    check("a session on a task, recorded and updated", s and patched and #list == 1 and list[1].status == "done"
        and list[1].issue == 2 and list[1].repo == "local/repo" and list[1].comment_id == 5
        and list[1].summary == "Drawing columns")
    check("not on a task that isn't there", why("POST", "/api/bragi/v0/repos/local/repo/issues/42/sessions", {}) == "Not found")
    ask("POST", "/api/bragi/v0/repos/local/repo/issues/2/sessions", { status = "working", summary = "Drawing columns" })
    check("newest first", ask("GET", "/api/bragi/v0/repos/local/repo/issues/2/sessions")[1].status == "working")
end, { full = true }) -- it acts on the store as it reads: never tried early

step(300, "the store: wikis", function()
    local SHARED = "/api/v1/repos/local/shared/wiki"
    local home = ask("POST", SHARED .. "/new", { title = "Home", content_base64 = wiki.base64(PAGE), message = "Add Home" })
    check("a page is made", home and home.sub_url == "Home" and home.content == PAGE)
    ask("POST", SHARED .. "/new", { title = "guides/Deep Dive", content_base64 = wiki.base64("# Deep Dive\n\nPipelines."),
        message = "Add the guide" })
    check("one page per title", why("POST", SHARED .. "/new", { title = "Home", content_base64 = "" }) ~= nil)
    local pages = ask("GET", "/api/bragi/v0/repos/local/shared/wiki/pages")
    check("pages listed by path, folders too", #pages == 2 and pages[1].sub_url == "Home"
        and pages[2].sub_url == "guides/Deep-Dive" and pages[2].title == "Deep Dive" and pages[2].path == "guides/Deep-Dive.md")
    local first = ask("GET", "/api/bragi/v0/repos/local/shared/wiki/page/Home?html=false").ref
    ask("PATCH", SHARED .. "/page/Home", { title = "Home", content_base64 = wiki.base64("# Home\n\nSecond."),
        message = "Update Home" })
    check("an edit is kept", ask("GET", "/api/bragi/v0/repos/local/shared/wiki/page/Home").content == "# Home\n\nSecond.")
    check("the old text at its revision",
        ask("GET", "/api/bragi/v0/repos/local/shared/wiki/page/Home?ref=" .. tostring(first)).content == PAGE)
    local revs = ask("GET", SHARED .. "/revisions/Home")
    check("its history", revs.count == 2 and revs.commits[1].message == "Update Home"
        and revs.commits[2].message == "Add Home")
    ask("PATCH", SHARED .. "/page/Home", { title = "Home", content_base64 = wiki.base64(PAGE), message = "Back" })

    local REPO = "/api/v1/repos/local/repo/wiki"
    ask("POST", REPO .. "/new", { title = "Notes", content_base64 = wiki.base64("Pipelines and builds.") })
    local renamed = ask("PATCH", REPO .. "/page/Notes", { title = "Build Notes" })
    check("a new title renames the page, text and all", renamed and renamed.sub_url == "Build-Notes"
        and renamed.content == "Pipelines and builds."
        and why("GET", "/api/bragi/v0/repos/local/repo/wiki/page/Notes") == "Not found")
    local up = ask("PUT", "/api/bragi/v0/repos/local/repo/wiki/files/images/logo.png", "\137PNG")
    check("an image is a file in the wiki", up and up.size == 4
        and ask("GET", "/api/bragi/v0/repos/local/repo/wiki/files/images/logo.png") == "\137PNG")
    check("pages only through the page calls", why("PUT", "/api/bragi/v0/repos/local/repo/wiki/files/x.md", "x") ~= nil)

    local hits = ask("GET", "/api/bragi/v0/wikis/search?limit=50&q=pipelines")
    check("search finds pages in every wiki", #hits == 2)
    check("every word must be there", #ask("GET", "/api/bragi/v0/wikis/search?q=pipelines+builds") == 1)
    local deep = nil
    for _, h in ipairs(hits) do
        if h.sub_url == "guides/Deep-Dive" then
            deep = h
        end
    end
    check("a hit names its wiki, page, and lines", deep and deep.repo == "local/shared" and deep.shared
        and deep.lines[1] and deep.lines[1].number == 3 and deep.lines[1].text == "Pipelines.")
    local wikis = ask("GET", "/api/bragi/v0/wikis?limit=50")
    check("the shared wiki first, then the project's", wikis[1].repo == "local/shared" and wikis[1].shared
        and wikis[2] and wikis[2].repo == "local/repo" and wikis[2].can_write)
    check("each wiki is a bare Git repository", gitgud.pathExists(gitgud.configPath("bragi/wikis/shared.wiki.git") .. "/HEAD")
        and #gitgud.bareLog("bragi/wikis/shared.wiki.git") == 4)
    check("wiki changes are events", eventOf("wiki.page.updated") ~= nil)
    ask("DELETE", REPO .. "/page/Build-Notes")
    check("a page is removed", why("GET", "/api/bragi/v0/repos/local/repo/wiki/page/Build-Notes") == "Not found")
end, { full = true }) -- it acts on the store as it reads: never tried early

-- The wiki tools for Claude Code (bragi/wikitool.lua), as quick answers use them.
local toolAnswers = {}
step(300, "the wiki tools", function()
    local uitools = require("bragi.uitools")
    for _, call in ipairs({
        { tool = "bragi_wiki_list", arguments = {} },
        { tool = "bragi_wiki_read", arguments = { page = "guides/Deep Dive" } },
        { tool = "bragi_wiki_read", arguments = { page = "Nowhere", wiki = "shared" } },
        { tool = "bragi_wiki_search", arguments = { query = "pipelines" } },
    }) do
        call.session = "bragi-quick1"
        local n = #toolAnswers + 1
        toolAnswers[n] = false -- answers come in any order: each keeps its place
        uitools.handle(call, function(answer, isError)
            toolAnswers[n] = { text = answer, isError = isError }
        end)
    end
end, { full = true })

step(500, "the wiki tools answer", function()
    local function answer(i)
        return toolAnswers[i] or { text = "" }
    end
    check("they're declared read-only", (function()
        for _, d in ipairs(require("bragi.uitools").definitions()) do
            if d.name == "bragi_wiki_search" then
                return d.annotations and d.annotations.readOnlyHint == true and d.sessions == nil
            end
        end
        return false
    end)())
    local uitools = require("bragi.uitools")
    check("they need no permission card", uitools.noCard("mcp__repo__bragi_wiki_search", "bragi-quick1")
        and uitools.noCard("mcp__repo__bragi_wiki_read", "bragi-main") and uitools.noCard("mcp__repo__bragi_wiki_list", nil))
    local rules = table.concat(uitools.allowRules("bragi-main"), " ")
    check("and are on every session's allow list", rules:find("mcp__repo__bragi_wiki_search", 1, true) ~= nil
        and rules:find("mcp__repo__bragi_settings_get", 1, true) ~= nil)
    check("list names the wikis and pages", #toolAnswers == 4 and answer(1).text:find("Wiki shared:", 1, true)
        and answer(1).text:find("- guides/Deep-Dive", 1, true) and answer(1).text:find("Wiki repo:", 1, true))
    check("read finds a page by its title", answer(2).text:find("Pipelines.", 1, true) ~= nil and not answer(2).isError)
    check("a missing page is an error", answer(3).isError == true)
    check("search shows pages and lines", answer(4).text:find("guides/Deep-Dive (wiki shared)", 1, true)
        and answer(4).text:find("3: Pipelines.", 1, true))
end)

step(300, "the store: writes are whole or not at all", function()
    local names = {}
    for _, f in ipairs(gitgud.configList("bragi/store/repo")) do
        names[#names + 1] = f.name
    end
    check("only the data files, no temporary ones (" .. table.concat(names, ",") .. ")",
        table.concat(names, ",") == "boards.json,sessions.json,tasks.json")
    -- A folder where the temporary file goes: the write fails.
    local before = gitgud.configRead("bragi/store/repo-2/tasks.json")
    gitgud.makeDir(gitgud.configPath("bragi/store/repo-2/tasks.json.tmp"))
    check("a write that fails is reported", why("POST", "/api/v1/repos/local/repo-2/issues", { title = "Never" }) ~= nil)
    check("and leaves the file as it was", before ~= nil and gitgud.configRead("bragi/store/repo-2/tasks.json") == before)
end, { full = true }) -- it acts on the store as it reads: never tried early


-- ===================================================================
-- Markdown (no server needed)
-- ===================================================================

step(200, "the server repository from the remote's address", function()
    -- A port without a user part read "0" as the host (2026-10-15).
    local repoModule = require("core.repo")
    local realRemote, realPrimary = repoModule.remote, repoModule.primaryRemote
    local realRepoOf, realInfo = server.repoOf, server.info
    server.repoOf = function()
        return nil
    end
    server.info = function()
        return { url = "http://server.test:8080", user = "sam", signedIn = true }
    end
    local url = ""
    repoModule.primaryRemote = function()
        return "origin"
    end
    repoModule.remote = function()
        return { url = url }
    end
    local function from(u)
        url = u
        return boards.serverRepo()
    end
    check("http with a port", from("http://server.test:8080/sam/bragi.git") == "sam/bragi")
    check("https with a user", from("https://sam@server.test/sam/bragi") == "sam/bragi")
    check("ssh form", from("git@server.test:sam/bragi.git") == "sam/bragi")
    check("another host", from("http://other.test:8080/sam/bragi") == nil)
    repoModule.remote, repoModule.primaryRemote = realRemote, realPrimary
    server.repoOf, server.info = realRepoOf, realInfo
end)

step(1500, "Markdown reads blocks", function()
    local blocks = markdown.parse(PAGE)
    local kinds = {}
    for _, b in ipairs(blocks) do
        kinds[#kinds + 1] = b.kind
    end
    check("block kinds in order (" .. table.concat(kinds, ",") .. ")",
        table.concat(kinds, ",") == "paragraph,heading,list,code,quote,rule,table")
    local list = blocks[3]
    check("lists keep order, nesting, and tasks", list.items[1].ordered and list.items[1].number == 1
        and list.items[3].depth == 1 and list.items[4].task == "done")
    check("code keeps its text and language", blocks[4].text == "print('[hi]')" and blocks[4].lang == "lua")
    check("tables split cells", blocks[7].rows[2][2] == "3001")
    local setext = markdown.parse("Title\n=====\nbody\n\n    indented code")
    check("underlined headings and indented code", setext[1].kind == "heading" and setext[1].level == 1
        and setext[2].kind == "paragraph" and setext[3].kind == "code" and setext[3].text == "indented code")

    local inline = markdown.inline("a **b** `[c]` [d](e) \\*f\\* ![g](h)")
    check("bold switches font", inline:find("Bragi-15-Bold", 1, true) ~= nil)
    check("code is escaped and monospaced", inline:find("Bragi-Mono-13", 1, true) ~= nil
        and inline:find("\\[c]", 1, true) ~= nil)
    check("links take the link colour", inline:find(C.link .. "']d", 1, true) ~= nil)
    check("escapes stay literal", inline:find("*f*", 1, true) ~= nil)
    check("images show their alt text", inline:find("']g", 1, true) ~= nil)
    check("plain text drops the marks", markdown.plain("**a** [b](c)") == "a b")
end)

-- ===================================================================
-- Tab in a dialog's fields
-- ===================================================================

-- Tab and Shift+Tab walk a dialog's fields, Enter in the last one presses OK.
local signInArgs = nil
local function activeField()
    for i = 1, 5 do
        if gitgud.getProperty("DialogField" .. i, "Active") == "true" then
            return i
        end
    end
    return nil
end

step(200, "a dialog with three fields", function()
    require("ui.dialog").show({
        title = "Three fields",
        fields = {
            { label = "Username", value = "sam" },
            { label = "Password", value = "", secret = true },
            { label = "Two-factor code", value = "" },
        },
        ok = "Go",
        onOk = function(v)
            signInArgs = { v.fields[1], v.fields[2], v.fields[3] }
        end,
    })
end)

step(300, "Tab walks the fields", function()
    check("it opens on the first field", activeField() == 1)
    gitgud.simulateKey("tab")
    check("Tab: password", activeField() == 2)
    gitgud.simulateText("secret")
    gitgud.simulateKey("tab")
    check("Tab: two-factor code", activeField() == 3)
    gitgud.simulateKey("tab")
    check("Tab wraps to the username", activeField() == 1)
    check("the username is selected on arrival", gitgud.getProperty("DialogField1", "SelectionLength") == "3")
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab wraps to the two-factor code", activeField() == 3)
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab: password", activeField() == 2)
    gitgud.simulateKey("tab")
    gitgud.simulateText("123456")
    shot("01b-sign-in")
end)

step(300, "Enter in the last field", function()
    gitgud.simulateKey("enter")
end)

step(300, "OK from the keyboard", function()
    check("Enter in the code field presses OK", signInArgs ~= nil and signInArgs[1] == "sam"
        and signInArgs[2] == "secret" and signInArgs[3] == "123456")
    check("the dialog closes", gitgud.getProperty("Dialog", "Visible") ~= "true")
end)

step(200, "the agent prompt keeps Tab", function()
    shell.show("agent")
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateKey("tab")
    check("Tab stays in the agent prompt", gitgud.getProperty("AgentPromptEdit", "Active") == "true")
end)

-- ===================================================================
-- Boards
-- ===================================================================

step(200, "open Boards", function()
    sent = {}
    shell.show("boards")
end)

step(800, "the board is drawn", function()
    local b = boards.current()
    check("the remembered or first board opens", b ~= nil and b.id == seeded.board)
    check("its name is the title", gitgud.getText("BoardsTitle") == "Sprint")
    check("asked for the project's boards and your own",
        lastSent("GET", "^/api/bragi/v0/repos/local/repo/projects") ~= nil
        and lastSent("GET", "^/api/bragi/v0/users/me/projects") ~= nil and lastSent("GET", "^/api/v1/user/orgs") ~= nil)
    check("a card's agent session shows", newest("BoardsBody", "Col2Card1More") == "Bragi is working")
    check("cards are drawn", newest("BoardsBody", "Col1Card1Title") == "Fix the login form")
    check("New task is on", gitgud.getProperty("BoardsNewTask", "Disabled") ~= "true")
    check("column colours become theme colours", boards.tone("#ee0701") == C.warn
        and boards.tone("#0e8a16") == C.add and boards.tone("#1d76db") == C.link
        and boards.tone("") == nil and boards.tone("#888888") == nil)
    shot("02-board")
end)

step(200, "move a card", function()
    boards.move(boards.current().columns[1].cards[1], seeded.done)
end)

step(400, "moved", function()
    local move = lastSent("POST", "/cards/" .. seeded.t1.id .. "/move$")
    check("the move names the column", move ~= nil and move.body.column_id == seeded.done)
    local board = ask("GET", "/api/bragi/v0/projects/" .. seeded.board)
    check("the store has it in Done", board.columns[3].cards[1] and board.columns[3].cards[1].issue_id == seeded.t1.id)
    local reloaded = false
    for i = #sent, 1, -1 do
        if sent[i].method == "POST" and sent[i].path:match("/move$") then
            break
        end
        reloaded = reloaded or (sent[i].method == "GET" and sent[i].path:match("/projects/7$") ~= nil)
    end
    check("the board reloads after a move", reloaded or lastSent("GET", "/projects/" .. seeded.board .. "$") ~= nil)
end)

step(200, "a card's menu", function()
    local name
    for n = 200, 1, -1 do
        if gitgud.getRect("BoardsBody" .. n .. "Col3Card1Title") then
            name = "BoardsBody" .. n .. "Col3Card1"
            break
        end
    end
    clickWidget(name, "right")
end)

step(300, "menu open", function()
    check("right-clicking a card opens its menu", visible("MenuPanel"))
    shot("03-card-menu")
    gitgud.emit("key", "escape")
end)

step(200, "a feed event reloads the board", function()
    sent = {}
    app.publish("bragi.serverEvent", { type = "board.card.moved", repo = "local/repo" })
end)

step(700, "reloaded", function()
    check("the board was fetched again", lastSent("GET", "/projects/" .. seeded.board .. "$") ~= nil)
end)

-- ===================================================================
-- Wiki
-- ===================================================================

step(200, "open the Wiki", function()
    sent = {}
    shell.show("wiki")
end)

step(800, "the shared wiki's front page", function()
    local page, open, view = wiki.current()
    check("the shared wiki opens first", open ~= nil and open.repo == "local/shared")
    check("on its front page", page == nil and view == "home")
    check("the crumbs name the wiki", gitgud.getText("WikiCrumbs") == "Shared wiki")
    check("the Home page is the first card", newest("WikiBody", "Card1Title") == "Home")
    shot("04-wiki-home")
    sent = {}
    wiki.openPage("Home")
end)

step(600, "the shared wiki's Home page", function()
    local page, _, view = wiki.current()
    check("its Home page opens", page ~= nil and page.title == "Home" and view == "page")
    check("the page is fetched as Markdown", lastSent("GET", "wiki/page/Home%?html=false$") ~= nil)
    check("the crumbs name the wiki and page", gitgud.getText("WikiCrumbs") == "Shared wiki  /  Home")
    check("Edit is on where you can write", gitgud.getProperty("WikiEdit", "Disabled") ~= "true")
    check("the title heading is drawn", newest("WikiBody", "Md1") ~= nil)
    shot("04-wiki")
end)

step(200, "open a page in a folder", function()
    wiki.openPage("guides/Deep-Dive")
end)

step(400, "folder page", function()
    check("crumbs show the folder", gitgud.getText("WikiCrumbs") == "Shared wiki  /  guides  /  Deep Dive")
    wiki.openPage("Home")
end)

step(400, "edit", function()
    clickWidget("WikiEdit")
end)

step(300, "editing", function()
    check("the source replaces the page", gitgud.getText("WikiEditor") ~= nil and not visible("WikiPage"))
    check("Edit became Save", gitgud.getText("WikiEdit") == "Save")
    gitgud.setText("WikiEditor", "# Home\n\nNew text.")
    shot("05-wiki-edit")
end)

-- A second click on the same spot sooner than this is a double-click.
step(1200, "save", function()
    clickWidget("WikiEdit")
end)

step(400, "saved", function()
    local patch = lastSent("PATCH", "/wiki/page/Home$")
    check("Save sends the title (or the page is renamed)", patch ~= nil and patch.body.title == "Home")
    check("Save sends the text as base64", patch ~= nil
        and patch.body.content_base64:sub(1, 8) == wiki.base64("# Home\n\nNew text."):sub(1, 8))
    check("base64 pads", wiki.base64("Man") == "TWFu" and wiki.base64("Ma") == "TWE=" and wiki.base64("M") == "TQ==")
    check("back to reading", gitgud.getText("WikiEdit") == "Edit" and visible("WikiPage"))
    check("the store has the new text",
        ask("GET", "/api/bragi/v0/repos/local/shared/wiki/page/Home").content == "# Home\n\nNew text.")
    check("as one more commit", ask("GET", "/api/v1/repos/local/shared/wiki/revisions/Home").count == 4)
end)

step(200, "search", function()
    gitgud.setText("WikiFindEdit", "deep")
    gitgud.emit("WikiFindEdit.changed", "deep")
end)

step(700, "found", function()
    check("search asks every wiki", lastSent("GET", "/wikis/search%?limit=50&q=deep$") ~= nil)
    gitgud.setText("WikiFindEdit", "")
    gitgud.emit("WikiFindEdit.changed", "")
end)

step(1200, "ask Bragi", function()
    clickWidget("WikiAskBragi")
end)

step(300, "the request is in the prompt", function()
    check("the Agent view opens", shell.view() == "agent")
    check("with a request about the page", (gitgud.getText("AgentPromptEdit") or ""):find("Update the wiki page \"Home\"", 1, true) == 1)
end)

-- ===================================================================
-- No store (this build)
-- ===================================================================

step(200, "no store", function()
    server.setBackend(nil)
    shell.show("boards")
end)

step(400, "boards without a store", function()
    check("the board is gone", boards.current() == nil)
    check("Boards says they're coming", newest("BoardsBody", "NoteTitle") == "Boards are coming")
    check("and offers nothing to click", newest("BoardsBody", "NoteButton") == nil)
    shot("06-no-store")
    shell.show("wiki")
end)

step(400, "wiki without a store", function()
    check("the wiki says it's coming", newest("WikiBody", "Title") == "Wikis are coming")
    check("and offers nothing to click", newest("WikiBody", "Button") == nil)
    check("nothing to edit", gitgud.getProperty("WikiEdit", "Disabled") == "true")
    server.setBackend(store)
end)

step(300, "the store again", function()
    check("the views have it back", server.info().signedIn and server.info()["local"])
end)

step(200, "done", function()
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
