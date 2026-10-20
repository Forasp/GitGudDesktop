// Tests for platform/ChildProcess, driving tests/child_echo.cpp (built next
// to the tests; GITGUD_TEST_CHILD is its path). Windows only for now.

#include <catch2/catch_test_macros.hpp>

#include "platform/ChildProcess.h"
#include "platform/Process.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using gitgud::platform::ChildProcess;

namespace
{

    // Collects what a child prints and lets a test wait for it.
    struct Collector
    {
        std::mutex m_Mutex;
        std::condition_variable m_Changed;
        std::vector<std::string> m_Out;
        std::vector<std::string> m_Err;
        int m_iExits = 0;
        int m_iExitCode = -2;

        ChildProcess::OnLine Out()
        {
            return [this](const std::string& _Line)
            {
                Add(m_Out, _Line);
            };
        }

        ChildProcess::OnLine Err()
        {
            return [this](const std::string& _Line)
            {
                Add(m_Err, _Line);
            };
        }

        ChildProcess::OnExit Exit()
        {
            return [this](int _iCode)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                ++m_iExits;
                m_iExitCode = _iCode;
                m_Changed.notify_all();
            };
        }

        void Add(std::vector<std::string>& _Lines, const std::string& _Line)
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            _Lines.push_back(_Line);
            m_Changed.notify_all();
        }

        // Wait until stdout has `_nCount` lines; false after 10 s.
        bool WaitOut(std::size_t _nCount)
        {
            std::unique_lock<std::mutex> lock(m_Mutex);
            return m_Changed.wait_for(
                lock, std::chrono::seconds(10), [&] { return m_Out.size() >= _nCount; });
        }

        std::string OutAt(std::size_t _nIndex)
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            return _nIndex < m_Out.size() ? m_Out[_nIndex] : "";
        }
    };

    ChildProcess::Options EchoChild()
    {
        ChildProcess::Options options;
        options.m_Args = {GITGUD_TEST_CHILD};
        return options;
    }

    bool ProcessEnded(unsigned long _uId)
    {
        HANDLE hprocess = OpenProcess(SYNCHRONIZE, FALSE, _uId);
        if (!hprocess)
        {
            return true;
        }
        const bool bended = WaitForSingleObject(hprocess, 5000) == WAIT_OBJECT_0;
        CloseHandle(hprocess);
        return bended;
    }

} // namespace

TEST_CASE("ChildProcess talks both ways while the child runs", "[process][child]")
{
    Collector seen;
    ChildProcess child;
    std::string error;
    REQUIRE(child.Start(EchoChild(), seen.Out(), seen.Err(), seen.Exit(), error));
    CHECK(child.Running());
    CHECK(child.Id() != 0);

    // A reply arrives before the next line is written: it's a conversation.
    REQUIRE(child.WriteLine("out hello"));
    REQUIRE(seen.WaitOut(1));
    CHECK(seen.OutAt(0) == "hello");
    REQUIRE(child.WriteLine("err oops"));
    REQUIRE(child.Write("out {\"type\":\"result\"}\r\nout "));
    REQUIRE(child.Write("split\n"));
    REQUIRE(seen.WaitOut(3));
    CHECK(seen.OutAt(1) == "{\"type\":\"result\"}");
    CHECK(seen.OutAt(2) == "split");

    REQUIRE(child.WriteLine("exit 7"));
    CHECK(child.Wait(10000) == 7);
    CHECK_FALSE(child.Running());
    CHECK_FALSE(child.WriteLine("out late"));

    std::lock_guard<std::mutex> lock(seen.m_Mutex);
    CHECK(seen.m_Err == std::vector<std::string>{"oops"});
    CHECK(seen.m_iExits == 1);
    CHECK(seen.m_iExitCode == 7);
}

TEST_CASE("ChildProcess ends on end of input", "[process][child]")
{
    Collector seen;
    ChildProcess child;
    std::string error;
    REQUIRE(child.Start(EchoChild(), seen.Out(), {}, seen.Exit(), error));
    child.CloseStdin();
    CHECK(child.Wait(10000) == 0);
    CHECK_FALSE(child.Write("x"));
    CHECK(child.Wait(0) == 0); // stays answered
}

