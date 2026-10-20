--- tests/ui/bragi-routines.lua: Settings, Routines (G5): a routine run now,
-- its status and summary, a permission request denied and noted, a due
-- routine run by the timer, one that's off left alone, its prompt edited,
-- and everything kept in routines.json. Against the fake claude.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local bragiSettings = require("bragi.settings")
local repo = require("core.repo")
local routines = require("bragi.routines")
local settings = require("core.settings")

settings.set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/routines-" .. name .. ".png")
end
local function textOf(card, row, part)
    return gitgud.getText(bragiSettings.widget(card, row, part)) or ""
end
local function clickName(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function get(id)
    for _, r in ipairs(routines.list()) do
        if r.id == id then
            return r
        end
    end
end

local morning, asking, off

step(1500, "make routines", function()
    local folder = repo.state().path
    morning = routines.add({ name = "Morning", folder = folder, every = 60, prompt = "hello" }).id
    asking = routines.add({ name = "Asks first", folder = folder, every = 60, prompt = "tool" }).id
    off = routines.add({ name = "Off", folder = folder, every = 1, prompt = "hello", enabled = false }).id
    bragiSettings.open("routines")
end)

step(400, "the section", function()
    check("a card per routine", textOf(1, 1, "Title") == "Not run yet" and textOf(3, 2, "Sub"):find("Off", 1, true) ~= nil)
    check("the prompt shows", textOf(1, 3, "Sub") == "hello")
    check("the schedule shows", textOf(1, 2, "Sub"):find("Every 60 min in repo", 1, true) ~= nil)
    check("a new one can be made", textOf(4, 1, "Action") == "New")
    shot("01-section")
    clickName(bragiSettings.widget(1, 1, "Action"))
end)

step(2000, "run now", function()
    local r = get(morning)
    check("it ran", r.lastRun ~= nil and r.lastStatus == "ok")
    check("its answer is kept", r.lastSummary == "Hello")
    check("the card says so", textOf(1, 1, "Title"):find("Last run done", 1, true) ~= nil
        and textOf(1, 1, "Sub") == "Hello")
    check("no runs left going", not routines.running(morning))
    routines.runNow(asking)
end)

step(2500, "a permission request", function()
    local r = get(asking)
    check("denied and noted", r.lastStatus == "asked" and (r.lastSummary or ""):find("Bash", 1, true) ~= nil)
    shot("02-ran")
    -- Due: the timer runs it; the one that's off stays off.
    routines.update(morning, { nextRun = os.time() - 5 })
    routines.update(off, { nextRun = os.time() - 5 })
    get(morning).lastRun = 0
    routines.tick()
    check("the due one is running", routines.running(morning))
    check("the off one isn't", not routines.running(off))
end)

step(2000, "the due run", function()
    local r = get(morning)
    check("it ran again", r.lastRun > 0 and r.lastStatus == "ok")
    check("next run an hour on", r.nextRun - r.lastRun == 3600)
    check("the off one never ran", get(off).lastRun == nil)
    routines.editPrompt(morning)
end)

step(300, "edit the prompt", function()
    check("the editor has the prompt", gitgud.getText(bragiSettings.editor("")) == "hello")
    gitgud.setText(bragiSettings.editor(""), "Check the build on main.\n")
    clickName(bragiSettings.editor("Save"))
end)

step(300, "prompt saved", function()
    check("the prompt changed", get(morning).prompt == "Check the build on main.")
    check("the card shows it", textOf(1, 3, "Sub") == "Check the build on main.")
    local stored = gitgud.configRead("bragi/routines.json") or ""
    check("kept in routines.json", stored:find("Check the build on main.", 1, true) ~= nil
        and stored:find("Asks first", 1, true) ~= nil)
    routines.remove(off)
end)

step(300, "removed", function()
    check("two left", #routines.list() == 2)
    shot("03-after")
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
