#pragma once

// -----------------------------------------------------------------------------
// SpeechText: text and audio shaping for spoken replies, as the voice server
// did it: sentences (a long first one cut at a clause, so audio starts
// sooner), punctuation the cloning model reads well, a pitch-keeping time
// stretch (WSOLA), and the trim of a stray sound the model sometimes adds
// after a sentence.
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

    // As Chatterbox normalizes punctuation: a capital first letter, single
    // spaces, "..." ";" ":" " - " read as commas, and a final . when the
    // sentence ends without punctuation.
    std::string NormalizeForSpeech(const std::string& _Sentence);

    // `_Samples` played `_fSpeed` times as fast with the pitch kept (WSOLA:
    // 40 ms frames, half overlap, +-10 ms search). Speed near 1 returns them
    // as they are.
    std::vector<float> Stretch(const std::vector<float>& _Samples, double _fSpeed, int _iRate);

    // The parts louder than `_fFloorDb` below the peak, as sample ranges.
    std::vector<std::pair<std::size_t, std::size_t>> VoicedParts(const std::vector<float>& _Samples,
        int _iRate, double _fFrameSeconds = 0.02, double _fFloorDb = -38.0);

    // Cut a short sound after the sentence (an "Ah!"): the last voiced part,
    // at most 0.8 s, after a pause long enough for `_Sentence` (0.65 s after
    // a short last clause, else 0.3 s), in audio longer than the text needs.
    // Returns the seconds cut.
    double TrimStrayTail(std::vector<float>& _Samples, int _iRate, const std::string& _Sentence);

} // namespace gitgud::speech
