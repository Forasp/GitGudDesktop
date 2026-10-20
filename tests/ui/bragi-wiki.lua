--- tests/ui/bragi-wiki.lua: the Wiki view on the local store: [[links]]
-- (bragi/wikilinks.lua) and the store's links and activity answers; a
-- wiki's front page (cards, activity, pages to write); a page with its
-- links clickable, what links to it, and its history beside it; the Graph
-- tab (gitgud.drawPicture); the History tab (what each version changed,
-- the whole page then, Restore); and a wiki with no pages, started from a
-- starter page.
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

local links = require("bragi.links")
local shell = require("bragi.shell")
local store = require("bragi.store")
local wiki = require("bragi.wiki")
local wikihistory = require("bragi.wikihistory")
local wikilinks = require("bragi.wikilinks")

local function shot(name)
    gitgud.screenshot(OUT .. "/wiki-" .. name .. ".png")
end
local function clickWidget(name)
    local x, y, w, h = gitgud.getRect(name)
    gitgud.simulateClick(x + w / 2, y + h / 2, "left")
end
local function newestRoot(prefix)
    for n = 400, 1, -1 do
        if gitgud.getRect(prefix .. n) then
            return prefix .. n
        end
    end
    return nil
end
local function exists(name)
    return gitgud.getRect(name) ~= nil
end
local function ask(method, path, body)
    local value, err = store.answer(method, path, body)
    if err then
        print("[store] " .. method .. " " .. path .. ": " .. tostring(err))
    end
    return value
