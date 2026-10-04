--- tests/ui/splitters.lua: resizing the default UI's regions by dragging,
-- through the real UI.
--
-- Run it in a repository made by make-testrepo.ps1 with GITGUD_UI=default, a
-- scratch APPDATA, GITGUD_SCRIPT pointing here, and GITGUD_SHOTS. It drags
-- the branch tree's and the sidebar's splitters, the console's top edge, and
-- the graph / content split (gitgud.simulateDrag), checks the panes follow
-- and keep their minimum sizes, then puts things back. Prints "[check] ..."
-- lines.

local OUT = os.getenv("GITGUD_SHOTS") or "."

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local function rect(name)
    local x, y, w, h = gitgud.getRect(name)
    return { x = x, y = y, w = w, h = h }
end

local function mid(name)
    local r = rect(name)
    return r.x + r.w / 2, r.y + r.h / 2
end

local before = {}
local steps = {
    function()
        before.nav = rect("Navigator").w
        before.side = rect("Sidebar").w
        gitgud.screenshot(OUT .. "/splitters-before.png")
        local x, y = mid("SplitNavigator")
        gitgud.simulateDrag(x, y, x + 80, y)
    end,
    function()
        check("branch tree widened by the drag (" .. before.nav .. " -> " .. rect("Navigator").w .. ")",
            rect("Navigator").w >= before.nav + 70)
        local x, y = mid("SplitSidebar")
        gitgud.simulateDrag(x, y, x + 120, y)
    end,
    function()
        check("sidebar widened by the drag (" .. before.side .. " -> " .. rect("Sidebar").w .. ")",
            rect("Sidebar").w >= before.side + 110)
        local x, y = mid("SplitSidebar")
        gitgud.simulateDrag(x, y, x + 5000, y)
    end,
    function()
        check("content pane keeps its minimum width (" .. rect("ContentPane").w .. ")", rect("ContentPane").w >= 315)
        local x, y = mid("SplitSidebar")
        gitgud.simulateDrag(x, y, x - 5000, y)
    end,
    function()
        check("sidebar keeps its minimum width (" .. rect("Sidebar").w .. ")", rect("Sidebar").w >= 275)
        require("views.console").toggle()
    end,
    function()
        before.console = rect("ConsolePane").h
        local x, y = mid("SplitConsole")
        gitgud.simulateDrag(x, y, x, y - 100)
    end,
    function()
        check("console taller by the drag (" .. before.console .. " -> " .. rect("ConsolePane").h .. ")",
            rect("ConsolePane").h >= before.console + 90)
        gitgud.screenshot(OUT .. "/splitters-after.png")
        require("views.console").toggle()
        require("views.graph").toggle()
    end,
    function()
        before.graph = rect("GraphPanel").h
        local x, y = mid("SplitGraph")
        gitgud.simulateDrag(x, y, x, y - 80)
    end,
    function()
        check("graph shorter by the drag (" .. before.graph .. " -> " .. rect("GraphPanel").h .. ")",
            rect("GraphPanel").h <= before.graph - 70)
        gitgud.screenshot(OUT .. "/splitters-graph.png")
        require("views.graph").toggle()
    end,
    function()
        -- Put the sizes back for whoever runs the next test with this APPDATA.
        local settings = require("core.settings")
        settings.set("navigatorWidth", before.nav)
        settings.set("sidebarWidth", before.side)
        settings.set("graphShare", 0.56)
        gitgud.emit("window.close", "")
    end,
}

local function run(i)
    if steps[i] then
        gitgud.after(i == 1 and 2500 or 700, function()
            local ok, err = pcall(steps[i])
            if not ok then
                check("step " .. i .. " ran without errors: " .. tostring(err), false)
            end
            run(i + 1)
        end)
    end
end

run(1)
