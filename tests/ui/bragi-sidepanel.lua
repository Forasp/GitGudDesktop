--- tests/ui/bragi-sidepanel.lua: the Agent view's session panel
-- (bragi/sidepanel.lua): hidden beside a narrow conversation and shown over
-- it on a click; beside it once there's room; its cards (Environment,
-- Context, Outputs, Changes, Background tasks) after the fake claude's
-- "panel" turn; folding a card and hiding the panel, both remembered;
-- stopping a background task; "Show more" and "N finished"; Create PR
-- enabled only with a remote on a signed-in server (a stand-in server and
-- push), in the dark theme and then the light one.
--
-- Run it like bragi-agent.lua: GITGUD_UI=bragi, a scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE set to
-- build\release\bin\gitgud_test_claude.exe, and CLAUDE_CONFIG_DIR set to a
-- scratch folder. The theme switch rebuilds the UI and runs this script
-- again, so it keeps its phase in a config file. Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "bragi-sidepanel-test-phase"

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local function phase()
    return (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "dark"
end
if phase() == "done" then
    return
end

local agent = require("bragi.agent")
local repo = require("core.repo")
local server = require("bragi.server")
local settings = require("core.settings")
local shell = require("bragi.shell")
local sidepanel = require("bragi.sidepanel")
local theme = phase()

settings.set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. theme .. "-sidepanel-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function has(s, part)
    return (s or ""):find(part, 1, true) ~= nil
end
local function snap()
    return sidepanel.snapshot()
end
--- The visible row of a card whose text has `part`, or nil.
local function rowWith(card, part)
    for n = 1, 30 do
        local name = "AgentPanelCard" .. card .. "Row" .. n
        if gitgud.getRect(name) and visible(name) and has(gitgud.getText(name .. "Text"), part) then
            return name
        end
    end
    return nil
end
local function mainWidth()
    local _, _, w = gitgud.getRect("AgentMain")
    return w or 0
end
local function rootWidth()
    local _, _, w = gitgud.getRect("AgentRoot")
    return w or 0
end
local function titles(list)
    local out = {}
    for _, t in ipairs(list or {}) do
        out[#out + 1] = t.title
    end
    return table.concat(out, ", ")
end

-- What Changes counted before the fake's edits.
local before = nil

if theme == "dark" then
    step(1500, "the Agent view, with the sessions list", function()
        check(theme .. ": theme in use", gitgud.theme() == theme)
        shell.show("agent")
        settings.set("bragi.panel", true)
    end)

    step(400, "too narrow beside the sessions list", function()
        local s = snap()
        check("there's no room beside the conversation", s.wide == false)
        check("so the panel is hidden", not visible("AgentPanel"))
        check("the conversation keeps its width", mainWidth() == rootWidth() - 264)
        check("the button says it would cover the conversation",
            has(gitgud.getProperty("AgentPanelButton", "TooltipText"), "over the conversation"))
        clickWidget("AgentPanelButton")
    end)

    step(400, "shown over the conversation", function()
        local s = snap()
        check("a click shows it anyway", visible("AgentPanel") and s.forced == true)
        check("over the conversation, which keeps its width", mainWidth() == rootWidth() - 264)
        local _, py = gitgud.getRect("AgentPanel")
        local _, my = gitgud.getRect("AgentMain")
        check("below the top bar", py and my and py - my == 56)
        check("not remembered", settings.get("bragi.panel", true) == true)
        shot("01-over")
    end)

    step(300, "hide it", function()
        clickWidget("AgentPanelButton")
    end)

    step(300, "hidden again", function()
        check("a second click hides it", not visible("AgentPanel") and snap().forced == false)
        -- Room for it: the sessions list goes.
        clickWidget("AgentSidebarButton")
    end)

    step(1200, "beside the conversation", function()
        local s = snap()
        check("with room, it shows beside the conversation", visible("AgentPanel") and s.wide == true)
        check("the conversation makes room", mainWidth() == rootWidth() - 288)
        check("Environment: this computer", (s.environment or {}).computer
            == (os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "This computer"))
        check("Environment: the folder", (s.environment or {}).folder == repo.state().name)
        check("Environment: the branch", (s.environment or {}).branch == repo.state().branch)
        check("Context: nothing yet", s.context and s.context.percent == nil)
        check("Outputs: nothing yet", s.outputs and #s.outputs == 0)
        check("Changes: counted", s.changes and (s.changes.added or 0) > 0)
        check("Background tasks: nothing running", s.tasks and #s.tasks.running == 0 and #s.tasks.finished == 0)
        check("no Create PR without a store", s.changes and not (s.changes.pr and s.changes.pr.show))
        before = s.changes
        shot("02-empty")
    end)

    step(300, "the panel turn", function()
        say("panel")
    end)

    step(4000, "the fake's panel turn", function()
        local s = snap()
        check("the turn ended", not agent.session().turn)
        check("Context: 45,000 of 200,000 tokens", s.context and s.context.tokens == 45000
            and s.context.window == 200000 and s.context.percent == 23)
        check("Context's header says it", s.cards.context.summary == "23%")
        check("Context's text", has(gitgud.getText("AgentPanelCardContextLine"), "45,000 of 200,000 tokens"))
        local outs = s.outputs or {}
        check("Outputs: three files, newest first", #outs == 3 and has(outs[1], "panel-outside.txt")
            and has(outs[2], "README.md") and has(outs[3], "notes/plan.md"))
        check("Outputs: a row each", rowWith("Outputs", "plan.md") ~= nil and rowWith("Outputs", "README.md") ~= nil)
        check("Outputs: the folder outside, in grey", has(gitgud.getText(rowWith("Outputs", "panel-outside.txt")
            .. "Text"), "panel-outside.txt"))
        check("Changes: the edits counted", s.changes and before and s.changes.added == before.added + 4)
        check("Changes: the new file counted", s.changes and before and s.changes.files == before.files + 2)
        check("Changes' text", has(gitgud.getText("AgentPanelCardChangesCounts"), "+" .. tostring(s.changes
            and s.changes.added)))
        local running, finished = s.tasks.running, s.tasks.finished
        check("Background tasks: two running", #running == 2, titles(running))
        check("Background tasks: the command and the agent", titles(running)
            == "Review the long log in the background, Watch the build")
        check("each can be stopped", running[1] and running[1].taskId == "task_a2" and running[2].taskId == "bash_1")
        check("Background tasks: one finished", #finished == 1 and finished[1].title == "Survey the parser"
            and finished[1].state == "completed")
        check("a row says it", rowWith("Tasks", "1 finished") ~= nil)
        check("the header says what runs", s.cards.tasks.summary == "2 running")
        check("a running task's time shows", has(gitgud.getText(rowWith("Tasks", "Watch the build") .. "Meta"), "s"))
        check("with Stop", visible(rowWith("Tasks", "Watch the build") .. "Stop"))
        shot("03-panel")
        local known = gitgud.jsonDecode(settings.get("bragi.contextWindows", "") or "")
        check("the result's window is remembered by model", type(known) == "table" and next(known) ~= nil
            and select(2, next(known)) == 200000)
        gitgud.emit("agent.usage", gitgud.jsonEncode({ session = agent.session().name, model = "claude-test-big",
            usage = { input_tokens = 2, cache_read_input_tokens = 264341 } }))
    end)

    step(500, "past the window it was told", function()
        local s = snap()
        check("Context: never less than the tokens in it", s.context and s.context.tokens == 264343
            and s.context.window == 1000000 and s.context.percent == 26)
        check("Context's text, past 200,000", has(gitgud.getText("AgentPanelCardContextLine"),
            "264,343 of 1,000,000 tokens"))
        gitgud.emit("agent.usage", gitgud.jsonEncode({ session = agent.session().name, model = "claude-test-big",
            usage = { input_tokens = 45000 } }))
    end)

    step(300, "open the finished ones", function()
        clickWidget(rowWith("Tasks", "1 finished"))
    end)

    step(500, "the finished ones", function()
        check("the finished task is listed", rowWith("Tasks", "Survey the parser") ~= nil)
        check("as done", gitgud.getProperty(rowWith("Tasks", "Survey the parser") .. "Icon", "IconImage")
            == "Bragi-Panel/Check")
        shot("04-finished")
    end)

    step(300, "stop the command", function()
        clickWidget(rowWith("Tasks", "Watch the build") .. "Stop")
    end)

    step(1500, "a task stopped", function()
        local s = snap()
        check("one left running", #s.tasks.running == 1 and s.tasks.running[1].title
            == "Review the long log in the background")
        check("the command stopped", s.tasks.finished[1] and s.tasks.finished[1].title == "Watch the build"
            and s.tasks.finished[1].state == "stopped")
        check("two finished", rowWith("Tasks", "2 finished") ~= nil)
        clickWidget("AgentPanelCardOutputsHead")
    end)

    step(400, "Outputs folded", function()
        local s = snap()
        check("folded", s.cards.outputs.open == false and s.cards.outputs.height == 40)
        check("remembered", settings.get("bragi.panel.outputs", true) == false)
        check("its header says how many", s.cards.outputs.summary == "3")
        check("its rows are hidden", rowWith("Outputs", "plan.md") == nil)
        clickWidget("AgentPanelButton")
    end)

    step(400, "the panel hidden", function()
        check("hidden", not visible("AgentPanel"))
        check("remembered", settings.get("bragi.panel", true) == false)
        check("the conversation takes the room back", mainWidth() == rootWidth())
        clickWidget("AgentPanelButton")
    end)

    step(600, "shown again", function()
        check("shown", visible("AgentPanel") and settings.get("bragi.panel", true) == true)
        check("Outputs still folded", snap().cards.outputs.open == false)
        say("tasks 6")
    end)

    step(3000, "many running", function()
        local s = snap()
        check("seven running", #s.tasks.running == 7, titles(s.tasks.running))
        check("four shown", rowWith("Tasks", "Background job 6") ~= nil and rowWith("Tasks", "Background job 2") == nil)
        check("then Show more", rowWith("Tasks", "Show 3 more") ~= nil)
        check("running() counts them", sidepanel.running(agent.current()) == 7)
        shot("05-many")
    end)

    -- Its turn is over but its background tasks live in its process:
    -- leaving it doesn't close it (four helpers died that way, 2026-10-17).
    local working
    step(600, "leave it while its tasks run", function()
        working = agent.current()
        check("its turn is over", not working.session.turn)
        agent.newSession()
    end)

    step(800, "still open", function()
        local kept = false
        for _, tab in ipairs(agent.tabs()) do
            kept = kept or tab == working
        end
        check("the tab stays", kept)
        check("its session still runs", working.session.running == true)
        agent.showTab(working)
    end)

    step(300, "show them all", function()
        clickWidget(rowWith("Tasks", "Show 3 more"))
    end)

    step(500, "all of them", function()
        check("every one shown", rowWith("Tasks", "Background job 1") ~= nil
            and rowWith("Tasks", "Review the long log") ~= nil)
        check("Show fewer", rowWith("Tasks", "Show fewer") ~= nil)
        say("finish")
    end)

    step(3000, "every one finished", function()
        local s = snap()
        check("nothing running", #s.tasks.running == 0 and rowWith("Tasks", "Nothing running.") ~= nil)
        check("nine finished", #s.tasks.finished == 9 and rowWith("Tasks", "9 finished") ~= nil)
        -- A remote on a stand-in store's host.
        server.info = function()
            return { url = "http://bragi.test:8080", user = "sam", signedIn = true }
        end
        gitgud.addRemote("home", "http://bragi.test:8080/sam/repo.git")
        sidepanel.refresh()
    end)

    local pushed, asked = nil, {}
    step(2000, "Create PR on the server", function()
        local pr = (snap().changes or {}).pr or {}
        check("Create PR is enabled", pr.enabled == true and pr.label == "Create PR")
        check("for the remote on the server", pr.remote == "home" and pr.own == "sam/repo")
        check("it says what it does", has(pr.tip, "Push main to home"))
        gitgud.pushBranch = function(remote, branch)
            pushed = remote .. " " .. branch
            gitgud.emit("pushBranch.done", branch .. "|" .. remote)
            return true
        end
        server.request = function(method, path, body, onDone)
            asked[#asked + 1] = method .. " " .. path
            if method == "GET" then
                onDone({ default_branch = "trunk" })
            else
                check("the pull request's head and base", body.head == "main" and body.base == "trunk")
                onDone({ number = 7, html_url = "http://bragi.test:8080/sam/repo/pulls/7" })
            end
        end
        clickWidget("AgentPanelCardChangesPr")
    end)

    step(600, "asked first", function()
        check("a confirmation", visible("Dialog") or visible("DialogOkButton"))
        shot("06-confirm")
    end)

    step(300, "confirm", function()
        clickWidget("DialogOkButton")
    end)

    step(1000, "the pull request", function()
        local pr = (snap().changes or {}).pr or {}
        check("pushed first", pushed == "home main")
        check("then asked the server", asked[1] == "GET /api/v1/repos/sam/repo"
            and asked[2] == "POST /api/v1/repos/sam/repo/pulls")
        check("the button opens it now", pr.label == "PR #7" and pr.pr and pr.pr.number == 7)
        check("and says so", gitgud.getText("AgentPanelCardChangesPr") == "PR #7")
        shot("07-pr")
    end)

    step(300, "switch to the light theme", function()
        gitgud.removeRemote("home")
        gitgud.configWrite(PHASE_FILE, "light")
        clickWidget("BragiThemeToggle")
    end)
else
    step(1500, "the light theme", function()
        check(theme .. ": theme in use", gitgud.theme() == theme)
        shell.show("agent")
        -- The sessions list comes back with the rebuilt UI: room for the panel.
        if visible("AgentSidebar") then
            clickWidget("AgentSidebarButton")
        end
    end)

    step(800, "the panel came back", function()
        check("still shown beside the conversation", visible("AgentPanel") and snap().wide == true)
        check("Outputs still folded", snap().cards.outputs.open == false)
        clickWidget("AgentPanelCardOutputsHead")
    end)

    step(400, "a new conversation", function()
        check("Outputs unfolded", snap().cards.outputs.open == true
            and settings.get("bragi.panel.outputs", false) == true)
        agent.newSession()
    end)

    step(600, "empty for a new one", function()
        local s = snap()
        check("no files", #s.outputs == 0)
        check("no tasks", #s.tasks.running == 0 and #s.tasks.finished == 0)
        check("no context", s.context.percent == nil)
        say("panel")
    end)

    step(4000, "the panel turn in the light theme", function()
        local s = snap()
        check("the turn ended", not agent.session().turn)
        check("Context", s.context.percent == 23)
        check("Outputs", #s.outputs == 3)
        check("two running", #s.tasks.running == 2)
        clickWidget(rowWith("Tasks", "1 finished"))
    end)

    step(500, "light screenshot", function()
        check("the finished one shows", rowWith("Tasks", "Survey the parser") ~= nil)
        shot("03-panel")
    end)

    step(300, "finish the tasks", function()
        say("finish")
    end)

    step(2000, "a slash command's output", function()
        check("nothing left running", #snap().tasks.running == 0)
        say("/context")
    end)

    step(1500, "used no context", function()
        check("Context stays at 45,000 tokens", snap().context.tokens == 45000)
        say("/compact")
    end)

    step(1500, "compaction", function()
        check("Context: what's left after compaction", snap().context.tokens == 5000)
    end)

    step(300, "done", function()
        gitgud.configWrite(PHASE_FILE, "done")
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
    end)
end

harness.run({ prefix = function()
    return theme
end })
