// Tests for voice/Pcm: byte order, 20 ms framing, resampling, levels, and WAV
// files.

#include <catch2/catch_test_macros.hpp>

#include "voice/Pcm.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace gitgud::voice;

TEST_CASE("Pcm: samples are little-endian bytes and back", "[voice]")
{
    const std::vector<int16_t> samples = {0, 1, -1, 0x1234, -32768, 32767};
    const std::string bytes = ToBytes(samples.data(), samples.size());
    REQUIRE(bytes.size() == 12);
    CHECK(static_cast<unsigned char>(bytes[2]) == 0x01);
    CHECK(static_cast<unsigned char>(bytes[3]) == 0x00);
    CHECK(static_cast<unsigned char>(bytes[4]) == 0xFF);
    CHECK(static_cast<unsigned char>(bytes[5]) == 0xFF);
    CHECK(static_cast<unsigned char>(bytes[6]) == 0x34);
    CHECK(static_cast<unsigned char>(bytes[7]) == 0x12);
    CHECK(FromBytes(bytes) == samples);
    // An odd last byte is dropped.
    CHECK(FromBytes(bytes + "x").size() == samples.size());

    CHECK(ToPcm16(0.0f) == 0);
    CHECK(ToPcm16(1.0f) == 32767);
    CHECK(ToPcm16(-1.0f) == -32767);
    CHECK(ToPcm16(4.0f) == 32767);
    CHECK(ToPcm16(-4.0f) == -32767);
}

TEST_CASE("Pcm: the framer cuts 20 ms frames of 640 bytes", "[voice]")
{
    REQUIRE(kFrameSamples == 320);
    REQUIRE(kFrameBytes == 640);

    Framer framer;
    std::vector<int16_t> samples(1000);
    for (std::size_t i = 0; i < samples.size(); ++i)
    {
        samples[i] = static_cast<int16_t>(i);
    }
    std::vector<std::string> frames;
    framer.Push(samples.data(), 100, frames);
    CHECK(frames.empty());
    CHECK(framer.Pending() == 100);
    framer.Push(samples.data() + 100, 900, frames);
    REQUIRE(frames.size() == 3);
    CHECK(framer.Pending() == 40);
    for (const std::string& frame : frames)
    {
        CHECK(frame.size() == kFrameBytes);
    }
    // Samples stay in order across pushes and frames.
    const std::vector<int16_t> second = FromBytes(frames[1]);
    CHECK(second.front() == 320);
    CHECK(second.back() == 639);

    // Small pushes, as a capture device delivers them (10 ms each).
    framer.Clear();
    frames.clear();
    for (int i = 0; i < 10; ++i)
    {
        framer.Push(samples.data(), 160, frames);
    }
    CHECK(frames.size() == 5);
    CHECK(framer.Pending() == 0);
}

