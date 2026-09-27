--- views/graph.lua — the commit graph (GitKraken-style), as an optional view.
--
-- View > Commit graph (Ctrl+3) or the toolbar's Graph button swaps the
-- sidebar for GraphPanel: every branch's history at once, drawn as coloured
-- lanes, with branch and tag labels. The selected commit's details (files and
-- diff) show below it, exactly like in the History tab. Changes / History
-- stay the home screen; closing the graph goes back to them.
--
-- The lane pictures come from the engine (gitgud.graph draws one image per
-- row); here they're placed inline at the start of each GraphList row, and
-- two more lists (author, date) scroll in step with it.
--
-- The top row, when you have uncommitted changes, is the "WIP" row: a hollow
-- dot above HEAD with +added ~modified −deleted counts. Click it to go to
-- the Changes tab.
--
-- Public API: graph.toggle(), graph.show(), graph.hide(), graph.reload(force),
--             graph.selectOid(oid)

local C = require("core.palette")
local app = require("core.app")
local frame = require("views.frame")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local settings = require("core.settings")
local sidebar = require("views.sidebar")
local status = require("core.status")
local text = require("core.text")

local graph = { name = "graph" }

local PAGE = 400
local ROW_HEIGHT = 28
local LISTS = { "GraphList", "GraphAuthorList", "GraphDateList" }

local rows = {}            -- gitgud.graph() rows, in list order
local width = 0            -- pixel width of the lane pictures
local labelsByOid = {}
local loadedKey = nil
local limit = PAGE
local filterText = ""
local selectedOid = nil

--- Index ref labels by commit.
local function loadLabels()
    labelsByOid = {}

    for _, label in ipairs(gitgud.refLabels()) do
        labelsByOid[label.oid] = labelsByOid[label.oid] or {}
        table.insert(labelsByOid[label.oid], label)
    end
end

