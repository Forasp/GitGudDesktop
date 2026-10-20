--- tests/ui/bragi-links.lua: links in a conversation. The fake's "links"
-- reply has a Markdown link, a bare web address, the working folder's
-- path, its README.md's path (then a full stop), `README.md` in backticks,
-- and a path that isn't there. Each link gets a clickable spot over its
-- text: a web link opens in the browser, the folder opens, the file shows
-- in its folder; the missing path stays plain, and so does trailing
-- punctuation. A path in your own message is a link too, and so is one in
-- a step's details. The open and reveal bindings are stubbed: no browser
-- or Explorer window opens. Then the theme switches (the script runs
-- again) for the other theme's screenshot.
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
local links = require("bragi.links")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("bragi.shell")

settings.set("bragi.claudeProgram", fake)
local PHASE = "test.linksPhase"
local phase = settings.get(PHASE, "")

-- What a click asked for, instead of a real window.
local opened = {}
gitgud.openExternal = function(target)
    opened[#opened + 1] = { call = "openExternal", target = target }
    return true
end
gitgud.showInFolder = function(target)
    opened[#opened + 1] = { call = "showInFolder", target = target }
    return true
end

local WINDOWS = gitgud.platform == "windows"
local here = repo.state().path:gsub("[/\\]+$", "")
local function native(path)
    return WINDOWS and (path:gsub("/", "\\")) or path
end
local folder = native(here)
local readme = native(here .. "/README.md")

local function shot(name)
    gitgud.screenshot(OUT .. "/links-" .. name .. ".png")
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

--- Every link spot drawn in a reply: { spot, kind, target }, in order.
local function replyLinks(item)
    local out = {}
    for _, name in ipairs(agent.replyTexts(item)) do
        for _, link in ipairs(links.shown(name)) do
            if gitgud.getProperty(link.spot, "Visible") == "true" then
                out[#out + 1] = link
            end
        end
    end
    return out
end

-- Links to a target (slashes either way), in order.
local function findAll(list, target)
    local out = {}
    for _, link in ipairs(list) do
        if native(link.target) == native(target) then
            out[#out + 1] = link
        end
    end
    return out
end
local function find(list, target)
    return findAll(list, target)[1]
end

local shown = {}

if phase == "" then
    step(1500, "the Agent view", function()
        shell.show("agent")
        agent.newSession()
    end)

    step(300, "what counts as a link", function()
        local _, url = links.match("see https://example.com/a.", 5)
        check("a bare web address, its full stop left off", url ~= nil and url.target == "https://example.com/a")
        local _, inBrackets = links.match("(https://example.com/x_(y))", 2)
        check("a closing bracket of its own stays", inBrackets ~= nil and inBrackets.target == "https://example.com/x_(y)")
        local _, bare = links.match("(https://example.com/z)", 2)
        check("a closing bracket around it doesn't", bare ~= nil and bare.target == "https://example.com/z")
        check("not inside a word", links.match("xhttps://example.com", 2) == nil)
        local last1, file = links.match(here .. "/README.md, then", 1)
        check("a file's path, its comma left off", file ~= nil and file.kind == "file" and last1 == #here + 10)
        local _, dir = links.match(here, 1)
        check("a folder's path", dir ~= nil and dir.kind == "folder")
        check("a path that isn't there isn't a link", links.match(here .. "/missing.txt", 1) == nil)
        local _, rel = links.match("src/../README.md", 1, here)
        check("a relative path from the folder", rel ~= nil and rel.kind == "file")
        check("not without a folder", links.match("src/../README.md", 1) == nil)
        check("a word with a slash that isn't there isn't one", links.match("and/or", 1, here) == nil)
        local code = links.target("README.md:12", here)
        check("in backticks, with a line number", code ~= nil and code.kind == "file")
        local markup, spans = links.markup("open " .. here .. "/README.md now", { folder = here })
        check("markup marks the span", #spans == 1
            and markup:sub(spans[1].first, spans[1].last) == (here .. "/README.md"):gsub("%[", "\\["))
        placeholder.setText("AgentPromptEdit", "links")
        agent.submit()
    end)

    step(4000, "the reply's links", function()
        local reply = last("assistant")
        check("the reply came", reply ~= nil and (reply.text or ""):find("Mem0", 1, true) ~= nil)
        shown = replyLinks(reply)
        local mem0 = find(shown, "https://github.com/mem0ai/mem0")
        check("the Markdown link is a link", mem0 ~= nil and mem0.kind == "web")
        local docs = find(shown, "https://example.com/docs/page")
        check("the bare address is one, without its full stop", docs ~= nil and docs.kind == "web")
        local dir = find(shown, folder)
        check("the folder's path is one", dir ~= nil and dir.kind == "folder")
        local file = find(shown, readme)
        check("the file's path is one, without its full stop", file ~= nil and file.kind == "file")
        check("`README.md` in backticks is one too", #findAll(shown, readme) == 2)
        check("the missing path isn't", find(shown, here .. "/missing.txt") == nil)
        check("nothing else is", #shown == 5)
        check("the spots sit on the text", mem0 ~= nil and select(3, gitgud.getRect(mem0.spot)) > 20
            and select(4, gitgud.getRect(mem0.spot)) < 40)
        shot("01-" .. gitgud.theme())
        if mem0 then
            click(mem0.spot)
        end
    end)

    step(300, "clicked the Markdown link", function()
        check("it opened in the browser", #opened == 1 and opened[1].call == "openExternal"
            and opened[1].target == "https://github.com/mem0ai/mem0")
        click(find(shown, "https://example.com/docs/page").spot)
    end)

    step(300, "clicked the bare address", function()
        check("it opened in the browser", #opened == 2 and opened[2].call == "openExternal"
            and opened[2].target == "https://example.com/docs/page")
        click(find(shown, folder).spot)
    end)

    step(300, "clicked the folder", function()
        check("the folder opened", #opened == 3 and opened[3].call == "openExternal" and opened[3].target == folder)
        click(find(shown, readme).spot)
    end)

    step(300, "clicked the file", function()
        check("its folder showed, the file selected", #opened == 4 and opened[4].call == "showInFolder"
            and opened[4].target == readme)
        local read = last("step")
        check("the Read step came", read ~= nil and read.title == "Read")
        if read then
            click(read.inner)
        end
    end)

    step(300, "a step's details", function()
        local read = last("step")
        local spots = read and read.open and links.shown(read.inner .. "Detail") or {}
        check("the path it read is a link", #spots == 1 and spots[1].kind == "file"
            and native(spots[1].target) == readme)
        shot("02-step")
        if spots[1] then
            click(spots[1].spot)
        end
    end)

    step(300, "clicked it", function()
        check("its folder showed", #opened == 5 and opened[5].call == "showInFolder" and opened[5].target == readme)
        local read = last("step")
        check("the step stayed open", read ~= nil and read.open == true)
        placeholder.setText("AgentPromptEdit", "look at " .. here .. "/README.md please")
        agent.submit()
    end)

    step(4000, "a path in your own message", function()
        local user = last("user")
        local spots = user and links.shown(user.name .. "Text") or {}
        check("it's a link", #spots == 1 and spots[1].kind == "file")
        shot("03-message")
        if spots[1] then
            click(spots[1].spot)
        end
    end)

    step(300, "clicked it", function()
        check("its folder showed", #opened == 6 and opened[6].call == "showInFolder" and opened[6].target == readme)
        -- The other theme: the window rebuilds and this script runs again.
        settings.set(PHASE, gitgud.theme() == "dark" and "light" or "dark")
        gitgud.setTheme(gitgud.theme() == "dark" and "light" or "dark")
    end)
else
    -- After the theme switch: the same links, drawn in this theme.
    step(1500, "the other theme", function()
        check("the theme is " .. phase, gitgud.theme() == phase)
        shell.show("agent")
        agent.newSession()
        agent.addMessage("user", "Where is " .. here .. "/README.md?")
        agent.addMessage("assistant", "See [Mem0](https://github.com/mem0ai/mem0), https://example.com/docs/page, "
            .. "the folder " .. here .. " and `README.md`.\n\n```\ncat " .. here .. "/README.md\n```")
    end)

    step(500, "drawn", function()
        local reply = last("assistant")
        local list = replyLinks(reply)
        check("the reply's links are there", #list >= 5)
        local codeText = nil
        for _, name in ipairs(agent.replyTexts(reply)) do
            codeText = name:sub(-4) == "Text" and name or codeText
        end
        check("a link in a code block too", codeText ~= nil and #links.shown(codeText) == 1)
        local wrapped = findAll(list, here)
        check("a link that wraps has a spot on each line", #wrapped == 2
            and select(2, gitgud.getRect(wrapped[2].spot)) > select(2, gitgud.getRect(wrapped[1].spot)))
        shot("01-" .. gitgud.theme())
        if wrapped[2] then
            local x, y, w, h = gitgud.getRect(wrapped[2].spot)
            gitgud.simulateScroll(x + w / 2, y + h / 2, 0)
        end
    end)

    step(300, "pointed at", function()
        shot("02-hover-" .. gitgud.theme())
        settings.set(PHASE, "")
        gitgud.emit("window.close", "")
    end, { full = true })
end

harness.run()
