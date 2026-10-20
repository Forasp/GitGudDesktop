#pragma once

// -----------------------------------------------------------------------------
// Pcm: the audio formats of the voice protocol (voice/VoiceSession.h):
// signed 16-bit little-endian mono, 16 kHz up in 20 ms frames, any rate
// down. Plain data work, no devices, so it's all unit-tested.
// -----------------------------------------------------------------------------

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace gitgud::voice
{

    // The listen channel's format.
    constexpr int kListenRate = 16000;
    constexpr std::size_t kFrameSamples = kListenRate / 50; // 20 ms
    constexpr std::size_t kFrameBytes = kFrameSamples * 2;  // 640

    // Samples as little-endian bytes, and back (an odd last byte is dropped).
    std::string ToBytes(const int16_t* _pSamples, std::size_t _nCount);
    std::vector<int16_t> FromBytes(const std::string& _Bytes);

    // Float samples (-1 to 1, clipped) to 16-bit.
    int16_t ToPcm16(float _fSample);

    // How loud samples are, for a level meter: their RMS on a -60 to 0 dBFS
    // scale, as 0 to 1 (silence and anything under -60 dBFS is 0).
    double Level(const int16_t* _pSamples, std::size_t _nCount);

    // A second of the microphone, for voice-log.txt: how loud the whole
    // second was (RMS) and its loudest 20 ms frame, both in whole dBFS
    // (kQuietDb for silence and anything quieter), and when it ended, in
    // ms since the first sample (the voice protocol's `t`).
    constexpr int kQuietDb = -90;

    struct SecondLevel
    {
        int m_iRmsDb = kQuietDb;
        int m_iMaxDb = kQuietDb;
        int64_t m_iEndMs = 0;
    };

    // Measures a 16 kHz stream a second at a time: cheap (a sum per
    // sample), so it runs on the capture thread.
    class LevelLog
    {
      public:
        // Add samples; each completed second is appended to `_Seconds`.
        void Push(
            const int16_t* _pSamples, std::size_t _nCount, std::vector<SecondLevel>& _Seconds);
        void Clear();

      private:
        double m_fSecondSum = 0.0; // squares, this second
        double m_fFrameSum = 0.0;  // squares, this 20 ms frame
        double m_fLoudest = 0.0;   // the loudest frame's mean square, this second
        std::size_t m_nInFrame = 0;
        std::size_t m_nInSecond = 0;
        std::size_t m_nSeconds = 0;
    };

    // Cuts a stream of samples into whole 20 ms frames.
    class Framer
    {
      public:
        // Add samples; each complete frame (kFrameBytes, little-endian) is
        // appended to `_Frames`.
        void Push(const int16_t* _pSamples, std::size_t _nCount, std::vector<std::string>& _Frames);

        std::size_t Pending() const; // samples waiting for a full frame
        void Clear();

      private:
        std::vector<int16_t> m_Pending;
    };

    // Streaming linear resampler for mono 16-bit audio. Good enough for
    // speech; keeps its position across calls, so chunks join smoothly.
    class Resampler
    {
      public:
        Resampler(int _iFromRate = kListenRate, int _iToRate = kListenRate);

        // Change rates (a new utterance at another rate); resets the state.
        void SetRates(int _iFromRate, int _iToRate);
        int FromRate() const;
        int ToRate() const;

        // Convert the next chunk, appending to `_Out`.
        void Process(const int16_t* _pIn, std::size_t _nCount, std::vector<int16_t>& _Out);
        void Reset();

      private:
        int m_iFrom;
        int m_iTo;
        // Position of the next output sample, in input samples, measured
        // from the last sample of the previous chunk (m_iLast).
        double m_fPosition = 0.0;
        int16_t m_iLast = 0;
        bool m_bHaveLast = false;
    };

    // Writes mono 16-bit little-endian audio to a WAV file as it comes. The
    // header's sizes are filled in on Close (and after every write, so a
    // file cut short by a crash still plays up to its last write).
    class WavWriter
    {
      public:
        WavWriter() = default;
        ~WavWriter(); // Close()
        WavWriter(const WavWriter&) = delete;
        WavWriter& operator=(const WavWriter&) = delete;

        // Create `_Path` (UTF-8; its folder too), replacing a file there.
        // False with `_Error` if it can't.
        bool Open(const std::string& _Path, int _iSampleRate, std::string& _Error);
        // Append samples as bytes (an odd last byte is dropped).
        void Write(const std::string& _Bytes);
        void Close();

        bool IsOpen() const;
        const std::string& Path() const;
        std::size_t DataBytes() const;
        int SampleRate() const;

      private:
        void WriteSizes();

        std::FILE* m_pFile = nullptr;
        std::string m_Path;
        std::size_t m_nDataBytes = 0;
        int m_iSampleRate = kListenRate;
    };

} // namespace gitgud::voice
