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

-- On macOS C++ reports the Command key as "ctrl" (so every binding works
-- unchanged), and labels use the Mac's symbols in its order: Option, Shift,
-- Command ("ctrl+shift+p" reads as "⇧⌘P").
local MAC = gitgud.platform == "macos"
local MAC_MODIFIERS = { { "alt", "⌥" }, { "shift", "⇧" }, { "ctrl", "⌘" } }
local MAC_KEYS = {
    enter = "↩", tab = "⇥", backspace = "⌫", escape = "⎋",
    up = "↑", down = "↓", left = "←", right = "→",
}

--- The human-readable label for a combo, for menus ("Ctrl+Shift+P", or
-- "⇧⌘P" on macOS).
-- @param combo  combo string
-- @return display label
function keys.label(combo)
    local parts = {}
    local held = {}

    for part in combo:gmatch("[^+]+") do
        if MAC and (part == "ctrl" or part == "alt" or part == "shift") then
            held[part] = true
        elseif #part == 1 then
            parts[#parts + 1] = part:upper()
        elseif MAC and MAC_KEYS[part] then
            parts[#parts + 1] = MAC_KEYS[part]
        else
            parts[#parts + 1] = part:sub(1, 1):upper() .. part:sub(2)
        end
    end

    if MAC then
        local symbols = {}
        for _, modifier in ipairs(MAC_MODIFIERS) do
            if held[modifier[1]] then
                symbols[#symbols + 1] = modifier[2]
            end
        end
        return table.concat(symbols) .. table.concat(parts, "+")
    end

    return table.concat(parts, "+")
end

--- Rewrite the shortcuts written out in a piece of text ("Undo  (Ctrl+Z)")
-- for this platform: unchanged on Windows and Linux, Mac symbols on macOS.
-- @param s  text with shortcuts like "Ctrl+Shift+N" or "Ctrl+,"
-- @return the text to show
function keys.text(s)
    if not MAC then
        return s
    end
    return (s:gsub("%f[%w]Ctrl%+[%w%+,%-=`]*[%w,%-=`]", function(shortcut)
        return keys.label(shortcut:lower())
    end):gsub("%f[%w]Alt%+[%w%+,%-=`]*[%w,%-=`]", function(shortcut)
        return keys.label(shortcut:lower())
    end))
end

--- keys.text for the TooltipText of each named widget (tooltips written in
-- layout XML).
-- @param names  widget names
function keys.adaptTooltips(names)
    if not MAC then
        return
    end
    for _, name in ipairs(names) do
        local tooltip = gitgud.getProperty(name, "TooltipText")
        if tooltip and tooltip ~= "" then
            gitgud.setProperty(name, "TooltipText", keys.text(tooltip))
        end
    end
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
