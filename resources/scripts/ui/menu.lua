--- ui/menu.lua — the title-bar menus and right-click context menus.
--
-- Menus are data. The menu bar buttons and every dropdown are built at
-- runtime from item tables, so any module (or mod) can add to them:
--
--     menu.addMenu("tools", "Tools")
--     menu.addItem("tools", {
--         label = "Count lines",
--         shortcut = "ctrl+alt+l",           -- shown right-aligned + bound
--         enabled = function() return repo.state().open end,
--         action = function() ... end,
--     })
--
-- Item fields (all optional except label/action; functions are evaluated
-- each time the menu opens):
--   label      text                 action    function() on click
--   shortcut   combo, e.g. "ctrl+p" enabled   bool | function() -> bool
--   checked    bool | function()    visible   bool | function() -> bool
--   separator  true for a divider line (no label/action)
--   expand     function() -> items, replaced by those items at open time
--
-- Context menus take the same item tables:
--     menu.popup(items, x, y)

local C = require("core.palette")
local geometry = require("ui.geometry")
local keys = require("core.keys")
local popup = require("ui.popup")
local text = require("core.text")

local menu = {}

local PANEL = "MenuPanel"          -- border colour; items live in PANEL_FILL
local PANEL_FILL = "MenuPanelFill"
local ITEM_HEIGHT = 30
local SEPARATOR_HEIGHT = 9
local PADDING = 4
local MIN_WIDTH = 220

local menus = {}          -- id -> { id, label, items = {} }
local menuOrder = {}      -- ids in bar order
local shown = {}          -- resolved items of the open menu, by pool index
local itemsBuilt = 0      -- item widgets created so far
local separatorsBuilt = 0

--- Evaluate a field that may be a value or a function returning one.
-- @param value     bool/string/function/nil
-- @param fallback  used when value is nil
-- @return the resolved value
local function resolve(value, fallback)
    if type(value) == "function" then
        return value()
    end
    if value == nil then
        return fallback
    end

    return value
end

--- Rough pixel width of a string in the UI font (no text metrics from Lua).
-- @param s  plain text
-- @return estimated width in pixels
local function estimateWidth(s)
    return #s * 7
end

--- Create the item widget for pool slot i, and wire its click once.
-- @param i  pool index
local function buildItem(i)
    local name = "MenuItem" .. i
    local keyName = "MenuItemKey" .. i

    gitgud.createWindow("Gitgud/Button", name, PANEL_FILL)
    gitgud.setProperty(name, "HorzFormatting", "LeftAligned")
    gitgud.setProperty(name, "NormalFillColour", C.bg2)
    gitgud.setProperty(name, "HoverFillColour", C.bg4)
    gitgud.setProperty(name, "PushedFillColour", C.bg3)

    gitgud.createWindow("Gitgud/Label", keyName, name)
    gitgud.setProperty(keyName, "Area", geometry.area(0, 0, 0, 0, 1, -12, 1, 0))
    gitgud.setProperty(keyName, "HorzFormatting", "RightAligned")
    gitgud.setProperty(keyName, "Font", "Gitgud-UI-Small")
    gitgud.setProperty(keyName, "NormalTextColour", C.dim)

    gitgud.on(name .. ".clicked", function()
        local item = shown[i]
        popup.close()
        if item and item.action then
            item.action()
        end
    end)
end

--- Create separator widget j.
-- @param j  pool index
local function buildSeparator(j)
    local name = "MenuSeparator" .. j

    gitgud.createWindow("Gitgud/StaticText", name, PANEL_FILL)
    gitgud.setProperty(name, "PanelColour", C.border)
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    gitgud.setText(name, "")
end

