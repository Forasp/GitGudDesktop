--- depot/changedialog.lua — the changelist form (layouts/dialogs/
-- changelist.xml): New / Edit Pending Changelist, Submit, Shelve, Unshelve.
--
--     changedialog.show({
--         title = "Submit Changelist 3",
--         info = "Workspace: repo    Branch: main",
--         description = "Fix the login bug",        -- nil hides the box
--         files = { { path = "src/a.cpp", code = "M", checked = true } },
--         options = { { label = "Push after submitting", value = true } },
--         ok = "Submit",
--         onOk = function(values)   -- values.description / files / options
--             return true            -- or false, "error shown in the form"
--         end,
--     })

local C = require("core.palette")
local dialog = require("ui.dialog")
local geometry = require("ui.geometry")
local icons = require("depot.icons")
local text = require("core.text")

local changedialog = {}

local MAX_OPTIONS = 3

local spec = nil
local token = nil
local checked = {}

--- Redraw the file rows.
local function renderFiles()
    local rows = {}
    for i, file in ipairs(spec.files or {}) do
        local box = icons.inline(checked[i] and "CheckOn" or "CheckOff")
        local action = file.action or icons.actionName(file.code)
        rows[i] = text.rowHeight(20) .. box .. " " .. icons.inline(file.icon or icons.forStatus(file.code))
            .. " " .. text.colour(C.text, file.label or file.path)
            .. text.colour(C.dim, "   " .. action)
    end
    gitgud.setList("ChangeDialogFiles", rows)

    local all = true
    for i = 1, #(spec.files or {}) do
        all = all and checked[i]
    end
    gitgud.setText("ChangeDialogToggleAll", all and "Select None" or "Select All")
end

--- Close without callbacks.
local function close()
    if spec then
        spec = nil
        dialog.hideModal("ChangeDialog", token)
        token = nil
    end
end

--- Gather the values.
local function values()
    local out = { description = gitgud.getText("ChangeDialogDescription"), files = {}, options = {} }
    out.description = out.description:gsub("\r", ""):gsub("%s+$", "")
    for i, file in ipairs(spec.files or {}) do
        if checked[i] then
            out.files[#out.files + 1] = file.path
        end
    end
    for i = 1, MAX_OPTIONS do
        out.options[i] = gitgud.getProperty("ChangeDialogOption" .. i, "Selected") == "true"
    end

    return out
end

--- OK.
local function submit()
    if not spec then
        return
    end
    local current = spec
    local ok, err = true, nil
    if current.onOk then
        ok, err = current.onOk(values())
    end
    if ok == false then
        gitgud.setText("ChangeDialogError", text.escape(err or "Please check the form."))
        return
    end
    if spec == current then
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

--- Show the form.
-- @param s  form spec (see the header)
function changedialog.show(s)
    close()
    spec = s
    checked = {}
    for i, file in ipairs(s.files or {}) do
        checked[i] = file.checked ~= false
    end

    gitgud.setText("ChangeDialogTitle", text.escape(s.title or ""))
    gitgud.setText("ChangeDialogInfo", text.escape(s.info or ""))

    local hasDescription = s.description ~= nil
    gitgud.setVisible("ChangeDialogDescriptionLabel", hasDescription)
    gitgud.setVisible("ChangeDialogDescription", hasDescription)
    gitgud.setText("ChangeDialogDescription", s.description or "")
    gitgud.setProperty("ChangeDialogDescription", "ReadOnly", s.readOnly and "true" or "false")

    local hasFiles = s.files ~= nil
    gitgud.setVisible("ChangeDialogFilesLabel", hasFiles)
    gitgud.setVisible("ChangeDialogFiles", hasFiles)
    gitgud.setVisible("ChangeDialogToggleAll", hasFiles and s.selectable ~= false)
    gitgud.setText("ChangeDialogFilesLabel", text.escape(s.filesLabel or "Files:"))

    -- Without a description the file list moves up.
    local listTop = hasDescription and 218 or 80
    gitgud.setProperty("ChangeDialogFilesLabel", "Area", geometry.area(0, 14, 0, listTop - 22, 1, -200, 0, listTop - 4))
    gitgud.setProperty("ChangeDialogToggleAll", "Area", geometry.area(1, -120, 0, listTop - 24, 1, -14, 0, listTop - 2))

    local options = s.options or {}
    for i = 1, MAX_OPTIONS do
        local name = "ChangeDialogOption" .. i
        gitgud.setVisible(name, options[i] ~= nil)
        if options[i] then
            gitgud.setText(name, text.escape(options[i].label))
            gitgud.setChecked(name, options[i].value == true)
        end
    end
    local optionRoom = #options * 22 + 50
    gitgud.setProperty("ChangeDialogFiles", "Area", geometry.area(0, 14, 0, listTop, 1, -14, 1, -optionRoom))
    for i = 1, MAX_OPTIONS do
        local top = optionRoom - (i - 1) * 22
        gitgud.setProperty("ChangeDialogOption" .. i, "Area", geometry.area(0, 12, 1, -top + 4, 1, -14, 1, -top + 26))
    end

    gitgud.setText("ChangeDialogError", "")
    gitgud.setText("ChangeDialogOk", text.escape(s.ok or "OK"))
    gitgud.setVisible("ChangeDialogAlt", s.alt ~= nil)
    if s.alt then
        gitgud.setText("ChangeDialogAlt", text.escape(s.alt.label))
    end

    local height = s.height or (hasDescription and 560 or 460)
    local width = s.width or 680
    gitgud.setProperty("ChangeDialog", "Area",
        geometry.area(0.5, -width / 2, 0.5, -height / 2, 0.5, width / 2, 0.5, height / 2))

    renderFiles()
    token = dialog.showModal("ChangeDialog", cancel)
    if hasDescription and not s.readOnly then
        gitgud.focus("ChangeDialogDescription")
    end
end

--- True while the form is open.
function changedialog.isOpen()
    return spec ~= nil
end

--- Wire the form.
function changedialog.init()
    gitgud.on("ChangeDialogOk.clicked", submit)
    gitgud.on("ChangeDialogCancel.clicked", cancel)
    gitgud.on("ChangeDialogAlt.clicked", function()
        if spec and spec.alt then
            local action = spec.alt.action
            local v = values()
            close()
            action(v)
        end
    end)
    gitgud.on("ChangeDialogFiles.clicked", function(value)
        local _, _, row = require("ui.menu").parseClick(value)
        if spec and row and spec.files[row] and spec.selectable ~= false then
            checked[row] = not checked[row]
            renderFiles()
        end
    end)
    gitgud.on("ChangeDialogToggleAll.clicked", function()
        if not spec then
            return
        end
        local all = true
        for i = 1, #spec.files do
            all = all and checked[i]
        end
        for i = 1, #spec.files do
            checked[i] = not all
        end
        renderFiles()
    end)
end

return changedialog
