--- core/text.lua — string helpers: CEGUI text markup, paths, plurals, dates.
--
-- CEGUI renders inline markup such as [colour='FFRRGGBB'] and
-- [font='Gitgud-UI-Bold'] inside any widget text. Anything that comes from
-- the repository (file names, commit messages, diff lines) must go through
-- escape() first, or a literal "[" would be parsed as a tag.

local text = {}

--- Escape CEGUI markup so the string renders literally.
-- @param s  any string
-- @return the string with every "[" escaped
function text.escape(s)
    return (tostring(s):gsub("%[", "\\["))
end

--- Colour a (literal) string.
-- @param colour  AARRGGBB hex
-- @param s       text; escaped for you
-- @return a markup string
function text.colour(colour, s)
    return "[colour='" .. colour .. "']" .. text.escape(s)
end

--- Render a (literal) string in another font.
-- @param font  font name, e.g. "Gitgud-UI-Bold"
-- @param s     text; escaped for you
-- @return a markup string (the font is reset to the widget default after)
function text.font(font, s)
    return "[font='" .. font .. "']" .. text.escape(s) .. "[font='']"
end

--- Markup that makes a list row at least `height` pixels tall, with the
-- rest of the row vertically centred (an invisible 1px-wide image sets the
-- line height). Put it at the start of the row's text.
-- @param height  row height in pixels
-- @return markup
function text.rowHeight(height)
    return "[vert-formatting='CentreAligned'][image-size='w:1 h:" .. height
        .. "'][image='Gitgud-Images/Spacer']"
end

--- Shorten a string to `limit` characters by cutting from the front
-- ("C:/Users/me/src/project" -> "…/src/project"), keeping the end, which is
-- the most specific part of a path.
-- @param s      plain text
-- @param limit  maximum length
-- @return the (possibly) shortened text
function text.truncateLeft(s, limit)
    if #s <= limit then
        return s
    end

    return "…" .. s:sub(#s - limit + 2)
end

--- Last path component ("src/app/main.cpp" -> "main.cpp").
-- @param path  a path with / or \ separators
-- @return the file or folder name
function text.basename(path)
    return path:match("([^/\\]+)[/\\]*$") or path
end

--- Everything before the last path component ("src/app/main.cpp" -> "src/app").
-- @param path  a path with / or \ separators
-- @return the parent folder, or "" for a bare name
function text.dirname(path)
    local name = text.basename(path)
    local dir = path:sub(1, #path - #name)

    return (dir:gsub("[/\\]+$", ""))
end

--- File extension without the dot, lower-cased ("" when there is none).
-- @param path  a file path
-- @return the extension
function text.extension(path)
    local ext = text.basename(path):match("%.([^.]+)$")

    return ext and ext:lower() or ""
end

--- "1 file" / "3 files".
-- @param count  a number
-- @param noun   singular noun
-- @param plural optional irregular plural
-- @return the count followed by the right form of the noun
function text.plural(count, noun, plural)
    if count == 1 then
        return "1 " .. noun
    end

    return tostring(count) .. " " .. (plural or (noun .. "s"))
end

--- Trim leading and trailing whitespace.
-- @param s  a string
-- @return the trimmed string
function text.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split a string on a literal separator.
-- @param s    the string
-- @param sep  separator (plain text, not a pattern)
-- @return an array of pieces (empty pieces included)
function text.split(s, sep)
    local parts = {}
    local start = 1

    while true do
        local first, last = s:find(sep, start, true)
        if not first then
            parts[#parts + 1] = s:sub(start)
            break
        end
        parts[#parts + 1] = s:sub(start, first - 1)
        start = last + 1
    end

    return parts
end

--- Case-insensitive "does haystack contain needle" (plain text).
-- @param haystack  string to search
-- @param needle    string to find; "" always matches
-- @return true when found
function text.contains(haystack, needle)
    if needle == "" then
        return true
    end

    return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

--- Human-friendly time since a Unix timestamp ("just now", "5 minutes ago").
-- @param timestamp  seconds since the epoch
-- @return a short relative description
function text.ago(timestamp)
    local seconds = os.time() - timestamp

    if seconds < 45 then
        return "just now"
    end
    if seconds < 90 then
        return "a minute ago"
    end

    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return text.plural(minutes, "minute") .. " ago"
    end

    local hours = math.floor(minutes / 60)
    if hours < 24 then
        return text.plural(hours, "hour") .. " ago"
    end

    local days = math.floor(hours / 24)
    if days < 30 then
        return text.plural(days, "day") .. " ago"
    end

    return os.date("%Y-%m-%d", timestamp)
end

--- Split a commit message into its summary line and the body after it.
-- @param message  full commit message
-- @return summary, body (body has no leading blank lines)
function text.splitMessage(message)
    local summary, body = message:match("^([^\n]*)\n?(.*)$")
    body = (body or ""):gsub("^%s*\n", ""):gsub("%s+$", "")

    return summary or message, body
end

return text
