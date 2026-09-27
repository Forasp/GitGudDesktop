--- views/remotes.lua — adding, editing, and removing remotes (the
-- REMOTE section actions). The branch tree lists every remote under REMOTE;
-- right-click one for remotes.menu(), or the section header for Add remote.
--
-- Public API: remotes.add(), remotes.edit(name), remotes.remove(name),
--   remotes.menu(name)

local app = require("core.app")
local dialog = require("ui.dialog")
local repo = require("core.repo")
local shell = require("core.shell")
local status = require("core.status")
local text = require("core.text")

local remotes = {}

--- Check a remote name the user typed.
-- @param name  trimmed input
-- @return nil when fine, else an error message
local function badName(name)
    if name == "" then
        return "Enter a name for the remote."
    end
    if name:find("[%s/\\:]") then
        return "Remote names can't contain spaces, slashes, or colons."
    end

    return nil
end

--- Ask for a name and URL, then add the remote (and fetch it).
function remotes.add()
    dialog.show({
        title = "Add a remote",
        message = "Another copy of this repository to fetch from and push to — a fork, a mirror, "
            .. "or a second host.",
        fields = {
            { label = "Name", value = repo.primaryRemote() and "" or "origin" },
            { label = "URL", value = "" },
        },
        checks = { { label = "Fetch it now", value = true } },
        ok = "Add remote",
        onOk = function(v)
            local name = text.trim(v.fields[1])
            local url = text.trim(v.fields[2])
            local err = badName(name)
            if err then
                return false, err
            end
            if repo.remote(name) then
                return false, "There is already a remote called " .. name .. "."
            end
            if url == "" then
                return false, "Enter the remote's URL."
            end

            local ok, addErr = gitgud.addRemote(name, url)
            if not ok then
                return false, addErr
            end
            status.ok("Added remote " .. name .. ".")
            repo.load()
            app.requestRefresh()
            if v.checks[1] then
                require("views.sync").fetchRemote(name)
            end
            return true
        end,
    })
end

--- Change a remote's name and/or URL.
-- @param name  remote to edit
function remotes.edit(name)
    local remote = repo.remote(name)
    if not remote then
        return
    end

    dialog.show({
        title = "Edit remote " .. name,
        message = "Renaming keeps its branches and every branch that tracks it.",
        fields = {
            { label = "Name", value = remote.name },
            { label = "URL", value = remote.url },
        },
        ok = "Save",
        onOk = function(v)
            local newName = text.trim(v.fields[1])
            local url = text.trim(v.fields[2])
            local err = badName(newName)
            if err then
                return false, err
            end
            if url == "" then
                return false, "Enter the remote's URL."
            end
            if newName ~= name and repo.remote(newName) then
                return false, "There is already a remote called " .. newName .. "."
            end

            if url ~= remote.url then
                local ok, urlErr = gitgud.setRemoteUrl(name, url)
                if not ok then
                    return false, urlErr
                end
            end
            if newName ~= name then
                local ok, renameErr = gitgud.renameRemote(name, newName)
                if not ok then
                    return false, renameErr
                end
            end
            status.ok("Saved remote " .. newName .. ".")
            app.requestRefresh()
            return true
        end,
    })
end

--- Remove a remote, after confirming.
-- @param name  remote to remove
function remotes.remove(name)
    dialog.confirm("Remove remote " .. name .. "?",
        "Its remote branches disappear from this repository and branches that track it stop "
            .. "tracking. Nothing on the server changes, and you can add it again later.",
        "Remove remote",
        function()
            status.report("Removed remote " .. name .. ".", gitgud.removeRemote(name))
            app.requestRefresh()
        end, true)
end

--- Right-click menu for a remote.
-- @param name  remote name
-- @return item list
function remotes.menu(name)
    local sync = require("views.sync")
    local state = repo.state()
    local remote = repo.remote(name)
    local onBranch = state.branch ~= "" and state.headOid ~= ""
    local tracks = state.aheadBehind.upstreamRemote == name

    return {
        {
            label = "Fetch " .. name,
            action = function()
                sync.fetchRemote(name)
            end,
        },
        {
            label = "Pull " .. (state.branch ~= "" and state.branch or "branch") .. " from " .. name,
            enabled = onBranch,
            action = function()
                sync.pullFrom(name)
            end,
        },
        {
            label = "Push " .. (state.branch ~= "" and state.branch or "branch") .. " to " .. name,
            enabled = onBranch,
            action = function()
                sync.pushTo(name, false)
            end,
        },
        {
            label = "Push " .. (state.branch ~= "" and state.branch or "branch") .. " to " .. name
                .. " and track it",
            enabled = onBranch and not tracks,
            action = function()
                sync.pushTo(name, true)
            end,
        },
        {
            label = "Push tags to " .. name,
            action = function()
                sync.pushTags(name)
            end,
        },
        { separator = true },
        {
            label = "Edit…",
            action = function()
                remotes.edit(name)
            end,
        },
        {
            label = "Copy URL",
            enabled = remote ~= nil,
            action = function()
                shell.copy(remote.url, "URL")
            end,
        },
        {
            label = "Remove…",
            action = function()
                remotes.remove(name)
            end,
        },
    }
end

return remotes
