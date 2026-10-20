--- ui/splitter.lua: draggable seams between panes.
--
-- A splitter is a thin button over the seam between two panes: it lights
-- up under the cursor, shows a resize cursor, and reports the cursor while
-- it is dragged. views/frame.lua's seams (the branch tree, the sidebar, the
-- graph, the console) and the side columns of other interfaces use it.
--
--     splitter.create(name, parent, direction, onDrag, onEnd)
--         "horizontal" drags left and right (a column's width), "vertical"
--         up and down. onDrag(x, y) gets the cursor in window pixels while
--         it's dragged; onEnd() runs when it's let go.
--
--     local col = splitter.column({ name = "ListSplit", parent = "Root",
--         pane = "List", edge = "left", key = "listWidth", default = 260,
--         min = 180, max = function() return 480 end, relayout = fn,
--         done = fn })
--         A column whose width the seam sets and the settings remember.
--         `pane` is the column's widget; `edge` says which side of the
--         parent it sits on ("left": the seam is its right edge; "right":
--         its left edge). While dragging, relayout() runs on every move
--         and done() whenever the drag pauses (for redrawing what depends
--         on the width); when it's let go, the width is saved (clamped),
--         then relayout() and done() run.
--         col.width()           the width to lay out, clamped to min..max
--         col.place(x, top, bottom)  put the seam x px in from the
--                               column's side of the parent (its width,
--                               for a column at that side), from top px
--                               to bottom px above the foot
--         col.hide()            no seam (the column isn't showing)
--         col.dragging()        a drag is under way
--
-- Public API: splitter.create, splitter.column, splitter.WIDTH

local C = require("core.palette")
local geometry = require("ui.geometry")
local settings = require("core.settings")

local splitter = {}

splitter.WIDTH = 4  -- the grab width, centred on the seam
local PAUSE_MS = 120  -- a drag this still has paused (done() runs)

--- Make the seam's button and wire its drag.
-- @param name       widget name
-- @param parent     the panes' parent
-- @param direction  "horizontal" | "vertical"
-- @param onDrag     fn(x, y), window pixels
-- @param onEnd      fn()
function splitter.create(name, parent, direction, onDrag, onEnd)
    gitgud.createWindow("Gitgud/Button", name, parent)
    gitgud.setText(name, "")
    gitgud.setProperty(name, "NormalFillColour", C.transparent)
    gitgud.setProperty(name, "HoverFillColour", C.borderStrong)
    gitgud.setProperty(name, "PushedFillColour", C.blue)
    gitgud.setProperty(name, "BorderColour", C.transparent)
    gitgud.setDraggable(name, true, direction)

    gitgud.on(name .. ".dragging", function(value)
        local x, y = tostring(value):match("^(-?%d+),(-?%d+)$")
        x, y = tonumber(x), tonumber(y)
        if x then
            onDrag(x, y)
        end
    end)
    gitgud.on(name .. ".dragEnded", function()
        onEnd()
    end)
end

--- A side column sized by dragging its seam (see the header).
-- @param spec  { name, parent, pane, edge, key, default, min, max, relayout, done }
-- @return the column: width(), place(x, top, bottom), hide(), dragging()
function splitter.column(spec)
    local col = {}
    local live = nil  -- the width while dragging
    local moves = 0   -- drag moves so far (a pause is none for PAUSE_MS)

    local function maxWidth()
        local m = spec.max
        if type(m) == "function" then
            m = m()
        end
        return m or math.huge
    end

    local function clamp(w)
        return math.floor(math.max(spec.min or 0, math.min(w, maxWidth())))
    end

    function col.width()
        local w = live
        if w == nil then
            w = tonumber(settings.get(spec.key, spec.default)) or spec.default
        end
        return clamp(w)
    end

    function col.dragging()
        return live ~= nil
    end

    function col.place(x, top, bottom)
        local half = splitter.WIDTH / 2
        local scale, offset = 0, x
        if spec.edge == "right" then
            scale, offset = 1, -x
        end
        gitgud.setProperty(spec.name, "Area",
            geometry.area(scale, offset - half, 0, top or 0, scale, offset + half, 1, -(bottom or 0)))
        gitgud.setVisible(spec.name, true)
        gitgud.bringToFront(spec.name)
    end

    function col.hide()
        gitgud.setVisible(spec.name, false)
    end

    splitter.create(spec.name, spec.parent, "horizontal", function(x)
        local px, _, pw = gitgud.getRect(spec.pane)
        if not px then
            return
        end
        -- The column's far edge stays put; the seam follows the cursor.
        if spec.edge == "right" then
            live = px + pw - x
        else
            live = x - px
        end
        spec.relayout()
        moves = moves + 1
        local at = moves
        gitgud.after(PAUSE_MS, function()
            if live ~= nil and moves == at and spec.done then
                spec.done()
            end
        end)
    end, function()
        if live == nil then
            return
        end
        local w = clamp(live)
        live = nil
        settings.set(spec.key, w)
        spec.relayout()
        if spec.done then
            spec.done()
        end
    end)

    return col
end

return splitter
