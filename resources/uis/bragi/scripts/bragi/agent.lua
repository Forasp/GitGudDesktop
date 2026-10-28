--- bragi/agent.lua: the Agent view (layouts/bragi/agent.xml, design D):
-- sessions, the conversation, the prompt box, driving Claude Code through
-- the gitgud.agent* bindings (docs/LUA_API.md, "Agent").
--
-- The conversation is a column at most COLUMN px wide (24px gutters),
-- centred in AgentMain. Items are created in their conversation's page (a
-- window in AgentTranscript, pageOf) as they arrive and stacked by layout():
--
--   user        your message, a rounded bubble on the right; Copy under it
--               while the mouse is over it, and once sent Rewind and Fork
--               (bragi/rewind.lua)
--   assistant   the agent's text, Markdown drawn by bragi/markdown.lua,
--               streamed in as it's written; Copy under it while the mouse
--               is over it, and on each code block
--
-- Any of the text can be selected with the mouse and copied (Ctrl+C, the
-- right-click menu): bragi/textselect.lua, given the shown texts in order
-- by selectable().
--   step        a tool call: its icon, what it did ("Read", "Ran"), what it
--               acted on, and how it went;
--               click it for the input and the output
--   thinking    a quiet "Thinking" row; click it for the text (not drawn
--               while it has no words: draw.thinking)
--   permission  a card asking to run a tool: Allow / Deny, and View diff
--               for a change to a file (bragi/proposed.lua)
--   question    one of Claude's multiple-choice questions (AskUserQuestion):
--               options, your own words, Skip ("Claude's questions", below)
--   note        the app's own remarks, quieter
--   plan        the agent's plan, one box per conversation: its steps with
--               a check, a turning ring, or a dashed circle; it stays last
--               (above the cards waiting on you) and changes in place
--               (bragi/plan.lua)
--
-- Sending starts a session the first time (model and permission mode from
-- the prompt box's buttons) and keeps it open; while a turn runs, Send
-- becomes Stop. The list on the left (bragi/sessionlist.lua) is Claude
-- Code's own saved conversations of every project, grouped by project
-- (bragi/projects.lua), under Bragi, the master conversation
-- (bragi/master.lua); picking one shows it and the next message resumes
-- it. New session (Ctrl+N) closes the current one.
--
-- Each conversation keeps its own working folder (tab.cwd):
-- it starts, resumes, and reads its history there, never in
-- whatever repository is open. A new one takes the open repository's (or
-- its project's, from the + on a project's header). Showing a
-- conversation opens its folder as the app's repository when it's one
-- (and isn't open already), so the Repo view, the quick answers, and the
-- repo tools match the conversation on screen.
--
-- Every main session gets prompts/main-session.md as an appended system
-- prompt: a reply that ends by asking the user to decide
-- asks with a question card (AskUserQuestion), which voice reads out and
-- takes a spoken answer to without the wake word. A session on an issue
-- gets the issue's prompt after it. Routines and helpers don't.
--
-- The program is bragi.claudeProgram ("claude"); UI tests point it at the
-- fake one (tests/fake_claude.cpp), never the real Claude Code.
--
-- The prompt box keeps one primary action filled: the mic while the box is
-- empty, Send once there's text, Stop while a turn runs. The mic turns
-- listening on and off (bragi/voice.lua): while it's on the mic stays lit,
-- the level meter moves with speech, a message being heard shows live in
-- the prompt box, and Send ends it.
--
-- Slash commands: typing "/" at the start of the prompt box
-- offers the session's commands and skills (from its init) in a dropdown.
-- They go to Claude Code as typed, which runs them. The CLI's
-- interactive-only commands open the app's own screens instead (SLASH_APP):
-- /model, /effort, /permissions, /output-style, /config, /login, /status,
-- /mcp go to Settings, Claude; /memory to Instructions and memory; /clear
-- and /new start a new session. The CLI's own screens open the app's
-- (SLASH_SCREENS): /help the Shortcuts in Settings,
-- /resume the conversations list, /rewind every message's Rewind and Fork,
-- /tasks the session panel's Background tasks. Output style applies from
-- the next session (--settings); the model and effort change in a running
-- session at once (showChoices, --effort at its start), also when the agent
-- sets them (bragi/settingstool.lua: "switch to Sonnet", "think harder").
-- With arguments ("/model sonnet") they go to Claude Code, which runs them
-- headless, and the app's controls stay as they are. A command goes alone,
-- without voice context or quick-answer notes (they'd be its arguments).
-- A command's output (/context, /usage) shows as the agent's reply;
-- compaction (/compact, or automatic) shows as a note, and the messages
-- it sends again show once.
--
-- agent.workOn(task) starts a session on an issue: it's told
-- the issue and to close it from the final commit, and the server follows
-- it (a session record with working / waiting / failed, and one issue
-- comment with the latest progress).
--
-- Quick answers (bragi/quick.lua): what you type goes through
-- agent.submit, which asks for its route first; a quick question is
-- answered by Haiku under the message, tagged "Answered by Haiku"
-- (agent.quickAnswered), or handed back to the agent with a note
-- (agent.quickHandoff). The next message the agent gets carries the quick
-- answers since its last one: "Meanwhile, Haiku answered:", then each
-- question and answer (not shown in your message). The agent's text in
-- progress when an answer goes in stays above it.
--
-- For bragi/master.lua: agent.openTab(opts), agent.sendTo(tab, text),
-- agent.noteIn(tab, text, opts), agent.tabFor(id), agent.current(),
-- agent.savedSession(id); tabs may carry master, extraPrompt (added to
-- the appended system prompt), startOptions (agentStart's, over the
-- usual), sessionName, and allowTool(name) (a permission it grants itself).
--
-- Voice context: what was said before a spoken message
-- (send's `context`) goes to the agent after the message, in a
-- <voice-context> block that says it's context, not their words. The view
-- shows only the message, live and in a reloaded transcript
-- (agent.shownText).
--
-- Public API: agent.send(text, opts), agent.submit(), agent.addMessage(role, text, opts),
-- agent.withContext(body, context), agent.shownText(text),
-- agent.updateNote(item, text), agent.clear(),
-- agent.slashCommands(), agent.completeSlash(name), agent.newSession(),
-- agent.items(), agent.session(), agent.resume(id), agent.refreshSessions(),
-- agent.workOn(task), agent.tabs(), agent.showTab(tab), agent.tabState(tab),
-- agent.answerQuestion(item, choice, opts), agent.openQuestion(), agent.typedChoice(item, body),
-- agent.choiceLabel(list, key, default), agent.pickChoice(button, list, key, default),
-- for bragi/voice.lua: agent.voiceStatus(line, on), agent.voiceLevel(levels),
-- agent.setPrompt(text), agent.voicePending(heard), agent.rehearPending(item, heard), agent.dropPending(item),
-- agent.waitingTitle(title), agent.warm(); for bragi/sidepanel.lua: agent.current(),
-- agent.relayout() and "bragi.tabShown" (tab); agent.loaded() (what the last session loaded, for
-- Settings, Claude); for bragi/quick.lua: agent.quickAnswered(item, question, answer),
-- agent.quickHandoff(item, line), agent.quickNotes(); for bragi/rewind.lua:
-- agent.fillHistory(tab, history)
--
-- During a turn asked for by voice, "bragi.activity" is published for each
-- step the model takes, for bragi/voice.lua's narrator: { kind = "thinking"
-- or "text", text } (a streamed piece) or { kind = "tool", name, summary,
-- description }. A tool is published twice: as it starts ({ kind = "tool",
-- name, starting = true }, the moment its block opens) and again with its
-- input once that has streamed. The same steps of every conversation's
-- turn, the voice turn's too, are published as "bragi.step" ({ tab, step }),
-- for Bragi's spoken updates (bragi/updates.lua).
--
-- Each permission card is published as "bragi.permission" ({ item, shown:
-- in the conversation on screen }) for bragi/voice.lua to ask aloud, and
-- its answer as "bragi.permissionAnswered" ({ item, by = "click", "voice",
-- "typed", "bragi" (a master's bragi_send), or "cancelled" }). A card
-- answered by voice says so ("Allowed by voice: ..."). A typed message
-- while the agent works goes to voice.whileWorking: only a clear stop or
-- change of direction interrupts. Every typed message
-- is published as "bragi.submitted" (its text) as it's sent, so voice can
-- learn from a heard message corrected before sending. Every message you
-- send, typed or spoken, is published as "bragi.sent" ({ tab, body, voice })
-- once it's gone: bragi/voice.lua tells that conversation's work aloud.
--
-- Parallel sessions: each conversation is a tab with its own
-- items and session. Starting a new one or picking another in the list
-- leaves a session that's mid-turn (or waiting on a permission) running in
-- the background; an idle one is closed (the next message resumes it).
-- Live sessions head the sessions list, marked: running, needs you (a
-- permission), finished, or failed, until you look at them. When a session
-- in the background finishes or asks for a permission, or any does while
-- the window isn't in front, the app asks for you (window.notify: the
-- taskbar flashes and a desktop notification shows).
--
-- Launch parity: sessions only ever append to Claude Code's
-- system prompt and never run it bare, so they load what an interactive
-- session does (CLAUDE.md files, auto memory, settings, hooks, skills,
-- plugins, MCP servers, connectors). Synced skills are switched on
-- (CLAUDE_CODE_SYNC_SKILLS, in the C++ session). When Claude Code says it
-- runs on an API key rather than the claude.ai sign-in, the transcript
-- says so once: connectors, synced skills, and plugins need the sign-in.

local C = require("core.palette")
local app = require("core.app")
local commands = require("ui.commands")
local geometry = require("ui.geometry")
local images = require("bragi.images")
local links = require("bragi.links")
local markdown = require("bragi.markdown")
local menu = require("ui.menu")
local plan = require("bragi.plan")
local placeholder = require("ui.placeholder")
local settings = require("core.settings")
local shell = require("bragi.shell")
local text = require("core.text")
local textselect = require("bragi.textselect")

local agent = { name = "bragi.agent" }

local SIDEBAR = 264       -- the conversation list's width, until it's dragged
local SIDEBAR_MIN = 200
local SIDEBAR_MAX = 520
local SIDEBAR_ROOM = 600  -- what the list leaves the rest of the view, at least
local COLUMN = 780        -- the conversation's widest, gutters included
local GUTTER = 24
local HEADER = 56
local COMPOSER = 134      -- prompt box height
local COMPOSER_GAP = 24   -- from the bottom edge
local ATTACH_ROW = 96     -- the prompt box's row of pictures, when it has some
local ATTACH_W, ATTACH_H = 140, 80  -- one picture there, at most
local PICTURE_W, PICTURE_H = 240, 170 -- one in the conversation, at most
local MESSAGE_GAP = 22
local STEP_GAP = 6        -- between consecutive steps
local BUBBLE_PAD = 14     -- inside your messages
local STEP_HEIGHT = 34
local REPLY_ROW_GAP = 4   -- between a reply and its Copy button
local LEVEL_BARS = 9
local MAX_DETAIL_LINES = 30
-- A saved session opens with its latest items drawn; "Show earlier" adds
-- more above (opening a long conversation hitched while
-- every message of it was drawn).
local HISTORY_ENTRIES = 300 -- transcript entries read for a saved session
local SHOWN_AT_FIRST = 40   -- items drawn when it opens
local SHOWN_MORE = 60       -- items each "Show earlier" adds
local END_SLACK = 2         -- px short of the end that still counts as at it
local JUMP = "AgentJumpLatest"
local JUMP_W, JUMP_H = 140, 32
local JUMP_LABEL = "Jump to latest"

local created = 0         -- item widgets made so far (names stay unique)
local pages = 0           -- conversation pages made so far (pageOf)
local waitingCount = 0    -- waiting rows made so far
local sidebarOpen = true
local sidebarSplit = nil  -- its seam (ui/splitter.lua), made in init
local panelShown = 0      -- the session panel's width beside the conversation
local layoutPending = false
local following = true    -- the shown conversation keeps to its end ("Following the end")
local ownScroll = false   -- a scroll this file makes, not yours
local fresh = false       -- something new at the shown tab's end since the last layout

-- A tab: one conversation. items: the transcript, in order (see the
-- header); byToolId: tool call id -> its step item; session: name (the
-- binding's key), id (Claude Code's session id), running, turn (a turn is
-- running), resume (the id the next start resumes), startOnce (agentStart
-- options for the next start only: bragi/rewind.lua's resumeAt and
-- forkSession), task (the issue it works on, agent.workOn, tracked on the
-- server); title; unread: "done" or
-- "failed" when it ended while you weren't looking.
-- cwd: its working folder (nil until it starts: then the open
-- repository's); updated: when its last message was (sent, or an answer
-- came), for the list's order: a saved one opened keeps its transcript's
-- (opening one must not move it).
local function newTab(opts)
    opts = opts or {}
    return {
        items = {},
        byToolId = {},
        -- session.cwd mirrors cwd (bragi/sidepanel.lua reads it).
        session = { name = nil, id = nil, running = false, turn = false, resume = nil, task = nil,
            cwd = opts.cwd },
        stderrTail = {},
        title = opts.title or "New session",
        unread = nil,
        cwd = opts.cwd,
        master = opts.master,
        updated = os.time(),
        attachments = {}, -- image files the next message takes (pasted or dropped)
    }
end

local tabs = {}           -- live tabs, oldest first
local cur = newTab()      -- the tab shown
tabs[1] = cur
-- The tab the handlers work on (cur, or one in the background while its
-- event is handled) and its parts.
local ctx = cur
local items, byToolId, session, stderrTail = cur.items, cur.byToolId, cur.session, cur.stderrTail

local function use(tab)
    ctx = tab
    items, byToolId, session, stderrTail = tab.items, tab.byToolId, tab.session, tab.stderrTail
end

local sessionCount = 0
local rows = {}           -- the sessions list's rows (bragi/sessionlist.lua)
local paintSessions        -- paints them (below)
local listedFor = nil     -- the open repository when the list was read
local voiceOn = false     -- listening (bragi/voice.lua)
local paintMute            -- the speaker button beside the mic (below)
local loaded = nil        -- the last session's init: what it loaded
local warnedKey = false   -- the API key note was shown

--- Choices shared with bragi/settings.lua.
agent.MODELS = {
    { id = "fable", label = "Fable 5.1" },
    { id = "opus", label = "Opus 5.5" },
    { id = "sonnet", label = "Sonnet 5.5" },
    { id = "haiku", label = "Haiku 5.5" },
}
agent.EFFORTS = {
    { id = "", label = "Default" },
    { id = "low", label = "Low" },
    { id = "medium", label = "Medium" },
    { id = "high", label = "High" },
    { id = "xhigh", label = "Extra high" },
    { id = "max", label = "Max" },
}
agent.STYLES = {
    { id = "default", label = "Default" },
    { id = "Explanatory", label = "Explanatory" },
    { id = "Learning", label = "Learning" },
}
agent.MODES = {
    { id = "default", label = "Ask before edits" },
    { id = "acceptEdits", label = "Edit automatically" },
    { id = "plan", label = "Plan first" },
    { id = "auto", label = "Auto" },
    { id = "bypassPermissions", label = "Skip all permission checks", confirm = {
        title = "Skip all permission checks?",
        body = "Claude Code runs every tool, edit, and command without asking, until you change this.",
        button = "Skip checks" } },
}
-- Permission modes as Claude Code names them (`claude --help`). "manual" is
-- "default" under its new name; dontAsk refuses anything not allowed in
-- advance, which only suits unattended runs, so the menu leaves it out.
local MODE_HIDDEN = { manual = true, dontAsk = true }

-- Tool icons (imagesets/BragiIcons.xml).
local TOOL_ICON = {
    Bash = "Terminal", BashOutput = "Terminal", KillShell = "Terminal", PowerShell = "Terminal",
    Read = "Read", NotebookRead = "Read",
    Edit = "Pencil", MultiEdit = "Pencil", Write = "Pencil", NotebookEdit = "Pencil",
    Glob = "Search", Grep = "Search", WebSearch = "Search", WebFetch = "Search",
    Task = "Agent", Agent = "Agent",
}

--- The label of the chosen entry in a choice list.
-- @param list     agent.MODELS or agent.MODES
-- @param key      settings key
-- @param default  id used when nothing is saved
-- @return label
function agent.choiceLabel(list, key, default)
    local id = settings.get(key, default)
    for _, entry in ipairs(list) do
        if entry.id == id then
            return entry.label
        end
    end

    return list[1].label
end

--- A dropdown of choices under a button; picking one saves it.
-- @param button  widget to drop from
-- @param list    agent.MODELS or agent.MODES
-- @param key     settings key
-- @param default id used when nothing is saved
function agent.pickChoice(button, list, key, default)
    local chosen = settings.get(key, default)
    local entries = {}
    for _, entry in ipairs(list) do
        entries[#entries + 1] = {
            label = entry.label,
            checked = entry.id == chosen,
            action = function()
                local function pick()
                    settings.set(key, entry.id)
                    app.publish("bragi.choices")
                end
                if entry.confirm and entry.id ~= chosen then
                    require("ui.dialog").confirm(entry.confirm.title, entry.confirm.body, entry.confirm.button,
                        pick, true)
                else
                    pick()
                end
            end,
        }
    end

    local x, y, _, h = gitgud.getRect(button)
    if x then
        menu.popup(entries, x, y + h + 4)
    end
end

--- Read the permission modes Claude Code offers from `claude --help`, and
-- keep agent.MODES to those (plus any new one, named as the CLI names it).
-- The list stays as it is when the help can't be read.
function agent.loadModes()
    local out = {}
    local name = "BragiAgentModes"
    gitgud.on(name .. ".output", function(line)
        out[#out + 1] = tostring(line or "")
    end)
    gitgud.on(name .. ".done", function()
        local help = table.concat(out, " ")
        local list = help:match("%-%-permission%-mode.-%(choices:([^%)]*)%)")
        if not list then
            return
        end
        local offered = {}
        for id in list:gmatch('"([^"]+)"') do
            offered[id] = true
        end
        offered.default = offered.default or offered.manual
        local modes, known = {}, {}
        for _, entry in ipairs(agent.MODES) do
            known[entry.id] = true
            if offered[entry.id] then
                modes[#modes + 1] = entry
            end
        end
        for id in list:gmatch('"([^"]+)"') do
            if not known[id] and not MODE_HIDDEN[id] then
                modes[#modes + 1] = { id = id, label = id }
            end
        end
        if #modes > 0 then
            agent.MODES = modes
            app.publish("bragi.choices")
        end
    end)
    gitgud.startProgram(name, { require("bragi.claude").program(), "--help" })
end

--- Show the saved model and mode on the prompt box's buttons, and hand
-- them to a running session.
local function showChoices()
    gitgud.setText("AgentModelButton", agent.choiceLabel(agent.MODELS, "bragi.model", "opus"))
    gitgud.setText("AgentModeButton", agent.choiceLabel(agent.MODES, "bragi.mode", "default"))
    if session.running then
        gitgud.agentSetModel(session.name, settings.get("bragi.model", "opus"))
        gitgud.agentSetMode(session.name, settings.get("bragi.mode", "default"))
        -- The thinking level too, while it runs (Claude Code's
        -- apply_flag_settings; null is its own default).
        local effort = settings.get("bragi.effort", "")
        if session.name and (session.effort or "") ~= effort then
            local level = effort ~= "" and gitgud.jsonEncode(effort) or "null"
            if gitgud.agentControl(session.name, "apply_flag_settings",
                    '{"settings":{"effortLevel":' .. level .. '}}') then
                session.effort = effort
            end
        end
    end
end

--- AgentMain's width and height.
local function mainSize()
    local _, _, w, h = gitgud.getRect("AgentMain")

    return w or 900, h or 600
end

--- The conversation column's inner width for the current window.
local function columnWidth()
    local w = mainSize()

    return math.max(280, math.min(COLUMN, w) - 2 * GUTTER)
end

--- Keep one primary action filled: Stop while a turn runs, Send when
-- there's text, else the mic.
local function paintPrimary()
    -- Pictures waiting count as something to send.
    local hasText = text.trim(gitgud.getText("AgentPromptEdit") or "") ~= "" or #(cur.attachments or {}) > 0
    local stop = session.turn and not hasText
    local sendOn = hasText or stop
    gitgud.setProperty("AgentSendButton", "NormalFillColour", sendOn and C.accent or C.sel)
    gitgud.setProperty("AgentSendButton", "HoverFillColour", sendOn and C.accentHover or C.hover)
    gitgud.setProperty("AgentSendButton", "BorderColour", sendOn and C.transparent or C.border)
    gitgud.setProperty("AgentSendButton", "TooltipText", stop and "Stop  (Esc)" or "Send  (Enter)")
    gitgud.setProperty("AgentSendIcon", "IconImage", stop and "Bragi-Icons/Stop" or "Bragi-Icons/Send")
    gitgud.setProperty("AgentSendIcon", "IconColour", sendOn and C.onAccent or C.text)
    local micLit = voiceOn or not sendOn
    gitgud.setProperty("AgentMicButton", "NormalFillColour", voiceOn and C.err or (micLit and C.accent or C.sel))
    gitgud.setProperty("AgentMicButton", "HoverFillColour", voiceOn and C.err or (micLit and C.accentHover or C.hover))
    gitgud.setProperty("AgentMicButton", "TooltipText", voiceOn and "Stop listening"
        or (require("bragi.voice").available() and "Start listening" or "Voice is off: click to see why"))
    gitgud.setProperty("AgentMicIcon", "IconColour", micLit and C.onAccent or C.text)
end

-- ===================================================================
-- Items
-- ===================================================================

local function newName()
    created = created + 1
    return "AgentMessage" .. created
end

--- A tool call's one-line summary from its input.
local function toolSummary(name, input)
    if type(input) ~= "table" then
        return ""
    end
    local function short(path)
        path = tostring(path or "")
        local dir, base = path:match("^(.*)[/\\]([^/\\]+)$")
        if base and #path > 60 then
            return base .. "  " .. text.basename(dir or "")
        end
        return path
    end
    if plan.isTool(name) then
        return plan.summary(ctx.plan, name, input)
    elseif (tostring(name):match("bragi_read_conversation$") or tostring(name):match("bragi_send$"))
        and input.id then
        -- A conversation by its title, not its id (the narrator says which
        -- one it's on, and the list shows it).
        local id = tostring(input.id)
        local tab = agent.tabFor(id)
        local saved = not tab and agent.savedSession(id) or nil
        local title = (tab and tab.title) or (saved and saved.title) or ""
        if title ~= "" then
            return title
        end
        return id
    elseif input.command then
        return input.command:match("^[^\n]*")
    elseif tostring(name):match("bragi_settings_set$") and input.setting then
        -- The app's own settings (bragi/settingstool.lua): "speechSpeed to 1.38".
        return tostring(input.setting) .. " to " .. tostring(input.value)
    elseif input.file_path or input.notebook_path then
        return short(input.file_path or input.notebook_path)
    elseif input.pattern then
        return input.pattern .. (input.path and ("  in " .. short(input.path)) or "")
    elseif input.url then
        return input.url
    elseif input.query then
        return input.query
    elseif input.description then
        return input.description
    elseif name == "AskUserQuestion" and type(input.questions) == "table" and type(input.questions[1]) == "table" then
        return tostring(input.questions[1].question or "")
    end
    for _, v in pairs(input) do
        if type(v) == "string" then
            return v:match("^[^\n]*")
        end
    end
    return ""
end

--- Draw an item's contents into its container at `width`. Returns its
-- height. Called again whenever the item changes or the width does.
local draw = {}

-- Where the conversation's relative paths start (bragi/links.lua).
local function linkFolder()
    return cur.cwd or require("core.repo").state().path
end

function draw.user(item, width)
    local most = math.floor(width * 0.8)
    local textName = item.name .. "Text"
    -- The bubble; its actions (bragi/rewind.lua) go under it.
    local bubble = item.name .. "Bubble"
    if not gitgud.getRect(bubble) then
        gitgud.createWindow("Bragi/Box12", bubble, item.name)
        gitgud.setProperty(bubble, "FillColour", C.sel)
        gitgud.setCursor(bubble, "ibeam")
    end
    if not item.made then
        item.made = true
        gitgud.createWindow("Gitgud/StaticText", textName, bubble)
        gitgud.setProperty(textName, "PanelColour", C.transparent)
        gitgud.setProperty(textName, "HorzFormatting", "WordWrapLeftAligned")
        gitgud.setProperty(textName, "VertFormatting", "TopAligned")
        gitgud.setProperty(textName, "Font", "Bragi-15")
        gitgud.setProperty(textName, "TextColours", C.text)
        gitgud.setProperty(textName, "CursorPassThroughEnabled", "true")
        local markup
        markup, item.linkSpans = links.markup(item.text, { folder = linkFolder() })
        gitgud.setText(textName, markup)
    end
    -- As wide as its text (and its pictures), up to 80% of the column.
    local pictures = item.images or {}
    local hasText = item.text ~= ""
    gitgud.setProperty(textName, "Area", geometry.rect(BUBBLE_PAD, 12, most - 2 * BUBBLE_PAD, 40))
    local textWidth = hasText and (tonumber(gitgud.getProperty(textName, "HorzExtent") or "") or most) or 0
    local picturesH, picturesW = 0, 0
    if #pictures > 0 then
        picturesH, picturesW = images.place(bubble, item.name .. "Pic", pictures, BUBBLE_PAD, 12,
            most - 2 * BUBBLE_PAD, { maxWidth = PICTURE_W, maxHeight = PICTURE_H })
    end
    local bubbleW = math.min(most, math.ceil(math.max(textWidth, picturesW) + 2 * BUBBLE_PAD + 4))
    local h = 0
    if hasText then
        gitgud.setProperty(textName, "Area", geometry.rect(BUBBLE_PAD, 12, bubbleW - 2 * BUBBLE_PAD, 40))
        local extent = tonumber(gitgud.getProperty(textName, "VertExtent") or "")
        h = math.ceil((extent and extent > 0) and extent or 22) + 4
    end
    -- Pictures first, as they went: the text under them.
    local textY = 12 + (picturesH > 0 and picturesH + (hasText and 8 or 0) or 0)
    gitgud.setProperty(textName, "Area", geometry.rect(BUBBLE_PAD, textY, bubbleW - 2 * BUBBLE_PAD, h))
    links.attach(textName, item.linkSpans)
    local bubbleH = textY - 12 + h + 24
    local rowW, rowH = require("bragi.rewind").drawActions(item, bubbleW, bubbleH)
    item.width = math.max(bubbleW, rowW)
    gitgud.setProperty(bubble, "Area", geometry.rect(item.width - bubbleW, 0, bubbleW, bubbleH))
    return bubbleH + rowH
end

function draw.note(item, width)
    local textName = item.name .. "Text"
    if not item.made then
        item.made = true
        gitgud.createWindow("Gitgud/StaticText", textName, item.name)
        gitgud.setProperty(textName, "PanelColour", C.transparent)
        gitgud.setProperty(textName, "HorzFormatting", "WordWrapLeftAligned")
        gitgud.setProperty(textName, "VertFormatting", "TopAligned")
        gitgud.setProperty(textName, "Font", "Bragi-14")
        gitgud.setProperty(textName, "TextColours", item.error and C.err or C.sub)
        gitgud.setProperty(textName, "CursorPassThroughEnabled", "true")
        gitgud.setText(textName, text.escape(item.text))
    end
    -- A button on the right ("Undo"), while it has one.
    local button = item.name .. "Action"
    local buttonWidth = 0
    if item.action and not item.actionMade then
        item.actionMade = true
        gitgud.createWindow("Bragi/Button8", button, item.name)
        gitgud.setProperty(button, "Font", "Bragi-13-Bold")
        gitgud.setProperty(button, "NormalFillColour", C.transparent)
        gitgud.setProperty(button, "BorderColour", C.border)
        gitgud.setText(button, text.escape(item.action.label))
        gitgud.on(button .. ".clicked", function()
            local action = item.action
            if action then
                action.run(item)
            end
        end)
    elseif not item.action and item.actionMade then
        item.actionMade = false
        gitgud.destroyWindow(button)
    end
    if item.action then
        buttonWidth = 76
    end
    local textWidth = width - (buttonWidth > 0 and buttonWidth + 12 or 0)
    gitgud.setProperty(textName, "Area", geometry.rect(0, 0, textWidth, 40))
    local extent = tonumber(gitgud.getProperty(textName, "VertExtent") or "")
    local h = math.ceil((extent and extent > 0) and extent or 20) + 4
    local ty = 0
    if buttonWidth > 0 then
        ty = math.max(0, math.floor((32 - h) / 2)) -- level with the button
        gitgud.setProperty(button, "Area", geometry.rect(width - buttonWidth, 0, buttonWidth, 32))
    end
    gitgud.setProperty(textName, "Area", geometry.rect(0, ty, textWidth, h))
    return buttonWidth > 0 and math.max(h + ty, 32) or h
end

--- A reply's Copy button under it, shown while the mouse is over the reply
-- (its room always kept, as under your messages). Returns the height it adds.
local function replyActions(item, top)
    local row = item.name .. "Actions"
    if not gitgud.getRect(row) then
        gitgud.createWindow("DefaultWindow", row, item.name)
        textselect.copyButton(row .. "Copy", row, 0, 0, function()
            return item.text
        end, "Copy", "the reply")
        gitgud.setProperty(item.name, "ReportHover", "true")
        gitgud.on(item.name .. ".hovered", function(value)
            item.hovered = value == "1"
            if gitgud.getRect(row) then
                gitgud.setVisible(row, item.hovered)
            end
        end)
    end
    gitgud.setVisible(row, item.hovered == true)
    gitgud.setProperty(row, "Area", geometry.rect(0, top + REPLY_ROW_GAP, textselect.BUTTON, textselect.BUTTON))
    return REPLY_ROW_GAP + textselect.BUTTON
end

--- A reply's text windows, in order (tests look for its links there).
function agent.replyTexts(item)
    return markdown.textWindows(item and item.md)
end

function draw.assistant(item, width)
    -- Its blocks keep their windows while they're unchanged
    -- (markdown.update): a reply streaming in draws only its growing end,
    -- not all of it at every piece (long replies froze the
    -- app as they streamed).
    if not item.inner or item.mdInner ~= item.inner then
        if item.inner then
            gitgud.destroyWindow(item.inner)
        end
        item.gen = (item.gen or 0) + 1
        item.inner = item.name .. "G" .. item.gen
        gitgud.createWindow("DefaultWindow", item.inner, item.name)
        gitgud.setCursor(item.inner, "ibeam")
        item.mdInner, item.md = item.inner, {}
    end
    local blocks = markdown.parse(item.text)
    item.texts = {}
    local h = markdown.update(item.md, blocks, item.inner, { width = width, links = true, folder = linkFolder(),
        texts = item.texts, copyCode = true })
    h = math.max(h - 12, 20) -- the last block's gap
    -- The pictures and the tag below it, drawn anew each time in a window
    -- of their own.
    if item.extra then
        gitgud.destroyWindow(item.extra)
        item.extra = nil
    end
    -- The image files it links to, ![what](path): shown, not just named.
    local linked = images.linked(item.text)
    if #linked > 0 or item.tag then
        item.extraGen = (item.extraGen or 0) + 1
        item.extra = item.inner .. "X" .. item.extraGen
        gitgud.createWindow("DefaultWindow", item.extra, item.inner)
        local eh = 0
        if #linked > 0 then
            local ph = images.place(item.extra, item.extra .. "Pic", linked, 0, 8, width,
                { maxWidth = PICTURE_W, maxHeight = PICTURE_H })
            eh = 8 + ph
        end
        if item.tag then
            -- Who answered, when it wasn't the agent ("Answered by Haiku").
            local tag = item.extra .. "Tag"
            gitgud.createWindow("Gitgud/Label", tag, item.extra)
            gitgud.setProperty(tag, "Area", geometry.rect(0, eh + 6, width, 18))
            gitgud.setProperty(tag, "Font", "Bragi-12")
            gitgud.setProperty(tag, "NormalTextColour", C.sub)
            gitgud.setProperty(tag, "CursorPassThroughEnabled", "true")
            gitgud.setText(tag, text.escape(item.tag))
            eh = eh + 24
        end
        gitgud.setProperty(item.extra, "Area", geometry.rect(0, h, width, eh))
        h = h + eh
    end
    gitgud.setProperty(item.inner, "Area", geometry.rect(0, 0, width, h))
    return h + replyActions(item, h)
end

-- What a step did, by tool, as the design words it ("Read src/main.cpp"),
-- and while it runs ("Reading ..."). Other tools show their own name.
local TOOL_VERB = {
    Bash = { "Ran", "Running" }, PowerShell = { "Ran", "Running" },
    BashOutput = { "Read output", "Reading output" }, KillShell = { "Stopped", "Stopping" },
    Read = { "Read", "Reading" }, NotebookRead = { "Read", "Reading" },
    Edit = { "Edited", "Editing" }, MultiEdit = { "Edited", "Editing" }, NotebookEdit = { "Edited", "Editing" },
    Write = { "Wrote", "Writing" },
    Glob = { "Found", "Finding" }, Grep = { "Searched", "Searching" },
    WebSearch = { "Searched the web", "Searching the web" }, WebFetch = { "Fetched", "Fetching" },
    Task = { "Asked an agent", "Asking an agent" }, Agent = { "Asked an agent", "Asking an agent" },
    AskUserQuestion = { "Asked you", "Asking you" },
}

for name, words in pairs(plan.VERBS) do
    TOOL_VERB[name] = words
end

--- More tools' words (bragi/master.lua's): name -> { done, running }.
function agent.addToolVerbs(verbs)
    for name, words in pairs(verbs) do
        TOOL_VERB[name] = words
    end
end

--- A step's title: what it did (or is doing), else the tool's name.
local function stepVerb(item)
    local verb = item.kind == "step" and TOOL_VERB[item.title or ""]
    if not verb then
        return item.title or ""
    end
    local running = item.result == nil and not item.error and not item.stopped
    return running and verb[2] or verb[1]
end

--- The status words and colour of a step.
local function stepStatus(item)
    if item.kind == "thinking" or item.kind == "waiting" then
        return item.done and "" or "...", C.sub
    end
    if item.error then
        return "Failed", C.err
    elseif item.result ~= nil then
        return "Done", C.sub
    elseif item.stopped then
        return "Stopped", C.sub
    end
    return "Running", C.accentText
end

local function detailText(item)
    if item.kind == "waiting" then
        return "Waiting for the first words of the answer."
    elseif item.kind == "thinking" then
        return item.text or ""
    end
    local lines = {}
    if item.inputText and item.inputText ~= "" then
        lines[#lines + 1] = item.inputText
    end
    if item.result and item.result ~= "" then
        lines[#lines + 1] = "\u{2192} " .. item.result
    end
    local all = table.concat(lines, "\n")
    local out, count = {}, 0
    for line in (all .. "\n"):gmatch("(.-)\n") do
        count = count + 1
        if count > MAX_DETAIL_LINES then
            out[#out + 1] = "..."
            break
        end
        out[#out + 1] = line
    end
    return table.concat(out, "\n")
end

function draw.step(item, width)
    local indent = item.parent and item.parent ~= "" and 24 or 0
    if item.inner then
        gitgud.destroyWindow(item.inner)
    end
    item.gen = (item.gen or 0) + 1
    item.inner = item.name .. "G" .. item.gen
    local root = item.inner
    gitgud.createWindow("Bragi/Button8", root, item.name)
    gitgud.setProperty(root, "Text", "")
    gitgud.setProperty(root, "NormalFillColour", item.open and C.panel or C.transparent)
    gitgud.setProperty(root, "HoverFillColour", C.hover)
    gitgud.setProperty(root, "PushedFillColour", C.sel)
    gitgud.setProperty(root, "BorderColour", item.open and C.border or C.transparent)
    gitgud.setProperty(root, "TooltipText", item.open and "Hide the details" or "Show the details")

    local icon = root .. "Icon"
    gitgud.createWindow("Gitgud/Icon", icon, root)
    gitgud.setProperty(icon, "Area", geometry.rect(10, 10, 14, 14))
    gitgud.setProperty(icon, "IconImage", "Bragi-Icons/" .. (item.icon or "Spark"))
    gitgud.setProperty(icon, "IconColour", C.sub)
    gitgud.setProperty(icon, "GlowColour", "00000000")
    gitgud.setProperty(icon, "CursorPassThroughEnabled", "true")

    local words, colour = stepStatus(item)
    local title = root .. "Title"
    -- The design's quiet step: what was done in the secondary colour, what
    -- it was done to in mono.
    local markup = "[font='Bragi-13'][colour='" .. C.sub .. "']" .. text.escape(stepVerb(item))
    if item.summary and item.summary ~= "" then
        markup = markup .. "  [font='Bragi-Mono-13'][colour='" .. C.text .. "']" .. text.escape(item.summary)
    end
    gitgud.createWindow("Gitgud/Label", title, root)
    gitgud.setProperty(title, "Area", geometry.rect(32, 0, width - indent - 32 - 90, STEP_HEIGHT))
    gitgud.setProperty(title, "CursorPassThroughEnabled", "true")
    gitgud.setProperty(title, "ClippedByParent", "true")
    gitgud.setText(title, markup)
    local state = root .. "State"
    gitgud.createWindow("Gitgud/Label", state, root)
    gitgud.setProperty(state, "Area", geometry.rect(width - indent - 90, 0, 80, STEP_HEIGHT))
    gitgud.setProperty(state, "Font", "Bragi-12-Bold")
    gitgud.setProperty(state, "HorzFormatting", "RightAligned")
    gitgud.setProperty(state, "NormalTextColour", colour)
    gitgud.setProperty(state, "CursorPassThroughEnabled", "true")
    gitgud.setText(state, words)

    local h = STEP_HEIGHT
    if item.open then
        local detail = root .. "Detail"
        gitgud.createWindow("Gitgud/StaticText", detail, root)
        gitgud.setProperty(detail, "PanelColour", C.transparent)
        gitgud.setProperty(detail, "HorzFormatting", "WordWrapLeftAligned")
        gitgud.setProperty(detail, "VertFormatting", "TopAligned")
        gitgud.setProperty(detail, "Font", item.kind == "thinking" and "Bragi-14" or "Bragi-Mono-13")
        gitgud.setProperty(detail, "TextColours", C.sub)
        gitgud.setProperty(detail, "CursorPassThroughEnabled", "true")
        gitgud.setProperty(detail, "Area", geometry.rect(32, STEP_HEIGHT, width - indent - 44, 40))
        local markup, spans = links.markup(detailText(item), { folder = linkFolder(), colour = C.sub })
        gitgud.setText(detail, markup)
        local extent = tonumber(gitgud.getProperty(detail, "VertExtent") or "") or 18
        local dh = math.ceil(extent) + 4
        gitgud.setProperty(detail, "Area", geometry.rect(32, STEP_HEIGHT, width - indent - 44, dh))
        links.attach(detail, spans)
        h = h + dh + 10
    end
    gitgud.setProperty(root, "Area", geometry.rect(indent, 0, width - indent, h))
    gitgud.on(root .. ".clicked", function()
        if textselect.touches(item) then
            return -- the press selected some of its details
        end
        item.open = not item.open
        item.dirty = true
        agent.layoutSoon()
    end)
    -- The pictures in its result (a screenshot, the Read of an image) show
    -- under it, open or not.
    if item.pics then
        gitgud.destroyWindow(item.pics)
        item.pics = nil
    end
    if item.images and #item.images > 0 then
        item.pics = item.name .. "P" .. item.gen
        gitgud.createWindow("DefaultWindow", item.pics, item.name)
        local ph = images.place(item.pics, item.pics .. "Pic", item.images, 0, 0, width - indent - 32,
            { maxWidth = PICTURE_W, maxHeight = PICTURE_H })
        gitgud.setProperty(item.pics, "Area", geometry.rect(indent + 32, h + 6, width - indent - 32, ph))
        h = h + 6 + ph
    end
    return h
end
draw.waiting = draw.step

--- Who asks on a card, when it isn't the conversation's own agent: "From
-- the helper "name"", "From a helper"; nil for the agent's own.
function agent.askedBy(item)
    if item.helper == nil then
        return nil
    end
    return item.helper ~= "" and ("From the helper \u{201C}" .. item.helper .. "\u{201D}") or "From a helper"
end

--- Whether a thinking item has words to show. Claude Code mostly streams
-- its thinking with none: only a signature, redacted, or a short think at a
-- low level.
local function hasThought(item)
    return text.trim(item.text or "") ~= ""
end

--- A thinking row, once it has words (empty "Thinking"
-- boxes above the steps and the news). Without words it isn't drawn at
-- all, going or done: it takes no room and no gap (layout), and while it
-- goes the waiting row stays (onAgentEvent). Words that come make it a row
-- to open, as a step is.
function draw.thinking(item, width)
    if not hasThought(item) then
        if item.inner then
            gitgud.destroyWindow(item.inner)
            item.inner = nil
        end
        item.open = false
        return 0
    end
    return draw.step(item, width)
end

-- Tools that ask to change a file: their card can show the change first.
local PROPOSES_CHANGE = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

function draw.permission(item, width)
    if item.inner then
        gitgud.destroyWindow(item.inner)
    end
    item.gen = (item.gen or 0) + 1
    item.inner = item.name .. "G" .. item.gen
    local root = item.inner
    gitgud.createWindow("Bragi/Box12", root, item.name)
    gitgud.setProperty(root, "FillColour", C.panel)
    gitgud.setProperty(root, "BorderColour", item.answer and C.border or C.accent)

    -- The design: what's asked on the left, Deny and Allow on the right,
    -- and before them View diff for a change to a file.
    local PAD, BUTTON, GAP, VIEW = 16, 84, 10, 96
    local viewDiff = PROPOSES_CHANGE[item.tool] and item.input ~= nil
    local column = width - PAD * 2 - (BUTTON * 2 + GAP) - (viewDiff and VIEW + GAP or 0) - 14
    local title = root .. "Title"
    gitgud.createWindow("Gitgud/Label", title, root)
    gitgud.setProperty(title, "Area", geometry.rect(PAD, PAD, column, 20))
    gitgud.setProperty(title, "Font", "Bragi-14-Bold")
    gitgud.setProperty(title, "NormalTextColour", C.text)
    gitgud.setProperty(title, "CursorPassThroughEnabled", "true")
    gitgud.setText(title, text.escape("Allow " .. item.tool .. "?"))

    -- A helper's request says which helper asks, and Claude Code's reason
    -- when it gave one (a folder outside the project, a file written...).
    local top = 40
    local line = agent.askedBy(item) or ""
    if (item.reason or "") ~= "" then
        line = line ~= "" and (line .. ". " .. item.reason) or item.reason
    end
    if line ~= "" then
        local who = root .. "Who"
        gitgud.createWindow("Gitgud/StaticText", who, root)
        gitgud.setProperty(who, "PanelColour", C.transparent)
        gitgud.setProperty(who, "HorzFormatting", "WordWrapLeftAligned")
        gitgud.setProperty(who, "VertFormatting", "TopAligned")
        gitgud.setProperty(who, "Font", "Bragi-13")
        gitgud.setProperty(who, "TextColours", C.sub)
        gitgud.setProperty(who, "CursorPassThroughEnabled", "true")
        gitgud.setProperty(who, "Area", geometry.rect(PAD, top, column, 40))
        gitgud.setText(who, text.escape(line))
        local wh = math.min(math.ceil(tonumber(gitgud.getProperty(who, "VertExtent") or "") or 18) + 4, 60)
        gitgud.setProperty(who, "Area", geometry.rect(PAD, top, column, wh))
        top = top + wh + 4
    end

    local body = root .. "Body"
    gitgud.createWindow("Gitgud/StaticText", body, root)
    gitgud.setProperty(body, "PanelColour", C.transparent)
    gitgud.setProperty(body, "HorzFormatting", "WordWrapLeftAligned")
    gitgud.setProperty(body, "VertFormatting", "TopAligned")
    gitgud.setProperty(body, "Font", "Bragi-Mono-13")
    gitgud.setProperty(body, "TextColours", C.sub)
    gitgud.setProperty(body, "CursorPassThroughEnabled", "true")
    gitgud.setProperty(body, "Area", geometry.rect(PAD, top, column, 40))
    gitgud.setText(body, text.escape(item.summary ~= "" and item.summary or "No details"))
    local extent = tonumber(gitgud.getProperty(body, "VertExtent") or "") or 18
    local bh = math.min(math.ceil(extent) + 4, 200)
    gitgud.setProperty(body, "Area", geometry.rect(PAD, top, column, bh))

    local y = math.max(top + bh + 12, PAD + 40 + PAD)
    if item.answerNote then
        -- How it was answered ("Allowed by voice: ..."), under what was asked.
        local how = root .. "How"
        gitgud.createWindow("Gitgud/Label", how, root)
        gitgud.setProperty(how, "Area", geometry.rect(PAD, y - 4, width - PAD * 2, 20))
        gitgud.setProperty(how, "Font", "Bragi-13")
        gitgud.setProperty(how, "NormalTextColour", C.sub)
        gitgud.setProperty(how, "CursorPassThroughEnabled", "true")
        gitgud.setText(how, text.escape(item.answerNote))
        y = y + 24
    end
    local right = width - PAD
    if item.answer then
        local done = root .. "Answer"
        gitgud.createWindow("Gitgud/Label", done, root)
        gitgud.setProperty(done, "Area", geometry.rect(right - (BUTTON * 2 + GAP), PAD, BUTTON * 2 + GAP, 40))
        gitgud.setProperty(done, "Font", "Bragi-13-Bold")
        gitgud.setProperty(done, "HorzFormatting", "RightAligned")
        gitgud.setProperty(done, "NormalTextColour", C.sub)
        gitgud.setText(done, text.escape(item.answer))
    else
        local allow = root .. "Allow"
        gitgud.createWindow("Bragi/Button8", allow, root)
        gitgud.setProperty(allow, "Area", geometry.rect(right - BUTTON, PAD, BUTTON, 40))
        gitgud.setProperty(allow, "Font", "Bragi-13-Bold")
        for _, s in ipairs({ "Normal", "Hover", "Pushed" }) do
            gitgud.setProperty(allow, s .. "TextColour", C.onAccent)
        end
        gitgud.setProperty(allow, "NormalFillColour", C.accent)
        gitgud.setProperty(allow, "HoverFillColour", C.accentHover)
        gitgud.setProperty(allow, "PushedFillColour", C.accentPressed)
        gitgud.setProperty(allow, "BorderColour", C.transparent)
        gitgud.setText(allow, "Allow")
        local deny = root .. "Deny"
        gitgud.createWindow("Bragi/Button8", deny, root)
        gitgud.setProperty(deny, "Area", geometry.rect(right - BUTTON * 2 - GAP, PAD, BUTTON, 40))
        gitgud.setProperty(deny, "Font", "Bragi-13-Bold")
        gitgud.setProperty(deny, "NormalFillColour", C.transparent)
        gitgud.setProperty(deny, "BorderColour", C.border)
        gitgud.setText(deny, "Deny")
        gitgud.on(allow .. ".clicked", function()
            agent.answer(item, true)
        end)
        gitgud.on(deny .. ".clicked", function()
            agent.answer(item, false)
        end)
    end
    if viewDiff then
        local view = root .. "View"
        gitgud.createWindow("Bragi/Button8", view, root)
        gitgud.setProperty(view, "Area", geometry.rect(right - BUTTON * 2 - GAP * 2 - VIEW, PAD, VIEW, 40))
        gitgud.setProperty(view, "Font", "Bragi-13-Bold")
        gitgud.setProperty(view, "NormalFillColour", C.transparent)
        gitgud.setProperty(view, "BorderColour", C.border)
        gitgud.setProperty(view, "TooltipText", "See the change before it's made")
        gitgud.setText(view, "View diff")
        gitgud.on(view .. ".clicked", function()
            require("bragi.proposed").show(item)
        end)
    end
    gitgud.setProperty(root, "Area", geometry.rect(0, 0, width, y))
    return y
end

-- ===================================================================
-- Claude's questions (AskUserQuestion)
-- ===================================================================
--
-- Claude's multiple-choice questions arrive as a permission request for
-- the tool AskUserQuestion: one to four questions, each with two to four
-- options (label, description), some multi-select. Each question is a card
-- of its own (kind "question"): the options as buttons (checkboxes and
-- Submit when several may be picked), a field for an answer in your own
-- words, and Skip. Once every card of a request is answered, the answers
-- go back together (gitgud.agentAnswer: question -> the label, labels
-- joined with ", ", or your words); all skipped, Claude hears you didn't
-- choose. A message typed while a card is open answers the first one. The
-- cards are published like permission cards ("bragi.permission",
-- "bragi.permissionAnswered") for bragi/voice.lua to ask aloud.

local QUESTION_TOOL = "AskUserQuestion"
local NOT_CHOSEN = "The user didn't choose."
local NOT_ANSWERED = "The user closed the question without choosing. Go on without the answer, or ask in plain text."
local OPTION_HEIGHT = 52
local OPTION_GAP = 8

--- Whether an item is a card waiting for you (a permission or a question).
local function waitsOnYou(item)
    return (item.kind == "permission" or item.kind == "question") and not item.answer
end

--- A question's answer as Claude gets it: the labels picked, then your
-- own words, joined with ", "; "" when nothing.
local function answerText(choice)
    local parts = {}
    for _, label in ipairs(choice and choice.labels or {}) do
        parts[#parts + 1] = label
    end
    local other = text.trim(choice and choice.other or "")
    if other ~= "" then
        parts[#parts + 1] = other
    end
    return table.concat(parts, ", ")
end

--- The first question card waiting in the shown conversation, or nil.
function agent.openQuestion()
    for _, item in ipairs(cur.items) do
        if item.kind == "question" and not item.answer then
            return item
        end
    end
    return nil
end

--- The first permission or question card waiting in the shown
-- conversation, or nil (bragi/voice.lua: what the user says goes to it first).
function agent.waitingCard()
    for _, item in ipairs(cur.items) do
        if (item.kind == "permission" or item.kind == "question") and not item.answer then
            return item
        end
    end
    return nil
end

--- What typed words pick on a question card: an option's number or label
-- (any case); on a multi-select one, several, split by commas or "and".
-- Anything else is your own answer.
function agent.typedChoice(item, body)
    local function find(word)
        word = text.trim(word):lower():gsub("[%.!]+$", "")
        local n = tonumber(word)
        if n and item.options[n] then
            return item.options[n].label
        end
        for _, o in ipairs(item.options) do
            if o.label:lower() == word then
                return o.label
            end
        end
        return nil
    end
    local one = find(body)
    if one then
        return { labels = { one } }
    end
    if item.multi then
        local labels, seen = {}, {}
        for part in (body:gsub("%s+and%s+", ",") .. ","):gmatch("([^,]*),") do
            local label = text.trim(part) ~= "" and find(part) or nil
            if text.trim(part) ~= "" and not label then
                return { other = body }
            end
            if label and not seen[label] then
                seen[label] = true
                labels[#labels + 1] = label
            end
        end
        if #labels > 0 then
            return { labels = labels }
        end
    end
    return { other = body }
end

--- The picked options of a multi-select card, in the options' order.
local function pickedLabels(item)
    local labels = {}
    for _, o in ipairs(item.options) do
        if item.picked[o.label] then
            labels[#labels + 1] = o.label
        end
    end
    return labels
end

function draw.question(item, width)
    local ui = require("bragi.ui")
    if item.inner then
        gitgud.destroyWindow(item.inner)
    end
    item.gen = (item.gen or 0) + 1
    item.inner = item.name .. "G" .. item.gen
    local root = item.inner
    ui.box(root, item.name, { 0, 0, width, 100 }, { fill = C.panel, border = item.answer and C.border or C.accent })

    local PAD, BUTTON = 16, 84
    local inner = width - PAD * 2
    local head = item.header ~= "" and item.header or "Question"
    if item.count > 1 then
        head = head .. "  \u{00B7}  " .. item.index .. " of " .. item.count
    end
    if agent.askedBy(item) then
        head = agent.askedBy(item) .. "  \u{00B7}  " .. head
    end
    ui.heading(root .. "Head", root, { PAD, PAD, inner, 16 }, head)
    local title = ui.paragraph(root .. "Title", root, { PAD, PAD + 22, inner, 40 }, item.question,
        { font = "Bragi-15-Bold" })
    local th = math.ceil(tonumber(gitgud.getProperty(title, "VertExtent") or "") or 20) + 4
    gitgud.setProperty(title, "Area", geometry.rect(PAD, PAD + 22, inner, th))
    local y = PAD + 22 + th + 12

    if item.answer then
        -- Answered: what Claude got, and how it was answered.
        local quiet = item.skipped or item.answer == "Cancelled"
        local answer = ui.paragraph(root .. "Answer", root, { PAD, y, inner, 40 }, item.answer,
            { font = "Bragi-14-Bold", colour = quiet and C.sub or C.accentText })
        local ah = math.ceil(tonumber(gitgud.getProperty(answer, "VertExtent") or "") or 20) + 4
        gitgud.setProperty(answer, "Area", geometry.rect(PAD, y, inner, ah))
        y = y + ah + 4
        if item.answerNote then
            ui.label(root .. "How", root, { PAD, y, inner, 20 }, item.answerNote, { font = "Bragi-13", colour = C.sub })
            y = y + 24
        end
        gitgud.setProperty(root, "Area", geometry.rect(0, 0, width, y + PAD - 4))
        return y + PAD - 4
    end

    for i, o in ipairs(item.options) do
        local row = root .. "Option" .. i
        local picked = item.picked[o.label]
        ui.button(row, root, { PAD, y, inner, OPTION_HEIGHT }, "",
            { tooltip = o.description ~= "" and o.description or nil })
        gitgud.setProperty(row, "NormalFillColour", picked and C.sel or C.transparent)
        gitgud.setProperty(row, "HoverFillColour", C.hover)
        gitgud.setProperty(row, "PushedFillColour", C.sel)
        gitgud.setProperty(row, "BorderColour", picked and C.accent or C.border)
        local x = 14
        if item.multi then
            local box = row .. "Box"
            gitgud.createWindow("Gitgud/Icon", box, row)
            gitgud.setProperty(box, "Area", geometry.rect(14, 19, 14, 14))
            gitgud.setProperty(box, "IconImage", picked and "Bragi-Icons/CheckMark" or "Bragi-Icons/CheckRing")
            gitgud.setProperty(box, "IconColour", picked and C.accent or C.borderStrong)
            gitgud.setProperty(box, "GlowColour", "00000000")
            gitgud.setProperty(box, "CursorPassThroughEnabled", "true")
            x = 38
        end
        ui.label(row .. "Label", row, { x, 8, inner - x - 12, 20 }, i .. ".  " .. o.label, { font = "Bragi-14-Bold" })
        ui.label(row .. "Desc", row, { x, 28, inner - x - 12, 18 }, o.description,
            { font = "Bragi-13", colour = C.sub })
        gitgud.on(row .. ".clicked", function()
            if item.answer then
                return
            end
            if item.multi then
                item.picked[o.label] = not picked or nil
                item.dirty = true
                agent.layoutSoon()
            else
                agent.answerQuestion(item, { labels = { o.label } })
            end
        end)
        y = y + OPTION_HEIGHT + OPTION_GAP
    end

    -- Your own answer: Enter (or Send) answers with it; on a multi-select
    -- card it goes with what's ticked, on Submit.
    local fieldWidth = item.multi and inner or inner - BUTTON - 10
    local edit = ui.input(root .. "Other", root, { PAD, y + 2, fieldWidth, 40 }, item.other)
    local hint = ui.label(root .. "OtherHint", root .. "Other", { 12, 0, fieldWidth - 24, 40 },
        "Or answer in your own words", { colour = C.sub })
    placeholder.bind(edit, hint)
    local function submit()
        if item.answer then
            return
        end
        local choice = { labels = item.multi and pickedLabels(item) or nil, other = item.other }
        if answerText(choice) ~= "" then
            agent.answerQuestion(item, choice)
        end
    end
    gitgud.on(edit .. ".changed", function(value)
        item.other = value or ""
    end)
    gitgud.on(edit .. ".accepted", submit)
    if not item.multi then
        local send = ui.button(root .. "OtherSend", root, { PAD + inner - BUTTON, y + 2, BUTTON, 40 }, "Send")
        gitgud.on(send .. ".clicked", submit)
    end
    y = y + 2 + 40 + 12

    -- Skip (and Submit on a multi-select card) on the right.
    local right = PAD + inner
    if item.multi then
        local done = ui.button(root .. "Submit", root, { right - BUTTON, y, BUTTON, 40 }, "Submit", { primary = true })
        gitgud.on(done .. ".clicked", submit)
        right = right - BUTTON - 10
    end
    local skip = ui.button(root .. "Skip", root, { right - BUTTON, y, BUTTON, 40 }, "Skip",
        { tooltip = "Go on without answering" })
    gitgud.on(skip .. ".clicked", function()
        agent.answerQuestion(item, nil)
    end)
    y = y + 40 + PAD
    gitgud.setProperty(root, "Area", geometry.rect(0, 0, width, y))
    return y
end

--- A conversation's page: the window in AgentTranscript its items are made
-- in. Only the shown one has a size (layout()), since the transcript's
-- scroll pane sizes itself to every child, hidden or not
-- (the master's long transcript, kept while another conversation showed,
-- made that one open on empty space).
local function pageOf(tab)
    if not tab.page or not gitgud.getRect(tab.page) then
        pages = pages + 1
        tab.page = "AgentPage" .. pages
        gitgud.createWindow("DefaultWindow", tab.page, "AgentTranscript")
        gitgud.setVisible(tab.page, tab == cur)
    end
    return tab.page
end

--- Put away a conversation's page while another is shown: hidden, and
-- with no size. layout() sizes it again when its conversation shows.
local function stow(tab)
    if tab.page then
        gitgud.setVisible(tab.page, false)
        gitgud.setProperty(tab.page, "Area", geometry.rect(0, 0, 0, 0))
    end
end

--- The index of the transcript's newest item, not counting the cards at
-- its end that still wait on you, nor the plan above them: those stay
-- last, under whatever comes after them, so a card is never left above a
-- conversation that goes on (a background helper's, while the
-- conversation's own agent keeps working), and the plan
-- stays under the latest message.
local function openTail()
    local n = #items
    while n > 0 and (waitsOnYou(items[n]) or items[n].kind == "plan") do
        n = n - 1
    end
    return n
end

--- Add an item and its container: a card at the end, the plan before the
-- open cards, anything else before both. Returns it.
local function addItem(item)
    -- A new window: nothing about the old one's layout carries over.
    item.area, item.culled, item.md, item.mdInner = nil, nil, nil, nil
    item.name = item.name or newName()
    if not gitgud.createWindow("DefaultWindow", item.name, pageOf(ctx)) then
        return item
    end
    if ctx == cur then
        fresh = true
    end
    item.dirty = true
    local function beforeCards(it)
        local n = #items
        while n > 0 and waitsOnYou(items[n]) do
            n = n - 1
        end
        table.insert(items, n + 1, it)
    end
    if waitsOnYou(item) then
        items[#items + 1] = item
    elseif item.kind == "plan" then
        beforeCards(item)
    else
        table.insert(items, openTail() + 1, item)
        -- A card answered since the plan came ends the tail: the plan goes
        -- back under what's new.
        local box = ctx.planItem
        for i = #items, 1, -1 do
            if items[i] == box then
                if i < #items and not waitsOnYou(items[i + 1]) then
                    table.remove(items, i)
                    beforeCards(box)
                end
                break
            end
        end
    end
    return item
end

--- The index of an item in the handlers' tab, or nil.
local function indexOf(item)
    for i, it in ipairs(items) do
        if it == item then
            return i
        end
    end
    return nil
end

draw.plan = plan.draw

--- A plan tool's call changed the plan of the handlers' tab (ctx): its box
-- made, redrawn in place, or taken away once the plan is empty.
local function planChanged(news)
    local box = ctx.planItem
    if box and not indexOf(box) then
        box, ctx.planItem = nil, nil -- cleared away
    end
    if #ctx.plan.steps == 0 then
        if box then
            gitgud.destroyWindow(box.name)
            table.remove(items, indexOf(box))
            ctx.planItem = nil
        end
    elseif not box then
        ctx.planItem = addItem({ kind = "plan", plan = ctx.plan })
    else
        box.plan = ctx.plan
        box.dirty = true
        if ctx == cur then
            fresh = true
        end
        -- A new plan, or one just done, folds as plan.folded says again.
        if news and (news.new or news.finished) then
            box.folded = nil
        end
    end
    agent.layoutSoon()
end

-- ===================================================================
-- Following the end: the shown conversation keeps to
-- its latest line until you scroll up from it. Scrolled up to read, it
-- stays where it is, and anything new in it shows "Jump to latest" over
-- the prompt box; conversations in the background never move it (each of
-- their events scrolled the shown one down, since the parallel sessions
-- of 2026-10-11). Your own message or answer, and opening a conversation,
-- go to the end.
--
-- `following` is what you did, not a guess from where the view is: only
-- your own scrolling up turns it off, and getting back to the end turns it
-- on. A guess made at each layout, against the height the last layout
-- left, lost the end when Bragi hadn't scrolled at all: the waiting row
-- went as the answer's first line came, so the view looked a row short;
-- the prompt box grew, so the view looked shorter.
-- ===================================================================

--- Show only the items near the view (the app froze for
-- seconds at a time in long conversations). The renderer gathers every
-- shown window's text into one buffer at each redraw, so a long
-- conversation cost hundreds of milliseconds a frame while anything in it
-- moved; hidden ones cost nothing. Items within a view's height (at least
-- CULL_MARGIN) above and below stay shown, so scrolling shows them at once.
local CULL_MARGIN = 900

--- The part of the page kept drawn: the view, and a view's height (at
-- least CULL_MARGIN) above and below it. `total`: the page's height, for
-- a view that follows the end.
local function nearView(total, atEndOfPage)
    local _, _, _, viewHeight = gitgud.getRect("AgentTranscript")
    viewHeight = viewHeight or 0
    local top = atEndOfPage and math.max(0, total - viewHeight) or (gitgud.getScroll("AgentTranscript") or 0)
    local margin = math.max(CULL_MARGIN, viewHeight)
    return top - margin, top + viewHeight + margin
end

local layout -- below: cull() lays out again when undrawn items come near
local culling = false

local function cull()
    if ctx ~= cur or culling then
        return
    end
    local from, to = nearView()
    -- Scrolled to items not drawn yet (a long conversation draws only
    -- what's near the view): draw them now (a few times at most: drawing
    -- them can move the view).
    for _ = 1, 3 do
        local undrawn = false
        for _, item in ipairs(items) do
            if item.top and item.guess and item.top + item.guess >= from and item.top <= to then
                undrawn = true
                break
            end
        end
        if not undrawn then
            break
        end
        culling = true
        layout()
        culling = false
        from, to = nearView()
    end
    for _, item in ipairs(items) do
        if item.top then
            local hidden = item.top + (item.guess or item.height or 0) < from or item.top > to
            if item.culled ~= hidden then
                item.culled = hidden
                gitgud.setVisible(item.name, not hidden)
            end
        end
    end
end

--- How long the last layout took (ms): a slow one waits longer before the
-- next (agent.layoutSoon).
local layoutCost = 0

--- Whether the shown transcript is at its end, as the pane knows it now.
local function atEnd()
    return gitgud.getScroll("AgentTranscript") >= gitgud.getScrollMax("AgentTranscript") - END_SLACK
end

--- Scroll the transcript, as this file (not you).
local function scrollTo(px)
    ownScroll = true
    gitgud.setScroll("AgentTranscript", px)
    ownScroll = false
end

local function hideJump()
    gitgud.setVisible(JUMP, false)
end

local function showJump()
    gitgud.setVisible(JUMP, true)
end

--- Follow the end again, from there.
local function toEnd()
    following = true
    hideJump()
    scrollTo(1e9)
end

--- The transcript scrolled: you (the wheel, its scrollbar), this file, or
-- the pane keeping in range as rows went (which lands on the end).
local function onScrolled()
    cull()
    if atEnd() then
        following = true
        hideJump()
    elseif not ownScroll then
        following = false
    end
end

-- A long conversation (more than LAZY_ITEMS items) draws only the items
-- near the view; the others keep the height they had (or a guess) until
-- they come near. Drawing every item again, at a hot reload or a new
-- column width, took seconds to minutes in a long conversation
-- (a day's master conversation froze the app for a minute).
local LAZY_ITEMS = 80

--- An item's height before it's drawn at this width: its height at the
-- width it was drawn at, scaled; kept over a reload; or a guess from its
-- text.
local function guessHeight(item, column)
    if item.kind == "thinking" and not hasThought(item) then
        return 0
    end
    if item.height and item.drawnWidth and item.drawnWidth > 0 then
        return math.max(20, math.floor(item.height * item.drawnWidth / column + 0.5))
    end
    if tonumber(item.estimate) then
        return math.max(20, math.floor(tonumber(item.estimate)))
    end
    if item.kind == "step" or item.kind == "thinking" or item.kind == "waiting" then
        return 28
    end
    local chars = #(item.text or "")
    return 12 + 22 * math.max(1, math.ceil(chars / math.max(20, column / 8)))
end

--- Stack the items, drawing those that need it inside [from, to] (all of
-- them when from is nil). Returns the page's height.
local function stack(column, left, from, to)
    local y = 32
    local previous = nil
    for _, item in ipairs(items) do
        local height = item.height
        if item.dirty or item.drawnWidth ~= column then
            local guess = guessHeight(item, column)
            if not from or (y + guess >= from and y <= to) then
                item.height = draw[item.kind](item, column)
                item.drawnWidth = column
                item.dirty = false
                item.area = nil
                item.guess = nil
                height = item.height
            else
                item.guess = guess
                height = guess
            end
        end
        local isStep = item.kind == "step" or item.kind == "thinking" or item.kind == "waiting"
        local shown = height > 0 -- a thinking row with no words takes no room, nor a gap
        if previous and shown then
            local prevStep = previous.kind == "step" or previous.kind == "thinking" or previous.kind == "waiting"
            y = y + ((isStep and prevStep) and STEP_GAP or MESSAGE_GAP)
        end
        local width = item.kind == "user" and not item.guess and item.width or column
        local x = item.kind == "user" and left + column - width or left
        -- Only what moved: setting every item's area at each layout made
        -- them all draw again.
        local area = item.area
        if not area or area[1] ~= x or area[2] ~= y or area[3] ~= width or area[4] ~= height then
            gitgud.setProperty(item.name, "Area", geometry.rect(x, y, width, height))
            item.area = { x, y, width, height }
        end
        item.top = y
        y = y + height
        if shown then
            previous = item
        end
    end
    return y
end

local function layoutNow(drawAll)
    local column = columnWidth()
    local w = mainSize()
    local left = math.floor((w - column) / 2)
    local y
    local keepAt = nil -- where to scroll so the view's top item stays put
    if #items <= LAZY_ITEMS or drawAll then
        y = stack(column, left)
    else
        -- Where everything goes with the heights known, then draw what's
        -- near the view. Scrolled up, the item at the view's top stays put.
        local total = stack(column, left, math.huge, -math.huge)
        local from, to = nearView(total, following)
        local scroll = gitgud.getScroll("AgentTranscript") or 0
        local anchor = nil
        if not following then
            for _, item in ipairs(items) do
                if item.top + (item.guess or item.height or 0) > scroll then
                    anchor = item
                    break
                end
            end
        end
        local before = anchor and anchor.top
        y = stack(column, left, from, to)
        if anchor and anchor.top ~= before then
            keepAt = scroll + anchor.top - before
        end
    end
    -- The page is as big as what's on it: the pane measures it once.
    gitgud.setProperty(pageOf(cur), "Area", geometry.rect(0, 0, left + column, y))
    if keepAt then
        scrollTo(keepAt)
    end

    gitgud.setVisible("AgentEmpty", #items == 0)
    if following then
        toEnd()
    elseif fresh then
        showJump()
    end
    fresh = false
    textselect.refresh()
end

--- Size and stack every item in the transcript.
-- @param drawAll  draw every item that needs it, near the view or not
--                 (what you asked to see: earlier messages shown)
function layout(drawAll)
    if ctx ~= cur then
        return -- a tab in the background: laid out when it's shown
    end
    local started = os.clock()
    layoutPending = false
    -- Scrolling while it lays out (to the end, or to keep the view's top)
    -- culls once it's done, not in the middle.
    local nested = culling
    culling = true
    local ok, err = pcall(layoutNow, drawAll)
    culling = nested
    if not ok then
        error(err, 0)
    end
    cull()
    layoutCost = (os.clock() - started) * 1000
end

--- Lay out after the current event (streamed pieces arrive many a frame).
function agent.layoutSoon()
    if layoutPending then
        return
    end
    layoutPending = true
    -- At most every 60 ms, and a slow layout (a long reply streaming in)
    -- waits three times as long as it took, so the app keeps three
    -- quarters of its time for everything else.
    gitgud.after(math.min(1000, math.max(60, math.floor(layoutCost * 3))), function()
        if layoutPending then
            layoutPending = false
            layout()
        end
    end)
end

--- Place the regions for the window's size and the sidebar's state.
local function relayout()
    local sidebar = sidebarOpen and (sidebarSplit and sidebarSplit.width() or SIDEBAR) or 0
    gitgud.setVisible("AgentSidebar", sidebarOpen)
    gitgud.setProperty("AgentSidebar", "Area", string.format("{{0,0},{0,0},{0,%d},{1,0}}", sidebar))
    if sidebarSplit then
        if sidebarOpen then
            sidebarSplit.place(sidebar, 0, 0)
        else
            sidebarSplit.hide()
        end
    end
    -- The session panel (bragi/sidepanel.lua) places itself on the right and
    -- says how much of the width it takes.
    local _, _, rootWidth = gitgud.getRect("AgentRoot")
    local panel = require("bragi.sidepanel").place((rootWidth or 0) - sidebar)
    panelShown = panel
    gitgud.setProperty("AgentMain", "Area", string.format("{{0,%d},{0,0},{1,%d},{1,0}}", sidebar, -panel))

    local half = math.floor(columnWidth() / 2)
    -- The pictures the next message takes go in a row above the text.
    local row = #(cur.attachments or {}) > 0 and ATTACH_ROW or 0
    local composer = COMPOSER + row
    gitgud.setProperty("AgentComposer", "Area", string.format(
        "{{0.5,%d},{1,%d},{0.5,%d},{1,%d}}", -half, -(composer + COMPOSER_GAP), half, -COMPOSER_GAP))
    gitgud.setProperty("AgentPromptEdit", "Area", string.format("{{0,14},{0,%d},{1,-14},{1,-72}}", 12 + row))
    gitgud.setProperty("AgentPromptPlaceholder", "Area",
        string.format("{{0,22},{0,%d},{1,-22},{0,%d}}", 16 + row, 40 + row))
    gitgud.setProperty("AgentTranscript", "Area", string.format(
        "{{0,0},{0,%d},{1,0},{1,%d}}", HEADER, -(composer + COMPOSER_GAP + 8)))
    -- Jump to latest: centred at the transcript's foot, over its last line.
    local foot = composer + COMPOSER_GAP + 8 + 12
    local jumpHalf = math.floor(JUMP_W / 2)
    gitgud.setProperty(JUMP, "Area", string.format("{{0.5,%d},{1,%d},{0.5,%d},{1,%d}}",
        -jumpHalf, -(foot + JUMP_H), jumpHalf, -foot))

    layout()
end

--- Place the regions again (bragi/sidepanel.lua, when it opens or closes).
function agent.relayout()
    relayout()
end

-- ===================================================================
-- Pictures for the next message: pasted (Ctrl+V) or dropped on the
-- window, shown in a row in the prompt box with an x each; they go with
-- the message, before its text, and show in it.
-- ===================================================================

local ATTACH = "AgentAttachments"
local attachGen = 0

--- Draw the prompt box's row of pictures for the tab shown.
local function paintAttachments()
    local list = cur.attachments or {}
    if gitgud.getRect(ATTACH) then
        gitgud.destroyWindow(ATTACH)
    end
    if #list > 0 then
        attachGen = attachGen + 1
        gitgud.createWindow("DefaultWindow", ATTACH, "AgentComposer")
        gitgud.setProperty(ATTACH, "Area", string.format("{{0,14},{0,12},{1,-14},{0,%d}}", 12 + ATTACH_ROW - 8))
        local width = columnWidth() - 28
        images.place(ATTACH, ATTACH .. attachGen .. "_", list, 0, 0, width,
            { maxWidth = ATTACH_W, maxHeight = ATTACH_H, remove = function(i)
                table.remove(list, i)
                paintAttachments()
                paintPrimary()
            end })
    end
    relayout()
end

--- Add an image file to the next message (the tab shown).
-- @return true, or nil and why
function agent.attach(path)
    if not images.isImage(path) then
        return nil, "not an image"
    end
    cur.attachments = cur.attachments or {}
    for _, p in ipairs(cur.attachments) do
        if p == path then
            return true
        end
    end
    cur.attachments[#cur.attachments + 1] = path
    paintAttachments()
    paintPrimary()
    gitgud.focus("AgentPromptEdit")
    return true
end

--- The image files the next message takes (the tab shown).
function agent.attachments()
    return cur.attachments or {}
end

--- The window of the prompt box's ith picture (for tests); its x is this
-- name .. "Remove".
function agent.attachmentWindow(i)
    return ATTACH .. attachGen .. "_" .. i
end

--- Ctrl+V: a picture on the clipboard (a screenshot, an image copied in
-- a browser), or image files copied in a file manager, are attached. Text
-- pastes into the prompt box as it always did, alone: office apps put a
-- picture of copied text on the clipboard too.
function agent.pasteImage()
    if gitgud.clipboardHasText() then
        return false
    end
    local path = gitgud.clipboardImage()
    if path then
        return agent.attach(path)
    end
    local any = false
    for _, file in ipairs(gitgud.clipboardFiles()) do
        any = agent.attach(file) or any
    end
    return any
end

--- A file dropped on the window: an image is attached; another file's
-- path goes into the prompt box.
function agent.dropped(path)
    if agent.attach(path) then
        return
    end
    local now = gitgud.getText("AgentPromptEdit") or ""
    local sep = (now == "" or now:match("%s$")) and "" or " "
    placeholder.setText("AgentPromptEdit", now .. sep .. path)
    paintPrimary()
    gitgud.focus("AgentPromptEdit")
end

--- Go to the transcript's end for something you did (your message, your
-- answer, a conversation opened); what arrives by itself follows the end
-- only while you're at it (layout()).
local function scrollToEnd()
    if ctx == cur then
        toEnd()
    end
end

--- Add a message to the transcript.
-- @param role  "user", "assistant", or "note" (the app's own remarks)
-- @param body  text (Markdown for "assistant")
-- @param opts  { error = true } paints a note as an error; action =
--              { label, run = fn(item) } puts a button on a note ("Undo");
--              images = { paths } shows pictures in your message
function agent.addMessage(role, body, opts)
    local item = addItem({ kind = role, text = body or "", error = opts and opts.error,
        action = opts and opts.action, images = opts and opts.images })
    layout()
    if role == "user" then
        scrollToEnd()
    end
    return item
end

--- Change a note's text; its button goes (it's been used).
function agent.updateNote(item, body)
    if not item then
        return
    end
    item.text = body or ""
    item.action = nil
    gitgud.setText(item.name .. "Text", text.escape(item.text))
    item.dirty = true
    agent.layoutSoon()
end

--- The shown conversation's texts in order, for selecting them
-- (bragi/textselect.lua): your messages, notes, replies block by block,
-- and the details of open steps.
local function selectable()
    local out = {}
    local function add(item, n, name, gap, prefix, inButton)
        out[#out + 1] = { name = name, key = item.name .. "/" .. n, item = item, gap = gap,
            prefix = prefix, inButton = inButton }
    end
    for _, item in ipairs(cur.items or {}) do
        if (item.kind == "user" and (item.text or "") ~= "") or item.kind == "note" then
            add(item, 1, item.name .. "Text")
        elseif item.kind == "assistant" then
            for n, t in ipairs(item.texts or {}) do
                add(item, n, t.name, t.gap, t.prefix)
            end
        elseif (item.kind == "step" or item.kind == "thinking") and item.open and item.inner then
            add(item, 1, item.inner .. "Detail", nil, nil, true)
        end
    end
    return out
end

--- The right-click menu's items for the message under the mouse.
local function messageMenu(item)
    local s, label, what = nil, "Copy message", "the message"
    if item and (item.kind == "user" or item.kind == "assistant" or item.kind == "note") then
        s = item.text
        what = item.kind == "user" and "your message" or (item.kind == "assistant" and "the reply" or what)
    elseif item and (item.kind == "step" or item.kind == "thinking") then
        s, label, what = detailText(item), "Copy details", "the details"
    end
    if not s or s == "" then
        return {}
    end
    return { { label = label, action = function()
        textselect.put(s, what)
    end } }
end

--- The transcript's items (for tests): { kind, name, text, ... }.
function agent.items()
    return items
end

--- The current session: { name, id, running, turn, resume }.
function agent.session()
    return session
end

--- The tab shown (bragi/sidepanel.lua): { title, session, items, earlier }.
function agent.current()
    return cur
end

--- Empty the transcript.
function agent.clear()
    for _, item in ipairs(items) do
        gitgud.destroyWindow(item.name)
    end
    cur.items, cur.byToolId = {}, {}
    cur.earlier, cur.earlierNote = nil, nil
    cur.plan, cur.planItem = nil, nil
    use(cur)
    cur.title = "New session"
    gitgud.setText("AgentTitle", cur.title)
    layout()
end

--- Show (or retitle) the row that says something is on its way: from the
-- moment a message is sent (or a spoken one ends) to the agent's first
-- event. On the tab the handlers work on.
-- @param title  what it says ("Thinking", "Checking what was heard")
local function setWaiting(title)
    local w = ctx.waiting
    if w then
        w.title = title
        w.dirty = true
        agent.layoutSoon()
        return
    end
    -- Named apart, so messages keep their numbers (AgentMessage<n>).
    waitingCount = waitingCount + 1
    ctx.waiting = addItem({ kind = "waiting", title = title, icon = "Spark", name = "AgentWaiting" .. waitingCount })
    layout()
end

--- Remove a tab's waiting row (the answer started, or nothing is coming).
local function clearWaiting(tab)
    local w = tab.waiting
    if not w then
        return
    end
    tab.waiting = nil
    gitgud.destroyWindow(w.name)
    for i, item in ipairs(tab.items) do
        if item == w then
            table.remove(tab.items, i)
            break
        end
    end
    if tab == cur then
        agent.layoutSoon()
    end
end

--- A spoken message, shown the moment it ends, before the heard-text filter
-- has checked it (bragi/voice.lua): your message as heard, and a waiting
-- row. agent.send(text, { pending = item }) turns it into the real message;
-- agent.dropPending(item) takes it away when it isn't sent. A typed message
-- waits the same way while its route is checked (agent.submit).
-- @param heard  the text as heard
-- @param title  optional: what the waiting row says
-- @return the message's item
function agent.voicePending(heard, title)
    if #items == 0 and not cur.master then
        cur.title = heard:match("^[^\n]*"):sub(1, 80)
        gitgud.setText("AgentTitle", text.escape(cur.title))
    end
    local item = agent.addMessage("user", heard)
    item.pending = cur
    setWaiting(title or "Checking what was heard")
    paintSessions()
    return item
end

--- Retitle the shown tab's waiting row, when it has one.
function agent.waitingTitle(title)
    if cur.waiting then
        use(cur)
        setWaiting(title)
    end
end

--- A pending spoken message heard further (it carried on after a pause).
function agent.rehearPending(item, heard)
    if item and item.pending then
        item.text = heard
        item.dirty = true
        agent.layoutSoon()
    end
end

--- Take away a pending spoken message and its waiting row.
function agent.dropPending(item)
    local tab = item and item.pending
    if not tab then
        return
    end
    item.pending = nil
    clearWaiting(tab)
    gitgud.destroyWindow(item.name)
    for i, it in ipairs(tab.items) do
        if it == item then
            table.remove(tab.items, i)
            break
        end
    end
    if tab == cur then
        layout()
    end
end

--- A waiting message becomes `body` (the filter may have changed it).
local function settle(item, body)
    if item.text ~= body then
        item.text = body
        item.made = false
        gitgud.destroyWindow(item.name .. "Text")
        item.dirty = true
    end
end

-- ===================================================================
-- Quick answers (bragi/quick.lua)
-- ===================================================================

local QUICK_NOTES = 5         -- quick answers kept for the next message
local QUICK_NOTE_CHARS = 500  -- of each answer

--- The note the next message to the agent carries: the quick answers
-- since its last one, or nil.
local function quickNoteText(tab)
    local notes = tab.quickNotes
    if not notes or #notes == 0 then
        return nil
    end
    local answers, updates = { "Meanwhile, Haiku answered:" }, { "Meanwhile, Haiku told "
        .. require("bragi.user").label() .. " about the conversations you follow:" }
    for _, n in ipairs(notes) do
        local a = text.trim((n.a:gsub("%s+", " ")))
        if #a > QUICK_NOTE_CHARS then
            a = a:sub(1, QUICK_NOTE_CHARS) .. "..."
        end
        if n.update then
            updates[#updates + 1] = "- " .. a
        else
            answers[#answers + 1] = "Q: " .. text.trim((tostring(n.q or ""):gsub("%s+", " ")))
            answers[#answers + 1] = "A: " .. a
        end
    end
    local parts = {}
    for _, list in ipairs({ answers, updates }) do
        if #list > 1 then
            parts[#parts + 1] = table.concat(list, "\n")
        end
    end
    return table.concat(parts, "\n\n")
end

--- The agent's text in progress ends where a quick answer goes in: the
-- part already shown stays above it (handlers.message keeps it).
local function cutStreaming()
    for _, item in ipairs(items) do
        if item.kind == "assistant" and item.streaming then
            item.streaming = false
            item.cutBlock = true
        end
    end
end

--- Haiku answered a waiting message (agent.voicePending's item): the
-- answer goes under it, tagged, and rides along with the next message.
-- @param item      the message's item
-- @param question  the message as answered
-- @param answer    the answer's Markdown
-- @param opts      optional: quiet (a quiet row instead of a reply: a recap,
--                  bragi/recap.lua); update (news of the conversations Bragi
--                  follows, told unasked, with no message: bragi/voice.lua),
--                  with tab (the conversation it goes in)
function agent.quickAnswered(item, question, answer, opts)
    opts = opts or {}
    local tab = item and item.pending or opts.tab or cur
    use(tab)
    if item then
        item.pending = nil
        settle(item, question)
    end
    if not opts.update then
        clearWaiting(tab)
    end
    cutStreaming()
    if opts.quiet then
        addItem({ kind = "note", text = answer })
    else
        addItem({ kind = "assistant", text = answer, tag = opts.update and "Update by Haiku" or "Answered by Haiku" })
    end
    tab.quickNotes = tab.quickNotes or {}
    local notes = tab.quickNotes
    notes[#notes + 1] = { q = question, a = answer, update = opts.update }
    if #notes > QUICK_NOTES then
        table.remove(notes, 1)
    end
    use(cur)
    if tab == cur then
        layout()
    end
    paintSessions()
end

--- Haiku handed a waiting message back: say so under it. The caller sends
-- it on (agent.send with the item as `pending`).
function agent.quickHandoff(item, line)
    local tab = item and item.pending or cur
    use(tab)
    clearWaiting(tab)
    addItem({ kind = "note", text = line })
    use(cur)
    if tab == cur then
        layout()
    end
end

--- A waiting message the app answered itself (bragi/slash.lua): it stays
-- as asked, with a quiet row under it, and goes nowhere.
-- @param item      agent.voicePending's item
-- @param question  the message as answered
-- @param line      the row's text
function agent.pendingNoted(item, question, line)
    local tab = item and item.pending or cur
    use(tab)
    if item then
        item.pending = nil
        settle(item, question)
    end
    clearWaiting(tab)
    addItem({ kind = "note", text = line })
    use(cur)
    if tab == cur then
        layout()
        scrollToEnd()
    end
    paintSessions()
end

--- The quick answers waiting to ride along with the shown conversation's
-- next message (for tests): { {q, a}, ... }.
function agent.quickNotes()
    return cur.quickNotes or {}
end

-- ===================================================================
-- The session
-- ===================================================================

local function setTurn(on)
    session.turn = on
    if ctx == cur then
        paintPrimary()
    end
end

-- ===================================================================
-- Working on an issue
-- ===================================================================

--- What the session is told about the issue.
local function taskPrompt(task)
    return "You are working on issue #" .. task.number .. " of " .. task.repo .. ": " .. task.title .. ". "
        .. "When the work is complete, end the final commit's message with \"Closes #" .. task.number
        .. "\" so the issue closes when it lands on the default branch."
end

--- What every main session is told (prompts/main-session.md, read once,
-- the user's name filled in each time, bragi/user.lua): end a reply that
-- asks the user to decide with a question card, so they can answer by
-- voice without the wake word. "" when the file is
-- missing.
local mainPromptText = nil
local function mainPrompt()
    if not mainPromptText then
        mainPromptText = ""
        for _, root in ipairs(require("bragi.customize").roots()) do
            local f = root and io.open(root .. "/prompts/main-session.md", "rb")
            if f then
                mainPromptText = text.trim(f:read("a"))
                f:close()
                break
            end
        end
    end
    return require("bragi.user").fill(mainPromptText)
end

--- The main session's appended system prompt: the main prompt, then the
-- issue's when it works on one. Nil when there's neither.
local function appendedPrompt(task, extra)
    local parts = {}
    if mainPrompt() ~= "" then
        parts[#parts + 1] = mainPrompt()
    end
    if extra and extra ~= "" then
        parts[#parts + 1] = extra
    end
    if task then
        parts[#parts + 1] = taskPrompt(task)
    end
    return #parts > 0 and table.concat(parts, "\n\n") or nil
end

--- A turn's result, cut to a summary for the server.
local function summarise(s)
    s = text.trim((s or ""):match("^(.-)\n%s*\n") or s or ""):gsub("%s+", " ")
    local count = utf8.len(s)
    if count and count > 400 then
        s = s:sub(1, utf8.offset(s, 401) - 1) .. "..." -- cut on a character
    end
    return s
end

--- Record the session's state on the server (created the first time).
-- @param status   "working", "waiting", "done", or "failed"
-- @param summary  what it last did (optional)
local function track(status, summary)
    local task = session.task
    if not task then
        return
    end
    local server = require("bragi.server")
    local body = { status = status, summary = summary, branch = require("core.repo").state().branch,
        conversation = session.id or session.resume }
    if task.remoteId then
        server.request("PATCH", "/api/bragi/v0/sessions/" .. task.remoteId, body)
        return
    end
    if task.creating then
        task.pending = body -- sent once the server has made the session
        return
    end
    task.creating = true
    body.title = task.title
    body.machine = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or ""
    server.request("POST", "/api/bragi/v0/repos/" .. task.repo .. "/issues/" .. task.number .. "/sessions", body,
        function(created)
            task.remoteId = type(created) == "table" and created.id or nil
            if task.remoteId and task.pending then
                server.request("PATCH", "/api/bragi/v0/sessions/" .. task.remoteId, task.pending)
                task.pending = nil
            end
        end, function(msg)
            agent.addMessage("note", "This session wasn't recorded: " .. tostring(msg), { error = true })
        end)
end

--- Keep one comment on the issue with the latest progress.
local function report(summary)
    local task = session.task
    if not task or summary == "" then
        return
    end
    local server = require("bragi.server")
    local branch = require("core.repo").state().branch
    local body = "Bragi is working on this" .. (branch ~= "" and (" on `" .. branch .. "`") or "") .. ".\n\n"
        .. "**Latest:** " .. summary
    if task.commentId then
        server.request("PATCH", "/api/v1/repos/" .. task.repo .. "/issues/comments/" .. task.commentId, { body = body })
        return
    end
    server.request("POST", "/api/v1/repos/" .. task.repo .. "/issues/" .. task.number .. "/comments",
        { body = body, author = "bragi" },
        function(comment)
            task.commentId = type(comment) == "table" and comment.id or nil
            if task.commentId and task.remoteId then
                server.request("PATCH", "/api/bragi/v0/sessions/" .. task.remoteId, { comment_id = task.commentId })
            end
        end)
end

--- Whether a tab's session needs to stay open: a turn running, a
-- permission waiting for an answer, background tasks running (its
-- sub-agents die with its process, as four helpers did on 2026-10-17), or
-- a message of its own still being checked (agent.voicePending): it's sent
-- there once checked.
local function busy(tab)
    if tab.session.turn or require("bragi.sidepanel").running(tab) > 0 then
        return true
    end
    for _, item in ipairs(tab.items) do
        if waitsOnYou(item) or item.pending == tab then
            return true
        end
    end
    return false
end

--- Leave the shown tab for another: a busy one goes on in the background
-- (its items hidden); an idle one is closed (its session ends a moment
-- later) and dropped.
local closedHere = {} -- session id -> when this app closed it (os.time())
local closedActive = {} -- session id -> its last message, as the tab closed knew it
local function leave()
    local tab = cur
    if busy(tab) or tab.master then
        -- The master conversation stays, open, while you look elsewhere.
        stow(tab)
        return
    end
    if tab.session.name and tab.session.running then
        gitgud.agentStop(tab.session.name)
    end
    for _, id in ipairs({ tab.session.id, tab.session.resume }) do
        if id and id ~= "" then
            closedHere[id] = os.time()
            closedActive[id] = math.max(closedActive[id] or 0, tab.updated or 0)
        end
    end
    for _, item in ipairs(tab.items) do
        gitgud.destroyWindow(item.name)
    end
    if tab.page then
        gitgud.destroyWindow(tab.page)
    end
    for i, t in ipairs(tabs) do
        if t == tab then
            table.remove(tabs, i)
            break
        end
    end
end

--- The open repository follows the conversation shown: its folder opens
-- when it's a repository that isn't open.
local function follow(tab)
    local cwd = tab.cwd
    if not cwd or cwd == "" or tab.master then
        return
    end
    local projects = require("bragi.projects")
    if projects.key(cwd) ~= projects.key(require("core.repo").state().path) and projects.isRepo(cwd) then
        gitgud.openRepo(cwd)
    end
end

--- Show a tab (a new one when nil); one not in the list yet joins it.
local function show(tab)
    tab = tab or newTab()
    local listed = false
    for _, t in ipairs(tabs) do
        listed = listed or t == tab
    end
    if not listed then
        tabs[#tabs + 1] = tab
    end
    cur = tab
    use(tab)
    textselect.clear()
    -- Only this conversation's page takes room in the transcript.
    for _, t in ipairs(tabs) do
        if t ~= tab then
            stow(t)
        end
    end
    gitgud.setVisible(pageOf(tab), true)
    tab.unread = nil
    for _, item in ipairs(tab.items) do
        -- Items made while the tab wasn't shown are drawn now, at this width.
        if not item.height or item.height <= 0 then
            item.dirty = true
        end
    end
    -- It opens on its latest exchange.
    following = true
    fresh = false
    paintAttachments()
    gitgud.setText("AgentTitle", text.escape(tab.title))
    layout()
    toEnd()
    paintPrimary()
    follow(tab)
    if agent.refreshFolder then
        agent.refreshFolder()
    end
    app.publish("bragi.tabShown", tab) -- the session panel follows it
end

--- Claude Code settings the session adds to the user's (--settings), as
-- JSON text, or nil: the output style, when it isn't the default, and the
-- allow list for Bragi's own tools that need no card (bragi/uitools.lua).
-- @param name  the session's name (the tools it has)
function agent.extraSettings(name)
    local extra, any = {}, false
    local style = settings.get("bragi.outputStyle", "default")
    if style ~= "" and style ~= "default" then
        extra.outputStyle, any = style, true
    end
    local allow = require("bragi.uitools").allowRules(name)
    if #allow > 0 then
        extra.permissions, any = { allow = allow }, true
    end
    return any and gitgud.jsonEncode(extra) or nil
end

--- Start the session of the tab the handlers work on, in its folder (the
-- open repository's the first time). True when it started.
local function startSession()
    local tab = ctx
    sessionCount = sessionCount + 1
    local name = tab.sessionName or ("bragi" .. sessionCount)
    local cwd = tab.cwd or require("core.repo").state().path
    tab.cwd = cwd ~= "" and cwd or nil
    session.cwd = tab.cwd
    local options = {
        program = require("bragi.claude").program(),
        cwd = tab.cwd,
        model = settings.get("bragi.model", "opus"),
        permissionMode = settings.get("bragi.mode", "default"),
        effort = settings.get("bragi.effort", ""),
        settings = agent.extraSettings(name),
        resume = session.resume,
        appendSystemPrompt = appendedPrompt(session.task, tab.extraPrompt),
        uiTools = true, -- the UI's declared tools: bragi_settings_get/set (bragi/settingstool.lua)
    }
    for k, v in pairs(tab.startOptions or {}) do
        options[k] = v
    end
    -- This start only: where a rewind or a fork goes on from (bragi/rewind.lua).
    for k, v in pairs(session.startOnce or {}) do
        options[k] = v
    end
    session.startOnce = nil
    session.effort = options.effort -- the thinking level it runs with (showChoices)
    local ok, err = gitgud.agentStart(name, options)
    if not ok then
        agent.addMessage("note", "Claude Code didn't start: " .. tostring(err), { error = true })
        return false
    end
    for i = #stderrTail, 1, -1 do
        stderrTail[i] = nil
    end
    session.name = name
    session.running = true
    session.id = session.resume
    track("working")
    return true
end

--- Start the shown conversation's session ahead of its first message, so
-- Claude Code's start-up is over by then: it waits for every MCP server's
-- tool list before the first turn, up to 30 s for one that doesn't answer.
-- Voice turns it on with listening. True when one was started.
function agent.warm()
    if session.running or session.turn or session.task then
        return false
    end
    if not startSession() then
        return false
    end
    session.warm = true -- not listed as live until it has a message
    return true
end

local closeSlash -- the slash command dropdown (below)

--- Your message went to Claude Code: it's in the transcript now, so it
-- can be rewound to or forked from (bragi/rewind.lua).
local function markSent(item)
    if item and not item.sent then
        item.sent = true
        item.dirty = true
        agent.layoutSoon()
    end
end

local CONTEXT_OPEN = "<voice-context>"
local CONTEXT_CLOSE = "</voice-context>"
local CONTEXT_NOTICE = "Speech heard before this message, for context only; it may or may not be relevant. "
    .. "It isn't part of the message."

--- What the agent gets for a message with voice context: the message,
-- then the context in its block (after it, so a saved session's title is
-- still the message).
function agent.withContext(body, context)
    context = text.trim(context or "")
    if context == "" then
        return body
    end
    return body .. "\n\n" .. CONTEXT_OPEN .. "\n" .. CONTEXT_NOTICE .. "\n" .. context .. "\n" .. CONTEXT_CLOSE
end

--- A message as the view shows it: without its voice context block.
function agent.shownText(s)
    s = tostring(s or "")
    if not s:find(CONTEXT_OPEN, 1, true) then
        return s
    end
    return text.trim((s:gsub("%s*<voice%-context>.-</voice%-context>", "")))
end

--- Send what's in the prompt box (or the given text).
-- @param body  optional text; defaults to the prompt box
-- @param opts  optional: voice (it was spoken: the reply is spoken too),
--              note (shown under the message: what the filter changed),
--              pending (agent.voicePending's item: it becomes the message),
--              context (what the user said before, from the voice lookback:
--              sent after the message as context, never shown in it)
function agent.send(body, opts)
    opts = opts or {}
    -- Only text taken from the prompt box leaves it: a voice note sent
    -- once the turn was over wiped what the user was typing, or what was being
    -- heard.
    local fromBox = body == nil or text.trim(body) == text.trim(gitgud.getText("AgentPromptEdit") or "")
    body = text.trim(body or gitgud.getText("AgentPromptEdit"))
    local pending = opts.pending
    if pending and pending.pending and pending.pending ~= cur then
        -- Another conversation was shown while it was checked: it goes to
        -- the one it was said in, in the background, and only there, never
        -- to the one shown now (said with the audit shown,
        -- it showed there and the master acted on it).
        local tab = pending.pending
        agent.dropPending(pending)
        local listed = false
        for _, t in ipairs(tabs) do
            listed = listed or t == tab
        end
        if not listed then
            -- Closed meanwhile: listed again, its rows made anew when shown.
            for _, item in ipairs(tab.items) do
                item.made, item.dirty = false, true
            end
            tabs[#tabs + 1] = tab
        end
        return agent.sendTo(tab, body, { voice = opts.voice, context = opts.context })
    elseif pending and not pending.pending then
        pending = nil
    end
    -- The pictures waiting in the prompt box go with it.
    local pictures = cur.attachments or {}
    if body == "" and #pictures == 0 then
        agent.dropPending(pending)
        return
    end
    closeSlash()
    local command, args = body:match("^/(%S+)%s*(.-)$")
    if command and #pictures == 0 and agent.runAppCommand(command, args) then
        if fromBox then
            placeholder.setText("AgentPromptEdit", "")
        end
        paintPrimary()
        return
    end

    if fromBox then
        placeholder.setText("AgentPromptEdit", "")
    end
    require("bragi.rewind").showAll(false) -- /rewind's buttons: until the next message
    if #pictures > 0 then
        cur.attachments = {}
        paintAttachments()
    end
    local mine = pending
    if pending then
        pending.pending = nil
        pending.images = #pictures > 0 and pictures or nil
        pending.dirty = true
        settle(pending, body)
        -- The note goes under the message, above the waiting row.
        clearWaiting(cur)
    else
        if #items == 0 and not cur.master then
            cur.title = body ~= "" and body:match("^[^\n]*"):sub(1, 80) or "Image"
            gitgud.setText("AgentTitle", text.escape(cur.title))
        end
        mine = agent.addMessage("user", body, { images = #pictures > 0 and pictures or nil })
    end
    cur.updated = os.time()
    paintSessions()
    if opts.note then
        agent.addMessage("note", opts.note)
    end
    gitgud.focus("AgentPromptEdit")

    if not session.running and not startSession() then
        clearWaiting(cur)
        paintPrimary()
        return
    end
    -- Quick answers since the last message ride along as a note, so the
    -- agent knows them without its cache being touched. A slash command goes
    -- alone: anything after it would be its arguments (the notes wait for
    -- the next message).
    local notes = not command and quickNoteText(cur) or nil
    local sent = command and body or agent.withContext(body, opts.context)
    local ok, err = gitgud.agentSend(session.name, notes and (sent .. "\n\n" .. notes) or sent, pictures)
    if ok then
        markSent(mine)
        if notes then
            require("bragi.helpers").log("quick-note", { count = #cur.quickNotes })
            cur.quickNotes = nil
        end
        session.warm = nil
        session.voiceTurn = opts.voice == true
        session.turnStarted = gitgud.now()
        session.answered = false
        session.takenUp = false
        session.unprompted = nil
        setTurn(true)
        setWaiting("Thinking")
        app.publish("bragi.sent", { tab = cur, body = body, voice = opts.voice == true })
    else
        clearWaiting(cur)
        agent.addMessage("note", "Couldn't send: " .. tostring(err), { error = true })
        paintPrimary()
    end
end

--- Send what's typed in the prompt box, by its route (bragi/quick.lua): a
-- quick question goes to Haiku, a recap of the conversations Bragi follows
-- to bragi/recap.lua, everything else to the agent. While the
-- route is checked the message shows, waiting.
function agent.submit()
    local body = text.trim(gitgud.getText("AgentPromptEdit") or "")
    if body ~= "" then
        app.publish("bragi.submitted", body)
    end
    local open = agent.openQuestion()
    if open and body ~= "" and not body:match("^/") then
        -- A question is open: what's typed answers it.
        closeSlash()
        placeholder.setText("AgentPromptEdit", "")
        paintPrimary()
        return agent.answerQuestion(open, agent.typedChoice(open, body), { by = "typed" })
    end
    if #(cur.attachments or {}) > 0 then
        -- Pictures go to the agent: the quick answers can't see them.
        return agent.send()
    end
    local quick = require("bragi.quick")
    if body == "" or quick.direct(body) then
        if body == "" or not session.turn or body:match("^/") then
            return agent.send()
        end
        closeSlash()
        placeholder.setText("AgentPromptEdit", "")
        local waiting = agent.voicePending(body, "Thinking")
        paintPrimary()
        return require("bragi.voice").whileWorking(body, { pending = waiting })
    end
    closeSlash()
    placeholder.setText("AgentPromptEdit", "")
    local item = agent.voicePending(body, "Thinking")
    paintPrimary()
    gitgud.focus("AgentPromptEdit")
    quick.route(body, function(route, _, command)
        if route == "quick" then
            quick.ask(body, { pending = item })
        elseif route == "recap" then
            -- How the conversations Bragi follows are doing (bragi/recap.lua).
            require("bragi.recap").answer(body, { pending = item })
        elseif route == "command" and require("bragi.slash").answer(item, body, command) then
            -- A slash command in any words ("compact this conversation"):
            -- run here, now or once the turn is over (bragi/slash.lua).
            return
        elseif session.turn then
            -- The agent is working: only a clear stop or change of
            -- direction interrupts it; anything else waits its turn.
            require("bragi.voice").whileWorking(body, { pending = item })
        else
            agent.send(body, { pending = item })
        end
    end)
end

-- ===================================================================
-- Slash commands
-- ===================================================================

-- The CLI's interactive-only commands: the app's own screens instead.
local SLASH_APP = {
    model = "claude",
    effort = "claude",
    permissions = "claude",
    ["output-style"] = "claude",
    config = "claude",
    login = "claude",
    status = "claude",
    mcp = "claude",
    memory = "memory",
}

-- The CLI's own screens: the app's that do the same.
local SLASH_SCREENS = {
    help = function()
        require("bragi.settings").open("shortcuts")
    end,
    resume = function()
        sidebarOpen = true
        relayout()
        require("core.status").info("Pick a conversation to go on with in the list.")
    end,
    rewind = function()
        require("bragi.rewind").showAll()
    end,
    tasks = function()
        require("bragi.sidepanel").showCard("tasks")
    end,
}

-- Offered by Claude Code but nothing in the app: they change its terminal
-- view (/color, /focus). Left out of the dropdown; typed, they still go.
local SLASH_HIDDEN = { color = true, focus = true }

--- Run an interactive-only command in the app. True when it was one.
-- With arguments only /clear and /new are (a name for the new session is
-- the CLI's, not ours); "/model sonnet" and the like go to Claude Code,
-- which runs them.
-- @param name  the command without its slash
-- @param args  optional: what follows it
function agent.runAppCommand(name, args)
    if name == "clear" or name == "new" then
        agent.newSession()
        return true
    end
    if (args or "") ~= "" then
        return false
    end
    if SLASH_SCREENS[name] then
        SLASH_SCREENS[name]()
        return true
    end
    local section = SLASH_APP[name]
    if not section then
        return false
    end
    require("bragi.settings").open(section)
    return true
end

--- Whether the app runs a command itself (a screen of its own, or /clear
-- and /new starting over) rather than Claude Code.
-- @param name  the command without its slash
function agent.isAppCommand(name)
    return name == "clear" or name == "new" or SLASH_SCREENS[name] ~= nil or SLASH_APP[name] ~= nil
end

--- The commands the prompt box offers: the session's (Claude Code's
-- commands, custom commands, skills) and the app's, sorted, once each.
function agent.slashCommands()
    local seen, list = {}, {}
    local function add(name)
        name = tostring(name):gsub("^/", "")
        if name ~= "" and not seen[name] and not SLASH_HIDDEN[name] then
            seen[name] = true
            list[#list + 1] = name
        end
    end
    for _, name in ipairs(loaded and loaded.slashCommands or {}) do
        add(name)
    end
    for _, name in ipairs(loaded and loaded.skills or {}) do
        add(type(name) == "table" and name.name or name)
    end
    for name in pairs(SLASH_APP) do
        add(name)
    end
    for name in pairs(SLASH_SCREENS) do
        add(name)
    end
    add("clear")
    add("new")
    table.sort(list)
    return list
end

--- Put a command in the prompt box, ready for its arguments.
function agent.completeSlash(name)
    local body = "/" .. name .. " "
    placeholder.setText("AgentPromptEdit", body)
    gitgud.setProperty("AgentPromptEdit", "CaretIndex", tostring(#body))
    paintPrimary()
    gitgud.focus("AgentPromptEdit")
end

local SLASH_SHOWN = 8
local slashOpen = false   -- the dropdown is ours and showing

closeSlash = function()
    if slashOpen then
        slashOpen = false
        require("ui.popup").close()
    end
end

--- Offer matching commands while the prompt box holds just "/...".
local function suggestSlash(value)
    local typed = (value or ""):match("^/(%S*)$")
    if not typed then
        closeSlash()
        return
    end
    local entries = {}
    for _, name in ipairs(agent.slashCommands()) do
        if name:sub(1, #typed):lower() == typed:lower() and #entries < SLASH_SHOWN then
            entries[#entries + 1] = { label = "/" .. name, action = function()
                agent.completeSlash(name)
            end }
        end
    end
    local x, y = gitgud.getRect("AgentComposer")
    if #entries > 0 and x then
        menu.popup(entries, x + 12, math.max(8, y - #entries * 30 - 16))
        slashOpen = true
        gitgud.focus("AgentPromptEdit")
    else
        closeSlash()
    end
end

--- Stop the running turn.
function agent.stop()
    if session.running and session.turn then
        gitgud.agentInterrupt(session.name)
    end
end

--- Answer a permission card (in its own conversation, shown or not).
-- Publishes "bragi.permissionAnswered" ({ item, by = "click" | "voice" | "bragi" }).
-- @param note  optional: how it was answered, shown on the card
--              ("Allowed by voice: ..."); answered by voice when given
-- @param by    optional: who answered instead ("bragi", bragi/master.lua)
function agent.answer(item, allow, note, by)
    if item.answer then
        return
    end
    gitgud.agentRespond((item.session or session).name, item.requestId, allow)
    item.answer = allow and "Allowed" or "Denied"
    item.answerNote = note
    item.dirty = true
    if (item.session or session) == cur.session then
        toEnd() -- the answer's reply comes at the end
    end
    agent.layoutSoon()
    track("working")
    paintSessions()
    app.publish("bragi.permissionAnswered", { item = item, by = by or (note and "voice" or "click") })
end

--- Words the user said with a spoken yes ("Yes, but it should already be
-- dark."), sent into the card's conversation right after it: a working one
-- takes them at its next step, as bragi_send's do.
function agent.remark(item, body)
    local s = item.session or session
    for _, tab in ipairs(tabs) do
        if tab.session == s then
            if not s.turn then
                return agent.sendTo(tab, body)
            end
            use(tab)
            addItem({ kind = "user", text = body })
            use(cur)
            if tab == cur then
                layout()
                scrollToEnd()
            end
            return gitgud.agentSend(s.name, body)
        end
    end
    return nil
end

--- Answer a question card; once every card of its request is answered,
-- the answers go to Claude. Publishes "bragi.permissionAnswered".
-- @param choice  { labels = { ... }, other = "your own words" }; nil skips it
-- @param opts    { note = how it was answered, shown on the card,
--                by = "click" | "voice" | "typed" | "bragi" (default "click") }
function agent.answerQuestion(item, choice, opts)
    if item.answer then
        return
    end
    opts = opts or {}
    local value = answerText(choice)
    item.skipped = value == ""
    item.answer = item.skipped and "Skipped" or value
    item.answerNote = opts.note
    item.dirty = true
    local group = item.group
    local done = true
    for _, q in ipairs(group.items) do
        done = done and q.answer ~= nil
    end
    if done and not group.sent then
        group.sent = true
        local answers, any = {}, false
        for _, q in ipairs(group.items) do
            answers[q.question] = q.skipped and NOT_CHOSEN or q.answer
            any = any or not q.skipped
        end
        local name = (group.session or session).name
        if any then
            gitgud.agentAnswer(name, group.requestId, answers)
        else
            gitgud.agentRespond(name, group.requestId, false, NOT_ANSWERED)
        end
        track("working")
    end
    if (item.session or session) == cur.session then
        toEnd()
    end
    agent.layoutSoon()
    paintSessions()
    app.publish("bragi.permissionAnswered", { item = item, by = opts.by or "click" })
end

--- The streaming assistant item, made on demand.
local function streaming()
    local last = items[openTail()]
    if last and last.kind == "assistant" and last.streaming then
        return last
    end
    return addItem({ kind = "assistant", text = "", streaming = true })
end

local function finishSteps(stopped)
    for _, item in ipairs(items) do
        if item.kind == "step" and item.result == nil and not item.stopped then
            item.stopped = stopped
            item.dirty = true
        elseif item.kind == "thinking" and not item.done then
            item.done = true
            item.dirty = true
        elseif waitsOnYou(item) and (stopped or not item.helper) then
            -- A helper's card outlives the turn (a background agent still
            -- waits on it); stopped or gone, Claude Code denied them all.
            item.answer = "Cancelled"
            item.dirty = true
            if item.group then
                item.group.sent = true -- the request ended with the turn
            end
            app.publish("bragi.permissionAnswered", { item = item, by = "cancelled" })
        end
    end
end

--- The thinking still going ends: an answer or the next block started.
local function endThinking()
    for _, it in ipairs(items) do
        if it.kind == "thinking" and not it.done then
            it.done = true
            it.dirty = true
        end
    end
end

local handlers = {}

function handlers.init(e)
    session.id = e.sessionId
    if ctx.keepTitle and (e.sessionId or "") ~= "" then
        -- A fork's title (bragi/rewind.lua), for its saved conversation.
        require("bragi.projects").setTitle(e.sessionId, ctx.keepTitle)
        ctx.keepTitle = nil
    end
    if not ctx.cwd and (e.cwd or "") ~= "" then
        ctx.cwd = e.cwd
        session.cwd = e.cwd
    end
    loaded = e
    loaded.files = gitgud.agentContextFiles(e.cwd or ctx.cwd or require("core.repo").state().path)
    app.publish("bragi.loaded", loaded)
    local source = e.apiKeySource
    if source and source ~= "none" and not warnedKey then
        warnedKey = true
        agent.addMessage("note", "Claude Code is using an API key (" .. tostring(source)
            .. ") instead of your claude.ai sign-in, so connectors, synced skills, and plugins "
            .. "won't load. Run claude and use /login with your subscription.", { error = true })
    end
end

--- What the last session loaded: its init (model, tools, apiKeySource,
-- version, mcpServers, slashCommands, skills, plugins, agents) plus files,
-- the instruction and memory files (gitgud.agentContextFiles). Nil before
-- the first session starts.
function agent.loaded()
    return loaded
end

function handlers.block(e)
    endThinking()
    if e.type == "text" then
        local last = items[openTail()]
        if last and last.kind == "assistant" then
            last.streaming = false
        end
        addItem({ kind = "assistant", text = "", streaming = true })
    elseif e.type == "thinking" then
        addItem({ kind = "thinking", title = "Thinking", icon = "Spark", text = "", done = false })
    end
    agent.layoutSoon()
end

function handlers.text(e)
    local item = streaming()
    item.text = item.text .. (e.text or "")
    item.dirty = true
    agent.layoutSoon()
end

function handlers.thinking(e)
    local last = items[openTail()]
    if last and last.kind == "thinking" and not last.done then
        local blank = not hasThought(last)
        last.text = last.text .. (e.text or "")
        if last.open or (blank and hasThought(last)) then -- its first words: it shows now
            last.dirty = true
            agent.layoutSoon()
        end
    end
end

function handlers.message(e)
    if (e.parent or "") ~= "" then
        return -- a sub-agent's text: its steps show what it did
    end
    -- Compaction sends the messages it keeps again (a command's output
    -- among them): each shows once.
    if (e.uuid or "") ~= "" then
        local key = e.uuid .. "\n" .. tostring(e.text or "")
        session.shown = session.shown or {}
        if session.shown[key] then
            return
        end
        session.shown[key] = true
    end
    local item = nil
    for i = #items, 1, -1 do
        if items[i].kind == "assistant" and items[i].streaming then
            item = items[i]
            break
        end
    end
    local body = e.text or ""
    -- A quick answer went in while this block streamed: what showed before
    -- it stays there, and only the rest goes here.
    for _, it in ipairs(items) do
        if it.cutBlock and it ~= item then
            it.cutBlock = nil
            if body:sub(1, #it.text) == it.text then
                body = body:sub(#it.text + 1)
            end
        end
    end
    if item or text.trim(body) ~= "" then
        item = item or addItem({ kind = "assistant", text = "" })
        item.text = body
        item.streaming = false
        item.dirty = true
    end
    endThinking()
    agent.layoutSoon()
end

function handlers.tool(e)
    local input = type(e.input) == "table" and e.input or {}
    local step = addItem({
        kind = "step",
        id = e.id,
        parent = e.parent,
        title = e.name or "Tool",
        icon = TOOL_ICON[e.name] or "Spark",
        summary = toolSummary(e.name, input),
        inputText = gitgud.jsonEncode(input) or "",
        -- A helper's name, for the cards it shows (helperOf).
        helperTitle = TOOL_ICON[e.name] == "Agent" and (input.description or input.subagent_type) or nil,
    })
    byToolId[e.id or ""] = step
    local last = items[openTail() - 1]
    if last and last.kind == "assistant" then
        last.streaming = false
    end
    if (e.parent or "") == "" and plan.isTool(e.name) then
        -- The conversation's plan (a helper's own isn't).
        local news = plan.news(ctx.plan, e.name, input)
        local changed
        ctx.plan, changed = plan.apply(ctx.plan, e.name, input, e.id)
        if changed then
            planChanged(news)
        end
    end
    agent.layoutSoon()
end

function handlers.toolResult(e)
    local step = byToolId[e.id or ""]
    if step then
        step.result = e.text or ""
        step.error = e.isError == true
        step.images = type(e.images) == "table" and #e.images > 0 and e.images or nil
        step.dirty = true
        agent.layoutSoon()
    end
    if ctx.plan and e.isError ~= true then
        plan.created(ctx.plan, e.id, e.text) -- the id Claude Code gave a new step
    end
end

--- The helper a permission request or question is from: its name, ""
-- for one not known by name, or nil for the conversation's own agent.
-- Claude Code says which helper (agent_id); a helper's name is its task's
-- (task_started), or the Agent call its tool call ran in.
local function helperOf(e)
    if (e.agentId or "") == "" then
        return nil
    end
    local name = session.helpers and session.helpers[e.agentId]
    if not name then
        local step = byToolId[e.toolUseId or ""]
        local call = step and byToolId[step.parent or ""]
        name = call and call.helperTitle
    end
    return name or ""
end

--- Claude's questions: a card for each (see "Claude's questions"). With
-- none to show, it's answered at once, so Claude doesn't wait.
local function askQuestions(e, input)
    local list = {}
    for _, q in ipairs(type(input.questions) == "table" and input.questions or {}) do
        if type(q) == "table" and type(q.question) == "string" then
            local options = {}
            for _, o in ipairs(type(q.options) == "table" and q.options or {}) do
                if type(o) == "table" and o.label ~= nil then
                    options[#options + 1] = { label = tostring(o.label),
                        description = type(o.description) == "string" and o.description or "" }
                end
            end
            list[#list + 1] = { question = q.question, header = type(q.header) == "string" and q.header or "",
                options = options, multi = q.multiSelect == true }
        end
    end
    if #list == 0 then
        gitgud.agentRespond(session.name, e.requestId, false, "There was no question to answer.")
        return
    end
    local group = { requestId = e.requestId, session = session, items = {} }
    e.items = {}
    local helper = helperOf(e)
    for i, q in ipairs(list) do
        q.kind, q.tool, q.requestId, q.session = "question", QUESTION_TOOL, e.requestId, session
        q.helper = helper
        q.group, q.index, q.count, q.picked, q.other = group, i, #list, {}, ""
        group.items[i] = addItem(q)
        e.items[i] = group.items[i]
    end
    agent.layoutSoon()
    track("waiting", "Asks: " .. list[1].question)
end

function handlers.permission(e)
    if (ctx.allowTool and ctx.allowTool(e.tool)) or require("bragi.uitools").noCard(e.tool, session.name) then
        -- One of the conversation's own tools (the master's, bragi/master.lua),
        -- or one of Bragi's that needs no card, asked about anyway.
        gitgud.agentRespond(session.name, e.requestId, true)
        return
    end
    local input = type(e.input) == "table" and e.input or {}
    if e.tool == QUESTION_TOOL then
        return askQuestions(e, input)
    end
    local summary = toolSummary(e.tool, input)
    if input.command then
        summary = input.command
    end
    e.item = addItem({ kind = "permission", requestId = e.requestId, tool = e.tool or "a tool", summary = summary,
        input = input, session = session, helper = helperOf(e), reason = e.reason })
    agent.layoutSoon()
    track("waiting", "Asks to run " .. (e.tool or "a tool"))
end

--- Claude Code took a request back (its helper stopped, or the answer
-- isn't needed now): its cards close.
function handlers.permissionCancelled(e)
    for _, item in ipairs(items) do
        if item.requestId == e.requestId and waitsOnYou(item) then
            item.answer = "Cancelled"
            item.dirty = true
            if item.group then
                item.group.sent = true
            end
            app.publish("bragi.permissionAnswered", { item = item, by = "cancelled" })
        end
    end
    agent.layoutSoon()
    paintSessions()
end

function handlers.result(e)
    if session.turn and not session.takenUp and not e.isError and not e.interrupted
        and (e.text or "") == "" and (tonumber(e.turns) or 0) == 0 then
        -- A result that ran no turn before the message sent was taken up:
        -- not its answer. Claude Code ends a notification it only writes
        -- to the transcript this way (a resumed session's word on a
        -- background command it lost), then answers the message queued
        -- behind it. Taken as done, Bragi's news of it had no reply to
        -- tell: the turn goes on, and the message's own result ends it.
        e.notYet = true
        session.id = e.sessionId or session.id
        setWaiting("Thinking")
        return
    end
    session.takenUp = false
    setTurn(false)
    finishSteps(e.interrupted == true)
    for _, item in ipairs(items) do
        if item.kind == "assistant" then
            item.streaming = false
        end
    end
    session.id = e.sessionId or session.id
    if e.interrupted then
        agent.addMessage("note", "Stopped.")
    elseif e.isError then
        agent.addMessage("note", (e.text and e.text ~= "") and e.text or "The turn ended with an error.",
            { error = true })
    end
    if not e.isError and not e.interrupted then
        app.publish("bragi.reply", { text = e.text or "", voice = session.voiceTurn == true,
            ms = session.turnStarted and (gitgud.now() - session.turnStarted) or nil, tab = ctx })
    end
    session.voiceTurn = false
    -- Between turns it waits for you; the issue hears what it last said.
    local summary = summarise(e.text)
    track(e.isError and not e.interrupted and "failed" or "waiting", summary)
    report(summary)
    agent.layoutSoon()
    gitgud.after(500, function()
        agent.refreshSessions(true)
    end)
end

--- The note where a conversation was compacted (/compact, or Claude Code
-- on its own when the context filled up).
-- @param trigger  "manual" or "auto"
-- @param before   tokens before, or nil
-- @param after    tokens after, or nil
local function compactedText(trigger, before, after)
    local s = trigger == "auto" and "Claude Code compacted the conversation to make room"
        or "Compacted the conversation"
    before, after = tonumber(before), tonumber(after)
    if before and after then
        s = s .. string.format(": %.1fk tokens down to %.1fk", before / 1000, after / 1000)
    end
    return s .. ". Earlier messages stay here; Claude now has a summary of them."
end

function handlers.system(e)
    local raw = type(e.raw) == "table" and e.raw or {}
    if e.subtype == "status" and raw.status == "compacting" then
        setWaiting("Compacting the conversation")
    elseif e.subtype == "task_started" and (raw.task_id or "") ~= "" then
        -- A helper's name, for its cards (helperOf): a background agent's
        -- task id is its agent id.
        local call = byToolId[raw.tool_use_id or ""]
        local name = (raw.description or "") ~= "" and raw.description or (call and call.helperTitle)
        if name then
            session.helpers = session.helpers or {}
            session.helpers[raw.task_id] = name
        end
    elseif e.subtype == "compact_boundary" then
        clearWaiting(ctx)
        local m = type(raw.compact_metadata) == "table" and raw.compact_metadata or {}
        agent.addMessage("note", compactedText(m.trigger, m.pre_tokens, m.post_tokens))
    end
end

function handlers.error(e)
    agent.addMessage("note", e.message or "Claude Code refused that.", { error = true })
end

function handlers.stderr(e)
    stderrTail[#stderrTail + 1] = e.line or ""
    if #stderrTail > 5 then
        table.remove(stderrTail, 1)
    end
end

function handlers.exit(e)
    local wasTurn = session.turn
    session.running = false
    -- The next message resumes the same conversation.
    session.resume = session.id
    setTurn(false)
    finishSteps(true)
    if (e.code or 0) ~= 0 and e.code ~= 137 then
        local why = table.concat(stderrTail, "\n")
        agent.addMessage("note", "Claude Code stopped (exit code " .. tostring(e.code) .. ")"
            .. (why ~= "" and (":\n" .. why) or "."), { error = true })
        track("failed", "Claude Code stopped (exit code " .. tostring(e.code) .. ")")
    elseif wasTurn then
        agent.addMessage("note", "Claude Code stopped.")
    end
end

-- paintSessions: the sessions list (below)

--- Ask for you: a session finished, failed, or wants a permission. The
-- window asks the OS while it isn't in front; a tab in the background is
-- also marked in the sessions list and named in the status line.
-- @param tab   the tab
-- @param what  "permission", "question", "done", or "failed"
-- @param unprompted  the turn that ended was one nobody sent a message for
local function attention(tab, what, unprompted)
    local title = tab.title ~= "" and tab.title or "Session"
    local body = what == "permission" and "Claude needs your permission to go on."
        or what == "question" and "Claude has a question for you."
        or (what == "failed" and "The session stopped with an error." or "Claude finished.")
    if settings.get("bragi.notify", true) then
        gitgud.emit("window.notify", title .. "\n" .. body)
    end
    -- bragi/master.lua follows the conversations it sent something to.
    app.publish("bragi.sessionState", { tab = tab, what = what, unprompted = unprompted or nil })
    if tab ~= cur then
        if what == "done" or what == "failed" then
            tab.unread = what
        end
        require("core.status").info(title .. ": " .. body)
        app.publish("bragi.attention", { title = title, what = what })
    end
    paintSessions()
end

-- Events that show the answer has started.
local FIRST_WORDS = { block = true, text = true, thinking = true, message = true, tool = true, permission = true }

--- A voice turn's step, for the narrator ("bragi.activity"), or nil.
local function activity(kind, e)
    if kind == "block" then
        return e.type == "tool_use" and { kind = "tool", name = e.name or "Tool", starting = true } or nil
    elseif kind == "thinking" or kind == "text" then
        return (e.text or "") ~= "" and { kind = kind, text = e.text } or nil
    elseif kind == "tool" then
        local input = type(e.input) == "table" and e.input or {}
        if plan.isTool(e.name) then
            -- What it changes in the plan (bragi/plan.lua): a new plan is
            -- talked through, an update names only the step it's on.
            return { kind = "tool", name = e.name, summary = toolSummary(e.name, input),
                plan = (e.parent or "") == "" and plan.news(ctx.plan, e.name, input) or nil }
        end
        return { kind = "tool", name = e.name or "Tool", summary = toolSummary(e.name, input),
            description = type(input.description) == "string" and input.description or nil }
    end
    return nil
end

local function onAgentEvent(kind)
    return function(detail)
        local e = gitgud.jsonDecode(detail)
        if type(e) ~= "table" or not e.session then
            return
        end
        local tab = nil
        for _, t in ipairs(tabs) do
            if t.session.name == e.session then
                tab = t
            end
        end
        if not tab then
            return -- another (closed) session's, or not the Agent view's
        end
        use(tab)
        -- Thinking with no words yet shows nothing (draw.thinking): the
        -- waiting row stays.
        local unseen = (kind == "block" and (e.type == "thinking" or e.type == "redacted_thinking"))
            or (kind == "thinking" and text.trim(e.text or "") == "")
        if kind ~= "init" and kind ~= "stderr" and kind ~= "system" and kind ~= "permissionCancelled"
            and not unseen then
            clearWaiting(tab)
            fresh = fresh or tab == cur -- streamed into what's shown
        end
        if FIRST_WORDS[kind] and tab.session.turn and not tab.session.answered then
            -- The first sign of the answer (bragi/voice.lua logs the time).
            tab.session.answered = true
            app.publish("bragi.answering", { voice = tab.session.voiceTurn == true,
                ms = tab.session.turnStarted and (gitgud.now() - tab.session.turnStarted) or nil })
        end
        if tab.session.turn and (FIRST_WORDS[kind] or (kind == "system" and e.subtype == "compact_boundary")) then
            tab.session.takenUp = true -- the message sent is being answered (handlers.result)
        elseif not tab.session.turn and FIRST_WORDS[kind] then
            -- A turn nobody sent a message for: Claude Code answering a
            -- background task's report on its own (bragi/master.lua: never
            -- done news).
            tab.session.unprompted = true
        end
        if FIRST_WORDS[kind] or kind == "result" then
            tab.updated = os.time() -- an answer: the list's order (bragi/sessionlist.lua)
        end
        local step = tab.session.turn and activity(kind, e)
        if step then
            if tab.session.voiceTurn then
                app.publish("bragi.activity", step)
            end
            -- Every conversation's, for Bragi's spoken updates (bragi/updates.lua).
            app.publish("bragi.step", { tab = tab, step = step })
        end
        local ok, err = pcall(handlers[kind], e)
        use(cur)
        if not ok then
            error(err, 0)
        end
        if kind == "permission" and (e.item or e.items) then
            attention(tab, e.items and "question" or "permission")
            -- bragi/voice.lua may ask it aloud (only the shown conversation's).
            for _, item in ipairs(e.items or { e.item }) do
                app.publish("bragi.permission", { item = item, shown = tab == cur })
            end
        elseif kind == "result" and not e.interrupted and not e.notYet then
            local unprompted = tab.session.unprompted
            tab.session.unprompted = nil
            attention(tab, e.isError and "failed" or "done", unprompted)
        elseif kind == "exit" and tab ~= cur then
            paintSessions()
        end
    end
end

-- ===================================================================
-- Sessions list
-- ===================================================================

--- A tab's state for the sessions list: "permission" (needs you),
-- "running", its unread ending ("done", "failed"), or nil.
function agent.tabState(tab)
    for _, item in ipairs(tab.items) do
        if waitsOnYou(item) then
            return "permission"
        end
    end
    if tab.session.turn then
        return "running"
    end
    return tab.unread
end

paintSessions = function()
    local master = nil
    for _, tab in ipairs(tabs) do
        master = master or (tab.master and tab) or nil
    end
    rows = require("bragi.sessionlist").paint({
        tabs = tabs,
        cur = cur,
        master = master,
        masterState = master and agent.tabState(master) or nil,
        tabState = agent.tabState,
        savedKind = agent.savedKind,
        groups = require("bragi.projects").conversations(),
    })
end

--- What a saved session is, by its title: "helper" (the app's own Haiku
-- helpers from before they stopped saving transcripts: their first message
-- is the JSON the app sent), "scheduled" (a scheduled task's run), or nil.
function agent.savedKind(title)
    title = tostring(title or "")
    if title:match('^%s*{%s*"') and (title:find('"message"%s*:') or title:find('"reply"%s*:')
        or title:find('"context"%s*:')) then
        return "helper"
    elseif title:match("^%s*<scheduled%-task") then
        return "scheduled"
    end
    return nil
end

--- The sessions list's rows (for tests; bragi/sessionlist.lua): { master },
-- { header }, { tab }, { saved }, { scheduled = count }, { more = count }.
function agent.sessionRows()
    return rows
end

--- The live tabs (for tests): { {title, session, items, unread} }, oldest
-- first.
function agent.tabs()
    return tabs
end

--- Show a live tab.
function agent.showTab(tab)
    if tab == cur then
        return
    end
    leave()
    show(tab)
    paintSessions()
    gitgud.focus("AgentPromptEdit")
end

--- Read Claude Code's saved conversations again (every project).
-- @param force  read again even when the open repository hasn't changed
function agent.refreshSessions(force)
    local cwd = require("core.repo").state().path
    if not force and cwd == listedFor then
        return
    end
    listedFor = cwd
    require("bragi.projects").conversations(true)
    paintSessions()
end

--- Add a saved conversation (gitgud.agentHistory, its last HISTORY_ENTRIES
-- entries) to the tab the handlers work on: read into plain items first,
-- only the latest SHOWN_AT_FIRST get windows; "Show" draws more.
local function addHistory(history)
    local list, tools = {}, {}
    -- The plan is rebuilt from the calls that made it.
    if ctx.planItem and indexOf(ctx.planItem) then
        gitgud.destroyWindow(ctx.planItem.name)
        table.remove(items, indexOf(ctx.planItem))
    end
    ctx.plan, ctx.planItem = nil, nil
    for _, h in ipairs(history) do
        if h.kind == "user" then
            local pictures = h.images and #h.images > 0 and h.images or nil
            list[#list + 1] = { kind = "user", text = agent.shownText(h.text), images = pictures, sent = true }
        elseif h.kind == "assistant" then
            list[#list + 1] = { kind = "assistant", text = h.text }
        elseif h.kind == "compacted" then
            local m = gitgud.jsonDecode(h.input ~= "" and h.input or "{}") or {}
            list[#list + 1] = { kind = "note", text = compactedText(h.text, m.preTokens, m.postTokens) }
        elseif h.kind == "tool" then
            local input = gitgud.jsonDecode(h.input ~= "" and h.input or "{}") or {}
            local step = { kind = "step", id = h.id, title = h.name, icon = TOOL_ICON[h.name] or "Spark",
                summary = toolSummary(h.name, input), inputText = h.input, stopped = true }
            tools[h.id] = step
            list[#list + 1] = step
            if plan.isTool(h.name) then
                ctx.plan = plan.apply(ctx.plan, h.name, input, h.id)
            end
        elseif h.kind == "toolResult" then
            local step = tools[h.id]
            if step then
                step.result = h.text
                step.error = h.isError
                step.images = h.images and #h.images > 0 and h.images or nil
            end
            if ctx.plan and not h.isError then
                plan.created(ctx.plan, h.id, h.text)
            end
        end
    end
    local cut = math.max(0, #list - SHOWN_AT_FIRST)
    ctx.earlier = { table.unpack(list, 1, cut) }
    ctx.cutOff = #history >= HISTORY_ENTRIES
    if cut > 0 or ctx.cutOff then
        ctx.earlierNote = addItem({ kind = "note", text = "Earlier messages aren't shown.", showsEarlier = true,
            action = cut > 0 and { label = "Show", run = agent.showEarlier } or nil })
    end
    for i = cut + 1, #list do
        local item = addItem(list[i])
        if item.kind == "step" then
            byToolId[item.id] = item
        end
    end
    if ctx.plan and #ctx.plan.steps > 0 then
        ctx.planItem = addItem({ kind = "plan", plan = ctx.plan })
    end
end

--- A saved conversation by id, from the last listing: { id, title,
-- updated, cwd }, or nil.
function agent.savedSession(id)
    for _, p in ipairs(require("bragi.projects").conversations()) do
        for _, s in ipairs(p.sessions) do
            if s.id == id then
                return s
            end
        end
    end
    return nil
end

--- When a saved conversation's last message was: its listing's, or later
-- when a tab here had one since (the listing is read again only now and
-- then).
function agent.activeAt(saved)
    return math.max(saved.active or saved.updated or 0, closedActive[saved.id] or 0)
end

--- A live tab by its session's id (or the id it resumes), or nil.
function agent.tabFor(id)
    for _, tab in ipairs(tabs) do
        if id and (tab.session.id == id or tab.session.resume == id) then
            return tab
        end
    end
    return nil
end

--- Whether a saved conversation is in use outside this app
-- (the master sent into the live desktop session and resumed it
-- in the background): why, or nil. Ours (a tab here) never is. Written to
-- in the last IN_USE_SECONDS (the listing's `updated`), or, unless `quick`,
-- a process running with its id on its command line. Writes from before
-- this app closed it (New session, another conversation) were ours: one
-- left a moment ago isn't in use elsewhere.
agent.IN_USE_SECONDS = 300
local CLOSING_SECONDS = 5 -- a closed session's last writes, after it was closed
local inUseChecked = {} -- id -> { at, why }: process checks, for a while
function agent.inUseElsewhere(id, updated, quick)
    if not id or id == "" or agent.tabFor(id) then
        return nil
    end
    local mine = closedHere[id] and tonumber(updated) and tonumber(updated) <= closedHere[id] + CLOSING_SECONDS
    if not mine and tonumber(updated) and os.time() - tonumber(updated) < agent.IN_USE_SECONDS then
        return "it was written to in the last few minutes"
    end
    if quick or not gitgud.agentSessionProcesses then
        return nil
    end
    local seen = inUseChecked[id]
    if not seen or gitgud.now() - seen.at > 10000 then
        seen = { at = gitgud.now(), why = gitgud.agentSessionProcesses(id) > 0
            and "Claude Code is running it in another window" or nil }
        inUseChecked[id] = seen
    end
    return seen.why
end

--- Put a saved conversation's history in a tab (shown or not): its latest
-- items drawn, earlier ones behind "Show" (addHistory).
-- @param history  optional: gitgud.agentHistory's entries to put there
--                 instead (bragi/rewind.lua's fork, cut where it forks)
local function loadHistory(tab, id, history)
    local before = ctx -- the handlers' tab: the master's, during its tool calls
    use(tab)
    addHistory(history or gitgud.agentHistory(tab.cwd or "", id, HISTORY_ENTRIES))
    use(before or cur)
end

--- Fill a tab with history entries (gitgud.agentHistory's) and lay it out
-- when it's shown (bragi/rewind.lua).
function agent.fillHistory(tab, history)
    loadHistory(tab, nil, history)
    if tab == cur then
        layout()
        scrollToEnd()
    end
end

--- Show a saved session; the next message resumes it. One that's live
-- (running in the background) is just shown.
-- @param opts  optional: cwd (its folder, when the listing doesn't know
--              it), master, title
function agent.resume(id, opts)
    opts = opts or {}
    for _, tab in ipairs(tabs) do
        if tab ~= cur and (tab.session.id == id or tab.session.resume == id) then
            agent.showTab(tab)
            return
        end
    end
    local found = agent.savedSession(id)
    local cwd = opts.cwd or (found and found.cwd ~= "" and found.cwd) or require("core.repo").state().path
    leave()
    local tab = newTab({ cwd = cwd ~= "" and cwd or nil, master = opts.master,
        title = opts.title or (found and found.title) or "Session" })
    tab.updated = found and agent.activeAt(found) or tab.updated
    tab.session.resume = id
    show(tab)
    loadHistory(tab, id)
    layout()
    scrollToEnd()
    paintSessions()
    gitgud.focus("AgentPromptEdit")
end

--- Draw more of a saved session's earlier items, above the ones shown,
-- keeping what's on screen where it is.
function agent.showEarlier()
    local tab = cur
    local note = tab.earlierNote
    local earlier = tab.earlier or {}
    if not note or #earlier == 0 then
        return
    end
    use(tab)
    local anchor = items[2]
    local before = anchor and anchor.top or 0
    local from = math.max(1, #earlier - SHOWN_MORE + 1)
    local added = {}
    for i = from, #earlier do
        local item = addItem(earlier[i])
        if item.kind == "step" then
            byToolId[item.id] = item
        end
        added[#added + 1] = table.remove(items, indexOf(item)) -- moved below the note next
        earlier[i] = nil
    end
    for i, item in ipairs(added) do
        table.insert(items, 1 + i, item)
    end
    if #earlier == 0 then
        if tab.cutOff then
            agent.updateNote(note, "Earlier messages aren't shown.")
        else
            gitgud.destroyWindow(note.name)
            table.remove(items, 1)
            tab.earlierNote = nil
        end
    end
    local scroll = gitgud.getScroll("AgentTranscript")
    -- Added above what you're reading: the view stays on it, and nothing
    -- new came at the end.
    following, fresh = false, false
    layout(true)
    if anchor and anchor.top then
        scrollTo(scroll + anchor.top - before)
    end
    following = atEnd()
end

--- A tab that isn't shown (for bragi/master.lua): a new conversation, or
-- a saved one with its history (the next message resumes it).
-- @param opts  { id = a saved session's id, cwd, title, master }
-- @return the tab
function agent.openTab(opts)
    opts = opts or {}
    local tab = (opts.id and agent.tabFor(opts.id)) or nil
    if tab then
        return tab
    end
    local found = opts.id and agent.savedSession(opts.id) or nil
    local cwd = opts.cwd or (found and found.cwd ~= "" and found.cwd) or nil
    tab = newTab({ cwd = cwd, master = opts.master, title = opts.title or (found and found.title) or nil })
    tab.updated = found and agent.activeAt(found) or tab.updated
    tab.session.resume = opts.id
    tabs[#tabs + 1] = tab
    if opts.id then
        loadHistory(tab, opts.id)
    end
    return tab
end

--- Send a message to a conversation without showing it (or leaving what's
-- typed in the prompt box): its session starts (or resumes) when needed.
-- The quick answers waiting to ride along with its next message go too.
-- @param opts  optional: title (a new one's), voice (it was spoken: the
--              reply is spoken too), context (as agent.send's)
-- @return true, or nil and why not
function agent.sendTo(tab, body, opts)
    opts = opts or {}
    body = text.trim(body or "")
    if body == "" then
        return nil, "Nothing to send."
    end
    local before = ctx -- the handlers' tab: the master's, during its tool calls
    use(tab)
    if #items == 0 and (tab.title == "New session" or tab.title == "") then
        tab.title = opts.title or body:match("^[^\n]*"):sub(1, 80)
    end
    local mine = addItem({ kind = "user", text = body })
    tab.updated = os.time()
    local ok, err = true, nil
    if not session.running then
        ok = startSession()
        err = not ok and "Claude Code didn't start." or nil
    end
    local notes = nil
    if ok then
        notes = not body:match("^/") and quickNoteText(tab) or nil
        local sent = agent.withContext(body, opts.context)
        ok, err = gitgud.agentSend(session.name, notes and (sent .. "\n\n" .. notes) or sent)
    end
    if ok then
        mine.sent = true
        if notes then
            tab.quickNotes = nil
        end
        session.warm = nil
        session.voiceTurn = opts.voice == true
        session.turnStarted = gitgud.now()
        session.answered = false
        session.takenUp = false
        session.unprompted = nil
        setTurn(true)
        setWaiting("Thinking")
    end
    use(before or cur)
    if tab == cur then
        gitgud.setText("AgentTitle", text.escape(cur.title))
        layout()
        if opts.voice then
            toEnd() -- you said it
        end
        paintPrimary()
    end
    paintSessions()
    return ok and true or nil, err
end

--- Add a quiet note to a conversation, shown or not.
-- @param opts  as agent.addMessage's
function agent.noteIn(tab, body, opts)
    local before = ctx
    use(tab)
    local item = addItem({ kind = "note", text = body or "", error = opts and opts.error,
        action = opts and opts.action })
    use(before or cur)
    if tab == cur then
        layout()
    end
    return item
end

--- A new conversation; a busy one goes on in the background.
-- @param opts  optional: cwd (its folder; default: the open repository's
--              when it first sends), master, title
function agent.newSession(opts)
    opts = type(opts) == "table" and opts or {}
    leave()
    show(newTab({ cwd = opts.cwd, master = opts.master, title = opts.title }))
    paintSessions()
    gitgud.focus("AgentPromptEdit")
end

--- New session (the button, Ctrl+N). With no repository open there's no
-- folder to start in: Bragi, the master conversation, is where to start
-- (it finds or clones the project).
function agent.newFromButton()
    if require("core.repo").state().path == "" then
        require("bragi.master").open()
        return
    end
    agent.newSession()
end

--- Start a new session on an issue: it's told the issue, and the server
-- follows its progress.
-- @param task  { repo = "owner/name", number, title, body }
function agent.workOn(task)
    agent.newSession()
    session.task = { repo = task.repo, number = task.number, title = task.title or "" }
    shell.show("agent")
    local own = require("bragi.boards").serverRepo()
    if own ~= task.repo then
        local here = require("core.repo").state().name
        agent.addMessage("note", "Claude Code works in " .. (here ~= "" and here or "no repository")
            .. ", not " .. task.repo .. ". Open that repository in the Repo view to work on it there.")
    end
    local ask = "Work on issue #" .. task.number .. " of " .. task.repo .. ": " .. (task.title or "")
    if task.body and text.trim(task.body) ~= "" then
        ask = ask .. "\n\n" .. task.body
    end
    agent.send(ask)
    cur.title = "#" .. task.number .. "  " .. (task.title or "")
    gitgud.setText("AgentTitle", text.escape(cur.title))
    paintSessions()
end

-- ===================================================================
-- The rest of the view
-- ===================================================================

--- The level meter: LEVEL_BARS bars, flat while voice is off.
-- @param levels  optional list of 0..1 values (one per bar)
local function paintLevel(levels)
    for i = 1, LEVEL_BARS do
        local h = math.max(2, math.floor(((levels and levels[i]) or 0) * 22 + 0.5))
        local bar = "AgentLevelBar" .. i
        gitgud.setProperty(bar, "Area", geometry.rect((i - 1) * 5, math.floor((24 - h) / 2), 3, h))
    end
end

--- Show which repository and branch the agent works on.
-- @param state  repository snapshot
local function showFolder(state)
    local projects = require("bragi.projects")
    if cur.master then
        gitgud.setText("AgentFolderLabel", "[font='Bragi-13'][colour='" .. C.sub .. "']Every project")
        gitgud.setProperty("AgentFolderButton", "TooltipText", "Bragi works across your projects")
        gitgud.setText("AgentEmptyHint", "Talk or type. Say what you want done and where: Bragi finds the "
            .. "project and the conversation, or starts one.")
        return
    end
    if cur.cwd and projects.key(cur.cwd) ~= projects.key(state.path) then
        -- Its own folder, not (yet) the open repository.
        gitgud.setText("AgentFolderLabel", "[font='Bragi-Mono-13'][colour='" .. C.text .. "']"
            .. text.escape(projects.name(cur.cwd)))
        gitgud.setProperty("AgentFolderButton", "TooltipText", "The agent works in " .. cur.cwd)
        gitgud.setText("AgentEmptyHint", text.escape("Talk or type. Claude Code works in "
            .. projects.name(cur.cwd) .. "."))
        return
    end
    if state.open then
        local branch = state.branch ~= "" and state.branch or "detached"
        local function mono(s)
            return "[font='Bragi-Mono-13'][colour='" .. C.text .. "']" .. text.escape(s)
        end
        gitgud.setText("AgentFolderLabel", mono(state.name)
            .. "[font='Bragi-13'][colour='" .. C.sub .. "']  on  " .. mono(branch))
        gitgud.setProperty("AgentFolderButton", "TooltipText", "The agent works in " .. state.path)
        gitgud.setText("AgentEmptyHint",
            text.escape("Talk or type. Claude Code works in " .. state.name .. "."))
    else
        gitgud.setText("AgentFolderLabel", text.colour(C.sub, "No repository"))
        gitgud.setProperty("AgentFolderButton", "TooltipText", "Open a repository in the Repo view")
        gitgud.setText("AgentEmptyHint", "Open a repository to give the agent somewhere to work.")
    end
end

--- Show the folder of the conversation shown.
function agent.refreshFolder()
    showFolder(require("core.repo").state())
end

--- The speaker button beside the mic: Bragi's voice on or muted.
paintMute = function()
    local muted = settings.get("bragi.mute", false) == true
    gitgud.setProperty("AgentMuteIcon", "IconImage", muted and "Bragi-Icons/SpeakerOff" or "Bragi-Icons/Speaker")
    gitgud.setProperty("AgentMuteIcon", "IconColour", muted and C.err or C.sub)
    gitgud.setProperty("AgentMuteButton", "TooltipText", muted and "Bragi is muted: click to unmute"
        or "Mute Bragi")
end

--- Show voice's state under the prompt box (bragi/voice.lua).
-- @param line  the status line
-- @param on    listening: the mic stays lit and the level meter shows
function agent.voiceStatus(line, on)
    voiceOn = on == true
    gitgud.setText("AgentVoiceState", text.escape(line))
    gitgud.setVisible("AgentLevel", voiceOn)
    gitgud.setProperty("AgentVoiceState", "Area",
        voiceOn and "{{0,152},{1,-58},{1,-352},{1,-14}}" or "{{0,106},{1,-58},{1,-352},{1,-14}}")
    if not voiceOn then
        paintLevel(nil)
    end
    paintPrimary()
end

--- Move the level meter.
-- @param levels  a list of 0..1 values, or nil for flat
function agent.voiceLevel(levels)
    paintLevel(levels)
end

--- Replace what's in the prompt box (a message being heard).
function agent.setPrompt(body)
    body = body or ""
    placeholder.setText("AgentPromptEdit", body)
    -- The caret follows the words as they arrive (and scrolls them into view).
    gitgud.setProperty("AgentPromptEdit", "CaretIndex", tostring(utf8.len(body) or #body))
    paintPrimary()
end

-- What voice last put in the prompt box (agent.setHeard). The box is
-- voice's to change only while it still shows that, or nothing: text you
-- typed, or changed in what was heard, is never replaced or cleared by a
-- wake, a partial, or the end of a message (typed text
-- vanished; a false wake, Bragi hearing itself, or a cancel cleared it).
local heardShown = ""

--- Whether the prompt box holds text you typed (not what voice wrote).
function agent.typedPrompt()
    local now = gitgud.getText("AgentPromptEdit") or ""
    return now ~= "" and now ~= heardShown
end

--- Show what voice hears in the prompt box, unless you typed there.
-- Returns whether it was shown.
function agent.setHeard(body)
    body = body or ""
    if agent.typedPrompt() then
        return false
    end
    heardShown = body
    agent.setPrompt(body)
    return true
end

--- Send, or end the message being heard. Typed text goes as typed, even
-- while voice hears something (ending that sent the heard words instead,
-- and cleared what you typed).
local function sendOrEnd()
    local voice = require("bragi.voice")
    if voice.hearing() and not agent.typedPrompt() then
        voice.sendNow()
    else
        agent.submit()
    end
end

-- ===================================================================
-- Hot-reload
-- ===================================================================
--
-- A change to the scripts, layouts, or prompts reloads the UI while the
-- app runs (main.cpp's watcher), and the sessions carry on in C++
-- through it. Before the reload ("app.reloading") the tabs are kept
-- (gitgud.keepForReload): each item's own fields, without its widgets or
-- links to other tables, and each tab's session. The reloaded view builds
-- them again, shows the same one, and goes on with their sessions' events:
-- a turn in progress keeps streaming into it, and waiting cards can still
-- be answered. A spoken message the filter hadn't checked yet waits in the
-- prompt box. When nothing was kept (the old scripts had failed), each
-- running main session gets a tab from its transcript and its waiting
-- permission requests (gitgud.agentList).

local KEPT = "bragi.agent"
-- An item's fields that belong to its widgets, or link other tables.
local NOT_KEPT = { name = true, inner = true, pics = true, gen = true, made = true, actionMade = true, height = true,
    drawnWidth = true, dirty = true, session = true, group = true, pending = true, action = true,
    -- what layout() and draw.assistant keep about the widgets they made
    mdInner = true, md = true, extra = true, extraGen = true, area = true, culled = true, top = true,
    guess = true, estimate = true, texts = true, hovered = true }

local function keptItem(item)
    local out = {}
    for k, v in pairs(item) do
        local kind = type(v)
        if type(k) == "string" and not NOT_KEPT[k] then
            if kind == "string" or kind == "number" or kind == "boolean" then
                out[k] = v
            elseif kind == "table" and gitgud.jsonEncode(v) then
                out[k] = v
            end
        end
    end
    out.heard = item.pending ~= nil or nil -- spoken, not checked yet
    out.estimate = item.height or item.estimate -- its height, until it's drawn again
    out.groupSent = item.group and item.group.sent == true or nil
    return out
end

--- Keep the tabs for the reloaded view.
local function keep()
    local list, current = {}, 1
    for i, tab in ipairs(tabs) do
        if tab == cur then
            current = i
        end
        local t = { title = tab.title, unread = tab.unread, session = tab.session, stderrTail = tab.stderrTail,
            quickNotes = tab.quickNotes, earlier = tab.earlier, cutOff = tab.cutOff, items = {},
            -- Its own folder, and what the master conversation set (its
            -- allowTool is set again by bragi/master.lua).
            cwd = tab.cwd, master = tab.master, sessionName = tab.sessionName, extraPrompt = tab.extraPrompt,
            startOptions = tab.startOptions, updated = tab.updated, bragiFollows = tab.bragiFollows,
            lastStatus = tab.lastStatus, ref = tab.ref, keepTitle = tab.keepTitle }
        for _, item in ipairs(tab.items) do
            t.items[#t.items + 1] = keptItem(item)
        end
        list[#list + 1] = t
    end
    local json = gitgud.jsonEncode({ tabs = list, current = current, sessionCount = sessionCount,
        sidebarOpen = sidebarOpen, warnedKey = warnedKey, loaded = loaded,
        prompt = gitgud.getText("AgentPromptEdit") or "" })
    if json then
        gitgud.keepForReload(KEPT, json)
    end
end

--- Build a kept tab again (in the background: show() shows it).
-- @return the tab, and the text of a spoken message not checked yet
local function keptTab(t)
    local tab = newTab()
    tab.title = type(t.title) == "string" and t.title or tab.title
    tab.unread = t.unread
    tab.quickNotes = type(t.quickNotes) == "table" and t.quickNotes or nil
    tab.stderrTail = type(t.stderrTail) == "table" and t.stderrTail or {}
    tab.earlier = type(t.earlier) == "table" and t.earlier or nil
    tab.cutOff = t.cutOff
    for _, k in ipairs({ "cwd", "sessionName", "extraPrompt", "updated", "lastStatus", "ref", "keepTitle" }) do
        if type(t[k]) == "string" or type(t[k]) == "number" then
            tab[k] = t[k]
        end
    end
    tab.startOptions = type(t.startOptions) == "table" and t.startOptions or nil
    tab.bragiFollows = t.bragiFollows == true or nil
    for k, v in pairs(type(t.session) == "table" and t.session or {}) do
        tab.session[k] = v
    end
    if t.master then
        require("bragi.master").configure(tab)
    end
    tabs[#tabs + 1] = tab
    use(tab)
    -- Its session ended without the app knowing (it can't, short of a
    -- restart): the next message starts it again.
    if tab.session.name and not gitgud.agentInfo(tab.session.name) then
        tab.session.running, tab.session.turn = false, false
        tab.session.resume = tab.session.id or tab.session.resume
    end
    local heard = nil
    local groups = {}
    for _, item in ipairs(type(t.items) == "table" and t.items or {}) do
        if item.heard then
            heard = item.text
        elseif item.kind == "waiting" then
            if tab.session.turn and not heard then
                tab.waiting = addItem(item)
            end
        elseif draw[item.kind] then
            item.heard = nil
            if item.kind == "permission" then
                item.session = tab.session
            elseif item.kind == "question" then
                local g = groups[item.requestId or ""]
                if not g then
                    g = { requestId = item.requestId, session = tab.session, items = {}, sent = item.groupSent }
                    groups[item.requestId or ""] = g
                end
                g.items[#g.items + 1] = item
                item.group, item.session, item.groupSent = g, tab.session, nil
            elseif item.kind == "step" and item.id then
                byToolId[item.id] = item
            elseif item.kind == "plan" then
                item.plan = type(item.plan) == "table" and item.plan or {}
                item.plan.steps = type(item.plan.steps) == "table" and item.plan.steps or {}
                item.plan.byTool = {}
                item.rows = nil
                tab.plan, tab.planItem = item.plan, item
            elseif item.showsEarlier then
                tab.earlierNote = item
                item.action = tab.earlier and #tab.earlier > 0 and { label = "Show", run = agent.showEarlier } or nil
            end
            addItem(item)
        end
    end
    if heard then
        clearWaiting(tab)
    end
    return tab, heard
end

--- A tab for each running main session no tab has (nothing was kept, or
-- it started after): its transcript so far and its waiting requests.
local function adoptLive()
    local known = {}
    for _, tab in ipairs(tabs) do
        if tab.session.name then
            known[tab.session.name] = true
        end
    end
    local masterName = require("bragi.master").SESSION
    for _, info in ipairs(gitgud.agentList()) do
        local n = tonumber(info.name:match("^bragi(%d+)$"))
        if n then
            sessionCount = math.max(sessionCount, n)
        end
        local isMaster = info.name == masterName
        if (n or isMaster) and info.running and not known[info.name] then
            -- In its own folder (the master's too).
            local tab = newTab({ cwd = info.options.cwd ~= "" and info.options.cwd or nil })
            if isMaster then
                require("bragi.master").configure(tab)
            end
            tabs[#tabs + 1] = tab
            use(tab)
            local s = tab.session
            s.name, s.running, s.turn = info.name, true, info.turnActive == true
            s.id = info.sessionId ~= "" and info.sessionId or (info.options.resume ~= "" and info.options.resume or nil)
            local cwd = info.options.cwd ~= "" and info.options.cwd or require("core.repo").state().path
            if s.id and cwd ~= "" then
                addHistory(gitgud.agentHistory(cwd, s.id, HISTORY_ENTRIES))
            end
            local saved = s.id and agent.savedSession(s.id)
            tab.updated = saved and agent.activeAt(saved) or tab.updated
            -- Titled by the first thing asked, past what was put in front of it.
            for _, item in ipairs(tab.items) do
                local title = item.kind == "user" and not isMaster and gitgud.agentTitle(item.text or "") or ""
                if title ~= "" then
                    tab.title = title
                    break
                end
            end
            for _, p in ipairs(info.pending) do
                handlers.permission({ requestId = p.requestId, tool = p.tool, input = gitgud.jsonDecode(p.input) or {} })
            end
        end
    end
end

--- Take up what the view had before a hot-reload, and the sessions still
-- running. Nothing happens on a normal start.
local function restore()
    local state = gitgud.jsonDecode(gitgud.takeKept(KEPT) or "")
    local live = false
    for _, info in ipairs(gitgud.agentList()) do
        live = live or (info.running and (info.name:match("^bragi%d+$") ~= nil
            or info.name == require("bragi.master").SESSION))
    end
    if type(state) ~= "table" and not live then
        return
    end
    local fresh = cur
    tabs = {}
    local shown, heard, heardTab = nil, nil, nil
    if type(state) == "table" then
        sessionCount = tonumber(state.sessionCount) or sessionCount
        sidebarOpen = state.sidebarOpen ~= false
        warnedKey = state.warnedKey == true
        loaded = type(state.loaded) == "table" and state.loaded or loaded
        for i, t in ipairs(type(state.tabs) == "table" and state.tabs or {}) do
            local ok, tab, said = pcall(keptTab, t)
            if ok then
                if said then
                    heard, heardTab = said, tab
                end
                if i == state.current then
                    shown = tab
                end
            else
                print("[agent] a conversation didn't come back after the reload: " .. tostring(tab))
            end
        end
    end
    adoptLive()
    use(fresh)
    if #tabs == 0 then
        tabs[1] = fresh
        shown = fresh
    end
    shown = shown or tabs[#tabs]
    -- A message still being filtered at the reload is sent as heard to its
    -- own conversation, never held in the prompt box
    -- (nothing heard is dropped or held).
    if heard and heardTab then
        show(heardTab)
        agent.send(heard, { voice = true })
    end
    show(shown)
    relayout()
    paintSessions()
    local prompt = type(state) == "table" and type(state.prompt) == "string" and state.prompt or ""
    if prompt ~= "" then
        agent.setPrompt(prompt)
    end
end

function agent.init()
    gitgud.setText("AgentPromptPlaceholder", "Ask anything, or say \u{201C}Bragi\u{201D}")
    placeholder.bind("AgentPromptEdit", "AgentPromptPlaceholder")
    gitgud.setList("AgentSessionList", {})
    gitgud.setText("AgentVoiceState", "Voice is off")
    showChoices()

    for i = 1, LEVEL_BARS do
        local bar = "AgentLevelBar" .. i
        if gitgud.createWindow("Gitgud/StaticText", bar, "AgentLevel") then
            gitgud.setProperty(bar, "PanelColour", C.sub)
            gitgud.setProperty(bar, "CursorPassThroughEnabled", "true")
            gitgud.setText(bar, "")
        end
    end
    paintLevel(nil)
    -- No level to show while voice is off: the status line takes its place.
    gitgud.setVisible("AgentLevel", false)
    agent.loadModes()
    gitgud.setProperty("AgentVoiceState", "Area", "{{0,106},{1,-58},{1,-352},{1,-14}}")
    paintMute()

    if not gitgud.getRect(JUMP) then
        require("bragi.ui").button(JUMP, "AgentMain", { 0, 0, JUMP_W, JUMP_H }, JUMP_LABEL,
            { primary = true, radius = 16 })
        gitgud.setProperty(JUMP, "AlwaysOnTop", "true")
        gitgud.on(JUMP .. ".clicked", toEnd)
    end
    hideJump()
    gitgud.watchScroll("AgentTranscript")
    gitgud.on("AgentTranscript.scrolled", onScrolled)
    textselect.attach("AgentTranscript", { segments = selectable, menu = messageMenu,
        drawAll = function()
            layout(true)
        end })

    for _, kind in ipairs({ "init", "block", "text", "thinking", "message", "tool", "toolResult",
        "permission", "permissionCancelled", "result", "system", "error", "stderr", "exit" }) do
        gitgud.on("agent." .. kind, onAgentEvent(kind))
    end

    gitgud.on("AgentPromptEdit.changed", function(value)
        paintPrimary()
        suggestSlash(value)
    end)
    gitgud.on("AgentSendButton.clicked", function()
        if session.turn and text.trim(gitgud.getText("AgentPromptEdit") or "") == ""
            and #(cur.attachments or {}) == 0 then
            agent.stop()
        else
            sendOrEnd()
        end
    end)
    -- Enter in the prompt box (Shift+Enter breaks the line instead).
    gitgud.on("AgentPromptEdit.accepted", sendOrEnd)
    gitgud.on("AgentNewButton.clicked", agent.newFromButton)
    local sessionlist = require("bragi.sessionlist")
    gitgud.on("AgentSessionList.selected", function(value)
        local row = rows[(tonumber(value) or -1) + 1]
        if row and row.master then
            require("bragi.master").open()
        elseif row and row.header then
            -- Its click opens or closes it (below); the selection stays.
            gitgud.selectListItem("AgentSessionList", sessionlist.selected, false)
        elseif row and row.more then
            sessionlist.showMore(row.group.key)
            paintSessions()
        elseif row and row.scheduled then
            sessionlist.toggleScheduled(row.group.key)
            paintSessions()
        elseif row and row.tab then
            agent.showTab(row.tab)
        elseif row and row.saved and row.saved.id ~= session.id then
            agent.resume(row.saved.id, { cwd = (row.saved.cwd or "") ~= "" and row.saved.cwd or nil })
        end
    end)
    -- A project's header: the + starts a conversation there, elsewhere it
    -- opens or closes.
    gitgud.on("AgentSessionList.clicked", function(value)
        local x, _, index = tostring(value or ""):match("^(-?%d+),(-?%d+),(-?%d+)$")
        local row = rows[(tonumber(index) or -1) + 1]
        if not (row and row.header) then
            return
        end
        if sessionlist.plusHit(x) and (row.header.cwd or "") ~= "" then
            agent.newSession({ cwd = row.header.cwd })
        else
            sessionlist.setOpen(row.header.key, not sessionlist.isOpen(row.header))
            paintSessions()
        end
    end)
    gitgud.on("AgentSessionList.rightClicked", function(value)
        local x, y, index = tostring(value or ""):match("^(-?%d+),(-?%d+),(-?%d+)$")
        local row = rows[(tonumber(index) or -1) + 1]
        local group = row and row.group
        if not group or (group.cwd or "") == "" then
            return
        end
        menu.popup({
            { label = "New conversation in " .. group.name, action = function()
                agent.newSession({ cwd = group.cwd })
            end },
            { label = "Open in the Repo view", action = function()
                if require("bragi.projects").isRepo(group.cwd) then
                    gitgud.openRepo(group.cwd)
                end
                shell.show("repo")
            end },
        }, tonumber(x) or 0, tonumber(y) or 0)
    end)
    gitgud.on("AgentSidebarButton.clicked", function()
        sidebarOpen = not sidebarOpen
        relayout()
    end)
    gitgud.on("AgentFolderButton.clicked", function()
        shell.show("repo")
    end)
    gitgud.on("AgentSearch.clicked", commands.open)
    gitgud.on("AgentMicButton.clicked", function()
        require("bragi.voice").toggle()
    end)
    gitgud.on("AgentMuteButton.clicked", function()
        local voice = require("bragi.voice")
        voice.setMuted(not voice.muted())
    end)
    app.subscribe("bragi.muted", function()
        paintMute()
    end)
    gitgud.on("AgentModelButton.clicked", function()
        agent.pickChoice("AgentModelButton", agent.MODELS, "bragi.model", "opus")
    end)
    gitgud.on("AgentModeButton.clicked", function()
        agent.pickChoice("AgentModeButton", agent.MODES, "bragi.mode", "default")
    end)

    shell.bind("ctrl+enter", sendOrEnd)
    shell.bind("ctrl+n", agent.newFromButton)
    shell.bind("ctrl+b", function()
        sidebarOpen = not sidebarOpen
        relayout()
    end)
    shell.bind("escape", agent.stop)
    -- Pictures for the next message: pasted, or dropped on the window.
    shell.bind("ctrl+v", agent.pasteImage)
    -- The transcript's selection; an editbox with the focus copies its own.
    shell.bind("ctrl+c", function()
        if not gitgud.textInputFocused() then
            textselect.copy()
        end
    end)
    gitgud.on("app.fileDropped", function(path)
        if shell.view() == "agent" and type(path) == "string" and path ~= "" then
            agent.dropped(path)
        end
    end)

    app.subscribe("bragi.choices", showChoices)
    app.subscribe("bragi.view", function(view)
        if view == "agent" then
            relayout()
            agent.refreshSessions(true)
            gitgud.focus("AgentPromptEdit")
        end
    end)
    gitgud.on("window.resized", relayout)
    gitgud.on("app.reloading", keep)

    -- The conversation list's right edge drags (its width is remembered).
    sidebarSplit = require("ui.splitter").column({
        name = "AgentSidebarSplit", parent = "AgentRoot", pane = "AgentSidebar", edge = "left",
        key = "bragi.sidebarWidth", default = SIDEBAR, min = SIDEBAR_MIN,
        max = function()
            -- Widening it never pushes the session panel off.
            local _, _, w = gitgud.getRect("AgentRoot")
            local rest = panelShown > 0 and panelShown + require("bragi.sidepanel").MIN_MAIN or SIDEBAR_ROOM
            return math.min(SIDEBAR_MAX, (w or 1200) - rest)
        end,
        relayout = relayout,
        done = function()
            paintSessions()
        end,
    })

    paintPrimary()
    relayout()
    local ok, err = pcall(restore)
    if not ok then
        print("[agent] the conversations didn't come back after the reload: " .. tostring(err))
    end
end

function agent.refresh(state)
    showFolder(state)
    agent.refreshSessions(false)
end

return agent
