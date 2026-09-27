--- ui/geometry.lua — building CEGUI "Area" strings without counting braces.
--
-- A CEGUI area is four unified coordinates {{scale,offset} x4}: left, top,
-- right, bottom, each relative to the parent (scale 0..1) plus pixels.
--
--     geometry.area(0, 10, 0, 40, 1, -10, 0, 72)
--         --> "{{0,10},{0,40},{1,-10},{0,72}}"
--     geometry.rect(20, 30, 200, 100)  -- absolute x, y, width, height
--         --> "{{0,20},{0,30},{0,220},{0,130}}"

local geometry = {}

--- Format one number compactly (integers without a trailing ".0").
-- @param n  a number
-- @return its string form
local function num(n)
    if n == math.floor(n) then
        return string.format("%d", n)
    end

    return string.format("%.4f", n)
end

--- An Area from eight scale/offset numbers.
-- @param ls  left scale    @param lo  left offset
-- @param ts  top scale     @param to  top offset
-- @param rs  right scale   @param ro  right offset
-- @param bs  bottom scale  @param bo  bottom offset
-- @return an Area property string
function geometry.area(ls, lo, ts, to, rs, ro, bs, bo)
    return "{{" .. num(ls) .. "," .. num(lo) .. "},{" .. num(ts) .. "," .. num(to)
        .. "},{" .. num(rs) .. "," .. num(ro) .. "},{" .. num(bs) .. "," .. num(bo) .. "}}"
end

--- An absolute pixel rectangle (relative to the parent's top-left corner).
-- @param x       left
-- @param y       top
-- @param width   width
-- @param height  height
-- @return an Area property string
function geometry.rect(x, y, width, height)
    return geometry.area(0, x, 0, y, 0, x + width, 0, y + height)
end

--- A full-width horizontal band at a fixed height.
-- @param top     top offset in pixels
-- @param height  band height
-- @param inset   optional left/right inset (default 0)
-- @return an Area property string
function geometry.band(top, height, inset)
    local side = inset or 0

    return geometry.area(0, side, 0, top, 1, -side, 0, top + height)
end

--- Fit a width x height picture inside a box, keeping its aspect ratio and
-- never scaling up past 100%.
-- @param width      picture width
-- @param height     picture height
-- @param boxWidth   available width
-- @param boxHeight  available height
-- @return x, y, w, h of the centred picture inside the box
function geometry.fit(width, height, boxWidth, boxHeight)
    if width <= 0 or height <= 0 or boxWidth <= 0 or boxHeight <= 0 then
        return 0, 0, 0, 0
    end

    local scale = math.min(boxWidth / width, boxHeight / height, 1)
    local w = math.floor(width * scale)
    local h = math.floor(height * scale)
    local x = math.floor((boxWidth - w) / 2)
    local y = math.floor((boxHeight - h) / 2)

    return x, y, w, h
end

return geometry
