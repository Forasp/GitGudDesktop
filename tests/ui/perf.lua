--- tests/ui/perf.lua — rough timings of the interactive hot paths.
--
-- Same harness as walkthrough.lua. Creates 300 new files and a 3,000-line
-- file edit in the (throwaway!) repository, then times each action through
-- the frame that draws its result (CEGUI lays lists out while rendering, so
-- timing only the Lua call would miss most of the cost). Results are
-- printed as "[perf] ..." lines.

local app = require("core.app")
local content = require("views.content")
local repo = require("core.repo")

local queue = {}

--- Queue a timed action.
-- @param label  what is being timed
-- @param fn     function to run
local function timed(label, fn)
    queue[#queue + 1] = { label = label, fn = fn }
end

--- Run queued action i: time from the call until the next frame is drawn
-- (a 0 ms timer fires on the loop iteration after that render).
-- @param i  queue index
local function runNext(i)
    local item = queue[i]
    if not item then
        print("[perf] files in status: " .. #repo.state().files)
        gitgud.after(300, function()
            gitgud.emit("window.close", "")
        end)
        return
    end

    gitgud.after(250, function()
        local started = gitgud.now()
        item.fn()
        gitgud.after(0, function()
            print(string.format("[perf] %-44s %5d ms", item.label, gitgud.now() - started))
            runNext(i + 1)
        end)
    end)
end

timed("(setup) write 300 new files", function()
    for i = 1, 300 do
        gitgud.writeRepoFile(string.format("bulk/file%03d.txt", i), "content " .. i .. "\n")
    end
end)

timed("first paint of 305 file rows", function()
    require("views.changes").resetRows()
    app.refreshNow()
end)

timed("refresh with nothing changed", function()
    app.refreshNow()
end)

timed("render a 3,000-line diff (split)", function()
    local lines = {}
    for i = 1, 3000 do
        lines[i] = "line " .. i .. " of the big file"
    end
    gitgud.writeRepoFile("big.txt", table.concat(lines, "\n") .. "\n")
    gitgud.stage("big.txt")
    gitgud.commit("Add big file")
    for i = 1, 3000, 2 do
        lines[i] = "LINE " .. i .. " was edited"
    end
    gitgud.writeRepoFile("big.txt", table.concat(lines, "\n") .. "\n")
    repo.load()
    content.showWorkingFile("big.txt", true)
end)

timed("toggle one line (stage it)", function()
    gitgud.emit("DiffListNew.selected", "2")
end)

timed("scroll the big diff by 40 rows", function()
    gitgud.setScroll("DiffListNew", gitgud.getScroll("DiffListNew") + 640)
end)

timed("switch to unified view", function()
    require("views.diff").setMode("unified")
end)

timed("switch back to split view", function()
    require("views.diff").setMode("split")
end)

timed("open History (300 commits max)", function()
    require("views.sidebar").select("history")
end)

gitgud.after(800, function()
    runNext(1)
end)
