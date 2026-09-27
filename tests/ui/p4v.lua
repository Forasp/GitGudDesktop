--- tests/ui/p4v.lua — the P4V-style UI and switching between interfaces,
-- through the real UI.
--
-- Run it in a repository made by make-testrepo.ps1 with GITGUD_UI=p4v, a
-- scratch APPDATA, GITGUD_SCRIPT pointing here, and GITGUD_SHOTS for the
-- screenshots. It walks the tabs, makes a numbered changelist, marks a file
-- for add, shelves (a branch, pushed to the test remote), reverts,
-- unshelves, deletes the shelf, and submits; opens the Diff, Revision Graph,
-- Time-lapse, and Folder Diff windows; then switches to the default UI, the
-- picker, and back. The script runs again after every UI switch, so it keeps
-- its phase in a config file. Prints "[check] ..." lines for the log.

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "p4v-test-phase"

local steps = {}
local marks = {}

local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end

local function shot(name, window)
    gitgud.screenshot(OUT .. "/" .. name .. ".png", window)
end

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local function clickWidget(name, window)
    local x, y, w, h = gitgud.getRect(name)
    local wx, wy = 0, 0
    if window then
        wx, wy = gitgud.getRect(window .. ":Root")
    end
    gitgud.simulateClick(x - (wx or 0) + w / 2, y - (wy or 0) + h / 2, "left", window)
end

