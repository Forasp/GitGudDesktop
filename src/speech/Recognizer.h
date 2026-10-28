#pragma once

// -----------------------------------------------------------------------------
// Recognizer: the speech models, on the CPU, through sherpa-onnx
// (speech/SherpaApi.h): Silero voice activity detection, the zipformer
// keyword spotter (wake word, closing phrase), Parakeet offline recognition
// (int8, beam search biased toward hotwords), and TitaNet speaker
// embeddings.
//
// Not thread-safe: one thread (the engine's) makes every call. Every call
// into the libraries goes through the caller's CallFn (speech/LocalEngine:
// the guard, the watchdog, the crash marker); a call it refuses or that
// failed returns nothing (an empty text, no stream, false).
//
// Inputs are checked before they reach the libraries, since some bad ones
// end the process: 16 kHz only, keywords and hotwords limited to tokens the
// models have, fixed decoding methods, an ONNX Runtime config file this
// writes itself.
// -----------------------------------------------------------------------------

#include "app/Json.h"

#include <chrono>
#include <cstddef>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

struct SherpaOnnxOfflineRecognizer;
struct SherpaOnnxKeywordSpotter;
struct SherpaOnnxOnlineStream;
struct SherpaOnnxVoiceActivityDetector;
struct SherpaOnnxSpeakerEmbeddingExtractor;

namespace gitgud::speech
{

    // Runs one call into the libraries: true when it ended normally. `_szName`
    // names it (the crash marker, the log), `_Limit` is the watchdog's.
    using CallFn = std::function<bool(
        const char* _szName, std::chrono::milliseconds _Limit, const std::function<void()>& _Call)>;

    // The models and the listening settings. Lua sets them
    // (gitgud.voiceEngineSetup); these defaults only stand in for a missing one.
    struct EngineConfig
    {
        std::string m_VadModel; // silero_vad.onnx
        std::string m_AsrDir;   // encoder/decoder/joiner(.int8).onnx, tokens.txt
        std::string m_AsrName = "parakeet-tdt_ctc-110m-transducer-int8";
        std::string m_KwsDir;       // the gigaspeech zipformer's files and bpe.model
        std::string m_SpeakerModel; // TitaNet (empty: no speaker identification)
        std::string m_VoiceprintsDir;
        std::string m_WorkDir; // where the engine writes its ONNX Runtime config
        // The turn-taking classifier (speech/TextClassifier.h): its graph and
        // vocab.txt. Optional: without it, `decide` requests get an error.
        std::string m_DeciderModel;
        std::string m_DeciderVocab;
        int m_iDeciderThreads = 1;

        int m_iAsrThreads = 4;
        int m_iKwsThreads = 1;
        int m_iSpeakerThreads = 2;
        bool m_bHotwords = true;
        float m_fHotwordsScore = 1.5f;
        float m_fAsrMaxSeconds = 16.0f;
        bool m_bSpinning = false; // ONNX Runtime thread spinning
        // "cpu" or "cuda" (used only on the GPU runtime; the spotter and the
        // speech detector stay on the CPU).
        std::string m_AsrProvider = "cpu";
        std::string m_SpeakerProvider = "cpu";

        float m_fSpeakerThreshold = 0.5f;
        float m_fSpeakerMinSeconds = 0.8f;
        float m_fSpeakerUnsureBelow = 0.3f;
        float m_fSpeakerUnsureSeconds = 2.0f;
        float m_fEnrollMinSeconds = 10.0f;

