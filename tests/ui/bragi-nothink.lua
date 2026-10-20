--- tests/ui/bragi-nothink.lua: thinking with no words isn't drawn
-- (empty "Thinking" boxes above the steps and the news). The
-- fake's "think" turn sends an empty thinking block, one with only a
-- signature, a redacted one, then one that has no words for 2 s and then
-- some. Only that last one is drawn, once its words come; the others take
-- no room and leave no gap, and the waiting row stays until there are
-- words to show.
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
local shell = require("bragi.shell")

require("core.settings").set("bragi.claudeProgram", fake)

local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function has(s, part)
    return (s or ""):find(part, 1, true) ~= nil
end
--- The last item of a kind whose text has `part`.
local function find(kind, part)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind and has(items[i].text, part) then
            return items[i]
        end
    end
    return nil
end
local function thinking()
    local out = {}
    for _, item in ipairs(agent.items()) do
        if item.kind == "thinking" then
            out[#out + 1] = item
        end
    end
    return out
end
--- Not drawn: no room, no window of its own.
local function unseen(item)
    return item ~= nil and item.height == 0 and item.inner == nil
end
--- Screen pixels from the bottom of one item to the top of the next shown.
local function gap(above, below)
    local _, ay, _, ah = gitgud.getRect(above.name)
    local _, by = gitgud.getRect(below.name)
    return (ay and by) and by - (ay + ah) or -1
end
local function near(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) <= 1
end

local base = nil -- the gap between a message and the reply under it

step(1500, "Agent view", function()
    shell.show("agent")
    say("hello")
end)

step(3000, "a plain reply", function()
    local reply = find("assistant", "Hello")
    check("the reply came", reply ~= nil and not agent.session().turn)
    base = gap(find("user", "hello"), reply)
    check("a gap between them", base > 0)
    say("think")
end)

step(1500, "thinking with no words yet", function()
    local th = thinking()
    local waiting = agent.current().waiting
    check("an empty block and a signature-only one, and one going; the redacted one is none",
        #th == 3 and th[3].done == false)
    check("none of them is drawn", unseen(th[1]) and unseen(th[2]) and unseen(th[3]))
    check("the waiting row stays", waiting ~= nil and waiting.height and waiting.height > 0)
    check("one message gap under the message, as without them", near(gap(find("user", "think"), waiting), base))
    check("they take no room after it",
        th[3].top == waiting.top + waiting.height and th[1].top == th[3].top)
end)

local words = nil
step(4000, "its words came", function()
    local th = thinking()
    local reply = find("assistant", "Thought it through.")
    words = th[3]
    check("the turn ended with its reply", reply ~= nil and not agent.session().turn)
    check("still three thinking items", #th == 3)
    check("the empty and the signature-only ones aren't drawn", unseen(th[1]) and unseen(th[2]))
    check("the one with words is", words.height > 0 and words.inner ~= nil
        and gitgud.getRect(words.inner) ~= nil and has(words.text, "Weighing the parser. Then the tests."))
    check("the waiting row went", agent.current().waiting == nil)
    check("no gap above it but the usual one", near(gap(find("user", "think"), words), base))
    check("nor under it", near(gap(words, reply), base))
    clickWidget(words.inner)
end)

step(800, "it opens to its words", function()
    check("open", words.open == true)
    check("its words show", has(gitgud.getText(words.inner .. "Detail"), "Weighing the parser"))
    for _, item in ipairs(agent.items()) do
        item.dirty = true
    end
    agent.relayout()
end)

step(600, "drawn again from scratch", function()
    local th = thinking()
    local reply = find("assistant", "Thought it through.")
    check("the empty ones still aren't drawn", unseen(th[1]) and unseen(th[2]))
    check("the one with words still is, open", th[3].height > 0 and th[3].inner ~= nil and th[3].open)
    check("still no gap above it", near(gap(find("user", "think"), th[3]), base))
    check("nor under it", near(gap(th[3], reply), base))
    gitgud.emit("window.close", "")
end)

harness.run()
