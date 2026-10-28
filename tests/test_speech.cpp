// The speech engine inside the app (src/speech): its guards, its input
// checks, and its links. Nothing here needs the models; one test needs the
// voice libraries beside the test exe (skipped without them), and the
// real-model smoke test is hidden ([.voice-models]): run it with
// GITGUD_TEST_VOICE_MODELS set to a folder with vad/, kws/, parakeet/, and
// speaker/ as the Bragi interface installs them.

#include <catch2/catch_test_macros.hpp>
#include <catch2/generators/catch_generators.hpp>

#include "app/Json.h"
#include "platform/Http.h"
#include "platform/Process.h"
#include "platform/Shell.h"
#include "speech/Guard.h"
#include "speech/LocalEngine.h"
#include "speech/Recognizer.h"
#include "speech/SherpaApi.h"
#include "speech/Text.h"
#include "speech/WordPiece.h"

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>
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
            fs::temp_directory_path() / ("gitgud_speech_" + std::to_string(std::random_device()()));
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

    void WriteFile(const fs::path& _Path, const std::string& _Text)
    {
        fs::create_directories(_Path.parent_path());
        std::ofstream out(_Path, std::ios::binary | std::ios::trunc);
        out << _Text;
    }

    // Waits for a condition the engine thread makes true.
    template <typename F> bool WaitFor(F _Done, std::chrono::milliseconds _Limit = 10s)
    {
        const auto deadline = std::chrono::steady_clock::now() + _Limit;
        while (!_Done())
        {
            if (std::chrono::steady_clock::now() > deadline)
            {
                return false;
            }
            std::this_thread::sleep_for(5ms);
        }
        return true;
    }

    // What a link delivered.
    struct Received
    {
        std::mutex m_Mutex;
        std::vector<std::string> m_Texts;
        int m_iClose = -1;
        std::string m_Reason;

        gitgud::voice::ILink::OnMessage OnMessage()
        {
            return [this](bool _bBinary, const std::string& _Data)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                if (!_bBinary)
                {
                    m_Texts.push_back(_Data);
                }
            };
        }

        gitgud::voice::ILink::OnClose OnClose()
        {
            return [this](int _iCode, const std::string& _Reason)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_iClose = _iCode;
                m_Reason = _Reason;
            };
        }

        bool Closed()
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            return m_iClose >= 0;
        }

        Json Last()
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            return m_Texts.empty() ? Json() : Json::Parse(m_Texts.back()).value_or(Json());
        }

        // The newest message of `_Type` (null if none came).
        Json LastOf(const std::string& _Type)
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            for (auto it = m_Texts.rbegin(); it != m_Texts.rend(); ++it)
            {
                Json json = Json::Parse(*it).value_or(Json());
                if (json["type"].AsString() == _Type)
                {
                    return json;
                }
            }
            return Json();
        }
    };

    std::string VoiceLibraries()
    {
        return (fs::u8path(gitgud::platform::ExecutableDirectory()) / "voice").u8string();
    }

#if defined(_WIN32)
    void NullWrite()
    {
        volatile int* pnull = nullptr;
        *pnull = 1;
    }
#endif

} // namespace

TEST_CASE("Guarded tells normal ends, exceptions, and faults apart", "[speech]")
{
    int icalls = 0;
    CHECK(Guarded([&]() { ++icalls; }).Ok());
    CHECK(icalls == 1);

    const GuardResult thrown =
        Guarded([]() { throw std::runtime_error("Protobuf parsing failed"); });
    CHECK(thrown.m_eEnd == GuardEnd::Exception);
    CHECK(thrown.m_Detail == "Protobuf parsing failed");

    const GuardResult other = Guarded([]() { throw 42; });
    CHECK(other.m_eEnd == GuardEnd::Exception);

#if defined(_WIN32)
    const GuardResult fault = Guarded([]() { NullWrite(); });
    CHECK(fault.m_eEnd == GuardEnd::Fault);
    CHECK(fault.m_uCode == 0xC0000005ul);
    CHECK(fault.m_Detail.find("0xC0000005") != std::string::npos);
#endif
}

TEST_CASE("The watchdog names an overdue call once", "[speech]")
{
    Watchdog watchdog;
    const auto now = Watchdog::Clock::now();
    CHECK(watchdog.Overdue(now + 1h).empty()); // no call running

    watchdog.Begin("transcribe", 50ms);
    CHECK(watchdog.Overdue(Watchdog::Clock::now()).empty());
    CHECK(watchdog.Overdue(Watchdog::Clock::now() + 100ms) == "transcribe");
    CHECK(watchdog.Hung());
    CHECK(watchdog.Overdue(Watchdog::Clock::now() + 200ms).empty()); // said once
    watchdog.End();
    CHECK(watchdog.Hung());
}

#if defined(_WIN32)
TEST_CASE("The crash marker keeps the call in progress for the next start", "[speech]")
{
    const fs::path dir = TempDir("marker");
    const std::string path = (dir / "voice-state").u8string();
    {
        CrashMarker marker;
        REQUIRE(marker.Open(path));
        marker.Set("load the recognizer");
        // As if the process ended here: the file holds the name.
        CHECK(CrashMarker::TakeLast(path) == "load the recognizer");
        marker.Set("transcribe");
        marker.Clear();
    }
    CHECK(CrashMarker::TakeLast(path).empty());
    {
        CrashMarker marker;
        REQUIRE(marker.Open(path));
        marker.Set("spot the wake word");
    }
    CHECK(CrashMarker::TakeLast(path) == "spot the wake word");
    CHECK(CrashMarker::TakeLast(path).empty()); // taken
}
#endif

