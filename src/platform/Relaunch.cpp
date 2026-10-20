#include "platform/Relaunch.h"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <cerrno>
#include <climits>
#include <csignal>
#include <fstream>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <cstdint>
#include <mach-o/dyld.h>
#endif
extern char** environ;
#endif

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {

        std::wstring g_CommandLine; // as this copy was started
        std::wstring g_WorkingDir;

        std::wstring Widen(const char* _szAscii)
        {
            return std::wstring(_szAscii, _szAscii + std::strlen(_szAscii));
        }

        std::wstring ModulePath()
        {
            std::vector<wchar_t> buffer(MAX_PATH);
            for (;;)
            {
                const DWORD dwlen =
                    GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
                if (dwlen == 0)
                {
                    return {};
                }
                if (dwlen < buffer.size())
                {
                    return std::wstring(buffer.data(), dwlen);
                }
                buffer.resize(buffer.size() * 2);
            }
        }

        // This environment with `_Name` set to `_Value`, as CreateProcessW
        // takes it: "name=value" strings in order of name, then an empty one.
        std::vector<wchar_t> EnvironmentWith(const std::wstring& _Name, const std::wstring& _Value)
        {
            const std::wstring prefix = _Name + L"=";
            std::vector<std::wstring> entries;
            if (wchar_t* pblock = GetEnvironmentStringsW())
            {
                for (const wchar_t* p = pblock; *p; p += std::wcslen(p) + 1)
                {
                    if (_wcsnicmp(p, prefix.c_str(), prefix.size()) != 0)
                    {
                        entries.emplace_back(p);
                    }
                }
                FreeEnvironmentStringsW(pblock);
            }
            const std::wstring entry = prefix + _Value;
            const auto it = std::find_if(entries.begin(), entries.end(),
                [&entry](const std::wstring& _Other) { return _wcsicmp(_Other.c_str(), entry.c_str()) > 0; });
            entries.insert(it, entry);
            std::vector<wchar_t> block;
            for (const std::wstring& one : entries)
            {
                block.insert(block.end(), one.begin(), one.end());
                block.push_back(L'\0');
            }
            block.push_back(L'\0');
            return block;
        }

    } // namespace

    void RememberLaunch(int, char*[])
    {
        g_CommandLine = GetCommandLineW();
        const DWORD dwlen = GetCurrentDirectoryW(0, nullptr);
        if (dwlen > 0)
        {
            std::wstring dir(dwlen, L'\0');
            const DWORD dwgot = GetCurrentDirectoryW(dwlen, dir.data());
            dir.resize(dwgot < dwlen ? dwgot : 0);
            g_WorkingDir = dir;
        }
    }

    bool StartRelaunch(std::string& _Error)
    {
        const std::wstring exe = ModulePath();
        if (exe.empty())
        {
            _Error = "Couldn't find the program's own file.";
            return false;
        }
        const std::wstring command = g_CommandLine.empty() ? L"\"" + exe + L"\"" : g_CommandLine;
        std::vector<wchar_t> environment = EnvironmentWith(
            Widen(kRelaunchWaitVariable), std::to_wstring(GetCurrentProcessId()));
        // Out of this copy's job when it's in one that ends with it (a
        // terminal's, a test runner's); as it is when the job won't allow it.
        for (const DWORD dwbreakaway : {static_cast<DWORD>(CREATE_BREAKAWAY_FROM_JOB), DWORD{0}})
        {
            std::vector<wchar_t> buffer(command.begin(), command.end());
            buffer.push_back(L'\0');
            STARTUPINFOW startup = {};
            startup.cb = sizeof(startup);
            PROCESS_INFORMATION process = {};
            if (CreateProcessW(exe.c_str(), buffer.data(), nullptr, nullptr, FALSE,
                    CREATE_UNICODE_ENVIRONMENT | dwbreakaway, environment.data(),
                    g_WorkingDir.empty() ? nullptr : g_WorkingDir.c_str(), &startup, &process))
            {
                CloseHandle(process.hThread);
                CloseHandle(process.hProcess);
                return true;
            }
            if (GetLastError() != ERROR_ACCESS_DENIED)
            {
                break;
            }
        }
        _Error = "Couldn't start the program again (error " + std::to_string(GetLastError()) + ").";
        return false;
    }

    bool WaitForProcessExit(unsigned long _uPid, int _iTimeoutMs)
    {
        HANDLE hprocess = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
            static_cast<DWORD>(_uPid));
        if (!hprocess)
        {
            return true;
        }
        FILETIME created{}, mine{}, unused1{}, unused2{}, unused3{};
        if (GetProcessTimes(hprocess, &created, &unused1, &unused2, &unused3) &&
            GetProcessTimes(GetCurrentProcess(), &mine, &unused1, &unused2, &unused3) &&
            CompareFileTime(&created, &mine) > 0)
        {
            CloseHandle(hprocess);
            return true; // the id was reused
        }
        const bool bgone =
            WaitForSingleObject(hprocess, static_cast<DWORD>(std::max(0, _iTimeoutMs))) == WAIT_OBJECT_0;
        CloseHandle(hprocess);
        return bgone;
    }

    bool WaitForEarlierCopy(int _iTimeoutMs)
    {
        const char* szpid = std::getenv(kRelaunchWaitVariable);
        if (!szpid)
        {
            return true;
        }
        const unsigned long upid = std::strtoul(szpid, nullptr, 10);
        _putenv_s(kRelaunchWaitVariable, ""); // gone from the CRT's copy and the process's
        return upid == 0 || WaitForProcessExit(upid, _iTimeoutMs);
    }

