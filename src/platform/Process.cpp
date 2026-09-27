#include "platform/Process.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <thread>
#include <vector>

namespace gitgud::platform
{

    namespace fs = std::filesystem;

    std::string QuoteArgument(const std::string& _Arg)
    {
        // Rules of CommandLineToArgvW / the MSVC runtime: backslashes are
        // literal unless they precede a quote, where they must be doubled.
        if (!_Arg.empty() && _Arg.find_first_of(" \t\n\v\"") == std::string::npos)
        {
            return _Arg;
        }

        std::string out = "\"";
        std::size_t nbackslashes = 0;
        for (const char c : _Arg)
        {
            if (c == '\\')
            {
                ++nbackslashes;
                continue;
            }
            if (c == '"')
            {
                out.append(nbackslashes * 2 + 1, '\\');
            }
            else
            {
                out.append(nbackslashes, '\\');
            }
            nbackslashes = 0;
            out.push_back(c);
        }
        out.append(nbackslashes * 2, '\\');
        out.push_back('"');
        return out;
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
            const int iwide = MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), nullptr, 0);
            std::wstring out(static_cast<std::size_t>(iwide), L'\0');
            MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), out.data(), iwide);
            return out;
        }

        std::string Narrow(const std::wstring& _Wide)
        {
            if (_Wide.empty())
            {
                return {};
            }
            const int ilen = WideCharToMultiByte(CP_UTF8, 0, _Wide.data(),
                static_cast<int>(_Wide.size()), nullptr, 0, nullptr, nullptr);
            std::string out(static_cast<std::size_t>(ilen), '\0');
            WideCharToMultiByte(CP_UTF8, 0, _Wide.data(), static_cast<int>(_Wide.size()),
                out.data(), ilen, nullptr, nullptr);
            return out;
        }

        // Console programs print in the OEM code page unless they know better
        // (git itself prints UTF-8). Keep valid UTF-8 as is; re-decode the rest.
        std::string ToUtf8(const std::string& _Bytes)
        {
            if (_Bytes.empty() || MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, _Bytes.data(),
                                      static_cast<int>(_Bytes.size()), nullptr, 0) > 0)
            {
                return _Bytes;
            }
            const int iwide = MultiByteToWideChar(
                CP_OEMCP, 0, _Bytes.data(), static_cast<int>(_Bytes.size()), nullptr, 0);
            std::wstring wide(static_cast<std::size_t>(iwide), L'\0');
            MultiByteToWideChar(
                CP_OEMCP, 0, _Bytes.data(), static_cast<int>(_Bytes.size()), wide.data(), iwide);
            return Narrow(wide);
        }

        std::string EnvString(const char* _szName)
        {
            const char* szvalue = std::getenv(_szName);
            return szvalue ? szvalue : "";
        }

        // Owns a Win32 HANDLE.
        struct ScopedHandle
        {
            HANDLE m_hHandle = nullptr;

            ScopedHandle() = default;

            ScopedHandle(const ScopedHandle&) = delete;
            ScopedHandle& operator=(const ScopedHandle&) = delete;

            ~ScopedHandle()
            {
                Close();
            }

            void Close()
            {
                if (m_hHandle && m_hHandle != INVALID_HANDLE_VALUE)
                {
                    CloseHandle(m_hHandle);
                }
                m_hHandle = nullptr;
            }
        };

        // An anonymous pipe whose parent end is not inherited by the child.
        bool MakePipe(ScopedHandle& _Read, ScopedHandle& _Write, bool _bParentReads)
        {
            SECURITY_ATTRIBUTES sa = {};
            sa.nLength = sizeof(sa);
            sa.bInheritHandle = TRUE;
            if (!CreatePipe(&_Read.m_hHandle, &_Write.m_hHandle, &sa, 0))
            {
                return false;
            }
            HANDLE hparentEnd = _bParentReads ? _Read.m_hHandle : _Write.m_hHandle;
            return SetHandleInformation(hparentEnd, HANDLE_FLAG_INHERIT, 0) != 0;
        }

        // Read a pipe until the writer closes it.
        std::string DrainPipe(HANDLE _hRead)
        {
            std::string out;
            char szbuf[4096];
            DWORD dwread = 0;
            while (ReadFile(_hRead, szbuf, sizeof(szbuf), &dwread, nullptr) && dwread > 0)
            {
                out.append(szbuf, dwread);
            }
            return out;
        }

    } // namespace

    std::string FindProgram(const std::string& _Name)
    {
        if (_Name.empty())
        {
            return {};
        }

        std::error_code ec;
        const fs::path direct = fs::u8path(_Name);
        if (direct.has_parent_path())
        {
            return fs::exists(direct, ec) ? _Name : std::string();
        }

        const std::wstring wide = Widen(_Name);
        wchar_t szfound[MAX_PATH] = {};
        if (SearchPathW(nullptr, wide.c_str(), L".exe", MAX_PATH, szfound, nullptr) > 0)
        {
            return Narrow(szfound);
        }

        // Git for Windows ships gpg, git-lfs, and ssh tools outside PATH; the
        // OS ships OpenSSH under System32.
        std::vector<fs::path> dirs;
        for (const char* szroot : {"ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"})
        {
            const std::string root = EnvString(szroot);
            if (!root.empty())
            {
                dirs.push_back(fs::u8path(root) / "Git" / "cmd");
                dirs.push_back(fs::u8path(root) / "Git" / "usr" / "bin");
                dirs.push_back(fs::u8path(root) / "Git" / "mingw64" / "bin");
            }
        }
        const std::string localAppData = EnvString("LOCALAPPDATA");
        if (!localAppData.empty())
        {
            dirs.push_back(fs::u8path(localAppData) / "Programs" / "Git" / "cmd");
            dirs.push_back(fs::u8path(localAppData) / "Programs" / "Git" / "usr" / "bin");
            dirs.push_back(fs::u8path(localAppData) / "Programs" / "Git" / "mingw64" / "bin");
        }
        const std::string systemRoot = EnvString("SystemRoot");
        if (!systemRoot.empty())
        {
            dirs.push_back(fs::u8path(systemRoot) / "System32" / "OpenSSH");
        }

        const std::string exeName =
            fs::u8path(_Name).has_extension() ? _Name : _Name + std::string(".exe");
        for (const fs::path& dir : dirs)
        {
            const fs::path candidate = dir / fs::u8path(exeName);
            if (fs::exists(candidate, ec))
            {
                return candidate.u8string();
            }
        }
        return {};
    }

    ProcessResult RunProcess(const std::vector<std::string>& _Args, const std::string& _WorkingDir,
        const std::string& _Input)
    {
        ProcessResult result;
        if (_Args.empty())
        {
            result.m_StartError = "no program given";
            return result;
        }

        std::string program = FindProgram(_Args[0]);
        if (program.empty())
        {
            result.m_StartError = "'" + _Args[0] + "' was not found";
            return result;
        }

        std::string commandLine = QuoteArgument(program);
        for (std::size_t i = 1; i < _Args.size(); ++i)
        {
            commandLine += " " + QuoteArgument(_Args[i]);
        }

        ScopedHandle stdinRead;
        ScopedHandle stdinWrite;
        ScopedHandle stdoutRead;
        ScopedHandle stdoutWrite;
        ScopedHandle stderrRead;
        ScopedHandle stderrWrite;
        if (!MakePipe(stdinRead, stdinWrite, false) || !MakePipe(stdoutRead, stdoutWrite, true) ||
            !MakePipe(stderrRead, stderrWrite, true))
        {
            result.m_StartError = "could not create pipes";
            return result;
        }

        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = stdinRead.m_hHandle;
        si.hStdOutput = stdoutWrite.m_hHandle;
        si.hStdError = stderrWrite.m_hHandle;

        std::wstring cmd = Widen(commandLine);
        std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
        buffer.push_back(L'\0');
        const std::wstring cwd = Widen(_WorkingDir);

        PROCESS_INFORMATION pi = {};
        if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                nullptr, cwd.empty() ? nullptr : cwd.c_str(), &si, &pi))
        {
            result.m_StartError = "could not start '" + program + "'";
            return result;
        }
        ScopedHandle process;
        process.m_hHandle = pi.hProcess;
        CloseHandle(pi.hThread);
        result.m_bStarted = true;

        // The child owns these ends now; closing ours lets EOF arrive.
        stdinRead.Close();
        stdoutWrite.Close();
        stderrWrite.Close();

        // Write stdin and read stderr on helper threads so a chatty child can
        // never deadlock against a full pipe.
        HANDLE hstdinWrite = stdinWrite.m_hHandle;
        std::thread writer(
            [hstdinWrite, &_Input]()
            {
                std::size_t noffset = 0;
                while (noffset < _Input.size())
                {
                    DWORD dwwritten = 0;
                    const DWORD dwchunk =
                        static_cast<DWORD>(std::min<std::size_t>(_Input.size() - noffset, 65536));
                    if (!WriteFile(
                            hstdinWrite, _Input.data() + noffset, dwchunk, &dwwritten, nullptr) ||
                        dwwritten == 0)
                    {
                        break;
                    }
                    noffset += dwwritten;
                }
                CloseHandle(hstdinWrite);
            });
        stdinWrite.m_hHandle = nullptr; // the writer thread closes it

        std::string errors;
        HANDLE hstderr = stderrRead.m_hHandle;
        std::thread errorReader([hstderr, &errors]() { errors = DrainPipe(hstderr); });

        result.m_Output = DrainPipe(stdoutRead.m_hHandle);
        writer.join();
        errorReader.join();
        result.m_Error = errors;

        WaitForSingleObject(process.m_hHandle, INFINITE);
        DWORD dwexit = 0;
        GetExitCodeProcess(process.m_hHandle, &dwexit);
        result.m_iExitCode = static_cast<int>(dwexit);
        return result;
    }

    int RunShellStreaming(const std::string& _CommandLine, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel)
    {
        std::string comspec = EnvString("ComSpec");
        if (comspec.empty())
        {
            comspec = "cmd.exe";
        }
        const std::string commandLine =
            QuoteArgument(comspec) + " /d /s /c \"" + _CommandLine + "\"";

        ScopedHandle outRead;
        ScopedHandle outWrite;
        if (!MakePipe(outRead, outWrite, true))
        {
            _OnOutput("could not create a pipe\n");
            return -1;
        }

        // No stdin: interactive prompts read end-of-file instead of hanging.
        SECURITY_ATTRIBUTES sa = {};
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;
        ScopedHandle nul;
        nul.m_hHandle = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
            OPEN_EXISTING, 0, nullptr);

        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = nul.m_hHandle;
        si.hStdOutput = outWrite.m_hHandle;
        si.hStdError = outWrite.m_hHandle;

        // A job object so cancelling kills the whole tree (cmd and its children).
        ScopedHandle job;
        job.m_hHandle = CreateJobObjectW(nullptr, nullptr);
        if (job.m_hHandle)
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                job.m_hHandle, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
        }

        std::wstring cmd = Widen(commandLine);
        std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
        buffer.push_back(L'\0');
        const std::wstring cwd = Widen(_WorkingDir);

        PROCESS_INFORMATION pi = {};
        if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, TRUE,
                CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, cwd.empty() ? nullptr : cwd.c_str(),
                &si, &pi))
        {
            _OnOutput("could not start the command shell\n");
            return -1;
        }
        ScopedHandle process;
        process.m_hHandle = pi.hProcess;
        if (job.m_hHandle)
        {
            AssignProcessToJobObject(job.m_hHandle, pi.hProcess);
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        outWrite.Close();

        // Poll so cancellation is noticed even while the command is silent.
        // Output is forwarded up to the last line break; a partial line waits
        // for its end (or the end of the command).
        std::string pending;
        bool bcancelled = false;
        char szbuf[4096];
        for (;;)
        {
            DWORD dwavailable = 0;
            if (!PeekNamedPipe(outRead.m_hHandle, nullptr, 0, nullptr, &dwavailable, nullptr))
            {
                break; // writer closed: the command (and its children) are done
            }
            if (dwavailable > 0)
            {
                DWORD dwread = 0;
                if (!ReadFile(outRead.m_hHandle, szbuf, sizeof(szbuf), &dwread, nullptr) ||
                    dwread == 0)
                {
                    break;
                }
                pending.append(szbuf, dwread);
                const std::size_t nlast = pending.find_last_of("\r\n");
                if (nlast != std::string::npos)
                {
                    _OnOutput(ToUtf8(pending.substr(0, nlast + 1)));
                    pending.erase(0, nlast + 1);
                }
                else if (pending.size() > 8192)
                {
                    _OnOutput(ToUtf8(pending));
                    pending.clear();
                }
                continue;
            }
            if (_pCancel && _pCancel->load())
            {
                bcancelled = true;
                if (job.m_hHandle)
                {
                    TerminateJobObject(job.m_hHandle, 1);
                }
                else
                {
                    TerminateProcess(process.m_hHandle, 1);
                }
                break;
            }
            Sleep(15);
        }
        if (!pending.empty())
        {
            _OnOutput(ToUtf8(pending));
        }

        WaitForSingleObject(process.m_hHandle, 5000);
        DWORD dwexit = 0;
        GetExitCodeProcess(process.m_hHandle, &dwexit);
        return bcancelled ? -1 : static_cast<int>(dwexit);
    }

#else

    std::string FindProgram(const std::string&)
    {
        return {};
    }

    ProcessResult RunProcess(
        const std::vector<std::string>&, const std::string&, const std::string&)
    {
        ProcessResult result;
        result.m_StartError = "running programs is not implemented on this platform";
        return result;
    }

    int RunShellStreaming(const std::string&, const std::string&,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>*)
    {
        _OnOutput("the console is not implemented on this platform\n");
        return -1;
    }

#endif

} // namespace gitgud::platform
