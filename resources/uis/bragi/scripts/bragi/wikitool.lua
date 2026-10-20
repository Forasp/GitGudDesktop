--- bragi/wikitool.lua: reading the wikis, for Claude Code. Three read-only
-- tools (through bragi/uitools.lua) that go to Bragi's store
-- (bragi/server.lua; on this computer, bragi/store.lua), so quick answers
-- (bragi/quick.lua) and the main session can answer from the wikis:
--
--   bragi_wiki_list     the wikis and their pages
--   bragi_wiki_read     one page's text: { page, wiki? }
--   bragi_wiki_search   pages with every word: { query }
--
-- They only read, so none asks with a permission card (noCard).
--
-- A wiki is named as the views name it: "shared" for the shared wiki, a
-- project's name for its own ("repo", or "local/repo").
--
-- Public API: wikitool.definitions(), wikitool.handle(call, reply)

local server = require("bragi.server")
local text = require("core.text")

local wikitool = { name = "bragi.wikitool" }

local API = "/api/bragi/v0"
local MAX_PAGE_CHARS = 12000
local MAX_HITS = 20

local function def(name, description, properties, required)
    return {
        name = name,
        description = description,
        inputSchema = { type = "object", properties = properties, required = required,
            additionalProperties = false },
        annotations = { readOnlyHint = true },
        noCard = true, -- they only read (bragi/uitools.lua)
    }
end

function wikitool.definitions()
    return {
        def("bragi_wiki_list", "The wikis on this computer (the shared one and each project's) and their pages.",
            {}),
        def("bragi_wiki_read", "One wiki page's text (Markdown).",
            { page = { type = "string", description = "The page: its title or path, as bragi_wiki_list shows it." },
              wiki = { type = "string", description = "\"shared\" or a project's name (default: the shared wiki, "
                  .. "then the others)." } },
            { "page" }),
        def("bragi_wiki_search", "Wiki pages that contain every word of the query, with the lines that match.",
            { query = { type = "string", description = "Words to find." } },
            { "query" }),
    }
end

--- "local/<name>" for what the agent calls a wiki.
local function repoOf(wiki)
    wiki = text.trim(tostring(wiki or ""))
    if wiki == "" then
        return nil
    end
    return wiki:find("/", 1, true) and wiki or ("local/" .. wiki)
end

local function nameOf(w)
    return w.shared and "shared" or (w.repo or ""):gsub("^local/", "")
end

local function list(reply)
    server.request("GET", API .. "/wikis?limit=50", nil, function(wikis)
        local lines, pending = {}, 0
        wikis = type(wikis) == "table" and wikis or {}
        if #wikis == 0 then
            reply("No wikis yet.", false)
            return
        end
        local sections = {}
        local function finish()
            for _, s in ipairs(sections) do
                lines[#lines + 1] = s
            end
            reply(table.concat(lines, "\n"), false)
        end
        for i, w in ipairs(wikis) do
            pending = pending + 1
            server.request("GET", API .. "/repos/" .. w.repo .. "/wiki/pages?limit=50", nil, function(pages)
                local names = {}
                for _, p in ipairs(type(pages) == "table" and pages or {}) do
                    names[#names + 1] = "- " .. tostring(p.sub_url)
                end
                sections[i] = "Wiki " .. nameOf(w) .. ":\n" .. (#names > 0 and table.concat(names, "\n") or "- (no pages)")
                pending = pending - 1
                if pending == 0 then
                    finish()
                end
            end, function(msg)
                sections[i] = "Wiki " .. nameOf(w) .. ": " .. tostring(msg)
                pending = pending - 1
                if pending == 0 then
                    finish()
                end
            end)
        end
    end, function(msg)
        reply("The wikis couldn't be read: " .. tostring(msg), true)
    end)
end

local function read(args, reply)
    local page = text.trim(tostring(args.page or ""))
    if page == "" then
        return reply("Which page?", true)
    end
    local sub = require("bragi.store").subUrl(page)
    local function try(repos, i)
        local repo = repos[i]
        if not repo then
            return reply("No page \"" .. page .. "\" in " .. (args.wiki and tostring(args.wiki) or "the wikis") .. ".", true)
        end
        server.request("GET", API .. "/repos/" .. repo .. "/wiki/page/" .. sub .. "?html=false", nil, function(p)
            local body = type(p) == "table" and tostring(p.content or "") or ""
            if #body > MAX_PAGE_CHARS then
                body = body:sub(1, MAX_PAGE_CHARS) .. "\n..."
            end
            reply("Page " .. sub .. " (wiki " .. repo:gsub("^local/", "") .. "):\n\n" .. body, false)
        end, function()
            try(repos, i + 1)
        end)
    end
    local only = repoOf(args.wiki)
    if only then
        return try({ only }, 1)
    end
    server.request("GET", API .. "/wikis?limit=50", nil, function(wikis)
        local repos = {}
        for _, w in ipairs(type(wikis) == "table" and wikis or {}) do
            repos[#repos + 1] = w.repo
        end
        try(repos, 1)
    end, function(msg)
        reply("The wikis couldn't be read: " .. tostring(msg), true)
    end)
end

local function encode(s)
    return (s:gsub("[^%w%-%._~]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

local function search(args, reply)
    local q = text.trim(tostring(args.query or ""))
    if q == "" then
        return reply("What to search for?", true)
    end
    server.request("GET", API .. "/wikis/search?limit=50&q=" .. encode(q), nil, function(hits)
        hits = type(hits) == "table" and hits or {}
        if #hits == 0 then
            return reply("No wiki page has all of: " .. q .. ".", false)
        end
        local lines = {}
        for i, h in ipairs(hits) do
            if i > MAX_HITS then
                lines[#lines + 1] = "... and " .. (#hits - MAX_HITS) .. " more"
                break
            end
            lines[#lines + 1] = "- " .. tostring(h.sub_url) .. " (wiki " .. (h.shared and "shared"
                or tostring(h.repo or ""):gsub("^local/", "")) .. ")"
            for _, l in ipairs(type(h.lines) == "table" and h.lines or {}) do
                lines[#lines + 1] = "    " .. tostring(l.number) .. ": " .. tostring(l.text)
            end
        end
        reply(table.concat(lines, "\n"), false)
    end, function(msg)
        reply("The search failed: " .. tostring(msg), true)
    end)
end

--- Answer one call (later, through reply).
function wikitool.handle(call, reply)
    local args = type(call.arguments) == "table" and call.arguments or {}
    if not server.info().signedIn then
        return "The wikis aren't available.", true
    end
    if call.tool == "bragi_wiki_list" then
        list(reply)
    elseif call.tool == "bragi_wiki_read" then
        read(args, reply)
    elseif call.tool == "bragi_wiki_search" then
        search(args, reply)
    else
        return "No tool named " .. tostring(call.tool) .. ".", true
    end
end

function wikitool.init()
    require("bragi.uitools").register(wikitool.definitions(), wikitool.handle)
end

return wikitool
