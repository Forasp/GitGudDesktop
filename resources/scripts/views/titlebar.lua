--- views/titlebar.lua — the custom window chrome's buttons.
--
-- The window is borderless; layouts/main/titlebar.xml is the caption. These
-- buttons emit window.* events that C++ maps onto the real SDL window, and
-- "window.state" comes back when the maximize state changes (button, Aero
-- snap, or double-clicking the caption). The menus themselves are defined in
-- views/menus.lua.

local titlebar = { name = "titlebar" }

--- Wire the minimize / maximize / close buttons.
function titlebar.init()
    gitgud.on("WindowMinButton.clicked", function()
        gitgud.emit("window.minimize", "")
    end)

    gitgud.on("WindowMaxButton.clicked", function()
        gitgud.emit("window.toggleMaximize", "")
    end)

    gitgud.on("WindowCloseButton.clicked", function()
        gitgud.emit("window.close", "")
    end)

    gitgud.on("window.state", function(state)
        local maximized = state == "maximized"
        gitgud.setProperty("WindowMaxButton", "TooltipText", maximized and "Restore" or "Maximize")
        gitgud.setText("WindowMaxButton", maximized and "❐" or "□")
    end)
end

return titlebar
