// Tests for the pure parts of platform/Audio: which endpoint voice opens and
// the echo canceller's device indexes, from made-up device lists. No device
// is opened.

#include <catch2/catch_test_macros.hpp>

#include "platform/Audio.h"

#include <cstdint>
#include <string>
#include <vector>

using gitgud::platform::EchoDeviceIndexes;
using gitgud::platform::PickAudioEndpoint;

namespace
{

    // Endpoint ids shaped like the system's.
    const std::string kWebcam = "{0.0.1.00000000}.{webcam}";
    const std::string kHeadsetMic = "{0.0.1.00000000}.{headset-mic}";
    const std::string kSpeakers = "{0.0.0.00000000}.{speakers}";
    const std::string kHeadset = "{0.0.0.00000000}.{headset}";
    const std::string kMonitor = "{0.0.0.00000000}.{monitor}";

} // namespace

TEST_CASE("PickAudioEndpoint: the chosen one while it's plugged in, else the default", "[audio]")
{
    const std::vector<std::string> active = {kHeadset, kSpeakers, kMonitor};

    // Nothing chosen: the default (the console default, where other apps play).
    CHECK(PickAudioEndpoint("", kSpeakers, active) == kSpeakers);
    // Chosen and plugged in.
    CHECK(PickAudioEndpoint(kMonitor, kSpeakers, active) == kMonitor);
    // Chosen but unplugged: the default.
    CHECK(PickAudioEndpoint("{0.0.0.00000000}.{gone}", kSpeakers, active) == kSpeakers);
    // A default that isn't active (or no default): nothing.
    CHECK(PickAudioEndpoint("", "{0.0.0.00000000}.{gone}", active).empty());
    CHECK(PickAudioEndpoint("", "", active).empty());
    CHECK(PickAudioEndpoint(kMonitor, kSpeakers, {}).empty());
}

TEST_CASE("EchoDeviceIndexes: the speaker high, the mic low, found by id", "[audio]")
{
    const std::vector<std::string> mics = {kHeadsetMic, kWebcam};
    const std::vector<std::string> speakers = {kHeadset, kSpeakers, kMonitor};
    int32_t ipacked = 0;

    // The webcam (index 1) with the speakers (index 1).
    REQUIRE(EchoDeviceIndexes(kWebcam, mics, kSpeakers, speakers, ipacked));
    CHECK(ipacked == 0x00010001);

    // The first of each: zero, not the DSP's "-1 = default".
    REQUIRE(EchoDeviceIndexes(kHeadsetMic, mics, kHeadset, speakers, ipacked));
    CHECK(ipacked == 0);

    // The speaker is the third: only the high half changes.
    REQUIRE(EchoDeviceIndexes(kHeadsetMic, mics, kMonitor, speakers, ipacked));
    CHECK(ipacked == 0x00020000);
    CHECK((ipacked & 0xFFFF) == 0);
    CHECK(((static_cast<uint32_t>(ipacked) >> 16) & 0xFFFFu) == 2);

    // Either missing: false, and the value is left alone.
    ipacked = 1234;
    CHECK_FALSE(EchoDeviceIndexes("{0.0.1.00000000}.{gone}", mics, kSpeakers, speakers, ipacked));
    CHECK_FALSE(EchoDeviceIndexes(kWebcam, mics, "", speakers, ipacked));
    CHECK_FALSE(EchoDeviceIndexes(kWebcam, {}, kSpeakers, speakers, ipacked));
    CHECK(ipacked == 1234);
}

TEST_CASE("Audio endpoints: playback and the echo reference are the same speaker", "[audio]")
{
    // The reported case: the speakers are the system default; the communications
    // default is a headset. Nothing chosen in Settings.
    const std::vector<std::string> mics = {kHeadsetMic, kWebcam};
    const std::vector<std::string> speakers = {kHeadset, kSpeakers};
    const std::string mic = PickAudioEndpoint("", kWebcam, mics);
    const std::string speaker = PickAudioEndpoint("", kSpeakers, speakers);
    CHECK(mic == kWebcam);
    CHECK(speaker == kSpeakers);
    int32_t ipacked = 0;
    REQUIRE(EchoDeviceIndexes(mic, mics, speaker, speakers, ipacked));
    // The canceller listens to the speakers (index 1), not the headset.
    CHECK(((static_cast<uint32_t>(ipacked) >> 16) & 0xFFFFu) == 1);
    CHECK((ipacked & 0xFFFF) == 1);
}

