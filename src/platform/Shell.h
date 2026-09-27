#pragma once

// -----------------------------------------------------------------------------
// Shell — thin wrappers over the OS desktop shell: open files/URLs, reveal a
// file in the file manager, launch an editor or terminal, move files to the
// recycle bin, pick a folder, and put text on the clipboard.
//
// Everything is best effort and returns false (with a message) on failure so
// the Lua layer can surface it. Only Windows is implemented today; other
// platforms return false with "not implemented".
// -----------------------------------------------------------------------------

#include <string>

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

    // Replace the clipboard's text.
    bool SetClipboardText(const std::string& _Text);

    // Per-user settings folder: %APPDATA%\Gitgud on Windows, ~/.gitgud
    // elsewhere (UTF-8; may not exist yet).
    std::string ConfigDirectory();

} // namespace gitgud::platform
