--- views/ssh.lua — SSH: your keys, trusting new servers, key passphrases.
--
-- Remotes like git@host:owner/repo.git connect over SSH. The engine offers
-- your SSH agent first (Pageant, the OpenSSH agent, or SSH_AUTH_SOCK), then the
-- usual key files in ~/.ssh (id_ed25519, id_ecdsa, id_rsa).
--
--   * File > SSH keys… lists your public keys, copies one to paste into
--     your Git host, and generates a new ed25519 key (with ssh-keygen,
--     part of OpenSSH).
--   * The first connection to a server asks whether to trust its host key
--     (shown by fingerprint) and remembers it in ~/.ssh/known_hosts. A key
--     that CHANGED is refused with a warning instead.
--   * An encrypted key's passphrase is asked for once and kept in the
--     OS credential store.
--
-- Public API: ssh.keys(), ssh.generate(), ssh.onUnknownHost(detail),
--             ssh.askPassphrase(credentialKey)

local dialog = require("ui.dialog")
local shell = require("core.shell")
local status = require("core.status")
local text = require("core.text")

local ssh = { name = "ssh" }

--- The public key people usually mean (ed25519 first), or nil.
-- @return key row { name, path, publicKey }
local function preferredKey()
    local keys = gitgud.sshKeys()
    for _, name in ipairs({ "id_ed25519", "id_ecdsa", "id_rsa" }) do
        for _, key in ipairs(keys) do
            if key.name == name then
                return key
            end
        end
    end

    return keys[1]
end

--- Show the keys dialog.
function ssh.keys()
    local keys = gitgud.sshKeys()
    local sep = gitgud.platform == "windows" and "\\" or "/"
    local message = nil
    if #keys == 0 then
        message = "You don't have an SSH key yet (none in " .. gitgud.homeDir() .. sep .. ".ssh).\n\n"
            .. "Generate one, then add its public key to your Git host (for example GitHub: "
            .. "Settings > SSH and GPG keys)."
    else
        local lines = { "Public keys in " .. gitgud.homeDir() .. sep .. ".ssh:" }
        for _, key in ipairs(keys) do
            local kind = key.publicKey:match("^(%S+)") or "?"
            local comment = key.publicKey:match("^%S+%s+%S+%s+(.+)$") or ""
            lines[#lines + 1] = "  •  " .. key.name .. "   (" .. kind .. ")   " .. comment
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Copy a public key and add it to your Git host to use SSH remotes. "
            .. "Your SSH agent's keys are tried first."
        message = table.concat(lines, "\n")
    end

    local key = preferredKey()
    dialog.show({
        title = "SSH keys",
        message = message,
        width = 600,
        ok = key and ("Copy " .. key.name .. ".pub") or "Close",
        cancel = key and "Close" or false,
        alt = { label = "Generate new key…", action = ssh.generate },
        onOk = function()
            if key then
                shell.copy(key.publicKey, "public key " .. key.name .. ".pub")
            end
            return true
        end,
    })
end

--- Generate a new ed25519 key with ssh-keygen.
function ssh.generate()
    if not gitgud.findProgram("ssh-keygen") then
        local how = "Generating a key needs ssh-keygen. Install your system's OpenSSH client "
            .. "(the openssh-client package on Debian and Ubuntu, openssh-clients on Fedora)."
        if gitgud.platform == "windows" then
            how = "Generating a key needs ssh-keygen, part of Windows' OpenSSH client (Settings > "
                .. "Apps > Optional features > OpenSSH Client) or Git for Windows."
        elseif gitgud.platform == "macos" then
            how = "Generating a key needs ssh-keygen, which comes with macOS in /usr/bin."
        end
        dialog.alert("ssh-keygen not found", how)
        return
    end

    local target = gitgud.homeDir() .. "/.ssh/id_ed25519"
    if gitgud.pathExists(target) then
        dialog.alert("You already have an ed25519 key",
            target .. " exists. Copy its public key from File > SSH keys… instead; GitGud won't "
                .. "overwrite a key.")
        return
    end

    dialog.show({
        title = "Generate an SSH key",
        message = "Creates " .. target .. " (ed25519). A passphrase protects the key if someone "
            .. "copies the file; GitGud will ask for it once and keep it in the "
            .. shell.names.keyring .. ". Leave it blank for no passphrase.",
        fields = {
            { label = "Label (usually your email)", value = gitgud.globalConfig("user.email") },
            { label = "Passphrase (optional)", value = "", secret = true },
            { label = "Repeat the passphrase", value = "", secret = true },
        },
        ok = "Generate key",
        onOk = function(v)
            local label = text.trim(v.fields[1])
            local passphrase = v.fields[2]
            if passphrase ~= v.fields[3] then
                return false, "The passphrases don't match."
            end
            local result, err = gitgud.runProgram({
                "ssh-keygen", "-q", "-t", "ed25519", "-C", label, "-f", target, "-N", passphrase,
            })
            if not result then
                return false, err
            end
            if result.code ~= 0 then
                return false, text.trim(result.error ~= "" and result.error or result.output)
            end

            local key = preferredKey()
            if key then
                shell.copy(key.publicKey, "the new public key")
            end
            gitgud.after(1, function()
                dialog.alert("Key created",
                    "Your new public key is on the clipboard. Add it to your Git host (GitHub: "
                        .. "Settings > SSH and GPG keys > New SSH key), then use an SSH remote URL "
                        .. "like git@github.com:owner/repo.git.")
            end)
            return true
        end,
    })
end

--- A server we haven't seen: ask before trusting it.
-- @param detail  "host\nfingerprint\nknown_hosts line"
function ssh.onUnknownHost(detail)
    local host, fingerprint, line = detail:match("^([^\n]*)\n([^\n]*)\n(.*)$")
    if not host then
        return
    end

    dialog.show({
        title = "Trust " .. host .. "?",
        message = "This is the first time you connect to " .. host .. " over SSH. Its host key "
            .. "fingerprint is:\n\n    " .. fingerprint .. "\n\nOnly continue if it matches the "
            .. "fingerprint your Git host publishes (e.g. GitHub lists them in its docs). It will "
            .. "be remembered in ~/.ssh/known_hosts.",
        width = 580,
        ok = "Trust and retry",
        onOk = function()
            local ok, err = gitgud.trustHostKey(line)
            if not ok then
                return false, err
            end
            status.info("Trusted " .. host .. "; retrying…")
            require("views.sync").retry()
            return true
        end,
    })
end

--- Ask for an SSH key's passphrase, store it, and retry.
-- @param credentialKey  "ssh-key:<path>"
function ssh.askPassphrase(credentialKey)
    local path = credentialKey:sub(#"ssh-key:" + 1)

    dialog.show({
        title = "Passphrase for " .. text.basename(path),
        message = "Your SSH key " .. path .. " is protected by a passphrase. It's stored in the "
            .. shell.names.keyring .. ", never in plain text.",
        fields = { { label = "Passphrase", value = "", secret = true } },
        ok = "Save and retry",
        onOk = function(v)
            if v.fields[1] == "" then
                return false, "Enter the passphrase."
            end
            if not gitgud.setCredential(credentialKey, "ssh", v.fields[1]) then
                return false, "Could not save the passphrase."
            end
            require("views.sync").retry()
            return true
        end,
    })
end

--- Wire the events the engine raises.
function ssh.init()
    gitgud.on("ssh.unknownHost", ssh.onUnknownHost)
end

return ssh
