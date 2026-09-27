#pragma once

// -----------------------------------------------------------------------------
// Updater: checking for, downloading, and handing off updates. The app side
// of update/UpdateCore.h; gitgud-patcher.exe does the file replacement.
//
//   Check()     fetch the latest release's signed update manifest and say
//               what an update would download.
//   Download()  fetch only the files that differ from this install (HTTP
//               Range requests into the release's pack), inflate and verify
//               each, and stage them in <local app data>\Gitgud\updates\staged.
//               Nothing in the install folder changes while the app runs.
//   StartPatcher()  run gitgud-patcher.exe, which waits for every copy of the
//               app to exit, applies the staged files, and restarts GitGud.
//
// Check/Download BLOCK (network): run them on a TaskRunner worker.
//
// Test hooks: GITGUD_UPDATE_URL is the manifest's URL, or a local folder
// holding update-manifest.txt and its pack; GITGUD_UPDATE_PUBLIC_KEY replaces
// the built-in public key (base64 X||Y).
// -----------------------------------------------------------------------------

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>

namespace gitgud::app::updater
{

    // This build's version (CMake's project version).
    std::string CurrentVersion();

    // The folder gitgud.exe runs from.
    std::filesystem::path InstallDir();

    // Packaged builds carry package-manifest.txt; developer builds don't and
    // never update themselves.
    bool IsPackagedBuild();

    // <local app data>\Gitgud\updates (created on demand by the writers).
    std::filesystem::path UpdatesDir();

    struct CheckResult
    {
        bool m_bAvailable = false;
        std::string m_Version;
        std::string m_Notes;                // release-notes URL
        std::uint64_t m_uDownloadBytes = 0; // compressed bytes the update needs
        std::size_t m_nFiles = 0;           // files that would change
    };

    // Throws std::runtime_error with a user-facing message on failure.
    CheckResult Check();

    // Download and stage the latest update. `_OnProgress(done, total)` reports
    // bytes; `_Cancel` stops it (throws "cancelled"). Returns the staged
    // version. Throws std::runtime_error on failure.
    std::string Download(const std::function<void(std::uint64_t, std::uint64_t)>& _OnProgress,
        const std::atomic<bool>& _Cancel);

    // The staged update's version when one is ready and newer than this
    // build, else "".
    std::string StagedVersion();

    // Throw away a staged or half-downloaded update.
    void DiscardStaged();

    // Other running copies of this install's gitgud.exe.
    int OtherCopies();

    // Start gitgud-patcher.exe for the staged update; it waits for this
    // process (and every other copy) to exit. The caller should then quit.
    bool StartPatcher(std::string& _Error);

    // True while gitgud-patcher.exe is replacing files.
    bool PatcherRunning();

    // The patcher's report from the last update ("ok <version>" /
    // "failed <message>", then optional "edited <folder>"), read once: the
    // file is deleted. "" when there's nothing to report.
    std::string TakePatcherReport();

} // namespace gitgud::app::updater
