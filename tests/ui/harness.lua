--- tests/ui/harness.lua: steps for the UI test scripts that go on as soon
-- as they can (the visual tests waited a second or two
-- between every action).
--
--   local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
--   local check, step = harness.check, harness.step
--   step(1500, "streamed reply", function()
--       check("the reply is drawn", ...)   -- what the step waits for
--       say("next")                         -- what it does once it's there
--   end)
--   harness.run()
--
-- A step's delay is the longest it waits. Its checks (with the lines that
-- only read: `local x = ...`, plain assignments, `if` and `for` blocks of
-- those) are tried every frame, in a sandbox and without printing, with the
-- statements that act left out. Once they all pass, the clock skips ahead
-- to the step's time (gitgud.skipTime: app timers due before then fire
-- first, in order, and gitgud.now() reads as if the delay had passed) and
-- the step runs for real. Until then nothing is skipped: a step whose
-- checks don't pass by its time keeps trying until the old fixed waits
-- would have reached it (so a step whose checks only pass after its own
-- actions waits at least its delay, and the whole script never takes
-- longer than before), then runs and reports what failed. A step with no checks, or one passed { full = true }, waits its
-- whole delay. GITGUD_HARNESS=full makes every step wait.

local harness = {}

local steps = {}
local probing = nil      -- { n = checks passed } while a step is tried
local NOT_YET = {}       -- the error a failed check raises while trying
local POLL_MS = 15
local canSkip = gitgud.skipTime ~= nil and gitgud.nextTimer ~= nil
-- GITGUD_HARNESS=full waits every whole delay (as before); =trace also
-- prints how each step went.
local mode = os.getenv("GITGUD_HARNESS") or ""
if mode == "full" then
    canSkip = false
end
local trace = mode == "trace"
local skipped = 0        -- ms skipped so far: gitgud.now() - skipped is real time
local function skip(ms)
    skipped = skipped + ms
    gitgud.skipTime(ms)
end

--- Print a check's result (or, while a step is tried, stop it if it fails).
function harness.check(label, ok)
    if probing then
        if not ok then
            error(NOT_YET, 0)
        end
        probing.n = probing.n + 1
        return
    end
    print("[check] " .. (ok and "PASS " or "FAIL ") .. label)
end

--- Add a step.
-- @param delay  ms to wait at most before it runs
-- @param label  what it does
-- @param fn     the step
-- @param opts   { full = true }: always wait the whole delay; { clock = true }:
--               it waits only on the app's own clock (an echo window, a
--               timer), so skip ahead at once
function harness.step(delay, label, fn, opts)
    steps[#steps + 1] = { delay = delay, label = label, fn = fn, full = opts and opts.full,
        clock = opts and opts.clock }
end

-- ===================================================================
-- Reading a step's checks
-- ===================================================================

