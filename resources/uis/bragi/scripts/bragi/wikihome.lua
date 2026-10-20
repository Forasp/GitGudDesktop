--- bragi/wikihome.lua: a wiki's front page, for bragi/wiki.lua.
--
-- With pages: the wiki's name and what it's for (the first paragraph of its
-- Home page, when it has one), counts, the pages changed last as cards
-- (Home first), and beside them the wiki's latest changes and the links
-- that point to pages that don't exist yet, with a way to have Bragi write
-- them. Without pages: ways to start one (Bragi drafts it, a blank page,
-- or a starter page).
--
--   wikihome.draw(ctx)   ctx from wiki.lua: root, width, height, open,
--                        pages, links, activity, canWrite, and actions

local C = require("core.palette")
local parts = require("bragi.wikiparts")
local rows = require("bragi.rows")
local text = require("core.text")
local ui = require("bragi.ui")

local wikihome = {}

local PAD = 32
local SIDE = 290          -- the activity column
local SIDE_FROM = 900     -- narrowest width that has it beside the cards
local CARD_W = 240        -- narrowest card
local CARD_H = 138
local GAP = 14
local MAX_CARDS = 9
local MAX_ACTIVITY = 6

local STARTERS = {
    { title = "Overview", blurb = "What this is, who it's for, where things live.",
        body = "# Overview\n\nWhat this is, and who it's for.\n\n## Where things live\n\n- \n\n## See also\n\n"
            .. "- [[How to build]]\n- [[Decisions log]]\n" },
    { title = "How to build", blurb = "Steps to build, test and run, kept current.",
        body = "# How to build\n\n## Build\n\n```\n\n```\n\n## Test\n\n```\n\n```\n\n## Run\n\n" },
    { title = "Decisions log", blurb = "Dated notes: what was decided and why.",
        body = "# Decisions log\n\nNewest first: the date, what was decided, and why.\n\n## %s\n\n- \n" },
}

--- What the wiki is for: its Home page's first paragraph, else a default.
local function description(ctx)
    local home = ctx.links and ctx.links.bySub["Home"]
    if home and home.summary and home.summary ~= "" then
        return home.summary
    end
    if ctx.open.shared then
        return "Notes every project can read. Bragi keeps them up to date as you work."
    end
    return "Notes about " .. ctx.wikiName .. ": how it works, how to build it, what was decided."
end

