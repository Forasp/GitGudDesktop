--- views/sidebar.lua — the Changes / History tab switch.
--
-- Owns which tab is active. Other views subscribe to the "tab.changed"
-- signal (app.subscribe) rather than poking each other's widgets.
--
-- Public API:
--   sidebar.tab()            -> "changes" | "history"
--   sidebar.select(tab)

local C = require("core.palette")
local app = require("core.app")
local text = require("core.text")

local sidebar = { name = "sidebar" }

local activeTab = "changes"

--- Style the two tab buttons and swap the panels.
local function paint()
    local changes = activeTab == "changes"

    gitgud.setVisible("ChangesPanel", changes)
    gitgud.setVisible("HistoryPanel", not changes)
    gitgud.setVisible("ChangesTabBar", changes)
    gitgud.setVisible("HistoryTabBar", not changes)
    gitgud.setProperty("ChangesTab", "NormalTextColour", changes and C.text or C.text2)
    gitgud.setProperty("HistoryTab", "NormalTextColour", changes and C.text2 or C.text)
end

--- The active tab.
-- @return "changes" | "history"
function sidebar.tab()
    return activeTab
end

--- Switch tabs (no-op if already active).
-- @param tab  "changes" | "history"
function sidebar.select(tab)
    -- Asking for Changes / History means leaving the commit graph.
    local frame = require("views.frame")
    if frame.graphMode() then
        frame.setGraph(false)
    end
    if tab == activeTab then
        return
    end

    activeTab = tab
    paint()
    app.publish("tab.changed", tab)
end

--- Show the number of changed files on the Changes tab ("Changes  3").
-- @param state  repository snapshot
function sidebar.refresh(state)
    local count = #state.files
    local label = "Changes"

    if count > 0 then
        label = "Changes  " .. text.colour(C.dim, tostring(count))
    end
    gitgud.setText("ChangesTab", label)
end

--- Wire the tab buttons.
function sidebar.init()
    gitgud.on("ChangesTab.clicked", function()
        sidebar.select("changes")
    end)

    gitgud.on("HistoryTab.clicked", function()
        sidebar.select("history")
    end)

    paint()
end

return sidebar
