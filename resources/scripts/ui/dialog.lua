--- ui/dialog.lua — the one generic modal dialog (layouts/dialogs/dialog.xml).
--
-- Every prompt in the app is a call to dialog.show with a spec table; the
-- dialog shows only the rows the spec asks for and stacks them top to
-- bottom:
--
--     dialog.show({
--         title = "Clone a repository",
--         message = "Optional explanatory text.",
--         fields = {
--             { label = "URL", value = "" },
--             { label = "Local path", value = "C:\\src", browse = true },
--             { label = "Password", value = "", secret = true },  -- masked
--         },
--         checks = { { label = "Open it afterwards", value = true } },
--         ok = "Clone",                 -- OK button text
--         danger = false,               -- true paints OK red (destructive)
--         alt = { label = "Help", action = function(values) end,
--                 stayOpen = false },   -- true: keep the dialog open
--         onOk = function(values)       -- values.fields[i], values.checks[i]
--             return true               -- or false, "error shown in dialog"
--         end,
--         onCancel = function() end,
--         stayOpen = false,             -- true: OK runs onOk but keeps it open
--     })
--
-- A secret field shows each character as "*", with the one just typed
-- readable for a moment; its text can't be copied out.
--
-- dialog.close(spec) dismisses that dialog from code (no callback runs).
-- Shortcuts: dialog.confirm, dialog.alert, dialog.prompt. Other full-screen
-- modals (repository settings) reuse dialog.showModal / hideModal for the
-- dimmed backdrop and Escape handling.

local C = require("core.palette")
local geometry = require("ui.geometry")
local keys = require("core.keys")
local popup = require("ui.popup")
local text = require("core.text")

local dialog = {}

local MAX_FIELDS = 5
local MAX_CHECKS = 3
local DEFAULT_WIDTH = 500
local REVEAL_SECONDS = "1" -- how long a typed secret character stays readable

local spec = nil          -- the dialog being shown
local escapeToken = nil
local modalStack = {}     -- names of open modal windows, topmost last

