// Spoken replies with Chatterbox Turbo (src/speech/Turbo*, SpeechText,
// Gpt2Tokenizer, OnnxPatch): text shaping, the stretch, the tokenizer, the
// sampler, the generation loop over fake networks, voice files, the graph
// patch. The real models on a GPU are a hidden test ([.voice-gpu]):
//   GITGUD_TEST_VOICE_GPU   a folder with the GPU runtime (sherpa-onnx's
//                           CUDA build and NVIDIA's CUDA and cuDNN DLLs)
//   GITGUD_TEST_TURBO_DIR   the Turbo download (tokenizer.json, onnx\ with
//                           the *_q4acc4 / *_quantizedacc4 graphs)
//   GITGUD_TEST_TURBO_REF   a voice recording (WAV)
//   GITGUD_TEST_VOICE_MODELS the listening models, as for [.voice-models]

#include <catch2/catch_test_macros.hpp>

#include "app/Json.h"
#include "platform/Process.h"
#include "platform/Shell.h"
#include "speech/Gpt2Tokenizer.h"
#include "speech/Guard.h"
#include "speech/LocalEngine.h"
#include "speech/OnnxPatch.h"
#include "speech/SherpaApi.h"
#include "speech/SpeechText.h"
#include "speech/Turbo.h"

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <thread>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

using namespace gitgud::speech;
using gitgud::app::Json;
namespace fs = std::filesystem;
using namespace std::chrono_literals;

namespace
{

    // This run's own folder in the temp folder (removed when it ends), so
    // test runs in other worktrees at the same time never share files.
    struct RunDir
    {
        fs::path m_Path =
            fs::temp_directory_path() / ("gitgud_turbo_" + std::to_string(std::random_device()()));
        ~RunDir()
        {
            std::error_code ec;
            fs::remove_all(m_Path, ec);
        }
    };

    fs::path TempDir(const std::string& _Name)
    {
        static const RunDir run;
        const fs::path dir = run.m_Path / _Name;
        std::error_code ec;
        fs::remove_all(dir, ec);
        fs::create_directories(dir);
        return dir;
    }

    std::vector<float> Tone(double _fHz, double _fSeconds, int _iRate)
    {
        std::vector<float> out(static_cast<std::size_t>(_fSeconds * _iRate));
        for (std::size_t ni = 0; ni < out.size(); ++ni)
        {
            out[ni] = 0.5f * static_cast<float>(std::sin(
                                 2 * 3.14159265358979 * _fHz * static_cast<double>(ni) / _iRate));
        }
        return out;
    }

    // Zero crossings a second: about twice the pitch.
    double CrossingsPerSecond(const std::vector<float>& _Samples, int _iRate)
    {
        std::size_t n = 0;
        for (std::size_t ni = 1; ni < _Samples.size(); ++ni)
        {
            if ((_Samples[ni - 1] < 0) != (_Samples[ni] < 0))
            {
                ++n;
            }
        }
        return static_cast<double>(n) * _iRate / static_cast<double>(_Samples.size());
    }

    // A tiny GPT-2 tokenizer.json: the bytes of "ab c" and two merges.
    std::string TinyTokenizer()
    {
        return R"({"added_tokens":[{"id":9,"content":"<|endoftext|>"},{"id":8,"content":"[chuckle]"}],
            "model":{"vocab":{"a":0,"b":1,"c":2,"Ġ":3,"ab":4,"Ġc":5,".":6,"!":7},
            "merges":["a b","Ġ c"]}})";
    }

    // Networks that return what the test sets, and remember the calls.
    class FakeNets : public ITurboNets
    {
      public:
        std::vector<int64_t> m_Tokens; // what the "model" says, in order (then STOP)
        std::size_t m_nNext = 0;
        int m_iSteps = 0;
        int m_iResets = 0;
        std::vector<int64_t> m_Decoded;
        int64_t m_iLastPosition = -1;
        int64_t m_iFirstLength = -1;

        bool Encode(const std::vector<float>& _Audio, std::vector<Tensor>& _Out) override
        {
            _Out = {Tensor::FromFloats(std::vector<float>(2 * 4, 0.5f), {1, 2, 4}),
                Tensor::FromInts({100, 101, static_cast<int64_t>(_Audio.size() / 24000)}, {1, 3}),
                Tensor::FromFloats({1, 2}, {1, 2}), Tensor::FromFloats({1, 2, 3}, {1, 1, 3})};
            return true;
        }

        bool Embed(const std::vector<int64_t>& _Ids, Tensor& _Out) override
        {
            _Out = Tensor::FromFloats(std::vector<float>(_Ids.size() * 4, 0.25f),
                {1, static_cast<int64_t>(_Ids.size()), 4});
            return true;
        }

        void Reset() override
        {
            ++m_iResets;
            m_nNext = 0;
        }

        bool Step(const Tensor& _Embeds, int64_t _iPosition, std::vector<float>& _Logits) override
        {
            if (m_iSteps++ == 0)
            {
                m_iFirstLength = _Embeds.m_Shape[1];
            }
            m_iLastPosition = _iPosition;
            const int64_t inext = m_nNext < m_Tokens.size() ? m_Tokens[m_nNext++] : kTurboStop;
            _Logits.assign(6563, -100.0f);
            _Logits[static_cast<std::size_t>(inext)] = 100.0f; // certain
            return true;
        }

        bool Decode(const std::vector<int64_t>& _SpeechTokens, const Tensor&, const Tensor&,
            std::vector<float>& _Audio) override
        {
            m_Decoded = _SpeechTokens;
            _Audio = Tone(
                220, static_cast<double>(_SpeechTokens.size()) * 0.04, 24000); // 25 tokens a second
            return true;
        }
    };

} // namespace

