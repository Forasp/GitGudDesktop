--- tests/ui/bragi-longchat.lua: a long conversation stays cheap to draw
-- (the app froze for seconds at a time). The renderer
-- gathers every drawn window's text at each redraw, so only the items near
-- the view are drawn: far ones are hidden, and scrolling shows them. A
-- reply streaming in keeps the windows of its finished blocks and draws
-- only its growing end. Laying out again moves nothing that didn't change.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake then
    check("needs GITGUD_UI=bragi and GITGUD_TEST_CLAUDE", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local MESSAGES = 160
local REPLY = table.concat({
    "## A heading",
    "",
    "A paragraph with `code`, **bold** words and a path, src/main.cpp, that runs long enough to wrap "
        .. "over a few lines in the transcript's column.",
    "",
    "- one item",
    "- another item",
    "",
    "```lua",
    "local x = 1",
    "```",
}, "\n")

local function drawn(item)
    return gitgud.getProperty(item.name, "Visible") == "true"
end
local function lastOf(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end

local firstBlock = nil

step(1500, "a long conversation", function()
    shell.show("agent")
    for i = 1, MESSAGES do
        agent.addMessage(i % 2 == 0 and "assistant" or "note", i % 2 == 0 and REPLY or ("Line " .. i .. "."))
    end
end)

step(600, "only what's near the view is drawn", function()
    local items = agent.items()
    check("all of it is there", #items >= MESSAGES)
    check("the latest is drawn", drawn(items[#items]))
    check("the first, far above, isn't", not drawn(items[1]))
    local total, shownWindows = gitgud.uiStats()
    print(string.format("[perf] long conversation: %d windows, %d drawn", total, shownWindows))
    check("most windows aren't drawn", shownWindows < total / 2)
    local t0 = gitgud.now()
    agent.relayout()
    local ms = gitgud.now() - t0
    print(string.format("[perf] laying out %d items again: %d ms", #items, ms))
    check("laying it out again is quick", ms < 250)
    gitgud.setScroll("AgentTranscript", 0)
end)

step(400, "scrolled to the top", function()
    local items = agent.items()
    check("the first is drawn now", drawn(items[1]))
    check("the latest, far below, isn't", not drawn(items[#items]))
    gitgud.setScroll("AgentTranscript", 1e9)
    agent.send("long 30 10")
end)

step(1500, "a long reply streaming in", function()
    local reply = lastOf("assistant")
    check("it streams", reply ~= nil and reply.streaming == true and reply.md ~= nil and reply.md.drawn ~= nil
        and #reply.md.drawn >= 2)
    firstBlock = reply and reply.md and reply.md.drawn and reply.md.drawn[1] and reply.md.drawn[1].window
end)

step(1500, "more of it", function()
    local reply = lastOf("assistant")
    local blocks = reply and reply.md and reply.md.drawn or {}
    check("its first block kept its window", firstBlock ~= nil and blocks[1] ~= nil and blocks[1].window == firstBlock
        and gitgud.getRect(firstBlock) ~= nil)
    check("and it grew", #blocks >= 3)
end)

step(12000, "the reply finished", function()
    local reply = lastOf("assistant")
    check("the whole reply is drawn", reply ~= nil and not reply.streaming and (reply.text or ""):find("Section 24", 1, true) ~= nil)
    check("the first block's window still the same", reply ~= nil and reply.md.drawn[1].window == firstBlock)
    check("its end is in view", drawn(reply))
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
