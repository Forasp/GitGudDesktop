--- tests/ui/localchanges.lua: uncommitted changes in the way of a pull, a
-- branch switch, or a merge, and the diff header's View button.
--
-- Same harness as features.lua (GITGUD_SCRIPT and GITGUD_SHOTS; run it in a
-- repository made by make-testrepo.ps1 / make-testrepo.sh, whose main tracks
-- a local bare origin). Commits lc.txt, moves origin on from a second clone,
-- edits lc.txt locally, then: the pull stops and names lc.txt, Stash and
-- continue pulls; a switch to a branch with another lc.txt stops, Cancel
-- leaves everything alone; a merge stops the same way. Prints "[check] ..."
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

--- Click the middle of a widget.
-- @param name  widget
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end

--- Run git with arguments (blocking).
-- @param args  array of arguments after "git"
-- @param cwd   working directory (default: the open repository)
-- @return the runProgram result
local function git(args, cwd)
    local command = { gitgud.findProgram("git") }
    for _, a in ipairs(args) do
        command[#command + 1] = a
    end
    return gitgud.runProgram(command, cwd or repo.state().path)
end

--- Delete a folder tree.
-- @param path  folder
local function removeTree(path)
    if gitgud.platform == "windows" then
        gitgud.runProgram({ "cmd", "/c", "rmdir", "/s", "/q", path }, repo.state().path)
    else
        gitgud.runProgram({ "rm", "-rf", path }, repo.state().path)
    end
end

--- Write a file.
-- @param path     full path
-- @param content  text
local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

--- Read a file ("" when missing).
-- @param path  full path
-- @return text
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then
        return ""
    end
    local content = f:read("a")
    f:close()
    return content
end

--- Is the generic dialog showing, with lc.txt named in it?
-- @return boolean
local function dialogNamesFile()
    return gitgud.getProperty("Dialog", "Visible") == "true"
        and gitgud.getText("DialogTitle"):find("overwritten", 1, true) ~= nil
        and gitgud.getText("DialogMessage"):find("lc.txt", 1, true) ~= nil
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

step(1200, "commit lc.txt and push it", function()
    local state = repo.state()
    marks.branch = state.branch
    marks.file = state.path .. "/lc.txt"
    marks.other = state.path .. "-lc-other"
    removeTree(marks.other)

    writeFile(marks.file, "v1\n")
    git({ "add", "lc.txt" })
    local committed = git({ "commit", "-q", "-m", "Add lc.txt", "--", "lc.txt" })
    local pushed = git({ "push", "-q", "origin", marks.branch })
    check("committed and pushed lc.txt", committed.code == 0 and pushed.code == 0)
end)

step(300, "move origin on from a second clone", function()
    local cloned = git({ "clone", "-q", "-b", marks.branch, repo.state().remotes[1].url, marks.other })
    if cloned.code ~= 0 then
        print("[ui-test] clone: " .. tostring(cloned.error) .. tostring(cloned.output))
    end
    writeFile(marks.other .. "/lc.txt", "upstream\n")
    git({ "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-am", "Change lc.txt" },
        marks.other)
    local pushed = git({ "push", "-q", "origin", marks.branch }, marks.other)
    check("origin moved on", cloned.code == 0 and pushed.code == 0)
end)

step(300, "edit lc.txt locally and pull", function()
    writeFile(marks.file, "mine\n")
    require("core.app").requestRefresh()
    require("views.sync").pull()
end)

step(2000, "the pull stopped and says why", function()
    check("pull stop dialog names lc.txt", dialogNamesFile())
    check("lc.txt kept the local edit", readFile(marks.file) == "mine\n")
    check("the pull finished (not busy)", require("views.sync").busy() == nil)
    shot("lc01-pull-blocked")
end)

step(300, "stash and continue", function()
    marks.stashes = #repo.state().stashes
    clickWidget("DialogOkButton")
end)

step(2000, "pulled", function()
    local state = repo.state()
    check("dialog closed", gitgud.getProperty("Dialog", "Visible") == "false")
    check("lc.txt has origin's version", readFile(marks.file) == "upstream\n")
    check("the changes are in a stash", #state.stashes == marks.stashes + 1)
    check("not behind origin any more", (state.aheadBehind.behind or 0) == 0)
end)

step(300, "make a branch with another lc.txt, edit lc.txt, switch", function()
    git({ "branch", "lc-topic", "HEAD~1" })
    writeFile(marks.file, "mine again\n")
    require("core.app").requestRefresh()
    require("views.branches").checkoutByName("lc-topic")
end)

step(800, "the switch stopped and says why", function()
    check("switch stop dialog names lc.txt", dialogNamesFile())
    shot("lc02-switch-blocked")
end)

step(300, "cancel", function()
    clickWidget("DialogCancelButton")
end)

step(600, "cancelled", function()
    check("still on " .. marks.branch, repo.state().branch == marks.branch)
    check("lc.txt kept the local edit", readFile(marks.file) == "mine again\n")
end)

step(300, "give lc-topic its own lc.txt change and merge it", function()
    -- Made in the second clone (from the commit that added lc.txt), pushed,
    -- and fetched here.
    local ident = { "-c", "user.name=Test", "-c", "user.email=test@example.com" }
    git({ "checkout", "-q", "-b", "lc-topic", "HEAD~1" }, marks.other)
    writeFile(marks.other .. "/lc.txt", "topic\n")
    git({ ident[1], ident[2], ident[3], ident[4], "commit", "-q", "-am", "Topic change" }, marks.other)
    git({ "push", "-q", "origin", "lc-topic" }, marks.other)
    git({ "fetch", "-q", "origin" })
    local moved = git({ "branch", "-f", "lc-topic", "origin/lc-topic" })
    check("lc-topic has a commit of its own", moved.code == 0)
    require("views.branches").merge("lc-topic")
end)

step(800, "the merge stopped and says why", function()
    check("merge stop dialog names lc.txt", dialogNamesFile())
    clickWidget("DialogCancelButton")
end)

step(600, "the diff header's View button opens the diff options", function()
    require("views.changes").select("lc.txt")
end)

step(800, "click View", function()
    marks.mode = require("views.diff").mode()
    check("the View button is showing", gitgud.getProperty("DiffViewButton", "Visible") == "true")
    clickWidget("DiffViewButton")
end)

step(600, "options shown", function()
    check("the options menu is open", gitgud.getProperty("MenuPanel", "Visible") == "true")
    check("first option is Split diff", gitgud.getText("MenuItem1"):find("Split diff", 1, true) ~= nil)
    shot("lc03-view-options")
end)

step(300, "pick the other mode", function()
    clickWidget(marks.mode == "split" and "MenuItem2" or "MenuItem1")
end)

step(600, "mode changed", function()
    local mode = require("views.diff").mode()
    check("picking an option changes the diff mode", mode ~= marks.mode)
    require("views.diff").setMode(marks.mode)
end)

step(300, "clean up", function()
    git({ "checkout", "--", "lc.txt" })
    git({ "branch", "-D", "lc-topic" })
    git({ "push", "-q", "origin", "--delete", "lc-topic" })
    removeTree(marks.other)
end)

run(1)
