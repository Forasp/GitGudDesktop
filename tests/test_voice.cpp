// Tests for the voice sessions end to end: voice::ListenSession and
// SpeakSession and the Lua bindings, against a fake speech engine reached
// through in-memory links (voice/Link.h), with synthetic audio. No
// microphone, no speaker.

#include <catch2/catch_test_macros.hpp>

#include "app/EventBus.h"
#include "app/Json.h"
#include "lua/LuaBindings.h"
#include "lua/LuaEngine.h"
#include "platform/Audio.h"
#include "voice/Link.h"
#include "voice/Pcm.h"
#include "voice/SendQueue.h"
#include "voice/VoiceSession.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

using gitgud::app::Json;

namespace
{

    // Polls `_Done` until it holds or a generous deadline passes.
    bool WaitFor(const std::function<bool()>& _Done, int _iSeconds = 10)
    {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(_iSeconds);
        while (!_Done())
        {
            if (std::chrono::steady_clock::now() > deadline)
            {
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        return true;
    }

    // One message the fake engine got.
    struct Received
    {
        bool m_bBinary = false;
        std::string m_Data;
    };

    // One direction of a connection: messages handed over in order on a
    // thread of its own, as a socket's peer would see them.
    class Pump
    {
      public:
        struct Item
        {
            bool m_bBinary = false;
            bool m_bClose = false;
            int m_iCode = 0;
            std::string m_Data;
        };

        using Deliver = std::function<void(const Item&)>;

        explicit Pump(Deliver _Deliver) : m_Deliver(std::move(_Deliver))
        {
            m_Thread = std::thread([this]() { Run(); });
        }

        ~Pump()
        {
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_bStop = true;
            }
            m_Wake.notify_all();
            if (m_Thread.joinable())
            {
                if (m_Thread.get_id() == std::this_thread::get_id())
                {
                    m_Thread.detach();
                }
                else
                {
                    m_Thread.join();
                }
            }
        }

        void Push(Item _Item)
        {
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Items.push_back(std::move(_Item));
            }
            m_Wake.notify_all();
        }

        bool OnThread() const
        {
            return m_Thread.get_id() == std::this_thread::get_id();
        }

      private:
        void Run()
        {
            for (;;)
            {
                Item item;
                {
                    std::unique_lock<std::mutex> lock(m_Mutex);
                    m_Wake.wait(lock, [this]() { return m_bStop || !m_Items.empty(); });
                    if (m_bStop)
                    {
                        return;
                    }
                    item = std::move(m_Items.front());
                    m_Items.pop_front();
                }
                m_Deliver(item);
            }
        }

        Deliver m_Deliver;
        std::mutex m_Mutex;
        std::condition_variable m_Wake;
        std::deque<Item> m_Items;
        bool m_bStop = false;
        std::thread m_Thread;
    };

    // A speech engine stand-in: each link it makes (Links()) connects to
    // it, one at a time, and it records everything the session sends.
    class FakeVoiceEngine
    {
      public:
        // Answers a message (on the connection's thread).
        using OnMessage = std::function<void(FakeVoiceEngine&, const Received&)>;

        FakeVoiceEngine() : m_pState(std::make_shared<State>())
        {
            m_pState->m_pOwner = this;
        }

        ~FakeVoiceEngine()
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            m_pState->m_pOwner = nullptr;
        }

        // Links to this engine, for the sessions.
        gitgud::voice::LinkFactory Links()
        {
            std::shared_ptr<State> pstate = m_pState;
            return [pstate](const std::string& _Channel) -> std::unique_ptr<gitgud::voice::ILink>
            { return std::make_unique<FakeLink>(pstate, _Channel); };
        }