TEST_CASE("Replies are split as the voice server did", "[speech][turbo]")
{
    CHECK(SplitForSpeech("Done. The pull request is open.") ==
          std::vector<std::string>{"Done.", "The pull request is open."});
    CHECK(SplitForSpeech(
              "I checked the build on the main branch, and it passed this morning. The only "
              "warning was "
              "here.") == std::vector<std::string>{"I checked the build on the main branch,",
                              "and it passed this morning.", "The only warning was here."});
    // Version numbers and file names stay whole; quotes stay with their sentence.
    CHECK(SplitForSpeech("Open 1.5.3 and Listen.cpp now. He said \"go.\" Then stop!") ==
          std::vector<std::string>{
              "Open 1.5.3 and Listen.cpp now.", "He said \"go.\"", "Then stop!"});
    // A long sentence without a period breaks at a comma.
    const std::string longText(250, 'a');
    const auto pieces = SplitForSpeech(longText + ", " + longText);
    CHECK(pieces.size() == 2);
}

TEST_CASE("Punctuation is normalized as Chatterbox does", "[speech][turbo]")
{
    CHECK(NormalizeForSpeech("  and it passed  this morning ") == "And it passed this morning.");
    CHECK(NormalizeForSpeech("wait... what; really: yes - no") == "Wait, what, really, yes, no.");
    CHECK(NormalizeForSpeech("Is it?") == "Is it?");
    CHECK(NormalizeForSpeech("").empty());
}

TEST_CASE("The stretch keeps the pitch and changes the length", "[speech][turbo]")
{
    const std::vector<float> tone = Tone(200, 2.0, 24000);
    const std::vector<float> fast = Stretch(tone, 1.15, 24000);
    CHECK(fast.size() == static_cast<std::size_t>(tone.size() / 1.15));
    const double fbefore = CrossingsPerSecond(tone, 24000);
    const double fafter = CrossingsPerSecond(fast, 24000);
    CHECK(std::fabs(fafter - fbefore) / fbefore < 0.05);
    CHECK(Stretch(tone, 1.0, 24000) == tone);
    const std::vector<float> slow = Stretch(tone, 0.4, 24000); // far below: no out-of-range reads
    CHECK(slow.size() == static_cast<std::size_t>(tone.size() / 0.4));
}

TEST_CASE("A stray sound after the sentence is trimmed", "[speech][turbo]")
{
    std::vector<float> audio = Tone(200, 1.5, 24000);
    audio.resize(audio.size() + 24000 / 2, 0.0f); // half a second of quiet
    const std::vector<float> ah = Tone(300, 0.3, 24000);
    audio.insert(audio.end(), ah.begin(), ah.end());
    CHECK(TrimStrayTail(audio, 24000, "Done.") > 0.4);
    CHECK(audio.size() < static_cast<std::size_t>(1.8 * 24000));
    // Speech that's all one part stays.
    std::vector<float> plain = Tone(200, 2.0, 24000);
    CHECK(TrimStrayTail(plain, 24000, "Done.") == 0);
}

TEST_CASE("GPT-2's pre-split matches its pattern", "[speech][turbo]")
{
    CHECK(Gpt2Tokenizer::PreSplit("It's 3.5 seconds; don't stop_now!  OK?") ==
          std::vector<std::string>{"It", "'s", " 3", ".", "5", " seconds", ";", " don", "'t",
              " stop", "_", "now", "!", " ", " OK", "?"});
    CHECK(Gpt2Tokenizer::PreSplit("  two  spaces ") ==
          std::vector<std::string>{" ", " two", " ", " spaces", " "});
    CHECK(Gpt2Tokenizer::PreSplit("na\xC3\xAFve") == std::vector<std::string>{"na\xC3\xAFve"});
}

TEST_CASE("The tokenizer merges by rank and keeps tags whole", "[speech][turbo]")
{
    Gpt2Tokenizer tokenizer;
    std::string error;
    REQUIRE(tokenizer.Load(TinyTokenizer(), error));
    CHECK(tokenizer.Encode("ab c.") == std::vector<int64_t>{4, 5, 6, 9, 9});
    CHECK(tokenizer.Encode("ab[chuckle]!") == std::vector<int64_t>{4, 8, 7, 9, 9});
    CHECK_FALSE(Gpt2Tokenizer().Load("{}", error));
}

