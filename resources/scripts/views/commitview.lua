--- views/commitview.lua — the commit header + file list arrangement.
--
-- Shared by the History tab (a selected commit) and the stash viewer: it
-- fills CommitHeader, lists the files in CommitFilesList, and shows the
-- picked file's diff through views/content.lua.
--
-- Public API:
--   commitview.show({
--       summary = "...", body = "...", meta = "...",   -- plain text
--       oid = "<commit the files belong to>",
--       files = { fileDiff, ... },                      -- gitgud.commitDiff()
--       actions = { { label = "Restore", action = fn }, ... },  -- up to 2
--   })
--   commitview.current()   -> the spec being shown (or nil)
--   commitview.selectFile(i)

local C = require("core.palette")
local content = require("views.content")
local geometry = require("ui.geometry")
local text = require("core.text")

local commitview = { name = "commitview" }

local shown = nil
local selectedFile = 1

--- Colour for a file-status letter.
-- @param code  "A" | "D" | "M" | "R" | "T"
-- @return AARRGGBB
local function statusColour(code)
    if code == "A" then
        return C.add
    end
    if code == "D" then
        return C.del
    end
    if code == "R" then
        return C.blue
    end

    return C.warn
end

--- One CommitFilesList row: status letter, file name, dim folder.
-- @param file  fileDiff table
-- @return markup
local function fileRow(file)
    local dir = text.dirname(file.path)
    local row = text.rowHeight(24) .. " " .. text.colour(statusColour(file.status), file.status .. "  ")
        .. text.colour(C.text, text.basename(file.path))

    if dir ~= "" then
        row = row .. "  " .. text.colour(C.dim, dir)
    end

    return row
end

--- Show one of the listed files in the diff body.
-- @param i  1-based index into shown.files
function commitview.selectFile(i)
    if not shown then
        return
    end

    selectedFile = i
    gitgud.selectListItem("CommitFilesList", i)
    content.showCommitFile(shown.oid, shown.files[i])
end

--- Fill and show the commit arrangement.
-- @param spec  see the header
function commitview.show(spec)
    shown = spec
    local hasBody = (spec.body or "") ~= ""
    content.arrange("commit", not hasBody)
    content.invalidate()

    gitgud.setText("CommitSummaryLabel", text.escape(spec.summary or ""))
    gitgud.setText("CommitBodyLabel", text.escape(spec.body or ""))
    gitgud.setText("CommitMetaLabel", text.escape(spec.meta or ""))
    gitgud.setVisible("CommitBodyLabel", hasBody)
    local metaTop = hasBody and 62 or 40
    gitgud.setProperty("CommitMetaLabel", "Area", geometry.area(0, 18, 0, metaTop, 1, -18, 0, metaTop + 24))

    local actions = spec.actions or {}
    for i = 1, 2 do
        local button = "CommitAction" .. i
        gitgud.setVisible(button, actions[i] ~= nil)
        if actions[i] then
            gitgud.setText(button, text.escape(actions[i].label))
        end
    end

    local rows = {}
    for i, file in ipairs(spec.files or {}) do
        rows[i] = fileRow(file)
    end
    gitgud.setList("CommitFilesList", rows)

    commitview.selectFile(math.min(1, #rows))
end

--- The spec currently shown, or nil.
-- @return spec table
function commitview.current()
    return shown
end

--- Forget the shown commit (the owner switched away).
function commitview.clear()
    shown = nil
    gitgud.setList("CommitFilesList", {})
end

--- Wire file picking and the action buttons.
function commitview.init()
    gitgud.on("CommitFilesList.selected", function(value)
        local row = tonumber(value)
        if row and row >= 0 and shown then
            selectedFile = row + 1
            content.showCommitFile(shown.oid, shown.files[selectedFile])
        end
    end)

    gitgud.on("CommitFilesList.rightClicked", function(value)
        local menu = require("ui.menu")
        local x, y, row = menu.parseClick(value)
        local file = row and shown and shown.files[row]
        if not file then
            return
        end
        commitview.selectFile(row)
        local oid = shown.oid
        menu.popup({
            {
                label = "Show file history",
                action = function()
                    require("views.inspector").history(file.path)
                end,
            },
            {
                label = "Blame as of this commit",
                enabled = file.status ~= "D",
                action = function()
                    require("views.inspector").blame(file.path, oid)
                end,
            },
            { separator = true },
            {
                label = "Copy file path",
                action = function()
                    require("core.shell").copy(file.path, "path")
                end,
            },
        }, x, y)
    end)

    for i = 1, 2 do
        gitgud.on("CommitAction" .. i .. ".clicked", function()
            local action = shown and shown.actions and shown.actions[i]
            if action then
                action.action()
            end
        end)
    end
end

return commitview
