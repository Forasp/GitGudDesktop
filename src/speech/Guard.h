#pragma once

// -----------------------------------------------------------------------------
// Guard: how the speech engine survives its libraries.
//
//   Guarded(fn)   runs fn and reports how it ended: normally; with a C++
//                 exception (ONNX Runtime throws them through the sherpa-onnx
//                 C API for a corrupt model, out of memory, bad input: the
//                 call failed, the engine is fine); or with a structured
//                 exception (an access violation inside the libraries: the
//                 process is alive but the engine can't be trusted again).
//                 On other systems only C++ exceptions are caught.
//
//   CrashMarker   a few bytes in a memory-mapped file naming the call in
//                 progress. The libraries can end the process outright
//                 (_Exit, abort) on some bad inputs; the system keeps the
//                 page when that happens, so on the next start the marker
//                 still names the call, and voice can say what happened.
//
//   Watchdog      the time each call may take; a call past its limit marks
//                 the engine as hung (it can't be stopped safely: its thread
//                 is left to finish or not).
// -----------------------------------------------------------------------------

#include <atomic>
#include <chrono>
#include <functional>
#include <mutex>
#include <string>

namespace gitgud::speech
{

    enum class GuardEnd
    {
        Normal,
        Exception, // a C++ exception: the call failed, the engine is usable
        Fault,     // a structured exception: never call the engine again
    };

    struct GuardResult
    {
        GuardEnd m_eEnd = GuardEnd::Normal;
        std::string m_Detail; // the exception's message, or the fault's code
        unsigned long m_uCode = 0;

        bool Ok() const
        {
            return m_eEnd == GuardEnd::Normal;
        }
    };

    GuardResult Guarded(const std::function<void()>& _Fn);

    class CrashMarker
    {
      public:
        CrashMarker() = default;
        ~CrashMarker();
        CrashMarker(const CrashMarker&) = delete;
        CrashMarker& operator=(const CrashMarker&) = delete;

        // Map the marker file at `_Path` (made if missing; its folder too).
        bool Open(const std::string& _Path);
        // Name the call in progress / clear it. Cheap: a memory write.
        void Set(const char* _szCall);
        void Clear();

        // What the marker at `_Path` names ("" when no call was in progress),
        // and clear it.
        static std::string TakeLast(const std::string& _Path);

      private:
        void* m_hFile = nullptr;
        void* m_hMapping = nullptr;
        char* m_pView = nullptr;
    };

    // The call the engine's thread is in, and how long it may take.
    class Watchdog
    {
      public:
        using Clock = std::chrono::steady_clock;

        void Begin(const char* _szCall, std::chrono::milliseconds _Limit);
        void End();

        // The call that has run past its limit (once: it is then marked
        // hung), or "".
        std::string Overdue(Clock::time_point _Now);

        bool Hung() const
        {
            return m_bHung;
        }

      private:
        std::mutex m_Mutex;
        const char* m_szCall = nullptr;
        Clock::time_point m_Start;
        std::chrono::milliseconds m_Limit{0};
        std::atomic<bool> m_bHung{false};
    };

} // namespace gitgud::speech
