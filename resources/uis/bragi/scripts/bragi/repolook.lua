--- bragi/repolook.lua: the Repository view's content in design D: the
-- Changes and History tabs (layouts/sidebar/changes.xml, history.xml), the
-- commit and diff headers (layouts/content/commit-header.xml,
-- diff-header.xml), and the branch panel (layouts/main/navigator.xml).
--
-- The GitGud UI's views still run them; this module gives them the
-- design's rows and sizes through their setLook hooks and wires what the
-- design adds:
--
--   Changes   44px rows: the include box, the path in mono with its folder
--             dimmed, the kind of change at the right ("Modified" ...);
--             "2 of 4 files staged" over them; "Commit 2 files to main"
--   History   two-line rows: a graph line with a dot per commit (filled for
--             HEAD), the summary with its branch and tag labels, then
--             author, age and SHA
--   Commit    the header's Revert and "Ask Bragi about this commit"
--   Diff      the display menu's button names the mode ("Split"), and
--             "Edited by Bragi" marks a file the open session changed
--   Ask Bragi to write the description / about this commit: drafts a
--             request in the Agent view's prompt, as the Wiki's "Ask Bragi
--             to update" does
--
-- Public API: repolook.askForDescription(), repolook.askAboutCommit(commit),
-- repolook.changesRow(file, inclusion), repolook.historyRow(commit, row, rows)

local C = require("core.palette")
local app = require("core.app")
local changes = require("views.changes")
local commitview = require("views.commitview")
local content = require("views.content")
local diff = require("views.diff")
local history = require("views.history")
local navigator = require("views.navigator")
local repo = require("core.repo")
local rows = require("bragi.rows")
local shell = require("bragi.shell")
local sidebar = require("views.sidebar")
local sprites = require("core.sprites")
local text = require("core.text")

local repolook = { name = "bragi.repolook" }

-- Changes rows. Keep the sizes in step with layouts/sidebar/changes.xml.
local ROW = 44
local LIST_TOP = 98
local COMMIT_BOX = 310
local INFO_ROW = 36
local ROW_INSET = 6           -- the list draws rows this far in
local BOX_LEFT = 3            -- after the row-height spacer, to the box
local BOX_GAP = 8             -- box to path
local KIND_GAP = 12           -- least room between the path and its kind
local RIGHT_PAD = 10          -- kind to the row's right edge
local SCROLLBAR = 14

-- History rows.
local GRAPH = 12              -- graph column width
local DOT = 10
local DOT_TOP = 16            -- the dot's top inside the first line
local LINE1 = 30              -- summary line height (text sits at its bottom)
local LINE2 = 31              -- author line height (text 4px below its top)
local LABEL = 18              -- a branch or tag label's height

-- The branch panel's rows.
local NAV_ROW = 30
local NAV_SECTION = 32

-- The commit header (layouts/content/commit-header.xml).
local HEADER_PAD = 24
local BUTTON_GAP = 10

local KINDS = {
    M = "Modified", A = "Added", ["?"] = "Added", D = "Deleted", R = "Renamed", U = "Conflict",
}
local KIND_COLOURS = {
    Modified = C.accentText, Added = C.add, Deleted = C.warn, Renamed = C.link, Conflict = C.err,
}

local monoWidth = 7.8         -- px per Bragi-Mono-13 character (measured at init)
local mono11Width = 7         -- px per Bragi-Mono-11 character (measured at init)
local kindWidths = {}         -- kind -> px in Bragi-Caps
local listWidth = 0           -- ChangesList's width the rows were drawn for
local historyWidth = 0        -- HistoryList's
local historyRows = 0         -- rows in HistoryList

--- A transparent gap of `w` pixels.
local function gap(w)
    return "[image-size='w:" .. math.max(0, math.floor(w + 0.5)) .. " h:1'][image='Gitgud-Images/Spacer']"
end

