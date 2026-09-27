// -----------------------------------------------------------------------------
// gitgud-patcher.exe: applies a staged update, then restarts GitGud Desktop.
//
// GitGud starts it (from a copy outside the install folder, so it can replace
// its own file) and exits:
//
//     gitgud-patcher.exe --install <dir> --staging <dir> --wait-pid <pid>
//
// It holds the "update in progress" lock, waits for that process, asks the
// user to close any other copy of GitGud running from the install folder,
// then applies the staged files (update/UpdateCore.h: journaled, rolled back
// on failure). When the install folder isn't writable (an all-users install
// under Program Files) it re-runs itself elevated with --elevated for the
// file work only, so GitGud is never restarted as administrator. It writes
// <updates>\report.txt for the app ("ok <version>" or "failed <message>")
// and restarts gitgud.exe.
//
// GITGUD_PATCHER_NO_UI=1 (tests): no message boxes; other copies are waited
// on for 30 seconds, then the update is cancelled.
// -----------------------------------------------------------------------------

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shellapi.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "update/UpdateCore.h"
#include "update/UpdateKey.h"

namespace
{

    namespace fs = std::filesystem;
    namespace update = gitgud::update;

    constexpr const wchar_t* kTitle = L"GitGud Desktop update";
    constexpr const wchar_t* kUninstallKey =
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
        L"{3DCDC712-0C9D-42CA-A13C-CA9E93DF07B1}_is1";

    struct Options
    {
        fs::path m_InstallDir;
        fs::path m_StagingDir;
        DWORD m_dwWaitPid = 0;
        bool m_bElevated = false;
    };

    bool NoUi()
    {
        const char* szvalue = std::getenv("GITGUD_PATCHER_NO_UI");
        return szvalue && szvalue[0] == '1';
    }

    std::wstring Widen(const std::string& _Utf8)
    {
        return fs::u8path(_Utf8).wstring();
    }

    void Message(const std::wstring& _Text, UINT _uIcon)
    {
        if (!NoUi())
        {
            MessageBoxW(nullptr, _Text.c_str(), kTitle, MB_OK | _uIcon | MB_SETFOREGROUND);
        }
    }

    bool ParseArgs(Options& _Options)
    {
        int iargc = 0;
        LPWSTR* ppargv = CommandLineToArgvW(GetCommandLineW(), &iargc);
        if (!ppargv)
        {
            return false;
        }
        for (int i = 1; i < iargc; ++i)
        {
            const std::wstring arg = ppargv[i];
            const bool bhasValue = i + 1 < iargc;
            if (arg == L"--install" && bhasValue)
            {
                _Options.m_InstallDir = ppargv[++i];
            }
            else if (arg == L"--staging" && bhasValue)
            {
                _Options.m_StagingDir = ppargv[++i];
            }
            else if (arg == L"--wait-pid" && bhasValue)
            {
                _Options.m_dwWaitPid = static_cast<DWORD>(std::wcstoul(ppargv[++i], nullptr, 10));
            }
            else if (arg == L"--elevated")
            {
                _Options.m_bElevated = true;
            }
        }
        LocalFree(ppargv);
        return !_Options.m_InstallDir.empty() && !_Options.m_StagingDir.empty();
    }

    bool CanWrite(const fs::path& _Dir)
    {
        const fs::path probe = _Dir / L".gitgud-write-test";
        HANDLE hfile = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
            FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
        if (hfile == INVALID_HANDLE_VALUE)
        {
            return false;
        }
        CloseHandle(hfile);
        return true;
    }

    std::string PublicKey()
    {
        // The test override is honoured unelevated only (an elevated run
        // doesn't inherit the environment anyway).
        const char* szoverride = std::getenv("GITGUD_UPDATE_PUBLIC_KEY");
        return szoverride && *szoverride ? szoverride : gitgud::update::kUpdatePublicKey;
    }

