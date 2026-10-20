#pragma once

// -----------------------------------------------------------------------------
// Voiceprint: the user's voice as the mean speaker embedding of their
// enrollment speech, one JSON file in the voice folder. Holds no audio.
// -----------------------------------------------------------------------------

#include <string>
#include <vector>

namespace gitgud::speech
{

    struct Voiceprint
    {
        std::string m_Model;         // the embedding model it was made with
        double m_fSeconds = 0;       // enrollment speech
        int m_iSamples = 0;          // enrollment utterances
        std::vector<float> m_Vector; // unit length; empty: not enrolled
    };

    // False when there is none or it can't be read.
    bool LoadVoiceprint(const std::string& _Path, Voiceprint& _Out);
    bool SaveVoiceprint(const std::string& _Path, const Voiceprint& _Print, std::string& _Error);
    bool RemoveVoiceprint(const std::string& _Path);

    // Cosine similarity of two unit vectors (-1 when the sizes differ).
    float Similarity(const std::vector<float>& _A, const std::vector<float>& _B);

} // namespace gitgud::speech
