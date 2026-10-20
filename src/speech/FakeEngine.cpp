#include "speech/FakeEngine.h"

#include "app/Json.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <vector>
#include <deque>
#include <mutex>
#include <thread>

namespace gitgud::speech
{

    using app::Json;

    namespace
    {

        class FakeLink : public voice::ILink
        {
          public:
            FakeLink(std::string _Channel, bool _bFault)
                : m_Channel(std::move(_Channel)), m_bFault(_bFault)
            {
            }

            ~FakeLink() override
            {
                Close();
            }

            bool Open(OnMessage _OnMessage, OnClose _OnClose, std::string& _Error) override
            {
                (void)_Error;
                m_OnMessage = std::move(_OnMessage);
                m_OnClose = std::move(_OnClose);
                m_Thread = std::thread([this]() { Loop(); });
                return true;
            }

            bool SendText(const std::string& _Text) override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                if (m_bQuit)
                {
                    return false;
                }
                m_In.push_back(_Text);
                m_Wake.notify_all();
                return true;
            }

            bool SendBinary(const void*, std::size_t) override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                return !m_bQuit;
            }

            std::string LastSendError() const override
            {
                return {};
            }

            void Close() override
            {
                {
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    if (m_bQuit && !m_Thread.joinable())
                    {
                        return;
                    }
                    m_bQuit = true;
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
                Closed(1000, "closed");
            }

          private:
            void Closed(int _iCode, const std::string& _Reason)
            {
                std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                m_OnMessage = nullptr;
                if (OnClose onClose = std::move(m_OnClose))
                {
                    m_OnClose = nullptr;
                    onClose(_iCode, _Reason);
                }
            }

            void Send(const Json& _Message)
            {
                std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                if (m_OnMessage)
                {
                    m_OnMessage(false, _Message.Dump());
                }
            }

            void SendPcm(const std::string& _Pcm)
            {
                std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                if (m_OnMessage)
                {
                    m_OnMessage(true, _Pcm);
                }
            }

            void Loop()
            {
                for (;;)
                {
                    std::string text;
                    {
                        std::unique_lock<std::mutex> lock(m_Mutex);
                        m_Wake.wait(lock, [this]() { return m_bQuit || !m_In.empty(); });
                        if (m_bQuit)
                        {
                            return;
                        }
                        text = std::move(m_In.front());
                        m_In.pop_front();
                    }
                    const std::optional<Json> parsed = Json::Parse(text);
                    if (parsed && parsed->IsObject())
                    {
                        if (m_Channel == "listen")
                        {
                            if (!Listen(*parsed))
                            {
                                return;
                            }
                        }
                        else
                        {
                            Speak(*parsed);
                        }
                    }
                }
            }

            // False: the link closed.
            bool Listen(const Json& _Message)
            {
                const std::string& type = _Message["type"].AsString();
                if (type == "hello")
                {
                    if (m_bFault)
                    {
                        Send(Json::Object()
                                .Set("type", "error")
                                .Set("code", "engine-fault")
                                .Set("message", "transcribe failed with exception 0xC0000005")
                                .Set("restart", true));
                        Closed(1011, "the speech engine stopped");
                        std::lock_guard<std::mutex> lock(m_Mutex);
                        m_bQuit = true;
                        return false;
                    }
                    Send(Json::Object()
                            .Set("type", "ready")
                            .Set("version", 0)
                            .Set("stt", Json::Object()
                                            .Set("provider", "test")
                                            .Set("model", "test")
                                            .Set("device", "cpu"))
                            .Set("keywords", true)
                            .Set("vocabulary", true)
                            .Set("speaker", Json::Object().Set("enrolled", false)));
                }
                else if (type == "wake")
                {
                    m_Id = "m" + std::to_string(++m_iCount);
                    Send(Json::Object()
                            .Set("type", "wake")
                            .Set("id", m_Id)
                            .Set("t", 0)
                            .Set("t0", 0));
                }
                else if (type == "send")
                {
                    if (m_Id.empty())
                    {
                        Send(Json::Object()
                                .Set("type", "error")
                                .Set("code", "no-message")
                                .Set("message", "no message to send"));
                        return true;
                    }
                    const char* sztext = std::getenv("GITGUD_TEST_VOICE_TEXT");
                    const std::string reason = _Message["reason"].AsString("button");
                    Send(Json::Object()
                            .Set("type", "message")
                            .Set("id", m_Id)
                            .Set("text", sztext && *sztext ? sztext : "hello from the test engine")
                            .Set("endedBy", reason == "done" ? "done" : "send")
                            .Set("t0", 0)
                            .Set("t1", 1000)
                            .Set("wakeAt", 0)
                            .Set("context", Json::Array()));
                    m_Id.clear();
                }
                else if (type == "cancel")
                {
                    if (!m_Id.empty())
                    {
                        Send(Json::Object().Set("type", "cancelled").Set("id", m_Id));
                        m_Id.clear();
                    }
                }
                else if (type == "lookback")
                {
                    Send(Json::Object()
                            .Set("type", "lookback")
                            .Set("id", _Message["id"])
                            .Set("segments", Json::Array()));
                }
                else if (type == "train" && _Message["state"].AsString() == "stop")
                {
                    Send(Json::Object()
                            .Set("type", "trainResult")
                            .Set("samples", 0)
                            .Set("mishearings", Json::Array())
                            .Set("threshold", 0.25));
                }
                else if (type == "enroll" && _Message["state"].AsString() != "start")
                {
                    Send(Json::Object()
                            .Set("type", "enrollResult")
                            .Set("samples", 0)
                            .Set("seconds", 0)
                            .Set("enrolled", false)
                            .Set("reason", "too-short"));
                }
                return true;
            }

            void Speak(const Json& _Message)
            {
                const std::string& type = _Message["type"].AsString();
                const std::string& id = _Message["id"].AsString();
                if (type == "say")
                {
                    Send(Json::Object()
                            .Set("type", "start")
                            .Set("id", id)
                            .Set("sampleRate", 24000)
                            .Set("provider", "test"));
                    SendPcm(std::string(4800, '\0'));
                    Send(Json::Object().Set("type", "end").Set("id", id));
                }
                else if (type == "stop")
                {
                    Send(Json::Object().Set("type", "stopped").Set("id", id));
                }
            }

            const std::string m_Channel;
            const bool m_bFault;
            std::mutex m_Mutex;
            std::condition_variable m_Wake;
            std::deque<std::string> m_In;
            bool m_bQuit = false;
            std::thread m_Thread;
            std::recursive_mutex m_CallbackMutex;
            OnMessage m_OnMessage;
            OnClose m_OnClose;
            std::string m_Id;
            int m_iCount = 0;
        };

    } // namespace

    namespace
    {

        class QuietCapture : public platform::IAudioCapture
        {
          public:
            ~QuietCapture() override
            {
                Stop();
            }

            bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) override
            {
                (void)_Error;
                Stop();
                m_bRun = true;
                const std::size_t nframe = static_cast<std::size_t>(_iSampleRate / 50);
                m_Thread = std::thread(
                    [this, nframe, onSamples = std::move(_OnSamples)]()
                    {
                        const std::vector<int16_t> quiet(nframe, 0);
                        auto next = std::chrono::steady_clock::now();
                        while (m_bRun)
                        {
                            onSamples(quiet.data(), quiet.size());
                            next += std::chrono::milliseconds(20);
                            std::this_thread::sleep_until(next);
                        }
                    });
                return true;
            }

            void Stop() override
            {
                m_bRun = false;
                if (m_Thread.joinable())
                {
                    m_Thread.join();
                }
            }

            std::string Description() const override
            {
                return "Test microphone (quiet)";
            }

          private:
            std::atomic<bool> m_bRun{false};
            std::thread m_Thread;
        };

        class QuietPlayback : public platform::IAudioPlayback
        {
          public:
            bool Start(int _iSampleRate, std::string& _Error) override
            {
                (void)_Error;
                m_iRate = _iSampleRate;
                return true;
            }

            void Stop() override
            {
            }

            int SampleRate() const override
            {
                return m_iRate;
            }

            void Enqueue(const int16_t*, std::size_t) override
            {
            }

            void Flush() override
            {
            }

            std::size_t Queued() const override
            {
                return 0;
            }

          private:
            int m_iRate = 24000;
        };

    } // namespace

    std::unique_ptr<platform::IAudioCapture> MakeQuietCapture()
    {
        return std::make_unique<QuietCapture>();
    }

    std::unique_ptr<platform::IAudioPlayback> MakeQuietPlayback()
    {
        return std::make_unique<QuietPlayback>();
    }

    std::unique_ptr<voice::ILink> MakeFakeLink(const std::string& _Channel, bool _bFault)
    {
        if (_Channel != "listen" && _Channel != "speak")
        {
            return nullptr;
        }
        return std::make_unique<FakeLink>(_Channel, _bFault);
    }

} // namespace gitgud::speech
