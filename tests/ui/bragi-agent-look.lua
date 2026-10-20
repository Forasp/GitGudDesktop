--- tests/ui/bragi-agent-look.lua: the Agent view's pieces in design D:
-- steps named by what they did ("Ran"), the permission card (Deny and
-- Allow on its right, View diff for a change to a file), the proposed
-- change it opens, and the two-line sessions list, in the dark theme and
-- then the light one.
--
-- Run it like bragi-agent.lua: GITGUD_UI=bragi, a scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE set to
-- build\release\bin\gitgud_test_claude.exe, and CLAUDE_CONFIG_DIR set to a
-- scratch folder. The theme switch rebuilds the UI and runs this script
-- again, so it keeps its phase in a config file. Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "bragi-agent-look-test-phase"

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
local proposed = require("bragi.proposed")
local repo = require("core.repo")
local shell = require("bragi.shell")
local theme = phase()

require("core.settings").set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. theme .. "-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
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
local function has(s, part)
    return (s or ""):find(part, 1, true) ~= nil
end

step(1500, "Agent view", function()
    check(theme .. ": theme in use", gitgud.theme() == theme)
    shell.show("agent")
end)

step(300, "say hello", function()
    say("hello")
end)

step(1500, "ask for a tool", function()
    say("tool")
end)

step(1500, "a Bash step and its card", function()
    local step1 = last("step")
    local card = last("permission")
    check("the step is running", step1 ~= nil and has(gitgud.getText(step1.inner .. "Title"), "Running"))
    check("the card asks", card ~= nil and not card.answer)
    local ax = gitgud.getRect(card.inner .. "Allow")
    local dx = gitgud.getRect(card.inner .. "Deny")
    local cx, _, cw = gitgud.getRect(card.inner)
    check("Deny, then Allow at the card's right", dx < ax and ax > cx + cw / 2)
    check("no View diff for a command", gitgud.getRect(card.inner .. "View") == nil)
    shot("01-permission")
end)

step(300, "allow it", function()
    clickWidget(last("permission").inner .. "Allow")
end)

step(1500, "the step says what it did", function()
    local step1 = last("step")
    check("the step ran", has(gitgud.getText(step1.inner .. "Title"), "Ran"))
    check("what it ran, in mono", has(gitgud.getText(step1.inner .. "Title"), "echo hi"))
end)

step(300, "the session asks to edit a file", function()
    local tabs = agent.tabs()
    local tab = tabs[#tabs]
    gitgud.emit("agent.permission", gitgud.jsonEncode({
        session = tab.session.name,
        requestId = "test-edit-1",
        tool = "Edit",
        input = {
            file_path = repo.state().path .. "/src/main.cpp",
            old_string = "int line3 = 3;\nint line4 = 4;\n",
            new_string = "int line3 = 3;\nint line4 = 40;  // changed\nint line4b = 41;\n",
        },
    }))
end)

step(800, "its card has View diff", function()
    local card = last("permission")
    check("an edit's card", card ~= nil and card.tool == "Edit" and not card.answer)
    check("View diff on it", gitgud.getRect(card.inner .. "View") ~= nil)
    shot("02-edit-permission")
end)

step(300, "View diff", function()
    clickWidget(last("permission").inner .. "View")
end)

step(600, "the proposed change", function()
    check("the change shows", proposed.isOpen() and gitgud.getProperty("BragiProposed", "Visible") == "true")
    local rows = proposed.rows()
    local context, removed, added = nil, nil, 0
    for _, r in ipairs(rows) do
        if r.sign == " " then
            context = context or r
        elseif r.sign == "-" then
            removed = r
        elseif r.sign == "+" then
            added = added + 1
        end
    end
    check("unchanged lines read as context, numbered from the file", context ~= nil and context.old == 3)
    check("the replaced line, at its line", removed ~= nil and removed.text == "int line4 = 4;" and removed.old == 4)
    check("the new lines", added == 2)
    check("the title names the file", has(gitgud.getText("BragiProposedTitle"), "src/main.cpp"))
    shot("03-proposed")
end)

step(300, "deny from the dialog", function()
    clickWidget("BragiProposedDeny")
end)

step(600, "answered", function()
    check("the dialog closed", not proposed.isOpen())
    check("the card is answered", last("permission").answer == "Denied")
    check("View diff stays for a look back", gitgud.getRect(last("permission").inner .. "View") ~= nil)
end)

step(300, "the sessions list", function()
    check("the session is listed", gitgud.getSelectedIndex("AgentSessionList") ~= nil)
    check("its rows are rounded",
        has(gitgud.getProperty("AgentSessionList", "SelectionBrushImage"), "Bragi-Rows/Row56x"))
    shot("04-sessions")
end)

-- The session's own edits mark their files in the Repository view: stand
-- in for an Edit step that ran (the fake only runs Bash).
local edited = nil
step(300, "an edit the session made", function()
    edited = { kind = "step", title = "Edit", result = "ok",
        inputText = gitgud.jsonEncode({ file_path = repo.state().path .. "/src/main.cpp" }) }
    table.insert(agent.items(), edited)
    shell.show("repo")
    require("views.sidebar").select("changes")
    require("views.changes").select("src/main.cpp")
end)

step(800, "Edited by Bragi on its diff", function()
    check("the edited file is shown", require("views.changes").selectedPath() == "src/main.cpp")
    check("Edited by Bragi shows", gitgud.getProperty("BragiEditedBadge", "Visible") == "true")
    local bx, _, bw = gitgud.getRect("BragiEditedBadge")
    local vx = gitgud.getRect("DiffViewButton")
    check("before the Split button", bx and vx and bx + bw < vx)
    shot("05-edited-badge")
end)

step(300, "another file", function()
    require("views.changes").select("notes.txt")
end)

step(800, "not on a file it didn't touch", function()
    check("another file shown", require("views.changes").selectedPath() == "notes.txt")
    check("no badge there", gitgud.getProperty("BragiEditedBadge", "Visible") ~= "true")
    for i, item in ipairs(agent.items()) do
        if item == edited then
            table.remove(agent.items(), i)
            break
        end
    end
    shell.show("agent")
end)

if theme == "dark" then
    step(400, "switch to the light theme", function()
        gitgud.configWrite(PHASE_FILE, "light")
        clickWidget("BragiThemeToggle")
    end)
else
    step(400, "done", function()
        gitgud.configWrite(PHASE_FILE, "done")
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
    end)
end

harness.run({ prefix = function()
    return theme
end })
