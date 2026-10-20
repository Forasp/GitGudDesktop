// Tests for the profiler (app/Profiler.h): zones and their times, the call
// tree's inclusive and exclusive times, Lua's call hook (errors, coroutines),
// the reports a capture writes, and the stall watchdog.

#include <catch2/catch_test_macros.hpp>

#include "app/Profiler.h"
#include "app/StallWatchdog.h"
#include "lua/LuaEngine.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>

namespace fs = std::filesystem;
using namespace gitgud;

namespace
{
    void Spin(int _iMs)
    {
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(_iMs);
        while (std::chrono::steady_clock::now() < until)
        {
        }
    }

    const prof::ZoneStats* Find(const std::vector<prof::ZoneStats>& _Stats, const std::string& _Name)
    {
        for (const auto& zone : _Stats)
        {
            if (zone.m_Name == _Name)
            {
                return &zone;
            }
        }
        return nullptr;
    }

    std::string ReadFile(const fs::path& _Path)
    {
        std::ifstream in(_Path, std::ios::binary);
        std::ostringstream text;
        text << in.rdbuf();
        return text.str();
    }

    fs::path Scratch()
    {
        const fs::path dir = fs::temp_directory_path() / "gitgud-test-profiler";
        std::error_code ec;
        fs::remove_all(dir, ec);
        fs::create_directories(dir);
        return dir;
    }

    void Recurse(int _iLeft)
    {
        GITGUD_PROFILE_SCOPE("test.recurse");
        Spin(2);
        if (_iLeft > 0)
        {
            Recurse(_iLeft - 1);
        }
    }
} // namespace

TEST_CASE("Profiler: zones nest, and the call tree splits self from inclusive time", "[profiler]")
{
    // The report's per-zone stats come from the UI thread.
    prof::SetThreadName("UI");
    const fs::path dir = Scratch();
    REQUIRE(prof::StartCapture());
    for (int i = 0; i < 3; ++i)
    {
        GITGUD_PROFILE_SCOPE("test.outer");
        Spin(5);
        {
            GITGUD_PROFILE_SCOPE("test.inner");
            Spin(10);
        }
    }
    Recurse(3); // four nested calls of one zone
    const std::string folder = prof::StopCapture(dir.u8string());
    REQUIRE_FALSE(folder.empty());

    const auto stats = prof::LastCaptureStats();
    const auto* outer = Find(stats, "test.outer");
    const auto* inner = Find(stats, "test.inner");
    const auto* recurse = Find(stats, "test.recurse");
    REQUIRE(outer);
    REQUIRE(inner);
    REQUIRE(recurse);
    CHECK(outer->m_uiCalls == 3);
    CHECK(inner->m_uiCalls == 3);
    CHECK(outer->m_fInclusiveMs >= 45.0);
    CHECK(outer->m_fExclusiveMs >= 15.0);
    CHECK(outer->m_fExclusiveMs < outer->m_fInclusiveMs - 25.0);
    CHECK(inner->m_fExclusiveMs >= 30.0);
    // Recursion counts its time once, not once per level.
    CHECK(recurse->m_uiCalls == 4);
    CHECK(recurse->m_fInclusiveMs >= 8.0);
    CHECK(recurse->m_fInclusiveMs < 20.0);

    for (const char* szfile : {"report.txt", "flame.svg", "folded.txt", "trace.json"})
    {
        INFO(szfile);
        CHECK(fs::file_size(fs::u8path(folder) / szfile) > 0);
    }
    const std::string trace = ReadFile(fs::u8path(folder) / "trace.json");
    CHECK(trace.find("\"name\":\"test.inner\",\"ph\":\"X\"") != std::string::npos);
    const std::string folded = ReadFile(fs::u8path(folder) / "folded.txt");
    CHECK(folded.find("UI;test.outer;test.inner ") != std::string::npos);
    CHECK(folded.find("test.recurse;test.recurse;test.recurse;test.recurse ") != std::string::npos);
    const std::string report = ReadFile(fs::u8path(folder) / "report.txt");
    CHECK(report.find("test.inner") != std::string::npos);
    CHECK(report.find("<- test.outer") != std::string::npos);
}

TEST_CASE("Profiler: zones outside a capture cost nothing and leave nothing open", "[profiler]")
{
    const int idepth = prof::Depth();
    {
        GITGUD_PROFILE_SCOPE("test.off");
        CHECK(prof::Depth() == idepth + 1);
        // A capture starting mid-zone doesn't record that zone's end.
        REQUIRE(prof::StartCapture());
    }
    CHECK(prof::Depth() == idepth);
    const fs::path dir = Scratch();
    prof::StopCapture(dir.u8string());
    CHECK(Find(prof::LastCaptureStats(), "test.off") == nullptr);
}

