// Hidden ([.echo-measure]): how much of what Bragi plays the microphone
// hears, on the real devices. Plays a recording through the speaker voice
// uses while recording the microphone twice at once: plain capture (all of
// the echo) and the echo-cancelled capture voice listens with (what's left).
// Writes played.wav, raw.wav, cancelled.wav and marks.json to
// GITGUD_TEST_ECHO_OUT for measuring; nothing is checked here.
//
//   GITGUD_TEST_ECHO_OUT     the folder to write to (required)
//   GITGUD_TEST_ECHO_WAV     what to play: 16-bit mono WAV (required)
//   GITGUD_TEST_ECHO_MIC     part of a microphone's name (default: the default one)
//   GITGUD_TEST_ECHO_LENGTH  the canceller's echo length in ms (128/256/512/1024)
//   GITGUD_TEST_ECHO_CLIP    1: center clipping on
//   GITGUD_TEST_ECHO_NS      0: noise suppression off
//   GITGUD_TEST_ECHO_DELAY   the speaker's delay in ms: the lined-up canceller
//   GITGUD_TEST_ECHO_AES     residual echo suppression passes (0 to 2)
//
// Plays out loud: keep the room quiet while it runs (about 10 s plus the
// recording).

#include <catch2/catch_test_macros.hpp>

#include "platform/Audio.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
using namespace std::chrono_literals;
using namespace gitgud::platform;

namespace
{

    // A 16-bit mono WAV's samples and rate (empty when it isn't one).
    std::vector<int16_t> ReadWav(const fs::path& _Path, int& _iRate)
    {
        std::ifstream in(_Path, std::ios::binary);
        std::vector<char> bytes(
            (std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        std::vector<int16_t> samples;
        if (bytes.size() < 44 || std::memcmp(bytes.data(), "RIFF", 4) != 0)
        {
            return samples;
        }
        std::size_t npos = 12;
        int ichannels = 0;
        int ibits = 0;
        while (npos + 8 <= bytes.size())
        {
            uint32_t usize = 0;
            std::memcpy(&usize, bytes.data() + npos + 4, 4);
            const std::string id(bytes.data() + npos, 4);
            const std::size_t nbody = npos + 8;
            if (id == "fmt ")
            {
                uint16_t uchannels = 0;
                uint32_t urate = 0;
                uint16_t ubits = 0;
                std::memcpy(&uchannels, bytes.data() + nbody + 2, 2);
                std::memcpy(&urate, bytes.data() + nbody + 4, 4);
                std::memcpy(&ubits, bytes.data() + nbody + 14, 2);
                ichannels = uchannels;
                _iRate = static_cast<int>(urate);
                ibits = ubits;
            }
            else if (id == "data" && ichannels == 1 && ibits == 16)
            {
                const std::size_t ncount = std::min<std::size_t>(usize, bytes.size() - nbody) / 2;
                samples.resize(ncount);
                std::memcpy(samples.data(), bytes.data() + nbody, ncount * 2);
                return samples;
            }
            npos = nbody + usize + (usize & 1);
        }
        return samples;
    }

    void WriteWav(const fs::path& _Path, const std::vector<int16_t>& _Samples, int _iRate)
    {
        std::ofstream out(_Path, std::ios::binary | std::ios::trunc);
        const uint32_t udata = static_cast<uint32_t>(_Samples.size() * 2);
        auto u32 = [&](uint32_t _uValue)
        {
            out.write(reinterpret_cast<const char*>(&_uValue), 4);
        };
        auto u16 = [&](uint16_t _uValue)
        {
            out.write(reinterpret_cast<const char*>(&_uValue), 2);
        };
        out.write("RIFF", 4);
        u32(36 + udata);
        out.write("WAVEfmt ", 8);
        u32(16);
        u16(1);
        u16(1);
        u32(static_cast<uint32_t>(_iRate));
        u32(static_cast<uint32_t>(_iRate * 2));
        u16(2);
        u16(16);
        out.write("data", 4);
        u32(udata);
        out.write(reinterpret_cast<const char*>(_Samples.data()), udata);
    }

    // Samples a capture gave, kept in order.
    struct Recorded
    {
        std::mutex m_Mutex;
        std::vector<int16_t> m_Samples;

        IAudioCapture::OnSamples Sink()
        {
            return [this](const int16_t* _pSamples, std::size_t _nCount)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Samples.insert(m_Samples.end(), _pSamples, _pSamples + _nCount);
            };
        }

        std::size_t Count()
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            return m_Samples.size();
        }
    };

