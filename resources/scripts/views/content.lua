--- views/content.lua — decides what the right-hand pane shows.
--
-- The pane has two arrangements:
--   plain    diff header on top, diff body below (Changes tab)
--   commit   commit header on top, the commit's files on the left, then the
--            diff header + body for the chosen file (History tab, stashes)
--
-- and the body shows exactly one of: a text diff (views/diff.lua), an image
-- diff (views/imagediff.lua), or an empty state (a centred message with up
-- to three action buttons).
--
-- Public API:
--   content.arrange("plain" | "commit")
--   content.showWorkingFile(path, force)   diff of one changed file
--   content.showCommitFile(oid, fileDiff)  one file of a commit/stash
--   content.showEmpty({ title, body, actions = { {label, action}, ... } })
--   content.setTitle(markup)

local C = require("core.palette")
local diff = require("views.diff")
local geometry = require("ui.geometry")
local imagediff = require("views.imagediff")
local repo = require("core.repo")
local status = require("core.status")
local text = require("core.text")

local content = { name = "content" }

local LARGE_DIFF_LINES = 4000
local FILES_WIDTH = 260
local COMMIT_HEADER_HEIGHT = 96
local COMMIT_HEADER_COMPACT = 74
local DIFF_HEADER_HEIGHT = 44

local arrangement = "plain"
local headerHeight = COMMIT_HEADER_HEIGHT
local emptyActions = {}
local shownSignature = nil   -- what the text diff currently shows
local shownTarget = nil      -- which file (and commit) that diff is of
local forcedLarge = {}       -- path -> true once the user asked to see it

--- Position the header and body for the current arrangement.
local function applyArrangement()
    if arrangement == "commit" then
        local top = headerHeight
        gitgud.setVisible("CommitView", true)
        gitgud.setProperty("CommitHeader", "Area", geometry.area(0, 0, 0, 0, 1, 0, 0, top))
        gitgud.setProperty("CommitFilesList", "Area", geometry.area(0, 0, 0, top, 0, FILES_WIDTH, 1, 0))
        gitgud.setProperty("CommitFilesBorder", "Area",
            geometry.area(0, FILES_WIDTH, 0, top, 0, FILES_WIDTH + 1, 1, 0))
        gitgud.setProperty("DiffHeader", "Area",
            geometry.area(0, FILES_WIDTH + 1, 0, top, 1, 0, 0, top + DIFF_HEADER_HEIGHT))
        gitgud.setProperty("DiffBody", "Area",
            geometry.area(0, FILES_WIDTH + 1, 0, top + DIFF_HEADER_HEIGHT + 1, 1, 0, 1, 0))
        return
    end

    gitgud.setVisible("CommitView", false)
    gitgud.setProperty("DiffHeader", "Area", geometry.area(0, 0, 0, 0, 1, 0, 0, DIFF_HEADER_HEIGHT))
    gitgud.setProperty("DiffBody", "Area", geometry.area(0, 0, 0, DIFF_HEADER_HEIGHT + 1, 1, 0, 1, 0))
end

--- Switch between the plain and commit arrangements.
-- @param mode     "plain" | "commit"
-- @param compact  commit arrangement only: true for a shorter header (a
--                 commit with no body text)
function content.arrange(mode, compact)
    arrangement = mode
    headerHeight = compact and COMMIT_HEADER_COMPACT or COMMIT_HEADER_HEIGHT
    applyArrangement()
end

--- Set the diff header text.
-- @param markup  CEGUI markup (escape your own text)
function content.setTitle(markup)
    gitgud.setText("DiffTitle", markup)
end

--- A "dir/name  +3 −1" title for a file.
-- @param path     repository-relative path
-- @param added    added line count (nil to omit stats)
-- @param removed  removed line count
-- @param oldPath  previous path for renames (optional)
-- @return markup
local function fileTitle(path, added, removed, oldPath)
    local dir = text.dirname(path)
    local markup = ""

    if oldPath and oldPath ~= "" and oldPath ~= path then
        markup = text.colour(C.dim, oldPath .. "  →  ")
    end
    if dir ~= "" then
        markup = markup .. text.colour(C.dim, dir .. "/")
    end
    markup = markup .. text.colour(C.text, text.basename(path))

    if added then
        markup = markup .. "   " .. text.colour(C.add, "+" .. added)
            .. " " .. text.colour(C.del, "−" .. removed)
    end

    return markup
end