TEST_CASE("Keyword lines only use tokens the spotter has", "[speech]")
{
    BpeTokenizer bpe;
    bpe.SetScores({{"\xE2\x96\x81"
                    "BRA",
                       -1.0f},
        {"GI", -1.0f},
        {"\xE2\x96\x81"
         "B",
            -3.0f},
        {"R", -3.0f}, {"A", -3.0f}, {"G", -3.0f}, {"I", -3.0f},
        {"\xE2\x96\x81"
         "HEY",
            -1.0f}});
    std::map<std::string, int> tokens{{"<blk>", 0},
        {"\xE2\x96\x81"
         "BRA",
            1},
        {"GI", 2},
        {"\xE2\x96\x81"
         "HEY",
            3}};

    CHECK(bpe.Encode("Bragi") == std::vector<std::string>{"\xE2\x96\x81"
                                                          "BRA",
                                     "GI"});
    const std::string line = KeywordLine(bpe, tokens, "Bragi", 1.5f, 0.25f);
    CHECK(line == "\xE2\x96\x81"
                  "BRA GI :1.50 #0.25 @Bragi");
    CHECK(
        KeywordLine(bpe, tokens, "hey Bragi", 1.5f, 0.25f).find("@hey_Bragi") != std::string::npos);

    // A piece the model lacks would make a stream that crashes when fed.
    tokens.erase("GI");
    CHECK(KeywordLine(bpe, tokens, "Bragi", 1.5f, 0.25f).empty());
    // The line format's own characters, and nothing at all.
    tokens["GI"] = 2;
    CHECK(KeywordLine(bpe, tokens, "Bragi@x", 1.5f, 0.25f).empty());
    CHECK(KeywordLine(bpe, tokens, "  ", 1.5f, 0.25f).empty());
    CHECK(KeywordLine(BpeTokenizer{}, tokens, "Bragi", 1.5f, 0.25f).empty());
}

TEST_CASE("Hotword lines only use characters the recognizer has", "[speech]")
{
    std::map<std::string, int> tokens{{"<blk>", 0}};
    for (char c : std::string("abcdefghijklmnopqrstuvwxyzBG"))
    {
        tokens[std::string(1, c)] = static_cast<int>(tokens.size());
    }
    CHECK(HotwordLine(tokens, "Bragi", 0) == "Bragi");
    CHECK(HotwordLine(tokens, "GitGud  repo", 2.0f) == "GitGud repo :2.00");
    CHECK(HotwordLine(tokens, "Bragi/two", 0).empty());
    CHECK(HotwordLine(tokens, "naive caf\xC3\xA9", 0).empty());
    CHECK(HotwordLine(tokens, "", 0).empty());
}

TEST_CASE("Transcript matching ignores case and punctuation", "[speech]")
{
    CHECK(ContainsPhrase("Hey, BRAGI! what's up", "bragi"));
    CHECK(StartsWithPhrase("Bragi, open the repo.", "Bragi"));
    CHECK(EndsWithPhrase("can you do that, Bragi?", "bragi"));
    CHECK_FALSE(EndsWithPhrase("Bragi can you", "bragi"));
    CHECK(RewriteMishearings("Brockie, look at this", {"Brockie", "brag he"}, "Bragi") ==
          "Bragi, look at this");
    CHECK(RewriteMishearings("I brag he said", {"brag he"}, "Bragi") == "I Bragi said");

    std::string text = "commit it, over and out.";
    CHECK(StripTrailingPhrase(text, "over and out"));
    CHECK(text == "commit it");
    CHECK_FALSE(StripTrailingPhrase(text, "over and out"));

    CHECK(SplitSentences("One. Two? Three!\nFour") ==
          std::vector<std::string>{"One.", "Two?", "Three!", "Four"});
    CHECK(EstimateTokens("12345678") == 2);
}

TEST_CASE("Engine settings come from Lua checked and kept in range", "[speech]")
{
    EngineConfig config;
    std::string error;
    REQUIRE(EngineConfig::FromJson(Json::Parse(R"({"asrThreads": 64, "wakeWord": "Odin",
        "vadThreshold": -3, "hotwords": false, "mishearings": ["oh then"]})")
                                       .value(),
        config, error));
    CHECK(config.m_iAsrThreads == 16);
    CHECK(config.m_WakeWord == "Odin");
    CHECK(config.m_fVadThreshold == 0.05f);
    CHECK_FALSE(config.m_bHotwords);
    CHECK(config.m_Mishearings == std::vector<std::string>{"oh then"});

    EngineConfig other;
    CHECK_FALSE(
        EngineConfig::FromJson(Json::Parse(R"({"asrThreads": "four"})").value(), other, error));
    CHECK(error.find("asrThreads") != std::string::npos);
    CHECK_FALSE(EngineConfig::FromJson(Json::Parse(R"({"endBy": "never"})").value(), other, error));
    CHECK_FALSE(EngineConfig::FromJson(Json::Parse(R"([1])").value(), other, error));
}

