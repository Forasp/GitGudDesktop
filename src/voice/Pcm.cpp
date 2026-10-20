#include "voice/Pcm.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <system_error>

namespace gitgud::voice
{

    std::string ToBytes(const int16_t* _pSamples, std::size_t _nCount)
    {
        std::string out(_nCount * 2, '\0');
        for (std::size_t i = 0; i < _nCount; ++i)
        {
            const auto uvalue = static_cast<uint16_t>(_pSamples[i]);
            out[i * 2] = static_cast<char>(uvalue & 0xFF);
            out[i * 2 + 1] = static_cast<char>(uvalue >> 8);
        }
        return out;
    }

    std::vector<int16_t> FromBytes(const std::string& _Bytes)
    {
        std::vector<int16_t> out(_Bytes.size() / 2);
        for (std::size_t i = 0; i < out.size(); ++i)
        {
            const auto ulow = static_cast<uint16_t>(static_cast<unsigned char>(_Bytes[i * 2]));
            const auto uhigh = static_cast<uint16_t>(static_cast<unsigned char>(_Bytes[i * 2 + 1]));
            out[i] = static_cast<int16_t>(static_cast<uint16_t>(ulow | (uhigh << 8)));
        }
        return out;
    }

    int16_t ToPcm16(float _fSample)
    {
        const float fclipped = std::clamp(_fSample, -1.0f, 1.0f);
        return static_cast<int16_t>(std::lround(fclipped * 32767.0f));
    }

    double Level(const int16_t* _pSamples, std::size_t _nCount)
    {
        if (_nCount == 0)
        {
            return 0.0;
        }
        double fsum = 0.0;
        for (std::size_t i = 0; i < _nCount; ++i)
        {
            const double fsample = _pSamples[i] / 32768.0;
            fsum += fsample * fsample;
        }
        const double frms = std::sqrt(fsum / static_cast<double>(_nCount));
        if (frms <= 0.0)
        {
            return 0.0;
        }
        const double fdb = 20.0 * std::log10(frms);
        return std::clamp((fdb + 60.0) / 60.0, 0.0, 1.0);
    }

    namespace
    {

        // A mean square of full-scale samples as whole dBFS.
        int Decibels(double _fMeanSquare)
        {
            if (_fMeanSquare <= 0.0)
            {
                return kQuietDb;
            }
            const double fdb = 10.0 * std::log10(_fMeanSquare);
            return std::max(kQuietDb, static_cast<int>(std::lround(fdb)));
        }

    } // namespace

    void LevelLog::Push(
        const int16_t* _pSamples, std::size_t _nCount, std::vector<SecondLevel>& _Seconds)
    {
        for (std::size_t i = 0; i < _nCount; ++i)
        {
            const double fsample = _pSamples[i] / 32768.0;
            const double fsquare = fsample * fsample;
            m_fSecondSum += fsquare;
            m_fFrameSum += fsquare;
            if (++m_nInFrame == kFrameSamples)
            {
                m_fLoudest = std::max(m_fLoudest, m_fFrameSum / static_cast<double>(kFrameSamples));
                m_fFrameSum = 0.0;
                m_nInFrame = 0;
            }
            if (++m_nInSecond == static_cast<std::size_t>(kListenRate))
            {
                ++m_nSeconds;
                SecondLevel second;
                second.m_iRmsDb = Decibels(m_fSecondSum / static_cast<double>(kListenRate));
                second.m_iMaxDb = Decibels(m_fLoudest);
                second.m_iEndMs = static_cast<int64_t>(m_nSeconds) * 1000;
                _Seconds.push_back(second);
                m_fSecondSum = 0.0;
                m_fLoudest = 0.0;
                m_nInSecond = 0;
            }
        }
    }

    void LevelLog::Clear()
    {
        *this = LevelLog();
    }

    void Framer::Push(
        const int16_t* _pSamples, std::size_t _nCount, std::vector<std::string>& _Frames)
    {
        m_Pending.insert(m_Pending.end(), _pSamples, _pSamples + _nCount);
        std::size_t nused = 0;
        while (m_Pending.size() - nused >= kFrameSamples)
        {
            _Frames.push_back(ToBytes(m_Pending.data() + nused, kFrameSamples));
            nused += kFrameSamples;
        }
        m_Pending.erase(m_Pending.begin(), m_Pending.begin() + static_cast<std::ptrdiff_t>(nused));
    }

    std::size_t Framer::Pending() const
    {
        return m_Pending.size();
    }

    void Framer::Clear()
    {
        m_Pending.clear();
    }

    Resampler::Resampler(int _iFromRate, int _iToRate) : m_iFrom(_iFromRate), m_iTo(_iToRate)
    {
    }

    void Resampler::SetRates(int _iFromRate, int _iToRate)
    {
        m_iFrom = _iFromRate;
        m_iTo = _iToRate;
        Reset();
    }

    int Resampler::FromRate() const
    {
        return m_iFrom;
    }

    int Resampler::ToRate() const
    {
        return m_iTo;
    }

    void Resampler::Reset()
    {
        m_fPosition = 0.0;
        m_iLast = 0;
        m_bHaveLast = false;
    }