TEST_CASE("Sampling follows Turbo's settings", "[speech][turbo]")
{
    std::mt19937 rng(42);
    SamplerConfig config;
    // A token far ahead of the rest is always picked.
    std::vector<float> logits(100, 0.0f);
    logits[7] = 50.0f;
    CHECK(SampleToken(logits, {}, config, rng) == 7);
    // min_p leaves only tokens near the best one.
    for (int i = 0; i < 50; ++i)
    {
        std::vector<float> two(100, -50.0f);
        two[3] = 10.0f;
        two[4] = 10.0f;
        const int64_t id = SampleToken(two, {}, config, rng);
        CHECK((id == 3 || id == 4));
    }
    // The repetition penalty, once per token seen: positive divided,
    // negative multiplied.
    std::vector<float> penalized = {2.4f, -1.0f, 0.0f};
    SampleToken(penalized, {0, 0, 1}, config, rng);
    CHECK(std::fabs(penalized[0] - 2.0f) < 1e-5);
    CHECK(std::fabs(penalized[1] + 1.2f) < 1e-5);
}

TEST_CASE("Half floats convert both ways", "[speech][turbo]")
{
    for (float f : {0.0f, 1.0f, -2.5f, 0.333f, 65504.0f, 1e-6f})
    {
        CHECK(std::fabs(HalfToFloat(FloatToHalf(f)) - f) <= std::fabs(f) * 1e-3f + 1e-7f);
    }
    const Tensor half = Tensor::FromFloats({1.5f, -0.25f}, {2}).As(Tensor::Type::Half);
    CHECK(half.m_Data.size() == 4);
    CHECK(half.As(Tensor::Type::Float).Floats() == std::vector<float>{1.5f, -0.25f});
}

TEST_CASE("A sentence goes through the networks as Turbo's loop does", "[speech][turbo]")
{
    Gpt2Tokenizer tokenizer;
    std::string error;
    REQUIRE(tokenizer.Load(TinyTokenizer(), error));
    FakeNets nets;
    nets.m_Tokens = {10, 11, 12, 13, kTurboStop};
    TurboSynth synth(nets, tokenizer);
    VoiceConditioning voice;
    REQUIRE(synth.Clone(Tone(150, 12.0, 24000), voice, error));
    CHECK(voice.m_PromptToken.Ints() == std::vector<int64_t>{100, 101, 10}); // from the first 10 s
    CHECK(voice.m_CondEmb.m_Shape == std::vector<int64_t>{1, 2, 4});

    std::vector<float> audio;
    REQUIRE(synth.Say("ab c", voice, 1.0, nullptr, audio, error));
    // Conditioning (2) plus the text's tokens (ab, c, ., end, end: 5) first,
    // then one token a step.
    CHECK(nets.m_iFirstLength == 7);
    CHECK(nets.m_iSteps == 5);
    CHECK(nets.m_iLastPosition == 7 + 3);
    CHECK(nets.m_Decoded == std::vector<int64_t>{100, 101, 10, 10, 11, 12, 13, kTurboSilence,
                                kTurboSilence, kTurboSilence});
    CHECK(synth.LastTokens() == 4);
    CHECK(audio.size() == static_cast<std::size_t>(10 * 0.04 * 24000));

    // Faster: shorter.
    std::vector<float> fast;
    REQUIRE(synth.Say("ab c", voice, 1.25, nullptr, fast, error));
    CHECK(fast.size() < audio.size());

    // Stopped: nothing said, no error.
    std::vector<float> none;
    REQUIRE(synth.Say("ab c", voice, 1.0, []() { return true; }, none, error));
    CHECK(none.empty());

    // A runaway model stops at the cap (60 + 3 a character).
    nets.m_Tokens.assign(2000, 20);
    REQUIRE(synth.Say("ab", voice, 1.0, nullptr, audio, error));
    CHECK(synth.LastTokens() == 60 + 3 * 3); // "Ab."
}

TEST_CASE("Voice files keep the conditioning", "[speech][turbo]")
{
    const fs::path dir = TempDir("voice");
    VoiceConditioning voice;
    voice.m_CondEmb = Tensor::FromFloats({1, 2, 3, 4}, {1, 1, 4}).As(Tensor::Type::Half);
    voice.m_PromptToken = Tensor::FromInts({5, 6}, {1, 2});
    voice.m_SpeakerEmbeddings = Tensor::FromFloats({0.5f}, {1, 1});
    voice.m_SpeakerFeatures = Tensor::FromFloats({0.25f, 0.75f}, {1, 1, 2});
    std::string error;
    REQUIRE(voice.Save((dir / "baldr.voice").u8string(), error));
    VoiceConditioning loaded;
    REQUIRE(loaded.Load((dir / "baldr.voice").u8string(), error));
    CHECK(loaded.m_CondEmb.m_eType == Tensor::Type::Half);
    CHECK(loaded.m_CondEmb.Floats() == std::vector<float>{1, 2, 3, 4});
    CHECK(loaded.m_PromptToken.Ints() == std::vector<int64_t>{5, 6});
    CHECK(loaded.m_SpeakerFeatures.Floats() == std::vector<float>{0.25f, 0.75f});
    {
        std::ofstream bad(dir / "bad.voice", std::ios::binary);
        bad << "GITGUD-VOICE 1\n" << std::string(20, '\xFF');
    }
    CHECK_FALSE(loaded.Load((dir / "bad.voice").u8string(), error));
    CHECK_FALSE(loaded.Load((dir / "missing.voice").u8string(), error));
}

