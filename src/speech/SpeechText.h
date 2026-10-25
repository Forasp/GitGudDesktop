#pragma once

// -----------------------------------------------------------------------------
// SpeechText: text and audio shaping for spoken replies: sentences (a long
// first one cut at a clause, so audio starts sooner), and the small voice's
// light roughness.
// -----------------------------------------------------------------------------

#include <string>
#include <utility>
#include <vector>

namespace gitgud::speech
{

    // Sentences to say one at a time: split after . ! ? (closing quotes
    // stay with their sentence), sentences longer than `_nMaxBytes` broken
    // at a comma or a space, and a first sentence of 12 or more words cut at
    // its first , ; or : when both halves keep at least 4 and 3 words.
    std::vector<std::string> SplitForSpeech(const std::string& _Text, std::size_t _nMaxBytes = 300);

    // Roughness: `_Samples` with their loudness fluttering at random by
    // `_fAmount` (0.15 is light), from noise band-passed to `_fLowHz` to
    // `_fHighHz` (run forward and back, so it adds no delay), as a rough
    // voice wavers. The same `_uSeed` gives the same flutter.
    void Roughen(std::vector<float>& _Samples, int _iRate, double _fAmount, double _fLowHz,
        double _fHighHz, unsigned _uSeed);

} // namespace gitgud::speech
