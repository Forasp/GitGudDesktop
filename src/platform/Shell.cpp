#include "platform/Shell.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#endif

#include <algorithm>
#include <cstdlib>
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
#endif
        if (const char* szhome = std::getenv("HOME"))
        {
            return (fs::u8path(szhome) / ".gitgud").u8string();
        }
        // Never the exe's folder: it may be read only (Program Files).
        std::error_code ec;
        return (fs::temp_directory_path(ec) / "Gitgud").u8string();
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

#else

    bool OpenExternal(const std::string&, std::string& _Error)
    {
        _Error = "openExternal is not implemented on this platform";
        return false;
    }

    bool ShowInFolder(const std::string&, std::string& _Error)
    {
        _Error = "showInFolder is not implemented on this platform";
        return false;
    }

    bool Spawn(const std::string&, const std::string&, std::string& _Error)
    {
        _Error = "spawn is not implemented on this platform";
        return false;
    }

    bool MoveToTrash(const std::string&)
    {
        return false;
    }

    std::string PickFolder(const std::string&)
    {
        return {};
    }

    bool SetClipboardText(const std::string&)
    {
        return false;
    }

#endif

} // namespace gitgud::platform
