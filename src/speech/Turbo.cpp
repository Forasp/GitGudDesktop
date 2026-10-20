#include "speech/Turbo.h"

#include "platform/Shell.h"
#include "speech/Gpt2Tokenizer.h"
#include "speech/SpeechText.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <numeric>
#include <set>
#include <sstream>

namespace gitgud::speech
{

    namespace fs = std::filesystem;

    // ---- Tensor ----------------------------------------------------------------

    float HalfToFloat(uint16_t _uHalf)
    {
        const uint32_t usign = static_cast<uint32_t>(_uHalf & 0x8000) << 16;
        uint32_t uexp = (_uHalf >> 10) & 0x1F;
        uint32_t umant = _uHalf & 0x3FF;
        uint32_t ubits = 0;
        if (uexp == 0)
        {
            if (umant == 0)
            {
                ubits = usign;
            }
            else
            {
                // Subnormal: normalize.
                int ie = -1;
                do
                {
                    ++ie;
                    umant <<= 1;
                } while ((umant & 0x400) == 0);
                umant &= 0x3FF;
                ubits = usign | (static_cast<uint32_t>(127 - 15 - ie) << 23) | (umant << 13);
            }
        }
        else if (uexp == 0x1F)
        {
            ubits = usign | 0x7F800000 | (umant << 13);
        }
        else
        {
            ubits = usign | ((uexp + 127 - 15) << 23) | (umant << 13);
        }
        float f;
        std::memcpy(&f, &ubits, 4);
        return f;
    }

    uint16_t FloatToHalf(float _fValue)
    {
        uint32_t ubits;
        std::memcpy(&ubits, &_fValue, 4);
        const uint16_t usign = static_cast<uint16_t>((ubits >> 16) & 0x8000);
        const int iexp = static_cast<int>((ubits >> 23) & 0xFF) - 127 + 15;
        uint32_t umant = ubits & 0x7FFFFF;
        if (((ubits >> 23) & 0xFF) == 0xFF)
        {
            return static_cast<uint16_t>(usign | 0x7C00 | (umant ? 0x200 : 0));
        }
        if (iexp >= 0x1F)
        {
            return static_cast<uint16_t>(usign | 0x7C00);
        }
        if (iexp <= 0)
        {
            if (iexp < -10)
            {
                return usign;
            }
            umant |= 0x800000;
            const int ishift = 14 - iexp;
            uint32_t uhalf = umant >> ishift;
            if ((umant >> (ishift - 1)) & 1)
            {
                ++uhalf; // round
            }
            return static_cast<uint16_t>(usign | uhalf);
        }
        uint16_t uhalf = static_cast<uint16_t>(usign | (iexp << 10) | (umant >> 13));
        if (umant & 0x1000)
        {
            ++uhalf; // round (may carry into the exponent, which is right)
        }
        return uhalf;
    }

    std::size_t Tensor::Count() const
    {
        std::size_t n = 1;
        for (int64_t d : m_Shape)
        {
            n *= static_cast<std::size_t>(std::max<int64_t>(d, 0));
        }
        return n;
    }

    std::vector<float> Tensor::Floats() const
    {
        std::vector<float> out;
        const std::size_t n = std::min(Count(), m_Data.size() / ElementSize());
        if (m_eType == Type::Float)
        {
            out.resize(n);
            std::memcpy(out.data(), m_Data.data(), n * 4);
        }
        else if (m_eType == Type::Half)
        {
            out.resize(n);
            for (std::size_t ni = 0; ni < n; ++ni)
            {
                uint16_t u;
                std::memcpy(&u, m_Data.data() + 2 * ni, 2);
                out[ni] = HalfToFloat(u);
            }
        }
        return out;
    }

    std::vector<int64_t> Tensor::Ints() const
    {
        std::vector<int64_t> out;
        if (m_eType == Type::Int64)
        {
            out.resize(std::min(Count(), m_Data.size() / 8));
            std::memcpy(out.data(), m_Data.data(), out.size() * 8);
        }
        return out;
    }

