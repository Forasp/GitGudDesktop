#include "platform/Shell.h"

#include "app/Profiler.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <shellapi.h>
#include <shlobj.h>
#include <io.h>
#include <shobjidl.h>
#else
#include "platform/Process.h"

#include <SDL.h>

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <ctime>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <cstdint>
#include <mach-o/dyld.h>
#endif
#endif

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <vector>

namespace gitgud::platform
{

    std::string ConfigDirectory()
    {
        namespace fs = std::filesystem;
#if defined(_WIN32)
        if (const char* szappdata = std::getenv("APPDATA"))
        {
            return (fs::u8path(szappdata) / "Gitgud").u8string();
        }
#elif defined(__APPLE__)
        if (const char* szhome = std::getenv("HOME"))
        {
            return (fs::u8path(szhome) / "Library" / "Application Support" / "Gitgud").u8string();
        }
#else
        if (const char* szconfig = std::getenv("XDG_CONFIG_HOME"); szconfig && *szconfig)
        {
            return (fs::u8path(szconfig) / "gitgud").u8string();
        }
        if (const char* szhome = std::getenv("HOME"))
        {
            return (fs::u8path(szhome) / ".config" / "gitgud").u8string();
        }
#endif
        // Never the exe's folder: it may be read only (Program Files, /usr).
        std::error_code ec;
        return (fs::temp_directory_path(ec) / "Gitgud").u8string();
    }

    std::string LocalDataDirectory()
    {
        namespace fs = std::filesystem;
#if defined(_WIN32)
        if (const char* szlocal = std::getenv("LOCALAPPDATA"); szlocal && *szlocal)
        {
            return (fs::u8path(szlocal) / "Gitgud").u8string();
        }
#elif defined(__APPLE__)
        return ConfigDirectory();
#else
        if (const char* szdata = std::getenv("XDG_DATA_HOME"); szdata && *szdata)
        {
            return (fs::u8path(szdata) / "gitgud").u8string();
        }
        if (const char* szhome = std::getenv("HOME"))
        {
            return (fs::u8path(szhome) / ".local" / "share" / "gitgud").u8string();
        }
#endif
        return ConfigDirectory();
    }

    std::string ExecutableDirectory()
    {
        namespace fs = std::filesystem;
        std::error_code ec;
#if defined(_WIN32)
        wchar_t wszexe[MAX_PATH * 2] = {};
        const DWORD dwlen = GetModuleFileNameW(nullptr, wszexe, MAX_PATH * 2);
        if (dwlen > 0 && dwlen < MAX_PATH * 2)
        {
            return fs::path(wszexe).parent_path().u8string();
        }
#elif defined(__APPLE__)
        char szexe[4096] = {};
        std::uint32_t nsize = sizeof(szexe);
        if (_NSGetExecutablePath(szexe, &nsize) == 0)
        {
            // In an app bundle the exe is in Contents/MacOS and its files in
            // Contents/Resources.
            const fs::path dir = fs::canonical(szexe, ec).parent_path();
            const fs::path resources = dir.parent_path() / "Resources";
            if (dir.filename() == "MacOS" && fs::is_directory(resources, ec))
            {
                return resources.u8string();
            }
            return dir.u8string();
        }
#else
        const fs::path exe = fs::read_symlink("/proc/self/exe", ec);
        if (!ec)
        {
            return exe.parent_path().u8string();
        }
#endif
        return fs::current_path(ec).u8string();
    }

    bool WriteFileAtomically(const std::string& _Path, const std::string& _Data, std::string& _Error)
    {
        GITGUD_PROFILE_FUNCTION();
        namespace fs = std::filesystem;
        const fs::path file = fs::u8path(_Path);
        std::error_code ec;
        fs::create_directories(file.parent_path(), ec);
        fs::path temp = file;
        temp += ".tmp";
        {
            std::FILE* pfile = nullptr;
#if defined(_WIN32)
            _wfopen_s(&pfile, temp.c_str(), L"wb");
#else
            pfile = std::fopen(temp.c_str(), "wb");
#endif
            if (!pfile)
            {
                _Error = "could not write " + temp.u8string();
                return false;
            }
            const bool bwritten = std::fwrite(_Data.data(), 1, _Data.size(), pfile) == _Data.size() &&
                                  std::fflush(pfile) == 0;
#if defined(_WIN32)
            const bool bsynced = bwritten && _commit(_fileno(pfile)) == 0;
#else
            const bool bsynced = bwritten && fsync(fileno(pfile)) == 0;
#endif
            std::fclose(pfile);
            if (!bsynced)
            {
                fs::remove(temp, ec);
                _Error = "could not write " + temp.u8string();
                return false;
            }
        }
        fs::rename(temp, file, ec); // replaces the old file in one step
        if (ec)
        {
            fs::remove(temp, ec);
            _Error = "could not replace " + file.u8string() + ": " + ec.message();
            return false;
        }
        return true;
    }