end
--- The clickable links laid over the page's text: { spot, kind, target }.
local function pageLinks()
    local root = newestRoot("WikiBody")
    local out = {}
    for n = 1, 80 do
        for _, suffix in ipairs({ "", "Text" }) do
            for _, l in ipairs(links.shown(root .. "Md" .. n .. suffix)) do
                out[#out + 1] = l
            end
        end
    end
    return out
end

--- The clickable link on the page that goes to `target`.
local function pageLinkTo(target)
    for _, l in ipairs(pageLinks()) do
        if l.target == target then
            return l
        end
    end
    return nil
end
--- The graph's clickable dot for the page called `title`.
local function graphDot(title)
    local root = newestRoot("WikiBody")
    for i = 1, 40 do
        if gitgud.getRect(root .. "Name" .. i) and gitgud.getText(root .. "Name" .. i) == title then
            return root .. "Dot" .. i
        end
    end
    return nil
end

local SHARED = "/api/v1/repos/local/shared/wiki"
local PAGES = {
    { "Home", "# Home\n\nNotes every project can read: how Bragi hears you, how it builds, what was decided.\n\n"
        .. "Start with [[Voice pipeline]] or [[Release steps]]." },
    { "Voice pipeline", "# Voice pipeline\n\nHow Bragi turns speech into a message, from the microphone to the "
        .. "Agent view.\n\n## Stages\n\nAudio goes to the [[Wake word]] detector, then to the recogniser. The "
        .. "rules for what may change live in [[Lua policy]].\n\n> Keep every heard word. See [[Decisions log|the "
        .. "decisions]].\n\n## Settings\n\nSilence length is `voice.silence_ms`." },
    { "Wake word", "# Wake word\n\nThe detector runs on every frame and hands frames back to the [[voice pipeline]]." },
    { "Lua policy", "# Lua policy\n\nC++ gives capabilities only. Wording, defaults and limits live in Lua. "
        .. "See [[Decisions log]]." },
    { "Decisions log", "# Decisions log\n\nNewest first.\n\n- 2026-10-12: keep heard words in the "
        .. "[[Voice pipeline]].\n- Colours by role: [[Theme tokens]]." },
    { "Theme tokens", "# Theme tokens\n\nEvery colour Bragi uses, by role. Light and dark map the same roles." },
    { "Release steps", "# Release steps\n\nSet the version, build and test, tag. See [[Build and test]]." },
    { "guides/Build and test", "# Build and test\n\nBuild, test, run. Back to [[Release steps]].\n\n"
        .. "Not a link: `[[In code]]`.\n\n```\n[[Fenced]]\n```" },
}

-- ===================================================================
-- Links, and the store's answers
-- ===================================================================

step(300, "links, read", function()
    local found = wikilinks.find("A [[Page one]] and [[guides/Two|the second]].\n`[[code]]`\n```\n[[fenced]]\n```\n[[ ]]")
    check("links are found with their shown text", #found == 2 and found[1].target == "Page one"
        and found[2].target == "guides/Two" and found[2].label == "the second" and found[2].line == 1)
    local index = wikilinks.index({ { sub_url = "Voice-pipeline", title = "Voice pipeline" },
        { sub_url = "guides/Deep-Dive", title = "Deep Dive" } })
    check("a link finds its page by title, any case", wikilinks.resolve(index, "voice PIPELINE") == "Voice-pipeline")
    check("a bare name finds a page in a folder", wikilinks.resolve(index, "Deep Dive") == "guides/Deep-Dive")
    check("and a missing page is nil", wikilinks.resolve(index, "Nowhere") == nil)
    check("a summary is the first paragraph, plain", wikilinks.summary("# T\n\nSee **[[A|this]]** and `x`.\n\nMore.")
        == "See this and x.")
    check("a long summary is cut at a word", #wikilinks.summary(string.rep("word ", 100)) < 240)
end)

step(300, "seed the shared wiki", function()
    for _, p in ipairs(PAGES) do
        ask("POST", SHARED .. "/new", { title = p[1], content_base64 = wiki.base64(p[2]), message = "Add " .. p[1] })
    end
end)

-- Commit times are in seconds: wait one out, so these are the newest.
step(1100, "edit a page twice", function()
    -- Two more versions of one page, for its history.
    local vp = PAGES[2][2]
    ask("PATCH", SHARED .. "/page/Voice-pipeline", { title = "Voice pipeline",
        content_base64 = wiki.base64(vp .. "\n\nModels are covered in [[Voice models]]."), message = "Link the models" })
    ask("PATCH", SHARED .. "/page/Voice-pipeline", { title = "Voice pipeline",
        content_base64 = wiki.base64((vp:gsub("then to the recogniser", "then to the recogniser until silence"))
            .. "\n\nModels are covered in [[Voice models]]."), message = "Say when the recogniser stops" })

    local data = ask("GET", "/api/bragi/v0/repos/local/shared/wiki/links")
    local bySub = {}
    for _, p in ipairs(data and data.pages or {}) do
        bySub[p.sub_url] = p
    end
    local vpLinks = {}
    for _, l in ipairs(bySub["Voice-pipeline"] and bySub["Voice-pipeline"].links or {}) do
        vpLinks[l.sub_url] = true
    end
    check("the links answer has every page", data and #data.pages == #PAGES)
    check("with the pages each links to", vpLinks["Wake-word"] and vpLinks["Lua-policy"] and vpLinks["Decisions-log"])
    check("and the ones that don't exist yet", bySub["Voice-pipeline"] and #bySub["Voice-pipeline"].missing == 1
        and bySub["Voice-pipeline"].missing[1].title == "Voice models")
    check("a lower-case link still finds its page", bySub["Wake-word"] and bySub["Wake-word"].links[1]
        and bySub["Wake-word"].links[1].sub_url == "Voice-pipeline")
    check("a bare name finds the page in a folder", bySub["Release-steps"].links[1]
        and bySub["Release-steps"].links[1].sub_url == "guides/Build-and-test")
    check("links in code don't count", #bySub["guides/Build-and-test"].missing == 0)
    check("summaries and word counts come along", bySub["Theme-tokens"].summary:find("Every colour", 1, true) == 1
        and bySub["Theme-tokens"].words > 5)
    local activity = ask("GET", "/api/bragi/v0/repos/local/shared/wiki/activity?limit=5")
    check("the activity answer is the latest changes", activity and #activity == 5
        and activity[1].message == "Say when the recogniser stops" and activity[1].created ~= nil)
    local revs = ask("GET", SHARED .. "/revisions/Voice-pipeline")
    check("revisions carry their time", revs and revs.count == 3 and revs.commits[1].created ~= nil)
end)

step(200, "drawPicture", function()
    local ok = gitgud.drawPicture("WikiTestPicture", 40, 30, {
        { kind = "line", points = { 0, 0, 40, 30 }, width = 2, colour = "FFE8B866" },
        { kind = "disc", x = 20, y = 15, radius = 6, colour = "80FFFFFF" },
        { kind = "ring", x = 20, y = 15, radius = 10, width = 2, colour = "FF35504A" } })
    local bad, why = gitgud.drawPicture("WikiTestPicture", 0, 30, {})
    check("a picture is drawn from shapes", ok == true)
    check("a bad size says why", bad == nil and type(why) == "string")
end)

-- ===================================================================
-- The front page
-- ===================================================================

step(200, "open the Wiki", function()
    shell.show("wiki")
end)

step(900, "the front page", function()
    local page, open, view = wiki.current()
    local root = newestRoot("WikiBody")
    check("the shared wiki's front page shows", open and open.shared and page == nil and view == "home")
    check("with the wiki's name", gitgud.getText(root .. "Title") == "Shared wiki")
    check("what it's for, from its Home page", (gitgud.getText(root .. "About") or ""):find("Notes every project", 1, true))
    check("the Home page first, then the newest", gitgud.getText(root .. "Card1Title") == "Home"
        and gitgud.getText(root .. "Card2Title") == "Voice pipeline")
    check("counts", gitgud.getText(root .. "CountText") == "8 pages")
    check("the latest changes", (gitgud.getText(root .. "Act1Message") or ""):find("Say when", 1, true) == 1)
    check("and the pages to write", gitgud.getText(root .. "MissingTitle") == "1 page to write"
        and exists(root .. "MissingAsk"))
    check("no tabs on the front page", gitgud.getProperty("WikiTabs", "Visible") == "false")
    shot("01-home")
end)

step(200, "after 01-home", function()
    clickWidget(newestRoot("WikiBody") .. "Card2")
end)

-- ===================================================================
-- A page
-- ===================================================================

step(900, "a page from its card", function()
    local page, _, view = wiki.current()
    local side = newestRoot("WikiSideBody")
    check("the card opens its page", page and page.sub_url == "Voice-pipeline" and view == "page")
    check("the tabs show", gitgud.getProperty("WikiTabs", "Visible") == "true")
    check("the side panel shows", gitgud.getProperty("WikiSideBox", "Visible") == "true")
    check("with the pages that link here", side and gitgud.getText(side .. "BackHeadCount") == "3")
    check("and its history", side and gitgud.getText(side .. "HistHeadCount") == "3"
        and gitgud.getText(side .. "Hist1Message") == "Say when the recogniser stops")
    check("who changed it last, and how many versions",
        (gitgud.getText(newestRoot("WikiBody") .. "WhoText") or ""):find("Updated by", 1, true) == 1
        and gitgud.getText(newestRoot("WikiBody") .. "VersionsText") == "3 versions")
    local found = pageLinks()
    local byTarget = {}
    for _, l in ipairs(found) do
        byTarget[l.target] = l
    end
    check("[[links]] in the text are clickable", byTarget["Wake-word"] and byTarget["Lua-policy"]
        and byTarget["Decisions-log"] and byTarget["Wake-word"].kind == "wiki")
    check("a link to a missing page is too", byTarget["Voice models"] ~= nil)
    shot("02-page")
end)

step(200, "after 02-page", function()
    clickWidget(pageLinkTo("Wake-word").spot)
end)

step(900, "a link followed", function()
    local page = wiki.current()
    check("a click on a link opens its page", page and page.sub_url == "Wake-word")
    local side = newestRoot("WikiSideBody")
    check("and its side panel lists who links to it", side and gitgud.getText(side .. "Back1Title") == "Voice pipeline")
    clickWidget(side .. "Back1")
end)

step(900, "back through Linked from", function()
    local page = wiki.current()
    check("Linked from opens the page", page and page.sub_url == "Voice-pipeline")
    clickWidget("WikiTab_graph")
end)

-- ===================================================================
-- Graph
-- ===================================================================

step(900, "the graph", function()
    local _, _, view = wiki.current()
    local root = newestRoot("WikiBody")
    check("the Graph tab shows", view == "graph")
    check("the picture is drawn", gitgud.getProperty(root .. "Picture", "Image") == "BragiWikiGraph")
    local names = {}
    for i = 1, 30 do
        local t = gitgud.getRect(root .. "Name" .. i) and gitgud.getText(root .. "Name" .. i)
        if t then
            names[t] = i
        end
    end
    check("the open page and its neighbours are named", names["Voice pipeline"] and names["Wake word"]
        and names["Decisions log"])
    check("a missing page too", names["Voice models"] ~= nil)
    check("two links out by default: Build and test is too far", names["Build and test"] == nil)
    shot("03-graph")
end)

step(200, "after 03-graph", function()
    clickWidget(graphDot("Wake word"))
end)

step(600, "a dot picked", function()
    local root = newestRoot("WikiBody")
    check("a click shows the page's card", gitgud.getText(root .. "CardTitle") == "Wake word"
        and exists(root .. "CardOpen"))
    shot("04-graph-card")
end)

step(200, "after 04-graph-card", function()
    clickWidget(newestRoot("WikiBody") .. "Depths0")
end)

step(900, "the whole wiki", function()
    local root = newestRoot("WikiBody")
    local names = {}
    for i = 1, 30 do
        local t = gitgud.getRect(root .. "Name" .. i) and gitgud.getText(root .. "Name" .. i)
        if t then
            names[t] = true
        end
    end
    check("Whole wiki shows every page", names["Release steps"] and names["Build and test"] and names["Home"])
    shot("05-graph-all")
end)

step(200, "after 05-graph-all", function()
    clickWidget("WikiTab_history")
end)

-- ===================================================================
-- History
-- ===================================================================

step(900, "history", function()
    local _, _, view = wiki.current()
    local root = newestRoot("WikiBody")
    check("the History tab shows", view == "history")
    check("every version is listed", exists(root .. "Ver3") and not exists(root .. "Ver4"))
    check("the newest first", gitgud.getText(root .. "Head") == "Say when the recogniser stops")
    local adds, dels = 0, 0
    for i = 1, 60 do
        local row = root .. "DiffL" .. i
        if exists(row) then
            local t = gitgud.getText(row)
            adds = adds + ((t:find("+ ", 1, true) and t:find("until silence", 1, true)) and 1 or 0)
            dels = dels + ((t:find("\u{2212} ", 1, true) and not t:find("until silence", 1, true)) and 1 or 0)
        end
    end
    check("what it changed: one line out, one in", adds == 1 and dels == 1)
    check("no Restore on the newest", not exists(root .. "Restore"))
    shot("06-history")
end)

step(200, "after 06-history", function()
    clickWidget(newestRoot("WikiBody") .. "Ver3")
end)

step(900, "the first version", function()
    local root = newestRoot("WikiBody")
    check("an older version is picked", gitgud.getText(root .. "Head") == "Add Voice pipeline")
    check("the first version is all new", exists(root .. "First"))
    check("and it can be restored", exists(root .. "Restore"))
    clickWidget(root .. "Modespage")
end)

step(700, "the whole page then", function()
    local root = newestRoot("WikiBody")
    check("Whole page draws the text as it was", exists(root .. "Md1") and not exists(root .. "Diff"))
    local d = wikihistory.diff("a\nb\nc", "a\nB\nc\nd")
    local kinds = { same = 0, add = 0, del = 0 }
    for _, l in ipairs(d) do
        kinds[l.kind] = kinds[l.kind] + 1
    end
    check("the line diff", #d == 5 and kinds.same == 2 and kinds.add == 2 and kinds.del == 1
        and d[1].text == "a" and d[5].text == "d")
    clickWidget(root .. "Restore")
end)

step(1200, "restored", function()
    local revs = ask("GET", SHARED .. "/revisions/Voice-pipeline")
    local now = ask("GET", "/api/bragi/v0/repos/local/shared/wiki/page/Voice-pipeline")
    check("Restore saves the old text as a new version", revs and revs.count == 4
        and revs.commits[1].message:find("Restore Voice pipeline", 1, true) == 1)
    check("with that version's text", now and now.content == PAGES[2][2])
end)

-- ===================================================================
-- A wiki with no pages
-- ===================================================================

step(200, "the project's wiki", function()
    wiki.load()
end)

step(900, "listed", function()
    local _, open = wiki.current()
    check("the shared wiki stays open", open and open.shared)
    local repoWiki = nil
    for _, w in ipairs(ask("GET", "/api/bragi/v0/wikis") or {}) do
        if not w.shared then
            repoWiki = w
        end
    end
    check("the open repository has a wiki", repoWiki ~= nil)
    wiki.openWiki(repoWiki)
end)

step(900, "empty", function()
    local root = newestRoot("WikiBody")
    check("an empty wiki says how to start it", gitgud.getText(root .. "Title") == "Start repo's wiki")
    check("Bragi can draft it", exists(root .. "Ask") and exists(root .. "Blank"))
    check("or a starter page", gitgud.getText(root .. "Starter3Title") == "Decisions log")
    shot("07-empty")
end)

step(200, "start from a starter", function()
    clickWidget(newestRoot("WikiBody") .. "Starter3")
end)

step(1200, "started", function()
    local page, open, view = wiki.current()
    check("the starter page is made and opened", page and page.sub_url == "Decisions-log" and view == "page"
        and not open.shared)
    check("with the starter text", page and page.content:find("Newest first", 1, true) ~= nil)
    shot("08-started")
end)

-- ===================================================================
-- A wiki made outside the view (an agent committing straight into the
-- store) shows the next time the view is opened, with no event and no
-- restart
-- ===================================================================

local OUTSIDE = nil

local function listed(repo)
    local _, _, _, wikis = wiki.current()
    for _, w in ipairs(wikis or {}) do
        if w.repo == repo then
            return true
        end
    end
    return false
end

step(200, "a wiki committed from outside", function()
    OUTSIDE = store.repoOf("C:/ui-test/outside-project")
    local id = OUTSIDE and OUTSIDE:match("^local/(.+)$")
    check("a second project is registered", id ~= nil)
    if id then
        gitgud.bareCommit("bragi/wikis/" .. id .. ".wiki.git",
            { { path = "Home.md", content = "# Outside\n\nMade by an agent.\n" } }, "Add Home", "Agent", "agent@localhost")
    end
    check("and its wiki committed straight into the store", id ~= nil
        and #(gitgud.bareFiles("bragi/wikis/" .. id .. ".wiki.git") or {}) == 1)
    check("the open view doesn't know yet", not listed(OUTSIDE))
    shell.show("agent")
end)

step(200, "away", function()
    shell.show("wiki")
end)

step(900, "back to the Wiki", function()
    local _, open = wiki.current()
    check("opening the view lists the new wiki", listed(OUTSIDE))
    check("and the open wiki stays open", open ~= nil and not open.shared)
end)

step(200, "done", function()
    print("[ui-test] finished")
    gitgud.emit("window.close", "")
end)

harness.run()
