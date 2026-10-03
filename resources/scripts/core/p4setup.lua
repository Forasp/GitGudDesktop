--- core/p4setup.lua: choosing Git or Perforce, setting up Perforce
-- workspaces, and signing in to Perforce servers. Shared by every
-- interface (the default UI, Depot, and the first-launch picker).
--
-- A Perforce workspace is a folder whose .p4config names the server, user,
-- and workspace; gitgud.openRepo opens it like any repository and every
-- gitgud.* call then runs p4 underneath (docs/P4.md).
--
-- The default backend and the last server used live in the per-user config
-- file "vcs-defaults" (key=value lines: backend, port, user, charset).
--
-- Public API: p4setup.defaults(), p4setup.saveDefaults(t),
--   p4setup.isP4(), p4setup.askDefaultBackend(onDone),
--   p4setup.newWorkspace(opts), p4setup.signIn(host, rejected, retry),
--   p4setup.init(onOpen)

local dialog = require("ui.dialog")
-- Lazy: the picker has no status bar.
local function status()
    return require("core.status")
end
local text = require("core.text")

local p4setup = {}

local DEFAULTS_FILE = "vcs-defaults"

local openRepo = nil       -- function(path): how this UI opens a repository
local signingIn = false    -- a sign-in dialog is showing (status refreshes ask again)
local pendingStreams = nil -- function(lines) waiting for "p4Streams.done"

