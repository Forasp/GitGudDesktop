--- depot/grid.lua — tables: column headers you can click to sort and
-- drag to resize, rows you can multi-select (Ctrl/Shift+click), right-click,
-- double-click, and drag.
--
-- Built from one list widget per column, scrolled together
-- (gitgud.linkScroll links are transitive) with their selections mirrored.
--
--     grid.create("HistoryGrid", "HistoryGridHost", {
--         columns = {
--             { key = "rev", title = "Revision", width = 70 },
--             { key = "desc", title = "Description" },   -- the last column fills
--         },
--         multi = true,
--         onSelect = function(rows) end,        -- the selected row tables
--         onActivate = function(row) end,       -- double-click / Enter
--         onContext = function(rows, x, y) end, -- right-click
--         onDrag = function(fromRow, toRow) end,
--         settingKey = "grid.history",          -- where column widths persist
--     })
--     grid.setRows("HistoryGrid", { { cells = { rev = "#3", desc = "Fix" }, data = ... } })
--
-- A cell is plain text (escaped for you), or { markup = "..." } for rich
-- content (icons, colours). A row may set `icon` (markup put before its
-- first cell), `colour` (its text colour), and `sort` = { key = value } to
-- sort by something other than the shown text.

local C = require("core.palette")
local geometry = require("ui.geometry")
local settings = require("core.settings")
local text = require("core.text")

local grid = {}

local HEADER_HEIGHT = 22
local ROW_HEIGHT = 20
local DIVIDER = 5
local MIN_WIDTH = 28
-- An invisible tail on every cell, past the column's edge: CEGUI decides
-- whether a row is selected by comparing item TEXT, so cells that read the
-- same (a date, a user) would light up together; the row number after the
-- tail keeps every cell unique without showing.
local TAIL = "[image-size='w:4000 h:1'][image='Depot-Icons/Spacer'][colour='00000000']"

local grids = {}   -- name -> state

--- The markup for one cell.
-- @param state   grid state
-- @param row     row table
-- @param column  column spec
-- @param first   true for the first column
-- @param index   the row's position (keeps the markup unique)
-- @return markup
local function cellMarkup(state, row, column, first, index)
    local value = row.cells[column.key]
    local body
    if type(value) == "table" then
        body = value.markup or ""
    else
        body = text.colour(row.colour or C.text, value == nil and "" or tostring(value))
    end
    if first and row.icon then
        body = row.icon .. " " .. body
    end

    return text.rowHeight(state.rowHeight) .. " " .. body .. TAIL .. index
end

--- Sort key of a cell (row.sort overrides, then plain text).
-- @param row  row table
-- @param key  column key
-- @return comparable value
local function sortValue(row, key)
    if row.sort and row.sort[key] ~= nil then
        return row.sort[key]
    end
    local value = row.cells[key]
    if type(value) == "table" then
        return value.sort or value.text or ""
    end
    if type(value) == "number" then
        return value
    end

    return tostring(value or ""):lower()
end

--- Order the rows by the sort column.
-- @param state  grid state
local function applySort(state)
    state.view = {}
    for i, row in ipairs(state.rows) do
        state.view[i] = row
    end
    if not state.sortKey then
        return
    end

    local key = state.sortKey
    local descending = state.sortDescending
    local order = {}
    for i, row in ipairs(state.view) do
        order[row] = i
    end
    table.sort(state.view, function(a, b)
        local va = sortValue(a, key)
        local vb = sortValue(b, key)
        if type(va) ~= type(vb) then
            va = tostring(va)
            vb = tostring(vb)
        end
        if va == vb then
            return order[a] < order[b]
        end
        if descending then
            return va > vb
        end
        return va < vb
    end)
end

--- Column x positions for the current widths; the last column fills.
-- @param state  grid state
-- @return array of { x, width }
local function columnSpans(state)
    local _, _, total = gitgud.getRect(state.name)
    total = total or 600
    local spans = {}
    local x = 0
    for i, column in ipairs(state.columns) do
        local width = column.width or 120
        if i == #state.columns then
            width = math.max(MIN_WIDTH, total - x)
        end
        spans[i] = { x = x, width = width }
        x = x + width
    end

    return spans
