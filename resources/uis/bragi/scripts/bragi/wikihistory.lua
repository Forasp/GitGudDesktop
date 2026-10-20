--- bragi/wikihistory.lua: the Wiki view's History tab, for bragi/wiki.lua.
--
-- The open page's versions (each edit is a commit in the wiki's Git
-- repository) on the left, newest first; on the right, the picked version:
-- what it changed against the one before (lines added and taken out, with
-- long unchanged stretches folded), or the whole page as it was then.
-- Restore saves that version's text as the newest (a new commit; nothing
-- is lost).
--
--   wikihistory.draw(ctx)    ctx from wiki.lua: root, width, height, open,
--                            page, revisions, canWrite, and actions
--   wikihistory.select(sha)  pick a version (the side panel's history)
--   wikihistory.reset()      forget the pick and the fetched texts

local C = require("core.palette")
local markdown = require("bragi.markdown")
local parts = require("bragi.wikiparts")
local rows = require("bragi.rows")
local text = require("core.text")
local ui = require("bragi.ui")

local wikihistory = {}

local API = "/api/bragi/v0"
local LIST = 300          -- the versions column
local PAD = 24
local CONTEXT = 2         -- unchanged lines kept around a change
local MAX_CELLS = 400000  -- biggest line diff worked out (lines x lines)
local LINE_H = 20

local selected = nil      -- the picked version's sha (nil: the newest)
local mode = "changes"    -- changes | page
local texts = {}          -- sha -> the page's text then (false while asked)
local textsFor = nil      -- the page those texts are of

function wikihistory.select(sha)
    selected = sha
    mode = "changes"
end

function wikihistory.reset()
    selected, texts, textsFor = nil, {}, nil
end

--- A version's text, asked for once; nil until it's here.
local function textAt(ctx, sha)
    local value = texts[sha]
    if value == nil then
        texts[sha] = false
        local repo, sub = ctx.open.repo, ctx.page.sub_url
        ctx.request("GET", API .. "/repos/" .. repo .. "/wiki/page/" .. sub .. "?html=false&ref=" .. sha, nil,
            function(page)
                if textsFor == repo .. "/" .. sub then
                    texts[sha] = type(page) == "table" and (page.content or "") or ""
                    ctx.show()
                end
            end, function()
                if textsFor == repo .. "/" .. sub then
                    texts[sha] = ""
                    ctx.show()
                end
            end)
        return nil
    end
    return value or nil
end

local function splitLines(s)
    local out = {}
    for line in ((s or ""):gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    if out[#out] == "" then
        out[#out] = nil
    end
    return out
end

--- The lines of `new` against `old`: { { kind = "same" | "add" | "del", text } }.
function wikihistory.diff(old, new)
    local a, b = splitLines(old), splitLines(new)
    -- Same lines at the ends need no table.
    local head = 0
    while head < #a and head < #b and a[head + 1] == b[head + 1] do
        head = head + 1
    end
    local tail = 0
    while tail < #a - head and tail < #b - head and a[#a - tail] == b[#b - tail] do
        tail = tail + 1
    end
    local out = {}
    for i = 1, head do
        out[#out + 1] = { kind = "same", text = a[i] }
    end
    local n, m = #a - head - tail, #b - head - tail
    if n * m > MAX_CELLS then
        for i = 1, n do
            out[#out + 1] = { kind = "del", text = a[head + i] }
        end
        for j = 1, m do
            out[#out + 1] = { kind = "add", text = b[head + j] }
        end
    else
        -- Longest common subsequence, then walk it.
        local L = {}
        for i = n + 1, 1, -1 do
            L[i] = {}
            for j = m + 1, 1, -1 do
                if i > n or j > m then
                    L[i][j] = 0
                elseif a[head + i] == b[head + j] then
                    L[i][j] = L[i + 1][j + 1] + 1
                else
                    L[i][j] = math.max(L[i + 1][j], L[i][j + 1])
                end
            end
        end
        local i, j = 1, 1
        while i <= n or j <= m do
            if i <= n and j <= m and a[head + i] == b[head + j] then
                out[#out + 1] = { kind = "same", text = a[head + i] }
                i, j = i + 1, j + 1
            elseif j <= m and (i > n or L[i][j + 1] >= L[i + 1][j]) then
                out[#out + 1] = { kind = "add", text = b[head + j] }
                j = j + 1
            else
                out[#out + 1] = { kind = "del", text = a[head + i] }
                i = i + 1
            end
        end
    end
    for k = #a - tail + 1, #a do
        out[#out + 1] = { kind = "same", text = a[k] }
    end
    return out
end

--- Unchanged stretches longer than the context, folded into one line.
local function fold(lines)
    local keep = {}
    for i, l in ipairs(lines) do
        if l.kind ~= "same" then
            for k = math.max(1, i - CONTEXT), math.min(#lines, i + CONTEXT) do
                keep[k] = true
            end
        end
    end
    local out, skipped = {}, 0
    for i, l in ipairs(lines) do
        if keep[i] then
            if skipped > 0 then
                out[#out + 1] = { kind = "fold", count = skipped }
                skipped = 0
            end
            out[#out + 1] = l
        else
            skipped = skipped + 1
        end
    end
    if skipped > 0 then
        out[#out + 1] = { kind = "fold", count = skipped }
    end
    return out
end

local function drawList(ctx, commits, current)
    local root = ctx.root
    local x, y = PAD, 24
    parts.heading(root .. "ListHead", root, x, y, LIST - 8, "Versions", #commits)
    y = y + 30
    for i, c in ipairs(commits) do
        local item = root .. "Ver" .. i
        local on = c.sha == current
        local sha = c.sha
        parts.spot(item, root, { x - 8, y, LIST, 58 }, function()
            selected, mode = sha, mode
            ctx.show()
        end, { fill = on and C.sel or C.transparent })
        if on then
            ui.rule(item .. "Bar", item, { 0, 12, 3, 34 })
            gitgud.setProperty(item .. "Bar", "PanelColour", C.accent)
        end
        local who = c.author and c.author.name or ""
        parts.avatar(item .. "Who", item, 14, 10, 20, who)
        ui.label(item .. "Message", item, { 44, 7, LIST - 56, 20 },
            rows.fitText(on and "Bragi-13-Bold" or "Bragi-13", parts.summary(c.message), LIST - 56),
            { font = on and "Bragi-13-Bold" or "Bragi-13", colour = C.text })
        ui.label(item .. "When", item, { 44, 28, LIST - 56, 18 },
            parts.capital(parts.when(c.created)) .. (who ~= "" and ("  \u{00B7}  " .. who) or "")
                .. (i == 1 and "  \u{00B7}  newest" or ""), { font = "Bragi-12", colour = C.disabled })
        y = y + 62
    end
    return y
end

local function drawChanges(ctx, x, y, w, lines)
    local root = ctx.root
    local adds, dels = 0, 0
    for _, l in ipairs(lines) do
        adds = adds + (l.kind == "add" and 1 or 0)
        dels = dels + (l.kind == "del" and 1 or 0)
    end
    local summary = "[font='Bragi-13'][colour='" .. C.add .. "']+" .. adds .. " "
        .. (adds == 1 and "line" or "lines") .. "[colour='" .. C.sub .. "']   [colour='" .. C.warn .. "']\u{2212}" .. dels
        .. " " .. (dels == 1 and "line" or "lines")
    if adds == 0 and dels == 0 then
        summary = "[font='Bragi-13'][colour='" .. C.sub .. "']No changes to the text in this version."
    end
    ui.label(root .. "Summary", root, { x, y, w, 20 }, summary, { markup = true })
    y = y + 30
    local box = root .. "Diff"
    ui.box(box, root, { x, y, w, 40 }, { radius = 10, fill = C.codeBg, border = C.border })
    local by = 8
    for i, l in ipairs(fold(lines)) do
        local row = box .. "L" .. i
        gitgud.createWindow("Gitgud/StaticText", row, box)
        gitgud.setProperty(row, "Area", string.format("{{0,1},{0,%d},{1,-1},{0,%d}}", by, by + LINE_H))
        gitgud.setProperty(row, "VertFormatting", "CentreAligned")
        gitgud.setProperty(row, "CursorPassThroughEnabled", "true")
        gitgud.setProperty(row, "Font", "Bragi-Mono-13")
        local bg, mark, colour = C.transparent, "  ", C.codeText
        if l.kind == "add" then
            bg, mark, colour = C.addBg, "+ ", C.add
        elseif l.kind == "del" then
            bg, mark, colour = C.delBg, "\u{2212} ", C.warn
        end
        gitgud.setProperty(row, "PanelColour", bg)
        if l.kind == "fold" then
            gitgud.setText(row, "[font='Bragi-12'][colour='" .. C.disabled .. "']      \u{22EF}  "
                .. text.plural(l.count, "unchanged line"))
        else
            gitgud.setText(row, "[colour='" .. colour .. "']  " .. mark .. "[colour='"
                .. (l.kind == "same" and C.sub or C.codeText) .. "']" .. text.escape(l.text))
        end
        by = by + LINE_H
    end
    gitgud.setProperty(box, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}", x, y, x + w, y + by + 8))
    return y + by + 8
end

function wikihistory.draw(ctx)
    local root, W = ctx.root, ctx.width - parts.SCROLLBAR
    local key = ctx.open.repo .. "/" .. ctx.page.sub_url
    if textsFor ~= key then
        texts, textsFor, selected = {}, key, nil
    end
    local commits = ctx.revisions
    if not commits then
        ui.label(root .. "Wait", root, { PAD, 28, 400, 20 }, "Reading the page's history\u{2026}",
            { font = "Bragi-14", colour = C.sub })
        parts.size(root, W, ctx.height)
        return
    end
    if #commits == 0 then
        ui.label(root .. "None", root, { PAD, 28, 600, 20 }, "This page has no history yet.",
            { font = "Bragi-14", colour = C.sub })
        parts.size(root, W, ctx.height)
        return
    end
    local index = 1
    for i, c in ipairs(commits) do
        if c.sha == selected then
            index = i
        end
    end
    local commit = commits[index]
    local listBottom = drawList(ctx, commits, commit.sha)

    ui.rule(root .. "Edge", root, { PAD + LIST + 4, 0, 1, math.max(ctx.height, listBottom + PAD) })
    local x = PAD + LIST + 28
    local w = math.max(320, math.min(860, W - x - 32))
    local y = 24
    ui.label(root .. "Head", root, { x, y, w, 28 }, rows.fitText("Bragi-18-Bold",
        parts.summary(commit.message), w), { font = "Bragi-18-Bold" })
    y = y + 32
    local who = commit.author and commit.author.name or ""
    ui.label(root .. "Sub", root, { x, y, w, 20 }, (who ~= "" and (who .. ", ") or "") .. parts.when(commit.created)
        .. "  \u{00B7}  " .. (commit.sha or ""):sub(1, 7), { font = "Bragi-13", colour = C.sub })
    y = y + 34

    -- What changed | Whole page, and Restore.
    local seg = root .. "Modes"
    ui.box(seg, root, { x, y, 2 * 118 + 6, 34 }, { radius = 10, fill = C.rail, border = C.border })
    for i, m in ipairs({ { "changes", "What changed" }, { "page", "Whole page" } }) do
        local b = seg .. m[1]
        local active = mode == m[1]
        ui.button(b, seg, { 3 + (i - 1) * 118, 3, 116, 28 }, m[2], { quiet = true, font = "Bragi-12-Bold" })
        gitgud.setProperty(b, "NormalFillColour", active and C.sel or C.transparent)
        gitgud.setProperty(b, "HoverFillColour", active and C.sel or C.hover)
        gitgud.setProperty(b, "NormalTextColour", active and C.accentText or C.sub)
        local id = m[1]
        gitgud.on(b .. ".clicked", function()
            mode = id
            ctx.show()
        end)
    end
    local content = textAt(ctx, commit.sha)
    if index > 1 and ctx.canWrite then
        local restore = ui.button(root .. "Restore", root, { x + w - 170, y, 170, 34 }, "Restore this version",
            { tooltip = "Save this version's text as the newest; nothing is lost" })
        gitgud.setEnabled(restore, content ~= nil)
        gitgud.on(restore .. ".clicked", function()
            local now = textAt(ctx, commit.sha)
            if now then
                ctx.restore(commit, now)
            end
        end)
    end
    y = y + 52

    local before = commits[index + 1]
    local old = before and textAt(ctx, before.sha) or ""
    if content == nil or old == nil then
        ui.label(root .. "Loading", root, { x, y, w, 20 }, "Reading that version\u{2026}",
            { font = "Bragi-13", colour = C.sub })
        y = y + 30
    elseif mode == "changes" then
        if not before then
            ui.label(root .. "First", root, { x, y, w, 20 }, "The first version: every line is new.",
                { font = "Bragi-13", colour = C.sub })
            y = y + 26
        end
        y = drawChanges(ctx, x, y, w, wikihistory.diff(old, content))
    else
        local blocks = markdown.parse(content)
        y = y + markdown.render(blocks, root, root .. "Md", { x = x, y = y, width = w })
    end
    parts.size(root, W, math.max(ctx.height, y + PAD, listBottom + PAD))
    gitgud.setProperty(root .. "Edge", "Area", string.format("{{0,%d},{0,0},{0,%d},{0,%d}}", PAD + LIST + 4,
        PAD + LIST + 5, math.max(ctx.height, y + PAD, listBottom + PAD)))
end

return wikihistory
