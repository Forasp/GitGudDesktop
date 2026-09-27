--- depot/tabs.lua — Windows-style tab strips.
--
-- A strip is a row of buttons created inside a container widget; the
-- selected tab is white and joins the pane below it, the others are grey.
--
--     tabs.create("RightTabs", {
--         { id = "history", label = "History", icon = "History" },
--         { id = "pending", label = "Pending" },
--     }, function(id) ... end)
--     tabs.select("RightTabs", "pending")      -- also calls the handler
--     tabs.current("RightTabs")                -- "pending"

local C = require("core.palette")
local geometry = require("ui.geometry")
local text = require("core.text")

local tabs = {}

local strips = {}   -- container -> { items, current, onSelect }

local CHAR_WIDTH = 6.6
local PADDING = 34
local ICON_ROOM = 20

--- Style every tab of a strip for the current selection.
-- @param container  strip container
local function paint(container)
    local strip = strips[container]
    for i, item in ipairs(strip.items) do
        local name = container .. "_Tab" .. i
        local active = item.id == strip.current
        gitgud.setProperty(name, "NormalFillColour", active and C.tabActive or C.tabInactive)
        gitgud.setProperty(name, "HoverFillColour", active and C.tabActive or C.tabHover)
        gitgud.setProperty(name, "PushedFillColour", active and C.tabActive or C.selection)
        gitgud.setProperty(name, "BorderColour", C.border)
        gitgud.setVisible(name .. "Mask", active)
    end
end

--- Lay the tabs out left to right (visible ones only).
-- @param container  strip container
local function layout(container)
    local strip = strips[container]
    local x = 0
    for i, item in ipairs(strip.items) do
        local name = container .. "_Tab" .. i
        gitgud.setVisible(name, item.hidden ~= true)
        if not item.hidden then
            local width = math.floor(#item.label * CHAR_WIDTH + PADDING + (item.icon and ICON_ROOM or 0))
            gitgud.setProperty(name, "Area", geometry.area(0, x, 0, 0, 0, x + width, 1, 1))
            x = x + width - 1
        end
    end
end

--- Build a strip.
-- @param container  widget the tabs go in (an empty DefaultWindow)
-- @param items      array of { id, label, icon?, hidden? }
-- @param onSelect   function(id) when a tab is chosen
function tabs.create(container, items, onSelect)
    strips[container] = { items = items, current = items[1] and items[1].id, onSelect = onSelect }

    for i, item in ipairs(items) do
        local name = container .. "_Tab" .. i
        gitgud.createWindow("Gitgud/Button", name, container)
        local label = text.escape(item.label)
        if item.icon then
            label = require("depot.icons").inline(item.icon) .. " " .. label
        end
        gitgud.setText(name, label)
        gitgud.setProperty(name, "NormalTextColour", C.text)

        -- A white strip over the tab's bottom border joins it to the pane.
        gitgud.createWindow("Gitgud/StaticText", name .. "Mask", name)
        gitgud.setProperty(name .. "Mask", "Area", geometry.area(0, 1, 1, -1, 1, -1, 1, 0))
        gitgud.setProperty(name .. "Mask", "PanelColour", C.tabActive)
        gitgud.setProperty(name .. "Mask", "CursorPassThroughEnabled", "true")
        gitgud.setText(name .. "Mask", "")

        local id = item.id
        gitgud.on(name .. ".clicked", function()
            tabs.select(container, id)
        end)
    end

    layout(container)
    paint(container)
end

--- Select a tab (runs the strip's handler).
-- @param container  strip container
-- @param id         tab id
function tabs.select(container, id)
    local strip = strips[container]
    if not strip then
        return
    end

    strip.current = id
    paint(container)
    if strip.onSelect then
        strip.onSelect(id)
    end
end

--- The selected tab's id.
-- @param container  strip container
-- @return id or nil
function tabs.current(container)
    local strip = strips[container]
    return strip and strip.current
end

--- Show or hide a tab (View menu toggles).
-- @param container  strip container
-- @param id         tab id
-- @param visible    boolean
function tabs.setVisible(container, id, visible)
    local strip = strips[container]
    if not strip then
        return
    end

    for _, item in ipairs(strip.items) do
        if item.id == id then
            item.hidden = not visible
        end
    end
    layout(container)
end

--- Is a tab shown?
-- @param container  strip container
-- @param id         tab id
-- @return boolean
function tabs.isVisible(container, id)
    local strip = strips[container]
    for _, item in ipairs(strip and strip.items or {}) do
        if item.id == id then
            return not item.hidden
        end
    end

    return false
end

return tabs