#else

    namespace
    {

        std::vector<std::string> g_Args; // as this copy was started
        std::string g_WorkingDir;

        std::string ExecutablePath()
        {
#if defined(__APPLE__)
            char szexe[4096] = {};
            std::uint32_t nsize = sizeof(szexe);
            if (_NSGetExecutablePath(szexe, &nsize) == 0)
            {
                char szreal[PATH_MAX] = {};
                return realpath(szexe, szreal) ? std::string(szreal) : std::string(szexe);
            }
#else
            char szexe[4096] = {};
            const ssize_t nlen = readlink("/proc/self/exe", szexe, sizeof(szexe) - 1);
            if (nlen > 0)
            {
                return std::string(szexe, static_cast<size_t>(nlen));
            }
#endif
            return g_Args.empty() ? std::string() : g_Args.front();
        }

        bool Alive(pid_t _Pid)
        {
            if (kill(_Pid, 0) != 0)
            {
                return errno == EPERM;
            }
#if !defined(__APPLE__)
            // Exited but not yet collected by its parent: gone all the same.
            std::ifstream stat("/proc/" + std::to_string(_Pid) + "/stat");
            std::string line;
            std::getline(stat, line);
            const size_t nclose = line.rfind(')');
            if (nclose != std::string::npos && nclose + 2 < line.size() && line[nclose + 2] == 'Z')
            {
                return false;
            }
#endif
            return true;
        }

    } // namespace

    void RememberLaunch(int _iArgc, char* _aSzArgv[])
    {
        g_Args.assign(_aSzArgv, _aSzArgv + _iArgc);
        char szdir[PATH_MAX] = {};
        if (getcwd(szdir, sizeof(szdir)))
        {
            g_WorkingDir = szdir;
        }
    }

    bool StartRelaunch(std::string& _Error)
    {
        const std::string exe = ExecutablePath();
        if (exe.empty())
        {
            _Error = "Couldn't find the program's own file.";
            return false;
        }
        // Everything made before the fork: the child only calls what's safe
        // in a copy of a process with threads.
        std::vector<std::string> args = g_Args.empty() ? std::vector<std::string>{exe} : g_Args;
        std::vector<char*> argv;
        for (std::string& arg : args)
        {
            argv.push_back(arg.data());
        }
        argv.push_back(nullptr);
        const std::string prefix = std::string(kRelaunchWaitVariable) + "=";
        std::vector<std::string> env;
        for (char** pp = environ; pp && *pp; ++pp)
        {
            if (std::strncmp(*pp, prefix.c_str(), prefix.size()) != 0)
            {
                env.emplace_back(*pp);
            }
        }
        env.push_back(prefix + std::to_string(getpid()));
        std::vector<char*> envp;
        for (std::string& one : env)
        {
            envp.push_back(one.data());
        }
        envp.push_back(nullptr);
        const long imaxFd = std::min(sysconf(_SC_OPEN_MAX), 65536L);

        const pid_t pid = fork();
        if (pid < 0)
        {
            _Error = "Couldn't start the program again.";
            return false;
        }
        if (pid == 0)
        {
            // Its own session, and a double fork so it's never our zombie;
            // only the standard streams go with it.
            setsid();
            if (fork() != 0)
            {
                _exit(0);
            }
            for (int ifd = 3; ifd < imaxFd; ++ifd)
            {
                close(ifd);
            }
            if (!g_WorkingDir.empty() && chdir(g_WorkingDir.c_str()) != 0)
            {
                _exit(127);
            }
            execve(exe.c_str(), argv.data(), envp.data());
            _exit(127);
        }
        int istatus = 0;
        while (waitpid(pid, &istatus, 0) < 0 && errno == EINTR)
        {
        }
        return true;
    }

    bool WaitForProcessExit(unsigned long _uPid, int _iTimeoutMs)
    {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(_iTimeoutMs);
        const pid_t pid = static_cast<pid_t>(_uPid);
        while (Alive(pid))
        {
            if (std::chrono::steady_clock::now() >= deadline)
            {
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        return true;
    }

    bool WaitForEarlierCopy(int _iTimeoutMs)
    {
        const char* szpid = std::getenv(kRelaunchWaitVariable);
        if (!szpid)
        {
            return true;
        }
        const unsigned long upid = std::strtoul(szpid, nullptr, 10);
        unsetenv(kRelaunchWaitVariable);
        return upid == 0 || WaitForProcessExit(upid, _iTimeoutMs);
    }

#endif

} // namespace gitgud::platform
