#include "platform/Http.h"

#include "platform/Process.h"
#if defined(_WIN32)
#include "platform/WinSpawn.h"
#endif

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <winhttp.h>
#endif

#include <algorithm>
#include <cstdio>
#include <cwchar>
#include <filesystem>
#include <thread>
#include <vector>

namespace gitgud::platform
{

    namespace fs = std::filesystem;

#if defined(_WIN32)

    namespace
    {

        // Downloads larger than this are refused (the GitHub CLI is ~15 MB).
        constexpr std::size_t kMaxBody = 256u * 1024u * 1024u;

        std::wstring Widen(const std::string& _Utf8)
        {
            if (_Utf8.empty())
            {
                return {};
            }
            const int iwide = MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), nullptr, 0);
            std::wstring out(static_cast<std::size_t>(iwide), L'\0');
            MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), out.data(), iwide);
            return out;
        }

        // Owns a WinHTTP handle.
        struct ScopedInternet
        {
            HINTERNET m_hHandle = nullptr;

            explicit ScopedInternet(HINTERNET _hHandle) : m_hHandle(_hHandle)
            {
            }

            ScopedInternet(const ScopedInternet&) = delete;
            ScopedInternet& operator=(const ScopedInternet&) = delete;

            ~ScopedInternet()
            {
                if (m_hHandle)
                {
                    WinHttpCloseHandle(m_hHandle);
                }
            }
        };

        std::string NetworkError(const char* _szWhat)
        {
            const DWORD dwerror = GetLastError();
            switch (dwerror)
            {
            case ERROR_WINHTTP_NAME_NOT_RESOLVED:
                return "the server name could not be resolved (are you offline?)";
            case ERROR_WINHTTP_TIMEOUT:
                return "the server did not answer in time";
            case ERROR_WINHTTP_CANNOT_CONNECT:
                return "could not connect to the server";
            case ERROR_WINHTTP_SECURE_FAILURE:
                return "the server's certificate was not accepted";
            default:
                return std::string(_szWhat) + " failed (error " + std::to_string(dwerror) + ")";
            }
        }

    } // namespace

    namespace
    {

        // One GET: the body goes to `_OnData` as it arrives (false from it
        // stops, with `_Error` as it set it, or "cancelled").
        bool HttpRequest(const std::string& _Url, const std::string& _Header, unsigned long& _uStatus,
            std::uint64_t& _uLength, const std::function<bool(const char*, std::size_t)>& _OnData,
            std::string& _Error)
        {
            _uStatus = 0;
            _uLength = 0;
            if (_Url.rfind("https://", 0) != 0)
            {
                _Error = "only https:// URLs are allowed";
                return false;
            }

            const std::wstring url = Widen(_Url);
            URL_COMPONENTS parts = {};
            parts.dwStructSize = sizeof(parts);
            parts.dwHostNameLength = static_cast<DWORD>(-1);
            parts.dwUrlPathLength = static_cast<DWORD>(-1);
            parts.dwExtraInfoLength = static_cast<DWORD>(-1);
            if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts))
            {
                _Error = "not a valid URL: " + _Url;
                return false;
            }
            const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
            std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
            path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

            ScopedInternet session(WinHttpOpen(L"GitGud", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
            if (!session.m_hHandle)
            {
                _Error = NetworkError("opening an HTTP session");
                return false;
            }
            WinHttpSetTimeouts(session.m_hHandle, 0, 30000, 30000, 60000);

            ScopedInternet connection(WinHttpConnect(session.m_hHandle, host.c_str(), parts.nPort, 0));
            if (!connection.m_hHandle)
            {
                _Error = NetworkError("connecting");
                return false;
            }

            // Redirects (release downloads hop to a CDN) are followed by
            // default; WinHTTP never follows one from https back to http.
            ScopedInternet request(WinHttpOpenRequest(connection.m_hHandle, L"GET", path.c_str(),
                nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
            if (!request.m_hHandle)
            {
                _Error = NetworkError("creating the request");
                return false;
            }
            const std::wstring header = Widen(_Header);
            if (!WinHttpSendRequest(request.m_hHandle,
                    header.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : header.c_str(),
                    header.empty() ? 0 : static_cast<DWORD>(-1L), WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
                !WinHttpReceiveResponse(request.m_hHandle, nullptr))
            {
                _Error = NetworkError("the request");
                return false;
            }

            DWORD dwstatus = 0;
            DWORD dwsize = sizeof(dwstatus);
            WinHttpQueryHeaders(request.m_hHandle,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                &dwstatus, &dwsize, WINHTTP_NO_HEADER_INDEX);
            _uStatus = dwstatus;
            if (dwstatus < 200 || dwstatus >= 300)
            {
                _Error = "the server answered HTTP " + std::to_string(dwstatus);
                return false;
            }
            wchar_t wszlength[32] = {};
            DWORD dwlength = sizeof(wszlength);
            if (WinHttpQueryHeaders(request.m_hHandle, WINHTTP_QUERY_CONTENT_LENGTH,
                    WINHTTP_HEADER_NAME_BY_INDEX, wszlength, &dwlength, WINHTTP_NO_HEADER_INDEX))
            {
                _uLength = std::wcstoull(wszlength, nullptr, 10);
            }

            std::vector<char> chunk;
            for (;;)
            {
                DWORD dwavailable = 0;
                if (!WinHttpQueryDataAvailable(request.m_hHandle, &dwavailable))
                {
                    _Error = NetworkError("reading the response");
                    return false;
                }
                if (dwavailable == 0)
                {
                    break;
                }
                chunk.resize(dwavailable);
                DWORD dwread = 0;
                if (!WinHttpReadData(request.m_hHandle, chunk.data(), dwavailable, &dwread))
                {
                    _Error = NetworkError("reading the response");
                    return false;
                }
                if (!_OnData(chunk.data(), dwread))
                {
                    if (_Error.empty())
                    {
                        _Error = "cancelled";
                    }
                    return false;
                }
            }
            return true;
        }

    } // namespace

    bool HttpGet(const std::string& _Url, std::string& _Body, std::string& _Error)
    {
        unsigned long ustatus = 0;
        return HttpGetEx(_Url, "", _Body, ustatus, nullptr, _Error);
    }

    bool HttpGetEx(const std::string& _Url, const std::string& _Header, std::string& _Body,
        unsigned long& _uStatus, const std::function<bool(std::uint64_t)>& _OnProgress,
        std::string& _Error)
    {
        _Body.clear();
        std::uint64_t ulength = 0;
        return HttpRequest(_Url, _Header, _uStatus, ulength,
            [&](const char* _pData, std::size_t _nSize)
            {
                if (_Body.size() + _nSize > kMaxBody)
                {
                    _Error = "the download is too large";
                    return false;
                }
                _Body.append(_pData, _nSize);
                return !_OnProgress || _OnProgress(_Body.size());
            },
            _Error);
    }

    bool HttpDownloadFile(const std::string& _Url, const std::string& _Path,
        const std::function<bool(std::uint64_t, std::uint64_t)>& _OnProgress, std::string& _Error)
    {
        const fs::path path = fs::u8path(_Path);
        std::error_code ec;
        fs::create_directories(path.parent_path(), ec);
        std::uint64_t uhave = fs::is_regular_file(path, ec) ? fs::file_size(path, ec) : 0;
        if (ec)
        {
            uhave = 0;
        }
        const std::string range = uhave > 0 ? "Range: bytes=" + std::to_string(uhave) + "-" : std::string();
        unsigned long ustatus = 0;
        std::uint64_t ulength = 0;
        FILE* pfile = nullptr;
        std::uint64_t ugot = 0;
        std::uint64_t utotal = 0;
        bool bstarted = false;
        const bool bok = HttpRequest(_Url, range, ustatus, ulength,
            [&](const char* _pData, std::size_t _nSize)
            {
                if (!bstarted)
                {
                    bstarted = true;
                    // 206: the rest after what's there; 200: the whole file again.
                    const bool bresume = ustatus == 206 && uhave > 0;
                    ugot = bresume ? uhave : 0;
                    utotal = ulength > 0 ? ulength + ugot : 0;
                    pfile = _wfopen(path.c_str(), bresume ? L"ab" : L"wb");
                    if (!pfile)
                    {
                        _Error = "could not write " + _Path;
                        return false;
                    }
                }
                if (std::fwrite(_pData, 1, _nSize, pfile) != _nSize)
                {
                    _Error = "could not write " + _Path + " (is the disk full?)";
                    return false;
                }
                ugot += _nSize;
                return !_OnProgress || _OnProgress(ugot, utotal);
            },
            _Error);
        if (pfile && std::fclose(pfile) != 0 && bok)
        {
            _Error = "could not write " + _Path;
            return false;
        }
        if (!bok && ustatus == 416 && uhave > 0)
        {
            // Bytes past the end were asked for: what's there is the whole
            // file (or more); the caller's checksum decides.
            _Error.clear();
            return true;
        }
        return bok;
    }

    std::string Sha256FileHex(const std::string& _Path, const std::function<bool(std::uint64_t)>& _OnProgress)
    {
        FILE* pfile = _wfopen(fs::u8path(_Path).c_str(), L"rb");
        if (!pfile)
        {
            return {};
        }
        BCRYPT_ALG_HANDLE halg = nullptr;
        if (BCryptOpenAlgorithmProvider(&halg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0)
        {
            std::fclose(pfile);
            return {};
        }
        unsigned char aHash[32] = {};
        BCRYPT_HASH_HANDLE hhash = nullptr;
        bool bok = BCryptCreateHash(halg, &hhash, nullptr, 0, nullptr, 0, 0) == 0;
        if (bok)
        {
            std::vector<unsigned char> buffer(1u << 20);
            std::uint64_t udone = 0;
            for (;;)
            {
                const std::size_t nread = std::fread(buffer.data(), 1, buffer.size(), pfile);
                if (nread == 0)
                {
                    bok = std::ferror(pfile) == 0;
                    break;
                }
                if (BCryptHashData(hhash, buffer.data(), static_cast<ULONG>(nread), 0) != 0)
                {
                    bok = false;
                    break;
                }
                udone += nread;
                if (_OnProgress && !_OnProgress(udone))
                {
                    bok = false;
                    break;
                }
            }
            bok = bok && BCryptFinishHash(hhash, aHash, sizeof(aHash), 0) == 0;
            BCryptDestroyHash(hhash);
        }
        BCryptCloseAlgorithmProvider(halg, 0);
        std::fclose(pfile);
        if (!bok)
        {
            return {};
        }
        static const char kDigits[] = "0123456789abcdef";
        std::string out;
        for (const unsigned char uc : aHash)
        {
            out.push_back(kDigits[uc >> 4]);
            out.push_back(kDigits[uc & 0x0F]);
        }
        return out;
    }

    std::string Sha256Hex(const std::string& _Data)
    {
        BCRYPT_ALG_HANDLE halg = nullptr;
        if (BCryptOpenAlgorithmProvider(&halg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0)
        {
            return {};
        }

        unsigned char aHash[32] = {};
        BCRYPT_HASH_HANDLE hhash = nullptr;
        bool bok = BCryptCreateHash(halg, &hhash, nullptr, 0, nullptr, 0, 0) == 0;
        if (bok)
        {
            // BCryptHashData takes a ULONG length: feed large inputs in pieces.
            std::size_t noffset = 0;
            while (bok && noffset < _Data.size())
            {
                const ULONG ulchunk =
                    static_cast<ULONG>(std::min<std::size_t>(_Data.size() - noffset, 1u << 30));
                bok = BCryptHashData(hhash,
                          reinterpret_cast<PUCHAR>(const_cast<char*>(_Data.data() + noffset)),
                          ulchunk, 0) == 0;
                noffset += ulchunk;
            }
            bok = bok && BCryptFinishHash(hhash, aHash, sizeof(aHash), 0) == 0;
            BCryptDestroyHash(hhash);
        }
        BCryptCloseAlgorithmProvider(halg, 0);
        if (!bok)
        {
            return {};
        }

        static const char kDigits[] = "0123456789abcdef";
        std::string out;
        for (const unsigned char uc : aHash)
        {
            out.push_back(kDigits[uc >> 4]);
            out.push_back(kDigits[uc & 0x0F]);
        }
        return out;
    }

    bool ExtractZip(const std::string& _ZipPath, const std::string& _DestDir, std::string& _Error)
    {
        return ExtractArchive(_ZipPath, _DestDir, nullptr, _Error);
    }

    bool ExtractArchive(const std::string& _Archive, const std::string& _DestDir,
        const std::function<bool(std::uint64_t, std::uint64_t)>& _OnProgress, std::string& _Error)
    {
        // Windows' own bsdtar reads zip files. Use it by full path: a tar.exe
        // earlier on PATH (Git's GNU tar) can't.
        wchar_t wszsystem[MAX_PATH] = {};
        const UINT uilen = GetSystemDirectoryW(wszsystem, MAX_PATH);
        if (uilen == 0 || uilen >= MAX_PATH)
        {
            _Error = "could not locate the system folder";
            return false;
        }
        const fs::path tar = fs::path(wszsystem) / L"tar.exe";
        std::error_code ec;
        if (!fs::exists(tar, ec))
        {
            _Error = "Windows' tar.exe is missing (Windows 10 1803 or later is needed)";
            return false;
        }
        fs::create_directories(fs::u8path(_DestDir), ec);
        const std::uint64_t utotal = fs::file_size(fs::u8path(_Archive), ec);
        if (ec)
        {
            _Error = "cannot read " + _Archive;
            return false;
        }

        // tar's messages through a pipe (read on a thread so it never blocks);
        // no input, no output. Progress is what it has read of the archive
        // (its I/O counters), polled while it runs.
        SECURITY_ATTRIBUTES sa = {};
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;
        HANDLE herrRead = nullptr;
        HANDLE herrWrite = nullptr;
        if (!CreatePipe(&herrRead, &herrWrite, &sa, 0))
        {
            _Error = "could not create a pipe";
            return false;
        }
        SetHandleInformation(herrRead, HANDLE_FLAG_INHERIT, 0);
        HANDLE hnul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);
        std::wstring cmd = L"\"" + tar.wstring() + L"\" -xf " +
                           Widen(QuoteArgument(_Archive)) + L" -C " +
                           Widen(QuoteArgument(_DestDir));
        std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
        buffer.push_back(L'\0');
        PROCESS_INFORMATION pi = {};
        const bool bstarted = SpawnWithStdHandles(
            buffer.data(), CREATE_NO_WINDOW, nullptr, nullptr, hnul, hnul, herrWrite, pi);
        CloseHandle(herrWrite);
        if (hnul != INVALID_HANDLE_VALUE)
        {
            CloseHandle(hnul);
        }
        if (!bstarted)
        {
            CloseHandle(herrRead);
            _Error = "could not start " + tar.u8string();
            return false;
        }
        CloseHandle(pi.hThread);
        std::string errors;
        std::thread reader(
            [herrRead, &errors]()
            {
                char szbuf[4096];
                DWORD dwread = 0;
                while (ReadFile(herrRead, szbuf, sizeof(szbuf), &dwread, nullptr) && dwread > 0)
                {
                    errors.append(szbuf, dwread);
                }
            });
        bool bcancelled = false;
        do
        {
            if (!_OnProgress)
            {
                continue;
            }
            IO_COUNTERS io = {};
            const std::uint64_t uread =
                GetProcessIoCounters(pi.hProcess, &io) ? io.ReadTransferCount : 0;
            if (!_OnProgress((std::min)(uread, utotal), utotal))
            {
                TerminateProcess(pi.hProcess, 1);
                WaitForSingleObject(pi.hProcess, INFINITE);
                bcancelled = true;
                break;
            }
        } while (WaitForSingleObject(pi.hProcess, 100) == WAIT_TIMEOUT);
        DWORD dwexit = 0;
        GetExitCodeProcess(pi.hProcess, &dwexit);
        CloseHandle(pi.hProcess);
        reader.join();
        CloseHandle(herrRead);
        if (bcancelled)
        {
            _Error = "cancelled";
            return false;
        }
        if (dwexit != 0)
        {
            _Error = "unpacking failed: " + errors;
            return false;
        }
        if (_OnProgress)
        {
            _OnProgress(utotal, utotal);
        }
        return true;
    }

#else

    bool HttpGet(const std::string&, std::string& _Body, std::string& _Error)
    {
        _Body.clear();
        _Error = "downloads are not implemented on this platform";
        return false;
    }

    bool HttpGetEx(const std::string&, const std::string&, std::string& _Body, unsigned long& _uStatus,
        const std::function<bool(std::uint64_t)>&, std::string& _Error)
    {
        _Body.clear();
        _uStatus = 0;
        _Error = "downloads are not implemented on this platform";
        return false;
    }

    std::string Sha256Hex(const std::string&)
    {
        return {};
    }

    bool HttpDownloadFile(const std::string&, const std::string&,
        const std::function<bool(std::uint64_t, std::uint64_t)>&, std::string& _Error)
    {
        _Error = "downloads are not implemented on this platform";
        return false;
    }

    std::string Sha256FileHex(const std::string&, const std::function<bool(std::uint64_t)>&)
    {
        return {};
    }

    bool ExtractZip(const std::string&, const std::string&, std::string& _Error)
    {
        _Error = "unpacking archives is not implemented on this platform";
        return false;
    }

    bool ExtractArchive(const std::string&, const std::string&,
        const std::function<bool(std::uint64_t, std::uint64_t)>&, std::string& _Error)
    {
        _Error = "unpacking archives is not implemented on this platform";
        return false;
    }

#endif

} // namespace gitgud::platform
