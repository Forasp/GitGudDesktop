--- tests/ui/bragi-memory.lua: Settings, Instructions and memory (G2): the
-- files Claude Code reads for the open repository and for every project,
-- made when missing, edited in place (Save, Cancel), and auto memory.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, and CLAUDE_CONFIG_DIR set to a scratch folder: files
-- are written there). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local config = os.getenv("CLAUDE_CONFIG_DIR")
if gitgud.currentUi().id ~= "bragi" or not config then
    check("needs GITGUD_UI=bragi and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local bragiSettings = require("bragi.settings")
local repo = require("core.repo")

local function shot(name)
    gitgud.screenshot(OUT .. "/memory-" .. name .. ".png")
end
local function textOf(card, row, part)
    return gitgud.getText(bragiSettings.widget(card, row, part)) or ""
end
local function clickName(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function click(card, row)
    clickName(bragiSettings.widget(card, row, "Action"))
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local s = f:read("a")
    f:close()
    return s
end
local function editorShown()
    return bragiSettings.editor() ~= nil
end
local function editorText()
    return gitgud.getText(bragiSettings.editor("")) or ""
end
local function setEditor(s)
    gitgud.setText(bragiSettings.editor(""), s)
end

local root
local memoryFile

step(1500, "open Instructions and memory", function()
    root = repo.state().path
    -- What Claude Code remembered about this repository.
    local folder = root:gsub("[^%w]", "-")
    local dir = config .. "/projects/" .. folder .. "/memory"
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    memoryFile = dir .. "/MEMORY.md"
    local f = assert(io.open(memoryFile, "wb"))
    f:write("- The tests run with ctest.\n")
    f:close()
    bragiSettings.open("memory")
end)

step(400, "the section", function()
    check("the project's CLAUDE.md can be made", textOf(1, 1, "Title"):find("CLAUDE.md for", 1, true) ~= nil
        and textOf(1, 1, "Action") == "Create")
    check("so can CLAUDE.local.md", textOf(1, 2, "Title"):find("CLAUDE.local.md for", 1, true) ~= nil)
    check("and yours", textOf(2, 1, "Title") == "Your CLAUDE.md")
    check("auto memory is listed", textOf(3, 1, "Title") == "MEMORY.md"
        and textOf(3, 1, "Action") == "Edit")
    shot("01-section")
    click(1, 1)
end)

step(300, "the editor for a new file", function()
    check("the editor shows", editorShown())
    check("a new file starts empty", editorText() == "")
    setEditor("# Repo rules\nUse tabs.")
    shot("02-editor")
end)

step(300, "Save", function()
    clickName(bragiSettings.editor("Save"))
end)

step(300, "saved", function()
    check("the file is written, ending in a newline", read(root .. "/CLAUDE.md") == "# Repo rules\nUse tabs.\n")
    check("back to the list", not editorShown())
    check("it's listed as the project's", textOf(1, 1, "Title") == "CLAUDE.md"
        and textOf(1, 1, "Sub"):find("shared", 1, true) ~= nil and textOf(1, 1, "Action") == "Edit")
    click(2, 1)
end)

step(300, "your CLAUDE.md", function()
    check("its editor shows", editorShown())
    setEditor("Be terse.")
    clickName(bragiSettings.editor("Save"))
end)

step(300, "yours is saved", function()
    check("written to the config folder", read(config .. "/CLAUDE.md") == "Be terse.\n")
    check("listed as yours", textOf(2, 1, "Title") == "CLAUDE.md"
        and textOf(2, 1, "Sub"):find("every project", 1, true) ~= nil)
    click(3, 1)
end)

step(300, "edit memory", function()
    check("its text is loaded", editorText():find("ctest", 1, true) ~= nil)
    setEditor("- something else")
    clickName(bragiSettings.editor("Cancel"))
end)

step(300, "Cancel keeps the file", function()
    check("unchanged", read(memoryFile) == "- The tests run with ctest.\n")
    check("back to the list", not editorShown())
    click(3, 1)
end)

step(300, "edit memory again", function()
    setEditor("- The tests run with ctest.\n- Use the release preset.\n")
    clickName(bragiSettings.editor("Save"))
end)

step(300, "memory saved", function()
    check("memory updated", read(memoryFile) == "- The tests run with ctest.\n- Use the release preset.\n")
    click(1, 1)
end)

step(300, "leaving the section closes the editor", function()
    check("editing the project's file", editorShown())
    bragiSettings.open("claude")
end)

step(300, "another section", function()
    check("the editor is gone", not editorShown())
    bragiSettings.open("memory")
end)

step(300, "back", function()
    check("the list, not the editor", not editorShown() and textOf(1, 1, "Action") == "Edit")
    shot("03-after")
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
