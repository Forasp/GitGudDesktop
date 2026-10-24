--- tests/ui/bragi-phonemes.lua: the phonemes for Bragi's built-in voice
-- (bragi.phonemes, misaki's English rules in Lua) against misaki itself, on
-- tests/data/phonemes-reference.tsv (text<TAB>misaki's phonemes, made with no
-- fallback: a word misaki didn't know is ❓ there). Lines without one must
-- match exactly, nearly all of them; every difference is printed as
-- "[diff] text | ours | misaki". Then the words misaki doesn't know, and
-- numbers and money.
--
-- Run it like bragi-voice.lua (GITGUD_UI=bragi, scratch APPDATA and
-- LOCALAPPDATA, a repository from make-testrepo.ps1, GITGUD_SCRIPT pointing
-- here). Prints "[check] ...".

local harness = dofile((os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "") .. "harness.lua")
local check, step = harness.check, harness.step

local phonemes = require("bragi.phonemes")
local here = (os.getenv("GITGUD_SCRIPT") or ""):gsub("[^/\\]+$", "")

step(200, "the dictionaries", function()
    phonemes.setDictionaries(gitgud.appDir() .. "/resources/uis/bragi/phonemes")
    local hello = phonemes.say("hello")
    print("[phonemes] hello: " .. hello)
    check("a common word is in the dictionary", hello == "həlˈO")
end)

step(200, "misaki's phonemes", function()
    local file = io.open(here .. "../data/phonemes-reference.tsv", "rb")
    check("the reference file is there", file ~= nil)
    if not file then
        return
    end
    local total, exact, unknown, unknownExact = 0, 0, 0, 0
    local words, wordsSame = 0, 0
    for line in file:lines() do
        local text, ref = line:match("^(.-)\t(.*)$")
        if text then
            local ours = phonemes.say(text)
            if ref:find("❓", 1, true) then
                unknown = unknown + 1
                if ours == ref then
                    unknownExact = unknownExact + 1
                end
            else
                total = total + 1
                if ours == ref then
                    exact = exact + 1
                else
                    print("[diff] " .. text .. " | " .. ours .. " | " .. ref)
                end
                -- Word by word, where both have as many words.
                local a, b = {}, {}
                for w in ours:gmatch("%S+") do
                    a[#a + 1] = w
                end
                for w in ref:gmatch("%S+") do
                    b[#b + 1] = w
                end
                words = words + #b
                if #a == #b then
                    for i = 1, #b do
                        if a[i] == b[i] then
                            wordsSame = wordsSame + 1
                        end
                    end
                end
            end
        end
    end
    file:close()
    print(string.format("[phonemes] %d of %d lines exactly as misaki (%.1f%%), %d of %d words (%.1f%%); "
        .. "lines with a word misaki doesn't know: %d", exact, total, 100 * exact / math.max(1, total),
        wordsSame, words, 100 * wordsSame / math.max(1, words), unknown))
    -- 95.5% of lines and 99.6% of words when this was written: the rest
    -- need spaCy's part-of-speech tags (contents, in use, he read it).
    check("nearly every line is exactly misaki's", exact >= total * 0.94)
    check("nearly every word is misaki's", wordsSame >= words * 0.995)
end)

step(200, "words misaki doesn't know", function()
    check("Bragi's own words come first", phonemes.say("Bragi") == "bɹˈɑɡi")
    local worktree = phonemes.say("worktree")
    print("[phonemes] worktree: " .. worktree .. ", changelog: " .. phonemes.say("changelog")
        .. ", Kvasir: " .. phonemes.say("Kvasir"))
    check("two known words joined", worktree == phonemes.say("work") .. phonemes.say("tree"):gsub("ˈ", "ˌ"))
    check("an unknown word still gets sounds", phonemes.say("Kvasir"):find("ˈ") ~= nil)
    check("an unknown acronym is spelled", phonemes.say("QZX") ~= "")
end)

step(200, "numbers and money", function()
    -- misaki's own readings of these are in the reference file; here, that
    -- they read at all.
    check("money", phonemes.say("$5") == phonemes.say("five dollars"))
    check("a time's pieces", phonemes.say("3:45") ~= "")
    check("nothing to say", phonemes.say("   ") == "")
end)

step(200, "done", function()
    gitgud.emit("window.close", "")
end)

harness.run()