    Tensor Tensor::FromFloats(const std::vector<float>& _Values, std::vector<int64_t> _Shape)
    {
        Tensor t;
        t.m_eType = Type::Float;
        t.m_Shape = std::move(_Shape);
        t.m_Data.resize(_Values.size() * 4);
        std::memcpy(t.m_Data.data(), _Values.data(), t.m_Data.size());
        return t;
    }

    Tensor Tensor::FromInts(const std::vector<int64_t>& _Values, std::vector<int64_t> _Shape)
    {
        Tensor t;
        t.m_eType = Type::Int64;
        t.m_Shape = std::move(_Shape);
        t.m_Data.resize(_Values.size() * 8);
        std::memcpy(t.m_Data.data(), _Values.data(), t.m_Data.size());
        return t;
    }

    Tensor Tensor::As(Type _eType) const
    {
        if (_eType == m_eType || m_eType == Type::Int64 || _eType == Type::Int64)
        {
            return *this;
        }
        const std::vector<float> values = Floats();
        if (_eType == Type::Float)
        {
            return FromFloats(values, m_Shape);
        }
        Tensor t;
        t.m_eType = Type::Half;
        t.m_Shape = m_Shape;
        t.m_Data.resize(values.size() * 2);
        for (std::size_t ni = 0; ni < values.size(); ++ni)
        {
            const uint16_t u = FloatToHalf(values[ni]);
            std::memcpy(t.m_Data.data() + 2 * ni, &u, 2);
        }
        return t;
    }

    // ---- VoiceConditioning -------------------------------------------------------

    namespace
    {

        constexpr char kMagic[] = "GITGUD-VOICE 1\n";

        void PutU64(std::string& _Out, uint64_t _uValue)
        {
            for (int i = 0; i < 8; ++i)
            {
                _Out += static_cast<char>((_uValue >> (8 * i)) & 0xFF);
            }
        }

        bool GetU64(const std::string& _In, std::size_t& _nAt, uint64_t& _uOut)
        {
            if (_nAt + 8 > _In.size())
            {
                return false;
            }
            _uOut = 0;
            for (int i = 0; i < 8; ++i)
            {
                _uOut |= static_cast<uint64_t>(static_cast<unsigned char>(_In[_nAt + i]))
                         << (8 * i);
            }
            _nAt += 8;
            return true;
        }

    } // namespace

    bool VoiceConditioning::Save(const std::string& _Path, std::string& _Error) const
    {
        std::string out = kMagic;
        for (const Tensor* pt :
            {&m_CondEmb, &m_PromptToken, &m_SpeakerEmbeddings, &m_SpeakerFeatures})
        {
            PutU64(out, static_cast<uint64_t>(pt->m_eType));
            PutU64(out, pt->m_Shape.size());
            for (int64_t d : pt->m_Shape)
            {
                PutU64(out, static_cast<uint64_t>(d));
            }
            PutU64(out, pt->m_Data.size());
            out.append(reinterpret_cast<const char*>(pt->m_Data.data()), pt->m_Data.size());
        }
        return platform::WriteFileAtomically(_Path, out, _Error);
    }

    bool VoiceConditioning::Load(const std::string& _Path, std::string& _Error)
    {
        std::ifstream file(fs::u8path(_Path), std::ios::binary);
        if (!file)
        {
            _Error = "no voice file " + _Path;
            return false;
        }
        std::stringstream ss;
        ss << file.rdbuf();
        const std::string in = ss.str();
        const std::size_t nmagic = sizeof(kMagic) - 1;
        if (in.compare(0, nmagic, kMagic) != 0)
        {
            _Error = _Path + " isn't a voice file";
            return false;
        }
        std::size_t nat = nmagic;
        VoiceConditioning loaded;
        for (Tensor* pt : {&loaded.m_CondEmb, &loaded.m_PromptToken, &loaded.m_SpeakerEmbeddings,
                 &loaded.m_SpeakerFeatures})
        {
            uint64_t utype = 0;
            uint64_t urank = 0;
            if (!GetU64(in, nat, utype) || utype > 2 || !GetU64(in, nat, urank) || urank > 8)
            {
                _Error = _Path + " is damaged";
                return false;
            }
            pt->m_eType = static_cast<Tensor::Type>(utype);
            for (uint64_t ui = 0; ui < urank; ++ui)
            {
                uint64_t udim = 0;
                if (!GetU64(in, nat, udim) || udim > (1u << 24))
                {
                    _Error = _Path + " is damaged";
                    return false;
                }
                pt->m_Shape.push_back(static_cast<int64_t>(udim));
            }
            uint64_t ubytes = 0;
            if (!GetU64(in, nat, ubytes) || nat + ubytes > in.size() ||
                ubytes != pt->Count() * pt->ElementSize())
            {
                _Error = _Path + " is damaged";
                return false;
            }
            pt->m_Data.assign(in.begin() + static_cast<std::ptrdiff_t>(nat),
                in.begin() + static_cast<std::ptrdiff_t>(nat + ubytes));
            nat += ubytes;
        }
        *this = std::move(loaded);
        return true;
    }