    std::string LogDirectory()
    {
        namespace fs = std::filesystem;
        const fs::path dir = fs::u8path(ConfigDirectory()) / "logs";
        std::error_code ec;
        fs::create_directories(dir, ec);
        if (ec)
        {
            return fs::temp_directory_path(ec).u8string();
        }
        return dir.u8string();
    }

#if defined(_WIN32)

    namespace
    {

        std::wstring Widen(const std::string& _Utf8)
        {
            if (_Utf8.empty())
            {
                return {};
            }
            const int iwide = MultiByteToWideChar(CP_UTF8, 0, _Utf8.c_str(), -1, nullptr, 0);
            std::wstring out(static_cast<std::size_t>(iwide > 0 ? iwide : 1), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, _Utf8.c_str(), -1, out.data(), iwide);
            out.resize(out.size() - 1); // drop the terminator MultiByteToWideChar wrote
            return out;
        }

        std::string Narrow(const wchar_t* _szWide)
        {
            const int ilen =
                WideCharToMultiByte(CP_UTF8, 0, _szWide, -1, nullptr, 0, nullptr, nullptr);
            if (ilen <= 1)
            {
                return {};
            }
            std::string out(static_cast<std::size_t>(ilen - 1), '\0');
            WideCharToMultiByte(CP_UTF8, 0, _szWide, -1, out.data(), ilen, nullptr, nullptr);
            return out;
        }

        std::wstring BackslashPath(const std::string& _Path)
        {
            std::wstring wide = Widen(_Path);
            for (wchar_t& c : wide)
            {
                if (c == L'/')
                {
                    c = L'\\';
                }
            }
            return wide;
        }

    } // namespace

