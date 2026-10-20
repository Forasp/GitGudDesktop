--- core/palette.lua (Bragi UI): the running theme's colours, under the
-- default palette's names and the design's own.
--
-- Every value comes from the theme in use (themes/<name>.ini, read through
-- gitgud.themeColour), so the GitGud UI's views and Bragi's scripts follow
-- the light / dark switch. The UI rebuilds when the theme changes, so
-- reading the colours once, here, is enough.
--
-- This file shadows resources/scripts/core/palette.lua for the Bragi UI.

--- A theme token's colour; the dark theme's value when the theme lacks it.
-- @param name      token name ("accent")
-- @param fallback  AARRGGBB
local function token(name, fallback)
    return gitgud.themeColour(name) or fallback
end

local T = {
    bg = token("bg", "FF1B2A27"),
    rail = token("rail", "FF14211F"),
    panel = token("panel", "FF213330"),
    well = token("well", "FF14211F"),
    border = token("border", "FF35504A"),
    borderStrong = token("border-strong", "FF4A6A62"),
    text = token("text", "FFECE7D8"),
    sub = token("sub", "FFB9C2B0"),
    disabled = token("disabled", "FF5E716B"),
    accent = token("accent", "FFE8B866"),
    accentHover = token("accent-hover", "FFF0CB86"),
    accentPressed = token("accent-pressed", "FFD9A64F"),
    onAccent = token("on-accent", "FF2A1E05"),
    accentText = token("accent-text", "FFE8B866"),
    link = token("link", "FFE8B866"),
    add = token("add", "FFA9BA78"),
    warn = token("warn", "FFE09A6A"),
    err = token("err", "FFEB8A5C"),
    sel = token("sel", "FF2A3F3B"),
    hover = token("hover", "FF233733"),
    petal = token("petal", "FFE8B866"),
    logoCentre = token("logo-centre", "FF6B4A16"),
    addBg = token("add-bg", "29A9BA78"),
    delBg = token("del-bg", "29E09A6A"),
    codeBg = token("code-bg", "FF14211F"),
    codeText = token("code-text", "FFECE7D8"),
    codeLink = token("code-link", "FFE8B866"),
    shade = token("shade", "A6081210"),
    textSelect = token("text-select", "59E8B866"),
    planDone = token("plan-done", "FFA9BA78"),
    planActive = token("plan-active", "FFE8B866"),
    planPending = token("plan-pending", "FF6E857E"),
}

local C = {
    -- The default palette's names (the GitGud UI's views use these).
    bg0 = T.rail,            -- window frame, status bar
    bg1 = T.bg,              -- canvas: toolbar, lists, diff background
    bg2 = T.panel,           -- panels, popups, dialogs
    bg3 = T.sel,             -- hover, selected row
    bg4 = T.border,          -- pressed

    text = T.text,
    text2 = T.sub,
    dim = T.sub,
    disabled = T.disabled,

    cyan = T.accent,
    blue = T.accent,
    purple = T.link,
    pink = T.warn,
    yellow = T.accentText,

    add = T.add,
    del = T.warn,
    warn = T.accentText,     -- "modified", warnings (the design's warn is `caution`)
    err = T.err,
    ok = T.add,

    hairline = T.border,
    border = T.border,
    borderStrong = T.borderStrong,

    transparent = "00000000",
    icon = T.text,
    bright = T.text,
    hunkHeader = T.sub,      -- "@@ -6,3 +6,4 @@" in diffs (views/diff.lua)

    -- Commit graph lanes, in the order lanes are handed out (cycled).
    lanes = { T.accent, T.link, T.add, T.warn, T.sub, T.accentText, T.borderStrong, T.text },
}

-- The design's tokens by name, for Bragi's own views.
for name, value in pairs(T) do
    if C[name] == nil then
        C[name] = value
    end
end
C.caution = T.warn
C.rail = T.rail
C.panel = T.panel
C.well = T.well
C.sel = T.sel

return C
