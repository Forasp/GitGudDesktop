--- bragi/vocabulary.lua: what the pre-pass filter (prompts/heard-text.md)
-- knows about the words the user uses.
--
-- Speech-to-text mishears names. The filter repairs them, but it once
-- "repaired" "cloud desktop" to "Gitgud Desktop" because all it knew were
-- the open repository's words. So it gets, with every message:
--
-- * a conversation digest (vocabulary.digest): the last few exchanges and
--   the names and terms mentioned in them, a few hundred tokens;
-- * the learned corrections (vocabulary.corrections): `heard -> meant`
--   pairs saved when the user corrects a hearing ("I said X, not Y", or by
--   editing the repaired text before sending it), in bragi.corrections
--   (a JSON list, newest first); Settings, Appearance and voice lists them;
-- * the vocabulary (vocabulary.words): the products the user uses, then the
--   open repository's words (its name, branches, top-level folders,
--   changed files, files the agent touched), then terms from the
--   conversation.
--
-- vocabulary.hotwords() is the same list shaped for the recognizer
-- (corrections first): bragi/voice.lua sends it as the listen hello's
-- `vocabulary`, and again in a `config` when it changes while listening.
--
-- Public API: vocabulary.PRODUCTS, vocabulary.words(), vocabulary.digest(),
-- vocabulary.corrections(), vocabulary.learn(heard, meant, how),
-- vocabulary.forget(heard), vocabulary.hotwords(),
-- vocabulary.fromEdit(before, after), vocabulary.cards()

local agent = require("bragi.agent")
local repo = require("core.repo")
local settings = require("core.settings")
local text = require("core.text")

local vocabulary = { name = "bragi.vocabulary" }

-- Always in the vocabulary: the products Bragi's users talk about.
vocabulary.PRODUCTS = { "Claude", "Claude Desktop", "Claude Code", "Bragi", "GitGud", "Haiku",
    "Opus", "Sonnet" }

local KEY = "bragi.corrections"
local MAX_WORDS = 200         -- the vocabulary sent with each message
local MAX_HOTWORDS = 100      -- the server takes up to 200
local MAX_HOTWORD_BYTES = 64  -- and phrases up to 64 bytes
local MAX_CORRECTIONS = 100
local MAX_SPAN_WORDS = 4      -- a correction is a short phrase each way
local MAX_SPAN_CHARS = 40
local MAX_BRANCHES = 30
local MAX_FOLDERS = 30
local MAX_FILES = 30
local DIGEST_EXCHANGES = 3    -- recent exchanges in the digest
local DIGEST_CHARS = 280      -- of each side of an exchange
local DIGEST_ITEMS = 12       -- messages names are taken from
local DIGEST_NAMES = 30
local REPO_TTL_MS = 30000     -- the repository's words are read again after this

