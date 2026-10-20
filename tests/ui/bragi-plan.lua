--- tests/ui/bragi-plan.lua: the agent's plan, pinned under the latest
-- message. Claude Code's TodoWrite calls make one box per conversation,
-- changed in place on each call: a filled check for a step done (greyed
-- out), a turning ring for the one in progress (its activeForm), a dashed
-- circle for one not started, in the theme's colours. Once every step is
-- done it folds to "Plan done (n steps)" and opens again on a click. The
-- newer TaskCreate / TaskUpdate calls keep the same box. Each call's news
-- goes to Bragi's spoken updates (a new plan whole, an update only the step
-- it's on), and a recap sees where the plan stands. Reopened, the saved
-- conversation has its box again, and reopened after the switch to the
-- light theme (which rebuilds the UI and runs this script again) it has
-- the light theme's colours. Against the fake claude (tests/fake_claude.cpp:
-- "plan <json>").
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
local config = os.getenv("CLAUDE_CONFIG_DIR")
if gitgud.currentUi().id ~= "bragi" or not fake or not config then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local C = require("core.palette")
local agent = require("bragi.agent")
local app = require("core.app")
local master = require("bragi.master")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")
local text = require("core.text")

settings.set("bragi.claudeProgram", fake)
-- Sessions saved as Claude Code saves them, so the conversation reopens.
local f = assert(io.open(config .. "/fake-transcripts", "wb"))
f:write("on\n")
f:close()

