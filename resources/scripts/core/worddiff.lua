--- core/worddiff.lua — which words changed between two versions of a line.
--
-- The diff view pairs each removed line with the added line that replaced
-- it; this splits both into words, spaces, and punctuation, finds the
-- longest run they share (LCS), and reports the rest as changed, so the
-- view can highlight just "foo" -> "bar" instead of the whole line.
--
--     local oldSegs, newSegs = worddiff.segments("a = foo(1)", "a = bar(1)")
--     -- oldSegs = { {text="a = ", changed=false}, {text="foo", changed=true},
--     --             {text="(1)", changed=false} }
--
-- Returns nil when the lines have little in common (highlighting every
-- other word would be noise) or are too long to compare cheaply.

local worddiff = {}

local MAX_TOKENS = 160
local MIN_SHARED = 0.3   -- of the longer line's characters

--- Split a line into tokens: identifier-ish runs, whitespace runs, and
-- single other characters (whole UTF-8 sequences).
-- @param s  the line
-- @return array of strings
local function tokenize(s)
    local tokens = {}
    local i = 1

    while i <= #s do
        local first, last = s:find("^[%w_]+", i)
        if not first then
            first, last = s:find("^%s+", i)
        end
        if not first then
            first, last = s:find("^[\xC2-\xF4][\x80-\xBF]+", i)
        end
        if not first then
            first, last = i, i
        end
        tokens[#tokens + 1] = s:sub(first, last)
        i = last + 1
    end

    return tokens
end

--- Merge tokens into segments of equal "changed" state.
-- @param tokens  array of strings
-- @param keep    set of token indices that are shared
-- @return array of { text, changed }
local function merge(tokens, keep)
    local out = {}

    for i, token in ipairs(tokens) do
        local changed = not keep[i]
        local last = out[#out]
        if last and last.changed == changed then
            last.text = last.text .. token
        else
            out[#out + 1] = { text = token, changed = changed }
        end
    end

    return out
end

--- Changed / unchanged segments of both lines.
-- @param old  the removed line (display text)
-- @param new  the added line (display text)
-- @return oldSegments, newSegments — or nil when not worth highlighting
function worddiff.segments(old, new)
    if old == new then
        return nil
    end

    local a = tokenize(old)
    local b = tokenize(new)
    local n = #a
    local m = #b
    if n == 0 or m == 0 or n > MAX_TOKENS or m > MAX_TOKENS then
        return nil
    end

    -- dp[i][j] = LCS length of a[i..n] and b[j..m], flattened.
    local width = m + 1
    local dp = {}
    for i = n + 1, 1, -1 do
        for j = m + 1, 1, -1 do
            local k = (i - 1) * width + j
            if i > n or j > m then
                dp[k] = 0
            elseif a[i] == b[j] then
                dp[k] = dp[i * width + j + 1] + 1
            else
                local down = dp[i * width + j]
                local right = dp[(i - 1) * width + j + 1]
                dp[k] = down > right and down or right
            end
        end
    end

    local keepA = {}
    local keepB = {}
    local shared = 0
    local i = 1
    local j = 1
    while i <= n and j <= m do
        if a[i] == b[j] then
            keepA[i] = true
            keepB[j] = true
            shared = shared + #a[i]
            i = i + 1
            j = j + 1
        elseif dp[i * width + j] >= dp[(i - 1) * width + j + 1] then
            i = i + 1
        else
            j = j + 1
        end
    end

    if shared < MIN_SHARED * math.max(#old, #new) then
        return nil
    end

    return merge(a, keepA), merge(b, keepB)
end

return worddiff
