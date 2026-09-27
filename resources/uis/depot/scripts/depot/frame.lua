--- depot/frame.lua — lays out the Depot window: toolbar, address bar, the tree
-- pane, the tabbed views, and the Log pane, with draggable splitters
-- between them (sizes remembered in settings). View menu toggles hide the
-- toolbar, the address bar, and the Log pane.
--
-- Also splits panels internally (History, Submitted, Pending):
--     frame.splitPanel{ bar = "HistorySplit", container = "HistoryPanel",
--                       top = "HistoryGridHost", bottom = "HistoryDetailHost",
--                       offset = 26, setting = "depot.historySplit" }
--
-- Anything that must re-measure after a resize subscribes to the in-script
-- signal "layout.changed" (app.subscribe).

local app = require("core.app")
local geometry = require("ui.geometry")
local settings = require("core.settings")

local frame = { name = "frame" }

local MENU = 22
local TOOLBAR = 50
local ADDRESS = 28
local STATUS = 22
local SPLIT = 5

local panelSplits = {}

-- Sizes while dragging live here; they're saved when the drag ends.
local live = {}

--- A size: the live value during a drag, else the saved setting.
-- @param key       setting name
-- @param default   default value
-- @return number
local function size(key, default)
    if live[key] ~= nil then
        return live[key]
    end

    return settings.get(key, default)
end

--- Save every size changed by a drag.
local function persist()
    for key, value in pairs(live) do
        settings.set(key, value)
    end
    live = {}
end

local function leftWidth()
    return size("depot.leftWidth", 330)
end

local function bottomHeight()
    return size("depot.bottomHeight", 150)
end

--- True when the toolbar is shown.
function frame.toolbarVisible()
    return settings.get("depot.showToolbar", true)
end

--- True when the address bar is shown.
function frame.addressVisible()
    return settings.get("depot.showAddress", true)
end

--- True when the Log pane is shown.
function frame.bottomVisible()
    return settings.get("depot.showLog", true)
end

--- True when the tree pane is shown.
function frame.leftVisible()
    return settings.get("depot.showTree", true)
end

--- Position one panel split.
-- @param split  the splitPanel spec
local function layoutSplit(split)
    local fraction = size(split.setting, split.default or 0.55)
    local _, _, _, height = gitgud.getRect(split.container)
    if not height then
        return
    end
    local y = math.floor(split.offset + (height - split.offset) * fraction)
    gitgud.setProperty(split.top, "Area", geometry.area(0, 0, 0, split.offset, 1, 0, 0, y))
    gitgud.setProperty(split.bar, "Area", geometry.area(0, 0, 0, y, 1, 0, 0, y + SPLIT))
    gitgud.setProperty(split.bottom, "Area", geometry.area(0, split.inset or 0, 0, y + SPLIT, 1, -(split.inset or 0), 1, 0))
end

--- Lay out the whole window.
function frame.relayout()
    local top = MENU
    gitgud.setVisible("Toolbar", frame.toolbarVisible())
    if frame.toolbarVisible() then
        gitgud.setProperty("Toolbar", "Area", geometry.band(top, TOOLBAR))
        top = top + TOOLBAR
    end
    gitgud.setVisible("AddressBar", frame.addressVisible())
    if frame.addressVisible() then
        gitgud.setProperty("AddressBar", "Area", geometry.band(top, ADDRESS))
        top = top + ADDRESS
    end
    gitgud.setProperty("WorkArea", "Area", geometry.area(0, 0, 0, top, 1, 0, 1, -STATUS))

    local _, _, width, height = gitgud.getRect("WorkArea")
    if not width then
        return
    end

    local bottom = frame.bottomVisible() and math.max(60, math.min(bottomHeight(), height - 160)) or 0
    local upper = height - (bottom > 0 and bottom + SPLIT or 0)
    local left = frame.leftVisible() and math.max(160, math.min(leftWidth(), width - 320)) or 0

    gitgud.setVisible("LeftPane", left > 0)
    gitgud.setVisible("SplitLeft", left > 0)
    gitgud.setProperty("LeftPane", "Area", geometry.rect(0, 0, left, upper))
    gitgud.setProperty("SplitLeft", "Area", geometry.rect(left, 0, SPLIT, upper))
    local rightX = left > 0 and left + SPLIT or 4
    gitgud.setProperty("RightPane", "Area", geometry.area(0, rightX, 0, 0, 1, 0, 0, upper))

    gitgud.setVisible("BottomPane", bottom > 0)
    gitgud.setVisible("SplitBottom", bottom > 0)
    gitgud.setProperty("SplitBottom", "Area", geometry.area(0, 0, 0, upper, 1, 0, 0, upper + SPLIT))
    gitgud.setProperty("BottomPane", "Area", geometry.area(0, 0, 0, upper + SPLIT, 1, 0, 1, 0))

    for _, split in ipairs(panelSplits) do
        layoutSplit(split)
    end
    app.publish("layout.changed")
end

--- Toggle helpers for the View menu.
function frame.toggleToolbar()
    settings.set("depot.showToolbar", not frame.toolbarVisible())
    frame.relayout()
end

function frame.toggleAddress()
    settings.set("depot.showAddress", not frame.addressVisible())
    frame.relayout()
end

function frame.toggleBottom()
    settings.set("depot.showLog", not frame.bottomVisible())
    frame.relayout()
end

function frame.toggleLeft()
    settings.set("depot.showTree", not frame.leftVisible())
    frame.relayout()
end

--- Make a panel's top/bottom split draggable.
-- @param split  { bar, container, top, bottom, offset, setting, default?, inset? }
function frame.splitPanel(split)
    panelSplits[#panelSplits + 1] = split
    gitgud.setDraggable(split.bar, true)
    gitgud.on(split.bar .. ".dragging", function(value)
        local y = tonumber(value:match(",(-?%d+)$"))
        local _, cy, _, height = gitgud.getRect(split.container)
        if not y or not cy then
            return
        end
        local usable = height - split.offset
        local fraction = (y - cy - split.offset) / usable
        live[split.setting] = math.max(0.15, math.min(0.9, fraction))
        layoutSplit(split)
        app.publish("layout.changed")
    end)
    gitgud.on(split.bar .. ".dragEnded", persist)
    layoutSplit(split)
end

--- Wire the main splitters and the window size.
function frame.init()
    gitgud.setDraggable("SplitLeft", true)
    gitgud.setDraggable("SplitBottom", true)

    gitgud.on("SplitLeft.dragging", function(value)
        local x = tonumber(value:match("^(-?%d+)"))
        local wx = gitgud.getRect("WorkArea")
        if x and wx then
            live["depot.leftWidth"] = math.max(160, x - wx)
            frame.relayout()
        end
    end)

    gitgud.on("SplitBottom.dragging", function(value)
        local y = tonumber(value:match(",(-?%d+)$"))
        local _, wy, _, height = gitgud.getRect("WorkArea")
        if y and wy then
            live["depot.bottomHeight"] = math.max(60, wy + height - y - SPLIT)
            frame.relayout()
        end
    end)

    gitgud.on("SplitLeft.dragEnded", persist)
    gitgud.on("SplitBottom.dragEnded", persist)
    gitgud.on("window.resized", frame.relayout)
    frame.relayout()
end

return frame
