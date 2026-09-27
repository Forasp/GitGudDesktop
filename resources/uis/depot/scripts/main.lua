--- main.lua — the Depot UI's entry point.
--
-- A UI package (see docs/MODDING.md, "Your own interface"): this folder's
-- scripts/ is searched before the default UI's, so `require` finds the
-- Depot modules here (depot/…, and core/palette.lua with the Dagobah colours)
-- and the shared toolkit there (core/, ui/, and a few default views used as
-- headless services: repositories, sync, ssh, settings, lfs).
--
--   depot/frame.lua        window layout and splitters
--   depot/toolbar.lua      the icon toolbar       depot/menus.lua   the menu bar
--   depot/views/*.lua      the tree pane and the tabs (Files, History,
--                       Pending, Submitted, Branches, Labels, Workspaces),
--                       the Log / Dashboard pane
--   depot/windows/*.lua    pop-out windows: Diff, Revision Graph, Time-lapse,
--                       Folder Diff
--   depot/actions.lua      Check Out, Add, Delete, Revert, Submit, Shelve, …
--   depot/commands.lua     branches, labels, integrate, resolve, connection
--   depot/changelists.lua  pending changelists (kept locally)

local app = require("core.app")
local changelists = require("depot.changelists")
local commands = require("ui.commands")
local dialog = require("ui.dialog")
local keys = require("core.keys")
local menu = require("ui.menu")
local popup = require("ui.popup")

-- A regular window with the OS title bar.
gitgud.setWindowBordered(true)
gitgud.setWindowTitle("", "GitGud Desktop - Depot")

keys.init()
popup.init()
dialog.init()
menu.init()
commands.init()
require("depot.changedialog").init()
require("depot.windows").init()

-- Shared services from the default UI (no widgets of their own here).
app.use(require("views.repositories"))
app.use(require("views.sync"))
app.use(require("views.ssh"))

-- The Depot window.
app.use(require("depot.frame"))
app.use(require("depot.log"))
app.use(require("depot.views.panes"))
app.use(require("depot.views.depot"))
app.use(require("depot.views.files"))
app.use(require("depot.views.history"))
app.use(require("depot.views.pending"))
app.use(require("depot.views.submitted"))
app.use(require("depot.views.branches"))
app.use(require("depot.views.labels"))
app.use(require("depot.views.workspaces"))
app.use(require("depot.views.dashboard"))
app.use(require("depot.toolbar"))
app.use(require("depot.menus"))
app.use(require("views.updates"))
app.use(require("depot.status"))

-- Refresh whenever the repository may have changed underneath us.
gitgud.on("status.changed", app.requestRefresh)
gitgud.on("app.focusGained", app.requestRefresh)
gitgud.on("repo.changed", function()
    changelists.reload()
end)

gitgud.on("app.started", function(reason)
    if reason == "hot-reload" then
        require("core.status").ok("UI reloaded.")
    end
end)

app.start()
require("depot.views.panes").start()
