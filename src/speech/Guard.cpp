#include "speech/Guard.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>

namespace gitgud::speech
{

    namespace fs = std::filesystem;

    namespace
    {

        constexpr std::size_t kMarkerBytes = 128;

        struct CallState
        {
            const std::function<void()>* m_pFn = nullptr;
            GuardResult* m_pResult = nullptr;
        };

        // The C++ half: exceptions from the call become a result.
        void RunCatching(CallState* _pState)
        {
            try
            {
                (*_pState->m_pFn)();
            }
            catch (const std::exception& e)
            {
                _pState->m_pResult->m_eEnd = GuardEnd::Exception;
                _pState->m_pResult->m_Detail = e.what();
            }
            catch (...)
            {
                _pState->m_pResult->m_eEnd = GuardEnd::Exception;
                _pState->m_pResult->m_Detail = "an unknown exception";
            }
        }

#if defined(_WIN32)
        constexpr DWORD kCppException = 0xE06D7363;

        int Filter(DWORD _dwCode, unsigned long* _pCode)
        {
            if (_dwCode == kCppException)
            {
                return EXCEPTION_CONTINUE_SEARCH; // RunCatching's
            }
            *_pCode = _dwCode;
            return EXCEPTION_EXECUTE_HANDLER;
        }

        // The structured half: no C++ objects with destructors may live here
        // (MSVC refuses __try in such a function).
        bool RunShielded(CallState* _pState, unsigned long* _pCode)
        {
            __try
            {
                RunCatching(_pState);
                return true;
            }
            __except (Filter(GetExceptionCode(), _pCode))
            {
                return false;
            }
        }
#endif

    } // namespace

    GuardResult Guarded(const std::function<void()>& _Fn)
    {
        GuardResult result;
        CallState state{&_Fn, &result};
#if defined(_WIN32)
        unsigned long ucode = 0;
        if (!RunShielded(&state, &ucode))
        {
            result.m_eEnd = GuardEnd::Fault;
            result.m_uCode = ucode;
            char abuf[32];
            std::snprintf(abuf, sizeof(abuf), "0x%08lX", ucode);
            result.m_Detail = std::string("exception ") + abuf;
        }
#else
        RunCatching(&state);
#endif
        return result;
    }

    // ---- CrashMarker ---------------------------------------------------------

    CrashMarker::~CrashMarker()
    {
#if defined(_WIN32)
        if (m_pView)
        {
            UnmapViewOfFile(m_pView);
        }
        if (m_hMapping)
        {
            CloseHandle(m_hMapping);
        }
        if (m_hFile)
        {
            CloseHandle(m_hFile);
        }
#endif
    }

    bool CrashMarker::Open(const std::string& _Path)
    {
        std::error_code ec;
        fs::create_directories(fs::u8path(_Path).parent_path(), ec);
#if defined(_WIN32)
        HANDLE hfile = CreateFileW(fs::u8path(_Path).c_str(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
            nullptr);
        if (hfile == INVALID_HANDLE_VALUE)
        {
            return false;
        }
        HANDLE hmap = CreateFileMappingW(hfile, nullptr, PAGE_READWRITE, 0, kMarkerBytes, nullptr);
        if (!hmap)
        {
            CloseHandle(hfile);
            return false;
        }
        void* pview = MapViewOfFile(hmap, FILE_MAP_WRITE, 0, 0, kMarkerBytes);
        if (!pview)
        {
            CloseHandle(hmap);
            CloseHandle(hfile);
            return false;
        }
        m_hFile = hfile;
        m_hMapping = hmap;
        m_pView = static_cast<char*>(pview);
        Clear();
        return true;
#else
        (void)_Path;
        return false;
#endif
    }

    void CrashMarker::Set(const char* _szCall)
    {
        if (!m_pView || !_szCall)
        {
            return;
        }
        const std::size_t nlength = std::min(std::strlen(_szCall), kMarkerBytes - 1);
        std::memcpy(m_pView, _szCall, nlength);
        m_pView[nlength] = '\0';
    }

    void CrashMarker::Clear()
    {
        if (m_pView)
        {
            m_pView[0] = '\0';
        }
    }

    std::string CrashMarker::TakeLast(const std::string& _Path)
    {
        std::string content;
        {
            std::ifstream in(fs::u8path(_Path), std::ios::binary);
            char abuf[kMarkerBytes] = {};
            in.read(abuf, kMarkerBytes);
            content.assign(
                abuf, std::strlen(abuf) < kMarkerBytes ? std::strlen(abuf) : kMarkerBytes);
        }
        if (!content.empty())
        {
            std::ofstream out(fs::u8path(_Path), std::ios::binary | std::ios::trunc);
            const std::string zeros(kMarkerBytes, '\0');
            out.write(zeros.data(), static_cast<std::streamsize>(zeros.size()));
        }
        return content;
    }

    // ---- Watchdog ------------------------------------------------------------

    void Watchdog::Begin(const char* _szCall, std::chrono::milliseconds _Limit)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_szCall = _szCall;
        m_Start = Clock::now();
        m_Limit = _Limit;
    }

    void Watchdog::End()
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_szCall = nullptr;
    }

    std::string Watchdog::Overdue(Clock::time_point _Now)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (!m_szCall || m_bHung || _Now - m_Start < m_Limit)
        {
            return {};
        }
        m_bHung = true;
        return m_szCall;
    }

} // namespace gitgud::speech