-- Capitalised words that start sentences, not names.
local COMMON = {}
for w in ([[a an and are as at be but by can could did do does done for from go got had has have he hello here hi
how i i'll i'm i've if in is it it's its just let let's maybe me my no not now of oh ok okay on or our please
she since so sure thanks that that's the their then there they this to up was we well what when where which who
why will with yeah yes you you're your also first next one two]]):gmatch("%S+") do
    COMMON[w] = true
end

-- ===================================================================
-- Learned corrections
-- ===================================================================

--- The learned corrections, newest first: { { heard, meant, how } }.
function vocabulary.corrections()
    local list = gitgud.jsonDecode(settings.get(KEY, ""))
    local out = {}
    for _, c in ipairs(type(list) == "table" and list or {}) do
        if type(c) == "table" and type(c.heard) == "string" and type(c.meant) == "string" then
            out[#out + 1] = { heard = c.heard, meant = c.meant, how = c.how }
        end
    end
    return out
end

local function save(list)
    settings.set(KEY, #list > 0 and gitgud.jsonEncode(list) or nil)
end

local function wordCount(s)
    local n = 0
    for _ in s:gmatch("%S+") do
        n = n + 1
    end
    return n
end

--- A phrase fit to be one side of a correction: short, not empty.
local function span(s)
    s = text.trim(tostring(s or "")):gsub("%s+", " ")
    s = s:gsub("^[%p]+", ""):gsub("[%.,;:!%?\"]+$", "")
    local n = wordCount(s)
    if n == 0 or n > MAX_SPAN_WORDS or #s > MAX_SPAN_CHARS then
        return nil
    end
    return s
end

--- Remember that `heard` means `meant`. True when it was saved.
-- @param how  "said" (the user said so) or "edited" (they changed it before sending)
function vocabulary.learn(heard, meant, how)
    heard, meant = span(heard), span(meant)
    if not heard or not meant or heard == meant then
        return false
    end
    local list = { { heard = heard, meant = meant, how = how } }
    for _, c in ipairs(vocabulary.corrections()) do
        if c.heard:lower() ~= heard:lower() and #list < MAX_CORRECTIONS then
            list[#list + 1] = c
        end
    end
    save(list)
    return true
end

--- Forget the correction for `heard`.
function vocabulary.forget(heard)
    local list = {}
    for _, c in ipairs(vocabulary.corrections()) do
        if c.heard ~= heard then
            list[#list + 1] = c
        end
    end
    save(list)
end

local function bare(word)
    return (word:gsub("^[%p]+", ""):gsub("[%.,;:!%?\"]+$", ""))
end

--- What the user changed in a repaired message before sending it, as one
-- correction: the words that differ between `before` and `after` when
-- everything around them is the same. Nil when it isn't one short swap.
-- @return heard, meant
function vocabulary.fromEdit(before, after)
    local a, b = {}, {}
    for w in tostring(before or ""):gmatch("%S+") do
        a[#a + 1] = w
    end
    for w in tostring(after or ""):gmatch("%S+") do
        b[#b + 1] = w
    end
    local head = 0
    while head < #a and head < #b and bare(a[head + 1]) == bare(b[head + 1]) do
        head = head + 1
    end
    local tail = 0
    while tail < #a - head and tail < #b - head and bare(a[#a - tail]) == bare(b[#b - tail]) do
        tail = tail + 1
    end
    -- Most of the message must be untouched: a rewrite isn't a correction.
    if head + tail < math.max(1, math.floor(#a / 2)) then
        return nil
    end
    local heard = span(table.concat(a, " ", head + 1, #a - tail))
    local meant = span(table.concat(b, " ", head + 1, #b - tail))
    if not heard or not meant or heard == meant then
        return nil
    end
    return heard, meant
end

-- ===================================================================
-- The conversation digest
-- ===================================================================

local function cut(s, max, fromEnd)
    s = text.trim(tostring(s or "")):gsub("%s+", " ")
    if #s > max then
        s = fromEnd and ("..." .. s:sub(-max)) or (s:sub(1, max) .. "...")
    end
    return s
end

--- Names and terms in a piece of text, in order: `code`, file names and
-- paths, CamelCase or snake_case symbols, and runs of capitalised words
-- ("Claude Desktop", "Claude Code").
local function namesIn(s, add)
    for code in s:gmatch("`([^`\n]+)`") do
        if #code <= 40 then
            add(code)
        end
    end
    s = s:gsub("`[^`\n]*`", " ")
    local run = {}
    local function flush()
        -- A lone capitalised everyday word starts a sentence; it isn't a name.
        while #run > 0 and COMMON[run[1]:lower()] do
            table.remove(run, 1)
        end
        while #run > 0 and run[#run]:match("^%d+$") == nil and COMMON[run[#run]:lower()] do
            table.remove(run)
        end
        if #run > 0 and not (#run == 1 and run[1]:match("^%d+$")) then
            add(table.concat(run, " "))
        end
        run = {}
    end
    for word in s:gmatch("%S+") do
        local w = bare(word)
        local symbol = (w:find("[%w][/_%.][%w]") or w:find("%l%u")) and not w:match("^[%d%.]+$")
        if symbol then
            flush()
            add(w)
        elseif w:match("^%u[%w'%-]*$") or (#run > 0 and w:match("^%d+$")) then
            run[#run + 1] = w
            if word ~= w then
                flush() -- punctuation ends the name
            end
        else
            flush()
        end
    end
    flush()
end

--- What the filter knows of the conversation: { recent = { { you, agent } },
-- names = { ... } }, newest names first.
function vocabulary.digest()
    local items = agent.items()
    local exchanges, cur = {}, nil
    for _, item in ipairs(items) do
        if item.kind == "user" and (item.text or "") ~= "" then
            cur = { you = item.text, agent = "" }
            exchanges[#exchanges + 1] = cur
        elseif item.kind == "assistant" and cur and (item.text or "") ~= "" then
            cur.agent = cur.agent ~= "" and (cur.agent .. "\n" .. item.text) or item.text
        end
    end
    local recent = {}
    for i = math.max(1, #exchanges - DIGEST_EXCHANGES + 1), #exchanges do
        local ex = exchanges[i]
        recent[#recent + 1] = { you = cut(ex.you, DIGEST_CHARS), agent = cut(ex.agent, DIGEST_CHARS, true) }
    end
    local names, seen = {}, {}
    local function add(name)
        name = text.trim(name)
        local key = name:lower()
        if name ~= "" and not seen[key] and #names < DIGEST_NAMES then
            seen[key] = true
            names[#names + 1] = name
        end
    end
    local taken = 0
    for i = #items, 1, -1 do
        local item = items[i]
        if (item.kind == "user" or item.kind == "assistant") and (item.text or "") ~= "" then
            namesIn(item.text, add)
            taken = taken + 1
            if taken >= DIGEST_ITEMS then
                break
            end
        end
    end
    return { recent = recent, names = names }
end

-- ===================================================================
-- The vocabulary
-- ===================================================================

local repoWords = nil       -- { key, at, list }

--- The open repository's words: its name, branch, branches, top-level
-- folders, changed files, files the agent touched, remotes.
local function fromRepository()
    local state = repo.state()
    local key = tostring(state.path) .. "|" .. tostring(state.branch)
    local now = gitgud.now()
    if repoWords and repoWords.key == key and now - repoWords.at < REPO_TTL_MS then
        return repoWords.list
    end
    local list = {}
    local function add(w)
        if type(w) == "string" and w ~= "" then
            list[#list + 1] = w
        end
    end
    add(state.name)
    add(state.branch)
    if state.open then
        local ok, branches = pcall(gitgud.branches)
        local n = 0
        for _, b in ipairs(ok and type(branches) == "table" and branches or {}) do
            if not b.isRemote and n < MAX_BRANCHES then
                n = n + 1
                add(b.name)
            end
        end
        local okTree, entries = pcall(gitgud.listTree, "HEAD", "")
        n = 0
        for _, e in ipairs(okTree and type(entries) == "table" and entries or {}) do
            if e.isDir and n < MAX_FOLDERS then
                n = n + 1
                add(e.name)
            end
        end
    end
    local n = 0
    for _, f in ipairs(state.files or {}) do
        if n < MAX_FILES then
            n = n + 1
            add(f.path)
        end
    end
    for _, r in ipairs(state.remotes or {}) do
        add(type(r) == "table" and r.name or r)
    end
    repoWords = { key = key, at = now, list = list }
    return list
end

--- Files the agent's tools touched lately, newest first.
local function touched()
    local items = agent.items()
    local list = {}
    for i = #items, 1, -1 do
        local item = items[i]
        if item.kind == "step" and item.inputText and #list < MAX_FILES then
            local input = gitgud.jsonDecode(item.inputText)
            local path = type(input) == "table" and (input.file_path or input.notebook_path or input.path)
            if type(path) == "string" and path ~= "" then
                list[#list + 1] = path:gsub("\\", "/"):match("[^/]+$") or path
            end
        end
    end
    return list
end

local function collect(lists, max)
    local words, seen = {}, {}
    for _, l in ipairs(lists) do
        for _, w in ipairs(l) do
            local key = tostring(w):lower()
            if w ~= "" and not seen[key] and #words < max then
                seen[key] = true
                words[#words + 1] = w
            end
        end
    end
    return words
end

--- Words the user uses: the products, the repository's, the conversation's.
-- @param digest  optional: vocabulary.digest() already made
function vocabulary.words(digest)
    digest = digest or vocabulary.digest()
    return collect({ vocabulary.PRODUCTS, fromRepository(), touched(), digest.names }, MAX_WORDS)
end

--- A phrase as the recognizer takes it, or nil: a path's last part
-- ("src/ui/ColourMap.h" is "ColourMap.h"), spaces collapsed, ASCII
-- letters, digits, and punctuation only, never '/' or ':' (the server's
-- hotword format reserves them), at most MAX_HOTWORD_BYTES.
local function hotword(w)
    local s = tostring(w):gsub("\\", "/"):gsub("/+$", "")
    s = (s:match("[^/]+$") or s):gsub(":", " "):gsub("%s+", " ")
    s = text.trim(s)
    if s == "" or #s > MAX_HOTWORD_BYTES or s:find("[^%w%p ]") then
        return nil
    end
    return s
end

--- The list for the recognizer's hotwords: what corrections meant, then
-- the vocabulary, each shaped by hotword().
function vocabulary.hotwords()
    local list = {}
    local function add(w)
        list[#list + 1] = hotword(w)
    end
    for _, c in ipairs(vocabulary.corrections()) do
        add(c.meant)
    end
    for _, w in ipairs(vocabulary.words()) do
        add(w)
    end
    return collect({ list }, MAX_HOTWORDS)
end

-- ===================================================================
-- Settings
-- ===================================================================

--- The "Learned corrections" card for Settings, Appearance and voice.
-- @param rebuild  called after one is removed
function vocabulary.cards(rebuild)
    local rows = {}
    for _, c in ipairs(vocabulary.corrections()) do
        rows[#rows + 1] = { kind = "action", title = "\u{201C}" .. c.heard .. "\u{201D} means \u{201C}" .. c.meant
            .. "\u{201D}", sub = c.how == "edited" and "You changed it before sending." or "You said so.",
            button = "Remove", run = function()
                vocabulary.forget(c.heard)
                gitgud.after(0, rebuild)
            end }
    end
    if #rows == 0 then
        rows[1] = { kind = "info", title = "None yet",
            sub = "Correct a word Bragi misheard (\u{201C}I said Claude, not cloud\u{201D}, or edit it before "
                .. "sending) and it's remembered here." }
    end
    return rows
end

return vocabulary
