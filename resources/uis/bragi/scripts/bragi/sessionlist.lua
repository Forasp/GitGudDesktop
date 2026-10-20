--- bragi/sessionlist.lua: the Agent view's conversations list
-- (AgentSessionList), grouped by project.
--
--   Bragi            the master conversation (bragi/master.lua), pinned at
--                    the top, outside every project
--   project header   its folder's name and how many conversations; a click
--                    opens or closes it (remembered, bragi.projectsOpen),
--                    the + at its right starts a conversation there
--   conversations    under it, by their last message (asked or answered),
--                    newest first: live tabs (with their state: running,
--                    needs you, finished, failed) and Claude Code's saved
--                    ones together. Showing or opening one doesn't move it
--. The app's own helpers are left out,
--                    scheduled runs are one row ("Scheduled runs (n)")
--   more             "Show n more" past the first MAX_SHOWN
--
-- Projects are ordered by their latest activity (the same times). A project starts open when it holds the conversation shown, a
-- live one, or the open repository, or is one of the first OPEN_FIRST.
--
-- The rows (sessionlist.rows(), as agent.sessionRows()): { master = true },
-- { header = group }, { tab = tab, group }, { saved = s, group },
-- { scheduled = n, group }, { more = n, group }; a group is { key, name,
-- cwd, updated, sessions, tabs }.
--
-- Public API: sessionlist.paint(ctx), sessionlist.rows(), sessionlist.isOpen(group),
-- sessionlist.setOpen(key, open), sessionlist.toggleScheduled(key),
-- sessionlist.showMore(key), sessionlist.plusHit(x), sessionlist.ROW
-- ctx: { tabs, cur, master (the master tab or nil), masterState, tabState(tab),
-- savedKind(first message), groups (projects.conversations()) }

local C = require("core.palette")
local settings = require("core.settings")
local text = require("core.text")

local sessionlist = { name = "bragi.sessionlist" }

sessionlist.ROW = 56        -- a conversation: two lines (design D)
local HEADER = 34           -- a project's header
local SMALL = 34            -- scheduled runs, show more
local MAX_SHOWN = 8         -- conversations shown per project before "more"
local OPEN_FIRST = 3        -- projects open by default
local PLUS = 30             -- the + zone at a header's right

local STATE_COLOUR = { permission = "caution", running = "accentText", done = "add", failed = "err" }
local STATE_WORDS = { permission = "Waiting for you", running = "Running", done = "Finished", failed = "Failed" }

local rows = {}
local scheduledOpen = {}    -- project key -> its scheduled runs are listed
local moreOpen = {}         -- project key -> every conversation is listed
local openState = nil       -- project key -> open (bragi.projectsOpen)

local function loadOpen()
    if not openState then
        local parsed = gitgud.jsonDecode(settings.get("bragi.projectsOpen", "") ~= ""
            and settings.get("bragi.projectsOpen", "") or "{}")
        openState = type(parsed) == "table" and parsed or {}
    end
    return openState
end

--- Remember a project open or closed.
function sessionlist.setOpen(key, open)
    loadOpen()[key] = open == true
    settings.set("bragi.projectsOpen", gitgud.jsonEncode(openState) or "{}")
end

--- Whether a group is open: as remembered, else by default.
function sessionlist.isOpen(group)
    local saved = loadOpen()[group.key]
    if saved ~= nil then
        return saved == true
    end
    return group.defaultOpen == true
end

function sessionlist.toggleScheduled(key)
    scheduledOpen[key] = not scheduledOpen[key] or nil
end

function sessionlist.showMore(key)
    moreOpen[key] = true
end

function sessionlist.rows()
    return rows
end

local SPACER = "[image-size='w:%d h:%d'][image='Gitgud-Images/Spacer']"

--- A conversation row: the title (cut to fit), and under it what it's
-- doing, or when a saved one was last used.
local function conversationRow(title, state, updated, width, words, indent)
    local rowsLib = require("bragi.rows")
    local meta = words or (state and STATE_WORDS[state]) or (updated and text.ago(updated)) or "Open"
    local colour = state and C[STATE_COLOUR[state]] or C.sub
    local pad = 9 + (indent or 0)
    return "[vert-formatting='BottomAligned']" .. SPACER:format(pad, 28)
        .. "[font='Bragi-13-Bold'][colour='" .. C.text .. "']"
        .. text.escape(rowsLib.fitText("Bragi-13-Bold", title, width - (indent or 0))) .. "\n"
        .. "[vert-formatting='TopAligned']" .. SPACER:format(pad, 28)
        .. "[padding='l:0 t:3 r:0 b:0'][font='Bragi-12'][colour='" .. colour .. "']" .. text.escape(meta)
end