TEST_CASE("ChildProcess passes the environment and working folder", "[process][child]")
{
    const auto folder = std::filesystem::temp_directory_path() / "gitgud-child-test";
    std::filesystem::create_directories(folder);
    SetEnvironmentVariableA("GITGUD_CHILD_DROP", "present");

    Collector seen;
    ChildProcess child;
    ChildProcess::Options options = EchoChild();
    options.m_WorkingDir = folder.u8string();
    options.m_Env = {{"GITGUD_CHILD_ADD", "added"}, {"GITGUD_CHILD_DROP", ""}};
    std::string error;
    REQUIRE(child.Start(options, seen.Out(), {}, {}, error));
    REQUIRE(child.WriteLine("env GITGUD_CHILD_ADD"));
    REQUIRE(child.WriteLine("env GITGUD_CHILD_DROP"));
    REQUIRE(child.WriteLine("env PATH"));
    REQUIRE(child.WriteLine("cwd"));
    REQUIRE(child.WriteLine("big 1000000"));
    REQUIRE(seen.WaitOut(5));
    CHECK(seen.OutAt(0) == "added");
    CHECK(seen.OutAt(1) == "<unset>");
    CHECK(seen.OutAt(2) != "<unset>"); // the rest is inherited
    CHECK(std::filesystem::equivalent(std::filesystem::u8path(seen.OutAt(3)), folder));
    CHECK(seen.OutAt(4) == std::string(1000000, 'x'));
    child.CloseStdin();
    CHECK(child.Wait(10000) == 0);
    SetEnvironmentVariableA("GITGUD_CHILD_DROP", nullptr);
}

TEST_CASE("ChildProcess kills the whole tree", "[process][child]")
{
    Collector seen;
    unsigned long ugrandchild = 0;
    {
        ChildProcess child;
        std::string error;
        REQUIRE(child.Start(EchoChild(), seen.Out(), {}, seen.Exit(), error));
        REQUIRE(child.WriteLine("spawn"));
        REQUIRE(seen.WaitOut(1));
        ugrandchild = std::stoul(seen.OutAt(0));
        child.Kill();
        CHECK(child.Wait(10000) == 137);
    }
    CHECK(ProcessEnded(ugrandchild));

    // The destructor kills a running child too.
    unsigned long uchild = 0;
    {
        ChildProcess child;
        std::string error;
        REQUIRE(child.Start(EchoChild(), {}, {}, {}, error));
        uchild = child.Id();
    }
    CHECK(ProcessEnded(uchild));
}

TEST_CASE("ChildProcess doesn't hang on what the child left running", "[process][child]")
{
    Collector seen;
    ChildProcess child;
    std::string error;
    REQUIRE(child.Start(EchoChild(), seen.Out(), {}, seen.Exit(), error));
    REQUIRE(child.WriteLine("spawn"));
    REQUIRE(seen.WaitOut(1));
    const unsigned long ugrandchild = std::stoul(seen.OutAt(0));
    REQUIRE(child.WriteLine("exit 3"));
    CHECK(child.Wait(10000) == 3);
    CHECK(ProcessEnded(ugrandchild));
}

TEST_CASE("ChildProcess writes never block on a child that stops reading", "[process][child]")
{
    Collector seen;
    unsigned long uchild = 0;
    {
        ChildProcess child;
        std::string error;
        REQUIRE(child.Start(EchoChild(), seen.Out(), {}, seen.Exit(), error));
        REQUIRE(child.WriteLine("stall"));
        REQUIRE(seen.WaitOut(1));
        uchild = child.Id();

        // Far more than the pipe holds: queued, not waited for.
        const auto started = std::chrono::steady_clock::now();
        const std::string big(256u * 1024u, 'x');
        for (int i = 0; i < 8; ++i)
        {
            CHECK(child.WriteLine(big));
        }
        child.CloseStdin();
        CHECK(std::chrono::steady_clock::now() - started < std::chrono::seconds(2));
        CHECK(child.Running());
        CHECK_FALSE(child.WriteLine("late")); // stdin is closing
    } // the destructor kills it and doesn't hang on the stuck write
    CHECK(ProcessEnded(uchild));
}

