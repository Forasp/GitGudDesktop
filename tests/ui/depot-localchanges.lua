--- tests/ui/depot-localchanges.lua: the Depot UI when pending changes are
-- in the way of Get Revision or of switching to a new branch.
--
-- Run it in a repository made by make-testrepo.ps1 / make-testrepo.sh with
-- GITGUD_UI=depot, a scratch APPDATA, GITGUD_SCRIPT pointing here, and
-- GITGUD_SHOTS for the screenshots. Commits lc.txt twice (branch lc-old at
-- the first), edits it, then: Get Revision lc-old stops and names lc.txt,
-- Cancel leaves everything alone; New Branch from lc-old with the switch
-- stops the same way, and Stash and continue switches. Prints "[check] ..."
-- lines for the log.

local repo = require("core.repo")

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

local function git(args)
    local command = { gitgud.findProgram("git") }
    for _, a in ipairs(args) do
        command[#command + 1] = a
    end
    return gitgud.runProgram(command, repo.state().path)
end

local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

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
local function dialogNamesFile()
    return gitgud.getProperty("Dialog", "Visible") == "true"
        and gitgud.getText("DialogTitle"):find("overwritten", 1, true) ~= nil
        and gitgud.getText("DialogMessage"):find("lc.txt", 1, true) ~= nil
end

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

step(1500, "commit lc.txt twice, branch lc-old at the first", function()
    local state = repo.state()
    marks.branch = state.branch
    marks.file = state.path .. "/lc.txt"
    local ident = { "-c", "user.name=Test", "-c", "user.email=test@example.com" }

    writeFile(marks.file, "v1\n")
    git({ "add", "lc.txt" })
    local first = git({ ident[1], ident[2], ident[3], ident[4], "commit", "-q", "-m", "lc v1", "--", "lc.txt" })
    git({ "branch", "lc-old" })
    writeFile(marks.file, "v2\n")
    local second = git({ ident[1], ident[2], ident[3], ident[4], "commit", "-q", "-m", "lc v2", "--", "lc.txt" })
    check("made the commits", first.code == 0 and second.code == 0)

    writeFile(marks.file, "mine\n")
    require("core.app").requestRefresh()
end)

step(600, "Get Revision lc-old for the whole workspace", function()
    require("depot.actions").getRevision({}, "lc-old")
end)

step(600, "confirm the revision", function()
    clickWidget("DialogOkButton")
end)

step(800, "Get Revision stopped and says why", function()
    check("Get Revision stop dialog names lc.txt", dialogNamesFile())
    shot("dlc01-get-revision-blocked")
end)

step(300, "cancel", function()
    clickWidget("DialogCancelButton")
end)

step(600, "nothing changed", function()
    check("still on " .. marks.branch, repo.state().branch == marks.branch)
    check("lc.txt kept the local edit", readFile(marks.file) == "mine\n")
end)

step(300, "New Branch from lc-old, switching to it", function()
    marks.stashes = #repo.state().stashes
    marks.old = git({ "rev-parse", "lc-old" }).output:gsub("%s+$", "")
    require("depot.commands").newBranch(marks.old)
end)

step(600, "name it", function()
    gitgud.setText("DialogField1", "lc-new")
    clickWidget("DialogOkButton")
end)

step(800, "the switch stopped and says why", function()
    check("switch stop dialog names lc.txt", dialogNamesFile())
    shot("dlc02-new-branch-blocked")
end)

step(300, "stash and continue", function()
    clickWidget("DialogOkButton")
end)

step(1000, "switched", function()
    local state = repo.state()
    check("on lc-new", state.branch == "lc-new")
    check("lc.txt is lc-old's", readFile(marks.file) == "v1\n")
    check("the changes are in a stash", #state.stashes == marks.stashes + 1)
end)

run(1)
