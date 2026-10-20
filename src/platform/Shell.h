#pragma once

// -----------------------------------------------------------------------------
// Shell — thin wrappers over the OS desktop shell: open files/URLs, reveal a
// file in the file manager, launch an editor or terminal, move files to the
// recycle bin, pick a folder, and put text on the clipboard.
//
// Everything is best effort and returns false (with a message) on failure so
// the Lua layer can surface it. macOS and Linux use the desktop's own tools
// (open/xdg-open, gio, zenity/kdialog, D-Bus) when they are installed.
// -----------------------------------------------------------------------------

#include <string>
#include <vector>

namespace gitgud::platform
{

    // Open a file, folder, or URL with the OS default handler.
    bool OpenExternal(const std::string& _Target, std::string& _Error);

    // Open the file manager with `_Path` selected (or the folder itself).
    bool ShowInFolder(const std::string& _Path, std::string& _Error);

    // Start `_CommandLine` detached, with `_WorkingDir` as its cwd ("" = inherit).
    bool Spawn(
        const std::string& _CommandLine, const std::string& _WorkingDir, std::string& _Error);

    // Move a file to the recycle bin (undoable), falling back to nothing.
    bool MoveToTrash(const std::string& _Path);

    // Native "choose a folder" dialog. Returns "" when cancelled.
    std::string PickFolder(const std::string& _Title);

    // Native "choose a file" dialog, showing files matching `_Pattern`
    // ("*.wav"; empty: all) under `_FilterName` ("Recordings"). Returns ""
    // when cancelled.
    std::string PickFile(const std::string& _Title, const std::string& _FilterName, const std::string& _Pattern);

    // Replace the clipboard's text.
    bool SetClipboardText(const std::string& _Text);

    // True when the clipboard holds text (an app may put a picture of it
    // there too, as office apps do).
    bool ClipboardHasText();

    // The picture on the clipboard, encoded (PNG, or BMP from a bitmap);
    // false when there is none. Windows only for now: false elsewhere.
    bool ClipboardImage(std::string& _Bytes);

    // The files copied to the clipboard in a file manager (UTF-8 paths);
    // empty when none. Windows only for now.
    std::vector<std::string> ClipboardFiles();

    // Folder of the running executable (UTF-8), where its resources/ and
    // docs/ are. On macOS, inside an app bundle, the bundle's Resources folder.
    std::string ExecutableDirectory();

    // Per-user settings folder: %APPDATA%\Gitgud on Windows,
    // ~/Library/Application Support/Gitgud on macOS, $XDG_CONFIG_HOME/gitgud
    // (~/.config/gitgud) on Linux (UTF-8; may not exist yet). Everything the app writes for
    // itself goes under here, never next to the exe, which may be read only.
    std::string ConfigDirectory();

    // Per-user folder for large files the app fetches for itself (voice
    // models): %LOCALAPPDATA%\Gitgud on Windows, the settings folder on macOS,
    // $XDG_DATA_HOME/gitgud (~/.local/share/gitgud) on Linux (UTF-8; may not
    // exist yet).
    std::string LocalDataDirectory();

    // Write `_Data` to `_Path` so that a crash or power cut leaves either the
    // old file or the new one, never part of one: a temporary file beside
    // it, flushed, then renamed over it. Its folder is made if needed. False
    // with `_Error` when it can't be written.
    bool WriteFileAtomically(const std::string& _Path, const std::string& _Data, std::string& _Error);

    // ConfigDirectory()/logs, created if needed (the temp folder if it can't
    // be): CEGUI.log and crash dumps.
    std::string LogDirectory();

} // namespace gitgud::platform
