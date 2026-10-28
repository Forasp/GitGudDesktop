#pragma once

// -----------------------------------------------------------------------------
// GrowingTranscript: one message's audio, transcribed as it grows (the
// listener's "growing" mode). Each live pass decodes the newest buffer again
// with all of its context, so the text corrects itself; a buffer that reaches
// its cap closes between two utterances, is decoded once more and frozen, and
// only the buffer after it is decoded live from then on. The end of the
// message decodes the live buffer one last time: for a message shorter than
// a buffer, that is one pass over all of it.
//
// What the recognizer hears is the message's audio kept only near speech the
// listener accepted (keepBefore / keepAfter around each accepted utterance,
// never into one it rejected). Everything else becomes quiet fill, and fill longer than gapMax is
// shortened to gapKeep, with short fades where real audio meets fill. Speech
// itself and its margins are never cut. Speech the listener hasn't judged yet
// (the utterance still being spoken) is heard by live passes only, and never
// frozen.
//
// Sample positions are the listener's (16 kHz samples since it started).
// Pure: no models, no threads; the caller decodes (DecodeFn). Every number
// comes from Lua through Settings.
// -----------------------------------------------------------------------------

#include <cstddef>
#include <deque>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace gitgud::speech
{

    class GrowingTranscript
    {
      public:
        struct Settings
        {
            int m_iRate = 16000;
            double m_fKeepBefore = 0.9;    // real audio kept before an accepted utterance
            double m_fKeepAfter = 0.9;     // and after it
            double m_fGapMax = 2.5;        // fill longer than this is shortened
            double m_fGapKeep = 0.5;       // to this
            double m_fFadeSeconds = 0.02;  // where real audio meets fill
            double m_fFillLevel = 0.0003;  // the fill's noise level (0: silence)
            double m_fBufferSeconds = 30;  // a buffer closes at most this long
            double m_fSnapSeconds = 5;     // from bufferSeconds - snapSeconds on
            double m_fAsrMaxSeconds = 30;  // the most one decode may get
        };

        // Decodes 16 kHz mono samples; false in `_bOk` when the call failed.
        using DecodeFn = std::function<std::string(const float*, std::size_t, bool& _bOk)>;

        // A message that starts at sample `_iStart`.
        GrowingTranscript(const Settings& _Settings, long long _iStart);

        // The message's next audio, right after what came before.
        void Append(const float* _pSamples, std::size_t _nCount);
        // An utterance the listener kept (pre-roll included) or dropped.
        void Accept(long long _iS0, long long _iS1);
        void Reject(long long _iS0, long long _iS1);
        // Speech not judged yet, from `_iS0` to now; -1 when there is none.
        void SetOpen(long long _iS0);

        // A live pass: closes full buffers first, then decodes the live
        // buffer (with the open speech). Returns the frozen texts and the
        // live text; `_bOk` false if any of their decodes failed (a closed
        // buffer's too, however long ago).
        std::string Live(const DecodeFn& _Decode, bool& _bOk);
        // The end of the message: closes full buffers, then decodes the live
        // buffer one last time, with the open speech when `_bWithOpen`
        // (`_bOk` as for Live).
        std::string Final(const DecodeFn& _Decode, bool _bWithOpen, bool& _bOk);

        // What a decode of [_iFrom, _iTo) hears (with the open speech when
        // `_bWithOpen`): real audio near accepted speech, fill elsewhere.
        std::vector<float> Audio(long long _iFrom, long long _iTo, bool _bWithOpen) const;

        long long Start() const
        {
            return m_iStart;
        }
        long long End() const
        {
            return m_iEnd;
        }
        long long LiveStart() const
        {
            return m_iLiveStart;
        }
        std::size_t ClosedCount() const
        {
            return m_Closed.size();
        }
        // The closed buffers' texts, joined.
        std::string FrozenText() const;
        // What a decode of the live buffer hears, in words (for the log).
        std::string Describe(bool _bWithOpen) const;
        int Decodes() const
        {
            return m_iDecodes;
        }

      private:
        struct Piece
        {
            bool m_bReal = false;
            long long m_iS0 = 0; // samples of the message
            long long m_iS1 = 0;
            long long m_iOut = 0; // samples it takes in the decoded audio
        };
        struct Closed
        {
            long long m_iS0 = 0;
            long long m_iS1 = 0;
            std::string m_Text;
            bool m_bOk = true; // false: its decode failed (its audio is gone)
        };

        std::vector<Piece> Layout(long long _iFrom, long long _iTo, bool _bWithOpen) const;
        static long long OutLength(const std::vector<Piece>& _Pieces);
        std::vector<float> Render(const std::vector<Piece>& _Pieces) const;
        std::string Decode(long long _iFrom, long long _iTo, bool _bWithOpen,
            const DecodeFn& _Decode, bool& _bOk);
        void CloseFull(const DecodeFn& _Decode);
        // Every closed buffer's decode worked.
        bool FrozenOk() const;
        // Where the live buffer may close: between accepted utterances (or
        // after the last one), never inside one, never in the open speech.
        std::vector<long long> CutPoints() const;
        long long Samples(double _fSeconds) const;
        float RawAt(long long _iAt) const;

        Settings m_Settings;
        long long m_iStart = 0;
        long long m_iEnd = 0;
        std::deque<float> m_Raw; // audio from m_iRawStart to m_iEnd
        long long m_iRawStart = 0;
        std::vector<std::pair<long long, long long>> m_Accepted;
        std::vector<std::pair<long long, long long>> m_Rejected;
        long long m_iOpen = -1;
        std::vector<Closed> m_Closed;
        long long m_iLiveStart = 0;
        int m_iDecodes = 0;
    };

} // namespace gitgud::speech