        // The next opens are refused with this message (0: accepted).
        void Refuse(int _iStatus, const std::string& _Message)
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            m_pState->m_iRefuse = _iStatus;
            m_pState->m_RefuseMessage = _Message;
        }

        void SetOnMessage(OnMessage _OnMessage)
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            m_pState->m_OnMessage = std::move(_OnMessage);
        }

        void SendText(const std::string& _Text)
        {
            Down({false, false, 0, _Text});
        }

        void SendJson(const Json& _Message)
        {
            SendText(_Message.Dump());
        }

        void SendBinary(const std::string& _Data)
        {
            Down({true, false, 0, _Data});
        }

        void SendClose(int _iCode)
        {
            Down({false, true, _iCode, "bye"});
        }

        // What was received so far.
        std::vector<Received> Messages() const
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            return m_pState->m_Messages;
        }

        std::vector<Json> TextMessages() const
        {
            std::vector<Json> out;
            for (const Received& message : Messages())
            {
                if (!message.m_bBinary)
                {
                    out.push_back(Json::Parse(message.m_Data).value_or(Json()));
                }
            }
            return out;
        }

        std::vector<Json> OfType(const std::string& _Type) const
        {
            std::vector<Json> out;
            for (const Json& message : TextMessages())
            {
                if (message["type"].AsString() == _Type)
                {
                    out.push_back(message);
                }
            }
            return out;
        }

        std::size_t BinaryCount() const
        {
            std::size_t ncount = 0;
            for (const Received& message : Messages())
            {
                ncount += message.m_bBinary ? 1 : 0;
            }
            return ncount;
        }

        // The last link's channel ("listen" or "speak").
        std::string Path() const
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            return m_pState->m_Channel;
        }

        int Connections() const
        {
            return m_pState->m_iConnections;
        }

        // The session's own close: its code (1000), or -1 before it closed.
        int ClientCloseCode() const
        {
            return m_pState->m_iClientClose;
        }

        bool Connected() const
        {
            return m_pState->m_bConnected;
        }

      private:
        class FakeLink;

        struct State
        {
            mutable std::mutex m_Mutex;
            FakeVoiceEngine* m_pOwner = nullptr;
            FakeLink* m_pCurrent = nullptr; // the open link
            int m_iRefuse = 0;
            std::string m_RefuseMessage;
            std::string m_Channel;
            std::vector<Received> m_Messages;
            OnMessage m_OnMessage;
            std::atomic<int> m_iConnections{0};
            std::atomic<int> m_iClientClose{-1};
            std::atomic<bool> m_bConnected{false};
        };

        // The session's end of one connection. Up: what the session sends,
        // handed to the engine on one thread; down: what the engine sends,
        // handed to the session on another.
        class FakeLink final : public gitgud::voice::ILink
        {
          public:
            FakeLink(std::shared_ptr<State> _pState, std::string _Channel)
                : m_pState(std::move(_pState)), m_Channel(std::move(_Channel))
            {
            }

            ~FakeLink() override
            {
                Close();
                m_pDown.reset();
                m_pUp.reset();
            }

            bool Open(OnMessage _OnMessage, OnClose _OnClose, std::string& _Error) override
            {
                std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
                m_pState->m_Channel = m_Channel;
                if (m_pState->m_iRefuse != 0)
                {
                    _Error = m_pState->m_RefuseMessage;
                    return false;
                }
                m_OnMessage = std::move(_OnMessage);
                m_OnClose = std::move(_OnClose);
                m_pUp = std::make_unique<Pump>([this](const Pump::Item& _Item) { Up(_Item); });
                m_pDown = std::make_unique<Pump>([this](const Pump::Item& _Item) { Down(_Item); });
                m_pState->m_pCurrent = this;
                m_pState->m_iClientClose = -1;
                m_pState->m_bConnected = true;
                ++m_pState->m_iConnections;
                m_bOpen = true;
                return true;
            }

            bool SendText(const std::string& _Text) override
            {
                return Send(false, _Text);
            }

            bool SendBinary(const void* _pData, std::size_t _nSize) override
            {
                return Send(true, std::string(static_cast<const char*>(_pData), _nSize));
            }

            std::string LastSendError() const override
            {
                return {};
            }

            void Close() override
            {
                if (!m_bOpen.exchange(false))
                {
                    return;
                }
                {
                    std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
                    if (m_pState->m_pCurrent == this)
                    {
                        m_pState->m_pCurrent = nullptr;
                        m_pState->m_iClientClose = 1000;
                        m_pState->m_bConnected = false;
                    }
                }
                Closed(1000, "");
            }

            // From the engine (any thread).
            void FromEngine(Pump::Item _Item)
            {
                if (m_bOpen && m_pDown)
                {
                    m_pDown->Push(std::move(_Item));
                }
            }

          private:
            bool Send(bool _bBinary, std::string _Data)
            {
                if (!m_bOpen)
                {
                    return false;
                }
                m_pUp->Push({_bBinary, false, 0, std::move(_Data)});
                return true;
            }

            // The engine's thread: record it and let the test answer.
            void Up(const Pump::Item& _Item)
            {
                const Received received{_Item.m_bBinary, _Item.m_Data};
                FakeVoiceEngine::OnMessage handler;
                FakeVoiceEngine* powner = nullptr;
                {
                    std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
                    if (m_pState->m_pCurrent != this)
                    {
                        return;
                    }
                    m_pState->m_Messages.push_back(received);
                    handler = m_pState->m_OnMessage;
                    powner = m_pState->m_pOwner;
                }
                if (handler && powner)
                {
                    handler(*powner, received);
                }
            }

            // The session's receive thread.
            void Down(const Pump::Item& _Item)
            {
                if (_Item.m_bClose)
                {
                    {
                        std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
                        if (m_pState->m_pCurrent == this)
                        {
                            m_pState->m_pCurrent = nullptr;
                            m_pState->m_bConnected = false;
                        }
                    }
                    m_bOpen = false;
                    Closed(_Item.m_iCode, _Item.m_Data);
                    return;
                }
                if (m_OnMessage)
                {
                    m_OnMessage(_Item.m_bBinary, _Item.m_Data);
                }
            }

            void Closed(int _iCode, const std::string& _Reason)
            {
                if (!m_bCloseReported.exchange(true) && m_OnClose)
                {
                    m_OnClose(_iCode, _Reason);
                }
            }

            std::shared_ptr<State> m_pState;
            std::string m_Channel;
            OnMessage m_OnMessage;
            OnClose m_OnClose;
            std::atomic<bool> m_bOpen{false};
            std::atomic<bool> m_bCloseReported{false};
            std::unique_ptr<Pump> m_pUp;
            std::unique_ptr<Pump> m_pDown;

            friend class FakeVoiceEngine;
        };

        void Down(Pump::Item _Item)
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            if (m_pState->m_pCurrent)
            {
                m_pState->m_pCurrent->FromEngine(std::move(_Item));
            }
        }

        std::shared_ptr<State> m_pState;
    };

    // A microphone the test speaks into.
    class FakeCapture : public gitgud::platform::IAudioCapture
    {
      public:
        struct State
        {
            std::mutex m_Mutex;
            OnSamples m_OnSamples;
            std::atomic<int> m_iStarts{0};
            std::atomic<int> m_iStops{0};
            std::atomic<int> m_iRate{0};
            bool m_bFail = false;
            std::string m_Route; // what Route() says
        };

        explicit FakeCapture(std::shared_ptr<State> _pState) : m_pState(std::move(_pState))
        {
        }

        bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) override
        {
            if (m_pState->m_bFail)
            {
                _Error = "no microphone here";
                return false;
            }
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            m_pState->m_OnSamples = std::move(_OnSamples);
            m_pState->m_iRate = _iSampleRate;
            ++m_pState->m_iStarts;
            return true;
        }

        void Stop() override
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            m_pState->m_OnSamples = nullptr;
            ++m_pState->m_iStops;
        }

        std::string Description() const override
        {
            return "Test microphone";
        }

        std::string Route() const override
        {
            return m_pState->m_Route;
        }

      private:
        std::shared_ptr<State> m_pState;
    };

    // Speak `_nCount` samples of a tone into the fake microphone.
    void Speak(FakeCapture::State& _State, std::size_t _nCount)
    {
        std::vector<int16_t> samples(_nCount);
        for (std::size_t i = 0; i < _nCount; ++i)
        {
            samples[i] = static_cast<int16_t>((i % 40) * 500 - 10000);
        }
        std::lock_guard<std::mutex> lock(_State.m_Mutex);
        REQUIRE(_State.m_OnSamples);
        _State.m_OnSamples(samples.data(), samples.size());
    }

    // A speaker that keeps what it's given.
    class FakePlayback : public gitgud::platform::IAudioPlayback
    {
      public:
        struct State
        {
            std::mutex m_Mutex;
            std::vector<int16_t> m_Played;
            std::atomic<int> m_iRate{0};
            std::atomic<int> m_iFlushes{0};
            std::atomic<bool> m_bStopped{false};
        };

        explicit FakePlayback(std::shared_ptr<State> _pState) : m_pState(std::move(_pState))
        {
        }

        bool Start(int _iSampleRate, std::string&) override
        {
            m_pState->m_iRate = _iSampleRate;
            return true;
        }

        void Stop() override
        {
            m_pState->m_bStopped = true;
        }

        int SampleRate() const override
        {
            return m_pState->m_iRate;
        }

        void Enqueue(const int16_t* _pSamples, std::size_t _nCount) override
        {
            std::lock_guard<std::mutex> lock(m_pState->m_Mutex);
            m_pState->m_Played.insert(m_pState->m_Played.end(), _pSamples, _pSamples + _nCount);
        }

        void Flush() override
        {
            ++m_pState->m_iFlushes;
        }

        std::size_t Queued() const override
        {
            return 0; // plays at once
        }

      private:
        std::shared_ptr<State> m_pState;
    };

    // Events a session reported, for the test thread.
    struct Events
    {
        mutable std::mutex m_Mutex;
        std::vector<Json> m_List;

        gitgud::voice::OnEvent Sink()
        {
            return [this](const Json& _Event)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_List.push_back(_Event);
            };
        }

        std::vector<Json> OfType(const std::string& _Type) const
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            std::vector<Json> out;
            for (const Json& event : m_List)
            {
                if (event["type"].AsString() == _Type)
                {
                    out.push_back(event);
                }
            }
            return out;
        }

        bool Has(const std::string& _Type) const
        {
            return !OfType(_Type).empty();
        }
    };

} // namespace

