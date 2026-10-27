#pragma once

// -----------------------------------------------------------------------------
// Listener: the listen channel of the voice protocol (docs/LUA_API.md,
// "Voice") on top of a Recognizer. Mic audio in (16 kHz s16le), and out:
// vad, wake, partial, pause, message, cancelled, ambient, lookback, wake word
// training and voice enrollment results, errors.
//
// How a message starts and ends: the wake word (spotted, or in the
// transcript) or the app's `wake` starts one. With endBy "app" the app ends
// it (`send`), or the closing phrase does; with endBy "engine" a pause after
// a remark ends it too. Speech that overlaps the app's own playback can only
// wake through the spotter (the transcript may be the app's echo). With a
// voiceprint, speech that isn't the user's is gated out.
//
// With transcribe "growing" the message's text comes from one recording
// decoded again as it grows (speech/GrowingTranscript.h) instead of its
// utterances' texts: only accepted utterances are heard, partials carry the
// whole text so far, and `message` carries the last decode (`text`), the
// last partial's text (`live`) and whether the last decode worked
// (`finalOk`), so the app can fall back.
//
// With a turn-taking model (Recognizer::Decider), `decide` runs it on the
// app's texts and answers with a `decision`: the app says what to read and
// decides what the answer means. "{pause}" in the text becomes the silence
// since the speech ended, as the engine heard it.
//
// Runs on the engine's thread only: every call, and every Send.
// -----------------------------------------------------------------------------

#include "app/Json.h"
#include "speech/GrowingTranscript.h"
#include "speech/Recognizer.h"
#include "speech/Voiceprint.h"

