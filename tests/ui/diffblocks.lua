--- tests/ui/diffblocks.lua — per-block stage toggles in the diff.
--
-- One hunk holding two separate blocks of changes must show a box for each
-- block (split: in the middle gutter; unified: at the block's first row),
-- and each box must include only its own block. Same harness as the other
-- scripts; run it in any throwaway repository (it commits blocks.txt).

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

--- The staged flat indices of blocks.txt as a set.
-- @return { [idx] = true }
local function staged()
    local set = {}
    for _, idx in ipairs(gitgud.stagedLines("blocks.txt")) do
        set[idx] = true
    end
    return set
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

-- Lines 3 and 7 change: close enough to share one hunk, apart enough to be
-- two blocks. Flat lines: 1-2 context, 3 "-3", 4 "+3", 5-7 context,
-- 8 "-7", 9 "+7", 10-12 context.
step(1000, "make two blocks in one hunk", function()
    local lines = {}
    for n = 1, 10 do
        lines[n] = "line " .. n
    end
    gitgud.writeRepoFile("blocks.txt", table.concat(lines, "\n") .. "\n")
    gitgud.stage("blocks.txt")
    gitgud.commit("Add blocks.txt")
    lines[3] = "line 3 changed"
    lines[7] = "line 7 changed"
    gitgud.writeRepoFile("blocks.txt", table.concat(lines, "\n") .. "\n")
    require("core.app").requestRefresh()
end)

step(900, "split view", function()
    local diff = gitgud.diff("blocks.txt", "head")
    check("the change is one hunk", diff and #diff.hunks == 1)
    require("views.diff").setMode("split")
    require("views.changes").select("blocks.txt")
end)

step(700, "split view shown", function()
    gitgud.screenshot(OUT .. "/b01-split.png")
end)

step(400, "click the second block's box", function()
    -- Split rows: 1 header, 2-3 context, 4 block 1, 5-7 context, 8 block 2.
    gitgud.emit("HunkGutter.selected", "7")
end)

step(600, "second block included", function()
    local set = staged()
    check("the second block's box includes its lines", set[8] and set[9])
    check("...and nothing of the first block", not set[3] and not set[4])
    gitgud.screenshot(OUT .. "/b02-split-block2.png")
end)

step(400, "unified view", function()
    gitgud.setStagedLines("blocks.txt", {}, 12)
    require("views.diff").setMode("unified")
end)

step(700, "click the first block's box", function()
    -- Unified rows (0-based): 0 header, 1-2 context, 3 "-3" (block 1 start).
    local x, y = gitgud.getRect("DiffListUnified")
    gitgud.emit("DiffListUnified.clicked", string.format("%d,%d,3", x + 12, y + 40))
end)

step(600, "first block included", function()
    local set = staged()
    check("the unified block box includes the whole block", set[3] and set[4])
    check("...and nothing of the second block", not set[8] and not set[9])
    gitgud.screenshot(OUT .. "/b03-unified.png")
end)

step(400, "click a single line", function()
    local x, y = gitgud.getRect("DiffListUnified")
    -- Row 9 (0-based) is "+7": clicking the text toggles just that line.
    gitgud.emit("DiffListUnified.clicked", string.format("%d,%d,9", x + 300, y + 40))
end)

step(600, "single line included", function()
    local set = staged()
    check("clicking a line's text toggles only that line", set[9] and not set[8])
    require("views.diff").setMode("split")
end)

run(1)
