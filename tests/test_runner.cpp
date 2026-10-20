// The whole run's set-up, before any test.
//
// On Windows a library that fails to load (a test's stand-in, a damaged
// file) makes the system show a dialog that waits for a click, and the run
// stops there: the errors come back to the caller instead.

#include <catch2/reporters/catch_reporter_event_listener.hpp>
#include <catch2/reporters/catch_reporter_registrars.hpp>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace
{

    class QuietErrors : public Catch::EventListenerBase
    {
    public:
        using Catch::EventListenerBase::EventListenerBase;

        void testRunStarting(const Catch::TestRunInfo&) override
        {
#if defined(_WIN32)
            SetErrorMode(GetErrorMode() | SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
#endif
        }
    };

} // namespace

CATCH_REGISTER_LISTENER(QuietErrors)
