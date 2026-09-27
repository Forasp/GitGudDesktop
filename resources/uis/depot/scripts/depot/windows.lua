--- depot/windows.lua — the separate windows (diffs, revision graphs,
-- time-lapse views, folder diffs), as real OS windows (gitgud.openWindow).
--
--     local id = windows.open("diff", "Diff: a.cpp", "windows/diff.xml", 1100, 720)
--     -- widgets are "<id>:<name>", e.g. id .. ":DiffLeft"
--     windows.onClose(id, function() ... end)
--     windows.onKey(id, function(combo) ... end)   -- the window's shortcuts
--
-- Shortcut helpers open the common diffs:
--     windows.diffHave(path)                          -- have revision vs workspace
--     windows.diffRevisions(oldPath, oldRev, newPath, newRev)
--     windows.diffAgainstPrompt(path)                 -- ask for two revisions
--     windows.diffSelection()                         -- whatever is selected

local app = require("core.app")
local dialog = require("ui.dialog")
local log = require("depot.log")
local repo = require("core.repo")
local selection = require("depot.selection")
local text = require("core.text")

local windows = { name = "windows" }

local counter = 0
local titles = {}       -- id -> title
local closers = {}      -- id -> function
local keyHandlers = {}  -- id -> function(combo)

--- Open a pop-out window with a fresh id.
-- @param kind    id prefix ("diff", "revgraph", ...)
-- @param title   OS title
-- @param layout  layout file (relative to the UI's layouts/)
-- @param width   pixels
-- @param height  pixels
-- @return the window id, or nil (logged) on failure
function windows.open(kind, title, layout, width, height)
    counter = counter + 1
    local id = kind .. counter
    local ok, err = gitgud.openWindow({
        id = id,
        title = title,
        layout = layout,
        width = width or 1000,
        height = height or 700,
        minWidth = 480,
        minHeight = 320,
    })
    if not ok then
        log.error("Couldn't open the window: " .. tostring(err))
        return nil
    end
    titles[id] = title

    return id
end

--- A window's title (for the Window menu).
-- @param id  window id
-- @return title
function windows.titleOf(id)
    return titles[id] or id
end

--- Change a window's title.
function windows.setTitle(id, title)
    titles[id] = title
    gitgud.setWindowTitle(id, title)
end

--- Run `fn` when the window closes (by its close box or code).
function windows.onClose(id, fn)
    closers[id] = fn
end

--- Receive the window's keyboard shortcuts ("escape", "f7", "ctrl+c", ...).
function windows.onKey(id, fn)
    keyHandlers[id] = fn
end

--- Close a window.
function windows.close(id)
    gitgud.closeWindow(id)
end

-- ---- diff shortcuts ---------------------------------------------------------------

--- A readable name for a revision spec.
-- @param rev  "workdir", "HEAD", an oid, "<oid>^", a branch...
-- @return label
function windows.revisionLabel(rev)
    if rev == "workdir" then
        return "workspace"
    end
    if rev == "HEAD" or rev == "head" then
        return "#have"
    end
    if rev == "index" then
        return "staged"
    end
    local base, caret = rev:match("^(%x+)(%^?)$")
    if base and #base >= 12 then
        return (caret ~= "" and "before " or "@") .. base:sub(1, 8)
    end

    return rev
end

--- Diff two versions of a file in a Diff window.
-- @param oldPath  left path
-- @param oldRev   left revision
-- @param newPath  right path
-- @param newRev   right revision
-- @return the window id
function windows.diffRevisions(oldPath, oldRev, newPath, newRev)
    return require("depot.windows.diff").open({
        oldPath = oldPath or newPath,
        oldRev = oldRev,
        newPath = newPath or oldPath,
        newRev = newRev,
    })
end

--- Diff a workspace file against its have revision.
-- @param path  file
-- @return the window id
function windows.diffHave(path)
    return windows.diffRevisions(path, "HEAD", path, "workdir")
end

--- Ask for two revisions and diff them.
-- @param path  file
function windows.diffAgainstPrompt(path)
    dialog.show({
        title = "Diff Against",
        message = "Compare two revisions of " .. selection.depotPath(path)
            .. ". A revision is a changelist id, branch, label, HEAD, or \"workspace\".",
        fields = {
            { label = "Left revision", value = "HEAD" },
            { label = "Right revision", value = "workspace" },
        },
        ok = "Diff",
        onOk = function(v)
            local function spec(value)
                value = text.trim(value)
                if value:lower() == "workspace" or value == "" then
                    return "workdir"
                end
                return value
            end
            windows.diffRevisions(path, spec(v.fields[1]), path, spec(v.fields[2]))
            return true
        end,
    })
end

--- Diff whatever is selected: a history revision against its predecessor,
-- a shelved file against its base, or a workspace file against #have.
function windows.diffSelection()
    local item = selection.primary()
    if not item or not item.path then
        return
    end
    if item.revision then
        windows.diffRevisions(item.path, item.revision .. "^", item.path, item.revision)
    elseif item.shelf then
        windows.diffRevisions(item.path, item.shelf .. "^", item.path, item.shelf)
    elseif repo.file(item.path) then
        windows.diffHave(item.path)
    else
        windows.diffAgainstPrompt(item.path)
    end
end

function windows.init()
    gitgud.on("window.closed", function(id)
        local closer = closers[id]
        closers[id] = nil
        keyHandlers[id] = nil
        titles[id] = nil
        if closer then
            closer()
        end
    end)
    -- Tables inside a window re-measure when it's resized.
    gitgud.on("window.popOutResized", function()
        app.publish("layout.changed")
    end)
    gitgud.on("window.key", function(detail)
        local id, combo = detail:match("^([^|]+)|(.+)$")
        local handler = id and keyHandlers[id]
        if combo == "escape" and not handler then
            gitgud.closeWindow(id)
            return
        end
        if handler then
            handler(combo)
        end
    end)
end

return windows
