--- views/titlebar.lua — the custom window chrome's buttons.
--
-- The window is borderless; layouts/main/titlebar.xml is the caption. These
-- buttons emit window.* events that C++ maps onto the real SDL window, and
-- "window.state" comes back when the maximize state changes (button, Aero
-- snap, or double-clicking the caption). On macOS maximize is zoom, and the
-- buttons move to the left. The menus themselves are defined in
-- views/menus.lua.

local titlebar = { name = "titlebar" }

local MAC = gitgud.platform == "macos"

-- macOS: the window buttons sit on the left in the Mac's order and colours
-- (close, minimize, zoom), and the mark and menus move right to make room.
local MAC_BUTTONS = {
    { "WindowCloseButton", "FFFF5F57", "FFFF8A84" },
    { "WindowMinButton", "FFFEBC2E", "FFFFD06B" },
    { "WindowMaxButton", "FF28C840", "FF5FD970" },
}

local function macLayout()
    for i, button in ipairs(MAC_BUTTONS) do
        local name, colour, hover = button[1], button[2], button[3]
        local left = 8 + (i - 1) * 20
        gitgud.setProperty(name, "Area", string.format("{{0,%d},{0,6},{0,%d},{0,26}}", left, left + 20))
        gitgud.setText(name, "●")
        gitgud.setProperty(name, "Font", "Gitgud-UI-Title")
        for _, fill in ipairs({ "NormalFillColour", "HoverFillColour", "PushedFillColour" }) do
            gitgud.setProperty(name, fill, "00000000")
        end
        gitgud.setProperty(name, "NormalTextColour", colour)
        gitgud.setProperty(name, "HoverTextColour", hover)
        gitgud.setProperty(name, "PushedTextColour", colour)
    end
    gitgud.setProperty("WindowMaxButton", "TooltipText", "Zoom")
    gitgud.setProperty("AppTitleMark", "Area", "{{0,76},{0,7},{0,94},{0,25}}")
    gitgud.setProperty("MenuBar", "Area", "{{0,100},{0,0},{0,666},{1,-1}}")
end

--- Wire the minimize / maximize / close buttons.
function titlebar.init()
    if MAC then
        macLayout()
    end

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
        if MAC then
            return -- the zoom button looks the same either way
        end
        local maximized = state == "maximized"
        gitgud.setProperty("WindowMaxButton", "TooltipText", maximized and "Restore" or "Maximize")
        gitgud.setText("WindowMaxButton", maximized and "❐" or "□")
    end)
end

return titlebar
