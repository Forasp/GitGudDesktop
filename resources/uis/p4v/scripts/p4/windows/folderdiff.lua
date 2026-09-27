--- p4/windows/folderdiff.lua — the Folder Diff window: every file that
-- differs between two versions of a folder, with what happened to it.
--
--     folderdiff.open(folder, leftRev, rightRev)          -- "" = everything
--     folderdiff.open("", "HEAD", "workdir", { "a.cpp" }) -- only these files

local C = require("core.palette")
local grid = require("p4.grid")
local icons = require("p4.icons")
local selection = require("p4.selection")
local text = require("core.text")
local windows = require("p4.windows")

local folderdiff = {}

--- Fill the window.
-- @param state  window state
local function render(state)
    local id = state.id
    local files, err
    if state.left == "workdir" then
        -- The engine compares towards the workspace; read it that way and
        -- flip adds and deletes so the left side is the workspace.
        files, err = gitgud.changedFiles(state.right, "workdir", state.folder)
        local flip = { A = "D", D = "A" }
        for _, file in ipairs(files or {}) do
            file.status = flip[file.status] or file.status
        end
    else
        files, err = gitgud.changedFiles(state.left, state.right, state.folder)
    end
    local rows = {}
    for _, file in ipairs(files or {}) do
        if not state.only or state.only[file.path] then
            rows[#rows + 1] = {
                icon = icons.inline(icons.forStatus(file.status)),
                cells = {
                    path = selection.depotPath(file.path),
                    action = icons.actionName(file.status),
                    left = file.status == "A" and "—" or windows.revisionLabel(state.left),
                    right = file.status == "D" and "—" or windows.revisionLabel(state.right),
                },
                data = file,
            }
        end
    end
    grid.setRows(id .. ":Grid", rows)

    local where = selection.depotPath(state.folder) .. (state.folder == "" and "/..." or "/...")
    gitgud.setText(id .. ":Title", text.colour(C.text, "Folder Diff: " .. where))
    gitgud.setText(id .. ":Subtitle", text.colour(C.text2, windows.revisionLabel(state.left) .. "   vs   "
        .. windows.revisionLabel(state.right)))
    gitgud.setText(id .. ":Footer", text.colour(C.dim, err and tostring(err)
        or (text.plural(#rows, "file") .. " differ   ·   double-click a file to diff it   ·   Esc closes")))
end

--- Open a Folder Diff window.
-- @param folder  folder path ("" = the whole workspace)
-- @param left    left revision
-- @param right   right revision ("workdir" = the workspace)
-- @param only    optional array of paths to show
function folderdiff.open(folder, left, right, only)
    local title = "Folder Diff: " .. selection.depotPath(folder or "") .. "  (" .. windows.revisionLabel(left)
        .. " vs " .. windows.revisionLabel(right) .. ")"
    local id = windows.open("folderdiff", title, "windows/folderdiff.xml", 900, 600)
    if not id then
        return nil
    end
    local state = { id = id, folder = folder or "", left = left, right = right }
    if only then
        state.only = {}
        for _, path in ipairs(only) do
            state.only[path] = true
        end
    end

    local function diffRow(row)
        local file = row.data
        require("p4.windows").diffRevisions(file.oldPath or file.path, state.left, file.path, state.right)
    end
    grid.create(id .. ":Grid", id .. ":GridHost", {
        columns = {
            { key = "path", title = "File", width = 440 },
            { key = "action", title = "Action", width = 90 },
            { key = "left", title = "Left", width = 110 },
            { key = "right", title = "Right" },
        },
        settingKey = "grid.folderdiff",
        sortKey = "path",
        emptyText = "No differences.",
        onActivate = diffRow,
    })

    gitgud.on(id .. ":DiffButton.clicked", function()
        local row = grid.selected(id .. ":Grid")[1]
        if row then
            diffRow(row)
        end
    end)
    gitgud.on(id .. ":SwapButton.clicked", function()
        state.left, state.right = state.right, state.left
        render(state)
    end)
    windows.onKey(id, function(combo)
        if combo == "escape" then
            windows.close(id)
        end
    end)

    render(state)
    return id
end

return folderdiff