#if defined(_WIN32)
TEST_CASE("Files are hashed as they're read", "[speech]")
{
    const fs::path dir = TempDir("sha");
    WriteFile(dir / "abc.txt", "abc");
    CHECK(gitgud::platform::Sha256FileHex((dir / "abc.txt").u8string()) ==
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    CHECK(gitgud::platform::Sha256FileHex((dir / "missing").u8string()).empty());
}

TEST_CASE("A call that hangs marks the engine faulted", "[speech]")
{
    const fs::path dir = TempDir("hang");
    LocalEngine engine((dir / "no-libraries").u8string(), dir.u8string());
    engine.SetMonitorPeriod(10ms);
    std::atomic<bool> bdone{false};
    std::atomic<bool> bresult{true};
    engine.Post(
        [&]()
        {
            bresult = engine.Call("transcribe", 50ms, []() { std::this_thread::sleep_for(400ms); });
            bdone = true;
        });
    REQUIRE(WaitFor([&]() { return engine.State().m_bFaulted; }));
    CHECK(engine.State().m_FaultCode == "engine-hung");
    CHECK(engine.State().m_FaultDetail.find("transcribe") != std::string::npos);
    REQUIRE(WaitFor([&]() { return bdone.load(); }));
    CHECK_FALSE(bresult.load()); // it came back, but too late to count

    // Nothing more runs.
    bool bran = false;
    CHECK_FALSE(engine.Call("detect speech", 1s, [&]() { bran = true; }));
    CHECK_FALSE(bran);

    // A listen link opened now says so at once.
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    std::string error;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    CHECK(received.Closed());
    CHECK(received.Last()["code"].AsString() == "engine-hung");
    CHECK(received.Last()["restart"].AsBool());
}

TEST_CASE("A fault in a call stops the engine; an exception doesn't", "[speech]")
{
    const fs::path dir = TempDir("fault");
    LocalEngine engine((dir / "no-libraries").u8string(), dir.u8string());

    CHECK_FALSE(
        engine.Call("load the recognizer", 1s, []() { throw std::runtime_error("bad model"); }));
    CHECK_FALSE(engine.State().m_bFaulted);
    CHECK(engine.Call("transcribe", 1s, []() {}));

    CHECK_FALSE(engine.Call("transcribe", 1s, []() { NullWrite(); }));
    CHECK(engine.State().m_bFaulted);
    CHECK(engine.State().m_FaultCode == "engine-fault");
    CHECK(engine.State().m_FaultDetail.find("transcribe") != std::string::npos);
    bool bran = false;
    CHECK_FALSE(engine.Call("transcribe", 1s, [&]() { bran = true; }));
    CHECK_FALSE(bran);

    std::ifstream log(dir / "voice-engine.log");
    std::stringstream ss;
    ss << log.rdbuf();
    CHECK(ss.str().find("FAULT engine-fault") != std::string::npos);
}

TEST_CASE("Listening without models set up reports it and closes", "[speech]")
{
    const fs::path dir = TempDir("unconfigured");
    LocalEngine engine((dir / "no-libraries").u8string(), dir.u8string());
    CHECK_FALSE(engine.Installed());
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    REQUIRE(plink);
    Received received;
    std::string error;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000})"));
    REQUIRE(WaitFor([&]() { return received.Closed(); }));
    CHECK(received.Last()["type"].AsString() == "error");
    CHECK(received.Last()["code"].AsString() == "engine-files");
    CHECK(received.m_iClose == 1011);
    CHECK_FALSE(plink->SendText(R"({"type":"wake"})"));
    CHECK_FALSE(engine.State().m_bFaulted);

    std::string setupError;
    CHECK_FALSE(engine.Configure(Json::Parse(R"({"vadModel": "x"})").value(), setupError));
    CHECK_FALSE(engine.Configure(
        Json::Parse(
            R"({"vadModel": "v", "asrDir": "a", "kwsDir": "k", "files": [{"path": "v", "size": 1}]})")
            .value(),
        setupError));
    CHECK(setupError.find("SHA-256") != std::string::npos);
}

TEST_CASE("Model files are checked before they load", "[speech]")
{
    const fs::path dir = TempDir("verify");
    if (!SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("no voice libraries beside the test exe");
    }
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    WriteFile(dir / "vad.onnx", "not a model");
    Json settings = Json::Object();
    settings.Set("vadModel", (dir / "vad.onnx").u8string())
        .Set("asrDir", (dir / "asr").u8string())
        .Set("kwsDir", (dir / "kws").u8string())
        .Set("workDir", (dir / "work").u8string())
        .Set("files", Json::Array().Push(Json::Object()
                              .Set("path", (dir / "vad.onnx").u8string())
                              .Set("size", 11)
                              .Set("sha256", std::string(64, '0'))));
    std::string error;
    REQUIRE(engine.Configure(settings, error));
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0})"));
    REQUIRE(WaitFor([&]() { return received.Closed(); }, 30s));
    CHECK(received.Last()["code"].AsString() == "engine-files");
    CHECK(received.Last()["message"].AsString().find("SHA-256") != std::string::npos);
    CHECK_FALSE(engine.State().m_bFaulted);
}

#if defined(_WIN32)
TEST_CASE("Unpacking reports what it has read, and stops when told", "[speech]")
{
    const fs::path dir = TempDir("unpack");
    // 24 MB that doesn't compress, as a .tar.bz2 (slow to decode, like the
    // models) made by Windows' own tar.
    std::string data(24u << 20, '\0');
    std::mt19937_64 rng(7);
    for (std::size_t ni = 0; ni + 8 <= data.size(); ni += 8)
    {
        const std::uint64_t u = rng();
        std::memcpy(data.data() + ni, &u, 8);
    }
    WriteFile(dir / "src" / "model.bin", data);
    const char* szroot = std::getenv("SystemRoot");
    REQUIRE(szroot != nullptr);
    const std::string tar = (fs::u8path(szroot) / "System32" / "tar.exe").u8string();
    const std::string archive = (dir / "model.tar.bz2").u8string();
    const auto made = gitgud::platform::RunProcess(
        {tar, "-cjf", archive, "-C", (dir / "src").u8string(), "model.bin"}, "");
    REQUIRE(made.m_iExitCode == 0);
    const std::uint64_t usize = fs::file_size(fs::u8path(archive));

    std::vector<std::pair<std::uint64_t, std::uint64_t>> seen;
    std::string error;
    REQUIRE(gitgud::platform::ExtractArchive(archive, (dir / "out").u8string(),
        [&](std::uint64_t _uDone, std::uint64_t _uTotal)
        {
            seen.emplace_back(_uDone, _uTotal);
            return true;
        },
        error));
    CHECK(fs::file_size(dir / "out" / "model.bin") == data.size());
    REQUIRE(seen.size() > 2); // reports while it ran, not just at the end
    CHECK(seen.back().first == usize);
    bool bmonotonic = true;
    for (std::size_t ni = 0; ni < seen.size(); ++ni)
    {
        bmonotonic = bmonotonic && seen[ni].second == usize &&
                     (ni == 0 || seen[ni].first >= seen[ni - 1].first);
    }
    CHECK(bmonotonic);

    // Told to stop at its first report: it stops, and says so.
    int icalls = 0;
    CHECK_FALSE(gitgud::platform::ExtractArchive(archive, (dir / "stopped").u8string(),
        [&](std::uint64_t, std::uint64_t)
        {
            ++icalls;
            return false;
        },
        error));
    CHECK(icalls == 1);
    CHECK(error == "cancelled");
}
#endif

