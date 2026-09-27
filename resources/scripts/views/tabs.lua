--- views/tabs.lua — several repositories open at once, as tabs.
--
-- The tab strip appears under the toolbar once two or more repositories are
-- open. Picking a repository from the Repositories dropdown switches the
-- current tab to it (as before); "Open in a new tab" (right-click in the
-- dropdown, the + button, worktrees and submodules in the branch tree)
-- adds one. Each tab remembers whether it was on Changes, History, or the
-- graph. Ctrl+Tab / Ctrl+Shift+Tab cycle, Ctrl+W closes the current tab.
-- The set of tabs is kept between runs.
--
-- The engine holds one repository at a time; switching tabs reopens the
-- repository (cheap — libgit2 keeps nothing warm worth sharing).
--
-- Public API: tabs.openInNewTab(path), tabs.close(index), tabs.next(delta),
--             tabs.list(), tabs.forget(path)

local C = require("core.palette")
local app = require("core.app")
local frame = require("views.frame")
local geometry = require("ui.geometry")
local keys = require("core.keys")
local sidebar = require("views.sidebar")
local text = require("core.text")

local tabs = { name = "tabs" }

local FILE = "open-tabs"
local HEIGHT = 30
local MAX_TAB_WIDTH = 220
local ADD_WIDTH = 34

local open = {}            -- { { path, view = "changes" | "history" | "graph" } }
local active = 0           -- index into `open`
local built = 0            -- tab widgets created so far
local pendingNewTab = false
local pendingView = nil    -- view to restore after a switch

--- Comparison key for paths.
-- @param path  a path
-- @return normalised key
local function key(path)
    return (path:gsub("\\", "/"):gsub("/+$", ""):lower())
end

--- Index of an open path.
-- @param path  repository path
-- @return index or nil
local function indexOf(path)
    for i, tab in ipairs(open) do
        if key(tab.path) == key(path) then
            return i
        end
    end

    return nil
end

