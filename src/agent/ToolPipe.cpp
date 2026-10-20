#include "agent/ToolPipe.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace gitgud::agent
{

#if defined(_WIN32)

    namespace
    {

        // A request longer than this is refused (the tools take a few short
        // arguments).
        constexpr std::size_t kMaxRequest = 1024u * 1024u;
        // How long a connected client may take to send its request, and to
        // close after reading the reply.
        constexpr DWORD kClientIdleMs = 30000;

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

        std::string LastError(const char* _szWhat)
        {
            return std::string(_szWhat) + " (error " + std::to_string(GetLastError()) + ")";
        }

        enum class IoResult
        {
            Ok,
            Closed, // the other end went away (or end of data)
            Stopped,
            TimedOut,
            Failed,
        };

        // One overlapped read or write on `_hPipe`, waiting at most `_dwTimeoutMs`
        // and returning early when `_hStop` (may be null) is set.
        IoResult Io(HANDLE _hPipe, bool _bWrite, void* _pBuffer, DWORD _dwSize, DWORD& _dwDone,
            HANDLE _hStop, DWORD _dwTimeoutMs)
        {
            _dwDone = 0;
            OVERLAPPED overlapped = {};
            overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!overlapped.hEvent)
            {
                return IoResult::Failed;
            }
            const BOOL bok = _bWrite ? WriteFile(_hPipe, _pBuffer, _dwSize, nullptr, &overlapped)
                                     : ReadFile(_hPipe, _pBuffer, _dwSize, nullptr, &overlapped);
            IoResult result = IoResult::Ok;
            if (!bok && GetLastError() != ERROR_IO_PENDING)
            {
                const DWORD dwerror = GetLastError();
                result = (dwerror == ERROR_BROKEN_PIPE || dwerror == ERROR_NO_DATA ||
                             dwerror == ERROR_PIPE_NOT_CONNECTED)
                             ? IoResult::Closed
                             : IoResult::Failed;
                CloseHandle(overlapped.hEvent);
                return result;
            }
            HANDLE ahwait[2] = {overlapped.hEvent, _hStop};
            const DWORD dwwait =
                WaitForMultipleObjects(_hStop ? 2 : 1, ahwait, FALSE, _dwTimeoutMs);
            if (dwwait != WAIT_OBJECT_0)
            {
                CancelIoEx(_hPipe, &overlapped);
                result = dwwait == WAIT_OBJECT_0 + 1 ? IoResult::Stopped : IoResult::TimedOut;
            }
            if (!GetOverlappedResult(_hPipe, &overlapped, &_dwDone, TRUE))
            {
                const DWORD dwerror = GetLastError();
                if (result == IoResult::Ok)
                {
                    result = (dwerror == ERROR_BROKEN_PIPE || dwerror == ERROR_PIPE_NOT_CONNECTED)
                                 ? IoResult::Closed
                                 : IoResult::Failed;
                }
            }
            else if (result != IoResult::Ok)
            {
                result = IoResult::Ok; // it finished before the cancel landed
            }
            CloseHandle(overlapped.hEvent);
            if (result == IoResult::Ok && !_bWrite && _dwDone == 0)
            {
                result = IoResult::Closed;
            }
            return result;
        }

        // Read up to a line break (not included); the end of data also ends
        // a line. `_bLimit` refuses a line over kMaxRequest.
        IoResult ReadLine(
            HANDLE _hPipe, HANDLE _hStop, DWORD _dwTimeoutMs, std::string& _Line, bool _bLimit)
        {
            _Line.clear();
            char szbuffer[4096];
            for (;;)
            {
                DWORD dwread = 0;
                const IoResult result =
                    Io(_hPipe, false, szbuffer, sizeof(szbuffer), dwread, _hStop, _dwTimeoutMs);
                if (result != IoResult::Ok)
                {
                    // A last line without a break still counts.
                    return result == IoResult::Closed && !_Line.empty() ? IoResult::Ok : result;
                }
                const std::string piece(szbuffer, dwread);
                const std::size_t nbreak = piece.find('\n');
                _Line += piece.substr(0, nbreak);
                if (nbreak != std::string::npos)
                {
                    break;
                }
                if (_bLimit && _Line.size() > kMaxRequest)
                {
                    return IoResult::Failed;
                }
            }
            if (!_Line.empty() && _Line.back() == '\r')
            {
                _Line.pop_back();
            }
            return IoResult::Ok;
        }

        IoResult WriteAll(
            HANDLE _hPipe, HANDLE _hStop, DWORD _dwTimeoutMs, const std::string& _Data)
        {
            std::size_t ndone = 0;
            while (ndone < _Data.size())
            {
                const DWORD dwchunk =
                    static_cast<DWORD>(std::min<std::size_t>(_Data.size() - ndone, 1u << 20));
                DWORD dwwritten = 0;
                const IoResult result = Io(_hPipe, true, const_cast<char*>(_Data.data() + ndone),
                    dwchunk, dwwritten, _hStop, _dwTimeoutMs);
                if (result != IoResult::Ok)
                {
                    return result;
                }
                ndone += dwwritten;
            }
            return IoResult::Ok;
        }

    } // namespace

    struct ToolPipeServer::Impl
    {
        struct Worker
        {
            std::thread m_Thread;
            std::shared_ptr<std::atomic<bool>> m_pbFinished;
        };

        std::wstring m_Name;
        Handler m_Handler;
        HANDLE m_hStop = nullptr;
        std::thread m_Listener;
        std::mutex m_WorkersMutex;
        std::vector<Worker> m_Workers;
        std::atomic<bool> m_bRunning{false};

        HANDLE NewInstance(bool _bFirst) const
        {
            DWORD dwopen = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
            if (_bFirst)
            {
                dwopen |= FILE_FLAG_FIRST_PIPE_INSTANCE;
            }
            // The default security lets only this user (and administrators)
            // write to it; remote clients are refused.
            return CreateNamedPipeW(m_Name.c_str(), dwopen,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES, 64u * 1024u, 64u * 1024u, 0, nullptr);
        }

        void Serve(HANDLE _hPipe)
        {
            std::string request;
            if (ReadLine(_hPipe, m_hStop, kClientIdleMs, request, true) == IoResult::Ok)
            {
                const std::string reply = m_Handler(request) + "\n";
                if (WriteAll(_hPipe, m_hStop, kClientIdleMs, reply) == IoResult::Ok)
                {
                    // Wait for the client to close its end: disconnecting
                    // first would throw away a reply it hasn't read.
                    char cbyte = 0;
                    DWORD dwread = 0;
                    while (Io(_hPipe, false, &cbyte, 1, dwread, m_hStop, kClientIdleMs) ==
                           IoResult::Ok)
                    {
                    }
                }
            }
            DisconnectNamedPipe(_hPipe);
            CloseHandle(_hPipe);
        }

        void StartWorker(HANDLE _hPipe)
        {
            std::lock_guard<std::mutex> lock(m_WorkersMutex);
            // Join the workers that have finished.
            for (auto it = m_Workers.begin(); it != m_Workers.end();)
            {
                if (it->m_pbFinished->load())
                {
                    it->m_Thread.join();
                    it = m_Workers.erase(it);
                }
                else
                {
                    ++it;
                }
            }
            auto pbfinished = std::make_shared<std::atomic<bool>>(false);
            std::thread worker(
                [this, _hPipe, pbfinished]
                {
                    Serve(_hPipe);
                    pbfinished->store(true);
                });
            m_Workers.push_back({std::move(worker), pbfinished});
        }

        void Listen(HANDLE _hPipe)
        {
            while (_hPipe != INVALID_HANDLE_VALUE)
            {
                OVERLAPPED overlapped = {};
                overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
                bool bconnected = false;
                bool bstop = false;
                if (!overlapped.hEvent)
                {
                    bstop = true;
                }
                else if (ConnectNamedPipe(_hPipe, &overlapped))
                {
                    bconnected = true;
                }
                else if (GetLastError() == ERROR_PIPE_CONNECTED)
                {
                    bconnected = true;
                }
                else if (GetLastError() == ERROR_IO_PENDING)
                {
                    HANDLE ahwait[2] = {overlapped.hEvent, m_hStop};
                    if (WaitForMultipleObjects(2, ahwait, FALSE, INFINITE) != WAIT_OBJECT_0)
                    {
                        CancelIoEx(_hPipe, &overlapped);
                        bstop = true;
                    }
                    DWORD dwdone = 0;
                    bconnected =
                        GetOverlappedResult(_hPipe, &overlapped, &dwdone, TRUE) != 0 && !bstop;
                }
                if (overlapped.hEvent)
                {
                    CloseHandle(overlapped.hEvent);
                }
                if (bconnected)
                {
                    StartWorker(_hPipe);
                }
                else
                {
                    CloseHandle(_hPipe);
                }
                if (bstop || WaitForSingleObject(m_hStop, 0) == WAIT_OBJECT_0)
                {
                    break;
                }
                _hPipe = NewInstance(false);
            }
        }
    };

    ToolPipeServer::ToolPipeServer() : m_pImpl(std::make_unique<Impl>())
    {
    }

    ToolPipeServer::~ToolPipeServer()
    {
        Stop();
    }

    bool ToolPipeServer::Start(const std::string& _Name, Handler _Handler, std::string& _Error)
    {
        if (m_pImpl->m_bRunning)
        {
            _Error = "The tool pipe is already listening";
            return false;
        }
        m_pImpl->m_Name = Widen(_Name);
        m_pImpl->m_Handler = std::move(_Handler);
        HANDLE hpipe = m_pImpl->NewInstance(true);
        if (hpipe == INVALID_HANDLE_VALUE)
        {
            _Error = LastError(("Couldn't create the pipe " + _Name).c_str());
            return false;
        }
        m_pImpl->m_hStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_pImpl->m_hStop)
        {
            _Error = LastError("Couldn't create an event");
            CloseHandle(hpipe);
            return false;
        }
        m_pImpl->m_bRunning = true;
        m_pImpl->m_Listener = std::thread([this, hpipe] { m_pImpl->Listen(hpipe); });
        return true;
    }

    void ToolPipeServer::Stop()
    {
        if (!m_pImpl->m_bRunning.exchange(false))
        {
            return;
        }
        SetEvent(m_pImpl->m_hStop);
        if (m_pImpl->m_Listener.joinable())
        {
            m_pImpl->m_Listener.join();
        }
        std::vector<Impl::Worker> workers;
        {
            std::lock_guard<std::mutex> lock(m_pImpl->m_WorkersMutex);
            workers.swap(m_pImpl->m_Workers);
        }
        for (Impl::Worker& worker : workers)
        {
            worker.m_Thread.join();
        }
        CloseHandle(m_pImpl->m_hStop);
        m_pImpl->m_hStop = nullptr;
    }

    bool ToolPipeServer::Running() const
    {
        return m_pImpl->m_bRunning;
    }

    bool CallToolPipe(const std::string& _Name, const std::string& _Request, int _iTimeoutMs,
        std::string& _Reply, std::string& _Error)
    {
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::milliseconds(_iTimeoutMs);
        auto remaining = [&deadline]() -> DWORD
        {
            const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now());
            return left.count() > 0 ? static_cast<DWORD>(left.count()) : 0;
        };

        const std::wstring name = Widen(_Name);
        HANDLE hpipe = INVALID_HANDLE_VALUE;
        for (;;)
        {
            hpipe = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
            if (hpipe != INVALID_HANDLE_VALUE)
            {
                break;
            }
            const DWORD dwerror = GetLastError();
            if (dwerror != ERROR_PIPE_BUSY || remaining() == 0)
            {
                _Error = dwerror == ERROR_FILE_NOT_FOUND
                             ? "Nothing is listening on " + _Name
                             : LastError(("Couldn't connect to " + _Name).c_str());
                return false;
            }
            WaitNamedPipeW(name.c_str(), std::min<DWORD>(remaining(), 1000));
        }

        IoResult result = WriteAll(hpipe, nullptr, remaining(), _Request + "\n");
        if (result == IoResult::Ok)
        {
            result = ReadLine(hpipe, nullptr, remaining(), _Reply, false);
        }
        CloseHandle(hpipe);
        if (result == IoResult::Ok)
        {
            return true;
        }
        _Error = result == IoResult::TimedOut ? "The app didn't answer in time"
                 : result == IoResult::Closed ? "The app closed the connection without answering"
                                              : "The connection to the app failed";
        return false;
    }

#else

    struct ToolPipeServer::Impl
    {
    };

    ToolPipeServer::ToolPipeServer() : m_pImpl(std::make_unique<Impl>())
    {
    }

    ToolPipeServer::~ToolPipeServer() = default;

    bool ToolPipeServer::Start(const std::string&, Handler, std::string& _Error)
    {
        _Error = "The tool pipe isn't implemented on this platform yet";
        return false;
    }

    void ToolPipeServer::Stop()
    {
    }

    bool ToolPipeServer::Running() const
    {
        return false;
    }

    bool CallToolPipe(
        const std::string&, const std::string&, int, std::string&, std::string& _Error)
    {
        _Error = "The tool pipe isn't implemented on this platform yet";
        return false;
    }

#endif

} // namespace gitgud::agent
