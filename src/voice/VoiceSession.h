#pragma once

// -----------------------------------------------------------------------------
// VoiceSession: the app's side of the voice protocol's two channels, each
// over a link (voice/Link.h) the session's LinkFactory makes.
//
//   ListenSession: the microphone up (16 kHz, 20 ms frames), transcripts and
//   events down.
//   SpeakSession: text up, speech down into the speaker.
//
// Each runs on a worker thread of its own: Start() returns at once, and
// everything arrives through OnEvent as JSON objects with a "type": the
// engine's messages as they are, plus the session's own:
//   {"type":"mic","state":"on"|"off","device":...,"route"?} (listen; route on
//    "on": the devices opened and the ducking opt-out, IAudioCapture::Route)
//   {"type":"level","t","rms","max"}                     (listen; each second
//    of mic audio: its RMS and loudest 20 ms in dBFS, LevelLog; `t` its end,
//    in the engine's times)
//   {"type":"drop","t","until","count","queued","sendingMs"} (listen; mic
//    frames dropped because the link didn't take them: the first dropped
//    frame's time and the last one's end, how many, how many still wait,
//    and how long the send in progress has waited; at most one a second)
//   {"type":"record","state":"off","path","seconds"}     (listen; a
//    recording of the sent mic audio ended, ListenSession::Record)
//   {"type":"playback","state":"started"|"stopped","id"}  (speak)
//   {"type":"error","code":"connect"|"audio"|"no-ready"|"send","message"}
//                                                        (either; local;
//    "send": a send failed on the link, and how long it had waited)
//   {"type":"closed","code","reason"}                    (either; last)
// OnEvent runs on the session's threads, never the caller's.
// -----------------------------------------------------------------------------

