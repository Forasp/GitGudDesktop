--- tests/ui/bragi-rewind.lua: rewind and fork (bragi/rewind.lua). Each
-- message you sent has Rewind and Fork under it, shown while the mouse is
-- over it. Rewind takes the view
-- back to just before the message, puts its text in the prompt box, and
-- the next message resumes the session at the entry before it (the
-- transcript reads back without what was rewound). Fork opens a new
-- conversation with everything up to the message's answer; its first
-- message resumes the session as a new one, and the original is left as
-- it was, and the fork is titled like it plus " (fork)", in the saved
-- list too. Rewinding the first message starts afresh. From Bragi, the
-- master conversation, a fork goes to the project the conversation was
-- about (a copy of its transcript there), or to a conversation of no
-- project, listed as "Uncategorized".
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT,
-- GITGUD_SHOTS, GITGUD_TEST_CLAUDE, a scratch CLAUDE_CONFIG_DIR). The fake
-- claude's `fake-transcripts` file gives each session an id and a chained
-- transcript. Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
local config = os.getenv("CLAUDE_CONFIG_DIR")
if gitgud.currentUi().id ~= "bragi" or not fake or not config then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local master = require("bragi.master")
local projects = require("bragi.projects")
local repo = require("core.repo")
local rewind = require("bragi.rewind")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)
local f = assert(io.open(config .. "/fake-transcripts", "wb"))
f:write("on\n")
f:close()

local here = repo.state().path:gsub("[/\\]+$", "")

local function shot(name)
    gitgud.screenshot(OUT .. "/rewind-" .. name .. ".png")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function click(name)
    local x, y, w, h = gitgud.getRect(name)
    if x then
        gitgud.simulateClick(x + w / 2, y + h / 2)
    end
