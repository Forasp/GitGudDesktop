--- tests/ui/bragi-tasks.lua: agent-aware tasks on the local store
-- (bragi/store.lua): a board card handed to the agent, the session recorded
-- in the store with a progress comment on the task, and the agent's state
-- on the cards. The agent is the fake claude (tests/fake_claude.cpp).
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR, GITGUD_SCRIPT,
-- GITGUD_SHOTS). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake then
    check("needs GITGUD_UI=bragi and GITGUD_TEST_CLAUDE", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local app = require("core.app")
local boards = require("bragi.boards")
local server = require("bragi.server")
local settings = require("core.settings")
local shell = require("bragi.shell")
local store = require("bragi.store")

settings.set("bragi.claudeProgram", fake)

local function newest(prefix, suffix)
    for n = 200, 1, -1 do
        if gitgud.getRect(prefix .. n .. suffix) then
            return gitgud.getText(prefix .. n .. suffix)
        end
    end
    return nil
end

-- ===================================================================
-- The store: a task on a board, another with sessions
-- ===================================================================

local function ask(method, path, body)
    local value, err = store.answer(method, path, body)
    if err then
        print("[ui-test] " .. method .. " " .. path .. ": " .. err)
    end
    return value
end

assert(store.repoOf(require("core.repo").state().path) == "local/repo")
local TASK = ask("POST", "/api/v1/repos/local/repo/issues", { title = "Fix the login form", body = "The form loses focus." })
local OTHER = ask("POST", "/api/v1/repos/local/repo/issues", { title = "Boards view" })
local BOARD = ask("POST", "/api/bragi/v0/users/me/projects", { title = "Sprint", template = "basic_kanban" })
local columns = ask("GET", "/api/bragi/v0/projects/" .. BOARD.id).columns
ask("POST", "/api/bragi/v0/projects/" .. BOARD.id .. "/cards", { issue_id = TASK.id })
ask("POST", "/api/bragi/v0/projects/" .. BOARD.id .. "/cards", { issue_id = OTHER.id, column_id = columns[2].id })
local older = ask("POST", "/api/bragi/v0/repos/local/repo/issues/2/sessions", { status = "done" })
ask("POST", "/api/bragi/v0/repos/local/repo/issues/2/sessions", { status = "working", summary = "Drawing columns" })

-- Requests still go to the store; this keeps a list.
local sent = {}
local realRequest = server.request
server.request = function(method, path, body, onDone, onError)
    sent[#sent + 1] = { method = method, path = path, body = body }
    return realRequest(method, path, body, onDone, onError)
end

local function find(method, pattern)
    local found = {}
    for _, s in ipairs(sent) do
        if s.method == method and s.path:match(pattern) then
            found[#found + 1] = s
        end
    end
    return found
end

-- ===================================================================

step(1500, "open the board", function()
    shell.show("boards")
end)

step(900, "the agent's state on the cards", function()
    check("the board is open", boards.current() and boards.current().id == BOARD.id)
    check("asked for the repository's sessions", #find("GET", "/repos/local/repo/sessions") > 0)
    check("an older session doesn't win", older ~= nil)
    check("the newest session's state shows on its card", newest("BoardsBody", "Col2Card1More") == "Bragi is working")
    check("a card without a session shows none", newest("BoardsBody", "Col1Card1More") == "")
    gitgud.screenshot(OUT .. "/tasks-01-board.png")
end)

step(200, "hand the card to the agent", function()
    sent = {}
    boards.workOn(boards.current().columns[1].cards[1])
end)

step(1500, "the session works on the issue", function()
    check("the Agent view opens", shell.view() == "agent")
    local first = nil
    for _, item in ipairs(agent.items()) do
        first = first or (item.kind == "user" and item or nil)
    end
    check("the open repository is the task's: no note", agent.items()[1].kind == "user")
    check("its first message is the issue", first and first.kind == "user"
        and first.text:find("Work on issue #1 of local/repo: Fix the login form", 1, true) == 1
        and first.text:find("The form loses focus.", 1, true) ~= nil)
    check("the title names the issue", gitgud.getText("AgentTitle") == "#1  Fix the login form")
    check("the session knows its task", agent.session().task and agent.session().task.number == 1)

    local created = find("POST", "/issues/1/sessions$")[1]
    check("the store records the session", created ~= nil and created.body.status == "working"
        and created.body.title == "Fix the login form")
    local patch = find("PATCH", "/sessions/%d+$")
    local waiting = nil
    for _, p in ipairs(patch) do
        waiting = p.body.status == "waiting" and p or waiting
    end
    check("after the turn it's waiting, with a summary", waiting ~= nil
        and waiting.body.summary:find("You said:", 1, true) == 1)
    local comment = find("POST", "/issues/1/comments$")[1]
    check("the issue gets a progress comment", comment ~= nil
        and comment.body.body:find("Bragi is working on this", 1, true) == 1
        and comment.body.body:find("**Latest:** You said:", 1, true) ~= nil)
    local comments = ask("GET", "/api/v1/repos/local/repo/issues/1/comments")
    local sessions = ask("GET", "/api/bragi/v0/repos/local/repo/issues/1/sessions")
    check("the task has the comment", #comments == 1 and comments[1].body:find("Bragi is working on this", 1, true) == 1)
    check("the session in the store is waiting and links to it", sessions[1] and sessions[1].status == "waiting"
        and sessions[1].comment_id == comments[1].id)
    gitgud.screenshot(OUT .. "/tasks-02-agent.png")
    sent = {}
    agent.send("again")
end)

step(1500, "a second turn edits the same comment", function()
    check("no second comment", #find("POST", "/comments$") == 0)
    check("the comment is edited", #find("PATCH", "/issues/comments/%d+$") == 1
        and #ask("GET", "/api/v1/repos/local/repo/issues/1/comments") == 1)
end)

step(300, "done", function()
    gitgud.agentStop(agent.session().name or "")
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