TEST_CASE("Audio endpoints: a chosen webcam unplugged", "[audio]")
{
    // A machine with the webcam chosen in Settings but unplugged, so
    // only the built-in array is active; two outputs, the second (a USB
    // S/PDIF interface) the default. Unplugged and disabled endpoints aren't
    // in the active lists, so they shift no index.
    const std::string array = "{0.0.1.00000000}.{mic-array}";
    const std::string builtInSpeakers = "{0.0.0.00000000}.{built-in-speakers}";
    const std::string spdif = "{0.0.0.00000000}.{spdif}";
    const std::vector<std::string> mics = {array};
    const std::vector<std::string> speakers = {builtInSpeakers, spdif};

    const std::string mic = PickAudioEndpoint(kWebcam, array, mics);
    const std::string speaker = PickAudioEndpoint("", spdif, speakers);
    CHECK(mic == array);
    CHECK(speaker == spdif);
    int32_t ipacked = 0;
    REQUIRE(EchoDeviceIndexes(mic, mics, speaker, speakers, ipacked));
    CHECK(ipacked == 0x00010000); // speaker 1, mic 0

    // The unplugged webcam itself can't be pointed at.
    CHECK_FALSE(EchoDeviceIndexes(kWebcam, mics, speaker, speakers, ipacked));
}

TEST_CASE("EchoTimeline: samples dated by their packets, kept until trimmed", "[audio]")
{
    using gitgud::platform::EchoTimeline;
    EchoTimeline line(16000);
    std::vector<int16_t> packet(160);
    for (std::size_t ni = 0; ni < packet.size(); ++ni)
    {
        packet[ni] = static_cast<int16_t>(ni);
    }
    CHECK_FALSE(line.Stamped());
    // 10 ms packets at 1 s, 1.01 s, then one without a time, then one a
    // little late (the device's clock runs slow).
    line.Push(packet.data(), packet.size(), 10000000);
    line.Push(packet.data(), packet.size(), 10100000);
    line.Push(packet.data(), packet.size(), -1);
    line.Push(packet.data(), packet.size(), 10300100);
    CHECK(line.Stamped());
    CHECK(line.Begin() == 0);
    CHECK(line.End() == 640);
    CHECK(line.TimeOf(0) == 10000000);
    CHECK(line.TimeOf(80) == 10050000);  // 5 ms in
    CHECK(line.TimeOf(400) == 10250000); // the untimed packet follows the one before
    CHECK(line.TimeOf(480) == 10300100); // the late one keeps its own time
    CHECK(line.IndexAt(10050000) == 80);
    CHECK(line.IndexAt(10300100) == 480);
    CHECK(line.IndexAt(9990000) == -16); // before the first: from it, backwards

    std::vector<int16_t> out;
    line.Copy(150, 20, out);
    REQUIRE(out.size() == 20);
    CHECK(out[0] == 150);
    CHECK(out[10] == 0); // the next packet starts again at 0
    line.Copy(630, 20, out);
    CHECK(out[9] == 159);
    CHECK(out[10] == 0); // not come yet

    line.TrimBefore(200);
    CHECK(line.Begin() == 200);
    CHECK(line.TimeOf(200) == 10125000); // still dated by the packet it's in
    line.Copy(150, 60, out);
    CHECK(out[0] == 0); // gone
    CHECK(out[50] == 40);
}

TEST_CASE("EchoLag: how far the microphone trails what played", "[audio]")
{
    using gitgud::platform::EchoLag;
    using gitgud::platform::EchoTestSignal;
    const std::vector<int16_t> played = EchoTestSignal(16000);
    REQUIRE(played.size() == 48000);
    // A quiet room, then the chirps 247.5 ms late at a third of the level.
    std::vector<int16_t> mic(played.size() + 16000, 0);
    uint32_t useed = 12345;
    for (int16_t& sample : mic)
    {
        useed = useed * 1103515245u + 12345u;
        sample = static_cast<int16_t>(static_cast<int>((useed >> 16) % 61) - 30);
    }
    const std::size_t nlag = 3960;
    for (std::size_t ni = 0; ni < played.size(); ++ni)
    {
        mic[ni + nlag] = static_cast<int16_t>(mic[ni + nlag] + played[ni] / 3);
    }
    double fcorrelation = 0;
    CHECK(EchoLag(played, mic, 16000, &fcorrelation) == static_cast<int>(nlag));
    CHECK(fcorrelation > 0.9);
    // Nothing heard: no clear match.
    std::vector<int16_t> silent(mic.size(), 0);
    EchoLag(played, silent, 16000, &fcorrelation);
    CHECK(fcorrelation == 0);
}