TEST_CASE("Quantized matmuls get an accuracy level", "[speech][turbo]")
{
    // ModelProto { ir_version: 8, graph { node { op_type: "MatMulNBits" }
    // node { op_type: "Add" } } } as protobuf bytes.
    auto ld = [](int _iField, const std::string& _Payload)
    {
        return std::string(1, static_cast<char>(_iField << 3 | 2)) +
               static_cast<char>(_Payload.size()) + _Payload;
    };
    const std::string matmul = ld(4, "MatMulNBits");
    const std::string add = ld(4, "Add");
    const std::string graph = ld(1, matmul) + ld(1, add);
    const std::string model = std::string("\x08\x08", 2) + ld(7, graph);
    std::string patched;
    int ichanged = 0;
    REQUIRE(SetMatMulNBitsAccuracyBytes(model, 4, patched, ichanged));
    CHECK(ichanged == 1);
    CHECK(patched.find("accuracy_level") != std::string::npos);
    CHECK(patched.size() > model.size());
    // Twice: nothing more.
    std::string again;
    REQUIRE(SetMatMulNBitsAccuracyBytes(patched, 4, again, ichanged));
    CHECK(ichanged == 0);
    CHECK(again == patched);
    CHECK_FALSE(SetMatMulNBitsAccuracyBytes("not a model", 4, again, ichanged));
}

TEST_CASE("A WAV file reads as 24 kHz mono", "[speech][turbo]")
{
    const fs::path dir = TempDir("wav");
    // 0.5 s of 48 kHz stereo 16-bit.
    const int irate = 48000;
    const std::size_t nframes = irate / 2;
    std::string data;
    for (std::size_t ni = 0; ni < nframes; ++ni)
    {
        for (int ic = 0; ic < 2; ++ic)
        {
            const int16_t s = 1000;
            data += static_cast<char>(s & 0xFF);
            data += static_cast<char>((s >> 8) & 0xFF);
        }
    }
    auto u32 = [](uint32_t _v)
    {
        return std::string{static_cast<char>(_v), static_cast<char>(_v >> 8),
            static_cast<char>(_v >> 16), static_cast<char>(_v >> 24)};
    };
    auto u16 = [](uint16_t _v)
    {
        return std::string{static_cast<char>(_v), static_cast<char>(_v >> 8)};
    };
    const std::string fmt = u16(1) + u16(2) + u32(irate) + u32(irate * 4) + u16(4) + u16(16);
    const std::string wav = "RIFF" +
                            u32(static_cast<uint32_t>(4 + 8 + fmt.size() + 8 + data.size())) +
                            "WAVE" + "fmt " + u32(static_cast<uint32_t>(fmt.size())) + fmt +
                            "data" + u32(static_cast<uint32_t>(data.size())) + data;
    {
        std::ofstream out(dir / "in.wav", std::ios::binary);
        out << wav;
    }
    std::vector<float> samples;
    std::string error;
    REQUIRE(ReadWav24k((dir / "in.wav").u8string(), samples, error));
    CHECK(samples.size() == 12000);
    CHECK(std::fabs(samples[100] - 1000.0f / 32768.0f) < 1e-4);
}

#if defined(_WIN32)
TEST_CASE("Without Turbo set up, the speak channel uses the system's voices", "[speech][turbo]")
{
    const fs::path dir = TempDir("fallback");
    LocalEngine engine((dir / "no-libraries").u8string(), dir.u8string());
    std::string error;
    if (engine.Voices(error).empty())
    {
        SKIP("no system voices");
    }
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("speak");
    std::mutex mutex;
    std::vector<Json> messages;
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
    REQUIRE(plink->SendText(R"({"type":"say","id":"r1","text":"Hello.","voice":"turbo:baldr"})"));
    const auto deadline = std::chrono::steady_clock::now() + 30s;
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
    CHECK(messages.front()["type"].AsString() == "start");
    CHECK(messages.front()["provider"].AsString() == "windows");
    CHECK(messages.front()["fallback"].AsString().find("aren't installed") != std::string::npos);
    CHECK(messages.back()["type"].AsString() == "end");
}
#endif

