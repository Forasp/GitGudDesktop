--- bragi/ui.lua: builders for the design's pieces, for views that create
-- their widgets at run time (Settings sections, Boards, Wiki).
--
-- Every builder takes the new widget's name, its parent, and an area: a
-- CEGUI area string, or {x, y, w, h} in pixels. Colours are theme colours
-- (core/palette.lua); rounded pieces use the Bragi/Box<r> and
-- Bragi/Button<r> types (imagesets/make-shapes.ps1).
--
--     ui.card("ThemeCard", "SettingsContent", { 40, 28, 680, 120 })
--     ui.label("ThemeTitle", "ThemeCard", { 20, 14, 300, 20 }, "Theme", { font = "Bragi-14-Bold" })
--     local edit = ui.input("WakeWord", "ThemeCard", { 300, 50, 360, 40 }, "Bragi")

local C = require("core.palette")
local geometry = require("ui.geometry")
local text = require("core.text")

local ui = {}

--- An area string from a string or a {x, y, w, h} pixel table.
local function area(a)
    if type(a) == "table" then
        return geometry.rect(a[1], a[2], a[3], a[4])
    end
    return a
end

local function create(kind, name, parent, a)
    if not gitgud.createWindow(kind, name, parent) then
        error("could not create " .. name)
    end
    gitgud.setProperty(name, "Area", area(a))
    return name
end

--- A rounded box.
-- @param opts  { radius = 12, fill = C.panel, border = C.border }
function ui.box(name, parent, a, opts)
    opts = opts or {}
    create("Bragi/Box" .. (opts.radius or 12), name, parent, a)
    gitgud.setProperty(name, "FillColour", opts.fill or C.panel)
    gitgud.setProperty(name, "BorderColour", opts.border or C.border)
    return name
end

--- A card: a panel-coloured box with a border, radius 12.
function ui.card(name, parent, a)
    return ui.box(name, parent, a, { radius = 12 })
end

--- A line of text (plain; markup when opts.markup is true).
-- @param opts  { font = "Bragi-14", colour = C.text, align = "LeftAligned", markup = false }
function ui.label(name, parent, a, s, opts)
    opts = opts or {}
    create("Gitgud/Label", name, parent, a)
    gitgud.setProperty(name, "Font", opts.font or "Bragi-14")
    gitgud.setProperty(name, "NormalTextColour", opts.colour or C.text)
    gitgud.setProperty(name, "HorzFormatting", opts.align or "LeftAligned")
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    gitgud.setText(name, opts.markup and s or text.escape(s or ""))
    return name
end

--- Wrapped text that grows downwards (a paragraph).
-- @param opts  { font, colour }
function ui.paragraph(name, parent, a, s, opts)
    opts = opts or {}
    create("Gitgud/StaticText", name, parent, a)
    gitgud.setProperty(name, "PanelColour", C.transparent)
    gitgud.setProperty(name, "HorzFormatting", "WordWrapLeftAligned")
    gitgud.setProperty(name, "VertFormatting", "TopAligned")
    gitgud.setProperty(name, "Font", opts.font or "Bragi-14")
    gitgud.setProperty(name, "TextColours", opts.colour or C.text)
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    gitgud.setText(name, text.escape(s or ""))
    return name
end

--- A button.
-- @param opts  { primary = false, quiet = false, radius = 8, font = "Bragi-13-Bold",
--                align = "CentreAligned", colour, tooltip }
--   primary: accent fill (one per area); quiet: no fill or border.
function ui.button(name, parent, a, label, opts)
    opts = opts or {}
    create("Bragi/Button" .. (opts.radius or 8), name, parent, a)
    gitgud.setProperty(name, "Font", opts.font or "Bragi-13-Bold")
    gitgud.setProperty(name, "HorzFormatting", opts.align or "CentreAligned")
    if opts.primary then
        gitgud.setProperty(name, "NormalFillColour", C.accent)
        gitgud.setProperty(name, "HoverFillColour", C.accentHover)
        gitgud.setProperty(name, "PushedFillColour", C.accentPressed)
        gitgud.setProperty(name, "BorderColour", C.transparent)
        for _, state in ipairs({ "Normal", "Hover", "Pushed" }) do
            gitgud.setProperty(name, state .. "TextColour", C.onAccent)
        end
    elseif opts.quiet then
        gitgud.setProperty(name, "NormalFillColour", C.transparent)
        gitgud.setProperty(name, "DisabledFillColour", C.transparent)
        gitgud.setProperty(name, "BorderColour", C.transparent)
    else
        gitgud.setProperty(name, "NormalFillColour", C.transparent)
        gitgud.setProperty(name, "DisabledFillColour", C.transparent)
        gitgud.setProperty(name, "BorderColour", C.border)
    end
    if opts.colour then
        gitgud.setProperty(name, "NormalTextColour", opts.colour)
        gitgud.setProperty(name, "HoverTextColour", opts.colour)
    end
    if opts.tooltip then
        gitgud.setProperty(name, "TooltipText", opts.tooltip)
    end
    gitgud.setText(name, text.escape(label or ""))
    return name
end

--- A single-line input: a well-coloured rounded box holding an editbox.
-- @return the editbox's name (name .. "Edit"), whose events are
--         "<edit>.changed" and "<edit>.accepted"
function ui.input(name, parent, a, value, opts)
    opts = opts or {}
    ui.box(name, parent, a, { radius = 8, fill = C.well, border = C.border })
    local edit = name .. "Edit"
    create("Gitgud/Editbox", edit, name, "{{0,10},{0,2},{1,-10},{1,-2}}")
    gitgud.setProperty(edit, "BgColour", C.transparent)
    gitgud.setProperty(edit, "BorderColour", C.transparent)
    gitgud.setProperty(edit, "Font", opts.font or "Bragi-14")
    gitgud.setText(edit, text.escape(value or ""))
    return edit
end

--- A checkbox (its "toggled" event carries "1" or "0").
function ui.check(name, parent, a, checked, label)
    create("Gitgud/Checkbox", name, parent, a)
    gitgud.setText(name, text.escape(label or ""))
    gitgud.setChecked(name, checked and true or false)
    return name
end

--- A 1px line.
function ui.rule(name, parent, a)
    create("Gitgud/StaticText", name, parent, a)
    gitgud.setProperty(name, "PanelColour", C.border)
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    gitgud.setText(name, "")
    return name
end

--- A caps heading ("APPEARANCE").
function ui.heading(name, parent, a, s)
    return ui.label(name, parent, a, s:upper(), { font = "Bragi-Caps", colour = C.sub })
end

return ui