end

--- Position headers, dividers, and column lists. Only the grid's width and
-- the column widths matter, so a pass that changes neither (a height-only
-- resize, a splitter elsewhere, a grid on a hidden tab) is skipped.
-- @param state  grid state
-- @param force  lay out even if the width is unchanged (column widths moved)
local function layout(state, force)
    local _, _, width = gitgud.getRect(state.name)
    if not force and width and width == state.laidOutWidth then
        return
    end
    state.laidOutWidth = width
    local spans = columnSpans(state)
    for i, span in ipairs(spans) do
        local header = state.name .. "H" .. i
        gitgud.setProperty(header, "Area", geometry.area(0, span.x, 0, 0, 0, span.x + span.width, 0, HEADER_HEIGHT))
        gitgud.setProperty(state.name .. "C" .. i, "Area",
            geometry.area(0, span.x, 0, HEADER_HEIGHT, 0, span.x + span.width, 1, 0))
        if i < #spans then
            local divider = state.name .. "D" .. i
            local edge = span.x + span.width
            gitgud.setProperty(divider, "Area",
                geometry.area(0, edge - 3, 0, 0, 0, edge + DIVIDER - 3, 0, HEADER_HEIGHT))
        end
    end
end

--- Header captions, with the sort arrow on the sorted column.
-- @param state  grid state
local function paintHeaders(state)
    for i, column in ipairs(state.columns) do
        local caption = column.title
        if state.sortKey == column.key then
            caption = caption .. (state.sortDescending and "  ▼" or "  ▲")
        end
        gitgud.setText(state.name .. "H" .. i, text.colour(C.text2, caption))
    end
end

--- Refill every column from the view.
-- @param state  grid state
local function fill(state)
    for i, column in ipairs(state.columns) do
        local items = {}
        for r, row in ipairs(state.view) do
            items[r] = cellMarkup(state, row, column, i == 1, r)
        end
        gitgud.setList(state.name .. "C" .. i, items)
    end

    local empty = #state.view == 0
    gitgud.setVisible(state.name .. "Empty", empty and state.emptyText ~= nil)
    if empty and state.emptyText then
        gitgud.setText(state.name .. "Empty", text.colour(C.dim, state.emptyText))
    end
end

--- Selected view indices (1-based), read from the first column.
-- @param state  grid state
-- @return array
local function selectedIndices(state)
    local list = state.name .. "C1"
    if state.multi then
        return gitgud.getSelectedIndices(list)
    end
    local index = gitgud.getSelectedIndex(list)

    return index and { index } or {}
end

--- Make every column show the same selection.
-- @param state  grid state
-- @param rows   view indices (1-based)
local function mirror(state, rows)
    for i = 1, #state.columns do
        local list = state.name .. "C" .. i
        if state.multi then
            gitgud.selectListItems(list, rows)
        else
            gitgud.selectListItem(list, rows[1], false)
        end
    end
end