--- A lane colour by 1-based index.
-- @param index  lane colour index from gitgud.graph
-- @return AARRGGBB
local function laneColour(index)
    return C.lanes[((index or 1) - 1) % #C.lanes + 1]
end

--- A coloured pill for a branch or tag name.
-- @param name    label text
-- @param colour  AARRGGBB of the text; the pill is a faint version of it
-- @param bold    draw the name in the bold font (the checked-out branch)
-- @return markup
local function pill(name, colour, bold)
    local tint = "38" .. colour:sub(3)
    local body = text.escape(" " .. name .. " ")
    if bold then
        body = "[font='Gitgud-UI-Bold']" .. body .. "[font='']"
    end

    return "[bg-colour='" .. tint .. "'][colour='" .. colour .. "']" .. body .. "[bg-colour='00000000'] "
end

--- The labels of a commit as pills (branches in their lane's colour).
-- @param row  graph row
-- @return markup ("" when unlabelled)
local function badges(row)
    local out = ""
    local current = repo.state().branch

    for _, label in ipairs(labelsByOid[row.oid] or {}) do
        if label.kind == "tag" then
            out = out .. pill(label.name, C.yellow, false)
        elseif label.kind == "remote" then
            out = out .. pill(label.name, C.purple, false)
        elseif label.kind == "head" then
            out = out .. pill("HEAD", C.pink, true)
        else
            local isCurrent = label.name == current
            local name = isCurrent and ("✓ " .. label.name) or label.name
            out = out .. pill(name, laneColour(row.colour), isCurrent)
        end
    end

    return out
end

--- Does a commit match the find box?
-- @param row  graph row
-- @return boolean
local function matches(row)
    if filterText == "" or row.wip then
        return true
    end

    return text.contains(row.summary, filterText)
        or text.contains(row.author, filterText)
        or row.oid:sub(1, #filterText):lower() == filterText:lower()
end

--- "+2 ~3 −1" counts for the WIP row.
-- @return markup
local function wipChips()
    local added = 0
    local modified = 0
    local deleted = 0

    for _, file in ipairs(repo.state().files) do
        if file.code == "A" or file.code == "?" then
            added = added + 1
        elseif file.code == "D" then
            deleted = deleted + 1
        else
            modified = modified + 1
        end
    end

    local out = ""
    if added > 0 then
        out = out .. pill("+" .. added, C.add, false)
    end
    if modified > 0 then
        out = out .. pill("~" .. modified, C.warn, false)
    end
    if deleted > 0 then
        out = out .. pill("−" .. deleted, C.del, false)
    end

    return out
end

--- The three column texts of one row.
-- @param row  graph row
-- @return graphMarkup, authorMarkup, dateMarkup
local function rowTexts(row)
    local picture = "[vert-formatting='CentreAligned'][image-size='w:" .. width .. " h:" .. ROW_HEIGHT
        .. "'][image='" .. row.image .. "']"
    local height = text.rowHeight(ROW_HEIGHT)

    if row.wip then
        return picture .. " " .. text.colour(C.dim, "// WIP  ") .. wipChips(),
            height .. text.colour(C.dim, " Uncommitted changes"),
            height
    end

    local dim = not matches(row)
    local summaryColour = dim and C.disabled or C.text
    local graphText = picture .. " " .. badges(row) .. text.colour(summaryColour, row.summary)
    local authorText = height .. text.colour(dim and C.disabled or C.text2, " " .. row.author)
    local dateText = height .. text.colour(dim and C.disabled or C.dim,
        " " .. text.ago(row.time) .. "  ·  " .. row.shortOid)

    return graphText, authorText, dateText
end

--- Fill the three lists from `rows`.
local function renderLists()
    local graphTexts = {}
    local authorTexts = {}
    local dateTexts = {}

    for i, row in ipairs(rows) do
        graphTexts[i], authorTexts[i], dateTexts[i] = rowTexts(row)
    end

    gitgud.setList("GraphList", graphTexts)
    gitgud.setList("GraphAuthorList", authorTexts)
    gitgud.setList("GraphDateList", dateTexts)

    local commits = #rows
    if rows[1] and rows[1].wip then
        commits = commits - 1
    end
    gitgud.setText("GraphFooterLabel", text.escape(text.plural(commits, "commit")
        .. (commits >= limit and " shown (there are more)" or "")))
    gitgud.setVisible("GraphMoreButton", commits >= limit)
end

--- Select row `i` in all three lists (no events).
-- @param i          1-based row
-- @param ensure     scroll it into view
local function selectRow(i, ensure)
    for _, list in ipairs(LISTS) do
        gitgud.selectListItem(list, i, ensure)
    end
end

--- Row index of a commit.
-- @param oid  commit id
-- @return 1-based row or nil
local function rowOf(oid)
    for i, row in ipairs(rows) do
        if row.oid == oid and not row.wip then
            return i
        end
    end

    return nil
end

--- Show a row's details below the graph (or jump to Changes for WIP).
-- @param i  1-based row
local function activate(i)
    local row = rows[i]
    if not row then
        return
    end

    selectRow(i, false)
    if row.wip then
        graph.hide()
        sidebar.select("changes")
        return
    end

    selectedOid = row.oid
    require("views.history").showCommit(row)
end

--- Load (or reload) the graph when something it shows has changed.
-- @param force  reload even if nothing seems to have changed
function graph.reload(force)
    if not frame.graphMode() then
        return
    end

    local state = repo.state()
    if not state.open then
        rows = {}
        renderLists()
        return
    end

    local labels = gitgud.refLabels()
    local parts = { state.headOid, tostring(#state.files > 0), tostring(limit),
        tostring(settings.get("graphRemotes", true)), tostring(settings.get("graphTags", true)) }
    for _, label in ipairs(labels) do
        parts[#parts + 1] = label.name .. "=" .. label.oid
    end
    local key = table.concat(parts, "|")
    if key == loadedKey and not force then
        return
    end
    loadedKey = key

    loadLabels()
    local result, err = gitgud.graph({
        max = limit,
        remotes = settings.get("graphRemotes", true),
        tags = settings.get("graphTags", true),
        wip = #state.files > 0,
        laneWidth = 16,
        rowHeight = ROW_HEIGHT,
        maxLanes = 14,
        colours = C.lanes,
        background = "FF17102B",
        headRing = C.text,
        prefix = "GitgudGraph",
    })
    if not result then
        status.error(err or "Could not draw the graph.")
        rows = {}
        renderLists()
        return
    end

    rows = result.rows
    width = result.width
    renderLists()

    local keep = selectedOid and rowOf(selectedOid)
    if not keep then
        keep = rowOf(state.headOid) or (rows[1] and 1)
    end
    if keep then
        activate(keep)
        selectRow(keep, true)
    end
end

--- Put the graph on screen.
function graph.show()
    if not repo.state().open then
        status.warn("Open a repository first.")
        return
    end

    frame.setGraph(true)
end

--- Go back to Changes / History.
function graph.hide()
    frame.setGraph(false)
end

--- Toggle the graph.
function graph.toggle()
    if frame.graphMode() then
        graph.hide()
    else
        graph.show()
    end
end

--- Select (and show) a commit if it's in the graph; opens the graph first.
-- @param oid  commit id
function graph.selectOid(oid)
    selectedOid = oid
    graph.show()
    local i = rowOf(oid)
    if i then
        activate(i)
        selectRow(i, true)
    end
end

--- Move the selection by `delta` rows (arrow keys).
-- @param delta  +1 / -1 / page sizes
local function moveSelection(delta)
    local current = gitgud.getSelectedIndex("GraphList") or 1
    local target = math.max(1, math.min(#rows, current + delta))
    activate(target)
    selectRow(target, true)
end

--- Jump to the next commit matching the find box.
local function findNext()
    if filterText == "" then
        return
    end

    local start = gitgud.getSelectedIndex("GraphList") or 0
    for step = 1, #rows do
        local i = (start + step - 1) % #rows + 1
        if not rows[i].wip and matches(rows[i]) then
            activate(i)
            selectRow(i, true)
            return
        end
    end
    status.info("No commit matches '" .. filterText .. "'.")
end

--- Refresh from a new snapshot.
-- @param state  repository snapshot
function graph.refresh(state)
    if frame.graphMode() and not state.open then
        graph.hide()
        return
    end

    graph.reload(false)
end

--- Wire the panel.
function graph.init()
    placeholder.bind("GraphFilterEdit", "GraphFilterPlaceholder")
    gitgud.setChecked("GraphRemotesCheck", settings.get("graphRemotes", true))
    gitgud.setChecked("GraphTagsCheck", settings.get("graphTags", true))

    gitgud.linkScroll("GraphList", "GraphAuthorList")
    gitgud.linkScroll("GraphList", "GraphDateList")
    gitgud.linkScroll("GraphAuthorList", "GraphDateList")

    for _, list in ipairs(LISTS) do
        gitgud.on(list .. ".selected", function(value)
            local row = tonumber(value)
            if row and row >= 0 then
                activate(row + 1)
            end
        end)

        gitgud.on(list .. ".rightClicked", function(value)
            local x, y, row = menu.parseClick(value)
            local commit = row and rows[row]
            if commit and not commit.wip then
                activate(row)
                menu.popup(require("views.history").commitMenu(commit), x, y)
            end
        end)

        gitgud.on(list .. ".doubleClicked", function(value)
            local row = tonumber(value)
            local commit = row and rows[row + 1]
            if not commit or commit.wip then
                return
            end
            for _, label in ipairs(labelsByOid[commit.oid] or {}) do
                if label.kind == "branch" and label.name ~= repo.state().branch then
                    require("views.branches").checkoutByName(label.name)
                    return
                end
            end
        end)
    end

    gitgud.on("GraphFilterEdit.changed", function(value)
        filterText = text.trim(value)
        renderLists()
        local i = selectedOid and rowOf(selectedOid)
        if i then
            selectRow(i, false)
        end
    end)
    gitgud.on("GraphFilterEdit.accepted", findNext)

    gitgud.on("GraphRemotesCheck.toggled", function(value)
        settings.set("graphRemotes", value == "1")
        graph.reload(true)
    end)
    gitgud.on("GraphTagsCheck.toggled", function(value)
        settings.set("graphTags", value == "1")
        graph.reload(true)
    end)

    gitgud.on("GraphMoreButton.clicked", function()
        limit = limit + PAGE
        graph.reload(true)
    end)

    gitgud.on("GraphCloseButton.clicked", graph.hide)

    gitgud.on("key", function(combo)
        if not frame.graphMode() or require("ui.dialog").isOpen() or gitgud.textInputFocused() then
            return
        end
        if combo == "down" then
            moveSelection(1)
        elseif combo == "up" then
            moveSelection(-1)
        elseif combo == "pagedown" then
            moveSelection(12)
        elseif combo == "pageup" then
            moveSelection(-12)
        end
    end)

    app.subscribe("frame.graphChanged", function(on)
        gitgud.setProperty("GraphButtonLabel", "NormalTextColour", on and C.cyan or C.text2)
        gitgud.setProperty("GraphButtonIcon", "IconColour", on and C.cyan or "FFFFFFFF")
        if on then
            loadedKey = nil
            graph.reload(true)
        else
            app.publish("tab.changed", sidebar.tab())
        end
    end)

    app.subscribe("diff.optionsChanged", function()
        if frame.graphMode() and selectedOid then
            local i = rowOf(selectedOid)
            if i then
                activate(i)
            end
        end
    end)
end

return graph
