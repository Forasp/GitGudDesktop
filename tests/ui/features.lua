--- tests/ui/features.lua — the GitKraken-style features through the real UI.
--
-- Same harness as walkthrough.lua / workflows.lua (GITGUD_SCRIPT and
-- GITGUD_SHOTS; run it in a repository made by make-testrepo.ps1). Covers:
-- the branch tree, the commit graph, the command palette, undo / redo, the
-- merge tool, interactive rebase (and undoing it), blame and file history,
-- word diffs, the console, worktrees opened as tabs. Prints "[check] ..."
-- lines that the log can be grepped for.

local repo = require("core.repo")

local OUT = os.getenv("GITGUD_SHOTS") or "."
local steps = {}
local marks = {}

--- Queue a step.
-- @param delay  milliseconds to wait before running it
-- @param label  name for the log
-- @param fn     function() doing the step
local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end

--- Save a screenshot of the next frame.
-- @param name  file name without extension
local function shot(name)
    gitgud.screenshot(OUT .. "/" .. name .. ".png")
end

--- Log a pass/fail line.
-- @param label  what was checked
-- @param ok     result
local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

--- Commit one file's content with a message (through the gitgud API).
-- @param path     file
-- @param content  new content
-- @param message  commit message
local function commitFile(path, content, message)
    gitgud.writeRepoFile(path, content)
    gitgud.stage(path)
    return gitgud.commit(message)
end

--- Click a list row by index (rows of `height` px).
-- @param list    widget
-- @param row     1-based row
-- @param height  row height
-- @param kind    "left" | "right" | "double"
local function clickRow(list, row, height, kind)
    local x, y = gitgud.getRect(list)
    gitgud.simulateClick(x + 60, y + (row - 1) * height + height / 2, kind or "left")
end

--- Run step i, then schedule the next.
-- @param i  step index
local function run(i)
    local s = steps[i]
    if not s then
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
        return
    end

    gitgud.after(s.delay, function()
        print("[ui-test] " .. i .. ": " .. s.label)
        local ok, err = pcall(s.fn)
        if not ok then
            print("[ui-test] step " .. i .. " failed: " .. tostring(err))
            check("step " .. i .. " ran without errors", false)
        end
        run(i + 1)
    end)
end

-- ---------------------------------------------------------------- steps --

step(1200, "start: branch tree and toolbar", function()
    check("branch tree is showing", gitgud.getProperty("Navigator", "Visible") == "true")
    shot("f01-start")
end)

step(300, "open the commit graph", function()
    require("views.graph").show()
end)

