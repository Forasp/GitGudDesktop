-- tests/ui/agent.lua: the Claude Code session bindings in the running app,
-- against the fake claude the engine tests use (tests/fake_claude.cpp),
-- never the real one.
--
-- Run it like bragi.lua (scratch APPDATA and LOCALAPPDATA, a repository
-- from make-testrepo.ps1, GITGUD_SCRIPT pointing here), with
-- GITGUD_TEST_CLAUDE set to build\release\bin\gitgud_test_claude.exe.
-- Prints "[check] ..." lines for the log.

local function check(label, ok)
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

local finished = false
local function finish()
    if finished then
        return
    end
    finished = true
    gitgud.agentStop("t")
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if not fake then
    check("GITGUD_TEST_CLAUDE is set", false)
    finish()
    return
end

-- Every event of session "t", decoded, in order.
local seen = {}
local waiters = {}
local function count(kind)
    local n = 0
    for _, e in ipairs(seen) do
        n = n + (e.kind == kind and 1 or 0)
    end
    return n
end
local function last(kind)
    for i = #seen, 1, -1 do
        if seen[i].kind == kind then
            return seen[i].detail
        end
    end
end
-- Run fn once `n` events of `kind` have arrived.
local function when(kind, n, fn)
    waiters[#waiters + 1] = { kind = kind, n = n, fn = fn }
end
local function settle()
    for i = #waiters, 1, -1 do
        local w = waiters[i]
        if count(w.kind) >= w.n then
            table.remove(waiters, i)
            w.fn()
        end
    end
end

for _, kind in ipairs({ "init", "block", "text", "message", "tool", "toolResult", "permission", "result", "stderr", "exit" }) do
    gitgud.on("agent." .. kind, function(json)
        local detail = gitgud.jsonDecode(json)
        if detail and detail.session == "t" then
            seen[#seen + 1] = { kind = kind, detail = detail }
            settle()
        end
    end)
end

check("agentInfo is nil before a start", gitgud.agentInfo("t") == nil)
check("agentSend needs a running session", gitgud.agentSend("t", "hello") == nil)
local missing, why = gitgud.agentStart("t", { program = "gitgud-no-such-claude" })
check("agentStart reports a missing program", missing == nil and why ~= nil and why ~= "")

check("agentStart runs the fake", gitgud.agentStart("t", { program = fake, model = "fake-opus" }) == true)
check("a second start under the name is refused", gitgud.agentStart("t", { program = fake }) == nil)
check("agentInfo says it runs", gitgud.agentInfo("t").running == true)
check("agentInterrupt between turns does nothing", gitgud.agentInterrupt("t") == nil)
check("agentSend", gitgud.agentSend("t", "hello") == true)

when("result", 1, function()
    local init = last("init")
    check("init carries the model", init and init.model == "fake-opus")
    local streamed = ""
    for _, e in ipairs(seen) do
        if e.kind == "text" then
            streamed = streamed .. e.detail.text
        end
    end
    check("text streams in", streamed == "Hello")
    check("the whole message follows", last("message").text == "Hello")
    check("agentInfo has the session id", gitgud.agentInfo("t").sessionId == "fake-session")
    gitgud.agentSend("t", "args")
end)

when("result", 2, function()
    -- No mcpConfig: the app's Git tools (a config file of its own for
    -- gitgud-mcp, naming the session).
    local args = last("message").text
    local config = args:match("%-%-mcp%-config\n([^\n]+)")
    check("sessions get the app's MCP config", config ~= nil and config:find("%-tools%-%d+%-s%-t%.json$") ~= nil)
    local file = config and io.open(config, "r")
    local text = file and file:read("a") or ""
    if file then
        file:close()
    end
    check("the MCP config runs gitgud-mcp", text:find("gitgud%-mcp") ~= nil and text:find("%-%-pipe") ~= nil)
    gitgud.agentSend("t", "tool")
end)

when("permission", 1, function()
    local ask = last("permission")
    check("a permission request names the tool", ask.tool == "Bash" and ask.input.command == "echo hi")
    check("agentInfo shows it waiting", gitgud.agentInfo("t").pendingPermission == ask.requestId)
    check("agentRespond", gitgud.agentRespond("t", ask.requestId, true) == true)
    check("a second answer is refused", gitgud.agentRespond("t", ask.requestId, true) == nil)
end)

when("result", 3, function()
    check("the allowed tool ran", last("toolResult").text == "ran echo hi")
    gitgud.agentSend("t", "wait")
end)

when("tool", 2, function()
    check("agentInterrupt during a turn", gitgud.agentInterrupt("t") == true)
end)

when("result", 4, function()
    check("the turn ended interrupted", last("result").interrupted == true)
    check("agentSetModel", gitgud.agentSetModel("t", "sonnet") == true)
    gitgud.agentStop("t")
end)

when("exit", 1, function()
    check("agentStop ends it", last("exit").code == 0 and gitgud.agentInfo("t").running == false)
    finish()
end)

gitgud.after(20000, function()
    check("the session finished in time", finished)
    finish()
end)
