#pragma once

// -----------------------------------------------------------------------------
// LocalEngine: the speech engine inside the app, behind the voice links
// (voice/Link.h). The listen channel runs the Listener (speech/Listener.h)
// on the models; the speak channel speaks with a small built-in voice
// (speech/SmallVoice.h, Configure's `small`: phonemes in, from Lua), with
// Chatterbox Turbo (speech/Turbo.h) in a voice made from a recording, when
// its models are set up (Configure's `tts`), else with the system's voices
// (speech/TextToSpeech.h).
//
// One ONNX Runtime serves both: the CPU build in the `voice` folder beside
// the exe, or the GPU runtime (the voice pack: sherpa-onnx's CUDA build
// with NVIDIA's CUDA and cuDNN libraries) from Configure's `runtimeDir`.
// Which one loads is decided once per process.
//
// Its libraries (sherpa-onnx and ONNX Runtime, in the `voice` folder beside
// the exe) load the first time the models do: when the Bragi interface turns
// voice on. Nothing here runs or loads for an interface without voice.
//
// Guards, because the libraries run in the app's process:
// - Two engine threads make every call into them: one for listening, one
//   for speaking (Turbo), each owning its handles, each with its own
//   watchdog and crash marker ("voice-state", "voice-state-speak"). A
//   fault on either stops both.
// - Every call goes through Call(): exceptions are caught (a failed decode
//   drops that utterance; three in a row stop listening), and a structured
//   exception (an access violation) marks the engine faulted: no further
//   calls, not even to release, until the app restarts.
// - A watchdog thread gives each call a time limit; a call past it marks
//   the engine faulted the same way (the thread is left to it).
// - Model files are checked against the sizes and SHA-256 sums Lua gives
//   (Configure) before they load; a check is remembered by size and time.
// - Before each call its name goes into a small file (the crash marker), and
//   is cleared after. If the process dies inside a call, the next start
//   finds the name there (TakeLastCrash) and Lua can say what happened.
// - The engine log (voice-engine.log beside the marker) gets every load,
//   fault, and utterance timing; when the app has no console, the
//   libraries' own messages (stderr) go there too.
// -----------------------------------------------------------------------------

