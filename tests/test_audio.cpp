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
