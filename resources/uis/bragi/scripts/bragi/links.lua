--- bragi/links.lua: clickable links in a conversation.
--
-- Web addresses and local paths in the text are drawn in the link colour,
-- with a clickable spot laid over each: a web link opens in the browser,
-- a folder opens in the file manager, and a file shows in its folder,
-- selected. A path is a link only while it's there on disk, so ordinary
-- words that look like paths stay plain.
--
-- What counts as a link:
--   [label](target)  a Markdown link to a web address or an existing path
--   https://...      a bare web address (http too)
--   D:\x\y, D:/x/y   an absolute path (on macOS and Linux: /x/y and ~/x)
--   x/y              a relative path, from the conversation's folder
--   `x.txt`          a path in backticks, even without a slash
-- A path may have spaces in it (the longest one that's there wins) and a
-- ":line" after it. Punctuation after a link isn't part of it.
--
--   links.target(s, folder)     what a link's text or target points to:
--                               { kind = "web" | "folder" | "file", target }
--   links.match(s, i, folder)   a link starting at byte i of plain text:
--                               its last byte and what it points to, or nil
--   links.markup(s, opts)       plain text as markup, its links coloured:
--                               markup, spans
--   links.attach(name, spans)   lay the clickable spots over a text's links
--   links.open(link)            open one, as a click does
--   links.onWiki(fn)            who opens { kind = "wiki" } links (the
--                               Wiki view: a page link in a wiki page)
--   links.onTask(fn)            who opens bragi://task/<owner>/<name>/<n>
--                               links ({ kind = "task" }: the task view)
--
-- A span is { first, last, link }: bytes first..last of the markup are the
-- link's text (gitgud.textRects finds where they're drawn).

local C = require("core.palette")
local geometry = require("ui.geometry")
local text = require("core.text")

local links = {}

local WINDOWS = gitgud.platform == "windows"
local RECHECK_MS = 5000   -- a path's answer is asked again after this
local MAX_WORDS = 8       -- a path with spaces spans at most this many words

local known = {}          -- path -> { kind, at }: what's on disk
local wikiHandler = nil   -- opens { kind = "wiki" } links
local taskHandler = nil   -- opens { kind = "task" } links
local spots = {}          -- spot window -> the link it opens

--- "folder", "file", or nil when nothing is there. Remembered a while.
local function kindOf(path)
    local now = gitgud.now()
    local seen = known[path]
    if seen and now - seen.at < RECHECK_MS then
        return seen.kind
    end
    local ok, kind = gitgud.pathExists(path)
    kind = ok and (kind or "file") or nil
    known[path] = { kind = kind, at = now }
    return kind
end

local function isAbsolute(path)
    if path:match("^%a:[/\\]") then
        return true
    end
    return not WINDOWS and path:match("^/") ~= nil
end

--- A path as written, made whole: ~ for home, relative ones from folder.
local function resolve(path, folder)
    if not WINDOWS and path:match("^~[/\\]") then
        return (gitgud.homeDir() or "~") .. path:sub(2)
    end
    if isAbsolute(path) then
        return path
    end
    if folder and folder ~= "" then
        return folder:gsub("[/\\]+$", "") .. "/" .. path
    end
    return nil
end

--- What a path points to, with any ":line" or "#anchor" after it left off.
local function pathLink(path, folder)
    for _, candidate in ipairs({ path, (path:gsub("#.*$", "")), (path:gsub(":%d+$", "")), (path:gsub(":%d+:%d+$", "")) }) do
        local full = candidate ~= "" and resolve(candidate, folder)
        local kind = full and kindOf(full)
        if kind then
            return { kind = kind, target = full }
        end
    end
    return nil
end

