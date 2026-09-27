#include "update/UpdateCore.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#include <tlhelp32.h>
#endif

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>

namespace gitgud::update
{

    namespace fs = std::filesystem;

    namespace
    {

        constexpr const char* kKindUpdate = "gitgud-update";
        constexpr const char* kKindPackage = "gitgud-package";

        bool IsHex64(const std::string& _Text)
        {
            return _Text.size() == 64 &&
                   _Text.find_first_not_of("0123456789abcdef") == std::string::npos;
        }

        bool ParseU64(const std::string& _Text, std::uint64_t& _Out)
        {
            if (_Text.empty() || _Text.size() > 19 ||
                _Text.find_first_not_of("0123456789") != std::string::npos)
            {
                return false;
            }
            _Out = std::stoull(_Text);
            return true;
        }

        // Split off the first `_nCount` space-separated words; the rest of the
        // line (which may contain spaces, e.g. a path) goes in `_Rest`.
        bool SplitWords(const std::string& _Line, std::size_t _nCount,
            std::vector<std::string>& _Words, std::string& _Rest)
        {
            _Words.clear();
            std::size_t npos = 0;
            for (std::size_t i = 0; i < _nCount; ++i)
            {
                const std::size_t nspace = _Line.find(' ', npos);
                if (nspace == std::string::npos)
                {
                    return false;
                }
                _Words.push_back(_Line.substr(npos, nspace - npos));
                npos = nspace + 1;
            }
            _Rest = _Line.substr(npos);
            return true;
        }

        std::vector<int> VersionParts(const std::string& _Version)
        {
            std::vector<int> parts;
            std::stringstream ss(_Version);
            std::string part;
            while (std::getline(ss, part, '.'))
            {
                if (part.empty() || part.size() > 9 ||
                    part.find_first_not_of("0123456789") != std::string::npos)
                {
                    return {0, 0, 0};
                }
                parts.push_back(std::stoi(part));
            }
            if (parts.empty())
            {
                return {0, 0, 0};
            }
            return parts;
        }

