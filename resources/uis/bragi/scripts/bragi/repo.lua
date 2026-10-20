--- bragi/repo.lua: the Repository view's Bragi touches (design D).
--
-- The GitGud UI's views run the Repository view unchanged; this module
-- adapts what the design moved:
--
--   - Changes / History is a switch in the top bar (BragiRepoTabs) instead
--     of tabs at the top of the sidebar; the sidebar's own tab row is hidden
--     and its panels move up.
--   - The branch tree (branches, remotes, tags, stashes, submodules,
--     worktrees) is a panel shown with the top bar's Branches button
--     (Ctrl+Shift+B); it starts hidden, as the design leans on the repo and
--     branch dropdowns.
--   - The fetch button reads as one line: "Fetch origin · never fetched",
--     or "Fetch origin", or just its icon, as room allows.

local C = require("core.palette")
local app = require("core.app")
local frame = require("views.frame")
local geometry = require("ui.geometry")
local rows = require("bragi.rows")
local settings = require("core.settings")
local shell = require("bragi.shell")
local sidebar = require("views.sidebar")
local text = require("core.text")

local repo = { name = "bragi.repo" }

--- Paint the Changes / History switch for the active tab.
local function paintTabs()
    local changes = sidebar.tab() ~= "history"
    gitgud.setProperty("BragiChangesTab", "NormalFillColour", changes and C.sel or C.transparent)
    gitgud.setProperty("BragiChangesTab", "HoverFillColour", changes and C.sel or C.hover)
    gitgud.setProperty("BragiChangesTabLabel", "NormalTextColour", changes and C.text or C.sub)
    gitgud.setProperty("BragiHistoryTab", "NormalFillColour", changes and C.transparent or C.sel)
    gitgud.setProperty("BragiHistoryTab", "HoverFillColour", changes and C.hover or C.sel)
    gitgud.setProperty("BragiHistoryTab", "NormalTextColour", changes and C.sub or C.text)
    gitgud.setProperty("BragiHistoryTab", "HoverTextColour", C.text)
    -- The count badge: accent on the active tab, quiet otherwise.
    gitgud.setProperty("BragiChangesCount", "FillColour", changes and C.accent or C.sel)
    gitgud.setProperty("BragiChangesCountLabel", "NormalTextColour", changes and C.onAccent or C.text)
end

--- Show or hide the branch tree.
-- @param on  boolean
local function setBranches(on)
    frame.setNavigator(on)
    settings.set("bragi.branchTree", on)
    gitgud.setProperty("BragiBranchesIcon", "IconColour", on and C.accentText or C.sub)
    gitgud.setProperty("BragiBranchesButton", "NormalFillColour", on and C.sel or C.transparent)
end

local DROPDOWN = 112      -- the repo and branch buttons
local ICON = 36           -- each quick-action button, gap included
local QUICK = { "BragiBranchesButton", "UndoButton", "RedoButton", "GraphButton", "ConsoleButton" }
local RIGHT_GROUP = 604   -- Changes | History, search, window buttons
local SYNC_MAX = 300      -- the fetch button at its widest

local syncLine = { full = "", short = "", shown = nil }