--- Show an empty state instead of a diff.
-- @param spec  { title, body, actions = { { label, action, primary }, ... } }
function content.showEmpty(spec)
    shownSignature = nil
    diff.clear()
    diff.setVisible(false)
    imagediff.hide()

    gitgud.setVisible("EmptyState", true)
    gitgud.setText("EmptyTitle", text.escape(spec.title or ""))
    gitgud.setText("EmptyBody", text.escape(spec.body or ""))

    emptyActions = spec.actions or {}
    for i = 1, 3 do
        local action = emptyActions[i]
        local button = "EmptyAction" .. i

        gitgud.setVisible(button, action ~= nil)
        if action then
            gitgud.setText(button, text.escape(action.label))
            gitgud.setProperty(button, "NormalFillColour", action.primary and C.blue or C.bg3)
            gitgud.setProperty(button, "HoverFillColour", action.primary and "FF93A4FF" or C.bg4)
            gitgud.setProperty(button, "NormalTextColour", action.primary and C.bg0 or C.text)
            gitgud.setProperty(button, "HoverTextColour", action.primary and C.bg0 or "FFFFFFFF")
        end
    end
end

--- Hide the empty state and image panel and show the text lists.
local function showTextBody()
    gitgud.setVisible("EmptyState", false)
    imagediff.hide()
    diff.setVisible(true)
end

--- Try an image diff; fall back to an explanatory empty state on failure.
-- @param path       repository-relative path
-- @param beforeRev  revision of the old version
-- @param afterRev   revision of the new version
local function showImage(path, beforeRev, afterRev)
    shownSignature = nil
    gitgud.setVisible("EmptyState", false)
    diff.setVisible(false)

    local ok, err = imagediff.show(path, beforeRev, afterRev)
    if not ok then
        content.showEmpty({
            title = "Can't preview this image",
            body = err or "The image could not be decoded.",
        })
    end
end

