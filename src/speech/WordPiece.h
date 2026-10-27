#pragma once

// -----------------------------------------------------------------------------
// WordPiece: BERT's uncased tokenizer, read from a vocab.txt (one piece per
// line, the line number its id), for the turn-taking classifier
// (speech/TextClassifier.h). As the reference one does: control characters
// dropped, lowercased with accents taken off, split at spaces and around
// every punctuation mark and CJK character, then each word split greedily
// into the longest pieces the vocabulary has ("##" before a piece inside a
// word); a word that can't be split, or is longer than 100 characters, is
// [UNK].
//
// Lowercasing and accents cover ASCII and the Latin-1 and Latin Extended-A
// letters; other characters are kept as they are (speech recognition writes
// English).
// -----------------------------------------------------------------------------

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace gitgud::speech
{

    class WordPiece
    {
      public:
        // From the vocab.txt text. False with `_Error` if it isn't one (no
        // [CLS], [SEP], or [UNK]).
        bool Load(const std::string& _Text, std::string& _Error);

        bool Loaded() const
        {
            return !m_Vocab.empty();
        }

        // The ids, without [CLS] and [SEP].
        std::vector<int64_t> Encode(const std::string& _Text) const;
        // The words before WordPiece (for tests).
        static std::vector<std::string> Words(const std::string& _Text);

        int64_t Cls() const
        {
            return m_iCls;
        }

        int64_t Sep() const
        {
            return m_iSep;
        }

        int64_t Unk() const
        {
            return m_iUnk;
        }

      private:
        std::unordered_map<std::string, int64_t> m_Vocab;
        int64_t m_iCls = -1;
        int64_t m_iSep = -1;
        int64_t m_iUnk = -1;
    };

} // namespace gitgud::speech
