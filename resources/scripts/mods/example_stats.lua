--- mods/example_stats.lua — an example mod: a "Tools > Repository
-- statistics" panel.
--
-- It shows the three things a mod usually needs:
--   1. its own layout, attached automatically by app.start() because the
--      module sets `layout` (resources/layouts/mods/example_stats.xml)
--   2. its own menu (ui/menu.lua) with a keyboard shortcut
--   3. reading repository data through the gitgud API and repainting on
--      every refresh
--
-- Enable it by uncommenting its app.use line in main.lua.

local C = require("core.palette")
local dialog = require("ui.dialog")
local menu = require("ui.menu")
local repo = require("core.repo")
local text = require("core.text")

local stats = {
    name = "example_stats",
    layout = "mods/example_stats.xml",   -- relative to resources/layouts
    parent = "Root",                     -- where to attach it
}

local escapeToken = nil
local visible = false

--- Fill the panel's labels from the current repository.
local function paint()
    local state = repo.state()
    if not state.open then
        gitgud.setText("StatsBody", text.colour(C.dim, "No repository open."))
        return
    end

    local commits = #gitgud.history(5000)
    local localBranches = 0
    local remoteBranches = 0
    for _, branch in ipairs(gitgud.branches()) do
        if branch.isRemote then
            remoteBranches = remoteBranches + 1
        else
            localBranches = localBranches + 1
        end
    end

    local lines = {
        text.colour(C.text2, "Commits on " .. state.branch .. ":  ") .. text.colour(C.cyan, tostring(commits)),
        text.colour(C.text2, "Local branches:  ") .. text.colour(C.cyan, tostring(localBranches)),
        text.colour(C.text2, "Remote branches:  ") .. text.colour(C.cyan, tostring(remoteBranches)),
        text.colour(C.text2, "Tags:  ") .. text.colour(C.cyan, tostring(#gitgud.tags())),
        text.colour(C.text2, "Uncommitted files:  ") .. text.colour(C.cyan, tostring(#state.files)),
    }
    gitgud.setText("StatsBody", table.concat(lines, "\n"))
end

--- Hide the panel.
local function hide()
    visible = false
    dialog.hideModal("StatsPanel", escapeToken)
end

--- Show the panel.
local function show()
    visible = true
    paint()
    escapeToken = dialog.showModal("StatsPanel", hide)
end

--- Called once at startup, after the layout is attached.
function stats.init()
    menu.addMenu("tools", "Tools")
    menu.addItem("tools", {
        label = "Repository statistics",
        shortcut = "ctrl+alt+s",
        enabled = function()
            return repo.state().open
        end,
        action = show,
    })

    gitgud.on("StatsCloseButton.clicked", hide)
end

--- Called after every repository refresh.
-- @param state  the repository snapshot (see core/repo.lua)
function stats.refresh(state)
    if visible then
        paint()
    end
end

return stats
