--- tests/ui/walkthrough.lua — an automated tour of the UI with screenshots.
--
-- Run the app with this as the test script (it runs after main.lua, in the
-- same Lua VM, so it can require the app's own modules):
--
--     set GITGUD_SCRIPT=D:\path\to\tests\ui\walkthrough.lua
--     set GITGUD_SHOTS=D:\some\folder          (where PNGs go; default ".")
--     gitgud.exe <a scratch repository>
--
-- Input is injected straight into the UI (gitgud.simulateClick / emit), so
-- it never touches the real mouse or keyboard. Each step waits a moment and
-- does one thing. Screenshots are captured on the NEXT frame, so a step that
-- takes one must not also change the UI. The app closes at the end.
-- Point it at a throwaway repository: it stages, commits, and branches.

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

--- Click the centre of a widget through the real hit-testing path.
-- @param name  widget name
-- @param kind  "left" | "right" | "double"
local function clickWidget(name, kind)
    local x, y, w, h = gitgud.getRect(name)
    if not x then
        print("[ui-test] no widget " .. name)
        return
    end
    gitgud.simulateClick(x + w / 2, y + h / 2, kind or "left")
end

--- Row index of a changed file in the Changes list.
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

step(900, "initial Changes view", function()
    shot("01-changes")
end)

step(300, "select src/main.cpp", function()
    clickChangesRow(rowOf("src/main.cpp") or 1)
end)

step(500, "diff of main.cpp", function()
    shot("02-diff-split")
end)

step(200, "include the first added line", function()
    -- Row 3 of the split lists is the first changed pair in this repo.
    gitgud.emit("DiffListNew.selected", "2")
end)

step(600, "after line toggle", function()
    shot("03-line-staged")
end)

step(200, "include notes.txt via its checkbox column", function()
    clickChangesRow(rowOf("notes.txt") or 1, "left", 16)
end)

step(500, "notes.txt included", function()
    local file = repo.load().files[rowOf("notes.txt") or 1]
    print("[check] " .. ((file and file.staged) and "PASS" or "FAIL") .. " checkbox column stages the file")
    shot("03b-checkbox")
end)

step(200, "unified view", function()
    require("views.diff").setMode("unified")
end)

step(500, "unified diff", function()
    shot("04-diff-unified")
end)

step(300, "back to split", function()
    require("views.diff").setMode("split")
end)

step(300, "type a summary", function()
    clickWidget("SummaryEdit")
    gitgud.simulateText("Tweak line two")
end)

step(400, "commit box filled", function()
    shot("05-summary")
end)

step(200, "commit with Ctrl+Enter", function()
    gitgud.emit("key", "ctrl+enter")
end)

step(900, "after commit (undo row)", function()
    shot("06-committed")
end)

step(200, "History tab", function()
    clickWidget("HistoryTab")
end)

step(700, "history", function()
    shot("07-history")
end)

step(200, "commit context menu", function()
    local x, y, w = gitgud.getRect("HistoryList")
    gitgud.emit("HistoryList.rightClicked", string.format("%d,%d,1", x + w / 2, y + 60))
end)

step(500, "context menu open", function()
    shot("08-commit-menu")
end)

step(200, "close menu", function()
    gitgud.emit("key", "escape")
end)

step(300, "branch popup", function()
    clickWidget("BranchButton")
end)

step(500, "branches", function()
    shot("09-branches")
end)

step(200, "filter branches", function()
    gitgud.simulateText("fea")
end)

step(400, "filtered branches", function()
    shot("10-branches-filtered")
end)

step(200, "close branches", function()
    gitgud.emit("key", "escape")
end)

step(300, "repository popup", function()
    clickWidget("RepoButton")
end)

step(500, "repositories", function()
    shot("11-repositories")
end)

step(200, "close repositories", function()
    gitgud.emit("key", "escape")
end)

step(300, "Repository menu", function()
    clickWidget("MenuBar_repository")
end)

step(500, "menu open", function()
    shot("12-menu")
end)

step(200, "close menu", function()
    gitgud.emit("key", "escape")
end)

step(300, "new branch dialog", function()
    gitgud.emit("key", "ctrl+shift+n")
end)

step(500, "dialog", function()
    shot("13-new-branch-dialog")
end)

step(200, "type the branch name", function()
    gitgud.simulateText("feature/walkthrough")
end)

step(300, "create the branch", function()
    gitgud.emit("DialogOkButton.clicked", "")
end)

step(800, "on the new branch", function()
    shot("14-new-branch")
end)

step(300, "options dialog", function()
    gitgud.emit("key", "ctrl+,")
end)

step(500, "options", function()
    shot("15-options")
end)

step(200, "close options", function()
    gitgud.emit("key", "escape")
end)

step(300, "repository settings", function()
    require("views.settings").repository()
end)

step(500, "repo settings", function()
    shot("16-repo-settings")
end)

step(200, "close repo settings", function()
    gitgud.emit("key", "escape")
end)

step(300, "back to Changes, image diff", function()
    clickWidget("ChangesTab")
    local row = rowOf("assets/logo.png")
    if row then
        clickChangesRow(row)
    end
end)

step(600, "onion skin", function()
    gitgud.emit("ImageModeOnion.clicked", "")
end)

step(500, "image onion", function()
    shot("17-image-onion")
end)

step(300, "stash everything", function()
    require("views.stash").stashAll()
end)

step(900, "after stash", function()
    shot("18-stashed")
end)

step(200, "view the stash", function()
    require("views.stash").view()
end)

step(700, "viewing stash", function()
    shot("19-stash-view")
end)

step(300, "about", function()
    require("views.about").show()
end)

step(500, "about dialog", function()
    shot("20-about")
end)

step(200, "close about", function()
    gitgud.emit("key", "escape")
end)

run(1)