step(900, "graph drawn", function()
    local result = gitgud.graph({ max = 50, prefix = "TestGraph" })
    check("gitgud.graph returns rows", result ~= nil and #result.rows > 5)
    check("graph rows carry lanes and images", result.rows[1].lane ~= nil and result.rows[1].image ~= nil)
    check("graph panel is visible", gitgud.getProperty("GraphPanel", "Visible") == "true")
    check("sidebar is hidden in graph mode", gitgud.getProperty("Sidebar", "Visible") == "false")
    shot("f02-graph")
end)

step(300, "select a commit in the graph", function()
    clickRow("GraphList", 4, 28)
end)

step(700, "graph selection", function()
    check("graph selection shows the commit header", gitgud.getProperty("CommitView", "Visible") == "true")
    shot("f03-graph-selected")
end)

step(300, "leave the graph, open the palette", function()
    require("views.graph").hide()
    require("ui.commands").open()
    gitgud.simulateText("grap")
end)

step(700, "palette results", function()
    check("palette is open", gitgud.getProperty("PalettePopup", "Visible") == "true")
    shot("f04-palette")
end)

step(400, "close the palette", function()
    gitgud.emit("key", "escape")
end)

step(500, "commit something to undo", function()
    check("palette closed on Escape", gitgud.getProperty("PalettePopup", "Visible") == "false")
    marks.headBefore = gitgud.headOid()
    gitgud.writeRepoFile("undo-me.txt", "undo me\n")
    gitgud.stage("undo-me.txt")
    require("ui.placeholder").setText("SummaryEdit", "Commit to undo")
    require("views.changes").commit()
end)

step(700, "undo the commit", function()
    marks.headAfter = gitgud.headOid()
    check("commit moved HEAD", marks.headAfter ~= marks.headBefore)
    check("undo is offered", require("core.undo").peekUndo() ~= nil)
    require("views.toolbar").undo()
end)

step(700, "after undo", function()
    local state = repo.load()
    check("undo put HEAD back", gitgud.headOid() == marks.headBefore)
    local file = repo.file("undo-me.txt")
    check("the undone commit's file is staged again", file ~= nil and file.staged)
    check("the message is back in the box", gitgud.getText("SummaryEdit") == "Commit to undo")
    shot("f05-after-undo")
end)

step(400, "redo", function()
    require("views.toolbar").redo()
end)

step(700, "after redo", function()
    check("redo restored the commit", gitgud.headOid() == marks.headAfter)
    check("redo cleared the message box", gitgud.getText("SummaryEdit") == "")
end)

step(300, "make a conflict", function()
    marks.main = gitgud.currentBranch()
    gitgud.createBranch("clash")
    commitFile("clash.txt", "top\nmain side\nbottom\n", "Main edits clash.txt")
    gitgud.checkout("clash")
    commitFile("clash.txt", "top\nclash side\nbottom\n", "Clash edits clash.txt")
    gitgud.checkout(marks.main)
    require("views.branches").merge("clash")
end)

step(900, "open the merge tool", function()
    local state = repo.load()
    check("merge stopped on a conflict", #state.conflicts == 1)
    require("views.mergetool").open("clash.txt")
end)

step(700, "merge tool", function()
    check("merge tool is open", gitgud.getProperty("MergeToolPanel", "Visible") == "true")
    check("Save waits for a decision", gitgud.getProperty("MergeSaveButton", "Disabled") == "true")
    shot("f06-mergetool")
end)

step(400, "take theirs", function()
    gitgud.emit("MergeTheirsList.clicked", "0,0,1")
end)

step(600, "took theirs for the conflict", function()
    check("Save is enabled once resolved", gitgud.getProperty("MergeSaveButton", "Disabled") ~= "true")
    shot("f07-mergetool-resolved")
end)

step(400, "save the resolution", function()
    gitgud.emit("MergeSaveButton.clicked", "")
end)

step(900, "finish the merge", function()
    local state = repo.load()
    check("no conflicts left", #state.conflicts == 0)
    local content = gitgud.readRepoFile("clash.txt")
    check("resolved file has their side", content == "top\nclash side\nbottom\n")
    gitgud.commit("Merge clash")
end)

step(500, "prepare commits to rebase", function()
    marks.base = gitgud.headOid()
    commitFile("r1.txt", "1\n", "Rebase one")
    commitFile("r2.txt", "2\n", "Rebase two")
    commitFile("r3.txt", "3\n", "Rebase three")
    marks.rebaseTip = gitgud.headOid()
    require("core.app").requestRefresh()
end)

step(700, "open the rebase editor", function()
    require("views.rebase").open(marks.base)
end)

step(700, "rebase editor", function()
    check("rebase editor is open", gitgud.getProperty("RebaseDialog", "Visible") == "true")
    -- Newest first: row 2 is "Rebase two"; squash it into "Rebase one".
    gitgud.emit("RebaseList.selected", "1")
    gitgud.emit("RebaseSquashButton.clicked", "")
end)

step(500, "squash chosen", function()
    shot("f08-rebase-editor")
end)

step(400, "start the rebase", function()
    gitgud.emit("RebaseStartButton.clicked", "")
end)

step(900, "after rebase", function()
    check("rebase editor closed", gitgud.getProperty("RebaseDialog", "Visible") == "false")
    local log = gitgud.history(3)
    check("three commits became two", log[1].summary == "Rebase three" and log[2].summary == "Rebase one")
    check("the squashed commit joins both messages", log[2].message:find("Rebase two", 1, true) ~= nil)
    require("views.toolbar").undo()
end)

step(900, "undo the rebase", function()
    check("undo restored the old tip", gitgud.headOid() == marks.rebaseTip)
end)

step(300, "blame", function()
    require("views.inspector").blame("README.md", "workdir")
end)

step(900, "blame view", function()
    check("blame view is open", gitgud.getProperty("BlameCodeList", "Visible") == "true")
    shot("f09-blame")
end)

step(400, "file history", function()
    require("views.inspector").history("README.md")
end)

step(900, "file history view", function()
    check("history mode shows the commit list", gitgud.getProperty("InspectorCommitList", "Visible") == "true")
    shot("f10-file-history")
end)

step(400, "close the inspector", function()
    gitgud.emit("key", "escape")
end)

step(500, "word diff", function()
    check("Escape closed the inspector", gitgud.getProperty("InspectorPanel", "Visible") == "false")
    require("views.sidebar").select("changes")
    require("views.changes").select("src/main.cpp")
end)

step(800, "word diff shown", function()
    shot("f11-word-diff")
end)

step(400, "run a console command", function()
    require("views.console").run("git status --short")
end)

step(4000, "console", function()
    check("console is open", gitgud.getProperty("ConsolePane", "Visible") == "true")
    check("the command finished", not gitgud.commandRunning())
    shot("f12-console")
end)

step(400, "hide the console", function()
    require("views.frame").setConsole(false)
end)

step(300, "branch tree menu", function()
    clickRow("NavList", 2, 26, "right")
end)

step(600, "branch tree context menu", function()
    check("branch menu opened", gitgud.getProperty("MenuPanel", "Visible") == "true")
    shot("f13-branch-menu")
end)

step(400, "close the menu", function()
    gitgud.emit("key", "escape")
end)

step(400, "drag feature/login onto the current branch", function()
    -- Rows (0-based): 0 LOCAL, 1 clash, 2 feature/login, 3 feature/theme, 4 main.
    gitgud.emit("NavList.dragged", "2,4")
end)

step(600, "drop menu", function()
    check("dropping a branch offers merge / rebase", gitgud.getProperty("MenuPanel", "Visible") == "true")
    check("the first offer merges into the current branch",
        gitgud.getText("MenuItem1"):find("Merge feature/login into main", 1, true) ~= nil)
    shot("f15-drag-drop-menu")
end)

step(400, "close the drop menu", function()
    gitgud.emit("key", "escape")
end)

step(400, "run a palette command with Enter", function()
    require("ui.commands").open()
    gitgud.simulateText("commit graph")
end)

step(500, "palette: Enter", function()
    gitgud.emit("PaletteEdit.accepted", "")
end)

step(900, "palette ran the command", function()
    check("Enter in the palette opened the graph", require("views.frame").graphMode())
    require("views.graph").hide()
end)

step(400, "SSH keys dialog", function()
    require("views.ssh").keys()
end)

step(600, "SSH keys dialog shown", function()
    check("SSH keys dialog is open", gitgud.getProperty("Dialog", "Visible") == "true")
    shot("f16-ssh-keys")
end)

step(400, "close it", function()
    gitgud.emit("key", "escape")
end)

step(400, "an unknown SSH host", function()
    gitgud.emit("ssh.unknownHost",
        "git.example.com\nSHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEF\ngit.example.com ssh-ed25519 AAAAC3Nz")
end)

step(600, "host trust prompt", function()
    check("unknown host asks before trusting", gitgud.getText("DialogTitle"):find("git.example.com", 1, true) ~= nil)
    shot("f17-ssh-trust")
end)

step(400, "decline", function()
    gitgud.emit("key", "escape")
end)

step(400, "commit signing dialog", function()
    require("views.settings").signing()
end)

step(600, "signing dialog shown", function()
    check("signing dialog is open", gitgud.getText("DialogTitle") == "Commit signing")
    shot("f18-signing")
end)

step(400, "close it", function()
    gitgud.emit("key", "escape")
end)

step(400, "track *.psd with LFS", function()
    require("views.lfs").track("*.psd")
end)

step(600, "LFS tracking written", function()
    local attributes = gitgud.readRepoFile(".gitattributes") or ""
    if gitgud.lfsAvailable() then
        check("*.psd is tracked with LFS", attributes:find("*.psd filter=lfs", 1, true) ~= nil)
    else
        check("LFS missing: nothing written", attributes == "")
    end
end)

step(400, "add a worktree", function()
    marks.worktree = repo.state().path .. "-features-wt"
    local ok, err = gitgud.addWorktree("features-wt", marks.worktree, "features-wt")
    check("worktree added" .. (ok and "" or (": " .. tostring(err))), ok == true)
    require("views.tabs").openInNewTab(marks.worktree)
end)

step(1200, "tabs", function()
    check("tab strip shows with two repositories", gitgud.getProperty("TabStrip", "Visible") == "true")
    check("the worktree is open", repo.state().path:lower():find("features%-wt") ~= nil)
    shot("f14-tabs")
end)

step(400, "switch tabs", function()
    require("views.tabs").next(1)
end)

step(1200, "back to the first tab", function()
    check("switched back", repo.state().path:lower():find("features%-wt") == nil)
    require("views.tabs").forget(marks.worktree)
    gitgud.removeWorktree("features-wt")
end)

run(1)