    // ---- Sampling ----------------------------------------------------------------

    int64_t SampleToken(std::vector<float>& _Logits, const std::vector<int64_t>& _Previous,
        const SamplerConfig& _Config, std::mt19937& _Rng)
    {
        const std::size_t nvocab = _Logits.size();
        if (nvocab == 0)
        {
            return kTurboStop;
        }
        // The repetition penalty, once per token seen.
        std::set<int64_t> seen(_Previous.begin(), _Previous.end());
        for (int64_t id : seen)
        {
            if (id >= 0 && static_cast<std::size_t>(id) < nvocab)
            {
                float& f = _Logits[static_cast<std::size_t>(id)];
                f = f < 0 ? f * _Config.m_fRepetitionPenalty : f / _Config.m_fRepetitionPenalty;
            }
        }
        const float ftemp = _Config.m_fTemperature > 0 ? _Config.m_fTemperature : 1.0f;
        std::vector<std::size_t> order(nvocab);
        std::iota(order.begin(), order.end(), 0);
        const std::size_t nk = std::min<std::size_t>(
            nvocab, _Config.m_iTopK > 0 ? static_cast<std::size_t>(_Config.m_iTopK) : nvocab);
        std::partial_sort(order.begin(), order.begin() + static_cast<std::ptrdiff_t>(nk),
            order.end(), [&](std::size_t _A, std::size_t _B) { return _Logits[_A] > _Logits[_B]; });
        order.resize(nk);
        std::vector<double> p(nk);
        const double ftop = _Logits[order[0]] / ftemp;
        double fsum = 0;
        for (std::size_t ni = 0; ni < nk; ++ni)
        {
            p[ni] = std::exp(_Logits[order[ni]] / ftemp - ftop);
            fsum += p[ni];
        }
        for (double& x : p)
        {
            x /= fsum;
        }
        // top_p: the first index where the running total reaches it, plus one.
        std::size_t nkeep = nk;
        double frun = 0;
        for (std::size_t ni = 0; ni < nk; ++ni)
        {
            frun += p[ni];
            if (frun >= _Config.m_fTopP)
            {
                nkeep = ni + 1;
                break;
            }
        }
        // min_p: at least this share of the top token's probability.
        std::size_t nminP = 0;
        for (double x : p)
        {
            if (x >= _Config.m_fMinP * p[0])
            {
                ++nminP;
            }
        }
        nkeep = std::max<std::size_t>(1, std::min(nkeep, nminP));
        std::discrete_distribution<std::size_t> pick(
            p.begin(), p.begin() + static_cast<std::ptrdiff_t>(nkeep));
        return static_cast<int64_t>(order[pick(_Rng)]);
    }

    // ---- TurboSynth --------------------------------------------------------------

    TurboSynth::TurboSynth(
        ITurboNets& _Nets, const Gpt2Tokenizer& _Tokenizer, SamplerConfig _Config)
        : m_Nets(_Nets), m_Tokenizer(_Tokenizer), m_Config(_Config)
    {
    }