--- What a link's text or target points to, or nil: a web address, a task
-- (bragi://task/<owner>/<name>/<number>), or a path that's there.
-- @param s       a Markdown link's target, or a code span's text
-- @param folder  where relative paths start (nil: no relative paths)
function links.target(s, folder)
    s = text.trim(tostring(s or "")):gsub("^<(.*)>$", "%1")
    if s == "" or s:find("\n", 1, true) then
        return nil
    end
    if s:match("^https?://%S+$") or s:match("^mailto:%S+$") then
        return { kind = "web", target = s }
    end
    if s:match("^bragi://task/[^/%s]+/[^/%s]+/%d+$") then
        return { kind = "task", target = s }
    end
    if s:match("^file:///") then
        s = s:gsub("^file:///", ""):gsub("%%20", " ")
        if not WINDOWS then
            s = "/" .. s
        end
    end
    return pathLink(s, folder)
end

--- Leave trailing punctuation off a link's text, and a closing bracket
-- that has no opening one in it.
local function trimEnd(s)
    while true do
        local last = s:sub(-1)
        if last:match("[%.,;:!%?'\"%*]") then
            s = s:sub(1, -2)
        elseif last == ")" or last == "]" then
            local open = last == ")" and "%(" or "%["
            local _, opens = s:gsub(open, "")
            local _, closes = s:gsub("%" .. last, "")
            if closes <= opens then
                return s
            end
            s = s:sub(1, -2)
        else
            return s
        end
    end
end

-- A link starts at a word's start, not inside one.
local function atStart(s, i)
    return i == 1 or s:sub(i - 1, i - 1):match("[%s%c%(%[<\"'=,;%*]") ~= nil
end

--- A link starting at byte i of plain text, or nil.
-- @return the link's last byte, and { kind, target }
function links.match(s, i, folder)
    if not atStart(s, i) then
        return nil
    end
    local c = s:sub(i, i)
    if c == "b" then
        local task = s:match("^bragi://task/[^/%s]+/[^/%s]+/%d+", i)
        if task then
            return i + #task - 1, { kind = "task", target = task }
        end
    end
    if c == "h" then
        local url = s:match("^https?://[^%s%c<>\"`]+", i)
        if url then
            url = trimEnd(url)
            if url:match("^https?://.") then
                return i + #url - 1, { kind = "web", target = url }
            end
        end
        -- Not a web address: it may still be a relative path ("hooks/x").
    end
    local absolute = s:match("^%a:[/\\]", i) or (not WINDOWS and (s:match("^/%S", i) or s:match("^~[/\\]", i)))
    local word = s:match("^[^%s%c<>\"|`]+", i)
    if not word then
        return nil
    end
    if not absolute and not (folder and word:match("^[%w_%.%-]+[/\\]")) then
        return nil
    end
    -- The longest run of words (to the line's end) that's a path on disk.
    local ends = { i + #word - 1 }
    local at = i + #word
    while #ends < MAX_WORDS do
        local gap, nextWord = s:match("^( )([^%s%c<>\"|`]+)", at)
        if not gap then
            break
        end
        at = at + 1 + #nextWord
        ends[#ends + 1] = at - 1
    end
    for k = #ends, 1, -1 do
        local candidate = trimEnd(s:sub(i, ends[k]))
        local link = candidate ~= "" and pathLink(candidate, folder)
        if link then
            return i + #candidate - 1, link
        end
    end
    return nil
end

--- Plain text as markup with its links coloured.
-- @param s     the text
-- @param opts  { folder, colour = the text's (C.text), link = the links' (C.link) }
-- @return markup, and the links' spans in it
function links.markup(s, opts)
    opts = opts or {}
    s = tostring(s or "")
    local linkColour = opts.link or C.link
    local colour = opts.colour or C.text
    local out, spans, len = {}, {}, 0
    local function put(piece)
        out[#out + 1] = piece
        len = len + #piece
    end
    local i, plainFrom = 1, 1
    while i <= #s do
        local last, link = links.match(s, i, opts.folder)
        if last then
            put(text.escape(s:sub(plainFrom, i - 1)))
            put("[colour='" .. linkColour .. "']")
            local first = len + 1
            put(text.escape(s:sub(i, last)))
            spans[#spans + 1] = { first = first, last = len, link = link }
            put("[colour='" .. colour .. "']")
            i = last + 1
            plainFrom = i
        else
            i = i + 1
        end
    end
    put(text.escape(s:sub(plainFrom)))
    return table.concat(out), spans
end

--- Open a link, as a click on it does: a web address in the browser, a
-- folder in the file manager, a file shown in its folder.
-- @return true, or nil and why
function links.open(link)
    if not link then
        return nil, "no link"
    end
    if link.kind == "wiki" then
        if not wikiHandler then
            return nil, "no wiki"
        end
        wikiHandler(link)
        return true
    end
    if link.kind == "task" then
        if not taskHandler then
            return nil, "no task view"
        end
        taskHandler(link)
        return true
    end
    local target = link.target
    if link.kind ~= "web" and WINDOWS then
        target = target:gsub("/", "\\")
    end
    local ok, err
    if link.kind == "file" then
        ok, err = gitgud.showInFolder(target)
    else
        ok, err = gitgud.openExternal(target)
    end
    if not ok then
        require("core.status").error(err or ("Could not open " .. target))
    end
    return ok, err
end

--- Set who opens wiki links: fn(link).
function links.onWiki(fn)
    wikiHandler = fn
end

--- Set who opens task links: fn(link).
function links.onTask(fn)
    taskHandler = fn
end

--- Lay a clickable spot over each line of each link in a static text
-- (after its text and size are set; again whenever they change). Spots
-- from before that aren't needed now are hidden.
-- @param name   the text's window
-- @param spans  from links.markup or markdown.inline
local made = 0 -- spots made since the last sweep
local SWEEP_EVERY = 400

--- Forget the spots whose windows are gone (their text was drawn again or
-- went), with their click handlers: kept, they only ever grew.
local function sweep()
    for spot in pairs(spots) do
        if not gitgud.getRect(spot) then
            spots[spot] = nil
            gitgud.off(spot .. ".clicked")
        end
    end
end

function links.attach(name, spans)
    local n = 0
    for _, span in ipairs(spans or {}) do
        for _, r in ipairs(gitgud.textRects(name, span.first, span.last)) do
            n = n + 1
            local spot = name .. "Link" .. n
            if not gitgud.getRect(spot) then
                gitgud.createWindow("Bragi/Button4", spot, name)
                gitgud.setProperty(spot, "Text", "")
                gitgud.setProperty(spot, "NormalFillColour", C.transparent)
                gitgud.setProperty(spot, "PushedFillColour", C.sel)
                gitgud.setProperty(spot, "BorderColour", C.transparent)
                -- A light wash of the link colour under the pointer.
                gitgud.setProperty(spot, "HoverFillColour", "33" .. C.link:sub(3))
                gitgud.setCursor(spot, "hand")
                gitgud.off(spot .. ".clicked") -- a window of that name before
                gitgud.on(spot .. ".clicked", function()
                    links.open(spots[spot])
                end)
                made = made + 1
                if made >= SWEEP_EVERY then
                    made = 0
                    sweep()
                end
            end
            spots[spot] = span.link
            gitgud.setProperty(spot, "TooltipText", span.link.tooltip or span.link.target)
            gitgud.setProperty(spot, "Area", geometry.rect(math.floor(r[1]) - 2, math.floor(r[2]),
                math.ceil(r[3]) + 4, math.ceil(r[4])))
            gitgud.setVisible(spot, true)
        end
    end
    local k = n + 1
    while gitgud.getRect(name .. "Link" .. k) do
        gitgud.setVisible(name .. "Link" .. k, false)
        spots[name .. "Link" .. k] = nil
        k = k + 1
    end
    return n
end

--- The links laid over a text: { { spot, kind, target }, ... } (for tests).
function links.shown(name)
    local out = {}
    local k = 1
    while gitgud.getRect(name .. "Link" .. k) do
        local link = spots[name .. "Link" .. k]
        if link then
            out[#out + 1] = { spot = name .. "Link" .. k, kind = link.kind, target = link.target }
        end
        k = k + 1
    end
    return out
end

return links
