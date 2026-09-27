--- views/github.lua: browser sign-in for GitHub, through the GitHub CLI (gh).
--
-- GitHub doesn't accept account passwords for Git over HTTPS. When a
-- github.com remote needs a sign-in, views/sync.lua hands over here:
--   1. If gh is already signed in, reuse its token (no prompt at all).
--   2. Otherwise offer "Sign in with browser". gh is found on PATH, or in
--      the copy GitGud keeps under its app data; when neither exists we ask,
--      then download the latest release (its SHA-256 checked) into
--      <app data>/tools/gh/<version>.
--   3. Run `gh auth login --web` in the background, show its one-time code
--      (also put on the clipboard), and open the browser.
--   4. Store the token gh ends up with like any other credential and retry.
-- "Use a token" falls back to the plain username/token dialog.
--
-- GitGud's own copy of gh is kept current: checked shortly after start and
-- then daily, updated when a newer release is out. A gh on PATH belongs to
-- the user and is left alone.
--
-- Public API: github.handles(host), github.signIn(host, opts),
--   github.checkForUpdate(), github.init()

local dialog = require("ui.dialog")
local settings = require("core.settings")
local status = require("core.status")
local text = require("core.text")

local github = {}

local TOOL = "gh"
local RELEASE_API = "https://api.github.com/repos/cli/cli/releases/latest"
local DOWNLOADS = "https://github.com/cli/cli/releases/download/"
local UPDATE_EVERY_SECONDS = 24 * 60 * 60
local TOKEN_USER = "x-access-token" -- GitHub ignores the name for tokens

local pending = {}        -- event name prefix -> function(ok, detail)
local wired = {}          -- event name prefixes with handlers registered
local loginRun = nil      -- the running `gh auth login`, or nil
local installing = false

--- True for hosts this module signs in to.
-- @param host  remote host name
function github.handles(host)
    return host == "github.com"
end

-- ---- async plumbing ----------------------------------------------------------

--- Route "<name>.done" / "<name>.error" to the next callback for `name`
-- (gitgud.on handlers are permanent, so register each name once).
local function await(name, callback)
    pending[name] = callback
    if wired[name] then
        return
    end
    wired[name] = true

    gitgud.on(name .. ".done", function(detail)
        local cb = pending[name]
        pending[name] = nil
        if cb then
            cb(true, detail)
        end
    end)
    gitgud.on(name .. ".error", function(detail)
        local cb = pending[name]
        pending[name] = nil
        if cb then
            cb(false, detail or "unknown error")
        end
    end)
end

--- HTTPS GET, then callback(body) or callback(nil, err).
local function fetch(name, url, callback)
    local started, err = gitgud.httpGet(name, url)
    if not started then
        callback(nil, err)
        return
    end
    await(name, function(ok, detail)
        if ok then
            callback(detail)
        else
            callback(nil, detail)
        end
    end)
end

-- ---- versions and installs ----------------------------------------------------

