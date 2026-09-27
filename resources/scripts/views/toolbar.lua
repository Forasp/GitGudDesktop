--- views/toolbar.lua — the three toolbar controls and the status summary.
--
-- Fills RepoValue / BranchValue / SyncLabel / SyncValue from the snapshot and
-- swaps the sync icon between fetch, push, and pull.
-- Clicks are handled by the modules that own each popup (repositories,
-- branches, sync).

local C = require("core.palette")
local app = require("core.app")
local repo = require("core.repo")
local status = require("core.status")
local sync = require("views.sync")
local text = require("core.text")

local toolbar = { name = "toolbar" }

--- The sync control's label, value, and icon for a snapshot.
-- @param state  repository snapshot
-- @return label, value, icon image name
local function syncDisplay(state)
    local remote = repo.upstreamRemote() or "origin"
    local ab = state.aheadBehind
    local busy = sync.busy()

    if busy then
        local verbs = {
            fetch = "FETCHING",
            push = "PUSHING",
            pull = "PULLING",
            pushTags = "PUSHING TAGS",
            clone = "CLONING",
        }
        local target = sync.busyRemote()
        return (verbs[busy] or "WORKING") .. (target and (" " .. target:upper()) or ""), "Working…", "IconSync"
    end

    if not state.open then
        return "FETCH ORIGIN", "No repository", "IconSync"
    end
    if not repo.primaryRemote() then
        return "NO REMOTE", "Add one in settings", "IconSync"
    end
    if ab.hasUpstream and (ab.behind or 0) > 0 then
        local value = text.plural(ab.behind, "commit") .. " behind"
        if (ab.ahead or 0) > 0 then
            value = value .. ", " .. ab.ahead .. " ahead"
        end
        return "PULL " .. remote:upper(), value, "IconPull"
    end
    if ab.hasUpstream and (ab.ahead or 0) > 0 then
        return "PUSH " .. remote:upper(), text.plural(ab.ahead, "commit") .. " to push", "IconPush"
    end
    if not ab.hasUpstream and state.branch ~= "" and state.headOid ~= "" then
        local where = #state.remotes > 1 and "Choose a remote" or ("Push to " .. remote)
        return "PUBLISH BRANCH", where, "IconPush"
    end

    local fetched = sync.lastFetched()
    local value = fetched and ("Fetched " .. text.ago(fetched)) or "Never fetched"
    local label = #state.remotes > 1 and "FETCH ALL" or ("FETCH " .. remote:upper())
    return label, value, "IconSync"
end

--- Repaint the toolbar and status summary.
-- @param state  repository snapshot
function toolbar.refresh(state)
    local title = "GitGud Desktop"
    if state.open then
        title = title .. "  —  " .. state.name
    end
    gitgud.setText("AppTitleLabel", text.colour(C.dim, title))

    gitgud.setText("RepoValue", text.escape(state.open and state.name or "No repository"))

    local branchValue = state.branch
    if state.detached then
        branchValue = "Detached at " .. state.headOid:sub(1, 7)
    elseif branchValue == "" then
        branchValue = state.open and "(no branch)" or "—"
    end
    gitgud.setText("BranchValue", text.escape(branchValue))
    gitgud.setEnabled("BranchButton", state.open)

    local label, value, icon = syncDisplay(state)
    gitgud.setText("SyncLabel", text.escape(label))
    gitgud.setText("SyncValue", text.escape(value))
    gitgud.setProperty("SyncIcon", "IconImage", "Gitgud-Images/" .. icon)
    gitgud.setEnabled("SyncButton", state.open and not sync.busy())

    local summary = ""
    if state.open then
        local ab = state.aheadBehind
        summary = text.colour(C.text2, branchValue)
        if ab.hasUpstream then
            summary = summary .. text.colour(C.dim, "   ↑" .. (ab.ahead or 0) .. " ↓" .. (ab.behind or 0))
        end
        summary = summary .. text.colour(C.dim, "   ·   " .. text.plural(#state.files, "change"))
    end
    status.summary(summary)
end

--- Enable Undo / Redo and put what they'd do in their tooltips.
local function paintUndo()
    local undo = require("core.undo")
    local nextUndo = undo.peekUndo()
    local nextRedo = undo.peekRedo()

    gitgud.setEnabled("UndoButton", nextUndo ~= nil)
    gitgud.setEnabled("RedoButton", nextRedo ~= nil)
    gitgud.setProperty("UndoButton", "TooltipText",
        nextUndo and ("Undo: " .. nextUndo.label .. "  (Ctrl+Z)") or "Nothing to undo")
    gitgud.setProperty("RedoButton", "TooltipText",
        nextRedo and ("Redo: " .. nextRedo.label .. "  (Ctrl+Shift+Z)") or "Nothing to redo")
    gitgud.setProperty("UndoButtonLabel", "NormalTextColour", nextUndo and C.text2 or C.disabled)
    gitgud.setProperty("RedoButtonLabel", "NormalTextColour", nextRedo and C.text2 or C.disabled)
    gitgud.setProperty("UndoButtonIcon", "IconColour", nextUndo and "FFFFFFFF" or C.disabled)
    gitgud.setProperty("RedoButtonIcon", "IconColour", nextRedo and "FFFFFFFF" or C.disabled)
end

--- Undo the last action, reporting the outcome.
function toolbar.undo()
    local undo = require("core.undo")
    local step = undo.peekUndo()
    local ok, err = undo.undo()
    if status.report(step and ("Undid: " .. step.label) or nil, ok, err) then
        app.requestRefresh()
    end
end

--- Redo the last undone action.
function toolbar.redo()
    local undo = require("core.undo")
    local step = undo.peekRedo()
    local ok, err = undo.redo()
    if status.report(step and ("Redid: " .. step.label) or nil, ok, err) then
        app.requestRefresh()
    end
end

--- Repaint when a network operation starts/stops (busy state).
function toolbar.init()
    gitgud.on("UndoButton.clicked", toolbar.undo)
    gitgud.on("RedoButton.clicked", toolbar.redo)
    gitgud.on("GraphButton.clicked", function()
        require("views.graph").toggle()
    end)
    gitgud.on("ConsoleButton.clicked", function()
        require("views.console").toggle()
    end)
    gitgud.on("PaletteButton.clicked", function()
        require("ui.commands").open()
    end)

    app.subscribe("undo.changed", paintUndo)
    app.subscribe("refreshed", paintUndo)
    --- Light the Console button while the console is open.
    local function paintConsoleButton()
        local consoleOn = require("views.frame").consoleVisible()
        gitgud.setProperty("ConsoleButtonLabel", "NormalTextColour", consoleOn and C.cyan or C.text2)
        gitgud.setProperty("ConsoleButtonIcon", "IconColour", consoleOn and C.cyan or "FFFFFFFF")
    end
    app.subscribe("frame.changed", paintConsoleButton)
    paintConsoleButton()

    app.subscribe("sync.changed", function()
        toolbar.refresh(repo.state())
    end)

    -- "Fetched 2 minutes ago" ages; repaint it now and then.
    gitgud.every(60 * 1000, function()
        toolbar.refresh(repo.state())
    end)
end

return toolbar