local sources = {}
local function sourceLines(path)
    if sources[path] == nil then
        local lines = false
        local f = io.open(path, "rb")
        if f then
            lines = {}
            for line in (f:read("a"):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
                lines[#lines + 1] = line
            end
            f:close()
        end
        sources[path] = lines
    end
    return sources[path] or nil
end

local function indentOf(line)
    return #line:match("^%s*")
end

local function isQuiet(line)
    local t = line:match("^%s*(.-)%s*$")
    return t == "" or t:sub(1, 2) == "--"
end

--- A line with its strings and comment taken out.
local function code(line)
    line = line:gsub('\\.', "")
    line = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
    return (line:gsub("%-%-.*$", ""))
end

local function balance(line)
    local n = 0
    for c in code(line):gmatch("[%(%)%{%}%[%]]") do
        n = n + ((c == "(" or c == "{" or c == "[") and 1 or -1)
    end
    return n
end

--- Does the line leave its statement open (an operator at its end)?
local function trailing(line)
    local t = code(line):match("^(.-)%s*$")
    return t:match("[,=%+%-%*/%.<>~%(%{%[]$") ~= nil or t:match("%f[%w]and$") ~= nil
        or t:match("%f[%w]or$") ~= nil or t:match("%f[%w]not$") ~= nil
end

-- Calls that always act, wherever they are.
local ACTS = { "io%.open", "io%.write", ":write%(", "os%.execute", "os%.remove", "os%.rename", "gitgud%.emit%(",
    "gitgud%.simulate", "gitgud%.focus", "settings%.set%(" }

--- Does any line from first to last call something that acts?
local function callsActs(lines, first, last)
    for k = first, last do
        local c = code(lines[k])
        for _, pattern in ipairs(ACTS) do
            if c:find(pattern) then
                return true
            end
        end
    end
    return false
end

local READ_LINE = { "^check%(", "^local ", "^end", "^else", "^elseif ", "^if .* then$", "^for .* do$",
    "^[%a_][%w_]*%s*=[^=]", "^[%a_][%w_]*%s*=$" }

--- Do the lines of a block (after its first) only read and check?
local function blockReads(lines, first, last, base)
    local depth, open = balance(lines[first]), trailing(lines[first])
    for k = first + 1, last do
        local line = lines[k]
        if not isQuiet(line) then
            local t = line:match("^%s*(.-)%s*$")
            if not (depth > 0 or open) then
                if indentOf(line) <= base and not (t:match("^end") or t:match("^else")) then
                    return false
                end
                local ok = false
                for _, pattern in ipairs(READ_LINE) do
                    ok = ok or t:match(pattern) ~= nil
                end
                if not ok then
                    return false
                end
            end
            depth = depth + balance(line)
            open = trailing(line)
        end
    end
    return true
end

--- The probe of a step: its checks and reads, compiled on their own.
-- @return a function that runs them in a fresh sandbox, or nil
local function analyse(s)
    if s.probe ~= nil then
        return s.probe or nil
    end
    s.probe = false
    local info = debug.getinfo(s.fn, "S")
    local lines = info.source:sub(1, 1) == "@" and sourceLines(info.source:sub(2))
    if not lines or info.linedefined <= 0 or info.lastlinedefined <= info.linedefined + 1 then
        return nil
    end
    -- Only functions whose header and `end` lines hold nothing else.
    if not code(lines[info.linedefined]):match("function%s*%(%s*%)%s*$")
        or not lines[info.lastlinedefined]:match("^%s*end[%)%s,]*$") then
        return nil
    end
    local first, last = info.linedefined + 1, info.lastlinedefined - 1
    local base = nil
    for k = first, last do
        if not isQuiet(lines[k]) then
            base = indentOf(lines[k])
            break
        end
    end
    if not base then
        return nil
    end

    -- Statements at the function's own indent: the ones that only read
    -- and check are kept, the ones that act are left out (blank lines, so
    -- errors keep their line numbers).
    local keep, checks, acts = {}, 0, 0
    local firstAct, before = nil, 0 -- the first statement that acts; checks before it
    local k = first
    while k <= last do
        local line = lines[k]
        if isQuiet(line) then
            k = k + 1
        else
            if indentOf(line) ~= base then
                return nil
            end
            local t = line:match("^%s*(.-)%s*$")
            -- The statement runs on while lines are deeper, open, or close a block.
            local e = k
            local depth, open = balance(line), trailing(line)
            while e < last do
                local nextLine = lines[e + 1]
                local nt = nextLine:match("^%s*(.-)%s*$")
                if not (isQuiet(nextLine) or depth > 0 or open or indentOf(nextLine) > base
                        or nt:match("^end") or nt:match("^else") or nt:match("^until")) then
                    break
                end
                e = e + 1
                if not isQuiet(nextLine) then
                    depth = depth + balance(nextLine)
                    open = trailing(nextLine)
                end
            end
            local reads
            if t:match("^check%(") or t:match("^local ") or t:match("^[%a_][%w_]*%s*=[^=]")
                    or t:match("^[%a_][%w_]*%s*=$") then
                reads = true
            elseif t:match("^if ") or t:match("^for ") then
                reads = blockReads(lines, k, e, base)
            else
                reads = false
            end
            if reads and callsActs(lines, k, e) then
                reads = false
            end
            if reads then
                for kk = k, e do
                    keep[kk] = true
                    local _, n = code(lines[kk]):gsub("%f[%w_]check%(", "")
                    checks = checks + n
                    before = before + (firstAct and 0 or n)
                end
            else
                acts = acts + 1
                firstAct = firstAct or k
            end
            k = e + 1
        end
    end
    if checks == 0 then
        return nil
    end

    local fn = s.fn
    local function upvalue(name)
        local i = 1
        while true do
            local n, v = debug.getupvalue(fn, i)
            if n == nil then
                return false
            elseif n == name then
                return true, v
            end
            i = i + 1
        end
    end
    local function compile(upto)
        local body = {}
        for kk = first, last do
            body[#body + 1] = (keep[kk] and kk < upto) and lines[kk] or ""
        end
        local src = string.rep("\n", first - 1) .. table.concat(body, "\n")
        local chunk = load(src, "=" .. info.short_src .. " (probe)", "t", {})
        if not chunk then
            return nil
        end
        return function()
            debug.setupvalue(chunk, 1, setmetatable({}, { __index = function(_, name)
                local found, v = upvalue(name)
                if found then
                    return v
                end
                return _G[name]
            end }))
            return chunk()
        end
    end
    local probe = compile(last + 1)
    if not probe then
        return nil
    end
    -- The checks before it acts: at its own time, a step whose checks only
    -- pass after its actions runs once these do (as it always ran then).
    s.prefix = before > 0 and compile(firstAct or (last + 1)) or false
    s.probe = probe
    s.checks, s.acts = checks, acts
    return probe
end

--- Do the step's checks pass now?
local function ready(probe)
    probing = { n = 0 }
    local ok = pcall(probe)
    local n = probing.n
    probing = nil
    return ok and n > 0
end

-- ===================================================================
-- Running
-- ===================================================================

--- Run the steps from the first.
-- @param opts  { prefix = fn() -> text before each step's number }
function harness.run(opts)
    local prefix = opts and opts.prefix
    local function realNow()
        return gitgud.now() - skipped
    end
    -- Where the old fixed waits would have been by now: a step that isn't
    -- ready at its own time may keep waiting until then (the time saved
    -- earlier), so slow things outside the app (the fake claude's own
    -- sleeps) get as long as they always did.
    local schedule = realNow()
    local function run(i)
        local s = steps[i]
        if not s then
            return
        end
        local realStarted = realNow()
        schedule = schedule + s.delay
        local function commit()
            print("[ui-test] " .. (prefix and (prefix() .. " ") or "") .. i .. ": " .. s.label)
            if trace then
                print(string.format("[harness] step %d: %s, %d of %d ms waited", i,
                    s.clock and "the app's clock" or s.probe and (s.checks .. " checks, " .. s.acts .. " left out")
                        or "no checks",
                    realNow() - realStarted, s.delay))
            end
            local ok, err = pcall(s.fn)
            if not ok then
                print("[ui-test] step " .. i .. " failed: " .. tostring(err))
                harness.check("step " .. i .. " (" .. s.label .. ") ran without errors", false)
            end
            run(i + 1)
        end
        local probe = canSkip and not s.full and (s.clock and function()
            harness.check("", true)
        end or analyse(s))
        if not probe then
            gitgud.after(s.delay, commit)
            return
        end
        local deadline = gitgud.now() + s.delay
        local latest = math.max(realStarted + s.delay, schedule)
        local function tick()
            local now = gitgud.now()
            if ready(probe) then
                local n = gitgud.nextTimer()
                if now >= deadline then
                    commit()
                elseif n >= 0 and now + n < deadline then
                    -- Let the app's next timer fire first, then look again.
                    skip(n)
                    gitgud.after(1, tick)
                else
                    skip(deadline - now)
                    commit()
                end
            elseif now >= deadline and (not s.prefix or ready(s.prefix)) then
                commit() -- its checks wait on what it does: run it at its time, as before
            elseif realNow() >= latest then
                commit() -- never got there: run it to report what failed
            else
                gitgud.after(POLL_MS, tick)
            end
        end
        gitgud.after(math.min(POLL_MS, s.delay), tick)
    end
    run(1)
end

return harness