TEST_CASE("Pcm: the resampler converts rates and joins chunks", "[voice]")
{
    SECTION("the same rate passes samples through")
    {
        Resampler resampler(24000, 24000);
        const std::vector<int16_t> in = {1, 2, 3};
        std::vector<int16_t> out;
        resampler.Process(in.data(), in.size(), out);
        CHECK(out == in);
    }

    SECTION("16 kHz to 48 kHz triples the samples and keeps a constant")
    {
        Resampler resampler(16000, 48000);
        const std::vector<int16_t> in(1600, 1000);
        std::vector<int16_t> out;
        resampler.Process(in.data(), in.size(), out);
        CHECK(out.size() >= 4797);
        CHECK(out.size() <= 4800);
        for (const int16_t sample : out)
        {
            REQUIRE(sample == 1000);
        }
    }

    SECTION("chunks give the same result as one block")
    {
        std::vector<int16_t> in(2400);
        for (std::size_t i = 0; i < in.size(); ++i)
        {
            in[i] = static_cast<int16_t>((i * 37) % 2000 - 1000);
        }
        Resampler whole(16000, 24000);
        std::vector<int16_t> expected;
        whole.Process(in.data(), in.size(), expected);

        Resampler chunked(16000, 24000);
        std::vector<int16_t> out;
        std::size_t nat = 0;
        for (const std::size_t nsize : {1u, 7u, 320u, 500u, 1u, 1571u})
        {
            chunked.Process(in.data() + nat, nsize, out);
            nat += nsize;
        }
        REQUIRE(nat == in.size());
        CHECK(out == expected);
        CHECK(out.size() >= 3598);
        CHECK(out.size() <= 3600);
    }

    SECTION("downsampling a ramp stays a ramp")
    {
        Resampler resampler(24000, 16000);
        std::vector<int16_t> in(2400);
        for (std::size_t i = 0; i < in.size(); ++i)
        {
            in[i] = static_cast<int16_t>(i * 3);
        }
        std::vector<int16_t> out;
        resampler.Process(in.data(), in.size(), out);
        CHECK(out.size() >= 1599);
        CHECK(out.size() <= 1600);
        for (std::size_t i = 1; i < out.size(); ++i)
        {
            REQUIRE(out[i] > out[i - 1]);
            // Each output step is 1.5 input samples: 4.5 in value.
            REQUIRE(std::abs((out[i] - out[i - 1]) - 4.5) <= 1.0);
        }
    }

    SECTION("new rates reset the state")
    {
        Resampler resampler(16000, 48000);
        std::vector<int16_t> out;
        const std::vector<int16_t> in(160, 5);
        resampler.Process(in.data(), in.size(), out);
        resampler.SetRates(24000, 24000);
        CHECK(resampler.FromRate() == 24000);
        out.clear();
        resampler.Process(in.data(), in.size(), out);
        CHECK(out.size() == 160);
    }
}

TEST_CASE("Pcm: the level meter reads RMS from -60 to 0 dBFS", "[voice]")
{
    using gitgud::voice::Level;

    CHECK(Level(nullptr, 0) == 0.0);
    const std::vector<int16_t> silence(320, 0);
    CHECK(Level(silence.data(), silence.size()) == 0.0);

    // A full-scale square wave is 0 dBFS.
    std::vector<int16_t> loud(320);
    for (std::size_t i = 0; i < loud.size(); ++i)
    {
        loud[i] = (i % 2) ? int16_t(32767) : int16_t(-32768);
    }
    CHECK(Level(loud.data(), loud.size()) > 0.99);

    // -30 dBFS is halfway.
    const auto iquiet = static_cast<int16_t>(std::lround(32768.0 * std::pow(10.0, -30.0 / 20.0)));
    const std::vector<int16_t> quiet(320, iquiet);
    CHECK(std::abs(Level(quiet.data(), quiet.size()) - 0.5) < 0.01);

    // Under -60 dBFS reads as nothing.
    const std::vector<int16_t> hiss(320, 10);
    CHECK(Level(hiss.data(), hiss.size()) == 0.0);
}

