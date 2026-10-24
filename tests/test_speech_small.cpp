// The small built-in voice (src/speech/SmallVoice, SpeechText's Roughen,
// app/SortedTable for the pronunciation dictionaries) and its path through the
// speak channel. The real model is the one the app ships
// (resources/uis/bragi/voices/bragi-1, copied beside the binaries), run on the
// app's own ONNX Runtime (voice/ beside the binaries); those tests skip when
// either isn't there.

#include <catch2/catch_test_macros.hpp>

#include "app/Json.h"
#include "app/SortedTable.h"
#include "platform/Shell.h"
#include "speech/LocalEngine.h"
#include "speech/SmallVoice.h"
#include "speech/SpeechText.h"

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <filesystem>
#include <map>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

using namespace gitgud::speech;
using gitgud::app::Json;
using gitgud::app::SortedTable;
namespace fs = std::filesystem;
using namespace std::chrono_literals;

namespace
{

    fs::path BinDir()
    {
        return fs::u8path(gitgud::platform::ExecutableDirectory());
    }

    fs::path VoicesDir()
    {
        return BinDir() / "resources" / "uis" / "bragi" / "voices";
    }

    bool VoiceThere()
    {
        std::error_code ec;
        return fs::is_regular_file(VoicesDir() / "bragi-1" / "model.onnx", ec) &&
               fs::is_regular_file(BinDir() / "voice" / "onnxruntime.dll", ec);
    }

    fs::path TempDir(const char* _szName)
    {
        const fs::path dir =
            fs::temp_directory_path() /
            ("gitgud_small_" + std::string(_szName) + "_" + std::to_string(std::random_device()()));
        fs::create_directories(dir);
        return dir;
    }

    // An engine on the app's own libraries, with small voices set up.
    std::unique_ptr<LocalEngine> SmallEngine(const fs::path& _State, bool _bSmall = true)
    {
        auto pengine =
            std::make_unique<LocalEngine>((BinDir() / "voice").u8string(), _State.u8string());
        Json settings = Json::Object();
        settings.Set("vadModel", (_State / "vad.onnx").u8string())
            .Set("asrDir", (_State / "asr").u8string())
            .Set("kwsDir", (_State / "kws").u8string())
            .Set("workDir", (_State / "work").u8string());
        if (_bSmall)
        {
            settings.Set(
                "small", Json::Object().Set("voicesDir", VoicesDir().u8string()).Set("threads", 1));
        }
        std::string error;
        REQUIRE(pengine->Configure(settings, error));
        return pengine;
    }

    // misaki's phonemes for "Hello, I'm Bragi." (stress marks and all).
    const char* const kHello = "həlˈO, ˌIm bɹˈɑɡi.";

} // namespace

TEST_CASE("A sorted table finds keys by binary search and refuses bad files", "[speech][small]")
{
    SortedTable table;
    std::string error;
    REQUIRE(table.LoadText("apple\tˈæpəl\nbanana\tbənˈænə\r\nzebra\tzˈibɹə", error));
    CHECK(table.Size() == 3);
    CHECK(table.Find("apple").value_or("") == "ˈæpəl");
    CHECK(table.Find("banana").value_or("") == "bənˈænə"); // \r dropped
    CHECK(table.Find("zebra").value_or("") == "zˈibɹə");
    CHECK_FALSE(table.Find("cherry"));
    CHECK_FALSE(table.Find(""));
    CHECK_FALSE(table.LoadText("b\t1\na\t2\n", error));
    CHECK(error.find("out of order") != std::string::npos);
    CHECK_FALSE(table.LoadText("a 1\n", error));
    CHECK(error.find("no tab") != std::string::npos);
    // Byte order: capitals and apostrophes sort before lowercase.
    REQUIRE(table.LoadText("'cause\tkˈʌz\nCat\tkˈæt\ncat\tkˈæt\n", error));
    CHECK(table.Find("Cat").has_value());
}

TEST_CASE("Phonemes become the model's input ids, unknown symbols dropped", "[speech][small]")
{
    std::map<std::string, int64_t> table;
    std::string error;
    REQUIRE(ParsePhonemeTable("a\t43\nˈ\t156\nɹ\t123\n \t16\n", table, error));
    CHECK(PhonemeIds("ˈaɹ a", table) == std::vector<int64_t>{0, 156, 43, 123, 16, 43, 0});
    CHECK(PhonemeIds("a?a", table) == std::vector<int64_t>{0, 43, 43, 0});
    CHECK(PhonemeIds("", table) == std::vector<int64_t>{0, 0});
    CHECK_FALSE(ParsePhonemeTable("a43\n", table, error));
    CHECK_FALSE(ParsePhonemeTable("\n", table, error));
}

TEST_CASE("Roughness flutters the loudness, the same each time for a seed", "[speech][small]")
{
    std::vector<float> tone(24000);
    for (std::size_t ni = 0; ni < tone.size(); ++ni)
    {
        tone[ni] =
            0.5f * static_cast<float>(std::sin(2.0 * 3.14159265358979 * 150.0 * ni / 24000.0));
    }
    std::vector<float> same = tone;
    Roughen(same, 24000, 0.0, 30.0, 80.0, 1);
    CHECK(same == tone); // no roughness: untouched

    std::vector<float> a = tone;
    std::vector<float> b = tone;
    Roughen(a, 24000, 0.15, 34.0, 91.0, 7);
    Roughen(b, 24000, 0.15, 34.0, 91.0, 7);
    CHECK(a == b);
    CHECK(a != tone);
    double fin = 0.0, fout = 0.0;
    for (std::size_t ni = 0; ni < tone.size(); ++ni)
    {
        fin += tone[ni] * tone[ni];
        fout += a[ni] * a[ni];
    }
    CHECK(std::fabs(std::sqrt(fout / fin) - 1.0) < 0.05); // about as loud overall
}