--- Fill the shared panel with `items` and return its size.
-- @param items  array of item tables
-- @return width, height of the panel
local function fillPanel(items)
    -- Expand dynamic groups ({ expand = function() return items end }) and
    -- drop hidden items.
    local visible = {}
    for _, item in ipairs(items) do
        if item.expand then
            for _, expanded in ipairs(item.expand()) do
                visible[#visible + 1] = expanded
            end
        elseif resolve(item.visible, true) then
            visible[#visible + 1] = item
        end
    end

    -- Size the panel to the widest label + shortcut.
    local width = MIN_WIDTH
    for _, item in ipairs(visible) do
        if not item.separator then
            local keyText = item.shortcut and keys.label(item.shortcut) or ""
            local wanted = estimateWidth(item.label) + estimateWidth(keyText) + 72
            width = math.max(width, wanted)
        end
    end

    local y = PADDING
    local itemIndex = 0
    local separatorIndex = 0
    shown = {}

    for _, item in ipairs(visible) do
        if item.separator then
            separatorIndex = separatorIndex + 1
            if separatorIndex > separatorsBuilt then
                buildSeparator(separatorIndex)
                separatorsBuilt = separatorIndex
            end
            local name = "MenuSeparator" .. separatorIndex
            gitgud.setProperty(name, "Area", geometry.area(0, 8, 0, y + 4, 1, -8, 0, y + 5))
            gitgud.setVisible(name, true)
            y = y + SEPARATOR_HEIGHT
        else
            itemIndex = itemIndex + 1
            if itemIndex > itemsBuilt then
                buildItem(itemIndex)
                itemsBuilt = itemIndex
            end

            local name = "MenuItem" .. itemIndex
            local mark = resolve(item.checked, false) and "✓  " or "    "
            local enabled = resolve(item.enabled, true)

            gitgud.setProperty(name, "Area", geometry.area(0, PADDING, 0, y, 1, -PADDING, 0, y + ITEM_HEIGHT))
            gitgud.setText(name, text.escape(mark .. item.label))
            gitgud.setText("MenuItemKey" .. itemIndex, item.shortcut and keys.label(item.shortcut) or "")
            gitgud.setEnabled(name, enabled)
            gitgud.setVisible(name, true)
            shown[itemIndex] = item
            y = y + ITEM_HEIGHT
        end
    end

    for i = itemIndex + 1, itemsBuilt do
        gitgud.setVisible("MenuItem" .. i, false)
    end
    for j = separatorIndex + 1, separatorsBuilt do
        gitgud.setVisible("MenuSeparator" .. j, false)
    end

    return width, y + PADDING
end

--- Show a context menu at an absolute position.
-- @param items  array of item tables (see the header)
-- @param x      left edge in window pixels
-- @param y      top edge in window pixels
function menu.popup(items, x, y)
    local width, height = fillPanel(items)

    gitgud.setProperty(PANEL, "Area", geometry.rect(x, y, width, height))
    popup.open(PANEL, { x = x, y = y })
end

--- Parse a "x,y,row" rightClicked payload.
-- @param value  event detail from C++
-- @return x, y, row (row is a 1-based list row, or nil)
function menu.parseClick(value)
    local x, y, row = value:match("^(-?%d+),(-?%d+),(-?%d+)$")
    local rowNumber = tonumber(row)

    if rowNumber and rowNumber >= 0 then
        rowNumber = rowNumber + 1
    else
        rowNumber = nil
    end

    return tonumber(x) or 0, tonumber(y) or 0, rowNumber
end

--- Open one of the menu-bar menus under its button.
-- @param id  menu id
function menu.open(id)
    local entry = menus[id]
    if not entry then
        return
    end

    local button = "MenuBar_" .. id
    local bx, by, _, bh = gitgud.getRect(button)
    local width, height = fillPanel(entry.items)

    gitgud.setProperty(PANEL, "Area", geometry.rect(bx, by + bh, width, height))
    popup.open(PANEL, { x = bx, y = by + bh })
end

--- Lay out the menu-bar buttons left to right.
local function layoutBar()
    local x = 0

    for _, id in ipairs(menuOrder) do
        local entry = menus[id]
        local width = estimateWidth(entry.label) + 26
        gitgud.setProperty("MenuBar_" .. id, "Area", geometry.area(0, x, 0, 0, 0, x + width, 1, 0))
        x = x + width
    end
end

--- Add a menu to the bar (no-op if the id exists).
-- @param id     stable identifier, e.g. "repository"
-- @param label  button text, e.g. "Repository"
function menu.addMenu(id, label)
    if menus[id] then
        return
    end

    menus[id] = { id = id, label = label, items = {} }
    menuOrder[#menuOrder + 1] = id

    local button = "MenuBar_" .. id
    gitgud.createWindow("Gitgud/Button", button, "MenuBar")
    gitgud.setText(button, text.escape(label))
    gitgud.setProperty(button, "NormalFillColour", C.bg0)
    gitgud.setProperty(button, "HoverFillColour", C.bg3)
    gitgud.setProperty(button, "PushedFillColour", C.bg1)
    gitgud.setProperty(button, "NormalTextColour", C.text2)

    gitgud.on(button .. ".clicked", function()
        if popup.isOpen(PANEL) then
            popup.close()
        else
            menu.open(id)
        end
    end)

    layoutBar()
end

--- Append an item (see the header) to a menu, binding its shortcut.
-- @param id    menu id (created by addMenu)
-- @param item  item table
function menu.addItem(id, item)
    local entry = menus[id]
    if not entry then
        error("menu.addItem: no menu '" .. tostring(id) .. "'")
    end

    table.insert(entry.items, item)

    if item.shortcut and item.action then
        keys.bind(item.shortcut, function()
            if resolve(item.enabled, true) and resolve(item.visible, true) then
                item.action()
            end
        end, item.label)
    end
end

--- Append several items at once.
-- @param id     menu id
-- @param items  array of item tables
function menu.addItems(id, items)
    for _, item in ipairs(items) do
        menu.addItem(id, item)
    end
end

--- Every menu item as a flat list, for the command palette: dynamic groups
-- are expanded, separators and hidden items dropped.
-- @return array of { menu = "Branch", item = itemTable }
function menu.entries()
    local out = {}

    for _, id in ipairs(menuOrder) do
        local entry = menus[id]
        for _, item in ipairs(entry.items) do
            local group = item.expand and item.expand() or { item }
            for _, candidate in ipairs(group) do
                if not candidate.separator and candidate.action and resolve(candidate.visible, true) then
                    out[#out + 1] = { menu = entry.label, item = candidate }
                end
            end
        end
    end

    return out
end

--- Is an item enabled right now?
-- @param item  item table
-- @return boolean
function menu.isEnabled(item)
    return resolve(item.enabled, true)
end

--- Create the shared dropdown panel. Called once by main.lua.
function menu.init()
    gitgud.createWindow("Gitgud/StaticText", PANEL, "Root")
    gitgud.setProperty(PANEL, "PanelColour", C.borderStrong)
    gitgud.setProperty(PANEL, "AlwaysOnTop", "true")
    gitgud.setText(PANEL, "")
    gitgud.setVisible(PANEL, false)

    gitgud.createWindow("Gitgud/StaticText", PANEL_FILL, PANEL)
    gitgud.setProperty(PANEL_FILL, "Area", geometry.area(0, 1, 0, 1, 1, -1, 1, -1))
    gitgud.setProperty(PANEL_FILL, "PanelColour", C.bg2)
    gitgud.setText(PANEL_FILL, "")
end

return menu
