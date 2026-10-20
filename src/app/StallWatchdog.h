#pragma once

// -----------------------------------------------------------------------------
// StallWatchdog: notices when the UI thread stays busy too long and writes
// down what it was doing.
//
// The UI thread marks each main-loop pass busy (UiBusy) and its wait for
// input idle (UiIdle). A watchdog thread checks every few milliseconds; once
// a pass has run past the threshold it samples the UI thread until the pass
// ends: its native stack (the thread is suspended for a moment), its open
// profiler zones (handlers, timers, git, files...) and a Lua traceback (the
// Lua engine's count hook answers RequestLuaTrace on the UI thread). Each
// stall goes to the perf log with the stack it started in and the functions
// most of its samples were in; a long one is written while it lasts too, so
// a freeze that ends in a kill still leaves its record.
//
// It also samples the process's memory every second (into a capture's
// counters, and every five minutes into the log), with the main window's
// frames since the last line: how many were presented, how many of those
// failed, and how long ago the last one was. A window that looks frozen
// while its frames go on shows there as frames still counted.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <string>

namespace gitgud::prof
{
    struct WatchdogOptions
    {
        int m_iThresholdMs = 200; // 0: no stall reports
        std::string m_LogPath;    // the perf log (appended)
    };

    // Watch the calling thread (the UI thread).
    void StartWatchdog(const WatchdogOptions& _Options);
    void StopWatchdog();
    void SetStallThreshold(int _iMs);
    int StallThreshold();

    // The UI thread's pass begins / it goes back to waiting.
    void UiBusy();
    void UiIdle();

    // The Lua heap's size, set by the UI thread (kB), for the memory samples.
    void SetLuaMemoryKb(double _fKb);

    // A frame of the main window was presented (failed: the swap said so).
    void CountFrame(bool _bFailed);

    // Lua's side: the count hook asks whether a traceback is wanted, and
    // hands one over (on the UI thread, while the stall goes on).
    bool LuaTraceWanted();
    void DeliverLuaTrace(const std::string& _Trace);
    // Called on the watchdog thread when it wants a traceback: installs the
    // count hook (lua_sethook may be called from another thread).
    using LuaTraceRequest = void (*)();
    void SetLuaTraceRequest(LuaTraceRequest _pfnRequest);

    // Stalls reported since start (for the tests and the status line).
    int StallCount();
    // The text of the last finished stall report.
    std::string LastStallReport();

    // Private memory of the process in MB (0 where unknown).
    double ProcessPrivateMb();

} // namespace gitgud::prof
