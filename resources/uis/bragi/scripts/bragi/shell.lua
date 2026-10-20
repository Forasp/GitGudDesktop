--- bragi/shell.lua: the window around Bragi's views (design D).
--
-- The rail on the left picks one view at a time:
--
--   agent     AgentView (bragi/agent.lua)
--   repo      RepoView, the GitGud UI's window (bragi/repo.lua adjusts it)
--   boards    BoardsView (bragi/boards.lua)
--   wiki      WikiView (bragi/wiki.lua)
--   settings  SettingsView (bragi/settings.lua)
--
-- The rail's theme button switches between the light and dark themes
-- (gitgud.setTheme rebuilds the UI in the other theme). The window's
-- canvas, behind the UI, takes the theme's background too (shell.paintCanvas).
--
-- The GitGud UI's shortcuts are global, so outside the Repository view only
-- combos bound with shell.bind (and a few window-wide ones) reach their
-- handlers: Ctrl+Enter must not commit while you type to the agent.
--
-- Public API: shell.show(view), shell.view(), shell.bind(combo, handler, view),
-- shell.returning() (Bragi ran before, on this machine), shell.paintCanvas()
-- Signals (app.publish): "bragi.view" (view)

local C = require("core.palette")
local app = require("core.app")
local keys = require("core.keys")
local settings = require("core.settings")

local shell = { name = "bragi.shell" }

local VIEWS = {
    agent = { root = "AgentView", rail = "BragiRailAgent" },
    repo = { root = "RepoView", rail = "BragiRailRepo" },
    boards = { root = "BoardsView", rail = "BragiRailBoards" },
    wiki = { root = "WikiView", rail = "BragiRailWiki" },
    settings = { root = "SettingsView", rail = "BragiRailSettings" },
}

local current = nil
local returning = false

-- Combos that work in every view.
local everywhere = {
    ["ctrl+1"] = true, ["ctrl+2"] = true, ["ctrl+3"] = true, ["ctrl+4"] = true,
    ["ctrl+,"] = true, ["ctrl+k"] = true, ["f1"] = true, ["ctrl+q"] = true,
}

-- view -> { combo = true } for combos bound with shell.bind.
local viewCombos = {}

--- Paint one rail item as active or not.
-- @param name    rail button
-- @param active  boolean
local function paintRail(name, active)
    gitgud.setProperty(name, "NormalFillColour", active and C.sel or C.transparent)
    gitgud.setProperty(name, "HoverFillColour", active and C.sel or C.hover)
    gitgud.setProperty(name .. "Icon", "IconColour", active and C.accentText or C.sub)
    gitgud.setProperty(name .. "Label", "NormalTextColour", active and C.accentText or C.sub)
end

--- The view showing.
-- @return "agent" | "repo" | "boards" | "wiki" | "settings"
function shell.view()
    return current
end

--- True when Bragi had run before this start (it remembered a view).
function shell.returning()
    return returning
end

--- Show a view.
-- @param view  a key of VIEWS (anything else shows the Agent view)
function shell.show(view)
    if not VIEWS[view] then
        view = "agent"
    end
    local changed = view ~= current
    current = view

    for id, v in pairs(VIEWS) do
        gitgud.setVisible(v.root, id == view)
        paintRail(v.rail, id == view)
    end

    if changed then
        settings.set("bragi.view", view)
        app.publish("bragi.view", view)
    end
end

--- Bind a combo for one Bragi view. In the Repository view (and other
-- views) the combo keeps whatever was bound to it before.
-- @param combo    combo string
-- @param handler  function() run while `view` shows
-- @param view     view id (default "agent")
function shell.bind(combo, handler, view)
    view = view or "agent"
    local previous = keys.handler(combo)
    viewCombos[view] = viewCombos[view] or {}
    viewCombos[view][combo] = true

    keys.bind(combo, function()
        if current == view then
            handler()
        elseif previous then
            previous()
        end
    end)
end

--- The rail's theme button names the theme it switches to.
local function paintThemeToggle()
    local theme = gitgud.theme()
    local other = theme == "light" and "Dark" or "Light"
    gitgud.setText("BragiThemeToggleLabel", other)
end

--- The window's canvas, what shows behind the UI while it resizes: the
-- theme's background, not the default skin's dark one.
function shell.paintCanvas()
    gitgud.emit("window.canvas", C.bg1)
end

--- Switch to the other theme (the UI rebuilds itself in it).
function shell.toggleTheme()
    local target = gitgud.theme() == "light" and "dark" or "light"
    local ok, err = gitgud.setTheme(target)
    if not ok then
        require("core.status").error(err or "Couldn't switch the theme.")
    end
end

function shell.init()
    for id, v in pairs(VIEWS) do
        gitgud.on(v.rail .. ".clicked", function()
            shell.show(id)
        end)
    end
    gitgud.on("BragiThemeToggle.clicked", shell.toggleTheme)
    paintThemeToggle()
    shell.paintCanvas()

    keys.bind("ctrl+1", function()
        shell.show("agent")
    end, "Agent")
    keys.bind("ctrl+2", function()
        shell.show("repo")
    end, "Repository")
    keys.bind("ctrl+3", function()
        shell.show("boards")
    end, "Boards")
    keys.bind("ctrl+4", function()
        shell.show("wiki")
    end, "Wiki")

    -- The GitGud UI's shortcuts only act in the Repository view.
    keys.setGate(function(combo)
        if current == "repo" or everywhere[combo] then
            return true
        end
        return (viewCombos[current] or {})[combo] or false
    end)

    returning = settings.get("bragi.view", "") ~= ""
    shell.show(settings.get("bragi.view", "agent"))
end

return shell