    bool OpenExternal(const std::string& _Target, std::string& _Error)
    {
        const std::wstring wide = Widen(_Target);
        const auto rc = reinterpret_cast<INT_PTR>(
            ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        if (rc <= 32)
        {
            _Error = "could not open '" + _Target + "'";
            return false;
        }
        return true;
    }

    bool ShowInFolder(const std::string& _Path, std::string& _Error)
    {
        const std::wstring args = L"/select,\"" + BackslashPath(_Path) + L"\"";
        const auto rc = reinterpret_cast<INT_PTR>(
            ShellExecuteW(nullptr, L"open", L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL));
        if (rc <= 32)
        {
            _Error = "could not reveal '" + _Path + "'";
            return false;
        }
        return true;
    }

    bool Spawn(const std::string& _CommandLine, const std::string& _WorkingDir, std::string& _Error)
    {
        std::wstring cmd = Widen(_CommandLine);
        const std::wstring cwd = BackslashPath(_WorkingDir);

        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi = {};
        // CreateProcessW may modify the command buffer, so it must be writable.
        std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
        buffer.push_back(L'\0');
        // A new console so terminal commands get their own window; GUI editors
        // simply ignore it.
        const BOOL bok = CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE,
            CREATE_NEW_CONSOLE, nullptr, cwd.empty() ? nullptr : cwd.c_str(), &si, &pi);
        if (!bok)
        {
            _Error = "could not start: " + _CommandLine;
            return false;
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return true;
    }

    bool MoveToTrash(const std::string& _Path)
    {
        // SHFileOperation wants a double-NUL-terminated list.
        std::wstring from = BackslashPath(_Path);
        from.push_back(L'\0');
        from.push_back(L'\0');

        SHFILEOPSTRUCTW op = {};
        op.wFunc = FO_DELETE;
        op.pFrom = from.c_str();
        op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
        return SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted;
    }

    std::string PickFolder(const std::string& _Title)
    {
        std::string result;
        const HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

        IFileOpenDialog* pdialog = nullptr;
        if (SUCCEEDED(CoCreateInstance(
                CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pdialog))))
        {
            DWORD dwoptions = 0;
            pdialog->GetOptions(&dwoptions);
            pdialog->SetOptions(dwoptions | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
            const std::wstring title = Widen(_Title);
            if (!title.empty())
            {
                pdialog->SetTitle(title.c_str());
            }
            if (SUCCEEDED(pdialog->Show(GetActiveWindow())))
            {
                IShellItem* pitem = nullptr;
                if (SUCCEEDED(pdialog->GetResult(&pitem)))
                {
                    PWSTR pszpath = nullptr;
                    if (SUCCEEDED(pitem->GetDisplayName(SIGDN_FILESYSPATH, &pszpath)))
                    {
                        result = Narrow(pszpath);
                        CoTaskMemFree(pszpath);
                    }
                    pitem->Release();
                }
            }
            pdialog->Release();
        }

        if (SUCCEEDED(hrInit))
        {
            CoUninitialize();
        }
        return result;
    }

    std::string PickFile(const std::string& _Title, const std::string& _FilterName, const std::string& _Pattern)
    {
        std::string result;
        const HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

        IFileOpenDialog* pdialog = nullptr;
        if (SUCCEEDED(CoCreateInstance(
                CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pdialog))))
        {
            DWORD dwoptions = 0;
            pdialog->GetOptions(&dwoptions);
            pdialog->SetOptions(dwoptions | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
            const std::wstring title = Widen(_Title);
            if (!title.empty())
            {
                pdialog->SetTitle(title.c_str());
            }
            const std::wstring name = Widen(_FilterName.empty() ? "Files" : _FilterName);
            const std::wstring pattern = Widen(_Pattern.empty() ? "*.*" : _Pattern);
            const COMDLG_FILTERSPEC filter = {name.c_str(), pattern.c_str()};
            pdialog->SetFileTypes(1, &filter);
            if (SUCCEEDED(pdialog->Show(GetActiveWindow())))
            {
                IShellItem* pitem = nullptr;
                if (SUCCEEDED(pdialog->GetResult(&pitem)))
                {
                    PWSTR pszpath = nullptr;
                    if (SUCCEEDED(pitem->GetDisplayName(SIGDN_FILESYSPATH, &pszpath)))
                    {
                        result = Narrow(pszpath);
                        CoTaskMemFree(pszpath);
                    }
                    pitem->Release();
                }
            }
            pdialog->Release();
        }

        if (SUCCEEDED(hrInit))
        {
            CoUninitialize();
        }
        return result;
    }

    bool SetClipboardText(const std::string& _Text)
    {
        const std::wstring wide = Widen(_Text);
        HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, (wide.size() + 1) * sizeof(wchar_t));
        if (!handle)
        {
            return false;
        }
        auto* pdest = static_cast<wchar_t*>(GlobalLock(handle));
        std::copy(wide.begin(), wide.end(), pdest);
        pdest[wide.size()] = L'\0';
        GlobalUnlock(handle);

        if (!OpenClipboard(nullptr))
        {
            GlobalFree(handle);
            return false;
        }
        EmptyClipboard();
        const bool bok = SetClipboardData(CF_UNICODETEXT, handle) != nullptr;
        if (!bok)
        {
            GlobalFree(handle);
        }
        CloseClipboard();
        return bok;
    }

    namespace
    {

        // A clipboard bitmap (CF_DIB / CF_DIBV5: a header, maybe masks and a
        // palette, then pixels) as a .bmp file, which stb_image reads.
        bool BmpFromDib(const std::uint8_t* _pDib, std::size_t _nSize, std::string& _Out)
        {
            if (_nSize < sizeof(BITMAPINFOHEADER))
            {
                return false;
            }
            BITMAPINFOHEADER header;
            std::memcpy(&header, _pDib, sizeof(header));
            if (header.biSize < sizeof(BITMAPINFOHEADER) || header.biSize > _nSize)
            {
                return false;
            }
            std::size_t nmasks = 0;
            if (header.biSize == sizeof(BITMAPINFOHEADER))
            {
                nmasks = header.biCompression == BI_BITFIELDS ? 12 : header.biCompression == 6 ? 16 : 0;
            }
            std::size_t ncolours = header.biClrUsed;
            if (ncolours == 0 && header.biBitCount <= 8)
            {
                ncolours = std::size_t{1} << header.biBitCount;
            }
            const std::size_t noffset = 14 + header.biSize + nmasks + ncolours * 4;
            const std::size_t ntotal = 14 + _nSize;
            _Out.assign(14, '\0');
            _Out[0] = 'B';
            _Out[1] = 'M';
            const auto put32 = [&](std::size_t _nAt, std::uint32_t _uValue)
            {
                for (int i = 0; i < 4; ++i)
                {
                    _Out[_nAt + i] = static_cast<char>((_uValue >> (8 * i)) & 0xFF);
                }
            };
            put32(2, static_cast<std::uint32_t>(ntotal));
            put32(10, static_cast<std::uint32_t>(noffset));
            _Out.append(reinterpret_cast<const char*>(_pDib), _nSize);
            return true;
        }