#include "app/Json.h"
#include "speech/Guard.h"
#include "speech/Recognizer.h"
#include "speech/TextToSpeech.h"
#include "voice/Link.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace gitgud::speech
{

    struct EngineState
    {
        bool m_bInstalled = false;  // the libraries are there (nothing loaded)
        bool m_bConfigured = false; // Configure() was given the models
        bool m_bLoaded = false;     // the models are in memory
        bool m_bFaulted = false;    // no more calls until the app restarts
        std::string m_FaultCode;    // "engine-fault" or "engine-hung"
        std::string m_FaultDetail;
        std::string m_TurboDevice; // "gpu" or "cpu" once Turbo loaded, else ""
        std::string m_GpuError;    // why Turbo isn't on the GPU it was asked to use
    };

    // What the crash marker held at start: the call the app was in when it
    // ended last time ("" if none), and the end of the engine log then.
    struct LastCrash
    {
        std::string m_Call;
        std::string m_LogTail;
    };

    class LocalEngine
    {
      public:
        // `_LibraryDir`: the folder with onnxruntime.dll and
        // sherpa-onnx-c-api.dll. `_StateDir`: where the crash marker
        // ("voice-state") and the log ("voice-engine.log") go.
        LocalEngine(std::string _LibraryDir, std::string _StateDir);
        ~LocalEngine();
        LocalEngine(const LocalEngine&) = delete;
        LocalEngine& operator=(const LocalEngine&) = delete;

        // The app's engine: <exe folder>/voice, <settings folder>/bragi.
        static LocalEngine& Instance();

        // The library files are there (only checks the files).
        bool Installed() const;

        // The models and settings: EngineConfig's fields (Recognizer.h) plus
        // `files`, [{path, size, sha256}], each checked before loading. Takes
        // effect at the next load (models load when listening starts and
        // unload when it stops). Also:
        //   gpuDir      the GPU pack's folder: with its provider there and
        //               tts.provider "cuda", Turbo loads (again) on the GPU,
        //               in the same run; if the GPU doesn't start, on the
        //               processor (State().m_GpuError says why)
        //   tts         Turbo: {dir, encoder, embed, lm, decoder, tokenizer,
        //               voicesDir, provider, threads, cpuThreads, files};
        //               absent: system voices only
        //   small       small voices: {voicesDir, threads}: "small:<name>" is
        //               <voicesDir>/<name> (model.onnx, phonemes.tsv), and its
        //               `say` text is phonemes; absent: none
        bool Configure(const app::Json& _Settings, std::string& _Error);

        // Turbo is set up (Configure's `tts`), not necessarily loaded.
        bool TurboConfigured() const;
        // Small voices are set up (Configure's `small`).
        bool SmallConfigured() const;
        // Say `_Phonemes` with small voice `_Name` (speaking thread; it loads
        // the first time). 24 kHz audio, or false with `_Error`.
        bool SmallSay(const std::string& _Phonemes, const std::string& _Name, double _fSpeed,
            double _fWobble, std::vector<float>& _Audio, std::string& _Error);
        // The voice a `say` without one uses when Turbo is set up:
        // "turbo:baldr" when Baldr is made, else the first made voice; ""
        // when none is.
        std::string DefaultMadeVoice() const;
        // Make a voice from a recording (a WAV file): its conditioning saved
        // as <voicesDir>/<_Name>.voice. `_Done` gets {ok, seconds?, code?,
        // message?} on the speaking thread.
        void MakeVoice(const std::string& _Wav, const std::string& _Name,
            std::function<void(const app::Json&)> _Done);
        // Say `_Sentence` with Turbo in voice `_Name` (speaking thread). False
        // with `_Error`. `_Stopped` is asked between tokens.
        bool TurboSay(const std::string& _Sentence, const std::string& _Name, double _fSpeed,
            const std::function<bool()>& _Stopped, std::vector<float>& _Audio, std::string& _Error);
        // Run `_Task` on the speaking thread.
        void PostSpeak(std::function<void()> _Task);
        // Load Turbo now, in the background (the speak channel opened); then
        // `_Done` on the speaking thread, if given.
        void WarmTurbo(std::function<void()> _Done = nullptr);

        // A link for "listen" or "speak" (voice::LinkFactory).
        std::unique_ptr<voice::ILink> MakeLink(const std::string& _Channel);

        EngineState State() const;
        // Read once; later calls return the same, until ForgetLastCrash. A
        // call the app was in while it was closing (PrepareForExit) isn't a
        // crash: it's only logged.
        LastCrash TakeLastCrash();
        // The user turned voice back on: the last crash isn't reported again.
        void ForgetLastCrash();

        // The app is closing: release the models now, while everything they
        // use is still loaded (waits up to `_Wait`), and from here on mark
        // every call as made at exit, so a release the process ends in
        // isn't taken for a crash next time. Called from main() before the
        // teardown; the static one at exit is only a fallback.
        static void PrepareForExit(std::chrono::milliseconds _Wait);

        // Load the models (if they aren't), run each on a second of
        // generated sound, or decode `_Wav` (16 kHz mono 16-bit), and report:
        // {ok, loadMs, decodeMs, text?, keywords, speaker} or {ok = false,
        // code, message}. `_Done` runs on the engine thread.
        void SelfTest(const std::string& _Wav, std::function<void(const app::Json&)> _Done);

        // The system voices spoken replies can use.
        std::vector<VoiceInfo> Voices(std::string& _Error);

        // Release the models now (they reload when listening starts), waiting
        // up to `_Wait` for the engine thread. Listening stops first.
        // True when both threads finished in time.
        bool ReleaseModels(std::chrono::milliseconds _Wait);

        // One guarded call into the libraries (Recognizer's CallFn). True
        // when it ended normally. Public for tests.
        bool Call(const char* _szName, std::chrono::milliseconds _Limit,
            const std::function<void()>& _Fn);
        // Run `_Task` on the engine thread.
        void Post(std::function<void()> _Task);
        // Tests: how often the watchdog looks (default 250 ms).
        void SetMonitorPeriod(std::chrono::milliseconds _Period);
        void Log(const std::string& _Line);

        struct ListenState;

      private:
        void StartThreads();
        void WorkerLoop();
        void MonitorLoop();
        // On the engine thread: load the libraries and the models if they
        // aren't. False with an error code (engine-missing, engine-files,
        // engine-fault) and message.
        bool EnsureLoaded(std::string& _Code, std::string& _Message);
        using FileList = std::vector<std::pair<std::string, std::pair<std::uint64_t, std::string>>>;
        bool VerifyFiles(const FileList& _Files, std::string& _Message);
        void Unload();
        void UnloadIfIdle();
        // After kMaxExceptionRun failed calls in a row: stop listening.
        void StopAfterFailures();
        // On the engine thread: close every listen link with `_Error` and
        // release its listener (before the models go).
        void DropListeners(const app::Json& _Error, const std::string& _Reason);
        // No more calls: tell every listen link and close it.
        void Fault(const std::string& _Code, const std::string& _Detail);
        void CloseListens(const app::Json& _Error, const std::string& _Reason);
        void OpenLog();

        // Speaking thread: load Turbo (and the runtime) if it isn't.
        bool EnsureTurbo(std::string& _Error);
        void UnloadTurbo();
        // Speaking thread: the runtime, the speak marker and the log, before
        // a small voice loads. False with `_Error`.
        bool PrepareSmall(std::string& _Error);
        void UnloadSmall();
        void SpeakLoop();
        // The GPU pack's folder when Turbo should use it and it's there, else "".
        std::string GpuDir() const;

        void OnListenText(const std::shared_ptr<ListenState>& _pState, const std::string& _Text);
        void OnListenAudio(const std::shared_ptr<ListenState>& _pState, const std::string& _Pcm);
        void OnListenClosed(const std::shared_ptr<ListenState>& _pState);
        friend class ListenLink;

        const std::string m_LibraryDir;
        const std::string m_StateDir;

        mutable std::mutex m_Mutex; // the fields below up to m_Tasks
        EngineConfig m_Config;
        std::vector<std::pair<std::string, std::pair<std::uint64_t, std::string>>>
            m_Files; // path, size, sha
        bool m_bConfigured = false;
        bool m_bLoaded = false;
        std::string m_GpuDir;
        std::string m_TurboDevice; // see EngineState
        std::string m_GpuError;
        app::Json m_Tts; // Configure's `tts` (null: none)
        FileList m_TtsFiles;
        app::Json m_Small; // Configure's `small` (null: none)
        std::string m_FaultCode;
        std::string m_FaultDetail;
        std::vector<std::weak_ptr<ListenState>> m_Listens;
        bool m_bThreads = false;
        bool m_bQuit = false;
        std::condition_variable m_Wake;
        std::deque<std::function<void()>> m_Tasks;

        std::atomic<bool> m_bFaulted{false};
        std::atomic<bool> m_bExiting{false}; // PrepareForExit: calls are marked "exit: ..."
        std::atomic<bool> m_bInTask{false};
        std::thread m_Worker;
        std::thread m_Monitor;
        std::atomic<long long> m_iMonitorMs{250};
        std::condition_variable m_MonitorWake;
        Watchdog m_Watchdog;
        CrashMarker m_Marker;
        bool m_bMarkerOpen = false;

        // The speaking thread: its queue (under m_Mutex), watchdog, marker.
        std::thread m_SpeakWorker;
        std::thread::id m_SpeakId;
        std::condition_variable m_SpeakWake;
        std::deque<std::function<void()>> m_SpeakTasks;
        std::atomic<bool> m_bSpeakInTask{false};
        Watchdog m_SpeakWatchdog;
        CrashMarker m_SpeakMarker;
        bool m_bSpeakMarkerOpen = false;
        std::mutex m_VerifyMutex; // m_Verified, from either thread

        std::once_flag m_CrashOnce;
        LastCrash m_LastCrash;

        std::mutex m_LogMutex;
        std::FILE* m_pLog = nullptr;
        bool m_bLogIsStderr = false;

        // Engine thread only.
        std::unique_ptr<Recognizer> m_pRecognizer;
        EngineConfig m_LoadedConfig;
        int m_iExceptionRun = 0;
        std::string m_LastException;
        std::map<std::string, std::string> m_Verified; // path -> "size:mtime:sha"
        bool m_bVerifiedRead = false;

        // Speaking thread only.
        struct TurboState;
        std::unique_ptr<TurboState> m_pTurbo;
        struct SmallState;
        std::unique_ptr<SmallState> m_pSmall;
        std::string m_SpeakException;
    };

} // namespace gitgud::speech
