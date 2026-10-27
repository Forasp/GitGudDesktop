// GrowingTranscript (src/speech): the listener's growing-mode transcript.
// No models: "words" are tone bursts, one frequency per word, and the fake
// decoder names the bursts it hears, so a test sees exactly which audio a
// decode got: nothing from rejected or unjudged audio, every word once.

#include <catch2/catch_test_macros.hpp>

#include "speech/GrowingTranscript.h"

#include <algorithm>
#include <cmath>
#include <sstream>
#include <string>
#include <vector>

using gitgud::speech::GrowingTranscript;

namespace
{
    constexpr int kRate = 16000;
    constexpr double kPi = 3.14159265358979323846;

    long long At(double _fSeconds)
    {
        return static_cast<long long>(std::llround(_fSeconds * kRate));
    }

    // Word k is a tone at 300 + 120 * k Hz.
    double WordHz(int _iWord)
    {
        return 300.0 + 120.0 * _iWord;
    }

    // A recording: silence with words at given times (0.25 s bursts).
    struct Recording
    {
        std::vector<float> m_Samples;

        explicit Recording(double _fSeconds)
            : m_Samples(static_cast<std::size_t>(At(_fSeconds)), 0.0f)
        {
        }

        // A word burst at `_fStart`; returns its sample range.
        std::pair<long long, long long> Word(int _iWord, double _fStart, double _fLength = 0.25)
        {
            const long long is0 = At(_fStart);
            const long long is1 = At(_fStart + _fLength);
            for (long long ik = is0; ik < is1; ++ik)
            {
                m_Samples[static_cast<std::size_t>(ik)] =
                    0.3f * static_cast<float>(std::sin(
                               2 * kPi * WordHz(_iWord) * static_cast<double>(ik - is0) / kRate));
            }
            return {is0, is1};
        }
    };

    // Names the bursts in the audio: "w<k>" for each, in order.
    struct FakeDecoder
    {
        int m_iCalls = 0;
        bool m_bFail = false;
        std::size_t m_nLongest = 0; // the most samples one call got

        std::string operator()(const float* _pSamples, std::size_t _nCount, bool& _bOk)
        {
            ++m_iCalls;
            _bOk = !m_bFail;
            m_nLongest = std::max(m_nLongest, _nCount);
            const std::size_t nframe = kRate / 100;
            std::vector<bool> active;
            for (std::size_t ni = 0; ni + nframe <= _nCount; ni += nframe)
            {
                double fsum = 0;
                for (std::size_t nk = 0; nk < nframe; ++nk)
                {
                    fsum += static_cast<double>(_pSamples[ni + nk]) * _pSamples[ni + nk];
                }
                active.push_back(std::sqrt(fsum / nframe) > 0.05);
            }
            std::ostringstream text;
            std::size_t ni = 0;
            while (ni < active.size())
            {
                if (!active[ni])
                {
                    ++ni;
                    continue;
                }
                std::size_t nend = ni;
                while (nend < active.size() && active[nend])
                {
                    ++nend;
                }
                if (nend - ni >= 5) // 50 ms or more
                {
                    const std::size_t ns0 = ni * nframe;
                    const std::size_t ns1 = nend * nframe;
                    int icross = 0;
                    for (std::size_t nk = ns0 + 1; nk < ns1; ++nk)
                    {
                        if ((_pSamples[nk - 1] < 0) != (_pSamples[nk] < 0))
                        {
                            ++icross;
                        }
                    }
                    const double fhz = icross / 2.0 / (static_cast<double>(ns1 - ns0) / kRate);
                    const int iword = static_cast<int>(std::lround((fhz - 300.0) / 120.0));
                    text << (text.tellp() > 0 ? " " : "") << "w" << iword;
                }
                ni = nend;
            }
            return text.str();
        }
    };

    GrowingTranscript::DecodeFn Bind(FakeDecoder& _Decoder)
    {
        return [&_Decoder](const float* _pS, std::size_t _nN, bool& _bOk)
        {
            return _Decoder(_pS, _nN, _bOk);
        };
    }

    // Feeds the recording in 20 ms chunks up to `_fUntil` seconds.
    void Feed(GrowingTranscript& _Transcript, const Recording& _Rec, double _fUntil)
    {
        const long long iend =
            std::min<long long>(At(_fUntil), static_cast<long long>(_Rec.m_Samples.size()));
        while (_Transcript.End() < iend)
        {
            const long long inext = std::min(_Transcript.End() + kRate / 50, iend);
            _Transcript.Append(_Rec.m_Samples.data() + _Transcript.End(),
                static_cast<std::size_t>(inext - _Transcript.End()));
        }
    }

    GrowingTranscript::Settings Defaults()
    {
        GrowingTranscript::Settings settings;
        settings.m_fFillLevel = 0.0003;
        return settings;
    }
} // namespace

