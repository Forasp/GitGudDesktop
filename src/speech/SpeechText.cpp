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
