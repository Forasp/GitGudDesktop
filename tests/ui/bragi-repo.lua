--- tests/ui/bragi-repo.lua: the Repository view in design D: the Changes
-- rows and commit card ("Ask Bragi to write the description"), the
-- History rows with their graph, the commit header (Revert, "Ask Bragi
-- about this commit"), the diff header (Split / Unified), the diff's
-- colours, the branch panel, and the top bar's fetch button fitting its
-- room, in the dark theme and then the light one.
--
-- Run it in a repository made by make-testrepo.ps1 with GITGUD_UI=bragi, a
-- scratch APPDATA and LOCALAPPDATA, GITGUD_SCRIPT pointing here, and
-- GITGUD_SHOTS for the screenshots. The theme switch rebuilds the UI and
-- runs this script again, so it keeps its phase in a config file. Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "bragi-repo-test-phase"

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local function clickAt(name, dx, dy)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + (dx or w / 2), y + (dy or h / 2), "left")
end

local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end

local function phase()
    return (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "dark"
end

if gitgud.currentUi().id ~= "bragi" then
    print("[ui-test] needs GITGUD_UI=bragi")
    return
end

local C = require("core.palette")
local repo = require("core.repo")
local repolook = require("bragi.repolook")
local rows = require("bragi.rows")
local shell = require("bragi.shell")
local sidebar = require("views.sidebar")
local theme = phase()

-- Nothing here sends to the agent, but never start the real Claude Code.
require("core.settings").set("bragi.claudeProgram", os.getenv("GITGUD_TEST_CLAUDE") or "gitgud-test-no-claude")

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. theme .. "-" .. name .. ".png")
end

local function has(s, part)
    return (s or ""):find(part, 1, true) ~= nil
end

step(1500, "Repository view", function()
    check(theme .. ": theme in use", gitgud.theme() == theme)
    shell.show("repo")
    sidebar.select("changes")
end)