TEST_CASE("Growing transcript hears only accepted speech", "[speech][growing]")
{
    Recording rec(12);
    const auto a = rec.Word(0, 1.0);
    const auto b = rec.Word(1, 2.0);
    const auto echo = rec.Word(5, 4.0); // the app's own voice: rejected
    rec.Word(7, 8.0);                   // background below the VAD: never accepted
    const auto c = rec.Word(2, 10.0);
    GrowingTranscript transcript(Defaults(), 0);
    Feed(transcript, rec, 12);
    transcript.Accept(a.first - At(0.1), b.second);
    transcript.Reject(echo.first, echo.second);
    transcript.Accept(c.first - At(0.1), c.second);
    FakeDecoder decoder;
    bool bok = false;
    CHECK(transcript.Live(Bind(decoder), bok) == "w0 w1 w2");
    CHECK(bok);
}

TEST_CASE("Growing transcript margins never reach into rejected audio", "[speech][growing]")
{
    Recording rec(6);
    const auto a = rec.Word(0, 1.0);
    const auto echo = rec.Word(5, 1.5); // starts 0.25 s after the accepted word: inside its margin
    GrowingTranscript transcript(Defaults(), 0);
    Feed(transcript, rec, 6);
    transcript.Accept(a.first, a.second);
    transcript.Reject(echo.first, echo.second);
    FakeDecoder decoder;
    bool bok = false;
    CHECK(transcript.Live(Bind(decoder), bok) == "w0");
}

TEST_CASE("Growing transcript keeps unjudged speech out of frozen text", "[speech][growing]")
{
    GrowingTranscript::Settings settings = Defaults();
    settings.m_fBufferSeconds = 6;
    settings.m_fSnapSeconds = 2;
    settings.m_fAsrMaxSeconds = 8;
    Recording rec(20);
    std::vector<std::pair<long long, long long>> words;
    for (int ik = 0; ik < 6; ++ik)
    {
        words.push_back(rec.Word(ik % 8, 1.0 + 2.0 * ik));
    }
    const auto open = rec.Word(9, 14.0);
    GrowingTranscript transcript(settings, 0);
    Feed(transcript, rec, 15);
    for (const auto& word : words)
    {
        transcript.Accept(word.first - At(0.1), word.second);
    }
    transcript.SetOpen(open.first - At(0.1));
    FakeDecoder decoder;
    bool bok = false;
    const std::string live = transcript.Live(Bind(decoder), bok);
    CHECK(live == "w0 w1 w2 w3 w4 w5 w9");
    CHECK(transcript.ClosedCount() >= 1);
    CHECK(transcript.FrozenText().find("w9") == std::string::npos);
    CHECK(transcript.Final(Bind(decoder), false, bok) == "w0 w1 w2 w3 w4 w5");
    CHECK(transcript.Final(Bind(decoder), true, bok) == "w0 w1 w2 w3 w4 w5 w9");
}

TEST_CASE(
    "Growing transcript closes buffers between utterances, every word once", "[speech][growing]")
{
    GrowingTranscript::Settings settings = Defaults();
    settings.m_fBufferSeconds = 10;
    settings.m_fSnapSeconds = 2;
    settings.m_fAsrMaxSeconds = 12;
    Recording rec(130);
    std::string expected;
    GrowingTranscript transcript(settings, 0);
    FakeDecoder decoder;
    bool bok = false;
    // 20 utterances of three words, 6 s apart; live passes as it grows.
    for (int iu = 0; iu < 20; ++iu)
    {
        const double fstart = 2.0 + 6.0 * iu;
        std::pair<long long, long long> first{};
        std::pair<long long, long long> last{};
        for (int iw = 0; iw < 3; ++iw)
        {
            const int iword = (iu * 3 + iw) % 9;
            const auto range = rec.Word(iword, fstart + 0.4 * iw);
            first = iw == 0 ? range : first;
            last = range;
            expected += (expected.empty() ? "" : " ") + std::string("w") + std::to_string(iword);
        }
        Feed(transcript, rec, fstart + 1.5);
        transcript.Accept(first.first - At(0.2), last.second + At(0.1));
        transcript.Live(Bind(decoder), bok);
        CHECK(bok);
    }
    Feed(transcript, rec, 130);
    CHECK(transcript.ClosedCount() >= 3);
    CHECK(transcript.Final(Bind(decoder), false, bok) == expected);
    CHECK(bok);
}