TEST_CASE("Sessions without a speech engine report it and close", "[voice]")
{
    for (const gitgud::voice::LinkFactory& links :
        {gitgud::voice::LinkFactory(), gitgud::voice::LinkFactory([](const std::string&)
                                           { return std::unique_ptr<gitgud::voice::ILink>(); })})
    {
        Events events;
        auto pcapture = std::make_shared<FakeCapture::State>();
        gitgud::voice::ListenSession session(links, events.Sink());
        REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pcapture)));
        REQUIRE(WaitFor([&]() { return events.Has("closed"); }));
        REQUIRE(events.Has("error"));
        CHECK(events.OfType("error").at(0)["code"].AsString() == "connect");
        CHECK(pcapture->m_iStarts == 0); // the mic never opened
        CHECK_FALSE(session.Running());
    }
}

TEST_CASE("Sessions open the link for their channel; a refused one closes", "[voice]")
{
    FakeVoiceEngine server;

    SECTION("accepted")
    {
        Events events;
        gitgud::voice::ListenSession session(server.Links(), events.Sink());
        REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(
                                                  std::make_shared<FakeCapture::State>())));
        REQUIRE(WaitFor([&]() { return !server.OfType("hello").empty(); }));
        CHECK(server.Path() == "listen");
        CHECK(server.Connections() == 1);
        session.Stop();
        CHECK(server.ClientCloseCode() == 1000);
    }

    SECTION("refused")
    {
        server.Refuse(1, "the engine isn't ready");
        Events events;
        gitgud::voice::ListenSession session(server.Links(), events.Sink());
        REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(
                                                  std::make_shared<FakeCapture::State>())));
        REQUIRE(WaitFor([&]() { return events.Has("closed"); }));
        const std::vector<Json> errors = events.OfType("error");
        REQUIRE(errors.size() == 1);
        CHECK(errors[0]["code"].AsString() == "connect");
        CHECK(errors[0]["message"].AsString() == "the engine isn't ready");
        CHECK(server.Connections() == 0);
    }
}

TEST_CASE("ListenSession: hello fields", "[voice]")
{
    const Json hello = gitgud::voice::ListenSession::Hello(Json::Object()
            .Set("wakeWord", "Bragi")
            .Set("lookbackTokens", 800)
            .Set("wakeThreshold", 0.3)
            .Set("sampleRate", 44100)
            .Set("version", 3));
    CHECK(hello["type"].AsString() == "hello");
    CHECK(hello["version"].AsInt(-1) == 0);
    CHECK(hello["sampleRate"].AsInt() == 16000);
    CHECK(hello["client"].AsString() == "GitGud");
    CHECK(hello["lookbackTokens"].AsInt() == 800);
    CHECK(hello["contextTokens"].AsInt() == 1000);
    CHECK(hello["messageContextTokens"].AsInt() == 0);
    CHECK(hello["endWaitSeconds"].AsInt() == 3);
    CHECK(hello["closingPhrase"].AsString() == "over and out");
    CHECK(hello["wakeThreshold"].AsNumber() == 0.3);
    CHECK(hello["mishearings"].GetType() == Json::Type::Array);
    CHECK_FALSE(hello.Has("lookbackSeconds"));
}

