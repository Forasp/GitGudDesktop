--- tests/ui/mod-example.lua — checks the example mod end to end.
--
-- Test scripts run after app.start(), so this attaches the mod the same way
-- app.start() would (layout, then init) and opens its panel from the Tools
-- menu it registers.

local stats = require("mods.example_stats")
local OUT = os.getenv("GITGUD_SHOTS") or "."

gitgud.after(800, function()
    local attached = gitgud.loadLayout(stats.layout, stats.parent)
    print("[check] " .. (attached and "PASS" or "FAIL") .. " mod layout attached")
    stats.init()
    gitgud.emit("key", "ctrl+alt+s")

    gitgud.after(500, function()
        local shown = gitgud.getProperty("StatsPanel", "Visible") == "true"
        print("[check] " .. (shown and "PASS" or "FAIL") .. " mod panel opened by its shortcut")
        gitgud.screenshot(OUT .. "/m01-mod-panel.png")

        gitgud.after(400, function()
            gitgud.emit("window.close", "")
        end)
    end)
end)