TEST_CASE("Growing transcript shortens long pauses and never touches speech or its margins",
    "[speech][growing]")
{
    GrowingTranscript::Settings settings = Defaults();
    settings.m_fFillLevel = 0;
    Recording rec(20);
    const auto a = rec.Word(0, 1.0);
    const auto b = rec.Word(1, 15.0); // 13.75 s of silence between
    GrowingTranscript transcript(settings, 0);
    Feed(transcript, rec, 20);
    transcript.Accept(a.first, a.second);
    transcript.Accept(b.first, b.second);
    const std::vector<float> audio = transcript.Audio(0, At(20), false);
    // Real audio: each word with 0.9 s on both sides; fill: the 1 s before
    // the first margin (kept: under gapMax), 2 x shortened gaps (0.5 s each).
    const long long iexpected = 2 * (At(0.25) + 2 * At(0.9)) + At(0.1) + 2 * At(0.5);
    CHECK(static_cast<long long>(audio.size()) == iexpected);
    // The first word is the original audio, sample for sample.
    const long long ioffset = At(0.1); // 1.0 - 0.9 s of leading fill
    bool bsame = true;
    for (long long ik = 0; ik < a.second - a.first; ++ik)
    {
        bsame = bsame && audio[static_cast<std::size_t>(ioffset + At(0.9) + ik)] ==
                             rec.m_Samples[static_cast<std::size_t>(a.first + ik)];
    }
    CHECK(bsame);
}

TEST_CASE("Growing transcript splits an over-long decode at a pause", "[speech][growing]")
{
    GrowingTranscript::Settings settings = Defaults();
    settings.m_fAsrMaxSeconds = 3;
    settings.m_fBufferSeconds = 60; // no buffer closes: only the decode limit splits
    Recording rec(12);
    std::vector<std::pair<long long, long long>> words;
    for (int ik = 0; ik < 4; ++ik)
    {
        words.push_back(rec.Word(ik, 1.0 + 2.6 * ik));
    }
    GrowingTranscript transcript(settings, 0);
    Feed(transcript, rec, 12);
    for (const auto& word : words)
    {
        transcript.Accept(word.first, word.second);
    }
    FakeDecoder decoder;
    bool bok = false;
    CHECK(transcript.Live(Bind(decoder), bok) == "w0 w1 w2 w3");
    CHECK(decoder.m_iCalls >= 2);
}

TEST_CASE("Growing transcript reports a failed decode", "[speech][growing]")
{
    Recording rec(4);
    const auto a = rec.Word(0, 1.0);
    GrowingTranscript transcript(Defaults(), 0);
    Feed(transcript, rec, 4);
    transcript.Accept(a.first, a.second);
    FakeDecoder decoder;
    decoder.m_bFail = true;
    bool bok = true;
    transcript.Live(Bind(decoder), bok);
    CHECK_FALSE(bok);
}

TEST_CASE("Growing transcript remembers a closed buffer's failed decode", "[speech][growing]")
{
    // A closed buffer is decoded once and its audio released: if that
    // decode failed, every later pass says so.
    GrowingTranscript::Settings settings = Defaults();
    settings.m_fBufferSeconds = 6;
    settings.m_fSnapSeconds = 2;
    settings.m_fAsrMaxSeconds = 8;
    Recording rec(14);
    std::vector<std::pair<long long, long long>> words;
    for (int ik = 0; ik < 6; ++ik)
    {
        words.push_back(rec.Word(ik, 1.0 + 2.0 * ik));
    }
    GrowingTranscript transcript(settings, 0);
    Feed(transcript, rec, 14);
    for (const auto& word : words)
    {
        transcript.Accept(word.first - At(0.1), word.second);
    }
    FakeDecoder decoder;
    decoder.m_bFail = true;
    bool bok = true;
    transcript.Live(Bind(decoder), bok);
    CHECK_FALSE(bok);
    REQUIRE(transcript.ClosedCount() >= 1);

    decoder.m_bFail = false;
    bok = true;
    transcript.Live(Bind(decoder), bok);
    CHECK_FALSE(bok);
    bok = true;
    transcript.Final(Bind(decoder), false, bok);
    CHECK_FALSE(bok);
}

TEST_CASE("Growing transcript cuts the quiet after speech at asrMaxSeconds", "[speech][growing]")
{
    // One word with its margins (2.8 s) and the quiet after it (1.1 s, under
    // gapMax): together over the limit, so the quiet is cut at it.
    GrowingTranscript::Settings settings = Defaults();
    settings.m_fAsrMaxSeconds = 3;
    Recording rec(4);
    const auto a = rec.Word(0, 1.0, 1.0);
    GrowingTranscript transcript(settings, 0);
    Feed(transcript, rec, 4);
    transcript.Accept(a.first, a.second);
    FakeDecoder decoder;
    bool bok = false;
    CHECK(transcript.Live(Bind(decoder), bok) == "w0");
    CHECK(bok);
    CHECK(decoder.m_iCalls == 1);
    CHECK(decoder.m_nLongest == static_cast<std::size_t>(At(3)));
}

TEST_CASE("Growing transcript decodes nothing without accepted or open speech", "[speech][growing]")
{
    Recording rec(5);
    rec.Word(3, 2.0); // background only
    GrowingTranscript transcript(Defaults(), 0);
    Feed(transcript, rec, 5);
    FakeDecoder decoder;
    bool bok = false;
    CHECK(transcript.Live(Bind(decoder), bok).empty());
    CHECK(decoder.m_iCalls == 0);
    CHECK(bok);
}
