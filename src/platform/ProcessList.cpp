#include "platform/Process.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <winternl.h>
#elif defined(__linux__)
#include <filesystem>
#include <fstream>
#include <unistd.h>
#endif

#include <string>
#include <vector>

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {

        std::string Narrow(const wchar_t* _pText, std::size_t _nChars)
        {
            if (_nChars == 0)
            {
                return {};
            }
            const int ilen = WideCharToMultiByte(
                CP_UTF8, 0, _pText, static_cast<int>(_nChars), nullptr, 0, nullptr, nullptr);
            std::string out(static_cast<std::size_t>(ilen), '\0');
            WideCharToMultiByte(CP_UTF8, 0, _pText, static_cast<int>(_nChars), out.data(), ilen,
                nullptr, nullptr);
            return out;
        }

        // A process's command line (ProcessCommandLineInformation, Windows 8.1
        // and later), or "" when it can't be read.
        std::string CommandLineOf(DWORD _dwPid)
        {
            using QueryFn = LONG(NTAPI*)(HANDLE, int, PVOID, ULONG, PULONG);
            static const auto pquery = reinterpret_cast<QueryFn>(reinterpret_cast<void*>(
                GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess")));
            if (!pquery)
            {
                return {};
            }
            HANDLE hprocess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, _dwPid);
            if (!hprocess)
            {
                return {};
            }
            constexpr int ikCommandLine = 60;
            ULONG ulsize = 0;
            pquery(hprocess, ikCommandLine, nullptr, 0, &ulsize);
            std::string out;
            if (ulsize > 0 && ulsize < (1u << 20))
            {
                std::vector<unsigned char> buffer(ulsize);
                if (pquery(hprocess, ikCommandLine, buffer.data(), ulsize, &ulsize) >= 0)
                {
                    const auto* ptext = reinterpret_cast<const UNICODE_STRING*>(buffer.data());
                    out = Narrow(ptext->Buffer, ptext->Length / sizeof(wchar_t));
                }
            }
            CloseHandle(hprocess);
            return out;
        }

    } // namespace

    std::vector<unsigned long> ProcessesWithArgument(const std::string& _Needle)
    {
        std::vector<unsigned long> out;
        if (_Needle.empty())
        {
            return out;
        }
        HANDLE hsnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (hsnapshot == INVALID_HANDLE_VALUE)
        {
            return out;
        }
        const DWORD dwself = GetCurrentProcessId();
        PROCESSENTRY32W entry{};
        entry.dwSize = sizeof(entry);
        for (BOOL bmore = Process32FirstW(hsnapshot, &entry); bmore; bmore = Process32NextW(hsnapshot, &entry))
        {
            if (entry.th32ProcessID == dwself || entry.th32ProcessID == 0)
            {
                continue;
            }
            if (CommandLineOf(entry.th32ProcessID).find(_Needle) != std::string::npos)
            {
                out.push_back(entry.th32ProcessID);
            }
        }
        CloseHandle(hsnapshot);
        return out;
    }

#elif defined(__linux__)

    std::vector<unsigned long> ProcessesWithArgument(const std::string& _Needle)
    {
        namespace fs = std::filesystem;
        std::vector<unsigned long> out;
        if (_Needle.empty())
        {
            return out;
        }
        const unsigned long ulself = static_cast<unsigned long>(getpid());
        std::error_code ec;
        for (fs::directory_iterator it("/proc", ec), end; !ec && it != end; it.increment(ec))
        {
            const std::string name = it->path().filename().string();
            if (name.empty() || name.find_first_not_of("0123456789") != std::string::npos)
            {
                continue;
            }
            const unsigned long ulpid = std::stoul(name);
            if (ulpid == ulself)
            {
                continue;
            }
            std::ifstream in(it->path() / "cmdline", std::ios::binary);
            std::string line((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            for (char& c : line)
            {
                c = c == '\0' ? ' ' : c;
            }
            if (line.find(_Needle) != std::string::npos)
            {
                out.push_back(ulpid);
            }
        }
        return out;
    }

#else

    std::vector<unsigned long> ProcessesWithArgument(const std::string&)
    {
        return {};
    }

#endif

} // namespace gitgud::platform
