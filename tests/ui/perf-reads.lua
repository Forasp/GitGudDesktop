--- tests/ui/perf-reads.lua: how long Bragi's master takes to read saved
-- transcripts, for the profiler (not a pass/fail test). Each line prints
-- "[perf-step] <name> <ms>": the master's own check that its saved session
-- is still there (savedId), with no limit and with one entry; an asked
-- recap of the followed conversations that aren't open
-- (master.followedSaved), first and again; and bragi_read_conversation on
-- one of them. First calls read the files; later ones find them cached.
--
-- Run it like tests/ui/perf-bragi.lua (docs/PROFILING.md) on a copy
-- of real data (the master's transcript and its followed conversations).

local master = require("bragi.master")
local projects = require("bragi.projects")
local settings = require("core.settings")

local function timed(name, fn)
    local t0 = gitgud.now()
    local ok, result = pcall(fn)
    print(string.format("[perf-step] %-40s %8.1f ms  %s", name, gitgud.now() - t0,
        ok and tostring(result or "") or ("ERROR " .. tostring(result))))
end

local steps = {}
local function after(ms, fn)
    steps[#steps + 1] = { ms = ms, fn = fn }
end
local function run(i)
    local s = steps[i]
    if s then
        gitgud.after(s.ms, function()
            s.fn()
            run(i + 1)
        end)
    end
end

local dir = projects.masterDir()
local id = settings.get("bragi.masterSession", "")
local follows = gitgud.jsonDecode(settings.get("bragi.masterFollows", "")) or {}

after(3000, function()
    print("[perf-step] master transcript " .. id .. ", " .. #follows .. " followed")
    timed("savedId check, no limit (cold)", function()
        return #gitgud.agentHistory(dir, id) .. " entries"
    end)
    timed("savedId check, no limit (cached)", function()
        return #gitgud.agentHistory(dir, id) .. " entries"
    end)
    timed("savedId check, 1 entry (cold)", function()
        return #gitgud.agentHistory(dir, id, 1) .. " entries"
    end)
    timed("savedId check, 1 entry (cached)", function()
        return #gitgud.agentHistory(dir, id, 1) .. " entries"
    end)
end)
after(500, function()
    timed("recap: followedSaved (cold)", function()
        return #master.followedSaved() .. " described"
    end)
    timed("recap: followedSaved (cached)", function()
        return #master.followedSaved() .. " described"
    end)
end)
after(500, function()
    local f = follows[1]
    if f then
        timed("bragi_read_conversation", function()
            local out = master.handle({ session = master.SESSION, tool = "bragi_read_conversation",
                arguments = { id = f.id, exchanges = 3 } })
            return #tostring(out) .. " chars"
        end)
    end
end)
after(500, function()
    gitgud.emit("window.close", "")
end)
run(1)
