--- tests/ui/bragi-switch.lua: opening and switching long conversations in
-- the Agent view, timed ("when I'm first clicking on a
-- conversation or switching conversations, it can hitch for a little
-- while"). Writes two long saved sessions (a few hundred messages, steps
-- with big results, Markdown replies) in the scratch CLAUDE_CONFIG_DIR,
-- then opens one from the sessions list, opens the other, and goes back to
-- the first while it's busy in the background. Each action is timed until
-- the frame that draws it, with the parts of it (reading the transcript,
-- Markdown, window calls) on "[perf] ..." lines.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT,
-- GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints "[check] ...".

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
local markdown = require("bragi.markdown")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

-- What each action spends, by part: the wrapped calls add their time here.
local spent = {}
local function timed(owner, name)
    local real = owner[name]
    owner[name] = function(...)
        local started = os.clock()
        local a, b, c = real(...)
        local s = spent[name] or { ms = 0, n = 0 }
        s.ms = s.ms + (os.clock() - started) * 1000
        s.n = s.n + 1
        spent[name] = s
        return a, b, c
    end
end
for _, name in ipairs({ "agentHistory", "agentSessions", "createWindow", "destroyWindow", "setProperty",
    "getProperty", "setText", "setVisible" }) do
    timed(gitgud, name)
end
timed(markdown, "parse")
timed(markdown, "render")

local results = {}
--- Time `fn` until the frame that draws its result (a 0 ms timer runs on
-- the loop pass after that frame), printing the parts.
local function measure(label, fn, done)
    spent = {}
    local started = gitgud.now()
    local cpu = os.clock()
    fn()
    local call = gitgud.now() - started
    local lua = (os.clock() - cpu) * 1000
    gitgud.after(0, function()
        local total = gitgud.now() - started
        results[label] = total
        print(string.format("[perf] %-34s %6d ms to the next frame (the call %d ms)", label, total, call))
        local parts = {}
        for name, s in pairs(spent) do
            parts[#parts + 1] = { name = name, ms = s.ms, n = s.n }
        end
        table.sort(parts, function(a, b) return a.ms > b.ms end)
        for _, p in ipairs(parts) do
            print(string.format("[perf]     %-16s %8.1f ms  %6d calls", p.name, p.ms, p.n))
        end
        print(string.format("[perf]     (all Lua and calls %.1f ms)", lua))
        if done then
            done()
        end
    end)
end

-- Two long sessions, as Claude Code writes them.
local LONG = { "1111aaaa-1111-2222-3333-444455556666", "2222bbbb-1111-2222-3333-444455556666" }
local TURNS = 400
local function writeLong(id, topic)
    local folder = repo.state().path:gsub("[^%w]", "-")
    local dir = config .. "/projects/" .. folder
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    local f = assert(io.open(dir .. "/" .. id .. ".jsonl", "wb"))
    local function line(t)
        f:write(gitgud.jsonEncode(t), "\n")
    end
    local result = string.rep("src/parser/lexer.cpp:120: token = next(); // a line of output\n", 120)
    for turn = 1, TURNS do
        line({ type = "user", message = { role = "user", content = topic .. ": question " .. turn
            .. ", about the parser and why the build fails on the second pass" } })
        line({ type = "assistant", message = { role = "assistant", content = { { type = "text", text =
            "I'll look at **the parser** first. Here's what I found:\n\n"
            .. "- The lexer reads `tokens` one at a time\n- It stops at the first error\n"
            .. "- Then the *second pass* starts\n\n```cpp\nint main()\n{\n    return parse(argv[1]);\n}\n```\n\n"
            .. "That should be enough to see it." } } } })
        for k = 1, 3 do
            local tid = "t" .. turn .. "x" .. k
            line({ type = "assistant", message = { role = "assistant", content = { { type = "tool_use", id = tid,
                name = k == 2 and "Read" or "Bash", input = k == 2 and { file_path = "src/parser/lexer.cpp" }
                    or { command = "git log --oneline -" .. k } } } } })
            line({ type = "user", message = { role = "user", content = { { type = "tool_result",
                tool_use_id = tid, content = result, is_error = false } } } })
        end
        line({ type = "assistant", message = { role = "assistant", content = { { type = "text", text =
            "Done: the build passes now (turn " .. turn .. ")." } } } })
    end
    f:close()
end

local shown, shownTop = nil, nil -- the first item shown before "Show", and where

--- The sessions list row of a saved session (0-based, for the list's event).
local function rowOf(id)
    for i, row in ipairs(agent.sessionRows()) do
        if (row.saved and row.saved.id == id) or (row.tab and row.tab.session.resume == id) then
            return i - 1
        end
    end
    return nil
end

step(1500, "write two long sessions", function()
    shell.show("agent")
    writeLong(LONG[1], "First")
    writeLong(LONG[2], "Second")
end)

step(200, "list them", function()
    measure("list the sessions", function()
        agent.refreshSessions(true)
    end)
end)

step(300, "open the first from the list", function()
    check("both are listed", rowOf(LONG[1]) ~= nil and rowOf(LONG[2]) ~= nil)
    measure("open a long session", function()
        gitgud.emit("AgentSessionList.selected", tostring(rowOf(LONG[1])))
    end)
end)

step(500, "it's shown", function()
    local items = agent.items()
    check("its latest messages are shown", #items == 41 and agent.session().resume == LONG[1])
    check("its last message is there", items[#items].text == "Done: the build passes now (turn " .. TURNS .. ").")
    check("earlier ones behind a button", items[1].kind == "note"
        and gitgud.getRect(items[1].name .. "Action") ~= nil)
    shown, shownTop = items[2], items[2].top
    gitgud.setScroll("AgentTranscript", 0)
end)

step(200, "show earlier ones", function()
    local items = agent.items()
    measure("show earlier messages", function()
        local x, y, w, h = gitgud.getRect(items[1].name .. "Action")
        gitgud.simulateClick(x + w / 2, y + h / 2, "left")
    end)
end)

step(500, "more are shown", function()
    local items = agent.items()
    check("more were drawn above", #items == 101 and items[62] == shown and items[1].kind == "note")
    check("what was on screen stays", shown.top ~= nil
        and math.abs(gitgud.getScroll("AgentTranscript") - (shown.top - shownTop)) < 4)
    -- Busy, so it goes on in the background when another is opened.
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("wait")
    gitgud.simulateKey("enter")
end)

step(1200, "a turn runs", function()
    check("the first session works", agent.session().turn == true)
    measure("open another long session", function()
        gitgud.emit("AgentSessionList.selected", tostring(rowOf(LONG[2])))
    end)
end)

step(500, "the other is shown", function()
    check("the second session is shown", agent.session().resume == LONG[2])
    local back = nil
    for i, row in ipairs(agent.sessionRows()) do
        if row.tab and row.tab.session.turn then
            back = i - 1
        end
    end
    check("the busy one is listed as live", back ~= nil)
    measure("switch back to the busy one", function()
        gitgud.emit("AgentSessionList.selected", tostring(back))
    end)
end)

step(500, "back on the first", function()
    check("the first session is shown again", agent.session().turn == true)
    measure("a new session", function()
        agent.newSession()
    end)
end)

step(300, "done", function()
    for _, tab in ipairs(agent.tabs()) do
        if tab.session.name then
            gitgud.agentStop(tab.session.name)
        end
    end
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
