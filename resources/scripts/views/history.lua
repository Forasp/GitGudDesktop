--- views/history.lua — the History tab.
--
-- A two-line row per commit (summary with branch/tag labels, then author
-- and age), a filter box, "load more" paging, and a branch comparison mode
-- (commits the other branch has that you don't — "behind" — or the reverse
-- — "ahead"). Selecting a commit shows it via views/commitview.lua;
-- right-clicking offers revert, cherry-pick, branch/tag from here, reset,
-- checkout, and copy actions.
--
-- Public API: history.compareWith(branch), history.stopCompare(),
--             history.reload(), history.showCommit(commit),
--             history.commitMenu(commit) (shared with the commit graph)

local C = require("core.palette")
local app = require("core.app")
local commitview = require("views.commitview")
local content = require("views.content")
local dialog = require("ui.dialog")
local diff = require("views.diff")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local shell = require("core.shell")
local sidebar = require("views.sidebar")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")

local history = { name = "history" }

local PAGE = 300

local commits = {}         -- everything loaded (unfiltered)
local shown = {}           -- the filtered rows, in list order
local labelsByOid = {}     -- oid -> { {name, kind}, ... }
local loadedFor = nil      -- the HEAD/compare state `commits` was loaded for
local limit = PAGE
local filterText = ""
local selectedOid = nil
local compare = nil        -- { branch, direction = "behind" | "ahead", ahead, behind }

--- Index ref labels (branches, tags) by the commit they point at.
local function loadLabels()
    labelsByOid = {}

    for _, label in ipairs(gitgud.refLabels()) do
        labelsByOid[label.oid] = labelsByOid[label.oid] or {}
        table.insert(labelsByOid[label.oid], label)
    end
end

--- The coloured [branch] [tag] badges for a commit.
-- @param oid  commit id
-- @return markup ("" when unlabelled)
local function badges(oid)
    local out = ""

    for _, label in ipairs(labelsByOid[oid] or {}) do
        local colour = C.cyan
        if label.kind == "tag" then
            colour = C.yellow
        elseif label.kind == "remote" then
            colour = C.purple
        elseif label.kind == "head" then
            colour = C.pink
        end
        out = out .. " " .. text.colour(colour, "[" .. label.name .. "]")
    end

    return out
end

--- One list row: summary + badges, then "author · age · sha".
-- @param commit  history row
-- @return markup
local function commitRow(commit)
    local merge = #(commit.parents or {}) > 1
    local dot = text.colour(merge and C.purple or C.cyan, merge and "◆ " or "● ")

    return text.rowHeight(22) .. dot .. text.colour(C.text, commit.summary) .. badges(commit.oid) .. "\n"
        .. text.colour(C.dim, "    " .. commit.author .. " · " .. text.ago(commit.time)
            .. " · " .. commit.shortOid)
end

