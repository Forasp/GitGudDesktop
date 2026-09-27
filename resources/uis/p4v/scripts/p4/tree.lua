--- p4/tree.lua — expandable trees in a single list widget (the depot tree,
-- pending changelists).
--
-- Nodes are tables; children load lazily through spec.children:
--
--     tree.create("DepotTree", {
--         children = function(node) return { ... } end,  -- lazy load
--         onSelect = function(nodes) end,
--         onActivate = function(node) end,       -- double-click a leaf
--         onContext = function(nodes, x, y) end,
--         onDrag = function(fromNode, toNode) end,
--         onToggle = function(node) end,         -- opened or closed (node.expanded)
--     })
--     tree.setRoots("DepotTree", { { id = "//repo", label = "repo", icon = "Depot",
--                                    hasChildren = true, expanded = true } })
--
-- Node fields: id (unique), label (plain text) or markup, icon (P4-Icons
-- name), hasChildren, expanded, children (filled by spec.children), colour,
-- suffix (dim text after the label), data (anything).

local C = require("core.palette")
local icons = require("p4.icons")
local text = require("core.text")

local tree = {}

local ROW_HEIGHT = 20
local INDENT = 16
local LIST_PADDING = 6   -- the list's left inset before a row's first pixel

local trees = {}   -- list name -> state

--- Load a node's children if it has none yet.
-- @param state  tree state
-- @param node   node
local function ensureChildren(state, node)
    if node.children == nil and node.hasChildren and state.children then
        node.children = state.children(node) or {}
        for _, child in ipairs(node.children) do
            child.parent = node
        end
    end
end