TEST_CASE("A GPU pack never stops listening, and a broken one isn't used", "[speech]")
{
    const fs::path dir = TempDir("gpupack");
    if (!SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("no voice libraries beside the test exe");
    }
    // A pack that arrived after the engine started, from an older layout
    // too (its own ONNX Runtime beside the provider), and broken.
    const fs::path gpu = dir / "gpu";
    WriteFile(gpu / "onnxruntime_providers_cuda.dll", "not a library");
    WriteFile(gpu / "onnxruntime.dll", "not a library either");
    WriteFile(dir / "vad.onnx", "not a model");
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    Json settings = Json::Object();
    settings.Set("vadModel", (dir / "vad.onnx").u8string())
        .Set("asrDir", (dir / "asr").u8string())
        .Set("kwsDir", (dir / "kws").u8string())
        .Set("workDir", (dir / "work").u8string())
        .Set("gpuDir", gpu.u8string())
        .Set("files", Json::Array().Push(Json::Object()
                              .Set("path", (dir / "vad.onnx").u8string())
                              .Set("size", 11)
                              .Set("sha256", std::string(64, '0'))));
    std::string error;
    REQUIRE(engine.Configure(settings, error));

    // Listening loads the app's own libraries whatever the pack: it gets as
    // far as the models (never "engine-missing").
    for (int i = 0; i < 2; ++i)
    {
        std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
        Received received;
        REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
        REQUIRE(plink->SendText(R"({"type":"hello","version":0})"));
        REQUIRE(WaitFor([&]() { return received.Closed(); }, 30s));
        CHECK(received.Last()["code"].AsString() == "engine-files");
    }
    CHECK(SherpaLoaded());
    CHECK(fs::equivalent(fs::u8path(SherpaDir()), fs::u8path(VoiceLibraries())));
#if defined(_WIN32)
    // On the processor nothing of CUDA is touched.
    CHECK(GetModuleHandleW(L"onnxruntime_providers_cuda.dll") == nullptr);
    CHECK(GetModuleHandleW(L"cudart64_13.dll") == nullptr);
    CHECK(GetModuleHandleW(L"cublas64_13.dll") == nullptr);

    // The broken provider doesn't start: the GPU stays off, with the reason.
    // A stand-in that isn't a library is never loaded (Windows would stop
    // the run with a "Bad Image" dialog).
    CHECK_FALSE(EnableCuda(gpu.u8string(), error));
    CHECK(error.find("isn't a library") != std::string::npos);
    CHECK(GetModuleHandleW(L"onnxruntime_providers_cuda.dll") == nullptr);
    CHECK_FALSE(SherpaOnGpu());
    CHECK(CudaEpDevice() == nullptr);
    CHECK_FALSE(EnableCuda((dir / "nothing").u8string(), error));
    CHECK(error.find("aren't in") != std::string::npos);
#endif
    CHECK_FALSE(engine.State().m_bFaulted);
}

TEST_CASE("A call the app closed in is a crash only if it wasn't closing", "[speech]")
{
    const fs::path dir = TempDir("crashmarker");
    const fs::path state = dir / "state";
    fs::create_directories(state);
    auto mark = [&](const char* _szFile, const char* _szCall)
    {
        CrashMarker marker;
        REQUIRE(marker.Open((state / _szFile).u8string()));
        marker.Set(_szCall); // the process "ends" here: never cleared
    };

    // The reply voice was being released while the app closed: not a crash.
    mark("voice-state-speak", "exit: release the speech models");
    {
        LocalEngine engine(VoiceLibraries(), state.u8string());
        CHECK(engine.TakeLastCrash().m_Call.empty());
    }

    // Transcribing (in use) when the app ended: a crash, reported until the
    // user turns voice back on.
    mark("voice-state", "transcribe");
    {
        LocalEngine engine(VoiceLibraries(), state.u8string());
        CHECK(engine.TakeLastCrash().m_Call == "transcribe");
        CHECK(engine.TakeLastCrash().m_Call == "transcribe"); // the same, read once
        engine.ForgetLastCrash();
        CHECK(engine.TakeLastCrash().m_Call.empty());
    }
    // And it was taken: the next start has nothing to say.
    {
        LocalEngine engine(VoiceLibraries(), state.u8string());
        CHECK(engine.TakeLastCrash().m_Call.empty());
    }
}

TEST_CASE("A corrupt model is reported, not a crash", "[speech]")
{
    const fs::path dir = TempDir("corrupt");
    if (!SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("no voice libraries beside the test exe");
    }
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    const std::string garbage(4096, '\x5a');
    WriteFile(dir / "vad.onnx", garbage);
    for (const char* szname : {"encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"})
    {
        WriteFile(dir / "asr" / szname, garbage);
    }
    WriteFile(dir / "asr" / "tokens.txt", "<blk> 0\na 1\nb 2\n");
    Json settings = Json::Object();
    settings.Set("vadModel", (dir / "vad.onnx").u8string())
        .Set("asrDir", (dir / "asr").u8string())
        .Set("kwsDir", (dir / "kws").u8string())
        .Set("workDir", (dir / "work").u8string());
    std::string error;
    REQUIRE(engine.Configure(settings, error));
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0})"));
    REQUIRE(WaitFor([&]() { return received.Closed(); }, 60s));
    CHECK(received.Last()["code"].AsString() == "engine-files");
    CHECK_FALSE(engine.State().m_bFaulted);
    CHECK_FALSE(engine.State().m_bLoaded);
}
#endif