local function phase()
    return (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "p4v"
end

local function setPhase(name)
    gitgud.configWrite(PHASE_FILE, name)
end

local function run(i)
    local s = steps[i]
    if not s then
        return
    end
    gitgud.after(s.delay, function()
        print("[ui-test] " .. phase() .. " " .. i .. ": " .. s.label)
        local ok, err = pcall(s.fn)
        if not ok then
            print("[ui-test] step " .. i .. " failed: " .. tostring(err))
            check("step " .. i .. " (" .. s.label .. ") ran without errors", false)
        end
        run(i + 1)
    end)
end

local function hasBranch(name)
    for _, branch in ipairs(gitgud.branches()) do
        if branch.name == name then
            return true
        end
    end

    return false
end

-- ============================================================ phase: p4v ==
if phase() == "p4v" and gitgud.currentUi().id == "p4v" then
    local repo = require("core.repo")
    local changelists = require("p4.changelists")
    local actions = require("p4.actions")
    local panes = require("p4.views.panes")
    local grid = require("p4.grid")

    step(1500, "starts in the P4V UI with the default changelist", function()
        check("the P4V UI is running", gitgud.currentUi().id == "p4v")
        local default = changelists.get(0)
        check("default changelist holds the 3 changed files (untracked hidden)", default and #default.files == 3)
        panes.show("pending")
        shot("p01-pending")
    end)

    step(500, "select a file in the depot tree", function()
        local depot = require("p4.views.depot")
        check("tree reveals src/main.cpp", depot.reveal("src/main.cpp"))
    end)

    step(400, "address bar follows", function()
        check("address shows the depot path", gitgud.getText("AddressEdit") == "//" .. repo.state().name .. "/src/main.cpp")
        check("toolbar Diff is enabled for one file", gitgud.getProperty("P4Tool10", "Disabled") == "false")
        shot("p02-tree")
    end)

    step(300, "address bar covers several items", function()
        local selection = require("p4.selection")
        local root = "//" .. repo.state().name
        check("one file: its own path", selection.coveringPath({ { path = "src/main.cpp" } }) == root .. "/src/main.cpp")
        check("one folder: path/...", selection.coveringPath({ { path = "src", folder = true } }) == root .. "/src/...")
        check("two files in src: src/...", selection.coveringPath({ { path = "src/a.cpp" }, { path = "src/b.cpp" } })
            == root .. "/src/...")
        check("files in different folders: the root", selection.coveringPath({ { path = "src/a.cpp" }, { path = "README.md" } })
            == root .. "/...")
        -- A pending changelist becomes the selection (two files)...
        panes.show("pending")
        require("p4.tree").select("PendingTree", "cl:0")
    end)

    step(400, "the changelist is the active selection", function()
        check("Rev Graph greys out for a whole changelist", gitgud.getProperty("P4Tool13", "Disabled") == "true")
        check("the address bar still shows the tree's selection", gitgud.getText("AddressEdit")
            == "//" .. repo.state().name .. "/src/main.cpp")
        -- ...then clicking the file that's still highlighted in the tree.
        local tree = require("p4.tree")
        local row = nil
        for i, entry in ipairs(tree.visible("DepotTree")) do
            if entry.node.id == "depot:src/main.cpp" then
                row = i
            end
        end
        local x, y, w = gitgud.getRect("DepotTree")
        gitgud.simulateClick(x + w - 40, y + 6 + (row - 1) * 20 + 10, "left")
    end)

    step(400, "re-clicking the tree", function()
        check("Rev Graph is enabled again for main.cpp", gitgud.getProperty("P4Tool13", "Disabled") == "false")
        check("Time-lapse too", gitgud.getProperty("P4Tool12", "Disabled") == "false")
    end)

    step(300, "History of README", function()
        require("p4.views.history").show("README.md", false)
    end)

    step(600, "history rows", function()
        local rows = grid.rows("HistoryGrid")
        check("README has 7 revisions (" .. #rows .. ")", #rows == 7)
        check("the newest is #7", rows[1] and rows[1].cells.revision == "#7")
        shot("p03-history")
    end)

    step(300, "Submitted tab", function()
        panes.show("submitted")
    end)

    step(600, "submitted rows", function()
        check("submitted lists the branch's changelists", #grid.rows("SubmittedGrid") >= 7)
        shot("p04-submitted")
        panes.show("branches")
    end)

    step(600, "branches, labels, workspaces", function()
        check("branches lists local and remote branches", #grid.rows("BranchesGrid") >= 4)
        shot("p05-branches")
        panes.show("labels")
    end)

    step(500, "labels", function()
        check("label v1.0 is listed", grid.rows("LabelsGrid")[1] and grid.rows("LabelsGrid")[1].cells.name == "v1.0")
        panes.show("workspaces")
    end)

    step(500, "workspaces", function()
        check("the workspace is listed", #grid.rows("WorkspacesGrid") >= 1)
        panes.show("pending")
    end)

    step(400, "New Pending Changelist with main.cpp", function()
        actions.newChangelist({ "src/main.cpp" })
    end)

    step(500, "fill the form", function()
        check("the changelist form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
        gitgud.setText("ChangeDialogDescription", "Tweak main")
        shot("p06-new-changelist")
        clickWidget("ChangeDialogOk")
    end)

    step(500, "changelist created", function()
        local cl = changelists.get(1)
        check("change 1 exists", cl ~= nil and cl.description == "Tweak main")
        check("main.cpp moved into it", cl and #cl.files == 1 and cl.files[1].path == "src/main.cpp")
        actions.markForAdd({ "notes.txt" }, 1)
    end)

    step(400, "mark for add", function()
        local cl = changelists.get(1)
        check("notes.txt is opened for add in change 1", cl and #cl.files == 2)
        actions.shelve(1)
    end)

    step(500, "shelve form", function()
        check("the shelve form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
        shot("p07-shelve")
        clickWidget("ChangeDialogOk")
    end)

    step(2500, "shelved", function()
        local cl = changelists.get(1)
        marks.shelf = cl and cl.shelf
        check("change 1 records its shelf", marks.shelf ~= nil)
        check("the shelf branch exists", marks.shelf and hasBranch(marks.shelf.branch))
        check("the shelf was pushed", marks.shelf and hasBranch("origin/" .. marks.shelf.branch))
        check("the workspace still has the edits", repo.file("src/main.cpp") ~= nil)
        shot("p08-shelved")
        actions.revert({ "src/main.cpp", "notes.txt" })
    end)

    step(500, "confirm revert", function()
        check("revert asks first", gitgud.getProperty("Dialog", "Visible") == "true")
        clickWidget("DialogOkButton")
    end)

    step(700, "reverted", function()
        check("main.cpp is back to #have", repo.file("src/main.cpp") == nil)
        check("notes.txt stays on disk (reverting an add keeps it)", gitgud.readRepoFile("notes.txt") ~= nil)
        actions.unshelve({ branch = marks.shelf.branch, oid = marks.shelf.oid, change = 1 })
    end)

    step(500, "unshelve form", function()
        check("the unshelve form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
        clickWidget("ChangeDialogOk")
    end)

    step(800, "unshelved", function()
        check("main.cpp has the shelved edits again", repo.file("src/main.cpp") ~= nil
            and (gitgud.readRepoFile("src/main.cpp") or ""):find("200;", 1, true) ~= nil)
        local cl = changelists.get(1)
        check("both files are back in change 1", cl and #cl.files == 2)
        actions.deleteShelf({ branch = marks.shelf.branch, change = 1, pushedTo = marks.shelf.pushedTo })
    end)

    step(500, "confirm delete shelf", function()
        clickWidget("DialogOkButton")
    end)

    step(2000, "shelf deleted", function()
        check("the shelf branch is gone", not hasBranch(marks.shelf.branch))
        check("change 1 has no shelf", changelists.get(1).shelf == nil)
        marks.head = repo.state().headOid
        actions.submit(1)
    end)

    step(500, "submit form", function()
        check("the submit form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
        shot("p09-submit")
        clickWidget("ChangeDialogOk")
    end)

    step(900, "submitted", function()
        local head = gitgud.history(1)[1]
        check("a new changelist was submitted", head and head.oid ~= marks.head and head.summary == "Tweak main")
        local files = {}
        for _, file in ipairs(gitgud.changedFiles(head.oid .. "^", head.oid)) do
            files[file.path] = true
        end
        check("it holds exactly main.cpp and notes.txt", files["src/main.cpp"] and files["notes.txt"]
            and not files["assets/logo.png"])
        check("change 1 is gone", changelists.get(1) == nil)
        check("logo.png is still pending", repo.file("assets/logo.png") ~= nil)
    end)

    step(300, "history for the revision graph", function()
        -- A branch that edits README and merges back.
        local main = repo.state().branch
        gitgud.createBranch("topic")
        gitgud.checkout("topic")
        local readme = gitgud.readRepoFile("README.md")
        gitgud.writeRepoFile("README.md", readme:gsub("# Test project", "# Test project (topic)", 1))
        gitgud.stage("README.md")
        gitgud.commit("Topic edits README")
        gitgud.checkout(main)
        gitgud.writeRepoFile("README.md", gitgud.readRepoFile("README.md") .. "main again\n")
        gitgud.stage("README.md")
        gitgud.commit("Main edits README")
        local merged = gitgud.merge("topic")
        check("topic merged cleanly", merged and merged.kind == "merged")
        require("core.app").requestRefresh()
    end)

    step(600, "open the revision graph", function()
        marks.graph = require("p4.windows.revgraph").open("README.md")
        check("the revision graph window opened", marks.graph ~= nil)
    end)

    step(1200, "revision graph", function()
        local state = require("p4.windows.revgraph").state(marks.graph)
        check("graph has a row per branch that touched README (" .. #state.graph.rows .. ")", #state.graph.rows >= 2)
        check("graph has 10 revisions (" .. #state.graph.nodes .. ")", #state.graph.nodes == 10)
        shot("p10-revision-graph", marks.graph)
    end)

    step(600, "diff window", function()
        marks.diff = require("p4.windows").diffRevisions("README.md", "HEAD~3", "README.md", "HEAD")
    end)

    step(900, "diff", function()
        local state = require("p4.windows.diff").state(marks.diff)
        check("the diff window opened", state ~= nil)
        check("it found differences", state and #state.blocks >= 1)
        shot("p11-diff", marks.diff)
    end)

    step(600, "time-lapse", function()
        marks.timelapse = require("p4.windows.timelapse").open("README.md")
        check("the time-lapse window opened", marks.timelapse ~= nil)
    end)

    step(900, "time-lapse view", function()
        shot("p12-timelapse", marks.timelapse)
    end)

    step(600, "folder diff", function()
        marks.folder = require("p4.windows.folderdiff").open("", "v1.0", "HEAD")
    end)

    step(900, "folder diff view", function()
        check("folder diff lists files", #grid.rows(marks.folder .. ":Grid") >= 3)
        shot("p13-folder-diff", marks.folder)
    end)

    step(500, "close the windows", function()
        for _, id in ipairs(gitgud.windows()) do
            gitgud.closeWindow(id)
        end
    end)

    step(800, "all closed; main window", function()
        check("every window closed", #gitgud.windows() == 0)
        panes.showBottom("dashboard")
        panes.show("pending")
        shot("p14-main")
    end)

    step(600, "switch to the default UI", function()
        setPhase("default")
        local ok = gitgud.switchUi("default", true)
        check("switchUi accepted", ok == true)
    end)
end

-- ======================================================== phase: default ==
if phase() == "default" and gitgud.currentUi().id == "default" then
    step(1500, "the default UI came up", function()
        check("default UI running", gitgud.currentUi().id == "default")
        check("previous UI is p4v", gitgud.previousUi() == "p4v")
        local found = false
        for _, entry in ipairs(require("ui.menu").entries()) do
            found = found or entry.item.label == "Switch user interface…"
        end
        check("File menu offers Switch user interface…", found)
        shot("d01-default-ui")
        setPhase("picker")
        gitgud.showUiPicker()
    end)
end

-- ========================================================= phase: picker ==
if phase() == "picker" and gitgud.currentUi().id == "picker" then
    step(1500, "the picker came up", function()
        check("picker running", gitgud.currentUi().id == "picker")
        check("not a first launch", not gitgud.firstLaunch())
        check("two interfaces offered", #gitgud.uiList() == 2)
        check("Cancel is offered", gitgud.getProperty("PickerBackButton", "Visible") == "true")
        shot("s01-picker")
        setPhase("back")
        clickWidget("CardButton2")
    end)
end

-- =========================================================== phase: back ==
if phase() == "back" and gitgud.currentUi().id == "p4v" then
    step(1500, "back in P4V, remembered", function()
        check("P4V is running again", gitgud.currentUi().id == "p4v")
        check("the choice was remembered", (gitgud.configRead("ui") or ""):find("ui=p4v", 1, true) ~= nil)
        setPhase("done")
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
    end)
end

run(1)