        float m_fVadThreshold = 0.5f;
        float m_fSilenceSeconds = 0.6f;
        float m_fMinSpeechSeconds = 0.25f;
        float m_fPrerollSeconds = 0.2f;
        float m_fMaxUtteranceSeconds = 20.0f;
        float m_fPartialSeconds = 1.0f;
        // "utterances": a message is its utterances' texts, joined (partials
        // decode the open utterance). "growing": a message is one recording,
        // decoded again as it grows, in buffers closed between utterances
        // (speech/GrowingTranscript.h); the numbers below are that mode's.
        std::string m_Transcribe = "utterances";
        float m_fGrowEverySeconds = 1.0f;      // a live pass this often
        float m_fGrowEveryLongSeconds = 2.5f;  // and this often once the live buffer
        float m_fGrowLongAfterSeconds = 10.0f; // is longer than this
        float m_fGrowCostFactor = 1.5f;        // never more often than this x the last pass's time
        bool m_bGrowHotwords = true;           // passes biased toward the hotwords too
        float m_fBufferSeconds = 30.0f;
        float m_fBufferSnapSeconds = 5.0f;
        float m_fKeepBeforeSeconds = 0.9f;
        float m_fKeepAfterSeconds = 0.9f;
        float m_fGapMaxSeconds = 2.5f;
        float m_fGapKeepSeconds = 0.5f;
        float m_fFadeSeconds = 0.02f;
        float m_fFillLevel = 0.0003f;
        float m_fClosingSilenceSeconds = 1.0f;
        std::string m_EndBy = "app";
        float m_fWakeThreshold = 0.25f;
        std::string m_WakeWord = "Bragi";
        std::vector<std::string> m_SpotterSpellings;
        std::vector<std::string> m_Mishearings;
        float m_fWakeBoost = 1.5f;
        bool m_bTextWake = true;
        float m_fWakeEndSeconds = 1.0f;
        float m_fWakeStartSeconds = 1.2f;
        int m_iRemarkMaxWords = 6;
        int m_iRemarkQuestionMaxWords = 15;
        float m_fRemarkContextSeconds = 30.0f;
        int m_iContextTokens = 1000;
        int m_iMessageContextTokens = 0;
        int m_iLookbackTokens = 5000;

        // The fields `_Json` has, over the defaults; numbers out of range are
        // kept to it. False with `_Error` for a field of the wrong type.
        static bool FromJson(const app::Json& _Json, EngineConfig& _Out, std::string& _Error);
    };

    // A SentencePiece unigram model (bpe.model), for the keyword spotter's
    // keywords.
    class BpeTokenizer
    {
      public:
        bool Load(const std::string& _Path, std::string& _Error);

        void SetScores(std::map<std::string, float> _Scores)
        {
            m_Scores = std::move(_Scores);
        }

        // One phrase as pieces, uppercased (the gigaspeech model's case).
        std::vector<std::string> Encode(const std::string& _Text) const;

        bool Loaded() const
        {
            return !m_Scores.empty();
        }

      private:
        std::map<std::string, float> m_Scores;
    };

    // tokens.txt: token -> id.
    std::map<std::string, int> LoadTokens(const std::string& _Path);

    // A spotter keyword line for `_Phrase` ("" when a piece isn't a token the
    // model has: such a keyword makes a stream that crashes when fed).
    std::string KeywordLine(const BpeTokenizer& _Bpe, const std::map<std::string, int>& _Tokens,
        const std::string& _Phrase, float _fBoost, float _fThreshold);
    // A hotword line for `_Phrase` ("" when a character isn't a token).
    std::string HotwordLine(
        const std::map<std::string, int>& _Tokens, const std::string& _Phrase, float _fBoost);

    // One finished stretch of speech the voice activity detector found.
    struct SpeechSegment
    {
        long long m_iStart = 0; // sample index
        std::vector<float> m_Samples;
    };

    class TextClassifier;

    class Recognizer
    {
      public:
        Recognizer(EngineConfig _Config, CallFn _Call);
        ~Recognizer(); // releases the models (unless SetPoisoned)
        Recognizer(const Recognizer&) = delete;
        Recognizer& operator=(const Recognizer&) = delete;

        // Load every model. False with `_Error` when one can't be: a file
        // missing, or the library refused or threw (`_bDamaged`: the files
        // are there but unusable, so they need repairing).
        bool Load(std::string& _Error, bool& _bDamaged);

        // After a fault: never call the libraries again, not even to release.
        void SetPoisoned();

