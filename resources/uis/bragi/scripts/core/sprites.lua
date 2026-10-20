--- core/sprites.lua (Bragi UI): the pictures inside list rows, in the
-- theme's colours.
--
-- Shadows resources/scripts/core/sprites.lua, whose pictures have the
-- GitGud UI's colours baked in. These are white (imagesets/BragiIcons.xml,
-- Bragi-Shapes/Solid) and tinted inline, so they follow light and dark:
--
--   include boxes   a checkbox like Gitgud/Checkbox: a 14px outline when
--                   off, accent with a tick when on, an accent outline with
--                   a dash when partly included, centred in the size asked
--   branch tree     line icons in the secondary text colour, tags in the
--                   accent text colour
--
-- Every picture leaves the row's colour and padding as it found them.

local C = require("core.palette")

local sprites = {}

local BOX = 14
local SOLID = "Bragi-Shapes/Solid"
local DONE = "[padding='l:0 t:0 r:0 b:0'][reset='colour']"

local NAV_COLOURS = {
    NavTag = C.accentText,
}

--- One picture, drawn at an offset from the pen with a given advance.
-- @param image  full image name
-- @param w      width
-- @param h      height
-- @param pad    { l, t, r, b } padding (l may be negative to draw over the
--               picture before it)
-- @param colour AARRGGBB tint
local function piece(image, w, h, pad, colour)
    return "[colour='" .. colour .. "'][padding='l:" .. pad[1] .. " t:" .. pad[2] .. " r:" .. pad[3]
        .. " b:" .. pad[4] .. "'][image-size='w:" .. w .. " h:" .. h .. "'][image='" .. image .. "']"
end

--- An include box centred in a w x h cell.
-- @param state  "On" | "Off" | "Part"
local function box(state, w, h)
    local x = math.floor((w - BOX) / 2)
    local y = math.floor((h - BOX) / 2)
    local cell = { x, y, w - BOX - x, h - BOX - y }
    -- Pieces drawn over the box start back at its left edge and add nothing.
    local back = -(w - x)

    if state == "On" then
        return piece(SOLID, BOX, BOX, cell, C.accent)
            .. piece("Bragi-Icons/CheckMark", BOX, BOX, { back, y, w - BOX - x, h - BOX - y }, C.onAccent)
            .. DONE
    end
    if state == "Part" then
        local dashX = math.floor((BOX - 6) / 2)
        local dashY = math.floor((BOX - 2) / 2)
        return piece("Bragi-Icons/CheckRing", BOX, BOX, cell, C.accent)
            .. piece(SOLID, 6, 2, { back + dashX, y + dashY, w - x - dashX - 6, h - y - dashY - 2 }, C.accent)
            .. DONE
    end

    return piece("Bragi-Icons/CheckRing", BOX, BOX, cell, C.borderStrong) .. DONE
end

--- Inline markup for a picture at a size (see resources/scripts/core/sprites.lua).
-- @param name  HunkOn / HunkOff / HunkPart, BlockOn / BlockOff / BlockPart,
--              or a branch tree icon (NavBranch, NavRemote, ...)
-- @param w     width
-- @param h     height
-- @return markup
function sprites.image(name, w, h)
    local state = name:match("^Hunk(%a+)$") or name:match("^Block(%a+)$")
    if state then
        return box(state, w, h)
    end

    return piece("Bragi-Icons/" .. name, w, h, { 0, 0, 0, 0 }, NAV_COLOURS[name] or C.sub) .. DONE
end

--- An include box for a row: "all", "some" or "none" included.
-- @param inclusion  "all" | "some" | "none"
-- @param w          cell width
-- @param h          cell height
function sprites.includeBox(inclusion, w, h)
    local state = inclusion == "all" and "On" or (inclusion == "some" and "Part" or "Off")
    return box(state, w, h)
end

return sprites
