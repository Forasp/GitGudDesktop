#pragma once

// -----------------------------------------------------------------------------
// Turbo: spoken replies with Chatterbox Turbo (ResembleAI's ONNX export,
// MIT), cloned to a voice from a short recording.
//
// Four networks (ITurboNets; speech/TurboOnnx.h runs them on ONNX Runtime):
// the speech encoder turns a reference recording into the voice's
// conditioning, once (cached as a file); embed_tokens and the language model
// (GPT-2 style, 24 layers, a key/value cache) generate speech tokens one at
// a time, 25 a second of audio; the conditional decoder turns the voice's
// prompt tokens plus the new ones into 24 kHz audio.
//
// TurboSynth says one sentence: the text normalized as Chatterbox does, the
// tokens sampled as Turbo's own generation does (temperature 0.8, top_k
// 1000, top_p 0.95, min_p 0.05, repetition penalty 1.2; the model card's
// greedy loop runs away), decoded, a stray last sound trimmed, and the
// speed applied as a pitch-keeping stretch.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <functional>
#include <random>
#include <string>
#include <vector>

namespace gitgud::speech
{

    class Gpt2Tokenizer;

    // A tensor on the CPU: float, float16 (raw bits), or int64.
    struct Tensor
    {
        enum class Type
        {
            Float,
            Half,
            Int64
        };
        Type m_eType = Type::Float;
        std::vector<int64_t> m_Shape;
        std::vector<uint8_t> m_Data;

        std::size_t Count() const;

        std::size_t ElementSize() const
        {
            return m_eType == Type::Half ? 2 : (m_eType == Type::Int64 ? 8 : 4);
        }

        // As floats (from float or half); empty for int64.
        std::vector<float> Floats() const;
        std::vector<int64_t> Ints() const;
        static Tensor FromFloats(const std::vector<float>& _Values, std::vector<int64_t> _Shape);
        static Tensor FromInts(const std::vector<int64_t>& _Values, std::vector<int64_t> _Shape);
        // The same values as `_eType` (float and half convert; int64 doesn't).
        Tensor As(Type _eType) const;
    };

    float HalfToFloat(uint16_t _uHalf);
    uint16_t FloatToHalf(float _fValue);

    // A voice: the speech encoder's outputs for its recording.
    struct VoiceConditioning
    {
        Tensor m_CondEmb;     // the language model's conditioning (from the first 6 s)
        Tensor m_PromptToken; // the decoder's prompt tokens (first 10 s)
        Tensor m_SpeakerEmbeddings;
        Tensor m_SpeakerFeatures;

        bool Save(const std::string& _Path, std::string& _Error) const;
        bool Load(const std::string& _Path, std::string& _Error);
    };

    class ITurboNets
    {
      public:
        virtual ~ITurboNets() = default;

        // The conditioning for 24 kHz mono audio (four outputs, in order).
        virtual bool Encode(const std::vector<float>& _Audio, std::vector<Tensor>& _Out) = 0;
        // Token ids [1, n] to embeddings [1, n, width].
        virtual bool Embed(const std::vector<int64_t>& _Ids, Tensor& _Out) = 0;
        // Start a new sequence (drops the key/value cache).
        virtual void Reset() = 0;
        // One language-model step on `_Embeds` [1, n, width] at positions
        // `_iPosition`...; the last position's logits.
        virtual bool Step(
            const Tensor& _Embeds, int64_t _iPosition, std::vector<float>& _Logits) = 0;
        // Speech tokens to audio (24 kHz).
        virtual bool Decode(const std::vector<int64_t>& _SpeechTokens,
            const Tensor& _SpeakerEmbeddings, const Tensor& _SpeakerFeatures,
            std::vector<float>& _Audio) = 0;
    };

    struct SamplerConfig
    {
        float m_fTemperature = 0.8f;
        int m_iTopK = 1000;
        float m_fTopP = 0.95f;
        float m_fMinP = 0.05f;
        float m_fRepetitionPenalty = 1.2f;
    };

    // One token from `_Logits` (changed in place by the penalty), given the
    // tokens so far.
    int64_t SampleToken(std::vector<float>& _Logits, const std::vector<int64_t>& _Previous,
        const SamplerConfig& _Config, std::mt19937& _Rng);

    // Chatterbox Turbo's special speech tokens.
    inline constexpr int64_t kTurboStart = 6561;
    inline constexpr int64_t kTurboStop = 6562;
    inline constexpr int64_t kTurboSilence = 4299;
    inline constexpr int kTurboRate = 24000;

    class TurboSynth
    {
      public:
        TurboSynth(ITurboNets& _Nets, const Gpt2Tokenizer& _Tokenizer, SamplerConfig _Config = {});

        // Say one sentence in `_Voice` at `_fSpeed` (1 is the model's own
        // pace). `_Stopped` is asked between tokens. False with `_Error` when
        // a network failed (the audio so far is dropped).
        bool Say(const std::string& _Sentence, const VoiceConditioning& _Voice, double _fSpeed,
            const std::function<bool()>& _Stopped, std::vector<float>& _Audio, std::string& _Error);

        // The conditioning for a recording (24 kHz mono): language-model
        // conditioning from its first 6 s, the rest from its first 10 s.
        bool Clone(const std::vector<float>& _Audio, VoiceConditioning& _Out, std::string& _Error);

        // How the last Say went, for the log.
        int LastTokens() const
        {
            return m_iLastTokens;
        }

        void Seed(unsigned _uSeed)
        {
            m_Rng.seed(_uSeed);
        }

      private:
        ITurboNets& m_Nets;
        const Gpt2Tokenizer& m_Tokenizer;
        SamplerConfig m_Config;
        std::mt19937 m_Rng{42};
        int m_iLastTokens = 0;
    };

    // A WAV file (16-bit PCM, any rate, mono or stereo) as 24 kHz mono.
    bool ReadWav24k(const std::string& _Path, std::vector<float>& _Out, std::string& _Error);

} // namespace gitgud::speech