TEST_CASE("Pcm: the level log measures each second in dBFS", "[voice]")
{
    using gitgud::voice::kQuietDb;
    using gitgud::voice::LevelLog;
    using gitgud::voice::SecondLevel;

    LevelLog levels;
    std::vector<SecondLevel> seconds;

    // Under a second: nothing yet.
    const std::vector<int16_t> silence(8000, 0);
    levels.Push(silence.data(), silence.size(), seconds);
    CHECK(seconds.empty());

    // The rest of a silent second, in uneven pieces.
    levels.Push(silence.data(), 3000, seconds);
    levels.Push(silence.data(), 5000, seconds);
    REQUIRE(seconds.size() == 1);
    CHECK(seconds[0].m_iRmsDb == kQuietDb);
    CHECK(seconds[0].m_iMaxDb == kQuietDb);
    CHECK(seconds[0].m_iEndMs == 1000);

    // A second that's quiet but for one loud 20 ms frame: the RMS stays
    // low, the loudest frame shows the voice.
    const auto iloud = static_cast<int16_t>(std::lround(32768.0 * std::pow(10.0, -20.0 / 20.0)));
    std::vector<int16_t> second(16000, 0);
    for (std::size_t i = 640; i < 960; ++i)
    {
        second[i] = (i % 2) ? iloud : static_cast<int16_t>(-iloud);
    }
    seconds.clear();
    levels.Push(second.data(), second.size(), seconds);
    REQUIRE(seconds.size() == 1);
    CHECK(seconds[0].m_iMaxDb == -20);
    CHECK(seconds[0].m_iRmsDb == -37); // -20 dB over 1/50 of the second
    CHECK(seconds[0].m_iEndMs == 2000);

    // Two seconds at once, steady at -30 dBFS.
    const auto iquiet = static_cast<int16_t>(std::lround(32768.0 * std::pow(10.0, -30.0 / 20.0)));
    const std::vector<int16_t> steady(32000, iquiet);
    seconds.clear();
    levels.Push(steady.data(), steady.size(), seconds);
    REQUIRE(seconds.size() == 2);
    CHECK(seconds[0].m_iRmsDb == -30);
    CHECK(seconds[0].m_iMaxDb == -30);
    CHECK(seconds[1].m_iEndMs == 4000);

    // Clear starts the count again.
    levels.Clear();
    seconds.clear();
    levels.Push(steady.data(), 16000, seconds);
    REQUIRE(seconds.size() == 1);
    CHECK(seconds[0].m_iEndMs == 1000);
}

TEST_CASE("Pcm: WavWriter writes a 16-bit mono WAV file", "[voice]")
{
    namespace fs = std::filesystem;
    const fs::path folder = fs::temp_directory_path() / "gitgud-wav-test";
    fs::remove_all(folder);
    const fs::path file = folder / "sub" / "a.wav";
    const auto readAll = [&]()
    {
        std::ifstream in(file, std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    };
    const auto u32 = [](const std::string& _Bytes, std::size_t _nAt)
    {
        uint32_t uvalue = 0;
        for (int i = 3; i >= 0; --i)
        {
            uvalue = (uvalue << 8) | static_cast<unsigned char>(_Bytes[_nAt + static_cast<std::size_t>(i)]);
        }
        return uvalue;
    };

    const std::vector<int16_t> samples = {1, -2, 300, -32768, 32767};
    const std::string bytes = ToBytes(samples.data(), samples.size());
    {
        WavWriter wav;
        std::string error;
        REQUIRE(wav.Open(file.u8string(), kListenRate, error)); // its folder is made
        CHECK(wav.IsOpen());
        wav.Write(bytes);
        // Sizes are right after each write, before Close.
        const std::string partial = readAll();
        REQUIRE(partial.size() == 44 + bytes.size());
        CHECK(u32(partial, 40) == bytes.size());
        wav.Write(bytes + "x"); // the odd byte is dropped
        CHECK(wav.DataBytes() == 2 * bytes.size());
    } // closed

    const std::string all = readAll();
    REQUIRE(all.size() == 44 + 2 * bytes.size());
    CHECK(all.substr(0, 4) == "RIFF");
    CHECK(u32(all, 4) == all.size() - 8);
    CHECK(all.substr(8, 8) == "WAVEfmt ");
    CHECK(u32(all, 16) == 16);
    CHECK((u32(all, 20) & 0xFFFF) == 1); // PCM
    CHECK((u32(all, 20) >> 16) == 1);    // mono
    CHECK(u32(all, 24) == 16000);
    CHECK(u32(all, 28) == 32000);
    CHECK((u32(all, 32) & 0xFFFF) == 2);
    CHECK((u32(all, 32) >> 16) == 16);
    CHECK(all.substr(36, 4) == "data");
    CHECK(u32(all, 40) == 2 * bytes.size());
    CHECK(FromBytes(all.substr(44)) == std::vector<int16_t>{1, -2, 300, -32768, 32767, 1, -2, 300, -32768, 32767});

    WavWriter bad;
    std::string error;
    CHECK_FALSE(bad.Open((folder / "sub").u8string(), kListenRate, error)); // a folder
    CHECK_FALSE(error.empty());
    fs::remove_all(folder);
}
