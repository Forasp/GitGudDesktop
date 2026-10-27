--- tests/ui/bragi-taskview.lua: a task's details over the board
-- (bragi/taskview.lua). A click on a card opens them: the key, title,
-- description, steps from its checklist, comments, the primary action,
-- Status, Assignee, Board and activity; the card is outlined. Ticking a step
-- saves the description (the step clicked, after Bragi changed it too),
-- Status moves the card (noted in the activity), Assignee assigns it, a
-- comment is added (the box keeps its text, focus and caret while Bragi
-- comments, and brackets as typed), Copy link copies a task link, and the
-- dimmed area, ×, and Escape close it. A right click still opens the card's
-- menu. A task link opens a task with its history (one saved before
-- histories keeps Created); a stale one says so; a task off the board shows
-- no board until it's put on it, then moves from Status. With no name set
-- the Assignee menu has no you, a comment has no author, @bragify isn't
-- @Bragi, and @Bragi asks for "the user". Then the light theme.
--
-- Run it like bragi-tasks.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR, GITGUD_SCRIPT,
-- GITGUD_SHOTS). The theme switch rebuilds the UI and runs this again, so
-- it keeps its phase in a config file. Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake then
    check("needs GITGUD_UI=bragi and GITGUD_TEST_CLAUDE", false)
    gitgud.emit("window.close", "")
    return
end

local boards = require("bragi.boards")
local settings = require("core.settings")
local shell = require("bragi.shell")
local store = require("bragi.store")
local taskview = require("bragi.taskview")

settings.set("bragi.claudeProgram", fake)
settings.set("bragi.userName", "Sam")

