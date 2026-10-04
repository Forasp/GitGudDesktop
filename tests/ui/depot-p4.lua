--- tests/ui/depot-p4.lua: the Depot UI on a Perforce workspace, through
-- the real UI.
--
-- Run it in a workspace made by make-p4workspace.ps1 with GITGUD_UI=depot,
-- a scratch APPDATA, the P4TICKETS/P4TRUST/P4ENVIRO and GITGUD_P4 variables
-- that script prints, GITGUD_SCRIPT pointing here, and GITGUD_SHOTS. It
-- checks that pending changelists come from the server (edits that aren't
-- checked out stay out until reconciled), then reconciles, makes a numbered
-- changelist, checks out and reverts unchanged, shelves and reverts,
-- unshelves, deletes the shelf, and submits part of a changelist, all with
-- the real dialogs. Prints "[check] ..." lines for the log.

local OUT = os.getenv("GITGUD_SHOTS") or "."

local steps = {}
local marks = {}

local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. name .. ".png")
end

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end

local function run(i)
    local s = steps[i]
    if not s then
        return
    end
    gitgud.after(s.delay, function()
        print("[ui-test] " .. i .. ": " .. s.label)
        local ok, err = pcall(s.fn)
        if not ok then
            check("step " .. i .. " (" .. s.label .. ") ran without errors: " .. tostring(err), false)
        end
        run(i + 1)
    end)
end

local function paths(cl)
    local out = {}
    for _, f in ipairs(cl and cl.files or {}) do
        out[f.path] = f
    end
    return out
end

local changelists = require("depot.changelists")
local actions = require("depot.actions")
local panes = require("depot.views.panes")
local repo = require("core.repo")

step(2000, "pending changelists come from the server", function()
    check("the Depot UI is running", gitgud.currentUi().id == "depot")
    check("backend is p4", gitgud.backend() == "p4")
    local default = changelists.get(0)
    check("default changelist is empty: nothing is checked out yet", default and #default.files == 0)
    check("the edited README shows as changed in the workspace", repo.file("README.md") ~= nil)
    panes.show("pending")
    shot("dp01-pending-empty")
end)

step(400, "Reconcile Offline Work", function()
    actions.reconcile({})
end)

step(800, "reconciled", function()
    local files = paths(changelists.get(0))
    check("README opened for edit", files["README.md"] and files["README.md"].action == "edit")
    check("notes.txt opened for add", files["notes.txt"] and files["notes.txt"].action == "add")
    actions.newChangelist({ "notes.txt" })
end)

step(500, "new changelist form", function()
    check("the changelist form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
    gitgud.setText("ChangeDialogDescription", "Add notes")
    clickWidget("ChangeDialogOk")
end)

step(800, "numbered changelist on the server", function()
    local all = changelists.all()
    local cl = all[#all]
    marks.cl = cl and cl.id
    check("a numbered changelist exists", cl ~= nil and cl.id > 0 and cl.description == "Add notes")
    check("notes.txt moved into it", paths(cl)["notes.txt"] ~= nil)
    check("README stayed in default", paths(changelists.get(0))["README.md"] ~= nil)
    actions.checkOut({ "src/main.cpp" }, 0)
end)

step(600, "checked out", function()
    check("main.cpp opened for edit", paths(changelists.get(0))["src/main.cpp"] ~= nil)
    actions.revertUnchanged()
end)

step(700, "revert unchanged", function()
    local files = paths(changelists.get(0))
    check("unchanged main.cpp was reverted", files["src/main.cpp"] == nil)
    check("edited README stays open", files["README.md"] ~= nil)
    changelists.move({ "README.md" }, marks.cl)
end)

step(700, "moved", function()
    check("README is in change " .. tostring(marks.cl), paths(changelists.get(marks.cl))["README.md"] ~= nil)
    actions.shelve(marks.cl)
end)

step(500, "shelve form", function()
    check("the shelve form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
    shot("dp02-shelve")
    clickWidget("ChangeDialogOk")
end)

step(1200, "shelved", function()
    local cl = changelists.get(marks.cl)
    check("the changelist has shelved files", cl and cl.shelf and #cl.shelf.files == 2)
    check("files are still open after shelving", cl and #cl.files == 2)
    check("shelved files list for the tree", #actions.shelvedFiles(cl.shelf.oid) == 2)
    actions.revert({ "README.md" })
end)

step(500, "confirm revert", function()
    check("revert asks first", gitgud.getProperty("Dialog", "Visible") == "true")
    clickWidget("DialogOkButton")
end)

step(800, "reverted", function()
    check("README is back to the have revision", not (gitgud.readRepoFile("README.md") or ""):find("More text", 1, true))
    local cl = changelists.get(marks.cl)
    actions.unshelve({ branch = cl.shelf.branch, oid = cl.shelf.oid, change = marks.cl })
end)

step(500, "unshelve form", function()
    check("the unshelve form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
    clickWidget("ChangeDialogOk")
end)

step(1000, "unshelved", function()
    check("README has the shelved edit again", (gitgud.readRepoFile("README.md") or ""):find("More text", 1, true) ~= nil)
    check("both files open in the changelist", #changelists.get(marks.cl).files == 2)
    local cl = changelists.get(marks.cl)
    actions.deleteShelf({ branch = cl.shelf.branch, oid = cl.shelf.oid, change = marks.cl })
end)

step(500, "confirm delete shelf", function()
    clickWidget("DialogOkButton")
end)

step(900, "shelf deleted", function()
    check("no shelf left", changelists.get(marks.cl).shelf == nil)
    marks.head = gitgud.history(1)[1].oid
    actions.submit(marks.cl)
end)

step(500, "submit form", function()
    check("the submit form is open", gitgud.getProperty("ChangeDialog", "Visible") == "true")
    shot("dp03-submit")
    clickWidget("ChangeDialogOk")
end)

step(1500, "submitted", function()
    local head = gitgud.history(1)[1]
    check("a new change was submitted", head and head.oid ~= marks.head and head.summary == "Add notes")
    check("the numbered changelist is gone", changelists.get(marks.cl) == nil)
    check("nothing is open", #changelists.get(0).files == 0)
    panes.show("submitted")
end)

step(800, "submitted tab", function()
    shot("dp04-submitted")
    panes.show("branches")
end)

step(600, "branches tab", function()
    shot("dp05-branches")
    gitgud.emit("window.close", "")
end)

run(1)
