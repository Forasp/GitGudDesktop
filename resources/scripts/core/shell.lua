--- core/shell.lua — hand things off to the rest of the desktop.
--
-- Wraps gitgud.spawn / showInFolder / openExternal / setClipboard with the
-- user's preferences from the Options dialog:
--   editorCommand  e.g.  code "%s"      (empty: the OS default program)
--   shellCommand   e.g.  wt.exe -d "%s" (empty: a Command Prompt, Terminal
--                  on macOS, the desktop's terminal on Linux)
-- "%s" is replaced by the path; without it the path is appended.

local settings = require("core.settings")
local status = require("core.status")

local shell = {}

local WINDOWS = gitgud.platform == "windows"

-- Linux has no single terminal: take $TERMINAL, then the usual ones.
local DEFAULT_SHELLS = {
    windows = 'cmd.exe /K cd /d "%s"',
    macos = 'open -a Terminal "%s"',
    linux = 'cd "%s" && for t in "$TERMINAL" x-terminal-emulator gnome-terminal konsole '
        .. 'xfce4-terminal kitty alacritty xterm; do [ -n "$t" ] && command -v "$t" >/dev/null '
        .. '&& exec "$t"; done',
}
local DEFAULT_SHELL = DEFAULT_SHELLS[gitgud.platform] or DEFAULT_SHELLS.linux

local NAMES = {
    windows = {
        fileManager = "Explorer",
        trash = "Recycle Bin",
        keyring = "Windows Credential Manager",
        terminal = 'wt.exe -d "%s" (blank: Command Prompt)',
    },
    macos = {
        fileManager = "Finder",
        trash = "Trash",
        keyring = "macOS Keychain",
        terminal = 'open -a Terminal "%s" (blank: Terminal)',
    },
    linux = {
        fileManager = "File Manager",
        trash = "Trash",
        keyring = "system keyring",
        terminal = 'konsole --workdir "%s" (blank: the desktop\'s terminal)',
    },
}

--- What this OS calls its desktop pieces, for UI text:
-- `fileManager` ("Explorer"), `trash` ("Recycle Bin"), `keyring`
-- ("Windows Credential Manager"), `terminal` (an example terminal command
-- and what blank means).
shell.names = NAMES[gitgud.platform] or NAMES.linux

--- A path as a comparison key: forward slashes, no trailing separator, and
-- lowercase where the file system ignores case (Windows, macOS).
-- @param path  a path
-- @return comparison key
function shell.pathKey(path)
    local key = path:gsub("\\", "/"):gsub("/+$", "")
    if gitgud.platform == "linux" then
        return key
    end
    return key:lower()
end

--- Put a path into a command template.
-- @param template  command with an optional %s
-- @param path      file or folder path
-- @return the command line
local function fill(template, path)
    if template:find("%%s") then
        return (template:gsub("%%s", (path:gsub("%%", "%%%%"))))
    end

    return template .. ' "' .. path .. '"'
end

--- Turn forward slashes into backslashes on Windows (its tools prefer them).
-- @param path  a path
-- @return the native form
local function native(path)
    if not WINDOWS then
        return path
    end
    return (path:gsub("/", "\\"))
end

--- Open a file or folder in the configured editor (or the OS default app).
-- @param path  absolute path
function shell.openInEditor(path)
    local template = settings.get("editorCommand", "")
    local ok = nil
    local err = nil

    if template == "" then
        ok, err = gitgud.openExternal(native(path))
    else
        ok, err = gitgud.spawn(fill(template, native(path)), "")
    end

    status.report(nil, ok, err)
end

--- Open a terminal in a folder.
-- @param dir  absolute folder path
function shell.openTerminal(dir)
    local template = settings.get("shellCommand", "")
    if template == "" then
        template = DEFAULT_SHELL
    end

    local ok, err = gitgud.spawn(fill(template, native(dir)), native(dir))
    status.report(nil, ok, err)
end

--- Reveal a file (or folder) in the file manager.
-- @param path  absolute path
function shell.showInFolder(path)
    local ok, err = gitgud.showInFolder(native(path))
    status.report(nil, ok, err)
end

--- Open with the OS default program.
-- @param path  absolute path
function shell.openDefault(path)
    local ok, err = gitgud.openExternal(native(path))
    status.report(nil, ok, err)
end

--- Copy text to the clipboard and say so.
-- @param value  text to copy
-- @param what   short description for the status bar ("SHA", "path")
function shell.copy(value, what)
    if gitgud.setClipboard(value) then
        status.ok("Copied " .. (what or "text") .. " to the clipboard.")
    else
        status.error("Could not access the clipboard.")
    end
end

return shell
