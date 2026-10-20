--- tests/ui/bragi-projects.lua: the Agent view's conversations grouped by
-- project (bragi/sessionlist.lua, bragi/projects.lua): Bragi pinned on top,
-- a header per project ordered by activity, collapsing remembered, the +
-- starting a conversation in that project, each conversation keeping its
-- own folder (resume, send, history), the open repository following the
-- conversation shown, and UI tool calls naming their session.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, and a scratch CLAUDE_CONFIG_DIR,
-- where saved conversations of two projects are written). Prints
-- "[check] ...".

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

local function shot(name)
    gitgud.screenshot(OUT .. "/projects-" .. name .. ".png")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function lastOf(items, kind)
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
local function same(a, b)
    return projects.key(a or "") == projects.key(b or "")
end

-- Two projects: the open repository, and "other" next to it (a repository
-- of its own), each with a saved conversation that names its folder.
local here = repo.state().path:gsub("[/\\]+$", "")
local other = here:gsub("[/\\][^/\\]+$", "") .. "/other"
local HERE_ID = "1111aaaa-0000-0000-0000-000000000001"
local OTHER_ID = "2222bbbb-0000-0000-0000-000000000002"

local function writeSaved(cwd, id, title)
    local dir = config .. "/projects/" .. cwd:gsub("[^%w]", "-")
    gitgud.makeDir(dir)
    local f = assert(io.open(dir .. "/" .. id .. ".jsonl", "wb"))
    local json = gitgud.jsonEncode
    f:write(json({ type = "user", cwd = cwd, message = { role = "user", content = title } }), "\n")
    f:write(json({ type = "assistant", cwd = cwd, message = { role = "assistant",
        content = { { type = "text", text = "Answer about " .. title } } } }), "\n")
    f:close()
end

--- The rows, and the index (0-based) of the first matching one.
local function rowIndex(match)
    for i, row in ipairs(agent.sessionRows()) do
        if match(row) then
            return i - 1, row
        end
    end
    return nil
end
local function headerOf(cwd)
    return rowIndex(function(row)
        return row.header and same(row.header.cwd, cwd)
    end)
end

