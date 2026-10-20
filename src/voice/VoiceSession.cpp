#include "voice/VoiceSession.h"

#include <cmath>
#include <utility>
#include <vector>

namespace gitgud::voice
{

    using app::Json;

    namespace
    {

        // One mic frame's length, in ms.
        constexpr int64_t kFrameMs = static_cast<int64_t>(kFrameSamples) * 1000 / kListenRate;

        Json Message(const char* _szType)
        {
            return Json::Object().Set("type", _szType);
        }

        Json LocalError(const char* _szCode, const std::string& _Message)
        {
            return Message("error").Set("code", _szCode).Set("message", _Message);
        }

    } // namespace

    // ---- Channel ------------------------------------------------------------

    Channel::Channel(LinkFactory _MakeLink, std::string _Channel, OnEvent _OnEvent,
        std::size_t _nMaxQueuedBinary)
        : m_MakeLink(std::move(_MakeLink)), m_Channel(std::move(_Channel)),
          m_OnEvent(std::move(_OnEvent)), m_Sends(_nMaxQueuedBinary)
    {
    }

    Channel::~Channel()
    {
        Stop();
    }

    bool Channel::Running() const
    {
        return m_bRunning;
    }

    bool Channel::Begin()
    {
        if (m_bRunning)
        {
            return false;
        }
        if (m_Thread.joinable())
        {
            m_Thread.join(); // the last run ended on its own
        }
        m_Sends.Clear();
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_SendError.clear();
            m_bSendReported = false;
            m_bStop = false;
            m_bClosed = false;
            m_iCloseCode = 0;
            m_CloseReason.clear();
        }
        m_bRunning = true;
        m_Thread = std::thread([this]() { Loop(); });
        return true;
    }

    void Channel::Stop()
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bStop = true;
        }
        m_Wake.notify_all();
        if (m_Thread.joinable() && m_Thread.get_id() != std::this_thread::get_id())
        {
            m_Thread.join();
        }
    }

    void Channel::RequestStop()
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_bStop = true;
    }

    bool Channel::Stopping() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_bStop;
    }

    void Channel::QueueText(const Json& _Message)
    {
        m_Sends.PushText(_Message.Dump());
    }

    void Channel::QueueBinary(std::string _Data, int64_t _iMs)
    {
        m_Sends.PushBinary(std::move(_Data), _iMs);
    }

    void Channel::Emit(const Json& _Event) const
    {
        if (m_OnEvent)
        {
            m_OnEvent(_Event);
        }
    }

    void Channel::ReportSendFailure()
    {
        std::string error;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (m_bSendReported || m_SendError.empty())
            {
                return;
            }
            m_bSendReported = true;
            error = m_SendError;
        }
        Emit(LocalError("send", error));
    }

    void Channel::Loop()
    {
        m_pLink = m_MakeLink ? m_MakeLink(m_Channel) : nullptr;
        std::string error = m_pLink ? std::string() : std::string("Voice isn't available");
        const bool bopen = m_pLink && m_pLink->Open(
            [this](bool _bBinary, const std::string& _Data)
            {
                if (_bBinary)
                {
                    OnBinary(_Data);
                    return;
                }
                std::optional<Json> parsed = Json::Parse(_Data);
                if (parsed && parsed->GetType() == Json::Type::Object)
                {
                    OnText(*parsed);
                }
            },
            [this](int _iCode, const std::string& _Reason)
            {
                {
                    // The first reason stands: a session ended by a failed
                    // send closes the link itself.
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    if (!m_bClosed)
                    {
                        m_bClosed = true;
                        m_iCloseCode = _iCode;
                        m_CloseReason = _Reason;
                    }
                }
                m_Wake.notify_all();
            },
            error);
        if (!bopen)
        {
            if (m_pLink)
            {
                m_pLink->Close();
                m_pLink.reset();
            }
            Emit(LocalError("connect", error));
            Emit(Message("closed").Set("code", 0).Set("reason", error));
            m_bRunning = false;
            return;
        }

        // Sends run on the queue's thread: a send the link holds up (an
        // engine that stopped reading) stalls only that thread, while
        // ticks, events, and the mic carry on (and the mic's oldest frames
        // are dropped past the cap).
        m_Sends.Start(
            [this](bool _bBinary, const std::string& _Data)
            {
                const auto start = std::chrono::steady_clock::now();
                const bool bsent = _bBinary ? m_pLink->SendBinary(_Data.data(), _Data.size())
                                            : m_pLink->SendText(_Data);
                if (bsent)
                {
                    OnSent(_bBinary, _Data);
                }
                const std::string error = bsent ? std::string() : m_pLink->LastSendError();
                if (!error.empty())
                {
                    const auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - start);
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_SendError = error + " after " + std::to_string(waited.count()) + " ms";
                }
                return bsent;
            });
        OnOpen();
        for (;;)
        {
            OnTick();
            ReportSendFailure();
            const bool bsendFailed = m_Sends.Failed();
            std::unique_lock<std::mutex> lock(m_Mutex);
            if (bsendFailed && !m_bClosed)
            {
                // Nothing more can go out: end the session rather than
                // listen on with the mic's audio piling up.
                m_bClosed = true;
                m_iCloseCode = 1006;
                m_CloseReason = m_SendError.empty() ? std::string("sending failed") : m_SendError;
            }
            m_Wake.wait_for(
                lock, std::chrono::milliseconds(20), [this]() { return m_bStop || m_bClosed; });
            if (m_bStop || m_bClosed)
            {
                break;
            }
        }
        OnEnd();
        // A last `send` or `stop` still goes out, unless the link is stuck:
        // then Close cuts it rather than wait it out.
        m_Sends.Drain(std::chrono::seconds(2));
        m_pLink->Close();
        m_Sends.Stop();
        m_pLink.reset();
        ReportSendFailure();
        OnStopped();

        int icode = 0;
        std::string reason;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            icode = m_iCloseCode;
            reason = m_CloseReason;
        }
        Emit(Message("closed").Set("code", icode).Set("reason", reason));
        m_bRunning = false;
    }

    // ---- ListenSession ------------------------------------------------------

    ListenSession::ListenSession(LinkFactory _MakeLink, OnEvent _OnEvent)
        : Channel(std::move(_MakeLink), "listen", std::move(_OnEvent),
              kMaxQueuedFrames)
    {
    }

    ListenSession::~ListenSession()
    {
        Stop();
    }

    Json ListenSession::Hello(const Json& _Fields)
    {
        // The values below are fallbacks for a caller that leaves a field
        // out; the script decides them (the Bragi UI's bragi/voice.lua sends
        // its wake word, closing phrase, lookbackTokens and endWaitSeconds,
        // the last from the bragi.endWaitSeconds setting).
        Json hello = Message("hello")
                         .Set("version", 0)
                         .Set("client", "GitGud")
                         .Set("sampleRate", kListenRate)
                         .Set("wakeWord", "Bragi")
                         .Set("closingPhrase", "over and out")
                         .Set("contextTokens", 1000)
                         .Set("messageContextTokens", 0)
                         .Set("lookbackTokens", 5000)
                         .Set("endWaitSeconds", 3)
                         .Set("mishearings", Json::Array());
        if (_Fields.GetType() == Json::Type::Object)
        {
            for (const std::string& key : _Fields.Keys())
            {
                hello.Set(key, _Fields[key]);
            }
        }
        // Fixed by the protocol, whatever the caller said.
        hello.Set("type", "hello").Set("version", 0).Set("sampleRate", kListenRate);
        return hello;
    }

    bool ListenSession::Start(
        const Json& _Hello, std::unique_ptr<platform::IAudioCapture> _pCapture)
    {
        if (Running() || !_pCapture)
        {
            return false;
        }
        m_Hello = Hello(_Hello);
        m_pCapture = std::move(_pCapture);
        m_bReady = false;
        m_bCapturing = false;
        m_nSamples = 0;
        m_nFrames = 0;
        m_bSilentWarned = false;
        {
            std::lock_guard<std::mutex> lock(m_FrameMutex);
            m_Framer.Clear();
            m_LevelLog.Clear();
            m_Levels.clear();
        }
        return Begin();
    }

    void ListenSession::SetReadyTimeout(std::chrono::milliseconds _Timeout)
    {
        m_ReadyTimeout = _Timeout;
    }

    void ListenSession::SetSilentTimeout(std::chrono::milliseconds _Timeout)
    {
        m_SilentTimeout = _Timeout;
    }

    std::size_t ListenSession::DroppedFrames() const
    {
        return Sends().DroppedTotal();
    }

    void ListenSession::Config(const Json& _Fields)
    {
        Json config = Message("config");
        if (_Fields.GetType() == Json::Type::Object)
        {
            for (const std::string& key : _Fields.Keys())
            {
                if (key != "type")
                {
                    config.Set(key, _Fields[key]);
                }
            }
        }
        QueueText(config);
    }

    void ListenSession::Wake()
    {
        QueueText(Message("wake"));
    }

    void ListenSession::SendNow(const std::string& _Reason)
    {
        Json send = Message("send");
        if (!_Reason.empty())
        {
            send.Set("reason", _Reason);
        }
        QueueText(send);
    }

    void ListenSession::Cancel()
    {
        QueueText(Message("cancel"));
    }

    void ListenSession::Playback(const std::string& _State, const std::string& _Id, const std::string& _Text)
    {
        Json playback = Message("playback").Set("state", _State).Set("id", _Id);
        if (!_Text.empty())
        {
            playback.Set("text", _Text);
        }
        QueueText(playback);
    }

    void ListenSession::Lookback(const std::string& _Id, int _iTokens)
    {
        Json lookback = Message("lookback").Set("id", _Id);
        if (_iTokens >= 0)
        {
            lookback.Set("tokens", _iTokens);
        }
        QueueText(lookback);
    }

    void ListenSession::Train(const std::string& _State)
    {
        QueueText(Message("train").Set("state", _State));
    }

    void ListenSession::Enroll(const std::string& _State)
    {
        QueueText(Message("enroll").Set("state", _State));
    }

    Json ListenSession::MicOn(const std::string& _Device, const std::string& _Route) const
    {
        Json event = Message("mic").Set("state", "on").Set("device", _Device);
        // Which devices, and whether other apps' audio is left alone.
        if (!_Route.empty())
        {
            event.Set("route", _Route);
        }
        return event;
    }

    void ListenSession::OnOpen()
    {
        QueueText(m_Hello);
        m_HelloSent = std::chrono::steady_clock::now();
    }

    void ListenSession::EmitLevels()
    {
        std::vector<SecondLevel> levels;
        {
            std::lock_guard<std::mutex> lock(m_FrameMutex);
            levels.swap(m_Levels);
        }
        for (const SecondLevel& level : levels)
        {
            Emit(Message("level")
                    .Set("t", level.m_iEndMs)
                    .Set("rms", level.m_iRmsDb)
                    .Set("max", level.m_iMaxDb));
        }
    }

    void ListenSession::EmitDrops(bool _bNow)
    {
        const auto now = std::chrono::steady_clock::now();
        if (!_bNow && now - m_LastDrop < std::chrono::seconds(1))
        {
            return; // the next one gathers these too
        }
        const SendQueue::Drops drops = Sends().TakeDrops();
        if (drops.m_nCount == 0)
        {
            return;
        }
        m_LastDrop = now;
        Emit(Message("drop")
                .Set("t", drops.m_iFirstMs)
                .Set("until", drops.m_iLastMs + kFrameMs)
                .Set("count", static_cast<int64_t>(drops.m_nCount))
                .Set("queued", static_cast<int64_t>(Sends().QueuedBinary()))
                .Set("sendingMs", static_cast<int64_t>(Sends().Sending().count())));
    }

    void ListenSession::OnTick()
    {
        if (m_bCapturing)
        {
            // Here, not on the capture thread, so events keep one order.
            EmitLevels();
            EmitDrops(false);
            // The capture can change under us (echo cancellation failing
            // over to another setup, or to plain capture): say so.
            const std::string device = m_pCapture->Description();
            const std::string route = m_pCapture->Route();
            if (device != m_MicDevice || route != m_MicRoute)
            {
                m_MicDevice = device;
                m_MicRoute = route;
                Emit(MicOn(device, route));
            }
            if (!m_bSilentWarned && m_nSamples == 0 &&
                std::chrono::steady_clock::now() - m_MicOn > m_SilentTimeout)
            {
                m_bSilentWarned = true;
                Emit(LocalError("no-audio", "The microphone gives no sound (" + device + ")"));
            }
            return;
        }
        if (!m_bReady)
        {
            if (std::chrono::steady_clock::now() - m_HelloSent > m_ReadyTimeout)
            {
                Emit(LocalError("no-ready", "The voice service did not answer hello"));
                RequestStop();
            }
            return;
        }
        // Times start at the first frame, so the mic opens only now.
        std::string error;
        if (!m_pCapture->Start(
                kListenRate, [this](const int16_t* _pSamples, std::size_t _nCount)
                { OnSamples(_pSamples, _nCount); }, error))
        {
            Emit(LocalError("audio", error));
            RequestStop();
            return;
        }
        m_bCapturing = true;
        m_MicOn = std::chrono::steady_clock::now();
        m_MicDevice = m_pCapture->Description();
        m_MicRoute = m_pCapture->Route();
        Emit(MicOn(m_MicDevice, m_MicRoute));
    }

    void ListenSession::OnEnd()
    {
        if (m_bCapturing)
        {
            const std::string device = m_pCapture->Description();
            m_pCapture->Stop();
            m_bCapturing = false;
            EmitLevels();
            EmitDrops(true);
            // What reached the link's queue, so a silent session shows.
            const double dseconds =
                static_cast<double>(m_nSamples) / static_cast<double>(kListenRate);
            Emit(Message("mic")
                    .Set("state", "off")
                    .Set("device", device)
                    .Set("seconds", std::round(dseconds * 10.0) / 10.0)
                    .Set("frames", m_nFrames.load())
                    .Set("dropped", static_cast<int64_t>(DroppedFrames())));
        }
    }

    void ListenSession::OnSamples(const int16_t* _pSamples, std::size_t _nCount)
    {
        std::vector<std::string> frames;
        m_nSamples += _nCount;
        {
            std::lock_guard<std::mutex> lock(m_FrameMutex);
            m_Framer.Push(_pSamples, _nCount, frames);
            // A second's loudness, for the log: whether a quiet stretch
            // was a quiet voice or the engine hearing silence.
            m_LevelLog.Push(_pSamples, _nCount, m_Levels);
        }
        // Only queued: the queue's thread sends, and drops the oldest frames
        // past kMaxQueuedFrames, so this never waits on the link.
        for (std::string& frame : frames)
        {
            const int64_t ims = static_cast<int64_t>(m_nFrames++) * kFrameMs;
            QueueBinary(std::move(frame), ims);
        }
    }

    void ListenSession::OnText(const Json& _Message)
    {
        if (_Message["type"].AsString() == "ready")
        {
            m_bReady = true;
        }
        Emit(_Message);
    }

    void ListenSession::OnBinary(const std::string&)
    {
        // The listen link sends no audio down.
    }

    bool ListenSession::Record(const std::string& _Path, std::string& _Error)
    {
        StopRecording();
        std::lock_guard<std::mutex> lock(m_RecordMutex);
        return m_Recording.Open(_Path, kListenRate, _Error);
    }

    void ListenSession::StopRecording()
    {
        std::string path;
        double dseconds = 0.0;
        {
            std::lock_guard<std::mutex> lock(m_RecordMutex);
            if (!m_Recording.IsOpen())
            {
                return;
            }
            path = m_Recording.Path();
            dseconds = static_cast<double>(m_Recording.DataBytes()) / 2.0 / kListenRate;
            m_Recording.Close();
        }
        Emit(Message("record")
                .Set("state", "off")
                .Set("path", path)
                .Set("seconds", std::round(dseconds * 10.0) / 10.0));
    }

    void ListenSession::OnSent(bool _bBinary, const std::string& _Data)
    {
        if (!_bBinary)
        {
            return;
        }
        std::lock_guard<std::mutex> lock(m_RecordMutex);
        m_Recording.Write(_Data);
    }

    void ListenSession::OnStopped()
    {
        StopRecording();
    }

    // ---- SpeakSession -------------------------------------------------------

    SpeakSession::SpeakSession(LinkFactory _MakeLink, OnEvent _OnEvent,
        std::unique_ptr<platform::IAudioPlayback> _pPlayback)
        : Channel(std::move(_MakeLink), "speak", std::move(_OnEvent)),
          m_pPlayback(std::move(_pPlayback))
    {
    }

    SpeakSession::~SpeakSession()
    {
        Stop();
    }

    void SpeakSession::Say(const std::string& _Id, const std::string& _Text,
        const std::string& _Voice, int _iSampleRate, double _fSpeed)
    {
        Begin(); // no-op while connected
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_SayTexts[_Id] = _Text;
            while (m_SayTexts.size() > 32)
            {
                m_SayTexts.erase(m_SayTexts.begin());
            }
        }
        Json say = Message("say").Set("id", _Id).Set("text", _Text);
        if (!_Voice.empty())
        {
            say.Set("voice", _Voice);
        }
        if (_iSampleRate > 0)
        {
            say.Set("sampleRate", _iSampleRate);
        }
        if (_fSpeed > 0.0)
        {
            say.Set("speed", _fSpeed);
        }
        QueueText(say);
    }

    void SpeakSession::Prepare()
    {
        Begin(); // no-op while connected
    }

    void SpeakSession::StopSpeech(const std::string& _Id)
    {
        if (!Running())
        {
            return;
        }
        Json stop = Message("stop");
        if (!_Id.empty())
        {
            stop.Set("id", _Id);
        }
        QueueText(stop);
        // Quiet at once, not when the engine's answer arrives.
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (_Id.empty() || _Id == m_CurrentId)
        {
            m_bDiscard = true;
            Silence();
        }
    }

    std::string SpeakSession::PlayingId() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_PlayingId;
    }

    void SpeakSession::Silence()
    {
        if (m_bSpeaker)
        {
            m_pPlayback->Flush();
        }
        if (!m_PlayingId.empty())
        {
            Emit(Message("playback").Set("state", "stopped").Set("id", m_PlayingId));
            m_PlayingId.clear();
        }
    }

    void SpeakSession::OnOpen()
    {
        std::string error;
        const bool bspeaker = m_pPlayback && m_pPlayback->Start(kPlaybackRate, error);
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bSpeaker = bspeaker;
        }
        if (!bspeaker)
        {
            // Speech events still arrive; there's just nothing to hear.
            Emit(LocalError("audio", error.empty() ? "No speaker" : error));
        }
        else
        {
            // Where replies play: the echo canceller's reference must be it.
            Emit(Message("speaker").Set("device", m_pPlayback->Description()));
        }
    }

    void SpeakSession::OnTick()
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (!m_PlayingId.empty() && m_PlayingId == m_CurrentId && m_bCurrentEnded &&
            (!m_bSpeaker || m_pPlayback->Queued() == 0))
        {
            Emit(Message("playback").Set("state", "stopped").Set("id", m_PlayingId));
            m_PlayingId.clear();
        }
    }

    void SpeakSession::OnEnd()
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        Silence();
        if (m_bSpeaker)
        {
            m_pPlayback->Stop();
            m_bSpeaker = false;
        }
    }

    void SpeakSession::OnText(const Json& _Message)
    {
        const std::string& type = _Message["type"].AsString();
        const std::string& id = _Message["id"].AsString();
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (type == "start")
            {
                m_CurrentId = id;
                m_bCurrentEnded = false;
                m_bDiscard = false;
                const int irate = static_cast<int>(_Message["sampleRate"].AsInt(kPlaybackRate));
                m_Resampler.SetRates(irate > 0 ? irate : kPlaybackRate,
                    m_bSpeaker ? m_pPlayback->SampleRate() : irate);
            }
            else if ((type == "end" || type == "error") && id == m_CurrentId)
            {
                m_bCurrentEnded = true;
            }
            else if (type == "stopped" && (id.empty() || id == m_CurrentId))
            {
                m_bCurrentEnded = true;
                m_bDiscard = true;
                Silence();
            }
        }
        Emit(_Message);
    }

    void SpeakSession::OnBinary(const std::string& _Data)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (m_CurrentId.empty() || m_bDiscard)
        {
            return;
        }
        if (m_PlayingId != m_CurrentId)
        {
            if (!m_PlayingId.empty())
            {
                Emit(Message("playback").Set("state", "stopped").Set("id", m_PlayingId));
            }
            m_PlayingId = m_CurrentId;
            Json started = Message("playback").Set("state", "started").Set("id", m_PlayingId);
            if (const auto it = m_SayTexts.find(m_PlayingId); it != m_SayTexts.end())
            {
                started.Set("text", it->second);
            }
            Emit(started);
        }
        if (!m_bSpeaker)
        {
            return;
        }
        const std::vector<int16_t> samples = FromBytes(_Data);
        std::vector<int16_t> converted;
        m_Resampler.Process(samples.data(), samples.size(), converted);
        m_pPlayback->Enqueue(converted.data(), converted.size());
    }

} // namespace gitgud::voice