    void Resampler::Process(const int16_t* _pIn, std::size_t _nCount, std::vector<int16_t>& _Out)
    {
        if (_nCount == 0)
        {
            return;
        }
        if (m_iFrom == m_iTo || m_iFrom <= 0 || m_iTo <= 0)
        {
            _Out.insert(_Out.end(), _pIn, _pIn + _nCount);
            return;
        }
        if (!m_bHaveLast)
        {
            // The very first output sample is the first input sample.
            m_iLast = _pIn[0];
            m_bHaveLast = true;
            m_fPosition = 0.0;
            ++_pIn;
            --_nCount;
            _Out.push_back(m_iLast);
            m_fPosition += static_cast<double>(m_iFrom) / m_iTo;
        }
        // Index -1 is m_iLast, 0.._nCount-1 this chunk; positions are
        // relative to m_iLast.
        const double fstep = static_cast<double>(m_iFrom) / m_iTo;
        auto sample = [&](std::ptrdiff_t _iIndex) -> double
        {
            return _iIndex < 0 ? m_iLast : _pIn[_iIndex];
        };
        while (m_fPosition <= static_cast<double>(_nCount))
        {
            const auto ibase = static_cast<std::ptrdiff_t>(std::floor(m_fPosition)) - 1;
            const double ffraction = m_fPosition - std::floor(m_fPosition);
            double fvalue = sample(ibase);
            if (ffraction > 0.0)
            {
                fvalue += (sample(ibase + 1) - fvalue) * ffraction;
            }
            _Out.push_back(static_cast<int16_t>(std::lround(fvalue)));
            m_fPosition += fstep;
        }
        if (_nCount > 0)
        {
            m_iLast = _pIn[_nCount - 1];
            m_fPosition -= static_cast<double>(_nCount);
        }
    }

    // ---- WavWriter ----------------------------------------------------------

    namespace
    {

        void PutU32(unsigned char* _pOut, uint32_t _uValue)
        {
            for (int i = 0; i < 4; ++i)
            {
                _pOut[i] = static_cast<unsigned char>((_uValue >> (8 * i)) & 0xFF);
            }
        }

        void PutU16(unsigned char* _pOut, uint16_t _uValue)
        {
            _pOut[0] = static_cast<unsigned char>(_uValue & 0xFF);
            _pOut[1] = static_cast<unsigned char>(_uValue >> 8);
        }

        constexpr long kHeaderBytes = 44;

    } // namespace

    WavWriter::~WavWriter()
    {
        Close();
    }

    bool WavWriter::Open(const std::string& _Path, int _iSampleRate, std::string& _Error)
    {
        Close();
        namespace fs = std::filesystem;
        const fs::path path = fs::u8path(_Path);
        std::error_code ec;
        if (path.has_parent_path())
        {
            fs::create_directories(path.parent_path(), ec);
        }
#if defined(_WIN32)
        m_pFile = _wfopen(path.c_str(), L"w+b");
#else
        m_pFile = std::fopen(path.c_str(), "w+b");
#endif
        if (!m_pFile)
        {
            _Error = "could not create " + _Path;
            return false;
        }
        m_Path = _Path;
        m_nDataBytes = 0;
        m_iSampleRate = _iSampleRate;
        // RIFF, then a PCM fmt chunk (mono, 16-bit), then the data chunk;
        // the sizes are filled in as data comes.
        unsigned char header[kHeaderBytes] = {};
        std::copy_n("RIFF", 4, header);
        std::copy_n("WAVEfmt ", 8, header + 8);
        PutU32(header + 16, 16);
        PutU16(header + 20, 1); // PCM
        PutU16(header + 22, 1); // mono
        PutU32(header + 24, static_cast<uint32_t>(_iSampleRate));
        PutU32(header + 28, static_cast<uint32_t>(_iSampleRate) * 2);
        PutU16(header + 32, 2);
        PutU16(header + 34, 16);
        std::copy_n("data", 4, header + 36);
        std::fwrite(header, 1, sizeof header, m_pFile);
        WriteSizes();
        return true;
    }

    void WavWriter::Write(const std::string& _Bytes)
    {
        const std::size_t nbytes = _Bytes.size() & ~static_cast<std::size_t>(1);
        if (!m_pFile || nbytes == 0)
        {
            return;
        }
        std::fseek(m_pFile, 0, SEEK_END);
        m_nDataBytes += std::fwrite(_Bytes.data(), 1, nbytes, m_pFile);
        WriteSizes();
    }

    void WavWriter::WriteSizes()
    {
        unsigned char size[4];
        PutU32(size, static_cast<uint32_t>(m_nDataBytes + kHeaderBytes - 8));
        std::fseek(m_pFile, 4, SEEK_SET);
        std::fwrite(size, 1, 4, m_pFile);
        PutU32(size, static_cast<uint32_t>(m_nDataBytes));
        std::fseek(m_pFile, 40, SEEK_SET);
        std::fwrite(size, 1, 4, m_pFile);
        std::fflush(m_pFile);
    }

    void WavWriter::Close()
    {
        if (m_pFile)
        {
            WriteSizes();
            std::fclose(m_pFile);
            m_pFile = nullptr;
        }
    }

    bool WavWriter::IsOpen() const
    {
        return m_pFile != nullptr;
    }

    const std::string& WavWriter::Path() const
    {
        return m_Path;
    }

    std::size_t WavWriter::DataBytes() const
    {
        return m_nDataBytes;
    }

    int WavWriter::SampleRate() const
    {
        return m_iSampleRate;
    }

} // namespace gitgud::voice
