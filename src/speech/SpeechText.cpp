#include "speech/SpeechText.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <random>

namespace gitgud::speech
{

    namespace
    {

        constexpr double kPi = 3.14159265358979323846;

        bool IsSpace(char _C)
        {
            return _C == ' ' || _C == '\t' || _C == '\n' || _C == '\r' || _C == '\f' || _C == '\v';
        }

        std::string Collapse(const std::string& _Text)
        {
            std::string out;
            bool bspace = false;
            for (char c : _Text)
            {
                if (IsSpace(c))
                {
                    bspace = !out.empty();
                    continue;
                }
                if (bspace)
                {
                    out += ' ';
                }
                bspace = false;
                out += c;
            }
            return out;
        }

        std::size_t CountWords(const std::string& _Text)
        {
            std::size_t n = 0;
            bool bin = false;
            for (char c : _Text)
            {
                if (IsSpace(c))
                {
                    bin = false;
                }
                else if (!bin)
                {
                    bin = true;
                    ++n;
                }
            }
            return n;
        }

        std::string Trim(const std::string& _Text)
        {
            const std::size_t nbegin = _Text.find_first_not_of(" \t\r\n");
            if (nbegin == std::string::npos)
            {
                return {};
            }
            const std::size_t nend = _Text.find_last_not_of(" \t\r\n");
            return _Text.substr(nbegin, nend - nbegin + 1);
        }

        void ReplaceAll(std::string& _Text, const std::string& _From, const std::string& _To)
        {
            for (std::size_t nat = _Text.find(_From); nat != std::string::npos;
                nat = _Text.find(_From, nat + _To.size()))
            {
                _Text.replace(nat, _From.size(), _To);
            }
        }

    } // namespace

    std::vector<std::string> SplitForSpeech(const std::string& _Text, std::size_t _nMaxBytes)
    {
        // Lines first (a line break ends a sentence too), then sentences.
        std::vector<std::string> lines;
        {
            std::string line;
            for (char c : _Text)
            {
                if (c == '\n' || c == '\r')
                {
                    lines.push_back(line);
                    line.clear();
                }
                else
                {
                    line += c;
                }
            }
            lines.push_back(line);
        }
        std::vector<std::string> parts;
        for (const std::string& rawLine : lines)
        {
            const std::string text = Collapse(rawLine);
            std::string current;
            for (std::size_t ni = 0; ni < text.size(); ++ni)
            {
                current += text[ni];
                if (text[ni] != '.' && text[ni] != '!' && text[ni] != '?')
                {
                    continue;
                }
                std::size_t nj = ni + 1;
                while (nj < text.size() &&
                       (text[nj] == '"' || text[nj] == '\'' || text[nj] == ')' || text[nj] == ']'))
                {
                    ++nj;
                }
                if (nj < text.size() && text[nj] == ' ')
                {
                    current += text.substr(ni + 1, nj - ni - 1);
                    parts.push_back(current);
                    current.clear();
                    ni = nj; // the space
                }
            }
            if (!Trim(current).empty())
            {
                parts.push_back(current);
            }
        }

        std::vector<std::string> out;
        for (std::string part : parts)
        {
            part = Trim(part);
            // Very long sentences: break at commas, then on words.
            while (part.size() > _nMaxBytes)
            {
                std::size_t ncut = part.rfind(", ", _nMaxBytes);
                if (ncut == std::string::npos || ncut < _nMaxBytes / 3)
                {
                    ncut = part.rfind(' ', _nMaxBytes);
                }
                if (ncut == std::string::npos || ncut == 0)
                {
                    ncut = _nMaxBytes;
                }
                out.push_back(Trim(part.substr(0, ncut + 1)));
                part = Trim(part.substr(ncut + 1));
            }
            if (!part.empty())
            {
                out.push_back(part);
            }
        }

        // A long first sentence: cut at its first clause break.
        if (!out.empty() && CountWords(out[0]) >= 12)
        {
            const std::string first = out[0];
            for (std::size_t ni = 0; ni + 1 < first.size(); ++ni)
            {
                if ((first[ni] == ',' || first[ni] == ';' || first[ni] == ':') &&
                    IsSpace(first[ni + 1]))
                {
                    const std::string head = first.substr(0, ni + 1);
                    const std::string tail = Trim(first.substr(ni + 1));
                    if (CountWords(head) >= 4 && CountWords(tail) >= 3)
                    {
                        out[0] = head;
                        out.insert(out.begin() + 1, tail);
                        break;
                    }
                }
            }
        }
        return out;
    }