--- Walk the visible nodes in order.
-- @param state  tree state
-- @return array of { node, depth }
local function flatten(state)
    local out = {}
    local function walk(nodes, depth)
        for _, node in ipairs(nodes) do
            out[#out + 1] = { node = node, depth = depth }
            if node.expanded and node.hasChildren then
                ensureChildren(state, node)
                walk(node.children or {}, depth + 1)
            end
        end
    end
    walk(state.roots, 0)

    return out
end

--- One row's markup. The invisible row number at the end keeps rows
-- unique: CEGUI treats rows with the same text as the same item when it
-- draws the selection.
-- @param entry  { node, depth }
-- @param index  row position
-- @return markup
local function rowMarkup(entry, index)
    local node = entry.node
    local arrow
    if node.hasChildren then
        arrow = icons.inline(node.expanded and "TreeOpen" or "TreeClosed")
    else
        arrow = icons.space(16)
    end
    local label = node.markup or text.colour(node.colour or C.text, node.label or "")
    if node.suffix and node.suffix ~= "" then
        label = label .. "  " .. text.colour(C.dim, node.suffix)
    end
    local icon = node.icon and (icons.inline(node.icon) .. " ") or ""

    return text.rowHeight(ROW_HEIGHT) .. icons.space(entry.depth * INDENT) .. arrow .. icon .. label
        .. "[colour='00000000'] " .. index
end

--- Rebuild the list, keeping the selection (by id) and scroll.
-- @param state  tree state
local function render(state)
    local selectedIds = {}
    for _, node in ipairs(tree.selected(state.name)) do
        selectedIds[node.id] = true
    end

    state.visible = flatten(state)
    local items = {}
    local keep = {}
    for i, entry in ipairs(state.visible) do
        items[i] = rowMarkup(entry, i)
        if selectedIds[entry.node.id] then
            keep[#keep + 1] = i
        end
    end
    gitgud.setList(state.name, items)
    gitgud.selectListItems(state.name, keep)
end

--- The visible row of a node, or nil.
-- @param state  tree state
-- @param id     node id
-- @return row index
local function rowOf(state, id)
    for i, entry in ipairs(state.visible) do
        if entry.node.id == id then
            return i
        end
    end

    return nil
end

--- Flip a node open or closed.
-- @param state  tree state
-- @param node   node
local function toggle(state, node)
    if not node.hasChildren then
        return
    end
    node.expanded = not node.expanded
    if state.onToggle then
        state.onToggle(node)
    end
    render(state)
end

--- Create a tree on an existing list widget.
-- @param name  list widget
-- @param spec  see the header
function tree.create(name, spec)
    local state = {
        name = name,
        roots = {},
        visible = {},
        children = spec.children,
        onSelect = spec.onSelect,
        onActivate = spec.onActivate,
        onContext = spec.onContext,
        onDrag = spec.onDrag,
        onToggle = spec.onToggle,
    }
    trees[name] = state
    gitgud.setProperty(name, "MultiSelect", spec.multi and "true" or "false")
    gitgud.setProperty(name, "HorzScrollbarDisplayMode", "WhenNeeded")

    gitgud.on(name .. ".clicked", function(value)
        local x, _, row = require("ui.menu").parseClick(value)
        local entry = row and state.visible[row]
        if not entry then
            return
        end
        -- The expand arrow's column.
        local left = gitgud.getRect(name) or 0
        local arrowX = left + LIST_PADDING + entry.depth * INDENT
        if entry.node.hasChildren and x >= arrowX - 2 and x <= arrowX + 18 then
            toggle(state, entry.node)
        end
    end)

    gitgud.on(name .. ".selected", function()
        if state.onSelect then
            state.onSelect(tree.selected(name))
        end
    end)

    gitgud.on(name .. ".doubleClicked", function(value)
        local row = tonumber(value)
        local entry = row and state.visible[row + 1]
        if not entry then
            return
        end
        if entry.node.hasChildren and not entry.node.activatable then
            toggle(state, entry.node)
        elseif state.onActivate then
            state.onActivate(entry.node)
        end
    end)

    gitgud.on(name .. ".rightClicked", function(value)
        local x, y, row = require("ui.menu").parseClick(value)
        local nodes = tree.selected(name)
        local entry = row and state.visible[row]
        if entry then
            local already = false
            for _, node in ipairs(nodes) do
                already = already or node == entry.node
            end
            if not already then
                gitgud.selectListItems(name, { row })
                nodes = { entry.node }
                if state.onSelect then
                    state.onSelect(nodes)
                end
            end
        end
        if state.onContext then
            state.onContext(nodes, x, y)
        end
    end)

    gitgud.on(name .. ".dragged", function(value)
        local from, to = value:match("^(%d+),(%d+)$")
        local a = from and state.visible[tonumber(from) + 1]
        local b = to and state.visible[tonumber(to) + 1]
        if a and b and state.onDrag then
            state.onDrag(a.node, b.node)
        end
    end)
end

--- Replace the root nodes and redraw.
-- @param name   list widget
-- @param roots  array of nodes
function tree.setRoots(name, roots)
    local state = trees[name]
    state.roots = roots
    render(state)
end

--- Redraw (after changing nodes in place).
-- @param name  list widget
function tree.refresh(name)
    render(trees[name])
end

--- The selected nodes, in row order.
-- @param name  list widget
-- @return array of nodes
function tree.selected(name)
    local state = trees[name]
    if not state then
        return {}
    end

    local out = {}
    for _, index in ipairs(gitgud.getSelectedIndices(name)) do
        local entry = state.visible[index]
        if entry then
            out[#out + 1] = entry.node
        end
    end

    return out
end

--- Find a loaded node by id.
-- @param name  list widget
-- @param id    node id
-- @return node or nil
function tree.find(name, id)
    local state = trees[name]
    local found = nil
    local function walk(nodes)
        for _, node in ipairs(nodes or {}) do
            if found then
                return
            end
            if node.id == id then
                found = node
                return
            end
            walk(node.children)
        end
    end
    walk(state and state.roots)

    return found
end

--- Select a node (expanding its ancestors), scroll to it, and raise onSelect.
-- @param name    list widget
-- @param id      node id
-- @param quiet   true: don't raise onSelect
-- @return true when found
function tree.select(name, id, quiet)
    local state = trees[name]
    local node = tree.find(name, id)
    if not node then
        return false
    end

    local parent = node.parent
    while parent do
        parent.expanded = true
        parent = parent.parent
    end
    render(state)
    local row = rowOf(state, id)
    gitgud.selectListItem(name, row, true)
    if not quiet and state.onSelect then
        state.onSelect({ node })
    end

    return true
end

--- Expand a node by id (loading its children) — for walking to a path.
-- @param name  list widget
-- @param id    node id
-- @return the node or nil
function tree.expand(name, id)
    local state = trees[name]
    local node = tree.find(name, id)
    if node and node.hasChildren then
        node.expanded = true
        ensureChildren(state, node)
    end

    return node
end

--- Collapse every node.
-- @param name  list widget
function tree.collapseAll(name)
    local state = trees[name]
    local function walk(nodes, depth)
        for _, node in ipairs(nodes or {}) do
            if depth > 0 then
                node.expanded = false
            end
            walk(node.children, depth + 1)
        end
    end
    walk(state.roots, 0)
    render(state)
end

--- Visible nodes (for keyboard helpers and tests).
-- @param name  list widget
-- @return array of { node, depth }
function tree.visible(name)
    local state = trees[name]
    return state and state.visible or {}
end

return tree