#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace gitgud::speech
{

    class Listener
    {
      public:
        using SendFn = std::function<void(const app::Json& _Message)>;
        using LogFn = std::function<void(const std::string& _Line)>;

        // `_VoiceprintPath`: the user's voiceprint file ("" for none).
        Listener(Recognizer& _Recognizer, std::string _VoiceprintPath, SendFn _Send, LogFn _Log);
        ~Listener();
        Listener(const Listener&) = delete;
        Listener& operator=(const Listener&) = delete;

        void OnText(const std::string& _Text);
        void OnAudio(const std::string& _Pcm);

        long long SamplesHeard() const
        {
            return m_iNow;
        }

      private:
        struct Segment
        {
            long long m_iT0 = 0;
            long long m_iT1 = 0;
            std::string m_Text;
            std::string m_Speaker; // "user", "other", or "" (unknown)
            float m_fSpeakerScore = 0;
            bool m_bScored = false;
        };

        struct Message
        {
            bool m_bActive = false;
            std::string m_Id;
            bool m_bFromApp = false;
            bool m_bPauseMode = false;
            long long m_iT0 = 0;
            long long m_iWakeAt = 0;
            std::vector<Segment> m_Parts;
            long long m_iPauseDeadline = -1;   // samples
            long long m_iClosingDeadline = -1; // samples
        };

        void OnHello(const app::Json& _Json, bool _bHello);
        void OnUtterance(
            const float* _pSamples, std::size_t _nCount, long long _iS0, long long _iS1);
        void OnKeyword(long long _iAt);
        void OnEnroll(const std::string& _State);
        void OnTrain(const std::string& _State);
        void OnDecide(const app::Json& _Json);
        // Seconds of silence since the speech ended (0 while speaking, or
        // before any speech).
        double SilenceSeconds() const;
        void CheckTimers();
        void SendPartial(bool _bForce);
        void SendPause(long long _iS1);
        void StartMessage(long long _iT0, long long _iWakeAt, bool _bFromApp);
        void FinishMessage(const char* _szEndedBy);
        void CancelMessage();
        void SendError(const std::string& _Code, const std::string& _Message);
        void ResetKws();
        void PruneLookback();
        app::Json NewestSegments(long long _iBeforeMs, int _iTokens) const;
        std::string MessageText() const;
        bool PauseModeFor(const std::string& _Text, const std::vector<long long>& _Hits,
            long long _iS0, long long _iS1) const;
        bool NameAtEnd(
            const std::string& _Text, const std::vector<long long>& _Hits, long long _iS1) const;
        bool SpeechBefore(long long _iS0) const;
        // "user" or "other" for most of the message's scored speech, "" when none is.
        const char* MessageSpeaker() const;
        // Most of `_Heard`'s words (two or more) are `_Spoken`'s.
        static bool EchoOf(const std::string& _Heard, const std::string& _Spoken);
        bool OverlapsPlayback(long long _iS0, long long _iS1) const;
        std::string FixText(const std::string& _Text) const;
        float ScoreSpeaker(const float* _pSamples, std::size_t _nCount, double* _pMs);
        void TagSpeaker(Segment& _Segment, float _fScore, double _fSeconds, double _fMs);
        bool GateActive() const;
        void CheckGate();
        void SendVad(bool _bSpeaking, long long _iT, bool _bGated);
        void RestoreDeadlines();
        static app::Json SegmentJson(const Segment& _Segment);
        std::vector<float> RingSlice(long long _iFrom, long long _iTo) const;
        // Growing mode: is it on, its settings, and a decode for it that adds
        // its time to `_fMs`.
        bool Growing() const
        {
            return m_Config.m_Transcribe == "growing";
        }
        GrowingTranscript::Settings GrowSettings() const;
        GrowingTranscript::DecodeFn GrowDecode(double& _fMs);
        // Tells the growing transcript where the speech not judged yet starts.
        void SetGrowOpen();
        // The message's text so far: the growing transcript's last pass, or
        // its utterances' texts.
        std::string CurrentText() const;

        static long long Ms(long long _iSamples)
        {
            return _iSamples / 16;
        }

        Recognizer& m_Recognizer;
        const EngineConfig& m_Config;
        SendFn m_Send;
        LogFn m_Log;
        bool m_bHello = false;

        std::string m_WakeWord;
        std::string m_ClosingPhrase;
        int m_iContextTokens = 0;
        int m_iMessageContextTokens = 0;
        int m_iLookbackTokens = 0;
        double m_fEndWaitSeconds = 3;
        bool m_bAppEnds = true;
        std::vector<std::string> m_AppMishearings;
        std::vector<std::string> m_Mishearings;
        std::vector<std::string> m_SpotterPhrases;
        float m_fWakeThreshold = 0.25f;
        std::vector<std::string> m_Vocabulary; // hotword lines
        std::string m_Hotwords;

        const SherpaOnnxVoiceActivityDetector* m_pVad = nullptr;
        const SherpaOnnxOnlineStream* m_pKws = nullptr;
        long long m_iNow = 0;
        std::vector<float> m_Ring;
        long long m_iRingStart = 0;
        bool m_bVoiced = false;
        bool m_bSpeaking = false;
        long long m_iSpeechStart = 0;
        bool m_bGated = false;
        int m_iGateLowRun = 0;
        int m_iGateChecks = 0;
        int m_iGateLows = 0;
        long long m_iLastGateCheck = 0;
        std::string m_SavedMsgId;
        long long m_iSavedPause = -1;
        long long m_iSavedClosing = -1;
        long long m_iLastPartial = 0;
        long long m_iPartialCost = 0;
        long long m_iSendCut = -1;
        std::vector<long long> m_WakeHits;
        long long m_iLastS0 = -1;
        long long m_iLastS1 = -1;
        std::string m_LastText;

        bool m_bPlaying = false;
        long long m_iPlayStart = 0;
        // What the replies playing now and just before say (playback's
        // `text`): its own voice heard back is dropped (OnUtterance).
        std::string m_PlayText;
        std::string m_LastPlayText;
        std::deque<std::pair<long long, long long>> m_Playback;

        std::deque<Segment> m_Lookback;
        Message m_Msg;
        int m_iMsgCount = 0;
        // Growing mode: the message's transcript (null when no message) and
        // its last live pass's text.
        std::unique_ptr<GrowingTranscript> m_pGrow;
        std::string m_GrowText;
        // Where speech last ended (samples; -1 before any), for the pause the
        // app measures (partial's `speechEnd`).
        long long m_iLastSpeechEnd = -1;

        bool m_bTraining = false;
        int m_iTrainCount = 0;
        std::vector<std::string> m_TrainTexts;
        std::vector<float> m_TrainScores;

        Voiceprint m_Voiceprint;
        std::string m_VoiceprintPath;
        bool m_bEnrolling = false;
        int m_iEnrollCount = 0;
        double m_fEnrollSeconds = 0;
        std::vector<double> m_EnrollSum;
    };

} // namespace gitgud::speech
