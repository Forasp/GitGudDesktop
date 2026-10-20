#pragma once

// -----------------------------------------------------------------------------
// Link: the connection a voice session (voice/VoiceSession.h) talks over. It
// carries the voice protocol both ways: JSON text messages (hello, ready,
// transcripts, say, ...) and binary audio (mic frames up, speech down).
//
// The speech engine inside the app provides them (speech/LocalEngine.h);
// tests pass their own (an in-memory engine) or the stand-in
// (speech/FakeEngine.h).
//
// The engine belongs to the Bragi interface alone: its libraries load when
// listening first starts (never for an interface that doesn't use voice),
// and its models live in the local app data folder (<local app
// data>\Gitgud\bragi\voice), fetched only from the Bragi interface's own
// setup or Settings, on the user's OK.
// -----------------------------------------------------------------------------

#include <cstddef>
#include <functional>
#include <memory>
#include <string>

namespace gitgud::voice
{

    class ILink
    {
      public:
        // A whole message: text, or binary when `_bBinary`.
        using OnMessage = std::function<void(bool _bBinary, const std::string& _Data)>;
        // The link ended: a close code (1000 normal, 1006 when it dropped
        // without one) and a reason. Runs once, also after Close().
        using OnClose = std::function<void(int _iCode, const std::string& _Reason)>;

        virtual ~ILink() = default;

        // BLOCKS until the other end accepts (or refuses: false with
        // `_Error`). After that the callbacks run on the link's own threads.
        virtual bool Open(OnMessage _OnMessage, OnClose _OnClose, std::string& _Error) = 0;

        // Sends may come from any thread, one at a time.
        virtual bool SendText(const std::string& _Text) = 0;
        virtual bool SendBinary(const void* _pData, std::size_t _nSize) = 0;
        // Why the last send failed ("" if none did).
        virtual std::string LastSendError() const = 0;

        // End the link; quick, safe to call more than once and from a
        // callback.
        virtual void Close() = 0;
    };

    // Makes the link for one session: `_Channel` is "listen" or "speak".
    // nullptr when voice isn't available.
    using LinkFactory = std::function<std::unique_ptr<ILink>(const std::string& _Channel)>;

} // namespace gitgud::voice
