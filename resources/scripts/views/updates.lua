--- views/updates.lua: Help ▸ Check for Updates…, shared by every interface.
--
-- An update downloads in the background while you work (progress on the
-- status bar) and is installed the next time GitGud starts, or right away
-- with "Restart now". Installing needs every GitGud window closed; opening
-- another copy is always fine. The engine side is app/Updater.h and
-- gitgud-patcher.exe (see docs/USAGE.md, "Updates").
--
-- With "Check for updates automatically" on (the default), release builds
-- check a few seconds after starting and then about once a day, and offer
-- each new version once; Help ▸ Check for Updates… always asks.
--
-- Public API: updates.show(), updates.menuItem(), updates.init()

local dialog = require("ui.dialog")
local settings = require("core.settings")
local status = require("core.status")

local updates = { name = "updates" }

local CHECK_EVERY_S = 20 * 3600 -- between automatic checks
local FIRST_CHECK_MS = 8000     -- after starting

local interactive = false -- the running check was asked for from the menu
local timers = {}

--- "3.4 MB" / "820 KB".
local function size(bytes)
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

--- Split a tab-separated event detail.
local function fields(detail)
    local out = {}
    for field in (detail .. "\t"):gmatch("([^\t]*)\t") do
        out[#out + 1] = field
    end
    return out
end

--- Hand over to the patcher and quit; if other copies are open, ask for them
-- to be closed first.
local function restart()
    local ok, err, copies = gitgud.updateRestart()
    if ok then
        gitgud.emit("window.close", "")
        return
    end
    if copies then
        dialog.show({
            title = "Close other GitGud Desktop windows",
            message = "Close all GitGud Desktop windows to install the update. "
                .. copies .. (copies == 1 and " other copy is" or " other copies are")
                .. " still open.\n\nChoose Later to keep working: the update is installed the "
                .. "next time GitGud starts with no other copy open.",
            ok = "Retry",
            cancel = "Later",
            onOk = function()
                gitgud.after(10, restart)
                return true
            end,
        })
        return
    end
    dialog.alert("Update", "The update couldn't be installed: " .. tostring(err))
end

local function readyDialog(version)
    dialog.show({
        title = "Update ready",
        message = "GitGud Desktop " .. version .. " is downloaded.\n\nRestart to install it; "
            .. "your repositories and tabs come back as they were. If you'd rather keep "
            .. "working, it's installed the next time GitGud starts.",
        ok = "Restart now",
        cancel = "Later",
        onOk = function()
            gitgud.after(10, restart)
            return true
        end,
    })
end

local function startDownload()
    local ok, err = gitgud.updateDownload()
    if ok then
        status.info("Downloading the update…")
    else
        status.error("Couldn't download the update: " .. tostring(err))
    end
end

local function availableDialog(version, notes, bytes, files)
    local info = gitgud.updateInfo()
    dialog.show({
        title = "Update available",
        message = "GitGud Desktop " .. version .. " is available (you have " .. info.current .. ").\n\n"
            .. "Only what changed is downloaded: " .. size(bytes) .. " (" .. files
            .. (files == 1 and " file" or " files") .. "). It downloads in the background "
            .. "while you keep working and is installed when GitGud restarts.",
        ok = "Download",
        cancel = "Later",
        alt = notes ~= "" and {
            label = "Release notes",
            stayOpen = true,
            action = function()
                local opened, err = gitgud.openExternal(notes)
                if not opened then
                    status.error("Couldn't open the release notes: " .. tostring(err))
                end
            end,
        } or nil,
        onOk = function()
            startDownload()
            return true
        end,
    })
end

--- Start a check. `ask` = asked for from the menu (always answer, even
-- "up to date"); otherwise quiet unless there's a version not offered yet.
local function check(ask)
    interactive = ask
    local ok, err = gitgud.updateCheck()
    if not ok then
        if ask then
            dialog.alert("Couldn't check for updates", tostring(err))
        end
        return
    end
    settings.set("updateLastCheck", os.time())
    if ask then
        status.info("Checking for updates…")
    end
end

--- Help ▸ Check for Updates…
function updates.show()
    local info = gitgud.updateInfo()
    if gitgud.platform ~= "windows" then
        dialog.alert("Updates", "GitGud Desktop " .. info.current .. " is updated through your "
            .. "system's package manager (for example Software Updater, apt, or dnf).")
    elseif not info.packaged then
        dialog.alert("Updates", "This is a developer build (" .. info.current .. "). Only release "
            .. "builds, installed or unzipped, update themselves.")
    elseif info.staged ~= "" then
        readyDialog(info.staged)
    elseif info.downloading then
        dialog.show({
            title = "Update",
            message = "An update is downloading in the background (see the status bar).",
            ok = "Keep downloading",
            cancel = "Cancel download",
            onCancel = function()
                gitgud.updateCancel()
            end,
        })
    else
        check(true)
    end
end

--- The Help-menu entry.
function updates.menuItem()
    return { label = "Check for Updates…", action = updates.show }
end

--- After an update: say what happened (the patcher leaves a report).
local function showReport()
    local report = gitgud.updateReport()
    if not report then
        return
    end
    local first = report:match("^[^\n]*") or ""
    local edited = report:match("\nedited ([^\n]+)")
    if first:match("^ok ") then
        local message = "GitGud Desktop is now version " .. first:sub(4) .. "."
        if edited then
            message = message .. "\n\nFiles you had edited in its folder were replaced; your "
                .. "copies are saved in:\n" .. edited
        end
        dialog.alert("Updated", message)
    else
        dialog.alert("Update not installed", (first:gsub("^failed ", ""))
            .. "\n\nGitGud Desktop is unchanged. Try Help ▸ Check for Updates… again.")
    end
end

local function onChecked(detail)
    local f = fields(detail)
    local ask = interactive
    interactive = false
    if f[1] == "available" then
        local version = f[2]
        if ask or settings.get("updateOffered", "") ~= version then
            settings.set("updateOffered", version)
            availableDialog(version, f[3] or "", tonumber(f[4]) or 0, tonumber(f[5]) or 0)
        end
    elseif ask then
        dialog.alert("No updates", "GitGud Desktop " .. gitgud.updateInfo().current
            .. " is the latest version.")
    end
end

local function automaticCheck()
    local info = gitgud.updateInfo()
    if not settings.get("updateCheck", true) or not info.packaged or info.downloading
        or info.staged ~= "" then
        return
    end
    if os.time() - tonumber(settings.get("updateLastCheck", 0)) >= CHECK_EVERY_S then
        check(false)
    end
end

function updates.init()
    gitgud.on("update.check.done", onChecked)
    gitgud.on("update.check.error", function(detail)
        local ask = interactive
        interactive = false
        if ask then
            dialog.alert("Couldn't check for updates", detail)
        else
            print("[update] automatic check failed: " .. tostring(detail))
        end
    end)
    gitgud.on("update.progress", function(detail)
        local done, total = detail:match("^(%d+) (%d+)$")
        done, total = tonumber(done), tonumber(total)
        if done and total then
            local percent = total > 0 and math.floor(done * 100 / total) or 100
            status.info(string.format("Downloading the update… %d%% of %s", percent, size(total)))
        end
    end)
    gitgud.on("update.download.done", function(version)
        status.ok("Update " .. version .. " downloaded.")
        readyDialog(version)
    end)
    gitgud.on("update.download.error", function(detail)
        if detail == "cancelled" then
            status.info("Update download cancelled.")
        else
            status.error("The update download failed: " .. tostring(detail))
        end
    end)

    for _, timer in ipairs(timers) do
        gitgud.cancelTimer(timer)
    end
    timers = {
        gitgud.after(FIRST_CHECK_MS, automaticCheck),
        gitgud.every(3600 * 1000, automaticCheck),
    }
    showReport()
end

return updates