--- A one-line row (scheduled runs, show more).
local function smallRow(label, width, indent)
    local rowsLib = require("bragi.rows")
    return "[vert-formatting='CentreAligned']" .. SPACER:format(9 + indent, SMALL)
        .. "[font='Bragi-12'][colour='" .. C.sub .. "']"
        .. text.escape(rowsLib.fitText("Bragi-12", label, width - indent))
end

--- A project's header: chevron, name, count, and + at the right. Gaps
-- are spacer pictures: padding on text would space out every letter.
local function headerRow(group, open, count, width)
    local sprites = require("core.sprites")
    local rowsLib = require("bragi.rows")
    local name = rowsLib.fitText("Bragi-13-Bold", group.name, width - 70)
    local left = "[vert-formatting='CentreAligned']" .. SPACER:format(4, HEADER)
        .. sprites.image(open and "NavOpen" or "NavClosed", 16, 16) .. SPACER:format(6, 1)
        .. "[font='Bragi-13-Bold'][colour='" .. C.text .. "']" .. text.escape(name) .. SPACER:format(8, 1)
        .. "[font='Bragi-12'][colour='" .. C.sub .. "']" .. count
    local gap = math.max(4, math.floor(width - rowsLib.measure(left) - 18))
    return left .. SPACER:format(gap, 1) .. "[colour='" .. C.sub
        .. "'][image-size='w:12 h:12'][image='Bragi-Icons/Plus']"
end

--- The pinned master row.
local function masterRow(state, width)
    local meta = state and STATE_WORDS[state] or "Every project, one conversation"
    local colour = state and C[STATE_COLOUR[state]] or C.sub
    local rowsLib = require("bragi.rows")
    return "[vert-formatting='BottomAligned']" .. SPACER:format(9, 28)
        .. "[font='Bragi-13-Bold'][colour='" .. C.accentText .. "']"
        .. text.escape(rowsLib.fitText("Bragi-13-Bold", "Bragi", width)) .. "\n"
        .. "[vert-formatting='TopAligned']" .. SPACER:format(9, 28)
        .. "[padding='l:0 t:3 r:0 b:0'][font='Bragi-12'][colour='" .. colour .. "']"
        .. text.escape(rowsLib.fitText("Bragi-12", meta, width))
end

--- When a conversation's last message was: a saved one's from its
-- transcript (or a tab here since), a live tab's as it was sent or answered.
local function activeAt(entry)
    if entry.tab then
        return entry.tab.updated or os.time()
    end
    return require("bragi.agent").activeAt(entry.saved)
end

