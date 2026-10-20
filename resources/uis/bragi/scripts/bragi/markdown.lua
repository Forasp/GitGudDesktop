--- bragi/markdown.lua: Markdown, read and drawn in the app.
--
-- Wiki pages (and later the agent's replies) arrive as Markdown source; the
-- server's HTML is never shown. This reads the common subset and draws it
-- with CEGUI markup in the theme's fonts and colours:
--
--   blocks   headings (#), paragraphs, lists (-, *, +, 1.; nested by
--            indent; [ ] and [x] tasks), fenced and indented code, quotes
--            (>), rules (---), tables (| a | b |)
--   inline   `code`, **bold**, *emphasis*, [links](url), ![images](url),
--            <autolinks>, backslash escapes, two trailing spaces for a break,
--            and [[wiki links]] when the caller gives opts.wiki
--
-- Emphasis shows in the secondary colour (the fonts have no italics);
-- images show their alt text; links are coloured, and clickable when the
-- caller asks (opts.links: a conversation's replies, bragi/links.lua).
-- opts.wiki(name) says where a [[wiki link]] goes: a link table for
-- bragi/links.lua ({ kind = "wiki", ... }), with missing = true for a page
-- that isn't there yet (drawn in the warning colour, still clickable).
--
--   local blocks = markdown.parse(source)
--   local height = markdown.render(blocks, parent, "WikiMd1", { x = 32, y = 90, width = 680 })

local C = require("core.palette")
local links = require("bragi.links")
local text = require("core.text")
local textselect = require("bragi.textselect")
local ui = require("bragi.ui")

local markdown = {}

-- ===================================================================
-- Blocks
-- ===================================================================

local function splitLines(source)
    local lines = {}
    source = (source or ""):gsub("\r\n?", "\n")
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line:gsub("\t", "    ")
    end
    return lines
end

local function isBlank(line)
    return line:match("^%s*$") ~= nil
end

local function isRule(line)
    local stripped = line:gsub("%s", "")
    return #stripped >= 3 and (stripped:match("^%-+$") or stripped:match("^%*+$") or stripped:match("^_+$")) ~= nil
end

--- A list item's marker: indent, ordered, number, the rest.
local function listItem(line)
    local indent, bullet, rest = line:match("^(%s*)([%-%*%+])%s+(.*)$")
    if indent then
        return #indent, false, nil, rest
    end
    local number
    indent, number, rest = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
    if indent then
        return #indent, true, tonumber(number), rest
    end
    return nil
end

local function tableCells(line)
    local body = line:match("^%s*|?(.-)|?%s*$")
    local cells = {}
    for cell in (body .. "|"):gmatch("(.-)|") do
        cells[#cells + 1] = text.trim(cell)
    end
    return cells
end

local function isTableDivider(line)
    return line:match("^%s*|?%s*:?%-+:?%s*[|%s:%-]*$") ~= nil and line:find("-", 1, true) ~= nil
end

--- Read Markdown into a list of blocks:
--   { kind = "heading", level, text }   { kind = "paragraph", text }
--   { kind = "code", text, lang }       { kind = "quote", text }
--   { kind = "rule" }                   { kind = "table", rows = { {cells} }, header = bool }
--   { kind = "list", items = { { text, depth, ordered, number, task = nil | "done" | "todo" } } }
-- Inline text stays Markdown; markdown.inline turns it into markup.
function markdown.parse(source)
    local lines = splitLines(source)
    local blocks = {}
    local para = nil   -- lines of the open paragraph
    local list = nil   -- the open list block

    local function closePara()
        if para then
            blocks[#blocks + 1] = { kind = "paragraph", text = table.concat(para, "\n") }
            para = nil
        end
    end
    local function closeList()
        list = nil
    end

    local i = 1
    while i <= #lines do
        local line = lines[i]
        local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
        if fence then
            closePara()
            closeList()
            local lang = text.trim(line:match("^%s*[`~]+(.*)$") or "")
            local body = {}
            i = i + 1
            while i <= #lines and not lines[i]:match("^%s*" .. fence:sub(1, 1):gsub("%p", "%%%0") .. "+%s*$") do
                body[#body + 1] = lines[i]
                i = i + 1
            end
            blocks[#blocks + 1] = { kind = "code", text = table.concat(body, "\n"), lang = lang }
        elseif isBlank(line) then
            closePara()
            -- A list survives one blank line when the next line continues it.
            if list and not (lines[i + 1] and (listItem(lines[i + 1]) or lines[i + 1]:match("^%s%s+%S"))) then
                closeList()
            end
        elseif line:match("^%s*#+%s") or line:match("^%s*#+$") then
            closePara()
            closeList()
            local hashes, rest = line:match("^%s*(#+)%s*(.-)%s*#*%s*$")
            blocks[#blocks + 1] = { kind = "heading", level = math.min(#hashes, 6), text = rest }
        elseif para and not list and (line:match("^%s*=+%s*$") or line:match("^%s*%-+%s*$")) then
            -- An underlined heading: the paragraph above is its text.
            blocks[#blocks + 1] = { kind = "heading", level = line:find("=", 1, true) and 1 or 2,
                text = table.concat(para, " ") }
            para = nil
        elseif isRule(line) and not para then
            closeList()
            blocks[#blocks + 1] = { kind = "rule" }
        elseif line:match("^%s*>") then
            closePara()
            closeList()
            local quote = {}
            while i <= #lines and lines[i]:match("^%s*>") do
                quote[#quote + 1] = lines[i]:match("^%s*>%s?(.*)$")
                i = i + 1
            end
            i = i - 1
            blocks[#blocks + 1] = { kind = "quote", text = table.concat(quote, "\n") }
        elseif line:match("^%s*|") and lines[i + 1] and isTableDivider(lines[i + 1]) then
            closePara()
            closeList()
            local rows = { tableCells(line) }
            i = i + 2
            while i <= #lines and lines[i]:match("^%s*|") do
                rows[#rows + 1] = tableCells(lines[i])
                i = i + 1
            end
            i = i - 1
            blocks[#blocks + 1] = { kind = "table", rows = rows, header = true }
        elseif listItem(line) then
            closePara()
            local indent, ordered, number, rest = listItem(line)
            if not list then
                list = { kind = "list", items = {} }
                blocks[#blocks + 1] = list
            end
            local task = nil
            local mark, after = rest:match("^%[([ xX])%]%s+(.*)$")
            if mark then
                task = mark == " " and "todo" or "done"
                rest = after
            end
            list.items[#list.items + 1] = { text = rest, depth = math.floor(indent / 2),
                ordered = ordered, number = number, task = task }
        elseif list and line:match("^%s%s+%S") then
            -- A wrapped list item.
            local item = list.items[#list.items]
            item.text = item.text .. "\n" .. text.trim(line)
        elseif line:match("^    ") and not para and not list then
            local body = {}
            while i <= #lines and (lines[i]:match("^    ") or isBlank(lines[i])) do
                body[#body + 1] = lines[i]:sub(5)
                i = i + 1
            end
            while #body > 0 and isBlank(body[#body]) do
                body[#body] = nil
            end
            i = i - 1
            blocks[#blocks + 1] = { kind = "code", text = table.concat(body, "\n"), lang = "" }
        else
            closeList()
            para = para or {}
            para[#para + 1] = line
        end
        i = i + 1
    end
    closePara()
    return blocks
end

-- ===================================================================
-- Inline
-- ===================================================================

--- Inline Markdown as CEGUI markup.
-- @param s      the Markdown text (line breaks inside are spaces, unless
--               the line ended with two spaces or a backslash)
-- @param style  { font, bold, mono, colour, sub, link, code, wiki }: fonts
--               and colours; defaults are the body's. With links = true,
--               links are found (bragi/links.lua; relative paths from
--               style.folder) and their spans returned; with wiki (a
--               function, see the top), [[wiki links]] are too
-- @return the markup, and its links' spans ({} without style.links)
function markdown.inline(s, style)
    style = style or {}
    local font = style.font or "Bragi-15"
    local bold = style.bold or "Bragi-15-Bold"
    local mono = style.mono or "Bragi-Mono-13"
    local colour = style.colour or C.text
    local subColour = style.sub or C.sub
    local linkColour = style.link or C.link
    local codeColour = style.code or C.accentText
    local folder = style.folder

    -- Hard breaks first, then soft breaks become spaces.
    s = (s or ""):gsub("  +\n", "\0"):gsub("\\\n", "\0"):gsub("\n", " ")

    local out, spans, len = {}, {}, 0
    local function put(piece)
        out[#out + 1] = piece
        len = len + #piece
    end
    -- A link's text, in the link colour (or `shade`), as a span.
    local function putLink(shown, link, shade)
        put("[colour='" .. (shade or linkColour) .. "']")
        local first = len + 1
        put(text.escape(shown))
        if link then
            spans[#spans + 1] = { first = first, last = len, link = link }
        end
    end
    local isBold, isEm = false, false
    local function state()
        return "[font='" .. (isBold and bold or font) .. "'][colour='" .. (isEm and subColour or colour) .. "']"
    end
    local function emit(literal)
        put(text.escape(literal))
    end

    put(state())
    local i = 1
    local n = #s
    local plain = {}
    local function flush()
        if #plain > 0 then
            emit(table.concat(plain))
            plain = {}
        end
    end
    while i <= n do
        local c = s:sub(i, i)
        local two = s:sub(i, i + 1)
        local bareEnd, bare = nil, nil
        if style.links and c:match("[%w/~_%.%-]") then
            bareEnd, bare = links.match(s, i, folder)
        end
        if c == "\0" then
            flush()
            put("\n")
            i = i + 1
        elseif bareEnd then
            -- A web address or a path, as written.
            flush()
            putLink(s:sub(i, bareEnd), bare)
            put(state())
            i = bareEnd + 1
        elseif c == "\\" and i < n and s:sub(i + 1, i + 1):match("%p") then
            plain[#plain + 1] = s:sub(i + 1, i + 1)
            i = i + 2
        elseif c == "`" then
            local ticks = s:match("^`+", i)
            local close = s:find(ticks, i + #ticks, true)
            if close then
                flush()
                local code = text.trim(s:sub(i + #ticks, close - 1))
                local link = style.links and links.target(code, folder)
                put("[font='" .. mono .. "']")
                putLink(code, link or nil, not link and codeColour or nil)
                put(state())
                i = close + #ticks
            else
                plain[#plain + 1] = ticks
                i = i + #ticks
            end
        elseif two == "**" or two == "__" then
            flush()
            isBold = not isBold
            put(state())
            i = i + 2
        elseif (c == "*" or c == "_") and not (c == "_" and s:sub(i - 1, i - 1):match("%w") and s:sub(i + 1, i + 1):match("%w")) then
            flush()
            isEm = not isEm
            put(state())
            i = i + 1
        elseif style.wiki and two == "[[" and s:find("]]", i + 2, true) then
            local close = s:find("]]", i + 2, true)
            local inner = s:sub(i + 2, close - 1)
            local target, label = inner:match("^(.-)|(.*)$")
            target = text.trim(target or inner)
            label = text.trim(label or "")
            local link = target ~= "" and style.wiki(target) or nil
            flush()
            putLink(label ~= "" and label or target, link, link and link.missing and C.warn or nil)
            put(state())
            i = close + 2
        elseif two == "![" or c == "[" then
            local image = two == "!["
            local start = image and i + 2 or i + 1
            local label, url, after = s:match("^(.-)%]%(([^%)]*)%)()", start)
            if label then
                flush()
                if image then
                    put("[colour='" .. subColour .. "']" .. text.escape(label ~= "" and label or url) .. state())
                else
                    putLink(label, style.links and links.target(url, folder) or nil)
                    put(state())
                end
                i = after
            else
                plain[#plain + 1] = c
                i = i + 1
            end
        elseif c == "<" and s:match("^<https?://[^>%s]+>", i) then
            flush()
            local url = s:match("^<([^>]+)>", i)
            putLink(url, style.links and { kind = "web", target = url } or nil)
            put(state())
            i = i + #url + 2
        else
            plain[#plain + 1] = c
            i = i + 1
        end
    end
    flush()
    return table.concat(out), spans
end

--- The text without Markdown (for titles, search, measuring).
function markdown.plain(s)
    s = (s or ""):gsub("%[%[(.-)%]%]", function(inner)
        return inner:match("|(.*)$") or inner
    end):gsub("!?%[(.-)%]%([^%)]*%)", "%1"):gsub("[`*_]", "")
    return s
end

-- ===================================================================
-- Drawing
-- ===================================================================

local HEADING_FONT = { "Bragi-32-Bold", "Bragi-20-Bold", "Bragi-18-Bold", "Bragi-15-Bold", "Bragi-15-Bold", "Bragi-15-Bold" }
local HEADING_SPACE = { 8, 20, 16, 12, 12, 12 }
local GAP = 12

--- A wrapped StaticText holding markup, sized to its text. Returns its height.
local function textBox(name, parent, x, y, width, markup, opts)
    opts = opts or {}
    gitgud.createWindow("Gitgud/StaticText", name, parent)
    gitgud.setProperty(name, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}", x, y, x + width, y + 40))
    gitgud.setProperty(name, "PanelColour", C.transparent)
    gitgud.setProperty(name, "HorzFormatting", opts.noWrap and "LeftAligned" or "WordWrapLeftAligned")
    gitgud.setProperty(name, "VertFormatting", "TopAligned")
    gitgud.setProperty(name, "Font", opts.font or "Bragi-15")
    gitgud.setProperty(name, "TextColours", opts.colour or C.text)
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    gitgud.setText(name, markup)
    local extent = tonumber(gitgud.getProperty(name, "VertExtent") or "") or 0
    local height = math.max(18, math.ceil(extent) + 2)
    gitgud.setProperty(name, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}", x, y, x + width, y + height))
    if opts.spans and #opts.spans > 0 then
        links.attach(name, opts.spans)
    end
    return height
end

local function styleOf(opts)
    return { font = opts.font or "Bragi-15", bold = opts.bold or "Bragi-15-Bold", links = opts.links,
        folder = opts.folder, wiki = opts.wiki }
end

--- Draw one block at y under parent, its widgets named by name(), its
-- texts given to collect(name, gap, prefix); returns the y below it.
local function drawBlock(block, first, parent, name, collect, x, y, width, style, opts)
    -- Plain text (code, tables) with its links coloured, after `head`.
    local function plainText(head, s, colour, linkColour)
        if not opts.links then
            return head .. text.escape(s), nil
        end
        local markup, spans = links.markup(s, { folder = opts.folder, colour = colour, link = linkColour })
        for _, span in ipairs(spans) do
            span.first, span.last = span.first + #head, span.last + #head
        end
        return head .. markup, spans
    end

    do
        if block.kind == "heading" then
            y = y + (first and 0 or HEADING_SPACE[block.level])
            local font = HEADING_FONT[block.level]
            local markup, spans = markdown.inline(block.text, { font = font, bold = font, links = opts.links,
                folder = opts.folder, wiki = opts.wiki })
            y = y + textBox(collect(name(), "\n\n"), parent, x, y, width, markup, { font = font, spans = spans }) + 8
        elseif block.kind == "paragraph" then
            local markup, spans = markdown.inline(block.text, style)
            y = y + textBox(collect(name(), "\n\n"), parent, x, y, width, markup, { font = style.font, spans = spans }) + GAP
        elseif block.kind == "code" then
            local box = name()
            ui.box(box, parent, { x, y, width, 40 }, { radius = 8, fill = C.codeBg, border = C.transparent })
            gitgud.setProperty(box, "CursorPassThroughEnabled", "true")
            local markup, spans = plainText("[colour='" .. C.codeText .. "']", block.text, C.codeText, C.codeLink)
            local room = opts.copyCode and textselect.BUTTON + 4 or 0
            local h = textBox(collect(box .. "Text", "\n\n"), box, 14, 10, width - 28 - room, markup,
                { font = "Bragi-Mono-13", colour = C.codeText, spans = spans })
            if opts.copyCode then
                local code = block.text
                textselect.copyButton(box .. "Copy", box, width - textselect.BUTTON - 6, 6, function()
                    return code
                end, "Copy the code", "the code")
            end
            gitgud.setProperty(box, "Area", string.format("{{0,%d},{0,%d},{0,%d},{0,%d}}", x, y, x + width, y + h + 20))
            y = y + h + 20 + GAP
        elseif block.kind == "quote" then
            local bar = name()
            local markup, spans = markdown.inline(block.text, { font = style.font, bold = style.bold, colour = C.sub,
                links = opts.links, folder = opts.folder, wiki = opts.wiki })
            local h = textBox(collect(bar .. "Text", "\n\n"), parent, x + 16, y, width - 16, markup,
                { font = style.font, spans = spans })
            ui.rule(bar, parent, { x, y, 3, h })
            gitgud.setProperty(bar, "PanelColour", C.accent)
            y = y + h + GAP
        elseif block.kind == "rule" then
            ui.rule(name(), parent, { x, y + 8, width, 1 })
            y = y + 17 + GAP
        elseif block.kind == "list" then
            local counters = {}
            for li, item in ipairs(block.items) do
                local indent = item.depth * 22
                local marker
                if item.task then
                    marker = item.task == "done" and "[x]" or "[  ]"
                elseif item.ordered then
                    counters[item.depth] = (counters[item.depth] or ((item.number or 1) - 1)) + 1
                    marker = counters[item.depth] .. "."
                else
                    marker = "\u{2022}"
                end
                for depth in pairs(counters) do
                    if depth > item.depth then
                        counters[depth] = nil
                    end
                end
                local mark = name()
                ui.label(mark, parent, { x + indent, y, 26, 22 }, marker,
                    { font = item.task and "Bragi-Mono-13" or style.font, colour = C.sub })
                local markup, spans = markdown.inline(item.text, style)
                -- Copied as Markdown writes it.
                local bullet = item.task and ("- " .. (item.task == "done" and "[x]" or "[ ]"))
                    or (item.ordered and marker or "-")
                local prefix = string.rep("  ", item.depth) .. bullet .. " "
                local h = textBox(collect(mark .. "Text", li == 1 and "\n\n" or "\n", prefix), parent,
                    x + indent + 28, y, width - indent - 28, markup,
                    { font = style.font, spans = spans })
                y = y + h + 4
            end
            y = y + GAP - 4
        elseif block.kind == "table" then
            -- Columns padded to their widest cell, in the code font.
            local widths = {}
            for _, row in ipairs(block.rows) do
                for c, cell in ipairs(row) do
                    widths[c] = math.max(widths[c] or 0, utf8.len(markdown.plain(cell)) or #cell)
                end
            end
            for r, row in ipairs(block.rows) do
                local rowGap = r == 1 and "\n\n" or "\n"
                local cells = {}
                for c, cell in ipairs(row) do
                    local plain = markdown.plain(cell)
                    cells[#cells + 1] = plain .. string.rep(" ", widths[c] - (utf8.len(plain) or #plain))
                end
                local header = r == 1 and block.header
                local shade = header and C.text or C.sub
                local markup, spans = plainText("[colour='" .. shade .. "']", table.concat(cells, "   "), shade)
                y = y + textBox(collect(name(), rowGap), parent, x, y, width, markup,
                    { font = "Bragi-Mono-13", noWrap = true, spans = spans }) + 2
                if header then
                    ui.rule(name(), parent, { x, y + 1, width, 1 })
                    y = y + 4
                end
            end
            y = y + GAP
        end
    end
    return y
end

--- Draw blocks under `parent`; widgets are named `prefix .. n`.
-- @param opts  { x, y, width, font, bold, links, folder, wiki, texts,
--              copyCode }: with links = true, web addresses and paths are
--              clickable (bragi/links.lua; relative paths from folder);
--              with wiki, [[wiki links]] (see markdown.inline); with a
--              texts list, each text drawn is added to it in order as
--              { name, gap, prefix } (for selecting, bragi/textselect.lua);
--              with copyCode, code blocks have a Copy button
-- @return the height drawn
function markdown.render(blocks, parent, prefix, opts)
    opts = opts or {}
    local x = opts.x or 0
    local y0 = opts.y or 0
    local width = opts.width or 600
    local style = styleOf(opts)
    local y = y0
    local n = 0
    -- The texts drawn, for selecting: gap is what goes between this one
    -- and the one before when they're copied together.
    local function collect(textName, gap, prefix)
        if opts.texts then
            opts.texts[#opts.texts + 1] = { name = textName, gap = gap, prefix = prefix }
        end
        return textName
    end
    local function name()
        n = n + 1
        return prefix .. n
    end
    for bi, block in ipairs(blocks) do
        y = drawBlock(block, bi == 1, parent, name, collect, x, y, width, style, opts)
    end
    return y - y0
end

--- What a block shows, as one string: equal keys draw the same.
local function blockKey(block)
    if block.kind == "list" then
        local parts = { "list" }
        for _, item in ipairs(block.items) do
            parts[#parts + 1] = table.concat({ item.depth, tostring(item.task), tostring(item.ordered),
                tostring(item.number), item.text }, "\1")
        end
        return table.concat(parts, "\2")
    elseif block.kind == "table" then
        local rows = { "table", tostring(block.header) }
        for _, row in ipairs(block.rows) do
            rows[#rows + 1] = table.concat(row, "\1")
        end
        return table.concat(rows, "\2")
    end
    return block.kind .. "\1" .. tostring(block.level) .. "\1" .. (block.text or "")
end

--- Draw blocks under `parent` again, keeping what's unchanged: each block
-- has a window of its own, and only the blocks from the first that
-- changed are drawn anew (a reply streaming in grows at its end; drawing
-- all of it at every piece cost more with every piece). `state` is the
-- caller's table, kept between calls; a new width draws everything.
-- @param opts  as markdown.render's (x and y are 0: the parent's corner);
--              texts gets every block's texts, kept ones too
-- @return the height drawn
function markdown.update(state, blocks, parent, opts)
    opts = opts or {}
    local width = opts.width or 600
    local style = styleOf(opts)
    local drawn = state.drawn or {}
    if state.width ~= width or state.parent ~= parent or state.folder ~= opts.folder
        or state.copyCode ~= (opts.copyCode == true) then
        for _, d in ipairs(drawn) do
            gitgud.destroyWindow(d.window)
        end
        drawn = {}
    end
    state.width, state.parent, state.folder, state.copyCode = width, parent, opts.folder, opts.copyCode == true
    local keep = 0
    while keep < #drawn and keep < #blocks and drawn[keep + 1].key == blockKey(blocks[keep + 1]) do
        keep = keep + 1
    end
    for i = #drawn, keep + 1, -1 do
        gitgud.destroyWindow(drawn[i].window)
        drawn[i] = nil
    end
    local y = keep > 0 and drawn[keep].bottom or 0
    for bi = keep + 1, #blocks do
        state.serial = (state.serial or 0) + 1
        local window = parent .. "B" .. state.serial
        gitgud.createWindow("DefaultWindow", window, parent)
        local n = 0
        local function name()
            n = n + 1
            return window .. "M" .. n
        end
        local texts = {}
        local function collect(textName, gap, prefix)
            texts[#texts + 1] = { name = textName, gap = gap, prefix = prefix }
            return textName
        end
        -- Drawn at its own top; the gap above it (a heading's) stays inside.
        local bottom = drawBlock(blocks[bi], bi == 1, window, name, collect, 0, 0, width, style, opts)
        gitgud.setProperty(window, "Area", string.format("{{0,0},{0,%d},{0,%d},{0,%d}}", y, width, y + bottom))
        y = y + bottom
        drawn[bi] = { key = blockKey(blocks[bi]), window = window, bottom = y, texts = texts }
    end
    state.drawn = drawn
    if opts.texts then
        for _, d in ipairs(drawn) do
            for _, t in ipairs(d.texts) do
                opts.texts[#opts.texts + 1] = t
            end
        end
    end
    return y
end

--- The text windows markdown.update drew, in order (paragraphs, headings,
-- list items, a code block's text...), for whoever looks them up.
function markdown.textWindows(state)
    local out = {}
    for _, d in ipairs(state and state.drawn or {}) do
        for _, t in ipairs(d.texts or {}) do
            out[#out + 1] = t.name
        end
    end
    return out
end

return markdown
