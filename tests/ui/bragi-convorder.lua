--- tests/ui/bragi-convorder.lua: the Agent view's conversations list keeps
-- its order by each conversation's last message (bragi/sessionlist.lua),
-- and titles skip what was put in front of the first message
-- (the open conversation popped to the top of its project, and
-- one was titled "<system-reminder>").
--
--   - saved conversations list by their last message, not when their file
--     was last written (Claude Code adds lines to one that's opened)
--   - opening one, or another, doesn't move it
--   - a new message, and its answer, moves it to the top
--   - a title skips system reminders and task notifications, and takes
--     Claude Code's own title when there is one
--
-- Run it like bragi-projects.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, and a scratch CLAUDE_CONFIG_DIR).
-- Prints "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
local config = os.getenv("CLAUDE_CONFIG_DIR")
if gitgud.currentUi().id ~= "bragi" or not fake or not config then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local projects = require("bragi.projects")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local here = repo.state().path:gsub("[/\\]+$", "")
local OLD = "4444dddd-0000-0000-0000-000000000004"     -- messages 4 hours ago, begun by injected text
local OPENED = "1111aaaa-0000-0000-0000-000000000001"  -- 3 hours ago, written to since (opened elsewhere)
local MIDDLE = "2222bbbb-0000-0000-0000-000000000002"  -- 2 hours ago
local NEWEST = "3333cccc-0000-0000-0000-000000000003"  -- 1 hour ago
local SCHEDULED = "5555eeee-0000-0000-0000-000000000005" -- a scheduled run Claude Code titled

local function stamp(secondsAgo)
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() - secondsAgo)
end

local function writeSaved(id, lines)
    local dir = config .. "/projects/" .. here:gsub("[^%w]", "-")
    gitgud.makeDir(dir)
    local f = assert(io.open(dir .. "/" .. id .. ".jsonl", "wb"))
    for _, line in ipairs(lines) do
        f:write(gitgud.jsonEncode(line), "\n")
    end
    f:close()
end

local function ask(ago, content)
    return { type = "user", cwd = here, timestamp = stamp(ago), message = { role = "user", content = content } }
end
local function answer(ago, words)
    return { type = "assistant", cwd = here, timestamp = stamp(ago),
        message = { role = "assistant", content = { { type = "text", text = words } } } }
end

local known = {} -- a live tab -> the saved conversation it is

--- The conversations under this project's header, in order: a saved
-- one's id, a live tab's (known, else the one it resumes, else the tab).
local function order()
    local list, inside = {}, false
    for _, row in ipairs(agent.sessionRows()) do
        if row.header then
            inside = projects.key(row.header.cwd or "") == projects.key(here)
        elseif inside and row.saved then
            list[#list + 1] = row.saved.id
        elseif inside and row.tab then
            list[#list + 1] = known[row.tab] or row.tab.session.resume or row.tab
        end
    end
    return list
end
local function same(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end
local function describe(list)
    local out = {}
    for i, v in ipairs(list) do
        out[i] = type(v) == "string" and v:sub(1, 4) or "tab"
    end
    return table.concat(out, " ")
end
--- The 0-based list index of a conversation's row.
local function rowOf(id)
    for i, row in ipairs(agent.sessionRows()) do
        if (row.saved and row.saved.id == id) or (row.tab and (known[row.tab] or row.tab.session.resume) == id) then
            return i - 1, row
        end
    end
    return nil
end
local function titleOf(id)
    local _, row = rowOf(id)
    return row and (row.saved and row.saved.title or row.tab and row.tab.title) or nil
end
local function shot(name)
    gitgud.screenshot(OUT .. "/convorder-" .. name .. ".png")
end
local function open(id)
    gitgud.emit("AgentSessionList.selected", tostring(rowOf(id)))
end

local START = { NEWEST, MIDDLE, OPENED, OLD }

step(1500, "four saved conversations", function()
    writeSaved(OLD, {
        ask(4 * 3600, "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"),
        ask(4 * 3600 - 5, { { type = "text", text = "<system-reminder>\nLinked sessions now\n</system-reminder>\n\n"
            .. "Why does the list jump around?" } }),
        answer(4 * 3600 - 60, "It sorts open ones first."),
    })
    writeSaved(MIDDLE, { ask(2 * 3600, "Tidy the README"), answer(2 * 3600 - 60, "Tidied.") })
    writeSaved(NEWEST, { ask(3600, "Fix the loot table"), answer(3600 - 60, "Fixed.") })
    -- Written last, but its last message is older: Claude Code added its
    -- title and last prompt when it was opened.
    writeSaved(OPENED, {
        ask(3 * 3600, "<system-reminder>x</system-reminder>Background (from the session that started this one)"),
        answer(3 * 3600 - 60, "Started."),
        { type = "custom-title", customTitle = "Pinned plan under the latest message", sessionId = OPENED },
        { type = "last-prompt", leafUuid = "u", sessionId = OPENED },
    })
    writeSaved(SCHEDULED, {
        ask(30 * 60, '<scheduled-task name="nightly">\nCheck the build.\n</scheduled-task>'),
        answer(30 * 60 - 60, "Checked."),
        { type = "custom-title", customTitle = "Nightly: check the build", sessionId = SCHEDULED },
    })
    shell.show("agent")
    agent.refreshSessions(true)
end)

step(600, "listed by their last message", function()
    local now = order()
    check("newest message first, not newest file (" .. describe(now) .. ")", same(now, START))
    check("a title skips the injected start", titleOf(OLD) == "Why does the list jump around?")
    check("Claude Code's title is used", titleOf(OPENED) == "Pinned plan under the latest message")
    local scheduled = nil
    for _, row in ipairs(agent.sessionRows()) do
        scheduled = scheduled or (row.scheduled and row.group and projects.key(row.group.cwd or "") == projects.key(here)
            and row.scheduled) or nil
    end
    check("a scheduled run with a title of Claude Code's is still one", scheduled == 1)
    shot("01-listed")
    open(OPENED)
end)

step(800, "opening one doesn't move it", function()
    local cur = agent.current()
    check("it's shown", cur.session.resume == OPENED)
    known[cur] = OPENED
    local now = order()
    check("still third (" .. describe(now) .. ")", same(now, START))
    local _, row = rowOf(OPENED)
    check("listed as the open conversation", row ~= nil and row.tab == cur)
    check("its title stays", cur.title == "Pinned plan under the latest message")
    shot("02-opened")
    open(OLD)
end)

step(800, "opening another doesn't move either", function()
    check("the old one is shown", agent.current().session.resume == OLD)
    local now = order()
    check("the order is the same (" .. describe(now) .. ")", same(now, START))
    check("the shown one's title skips the injected start", agent.current().title == "Why does the list jump around?")
    open(OPENED)
end)

step(800, "back to the first", function()
    check("shown again", agent.current().session.resume == OPENED)
    local now = order()
    check("the order is still the same (" .. describe(now) .. ")", same(now, START))
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText("hello")
    gitgud.simulateKey("enter")
end)

step(2500, "a new message moves it to the top", function()
    local now = order()
    check("it's first now (" .. describe(now) .. ")", same(now, { OPENED, NEWEST, MIDDLE, OLD }))
    shot("03-sent")
    open(OLD)
end)

step(800, "and opening another still doesn't", function()
    local now = order()
    check("the old one stays last (" .. describe(now) .. ")", same(now, { OPENED, NEWEST, MIDDLE, OLD }))
end)

step(300, "done", function()
    print("[ui-test] done")
    gitgud.emit("window.close", "")
end)

harness.run()
