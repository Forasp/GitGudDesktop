--- tests/ui/bragi-shown.lua: a conversation filled in the background (the
-- master sending work to it, its notes) shows its latest exchange when it's
-- opened, whichever was shown before (one opened from
-- the list looked empty until scrolled up).
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

if gitgud.currentUi().id ~= "bragi" then
    check("needs GITGUD_UI=bragi", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local shell = require("bragi.shell")

local phase = ""

-- Whether a widget is inside the transcript's visible area.
local function inView(name)
    local _, ty, _, th = gitgud.getRect("AgentTranscript")
    local _, y, _, h = gitgud.getRect(name)
    return ty ~= nil and y ~= nil and h > 0 and y >= ty - 1 and y + h <= ty + th + 1
end

local function tabTitled(title)
    for _, tab in ipairs(agent.tabs()) do
        if tab.title == title then
            return tab
        end
    end
    return nil
end

-- Scrolled to the end, the last item is at the bottom of the transcript,
-- with no empty space below it (the pane is as tall as what it shows); a
-- conversation shorter than the view starts at its top.
local function endsAtBottom()
    local items = agent.items()
    local first, last = items[1], items[#items]
    local _, ty, _, th = gitgud.getRect("AgentTranscript")
    local _, y, _, h = gitgud.getRect(last.name)
    local _, fy = gitgud.getRect(first.name)
    if not (ty and y and fy) or y + h > ty + th + 1 then
        return false
    end
    return y + h >= ty + th - 80 or fy <= ty + 40
end

local function lastItem()
    local items = agent.items()
    return items[#items]
end

if phase == "" then
    local background = nil
    step(1500, "a long conversation, at its end", function()
        shell.show("agent")
        for i = 1, 60 do
            agent.addMessage("note", "Line " .. i .. " of a long conversation, long enough to need scrolling.")
        end
    end)
    step(300, "the background conversation is filled", function()
        check("the long one ends in view", lastItem() ~= nil and inView(lastItem().name))
        background = agent.openTab({ title = "Investigating the loot tables" })
        agent.noteIn(background, "At one point we were investigating the loot tables.")
        -- Sent there by the master: Claude Code answers while it isn't shown.
        agent.sendTo(background, "Where do the drop rates come from?")
    end)
    step(4000, "answered in the background", function()
        check("still the long one shown", agent.current() ~= background)
        check("an answer came", not background.session.turn)
        agent.showTab(background)
    end)
    step(300, "its latest exchange is in view", function()
        local items = agent.items()
        check("it has its items", #items >= 3)
        check("the latest is in view", inView(items[#items].name))
    end)

    -- The other way round: from a short conversation to a long one filled
    -- in the background.
    local long = nil
    step(300, "a long conversation in the background", function()
        long = agent.openTab({ title = "Long background work" })
        for i = 1, 40 do
            agent.noteIn(long, "Background line " .. i .. ", long enough to need scrolling in the end.")
        end
        agent.showTab(long)
    end)
    step(300, "it opens on its latest line", function()
        local items = agent.items()
        check("all there", #items == 40)
        check("the latest is in view", inView(items[#items].name))
        check("the first is above it, out of view", not inView(items[1].name))
    end)
    -- The master conversation stays (hidden) while another is shown
    -- (every other conversation opened on empty space; at the
    -- true bottom the last row sat mid-screen with space below it).
    local short, long2 = nil, nil
    step(300, "a long master conversation", function()
        require("bragi.master").open()
        for i = 1, 80 do
            agent.addMessage("note", "Master line " .. i .. ", long enough to need a lot of scrolling here.")
        end
    end)
    step(300, "then a short conversation", function()
        check("the master ends at the bottom", endsAtBottom())
        agent.newSession()
        short = agent.current()
        for i = 1, 6 do
            agent.addMessage("note", "Short line " .. i)
        end
    end)
    step(300, "it shows from its top, no space above", function()
        check("the short one shows whole", endsAtBottom())
        check("and its first is in view", inView(agent.items()[1].name))
        require("bragi.master").open()
    end)
    step(300, "back to the master", function()
        check("the master ends at the bottom again", endsAtBottom())
        agent.newSession()
        long2 = agent.current()
        for i = 1, 30 do
            agent.addMessage("note", "Another conversation, line " .. i .. ", long enough to scroll.")
        end
    end)
    step(300, "a longer one, but shorter than the master", function()
        check("its last line is at the bottom", endsAtBottom())
        check("and in view", inView(agent.items()[#agent.items()].name))
    end)
    step(300, "done", function()
        gitgud.emit("window.close", "")
    end)
end

harness.run()
