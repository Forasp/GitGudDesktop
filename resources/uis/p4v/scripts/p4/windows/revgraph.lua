--- p4/windows/revgraph.lua — the Revision Graph window, P4V's way of
-- seeing a file's history across branches: a row per branch, a box per
-- revision (rounded = added, pointed = merged in, slanted = branched,
-- grey = deleted), arrows where branches start and merge.
--
-- The picture is drawn by the engine (gitgud.revisionGraph); this module
-- lays labels and a clickable button over every box, fills the branch
-- filter, the Details / Integrations tabs, and the navigator, and handles
-- zoom (Ctrl+= / Ctrl+-). Click a box to select it; double-click to diff it
-- against its previous revision.
--
--     revgraph.open(path)

local C = require("core.palette")
local geometry = require("ui.geometry")
local icons = require("p4.icons")
local selection = require("p4.selection")
local tabs = require("p4.tabs")
local text = require("core.text")
local util = require("p4.util")
local windows = require("p4.windows")

local revgraph = {}

local ZOOMS = { 0.5, 0.65, 0.8, 1.0, 1.25, 1.5, 2.0 }
local BASE = { columnWidth = 64, rowHeight = 84, nodeWidth = 50, nodeHeight = 26, nodeTop = 26 }

local open = {}   -- id -> state

--- Colours for the engine, from the palette.
local function colours()
    return C.graph
end

--- Destroy the overlay widgets of the previous picture.
-- @param state  window state
local function clearOverlays(state)
    for _, name in ipairs(state.overlays or {}) do
        gitgud.destroyWindow(name)
    end
    state.overlays = {}
end