TEST_CASE("ListenSession: streams the mic and reports transcripts", "[voice]")
{
    FakeVoiceEngine server;
    server.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            if (_Message.m_bBinary)
            {
                return;
            }
            const Json message = Json::Parse(_Message.m_Data).value_or(Json());
            const std::string& type = message["type"].AsString();
            if (type == "hello")
            {
                _Server.SendJson(
                    Json::Object().Set("type", "ready").Set("version", 0).Set("keywords", true));
            }
            else if (type == "wake")
            {
                _Server.SendJson(
                    Json::Object().Set("type", "partial").Set("text", "Bragi, run").Set("t", 900));
                _Server.SendJson(Json::Object()
                        .Set("type", "message")
                        .Set("text", "Bragi, run the tests")
                        .Set("endedBy", "send")
                        .Set("t0", 100)
                        .Set("t1", 1200)
                        .Set("context", Json::Array()));
            }
            else if (type == "lookback")
            {
                _Server.SendJson(Json::Object()
                        .Set("type", "lookback")
                        .Set("id", message["id"])
                        .Set("segments",
                            Json::Array().Push(Json::Object().Set("t0", 0).Set("t1", 500).Set(
                                "text", "earlier"))));
            }
        });
    auto pclient = server.Links();
    auto pmic = std::make_shared<FakeCapture::State>();
    Events events;
    gitgud::voice::ListenSession session(pclient, events.Sink());
    REQUIRE(session.Start(Json::Object().Set("wakeWord", "Bragi").Set("lookbackTokens", 2000),
        std::make_unique<FakeCapture>(pmic)));
    CHECK_FALSE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pmic)));

    // hello first, then ready, then the mic opens.
    REQUIRE(WaitFor([&]() { return pmic->m_iStarts == 1; }));
    CHECK(pmic->m_iRate == 16000);
    CHECK(server.Path() == "listen");
    const std::vector<Json> hellos = server.OfType("hello");
    REQUIRE(hellos.size() == 1);
    CHECK(server.TextMessages().front()["type"].AsString() == "hello");
    CHECK(hellos[0]["lookbackTokens"].AsInt() == 2000);
    CHECK(hellos[0]["sampleRate"].AsInt() == 16000);
    REQUIRE(WaitFor([&]() { return events.Has("mic"); }));
    CHECK(events.OfType("ready").size() == 1);
    CHECK(events.OfType("mic")[0]["state"].AsString() == "on");
    CHECK(events.OfType("mic")[0]["device"].AsString() == "Test microphone");

    // 1000 samples (62.5 ms): three whole 20 ms frames, the rest waits.
    Speak(*pmic, 1000);
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 3; }));
    Speak(*pmic, 280); // completes the fourth
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 4; }));
    std::vector<int16_t> sent;
    for (const Received& message : server.Messages())
    {
        if (message.m_bBinary)
        {
            REQUIRE(message.m_Data.size() == 640);
            const std::vector<int16_t> samples = gitgud::voice::FromBytes(message.m_Data);
            sent.insert(sent.end(), samples.begin(), samples.end());
        }
    }
    REQUIRE(sent.size() == 1280);
    CHECK(sent[0] == -10000);
    CHECK(sent[1] == -9500);
    CHECK(sent[1000] == -10000); // the second push starts the tone again

    // Controls, in the protocol's shapes.
    session.Wake();
    REQUIRE(WaitFor([&]() { return events.Has("message"); }));
    CHECK(events.OfType("partial")[0]["text"].AsString() == "Bragi, run");
    const Json message = events.OfType("message")[0];
    CHECK(message["text"].AsString() == "Bragi, run the tests");
    CHECK(message["endedBy"].AsString() == "send");

    session.Lookback("lb1", 300);
    session.Lookback("lb2", -1);
    REQUIRE(WaitFor([&]() { return events.OfType("lookback").size() == 2; }));
    const std::vector<Json> lookbacks = server.OfType("lookback");
    REQUIRE(lookbacks.size() == 2);
    CHECK(lookbacks[0]["id"].AsString() == "lb1");
    CHECK(lookbacks[0]["tokens"].AsInt() == 300);
    CHECK_FALSE(lookbacks[0].Has("seconds"));
    CHECK(lookbacks[1]["id"].AsString() == "lb2");
    CHECK_FALSE(lookbacks[1].Has("tokens"));
    CHECK(events.OfType("lookback")[0]["segments"][0]["text"].AsString() == "earlier");

    session.SendNow();
    session.SendNow("done");
    session.Cancel();
    session.Playback("started", "r1");
    session.Config(Json::Object().Set("endWaitSeconds", 5).Set("type", "nonsense"));
    session.Train("start");
    session.Enroll("clear");
    REQUIRE(WaitFor([&]() { return !server.OfType("enroll").empty(); }));
    REQUIRE(server.OfType("send").size() == 2);
    CHECK_FALSE(server.OfType("send")[0].Has("reason"));
    CHECK(server.OfType("send")[1]["reason"].AsString() == "done");
    CHECK(server.OfType("cancel").size() == 1);
    const Json playback = server.OfType("playback").at(0);
    CHECK(playback["state"].AsString() == "started");
    CHECK(playback["id"].AsString() == "r1");
    CHECK(server.OfType("config").at(0)["endWaitSeconds"].AsInt() == 5);
    CHECK(server.OfType("train").at(0)["state"].AsString() == "start");
    CHECK(server.OfType("enroll").at(0)["state"].AsString() == "clear");
    CHECK(session.DroppedFrames() == 0);

    // Stop: mic off, a normal close.
    session.Stop();
    CHECK_FALSE(session.Running());
    CHECK(pmic->m_iStops == 1);
    REQUIRE(WaitFor([&]() { return server.ClientCloseCode() == 1000; }));
    CHECK(events.OfType("mic").back()["state"].AsString() == "off");
    CHECK(events.OfType("mic").back()["device"].AsString() == "Test microphone");
    CHECK(events.OfType("mic").back()["frames"].AsInt() == 4);
    CHECK(events.OfType("mic").back()["seconds"].AsNumber() == 0.1); // 1280 samples
    REQUIRE(events.OfType("closed").size() == 1);
    CHECK(events.OfType("closed")[0]["code"].AsInt() == 1000);
}

TEST_CASE("ListenSession: no ready, no mic", "[voice]")
{
    FakeVoiceEngine server; // never answers hello
    auto pclient = server.Links();
    auto pmic = std::make_shared<FakeCapture::State>();
    Events events;
    gitgud::voice::ListenSession session(pclient, events.Sink());
    session.SetReadyTimeout(std::chrono::milliseconds(200));
    REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pmic)));
    REQUIRE(WaitFor([&]() { return events.Has("closed"); }));
    CHECK(events.OfType("error").at(0)["code"].AsString() == "no-ready");
    CHECK(pmic->m_iStarts == 0);
    CHECK(server.BinaryCount() == 0);
    REQUIRE(WaitFor([&]() { return !session.Running(); }));
}

