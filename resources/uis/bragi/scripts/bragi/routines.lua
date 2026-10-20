--- bragi/routines.lua: scheduled runs, so routines don't need
-- another desktop app. Settings shows them as the Routines section.
--
-- A routine is a prompt run on a schedule in a folder: every `every`
-- minutes while the app is open. One that came due while the app was
-- closed runs once at the next start. Each run is its own Claude Code
-- session (bragi.claudeProgram), told it runs unattended; it's saved like
-- any session, so the Agent view's list has it. Permission requests are
-- denied (nobody is there to answer) and noted in the routine's status;
-- "Edit files without asking" runs it in acceptEdits mode.
--
-- Stored in bragi/routines.json in the config folder:
--   { id, name, folder, every, prompt, enabled, acceptEdits,
--     lastRun, nextRun (seconds since 1970), lastStatus (ok, failed,
--     asked), lastSummary }
--
-- Public API: routines.list(), routines.add(fields), routines.update(id, fields),
-- routines.remove(id), routines.runNow(id), routines.tick(), routines.running(id),
-- routines.cards() (for bragi/settings.lua)

local settings = require("core.settings")
local text = require("core.text")

local routines = { name = "bragi.routines" }

local FILE = "bragi/routines.json"
local TICK_MS = 30000
local SUMMARY = 160         -- characters of the last answer kept

local UNATTENDED = "This is an unattended scheduled run of the routine \"%s\". Nobody is watching: "
    .. "don't ask questions or wait for answers; do the work, then end with a short report of what "
    .. "you did and anything that needs a person."

local list = nil            -- the routines, read on first use
local runs = {}             -- session name -> { id, asked }
local runCount = 0

local function load()
    if not list then
        local parsed = gitgud.jsonDecode(gitgud.configRead(FILE) or "")
        list = type(parsed) == "table" and parsed or {}
    end
    return list
end

local function save()
    gitgud.configWrite(FILE, gitgud.jsonEncode(load()))
    require("bragi.settings").rebuild("routines")
end

local function find(id)
    for i, r in ipairs(load()) do
        if r.id == id then
            return r, i
        end
    end
    return nil
end

--- The routines, in the order they were made.
function routines.list()
    return load()
end

--- True while a run of the routine is going.
function routines.running(id)
    for _, run in pairs(runs) do
        if run.id == id then
            return true
        end
    end
    return false
end

