#pragma once

// -----------------------------------------------------------------------------
// TurboOnnx: Chatterbox Turbo's four networks (speech/Turbo.h) on ONNX
// Runtime, through its C API from the onnxruntime.dll the speech engine
// loaded (speech/SherpaApi.h: one runtime for listening and speaking). On
// the GPU runtime the sessions use the CUDA execution provider.
//
// Every call into ONNX Runtime goes through the caller's CallFn (the
// engine's guard, watchdog, and crash marker). Not thread-safe: the engine's
// speaking thread makes every call. The speech encoder loads only while a
// voice is being made, then is released.
// -----------------------------------------------------------------------------

#include "speech/Recognizer.h" // CallFn
#include "speech/Turbo.h"

#include <memory>
#include <string>
#include <vector>

namespace gitgud::speech
{

    struct TurboFiles
    {
        std::string m_Dir;     // the graphs and their .onnx_data
        std::string m_Encoder; // file names in m_Dir
        std::string m_Embed;
        std::string m_Lm;
        std::string m_Decoder;
        bool m_bCuda = false; // the CUDA execution provider
        int m_iThreads = 4;   // CPU threads (CPU nodes, or no GPU)
    };

    class TurboOnnx : public ITurboNets
    {
      public:
        TurboOnnx(TurboFiles _Files, CallFn _Call);
        ~TurboOnnx() override; // releases the sessions (unless SetPoisoned)
        TurboOnnx(const TurboOnnx&) = delete;
        TurboOnnx& operator=(const TurboOnnx&) = delete;

        // Load the embedding, language model, and decoder. False with `_Error`.
        bool Load(std::string& _Error);

        void SetPoisoned()
        {
            m_bPoisoned = true;
        }

        bool Encode(const std::vector<float>& _Audio, std::vector<Tensor>& _Out) override;
        bool Embed(const std::vector<int64_t>& _Ids, Tensor& _Out) override;
        void Reset() override;
        bool Step(const Tensor& _Embeds, int64_t _iPosition, std::vector<float>& _Logits) override;
        bool Decode(const std::vector<int64_t>& _SpeechTokens, const Tensor& _SpeakerEmbeddings,
            const Tensor& _SpeakerFeatures, std::vector<float>& _Audio) override;

        struct Impl;

      private:
        TurboFiles m_Files;
        CallFn m_Call;
        bool m_bPoisoned = false;
        std::unique_ptr<Impl> m_pImpl;
    };

} // namespace gitgud::speech
