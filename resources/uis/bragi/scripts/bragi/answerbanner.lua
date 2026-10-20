--- bragi/answerbanner.lua: a spoken answer that went to another
-- conversation. When Bragi asks something aloud from a
-- conversation that isn't shown (the master conversation's news, most
-- often) and you answer it in the follow-up window, the answer goes to
-- that conversation, and the one on screen gets a small banner over its
-- top: the question, your answer, and Open to go there. It stays with
-- that tab until it's closed or the conversation it went to is opened.
--
-- Public API: answerbanner.show(onTab, { target, question, answer }),
-- answerbanner.clear(tab), answerbanner.state() (for tests: { shown,
-- question, answer })

local C = require("core.palette")
local app = require("core.app")
local geometry = require("ui.geometry")
local text = require("core.text")

local answerbanner = { name = "bragi.answerbanner" }

local BANNER = "AgentAnswerBanner"
local HEIGHT = 64
local TOP = 64            -- under the header (agent.lua's HEADER, plus a gap)
local MAX_WIDTH = 732     -- the conversation column's
local SIDE = 24
local LINE_CHARS = 160    -- of the question or the answer shown
local ASKED = "Bragi asked: "
local ANSWERED = "You answered: "
local OPEN = "Open"

local shownFor = nil      -- the tab whose banner shows

local function agent()
    return require("bragi.agent")
end

--- A line cut to LINE_CHARS, on one line.
local function short(s)
    s = text.trim((tostring(s or ""):gsub("%s+", " ")))
    if #s > LINE_CHARS then
        s = s:sub(1, LINE_CHARS):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "..."
    end
    return s
end

local function create()
    if gitgud.getRect(BANNER) then
        return
    end
    local ui = require("bragi.ui")
    ui.box(BANNER, "AgentMain", { 0, 0, 10, 10 }, { radius = 12, fill = C.panel, border = C.accent })
    gitgud.setProperty(BANNER, "AlwaysOnTop", "true")
    ui.label(BANNER .. "Asked", BANNER, "{{0,16},{0,10},{1,-150},{0,30}}", "", { font = "Bragi-13", colour = C.sub })
    ui.label(BANNER .. "Answer", BANNER, "{{0,16},{0,32},{1,-150},{0,54}}", "", { font = "Bragi-14" })
    ui.button(BANNER .. "Open", BANNER, "{{1,-136},{0.5,-16},{1,-52},{0.5,16}}", OPEN, { primary = true })
    ui.button(BANNER .. "Close", BANNER, "{{1,-44},{0.5,-14},{1,-16},{0.5,14}}", "", { quiet = true,
        tooltip = "Close" })
    gitgud.createWindow("Gitgud/Icon", BANNER .. "CloseIcon", BANNER .. "Close")
    gitgud.setProperty(BANNER .. "CloseIcon", "Area", "{{0.5,-7},{0.5,-7},{0.5,7},{0.5,7}}")
    gitgud.setProperty(BANNER .. "CloseIcon", "IconImage", "Bragi-Icons/Close")
    gitgud.setProperty(BANNER .. "CloseIcon", "IconColour", C.sub)
    gitgud.setProperty(BANNER .. "CloseIcon", "GlowColour", C.transparent)
    gitgud.setProperty(BANNER .. "CloseIcon", "CursorPassThroughEnabled", "true")
    gitgud.on(BANNER .. "Open.clicked", function()
        local b = shownFor and shownFor.answerBanner
        if b and b.target then
            answerbanner.clear(shownFor)
            agent().showTab(b.target)
        end
    end)
    gitgud.on(BANNER .. "Close.clicked", function()
        if shownFor then
            answerbanner.clear(shownFor)
        end
    end)
end

--- Draw the banner of the tab shown, or hide it.
local function paint()
    local tab = agent().current()
    local b = tab and tab.answerBanner
    if not b then
        shownFor = nil
        if gitgud.getRect(BANNER) then
            gitgud.setVisible(BANNER, false)
        end
        return
    end
    create()
    shownFor = tab
    local _, _, w = gitgud.getRect("AgentMain")
    local width = math.min(MAX_WIDTH, (w or 800) - 2 * SIDE)
    gitgud.setProperty(BANNER, "Area", string.format("{{0.5,%d},{0,%d},{0.5,%d},{0,%d}}",
        -math.floor(width / 2), TOP, math.floor(width / 2), TOP + HEIGHT))
    gitgud.setText(BANNER .. "Asked", text.escape(ASKED .. short(b.question)))
    gitgud.setText(BANNER .. "Answer", text.escape(ANSWERED .. short(b.answer)))
    local where = b.target and b.target.title or ""
    gitgud.setProperty(BANNER .. "Open", "TooltipText", "Open " .. (where ~= "" and where or "the conversation"))
    gitgud.setVisible(BANNER, true)
end

--- Show the banner on a tab (the one on screen).
-- @param b  { target (the tab the answer went to), question, answer }
function answerbanner.show(onTab, b)
    if not onTab then
        return
    end
    onTab.answerBanner = { target = b.target, question = b.question or "", answer = b.answer or "" }
    if onTab == agent().current() then
        paint()
    end
end

--- Take a tab's banner away.
function answerbanner.clear(tab)
    if tab then
        tab.answerBanner = nil
    end
    paint()
end

function answerbanner.state()
    local tab = agent().current()
    local b = tab and tab.answerBanner
    return { shown = b ~= nil and gitgud.getRect(BANNER) ~= nil and gitgud.getProperty(BANNER, "Visible") == "true",
        question = b and b.question, answer = b and b.answer, target = b and b.target }
end

function answerbanner.init()
    app.subscribe("bragi.tabShown", function(tab)
        -- The conversation the answer went to, opened: every banner
        -- pointing there has done its job.
        for _, t in ipairs(agent().tabs()) do
            if t.answerBanner and t.answerBanner.target == tab then
                t.answerBanner = nil
            end
        end
        paint()
    end)
end

return answerbanner
