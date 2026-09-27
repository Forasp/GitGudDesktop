--- main.lua — the user-interface picker (a UI package of its own).
--
-- Shown on first launch and whenever a UI asks for it (gitgud.showUiPicker).
-- One card per interface: the default UI, the built-in alternatives
-- (resources/uis/*), and any package already chosen from a folder. Picking
-- one remembers it (gitgud.switchUi(id, true)) and starts it; "Use an
-- interface from a folder…" accepts any folder holding scripts/main.lua and
-- layouts/main.xml. Cancel goes back to the interface that opened the picker.
--
-- It reuses the default UI's toolkit (require searches this package's
-- scripts/ first, then resources/scripts).

local C = require("core.palette")
local dialog = require("ui.dialog")
local geometry = require("ui.geometry")
local keys = require("core.keys")
local popup = require("ui.popup")
local text = require("core.text")

keys.init()
popup.init()
dialog.init()

local CARD_MIN_WIDTH = 300
local CARD_GAP = 24
local PREVIEW_HEIGHT = 190

-- Screenshots of the built-in interfaces (imagesets/Previews.xml).
local previews = {
    default = "GitGud-Previews/Default",
    p4v = "GitGud-Previews/P4V",
}

local cards = {}      -- { id, name } per card, in order
local current = gitgud.currentUi()
local previous = gitgud.previousUi()
local firstLaunch = gitgud.firstLaunch()

--- Switch to a UI, remembering the choice; report a failure in a dialog.
-- @param spec  package id or "path:<folder>"
local function choose(spec)
    local ok, err = gitgud.switchUi(spec, true)
    if not ok then
        dialog.alert("That interface can't be used", err or "Unknown error.")
    end
end

--- Back to the UI that opened the picker (not on first launch).
local function back()
    if previous ~= "" then
        gitgud.switchUi(previous, false)
    end
end

--- Lay the cards out in rows that fill the width.
local function layoutCards()
    local _, _, width, height = gitgud.getRect("PickerCards")
    if not width or #cards == 0 then
        return
    end

    local perRow = math.max(1, math.min(#cards, math.floor((width + CARD_GAP) / (CARD_MIN_WIDTH + CARD_GAP))))
    local cardWidth = math.floor((width - (perRow - 1) * CARD_GAP) / perRow)
    local rows = math.ceil(#cards / perRow)
    local cardHeight = math.min(420, math.floor((height - (rows - 1) * CARD_GAP) / rows))
    local previewHeight = math.min(PREVIEW_HEIGHT, cardHeight - 150)

    for i = 1, #cards do
        local column = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        local x = column * (cardWidth + CARD_GAP)
        local y = row * (cardHeight + CARD_GAP)
        gitgud.setProperty("Card" .. i, "Area", geometry.rect(x, y, cardWidth, cardHeight))
        gitgud.setProperty("CardPreview" .. i, "Area", geometry.area(0, 1, 0, 1, 1, -1, 0, previewHeight))
        gitgud.setProperty("CardTitle" .. i, "Area", geometry.band(previewHeight + 12, 28, 18))
        gitgud.setProperty("CardText" .. i, "Area",
            geometry.area(0, 18, 0, previewHeight + 42, 1, -18, 1, -58))
        gitgud.setProperty("CardButton" .. i, "Area", geometry.area(0, 18, 1, -48, 1, -18, 1, -14))
    end
end

--- Build one card.
-- @param i   card index
-- @param ui  a gitgud.uiList() row
local function buildCard(i, ui)
    local card = "Card" .. i
    gitgud.createWindow("Gitgud/StaticText", card, "PickerCards")
    gitgud.setProperty(card, "PanelColour", C.bg2)
    gitgud.setProperty(card, "FrameEnabled", "true")
    gitgud.setProperty(card, "FrameColour", ui.id == current.id and C.blue or C.border)
    gitgud.setText(card, "")

    local preview = "CardPreview" .. i
    local image = previews[ui.id]
    if image then
        gitgud.createWindow("Gitgud/Image", preview, card)
        gitgud.setProperty(preview, "Image", image)
    else
        -- No screenshot for a custom package: a panel with its folder.
        gitgud.createWindow("Gitgud/StaticText", preview, card)
        gitgud.setProperty(preview, "PanelColour", C.bg1)
        gitgud.setProperty(preview, "HorzFormatting", "WordWrapCentreAligned")
        gitgud.setProperty(preview, "TextColours", C.dim)
        gitgud.setText(preview, text.escape(ui.builtIn and ui.name or ui.root))
    end
    gitgud.setProperty(preview, "CursorPassThroughEnabled", "true")

    local title = "CardTitle" .. i
    gitgud.createWindow("Gitgud/Label", title, card)
    gitgud.setProperty(title, "Font", "Gitgud-UI-Title")
    local label = text.escape(ui.name)
    if ui.id == current.id or ui.id == previous then
        label = label .. text.colour(C.dim, "   (current)")
    end
    gitgud.setText(title, label)

    local body = "CardText" .. i
    gitgud.createWindow("Gitgud/StaticText", body, card)
    gitgud.setProperty(body, "PanelColour", C.transparent)
    gitgud.setProperty(body, "HorzFormatting", "WordWrapLeftAligned")
    gitgud.setProperty(body, "VertFormatting", "TopAligned")
    gitgud.setProperty(body, "TextColours", C.text2)
    gitgud.setProperty(body, "CursorPassThroughEnabled", "true")
    local description = ui.description ~= "" and ui.description or ("From " .. ui.root)
    gitgud.setText(body, text.escape(description))

    local button = "CardButton" .. i
    gitgud.createWindow("Gitgud/Button", button, card)
    gitgud.setText(button, "Use " .. text.escape(ui.name))
    gitgud.setProperty(button, "NormalFillColour", C.blue)
    gitgud.setProperty(button, "HoverFillColour", "FF93A4FF")
    gitgud.setProperty(button, "NormalTextColour", C.bg0)
    gitgud.setProperty(button, "HoverTextColour", C.bg0)
    gitgud.setProperty(button, "PushedTextColour", C.bg0)
    gitgud.on(button .. ".clicked", function()
        choose(ui.id)
    end)

    cards[i] = { id = ui.id, name = ui.name }
end

--- Fill the window.
local function build()
    gitgud.setWindowTitle("", "GitGud Desktop — choose an interface")

    if firstLaunch then
        gitgud.setText("PickerHeading", "Welcome to GitGud Desktop")
        gitgud.setText("PickerSubtitle", text.escape(
            "Pick the interface you'd like to start with. Both work on the same repositories "
                .. "and settings; you can switch at any time from the File menu (GitGud) or "
                .. "Edit > Preferences (P4V), or build your own interface in XML and Lua."))
    else
        gitgud.setText("PickerHeading", "Choose your interface")
        gitgud.setText("PickerSubtitle", text.escape(
            "Switching restarts the interface; your repositories, tabs, and settings stay."))
    end
    gitgud.setText("PickerNote", text.escape(
        "Your own interface: a folder with scripts/main.lua and layouts/main.xml — see the Modding guide."))
    gitgud.setVisible("PickerBackButton", previous ~= "")

    for i, ui in ipairs(gitgud.uiList()) do
        buildCard(i, ui)
    end
    layoutCards()
end

gitgud.on("PickerFolderButton.clicked", function()
    local folder = gitgud.pickFolder("Choose a GitGud interface folder")
    if folder then
        choose("path:" .. folder)
    end
end)

gitgud.on("PickerBackButton.clicked", back)
gitgud.on("PickerCloseButton.clicked", function()
    gitgud.emit("window.close", "")
end)
gitgud.on("PickerMinButton.clicked", function()
    gitgud.emit("window.minimize", "")
end)
gitgud.on("window.resized", layoutCards)
keys.bind("escape", back, "Back")

build()