--- The groups: saved conversations by project, plus live tabs.
local function buildGroups(ctx)
    local projects = require("bragi.projects")
    local byKey, groups = {}, {}
    local function group(key, name, cwd, updated)
        local g = byKey[key]
        if not g then
            g = { key = key, name = name, cwd = cwd, updated = updated or 0, sessions = {}, tabs = {} }
            byKey[key] = g
            groups[#groups + 1] = g
        end
        return g
    end
    -- Claude Code can keep one project's conversations in several folders
    -- (one begun there, then moved to a worktree): they all list, newest
    -- first (a worktree's one old conversation took the
    -- place of the project's others).
    for _, p in ipairs(ctx.groups or {}) do
        local g = group(p.key, p.name, p.cwd, p.updated)
        if #g.sessions == 0 then
            g.sessions = p.sessions or {}
        else
            local merged, seen = {}, {}
            for _, list in ipairs({ g.sessions, p.sessions or {} }) do
                for _, s in ipairs(list) do
                    if not seen[s.id] then
                        seen[s.id] = true
                        merged[#merged + 1] = s
                    end
                end
            end
            table.sort(merged, function(a, b)
                return activeAt({ saved = a }) > activeAt({ saved = b })
            end)
            g.sessions = merged
            g.updated = math.max(g.updated, p.updated or 0)
        end
    end
    local open = require("core.repo").state().path
    for i = #ctx.tabs, 1, -1 do
        local tab = ctx.tabs[i]
        if tab ~= ctx.master and not tab.master
            and (#tab.items > 0 or (tab.session.running and not tab.session.warm)) then
            -- Not started yet: it starts in the open repository.
            local cwd = tab.cwd or open
            local key = cwd ~= "" and projects.key(cwd) or ""
            local at = activeAt({ tab = tab })
            local g = group(key, cwd ~= "" and projects.name(cwd) or "No folder", cwd, at)
            g.tabs[#g.tabs + 1] = tab
            g.updated = math.max(g.updated, at)
        end
    end
    table.sort(groups, function(a, b)
        if a.updated ~= b.updated then
            return a.updated > b.updated
        end
        return a.name:lower() < b.name:lower()
    end)
    local openKey = projects.key(require("core.repo").state().path)
    local curKey = ctx.cur and ctx.cur.cwd and projects.key(ctx.cur.cwd) or nil
    for i, g in ipairs(groups) do
        g.defaultOpen = i <= OPEN_FIRST or #g.tabs > 0 or (openKey ~= "" and g.key == openKey) or g.key == curKey
    end
    return groups
end

--- Build the rows and paint the list.
function sessionlist.paint(ctx)
    rows = { { master = true } }
    local groups = buildGroups(ctx)
    for _, g in ipairs(groups) do
        local live = {}
        for _, tab in ipairs(g.tabs) do
            live[tab.session.id or false] = true
            live[tab.session.resume or false] = true
        end
        local entries, scheduled = {}, {}
        for _, tab in ipairs(g.tabs) do
            entries[#entries + 1] = { tab = tab, group = g }
        end
        for _, s in ipairs(g.sessions) do
            -- By what it began with: a scheduled run's title can be
            -- Claude Code's own.
            local kind = ctx.savedKind(s.asked or s.title)
            if live[s.id] or kind == "helper" then
                -- shown as its tab, or one of the app's own helpers: not listed
            elseif kind == "scheduled" then
                scheduled[#scheduled + 1] = s
            else
                entries[#entries + 1] = { saved = s, group = g }
            end
        end
        -- Live and saved together, by their last message; ties keep the
        -- order they came in.
        for i, entry in ipairs(entries) do
            entry.at, entry.order = activeAt(entry), i
        end
        table.sort(entries, function(a, b)
            if a.at ~= b.at then
                return a.at > b.at
            end
            return a.order < b.order
        end)
        g.count = #entries + #scheduled
        if g.count > 0 then
            rows[#rows + 1] = { header = g, group = g }
            if sessionlist.isOpen(g) then
                local shown, hidden = 0, 0
                for _, entry in ipairs(entries) do
                    if entry.tab or moreOpen[g.key] or shown < MAX_SHOWN then
                        rows[#rows + 1] = entry
                        shown = shown + 1
                    else
                        hidden = hidden + 1
                    end
                end
                if hidden > 0 then
                    rows[#rows + 1] = { more = hidden, group = g }
                end
                if #scheduled > 0 then
                    rows[#rows + 1] = { scheduled = #scheduled, group = g }
                    if scheduledOpen[g.key] then
                        for _, s in ipairs(scheduled) do
                            rows[#rows + 1] = { saved = s, group = g }
                        end
                    end
                end
            end
        end
    end

    local _, _, listW, listH = gitgud.getRect("AgentSessionList")
    local total = 0
    for _, row in ipairs(rows) do
        total = total + ((row.header and HEADER) or ((row.more or row.scheduled) and SMALL) or sessionlist.ROW)
    end
    local scrollbar = listH and total > listH - 4 and 14 or 0
    local width = (listW or 240) - 14 - scrollbar - 9 - 12
    local list, selected = {}, nil
    for i, row in ipairs(rows) do
        if row.master then
            list[i] = masterRow(ctx.masterState, width)
            if ctx.master and ctx.cur == ctx.master then
                selected = i
            end
        elseif row.header then
            list[i] = headerRow(row.header, sessionlist.isOpen(row.header), row.header.count, width + 9)
        elseif row.more then
            list[i] = smallRow("Show " .. row.more .. " more", width, 12)
        elseif row.scheduled then
            list[i] = smallRow("Scheduled runs (" .. row.scheduled .. ")"
                .. (scheduledOpen[row.group.key] and "  \u{00B7}  hide" or ""), width, 12)
        else
            local title = row.tab and row.tab.title or row.saved.title
            local state = row.tab and ctx.tabState(row.tab)
            -- A saved one being used outside this app says so.
            local words = row.saved and require("bragi.agent").inUseElsewhere(row.saved.id, row.saved.updated, true)
                and "In use elsewhere" or nil
            list[i] = conversationRow(title, state, row.saved and activeAt(row), width, words, 12)
            if row.tab and row.tab == ctx.cur then
                selected = i
            end
        end
    end
    require("bragi.rows").select("AgentSessionList", sessionlist.ROW, #rows)
    gitgud.setList("AgentSessionList", list)
    gitgud.selectListItem("AgentSessionList", selected, false)
    gitgud.setVisible("AgentSessionsEmpty", false)
    sessionlist.selected = selected
    return rows
end

--- Whether a click at screen x hits a header's +.
function sessionlist.plusHit(x)
    local lx, _, lw = gitgud.getRect("AgentSessionList")
    return lx ~= nil and tonumber(x) ~= nil and tonumber(x) >= lx + lw - PLUS - 14
end

return sessionlist