        std::string ToLowerAscii(std::string _Text)
        {
            std::transform(_Text.begin(), _Text.end(), _Text.begin(),
                [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
            return _Text;
        }

        fs::path Join(const fs::path& _Root, const std::string& _Relative)
        {
            return _Root / fs::u8path(_Relative);
        }

#if defined(_WIN32)

        // Append a line to the journal and flush it to disk before returning,
        // so a crash never leaves an action done but unrecorded.
        bool JournalAppend(const fs::path& _Path, const std::string& _Line)
        {
            HANDLE hfile = CreateFileW(_Path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (hfile == INVALID_HANDLE_VALUE)
            {
                return false;
            }
            const std::string text = _Line + "\n";
            DWORD dwwritten = 0;
            const bool bok = WriteFile(hfile, text.data(), static_cast<DWORD>(text.size()),
                                 &dwwritten, nullptr) &&
                             dwwritten == text.size() && FlushFileBuffers(hfile);
            CloseHandle(hfile);
            return bok;
        }

        bool MovePath(const fs::path& _From, const fs::path& _To)
        {
            std::error_code ec;
            fs::create_directories(_To.parent_path(), ec);
            return MoveFileExW(_From.c_str(), _To.c_str(),
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED |
                           MOVEFILE_WRITE_THROUGH) != 0;
        }

        std::string LastErrorText()
        {
            const DWORD dwerror = GetLastError();
            if (dwerror == ERROR_SHARING_VIOLATION || dwerror == ERROR_ACCESS_DENIED)
            {
                return "a file is in use or not writable (error " + std::to_string(dwerror) + ")";
            }
            return "error " + std::to_string(dwerror);
        }

#else

        bool JournalAppend(const fs::path& _Path, const std::string& _Line)
        {
            std::ofstream out(_Path, std::ios::binary | std::ios::app);
            out << _Line << "\n";
            out.flush();
            return static_cast<bool>(out);
        }

        bool MovePath(const fs::path& _From, const fs::path& _To)
        {
            std::error_code ec;
            fs::create_directories(_To.parent_path(), ec);
            fs::rename(_From, _To, ec);
            return !ec;
        }

        std::string LastErrorText()
        {
            return "a file operation failed";
        }

#endif

        // Undo the journal's recorded steps, newest first. Best effort: keeps
        // going past individual failures and reports the first.
        bool RollBack(const std::vector<std::string>& _Lines, const fs::path& _InstallDir,
            const fs::path& _BackupDir, std::string& _Error)
        {
            bool bok = true;
            std::error_code ec;
            for (auto it = _Lines.rbegin(); it != _Lines.rend(); ++it)
            {
                const std::string& line = *it;
                if (line.rfind("placed ", 0) == 0)
                {
                    const fs::path target = Join(_InstallDir, line.substr(7));
                    fs::remove(target, ec);
                    fs::path pending = target;
                    pending += ".gg-new";
                    fs::remove(pending, ec);
                }
                else if (line.rfind("moved ", 0) == 0)
                {
                    const std::string relative = line.substr(6);
                    const fs::path backup = Join(_BackupDir, relative);
                    if (fs::exists(backup, ec) && !MovePath(backup, Join(_InstallDir, relative)))
                    {
                        if (bok)
                        {
                            _Error = "could not restore " + relative + ": " + LastErrorText();
                        }
                        bok = false;
                    }
                }
            }
            return bok;
        }

    } // namespace

    // ---- Manifests ---------------------------------------------------------------

    bool ParseManifest(const std::string& _Text, Manifest& _Out, std::string& _Error)
    {
        _Out = Manifest{};
        std::size_t nstart = 0;
        std::set<std::string> seen;
        bool bfirst = true;
        while (nstart < _Text.size())
        {
            std::size_t nend = _Text.find('\n', nstart);
            if (nend == std::string::npos)
            {
                nend = _Text.size();
            }
            std::string line = _Text.substr(nstart, nend - nstart);
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }

            if (line.rfind("signature ", 0) == 0)
            {
                _Out.m_SignedText = _Text.substr(0, nstart);
                _Out.m_Signature = line.substr(10);
                break;
            }
            nstart = nend + 1;
            if (line.empty())
            {
                continue;
            }

            if (bfirst)
            {
                bfirst = false;
                const std::size_t nspace = line.find(' ');
                const std::string kind = line.substr(0, nspace);
                const std::string format =
                    nspace == std::string::npos ? "" : line.substr(nspace + 1);
                if ((kind != kKindUpdate && kind != kKindPackage) || format != "1")
                {
                    _Error = "not a GitGud update manifest (or a newer format)";
                    return false;
                }
                _Out.m_Kind = kind;
                continue;
            }

            const std::size_t nspace = line.find(' ');
            const std::string key = line.substr(0, nspace);
            const std::string value = nspace == std::string::npos ? "" : line.substr(nspace + 1);
            if (key == "version")
            {
                _Out.m_Version = value;
            }
            else if (key == "published")
            {
                _Out.m_Published = value;
            }
            else if (key == "notes")
            {
                _Out.m_Notes = value;
            }
            else if (key == "pack")
            {
                std::vector<std::string> words;
                std::string rest;
                // pack <url> <size> <sha256>: the URL has no spaces.
                if (!SplitWords(value, 2, words, rest) || !ParseU64(words[1], _Out.m_uPackSize) ||
                    !IsHex64(rest))
                {
                    _Error = "bad pack line";
                    return false;
                }
                _Out.m_PackUrl = words[0];
                _Out.m_PackSha256 = rest;
            }
            else if (key == "file")
            {
                std::vector<std::string> words;
                std::string path;
                ManifestFile file;
                if (!SplitWords(value, 4, words, path) || !IsHex64(words[0]) ||
                    !ParseU64(words[1], file.m_uSize) || !ParseU64(words[2], file.m_uOffset) ||
                    !ParseU64(words[3], file.m_uPacked))
                {
                    _Error = "bad file line: " + line;
                    return false;
                }
                if (!IsSafeRelativePath(path))
                {
                    _Error = "unsafe path in manifest: " + path;
                    return false;
                }
                if (!seen.insert(ToLowerAscii(path)).second)
                {
                    _Error = "path listed twice: " + path;
                    return false;
                }
                file.m_Sha256 = words[0];
                file.m_Path = path;
                _Out.m_Files.push_back(std::move(file));
            }
            // Unknown keys are ignored so the format can grow.
        }

        if (_Out.m_Kind.empty())
        {
            _Error = "empty manifest";
            return false;
        }
        if (CompareVersions(_Out.m_Version, "0.0.0") <= 0)
        {
            _Error = "the manifest has no valid version";
            return false;
        }
        if (_Out.m_Files.empty())
        {
            _Error = "the manifest lists no files";
            return false;
        }
        if (_Out.m_Kind == kKindUpdate)
        {
            if (_Out.m_PackUrl.empty())
            {
                _Error = "the manifest has no pack";
                return false;
            }
            for (const ManifestFile& file : _Out.m_Files)
            {
                if (file.m_uOffset + file.m_uPacked > _Out.m_uPackSize ||
                    file.m_uOffset + file.m_uPacked < file.m_uOffset)
                {
                    _Error = "file outside the pack: " + file.m_Path;
                    return false;
                }
            }
        }
        return true;
    }

    bool ReadManifestFile(const fs::path& _Path, Manifest& _Out, std::string& _Error)
    {
        std::ifstream in(_Path, std::ios::binary);
        if (!in)
        {
            _Error = "could not read " + _Path.u8string();
            return false;
        }
        std::ostringstream ss;
        ss << in.rdbuf();
        return ParseManifest(ss.str(), _Out, _Error);
    }

    int CompareVersions(const std::string& _A, const std::string& _B)
    {
        std::vector<int> a = VersionParts(_A);
        std::vector<int> b = VersionParts(_B);
        const std::size_t n = std::max(a.size(), b.size());
        a.resize(n, 0);
        b.resize(n, 0);
        for (std::size_t i = 0; i < n; ++i)
        {
            if (a[i] != b[i])
            {
                return a[i] < b[i] ? -1 : 1;
            }
        }
        return 0;
    }

    bool IsSafeRelativePath(const std::string& _Path)
    {
        if (_Path.empty() || _Path.size() > 400 || _Path.front() == '/' ||
            _Path.find('\\') != std::string::npos || _Path.find(':') != std::string::npos)
        {
            return false;
        }
        for (const unsigned char uc : _Path)
        {
            if (uc < 0x20)
            {
                return false;
            }
        }
        std::stringstream ss(_Path);
        std::string part;
        while (std::getline(ss, part, '/'))
        {
            if (part.empty() || part == "." || part == "..")
            {
                return false;
            }
        }
        return _Path.back() != '/';
    }

    // ---- Base64 ------------------------------------------------------------------

    bool Base64Decode(const std::string& _Text, std::string& _Out)
    {
        static const std::string kAlphabet =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        _Out.clear();
        unsigned int uacc = 0;
        int ibits = 0;
        std::size_t npad = 0;
        for (const char c : _Text)
        {
            if (c == '=')
            {
                ++npad;
                continue;
            }
            if (c == '\r' || c == '\n' || c == ' ')
            {
                continue;
            }
            const std::size_t nvalue = kAlphabet.find(c);
            if (nvalue == std::string::npos || npad > 0)
            {
                return false;
            }
            uacc = (uacc << 6) | static_cast<unsigned int>(nvalue);
            ibits += 6;
            if (ibits >= 8)
            {
                ibits -= 8;
                _Out.push_back(static_cast<char>((uacc >> ibits) & 0xFF));
            }
        }
        return npad <= 2;
    }

    std::string Base64Encode(const std::string& _Data)
    {
        static const char kAlphabet[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string out;
        unsigned int uacc = 0;
        int ibits = 0;
        for (const unsigned char uc : _Data)
        {
            uacc = (uacc << 8) | uc;
            ibits += 8;
            while (ibits >= 6)
            {
                ibits -= 6;
                out.push_back(kAlphabet[(uacc >> ibits) & 0x3F]);
            }
        }
        if (ibits > 0)
        {
            out.push_back(kAlphabet[(uacc << (6 - ibits)) & 0x3F]);
        }
        while (out.size() % 4 != 0)
        {
            out.push_back('=');
        }
        return out;
    }

    // ---- Hashes and signatures ---------------------------------------------------

#if defined(_WIN32)

    namespace
    {

        // Incremental SHA-256 over BCrypt.
        class Sha256
        {
          public:
            Sha256()
            {
                if (BCryptOpenAlgorithmProvider(&m_hAlg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) ==
                        0 &&
                    BCryptCreateHash(m_hAlg, &m_hHash, nullptr, 0, nullptr, 0, 0) == 0)
                {
                    m_bOk = true;
                }
            }

            Sha256(const Sha256&) = delete;
            Sha256& operator=(const Sha256&) = delete;

            ~Sha256()
            {
                if (m_hHash)
                {
                    BCryptDestroyHash(m_hHash);
                }
                if (m_hAlg)
                {
                    BCryptCloseAlgorithmProvider(m_hAlg, 0);
                }
            }

            void Add(const char* _pData, std::size_t _nSize)
            {
                while (m_bOk && _nSize > 0)
                {
                    const ULONG ulchunk =
                        static_cast<ULONG>(std::min<std::size_t>(_nSize, 1u << 30));
                    m_bOk =
                        BCryptHashData(m_hHash, reinterpret_cast<PUCHAR>(const_cast<char*>(_pData)),
                            ulchunk, 0) == 0;
                    _pData += ulchunk;
                    _nSize -= ulchunk;
                }
            }

            // Raw 32-byte digest, or "" on failure.
            std::string Finish()
            {
                unsigned char aDigest[32] = {};
                if (!m_bOk || BCryptFinishHash(m_hHash, aDigest, sizeof(aDigest), 0) != 0)
                {
                    return {};
                }
                return std::string(reinterpret_cast<const char*>(aDigest), sizeof(aDigest));
            }

          private:
            BCRYPT_ALG_HANDLE m_hAlg = nullptr;
            BCRYPT_HASH_HANDLE m_hHash = nullptr;
            bool m_bOk = false;
        };

        std::string ToHex(const std::string& _Raw)
        {
            static const char kDigits[] = "0123456789abcdef";
            std::string out;
            for (const unsigned char uc : _Raw)
            {
                out.push_back(kDigits[uc >> 4]);
                out.push_back(kDigits[uc & 0x0F]);
            }
            return out;
        }

    } // namespace

    std::string Sha256Hex(const std::string& _Data)
    {
        Sha256 hash;
        hash.Add(_Data.data(), _Data.size());
        return ToHex(hash.Finish());
    }

    std::string Sha256File(const fs::path& _Path)
    {
        std::ifstream in(_Path, std::ios::binary);
        if (!in)
        {
            return {};
        }
        Sha256 hash;
        std::vector<char> buffer(1u << 16);
        while (in)
        {
            in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
            hash.Add(buffer.data(), static_cast<std::size_t>(in.gcount()));
        }
        return ToHex(hash.Finish());
    }

    bool VerifySignature(
        const Manifest& _Manifest, const std::string& _PublicKeyBase64, std::string& _Error)
    {
        if (_Manifest.m_Signature.empty())
        {
            _Error = "the update isn't signed";
            return false;
        }
        std::string key;
        std::string signature;
        if (!Base64Decode(_PublicKeyBase64, key) || key.size() != 64)
        {
            _Error = "this build has no valid update key";
            return false;
        }
        if (!Base64Decode(_Manifest.m_Signature, signature) || signature.size() != 64)
        {
            _Error = "the update's signature is malformed";
            return false;
        }

        Sha256 hash;
        hash.Add(_Manifest.m_SignedText.data(), _Manifest.m_SignedText.size());
        std::string digest = hash.Finish();
        if (digest.empty())
        {
            _Error = "hashing failed";
            return false;
        }

        std::string blob(sizeof(BCRYPT_ECCKEY_BLOB), '\0');
        BCRYPT_ECCKEY_BLOB header = {};
        header.dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
        header.cbKey = 32;
        std::memcpy(blob.data(), &header, sizeof(header));
        blob += key;

        BCRYPT_ALG_HANDLE halg = nullptr;
        BCRYPT_KEY_HANDLE hkey = nullptr;
        bool bvalid = false;
        if (BCryptOpenAlgorithmProvider(&halg, BCRYPT_ECDSA_P256_ALGORITHM, nullptr, 0) == 0)
        {
            if (BCryptImportKeyPair(halg, nullptr, BCRYPT_ECCPUBLIC_BLOB, &hkey,
                    reinterpret_cast<PUCHAR>(blob.data()), static_cast<ULONG>(blob.size()), 0) == 0)
            {
                bvalid =
                    BCryptVerifySignature(hkey, nullptr, reinterpret_cast<PUCHAR>(digest.data()),
                        static_cast<ULONG>(digest.size()),
                        reinterpret_cast<PUCHAR>(signature.data()),
                        static_cast<ULONG>(signature.size()), 0) == 0;
                BCryptDestroyKey(hkey);
            }
            BCryptCloseAlgorithmProvider(halg, 0);
        }
        if (!bvalid)
        {
            _Error = "the update's signature doesn't match (it may have been tampered with)";
        }
        return bvalid;
    }

    std::vector<unsigned long> RunningCopies(const fs::path& _ExePath, unsigned long _uExcludePid)
    {
        std::vector<unsigned long> pids;
        std::error_code ec;
        const std::wstring target = fs::absolute(_ExePath, ec).wstring();
        HANDLE hsnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (hsnapshot == INVALID_HANDLE_VALUE)
        {
            return pids;
        }
        PROCESSENTRY32W entry = {};
        entry.dwSize = sizeof(entry);
        const std::wstring exeName = _ExePath.filename().wstring();
        for (BOOL bmore = Process32FirstW(hsnapshot, &entry); bmore;
            bmore = Process32NextW(hsnapshot, &entry))
        {
            if (entry.th32ProcessID == _uExcludePid ||
                CompareStringOrdinal(entry.szExeFile, -1, exeName.c_str(), -1, TRUE) != CSTR_EQUAL)
            {
                continue;
            }
            HANDLE hprocess =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
            if (!hprocess)
            {
                continue;
            }
            wchar_t wszpath[MAX_PATH * 2] = {};
            DWORD dwlen = static_cast<DWORD>(std::size(wszpath));
            if (QueryFullProcessImageNameW(hprocess, 0, wszpath, &dwlen) &&
                CompareStringOrdinal(wszpath, static_cast<int>(dwlen), target.c_str(),
                    static_cast<int>(target.size()), TRUE) == CSTR_EQUAL)
            {
                pids.push_back(entry.th32ProcessID);
            }
            CloseHandle(hprocess);
        }
        CloseHandle(hsnapshot);
        return pids;
    }

#else

    std::string Sha256Hex(const std::string&)
    {
        return {};
    }

    std::string Sha256File(const fs::path&)
    {
        return {};
    }

    bool VerifySignature(const Manifest&, const std::string&, std::string& _Error)
    {
        _Error = "updates are not implemented on this platform";
        return false;
    }

    std::vector<unsigned long> RunningCopies(const fs::path&, unsigned long)
    {
        return {};
    }

#endif

    // ---- Plans and applying them -------------------------------------------------

    std::vector<ManifestFile> ChangedFiles(const Manifest& _New, const fs::path& _InstallDir)
    {
        std::vector<ManifestFile> changed;
        for (const ManifestFile& file : _New.m_Files)
        {
            if (Sha256File(Join(_InstallDir, file.m_Path)) != file.m_Sha256)
            {
                changed.push_back(file);
            }
        }
        return changed;
    }

    bool BuildPlan(
        const Manifest& _New, const Manifest* _Old, PatchPlan& _Plan, std::string& _Error)
    {
        _Plan.m_Version = _New.m_Version;
        _Plan.m_Replace.clear();
        _Plan.m_Remove.clear();
        _Plan.m_UserEdited.clear();

        std::map<std::string, std::string> oldHashes; // lowercased path -> hash
        if (_Old)
        {
            for (const ManifestFile& file : _Old->m_Files)
            {
                oldHashes[ToLowerAscii(file.m_Path)] = file.m_Sha256;
            }
        }
        auto userEdited = [&](const std::string& _Path, const std::string& _InstalledHash)
        {
            const auto it = oldHashes.find(ToLowerAscii(_Path));
            return it != oldHashes.end() && !_InstalledHash.empty() && _InstalledHash != it->second;
        };

        std::set<std::string> newPaths;
        for (const ManifestFile& file : _New.m_Files)
        {
            newPaths.insert(ToLowerAscii(file.m_Path));
            const std::string installed = Sha256File(Join(_Plan.m_InstallDir, file.m_Path));
            if (installed == file.m_Sha256)
            {
                continue;
            }
            if (Sha256File(Join(_Plan.m_FilesDir, file.m_Path)) != file.m_Sha256)
            {
                _Error =
                    "the downloaded update is incomplete (" + file.m_Path + "); download it again";
                return false;
            }
            _Plan.m_Replace.push_back(file.m_Path);
            if (userEdited(file.m_Path, installed))
            {
                _Plan.m_UserEdited.push_back(file.m_Path);
            }
        }

        if (_Old)
        {
            std::error_code ec;
            for (const ManifestFile& file : _Old->m_Files)
            {
                if (newPaths.count(ToLowerAscii(file.m_Path)) ||
                    !fs::exists(Join(_Plan.m_InstallDir, file.m_Path), ec))
                {
                    continue;
                }
                _Plan.m_Remove.push_back(file.m_Path);
                if (userEdited(file.m_Path, Sha256File(Join(_Plan.m_InstallDir, file.m_Path))))
                {
                    _Plan.m_UserEdited.push_back(file.m_Path);
                }
            }
        }
        return true;
    }

    bool ApplyPlan(const PatchPlan& _Plan, std::string& _Error)
    {
        std::error_code ec;
        fs::remove(_Plan.m_JournalPath, ec);
        fs::remove_all(_Plan.m_BackupDir, ec);
        fs::create_directories(_Plan.m_BackupDir, ec);
        if (!JournalAppend(_Plan.m_JournalPath, "update " + _Plan.m_Version) ||
            !JournalAppend(_Plan.m_JournalPath, "install " + _Plan.m_InstallDir.u8string()))
        {
            _Error = "could not write the update journal";
            return false;
        }

        // Keep copies of files the user edited before anything moves.
        for (const std::string& relative : _Plan.m_UserEdited)
        {
            const fs::path target = Join(_Plan.m_ReplacedDir, relative);
            fs::create_directories(target.parent_path(), ec);
            fs::copy_file(Join(_Plan.m_InstallDir, relative), target,
                fs::copy_options::overwrite_existing, ec);
        }

        std::vector<std::string> lines;
        auto record = [&](const std::string& _Line)
        {
            lines.push_back(_Line);
            return JournalAppend(_Plan.m_JournalPath, _Line);
        };
        auto fail = [&](const std::string& _Why)
        {
            _Error = _Why;
            std::string rollbackError;
            if (!RollBack(lines, _Plan.m_InstallDir, _Plan.m_BackupDir, rollbackError))
            {
                _Error += "; restoring the previous version also failed: " + rollbackError;
            }
            else
            {
                JournalAppend(_Plan.m_JournalPath, "rolledback");
                fs::remove(_Plan.m_JournalPath, ec);
            }
            return false;
        };

        for (const std::string& relative : _Plan.m_Replace)
        {
            const fs::path target = Join(_Plan.m_InstallDir, relative);
            fs::path pending = target;
            pending += ".gg-new";
            fs::create_directories(target.parent_path(), ec);
            if (!fs::copy_file(Join(_Plan.m_FilesDir, relative), pending,
                    fs::copy_options::overwrite_existing, ec))
            {
                fs::remove(pending, ec);
                return fail("could not write " + relative + ": " + ec.message());
            }
            if (fs::exists(target, ec))
            {
                if (!record("moved " + relative))
                {
                    return fail("could not write the update journal");
                }
                if (!MovePath(target, Join(_Plan.m_BackupDir, relative)))
                {
                    fs::remove(pending, ec);
                    return fail("could not replace " + relative + ": " + LastErrorText());
                }
            }
            if (!record("placed " + relative))
            {
                return fail("could not write the update journal");
            }
            if (!MovePath(pending, target))
            {
                return fail("could not place " + relative + ": " + LastErrorText());
            }
        }

        for (const std::string& relative : _Plan.m_Remove)
        {
            if (!record("moved " + relative))
            {
                return fail("could not write the update journal");
            }
            if (!MovePath(Join(_Plan.m_InstallDir, relative), Join(_Plan.m_BackupDir, relative)))
            {
                return fail("could not remove " + relative + ": " + LastErrorText());
            }
        }

        if (!record("done"))
        {
            return fail("could not write the update journal");
        }
        fs::remove_all(_Plan.m_BackupDir, ec);
        fs::remove(_Plan.m_JournalPath, ec);
        return true;
    }

    bool RecoverJournal(
        const fs::path& _JournalPath, const fs::path& _BackupDir, std::string& _Error)
    {
        std::error_code ec;
        std::ifstream in(_JournalPath, std::ios::binary);
        if (!in)
        {
            return true; // no journal: nothing was interrupted
        }
        std::vector<std::string> lines;
        std::string line;
        fs::path installDir;
        bool bfinished = false;
        while (std::getline(in, line))
        {
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }
            if (line.rfind("install ", 0) == 0)
            {
                installDir = fs::u8path(line.substr(8));
            }
            else if (line == "done" || line == "rolledback")
            {
                bfinished = true;
            }
            lines.push_back(line);
        }
        in.close();

        bool bok = true;
        if (!bfinished && !installDir.empty())
        {
            bok = RollBack(lines, installDir, _BackupDir, _Error);
        }
        if (bok)
        {
            fs::remove_all(_BackupDir, ec);
            fs::remove(_JournalPath, ec);
        }
        return bok;
    }

} // namespace gitgud::update
