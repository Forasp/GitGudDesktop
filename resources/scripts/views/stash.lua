--- views/stash.lua — stash your changes, look at them, bring them back.
--
-- The UI works with the stash of the CURRENT branch:
-- "Stash all changes" saves everything (untracked files included) with a
-- branch-tagged message, the Changes tab then shows a "Stashed changes" row,
-- and viewing it offers Restore (pop) or Discard (drop).
--
-- Public API: stash.stashAll(), stash.view(), stash.restore(),
--             stash.discard(), stash.viewing(), stash.latest()

local app = require("core.app")
local commitview = require("views.commitview")
local dialog = require("ui.dialog")
local repo = require("core.repo")
local status = require("core.status")
local text = require("core.text")

local stash = { name = "stash" }

local viewing = false
local viewedOid = nil      -- the stash being shown

--- The newest stash taken on the current branch, or nil.
-- @return stash row { index, message, oid }
function stash.latest()
    return repo.branchStashes()[1]
end

--- True while the stash is shown in the content pane.
-- @return boolean
function stash.viewing()
    return viewing
end

--- Stop showing the stash (the Changes view takes the pane back).
function stash.close()
    if not viewing then
        return
    end

    viewing = false
    commitview.clear()
    app.publish("stash.closed")
end

--- Save every change (including untracked files) into a stash.
-- @return true when they were stashed
function stash.stashAll()
    local state = repo.state()
    if #state.files == 0 then
        status.warn("There are no changes to stash.")
        return
    end

    local message = "gitgud: changes on " .. (state.branch ~= "" and state.branch or "detached HEAD")
    local ok, err = gitgud.stashSave(message)
    if status.report("Stashed your changes.", ok, err) then
        app.requestRefresh()
        return true
    end
    return false
end

--- Apply and drop the newest branch stash.
function stash.restore()
    local entry = stash.latest()
    if not entry then
        status.warn("This branch has no stashed changes.")
        return
    end

    local ok, err = gitgud.stashPop(entry.index)
    if status.report("Restored your stashed changes.", ok, err) then
        stash.close()
        app.requestRefresh()
    end
end

--- Drop the newest branch stash, after confirming.
function stash.discard()
    local entry = stash.latest()
    if not entry then
        return
    end

    dialog.confirm("Discard stash?",
        "The stashed changes will be permanently deleted. This can't be undone.",
        "Discard stash",
        function()
            local ok, err = gitgud.stashDrop(entry.index)
            if status.report("Discarded the stash.", ok, err) then
                stash.close()
                app.requestRefresh()
            end
        end,
        true)
end

--- Show the newest branch stash in the content pane.
function stash.view()
    local entry = stash.latest()
    if not entry then
        return
    end

    local files, err = gitgud.stashDiff(entry.index)
    if not files then
        status.error(err or "Could not read the stash.")
        return
    end

    viewing = true
    viewedOid = entry.oid
    local state = repo.state()
    commitview.show({
        summary = "Stashed changes",
        body = "Restore them to continue where you left off, or discard them.",
        meta = text.plural(#files, "file") .. " · stashed on " .. state.branch,
        oid = entry.oid,
        files = files,
        actions = {
            { label = "Restore", action = stash.restore },
            { label = "Discard", action = stash.discard },
        },
    })
end

--- Show any stash (the branch tree lists all of them), with Apply / Pop.
-- @param entry  stash row { index, message, oid }
function stash.viewEntry(entry)
    local files, err = gitgud.stashDiff(entry.index)
    if not files then
        status.error(err or "Could not read the stash.")
        return
    end

    require("views.frame").setGraph(false)
    require("views.sidebar").select("changes")
    viewing = true
    viewedOid = entry.oid
    commitview.show({
        summary = entry.message:gsub("^gitgud: ", ""),
        body = "Apply keeps the stash; Pop applies it and deletes it.",
        meta = text.plural(#files, "file") .. " · stash@{" .. (entry.index - 1) .. "}",
        oid = entry.oid,
        files = files,
        actions = {
            {
                label = "Apply",
                action = function()
                    if status.report("Applied the stash.", gitgud.stashApply(entry.index)) then
                        stash.close()
                        app.requestRefresh()
                    end
                end,
            },
            {
                label = "Pop",
                action = function()
                    if status.report("Restored the stash.", gitgud.stashPop(entry.index)) then
                        stash.close()
                        app.requestRefresh()
                    end
                end,
            },
        },
    })
end

--- Close the viewer when the stash it shows disappears.
-- @param state  repository snapshot
function stash.refresh(state)
    if not viewing then
        return
    end
    for _, entry in ipairs(state.stashes) do
        if entry.oid == viewedOid then
            return
        end
    end
    stash.close()
end

return stash