        // A clipboard format's bytes; the clipboard is open.
        bool ClipboardBytes(UINT _uFormat, std::string& _Out)
        {
            HANDLE handle = GetClipboardData(_uFormat);
            if (!handle)
            {
                return false;
            }
            const SIZE_T nsize = GlobalSize(handle);
            const void* pdata = GlobalLock(handle);
            if (!pdata || nsize == 0)
            {
                return false;
            }
            _Out.assign(static_cast<const char*>(pdata), nsize);
            GlobalUnlock(handle);
            return true;
        }

    } // namespace

    bool ClipboardHasText()
    {
        return IsClipboardFormatAvailable(CF_UNICODETEXT) != 0;
    }

    bool ClipboardImage(std::string& _Bytes)
    {
        _Bytes.clear();
        if (!OpenClipboard(nullptr))
        {
            return false;
        }
        static const UINT kPng = RegisterClipboardFormatW(L"PNG");
        bool bok = kPng != 0 && IsClipboardFormatAvailable(kPng) && ClipboardBytes(kPng, _Bytes);
        for (const UINT uformat : {static_cast<UINT>(CF_DIBV5), static_cast<UINT>(CF_DIB)})
        {
            std::string dib;
            if (!bok && IsClipboardFormatAvailable(uformat) && ClipboardBytes(uformat, dib))
            {
                bok = BmpFromDib(reinterpret_cast<const std::uint8_t*>(dib.data()), dib.size(), _Bytes);
            }
        }
        CloseClipboard();
        return bok;
    }

    std::vector<std::string> ClipboardFiles()
    {
        std::vector<std::string> files;
        if (!IsClipboardFormatAvailable(CF_HDROP) || !OpenClipboard(nullptr))
        {
            return files;
        }
        if (HANDLE handle = GetClipboardData(CF_HDROP))
        {
            if (auto hdrop = static_cast<HDROP>(GlobalLock(handle)))
            {
                const UINT ncount = DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
                for (UINT i = 0; i < ncount; ++i)
                {
                    std::wstring path(DragQueryFileW(hdrop, i, nullptr, 0) + 1, L'\0');
                    DragQueryFileW(hdrop, i, path.data(), static_cast<UINT>(path.size()));
                    files.push_back(Narrow(path.c_str()));
                }
                GlobalUnlock(handle);
            }
        }
        CloseClipboard();
        return files;
    }

#else

    namespace
    {

        namespace fs = std::filesystem;

        // Start /bin/sh -c `_CommandLine` fully detached: its own session, no
        // stdio, and a double fork so it never becomes our zombie.
        bool SpawnDetached(const std::string& _CommandLine, const std::string& _WorkingDir)
        {
            const pid_t pid = fork();
            if (pid < 0)
            {
                return false;
            }
            if (pid == 0)
            {
                setsid();
                if (fork() != 0)
                {
                    _exit(0);
                }
                const int inull = open("/dev/null", O_RDWR);
                dup2(inull, STDIN_FILENO);
                dup2(inull, STDOUT_FILENO);
                dup2(inull, STDERR_FILENO);
                if (!_WorkingDir.empty() && chdir(_WorkingDir.c_str()) != 0)
                {
                    _exit(127);
                }
                execl("/bin/sh", "sh", "-c", _CommandLine.c_str(), static_cast<char*>(nullptr));
                _exit(127);
            }
            int istatus = 0;
            while (waitpid(pid, &istatus, 0) < 0 && errno == EINTR)
            {
            }
            return true;
        }

