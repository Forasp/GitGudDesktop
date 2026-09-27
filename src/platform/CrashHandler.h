#pragma once

// -----------------------------------------------------------------------------
// CrashHandler — last-chance reporting for unhandled crashes.
//
// On Windows, installs an unhandled-exception filter that prints the
// exception and a symbolized stack trace to stderr (so it lands in the
// GITGUD_LOG file or the console) and writes gitgud-crash.dmp for a
// debugger. No-op elsewhere.
// -----------------------------------------------------------------------------

#include <string>

namespace gitgud::platform
{

    // `_DumpDirectory`: where gitgud-crash.dmp goes (platform::LogDirectory()).
    void InstallCrashHandler(const std::string& _DumpDirectory);

} // namespace gitgud::platform