local here = repo.state().path:gsub("[/\\]+$", "")
local PHASE_FILE = "bragi-plan-phase"
local theme = (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "dark"

local function shot(name)
    gitgud.screenshot(OUT .. "/plan-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end

--- The plan calls as the fake takes them: "plan " and the JSON list.
local function sendPlan(calls)
    agent.send("plan " .. gitgud.jsonEncode(calls))
end
local function todo(content, status, active)
    return { content = content, status = status, activeForm = active }
end
local function todoWrite(list)
    return { name = "TodoWrite", input = { todos = list } }
end

local function plans()
    local out = {}
    for _, item in ipairs(agent.items()) do
        if item.kind == "plan" then
            out[#out + 1] = item
        end
    end
    return out
end
local function last(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
--- The box's rows as "<status>:<text>", "; " between them.
local function rowsOf(box)
    local out = {}
    for _, r in ipairs(box and box.rows or {}) do
        out[#out + 1] = r.status .. ":" .. r.text
    end
    return table.concat(out, "; ")
end
local function prop(name, key)
    return gitgud.getProperty(name, key) or ""
end
--- Whether a colour property is a colour (CEGUI writes it in lower case).
local function tinted(name, key, colour)
    return prop(name, key):upper():find(colour, 1, true) ~= nil
end
local function stepRows(name)
    local out = {}
    for _, item in ipairs(agent.items()) do
        if item.kind == "step" and item.title == name then
            out[#out + 1] = item
        end
    end
    return out
end

-- The steps published for Bragi's spoken updates (bragi/updates.lua).
local published = {}
app.subscribe("bragi.step", function(e)
    if type(e) == "table" and type(e.step) == "table" and e.step.plan then
        published[#published + 1] = e.step
    end
end)

local box, firstName, sessionId, liveRows

if theme == "dark" then
step(1500, "start in the Agent view", function()
    shell.show("agent")
    sendPlan({ todoWrite({
        todo("Read the agent view", "in_progress", "Reading the agent view"),
        todo("Draw the plan box", "pending", "Drawing the plan box"),
        todo("Test it", "pending", "Testing it"),
    }) })
end)

step(1500, "a plan is made", function()
    local list = plans()
    check("one plan box", #list == 1)
    box = list[1]
    firstName = box and box.name
    local items = agent.items()
    check("it's the last item", items[#items] == box)
    local reply = last("assistant")
    check("under the latest message", reply ~= nil and reply.text == "Planned." and box ~= nil
        and reply.top < box.top)
    check("its steps, the one in progress by its activeForm", rowsOf(box)
        == "in_progress:Reading the agent view; pending:Draw the plan box; pending:Test it")
    check("open, with how far it got", box ~= nil and box.headText == "Plan"
        and gitgud.getText(box.inner .. "Count") == "0 of 3 done")
    local spin = box and box.rows[1].window .. "Spin"
    check("a turning ring for the step in progress, in the theme's colour", spin ~= nil and gitgud.getRect(spin) ~= nil
        and tinted(spin, "IconColour", C.planActive))
    check("a dashed circle for one not started", box ~= nil
        and prop(box.rows[2].window .. "Mark", "IconImage") == "Bragi-Icons/PlanPending"
        and tinted(box.rows[2].window .. "Mark", "IconColour", C.planPending))
    check("the colours are the theme's", C.planDone == gitgud.themeColour("plan-done")
        and C.planActive == gitgud.themeColour("plan-active") and C.planPending == gitgud.themeColour("plan-pending")
        and C.planDone ~= C.planActive and C.planActive ~= C.planPending)
    local rows = stepRows("TodoWrite")
    check("the call's step row says what it did", #rows == 1 and rows[1].summary == "3 steps")
    local news = published[#published]
    check("Bragi's updates get the new plan whole", news ~= nil and news.plan.new == true
        and #news.plan.steps == 3 and news.plan.steps[2] == "Draw the plan box")
    box.spunFrom = spin and prop(spin, "IconImage")
    shot("01-made")
    sessionId = agent.session().id
end)

step(400, "the ring turns", function()
    local spin = box and box.rows[1] and box.rows[1].window .. "Spin"
    check("its frame moved on", spin ~= nil and prop(spin, "IconImage"):find("PlanSpin", 1, true) ~= nil
        and prop(spin, "IconImage") ~= box.spunFrom)
    sendPlan({ todoWrite({
        todo("Read the agent view", "completed", "Reading the agent view"),
        todo("Draw the plan box", "in_progress", "Drawing the plan box"),
        todo("Test it", "pending", "Testing it"),
    }) })
end)

step(1500, "the plan moves on", function()
    local list = plans()
    check("still one plan box", #list == 1)
    check("changed in place", list[1] == box and box.name == firstName)
    local items = agent.items()
    check("still the last item, under the new message", items[#items] == box)
    local user = last("user")
    check("the new message is above it", user ~= nil and user.top < box.top)
    check("its steps", rowsOf(box)
        == "completed:Read the agent view; in_progress:Drawing the plan box; pending:Test it")
    check("a filled check for the step done, in the theme's colour",
        prop(box.rows[1].window .. "Mark", "IconImage") == "Bragi-Icons/PlanDone"
        and tinted(box.rows[1].window .. "Mark", "IconColour", C.planDone))
    check("the step done is greyed out", tinted(box.rows[1].window, "TextColours", C.sub)
        and tinted(box.rows[2].window, "TextColours", C.text))
    check("how far it got", gitgud.getText(box.inner .. "Count") == "1 of 3 done")
    local news = published[#published]
    check("Bragi's update names only the step it's on", news ~= nil and news.plan.current == "Drawing the plan box"
        and news.plan.steps == nil)
    local rows = stepRows("TodoWrite")
    check("its step row names the step too", #rows == 2 and rows[2].summary == "Drawing the plan box")
    local d = master.describe(agent.current())
    check("a recap sees where it stands", d.plan ~= nil and d.plan.done == 1 and d.plan.total == 3
        and d.plan.current == "Drawing the plan box" and d.plan.next == "Test it")
    shot("02-moved-on")
    sendPlan({ todoWrite({
        todo("Read the agent view", "completed", "Reading the agent view"),
        todo("Draw the plan box", "completed", "Drawing the plan box"),
        todo("Test it", "completed", "Testing it"),
    }) })
end)

step(1500, "every step done", function()
    check("still one plan box", #plans() == 1 and plans()[1] == box)
    check("it folds to one line", box.headText == "Plan done (3 steps)" and box.height == 40
        and gitgud.getRect(box.rows[1].window) == nil)
    local news = published[#published]
    check("Bragi's update says it's done", news ~= nil and news.plan.finished == true)
    shot("03-done")
    clickWidget(box.inner .. "Head")
end)

step(600, "opened again", function()
    check("its steps show again", rowsOf(box)
        == "completed:Read the agent view; completed:Draw the plan box; completed:Test it"
        and box.height > 100 and gitgud.getRect(box.rows[3].window) ~= nil)
    check("every step with a check", prop(box.rows[3].window .. "Mark", "IconImage") == "Bragi-Icons/PlanDone")
    shot("04-opened")
    clickWidget(box.inner .. "Head")
end)

step(600, "folded again", function()
    check("one line again", box.height == 40 and box.headText == "Plan done (3 steps)")
    -- The newer tools: a step at a time.
    sendPlan({
        { name = "TaskCreate", input = { subject = "Find the bug", description = "Where it breaks.",
            activeForm = "Finding the bug" } },
        { name = "TaskCreate", input = { subject = "Fix it", description = "The fix.", activeForm = "Fixing it" } },
        { name = "TaskCreate", input = { subject = "Spare step", description = "Not needed." } },
        { name = "TaskUpdate", input = { taskId = "1", status = "in_progress" } },
    })
end)

step(1500, "a plan made a step at a time", function()
    local list = plans()
    check("still one plan box", #list == 1 and list[1] == box)
    check("the new plan in it, open", rowsOf(box)
        == "in_progress:Finding the bug; pending:Fix it; pending:Spare step" and box.headText == "Plan")
    local ids = {}
    for _, s in ipairs(box.plan.steps) do
        ids[#ids + 1] = s.id
    end
    check("each step has the id Claude Code gave it", table.concat(ids, ",") == "1,2,3")
    local creates = stepRows("TaskCreate")
    check("a step row for each, named by its step", #creates == 3 and creates[1].summary == "Find the bug")
    local n = #published
    check("Bragi's updates: the steps as they're added, then the one it's on", n >= 4
        and published[n - 3].plan.added == "Find the bug" and published[n - 3].plan.new == true
        and published[n - 2].plan.added == "Fix it" and published[n].plan.current == "Finding the bug")
    sendPlan({
        { name = "TaskUpdate", input = { taskId = "3", status = "deleted" } },
        { name = "TaskUpdate", input = { taskId = "1", status = "completed" } },
        { name = "TaskUpdate", input = { taskId = "2", status = "in_progress", activeForm = "Fixing the bug" } },
    })
end)

step(1500, "updated a step at a time", function()
    check("still one plan box", #plans() == 1 and plans()[1] == box)
    check("a step taken out, one done, the next in progress", rowsOf(box)
        == "completed:Find the bug; in_progress:Fixing the bug")
    check("how far it got", gitgud.getText(box.inner .. "Count") == "1 of 2 done")
    check("still last", agent.items()[#agent.items()] == box)
    liveRows = rowsOf(box)
    shot("05-tasks")
    agent.send("tool") -- a command that asks first
end)

step(1500, "a card that waits on you", function()
    local items = agent.items()
    local card = last("permission")
    check("the card is last, the plan just above it", card ~= nil and items[#items] == card
        and items[#items - 1] == box)
    if card then
        clickWidget(card.inner .. "Allow")
    end
end)

step(1500, "answered", function()
    local items = agent.items()
    local card = last("permission")
    check("the answer came", card ~= nil and card.answer == "Allowed" and agent.session().turn == false)
    check("the plan is back under what came after the card", items[#items] == box
        and last("assistant").top > card.top and box.top > last("assistant").top)
    check("still one plan box, as it was", #plans() == 1 and rowsOf(box) == liveRows)
    agent.newSession()
end)

step(800, "reopen the conversation", function()
    check("a new session has no plan", #plans() == 0)
    agent.resume(sessionId, { cwd = here })
end)

step(1500, "reopened", function()
    local list = plans()
    check("its plan box is back", #list == 1)
    local items = agent.items()
    check("last, under the latest message", list[1] ~= nil and items[#items] == list[1])
    check("as it was", list[1] ~= nil and rowsOf(list[1]) == liveRows)
    shot("06-reopened")
end)

step(300, "switch to the light theme", function()
    gitgud.configWrite(PHASE_FILE, "light")
    gitgud.configWrite(PHASE_FILE .. "-session", sessionId or "")
    clickWidget("BragiThemeToggle")
end)
else
step(2000, "in the light theme, reopen the conversation", function()
    check("the light theme is in use", gitgud.theme() == "light")
    agent.resume(text.trim(gitgud.configRead(PHASE_FILE .. "-session") or ""), { cwd = here })
end)

step(1500, "its plan in the light theme", function()
    local list = plans()
    check("the plan box is still there", #list == 1 and rowsOf(list[1])
        == "completed:Find the bug; in_progress:Fixing the bug")
    local b = list[1]
    check("its colours are the light theme's", b ~= nil and C.planDone == gitgud.themeColour("plan-done")
        and C.planDone ~= "FFA9BA78"
        and tinted(b.rows[1].window .. "Mark", "IconColour", C.planDone)
        and tinted(b.rows[2].window .. "Spin", "IconColour", C.planActive)
        and tinted(b.inner, "FillColour", C.panel))
    shot("07-light")
end)

step(300, "done", function()
    gitgud.configWrite(PHASE_FILE, "done")
    gitgud.agentStop(agent.session().name or "")
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)
end

if theme ~= "done" then
    harness.run({ prefix = function()
        return theme
    end })
end
