--- bragi/wikilinks.lua: links between wiki pages, for the store
-- (bragi/store.lua: the links answer) and the Wiki view.
--
-- A link is [[Page name]], or [[Page name|shown text]]. The name finds a
-- page by its path or its title, ignoring case and spaces against dashes;
-- a name without a folder also finds a page of that name in a folder.
-- Links inside code (fenced blocks, `backticks`) don't count.
--
--   wikilinks.find(source)          { { target, label, line } } in order
--   wikilinks.key(name)             the form names are compared in
--   wikilinks.index(pages)          a lookup for resolve, from { sub_url }
--   wikilinks.resolve(index, name)  the page's sub_url, or nil
--   wikilinks.summary(source)       the first paragraph, plain, cut short
--   wikilinks.plain(s)              s with [[links]] as their shown text

local text = require("core.text")

local wikilinks = {}

local SUMMARY = 220   -- longest summary, in bytes

--- The form names are compared in: trimmed, lower case, spaces as dashes.
function wikilinks.key(name)
    local parts = {}
    for raw in tostring(name or ""):gmatch("[^/]+") do
        local part = text.trim(raw):lower():gsub("[%s_]+", "-")
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

--- Every [[link]] in some Markdown: { target, label, line }, in order.
function wikilinks.find(source)
    local out = {}
    local fenced = false
    local n = 0
    for line in ((source or ""):gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        if line:match("^%s*```") or line:match("^%s*~~~") then
            fenced = not fenced
        elseif not fenced then
            local bare = line:gsub("`[^`]*`", function(code)
                return string.rep(" ", #code)
            end)
            for inner in bare:gmatch("%[%[(.-)%]%]") do
                local target, label = inner:match("^(.-)|(.*)$")
                target = text.trim(target or inner)
                label = text.trim(label or "")
                if target ~= "" then
                    out[#out + 1] = { target = target, label = label ~= "" and label or target, line = n,
                        context = text.trim(line) }
                end
            end
        end
    end
    return out
end

--- A lookup for resolve: page paths first, then titles, then bare names
-- (a page "guides/Deep-Dive" is found as "Deep Dive" too, unless another
-- page is called that outright).
function wikilinks.index(pages)
    local exact, leaf = {}, {}
    for _, p in ipairs(pages or {}) do
        local sub = p.sub_url or ""
        exact[wikilinks.key(sub)] = sub
        if p.title then
            exact[wikilinks.key(p.title)] = exact[wikilinks.key(p.title)] or sub
        end
        local name = wikilinks.key(sub:match("([^/]+)$") or sub)
        leaf[name] = leaf[name] or sub
    end
    return { exact = exact, leaf = leaf }
end

--- The sub_url a link's name points to, or nil when there's no such page.
function wikilinks.resolve(index, name)
    local key = wikilinks.key(name)
    return index.exact[key] or (not key:find("/", 1, true) and index.leaf[key]) or nil
end

--- Text with [[links]] as the text they show.
function wikilinks.plain(s)
    return ((s or ""):gsub("%[%[(.-)%]%]", function(inner)
        local _, label = inner:match("^(.-)|(.*)$")
        return label or inner
    end))
end

--- The first paragraph of a page, as plain text: no headings, code, or
-- Markdown marks; cut at a word near SUMMARY bytes.
function wikilinks.summary(source)
    local lines = {}
    local fenced = false
    for line in ((source or ""):gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*```") or line:match("^%s*~~~") then
            fenced = not fenced
            if #lines > 0 then
                break
            end
        elseif not fenced then
            local blank = line:match("^%s*$")
            local skip = line:match("^%s*#") or line:match("^%s*|") or line:match("^%s*%-%-%-") or line:match("^%s*>")
            if blank or skip then
                if #lines > 0 then
                    break
                end
            else
                lines[#lines + 1] = text.trim((line:gsub("^%s*[%-%*%+]%s+", ""):gsub("^%s*%d+[%.%)]%s+", "")))
            end
        end
    end
    local s = wikilinks.plain(table.concat(lines, " "))
    s = s:gsub("!?%[(.-)%]%([^%)]*%)", "%1"):gsub("[`*_]", ""):gsub("%s+", " ")
    s = text.trim(s)
    if #s > SUMMARY then
        local cut = s:sub(1, SUMMARY):match("^(.*)%s") or s:sub(1, SUMMARY)
        s = cut:gsub("[%s%p]+$", "") .. "\u{2026}"
    end
    return s
end

return wikilinks
