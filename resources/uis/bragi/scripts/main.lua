--- main.lua: the Bragi UI's entry point.
--
-- A UI package (docs/MODDING.md, "Your own interface"), in design D
--: an icon rail and five views.
--
--   Agent      bragi/agent.lua: talk to Claude Code
--   Repo       the GitGud UI itself: its views, run from the shared
--              resources/scripts in its own layouts (this package replaces
--              the title bar and toolbar), themed by themes/*.ini;
--              bragi/repo.lua adapts what the design moved;
--              bragi/repolook.lua draws Changes and History its way
--   Boards     bragi/boards.lua
--   Wiki       bragi/wiki.lua
--   Settings   bragi/settings.lua
--
--   bragi/shell.lua   the rail, the views, light / dark, shortcuts per view
--   bragi/server.lua  where tasks, boards, and wikis come from: API calls by path
--   bragi/store.lua   the local store that answers them, on this computer
--   bragi/projects.lua  the projects: conversations' folders, the repository
--                     list, Claude Code's
--   bragi/sessionlist.lua  the Agent view's conversations, grouped by project
--   bragi/master.lua  Bragi, the master conversation over every project
--   bragi/uitools.lua the UI's own tools for Claude Code, from every module
--   bragi/wikitool.lua  reading the wikis, for Claude Code (quick answers too)
--   bragi/customize.lua your own changes to this interface (<config>/bragi/ui)
--   bragi/voice.lua   listening, the heard-text filter, spoken replies
--   bragi/sidepanel.lua  the Agent view's session panel on the right
--   bragi/usage.lua   the usage circle by the prompt box: context and limits
--   bragi/quick.lua   quick answers with Haiku (bragi/helpers.lua: the
--                     app's own Haiku sessions)
--   bragi/training.lua  wake word training and voice enrollment
--   bragi/routines.lua  prompts Claude Code runs on a schedule
--   bragi/import.lua  projects and MCP servers from Claude Code and Claude Desktop
--   bragi/welcome.lua the first-time setup, the first time Bragi is picked
--   bragi/markdown.lua  Markdown read and drawn in the app
--   bragi/ui.lua      builders for the design's cards, buttons, inputs
--   core/palette.lua  the running theme's colours for every script

local app = require("core.app")
local commands = require("ui.commands")
local dialog = require("ui.dialog")
local keys = require("core.keys")
require("core.display") -- renews the window after the displays change
local menu = require("ui.menu")
local popup = require("ui.popup")

keys.init()
popup.init()
dialog.init()
menu.init()
commands.init()

-- The Repository view: the GitGud UI's modules, as its main.lua runs them.
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

-- Bragi. After the GitGud UI's modules, so its shortcuts can wrap theirs.
app.use(require("bragi.shell"))
app.use(require("bragi.server"))
app.use(require("bragi.store"))
app.use(require("bragi.repo"))
app.use(require("bragi.repolook"))
app.use(require("bragi.projects"))
app.use(require("bragi.agent"))
app.use(require("bragi.sidepanel"))
app.use(require("bragi.usage"))
app.use(require("bragi.answerbanner"))
app.use(require("bragi.master"))
app.use(require("bragi.review"))
app.use(require("bragi.quick"))
app.use(require("bragi.voice"))
app.use(require("bragi.uitools"))
app.use(require("bragi.settingstool"))
app.use(require("bragi.wikitool"))
app.use(require("bragi.customize"))
app.use(require("bragi.training"))
app.use(require("bragi.routines"))
app.use(require("bragi.import"))
app.use(require("bragi.settings"))
app.use(require("bragi.boards"))
app.use(require("bragi.taskview"))
app.use(require("bragi.wiki"))
app.use(require("bragi.welcome"))

gitgud.on("status.changed", app.requestRefresh)
gitgud.on("app.focusGained", app.requestRefresh)

gitgud.on("app.started", function(reason)
    if reason == "hot-reload" then
        require("core.status").ok("UI reloaded.")
    end
end)

app.start()

require("core.keys").adaptTooltips({
    "RepoButton", "BranchButton", "SyncButton", "UndoButton", "RedoButton", "GraphButton",
    "ConsoleButton", "PaletteButton", "ChangesTab", "HistoryTab", "GraphCloseButton",
    "ConsoleCloseButton", "CommitButton", "NewBranchButton", "BragiRailAgent", "BragiRailRepo",
    "BragiRailBoards", "BragiRailWiki", "BragiRailSettings", "AgentNewButton", "AgentSidebarButton",
    "AgentSendButton", "AgentSearch", "PaletteButton", "BragiBranchesButton", "AgentReviewButton",
})