        const EngineConfig& Config() const
        {
            return m_Config;
        }

        // 16 kHz mono float samples to text; `_bOk` false when the call failed.
        // Audio longer than asrMaxSeconds is decoded in equal pieces.
        std::string Recognize(const float* _pSamples, std::size_t _nCount,
            const std::string& _Hotwords, double* _pMs, bool* _pOk = nullptr);
        // The same in a single decode, never split (the caller keeps it short:
        // growing mode cuts its audio at pauses itself).
        std::string RecognizeWhole(const float* _pSamples, std::size_t _nCount,
            const std::string& _Hotwords, double* _pMs, bool* _pOk);

        bool KwsReady() const
        {
            return m_pKws != nullptr;
        }

        std::string KeywordLines(const std::vector<std::string>& _Phrases, float _fThreshold) const;
        const SherpaOnnxOnlineStream* CreateKwsStream(const std::string& _Keywords);
        // True when a keyword was spotted in this chunk (the stream resets).
        bool KwsFeed(
            const SherpaOnnxOnlineStream* _pStream, const float* _pSamples, std::size_t _nCount);
        void KwsFinish(const SherpaOnnxOnlineStream* _pStream);
        void DestroyKwsStream(const SherpaOnnxOnlineStream* _pStream);
        // The highest threshold (0.05 to 0.95) at which one of `_Phrases` is
        // spotted in the samples (0: none).
        float KwsScore(
            const std::vector<std::string>& _Phrases, const float* _pSamples, std::size_t _nCount);

        const SherpaOnnxVoiceActivityDetector* CreateVad();
        void DestroyVad(const SherpaOnnxVoiceActivityDetector* _pVad);
        // Feed the detector; `_bSpeech` says whether it hears speech now, and
        // `_Segments` gets the stretches it finished.
        bool VadFeed(const SherpaOnnxVoiceActivityDetector* _pVad, const float* _pSamples,
            std::size_t _nCount, bool& _bSpeech, std::vector<SpeechSegment>& _Segments);

        bool SpeakerReady() const
        {
            return m_pSpeaker != nullptr;
        }

        // A unit-length speaker embedding (empty on failure).
        std::vector<float> Embed(const float* _pSamples, std::size_t _nCount, double* _pMs);
        std::string SpeakerModelName() const;

        // A phrase as a hotwords line for this recognizer ("" if it can't).
        std::string HotwordLineFor(const std::string& _Phrase, float _fBoost = 0) const;

        // The turn-taking classifier, or null: none configured, or it didn't
        // load (DeciderError says why; listening goes on without it).
        TextClassifier* Decider()
        {
            return m_pDecider.get();
        }

        const std::string& DeciderError() const
        {
            return m_DeciderError;
        }

      private:
        std::string DecodeOne(
            const float* _pSamples, std::size_t _nCount, const std::string& _Hotwords, bool& _bOk);
        // The ONNX Runtime provider string: "cpu", or "cpu:<config>" with
        // spinning off (a file this writes and checks; never a missing one).
        std::string Provider();
        // Provider(), whatever is asked for (listening stays on the
        // processor; see ProviderFor in Recognizer.cpp).
        std::string ProviderFor(const std::string& _Wanted);

        EngineConfig m_Config;
        CallFn m_Call;
        bool m_bPoisoned = false;
        std::string m_ProviderString;
        std::string m_VocabPath;
        const SherpaOnnxOfflineRecognizer* m_pAsr = nullptr;
        const SherpaOnnxKeywordSpotter* m_pKws = nullptr;
        const SherpaOnnxSpeakerEmbeddingExtractor* m_pSpeaker = nullptr;
        BpeTokenizer m_KwsBpe;
        std::map<std::string, int> m_KwsTokens;
        std::map<std::string, int> m_AsrTokens;
        std::unique_ptr<TextClassifier> m_pDecider;
        std::string m_DeciderError;
    };

} // namespace gitgud::speech
