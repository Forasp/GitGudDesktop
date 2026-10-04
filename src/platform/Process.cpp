#include "platform/Process.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>
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

    // Start a full command line with no stdin, stream its merged
    // stdout/stderr to `_OnOutput`, and kill its whole tree on cancel.
    // Returns the exit code, or -1 when it couldn't start or was cancelled.
    static int StreamCommandLine(const std::string& _CommandLine, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel,
        const std::string& _StartError)
    {
        const std::string& commandLine = _CommandLine;

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
            _OnOutput(_StartError);
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
        return StreamCommandLine(
            commandLine, _WorkingDir, _OnOutput, _pCancel, "could not start the command shell\n");
    }

    int RunProcessStreaming(const std::vector<std::string>& _Args, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel)
    {
        const std::string program = _Args.empty() ? std::string() : FindProgram(_Args[0]);
        if (program.empty())
        {
            _OnOutput(_Args.empty() ? std::string("no program given\n")
                                    : "'" + _Args[0] + "' was not found\n");
            return -1;
        }

        std::string commandLine = QuoteArgument(program);
        for (std::size_t i = 1; i < _Args.size(); ++i)
        {
            commandLine += " " + QuoteArgument(_Args[i]);
        }
        return StreamCommandLine(
            commandLine, _WorkingDir, _OnOutput, _pCancel, "could not start '" + program + "'\n");
    }

