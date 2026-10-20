--- tests/ui/tab-focus.lua: Tab and Shift+Tab between text boxes in the
-- GitGud UI: a dialog's fields in order with wrap-around, disabled fields
-- skipped, the text selected on arrival, Enter in the last field pressing
-- the dialog's button, and the commit box keeping Tab to its own two boxes.
--
-- Run it in a repository made by make-testrepo.ps1 with GITGUD_UI=default,
-- a scratch APPDATA and LOCALAPPDATA, and GITGUD_SCRIPT pointing here.
-- Prints "[check] ..." lines.

local dialog = require("ui.dialog")

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local function active(name)
    return gitgud.getProperty(name, "Active") == "true"
end

--- The DialogField<n> that has the focus, or nil.
local function activeField()
    for i = 1, 5 do
        if active("DialogField" .. i) then
            return i
        end
    end
    return nil
end

--- Whether all of a box's text is selected.
local function allSelected(name)
    return gitgud.getProperty(name, "SelectionStart") == "0"
        and tonumber(gitgud.getProperty(name, "SelectionLength")) == #gitgud.getText(name)
end

-- ------------------------------------------------- a real dialog: Add remote

step(1200, "open Add a remote", function()
    require("views.remotes").add()
end)

step(300, "Tab walks Name, URL, and wraps", function()
    check("the dialog opens on Name", activeField() == 1)
    gitgud.simulateText("upstream")
    gitgud.simulateKey("tab")
    check("Tab: URL", activeField() == 2)
    gitgud.simulateText("server.test/app.git")
    gitgud.simulateKey("tab")
    check("Tab from the last field wraps to Name", activeField() == 1)
    check("Name's text is selected on arrival", allSelected("DialogField1"))
    gitgud.screenshot(OUT .. "/tab-01-remote.png")
end)

step(300, "Shift+Tab goes back", function()
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab from the first field wraps to URL", activeField() == 2)
    check("URL's text is selected on arrival", allSelected("DialogField2"))
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab: Name", activeField() == 1)
    check("Tab typed nothing", gitgud.getText("DialogField1") == "upstream"
        and gitgud.getText("DialogField2") == "server.test/app.git")
end)

step(200, "close it", function()
    gitgud.emit("key", "escape")
end)

-- --------------------------------- the generic dialog: order, skip, Enter

local submitted = nil

step(300, "a dialog with a disabled field", function()
    dialog.show({
        title = "Tab order",
        fields = {
            { label = "One", value = "1" },
            { label = "Two (disabled)", value = "2", enabled = function() return false end },
            { label = "Three", value = "3" },
            { label = "Four", value = "4" },
        },
        ok = "Done",
        onOk = function(v)
            submitted = v.fields
            return true
        end,
    })
end)

step(300, "Tab skips the disabled field", function()
    check("starts on One", activeField() == 1)
    gitgud.simulateKey("tab")
    check("Tab skips Two: Three", activeField() == 3)
    gitgud.simulateKey("tab")
    check("Tab: Four", activeField() == 4)
    gitgud.simulateKey("shift+tab")
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab twice skips Two: One", activeField() == 1)
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab wraps to Four", activeField() == 4)
end)

step(200, "Enter in the last field", function()
    gitgud.simulateText("x")
    gitgud.simulateKey("enter")
end)

step(300, "the dialog's button ran", function()
    check("Enter in the last field submits", submitted ~= nil and submitted[4] == "x")
    check("and closes the dialog", not dialog.isOpen())
end)

-- ------------------------------------------- the commit box is its own group

step(300, "the commit box", function()
    local shown = gitgud.getProperty("SummaryEdit", "Visible") == "true"
    check("the commit box shows", shown)
    gitgud.focus("SummaryEdit")
    gitgud.simulateText("Summary")
    gitgud.simulateKey("tab")
    check("Tab from the summary: the description", active("DescriptionEdit"))
    gitgud.simulateKey("tab")
    check("Tab from the description wraps to the summary, not the filter box",
        active("SummaryEdit") and not active("ChangesFilterEdit"))
    gitgud.simulateKey("shift+tab")
    check("Shift+Tab: the description", active("DescriptionEdit"))
    check("no tab typed into the description", not gitgud.getText("DescriptionEdit"):find("\t", 1, true))
end)

step(200, "clean up", function()
    gitgud.setText("SummaryEdit", "")
    gitgud.setText("DescriptionEdit", "")
    gitgud.focus("SummaryEdit")
end)

step(200, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
