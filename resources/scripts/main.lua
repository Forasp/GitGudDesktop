--- main.lua — GitGud Desktop's script entry point.
--
-- This file only wires things together. Behaviour lives in modules under
-- resources/scripts, loaded with require (dots are folders:
-- require("views.changes") loads views/changes.lua):
--
--   core/   shared services: the module registry and refresh pipeline
--           (app), the repository snapshot (repo), settings, status bar,
--           keyboard shortcuts, colours, text helpers, desktop shell,
--           undo/redo (undo), word diffs (worddiff)
--   ui/     reusable widgets built on the gitgud API: popups, menus,
--           the command palette, the generic dialog, editbox placeholders,
--           geometry helpers
--   views/  one module per feature of the window (frame.lua lays out the
--           big regions: tabs, branch tree, sidebar/graph, content, console)
--
-- The widget tree they drive is resources/layouts/main.xml (and the files
-- it imports). Saving any .lua or .xml while the app runs reloads the UI.
--
-- To add your own feature: write a module (see mods/example_stats.lua and
-- docs/MODDING.md), then add one app.use(require("...")) line in the
-- "Your modules" section below.

local app = require("core.app")
local commands = require("ui.commands")
local dialog = require("ui.dialog")
local keys = require("core.keys")
local menu = require("ui.menu")
local popup = require("ui.popup")

-- The toolkit first: everything below builds on it.
keys.init()
popup.init()
dialog.init()
menu.init()
commands.init()

-- Built-in views. Order matters only for refresh(): each module's refresh
-- runs in this order after the repository snapshot is reloaded.
app.use(require("views.titlebar"))
app.use(require("views.frame"))
app.use(require("views.notice"))
app.use(require("views.toolbar"))
app.use(require("views.tabs"))
app.use(require("views.navigator"))
app.use(require("views.sidebar"))
app.use(require("views.diff"))
app.use(require("views.imagediff"))
app.use(require("views.content"))
app.use(require("views.commitview"))
app.use(require("views.stash"))
app.use(require("views.changes"))
app.use(require("views.history"))
app.use(require("views.graph"))
app.use(require("views.branches"))
app.use(require("views.repositories"))
app.use(require("views.sync"))
app.use(require("views.settings"))
app.use(require("views.mergetool"))
app.use(require("views.inspector"))
app.use(require("views.rebase"))
app.use(require("views.console"))
app.use(require("views.ssh"))
app.use(require("views.lfs"))
app.use(require("views.menus"))
app.use(require("views.updates"))

-- Your modules --------------------------------------------------------------
-- Uncomment to try the example: adds a Tools menu with a statistics panel
-- (scripts/mods/example_stats.lua + layouts/mods/example_stats.xml).
-- app.use(require("mods.example_stats"))

-- Refresh whenever the repository may have changed underneath us.
gitgud.on("status.changed", app.requestRefresh)
gitgud.on("app.focusGained", app.requestRefresh)

gitgud.on("app.started", function(reason)
    if reason == "hot-reload" then
        require("core.status").ok("UI reloaded.")
    end
end)

app.start()