TEST_CASE("ListenSession: a mic that gives nothing is reported, then falls back", "[voice]")
{
    FakeVoiceEngine server;
    server.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            if (!_Message.m_bBinary &&
                Json::Parse(_Message.m_Data).value_or(Json())["type"].AsString() == "hello")
            {
                _Server.SendJson(Json::Object().Set("type", "ready").Set("version", 0));
            }
        });
    auto pclient = server.Links();
    auto pfirst = std::make_shared<FakeCapture::State>();  // starts, never speaks
    auto psecond = std::make_shared<FakeCapture::State>(); // the fallback
    pfirst->m_Route = "mic: Webcam (default); echo reference: Speakers (default)";
    psecond->m_Route = "mic: Webcam (default); ducking opt-out: session ok, stream ok";
    Events events;
    gitgud::voice::ListenSession session(pclient, events.Sink());
    session.SetSilentTimeout(std::chrono::milliseconds(100));
    REQUIRE(session.Start(Json::Object(),
        gitgud::platform::MakeFallbackCapture(std::make_unique<FakeCapture>(pfirst),
            std::make_unique<FakeCapture>(psecond), std::chrono::milliseconds(400))));

    // Silent past the session's limit: an error, and the session goes on.
    REQUIRE(WaitFor([&]() { return events.Has("error"); }));
    CHECK(events.OfType("error")[0]["code"].AsString() == "no-audio");
    CHECK(events.OfType("mic")[0]["device"].AsString() == "Test microphone");
    // The mic line says which devices, for the log.
    CHECK(events.OfType("mic")[0]["route"].AsString() == pfirst->m_Route);
    CHECK(session.Running());

    // Silent past the capture's limit: plain capture takes over and the
    // session says so.
    REQUIRE(WaitFor([&]() { return psecond->m_iStarts == 1; }));
    CHECK(pfirst->m_iStops >= 1);
    REQUIRE(WaitFor([&]() { return events.OfType("mic").size() == 2; }));
    CHECK(events.OfType("mic")[1]["state"].AsString() == "on");
    CHECK(events.OfType("mic")[1]["device"].AsString() ==
          "Microphone (no echo cancellation: it gave no audio)");
    // Its route, then the one that failed and why.
    CHECK(events.OfType("mic")[1]["route"].AsString() ==
          psecond->m_Route + "; tried before: (" + pfirst->m_Route + "): it gave no audio");
    CHECK(psecond->m_iRate == 16000);

    Speak(*psecond, 1600); // 0.1 s: five frames
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 5; }));
    CHECK(events.OfType("error").size() == 1);

    session.Stop();
    const Json off = events.OfType("mic").back();
    CHECK(off["state"].AsString() == "off");
    CHECK(off["device"].AsString() == "Microphone (no echo cancellation: it gave no audio)");
    CHECK(off["frames"].AsInt() == 5);
    CHECK(off["seconds"].AsNumber() == 0.1);
    CHECK(off["dropped"].AsInt() == 0);
    CHECK(psecond->m_iStops == 1);
}

TEST_CASE("ListenSession: a level for each second of the mic", "[voice]")
{
    FakeVoiceEngine server;
    server.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            if (!_Message.m_bBinary &&
                Json::Parse(_Message.m_Data).value_or(Json())["type"].AsString() == "hello")
            {
                _Server.SendJson(Json::Object().Set("type", "ready").Set("version", 0));
            }
        });
    auto pclient = server.Links();
    auto pmic = std::make_shared<FakeCapture::State>();
    Events events;
    gitgud::voice::ListenSession session(pclient, events.Sink());
    REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pmic)));
    REQUIRE(WaitFor([&]() { return pmic->m_iStarts == 1; }));

    // Under a second: no level yet.
    Speak(*pmic, 8000);
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 25; }));
    CHECK(events.OfType("level").empty());

    // Two seconds in all: two levels, at the engine's times.
    Speak(*pmic, 24000);
    REQUIRE(WaitFor([&]() { return events.OfType("level").size() == 2; }));
    const std::vector<Json> levels = events.OfType("level");
    CHECK(levels[0]["t"].AsInt() == 1000);
    CHECK(levels[1]["t"].AsInt() == 2000);
    // The fake's tone is steady, about -15 dBFS.
    CHECK(levels[0]["rms"].AsInt() < -10);
    CHECK(levels[0]["rms"].AsInt() > -20);
    CHECK(levels[0]["max"].AsInt() == levels[0]["rms"].AsInt());

    // A part second at the end isn't reported; the mic's off line comes last.
    Speak(*pmic, 4000);
    session.Stop();
    CHECK(events.OfType("level").size() == 2);
    CHECK(events.OfType("mic").back()["state"].AsString() == "off");
}

TEST_CASE("ListenSession: records what the engine got", "[voice]")
{
    namespace fs = std::filesystem;
    const fs::path folder = fs::temp_directory_path() / "gitgud-record-test";
    fs::remove_all(folder);
    FakeVoiceEngine server;
    server.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            if (!_Message.m_bBinary &&
                Json::Parse(_Message.m_Data).value_or(Json())["type"].AsString() == "hello")
            {
                _Server.SendJson(Json::Object().Set("type", "ready").Set("version", 0));
            }
        });
    auto pclient = server.Links();
    auto pmic = std::make_shared<FakeCapture::State>();
    Events events;
    gitgud::voice::ListenSession session(pclient, events.Sink());
    REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pmic)));
    REQUIRE(WaitFor([&]() { return pmic->m_iStarts == 1; }));

    // Before recording: not saved.
    Speak(*pmic, 3200);
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 10; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(100)); // its send has returned
    std::string error;
    const fs::path first = folder / "a" / "one.wav";
    REQUIRE(session.Record(first.u8string(), error));
    Speak(*pmic, 6400);
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 30; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // A new file ends the first one.
    const fs::path second = folder / "two.wav";
    REQUIRE(session.Record(second.u8string(), error));
    REQUIRE(WaitFor([&]() { return events.OfType("record").size() == 1; }));
    CHECK(events.OfType("record")[0]["path"].AsString() == first.u8string());
    CHECK(events.OfType("record")[0]["seconds"].AsNumber() == 0.4);
    Speak(*pmic, 1600);
    REQUIRE(WaitFor([&]() { return server.BinaryCount() == 35; }));
    session.Stop(); // ends the second
    REQUIRE(events.OfType("record").size() == 2);
    CHECK(events.OfType("record")[1]["state"].AsString() == "off");
    CHECK(events.OfType("record")[1]["path"].AsString() == second.u8string());

    // Each file holds the frames the engine got while it was open, as sent.
    std::vector<std::string> frames;
    for (const Received& message : server.Messages())
    {
        if (message.m_bBinary)
        {
            frames.push_back(message.m_Data);
        }
    }
    REQUIRE(frames.size() == 35);
    const auto read = [](const fs::path& _File)
    {
        std::ifstream in(_File, std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    };
    std::string expect;
    for (std::size_t i = 10; i < 30; ++i)
    {
        expect += frames[i];
    }
    const std::string one = read(first);
    REQUIRE(one.size() == 44 + expect.size());
    CHECK(one.substr(0, 4) == "RIFF");
    CHECK(one.substr(44) == expect);
    expect.clear();
    for (std::size_t i = 30; i < 35; ++i)
    {
        expect += frames[i];
    }
    CHECK(read(second).substr(44) == expect);

    // A path that can't be written fails.
    CHECK_FALSE(session.Record(folder.u8string(), error));
    fs::remove_all(folder);
}

