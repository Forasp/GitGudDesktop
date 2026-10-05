--- tests/ui/whitespace.lua: staging while View > Hide whitespace changes is on.
--
-- Same harness as features.lua (GITGUD_SCRIPT and GITGUD_SHOTS; run it in a
-- repository made by make-testrepo.ps1 / make-testrepo.sh). Commits ws.txt,
-- then changes one line for real and two only in whitespace. With
-- whitespace hidden the line boxes still show; including the file and
-- clicking a line both stage the real change only. With whitespace shown
-- again the file goes in whole. Prints "[check] ..." lines for the log.

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

--- What's staged for ws.txt, and what isn't.
-- @return staged diff text, unstaged diff text
local function diffs()
    return git({ "diff", "--cached", "--", "ws.txt" }).output or "",
        git({ "diff", "--", "ws.txt" }).output or ""
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

step(1200, "commit ws.txt, then change it", function()
    marks.file = repo.state().path .. "/ws.txt"
    writeFile(marks.file, "a = 1\nb = 2\nc = 3\n")
    git({ "add", "ws.txt" })
    local committed = git({ "-c", "user.name=Test", "-c", "user.email=test@example.com",
        "commit", "-q", "-m", "Add ws.txt", "--", "ws.txt" })
    check("committed ws.txt", committed.code == 0)

    -- a: trailing spaces only; b: a real change; c: inner spaces only.
    writeFile(marks.file, "a = 1  \nb = 20\nc  = 3\n")
    require("views.diff").setIgnoreWhitespace(true)
    require("views.diff").setMode("split")
    require("core.app").requestRefresh()
end)

step(800, "show ws.txt with whitespace hidden", function()
    require("views.changes").select("ws.txt")
end)

step(800, "the line boxes are there", function()
    check("the staging column shows with whitespace hidden", gitgud.getProperty("HunkGutter", "Visible") == "true")
    shot("ws01-hidden-with-boxes")
end)

step(300, "include the whole file", function()
    local ok = require("core.staging").stage("ws.txt")
    check("including the file worked", ok == true)
    require("core.app").requestRefresh()
end)

step(800, "only the real change is staged", function()
    local staged, unstaged = diffs()
    check("b's change is staged", staged:find("+b = 20", 1, true) ~= nil)
    check("a's trailing spaces are not staged", staged:find("+a = 1  ", 1, true) == nil
        and unstaged:find("+a = 1  ", 1, true) ~= nil)
    check("c's inner spaces are not staged", staged:find("+c  = 3", 1, true) == nil
        and unstaged:find("+c  = 3", 1, true) ~= nil)
    shot("ws02-file-included")
end)

step(300, "unstage it, then click b's row", function()
    git({ "reset", "-q", "--", "ws.txt" })
    require("core.app").requestRefresh()
end)

step(800, "click the change", function()
    -- Split rows: the hunk header, a (context), b (the change), c (context).
    gitgud.emit("DiffListNew.selected", "2")
end)

step(800, "the line box staged only b", function()
    local staged, unstaged = diffs()
    check("clicking b staged b", staged:find("+b = 20", 1, true) ~= nil)
    check("clicking b staged no whitespace", staged:find("+a = 1  ", 1, true) == nil
        and staged:find("+c  = 3", 1, true) == nil)
    check("whitespace changes are still in the working tree", unstaged:find("+a = 1  ", 1, true) ~= nil)
end)

step(300, "show whitespace, include the file", function()
    git({ "reset", "-q", "--", "ws.txt" })
    require("views.diff").setIgnoreWhitespace(false)
    local ok = require("core.staging").stage("ws.txt")
    check("including the file worked", ok == true)
end)

step(600, "everything is staged", function()
    local staged, unstaged = diffs()
    check("with whitespace shown the whole file is staged",
        staged:find("+a = 1  ", 1, true) ~= nil and unstaged == "")
end)

step(300, "clean up", function()
    git({ "reset", "-q", "--", "ws.txt" })
    git({ "checkout", "--", "ws.txt" })
end)

run(1)