local PHASE_FILE = "bragi-taskview-test-phase"
local phase = (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "dark"

local function ask(method, path, body)
    local value, err = store.answer(method, path, body)
    if err then
        print("[ui-test] " .. method .. " " .. path .. ": " .. err)
    end
    return value
end
local function clickAt(name, button)
    local x, y, w, h = gitgud.getRect(name)
    if not x then
        return false
    end
    gitgud.simulateClick(x + w / 2, y + h / 2, button or "left")
    return true
end
local function visible(name)
    return gitgud.getRect(name) ~= nil and gitgud.getProperty(name, "Visible") == "true"
end
-- The newest of a run of windows prefix<n>suffix.
local function newest(prefix, suffix)
    for n = 200, 1, -1 do
        if gitgud.getRect(prefix .. n .. suffix) then
            return prefix .. n .. suffix
        end
    end
    return nil
end
local function body()
    return newest("TaskViewBody", "")
end
local function has(s, part)
    return tostring(s or ""):find(part, 1, true) ~= nil
end
-- What's typed in the comment box (the box keeps a newline at the end).
local function typed()
    return ((gitgud.getText(body() .. "WriteEdit") or ""):gsub("%s+$", ""))
end
local function menuItem(label)
    for i = 1, 20 do
        local name = "MenuItem" .. i
        if visible(name) and has(gitgud.getText(name), label) then
            return name
        end
    end
    return nil
end
local copied = nil
local realClipboard = nil
local function shot(name)
    gitgud.screenshot(OUT .. "/taskview-" .. phase .. "-" .. name .. ".png")
end

if phase == "dark" then
    assert(store.repoOf(require("core.repo").state().path) == "local/repo")
    local TASK = ask("POST", "/api/v1/repos/local/repo/issues", { title = "Fix the login form",
        body = "The form loses focus when the page reloads.\n\n- [x] Find the cause\n- [ ] Fix it\n- [ ] Tests" })
    local OTHER = ask("POST", "/api/v1/repos/local/repo/issues", { title = "Boards view" })
    local BOARD = ask("POST", "/api/bragi/v0/users/me/projects", { title = "Sprint", template = "basic_kanban" })
    gitgud.configWrite("bragi-taskview-test-board", tostring(BOARD.id))
    local columns = ask("GET", "/api/bragi/v0/projects/" .. BOARD.id).columns
    ask("POST", "/api/bragi/v0/projects/" .. BOARD.id .. "/cards", { issue_id = TASK.id, column_id = columns[1].id })
    ask("POST", "/api/bragi/v0/projects/" .. BOARD.id .. "/cards", { issue_id = OTHER.id, column_id = columns[2].id })
    ask("POST", "/api/v1/repos/local/repo/issues/1/comments", { body = "Repro: reload with the form open.",
        author = "bragi" })
    local LOOSE = ask("POST", "/api/v1/repos/local/repo/issues", { title = "A task off the board" })
    -- Task 2 as saved before histories (no events), then assigned.
    local saved = gitgud.jsonDecode(gitgud.configRead("bragi/store/repo/tasks.json"))
    for _, t in ipairs(saved.tasks) do
        if t.number == 2 then
            t.events = nil
        end
    end
    gitgud.configWrite("bragi/store/repo/tasks.json", gitgud.jsonEncode(saved))
    ask("PATCH", "/api/v1/repos/local/repo/issues/2", { assignee = "bragi" })

    step(1500, "open the board", function()
        shell.show("boards")
        boards.open(BOARD.id)
    end)

    step(1200, "click the first card", function()
        check("the board is open", boards.current() and boards.current().id == BOARD.id)
        local card = newest("BoardsBody", "Col1Card1")
        check("the card is there", card ~= nil)
        clickAt(card)
    end)

    step(900, "the task's details", function()
        check("the dialog is open", taskview.isOpen() and visible("TaskView") and visible("TaskViewScrim"))
        check("its key names the board and the task", has(gitgud.getText("TaskViewKey"), "Sprint")
            and has(gitgud.getText("TaskViewKey"), "local/repo#1"))
        local b = body()
        check("the title", gitgud.getText(b .. "Title") == "Fix the login form")
        check("three steps from the checklist", gitgud.getRect(b .. "Step3") ~= nil and gitgud.getRect(b .. "Step4") == nil)
        check("the first step is done", gitgud.getRect(b .. "Step1Tick") ~= nil and gitgud.getRect(b .. "Step2Tick") == nil)
        check("the comment, by Bragi", has(gitgud.getText(b .. "CommentWho1"), "Bragi"))
        check("Ask Bragi to start: nothing works on it", gitgud.getText(b .. "Primary") == "Ask Bragi to start")
        check("status is its column", has(gitgud.getText(b .. "StatusValue"), columns[1].title))
        check("unassigned", has(gitgud.getText(b .. "AssigneeValue"), "Unassigned"))
        check("the board", has(gitgud.getText(b .. "BoardValue"), "Sprint"))
        check("it fits: no scroll pane, no scrollbars", not visible("TaskViewScroll"))
        check("the activity starts with Created", has(gitgud.getText(b .. "Activity1"), "Created"))
        check("the card is outlined", (gitgud.getProperty(newest("BoardsBody", "Col1Card1"), "BorderColour") or ""):upper()
            :find(gitgud.themeColour("accent"), 1, true) ~= nil)
        shot("01-open")
        clickAt(b .. "Step2Hit")
    end)

    step(900, "a step ticked", function()
        local issue = ask("GET", "/api/v1/repos/local/repo/issues/1")
        check("the description saves it", has(issue.body, "- [x] Fix it") and has(issue.body, "- [ ] Tests"))
        check("drawn ticked", gitgud.getRect(body() .. "Step2Tick") ~= nil)
        -- Bragi adds a line above the steps; a tick before the dialog draws
        -- that still ticks the step clicked.
        ask("PATCH", "/api/v1/repos/local/repo/issues/1",
            { body = (issue.body:gsub("\n\n%- %[", "\n\nA note from Bragi.\n\n- [", 1)) })
        clickAt(body() .. "Step3Hit")
    end)

    step(900, "a step ticked after Bragi's edit", function()
        local issue = ask("GET", "/api/v1/repos/local/repo/issues/1")
        check("the step clicked is ticked", has(issue.body, "- [x] Tests"))
        check("Bragi's line and the other steps kept", has(issue.body, "A note from Bragi.")
            and has(issue.body, "- [x] Find the cause") and has(issue.body, "- [x] Fix it"))
        check("drawn ticked", gitgud.getRect(body() .. "Step3Tick") ~= nil)
        clickAt(body() .. "Status")
    end)

    step(600, "status opens the columns", function()
        check("a menu with the columns", menuItem(columns[2].title) ~= nil and menuItem("Close the task") ~= nil)
        clickAt(menuItem(columns[2].title))
    end)

    step(1200, "moved", function()
        local b = boards.current()
        local inSecond = false
        for _, card in ipairs(b.columns[2].cards or {}) do
            inSecond = inSecond or card.number == 1
        end
        check("the card is in the second column", inSecond)
        check("status shows it", has(gitgud.getText(body() .. "StatusValue"), columns[2].title))
        check("the activity says so", has(gitgud.getText(body() .. "Activity1"), "Moved to " .. columns[2].title))
        clickAt(body() .. "Assignee")
    end)

    step(600, "assignee", function()
        check("Bragi, you, or no one", menuItem("Bragi") ~= nil and menuItem("Sam") ~= nil
            and menuItem("Unassigned") ~= nil)
        clickAt(menuItem("Sam"))
    end)

    step(900, "assigned", function()
        local issue = ask("GET", "/api/v1/repos/local/repo/issues/1")
        check("the store has it", issue.assignees and issue.assignees[1] == "Sam")
        check("shown", has(gitgud.getText(body() .. "AssigneeValue"), "Sam"))
        check("noted", has(gitgud.getText(body() .. "Activity1"), "Assigned to Sam"))
        check("just now (UTC times read as UTC)", has(gitgud.getText(body() .. "Activity1"), "just now"))
        gitgud.focus(body() .. "WriteEdit")
        gitgud.simulateText("See [1]: looks like")
    end)

    local typingIn = nil
    step(500, "Bragi comments while you type", function()
        typingIn = body()
        ask("POST", "/api/v1/repos/local/repo/issues/1/comments", { body = "Still looking.", author = "bragi" })
    end)

    step(900, "the comment box kept what's typed", function()
        check("drawn again, with Bragi's comment", body() ~= typingIn
            and has(gitgud.getText(body() .. "CommentWho2"), "Bragi"))
        check("the text as typed, brackets and all", typed() == "See [1]: looks like")
        check("still focused", gitgud.textInputFocused())
        gitgud.simulateText(" the focus handler runs twice.")
    end)

    step(500, "a comment", function()
        check("typing goes on at the caret", typed() == "See [1]: looks like the focus handler runs twice.")
        check("the Comment button shows", visible(body() .. "Send"))
        clickAt(body() .. "Send")
    end)

    step(900, "comment added", function()
        local comments = ask("GET", "/api/v1/repos/local/repo/issues/1/comments")
        check("saved, by you, as typed", #comments == 3 and comments[3].author == "Sam"
            and comments[3].body == "See [1]: looks like the focus handler runs twice.")
        check("drawn", has(gitgud.getText(body() .. "CommentWho3"), "Sam"))
        check("the box is empty again", typed() == "")
        -- The clipboard stays the user's: Copy link's text is caught here.
        realClipboard = gitgud.setClipboard
        gitgud.setClipboard = function(value)
            copied = value
            return true
        end
        clickAt("TaskViewCopy")
    end)

    step(400, "copy link", function()
        gitgud.setClipboard = realClipboard
        check("a task link", copied == "bragi://task/local/repo/1")
        shot("02-edited")
    end)

    step(300, "then Escape", function()
        gitgud.emit("key", "escape")
    end)

    step(500, "Escape closes it", function()
        check("closed", not taskview.isOpen() and not visible("TaskView") and not visible("TaskViewScrim"))
        check("the outline is gone", (gitgud.getProperty(newest("BoardsBody", "Col2Card1"), "BorderColour") or ""):upper()
            :find(gitgud.themeColour("accent"), 1, true) == nil)
        clickAt(newest("BoardsBody", "Col2Card1"), "right")
    end)

    step(500, "right click: the card's menu", function()
        check("the menu, not the dialog", not taskview.isOpen() and menuItem("Work on this with Bragi") ~= nil)
        gitgud.emit("key", "escape")
    end)

    step(300, "a task link", function()
        check("the menu closed", require("ui.popup").current() == nil)
        require("bragi.links").open({ kind = "task", target = "bragi://task/local/repo/2" })
    end)

    step(900, "a task link opens it", function()
        check("open on task 2", taskview.isOpen() and gitgud.getText(body() .. "Title") == "Boards view")
        check("no steps yet", gitgud.getRect(body() .. "NoSteps") ~= nil)
        check("its history, newest first", has(gitgud.getText(body() .. "Activity1"), "Assigned to Bragi"))
        check("saved before histories, it still says Created", has(gitgud.getText(body() .. "Activity2"), "Created"))
        local _, _, _, rootH = gitgud.getRect("Root")
        gitgud.simulateClick(20, rootH - 20, "left")
    end)

    local status = require("core.status")
    local statusError = status.error
    local errors = {}
    step(400, "the dimmed area closes it", function()
        check("closed", not taskview.isOpen())
        status.error = function(message)
            errors[#errors + 1] = message
            statusError(message)
        end
        require("bragi.links").open({ kind = "task", target = "bragi://task/local/repo/99" })
    end)

    step(900, "a stale task link", function()
        status.error = statusError
        check("no dialog", not taskview.isOpen() and not visible("TaskView"))
        check("it says so", has(errors[#errors], "local/repo#99"))
        require("bragi.links").open({ kind = "task", target = "bragi://task/local/repo/3" })
    end)

    step(900, "a task off the board", function()
        check("open on task 3", taskview.isOpen() and gitgud.getText(body() .. "Title") == "A task off the board")
        check("no board in the key", not has(gitgud.getText("TaskViewKey"), "Sprint"))
        check("no board", not has(gitgud.getText(body() .. "BoardValue"), "Sprint"))
        -- A change on the open board doesn't put the task on it.
        ask("POST", "/api/bragi/v0/projects/" .. BOARD.id .. "/cards/" .. TASK.id .. "/move",
            { column_id = columns[1].id })
    end)

    step(900, "still off the board", function()
        check("no board", not has(gitgud.getText(body() .. "BoardValue"), "Sprint"))
        clickAt(body() .. "Status")
    end)

    step(600, "status without a board", function()
        check("only closing", menuItem("Close the task") ~= nil and menuItem(columns[2].title) == nil)
        require("ui.popup").close()
        ask("POST", "/api/bragi/v0/projects/" .. BOARD.id .. "/cards",
            { issue_id = LOOSE.id, column_id = columns[1].id })
        boards.reload()
    end)

    step(900, "put on the board", function()
        check("the board in the key", has(gitgud.getText("TaskViewKey"), "Sprint"))
        check("the board", has(gitgud.getText(body() .. "BoardValue"), "Sprint"))
        check("status is its column", has(gitgud.getText(body() .. "StatusValue"), columns[1].title))
        clickAt(body() .. "Status")
    end)

    step(600, "status opens the columns", function()
        check("a menu with the columns", menuItem(columns[2].title) ~= nil)
        clickAt(menuItem(columns[2].title))
    end)

    step(1200, "moved from the dialog", function()
        local inSecond = false
        for _, card in ipairs(boards.current().columns[2].cards or {}) do
            inSecond = inSecond or card.number == 3
        end
        check("the card is in the second column", inSecond)
        check("status shows it", has(gitgud.getText(body() .. "StatusValue"), columns[2].title))
        settings.set("bragi.userName", "")
        clickAt(body() .. "Assignee")
    end)

    local agent = require("bragi.agent")
    local workOn = agent.workOn
    local asked = nil
    step(600, "assignee with no name", function()
        check("Bragi or no one", menuItem("Bragi") ~= nil and menuItem("Unassigned") ~= nil
            and menuItem("Sam") == nil and menuItem("You") == nil)
        require("ui.popup").close()
        agent.workOn = function(task)
            asked = task
        end
        gitgud.focus(body() .. "WriteEdit")
        gitgud.simulateText("Not one for @bragify.")
    end)

    step(500, "a comment with no name", function()
        clickAt(body() .. "Send")
    end)

    step(900, "no author", function()
        local comments = ask("GET", "/api/v1/repos/local/repo/issues/3/comments")
        check("saved with no author", #comments == 1 and comments[1].author == nil)
        check("drawn as a comment", has(gitgud.getText(body() .. "CommentWho1"), "Comment"))
        check("@bragify doesn't ask Bragi", asked == nil and taskview.isOpen())
        gitgud.focus(body() .. "WriteEdit")
        gitgud.simulateText("@Bragi plan this.")
    end)

    step(500, "a comment for Bragi", function()
        clickAt(body() .. "Send")
    end)

    step(900, "@Bragi asks Bragi", function()
        agent.workOn = workOn
        settings.set("bragi.userName", "Sam")
        check("a session on task 3", asked ~= nil and asked.number == 3)
        check("asked for the user", asked ~= nil
            and has(asked.body, "The user asks, in a comment on the task: @Bragi plan this."))
        check("the dialog closed", not taskview.isOpen())
        gitgud.configWrite(PHASE_FILE, "light")
        gitgud.setTheme("light")
    end)
    harness.run()

elseif phase == "done" then
    step(300, "close", function()
        gitgud.emit("window.close", "")
    end)
    harness.run()
elseif phase == "light" then
    gitgud.configWrite(PHASE_FILE, "done")
    step(1500, "the board in light", function()
        shell.show("boards")
        boards.open(tonumber(gitgud.configRead("bragi-taskview-test-board")))
    end)
    step(1000, "open", function()
        clickAt(newest("BoardsBody", "Col2Card1"))
    end)
    step(900, "light", function()
        check("open in the light theme", taskview.isOpen() and gitgud.theme() == "light")
        shot("03-open")
    end)
    step(300, "back to dark", function()
        gitgud.setTheme("dark")
    end)
    harness.run()
end
