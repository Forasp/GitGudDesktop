--- bragi/wikigraph.lua: the Wiki view's Graph tab, for bragi/wiki.lua.
--
-- The open wiki's pages as dots and their [[links]] as lines, laid out so
-- linked pages sit together (a small force layout, here in Lua; it's kept
-- until the pages, links, or size change). Around the open page by
-- default: the pages within two links of it; "Whole wiki" shows them all.
-- Pages that are linked to but don't exist yet show as dashed rings.
--
-- A click on a page picks it and shows a card: what it says, how many links
-- it has, Open and Centre here (or Make this page, for a missing one). The
-- lines and dots are one picture (gitgud.drawPicture); names and the
-- clickable spots are widgets over it.
--
--   wikigraph.draw(ctx)   ctx from wiki.lua: root, width, height, open,
--                         page, links, canWrite, and actions

local C = require("core.palette")
local parts = require("bragi.wikiparts")
local rows = require("bragi.rows")
local text = require("core.text")
local ui = require("bragi.ui")
local wikilinks = require("bragi.wikilinks")

local wikigraph = {}

local PICTURE = "BragiWikiGraph"
local BAR = 56            -- the bar along the bottom
local MARGIN = 70         -- room around the dots for their names
local LABEL_W = 170
local CARD_W = 270
local DASHES = 10         -- dashes in a missing page's ring

local DEPTHS = { { id = 1, label = "Next to it" }, { id = 2, label = "Two links out" },
    { id = 0, label = "Whole wiki" } }

local depth = 2           -- links out from the open page; 0 = all
local showMissing = true
local picked = nil        -- the node id picked by a click
local cache = {}          -- the last layout: { key, pos }

