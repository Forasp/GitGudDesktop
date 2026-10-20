--- tests/ui/bragi-hotreload.lua: a hot-reload keeps the running sessions
--. Against the fake claude (tests/fake_claude.cpp).
--
-- The harness runs this script again after every reload (like main.lua),
-- so it goes in phases, carried across with gitgud.keepForReload:
--
--   1  voice listening (a stub backend), Bragi (the master conversation)
--      answered once, a turn that never ends ("wait") in a conversation of
--      another project, a turn running ("work") in one conversation and a
--      permission card waiting ("tool") in another; then a reload asked
--      for (emit "app.reload")
--   2  the same session processes, every conversation back (Bragi still
--      Bragi, the other project's still in its folder), the card
--      answerable, the turn finishing where it was, a new message reaching
--      the same session, voice still listening, its helpers the same
--      processes; then two resource files rewritten half a second apart
--   3  one reload for both (the watcher waits for the files to settle),
--      the sessions still the same
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT,
-- GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."
local KEY = "test.hotreload"

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local projects = require("bragi.projects")
local settings = require("core.settings")
local shell = require("bragi.shell")
local voice = require("bragi.voice")

settings.set("bragi.claudeProgram", fake)

local state = gitgud.jsonDecode(gitgud.takeKept(KEY) or "")
if type(state) ~= "table" then
    state = { phase = 1 }
end
local function keepState()
    gitgud.keepForReload(KEY, gitgud.jsonEncode(state))
end

-- Voice through a stub: it listens once asked to, and says so after a
-- reload, as the real backend (in C++) does.
local listening = state.listening == true
-- Whether a speech engine is there (none is built in yet).
local engineOn = true
voice.backend = {
    available = function()
        return engineOn
    end,
    listen = function()
        listening = true
        return true
    end,
    stop = function()
        listening = false
    end,
    send = function()
        return true
    end,
    lookback = function()
        return true
    end,
    speak = function()
        return true
    end,
    health = function(onDone)
        onDone({ status = "ok", sttProvider = "stt-engine", ttsProvider = "tts-engine" })
    end,
    speakPrepare = function()
        return true
    end,
    speakStop = function()
    end,
    cancel = function()
        return true
    end,
    playing = function()
        return nil
    end,
    listening = function()
        return listening
    end,
    config = function()
        return true
    end,
}

local steps = {}
local function step(delay, label, fn)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn }
end
local function run(i)
    local s = steps[i]
    if not s then
        return
    end
    gitgud.after(s.delay, function()
        print("[ui-test] " .. state.phase .. "." .. i .. ": " .. s.label)
        local ok, err = pcall(s.fn)
        if not ok then
            print("[ui-test] step " .. i .. " failed: " .. tostring(err))
            check("phase " .. state.phase .. " step " .. i .. " (" .. s.label .. ") ran without errors", false)
        end
        run(i + 1)
    end)
end
local function shot(name)
    gitgud.screenshot(OUT .. "/hotreload-" .. name .. ".png")
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
local function tabOf(name)
    for _, tab in ipairs(agent.tabs()) do
        if tab.session.name == name then
            return tab
        end
    end
    return nil
end
local function lastOf(tab, kind)
    for i = #tab.items, 1, -1 do
        if tab.items[i].kind == kind then
            return tab.items[i]
        end
    end
    return nil
end
local function has(tab, kind, needle)
    for _, item in ipairs(tab.items) do
        if item.kind == kind and (item.text or ""):find(needle, 1, true) then
            return true
        end
    end
    return false
end
local function pid(name)
    local info = gitgud.agentInfo(name)
    return info and info.running and info.pid or nil
end
--- The running helper sessions (lean): name -> pid.
local function helperPids()
    local out = {}
    for _, info in ipairs(gitgud.agentList()) do
        if info.running and info.options.lean then
            out[info.name] = info.pid
        end
    end
    return out
