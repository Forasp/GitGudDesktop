--- p4/toolbar.lua — P4V's toolbar: an icon over a label per command,
-- greyed out when the command doesn't apply to the selection.
--
-- The buttons are data (BUTTONS below); mods can add their own:
--     require("p4.toolbar").add({ icon = "Console", label = "Build", action = fn })

local C = require("core.palette")
local actions = require("p4.actions")
local app = require("core.app")
local commands = require("p4.commands")
local geometry = require("ui.geometry")
local icons = require("p4.icons")
local repo = require("core.repo")
local selection = require("p4.selection")
local text = require("core.text")

local toolbar = { name = "toolbar" }

local WIDTH = 66
local HEIGHT = 46
local GAP = 2

--- True when a repository is open.
local function open()
    return repo.state().open
end

--- True when the selection has a file.
local function hasFile()
    return open() and #selection.files() > 0
end

--- True when a single file is selected.
local function oneFile()
    return open() and #selection.files() == 1
end

--- True when the selection holds changed files.
local function hasChanges()
    return open() and #selection.changedFiles() > 0
end

--- A changelist that can be submitted / shelved: the selected one, else the
-- default when it has files.
local function submittable()
    return open() and #repo.state().files > 0
end

local BUTTONS = {
    { icon = "Refresh", label = "Refresh", tip = "Refresh the workspace state (F5)", action = app.requestRefresh },
    { icon = "GetLatest", label = "Get Latest", tip = "Get the latest revision: pull from the upstream", enabled = open, action = actions.getLatest },
    { icon = "Submit", label = "Submit", tip = "Submit a pending changelist", enabled = submittable, action = function()
        actions.submit()
    end },
    { separator = true },
    { icon = "Checkout", label = "Check Out", tip = "Open the selected files for edit", enabled = hasFile, action = function()
        actions.checkOut()
    end },
    { icon = "Add", label = "Add", tip = "Mark the selected new files for add", enabled = hasFile, action = function()
        actions.markForAdd()
    end },
    { icon = "Delete", label = "Delete", tip = "Mark the selected files for delete", enabled = hasFile, action = function()
        actions.markForDelete()
    end },
    { icon = "Revert", label = "Revert", tip = "Revert the selected files", enabled = function()
        return hasChanges() or hasFile()
    end, action = function()
        actions.revert()
    end },
    { separator = true },
    { icon = "Diff", label = "Diff", tip = "Diff the selected file against the have revision", enabled = oneFile, action = function()
        require("p4.windows").diffSelection()
    end },
    { icon = "History", label = "History", tip = "Show the selected file's or folder's history", enabled = function()
        return open() and selection.primary() ~= nil and selection.primary().path ~= nil
    end, action = function()
        local item = selection.primary()
        require("p4.views.history").show(item.path, item.folder)
    end },
    { icon = "Timelapse", label = "Time-lapse", tip = "Time-lapse view of the selected file", enabled = oneFile, action = function()
        require("p4.windows.timelapse").open(selection.files()[1])
    end },
    { icon = "Revgraph", label = "Rev Graph", tip = "Revision graph of the selected file", enabled = oneFile, action = function()
        require("p4.windows.revgraph").open(selection.files()[1])
    end },
    { separator = true },
    { icon = "Shelve", label = "Shelve", tip = "Shelve a pending changelist", enabled = submittable, action = function()
        actions.shelve()
    end },
    { icon = "Merge", label = "Integrate", tip = "Merge/integrate another branch into this one", enabled = open, action = function()
        commands.integrate()
    end },
    { separator = true },
    { icon = "Fetch", label = "Fetch", tip = "Fetch every remote", enabled = function()
        return open() and repo.primaryRemote() ~= nil
    end, action = commands.fetch },
    { icon = "Push", label = "Push", tip = "Push the current branch", enabled = function()
        return open() and repo.primaryRemote() ~= nil
    end, action = commands.push },
}

local built = 0

--- Create the widgets for the buttons.
local function build()
    local x = 0
    for i, button in ipairs(BUTTONS) do
        local name = "P4Tool" .. i
        if i > built then
            if button.separator then
                gitgud.createWindow("Gitgud/StaticText", name, "ToolbarButtons")
                gitgud.setProperty(name, "PanelColour", C.border)
                gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
                gitgud.setText(name, "")
            else
                gitgud.createWindow("Gitgud/Button", name, "ToolbarButtons")
                gitgud.setText(name, "")
                gitgud.setProperty(name, "NormalFillColour", C.transparent)
                gitgud.setProperty(name, "HoverFillColour", C.header)
                gitgud.setProperty(name, "PushedFillColour", C.selection)
                gitgud.setProperty(name, "DisabledFillColour", C.transparent)
                gitgud.setProperty(name, "BorderColour", C.transparent)
                gitgud.setProperty(name, "TooltipText", button.tip or button.label)

                gitgud.createWindow("Gitgud/Image", name .. "Icon", name)
                gitgud.setProperty(name .. "Icon", "Image", icons.image(button.icon))
                gitgud.setProperty(name .. "Icon", "Area", geometry.area(0.5, -12, 0, 3, 0.5, 12, 0, 27))
                gitgud.setProperty(name .. "Icon", "CursorPassThroughEnabled", "true")

                gitgud.createWindow("Gitgud/Label", name .. "Label", name)
                gitgud.setProperty(name .. "Label", "Area", geometry.area(0, 0, 0, 28, 1, 0, 1, 0))
                gitgud.setProperty(name .. "Label", "HorzFormatting", "CentreAligned")
                gitgud.setProperty(name .. "Label", "Font", "Gitgud-System-Small")
                gitgud.setProperty(name .. "Label", "CursorPassThroughEnabled", "true")
                gitgud.setText(name .. "Label", text.escape(button.label))

                local index = i
                gitgud.on(name .. ".clicked", function()
                    local b = BUTTONS[index]
                    if b.action then
                        b.action()
                    end
                end)
            end
            built = i
        end
        if button.separator then
            gitgud.setProperty(name, "Area", geometry.rect(x + 3, 6, 1, HEIGHT - 12))
            x = x + 8
        else
            gitgud.setProperty(name, "Area", geometry.rect(x, 0, WIDTH, HEIGHT))
            x = x + WIDTH + GAP
        end
    end
end

--- Grey out what doesn't apply right now.
function toolbar.update()
    for i, button in ipairs(BUTTONS) do
        if not button.separator then
            local enabled = button.enabled == nil or button.enabled()
            local name = "P4Tool" .. i
            gitgud.setEnabled(name, enabled)
            gitgud.setProperty(name .. "Icon", "ImageColour", enabled and "FFFFFFFF" or "55FFFFFF")
            gitgud.setProperty(name .. "Label", "NormalTextColour", enabled and C.text or C.disabled)
        end
    end
end

--- Add a button (mods).
-- @param button  { icon, label, tip?, enabled?, action } or { separator = true }
function toolbar.add(button)
    BUTTONS[#BUTTONS + 1] = button
    build()
    toolbar.update()
end

function toolbar.init()
    build()
    app.subscribe("selection.changed", toolbar.update)
end

function toolbar.refresh()
    toolbar.update()
end

return toolbar