TEST_CASE("MakeFallbackCapture: keeps a capture that gives samples", "[voice]")
{
    auto pfirst = std::make_shared<FakeCapture::State>();
    auto psecond = std::make_shared<FakeCapture::State>();
    auto pcapture = gitgud::platform::MakeFallbackCapture(std::make_unique<FakeCapture>(pfirst),
        std::make_unique<FakeCapture>(psecond), std::chrono::milliseconds(500));
    std::atomic<std::size_t> nheard{0};
    std::string error;
    REQUIRE(pcapture->Start(
        16000, [&](const int16_t*, std::size_t _nCount) { nheard += _nCount; }, error));
    for (int i = 0; i < 10; ++i)
    {
        Speak(*pfirst, 160);
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(nheard == 1600);
    CHECK(psecond->m_iStarts == 0);
    CHECK(pcapture->Description() == "Test microphone");
    pcapture->Stop();
    CHECK(pfirst->m_iStops == 1);
    CHECK(pcapture->Description() == "Microphone (off)");

    // A first capture that can't start: the second at once, with why.
    pfirst->m_bFail = true;
    REQUIRE(pcapture->Start(16000, [](const int16_t*, std::size_t) {}, error));
    CHECK(psecond->m_iStarts == 1);
    CHECK(pcapture->Description() == "Microphone (no echo cancellation: no microphone here)");
    pcapture->Stop();
    CHECK(psecond->m_iStops == 1);

    // Neither: false, with both reasons.
    psecond->m_bFail = true;
    CHECK_FALSE(pcapture->Start(16000, [](const int16_t*, std::size_t) {}, error));
    CHECK(error == "no microphone here (echo cancellation: no microphone here)");
}

TEST_CASE("MakeFallbackCapture: each stage in turn until one gives samples", "[voice]")
{
    // The echo canceller three ways, then plain capture: the first two
    // start and stay silent, the third speaks.
    std::vector<std::shared_ptr<FakeCapture::State>> states;
    std::vector<std::unique_ptr<gitgud::platform::IAudioCapture>> stages;
    for (const char* szRoute : {"by index", "by index, no opt-out", "defaults", "plain"})
    {
        states.push_back(std::make_shared<FakeCapture::State>());
        states.back()->m_Route = szRoute;
        stages.push_back(std::make_unique<FakeCapture>(states.back()));
    }
    auto pcapture =
        gitgud::platform::MakeFallbackCapture(std::move(stages), std::chrono::milliseconds(150));
    std::atomic<std::size_t> nheard{0};
    std::string error;
    REQUIRE(pcapture->Start(
        16000, [&](const int16_t*, std::size_t _nCount) { nheard += _nCount; }, error));
    CHECK(pcapture->Route() == "by index");

    REQUIRE(WaitFor([&]() { return states[2]->m_iStarts == 1; }));
    CHECK(states[0]->m_iStops == 1);
    CHECK(states[1]->m_iStops == 1);
    // A later echo canceller is still one: Description says so, and the
    // route says which ran and what didn't before it.
    CHECK(pcapture->Description() == "Test microphone");
    CHECK(pcapture->Route() == "defaults; tried before: (by index): it gave no audio; "
                               "(by index, no opt-out): it gave no audio");
    // Speaking keeps it.
    for (int i = 0; i < 8; ++i)
    {
        Speak(*states[2], 160);
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    CHECK(nheard == 1280);
    CHECK(states[3]->m_iStarts == 0);
    // Then silence too: plain capture, and why the last canceller failed.
    REQUIRE(WaitFor([&]() { return states[3]->m_iStarts == 1; }));
    CHECK(pcapture->Description() == "Microphone (no echo cancellation: it stopped giving audio)");
    CHECK(pcapture->Route().find("plain; tried before: (by index)") == 0);
    CHECK(pcapture->Route().find("(defaults): it stopped giving audio") != std::string::npos);
    pcapture->Stop();
    CHECK(states[3]->m_iStops == 1);

    // A new start begins at the first again, with a clean slate.
    REQUIRE(pcapture->Start(16000, [](const int16_t*, std::size_t) {}, error));
    CHECK(states[0]->m_iStarts == 2);
    CHECK(pcapture->Route() == "by index");
    pcapture->Stop();
}

namespace
{

    // A link for SendQueue: records what it sends, and can hold a send
    // (an engine that stopped reading) or fail one.
    struct FakeSocket
    {
        std::mutex m_Mutex;
        std::condition_variable m_Changed;
        std::vector<std::string> m_Sent; // "T:text" or "B:data"
        bool m_bHold = false;            // sends wait while set
        int m_iInSend = 0;               // sends waiting
        int m_iFailAt = -1;              // this send (0-based) fails

        gitgud::voice::SendQueue::Send Sender()
        {
            return [this](bool _bBinary, const std::string& _Data)
            {
                std::unique_lock<std::mutex> lock(m_Mutex);
                ++m_iInSend;
                m_Changed.notify_all();
                m_Changed.wait(lock, [this]() { return !m_bHold; });
                --m_iInSend;
                if (static_cast<int>(m_Sent.size()) == m_iFailAt)
                {
                    return false;
                }
                m_Sent.push_back((_bBinary ? "B:" : "T:") + _Data);
                return true;
            };
        }

        void Hold(bool _bHold)
        {
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_bHold = _bHold;
            }
            m_Changed.notify_all();
        }

        std::vector<std::string> Sent()
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            return m_Sent;
        }

        int InSend()
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            return m_iInSend;
        }
    };

} // namespace

TEST_CASE("SendQueue: sends in order on its own thread", "[voice]")
{
    FakeSocket socket;
    gitgud::voice::SendQueue queue(100);
    queue.PushText("hello"); // queued before Start: goes first
    queue.Start(socket.Sender());
    queue.PushBinary("f0", 0);
    queue.PushBinary("f1", 20);
    queue.PushText("send");
    queue.PushBinary("f2", 40);
    REQUIRE(queue.Drain(std::chrono::seconds(5)));
    CHECK(socket.Sent() == std::vector<std::string>{"T:hello", "B:f0", "B:f1", "T:send", "B:f2"});
    CHECK(queue.DroppedTotal() == 0);
    CHECK(queue.TakeDrops().m_nCount == 0);
    CHECK_FALSE(queue.Failed());
    queue.Stop();
}