#if defined(_WIN32)
TEST_CASE("Replies are spoken with the system's voices", "[speech]")
{
    const fs::path dir = TempDir("speak");
    LocalEngine engine((dir / "no-libraries").u8string(), dir.u8string());
    std::string error;
    const std::vector<VoiceInfo> voices = engine.Voices(error);
    if (voices.empty())
    {
        SKIP("no system voices: " + error);
    }
    CHECK_FALSE(voices.front().m_Id.empty());

    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("speak");
    REQUIRE(plink);
    std::mutex mutex;
    std::vector<std::string> types;
    std::size_t nbytes = 0;
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
                types.push_back(Json::Parse(_Data).value_or(Json())["type"].AsString());
            }
        },
        [](int, const std::string&) {}, error));
    REQUIRE(plink->SendText(R"({"type":"say","id":"r1","text":"Hello. This is a test."})"));
    REQUIRE(WaitFor(
        [&]()
        {
            std::lock_guard<std::mutex> lock(mutex);
            return !types.empty() && (types.back() == "end" || types.back() == "error");
        },
        30s));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(types == std::vector<std::string>{"start", "end"});
        CHECK(nbytes > 24000); // over half a second of speech
    }
    // A say for an unknown voice fails on its own.
    REQUIRE(plink->SendText(R"({"type":"say","id":"r2","text":"Hi.","voice":"no such voice"})"));
    REQUIRE(WaitFor(
        [&]()
        {
            std::lock_guard<std::mutex> lock(mutex);
            return types.size() >= 4;
        },
        30s));
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(types[2] == "start");
        CHECK(types[3] == "error");
    }
    plink->Close();
}
#endif

// Hidden: needs the real models (GITGUD_TEST_VOICE_MODELS) and the libraries.
TEST_CASE("The real models load, transcribe, and spot", "[.voice-models]")
{
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    if (!szmodels || !SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("set GITGUD_TEST_VOICE_MODELS, with the voice libraries beside the test exe");
    }
    const fs::path models = fs::u8path(szmodels);
    const fs::path dir = TempDir("models");
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    Json settings = Json::Object();
    settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
        .Set("asrDir",
            (models / "parakeet" / "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8")
                .u8string())
        .Set("kwsDir",
            (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01").u8string())
        .Set("speakerModel", (models / "speaker" / "nemo_en_titanet_large.onnx").u8string())
        .Set("workDir", (dir / "work").u8string());
    std::string error;
    REQUIRE(engine.Configure(settings, error));

    std::mutex mutex;
    std::condition_variable wake;
    std::optional<Json> result;
    engine.SelfTest(
        (models / "parakeet" / "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8" /
            "test_wavs" / "0.wav")
            .u8string(),
        [&](const Json& _Result)
        {
            std::lock_guard<std::mutex> lock(mutex);
            result = _Result;
            wake.notify_all();
        });
    std::unique_lock<std::mutex> lock(mutex);
    REQUIRE(wake.wait_for(lock, 120s, [&]() { return result.has_value(); }));
    INFO(result->Dump());
    CHECK(result->operator[]("ok").AsBool());
    CHECK_FALSE(result->operator[]("text").AsString().empty());
    CHECK(result->operator[]("keywords").AsBool());
    CHECK(result->operator[]("speaker").AsBool());
    CHECK_FALSE(engine.State().m_bLoaded); // released again: nothing listens
    lock.unlock();

    // Listening: hello, a message the app starts, the clip as mic frames,
    // then the app ends it.
    std::ifstream wav(models / "parakeet" /
                          "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8" /
                          "test_wavs" / "0.wav",
        std::ios::binary);
    std::stringstream ss;
    ss << wav.rdbuf();
    std::string pcm = ss.str().substr(44); // 16 kHz mono 16-bit after the header
    pcm.append(16000 * 2 * 2, '\0');       // two seconds of quiet after it
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000,"endBy":"app"})"));
    REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "ready"; }, 60s));
    CHECK(received.Last()["keywords"].AsBool());
    REQUIRE(plink->SendText(R"({"type":"wake"})"));
    for (std::size_t nat = 0; nat < pcm.size(); nat += 640)
    {
        REQUIRE(plink->SendBinary(pcm.data() + nat, std::min<std::size_t>(640, pcm.size() - nat)));
    }
    REQUIRE(plink->SendText(R"({"type":"send","reason":"button"})"));
    REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "message"; }, 60s));
    INFO(received.Last().Dump());
    CHECK(received.Last()["text"].AsString().find("wish") != std::string::npos);
    CHECK(received.Last()["endedBy"].AsString() == "send");
    plink->Close();
    REQUIRE(WaitFor([&]() { return !engine.State().m_bLoaded; }, 30s));

    // Releasing the models while listening ends the listening first.
    plink = engine.MakeLink("listen");
    Received second;
    REQUIRE(plink->Open(second.OnMessage(), second.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0})"));
    REQUIRE(WaitFor([&]() { return second.Last()["type"].AsString() == "ready"; }, 60s));
    REQUIRE(plink->SendBinary(pcm.data(), 640));
    engine.ReleaseModels(30s);
    CHECK(second.Closed());
    CHECK(second.Last()["code"].AsString() == "engine-files");
    CHECK_FALSE(engine.State().m_bLoaded);
    CHECK_FALSE(engine.State().m_bFaulted);
    CHECK_FALSE(plink->SendBinary(pcm.data(), 640));
}

