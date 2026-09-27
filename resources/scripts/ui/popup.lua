--- ui/popup.lua — one popup at a time, closed by clicking away or Escape.
--
-- A "popup" is any hidden panel shown over the UI: the repository and
-- branch dropdowns, menus, context menus. While one is open an invisible
-- full-window button (PopupBlocker, layouts/popups/blocker.xml) sits right
-- under it, so a click anywhere else closes the popup instead of reaching
-- the widget underneath.
--
--     popup.open("BranchPopup", { anchor = "BranchButton",
--                                 focus = "BranchFilterEdit",
--                                 onClose = function() ... end })

local geometry = require("ui.geometry")
local keys = require("core.keys")

local popup = {}

local current = nil

--- Close the open popup, if any.
function popup.close()
    if not current then
        return
    end

    local closing = current
    current = nil

    gitgud.setVisible(closing.name, false)
    gitgud.setVisible("PopupBlocker", false)
    keys.popEscape(closing.escape)

    if closing.onClose then
        closing.onClose()
    end
end

--- The name of the open popup, or nil.
-- @return widget name or nil
function popup.current()
    return current and current.name or nil
end

--- True when `name` is the open popup.
-- @param name  widget name
-- @return boolean
function popup.isOpen(name)
    return current ~= nil and current.name == name
end

--- Move a popup so its top-left corner sits at an absolute position,
-- keeping it inside the window.
-- @param name  popup widget
-- @param x     desired left edge (pixels)
-- @param y     desired top edge (pixels)
function popup.placeAt(name, x, y)
    local _, _, width, height = gitgud.getRect(name)
    local _, _, rootWidth, rootHeight = gitgud.getRect("Root")

    if not width or not rootWidth then
        return
    end

    local left = math.max(0, math.min(x, rootWidth - width - 4))
    local top = math.max(0, math.min(y, rootHeight - height - 4))
    gitgud.setProperty(name, "Area", geometry.rect(left, top, width, height))
end

--- Open a popup (closing any other first).
-- @param name  the popup widget
-- @param opts  optional table:
--              anchor   widget to drop down from (placed under its left edge)
--              x, y     absolute position instead of an anchor
--              focus    widget to give keyboard focus
--              onClose  function() called when it closes
function popup.open(name, opts)
    opts = opts or {}
    popup.close()

    if opts.anchor then
        local ax, ay, _, ah = gitgud.getRect(opts.anchor)
        if ax then
            popup.placeAt(name, ax, ay + ah)
        end
    elseif opts.x then
        popup.placeAt(name, opts.x, opts.y)
    end

    gitgud.setVisible("PopupBlocker", true)
    gitgud.bringToFront("PopupBlocker")
    gitgud.setVisible(name, true)
    gitgud.bringToFront(name)

    current = {
        name = name,
        onClose = opts.onClose,
    }
    current.escape = keys.pushEscape(popup.close)

    if opts.focus then
        gitgud.focus(opts.focus)
    end
end

--- Toggle: open the popup, or close it if it's the one already open.
-- @param name  popup widget
-- @param opts  as for popup.open
function popup.toggle(name, opts)
    if popup.isOpen(name) then
        popup.close()
    else
        popup.open(name, opts)
    end
end

--- Wire the click-away blocker. Called once by main.lua.
function popup.init()
    gitgud.on("PopupBlocker.clicked", function()
        popup.close()
    end)

    gitgud.on("PopupBlocker.rightClicked", function()
        popup.close()
    end)
end

return popup
