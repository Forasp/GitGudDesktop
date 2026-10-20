--- tests/ui/bragi-images.lua: pictures in a conversation. Dropped (or
-- pasted) images wait in a row in the prompt box, each with an x; they go
-- with the next message, before its text, and show in it. A tool result's
-- image (the fake's Read of shot.png) shows under its step, a reply's
-- ![...](path) shows the file, a click opens the viewer, and a saved
-- conversation shows its pictures again when it's opened. A dropped file
-- that isn't an image puts its path in the prompt box. (Ctrl+V isn't
-- driven here: the test leaves the system clipboard alone.)
--
-- Run it like bragi-agent.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT,
-- GITGUD_SHOTS, GITGUD_TEST_CLAUDE, a scratch CLAUDE_CONFIG_DIR). Prints
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
local images = require("bragi.images")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")
local store = require("bragi.store")

settings.set("bragi.claudeProgram", fake)
local f = assert(io.open(config .. "/fake-transcripts", "wb"))
f:write("on\n")
f:close()

-- Two pictures and a text file next to the test's repository.
local here = repo.state().path:gsub("[/\\]+$", "")
local parent = here:gsub("[/\\][^/\\]+$", "")
local PNG = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAAcklEQVR4nBXKMREAIQwAwUihRAYSIgEZKZESKZQnAyf381tvROAIXIE78AR24A18gRE"
    .. "Tx8Q1cU88E3vinfjmHxJH4krciSexE2/iyz8UjsJVuAtPYRfewld/aByNq3E3nsZuvI2v/wAOcIEbPGCDF3zgB98SfRE4KRJlAAAAAElFTkSuQmCC"
local function writeFile(path, bytes)
    local out = assert(io.open(path, "wb"))
    out:write(bytes)
    out:close()
    return path
end
local first = writeFile(parent .. "/first.png", store.unbase64(PNG))
local second = writeFile(parent .. "/second.png", store.unbase64(PNG) .. "")
local notes = writeFile(parent .. "/notes.txt", "not a picture\n")

local function shot(name)
    gitgud.screenshot(OUT .. "/images-" .. name .. ".png")
end

local function height(name)
    local _, _, _, h = gitgud.getRect(name)
    return h or 0
end

local function click(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2)
end

local function last(kind)
    local items = agent.items()
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
    return nil
end

local composerBefore = 0
local sessionId = nil

step(1500, "the Agent view", function()
    shell.show("agent")
    agent.newSession()
    composerBefore = height("AgentComposer")
    gitgud.emit("app.fileDropped", first)
end)

step(300, "a dropped picture waits in the prompt box", function()
    check("it's attached", #agent.attachments() == 1 and agent.attachments()[1] == first)
    check("the prompt box grew a row for it", height("AgentComposer") > composerBefore)
    check("a non-image isn't attached", agent.attach(notes) == nil and #agent.attachments() == 1)
    agent.dropped(notes)
    agent.attach(second)
end)

step(300, "two pictures; a dropped text file's path went into the prompt box", function()
    check("two attached", #agent.attachments() == 2)
    check("the text file's path is in the prompt box", (gitgud.getText("AgentPromptEdit") or ""):find("notes.txt", 1, true) ~= nil)
    check("the second picture has an x", gitgud.getRect(agent.attachmentWindow(2) .. "Remove") ~= nil)
    shot("01-attached")
    placeholder.setText("AgentPromptEdit", "")
    click(agent.attachmentWindow(2) .. "Remove")
end)

step(300, "its x took it off", function()
    check("one left", #agent.attachments() == 1 and agent.attachments()[1] == first)
    check("Send is lit with only a picture",
        (gitgud.getProperty("AgentSendButton", "NormalFillColour") or ""):upper():find(gitgud.themeColour("accent"), 1, true) ~= nil)
    placeholder.setText("AgentPromptEdit", "what is this")
    agent.submit()
end)

step(4000, "sent with the picture", function()
    local reply = last("assistant")
    check("the agent got the picture before the text", reply ~= nil and reply.text == "You said: what is this (1 image)")
    local user = last("user")
    check("the message shows it", user ~= nil and user.images ~= nil and user.images[1] == first)
    check("its thumbnail is drawn", user ~= nil and gitgud.getRect(user.name .. "Pic1Picture") ~= nil)
    check("the prompt box is empty again", #agent.attachments() == 0)
    check("and back to its height", height("AgentComposer") == composerBefore)
    sessionId = agent.session().id
    shot("02-sent")
    if user then
        click(user.name .. "Pic1")
    end
end)

step(300, "a click opens the viewer", function()
    check("the viewer shows it", images.viewing() == first)
    shot("03-viewer")
    images.close()
    placeholder.setText("AgentPromptEdit", "picture")
    agent.submit()
end)

step(4000, "a tool result's image shows under its step", function()
    check("the viewer closed", images.viewing() == nil)
    local stepItem = last("step")
    check("the Read step has the image", stepItem ~= nil and stepItem.images ~= nil and #stepItem.images == 1)
    local path = stepItem and stepItem.images and stepItem.images[1] or ""
    check("kept in chat-images", path:find("chat-images", 1, true) ~= nil and images.isImage(path))
    check("drawn under the step", stepItem ~= nil and stepItem.pics ~= nil
        and gitgud.getRect(stepItem.pics .. "Pic1Picture") ~= nil)
    check("the turn ended", last("assistant") ~= nil and last("assistant").text == "Here is the screenshot.")
    agent.addMessage("assistant", "Here it is:\n\n![the first picture](" .. first:gsub("\\", "/") .. ")")
end)

step(300, "a reply's linked picture shows", function()
    local reply = last("assistant")
    check("the reply draws the file", reply ~= nil and reply.extra ~= nil and gitgud.getRect(reply.extra .. "Pic1Picture") ~= nil)
    check("a missing file isn't drawn", #images.linked("![x](C:/no/such/file.png)") == 0)
    shot("04-results")
    agent.newSession()
end)

step(300, "the saved conversation opens again", function()
    check("a session id came", sessionId ~= nil)
    -- Just left with New session, it was written to a moment ago, by us: not
    -- "in use elsewhere" (the list said so for five minutes). Written to
    -- after we closed it, it would be.
    check("the one just left isn't in use elsewhere", sessionId ~= nil
        and agent.inUseElsewhere(sessionId, os.time() - 1, true) == nil)
    check("written to later, it is", sessionId ~= nil
        and agent.inUseElsewhere(sessionId, os.time() + 60, true) ~= nil)
    if sessionId then
        agent.resume(sessionId, { cwd = here })
    end
end)

step(1500, "its pictures are back", function()
    local user = nil
    for _, item in ipairs(agent.items()) do
        if item.kind == "user" and item.images then
            user = item
        end
    end
    check("the message has its picture", user ~= nil and #user.images == 1 and images.isImage(user.images[1]))
    check("drawn", user ~= nil and gitgud.getRect(user.name .. "Pic1Picture") ~= nil)
    local stepItem = last("step")
    check("the step has its picture", stepItem ~= nil and stepItem.images ~= nil and #stepItem.images == 1)
    shot("05-reopened")
end)

step(300, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
