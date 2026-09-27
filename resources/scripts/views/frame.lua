--- views/frame.lua — where the big regions of the window go.
--
-- Everything between the toolbar and the status bar is laid out here, so
-- panels that come and go (repository tabs, the operation banner, the
-- branch tree, the commit graph, the console) never fight over Areas:
--
--   toolbar
--   TabStrip       (only with 2+ repositories open)   frame.setBand("tabs", h)
--   NoticeBar      (merge/rebase in progress, ...)    frame.setBand("notice", h)
--   MainArea:
--     Navigator | Sidebar | ContentPane               normal mode
--     Navigator | GraphPanel over ContentPane         graph mode
--     ConsolePane along the bottom                    when the console is open
--   status bar
--
-- Public API:
--   frame.setBand(name, height)       frame.relayout()
--   frame.setNavigator(bool)          frame.navigatorVisible()
--   frame.setGraph(bool)              frame.graphMode()
--   frame.setConsole(bool)            frame.consoleVisible()
-- Signals (app.publish): "frame.graphChanged" (on), "frame.changed"

local app = require("core.app")
local geometry = require("ui.geometry")
local settings = require("core.settings")

local frame = { name = "frame" }

local TOOLBAR_BOTTOM = 88
local STATUS_HEIGHT = 24
local NAVIGATOR_WIDTH = 236
local SIDEBAR_WIDTH = 320
local CONSOLE_HEIGHT = 230
local GRAPH_SHARE = 0.56   -- of the main area's height, in graph mode

local bands = { tabs = 0, notice = 0 }
local graphOn = false
local lastMainTop = nil

--- Height of MainArea's bottom dock (the console).
-- @return pixels
local function consoleHeight()
    if frame.consoleVisible() then
        return CONSOLE_HEIGHT
    end

    return 0
end

--- Put every region where it belongs.
function frame.relayout()
    local tabs = bands.tabs or 0
    local notice = bands.notice or 0

    gitgud.setVisible("TabStrip", tabs > 0)
    gitgud.setProperty("TabStrip", "Area", geometry.band(TOOLBAR_BOTTOM, math.max(tabs, 1)))
    gitgud.setProperty("NoticeBar", "Area", geometry.band(TOOLBAR_BOTTOM + tabs, 36))

    -- Moving MainArea re-lays-out everything inside it: only when it moved.
    local mainTop = TOOLBAR_BOTTOM + tabs + notice
    if mainTop ~= lastMainTop then
        lastMainTop = mainTop
        gitgud.setProperty("MainArea", "Area", geometry.area(0, 0, 0, mainTop, 1, 0, 1, -STATUS_HEIGHT))
    end

    local nav = frame.navigatorVisible() and NAVIGATOR_WIDTH or 0
    local bottom = consoleHeight()

    gitgud.setVisible("Navigator", nav > 0)
    gitgud.setProperty("Navigator", "Area", geometry.area(0, 0, 0, 0, 0, nav, 1, -bottom))

    gitgud.setVisible("ConsolePane", bottom > 0)
    gitgud.setProperty("ConsolePane", "Area", geometry.area(0, 0, 1, -bottom, 1, 0, 1, 0))

    if graphOn then
        local split = GRAPH_SHARE
        gitgud.setVisible("Sidebar", false)
        gitgud.setVisible("GraphPanel", true)
        gitgud.setProperty("GraphPanel", "Area",
            geometry.area(0, nav, 0, 0, 1, 0, split, -bottom * split))
        gitgud.setProperty("ContentPane", "Area",
            geometry.area(0, nav, split, -bottom * split, 1, 0, 1, -bottom))
    else
        gitgud.setVisible("Sidebar", true)
        gitgud.setVisible("GraphPanel", false)
        gitgud.setProperty("Sidebar", "Area", geometry.area(0, nav, 0, 0, 0, nav + SIDEBAR_WIDTH, 1, -bottom))
        gitgud.setProperty("ContentPane", "Area",
            geometry.area(0, nav + SIDEBAR_WIDTH, 0, 0, 1, 0, 1, -bottom))
    end

    app.publish("frame.changed")
end

--- Reserve (or release) a horizontal band above MainArea.
-- @param name    "tabs" | "notice"
-- @param height  pixels (0 hides it)
function frame.setBand(name, height)
    if bands[name] == height then
        return
    end

    bands[name] = height
    frame.relayout()
end

--- Is the branch tree showing?
-- @return boolean
function frame.navigatorVisible()
    return settings.get("showNavigator", true)
end

--- Show or hide the branch tree (remembered between runs).
-- @param visible  boolean
function frame.setNavigator(visible)
    settings.set("showNavigator", visible)
    frame.relayout()
end

--- Is the console open?
-- @return boolean
function frame.consoleVisible()
    return settings.get("showConsole", false)
end

--- Open or close the console (remembered between runs).
-- @param visible  boolean
function frame.setConsole(visible)
    settings.set("showConsole", visible)
    frame.relayout()
end

--- Is the commit graph taking over the main area?
-- @return boolean
function frame.graphMode()
    return graphOn
end

--- Switch graph mode on or off.
-- @param on  boolean
function frame.setGraph(on)
    if on == graphOn then
        return
    end

    graphOn = on
    frame.relayout()
    app.publish("frame.graphChanged", on)
end

--- Lay out once everything is loaded.
function frame.init()
    frame.relayout()
end

return frame