TEST_CASE("The built-in voice says phonemes on the processor", "[speech][small]")
{
    if (!VoiceThere())
    {
        SKIP("no voice model or ONNX Runtime beside the tests");
    }
    const fs::path state = TempDir("say");
    std::unique_ptr<LocalEngine> pengine = SmallEngine(state);
    REQUIRE(pengine->SmallConfigured());

    std::mutex mutex;
    std::condition_variable done;
    bool bdone = false;
    bool bok = false;
    std::vector<float> audio;
    std::vector<float> fast;
    std::string error;
    pengine->PostSpeak(
        [&]()
        {
            bool b = pengine->SmallSay(kHello, "bragi-1", 1.0, 0.045, audio, error);
            b = b && pengine->SmallSay(kHello, "bragi-1", 1.3, 0.045, fast, error);
            std::lock_guard<std::mutex> lock(mutex);
            bok = b;
            bdone = true;
            done.notify_all();
        });
    std::unique_lock<std::mutex> lock(mutex);
    REQUIRE(done.wait_for(lock, 60s, [&]() { return bdone; }));
    INFO(error);
    REQUIRE(bok);
    const double fseconds = static_cast<double>(audio.size()) / kSmallVoiceRate;
    CHECK(fseconds > 0.8);
    CHECK(fseconds < 3.0);
    CHECK(fast.size() < audio.size()); // the speed input makes it faster
    float fpeak = 0.0f;
    for (float f : audio)
    {
        fpeak = std::max(fpeak, std::fabs(f));
    }
    CHECK(fpeak > 0.05f); // not silence
    CHECK(fpeak < 1.5f);

    // A voice that isn't there says so, and isn't tried again.
    std::vector<float> none;
    std::string missing;
    bdone = false;
    lock.unlock();
    pengine->PostSpeak(
        [&]()
        {
            const bool b = pengine->SmallSay(kHello, "no-such-voice", 1.0, 0.0, none, missing);
            std::lock_guard<std::mutex> l(mutex);
            bok = b;
            bdone = true;
            done.notify_all();
        });
    lock.lock();
    REQUIRE(done.wait_for(lock, 30s, [&]() { return bdone; }));
    CHECK_FALSE(bok);
    CHECK(missing.find("phonemes.tsv") != std::string::npos);
}

TEST_CASE("The speak channel plays a small voice at the rate it's asked for", "[speech][small]")
{
    if (!VoiceThere())
    {
        SKIP("no voice model or ONNX Runtime beside the tests");
    }
    const fs::path state = TempDir("link");
    std::unique_ptr<LocalEngine> pengine = SmallEngine(state);
    std::unique_ptr<gitgud::voice::ILink> plink = pengine->MakeLink("speak");
    std::mutex mutex;
    std::vector<Json> messages;
    std::size_t nbytes = 0;
    std::string error;
    REQUIRE(plink->Open(
        [&](bool _bBinary, const std::string& _Data)
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (_bBinary)
            {
                nbytes += _Data.size();
            }
            else
            {
                messages.push_back(Json::Parse(_Data).value_or(Json()));
            }
        },
        [](int, const std::string&) {}, error));
    Json say = Json::Object();
    say.Set("type", "say")
        .Set("id", "r1")
        .Set("text", std::string(kHello) + " " + kHello)
        .Set("voice", "small:bragi-1")
        .Set("sampleRate", 21120)
        .Set("speed", 1.3)
        .Set("wobble", 0.045)
        .Set("rough", 0.15);
    REQUIRE(plink->SendText(say.Dump()));
    const auto deadline = std::chrono::steady_clock::now() + 60s;
    for (;;)
    {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!messages.empty() && messages.back()["type"].AsString() != "start")
            {
                break;
            }
        }
        REQUIRE(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(10ms);
    }
    std::lock_guard<std::mutex> lock(mutex);
    INFO(messages.back().Dump());
    CHECK(messages.front()["type"].AsString() == "start");
    CHECK(messages.front()["provider"].AsString() == "small");
    CHECK(messages.front()["sampleRate"].AsInt() == 21120);
    CHECK(messages.back()["type"].AsString() == "end");
    CHECK(nbytes > 2 * 24000); // over a second of 16-bit audio for two sentences
    plink->Close();
}

TEST_CASE("Without small voices set up, a small voice's say is an error", "[speech][small]")
{
    const fs::path state = TempDir("unset");
    std::unique_ptr<LocalEngine> pengine = SmallEngine(state, false);
    CHECK_FALSE(pengine->SmallConfigured());
    std::unique_ptr<gitgud::voice::ILink> plink = pengine->MakeLink("speak");
    std::mutex mutex;
    std::vector<Json> messages;
    std::string error;
    REQUIRE(plink->Open(
        [&](bool _bBinary, const std::string& _Data)
        {
            if (!_bBinary)
            {
                std::lock_guard<std::mutex> lock(mutex);
                messages.push_back(Json::Parse(_Data).value_or(Json()));
            }
        },
        [](int, const std::string&) {}, error));
    REQUIRE(plink->SendText(R"({"type":"say","id":"r1","text":"həlˈO.","voice":"small:bragi-1"})"));
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    for (;;)
    {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!messages.empty())
            {
                break;
            }
        }
        REQUIRE(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(10ms);
    }
    std::lock_guard<std::mutex> lock(mutex);
    CHECK(messages.front()["type"].AsString() == "error");
    CHECK(messages.front()["code"].AsString() == "tts");
    CHECK(messages.front()["id"].AsString() == "r1");
    plink->Close();
}
