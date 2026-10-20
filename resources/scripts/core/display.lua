--- core/display.lua: renew the main window after the displays change.
--
-- C++ tells of changes to the displays ("display.changed": a display
-- connected, disconnected or moved, Windows' display settings changing, the
-- computer waking). After one, an OpenGL window can go on drawing while
-- nothing it draws reaches the screen (the dock's monitor
-- came back and the window kept its last frame, though input, layout and
-- drawing all went on). So once the changes have settled, the main window
-- is renewed: a new one in its place, the UI as it was
-- (emit("window.renew", why), main.cpp's renewWindow). Ctrl+Alt+Shift+R does
-- the same by hand (handled in C++).
--
-- Every interface's main.lua requires this module.

local display = {}

display.SETTLE_MS = 1500 -- changes this close together are one

local changes = {} -- what changed since the last renewal, in order, once each
local timer = nil

local function renew()
    timer = nil
    local why = table.concat(changes, ", ")
    changes = {}
    gitgud.emit("window.renew", why)
end

gitgud.on("display.changed", function(what)
    what = tostring(what or "")
    local seen = false
    for _, c in ipairs(changes) do
        seen = seen or c == what
    end
    if not seen then
        changes[#changes + 1] = what
    end
    if timer then
        gitgud.cancelTimer(timer)
    end
    timer = gitgud.after(display.SETTLE_MS, renew)
end)

--- The changes waiting for the renewal, oldest first (for tests).
function display.pending()
    return { table.unpack(changes) }
end

return display