--- Fit the fetch button into `room` pixels: its whole line ("Fetch origin
-- · never fetched") when that fits, else just what it does ("Fetch
-- origin"), else only its icon.
-- @return the width it takes
local function fitSync(room)
    local function width(s)
        return s ~= "" and math.ceil(rows.measure("[font='Bragi-13']" .. text.escape(s))) + 38 or 0
    end
    local line, w = syncLine.full, width(syncLine.full)
    if w > room or w > SYNC_MAX then
        line, w = syncLine.short, width(syncLine.short)
    end
    local iconOnly = line == "" or w > room
    if iconOnly then
        w = 32
    end
    syncLine.shown = iconOnly and nil or line
    gitgud.setVisible("SyncLabel", not iconOnly)
    if not iconOnly then
        gitgud.setText("SyncLabel", text.escape(line))
    end
    return w
end

--- Lay the left group out to fit before the Changes | History switch:
-- the fetch button gets what's left (fitSync), then the quick actions.
local function layoutTopBar()
    local _, _, w = gitgud.getRect("Toolbar")
    if not w then
        return
    end
    local x = 24
    gitgud.setProperty("RepoButton", "Area", geometry.rect(x, 10, DROPDOWN, 36))
    x = x + DROPDOWN + 10
    gitgud.setProperty("BranchButton", "Area", geometry.rect(x, 10, DROPDOWN, 36))
    x = x + DROPDOWN + 8

    local room = (w - RIGHT_GROUP - 16) - x - #QUICK * ICON - 8
    local syncWidth = fitSync(room)
    gitgud.setProperty("SyncButton", "Area", geometry.rect(x, 10, syncWidth, 36))
    x = x + syncWidth + 8
    for _, name in ipairs(QUICK) do
        gitgud.setProperty(name, "Area", geometry.rect(x, 12, 32, 32))
        x = x + ICON
    end
end

--- "FETCH ORIGIN" + "Never fetched" -> "Fetch origin · never fetched"
-- (and "Fetch origin" for when that doesn't fit), then lay the bar out.
local function joinSync()
    local label = text.trim(gitgud.getText("SyncLabel") or "")
    local value = text.trim(gitgud.getText("SyncValue") or "")
    -- Still what we put there (refresh can run without the toolbar changing it).
    if label == "" or label == syncLine.shown then
        return
    end
    local function sentence(s)
        s = s:lower()
        return s:sub(1, 1):upper() .. s:sub(2)
    end
    syncLine.short = sentence(label)
    syncLine.full = syncLine.short
    if value ~= "" then
        syncLine.full = syncLine.short .. " · " .. value:sub(1, 1):lower() .. value:sub(2)
    end
    layoutTopBar()
end

function repo.init()
    -- The sidebar's own tab row goes; its panels move up to fill it.
    for _, name in ipairs({ "ChangesTab", "HistoryTab", "ChangesTabBar", "HistoryTabBar", "TabHairline" }) do
        gitgud.setVisible(name, false)
    end
    -- views/sidebar.lua shows the active tab's underline again on every
    -- switch: give them no size.
    gitgud.setProperty("ChangesTabBar", "Area", "{{0,0},{0,0},{0,0},{0,0}}")
    gitgud.setProperty("HistoryTabBar", "Area", "{{0,0},{0,0},{0,0},{0,0}}")
    gitgud.setProperty("ChangesPanel", "Area", "{{0,0},{0,0},{1,0},{1,0}}")
    gitgud.setProperty("HistoryPanel", "Area", "{{0,0},{0,0},{1,0},{1,0}}")

    gitgud.on("BragiChangesTab.clicked", function()
        sidebar.select("changes")
    end)
    gitgud.on("BragiHistoryTab.clicked", function()
        sidebar.select("history")
    end)
    app.subscribe("tab.changed", paintTabs)

    gitgud.on("BragiBranchesButton.clicked", function()
        setBranches(not frame.navigatorVisible())
    end)
    shell.bind("ctrl+shift+b", function()
        setBranches(not frame.navigatorVisible())
    end, "repo")

    setBranches(settings.get("bragi.branchTree", false))
    paintTabs()

    gitgud.on("window.resized", layoutTopBar)
    -- The toolbar repaints the fetch button on its own when a sync ends.
    app.subscribe("sync.changed", joinSync)
    -- It also repaints "Fetched 2 minutes ago" every minute.
    gitgud.every(60 * 1000, function()
        gitgud.after(50, joinSync)
    end)
    app.subscribe("bragi.view", function(view)
        if view == "repo" then
            layoutTopBar()
        end
    end)
    layoutTopBar()
end

function repo.refresh(state)
    local count = #state.files
    gitgud.setVisible("BragiChangesCount", count > 0)
    gitgud.setText("BragiChangesCountLabel", tostring(count))
    joinSync()
    paintTabs()
end

return repo
