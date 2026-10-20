--- bragi/wiki.lua: the Wiki view (layouts/bragi/wiki.xml).
--
-- Pages come from Bragi's store (bragi/server.lua): one wiki per
-- repository, plus the shared one. The tree lists the wikis, with the open
-- wiki's pages under it; the search field searches every wiki. A page is
-- fetched as Markdown (html=false) and drawn by bragi/markdown.lua: the
-- store's HTML is never shown.
--
-- What the right side shows (view):
--   home     the open wiki's front page: recent pages as cards, its
--            activity, links to pages that don't exist yet; or, for a wiki
--            with no pages, ways to start one (bragi/wikihome.lua)
--   page     a page, its [[links]] clickable (bragi/wikilinks.lua), and
--            beside it the pages that link to it and its history
--   graph    how the pages link, around the open page (bragi/wikigraph.lua)
--   history  the page's versions, what each changed, and Restore
--            (bragi/wikihistory.lua)
-- Page, Graph and History are tabs in the top bar; a wiki in the tree
-- opens its front page. A dot in the tree marks a page Bragi changed in
-- the last day.
--
-- Edit swaps the page for its source (Save, Cancel); New page asks for a
-- title. Both need write access to that wiki. "Ask Bragi to update" puts a
-- request about the page in the Agent view's prompt. The store's events reload
-- the open page when it changes in the store (unless you're editing it).

local C = require("core.palette")
local app = require("core.app")
local commands = require("ui.commands")
local dialog = require("ui.dialog")
local links = require("bragi.links")
local markdown = require("bragi.markdown")
local parts = require("bragi.wikiparts")
local placeholder = require("ui.placeholder")
local rowsUi = require("bragi.rows")
local server = require("bragi.server")
local shell = require("bragi.shell")
local status = require("core.status")
local text = require("core.text")
local ui = require("bragi.ui")
local wikigraph = require("bragi.wikigraph")
local wikihistory = require("bragi.wikihistory")
local wikihome = require("bragi.wikihome")
local wikilinks = require("bragi.wikilinks")

local wiki = { name = "bragi.wiki" }

local API = "/api/bragi/v0"
local SIDE = 300          -- the side panel's width beside a page, until it's dragged
local SIDE_MIN = 220
local SIDE_MAX = 520
local SIDE_FROM = 940     -- the narrowest the main column shows it at
local PAGE_LEAST = SIDE_FROM - SIDE -- the page's narrowest beside it
local TREE = 256          -- the page tree's width, until it's dragged
local TREE_MIN = 180
local TREE_MAX = 480
local MAIN_LEAST = 640    -- the main column's narrowest beside the tree
local FRESH = 86400       -- a page changed this recently gets a dot in the tree
local READ_WPM = 200      -- words a minute, for "4 min read"
local HISTORY_SHOWN = 5   -- versions listed beside a page

local CONTROLS = 148      -- the window's buttons, at the top bar's right
local SEARCH_W = 240      -- the search box, when there's room
local SEARCH_FROM = 1180  -- the narrowest the main column has the whole box at

local TABS = { { id = "page", label = "Page" }, { id = "graph", label = "Graph" },
    { id = "history", label = "History" } }

local wikis = {}          -- readable wikis, shared first
local open = nil          -- the open wiki (an entry of wikis)
local pages = {}          -- the open wiki's pages, by path
local page = nil          -- the open page { title, sub_url, content, ... }
local view = "home"       -- home | page | graph | history
local linkData = nil      -- the open wiki's links: { pages, bySub, back, index, count, missing }
local activity = nil      -- the open wiki's latest changes
local revisions = nil     -- the open page's versions { sub, commits }
local hits = nil          -- search hits while searching, else nil
local rows = {}           -- what each tree row is: { kind, wiki | page | hit }
local state = "idle"      -- idle | loading | ready | error
local problem = nil
local editing = false
local built = 0
local sideBuilt = 0
local searchTimer = nil
local treeSplit = nil     -- the tree's right edge (ui/splitter.lua), made in init
local sideSplit = nil     -- the side panel's left edge

-- ===================================================================
-- Helpers
-- ===================================================================

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64 of a byte string (the wiki API takes page text this way).
function wiki.base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local e1 = n // 262144 % 64
        local e2 = n // 4096 % 64
        local e3 = n // 64 % 64
        local e4 = n % 64
        out[#out + 1] = B64:sub(e1 + 1, e1 + 1) .. B64:sub(e2 + 1, e2 + 1)
            .. (b and B64:sub(e3 + 1, e3 + 1) or "=") .. (c and B64:sub(e4 + 1, e4 + 1) or "=")
    end
    return table.concat(out)
end

local function encode(s)
    return (s:gsub("[^%w%-%._~]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

local build

--- The side panel's width beside a page.
local function sideWidth()
    return sideSplit and sideSplit.width() or SIDE
end

--- Put the tree and the main column side by side, the tree as wide as
-- it was dragged to.
local function placeTree()
    local w = treeSplit and treeSplit.width() or TREE
    gitgud.setProperty("WikiTree", "Area", string.format("{{0,0},{0,0},{0,%d},{1,0}}", w))
    gitgud.setProperty("WikiMain", "Area", string.format("{{0,%d},{0,0},{1,0},{1,0}}", w))
    if treeSplit then
        treeSplit.place(w, 0, 0)
    end
end

--- Show the side panel beside a page when it's wanted and there's room.
-- @return whether it shows
local function placeSide()
    local _, _, mainW = gitgud.getRect("WikiMain")
    local w = sideWidth()
    local side = view == "page" and page ~= nil and not editing and state ~= "error"
        and (mainW or 1000) - w >= PAGE_LEAST
    gitgud.setVisible("WikiSideBox", side)
    gitgud.setProperty("WikiSideBox", "Area", string.format("{{1,%d},{0,56},{1,0},{1,0}}", -w))
    gitgud.setProperty("WikiPage", "Area", side and string.format("{{0,0},{0,56},{1,%d},{1,0}}", -w)
        or "{{0,0},{0,56},{1,0},{1,0}}")
    if sideSplit then
        if side then
            sideSplit.place(w, 56, 0)
        else
            sideSplit.hide()
        end
    end
    return side
end

local function show()
    if shell.view() == "wiki" then
        build()
    end
end

local function fail(message)
    state = "error"
    problem = message
    show()
end

local function canWrite()
    return open ~= nil and open.can_write == true and server.info().signedIn
end

--- The open wiki's page by sub_url, from the list.
local function pageEntry(sub)
    for _, p in ipairs(pages) do
        if p.sub_url == sub then
            return p
        end
    end
    return nil
end

--- What links where, from the store's links answer.
local function readLinks(value)
    local data = { pages = {}, bySub = {}, back = {}, count = 0, missing = {} }
    if type(value) ~= "table" or type(value.pages) ~= "table" then
        return data
    end
    data.pages = value.pages
    local missingByKey = {}
    for _, p in ipairs(value.pages) do
        data.bySub[p.sub_url] = p
        for _, l in ipairs(p.links or {}) do
            data.count = data.count + 1
            local list = data.back[l.sub_url] or {}
            list[#list + 1] = { sub_url = p.sub_url, title = p.title, context = l.context }
            data.back[l.sub_url] = list
        end
        for _, m in ipairs(p.missing or {}) do
            data.count = data.count + 1
            local key = wikilinks.key(m.title)
            local entry = missingByKey[key]
            if not entry then
                entry = { title = m.title, from = {} }
                missingByKey[key] = entry
                data.missing[#data.missing + 1] = entry
            end
            entry.from[#entry.from + 1] = p.sub_url
        end
    end
    return data
end

-- ===================================================================
-- The tree
-- ===================================================================

local function icon(image, colour, size)
    size = size or 14
    return "[colour='" .. colour .. "'][image-size='w:" .. size .. " h:" .. size
        .. "'][vert-formatting='CentreAligned'][image='" .. image .. "']"
end

local function paintTree()
    rows = {}
    local items = {}
    local selected = nil
    if hits then
        for _, hit in ipairs(hits) do
            rows[#rows + 1] = { kind = "hit", hit = hit }
            items[#items + 1] = text.escape(hit.title or hit.sub_url or "")
                .. "  [colour='" .. C.sub .. "']" .. text.escape(hit.repo or "")
        end
        if #hits == 0 then
            rows[#rows + 1] = { kind = "none" }
            items[#items + 1] = "[colour='" .. C.sub .. "']No pages match"
        end
    else
        rows[#rows + 1] = { kind = "none" }
        items[#items + 1] = "[font='Bragi-Caps'][colour='" .. C.sub .. "'] WIKIS"
        local now = os.time()
        for _, w in ipairs(wikis) do
            local isOpen = open and w.repo == open.repo
            rows[#rows + 1] = { kind = "wiki", wiki = w }
            local item = " " .. icon(w.shared and "Bragi-Icons/Wiki" or "Bragi-Icons/Folder", w.shared and C.accent or C.add, 16)
                .. "  [font='Bragi-14-Bold'][colour='" .. (isOpen and C.text or C.sub) .. "']"
                .. text.escape(parts.wikiName(w))
            if isOpen then
                item = item .. "   [font='Bragi-12'][colour='" .. C.disabled .. "']" .. #pages
            end
            items[#items + 1] = item
            if isOpen and view == "home" and not page then
                selected = #rows
            end
            if isOpen then
                for _, p in ipairs(pages) do
                    rows[#rows + 1] = { kind = "page", page = p }
                    local on = page and p.sub_url == page.sub_url
                    local last = p.last_commit
                    local fresh = last and last.created and now - last.created < FRESH and parts.byBragi(last.author)
                    local folder, name = parts.treeLabel(p)
                    items[#items + 1] = "      "
                        .. icon("Bragi-Panel/File", on and C.accent or C.disabled, 14) .. "  [font='Bragi-14']"
                        .. (folder and ("[colour='" .. C.disabled .. "']" .. text.escape(folder) .. " / ") or "")
                        .. "[colour='" .. (on and C.text or C.sub) .. "']" .. text.escape(name)
                        .. (fresh and ("  [colour='" .. C.accent .. "']\u{2022}") or "")
                    if on then
                        selected = #rows
                    end
                end
            end
        end
    end
    gitgud.setList("WikiPages", items)
    gitgud.selectListItem("WikiPages", selected, false)
end

-- ===================================================================
-- The top bar
-- ===================================================================

local function paintTabs()
    local shown = open ~= nil and not editing and (page ~= nil or view == "graph") and view ~= "home"
    gitgud.setVisible("WikiTabs", shown)
    for _, t in ipairs(TABS) do
        local name = "WikiTab_" .. t.id
        local active = t.id == view
        gitgud.setEnabled(name, t.id == "graph" or page ~= nil)
        gitgud.setProperty(name, "NormalFillColour", active and C.sel or C.transparent)
        gitgud.setProperty(name, "HoverFillColour", active and C.sel or C.hover)
        gitgud.setProperty(name, "NormalTextColour", active and C.accentText or C.sub)
        gitgud.setProperty(name, "HoverTextColour", active and C.accentText or C.text)
    end
end

--- Lay out the top bar for its width, right to left: search (a box, or
-- just its icon when narrow), Ask Bragi, Edit, the tabs; the breadcrumb
-- takes what's left, cut short when it must be.
local function paintHeader(crumbs)
    local _, _, w = gitgud.getRect("WikiMain")
    w = w or 1000
    local wide = w >= SEARCH_FROM
    local function place(name, right, width)
        gitgud.setProperty(name, "Area", string.format("{{1,%d},{0,10},{1,%d},{0,46}}", -(right + width), -right))
        return right + width
    end
    local right = place("WikiSearch", CONTROLS, wide and SEARCH_W or 40)
    gitgud.setVisible("WikiSearchLabel", wide)
    gitgud.setVisible("WikiSearchKey", wide)
    gitgud.setVisible("WikiSearchIcon", not wide)
    right = place("WikiAskBragi", right + 12, 164)
    if gitgud.getProperty("WikiEdit", "Visible") ~= "false" then
        right = place("WikiEdit", right + 8, 68)
    end
    if gitgud.getProperty("WikiTabs", "Visible") ~= "false" then
        gitgud.setProperty("WikiTabs", "Area", string.format("{{1,%d},{0,9},{1,%d},{0,47}}", -(right + 12 + 240),
            -(right + 12)))
        right = right + 12 + 240
    end
    local room = math.max(40, w - right - 12 - 24)
    gitgud.setProperty("WikiCrumbs", "Area", string.format("{{0,24},{0,0},{0,%d},{1,0}}", 24 + room))
    gitgud.setText("WikiCrumbs", text.escape(rowsUi.fitText("Bragi-13", crumbs, room)))
end

local function paintButtons()
    local onPage = page ~= nil and view ~= "home"
    gitgud.setVisible("WikiEdit", editing or onPage)
    gitgud.setEnabled("WikiEdit", editing or (onPage and canWrite()))
    gitgud.setEnabled("WikiNewPage", not editing and canWrite())
    gitgud.setEnabled("WikiAskBragi", editing or open ~= nil)
    gitgud.setText("WikiEdit", editing and "Save" or "Edit")
    gitgud.setText("WikiAskBragi", editing and "Cancel" or (onPage and "Ask Bragi to update" or "Ask Bragi"))
    local crumbs = "Wiki"
    if open then
        crumbs = parts.wikiName(open)
        if page and view ~= "home" then
            for part in ((page.sub_url or ""):match("^(.*)/") or ""):gmatch("[^/]+") do
                crumbs = crumbs .. "  /  " .. part:gsub("%-", " ")
            end
            crumbs = crumbs .. "  /  " .. (page.title or "")
        elseif view == "graph" then
            crumbs = crumbs .. "  /  Graph"
        end
    end
    paintTabs()
    paintHeader(crumbs)
end

-- ===================================================================
-- Loading
-- ===================================================================

local function loadRevisions(sub)
    local repo = open.repo
    server.request("GET", "/api/v1/repos/" .. repo .. "/wiki/revisions/" .. sub, nil, function(value)
        if not open or open.repo ~= repo or not page or page.sub_url ~= sub then
            return
        end
        revisions = { sub = sub, commits = type(value) == "table" and value.commits or {} }
        show()
    end, function()
        revisions = { sub = sub, commits = {} }
    end)
end

--- The open wiki's links and latest changes (for the front page, the
-- side panel, and the graph). A store without them just leaves them out.
local function loadExtras()
    local w = open
    server.request("GET", API .. "/repos/" .. w.repo .. "/wiki/links", nil, function(value)
        if open ~= w then
            return
        end
        linkData = readLinks(value)
        show()
    end, function()
        linkData = readLinks(nil)
    end)
    server.request("GET", API .. "/repos/" .. w.repo .. "/wiki/activity?limit=12", nil, function(value)
        if open ~= w then
            return
        end
        activity = type(value) == "table" and value or {}
        show()
    end, function()
        activity = {}
    end)
end

--- Open page `subUrl` of the open wiki (in the Page tab, unless the Graph or
-- History tab is showing).
function wiki.openPage(subUrl)
    if not open then
        return
    end
    local repo = open.repo
    if view == "home" then
        view = "page"
    end
    state = "loading"
    show()
    server.request("GET", API .. "/repos/" .. repo .. "/wiki/page/" .. subUrl .. "?html=false", nil, function(value)
        if not open or open.repo ~= repo then
            return
        end
        if type(value) ~= "table" then
            fail("No page came back.")
            return
        end
        local same = page and page.sub_url == (value.sub_url or subUrl)
        page = value
        page.sub_url = page.sub_url or subUrl
        if not same then
            revisions = nil
            wikihistory.reset()
        end
        if view == "home" then
            view = "page"
        end
        state = "ready"
        paintTree()
        show()
        loadRevisions(page.sub_url)
    end, fail)
end

--- Open a wiki: list its pages, then show its front page (or `subUrl`).
function wiki.openWiki(w, subUrl)
    local same = open ~= nil and open.repo == w.repo
    open = w
    page = nil
    if not same then
        pages, linkData, activity = {}, nil, nil
        wikigraph.reset()
        wikihistory.reset()
    end
    revisions = nil
    if not subUrl then
        view = "home"
    end
    state = "loading"
    paintTree()
    show()
    server.request("GET", API .. "/repos/" .. w.repo .. "/wiki/pages?limit=50", nil, function(value)
        if open ~= w then
            return
        end
        pages = type(value) == "table" and value or {}
        table.sort(pages, function(a, b)
            return (a.sub_url or ""):lower() < (b.sub_url or ""):lower()
        end)
        paintTree()
        loadExtras()
        if subUrl then
            wiki.openPage(subUrl)
        else
            state = "ready"
            show()
        end
    end, fail)
end

--- Show the open wiki's front page.
function wiki.openHome()
    if open then
        page, revisions, view = nil, nil, "home"
        paintTree()
        show()
    end
end

--- Show a tab: "page", "graph", or "history".
function wiki.setView(v)
    if editing or not open then
        return
    end
    if v ~= "graph" and not page then
        return
    end
    view = v
    paintTree()
    show()
end

--- List the readable wikis and open the first (the shared one first).
function wiki.load()
    hits = nil
    if not server.info().signedIn then
        wikis, open, page, pages, state = {}, nil, nil, {}, "idle"
        paintTree()
        show()
        return
    end
    state = "loading"
    show()
    server.request("GET", API .. "/wikis?limit=50", nil, function(value)
        wikis = type(value) == "table" and value or {}
        if #wikis == 0 then
            open, page, pages = nil, nil, {}
            state = "ready"
            paintTree()
            show()
            return
        end
        local keep = nil
        for _, w in ipairs(wikis) do
            if open and w.repo == open.repo then
                keep = w
            end
        end
        wiki.openWiki(keep or wikis[1], keep and page and page.sub_url or nil)
    end, fail)
end

--- Fetch the list of wikis again and repaint the tree, leaving the open
-- page as it is. A wiki can appear with no event to say so (an agent
-- commits straight into bragi/wikis/<id>.wiki.git), so the view asks
-- each time it's shown.
local function refreshList()
    server.request("GET", API .. "/wikis?limit=50", nil, function(value)
        if type(value) ~= "table" then
            return
        end
        wikis = value
        if not open and #wikis > 0 then
            wiki.openWiki(wikis[1])
            return
        end
        paintTree()
    end)
end

local function search(q)
    if q == "" then
        hits = nil
        paintTree()
        return
    end
    server.request("GET", API .. "/wikis/search?limit=50&q=" .. encode(q), nil, function(value)
        if text.trim(gitgud.getText("WikiFindEdit") or "") ~= q then
            return -- typed on since
        end
        hits = type(value) == "table" and value or {}
        paintTree()
    end, function(msg)
        status.error(msg)
    end)
end

-- ===================================================================
-- Editing
-- ===================================================================

local function stopEditing()
    editing = false
    show()
end

local function save()
    local body = gitgud.getText("WikiEditor") or ""
    local repo, target = open.repo, page
    server.request("PATCH", "/api/v1/repos/" .. repo .. "/wiki/page/" .. target.sub_url, {
        title = target.title, -- without it the page is renamed "unnamed"
        content_base64 = wiki.base64(body),
        message = "Update " .. (target.title or target.sub_url),
    }, function()
        status.ok("Saved " .. (target.title or "the page") .. ".")
        editing = false
        if open and open.repo == repo then
            wiki.openPage(target.sub_url)
        end
    end, function(msg)
        status.error(msg) -- still editing: nothing typed is lost
    end)
end

--- Make a page and open it; with `content`, straight away, else after
-- asking for a title (`title` filled in).
function wiki.newPage(title, content)
    if not canWrite() then
        return
    end
    local repo = open.repo
    local function create(name)
        server.request("POST", "/api/v1/repos/" .. repo .. "/wiki/new", {
            title = name,
            content_base64 = wiki.base64(content or ("# " .. name .. "\n")),
            message = "Add " .. name,
        }, function(created)
            local subUrl = created and created.sub_url or name:gsub(" ", "-")
            if open and open.repo == repo then
                view = "page"
                wiki.openWiki(open, subUrl)
            end
        end, function(msg)
            status.error(msg)
        end)
    end
    if content then
        create(title)
        return
    end
    dialog.prompt("New page", "Title", title or "", "Create", function(name)
        if name == "" then
            return false, "Give the page a title."
        end
        create(name)
        return true
    end)
end

--- Put a request into the Agent view's prompt.
function wiki.askBragi(draft)
    shell.show("agent")
    placeholder.setText("AgentPromptEdit", draft)
    gitgud.focus("AgentPromptEdit")
end

local function wikiPhrase()
    return open.shared and "the shared wiki (" .. open.repo .. ")" or open.repo .. "'s wiki"
end

local function askBragi()
    if page and view ~= "home" then
        wiki.askBragi("Update the wiki page \"" .. (page.title or page.sub_url) .. "\" in " .. wikiPhrase() .. ": ")
    else
        wiki.askBragi("In " .. wikiPhrase() .. ", ")
    end
end

--- Save an old version's text as the page's newest.
function wiki.restore(commit, content)
    if not (page and canWrite()) then
        return
    end
    local repo, target = open.repo, page
    local short = (commit.sha or ""):sub(1, 7)
    server.request("PATCH", "/api/v1/repos/" .. repo .. "/wiki/page/" .. target.sub_url, {
        title = target.title,
        content_base64 = wiki.base64(content or ""),
        message = "Restore " .. (target.title or target.sub_url) .. " to " .. short,
    }, function()
        status.ok("Restored " .. (target.title or "the page") .. ".")
        wikihistory.reset()
        if open and open.repo == repo then
            wiki.openPage(target.sub_url)
        end
    end, function(msg)
        status.error(msg)
    end)
end

-- ===================================================================
-- Drawing
-- ===================================================================

local function note(root, width, title, body, button, action)
    ui.label(root .. "Title", root, { 32, 32, width, 40 }, title, { font = "Bragi-32-Bold" })
    ui.paragraph(root .. "Text", root, { 32, 88, width, 80 }, body, { font = "Bragi-16", colour = C.sub })
    local height = 200
    if button then
        local b = ui.button(root .. "Button", root, { 32, 172, 180, 36 }, button, { primary = true })
        gitgud.on(b .. ".clicked", action)
        height = 240
    end
    parts.size(root, width + 64, height)
end

--- Where a [[link]] in the open page goes (for bragi/markdown.lua).
local function wikiLink(name)
    local index = wikilinks.index(pages)
    local sub = wikilinks.resolve(index, name)
    if sub then
        local p = pageEntry(sub)
        return { kind = "wiki", target = sub, sub_url = sub, tooltip = "Open " .. (p and p.title or name) }
    end
    return { kind = "wiki", target = name, missing = true,
        tooltip = canWrite() and ("No page called " .. name .. " yet: click to make it") or ("No page called " .. name) }
end

local function openLink(link)
    if link.missing then
        wiki.newPage(link.target)
    elseif link.sub_url then
        wiki.openPage(link.sub_url)
    end
end

--- The page itself: who changed it last, how many versions, then the text.
local function drawPage(root, width)
    local x, y = 32, 26
    local last = page.last_commit
    local entry = linkData and linkData.bySub[page.sub_url]
    if last and last.author then
        x = x + parts.chip(root .. "Who", root, x, y, "Updated by " .. last.author
            .. (last.created and (", " .. parts.when(last.created)) or ""), { author = last.author }) + 8
    end
    if revisions and revisions.sub == page.sub_url and #revisions.commits > 0 then
        x = x + parts.chip(root .. "Versions", root, x, y, text.plural(#revisions.commits, "version")) + 8
    end
    if entry and entry.words then
        parts.chip(root .. "Read", root, x, y, math.max(1, (entry.words + READ_WPM // 2) // READ_WPM) .. " min read")
    end
    y = y + 44

    local blocks = markdown.parse(page.content or "")
    -- A page that doesn't start with a heading gets its title as one.
    if not (blocks[1] and blocks[1].kind == "heading" and blocks[1].level == 1) then
        table.insert(blocks, 1, { kind = "heading", level = 1, text = page.title or page.sub_url })
    end
    local height = markdown.render(blocks, root, root .. "Md", { x = 32, y = y, width = width, wiki = wikiLink })
    parts.size(root, width + 64, y + height + 64)
end

--- Beside a page: the pages that link to it, and its latest versions.
local function drawSide()
    if sideBuilt > 0 then
        gitgud.destroyWindow("WikiSideBody" .. sideBuilt)
    end
    sideBuilt = sideBuilt + 1
    local root = "WikiSideBody" .. sideBuilt
    gitgud.createWindow("DefaultWindow", root, "WikiSide")
    local sideW = sideWidth()
    local width = sideW - 1 - 36
    local x, y = 18, 22

    local back = linkData and linkData.back[page.sub_url] or {}
    parts.heading(root .. "BackHead", root, x, y, width, "Linked from", linkData and #back or nil)
    y = y + 28
    if not linkData then
        ui.label(root .. "BackWait", root, { x, y, width, 20 }, "Looking\u{2026}", { font = "Bragi-13", colour = C.sub })
        y = y + 30
    elseif #back == 0 then
        ui.paragraph(root .. "BackNone", root, { x, y, width, 60 },
            "No pages link here yet. Write [[" .. (page.title or page.sub_url) .. "]] in another page to link to it.",
            { font = "Bragi-13", colour = C.sub })
        y = y + 64
    end
    for i, b in ipairs(back) do
        local item = root .. "Back" .. i
        local sub = b.sub_url
        parts.spot(item, root, { x - 8, y, width + 16, 58 }, function()
            wiki.openPage(sub)
        end, { tooltip = "Open " .. (b.title or sub) })
        gitgud.createWindow("Gitgud/Icon", item .. "Icon", item)
        gitgud.setProperty(item .. "Icon", "Area", string.format("{{0,8},{0,9},{0,22},{0,23}}"))
        gitgud.setProperty(item .. "Icon", "IconImage", "Bragi-Panel/File")
        gitgud.setProperty(item .. "Icon", "IconColour", C.sub)
        gitgud.setProperty(item .. "Icon", "GlowColour", C.transparent)
        gitgud.setProperty(item .. "Icon", "CursorPassThroughEnabled", "true")
        ui.label(item .. "Title", item, { 30, 6, width - 30, 20 }, b.title or sub,
            { font = "Bragi-14-Bold", colour = C.link })
        local context = markdown.plain(b.context or ""):gsub("^#+%s*", ""):gsub("^[%-%*%+]%s+", "")
            :gsub("^%d+[%.%)]%s+", "")
        ui.paragraph(item .. "Context", item, { 30, 26, width - 30, 32 }, context, { font = "Bragi-12", colour = C.sub })
        y = y + 62
    end

    y = y + 18
    local commits = revisions and revisions.sub == page.sub_url and revisions.commits or nil
    parts.heading(root .. "HistHead", root, x, y, width, "History", commits and #commits or nil)
    y = y + 30
    if not commits then
        ui.label(root .. "HistWait", root, { x, y, width, 20 }, "Looking\u{2026}", { font = "Bragi-13", colour = C.sub })
        y = y + 30
    else
        local shown = math.min(#commits, HISTORY_SHOWN)
        for i = 1, shown do
            local c = commits[i]
            local item = root .. "Hist" .. i
            local sha = c.sha
            if i < shown then
                ui.rule(item .. "Line", root, { x + 9, y + 22, 1, 30 })
            end
            parts.spot(item, root, { x - 8, y - 4, width + 16, 48 }, function()
                wikihistory.select(sha)
                wiki.setView("history")
            end, { tooltip = "See this version" })
            parts.avatar(item .. "Who", item, 8, 4, 20, c.author and c.author.name)
            ui.label(item .. "Message", item, { 38, 2, width - 34, 20 },
                rowsUi.fitText("Bragi-13", parts.summary(c.message), width - 40), { font = "Bragi-13", colour = C.text })
            local who = (c.author and c.author.name or "")
            ui.label(item .. "When", item, { 38, 21, width - 34, 18 },
                parts.capital(parts.when(c.created)) .. (who ~= "" and ("  \u{00B7}  " .. who) or ""),
                { font = "Bragi-12", colour = C.disabled })
            y = y + 52
        end
        if #commits > 0 then
            local all = ui.button(root .. "HistAll", root, { x - 8, y, width + 16, 30 },
                #commits > 1 and "See all versions and what changed" or "See this version", {
                    quiet = true, font = "Bragi-13", colour = C.link, align = "LeftAligned" })
            gitgud.on(all .. ".clicked", function()
                wiki.setView("history")
            end)
            y = y + 36
        end
    end
    parts.size(root, sideW - 1, y + 24)
end

local function context(root, width, height)
    return {
        root = root, width = width, height = height,
        open = open, pages = pages, page = page, links = linkData, activity = activity,
        revisions = revisions and page and revisions.sub == page.sub_url and revisions.commits or nil,
        canWrite = canWrite(), wikiName = parts.wikiName(open),
        openPage = wiki.openPage, openHome = wiki.openHome, setView = wiki.setView, newPage = wiki.newPage,
        askBragi = wiki.askBragi, wikiPhrase = wikiPhrase, restore = wiki.restore, request = server.request,
        show = show,
    }
end

local editorMade = false

build = function()
    placeTree()
    paintButtons()
    local _, _, mainW, mainH = gitgud.getRect("WikiMain")
    mainW, mainH = mainW or 1000, mainH or 700
    local side = placeSide()
    if editing then
        -- The editor sizes itself; a rebuild (a resize) keeps what's typed.
        if not editorMade then
            editorMade = true
            gitgud.setVisible("WikiPage", false)
            gitgud.createWindow("Gitgud/MultiLineEditbox", "WikiEditor", "WikiMain")
            gitgud.setProperty("WikiEditor", "Area", "{{0,24},{0,72},{1,-24},{1,-16}}")
            gitgud.setProperty("WikiEditor", "Font", "Bragi-Mono-13")
            gitgud.setText("WikiEditor", page.content or "")
            gitgud.focus("WikiEditor")
        end
        return
    end
    if editorMade then
        editorMade = false
        gitgud.destroyWindow("WikiEditor")
    end
    gitgud.setVisible("WikiPage", true)

    if built > 0 then
        gitgud.destroyWindow("WikiBody" .. built)
    end
    built = built + 1
    local pageW = mainW - (side and sideWidth() or 0)
    local pageH = mainH - 56
    local width = math.min(760, pageW - 64)

    local root = "WikiBody" .. built
    gitgud.createWindow("DefaultWindow", root, "WikiPage")

    if not server.info().signedIn then
        note(root, width, "Wikis are coming",
            "Each project will have a wiki on this computer, plus one shared wiki for everything else. "
                .. "They aren't in this build yet.")
        return
    end
    if state == "error" then
        note(root, width, "The page couldn't be loaded", problem or "", "Try again", wiki.load)
        return
    end
    if not open then
        if state == "loading" then
            note(root, width, "Wiki", "One moment.")
        else
            note(root, width, "No wikis yet",
                "The shared wiki and each project's wiki show here once they have a page.")
        end
        return
    end
    if view == "graph" then
        wikigraph.draw(context(root, pageW, pageH))
        return
    end
    if view == "home" or not page then
        if state == "loading" and #pages == 0 then
            note(root, width, parts.wikiName(open), "One moment.")
            return
        end
        wikihome.draw(context(root, pageW, pageH))
        return
    end
    if view == "history" then
        wikihistory.draw(context(root, pageW, pageH))
        return
    end
    drawPage(root, width)
    if side then
        drawSide()
    end
end

--- The open page and wiki, the view, and the listed wikis, for scripts and tests.
function wiki.current()
    return page, open, view, wikis
end

function wiki.init()
    placeholder.bind("WikiFindEdit", "WikiFindPlaceholder")
    gitgud.setList("WikiPages", {})
    gitgud.on("WikiSearch.clicked", commands.open)
    gitgud.createWindow("Gitgud/Icon", "WikiSearchIcon", "WikiSearch")
    gitgud.setProperty("WikiSearchIcon", "Area", "{{0.5,-9},{0.5,-9},{0.5,9},{0.5,9}}")
    gitgud.setProperty("WikiSearchIcon", "IconImage", "Bragi-Icons/Search")
    gitgud.setProperty("WikiSearchIcon", "IconColour", C.sub)
    gitgud.setProperty("WikiSearchIcon", "GlowColour", C.transparent)
    gitgud.setProperty("WikiSearchIcon", "CursorPassThroughEnabled", "true")
    gitgud.setVisible("WikiSearchIcon", false)
    links.onWiki(openLink)

    for i, t in ipairs(TABS) do
        local name = "WikiTab_" .. t.id
        ui.button(name, "WikiTabs", { 3 + (i - 1) * 78, 3, 76, 32 }, t.label, { quiet = true, font = "Bragi-13-Bold" })
        local id = t.id
        gitgud.on(name .. ".clicked", function()
            wiki.setView(id)
        end)
    end

    gitgud.on("WikiPages.selected", function(value)
        local row = rows[(tonumber(value) or -1) + 1]
        if not row or editing then
            return
        end
        if row.kind == "wiki" then
            if not open or row.wiki.repo ~= open.repo then
                wiki.openWiki(row.wiki)
            else
                wiki.openHome()
            end
        elseif row.kind == "page" then
            wiki.openPage(row.page.sub_url)
        elseif row.kind == "hit" then
            local hit = row.hit
            placeholder.setText("WikiFindEdit", "")
            hits = nil
            for _, w in ipairs(wikis) do
                if w.repo == hit.repo then
                    if view == "home" then
                        view = "page"
                    end
                    if open and open.repo == w.repo then
                        paintTree()
                        wiki.openPage(hit.sub_url)
                    else
                        wiki.openWiki(w, hit.sub_url)
                    end
                end
            end
        else
            paintTree() -- a heading: keep the selection where it was
        end
    end)
    gitgud.on("WikiFindEdit.changed", function(value)
        if searchTimer then
            gitgud.cancelTimer(searchTimer)
        end
        local q = text.trim(value or "")
        searchTimer = gitgud.after(350, function()
            searchTimer = nil
            search(q)
        end)
    end)

    gitgud.on("WikiEdit.clicked", function()
        if editing then
            save()
        elseif page and canWrite() then
            editing = true
            view = "page"
            show()
        end
    end)
    gitgud.on("WikiAskBragi.clicked", function()
        if editing then
            stopEditing()
        elseif open then
            askBragi()
        end
    end)
    gitgud.on("WikiNewPage.clicked", function()
        if canWrite() then
            wiki.newPage()
        end
    end)

    app.subscribe("bragi.view", function(v)
        if v == "wiki" then
            if state == "idle" and server.info().signedIn then
                wiki.load()
            else
                build()
                if state == "ready" and not editing and server.info().signedIn then
                    refreshList()
                end
            end
        end
    end)
    local signedAs = nil
    app.subscribe("bragi.server", function(info)
        local now = info.signedIn and (info.url .. " " .. info.user) or ""
        if now == signedAs then
            return
        end
        signedAs = now
        wikis, open, page, pages, hits, editing, state = {}, nil, nil, {}, nil, false, "idle"
        view, linkData, activity, revisions = "home", nil, nil, nil
        paintTree()
        if shell.view() == "wiki" then
            if info.signedIn then
                wiki.load()
            else
                build()
            end
        end
    end)
    app.subscribe("bragi.serverEvent", function(event)
        if event.type == "feed.reset" then
            if not editing and state ~= "idle" then
                wiki.load()
            end
        elseif event.type == "wiki.page.updated" and open and event.repo == open.repo and not editing then
            wiki.openWiki(open, page and view ~= "home" and page.sub_url or nil)
        end
    end)
    gitgud.on("window.resized", show)

    -- The tree's right edge and the side panel's left edge drag; their
    -- widths are remembered. The page is drawn again for the new width
    -- when the drag pauses or ends.
    local splitter = require("ui.splitter")
    treeSplit = splitter.column({
        name = "WikiTreeSplit", parent = "WikiRoot", pane = "WikiTree", edge = "left",
        key = "bragi.wikiTreeWidth", default = TREE, min = TREE_MIN,
        max = function()
            -- Widening it never pushes the side panel off.
            local _, _, w = gitgud.getRect("WikiRoot")
            local rest = gitgud.getProperty("WikiSideBox", "Visible") == "true"
                and sideWidth() + PAGE_LEAST or MAIN_LEAST
            return math.min(TREE_MAX, (w or 1200) - rest)
        end,
        relayout = function()
            placeTree()
            placeSide()
        end,
        done = show,
    })
    sideSplit = splitter.column({
        name = "WikiSideSplit", parent = "WikiMain", pane = "WikiSideBox", edge = "right",
        key = "bragi.wikiSideWidth", default = SIDE, min = SIDE_MIN,
        max = function()
            local _, _, w = gitgud.getRect("WikiMain")
            return math.min(SIDE_MAX, (w or 1000) - PAGE_LEAST)
        end,
        relayout = placeSide,
        done = show,
    })
    placeTree()
    paintButtons()
end

return wiki