local toolCalls = {}
gitgud.on("tools.call", function(detail)
    toolCalls[#toolCalls + 1] = gitgud.jsonDecode(detail)
end)

step(1500, "two projects' conversations", function()
    gitgud.makeDir(other)
    local git = gitgud.findProgram("git")
    check("git is there to make the second repository", git ~= nil)
    gitgud.runProgram({ git, "init", "-q", other })
    writeSaved(other, OTHER_ID, "Fix the loot table")
    -- Older: written first, then "other" is touched after it.
    writeSaved(here, HERE_ID, "Tidy the README")
    os.execute('powershell -NoProfile -Command "(Get-Item \'' .. (config .. "/projects/"
        .. other:gsub("[^%w]", "-") .. "/" .. OTHER_ID .. ".jsonl"):gsub("/", "\\")
        .. '\').LastWriteTime = (Get-Date).AddSeconds(5)"')
    shell.show("agent")
    agent.refreshSessions(true)
end)

step(600, "grouped by project", function()
    local list = agent.sessionRows()
    check("Bragi is pinned on top", list[1] and list[1].master == true)
    local hi, hrow = headerOf(here)
    local oi, orow = headerOf(other)
    check("a header per project", hi ~= nil and oi ~= nil)
    check("named by folder", orow and orow.header.name == "other" and hrow
        and hrow.header.name == projects.name(here))
    check("the most recently active project first", oi and hi and oi < hi)
    check("its conversation under it", list[oi + 2] and list[oi + 2].saved
        and list[oi + 2].saved.id == OTHER_ID and same(list[oi + 2].saved.cwd, other))
    check("the folder comes from the transcript", same(agent.savedSession(OTHER_ID).cwd, other))
    shot("01-grouped")
end)

step(200, "collapse the other project", function()
    local oi = headerOf(other)
    local x, y, w = gitgud.getRect("AgentSessionList")
    gitgud.emit("AgentSessionList.clicked", math.floor(x + w / 2) .. "," .. math.floor(y + 10) .. "," .. oi)
end)

step(300, "collapsed", function()
    local oi = headerOf(other)
    local nextRow = agent.sessionRows()[oi + 2]
    check("its conversations are hidden", not (nextRow and nextRow.saved and nextRow.saved.id == OTHER_ID))
    local saved = gitgud.jsonDecode(settings.get("bragi.projectsOpen", "{}")) or {}
    check("remembered", saved[projects.key(other)] == false)
    shot("02-collapsed")
    local x, y, w = gitgud.getRect("AgentSessionList")
    gitgud.emit("AgentSessionList.clicked", math.floor(x + w / 2) .. "," .. math.floor(y + 10) .. "," .. oi)
end)

step(300, "opened again", function()
    local oi = headerOf(other)
    local nextRow = agent.sessionRows()[oi + 2]
    check("shown again", nextRow and nextRow.saved and nextRow.saved.id == OTHER_ID)
    check("remembered open", (gitgud.jsonDecode(settings.get("bragi.projectsOpen", "{}")) or {})
        [projects.key(other)] == true)
    -- Pick the other project's conversation.
    gitgud.emit("AgentSessionList.selected", tostring(oi + 1))
end)

step(800, "resumed in its own folder", function()
    check("its history is read from its folder", agent.items()[1] and agent.items()[1].text == "Fix the loot table")
    check("the tab keeps its folder", same(agent.current().cwd, other))
    check("the next message resumes it", agent.session().resume == OTHER_ID)
    check("the open repository follows it", same(repo.state().path, other))
    check("the header names its project", (gitgud.getText("AgentFolderLabel") or ""):find("other", 1, true) ~= nil)
    shot("03-resumed-other")
    local panel = require("bragi.sidepanel")
    if not panel.snapshot().visible then
        panel.toggle()
    end
    panel.paint()
end)

step(300, "the session panel", function()
    local panel = require("bragi.sidepanel")
    check("the session panel shows the conversation's folder", same(panel.snapshot().folder, other))
    if panel.snapshot().forced then
        panel.toggle()
    end
    say("settings get speechSpeed")
end)

step(2700, "it runs there, without a card (Bragi's own tool)", function()
    check("no permission card", lastOf(agent.items(), "permission") == nil)
    local l = agent.loaded()
    check("Claude Code ran in the conversation's folder", l ~= nil and same(l.cwd, other))
    local reply = lastOf(agent.items(), "assistant")
    check("a UI tool answered", reply ~= nil and reply.text:find("speechSpeed", 1, true) ~= nil)
    local call = toolCalls[#toolCalls]
    check("the tool call names its session", call ~= nil and call.session == agent.session().name
        and call.session ~= nil and call.session ~= "")
end)

step(300, "a conversation in this project, from its header's +", function()
    -- Back to the first repository's project.
    local hi = headerOf(here)
    local x, y, w = gitgud.getRect("AgentSessionList")
    gitgud.emit("AgentSessionList.clicked", math.floor(x + w - 12) .. "," .. math.floor(y + 10) .. "," .. hi)
end)

step(400, "a new conversation there", function()
    check("an empty conversation", #agent.items() == 0)
    check("in that project's folder", same(agent.current().cwd, here))
    say("hello")
end)

step(1500, "it started there", function()
    check("Claude Code ran in the project's folder", same(agent.loaded().cwd, here))
    check("the open repository followed", same(repo.state().path, here))
    local hi = headerOf(here)
    local found = false
    for i = hi + 2, #agent.sessionRows() do
        local row = agent.sessionRows()[i]
        if row.header then
            break
        end
        found = found or row.tab == agent.current()
    end
    check("listed live under its project", found)
    shot("04-new-in-project")
end)

step(300, "the other conversation again: still its own folder", function()
    local _, row = rowIndex(function(r)
        return r.saved and r.saved.id == OTHER_ID
    end)
    check("the other conversation is listed", row ~= nil)
    agent.resume(OTHER_ID)
end)

step(800, "resumed by id, its folder from the listing", function()
    check("its folder", same(agent.current().cwd, other))
    check("the repository follows again", same(repo.state().path, other))
end)

-- One project's conversations in two of Claude Code's folders (one begun
-- in the project, then moved to a worktree): the list has them all
-- (the worktree's one conversation hid the project's others).
local MOVED_ID = "3333cccc-0000-0000-0000-000000000003"
step(300, "a conversation of this project kept in another folder", function()
    local dir = config .. "/projects/" .. here:gsub("[^%w]", "-") .. "--claude-worktrees-side"
    gitgud.makeDir(dir)
    local f = assert(io.open(dir .. "/" .. MOVED_ID .. ".jsonl", "wb"))
    f:write(gitgud.jsonEncode({ type = "user", cwd = here, message = { role = "user",
        content = "Begun here, moved to a worktree" } }), "\n")
    f:close()
    agent.refreshSessions(true)
end)

step(600, "both folders' conversations listed under the project", function()
    local found = {}
    for _, row in ipairs(agent.sessionRows()) do
        if row.saved and row.group and same(row.group.cwd, here) then
            found[row.saved.id] = true
        end
    end
    check("the one in the project's own folder", found[HERE_ID] == true)
    check("and the one in the other folder", found[MOVED_ID] == true)
    local headers = 0
    for _, row in ipairs(agent.sessionRows()) do
        if row.header and same(row.header.cwd, here) then
            headers = headers + 1
        end
    end
    check("one header for the project", headers == 1)
end)

step(300, "done", function()
    print("[ui-test] done")
    gitgud.emit("window.close", "")
end)

harness.run()