    std::string Env(const char* _szName)
    {
        const char* szvalue = std::getenv(_szName);
        return szvalue ? szvalue : "";
    }

} // namespace

TEST_CASE("Echo: what the microphone hears of what plays", "[.echo-measure]")
{
    const std::string outDir = Env("GITGUD_TEST_ECHO_OUT");
    const std::string wav = Env("GITGUD_TEST_ECHO_WAV");
    if (outDir.empty() || wav.empty())
    {
        SKIP("set GITGUD_TEST_ECHO_OUT and GITGUD_TEST_ECHO_WAV");
    }
    int irate = 0;
    const std::vector<int16_t> played = ReadWav(fs::u8path(wav), irate);
    REQUIRE_FALSE(played.empty());
    fs::create_directories(fs::u8path(outDir));

    std::string micName = "default";
    if (const std::string want = Env("GITGUD_TEST_ECHO_MIC"); !want.empty())
    {
        for (const AudioDevice& device : ListAudioDevices(true))
        {
            if (device.m_Name.find(want) != std::string::npos)
            {
                SetAudioDevices(device.m_Id, "");
                micName = device.m_Name;
                break;
            }
        }
        REQUIRE(micName != "default");
    }
    EchoOptions options;
    if (const std::string length = Env("GITGUD_TEST_ECHO_LENGTH"); !length.empty())
    {
        options.m_iEchoLengthMs = std::atoi(length.c_str());
    }
    options.m_bCenterClip = Env("GITGUD_TEST_ECHO_CLIP") == "1";
    options.m_bNoiseSuppression = Env("GITGUD_TEST_ECHO_NS") != "0";
    // A delay: voice lines the speaker up itself (EchoOptions).
    options.m_iDelayMs = std::atoi(Env("GITGUD_TEST_ECHO_DELAY").c_str());
    options.m_iSuppression = std::atoi(Env("GITGUD_TEST_ECHO_AES").c_str());
    SetEchoOptions(options);

    Recorded raw;
    Recorded cancelled;
    std::unique_ptr<IAudioCapture> pcancelled = MakeVoiceCapture();
    std::unique_ptr<IAudioCapture> praw = MakePlainCapture();
    std::unique_ptr<IAudioPlayback> pplayback = MakePlayback();
    std::string error;
    REQUIRE(pcancelled->Start(16000, cancelled.Sink(), error));
    REQUIRE(praw->Start(16000, raw.Sink(), error));
    REQUIRE(pplayback->Start(irate, error));

    // The quiet room first (and the canceller settling), then the recording,
    // then its tail.
    std::this_thread::sleep_for(3s);
    const std::size_t nrawAt = raw.Count();
    const std::size_t ncancelledAt = cancelled.Count();
    pplayback->Enqueue(played.data(), played.size());
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(played.size() * 1000 / irate + 5000);
    while (pplayback->Queued() > 0 && std::chrono::steady_clock::now() < deadline)
    {
        std::this_thread::sleep_for(50ms);
    }
    std::this_thread::sleep_for(2s);
    const std::string route = pcancelled->Route();
    const std::string description = pcancelled->Description();
    const std::string speaker = pplayback->Description();
    pplayback->Stop();
    praw->Stop();
    pcancelled->Stop();
    SetAudioDevices("", "");
    SetEchoOptions(EchoOptions{});

    const fs::path out = fs::u8path(outDir);
    WriteWav(out / "played.wav", played, irate);
    {
        std::lock_guard<std::mutex> lock(raw.m_Mutex);
        WriteWav(out / "raw.wav", raw.m_Samples, 16000);
    }
    {
        std::lock_guard<std::mutex> lock(cancelled.m_Mutex);
        WriteWav(out / "cancelled.wav", cancelled.m_Samples, 16000);
    }
    std::ofstream marks(out / "marks.json", std::ios::binary | std::ios::trunc);
    auto quoted = [](std::string _Text)
    {
        std::string s = "\"";
        for (const char c : _Text)
        {
            if (c == '"' || c == '\\')
            {
                s += '\\';
            }
            s += c;
        }
        return s + "\"";
    };
    marks << "{\"rawStart\": " << nrawAt << ", \"cancelledStart\": " << ncancelledAt
          << ", \"playedRate\": " << irate << ", \"echoLengthMs\": " << options.m_iEchoLengthMs
          << ", \"centerClip\": " << (options.m_bCenterClip ? "true" : "false")
          << ", \"suppression\": " << options.m_iSuppression
          << ", \"noiseSuppression\": " << (options.m_bNoiseSuppression ? "true" : "false")
          << ", \"mic\": " << quoted(micName) << ", \"speaker\": " << quoted(speaker)
          << ", \"capture\": " << quoted(description) << ", \"route\": " << quoted(route) << "}\n";
    SUCCEED(route);
}

