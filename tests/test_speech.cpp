// The speech engine inside the app (src/speech): its guards, its input
// checks, and its links. Nothing here needs the models; one test needs the
// voice libraries beside the test exe (skipped without them), and the
// real-model smoke test is hidden ([.voice-models]): run it with
// GITGUD_TEST_VOICE_MODELS set to a folder with vad/, kws/, parakeet/, and
// speaker/ as the Bragi interface installs them.

#include <catch2/catch_test_macros.hpp>

#include "app/Json.h"
#include "platform/Http.h"
#include "platform/Process.h"
#include "platform/Shell.h"
#include "speech/Guard.h"
#include "speech/LocalEngine.h"
#include "speech/Recognizer.h"
#include "speech/SherpaApi.h"
#include "speech/Text.h"

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <random>
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
            (models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8").u8string())
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
        (models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8" / "test_wavs" / "0.wav")
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
    std::ifstream wav(
        models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8" / "test_wavs" / "0.wav",
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
    const fs::path asr = models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
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

// Hidden: its own reply heard back while it plays never joins a message
// (GITGUD_TEST_VOICE_MODELS). The clip is said once as the user's message
// (started by the app), then again while a reply with the same words plays:
// the second time it's dropped.
TEST_CASE("The reply's own words heard during playback are dropped", "[.voice-models]")
{
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    if (!szmodels || !SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("set GITGUD_TEST_VOICE_MODELS, with the voice libraries beside the test exe");
    }
    const fs::path models = fs::u8path(szmodels);
    const fs::path asr = models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
    const fs::path dir = TempDir("echo");
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    Json settings = Json::Object();
    settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
        .Set("asrDir", asr.u8string())
        .Set("kwsDir",
            (models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01").u8string())
        .Set("speakerModel", (models / "speaker" / "nemo_en_titanet_large.onnx").u8string())
        .Set("workDir", (dir / "work").u8string());
    std::string error;
    REQUIRE(engine.Configure(settings, error));
    std::ifstream wav(asr / "test_wavs" / "0.wav", std::ios::binary);
    std::stringstream ss;
    ss << wav.rdbuf();
    std::string pcm = ss.str().substr(44);
    pcm.append(16000 * 2 * 2, '\0');
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000,"endBy":"app"})"));
    REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "ready"; }, 60s));
    auto speak = [&]()
    {
        for (std::size_t nat = 0; nat < pcm.size(); nat += 640)
        {
            REQUIRE(plink->SendBinary(pcm.data() + nat, std::min<std::size_t>(640, pcm.size() - nat)));
        }
    };
    REQUIRE(plink->SendText(R"({"type":"wake"})"));
    speak(); // the user's words
    REQUIRE(WaitFor([&]() { return !received.LastOf("partial").IsNull(); }, 60s));
    // A reply saying the same words starts playing, and the mic hears it.
    REQUIRE(plink->SendText(
        R"({"type":"playback","state":"started","id":"r1","text":"Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. It is certainly very like the old portrait."})"));
    speak();
    REQUIRE(plink->SendText(R"({"type":"playback","state":"stopped","id":"r1"})"));
    REQUIRE(plink->SendText(R"({"type":"send","reason":"button"})"));
    REQUIRE(WaitFor([&]() { return !received.LastOf("message").IsNull(); }, 60s));
    const std::string text = received.LastOf("message")["text"].AsString();
    INFO(text);
    // The words once, not twice.
    const std::size_t nfirst = text.find("portrait");
    CHECK(nfirst != std::string::npos);
    CHECK(text.find("portrait", nfirst + 1) == std::string::npos);
    plink->Close();
}

// Hidden: once the user's voice is enrolled, someone else's utterance in the
// middle of their message stays out of it (GITGUD_TEST_VOICE_MODELS; the
// keyword spotter's test clip is another speaker).
TEST_CASE("Someone else's words stay out of the enrolled user's message", "[.voice-models]")
{
    const char* szmodels = std::getenv("GITGUD_TEST_VOICE_MODELS");
    if (!szmodels || !SherpaFilesPresent(VoiceLibraries()))
    {
        SKIP("set GITGUD_TEST_VOICE_MODELS, with the voice libraries beside the test exe");
    }
    const fs::path models = fs::u8path(szmodels);
    const fs::path asr = models / "parakeet" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
    const fs::path kws = models / "kws" / "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01";
    const fs::path dir = TempDir("other");
    LocalEngine engine(VoiceLibraries(), (dir / "state").u8string());
    Json settings = Json::Object();
    settings.Set("vadModel", (models / "vad" / "silero_vad.onnx").u8string())
        .Set("asrDir", asr.u8string())
        .Set("kwsDir", kws.u8string())
        .Set("speakerModel", (models / "speaker" / "nemo_en_titanet_large.onnx").u8string())
        .Set("voiceprintsDir", (dir / "voiceprints").u8string())
        .Set("workDir", (dir / "work").u8string())
        .Set("enrollMinSeconds", 1);
    std::string error;
    REQUIRE(engine.Configure(settings, error));
    auto read = [](const fs::path& _Path)
    {
        std::ifstream wav(_Path, std::ios::binary);
        std::stringstream ss;
        ss << wav.rdbuf();
        std::string pcm = ss.str().substr(44);
        pcm.append(16000 * 2 * 2, '\0');
        return pcm;
    };
    const std::string user = read(asr / "test_wavs" / "0.wav");
    const std::string other = read(kws / "test_wavs" / "1.wav");
    std::unique_ptr<gitgud::voice::ILink> plink = engine.MakeLink("listen");
    Received received;
    REQUIRE(plink->Open(received.OnMessage(), received.OnClose(), error));
    REQUIRE(plink->SendText(R"({"type":"hello","version":0,"sampleRate":16000,"endBy":"app"})"));
    REQUIRE(WaitFor([&]() { return received.Last()["type"].AsString() == "ready"; }, 60s));
    auto say = [&](const std::string& _Pcm)
    {
        for (std::size_t nat = 0; nat < _Pcm.size(); nat += 640)
        {
            REQUIRE(plink->SendBinary(_Pcm.data() + nat, std::min<std::size_t>(640, _Pcm.size() - nat)));
        }
    };
    // Enrolled as the first speaker.
    REQUIRE(plink->SendText(R"({"type":"enroll","state":"start"})"));
    say(user);
    REQUIRE(WaitFor([&]() { return !received.LastOf("enrollSample").IsNull(); }, 60s));
    REQUIRE(plink->SendText(R"({"type":"enroll","state":"stop"})"));
    REQUIRE(WaitFor([&]() { return !received.LastOf("enrollResult").IsNull(); }, 30s));
    REQUIRE(received.LastOf("enrollResult")["enrolled"].AsBool());

    // A message: the user, then someone else.
    REQUIRE(plink->SendText(R"({"type":"wake"})"));
    say(user);
    say(other);
    REQUIRE(plink->SendText(R"({"type":"send","reason":"button"})"));
    REQUIRE(WaitFor([&]() { return !received.LastOf("message").IsNull(); }, 120s));
    const Json message = received.LastOf("message");
    INFO(message.Dump());
    const std::string text = message["text"].AsString();
    CHECK(text.find("portrait") != std::string::npos);
    CHECK(text.find("consequence") == std::string::npos);
    CHECK(text.find("heaven") == std::string::npos);
    CHECK(message["speaker"].AsString() == "user");
    plink->Close();
}