--- Create one overlay widget inside the canvas.
local function overlay(state, kind, name, area)
    local full = state.id .. ":" .. name
    gitgud.createWindow(kind, full, state.id .. ":Canvas")
    gitgud.setProperty(full, "Area", area)
    state.overlays[#state.overlays + 1] = full

    return full
end

--- The Details text of a node.
-- @param state  window state
-- @param node   graph node
-- @return text
local function detailsOf(state, node)
    local row = state.graph.rows[node.row]
    local names = { A = "add", M = "edit", D = "delete", I = "integrate (merge)" }
    return "Revision:   " .. selection.depotPath(state.path) .. "#" .. node.revision
        .. "   on " .. (row.name ~= "" and row.name or "(merged history)") .. "\n"
        .. "Change:     " .. node.oid .. "\n"
        .. "Action:     " .. (names[node.action] or node.action) .. "\n"
        .. "Date:       " .. util.dateTime(node.time) .. "\n"
        .. "User:       " .. node.author .. " <" .. node.email .. ">\n\n"
        .. node.message
end

--- The Integrations text: where this revision came from and went.
-- @param state  window state
-- @param index  node index
-- @return text
local function integrationsOf(state, index)
    local graph = state.graph
    local sources, targets = {}, {}
    local function label(i)
        local n = graph.nodes[i]
        local row = graph.rows[n.row]
        return (row.name ~= "" and row.name or "(merged)") .. "#" .. n.revision .. "  " .. util.change(n.oid)
            .. "  " .. util.summary(n.summary)
    end
    for _, edge in ipairs(graph.edges) do
        if edge.to == index then
            sources[#sources + 1] = "   " .. label(edge.from) .. (edge.merge and "   (merged from)" or "   (previous)")
        elseif edge.from == index then
            targets[#targets + 1] = "   " .. label(edge.to) .. (edge.merge and "   (merged into)" or "   (next)")
        end
    end

    return "Sources (contributing content to this revision):\n"
        .. (#sources > 0 and table.concat(sources, "\n") or "   (none — the file was added here)") .. "\n\n"
        .. "Targets (receiving content from this revision):\n"
        .. (#targets > 0 and table.concat(targets, "\n") or "   (none yet)")
end

--- Fill the bottom pane for the selection.
-- @param state  window state
local function showSelected(state)
    local node = state.selected and state.graph.nodes[state.selected]
    if not node then
        gitgud.setText(state.id .. ":DetailsText", "Click a revision.")
        return
    end
    if state.bottomTab == "integrations" then
        gitgud.setText(state.id .. ":DetailsText", integrationsOf(state, state.selected))
    else
        gitgud.setText(state.id .. ":DetailsText", detailsOf(state, node))
    end
end

--- Draw the graph (engine picture + overlays).
-- @param state        window state
-- @param keepOverlays true when only the selection changed
local function render(state, keepOverlays)
    local id = state.id
    local zoom = ZOOMS[state.zoom]
    local exclude = {}
    for name, hidden in pairs(state.hidden) do
        if hidden then
            exclude[#exclude + 1] = name
        end
    end
    local graph, err = gitgud.revisionGraph({
        path = state.path,
        remotes = state.remotes,
        exclude = exclude,
        max = 300,
        image = "P4RevGraph/" .. id,
        selected = state.selected,
        columnWidth = math.floor(BASE.columnWidth * zoom),
        rowHeight = math.floor(BASE.rowHeight * zoom),
        nodeWidth = math.floor(BASE.nodeWidth * zoom),
        nodeHeight = math.max(14, math.floor(BASE.nodeHeight * zoom)),
        nodeTop = math.floor(BASE.nodeTop * zoom),
        colours = colours(),
    })
    if not graph then
        gitgud.setText(id .. ":DetailsText", "Couldn't draw the graph: " .. tostring(err))
        return
    end
    state.graph = graph

    if not keepOverlays then
        clearOverlays(state)
        state.picture = overlay(state, "Gitgud/Image", "Picture", geometry.rect(0, 0, graph.width, graph.height))
        gitgud.setProperty(state.picture, "Image", graph.image)
        gitgud.setProperty(state.picture, "CursorPassThroughEnabled", "true")

        local font = zoom >= 1 and "Gitgud-System" or "Gitgud-System-Small"
        for r, row in ipairs(graph.rows) do
            local label = overlay(state, "Gitgud/Label", "Row" .. r, geometry.rect(8, row.y + 3, 600, 18))
            gitgud.setProperty(label, "Font", font)
            gitgud.setProperty(label, "CursorPassThroughEnabled", "true")
            local name = row.name ~= "" and row.name or "(history from merged or deleted branches)"
            gitgud.setText(label, text.colour(row.head and C.text or C.text2,
                selection.depotPath(state.path) .. "   ") .. text.colour(row.head and C.yellow or C.dim, name
                .. (row.head and "   (your workspace)" or "")))
        end

        for n, node in ipairs(graph.nodes) do
            local button = overlay(state, "Gitgud/Button", "Node" .. n, geometry.rect(node.x, node.y, node.w, node.h))
            gitgud.setText(button, text.colour(C.deep, tostring(node.revision)))
            gitgud.setProperty(button, "HorzFormatting", "LeftAligned")
            gitgud.setProperty(button, "Font", font)
            gitgud.setProperty(button, "NormalFillColour", C.transparent)
            gitgud.setProperty(button, "HoverFillColour", "30ECF1C1")
            gitgud.setProperty(button, "PushedFillColour", "50ECF1C1")
            gitgud.setProperty(button, "BorderColour", C.transparent)
            gitgud.setProperty(button, "TooltipText", "#" .. node.revision .. "  " .. util.change(node.oid) .. "  "
                .. node.author .. "  " .. util.date(node.time) .. "\n" .. util.summary(node.summary))
            local index = n
            gitgud.on(button .. ".clicked", function()
                state.selected = index
                render(state, true)
            end)
            gitgud.on(button .. ".doubleClicked", function()
                local target = graph.nodes[index]
                windows.diffRevisions(state.path, target.oid .. "^", state.path, target.oid)
            end)

            local change = overlay(state, "Gitgud/Label", "Change" .. n,
                geometry.rect(node.x - 6, node.y + node.h + 1, node.w + 12, 16))
            gitgud.setProperty(change, "Font", "Gitgud-System-Small")
            gitgud.setProperty(change, "HorzFormatting", "CentreAligned")
            gitgud.setProperty(change, "CursorPassThroughEnabled", "true")
            gitgud.setText(change, text.colour(C.dim, util.change(node.oid):sub(1, zoom >= 1 and 7 or 5)))
        end
    else
        gitgud.setProperty(state.picture, "Image", graph.image)
    end

    -- Navigator: the whole picture, fitted.
    local _, _, nw, nh = gitgud.getRect(id .. ":NavigatorPanel")
    if nw then
        local x, y, w, h = geometry.fit(graph.width, graph.height, nw - 12, nh - 36)
        gitgud.setProperty(id .. ":NavigatorImage", "Area", geometry.rect(6 + x, 30 + y, w, h))
        gitgud.setProperty(id .. ":NavigatorImage", "Image", graph.image)
    end

    gitgud.setText(id .. ":ZoomLabel", math.floor(zoom * 100 + 0.5) .. "%")
    showSelected(state)
end

--- Fill the branch filter.
-- @param state  window state
local function renderFilter(state)
    local rows = {}
    state.filterNames = {}
    for _, branch in ipairs(gitgud.branches() or {}) do
        if (state.remotes or not branch.isRemote) and not branch.name:match("/HEAD$") then
            state.filterNames[#state.filterNames + 1] = branch.name
            rows[#rows + 1] = text.rowHeight(20) .. icons.inline(state.hidden[branch.name] and "CheckOff" or "CheckOn")
                .. " " .. icons.inline(branch.isRemote and "RemoteBranch" or "Branch16") .. " "
                .. text.colour(C.text, branch.name)
        end
    end
    gitgud.setList(state.id .. ":FilterList", rows)
end

--- Scroll the canvas so the newest revisions (right) show.
local function scrollToLatest(state)
    gitgud.after(1, function()
        gitgud.setScroll(state.id .. ":Canvas", 1e9, "horizontal")
    end)
end

--- Open a Revision Graph window for a file.
-- @param path  file
-- @return window id
function revgraph.open(path)
    local id = windows.open("revgraph", "Revision Graph: " .. selection.depotPath(path), "windows/revgraph.xml", 1200, 800)
    if not id then
        return nil
    end
    local state = { id = id, path = path, zoom = 4, remotes = true, hidden = {}, overlays = {}, bottomTab = "details" }
    open[id] = state

    tabs.create(id .. ":BottomTabs", {
        { id = "details", label = "Details" },
        { id = "integrations", label = "Integrations" },
    }, function(tab)
        state.bottomTab = tab
        if state.graph then
            showSelected(state)
        end
    end)

    local function zoomBy(step)
        state.zoom = math.max(1, math.min(#ZOOMS, state.zoom + step))
        render(state)
    end
    gitgud.on(id .. ":ZoomInButton.clicked", function()
        zoomBy(1)
    end)
    gitgud.on(id .. ":ZoomOutButton.clicked", function()
        zoomBy(-1)
    end)
    gitgud.on(id .. ":RefreshButton.clicked", function()
        renderFilter(state)
        render(state)
    end)
    gitgud.on(id .. ":RemoteCheck.toggled", function(value)
        state.remotes = value == "1"
        renderFilter(state)
        render(state)
    end)
    gitgud.on(id .. ":FilterList.clicked", function(value)
        local _, _, row = require("ui.menu").parseClick(value)
        local name = row and state.filterNames[row]
        if name then
            state.hidden[name] = not state.hidden[name]
            state.selected = nil
            renderFilter(state)
            render(state)
        end
    end)

    local function selectedNode()
        return state.selected and state.graph and state.graph.nodes[state.selected]
    end
    gitgud.on(id .. ":DiffPrevButton.clicked", function()
        local node = selectedNode()
        if node then
            windows.diffRevisions(path, node.oid .. "^", path, node.oid)
        end
    end)
    gitgud.on(id .. ":MarkButton.clicked", function()
        local node = selectedNode()
        if node then
            state.marked = node
            gitgud.setText(id .. ":MarkButton", "Marked #" .. node.revision)
        end
    end)
    gitgud.on(id .. ":DiffMarkedButton.clicked", function()
        local node = selectedNode()
        if node and state.marked then
            local a, b = state.marked, node
            if a.time > b.time then
                a, b = b, a
            end
            windows.diffRevisions(path, a.oid, path, b.oid)
        end
    end)
    gitgud.on(id .. ":TimelapseButton.clicked", function()
        local node = selectedNode()
        require("p4.windows.timelapse").open(path, node and node.oid)
    end)
    gitgud.on(id .. ":GetButton.clicked", function()
        local node = selectedNode()
        if node then
            require("p4.actions").getRevision({ path }, node.oid)
        end
    end)

    windows.onKey(id, function(combo)
        if combo == "escape" then
            windows.close(id)
        elseif combo == "ctrl+=" or combo == "ctrl+shift+=" then
            zoomBy(1)
        elseif combo == "ctrl+-" then
            zoomBy(-1)
        elseif combo == "f5" then
            render(state)
        end
    end)
    windows.onClose(id, function()
        open[id] = nil
    end)

    renderFilter(state)
    render(state)
    -- Start on the newest revision of the workspace's branch.
    for n = #state.graph.nodes, 1, -1 do
        local node = state.graph.nodes[n]
        if state.graph.rows[node.row] and state.graph.rows[node.row].head then
            state.selected = n
            break
        end
    end
    if state.selected then
        render(state, true)
    end
    scrollToLatest(state)

    return id
end

--- An open window's state (tests).
function revgraph.state(id)
    return open[id]
end

return revgraph
