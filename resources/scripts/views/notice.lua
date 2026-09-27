--- views/notice.lua — the banner for operations in progress.
--
-- Shown under the toolbar while the repository is mid-merge, mid-rebase,
-- mid-cherry-pick/revert, or on a detached HEAD, with the actions that get
-- you out (continue / abort / create a branch, open the merge tool).
-- views/frame.lua moves MainArea down while it's visible.

local C = require("core.palette")
local app = require("core.app")
local dialog = require("ui.dialog")
local frame = require("views.frame")
local status = require("core.status")
local text = require("core.text")

local notice = { name = "notice" }

local HEIGHT = 36
local actions = {}
local showing = false

--- Show the banner with a message and up to three actions.
-- @param colour   accent colour (AARRGGBB)
-- @param message  markup
-- @param list     { { label, action }, ... }
local function show(colour, message, list)
    -- Entries may be nil (an action that doesn't apply right now).
    actions = {}
    for i = 1, 3 do
        if list and list[i] then
            actions[#actions + 1] = list[i]
        end
    end

    gitgud.setVisible("NoticeBar", true)
    gitgud.setProperty("NoticeAccent", "PanelColour", colour)
    gitgud.setText("NoticeText", message)

    for i = 1, 3 do
        local button = "NoticeButton" .. i
        local action = actions[i]
        gitgud.setVisible(button, action ~= nil)
        if action then
            gitgud.setText(button, text.escape(action.label))
        end
    end

    if not showing then
        showing = true
        frame.setBand("notice", HEIGHT)
    end
end

--- Hide the banner.
local function hide()
    actions = {}
    if not showing then
        return
    end

    showing = false
    gitgud.setVisible("NoticeBar", false)
    frame.setBand("notice", 0)
end

--- Abort the operation in progress, after confirming.
-- @param what  "merge" | "rebase" | "cherry-pick" | "revert"
local function abort(what)
    dialog.confirm("Abort the " .. what .. "?",
        "Your working tree goes back to how it was before the " .. what .. " started.",
        "Abort " .. what,
        function()
            status.report("Aborted the " .. what .. ".", gitgud.abortOperation())
            app.requestRefresh()
        end,
        true)
end

--- Continue a paused rebase.
local function continueRebase()
    local result, err = gitgud.continueRebase()
    if not result then
        status.error(err or "Could not continue the rebase.")
    elseif result.kind == "conflicts" then
        status.warn(result.message)
    else
        status.ok(result.message)
    end
    app.requestRefresh()
end

--- Pick the banner for a snapshot.
-- @param state  repository snapshot
function notice.refresh(state)
    if not state.open then
        hide()
        return
    end

    local conflicts = #state.conflicts
    local mergeTool = {
        label = "Open merge tool",
        action = function()
            require("views.mergetool").open(state.conflicts[1])
        end,
    }
    local conflictText = conflicts > 0
        and text.colour(C.err, "  " .. text.plural(conflicts, "conflicted file") .. " to resolve.")
        or text.colour(C.dim, "  All conflicts resolved.")

    if state.operation == "merge" then
        show(C.warn, text.colour(C.text, "Merge in progress.") .. conflictText
            .. text.colour(C.dim, conflicts == 0 and "  Commit to finish it." or ""),
            {
                conflicts > 0 and mergeTool or nil,
                {
                    label = "Abort merge",
                    action = function()
                        abort("merge")
                    end,
                },
            })
    elseif state.operation == "rebase" then
        show(C.purple, text.colour(C.text, "Rebase in progress.") .. conflictText, {
            conflicts > 0 and mergeTool or { label = "Continue rebase", action = continueRebase },
            {
                label = "Abort rebase",
                action = function()
                    abort("rebase")
                end,
            },
        })
    elseif state.operation == "cherrypick" or state.operation == "revert" then
        local what = state.operation == "revert" and "revert" or "cherry-pick"
        show(C.warn, text.colour(C.text, "A " .. what .. " is in progress.") .. conflictText
            .. text.colour(C.dim, conflicts == 0 and "  Commit to finish it." or ""),
            {
                conflicts > 0 and mergeTool or nil,
                {
                    label = "Abort " .. what,
                    action = function()
                        abort(what)
                    end,
                },
            })
    elseif state.detached then
        show(C.blue, text.colour(C.text, "You're on a detached HEAD at " .. state.headOid:sub(1, 7) .. ".")
            .. text.colour(C.dim, "  New commits won't belong to any branch."), {
            {
                label = "Create branch here",
                action = function()
                    local branches = require("views.branches")
                    branches.create()
                end,
            },
        })
    else
        hide()
    end
end

--- Wire the banner buttons.
function notice.init()
    for i = 1, 3 do
        gitgud.on("NoticeButton" .. i .. ".clicked", function()
            local action = actions[i]
            if action then
                action.action()
            end
        end)
    end
end

return notice