TEST_CASE("Profiler: Lua functions are zones, through errors and coroutines", "[profiler]")
{
    prof::SetThreadName("UI");
    lua::LuaEngine engine;
    REQUIRE(engine.Initialize());
    REQUIRE(engine.Eval(R"lua(
        function spin(ms) local t = os.clock() + ms / 1000 while os.clock() < t do end end
        function leaf() spin(4) end
        function caller() leaf() leaf() end
        function fails() spin(2) error("boom") end
        function catches() pcall(fails) leaf() end
        function gen() for i = 1, 3 do spin(2) coroutine.yield(i) end end
        function runs()
            local co = coroutine.create(gen)
            while coroutine.resume(co) do spin(1) end
        end
        gitgud.on("test.go", function() caller() catches() runs() fails() end)
    )lua"));
    REQUIRE(prof::StartCapture());
    engine.SetCallProfiling(true);
    const int idepth = prof::Depth();
    engine.Dispatch("test.go", ""); // ends in an uncaught error
    CHECK(prof::Depth() == idepth);
    engine.SetCallProfiling(false);
    const fs::path dir = Scratch();
    const std::string folder = prof::StopCapture(dir.u8string());
    REQUIRE_FALSE(folder.empty());

    const auto stats = prof::LastCaptureStats();
    auto named = [&](const std::string& _Prefix) -> const prof::ZoneStats*
    {
        for (const auto& zone : stats)
        {
            if (zone.m_Name.rfind(_Prefix, 0) == 0)
            {
                return &zone;
            }
        }
        return nullptr;
    };
    const auto* leaf = named("leaf (");
    const auto* caller = named("caller (");
    const auto* fails = named("fails (");
    // A coroutine's body is called by resume, without a name: found by where
    // it is defined.
    const prof::ZoneStats* gen = nullptr;
    for (const auto& zone : stats)
    {
        if (zone.m_Name.size() > 3 && zone.m_Name.compare(zone.m_Name.size() - 3, 3, ":7)") == 0)
        {
            gen = &zone;
        }
    }
    const auto* handler = named("on test.go (");
    REQUIRE(leaf);
    REQUIRE(caller);
    REQUIRE(fails);
    REQUIRE(gen);
    REQUIRE(handler);
    CHECK(leaf->m_uiCalls == 3);
    CHECK(caller->m_uiCalls == 1);
    CHECK(fails->m_uiCalls == 2);
    CHECK(leaf->m_fInclusiveMs >= 11.0);
    CHECK(caller->m_fInclusiveMs >= 6.0);
    // The coroutine's time counts while it runs, not while it is suspended.
    CHECK(gen->m_fInclusiveMs >= 5.0);
    CHECK(gen->m_fInclusiveMs < 12.0);
    CHECK(handler->m_uiCalls == 1);
    CHECK(named("[C] pcall") != nullptr);
}

TEST_CASE("Stall watchdog: a blocked UI thread is reported with its zones and Lua stack", "[profiler]")
{
    const fs::path dir = Scratch();
    const fs::path log = dir / "perf.log";
    prof::WatchdogOptions options;
    options.m_iThresholdMs = 100;
    options.m_LogPath = log.u8string();
    lua::LuaEngine engine;
    REQUIRE(engine.Initialize());
    REQUIRE(engine.Eval(R"lua(
        function busyLoop(ms) local t = os.clock() + ms / 1000 while os.clock() < t do end end
        gitgud.on("test.stall", function() busyLoop(450) end)
    )lua"));
    prof::StartWatchdog(options);
    const int ibefore = prof::StallCount();

    prof::UiBusy();
    {
        GITGUD_PROFILE_SCOPE("test.native stall");
        Spin(350);
    }
    prof::UiIdle();
    prof::UiBusy();
    engine.Dispatch("test.stall", "");
    prof::UiIdle();
    prof::UiBusy();
    Spin(20); // short: not a stall
    prof::UiIdle();
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    prof::StopWatchdog();

    CHECK(prof::StallCount() - ibefore == 2);
    const std::string text = ReadFile(log);
    CHECK(text.find("zones at first sample: test.native stall") != std::string::npos);
    CHECK(text.find("on test.stall (") != std::string::npos);
    CHECK(text.find("busyLoop") != std::string::npos);
#if defined(_WIN32)
    CHECK(text.find("test_profiler.cpp") != std::string::npos); // the native stack
#endif
}