--- Persist the open tabs.
local function save()
    local lines = {}
    for _, tab in ipairs(open) do
        lines[#lines + 1] = tab.path
    end

    gitgud.configWrite(FILE, table.concat(lines, "\n"))
end

--- The view the window is showing now.
-- @return "changes" | "history" | "graph"
local function currentView()
    if frame.graphMode() then
        return "graph"
    end

    return sidebar.tab()
end

--- Create the widgets for tab slot i.
-- @param i  slot
local function buildSlot(i)
    local button = "TabButton" .. i
    local close = "TabClose" .. i

    gitgud.createWindow("Gitgud/Button", button, "TabStrip")
    gitgud.setProperty(button, "HorzFormatting", "LeftAligned")
    gitgud.setProperty(button, "Font", "Gitgud-UI-Small")
    gitgud.setProperty(button, "BorderColour", C.hairline)
    gitgud.on(button .. ".clicked", function()
        tabs.activate(i)
    end)

    gitgud.createWindow("Gitgud/Button", close, button)
    gitgud.setText(close, "×")
    gitgud.setProperty(close, "Area", geometry.area(1, -26, 0, 4, 1, -4, 1, -4))
    gitgud.setProperty(close, "NormalFillColour", C.transparent)
    gitgud.setProperty(close, "HoverFillColour", C.bg4)
    gitgud.setProperty(close, "BorderColour", C.transparent)
    gitgud.setProperty(close, "NormalTextColour", C.dim)
    gitgud.setProperty(close, "TooltipText", "Close tab  (Ctrl+W)")
    gitgud.on(close .. ".clicked", function()
        tabs.close(i)
    end)
end

--- Paint the strip.
local function render()
    local show = #open >= 2
    frame.setBand("tabs", show and HEIGHT or 0)
    if not show then
        for i = 1, built do
            gitgud.setVisible("TabButton" .. i, false)
        end
        gitgud.setVisible("TabAddButton", false)
        return
    end

    local _, _, stripWidth = gitgud.getRect("TabStrip")
    stripWidth = stripWidth or 1200
    local tabWidth = math.min(MAX_TAB_WIDTH, math.floor((stripWidth - ADD_WIDTH - 8) / #open))

    for i, tab in ipairs(open) do
        if i > built then
            buildSlot(i)
            built = i
        end
        local button = "TabButton" .. i
        local isActive = i == active
        local x = (i - 1) * tabWidth

        gitgud.setVisible(button, true)
        gitgud.setProperty(button, "Area", geometry.area(0, x, 0, 0, 0, x + tabWidth - 1, 1, -1))
        local dot = isActive and text.colour(C.cyan, "●  ") or text.colour(C.disabled, "●  ")
        gitgud.setText(button, "   " .. dot .. text.colour(isActive and C.text or C.text2, text.basename(tab.path)))
        gitgud.setProperty(button, "TooltipText", tab.path)
        gitgud.setProperty(button, "NormalFillColour", isActive and C.bg1 or C.bg0)
        gitgud.setProperty(button, "HoverFillColour", isActive and C.bg1 or C.bg3)
        gitgud.setProperty(button, "PushedFillColour", C.bg1)
        gitgud.setProperty(button, "NormalTextColour", isActive and C.text or C.text2)
    end
    for i = #open + 1, built do
        gitgud.setVisible("TabButton" .. i, false)
    end

    local addX = #open * tabWidth + 4
    gitgud.setVisible("TabAddButton", true)
    gitgud.setProperty("TabAddButton", "Area", geometry.area(0, addX, 0, 3, 0, addX + ADD_WIDTH - 6, 1, -4))
end

--- Switch to tab i.
-- @param i  index
function tabs.activate(i)
    local tab = open[i]
    if not tab or i == active then
        return
    end

    if open[active] then
        open[active].view = currentView()
    end
    active = i
    pendingView = tab.view
    render()
    gitgud.openRepo(tab.path)
end

--- Open a repository in a new tab (or switch to it if it has one).
-- @param path  repository folder
function tabs.openInNewTab(path)
    local existing = indexOf(path)
    if existing then
        tabs.activate(existing)
        return
    end

    if open[active] then
        open[active].view = currentView()
    end
    pendingNewTab = true
    require("ui.popup").close()
    gitgud.openRepo(path)
end

--- Close tab i (switching to a neighbour if it was the current one).
-- @param i  index
function tabs.close(i)
    if not open[i] or #open < 2 then
        return
    end

    table.remove(open, i)
    save()
    if i == active then
        active = 0
        tabs.activate(math.min(i, #open))
    else
        if i < active then
            active = active - 1
        end
        render()
    end
end

--- Cycle through the tabs.
-- @param delta  +1 or -1
function tabs.next(delta)
    if #open < 2 then
        return
    end

    tabs.activate((active - 1 + delta) % #open + 1)
end

--- The open tabs (paths).
-- @return array of paths
function tabs.list()
    local out = {}
    for _, tab in ipairs(open) do
        out[#out + 1] = tab.path
    end

    return out
end

--- Drop a repository from the tabs (e.g. removed from the list).
-- @param path  repository folder
-- @return true when another tab was opened in its place
function tabs.forget(path)
    local i = indexOf(path)
    if i and #open >= 2 then
        local wasActive = i == active
        tabs.close(i)
        return wasActive
    end
    if i then
        table.remove(open, i)
        active = 0
        save()
        render()
    end

    return false
end

--- A repository finished opening: add it or retarget the current tab.
-- @param path  the repository's folder ("" when closed)
local function onRepoChanged(path)
    if path == "" then
        return
    end

    local existing = indexOf(path)
    if existing then
        active = existing
    elseif pendingNewTab or active == 0 then
        open[#open + 1] = { path = path, view = "changes" }
        active = #open
    else
        open[active] = { path = path, view = "changes" }
    end
    pendingNewTab = false
    save()
    render()

    local view = pendingView
    pendingView = nil
    if view == "graph" then
        require("views.graph").show()
    elseif view == "history" or view == "changes" then
        sidebar.select(view)
    end
end

--- Wire the strip, restore the saved tabs.
function tabs.init()
    gitgud.createWindow("Gitgud/Button", "TabAddButton", "TabStrip")
    gitgud.setText("TabAddButton", "[image-size='w:22 h:22'][image='Gitgud-Images/IconPlus']")
    gitgud.setProperty("TabAddButton", "NormalFillColour", C.bg0)
    gitgud.setProperty("TabAddButton", "HoverFillColour", C.bg3)
    gitgud.setProperty("TabAddButton", "BorderColour", C.transparent)
    gitgud.setProperty("TabAddButton", "TooltipText", "Open a repository in a new tab")
    gitgud.setVisible("TabAddButton", false)
    gitgud.on("TabAddButton.clicked", function()
        require("views.repositories").show({ newTab = true })
    end)

    local raw = gitgud.configRead(FILE) or ""
    for line in raw:gmatch("[^\r\n]+") do
        if gitgud.pathExists(line) and not indexOf(line) then
            open[#open + 1] = { path = line, view = "changes" }
        end
    end

    gitgud.on("repo.changed", onRepoChanged)
    gitgud.on("window.resized", render)

    keys.bind("ctrl+tab", function()
        tabs.next(1)
    end, "Next tab")
    keys.bind("ctrl+shift+tab", function()
        tabs.next(-1)
    end, "Previous tab")
    keys.bind("ctrl+w", function()
        tabs.close(active)
    end, "Close tab")

    -- The repository opened at launch belongs in a tab too.
    if gitgud.isOpen() then
        onRepoChanged(gitgud.repoPath())
    else
        render()
    end
end

return tabs
