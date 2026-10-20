--- tests/ui/renew.lua: renewing the main window (main.cpp's renewWindow,
-- core/display.lua), through the real UI.
--
-- Run it in a repository made by make-testrepo.ps1 with GITGUD_UI=default, a
-- scratch APPDATA, GITGUD_SCRIPT pointing here, and GITGUD_SHOTS. A script
-- asks for a renewal, then display changes come in close together: each time
-- the window is replaced, the UI looks the same afterwards (same size, a
-- screenshot like the one before) and still takes input. Prints
-- "[check] ..." lines.

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

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local n = f:seek("end")
    f:close()
    return n
end

-- A screenshot that looks like the first: same pixel size, and a file within
-- a quarter of its size (a window showing nothing compresses to far less).
local function likeBefore(path, first)
    local w, h = gitgud.imageSize(path)
    local wa, ha = gitgud.imageSize(first)
    local n, na = fileSize(path), fileSize(first)
    return w ~= nil and w == wa and h == ha and na > 0 and math.abs(n - na) <= na / 4,
        string.format("%sx%s, %d bytes; before %sx%s, %d bytes", tostring(w), tostring(h), n, tostring(wa),
            tostring(ha), na)
end

local renewals = {}
gitgud.on("window.renewed", function(why)
    renewals[#renewals + 1] = why
end)

local before = {}
local FIRST = OUT .. "/renew-0-before.png"
local steps = {
    function()
        before.nav = rect("Navigator")
        gitgud.screenshot(FIRST)
    end,
    function()
        gitgud.emit("window.renew", "asked by the test")
    end,
    function()
        check("the window was renewed once", #renewals == 1)
        check("for the reason asked", renewals[1] == "asked by the test")
        gitgud.screenshot(OUT .. "/renew-1-after.png")
    end,
    function()
        local ok, info = likeBefore(OUT .. "/renew-1-after.png", FIRST)
        check("the renewed window shows the UI as before (" .. info .. ")", ok)
        local nav = rect("Navigator")
        check("the layout is unchanged", nav.w == before.nav.w and nav.h == before.nav.h)
        -- Input still reaches the UI: drag the branch tree's splitter.
        local x, y = mid("SplitNavigator")
        gitgud.simulateDrag(x, y, x + 80, y)
    end,
    function()
        check("the UI still takes input (" .. before.nav.w .. " -> " .. rect("Navigator").w .. ")",
            rect("Navigator").w >= before.nav.w + 70)
        local x, y = mid("SplitNavigator")
        gitgud.simulateDrag(x, y, x - 80, y)
        -- Display changes close together: one renewal once they settle.
        gitgud.emit("display.changed", "a display was connected")
        gitgud.emit("display.changed", "the display settings changed")
        gitgud.emit("display.changed", "a display was connected")
    end,
    function()
        check("not renewed before the changes settle", #renewals == 1)
        check("the changes wait together",
            #require("core.display").pending() == 2)
    end,
    function()
        -- SETTLE_MS (1.5 s) after the last change.
        check("renewed once for the display changes", #renewals == 2)
        check("naming each change once, in order",
            renewals[2] == "a display was connected, the display settings changed")
        gitgud.screenshot(OUT .. "/renew-2-after-display.png")
    end,
    function()
        local ok, info = likeBefore(OUT .. "/renew-2-after-display.png", FIRST)
        check("still the UI as before after the second renewal (" .. info .. ")", ok)
        gitgud.emit("window.close", "")
    end,
}

local DELAYS = { 2500, 700, 900, 900, 900, 400, 1700, 900 }

local function run(i)
    if steps[i] then
        gitgud.after(DELAYS[i] or 700, function()
            local ok, err = pcall(steps[i])
            if not ok then
                check("step " .. i .. " ran without errors: " .. tostring(err), false)
            end
            run(i + 1)
        end)
    end
end

run(1)