// Hidden: wake word training and voice enrollment on the real models
// (GITGUD_TEST_VOICE_MODELS), as Settings' Voice training runs them: the
// spotter scores every utterance and Stop suggests mishearings and a
// threshold; enrollment averages the speaker model's embeddings into a
// voiceprint kept on this computer, which hello then reports, and Forget
// deletes.
TEST_CASE("Wake word training and voice enrollment run on the real models", "[.voice-models]")
{
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    if (!szmodels || !SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("set GITGUD_TEST_VOICE_MODELS, with the voice libraries beside the test exe");
    }
    const fs::path models = fs::u8path(szmodels);
    const fs::path asr =
        models / "parakeet" / "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8";
    const fs::path dir = TempDir("training");
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    Json settings = Json::Object();
    settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
        .Set("asrDir", asr.u8string())
        .Set("kwsDir",
            (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01").u8string())
        .Set("speakerModel", (models / "speaker" / "nemo_en_titanet_large.onnx").u8string())
        .Set("voiceprintsDir", (dir / "voiceprints").u8string())
        .Set("workDir", (dir / "work").u8string())
        .Set("enrollMinSeconds", 1);
    std::string error;
    REQUIRE(engine.Configure(settings, error));

    std::ifstream wav(asr / "test_wavs" / "0.wav", std::ios::binary);
    std::stringstream ss;
    ss << wav.rdbuf();
    std::string pcm = ss.str().substr(44);
    pcm.append(16000 * 2 * 2, '\0'); // two seconds of quiet: the utterance ends
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000})"));
    REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "ready"; }, 60s));
    CHECK_FALSE(received.Last()["speaker"]["enrolled"].AsBool());
    auto speak = [&]()
    {
        for (std::size_t nat = 0; nat < pcm.size(); nat += 640)
        {
            REQUIRE(plink->SendBinary(pcm.data() + nat, std::min<std::size_t>(640, pcm.size() - nat)));
        }
    };

    // Training: the utterance comes back as a sample, Stop sums it up.
    REQUIRE(plink->SendText(R"({"type":"train","state":"start"})"));
    speak();
    REQUIRE(WaitFor([&]() { return !received.LastOf("trainSample").IsNull(); }, 60s));
    const Json sample = received.LastOf("trainSample");
    INFO(sample.Dump());
    CHECK(sample["n"].AsInt() == 1);
    CHECK(sample["text"].AsString().find("wish") != std::string::npos);
    CHECK(sample["score"].IsNumber());
    CHECK(received.LastOf("message").IsNull()); // training never starts a message
    REQUIRE(plink->SendText(R"({"type":"train","state":"stop"})"));
    REQUIRE(WaitFor([&]() { return !received.LastOf("trainResult").IsNull(); }, 30s));
    const Json trained = received.LastOf("trainResult");
    INFO(trained.Dump());
    // The clip holds two sentences: two samples, each heard as a mishearing.
    CHECK(trained["samples"].AsInt() >= 1);
    CHECK(static_cast<int>(trained["mishearings"].Items().size()) == trained["samples"].AsInt());
    CHECK(trained["threshold"].IsNumber());

    // Enrollment: the voiceprint is made and kept on this computer.
    REQUIRE(plink->SendText(R"({"type":"enroll","state":"start"})"));
    speak();
    REQUIRE(WaitFor([&]() { return !received.LastOf("enrollSample").IsNull(); }, 60s));
    CHECK(received.LastOf("enrollSample")["seconds"].AsNumber() > 1.0);
    REQUIRE(plink->SendText(R"({"type":"enroll","state":"stop"})"));
    REQUIRE(WaitFor([&]() { return !received.LastOf("enrollResult").IsNull(); }, 30s));
    INFO(received.LastOf("enrollResult").Dump());
    CHECK(received.LastOf("enrollResult")["enrolled"].AsBool());
    CHECK(fs::exists(dir / "voiceprints" / "voiceprint.json"));
    plink->Close();
    REQUIRE(WaitFor([&]() { return !engine.State().m_bLoaded; }, 30s));

    // A new session knows the voice; its own utterance scores as the user.
    plink = engine.MakeLink("listen");
    Received again;
    REQUIRE(plink->Open(again.OnMessage(), again.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000,"endBy":"app"})"));
    REQUIRE(WaitFor([&]() { return again.Last()["type"].AsString() == "ready"; }, 60s));
    CHECK(again.Last()["speaker"]["enrolled"].AsBool());
    REQUIRE(plink->SendText(R"({"type":"wake"})"));
    for (std::size_t nat = 0; nat < pcm.size(); nat += 640)
    {
        REQUIRE(plink->SendBinary(pcm.data() + nat, std::min<std::size_t>(640, pcm.size() - nat)));
    }
    REQUIRE(plink->SendText(R"({"type":"send","reason":"button"})"));
    REQUIRE(WaitFor([&]() { return !again.LastOf("message").IsNull(); }, 60s));
    INFO(again.LastOf("message").Dump());
    CHECK(again.LastOf("message")["speaker"].AsString() == "user");

    // Forget: the voiceprint is deleted.
    REQUIRE(plink->SendText(R"({"type":"enroll","state":"clear"})"));
    REQUIRE(WaitFor([&]() { return !again.LastOf("enrollResult").IsNull(); }, 30s));
    CHECK_FALSE(again.LastOf("enrollResult")["enrolled"].AsBool());
    CHECK_FALSE(fs::exists(dir / "voiceprints" / "voiceprint.json"));
    plink->Close();
}

