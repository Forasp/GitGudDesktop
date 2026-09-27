--- core/keys.lua — keyboard shortcuts.
--
-- C++ publishes a "key" event for every combo that involves Ctrl or Alt,
-- plus function keys and Escape (plain typing stays with the focused
-- editbox). The detail is a lower-case combo string such as "ctrl+shift+p",
-- "f5", "escape", or "ctrl+enter".
--
--     keys.bind("ctrl+shift+n", function() branches.create() end, "New branch")
--
-- Escape first closes whatever popup or dialog is on top (see
-- keys.pushEscape); only when nothing is open does a bound handler run.

local keys = {}

local bindings = {}
local escapeStack = {}

--- Bind a combo to a function. Re-binding a combo replaces the old handler.
-- @param combo        e.g. "ctrl+shift+p" (modifier order: ctrl, alt, shift)
-- @param handler      function() called when the combo is pressed
-- @param description  optional text for menus/tooltips
function keys.bind(combo, handler, description)
    bindings[combo] = { handler = handler, description = description }
end

--- The human-readable label for a combo, for menus ("Ctrl+Shift+P").
-- @param combo  combo string
-- @return display label
function keys.label(combo)
    local parts = {}

    for part in combo:gmatch("[^+]+") do
        if #part == 1 then
            parts[#parts + 1] = part:upper()
        else
            parts[#parts + 1] = part:sub(1, 1):upper() .. part:sub(2)
        end
    end

    return table.concat(parts, "+")
end

--- Register something Escape should close (a popup or dialog). The most
-- recently pushed closer runs first.
-- @param closer  function() that closes it
-- @return a token for keys.popEscape
function keys.pushEscape(closer)
    escapeStack[#escapeStack + 1] = closer

    return closer
end

--- Remove a closer registered with pushEscape (call when it closes itself).
-- @param token  the value pushEscape returned
function keys.popEscape(token)
    for i = #escapeStack, 1, -1 do
        if escapeStack[i] == token then
            table.remove(escapeStack, i)
            return
        end
    end
end

--- Handle one "key" event from C++.
-- @param combo  the combo string
local function onKey(combo)
    if combo == "escape" and #escapeStack > 0 then
        local closer = table.remove(escapeStack)
        closer()
        return
    end

    local binding = bindings[combo]
    if binding then
        binding.handler()
    end
end

--- Start listening for key events. Called once by main.lua.
function keys.init()
    gitgud.on("key", onKey)
end

return keys
