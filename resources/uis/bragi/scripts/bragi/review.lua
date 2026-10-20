--- bragi/review.lua: reviewing Claude's changes, in the Agent
-- view (layouts/bragi/agent.xml, AgentReview).
--
-- Review (the header button, Ctrl+Shift+R, or the palette) covers the
-- conversation with the open repository's changes against HEAD: the files
-- on the left (the ones the session edited first, marked), the chosen
-- file's diff on the right, one column with both line numbers. Clicking a
-- line asks for a comment; a commented line shows it underneath, and
-- clicking either again edits it (an empty comment removes it).
--
-- Send comments puts every comment into one message to the session (each
-- with its file, line, and the line's text) and goes back to the
-- conversation. Back (or Esc) keeps them for later; Clear drops them.
-- Comments are kept per file and line, so they survive the diff changing
-- under them, though a line that moved is still named by its old number.
--
-- Public API: review.open(), review.close(), review.isOpen(),
-- review.files(), review.edited(path), review.selectFile(path), review.rows(),
-- review.comment(row, text), review.comments(), review.message(),
-- review.send(), review.clear()

local C = require("core.palette")
local dialog = require("ui.dialog")
local shell = require("bragi.shell")
local text = require("core.text")

local review = { name = "bragi.review" }

local MAX_LINES = 4000      -- rows drawn for one file

local open = false
local files = {}            -- { {path, code, edited} }
local current = nil         -- the path shown
local rows = {}             -- the diff list's rows: {kind, line, path, key}
local comments = {}         -- key -> {path, line, origin, content, text, order}
local order = 0

local EDIT_TOOLS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

--- Folder separators and case as Windows compares them.
local function norm(path)
    path = tostring(path or ""):gsub("\\", "/")
    if gitgud.platform == "windows" then
        path = path:lower()
    end
    return path
end

--- The files the session edited (from its Edit and Write steps), as
-- normalised absolute paths.
local function editedPaths()
    local set = {}
    for _, item in ipairs(require("bragi.agent").items()) do
        if item.kind == "step" and EDIT_TOOLS[item.title] and not item.error then
            local input = gitgud.jsonDecode(item.inputText or "") or {}
            local path = input.file_path or input.notebook_path
            if path then
                set[norm(path)] = true
            end
        end
    end
    return set
end

--- A comment's key: the file and the line as the diff names it.
local function lineKey(path, line)
    local number = line.newLineno and line.newLineno >= 0 and line.newLineno or line.oldLineno
    local side = line.origin == "-" and "old" or "new"
    return path .. "\n" .. side .. "\n" .. tostring(number)
end

--- The line number a comment names, and which version it's in.
local function lineNumber(c)
    if c.origin == "-" then
        return c.oldLineno, "old"
    end
    return c.newLineno, "new"
end

local function count()
    local n = 0
    for _ in pairs(comments) do
        n = n + 1
    end
    return n
end

--- Comments in the order they were written, files grouped.
function review.comments()
    local list = {}
    for _, c in pairs(comments) do
        list[#list + 1] = c
    end
    table.sort(list, function(a, b)
        if a.path ~= b.path then
            return a.firstOrder < b.firstOrder
        end
        local an, bn = lineNumber(a), lineNumber(b)
        if an ~= bn then
            return (an or 0) < (bn or 0)
        end
        return a.order < b.order
    end)
    return list
end

--- Paint the header: the count, and Send only with something to send.
local function paintBar()
    local n = count()
    local repoName = require("core.repo").state().name
    local title = "Review changes" .. (repoName ~= "" and ("  [font='Bragi-13'][colour='" .. C.sub .. "']in "
        .. text.escape(repoName)) or "")
    if n > 0 then
        title = title .. "[font='Bragi-13'][colour='" .. C.accentText .. "']   " .. n
            .. (n == 1 and " comment" or " comments")
    end
    gitgud.setText("AgentReviewTitle", title)
    gitgud.setEnabled("AgentReviewSend", n > 0)
    gitgud.setEnabled("AgentReviewClear", n > 0)
    local on = n > 0
    gitgud.setProperty("AgentReviewSend", "NormalFillColour", on and C.accent or C.transparent)
    gitgud.setProperty("AgentReviewSend", "HoverFillColour", on and C.accentHover or C.hover)
    gitgud.setProperty("AgentReviewSend", "BorderColour", on and C.transparent or C.border)
    for _, s in ipairs({ "Normal", "Hover", "Pushed" }) do
        gitgud.setProperty("AgentReviewSend", s .. "TextColour", on and C.onAccent or C.sub)
    end
    gitgud.setText("AgentReviewButton", n > 0 and ("Review  " .. n) or "Review")
end

--- How many comments a file has.
local function fileComments(path)
    local n = 0
    for _, c in pairs(comments) do
        if c.path == path then
            n = n + 1
        end
    end
    return n
end

local CODE_COLOUR = { A = "add", ["?"] = "add", D = "del", M = "warn", U = "err" }

local function paintFiles()
    local list, selected = {}, nil
    for i, f in ipairs(files) do
        local colour = C[CODE_COLOUR[f.code] or "sub"] or C.sub
        local code = f.code == "?" and "A" or f.code
        local row = "[font='Bragi-Mono-13'][colour='" .. colour .. "'] " .. text.escape(code) .. "  "
            .. "[font='Bragi-13'][colour='" .. C.text .. "']" .. text.escape(text.basename(f.path))
        local dir = f.path:match("^(.*)/[^/]+$")
        if dir then
            row = row .. "[colour='" .. C.sub .. "']  " .. text.escape(dir)
        end
        if f.edited then
            row = row .. "[colour='" .. C.accentText .. "']  \u{2022}"
        end
        local n = fileComments(f.path)
        if n > 0 then
            row = row .. "[colour='" .. C.accentText .. "']  " .. n
        end
        list[i] = row
        if f.path == current then
            selected = i
        end
    end
    gitgud.setList("AgentReviewFiles", list)
    gitgud.selectListItem("AgentReviewFiles", selected, false)
end

--- Tabs to spaces, so columns line up in the list.
local function expand(s)
    return (s or ""):gsub("[\r\n]+$", ""):gsub("\t", "    ")
end

local function numberText(n)
    if not n or n < 0 then
        return "     "
    end
    return string.format("%5d", n)
end

--- One row's markup.
local function rowText(row)
    if row.kind == "header" then
        return "[colour='" .. C.sub .. "']" .. text.escape(row.text)
    elseif row.kind == "note" then
        return "[font='Bragi-13'][colour='" .. C.sub .. "']" .. text.escape(row.text)
    elseif row.kind == "comment" then
        return "[font='Bragi-13'][colour='" .. C.accentText .. "']" .. string.rep(" ", 14) .. "\u{2192} "
            .. text.escape(row.comment.text)
    end
    local line = row.line
    local origin = line.origin
    local colour = origin == "+" and C.add or (origin == "-" and C.del or C.sub)
    local mark = comments[row.key] and ("[colour='" .. C.accentText .. "']\u{25CF}") or " "
    return mark .. "[colour='" .. C.sub .. "']" .. numberText(line.oldLineno) .. " " .. numberText(line.newLineno)
        .. "[colour='" .. colour .. "'] " .. (origin == " " and " " or text.escape(origin)) .. " "
        .. "[colour='" .. (origin == " " and C.sub or C.text) .. "']" .. text.escape(expand(line.content))
end

--- Build the rows of the shown file and draw them.
local function paintDiff()
    rows = {}
    if current then
        local d = gitgud.diff(current, "head")
        if type(d) ~= "table" then
            rows[1] = { kind = "note", text = "This file's changes can't be shown." }
        elseif d.binary then
            rows[1] = { kind = "note", text = "A binary file: nothing to comment on line by line." }
        else
            for _, hunk in ipairs(d.hunks or {}) do
                rows[#rows + 1] = { kind = "header", text = hunk.header and expand(hunk.header) or "" }
                for _, line in ipairs(hunk.lines or {}) do
                    if #rows >= MAX_LINES then
                        break
                    end
                    if line.origin == "+" or line.origin == "-" or line.origin == " " then
                        local key = lineKey(current, line)
                        rows[#rows + 1] = { kind = "line", line = line, path = current, key = key }
                        if comments[key] then
                            rows[#rows + 1] = { kind = "comment", comment = comments[key], key = key }
                        end
                    end
                end
            end
            if #rows == 0 then
                rows[1] = { kind = "note", text = "No changes in this file's text." }
            end
        end
    end
    local list = {}
    for i, row in ipairs(rows) do
        list[i] = rowText(row)
    end
    gitgud.setList("AgentReviewDiff", list)
end

--- Read the working tree's changes again.
local function readFiles()
    local edited = editedPaths()
    local root = norm(require("core.repo").state().path)
    files = {}
    for _, s in ipairs(gitgud.isOpen() and gitgud.status() or {}) do
        files[#files + 1] = { path = s.path, code = s.code, edited = edited[root .. "/" .. norm(s.path)] == true }
    end
    table.sort(files, function(a, b)
        if a.edited ~= b.edited then
            return a.edited
        end
        return a.path:lower() < b.path:lower()
    end)
    local still = false
    for _, f in ipairs(files) do
        still = still or f.path == current
    end
    if not still then
        current = files[1] and files[1].path or nil
    end
    gitgud.setVisible("AgentReviewEmpty", #files == 0)
    gitgud.setVisible("AgentReviewFiles", #files > 0)
    gitgud.setVisible("AgentReviewDiff", #files > 0)
end

local function paint()
    paintBar()
    paintFiles()
    paintDiff()
end

--- Did the session in the Agent view edit this file (Edit, Write ...)?
-- @param path  repository-relative path
function review.edited(path)
    local root = norm(require("core.repo").state().path)
    return editedPaths()[root .. "/" .. norm(path)] == true
end

--- The changed files: { {path, code, edited} }, the session's edits first.
function review.files()
    return files
end

--- The diff list's rows (for tests): { kind = "header" | "line" |
-- "comment" | "note", line, key, comment }.
function review.rows()
    return rows
end

--- Show a file's diff.
function review.selectFile(path)
    current = path
    paintFiles()
    paintDiff()
    gitgud.setScroll("AgentReviewDiff", 0)
end

--- Set or remove (empty text) the comment on a row of the diff.
-- @param i     row index (1-based)
-- @param body  the comment
function review.comment(i, body)
    local row = rows[i]
    if not row or (row.kind ~= "line" and row.kind ~= "comment") then
        return false
    end
    local key = row.key
    body = text.trim(body or "")
    if body == "" then
        comments[key] = nil
    elseif comments[key] then
        comments[key].text = body
    else
        local line = row.line
        local first = nil
        for _, c in pairs(comments) do
            if c.path == row.path then
                first = math.min(first or c.firstOrder, c.firstOrder)
            end
        end
        order = order + 1
        comments[key] = {
            path = row.path, origin = line.origin, content = expand(line.content),
            oldLineno = line.oldLineno, newLineno = line.newLineno,
            text = body, order = order, firstOrder = first or order,
        }
    end
    local scroll = gitgud.getScroll("AgentReviewDiff")
    paint()
    gitgud.setScroll("AgentReviewDiff", scroll)
    return true
end

--- Ask for a comment on a clicked row.
local function askComment(i)
    local row = rows[i]
    if not row or (row.kind ~= "line" and row.kind ~= "comment") then
        return
    end
    local c = comments[row.key]
    local number, side
    if c then
        number, side = lineNumber(c)
    else
        local line = row.line
        number = line.origin == "-" and line.oldLineno or line.newLineno
        side = line.origin == "-" and "old" or "new"
    end
    local where = text.basename(row.path or (c and c.path) or "") .. ", line " .. tostring(number)
        .. (side == "old" and " (removed)" or "")
    dialog.show({
        title = "Comment on " .. where,
        fields = { { label = "Comment (empty removes it)", value = c and c.text or "" } },
        ok = c and "Save" or "Add",
        onOk = function(v)
            review.comment(i, v.fields[1])
            return true
        end,
    })
end

--- The message Send comments sends.
function review.message()
    local list = review.comments()
    if #list == 0 then
        return nil
    end
    local out = { "Review comments on the changes. Please address each one:", "" }
    for i, c in ipairs(list) do
        local number, side = lineNumber(c)
        local what = side == "old" and (" (removed line " .. tostring(number) .. ")") or (", line " .. tostring(number))
        out[#out + 1] = i .. ". " .. c.path .. what .. ": `" .. text.trim(c.content) .. "`"
        for piece in (c.text .. "\n"):gmatch("(.-)\n") do
            out[#out + 1] = "   " .. piece
        end
    end
    return table.concat(out, "\n")
end

--- Drop every comment.
function review.clear()
    comments = {}
    paint()
end

--- Send every comment to the session as one message, and go back to it.
function review.send()
    local body = review.message()
    if not body then
        return false
    end
    review.close()
    comments = {}
    paintBar()
    require("bragi.agent").send(body)
    return true
end

function review.isOpen()
    return open
end

function review.open()
    open = true
    shell.show("agent")
    readFiles()
    paint()
    gitgud.setVisible("AgentReview", true)
    gitgud.bringToFront("AgentReview")
end

function review.close()
    open = false
    gitgud.setVisible("AgentReview", false)
    gitgud.focus("AgentPromptEdit")
end

local function toggle()
    if open then
        review.close()
    else
        review.open()
    end
end

function review.init()
    gitgud.on("AgentReviewButton.clicked", toggle)
    gitgud.on("AgentReviewClose.clicked", review.close)
    gitgud.on("AgentReviewSend.clicked", review.send)
    gitgud.on("AgentReviewClear.clicked", function()
        dialog.confirm("Clear the comments?", "Every comment on these changes is dropped.", "Clear", review.clear, true)
    end)
    gitgud.on("AgentReviewFiles.selected", function(value)
        local f = files[(tonumber(value) or -1) + 1]
        if f and f.path ~= current then
            review.selectFile(f.path)
        end
    end)
    gitgud.on("AgentReviewDiff.selected", function(value)
        local i = (tonumber(value) or -1) + 1
        if i >= 1 then
            -- Clear it, so clicking the same line again asks again.
            gitgud.selectListItem("AgentReviewDiff", nil, false)
            askComment(i)
        end
    end)
    shell.bind("ctrl+shift+r", toggle)
    shell.bind("escape", function()
        if open then
            review.close()
        else
            require("bragi.agent").stop()
        end
    end)
    require("ui.commands").register({ label = "Review changes", keywords = "diff comments review code",
        action = review.open })
    paintBar()
end

function review.refresh()
    if open then
        readFiles()
        paint()
    end
end

return review
