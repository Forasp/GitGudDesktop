// Tests for platform/Relaunch: the wait a restarted copy does for the copy
// that started it. Starting a copy again is checked by hand (it would start
// this test program again).

#include <catch2/catch_test_macros.hpp>

#include "platform/Relaunch.h"

#include <chrono>
#include <cstdlib>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <unistd.h>
#endif

using namespace gitgud::platform;

namespace
{

    unsigned long OwnPid()
    {
#if defined(_WIN32)
        return GetCurrentProcessId();
#else
        return static_cast<unsigned long>(getpid());
#endif
    }

    void SetVariable(const std::string& _Value)
    {
#if defined(_WIN32)
        _putenv_s(kRelaunchWaitVariable, _Value.c_str());
#else
        setenv(kRelaunchWaitVariable, _Value.c_str(), 1);
#endif
    }

} // namespace

TEST_CASE("Relaunch: a process that's running is waited for until the time is up", "[relaunch]")
{
    const auto start = std::chrono::steady_clock::now();
    CHECK_FALSE(WaitForProcessExit(OwnPid(), 150));
    CHECK(std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(100));
}

TEST_CASE("Relaunch: a process that isn't there needs no wait", "[relaunch]")
{
    CHECK(WaitForProcessExit(0x7ffffff0UL, 5000));
}

TEST_CASE("Relaunch: a copy started any other way doesn't wait", "[relaunch]")
{
    SetVariable("");
#if !defined(_WIN32)
    unsetenv(kRelaunchWaitVariable);
#endif
    CHECK(WaitForEarlierCopy(5000));
}

TEST_CASE("Relaunch: a restarted copy waits for the earlier one and drops the variable", "[relaunch]")
{
    SetVariable(std::to_string(OwnPid()));
    CHECK_FALSE(WaitForEarlierCopy(100));
    CHECK(std::getenv(kRelaunchWaitVariable) == nullptr);
    // The variable is gone, so the next start doesn't wait.
    CHECK(WaitForEarlierCopy(5000));
}
