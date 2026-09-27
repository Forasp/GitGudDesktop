--- tests/ui/scrolling.lua — the mouse wheel over every column of the commit
-- graph and over the diff's hunk gutter (lists whose own scrollbar is
-- hidden), plus screenshots of the scrollbars and hunk boxes.
--
-- Same harness as the other scripts (GITGUD_SCRIPT / GITGUD_SHOTS). Needs a
-- repository with enough history to scroll (a few hundred commits) and a
-- changed file with more lines than fit, e.g. make-testrepo.ps1 plus a long
-- history, or any big scratch repository.

local OUT = os.getenv("GITGUD_SHOTS") or "."
local steps = {}

--- Queue a step.
-- @param delay  milliseconds to wait before running it
-- @param label  name for the log
-- @param fn     function() doing the step
local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end

--- Log a pass/fail line.
-- @param label  what was checked
-- @param ok     result
local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

--- Turn the wheel down over the middle of a widget.
-- @param name   widget
-- @param notches  wheel steps (positive = down)
local function wheelDown(name, notches)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateScroll(x + w / 2, y + h / 2, -notches)
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

step(1200, "open the graph", function()
    require("views.graph").show()
end)

for _, list in ipairs({ "GraphList", "GraphAuthorList", "GraphDateList" }) do
    step(800, "wheel over " .. list, function()
        gitgud.setScroll("GraphDateList", 0)
    end)
    step(300, "scroll " .. list, function()
        wheelDown(list, 3)
    end)
    step(300, "check " .. list, function()
        local a = gitgud.getScroll("GraphList")
        local b = gitgud.getScroll("GraphAuthorList")
        local c = gitgud.getScroll("GraphDateList")
        check("the wheel over " .. list .. " scrolls the graph", c > 0)
        check("all graph columns stay in step after scrolling " .. list, a == c and b == c)
    end)
end

step(300, "graph scrollbar", function()
    gitgud.screenshot(OUT .. "/s01-graph-scrolled.png")
end)

step(500, "back to Changes, show a long diff", function()
    require("views.graph").hide()
    local lines = {}
    for i = 1, 200 do
        lines[i] = "line " .. i .. " changed " .. ((i % 7 == 0) and "yes" or "no")
    end
    gitgud.writeRepoFile("long.txt", table.concat(lines, "\n") .. "\n")
    require("core.app").requestRefresh()
end)

step(900, "select the long file", function()
    require("views.diff").setMode("split")
    require("views.changes").select("long.txt")
end)

step(800, "wheel over the hunk gutter", function()
    gitgud.screenshot(OUT .. "/s02-diff-top.png")
    wheelDown("HunkGutter", 3)
end)

step(500, "gutter scrolled", function()
    check("the wheel over the hunk gutter scrolls the diff", gitgud.getScroll("DiffListNew") > 0)
    check("the gutter stays in step", gitgud.getScroll("HunkGutter") == gitgud.getScroll("DiffListNew"))
    gitgud.screenshot(OUT .. "/s03-diff-scrolled.png")
end)

run(1)
