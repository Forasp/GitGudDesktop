#include "speech/LocalEngine.h"

#include "platform/Http.h"
#include "platform/Shell.h"
#include "speech/Listener.h"
#include "speech/SherpaApi.h"
#include "speech/SmallVoice.h"
#include "speech/SpeechText.h"
#include "speech/Text.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace gitgud::speech
{

    namespace fs = std::filesystem;
    using app::Json;
    using namespace std::chrono_literals;

    namespace
    {

        constexpr int kRate = 16000;
        // Mic audio waiting for the engine thread: past this many frames (10 s
        // of 20 ms frames) a send waits, and the app's queue drops the oldest.
        constexpr int kMaxQueuedFrames = 500;
        // Decode failures in a row that stop listening.
        constexpr int kMaxExceptionRun = 3;
        // The engine log is started over past this size.
        constexpr std::uintmax_t kMaxLogBytes = 2u * 1024u * 1024u;
        // The speak channel: says kept waiting, and their size.
        constexpr std::size_t kMaxSays = 64;
        constexpr std::size_t kMaxSayBytes = 8000;

        LocalEngine* g_pInstance = nullptr;

        std::string Now()
        {
            const std::time_t now = std::time(nullptr);
            std::tm tm = {};
#if defined(_WIN32)
            localtime_s(&tm, &now);
#else
            localtime_r(&now, &tm);
#endif
            char abuf[32];
            std::strftime(abuf, sizeof(abuf), "%Y-%m-%d %H:%M:%S", &tm);
            return abuf;
        }

        std::string ReadTail(const std::string& _Path, std::size_t _nBytes)
        {
            std::ifstream file(fs::u8path(_Path), std::ios::binary);
            if (!file)
            {
                return {};
            }
            file.seekg(0, std::ios::end);
            const std::streamoff isize = file.tellg();
            const std::streamoff ifrom = isize > static_cast<std::streamoff>(_nBytes)
                                             ? isize - static_cast<std::streamoff>(_nBytes)
                                             : 0;
            file.seekg(ifrom);
            std::string tail(static_cast<std::size_t>(isize - ifrom), '\0');
            file.read(tail.data(), static_cast<std::streamsize>(tail.size()));
            if (ifrom > 0)
            {
                const std::size_t nline = tail.find('\n');
                tail = nline == std::string::npos ? tail : tail.substr(nline + 1);
            }
            return tail;
        }

        // A 16 kHz mono 16-bit WAV file's samples.
        bool ReadWav(const std::string& _Path, std::vector<float>& _Out, std::string& _Error)
        {
            std::ifstream file(fs::u8path(_Path), std::ios::binary);
            std::stringstream ss;
            ss << file.rdbuf();
            const std::string bytes = ss.str();
            auto u16 = [&](std::size_t _nAt)
            {
                return static_cast<unsigned>(static_cast<unsigned char>(bytes[_nAt]) |
                                             (static_cast<unsigned char>(bytes[_nAt + 1]) << 8));
            };
            auto u32 = [&](std::size_t _nAt)
            {
                return u16(_nAt) | (u16(_nAt + 2) << 16);
            };
            if (bytes.size() < 12 || bytes.compare(0, 4, "RIFF") != 0 ||
                bytes.compare(8, 4, "WAVE") != 0)
            {
                _Error = "not a WAV file: " + _Path;
                return false;
            }
            bool bformat = false;
            for (std::size_t nat = 12; nat + 8 <= bytes.size();)
            {
                const std::string id = bytes.substr(nat, 4);
                const std::size_t nsize = u32(nat + 4);
                const std::size_t nbody = nat + 8;
                if (nbody + nsize > bytes.size() + 1)
                {
                    break;
                }
                if (id == "fmt " && nsize >= 16)
                {
                    bformat = u16(nbody) == 1 && u16(nbody + 2) == 1 && u32(nbody + 4) == kRate &&
                              u16(nbody + 14) == 16;
                }
                else if (id == "data" && bformat)
                {
                    const std::size_t ncount = std::min(nsize, bytes.size() - nbody) / 2;
                    _Out.resize(ncount);
                    for (std::size_t ni = 0; ni < ncount; ++ni)
                    {
                        _Out[ni] = static_cast<float>(static_cast<int16_t>(u16(nbody + 2 * ni))) /
                                   32768.0f;
                    }
                    return true;
                }
                nat = nbody + nsize + (nsize & 1);
            }
            _Error = _Path + " isn't 16 kHz mono 16-bit";
            return false;
        }

        Json ErrorMessage(const std::string& _Code, const std::string& _Message)
        {
            return Json::Object().Set("type", "error").Set("code", _Code).Set("message", _Message);
        }

    } // namespace

    // ---- Listen links ----------------------------------------------------------

    struct LocalEngine::ListenState
    {
        std::recursive_mutex m_Mutex;
        voice::ILink::OnMessage m_OnMessage;
        voice::ILink::OnClose m_OnClose;
        bool m_bClosed = false;

        std::mutex m_QueueMutex;
        std::condition_variable m_QueueWake;
        int m_iQueued = 0;

        // Engine thread only.
        std::unique_ptr<Listener> m_pListener;
        bool m_bFailed = false;

        void Deliver(bool _bBinary, const std::string& _Data)
        {
            std::lock_guard<std::recursive_mutex> lock(m_Mutex);
            if (!m_bClosed && m_OnMessage)
            {
                m_OnMessage(_bBinary, _Data);
            }
        }

        void CloseWith(int _iCode, const std::string& _Reason)
        {
            {
                std::lock_guard<std::recursive_mutex> lock(m_Mutex);
                if (m_bClosed)
                {
                    return;
                }
                m_bClosed = true;
                m_OnMessage = nullptr;
                voice::ILink::OnClose onClose = std::move(m_OnClose);
                m_OnClose = nullptr;
                if (onClose)
                {
                    onClose(_iCode, _Reason);
                }
            }
            std::lock_guard<std::mutex> queue(m_QueueMutex);
            m_QueueWake.notify_all();
        }

        bool Closed()
        {
            std::lock_guard<std::recursive_mutex> lock(m_Mutex);
            return m_bClosed;
        }
    };

    class ListenLink : public voice::ILink
    {
      public:
        explicit ListenLink(LocalEngine& _Engine)
            : m_Engine(_Engine), m_pState(std::make_shared<LocalEngine::ListenState>())
        {
        }

        ~ListenLink() override
        {
            Close();
        }

        bool Open(OnMessage _OnMessage, OnClose _OnClose, std::string& _Error) override
        {
            (void)_Error;
            {
                std::lock_guard<std::recursive_mutex> lock(m_pState->m_Mutex);
                m_pState->m_OnMessage = std::move(_OnMessage);
                m_pState->m_OnClose = std::move(_OnClose);
            }
            {
                std::lock_guard<std::mutex> lock(m_Engine.m_Mutex);
                m_Engine.m_Listens.push_back(m_pState);
            }
            const EngineState state = m_Engine.State();
            if (state.m_bFaulted)
            {
                // Faulted (maybe with its thread stuck): say so at once.
                Json error = ErrorMessage(state.m_FaultCode, state.m_FaultDetail);
                error.Set("restart", true);
                m_pState->Deliver(false, error.Dump());
                m_pState->CloseWith(1011, "the speech engine stopped");
            }
            return true;
        }

        bool SendText(const std::string& _Text) override
        {
            if (m_pState->Closed())
            {
                m_LastError = "the link is closed";
                return false;
            }
            std::shared_ptr<LocalEngine::ListenState> pstate = m_pState;
            LocalEngine* pengine = &m_Engine;
            m_Engine.Post([pengine, pstate, _Text]() { pengine->OnListenText(pstate, _Text); });
            return true;
        }

        bool SendBinary(const void* _pData, std::size_t _nSize) override
        {
            if (m_pState->Closed())
            {
                m_LastError = "the link is closed";
                return false;
            }
            {
                std::unique_lock<std::mutex> lock(m_pState->m_QueueMutex);
                m_pState->m_QueueWake.wait_for(lock, 2s, [this]()
                    { return m_pState->m_iQueued < kMaxQueuedFrames || m_pState->m_bClosed; });
                if (m_pState->m_iQueued >= kMaxQueuedFrames)
                {
                    m_LastError = "the speech engine is behind";
                    return false;
                }
                ++m_pState->m_iQueued;
            }
            std::shared_ptr<LocalEngine::ListenState> pstate = m_pState;
            LocalEngine* pengine = &m_Engine;
            std::string pcm(static_cast<const char*>(_pData), _nSize);
            m_Engine.Post(
                [pengine, pstate, pcm = std::move(pcm)]() { pengine->OnListenAudio(pstate, pcm); });
            return true;
        }

        std::string LastSendError() const override
        {
            return m_LastError;
        }

        void Close() override
        {
            if (m_bCloseSent)
            {
                return;
            }
            m_bCloseSent = true;
            m_pState->CloseWith(1000, "closed");
            std::shared_ptr<LocalEngine::ListenState> pstate = m_pState;
            LocalEngine* pengine = &m_Engine;
            m_Engine.Post([pengine, pstate]() { pengine->OnListenClosed(pstate); });
        }

      private:
        LocalEngine& m_Engine;
        std::shared_ptr<LocalEngine::ListenState> m_pState;
        std::string m_LastError;
        bool m_bCloseSent = false;
    };

    // ---- Speak links -------------------------------------------------------------

    namespace
    {

        // The speak channel: says spoken one at a time on a thread of its own,
        // sentence by sentence: a "small:<name>" voice (its text is phonemes)
        // on the engine's speaking thread, any other with the system's
        // voices. `warm` loads a small voice before its first say.
        class SpeakLink : public voice::ILink
        {
          public:
            explicit SpeakLink(LocalEngine* _pEngine) : m_pEngine(_pEngine)
            {
            }

            ~SpeakLink() override
            {
                Close();
            }

            bool Open(OnMessage _OnMessage, OnClose _OnClose, std::string& _Error) override
            {
                (void)_Error;
                {
                    std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                    m_OnMessage = std::move(_OnMessage);
                    m_OnClose = std::move(_OnClose);
                }
                m_Thread = std::thread([this]() { Loop(); });
                return true;
            }

            bool SendText(const std::string& _Text) override
            {
                const std::optional<Json> parsed = Json::Parse(_Text);
                if (!parsed || !parsed->IsObject())
                {
                    Send(ErrorMessage("bad-json", "not a JSON object"));
                    return true;
                }
                const std::string& type = (*parsed)["type"].AsString();
                const std::string& id = (*parsed)["id"].AsString();
                std::lock_guard<std::mutex> lock(m_Mutex);
                if (m_bQuit)
                {
                    m_LastError = "the link is closed";
                    return false;
                }
                if (type == "say")
                {
                    Say say;
                    say.m_Id = id;
                    say.m_Text = (*parsed)["text"].AsString();
                    say.m_Voice = (*parsed)["voice"].AsString();
                    say.m_fSpeed = (*parsed)["speed"].AsNumber(1.0);
                    // A small voice's playback: the rate it plays at, the
                    // pitch wobble, and the roughness with its band (Lua's).
                    say.m_iRate = static_cast<int>((*parsed)["sampleRate"].AsInt(0));
                    say.m_fWobble = (*parsed)["wobble"].AsNumber(0.0);
                    say.m_fRough = (*parsed)["rough"].AsNumber(0.0);
                    say.m_fRoughLow = (*parsed)["roughLow"].AsNumber(30.0);
                    say.m_fRoughHigh = (*parsed)["roughHigh"].AsNumber(80.0);
                    if (id.empty() || id.size() > 64 || say.m_Text.size() > kMaxSayBytes ||
                        m_Says.size() >= kMaxSays)
                    {
                        m_Out.push_back(ErrorMessage(
                            "bad-request", "say needs an id and at most 8000 bytes of text")
                                .Set("id", id)
                                .Dump());
                    }
                    else
                    {
                        m_Says.push_back(std::move(say));
                    }
                }
                else if (type == "warm")
                {
                    // Load a small voice now, so its first say doesn't wait.
                    const std::string& voice = (*parsed)["voice"].AsString();
                    if (voice.rfind("small:", 0) == 0 && m_pEngine && m_pEngine->SmallConfigured())
                    {
                        m_pEngine->WarmSmall(voice.substr(std::strlen("small:")));
                    }
                }
                else if (type == "stop")
                {
                    const bool ball = !(*parsed).Has("id") || id.empty();
                    if (!m_CurrentId.empty() && (ball || id == m_CurrentId))
                    {
                        m_bStopCurrent = true;
                        m_pStop->store(true);
                    }
                    for (auto it = m_Says.begin(); it != m_Says.end();)
                    {
                        if (ball || it->m_Id == id)
                        {
                            m_Out.push_back(
                                Json::Object().Set("type", "stopped").Set("id", it->m_Id).Dump());
                            it = m_Says.erase(it);
                        }
                        else
                        {
                            ++it;
                        }
                    }
                }
                else
                {
                    m_Out.push_back(
                        ErrorMessage("unknown-type", "unknown type '" + type + "'").Dump());
                }
                m_Wake.notify_all();
                return true;
            }

            bool SendBinary(const void*, std::size_t) override
            {
                m_LastError = "the speak channel takes no audio";
                return false;
            }

            std::string LastSendError() const override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                return m_LastError;
            }

            void Close() override
            {
                {
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_bQuit = true;
                    m_bStopCurrent = true;
                    m_pStop->store(true);
                }
                m_Wake.notify_all();
                if (m_Thread.joinable())
                {
                    if (m_Thread.get_id() == std::this_thread::get_id())
                    {
                        m_Thread.detach();
                    }
                    else
                    {
                        m_Thread.join();
                    }
                }
                std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                m_OnMessage = nullptr;
                if (OnClose onClose = std::move(m_OnClose))
                {
                    m_OnClose = nullptr;
                    onClose(1000, "closed");
                }
            }

          private:
            struct Say
            {
                std::string m_Id;
                std::string m_Text;
                std::string m_Voice;
                double m_fSpeed = 1.0;
                int m_iRate = 0; // small voices: 0 is the model's own rate
                double m_fWobble = 0.0;
                double m_fRough = 0.0;
                double m_fRoughLow = 30.0;
                double m_fRoughHigh = 80.0;
            };

            void Send(const Json& _Message)
            {
                std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                if (m_OnMessage)
                {
                    m_OnMessage(false, _Message.Dump());
                }
            }

            void SendPcm(const std::string& _Pcm)
            {
                std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                if (m_OnMessage)
                {
                    m_OnMessage(true, _Pcm);
                }
            }

            void Loop()
            {
                std::string error;
                std::unique_ptr<ITextToSpeech> pspeech;
                bool bsystem = false; // the system's voices tried
                for (;;)
                {
                    Say say;
                    std::vector<std::string> out;
                    {
                        std::unique_lock<std::mutex> lock(m_Mutex);
                        m_Wake.wait(lock,
                            [this]() { return m_bQuit || !m_Says.empty() || !m_Out.empty(); });
                        out.swap(m_Out);
                        if (m_bQuit)
                        {
                            return;
                        }
                        if (!m_Says.empty())
                        {
                            say = std::move(m_Says.front());
                            m_Says.pop_front();
                            m_CurrentId = say.m_Id;
                            m_bStopCurrent = false;
                            m_pStop = std::make_shared<std::atomic<bool>>(false);
                        }
                    }
                    for (const std::string& message : out)
                    {
                        std::lock_guard<std::recursive_mutex> lock(m_CallbackMutex);
                        if (m_OnMessage)
                        {
                            m_OnMessage(false, message);
                        }
                    }
                    if (say.m_Id.empty())
                    {
                        continue;
                    }
                    if (say.m_Voice.rfind("small:", 0) == 0)
                    {
                        if (m_pEngine && m_pEngine->SmallConfigured() &&
                            !m_pEngine->State().m_bFaulted)
                        {
                            SpeakSmall(say);
                            std::lock_guard<std::mutex> lock(m_Mutex);
                            m_CurrentId.clear();
                            continue;
                        }
                        // Its text is phonemes: a system voice can't read it.
                        Send(ErrorMessage(
                            "tts", m_pEngine && m_pEngine->State().m_bFaulted
                                       ? "the speech engine stopped after an internal error"
                                       : "the built-in voice isn't set up")
                                .Set("id", say.m_Id));
                        std::lock_guard<std::mutex> lock(m_Mutex);
                        m_CurrentId.clear();
                        continue;
                    }
                    if (!bsystem)
                    {
                        bsystem = true;
                        pspeech = MakeSystemTextToSpeech(error);
                    }
                    if (!pspeech)
                    {
                        Send(ErrorMessage("tts", error).Set("id", say.m_Id));
                    }
                    else
                    {
                        Speak(*pspeech, say);
                    }
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_CurrentId.clear();
                }
            }

            bool Stopping()
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                return m_bStopCurrent || m_bQuit;
            }

            // A small voice: its text is phonemes, said a sentence at a time
            // on the engine's speaking thread, played at the say's rate (a
            // lower one than the model's deepens the voice), with roughness.
            void SpeakSmall(const Say& _Say)
            {
                const int irate = _Say.m_iRate > 0 ? _Say.m_iRate : kSmallVoiceRate;
                Send(Json::Object()
                        .Set("type", "start")
                        .Set("id", _Say.m_Id)
                        .Set("sampleRate", irate)
                        .Set("provider", "small"));
                const std::string name = _Say.m_Voice.substr(std::strlen("small:"));
                // The roughness band is in played Hz; the audio is still at the model's rate.
                const double fscale = static_cast<double>(kSmallVoiceRate) / irate;
                unsigned useed = 7;
                for (const std::string& sentence : SplitForSpeech(_Say.m_Text))
                {
                    if (Stopping())
                    {
                        break;
                    }

                    struct Result
                    {
                        std::mutex m_Mutex;
                        std::condition_variable m_Done;
                        bool m_bDone = false;
                        bool m_bOk = false;
                        std::vector<float> m_Audio;
                        std::string m_Error;
                    };

                    auto presult = std::make_shared<Result>();
                    LocalEngine* pengine = m_pEngine;
                    const double fspeed = _Say.m_fSpeed;
                    const double fwobble = _Say.m_fWobble;
                    pengine->PostSpeak(
                        [pengine, presult, sentence, name, fspeed, fwobble]()
                        {
                            std::vector<float> audio;
                            std::string error;
                            const bool bok =
                                pengine->SmallSay(sentence, name, fspeed, fwobble, audio, error);
                            std::lock_guard<std::mutex> lock(presult->m_Mutex);
                            presult->m_bOk = bok;
                            presult->m_Audio = std::move(audio);
                            presult->m_Error = error;
                            presult->m_bDone = true;
                            presult->m_Done.notify_all();
                        });
                    bool bdone = false;
                    {
                        std::unique_lock<std::mutex> lock(presult->m_Mutex);
                        while (!presult->m_bDone)
                        {
                            presult->m_Done.wait_for(lock, 100ms);
                            if (presult->m_bDone || Stopping() || pengine->State().m_bFaulted)
                            {
                                break;
                            }
                        }
                        bdone = presult->m_bDone;
                    }
                    if (Stopping())
                    {
                        break;
                    }
                    if (!bdone || !presult->m_bOk)
                    {
                        Send(ErrorMessage(
                            "tts", bdone ? presult->m_Error : "the speech engine stopped")
                                .Set("id", _Say.m_Id));
                        return;
                    }
                    std::vector<float>& audio = presult->m_Audio;
                    Roughen(audio, kSmallVoiceRate, _Say.m_fRough, _Say.m_fRoughLow * fscale,
                        _Say.m_fRoughHigh * fscale, useed++);
                    std::string pcm(audio.size() * 2, '\0');
                    for (std::size_t ni = 0; ni < audio.size(); ++ni)
                    {
                        const float f = std::max(-1.0f, std::min(1.0f, audio[ni]));
                        const int16_t s = static_cast<int16_t>(std::lround(f * 32767.0f));
                        pcm[2 * ni] = static_cast<char>(s & 0xFF);
                        pcm[2 * ni + 1] = static_cast<char>((s >> 8) & 0xFF);
                    }
                    const std::size_t npiece = static_cast<std::size_t>(irate) / 10 * 2;
                    for (std::size_t nat = 0; nat < pcm.size() && !Stopping(); nat += npiece)
                    {
                        SendPcm(pcm.substr(nat, npiece));
                    }
                }
                Send(Json::Object()
                        .Set("type", Stopping() ? "stopped" : "end")
                        .Set("id", _Say.m_Id));
            }

            void Speak(ITextToSpeech& _Speech, const Say& _Say)
            {
                Send(Json::Object()
                        .Set("type", "start")
                        .Set("id", _Say.m_Id)
                        .Set("sampleRate", _Speech.SampleRate())
                        .Set("provider", _Speech.Provider()));
                for (const std::string& sentence : SplitForSpeech(_Say.m_Text))
                {
                    if (Stopping())
                    {
                        break;
                    }
                    std::string error;
                    const bool bok = _Speech.Synthesize(
                        sentence, _Say.m_Voice, _Say.m_fSpeed,
                        [this](const std::string& _Pcm)
                        {
                            if (Stopping())
                            {
                                return false;
                            }
                            SendPcm(_Pcm);
                            return true;
                        },
                        error);
                    if (!bok)
                    {
                        Send(ErrorMessage("tts", error).Set("id", _Say.m_Id));
                        return;
                    }
                }
                Send(Json::Object()
                        .Set("type", Stopping() ? "stopped" : "end")
                        .Set("id", _Say.m_Id));
            }

            LocalEngine* m_pEngine = nullptr;
            std::shared_ptr<std::atomic<bool>> m_pStop = std::make_shared<std::atomic<bool>>(false);
            mutable std::mutex m_Mutex;
            std::condition_variable m_Wake;
            std::deque<Say> m_Says;
            std::vector<std::string> m_Out;
            std::string m_CurrentId;
            bool m_bStopCurrent = false;
            bool m_bQuit = false;
            std::string m_LastError;

            std::recursive_mutex m_CallbackMutex;
            OnMessage m_OnMessage;
            OnClose m_OnClose;
            std::thread m_Thread;
        };

        // At exit: release the models while the libraries' threads still run.
        struct ShutdownAtExit
        {
            ~ShutdownAtExit();
        } g_ShutdownAtExit;

    } // namespace

    // ---- LocalEngine -----------------------------------------------------------

    LocalEngine::LocalEngine(std::string _LibraryDir, std::string _StateDir)
        : m_LibraryDir(std::move(_LibraryDir)), m_StateDir(std::move(_StateDir))
    {
    }

    LocalEngine::~LocalEngine()
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Tasks.push_back([this]() { Unload(); });
            m_SpeakTasks.push_back([this]() { UnloadSmall(); });
            m_bQuit = true;
        }
        m_Wake.notify_all();
        m_MonitorWake.notify_all();
        m_SpeakWake.notify_all();
        if (m_Monitor.joinable())
        {
            m_Monitor.join();
        }
        if (m_SpeakWorker.joinable())
        {
            if (m_SpeakWatchdog.Hung() && m_bSpeakInTask.load())
            {
                m_SpeakWorker.detach();
            }
            else
            {
                m_SpeakWorker.join();
            }
        }
        if (m_Worker.joinable())
        {
            if (m_Watchdog.Hung() && m_bInTask.load())
            {
                m_Worker.detach(); // stuck in a library call: left to the process's end
            }
            else
            {
                m_Worker.join();
            }
        }
        std::lock_guard<std::mutex> lock(m_LogMutex);
        if (m_pLog && !m_bLogIsStderr)
        {
            std::fclose(m_pLog);
        }
        m_pLog = nullptr;
    }

    ShutdownAtExit::~ShutdownAtExit()
    {
        // The app's engine is never deleted (a stuck thread may still use
        // it). main() releases its models before the teardown
        // (PrepareForExit); this is the fallback for an exit that skipped
        // it, its calls marked as made at exit.
        LocalEngine::PrepareForExit(5s); // nothing when main() already did
    }

    void LocalEngine::PrepareForExit(std::chrono::milliseconds _Wait)
    {
        if (!g_pInstance || g_pInstance->m_bExiting.exchange(true))
        {
            return;
        }
        const auto t0 = std::chrono::steady_clock::now();
        const bool bdone = g_pInstance->ReleaseModels(_Wait);
        const std::string ms = std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0)
                                                  .count());
        // Not done in time: the process ends anyway, and the next start
        // knows it was at exit (the calls are marked "exit: ...").
        g_pInstance->Log(bdone ? "exit: models released in " + ms + " ms"
                               : "exit: the models weren't released after " + ms +
                                     " ms; the app closes without waiting");
    }

    bool LocalEngine::ReleaseModels(std::chrono::milliseconds _Wait)
    {
        const EngineState state = State();
        if (state.m_bFaulted)
        {
            return false;
        }
        bool bthreads = false;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            bthreads = m_bThreads;
        }
        auto pspoken = std::make_shared<std::atomic<bool>>(!bthreads);
        if (bthreads)
        {
            PostSpeak(
                [this, pspoken]()
                {
                    UnloadSmall();
                    pspoken->store(true);
                });
        }
        if (!state.m_bLoaded)
        {
            const auto deadline = std::chrono::steady_clock::now() + _Wait;
            while (!pspoken->load() && std::chrono::steady_clock::now() < deadline)
            {
                std::this_thread::sleep_for(20ms);
            }
            return pspoken->load();
        }
        auto pdone = std::make_shared<std::atomic<bool>>(false);
        Post(
            [this, pdone]()
            {
                // Listening stops first: its listeners use the models.
                DropListeners(ErrorMessage("engine-files", "the voice models were released"),
                    "the voice models were released");
                Unload();
                pdone->store(true);
            });
        const auto deadline = std::chrono::steady_clock::now() + _Wait;
        while ((!pdone->load() || !pspoken->load()) && std::chrono::steady_clock::now() < deadline)
        {
            std::this_thread::sleep_for(20ms);
        }
        return pdone->load() && pspoken->load();
    }

    LocalEngine& LocalEngine::Instance()
    {
        static LocalEngine* pengine = []()
        {
            g_pInstance =
                new LocalEngine((fs::u8path(platform::ExecutableDirectory()) / "voice").u8string(),
                    (fs::u8path(platform::ConfigDirectory()) / "bragi").u8string());
            return g_pInstance;
        }();
        return *pengine;
    }

    bool LocalEngine::Installed() const
    {
        return SherpaFilesPresent(m_LibraryDir);
    }

    bool LocalEngine::Configure(const Json& _Settings, std::string& _Error)
    {
        EngineConfig config;
        if (!EngineConfig::FromJson(_Settings, config, _Error))
        {
            return false;
        }
        std::vector<std::pair<std::string, std::pair<std::uint64_t, std::string>>> files;
        if (_Settings.Has("files"))
        {
            if (!_Settings["files"].IsArray())
            {
                _Error = "files must be a list";
                return false;
            }
            for (const Json& file : _Settings["files"].Items())
            {
                const std::string& path = file["path"].AsString();
                std::string sha = file["sha256"].AsString();
                std::transform(sha.begin(), sha.end(), sha.begin(),
                    [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
                if (path.empty() || !file["size"].IsNumber() || sha.size() != 64 ||
                    sha.find_first_not_of("0123456789abcdef") != std::string::npos)
                {
                    _Error = "each file needs a path, a size, and a SHA-256";
                    return false;
                }
                files.push_back({path, {static_cast<std::uint64_t>(file["size"].AsNumber()), sha}});
            }
        }
        if (config.m_VadModel.empty() || config.m_AsrDir.empty() || config.m_KwsDir.empty())
        {
            _Error = "vadModel, asrDir, and kwsDir are needed";
            return false;
        }
        if (config.m_WorkDir.empty())
        {
            config.m_WorkDir = (fs::u8path(config.m_AsrDir).parent_path() / "work").u8string();
        }
        const Json& small = _Settings["small"];
        if (!small.IsNull() && (!small.IsObject() || small["voicesDir"].AsString().empty()))
        {
            _Error = "small needs voicesDir";
            return false;
        }
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_Config = std::move(config);
        m_Files = std::move(files);
        m_Small = small.IsObject() ? small : Json();
        m_bConfigured = true;
        return true;
    }

    bool LocalEngine::SmallConfigured() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_Small.IsObject();
    }

    std::unique_ptr<voice::ILink> LocalEngine::MakeLink(const std::string& _Channel)
    {
        if (_Channel == "listen")
        {
            return std::make_unique<ListenLink>(*this);
        }
        if (_Channel == "speak")
        {
            return std::make_unique<SpeakLink>(this);
        }
        return nullptr;
    }

    EngineState LocalEngine::State() const
    {
        EngineState state;
        state.m_bInstalled = Installed();
        std::lock_guard<std::mutex> lock(m_Mutex);
        state.m_bConfigured = m_bConfigured;
        state.m_bLoaded = m_bLoaded;
        state.m_bFaulted = m_bFaulted.load();
        state.m_FaultCode = m_FaultCode;
        state.m_FaultDetail = m_FaultDetail;
        return state;
    }

    LastCrash LocalEngine::TakeLastCrash()
    {
        std::call_once(m_CrashOnce,
            [this]()
            {
                for (const char* szname : {"voice-state", "voice-state-speak"})
                {
                    const std::string marker = (fs::u8path(m_StateDir) / szname).u8string();
                    std::error_code ec;
                    if (fs::exists(fs::u8path(marker), ec))
                    {
                        const std::string call = CrashMarker::TakeLast(marker);
                        if (call.rfind("exit: ", 0) == 0)
                        {
                            // The app closed during an exit-time release:
                            // nothing was in use, so it isn't a crash.
                            Log("last run: the app closed while it was in \"" + call.substr(6) +
                                "\" at exit (not counted as a crash)");
                            continue;
                        }
                        if (m_LastCrash.m_Call.empty())
                        {
                            m_LastCrash.m_Call = call;
                        }
                    }
                }
                if (!m_LastCrash.m_Call.empty())
                {
                    m_LastCrash.m_LogTail =
                        ReadTail((fs::u8path(m_StateDir) / "voice-engine.log").u8string(), 2000);
                }
            });
        return m_LastCrash;
    }

    void LocalEngine::ForgetLastCrash()
    {
        TakeLastCrash(); // read (and cleared) first, so it never comes back
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_LastCrash = LastCrash{};
    }

    std::vector<VoiceInfo> LocalEngine::Voices(std::string& _Error)
    {
        std::unique_ptr<ITextToSpeech> pspeech = MakeSystemTextToSpeech(_Error);
        return pspeech ? pspeech->Voices() : std::vector<VoiceInfo>{};
    }

    void LocalEngine::SetMonitorPeriod(std::chrono::milliseconds _Period)
    {
        m_iMonitorMs = std::max<long long>(10, _Period.count());
        m_MonitorWake.notify_all();
    }

    void LocalEngine::OpenLog()
    {
        if (m_pLog)
        {
            return;
        }
        const fs::path path = fs::u8path(m_StateDir) / "voice-engine.log";
        std::error_code ec;
        fs::create_directories(path.parent_path(), ec);
        if (fs::file_size(path, ec) > kMaxLogBytes && !ec)
        {
            fs::remove(path, ec);
        }
#if defined(_WIN32)
        // No console (the app as people run it): the libraries' messages
        // (stderr; they share the app's C runtime) go to the log too, so a
        // reason printed just before the process ends is kept.
        const HANDLE herr = GetStdHandle(STD_ERROR_HANDLE);
        if (herr == nullptr || herr == INVALID_HANDLE_VALUE)
        {
            if (_wfreopen(path.c_str(), L"a", stderr))
            {
                m_pLog = stderr;
                m_bLogIsStderr = true;
                return;
            }
        }
        m_pLog = _wfsopen(path.c_str(), L"a", _SH_DENYNO);
#else
        m_pLog = std::fopen(path.c_str(), "a");
#endif
    }

    void LocalEngine::Log(const std::string& _Line)
    {
        std::lock_guard<std::mutex> lock(m_LogMutex);
        OpenLog();
        if (m_pLog)
        {
            std::fprintf(m_pLog, "%s %s\n", Now().c_str(), _Line.c_str());
            std::fflush(m_pLog);
        }
    }

    void LocalEngine::StartThreads()
    {
        // m_Mutex held.
        if (m_bThreads || m_bQuit)
        {
            return;
        }
        m_bThreads = true;
        m_Worker = std::thread([this]() { WorkerLoop(); });
        m_SpeakWorker = std::thread([this]() { SpeakLoop(); });
        m_SpeakId = m_SpeakWorker.get_id();
        m_Monitor = std::thread([this]() { MonitorLoop(); });
    }

    void LocalEngine::Post(std::function<void()> _Task)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            StartThreads();
            m_Tasks.push_back(std::move(_Task));
        }
        m_Wake.notify_one();
    }

    void LocalEngine::WorkerLoop()
    {
        for (;;)
        {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(m_Mutex);
                m_Wake.wait(lock, [this]() { return m_bQuit || !m_Tasks.empty(); });
                if (m_Tasks.empty())
                {
                    return;
                }
                task = std::move(m_Tasks.front());
                m_Tasks.pop_front();
            }
            m_bInTask = true;
            task();
            m_bInTask = false;
            if (m_bFaulted.load() && m_pRecognizer)
            {
                // Never released: releasing could fault again. Listeners that
                // still point at it only check it's poisoned.
                m_pRecognizer->SetPoisoned();
                (void)m_pRecognizer.release();
            }
        }
    }

    void LocalEngine::PostSpeak(std::function<void()> _Task)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            StartThreads();
            m_SpeakTasks.push_back(std::move(_Task));
        }
        m_SpeakWake.notify_one();
    }

    void LocalEngine::SpeakLoop()
    {
        for (;;)
        {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(m_Mutex);
                m_SpeakWake.wait(lock, [this]() { return m_bQuit || !m_SpeakTasks.empty(); });
                if (m_SpeakTasks.empty())
                {
                    return;
                }
                task = std::move(m_SpeakTasks.front());
                m_SpeakTasks.pop_front();
            }
            m_bSpeakInTask = true;
            task();
            m_bSpeakInTask = false;
            if (m_bFaulted.load() && m_pSmall)
            {
                UnloadSmall(); // leaks its handles once faulted
            }
        }
    }

    void LocalEngine::MonitorLoop()
    {
        for (;;)
        {
            {
                std::unique_lock<std::mutex> lock(m_Mutex);
                m_MonitorWake.wait_for(lock, std::chrono::milliseconds(m_iMonitorMs.load()),
                    [this]() { return m_bQuit; });
                if (m_bQuit)
                {
                    return;
                }
            }
            const auto now = Watchdog::Clock::now();
            for (Watchdog* pwatchdog : {&m_Watchdog, &m_SpeakWatchdog})
            {
                const std::string call = pwatchdog->Overdue(now);
                if (!call.empty())
                {
                    Fault("engine-hung", "the speech engine stopped answering (" + call + ")");
                }
            }
        }
    }

    bool LocalEngine::Call(
        const char* _szName, std::chrono::milliseconds _Limit, const std::function<void()>& _Fn)
    {
        if (m_bFaulted.load())
        {
            return false;
        }
        // The speaking thread has its own watchdog and marker.
        const bool bspeak = std::this_thread::get_id() == m_SpeakId;
        Watchdog& watchdog = bspeak ? m_SpeakWatchdog : m_Watchdog;
        CrashMarker& marker = bspeak ? m_SpeakMarker : m_Marker;
        const bool bmarker = bspeak ? m_bSpeakMarkerOpen : m_bMarkerOpen;
        if (bmarker)
        {
            // A call made while the app closes: named so the next start knows.
            marker.Set(m_bExiting.load() ? ("exit: " + std::string(_szName)).c_str() : _szName);
        }
        watchdog.Begin(_szName, _Limit);
        const GuardResult result = Guarded(_Fn);
        watchdog.End();
        if (bmarker)
        {
            marker.Clear();
        }
        if (watchdog.Hung())
        {
            return false; // came back after the watchdog gave up on it
        }
        switch (result.m_eEnd)
        {
        case GuardEnd::Normal:
            if (!bspeak)
            {
                m_iExceptionRun = 0;
            }
            return true;
        case GuardEnd::Exception:
            if (bspeak)
            {
                m_SpeakException = std::string(_szName) + ": " + result.m_Detail;
                Log("call failed: " + m_SpeakException);
                return false;
            }
            ++m_iExceptionRun;
            m_LastException = std::string(_szName) + ": " + result.m_Detail;
            Log("call failed: " + m_LastException);
            return false;
        case GuardEnd::Fault:
            Fault("engine-fault", std::string(_szName) + " failed with " + result.m_Detail);
            return false;
        }
        return false;
    }

    void LocalEngine::Fault(const std::string& _Code, const std::string& _Detail)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (m_bFaulted.load())
            {
                return;
            }
            m_bFaulted = true;
            m_FaultCode = _Code;
            m_FaultDetail = _Detail;
            m_bLoaded = false;
        }
        Log("FAULT " + _Code + ": " + _Detail + " (no more calls until the app restarts)");
        Json error = ErrorMessage(_Code, _Detail);
        error.Set("restart", true);
        CloseListens(error, "the speech engine stopped");
    }

    void LocalEngine::StopAfterFailures()
    {
        if (m_iExceptionRun < kMaxExceptionRun)
        {
            return;
        }
        const std::string last = m_LastException;
        m_iExceptionRun = 0;
        Log("stopping after " + std::to_string(kMaxExceptionRun) + " failures in a row");
        DropListeners(ErrorMessage("engine-error", last), "the speech engine failed");
        Unload();
    }

    void LocalEngine::DropListeners(const Json& _Error, const std::string& _Reason)
    {
        CloseListens(_Error, _Reason);
        std::vector<std::shared_ptr<ListenState>> listens;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            for (const std::weak_ptr<ListenState>& pweak : m_Listens)
            {
                if (std::shared_ptr<ListenState> pstate = pweak.lock())
                {
                    listens.push_back(pstate);
                }
            }
        }
        for (const std::shared_ptr<ListenState>& pstate : listens)
        {
            pstate->m_pListener.reset();
            pstate->m_bFailed = true;
        }
    }

    void LocalEngine::CloseListens(const Json& _Error, const std::string& _Reason)
    {
        std::vector<std::shared_ptr<ListenState>> listens;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            for (const std::weak_ptr<ListenState>& pweak : m_Listens)
            {
                if (std::shared_ptr<ListenState> pstate = pweak.lock())
                {
                    listens.push_back(pstate);
                }
            }
        }
        const std::string text = _Error.Dump();
        for (const std::shared_ptr<ListenState>& pstate : listens)
        {
            pstate->Deliver(false, text);
            pstate->CloseWith(1011, _Reason);
        }
    }

    bool LocalEngine::VerifyFiles(const FileList& _Files, std::string& _Message)
    {
        std::lock_guard<std::mutex> verifying(m_VerifyMutex);
        const FileList& files = _Files;
        std::string work;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            work = m_Config.m_WorkDir;
        }
        const fs::path cachePath = fs::u8path(work) / "verified.json";
        if (!m_bVerifiedRead)
        {
            m_bVerifiedRead = true;
            std::ifstream in(cachePath, std::ios::binary);
            std::stringstream ss;
            ss << in.rdbuf();
            if (const std::optional<Json> cache = Json::Parse(ss.str()); cache && cache->IsObject())
            {
                for (const std::string& key : cache->Keys())
                {
                    m_Verified[key] = (*cache)[key].AsString();
                }
            }
        }
        bool bchanged = false;
        for (const auto& [path, expected] : files)
        {
            const fs::path file = fs::u8path(path);
            std::error_code ec;
            const std::uintmax_t usize = fs::file_size(file, ec);
            if (ec)
            {
                _Message = "missing " + path;
                return false;
            }
            if (usize != expected.first)
            {
                _Message = path + " is " + std::to_string(usize) + " bytes, not " +
                           std::to_string(expected.first);
                return false;
            }
            const auto mtime = fs::last_write_time(file, ec).time_since_epoch().count();
            const std::string stamp = std::to_string(usize) + ":" +
                                      std::to_string(static_cast<long long>(mtime)) + ":" +
                                      expected.second;
            if (m_Verified[path] == stamp)
            {
                continue;
            }
            const auto t0 = std::chrono::steady_clock::now();
            const std::string sha = platform::Sha256FileHex(path);
            if (sha != expected.second)
            {
                m_Verified.erase(path);
                _Message = path + " doesn't match its SHA-256";
                return false;
            }
            Log("verified " + path + " in " +
                std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - t0)
                        .count()) +
                " ms");
            m_Verified[path] = stamp;
            bchanged = true;
        }
        if (bchanged)
        {
            Json cache = Json::Object();
            for (const auto& [key, value] : m_Verified)
            {
                if (!value.empty())
                {
                    cache.Set(key, value);
                }
            }
            std::string error;
            platform::WriteFileAtomically(cachePath.u8string(), cache.Dump(), error);
        }
        return true;
    }

    bool LocalEngine::EnsureLoaded(std::string& _Code, std::string& _Message)
    {
        if (m_bFaulted.load())
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            _Code = m_FaultCode;
            _Message = m_FaultDetail;
            return false;
        }
        if (m_pRecognizer)
        {
            return true;
        }
        EngineConfig config;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (!m_bConfigured)
            {
                _Code = "engine-files";
                _Message = "the voice models aren't set up";
                return false;
            }
            config = m_Config;
        }
        TakeLastCrash(); // before the marker is reused
        if (!m_bMarkerOpen)
        {
            m_bMarkerOpen = m_Marker.Open((fs::u8path(m_StateDir) / "voice-state").u8string());
        }
        {
            // The log (and the libraries' messages with it) before they load.
            std::lock_guard<std::mutex> lock(m_LogMutex);
            OpenLog();
        }
        std::string error;
        // Always the app's own libraries: they run on the processor.
        if (!LoadSherpa(m_LibraryDir, error))
        {
            _Code = "engine-missing";
            _Message = error;
            Log("libraries: " + error);
            return false;
        }
        FileList files;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            files = m_Files;
        }
        if (!VerifyFiles(files, error))
        {
            _Code = "engine-files";
            _Message = error;
            Log("files: " + error);
            return false;
        }
        const auto t0 = std::chrono::steady_clock::now();
        auto precognizer = std::make_unique<Recognizer>(
            config, [this](const char* _szName, std::chrono::milliseconds _Limit,
                        const std::function<void()>& _Fn) { return Call(_szName, _Limit, _Fn); });
        bool bdamaged = false;
        if (!precognizer->Load(error, bdamaged))
        {
            if (m_bFaulted.load())
            {
                precognizer->SetPoisoned();
                (void)precognizer.release();
                std::lock_guard<std::mutex> lock(m_Mutex);
                _Code = m_FaultCode;
                _Message = m_FaultDetail;
                return false;
            }
            _Code = "engine-files";
            _Message =
                error + (m_LastException.empty() ? std::string() : " (" + m_LastException + ")");
            Log("load: " + _Message);
            m_iExceptionRun = 0;
            return false;
        }
        m_pRecognizer = std::move(precognizer);
        m_LoadedConfig = config;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bLoaded = true;
        }
        Log("models loaded in " +
            std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0)
                    .count()) +
            " ms (" +
            std::string(
                Sherpa().SherpaOnnxGetVersionStr ? Sherpa().SherpaOnnxGetVersionStr() : "?") +
            ")");
        return true;
    }

    void LocalEngine::Unload()
    {
        if (!m_pRecognizer)
        {
            return;
        }
        if (m_bFaulted.load())
        {
            m_pRecognizer->SetPoisoned();
            (void)m_pRecognizer.release();
        }
        else
        {
            m_pRecognizer.reset();
            Log("models released");
        }
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_bLoaded = false;
    }

    void LocalEngine::UnloadIfIdle()
    {
        bool bbusy = false;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Listens.erase(
                std::remove_if(m_Listens.begin(), m_Listens.end(),
                    [](const std::weak_ptr<ListenState>& _pWeak) { return _pWeak.expired(); }),
                m_Listens.end());
            for (const std::weak_ptr<ListenState>& pweak : m_Listens)
            {
                if (std::shared_ptr<ListenState> pstate = pweak.lock();
                    pstate && pstate->m_pListener)
                {
                    bbusy = true;
                }
            }
        }
        if (!bbusy)
        {
            Unload();
        }
    }

    void LocalEngine::OnListenText(
        const std::shared_ptr<ListenState>& _pState, const std::string& _Text)
    {
        if (_pState->Closed() || _pState->m_bFailed)
        {
            return;
        }
        if (!_pState->m_pListener)
        {
            std::string code;
            std::string message;
            if (!EnsureLoaded(code, message))
            {
                _pState->m_bFailed = true;
                Json error = ErrorMessage(code, message);
                if (code == "engine-fault" || code == "engine-hung")
                {
                    error.Set("restart", true);
                }
                _pState->Deliver(false, error.Dump());
                _pState->CloseWith(1011, message);
                UnloadIfIdle();
                return;
            }
            std::string voiceprint;
            if (!m_LoadedConfig.m_VoiceprintsDir.empty())
            {
                voiceprint =
                    (fs::u8path(m_LoadedConfig.m_VoiceprintsDir) / "voiceprint.json").u8string();
            }
            std::weak_ptr<ListenState> pweak = _pState;
            _pState->m_pListener = std::make_unique<Listener>(
                *m_pRecognizer, voiceprint,
                [pweak](const Json& _Message)
                {
                    if (std::shared_ptr<ListenState> pstate = pweak.lock())
                    {
                        pstate->Deliver(false, _Message.Dump());
                    }
                },
                [this](const std::string& _Line) { Log(_Line); });
        }
        _pState->m_pListener->OnText(_Text);
        StopAfterFailures();
    }

    void LocalEngine::OnListenAudio(
        const std::shared_ptr<ListenState>& _pState, const std::string& _Pcm)
    {
        {
            std::lock_guard<std::mutex> lock(_pState->m_QueueMutex);
            --_pState->m_iQueued;
            _pState->m_QueueWake.notify_all();
        }
        if (_pState->Closed() || !_pState->m_pListener)
        {
            return;
        }
        _pState->m_pListener->OnAudio(_Pcm);
        StopAfterFailures();
    }

    void LocalEngine::OnListenClosed(const std::shared_ptr<ListenState>& _pState)
    {
        if (_pState->m_pListener)
        {
            Log("listen: closed after " +
                std::to_string(_pState->m_pListener->SamplesHeard() / kRate) + " s of audio");
        }
        _pState->m_pListener.reset();
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Listens.erase(std::remove_if(m_Listens.begin(), m_Listens.end(),
                                [&](const std::weak_ptr<ListenState>& _pWeak)
                                {
                                    std::shared_ptr<ListenState> p = _pWeak.lock();
                                    return !p || p == _pState;
                                }),
                m_Listens.end());
        }
        UnloadIfIdle();
    }

    void LocalEngine::SelfTest(const std::string& _Wav, std::function<void(const Json&)> _Done)
    {
        Post(
            [this, _Wav, _Done]()
            {
                Json result = Json::Object();
                std::string code;
                std::string message;
                const auto t0 = std::chrono::steady_clock::now();
                const bool bwasLoaded = m_pRecognizer != nullptr;
                if (!EnsureLoaded(code, message))
                {
                    result.Set("ok", false).Set("code", code).Set("message", message);
                    UnloadIfIdle();
                    _Done(result);
                    return;
                }
                const double floadMs =
                    std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                        .count();
                std::vector<float> audio;
                std::string error;
                if (!_Wav.empty() && !ReadWav(_Wav, audio, error))
                {
                    result.Set("ok", false).Set("code", "bad-wav").Set("message", error);
                    UnloadIfIdle();
                    _Done(result);
                    return;
                }
                if (audio.empty())
                {
                    // A second of quiet, varying sound: every model gets to run.
                    audio.resize(kRate);
                    for (std::size_t ni = 0; ni < audio.size(); ++ni)
                    {
                        audio[ni] = 0.05f * std::sin(static_cast<float>(ni) * 0.07f) *
                                    std::sin(static_cast<float>(ni) * 0.0011f);
                    }
                }
                Recognizer& recognizer = *m_pRecognizer;
                bool bok = true;
                double fdecodeMs = 0;
                const std::string text =
                    recognizer.Recognize(audio.data(), audio.size(), {}, &fdecodeMs, &bok);
                bool bkeywords = false;
                if (bok && recognizer.KwsReady())
                {
                    const std::string line =
                        recognizer.KeywordLines({recognizer.Config().m_WakeWord}, 0.25f);
                    const SherpaOnnxOnlineStream* pstream = recognizer.CreateKwsStream(line);
                    if (pstream)
                    {
                        recognizer.KwsFeed(pstream, audio.data(), audio.size());
                        recognizer.DestroyKwsStream(pstream);
                        bkeywords = !m_bFaulted.load();
                    }
                }
                bool bspeaker = false;
                if (bok && recognizer.SpeakerReady())
                {
                    bspeaker = !recognizer.Embed(audio.data(), audio.size(), nullptr).empty();
                }
                bool bvad = false;
                if (bok)
                {
                    if (const SherpaOnnxVoiceActivityDetector* pvad = recognizer.CreateVad())
                    {
                        bool bspeech = false;
                        std::vector<SpeechSegment> segments;
                        bvad =
                            recognizer.VadFeed(pvad, audio.data(), audio.size(), bspeech, segments);
                        recognizer.DestroyVad(pvad);
                    }
                }
                bok = bok && bvad && bkeywords && !m_bFaulted.load();
                result.Set("ok", bok)
                    .Set("loadMs", std::round(floadMs))
                    .Set("decodeMs", std::round(fdecodeMs))
                    .Set("text", text)
                    .Set("keywords", bkeywords)
                    .Set("speaker", bspeaker)
                    .Set("wasLoaded", bwasLoaded);
                if (!bok)
                {
                    const EngineState state = State();
                    result.Set(
                        "code", state.m_bFaulted ? state.m_FaultCode : std::string("engine-files"));
                    result.Set("message",
                        state.m_bFaulted ? state.m_FaultDetail
                                         : (m_LastException.empty() ? std::string("a model failed")
                                                                    : m_LastException));
                }
                Log(std::string("self test: ") + (bok ? "passed" : "failed") + ", decode " +
                    std::to_string(static_cast<int>(fdecodeMs)) + " ms");
                UnloadIfIdle();
                _Done(result);
            });
    }

    namespace
    {

        // A voice name: letters, digits, - and _ (a file name in voicesDir).
        bool ValidVoiceName(const std::string& _Name)
        {
            if (_Name.empty() || _Name.size() > 64)
            {
                return false;
            }
            for (char c : _Name)
            {
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                        c == '-' || c == '_'))
                {
                    return false;
                }
            }
            return true;
        }

    } // namespace

    // ---- Small voices (speaking thread) -------------------------------------------

    struct LocalEngine::SmallState
    {
        std::map<std::string, std::unique_ptr<SmallVoice>> m_Voices;
        std::map<std::string, std::string> m_LoadErrors; // a failed load, until the settings change
        std::string m_LoadedFrom;                        // the settings they loaded with
    };

    bool LocalEngine::PrepareSmall(std::string& _Error)
    {
        TakeLastCrash(); // before the marker is reused
        if (!m_bSpeakMarkerOpen)
        {
            m_bSpeakMarkerOpen =
                m_SpeakMarker.Open((fs::u8path(m_StateDir) / "voice-state-speak").u8string());
        }
        {
            std::lock_guard<std::mutex> lock(m_LogMutex);
            OpenLog();
        }
        return LoadSherpa(m_LibraryDir, _Error);
    }

    void LocalEngine::UnloadSmall()
    {
        if (!m_pSmall)
        {
            return;
        }
        if (m_bFaulted.load())
        {
            for (auto& entry : m_pSmall->m_Voices)
            {
                entry.second->SetPoisoned();
            }
        }
        m_pSmall.reset();
    }

    SmallVoice* LocalEngine::FindSmall(const std::string& _Name, std::string& _Error)
    {
        if (m_bFaulted.load())
        {
            _Error = "the speech engine stopped after an internal error";
            return nullptr;
        }
        Json small;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            small = m_Small;
        }
        if (!small.IsObject())
        {
            _Error = "the built-in voice isn't set up";
            return nullptr;
        }
        if (!ValidVoiceName(_Name))
        {
            _Error = "no voice called " + _Name;
            return nullptr;
        }
        const std::string settings = small.Dump();
        if (m_pSmall && m_pSmall->m_LoadedFrom != settings)
        {
            UnloadSmall(); // the settings changed: load again
        }
        if (!m_pSmall)
        {
            m_pSmall = std::make_unique<SmallState>();
            m_pSmall->m_LoadedFrom = settings;
        }
        SmallState& state = *m_pSmall;
        auto failed = state.m_LoadErrors.find(_Name);
        if (failed != state.m_LoadErrors.end())
        {
            _Error = failed->second;
            return nullptr;
        }
        auto it = state.m_Voices.find(_Name);
        if (it == state.m_Voices.end())
        {
            std::string error;
            if (!PrepareSmall(error))
            {
                _Error = error;
                Log("speak: " + error);
                return nullptr;
            }
            const int ithreads = static_cast<int>(
                std::min<int64_t>(16, std::max<int64_t>(1, small["threads"].AsInt(2))));
            const auto t0 = std::chrono::steady_clock::now();
            auto pvoice = std::make_unique<SmallVoice>(
                (fs::u8path(small["voicesDir"].AsString()) / fs::u8path(_Name)).u8string(),
                ithreads,
                [this](const char* _szName, std::chrono::milliseconds _Limit,
                    const std::function<void()>& _Fn) { return Call(_szName, _Limit, _Fn); });
            if (!pvoice->Load(error))
            {
                if (m_bFaulted.load())
                {
                    pvoice->SetPoisoned();
                }
                error += m_SpeakException.empty() ? std::string() : " (" + m_SpeakException + ")";
                state.m_LoadErrors[_Name] = error;
                _Error = error;
                Log("speak: the small voice " + _Name + " didn't load: " + error);
                return nullptr;
            }
            Log("speak: small voice " + _Name + " loaded in " +
                std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - t0)
                        .count()) +
                " ms");
            it = state.m_Voices.emplace(_Name, std::move(pvoice)).first;
        }
        return it->second.get();
    }

    void LocalEngine::WarmSmall(const std::string& _Name)
    {
        PostSpeak(
            [this, _Name]()
            {
                std::string error;
                FindSmall(_Name, error); // a failed load is logged, and its say says why
            });
    }

    bool LocalEngine::SmallSay(const std::string& _Phonemes, const std::string& _Name,
        double _fSpeed, double _fWobble, std::vector<float>& _Audio, std::string& _Error)
    {
        SmallVoice* pvoice = FindSmall(_Name, _Error);
        if (!pvoice)
        {
            return false;
        }
        const auto t0 = std::chrono::steady_clock::now();
        const bool bok = pvoice->Say(_Phonemes, _fSpeed, _fWobble, _Audio, _Error);
        const double fms =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                .count();
        char abuf[160];
        std::snprintf(abuf, sizeof(abuf), "speak: %zu phonemes, %.2f s of audio in %.0f ms%s",
            pvoice->LastIds(), static_cast<double>(_Audio.size()) / kSmallVoiceRate, fms,
            bok ? "" : " (failed)");
        Log(abuf);
        if (!bok && !m_SpeakException.empty())
        {
            _Error += " (" + m_SpeakException + ")";
        }
        return bok;
    }

} // namespace gitgud::speech