step(800, "Changes in the design's style", function()
    local state = repo.state()
    check("four changed files", #state.files == 4)
    check("staged count over the rows", gitgud.getText("IncludeAllCheck") == "0 of 4 files staged")
    check("nothing staged: Commit names no count", gitgud.getText("CommitButton") == "Commit to main")
    check("the commit card shows", visible("BragiCommitCard") and visible("BragiAskCommitButton"))
    check("every feature of the commit box kept", visible("DescriptionEdit") and visible("AmendCheck")
        and visible("CoAuthorButton") and visible("SummaryEdit") and visible("ChangesFilterEdit"))
    local _, _, w = gitgud.getRect("ChangesList")
    local _, _, sw = gitgud.getRect("Sidebar")
    check("rows keep a 10px margin", w and sw and math.abs((sw - w) - 20) <= 1)

    local row = repolook.changesRow({ path = "src/main.cpp", code = "M" }, "none")
    check("row: folder dimmed, then the name", has(row, "[colour='" .. C.sub .. "']src/") and has(row, "main.cpp"))
    check("row: the kind at the right, in its colour", has(row, "[colour='" .. C.accentText .. "']Modified"))
    check("row: themed include box", has(row, "Bragi-Icons/CheckRing") and not has(row, "Gitgud-Images/Hunk"))
    local long = repolook.changesRow({ path = string.rep("folder/", 30) .. "file.txt", code = "?" }, "all")
    check("row: a long path loses its folder's front", has(long, "…") and has(long, "file.txt") and has(long, "Added"))
    check("row: included box is filled", has(long, "Bragi-Icons/CheckMark"))
    shot("01-changes")
end)

step(300, "stage a file with its box", function()
    -- The box sits 20px into the list frame, the first row 22px down.
    clickAt("ChangesList", 17, 22)
end)

step(800, "staged", function()
    check("staged count follows", gitgud.getText("IncludeAllCheck") == "1 of 4 files staged")
    check("Commit names the count", gitgud.getText("CommitButton") == "Commit 1 file to main")
end)

step(300, "select main.cpp for its diff", function()
    for i, file in ipairs(repo.state().files) do
        if file.path == "src/main.cpp" then
            clickAt("ChangesList", 150, (i - 1) * 44 + 22)
        end
    end
end)

step(800, "diff colours", function()
    check("main.cpp selected", require("views.changes").selectedPath() == "src/main.cpp")
    check("add-bg token", gitgud.themeColour("add-bg") ~= nil and gitgud.themeColour("del-bg") ~= nil)
    check("hunk headers in the secondary colour", C.hunkHeader == C.sub)
    shot("02-changes-diff")
end)

step(300, "type a summary", function()
    gitgud.focus("SummaryEdit")
    gitgud.simulateText("Give each parser test its own temp file")
end)

step(300, "commit card filled", function()
    shot("03-commit-card")
end)

step(300, "Ask Bragi to write the description", function()
    clickAt("BragiAskCommitButton")
end)

step(600, "the request is drafted in the Agent view", function()
    check("Agent view shows", visible("AgentView") and not visible("RepoView"))
    local prompt = gitgud.getText("AgentPromptEdit") or ""
    check("draft names the commit", has(prompt, "Give each parser test its own temp file"))
    check("draft names the staged changes and the repository", has(prompt, "the staged changes in repo"))
    check("nothing sent", gitgud.getRect("AgentMessage1") == nil)
    check("the caret is at the draft's end",
        tonumber(gitgud.getProperty("AgentPromptEdit", "CaretIndex") or "") == utf8.len(prompt))
    check("the summary stays in the commit box", gitgud.getText("SummaryEdit") == "Give each parser test its own temp file")
    shot("04-ask-bragi")
end)

step(300, "back to Changes, commit", function()
    require("bragi.agent").setPrompt("")
    shell.show("repo")
    clickAt("CommitButton")
end)

step(800, "the undo row shows above the card", function()
    check("committed", #repo.state().files == 3)
    check("undo row shows", visible("UndoRow"))
    local _, rowY, _, rowH = gitgud.getRect("UndoRow")
    local _, cardY = gitgud.getRect("CommitBox")
    check("undo row sits on the commit card", rowY and cardY and rowY + rowH == cardY)
    local label = gitgud.getText("SyncLabel") or ""
    local sx, _, sw = gitgud.getRect("SyncButton")
    local bx = gitgud.getRect("BragiBranchesButton")
    check("the push button names what it does", has(label, "Push origin"))
    check("its text fits the button",
        not visible("SyncLabel") or rows.measure("[font='Bragi-13']" .. label) + 30 <= sw)
    check("the button stops before the quick actions", sx and bx and sx + sw <= bx)
    shot("05-undo-row")
end)

step(300, "undo the commit", function()
    clickAt("UndoRowButton")
end)

step(800, "undone", function()
    check("the commit is undone", #repo.state().files == 4)
    check("its summary is back", gitgud.getText("SummaryEdit") == "Give each parser test its own temp file")
end)

step(300, "back to History", function()
    sidebar.select("history")
end)

step(800, "History rows with graph dots", function()
    check("History shows", visible("HistoryPanel"))
    local head = gitgud.history({ max = 1 })[1]
    local row = repolook.historyRow(head, 1, 7)
    check("HEAD's dot is filled", has(row, "Bragi-Icons/GraphDot"))
    check("labels on HEAD, the ones that don't fit counted",
        has(row, "Bragi-Icons/PillLeft") and has(row, "']main") and (has(row, "']v1.0") or has(row, "']+")))
    check("author, age and SHA", has(row, "Test User") and has(row, head.shortOid))
    local older = gitgud.history({ max = 3 })[3]
    check("an older commit's dot is a ring", has(repolook.historyRow(older, 3, 7), "Bragi-Icons/GraphRing"))
    local long = { oid = "0", summary = string.rep("A long summary ", 12), author = "Test User", time = os.time(),
        shortOid = "0000000", parents = { "1" } }
    check("a long summary is cut to fit the row", has(repolook.historyRow(long, 2, 7), "…"))
    shot("06-history")
end)

step(300, "the commit header", function()
    local head = gitgud.history({ max = 1 })[1]
    check("the title in 20px", gitgud.getProperty("CommitSummaryLabel", "Font") == "Bragi-20-Bold"
        and gitgud.getText("CommitSummaryLabel") == head.summary)
    check("Revert and Ask Bragi on the right", visible("CommitAction1") and visible("CommitAction2")
        and gitgud.getText("CommitAction1") == "Revert"
        and gitgud.getText("CommitAction2") == "Ask Bragi about this commit")
    local tx, _, tw = gitgud.getRect("CommitSummaryLabel")
    local ax, _, aw = gitgud.getRect("CommitAction1")
    local bx, _, bw = gitgud.getRect("CommitAction2")
    local _, _, cw = gitgud.getRect("CommitHeader")
    local cx = gitgud.getRect("CommitHeader")
    check("the buttons fit their labels, the title stops before them",
        tx + tw <= ax and ax + aw < bx and math.abs((bx + bw) - (cx + cw - 24)) <= 1)
    check("the meta line has the SHA and the line counts",
        has(gitgud.getText("CommitMetaLabel"), head.shortOid) and has(gitgud.getText("CommitMetaLabel"), "+1"))
    check("the diff header names the mode", has(gitgud.getText("DiffViewButton"), "Split"))
    local _, _, _, dh = gitgud.getRect("DiffHeader")
    check("the diff header is 52px", dh == 52)
    check("no Edited by Bragi on a commit's file", not visible("BragiEditedBadge"))
end)

step(300, "Unified", function()
    require("views.diff").setMode("unified")
end)

step(400, "the diff header follows", function()
    check("the button says Unified", has(gitgud.getText("DiffViewButton"), "Unified"))
    shot("06b-unified")
    require("views.diff").setMode("split")
end)

step(400, "Ask Bragi about this commit", function()
    check("back to Split", has(gitgud.getText("DiffViewButton"), "Split"))
    clickAt("CommitAction2")
end)

step(600, "the question is drafted in the Agent view", function()
    local head = gitgud.history({ max = 1 })[1]
    local prompt = gitgud.getText("AgentPromptEdit") or ""
    check("Agent view shows", visible("AgentView"))
    check("draft names the commit", has(prompt, head.shortOid) and has(prompt, head.summary))
    check("nothing sent", gitgud.getRect("AgentMessage1") == nil)
    require("bragi.agent").setPrompt("")
    shell.show("repo")
end)

step(300, "branch tree", function()
    require("views.frame").setNavigator(true)
end)

step(800, "branch tree icons follow the theme", function()
    check("branch tree shows", require("views.frame").navigatorVisible())
    local sprites = require("core.sprites")
    local remote = sprites.image("NavRemote", 16, 16)
    check("remote icon is the theme's", has(remote, "Bragi-Icons/NavRemote") and has(remote, C.sub))
    check("include boxes are the theme's", has(sprites.image("HunkOn", 26, 26), C.accent))
    check("the panel's filter", visible("BragiNavFilterBox")
        and gitgud.getText("NavFilterPlaceholder") == "Filter branches and tags")
    check("its rows are rounded",
        has(gitgud.getProperty("NavList", "SelectionBrushImage"), "Bragi-Rows/Row30x"))
    shot("07-branches")
end)

step(300, "a wider sidebar", function()
    require("views.frame").setNavigator(false)
    require("core.settings").set("sidebarWidth", 460)
    require("views.frame").relayout()
end)

step(800, "rows fit the wider sidebar", function()
    local head = gitgud.history({ max = 1 })[1]
    local row = repolook.historyRow(head, 1, 7)
    check("every label fits now", has(row, "']main") and has(row, "']origin/main") and has(row, "']v1.0"))
    local brushW = tonumber((gitgud.getProperty("HistoryList", "SelectionBrushImage") or ""):match("Row61x(%d+)"))
    local _, _, lw = gitgud.getRect("HistoryList")
    check("the selected row's picture is drawn near the list's width",
        brushW and lw and math.abs(brushW - (lw - 14)) <= 30)
    shot("08-history-wide")
end)

step(300, "back to the usual width", function()
    require("core.settings").set("sidebarWidth", 320)
    require("views.frame").relayout()
end)

step(600, "hide the branch tree, unstage, clear the summary", function()
    require("views.frame").setNavigator(false)
    sidebar.select("changes")
    local paths = {}
    for _, file in ipairs(repo.state().files) do
        paths[#paths + 1] = file.path
    end
    gitgud.unstage(paths)
    require("ui.placeholder").setText("SummaryEdit", "")
end)

if theme == "dark" then
    step(400, "switch to the light theme", function()
        gitgud.configWrite(PHASE_FILE, "light")
        shell.show("agent")
        clickAt("BragiThemeToggle")
    end)
else
    step(400, "done", function()
        gitgud.configWrite(PHASE_FILE, "done")
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
    end)
end

if phase() ~= "done" then
    harness.run({ prefix = phase })
end