TEST_CASE("SendQueue: a stuck send never blocks the mic; the oldest frames go", "[voice]")
{
    FakeSocket socket;
    socket.Hold(true);
    gitgud::voice::SendQueue queue(10);
    queue.Start(socket.Sender());
    queue.PushBinary("f0", 0); // taken by the send that hangs
    REQUIRE(WaitFor([&]() { return socket.InSend() == 1; }));

    // Ten seconds of mic while the network holds: queueing never waits.
    const auto start = std::chrono::steady_clock::now();
    for (int i = 1; i <= 500; ++i)
    {
        queue.PushBinary("f" + std::to_string(i), static_cast<int64_t>(i) * 20);
        if (i == 250)
        {
            queue.PushText("send"); // control messages are never dropped
        }
    }
    CHECK(std::chrono::steady_clock::now() - start < std::chrono::seconds(1));
    CHECK(queue.QueuedBinary() == 10);
    CHECK(queue.Sending() > std::chrono::milliseconds(0));

    // f1 to f490 dropped, oldest first, with their times.
    const auto drops = queue.TakeDrops();
    CHECK(drops.m_nCount == 490);
    CHECK(drops.m_iFirstMs == 20);
    CHECK(drops.m_iLastMs == 490 * 20);
    CHECK(queue.TakeDrops().m_nCount == 0); // taken
    CHECK(queue.DroppedTotal() == 490);

    // The network takes data again: what's left goes, in order.
    socket.Hold(false);
    REQUIRE(queue.Drain(std::chrono::seconds(5)));
    std::vector<std::string> expected = {"B:f0", "T:send"};
    for (int i = 491; i <= 500; ++i)
    {
        expected.push_back("B:f" + std::to_string(i));
    }
    CHECK(socket.Sent() == expected);
    CHECK(queue.Sending() == std::chrono::milliseconds(0));
    queue.Stop();
}

TEST_CASE("SendQueue: a failed send stops sending; Clear starts afresh", "[voice]")
{
    FakeSocket socket;
    socket.m_iFailAt = 2;
    gitgud::voice::SendQueue queue(100);
    queue.Start(socket.Sender());
    for (int i = 0; i < 5; ++i)
    {
        queue.PushBinary("f" + std::to_string(i), i * 20);
    }
    REQUIRE(WaitFor([&]() { return queue.Failed(); }));
    CHECK_FALSE(queue.Drain(std::chrono::milliseconds(100))); // f3 and f4 wait
    CHECK(socket.Sent() == std::vector<std::string>{"B:f0", "B:f1"});
    CHECK(queue.QueuedBinary() == 2);
    queue.Stop();

    queue.Clear();
    CHECK(queue.QueuedBinary() == 0);
    CHECK_FALSE(queue.Failed());
    socket.m_iFailAt = -1;
    queue.Start(socket.Sender());
    queue.PushText("again");
    REQUIRE(queue.Drain(std::chrono::seconds(5)));
    CHECK(socket.Sent().back() == "T:again");
    queue.Stop();
}

TEST_CASE("ListenSession: a refused link and an engine that goes away", "[voice]")
{
    FakeVoiceEngine server;
    auto pclient = server.Links();
    auto pmic = std::make_shared<FakeCapture::State>();

    SECTION("refused")
    {
        server.Refuse(1, "no models");
        Events events;
        gitgud::voice::ListenSession session(pclient, events.Sink());
        REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pmic)));
        REQUIRE(WaitFor([&]() { return events.Has("closed"); }));
        const Json error = events.OfType("error").at(0);
        CHECK(error["code"].AsString() == "connect");
        CHECK(error["message"].AsString() == "no models");
        CHECK(pmic->m_iStarts == 0);
    }

    SECTION("the engine closes")
    {
        server.SetOnMessage(
            [](FakeVoiceEngine& _Server, const Received& _Message)
            {
                if (!_Message.m_bBinary)
                {
                    _Server.SendJson(Json::Object().Set("type", "ready").Set("version", 0));
                    return;
                }
                _Server.SendJson(Json::Object()
                        .Set("type", "error")
                        .Set("code", "shutting-down")
                        .Set("message", "restart"));
                _Server.SendClose(1001);
            });
        Events events;
        gitgud::voice::ListenSession session(pclient, events.Sink());
        REQUIRE(session.Start(Json::Object(), std::make_unique<FakeCapture>(pmic)));
        REQUIRE(WaitFor([&]() { return pmic->m_iStarts == 1; }));
        Speak(*pmic, 320);
        REQUIRE(WaitFor([&]() { return events.Has("closed"); }));
        CHECK(events.OfType("error").at(0)["code"].AsString() == "shutting-down");
        CHECK(events.OfType("closed")[0]["code"].AsInt() == 1001);
        CHECK(pmic->m_iStops == 1);
        REQUIRE(WaitFor([&]() { return !session.Running(); }));
    }
}

TEST_CASE("SpeakSession: text up, speech down into the speaker", "[voice]")
{
    FakeVoiceEngine server;
    server.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            const Json message = Json::Parse(_Message.m_Data).value_or(Json());
            if (message["type"].AsString() != "say")
            {
                return;
            }
            const std::string& id = message["id"].AsString();
            // 16 kHz on request, so the speaker's 24 kHz needs resampling.
            _Server.SendJson(
                Json::Object().Set("type", "start").Set("id", id).Set("sampleRate", 16000));
            const std::vector<int16_t> tone(320, 1200);
            _Server.SendBinary(gitgud::voice::ToBytes(tone.data(), tone.size()));
            _Server.SendBinary(gitgud::voice::ToBytes(tone.data(), tone.size()));
            _Server.SendJson(Json::Object().Set("type", "end").Set("id", id));
        });
    auto pclient = server.Links();
    auto pspeaker = std::make_shared<FakePlayback::State>();
    Events events;
    {
        gitgud::voice::SpeakSession session(
            pclient, events.Sink(), std::make_unique<FakePlayback>(pspeaker));
        CHECK_FALSE(session.Running());
        session.Say("r1", "All tests pass.", "", 16000);
        REQUIRE(WaitFor([&]() { return events.OfType("playback").size() == 2; }));
        CHECK(server.Path() == "speak");
        const Json say = server.OfType("say").at(0);
        CHECK(say["id"].AsString() == "r1");
        CHECK(say["text"].AsString() == "All tests pass.");
        CHECK(say["sampleRate"].AsInt() == 16000);
        CHECK_FALSE(say.Has("voice"));

        CHECK(pspeaker->m_iRate == 24000);
        {
            std::lock_guard<std::mutex> lock(pspeaker->m_Mutex);
            // 640 samples at 16 kHz are about 960 at 24 kHz.
            CHECK(pspeaker->m_Played.size() >= 957);
            CHECK(pspeaker->m_Played.size() <= 960);
            CHECK(std::all_of(pspeaker->m_Played.begin(), pspeaker->m_Played.end(),
                [](int16_t _Sample) { return _Sample == 1200; }));
        }
        const std::vector<Json> playback = events.OfType("playback");
        CHECK(playback[0]["state"].AsString() == "started");
        CHECK(playback[0]["id"].AsString() == "r1");
        CHECK(playback[1]["state"].AsString() == "stopped");
        CHECK(playback[1]["id"].AsString() == "r1");
        CHECK(events.OfType("start").size() == 1);
        CHECK(events.OfType("end").size() == 1);
        CHECK(session.PlayingId().empty());

        // A second reply on the same socket; then stop everything.
        session.Say("r2", "Again.", "narrator", 0, 1.15);
        REQUIRE(WaitFor([&]() { return events.OfType("end").size() == 2; }));
        CHECK(server.OfType("say").at(1)["voice"].AsString() == "narrator");
        CHECK_FALSE(server.OfType("say").at(1).Has("sampleRate"));
        CHECK(server.OfType("say").at(1)["speed"].AsNumber() > 1.149);
        CHECK(server.OfType("say").at(1)["speed"].AsNumber() < 1.151);
        CHECK_FALSE(server.OfType("say").at(0).Has("speed"));
        CHECK(server.Connections() == 1);
        session.StopSpeech();
        REQUIRE(WaitFor([&]() { return !server.OfType("stop").empty(); }));
        CHECK_FALSE(server.OfType("stop").at(0).Has("id"));
        CHECK(pspeaker->m_iFlushes >= 1);
    }
    CHECK(pspeaker->m_bStopped);
    REQUIRE(WaitFor([&]() { return server.ClientCloseCode() == 1000; }));
    CHECK(events.OfType("closed").size() == 1);
}