--- Fit a path into `chars` characters: the folder loses its front first,
-- then the name its end.
-- @return dir, name
local function fitPath(path, chars)
    local name = text.basename(path)
    local dir = text.dirname(path)
    dir = dir ~= "" and (dir .. "/") or ""

    if rows.length(dir) + rows.length(name) <= chars then
        return dir, name
    end
    local room = chars - rows.length(name)
    if room >= 4 then
        return "…" .. rows.tail(dir, room - 1), name
    end
    if chars < 2 then
        return "", ""
    end
    return "", rows.head(name, chars - 1) .. "…"
end

--- One Changes row: box, path, kind at the right.
-- @param file       status row
-- @param inclusion  "all" | "some" | "none"
-- @return markup
function repolook.changesRow(file, inclusion)
    local kind = KINDS[file.code] or "Modified"
    local kindWidth = kindWidths[kind] or 60
    local _, _, _, listHeight = gitgud.getRect("ChangesList")
    local overflow = listHeight and #repo.state().files * ROW > listHeight - 4
    local width = listWidth - ROW_INSET * 2 - (overflow and SCROLLBAR or 0)
    local before = 1 + BOX_LEFT + 14 + BOX_GAP
    local room = width - before - KIND_GAP - kindWidth - RIGHT_PAD
    local dir, name = fitPath(file.path, math.floor(room / monoWidth))
    local used = (rows.length(dir) + rows.length(name)) * monoWidth

    return text.rowHeight(ROW) .. gap(BOX_LEFT) .. sprites.includeBox(inclusion, 14, 14) .. gap(BOX_GAP)
        .. "[font='Bragi-Mono-13']" .. text.colour(C.sub, dir) .. text.colour(C.text, name)
        .. gap(room - used + KIND_GAP)
        .. "[font='Bragi-Caps']" .. text.colour(KIND_COLOURS[kind] or C.sub, kind)
end

--- An image in the row: tinted, padded (left padding may be negative to
-- draw over what's before it; text can't take left padding), aligned to
-- the line's top or bottom.
local function picture(image, colour, w, h, pad, align)
    return "[vert-formatting='" .. align .. "'][colour='" .. colour .. "'][padding='l:" .. pad[1] .. " t:"
        .. pad[2] .. " r:" .. pad[3] .. " b:" .. pad[4] .. "'][image-size='w:" .. w .. " h:" .. h
        .. "'][image='" .. image .. "']"
end

local PLAIN = "[padding='l:0 t:0 r:0 b:0'][reset='colour']"

--- Move the pen back `w` pixels.
local function back(w)
    return "[padding='l:" .. -(w + 1) .. " t:0 r:0 b:0'][image-size='w:1 h:1'][image='Gitgud-Images/Spacer']" .. PLAIN
end

--- A label's width in the row: the gap before it and its outline.
local function labelWidth(label)
    return 6 + math.ceil(rows.length(label.name) * mono11Width) + 12
end

--- The branch and tag names on a commit, as outlined labels at the
-- bottom of a line whose text is bottom-aligned.
local function refLabels(labels)
    local out = ""
    for _, label in ipairs(labels or {}) do
        local w = math.ceil(rows.length(label.name) * mono11Width)
        out = out .. gap(6)
            .. picture("Bragi-Icons/PillLeft", C.accent, 5, LABEL, { 0, 0, 0, 1 }, "BottomAligned")
            .. picture("Bragi-Icons/PillMiddle", C.accent, w + 2, LABEL, { 0, 0, 0, 1 }, "BottomAligned")
            .. picture("Bragi-Icons/PillRight", C.accent, 5, LABEL, { 0, 0, 0, 1 }, "BottomAligned")
            .. PLAIN .. back(w + 6)
            .. "[vert-formatting='BottomAligned'][padding='l:0 t:0 r:0 b:5'][font='Bragi-Mono-11']"
            .. text.colour(C.accentText, label.name) .. PLAIN .. gap(6)
    end
    return out
end

local labelsByOid = nil

--- Branch and tag labels by commit, read once per history load.
local function labelsFor(oid, row)
    if row == 1 or not labelsByOid then
        labelsByOid = {}
        for _, label in ipairs(gitgud.refLabels()) do
            labelsByOid[label.oid] = labelsByOid[label.oid] or {}
            table.insert(labelsByOid[label.oid], label)
        end
    end
    return labelsByOid[oid]
