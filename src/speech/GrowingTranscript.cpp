#include "speech/GrowingTranscript.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace gitgud::speech
{

    namespace
    {
        void AddRange(
            std::vector<std::pair<long long, long long>>& _Ranges, long long _iS0, long long _iS1)
        {
            if (_iS1 <= _iS0)
            {
                return;
            }
            _Ranges.emplace_back(_iS0, _iS1);
            std::sort(_Ranges.begin(), _Ranges.end());
        }

        void JoinTo(std::string& _Text, const std::string& _Part)
        {
            if (_Part.empty())
            {
                return;
            }
            if (!_Text.empty())
            {
                _Text += ' ';
            }
            _Text += _Part;
        }

        // Union of sorted-or-not ranges, sorted and merged.
        std::vector<std::pair<long long, long long>> Merged(
            std::vector<std::pair<long long, long long>> _Ranges)
        {
            std::sort(_Ranges.begin(), _Ranges.end());
            std::vector<std::pair<long long, long long>> out;
            for (const auto& range : _Ranges)
            {
                if (range.second <= range.first)
                {
                    continue;
                }
                if (!out.empty() && range.first <= out.back().second)
                {
                    out.back().second = std::max(out.back().second, range.second);
                }
                else
                {
                    out.push_back(range);
                }
            }
            return out;
        }

        // `_Ranges` minus `_Cut` (both merged).
        std::vector<std::pair<long long, long long>> Minus(
            const std::vector<std::pair<long long, long long>>& _Ranges,
            const std::vector<std::pair<long long, long long>>& _Cut)
        {
            std::vector<std::pair<long long, long long>> out;
            for (auto range : _Ranges)
            {
                for (const auto& cut : _Cut)
                {
                    if (cut.second <= range.first || cut.first >= range.second)
                    {
                        continue;
                    }
                    if (cut.first > range.first)
                    {
                        out.emplace_back(range.first, cut.first);
                    }
                    range.first = std::max(range.first, cut.second);
                    if (range.first >= range.second)
                    {
                        break;
                    }
                }
                if (range.first < range.second)
                {
                    out.push_back(range);
                }
            }
            return out;
        }
    } // namespace

    GrowingTranscript::GrowingTranscript(const Settings& _Settings, long long _iStart)
        : m_Settings(_Settings), m_iStart(_iStart), m_iEnd(_iStart), m_iRawStart(_iStart),
          m_iLiveStart(_iStart)
    {
    }

    long long GrowingTranscript::Samples(double _fSeconds) const
    {
        return static_cast<long long>(std::llround(std::max(0.0, _fSeconds) * m_Settings.m_iRate));
    }

    void GrowingTranscript::Append(const float* _pSamples, std::size_t _nCount)
    {
        m_Raw.insert(m_Raw.end(), _pSamples, _pSamples + _nCount);
        m_iEnd += static_cast<long long>(_nCount);
    }

    void GrowingTranscript::Accept(long long _iS0, long long _iS1)
    {
        AddRange(m_Accepted, std::max(_iS0, m_iStart), std::min(_iS1, m_iEnd));
    }

    void GrowingTranscript::Reject(long long _iS0, long long _iS1)
    {
        AddRange(m_Rejected, std::max(_iS0, m_iStart), std::min(_iS1, m_iEnd));
    }

    void GrowingTranscript::SetOpen(long long _iS0)
    {
        m_iOpen = _iS0 < 0 ? -1 : std::max(_iS0, m_iStart);
    }

    float GrowingTranscript::RawAt(long long _iAt) const
    {
        if (_iAt < m_iRawStart || _iAt >= m_iEnd)
        {
            return 0.0f;
        }
        return m_Raw[static_cast<std::size_t>(_iAt - m_iRawStart)];
    }

    std::vector<GrowingTranscript::Piece> GrowingTranscript::Layout(
        long long _iFrom, long long _iTo, bool _bWithOpen) const
    {
        _iFrom = std::max(_iFrom, m_iStart);
        _iTo = std::min(_iTo, m_iEnd);
        std::vector<Piece> out;
        if (_iTo <= _iFrom)
        {
            return out;
        }
        const long long ibefore = Samples(m_Settings.m_fKeepBefore);
        const long long iafter = Samples(m_Settings.m_fKeepAfter);
        // Accepted speech and its margins; margins never reach into rejected
        // audio, accepted speech itself is never cut.
        std::vector<std::pair<long long, long long>> core;
        std::vector<std::pair<long long, long long>> margins;
        for (const auto& range : m_Accepted)
        {
            core.push_back(range);
            margins.emplace_back(range.first - ibefore, range.first);
            margins.emplace_back(range.second, range.second + iafter);
        }
        if (_bWithOpen && m_iOpen >= 0)
        {
            core.emplace_back(m_iOpen, m_iEnd);
            margins.emplace_back(m_iOpen - ibefore, m_iOpen);
        }
        const auto rejected = Merged(m_Rejected);
        std::vector<std::pair<long long, long long>> real = Minus(Merged(margins), rejected);
        real.insert(real.end(), core.begin(), core.end());
        real = Merged(real);

        const long long igapMax = Samples(m_Settings.m_fGapMax);
        const long long igapKeep = std::min(Samples(m_Settings.m_fGapKeep), igapMax);
        auto addFill = [&](long long _iS0, long long _iS1)
        {
            if (_iS1 <= _iS0)
            {
                return;
            }
            const long long ilen = _iS1 - _iS0;
            out.push_back(Piece{false, _iS0, _iS1, ilen > igapMax ? igapKeep : ilen});
        };
        long long iat = _iFrom;
        for (const auto& range : real)
        {
            const long long is0 = std::max(range.first, _iFrom);
            const long long is1 = std::min(range.second, _iTo);
            if (is1 <= is0)
            {
                continue;
            }
            addFill(iat, is0);
            out.push_back(Piece{true, is0, is1, is1 - is0});
            iat = is1;
        }
        addFill(iat, _iTo);
        return out;
    }

    long long GrowingTranscript::OutLength(const std::vector<Piece>& _Pieces)
    {
        long long itotal = 0;
        for (const Piece& piece : _Pieces)
        {
            itotal += piece.m_iOut;
        }
        return itotal;
    }

    std::vector<float> GrowingTranscript::Render(const std::vector<Piece>& _Pieces) const
    {
        std::vector<float> out;
        out.reserve(static_cast<std::size_t>(OutLength(_Pieces)));
        const long long ifade = Samples(m_Settings.m_fFadeSeconds);
        const float flevel = static_cast<float>(m_Settings.m_fFillLevel);
        uint32_t useed = 0x9e3779b9u;
        for (std::size_t ni = 0; ni < _Pieces.size(); ++ni)
        {
            const Piece& piece = _Pieces[ni];
            if (!piece.m_bReal)
            {
                for (long long ik = 0; ik < piece.m_iOut; ++ik)
                {
                    useed = useed * 1664525u + 1013904223u;
                    out.push_back(flevel * (static_cast<float>(useed >> 8) / 8388608.0f - 1.0f));
                }
                continue;
            }
            // Fades only where real audio meets fill: in a margin, or at the
            // edge of accepted speech where rejected audio cut its margin off.
            const bool bfadeIn = ni > 0 && !_Pieces[ni - 1].m_bReal;
            const bool bfadeOut = ni + 1 < _Pieces.size() && !_Pieces[ni + 1].m_bReal;
            const long long ilen = piece.m_iS1 - piece.m_iS0;
            const long long iedge = std::min(ifade, ilen / 2);
            for (long long ik = 0; ik < ilen; ++ik)
            {
                float fgain = 1.0f;
                if (bfadeIn && ik < iedge)
                {
                    fgain = static_cast<float>(ik + 1) / static_cast<float>(iedge + 1);
                }
                if (bfadeOut && ilen - 1 - ik < iedge)
                {
                    fgain = std::min(
                        fgain, static_cast<float>(ilen - ik) / static_cast<float>(iedge + 1));
                }
                out.push_back(RawAt(piece.m_iS0 + ik) * fgain);
            }
        }
        return out;
    }

    std::vector<float> GrowingTranscript::Audio(
        long long _iFrom, long long _iTo, bool _bWithOpen) const
    {
        return Render(Layout(_iFrom, _iTo, _bWithOpen));
    }

    std::string GrowingTranscript::Decode(
        long long _iFrom, long long _iTo, bool _bWithOpen, const DecodeFn& _Decode, bool& _bOk)
    {
        const std::vector<Piece> pieces = Layout(_iFrom, _iTo, _bWithOpen);
        if (pieces.empty())
        {
            return {};
        }
        // One decode when it fits; otherwise split at fill (a pause), never
        // inside real audio. A single real stretch over the limit (speech the
        // VAD didn't split) is decoded whole.
        const long long imost = std::max(Samples(m_Settings.m_fAsrMaxSeconds), Samples(1.0));
        std::string text;
        std::vector<Piece> group;
        long long ilen = 0;
        auto flush = [&]()
        {
            const bool breal =
                std::any_of(group.begin(), group.end(), [](const Piece& _P) { return _P.m_bReal; });
            if (breal)
            {
                const std::vector<float> audio = Render(group);
                bool bok = true;
                ++m_iDecodes;
                JoinTo(text, _Decode(audio.data(), audio.size(), bok));
                _bOk = _bOk && bok;
            }
            group.clear();
            ilen = 0;
        };
        for (Piece piece : pieces)
        {
            if (!piece.m_bReal && ilen + piece.m_iOut > imost)
            {
                // Fill past the limit: what fits ends this group, the rest
                // starts the next.
                const long long iroom = std::max(0LL, imost - ilen);
                if (iroom > 0)
                {
                    Piece head = piece;
                    head.m_iOut = iroom;
                    group.push_back(head);
                }
                flush();
                piece.m_iOut -= iroom;
            }
            else if (piece.m_bReal && ilen > 0 && ilen + piece.m_iOut > imost)
            {
                flush();
            }
            if (piece.m_iOut > 0)
            {
                group.push_back(piece);
                ilen += piece.m_iOut;
            }
        }
        flush();
        return text;
    }

    std::vector<long long> GrowingTranscript::CutPoints() const
    {
        const long long iafter = Samples(m_Settings.m_fKeepAfter);
        std::vector<long long> out;
        const long long ilimit = m_iOpen >= 0 ? m_iOpen : m_iEnd;
        for (std::size_t ni = 0; ni < m_Accepted.size(); ++ni)
        {
            const auto& range = m_Accepted[ni];
            if (range.second <= m_iLiveStart || range.second > ilimit)
            {
                continue;
            }
            // Between this utterance and the next speech: its margin, or the
            // middle of the gap when the next speech comes sooner.
            long long inext = ilimit;
            if (ni + 1 < m_Accepted.size())
            {
                inext = std::min(inext, m_Accepted[ni + 1].first);
            }
            const long long icut =
                std::min(range.second + iafter, range.second + (inext - range.second) / 2);
            if (icut > m_iLiveStart && icut <= ilimit)
            {
                out.push_back(std::max(icut, range.second));
            }
        }
        return out;
    }

    void GrowingTranscript::CloseFull(const DecodeFn& _Decode)
    {
        const long long itrigger =
            Samples(std::max(1.0, m_Settings.m_fBufferSeconds - m_Settings.m_fSnapSeconds));
        const long long icap = Samples(m_Settings.m_fBufferSeconds);
        for (;;)
        {
            const std::vector<long long> cuts = CutPoints();
            if (cuts.empty() || OutLength(Layout(m_iLiveStart, cuts.back(), false)) < itrigger)
            {
                return;
            }
            // The latest cut that keeps the buffer within its cap (the first
            // one if even that is over: one long utterance).
            long long icut = cuts.front();
            for (long long icandidate : cuts)
            {
                if (OutLength(Layout(m_iLiveStart, icandidate, false)) <= icap)
                {
                    icut = icandidate;
                }
            }
            Closed closed;
            closed.m_iS0 = m_iLiveStart;
            closed.m_iS1 = icut;
            closed.m_Text = Decode(m_iLiveStart, icut, false, _Decode, closed.m_bOk);
            m_Closed.push_back(std::move(closed));
            m_iLiveStart = icut;
            // A closed buffer is never heard again: release its audio.
            if (m_iLiveStart > m_iRawStart)
            {
                const long long idrop = std::min<long long>(
                    m_iLiveStart - m_iRawStart, static_cast<long long>(m_Raw.size()));
                m_Raw.erase(m_Raw.begin(), m_Raw.begin() + static_cast<std::ptrdiff_t>(idrop));
                m_iRawStart += idrop;
            }
        }
    }

    std::string GrowingTranscript::FrozenText() const
    {
        std::string text;
        for (const Closed& closed : m_Closed)
        {
            JoinTo(text, closed.m_Text);
        }
        return text;
    }

    bool GrowingTranscript::FrozenOk() const
    {
        return std::all_of(
            m_Closed.begin(), m_Closed.end(), [](const Closed& _Closed) { return _Closed.m_bOk; });
    }

    std::string GrowingTranscript::Describe(bool _bWithOpen) const
    {
        const std::vector<Piece> pieces = Layout(m_iLiveStart, m_iEnd, _bWithOpen);
        long long ireal = 0;
        int ireals = 0;
        for (const Piece& piece : pieces)
        {
            if (piece.m_bReal)
            {
                ireal += piece.m_iOut;
                ++ireals;
            }
        }
        const double frate = m_Settings.m_iRate;
        char sz[160];
        std::snprintf(sz, sizeof(sz),
            "%d accepted, %d rejected, open %s, %d real piece(s) %.2f s of %.2f s",
            static_cast<int>(m_Accepted.size()), static_cast<int>(m_Rejected.size()),
            _bWithOpen && m_iOpen >= 0 ? "in" : "out", ireals, static_cast<double>(ireal) / frate,
            static_cast<double>(OutLength(pieces)) / frate);
        return sz;
    }

    std::string GrowingTranscript::Live(const DecodeFn& _Decode, bool& _bOk)
    {
        CloseFull(_Decode);
        _bOk = FrozenOk();
        const std::string live = Decode(m_iLiveStart, m_iEnd, true, _Decode, _bOk);
        std::string text = FrozenText();
        JoinTo(text, live);
        return text;
    }

    std::string GrowingTranscript::Final(const DecodeFn& _Decode, bool _bWithOpen, bool& _bOk)
    {
        CloseFull(_Decode);
        _bOk = FrozenOk();
        std::string text = FrozenText();
        JoinTo(text, Decode(m_iLiveStart, m_iEnd, _bWithOpen, _Decode, _bOk));
        return text;
    }

} // namespace gitgud::speech
