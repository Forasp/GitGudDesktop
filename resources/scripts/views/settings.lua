--- views/settings.lua — the Options dialog and Repository settings.
--
-- Options (File > Options…, Ctrl+,) edits your global git identity and
-- default branch name (~/.gitconfig) plus app preferences kept by
-- core/settings.lua. Repository settings edits this repository's origin
-- remote, an optional per-repository identity, and its .gitignore (other
-- remotes are managed from the branch tree — views/remotes.lua).
--
-- Public API: settingsView.options(), settingsView.repository(),
-- settingsView.switchInterface()

local app = require("core.app")
local dialog = require("ui.dialog")
local repo = require("core.repo")
local settings = require("core.settings")
local status = require("core.status")
local text = require("core.text")

local settingsView = { name = "settings" }

local repoDialogToken = nil
local shownValues = {}      -- what the repository dialog was opened with

--- The Options dialog.
function settingsView.options()
    dialog.show({
        title = "Options",
        width = 560,
        fields = {
            { label = "Name (used for your commits)", value = gitgud.globalConfig("user.name") },
            { label = "Email", value = gitgud.globalConfig("user.email") },
            { label = "Default branch name for new repositories", value = gitgud.globalConfig("init.defaultBranch") },
            { label = 'External editor command, e.g. code "%s" (blank: the default program)', value = settings.get("editorCommand", "") },
            { label = "Terminal command, e.g. " .. require("core.shell").names.terminal, value = settings.get("shellCommand", "") },
        },
        checks = {
            { label = "Ask before discarding changes", value = settings.get("confirmDiscard", true) },
            { label = "Ask before force pushing", value = settings.get("confirmForcePush", true) },
            { label = "Fetch in the background every 15 minutes", value = settings.get("autoFetch", true) },
            -- Only Windows updates itself; elsewhere the package manager does.
            gitgud.platform == "windows"
                and { label = "Check for updates automatically", value = settings.get("updateCheck", true) }
                or nil,
        },
        ok = "Save",
        alt = { label = "Switch UI…", action = settingsView.switchInterface },
        onOk = function(v)
            local identity = {
                { "user.name", text.trim(v.fields[1]) },
                { "user.email", text.trim(v.fields[2]) },
                { "init.defaultBranch", text.trim(v.fields[3]) },
            }
            for _, entry in ipairs(identity) do
                if entry[2] ~= gitgud.globalConfig(entry[1]) then
                    local ok, err = gitgud.setGlobalConfig(entry[1], entry[2])
                    if not ok then
                        return false, err
                    end
                end
            end

            settings.set("editorCommand", text.trim(v.fields[4]))
            settings.set("shellCommand", text.trim(v.fields[5]))
            settings.set("confirmDiscard", v.checks[1])
            settings.set("confirmForcePush", v.checks[2])
            settings.set("autoFetch", v.checks[3])
            if gitgud.platform == "windows" then
                settings.set("updateCheck", v.checks[4])
            end

            require("views.sync").scheduleAutoFetch()
            status.ok("Options saved.")
            return true
        end,
    })
end

