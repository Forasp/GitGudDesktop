--- views/changes.lua — the Changes tab.
--
-- Left column, top to bottom: the file filter, the "N changed files"
-- include-all checkbox, one row per changed file, optional info rows
-- (stashed changes / undo last commit), and the commit box.
--
-- The file rows are one list (ChangesList): an include box (an inline
-- sprite — clicking its column stages/unstages the whole file), a coloured
-- status letter, and the name with its folder dimmed. Clicking elsewhere on
-- a row shows its diff; double-click opens it in your editor; right-click
-- for the file menu. Refreshes only rewrite rows whose text changed.
--
-- Public API (menus, shortcuts):
--   changes.commit()  changes.discardAll()  changes.undoLastCommit()
--   changes.focusFilter()  changes.selectedPath()

local C = require("core.palette")
local app = require("core.app")
local content = require("views.content")
local dialog = require("ui.dialog")
local geometry = require("ui.geometry")
local keys = require("core.keys")
local menu = require("ui.menu")
local placeholder = require("ui.placeholder")
local repo = require("core.repo")
local settings = require("core.settings")
local shell = require("core.shell")
local sidebar = require("views.sidebar")
local stash = require("views.stash")
local status = require("core.status")
local text = require("core.text")
local undo = require("core.undo")

local changes = { name = "changes" }

local ROW_HEIGHT = 32
local CHECK_COLUMN = 36       -- px from the list's left edge that toggle inclusion
local NAME_BUDGET = 32        -- characters of "name  dir" that fit a row
local SUMMARY_LIMIT = 50
local COMMIT_BOX_HEIGHT = 212
local INFO_ROW_HEIGHT = 36
local LIST_TOP = 76

local selectedPath = nil
local visibleFiles = {}       -- the filtered rows, in display order
local rowTexts = {}           -- what each list row currently shows
local filterText = ""
local lastCommit = nil        -- { oid, summary } for the Undo row

--- Colour of a status letter.
-- @param code  "A" | "?" | "D" | "M" | "R" | "U"
-- @return AARRGGBB
local function codeColour(code)
    if code == "A" or code == "?" then
        return C.add
    end
    if code == "D" then
        return C.del
    end
    if code == "U" then
        return C.err
    end
    if code == "R" then
        return C.blue
    end

    return C.warn
end

