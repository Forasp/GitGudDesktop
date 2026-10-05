--- core/p4setup.lua: choosing Git or Perforce, setting up Perforce
-- workspaces, and signing in to Perforce servers. Shared by every
-- interface (the default UI, Depot, and the first-launch picker).
--
-- A Perforce workspace is a folder whose .p4config names the server, user,
-- and workspace; gitgud.openRepo opens it like any repository and every
-- gitgud.* call then runs p4 underneath (docs/P4.md).
--
-- The default backend and the last server used live in the per-user config
-- file "vcs-defaults" (key=value lines: backend, port, user,
-- charset).
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
local PENDING_FILE = "vcs-pending" -- a first-launch setup to run once the interface starts

local openRepo = nil       -- function(path): how this UI opens a repository
local signingIn = false    -- a sign-in dialog is showing (status refreshes ask again)
local pendingStreams = nil -- function(lines) waiting for "p4Streams.done"
local lastSetup = nil      -- the p4CreateWorkspace request running (retried after a login)
local retrySetup = nil     -- that request, when it stopped to ask for a password

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

--- Is `folder` already a Git repository / a Perforce workspace?
local function isGitRepo(folder)
    return folder ~= "" and gitgud.pathExists(folder:gsub("[/\\]+$", "") .. "/.git")
end

local function isP4Workspace(folder)
    return folder ~= "" and gitgud.pathExists(folder:gsub("[/\\]+$", "") .. "/.p4config")
end

--- Do what Backend selection asked for: open the folder, clone into it,
-- start a repository there, or set up a Perforce workspace.
-- @param t  { kind = gitopen | gitclone | gitinit | p4open | p4create, folder,
--             url?, port?, user?, stream?, depotPath?, create? }
local function runSetup(t)
    if t.kind == "gitopen" or t.kind == "p4open" then
        openRepo(t.folder)
    elseif t.kind == "gitclone" then
        require("views.sync").clone(t.url, t.folder)
    elseif t.kind == "gitinit" then
        gitgud.initRepo(t.folder)
    elseif t.kind == "p4create" then
        status().info("Setting up the workspace in " .. t.folder .. "…")
        lastSetup = {
            port = t.port,
            user = t.user,
            root = t.folder,
            stream = t.stream,
            depotPath = t.depotPath,
            create = t.create == true or t.create == "true",
        }
        gitgud.p4CreateWorkspace(lastSetup)
    end
end

local P4_DOWNLOAD = "https://www.perforce.com/downloads/helix-command-line-client-p4"

--- What to do about a missing p4 command-line client, for dialogs.
-- @return one or two sentences
function p4setup.missingP4()
    if gitgud.platform == "windows" then
        return "Install the p4 command-line client first (" .. P4_DOWNLOAD .. "), or set "
            .. "GITGUD_P4 to the full path of p4.exe."
    end
    if gitgud.platform == "macos" then
        return "Install the p4 command-line client first: download p4 from " .. P4_DOWNLOAD
            .. " and put it on your PATH (for example /usr/local/bin). GITGUD_P4 can also name "
            .. "its full path."
    end
    return "Install the p4 command-line client first: download p4 from " .. P4_DOWNLOAD
        .. " and put it on your PATH (for example ~/.local/bin), or install the helix-cli "
        .. "package from Perforce's package repository. GITGUD_P4 can also name its full path."
end

--- Open the p4 download page in the browser.
function p4setup.openP4Download()
    gitgud.openExternal(P4_DOWNLOAD)
end

