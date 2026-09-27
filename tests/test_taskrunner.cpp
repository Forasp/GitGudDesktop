// Tests for the worker-thread infrastructure: the thread-safe EventBus queue
// and TaskRunner's started/done/error event contract.

#include <catch2/catch_test_macros.hpp>

#include "app/EventBus.h"
#include "app/TaskRunner.h"

#include <chrono>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace gitgud::app;

namespace
{

    // Drain until a predicate holds or a timeout passes — stands in for the app's
    // per-frame Drain loop.
    template <typename Pred> bool drainUntil(EventBus& bus, Pred done, int timeoutMs = 5000)
    {
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
        while (std::chrono::steady_clock::now() < deadline)
        {
            bus.Drain();
            if (done())
            {
                return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        return false;
    }

} // namespace

TEST_CASE("publish from another thread is delivered on drain", "[eventbus]")
{
    EventBus bus;
    std::vector<std::string> seen;
    bus.Subscribe("ping", [&](const AppEvent& e) { seen.push_back(e.m_Detail); });

    std::thread producer([&] { bus.Publish({"ping", "from-worker"}); });
    producer.join();

    CHECK(seen.empty()); // nothing until the UI thread drains
    bus.Drain();
    REQUIRE(seen.size() == 1);
    CHECK(seen[0] == "from-worker");
}

TEST_CASE("events published by handlers land in the same drain", "[eventbus]")
{
    EventBus bus;
    std::vector<std::string> order;
    bus.Subscribe("first",
        [&](const AppEvent&)
        {
            order.push_back("first");
            bus.Publish({"second", ""});
        });
    bus.Subscribe("second", [&](const AppEvent&) { order.push_back("second"); });

    bus.Publish({"first", ""});
    bus.Drain();
    REQUIRE(order.size() == 2);
    CHECK(order[1] == "second");
}

TEST_CASE("wildcard subscribers see every event", "[eventbus]")
{
    EventBus bus;
    int count = 0;
    bus.Subscribe("*", [&](const AppEvent&) { ++count; });
    bus.Publish({"a", ""});
    bus.Publish({"b", ""});
    bus.Drain();
    CHECK(count == 2);
}

TEST_CASE("TaskRunner publishes started then done with the result", "[taskrunner]")
{
    EventBus bus;
    std::vector<std::string> events;
    bus.Subscribe("*", [&](const AppEvent& e) { events.push_back(e.m_Type + "|" + e.m_Detail); });

    TaskRunner runner(bus);
    runner.Run("fetch", [] { return std::string("all good"); });

    REQUIRE(drainUntil(bus, [&] { return events.size() >= 2; }));
    CHECK(events[0] == "fetch.started|fetch");
    CHECK(events[1] == "fetch.done|all good");
    REQUIRE(drainUntil(bus, [&] { return !runner.Busy(); }));
}

TEST_CASE("TaskRunner converts exceptions into .error events", "[taskrunner]")
{
    EventBus bus;
    std::vector<std::string> events;
    bus.Subscribe("push.error", [&](const AppEvent& e) { events.push_back(e.m_Detail); });

    TaskRunner runner(bus);
    runner.Run("push", []() -> std::string { throw std::runtime_error("auth denied"); });

    REQUIRE(drainUntil(bus, [&] { return !events.empty(); }));
    CHECK(events[0] == "auth denied");
}

TEST_CASE("parallel tasks all complete", "[taskrunner]")
{
    EventBus bus;
    int done = 0;
    bus.Subscribe("work.done", [&](const AppEvent&) { ++done; });

    TaskRunner runner(bus);
    for (int i = 0; i < 8; ++i)
    {
        runner.Run("work",
            []
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                return std::string("ok");
            });
    }
    REQUIRE(drainUntil(bus, [&] { return done == 8; }));
    CHECK(done == 8);
}