end
--- Rewrite a resource file as it is (its time changes, as a copy's would).
local function touch(rel)
    local path = gitgud.appDir() .. "/resources/uis/bragi/" .. rel
    local f = io.open(path, "rb")
    local body = f and f:read("a")
    if f then
        f:close()
    end
    f = body and io.open(path, "wb")
    if f then
        f:write(body)
        f:close()
    end
    return f ~= nil
end

if state.phase == 1 then
    step(1500, "listen", function()
        shell.show("agent")
        if voice.state() == "off" then
            voice.toggle()
            gitgud.emit("voice.ready", "{}")
        end
    end)
    step(500, "Bragi", function()
        require("bragi.master").open()
        say("hello")
    end)
    step(1500, "a conversation in another project", function()
        check("Bragi answered", agent.current().master == true and lastOf(agent.current(), "assistant") ~= nil)
        state.master = agent.session().name
        state.other = (gitgud.configPath() .. "/hr-other"):gsub("\\", "/")
        gitgud.makeDir(state.other)
        agent.newSession({ cwd = state.other })
        say("wait")
    end)
    step(1500, "a long turn", function()
        check("the other project's turn runs", agent.session().turn == true)
        state.otherName = agent.session().name
        agent.newSession()
        check("voice is listening", voice.state() == "listening")
        say("work")
    end)
    step(1500, "a second conversation asks a permission", function()
        check("the turn runs", agent.session().turn == true)
        state.work = agent.session().name
        agent.newSession()
        say("tool")
    end)
    step(2000, "reload while both wait", function()
        local card = nil
        for _, item in ipairs(agent.items()) do
            if item.kind == "permission" then
                card = item
            end
        end
        check("the permission card waits", card ~= nil and card.answer == nil)
        state.tool = agent.session().name
        state.workPid, state.toolPid = pid(state.work), pid(state.tool)
        state.helpers = helperPids()
        check("both sessions run", state.workPid ~= nil and state.toolPid ~= nil and state.work ~= state.tool)
        check("helpers run while listening", next(state.helpers) ~= nil)
        check("the work turn is still going", tabOf(state.work).session.turn == true)
        state.workItems = #tabOf(state.work).items
        state.phase, state.listening = 2, listening
        shot("before")
        keepState()
        gitgud.emit("app.reload")
    end)
elseif state.phase == 2 then
    step(300, "after the reload", function()
        shot("after")
        local work, tool = tabOf(state.work), tabOf(state.tool)
        check("every conversation came back", work ~= nil and tool ~= nil and #agent.tabs() == 4)
        local bragi, other = tabOf(state.master), tabOf(state.otherName)
        check("Bragi is still Bragi", bragi ~= nil and bragi.master == true and bragi.title == "Bragi"
            and bragi.sessionName == state.master and type(bragi.allowTool) == "function"
            and (bragi.extraPrompt or ""):find("master conversation", 1, true) ~= nil
            and projects.key(bragi.cwd) == projects.key(projects.masterDir()))
        check("pinned on top", agent.sessionRows()[1] and agent.sessionRows()[1].master == true)
        check("the other project's conversation keeps its folder", other ~= nil
            and projects.key(other.cwd) == projects.key(state.other)
            and projects.key(other.session.cwd) == projects.key(state.other) and other.session.turn == true)
        local listed = false
        for _, row in ipairs(agent.sessionRows()) do
            listed = listed or (row.tab == other and projects.key(row.group.cwd) == projects.key(state.other))
        end
        check("listed under its project", listed)
        check("the same conversation is shown", agent.session().name == state.tool)
        check("the same processes", pid(state.work) == state.workPid and pid(state.tool) == state.toolPid)
        print("[ui-test] work items " .. state.workItems .. " -> " .. (work and #work.items or -1))
        for _, item in ipairs(work and work.items or {}) do
            print("[ui-test]   " .. item.kind .. " " .. tostring(item.text or item.title))
        end
        check("the work conversation is all there", work ~= nil and #work.items >= state.workItems
            and has(work, "user", "work"))
        check("its turn still runs", work ~= nil and work.session.turn == true and work.session.running == true)
        local card = tool and lastOf(tool, "permission")
        check("the permission card is back, waiting", card ~= nil and card.answer == nil and card.requestId ~= nil)
        check("voice still listens", voice.state() == "listening")
        local same = true
        for name, p in pairs(state.helpers) do
            same = same and pid(name) == p
        end
        check("the helpers are the same processes", same)
    end)
    step(300, "allow the card", function()
        local card = lastOf(tabOf(state.tool), "permission")
        clickWidget(card.inner .. "Allow")
        check("answered", card.answer == "Allowed")
    end)
    step(1500, "the tool ran", function()
        local tool = tabOf(state.tool)
        local step_ = lastOf(tool, "step")
        check("the step has its result", step_ ~= nil and step_.result ~= nil)
        check("the turn ended", tool.session.turn == false)
        say("hello")
    end)
    step(2500, "a new message reaches the same session", function()
        local tool = tabOf(state.tool)
        local reply = lastOf(tool, "assistant")
        print("[ui-test] reply " .. tostring(reply and reply.text))
        check("the reply came", reply ~= nil and reply.text == "Hello")
        check("from the same process", pid(state.tool) == state.toolPid)
        local work = tabOf(state.work)
        check("the work turn finished where it was", work.session.turn == false
            and has(work, "assistant", "Worked through it."))
        shot("done")
    end)
    step(300, "rewrite two resource files, half a second apart", function()
        state.phase = 3
        state.reloads = 0
        keepState()
        check("a layout rewritten", touch("layouts/bragi/chrome.xml"))
    end)
    step(500, "and a script", function()
        check("a script rewritten", touch("scripts/core/sprites.lua"))
    end)
    step(10000, "no reload came", function()
        check("the file change reloaded the UI", false)
        gitgud.emit("window.close", "")
    end)
elseif state.phase == 3 then
    state.reloads = (state.reloads or 0) + 1
    keepState() -- a second reload would count 2
    step(300, "after the file reload", function()
        check("the sessions are still the same", pid(state.work) == state.workPid and pid(state.tool) == state.toolPid)
        check("both conversations came back again", tabOf(state.work) ~= nil and tabOf(state.tool) ~= nil)
        check("voice still listens", voice.state() == "listening")
    end)
    step(4000, "one reload for both files", function()
        check("one reload, not one per file", state.reloads == 1)
        gitgud.takeKept(KEY)
        gitgud.emit("window.close", "")
    end)
end

run(1)
