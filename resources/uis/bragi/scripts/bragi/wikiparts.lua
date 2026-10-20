--- bragi/wikiparts.lua: small pieces the Wiki view's screens share
-- (bragi/wiki.lua, wikihome.lua, wikigraph.lua, wikihistory.lua): chips,
-- authors' round badges, caps headings with a count, clickable rows.
--
-- Every builder takes the new widget's name, its parent, and pixels, like
-- bragi/ui.lua's.

local C = require("core.palette")
local rows = require("bragi.rows")
local text = require("core.text")
local ui = require("bragi.ui")

local parts = {}

local RADII = { 22, 16, 12, 10, 8, 6, 4 }   -- the Bragi/Box and Button shapes there are
parts.SCROLLBAR = 14                        -- what a scrolling pane's bar takes

--- The largest rounded shape's radius that fits `r`.
function parts.radius(r)
    for _, candidate in ipairs(RADII) do
        if candidate <= r then
            return candidate
        end
    end
    return 4
end

--- A wiki's name as shown: "Shared wiki", or the project's name.
function parts.wikiName(w)
    if not w then
        return "Wiki"
    end
    return w.shared and "Shared wiki" or ((w.repo or ""):match("([^/]+)$") or w.repo or "")
end

--- A change's message in one line: its first line with text, or "(no
-- message)". Rows that list changes show this (a message of several lines
-- in a one-line row showed parts of two, cut off).
function parts.summary(message)
    for raw in tostring(message or ""):gmatch("[^\r\n]+") do
        local line = text.trim(raw)
        if line ~= "" then
            return line
        end
    end
    return "(no message)"
end

--- A page's row in the page tree: its folder ("Space Game", nil at the
-- top) and its name there. A title that starts with its folder's name
-- ("Space Game - Balance" in Space Game) goes by the rest ("Balance");
-- the folder's own page ("Space Game" in Space Game) by its title alone.
-- @param p  a page { sub_url, title }
-- @return folder or nil, name
function parts.treeLabel(p)
    local sub = tostring(p.sub_url or "")
    local title = tostring(p.title or sub)
    local folder = sub:match("^(.*)/")
    if not folder then
        return nil, title
    end
    folder = folder:gsub("%-", " ")
    -- The folder's last part, word by word, at the title's start (any case,
    -- any spaces, dashes or underscores between the words).
    local words = {}
    for word in (folder:match("([^/]+)$") or folder):lower():gmatch("[^%s%-_]+") do
        words[#words + 1] = (word:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
    end
    if #words == 0 then
        return folder, title
    end
    local _, last = title:lower():find("^" .. table.concat(words, "[%s%-_]+"))
    if not last then
        return folder, title
    end
    local rest = title:sub(last + 1)
    if rest:match("^[%w\128-\255]") and not rest:match("^\u{2013}") and not rest:match("^\u{2014}") then
        return folder, title -- a longer word ("Space GameX")
    end
    -- What separates the two: spaces, dashes, colons, slashes.
    local before
    repeat
        before = rest
        rest = rest:gsub("^[%s%-_:/|]+", ""):gsub("^\u{2013}", ""):gsub("^\u{2014}", "")
    until rest == before
    if rest == "" then
        return nil, title
    end
    return folder, rest
end

--- True when a change was made by Bragi (or Claude Code working for it).
function parts.byBragi(author)
    local a = tostring(author or ""):lower()
    return a:find("bragi", 1, true) ~= nil or a:find("claude", 1, true) ~= nil
end

--- When something happened, short: "2 hours ago", "yesterday", a date.
function parts.when(time)
    if not time then
        return ""
    end
    local days = (os.time() - time) // 86400
    if days == 1 then
        return "yesterday"
    end
    return text.ago(time)
end

--- Sentence case: the first letter up ("Yesterday").
function parts.capital(s)
    return (tostring(s or ""):gsub("^%l", string.upper))
end

--- An author's round badge: their first letter, accent for Bragi.
function parts.avatar(name, parent, x, y, size, author)
    local bragi = parts.byBragi(author)
    ui.box(name, parent, { x, y, size, size }, { radius = size >= 24 and 12 or (size >= 20 and 10 or 8),
        fill = bragi and C.accent or C.borderStrong, border = C.transparent })
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    local letter = tostring(author or "?"):match("[%w]") or "?"
    ui.label(name .. "Letter", name, { 0, 0, size, size }, letter:upper(), { font = size >= 20 and "Bragi-12-Bold"
        or "Bragi-Caps", colour = bragi and C.onAccent or C.text, align = "CentreAligned" })
    return name
end

--- A rounded chip with a line of text (markup when opts.markup).
-- @param opts  { markup, colour, border, icon = { author } }
-- @return its width
function parts.chip(name, parent, x, y, label, opts)
    opts = opts or {}
    local markup = opts.markup and label or text.escape(label or "")
    local width = math.ceil(rows.measure("[font='Bragi-12']" .. markup)) + 22
    local left = 11
    if opts.author then
        width, left = width + 20, 28
    end
    ui.box(name, parent, { x, y, width, 24 }, { radius = 10, fill = C.transparent, border = opts.border or C.border })
    gitgud.setProperty(name, "CursorPassThroughEnabled", "true")
    if opts.author then
        parts.avatar(name .. "Who", name, 5, 4, 16, opts.author)
    end
    ui.label(name .. "Text", name, { left, 0, width - left - 6, 24 }, markup,
        { font = "Bragi-12", colour = opts.colour or C.sub, markup = true })
    return width
end

--- A caps heading, with a count at its right when given.
function parts.heading(name, parent, x, y, width, label, count)
    ui.heading(name, parent, { x, y, width, 18 }, label)
    if count then
        ui.label(name .. "Count", parent, { x + width - 60, y, 60, 18 }, tostring(count),
            { font = "Bragi-12", colour = C.disabled, align = "RightAligned" })
    end
end

--- A clickable area with no look but a hover wash (a row, a card's face).
-- @param opts  { radius = 8, fill, tooltip }
function parts.spot(name, parent, a, action, opts)
    opts = opts or {}
    ui.button(name, parent, a, "", { radius = parts.radius(opts.radius or 8), quiet = true, tooltip = opts.tooltip })
    gitgud.setProperty(name, "NormalFillColour", opts.fill or C.transparent)
    gitgud.setProperty(name, "HoverFillColour", C.hover)
    gitgud.setProperty(name, "PushedFillColour", C.sel)
    if opts.border then
        gitgud.setProperty(name, "BorderColour", opts.border)
    end
    gitgud.setCursor(name, "hand")
    gitgud.on(name .. ".clicked", action)
    return name
end

--- Give a built root its size, so the scrolling pane around it knows.
function parts.size(root, width, height)
    gitgud.setProperty(root, "Area", string.format("{{0,0},{0,0},{0,%d},{0,%d}}", math.ceil(width),
        math.ceil(height)))
end

return parts
