#pragma once

// -----------------------------------------------------------------------------
// TextClassifier: a BERT-style text classifier on ONNX Runtime, through its
// C API from the onnxruntime.dll the speech engine loaded (speech/SherpaApi.h),
// on the processor. Bragi's turn-taking model is one: it reads a pair of
// texts and answers with a few probability lists (its outputs, each already
// a softmax), and Lua decides what they mean.
//
// The graph takes input_ids and attention_mask (int64, [1, n]); the input is
// [CLS] first [SEP] second [SEP], tokenized by WordPiece (speech/WordPiece.h)
// with the model's vocab.txt. `first` keeps its start, `second` its end
// (where a message's turn state is).
//
// Every call into ONNX Runtime goes through the caller's CallFn (the
// engine's guard, watchdog, and crash marker). Not thread-safe: the
// listening thread makes every call.
// -----------------------------------------------------------------------------

#include "speech/Recognizer.h" // CallFn
#include "speech/WordPiece.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace gitgud::speech
{

    class TextClassifier
    {
      public:
        TextClassifier(std::string _ModelPath, std::string _VocabPath, int _iThreads, CallFn _Call);
        ~TextClassifier(); // releases the session (unless SetPoisoned)
        TextClassifier(const TextClassifier&) = delete;
        TextClassifier& operator=(const TextClassifier&) = delete;

        // Load the vocabulary and the graph, and run it once. False with `_Error`.
        bool Load(std::string& _Error);

        void SetPoisoned()
        {
            m_bPoisoned = true;
        }

        // The ids for a pair, at most `_iMaxLength` (3 at least): `_First` cut
        // to `_iFirstMax` pieces (and to fit), `_Second` to what's left (its
        // end kept).
        std::vector<int64_t> Encode(const std::string& _First, const std::string& _Second,
            int _iMaxLength, int _iFirstMax) const;

        // Each output's name and values (the first row). False when the call failed.
        using Outputs = std::vector<std::pair<std::string, std::vector<float>>>;
        bool Classify(const std::vector<int64_t>& _Ids, Outputs& _Out, double* _pMs);

        struct Impl;

      private:
        std::string m_ModelPath;
        std::string m_VocabPath;
        int m_iThreads = 1;
        CallFn m_Call;
        bool m_bPoisoned = false;
        WordPiece m_Tokenizer;
        std::unique_ptr<Impl> m_pImpl;
    };

} // namespace gitgud::speech
