--- bragi.phonemes: English text to the phonemes Bragi's built-in voice reads.
--
-- The voice was trained on misaki's American English phonemes (Kokoro's
-- spelling: hexgrad's misaki, Apache-2.0), so this is misaki's English rules
-- ported to Lua, over its two dictionaries (resources/uis/bragi/phonemes/
-- en-us-gold.tsv and en-us-silver.tsv, read through gitgud.lookup): its
-- tokenizer, the case variants it adds to the dictionaries, the -s, -ed and
-- -ing endings, stress, numbers and money, and the words whose sound depends
-- on the next word (the, to, a).
--
-- Two things misaki gets from elsewhere are guessed or replaced here:
-- - spaCy's part-of-speech tags, which a few words need (a, I, in, used, an
--   acronym in capitals): guessed from the word and its neighbours. The
--   other words a tag would change are read their usual way.
-- - eSpeak NG, for words in neither dictionary: instead, phonemes.extra (Bragi's
--   own words), then two known words joined (worktree = work + tree), then
--   rough letter-to-sound rules.
--
-- phonemes.setDictionaries(dir)    the folder with the two dictionaries
-- phonemes.say(text) -> phonemes   a whole reply ("" when there's nothing)
-- phonemes.extra                   word (lower case) -> phonemes, before the
--                                  dictionaries

local phonemes = {}

local dictionaries = { gold = nil, silver = nil }

--- Bragi's own words, read before the dictionaries (lower case keys): the
-- ones the dictionaries lack (and the -s, -ed, -ing rules can't reach) or
-- read wrong. Joined words (worktree, changelog) and plurals of known words
-- need no entry.
phonemes.extra = {
    bragi = "bɹˈɑɡi",
    baldr = "bˈɔldəɹ",
    config = "kənfˈɪɡ",
    configs = "kənfˈɪɡz",
    gitgud = "ɡˈɪtɡʊd",
    json = "ʤˈAsən",
    lua = "lˈuə",
    async = "ˈAsɪŋk",
    enum = "ˈinəm",
    sudo = "sˈudu",
}

local cache -- the dictionaries' answers so far (below)

function phonemes.setDictionaries(dir)
    dir = tostring(dir or ""):gsub("[/\\]$", "")
    dictionaries.gold = dir .. "/en-us-gold.tsv"
    dictionaries.silver = dir .. "/en-us-silver.tsv"
    cache = { gold = {}, silver = {} }
end

-- ---- Characters ---------------------------------------------------------------

local function set(s)
    local t = {}
    for c in s:gmatch(utf8.charpattern) do
        t[c] = true
    end
    return t
end

local PUNCTS = set(';:,.!?—…"“”')
local NON_QUOTE_PUNCTS = set(";:,.!?—…")
local SUBTOKEN_JUNKS = set("',-._‘’/")
local CONSONANTS = set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
local US_TAUS = set("AIOWYiuæɑəɛɪɹʊʌ")
local VOWELS = set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
local DIPHTHONGS = set("AIOQWYʤʧ")
local APOSTROPHES = set("'‘’")
local PRIMARY, SECONDARY = "ˈ", "ˌ"
local STRESSES = { [PRIMARY] = true, [SECONDARY] = true }

local CURRENCIES = { ["$"] = { "dollar", "cent" }, ["£"] = { "pound", "pence" }, ["€"] = { "euro", "cent" } }
local ORDINALS = { st = true, nd = true, rd = true, th = true }
local ADD_SYMBOLS = { ["."] = "dot", ["/"] = "slash" }
local SYMBOLS = { ["%"] = "percent", ["&"] = "and", ["+"] = "plus", ["@"] = "at" }

local function chars(s)
    local t = {}
    for c in s:gmatch(utf8.charpattern) do
        t[#t + 1] = c
    end
    return t
end

local function has(s, piece)
    return s:find(piece, 1, true) ~= nil
end

local function isUpperChar(c)
    return c:match("^%u$") ~= nil
end

local function isLowerChar(c)
    -- Letters outside ASCII count as lower case letters (é, ñ...).
    return c:match("^%l$") ~= nil or (#c > 1 and not PUNCTS[c] and not APOSTROPHES[c] and c ~= "–")
end

local function isLetter(c)
    return isUpperChar(c) or isLowerChar(c)
end

local function isDigitChar(c)
    return c:match("^%d$") ~= nil
end

local function isDigits(s)
    return s:match("^%d+$") ~= nil
end

local function isAlpha(s)
    if s == "" then
        return false
    end
    for _, c in ipairs(chars(s)) do
        if not isLetter(c) then
            return false
        end
    end
    return true
end

-- Only ' - A-Z a-z (misaki's LEXICON_ORDS).
local function lexiconChars(s)
    return s:match("^[%a'%-]*$") ~= nil
end

local function lower(s)
    return s:lower()
end

local function upper(s)
    return s:upper()
end

local function capitalize(s)
    return s:sub(1, 1):upper() .. s:sub(2):lower()
end

-- ---- Stress -------------------------------------------------------------------

local function restress(ps)
    local cs = chars(ps)
    local items = {}
    for i, c in ipairs(cs) do
        local pos = i
        if STRESSES[c] then
            for j = i, #cs do
                if VOWELS[cs[j]] then
                    pos = j - 0.5
                    break
                end
            end
        end
        items[#items + 1] = { pos = pos, i = i, c = c }
    end
    table.sort(items, function(a, b)
        if a.pos ~= b.pos then
            return a.pos < b.pos
        end
        return a.i < b.i
    end)
    local out = {}
    for _, item in ipairs(items) do
        out[#out + 1] = item.c
    end
    return table.concat(out)
end

local function anyOf(ps, group)
    for _, c in ipairs(chars(ps)) do
        if group[c] then
            return true
        end
    end
    return false
end

local function applyStress(ps, stress)
    if ps == nil or stress == nil then
        return ps
    elseif stress < -1 then
        return (ps:gsub(PRIMARY, ""):gsub(SECONDARY, ""))
    elseif stress == -1 or ((stress == 0 or stress == -0.5) and has(ps, PRIMARY)) then
        return (ps:gsub(SECONDARY, ""):gsub(PRIMARY, SECONDARY))
    elseif (stress == 0 or stress == 0.5 or stress == 1) and not anyOf(ps, STRESSES) then
        if not anyOf(ps, VOWELS) then
            return ps
        end
        return restress(SECONDARY .. ps)
    elseif stress >= 1 and not has(ps, PRIMARY) and has(ps, SECONDARY) then
        return (ps:gsub(SECONDARY, PRIMARY))
    elseif stress > 1 and not anyOf(ps, STRESSES) then
        if not anyOf(ps, VOWELS) then
            return ps
        end
        return restress(PRIMARY .. ps)
    end
    return ps
end

local function stressWeight(ps)
    local n = 0
    for _, c in ipairs(chars(ps or "")) do
        n = n + (DIPHTHONGS[c] and 2 or 1)
    end
    return n
end

-- ---- Dictionaries -------------------------------------------------------------

-- An entry: a string, or { DEFAULT = ..., <tag> = ... } (false: misaki's None).
cache = { gold = {}, silver = {} }

local function raw(which, key)
    local path = dictionaries[which]
    if not path or not gitgud.lookup then
        return nil -- no dictionaries yet: nothing remembered either
    end
    local hit = cache[which][key]
    if hit ~= nil then
        return hit or nil
    end
    local value = gitgud.lookup(path, key)
    local entry = false
    if type(value) == "string" then
        if value:find("=", 1, true) then
            entry = {}
            for tag, ps in value:gmatch("([^;=]+)=([^;]*)") do
                entry[tag] = ps ~= "" and ps or false
            end
        else
            entry = value
        end
    end
    cache[which][key] = entry
    return entry or nil
end

-- misaki grows each dictionary with case variants (grow_dictionary): a lower
-- case word is also found Capitalized, and a Capitalized one in lower case.
local function get(which, key)
    local entry = raw(which, key)
    if entry ~= nil or #key < 2 then
        return entry
    end
    local low = lower(key)
    if key ~= low and key == capitalize(low) then
        return raw(which, low)
    elseif key == low and capitalize(key) ~= key then
        return raw(which, capitalize(key))
    end
    return nil
end

local function inGold(w)
    return get("gold", w) ~= nil
end

local function inSilver(w)
    return get("silver", w) ~= nil
end

local function parentTag(tag)
    if tag == nil then
        return nil
    elseif tag:find("^VB") then
        return "VERB"
    elseif tag:find("^NN") then
        return "NOUN"
    elseif tag:find("^ADV") or tag:find("^RB") then
        return "ADV"
    elseif tag:find("^ADJ") or tag:find("^JJ") then
        return "ADJ"
    end
    return tag
end

local lookup -- forward

local function getNNP(word)
    local parts = {}
    for _, c in ipairs(chars(word)) do
        if isLetter(c) then
            local ps = get("gold", upper(c))
            if type(ps) ~= "string" then
                return nil
            end
            parts[#parts + 1] = ps
        end
    end
    local ps = applyStress(table.concat(parts), 0)
    -- The last secondary stress becomes the primary one.
    local at
    local from = 1
    while true do
        local s, e = ps:find(SECONDARY, from, true)
        if not s then
            break
        end
        at = s
        from = e + 1
    end
    if at then
        ps = ps:sub(1, at - 1) .. PRIMARY .. ps:sub(at + #SECONDARY)
    end
    return ps
end

local function isKnown(word, tag)
    if inGold(word) or SYMBOLS[word] or inSilver(word) then
        return true
    elseif not isAlpha(word) or not lexiconChars(word) then
        return false
    elseif #chars(word) == 1 then
        return true
    elseif word == upper(word) and inGold(lower(word)) then
        return true
    end
    local rest = word:sub(2)
    return rest == upper(rest)
end

lookup = function(word, tag, stress, ctx)
    local isNNP = nil
    if word == upper(word) and not inGold(word) then
        word = lower(word)
        isNNP = tag == "NNP"
    end
    local ps = get("gold", word)
    if ps == nil and not isNNP then
        ps = get("silver", word)
    end
    if type(ps) == "table" then
        if ctx and ctx.futureVowel == nil and ps["None"] ~= nil then
            tag = "None"
        elseif tag == nil or ps[tag] == nil then
            tag = parentTag(tag)
        end
        local v = tag and ps[tag]
        if v == nil then
            v = ps.DEFAULT
        end
        ps = v or nil
    end
    if ps == nil or (isNNP and not has(ps, PRIMARY)) then
        local nnp = getNNP(word)
        if nnp then
            return nnp
        end
    end
    return applyStress(ps, stress)
end

local function specialCase(word, tag, stress, ctx)
    if tag == "ADD" and ADD_SYMBOLS[word] then
        return lookup(ADD_SYMBOLS[word], nil, -0.5, ctx)
    elseif SYMBOLS[word] then
        return lookup(SYMBOLS[word], nil, nil, ctx)
    end
    local stripped = word:gsub("^%.+", ""):gsub("%.+$", "")
    if has(stripped, ".") and isAlpha((word:gsub("%.", ""))) then
        local longest = 0
        for part in (word .. "."):gmatch("([^.]*)%.") do
            longest = math.max(longest, #part)
        end
        if longest < 3 then
            return getNNP(word)
        end
    end
    if word == "a" or word == "A" then
        return tag == "DT" and "ɐ" or "ˈA"
    elseif word == "am" or word == "Am" or word == "AM" then
        if tag and tag:find("^NN") then
            return getNNP(word)
        elseif ctx.futureVowel == nil or word ~= "am" or (stress and stress > 0) then
            return get("gold", "am")
        end
        return "ɐm"
    elseif word == "an" or word == "An" or word == "AN" then
        if word == "AN" and tag and tag:find("^NN") then
            return getNNP(word)
        end
        return "ɐn"
    elseif word == "I" and tag == "PRP" then
        return SECONDARY .. "I"
    elseif (word == "by" or word == "By" or word == "BY") and parentTag(tag) == "ADV" then
        return "bˈI"
    elseif word == "to" or word == "To" or (word == "TO" and (tag == "TO" or tag == "IN")) then
        if ctx.futureVowel == nil then
            return get("gold", "to")
        end
        return ctx.futureVowel and "tʊ" or "tə"
    elseif word == "in" or word == "In" or (word == "IN" and tag ~= "NNP") then
        local s = (ctx.futureVowel == nil or tag ~= "IN") and PRIMARY or ""
        return s .. "ɪn"
    elseif word == "the" or word == "The" or (word == "THE" and tag == "DT") then
        return ctx.futureVowel == true and "ði" or "ðə"
    elseif tag == "IN" and word:lower():match("^vs%.?$") then
        return lookup("versus", nil, nil, ctx)
    elseif word == "used" or word == "Used" or word == "USED" then
        local used = get("gold", "used")
        if type(used) == "table" then
            if (tag == "VBD" or tag == "JJ") and ctx.futureTo then
                return used.VBD
            end
            return used.DEFAULT
        end
        return used
    end
    return nil
end

local function plural(stem)
    if not stem or stem == "" then
        return nil
    end
    local cs = chars(stem)
    local last = cs[#cs]
    if ("ptkfθ"):find(last, 1, true) then
        return stem .. "s"
    elseif ("szʃʒʧʤ"):find(last, 1, true) then
        return stem .. "ᵻz"
    end
    return stem .. "z"
end

local function past(stem)
    if not stem or stem == "" then
        return nil
    end
    local cs = chars(stem)
    local last = cs[#cs]
    if ("pkfθʃsʧ"):find(last, 1, true) then
        return stem .. "t"
    elseif last == "d" then
        return stem .. "ᵻd"
    elseif last ~= "t" then
        return stem .. "d"
    elseif #cs < 2 then
        return stem .. "ɪd"
    elseif US_TAUS[cs[#cs - 1]] then
        cs[#cs] = nil
        return table.concat(cs) .. "ɾᵻd"
    end
    return stem .. "ᵻd"
end

local function progressive(stem)
    if not stem or stem == "" then
        return nil
    end
    local cs = chars(stem)
    if #cs > 1 and cs[#cs] == "t" and US_TAUS[cs[#cs - 1]] then
        cs[#cs] = nil
        return table.concat(cs) .. "ɾɪŋ"
    end
    return stem .. "ɪŋ"
end

local function stemS(word, tag, stress, ctx)
    if #word < 3 or word:sub(-1) ~= "s" then
        return nil
    end
    local stem
    if word:sub(-2) ~= "ss" and isKnown(word:sub(1, -2), tag) then
        stem = word:sub(1, -2)
    elseif (word:sub(-2) == "'s" or (#word > 4 and word:sub(-2) == "es" and word:sub(-3) ~= "ies"))
        and isKnown(word:sub(1, -3), tag) then
        stem = word:sub(1, -3)
    elseif #word > 4 and word:sub(-3) == "ies" and isKnown(word:sub(1, -4) .. "y", tag) then
        stem = word:sub(1, -4) .. "y"
    else
        return nil
    end
    return plural(lookup(stem, tag, stress, ctx))
end

local function stemEd(word, tag, stress, ctx)
    if #word < 4 or word:sub(-1) ~= "d" then
        return nil
    end
    local stem
    if word:sub(-2) ~= "dd" and isKnown(word:sub(1, -2), tag) then
        stem = word:sub(1, -2)
    elseif #word > 4 and word:sub(-2) == "ed" and word:sub(-3) ~= "eed" and isKnown(word:sub(1, -3), tag) then
        stem = word:sub(1, -3)
    else
        return nil
    end
    return past(lookup(stem, tag, stress, ctx))
end

local function stemIng(word, tag, stress, ctx)
    if #word < 5 or word:sub(-3) ~= "ing" then
        return nil
    end
    local stem
    local base = word:sub(1, -4)
    if #word > 5 and isKnown(base, tag) then
        stem = base
    elseif isKnown(base .. "e", tag) then
        stem = base .. "e"
    else
        local c = word:sub(-5, -5)
        local doubled = #word > 5 and (word:sub(-4, -4) == c and c:match("[bcdgklmnprstvxz]"))
        if (doubled or word:sub(-5) == "cking") and isKnown(word:sub(1, -5), tag) then
            stem = word:sub(1, -5)
        else
            return nil
        end
    end
    return progressive(lookup(stem, tag, stress, ctx))
end

local function getWord(word, tag, stress, ctx)
    local ps = specialCase(word, tag, stress, ctx)
    if ps ~= nil then
        return ps
    end
    local wl = lower(word)
    if #word > 1 and isAlpha((word:gsub("'", ""))) and word ~= wl and (tag ~= "NNP" or #word > 7)
        and not inGold(word) and not inSilver(word)
        and (word == upper(word) or word:sub(2) == word:sub(2):lower())
        and (inGold(wl) or inSilver(wl) or stemS(wl, tag, stress, ctx) or stemEd(wl, tag, stress, ctx)
            or stemIng(wl, tag, stress, ctx)) then
        word = wl
    end
    if isKnown(word, tag) then
        return lookup(word, tag, stress, ctx)
    elseif word:sub(-2) == "s'" and isKnown(word:sub(1, -3) .. "'s", tag) then
        return lookup(word:sub(1, -3) .. "'s", tag, stress, ctx)
    elseif word:sub(-1) == "'" and isKnown(word:sub(1, -2), tag) then
        return lookup(word:sub(1, -2), tag, stress, ctx)
    end
    return stemS(word, tag, stress, ctx) or stemEd(word, tag, stress, ctx)
        or stemIng(word, tag, stress == nil and 0.5 or stress, ctx)
end

-- ---- Numbers (num2words' English, as misaki uses it) ----------------------------

local ONES = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen" }
local TENS = { nil, "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety" }
local SCALES = { { 1e12, "trillion" }, { 1e9, "billion" }, { 1e6, "million" }, { 1e3, "thousand" } }
local ORDINAL_WORDS = { one = "first", two = "second", three = "third", five = "fifth", eight = "eighth",
    nine = "ninth", twelve = "twelfth" }

local function append(out, words)
    for _, w in ipairs(words) do
        out[#out + 1] = w
    end
    return out
end

-- The words for a whole number below 1000 ("and" left out, as misaki drops it).
local function under1000(n)
    local out = {}
    if n >= 100 then
        append(out, { ONES[n // 100], "hundred" })
        n = n % 100
    end
    if n >= 20 then
        out[#out + 1] = TENS[n // 10]
        n = n % 10
    end
    if n > 0 then
        out[#out + 1] = ONES[n]
    end
    return out
end

local function cardinal(n)
    if n == 0 then
        return { "zero" }
    end
    local out = {}
    for _, scale in ipairs(SCALES) do
        if n >= scale[1] then
            append(out, under1000(math.floor(n / scale[1])))
            out[#out + 1] = scale[2]
            n = n % math.floor(scale[1])
        end
    end
    return append(out, under1000(math.floor(n)))
end

local function ordinal(n)
    local out = cardinal(n)
    local last = out[#out]
    if ORDINAL_WORDS[last] then
        out[#out] = ORDINAL_WORDS[last]
    elseif last:sub(-1) == "y" then
        out[#out] = last:sub(1, -2) .. "ieth"
    else
        out[#out] = last .. "th"
    end
    return out
end

local function year(n)
    local high, low = n // 100, n % 100
    -- 00XX, X00X and beyond 9999 are plain numbers (num2words' to_year).
    if high == 0 or (high % 10 == 0 and low < 10) or high >= 100 then
        return cardinal(n)
    end
    local out = cardinal(high)
    if low == 0 then
        out[#out + 1] = "hundred"
    elseif low < 10 then
        append(out, { "oh", ONES[low] })
    else
        append(out, cardinal(low))
    end
    return out
end

local function digitWords(s)
    local out = {}
    for d in s:gmatch("%d") do
        append(out, cardinal(tonumber(d)))
    end
    return out
end

local function isNumber(word, isHead)
    if not word:find("%d") then
        return false
    end
    for _, s in ipairs({ "ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s" }) do
        if #word > #s and word:sub(-#s) == s then
            word = word:sub(1, -#s - 1)
            break
        end
    end
    for i = 1, #word do
        local c = word:sub(i, i)
        if not (c:match("%d") or c == "," or c == "." or (isHead and i == 1 and c == "-")) then
            return false
        end
    end
    return true
end

local function isCurrency(word)
    if not has(word, ".") then
        return true
    end
    local _, dots = word:gsub("%.", "")
    if dots > 1 then
        return false
    end
    local cents = word:match("%.(.*)$") or ""
    return #cents < 3
end

local function getNumber(word, currency, isHead)
    local suffix = word:match("[a-z']+$")
    if suffix then
        word = word:sub(1, -#suffix - 1)
    end
    local result = {}
    if word:sub(1, 1) == "-" then
        result[#result + 1] = lookup("minus", nil, nil, nil)
        word = word:sub(2)
    end
    local function extend(words)
        for _, w in ipairs(words) do
            if w ~= "and" then
                result[#result + 1] = lookup(w, nil, w == "point" and -2 or nil, nil)
            end
        end
    end
    local function extendNum(num)
        extend(cardinal(tonumber(num)))
    end
    if isDigits(word) and ORDINALS[suffix or ""] then
        extend(ordinal(tonumber(word)))
    elseif #result == 0 and #word == 4 and not CURRENCIES[currency or ""] and isDigits(word) then
        extend(year(tonumber(word)))
    elseif not isHead and not has(word, ".") then
        local num = word:gsub(",", "")
        if num:sub(1, 1) == "0" or #num > 3 then
            extend(digitWords(num))
        elseif #num == 3 and num:sub(-2) ~= "00" then
            extendNum(num:sub(1, 1))
            if num:sub(2, 2) == "0" then
                result[#result + 1] = lookup("O", nil, -2, nil)
                extendNum(num:sub(3, 3))
            else
                extendNum(num:sub(2))
            end
        else
            extendNum(num)
        end
    elseif select(2, word:gsub("%.", "")) > 1 or not isHead then
        for num in (word:gsub(",", "") .. "."):gmatch("([^.]*)%.") do
            if num ~= "" then
                if num:sub(1, 1) == "0" or (#num ~= 2 and num:sub(2):find("[1-9]")) then
                    extend(digitWords(num))
                else
                    extendNum(num)
                end
            end
        end
    elseif CURRENCIES[currency or ""] and isCurrency(word) then
        local units = CURRENCIES[currency]
        local parts = {}
        local whole, cents = word:gsub(",", ""):match("^([^.]*)%.?(.*)$")
        parts[1] = { tonumber(whole ~= "" and whole or "0") or 0, units[1] }
        if cents ~= "" then
            parts[2] = { tonumber(cents) or 0, units[2] }
        end
        if #parts > 1 then
            if parts[2][1] == 0 then
                parts = { parts[1] }
            elseif parts[1][1] == 0 then
                parts = { parts[2] }
            end
        end
        for i, part in ipairs(parts) do
            if i > 1 then
                result[#result + 1] = lookup("and", nil, nil, nil)
            end
            extendNum(tostring(part[1]))
            if math.abs(part[1]) ~= 1 and part[2] ~= "pence" then
                result[#result + 1] = stemS(part[2] .. "s", nil, nil, nil)
            else
                result[#result + 1] = lookup(part[2], nil, nil, nil)
            end
        end
    else
        local words
        if isDigits(word) then
            words = cardinal(tonumber(word))
        elseif not has(word, ".") then
            local n = tonumber((word:gsub(",", ""))) or 0
            words = ORDINALS[suffix or ""] and ordinal(n) or cardinal(n)
        else
            word = word:gsub(",", "")
            local whole, frac = word:match("^(%d*)%.(%d*)$")
            words = {}
            if whole and whole ~= "" then
                append(words, cardinal(tonumber(whole)))
            end
            append(words, { "point" })
            append(words, digitWords(frac or ""))
        end
        extend(words)
    end
    local parts = {}
    for _, ps in ipairs(result) do
        if ps == nil then
            return nil
        end
        parts[#parts + 1] = ps
    end
    if #parts == 0 then
        return nil
    end
    local ps = table.concat(parts, " ")
    if suffix == "s" or suffix == "'s" then
        return plural(ps)
    elseif suffix == "ed" or suffix == "'d" then
        return past(ps)
    elseif suffix == "ing" then
        return progressive(ps)
    end
    return ps
end

local function appendCurrency(ps, currency)
    if not currency or not CURRENCIES[currency] then
        return ps
    end
    local unit = stemS(CURRENCIES[currency][1] .. "s", nil, nil, nil)
    return unit and (ps .. " " .. unit) or ps
end

-- ---- Words misaki doesn't know ----------------------------------------------------

-- Rough letter-to-sound rules, longest first at each letter: (letters, phonemes).
local LETTER_RULES = {
    { "tion", "ʃən" }, { "sion", "ʒən" }, { "ture", "ʧəɹ" }, { "ough", "O" }, { "augh", "ɔ" },
    { "eigh", "A" }, { "tch", "ʧ" }, { "igh", "I" }, { "dge", "ʤ" }, { "air", "ɛɹ" }, { "ear", "ɪɹ" },
    { "ch", "ʧ" }, { "sh", "ʃ" }, { "th", "θ" }, { "ph", "f" }, { "wh", "w" }, { "ck", "k" },
    { "ng", "ŋ" }, { "qu", "kw" }, { "gh", "" }, { "ee", "i" }, { "ea", "i" }, { "oo", "u" },
    { "ou", "W" }, { "oi", "Y" }, { "oy", "Y" }, { "ai", "A" }, { "ay", "A" }, { "au", "ɔ" },
    { "aw", "ɔ" }, { "ei", "A" }, { "ie", "i" }, { "ue", "u" }, { "ui", "u" }, { "oa", "O" },
    { "ar", "ɑɹ" }, { "or", "ɔɹ" }, { "er", "əɹ" }, { "ir", "ɜɹ" }, { "ur", "ɜɹ" }, { "x", "ks" },
    { "a", "æ" }, { "e", "ɛ" }, { "i", "ɪ" }, { "o", "ɑ" }, { "u", "ʌ" }, { "b", "b" }, { "d", "d" },
    { "f", "f" }, { "h", "h" }, { "j", "ʤ" }, { "k", "k" }, { "l", "l" }, { "m", "m" }, { "n", "n" },
    { "p", "p" }, { "q", "k" }, { "r", "ɹ" }, { "s", "s" }, { "t", "t" }, { "v", "v" }, { "w", "w" },
    { "z", "z" },
}
local LONG = { a = "A", e = "i", i = "I", o = "O", u = "u" }

local function letterToSound(word)
    local w = lower(word):gsub("[^a-z]", "")
    if w == "" then
        return nil
    end
    w = w:gsub("^kn", "n"):gsub("^wr", "r"):gsub("(.)%1", "%1")
    local out = {}
    local i = 1
    while i <= #w do
        local c = w:sub(i, i)
        local nextc = w:sub(i + 1, i + 1)
        local after = w:sub(i + 2, i + 2)
        local done = false
        -- A vowel, one consonant, and a final e: the long vowel, the e silent.
        if LONG[c] and nextc:match("[bcdfgklmnprstvz]") and after == "e" and i + 2 == #w then
            out[#out + 1] = LONG[c]
            out[#out + 1] = (nextc == "c" and "s") or (nextc == "g" and "ʤ") or (nextc == "r" and "ɹ") or nextc
            i = i + 3
            done = true
        elseif c == "c" then
            out[#out + 1] = nextc:match("[eiy]") and "s" or "k"
            i = i + 1
            done = true
        elseif c == "g" then
            out[#out + 1] = (nextc:match("[eiy]") and i > 1) and "ʤ" or "ɡ"
            i = i + 1
            done = true
        elseif c == "y" then
            out[#out + 1] = (i == 1 and "j") or (i == #w and "i") or "ɪ"
            i = i + 1
            done = true
        elseif c == "e" and i == #w and #w > 2 then
            i = i + 1
            done = true
        end
        if not done then
            local matched = false
            for _, rule in ipairs(LETTER_RULES) do
                if w:sub(i, i + #rule[1] - 1) == rule[1] then
                    out[#out + 1] = rule[2]
                    i = i + #rule[1]
                    matched = true
                    break
                end
            end
            if not matched then
                i = i + 1
            end
        end
    end
    local ps = table.concat(out)
    -- The primary stress before the first vowel.
    local cs = chars(ps)
    for k, ch in ipairs(cs) do
        if VOWELS[ch] then
            table.insert(cs, k, PRIMARY)
            break
        end
    end
    return table.concat(cs)
end

-- Two known words, then the letters' sounds (Bragi's own words come first,
-- in wordPhonemes).
local function fallback(word, ctx)
    local w = word:gsub("[^%a]", "")
    if w == "" then
        return nil
    end
    if #w >= 6 then
        for cut = #w - 3, 3, -1 do
            local a = getWord(lower(w:sub(1, cut)), nil, nil, ctx)
            local b = a and getWord(lower(w:sub(cut + 1)), nil, nil, ctx)
            if a and b then
                return a .. applyStress(b, -1)
            end
        end
    end
    if w == upper(w) and #w <= 5 then
        local nnp = getNNP(w)
        if nnp then
            return nnp
        end
    end
    return letterToSound(w)
end

-- ---- Tokens -------------------------------------------------------------------------

-- A token: { text, ws (the space after it: "" or " "), tag, phonemes, isHead,
-- currency, prespace, alias }.

local CONTRACTIONS = { "n't", "'s", "'re", "'ve", "'ll", "'d", "'m" }
-- Apostrophes stay with their word ('cause, files'): misaki's subtokenizer
-- and the dictionaries handle them.
local OPEN_PUNCT = set('"“([')
local CLOSE_PUNCT = set(".,!?;:\"”)]…")

local function isPunctToken(s)
    for _, c in ipairs(chars(s)) do
        if isLetter(c) or isDigitChar(c) then
            return false
        end
    end
    return s ~= ""
end

-- Words spaCy keeps with their full stop (misaki then reads the word and
-- drops the stop).
local TITLES = {}
for _, w in ipairs({ "mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "prof", "gen", "rep", "sen",
    "gov", "lt", "col", "sgt", "capt", "mt", "ft", "inc", "ltd", "co", "corp", "dept", "fig", "jan", "feb",
    "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec" }) do
    TITLES[w] = true
end

-- An abbreviation kept whole with its stop (U.S., e.g., p.m., W., Mr.).
local function isAbbreviation(s)
    if s:match("^%a%.%a[%a.]*$") ~= nil and s:sub(-1) == "." or s:match("^%a%.%a+$") ~= nil then
        return true
    end
    return s:match("^%a%.$") ~= nil or (s:sub(-1) == "." and TITLES[s:sub(1, -2):lower()] == true)
end

-- spaCy's work, roughly: words, the punctuation around them, contractions.
local function tokenize(text)
    local tokens = {}
    for chunk, ws in text:gmatch("(%S+)(%s*)") do
        local pieces = {}
        local cs = chars(chunk)
        local first, last = 1, #cs
        local lead = {}
        while first <= last and (OPEN_PUNCT[cs[first]] or CURRENCIES[cs[first]]) do
            lead[#lead + 1] = cs[first]
            first = first + 1
        end
        local trail = {}
        while last >= first do
            local c = cs[last]
            if not CLOSE_PUNCT[c] then
                break
            end
            if c == "." and isAbbreviation(table.concat(cs, "", first, last)) then
                break
            end
            table.insert(trail, 1, c)
            last = last - 1
        end
        local core = table.concat(cs, "", first, last)
        for _, c in ipairs(lead) do
            pieces[#pieces + 1] = c
        end
        if core ~= "" then
            local split = false
            local lc = lower(core)
            for _, suffix in ipairs(CONTRACTIONS) do
                if #lc > #suffix and lc:sub(-#suffix) == suffix and core:sub(1, -#suffix - 1):find("%a") then
                    pieces[#pieces + 1] = core:sub(1, -#suffix - 1)
                    pieces[#pieces + 1] = core:sub(-#suffix)
                    split = true
                    break
                end
            end
            if not split then
                pieces[#pieces + 1] = core
            end
        end
        -- A run of the same closing marks stays one token ("...", "?!").
        local run = {}
        for _, c in ipairs(trail) do
            if #run > 0 and PUNCTS[c] and PUNCTS[run[#run]] then
                run[#run] = run[#run] .. c
            else
                run[#run + 1] = c
            end
        end
        for _, c in ipairs(run) do
            pieces[#pieces + 1] = c
        end
        for i, piece in ipairs(pieces) do
            tokens[#tokens + 1] = { text = piece, ws = (i == #pieces and ws ~= "") and " " or "" }
        end
    end
    return tokens
end

-- Words after which "that" joins a clause ("noted that the...", "commits
-- that aren't"): misaki reads that one unstressed (spaCy's IN or WDT).
local CLAUSE_STARTS = {}
for _, w in ipairs({ "the", "a", "an", "it", "its", "he", "she", "they", "we", "you", "i", "this", "these",
    "those", "there", "his", "her", "their", "our", "my", "your", "is", "are", "was", "were", "has", "have",
    "had", "will", "would", "can", "could", "should", "may", "might", "must", "aren't", "isn't", "wasn't",
    "weren't", "don't", "doesn't", "didn't", "won't", "can't", "couldn't", "shouldn't", "some", "all", "no",
    "not", "if", "certain", "every", "each", "nothing", "everything", "something" }) do
    CLAUSE_STARTS[w] = true
end
-- Verbs whose "in" is a particle (sign in, brought in): stressed (spaCy's RP).
local PARTICLE_VERBS = {}
for _, w in ipairs({ "sign", "signed", "signs", "log", "logged", "logs", "check", "checked", "checks",
    "plug", "plugged", "fill", "filled", "bring", "brought", "brings", "come", "came", "comes", "get", "got",
    "gets", "step", "stepped", "put", "puts", "turn", "turned", "turns", "hand", "handed", "give", "gave",
    "gives", "join", "joined", "opt", "opted", "chime", "chimed", "tune", "tuned", "dig", "kick", "kicked",
    "sink", "sank", "cave", "caved", "pull", "pulled", "pulls", "roll", "rolled", "rolls", "settle", "settled",
    "breathe", "drop", "dropped", "fit", "fits", "zoom", "zoomed" }) do
    PARTICLE_VERBS[w] = true
end
-- Words after "that" that make it a clause's, not "that thing" (misaki
-- unstressed): common verbs (with -s and -ed checked by ending).
local CLAUSE_VERBS = {}
for _, w in ipairs({ "did", "do", "does", "made", "make", "came", "come", "went", "go", "got", "get", "said",
    "say", "seem", "seemed", "felt", "feel", "took", "take", "knew", "know", "ran", "run", "saw", "see",
    "used", "led", "left", "let", "kept", "keep", "means", "mean", "needs", "need", "lets" }) do
    CLAUSE_VERBS[w] = true
end
-- Small words that are words, not letters, in capitals (OF, TO, AND).
local function capitalsAreLetters(t)
    if get("gold", t) ~= nil then
        return true -- the dictionary has the capitals (US, IT): it says how
    end
    return get("gold", lower(t)) == nil
end

-- The tags misaki would get from spaCy, guessed for the words that need one.
local function guessTags(tokens)
    for i, tk in ipairs(tokens) do
        local t = tk.text
        local prev = tokens[i - 1]
        local nextTk = tokens[i + 1]
        local sentenceStart = not prev or (prev.text:find("^[.!?]") ~= nil)
        local nextWord = nextTk and isAlpha((nextTk.text:gsub("'", ""))) and lower(nextTk.text) or nil
        local nextCapitalized = nextTk and nextTk.text:match("^%u%l") ~= nil
        if t == "I" then
            -- A name's numeral (Stephen I,) is the letter; else the pronoun.
            local afterName = prev and not sentenceStart and prev.text:match("^%u%l") ~= nil
            tk.tag = (afterName and not nextWord) and "NNP" or "PRP"
        elseif t == "a" then
            tk.tag = "DT"
        elseif t == "A" then
            -- The article starts a sentence or a title (A Hoosier Romance);
            -- otherwise it's the letter (plan A failed).
            tk.tag = (sentenceStart and nextWord or nextCapitalized) and "DT" or "NNP"
        elseif t == "in" or t == "In" then
            -- Before "the", "a" and the like it's mostly where (signed in the
            -- spring), except after bring (brought in the new logging).
            local prevWord = prev and lower(prev.text) or ""
            local determiner = nextWord and CLAUSE_STARTS[nextWord] and not CLAUSE_VERBS[nextWord]
            local particle = PARTICLE_VERBS[prevWord] and (not determiner or prevWord:find("^br[io]") ~= nil)
            tk.tag = particle and "RP" or "IN"
        elseif t == "that" or t == "That" then
            local clause = nextWord and (CLAUSE_STARTS[nextWord] or CLAUSE_VERBS[nextWord] or nextCapitalized
                or nextWord:match("ed$") or (nextWord:match("s$") and not nextWord:match("ss$")))
            if sentenceStart or not nextWord or nextWord == "'s" or not clause then
                tk.tag = "DT"
            end
        elseif t:lower():match("^vs%.?$") then
            tk.tag = "IN"
        elseif t == "to" or t == "To" or t == "TO" then
            tk.tag = "TO"
        elseif (t == "used" or t == "Used") and nextWord == "to" then
            tk.tag = "VBD"
        elseif #t >= 2 and isAlpha(t) and t == upper(t) and capitalsAreLetters(t) then
            tk.tag = "NNP"
        elseif CURRENCIES[t] then
            tk.tag = "$"
        end
    end
end

-- misaki's subtokenize regex, by hand.
local function subtokenize(word)
    local cs = chars(word)
    local n = #cs
    local out = {}
    local i = 1
    local function at(k)
        return cs[k] or ""
    end
    local function numberAt(k)
        local j = k
        if k == 1 and at(k) == "-" then
            j = k + 1
        end
        local start = j
        while true do
            local function try(pattern)
                local p = j
                for _, kind in ipairs(pattern) do
                    local c = at(p)
                    if kind == "d" and isDigitChar(c) then
                        p = p + 1
                    elseif kind == "p" and (c == "," or c == ".") then
                        p = p + 1
                    else
                        return nil
                    end
                end
                return p
            end
            local p = try({ "d", "p", "d" }) or try({ "d", "d" }) or try({ "p", "d" }) or try({ "d" })
            if not p then
                break
            end
            j = p
        end
        if j == start then
            return nil
        end
        return j - 1
    end
    while i <= n do
        local c = cs[i]
        local stop
        if i == 1 and APOSTROPHES[c] then
            stop = i
            while APOSTROPHES[at(stop + 1)] do
                stop = stop + 1
            end
        elseif isUpperChar(c) and isUpperChar(at(i + 1)) and isLowerChar(at(i + 2)) then
            stop = i
        else
            stop = numberAt(i)
            if not stop and (c == "-" or c == "_") then
                stop = i
                while at(stop + 1) == "-" or at(stop + 1) == "_" do
                    stop = stop + 1
                end
            end
            if not stop and APOSTROPHES[c] and APOSTROPHES[at(i + 1)] then
                stop = i + 1
                while APOSTROPHES[at(stop + 1)] do
                    stop = stop + 1
                end
            end
            if not stop and isLetter(c) then
                -- Lazily up to a lower case letter before a capital (camelCase).
                local k = i
                while k <= n and (isLetter(at(k)) or (APOSTROPHES[at(k)] and isLetter(at(k + 1)))) do
                    if isLowerChar(at(k)) and isUpperChar(at(k + 1)) then
                        stop = k
                        break
                    end
                    k = k + 1
                end
                if not stop then
                    stop = i
                    while isLetter(at(stop + 1)) do
                        stop = stop + 1
                    end
                    while APOSTROPHES[at(stop + 1)] and isLetter(at(stop + 2)) do
                        stop = stop + 2
                    end
                end
            end
            if not stop and not (c == "-" or c == "_" or isLetter(c) or APOSTROPHES[c] or isDigitChar(c)) then
                stop = i
            end
            if not stop and APOSTROPHES[c] then
                local k = i
                while APOSTROPHES[at(k)] do
                    k = k + 1
                end
                if k > n then
                    stop = n
                end
            end
        end
        if stop then
            out[#out + 1] = table.concat(cs, "", i, stop)
            i = stop + 1
        else
            i = i + 1
        end
    end
    return out
end

local function mergeTokens(tokens)
    local text = {}
    for k, tk in ipairs(tokens) do
        text[#text + 1] = tk.text
        if k < #tokens then
            text[#text + 1] = tk.ws
        end
    end
    local best, score = tokens[1], -1
    for _, tk in ipairs(tokens) do
        local s = 0
        for _, ch in ipairs(chars(tk.text)) do
            s = s + ((ch == lower(ch)) and 1 or 2)
        end
        if s > score then
            best, score = tk, s
        end
    end
    local currency
    for _, tk in ipairs(tokens) do
        currency = currency or tk.currency
    end
    return {
        text = table.concat(text),
        tag = best.tag,
        ws = tokens[#tokens].ws,
        isHead = tokens[1].isHead,
        currency = currency,
        prespace = tokens[1].prespace,
    }
end

-- Tokens into words: punctuation on its own, and the pieces of one written
-- word (no space between them) as a group misaki tries whole first.
local function retokenize(tokens)
    local words = {}
    local currency = nil
    local quotes = 0 -- straight quotes so far: odd ones open, even ones close
    for i, token in ipairs(tokens) do
        local tks = {}
        if CURRENCIES[token.text] then
            tks = { { text = token.text, tag = "$", isHead = true } }
        elseif isPunctToken(token.text) then
            tks = { { text = token.text, tag = "PUNCT", isHead = true } }
        else
            for _, t in ipairs(subtokenize(token.text)) do
                tks[#tks + 1] = { text = t, tag = token.tag, isHead = true }
            end
            if #tks == 0 then
                tks = { { text = token.text, tag = token.tag, isHead = true } }
            end
        end
        for _, tk in ipairs(tks) do
            tk.ws = ""
        end
        tks[#tks].ws = token.ws
        for j, tk in ipairs(tks) do
            if tk.tag == "$" and CURRENCIES[tk.text] then
                currency = tk.text
                tk.phonemes = ""
            elseif tk.tag == "PUNCT" and (tk.text == "-" or tk.text == "–" or tk.text == "—") then
                tk.phonemes = "—"
            elseif tk.tag == "PUNCT" then
                local p = {}
                for _, ch in ipairs(chars(tk.text)) do
                    if ch == '"' then
                        quotes = quotes + 1
                        p[#p + 1] = quotes % 2 == 1 and "“" or "”"
                    elseif ch == "(" or ch == ")" or PUNCTS[ch] then
                        p[#p + 1] = ch
                    end
                end
                tk.phonemes = table.concat(p)
            elseif currency ~= nil then
                if not isNumber(tk.text, true) then
                    currency = nil
                elseif j == #tks and (i == #tokens or not isNumber(tokens[i + 1].text, true)) then
                    tk.currency = currency
                end
            elseif j > 1 and j < #tks and tk.text == "2" and (tks[j - 1].text:sub(-1) .. tks[j + 1].text:sub(1, 1)):match("^%a%a$") then
                tk.alias = "to"
            end
            if tk.alias ~= nil or tk.phonemes ~= nil then
                words[#words + 1] = tk
            elseif #words > 0 and words[#words].group and words[#words][#words[#words]].ws == "" then
                tk.isHead = false
                table.insert(words[#words], tk)
            elseif tk.ws ~= "" then
                words[#words + 1] = tk
            else
                words[#words + 1] = { group = true, tk }
            end
        end
    end
    for k, w in ipairs(words) do
        if w.group and #w == 1 then
            words[k] = w[1]
        end
    end
    return words
end

local function tokenContext(ctx, ps, token)
    local vowel = ctx.futureVowel
    if ps and ps ~= "" then
        for _, c in ipairs(chars(ps)) do
            if VOWELS[c] or CONSONANTS[c] or NON_QUOTE_PUNCTS[c] then
                if NON_QUOTE_PUNCTS[c] then
                    vowel = nil
                else
                    vowel = VOWELS[c] == true
                end
                break
            end
        end
    end
    local t = token.text
    local futureTo = t == "to" or t == "To" or (t == "TO" and (token.tag == "TO" or token.tag == "IN"))
    return { futureVowel = vowel, futureTo = futureTo }
end

local function wordPhonemes(tk, ctx)
    local word = (tk.alias or tk.text):gsub("‘", "'"):gsub("’", "'")
    local own = phonemes.extra[lower(word)]
    if own then
        return own
    end
    local stress = nil
    if word ~= lower(word) then
        stress = (word == upper(word)) and 2 or 0.5
    end
    local ps = getWord(word, tk.tag, stress, ctx)
    if ps ~= nil then
        return appendCurrency(ps, tk.currency)
    elseif isNumber(word, tk.isHead) then
        return getNumber(word, tk.currency, tk.isHead)
    end
    return nil
end

local function resolveGroup(tokens)
    local text = mergeTokens(tokens).text
    local kinds = {}
    for _, c in ipairs(chars(text)) do
        if not SUBTOKEN_JUNKS[c] then
            kinds[isLetter(c) and 0 or (isDigitChar(c) and 1 or 2)] = true
        end
    end
    local nkinds = 0
    for _ in pairs(kinds) do
        nkinds = nkinds + 1
    end
    local prespace = has(text, " ") or has(text, "/") or nkinds > 1
    for i, tk in ipairs(tokens) do
        if tk.phonemes == nil then
            if i == #tokens and NON_QUOTE_PUNCTS[tk.text] then
                tk.phonemes = tk.text
            elseif (function()
                    for _, c in ipairs(chars(tk.text)) do
                        if not SUBTOKEN_JUNKS[c] then
                            return false
                        end
                    end
                    return true
                end)() then
                tk.phonemes = ""
            end
        elseif i > 1 then
            tk.prespace = prespace
        end
    end
    if prespace then
        return
    end
    local indices = {}
    for i, tk in ipairs(tokens) do
        if tk.phonemes and tk.phonemes ~= "" then
            indices[#indices + 1] = { primary = has(tk.phonemes, PRIMARY) and 1 or 0, weight = stressWeight(tk.phonemes), i = i }
        end
    end
    if #indices == 2 and #chars(tokens[indices[1].i].text) == 1 then
        local i = indices[2].i
        tokens[i].phonemes = applyStress(tokens[i].phonemes, -0.5)
        return
    end
    local primaries = 0
    for _, x in ipairs(indices) do
        primaries = primaries + x.primary
    end
    if #indices < 2 or primaries <= (#indices + 1) // 2 then
        return
    end
    table.sort(indices, function(a, b)
        if a.primary ~= b.primary then
            return a.primary < b.primary
        elseif a.weight ~= b.weight then
            return a.weight < b.weight
        end
        return a.i < b.i
    end)
    for k = 1, #indices // 2 do
        local i = indices[k].i
        tokens[i].phonemes = applyStress(tokens[i].phonemes, -0.5)
    end
end

local function joinGroup(tokens)
    local out = ""
    for _, tk in ipairs(tokens) do
        local ps = tk.phonemes or ""
        if tk.prespace and out ~= "" and not out:sub(-1):match("%s") and ps ~= "" then
            out = out .. " "
        end
        out = out .. ps
    end
    return out
end

--- `text` as phonemes, words separated by spaces, punctuation kept.
function phonemes.say(text)
    text = tostring(text or ""):gsub("^%s+", "")
    if text == "" then
        return ""
    end
    local tokens = tokenize(text)
    guessTags(tokens)
    local words = retokenize(tokens)
    local ctx = { futureVowel = nil, futureTo = false }
    for k = #words, 1, -1 do
        local w = words[k]
        if not w.group then
            if w.phonemes == nil then
                w.phonemes = wordPhonemes(w, ctx)
            end
            if w.phonemes == nil then
                w.phonemes = fallback(w.alias or w.text, ctx)
            end
            ctx = tokenContext(ctx, w.phonemes, w)
        else
            local left, right = 1, #w
            local shouldFallback = false
            while left <= right do
                local tk = nil
                local blocked = false
                for x = left, right do
                    if w[x].alias ~= nil or w[x].phonemes ~= nil then
                        blocked = true
                        break
                    end
                end
                if not blocked then
                    local slice = {}
                    for x = left, right do
                        slice[#slice + 1] = w[x]
                    end
                    tk = mergeTokens(slice)
                end
                local ps = tk and wordPhonemes(tk, ctx) or nil
                if ps ~= nil then
                    w[left].phonemes = ps
                    for x = left + 1, right do
                        w[x].phonemes = ""
                    end
                    ctx = tokenContext(ctx, ps, tk)
                    right = left - 1
                    left = 1
                elseif left < right then
                    left = left + 1
                else
                    local last = w[right]
                    right = right - 1
                    if last.phonemes == nil then
                        local junk = true
                        for _, c in ipairs(chars(last.text)) do
                            if not SUBTOKEN_JUNKS[c] then
                                junk = false
                            end
                        end
                        if junk then
                            last.phonemes = ""
                        else
                            shouldFallback = true
                            break
                        end
                    end
                    left = 1
                end
            end
            local merged = mergeTokens(w)
            local whole = shouldFallback and merged.text:match("^[%a'%-]+$") and fallback(merged.text, ctx)
            if whole then
                w[1].phonemes = whole
                for x = 2, #w do
                    w[x].phonemes = ""
                end
                ctx = tokenContext(ctx, whole, merged)
            else
                -- Not a word as a whole (3:45, a1b2): each piece as it reads.
                for x = #w, 1, -1 do
                    local tk = w[x]
                    if tk.phonemes == nil then
                        tk.phonemes = wordPhonemes(tk, ctx) or fallback(tk.text, ctx)
                            or (PUNCTS[tk.text] and tk.text) or (shouldFallback and "" or nil)
                    end
                end
                resolveGroup(w)
            end
        end
    end
    local out = {}
    for _, w in ipairs(words) do
        if w.group then
            out[#out + 1] = joinGroup(w)
            out[#out + 1] = w[#w].ws
        else
            out[#out + 1] = w.phonemes or ""
            out[#out + 1] = w.ws or ""
        end
    end
    local result = table.concat(out):gsub("ɾ", "T"):gsub("ʔ", "t")
    return (result:gsub("%s+$", ""))
end

return phonemes