--- The row tables for view indices.
-- @param state    grid state
-- @param indices  view indices
-- @return array of rows
local function rowsAt(state, indices)
    local out = {}
    for _, index in ipairs(indices) do
        if state.view[index] then
            out[#out + 1] = state.view[index]
        end
    end

    return out
end

--- Persist the column widths.
-- @param state  grid state
local function saveWidths(state)
    local widths = {}
    for i, column in ipairs(state.columns) do
        widths[i] = tostring(column.width or 120)
    end
    settings.set(state.settingKey, table.concat(widths, ","))
end

--- Create a grid inside `parent` (filling it).
-- @param name    widget name prefix (unique)
-- @param parent  host widget
-- @param spec    see the header
function grid.create(name, parent, spec)
    local state = {
        name = name,
        columns = spec.columns,
        multi = spec.multi == true,
        rowHeight = spec.rowHeight or ROW_HEIGHT,
        onSelect = spec.onSelect,
        onActivate = spec.onActivate,
        onContext = spec.onContext,
        onDrag = spec.onDrag,
        emptyText = spec.emptyText,
        sortable = spec.sortable ~= false,
        sortKey = spec.sortKey,
        sortDescending = spec.sortDescending == true,
        rows = {},
        view = {},
        settingKey = spec.settingKey or ("grid." .. name),
    }
    grids[name] = state

    -- Remembered column widths.
    local saved = settings.get(state.settingKey, "")
    local i = 0
    for width in saved:gmatch("[^,]+") do
        i = i + 1
        if state.columns[i] and tonumber(width) then
            state.columns[i].width = math.max(MIN_WIDTH, tonumber(width))
        end
    end

    gitgud.createWindow("DefaultWindow", name, parent)
    gitgud.setProperty(name, "Area", geometry.area(0, 0, 0, 0, 1, 0, 1, 0))

    gitgud.createWindow("Gitgud/StaticText", name .. "HeaderBg", name)
    gitgud.setProperty(name .. "HeaderBg", "Area", geometry.area(0, 0, 0, 0, 1, 0, 0, HEADER_HEIGHT))
    gitgud.setProperty(name .. "HeaderBg", "PanelColour", C.header)
    gitgud.setText(name .. "HeaderBg", "")

    for c, column in ipairs(state.columns) do
        local header = name .. "H" .. c
        gitgud.createWindow("Gitgud/Button", header, name)
        gitgud.setProperty(header, "HorzFormatting", "LeftAligned")
        gitgud.setProperty(header, "NormalFillColour", C.header)
        gitgud.setProperty(header, "HoverFillColour", C.headerHover)
        gitgud.setProperty(header, "PushedFillColour", C.selection)
        gitgud.setProperty(header, "BorderColour", C.headerLine)
        if column.tooltip then
            gitgud.setProperty(header, "TooltipText", column.tooltip)
        end

        local list = name .. "C" .. c
        gitgud.createWindow("Gitgud/ListWidget", list, name)
        gitgud.setProperty(list, "BorderColour", C.panel)
        gitgud.setProperty(list, "HorzScrollbarDisplayMode", "Hidden")
        gitgud.setProperty(list, "VertScrollbarDisplayMode", c == #state.columns and "WhenNeeded" or "Hidden")
        if state.multi then
            gitgud.setProperty(list, "MultiSelect", "true")
        end
        if c > 1 then
            gitgud.linkScroll(name .. "C1", list)
        end

        local key = column.key
        gitgud.on(header .. ".clicked", function()
            if not state.sortable or column.sortable == false then
                return
            end
            if state.sortKey == key then
                state.sortDescending = not state.sortDescending
            else
                state.sortKey = key
                state.sortDescending = column.descending == true
            end
            local selection = rowsAt(state, selectedIndices(state))
            applySort(state)
            paintHeaders(state)
            fill(state)
            grid.selectRows(name, selection)
        end)

        gitgud.on(list .. ".selected", function()
            local indices
            if state.multi then
                indices = gitgud.getSelectedIndices(list)
            else
                local index = gitgud.getSelectedIndex(list)
                indices = index and { index } or {}
            end
            mirror(state, indices)
            if state.onSelect then
                state.onSelect(rowsAt(state, indices))
            end
        end)

        -- A click on an already-selected row raises no "selected": re-announce
        -- the selection so this table becomes the one commands act on.
        gitgud.on(list .. ".clicked", function()
            if state.onSelect then
                state.onSelect(rowsAt(state, selectedIndices(state)))
            end
        end)

        gitgud.on(list .. ".doubleClicked", function(value)
            local row = tonumber(value)
            if row and row >= 0 and state.onActivate and state.view[row + 1] then
                state.onActivate(state.view[row + 1])
            end
        end)

        gitgud.on(list .. ".rightClicked", function(value)
            local x, y, row = require("ui.menu").parseClick(value)
            local indices = selectedIndices(state)
            if row then
                local already = false
                for _, index in ipairs(indices) do
                    already = already or index == row
                end
                if not already then
                    indices = { row }
                    mirror(state, indices)
                    if state.onSelect then
                        state.onSelect(rowsAt(state, indices))
                    end
                end
            end
            if state.onContext then
                state.onContext(rowsAt(state, indices), x, y)
            end
        end)

        gitgud.on(list .. ".dragged", function(value)
            local from, to = value:match("^(%d+),(%d+)$")
            if from and state.onDrag then
                state.onDrag(state.view[tonumber(from) + 1], state.view[tonumber(to) + 1])
            end
        end)
    end

    -- Dividers (drag to resize the column on their left).
    for c = 1, #state.columns - 1 do
        local divider = name .. "D" .. c
        gitgud.createWindow("Gitgud/Button", divider, name)
        gitgud.setText(divider, "")
        gitgud.setProperty(divider, "NormalFillColour", C.transparent)
        gitgud.setProperty(divider, "HoverFillColour", C.selectionBorder)
        gitgud.setProperty(divider, "PushedFillColour", C.text2)
        gitgud.setProperty(divider, "BorderColour", C.transparent)
        gitgud.setDraggable(divider, true)
        local column = state.columns[c]
        gitgud.on(divider .. ".dragging", function(value)
            local x = tonumber(value:match("^(-?%d+)"))
            local left = gitgud.getRect(name)
            if not x or not left then
                return
            end
            local spans = columnSpans(state)
            column.width = math.max(MIN_WIDTH, x - left - spans[c].x)
            layout(state, true)
        end)
        gitgud.on(divider .. ".dragEnded", function()
            saveWidths(state)
        end)
    end

    gitgud.createWindow("Gitgud/Label", name .. "Empty", name)
    gitgud.setProperty(name .. "Empty", "Area", geometry.area(0, 12, 0, HEADER_HEIGHT + 8, 1, -12, 0, HEADER_HEIGHT + 32))
    gitgud.setProperty(name .. "Empty", "CursorPassThroughEnabled", "true")
    gitgud.setVisible(name .. "Empty", false)

    paintHeaders(state)
    layout(state)
    gitgud.on("window.resized", function()
        layout(state)
    end)
    -- The host may be resized by splitters: frame.lua publishes this.
    require("core.app").subscribe("layout.changed", function()
        layout(state)
    end)
end

--- Replace the rows (keeps the sort; tries to keep the selection).
-- @param name  grid name
-- @param rows  array of row tables (see the header)
-- @param keep  optional function(row) -> identity, to restore the selection
function grid.setRows(name, rows, keep)
    local state = grids[name]
    if not state then
        return
    end

    local previous = {}
    if keep then
        for _, row in ipairs(rowsAt(state, selectedIndices(state))) do
            previous[keep(row)] = true
        end
    end

    state.rows = rows
    applySort(state)
    fill(state)

    if keep then
        local indices = {}
        for i, row in ipairs(state.view) do
            if previous[keep(row)] then
                indices[#indices + 1] = i
            end
        end
        mirror(state, indices)
    end
end

--- The rows in display order.
-- @param name  grid name
-- @return array
function grid.rows(name)
    local state = grids[name]
    return state and state.view or {}
end

--- The selected rows.
-- @param name  grid name
-- @return array of row tables
function grid.selected(name)
    local state = grids[name]
    if not state then
        return {}
    end

    return rowsAt(state, selectedIndices(state))
end

--- Select these row tables (without raising onSelect).
-- @param name  grid name
-- @param rows  array of row tables (from grid.rows)
function grid.selectRows(name, rows)
    local state = grids[name]
    if not state then
        return
    end

    local wanted = {}
    for _, row in ipairs(rows) do
        wanted[row] = true
    end
    local indices = {}
    for i, row in ipairs(state.view) do
        if wanted[row] then
            indices[#indices + 1] = i
        end
    end
    mirror(state, indices)
end

--- Select the first row matching a predicate, scroll it into view, and
-- raise onSelect.
-- @param name  grid name
-- @param test  function(row) -> boolean
-- @return the row, or nil
function grid.selectWhere(name, test)
    local state = grids[name]
    if not state then
        return nil
    end

    for i, row in ipairs(state.view) do
        if test(row) then
            for c = 1, #state.columns do
                gitgud.selectListItem(state.name .. "C" .. c, i, c == #state.columns)
            end
            if state.onSelect then
                state.onSelect({ row })
            end
            return row
        end
    end

    return nil
end

--- Re-run the layout (after the host moved).
-- @param name  grid name
function grid.layout(name)
    if grids[name] then
        layout(grids[name], true)
    end
end

return grid