TEST_CASE("ChildProcess callbacks can wait and destroy it", "[process][child]")
{
    // Wait() from a line callback answers at once instead of deadlocking.
    {
        Collector seen;
        ChildProcess child;
        int iwaited = 0;
        std::string error;
        REQUIRE(child.Start(
            EchoChild(),
            [&](const std::string& _Line)
            {
                iwaited = child.Wait(-1);
                seen.Add(seen.m_Out, _Line);
            },
            {}, {}, error));
        REQUIRE(child.WriteLine("out hi"));
        REQUIRE(seen.WaitOut(1));
        CHECK(iwaited == -1);
        child.CloseStdin();
        CHECK(child.Wait(10000) == 0);
    }

    // Destroyed from its own OnExit: no self-join, no terminate.
    {
        std::mutex mutex;
        std::condition_variable done;
        bool bdestroyed = false;
        auto pchild = std::make_unique<ChildProcess>();
        ChildProcess* praw = pchild.get();
        std::string error;
        REQUIRE(praw->Start(
            EchoChild(), {}, {},
            [&](int)
            {
                pchild.reset();
                std::lock_guard<std::mutex> lock(mutex);
                bdestroyed = true;
                done.notify_all();
            },
            error));
        REQUIRE(praw->WriteLine("exit 0"));
        std::unique_lock<std::mutex> lock(mutex);
        CHECK(done.wait_for(lock, std::chrono::seconds(10), [&] { return bdestroyed; }));
    }

    // Destroyed from a line callback while it still runs.
    {
        std::mutex mutex;
        std::condition_variable done;
        bool bdestroyed = false;
        auto pchild = std::make_unique<ChildProcess>();
        ChildProcess* praw = pchild.get();
        std::string error;
        REQUIRE(praw->Start(
            EchoChild(),
            [&](const std::string&)
            {
                pchild.reset();
                std::lock_guard<std::mutex> lock(mutex);
                bdestroyed = true;
                done.notify_all();
            },
            {}, {}, error));
        const unsigned long uchild = praw->Id();
        REQUIRE(praw->WriteLine("out bye"));
        {
            std::unique_lock<std::mutex> lock(mutex);
            CHECK(done.wait_for(lock, std::chrono::seconds(10), [&] { return bdestroyed; }));
        }
        CHECK(ProcessEnded(uchild));
    }
}

TEST_CASE("ChildProcess refuses what it can't run safely", "[process][child]")
{
    std::string error;
    {
        ChildProcess child;
        CHECK_FALSE(child.Start({}, {}, {}, {}, error));
        CHECK(child.Wait(0) == -1);
    }
    {
        ChildProcess child;
        ChildProcess::Options options;
        options.m_Args = {"definitely-not-a-program-xyz"};
        CHECK_FALSE(child.Start(options, {}, {}, {}, error));
        CHECK(error.find("not found") != std::string::npos);
    }

    // A batch file runs through cmd.exe, found without its extension; an
    // argument cmd.exe would reparse is refused.
    const auto folder = std::filesystem::temp_directory_path() / "gitgud-child-test";
    std::filesystem::create_directories(folder);
    const auto script = folder / "gitgud-child-shim.cmd";
    {
        std::ofstream out(script);
        out << "@echo off\r\necho arg=%~1\r\n";
    }
    {
        Collector seen;
        ChildProcess child;
        ChildProcess::Options options;
        options.m_Args = {(folder / "gitgud-child-shim").u8string(), "two words"};
        REQUIRE(child.Start(options, seen.Out(), {}, {}, error));
        CHECK(child.Wait(10000) == 0);
        CHECK(seen.OutAt(0) == "arg=two words");
    }
    {
        // Inside the quotes every argument gets, these are plain text (this
        // script echoes %1 with its quotes, so its own line stays safe too).
        const auto quoting = folder / "gitgud-child-quoted.cmd";
        {
            std::ofstream out(quoting);
            out << "@echo off\r\necho arg=%1\r\n";
        }
        Collector seen;
        ChildProcess child;
        ChildProcess::Options options;
        options.m_Args = {quoting.u8string(), "Bash(git log:*)&|<>^!"};
        REQUIRE(child.Start(options, seen.Out(), {}, {}, error));
        CHECK(child.Wait(10000) == 0);
        CHECK(seen.OutAt(0) == "arg=\"Bash(git log:*)&|<>^!\"");
    }
    for (const char* szbad : {"a \" & calc", "%PATH%", "two\nlines"})
    {
        ChildProcess child;
        ChildProcess::Options options;
        options.m_Args = {script.u8string(), szbad};
        CHECK_FALSE(child.Start(options, {}, {}, {}, error));
        CHECK(error.find("misread") != std::string::npos);
    }
    {
        ChildProcess child;
        REQUIRE(child.Start(EchoChild(), {}, {}, {}, error));
        CHECK_FALSE(child.Start(EchoChild(), {}, {}, {}, error));
    }
}

#if defined(_WIN32)
TEST_CASE("Processes are found by an argument on their command line", "[process]")
{
    // A child with a marker on its command line, alive for a few seconds.
    const std::string marker = "gitgud-marker-4f1c9e2a7b";
    std::thread child([&]()
        { gitgud::platform::RunProcess({"cmd", "/c", "ping -n 4 127.0.0.1 >nul & rem " + marker}, ""); });
    bool bfound = false;
    for (int i = 0; i < 40 && !bfound; ++i)
    {
        bfound = !gitgud::platform::ProcessesWithArgument(marker).empty();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(bfound);
    CHECK(gitgud::platform::ProcessesWithArgument("gitgud-marker-nobody-has-this").empty());
    child.join();
    CHECK(gitgud::platform::ProcessesWithArgument(marker).empty());
}
#endif
