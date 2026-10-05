--- core/staging.lua: staging that honours View > Hide whitespace changes.
--
-- With whitespace changes hidden, a change that only touches whitespace is
-- never staged: including a whole file stages its other changes only, and
-- the diff's checkboxes stage the lines they show. Lines that changed more
-- than whitespace show (and stage) as usual.
--
-- gitgud.stagedLines / setStagedLines index the exact diff; the diff shown
-- with whitespace hidden is a different one. Changed lines are matched
-- between the two by their line number in the old (removed lines) or new
-- (added lines) file; exact-diff changes with no match are whitespace-only.
--
--   staging.hidesWhitespace()      the setting
--   staging.stage(paths)           include whole files (true, or nil + error)
--   staging.lineMap(path, shown)   -> { exactOf = {[shownIdx] = exactIdx},
--                                       shownOf = {[exactIdx] = shownIdx},
--                                       lineCount }  (exact diff's), or nil

local settings = require("core.settings")

local staging = {}

--- Whether whitespace-only changes are hidden (and so left out of staging).
-- @return boolean
function staging.hidesWhitespace()
    return settings.get("hideWhitespace", false)
end

--- "-12" / "+40": a changed line's side and line number, or nil.
-- @param line  diff line table
-- @return key string or nil
local function key(line)
    if line.origin == "-" then
        return "-" .. tostring(line.oldLineno)
    elseif line.origin == "+" then
        return "+" .. tostring(line.newLineno)
    end
    return nil
end

--- Flat index of every changed line, by key.
-- @param fileDiff  gitgud diff table
-- @return { [key] = flat index }, total line count
local function changedLines(fileDiff)
    local out = {}
    local idx = 0
    for _, hunk in ipairs(fileDiff.hunks) do
        for _, line in ipairs(hunk.lines) do
            idx = idx + 1
            local k = key(line)
            if k then
                out[k] = idx
            end
        end
    end
    return out, idx
end

--- Match the changed lines of `shown` (a diff of `path` made with
-- whitespace ignored) to the exact diff staging uses.
-- @param path   repository-relative path
-- @param shown  the displayed gitgud diff table
-- @return map table (see the header), or nil and an error
function staging.lineMap(path, shown)
    local exact, err = gitgud.diff(path, "head")
    if not exact then
        return nil, err
    end

    local exactByKey, lineCount = changedLines(exact)
    local map = { exactOf = {}, shownOf = {}, lineCount = lineCount }
    local idx = 0
    for _, hunk in ipairs(shown.hunks) do
        for _, line in ipairs(hunk.lines) do
            idx = idx + 1
            local k = key(line)
            local exactIdx = k and exactByKey[k]
            if exactIdx then
                map.exactOf[idx] = exactIdx
                map.shownOf[exactIdx] = idx
            end
        end
    end
    return map
end

--- Stage one file without its whitespace-only changes.
-- @param file  status row
-- @return true, or nil and an error
local function stageWithoutWhitespace(file)
    -- Only text changes to a tracked file have whitespace-only lines to
    -- leave out; new, deleted, and binary files go in whole.
    if file.code ~= "M" then
        return gitgud.stage(file.path)
    end
    local shown, err = gitgud.diff(file.path, "head", { ignoreWhitespace = true })
    if not shown then
        return nil, err
    end
    if shown.binary then
        return gitgud.stage(file.path)
    end

    local map, mapErr = staging.lineMap(file.path, shown)
    if not map then
        return nil, mapErr
    end
    local indices = {}
    for _, exactIdx in pairs(map.exactOf) do
        indices[#indices + 1] = exactIdx
    end
    table.sort(indices)
    return gitgud.setStagedLines(file.path, indices, map.lineCount)
end

--- Include whole files in the next commit, leaving out whitespace-only
-- changes while they're hidden.
-- @param paths  path or array of paths
-- @return true, or nil and an error
function staging.stage(paths)
    if type(paths) == "string" then
        paths = { paths }
    end
    if not staging.hidesWhitespace() then
        return gitgud.stage(paths)
    end

    local rows = {}
    for _, file in ipairs(require("core.repo").state().files) do
        rows[file.path] = file
    end
    for _, path in ipairs(paths) do
        local file = rows[path] or { path = path, code = "M" }
        local ok, err = stageWithoutWhitespace(file)
        if not ok then
            return nil, err
        end
    end
    return true
end

return staging
