--- core/palette.lua (P4V UI) — the Dagobah palette under the same token
-- names as the default palette.
--
--   ECF1C1 cream   A0A485 sage   525445 olive   34796A teal   276460 deep teal
--   25484F slate teal   28333C swamp   1F2731 night   010102 black
--   (loading.io "StarWars - Dagobah")
--
-- This file shadows resources/scripts/core/palette.lua for the P4V UI (a UI
-- package's scripts are searched first), so the shared toolkit — menus,
-- dialogs, the command palette — draws in these colours too. The palette
-- has no red: deletions and errors use a muted brick derived to sit with it.

local C = {
    -- Surfaces, window chrome to content.
    bg0 = "FF28333C",        -- window face: menu bar, toolbar, status bar
    bg1 = "FF1F2731",        -- content: lists, trees, editors
    bg2 = "FF28333C",        -- popups and menus
    bg3 = "FF276460",        -- hover, selected row
    bg4 = "FF34796A",        -- pressed

    -- Text.
    text = "FFECF1C1",
    text2 = "FFA0A485",
    dim = "FF8C9075",
    disabled = "FF525445",

    -- Accents.
    cyan = "FF34796A",
    blue = "FF34796A",
    purple = "FF7FA89A",
    pink = "FFC9A27A",
    yellow = "FFD8C27A",

    -- Semantic.
    add = "FF7FC9A0",
    del = "FFD9826F",
    warn = "FFD8C27A",
    err = "FFD9826F",
    ok = "FF7FC9A0",

    -- Hairlines.
    hairline = "FF25484F",
    border = "FF525445",
    borderStrong = "FFA0A485",

    transparent = "00000000",

    -- Graph lanes (the commit graph, when shown).
    lanes = {
        "FF34796A",
        "FFECF1C1",
        "FFA0A485",
        "FF7FC9A0",
        "FFD8C27A",
        "FF5FA3B0",
        "FFC9A27A",
        "FF8C9075",
    },

    -- P4V-layout specifics.
    face = "FF28333C",       -- chrome
    panel = "FF1F2731",      -- content background
    deep = "FF010102",       -- deepest edges, editbox wells
    selection = "FF276460",
    selectionBorder = "FF34796A",
    tabActive = "FF1F2731",
    tabInactive = "FF28333C",
    tabHover = "FF25484F",
    header = "FF25484F",     -- table column headers
    headerHover = "FF276460",
    headerLine = "FF1F2731",
    diffAdd = "FF1F4A3F",    -- diff line tints over the night background
    diffDel = "FF4A2F2C",
    diffChange = "FF25484F",
    diffAddWord = "FF2F7A5E",
    diffDelWord = "FF7A3F36",
    diffGap = "FF232C35",
    link = "FF7FC9A0",

    -- The revision graph (0xRRGGBB for gitgud.revisionGraph).
    graph = {
        background = "1F2731",
        bandA = "1F2731",
        bandB = "232C35",
        bandSelected = "25484F",
        rowLine = "28333C",
        node = "A0A485",
        nodeHead = "34796A",
        nodeBorder = "ECF1C1",
        deleted = "525445",
        bar = "276460",
        edge = "ECF1C1",
        branchEdge = "A0A485",
        selectedFill = "ECF1C1",
        selectedBorder = "D8C27A",
    },
}

return C