--- Show the dimmed backdrop and a modal window above it.
-- @param name      the modal window
-- @param onEscape  function() run when Escape is pressed
-- @return an Escape token (pass to hideModal)
function dialog.showModal(name, onEscape)
    popup.close()

    gitgud.setVisible("ModalShade", true)
    gitgud.bringToFront("ModalShade")
    gitgud.setVisible(name, true)
    gitgud.bringToFront(name)
    modalStack[#modalStack + 1] = name

    return keys.pushEscape(onEscape)
end

--- Hide a modal window (and the backdrop when it was the last one).
-- @param name   the modal window
-- @param token  what showModal returned
function dialog.hideModal(name, token)
    gitgud.setVisible(name, false)
    keys.popEscape(token)

    for i = #modalStack, 1, -1 do
        if modalStack[i] == name then
            table.remove(modalStack, i)
        end
    end

    if #modalStack == 0 then
        gitgud.setVisible("ModalShade", false)
    else
        gitgud.bringToFront("ModalShade")
        gitgud.bringToFront(modalStack[#modalStack])
    end
end

--- True while any modal is open (views use it to ignore global shortcuts).
-- @return boolean
function dialog.isOpen()
    return #modalStack > 0
end

--- Estimate how tall a wrapped message will render.
-- @param message  plain text
-- @param width    available pixel width
-- @return height in pixels (0 for no message)
local function messageHeight(message, width)
    if not message or message == "" then
        return 0
    end

    local charsPerLine = math.max(20, math.floor(width / 7))
    local lines = 0
    for paragraph in (message .. "\n"):gmatch("([^\n]*)\n") do
        lines = lines + math.max(1, math.ceil(#paragraph / charsPerLine))
    end

    return lines * 19 + 6
end

--- A button width that fits its label (estimated; the default is 116 px).
-- @param label  button text
-- @return width in pixels
local function buttonWidth(label)
    return math.max(116, math.floor(#label * 7.5 + 30))
end

--- Collect the current field and checkbox values.
-- @return { fields = {...}, checks = {...} }
local function values()
    local out = { fields = {}, checks = {} }

    for i, _ in ipairs(spec.fields or {}) do
        out.fields[i] = gitgud.getText("DialogField" .. i)
    end
    for i, _ in ipairs(spec.checks or {}) do
        out.checks[i] = gitgud.getProperty("DialogCheck" .. i, "Selected") == "true"
    end

    return out
end

--- Close the dialog without running any callback.
local function close()
    if not spec then
        return
    end

    spec = nil
    dialog.hideModal("Dialog", escapeToken)
    escapeToken = nil
end

--- Show an error line inside the dialog (it stays open).
-- @param message  plain text
local function showError(message)
    gitgud.setText("DialogError", text.escape(message))
    gitgud.setVisible("DialogError", true)
end

--- OK / Enter: run onOk; close unless it returned false.
local function submit()
    if not spec then
        return
    end

    local current = spec
    local result = true
    local err = nil
    if current.onOk then
        result, err = current.onOk(values())
    end

    if result == false then
        showError(err or "Please check the values above.")
        return
    end

    if spec == current and not current.stayOpen then
        close()
    end
end

--- Cancel / Escape.
local function cancel()
    if not spec then
        return
    end

    local onCancel = spec.onCancel
    close()
    if onCancel then
        onCancel()
    end
end

--- Show the dialog described by `s` (see the header).
-- @param s  dialog spec
function dialog.show(s)
    if spec then
        close()
    end
    spec = s

    local width = s.width or DEFAULT_WIDTH
    local inner = width - 44
    local y = 16

    gitgud.setText("DialogTitle", text.escape(s.title or ""))
    y = y + 34

    local msgHeight = messageHeight(s.message, inner)
    gitgud.setVisible("DialogMessage", msgHeight > 0)
    if msgHeight > 0 then
        gitgud.setText("DialogMessage", text.escape(s.message))
        gitgud.setProperty("DialogMessage", "Area", geometry.band(y, msgHeight, 22))
        y = y + msgHeight + 8
    end

    local fields = s.fields or {}
    for i = 1, MAX_FIELDS do
        local field = fields[i]
        local label = "DialogFieldLabel" .. i
        local edit = "DialogField" .. i
        local browse = "DialogBrowse" .. i

        gitgud.setVisible(label, field ~= nil)
        gitgud.setVisible(edit, field ~= nil)
        gitgud.setVisible(browse, field ~= nil and field.browse == true)

        if field then
            gitgud.setText(label, text.escape(field.label or ""))
            gitgud.setProperty(label, "Area", geometry.band(y, 20, 22))
            y = y + 22

            gitgud.setProperty(edit, "TextMaskingEnabled", field.secret and "true" or "false")
            gitgud.setProperty(edit, "TextMaskingRevealTime", field.secret and REVEAL_SECONDS or "0")
            gitgud.setText(edit, field.value or "")
            local right = field.browse and -122 or -22
            gitgud.setProperty(edit, "Area", geometry.area(0, 22, 0, y, 1, right, 0, y + 32))
            gitgud.setProperty(browse, "Area", geometry.area(1, -114, 0, y, 1, -22, 0, y + 32))
            y = y + 42
        end
    end

    local checks = s.checks or {}
    for i = 1, MAX_CHECKS do
        local check = checks[i]
        local name = "DialogCheck" .. i

        gitgud.setVisible(name, check ~= nil)
        if check then
            gitgud.setText(name, text.escape(check.label or ""))
            gitgud.setChecked(name, check.value == true)
            gitgud.setProperty(name, "Area", geometry.area(0, 14, 0, y, 1, -22, 0, y + 30))
            y = y + 32
        end
    end

    gitgud.setVisible("DialogError", false)
    gitgud.setProperty("DialogError", "Area", geometry.band(y, 22, 22))
    y = y + 26

    -- Buttons, wide enough for their labels.
    local okWidth = buttonWidth(s.ok or "OK")
    local cancelWidth = buttonWidth(s.cancel or "Cancel")
    gitgud.setProperty("DialogOkButton", "Area", geometry.area(1, -22 - okWidth, 1, -46, 1, -22, 1, -14))
    gitgud.setProperty("DialogOkGlow", "Area", geometry.area(1, -30 - okWidth, 1, -54, 1, -14, 1, -6))
    gitgud.setProperty("DialogCancelButton", "Area",
        geometry.area(1, -30 - okWidth - cancelWidth, 1, -46, 1, -30 - okWidth, 1, -14))
    if s.alt then
        gitgud.setProperty("DialogAltButton", "Area",
            geometry.area(0, 22, 1, -46, 0, 22 + buttonWidth(s.alt.label), 1, -14))
    end
    gitgud.setText("DialogOkButton", text.escape(s.ok or "OK"))
    local okFill = s.danger and C.err or C.blue
    local okHover = s.danger and "FFFF7A7C" or "FF93A4FF"
    gitgud.setProperty("DialogOkButton", "NormalFillColour", okFill)
    gitgud.setProperty("DialogOkButton", "HoverFillColour", okHover)
    gitgud.setProperty("DialogOkButton", "BorderColour", okHover)
    gitgud.setProperty("DialogOkGlow", "GlowColour", s.danger and "90FF5457" or "907C93FF")

    gitgud.setVisible("DialogCancelButton", s.cancel ~= false)
    gitgud.setText("DialogCancelButton", text.escape(s.cancel or "Cancel"))

    gitgud.setVisible("DialogAltButton", s.alt ~= nil)
    if s.alt then
        gitgud.setText("DialogAltButton", text.escape(s.alt.label))
    end

    local height = y + 60
    gitgud.setProperty("Dialog", "Area",
        geometry.area(0.5, -width / 2, 0.5, -height / 2, 0.5, width / 2, 0.5, height / 2))

    escapeToken = dialog.showModal("Dialog", cancel)

    if fields[1] then
        gitgud.focus("DialogField1")
    end
end

--- Dismiss the dialog from code without running onOk or onCancel.
-- @param s  only close when this spec is the one showing (nil: any)
function dialog.close(s)
    if s == nil or spec == s then
        close()
    end
end

--- Ask a yes/no question.
-- @param title    dialog title
-- @param message  explanation
-- @param okLabel  text for the confirming button (e.g. "Discard changes")
-- @param onOk     function() run when confirmed
-- @param danger   true for destructive actions (red button)
function dialog.confirm(title, message, okLabel, onOk, danger)
    dialog.show({
        title = title,
        message = message,
        ok = okLabel,
        danger = danger,
        onOk = function()
            onOk()
            return true
        end,
    })
end

--- Show a message with a single OK button.
-- @param title    dialog title
-- @param message  body text
function dialog.alert(title, message)
    dialog.show({ title = title, message = message, cancel = false })
end

--- Ask for one line of text.
-- @param title    dialog title
-- @param label    field label
-- @param value    initial text
-- @param okLabel  confirming button text
-- @param onOk     function(text) -> true | false, "error"
function dialog.prompt(title, label, value, okLabel, onOk)
    dialog.show({
        title = title,
        fields = { { label = label, value = value } },
        ok = okLabel,
        onOk = function(v)
            return onOk(text.trim(v.fields[1]))
        end,
    })
end

--- Wire the dialog's buttons and fields. Called once by main.lua.
function dialog.init()
    gitgud.on("DialogOkButton.clicked", submit)
    gitgud.on("DialogCancelButton.clicked", cancel)
    gitgud.on("ModalShade.clicked", function()
        -- Clicking the backdrop does nothing (explicit choice required).
    end)

    gitgud.on("DialogAltButton.clicked", function()
        if spec and spec.alt then
            local action = spec.alt.action
            local v = values()
            if not spec.alt.stayOpen then
                close()
            end
            action(v)
        end
    end)

    for i = 1, MAX_FIELDS do
        gitgud.on("DialogField" .. i .. ".accepted", submit)

        gitgud.on("DialogBrowse" .. i .. ".clicked", function()
            local field = spec and spec.fields and spec.fields[i]
            local chosen = gitgud.pickFolder(field and field.label or "Choose a folder")
            if chosen then
                gitgud.setText("DialogField" .. i, chosen)
            end
        end)
    end
end

return dialog
