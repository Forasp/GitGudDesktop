--- tests/ui/bragi-master.lua: Bragi, the master conversation
-- (bragi/master.lua): pinned, in its own folder with its prompt, its tools
-- allowed without asking and refused to other sessions; listing projects,
-- listing and reading conversations, sending to one (resumed in the
-- background), starting one in a project, cloning a repository by its
-- address (a local bare repository stands in), opening a
-- project (by name, or a local repository by path, added to the projects;
-- a plain or missing folder refused); quiet status rows with Open for the conversations it sent to;
-- a message to one waiting on a question or a permission answering it;
-- a typed recap of them; its id remembered; restarting the app (refused
-- while others work).
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1 (with its
-- <repo>-remote.git), GITGUD_SCRIPT, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, a
-- scratch CLAUDE_CONFIG_DIR). The fake claude's "call <tool> <json>"
-- calls the tools; its `fake-transcripts` file gives each session an id
-- and a transcript. Prints "[check] ...".

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
local app = require("core.app")
local master = require("bragi.master")
local projects = require("bragi.projects")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")

-- Every saved transcript bragi/master.lua reads, with the most entries it
-- asks for: never the whole transcript (read on the UI thread, a long one
-- held it up for over a second).
local masterReads = {}
local realHistory = gitgud.agentHistory
gitgud.agentHistory = function(cwd, id, max)
    local info = debug.getinfo(2, "S")
    if info and tostring(info.source):find("bragi[/\\]master%.lua$") then
        masterReads[#masterReads + 1] = max or false
    end
    return realHistory(cwd, id, max)
end

settings.set("bragi.claudeProgram", fake)
-- Whose master conversation it is (bragi/user.lua).
settings.set("bragi.userName", "Sam")
local f = assert(io.open(config .. "/fake-transcripts", "wb"))
f:write("on\n")
f:close()

local here = repo.state().path:gsub("[/\\]+$", "")
local parent = here:gsub("[/\\][^/\\]+$", "")
local remote = here .. "-remote.git"
settings.set("bragi.projectsFolder", "")
-- Where cloned repositories go in this test (made on demand).
local projectsFolder = parent .. "/projects"
settings.set("bragi.projectsFolder", projectsFolder)
-- A local repository and a plain folder, opened by path.
local localRepo = (parent .. "/Moon Garden"):gsub("\\", "/")
local plainFolder = (parent .. "/Plain Folder"):gsub("\\", "/")
local missingFolder = (parent .. "/Nowhere Here"):gsub("\\", "/")


local SAVED = "3333cccc-0000-0000-0000-000000000003"
local function writeSaved(cwd, id, title)
    local dir = config .. "/projects/" .. cwd:gsub("[^%w]", "-")
    gitgud.makeDir(dir)
    local out = assert(io.open(dir .. "/" .. id .. ".jsonl", "wb"))
    out:write(gitgud.jsonEncode({ type = "user", cwd = cwd, message = { role = "user", content = title } }), "\n")
    out:write(gitgud.jsonEncode({ type = "assistant", cwd = cwd, message = { role = "assistant",
        content = { { type = "text", text = "Looked at the loot table." } } } }), "\n")
    out:close()
end

local function shot(name)
    gitgud.screenshot(OUT .. "/master-" .. name .. ".png")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function lastOf(items, kind)
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
local function count(items, kind)
    local n = 0
    for _, item in ipairs(items) do
        n = n + (item.kind == kind and 1 or 0)
    end
    return n
end
local function has(s, part)
    return tostring(s or ""):find(part, 1, true) ~= nil
end
local function reply()
    local item = lastOf(agent.items(), "assistant")
    return item and item.text or ""
end
local function same(a, b)
    return projects.key(a or "") == projects.key(b or "")
end
local function tabTitled(title)
    for _, tab in ipairs(agent.tabs()) do
        if tab.title == title then
            return tab
        end
    end
    return nil
end
local statuses = {}
app.subscribe("bragi.masterStatus", function(s)
    statuses[#statuses + 1] = s
end)
local replies = {}
app.subscribe("bragi.reply", function(r)
    replies[#replies + 1] = r.text or ""
end)

local bragi -- the master's tab

-- The saved conversations here were just written: not "in use elsewhere"
-- for these steps (the last ones check that).
agent.IN_USE_SECONDS = 0

step(1500, "a saved conversation, then Bragi", function()
    writeSaved(here, SAVED, "Fix the loot table")
    shell.show("agent")
    agent.refreshSessions(true)
    local list = agent.sessionRows()
    check("Bragi is pinned on top", list[1] and list[1].master == true)
    gitgud.emit("AgentSessionList.selected", "0")
end)

step(600, "Bragi's conversation", function()
    bragi = agent.current()
    check("the master conversation is shown", bragi.master == true and gitgud.getText("AgentTitle") == "Bragi")
    check("in its own folder", same(bragi.cwd, projects.masterDir()))
    check("with its prompt, for its user", has(bragi.extraPrompt, "You are Bragi, Sam's master conversation")
        and not has(bragi.extraPrompt, "{user}") and not has(bragi.extraPrompt, "{User}"))
    local f2 = io.open(projects.masterDir() .. "/.claude/settings.local.json", "rb")
    local allow = f2 and gitgud.jsonDecode(f2:read("a")) or {}
    if f2 then
        f2:close()
    end
    local rules = table.concat(allow.permissions and allow.permissions.allow or {}, " ")
    check("its tools are allowed in its folder", has(rules, "mcp__repo__bragi_send")
        and has(rules, "mcp__repo__bragi_clone"))
    check("the list marks it", gitgud.getSelectedIndex("AgentSessionList") == 1)
    say("call bragi_projects {}")
end)

step(2000, "projects", function()
    local text = reply()
    check("its tools need no permission card", count(agent.items(), "permission") == 0)
    check("the open repository is listed", has(text, "- repo: ") and has(text, "open in the Repo view"))
    check("with its conversations", has(text, "1 conversation"))
    check("no server's repositories", not has(text, "star-trader") and not has(text, "server"))
    check("where they'd be cloned", has(text, projectsFolder))
    check("Bragi's own folder isn't a project", not has(text, "/master:"))
    check("the session ran in its folder", same(agent.loaded().cwd, projects.masterDir()))
    shot("01-projects")
    say("call bragi_conversations {}")
end)

step(1800, "conversations", function()
    local text = reply()
    check("the saved conversation, its id, its project, its state",
        has(text, "\"Fix the loot table\" [" .. SAVED .. "] in repo: idle"))
    say('call bragi_read_conversation {"id":"' .. SAVED .. '"}')
end)

step(1800, "read one", function()
    local text = reply()
    check("its last exchange", has(text, "Sam: Fix the loot table") and has(text, "Claude: Looked at the loot table."))
    say('call bragi_send {"id":"' .. SAVED .. '","message":"hello"}')
end)

step(2500, "sent to it, in the background", function()
    local text = reply()
    check("Bragi says where it went", has(text, "Sent to \"Fix the loot table\" in repo"))
    local tab = tabTitled("Fix the loot table")
    check("the conversation resumed in the background", tab ~= nil and tab ~= agent.current()
        and tab.session.resume == SAVED and same(tab.cwd, here))
    check("it got the message", tab and lastOf(tab.items, "user") and lastOf(tab.items, "user").text == "hello")
    check("and answered", tab and lastOf(tab.items, "assistant") and lastOf(tab.items, "assistant").text == "Hello")
    check("its history came along", tab and tab.items[1] and tab.items[1].text == "Fix the loot table")
    check("Bragi follows it", tab and master.followed(tab))
    local note = lastOf(agent.items(), "note")
    check("a quiet status row in Bragi's conversation", note ~= nil and note.text == 'repo: done, "Fix the loot table"')
    check("with Open", note ~= nil and note.action ~= nil and note.action.label == "Open")
    check("not a model turn", lastOf(agent.items(), "assistant").text == text)
    shot("02-status-row")
    say('call bragi_start {"project":"repo","message":"tools","title":"Try two tools"}')
end)

step(2000, "started one", function()
    local text = reply()
    check("Bragi says it started it", has(text, "Started \"Try two tools\"") and has(text, " in repo."))
    local tab = tabTitled("Try two tools")
    check("a new conversation in the project's folder", tab ~= nil and same(tab.cwd, here) and not tab.master)
    check("with the first message", tab and tab.items[1] and tab.items[1].text == "tools")
    check("it waits for permissions", tab and agent.tabState(tab) == "permission")
    local notes = 0
    for _, s in ipairs(statuses) do
        notes = notes + ((s.tab == tab and s.what == "permission") and 1 or 0)
    end
    check("one status row says it needs the user", notes == 1
        and lastOf(agent.items(), "note").text == 'repo: "Try two tools" needs your permission')
    -- Open, from the row.
    local note = lastOf(agent.items(), "note")
    note.action.run(note)
end)

step(600, "opened from the row", function()
    local tab = agent.current()
    check("Open shows the conversation", tab.title == "Try two tools")
    for _, item in ipairs(tab.items) do
        if item.kind == "permission" and not item.answer then
            agent.answer(item, true)
        end
    end
end)

step(1500, "it finishes", function()
    local tab = tabTitled("Try two tools")
    check("it finished", tab and not tab.session.turn)
    local last = statuses[#statuses]
    check("the row counts the files changed", last and last.tab == tab and last.line == 'repo: done, "Try two tools" (1 file changed)')
    -- Another session can't use Bragi's tools.
    agent.newSession()
    say("call bragi_projects {}")
end)

step(1500, "another session asks for Bragi's tool", function()
    local card = lastOf(agent.items(), "permission")
    check("it isn't allowed there in advance", card ~= nil and card.tool == "mcp__repo__bragi_projects")
    if card then
        agent.answer(card, true)
    end
end)

step(1500, "refused", function()
    check("another session is refused Bragi's tools", has(reply(), "Refused: ")
        and has(reply(), "isn't available in this session"))
    master.open()
end)

step(600, "clone by address", function()
    check("back in Bragi", agent.current() == bragi)
    say("call bragi_clone " .. gitgud.jsonEncode({ url = remote, name = "star-trader" }))
end)

step(4000, "cloned", function()
    local path = projectsFolder .. "/star-trader"
    check("Bragi says where", has(reply(), " is in " .. path))
    check("it's a repository there", gitgud.pathExists(path .. "/.git"))
    check("a project now", projects.find("star-trader") ~= nil and same(projects.find("Star trader").path, path))
    check("the projects folder is remembered", settings.get("bragi.projectsFolder", "") == projectsFolder)
    check("the open repository stays as it was", same(repo.state().path, here))
    say('call bragi_open_project {"project":"star-trader"}')
end)

step(2000, "open a project", function()
    check("Bragi says so", has(reply(), "star-trader is open in the Repo view"))
    check("it's the open repository", same(repo.state().path, projectsFolder .. "/star-trader"))
    -- A local repository that isn't a project yet, by its path:
    -- Windows backslashes, a space in its name.
    gitgud.makeDir(localRepo)
    gitgud.runProgram({ gitgud.findProgram("git"), "init", "-q", localRepo })
    gitgud.makeDir(plainFolder)
    check("not a project yet", projects.find(localRepo) == nil and projects.find("Moon Garden") == nil)
    say("call bragi_open_project " .. gitgud.jsonEncode({ project = localRepo:gsub("/", "\\") }))
end)

step(2500, "a local repository by path", function()
    check("Bragi says it's a project now", has(reply(), "Moon Garden (" .. localRepo .. ") is a project now"))
    check("it's the open repository", same(repo.state().path, localRepo))
    check("it's in the repository list", projects.find("moon garden") ~= nil
        and same(projects.find("moon garden").path, localRepo))
    say("call bragi_open_project " .. gitgud.jsonEncode({ project = plainFolder }))
end)

step(1800, "a plain folder by path", function()
    check("refused: not a repository", has(reply(), "Refused: " .. plainFolder .. " isn't a Git repository"))
    check("no repository made there", not gitgud.pathExists(plainFolder .. "/.git"))
    check("not a project", projects.find(plainFolder) == nil)
    say("call bragi_open_project " .. gitgud.jsonEncode({ project = missingFolder }))
end)

step(1800, "a missing folder by path", function()
    check("says there's no such folder", has(reply(), "Refused: There's no folder " .. missingFolder))
    say("call bragi_projects {}")
end)

step(2000, "listed with the projects", function()
    check("the added repository is listed", has(reply(), "- Moon Garden: "))
    say('call bragi_open_project {"project":"repo"}')
end)

step(2500, "a known project by name", function()
    check("Bragi says so", has(reply(), "repo is open in the Repo view"))
    check("it's the open repository again", same(repo.state().path, here))
    say('call bragi_conversations {"project":"nowhere"}')
end)

step(1800, "an unknown project", function()
    check("says there's no such project", has(reply(), "Refused: No project called \"nowhere\""))
    local spokenRow = false
    for _, r in ipairs(replies) do
        spokenRow = spokenRow or r:find("^repo: ") ~= nil
    end
    check("Bragi's status rows are never replies (never spoken)", #replies > 0 and not spokenRow)
    local id = bragi.session.id
    check("its id is remembered", id ~= nil and settings.get("bragi.masterSession", "") == id)
    check("its transcript is where it resumes from", #gitgud.agentHistory(projects.masterDir(), id) > 0)
    check("voice talks to it while it's shown", agent.session() == bragi.session)
    local found = false
    for _, row in ipairs(agent.sessionRows()) do
        found = found or (row.header and same(row.header.cwd, projects.masterDir()))
    end
    check("Bragi's folder isn't listed as a project", not found)
    shot("03-end")
end)

-- A message to a conversation waiting on a card answers the card:
-- a question by its option or as its own answer, a
-- permission by a yes or a no; never sent as a message after it. The fake
-- claude's choice and approval classifiers read the message.
local function startWaiting(scenario, title)
    say("call bragi_start " .. gitgud.jsonEncode({ project = "repo", message = scenario, title = title }))
end
local function sendTo(title, message)
    -- Its id as bragi_start gave it: its session's, or Bragi's own for now.
    local tab = tabTitled(title)
    local id = tab and (tab.session.id or tab.session.resume or tab.ref) or ""
    say("call bragi_send " .. gitgud.jsonEncode({ id = id, message = message }))
end
local function card(tab, kind)
    return tab and lastOf(tab.items, kind)
end
local function onlyFirstMessage(tab)
    return tab ~= nil and count(tab.items, "user") == 1
end
-- What Bragi said since the last call: its reply, and news of the
-- conversations it follows, which may come before or after it.
local function answered()
    local items, said = agent.items(), {}
    for i = #items, 1, -1 do
        if items[i].kind == "user" then
            break
        elseif items[i].kind == "assistant" then
            table.insert(said, 1, items[i].text)
        end
    end
    return table.concat(said, "\n")
end

step(300, "a conversation asks a question", function()
    startWaiting("choose", "Pick a colour")
end)
step(2200, "answered by its option", function()
    local tab = tabTitled("Pick a colour")
    check("it waits on its question", tab ~= nil and agent.tabState(tab) == "permission"
        and card(tab, "question") and not card(tab, "question").answer)
    sendTo("Pick a colour", "blue, please")
end)
step(3000, "the question took the option", function()
    local tab = tabTitled("Pick a colour")
    local q = card(tab, "question")
    check("Bragi says how it answered", has(answered(),
        "Answered its question 'Which colour do you prefer?' with 'Blue'") and has(answered(), "Not sent as a message"))
    check("the card has the option, marked as Bragi's", q and q.answer == "Blue"
        and q.answerNote == "Answered from Bragi: \u{201C}blue, please\u{201D}")
    check("the conversation went on with it", lastOf(tab.items, "assistant")
        and lastOf(tab.items, "assistant").text == "You chose: Blue")
    check("nothing sent as a message", onlyFirstMessage(tab))
    startWaiting("choose", "Pick another colour")
end)
step(2200, "a question no option fits", function()
    sendTo("Pick another colour", "go ahead with the button")
end)
step(3000, "answered as its own answer", function()
    local tab = tabTitled("Pick another colour")
    local q = card(tab, "question")
    check("Bragi says it was the question's own answer", has(answered(),
        "with its own answer 'go ahead with the button' (no option fit)"))
    check("the card has the words", q and q.answer == "go ahead with the button")
    check("the conversation went on with them", lastOf(tab.items, "assistant")
        and lastOf(tab.items, "assistant").text == "You chose: go ahead with the button")
    check("nothing sent as a message (own answer)", onlyFirstMessage(tab))
    startWaiting("choose two", "Pick two")
end)
step(2200, "two questions at once", function()
    sendTo("Pick two", "blue, with install and usage")
end)
step(3000, "each question answered", function()
    local tab = tabTitled("Pick two")
    check("both answered, each its options", has(answered(), "with 'Blue'")
        and has(answered(), "with 'Install, Usage'"))
    check("the conversation went on with both", lastOf(tab.items, "assistant")
        and lastOf(tab.items, "assistant").text == "You chose: Blue; Install, Usage")
    check("nothing sent as a message (two)", onlyFirstMessage(tab))
    startWaiting("tool", "Say hi")
end)
step(2200, "a permission", function()
    local tab = tabTitled("Say hi")
    check("it waits on a permission", tab ~= nil and agent.tabState(tab) == "permission")
    sendTo("Say hi", "yes, go ahead")
end)
step(3000, "allowed", function()
    local tab = tabTitled("Say hi")
    local p = card(tab, "permission")
    check("Bragi says it allowed it", has(answered(), "Allowed its permission to run Bash"))
    check("the card is allowed, marked as Bragi's", p and p.answer == "Allowed"
        and p.answerNote == "Allowed from Bragi: \u{201C}yes, go ahead\u{201D}")
    check("the conversation went on", lastOf(tab.items, "assistant") and lastOf(tab.items, "assistant").text == "Done")
    check("nothing sent as a message (allowed)", onlyFirstMessage(tab))
    startWaiting("tool", "Say hi again")
end)
step(2200, "a permission, an unclear answer", function()
    sendTo("Say hi again", "maybe later")
end)
step(3000, "not answered, Bragi asks", function()
    local tab = tabTitled("Say hi again")
    check("Bragi is told to ask", has(answered(), "Not sent: ") and has(answered(), "isn't a clear yes or no")
        and has(answered(), "Ask Sam"))
    check("the card still waits", card(tab, "permission") and not card(tab, "permission").answer)
    check("nothing sent as a message (unclear)", onlyFirstMessage(tab))
    sendTo("Say hi again", "no")
end)
step(3000, "denied", function()
    local tab = tabTitled("Say hi again")
    local p = card(tab, "permission")
    check("Bragi says it denied it", has(answered(), "Denied its permission to run Bash"))
    check("the card is denied", p and p.answer == "Denied" and p.answerNote == "Denied from Bragi: \u{201C}no\u{201D}")
    check("the conversation went on (denied)", lastOf(tab.items, "assistant")
        and lastOf(tab.items, "assistant").text == "Denied")
    check("nothing sent as a message (denied)", onlyFirstMessage(tab))
end)

-- A result that ran no turn before the message was taken up (Claude
-- Code's for a notification it only writes to the transcript, before the
-- message queued behind it) isn't the answer: the conversation still
-- works, and Bragi's news waits for its reply (the fake recap helper
-- repeats it), never "done" with nothing to tell.
local function news(title)
    local list = {}
    for _, item in ipairs(bragi.items) do
        local at = item.kind == "assistant" and item.text:find(title .. " done", 1, true)
        if at then
            list[#list + 1] = item.text:sub(at)
        end
    end
    return list
end
local function doneCount(tab)
    local n = 0
    for _, s in ipairs(statuses) do
        n = n + ((s.tab == tab and s.what == "done") and 1 or 0)
    end
    return n
end
step(300, "a conversation answers after a result with no turn", function()
    startWaiting("late", "Merge it")
end)
step(2000, "not done before its answer", function()
    local tab = tabTitled("Merge it")
    check("it still works, in the background", tab ~= nil and tab.session.turn == true and tab ~= agent.current())
    check("no status row or news yet", tab ~= nil and doneCount(tab) == 0 and #news("Merge it") == 0)
end)
step(4500, "done, with its reply", function()
    local tab = tabTitled("Merge it")
    check("it answered, unseen", tab ~= nil and not tab.session.turn and lastOf(tab.items, "assistant")
        and lastOf(tab.items, "assistant").text == "Merged, and the tests pass.")
    check("one status row, once it answered", tab ~= nil and doneCount(tab) == 1)
    check("the recap helper has its reply", tab ~= nil and master.describe(tab).reply == "Merged, and the tests pass.")
    local told = news("Merge it")
    check("the news tells its reply", #told == 1 and told[1]:find("^Merge it done: Merged, and the tests pass%.") ~= nil)
end)

-- A recap typed in any words: the router calls it
-- `recap`, and it's told from the live state of the conversations Bragi
-- follows, as a quiet row, never a turn of the master's.
local before = { reply = "", replies = 0 }
step(300, "asked how the conversations are doing", function()
    before.reply, before.replies = reply(), #replies
    say("how are my conversations doing?")
end)

step(2500, "a recap", function()
    local note = lastOf(agent.items(), "note")
    local said = note and note.text or ""
    check("a quiet row under the message", lastOf(agent.items(), "user").text == "how are my conversations doing?"
        and has(said, "Recap: "))
    check("told from what the app sees", has(said, "Fix the loot table is finished, not looked at yet"))
    check("not a turn of the master's", reply() == before.reply and not bragi.session.turn)
    check("never spoken for a typed message", #replies == before.replies)
    local notes = agent.quickNotes()
    check("it rides along with the next message", #notes > 0 and notes[#notes].a == said)
end)

-- What Bragi follows is kept with its conversation, so after a restart its
-- recaps and updates still know them ("I'm not following
-- anything right now").
local EARLIER = "5555eeee-0000-0000-0000-000000000005"
step(300, "a restart: what Bragi follows comes back", function()
    local kept = gitgud.jsonDecode(settings.get("bragi.masterFollows", "") or "") or {}
    local has = false
    for _, f in ipairs(kept) do
        has = has or f.id == SAVED
    end
    check("the conversation it sent work to is kept", has)
    -- As a new start has it: the open conversation's flag gone, and one
    -- followed before, saved and not open.
    writeSaved(here, EARLIER, "Ship the patch")
    kept[#kept + 1] = { id = EARLIER, cwd = here, title = "Ship the patch", at = os.time() - 600 }
    settings.set("bragi.masterFollows", gitgud.jsonEncode(kept))
    master.reloadFollows()
    local tab = tabTitled("Fix the loot table")
    tab.bragiFollows = nil
    check("an open one is followed again", master.followed(tab) and tab.bragiFollows == true)
    local titles = {}
    for _, d in ipairs(require("bragi.recap").conversations()) do
        titles[d.title] = d
    end
    check("the recap has both", titles["Fix the loot table"] ~= nil and titles["Ship the patch"] ~= nil)
    check("the saved one from its transcript", titles["Ship the patch"] ~= nil
        and titles["Ship the patch"].reply == "Looked at the loot table." and titles["Ship the patch"].state == "idle")
    before.reply, before.replies = reply(), #replies
    say("how are my conversations doing?")
end)

step(2500, "a recap after the restart", function()
    local note = lastOf(agent.items(), "note")
    check("it tells of the one from before", note ~= nil and has(note.text, "Ship the patch"))
    -- Reading one back and the recaps read saved transcripts by now.
    local bounded = #masterReads >= 2
    for _, max in ipairs(masterReads) do
        bounded = bounded and max ~= false and max <= 1000
    end
    check("Bragi reads only the latest entries of a saved transcript", bounded)
end)

-- A conversation written to a moment ago (as one open in another app is):
-- the master still sends into it, never a new one instead.
local BUSY = "4444dddd-0000-0000-0000-000000000004"
step(300, "a conversation written to a moment ago", function()
    agent.IN_USE_SECONDS = 300
    writeSaved(here, BUSY, "The live desktop session")
    agent.refreshSessions(true)
    require("bragi.master").open()
    say('call bragi_send {"id":"' .. BUSY .. '","message":"check the build"}')
end)
step(2500, "sent to it", function()
    local text = reply()
    check("Bragi says it sent it there", has(text, "Sent to \"The live desktop session\""))
    check("no new conversation instead", tabTitled("check the build") == nil)
    local busyTab = nil
    for _, tab in ipairs(agent.tabs()) do
        if tab.session.resume == BUSY or tab.session.id == BUSY then
            busyTab = tab
        end
    end
    check("the message went to it", busyTab ~= nil and lastOf(busyTab.items, "user") ~= nil
        and lastOf(busyTab.items, "user").text == "check the build")
end)

step(300, "Settings, Projects", function()
    require("bragi.settings").open("projects")
end)

step(600, "the projects folder in Settings", function()
    local bragiSettings = require("bragi.settings")
    check("a Projects folder row", gitgud.getText(bragiSettings.widget(1, 1, "Title")) == "Projects folder"
        and gitgud.getText(bragiSettings.widget(1, 1, "InputEdit")) == projectsFolder)
    check("with Choose", gitgud.getText(bragiSettings.widget(1, 2, "Action")) == "Choose")
    shot("04-settings")
end)

-- Restarting the app (bragi_restart_app): not while other conversations
-- work unless forced; it answers, then closes once Claude Code has the
-- answer. gitgud.restartApp is stubbed: the real one closes the app.
local restarts = 0
local realRunning -- the side panel's running(), while a test stands in for it
gitgud.restartApp = function()
    restarts = restarts + 1
    return true
end
local loot
step(300, "restart while a conversation works", function()
    shell.show("agent")
    master.open()
    loot = tabTitled("Fix the loot table")
    loot.session.turn = true
    say("call bragi_restart_app {}")
end)
step(2000, "refused, saying which", function()
    check("a restart names what it would stop", has(reply(), "Refused: Not restarted: it would stop "
        .. "\"Fix the loot table\" in repo (running)") and has(reply(), "force"))
    check("and doesn't restart", restarts == 0 and settings.get("bragi.restarted", "") == "")
    loot.session.turn = false
    -- Background tasks count too (the side panel's, where it counts them).
    realRunning = require("bragi.sidepanel").running
    require("bragi.sidepanel").running = function(tab)
        return tab == loot and 2 or 0
    end
    say("call bragi_restart_app {}")
end)
step(2000, "refused for background tasks", function()
    check("background tasks are named", has(reply(), "\"Fix the loot table\" in repo (2 background tasks)"))
    say('call bragi_restart_app {"force":true}')
end)
step(1500, "forced", function()
    check("it answers first", has(reply(), "Restarting now") and not has(reply(), "Refused"))
    check("then restarts, once Claude Code has the answer", restarts == 1)
    local note = gitgud.jsonDecode(settings.get("bragi.restarted", "")) or {}
    check("what the new start carries on with is kept", tonumber(note.at) ~= nil and note.listening == false
        and note.byVoice == false)
    require("bragi.sidepanel").running = realRunning
    -- The new start: Bragi's conversation again, with a note.
    agent.showTab(loot)
    master.afterRestart()
end)
step(600, "after the restart", function()
    check("Bragi's conversation is open again", agent.current() == bragi)
    local note = lastOf(agent.items(), "note")
    check("with a quiet note", note ~= nil and has(note.text, "The app restarted"))
    check("the note is used once", settings.get("bragi.restarted", "") == "")
    -- Asked by voice while listening: voice back on, and "I'm back".
    local voice = require("bragi.voice")
    local toggle, sayLine = voice.toggle, voice.say
    local toggled, said = false, nil
    voice.toggle = function()
        toggled = true
        gitgud.after(0, function()
            app.publish("bragi.voice", "listening")
        end)
    end
    voice.say = function(line)
        said = line
    end
    settings.set("bragi.restarted", gitgud.jsonEncode({ at = os.time(), listening = true, byVoice = true }))
    master.afterRestart()
    gitgud.after(200, function()
        check("voice listens again", toggled)
        check("and says it's back", said == "I'm back.")
        voice.toggle, voice.say = toggle, sayLine
    end)
end)

step(600, "done", function()
    print("[ui-test] done")
    gitgud.emit("window.close", "")
end)

harness.run()
