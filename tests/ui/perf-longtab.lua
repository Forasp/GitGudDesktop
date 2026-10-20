--- tests/ui/perf-longtab.lua: a live conversation that has grown long (as
-- the master conversation does over a day), for the profiler (not a
-- pass/fail test). It adds PERF_ITEMS items (default 1500) to the shown
-- conversation, then times what redraws them: laying out again, a narrower
-- column (the session panel opening, the window resized), and a hot reload.
-- Prints "[perf-step] <name> <ms>".
--
-- Run it like perf-bragi.lua.

local agent = require("bragi.agent")
local shell = require("bragi.shell")
local N = tonumber(os.getenv("PERF_ITEMS") or "") or 1500

local REPLY = table.concat({
    "Here is what I found in `src/agent/ClaudeTranscripts.cpp`: the reader goes back a block at a time, "
        .. "and **each line** is parsed before it knows whether it's kept.",
    "",
    "- the first point, with a path docs/BUILDING.md",
    "- the second point",
    "",
    "```cpp",
    "for (auto& line : lines) { Parse(line); }",
    "```",
    "",
    "That's why it's slow on long sessions.",
}, "\n")

local function timed(name, fn)
    local t0 = gitgud.now()
    local ok, err = pcall(fn)
    print(string.format("[perf-step] %-34s %8.0f ms%s", name, gitgud.now() - t0, ok and "" or ("  ERROR " .. tostring(err))))
end

local queue = {}
local function after(ms, name, fn)
    queue[#queue + 1] = { ms = ms, name = name, fn = fn }
end
local function run(i)
    local s = queue[i]
    if s then
        gitgud.after(s.ms, function()
            timed(s.name, s.fn)
            run(i + 1)
        end)
    end
end

if gitgud.takeKept("perf.phase") == "reloaded" then
    after(2000, "after reload: idle", function() end)
    after(500, "stop capture", function()
        gitgud.profileStop()
    end)
    after(6000, "close", function()
        gitgud.emit("window.close", "")
    end)
    run(1)
    return
end

after(2500, "show the Agent view", function()
    shell.show("agent")
end)
local added = 0
for batch = 1, N / 100 do
    after(50, "add 100 items (to " .. batch * 100 .. ")", function()
        for i = 1, 100 do
            added = added + 1
            local kind = added % 3 == 0 and "assistant" or (added % 3 == 1 and "user" or "note")
            agent.addMessage(kind, kind == "assistant" and REPLY or ("Message " .. added .. ", asking about the reader."))
        end
    end)
end
after(1000, "lay out again", function()
    agent.relayout()
end)
after(1000, "open the session panel (narrower)", function()
    require("bragi.sidepanel").toggle()
end)
after(2000, "close the session panel (wider)", function()
    require("bragi.sidepanel").toggle()
end)
after(2000, "hot reload", function()
    gitgud.keepForReload("perf.phase", "reloaded")
    gitgud.emit("app.reload", "")
end)
run(1)