// Hidden: recordings said to the engine in real time, as a message the app
// started and ended with Send, in each transcribe mode, for comparing what
// each hears and how far behind it falls. GITGUD_TEST_VOICE_MODELS, plus
// GITGUD_TEST_REPLAY_LIST (a file of 16 kHz mono 16-bit WAV paths, one a
// line) and GITGUD_TEST_REPLAY_OUT (a file it writes: a JSON line a
// recording and mode). GITGUD_TEST_REPLAY_MODES limits the modes
// ("utterances,growing").
TEST_CASE("Recordings replayed in each transcribe mode", "[.voice-replay]")
{
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    const char* szlist = std::getenv("GITGUD_TEST_REPLAY_LIST");
    const char* szout = std::getenv("GITGUD_TEST_REPLAY_OUT");
    if (!szmodels || !szlist || !szout || !SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("set GITGUD_TEST_VOICE_MODELS, GITGUD_TEST_REPLAY_LIST and GITGUD_TEST_REPLAY_OUT, "
             "with the voice libraries beside the test exe");
    }
    const fs::path models = fs::u8path(szmodels);
    std::vector<std::string> paths;
    {
        std::ifstream list(fs::u8path(szlist));
        std::string line;
        while (std::getline(list, line))
        {
            while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
            {
                line.pop_back();
            }
            if (!line.empty())
            {
                paths.push_back(line);
            }
        }
    }
    REQUIRE(!paths.empty());
    std::vector<std::string> modes = {"utterances", "growing"};
    if (const char* szmodes = std::getenv("GITGUD_TEST_REPLAY_MODES"))
    {
        modes.clear();
        std::stringstream ss(szmodes);
        std::string mode;
        while (std::getline(ss, mode, ','))
        {
            modes.push_back(mode);
        }
    }
    // The samples of a WAV's data chunk; none for any other format than
    // 16 kHz mono 16-bit (other audio would play at the wrong speed).
    auto read = [](const std::string& _Path)
    {
        std::ifstream wav(fs::u8path(_Path), std::ios::binary);
        std::stringstream ss;
        ss << wav.rdbuf();
        const std::string all = ss.str();
        auto u32 = [&](std::size_t _nAt)
        {
            return static_cast<std::uint32_t>(static_cast<unsigned char>(all[_nAt])) |
                   (static_cast<std::uint32_t>(static_cast<unsigned char>(all[_nAt + 1])) << 8) |
                   (static_cast<std::uint32_t>(static_cast<unsigned char>(all[_nAt + 2])) << 16) |
                   (static_cast<std::uint32_t>(static_cast<unsigned char>(all[_nAt + 3])) << 24);
        };
        bool bformat = false;
        std::size_t nat = 12;
        while (nat + 8 <= all.size())
        {
            const std::string id = all.substr(nat, 4);
            const std::uint32_t nsize = u32(nat + 4);
            if (id == "fmt " && nat + 24 <= all.size())
            {
                const unsigned nchannels = static_cast<unsigned char>(all[nat + 10]);
                const unsigned nbits = static_cast<unsigned char>(all[nat + 22]);
                bformat = nchannels == 1 && u32(nat + 12) == 16000 && nbits == 16;
            }
            if (id == "data")
            {
                if (!bformat)
                {
                    WARN(_Path << " isn't 16 kHz mono 16-bit; skipped");
                    return std::string();
                }
                return all.substr(nat + 8, std::min<std::size_t>(nsize, all.size() - nat - 8));
            }
            nat += 8 + nsize + (nsize & 1);
        }
        return std::string();
    };
    // Recordings already in the file are skipped: a run stopped part way
    // goes on where it was.
    std::set<std::pair<std::string, std::string>> done;
    {
        std::ifstream in(fs::u8path(szout), std::ios::binary);
        std::string line;
        while (std::getline(in, line))
        {
            const Json row = Json::Parse(line).value_or(Json());
            if (!row["path"].IsNull())
            {
                done.emplace(row["mode"].AsString(), row["path"].AsString());
            }
        }
    }
    std::ofstream out(fs::u8path(szout), std::ios::binary | std::ios::app);
    const fs::path dir = TempDir("replay");
    for (const std::string& mode : modes)
    {
        LocalEngine engine(VoiceLibraries(), (dir / ("state-" + mode)).u8string());
        Json settings = Json::Object();
        settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
            .Set("asrDir", (models / "parakeet" /
                               "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8")
                               .u8string())
            .Set("kwsDir", (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
                               .u8string())
            .Set("workDir", (dir / "work").u8string())
            .Set("transcribe", mode)
            .Set("asrMaxSeconds", 30);
        // GITGUD_TEST_REPLAY_SETTINGS: more engine settings, as JSON.
        if (const char* szmore = std::getenv("GITGUD_TEST_REPLAY_SETTINGS"))
        {
            const Json more = Json::Parse(szmore).value_or(Json());
            for (const std::string& key : more.Keys())
            {
                settings.Set(key, more[key]);
            }
        }
        std::string error;
        REQUIRE(engine.Configure(settings, error));
        for (const std::string& path : paths)
        {
            if (done.count({mode, path}) > 0)
            {
                continue;
            }
            std::string pcm = read(path);
            if (pcm.empty())
            {
                continue;
            }
            const double fseconds = static_cast<double>(pcm.size()) / 32000.0;
            pcm.append(16000 * 2, '\0'); // a second of quiet before Send
            std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
            Received received;
            REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
            REQUIRE(plink->SendText(
                R"({"type":"hello","version":0,"sampleRate":16000,"endBy":"app"})"));
            REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "ready"; }, 120s));
            REQUIRE(plink->SendText(R"({"type":"wake"})"));
            // 20 ms frames on the clock; how far behind it a send returns
            // is how far the engine fell behind.
            const auto start = std::chrono::steady_clock::now();
            double flagMax = 0;
            for (std::size_t nat = 0; nat < pcm.size(); nat += 640)
            {
                const auto due = start + std::chrono::microseconds(
                                             static_cast<long long>(nat) * 1000000 / 32000);
                std::this_thread::sleep_until(due);
                REQUIRE(plink->SendBinary(
                    pcm.data() + nat, std::min<std::size_t>(640, pcm.size() - nat)));
                flagMax = std::max(flagMax, std::chrono::duration<double, std::milli>(
                                                std::chrono::steady_clock::now() - due)
                                                .count());
            }
            const auto sent = std::chrono::steady_clock::now();
            REQUIRE(plink->SendText(R"({"type":"send","reason":"button"})"));
            REQUIRE(WaitFor([&]() { return !received.LastOf("message").IsNull(); }, 300s));
            const double fendMs =
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - sent)
                    .count();
            const Json message = received.LastOf("message");
            int ipartials = 0;
            {
                std::lock_guard<std::mutex> lock(received.m_Mutex);
                for (const std::string& textLine : received.m_Texts)
                {
                    if (Json::Parse(textLine).value_or(Json())["type"].AsString() == "partial")
                    {
                        ++ipartials;
                    }
                }
            }
            Json row = Json::Object();
            row.Set("mode", mode)
                .Set("path", path)
                .Set("seconds", fseconds)
                .Set("text", message["text"].AsString())
                .Set("live", message["live"].AsString())
                .Set("finalOk", message["finalOk"].IsNull() ? true : message["finalOk"].AsBool())
                .Set("partials", ipartials)
                .Set("lagMaxMs", flagMax)
                .Set("endMs", fendMs);
            out << row.Dump() << "\n";
            out.flush();
            plink->Close();
        }
        // The engine's log, after any from a run before.
        std::ifstream log(dir / ("state-" + mode) / "voice-engine.log", std::ios::binary);
        std::ofstream logs(fs::u8path(szout).replace_extension("." + mode + ".log"),
            std::ios::binary | std::ios::app);
        logs << log.rdbuf();
    }
}

