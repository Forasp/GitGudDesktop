--- main.lua — the P4V-style UI's entry point.
--
-- A UI package (see docs/MODDING.md, "Your own interface"): this folder's
-- scripts/ is searched before the default UI's, so `require` finds the
-- P4V modules here (p4/…, and core/palette.lua with the Dagobah colours)
-- and the shared toolkit there (core/, ui/, and a few default views used as
-- headless services: repositories, sync, ssh, settings, lfs).
--
--   p4/frame.lua        window layout and splitters
--   p4/toolbar.lua      the icon toolbar       p4/menus.lua   the menu bar
--   p4/views/*.lua      the tree pane and the tabs (Files, History,
--                       Pending, Submitted, Branches, Labels, Workspaces),
--                       the Log / Dashboard pane
--   p4/windows/*.lua    pop-out windows: Diff, Revision Graph, Time-lapse,
--                       Folder Diff
--   p4/actions.lua      Check Out, Add, Delete, Revert, Submit, Shelve, …
--   p4/commands.lua     branches, labels, integrate, resolve, connection
--   p4/changelists.lua  pending changelists (kept locally)

local app = require("core.app")
local changelists = require("p4.changelists")
local commands = require("ui.commands")
local dialog = require("ui.dialog")
local keys = require("core.keys")
local menu = require("ui.menu")
local popup = require("ui.popup")

-- P4V is a regular window with the OS title bar.
gitgud.setWindowBordered(true)
gitgud.setWindowTitle("", "GitGud Desktop — P4V")

keys.init()
popup.init()
dialog.init()
menu.init()
commands.init()
require("p4.changedialog").init()
require("p4.windows").init()

-- Shared services from the default UI (no widgets of their own here).
app.use(require("views.repositories"))
app.use(require("views.sync"))
app.use(require("views.ssh"))

-- The P4V window.
app.use(require("p4.frame"))
app.use(require("p4.log"))
app.use(require("p4.views.panes"))
app.use(require("p4.views.depot"))
app.use(require("p4.views.files"))
app.use(require("p4.views.history"))
app.use(require("p4.views.pending"))
app.use(require("p4.views.submitted"))
app.use(require("p4.views.branches"))
app.use(require("p4.views.labels"))
app.use(require("p4.views.workspaces"))
app.use(require("p4.views.dashboard"))
app.use(require("p4.toolbar"))
app.use(require("p4.menus"))
app.use(require("p4.status"))

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
require("p4.views.panes").start()
