--- core/palette.lua — the colour tokens every view shares.
--
-- Hex values are CEGUI's AARRGGBB. They mirror the Synthwave design tokens
-- (tokens/colors.css in the design kit) and the defaults baked into the
-- looknfeel, so restyling from Lua stays consistent with the skin.
--
-- Mods can reuse these instead of hard-coding colours:
--     local C = require("core.palette")
--     gitgud.setProperty("MyLabel", "NormalTextColour", C.cyan)

local C = {
    -- Surfaces, darkest to lightest.
    bg0 = "FF0E0A1A",        -- window frame, title bar, status bar
    bg1 = "FF17102B",        -- canvas: toolbar, diff background
    bg2 = "FF1F1738",        -- panels: sidebar, popups, dialogs
    bg3 = "FF291F47",        -- hover, selected row
    bg4 = "FF342A56",        -- pressed

    -- Text.
    text = "FFF3EEFC",       -- primary
    text2 = "FFB7AED6",      -- secondary
    dim = "FF766A9C",        -- tertiary / hints
    disabled = "FF4D4470",

    -- Neon accents.
    cyan = "FF7EF2D6",
    blue = "FF7C93FF",
    purple = "FFB06BFF",
    pink = "FFFF7EDB",
    yellow = "FFFFCF6E",

    -- Semantic.
    add = "FF5EF2A6",        -- diff additions, "added" status
    del = "FFFF5EC4",        -- diff deletions, "deleted" status
    warn = "FFFFCF6E",       -- modified status, warnings
    err = "FFFF5457",        -- conflicts, errors
    ok = "FF5EF2A6",

    -- Hairlines.
    hairline = "1FC4B5FD",
    border = "2EC4B5FD",
    borderStrong = "52C4B5FD",

    transparent = "00000000",

    -- Commit graph lanes, in the order lanes are handed out (cycled).
    lanes = {
        "FF7EF2D6", -- cyan
        "FFFF7EDB", -- pink
        "FF7C93FF", -- blue
        "FFFFCF6E", -- yellow
        "FFB06BFF", -- purple
        "FF5EF2A6", -- green
        "FFFF9E6E", -- orange
        "FF6EDBFF", -- sky
    },
}

return C
