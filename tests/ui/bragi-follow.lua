--- tests/ui/bragi-follow.lua: the shown conversation follows its end only
-- while you're at it (scrolled up to read a question
-- card's options, the view snapped back down every second or two, as
-- another conversation worked in the background). Scrolled up, it stays
-- put; something new in it shows "Jump to latest"; your own message or
-- answer goes to the end. And it keeps to the end until you scroll up
-- (without a scroll, it stopped following as Bragi
-- spoke): not when the waiting row goes as the answer's first line comes,
-- rows are taken away, or the prompt box grows; scrolled up while lines
-- stream in, it stays up.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake then
    check("needs GITGUD_UI=bragi and GITGUD_TEST_CLAUDE", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local JUMP = "AgentJumpLatest"

-- A picture to attach, next to the test's repository.
local here = require("core.repo").state().path:gsub("[/\\]+$", "")
local PICTURE = here:gsub("[/\\][^/\\]+$", "") .. "/follow.png"
do
    local out = assert(io.open(PICTURE, "wb"))
    out:write(require("bragi.store").unbase64("iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAAcklEQVR4nBXKMREAIQwAwUihRAYSIgEZKZESKZQnAyf381tvROAIXIE78AR24A18gRE"
        .. "Tx8Q1cU88E3vinfjmHxJH4krciSexE2/iyz8UjsJVuAtPYRfewld/aByNq3E3nsZuvI2v/wAOcIEbPGCDF3zgB98SfRE4KRJlAAAAAElFTkSuQmCC"))
    out:close()
end

local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function scroll()
    return gitgud.getScroll("AgentTranscript")
end
local function jumpShown()
    return gitgud.getProperty(JUMP, "Visible") == "true"
end
local function inView(name)
    local _, ty, _, th = gitgud.getRect("AgentTranscript")
    local _, y, _, h = gitgud.getRect(name)
    return ty ~= nil and y ~= nil and h > 0 and y >= ty - 1 and y + h <= ty + th + 1
end
local function lastItem()
    local items = agent.items()
    return items[#items]
end
local function last(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end

local shown, background, card = nil, nil, nil

step(1500, "a long conversation, at its end", function()
    shell.show("agent")
    for i = 1, 40 do
        agent.addMessage("note", "Line " .. i .. " of a long conversation, long enough to need scrolling.")
    end
end)

step(400, "a question", function()
    check("it followed its end", inView(lastItem().name))
    check("no Jump at the end", not jumpShown())
    shown = agent.current()
    say("choose")
end)

step(1500, "the card, in view", function()
    card = last("question")
    check("a question card waits", card ~= nil and card.answer == nil)
    check("the card came into view (you were at the end)", card ~= nil and inView(card.name))
    gitgud.setScroll("AgentTranscript", 0)
    background = agent.openTab({ title = "Busy elsewhere" })
    agent.sendTo(background, "work")
end)

step(8000, "scrolled up while another conversation works", function()
    check("still the question's conversation shown", agent.current() == shown)
    check("the other one worked", not background.session.turn)
    check("the view stayed where you scrolled", scroll() < 1)
    check("nothing new here: no Jump", not jumpShown())
    agent.addMessage("note", "Something new in this conversation.")
end, { full = true })

step(400, "something new here while scrolled up", function()
    check("the view still stays", scroll() < 1)
    check("Jump to latest shows", jumpShown())
    check("Jump sits over the prompt box's top", (function()
        local _, jy, _, jh = gitgud.getRect(JUMP)
        local _, ty, _, th = gitgud.getRect("AgentTranscript")
        return jy ~= nil and jy + jh <= ty + th and jy > ty + th - 80
    end)())
    clickWidget(JUMP)
end)

step(400, "Jump clicked", function()
    check("at the end", inView(lastItem().name))
    check("Jump went", not jumpShown())
    gitgud.setScroll("AgentTranscript", 0)
    agent.addMessage("note", "Another new line.")
end)

step(400, "scrolling down yourself", function()
    check("Jump shows again", jumpShown())
    gitgud.setScroll("AgentTranscript", 1e9)
end)

step(600, "at the end by scrolling", function()
    check("Jump goes once you're at the end", not jumpShown())
    gitgud.setScroll("AgentTranscript", 0)
    agent.answerQuestion(card, { labels = { "Blue" } })
end)

step(1500, "your answer", function()
    check("Claude got it", last("assistant") ~= nil and last("assistant").text == "You chose: Blue")
    check("answering went to the end, and the reply followed", inView(lastItem().name))
    check("no Jump", not jumpShown())
    say("work")
end)

step(8000, "a turn at the end streams in view", function()
    check("the turn ended", not agent.session().turn)
    check("its steps and reply followed the end", inView(lastItem().name))
    gitgud.setScroll("AgentTranscript", 0)
    say("hello")
end, { full = true })

step(1500, "your message from scrolled up", function()
    check("sending went to the end", inView(lastItem().name))
    check("no Jump after your own message", not jumpShown())
    gitgud.setScroll("AgentTranscript", 0)
    agent.showTab(background)
end)

step(600, "opening a conversation", function()
    check("it opens on its latest exchange", inView(lastItem().name))
    check("no Jump on opening", not jumpShown())
    for i = 1, 40 do
        agent.addMessage("note", "Line " .. i .. " of this one too, long enough to need scrolling.")
    end
end)

local pending, streamer, mark = nil, nil, 0
-- Calls, not assignments: the harness tries a step's assignments before
-- it runs.
local function speak()
    pending = agent.voicePending("a spoken question", "Thinking")
end
local function stream()
    streamer = gitgud.every(60, function()
        agent.addMessage("note", "A streamed line.")
    end)
end

step(600, "a long conversation again", function()
    check("it followed its end", inView(lastItem().name))
    speak()
end)

-- Well after the message: the waiting row goes as the first line comes.
step(2500, "the answer's first line, a while later", function()
    check("the waiting row waits, in view", lastItem().kind == "waiting" and inView(lastItem().name))
    gitgud.emit("agent.text", gitgud.jsonEncode({ session = agent.session().name, text = "First words." }))
end, { full = true })

step(400, "the first line", function()
    check("it came into view", lastItem().kind == "assistant" and inView(lastItem().name))
    check("no Jump for it", not jumpShown())
    agent.dropPending(pending)
    agent.addMessage("note", "News after rows went.")
end, { full = true })

step(400, "rows taken away", function()
    check("the end stays in view", inView(lastItem().name))
    check("no Jump", not jumpShown())
    agent.attach(PICTURE)
end, { full = true })

step(400, "the prompt box grew", function()
    check("a picture waits to go", #agent.attachments() == 1)
    check("the end stays in view as the view got shorter", inView(lastItem().name))
    agent.addMessage("note", "News after the prompt box grew.")
end, { full = true })

step(400, "news", function()
    check("it came into view", inView(lastItem().name))
    check("no Jump", not jumpShown())
    stream()
end, { full = true })

step(500, "lines streaming in", function()
    gitgud.setScroll("AgentTranscript", 0)
end, { full = true })

step(500, "scrolled up as they stream", function()
    gitgud.cancelTimer(streamer)
    check("the view stays up", scroll() < 1)
    check("Jump shows", jumpShown())
    clickWidget(JUMP)
end, { full = true })

step(400, "back at the end", function()
    check("at the end", inView(lastItem().name))
    check("no Jump", not jumpShown())
    mark = scroll() - 30
    gitgud.setScroll("AgentTranscript", mark)
    agent.addMessage("note", "News after a small scroll up.")
end, { full = true })

step(400, "a small scroll up", function()
    check("the view stays where you put it", math.abs(scroll() - mark) < 1)
    check("Jump shows", jumpShown())
    gitgud.emit("window.close", "")
end)

harness.run()