TEST_CASE("A reply that names no voice is Baldr's when Turbo is set up", "[speech][turbo]")
{
    const fs::path dir = TempDir("defaultvoice");
    fs::create_directories(dir / "voices");
    std::ofstream(dir / "voices" / "zed.voice", std::ios::binary) << "x";
    // The app's own libraries (a missing folder would stay the process's
    // only try at loading them).
    LocalEngine engine((fs::u8path(gitgud::platform::ExecutableDirectory()) / "voice").u8string(),
        (dir / "state").u8string());
    CHECK(engine.DefaultMadeVoice().empty()); // Turbo isn't set up yet
    Json tts = Json::Object();
    tts.Set("dir", (dir / "turbo").u8string())
        .Set("encoder", "e.onnx")
        .Set("embed", "m.onnx")
        .Set("lm", "l.onnx")
        .Set("decoder", "d.onnx")
        .Set("tokenizer", (dir / "turbo" / "tokenizer.json").u8string())
        .Set("voicesDir", (dir / "voices").u8string())
        .Set("provider", "cpu");
    Json settings = Json::Object();
    settings.Set("vadModel", (dir / "vad.onnx").u8string())
        .Set("asrDir", (dir / "asr").u8string())
        .Set("kwsDir", (dir / "kws").u8string())
        .Set("workDir", (dir / "work").u8string())
        .Set("tts", tts);
    std::string error;
    REQUIRE(engine.Configure(settings, error));
    CHECK(engine.DefaultMadeVoice() == "turbo:zed");
    std::ofstream(dir / "voices" / "baldr.voice", std::ios::binary) << "x";
    CHECK(engine.DefaultMadeVoice() == "turbo:baldr"); // Baldr first

    // The first reply, before the app knows the voices: no voice named, and
    // Turbo takes it (its models are missing here, so it then says so).
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("speak");
    std::mutex mutex;
    std::vector<Json> messages;
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
    REQUIRE(plink->SendText(R"({"type":"say","id":"r1","text":"Hello."})"));
    const auto deadline = std::chrono::steady_clock::now() + 30s;
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
    INFO(messages.front().Dump());
    CHECK(messages.front()["type"].AsString() == "start");
    CHECK(messages.front()["provider"].AsString().rfind("turbo", 0) == 0);
    plink->Close();
}

// ---- The real models on a GPU (hidden) --------------------------------------------

