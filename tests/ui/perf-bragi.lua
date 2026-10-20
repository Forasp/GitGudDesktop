--- tests/ui/perf-bragi.lua: a scripted session of heavy use, for the
-- profiler (not a pass/fail test). It opens the saved conversations named in
-- PERF_IDS (comma-separated, biggest first), switches between them, streams
-- long replies into several at once, then hot-reloads with all of them open.
-- Each step prints "[perf-step] <name> <ms>" (the time its own call took);
-- the frames in between show in the capture (GITGUD_PROFILE=1).
--
-- Run it with GITGUD_UI=bragi, scratch APPDATA, LOCALAPPDATA and
-- CLAUDE_CONFIG_DIR (a copy of real transcripts), GITGUD_TEST_CLAUDE and
-- bragi.claudeProgram set to tests' fake Claude, a scratch repository as the
-- argument.

local agent = require("bragi.agent")
local shell = require("bragi.shell")
local repoPath = require("core.repo").state().path

local function timed(name, fn)
    local t0 = gitgud.now()
    local ok, err = pcall(fn)
    print(string.format("[perf-step] %-34s %8.0f ms%s", name, gitgud.now() - t0, ok and "" or ("  ERROR " .. tostring(err))))
end

local ids = {}
for id in (os.getenv("PERF_IDS") or ""):gmatch("[^,]+") do
    ids[#ids + 1] = id
end

local queue = {}
local function after(ms, name, fn)
    queue[#queue + 1] = { ms = ms, name = name, fn = fn }
end
local function run(i)
    local s = queue[i]
    if not s then
        return
    end
    gitgud.after(s.ms, function()
        if s.fn then
            timed(s.name, s.fn)
        end
        run(i + 1)
    end)
end

if gitgud.takeKept and gitgud.takeKept("perf.phase") == "reloaded" then
    -- After the hot reload: let the restore settle, then stop the capture.
    after(3000, "after reload: idle", function() end)
    after(1000, "stop capture", function()
        gitgud.profileStop()
    end)
    after(8000, "close", function()
        gitgud.emit("window.close", "")
    end)
    run(1)
    return
end

after(2500, "show the Agent view", function()
    shell.show("agent")
end)
after(500, "list conversations (refreshSessions)", function()
    agent.refreshSessions(true)
end)
for i, id in ipairs(ids) do
    after(400, "open saved #" .. i .. " " .. id:sub(1, 8), function()
        agent.resume(id, { cwd = repoPath })
    end)
end
for round = 1, 3 do
    for i = 1, #agent.tabs() + #ids do
        after(150, "switch tab r" .. round .. " #" .. i, function()
            local tabs = agent.tabs()
            local tab = tabs[(i - 1) % #tabs + 1]
            if tab then
                agent.showTab(tab)
            end
        end)
    end
end
after(500, "list conversations again", function()
    agent.refreshSessions(true)
end)
-- Long replies streaming into three conversations at once, one of them shown.
after(500, "send long replies (3 at once)", function()
    local tabs = agent.tabs()
    for i = 1, math.min(3, #tabs) do
        agent.sendTo(tabs[#tabs - i + 1], "long 40 8")
    end
end)
for i = 1, 60 do
    after(500, "streaming " .. i, function() end)
end
after(500, "send a long reply to the shown one", function()
    agent.send("long 60 5")
end)
for i = 1, 40 do
    after(500, "streaming shown " .. i, function() end)
end
after(1000, "hot reload with everything open", function()
    gitgud.keepForReload("perf.phase", "reloaded")
    gitgud.emit("app.reload", "")
end)
run(1)