--- Compare dotted version strings numerically.
-- @return -1, 0 or 1
local function compareVersions(a, b)
    local pa, pb = {}, {}
    for n in a:gmatch("%d+") do
        pa[#pa + 1] = tonumber(n)
    end
    for n in b:gmatch("%d+") do
        pb[#pb + 1] = tonumber(n)
    end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

--- The gh.exe inside an install folder, or nil.
local function exeIn(dir)
    for _, rel in ipairs({ "\\bin\\gh.exe", "\\gh.exe" }) do
        if gitgud.pathExists(dir .. rel) then
            return dir .. rel
        end
    end
    return nil
end

--- GitGud's own newest copy: { version, exe } or nil.
local function ownCopy()
    local best = nil
    for _, entry in ipairs(gitgud.installedTools(TOOL)) do
        local exe = exeIn(entry.dir)
        if exe and (not best or compareVersions(entry.version, best.version) > 0) then
            best = { version = entry.version, exe = exe }
        end
    end
    return best
end

--- The gh to use: the user's on PATH first, then GitGud's copy.
-- @return path or nil
local function findGh()
    local onPath = gitgud.findProgram("gh")
    if onPath then
        return onPath
    end
    local own = ownCopy()
    return own and own.exe or nil
end

--- Look up the latest release: callback({ version, url, sha256 }) or (nil, err).
local function latestRelease(callback)
    fetch("github.release", RELEASE_API, function(body, err)
        local version = body and body:match('"tag_name"%s*:%s*"v([%d%.]+)"')
        if not version then
            callback(nil, err or "couldn't read the latest release")
            return
        end

        local base = DOWNLOADS .. "v" .. version .. "/"
        local zip = "gh_" .. version .. "_windows_amd64.zip"
        fetch("github.checksums", base .. "gh_" .. version .. "_checksums.txt", function(sums, err2)
            local sha = sums and sums:match("(%x+)%s+" .. zip:gsub("%p", "%%%0"))
            if not sha then
                callback(nil, err2 or "the release has no checksum for " .. zip)
                return
            end
            callback({ version = version, url = base .. zip, sha256 = sha })
        end)
    end)
end

--- Download and unpack a release: callback(exe) or (nil, err).
local function install(release, callback)
    local started, err = gitgud.installTool("github.install", {
        url = release.url,
        sha256 = release.sha256,
        tool = TOOL,
        version = release.version,
    })
    if not started then
        callback(nil, err)
        return
    end
    installing = true
    await("github.install", function(ok, detail)
        installing = false
        if not ok then
            callback(nil, detail)
            return
        end
        settings.set("githubCliChecked", os.time())
        local exe = exeIn(detail)
        if exe then
            callback(exe)
        else
            callback(nil, "gh.exe wasn't in the download")
        end
    end)
end

--- Update GitGud's own copy of gh when a newer release is out. Quiet unless
-- it actually updates; at most once a day.
function github.checkForUpdate()
    local own = ownCopy()
    if not own or installing or loginRun then
        return
    end
    local last = tonumber(settings.get("githubCliChecked", 0)) or 0
    if os.time() - last < UPDATE_EVERY_SECONDS then
        return
    end
    settings.set("githubCliChecked", os.time())

    latestRelease(function(release)
        if not release or compareVersions(release.version, own.version) <= 0 then
            return
        end
        install(release, function(exe)
            if exe then
                status.info("Updated the GitHub CLI to " .. release.version .. ".")
            end
        end)
    end)
end

-- ---- signing in -----------------------------------------------------------------

--- Store a token for `host` and retry the operation that needed it.
local function useToken(host, user, token, onSignedIn)
    if not gitgud.setCredential(host, user or TOKEN_USER, token) then
        status.error("Could not save the GitHub sign-in.")
        return
    end
    onSignedIn()
end

--- The token gh already holds for `host`, or nil.
local function ghToken(gh, host)
    local result = gitgud.runProgram({ gh, "auth", "token", "--hostname", host })
    if result and result.code == 0 then
        local token = text.trim(result.output or "")
        if token ~= "" then
            return token
        end
    end
    return nil
end

--- Show the one-time code while gh waits for the browser.
local function showCode(run)
    run.dialog = {
        title = "Sign in to GitHub",
        message = "Enter this code on the GitHub page that opened in your browser:\n\n"
            .. "        " .. run.code .. "\n\n"
            .. "The code has been copied to your clipboard. This closes by itself once "
            .. "you've approved GitGud in the browser.",
        ok = "Open page again",
        stayOpen = true,
        alt = {
            label = "Copy code",
            stayOpen = true,
            action = function()
                gitgud.setClipboard(run.code)
                status.info("Copied " .. run.code .. " to the clipboard.")
            end,
        },
        onOk = function()
            gitgud.setClipboard(run.code)
            gitgud.openExternal(run.url)
            return true
        end,
        onCancel = function()
            if loginRun == run then
                run.cancelled = true
                gitgud.stopProgram("github.login")
            end
        end,
    }
    dialog.show(run.dialog)
end

--- Run `gh auth login --web` and finish with the token it saves.
local function login(gh, host, onSignedIn)
    local run = { output = "", host = host }
    local started, err = gitgud.startProgram("github.login",
        { gh, "auth", "login", "--web", "--hostname", host, "--scopes", "workflow" })
    if not started then
        status.error("Couldn't start the GitHub CLI: " .. tostring(err))
        return
    end
    loginRun = run
    status.info("Starting GitHub sign-in…")

    run.onOutput = function(chunk)
        run.output = run.output .. chunk
        if run.code then
            return
        end
        -- "! First copy your one-time code: XXXX-XXXX", or newer gh:
        -- "! One-time code (XXXX-XXXX) copied to clipboard"
        local code = run.output:match("[Oo]ne%-time code[^%w]*(%w+%-%w+)")
        local url = run.output:match("(https://%S+/login/device)")
        if code and url then
            run.code, run.url = code, url
            gitgud.setClipboard(code)
            gitgud.openExternal(url)
            showCode(run)
        end
    end

    run.onDone = function(exitCode)
        loginRun = nil
        if run.dialog then
            dialog.close(run.dialog)
        end
        if run.cancelled then
            status.info("GitHub sign-in cancelled.")
            return
        end
        if tonumber(exitCode) ~= 0 then
            local last = text.trim(run.output):match("([^\n]*)$") or ""
            status.error("GitHub sign-in failed" .. (last ~= "" and (": " .. last) or "."))
            return
        end

        local token = ghToken(gh, host)
        if not token then
            status.error("The GitHub CLI signed in but didn't hand over a token.")
            return
        end
        local user = run.output:match("Logged in as (%S+)")
        status.ok("Signed in to GitHub" .. (user and (" as " .. user) or "") .. "; retrying…")
        useToken(host, user, token, onSignedIn)
    end
end

--- Make sure gh is available (asking before any download): callback(gh).
local function withGh(callback)
    local gh = findGh()
    if gh then
        callback(gh)
        return
    end

    status.info("Downloading the GitHub CLI…")
    latestRelease(function(release, err)
        if not release then
            status.error("Couldn't find the GitHub CLI download: " .. tostring(err))
            return
        end
        install(release, function(exe, err2)
            if not exe then
                status.error("Couldn't install the GitHub CLI: " .. tostring(err2))
                return
            end
            status.info("Installed the GitHub CLI " .. release.version .. ".")
            callback(exe)
        end)
    end)
end

--- Sign in to a GitHub host, then call opts.onSignedIn().
-- @param host  "github.com"
-- @param opts  { rejected = bool (the saved sign-in was just refused),
--                onSignedIn = function(), useToken = function() (the
--                username/token dialog) }
function github.signIn(host, opts)
    if loginRun or installing then
        return -- already on it; the running flow retries when it finishes
    end

    -- gh may already be signed in: reuse its token without asking. Not after
    -- a rejection, which may be that very token.
    local gh = findGh()
    if gh and not opts.rejected then
        local token = ghToken(gh, host)
        if token then
            status.info("Using the GitHub CLI's sign-in; retrying…")
            useToken(host, nil, token, opts.onSignedIn)
            return
        end
    end

    local message = "GitHub doesn't accept account passwords for Git. Sign in with your "
        .. "browser instead; two-factor authentication works as usual."
    if opts.rejected then
        message = "GitHub didn't accept the saved sign-in. " .. message
    end
    if not gh then
        message = message .. "\n\nGitGud uses the GitHub CLI for this. It isn't installed, so "
            .. "GitGud will download the latest release from github.com/cli/cli (about 15 MB) "
            .. "into its own app data folder and keep it up to date."
    end

    dialog.show({
        title = "Sign in to GitHub",
        message = message,
        ok = gh and "Sign in with browser" or "Download and sign in",
        width = 540,
        alt = { label = "Use a token", action = function()
            opts.useToken()
        end },
        onOk = function()
            withGh(function(exe)
                login(exe, host, opts.onSignedIn)
            end)
            return true
        end,
    })
end

--- Wire gh's output events and the update schedule. Called by views/sync.lua.
function github.init()
    gitgud.on("github.login.output", function(chunk)
        if loginRun then
            loginRun.onOutput(chunk)
        end
    end)
    gitgud.on("github.login.done", function(exitCode)
        if loginRun then
            loginRun.onDone(exitCode)
        end
    end)
    gitgud.on("github.login.error", function(detail)
        if loginRun then
            loginRun.onDone(-1)
        end
        status.error("GitHub sign-in failed: " .. tostring(detail))
    end)

    gitgud.after(15 * 1000, github.checkForUpdate)
    gitgud.every(60 * 60 * 1000, github.checkForUpdate)
end

return github