        // Single-quote a word for /bin/sh.
        std::string ShellQuote(const std::string& _Word)
        {
            std::string out = "'";
            for (const char c : _Word)
            {
                if (c == '\'')
                {
                    out += "'\\''";
                }
                else
                {
                    out.push_back(c);
                }
            }
            out.push_back('\'');
            return out;
        }

#if !defined(__APPLE__)
        // file:// URI for an absolute path, percent-encoding everything but
        // unreserved characters and '/'.
        std::string FileUri(const std::string& _Path)
        {
            static const char kHex[] = "0123456789ABCDEF";
            std::string out = "file://";
            for (const unsigned char c : _Path)
            {
                if (std::isalnum(c) || c == '/' || c == '-' || c == '_' || c == '.' || c == '~')
                {
                    out.push_back(static_cast<char>(c));
                }
                else
                {
                    out.push_back('%');
                    out.push_back(kHex[c >> 4]);
                    out.push_back(kHex[c & 15]);
                }
            }
            return out;
        }
#endif

#if defined(__APPLE__)
        // An AppleScript string literal: quotes and backslashes escaped.
        std::string AppleScriptString(const std::string& _Text)
        {
            std::string out = "\"";
            for (const char c : _Text)
            {
                if (c == '"' || c == '\\')
                {
                    out.push_back('\\');
                }
                out.push_back(c);
            }
            out.push_back('"');
            return out;
        }
#endif

        std::string Trimmed(std::string _Text)
        {
            while (!_Text.empty() && (_Text.back() == '\n' || _Text.back() == '\r'))
            {
                _Text.pop_back();
            }
            return _Text;
        }

#if !defined(__APPLE__)
        // The FreeDesktop trash spec's home trash: move the file into
        // $XDG_DATA_HOME/Trash/files and describe it in Trash/info. Only works
        // on the home folder's file system (rename can't cross devices).
        bool MoveToHomeTrash(const fs::path& _Path)
        {
            fs::path dataHome;
            if (const char* szdata = std::getenv("XDG_DATA_HOME"); szdata && *szdata)
            {
                dataHome = szdata;
            }
            else if (const char* szhome = std::getenv("HOME"))
            {
                dataHome = fs::path(szhome) / ".local" / "share";
            }
            else
            {
                return false;
            }
            const fs::path filesDir = dataHome / "Trash" / "files";
            const fs::path infoDir = dataHome / "Trash" / "info";
            std::error_code ec;
            fs::create_directories(filesDir, ec);
            fs::create_directories(infoDir, ec);

            const std::string base = _Path.filename().string();
            for (int i = 0; i < 1000; ++i)
            {
                const std::string name = i == 0 ? base : base + "." + std::to_string(i);
                const fs::path info = infoDir / (name + ".trashinfo");
                // O_EXCL claims the name, as the spec asks.
                const int ifd = open(info.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
                if (ifd < 0)
                {
                    continue;
                }
                char szwhen[32] = {};
                const std::time_t now = std::time(nullptr);
                std::tm local = {};
                localtime_r(&now, &local);
                std::strftime(szwhen, sizeof(szwhen), "%Y-%m-%dT%H:%M:%S", &local);
                const std::string uri = FileUri(_Path.string());
                const std::string body = "[Trash Info]\nPath=" + uri.substr(7) +
                                         "\nDeletionDate=" + szwhen + "\n";
                const bool bwritten =
                    write(ifd, body.data(), body.size()) == static_cast<ssize_t>(body.size());
                close(ifd);
                if (bwritten && std::rename(_Path.c_str(), (filesDir / name).c_str()) == 0)
                {
                    return true;
                }
                fs::remove(info, ec);
                return false;
            }
            return false;
        }
#endif

    } // namespace

    bool OpenExternal(const std::string& _Target, std::string& _Error)
    {
#if defined(__APPLE__)
        const char* szopener = "open";
#else
        const char* szopener = "xdg-open";
#endif
        if (FindProgram(szopener).empty() ||
            !SpawnDetached(std::string(szopener) + " " + ShellQuote(_Target), ""))
        {
            _Error = "could not open '" + _Target + "'";
            return false;
        }
        return true;
    }

    bool ShowInFolder(const std::string& _Path, std::string& _Error)
    {
        std::error_code ec;
        const fs::path path = fs::absolute(fs::u8path(_Path), ec);
#if defined(__APPLE__)
        if (RunProcess({"open", "-R", path.u8string()}, "").m_iExitCode == 0)
        {
            return true;
        }
#else
        // File managers that implement org.freedesktop.FileManager1 select
        // the item; anything else just opens the folder.
        if (!FindProgram("dbus-send").empty() &&
            RunProcess({"dbus-send", "--session", "--print-reply",
                           "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                           "org.freedesktop.FileManager1.ShowItems",
                           "array:string:" + FileUri(path.u8string()), "string:"},
                "")
                    .m_iExitCode == 0)
        {
            return true;
        }
#endif
        const fs::path folder = fs::is_directory(path, ec) ? path : path.parent_path();
        if (!OpenExternal(folder.u8string(), _Error))
        {
            _Error = "could not reveal '" + _Path + "'";
            return false;
        }
        return true;
    }

