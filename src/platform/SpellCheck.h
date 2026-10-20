#pragma once

// -----------------------------------------------------------------------------
// SpellCheck: is a word an ordinary dictionary word? Wake word training uses
// it to tell everyday words ("Roger", "Right") from real mishearings
// (SpellCheck.cpp). Windows' own spell checker (Windows 8 and later), US
// English.
// -----------------------------------------------------------------------------

#include <optional>
#include <string>

namespace gitgud::platform
{

    // True when `_Text` (UTF-8: a word, or words separated by spaces) has no
    // spelling errors, false when it has any. Nothing when there's no answer:
    // other platforms, no US English dictionary, empty text, or an error.
    std::optional<bool> IsDictionaryWord(const std::string& _Text);

} // namespace gitgud::platform
