--- views/sync.lua — talking to remotes: fetch, pull, push, force push,
-- push tags, clone, sign-in, and background fetching.
--
-- A branch pushes to and pulls from the remote its upstream lives on
-- (repo.upstreamRemote()); a branch without one is published to the default
-- remote, or, when there are several, to the one you pick. Fetch covers
-- every remote. The *From / *To variants target one remote explicitly.
--
-- Network operations run on worker threads in C++; each reports back with
-- "<op>.started" / "<op>.done" / "<op>.error" events. While one runs the
-- toolbar shows it as busy (sync.busy()). If the server asks for
-- credentials that aren't stored, C++ fires "credential.missing" and we ask
-- for them (or for an SSH key's passphrase — views/ssh.lua), then retry the
-- operation. Repositories that use Git LFS upload their LFS objects (through
-- git-lfs) before the commits are pushed.
--
-- Public API: sync.sync(), sync.fetch(), sync.fetchRemote(name),
--   sync.pull(), sync.pullFrom(name), sync.push(), sync.pushTo(name, track),
--   sync.choosePushRemote(), sync.choosePullRemote(), sync.forcePush(),
--   sync.pushTags(name), sync.clone(url, path), sync.busy(),
--   sync.busyRemote(), sync.lastFetched(), sync.retry()

local app = require("core.app")
local dialog = require("ui.dialog")
local menu = require("ui.menu")
local repo = require("core.repo")
local settings = require("core.settings")
local status = require("core.status")
local text = require("core.text")

local sync = { name = "sync" }

local AUTO_FETCH_MS = 15 * 60 * 1000

local busyOp = nil         -- name of the running operation, or nil
local busyTarget = nil     -- what it talks to ("origin", "all remotes"), or nil
local lastOp = nil         -- { op, target, fn } to retry after signing in
local lastFetched = {}     -- repo path -> os.time() of the last fetch
local autoFetchTimer = nil

--- The running operation's name ("fetch", "push", ...), or nil.
-- @return string or nil
function sync.busy()
    return busyOp
end

--- What the running operation talks to ("origin", "all remotes"), or nil.
-- @return string or nil
function sync.busyRemote()
    return busyTarget
end

--- When the current repository was last fetched (os.time()), or nil.
-- @return timestamp or nil
function sync.lastFetched()
    return lastFetched[repo.state().path]
end

--- Start a network operation unless one is already running.
-- @param op      operation name (for busy state)
-- @param target  remote it talks to, for messages (nil for clone)
-- @param fn      function() that calls the gitgud async API
-- @return true when started
local function start(op, target, fn)
    if busyOp then
        status.warn("Wait for the current " .. busyOp .. " to finish.")
        return false
    end
    if not repo.primaryRemote() and op ~= "clone" then
        status.warn("This repository has no remote. Add one in Repository settings.")
        return false
    end

    busyOp = op
    busyTarget = target
    lastOp = { op = op, target = target, fn = fn }
    fn()
    app.publish("sync.changed")
    return true
end

--- Offer the repository's remotes in a menu under the sync button.
-- @param heading  first (disabled) line, e.g. "Push main to"
-- @param build    function(remote) -> item list for that remote
local function chooseRemote(heading, build)
    local items = { { label = heading, enabled = false } }
    for _, remote in ipairs(repo.state().remotes) do
        for _, item in ipairs(build(remote)) do
            items[#items + 1] = item
        end
    end

    local x, y, _, h = gitgud.getRect("SyncButton")
    menu.popup(items, x or 200, (y or 60) + (h or 0))
end

--- Fetch every remote.
function sync.fetch()
    local remotes = repo.state().remotes
    local target = #remotes == 1 and remotes[1].name or "all remotes"
    start("fetch", target, function()
        gitgud.fetchAll()
    end)
end

--- Fetch one remote.
-- @param name  remote name
function sync.fetchRemote(name)
    start("fetch", name, function()
        gitgud.fetch(name)
    end)
end

--- Pull (fetch + merge the upstream) from one remote.
-- @param name  remote name
function sync.pullFrom(name)
    start("pull", name, function()
        gitgud.pull(name)
    end)
end

--- Pull the current branch from its upstream's remote.
function sync.pull()
    sync.pullFrom(repo.upstreamRemote())
end

--- Push the current branch to one remote.
-- @param name   remote name
-- @param track  true to make that remote's branch the upstream
function sync.pushTo(name, track)
    require("views.lfs").beforePush(function()
        start("push", name, function()
            gitgud.push(name, { setUpstream = track == true })
        end)
    end, name)
end

--- Pick a remote to push the current branch to.
function sync.choosePushRemote()
    local branch = repo.state().branch
    local ab = repo.state().aheadBehind
    chooseRemote("Push " .. branch .. " to", function(remote)
        local items = {
            {
                label = remote.name,
                action = function()
                    sync.pushTo(remote.name, false)
                end,
            },
        }
        if ab.hasUpstream and ab.upstreamRemote ~= remote.name then
            items[2] = {
                label = remote.name .. " and track it from now on",
                action = function()
                    sync.pushTo(remote.name, true)
                end,
            }
        end
        return items
    end)
end

--- Pick a remote to pull the current branch from.
function sync.choosePullRemote()
    chooseRemote("Pull " .. repo.state().branch .. " from", function(remote)
        return {
            {
                label = remote.name,
                action = function()
                    sync.pullFrom(remote.name)
                end,
            },
        }
    end)
end

--- Push the current branch to its upstream; publish it the first time
-- (asking where when there is more than one remote).
function sync.push()
    local state = repo.state()
    if not state.aheadBehind.hasUpstream and #state.remotes > 1 then
        chooseRemote("Publish " .. state.branch .. " to", function(remote)
            return {
                {
                    label = remote.name,
                    action = function()
                        sync.pushTo(remote.name, true)
                    end,
                },
            }
        end)
        return
    end

    sync.pushTo(repo.upstreamRemote(), false)
end

--- Force-push the current branch, after confirming (if enabled in Options).
function sync.forcePush()
    local branch = repo.state().branch
    local remote = repo.upstreamRemote()

    --- Do the force push.
    local function run()
        require("views.lfs").beforePush(function()
            start("push", remote, function()
                gitgud.push(remote, { force = true })
            end)
        end, remote)
    end

    if not settings.get("confirmForcePush", true) then
        run()
        return
    end

    dialog.confirm("Force push " .. branch .. "?",
        "This overwrites " .. branch .. " on " .. (remote or "the remote")
            .. ". Commits others pushed there since your last fetch will be lost.",
        "Force push", run, true)
end

--- Push every local tag.
-- @param name  remote (default: the current branch's upstream remote)
function sync.pushTags(name)
    local remote = name or repo.upstreamRemote()
    start("pushTags", remote, function()
        gitgud.pushTags(remote)
    end)
end

--- Clone into a folder; the clone opens when it finishes.
-- @param url   what to clone
-- @param path  destination folder
function sync.clone(url, path)
    start("clone", nil, function()
        gitgud.clone(url, path)
    end)
end

--- The toolbar button: pull when behind, push when ahead (or unpublished),
-- otherwise fetch.
function sync.sync()
    local state = repo.state()
    local ab = state.aheadBehind

    if ab.hasUpstream and (ab.behind or 0) > 0 then
        sync.pull()
    elseif ab.hasUpstream and (ab.ahead or 0) > 0 then
        sync.push()
    elseif not ab.hasUpstream and state.branch ~= "" and state.headOid ~= "" and repo.primaryRemote() then
        sync.push()
    else
        sync.fetch()
    end
end

--- A network operation finished (either way).
local function finished()
    busyOp = nil
    busyTarget = nil
    app.publish("sync.changed")
    app.requestRefresh()
end

--- Run the last network operation again (after signing in, trusting a
-- host, or entering a passphrase).
function sync.retry()
    if lastOp then
        local retry = lastOp
        busyOp = nil
        start(retry.op, retry.target, retry.fn)
    end
end

--- Ask for credentials for a host, then retry the operation.
-- @param host  server host name (or "ssh-key:<path>" for a key passphrase)
local function signIn(host)
    if host:sub(1, 8) == "ssh-key:" then
        require("views.ssh").askPassphrase(host)
        return
    end

    dialog.show({
        title = "Sign in to " .. host,
        message = "Stored in the Windows Credential Manager, never in plain text. "
            .. "For hosted services use a personal access token as the password.",
        fields = {
            { label = "Username", value = "" },
            { label = "Password or access token", value = "" },
        },
        ok = "Save and retry",
        onOk = function(v)
            local user = text.trim(v.fields[1])
            local pass = v.fields[2]
            if user == "" or pass == "" then
                return false, "Enter both a username and a password."
            end
            if not gitgud.setCredential(host, user, pass) then
                return false, "Could not save the credential."
            end

            status.info("Saved credentials for " .. host .. "; retrying…")
            sync.retry()
            return true
        end,
    })
end

--- (Re)start the background fetch timer per the Options setting.
function sync.scheduleAutoFetch()
    if autoFetchTimer then
        gitgud.cancelTimer(autoFetchTimer)
        autoFetchTimer = nil
    end

    if not settings.get("autoFetch", true) then
        return
    end

    autoFetchTimer = gitgud.every(AUTO_FETCH_MS, function()
        if repo.state().open and not busyOp and repo.primaryRemote() then
            sync.fetch()
        end
    end)
end

--- Wire the toolbar button and the async operation events.
function sync.init()
    gitgud.on("SyncButton.clicked", sync.sync)

    local labels = {
        fetch = "Fetching from",
        push = "Pushing to",
        pull = "Pulling from",
        pushTags = "Pushing tags to",
    }
    for op, verb in pairs(labels) do
        gitgud.on(op .. ".started", function()
            status.info(verb .. " " .. (busyTarget or "the remote") .. "…")
        end)
    end

    gitgud.on("fetch.done", function(detail)
        lastFetched[repo.state().path] = os.time()
        status.ok(detail)
        finished()
    end)

    gitgud.on("push.done", function(detail)
        status.ok(detail)
        finished()
    end)

    gitgud.on("pushTags.done", function(detail)
        status.ok(detail)
        finished()
    end)

    gitgud.on("deleteRemoteBranch.done", function(detail)
        status.ok(detail)
        app.requestRefresh()
    end)

    gitgud.on("pull.done", function(detail)
        local kind, message = detail:match("^(%w+)|(.*)$")
        lastFetched[repo.state().path] = os.time()
        if kind == "conflicts" then
            status.warn("Pull hit merge conflicts. Resolve the files, then commit the merge.")
        else
            status.ok(message or detail)
        end
        finished()
    end)

    gitgud.on("clone.started", function()
        status.info("Cloning…")
    end)

    gitgud.on("clone.done", function(path)
        status.ok("Cloned into " .. path)
        finished()
        gitgud.openRepo(path)
    end)

    for _, op in ipairs({ "fetch", "push", "pull", "pushTags", "clone", "deleteRemoteBranch" }) do
        gitgud.on(op .. ".error", function(detail)
            local message = detail or "unknown error"
            if op == "push" and message:lower():find("non%-fast%-forward") then
                message = message .. " — pull first, or force push if you rewrote history."
            end
            status.error(op:sub(1, 1):upper() .. op:sub(2) .. " failed: " .. message)
            finished()
        end)
    end

    gitgud.on("credential.missing", signIn)

    sync.scheduleAutoFetch()
end

return sync
