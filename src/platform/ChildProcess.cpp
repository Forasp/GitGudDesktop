#include "platform/ChildProcess.h"

#include "app/Profiler.h"

#include "platform/Process.h"
#include "platform/WinSpawn.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <algorithm>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cwctype>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {

        // A line longer than this is delivered in pieces.
        constexpr std::size_t kMaxLine = 64u * 1024u * 1024u;

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

        void CloseOnce(HANDLE& _hHandle)
        {
            if (_hHandle && _hHandle != INVALID_HANDLE_VALUE)
            {
                CloseHandle(_hHandle);
            }
            _hHandle = nullptr;
        }

        // An anonymous pipe whose parent end is not inherited by the child.
        bool MakePipe(HANDLE& _hRead, HANDLE& _hWrite, bool _bParentReads)
        {
            SECURITY_ATTRIBUTES sa = {};
            sa.nLength = sizeof(sa);
            sa.bInheritHandle = TRUE;
            if (!CreatePipe(&_hRead, &_hWrite, &sa, 1u << 16))
            {
                return false;
            }
            HANDLE hparentEnd = _bParentReads ? _hRead : _hWrite;
            return SetHandleInformation(hparentEnd, HANDLE_FLAG_INHERIT, 0) != 0;
        }

        bool EndsWith(std::string _Text, const char* _szSuffix)
        {
            std::transform(_Text.begin(), _Text.end(), _Text.begin(),
                [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
            const std::string suffix = _szSuffix;
            return _Text.size() >= suffix.size() &&
                   _Text.compare(_Text.size() - suffix.size(), suffix.size(), suffix) == 0;
        }

        // Always in quotes (cmd.exe treats & | < > ^ ( ) inside them as
        // text), with the program's own rules for backslashes before the
        // closing quote. The caller has refused embedded quotes.
        std::string QuoteAlways(const std::string& _Arg)
        {
            const std::string quoted = QuoteArgument(_Arg);
            if (!quoted.empty() && quoted.front() == '"')
            {
                return quoted;
            }
            std::size_t ntrailing = 0;
            while (ntrailing < _Arg.size() && _Arg[_Arg.size() - 1 - ntrailing] == '\\')
            {
                ++ntrailing;
            }
            return "\"" + _Arg + std::string(ntrailing, '\\') + "\"";
        }

        struct LessNoCase
        {
            bool operator()(const std::wstring& _A, const std::wstring& _B) const
            {
                return std::lexicographical_compare(_A.begin(), _A.end(), _B.begin(), _B.end(),
                    [](wchar_t _X, wchar_t _Y) { return std::towupper(_X) < std::towupper(_Y); });
            }
        };

        // Our environment with the overrides applied, as a CreateProcess block
        // (sorted, case-insensitive names); empty when there are none.
        std::wstring EnvironmentBlock(const std::vector<std::pair<std::string, std::string>>& _Env)
        {
            if (_Env.empty())
            {
                return {};
            }
            std::map<std::wstring, std::wstring, LessNoCase> merged;
            if (wchar_t* szbase = GetEnvironmentStringsW())
            {
                for (const wchar_t* sz = szbase; *sz;)
                {
                    const std::wstring entry(sz);
                    // Names may start with '=' (the per-drive folders).
                    const std::size_t neq = entry.find(L'=', 1);
                    if (neq != std::wstring::npos)
                    {
                        merged[entry.substr(0, neq)] = entry.substr(neq + 1);
                    }
                    sz += entry.size() + 1;
                }
                FreeEnvironmentStringsW(szbase);
            }
            for (const auto& [name, value] : _Env)
            {
                if (value.empty())
                {
                    merged.erase(Widen(name));
                }
                else
                {
                    merged[Widen(name)] = Widen(value);
                }
            }
            std::wstring block;
            for (const auto& [name, value] : merged)
            {
                block += name + L"=" + value;
                block += L'\0';
            }
            block += L'\0';
            return block;
        }

    } // namespace

    struct ChildProcess::Impl
    {
        HANDLE m_hProcess = nullptr;
        HANDLE m_hJob = nullptr;
        HANDLE m_hStdinWrite = nullptr;
        HANDLE m_hStdoutRead = nullptr;
        HANDLE m_hStderrRead = nullptr;
        unsigned long m_uId = 0;

        OnLine m_OnStdout;
        OnLine m_OnStderr;
        OnExit m_OnExit;

        std::thread m_StdoutThread;
        std::thread m_StderrThread;
        std::thread m_WriterThread;
        std::thread m_WaitThread;

        // Stdin: Write() queues, the writer thread writes, so a child that
        // isn't reading never blocks the caller.
        std::mutex m_WriteMutex;
        std::condition_variable m_WriteReady;
        std::deque<std::string> m_WriteQueue;
        bool m_bStdinClosing = false; // no more writes; close once the queue is written
        bool m_bStdinDead = false;    // a write failed or the process ended

        mutable std::mutex m_StateMutex;
        std::condition_variable m_Exited;
        bool m_bStarted = false;
        bool m_bExited = false;
        int m_iExitCode = -1;

        ~Impl()
        {
            CloseOnce(m_hStdinWrite);
            CloseOnce(m_hStdoutRead);
            CloseOnce(m_hStderrRead);
            CloseOnce(m_hProcess);
            CloseOnce(m_hJob);
        }

        // The object whose thread this is (null on threads that aren't ours).
        static thread_local const Impl* t_pOwner;

        bool OnOwnThread() const
        {
            return t_pOwner == this;
        }

        static void ReadLines(Impl& _Impl, HANDLE _hPipe, const OnLine& _OnLine)
        {
            t_pOwner = &_Impl;
            prof::SetThreadName("child output reader");
            std::string pending;
            char szbuf[16384];
            for (;;)
            {
                DWORD dwread = 0;
                if (!ReadFile(_hPipe, szbuf, sizeof(szbuf), &dwread, nullptr) || dwread == 0)
                {
                    break;
                }
                pending.append(szbuf, dwread);
                std::size_t nstart = 0;
                for (;;)
                {
                    const std::size_t nend = pending.find('\n', nstart);
                    if (nend == std::string::npos)
                    {
                        break;
                    }
                    std::size_t nlength = nend - nstart;
                    if (nlength > 0 && pending[nend - 1] == '\r')
                    {
                        --nlength;
                    }
                    if (_OnLine)
                    {
                        GITGUD_PROFILE_SCOPE("child output line");
                        _OnLine(pending.substr(nstart, nlength));
                    }
                    nstart = nend + 1;
                }
                pending.erase(0, nstart);
                if (pending.size() > kMaxLine)
                {
                    if (_OnLine)
                    {
                        _OnLine(pending);
                    }
                    pending.clear();
                }
            }
            if (!pending.empty() && _OnLine)
            {
                if (pending.back() == '\r')
                {
                    pending.pop_back();
                }
                _OnLine(pending);
            }
        }

        void WriteStdin()
        {
            t_pOwner = this;
            std::unique_lock<std::mutex> lock(m_WriteMutex);
            for (;;)
            {
                m_WriteReady.wait(lock,
                    [this] { return !m_WriteQueue.empty() || m_bStdinClosing || m_bStdinDead; });
                if (m_bStdinDead || m_WriteQueue.empty())
                {
                    break; // closed with everything written, or broken
                }
                const std::string data = std::move(m_WriteQueue.front());
                m_WriteQueue.pop_front();
                lock.unlock();
                bool bok = true;
                std::size_t noffset = 0;
                while (bok && noffset < data.size())
                {
                    const DWORD dwwant =
                        static_cast<DWORD>(std::min<std::size_t>(data.size() - noffset, 1u << 20));
                    DWORD dwwritten = 0;
                    bok = WriteFile(m_hStdinWrite, data.data() + noffset, dwwant, &dwwritten,
                              nullptr) != 0;
                    noffset += dwwritten;
                }
                lock.lock();
                if (!bok)
                {
                    m_bStdinDead = true;
                }
            }
            m_bStdinDead = true;
            m_WriteQueue.clear();
            CloseOnce(m_hStdinWrite);
        }

        void WaitForExit()
        {
            t_pOwner = this;
            WaitForSingleObject(m_hProcess, INFINITE);
            DWORD dwcode = 0;
            GetExitCodeProcess(m_hProcess, &dwcode);
            // Anything it left running would hold the pipes open: end it too.
            if (m_hJob)
            {
                TerminateJobObject(m_hJob, 137);
            }
            m_StdoutThread.join();
            m_StderrThread.join();
            {
                std::lock_guard<std::mutex> lock(m_WriteMutex);
                m_bStdinDead = true;
            }
            m_WriteReady.notify_all();
            // A write in progress fails once the reader has gone; cancel it
            // anyway in case something else still holds the pipe open.
            CancelSynchronousIo(m_WriterThread.native_handle());
            m_WriterThread.join();
            {
                std::lock_guard<std::mutex> lock(m_StateMutex);
                m_iExitCode = static_cast<int>(dwcode);
                m_bExited = true;
            }
            m_Exited.notify_all();
            if (m_OnExit)
            {
                m_OnExit(static_cast<int>(dwcode));
            }
        }
    };

    thread_local const ChildProcess::Impl* ChildProcess::Impl::t_pOwner = nullptr;

    ChildProcess::ChildProcess() : m_pImpl(std::make_shared<Impl>())
    {
    }

    ChildProcess::~ChildProcess()
    {
        Kill();
        if (m_pImpl->m_WaitThread.joinable())
        {
            if (m_pImpl->OnOwnThread())
            {
                // Destroyed from one of its own callbacks, which can't join the
                // threads: the wait thread keeps the state alive and finishes.
                m_pImpl->m_WaitThread.detach();
            }
            else
            {
                m_pImpl->m_WaitThread.join();
            }
        }
    }

    bool ChildProcess::Start(const Options& _Options, OnLine _OnStdout, OnLine _OnStderr,
        OnExit _OnExit, std::string& _Error)
    {
        Impl& impl = *m_pImpl;
        {
            std::lock_guard<std::mutex> lock(impl.m_StateMutex);
            if (impl.m_bStarted)
            {
                _Error = "already started";
                return false;
            }
        }
        if (_Options.m_Args.empty())
        {
            _Error = "no program given";
            return false;
        }

        std::string program = FindProgram(_Options.m_Args[0]);
        for (const char* szext : {".cmd", ".bat"})
        {
            if (program.empty())
            {
                program = FindProgram(_Options.m_Args[0] + szext);
            }
        }
        if (program.empty())
        {
            _Error = "'" + _Options.m_Args[0] + "' was not found";
            return false;
        }

        std::string commandLine;
        if (EndsWith(program, ".cmd") || EndsWith(program, ".bat"))
        {
            // cmd.exe reparses the line. Every argument goes in quotes, where
            // & | < > ^ ( ) are text; refuse what quotes can't protect.
            commandLine = QuoteAlways(program);
            for (std::size_t i = 1; i < _Options.m_Args.size(); ++i)
            {
                if (_Options.m_Args[i].find_first_of("\"%\r\n") != std::string::npos)
                {
                    _Error = "an argument for a batch file contains a character cmd.exe "
                             "would misread: " +
                             _Options.m_Args[i];
                    return false;
                }
                commandLine += " " + QuoteAlways(_Options.m_Args[i]);
            }
            const char* szcomspec = std::getenv("ComSpec");
            commandLine = QuoteArgument(szcomspec && *szcomspec ? szcomspec : "cmd.exe") +
                          " /d /s /c \"" + commandLine + "\"";
        }
        else
        {
            commandLine = QuoteArgument(program);
            for (std::size_t i = 1; i < _Options.m_Args.size(); ++i)
            {
                commandLine += " " + QuoteArgument(_Options.m_Args[i]);
            }
        }

        HANDLE hstdinRead = nullptr;
        HANDLE hstdoutWrite = nullptr;
        HANDLE hstderrWrite = nullptr;
        auto closeChildEnds = [&]
        {
            CloseOnce(hstdinRead);
            CloseOnce(hstdoutWrite);
            CloseOnce(hstderrWrite);
        };
        auto closeAll = [&]
        {
            closeChildEnds();
            CloseOnce(impl.m_hStdinWrite);
            CloseOnce(impl.m_hStdoutRead);
            CloseOnce(impl.m_hStderrRead);
            CloseOnce(impl.m_hJob);
        };
        if (!MakePipe(hstdinRead, impl.m_hStdinWrite, false) ||
            !MakePipe(impl.m_hStdoutRead, hstdoutWrite, true) ||
            !MakePipe(impl.m_hStderrRead, hstderrWrite, true))
        {
            closeAll();
            _Error = "could not create pipes";
            return false;
        }

        impl.m_hJob = CreateJobObjectW(nullptr, nullptr);
        if (impl.m_hJob)
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                impl.m_hJob, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
        }

        std::wstring cmd = Widen(commandLine);
        std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
        buffer.push_back(L'\0');
        const std::wstring cwd = Widen(_Options.m_WorkingDir);
        std::wstring env = EnvironmentBlock(_Options.m_Env);

        PROCESS_INFORMATION pi = {};
        const bool bcreated = SpawnWithStdHandles(buffer.data(),
            CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
            env.empty() ? nullptr : env.data(), cwd.empty() ? nullptr : cwd.c_str(), hstdinRead,
            hstdoutWrite, hstderrWrite, pi);
        const DWORD dwerror = GetLastError();
        closeChildEnds(); // the child has its own copies now
        if (!bcreated)
        {
            closeAll();
            _Error = "could not start '" + program + "' (error " + std::to_string(dwerror) + ")";
            return false;
        }
        // Outside the job, Kill() couldn't reach what it starts: don't run it.
        if (impl.m_hJob && !AssignProcessToJobObject(impl.m_hJob, pi.hProcess))
        {
            const DWORD dwjobError = GetLastError();
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 5000);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            closeAll();
            _Error = "could not start '" + program + "' in a job (error " +
                     std::to_string(dwjobError) + ")";
            return false;
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        impl.m_hProcess = pi.hProcess;
        impl.m_uId = pi.dwProcessId;
        impl.m_OnStdout = std::move(_OnStdout);
        impl.m_OnStderr = std::move(_OnStderr);
        impl.m_OnExit = std::move(_OnExit);
        {
            std::lock_guard<std::mutex> lock(impl.m_StateMutex);
            impl.m_bStarted = true;
        }

        // The wait thread shares the state (it joins the others), so the
        // state outlives this object when a callback destroys it.
        std::shared_ptr<Impl> pimpl = m_pImpl;
        impl.m_StdoutThread =
            std::thread([&impl] { Impl::ReadLines(impl, impl.m_hStdoutRead, impl.m_OnStdout); });
        impl.m_StderrThread =
            std::thread([&impl] { Impl::ReadLines(impl, impl.m_hStderrRead, impl.m_OnStderr); });
        impl.m_WriterThread = std::thread([&impl] { impl.WriteStdin(); });
        impl.m_WaitThread = std::thread([pimpl] { pimpl->WaitForExit(); });
        return true;
    }

    bool ChildProcess::Write(const std::string& _Data)
    {
        if (!Running())
        {
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(m_pImpl->m_WriteMutex);
            if (m_pImpl->m_bStdinClosing || m_pImpl->m_bStdinDead)
            {
                return false;
            }
            m_pImpl->m_WriteQueue.push_back(_Data);
        }
        m_pImpl->m_WriteReady.notify_all();
        return true;
    }

    bool ChildProcess::WriteLine(const std::string& _Line)
    {
        return Write(_Line + "\n");
    }

    void ChildProcess::CloseStdin()
    {
        {
            std::lock_guard<std::mutex> lock(m_pImpl->m_WriteMutex);
            m_pImpl->m_bStdinClosing = true;
        }
        m_pImpl->m_WriteReady.notify_all();
    }

    void ChildProcess::Kill()
    {
        if (!Running())
        {
            return;
        }
        if (m_pImpl->m_hJob)
        {
            TerminateJobObject(m_pImpl->m_hJob, 137);
        }
        else
        {
            TerminateProcess(m_pImpl->m_hProcess, 137);
        }
    }

    bool ChildProcess::Running() const
    {
        std::lock_guard<std::mutex> lock(m_pImpl->m_StateMutex);
        return m_pImpl->m_bStarted && !m_pImpl->m_bExited;
    }

    int ChildProcess::Wait(int _iTimeoutMs)
    {
        std::unique_lock<std::mutex> lock(m_pImpl->m_StateMutex);
        if (!m_pImpl->m_bStarted)
        {
            return -1;
        }
        auto exited = [this]
        {
            return m_pImpl->m_bExited;
        };
        if (m_pImpl->OnOwnThread())
        {
            // A callback can't wait for an exit that waits for the callback.
            return exited() ? m_pImpl->m_iExitCode : -1;
        }
        if (_iTimeoutMs < 0)
        {
            m_pImpl->m_Exited.wait(lock, exited);
        }
        else if (!m_pImpl->m_Exited.wait_for(lock, std::chrono::milliseconds(_iTimeoutMs), exited))
        {
            return -1;
        }
        return m_pImpl->m_iExitCode;
    }

    unsigned long ChildProcess::Id() const
    {
        return m_pImpl->m_uId;
    }

#else

    struct ChildProcess::Impl
    {
    };

    ChildProcess::ChildProcess() : m_pImpl(std::make_shared<Impl>())
    {
    }

    ChildProcess::~ChildProcess() = default;

    bool ChildProcess::Start(const Options&, OnLine, OnLine, OnExit, std::string& _Error)
    {
        _Error = "long-lived child processes are not implemented on this platform yet";
        return false;
    }

    bool ChildProcess::Write(const std::string&)
    {
        return false;
    }

    bool ChildProcess::WriteLine(const std::string&)
    {
        return false;
    }

    void ChildProcess::CloseStdin()
    {
    }

    void ChildProcess::Kill()
    {
    }

    bool ChildProcess::Running() const
    {
        return false;
    }

    int ChildProcess::Wait(int)
    {
        return -1;
    }

    unsigned long ChildProcess::Id() const
    {
        return 0;
    }

#endif

} // namespace gitgud::platform
