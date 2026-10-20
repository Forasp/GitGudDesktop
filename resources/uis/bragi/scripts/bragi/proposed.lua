--- bragi/proposed.lua: the change an edit's permission card asks about,
-- before it's made ("View diff" on the card, design D).
--
-- Claude Code asks before Edit, MultiEdit, Write, and NotebookEdit with the
-- tool's input: the text to replace and its replacement, or a file's new
-- content. This shows that as a diff in a dialog: lines removed and added
-- (a small line diff, so unchanged lines inside a replacement read as
-- context), numbered from where the old text sits in the file when it can
-- be found there. Deny and Allow answer the card from the dialog too.
--
-- Public API: proposed.show(item), proposed.close(), proposed.isOpen(),
-- proposed.rows() (for tests: { {sign, old, new, text} })

local C = require("core.palette")
local dialog = require("ui.dialog")
local text = require("core.text")

local proposed = {}

local PANEL = "BragiProposed"
local WIDTH, HEIGHT = 760, 560
local MAX_CELLS = 250000      -- old x new lines the line diff will compare
local CHAR = 7.8              -- Bragi-Mono-13, px per character

local open = nil              -- { item, token }
local shown = {}              -- the rows shown

--- Lines of a string (a final newline adds no empty line).
local function lines(s)
    local out = {}
    s = tostring(s or "")
    if s == "" then
        return out
    end
    for line in (s:gsub("\r\n", "\n") .. (s:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    return out
end

--- A line diff of two arrays: { {sign = " " | "-" | "+", text} } in order.
-- Longest common subsequence; too big, it's all removed then all added.
local function lineDiff(a, b)
    local out = {}
    if #a * #b > MAX_CELLS then
        for _, l in ipairs(a) do
            out[#out + 1] = { sign = "-", text = l }
        end
        for _, l in ipairs(b) do
            out[#out + 1] = { sign = "+", text = l }
        end
        return out
    end
    local n, m = #a, #b
    local len = {}
    for i = n + 1, 1, -1 do
        len[i] = {}
        for j = m + 1, 1, -1 do
            if i > n or j > m then
                len[i][j] = 0
            elseif a[i] == b[j] then
                len[i][j] = len[i + 1][j + 1] + 1
            else
                len[i][j] = math.max(len[i + 1][j], len[i][j + 1])
            end
        end
    end
    local i, j = 1, 1
    while i <= n or j <= m do
        if i <= n and j <= m and a[i] == b[j] then
            out[#out + 1] = { sign = " ", text = a[i] }
            i, j = i + 1, j + 1
        elseif i <= n and (j > m or len[i + 1][j] >= len[i][j + 1]) then
            -- Removed lines before the added ones that replace them.
            out[#out + 1] = { sign = "-", text = a[i] }
            i = i + 1
        else
            out[#out + 1] = { sign = "+", text = b[j] }
            j = j + 1
        end
    end
    return out
end

--- The repository-relative path of a file the tool names, or nil.
local function relative(path)
    local root = (require("core.repo").state().path or ""):gsub("\\", "/")
    path = tostring(path or ""):gsub("\\", "/")
    if root == "" then
        return nil
    end
    local a, b = path, root .. "/"
    if gitgud.platform == "windows" then
        a, b = a:lower(), b:lower()
    end
    if a:sub(1, #b) == b then
        return path:sub(#b + 1)
    end
    return nil
end

--- The file's text now, when it's in the repository.
local function current(path)
    local rel = relative(path)
    return rel and gitgud.readRepoFile(rel) or nil
end

--- The line `s` starts on in `whole` (1-based), or nil.
local function lineOf(whole, s)
    if not whole or s == "" then
        return nil
    end
    local at = whole:find(s, 1, true)
    if not at then
        return nil
    end
    local _, newlines = whole:sub(1, at - 1):gsub("\n", "")
    return newlines + 1
end

--- Number the rows of one replacement from the line it starts on.
local function number(rows, start)
    local old, new = start, start
    for _, r in ipairs(rows) do
        if r.sign ~= "+" then
            r.old = old
            old = old and old + 1
        end
        if r.sign ~= "-" then
            r.new = new
            new = new and new + 1
        end
    end
    return rows
end

--- The rows for a tool's input: { {sign, old, new, text} } plus header
-- rows { {header = "..."} } between a MultiEdit's edits.
-- @return rows, added, removed
function proposed.build(tool, input)
    input = input or {}
    local rows = {}
    local now = current(input.file_path or input.notebook_path)
    local function add(list)
        for _, r in ipairs(list) do
            rows[#rows + 1] = r
        end
    end
    if tool == "Edit" then
        add(number(lineDiff(lines(input.old_string), lines(input.new_string)), lineOf(now, input.old_string or "")))
    elseif tool == "MultiEdit" then
        for i, edit in ipairs(input.edits or {}) do
            rows[#rows + 1] = { header = "Edit " .. i .. " of " .. #input.edits }
            add(number(lineDiff(lines(edit.old_string), lines(edit.new_string)), lineOf(now, edit.old_string or "")))
        end
    elseif tool == "Write" then
        add(number(lineDiff(lines(now or ""), lines(input.content)), 1))
    else
        add(number(lineDiff({}, lines(input.new_source or input.content)), nil))
    end
    local added, removed = 0, 0
    for _, r in ipairs(rows) do
        added = added + (r.sign == "+" and 1 or 0)
        removed = removed + (r.sign == "-" and 1 or 0)
    end
    return rows, added, removed
end

--- One list row, tinted like the Repository view's diff.
local function rowText(r, columns)
    if r.header then
        return "[colour='" .. C.sub .. "']" .. text.escape(r.header)
    end
    local tint = r.sign == "+" and C.addBg or (r.sign == "-" and C.delBg or "00000000")
    local signColour = r.sign == "+" and C.add or C.warn
    local body = r.text:gsub("\t", "    ")
    if #body < columns then
        body = body .. string.rep(" ", columns - #body)
    end
    return "[colour='" .. C.sub .. "']" .. string.format("%5s %5s ", r.old or "", r.new or "")
        .. "[bg-colour='" .. tint .. "'][colour='" .. signColour .. "'] " .. (r.sign == " " and " " or r.sign) .. " "
        .. "[colour='" .. C.text .. "']" .. text.escape(body) .. "[bg-colour='00000000']"
end

--- Build the dialog once.
local function create()
    if gitgud.getRect(PANEL) then
        return
    end
    local ui = require("bragi.ui")
    gitgud.createWindow("Bragi/Box12", PANEL, "Root")
    gitgud.setProperty(PANEL, "Area", "{{0.5," .. -WIDTH / 2 .. "},{0.5," .. -HEIGHT / 2 .. "},{0.5,"
        .. WIDTH / 2 .. "},{0.5," .. HEIGHT / 2 .. "}}")
    gitgud.setProperty(PANEL, "FillColour", C.panel)
    gitgud.setProperty(PANEL, "BorderColour", C.border)
    -- Above the modal shade, which is always on top itself.
    gitgud.setProperty(PANEL, "AlwaysOnTop", "true")
    gitgud.setVisible(PANEL, false)
    ui.label(PANEL .. "Title", PANEL, { 24, 20, WIDTH - 48, 24 }, "", { font = "Bragi-15-Bold" })
    ui.label(PANEL .. "Sub", PANEL, { 24, 46, WIDTH - 48, 20 }, "", { font = "Bragi-13", colour = C.sub, markup = true })
    gitgud.createWindow("Gitgud/ListWidget", PANEL .. "List", PANEL)
    gitgud.setProperty(PANEL .. "List", "Area", "{{0,16},{0,80},{1,-16},{1,-72}}")
    gitgud.setProperty(PANEL .. "List", "Font", "Bragi-Mono-13")
    gitgud.setProperty(PANEL .. "List", "BgColour", C.bg)
    gitgud.setProperty(PANEL .. "List", "BorderColour", C.border)
    gitgud.setProperty(PANEL .. "List", "SelectionColour", C.transparent)
    ui.button(PANEL .. "Close", PANEL, { 24, HEIGHT - 56, 96, 40 }, "Close")
    ui.button(PANEL .. "Deny", PANEL, { WIDTH - 24 - 84 * 2 - 10, HEIGHT - 56, 84, 40 }, "Deny")
    ui.button(PANEL .. "Allow", PANEL, { WIDTH - 24 - 84, HEIGHT - 56, 84, 40 }, "Allow", { primary = true })
    gitgud.on(PANEL .. "Close.clicked", proposed.close)
    gitgud.on(PANEL .. "Deny.clicked", function()
        local item = open and open.item
        proposed.close()
        if item then
            require("bragi.agent").answer(item, false)
        end
    end)
    gitgud.on(PANEL .. "Allow.clicked", function()
        local item = open and open.item
        proposed.close()
        if item then
            require("bragi.agent").answer(item, true)
        end
    end)
end

--- Show the change a permission card asks about.
-- @param item  the card's transcript item ({tool, input, answer})
function proposed.show(item)
    create()
    local rows, added, removed = proposed.build(item.tool, item.input)
    shown = rows
    local path = (item.input or {}).file_path or (item.input or {}).notebook_path or ""
    gitgud.setText(PANEL .. "Title", text.escape(item.tool .. " " .. (relative(path) or path)))
    gitgud.setText(PANEL .. "Sub", text.colour(C.add, "+" .. added) .. " " .. text.colour(C.warn, "−" .. removed)
        .. text.colour(C.sub, "  ·  proposed by the session, not made yet"))
    local columns = math.floor((WIDTH - 32 - 40) / CHAR) - 16
    local list = {}
    for i, r in ipairs(rows) do
        list[i] = rowText(r, columns)
    end
    if #list == 0 then
        list[1] = text.colour(C.sub, "No changes to show.")
    end
    gitgud.setList(PANEL .. "List", list)
    local waiting = not item.answer
    gitgud.setVisible(PANEL .. "Deny", waiting)
    gitgud.setVisible(PANEL .. "Allow", waiting)
    if open then
        proposed.close()
    end
    open = { item = item }
    open.token = dialog.showModal(PANEL, proposed.close)
end

--- Close the dialog.
function proposed.close()
    if open then
        dialog.hideModal(PANEL, open.token)
        open = nil
    end
end

function proposed.isOpen()
    return open ~= nil
end

--- The rows shown (for tests).
function proposed.rows()
    return shown
end

return proposed
