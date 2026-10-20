#pragma once

// -----------------------------------------------------------------------------
// FakeEngine: a stand-in speech engine for UI tests (GITGUD_TEST_VOICE=fake),
// so the voice bindings, sessions, and the Bragi interface run end to end
// without models. It answers the voice protocol at once:
//
//   listen: hello -> ready; wake -> wake; send -> message (the text from
//           GITGUD_TEST_VOICE_TEXT, else "hello from the test engine");
//           cancel -> cancelled; lookback -> lookback (no segments);
//           train/enroll stop -> their results. Audio is ignored.
//   speak:  say -> start, a tenth of a second of silence, end; stop ->
//           stopped.
//
// GITGUD_TEST_VOICE=fault makes the listen channel answer hello with the
// error a faulted engine sends (engine-fault, restart) and close.
//
// With it come quiet devices, so tests never open a real microphone or
// speaker: the microphone gives silence, the speaker drops what it gets.
// -----------------------------------------------------------------------------

#include "platform/Audio.h"
#include "voice/Link.h"

#include <memory>
#include <string>

namespace gitgud::speech
{

    // `_bFault`: the listen channel acts out an engine fault.
    std::unique_ptr<voice::ILink> MakeFakeLink(const std::string& _Channel, bool _bFault);

    std::unique_ptr<platform::IAudioCapture> MakeQuietCapture();
    std::unique_ptr<platform::IAudioPlayback> MakeQuietPlayback();

} // namespace gitgud::speech
