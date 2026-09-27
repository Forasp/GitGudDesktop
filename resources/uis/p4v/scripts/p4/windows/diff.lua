--- p4/windows/diff.lua — the Diff window (layouts/windows/diff.xml), P4Merge
-- style: both versions side by side as whole files, removed lines tinted on
-- the left, added lines on the right, changed lines paired with the words
-- that changed highlighted. Previous / Next Diff (Shift+F7 / F7) step
-- through the differences; the lists scroll together.
--
--     require("p4.windows.diff").open({ oldPath, oldRev, newPath, newRev })

local C = require("core.palette")
local selection = require("p4.selection")
local text = require("core.text")
local windows = require("p4.windows")
local worddiff = require("core.worddiff")

local diffwin = {}

local MAX_PAD = 400
local WHOLE_FILE = 1000000   -- context lines: show every line

local open = {}   -- id -> state

--- Tabs to spaces, no line terminator.
local function expand(s)
    return (s:gsub("[\r\n]+$", ""):gsub("\t", "    "))
end

--- Pair a diff's lines into side-by-side rows.
-- @param fileDiff  gitgud.diffVersions() result
-- @return rows: { left = line?, right = line?, kind = "same"|"change"|"del"|"add" }
local function buildRows(fileDiff)
    local rows = {}
    for _, hunk in ipairs(fileDiff.hunks or {}) do
        local dels, adds = {}, {}
        local function flush()
            local n = math.max(#dels, #adds)
            for i = 1, n do
                local kind = (dels[i] and adds[i]) and "change" or (dels[i] and "del" or "add")
                rows[#rows + 1] = { left = dels[i], right = adds[i], kind = kind }
            end
            dels, adds = {}, {}
        end
        for _, line in ipairs(hunk.lines) do
            if line.origin == "-" then
                dels[#dels + 1] = line
            elseif line.origin == "+" then
                adds[#adds + 1] = line
            elseif line.origin == " " then
                flush()
                rows[#rows + 1] = { left = line, right = line, kind = "same" }
            end
        end
        flush()
    end

    return rows
end

--- Both files unchanged: show the file as "same" rows.
-- @param content  file text
-- @return rows
local function sameRows(content)
    local rows = {}
    local n = 0
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local entry = { content = line, oldLineno = n, newLineno = n, origin = " " }
        rows[#rows + 1] = { left = entry, right = entry, kind = "same" }
    end
    if #rows > 0 and rows[#rows].left.content == "" then
        rows[#rows] = nil
    end

    return rows
end

--- One side of a row as markup.
-- @param state  window state
-- @param row    row
-- @param side   "left" | "right"
-- @return markup
local function sideMarkup(state, row, side)
    local line = row[side]
    local number = line and (side == "left" and line.oldLineno or line.newLineno)
    local cell = "[bg-colour='00000000'][colour='" .. C.dim .. "']"
        .. string.format(" %5s ", (number and number > 0) and tostring(number) or "")

    if not line then
        return cell .. "[bg-colour='" .. C.diffGap .. "']" .. string.rep(" ", state.pad + 1)
    end

    local tint = "00000000"
    local strong = nil
    if row.kind == "change" then
        tint = C.diffChange
        strong = side == "left" and C.diffDelWord or C.diffAddWord
    elseif row.kind == "del" then
        tint = C.diffDel
    elseif row.kind == "add" then
        tint = C.diffAdd
    end

    local content = expand(line.content)
    local body = ""
    local length = 0
    local segments = nil
    if row.kind == "change" and state.words then
        row.segments = row.segments or { worddiff.segments(expand(row.left.content), expand(row.right.content)) }
        segments = side == "left" and row.segments[1] or row.segments[2]
    end
    if segments then
        for _, segment in ipairs(segments) do
            body = body .. "[bg-colour='" .. (segment.changed and strong or tint) .. "']" .. text.escape(segment.text)
            length = length + #segment.text
        end
    else
        body = "[bg-colour='" .. tint .. "']" .. text.escape(content)
        length = #content
    end
    if length < state.pad then
        body = body .. "[bg-colour='" .. tint .. "']" .. string.rep(" ", state.pad - length)
    end

    return cell .. "[colour='" .. C.text .. "']" .. " " .. body
end

--- The middle gutter's marker for a row.
local function gutterMarkup(row)
    if row.kind == "change" then
        return text.colour(C.yellow, " •")
    end
    if row.kind == "del" then
        return text.colour(C.del, " -")
    end
    if row.kind == "add" then
        return text.colour(C.add, " +")
    end

    return " "
end

--- A header: which version this side shows.
-- @param path  file
-- @param rev   revision
-- @return markup
local function headerMarkup(path, rev)
    local label = windows.revisionLabel(rev)
    local detail = ""
    if rev ~= "workdir" and rev ~= "index" then
        local commit = (gitgud.history({ max = 1, from = rev == "head" and "HEAD" or rev }) or {})[1]
        if commit then
            detail = "   " .. commit.shortOid .. "  " .. commit.author .. "  " .. os.date("%Y/%m/%d %H:%M", commit.time)
        end
    end

    return "  " .. text.colour(C.text, selection.depotPath(path) .. "  " .. label) .. text.colour(C.dim, detail)
end

--- Load and draw the diff.
-- @param state  window state
local function render(state)
    local id = state.id
    local spec = state.spec
    gitgud.setText(id .. ":LeftHeader", headerMarkup(spec.oldPath, spec.oldRev))
    gitgud.setText(id .. ":RightHeader", headerMarkup(spec.newPath, spec.newRev))

    local fileDiff, err = gitgud.diffVersions(spec.oldPath, spec.oldRev, spec.newPath, spec.newRev,
        { ignoreWhitespace = state.ignoreWhitespace, context = WHOLE_FILE })
    if not fileDiff then
        gitgud.setList(id .. ":DiffLeft", { text.colour(C.err, "  " .. tostring(err)) })
        return
    end
    if fileDiff.binary then
        state.rows = {}
        local message = text.colour(C.dim, "  Binary file: no line diff. The versions "
            .. (#(fileDiff.hunks or {}) > 0 and "differ." or "are identical."))
        gitgud.setList(id .. ":DiffLeft", { message })
        gitgud.setList(id .. ":DiffRight", { message })
        gitgud.setList(id .. ":DiffMid", {})
        gitgud.setText(id .. ":DiffCount", "")
        return
    end

    local rows = buildRows(fileDiff)
    if #rows == 0 then
        rows = sameRows(gitgud.fileAt(spec.newPath, spec.newRev) or gitgud.fileAt(spec.oldPath, spec.oldRev) or "")
    end
    state.rows = rows

    local pad = 0
    for _, row in ipairs(rows) do
        for _, side in ipairs({ "left", "right" }) do
            if row[side] then
                pad = math.max(pad, #expand(row[side].content))
            end
        end
    end
    state.pad = math.min(pad, MAX_PAD)

    local left, mid, right = {}, {}, {}
    state.blocks = {}
    local previous = "same"
    for i, row in ipairs(rows) do
        left[i] = sideMarkup(state, row, "left")
        right[i] = sideMarkup(state, row, "right")
        mid[i] = gutterMarkup(row)
        if row.kind ~= "same" and previous == "same" then
            state.blocks[#state.blocks + 1] = i
        end
        previous = row.kind
    end
    gitgud.setList(id .. ":DiffLeft", left)
    gitgud.setList(id .. ":DiffMid", mid)
    gitgud.setList(id .. ":DiffRight", right)

    local added, removed = 0, 0
    for _, row in ipairs(rows) do
        if row.kind == "add" or row.kind == "change" then
            added = added + 1
        end
        if row.kind == "del" or row.kind == "change" then
            removed = removed + 1
        end
    end
    local count = #state.blocks
    gitgud.setText(id .. ":DiffCount", text.colour(C.text, count == 0 and "No differences"
        or (text.plural(count, "difference") .. "   ")) .. (count > 0 and (text.colour(C.add, "+" .. added)
        .. text.colour(C.dim, " / ") .. text.colour(C.del, "-" .. removed)) or ""))
    gitgud.setText(id .. ":FooterText", text.colour(C.dim, "F7 next difference   ·   Shift+F7 previous   ·   Esc closes"
        .. (state.ignoreWhitespace and "   ·   whitespace ignored" or "")))
    state.current = 0
end

--- Scroll to difference `n`.
-- @param state  window state
-- @param n      1-based block index (wraps)
local function goTo(state, n)
    local count = #(state.blocks or {})
    if count == 0 then
        return
    end
    if n < 1 then
        n = count
    elseif n > count then
        n = 1
    end
    state.current = n
    local row = state.blocks[n]
    -- Put the block a few rows below the top so its context shows.
    local target = math.max(1, row - 4)
    gitgud.selectListItem(state.id .. ":DiffRight", #state.rows, true)
    gitgud.selectListItem(state.id .. ":DiffRight", target, true)
    gitgud.selectListItem(state.id .. ":DiffRight", row, false)
    gitgud.selectListItem(state.id .. ":DiffLeft", row, false)
    gitgud.setText(state.id .. ":FooterText", text.colour(C.dim, "Difference " .. n .. " of " .. count
        .. "   ·   F7 next   ·   Shift+F7 previous   ·   Esc closes"))
end

--- Open a Diff window.
-- @param spec  { oldPath, oldRev, newPath, newRev }
-- @return window id
function diffwin.open(spec)
    local title = "Diff: " .. selection.depotPath(spec.newPath) .. "  (" .. windows.revisionLabel(spec.oldRev)
        .. " vs " .. windows.revisionLabel(spec.newRev) .. ")"
    local id = windows.open("diff", title, "windows/diff.xml", 1180, 760)
    if not id then
        return nil
    end
    local state = { id = id, spec = spec, ignoreWhitespace = false, words = true, rows = {}, blocks = {} }
    open[id] = state

    gitgud.linkScroll(id .. ":DiffLeft", id .. ":DiffMid")
    gitgud.linkScroll(id .. ":DiffMid", id .. ":DiffRight")

    gitgud.on(id .. ":NextButton.clicked", function()
        goTo(state, (state.current or 0) + 1)
    end)
    gitgud.on(id .. ":PrevButton.clicked", function()
        goTo(state, (state.current or 1) - 1)
    end)
    gitgud.on(id .. ":WhitespaceCheck.toggled", function(value)
        state.ignoreWhitespace = value == "1"
        render(state)
    end)
    gitgud.on(id .. ":WordsCheck.toggled", function(value)
        state.words = value == "1"
        render(state)
    end)
    gitgud.on(id .. ":SwapButton.clicked", function()
        spec.oldPath, spec.newPath = spec.newPath, spec.oldPath
        spec.oldRev, spec.newRev = spec.newRev, spec.oldRev
        render(state)
    end)
    gitgud.on(id .. ":EditButton.clicked", function()
        require("core.shell").openInEditor(require("core.repo").state().path .. "/" .. spec.newPath)
    end)
    windows.onKey(id, function(combo)
        if combo == "escape" then
            windows.close(id)
        elseif combo == "f7" or combo == "ctrl+down" then
            goTo(state, (state.current or 0) + 1)
        elseif combo == "shift+f7" or combo == "ctrl+up" then
            goTo(state, (state.current or 1) - 1)
        end
    end)
    windows.onClose(id, function()
        open[id] = nil
    end)

    render(state)
    if #state.blocks > 0 then
        goTo(state, 1)
    end

    return id
end

--- Redraw every open diff (after the workspace changed).
function diffwin.refreshAll()
    for _, state in pairs(open) do
        if state.spec.newRev == "workdir" or state.spec.oldRev == "workdir" then
            render(state)
        end
    end
end

--- The state of an open diff window (tests).
function diffwin.state(id)
    return open[id]
end

return diffwin
