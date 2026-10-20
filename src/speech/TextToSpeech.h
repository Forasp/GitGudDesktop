#pragma once

// -----------------------------------------------------------------------------
// TextToSpeech: spoken replies. ITextToSpeech is what the speak channel
// (speech/LocalEngine) uses; the system's own voices (SAPI on Windows) stand
// in until a neural voice is built in.
//
// One object per thread: make it, and use it, on the thread that speaks
// (COM is set up there on Windows).
// -----------------------------------------------------------------------------

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace gitgud::speech
{

    struct VoiceInfo
    {
        std::string m_Id;   // what `say` names it by
        std::string m_Name; // the system's name for it
        std::string m_Language;
    };

    class ITextToSpeech
    {
      public:
        // Gets each piece of speech, s16le mono at SampleRate(); returning
        // false stops the speech.
        using OnPcm = std::function<bool(const std::string& _Pcm)>;

        virtual ~ITextToSpeech() = default;

        virtual std::string Provider() const = 0;
        virtual int SampleRate() const = 0;
        virtual std::vector<VoiceInfo> Voices() = 0;
        // Speak `_Text` (plain text, not markup) in `_Voice` ("" for the
        // default) at `_fSpeed` (1 is normal). False with `_Error` when it
        // couldn't.
        virtual bool Synthesize(const std::string& _Text, const std::string& _Voice, double _fSpeed,
            const OnPcm& _OnPcm, std::string& _Error) = 0;
    };

    // The system's voices; nullptr where there are none to use.
    std::unique_ptr<ITextToSpeech> MakeSystemTextToSpeech(std::string& _Error);

} // namespace gitgud::speech
