--- tests/ui/bragi-sidebars.lua: the Bragi views' side columns resize by
-- dragging their edges, like the Repo view's (in the
-- Agent and Wiki views they couldn't be resized). The Agent view's
-- conversation list and session panel, the Wiki view's page tree and the
-- panel beside a page: each follows a drag (ui/splitter.lua), keeps its
-- least and most width (never pushing the other side's panel off), and
-- is remembered. Also the Wiki view's page tree: pages in a folder go by
-- their own names ("Space Game / Balance", not "Space Game / Space Game
-- - Balance", cut off), and History rows beside a page show a message's
-- first line only.
--
-- Run it like bragi.lua (GITGUD_UI=bragi, scratch APPDATA and LOCALAPPDATA,
-- a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing here,
-- GITGUD_SHOTS for screenshots). Prints "[check] ..." lines.

local OUT = os.getenv("GITGUD_SHOTS") or "."

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

if gitgud.currentUi().id ~= "bragi" then
    print("[ui-test] needs GITGUD_UI=bragi")
    return
end

local agent = require("bragi.agent")
local parts = require("bragi.wikiparts")
local settings = require("core.settings")
local shell = require("bragi.shell")
local sidepanel = require("bragi.sidepanel")
local store = require("bragi.store")
local wiki = require("bragi.wiki")

local SHARED = "/api/v1/repos/local/shared/wiki"

-- The page tree's rows as the Wiki view sets them.
local treeRows = {}
local setList = gitgud.setList
gitgud.setList = function(name, items, ...)
    if name == "WikiPages" then
        treeRows = items
    end
    return setList(name, items, ...)
end

local function shot(name)
    gitgud.screenshot(OUT .. "/sidebars-" .. name .. ".png")
end
local function rect(name)
    local x, y, w, h = gitgud.getRect(name)
    return { x = x or 0, y = y or 0, w = w or 0, h = h or 0 }
end
local function clickWidget(name)
    local r = rect(name)
    gitgud.simulateClick(r.x + r.w / 2, r.y + r.h / 2, "left")
end
local function visible(name)
    return gitgud.getProperty(name, "Visible") == "true"
end
--- Drag a seam sideways by `dx` px.
local function drag(name, dx)
    local r = rect(name)
    local x, y = r.x + r.w / 2, r.y + r.h / 2
    gitgud.simulateDrag(x, y, x + dx, y)
end
local function near(a, b)
    return math.abs(a - b) <= 2
end
local function ask(method, path, body)
    local value, err = store.answer(method, path, body)
    if err then
        print("[store] " .. method .. " " .. path .. ": " .. tostring(err))
    end
    return value
end
local function plain(item)
    return ((item or ""):gsub("%[[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s*\u{2022}$", ""))
end
local function newestRoot(prefix)
    for n = 400, 1, -1 do
        if gitgud.getRect(prefix .. n) then
            return prefix .. n
        end
    end
    return nil
end

local before = {}

-- ===================================================================
-- Names in the page tree, and changes in one line
-- ===================================================================

step(300, "a page's name in its folder", function()
    local function label(sub, title)
        local folder, name = parts.treeLabel({ sub_url = sub, title = title })
        return (folder and (folder .. " / ") or "") .. name
    end
    check("a subpage goes by the rest of its title",
        label("Space Game/Space Game - Balance", "Space Game   Balance") == "Space Game / Balance")
    check("with any separator", label("Space-Game/Space-Game-Economy", "Space Game Economy") == "Space Game / Economy"
        and label("Game/Game: Vehicles", "Game: Vehicles") == "Game / Vehicles"
        and label("Game/game \u{2013} Combat", "game \u{2013} Combat") == "Game / Combat")
    check("the folder's own page by its title alone", label("Space Game/Space Game", "Space Game") == "Space Game")
    check("a title that doesn't start with the folder keeps it", label("guides/Build and test", "Build and test")
        == "guides / Build and test")
    check("nor one whose first word only starts the same", label("Game/Games list", "Games list")
        == "Game / Games list")
    check("a page at the top as it is", label("Home", "Home") == "Home")
    check("a change's first line", parts.summary("\n  Add the index of all projects  \r\n\nWritten from notes")
        == "Add the index of all projects")
    check("or that there's none", parts.summary("") == "(no message)" and parts.summary(nil) == "(no message)")
end)

step(300, "seed the shared wiki", function()
    local pages = {
        { "Home", "# Home\n\nSee [[Space Game]].", "Add Home" },
        { "Space Game/Space Game", "# Space Game\n\nThe game. [[Space Game - Balance]].",
            "Add the index of all projects, plus the first pages\n\nWritten from the design notes." },
        { "Space Game/Space Game - Balance", "# Balance\n\nBack to [[Space Game]].", "Add Balance" },
        { "Space Game/Space Game - Economy", "# Economy\n\nBack to [[Space Game]].", "Add Economy" },
        { "Space Game/Space Game - Vehicles", "# Vehicles\n\nBack to [[Space Game]].", "Add Vehicles" },
    }
    for _, p in ipairs(pages) do
        ask("POST", SHARED .. "/new", { title = p[1], content_base64 = wiki.base64(p[2]), message = p[3] })
    end
end)

-- ===================================================================
-- The Agent view: the conversation list
-- ===================================================================

step(600, "the Agent view", function()
    settings.set("bragi.panel", false)
    shell.show("agent")
    agent.relayout()
end)

step(400, "drag the conversation list's edge", function()
    check("the list has its seam", visible("AgentSidebarSplit"))
    before.list = rect("AgentSidebar").w
    check("the list starts at its usual width (" .. before.list .. ")", before.list == 264)
    drag("AgentSidebarSplit", 80)
end)

step(400, "wider", function()
    local w = rect("AgentSidebar").w
    check("the list follows the drag (" .. before.list .. " -> " .. w .. ")", near(w, before.list + 80))
    check("the conversation starts where it ends", near(rect("AgentMain").x, rect("AgentSidebar").x + w))
    check("the seam sits on the edge", near(rect("AgentSidebarSplit").x + rect("AgentSidebarSplit").w / 2,
        rect("AgentSidebar").x + w))
    check("and the width is remembered", near(settings.get("bragi.sidebarWidth", 0), w))
    shot("01-agent-wider")
    drag("AgentSidebarSplit", -5000)
end)

step(400, "as narrow as it goes", function()
    check("the list keeps its least width (" .. rect("AgentSidebar").w .. ")", rect("AgentSidebar").w == 200)
    check("remembered", settings.get("bragi.sidebarWidth", 0) == 200)
    -- The session panel fits beside the conversation now.
    settings.set("bragi.panel", true)
    agent.relayout()
end)

step(400, "with the session panel beside it", function()
    check("the panel shows beside the conversation", visible("AgentPanel") and sidepanel.snapshot().wide == true)
    check("with its own seam", visible("AgentPanelSplit"))
    drag("AgentSidebarSplit", 5000)
end)

step(400, "widened as far as it goes", function()
    local root, panel = rect("AgentRoot").w, rect("AgentPanel").w
    local most = math.min(520, root - panel - sidepanel.MIN_MAIN)
    check("the list stops where the panel would go (" .. rect("AgentSidebar").w .. ", " .. most .. ")",
        near(rect("AgentSidebar").w, most))
    check("so the panel stays", visible("AgentPanel") and sidepanel.snapshot().wide == true)
    drag("AgentSidebarSplit", -5000)
end)

-- ===================================================================
-- The Agent view: the session panel
-- ===================================================================

step(400, "drag the session panel's edge", function()
    before.panel = rect("AgentPanel").w
    check("the panel starts at its usual width (" .. before.panel .. ")", before.panel == 288)
    drag("AgentPanelSplit", -40)
end)

step(400, "the panel wider", function()
    local p = rect("AgentPanel")
    check("the panel follows the drag (" .. before.panel .. " -> " .. p.w .. ")", near(p.w, before.panel + 40))
    check("its right edge stays at the window's", near(p.x + p.w, rect("AgentRoot").x + rect("AgentRoot").w))
    check("the conversation ends where it starts", near(rect("AgentMain").x + rect("AgentMain").w, p.x))
    check("remembered", near(settings.get("bragi.panelWidth", 0), p.w))
    shot("02-panel-wider")
    drag("AgentPanelSplit", -5000)
end)

step(400, "the panel as wide as it goes", function()
    check("the conversation keeps its least width beside it (" .. rect("AgentMain").w .. ")",
        rect("AgentMain").w >= sidepanel.MIN_MAIN - 2)
    check("and the panel stays beside it", visible("AgentPanel") and sidepanel.snapshot().wide == true)
    drag("AgentPanelSplit", 5000)
end)

step(400, "the panel as narrow as it goes", function()
    check("the panel keeps its least width (" .. rect("AgentPanel").w .. ")", rect("AgentPanel").w == 240)
    check("remembered", settings.get("bragi.panelWidth", 0) == 240)
    settings.set("bragi.panel", false)
    clickWidget("AgentSidebarButton")
end)

step(400, "the list closed", function()
    check("the list closes (" .. tostring(visible("AgentSidebar")) .. ")", not visible("AgentSidebar"))
    check("and its seam goes with it", not visible("AgentSidebarSplit"))
    clickWidget("AgentSidebarButton")
end)

-- ===================================================================
-- The Wiki view
-- ===================================================================

step(400, "open the Wiki", function()
    check("the list is back at its remembered width", visible("AgentSidebar") and rect("AgentSidebar").w == 200)
    shell.show("wiki")
end)

step(1200, "the tree", function()
    local _, open = wiki.current()
    check("the shared wiki is open", open and open.shared)
    local shown = {}
    for _, item in ipairs(treeRows) do
        shown[#shown + 1] = plain(item)
    end
    local all = table.concat(shown, "|")
    check("subpages go by their own names (" .. all .. ")", all:find("Space Game / Balance", 1, true)
        and all:find("Space Game / Economy", 1, true) and all:find("Space Game / Vehicles", 1, true))
    check("the folder's own page once", all:find("|Space Game|", 1, true) ~= nil
        and not all:find("Space Game / Space Game", 1, true))
    wiki.openPage(store.subUrl("Space Game/Space Game"))
end)

step(1200, "a page, with the panel beside it", function()
    check("the side panel shows", visible("WikiSideBox") and visible("WikiSideSplit"))
    local root = newestRoot("WikiSideBody")
    local message = root and gitgud.getText(root .. "Hist1Message") or ""
    check("its History row is the message's first line (" .. message .. ")",
        message:find("Add the index of all projects", 1, true) == 1 and not message:find("\n", 1, true)
        and not message:find("Written from", 1, true))
    before.tree = rect("WikiTree").w
    before.side = rect("WikiSideBox").w
    check("the tree starts at its usual width (" .. before.tree .. ")", before.tree == 256)
    check("the side panel too (" .. before.side .. ")", before.side == 300)
    drag("WikiTreeSplit", 60)
end)

step(400, "the tree wider", function()
    local w = rect("WikiTree").w
    check("the tree follows the drag (" .. before.tree .. " -> " .. w .. ")", near(w, before.tree + 60))
    check("the page column starts where it ends", near(rect("WikiMain").x, rect("WikiTree").x + w))
    check("remembered", near(settings.get("bragi.wikiTreeWidth", 0), w))
    drag("WikiSideSplit", -30)
end)

step(800, "the side panel wider", function()
    local s = rect("WikiSideBox")
    check("the side panel follows the drag (" .. before.side .. " -> " .. s.w .. ")", near(s.w, before.side + 30))
    check("its right edge stays at the window's", near(s.x + s.w, rect("WikiMain").x + rect("WikiMain").w))
    check("the page ends where it starts", near(rect("WikiPage").x + rect("WikiPage").w, s.x))
    check("remembered", near(settings.get("bragi.wikiSideWidth", 0), s.w))
    local root = newestRoot("WikiSideBody")
    local _, _, bodyW = gitgud.getRect(root or "")
    check("and drawn again for its width (" .. tostring(bodyW) .. ")", bodyW and near(bodyW, s.w - 1))
    shot("03-wiki-wider")
    drag("WikiTreeSplit", 5000)
end)

step(800, "the tree as wide as it goes", function()
    check("the side panel stays beside the page", visible("WikiSideBox"))
    check("which keeps its least width (" .. rect("WikiPage").w .. ")", rect("WikiPage").w >= 640 - 2)
    drag("WikiSideSplit", 5000)
end)

step(800, "the side panel as narrow as it goes", function()
    check("the side panel keeps its least width (" .. rect("WikiSideBox").w .. ")", rect("WikiSideBox").w == 220)
    drag("WikiTreeSplit", -5000)
end)

step(800, "the tree as narrow as it goes", function()
    check("the tree keeps its least width (" .. rect("WikiTree").w .. ")", rect("WikiTree").w == 180)
    shot("04-wiki-narrow")
    gitgud.emit("window.close", "")
end)

harness.run()
