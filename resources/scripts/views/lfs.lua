--- views/lfs.lua — Git LFS (large files stored outside the repository).
--
-- When git-lfs is installed (it ships with Git for Windows), the engine
-- cleans and smudges `filter=lfs` files through it exactly like git does, so
-- staging a tracked .psd stores a small pointer and checking out downloads
-- the real file. This module adds the rest:
--
--   * Repository > Git LFS: track a pattern (writes .gitattributes), pull
--     LFS files, show LFS status (in the console)
--   * before a push, upload the LFS objects it needs (`git-lfs push`) — the
--     engine's own push doesn't run git's hooks, which is where git-lfs
--     normally does this
--   * diffs of LFS files show "stored with Git LFS" with the sizes instead
--     of the pointer text
--
-- Public API: lfs.available(), lfs.used(), lfs.patterns(), lfs.track(pattern),
--             lfs.pull(), lfs.status(), lfs.beforePush(fn), lfs.describe(fileDiff)

local app = require("core.app")
local dialog = require("ui.dialog")
local repo = require("core.repo")
local status = require("core.status")
local text = require("core.text")

local lfs = { name = "lfs" }

local POINTER = "version https://git-lfs.github.com/spec/v1"

--- Is git-lfs installed?
-- @return boolean
function lfs.available()
    return gitgud.lfsAvailable()
end

--- Patterns .gitattributes sends through LFS.
-- @return array of patterns
function lfs.patterns()
    local out = {}
    local attributes = repo.state().open and gitgud.readRepoFile(".gitattributes") or nil
    for line in (attributes or ""):gmatch("[^\r\n]+") do
        local pattern = line:match("^%s*(%S+)%s+.*filter=lfs")
        if pattern then
            out[#out + 1] = pattern
        end
    end

    return out
end

--- Does this repository use LFS at all?
-- @return boolean
function lfs.used()
    return #lfs.patterns() > 0
end

--- The git-lfs command, quoted for the console.
-- @return command prefix or nil
local function program()
    local path = gitgud.findProgram("git-lfs")
    if not path then
        return nil
    end

    return '"' .. path .. '"'
end

--- Explain that git-lfs is missing.
local function missing()
    dialog.alert("Git LFS isn't installed",
        "This needs git-lfs, which comes with Git for Windows (https://git-scm.com) or from "
            .. "https://git-lfs.com. Install it and restart GitGud.")
end

--- Track a pattern with LFS (appends it to .gitattributes).
-- @param pattern  e.g. "*.psd"
function lfs.track(pattern)
    if not lfs.available() then
        missing()
        return
    end
    for _, existing in ipairs(lfs.patterns()) do
        if existing == pattern then
            status.info(pattern .. " is already tracked with Git LFS.")
            return
        end
    end

    local attributes = gitgud.readRepoFile(".gitattributes") or ""
    if attributes ~= "" and not attributes:match("\n$") then
        attributes = attributes .. "\n"
    end
    attributes = attributes .. pattern .. " filter=lfs diff=lfs merge=lfs -text\n"
    local ok, err = gitgud.writeRepoFile(".gitattributes", attributes)
    if status.report("Tracking " .. pattern .. " with Git LFS. Commit .gitattributes to share that. "
        .. "Files already committed stay as they are.", ok, err) then
        app.requestRefresh()
    end
end

--- Ask for a pattern and track it.
function lfs.trackPrompt()
    dialog.prompt("Track files with Git LFS", "Pattern (e.g. *.psd, assets/**/*.png)", "", "Track",
        function(pattern)
            if pattern == "" then
                return false, "Enter a pattern."
            end
            lfs.track(pattern)
            return true
        end)
end

--- Download the LFS files of the current checkout.
function lfs.pull()
    local lfsCommand = program()
    if not lfsCommand then
        missing()
        return
    end
    require("views.console").run(lfsCommand .. " pull")
end

--- Show `git-lfs status` in the console.
function lfs.status()
    local lfsCommand = program()
    if not lfsCommand then
        missing()
        return
    end
    require("views.console").run(lfsCommand .. " status")
end

--- Upload LFS objects before a push, then run `push` (or offer to push
-- anyway if the upload fails).
-- @param push    function() doing the real push
-- @param remote  where the push goes (default: the upstream's remote)
function lfs.beforePush(push, remote)
    local lfsCommand = program()
    local state = repo.state()
    remote = remote or repo.upstreamRemote()
    if not lfsCommand or not lfs.used() or state.branch == "" or not remote then
        push()
        return
    end

    status.info("Uploading Git LFS files…")
    local started = require("views.console").run(lfsCommand .. " push " .. remote .. " " .. state.branch,
        function(code)
            if code == 0 then
                push()
                return
            end
            dialog.confirm("Uploading Git LFS files failed",
                "The console shows why. Pushing anyway would publish commits whose large files "
                    .. "others can't download.",
                "Push anyway", push, true)
        end)
    if not started then
        push()
    end
end

--- Is a diff the change of an LFS pointer file? Then describe it.
-- @param fileDiff  gitgud diff table
-- @return { title, body } or nil
function lfs.describe(fileDiff)
    local oldSize = nil
    local newSize = nil
    local isPointer = false

    for _, hunk in ipairs(fileDiff.hunks or {}) do
        for _, line in ipairs(hunk.lines) do
            if line.content:find(POINTER, 1, true) then
                isPointer = true
            end
            local size = line.content:match("^size (%d+)")
            if size and line.origin == "-" then
                oldSize = tonumber(size)
            elseif size then
                newSize = tonumber(size)
            end
        end
    end
    if not isPointer then
        return nil
    end

    --- "1.2 MB"
    local function human(bytes)
        if not bytes then
            return "—"
        end
        local units = { "bytes", "KB", "MB", "GB" }
        local value = bytes
        local unit = 1
        while value >= 1024 and unit < #units do
            value = value / 1024
            unit = unit + 1
        end
        return unit == 1 and (bytes .. " bytes") or string.format("%.1f %s", value, units[unit])
    end

    local body = "This file is stored with Git LFS; Git holds a small pointer to it."
    if oldSize or newSize then
        body = body .. " Size: " .. human(oldSize) .. " → " .. human(newSize) .. "."
    end
    if not lfs.available() then
        body = body .. " Install git-lfs to download and commit the real content."
    end

    return { title = "Git LFS file", body = body }
end

return lfs
