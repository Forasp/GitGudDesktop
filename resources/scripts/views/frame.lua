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

local C = require("core.palette")
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
local SPLIT = 4            -- splitter grab width, centred on the seam
local MIN_CONTENT = 320    -- the content pane never gets narrower than this

local bands = { tabs = 0, notice = 0 }
local graphOn = false
local lastMainTop = nil
local live = {}            -- sizes while a splitter is dragged (saved when it's let go)

--- A remembered size: live while dragging, else the saved setting.
-- @param key       settings key
-- @param fallback  default
local function size(key, fallback)
    local value = live[key]
    if value == nil then
        value = settings.get(key, fallback)
    end

    return value
end

--- MainArea's width and height in pixels (a guess before the first layout).
local function mainSize()
    local _, _, w, h = gitgud.getRect("MainArea")
    return w or 1200, h or 700
end

--- Width of the branch tree (0 when hidden).
local function navigatorWidth()
    if not frame.navigatorVisible() then
        return 0
    end
    local w = mainSize()
    return math.max(150, math.min(size("navigatorWidth", NAVIGATOR_WIDTH), w - 280 - MIN_CONTENT))
end

--- Width of the Changes / History sidebar.
local function sidebarWidth(nav)
    local w = mainSize()
    return math.max(280, math.min(size("sidebarWidth", SIDEBAR_WIDTH), w - nav - MIN_CONTENT))
end

--- Height of MainArea's bottom dock (the console).
-- @return pixels
local function consoleHeight()
    if frame.consoleVisible() then
        local _, h = mainSize()
        return math.max(100, math.min(size("consoleHeight", CONSOLE_HEIGHT), h - 160))
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

    local nav = navigatorWidth()
    local bottom = consoleHeight()
    local half = SPLIT / 2

    gitgud.setVisible("Navigator", nav > 0)
    gitgud.setProperty("Navigator", "Area", geometry.area(0, 0, 0, 0, 0, nav, 1, -bottom))
    gitgud.setVisible("SplitNavigator", nav > 0)
    gitgud.setProperty("SplitNavigator", "Area", geometry.area(0, nav - half, 0, 0, 0, nav + half, 1, -bottom))

    gitgud.setVisible("ConsolePane", bottom > 0)
    gitgud.setProperty("ConsolePane", "Area", geometry.area(0, 0, 1, -bottom, 1, 0, 1, 0))
    gitgud.setVisible("SplitConsole", bottom > 0)
    gitgud.setProperty("SplitConsole", "Area", geometry.area(0, 0, 1, -bottom - half, 1, 0, 1, -bottom + half))

    if graphOn then
        local split = math.max(0.2, math.min(size("graphShare", GRAPH_SHARE), 0.85))
        gitgud.setVisible("Sidebar", false)
        gitgud.setVisible("GraphPanel", true)
        gitgud.setProperty("GraphPanel", "Area",
            geometry.area(0, nav, 0, 0, 1, 0, split, -bottom * split))
        gitgud.setProperty("ContentPane", "Area",
            geometry.area(0, nav, split, -bottom * split, 1, 0, 1, -bottom))
        gitgud.setVisible("SplitSidebar", false)
        gitgud.setVisible("SplitGraph", true)
        gitgud.setProperty("SplitGraph", "Area",
            geometry.area(0, nav, split, -bottom * split - half, 1, 0, split, -bottom * split + half))
    else
        local side = sidebarWidth(nav)
        gitgud.setVisible("Sidebar", true)
        gitgud.setVisible("GraphPanel", false)
        gitgud.setProperty("Sidebar", "Area", geometry.area(0, nav, 0, 0, 0, nav + side, 1, -bottom))
        gitgud.setProperty("ContentPane", "Area",
            geometry.area(0, nav + side, 0, 0, 1, 0, 1, -bottom))
        gitgud.setVisible("SplitGraph", false)
        gitgud.setVisible("SplitSidebar", true)
        gitgud.setProperty("SplitSidebar", "Area",
            geometry.area(0, nav + side - half, 0, 0, 0, nav + side + half, 1, -bottom))
    end
    for _, name in ipairs({ "SplitNavigator", "SplitSidebar", "SplitGraph", "SplitConsole" }) do
        gitgud.bringToFront(name)
    end

    app.publish("frame.changed")
end

--- Make the seams between regions draggable: the branch tree's and the
-- sidebar's widths, the graph / content split, and the console's height.
local function makeSplitters()
    local splitters = {
        { name = "SplitNavigator", direction = "horizontal", key = "navigatorWidth" },
        { name = "SplitSidebar", direction = "horizontal", key = "sidebarWidth" },
        { name = "SplitGraph", direction = "vertical", key = "graphShare" },
        { name = "SplitConsole", direction = "vertical", key = "consoleHeight" },
    }
    for _, s in ipairs(splitters) do
        gitgud.createWindow("Gitgud/Button", s.name, "MainArea")
        gitgud.setText(s.name, "")
        gitgud.setProperty(s.name, "NormalFillColour", C.transparent)
        gitgud.setProperty(s.name, "HoverFillColour", C.borderStrong)
        gitgud.setProperty(s.name, "PushedFillColour", C.blue)
        gitgud.setProperty(s.name, "BorderColour", C.transparent)
        gitgud.setDraggable(s.name, true, s.direction)

        gitgud.on(s.name .. ".dragging", function(value)
            local x, y = value:match("^(-?%d+),(-?%d+)$")
            local mx, my, mw, mh = gitgud.getRect("MainArea")
            x, y = tonumber(x), tonumber(y)
            if not x or not mx then
                return
            end
            if s.key == "navigatorWidth" then
                live.navigatorWidth = x - mx
            elseif s.key == "sidebarWidth" then
                live.sidebarWidth = x - mx - navigatorWidth()
            elseif s.key == "consoleHeight" then
                live.consoleHeight = my + mh - y
            else
                local usable = math.max(1, mh - consoleHeight())
                live.graphShare = (y - my) / usable
            end
            frame.relayout()
        end)
        gitgud.on(s.name .. ".dragEnded", function()
            -- Save what the layout actually used (after clamping).
            local nav = navigatorWidth()
            local values = {
                navigatorWidth = frame.navigatorVisible() and nav or nil,
                sidebarWidth = sidebarWidth(nav),
                consoleHeight = frame.consoleVisible() and consoleHeight() or nil,
                graphShare = live.graphShare and math.max(0.2, math.min(live.graphShare, 0.85)) or nil,
            }
            if values[s.key] then
                settings.set(s.key, values[s.key])
            end
            live = {}
            frame.relayout()
        end)
    end
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
    makeSplitters()
    frame.relayout()
    -- Clamps depend on the window size: keep the panes valid as it changes.
    gitgud.on("window.resized", frame.relayout)
end

return frame