    bool Spawn(const std::string& _CommandLine, const std::string& _WorkingDir, std::string& _Error)
    {
        if (!SpawnDetached(_CommandLine, _WorkingDir))
        {
            _Error = "could not start: " + _CommandLine;
            return false;
        }
        return true;
    }

    bool MoveToTrash(const std::string& _Path)
    {
        const fs::path path = fs::u8path(_Path);
        std::error_code ec;
        if (!fs::exists(fs::symlink_status(path, ec)))
        {
            return false;
        }
#if defined(__APPLE__)
        // Finder's own trash, through AppleScript (keeps "Put Back" working).
        const std::string script = "tell application \"Finder\" to delete POSIX file " +
                                   AppleScriptString(fs::absolute(path, ec).u8string());
        if (RunProcess({"osascript", "-e", script}, "").m_iExitCode == 0)
        {
            return true;
        }
        // Without Finder (or permission to ask it), move the file into the
        // user's Trash folder directly.
        if (const char* szhome = std::getenv("HOME"))
        {
            const fs::path trash = fs::path(szhome) / ".Trash";
            const fs::path source = fs::absolute(path, ec);
            fs::path target = trash / source.filename();
            for (int i = 1; fs::exists(fs::symlink_status(target, ec)) && i < 1000; ++i)
            {
                target = trash / (source.stem().string() + " " + std::to_string(i) +
                                     source.extension().string());
            }
            if (std::rename(source.c_str(), target.c_str()) == 0)
            {
                return true;
            }
        }
        return false;
#else
        // gio knows every trash location (other drives too); the spec's home
        // trash covers systems without it.
        if (!FindProgram("gio").empty() &&
            RunProcess({"gio", "trash", "--", fs::absolute(path, ec).u8string()}, "").m_iExitCode ==
                0)
        {
            return true;
        }
        return MoveToHomeTrash(fs::absolute(path, ec));
#endif
    }

    std::string PickFile(const std::string& _Title, const std::string& _FilterName, const std::string& _Pattern)
    {
#if defined(__APPLE__)
        (void)_FilterName;
        (void)_Pattern;
        const std::string script =
            "POSIX path of (choose file with prompt " + AppleScriptString(_Title) + ")";
        const ProcessResult result = RunProcess({"osascript", "-e", script}, "");
#else
        ProcessResult result;
        const std::string pattern = _Pattern.empty() ? "*" : _Pattern;
        if (!FindProgram("zenity").empty())
        {
            result = RunProcess({"zenity", "--file-selection", "--title=" + _Title,
                                    "--file-filter=" + (_FilterName.empty() ? "Files" : _FilterName) + " | " + pattern},
                "");
        }
        else if (!FindProgram("kdialog").empty())
        {
            result = RunProcess({"kdialog", "--getopenfilename", ".", pattern, "--title", _Title}, "");
        }
#endif
        if (result.m_iExitCode != 0)
        {
            return {};
        }
        return Trimmed(result.m_Output);
    }

    std::string PickFolder(const std::string& _Title)
    {
#if defined(__APPLE__)
        const std::string script =
            "POSIX path of (choose folder with prompt " + AppleScriptString(_Title) + ")";
        const ProcessResult result = RunProcess({"osascript", "-e", script}, "");
#else
        // The desktop's own dialog tools: zenity (GNOME and most others) or
        // kdialog (KDE).
        ProcessResult result;
        if (!FindProgram("zenity").empty())
        {
            result = RunProcess(
                {"zenity", "--file-selection", "--directory", "--title=" + _Title}, "");
        }
        else if (!FindProgram("kdialog").empty())
        {
            result = RunProcess({"kdialog", "--getexistingdirectory", ".", "--title", _Title}, "");
        }
#endif
        if (result.m_iExitCode != 0)
        {
            return {};
        }
        std::string path = Trimmed(result.m_Output);
        if (path.size() > 1 && path.back() == '/')
        {
            path.pop_back();
        }
        return path;
    }

    bool SetClipboardText(const std::string& _Text)
    {
        return SDL_SetClipboardText(_Text.c_str()) == 0;
    }

    bool ClipboardHasText()
    {
        return SDL_HasClipboardText() == SDL_TRUE;
    }

    bool ClipboardImage(std::string& _Bytes)
    {
        _Bytes.clear();
        return false;
    }

    std::vector<std::string> ClipboardFiles()
    {
        return {};
    }

#endif

} // namespace gitgud::platform
