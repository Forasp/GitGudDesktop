--- tests/ui/bragi-agent.lua: the Bragi UI's Agent view driving a session
-- (B3: streamed text, steps, permission cards, Stop) and the sessions list
-- (B4: Claude Code's saved sessions, resuming one), against the fake
-- claude (tests/fake_claude.cpp), never the real one.
--
-- Run it like bragi.lua (GITGUD_UI=bragi, scratch APPDATA and LOCALAPPDATA,
-- a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing here,
-- GITGUD_SHOTS), with GITGUD_TEST_CLAUDE set to
-- build\release\bin\gitgud_test_claude.exe and CLAUDE_CONFIG_DIR set to a
-- scratch folder (a saved session is written there). Prints "[check] ...".

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
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/agent-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
--- The newest transcript item of a kind.
local function last(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end

-- A saved session for this repository, as Claude Code writes it.
local SAVED = "0000aaaa-1111-2222-3333-444455556666"
local function writeSaved()
    local folder = repo.state().path:gsub("[^%w]", "-")
    local dir = config .. "/projects/" .. folder
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    local f = assert(io.open(dir .. "/" .. SAVED .. ".jsonl", "wb"))
    f:write('{"type":"user","message":{"role":"user","content":"Old question about the parser"}}\n')
    f:write('{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Old answer with **bold**."}]}}\n')
    f:write('{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"git log -1"}}]}}\n')
    f:write('{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"abc123 Fix","is_error":false}]}}\n')
    -- A spoken message with what was said before it, as context.
    f:write('{"type":"user","message":{"role":"user","content":"Fix that one\\n\\n<voice-context>\\n'
        .. 'Speech heard before this message, for context only.\\nThe parser is slow.\\n</voice-context>"}}\n')
    f:close()
    -- A voice helper's session from before helpers stopped saving theirs,
    -- and two scheduled task runs.
    local extra = {
        ["0000bbbb-1111-2222-3333-444455556666"] = '{\\"message\\":\\"All right\\",\\"context\\":\\"\\"}',
        ["0000cccc-1111-2222-3333-444455556666"] = '<scheduled-task name=\\"bragi-one\\">run</scheduled-task>',
        ["0000dddd-1111-2222-3333-444455556666"] = '<scheduled-task name=\\"bragi-two\\">run</scheduled-task>',
    }
    for id, content in pairs(extra) do
        f = assert(io.open(dir .. "/" .. id .. ".jsonl", "wb"))
        f:write('{"type":"user","message":{"role":"user","content":"' .. content .. '"}}\n')
        f:close()
    end
end

step(1500, "start in the Agent view", function()
    shell.show("agent")
    writeSaved()
    -- Instructions and a hook, as a project would have them.
    local root = repo.state().path
    local f = assert(io.open(root .. "/CLAUDE.md", "wb"))
    f:write("# Rules\n")
    f:close()
    os.execute('mkdir "' .. (root .. "/.claude"):gsub("/", "\\") .. '" 2>nul')
    f = assert(io.open(root .. "/.claude/settings.local.json", "wb"))
    f:write('{"hooks":{"PreToolUse":[]}}')
    f:close()
    agent.refreshSessions(true)
end)

step(300, "the saved session is listed", function()
    check("the sessions list has the saved session", not (gitgud.getProperty("AgentSessionsEmpty", "Visible") == "true"))
    local saved, scheduled, helper = 0, nil, false
    for _, row in ipairs(agent.sessionRows()) do
        if row.scheduled then
            scheduled = row.scheduled
        elseif row.saved then
            saved = saved + 1
            helper = helper or row.saved.id:find("^0000bbbb") ~= nil
        end
    end
    check("helper sessions aren't listed", not helper)
    check("scheduled runs are one row", scheduled == 2 and saved == 1)
    check("a helper's title is known", agent.savedKind('{"message":"x","context":""}') == "helper")
    check("a scheduled run's title is known", agent.savedKind('<scheduled-task name="x">') == "scheduled")
    check("a normal title is neither", agent.savedKind("Fix the parser") == nil)
end)

--- Click the scheduled runs' row.
local function clickScheduled()
    for i, row in ipairs(agent.sessionRows()) do
        if row.scheduled then
            gitgud.emit("AgentSessionList.selected", tostring(i - 1))
        end
    end
end

step(200, "a click on the scheduled runs", clickScheduled)

step(300, "scheduled runs open on a click", function()
    local saved = 0
    for _, row in ipairs(agent.sessionRows()) do
        saved = saved + (row.saved and 1 or 0)
    end
    check("the scheduled runs are listed after a click", saved == 3)
    shot("00-scheduled-open")
    clickScheduled()
end)

step(200, "permission modes from the CLI", function()
    local ids = {}
    for _, m in ipairs(agent.MODES) do
        ids[m.id] = m
    end
    check("Auto is offered", ids.auto ~= nil)
    check("skipping checks is offered, behind a confirmation", ids.bypassPermissions ~= nil
        and ids.bypassPermissions.confirm ~= nil)
    check("dontAsk and manual aren't in the menu", ids.dontAsk == nil and ids.manual == nil)
    check("the old choices stay", ids.default ~= nil and ids.acceptEdits ~= nil and ids.plan ~= nil)
end)

step(200, "say hello", function()
    say("hello")
end)

step(1500, "streamed reply", function()
    local reply = last("assistant")
    check("a session started", agent.session().running == true)
    check("the reply is drawn", reply ~= nil and reply.text == "Hello")
    check("the turn ended", agent.session().turn == false)
    check("Send is back", gitgud.getProperty("AgentSendIcon", "IconImage") == "Bragi-Icons/Send")
    check("the session id is known", agent.session().id == "fake-session")
    shot("01-hello")
end)

step(200, "a tool that asks first", function()
    say("tool")
end)

step(1200, "permission card", function()
    local card = last("permission")
    check("a permission card asks", card ~= nil and card.tool == "Bash" and card.answer == nil)
    check("it shows the command", card ~= nil and card.summary == "echo hi")
    local step = last("step")
    check("the tool call is a step", step ~= nil and step.title == "Bash" and step.summary == "echo hi")
    check("Stop shows while it waits", gitgud.getProperty("AgentSendIcon", "IconImage") == "Bragi-Icons/Stop")
    shot("02-permission")
    clickWidget(card.inner .. "Allow")
end)

step(1200, "allowed", function()
    local card = last("permission")
    local step = last("step")
    check("the card says it was allowed", card.answer == "Allowed")
    check("the step finished", step.result ~= nil and not step.error)
    check("the turn ended", agent.session().turn == false)
    clickWidget(step.inner)
end)

step(500, "step details", function()
    local step = last("step")
    check("clicking a step opens it", step.open == true)
    check("details show the input", (gitgud.getText(step.inner .. "Detail") or ""):find("echo hi", 1, true) ~= nil)
    shot("03-step-open")
end)

step(200, "a turn that runs until stopped", function()
    say("wait")
end)

step(1000, "running", function()
    check("the turn runs", agent.session().turn == true)
    clickWidget("AgentSendButton")
end)

step(1200, "stopped", function()
    check("Stop ended the turn", agent.session().turn == false)
    check("the transcript says so", last("note") ~= nil and last("note").text == "Stopped.")
    check("the running step is marked stopped", last("step").stopped == true)
end)

-- Claude's questions (AskUserQuestion): the fake's "choose" asks which
-- colour (Red, Blue), "choose two" also which README sections
-- (multi-select: Install, Usage, License).
--- The newest `n` question cards, oldest first.
local function questions(n)
    local list = {}
    for _, item in ipairs(agent.items()) do
        if item.kind == "question" then
            list[#list + 1] = item
        end
    end
    return { table.unpack(list, math.max(1, #list - n + 1)) }
end

step(200, "a question", function()
    say("choose")
end)

step(1200, "the question card", function()
    local card = last("question")
    check("a question card asks", card ~= nil and card.answer == nil and card.question == "Which colour do you prefer?")
    check("with its options and their descriptions", card ~= nil and #card.options == 2
        and gitgud.getText(card.inner .. "Option2Desc") == "Calm and cool.")
    check("a field for your own words and Skip", card ~= nil and gitgud.getRect(card.inner .. "OtherEdit") ~= nil
        and gitgud.getRect(card.inner .. "Skip") ~= nil)
    check("no Allow card for it", last("permission").answer ~= nil)
    check("the session waits for you", agent.tabState(agent.tabs()[#agent.tabs()]) == "permission")
    shot("09-question")
    clickWidget(card.inner .. "Option2")
end)

step(1200, "an option clicked", function()
    local card = last("question")
    check("the card shows the answer", card.answer == "Blue")
    check("Claude got it", last("assistant").text == "You chose: Blue")
    check("the turn ended", agent.session().turn == false)
    shot("10-question-answered")
    say("choose two")
end)

step(1200, "two questions: a card each", function()
    local cards = questions(2)
    check("two cards", #cards == 2 and cards[1].answer == nil and cards[2].answer == nil
        and cards[2].question == "Which sections should the README have?")
    check("the second takes several, with Submit", cards[2].multi == true
        and gitgud.getRect(cards[2].inner .. "Submit") ~= nil and gitgud.getRect(cards[2].inner .. "Option1Box") ~= nil)
    clickWidget(cards[2].inner .. "Option1")
end)

step(300, "ticked", function()
    local cards = questions(2)
    check("Install is ticked", cards[2].picked.Install == true and cards[2].answer == nil)
    clickWidget(cards[2].inner .. "Option3")
end)

step(300, "ticked another", function()
    local cards = questions(2)
    check("License too", cards[2].picked.License == true)
    shot("11-questions")
    clickWidget(cards[2].inner .. "Submit")
end)

step(500, "submitted", function()
    local cards = questions(2)
    check("the second is answered", cards[2].answer == "Install, License")
    check("Claude waits for the first", agent.session().turn == true and cards[1].answer == nil)
    say("Green, actually")
end)

step(1500, "typed in the prompt box", function()
    local cards = questions(2)
    check("the typed words answer the open question", cards[1].answer == "Green, actually")
    check("not sent as a message", last("user").text == "choose two")
    check("both went back together", last("assistant").text == "You chose: Green, actually; Install, License")
    say("choose")
end)

step(1200, "your own words on the card", function()
    local card = last("question")
    check("a new question card asks", card ~= nil and card.answer == nil)
    gitgud.focus(card.inner .. "OtherEdit")
    gitgud.simulateText("Purple")
    gitgud.simulateKey("enter")
end)

step(1500, "answered in your own words", function()
    check("the card shows them", last("question").answer == "Purple")
    check("Claude got them", last("assistant").text == "You chose: Purple")
    say("choose")
end)

step(1200, "a number typed", function()
    check("a new question card asks", last("question") ~= nil and last("question").answer == nil)
    say("1")
end)

step(1500, "picks that option", function()
    check("the first option", last("question").answer == "Red" and last("assistant").text == "You chose: Red")
    say("choose")
end)

step(1200, "skipped", function()
    check("a new question card asks", last("question") ~= nil and last("question").answer == nil)
    clickWidget(last("question").inner .. "Skip")
end)

step(1500, "Claude hears you didn't choose", function()
    check("the card says skipped", last("question").answer == "Skipped")
    local reply = last("assistant").text or ""
    check("Claude goes on", reply:find("No answer: The user closed the question", 1, true) == 1)
    check("nothing waits", agent.session().turn == false and agent.openQuestion() == nil)
    say("choose")
end)

step(1200, "a question when the turn is stopped", function()
    check("a new question card asks", last("question") ~= nil and last("question").answer == nil)
    clickWidget("AgentSendButton")
end)

step(1200, "cancelled", function()
    check("the card is cancelled", last("question").answer == "Cancelled")
    check("the turn ended", agent.session().turn == false)
end)

step(200, "new session", function()
    clickWidget("AgentNewButton")
end)

step(600, "fresh", function()
    check("the transcript is empty", #agent.items() == 0)
    check("the session closed", agent.session().running == false)
    check("the empty state shows", gitgud.getProperty("AgentEmpty", "Visible") == "true")
end)

step(1800, "resume the saved session", function()
    agent.resume(SAVED)
end)

step(500, "resumed", function()
    local items = agent.items()
    check("its messages are shown", items[1] and items[1].kind == "user"
        and items[1].text == "Old question about the parser")
    check("its answer too", items[2] and items[2].kind == "assistant" and items[2].text == "Old answer with **bold**.")
    check("its tool call has its result", items[3] and items[3].kind == "step" and items[3].result == "abc123 Fix")
    check("a spoken message shows without its context", items[4] and items[4].kind == "user"
        and items[4].text == "Fix that one")
    check("context is kept from the view", agent.shownText(agent.withContext("Do it", "said before")) == "Do it"
        and agent.withContext("Do it", "said before"):find("<voice-context>", 1, true) ~= nil)
    check("the title is the session's", gitgud.getText("AgentTitle") == "Old question about the parser")
    check("the next message resumes it", agent.session().resume == SAVED)
    shot("04-resumed")
    say("args")
end)

step(1500, "resumed by id", function()
    local reply = last("assistant")
    check("Claude Code got --resume and the id", reply ~= nil and reply.text:find("--resume", 1, true) ~= nil
        and reply.text:find(SAVED, 1, true) ~= nil)
    check("and the model and mode", reply ~= nil and reply.text:find("--model", 1, true) ~= nil
        and reply.text:find("--permission-mode", 1, true) ~= nil)
end)

step(200, "the args never run it bare or replace the system prompt", function()
    local reply = last("assistant")
    check("no --bare", reply ~= nil and reply.text:find("--bare", 1, true) == nil)
    check("no --system-prompt", reply ~= nil and reply.text:find("--system-prompt\n", 1, true) == nil)
    say("skills")
end)

step(1500, "synced skills are on", function()
    check("CLAUDE_CODE_SYNC_SKILLS=1", last("assistant") ~= nil and last("assistant").text == "1")
    local l = agent.loaded()
    check("what it loaded is kept", l ~= nil and l.version == "0.0.0-fake" and l.apiKeySource == "none")
    local found = false
    for _, f in ipairs(l and l.files or {}) do
        found = found or (f.kind == "project" and f.path:find("CLAUDE.md", 1, true) ~= nil)
    end
    check("the repository's CLAUDE.md is listed", found)
    require("bragi.settings").open("claude")
end)

step(400, "Settings, Claude, what the agent loads", function()
    local bragiSettings = require("bragi.settings")
    local function sub(row)
        return gitgud.getText(bragiSettings.widget(2, row, "Sub")) or ""
    end
    check("the sign-in is the subscription", sub(1):find("claude.ai sign-in", 1, true) ~= nil)
    check("the version and model", sub(2):find("0.0.0-fake", 1, true) ~= nil)
    check("the instructions", sub(3):find("CLAUDE.md", 1, true) ~= nil)
    check("the MCP servers with their status", sub(5) == "gitgud (connected)")
    check("the skills", sub(6) == "fake-skill")
    check("the plugins", sub(7) == "fake-plugin")
    check("the hooks", sub(9):find("PreToolUse", 1, true) ~= nil)
    check("a switch for quick answers", gitgud.getText(bragiSettings.widget(1, 7, "Title"))
        == "Answer simple questions with Haiku")
    shot("05-loaded")
end)

step(300, "an API key in use", function()
    shell.show("agent")
    gitgud.emit("agent.init", gitgud.jsonEncode({ session = agent.session().name, sessionId = "fake-session",
        apiKeySource = "ANTHROPIC_API_KEY" }))
end)

step(300, "an API key is pointed out", function()
    local note = last("note")
    check("the transcript says an API key is in use", note ~= nil and note.text:find("API key", 1, true) ~= nil)
end)

-- Quick answers (E10): a quick question goes to Haiku, reading only; the
-- next message to the agent carries its answer. The fake router calls
-- "what time", "which branch", "readme", "todo", and "why does" quick.
local voiceLog = require("bragi.voice")
--- A voice-log.txt line of `kind` with all of `parts` in it.
local function logged(kind, parts)
    for _, line in ipairs(voiceLog.logLines()) do
        local all = line:find(" " .. kind .. " ", 1, true) ~= nil
        for _, part in ipairs(parts or {}) do
            all = all and line:find(part, 1, true) ~= nil
        end
        if all then
            return true
        end
    end
    return false
end
local function count(kind)
    local n = 0
    for _, item in ipairs(agent.items()) do
        n = n + (item.kind == kind and 1 or 0)
    end
    return n
end
local assistants = 0

step(300, "a quick question", function()
    assistants = count("assistant")
    check("the router and the answerer were warmed when the view opened",
        logged("helper", { '"helper":"bragi-route"', '"ping":true' })
        and logged("helper", { '"helper":"bragi-quick"', '"ping":true' }))
    say("what time is it")
end)

step(1500, "answered by Haiku", function()
    local reply = last("assistant")
    local branch = repo.state().branch
    check("answered under the question", count("assistant") == assistants + 1 and last("user").text == "what time is it"
        and last("user").pending == nil)
    check("tagged", reply ~= nil and reply.tag == "Answered by Haiku")
    check("from the digest: the time and the branch", reply ~= nil and reply.text:find("It's ", 1, true) == 1
        and reply.text:find("on `" .. branch .. "`", 1, true) ~= nil)
    check("the agent wasn't asked", agent.session().turn == false)
    check("no waiting row left", count("waiting") == 0)
    check("the route is logged", logged("route", { '"by":"router"', '"route":"quick"', '"text":"what time is it"' }))
    check("the answer is logged", logged("quick", { '"question":"what time is it"', '"answer":"It' }))
    check("it waits to go with the next message", #agent.quickNotes() == 1)
    shot("06-quick")
    say("which branch am I on")
end)

step(1500, "a repo tool, allowed", function()
    local reply = last("assistant")
    check("answered from the branches tool", reply ~= nil and reply.tag ~= nil and reply.text == "You're on `main`.")
    check("the tool was allowed", logged("helper-tool", { '"tool":"mcp__repo__branches"', '"allowed":true' }))
    check("the tools used are logged", logged("quick", { '"tools":["mcp__repo__branches"]' }))
    say("what does the readme say")
end)

step(1500, "a file read", function()
    local reply = last("assistant")
    check("answered from the file", reply ~= nil and reply.tag ~= nil
        and reply.text == "The README is titled \"Test repository\".")
    check("it read it", logged("quick", { '"tools":["Read"]' }))
    say("do you have background tasks on the right side? never mind, I just found it")
end)

-- A withdrawn question needs no answer: Haiku replies, whatever it was
-- about, and Opus isn't asked (the 2026-10-17 bug).
step(1500, "never mind: answered, not handed back", function()
    local reply = last("assistant")
    check("a short reply from Haiku", reply ~= nil and reply.tag ~= nil
        and reply.text == "Good, glad you found it.")
    check("not handed back", not logged("quick", { '"handoff":true', '"question":"do you have background' }))
    check("the agent wasn't asked", agent.session().turn == false)
    local prompt = nil
    for _, root in ipairs(require("bragi.customize").roots()) do
        local f = root and io.open(root .. "/prompts/quick-answer.md", "rb")
        if f and not prompt then
            prompt = f:read("a")
        end
        if f then
            f:close()
        end
    end
    check("the prompt says to answer these, not hand them back",
        (prompt or ""):gsub("%s+", " "):find("Never hand these back", 1, true) ~= nil)
    say("tick off the todo")
end)

step(2500, "a write is refused: handed back", function()
    check("the write was denied", logged("helper-tool", { '"tool":"Write"', '"allowed":false' }))
    check("logged as a hand-off", logged("quick", { '"handoff":true', '"why":"that needs an edit"' }))
    local passing = false
    for _, item in ipairs(agent.items()) do
        passing = passing or (item.kind == "note" and item.text == "Passing that to Opus.")
    end
    check("it says it's passing it on", passing)
    check("your message shows as typed", last("user").text == "tick off the todo")
    local reply = last("assistant")
    check("the agent answered it", reply ~= nil and reply.tag == nil
        and reply.text:find("You said: tick off the todo\n\nMeanwhile, Haiku answered:\n", 1, true) == 1)
    check("with the quick answers so far", reply ~= nil and reply.text:find("Q: what time is it\nA: It's ", 1, true) ~= nil
        and reply.text:find("Q: which branch am I on\nA: You're on `main`.", 1, true) ~= nil)
    check("each goes once", #agent.quickNotes() == 0 and logged("quick-note", { '"count":4' }))
    shot("07-handed-back")
    say("ask Opus what time it is")
end)

step(1500, "\"ask Opus\" goes to the agent", function()
    local reply = last("assistant")
    check("the agent answered", reply ~= nil and reply.tag == nil and reply.text == "You said: ask Opus what time it is")
    check("decided without asking", logged("route", { '"by":"app"', '"why":"asked for Opus"' }))
    settings.set("bragi.quickAnswers", false)
    say("what time is it")
end)

step(1500, "quick answers off", function()
    local reply = last("assistant")
    check("the agent answered", reply ~= nil and reply.tag == nil and reply.text == "You said: what time is it")
    check("logged why", logged("route", { '"why":"quick answers are off"' }))
    settings.set("bragi.quickAnswers", true)
    say("wait")
end)

step(1200, "a turn runs", function()
    check("the agent works", agent.session().turn == true)
    say("what time is it")
end)

step(1500, "a quick question while it works", function()
    local reply = last("assistant")
    check("answered by Haiku", reply ~= nil and reply.tag == "Answered by Haiku")
    check("while the agent still works", agent.session().turn == true)
    shot("08-quick-while-working")
    agent.stop()
end)

step(1200, "a question Haiku hands back", function()
    check("the turn stopped", agent.session().turn == false)
    say("why does the build fail")
end)

step(2000, "handed back", function()
    check("logged", logged("quick", { '"why":"that needs judgment"' }))
    local reply = last("assistant")
    check("the agent answered, with what Haiku answered meanwhile", reply ~= nil
        and reply.text:find("You said: why does the build fail\n\nMeanwhile, Haiku answered:\nQ: what time is it", 1, true)
        == 1)
end)

step(300, "done", function()
    gitgud.agentStop(agent.session().name or "")
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