--- A cheap fingerprint of what a text diff would render, so refreshes that
-- change nothing don't rebuild the lists (and lose the scroll position).
-- @param fileDiff  diff table
-- @param staged    set of included indices (or nil)
-- @return signature string
local function signature(fileDiff, staged)
    local parts = { fileDiff.path, diff.mode(), tostring(diff.ignoreWhitespace()) }

    for _, hunk in ipairs(fileDiff.hunks) do
        parts[#parts + 1] = hunk.header
        for _, line in ipairs(hunk.lines) do
            parts[#parts + 1] = line.origin .. line.content
        end
    end

    if staged then
        local indices = {}
        for idx, _ in pairs(staged) do
            indices[#indices + 1] = idx
        end
        table.sort(indices)
        parts[#parts + 1] = "staged:" .. table.concat(indices, ",")
    end

    return table.concat(parts, "\n")
end

--- Gate very large diffs behind a button (rendering them costs seconds).
-- @param path      file path
-- @param lines     flat line count
-- @param onReveal  function() that renders anyway
-- @return true when the gate was shown
local function largeDiffGate(path, lines, onReveal)
    if lines <= LARGE_DIFF_LINES or forcedLarge[path] then
        return false
    end

    content.showEmpty({
        title = "This diff is large",
        body = string.format("%s changed lines. Rendering it may take a moment.",
            tostring(lines)),
        actions = {
            {
                label = "Show the diff",
                primary = true,
                action = function()
                    forcedLarge[path] = true
                    onReveal()
                end,
            },
        },
    })

    return true
end

--- Show the diff of one working-tree file, with line staging.
-- @param path   repository-relative path
-- @param force  re-render even if nothing changed
function content.showWorkingFile(path, force)
    local entry = repo.file(path)
    if not entry then
        return
    end

    if gitgud.isImage(path) then
        content.setTitle(fileTitle(path))
        showImage(path, "head", "workdir")
        return
    end

    local fileDiff, err = gitgud.diff(path, "head", diff.queryOptions())
    if not fileDiff then
        content.setTitle(fileTitle(path))
        content.showEmpty({ title = "Can't show this diff", body = err })
        return
    end

    local added, removed = diff.stats(fileDiff)
    if fileDiff.binary then
        added = nil
    end
    content.setTitle(fileTitle(path, added, removed))

    if fileDiff.binary then
        content.showEmpty({
            title = "Binary file",
            body = "This file's contents can't be shown as text. It will be committed as a whole.",
        })
        return
    end

    local pointer = require("views.lfs").describe(fileDiff)
    if pointer then
        content.showEmpty(pointer)
        return
    end

    if #fileDiff.hunks == 0 then
        local body = "Nothing changed inside this file (perhaps only its mode or line endings)."
        if entry.code == "?" or entry.code == "A" then
            body = "This new file is empty."
        end
        content.showEmpty({ title = "No content changes", body = body })
        return
    end

    local lineCount = diff.lineCount(fileDiff)
    local reveal = function()
        content.showWorkingFile(path, true)
    end
    if largeDiffGate(path, lineCount, reveal) then
        return
    end

    -- Line staging needs byte-exact line numbering, which whitespace
    -- filtering and conflict markers break. Perforce opens whole files only.
    local staging = nil
    local canStage = not diff.ignoreWhitespace() and entry.code ~= "U" and gitgud.supports("lineStaging")
    if canStage then
        local staged = {}
        for _, idx in ipairs(gitgud.stagedLines(path)) do
            staged[idx] = true
        end

        staging = {
            staged = staged,
            onChange = function(indices)
                local ok, stageErr = gitgud.setStagedLines(path, indices, lineCount)
                if not ok then
                    status.error(stageErr or "Could not update the staged lines.")
                    content.showWorkingFile(path, true)
                end
            end,
        }
    end

    local sig = signature(fileDiff, staging and staging.staged or nil)
    if sig == shownSignature and not force then
        return
    end

    showTextBody()
    diff.render(fileDiff, staging)
    shownSignature = sig
    if shownTarget ~= path then
        shownTarget = path
        diff.scrollToTop()
    end
end

--- Show one file of a commit (or stash) read-only.
-- @param oid       the commit the file belongs to
-- @param fileDiff  its diff table (from gitgud.commitDiff / stashDiff)
function content.showCommitFile(oid, fileDiff)
    if not fileDiff then
        content.setTitle("")
        content.showEmpty({ title = "No files", body = "This commit doesn't change any files." })
        return
    end

    local added, removed = diff.stats(fileDiff)
    if fileDiff.binary or gitgud.isImage(fileDiff.path) then
        added = nil
    end
    content.setTitle(fileTitle(fileDiff.path, added, removed, fileDiff.oldPath))

    if gitgud.isImage(fileDiff.path) then
        showImage(fileDiff.path, oid .. "^", oid)
        return
    end

    if fileDiff.binary then
        content.showEmpty({ title = "Binary file", body = "This file's contents can't be shown as text." })
        return
    end

    local pointer = require("views.lfs").describe(fileDiff)
    if pointer then
        content.showEmpty(pointer)
        return
    end

    if #fileDiff.hunks == 0 then
        content.showEmpty({ title = "No content changes", body = "Only the file's mode or name changed." })
        return
    end

    local reveal = function()
        content.showCommitFile(oid, fileDiff)
    end
    if largeDiffGate(oid .. fileDiff.path, diff.lineCount(fileDiff), reveal) then
        return
    end

    local sig = signature(fileDiff, nil) .. oid
    if sig == shownSignature then
        return
    end

    showTextBody()
    diff.render(fileDiff, nil)
    shownSignature = sig
    if shownTarget ~= oid .. fileDiff.path then
        shownTarget = oid .. fileDiff.path
        diff.scrollToTop()
    end
end

--- Forget what's rendered so the next show*() call redraws.
function content.invalidate()
    shownSignature = nil
end

-- ---- Overlays ----------------------------------------------------------------
-- Full-pane tools (the merge tool, file history / blame) sit over the
-- normal content. One at a time; Escape or their Close button returns to
-- whatever the pane showed before.

local overlay = nil        -- { name, token, onClose }

--- Is a full-pane tool open?
-- @return boolean
function content.overlayOpen()
    return overlay ~= nil
end

--- The name of the open overlay (or nil).
-- @return widget name
function content.currentOverlay()
    return overlay and overlay.name or nil
end

--- Close the open overlay.
-- @param quiet  true: don't repaint what's underneath (someone else will)
function content.closeOverlay(quiet)
    if not overlay then
        return
    end

    local closing = overlay
    overlay = nil
    gitgud.setVisible(closing.name, false)
    require("core.keys").popEscape(closing.token)
    if closing.onClose then
        closing.onClose()
    end

    if quiet then
        return
    end
    shownSignature = nil
    if require("views.frame").graphMode() then
        require("views.graph").reload(true)
    else
        require("core.app").publish("tab.changed", require("views.sidebar").tab())
    end
end

--- Show a full-pane tool over the content.
-- @param name     its panel widget
-- @param onClose  optional function() run when it closes
function content.openOverlay(name, onClose)
    content.closeOverlay(true)
    overlay = { name = name, onClose = onClose }
    overlay.token = require("core.keys").pushEscape(function()
        content.closeOverlay()
    end)
    gitgud.setVisible(name, true)
    gitgud.bringToFront(name)
end

--- Wire the empty-state buttons.
function content.init()
    for i = 1, 3 do
        gitgud.on("EmptyAction" .. i .. ".clicked", function()
            local action = emptyActions[i]
            if action and action.action then
                action.action()
            end
        end)
    end

    gitgud.on("window.resized", function()
        imagediff.relayout()
    end)

    -- Switching tabs or opening the graph leaves any full-pane tool.
    local app = require("core.app")
    app.subscribe("tab.changed", function()
        content.closeOverlay(true)
    end)
    app.subscribe("frame.graphChanged", function()
        content.closeOverlay(true)
    end)

    applyArrangement()
end

return content