    bool TurboSynth::Say(const std::string& _Sentence, const VoiceConditioning& _Voice,
        double _fSpeed, const std::function<bool()>& _Stopped, std::vector<float>& _Audio,
        std::string& _Error)
    {
        _Audio.clear();
        m_iLastTokens = 0;
        const std::string text = NormalizeForSpeech(_Sentence);
        if (text.empty())
        {
            return true;
        }
        Tensor embeds;
        if (!m_Nets.Embed(m_Tokenizer.Encode(text), embeds))
        {
            _Error = "the text embedding failed";
            return false;
        }
        // The voice's conditioning first, then the text.
        const Tensor cond = _Voice.m_CondEmb.As(embeds.m_eType);
        if (cond.m_Shape.size() != 3 || embeds.m_Shape.size() != 3 ||
            cond.m_Shape[2] != embeds.m_Shape[2])
        {
            _Error = "the voice doesn't fit this model";
            return false;
        }
        Tensor first;
        first.m_eType = embeds.m_eType;
        first.m_Shape = {1, cond.m_Shape[1] + embeds.m_Shape[1], embeds.m_Shape[2]};
        first.m_Data = cond.m_Data;
        first.m_Data.insert(first.m_Data.end(), embeds.m_Data.begin(), embeds.m_Data.end());

        m_Nets.Reset();
        std::vector<int64_t> generated{kTurboStart};
        const std::size_t nmax = std::min<std::size_t>(1024, 60 + 3 * text.size());
        int64_t iposition = 0;
        Tensor input = std::move(first);
        std::vector<float> logits;
        while (generated.size() <= nmax)
        {
            if (_Stopped && _Stopped())
            {
                return true; // nothing to say any more
            }
            if (!m_Nets.Step(input, iposition, logits))
            {
                _Error = "the language model failed";
                return false;
            }
            iposition += input.m_Shape[1];
            const int64_t inext = SampleToken(logits, generated, m_Config, m_Rng);
            generated.push_back(inext);
            if (inext == kTurboStop)
            {
                break;
            }
            if (!m_Nets.Embed({inext}, input))
            {
                _Error = "the token embedding failed";
                return false;
            }
        }
        std::vector<int64_t> speech = _Voice.m_PromptToken.Ints();
        for (std::size_t ni = 1; ni < generated.size(); ++ni)
        {
            if (generated[ni] != kTurboStop)
            {
                speech.push_back(generated[ni]);
                ++m_iLastTokens;
            }
        }
        speech.insert(speech.end(), 3, kTurboSilence);
        if (_Stopped && _Stopped())
        {
            return true;
        }
        std::vector<float> audio;
        if (!m_Nets.Decode(speech, _Voice.m_SpeakerEmbeddings, _Voice.m_SpeakerFeatures, audio))
        {
            _Error = "the speech decoder failed";
            return false;
        }
        TrimStrayTail(audio, kTurboRate, text);
        _Audio = Stretch(audio, _fSpeed, kTurboRate);
        return true;
    }

    bool TurboSynth::Clone(
        const std::vector<float>& _Audio, VoiceConditioning& _Out, std::string& _Error)
    {
        if (_Audio.size() < static_cast<std::size_t>(kTurboRate))
        {
            _Error = "the recording is shorter than a second";
            return false;
        }
        std::vector<Tensor> six;
        std::vector<Tensor> ten;
        const std::vector<float> first6(_Audio.begin(),
            _Audio.begin() +
                static_cast<std::ptrdiff_t>(std::min<std::size_t>(_Audio.size(), 6 * kTurboRate)));
        const std::vector<float> first10(_Audio.begin(),
            _Audio.begin() +
                static_cast<std::ptrdiff_t>(std::min<std::size_t>(_Audio.size(), 10 * kTurboRate)));
        if (!m_Nets.Encode(first6, six) || six.size() != 4 || !m_Nets.Encode(first10, ten) ||
            ten.size() != 4)
        {
            _Error = "the speech encoder failed";
            return false;
        }
        _Out.m_CondEmb = six[0];
        _Out.m_PromptToken = ten[1];
        _Out.m_SpeakerEmbeddings = ten[2];
        _Out.m_SpeakerFeatures = ten[3];
        return true;
    }