--- Backend selection: one tab for Git and one for Perforce. Each picks the
-- folder for a workspace: an existing repository or workspace opens as it
-- is; otherwise Git clones a URL into it (or starts a new repository), and
-- Perforce maps a stream or depot folder there. The tab used becomes the
-- default for new repositories. Opened on first launch and from the File
-- (default UI) or Connection (Depot) menu.
-- @param onDone  function() run after Continue or Cancel
-- @param opts    { firstLaunch = true }: nothing pre-selected, a folder is
--                required, and the setup runs once the chosen interface
--                starts (p4setup.init), since the picker restarts it
function p4setup.askDefaultBackend(onDone, opts)
    opts = opts or {}
    local d = p4setup.defaults()
    local required = opts.firstLaunch == true
    local p4Message = "Choose the folder for your workspace. GitGud connects to the workspace you "
        .. "already have there, or maps a stream (//depot/main) or depot folder into it. Tick Create "
        .. "to start a new stream on the server."
    if not gitgud.p4Available() then
        p4Message = p4Message .. " " .. p4setup.missingP4()
    end

    local function folderOf(v)
        return text.trim(v.fields[v.tab == 1 and 1 or 3] or "")
    end

    dialog.show({
        title = "Backend selection",
        message = "Choose Git or Perforce for your workspace. New repositories use the one you "
            .. "pick; you can still clone or create the other kind each time.",
        tabs = {
            {
                label = "Git",
                message = "Choose the folder for your workspace. A folder that's already a Git "
                    .. "repository opens as it is; otherwise clone a URL into it, or leave the URL "
                    .. "empty to start a new repository there.",
                fields = {
                    { label = "Local folder", value = "", browse = true },
                    {
                        label = "Git URL to clone (leave empty to create a new repository)",
                        value = "",
                        enabled = function(v)
                            return v.tab == 1 and folderOf(v) ~= "" and not isGitRepo(folderOf(v))
                        end,
                    },
                },
            },
            {
                label = "Perforce",
                message = p4Message,
                fields = {
                    { label = "Server (P4PORT), e.g. ssl:perforce.example.com:1666", value = d.port },
                    { label = "User", value = d.user },
                    { label = "Local folder", value = "", browse = true },
                    {
                        label = "Stream or depot path, e.g. //project/main (empty: your existing workspace for this folder)",
                        value = "",
                        enabled = function(v)
                            return v.tab == 2 and folderOf(v) ~= "" and not isP4Workspace(folderOf(v))
                        end,
                    },
                },
                checks = {
                    { label = "Create the stream if it doesn't exist (a new repository)", value = false },
                    { label = "Classic depot folder, not a stream", value = false },
                },
            },
        },
        tab = required and 0 or (d.backend == "p4" and 2 or 1),
        ok = "Continue",
        alt = not gitgud.p4Available() and {
            label = "Get p4…",
            stayOpen = true,
            action = p4setup.openP4Download,
        } or nil,
        -- Continue waits for a tab and what that tab needs.
        canSubmit = function(v)
            local folder = folderOf(v)
            if v.tab == 1 then
                return folder ~= "" or not required
            end
            if v.tab ~= 2 or text.trim(v.fields[1] or "") == "" or text.trim(v.fields[2] or "") == "" then
                return false
            end
            if folder == "" then
                return not required
            end
            -- An empty stream connects to the server's workspace for this folder.
            local path = text.trim(v.fields[4] or "")
            return isP4Workspace(folder) or path == "" or path:match("^//[^/]+/.+") ~= nil
        end,
        onOk = function(v)
            local folder = folderOf(v)
            local setup = nil
            if v.tab == 1 then
                p4setup.saveDefaults({ backend = "git" })
                local url = text.trim(v.fields[2] or "")
                if folder ~= "" then
                    setup = { kind = isGitRepo(folder) and "gitopen" or (url ~= "" and "gitclone" or "gitinit"),
                        folder = folder, url = url }
                end
            else
                local port = text.trim(v.fields[1])
                local user = text.trim(v.fields[2])
                p4setup.saveDefaults({ backend = "p4", port = port, user = user })
                if folder ~= "" then
                    local path = text.trim(v.fields[4] or ""):gsub("/%.%.%.$", ""):gsub("/+$", "")
                    local classic = v.checks[2]
                    setup = {
                        kind = isP4Workspace(folder) and "p4open" or "p4create",
                        folder = folder,
                        port = port,
                        user = user,
                        stream = not classic and path or nil,
                        depotPath = classic and path or nil,
                        create = v.checks[1] and not classic,
                    }
                end
            end
            if setup and opts.firstLaunch then
                -- The picker restarts into the chosen interface; it runs this.
                local lines = {}
                for k, value in pairs(setup) do
                    lines[#lines + 1] = k .. "=" .. tostring(value)
                end
                gitgud.configWrite(PENDING_FILE, table.concat(lines, "\n") .. "\n")
            elseif setup then
                runSetup(setup)
            end
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
            { label = "Password (only if the server asks; saved in the " .. require("core.shell").names.keyring .. ")", value = "", secret = true },
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
                return false, p4setup.missingP4()
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
    local message = "Saved in the " .. require("core.shell").names.keyring .. ", never in plain text."
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
            if retrySetup then
                local again = retrySetup
                retrySetup = nil
                lastSetup = again
                status().info("Setting up the workspace in " .. again.root .. "…")
                gitgud.p4CreateWorkspace(again)
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
        lastSetup = nil
        status().ok("Workspace ready in " .. root)
        openRepo(root)
    end)
    gitgud.on("p4CreateWorkspace.error", function(detail)
        local message = tostring(detail)
        -- Stopped for a password: the sign-in dialog is up; go again after it.
        if message:find("P4PASSWD", 1, true) or message:lower():find("login again", 1, true) then
            retrySetup = lastSetup
            status().warn("Log in to continue setting up the workspace.")
            return
        end
        lastSetup = nil
        status().error("Setting up the workspace failed: " .. message)
    end)

    -- A first-launch Backend selection waiting for this interface to start.
    local raw = gitgud.configRead(PENDING_FILE) or ""
    if raw ~= "" then
        gitgud.configWrite(PENDING_FILE, "")
        local t = {}
        for line in raw:gmatch("[^\r\n]+") do
            local k, v = line:match("^(%w+)=(.*)$")
            if k then
                t[k] = v
            end
        end
        if t.kind then
            gitgud.after(300, function()
                runSetup(t)
            end)
        end
    end
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