    // Show the version installed from this folder in Add/Remove Programs.
    void UpdateUninstallEntry(const fs::path& _InstallDir, const std::string& _Version)
    {
        std::wstring install = _InstallDir.wstring();
        while (!install.empty() && (install.back() == L'\\' || install.back() == L'/'))
        {
            install.pop_back();
        }
        for (HKEY hroot : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER})
        {
            HKEY hkey = nullptr;
            if (RegOpenKeyExW(hroot, kUninstallKey, 0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, &hkey) != ERROR_SUCCESS)
            {
                continue;
            }
            wchar_t wszlocation[MAX_PATH * 2] = {};
            DWORD dwsize = sizeof(wszlocation) - sizeof(wchar_t);
            DWORD dwtype = 0;
            if (RegQueryValueExW(hkey, L"InstallLocation", nullptr, &dwtype,
                    reinterpret_cast<LPBYTE>(wszlocation), &dwsize) == ERROR_SUCCESS &&
                dwtype == REG_SZ)
            {
                std::wstring location = wszlocation;
                while (!location.empty() && (location.back() == L'\\' || location.back() == L'/'))
                {
                    location.pop_back();
                }
                if (CompareStringOrdinal(location.c_str(), -1, install.c_str(), -1, TRUE) ==
                    CSTR_EQUAL)
                {
                    const std::wstring version = Widen(_Version);
                    RegSetValueExW(hkey, L"DisplayVersion", 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(version.c_str()),
                        static_cast<DWORD>((version.size() + 1) * sizeof(wchar_t)));
                }
            }
            RegCloseKey(hkey);
        }
    }

    // Verify and apply the staged update. `_EditedDir` gets the folder holding
    // copies of files the user had edited (empty when there were none).
    bool ApplyStaged(
        const Options& _Options, std::string& _Version, fs::path& _EditedDir, std::string& _Error)
    {
        const fs::path journal = _Options.m_StagingDir / "journal.txt";
        const fs::path backup = _Options.m_StagingDir / "backup";
        if (!update::RecoverJournal(journal, backup, _Error))
        {
            _Error = "an earlier update couldn't be undone: " + _Error;
            return false;
        }

        update::Manifest manifest;
        if (!update::ReadManifestFile(
                _Options.m_StagingDir / "update-manifest.txt", manifest, _Error) ||
            !update::VerifySignature(manifest, PublicKey(), _Error))
        {
            _Error = "the downloaded update can't be trusted: " + _Error;
            return false;
        }
        _Version = manifest.m_Version;

        update::Manifest installed;
        std::string ignored;
        const bool bhaveOld = update::ReadManifestFile(
            _Options.m_InstallDir / "package-manifest.txt", installed, ignored);

        update::PatchPlan plan;
        plan.m_InstallDir = _Options.m_InstallDir;
        plan.m_FilesDir = _Options.m_StagingDir / "files";
        plan.m_BackupDir = backup;
        plan.m_JournalPath = journal;
        plan.m_ReplacedDir =
            _Options.m_StagingDir.parent_path() / "edited" / fs::u8path(manifest.m_Version);
        if (!update::BuildPlan(manifest, bhaveOld ? &installed : nullptr, plan, _Error) ||
            !update::ApplyPlan(plan, _Error))
        {
            return false;
        }
        if (!plan.m_UserEdited.empty())
        {
            _EditedDir = plan.m_ReplacedDir;
        }
        UpdateUninstallEntry(_Options.m_InstallDir, manifest.m_Version);
        return true;
    }

    // --elevated: do the file work only; the unelevated patcher reads the result.
    int RunElevated(const Options& _Options)
    {
        std::string version;
        fs::path edited;
        std::string error;
        const bool bok = ApplyStaged(_Options, version, edited, error);
        std::ofstream out(
            _Options.m_StagingDir / "elevated-result.txt", std::ios::binary | std::ios::trunc);
        out << (bok ? "ok " + version : "failed " + error) << "\n";
        if (!edited.empty())
        {
            out << "edited " << edited.u8string() << "\n";
        }
        return bok ? 0 : 1;
    }

    // Run the elevated half and collect its result. False with `_bDeclined`
    // when the user said no to the UAC prompt.
    bool ApplyElevated(const Options& _Options, std::string& _Result, bool& _bDeclined)
    {
        _bDeclined = false;
        wchar_t wszself[MAX_PATH * 2] = {};
        GetModuleFileNameW(nullptr, wszself, MAX_PATH * 2);
        const std::wstring parameters = L"--elevated --install \"" +
                                        _Options.m_InstallDir.wstring() + L"\" --staging \"" +
                                        _Options.m_StagingDir.wstring() + L"\"";
        SHELLEXECUTEINFOW info = {};
        info.cbSize = sizeof(info);
        info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        info.lpVerb = L"runas";
        info.lpFile = wszself;
        info.lpParameters = parameters.c_str();
        info.nShow = SW_HIDE;
        if (!ShellExecuteExW(&info) || !info.hProcess)
        {
            _bDeclined = GetLastError() == ERROR_CANCELLED;
            return false;
        }
        WaitForSingleObject(info.hProcess, INFINITE);
        CloseHandle(info.hProcess);

        std::ifstream in(_Options.m_StagingDir / "elevated-result.txt", std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        _Result = ss.str();
        return _Result.rfind("ok ", 0) == 0;
    }

    void WaitForProcess(DWORD _dwPid)
    {
        if (_dwPid == 0)
        {
            return;
        }
        HANDLE hprocess = OpenProcess(SYNCHRONIZE, FALSE, _dwPid);
        if (hprocess)
        {
            WaitForSingleObject(hprocess, 60000);
            CloseHandle(hprocess);
        }
    }

    // Every copy of gitgud.exe from the install folder must be closed.
    // False when the user cancels.
    bool WaitForOtherCopies(const fs::path& _Exe)
    {
        const DWORD dwstart = GetTickCount();
        for (;;)
        {
            const std::size_t ncount = update::RunningCopies(_Exe, GetCurrentProcessId()).size();
            if (ncount == 0)
            {
                return true;
            }
            if (NoUi())
            {
                if (GetTickCount() - dwstart > 30000)
                {
                    return false;
                }
                Sleep(500);
                continue;
            }
            const std::wstring text =
                L"Close all GitGud Desktop windows to install the update.\n\n" +
                std::to_wstring(ncount) +
                (ncount == 1 ? L" copy is still open." : L" copies are still open.") +
                L"\n\nRetry once they're closed, or Cancel to install the update later.";
            if (MessageBoxW(nullptr, text.c_str(), kTitle,
                    MB_RETRYCANCEL | MB_ICONINFORMATION | MB_SETFOREGROUND) != IDRETRY)
            {
                return false;
            }
        }
    }

    void WriteReport(const fs::path& _UpdatesDir, const std::string& _Report)
    {
        std::ofstream out(_UpdatesDir / "report.txt", std::ios::binary | std::ios::trunc);
        out << _Report;
    }

    void StartApp(const fs::path& _InstallDir)
    {
        const fs::path exe = _InstallDir / L"gitgud.exe";
        std::wstring command = L"\"" + exe.wstring() + L"\"";
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        if (CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, 0, nullptr,
                _InstallDir.c_str(), &startup, &process))
        {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
    }

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    Options options;
    if (!ParseArgs(options))
    {
        Message(L"This program is run by GitGud Desktop to install updates.", MB_ICONINFORMATION);
        return 2;
    }
    if (options.m_bElevated)
    {
        return RunElevated(options);
    }

    const fs::path updatesDir = options.m_StagingDir.parent_path();
    HANDLE hlock = CreateMutexW(nullptr, TRUE, gitgud::update::kUpdateLockName);
    WaitForProcess(options.m_dwWaitPid);

    std::error_code ec;
    if (!WaitForOtherCopies(options.m_InstallDir / L"gitgud.exe"))
    {
        // Keep the staged update: it's installed at the next start with no
        // other copy open.
        if (hlock)
        {
            ReleaseMutex(hlock);
            CloseHandle(hlock);
        }
        StartApp(options.m_InstallDir);
        return 3;
    }

    std::string report;
    if (CanWrite(options.m_InstallDir))
    {
        std::string version;
        fs::path edited;
        std::string error;
        if (ApplyStaged(options, version, edited, error))
        {
            report = "ok " + version + "\n" +
                     (edited.empty() ? "" : "edited " + edited.u8string() + "\n");
        }
        else
        {
            report = "failed " + error + "\n";
        }
    }
    else
    {
        std::string result;
        bool bdeclined = false;
        if (ApplyElevated(options, result, bdeclined))
        {
            report = result;
        }
        else if (bdeclined)
        {
            report = "failed Installing the update needs administrator permission, which was "
                     "declined.\n";
        }
        else
        {
            report = result.empty() ? "failed The updater couldn't get administrator permission.\n"
                                    : result;
        }
    }

    // Success or failure, the staged copy is spent: a failed update is
    // downloaded again rather than retried at every start.
    fs::remove_all(options.m_StagingDir, ec);
    // The restarted app shows the result (views/updates.lua).
    WriteReport(updatesDir, report);

    if (hlock)
    {
        ReleaseMutex(hlock);
        CloseHandle(hlock);
    }
    StartApp(options.m_InstallDir);
    return report.rfind("ok ", 0) == 0 ? 0 : 1;
}