TEST_CASE("Voice bindings: scripts listen and speak; events reach the bus", "[voice][lua]")
{
    FakeVoiceEngine listenEngine;
    listenEngine.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            const Json message = Json::Parse(_Message.m_Data).value_or(Json());
            if (message["type"].AsString() == "hello")
            {
                _Server.SendJson(Json::Object().Set("type", "ready").Set("version", 0));
            }
            else if (message["type"].AsString() == "send")
            {
                _Server.SendJson(Json::Object()
                        .Set("type", "message")
                        .Set("text", "Bragi, commit it")
                        .Set("endedBy", "send"));
            }
        });
    auto pclient = listenEngine.Links();
    auto pmic = std::make_shared<FakeCapture::State>();
    auto pspeaker = std::make_shared<FakePlayback::State>();
    gitgud::lua::bindings::SetVoiceAudio([pmic]() { return std::make_unique<FakeCapture>(pmic); },
        [pspeaker]() { return std::make_unique<FakePlayback>(pspeaker); });

    gitgud::app::EventBus bus;
    std::vector<gitgud::app::AppEvent> seen;
    bus.Subscribe("*", [&](const gitgud::app::AppEvent& _Event) { seen.push_back(_Event); });
    gitgud::lua::LuaEngine engine;
    REQUIRE(engine.Initialize());
    engine.Bind(nullptr, &bus, nullptr, nullptr, nullptr);
    // No engine (not even the app's own, whose libraries may be beside the
    // test exe).
    gitgud::lua::bindings::SetVoiceLink(nullptr);
    REQUIRE(engine.Eval(R"(
        assert(gitgud.voiceInfo().available == false)
        local no, why = gitgud.voiceListen()
        assert(no == nil and why == "Voice isn't available")
        assert(gitgud.voiceSpeak("s0", "Hi") == nil)
    )"));
    gitgud::lua::bindings::SetVoiceLink(pclient);

    auto drainUntil = [&](const std::string& _Type)
    {
        return WaitFor(
            [&]()
            {
                bus.Drain();
                return std::any_of(seen.begin(), seen.end(),
                    [&](const gitgud::app::AppEvent& _Event) { return _Event.m_Type == _Type; });
            });
    };

    REQUIRE(engine.Eval(R"(
        local off, why = gitgud.voiceSend()
        assert(off == nil and why == "Voice input is off")
        assert(gitgud.voiceListen({ wakeWord = "Bragi", mishearings = { "groggy" } }))
        local again, msg = gitgud.voiceListen()
        assert(again == nil and msg:find("already"))
        local bad = gitgud.voiceTrain("sideways")
        assert(bad == nil)
    )"));
    REQUIRE(drainUntil("voice.ready"));
    REQUIRE(drainUntil("voice.mic"));
    const Json hello = listenEngine.OfType("hello").at(0);
    CHECK(hello["mishearings"][0].AsString() == "groggy");
    REQUIRE(engine.Eval(R"(
        local info = gitgud.voiceInfo()
        assert(info.available and info.listening == true and info.speaking == false)
        assert(gitgud.voiceSend())
        assert(gitgud.voiceLookback("l1", 120))
    )"));
    REQUIRE(drainUntil("voice.message"));
    REQUIRE(WaitFor([&]() { return !listenEngine.OfType("lookback").empty(); }));
    CHECK(listenEngine.OfType("lookback").at(0)["tokens"].AsInt() == 120);

    // Speech goes to the same (fake) engine, whose speak half answers too.
    listenEngine.SetOnMessage(nullptr);
    REQUIRE(engine.Eval(R"(gitgud.voiceStop())"));
    REQUIRE(drainUntil("voice.closed"));
    CHECK(pmic->m_iStops == 1);
    listenEngine.SetOnMessage(
        [](FakeVoiceEngine& _Server, const Received& _Message)
        {
            const Json message = Json::Parse(_Message.m_Data).value_or(Json());
            if (message["type"].AsString() == "say")
            {
                _Server.SendJson(Json::Object()
                        .Set("type", "start")
                        .Set("id", message["id"])
                        .Set("sampleRate", 24000));
                const std::vector<int16_t> tone(480, 7);
                _Server.SendBinary(gitgud::voice::ToBytes(tone.data(), tone.size()));
                _Server.SendJson(Json::Object().Set("type", "end").Set("id", message["id"]));
            }
        });
    REQUIRE(engine.Eval(R"(assert(gitgud.voiceSpeak("s1", "Done.", { voice = "default" })))"));
    REQUIRE(drainUntil("voice.speech.end"));
    REQUIRE(drainUntil("voice.playback"));
    {
        std::lock_guard<std::mutex> lock(pspeaker->m_Mutex);
        CHECK(pspeaker->m_Played.size() == 480);
    }
    REQUIRE(engine.Eval(R"(gitgud.voiceSpeakStop())"));

    gitgud::lua::bindings::SetVoiceLink({});
    gitgud::lua::bindings::SetVoiceAudio({}, {});
}