// Hidden ([.echo-offline]): the echo canceller in filter mode on files: a
// microphone recording and what played, already lined up sample for sample
// (16 kHz mono), into the cancelled microphone.
//
//   GITGUD_TEST_ECHO_MIC_WAV  the microphone
//   GITGUD_TEST_ECHO_REF_WAV  what played, lined up with it
//   GITGUD_TEST_ECHO_OUT_WAV  where the cancelled microphone goes
//   GITGUD_TEST_ECHO_LENGTH / _CLIP / _NS as for [.echo-measure]
TEST_CASE("Echo: the canceller on recordings", "[.echo-offline]")
{
    const std::string micWav = Env("GITGUD_TEST_ECHO_MIC_WAV");
    const std::string refWav = Env("GITGUD_TEST_ECHO_REF_WAV");
    const std::string outWav = Env("GITGUD_TEST_ECHO_OUT_WAV");
    if (micWav.empty() || refWav.empty() || outWav.empty())
    {
        SKIP("set GITGUD_TEST_ECHO_MIC_WAV, GITGUD_TEST_ECHO_REF_WAV and GITGUD_TEST_ECHO_OUT_WAV");
    }
    int imicRate = 0;
    int irefRate = 0;
    const std::vector<int16_t> mic = ReadWav(fs::u8path(micWav), imicRate);
    const std::vector<int16_t> reference = ReadWav(fs::u8path(refWav), irefRate);
    REQUIRE(imicRate == 16000);
    REQUIRE(irefRate == 16000);
    EchoOptions options;
    if (const std::string length = Env("GITGUD_TEST_ECHO_LENGTH"); !length.empty())
    {
        options.m_iEchoLengthMs = std::atoi(length.c_str());
    }
    options.m_bCenterClip = Env("GITGUD_TEST_ECHO_CLIP") == "1";
    options.m_bNoiseSuppression = Env("GITGUD_TEST_ECHO_NS") != "0";
    std::vector<int16_t> out;
    std::string error;
    INFO(error);
    REQUIRE(CancelEcho(mic, reference, options, out, error));
    CHECK(out.size() + 320 >= std::min(mic.size(), reference.size()));
    WriteWav(fs::u8path(outWav), out, 16000);
}

// Hidden ([.echo-test]): the echo test Settings runs (MeasureEcho): chirps on
// the speaker voice uses, and how late the microphone hears them. Plays out
// loud. Prints what it found.
TEST_CASE("Echo: the chirp test measures the speaker's delay", "[.echo-test]")
{
    if (Env("GITGUD_TEST_ECHO_LIVE") != "1")
    {
        SKIP("set GITGUD_TEST_ECHO_LIVE=1 (it plays out loud)");
    }
    if (const std::string want = Env("GITGUD_TEST_ECHO_MIC"); !want.empty())
    {
        for (const AudioDevice& device : ListAudioDevices(true))
        {
            if (device.m_Name.find(want) != std::string::npos)
            {
                SetAudioDevices(device.m_Id, "");
            }
        }
    }
    // GITGUD_TEST_ECHO_WAV: something to play instead of the chirps
    // (16-bit mono, resampled to 16 kHz).
    std::vector<int16_t> signal;
    if (const std::string wav = Env("GITGUD_TEST_ECHO_WAV"); !wav.empty())
    {
        int irate = 0;
        const std::vector<int16_t> samples = ReadWav(fs::u8path(wav), irate);
        REQUIRE(irate > 0);
        for (std::size_t ni = 0; ni * irate / 16000 < samples.size(); ++ni)
        {
            signal.push_back(samples[ni * irate / 16000]);
        }
    }
    const EchoMeasurement result = MeasureEcho(signal);
    SetAudioDevices("", "");
    INFO(result.m_Error);
    REQUIRE(result.m_bOk);
    std::printf("[echo-test] delay %.1f ms, correlation %.3f, echo %.1f dBFS, floor %.1f dBFS, "
                "heard %s; %s\n",
        result.m_fDelayMs, result.m_fCorrelation, result.m_fEchoDb, result.m_fFloorDb,
        result.m_bHeard ? "yes" : "no", result.m_Route.c_str());
    CHECK(result.m_bHeard);
}