--- Pages, changed last first; Home first of all.
local function recent(ctx)
    local list = {}
    for _, p in ipairs(ctx.pages) do
        list[#list + 1] = p
    end
    table.sort(list, function(a, b)
        if (a.sub_url == "Home") ~= (b.sub_url == "Home") then
            return a.sub_url == "Home"
        end
        local ta = a.last_commit and a.last_commit.created or 0
        local tb = b.last_commit and b.last_commit.created or 0
        if ta ~= tb then
            return ta > tb
        end
        return (a.sub_url or "") < (b.sub_url or "")
    end)
    return list
end

local function latest(ctx)
    local t = nil
    for _, p in ipairs(ctx.pages) do
        local c = p.last_commit and p.last_commit.created
        if c and (not t or c > t) then
            t = c
        end
    end
    return t
end

--- The page a change's message names ("Update Voice-pipeline"), or nil.
local function pageOfMessage(ctx, message)
    local best = nil
    local lower = (message or ""):lower():gsub("%-", " ")
    for _, p in ipairs(ctx.pages) do
        local title = (p.title or ""):lower()
        local sub = (p.sub_url or ""):lower():gsub("%-", " ")
        if (title ~= "" and lower:find(title, 1, true)) or (sub ~= "" and lower:find(sub, 1, true)) then
            if not best or #(p.sub_url or "") > #(best.sub_url or "") then
                best = p
            end
        end
    end
    return best
end

local function card(name, parent, ctx, p, x, y, w)
    local sub = p.sub_url
    parts.spot(name, parent, { x, y, w, CARD_H }, function()
        ctx.openPage(sub)
    end, { radius = 12, fill = C.panel, border = C.border, tooltip = "Open " .. (p.title or sub) })
    local entry = ctx.links and ctx.links.bySub[sub]
    local pinned = sub == "Home"
    local titleW = w - 32 - (pinned and 60 or 0)
    ui.label(name .. "Title", name, { 16, 12, titleW, 22 }, rows.fitText("Bragi-15-Bold", p.title or sub, titleW),
        { font = "Bragi-15-Bold" })
    if pinned then
        ui.label(name .. "Pin", name, { w - 76, 12, 60, 22 }, "Pinned", { font = "Bragi-12-Bold", colour = C.accentText,
            align = "RightAligned" })
    end
    local summary = entry and entry.summary or ""
    if summary == "" then
        summary = ctx.links and "Nothing written yet." or ""
    end
    ui.paragraph(name .. "Summary", name, { 16, 38, w - 32, 58 }, summary, { font = "Bragi-13", colour = C.sub })
    local last = p.last_commit
    if last then
        parts.avatar(name .. "Who", name, 16, CARD_H - 30, 16, last.author)
        ui.label(name .. "When", name, { 38, CARD_H - 32, w - 140, 20 }, parts.capital(parts.when(last.created)),
            { font = "Bragi-12", colour = C.disabled })
    end
    local back = ctx.links and ctx.links.back[sub]
    if back and #back > 0 then
        ui.label(name .. "Back", name, { w - 136, CARD_H - 32, 120, 20 }, "linked from " .. #back,
            { font = "Bragi-12", colour = C.disabled, align = "RightAligned" })
    end
end

--- The wiki's latest changes, then its missing pages. Returns the bottom.
local function drawActivity(root, ctx, x, y, w)
    parts.heading(root .. "ActHead", root, x, y, w, "Activity")
    y = y + 26
    local list = ctx.activity or {}
    if not ctx.activity then
        ui.label(root .. "ActWait", root, { x, y, w, 20 }, "Looking\u{2026}", { font = "Bragi-13", colour = C.sub })
        y = y + 30
    end
    for i = 1, math.min(#list, MAX_ACTIVITY) do
        local c = list[i]
        local item = root .. "Act" .. i
        local p = pageOfMessage(ctx, c.message)
        if p then
            local sub = p.sub_url
            parts.spot(item, root, { x - 8, y, w + 16, 52 }, function()
                ctx.openPage(sub)
            end, { tooltip = "Open " .. (p.title or sub) })
        else
            ui.box(item, root, { x - 8, y, w + 16, 52 }, { radius = 8, fill = C.transparent, border = C.transparent })
        end
        parts.avatar(item .. "Who", item, 8, 8, 20, c.author)
        ui.label(item .. "Message", item, { 38, 6, w - 34, 20 },
            rows.fitText("Bragi-13", parts.summary(c.message), w - 40),
            { font = "Bragi-13", colour = p and C.text or C.sub })
        ui.label(item .. "When", item, { 38, 25, w - 34, 18 },
            parts.capital(parts.when(c.created)) .. (c.author and ("  \u{00B7}  " .. c.author) or ""),
            { font = "Bragi-12", colour = C.disabled })
        if i < math.min(#list, MAX_ACTIVITY) then
            ui.rule(item .. "Rule", root, { x, y + 52, w, 1 })
        end
        y = y + 53
    end

    local missing = ctx.links and ctx.links.missing or {}
    if #missing > 0 then
        y = y + 18
        local names = {}
        for i, m in ipairs(missing) do
            if i <= 3 then
                names[#names + 1] = "[colour='" .. C.warn .. "']" .. text.escape(m.title) .. "[colour='" .. C.sub .. "']"
            end
        end
        local list = #names == 1 and names[1] or (table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names])
        if #missing > 3 then
            list = table.concat(names, ", ") .. " and " .. (#missing - 3) .. " more"
        end
        local box = root .. "Missing"
        local h = ctx.canWrite and 150 or 112
        ui.card(box, root, { x, y, w, h })
        ui.label(box .. "Title", box, { 16, 14, w - 32, 20 },
            #missing == 1 and "1 page to write" or (#missing .. " pages to write"), { font = "Bragi-14-Bold" })
        local para = box .. "Text"
        gitgud.createWindow("Gitgud/StaticText", para, box)
        gitgud.setProperty(para, "Area", string.format("{{0,16},{0,38},{0,%d},{0,%d}}", w - 16, 98))
        gitgud.setProperty(para, "PanelColour", C.transparent)
        gitgud.setProperty(para, "HorzFormatting", "WordWrapLeftAligned")
        gitgud.setProperty(para, "VertFormatting", "TopAligned")
        gitgud.setProperty(para, "CursorPassThroughEnabled", "true")
        gitgud.setText(para, "[font='Bragi-13'][colour='" .. C.sub .. "']Links to " .. list
            .. " point to pages that don't exist yet.")
        if ctx.canWrite then
            local titles = {}
            for _, m in ipairs(missing) do
                titles[#titles + 1] = m.title
            end
            local b = ui.button(box .. "Ask", box, { 16, h - 50, w - 32, 34 }, "Ask Bragi to write them")
            gitgud.on(b .. ".clicked", function()
                ctx.askBragi("In " .. ctx.wikiPhrase() .. ", write the pages that other pages link to but that don't "
                    .. "exist yet: " .. table.concat(titles, ", ") .. ". ")
            end)
        end
        y = y + h
    end
    return y
end

local function drawPages(ctx)
    local root, W = ctx.root, ctx.width - parts.SCROLLBAR
    local besideCards = W >= SIDE_FROM
    local mainW = W - 2 * PAD - (besideCards and (SIDE + PAD) or 0)

    -- Title, what the wiki is for, counts; New page and Graph on the right.
    local buttonsW = ctx.canWrite and 236 or 112
    ui.label(root .. "Title", root, { PAD, 26, mainW - buttonsW - 12, 42 }, ctx.wikiName, { font = "Bragi-32-Bold" })
    if ctx.canWrite then
        local b = ui.button(root .. "New", root, { PAD + mainW - 236, 30, 120, 36 }, "+ New page", { primary = true })
        gitgud.on(b .. ".clicked", function()
            ctx.newPage()
        end)
    end
    local g = ui.button(root .. "Graph", root, { PAD + mainW - 108, 30, 108, 36 }, "Graph",
        { tooltip = "How the pages link" })
    gitgud.on(g .. ".clicked", function()
        ctx.setView("graph")
    end)
    local about = root .. "About"
    ui.paragraph(about, root, { PAD, 74, mainW, 44 }, description(ctx), { font = "Bragi-15", colour = C.sub })
    local extent = tonumber(gitgud.getProperty(about, "VertExtent") or "") or 22
    local y = 74 + math.max(22, math.ceil(extent)) + 12
    local x = PAD
    x = x + parts.chip(root .. "Count", root, x, y, text.plural(#ctx.pages, "page")) + 8
    if ctx.links then
        x = x + parts.chip(root .. "Links", root, x, y, text.plural(ctx.links.count, "link")) + 8
    end
    local t = latest(ctx)
    if t then
        parts.chip(root .. "Updated", root, x, y, "Updated " .. parts.when(t))
    end
    y = y + 48

    parts.heading(root .. "RecentHead", root, PAD, y, mainW, "Recently changed")
    y = y + 28
    local cols = math.max(1, math.min(3, (mainW + GAP) // (CARD_W + GAP)))
    local cardW = (mainW - (cols - 1) * GAP) // cols
    local list = recent(ctx)
    local shown = math.min(#list, MAX_CARDS)
    for i = 1, shown do
        local col = (i - 1) % cols
        local row = (i - 1) // cols
        card(root .. "Card" .. i, root, ctx, list[i], PAD + col * (cardW + GAP), y + row * (CARD_H + GAP), cardW)
    end
    local bottom = y + ((shown + cols - 1) // cols) * (CARD_H + GAP)
    if #list > shown then
        ui.label(root .. "More", root, { PAD, bottom, mainW, 20 },
            text.plural(#list - shown, "more page", "more pages") .. " in the list on the left", { font = "Bragi-13", colour = C.sub })
        bottom = bottom + 30
    end

    local sideBottom
    if besideCards then
        ui.rule(root .. "SideEdge", root, { W - SIDE - PAD // 2 - 8, 0, 1, math.max(ctx.height, bottom + PAD) })
        sideBottom = drawActivity(root, ctx, W - SIDE - 8, 30, SIDE - 24)
    else
        sideBottom = drawActivity(root, ctx, PAD, bottom + 16, math.min(mainW, 520))
    end
    parts.size(root, W, math.max(bottom, sideBottom) + PAD)
    if besideCards then
        gitgud.setProperty(root .. "SideEdge", "Area", string.format("{{0,%d},{0,0},{0,%d},{0,%d}}",
            W - SIDE - PAD // 2 - 8, W - SIDE - PAD // 2 - 7, math.max(ctx.height, bottom + PAD, sideBottom + PAD)))
    end
end

--- A wiki with no pages: how to start it.
local function drawEmpty(ctx)
    local root, W, H = ctx.root, ctx.width, ctx.height
    local w = math.min(560, W - 2 * PAD)
    local cardsW = math.min(3 * 220 + 2 * 12, W - 2 * PAD)
    local total = 112 + 24 + 36 + 70 + 56 + 60 + 96
    local top = math.max(28, (H - total) // 2)
    local cx = W // 2

    local mark = root .. "Mark"
    ui.box(mark, root, { cx - 56, top, 112, 112 }, { radius = 22, fill = C.panel, border = C.border })
    for _, piece in ipairs({ { "Petals", "Bragi-Icons/MarkPetalsLarge", C.petal },
        { "Centre", "Bragi-Icons/MarkCentreLarge", C.logoCentre } }) do
        local icon = mark .. piece[1]
        gitgud.createWindow("Gitgud/Icon", icon, mark)
        gitgud.setProperty(icon, "Area", "{{0,24},{0,24},{0,88},{0,88}}")
        gitgud.setProperty(icon, "IconImage", piece[2])
        gitgud.setProperty(icon, "IconColour", piece[3])
        gitgud.setProperty(icon, "GlowColour", C.transparent)
        gitgud.setProperty(icon, "CursorPassThroughEnabled", "true")
    end
    local y = top + 112 + 22
    ui.label(root .. "Title", root, { cx - w // 2, y, w, 36 }, "Start " .. (ctx.open.shared and "the shared wiki"
        or (ctx.wikiName .. "'s wiki")), { font = "Bragi-20-Bold", align = "CentreAligned" })
    y = y + 42
    local about = root .. "About"
    gitgud.createWindow("Gitgud/StaticText", about, root)
    gitgud.setProperty(about, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}", cx - w // 2, y, cx + w // 2, y + 64))
    gitgud.setProperty(about, "PanelColour", C.transparent)
    gitgud.setProperty(about, "HorzFormatting", "WordWrapCentreAligned")
    gitgud.setProperty(about, "VertFormatting", "TopAligned")
    gitgud.setProperty(about, "CursorPassThroughEnabled", "true")
    gitgud.setText(about, "[font='Bragi-15'][colour='" .. C.sub .. "']A place for what Bragi and you learn: how things "
        .. "work, how to build, what was decided. Pages link to each other with [font='Bragi-Mono-13'][colour='"
        .. C.accentText .. "']" .. text.escape("[[Page name]]") .. "[font='Bragi-15'][colour='" .. C.sub .. "'], and every change is kept.")
    y = y + 76

    if ctx.canWrite then
        local askW, blankW = 270, 120
        local bx = cx - (askW + 10 + blankW) // 2
        local ask = ui.button(root .. "Ask", root, { bx, y, askW, 40 }, "Ask Bragi to draft the first pages",
            { primary = true })
        gitgud.on(ask .. ".clicked", function()
            ctx.askBragi("Start " .. ctx.wikiPhrase() .. ": write its first few pages from what you know, and link "
                .. "them to each other with [[Page name]] links. ")
        end)
        local blank = ui.button(root .. "Blank", root, { bx + askW + 10, y, blankW, 40 }, "Blank page")
        gitgud.on(blank .. ".clicked", function()
            ctx.newPage()
        end)
        y = y + 40 + 34

        ui.label(root .. "Or", root, { cx - 150, y, 300, 18 }, "OR START FROM",
            { font = "Bragi-Caps", colour = C.sub, align = "CentreAligned" })
        y = y + 28
        local each = (cardsW - 2 * 12) // 3
        local x0 = cx - cardsW // 2
        for i, s in ipairs(STARTERS) do
            local name = root .. "Starter" .. i
            local starter = s
            parts.spot(name, root, { x0 + (i - 1) * (each + 12), y, each, 84 }, function()
                ctx.newPage(starter.title, starter.body:format(os.date("%Y-%m-%d")))
            end, { radius = 12, fill = C.panel, border = C.border, tooltip = "Make this page" })
            gitgud.createWindow("Gitgud/Icon", name .. "Icon", name)
            gitgud.setProperty(name .. "Icon", "Area", "{{0,14},{0,15},{0,28},{0,29}}")
            gitgud.setProperty(name .. "Icon", "IconImage", "Bragi-Panel/File")
            gitgud.setProperty(name .. "Icon", "IconColour", C.accent)
            gitgud.setProperty(name .. "Icon", "GlowColour", C.transparent)
            gitgud.setProperty(name .. "Icon", "CursorPassThroughEnabled", "true")
            ui.label(name .. "Title", name, { 36, 12, each - 48, 20 }, s.title, { font = "Bragi-14-Bold" })
            ui.paragraph(name .. "Text", name, { 14, 38, each - 28, 40 }, s.blurb, { font = "Bragi-12", colour = C.sub })
        end
        y = y + 84
    else
        ui.label(root .. "ReadOnly", root, { cx - w // 2, y, w, 20 }, "You can read this wiki but not change it.",
            { font = "Bragi-13", colour = C.sub, align = "CentreAligned" })
        y = y + 30
    end
    parts.size(root, W - parts.SCROLLBAR, math.max(H, y + PAD))
end

function wikihome.draw(ctx)
    if #ctx.pages == 0 then
        drawEmpty(ctx)
    else
        drawPages(ctx)
    end
end

return wikihome