    // ---- WAV ---------------------------------------------------------------------

    bool ReadWav24k(const std::string& _Path, std::vector<float>& _Out, std::string& _Error)
    {
        std::ifstream file(fs::u8path(_Path), std::ios::binary);
        std::stringstream ss;
        ss << file.rdbuf();
        const std::string bytes = ss.str();
        auto u16 = [&](std::size_t _nAt)
        {
            return static_cast<unsigned>(static_cast<unsigned char>(bytes[_nAt])) |
                   (static_cast<unsigned>(static_cast<unsigned char>(bytes[_nAt + 1])) << 8);
        };
        auto u32 = [&](std::size_t _nAt)
        {
            return u16(_nAt) | (u16(_nAt + 2) << 16);
        };
        if (bytes.size() < 12 || bytes.compare(0, 4, "RIFF") != 0 ||
            bytes.compare(8, 4, "WAVE") != 0)
        {
            _Error = "not a WAV file: " + _Path;
            return false;
        }
        unsigned uformat = 0;
        unsigned uchannels = 0;
        unsigned urate = 0;
        unsigned ubits = 0;
        for (std::size_t nat = 12; nat + 8 <= bytes.size();)
        {
            const std::string id = bytes.substr(nat, 4);
            const std::size_t nsize = u32(nat + 4);
            const std::size_t nbody = nat + 8;
            if (id == "fmt " && nsize >= 16 && nbody + 16 <= bytes.size())
            {
                uformat = u16(nbody);
                uchannels = u16(nbody + 2);
                urate = u32(nbody + 4);
                ubits = u16(nbody + 14);
                if (uformat == 0xFFFE && nsize >= 26)
                {
                    uformat = u16(nbody + 24); // WAVE_FORMAT_EXTENSIBLE: the subformat
                }
            }
            else if (id == "data" && uchannels > 0 && urate >= 8000)
            {
                const bool bpcm = uformat == 1 && ubits == 16;
                const bool bfloat = uformat == 3 && ubits == 32;
                if (!bpcm && !bfloat)
                {
                    break;
                }
                const std::size_t nframeBytes = (ubits / 8) * uchannels;
                const std::size_t nframes = std::min(nsize, bytes.size() - nbody) / nframeBytes;
                std::vector<float> mono(nframes);
                for (std::size_t nf = 0; nf < nframes; ++nf)
                {
                    double fsum = 0;
                    for (unsigned uc = 0; uc < uchannels; ++uc)
                    {
                        const std::size_t nat2 = nbody + nf * nframeBytes + uc * (ubits / 8);
                        if (bpcm)
                        {
                            fsum += static_cast<int16_t>(u16(nat2)) / 32768.0;
                        }
                        else
                        {
                            float f;
                            std::memcpy(&f, bytes.data() + nat2, 4);
                            fsum += f;
                        }
                    }
                    mono[nf] = static_cast<float>(fsum / uchannels);
                }
                if (urate == static_cast<unsigned>(kTurboRate))
                {
                    _Out = std::move(mono);
                    return true;
                }
                // Linear resampling to 24 kHz.
                const double fratio = static_cast<double>(urate) / kTurboRate;
                const std::size_t nout =
                    static_cast<std::size_t>(static_cast<double>(nframes) / fratio);
                _Out.resize(nout);
                for (std::size_t ni = 0; ni < nout; ++ni)
                {
                    const double fpos = static_cast<double>(ni) * fratio;
                    const std::size_t n0 = static_cast<std::size_t>(fpos);
                    const std::size_t n1 = std::min(n0 + 1, nframes - 1);
                    const double ffrac = fpos - static_cast<double>(n0);
                    _Out[ni] = static_cast<float>(mono[n0] * (1 - ffrac) + mono[n1] * ffrac);
                }
                return true;
            }
            nat = nbody + nsize + (nsize & 1);
        }
        _Error = _Path + " isn't a 16-bit or float WAV file";
        return false;
    }

} // namespace gitgud::speech
