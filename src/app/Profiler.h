#pragma once

// -----------------------------------------------------------------------------
// Profiler: where the app's time goes, on every thread.
//
// Zones are RAII scopes, opened with GITGUD_PROFILE_SCOPE("name") or
// GITGUD_PROFILE_FUNCTION(). Lua functions become zones through a call hook
// (LuaEngine), and a GITGUD_PROFILE_INSTRUMENT build turns every C++ function
// of the app into one through the compiler (ProfilerInstrument.cpp).
//
// Zones cost almost nothing while no capture runs: one relaxed atomic load,
// plus a push on the thread's activity stack (what the stall watchdog reports
// when the UI thread blocks). During a capture every zone is recorded with its
// start and end, and folded into a per-thread call tree; StopCapture() writes
//   trace.json   Chrome trace format (chrome://tracing, ui.perfetto.dev)
//   flame.svg    flame graph of the call tree (any browser; click to zoom)
//   folded.txt   folded stacks, for other flame graph tools
//   report.txt   inclusive and exclusive times, counts, callers and callees,
//                frame times and the slowest frames, memory over time
// into a profile-<time> folder.
// -----------------------------------------------------------------------------

#include <atomic>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace gitgud::prof
{
    using ZoneId = std::uint32_t;
    constexpr ZoneId kNoZone = 0;

    // A zone's name, interned once. Thread-safe.
    ZoneId Intern(std::string_view _Name);
    // A zone named by a code address (an instrumented function); the name is
    // looked up in the program's symbols when a report is written.
    ZoneId InternAddress(std::uintptr_t _Address);
    std::string ZoneName(ZoneId _Id);
    // Give a zone a better name found later (a Lua function first seen
    // called without one).
    void RenameZone(ZoneId _Id, const std::string& _Name);

    // One source site of a zone; the macros keep one per call site.
    struct Site
    {
        const char* m_szName;
        const char* m_szFile;
        int m_iLine;
        std::atomic<ZoneId> m_Id{kNoZone};
        ZoneId Id();
    };

    namespace detail
    {
        extern std::atomic<bool> g_bCapturing;
    }

    inline bool Capturing()
    {
        return detail::g_bCapturing.load(std::memory_order_relaxed);
    }

    // True while the profiler's own code runs on the calling thread (or a
    // GITGUD_PROFILE_INSTRUMENT hook does): the hooks do nothing then. The
    // template code the profiler calls can be another file's instrumented
    // copy, whose hook would come back in mid-change or take a lock the
    // thread already holds.
    bool& HooksOff();

    // Open and close a zone on the calling thread. Every Begin needs its End,
    // in order.
    void Begin(ZoneId _Id);
    void End();

    // Open zones of the calling thread (for unwinding after a Lua error).
    int Depth();
    void EndTo(int _iDepth);

    class Scope
    {
      public:
        explicit Scope(Site& _Site)
        {
            Begin(_Site.Id());
        }
        explicit Scope(ZoneId _Id)
        {
            Begin(_Id);
        }
        ~Scope()
        {
            End();
        }
        Scope(const Scope&) = delete;
        Scope& operator=(const Scope&) = delete;
    };

    // Name the calling thread in reports ("UI", "git worker", ...).
    void SetThreadName(const std::string& _Name);

    // A value over time (memory, counts), kept in a capture.
    void Counter(const char* _szName, double _fValue);

    // --- Capture ----------------------------------------------------------
    struct CaptureOptions
    {
        // Events kept for the timeline; the call tree is always complete.
        // Past this many, only events of a millisecond or more are kept.
        std::size_t m_uiMaxEvents = 30'000'000;
        // Lua functions are zones (the call hook). Off: only handlers and
        // timers as a whole.
        bool m_bLuaCalls = true;
    };

    bool StartCapture(const CaptureOptions& _Options = {});
    // Stop and write the reports into a new folder under _Directory. Returns
    // that folder ("" when no capture was running or it couldn't be written).
    std::string StopCapture(const std::string& _Directory);
    bool LuaCallsWanted();
    // Seconds since the capture started (0 when none runs).
    double CaptureSeconds();

    // Asked from anywhere (a script, the hotkey); the main loop starts or
    // stops the capture between frames.
    enum class CaptureRequest
    {
        None,
        Start,
        Stop,
        Toggle
    };
    void RequestCapture(CaptureRequest _Request);
    CaptureRequest TakeCaptureRequest();
    // The folder the last capture was written to ("" until one is).
    void SetLastCaptureFolder(const std::string& _Folder);
    std::string LastCaptureFolder();

    // --- Activity (for the stall watchdog) --------------------------------
    // What a thread is in right now, outermost first, read from another
    // thread while this one is suspended. Bounded depth; deeper zones are
    // counted but not kept.
    struct Activity
    {
        static constexpr int kMax = 96;
        ZoneId m_aZones[kMax] = {};
        std::atomic<int> m_iDepth{0};
    };
    Activity* ThreadActivity(); // the calling thread's

    // --- Report pieces (exposed for tests) ---------------------------------
    struct ZoneStats
    {
        ZoneId m_Id = kNoZone;
        std::string m_Name;
        std::uint64_t m_uiCalls = 0;
        double m_fInclusiveMs = 0.0; // recursion counted once
        double m_fExclusiveMs = 0.0;
        double m_fMaxMs = 0.0;
    };
    // The finished capture's zones, worst exclusive time first (valid after
    // StopCapture until the next capture starts).
    std::vector<ZoneStats> LastCaptureStats();

    // Look up a code address in the program's symbols: "function (file:line)".
    std::string Symbolize(std::uintptr_t _Address, bool _bWithLine = true);

} // namespace gitgud::prof

#define GITGUD_PROF_CAT2(a, b) a##b
#define GITGUD_PROF_CAT(a, b) GITGUD_PROF_CAT2(a, b)
#define GITGUD_PROFILE_SCOPE(name)                                                                 \
    static ::gitgud::prof::Site GITGUD_PROF_CAT(gitgudProfSite, __LINE__){name, __FILE__, __LINE__}; \
    ::gitgud::prof::Scope GITGUD_PROF_CAT(gitgudProfScope, __LINE__)                               \
    {                                                                                              \
        GITGUD_PROF_CAT(gitgudProfSite, __LINE__)                                                  \
    }
#define GITGUD_PROFILE_FUNCTION() GITGUD_PROFILE_SCOPE(__FUNCTION__)