// Hidden: the turn-taking classifier against the reference answers its
// training tools give (GITGUD_TEST_DECIDER: a folder with model.int8.onnx,
// vocab.txt, and expected.json: WordPiece ids for some texts, and the
// outputs for some inputs), on the real listening models
// (GITGUD_TEST_VOICE_MODELS). `decide` fills in "{pause}" itself.
TEST_CASE("The turn-taking model answers as its reference does", "[.voice-decider]")
{
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    const char* szdecider = std::getenv("GITGUD_TEST_DECIDER");
    if (!szmodels || !szdecider || !SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("set GITGUD_TEST_VOICE_MODELS and GITGUD_TEST_DECIDER, with the voice libraries "
             "beside the test exe");
    }
    const fs::path models = fs::u8path(szmodels);
    const fs::path decider = fs::u8path(szdecider);
    auto read = [](const fs::path& _Path)
    {
        std::ifstream in(_Path, std::ios::binary);
        std::stringstream ss;
        ss << in.rdbuf();
        return ss.str();
    };
    const Json expected = Json::Parse(read(decider / "expected.json")).value_or(Json());
    REQUIRE(expected.IsObject());

    WordPiece tokenizer;
    std::string error;
    REQUIRE(tokenizer.Load(read(decider / "vocab.txt"), error));
    for (const Json& item : expected["ids"].Items())
    {
        INFO(item["text"].AsString());
        const std::vector<int64_t> ids = tokenizer.Encode(item["text"].AsString());
        std::vector<int64_t> want;
        for (const Json& id : item["ids"].Items())
        {
            want.push_back(id.AsInt());
        }
        CHECK(ids == want);
    }

    const fs::path dir = TempDir("decider");
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    Json settings = Json::Object();
    settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
        .Set("asrDir",
            (models / "parakeet" / "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8")
                .u8string())
        .Set("kwsDir",
            (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01").u8string())
        .Set("deciderModel", (decider / "model.int8.onnx").u8string())
        .Set("deciderVocab", (decider / "vocab.txt").u8string())
        .Set("workDir", (dir / "work").u8string());
    REQUIRE(engine.Configure(settings, error));
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000,"endBy":"app"})"));
    REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "ready"; }, 60s));
    INFO(received.Last().Dump());
    REQUIRE(received.Last()["decider"].AsBool());

    int iid = 0;
    for (const Json& item : expected["cases"].Items())
    {
        // The pause as the reference had it (no speech has been heard, so
        // the engine's own "{pause}" would be 0.0).
        std::string second = item["second"].AsString();
        char szpause[16];
        std::snprintf(szpause, sizeof(szpause), "%.1f", item["pause"].AsNumber());
        second.replace(second.find("{pause}"), 7, szpause);
        const std::string id = "d" + std::to_string(++iid);
        Json request = Json::Object();
        request.Set("type", "decide")
            .Set("id", id)
            .Set("first", item["first"].AsString())
            .Set("second", second)
            .Set("maxLength", expected["maxLength"].AsNumber())
            .Set("firstMax", expected["firstMax"].AsNumber());
        REQUIRE(plink->SendText(request.Dump()));
        REQUIRE(WaitFor([&]() { return received.LastOf("decision")["id"].AsString() == id; }, 10s));
        const Json reply = received.LastOf("decision");
        INFO(item["second"].AsString() << "\n" << reply.Dump());
        REQUIRE(reply["error"].IsNull());
        CHECK(reply["tokens"].AsInt() == item["tokens"].AsInt());
        for (const std::string& name : item["outputs"].Keys())
        {
            const Json& want = item["outputs"][name];
            const Json& got = reply["outputs"][name];
            REQUIRE(got.Size() == want.Size());
            // Quantized graphs round differently in other ONNX Runtime
            // versions and with other graph fusions (about 0.01 to 0.02).
            for (std::size_t ni = 0; ni < want.Size(); ++ni)
            {
                CHECK(std::abs(got[ni].AsNumber() - want[ni].AsNumber()) < 0.03);
            }
        }
    }

    // "{pause}": nothing heard yet, so no pause.
    REQUIRE(plink->SendText(
        R"({"type":"decide","id":"p","first":"x","second":"message: hello | pause: {pause} s"})"));
    REQUIRE(WaitFor([&]() { return received.LastOf("decision")["id"].AsString() == "p"; }, 10s));
    CHECK(received.LastOf("decision")["pause"].AsNumber() == 0.0);
    plink->Close();
    REQUIRE(WaitFor([&]() { return !engine.State().m_bLoaded; }, 30s));
}
