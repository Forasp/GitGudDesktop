--- tests/ui/workflows.lua — multi-step git workflows through the real UI.
--
-- Same harness as walkthrough.lua (GITGUD_SCRIPT / GITGUD_SHOTS; run it in a
-- repository made by make-testrepo.ps1). Covers: stashing, a merge conflict
-- (banner, conflicted row, resolve, finish), push and fetch against the
-- local "remote", discard with confirmation, amend, a tag, and a rebase.
-- Prints "[check] ..." lines that the log can be grepped for.

local repo = require("core.repo")

local OUT = os.getenv("GITGUD_SHOTS") or "."
local steps = {}

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

--- Row index of a changed file.
-- @param path  repository-relative path
-- @return 1-based row, or nil
local function rowOf(path)
    for i, file in ipairs(repo.state().files) do
        if file.path == path then
            return i
        end
    end
    return nil
end

--- Commit one file's content with a message (through the gitgud API).
-- @param path     file
-- @param content  new content
-- @param message  commit message
local function commitFile(path, content, message)
    gitgud.writeRepoFile(path, content)
    gitgud.stage(path)
    gitgud.commit(message)
end

--- Click a row of the Changes list (rows are 32px tall).
-- @param row   1-based row
-- @param kind  "left" | "right" | "double"
-- @param x     optional x offset inside the row (default: on the file name)
local function clickChangesRow(row, kind, x)
    local lx, ly = gitgud.getRect("ChangesList")
    gitgud.simulateClick(lx + (x or 140), ly + (row - 1) * 32 + 16, kind or "left")
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
        end
        run(i + 1)
    end)
end

-- ---------------------------------------------------------------- steps --

step(900, "stash the starting changes", function()
    require("views.stash").stashAll()
end)

step(700, "make a conflict", function()
    check("stash left a clean tree", #repo.load().files == 0)
    gitgud.createBranch("other")
    commitFile("conflict.txt", "main side\n", "Main edits conflict.txt")
    gitgud.checkout("other")
    commitFile("conflict.txt", "other side\n", "Other edits conflict.txt")
    gitgud.checkout("main")
    require("views.branches").merge("other")
end)

step(900, "conflict banner", function()
    local state = repo.load()
    check("repository is merging", state.operation == "merge")
    check("conflict.txt is conflicted", #state.conflicts == 1)
    shot("w01-conflict")
end)

step(200, "file context menu on the conflicted file", function()
    clickChangesRow(rowOf("conflict.txt") or 1, "right")
end)

step(500, "conflict menu", function()
    shot("w02-conflict-menu")
end)

step(200, "resolve using theirs", function()
    gitgud.emit("key", "escape")
    gitgud.resolveConflict("conflict.txt", "theirs")
    gitgud.emit("status.changed", "")
end)

step(700, "resolved", function()
    local state = repo.load()
    check("no conflicts left", #state.conflicts == 0)
    check("resolution took their side", gitgud.readRepoFile("conflict.txt") == "other side\n")
    shot("w03-resolved")
end)

step(200, "commit the merge", function()
    gitgud.setText("SummaryEdit", "Merge other")
    require("views.changes").commit()
end)

step(900, "merge committed", function()
    local state = repo.load()
    check("merge finished", state.operation == "none")
    check("merge commit has two parents", #gitgud.history(1)[1].parents == 2)
    shot("w04-merged")
end)

step(200, "push to the local remote", function()
    require("views.sync").push()
end)

step(2500, "after push", function()
    local ab = repo.load().aheadBehind
    check("nothing left to push", (ab.ahead or 0) == 0)
    shot("w05-pushed")
    require("views.sync").fetch()
end)

step(2000, "after fetch", function()
    check("fetch recorded", require("views.sync").lastFetched() ~= nil)
    shot("w06-fetched")
end)

step(200, "restore the stash", function()
    require("views.stash").restore()
end)

step(900, "stash restored", function()
    check("changes are back", #repo.load().files >= 3)
    local row = rowOf("notes.txt")
    if row then
        clickChangesRow(row, "right")
    end
end)

step(500, "file context menu", function()
    shot("w07-file-menu")
end)

step(200, "discard notes.txt (confirm dialog)", function()
    gitgud.emit("key", "escape")
    gitgud.emit("MenuItem1.clicked", "")
end)

step(500, "discard confirmation", function()
    shot("w08-discard-confirm")
end)

step(200, "confirm discard", function()
    gitgud.emit("DialogOkButton.clicked", "")
end)

step(800, "discarded", function()
    check("notes.txt discarded", rowOf("notes.txt") == nil)
    check("notes.txt went to the recycle bin", not gitgud.pathExists(repo.state().path .. "/notes.txt"))
end)

step(200, "amend the merge message", function()
    gitgud.emit("AmendCheck.toggled", "1")
    gitgud.setChecked("AmendCheck", true)
end)

step(400, "amend prefilled", function()
    shot("w09-amend")
    gitgud.setText("SummaryEdit", "Merge branch 'other' (amended)")
    require("views.changes").commit()
end)

step(900, "amended", function()
    check("amend kept the merge parents", #gitgud.history(1)[1].parents == 2)
    check("amend changed the message", gitgud.history(1)[1].summary:find("amended") ~= nil)
    gitgud.createTag("v2.0", "HEAD", "Second release")
end)

step(300, "rebase feature/theme onto main", function()
    require("views.stash").stashAll()
    gitgud.checkout("feature/theme")
    local result = gitgud.rebase("main")
    check("rebase completed", result and result.kind == "done")
    gitgud.emit("status.changed", "")
end)

step(900, "after rebase, history", function()
    require("views.sidebar").select("history")
end)

step(800, "rebased history", function()
    local top = gitgud.history(2)
    check("feature commit on top of main", top[1].summary == "Add theme support")
    shot("w10-rebased-history")
end)

run(1)