TEST_CASE("Turbo speaks Baldr on the GPU or the processor", "[.voice-gpu]")
{
    const char* szgpu = std::getenv("GITGUD_TEST_VOICE_GPU");
    const char* szturbo = std::getenv("GITGUD_TEST_TURBO_DIR");
    const char* szref = std::getenv("GITGUD_TEST_TURBO_REF");
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    if (!szturbo || !szref || !szmodels)
    {
        SKIP("set GITGUD_TEST_TURBO_DIR, GITGUD_TEST_TURBO_REF, GITGUD_TEST_VOICE_MODELS, and "
             "GITGUD_TEST_VOICE_GPU for the GPU (without it, the processor)");
    }
    const bool bgpu = szgpu && *szgpu;
    const fs::path turbo = fs::u8path(szturbo);
    const fs::path models = fs::u8path(szmodels);
    const fs::path dir = TempDir("gpu");

    // The tokenizer and the splitting match the reference harness.
    {
        std::ifstream in(turbo / "tokenizer.json", std::ios::binary);
        std::stringstream ss;
        ss << in.rdbuf();
        Gpt2Tokenizer tokenizer;
        std::string error;
        REQUIRE(tokenizer.Load(ss.str(), error));
        CHECK(tokenizer.Encode("Done.") == std::vector<int64_t>{45677, 13, 50256, 50256});
        CHECK(
            tokenizer.Encode(
                "Most of the work is in Listen.cpp, where the voice service now reads its settings "
                "from a JSON file instead of the command line.") ==
            std::vector<int64_t>{6943, 286, 262, 670, 318, 287, 20600, 13, 20322, 11, 810, 262,
                3809, 2139, 783, 9743, 663, 6460, 422, 257, 19449, 2393, 2427, 286, 262, 3141, 1627,
                13, 50256, 50256});
        CHECK(tokenizer.Encode(NormalizeForSpeech(
                  "If you want, I can open a pull request for version 1.5.3 tonight.")) ==
              std::vector<int64_t>{1532, 345, 765, 11, 314, 460, 1280, 257, 2834, 2581, 329, 2196,
                  352, 13, 20, 13, 18, 9975, 13, 50256, 50256});
        CHECK(tokenizer.Encode("It's 3.5 seconds; don't stop_now!  OK?") ==
              std::vector<int64_t>{1026, 338, 513, 13, 20, 4201, 26, 836, 470, 2245, 62, 2197, 0,
                  220, 7477, 30, 50256, 50256});
        CHECK(tokenizer.Encode("na\xC3\xAFve caf\xC3\xA9 [chuckle] works") ==
              std::vector<int64_t>{2616, 38776, 40304, 220, 50274, 2499, 50256, 50256});
        CHECK(tokenizer.Encode("  two  spaces ") ==
              std::vector<int64_t>{220, 734, 220, 9029, 220, 50256, 50256});
    }

    // The graph patch gives the same bytes as the reference harness's.
    for (const char* szname : {"language_model_q4", "conditional_decoder_q4", "speech_encoder_q4"})
    {
        const std::string in = (turbo / "onnx" / (std::string(szname) + ".onnx")).u8string();
        const std::string out = (dir / (std::string(szname) + "acc4.onnx")).u8string();
        int ichanged = 0;
        std::string error;
        REQUIRE(SetMatMulNBitsAccuracy(in, out, 4, ichanged, error));
        CHECK(ichanged > 0);
        auto read = [](const std::string& _Path)
        {
            std::ifstream file(fs::u8path(_Path), std::ios::binary);
            std::stringstream ss;
            ss << file.rdbuf();
            return ss.str();
        };
        CHECK(read(out) == read((turbo / "onnx" / (std::string(szname) + "acc4.onnx")).u8string()));
    }

    LocalEngine engine((fs::u8path(gitgud::platform::ExecutableDirectory()) / "voice").u8string(),
        (dir / "state").u8string());
    Json tts = Json::Object();
    tts.Set("dir", (turbo / "onnx").u8string())
        .Set("encoder", "speech_encoder_q4acc4.onnx")
        .Set("embed", "embed_tokens_q4acc4.onnx")
        .Set("lm", "language_model_q4acc4.onnx")
        .Set("decoder", "conditional_decoder_q4acc4.onnx")
        .Set("tokenizer", (turbo / "tokenizer.json").u8string())
        .Set("voicesDir", (dir / "voices").u8string())
        .Set("provider", "cuda")
        .Set("threads", 4)
        .Set("cpuThreads", 8);
    Json settings = Json::Object();
    settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
        .Set("asrDir",
            (models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8").u8string())
        .Set("kwsDir",
            (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01").u8string())
        .Set("speakerModel", (models / "speaker" / "nemo_en_titanet_large.onnx").u8string())
        .Set("workDir", (dir / "work").u8string())
        .Set("tts", tts);
    std::string error;
    REQUIRE(engine.Configure(settings, error));
    REQUIRE(engine.TurboConfigured());

    std::mutex mutex;
    std::condition_variable wake;
    std::optional<Json> made;
    auto makeVoice = [&]()
    {
        made.reset();
        engine.MakeVoice(szref, "baldr",
            [&](const Json& _Result)
            {
                std::lock_guard<std::mutex> lock(mutex);
                made = _Result;
                wake.notify_all();
            });
        std::unique_lock<std::mutex> lock(mutex);
        REQUIRE(wake.wait_for(lock, 600s, [&]() { return made.has_value(); }));
        INFO(made->Dump());
        REQUIRE((*made)["ok"].AsBool());
    };

    // First on the processor, as before the GPU pack is there: nothing of
    // CUDA loads.
    auto t0 = std::chrono::steady_clock::now();
    makeVoice();
    CHECK(engine.State().m_TurboDevice == "cpu");
    CHECK_FALSE(SherpaOnGpu());
#if defined(_WIN32)
    CHECK(GetModuleHandleW(L"onnxruntime_providers_cuda.dll") == nullptr);
    CHECK(GetModuleHandleW(L"cudart64_13.dll") == nullptr);
#endif
    CHECK(fs::exists(dir / "voices" / "baldr.voice"));
    double fmakeSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    // A broken pack: the GPU doesn't start, Turbo stays on the processor and
    // says why.
    {
        const fs::path broken = dir / "broken-gpu";
        fs::create_directories(broken);
        std::ofstream(broken / "onnxruntime_providers_cuda.dll", std::ios::binary) << "not a library";
        settings.Set("gpuDir", broken.u8string());
        REQUIRE(engine.Configure(settings, error));
        makeVoice();
        CHECK(engine.State().m_TurboDevice == "cpu");
        CHECK_FALSE(engine.State().m_GpuError.empty());
        CHECK_FALSE(SherpaOnGpu());
    }
    if (bgpu)
    {
        // The pack arrives: the same engine, in the same run, moves Turbo to
        // the GPU (no restart).
        settings.Set("gpuDir", szgpu);
        REQUIRE(engine.Configure(settings, error));
        t0 = std::chrono::steady_clock::now();
        makeVoice();
        fmakeSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        INFO(engine.State().m_GpuError);
        CHECK(engine.State().m_TurboDevice == "gpu");
        CHECK(SherpaOnGpu());
        CHECK(engine.State().m_GpuError.empty());
    }

    // A reply through the speak channel.
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("speak");
    std::vector<Json> messages;
    std::size_t nbytes = 0;
    std::string pcm;
    REQUIRE(plink->Open(
        [&](bool _bBinary, const std::string& _Data)
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (_bBinary)
            {
                nbytes += _Data.size();
                pcm += _Data;
            }
            else
            {
                messages.push_back(Json::Parse(_Data).value_or(Json()));
            }
            wake.notify_all();
        },
        [](int, const std::string&) {}, error));
    const auto t1 = std::chrono::steady_clock::now();
    REQUIRE(plink->SendText(
        R"({"type":"say","id":"r1","text":"Done. The pull request is open.","voice":"turbo:baldr","speed":1.15})"));
    double ffirst = 0;
    {
        std::unique_lock<std::mutex> lock(mutex);
        REQUIRE(wake.wait_for(lock, 600s,
            [&]()
            {
                return nbytes > 0 ||
                       (!messages.empty() && messages.back()["type"].AsString() != "start");
            }));
        ffirst = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
        REQUIRE(wake.wait_for(lock, 600s,
            [&]() { return !messages.empty() && messages.back()["type"].AsString() != "start"; }));
    }
    const double ftotal =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
    std::lock_guard<std::mutex> lock(mutex);
    INFO(messages.back().Dump());
    CHECK(messages.front()["provider"].AsString() == (bgpu ? "turbo" : "turbo-cpu"));
    CHECK(messages.back()["type"].AsString() == "end");
    const double faudio = static_cast<double>(nbytes) / 2 / kTurboRate;
    CHECK(faudio > 1.0);
    CHECK(faudio < 8.0);
    WARN("voice made in " << fmakeSeconds << " s; first audio " << ffirst << " s, total " << ftotal
                          << " s for " << faudio << " s of audio");
    // For listening: the reply as a WAV in the test folder.
    {
        std::ofstream out(dir / "reply.wav", std::ios::binary);
        auto u32 = [](uint32_t _v)
        {
            return std::string{static_cast<char>(_v), static_cast<char>(_v >> 8),
                static_cast<char>(_v >> 16), static_cast<char>(_v >> 24)};
        };
        auto u16 = [](uint16_t _v)
        {
            return std::string{static_cast<char>(_v), static_cast<char>(_v >> 8)};
        };
        const std::string fmt =
            u16(1) + u16(1) + u32(kTurboRate) + u32(kTurboRate * 2) + u16(2) + u16(16);
        out << "RIFF" << u32(static_cast<uint32_t>(36 + pcm.size())) << "WAVE" << "fmt " << u32(16)
            << fmt << "data" << u32(static_cast<uint32_t>(pcm.size())) << pcm;
    }
    CHECK_FALSE(engine.State().m_bFaulted);
}

// ---- Closing the app with Baldr loaded (hidden) ------------------------------------
//
// The app's own engine (LocalEngine::Instance, as gitgud.exe uses it) loads
// Turbo, speaks one reply, and the process ends the way gitgud.exe's does:
// main() releases the models (PrepareForExit), then the static teardown.
// Run as a child process ten times on the processor and, with
// GITGUD_TEST_VOICE_GPU, ten times on the GPU: each must exit cleanly and
// leave no crash for the next start.

namespace
{
    // The child's part: GITGUD_TEST_EXIT_GPU ("" for the processor).
    int RunExitChild()
    {
        const char* szturbo = std::getenv("GITGUD_TEST_TURBO_DIR");
        const char* szref = std::getenv("GITGUD_TEST_TURBO_REF");
        const char* szgpu = std::getenv("GITGUD_TEST_EXIT_GPU");
        const fs::path turbo = fs::u8path(szturbo);
        const fs::path dir = fs::u8path(gitgud::platform::ConfigDirectory()) / "exit-test";
        LocalEngine& engine = LocalEngine::Instance();
        Json tts = Json::Object();
        tts.Set("dir", (turbo / "onnx").u8string())
            .Set("encoder", "speech_encoder_q4acc4.onnx")
            .Set("embed", "embed_tokens_q4acc4.onnx")
            .Set("lm", "language_model_q4acc4.onnx")
            .Set("decoder", "conditional_decoder_q4acc4.onnx")
            .Set("tokenizer", (turbo / "tokenizer.json").u8string())
            .Set("voicesDir", (dir / "voices").u8string())
            .Set("provider", "cuda")
            .Set("threads", 4)
            .Set("cpuThreads", 8);
        const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
        const fs::path models = fs::u8path(szmodels);
        Json settings = Json::Object();
        settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
            .Set("asrDir",
                (models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8").u8string())
            .Set("kwsDir",
                (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01").u8string())
            .Set("speakerModel", (models / "speaker" / "nemo_en_titanet_large.onnx").u8string())
            .Set("workDir", (dir / "work").u8string())
            .Set("tts", tts);
        if (szgpu && *szgpu)
        {
            settings.Set("gpuDir", szgpu);
        }
        std::string error;
        if (!engine.Configure(settings, error))
        {
            std::fprintf(stderr, "configure: %s\n", error.c_str());
            return 2;
        }
        std::mutex mutex;
        std::condition_variable wake;
        bool bmade = false;
        bool bok = false;
        if (!fs::exists(dir / "voices" / "baldr.voice"))
        {
            engine.MakeVoice(szref, "baldr",
                [&](const Json& _Result)
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    bmade = true;
                    bok = _Result["ok"].AsBool();
                    wake.notify_all();
                });
            std::unique_lock<std::mutex> lock(mutex);
            wake.wait_for(lock, 600s, [&]() { return bmade; });
            if (!bok)
            {
                return 3;
            }
        }
        // One reply, then the window "closes".
        std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("speak");
        bool bended = false;
        if (!plink->Open(
                [&](bool _bBinary, const std::string& _Data)
                {
                    if (_bBinary)
                    {
                        return;
                    }
                    const Json json = Json::Parse(_Data).value_or(Json());
                    std::lock_guard<std::mutex> lock(mutex);
                    if (json["type"].AsString() == "end" || json["type"].AsString() == "error")
                    {
                        bended = true;
                        wake.notify_all();
                    }
                },
                [](int, const std::string&) {}, error))
        {
            return 4;
        }
        plink->SendText(R"({"type":"say","id":"r1","text":"Done.","voice":"turbo:baldr"})");
        {
            std::unique_lock<std::mutex> lock(mutex);
            wake.wait_for(lock, 300s, [&]() { return bended; });
        }
        if (engine.State().m_TurboDevice != ((szgpu && *szgpu) ? "gpu" : "cpu"))
        {
            std::fprintf(stderr, "Turbo on '%s'\n", engine.State().m_TurboDevice.c_str());
            return 5;
        }
        plink->Close();
        plink.reset();
        if (!std::getenv("GITGUD_TEST_EXIT_SKIP_PREPARE"))
        {
            LocalEngine::PrepareForExit(20s); // as gitgud.exe's main() does
        }
        return 0;
    }
} // namespace

TEST_CASE("The app's engine child: Baldr loaded, one reply, then exit", "[.voice-exit-child]")
{
    const int icode = RunExitChild();
    std::fflush(nullptr);
    // Ends the process the way gitgud.exe does: returning from main.
    CHECK(icode == 0);
}

TEST_CASE("Closing with Baldr loaded never leaves a crash behind", "[.voice-exit]")
{
    const char* szturbo = std::getenv("GITGUD_TEST_TURBO_DIR");
    const char* szref = std::getenv("GITGUD_TEST_TURBO_REF");
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    if (!szturbo || !szref || !szmodels)
    {
        SKIP("set GITGUD_TEST_TURBO_DIR, GITGUD_TEST_TURBO_REF, GITGUD_TEST_VOICE_MODELS "
             "(and GITGUD_TEST_VOICE_GPU for the GPU runs)");
    }
    const char* szgpu = std::getenv("GITGUD_TEST_VOICE_GPU");
    const fs::path base = TempDir("exit");
    const std::string exe =
        (fs::u8path(gitgud::platform::ExecutableDirectory()) / "gitgud_tests.exe").u8string();
    std::vector<std::string> devices{""};
    if (szgpu && *szgpu)
    {
        devices.push_back(szgpu);
    }
    const int iruns = std::getenv("GITGUD_TEST_EXIT_RUNS") ? std::atoi(std::getenv("GITGUD_TEST_EXIT_RUNS")) : 10;
    for (const std::string& device : devices)
    {
        const fs::path appdata = base / (device.empty() ? "cpu" : "gpu");
        fs::create_directories(appdata);
#if defined(_WIN32)
        _putenv_s("APPDATA", appdata.u8string().c_str());
        _putenv_s("GITGUD_TEST_EXIT_GPU", device.c_str());
#endif
        for (int i = 0; i < iruns; ++i)
        {
            INFO((device.empty() ? "processor" : "GPU") << " run " << (i + 1));
            const auto t0 = std::chrono::steady_clock::now();
            const auto result =
                gitgud::platform::RunProcess({exe, "[.voice-exit-child]"}, appdata.u8string());
            const double fseconds =
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            INFO(result.m_Output.substr(result.m_Output.size() > 2000 ? result.m_Output.size() - 2000 : 0));
            INFO(result.m_Error.substr(result.m_Error.size() > 2000 ? result.m_Error.size() - 2000 : 0));
            CHECK(result.m_iExitCode == 0);
            // The next start finds nothing: no call was in progress, and the
            // exit-time release finished.
            const fs::path state = appdata / "Gitgud" / "bragi";
            for (const char* szmarker : {"voice-state", "voice-state-speak"})
            {
                const std::string call = CrashMarker::TakeLast((state / szmarker).u8string());
                CHECK(call == "");
            }
            std::ifstream log(state / "voice-engine.log", std::ios::binary);
            std::stringstream ss;
            ss << log.rdbuf();
            CHECK(ss.str().find("exit: models released") != std::string::npos);
            WARN((device.empty() ? "processor" : "GPU") << " run " << (i + 1) << ": " << fseconds << " s");
        }
    }
#if defined(_WIN32)
    _putenv_s("GITGUD_TEST_EXIT_GPU", "");
#endif
}
