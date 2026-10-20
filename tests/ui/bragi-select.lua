--- tests/ui/bragi-select.lua: selecting and copying a conversation's text.
-- A message and a reply (a paragraph, a list, a code block, a last line)
-- are added, and a step with its details open. Then, with the mouse:
-- a drag across the reply selects its text in order and Ctrl+C copies it
-- as shown; a double-click selects a word and a triple-click a paragraph;
-- a drag from your message into the reply takes both; a drag in a step's
-- details selects there and doesn't fold the step; the right-click menu
-- copies the selection or the whole message; the Copy buttons on a code
-- block, under a reply and under your message copy theirs; Ctrl+C with
-- the prompt box focused leaves the selection alone; a click elsewhere
-- clears it. The clipboard is stubbed.
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT,
-- GITGUD_SHOTS, GITGUD_TEST_CLAUDE, a scratch CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

if gitgud.currentUi().id ~= "bragi" then
    check("needs GITGUD_UI=bragi", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local placeholder = require("ui.placeholder")
local settings = require("core.settings")
local shell = require("bragi.shell")
local textselect = require("bragi.textselect")

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if fake then
    settings.set("bragi.claudeProgram", fake)
end

-- What was copied, instead of the real clipboard.
local copied = {}
gitgud.setClipboard = function(s)
    copied[#copied + 1] = s
    return true
end
local function lastCopy()
    return copied[#copied]
end

local USER = "Please copy this message."
local REPLY = "First paragraph with some words.\n\n- one\n- two\n\n```\nlocal x = 1\nprint(x)\n```\n\nLast line."
local CODE = "local x = 1\nprint(x)"

local user, reply, tool

local function shot(name)
    gitgud.screenshot(OUT .. "/select-" .. name .. ".png")
end

--- Window pixels of a text's characters first..last (0-based).
local function charsAt(name, first, last)
    local wx, wy = gitgud.getRect(name)
    local r = gitgud.shownRects(name, first, last)[1]
    if not r then
        return nil
    end
    return wx + r[1], wy + r[2], r[3], r[4]
end

local function centre(name)
    local x, y, w, h = gitgud.getRect(name)
    return x + w / 2, y + h / 2
end

--- The reply's text widgets, in order.
local function replyTexts()
    local out = {}
    for _, t in ipairs(reply.texts or {}) do
        out[#out + 1] = t.name
    end
    return out
end

--- The reply's code block (its box): the one with a Copy button.
local function codeBox()
    -- A code block's text is its box's name and "Text".
    for _, t in ipairs(reply.texts or {}) do
        local box = t.name:match("^(.*)Text$")
        if box and gitgud.getRect(box .. "Copy") then
            return box
        end
    end
    return nil
end

local function menuItem(label)
    for i = 1, 12 do
        local name = "MenuItem" .. i
        if gitgud.getRect(name) and gitgud.getProperty(name, "Visible") == "true"
            and (gitgud.getText(name) or ""):find(label, 1, true) then
            return name
        end
    end
    return nil
end

local function hoverOver(name)
    local x, y = centre(name)
    gitgud.simulateMove(x, y)
end

step(800, "a conversation", function()
    shell.show("agent")
    agent.newSession()
    user = agent.addMessage("user", USER)
    reply = agent.addMessage("assistant", REPLY)
    -- A step, open, with details to select.
    tool = agent.addMessage("step", "")
    tool.title, tool.summary = "Read", "notes.txt"
    tool.inputText, tool.result = "notes.txt", "alpha beta gamma"
    tool.open, tool.dirty = true, true
    agent.layoutSoon()
end)

step(400, "drawn", function()
    local texts = replyTexts()
    check("the reply's texts are known in order (paragraph, two list items, code, last line)", #texts == 5)
    check("the code block has a Copy button", codeBox() ~= nil)
    check("nothing is selected yet", textselect.text() == "")
end)

step(200, "drag across the reply", function()
    local texts = replyTexts()
    local x1, y1 = charsAt(texts[1], 0, 0)
    local x2, y2 = charsAt(texts[5], 0, 0)
    -- From before the first character to before "Last line".
    gitgud.simulateDrag(x1 + 1, y1 + 4, x2 + 1, y2 + 4)
end)

step(300, "selected", function()
    check("the drag selected the reply as shown, up to the last line",
        textselect.text() == "First paragraph with some words.\n\n- one\n- two\n\n" .. CODE .. "\n\n")
    check("the selection is drawn over each line", #textselect.boxes() >= 5)
    shot("01-reply")
    gitgud.emit("key", "ctrl+c")
end)

step(200, "Ctrl+C", function()
    check("Ctrl+C copied it", lastCopy() == textselect.text())
    -- A double-click on "paragraph".
    local name = replyTexts()[1]
    local x, y, w, h = charsAt(name, 6, 14)
    gitgud.simulateClick(x + w / 2, y + h / 2, "double")
end)

step(200, "a word", function()
    check("a double-click selected the word", textselect.text() == "paragraph")
    local name = replyTexts()[1]
    local x, y, w, h = charsAt(name, 6, 14)
    -- A click somewhere else first, so the double-click before doesn't count.
    gitgud.simulateClick(x + w / 2, y + h + 40)
    gitgud.simulateClick(x + w / 2, y + h / 2, "double")
    gitgud.simulateClick(x + w / 2, y + h / 2)
end)

step(200, "a paragraph", function()
    check("a triple-click selected the paragraph", textselect.text() == "First paragraph with some words.")
    -- From the start of your message into the reply's first paragraph.
    local x1, y1 = charsAt(user.name .. "Text", 0, 0)
    local x2, y2, w2, h2 = charsAt(replyTexts()[1], 0, 4)
    gitgud.simulateDrag(x1 + 1, y1 + 4, x2 + w2, y2 + h2 / 2)
end)

step(300, "across messages", function()
    check("a drag across two messages takes both", textselect.text() == USER .. "\n\nFirst")
    shot("02-across")
end)

step(200, "shown", function()
    -- Into the step's details: selecting there doesn't fold the step.
    local detail = tool.inner .. "Detail"
    local x1, y1 = charsAt(detail, 0, 0)
    local x2, y2, w2, h2 = charsAt(detail, 0, 8)
    gitgud.simulateDrag(x1 + 1, y1 + 4, x2 + w2, y2 + h2 / 2)
end)

step(300, "in a step", function()
    check("a step's details can be selected", textselect.text() == "notes.txt")
    check("and the step stays open", tool.open == true)
    -- The right-click menu, over the reply's last line.
    local x, y = charsAt(replyTexts()[5], 0, 3)
    gitgud.simulateClick(x + 2, y + 4, "right")
end)

step(300, "the menu", function()
    local copy, whole = menuItem("Copy"), menuItem("Copy message")
    check("the menu has Copy and Copy message", copy ~= nil and whole ~= nil)
    check("and Select all", menuItem("Select all") ~= nil)
    check("the selection stayed for it", textselect.text() == "notes.txt")
    shot("03-menu")
end)

step(200, "shown", function()
    local copy = menuItem("Copy")
    if copy then
        gitgud.simulateClick(centre(copy))
    end
end)

step(200, "Copy from the menu", function()
    check("Copy copied the selection", lastCopy() == "notes.txt")
    local x, y = charsAt(replyTexts()[5], 0, 3)
    gitgud.simulateClick(x + 2, y + 4, "right")
end)

step(300, "the menu again", function()
    local whole = menuItem("Copy message")
    if whole then
        gitgud.simulateClick(centre(whole))
    end
end)

step(200, "Copy message", function()
    check("Copy message copied the reply as written", lastCopy() == REPLY)
    local box = codeBox()
    if box then
        gitgud.simulateClick(centre(box .. "Copy"))
    end
end)

step(200, "the code's Copy", function()
    check("the code block's Copy copied its code", lastCopy() == CODE)
    hoverOver(reply.inner)
end)

step(200, "over the reply", function()
    local button = reply.name .. "ActionsCopy"
    check("a Copy button shows under the reply", gitgud.getRect(button) ~= nil
        and gitgud.getProperty(reply.name .. "Actions", "Visible") == "true")
    shot("04-reply-copy")
    if gitgud.getRect(button) then
        gitgud.simulateClick(centre(button))
    end
end)

step(200, "the reply's Copy", function()
    check("it copied the reply", lastCopy() == REPLY)
    hoverOver(user.name .. "Bubble")
end)

step(200, "over your message", function()
    local button = user.name .. "ActionsCopy"
    check("a Copy button shows under your message", gitgud.getRect(button) ~= nil
        and gitgud.getProperty(user.name .. "Actions", "Visible") == "true")
    if gitgud.getRect(button) then
        gitgud.simulateClick(centre(button))
    end
end)

step(200, "your message's Copy", function()
    check("it copied your message", lastCopy() == USER)
    textselect.selectAll()
    check("Select all takes every text", textselect.text():sub(1, #USER) == USER
        and textselect.text():find("alpha beta gamma", 1, true) ~= nil)
    -- The prompt box has the focus: its own Ctrl+C, not the transcript's.
    placeholder.setText("AgentPromptEdit", "typed")
    gitgud.focus("AgentPromptEdit")
end)

step(200, "the prompt box focused", function()
    local before = #copied
    gitgud.emit("key", "ctrl+c")
    check("Ctrl+C in the prompt box leaves the selection alone", #copied == before)
    -- A click on a blank part of the transcript clears it.
    local x, y, w, h = gitgud.getRect("AgentTranscript")
    gitgud.simulateClick(x + 4, y + h - 30)
end)

step(200, "cleared", function()
    check("a click elsewhere cleared the selection", textselect.text() == "" and #textselect.boxes() == 0)
    placeholder.setText("AgentPromptEdit", "")
    gitgud.emit("window.close", "")
end)

harness.run()
