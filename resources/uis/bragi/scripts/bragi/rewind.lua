--- bragi/rewind.lua: take a conversation back to one of your messages, or
-- start a new one from it. Each message you sent has two
-- quiet buttons under it (bragi/agent.lua's draw.user), shown while the
-- mouse is over the message (its "hovered" events), or
-- under every message after /rewind (rewind.showAll) until one is used or
-- the next message goes:
--
--   Rewind  the conversation goes back to just before that message: it and
--           everything after it leave the view, and its text (and
--           pictures) go back into the prompt box, to change and send
--           again. The next message resumes the session at the entry
--           before it (agentStart's resumeAt); what came after stays in the
--           transcript, on a branch left behind. Only the conversation goes
--           back: files Claude Code changed stay as they are.
--   Fork    a new conversation with everything up to that message's
--           answer; the one it's from stays as it is. Its first message
--           resumes the session as a new one there (forkSession, resumeAt).
--           It's titled like the one it's from plus FORK_SUFFIX,
--           kept for its saved conversation too
--           (projects.setTitle).
--
-- From Bragi, the master conversation, a fork goes to the project the
-- conversation was about up to there (rewind.projectFor), else to a
-- conversation of no project (projects.loneDir), never into the master's
-- own folder. Claude Code resumes a session only in its own folder, so the
-- transcript is copied there (gitgud.agentForkTranscript) and the copy
-- opens like any saved conversation.
--
-- A message is found in the transcript by its text: your sent messages
-- are matched to the transcript's from the end (it has more of them:
-- interruptions, for one). Neither works while an answer is coming.
--
-- The same row has a Copy button first, on every message with text.
--
-- Public API: rewind.drawActions(item, bubbleWidth, bubbleHeight),
-- rewind.actionsShown(item), rewind.forkTitle(title), rewind.showAll(on),
-- rewind.rewindTo(item), rewind.forkFrom(item), rewind.locate(tab, item),
-- rewind.projectFor(tab, item)

local C = require("core.palette")
local geometry = require("ui.geometry")
local text = require("core.text")

local rewind = { name = "bragi.rewind" }

local BUTTON = 22         -- each button, square
local BUTTON_GAP = 2
local ROW_GAP = 4         -- between the bubble and its buttons
local LOOK_BACK = 5000    -- transcript entries searched for a message
local SHOWN = 300         -- history entries a fork opens with (agent.lua's HISTORY_ENTRIES)
local MIN_NAME = 3        -- shorter project names aren't looked for in text
local FORK_SUFFIX = " (fork)"

local function agent()
    return require("bragi.agent")
end

local function say(message)
    require("core.status").info(message)
end

-- ===================================================================
-- The buttons
-- ===================================================================

local function button(row, name, icon, tip, x, run)
    gitgud.createWindow("Bragi/Button8", name, row)
    gitgud.setProperty(name, "Area", geometry.rect(x, 0, BUTTON, BUTTON))
    gitgud.setProperty(name, "Text", "")
    gitgud.setProperty(name, "NormalFillColour", C.transparent)
    gitgud.setProperty(name, "HoverFillColour", C.hover)
    gitgud.setProperty(name, "BorderColour", C.transparent)
    gitgud.setProperty(name, "TooltipText", tip)
    gitgud.createWindow("Gitgud/Icon", name .. "Icon", name)
    gitgud.setProperty(name .. "Icon", "Area", geometry.rect(3, 3, BUTTON - 6, BUTTON - 6))
    gitgud.setProperty(name .. "Icon", "IconImage", "Bragi-Icons/" .. icon)
    gitgud.setProperty(name .. "Icon", "IconColour", C.disabled)
    gitgud.setProperty(name .. "Icon", "GlowColour", "00000000")
    gitgud.setProperty(name .. "Icon", "CursorPassThroughEnabled", "true")
    gitgud.on(name .. ".clicked", run)
end

local everyMessage = false -- /rewind: every message's buttons show

--- The mouse over a message (or off it): its buttons show (or hide).
local function hover(item, on)
    item.hovered = on
    local row = item.name .. "Actions"
    if gitgud.getRect(row) then
        gitgud.setVisible(row, on or everyMessage)
    end
end

--- Show every message's buttons (/rewind), or only the one under the
-- mouse again.
function rewind.showAll(on)
    if on == false and not everyMessage then
        return
    end
    everyMessage = on ~= false
    for _, item in ipairs(agent().items()) do
        local row = item.name .. "Actions"
        if item.kind == "user" and gitgud.getRect(row) then
            gitgud.setVisible(row, everyMessage or item.hovered == true)
        end
    end
    if everyMessage then
        say("Rewind or fork from any of your messages: the buttons under each one.")
    end
end

--- Draw a message's buttons under its bubble, right-aligned, shown while
-- the mouse is over it (the room for them is always kept, so nothing
-- moves): Copy on any with text (bragi/textselect.lua), Rewind and Fork
-- on one that went to Claude Code. Returns the row's width and the height
-- it adds (0, 0 when there's none).
function rewind.drawActions(item, bubbleWidth, bubbleHeight)
    local row = item.name .. "Actions"
    local copy = (item.text or "") ~= ""
    local back = item.sent and not item.pending
    local count = (copy and 1 or 0) + (back and 2 or 0)
    local kind = (copy and "c" or "") .. (back and "r" or "")
    if gitgud.getRect(row) and item.actionsKind ~= kind then
        gitgud.destroyWindow(row)
    end
    if count == 0 then
        return 0, 0
    end
    local width = count * BUTTON + (count - 1) * BUTTON_GAP
    if not item.hoverWatched then
        item.hoverWatched = true
        gitgud.setProperty(item.name, "ReportHover", "true")
        gitgud.on(item.name .. ".hovered", function(value)
            hover(item, value == "1")
        end)
    end
    if not gitgud.getRect(row) then
        item.actionsKind = kind
        gitgud.createWindow("DefaultWindow", row, item.name)
        local x = 0
        if copy then
            require("bragi.textselect").copyButton(row .. "Copy", row, x, 0, function()
                return item.text
            end, "Copy", "your message")
            x = x + BUTTON + BUTTON_GAP
        end
        if back then
            button(row, row .. "Rewind", "Rewind", "Rewind to here", x, function()
                rewind.rewindTo(item)
            end)
            button(row, row .. "Fork", "Fork", "Fork from here", x + BUTTON + BUTTON_GAP, function()
                rewind.forkFrom(item)
            end)
        end
    end
    gitgud.setVisible(row, item.hovered == true or everyMessage)
    gitgud.setProperty(row, "Area", geometry.rect(math.max(bubbleWidth, width) - width,
        bubbleHeight + ROW_GAP, width, BUTTON))
    return width, ROW_GAP + BUTTON
end

--- Whether a message's buttons show now (for tests).
function rewind.actionsShown(item)
    local row = item.name .. "Actions"
    return gitgud.getRect(row) ~= nil and gitgud.getProperty(row, "Visible") == "true"
end

--- A fork's title: the one it's from plus FORK_SUFFIX.
function rewind.forkTitle(title)
    title = text.trim(tostring(title or ""))
    return (title ~= "" and title or "Session") .. FORK_SUFFIX
end

-- ===================================================================
-- Finding a message in the transcript
-- ===================================================================

--- The session a tab's transcript is (a fork not sent to yet: the one it
-- forks), or nil.
local function sessionOf(tab)
    local s = tab.session
    return s.id or s.resume or (s.startOnce and s.startOnce.resume) or nil
end

--- Whether a transcript message is the one shown.
local function matches(item, entry)
    local mine = text.trim(item.text or "")
    if mine == "" then
        return #(entry.images or {}) > 0
    end
    -- What was sent may say more after it (quick answers riding along).
    local said = text.trim(agent().shownText(entry.text))
    return said:sub(1, #mine) == mine
end

--- Where a message is in its conversation's transcript.
-- @return { id (the session), entries (the transcript's, oldest first),
--          at (the message's index in them), nextAt (the next message's,
--          nil for the last) }, or nil and why not
function rewind.locate(tab, item)
    local id = sessionOf(tab)
    if not id then
        return nil, "This conversation isn't saved yet."
    end
    local entries = gitgud.agentHistory(tab.cwd or "", id, LOOK_BACK)
    local prompts = {}
    for i, h in ipairs(entries) do
        if h.kind == "user" and (h.uuid or "") ~= "" then
            prompts[#prompts + 1] = i
        end
    end
    local mine = {}
    for _, it in ipairs(tab.items) do
        if it.kind == "user" and it.sent then
            mine[#mine + 1] = it
        end
    end
    local j = #prompts
    for i = #mine, 1, -1 do
        while j >= 1 and not matches(mine[i], entries[prompts[j]]) do
            j = j - 1
        end
        if j < 1 then
            break
        end
        if mine[i] == item then
            return { id = id, entries = entries, at = prompts[j], nextAt = prompts[j + 1] }
        end
        j = j - 1
    end
    return nil, "That message isn't in the saved conversation."
end

--- A tab's session stopped, then `after()`: its events are no longer the
-- tab's, and the next message starts it again (as the caller set it up).
local function stopThen(tab, after)
    local s = tab.session
    if not s.running or not s.name then
        after()
        return
    end
    local name = s.name
    s.name, s.running, s.warm = nil, false, nil
    gitgud.agentStop(name)
    -- The master's session keeps its name: wait for the old one to end.
    local waited = 0
    local function check()
        local info = gitgud.agentInfo(name)
        if info and info.running and waited < 3000 then
            waited = waited + 50
            gitgud.after(50, check)
        else
            after()
        end
    end
    check()
end

--- Why a tab can't go back or fork now, or nil.
local function busy(tab)
    if tab.session.turn or tab.waiting then
        return "Wait for the answer, or stop it, first."
    end
    return nil
end

-- ===================================================================
-- Rewind
-- ===================================================================

--- Take items out of a tab's view, from `item` on.
local function cutFrom(tab, item)
    local from = nil
    for i, it in ipairs(tab.items) do
        if it == item then
            from = i
            break
        end
    end
    if not from then
        return
    end
    for i = #tab.items, from, -1 do
        local it = table.remove(tab.items, i)
        gitgud.destroyWindow(it.name)
        if it.id and tab.byToolId[it.id] == it then
            tab.byToolId[it.id] = nil
        end
    end
end

--- Rewind the shown conversation to just before one of your messages.
function rewind.rewindTo(item)
    rewind.showAll(false)
    local a = agent()
    local tab = a.current()
    local why = busy(tab)
    local found
    if not why then
        found, why = rewind.locate(tab, item)
    end
    if not found then
        say(why)
        return false
    end
    local before = found.entries[found.at].parentUuid or ""
    stopThen(tab, function()
        local s = tab.session
        local once = s.startOnce or {}
        if before == "" then
            -- Its first message: there's nothing before it to go on from.
            s.id, s.resume, once = nil, nil, nil
        else
            once.resumeAt = before
            if not once.resume then
                s.id, s.resume = found.id, found.id
            end
        end
        s.startOnce = once
        cutFrom(tab, item)
        if tab == a.current() then
            a.setPrompt(item.text or "")
            for _, path in ipairs(item.images or {}) do
                a.attach(path)
            end
            a.relayout()
            gitgud.focus("AgentPromptEdit")
        end
        say("Rewound. Files Claude Code changed stay as they are.")
    end)
    return true
end

-- ===================================================================
-- Fork
-- ===================================================================

--- A project named in some text (the one named last), or nil.
local function namedIn(body, list)
    body = " " .. tostring(body or ""):lower() .. " "
    local best, bestAt = nil, 0
    for _, p in ipairs(list) do
        local name = p.name:lower()
        if #name >= MIN_NAME then
            local at, from = nil, 1
            local pattern = "%f[%w]" .. name:gsub("%W", "%%%0") .. "%f[%W]"
            while true do
                local s = body:find(pattern, from)
                if not s then
                    break
                end
                at, from = s, s + 1
            end
            if at and at > bestAt then
                best, bestAt = p, at
            end
        end
    end
    return best
end

--- The project a step of the master's acted on, or nil.
local function stepProject(item, projects)
    local tool = tostring(item.title or ""):gsub("^mcp__repo__", "")
    local input = gitgud.jsonDecode(item.inputText or "") or {}
    if type(input) ~= "table" then
        return nil
    end
    if tool == "bragi_start" or tool == "bragi_open_project" or tool == "bragi_conversations" then
        local p = input.project and projects.find(input.project)
        return p and p.path or nil
    elseif tool == "bragi_send" or tool == "bragi_read_conversation" then
        local a = agent()
        local live = input.id and a.tabFor(input.id)
        local saved = input.id and a.savedSession(input.id)
        local cwd = (live and live.cwd) or (saved and saved.cwd) or ""
        return cwd ~= "" and cwd or nil
    end
    return nil
end

--- The project a master conversation was about up to the end of a
-- message's answer: the last one its steps acted on or its words named.
-- @return the project's folder, or nil
function rewind.projectFor(tab, item)
    local projects = require("bragi.projects")
    local list = {}
    for _, p in ipairs(projects.locals()) do
        if p.exists then
            list[#list + 1] = p
        end
    end
    local last = #tab.items
    local seen = false
    for i, it in ipairs(tab.items) do
        if it == item then
            seen = true
        elseif seen and it.kind == "user" and it.sent then
            last = i - 1
            break
        end
    end
    for i = last, 1, -1 do
        local it = tab.items[i]
        local path = nil
        if it.kind == "step" then
            path = stepProject(it, projects)
        elseif it.kind == "user" or (it.kind == "assistant" and not it.tag) then
            local p = namedIn(it.text, list)
            path = p and p.path or nil
        end
        if path and not projects.isMaster(path) and gitgud.pathExists(path) then
            return path
        end
    end
    return nil
end

--- Fork the shown conversation at one of your messages: a new one with
-- everything up to its answer.
function rewind.forkFrom(item)
    rewind.showAll(false)
    local a = agent()
    local tab = a.current()
    local why = busy(tab)
    local found
    if not why then
        found, why = rewind.locate(tab, item)
    end
    if not found then
        say(why)
        return false
    end
    local nextEntry = found.nextAt and found.entries[found.nextAt] or nil
    -- The last entry of its answer: what the next message followed.
    local upTo = nextEntry and nextEntry.parentUuid or ""
    if tab.master then
        local projects = require("bragi.projects")
        local cwd = rewind.projectFor(tab, item) or projects.loneDir()
        gitgud.makeDir(cwd)
        local id, err = gitgud.agentForkTranscript(tab.cwd or "", found.id, upTo, cwd)
        if not id then
            say("Couldn't fork: " .. tostring(err))
            return false
        end
        local title = rewind.forkTitle(tab.title)
        projects.setTitle(id, title)
        projects.conversations(true)
        a.resume(id, { cwd = cwd, title = title })
        say("Forked into " .. projects.name(cwd) .. ".")
        return true
    end
    local kept = {}
    for i = 1, (found.nextAt or #found.entries + 1) - 1 do
        kept[#kept + 1] = found.entries[i]
    end
    while #kept > SHOWN do
        table.remove(kept, 1)
    end
    local title = rewind.forkTitle(tab.title)
    a.newSession({ cwd = tab.cwd, title = title })
    local fork = a.current()
    -- Its own session id comes when it first sends: the title is kept for it then.
    fork.keepTitle = title
    fork.session.startOnce = { resume = found.id, forkSession = true, resumeAt = upTo ~= "" and upTo or nil }
    a.fillHistory(fork, kept)
    say("Forked. The conversation it's from stays as it was.")
    return true
end

return rewind