#include "app/Json.h"
#include "platform/Audio.h"
#include "voice/Link.h"
#include "voice/Pcm.h"
#include "voice/SendQueue.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace gitgud::voice
{

    using OnEvent = std::function<void(const app::Json& _Event)>;

    // One link, its worker thread, and the queue of what to send (sent on a
    // thread of its own, so a stalled link never holds up the worker's ticks
    // or whoever queues).
    class Channel
    {
      public:
        Channel(const Channel&) = delete;
        Channel& operator=(const Channel&) = delete;

        bool Running() const;
        // Close the link and wait for the worker (quick, unless it is still
        // opening: then until the link gives up).
        void Stop();

      protected:
        // Binary messages beyond `_nMaxQueuedBinary` drop the oldest.
        Channel(LinkFactory _MakeLink, std::string _Channel, OnEvent _OnEvent,
            std::size_t _nMaxQueuedBinary = (std::numeric_limits<std::size_t>::max)());
        virtual ~Channel(); // derived classes call Stop() in theirs

        // Start the worker (open the link, then OnOpen); false if it's running.
        bool Begin();

        void QueueText(const app::Json& _Message);
        // A mic frame and its time (ms since the first sample).
        void QueueBinary(std::string _Data, int64_t _iMs);
        void Emit(const app::Json& _Event) const;
        bool Stopping() const;
        // From the worker: end the session after this tick.
        void RequestStop();

        // The worker thread: after the link opens, every tick (about 20 ms), and
        // before closing.
        virtual void OnOpen()
        {
        }

        virtual void OnTick()
        {
        }

        virtual void OnEnd()
        {
        }

        // The queue's thread: `_Data` went out on the link.
        virtual void OnSent(bool /*_bBinary*/, const std::string& /*_Data*/)
        {
        }

        // The worker thread, last: nothing more is sent (before `closed`).
        virtual void OnStopped()
        {
        }

        // The link's receive thread.
        virtual void OnText(const app::Json& _Message) = 0;
        virtual void OnBinary(const std::string& _Data) = 0;

        SendQueue& Sends()
        {
            return m_Sends;
        }

        const SendQueue& Sends() const
        {
            return m_Sends;
        }

      private:
        void Loop();
        // Once: a `send` error if a send failed on the link.
        void ReportSendFailure();

        LinkFactory m_MakeLink;
        std::string m_Channel;
        OnEvent m_OnEvent;

        std::unique_ptr<ILink> m_pLink; // the worker's, while it runs
        SendQueue m_Sends;
        std::thread m_Thread;
        mutable std::mutex m_Mutex;
        std::condition_variable m_Wake;
        std::string m_SendError; // why a send failed ("" if none), and after how long
        bool m_bSendReported = false;
        bool m_bStop = false;
        bool m_bClosed = false;
        int m_iCloseCode = 0;
        std::string m_CloseReason;
        std::atomic<bool> m_bRunning{false};
    };

    class ListenSession final : public Channel
    {
      public:
        // Mic frames waiting for the link beyond this (10 s) are dropped,
        // oldest first: live speech is worth more than an older backlog. A
        // link that stalls for less loses nothing (the queue catches up at
        // the link's speed, many times real time).
        static constexpr std::size_t kMaxQueuedFrames = 500;

        ListenSession(LinkFactory _MakeLink, OnEvent _OnEvent);
        ~ListenSession() override;

        // Connect, send `hello` (the protocol's defaults with `_Hello`'s
        // fields on top), and once `ready` arrives start `_pCapture` and
        // stream it. False if already running.
        bool Start(const app::Json& _Hello, std::unique_ptr<platform::IAudioCapture> _pCapture);

        // The hello this session sends for `_Fields`.
        static app::Json Hello(const app::Json& _Fields);

        // Control messages (queued; sent in order).
        void Config(const app::Json& _Fields);
        void Wake();
        // `send`: end the current message. `_Reason` is "button" (the default)
        // or "done" (the app judged it finished); empty sends none.
        void SendNow(const std::string& _Reason = "");
        void Cancel();
        // `_Text`: what the reply says (the engine drops its own voice heard
        // back while it plays).
        void Playback(const std::string& _State, const std::string& _Id, const std::string& _Text = {});
        // `_iTokens` < 0 leaves the engine's default (contextTokens).
        void Lookback(const std::string& _Id, int _iTokens);
        // `decide` with `_Fields` (id, first, second, maxLength, firstMax):
        // the turn-taking model's `decision` answers.
        void Decide(const app::Json& _Fields);
        void Train(const std::string& _State);
        void Enroll(const std::string& _State);

        // Save the mic audio as the engine gets it (each frame once it has
        // gone out on the link) to a WAV file at `_Path` (16 kHz mono
        // 16-bit), until StopRecording or the session ends; either emits
        // {"type":"record","state":"off","path","seconds"}. A recording
        // already running ends first. False with `_Error` if the file can't
        // be created.
        bool Record(const std::string& _Path, std::string& _Error);
        void StopRecording();

        // Tests: wait for `ready` this long.
        void SetReadyTimeout(std::chrono::milliseconds _Timeout);
        // Tests: a mic that gives no samples this long after it opens gets a
        // `no-audio` error (the session keeps running).
        void SetSilentTimeout(std::chrono::milliseconds _Timeout);
        std::size_t DroppedFrames() const;

      private:
        void OnOpen() override;
        void OnTick() override;
        void OnEnd() override;
        void OnText(const app::Json& _Message) override;
        void OnBinary(const std::string& _Data) override;
        void OnSent(bool _bBinary, const std::string& _Data) override;
        void OnStopped() override;
        void OnSamples(const int16_t* _pSamples, std::size_t _nCount);
        // The `level` events measured since the last call.
        void EmitLevels();
        // The `mic` on event for `_Device` and the capture's `_Route`.
        app::Json MicOn(const std::string& _Device, const std::string& _Route) const;
        // A `drop` event for the frames dropped since the last one, at most
        // one a second unless `_bNow`.
        void EmitDrops(bool _bNow);

        app::Json m_Hello;
        std::unique_ptr<platform::IAudioCapture> m_pCapture;
        Framer m_Framer;                   // the capture thread's
        LevelLog m_LevelLog;               // the capture thread's
        std::vector<SecondLevel> m_Levels; // measured, not yet emitted
        std::atomic<bool> m_bReady{false};
        bool m_bCapturing = false;
        std::chrono::steady_clock::time_point m_HelloSent;
        std::chrono::milliseconds m_ReadyTimeout{15000};
        std::chrono::milliseconds m_SilentTimeout{4000};
        std::chrono::steady_clock::time_point m_MicOn;
        std::string m_MicDevice; // the last `mic` event's device
        std::string m_MicRoute;  // and its route
        bool m_bSilentWarned = false;
        std::chrono::steady_clock::time_point m_LastDrop; // the last `drop` event
        std::atomic<std::size_t> m_nSamples{0}; // captured this session
        std::atomic<std::size_t> m_nFrames{0};  // queued for the engine
        std::mutex m_FrameMutex;
        WavWriter m_Recording; // what was sent, while recording (Record)
        std::mutex m_RecordMutex;
    };

    class SpeakSession final : public Channel
    {
      public:
        // The speaker runs at this rate; speech at other rates is resampled.
        static constexpr int kPlaybackRate = 24000;

        SpeakSession(LinkFactory _MakeLink, OnEvent _OnEvent,
            std::unique_ptr<platform::IAudioPlayback> _pPlayback);
        ~SpeakSession() override;

        // Queue text to speak; connects (and opens the speaker) first if
        // needed. `_Voice` "", `_iSampleRate` 0, and `_fSpeed` 0 leave the
        // engine's default (`_fSpeed`: 1 is normal pace, 1.2 a fifth faster).
        void Say(const std::string& _Id, const std::string& _Text, const std::string& _Voice = {},
            int _iSampleRate = 0, double _fSpeed = 0.0);
        // Connect and open the speaker now, so the first reply doesn't wait
        // for either. No-op while connected.
        void Prepare();
        // Stop that utterance, or everything when `_Id` is "".
        void StopSpeech(const std::string& _Id = {});

        // What is playing ("" when silent).
        std::string PlayingId() const;

      private:
        void OnOpen() override;
        void OnTick() override;
        void OnEnd() override;
        void OnText(const app::Json& _Message) override;
        void OnBinary(const std::string& _Data) override;
        void Silence(); // m_Mutex held: drop queued audio, report stopped

        std::unique_ptr<platform::IAudioPlayback> m_pPlayback;
        bool m_bSpeaker = false;

        mutable std::mutex m_Mutex;
        Resampler m_Resampler;
        std::string m_CurrentId;      // the latest `start`
        std::map<std::string, std::string> m_SayTexts; // id -> text, the latest few
        std::string m_PlayingId;      // reported as started, not yet stopped
        bool m_bCurrentEnded = false; // its `end` or `stopped` arrived
        bool m_bDiscard = false;      // stopped here: ignore its audio
    };

} // namespace gitgud::voice