end
-- The mouse over a window (or, with nil, off to the window's top left).
local function hoverOver(name)
    local x, y, w, h = gitgud.getRect(name or "")
    if x then
        gitgud.simulateMove(x + w / 2, y + h / 2)
    else
        gitgud.simulateMove(2, 2)
    end
end
local function same(a, b)
    return projects.key(a or "") == projects.key(b or "")
end
local function users(items)
    local list = {}
    for _, item in ipairs(items or agent.items()) do
        if item.kind == "user" then
            list[#list + 1] = item
        end
    end
    return list
end
local function lastReply()
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == "assistant" then
            return items[i].text
        end
    end
    return ""
end
-- A saved conversation's messages and replies, as text.
local function said(cwd, id)
    local list = {}
    for _, h in ipairs(gitgud.agentHistory(cwd, id or "")) do
        if h.kind == "user" or h.kind == "assistant" then
            list[#list + 1] = h.text
        end
    end
    return table.concat(list, " | ")
end
local function startedWith(tab)
    local info = tab and tab.session.name and gitgud.agentInfo(tab.session.name)
    return info and info.options or {}
end

local sessionId = nil     -- the first conversation's
local original = nil      -- its tab
local forkTab = nil
local masterId = nil

step(1500, "a conversation of three messages", function()
    shell.show("agent")
    agent.newSession()
    say("first one")
end)

step(2500, "the first answered", function()
    check("answered", lastReply() == "You said: first one")
    say("second one")
end)

step(2500, "the second answered", function()
    check("answered", lastReply() == "You said: second one")
    say("third one")
end)

step(2500, "each message has Rewind and Fork", function()
    check("answered", lastReply() == "You said: third one")
    local list = users()
    check("three messages", #list == 3)
    local all = #list == 3
    for _, item in ipairs(list) do
        all = all and item.sent == true and gitgud.getRect(item.name .. "ActionsRewind") ~= nil
            and gitgud.getRect(item.name .. "ActionsFork") ~= nil
    end
    check("under each one", all)
    local bx, by, bw, bh = gitgud.getRect(list[1].name .. "Bubble")
    local rx, ry, rw = gitgud.getRect(list[1].name .. "Actions")
    check("under the bubble, right-aligned", bx ~= nil and rx ~= nil and ry >= by + bh and rx + rw == bx + bw)
    original = agent.current()
    sessionId = agent.session().id
    check("hidden until the mouse is over a message", not rewind.actionsShown(list[1])
        and not rewind.actionsShown(list[2]) and not rewind.actionsShown(list[3]))
    hoverOver(list[2].name .. "Bubble")
end)

step(300, "the mouse over the second message", function()
    local list = users()
    check("its buttons show", rewind.actionsShown(list[2]))
    check("only its own", not rewind.actionsShown(list[1]) and not rewind.actionsShown(list[3]))
    shot("01-actions")
end)

step(300, "the mouse moves off", function()
    hoverOver(nil)
end)

step(300, "the mouse off it", function()
    check("they hide again", not rewind.actionsShown(users()[2]))
    hoverOver(users()[2].name .. "Bubble")
end)

step(300, "over it again: Rewind", function()
    check("they show again", rewind.actionsShown(users()[2]))
    click(users()[2].name .. "ActionsRewind")
end)

step(1500, "rewound to before the second message", function()
    local list = users()
    check("only the first exchange is left", #list == 1 and list[1].text == "first one"
        and lastReply() == "You said: first one")
    check("its text is back in the prompt box", gitgud.getText("AgentPromptEdit") == "second one")
    local s = agent.session()
    check("the session stopped", not s.running)
    check("it resumes the same session", s.resume == sessionId)
    local entries = gitgud.agentHistory(here, sessionId)
    local second = nil
    for _, h in ipairs(entries) do
        if h.kind == "user" and h.text == "second one" then
            second = h
        end
    end
    check("at the entry before the message", second ~= nil and s.startOnce ~= nil
        and s.startOnce.resumeAt == second.parentUuid and second.parentUuid ~= "")
    shot("02-rewound")
    require("ui.placeholder").setText("AgentPromptEdit", "")
    say("second, edited")
end)

step(2500, "sent again from there", function()
    check("answered", lastReply() == "You said: second, edited")
    local options = startedWith(agent.current())
    check("Claude Code resumed it at that entry", options.resume == sessionId and (options.resumeAt or "") ~= ""
        and options.forkSession ~= true)
    check("the same session", agent.session().id == sessionId)
    check("its transcript reads back without what was rewound",
        said(here, sessionId) == "first one | You said: first one | second, edited | You said: second, edited")
    check("once: the next start won't rewind again", agent.session().startOnce == nil)
    rewind.forkFrom(users()[1])
end)

step(1500, "forked from the first message", function()
    forkTab = agent.current()
    check("a new conversation is shown", forkTab ~= original and not forkTab.master)
    local list = users()
    check("with the first exchange only", #list == 1 and list[1].text == "first one"
        and lastReply() == "You said: first one")
    check("its message can be rewound or forked too", list[1] and list[1].sent == true)
    check("in the same folder", same(forkTab.cwd, here))
    check("titled like the original, plus (fork)", forkTab.title == original.title .. " (fork)"
        and gitgud.getText("AgentTitle") == original.title .. " (fork)")
    check("it forks the session when it starts", forkTab.session.startOnce ~= nil
        and forkTab.session.startOnce.resume == sessionId and forkTab.session.startOnce.forkSession == true)
    shot("03-forked")
    say("fork hello")
end)

step(2500, "the fork goes on as a session of its own", function()
    check("answered", lastReply() == "You said: fork hello")
    local id = forkTab.session.id
    local options = startedWith(forkTab)
    check("Claude Code forked it", options.resume == sessionId and options.forkSession == true
        and (options.resumeAt or "") ~= "")
    check("a new session", id ~= nil and id ~= sessionId)
    check("with the history up to there", said(here, id)
        == "first one | You said: first one | fork hello | You said: fork hello")
    check("the original is as it was",
        said(here, sessionId) == "first one | You said: first one | second, edited | You said: second, edited")
    local saved = agent.savedSession(id)
    check("its saved conversation keeps the fork's title", projects.titleOf(id) == original.title .. " (fork)"
        and saved ~= nil and saved.title == original.title .. " (fork)")
    agent.resume(sessionId, { cwd = here })
end)

step(1500, "rewinding the first message starts afresh", function()
    check("the original is shown again", agent.session().resume == sessionId and #users() == 2)
    rewind.rewindTo(users()[1])
end)

step(1000, "afresh", function()
    check("nothing is left", #users() == 0)
    check("its text is in the prompt box", gitgud.getText("AgentPromptEdit") == "first one")
    check("a new session next", agent.session().resume == nil and agent.session().startOnce == nil)
    require("ui.placeholder").setText("AgentPromptEdit", "")
    master.open()
    say("just chatting")
end)

step(2500, "Bragi, about no project", function()
    check("answered", agent.current().master and lastReply() == "You said: just chatting")
    masterId = agent.session().id
    local list = users()
    rewind.forkFrom(list[#list])
end)

step(1500, "its fork is a conversation of no project", function()
    local tab = agent.current()
    check("shown, not the master", not tab.master and master.tab() ~= nil)
    check("in the folder of no project", same(tab.cwd, projects.loneDir()))
    check("with what was said", users()[1] and users()[1].text == "just chatting"
        and lastReply() == "You said: just chatting")
    check("a copy, resumed there", tab.session.resume ~= nil and tab.session.resume ~= masterId
        and said(projects.loneDir(), tab.session.resume) == "just chatting | You said: just chatting")
    check("titled like the master plus (fork)", tab.title == rewind.forkTitle(master.tab().title)
        and projects.titleOf(tab.session.resume) == tab.title)
    local group = nil
    for _, p in ipairs(projects.conversations(true)) do
        if same(p.cwd, projects.loneDir()) then
            group = p
        end
    end
    check("listed as Uncategorized", group ~= nil and group.name == "Uncategorized"
        and projects.name(projects.loneDir()) == "Uncategorized")
    check("never a project to work in", (function()
        for _, p in ipairs(projects.locals()) do
            if same(p.path, projects.loneDir()) then
                return false
            end
        end
        return true
    end)())
    shot("04-no-project")
    say("after the fork")
end)

step(2500, "it goes on there", function()
    local tab = agent.current()
    check("answered", lastReply() == "You said: after the fork")
    check("the copy resumed in its own folder", same(startedWith(tab).cwd, projects.loneDir())
        and tab.session.id == startedWith(tab).resume)
    check("its transcript has both", said(projects.loneDir(), tab.session.id)
        == "just chatting | You said: just chatting | after the fork | You said: after the fork")
    master.open()
    say('call bragi_start {"project":"repo","message":"hello","title":"Started from Bragi"}')
end)

step(2500, "Bragi, about a project", function()
    check("Bragi started a conversation", agent.current().master and lastReply():find("Started", 1, true) ~= nil)
    local list = users()
    rewind.forkFrom(list[#list])
end)

step(1500, "its fork is a conversation in that project", function()
    local tab = agent.current()
    check("shown, not the master", not tab.master)
    check("in the project's folder", same(tab.cwd, here))
    local history = said(here, tab.session.resume)
    check("with all Bragi's conversation up to there", history:find("just chatting", 1, true) ~= nil
        and history:find("call bragi_start", 1, true) ~= nil)
    check("the master is left as it was", master.tab() ~= nil and master.tab().session.id == masterId)
    shot("05-project")
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