--- Make a routine. Returns it.
-- @param fields  { name, folder, every (minutes), prompt, enabled, acceptEdits }
function routines.add(fields)
    local r = {
        id = string.format("r%d%03d", os.time(), math.random(0, 999)),
        name = text.trim(fields.name or "") ~= "" and text.trim(fields.name) or "Routine",
        folder = fields.folder or "",
        every = math.max(1, tonumber(fields.every) or 60),
        prompt = fields.prompt or "",
        enabled = fields.enabled ~= false,
        acceptEdits = fields.acceptEdits == true,
    }
    r.nextRun = os.time() + r.every * 60
    local all = load()
    all[#all + 1] = r
    save()
    return r
end

--- Change a routine's fields (a new schedule counts from now).
function routines.update(id, fields)
    local r = find(id)
    if not r then
        return
    end
    for k, v in pairs(fields) do
        r[k] = v
    end
    if fields.every then
        r.every = math.max(1, tonumber(fields.every) or r.every)
        r.nextRun = os.time() + r.every * 60
    end
    save()
end

function routines.remove(id)
    local _, i = find(id)
    if i then
        table.remove(load(), i)
        save()
    end
end

local function finish(name, status, summary)
    local run = runs[name]
    if not run then
        return
    end
    runs[name] = nil
    local r = find(run.id)
    if r then
        r.lastStatus = run.asked and status == "ok" and "asked" or status
        r.lastSummary = summary
        if run.asked then
            r.lastSummary = "Asked to use " .. run.asked .. " (denied). " .. (summary or "")
        end
        save()
    end
    gitgud.agentStop(name)
end

--- Run a routine now (it keeps its schedule).
function routines.runNow(id)
    local r = find(id)
    if not r or routines.running(id) then
        return false
    end
    runCount = runCount + 1
    local name = "routine-" .. r.id .. "-" .. runCount
    r.lastRun = os.time()
    r.nextRun = r.lastRun + r.every * 60
    local ok, err = gitgud.agentStart(name, {
        program = require("bragi.claude").program(),
        cwd = r.folder ~= "" and r.folder or nil,
        model = settings.get("bragi.model", "opus"),
        permissionMode = r.acceptEdits and "acceptEdits" or "default",
        effort = settings.get("bragi.effort", ""),
        appendSystemPrompt = string.format(UNATTENDED, r.name),
    })
    if ok then
        runs[name] = { id = r.id }
        ok, err = gitgud.agentSend(name, r.prompt ~= "" and r.prompt or "Report that this routine has no prompt yet.")
    end
    if not ok then
        runs[name] = nil
        r.lastStatus = "failed"
        r.lastSummary = "Didn't start: " .. tostring(err)
    else
        r.lastStatus = "running"
        r.lastSummary = nil
    end
    save()
    return ok
end

--- Run every routine that's due (the timer calls this).
function routines.tick()
    local now = os.time()
    for _, r in ipairs(load()) do
        if r.enabled and (r.nextRun or 0) <= now and not routines.running(r.id) then
            routines.runNow(r.id)
        end
    end
end

local function onAgentEvent(kind)
    return function(detail)
        local e = gitgud.jsonDecode(detail)
        local run = type(e) == "table" and runs[e.session]
        if not run then
            return
        end
        if kind == "permission" then
            run.asked = run.asked or e.tool or "a tool"
            gitgud.agentRespond(e.session, e.requestId, false,
                "Unattended run: nobody can allow this. Carry on without it and say what you needed.")
        elseif kind == "result" then
            local summary = text.trim((e.text or ""):gsub("%s+", " "))
            if #summary > SUMMARY then
                summary = summary:sub(1, SUMMARY - 3) .. "..."
            end
            finish(e.session, (e.isError and not e.interrupted) and "failed" or "ok", summary)
        elseif kind == "exit" then
            finish(e.session, "failed", "Claude Code stopped (exit code " .. tostring(e.code) .. ").")
        end
    end
end

-- ===================================================================
-- The settings section
-- ===================================================================

local function ago(t)
    if not t then
        return "never"
    end
    local d = math.max(0, os.time() - t)
    if d < 90 then
        return "just now"
    elseif d < 5400 then
        return math.floor(d / 60 + 0.5) .. " min ago"
    elseif d < 129600 then
        return math.floor(d / 3600 + 0.5) .. " h ago"
    end
    return os.date("%Y-%m-%d %H:%M", t)
end

local function shortFolder(folder)
    if folder == "" then
        return "no folder"
    end
    return folder:gsub("\\", "/"):match("[^/]+/?$") or folder
end

local function editSchedule(r)
    local dialog = require("ui.dialog")
    dialog.show({
        title = r and ("Routine: " .. r.name) or "New routine",
        fields = {
            { label = "Name", value = r and r.name or "" },
            { label = "Folder", value = r and r.folder or require("core.repo").state().path, browse = true },
            { label = "Every (minutes)", value = tostring(r and r.every or 60) },
        },
        checks = {
            { label = "On", value = not r or r.enabled },
            { label = "Edit files without asking", value = r and r.acceptEdits or false },
        },
        ok = r and "Save" or "Make",
        alt = r and { label = "Delete", action = function()
            routines.remove(r.id)
        end } or nil,
        onOk = function(v)
            local every = tonumber(text.trim(v.fields[3]))
            if not every or every < 1 then
                return false, "Every needs a number of minutes"
            end
            local fields = { name = text.trim(v.fields[1]), folder = text.trim(v.fields[2]), every = every,
                enabled = v.checks[1], acceptEdits = v.checks[2] }
            if r then
                routines.update(r.id, fields)
            else
                local made = routines.add(fields)
                routines.editPrompt(made.id)
            end
            return true
        end,
    })
end

--- Edit a routine's prompt in the Settings editor.
function routines.editPrompt(id)
    local r = find(id)
    if not r then
        return
    end
    require("bragi.settings").edit({ title = "Prompt: " .. r.name, body = r.prompt or "", save = function(body)
        routines.update(id, { prompt = text.trim(body) })
        return true
    end })
end

local STATUS = { ok = "Last run done", failed = "Last run failed", asked = "Last run needed permission",
    running = "Running now" }

--- The Routines section's cards.
function routines.cards()
    local cards = {}
    for _, r in ipairs(load()) do
        local status = r.lastRun and ((STATUS[r.lastStatus] or "Last run") .. ", " .. ago(r.lastRun)) or "Not run yet"
        if routines.running(r.id) then
            status = "Running now"
        end
        cards[#cards + 1] = { heading = r.name, rows = {
            { kind = "action", title = status,
              sub = (r.lastSummary and r.lastSummary ~= "") and r.lastSummary
                  or (r.enabled and ("Next run " .. os.date("%H:%M", r.nextRun or os.time())) or "Off"),
              button = "Run now", enabled = not routines.running(r.id),
              run = function()
                  routines.runNow(r.id)
              end },
            { kind = "action", title = "Schedule",
              sub = (r.enabled and "" or "Off. ") .. "Every " .. r.every .. " min in " .. shortFolder(r.folder)
                  .. (r.acceptEdits and ", edits files without asking" or "") .. ".",
              button = "Edit", run = function()
                  editSchedule(r)
              end },
            { kind = "action", title = "Prompt",
              sub = r.prompt ~= "" and (r.prompt:gsub("%s+", " "):sub(1, 120)) or "No prompt yet.",
              button = "Edit", run = function()
                  routines.editPrompt(r.id)
              end },
        } }
    end
    cards[#cards + 1] = { heading = #cards > 0 and "More" or "Routines", rows = {
        { kind = "action", title = "New routine",
          sub = "A prompt Claude Code runs on a schedule in a folder, while the app is open. "
              .. "One that came due while it was closed runs at the next start.",
          button = "New", primary = true, run = function()
              editSchedule(nil)
          end },
    } }
    return cards
end

function routines.init()
    for _, kind in ipairs({ "result", "permission", "exit" }) do
        gitgud.on("agent." .. kind, onAgentEvent(kind))
    end
    -- A hot-reload: runs go on in C++, and their record comes back.
    -- One whose session is gone is ended by its exit event.
    gitgud.on("app.reloading", function()
        local json = gitgud.jsonEncode({ runs = runs, runCount = runCount })
        if json then
            gitgud.keepForReload("bragi.routines", json)
        end
    end)
    local kept = gitgud.jsonDecode(gitgud.takeKept("bragi.routines") or "")
    if type(kept) == "table" then
        runCount = tonumber(kept.runCount) or runCount
        for name, run in pairs(type(kept.runs) == "table" and kept.runs or {}) do
            if gitgud.agentInfo(name) then
                runs[name] = run
            end
        end
    end
    -- Runs left "running" by a closed app ended with it.
    for _, r in ipairs(load()) do
        if r.lastStatus == "running" and not routines.running(r.id) then
            r.lastStatus = "failed"
            r.lastSummary = "The app closed during the run."
        end
    end
    gitgud.every(TICK_MS, routines.tick)
    gitgud.after(5000, routines.tick)
end

function routines.refresh()
end

return routines