--- The nodes and edges to show: { nodes = { {id, title, sub, missing, degree} }, edges = { {a, b} } }.
local function collect(ctx)
    local data = ctx.links
    local nodes, byId, edges, seenEdge = {}, {}, {}, {}
    local function node(id, title, sub, missing)
        if not byId[id] then
            byId[id] = { id = id, title = title, sub = sub, missing = missing, degree = 0 }
            nodes[#nodes + 1] = byId[id]
        end
        return byId[id]
    end
    local function edge(a, b)
        local key = a < b and (a .. "\0" .. b) or (b .. "\0" .. a)
        if not seenEdge[key] then
            seenEdge[key] = true
            edges[#edges + 1] = { a = a, b = b }
        end
    end
    for _, p in ipairs(data.pages) do
        node(p.sub_url, p.title or p.sub_url, p.sub_url, false)
    end
    for _, p in ipairs(data.pages) do
        for _, l in ipairs(p.links or {}) do
            if byId[l.sub_url] then
                edge(p.sub_url, l.sub_url)
            end
        end
        if showMissing then
            for _, m in ipairs(p.missing or {}) do
                local id = "?" .. wikilinks.key(m.title)
                node(id, m.title, nil, true)
                edge(p.sub_url, id)
            end
        end
    end

    -- Around the open page: only what's within `depth` links.
    local focus = ctx.page and byId[ctx.page.sub_url] and ctx.page.sub_url or nil
    if focus and depth > 0 then
        local near = { [focus] = 0 }
        local frontier = { focus }
        for d = 1, depth do
            local nextFrontier = {}
            for _, id in ipairs(frontier) do
                for _, e in ipairs(edges) do
                    local other = (e.a == id and e.b) or (e.b == id and e.a) or nil
                    if other and not near[other] then
                        near[other] = d
                        nextFrontier[#nextFrontier + 1] = other
                    end
                end
            end
            frontier = nextFrontier
        end
        local keptNodes, keptEdges = {}, {}
        for _, n in ipairs(nodes) do
            if near[n.id] then
                keptNodes[#keptNodes + 1] = n
            end
        end
        for _, e in ipairs(edges) do
            if near[e.a] and near[e.b] then
                keptEdges[#keptEdges + 1] = e
            end
        end
        nodes, edges = keptNodes, keptEdges
    end
    for _, e in ipairs(edges) do
        byId[e.a].degree = byId[e.a].degree + 1
        byId[e.b].degree = byId[e.b].degree + 1
    end
    table.sort(nodes, function(a, b)
        return a.id < b.id
    end)
    return { nodes = nodes, edges = edges, byId = byId, focus = focus }
end

local function radius(n, focus)
    local r = math.min(24, 8 + 3 * math.sqrt(n.degree))
    if n.missing then
        r = 9
    end
    return n.id == focus and r + 4 or r
end

--- Positions for the nodes in a w x h area: a force layout, started from a
-- circle in name order so the same wiki always lands the same way.
local function layout(g, w, h)
    local key = { tostring(w), tostring(h), g.focus or "" }
    for _, n in ipairs(g.nodes) do
        key[#key + 1] = n.id
    end
    for _, e in ipairs(g.edges) do
        key[#key + 1] = e.a .. ">" .. e.b
    end
    key = table.concat(key, "|")
    if cache.key == key then
        return cache.pos
    end

    local n = #g.nodes
    local pos = {}
    local cx, cy = w / 2, h / 2
    local spread = math.min(w, h) * 0.38
    for i, node in ipairs(g.nodes) do
        if node.id == g.focus then
            pos[node.id] = { x = cx, y = cy }
        else
            local a = (i / math.max(1, n)) * 2 * math.pi
            pos[node.id] = { x = cx + math.cos(a) * spread, y = cy + math.sin(a) * spread }
        end
    end
    if n > 1 then
        local k = math.sqrt((w * h) / n) * 0.75
        local iterations = math.max(60, math.min(300, 30000 // n))
        local temp = math.min(w, h) / 8
        for _ = 1, iterations do
            local disp = {}
            for _, a in ipairs(g.nodes) do
                disp[a.id] = { x = 0, y = 0 }
            end
            for i = 1, n do
                local a = g.nodes[i]
                local pa = pos[a.id]
                for j = i + 1, n do
                    local b = g.nodes[j]
                    local pb = pos[b.id]
                    local dx, dy = pa.x - pb.x, pa.y - pb.y
                    local d2 = dx * dx + dy * dy
                    if d2 < 0.01 then
                        dx, dy, d2 = (i - j) * 0.1, 0.1, 0.02
                    end
                    local d = math.sqrt(d2)
                    local f = k * k / d
                    disp[a.id].x, disp[a.id].y = disp[a.id].x + dx / d * f, disp[a.id].y + dy / d * f
                    disp[b.id].x, disp[b.id].y = disp[b.id].x - dx / d * f, disp[b.id].y - dy / d * f
                end
            end
            for _, e in ipairs(g.edges) do
                local pa, pb = pos[e.a], pos[e.b]
                local dx, dy = pa.x - pb.x, pa.y - pb.y
                local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
                local f = d * d / k
                disp[e.a].x, disp[e.a].y = disp[e.a].x - dx / d * f, disp[e.a].y - dy / d * f
                disp[e.b].x, disp[e.b].y = disp[e.b].x + dx / d * f, disp[e.b].y + dy / d * f
            end
            for _, a in ipairs(g.nodes) do
                if a.id ~= g.focus then
                    local d = disp[a.id]
                    -- A gentle pull to the middle keeps loose pages near.
                    d.x, d.y = d.x + (cx - pos[a.id].x) * 0.02 * k / 10, d.y + (cy - pos[a.id].y) * 0.02 * k / 10
                    local len = math.max(0.1, math.sqrt(d.x * d.x + d.y * d.y))
                    local step = math.min(len, temp)
                    pos[a.id].x = pos[a.id].x + d.x / len * step
                    pos[a.id].y = pos[a.id].y + d.y / len * step
                end
            end
            temp = temp * 0.97
        end
    end

    -- Fit what came out into the area, keeping the open page in the middle.
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, p in pairs(pos) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    local spanX, spanY = math.max(1, maxX - minX), math.max(1, maxY - minY)
    local scale = math.min((w - 2 * MARGIN) / spanX, (h - 2 * MARGIN) / spanY, 1.6)
    for _, p in pairs(pos) do
        p.x = w / 2 + (p.x - (minX + maxX) / 2) * scale
        p.y = h / 2 + (p.y - (minY + maxY) / 2) * scale
    end
    cache = { key = key, pos = pos }
    return pos
end

local function alpha(hex, a)
    return string.format("%02X", a) .. hex:sub(3)
end

local function note(ctx, title, body)
    local root = ctx.root
    ui.label(root .. "Title", root, { 32, 32, ctx.width - 64, 40 }, title, { font = "Bragi-32-Bold" })
    ui.paragraph(root .. "Text", root, { 32, 88, math.min(640, ctx.width - 64), 80 }, body,
        { font = "Bragi-16", colour = C.sub })
    parts.size(root, ctx.width, ctx.height)
end

--- The card for the picked page, near its dot.
local function drawCard(ctx, g, pos, id)
    local n = g.byId[id]
    local p = pos[id]
    if not n or not p then
        return
    end
    local root = ctx.root
    local name = root .. "Card"
    local entry = n.sub and ctx.links.bySub[n.sub]
    local back = n.sub and ctx.links.back[n.sub] or {}
    local out = entry and #(entry.links or {}) + #(entry.missing or {}) or 0
    local h = n.missing and 128 or 168
    local x = p.x + radius(n, g.focus) + 18
    if x + CARD_W > ctx.width - 12 then
        x = p.x - radius(n, g.focus) - 18 - CARD_W
    end
    x = math.max(12, x)
    local y = math.max(12, math.min(p.y - 40, ctx.height - BAR - h - 12))
    ui.card(name, root, { x, y, CARD_W, h })
    ui.label(name .. "Title", name, { 16, 12, CARD_W - 32, 22 }, rows.fitText("Bragi-15-Bold", n.title, CARD_W - 32),
        { font = "Bragi-15-Bold", colour = n.missing and C.warn or C.text })
    local summary
    if n.missing then
        summary = "No page yet. " .. text.plural(n.degree, "page links", "pages link") .. " to it."
    else
        summary = entry and entry.summary ~= "" and entry.summary or "Nothing written yet."
    end
    ui.paragraph(name .. "Text", name, { 16, 36, CARD_W - 32, 54 }, summary, { font = "Bragi-13", colour = C.sub })
    local by = h - 46
    if not n.missing then
        local cx = 16
        cx = cx + parts.chip(name .. "Back", name, cx, 92, #back .. " linked from") + 6
        parts.chip(name .. "Out", name, cx, 92, text.plural(out, "link out", "links out"))
        local sub = n.sub
        local openB = ui.button(name .. "Open", name, { 16, by, 108, 32 }, "Open page", { primary = true })
        gitgud.on(openB .. ".clicked", function()
            picked = nil
            ctx.openPage(sub)
            ctx.setView("page")
        end)
        if sub ~= g.focus then
            local centre = ui.button(name .. "Centre", name, { 132, by, 112, 32 }, "Centre here")
            gitgud.on(centre .. ".clicked", function()
                picked = nil
                ctx.openPage(sub)
            end)
        end
    elseif ctx.canWrite then
        local title = n.title
        local make = ui.button(name .. "Make", name, { 16, by, 140, 32 }, "Make this page", { primary = true })
        gitgud.on(make .. ".clicked", function()
            picked = nil
            ctx.newPage(title)
        end)
    end
end

--- The bar along the bottom: how far out, and missing pages on or off.
local function drawBar(ctx, g)
    local root = ctx.root
    local y = ctx.height - BAR + 12
    local x = 20
    if g.focus or depth ~= 0 then
        local box = root .. "Depths"
        ui.box(box, root, { x, y, 3 * 112 + 6, 34 }, { radius = 10, fill = C.rail, border = C.border })
        for i, d in ipairs(DEPTHS) do
            local b = box .. d.id
            local active = d.id == depth
            ui.button(b, box, { 3 + (i - 1) * 112, 3, 110, 28 }, d.label, { quiet = true, font = "Bragi-12-Bold" })
            gitgud.setProperty(b, "NormalFillColour", active and C.sel or C.transparent)
            gitgud.setProperty(b, "HoverFillColour", active and C.sel or C.hover)
            gitgud.setProperty(b, "NormalTextColour", active and C.accentText or C.sub)
            gitgud.setEnabled(b, g.focus ~= nil or d.id == 0)
            local id = d.id
            gitgud.on(b .. ".clicked", function()
                depth, picked = id, nil
                ctx.show()
            end)
        end
        x = x + 3 * 112 + 6 + 10
    end
    local m = ui.button(root .. "Missing", root, { x, y, 150, 34 }, (showMissing and "\u{2713}  " or "")
        .. "Missing pages", { font = "Bragi-12-Bold", colour = showMissing and C.warn or C.sub,
            tooltip = "Pages that are linked to but don't exist yet" })
    gitgud.on(m .. ".clicked", function()
        showMissing, picked = not showMissing, nil
        ctx.show()
    end)
    x = x + 160
    local shown = 0
    for _, n in ipairs(g.nodes) do
        if not n.missing then
            shown = shown + 1
        end
    end
    ui.label(root .. "Count", root, { x, y, math.max(0, ctx.width - x - 20), 34 },
        text.plural(shown, "page") .. ", " .. text.plural(#g.edges, "link") .. ".  Click a page to see it.",
        { font = "Bragi-12", colour = C.disabled, align = "RightAligned" })
end

function wikigraph.draw(ctx)
    local root, W, H = ctx.root, ctx.width, ctx.height
    if not ctx.links then
        note(ctx, "Graph", "Reading the pages\u{2026}")
        return
    end
    if #ctx.links.pages == 0 then
        note(ctx, "Nothing to draw yet", "Pages and the [[links]] between them show here once the wiki has some.")
        return
    end
    if not (ctx.page) and depth ~= 0 then
        depth = 0
    end
    local g = collect(ctx)
    local areaH = H - BAR
    local pos = layout(g, W, areaH)
    if picked and not g.byId[picked] then
        picked = nil
    end

    -- Lines, then dots, as one picture.
    local shapes = {}
    local hot = picked or g.focus
    for _, e in ipairs(g.edges) do
        local a, b = pos[e.a], pos[e.b]
        local lit = hot and (e.a == hot or e.b == hot)
        shapes[#shapes + 1] = { kind = "line", points = { a.x, a.y, b.x, b.y }, width = lit and 1.6 or 1.2,
            colour = lit and alpha(C.accent, 0x99) or C.border }
    end
    for _, n in ipairs(g.nodes) do
        local p = pos[n.id]
        local r = radius(n, g.focus)
        if n.missing then
            shapes[#shapes + 1] = { kind = "disc", x = p.x, y = p.y, radius = r + 1, colour = C.bg }
            for k = 0, DASHES - 1 do
                local a1 = (k / DASHES) * 2 * math.pi
                local a2 = a1 + math.pi / DASHES
                local pts = {}
                for s = 0, 4 do
                    local a = a1 + (a2 - a1) * s / 4
                    pts[#pts + 1] = p.x + math.cos(a) * r
                    pts[#pts + 1] = p.y + math.sin(a) * r
                end
                shapes[#shapes + 1] = { kind = "line", points = pts, width = 1.5, colour = C.warn }
            end
        elseif n.id == g.focus then
            shapes[#shapes + 1] = { kind = "ring", x = p.x, y = p.y, radius = r + 7, width = 5,
                colour = alpha(C.accent, 0x5C) }
            shapes[#shapes + 1] = { kind = "disc", x = p.x, y = p.y, radius = r, colour = C.accent }
        else
            shapes[#shapes + 1] = { kind = "disc", x = p.x, y = p.y, radius = r, colour = C.sel }
            shapes[#shapes + 1] = { kind = "ring", x = p.x, y = p.y, radius = r - 0.75, width = 1.5,
                colour = n.id == picked and C.accent or C.borderStrong }
        end
        if n.id == picked and n.id ~= g.focus then
            shapes[#shapes + 1] = { kind = "ring", x = p.x, y = p.y, radius = r + 5, width = 3,
                colour = alpha(C.accent, 0x5C) }
        end
    end
    local picture = root .. "Picture"
    gitgud.createWindow("Gitgud/Image", picture, root)
    gitgud.setProperty(picture, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}", W, areaH))
    if gitgud.drawPicture(PICTURE, W, areaH, shapes) then
        gitgud.setProperty(picture, "Image", PICTURE)
    end

    -- Names under the dots, and a clickable spot on each.
    for i, n in ipairs(g.nodes) do
        local p = pos[n.id]
        local r = radius(n, g.focus)
        local isFocus = n.id == g.focus
        local font = isFocus and "Bragi-13-Bold" or "Bragi-12"
        local label = root .. "Name" .. i
        local lx = math.max(4, math.min(W - LABEL_W - 4, math.floor(p.x - LABEL_W / 2)))
        ui.label(label, root, { lx, math.floor(p.y + r + 4), LABEL_W, 18 }, rows.fitText(font, n.title, LABEL_W), {
            font = font, align = "CentreAligned",
            colour = n.missing and C.warn or ((isFocus or n.id == picked) and C.text or C.sub) })
        local size = math.floor(2 * r + 10)
        local id = n.id
        parts.spot(root .. "Dot" .. i, root, { math.floor(p.x - size / 2), math.floor(p.y - size / 2), size, size },
            function()
                picked = picked ~= id and id or nil
                ctx.show()
            end, { radius = math.min(22, size // 2), tooltip = n.title })
        gitgud.setProperty(root .. "Dot" .. i, "HoverFillColour", alpha(C.accent, 0x22))
    end
    if picked then
        drawCard(ctx, g, pos, picked)
    end

    ui.rule(root .. "BarRule", root, { 0, areaH, W, 1 })
    drawBar(ctx, g)
    parts.size(root, W, H)
end

--- Forget the picked page (another wiki opened).
function wikigraph.reset()
    picked, cache = nil, {}
end

return wikigraph
