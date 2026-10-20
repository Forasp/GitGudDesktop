--- tests/ui/bragi-usage.lua: the usage circle by the prompt box
-- (bragi/usage.lua). Hidden while nothing is known; the fake claude's
-- "limits" turn (a rate_limit_event like Claude Code's) brings the
-- five-hour and weekly rings without a context one; the "panel" turn adds
-- the context ring; a click opens the numbers; a limit near full turns
-- its ring red; the limits outlast the theme switch, in the dark theme and
-- then the light one. get_usage is asked rarely: after a
-- turn, not again for a while (nor for longer after it was refused), its
-- answer kept per account and shown between asks.
--
-- Run it like bragi-sidepanel.lua: GITGUD_UI=bragi, a scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE set to the fake claude, and
-- CLAUDE_CONFIG_DIR set to a scratch folder. The theme switch rebuilds the
-- UI and runs this script again, so it keeps its phase in a config file.
-- Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local PHASE_FILE = "bragi-usage-test-phase"

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local function phase()
    return (gitgud.configRead(PHASE_FILE) or ""):match("%S+") or "dark"
end
if phase() == "done" then
    return
end

local C = require("core.palette")
local agent = require("bragi.agent")
local settings = require("core.settings")
local shell = require("bragi.shell")
local usage = require("bragi.usage")
local theme = phase()

settings.set("bragi.claudeProgram", fake)

-- The get_usage requests made while this phase runs.
local asks = 0
local realControl = gitgud.agentControl
gitgud.agentControl = function(name, subtype, fields)
    if subtype == "get_usage" then
        asks = asks + 1
    end
    return realControl(name, subtype, fields)
end

local function shot(name)
    gitgud.screenshot(OUT .. "/" .. theme .. "-usage-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function has(s, part)
    return (s or ""):find(part, 1, true) ~= nil
end
local function snap()
    return usage.snapshot()
end
local function near(a, b)
    return a ~= nil and math.abs(a - b) < 0.001
end
--- The popup's row titled `title`, or nil.
local function row(title)
    for _, r in ipairs(snap().rows or {}) do
        if r.title == title then
            return r
        end
    end
    return nil
end

if theme == "dark" then
    step(1500, "the Agent view", function()
        check(theme .. ": theme in use", gitgud.theme() == theme)
        shell.show("agent")
        settings.set("bragi.panel", false)
    end)

    step(400, "nothing known yet", function()
        check("the circle hides", snap().visible == false and not visible("AgentUsage"))
        say("limits 42 17")
    end)

    step(3000, "the limits, without a context", function()
        local s = snap()
        check("the turn ended", not agent.session().turn)
        check("the circle shows", s.visible and visible("AgentUsage"))
        check("five-hour ring at 42%", near(s.rings.five_hour, 0.42))
        check("weekly ring at 17%", near(s.rings.seven_day, 0.17))
        check("no context ring: no window named", s.rings.context == nil and not visible("AgentUsageTrack1"))
        check("the limit rings drawn", visible("AgentUsageTrack2") and visible("AgentUsageArc2")
            and gitgud.getProperty("AgentUsageArc2", "IconImage") == "Bragi-Usage/Arc2-21")
        check("the tooltip has them", has(s.tooltip, "Five-hour limit: 42%") and has(s.tooltip, "Weekly limit: 17%"))
        local cx, _, cw = gitgud.getRect("AgentUsage")
        local mx = gitgud.getRect("AgentModeButton")
        local vx, _, vw = gitgud.getRect("AgentVoiceState")
        check("left of the mode button", cx + cw <= mx)
        check("right of the status line", vx + vw <= cx)
        clickWidget("AgentUsage")
    end)

    step(500, "the numbers, without a context", function()
        local s = snap()
        check("the popup opens", s.open and visible("BragiUsagePopup"))
        check("no context row", row("Context") == nil)
        check("five-hour row", row("Five-hour limit") and row("Five-hour limit").value == "42%"
            and has(row("Five-hour limit").detail, "Resets in 2 h 1"))
        check("weekly row", row("Weekly limit") and row("Weekly limit").value == "17%"
            and has(row("Weekly limit").detail, "Resets "))
        check("says why there's no context", has(s.note, "Context shows"))
        shot("01-limits")
    end)

    step(300, "close it", function()
        gitgud.emit("key", "escape")
    end)

    step(400, "closed", function()
        check("Escape closes it", not snap().open and not visible("BragiUsagePopup"))
        say("panel")
    end)

    step(4000, "the context too", function()
        local s = snap()
        check("the turn ended", not agent.session().turn)
        check("context ring at 45,000 of 200,000", near(s.rings.context, 0.225))
        check("its ring drawn", visible("AgentUsageTrack1")
            and gitgud.getProperty("AgentUsageArc1", "IconImage") == "Bragi-Usage/Arc1-11")
        check("the limits stay", near(s.rings.five_hour, 0.42) and near(s.rings.seven_day, 0.17))
        shot("02-circle")
        clickWidget("AgentUsage")
    end)

    step(500, "all three numbers", function()
        local s = snap()
        check("open", s.open)
        check("context row", row("Context") and row("Context").value == "23%"
            and row("Context").detail == "45,000 of 200,000 tokens")
        check("in ring order", s.rows[1].title == "Context" and s.rows[2].title == "Five-hour limit"
            and s.rows[3].title == "Weekly limit")
        check("no note when all are known", s.note == nil and not visible("BragiUsagePopupNote"))
        local px, py, pw, ph = gitgud.getRect("BragiUsagePopup")
        local cx, cy, cw = gitgud.getRect("AgentUsage")
        check("above the circle", py + ph <= cy and math.abs((px + pw) - (cx + cw)) <= 1)
        shot("03-numbers")
    end)

    step(300, "close it, and near the five-hour limit", function()
        gitgud.emit("key", "escape")
        say("limits 95 -")
    end)

    step(3000, "near the five-hour limit", function()
        local s = snap()
        check("the five-hour ring moved", near(s.rings.five_hour, 0.95))
        check("the weekly one kept", near(s.rings.seven_day, 0.17))
        check("red when near full", s.colours.five_hour == C.err)
        shot("04-high")
    end)

    step(300, "switch to the light theme", function()
        gitgud.configWrite(PHASE_FILE, "light")
        clickWidget("BragiThemeToggle")
    end)
else
    step(1500, "the light theme", function()
        check(theme .. ": theme in use", gitgud.theme() == theme)
        shell.show("agent")
    end)

    step(800, "the limits outlast the rebuild", function()
        local s = snap()
        check("the circle shows", s.visible and visible("AgentUsage"))
        check("five-hour kept", near(s.rings.five_hour, 0.95))
        check("weekly kept", near(s.rings.seven_day, 0.17))
        check("kept on disk", has(gitgud.configRead("bragi-limits.json"), "five_hour"))
        agent.newSession()
    end)

    step(600, "a new conversation", function()
        local s = snap()
        check("no context for it yet", s.rings.context == nil)
        check("the limits still show", near(s.rings.five_hour, 0.95))
        say("limits 42 17")
    end)

    step(3000, "back down", function()
        check("the turn ended", not agent.session().turn)
        check("five-hour at 42% again", near(snap().rings.five_hour, 0.42))
        say("panel")
    end)

    step(4000, "the context again", function()
        check("the turn ended", not agent.session().turn)
        check("context ring", near(snap().rings.context, 0.225))
        clickWidget("AgentUsage")
    end)

    step(500, "light screenshots", function()
        check("open", snap().open and #snap().rows == 3)
        shot("01-numbers")
    end)

    step(300, "click away", function()
        local x, y = gitgud.getRect("AgentTranscript")
        gitgud.simulateClick(x + 40, y + 40, "left")
    end)

    step(300, "the circle alone", function()
        check("a click elsewhere closes it", not snap().open and not visible("BragiUsagePopup"))
        shot("02-circle")
    end)

    step(300, "get_usage is asked rarely", function()
        local kept = gitgud.jsonDecode(gitgud.configRead("bragi-limits.json") or "") or {}
        local mine = type(kept.accounts) == "table" and kept.accounts["-"] or nil
        check("asked once, in the first turn, and refused (no usage here)", mine ~= nil
            and tonumber(mine.asked) ~= nil and tonumber(mine.failed) ~= nil)
        check("not asked again since: refused not long ago", asks == 0)
        local f = assert(io.open(os.getenv("CLAUDE_CONFIG_DIR") .. "/fake-usage.json", "wb"))
        f:write(gitgud.jsonEncode({ subscription_type = "max", rate_limits_available = true, rate_limits = {
            five_hour = { utilization = 63, resets_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 3 * 3600 + 120) },
            seven_day = { utilization = 30, resets_at = os.date("!%Y-%m-%dT%H:%M:%S.000+00:00", os.time() + 86400 * 3) },
        } }))
        f:close()
        -- Two hours on: due again.
        usage.clock = function()
            return os.time() + 2 * 3600
        end
        say("hello again")
    end)

    step(3000, "asked after the turn", function()
        check("the turn ended", not agent.session().turn)
        check("asked once", asks == 1)
        local s = snap()
        check("five-hour from get_usage: 63%", near(s.rings.five_hour, 0.63))
        check("weekly from get_usage: 30%", near(s.rings.seven_day, 0.30))
        clickWidget("AgentUsage")
    end)

    step(500, "its reset times", function()
        check("five-hour resets in 3 h", row("Five-hour limit") ~= nil
            and has(row("Five-hour limit").detail, "Resets in 3 h"))
        local kept = gitgud.jsonDecode(gitgud.configRead("bragi-limits.json") or "") or {}
        local mine = type(kept.accounts) == "table" and kept.accounts["-"] or {}
        check("kept for the account", type(mine.five_hour) == "table" and near(mine.five_hour.utilization, 0.63)
            and mine.failed == nil)
        gitgud.emit("key", "escape")
        say("and once more")
    end)

    step(3000, "not asked again so soon", function()
        check("the turn ended", not agent.session().turn)
        check("still asked once", asks == 1)
        check("the kept numbers show", near(snap().rings.five_hour, 0.63))
    end)

    step(300, "done", function()
        gitgud.configWrite(PHASE_FILE, "done")
        print("[ui-test] finished")
        gitgud.emit("window.close", "")
    end)
end

harness.run({ prefix = function()
    return theme
end })
