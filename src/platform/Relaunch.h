#pragma once

// -----------------------------------------------------------------------------
// Relaunch: start this program again the way it was started, for a restart
// (gitgud.restartApp). The new copy gets the same executable, arguments,
// working folder and environment (so the same APPDATA, LOCALAPPDATA and
// data), plus GITGUD_RELAUNCH_WAIT=<this process's id>: first thing in
// main it waits for this copy to exit (WaitForEarlierCopy), so it never
// meets this one's voice engine, conversations or files still in use.
// Windows, Linux and macOS.
// -----------------------------------------------------------------------------

#include <string>

namespace gitgud::platform
{

    // The variable a relaunched copy finds the earlier copy's process id in.
    constexpr const char* kRelaunchWaitVariable = "GITGUD_RELAUNCH_WAIT";

    // Remember how this copy was started: its arguments and working folder
    // (call at the start of main, before anything changes the folder).
    void RememberLaunch(int _iArgc, char* _aSzArgv[]);

    // Start the new copy, detached; it waits for this one to exit. The
    // caller then closes this copy the usual way. False with `_Error` when
    // it couldn't be started.
    bool StartRelaunch(std::string& _Error);

    // In a copy started by StartRelaunch: wait for the earlier copy to exit,
    // at most `_iTimeoutMs`, and take the variable out of the environment
    // (the copy's own children and its next restart don't see it). Nothing
    // in a copy started any other way. False when it gave up waiting.
    bool WaitForEarlierCopy(int _iTimeoutMs);

    // Wait for process `_uPid` to exit, at most `_iTimeoutMs`: true once
    // it's gone (or was never there). On Windows, a process started after
    // this one has only reused the id and isn't waited for.
    bool WaitForProcessExit(unsigned long _uPid, int _iTimeoutMs);

} // namespace gitgud::platform
