#pragma once

// -----------------------------------------------------------------------------
// Gpt2Tokenizer: GPT-2's byte-level BPE, read from a Hugging Face
// tokenizer.json (model.vocab, model.merges, added_tokens), as Chatterbox
// Turbo's text tokenizer. Text is pre-split as GPT-2 does (contractions,
// letters, digits, other symbols, spaces; non-ASCII counts as letters),
// each piece's UTF-8 bytes mapped to GPT-2's printable characters, then
// merged by rank. Added tokens written in brackets ("[chuckle]") are kept
// whole. Encode() ends with the end-of-text token twice, as the tokenizer's
// template does.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace gitgud::speech
{

    class Gpt2Tokenizer
    {
      public:
        // From the tokenizer.json text. False with `_Error` if it isn't one.
        bool Load(const std::string& _Json, std::string& _Error);

        bool Loaded() const
        {
            return !m_Vocab.empty();
        }

        std::vector<int64_t> Encode(const std::string& _Text) const;
        // The pre-split pieces (for tests).
        static std::vector<std::string> PreSplit(const std::string& _Text);

      private:
        std::vector<std::string> Bpe(const std::string& _Word) const;

        std::unordered_map<std::string, int64_t> m_Vocab;
        std::unordered_map<std::string, int> m_Ranks; // "a\x01b" -> rank
        std::unordered_map<std::string, int64_t> m_Special;
        int64_t m_iEndOfText = -1;
        std::string m_ByteChar[256]; // GPT-2's printable character for each byte (UTF-8)
    };

} // namespace gitgud::speech
