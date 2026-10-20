--- tests/ui/bragi-helperask.lua: a helper's (a background sub-agent's)
-- permission request shows as a card in its conversation, saying which
-- helper asks and why, stays last under what the conversation's own agent
-- does after it, outlives the turn, and can be answered there; one Claude
-- Code takes back closes. Against the fake claude (tests/fake_claude.cpp:
-- "helper asks", "helper withdraws").
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here, GITGUD_SHOTS, GITGUD_TEST_CLAUDE, CLAUDE_CONFIG_DIR). Prints
-- "[check] ...".

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local fake = os.getenv("GITGUD_TEST_CLAUDE")
if gitgud.currentUi().id ~= "bragi" or not fake or not os.getenv("CLAUDE_CONFIG_DIR") then
    check("needs GITGUD_UI=bragi, GITGUD_TEST_CLAUDE, and CLAUDE_CONFIG_DIR", false)
    gitgud.emit("window.close", "")
    return
end

local agent = require("bragi.agent")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)

local function shot(name)
    gitgud.screenshot(OUT .. "/helperask-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function say(s)
    gitgud.focus("AgentPromptEdit")
    gitgud.simulateText(s)
    gitgud.simulateKey("enter")
end
--- The newest transcript item of a kind.
local function last(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end
local function stepOf(id)
    for _, item in ipairs(agent.items()) do
        if item.kind == "step" and item.id == id then
            return item
        end
    end
    return nil
end
local function state()
    return agent.tabState(agent.tabs()[#agent.tabs()])
end

step(1500, "start in the Agent view", function()
    shell.show("agent")
end)

step(200, "a background helper asks", function()
    say("helper asks")
end)

step(1500, "its card, with who asks and why", function()
    local card = last("permission")
    check("a card asks", card ~= nil and card.tool == "Bash" and card.answer == nil)
    check("it says which helper asks", card ~= nil and card.helper == "Empty Thinking blocks"
        and (gitgud.getText(card.inner .. "Who") or ""):find("From the helper \u{201C}Empty Thinking blocks\u{201D}", 1, true)
        ~= nil)
    check("and why", (gitgud.getText(card.inner .. "Who") or ""):find("It writes a file outside the project", 1, true)
        ~= nil)
    check("it shows the command", card ~= nil and card.summary == "cd ../other && git diff > ../stash.patch")
    local items = agent.items()
    check("it stays last, under what the agent did after it", items[#items] == card)
    local reply = last("assistant")
    check("the agent's reply is above it", reply ~= nil and reply.text == "Waiting on the helper."
        and card ~= nil and reply.top < card.top)
    check("the turn ended", agent.session().turn == false)
    check("the card outlived the turn", card ~= nil and card.answer == nil)
    check("the conversation waits for you", state() == "permission")    check("the card is on screen", card ~= nil and gitgud.getRect(card.inner .. "Allow") ~= nil)
    shot("01-card")
    if card then
        clickWidget(card.inner .. "Allow")
    end
end)

step(1200, "allowed after the turn", function()
    local card = last("permission")
    check("the card says it was allowed", card ~= nil and card.answer == "Allowed")
    local ran = stepOf("toolu_h2")
    check("the helper's command ran", ran ~= nil and ran.result == "diff saved" and not ran.error)
    check("nothing waits for you now", state() ~= "permission")
    shot("02-allowed")
end)

step(200, "a helper asks, then Claude Code takes it back", function()
    say("helper withdraws")
end)

step(1500, "taken back", function()
    local card = last("permission")
    check("its card came", card ~= nil and card.summary == "git -C ../other log" and card.helper == "Empty Thinking blocks")
    check("and closed", card ~= nil and card.answer == "Cancelled")
    check("nothing waits for you", state() ~= "permission")
    shot("03-withdrawn")
end)

step(300, "done", function()
    gitgud.agentStop(agent.session().name or "")
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
