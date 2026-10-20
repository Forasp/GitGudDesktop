#pragma once

// -----------------------------------------------------------------------------
// Text: word-level matching on transcripts, case and punctuation
// insensitive (the wake word, the closing phrase, mishearings).
// -----------------------------------------------------------------------------

#include <cstddef>
#include <string>
#include <vector>

namespace gitgud::speech
{

    struct Word
    {
        std::string m_Norm;       // lowercase letters, digits, apostrophes
        std::size_t m_nBegin = 0; // byte span in the original text
        std::size_t m_nEnd = 0;
    };

    std::vector<Word> SplitWords(const std::string& _Text);
    // Words joined by single spaces.
    std::string NormalizePhrase(const std::string& _Text);

    // Index of the first word of each occurrence of `_Phrase` in `_Words`.
    std::vector<std::size_t> FindPhrase(
        const std::vector<Word>& _Words, const std::string& _Phrase);
    bool ContainsPhrase(const std::string& _Text, const std::string& _Phrase);
    bool StartsWithPhrase(const std::string& _Text, const std::string& _Phrase);
    bool EndsWithPhrase(const std::string& _Text, const std::string& _Phrase);

    // Each mishearing (whole words) replaced with `_WakeWord`.
    std::string RewriteMishearings(const std::string& _Text,
        const std::vector<std::string>& _Mishearings, const std::string& _WakeWord);
    // Remove `_Phrase` at the end (and the punctuation before it); false if absent.
    bool StripTrailingPhrase(std::string& _Text, const std::string& _Phrase);

    std::vector<std::string> SplitSentences(const std::string& _Text);

    // Rough token count for lookback budgets: one per 4 bytes of UTF-8.
    int EstimateTokens(const std::string& _Text);

} // namespace gitgud::speech
