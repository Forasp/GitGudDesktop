#pragma once

// -----------------------------------------------------------------------------
// SmallVoice: a small single-voice speech model (one ONNX graph, a few MB)
// that turns phonemes into 24 kHz audio on the processor, fast enough for a
// sentence in tens of milliseconds. Bragi's built-in voice is one
// (resources/uis/bragi/voices/bragi-1: a student distilled from Kokoro-82M).
//
// A voice is a folder with model.onnx and phonemes.tsv (each phoneme symbol
// and its input id). The graph takes input_ids [1, T] (int64, 0 at both
// ends), speed [1] (1 is the voice's own pace) and, when it has one,
// wobble [1] (random pitch waver), and gives waveform [1, samples].
//
// Runs on ONNX Runtime through its C API from the onnxruntime.dll the speech
// engine loaded (speech/SherpaApi.h). Every call into it goes through the
// caller's CallFn (the engine's guard, watchdog, and crash marker). Not
// thread-safe: the engine's speaking thread makes every call.
// -----------------------------------------------------------------------------

#include "speech/Recognizer.h" // CallFn

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace gitgud::speech
{

    inline constexpr int kSmallVoiceRate = 24000;
    inline constexpr std::size_t kSmallVoiceMaxIds = 510; // phonemes per call, without the ends

    // The phoneme table: "symbol<TAB>id" lines. False with `_Error`.
    bool ParsePhonemeTable(
        const std::string& _Text, std::map<std::string, int64_t>& _Out, std::string& _Error);
    // The model's input ids for `_Phonemes` (UTF-8): one per symbol the table
    // has (the others skipped), with 0 at both ends.
    std::vector<int64_t> PhonemeIds(
        const std::string& _Phonemes, const std::map<std::string, int64_t>& _Table);

    class SmallVoice
    {
      public:
        SmallVoice(std::string _Dir, int _iThreads, CallFn _Call);
        ~SmallVoice(); // releases the session (unless SetPoisoned)
        SmallVoice(const SmallVoice&) = delete;
        SmallVoice& operator=(const SmallVoice&) = delete;

        // Load the phoneme table and the model. False with `_Error`.
        bool Load(std::string& _Error);

        void SetPoisoned()
        {
            m_bPoisoned = true;
        }

        // 24 kHz audio for `_Phonemes` at `_fSpeed`, with `_fWobble` (ignored
        // by a graph without the input). False with `_Error`.
        bool Say(const std::string& _Phonemes, double _fSpeed, double _fWobble,
            std::vector<float>& _Audio, std::string& _Error);

        // The phonemes given to the last Say, after unknown symbols were dropped.
        std::size_t LastIds() const
        {
            return m_nLastIds;
        }

        struct Impl;

      private:
        std::string m_Dir;
        int m_iThreads = 1;
        CallFn m_Call;
        bool m_bPoisoned = false;
        std::map<std::string, int64_t> m_Table;
        std::size_t m_nLastIds = 0;
        std::unique_ptr<Impl> m_pImpl;
    };

} // namespace gitgud::speech