--- Open the user-interface picker (File > Switch user interface…, or the
-- Options dialog's "Switch UI…" button): choose the default UI, the Depot
-- UI, or a UI package from any folder. The picker runs in place of this UI
-- and comes back here on Cancel.
function settingsView.switchInterface()
    local ok, err = gitgud.showUiPicker()
    if not ok then
        status.error(err or "The interface picker isn't available.")
    end
end

--- Commit signing (File > Commit signing…): commit.gpgsign, gpg.format, and
-- user.signingkey in your global ~/.gitconfig — the same settings the git
-- command line uses. Every commit GitGud makes (commit, amend, merge,
-- revert, cherry-pick, rebase) is then signed with gpg, or ssh-keygen for
-- SSH signing.
function settingsView.signing()
    local format = gitgud.globalConfig("gpg.format")
    if format == "" then
        format = "openpgp"
    end
    local key = gitgud.globalConfig("user.signingkey")
    local tools = {}
    for _, name in ipairs({ "gpg", "ssh-keygen" }) do
        tools[#tools + 1] = name .. ": " .. (gitgud.findProgram(name) or "not found")
    end

    dialog.show({
        title = "Commit signing",
        width = 600,
        message = "Signed commits prove they came from you (hosts show them as \"Verified\"). "
            .. "Use a GPG key (format openpgp; the key id from gpg --list-secret-keys) or an SSH "
            .. "key (format ssh; the path of the key, e.g. ~/.ssh/id_ed25519) — and add the "
            .. "same key to your Git host as a signing key.\n\n" .. table.concat(tools, "    "),
        fields = {
            { label = "Format: openpgp or ssh", value = format },
            { label = "Signing key (blank: gpg's default key)", value = key },
        },
        checks = {
            { label = "Sign every commit", value = gitgud.globalConfig("commit.gpgsign") == "true" },
        },
        ok = "Save",
        onOk = function(v)
            local newFormat = text.trim(v.fields[1]):lower()
            local newKey = text.trim(v.fields[2])
            if newFormat ~= "openpgp" and newFormat ~= "ssh" then
                return false, "The format is openpgp or ssh."
            end
            if newFormat == "ssh" and newKey == "" then
                return false, "SSH signing needs the path of your SSH key."
            end

            local values = {
                { "gpg.format", newFormat == "openpgp" and "" or newFormat },
                { "user.signingkey", newKey },
                { "commit.gpgsign", v.checks[1] and "true" or "" },
            }
            for _, entry in ipairs(values) do
                if entry[2] ~= gitgud.globalConfig(entry[1]) then
                    local ok, err = gitgud.setGlobalConfig(entry[1], entry[2])
                    if not ok then
                        return false, err
                    end
                end
            end
            status.ok(v.checks[1] and "Commits will be signed." or "Commit signing is off.")
            return true
        end,
    })
end

--- Close the repository settings dialog.
local function closeRepository()
    dialog.hideModal("RepoSettingsDialog", repoDialogToken)
    repoDialogToken = nil
end

--- The URL of the "origin" remote ("" when there is none).
-- @return url
local function originUrl()
    for _, remote in ipairs(repo.state().remotes) do
        if remote.name == "origin" then
            return remote.url
        end
    end

    return ""
end

--- Save the repository settings dialog.
local function saveRepository()
    local url = text.trim(gitgud.getText("RepoSettingsRemoteEdit"))
    local name = text.trim(gitgud.getText("RepoSettingsNameEdit"))
    local email = text.trim(gitgud.getText("RepoSettingsEmailEdit"))
    local ignore = gitgud.getText("RepoSettingsIgnoreEdit")

    -- Change the URL in place: removing and re-adding origin would drop its
    -- branches and every upstream that tracks it. Clearing it removes origin.
    if url ~= shownValues.url then
        local ok, err = true, nil
        if shownValues.url == "" then
            ok, err = gitgud.addRemote("origin", url)
        elseif url == "" then
            ok, err = gitgud.removeRemote("origin")
        else
            ok, err = gitgud.setRemoteUrl("origin", url)
        end
        if not ok then
            status.error(err or "Could not set the remote.")
            return
        end
    end

    -- Blank clears the per-repository value, falling back to the global one.
    if name ~= shownValues.name then
        gitgud.setConfig("user.name", name)
    end
    if email ~= shownValues.email then
        gitgud.setConfig("user.email", email)
    end

    -- CEGUI's multi-line editbox always keeps a trailing newline.
    if ignore:gsub("%s+$", "") ~= shownValues.ignore:gsub("%s+$", "") then
        local content = ignore:gsub("%s+$", "")
        if content ~= "" then
            content = content .. "\n"
        end
        gitgud.writeRepoFile(".gitignore", content)
    end

    closeRepository()
    status.ok("Repository settings saved.")
    app.requestRefresh()
end

--- Open Repository settings for the current repository.
function settingsView.repository()
    if not repo.state().open then
        status.warn("Open a repository first.")
        return
    end

    shownValues = {
        url = originUrl(),
        name = gitgud.config("user.name"),
        email = gitgud.config("user.email"),
        ignore = gitgud.readRepoFile(".gitignore") or "",
    }

    gitgud.setText("RepoSettingsTitle", text.escape("Repository settings — " .. repo.state().name))
    gitgud.setText("RepoSettingsRemoteEdit", shownValues.url)
    gitgud.setText("RepoSettingsNameEdit", shownValues.name)
    gitgud.setText("RepoSettingsEmailEdit", shownValues.email)
    gitgud.setText("RepoSettingsIgnoreEdit", shownValues.ignore)

    repoDialogToken = dialog.showModal("RepoSettingsDialog", closeRepository)
    gitgud.focus("RepoSettingsRemoteEdit")
end

--- Wire the repository settings buttons.
function settingsView.init()
    gitgud.on("RepoSettingsSaveButton.clicked", saveRepository)
    gitgud.on("RepoSettingsCancelButton.clicked", closeRepository)
end

return settingsView
