--- core/repo.lua — one snapshot of repository state per refresh.
--
-- Views read from this snapshot instead of each calling gitgud.status() /
-- gitgud.currentBranch() / ... themselves, so a refresh costs one round of
-- git queries no matter how many views are listening.
--
-- The snapshot (also passed to every module's refresh(state)):
--   open          a repository is open
--   path          working-tree root ("" when closed)
--   name          folder name of the repository
--   branch        checked-out branch ("" when detached or closed)
--   detached      HEAD is detached
--   files         gitgud.status() rows: {path, staged, unstaged, code}
--   aheadBehind   {ahead, behind, hasUpstream, upstream, upstreamRemote}
--   operation     "none" | "merge" | "rebase" | "cherrypick" | "revert" | "other"
--   conflicts     paths with unresolved conflicts
--   stashes       gitgud.stashList()
--   remotes       gitgud.remotes()
--   headOid       tip commit of HEAD ("" on an unborn branch)

local text = require("core.text")

local repo = {}

local current = {
    open = false,
    path = "",
    name = "",
    branch = "",
    detached = false,
    files = {},
    aheadBehind = {},
    operation = "none",
    conflicts = {},
    stashes = {},
    remotes = {},
    headOid = "",
}

--- The most recent snapshot (without reloading).
-- @return the snapshot table
function repo.state()
    return current
end

--- Query git for a fresh snapshot.
-- @return the new snapshot table
function repo.load()
    local s = {}
    s.open = gitgud.isOpen()
    s.path = gitgud.repoPath()
    s.name = s.path ~= "" and text.basename(s.path) or ""

    if not s.open then
        s.branch = ""
        s.detached = false
        s.files = {}
        s.aheadBehind = {}
        s.operation = "none"
        s.conflicts = {}
        s.stashes = {}
        s.remotes = {}
        s.headOid = ""
        current = s
        return s
    end

    s.branch = gitgud.currentBranch()
    s.files = gitgud.status()
    s.aheadBehind = gitgud.aheadBehind()
    s.operation = gitgud.repoState()
    s.conflicts = gitgud.conflicts()
    s.stashes = gitgud.stashList()
    s.remotes = gitgud.remotes()

    local head = gitgud.history(1)
    s.headOid = head[1] and head[1].oid or ""
    s.detached = s.branch == "" and s.headOid ~= ""

    current = s
    return s
end

--- The default remote: "origin" if it exists, else the first.
-- @return remote name, or nil when the repository has no remotes
function repo.primaryRemote()
    local first = nil

    for _, remote in ipairs(current.remotes) do
        if remote.name == "origin" then
            return "origin"
        end
        first = first or remote.name
    end

    return first
end

--- Look up a remote by name.
-- @param name  remote name
-- @return the gitgud.remotes() row, or nil
function repo.remote(name)
    for _, remote in ipairs(current.remotes) do
        if remote.name == name then
            return remote
        end
    end

    return nil
end

--- Split a remote-tracking name ("origin/feature/x") into remote and
-- branch, matching the longest known remote name (names may contain "/").
-- @param name  remote-tracking branch shorthand
-- @return remote, branch — or nil when no remote matches
function repo.splitRemoteBranch(name)
    local best = nil
    for _, remote in ipairs(current.remotes) do
        local prefix = remote.name .. "/"
        if name:sub(1, #prefix) == prefix and (not best or #remote.name > #best) then
            best = remote.name
        end
    end
    if not best then
        return nil
    end

    return best, name:sub(#best + 2)
end

--- The remote the current branch pushes to and pulls from: the one its
-- upstream lives on, else the default remote.
-- @return remote name, or nil when the repository has no remotes
function repo.upstreamRemote()
    local name = current.aheadBehind and current.aheadBehind.upstreamRemote
    if name and name ~= "" and repo.remote(name) then
        return name
    end

    return repo.primaryRemote()
end

--- Look up one changed file in the snapshot.
-- @param path  repository-relative path
-- @return the status row, or nil
function repo.file(path)
    for _, file in ipairs(current.files) do
        if file.path == path then
            return file
        end
    end

    return nil
end

--- Stashes that were taken on the current branch. Git labels them
-- "On <branch>: message" (or "WIP on <branch>: ..." without a message).
-- @return array of stash rows, newest first
function repo.branchStashes()
    local out = {}
    local named = "On " .. current.branch .. ":"
    local wip = "WIP on " .. current.branch .. ":"

    for _, stash in ipairs(current.stashes) do
        local message = stash.message
        if message:sub(1, #named) == named or message:sub(1, #wip) == wip then
            out[#out + 1] = stash
        end
    end

    return out
end

return repo
