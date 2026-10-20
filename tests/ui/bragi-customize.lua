--- tests/ui/bragi-customize.lua: your own changes to the Bragi interface
-- (bragi/customize.lua, app/UiPackages.h). Files in the customizations
-- folder (<config>/bragi/ui) win over the shipped ones; a broken one falls
-- back to the shipped file with a note; a theme there is offered and
-- applies; bragi_ui_paths says where everything is; Reset all moves the
-- folder aside and the shipped interface comes back. The script runs again
-- after each reload and theme switch, so it keeps its phase in a config
-- file.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, a scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT
-- pointing here). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local appData = os.getenv("APPDATA") or ""
if gitgud.currentUi().id ~= "bragi" or not appData:lower():find("sandbox", 1, true) then
    check("needs GITGUD_UI=bragi and a scratch APPDATA", false)
    gitgud.emit("window.close", "")
    return
end

local bragiSettings = require("bragi.settings")
local customize = require("bragi.customize")
local uitools = require("bragi.uitools")

local PHASE_FILE = "bragi-customize-test-phase"
local phase = gitgud.configRead(PHASE_FILE) or ""

local function read(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local s = f:read("a")
    f:close()
    return s
end
local function has(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then
            return true
        end
    end
    return false
end
-- Reset all, as Settings does it (without the confirmation): the backup
-- is noted for the next phase.
local function resetAll()
    local backup = gitgud.uiOverlayReset()
    gitgud.configWrite("bragi-customize-test-backup", backup or "")
end
local function slashes(s)
    return (tostring(s or ""):gsub("\\", "/"))
end

if phase == "" then
    step(1500, "nothing customized yet", function()
        local o = gitgud.uiOverlay()
        check("the folder is in the config", slashes(o.root):find("/bragi/ui$") ~= nil
            and slashes(o.root):lower():find(slashes(appData):lower(), 1, true) == 1)
        check("the shipped folder is the interface's own", o.shipped == gitgud.currentUi().root)
        check("no files, no errors", #o.files == 0 and #o.errors == 0)
        check("only the shipped themes", has(gitgud.themes(), "dark") and has(gitgud.themes(), "light")
            and #gitgud.themes() == 2)
        local answer, isError = customize.handle({ tool = "bragi_ui_paths" })
        check("bragi_ui_paths gives both folders", not isError and answer:find(o.shipped, 1, true) ~= nil
            and answer:find(o.root, 1, true) ~= nil and answer:find("Customized now: none.", 1, true) ~= nil)
        check("and needs no permission card", uitools.noCard("mcp__repo__bragi_ui_paths", "bragi-main"))

        -- A working change, a broken one, and a theme of your own.
        local root = gitgud.currentUi().root
        local rows = read(root .. "/scripts/bragi/rows.lua")
        gitgud.configWrite("bragi/ui/scripts/bragi/rows.lua",
            (rows:gsub("return rows%s*$", "rows.customized = true\n\nreturn rows\n")))
        gitgud.configWrite("bragi/ui/scripts/bragi/wikitool.lua", "this isn't Lua (\n")
        gitgud.configWrite("bragi/ui/layouts/main.xml", "<GUILayout version=\"4\"><Window broken\n")
        local dark = read(root .. "/themes/dark.ini")
        gitgud.configWrite("bragi/ui/themes/darkblue.ini", (dark:gsub("FF1B2A27", "FF14233F")))
        gitgud.configWrite(PHASE_FILE, "reloaded")
        gitgud.emit("app.reload", "")
    end)
elseif phase == "reloaded" then
    step(2000, "after the reload", function()
        local o = gitgud.uiOverlay()
        check("four files customized", #o.files == 4 and has(o.files, "scripts/bragi/rows.lua")
            and has(o.files, "themes/darkblue.ini") and has(o.files, "layouts/main.xml"))
        check("the working one is used", require("bragi.rows").customized == true)
        local broken = {}
        for _, e in ipairs(o.errors) do
            broken[slashes(e.file):match("[^/]+/[^/]+$") or ""] = e.error ~= ""
        end
        check("the broken script is named with its error", broken["bragi/wikitool.lua"] == true)
        check("so is the broken layout", broken["layouts/main.xml"] == true)
        check("and the shipped layout came up", gitgud.getRect("BragiRailAgent") ~= nil)
        local wiki = false
        for _, d in ipairs(uitools.definitions()) do
            wiki = wiki or d.name == "bragi_wiki_search"
        end
        check("and the shipped one took its place", wiki)
        check("the theme of your own is offered", has(gitgud.themes(), "darkblue"))
        check("prompts come through the customizations too",
            slashes(gitgud.uiFile("prompts/master.md")) == slashes(gitgud.currentUi().root) .. "/prompts/master.md")
        bragiSettings.open("git")
    end)
    step(800, "Settings lists them", function()
        local titles = {}
        for r = 1, 6 do
            titles[#titles + 1] = gitgud.getText(bragiSettings.widget(3, r, "Title")) or ""
        end
        check("the card", titles[1] == "Interface customizations"
            and (gitgud.getText(bragiSettings.widget(3, 1, "Sub")) or ""):find("4 files", 1, true) ~= nil)
        check("the files that didn't load", has(titles, "Not used: scripts/bragi/wikitool.lua")
            and has(titles, "Not used: layouts/main.xml"))
        check("Open and Reset all", titles[4] == "Open the customizations folder" and titles[5] == "Reset all")
        bragiSettings.open("appearance")
    end)
    step(800, "the theme among Light and Dark", function()
        local name = bragiSettings.widget(1, 1, "Themedarkblue")
        check("its swatch shows", gitgud.getRect(name) ~= nil)
        gitgud.configWrite(PHASE_FILE, "themed")
        gitgud.setTheme("darkblue")
    end)
elseif phase == "themed" then
    step(2000, "in your theme", function()
        check("it's the theme", gitgud.theme() == "darkblue")
        check("its colours apply", require("core.palette").bg == "FF14233F")
        gitgud.configWrite(PHASE_FILE, "reset")
        -- A call on its own line: the harness never tries it early.
        resetAll()
    end)
elseif phase == "reset" then
    step(2000, "back to the shipped interface", function()
        local o = gitgud.uiOverlay()
        check("nothing customized", #o.files == 0 and #o.errors == 0)
        check("Reset all moved the folder aside", (gitgud.configRead("bragi-customize-test-backup") or "") ~= "")
        check("the backup is kept", gitgud.pathExists(gitgud.configRead("bragi-customize-test-backup") or "")
            and gitgud.pathExists((gitgud.configRead("bragi-customize-test-backup") or "")
                .. "/scripts/bragi/rows.lua"))
        check("the shipped module again", require("bragi.rows").customized == nil)
        check("your theme is gone, a shipped one is used", not has(gitgud.themes(), "darkblue")
            and gitgud.theme() ~= "darkblue")
        gitgud.configWrite(PHASE_FILE, "done")
    end)
    step(300, "done", function()
        gitgud.emit("window.close", "")
    end)
end

harness.run()