--- Does a commit match the filter box?
-- @param commit  history row
-- @return boolean
local function matches(commit)
    if filterText == "" then
        return true
    end

    return text.contains(commit.summary, filterText)
        or text.contains(commit.author, filterText)
        or text.contains(commit.email, filterText)
        or commit.oid:sub(1, #filterText):lower() == filterText:lower()
end

--- The query for the current mode (plain history or a comparison).
-- @return gitgud.history argument table
local function query()
    if compare and compare.direction == "behind" then
        return { max = limit, from = compare.branch, hide = "HEAD" }
    end
    if compare then
        return { max = limit, from = "HEAD", hide = compare.branch }
    end

    return { max = limit }
end

--- Fill the list from `commits` through the filter.
local function renderList()
    shown = {}
    local rows = {}

    for _, commit in ipairs(commits) do
        if matches(commit) then
            shown[#shown + 1] = commit
            rows[#rows + 1] = commitRow(commit)
        end
    end

    if #rows == 0 then
        rows[1] = text.colour(C.dim, compare and "No commits in this direction." or "No matching commits.")
    end

    gitgud.setList("HistoryList", rows)
    gitgud.setVisible("HistoryMoreButton", #commits >= limit and not compare)
end

--- Show one commit in the content pane.
-- @param commit  history row
local function showCommit(commit)
    selectedOid = commit.oid

    local files, err = gitgud.commitDiff(commit.oid, diff.queryOptions())
    if not files then
        status.error(err or "Could not read that commit.")
        return
    end

    local summary, body = text.splitMessage(commit.message)
    local added = 0
    local removed = 0
    for _, file in ipairs(files) do
        local a, r = diff.stats(file)
        added = added + a
        removed = removed + r
    end

    local firstBodyLine = body:match("^[^\n]*") or ""
    commitview.show({
        summary = summary,
        body = firstBodyLine,
        meta = commit.author .. " <" .. commit.email .. ">  ·  "
            .. os.date("%Y-%m-%d %H:%M", commit.time) .. "  ·  " .. commit.shortOid
            .. "  ·  " .. text.plural(#files, "file") .. "  +" .. added .. " −" .. removed,
        oid = commit.oid,
        files = files,
    })
end

--- Show a commit's header, files, and diff in the content pane (used by the
-- commit graph too).
-- @param commit  a gitgud.history() / gitgud.graph() row
function history.showCommit(commit)
    showCommit(commit)
end

--- Reload the commit list (only when HEAD, refs, or the comparison moved).
-- @param force  reload even if nothing seems to have changed
function history.reload(force)
    local state = repo.state()
    local key = state.headOid .. "|" .. (compare and (compare.branch .. compare.direction) or "") .. "|" .. limit

    if not force and key == loadedFor then
        return
    end
    loadedFor = key

    if not state.open then
        commits = {}
        renderList()
        return
    end

    loadLabels()
    commits = gitgud.history(query())
    renderList()

    -- Keep the selection when the commit is still listed; else pick the top.
    for i, commit in ipairs(shown) do
        if commit.oid == selectedOid then
            gitgud.selectListItem("HistoryList", i)
            return
        end
    end
    if shown[1] and sidebar.tab() == "history" and not require("views.frame").graphMode() then
        gitgud.selectListItem("HistoryList", 1)
        showCommit(shown[1])
    end
end

--- Paint the comparison bar.
local function paintCompare()
    local comparing = compare ~= nil

    gitgud.setVisible("CompareBar", comparing)
    gitgud.setVisible("CompareMergeButton", comparing and compare.direction == "behind" and compare.behind > 0)

    if not comparing then
        gitgud.setText("CompareButton", "Compare with a branch…")
        gitgud.setProperty("HistoryHairline", "Area", "{{0,0},{0,76},{1,0},{0,77}}")
        gitgud.setProperty("HistoryList", "Area", "{{0,0},{0,77},{1,0},{1,-44}}")
        return
    end

    gitgud.setText("CompareButton", text.colour(C.text, "Comparing with " .. compare.branch)
        .. text.colour(C.dim, "   (click to stop)"))
    gitgud.setText("CompareBehindTab", text.escape(compare.behind .. " behind"))
    gitgud.setText("CompareAheadTab", text.escape(compare.ahead .. " ahead"))

    local behindActive = compare.direction == "behind"
    gitgud.setProperty("CompareBehindTab", "NormalFillColour", behindActive and C.bg4 or C.bg2)
    gitgud.setProperty("CompareAheadTab", "NormalFillColour", behindActive and C.bg2 or C.bg4)
    gitgud.setProperty("HistoryHairline", "Area", "{{0,0},{0,110},{1,0},{0,111}}")
    gitgud.setProperty("HistoryList", "Area", "{{0,0},{0,111},{1,0},{1,-44}}")
end

--- Compare the current branch with another one.
-- @param branch  branch name
function history.compareWith(branch)
    local counts = gitgud.compareBranch(branch)

    compare = {
        branch = branch,
        direction = (counts.behind or 0) > 0 and "behind" or "ahead",
        ahead = counts.ahead or 0,
        behind = counts.behind or 0,
    }
    selectedOid = nil
    sidebar.select("history")
    paintCompare()
    history.reload(true)
end

--- Leave comparison mode.
function history.stopCompare()
    compare = nil
    paintCompare()
    history.reload(true)
end

--- Right-click menu for a commit (History list and the commit graph).
-- @param commit  history row
-- @return item list
function history.commitMenu(commit)
    local state = repo.state()
    local isHead = commit.oid == state.headOid
    local tags = {}
    for _, label in ipairs(labelsByOid[commit.oid] or {}) do
        if label.kind == "tag" then
            tags[#tags + 1] = label.name
        end
    end

    local items = {
        {
            label = "Revert changes in commit",
            action = function()
                local oid, err = undo.track("Revert " .. commit.shortOid, function()
                    return gitgud.revert(commit.oid)
                end)
                if oid == nil then
                    status.error(err or "Revert failed.")
                elseif oid == "" then
                    status.warn("The revert has conflicts. Resolve them, then commit.")
                else
                    status.ok("Reverted " .. commit.shortOid .. ".")
                end
                app.requestRefresh()
            end,
        },
        {
            label = "Cherry-pick onto current branch",
            enabled = not isHead,
            action = function()
                local oid, err = undo.track("Cherry-pick " .. commit.shortOid, function()
                    return gitgud.cherryPick(commit.oid)
                end)
                if oid == nil then
                    status.error(err or "Cherry-pick failed.")
                elseif oid == "" then
                    status.warn("The cherry-pick has conflicts. Resolve them, then commit.")
                else
                    status.ok("Cherry-picked " .. commit.shortOid .. ".")
                end
                app.requestRefresh()
            end,
        },
        { separator = true },
        {
            label = "Create branch from commit…",
            action = function()
                dialog.prompt("Create a branch from " .. commit.shortOid, "Branch name", "", "Create branch",
                    function(name)
                        if name == "" then
                            return false, "Enter a branch name."
                        end
                        local ok, err = undo.track("Create branch " .. name, function()
                            local created, createErr = gitgud.createBranch(name, commit.oid)
                            if not created then
                                return created, createErr
                            end
                            status.report("Created and switched to " .. name .. ".", gitgud.checkout(name))
                            return true
                        end)
                        if not ok then
                            return false, err
                        end
                        app.requestRefresh()
                        return true
                    end)
            end,
        },
        {
            label = "Create tag…",
            action = function()
                dialog.show({
                    title = "Create a tag on " .. commit.shortOid,
                    fields = {
                        { label = "Tag name", value = "" },
                        { label = "Message (optional — makes an annotated tag)", value = "" },
                    },
                    ok = "Create tag",
                    onOk = function(v)
                        local name = text.trim(v.fields[1])
                        if name == "" then
                            return false, "Enter a tag name."
                        end
                        local ok, err = gitgud.createTag(name, commit.oid, text.trim(v.fields[2]))
                        if not ok then
                            return false, err
                        end
                        status.ok("Created tag " .. name .. ". Push tags from the Repository menu.")
                        history.reload(true)
                        return true
                    end,
                })
            end,
        },
    }

    for _, tag in ipairs(tags) do
        items[#items + 1] = {
            label = "Delete tag " .. tag .. "…",
            action = function()
                dialog.confirm("Delete tag " .. tag .. "?",
                    "The tag is removed locally. Tags already pushed stay on the remote.",
                    "Delete tag",
                    function()
                        status.report("Deleted tag " .. tag .. ".", gitgud.deleteTag(tag))
                        history.reload(true)
                    end,
                    true)
            end,
        }
    end

    items[#items + 1] = { separator = true }
    items[#items + 1] = {
        label = "Reset to commit…",
        enabled = not isHead,
        action = function()
            dialog.confirm("Reset " .. (state.branch ~= "" and state.branch or "HEAD") .. " to " .. commit.shortOid .. "?",
                "Commits after this one are removed from the branch. Their changes stay in your "
                    .. "working tree as uncommitted changes.",
                "Reset branch",
                function()
                    status.report("Reset to " .. commit.shortOid .. ".", undo.track("Reset to " .. commit.shortOid,
                        function()
                            return gitgud.resetTo(commit.oid, "mixed")
                        end))
                    app.requestRefresh()
                end,
                true)
        end,
    }
    items[#items + 1] = {
        label = "Checkout commit",
        enabled = not isHead,
        action = function()
            dialog.confirm("Check out " .. commit.shortOid .. "?",
                "You'll be on a detached HEAD: new commits won't belong to any branch until you "
                    .. "create one.",
                "Checkout",
                function()
                    status.report("Checked out " .. commit.shortOid .. " (detached HEAD).",
                        undo.track("Checkout " .. commit.shortOid, function()
                            return gitgud.checkoutCommit(commit.oid)
                        end))
                    app.requestRefresh()
                end)
        end,
    }
    items[#items + 1] = {
        label = "Interactive rebase from here…",
        enabled = not isHead and state.branch ~= "",
        action = function()
            require("views.rebase").open(commit.oid)
        end,
    }
    items[#items + 1] = { separator = true }
    items[#items + 1] = {
        label = "Copy SHA",
        action = function()
            shell.copy(commit.oid, "SHA")
        end,
    }
    items[#items + 1] = {
        label = "Copy summary",
        action = function()
            shell.copy(commit.summary, "summary")
        end,
    }

    return items
end

--- Refresh from a new snapshot.
-- @param state  repository snapshot
function history.refresh(state)
    if compare then
        local counts = gitgud.compareBranch(compare.branch)
        compare.ahead = counts.ahead or 0
        compare.behind = counts.behind or 0
        paintCompare()
    end

    if sidebar.tab() == "history" then
        history.reload(false)
    end
end

--- Wire the History widgets.
function history.init()
    placeholder.bind("HistoryFilterEdit", "HistoryFilterPlaceholder")

    gitgud.on("HistoryFilterEdit.changed", function(value)
        filterText = text.trim(value)
        renderList()
    end)

    gitgud.on("HistoryList.selected", function(value)
        local row = tonumber(value)
        local commit = row and shown[row + 1]
        if commit then
            showCommit(commit)
        end
    end)

    gitgud.on("HistoryList.rightClicked", function(value)
        local x, y, row = menu.parseClick(value)
        local commit = row and shown[row]
        if commit then
            gitgud.selectListItem("HistoryList", row)
            showCommit(commit)
            menu.popup(history.commitMenu(commit), x, y)
        end
    end)

    gitgud.on("HistoryMoreButton.clicked", function()
        limit = limit + PAGE
        history.reload(true)
    end)

    gitgud.on("CompareButton.clicked", function()
        if compare then
            history.stopCompare()
            return
        end
        local branches = require("views.branches")
        branches.pick("Compare with", history.compareWith)
    end)

    gitgud.on("CompareBehindTab.clicked", function()
        if compare then
            compare.direction = "behind"
            paintCompare()
            history.reload(true)
        end
    end)

    gitgud.on("CompareAheadTab.clicked", function()
        if compare then
            compare.direction = "ahead"
            paintCompare()
            history.reload(true)
        end
    end)

    gitgud.on("CompareMergeButton.clicked", function()
        if compare then
            local branches = require("views.branches")
            branches.merge(compare.branch)
        end
    end)

    app.subscribe("tab.changed", function(tab)
        if tab == "history" then
            history.reload(false)
            local current = nil
            for _, commit in ipairs(shown) do
                if commit.oid == selectedOid then
                    current = commit
                end
            end
            current = current or shown[1]
            if current then
                showCommit(current)
            else
                content.arrange("plain")
                content.setTitle("")
                content.showEmpty({ title = "No commits yet", body = "Commits you make will show up here." })
            end
        end
    end)

    app.subscribe("diff.optionsChanged", function()
        if sidebar.tab() == "history" and selectedOid then
            for _, commit in ipairs(shown) do
                if commit.oid == selectedOid then
                    showCommit(commit)
                end
            end
        end
    end)
end

return history