    std::string NormalizeForSpeech(const std::string& _Sentence)
    {
        std::string text = Collapse(Trim(_Sentence));
        if (text.empty())
        {
            return text;
        }
        text[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(text[0])));
        // Smart quotes and dashes as plain ones.
        ReplaceAll(text, "\xE2\x80\x9C", "\"");
        ReplaceAll(text, "\xE2\x80\x9D", "\"");
        ReplaceAll(text, "\xE2\x80\x98", "'");
        ReplaceAll(text, "\xE2\x80\x99", "'");
        ReplaceAll(text, "\xE2\x80\x94", " - ");
        ReplaceAll(text, "\xE2\x80\x93", " - ");
        text = Collapse(text);
        ReplaceAll(text, "...", ", ");
        ReplaceAll(text, ";", ", ");
        ReplaceAll(text, ":", ",");
        ReplaceAll(text, " - ", ", ");
        text = Collapse(text);
        const char clast = text.back();
        if (clast != '.' && clast != '!' && clast != '?' && clast != ',')
        {
            text += '.';
        }
        return text;
    }

    std::vector<float> Stretch(const std::vector<float>& _Samples, double _fSpeed, int _iRate)
    {
        const std::size_t nwin = static_cast<std::size_t>(_iRate * 0.04) / 2 * 2; // 40 ms
        const std::size_t nhop = nwin / 2;
        const std::size_t ndelta = nhop / 2; // +-10 ms
        if (!(std::fabs(_fSpeed - 1.0) >= 0.01) || _fSpeed <= 0 || _Samples.size() < 2 * nwin ||
            nwin == 0)
        {
            return _Samples;
        }
        const std::size_t nout =
            static_cast<std::size_t>(static_cast<double>(_Samples.size()) / _fSpeed);
        const std::size_t nframes = nout / nhop + 1;
        const double fstep = static_cast<double>(nhop) * _fSpeed;
        std::vector<float> xp(ndelta, 0.0f);
        xp.insert(xp.end(), _Samples.begin(), _Samples.end());
        xp.resize(xp.size() + nwin + 2 * ndelta + static_cast<std::size_t>(fstep) + nhop, 0.0f);
        std::vector<float> window(nwin);
        for (std::size_t ni = 0; ni < nwin; ++ni)
        {
            window[ni] = static_cast<float>(0.5 - 0.5 * std::cos(2 * kPi * static_cast<double>(ni) /
                                                                 static_cast<double>(nwin)));
        }
        std::vector<float> y(nframes * nhop + nwin, 0.0f);
        long long iprev = 0; // the previous frame's cut, as the source's sample index
        for (std::size_t nk = 0; nk < nframes; ++nk)
        {
            const std::size_t nnominal =
                static_cast<std::size_t>(std::llround(static_cast<double>(nk) * fstep));
            std::size_t nbest = nnominal + ndelta; // index into xp of the frame's start
            if (nk > 0)
            {
                // The cut whose start best continues the previous frame's audio.
                const float* ptmpl = xp.data() + (iprev + static_cast<long long>(nhop + ndelta));
                double fbestScore = -1e300;
                std::size_t nbestShift = 0;
                for (std::size_t nshift = 0; nshift <= 2 * ndelta; ++nshift)
                {
                    const float* pregion = xp.data() + nnominal + nshift;
                    double fscore = 0;
                    for (std::size_t ni = 0; ni < nwin; ++ni)
                    {
                        fscore += static_cast<double>(pregion[ni]) * ptmpl[ni];
                    }
                    if (fscore > fbestScore)
                    {
                        fbestScore = fscore;
                        nbestShift = nshift;
                    }
                }
                nbest = nnominal + nbestShift; // nominal - delta + shift, then + delta
            }
            const float* psrc = xp.data() + nbest;
            float* pdst = y.data() + nk * nhop;
            for (std::size_t ni = 0; ni < nwin; ++ni)
            {
                pdst[ni] += psrc[ni] * window[ni];
            }
            iprev = static_cast<long long>(nbest) - static_cast<long long>(ndelta);
        }
        y.resize(nout);
        return y;
    }

    std::vector<std::pair<std::size_t, std::size_t>> VoicedParts(
        const std::vector<float>& _Samples, int _iRate, double _fFrameSeconds, double _fFloorDb)
    {
        std::vector<std::pair<std::size_t, std::size_t>> out;
        const std::size_t nframe = static_cast<std::size_t>(_iRate * _fFrameSeconds);
        const std::size_t nframes = nframe ? _Samples.size() / nframe : 0;
        if (nframes == 0)
        {
            return out;
        }
        std::vector<double> rms(nframes);
        double fmax = 0;
        for (std::size_t nf = 0; nf < nframes; ++nf)
        {
            double fsum = 0;
            for (std::size_t ni = 0; ni < nframe; ++ni)
            {
                const double x = _Samples[nf * nframe + ni];
                fsum += x * x;
            }
            rms[nf] = std::sqrt(fsum / static_cast<double>(nframe) + 1e-12);
            fmax = std::max(fmax, rms[nf]);
        }
        bool bon = false;
        std::size_t nstart = 0;
        for (std::size_t nf = 0; nf <= nframes; ++nf)
        {
            const bool bloud = nf < nframes && 20 * std::log10(rms[nf] / fmax) > _fFloorDb;
            if (bloud && !bon)
            {
                nstart = nf;
            }
            else if (!bloud && bon)
            {
                out.push_back({nstart * nframe, nf * nframe});
            }
            bon = bloud;
        }
        return out;
    }

    double TrimStrayTail(std::vector<float>& _Samples, int _iRate, const std::string& _Sentence)
    {
        // A short last clause after a comma ("Okay, sure.") can follow a real
        // pause of up to about 0.55 s.
        bool bshortLast = false;
        {
            const std::string text = Trim(_Sentence);
            const std::size_t nmark = text.find_last_of(",;:-");
            if (nmark != std::string::npos)
            {
                bshortLast = CountWords(text.substr(nmark + 1)) >= 1 &&
                             CountWords(text.substr(nmark + 1)) <= 2;
            }
        }
        const double fminGap = bshortLast ? 0.65 : 0.3;
        const double fminLen = 1.2 * (0.63 + 0.048 * static_cast<double>(_Sentence.size()));
        constexpr double kMaxSound = 0.8;
        constexpr double kKeep = 0.15;
        const auto parts = VoicedParts(_Samples, _iRate);
        if (parts.size() < 2 || static_cast<double>(_Samples.size()) < fminLen * _iRate)
        {
            return 0;
        }
        const std::size_t nprevEnd = parts[parts.size() - 2].second;
        const auto [nstart, nend] = parts.back();
        if (static_cast<double>(nstart - nprevEnd) < fminGap * _iRate ||
            static_cast<double>(nend - nstart) > kMaxSound * _iRate)
        {
            return 0;
        }
        const std::size_t ncut =
            std::min(_Samples.size(), nprevEnd + static_cast<std::size_t>(kKeep * _iRate));
        const double fcut = static_cast<double>(_Samples.size() - ncut) / _iRate;
        _Samples.resize(ncut);
        const std::size_t nfade =
            std::min(static_cast<std::size_t>(0.01 * _iRate), _Samples.size());
        for (std::size_t ni = 0; ni < nfade; ++ni)
        {
            _Samples[_Samples.size() - nfade + ni] *=
                nfade > 1 ? 1.0f - static_cast<float>(ni) / static_cast<float>(nfade - 1) : 0.0f;
        }
        return fcut;
    }

    void Roughen(std::vector<float>& _Samples, int _iRate, double _fAmount, double _fLowHz,
        double _fHighHz, unsigned _uSeed)
    {
        if (_Samples.empty() || _fAmount <= 0.0 || _iRate <= 0 || _fLowHz <= 0.0 ||
            _fHighHz <= _fLowHz || _fHighHz >= _iRate / 2.0)
        {
            return;
        }
        std::mt19937 rng(_uSeed);
        std::normal_distribution<double> gauss(0.0, 1.0);
        std::vector<double> mod(_Samples.size());
        for (double& f : mod)
        {
            f = gauss(rng);
        }
        // A band-pass biquad (0 dB peak) at the band's middle, twice, run
        // forward and then backward.
        const double fcentre = std::sqrt(_fLowHz * _fHighHz);
        const double fq = fcentre / (_fHighHz - _fLowHz);
        const double fw = 2.0 * 3.14159265358979323846 * fcentre / _iRate;
        const double falpha = std::sin(fw) / (2.0 * fq);
        const double fa0 = 1.0 + falpha;
        const double fb0 = falpha / fa0;
        const double fb2 = -falpha / fa0;
        const double fa1 = -2.0 * std::cos(fw) / fa0;
        const double fa2 = (1.0 - falpha) / fa0;
        auto pass = [&](bool _bBackward)
        {
            double fx1 = 0.0, fx2 = 0.0, fy1 = 0.0, fy2 = 0.0;
            const std::size_t ncount = mod.size();
            for (std::size_t nk = 0; nk < ncount; ++nk)
            {
                double& f = mod[_bBackward ? ncount - 1 - nk : nk];
                const double fy = fb0 * f + fb2 * fx2 - fa1 * fy1 - fa2 * fy2;
                fx2 = fx1;
                fx1 = f;
                fy2 = fy1;
                fy1 = fy;
                f = fy;
            }
        };
        for (int ipass = 0; ipass < 2; ++ipass)
        {
            pass(false);
            pass(true);
        }
        double fsum = 0.0;
        for (double f : mod)
        {
            fsum += f * f;
        }
        const double fstd = std::sqrt(fsum / static_cast<double>(mod.size()));
        if (fstd <= 0.0)
        {
            return;
        }
        for (std::size_t ni = 0; ni < _Samples.size(); ++ni)
        {
            const double fgain = std::max(0.0, 1.0 + _fAmount * mod[ni] / fstd);
            _Samples[ni] = static_cast<float>(_Samples[ni] * fgain);
        }
    }

} // namespace gitgud::speech