end

--- One History row: graph, summary and labels, then author, age, SHA.
--
-- The graph column (GRAPH wide) is three pictures on the first line, the
-- later ones stepping back over it with negative padding: the stem above
-- the dot (from the top), the stem below it and the dot (from the bottom);
-- and one stem the height of the second line.
--
-- Everything fits the list's width (a row wider than the list would widen
-- its selection past the edge): labels get what the summary leaves (at
-- least 40% of the line), the rest are counted ("+2"), and the summary is
-- cut with "…".
-- @param commit  history row
-- @param row     1-based row
-- @param count   number of rows
-- @return markup
function repolook.historyRow(commit, row, count)
    historyRows = count or historyRows
    local _, _, listW, listH = gitgud.getRect("HistoryList")
    local overflow = listH and (count or 0) * (LINE1 + LINE2) > listH - 4
    local room = (listW or 300) - ROW_INSET * 2 - (overflow and SCROLLBAR or 0) - 4 - GRAPH - 12 - RIGHT_PAD

    local all = labelsFor(commit.oid, row) or {}
    local summaryW = rows.measure("[font='Bragi-14-Bold']" .. text.escape(commit.summary))
    local budget = math.max(room - summaryW, room * 0.4)
    local total = 0
    for _, label in ipairs(all) do
        total = total + labelWidth(label)
    end
    local labels = {}
    local labelsW = 0
    for _, label in ipairs(all) do
        local w = labelWidth(label)
        -- When some won't fit, keep room for the "+2" that counts them.
        local reserve = total > budget and 40 or 0
        if labelsW + w + reserve > budget then
            break
        end
        labels[#labels + 1] = label
        labelsW = labelsW + w
    end
    local extra = ""
    if #labels < #all then
        extra = gap(6) .. "[vert-formatting='BottomAligned'][padding='l:0 t:0 r:0 b:5'][font='Bragi-Mono-11']"
            .. text.colour(C.sub, "+" .. (#all - #labels)) .. PLAIN
        labelsW = labelsW + 6 + math.ceil((#tostring(#all - #labels) + 1) * mono11Width)
    end
    local summary = rows.fitText("Bragi-14-Bold", commit.summary, room - labelsW)
    local meta = rows.fitText("Bragi-12", commit.author .. " · " .. text.ago(commit.time) .. " · ",
        room - math.ceil(#commit.shortOid * mono11Width))

    local isHead = commit.oid == repo.state().headOid
    local merge = #(commit.parents or {}) > 1
    local root = #(commit.parents or {}) == 0
    local stem = "Bragi-Shapes/Solid"
    local x = (GRAPH - 2) / 2
    local dotX = (GRAPH - DOT) / 2
    local below = LINE1 - DOT_TOP - DOT
    local tall = "[vert-formatting='TopAligned'][image-size='w:4 h:%d'][image='Gitgud-Images/Spacer']"

    local graph1 = picture(stem, row == 1 and C.transparent or C.border, 2, DOT_TOP, { x, 0, x, 0 }, "TopAligned")
        .. picture(stem, root and C.transparent or C.border, 2, below, { x - GRAPH, 0, x, 0 }, "BottomAligned")
        .. picture(isHead and "Bragi-Icons/GraphDot" or "Bragi-Icons/GraphRing", merge and C.link or C.accent,
            DOT, DOT, { dotX - GRAPH, 0, dotX, below }, "BottomAligned")
    local graph2 = picture(stem, root and C.transparent or C.border, 2, LINE2, { x, 0, x, 0 }, "TopAligned")

    return tall:format(LINE1) .. graph1 .. PLAIN .. gap(12)
        .. "[vert-formatting='BottomAligned'][font='Bragi-14-Bold']" .. text.colour(C.text, summary)
        .. refLabels(labels) .. extra .. "[font='']\n"
        .. tall:format(1) .. graph2 .. PLAIN .. gap(12)
        .. "[vert-formatting='TopAligned'][padding='l:0 t:4 r:0 b:0'][font='Bragi-12']"
        .. text.colour(C.sub, meta) .. "[font='Bragi-Mono-11']" .. text.colour(C.sub, commit.shortOid)
end

--- The commit header's metadata line: author, date, SHA in mono, the
-- file count, and the line counts in their colours.
local function commitMeta(commit, files, added, removed)
    local dot = text.colour(C.sub, "  ·  ")
    return text.colour(C.sub, commit.author .. "  ·  " .. os.date("%Y-%m-%d %H:%M", commit.time)) .. dot
        .. "[font='Bragi-Mono-11']" .. text.colour(C.sub, commit.shortOid) .. "[font='']" .. dot
        .. text.colour(C.sub, text.plural(files, "file")) .. dot
        .. "[font='Bragi-12-Bold']" .. text.colour(C.add, "+" .. added) .. " "
        .. text.colour(C.warn, "−" .. removed) .. "[font='']"
end

--- Put a draft into the Agent view's prompt, for the user to finish and
-- send; the caret goes to its end.
local function draftForAgent(draft)
    shell.show("agent")
    require("bragi.agent").setPrompt(draft)
    gitgud.focus("AgentPromptEdit")
    gitgud.setProperty("AgentPromptEdit", "CaretIndex", tostring(rows.length(draft)))
end

--- Ask the agent for the commit's description.
function repolook.askForDescription()
    local state = repo.state()
    local staged = 0
    for _, file in ipairs(state.files) do
        if file.staged then
            staged = staged + 1
        end
    end
    local what = (staged > 0 and "the staged changes" or "the uncommitted changes") .. " in " .. state.name
    local summary = text.trim(gitgud.getText("SummaryEdit") or "")
    if summary ~= "" then
        draftForAgent("Write the description for my commit \"" .. summary .. "\" from " .. what .. ": ")
    else
        draftForAgent("Write a commit message (a summary line and a description) for " .. what .. ": ")
    end
end

--- Ask the agent about a commit.
-- @param commit  history row
function repolook.askAboutCommit(commit)
    draftForAgent("About commit " .. commit.shortOid .. " \"" .. commit.summary .. "\" in "
        .. repo.state().name .. ": ")
end

--- Size the commit header's buttons to their labels, right-aligned, and
-- give the title the room that's left.
local function layoutCommitButtons()
    local right = -HEADER_PAD
    for i = 2, 1, -1 do
        local button = "CommitAction" .. i
        if gitgud.getProperty(button, "Visible") == "true" then
            local font = gitgud.getProperty(button, "Font") or "Bragi-13"
            local w = math.ceil(rows.measure("[font='" .. font .. "']" .. (gitgud.getText(button) or ""))) + 28
            gitgud.setProperty(button, "Area",
                "{{1," .. (right - w) .. "},{0,18},{1," .. right .. "},{0,54}}")
            right = right - w - BUTTON_GAP
        end
    end
    gitgud.setProperty("CommitSummaryLabel", "Area",
        "{{0," .. HEADER_PAD .. "},{0,18},{1," .. (right - 6) .. "},{0,54}}")
end

--- The diff header: the display menu's button names the mode, and the
-- "Edited by Bragi" badge shows for a working file the session changed.
local function paintDiffHeader()
    local mode = diff.mode() == "unified" and "Unified" or "Split"
    gitgud.setText("DiffViewButton", mode .. "  [colour='" .. C.sub
        .. "'][image-size='w:10 h:7'][vert-formatting='CentreAligned'][image='Gitgud-Images/Chevron']")
    local path = changes.selectedPath()
    local edited = content.arrangement() == "plain" and sidebar.tab() == "changes" and path ~= nil
        and require("bragi.review").edited(path)
    gitgud.setVisible("BragiEditedBadge", edited == true)
end

--- Measure the fonts the rows are laid out with.
local function measureFonts()
    local ten = rows.measure("[font='Bragi-Mono-13']0123456789")
    if ten > 0 then
        monoWidth = ten / 10
    end
    ten = rows.measure("[font='Bragi-Mono-11']0123456789")
    if ten > 0 then
        mono11Width = ten / 10
    end
    for _, kind in pairs(KINDS) do
        kindWidths[kind] = math.ceil(rows.measure("[font='Bragi-Caps']" .. kind))
    end
end

--- Give the lists the rounded selected row for their widths.
local function selectionRows()
    rows.select("ChangesList", ROW, #repo.state().files)
    rows.select("HistoryList", LINE1 + LINE2, historyRows)
    rows.select("NavList", NAV_ROW, 0)
    rows.select("CommitFilesList", 24, 0)
end

local fitTimer = nil

--- Redraw the rows when a list's width changed (the window or the
-- sidebar was resized), once the resizing pauses.
local function fitRows()
    if fitTimer then
        gitgud.cancelTimer(fitTimer)
    end
    fitTimer = gitgud.after(120, function()
        fitTimer = nil
        selectionRows()
        local _, _, w = gitgud.getRect("ChangesList")
        if w and math.abs(w - listWidth) >= 1 then
            listWidth = w
            changes.refresh(repo.state())
        end
        local _, _, hw = gitgud.getRect("HistoryList")
        if hw and math.abs(hw - historyWidth) >= 1 then
            historyWidth = hw
            history.setLook({})
            if sidebar.tab() == "history" then
                history.reload(true)
            end
        end
    end)
end

function repolook.init()
    measureFonts()
    listWidth = select(3, gitgud.getRect("ChangesList")) or 300
    historyWidth = select(3, gitgud.getRect("HistoryList")) or 300

    gitgud.setProperty("Sidebar", "PanelColour", C.bg)

    changes.setLook({
        rowHeight = ROW,
        checkColumn = ROW_INSET + 1 + BOX_LEFT + 14 + BOX_GAP / 2,
        listTop = LIST_TOP,
        commitBoxHeight = COMMIT_BOX,
        infoRowHeight = INFO_ROW,
        rowText = repolook.changesRow,
        includeAllText = function(total, staged)
            if total == 0 then
                return "No changed files"
            end
            return staged .. " of " .. text.plural(total, "file") .. " staged"
        end,
        commitLabel = function(branch, staged)
            if staged == 0 then
                return "Commit to " .. branch
            end
            return "Commit " .. text.plural(staged, "file") .. " to " .. branch
        end,
    })
    history.setLook({
        listTop = 104,
        compareTop = 140,
        rowText = repolook.historyRow,
        commitMeta = commitMeta,
        commitActions = function(commit)
            return {
                { label = "Revert", action = function()
                    history.revert(commit)
                end },
                { label = "Ask Bragi about this commit", action = function()
                    repolook.askAboutCommit(commit)
                end },
            }
        end,
    })
    navigator.setLook({ rowHeight = NAV_ROW, sectionHeight = NAV_SECTION, sectionFont = "Bragi-Caps" })
    commitview.setLook({ left = HEADER_PAD, metaTop = 84, metaTopCompact = 56 })
    content.setLook({ commitHeader = 124, commitHeaderCompact = 96, diffHeader = 52 })

    gitgud.on("BragiAskCommitButton.clicked", repolook.askForDescription)
    gitgud.on("BragiEditedBadge.clicked", function()
        shell.show("agent")
    end)
    app.subscribe("content.title", function()
        layoutCommitButtons()
        paintDiffHeader()
    end)
    app.subscribe("diff.optionsChanged", paintDiffHeader)
    app.subscribe("diff.modeChanged", paintDiffHeader)
    app.subscribe("frame.changed", fitRows)
    app.subscribe("bragi.view", function(view)
        if view == "repo" then
            fitRows()
            paintDiffHeader()
        end
    end)
    paintDiffHeader()
    selectionRows()
end

function repolook.refresh()
    gitgud.setEnabled("BragiAskCommitButton", repo.state().open and #repo.state().files > 0)
    selectionRows()
end

return repolook