#else

    namespace
    {

        // Owns a file descriptor.
        struct ScopedFd
        {
            int m_iFd = -1;

            ScopedFd() = default;

            ScopedFd(const ScopedFd&) = delete;
            ScopedFd& operator=(const ScopedFd&) = delete;

            ~ScopedFd()
            {
                Close();
            }

            void Close()
            {
                if (m_iFd >= 0)
                {
                    close(m_iFd);
                }
                m_iFd = -1;
            }
        };

        // A pipe whose ends are closed in the child once it execs; the child
        // gets its own copies through dup2.
        bool MakePipe(ScopedFd& _Read, ScopedFd& _Write)
        {
            int fds[2];
#if defined(__linux__)
            if (pipe2(fds, O_CLOEXEC) != 0)
            {
                return false;
            }
#else
            if (pipe(fds) != 0)
            {
                return false;
            }
            fcntl(fds[0], F_SETFD, FD_CLOEXEC);
            fcntl(fds[1], F_SETFD, FD_CLOEXEC);
#endif
            _Read.m_iFd = fds[0];
            _Write.m_iFd = fds[1];
            return true;
        }

        // Read a pipe until the writer closes it.
        std::string DrainPipe(int _iFd)
        {
            std::string out;
            char szbuf[4096];
            for (;;)
            {
                const ssize_t nread = read(_iFd, szbuf, sizeof(szbuf));
                if (nread > 0)
                {
                    out.append(szbuf, static_cast<std::size_t>(nread));
                }
                else if (nread < 0 && errno == EINTR)
                {
                    continue;
                }
                else
                {
                    break;
                }
            }
            return out;
        }

        // Wait for a child and turn its status into an exit code (128 + signal
        // when it was killed, like a shell reports it).
        int WaitExitCode(pid_t _Pid)
        {
            int istatus = 0;
            while (waitpid(_Pid, &istatus, 0) < 0)
            {
                if (errno != EINTR)
                {
                    return -1;
                }
            }
            if (WIFEXITED(istatus))
            {
                return WEXITSTATUS(istatus);
            }
            if (WIFSIGNALED(istatus))
            {
                return 128 + WTERMSIG(istatus);
            }
            return -1;
        }

        // argv for execv, pointing into `_Args` (which must outlive it).
        std::vector<char*> MakeArgv(const std::string& _Program, const std::vector<std::string>& _Args)
        {
            std::vector<char*> argv;
            argv.push_back(const_cast<char*>(_Program.c_str()));
            for (std::size_t i = 1; i < _Args.size(); ++i)
            {
                argv.push_back(const_cast<char*>(_Args[i].c_str()));
            }
            argv.push_back(nullptr);
            return argv;
        }

        bool IsExecutable(const fs::path& _Path)
        {
            std::error_code ec;
            return fs::is_regular_file(_Path, ec) && access(_Path.c_str(), X_OK) == 0;
        }

        // Fork and exec `_Argv[0]` (a full path) in `_WorkingDir`. The child's
        // stdin/stdout/stderr come from the given descriptors (-1: /dev/null).
        // `_bNewGroup` puts it in its own process group so the whole tree can
        // be killed. Only async-signal-safe calls happen after fork.
        pid_t StartChild(const std::vector<char*>& _Argv, const std::string& _WorkingDir, int _iIn,
            int _iOut, int _iErr, bool _bNewGroup)
        {
            const pid_t pid = fork();
            if (pid != 0)
            {
                return pid; // parent, or -1
            }

            if (_bNewGroup)
            {
                setpgid(0, 0);
            }
            const int inull = open("/dev/null", O_RDWR);
            dup2(_iIn >= 0 ? _iIn : inull, STDIN_FILENO);
            dup2(_iOut >= 0 ? _iOut : inull, STDOUT_FILENO);
            dup2(_iErr >= 0 ? _iErr : inull, STDERR_FILENO);
            if (!_WorkingDir.empty() && chdir(_WorkingDir.c_str()) != 0)
            {
                _exit(127);
            }
            execv(_Argv[0], _Argv.data());
            _exit(127);
        }

    } // namespace

    std::string FindProgram(const std::string& _Name)
    {
        if (_Name.empty())
        {
            return {};
        }

        const fs::path direct = fs::u8path(_Name);
        if (direct.has_parent_path())
        {
            return IsExecutable(direct) ? _Name : std::string();
        }

        std::vector<fs::path> dirs;
        if (const char* szpath = std::getenv("PATH"))
        {
            const std::string path = szpath;
            std::size_t nstart = 0;
            while (nstart <= path.size())
            {
                const std::size_t nend = std::min(path.find(':', nstart), path.size());
                if (nend > nstart)
                {
                    dirs.push_back(fs::u8path(path.substr(nstart, nend - nstart)));
                }
                nstart = nend + 1;
            }
        }
        // Apps started from a desktop launcher can get a minimal PATH.
        for (const char* szdir : {"/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"})
        {
            dirs.push_back(szdir);
        }

        for (const fs::path& dir : dirs)
        {
            const fs::path candidate = dir / direct;
            if (IsExecutable(candidate))
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

        const std::string program = FindProgram(_Args[0]);
        if (program.empty())
        {
            result.m_StartError = "'" + _Args[0] + "' was not found";
            return result;
        }

        ScopedFd stdinRead;
        ScopedFd stdinWrite;
        ScopedFd stdoutRead;
        ScopedFd stdoutWrite;
        ScopedFd stderrRead;
        ScopedFd stderrWrite;
        if (!MakePipe(stdinRead, stdinWrite) || !MakePipe(stdoutRead, stdoutWrite) ||
            !MakePipe(stderrRead, stderrWrite))
        {
            result.m_StartError = "could not create pipes";
            return result;
        }

        const std::vector<char*> argv = MakeArgv(program, _Args);
        const pid_t pid = StartChild(argv, _WorkingDir, stdinRead.m_iFd, stdoutWrite.m_iFd,
            stderrWrite.m_iFd, false);
        if (pid < 0)
        {
            result.m_StartError = "could not start '" + program + "'";
            return result;
        }
        result.m_bStarted = true;

        // The child owns these ends now; closing ours lets EOF arrive.
        stdinRead.Close();
        stdoutWrite.Close();
        stderrWrite.Close();

        // Write stdin and read stderr on helper threads so a chatty child can
        // never deadlock against a full pipe. SIGPIPE is blocked on the writer
        // so a child that exits early only makes write() fail.
        const int istdinWrite = stdinWrite.m_iFd;
        stdinWrite.m_iFd = -1; // the writer thread closes it
        std::thread writer(
            [istdinWrite, &_Input]()
            {
                sigset_t set;
                sigemptyset(&set);
                sigaddset(&set, SIGPIPE);
                pthread_sigmask(SIG_BLOCK, &set, nullptr);
                std::size_t noffset = 0;
                while (noffset < _Input.size())
                {
                    const ssize_t nwritten =
                        write(istdinWrite, _Input.data() + noffset, _Input.size() - noffset);
                    if (nwritten < 0 && errno == EINTR)
                    {
                        continue;
                    }
                    if (nwritten <= 0)
                    {
                        break;
                    }
                    noffset += static_cast<std::size_t>(nwritten);
                }
                close(istdinWrite);
            });

        std::string errors;
        const int istderr = stderrRead.m_iFd;
        std::thread errorReader([istderr, &errors]() { errors = DrainPipe(istderr); });

        result.m_Output = DrainPipe(stdoutRead.m_iFd);
        writer.join();
        errorReader.join();
        result.m_Error = errors;
        result.m_iExitCode = WaitExitCode(pid);
        if (result.m_iExitCode == 127 && result.m_Output.empty() && result.m_Error.empty())
        {
            result.m_Error = "could not start '" + program + "'";
        }
        return result;
    }

    // Start a program with no stdin, stream its merged stdout/stderr to
    // `_OnOutput`, and kill its whole process group on cancel. Returns the
    // exit code, or -1 when it couldn't start or was cancelled.
    static int StreamProgram(const std::string& _Program, const std::vector<std::string>& _Args,
        const std::string& _WorkingDir, const std::function<void(const std::string&)>& _OnOutput,
        std::atomic<bool>* _pCancel, const std::string& _StartError)
    {
        ScopedFd outRead;
        ScopedFd outWrite;
        if (!MakePipe(outRead, outWrite))
        {
            _OnOutput("could not create a pipe\n");
            return -1;
        }

        const std::vector<char*> argv = MakeArgv(_Program, _Args);
        const pid_t pid = StartChild(argv, _WorkingDir, -1, outWrite.m_iFd, outWrite.m_iFd, true);
        if (pid < 0)
        {
            _OnOutput(_StartError);
            return -1;
        }
        outWrite.Close();

        // Poll so cancellation is noticed even while the command is silent.
        // Output is forwarded up to the last line break; a partial line waits
        // for its end (or the end of the command).
        std::string pending;
        bool bcancelled = false;
        char szbuf[4096];
        for (;;)
        {
            if (_pCancel && _pCancel->load())
            {
                bcancelled = true;
                kill(-pid, SIGKILL);
                break;
            }
            pollfd pfd = {outRead.m_iFd, POLLIN, 0};
            const int iready = poll(&pfd, 1, 15);
            if (iready < 0 && errno != EINTR)
            {
                break;
            }
            if (iready <= 0)
            {
                continue;
            }
            const ssize_t nread = read(outRead.m_iFd, szbuf, sizeof(szbuf));
            if (nread < 0 && errno == EINTR)
            {
                continue;
            }
            if (nread <= 0)
            {
                break; // writer closed: the command (and its children) are done
            }
            pending.append(szbuf, static_cast<std::size_t>(nread));
            const std::size_t nlast = pending.find_last_of("\r\n");
            if (nlast != std::string::npos)
            {
                _OnOutput(pending.substr(0, nlast + 1));
                pending.erase(0, nlast + 1);
            }
            else if (pending.size() > 8192)
            {
                _OnOutput(pending);
                pending.clear();
            }
        }
        if (!pending.empty())
        {
            _OnOutput(pending);
        }

        const int iexit = WaitExitCode(pid);
        return bcancelled ? -1 : iexit;
    }

    int RunShellStreaming(const std::string& _CommandLine, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel)
    {
        return StreamProgram("/bin/sh", {"sh", "-c", _CommandLine}, _WorkingDir, _OnOutput,
            _pCancel, "could not start the command shell\n");
    }

    int RunProcessStreaming(const std::vector<std::string>& _Args, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel)
    {
        const std::string program = _Args.empty() ? std::string() : FindProgram(_Args[0]);
        if (program.empty())
        {
            _OnOutput(_Args.empty() ? std::string("no program given\n")
                                    : "'" + _Args[0] + "' was not found\n");
            return -1;
        }
        return StreamProgram(
            program, _Args, _WorkingDir, _OnOutput, _pCancel, "could not start '" + program + "'\n");
    }

#endif

} // namespace gitgud::platform
