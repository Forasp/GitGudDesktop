#pragma once

// -----------------------------------------------------------------------------
// WinSpawn: CreateProcessW for programs whose standard streams are pipes.
//
// A child started with bInheritHandles inherits every inheritable handle in
// the app, including pipe ends another worker thread is creating for its own
// child at that moment. Such a stray copy keeps a pipe open: its reader never
// sees end-of-file and waits until the wrong program exits. This passes an
// explicit handle list instead, so the child gets its three streams and
// nothing else. Windows only.
// -----------------------------------------------------------------------------

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace gitgud::platform
{

    // CreateProcessW(nullptr, _szCommandLine, ...) with STARTF_USESTDHANDLES;
    // only the given standard handles are inherited (null or invalid ones are
    // skipped). `_dwFlags` are the creation flags. GetLastError() holds the
    // reason on failure.
    bool SpawnWithStdHandles(wchar_t* _szCommandLine, DWORD _dwFlags, void* _pEnvironment,
        const wchar_t* _szWorkingDir, HANDLE _hStdin, HANDLE _hStdout, HANDLE _hStderr,
        PROCESS_INFORMATION& _Info);

} // namespace gitgud::platform

#endif