--- The saved defaults.
-- @return { backend = "git" | "p4", port, user, charset }
function p4setup.defaults()
    local out = { backend = "git", port = "", user = "", charset = "" }
    for line in (gitgud.configRead(DEFAULTS_FILE) or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^(%w+)=(.*)$")
        if k then
            out[k] = v
        end
    end

    return out
end

--- Save defaults (fields not given keep their value).
-- @param t  { backend?, port?, user?, charset? }
function p4setup.saveDefaults(t)
    local d = p4setup.defaults()
    for k, v in pairs(t) do
        d[k] = v
    end
    local lines = {}
    for _, k in ipairs({ "backend", "port", "user", "charset" }) do
        lines[#lines + 1] = k .. "=" .. (d[k] or "")
    end
    gitgud.configWrite(DEFAULTS_FILE, table.concat(lines, "\n") .. "\n")
end

--- Is the open repository a Perforce workspace?
-- @return boolean
function p4setup.isP4()
    return gitgud.backend() == "p4"
end

--- Ask which version control GitGud should set up new repositories with
-- (first launch, or Preferences).
-- @param onDone  function() run after the choice is saved (or cancelled)
function p4setup.askDefaultBackend(onDone)
    local d = p4setup.defaults()
    local available = gitgud.p4Available()
    local message = "GitGud works the same way on Git and on Perforce. This sets what new "
        .. "repositories and clones use by default; you can still pick the other each time."
    if not available then
        message = message .. " The p4 command-line client isn't installed yet: install it "
            .. "(or set GITGUD_P4 to p4.exe) before using a Perforce server."
    end

    dialog.show({
        title = "Git or Perforce?",
        message = message,
        fields = {
            { label = "Perforce server (P4PORT), e.g. ssl:perforce.example.com:1666", value = d.port },
            { label = "Perforce user", value = d.user },
        },
        checks = { { label = "I use a Perforce server (P4) by default", value = d.backend == "p4" } },
        ok = "Continue",
        onOk = function(v)
            local p4 = v.checks[1]
            local port = text.trim(v.fields[1])
            local user = text.trim(v.fields[2])
            if p4 and (port == "" or user == "") then
                return false, "Enter the Perforce server and your user name, or untick Perforce."
            end
            p4setup.saveDefaults({ backend = p4 and "p4" or "git", port = port, user = user })
            if onDone then
                onDone()
            end
            return true
        end,
        onCancel = function()
            if onDone then
                onDone()
            end
        end,
    })
end

--- Parse "p4Streams.done" lines.
-- @param detail  "stream\tname\tparent\ttype" lines
-- @return array of { stream, name, parent, type }
local function parseStreams(detail)
    local out = {}
    for line in (detail or ""):gmatch("[^\n]+") do
        local stream, name, parent, kind = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if stream then
            out[#out + 1] = { stream = stream, name = name, parent = parent, type = kind }
        end
    end
    table.sort(out, function(a, b)
        return a.stream < b.stream
    end)

    return out
end

--- Set up a Perforce workspace: map an existing stream or depot folder
-- (like a clone), or create a new stream (a new repository). The workspace
-- opens when it's ready.
-- @param opts  { create = boolean, folder = default parent folder }
function p4setup.newWorkspace(opts)
    opts = opts or {}
    local d = p4setup.defaults()
    local spec

    spec = {
        title = opts.create and "Create a new Perforce stream" or "Set up a Perforce workspace",
        message = opts.create
            and "Creates the stream (and its stream depot, which needs admin rights) and a workspace for it."
            or "Maps a stream (//depot/main) or, in a classic depot, a folder (//depot/project/main). "
                .. "Branches are then streams, or that folder's siblings.",
        fields = {
            { label = "Server (P4PORT)", value = d.port },
            { label = "User", value = d.user },
            { label = "Password (only if the server asks; saved in Windows Credential Manager)", value = "", secret = true },
            { label = opts.create and "New stream, e.g. //project/main" or "Stream or depot path", value = "" },
            { label = "Local folder (the workspace folder is created inside)", value = opts.folder or "", browse = true },
        },
        checks = {
            { label = "Create the stream if it doesn't exist", value = opts.create == true },
            { label = "Classic depot folder, not a stream", value = false },
        },
        ok = opts.create and "Create" or "Set up workspace",
        alt = {
            label = "Find streams",
            stayOpen = true,
            action = function(v)
                local port = text.trim(v.fields[1])
                local user = text.trim(v.fields[2])
                if port == "" or user == "" then
                    status().warn("Enter the server and user first.")
                    return
                end
                if v.fields[3] ~= "" then
                    gitgud.setCredential("p4:" .. port, user, v.fields[3])
                end
                status().info("Asking " .. port .. " for its streams…")
                pendingStreams = function(list)
                    local names = {}
                    for _, s in ipairs(list) do
                        names[#names + 1] = s.stream .. "  (" .. s.type .. ")"
                    end
                    if #names == 0 then
                        status().warn("No streams on " .. port .. ". Use a depot path, or create a stream.")
                        return
                    end
                    status().ok(#names .. " stream(s): " .. table.concat(names, ", "))
                end
                gitgud.p4ListStreams({ port = port, user = user })
            end,
        },
        onOk = function(v)
            local port = text.trim(v.fields[1])
            local user = text.trim(v.fields[2])
            local password = v.fields[3]
            local path = text.trim(v.fields[4]):gsub("/%.%.%.$", ""):gsub("/+$", "")
            local parent = text.trim(v.fields[5])
            if port == "" or user == "" then
                return false, "Enter the server and your user name."
            end
            if not path:match("^//[^/]+/.+") then
                return false, "Name a stream or depot path like //depot/main."
            end
            if parent == "" then
                return false, "Choose a local folder."
            end
            if not gitgud.p4Available() then
                return false, "The p4 command-line client isn't installed (or set GITGUD_P4 to p4.exe)."
            end

            local classic = v.checks[2]
            local name = path:match("([^/]+)$")
            local root = parent:gsub("[/\\]+$", "") .. "/" .. name
            if password ~= "" then
                gitgud.setCredential("p4:" .. port, user, password)
            end
            p4setup.saveDefaults({ port = port, user = user })

            local setup = {
                port = port,
                user = user,
                password = password,
                root = root,
                create = v.checks[1] and not classic,
            }
            if classic then
                setup.depotPath = path
            else
                setup.stream = path
            end
            status().info("Setting up the workspace in " .. root .. "…")
            gitgud.p4CreateWorkspace(setup)
            return true
        end,
    }
    dialog.show(spec)
end

--- Ask for a Perforce password ("p4:<port>" credential), then retry.
-- @param host      "p4:<P4PORT>"
-- @param rejected  true when the saved password was just refused
-- @param retry     function() run after saving (may be nil)
function p4setup.signIn(host, rejected, retry)
    if signingIn then
        return
    end
    signingIn = true
    local port = host:sub(4)
    local user = p4setup.isP4() and (gitgud.config("p4.user") or "") or ""
    if user == "" then
        user = p4setup.defaults().user
    end
    local message = "Saved in the Windows Credential Manager, never in plain text."
    if rejected then
        message = port .. " didn't accept the saved password, so it was removed. " .. message
    end

    dialog.show({
        title = "Log in to " .. port,
        message = message,
        fields = {
            { label = "User", value = user },
            { label = "Password", value = "", secret = true },
        },
        ok = "Log in",
        onOk = function(v)
            local name = text.trim(v.fields[1])
            local pass = v.fields[2]
            if name == "" or pass == "" then
                return false, "Enter your user name and password."
            end
            local ok, err = gitgud.p4Login(port, name, pass)
            if not ok then
                return false, err or "The server refused the password."
            end
            gitgud.setCredential(host, name, pass)
            signingIn = false
            status().ok("Logged in to " .. port .. ".")
            if retry then
                retry()
            end
            gitgud.emit("status.changed", "")
            return true
        end,
        onCancel = function()
            signingIn = false
        end,
    })
end

--- Wire the worker events.
-- @param onOpen  function(path) that opens (and remembers) a repository
function p4setup.init(onOpen)
    openRepo = onOpen or gitgud.openRepo

    gitgud.on("p4CreateWorkspace.done", function(root)
        status().ok("Workspace ready in " .. root)
        openRepo(root)
    end)
    gitgud.on("p4CreateWorkspace.error", function(detail)
        status().error("Setting up the workspace failed: " .. tostring(detail))
    end)
    gitgud.on("p4Streams.done", function(detail)
        if pendingStreams then
            local callback = pendingStreams
            pendingStreams = nil
            callback(parseStreams(detail))
        end
    end)
    gitgud.on("p4Streams.error", function(detail)
        pendingStreams = nil
        status().error("Listing streams failed: " .. tostring(detail))
    end)
end

return p4setup
