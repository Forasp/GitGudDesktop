#include "app/Updater.h"

#include "platform/Http.h"
#include "platform/Shell.h"
#include "update/UpdateCore.h"
#include "update/UpdateKey.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <zlib.h>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace gitgud::app::updater
{

    namespace fs = std::filesystem;
    using gitgud::update::Manifest;
    using gitgud::update::ManifestFile;

    namespace
    {

        constexpr const char* kDefaultManifestUrl =
            "https://github.com/Forasp/GitGudDesktop/releases/latest/download/update-manifest.txt";
        constexpr const char* kPackageManifest = "package-manifest.txt";
        constexpr const char* kPatcherExe = "gitgud-patcher.exe";

        // Download ranges closer than this are fetched as one request.
        constexpr std::uint64_t kMergeGap = 256u * 1024u;

        [[noreturn]] void Fail(const std::string& _Message)
        {
            throw std::runtime_error(_Message);
        }

        std::string Env(const char* _szName)
        {
            const char* szvalue = std::getenv(_szName);
            return szvalue ? szvalue : "";
        }

        // Where the manifest comes from: a URL, or (tests) a local folder.
        struct Source
        {
            bool m_bLocal = false;
            std::string m_Url;
            fs::path m_Dir;
        };

        Source GetSource()
        {
            Source source;
            const std::string configured = Env("GITGUD_UPDATE_URL");
            if (configured.empty() || configured.rfind("https://", 0) == 0)
            {
                source.m_Url = configured.empty() ? kDefaultManifestUrl : configured;
            }
            else
            {
                source.m_bLocal = true;
                source.m_Dir = fs::u8path(configured);
            }
            return source;
        }

        std::string ReadFile(const fs::path& _Path)
        {
            std::ifstream in(_Path, std::ios::binary);
            if (!in)
            {
                Fail("could not read " + _Path.u8string());
            }
            std::ostringstream ss;
            ss << in.rdbuf();
            return ss.str();
        }

        void WriteFile(const fs::path& _Path, const std::string& _Data)
        {
            std::error_code ec;
            fs::create_directories(_Path.parent_path(), ec);
            std::ofstream out(_Path, std::ios::binary | std::ios::trunc);
            out.write(_Data.data(), static_cast<std::streamsize>(_Data.size()));
            if (!out)
            {
                Fail("could not write " + _Path.u8string());
            }
        }

        // Fetch, parse, and verify the latest update manifest.
        Manifest LoadManifest(const Source& _Source, std::string& _Text)
        {
            if (_Source.m_bLocal)
            {
                _Text = ReadFile(_Source.m_Dir / "update-manifest.txt");
            }
            else
            {
                std::string error;
                if (!gitgud::platform::HttpGet(_Source.m_Url, _Text, error))
                {
                    Fail("Couldn't reach the update server: " + error);
                }
            }

            Manifest manifest;
            std::string error;
            if (!gitgud::update::ParseManifest(_Text, manifest, error) ||
                manifest.m_Kind != "gitgud-update")
            {
                Fail("The update information is invalid: " +
                     (error.empty() ? std::string("wrong kind of manifest") : error));
            }
            const std::string overrideKey = Env("GITGUD_UPDATE_PUBLIC_KEY");
            const std::string key =
                overrideKey.empty() ? gitgud::update::kUpdatePublicKey : overrideKey;
            if (key.empty())
            {
                Fail("This build can't verify updates (it has no update key).");
            }
            if (!gitgud::update::VerifySignature(manifest, key, error))
            {
                Fail("The update was rejected: " + error + ".");
            }
            return manifest;
        }

        // The pack's URL (or local path for a folder source).
        std::string PackLocation(const Source& _Source, const Manifest& _Manifest)
        {
            const std::string& pack = _Manifest.m_PackUrl;
            if (pack.rfind("https://", 0) == 0)
            {
                return pack;
            }
            if (!gitgud::update::IsSafeRelativePath(pack))
            {
                Fail("The update names an invalid pack.");
            }
            if (_Source.m_bLocal)
            {
                return (_Source.m_Dir / fs::u8path(pack)).u8string();
            }
            return _Source.m_Url.substr(0, _Source.m_Url.rfind('/') + 1) + pack;
        }

        std::string Inflate(const std::string& _Packed, std::uint64_t _uSize)
        {
            std::string out(static_cast<std::size_t>(_uSize), '\0');
            z_stream zs = {};
            if (inflateInit2(&zs, -15) != Z_OK) // raw deflate, as .NET's DeflateStream writes
            {
                Fail("could not start decompression");
            }
            zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(_Packed.data()));
            zs.avail_in = static_cast<uInt>(_Packed.size());
            zs.next_out = reinterpret_cast<Bytef*>(out.data());
            zs.avail_out = static_cast<uInt>(out.size());
            const int iresult = inflate(&zs, Z_FINISH);
            const bool bok = (iresult == Z_STREAM_END || (iresult == Z_BUF_ERROR && _uSize == 0)) &&
                             zs.total_out == _uSize;
            inflateEnd(&zs);
            if (!bok)
            {
                Fail("a downloaded file is damaged");
            }
            return out;
        }

        // A run of changed files close together in the pack.
        struct Group
        {
            std::uint64_t m_uStart = 0;
            std::uint64_t m_uEnd = 0; // exclusive
            std::vector<ManifestFile> m_Files;
        };

        std::vector<Group> GroupRanges(std::vector<ManifestFile> _Files)
        {
            std::sort(_Files.begin(), _Files.end(),
                [](const ManifestFile& _A, const ManifestFile& _B)
                { return _A.m_uOffset < _B.m_uOffset; });
            std::vector<Group> groups;
            for (const ManifestFile& file : _Files)
            {
                const std::uint64_t uend = file.m_uOffset + file.m_uPacked;
                if (groups.empty() || file.m_uOffset > groups.back().m_uEnd + kMergeGap)
                {
                    groups.push_back(Group{file.m_uOffset, uend, {}});
                }
                groups.back().m_uEnd = std::max(groups.back().m_uEnd, uend);
                groups.back().m_Files.push_back(file);
            }
            return groups;
        }

        fs::path StagedDir()
        {
            return UpdatesDir() / "staged";
        }

    } // namespace

    // ---- Queries -------------------------------------------------------------------

    std::string CurrentVersion()
    {
        return GITGUD_VERSION;
    }

    fs::path InstallDir()
    {
        return fs::u8path(gitgud::platform::ExecutableDirectory());
    }

    bool IsPackagedBuild()
    {
        std::error_code ec;
        return fs::exists(InstallDir() / kPackageManifest, ec);
    }

    fs::path UpdatesDir()
    {
        const std::string local = Env("LOCALAPPDATA");
        if (!local.empty())
        {
            return fs::u8path(local) / "Gitgud" / "updates";
        }
        return fs::u8path(gitgud::platform::ConfigDirectory()) / "updates";
    }

    std::string StagedVersion()
    {
        std::ifstream in(StagedDir() / "ready", std::ios::binary);
        std::string version;
        std::getline(in, version);
        if (!version.empty() && version.back() == '\r')
        {
            version.pop_back();
        }
        if (version.empty() || gitgud::update::CompareVersions(version, CurrentVersion()) <= 0)
        {
            return {};
        }
        return version;
    }

    void DiscardStaged()
    {
        std::error_code ec;
        fs::remove_all(StagedDir(), ec);
        fs::remove_all(UpdatesDir() / "staged.partial", ec);
    }

    int OtherCopies()
    {
#if defined(_WIN32)
        return static_cast<int>(
            gitgud::update::RunningCopies(InstallDir() / "gitgud.exe", GetCurrentProcessId())
                .size());
#else
        return 0;
#endif
    }

    bool PatcherRunning()
    {
#if defined(_WIN32)
        HANDLE hlock = OpenMutexW(SYNCHRONIZE, FALSE, gitgud::update::kUpdateLockName);
        if (hlock)
        {
            CloseHandle(hlock);
            return true;
        }
#endif
        return false;
    }

    std::string TakePatcherReport()
    {
        const fs::path path = UpdatesDir() / "report.txt";
        std::ifstream in(path, std::ios::binary);
        if (!in)
        {
            return {};
        }
        std::ostringstream ss;
        ss << in.rdbuf();
        in.close();
        std::error_code ec;
        fs::remove(path, ec);
        return ss.str();
    }

    // ---- Check and download --------------------------------------------------------

    CheckResult Check()
    {
        if (!IsPackagedBuild())
        {
            Fail("This is a developer build; only release builds update themselves.");
        }
        const Source source = GetSource();
        std::string text;
        const Manifest manifest = LoadManifest(source, text);

        CheckResult result;
        result.m_Version = manifest.m_Version;
        result.m_Notes = manifest.m_Notes;
        if (gitgud::update::CompareVersions(manifest.m_Version, CurrentVersion()) <= 0)
        {
            return result;
        }
        result.m_bAvailable = true;
        for (const ManifestFile& file : gitgud::update::ChangedFiles(manifest, InstallDir()))
        {
            result.m_uDownloadBytes += file.m_uPacked;
            ++result.m_nFiles;
        }
        return result;
    }

    std::string Download(const std::function<void(std::uint64_t, std::uint64_t)>& _OnProgress,
        const std::atomic<bool>& _Cancel)
    {
        if (!IsPackagedBuild())
        {
            Fail("This is a developer build; only release builds update themselves.");
        }
        const Source source = GetSource();
        std::string manifestText;
        const Manifest manifest = LoadManifest(source, manifestText);
        if (gitgud::update::CompareVersions(manifest.m_Version, CurrentVersion()) <= 0)
        {
            Fail("GitGud Desktop is already up to date.");
        }
        if (StagedVersion() == manifest.m_Version)
        {
            return manifest.m_Version; // already downloaded
        }

        const std::vector<ManifestFile> changed =
            gitgud::update::ChangedFiles(manifest, InstallDir());
        std::uint64_t utotal = 0;
        for (const ManifestFile& file : changed)
        {
            utotal += file.m_uPacked;
        }

        const fs::path partial = UpdatesDir() / "staged.partial";
        std::error_code ec;
        fs::remove_all(partial, ec);
        fs::create_directories(partial / "files", ec);

        const std::string pack = PackLocation(source, manifest);
        std::uint64_t udone = 0;
        std::string wholePack; // set once the whole pack has been fetched
        auto progress = [&](std::uint64_t _uNow)
        {
            if (_OnProgress)
            {
                _OnProgress(std::min(udone + _uNow, utotal), utotal);
            }
            return !_Cancel.load();
        };
        auto fetch = [&](const std::string& _Header, std::string& _Body, unsigned long& _uStatus)
        {
            std::string error;
            if (!gitgud::platform::HttpGetEx(pack, _Header, _Body, _uStatus, progress, error))
            {
                Fail(error == "cancelled" ? "cancelled" : "The download failed: " + error);
            }
        };
        auto useWholePack = [&](std::string _Body)
        {
            if (_Body.size() != manifest.m_uPackSize ||
                gitgud::update::Sha256Hex(_Body) != manifest.m_PackSha256)
            {
                Fail("The downloaded update doesn't match its signed checksum.");
            }
            wholePack = std::move(_Body);
        };
        auto stageFile = [&](const ManifestFile& _File, const std::string& _Packed)
        {
            const std::string data = Inflate(_Packed, _File.m_uSize);
            if (gitgud::update::Sha256Hex(data) != _File.m_Sha256)
            {
                Fail("A downloaded file doesn't match its signed checksum (" + _File.m_Path + ").");
            }
            WriteFile(partial / "files" / fs::u8path(_File.m_Path), data);
        };

        if (source.m_bLocal)
        {
            // Test source: read each file's bytes straight from the pack.
            std::ifstream in(fs::u8path(pack), std::ios::binary);
            if (!in)
            {
                Fail("could not read " + pack);
            }
            for (const ManifestFile& file : changed)
            {
                std::string packed(static_cast<std::size_t>(file.m_uPacked), '\0');
                in.seekg(static_cast<std::streamoff>(file.m_uOffset));
                in.read(packed.data(), static_cast<std::streamsize>(packed.size()));
                if (static_cast<std::uint64_t>(in.gcount()) != file.m_uPacked)
                {
                    Fail("the pack is truncated");
                }
                stageFile(file, packed);
                udone += file.m_uPacked;
                progress(0);
                if (_Cancel.load())
                {
                    Fail("cancelled");
                }
            }
        }
        else if (utotal * 10 > manifest.m_uPackSize * 6)
        {
            // Most of the pack changed: one request for all of it.
            std::string body;
            unsigned long ustatus = 0;
            fetch("", body, ustatus);
            useWholePack(std::move(body));
        }
        else
        {
            for (const Group& group : GroupRanges(changed))
            {
                std::string body;
                unsigned long ustatus = 0;
                fetch("Range: bytes=" + std::to_string(group.m_uStart) + "-" +
                          std::to_string(group.m_uEnd - 1),
                    body, ustatus);
                if (ustatus != 206)
                {
                    // The server ignored the range and sent everything.
                    useWholePack(std::move(body));
                    break;
                }
                if (body.size() != group.m_uEnd - group.m_uStart)
                {
                    Fail("The download was cut short.");
                }
                for (const ManifestFile& file : group.m_Files)
                {
                    stageFile(
                        file, body.substr(static_cast<std::size_t>(file.m_uOffset - group.m_uStart),
                                  static_cast<std::size_t>(file.m_uPacked)));
                }
                udone += body.size();
            }
        }

        if (!wholePack.empty())
        {
            for (const ManifestFile& file : changed)
            {
                stageFile(file, wholePack.substr(static_cast<std::size_t>(file.m_uOffset),
                                    static_cast<std::size_t>(file.m_uPacked)));
            }
            udone = utotal;
        }
        if (_OnProgress)
        {
            _OnProgress(utotal, utotal);
        }

        WriteFile(partial / "update-manifest.txt", manifestText);
        WriteFile(partial / "ready", manifest.m_Version + "\n");
        fs::remove_all(StagedDir(), ec);
        fs::rename(partial, StagedDir(), ec);
        if (ec)
        {
            Fail("could not store the update: " + ec.message());
        }
        return manifest.m_Version;
    }

    // ---- Hand-off --------------------------------------------------------------------

    bool StartPatcher(std::string& _Error)
    {
#if defined(_WIN32)
        if (StagedVersion().empty())
        {
            _Error = "No update is ready to install.";
            return false;
        }
        // Run a copy from outside the install folder so the patcher can
        // replace its own file. Prefer the new version's patcher.
        std::error_code ec;
        fs::path source = StagedDir() / "files" / kPatcherExe;
        if (!fs::exists(source, ec))
        {
            source = InstallDir() / kPatcherExe;
        }
        const fs::path runDir = UpdatesDir() / "run";
        const fs::path patcher = runDir / kPatcherExe;
        fs::create_directories(runDir, ec);
        if (!fs::copy_file(source, patcher, fs::copy_options::overwrite_existing, ec))
        {
            _Error = "Couldn't prepare the updater: " + ec.message();
            return false;
        }

        std::wstring command = L"\"" + patcher.wstring() + L"\" --install \"" +
                               InstallDir().wstring() + L"\" --staging \"" + StagedDir().wstring() +
                               L"\" --wait-pid " + std::to_wstring(GetCurrentProcessId());
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(patcher.c_str(), command.data(), nullptr, nullptr, FALSE, 0, nullptr,
                runDir.c_str(), &startup, &process))
        {
            _Error = "Couldn't start the updater (error " + std::to_string(GetLastError()) + ").";
            return false;
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return true;
#else
        _Error = "Updates are not implemented on this platform.";
        return false;
#endif
    }

} // namespace gitgud::app::updater
