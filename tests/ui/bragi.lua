--- tests/ui/bragi.lua: the Bragi UI (design D): the rail and its five
-- views, the prompt box, the Repository view's top bar, Settings, and the
-- light / dark switch.
--
-- Run it in a repository made by make-testrepo.ps1 with GITGUD_UI=bragi, a
-- scratch APPDATA, GITGUD_SCRIPT pointing here, and GITGUD_SHOTS for the
-- screenshots. The theme switch rebuilds the UI and runs this script again,
-- so it keeps its phase in a config file. Prints "[check] ..." lines.

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "bragi-test-phase"

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end

local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end

local function phase()
    return (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "dark"
end

if gitgud.currentUi().id ~= "bragi" then
    print("[ui-test] needs GITGUD_UI=bragi")
    return
end

local shell = require("bragi.shell")
local text = require("core.text")
local theme = phase()
local canvas = nil -- the last "window.canvas" colour

-- Sending starts a session: never the real Claude Code.
require("core.settings").set("bragi.claudeProgram", os.getenv("GITGUD_TEST_CLAUDE") or "gitgud-test-no-claude")
local function shot(name)
    gitgud.screenshot(OUT .. "/" .. theme .. "-" .. name .. ".png")
end

-- Every phase: walk the views in the current theme.
step(1500, "starts in the Agent view", function()
    check(theme .. ": theme in use", gitgud.theme() == theme)
    check("Agent view shows", visible("AgentView"))
    check("other views hidden", not visible("RepoView") and not visible("BoardsView") and not visible("SettingsView"))
    check("empty state shows", visible("AgentEmpty"))
    check("theme token resolves", gitgud.themeColour("accent") ~= nil)
    gitgud.on("window.canvas", function(colour)
        canvas = colour
    end)
    shell.paintCanvas() -- events arrive on the next drain: checked in the next step
    check("rail item for Agent is active",
        (gitgud.getProperty("BragiRailAgent", "NormalFillColour") or ""):upper():find(gitgud.themeColour("sel"), 1, true) ~= nil)
    shot("01-agent")
end)

step(300, "type", function()
    check(theme .. ": the window's canvas is the theme's background", canvas ~= nil
        and canvas:upper() == (gitgud.themeColour("bg") or ""):upper())
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("Find out why the parser test is flaky, and keep it short")
end)

step(300, "Send is the primary action once there's text", function()
    check("send filled with the accent",
        (gitgud.getProperty("AgentSendButton", "NormalFillColour") or ""):upper():find(gitgud.themeColour("accent"), 1, true) ~= nil)
    clickWidget("AgentSendButton")
end)

step(400, "the message is in the conversation", function()
    check("user bubble created", gitgud.getRect("AgentMessage1") ~= nil)
    check("empty state hidden", not visible("AgentEmpty"))
    check("prompt cleared", gitgud.getText("AgentPromptEdit") == "")
    local _, _, w = gitgud.getRect("AgentMessage1")
    local _, _, column = gitgud.getRect("AgentComposer")
    check("bubble sized to its text", w and column and w < column * 0.8)
    shot("02-agent-sent")
end)

step(300, "Shift+Enter breaks the line", function()
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("first line")
    gitgud.simulateKey("shift+enter")
    gitgud.simulateText("second line")
    check("Shift+Enter added a line break",
        (gitgud.getText("AgentPromptEdit") or ""):find("first line\nsecond line", 1, true) ~= nil)
    check("Shift+Enter didn't send", gitgud.getRect("AgentMessage3") == nil)
end)

step(300, "Enter sends", function()
    gitgud.simulateKey("enter")
end)

step(400, "the two-line message is in the conversation", function()
    check("Enter sent the message", gitgud.getRect("AgentMessage3") ~= nil)
    check("prompt cleared after Enter", text.trim(gitgud.getText("AgentPromptEdit") or "") == "")
    check("message kept its line break",
        (gitgud.getText("AgentMessage3Text") or ""):find("first line\nsecond line", 1, true) ~= nil)
end)

step(300, "Repository view", function()
    clickWidget("BragiRailRepo")
end)

step(800, "the Repository view's top bar", function()
    check("Repository view shows", visible("RepoView"))
    check("sidebar's own tabs hidden", not visible("ChangesTab"))
    check("branch tree hidden by default", not require("views.frame").navigatorVisible())
    check("fetch line joined", (gitgud.getText("SyncLabel") or ""):find(" · ", 1, true) ~= nil)
    shot("03-repo-changes")
end)

step(300, "History", function()
    clickWidget("BragiHistoryTab")
end)

step(600, "History shows", function()
    check("History selected", require("views.sidebar").tab() == "history")
    shot("04-repo-history")
end)

step(300, "branch tree", function()
    clickWidget("BragiBranchesButton")
end)

step(600, "branch tree shows", function()
    check("branch tree shows", require("views.frame").navigatorVisible())
    shot("05-repo-branches")
end)

step(300, "back to Changes, tree hidden", function()
    clickWidget("BragiBranchesButton")
    clickWidget("BragiChangesTab")
end)

local VIEW_SHOTS = {
    { rail = "BragiRailBoards", view = "BoardsView", shot = "06-boards" },
    { rail = "BragiRailWiki", view = "WikiView", shot = "07-wiki" },
    { rail = "BragiRailSettings", view = "SettingsView", shot = "08-settings" },
}
for _, v in ipairs(VIEW_SHOTS) do
    step(300, v.view, function()
        clickWidget(v.rail)
    end)
    step(600, v.view .. " shows", function()
        check(v.view .. " shows", visible(v.view))
        shot(v.shot)
    end)
end

for i, section in ipairs({ "claude", "git", "projects", "shortcuts" }) do
    step(300, "Settings: " .. section, function()
        clickWidget("SettingsNav_" .. section)
    end)
    step(500, "Settings: " .. section .. " shows", function()
        shot(string.format("%02d-settings-%s", 8 + i, section))
    end)
end

step(300, "command palette from the search field", function()
    clickWidget("SettingsNav_appearance")
    shell.show("agent")
end)

step(300, "open the palette", function()
    clickWidget("AgentSearch")
end)

step(400, "palette open", function()
    check("palette opened", visible("PalettePopup"))
    shot("13-palette")
end)

step(300, "close the palette", function()
    gitgud.emit("key", "escape")
end)

if theme == "dark" then
    step(400, "switch to the light theme", function()
        gitgud.configWrite(PHASE_FILE, "light")
        clickWidget("BragiThemeToggle")
    end)
else
    step(400, "done", function()
        gitgud.configWrite(PHASE_FILE, "done")
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
    end)
end

if phase() ~= "done" then
    harness.run({ prefix = phase })
end