--- "name  —  folder" markup that fits in a row (long folders lose their
-- front, which is the least informative part).
-- @param path  repository-relative path
-- @return markup
local function rowLabel(path)
    local name = text.basename(path)
    local dir = text.dirname(path)

    if dir == "" then
        return text.colour(C.text, name)
    end

    local room = NAME_BUDGET - #name - 3
    if room < 6 then
        return text.colour(C.text, name)
    end
    if #dir > room then
        dir = "…" .. dir:sub(#dir - room + 2)
    end

    return text.colour(C.text, name) .. text.colour(C.dim, "  " .. dir)
end

--- Is this file fully / partly included in the next commit?
-- @param file  status row
-- @return "all" | "some" | "none"
local function inclusion(file)
    if file.staged and not file.unstaged then
        return "all"
    end
    if file.staged then
        return "some"
    end

    return "none"
end

--- The include-box sprite for a file (checked / partial / empty).
-- @param file  status row
-- @return inline image markup
local function checkSprite(file)
    local state = inclusion(file)
    local image = "HunkOff"

    if state == "all" then
        image = "HunkOn"
    elseif state == "some" then
        image = "HunkPart"
    end

    return "[image-size='w:26 h:26'][image='Gitgud-Images/" .. image .. "']"
end

--- One list row: box, status letter, name + folder.
-- @param file  status row
-- @return markup
local function rowText(file)
    local code = file.code == "?" and "A" or file.code

    return text.rowHeight(ROW_HEIGHT) .. " " .. checkSprite(file) .. "  "
        .. "[font='Gitgud-Mono']" .. text.colour(codeColour(file.code), code) .. "[font='Gitgud-UI']   "
        .. rowLabel(file.path)
end

--- Row number of the selected file among the visible rows.
-- @return 1-based row, or nil
local function selectedRow()
    for i, file in ipairs(visibleFiles) do
        if file.path == selectedPath then
            return i
        end
    end

    return nil
end

--- Highlight the selected file's row.
-- @param scrollIntoView  also scroll the list so the row is visible
local function paintSelection(scrollIntoView)
    gitgud.selectListItem("ChangesList", selectedRow(), scrollIntoView)
end

--- Select a file and show its diff.
-- @param path  repository-relative path (nil clears)
function changes.select(path)
    stash.close()
    selectedPath = path
    paintSelection(false)

    local file = repo.file(path)
    if file and file.code == "U" then
        require("views.mergetool").open(path)
        return
    end
    changes.showContent(true)
end

--- Stage or unstage one whole file.
-- @param file     status row
-- @param include  true to include it in the next commit
local function setIncluded(file, include)
    local ok = nil
    local err = nil

    if include then
        ok, err = gitgud.stage(file.path)
    else
        ok, err = gitgud.unstage(file.path)
    end

    status.report(nil, ok, err)
end

--- Absolute path of a repository file.
-- @param path  repository-relative path
-- @return absolute path
local function absolute(path)
    return repo.state().path .. "/" .. path
end

--- Throw away a file's changes, after confirming (if enabled in Options).
-- @param paths  array of repository-relative paths
local function discard(paths)
    --- Do the discard.
    local function run()
        local ok, err = gitgud.discard(paths)
        if status.report("Discarded changes to " .. text.plural(#paths, "file") .. ".", ok, err) then
            app.requestRefresh()
        end
    end

    if not settings.get("confirmDiscard", true) then
        run()
        return
    end

    local what = #paths == 1 and ("'" .. paths[1] .. "'") or text.plural(#paths, "file")
    dialog.confirm("Discard changes?",
        "Your changes to " .. what .. " will be thrown away. New files go to the Recycle Bin; "
            .. "edits to tracked files can't be recovered.",
        "Discard changes", run, true)
end

--- Build the right-click menu for a file.
-- @param file  status row
-- @return item list for menu.popup
local function fileMenu(file)
    local path = file.path
    local ext = text.extension(path)
    local isNew = file.code == "?" or file.code == "A"
    local items = {}

    if file.code == "U" then
        items[#items + 1] = {
            label = "Open merge tool",
            action = function()
                require("views.mergetool").open(path)
            end,
        }
        items[#items + 1] = {
            label = "Resolve using mine",
            action = function()
                status.report("Kept your version of " .. path .. ".", gitgud.resolveConflict(path, "ours"))
            end,
        }
        items[#items + 1] = {
            label = "Resolve using theirs",
            action = function()
                status.report("Took their version of " .. path .. ".", gitgud.resolveConflict(path, "theirs"))
            end,
        }
        items[#items + 1] = {
            label = "Mark as resolved",
            action = function()
                status.report("Marked " .. path .. " as resolved.", gitgud.stage(path))
            end,
        }
        items[#items + 1] = { separator = true }
    end

    items[#items + 1] = {
        label = "Discard changes…",
        action = function()
            discard({ path })
        end,
    }

    if isNew then
        items[#items + 1] = {
            label = "Ignore file (add to .gitignore)",
            action = function()
                status.report("Ignoring " .. path .. ".", gitgud.ignore(path))
            end,
        }
        if ext ~= "" then
            items[#items + 1] = {
                label = "Ignore all ." .. ext .. " files",
                action = function()
                    status.report("Ignoring *." .. ext .. " files.", gitgud.ignore("*." .. ext))
                end,
            }
        end
    end

    if not isNew then
        items[#items + 1] = { separator = true }
        items[#items + 1] = {
            label = "Show file history",
            action = function()
                require("views.inspector").history(path)
            end,
        }
        items[#items + 1] = {
            label = "Blame",
            enabled = file.code ~= "D",
            action = function()
                require("views.inspector").blame(path, "workdir")
            end,
        }
    end
    if gitgud.lfsAvailable() and ext ~= "" then
        items[#items + 1] = {
            label = "Track all ." .. ext .. " files with Git LFS",
            action = function()
                require("views.lfs").track("*." .. ext)
            end,
        }
    end

    items[#items + 1] = { separator = true }
    items[#items + 1] = {
        label = "Copy file path",
        action = function()
            shell.copy(absolute(path), "path")
        end,
    }
    items[#items + 1] = {
        label = "Copy relative file path",
        action = function()
            shell.copy(path, "path")
        end,
    }
    items[#items + 1] = { separator = true }
    items[#items + 1] = {
        label = "Show in Explorer",
        action = function()
            shell.showInFolder(absolute(path))
        end,
    }
    items[#items + 1] = {
        label = "Open in external editor",
        enabled = file.code ~= "D",
        action = function()
            shell.openInEditor(absolute(path))
        end,
    }
    items[#items + 1] = {
        label = "Open with default program",
        enabled = file.code ~= "D",
        action = function()
            shell.openDefault(absolute(path))
        end,
    }

    return items
end

--- Files matching the filter box.
-- @param files  all status rows
-- @return filtered array
local function applyFilter(files)
    if filterText == "" then
        return files
    end

    local out = {}
    for _, file in ipairs(files) do
        if text.contains(file.path, filterText) then
            out[#out + 1] = file
        end
    end

    return out
end

--- Rebuild the file rows from the snapshot. When the same files are shown
-- in the same order (the usual case: something got staged), only rows whose
-- text changed are rewritten, so the list keeps its scroll position.
-- @param state  repository snapshot
local function renderRows(state)
    local files = applyFilter(state.files)
    local texts = {}
    for i, file in ipairs(files) do
        texts[i] = rowText(file)
    end

    local samePaths = #files == #visibleFiles
    if samePaths then
        for i, file in ipairs(files) do
            if visibleFiles[i].path ~= file.path then
                samePaths = false
                break
            end
        end
    end

    visibleFiles = files
    if samePaths then
        for i, rowMarkup in ipairs(texts) do
            if rowTexts[i] ~= rowMarkup then
                gitgud.setListItem("ChangesList", i, rowMarkup)
            end
        end
    else
        gitgud.setList("ChangesList", texts)
    end
    rowTexts = texts
    paintSelection(false)

    local empty = #files == 0 and #state.files > 0
    gitgud.setVisible("ChangesEmptyLabel", empty)
    gitgud.setText("ChangesEmptyLabel", empty and text.escape("No files match '" .. filterText .. "'") or "")
end

--- The include-all checkbox: label and checked state.
-- @param state  repository snapshot
local function renderIncludeAll(state)
    local total = #state.files
    local all = total > 0

    for _, file in ipairs(state.files) do
        if inclusion(file) ~= "all" then
            all = false
        end
    end

    gitgud.setText("IncludeAllCheck", text.plural(total, "changed file"))
    gitgud.setChecked("IncludeAllCheck", all)
    gitgud.setEnabled("IncludeAllCheck", total > 0)
end

--- Stack the visible info rows above the commit box and size the list.
-- @param state  repository snapshot
local function layoutInfoRows(state)
    local rows = {}

    local stashed = stash.latest()
    gitgud.setVisible("StashRow", stashed ~= nil)
    if stashed then
        gitgud.setText("StashRowText", text.colour(C.text, "Stashed changes"))
        rows[#rows + 1] = "StashRow"
    end

    local showUndo = lastCommit ~= nil and lastCommit.oid == state.headOid
    gitgud.setVisible("UndoRow", showUndo)
    if showUndo then
        gitgud.setText("UndoRowText", text.colour(C.dim, "Committed ")
            .. text.colour(C.text, lastCommit.summary))
        rows[#rows + 1] = "UndoRow"
    end

    local bottom = COMMIT_BOX_HEIGHT
    for _, name in ipairs(rows) do
        gitgud.setProperty(name, "Area", geometry.area(0, 0, 1, -bottom - INFO_ROW_HEIGHT, 1, 0, 1, -bottom))
        bottom = bottom + INFO_ROW_HEIGHT
    end

    gitgud.setProperty("ChangesList", "Area", geometry.area(0, 0, 0, LIST_TOP, 1, 0, 1, -bottom))
end

--- Summary character counter (turns yellow, then red, near the limit).
local function updateSummaryCount()
    local summary = gitgud.getText("SummaryEdit")
    local left = SUMMARY_LIMIT - #summary

    if #summary == 0 then
        gitgud.setText("SummaryCount", "")
        return
    end

    local colour = C.dim
    if left < 0 then
        colour = C.err
    elseif left <= 10 then
        colour = C.warn
    end
    gitgud.setText("SummaryCount", text.colour(colour, tostring(left)))
end

--- Enable/label the commit button for the current state.
-- @param state  repository snapshot
local function updateCommitButton(state)
    local anyStaged = false
    for _, file in ipairs(state.files) do
        if file.staged then
            anyStaged = true
        end
    end

    local amend = gitgud.getProperty("AmendCheck", "Selected") == "true"
    local conflicts = #state.conflicts > 0
    local label = "Commit to " .. (state.branch ~= "" and state.branch or "HEAD")

    if amend then
        label = "Amend last commit"
    elseif state.operation == "merge" then
        label = "Commit merge"
    end

    local enabled = state.open and not conflicts and (anyStaged or amend or state.operation == "merge")
    gitgud.setText("CommitButton", text.escape(label))
    gitgud.setEnabled("CommitButton", enabled)
    gitgud.setVisible("CommitGlow", enabled)
    gitgud.setProperty("CommitButton", "TooltipText",
        conflicts and "Resolve the conflicted files first" or "Commit the included changes  (Ctrl+Enter)")
end

--- Show what the content pane should hold on the Changes tab.
-- @param force  re-render even if unchanged
function changes.showContent(force)
    if sidebar.tab() ~= "changes" or stash.viewing() or require("views.frame").graphMode()
        or require("views.content").overlayOpen() then
        return
    end

    local state = repo.state()
    content.arrange("plain")

    if not state.open then
        content.setTitle("")
        local repositories = require("views.repositories")
        content.showEmpty({
            title = "No repository open",
            body = "Open a repository you already have on disk, clone one, or create a new one. "
                .. "You can also drop a folder onto this window.",
            actions = {
                { label = "Add an existing repository…", action = repositories.addExisting, primary = true },
                { label = "Clone a repository…", action = repositories.clone },
                { label = "Create a new repository…", action = repositories.create },
            },
        })
        return
    end

    if #state.files == 0 then
        content.setTitle(text.colour(C.dim, "No local changes"))
        local sync = require("views.sync")
        local actions = {}
        local ab = state.aheadBehind

        if ab.hasUpstream and (ab.ahead or 0) > 0 then
            actions[#actions + 1] = {
                label = "Push " .. text.plural(ab.ahead, "commit") .. " to " .. (repo.upstreamRemote() or "origin"),
                action = sync.push,
                primary = true,
            }
        elseif not ab.hasUpstream and state.branch ~= "" and repo.primaryRemote() and state.headOid ~= "" then
            actions[#actions + 1] = { label = "Publish branch", action = sync.push, primary = true }
        end

        actions[#actions + 1] = {
            label = "Open in terminal",
            action = function()
                shell.openTerminal(state.path)
            end,
        }
        actions[#actions + 1] = {
            label = "Show in Explorer",
            action = function()
                shell.showInFolder(state.path)
            end,
        }

        content.showEmpty({
            title = "No local changes",
            body = "There are no uncommitted changes in this repository. Here are some "
                .. "friendly suggestions for what to do next.",
            actions = actions,
        })
        return
    end

    if not selectedPath or not repo.file(selectedPath) then
        selectedPath = visibleFiles[1] and visibleFiles[1].path or state.files[1].path
        paintSelection(true)
    end

    content.showWorkingFile(selectedPath, force)
end

--- Commit (or amend) with the message in the commit box.
function changes.commit()
    local state = repo.state()
    local summary = text.trim(gitgud.getText("SummaryEdit"))
    local description = text.trim(gitgud.getText("DescriptionEdit"))
    local amend = gitgud.getProperty("AmendCheck", "Selected") == "true"

    if not state.open then
        return
    end
    if summary == "" then
        status.warn("A commit summary is required.")
        gitgud.focus("SummaryEdit")
        return
    end
    if #state.conflicts > 0 then
        status.warn("Resolve the conflicted files before committing.")
        return
    end

    local message = summary
    if description ~= "" then
        message = summary .. "\n\n" .. description
    end

    local oid = nil
    local err = nil
    local label = (amend and "Amend: " or "Commit: ") .. summary
    oid, err = undo.track(label, function()
        if amend then
            return gitgud.amend(message)
        end
        return gitgud.commit(message)
    end, {
        soft = true,
        onUndo = function()
            -- The message goes back in the box, like "Undo last commit".
            if not amend then
                placeholder.setText("SummaryEdit", summary)
                placeholder.setText("DescriptionEdit", description)
                updateSummaryCount()
            end
        end,
        onRedo = function()
            if gitgud.getText("SummaryEdit") == summary then
                placeholder.setText("SummaryEdit", "")
                placeholder.setText("DescriptionEdit", "")
                updateSummaryCount()
            end
        end,
    })

    if not oid then
        status.error(err or "Commit failed.")
        return
    end

    placeholder.setText("SummaryEdit", "")
    placeholder.setText("DescriptionEdit", "")
    gitgud.setChecked("AmendCheck", false)
    updateSummaryCount()
    selectedPath = nil
    lastCommit = { oid = oid, summary = summary }
    status.ok((amend and "Amended " or "Committed ") .. oid:sub(1, 7) .. ": " .. summary)
    app.requestRefresh()
end

--- Undo the last commit, putting its message back in the commit box.
function changes.undoLastCommit()
    local state = repo.state()
    if state.headOid == "" then
        status.warn("There is no commit to undo.")
        return
    end

    local message, err = undo.track("Undo last commit", function()
        return gitgud.undoCommit()
    end, { soft = true })
    if not message then
        status.error(err or "Could not undo the commit.")
        return
    end

    local summary, body = text.splitMessage(message)
    placeholder.setText("SummaryEdit", summary)
    placeholder.setText("DescriptionEdit", body)
    updateSummaryCount()
    lastCommit = nil
    status.ok("Undid the last commit; its changes are staged again.")
    sidebar.select("changes")
    app.requestRefresh()
end

--- Discard every change in the working tree, after confirming.
function changes.discardAll()
    local paths = {}
    for _, file in ipairs(repo.state().files) do
        paths[#paths + 1] = file.path
    end

    if #paths == 0 then
        status.warn("There are no changes to discard.")
        return
    end
    discard(paths)
end

--- Put the cursor in the filter box.
function changes.focusFilter()
    sidebar.select("changes")
    gitgud.focus("ChangesFilterEdit")
end

--- Forget the rendered rows so the next refresh rebuilds the whole list
-- (used by tests/ui/perf.lua to time a cold paint).
function changes.resetRows()
    visibleFiles = {}
    rowTexts = {}
end

--- The file whose diff is shown.
-- @return path or nil
function changes.selectedPath()
    return selectedPath
end

--- Ask for a co-author and append a Co-authored-by trailer.
local function addCoAuthor()
    dialog.show({
        title = "Add a co-author",
        message = "Adds a Co-authored-by trailer to the commit message.",
        fields = {
            { label = "Name", value = "" },
            { label = "Email", value = "" },
        },
        ok = "Add co-author",
        onOk = function(v)
            local name = text.trim(v.fields[1])
            local email = text.trim(v.fields[2])
            if name == "" or email == "" then
                return false, "Both a name and an email are needed."
            end

            local description = gitgud.getText("DescriptionEdit"):gsub("%s+$", "")
            local trailer = "Co-authored-by: " .. name .. " <" .. email .. ">"
            if description == "" then
                description = "\n\n" .. trailer
            elseif description:find("Co%-authored%-by:") then
                description = description .. "\n" .. trailer
            else
                description = description .. "\n\n" .. trailer
            end
            placeholder.setText("DescriptionEdit", (description:gsub("^\n+", "")))
            return true
        end,
    })
end

--- Checking "Amend" pre-fills the last commit's message when the box is
-- empty, so amending a typo is one edit.
-- @param checked  "1" | "0"
local function onAmendToggled(checked)
    if checked == "1" and gitgud.getText("SummaryEdit") == "" then
        local last = gitgud.history(1)[1]
        if last then
            local summary, body = text.splitMessage(last.message)
            placeholder.setText("SummaryEdit", summary)
            placeholder.setText("DescriptionEdit", body)
            updateSummaryCount()
        end
    end

    updateCommitButton(repo.state())
end

--- Repaint from a fresh snapshot.
-- @param state  repository snapshot
function changes.refresh(state)
    if lastCommit and lastCommit.oid ~= state.headOid then
        lastCommit = nil
    end

    renderRows(state)
    renderIncludeAll(state)
    layoutInfoRows(state)
    updateCommitButton(state)
    gitgud.setEnabled("AmendCheck", state.headOid ~= "" and gitgud.supports("amend"))
    changes.showContent(false)
end

--- Wire the static widgets.
function changes.init()
    placeholder.bind("ChangesFilterEdit", "ChangesFilterPlaceholder")
    placeholder.bind("SummaryEdit", "SummaryPlaceholder")
    placeholder.bind("DescriptionEdit", "DescriptionPlaceholder")

    gitgud.on("ChangesList.clicked", function(value)
        local x, _, row = menu.parseClick(value)
        local file = row and visibleFiles[row]
        if not file then
            return
        end

        local listX = gitgud.getRect("ChangesList")
        if x - listX < CHECK_COLUMN then
            setIncluded(file, inclusion(file) ~= "all")
            paintSelection(false)
        else
            changes.select(file.path)
        end
    end)

    gitgud.on("ChangesList.rightClicked", function(value)
        local x, y, row = menu.parseClick(value)
        local file = row and visibleFiles[row]
        if file then
            changes.select(file.path)
            menu.popup(fileMenu(file), x, y)
        end
    end)

    gitgud.on("ChangesList.doubleClicked", function(value)
        local row = tonumber(value)
        local file = row and visibleFiles[row + 1]
        if file and file.code ~= "D" then
            shell.openInEditor(absolute(file.path))
        end
    end)

    gitgud.on("ChangesFilterEdit.changed", function(value)
        filterText = text.trim(value)
        renderRows(repo.state())
        changes.showContent(false)
    end)

    gitgud.on("IncludeAllCheck.toggled", function(value)
        local paths = {}
        for _, file in ipairs(repo.state().files) do
            paths[#paths + 1] = file.path
        end
        if value == "1" then
            status.report(nil, gitgud.stage(paths))
        else
            status.report(nil, gitgud.unstage(paths))
        end
    end)

    gitgud.on("SummaryEdit.changed", function()
        updateSummaryCount()
    end)

    gitgud.on("CommitButton.clicked", changes.commit)
    gitgud.on("SummaryEdit.accepted", changes.commit)
    gitgud.on("AmendCheck.toggled", onAmendToggled)
    gitgud.on("CoAuthorButton.clicked", addCoAuthor)
    gitgud.on("UndoRowButton.clicked", changes.undoLastCommit)
    gitgud.on("StashRowButton.clicked", stash.view)

    keys.bind("ctrl+enter", function()
        if sidebar.tab() == "changes" and not dialog.isOpen() then
            changes.commit()
        end
    end, "Commit")

    app.subscribe("tab.changed", function(tab)
        if tab == "changes" then
            changes.showContent(true)
        end
    end)

    app.subscribe("stash.closed", function()
        changes.showContent(true)
    end)

    app.subscribe("diff.optionsChanged", function()
        content.invalidate()
        changes.showContent(true)
    end)
end

return changes
