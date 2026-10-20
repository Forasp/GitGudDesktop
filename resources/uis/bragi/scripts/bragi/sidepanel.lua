--- bragi/sidepanel.lua: the Agent view's session panel
-- (the layout elements on the right of the conversation, "especially the
-- background tasks and environment"). A column on the right
-- (layouts/bragi/sidepanel.xml) with a card each about the conversation
-- shown (agent.current()):
--
--   Environment       this computer; the session's working folder (its name,
--                     the folder above it in grey; a click opens it); the
--                     branch checked out there, and the worktree when it's
--                     a linked one
--   Context           how full the session's context window is: the latest
--                     model call's tokens (agent.usage: input, cache read and
--                     written, output) over the model's window (the turn's
--                     result says it; else CONTEXT_WINDOWS, below); not a
--                     slash command's output (model "<synthetic>", no
--                     tokens); after compaction, what's left
--   Outputs           files the session wrote or edited (Write, Edit,
--                     MultiEdit, NotebookEdit steps, its sub-agents' too,
--                     wherever they are), newest first; a click opens one
--   Changes           lines added and removed in the folder's working tree
--                     against HEAD, staged, unstaged, and untracked
--                     (gitgud.folderSummary, on a worker; again when a turn
--                     ends or a step changes files), and Create PR: push the
--                     branch, then open a pull request through bragi/server.lua
--                     when the folder's repository has a remote there (not
--                     offered while no store answers: this build)
--   Background tasks  sub-agents and background commands the session
--                     started: running ones with their time and Stop (Claude
--                     Code's stop_task, for a task it named in task_started),
--                     then "N finished", which opens the finished ones
--
-- The session's folder is its own (session.cwd once sessions carry one),
-- else what it was started in (gitgud.agentInfo(name).options.cwd), else
-- the open repository.
--
-- A click on a card's header folds it (remembered: bragi.panel.<card>);
-- AgentPanelButton in the conversation's top bar shows and hides the panel
-- (bragi.panel). Beside the conversation it takes PANEL px, or what its
-- left edge was dragged to (bragi.panelWidth), and the conversation makes
-- room (agent.lua's relayout asks sidepanel.place). When the window is too
-- narrow for both, it hides; the button then shows it over the
-- conversation until it's clicked again.
--
-- Public API: sidepanel.place(width), sidepanel.toggle(), sidepanel.showCard(key), sidepanel.paint(),
-- sidepanel.context(name), sidepanel.snapshot() (what it shows, for tests),
-- sidepanel.running(tab)

local C = require("core.palette")
local agent = require("bragi.agent")
local app = require("core.app")
local geometry = require("ui.geometry")
local repo = require("core.repo")
local rowsLib = require("bragi.rows")
local server = require("bragi.server")
local settings = require("core.settings")
local status = require("core.status")
local text = require("core.text")

local sidepanel = { name = "bragi.sidepanel", layout = "bragi/sidepanel.xml", parent = "AgentRoot" }

local PANEL = 288          -- its width, until it's dragged
local PANEL_MIN = 240
local PANEL_MAX = 560
local MIN_MAIN = 760       -- the conversation's narrowest beside it
sidepanel.MIN_MAIN = MIN_MAIN
local HEADER = 56          -- the top bar's height
local MARGIN = 12          -- around the cards
local CARD_GAP = 10
local HEAD = 40            -- a card's header
local ROW = 30
local SCROLLBAR = 10
local TASKS_SHOWN = 4      -- running tasks before "Show more"
local FINISHED_SHOWN = 20  -- finished tasks listed at most
local OUTPUTS_SHOWN = 5    -- files before "Show more"
local OUTPUTS_MORE = 40    -- files listed at most
local TICK_MS = 1000       -- running tasks' times
local SUMMARY_DELAY = 600  -- a burst of changes reads the folder once

-- Context windows by model (policy): the turn's result names the window
-- when it can (modelUsage's contextWindow); else the last one a result named
-- for that model (kept in WINDOWS_KEY, so a conversation opened from its
-- transcript shows it too); else a model chosen with "[1m]" has a million
-- tokens, anything else CONTEXT_WINDOW. Never less than the tokens in it: a
-- session past CONTEXT_WINDOW has the larger one.
local CONTEXT_WINDOW = 200000
local CONTEXT_WINDOWS = {
    { match = "%[1m%]", size = 1000000 },
}
local LARGE_WINDOW = 1000000
local WINDOWS_KEY = "bragi.contextWindows"

local CARDS = {
    { key = "environment", title = "Environment" },
    { key = "context", title = "Context" },
    { key = "outputs", title = "Outputs" },
    { key = "changes", title = "Changes" },
    { key = "tasks", title = "Background tasks" },
}

-- Tools whose steps write files (Outputs) and start tasks.
local WRITES = { Write = true, Edit = true, MultiEdit = true, NotebookEdit = true }
local AGENT_TOOLS = { Agent = true, Task = true }
local SHELL_TOOLS = { Bash = true, PowerShell = true }
-- A step that may change files: Changes is read again after it.
local CHANGES_FILES = { Write = true, Edit = true, MultiEdit = true, NotebookEdit = true, Bash = true,
    PowerShell = true }

local SUMMARY = "BragiPanelSummary" -- the folderSummary task's name
local PUSH = "pushBranch"           -- gitgud.pushBranch's events

local visible = false   -- shown
local wide = true       -- room for it beside the conversation
local forced = false    -- shown over the conversation (narrow window)
local width = PANEL
local split = nil       -- its left edge's seam (ui/splitter.lua), made in init
local room = 0          -- the width it and the conversation share (place)

-- Session name -> what its events said: tokens, model, window (from the
-- result), tasks (oldest first), byTool (tool use id -> task), byTask.
local sessions = {}
local summaries = {}        -- folder -> { data | error }
local summaryBusy = nil     -- the folder being read
local summaryNext = nil     -- the next one to read
local summaryTimer = nil
local prs = {}              -- folder .. "|" .. branch -> { number, url } or { busy = true }
local pushWaiting = nil     -- fn(ok, detail) for the push under way
local expanded = { outputs = false, tasks = false, finished = false }
local paintPending = false
local tickTimer = nil
local ticking = {}          -- { {label, task} } of the running tasks shown
local made = {}             -- widgets made (the VM starts over on a reload)
local actions, stops = {}, {} -- row name -> fn: a click, its Stop
local last = {}             -- what the last paint showed (sidepanel.snapshot)

-- ===================================================================
-- Session data
-- ===================================================================

--- The tab a session belongs to, or nil (the app's own helpers).
local function tabOf(name)
    for _, tab in ipairs(agent.tabs()) do
        if tab.session.name == name then
            return tab
        end
    end
    return nil
end

local function dataOf(name, make)
    if not name then
        return nil
    end
    local d = sessions[name]
    if not d and make then
        d = { tasks = {}, byTool = {}, byTask = {} }
        sessions[name] = d
    end
    return d
end

--- The session folder of a tab, "" when there's none.
local function folderOf(tab)
    local s = tab and tab.session or {}
    local folder = type(s.cwd) == "string" and s.cwd or ""
    if folder == "" and s.name then
        local info = gitgud.agentInfo(s.name)
        folder = info and info.options and info.options.cwd or ""
    end
    if folder == "" then
        folder = repo.state().path or ""
    end
    return (folder:gsub("\\", "/"):gsub("/+$", ""))
end

--- A path as the platform writes it.
local function shown(path)
    if gitgud.platform == "windows" then
        return (path:gsub("/", "\\"))
    end
    return path
end

local function thousands(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

--- "45s", "57m", "2h 5m".
local function elapsed(ms)
    local s = math.max(0, math.floor((ms or 0) / 1000))
    if s < 60 then
        return s .. "s"
    elseif s < 3600 then
        return math.floor(s / 60) .. "m"
    end
    local m = math.floor(s / 60) % 60
    return math.floor(s / 3600) .. "h" .. (m > 0 and (" " .. m .. "m") or "")
end

-- ===================================================================
-- Tasks (from the session's tool calls and its task_* system messages)
-- ===================================================================

local function addTask(d, t)
    t.started = t.started or gitgud.now()
    t.state = t.state or "running"
    d.tasks[#d.tasks + 1] = t
    if t.toolId then
        d.byTool[t.toolId] = t
    end
    if t.taskId then
        d.byTask[t.taskId] = t
    end
    return t
end

local function finish(t, state)
    if t and t.state == "running" then
        t.state = state
        t.ended = gitgud.now()
        t.stopping = nil
    end
end

--- A task_* message's task: by its task id, then its tool call's.
local function findTask(d, raw)
    return d.byTask[raw.task_id or ""] or d.byTool[raw.tool_use_id or ""]
end

local KIND_OF_TYPE = { local_agent = "agent", local_bash = "shell", remote_agent = "agent" }

local function onTool(d, e)
    local input = type(e.input) == "table" and e.input or {}
    if AGENT_TOOLS[e.name] then
        addTask(d, { toolId = e.id, kind = "agent", background = input.run_in_background == true,
            title = input.description or input.subagent_type or "Sub-agent" })
    elseif SHELL_TOOLS[e.name] and input.run_in_background == true then
        addTask(d, { toolId = e.id, kind = "shell", background = true,
            title = input.description or tostring(input.command or ""):match("^[^\n]*") })
    end
end

local function onToolResult(d, e)
    local t = d.byTool[e.id or ""]
    if not t then
        return
    end
    if e.isError then
        finish(t, "failed")
    elseif t.kind == "agent" and not t.background then
        finish(t, "completed")
    end
end

local FINISHED = { completed = "completed", failed = "failed", stopped = "stopped", killed = "stopped" }

local function onSystem(d, e)
    local raw = type(e.raw) == "table" and e.raw or {}
    local compacted = e.subtype == "compact_boundary" and type(raw.compact_metadata) == "table"
        and tonumber(raw.compact_metadata.post_tokens)
    if compacted then
        d.tokens = compacted -- the context left after compaction
    elseif e.subtype == "task_started" then
        if raw.ambient or raw.skip_transcript then
            return -- the CLI's own housekeeping
        end
        local t = findTask(d, raw)
        if not t then
            t = addTask(d, { toolId = raw.tool_use_id, kind = KIND_OF_TYPE[raw.task_type or ""] or "task" })
        end
        t.taskId = raw.task_id
        d.byTask[raw.task_id or ""] = t
        if (raw.description or "") ~= "" then
            t.title = raw.description
        end
        t.background = t.background or raw.is_backgrounded == true
    elseif e.subtype == "task_updated" then
        local t = findTask(d, raw)
        local patch = type(raw.patch) == "table" and raw.patch or {}
        if t and FINISHED[patch.status or ""] then
            finish(t, FINISHED[patch.status])
        elseif t and patch.is_backgrounded then
            t.background = true
        end
    elseif e.subtype == "task_notification" then
        finish(findTask(d, raw), FINISHED[raw.status or ""] or "completed")
    elseif e.subtype == "background_tasks_changed" then
        -- Running tasks this panel didn't hear start.
        for _, task in ipairs(type(raw.tasks) == "table" and raw.tasks or {}) do
            if type(task) == "table" and task.task_id and not d.byTask[task.task_id] and not task.ambient then
                addTask(d, { taskId = task.task_id, kind = KIND_OF_TYPE[task.task_type or ""] or "task",
                    background = true, title = task.description or "Task" })
            end
        end
    end
end

--- Running and finished tasks, newest first.
local function taskLists(d)
    local running, done = {}, {}
    for i = #(d and d.tasks or {}), 1, -1 do
        local t = d.tasks[i]
        if t.state == "running" then
            running[#running + 1] = t
        else
            done[#done + 1] = t
        end
    end
    return running, done
end

-- ===================================================================
-- Changes (gitgud.folderSummary)
-- ===================================================================

local function fetchSummary(folder)
    if folder == "" then
        return
    end
    if summaryBusy then
        summaryNext = folder
        return
    end
    summaryBusy = folder
    if not gitgud.folderSummary(SUMMARY, folder) then
        summaryBusy = nil
    end
end

local paintSoon

--- Read the shown conversation's folder again soon.
local function summarySoon()
    if not visible then
        return
    end
    if summaryTimer then
        gitgud.cancelTimer(summaryTimer)
    end
    summaryTimer = gitgud.after(SUMMARY_DELAY, function()
        summaryTimer = nil
        fetchSummary(folderOf(agent.current()))
    end)
end

local function summaryDone(entry)
    local folder = summaryBusy
    summaryBusy = nil
    if folder then
        summaries[folder] = entry
    end
    paintSoon()
    if summaryNext then
        local nextFolder = summaryNext
        summaryNext = nil
        fetchSummary(nextFolder)
    end
end

--- The server repository ("owner/name") a remote points at, and the
-- remote's name, when one of them is on the store's host (bragi/server.lua).
local function serverRepoOf(remotes)
    local host = (server.info().url or ""):match("^https?://([^/:]+)")
    if not host then
        return nil
    end
    local list = {}
    for _, r in ipairs(remotes or {}) do
        table.insert(list, r.name == "origin" and 1 or #list + 1, r)
    end
    for _, r in ipairs(list) do
        local url = r.url or ""
        local remoteHost, path = nil, nil
        local authority, rest = url:match("^%a[%w+.-]*://([^/]*)/(.+)$")
        if authority then
            -- user@host:port: the host alone
            remoteHost, path = authority:gsub("^.*@", ""):match("^([^:]+)"), rest
        else
            remoteHost, path = url:match("^[^@/]+@([^:/]+):(.+)$")
        end
        if remoteHost and remoteHost:lower() == host:lower() then
            path = path:gsub("%.git$", ""):gsub("/$", "")
            if path:match("^[^/]+/[^/]+$") then
                return path, r.name
            end
        end
    end
    return nil
end

--- Whether the folder's working tree is one of the open repository's (so
-- gitgud.pushBranch can push its branch).
local function inOpenRepo(root)
    local open = (repo.state().path or ""):gsub("\\", "/"):lower()
    root = (root or ""):gsub("\\", "/"):lower()
    if root == "" or open == "" then
        return false
    end
    if root == open then
        return true
    end
    for _, w in ipairs(gitgud.worktrees and gitgud.worktrees() or {}) do
        if (w.path or ""):gsub("\\", "/"):gsub("/+$", ""):lower() == root then
            return true
        end
    end
    return false
end

--- Create PR's state: { show, enabled, label, tip, pr, own, remote }.
local function prState(folder, sum)
    if not sum then
        return { show = false }
    end
    local key = folder .. "|" .. (sum.branch or "")
    local pr = prs[key]
    if pr and pr.number then
        return { show = true, enabled = true, label = "PR #" .. pr.number, tip = "Open the pull request", pr = pr }
    elseif pr and pr.busy then
        return { show = true, enabled = false, label = "Creating", tip = "Pushing and opening the pull request" }
    end
    local info = server.info()
    if (info.url or "") == "" or not info.signedIn then
        return { show = false }
    end
    local state = { show = true, enabled = false, label = "Create PR" }
    local own, remote = serverRepoOf(sum.remotes)
    if not own then
        state.tip = "This repository has no remote on " .. info.url
    elseif (sum.branch or "") == "" then
        state.tip = "Check out a branch first"
    elseif not inOpenRepo(sum.root) then
        state.tip = "Open this repository in the Repo view to push its branch"
    else
        state.enabled = true
        state.tip = "Push " .. sum.branch .. " to " .. remote .. " and open a pull request"
        state.own, state.remote = own, remote
    end
    return state
end

--- Push the branch, then open the pull request into the default branch.
local function createPr(folder, sum, state, title)
    local key = folder .. "|" .. sum.branch
    local function fail(message)
        prs[key] = nil
        status.error("The pull request wasn't created: " .. tostring(message))
        paintSoon()
    end
    prs[key] = { busy = true }
    paintSoon()
    pushWaiting = function(ok, detail)
        if not ok then
            fail(detail)
            return
        end
        server.request("GET", "/api/v1/repos/" .. state.own, nil, function(info)
            local base = type(info) == "table" and info.default_branch or "main"
            if base == sum.branch then
                fail(sum.branch .. " is the repository's default branch")
                return
            end
            server.request("POST", "/api/v1/repos/" .. state.own .. "/pulls",
                { head = sum.branch, base = base, title = title, body = "Opened from Bragi." },
                function(pr)
                    if type(pr) ~= "table" or not pr.number then
                        fail("no pull request number came back")
                        return
                    end
                    prs[key] = { number = pr.number, url = pr.html_url or pr.url }
                    status.ok("Pull request #" .. pr.number .. " opened.")
                    paintSoon()
                end, fail)
        end, fail)
    end
    local ok, err = gitgud.pushBranch(state.remote, sum.branch, {})
    if not ok then
        pushWaiting = nil
        fail(err or "the push didn't start")
    end
end

local function askCreatePr(folder, sum, state)
    local tab = agent.current()
    local title = tab and tab.title ~= "" and tab.title ~= "New session" and tab.title or sum.branch
    local body = "Push " .. sum.branch .. " to " .. state.remote .. " and open a pull request for it on its "
        .. "host (" .. state.own .. "), into the repository's default branch."
    if (sum.files or 0) > 0 then
        body = body .. "\n\n" .. text.plural(sum.files, "file") .. " with uncommitted changes won't be in it: "
            .. "commit them first to include them."
    end
    require("ui.dialog").confirm("Create a pull request?", body, "Create PR", function()
        createPr(folder, sum, state, title)
    end)
end

-- ===================================================================
-- Outputs (from the conversation's steps)
-- ===================================================================

--- Files the tab's steps wrote or edited, newest first: { path }.
local function outputsOf(tab)
    local list, seen = {}, {}
    local function scan(items)
        for i = #items, 1, -1 do
            local item = items[i]
            if item.kind == "step" and WRITES[item.title or ""] and not item.error then
                local input = gitgud.jsonDecode(item.inputText or "") or {}
                local path = type(input) == "table" and (input.file_path or input.notebook_path) or nil
                if type(path) == "string" and path ~= "" then
                    path = path:gsub("\\", "/")
                    local k = path:lower()
                    if not seen[k] then
                        seen[k] = true
                        list[#list + 1] = path
                    end
                end
            end
        end
    end
    if tab then
        scan(tab.items or {})
        scan(tab.earlier or {})
    end
    return list
end

-- ===================================================================
-- Drawing
-- ===================================================================

local function make(kind, name, parent)
    if made[name] then
        return false
    end
    made[name] = true
    gitgud.createWindow(kind, name, parent)
    return true
end

local function label(name, parent, font, colour, align)
    if make("Gitgud/Label", name, parent) then
        gitgud.setProperty(name, "Font", font)
        gitgud.setProperty(name, "NormalTextColour", colour or C.text)
        gitgud.setProperty(name, "HorzFormatting", align or "LeftAligned")
        gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
        gitgud.setProperty(name, "ClippedByParent", "true")
    end
    return name
end

local function icon(name, parent, image, colour)
    if make("Gitgud/Icon", name, parent) then
        gitgud.setProperty(name, "GlowColour", "00000000")
        gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    end
    gitgud.setProperty(name, "IconImage", image)
    gitgud.setProperty(name, "IconColour", colour or C.sub)
    return name
end

--- Plain text cut from the front with "…" to fit a width.
local function fitLeft(font, s, w)
    local prefix = "[font='" .. font .. "']"
    if rowsLib.measure(prefix .. text.escape(s)) <= w then
        return s
    end
    local lo, hi = 0, rowsLib.length(s)
    while lo < hi do
        local mid = (lo + hi + 1) // 2
        if rowsLib.measure(prefix .. text.escape("…" .. rowsLib.tail(s, mid))) <= w then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return "…" .. rowsLib.tail(s, lo)
end

--- One row of a card. spec: { icon, iconColour, markup, meta, metaColour,
-- tip, run (a click), stop (Stop's click), stopTip, indent (text where it
-- would be after an icon) }. Returns the row's name and its text's width.
local function row(card, n, y, cw, spec)
    local name = card .. "Row" .. n
    if make("Bragi/Button6", name, card) then
        gitgud.setProperty(name, "Text", "")
        gitgud.setProperty(name, "BorderColour", C.transparent)
        gitgud.setProperty(name, "NormalFillColour", C.transparent)
        gitgud.setProperty(name, "DisabledFillColour", C.transparent)
        gitgud.on(name .. ".clicked", function()
            local fn = actions[name]
            if fn then
                fn()
            end
        end)
        local stop = name .. "Stop"
        make("Bragi/Button6", stop, name)
        gitgud.setProperty(stop, "Text", "")
        gitgud.setProperty(stop, "NormalFillColour", C.transparent)
        gitgud.setProperty(stop, "HoverFillColour", C.sel)
        gitgud.setProperty(stop, "BorderColour", C.transparent)
        icon(stop .. "Icon", stop, "Bragi-Panel/Stop", C.sub)
        gitgud.setProperty(stop .. "Icon", "Area", geometry.rect(3, 3, 16, 16))
        gitgud.on(stop .. ".clicked", function()
            local fn = stops[name]
            if fn then
                fn()
            end
        end)
    end
    local rw = cw - 12
    gitgud.setVisible(name, true)
    gitgud.setProperty(name, "Area", geometry.rect(6, y, rw, ROW))
    gitgud.setProperty(name, "HoverFillColour", spec.run and C.hover or C.transparent)
    gitgud.setProperty(name, "PushedFillColour", spec.run and C.sel or C.transparent)
    gitgud.setProperty(name, "TooltipText", spec.tip or "")
    actions[name] = spec.run
    stops[name] = spec.stop

    local x = spec.indent and 32 or 10
    if spec.icon then
        icon(name .. "Icon", name, spec.icon, spec.iconColour)
        gitgud.setProperty(name .. "Icon", "Area", geometry.rect(8, 7, 16, 16))
        gitgud.setVisible(name .. "Icon", true)
        x = 32
    elseif made[name .. "Icon"] then
        gitgud.setVisible(name .. "Icon", false)
    end
    local right = rw - 6
    local stop = name .. "Stop"
    gitgud.setVisible(stop, spec.stop ~= nil)
    if spec.stop then
        right = rw - 28
        gitgud.setProperty(stop, "Area", geometry.rect(right + 2, 4, 22, 22))
        gitgud.setProperty(stop, "TooltipText", spec.stopTip or "Stop")
    end
    local meta = label(name .. "Meta", name, "Bragi-12", spec.metaColour or C.sub, "RightAligned")
    local metaW = 0
    if spec.meta and spec.meta ~= "" then
        metaW = 52
        gitgud.setProperty(meta, "NormalTextColour", spec.metaColour or C.sub)
        gitgud.setProperty(meta, "Area", geometry.rect(right - metaW, 0, metaW, ROW))
        gitgud.setText(meta, text.escape(spec.meta))
    end
    gitgud.setVisible(meta, metaW > 0)
    local body = label(name .. "Text", name, "Bragi-13", C.text)
    gitgud.setProperty(body, "Area", geometry.rect(x, 0, math.max(10, right - metaW - x - 4), ROW))
    gitgud.setText(body, spec.markup or "")
    return name, math.max(10, right - metaW - x - 4)
end

--- Hide a card's rows from `n` on.
local function hideRows(card, n)
    while made[card .. "Row" .. n] do
        gitgud.setVisible(card .. "Row" .. n, false)
        actions[card .. "Row" .. n], stops[card .. "Row" .. n] = nil, nil
        n = n + 1
    end
end

local function cardOpen(key)
    return settings.get("bragi.panel." .. key, true)
end

--- A line of markup in the text colour, cut to fit.
local function fitted(font, colour, s, w)
    return "[font='" .. font .. "'][colour='" .. colour .. "']" .. text.escape(rowsLib.fitText(font, s, w))
end

-- Each card's body: draws its rows from y under the header, returns the
-- height they take.
local body = {}

function body.environment(card, y, cw, tab)
    local folder = folderOf(tab)
    local sum = summaries[folder] and summaries[folder].data
    local n = 0
    local env = {}
    last.environment = env

    n = n + 1
    env.computer = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "This computer"
    local _, tw = row(card, n, y, cw, { icon = "Bragi-Panel/Computer", tip = "This computer" })
    gitgud.setText(card .. "Row" .. n .. "Text", fitted("Bragi-13", C.text, env.computer, tw))
    y = y + ROW

    n = n + 1
    if folder ~= "" then
        local root = sum and sum.root or folder
        env.folder, env.parent = text.basename(root), shown(text.dirname(root):gsub("/+$", ""))
        local _, w = row(card, n, y, cw, { icon = "Bragi-Panel/Folder", tip = shown(root), run = function()
            gitgud.openExternal(shown(root))
        end })
        local nameMarkup = fitted("Bragi-13-Bold", C.text, env.folder, w)
        local used = rowsLib.measure(nameMarkup)
        local rest = w - used - 8
        local parentMarkup = rest > 30 and ("  [font='Bragi-12'][colour='" .. C.sub .. "']"
            .. text.escape(fitLeft("Bragi-12", env.parent, rest))) or ""
        gitgud.setText(card .. "Row" .. n .. "Text", nameMarkup .. parentMarkup)
    else
        env.folder = nil
        local _, w = row(card, n, y, cw, { icon = "Bragi-Panel/Folder" })
        gitgud.setText(card .. "Row" .. n .. "Text", fitted("Bragi-13", C.sub, "No folder: open a repository", w))
    end
    y = y + ROW

    n = n + 1
    local branchText, colour, font = nil, C.text, "Bragi-Mono-13"
    if sum then
        branchText = sum.branch ~= "" and sum.branch or ("detached at " .. (sum.head or ""))
        env.branch = sum.branch
    elseif summaries[folder] and summaries[folder].error then
        branchText, colour, font = "Not a Git repository", C.sub, "Bragi-13"
    else
        branchText, colour, font = "Reading the repository", C.sub, "Bragi-13"
    end
    local _, bw = row(card, n, y, cw, { icon = "Bragi-Icons/NavBranch", tip = "The branch checked out there" })
    gitgud.setText(card .. "Row" .. n .. "Text", fitted(font, colour, branchText, bw))
    y = y + ROW

    if sum and (sum.worktree or "") ~= "" then
        n = n + 1
        env.worktree = sum.worktree
        local _, ww = row(card, n, y, cw, { icon = "Bragi-Icons/NavWorktree", tip = "A linked worktree" })
        gitgud.setText(card .. "Row" .. n .. "Text", "[font='Bragi-12'][colour='" .. C.sub .. "']worktree  "
            .. fitted("Bragi-Mono-13", C.text, sum.worktree, ww - 70))
        y = y + ROW
    end
    hideRows(card, n + 1)
    return n * ROW + 8
end

--- Model -> the window a turn's result last named for it.
local function learnedWindows()
    local known = gitgud.jsonDecode(settings.get(WINDOWS_KEY, "") or "")
    return type(known) == "table" and known or {}
end

--- The model's context window (policy above).
local function windowOf(d, tab)
    local tokens = d and d.tokens or 0
    local window = d and d.window
    if not window and d and d.model then
        window = tonumber(learnedWindows()[d.model])
    end
    if not window then
        local info = tab and tab.session.name and gitgud.agentInfo(tab.session.name)
        local chosen = (info and info.options and info.options.model ~= "" and info.options.model)
            or settings.get("bragi.model", "opus")
        for _, rule in ipairs(CONTEXT_WINDOWS) do
            if tostring(chosen):find(rule.match) or tostring(d and d.model or ""):find(rule.match) then
                window = rule.size
                break
            end
        end
    end
    window = window or CONTEXT_WINDOW
    if tokens > window then
        window = math.max(LARGE_WINDOW, tokens)
    end
    return window
end

function body.context(card, y, cw, tab)
    local d = dataOf(tab and tab.session.name)
    local line = label(card .. "Line", card, "Bragi-12", C.sub)
    local track, fill = card .. "Track", card .. "Fill"
    if make("Bragi/Box4", track, card) then
        gitgud.setProperty(track, "BorderColour", C.transparent)
        gitgud.setProperty(track, "FillColour", C.sel)
        gitgud.setProperty(track, "CursorPassThroughEnabled", "true")
    end
    if make("Bragi/Box4", fill, card) then
        gitgud.setProperty(fill, "BorderColour", C.transparent)
        gitgud.setProperty(fill, "CursorPassThroughEnabled", "true")
    end
    gitgud.setVisible(line, true)
    gitgud.setProperty(line, "Area", geometry.rect(14, y, cw - 28, 20))
    local tokens = d and d.tokens
    if not tokens then
        last.context = { percent = nil }
        gitgud.setText(line, "No model calls yet.")
        gitgud.setVisible(track, false)
        gitgud.setVisible(fill, false)
        return 30
    end
    local window = windowOf(d, tab)
    local share = math.min(1, tokens / window)
    local percent = math.floor(share * 100 + 0.5)
    last.context = { tokens = tokens, window = window, percent = percent }
    gitgud.setText(line, text.escape(thousands(tokens) .. " of " .. thousands(window) .. " tokens"))
    local barW = cw - 28
    gitgud.setVisible(track, true)
    gitgud.setProperty(track, "Area", geometry.rect(14, y + 26, barW, 8))
    gitgud.setVisible(fill, share > 0)
    gitgud.setProperty(fill, "FillColour", share >= 0.9 and C.err or (share >= 0.7 and C.accentText or C.accent))
    gitgud.setProperty(fill, "Area", geometry.rect(14, y + 26, math.max(8, math.floor(barW * share)), 8))
    return 46
end

function body.outputs(card, y, cw, tab)
    local list = outputsOf(tab)
    local folder = folderOf(tab)
    last.outputs = list
    local n = 0
    if #list == 0 then
        n = 1
        local _, w = row(card, n, y, cw, {})
        gitgud.setText(card .. "Row1Text", fitted("Bragi-13", C.sub, "No files written yet.", w))
    end
    local limit = expanded.outputs and OUTPUTS_MORE or OUTPUTS_SHOWN
    for i, path in ipairs(list) do
        if i > limit then
            break
        end
        n = n + 1
        local dir = text.dirname(path):gsub("/+$", "")
        local prefix = folder ~= "" and (folder .. "/") or nil
        if prefix and path:lower():sub(1, #prefix) == prefix:lower() then
            dir = text.dirname(path:sub(#prefix + 1)):gsub("/+$", "")
        end
        local _, w = row(card, n, y + (n - 1) * ROW, cw, { icon = "Bragi-Panel/File", tip = shown(path),
            run = function()
                gitgud.openExternal(shown(path))
            end })
        local nameMarkup = fitted("Bragi-13", C.text, text.basename(path), w)
        local rest = w - rowsLib.measure(nameMarkup) - 8
        local dirMarkup = (dir ~= "" and rest > 30) and ("  [font='Bragi-12'][colour='" .. C.sub .. "']"
            .. text.escape(fitLeft("Bragi-12", shown(dir), rest))) or ""
        gitgud.setText(card .. "Row" .. n .. "Text", nameMarkup .. dirMarkup)
    end
    if #list > OUTPUTS_SHOWN then
        n = n + 1
        local more = expanded.outputs and "Show fewer" or ("Show " .. (math.min(#list, OUTPUTS_MORE) - OUTPUTS_SHOWN)
            .. " more")
        row(card, n, y + (n - 1) * ROW, cw, { indent = true, run = function()
            expanded.outputs = not expanded.outputs
            paintSoon()
        end })
        gitgud.setText(card .. "Row" .. n .. "Text", "[font='Bragi-13'][colour='" .. C.link .. "']" .. more)
    end
    hideRows(card, n + 1)
    return n * ROW + 8
end

function body.changes(card, y, cw, tab)
    local folder = folderOf(tab)
    local entry = summaries[folder]
    local sum = entry and entry.data
    local counts = label(card .. "Counts", card, "Bragi-14-Bold", C.text)
    local files = label(card .. "Files", card, "Bragi-12", C.sub)
    local button = card .. "Pr"
    if make("Bragi/Button8", button, card) then
        gitgud.setProperty(button, "Font", "Bragi-13-Bold")
        gitgud.setProperty(button, "NormalFillColour", C.transparent)
        gitgud.setProperty(button, "PushedFillColour", C.sel)
        gitgud.setProperty(button, "BorderColour", C.border)
        gitgud.on(button .. ".clicked", function()
            local fn = actions[button]
            if fn then
                fn()
            end
        end)
    end
    gitgud.setVisible(counts, true)
    gitgud.setVisible(files, true)
    if not sum then
        last.changes = { error = entry and entry.error }
        gitgud.setProperty(counts, "Area", geometry.rect(14, y, cw - 28, 24))
        gitgud.setText(counts, "[font='Bragi-13'][colour='" .. C.sub .. "']"
            .. (entry and "Not a Git repository." or (folder == "" and "No folder." or "Reading the changes.")))
        gitgud.setVisible(files, false)
        gitgud.setVisible(button, false)
        return 34
    end
    local summary = "[colour='" .. C.add .. "']+" .. thousands(sum.added) .. "  [colour='" .. C.warn .. "']-"
        .. thousands(sum.removed)
    gitgud.setProperty(counts, "Area", geometry.rect(14, y, cw - 28 - 104, 24))
    gitgud.setText(counts, summary)
    gitgud.setProperty(files, "Area", geometry.rect(14, y + 22, cw - 28 - 104, 18))
    gitgud.setText(files, (sum.files or 0) == 0 and "No changes" or ("in " .. text.plural(sum.files, "file")))
    local pr = prState(folder, sum)
    last.changes = { added = sum.added, removed = sum.removed, files = sum.files, pr = pr }
    gitgud.setVisible(button, pr.show)
    if pr.show then
        gitgud.setProperty(button, "Area", geometry.rect(cw - 14 - 96, y + 4, 96, 30))
        gitgud.setText(button, text.escape(pr.label))
        -- Unavailable, it looks it but still takes a click (and keeps its
        -- tooltip): the click says why.
        for _, state in ipairs({ "Normal", "Hover", "Pushed" }) do
            gitgud.setProperty(button, state .. "TextColour", pr.enabled and C.text or C.disabled)
        end
        gitgud.setProperty(button, "HoverFillColour", pr.enabled and C.hover or C.transparent)
        gitgud.setProperty(button, "TooltipText", pr.tip or "")
        actions[button] = function()
            if not pr.enabled then
                status.info(pr.tip or "Not now.")
            elseif pr.pr then
                gitgud.openExternal(pr.pr.url)
            else
                askCreatePr(folder, sum, pr)
            end
        end
    end
    return 48
end

local KIND_ICON = { agent = "Bragi-Panel/Agent", shell = "Bragi-Panel/Terminal" }
local END_WORDS = { completed = "Finished", failed = "Failed", stopped = "Stopped" }

function body.tasks(card, y, cw, tab)
    local name = tab and tab.session.name
    local d = dataOf(name)
    local running, done = taskLists(d)
    last.tasks = { running = running, finished = done }
    ticking = {}
    local n = 0
    -- The next row: its number and top.
    local function nextRow()
        n = n + 1
        return n, y + (n - 1) * ROW
    end
    if #running == 0 then
        local i, ry = nextRow()
        local rowName, w = row(card, i, ry, cw, {})
        gitgud.setText(rowName .. "Text", fitted("Bragi-13", C.sub, "Nothing running.", w))
    end
    local limit = expanded.tasks and #running or TASKS_SHOWN
    for i, t in ipairs(running) do
        if i > limit then
            break
        end
        local stoppable = t.taskId ~= nil and not t.stopping and tab.session.running
        local ri, ry = nextRow()
        local rowName, w = row(card, ri, ry, cw, {
            icon = KIND_ICON[t.kind] or "Bragi-Icons/Spark", iconColour = C.accentText,
            tip = t.title,
            meta = t.stopping and "Stopping" or elapsed(gitgud.now() - t.started),
            stop = stoppable and function()
                local ok, err = gitgud.agentStopTask(name, t.taskId)
                if ok then
                    t.stopping = true
                else
                    status.error("Couldn't stop it: " .. tostring(err))
                end
                paintSoon()
            end or nil,
            stopTip = "Stop " .. (t.kind == "shell" and "this command" or "this agent"),
        })
        gitgud.setText(rowName .. "Text", fitted("Bragi-13", C.text, t.title or "Task", w))
        if not t.stopping then
            ticking[#ticking + 1] = { label = rowName .. "Meta", task = t }
        end
    end
    if #running > TASKS_SHOWN then
        local mi, my = nextRow()
        local rowName = row(card, mi, my, cw, { indent = true, run = function()
            expanded.tasks = not expanded.tasks
            paintSoon()
        end })
        gitgud.setText(rowName .. "Text", "[font='Bragi-13'][colour='" .. C.link .. "']"
            .. (expanded.tasks and "Show fewer" or ("Show " .. (#running - TASKS_SHOWN) .. " more")))
    end
    if #done > 0 then
        local fi, fy = nextRow()
        local rowName = row(card, fi, fy, cw, {
            icon = expanded.finished and "Bragi-Icons/NavOpen" or "Bragi-Icons/NavClosed",
            tip = expanded.finished and "Hide the finished ones" or "Show the finished ones",
            run = function()
                expanded.finished = not expanded.finished
                paintSoon()
            end })
        gitgud.setText(rowName .. "Text", "[font='Bragi-13'][colour='" .. C.sub .. "']" .. #done .. " finished")
        if expanded.finished then
            for i, t in ipairs(done) do
                if i > FINISHED_SHOWN then
                    break
                end
                local failed = t.state == "failed"
                local di, dy = nextRow()
                local rn, w = row(card, di, dy, cw, {
                    icon = failed and "Bragi-Panel/Cross" or (t.state == "stopped" and "Bragi-Panel/Stop"
                        or "Bragi-Panel/Check"),
                    iconColour = failed and C.err or C.sub,
                    tip = (t.title or "Task") .. ": " .. (END_WORDS[t.state] or t.state),
                    meta = elapsed((t.ended or gitgud.now()) - t.started),
                })
                gitgud.setText(rn .. "Text", fitted("Bragi-13", C.sub, t.title or "Task", w))
            end
        end
    end
    hideRows(card, n + 1)
    return n * ROW + 8
end

-- What a card's header says beside its title (always for Context, else
-- while it's folded), or nil.
local brief = {}

function brief.environment()
    return nil
end

function brief.context(tab)
    local d = dataOf(tab and tab.session.name)
    if not d or not d.tokens then
        return nil
    end
    return math.floor(math.min(1, d.tokens / windowOf(d, tab)) * 100 + 0.5) .. "%"
end

function brief.outputs(tab)
    local count = #outputsOf(tab)
    return count > 0 and tostring(count) or nil
end

function brief.changes(tab)
    local entry = summaries[folderOf(tab)]
    local sum = entry and entry.data
    return sum and ("+" .. thousands(sum.added) .. "  -" .. thousands(sum.removed)) or nil
end

function brief.tasks(tab)
    local running = taskLists(dataOf(tab and tab.session.name))
    return #running > 0 and (#running .. " running") or nil
end

--- A card: its box, its header (title, summary, chevron), its body.
local function paintCard(spec, y, cw, tab)
    local card = "AgentPanelCard" .. spec.key:sub(1, 1):upper() .. spec.key:sub(2)
    if make("Bragi/Box10", card, "AgentPanelScroll") then
        gitgud.setProperty(card, "FillColour", C.panel)
        gitgud.setProperty(card, "BorderColour", C.border)
    end
    local head = card .. "Head"
    if make("Bragi/Button10", head, card) then
        gitgud.setProperty(head, "Text", "")
        gitgud.setProperty(head, "NormalFillColour", C.transparent)
        gitgud.setProperty(head, "HoverFillColour", C.hover)
        gitgud.setProperty(head, "PushedFillColour", C.sel)
        gitgud.setProperty(head, "BorderColour", C.transparent)
        gitgud.on(head .. ".clicked", function()
            settings.set("bragi.panel." .. spec.key, not cardOpen(spec.key))
            paintSoon()
            if spec.key == "changes" or spec.key == "environment" then
                summarySoon()
            end
        end)
    end
    local open = cardOpen(spec.key)
    gitgud.setProperty(head, "Area", geometry.rect(0, 0, cw, HEAD))
    gitgud.setProperty(head, "TooltipText", open and "Fold it" or "Unfold it")
    local title = label(head .. "Title", head, "Bragi-13-Bold", C.text)
    gitgud.setProperty(title, "Area", geometry.rect(14, 0, cw - 120, HEAD))
    gitgud.setText(title, text.escape(spec.title))
    local summaryLabel = label(head .. "Sum", head, "Bragi-12", C.sub, "RightAligned")
    gitgud.setProperty(summaryLabel, "Area", geometry.rect(cw - 130, 0, 100, HEAD))
    local chevron = icon(head .. "Chevron", head, open and "Bragi-Icons/NavOpen" or "Bragi-Icons/NavClosed", C.sub)
    gitgud.setProperty(chevron, "Area", geometry.rect(cw - 28, 12, 16, 16))

    local h = HEAD
    if open then
        h = HEAD + body[spec.key](card, HEAD, cw, tab)
    else
        hideRows(card, 1)
        for _, part in ipairs({ "Line", "Track", "Fill", "Counts", "Files", "Pr" }) do
            if made[card .. part] then
                gitgud.setVisible(card .. part, false)
            end
        end
    end
    local summary = brief[spec.key](tab)
    gitgud.setText(summaryLabel, summary and text.escape(summary) or "")
    gitgud.setVisible(summaryLabel, summary ~= nil and (not open or spec.key == "context"))
    gitgud.setProperty(card, "Area", geometry.rect(MARGIN, y, cw, h))
    last.cards[spec.key] = { open = open, summary = summary, height = h, name = card }
    return h
end

--- Tick the running tasks' times.
local function tick()
    tickTimer = nil
    if not visible or #ticking == 0 then
        return
    end
    for _, t in ipairs(ticking) do
        if t.task.state == "running" then
            gitgud.setText(t.label, elapsed(gitgud.now() - t.task.started))
        end
    end
    tickTimer = gitgud.after(TICK_MS, tick)
end

--- Draw every card for the conversation shown.
function sidepanel.paint()
    paintPending = false
    if not visible then
        return
    end
    local tab = agent.current()
    local _, _, _, paneH = gitgud.getRect("AgentPanelScroll")
    last = { cards = {}, folder = folderOf(tab) }
    gitgud.setText("AgentPanelTitle", "SESSION")
    local function all(cw)
        local y = MARGIN
        for _, spec in ipairs(CARDS) do
            y = y + paintCard(spec, y, cw, tab) + CARD_GAP
        end
        return y
    end
    local cw = width - 2 * MARGIN
    local total = all(cw)
    if paneH and total > paneH then
        all(cw - SCROLLBAR) -- room for the scrollbar
    end
    if #ticking > 0 and not tickTimer then
        tickTimer = gitgud.after(TICK_MS, tick)
    end
end

paintSoon = function()
    if paintPending or not visible then
        return
    end
    paintPending = true
    gitgud.after(60, function()
        if paintPending then
            sidepanel.paint()
        end
    end)
end

-- ===================================================================
-- Placing and showing
-- ===================================================================

local function paintButton()
    gitgud.setProperty("AgentPanelIcon", "IconColour", visible and C.accentText or C.sub)
    gitgud.setProperty("AgentPanelButton", "NormalFillColour", visible and C.sel or C.transparent)
    gitgud.setProperty("AgentPanelButton", "TooltipText", visible and "Hide the session panel"
        or (wide and "Show the session panel" or "Show the session panel over the conversation (the window is narrow)"))
end

--- Place the panel for the width the Agent view has beside the sessions
-- list (agent.lua's relayout). Returns the width the conversation gives
-- it: PANEL beside it, 0 when hidden or over it.
function sidepanel.place(available)
    room = available or 0
    width = split and split.width() or PANEL
    wide = room - width >= MIN_MAIN
    if wide then
        forced = false
    end
    local was = visible
    visible = (settings.get("bragi.panel", true) and wide) or (forced and not wide)
    if split then
        if visible and wide then
            split.place(width, 0, 0)
        else
            split.hide()
        end
    end
    if visible then
        local top = wide and 0 or HEADER
        gitgud.setProperty("AgentPanel", "Area", geometry.area(1, -width, 0, top, 1, 0, 1, 0))
        gitgud.setVisible("AgentPanelHeader", wide)
        gitgud.setProperty("AgentPanelScroll", "Area", geometry.area(0, 0, 0, wide and HEADER or 0, 1, 0, 1, 0))
        sidepanel.paint()
        if not was then
            summarySoon()
        end
    end
    gitgud.setVisible("AgentPanel", visible)
    paintButton()
    return (visible and wide) and width or 0
end

--- Show or hide it: remembered when there's room beside the conversation,
-- else over the conversation until it's clicked again.
function sidepanel.toggle()
    if wide then
        settings.set("bragi.panel", not settings.get("bragi.panel", true))
    else
        forced = not forced
    end
    agent.relayout()
end

--- Show the panel with one of its cards unfolded (/tasks: "tasks").
function sidepanel.showCard(key)
    settings.set("bragi.panel." .. key, true)
    settings.set("bragi.panel", true)
    if not wide then
        forced = true
    end
    agent.relayout()
    sidepanel.paint()
end

--- A session's context (bragi/usage.lua): { tokens, window, model }, the
-- window only once a turn's result named it; nil before any model call.
function sidepanel.context(name)
    local d = dataOf(name)
    if not d or not d.tokens then
        return nil
    end
    return { tokens = d.tokens, window = d.window, model = d.model }
end

--- What it shows (for tests): { visible, wide, forced, folder, cards =
-- { [key] = { open, summary } }, environment, context, outputs, changes,
-- tasks = { running, finished } }.
function sidepanel.snapshot()
    local out = {}
    for k, v in pairs(last) do
        out[k] = v
    end
    out.visible, out.wide, out.forced = visible, wide, forced
    return out
end

-- ===================================================================
-- Hot-reload: the tasks and pull requests carry on
-- ===================================================================

local KEPT = "bragi.sidepanel"

local function keep()
    local list = {}
    for name, d in pairs(sessions) do
        list[name] = { tokens = d.tokens, model = d.model, window = d.window, tasks = d.tasks }
    end
    local json = gitgud.jsonEncode({ sessions = list, prs = prs, expanded = expanded, forced = forced })
    if json then
        gitgud.keepForReload(KEPT, json)
    end
end

local function restore()
    local state = gitgud.jsonDecode(gitgud.takeKept(KEPT) or "")
    if type(state) ~= "table" then
        return
    end
    for name, d in pairs(type(state.sessions) == "table" and state.sessions or {}) do
        local s = dataOf(name, true)
        s.tokens, s.model, s.window = d.tokens, d.model, d.window
        for _, t in ipairs(type(d.tasks) == "table" and d.tasks or {}) do
            t.stopping = nil
            addTask(s, t)
        end
    end
    for k, v in pairs(type(state.prs) == "table" and state.prs or {}) do
        if v.number then
            prs[k] = v
        end
    end
    for k, v in pairs(type(state.expanded) == "table" and state.expanded or {}) do
        expanded[k] = v == true
    end
    forced = state.forced == true
end

-- ===================================================================
-- Events
-- ===================================================================

--- A session's event: its data updated, the panel repainted when it's the
-- one shown.
local function onEvent(fn)
    return function(detail)
        local e = gitgud.jsonDecode(detail)
        if type(e) ~= "table" or not e.session or not tabOf(e.session) then
            return
        end
        local d = dataOf(e.session, true)
        fn(d, e)
        local tab = agent.current()
        if tab and tab.session.name == e.session then
            paintSoon()
        end
    end
end

function sidepanel.init()
    restore()
    -- Its left edge drags (the width is remembered); the conversation keeps
    -- MIN_MAIN beside it.
    split = require("ui.splitter").column({
        name = "AgentPanelSplit", parent = "AgentRoot", pane = "AgentPanel", edge = "right",
        key = "bragi.panelWidth", default = PANEL, min = PANEL_MIN,
        -- Dragged, it stops where the conversation would get too narrow;
        -- else it keeps its width and hides when there isn't room.
        max = function()
            return split.dragging() and math.min(PANEL_MAX, room - MIN_MAIN) or PANEL_MAX
        end,
        relayout = agent.relayout,
        done = function()
            if visible then
                sidepanel.paint()
            end
        end,
    })
    gitgud.on("AgentPanelButton.clicked", sidepanel.toggle)

    gitgud.on("agent.usage", onEvent(function(d, e)
        if (e.parent or "") ~= "" or type(e.usage) ~= "table" or e.model == "<synthetic>" then
            return -- a sub-agent's calls fill its own context; a command's output used none
        end
        local u = e.usage
        d.tokens = (tonumber(u.input_tokens) or 0) + (tonumber(u.cache_creation_input_tokens) or 0)
            + (tonumber(u.cache_read_input_tokens) or 0) + (tonumber(u.output_tokens) or 0)
        d.model = e.model
    end))
    gitgud.on("agent.tool", onEvent(onTool))
    gitgud.on("agent.toolResult", onEvent(function(d, e)
        onToolResult(d, e)
        local tab = agent.current()
        if tab and tab.session.name == e.session then
            local step = tab.byToolId and tab.byToolId[e.id or ""]
            if step and CHANGES_FILES[step.title or ""] then
                summarySoon()
            end
        end
    end))
    gitgud.on("agent.system", onEvent(onSystem))
    gitgud.on("agent.result", onEvent(function(d, e)
        local usage = type(e.modelUsage) == "table" and e.modelUsage or {}
        local entry = usage[d.model or ""]
        if type(entry) ~= "table" then
            local only, count = nil, 0
            for _, v in pairs(usage) do
                count = count + 1
                only = v
            end
            entry = count == 1 and only or nil
        end
        if type(entry) == "table" and tonumber(entry.contextWindow) then
            d.window = tonumber(entry.contextWindow)
        end
        local known, changed = learnedWindows(), false
        for model, v in pairs(usage) do
            local size = type(v) == "table" and tonumber(v.contextWindow)
            if size and known[model] ~= size then
                known[model], changed = size, true
            end
        end
        if changed then
            settings.set(WINDOWS_KEY, gitgud.jsonEncode(known))
        end
        -- The turn's own sub-agents ended with it.
        for _, t in ipairs(d.tasks) do
            if not t.background then
                finish(t, e.interrupted and "stopped" or "completed")
            end
        end
        local tab = agent.current()
        if tab and tab.session.name == e.session then
            summarySoon()
        end
    end))
    gitgud.on("agent.exit", onEvent(function(d)
        for _, t in ipairs(d.tasks) do
            finish(t, "stopped") -- the process took them with it
        end
    end))
    gitgud.on("agent.init", onEvent(function() end))

    gitgud.on(SUMMARY .. ".done", function(detail)
        local data = gitgud.jsonDecode(detail or "")
        summaryDone(type(data) == "table" and { data = data } or { error = "unreadable" })
    end)
    gitgud.on(SUMMARY .. ".error", function(msg)
        summaryDone({ error = msg or "" })
    end)
    gitgud.on(PUSH .. ".done", function(detail)
        local fn = pushWaiting
        pushWaiting = nil
        if fn then
            fn(true, detail)
        end
    end)
    gitgud.on(PUSH .. ".error", function(msg)
        local fn = pushWaiting
        pushWaiting = nil
        if fn then
            fn(false, msg)
        end
    end)

    app.subscribe("bragi.tabShown", function()
        expanded.outputs, expanded.tasks = false, false
        paintSoon()
        summarySoon()
    end)
    app.subscribe("bragi.server", paintSoon)
    gitgud.on("app.reloading", keep)
    agent.relayout()
end

--- How many of a tab's background tasks (sub-agents, background commands)
-- are running: they live in its session's process.
function sidepanel.running(tab)
    local d = tab and tab.session and dataOf(tab.session.name)
    local count = 0
    for _, t in ipairs(d and d.tasks or {}) do
        if t.state == "running" and t.background then
            count = count + 1
        end
    end
    return count
end

function sidepanel.refresh()
    summarySoon()
    paintSoon()
end

return sidepanel
