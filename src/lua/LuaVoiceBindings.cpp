// -----------------------------------------------------------------------------
// LuaVoiceBindings: voice input and spoken replies (voice/VoiceSession.h) for
// scripts, over the links the speech engine provides (voice/Link.h): the
// one inside the app (speech/LocalEngine.h) when its libraries are in the
// `voice` folder beside the exe, else none (voiceInfo().available is false
// and voiceListen, voiceSpeak, and voiceSpeakPrepare fail). With
// GITGUD_TEST_VOICE=fake (or =fault), a stand-in engine (speech/FakeEngine.h).
//
//   gitgud.voiceListen(options?)   -> true | nil, msg. Opens the listen
//                                     channel and, once the engine is ready,
//                                     the echo-cancelled microphone. options:
//                                     hello fields (wakeWord, closingPhrase,
//                                     contextTokens, messageContextTokens,
//                                     lookbackTokens, endWaitSeconds,
//                                     mishearings, wakeThreshold,
//                                     vocabulary; any field passes through)
//   gitgud.voiceStop()             mic off, listen channel closed
//   gitgud.voiceConfig(fields)     -> true | nil, msg (hello fields changed)
//   gitgud.voiceWake() / voiceSend(reason?) / voiceCancel()
//                                  -> true | nil, msg: start a message now,
//                                     end it now ("button" or "done"), drop it
//   gitgud.voiceLookback(id, tokens?)
//                                  -> true | nil, msg; "voice.lookback" answers
//   gitgud.voiceRecord(path?)      -> true | nil, msg. Saves the mic audio
//                                     as the engine gets it to a WAV file at
//                                     path (16 kHz mono 16-bit) until called
//                                     without one or listening stops; then
//                                     "voice.record" ({state: off, path,
//                                     seconds})
//   gitgud.voiceTrain(state) / voiceEnroll(state)
//                                  -> true | nil, msg (wake word training:
//                                     start, stop; enrollment: start, stop,
//                                     clear)
//   gitgud.voiceSpeak(id, text, options?)
//                                  -> true | nil, msg. Speaks through the
//                                     speak channel (opened on first use).
//                                     options: { voice, sampleRate, speed
//                                     (1 is normal pace), voicing (a small
//                                     voice's {wobble, rough, roughLow,
//                                     roughHigh}) }. A "small:<name>"
//                                     voice's text is its phonemes, and
//                                     sampleRate is the rate it plays at
//   gitgud.voiceSpeakPrepare()     -> true | nil, msg. Opens the speak channel
//                                     and the speaker now (when listening
//                                     starts), so the first reply is quick
//   gitgud.voiceSpeakStop(id?)     stop that reply, or all of them
//   gitgud.voiceInfo()             -> { available, listening, speaking,
//                                       playing }; available: a speech
//                                     engine is there to talk to
//   gitgud.audioDevices()          -> { inputs = { {id, name, default}, ... },
//                                       outputs = { ... } }: microphones and
//                                     speakers plugged in (empty lists where
//                                     devices can't be listed)
//   gitgud.setAudioDevices(input, output)
//                                  the devices voice opens from its next
//                                     start; "" or nil is the system default.
//                                     A new speaker closes the speak channel
//                                     (the next voiceSpeak reopens it there)
//   gitgud.micTest(on)             -> true | nil, msg. While on, the chosen
//                                     microphone (no engine needed) reports
//                                     "audio.level" ten times a second: its
//                                     level, 0 to 1, as text
//
// The engine inside the app (nothing here loads it; its libraries and
// models load when listening starts). Tests use a stand-in: GITGUD_TEST_VOICE
// or gitgud.voiceTestEngine("fake" | "fault" | nil), under the harness only.
//   gitgud.voiceEngine()           -> { installed, configured, loaded,
//                                       faulted, faultCode, fault, gpu,
//                                       runtimeDir, turbo, turboDevice,
//                                       gpuError, test, lastCrash }: installed, its
//                                     libraries are there; faulted, it
//                                     stopped after an internal error (until
//                                     the app restarts); test, "fake" or
//                                     "fault" for the stand-in; lastCrash
//                                     ({call, log}), what it was doing when
//                                     the app ended without warning last time
//   gitgud.voiceEngineSetup(settings)
//                                  -> true | nil, msg: where the models are
//                                     (vadModel, asrDir, kwsDir,
//                                     speakerModel, voiceprintsDir, workDir),
//                                     the files to check first ({path, size,
//                                     sha256}), and listening settings
//   gitgud.voiceSelfTest(task, wav?)
//                                  -> true | nil, msg. Loads and runs every
//                                     model; "<task>.done" carries {ok,
//                                     loadMs, decodeMs, text, keywords,
//                                     speaker, code?, message?}
//   gitgud.voiceVoices()           -> { {id, name, language}, ... } | nil, msg:
//                                     the voices replies can be spoken in
//   gitgud.voiceEngineRelease()    unload the models (before removing them)
//   gitgud.voiceEngineForgetCrash()
//                                  the last run's crash (lastCrash) isn't
//                                  reported again this run
//
// Events carry JSON text. The listen channel's are "voice.<type>" (ready, vad,
// wake, partial, message, cancelled, ambient, lookback, trainSample,
// trainResult, enrollSample, enrollResult, error) plus "voice.mic" ({state:
// on|off, device, route?}), "voice.level" ({t, rms, max}: each second of the
// mic, in dBFS), "voice.drop" ({t, until, count, queued, sendingMs}: mic audio
// the link didn't take in time, dropped oldest first), "voice.record"
// (voiceRecord) and "voice.closed" ({code, reason}). The speak channel's are
// "voice.speech.<type>" (start, end, stopped, error, closed). "voice.playback"
// ({state: started|stopped, id}) is also told to the listen channel, so the
// engine knows the app's own voice when it hears it. Local failures are
// errors with code "connect", "audio", "no-ready", or "send" (a send failed
// on the link; the session then closes).
// -----------------------------------------------------------------------------

#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

#include "app/EventBus.h"
#include "app/Json.h"
#include "app/TaskRunner.h"
#include "lua/LuaBindings.h"
#include "platform/Audio.h"
#include "platform/Gpu.h"
#include "speech/FakeEngine.h"
#include "speech/LocalEngine.h"
#include "speech/OnnxPatch.h"
#include "speech/SherpaApi.h"
#include "voice/Pcm.h"
#include "voice/VoiceSession.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <algorithm>
#include <vector>

namespace gitgud::lua::bindings
{

    namespace
    {

        using app::Json;
        using voice::ListenSession;
        using voice::SpeakSession;

        // The speech engine's links: the app's own engine, or what a test
        // set (SetVoiceLink).
        voice::LinkFactory g_MakeLink;
        bool g_bLinkSet = false;
        // How long the engine may take to answer hello: the app's own loads
        // its models first.
        std::chrono::milliseconds g_ReadyTimeout{15000};

        // The stand-in engine: "fake" or "fault" (GITGUD_TEST_VOICE, or
        // gitgud.voiceTestEngine under the test harness), else "".
        bool g_bTestVoiceRead = false;
        std::string g_TestVoice;

        std::string TestVoice()
        {
            if (!g_bTestVoiceRead)
            {
                g_bTestVoiceRead = true;
                const char* szvalue = std::getenv("GITGUD_TEST_VOICE");
                const std::string value = szvalue ? szvalue : "";
                g_TestVoice = value == "fake" || value == "fault" ? value : std::string();
            }
            return g_TestVoice;
        }

        // The first time voice is asked for: the stand-in for tests, or the
        // app's engine when its libraries are there (only the files are
        // checked; nothing loads).
        void ChooseLink()
        {
            if (g_bLinkSet)
            {
                return;
            }
            g_bLinkSet = true;
            const std::string test = TestVoice();
            if (!test.empty())
            {
                const bool bfault = test == "fault";
                g_MakeLink = [bfault](const std::string& _Channel) { return speech::MakeFakeLink(_Channel, bfault); };
                return;
            }
            if (speech::LocalEngine::Instance().Installed())
            {
                g_MakeLink = [](const std::string& _Channel)
                { return speech::LocalEngine::Instance().MakeLink(_Channel); };
                g_ReadyTimeout = std::chrono::minutes(3);
            }
        }

        std::function<std::unique_ptr<platform::IAudioCapture>()> g_MakeCapture;
        std::function<std::unique_ptr<platform::IAudioPlayback>()> g_MakePlayback;

        // The speak channel's thread reports playback to the listen channel,
        // so the listen session is shared under a lock.
        std::mutex g_ListenMutex;
        std::shared_ptr<ListenSession> g_pListen;
        std::unique_ptr<SpeakSession> g_pSpeak;
        app::EventBus* g_pSpeakBus = nullptr;

        // The microphone check's capture, while it runs.
        std::unique_ptr<platform::IAudioCapture> g_pMicTest;

        // Quiet devices with the real engine: the harness only
        // (GITGUD_SCRIPT and GITGUD_TEST_QUIET_AUDIO), for runs of the real
        // models that must not use the room's microphone or speakers.
        bool QuietAudio()
        {
            static const bool bquiet = std::getenv("GITGUD_SCRIPT") && std::getenv("GITGUD_TEST_QUIET_AUDIO");
            return bquiet;
        }

        // The stand-in engine comes with quiet devices: tests never open a
        // real microphone or speaker.
        std::unique_ptr<platform::IAudioCapture> MakeCapture()
        {
            if (g_MakeCapture)
            {
                return g_MakeCapture();
            }
            return TestVoice().empty() && !QuietAudio() ? platform::MakeVoiceCapture()
                                                        : speech::MakeQuietCapture();
        }

        std::unique_ptr<platform::IAudioPlayback> MakePlayback()
        {
            if (g_MakePlayback)
            {
                return g_MakePlayback();
            }
            return TestVoice().empty() && !QuietAudio() ? platform::MakePlayback()
                                                        : speech::MakeQuietPlayback();
        }

        std::shared_ptr<ListenSession> Listening()
        {
            std::lock_guard<std::mutex> lock(g_ListenMutex);
            return g_pListen && g_pListen->Running() ? g_pListen : nullptr;
        }

        void StopListen()
        {
            std::shared_ptr<ListenSession> plisten;
            {
                std::lock_guard<std::mutex> lock(g_ListenMutex);
                plisten = std::move(g_pListen);
            }
            if (plisten)
            {
                plisten->Stop();
            }
        }

        // An optional table argument as JSON (nil: an empty object).
        bool OptionalJson(lua_State* _pL, int _iArg, Json& _Out, std::string& _Error)
        {
            if (lua_isnoneornil(_pL, _iArg))
            {
                _Out = Json::Object();
                return true;
            }
            if (!lua_istable(_pL, _iArg))
            {
                _Error = "options must be a table";
                return false;
            }
            try
            {
                _Out = LuaToJson(_pL, _iArg);
            }
            catch (const std::exception& e)
            {
                _Error = e.what();
                return false;
            }
            if (_Out.GetType() != Json::Type::Object)
            {
                _Out = Json::Object(); // an empty table
            }
            return true;
        }

        int Ok(lua_State* _pL)
        {
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int NotListening(lua_State* _pL)
        {
            return FailWith(_pL, "Voice input is off");
        }

        int LVoiceListen(lua_State* _pL)
        {
            Json options;
            std::string error;
            if (!OptionalJson(_pL, 1, options, error))
            {
                return FailWith(_pL, error);
            }
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return FailWith(_pL, "no event bus");
            }
            ChooseLink();
            if (!g_MakeLink)
            {
                return FailWith(_pL, "Voice isn't available");
            }
            if (Listening())
            {
                return FailWith(_pL, "Voice input is already on");
            }
            StopListen(); // one that ended on its own
            auto plisten = std::make_shared<ListenSession>(g_MakeLink, [pbus](const Json& _Event)
                { pbus->Publish({"voice." + _Event["type"].AsString(), _Event.Dump()}); });
            plisten->SetReadyTimeout(g_ReadyTimeout);
            {
                std::lock_guard<std::mutex> lock(g_ListenMutex);
                g_pListen = plisten;
            }
            if (!plisten->Start(options, MakeCapture()))
            {
                StopListen();
                return FailWith(_pL, "Voice input could not start");
            }
            return Ok(_pL);
        }

        int LVoiceStop(lua_State*)
        {
            StopListen();
            return 0;
        }

        int LVoiceConfig(lua_State* _pL)
        {
            luaL_checktype(_pL, 1, LUA_TTABLE);
            Json fields;
            std::string error;
            if (!OptionalJson(_pL, 1, fields, error))
            {
                return FailWith(_pL, error);
            }
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            plisten->Config(fields);
            return Ok(_pL);
        }

        int LVoiceRecord(lua_State* _pL)
        {
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            if (lua_isnoneornil(_pL, 1))
            {
                plisten->StopRecording();
                return Ok(_pL);
            }
            std::string error;
            if (!plisten->Record(luaL_checkstring(_pL, 1), error))
            {
                return FailWith(_pL, error);
            }
            return Ok(_pL);
        }

        // voiceWake, voiceCancel.
        template <void (ListenSession::*Method)()> int LListenCommand(lua_State* _pL)
        {
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            ((*plisten).*Method)();
            return Ok(_pL);
        }

        int LVoiceSend(lua_State* _pL)
        {
            const std::string reason = luaL_optstring(_pL, 1, "");
            if (!reason.empty() && reason != "button" && reason != "done")
            {
                return FailWith(_pL, "reason is button or done");
            }
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            plisten->SendNow(reason);
            return Ok(_pL);
        }

        int LVoiceLookback(lua_State* _pL)
        {
            const std::string id = luaL_checkstring(_pL, 1);
            const int itokens =
                lua_isnoneornil(_pL, 2) ? -1 : static_cast<int>(luaL_checkinteger(_pL, 2));
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            plisten->Lookback(id, itokens);
            return Ok(_pL);
        }

        int LVoiceTrain(lua_State* _pL)
        {
            const std::string state = luaL_checkstring(_pL, 1);
            if (state != "start" && state != "stop")
            {
                return FailWith(_pL, "state must be start or stop");
            }
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            plisten->Train(state);
            return Ok(_pL);
        }

        int LVoiceEnroll(lua_State* _pL)
        {
            const std::string state = luaL_checkstring(_pL, 1);
            if (state != "start" && state != "stop" && state != "clear")
            {
                return FailWith(_pL, "state must be start, stop, or clear");
            }
            auto plisten = Listening();
            if (!plisten)
            {
                return NotListening(_pL);
            }
            plisten->Enroll(state);
            return Ok(_pL);
        }

        // The speak session for this Lua state's bus, made on first use;
        // "" or the reason it can't be.
        std::string EnsureSpeak(lua_State* _pL)
        {
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return "no event bus";
            }
            ChooseLink();
            if (!g_MakeLink)
            {
                return "Voice isn't available";
            }
            if (g_pSpeak && g_pSpeakBus != pbus)
            {
                g_pSpeak.reset();
            }
            if (!g_pSpeak)
            {
                g_pSpeakBus = pbus;
                g_pSpeak = std::make_unique<SpeakSession>(
                    g_MakeLink,
                    [pbus](const Json& _Event)
                    {
                        const std::string& type = _Event["type"].AsString();
                        if (type == "playback")
                        {
                            if (auto plisten = Listening())
                            {
                                plisten->Playback(_Event["state"].AsString(),
                                    _Event["id"].AsString(), _Event["text"].AsString());
                            }
                            pbus->Publish({"voice.playback", _Event.Dump()});
                            return;
                        }
                        pbus->Publish({"voice.speech." + type, _Event.Dump()});
                    },
                    MakePlayback());
            }
            return {};
        }

        int LVoiceSpeak(lua_State* _pL)
        {
            const std::string id = luaL_checkstring(_pL, 1);
            const std::string text = luaL_checkstring(_pL, 2);
            Json options;
            std::string error;
            if (!OptionalJson(_pL, 3, options, error))
            {
                return FailWith(_pL, error);
            }
            error = EnsureSpeak(_pL);
            if (!error.empty())
            {
                return FailWith(_pL, error);
            }
            g_pSpeak->Say(id, text, options["voice"].AsString(),
                static_cast<int>(options["sampleRate"].AsInt(0)), options["speed"].AsNumber(0.0),
                options["voicing"]);
            return Ok(_pL);
        }

        int LVoiceSpeakPrepare(lua_State* _pL)
        {
            const std::string error = EnsureSpeak(_pL);
            if (!error.empty())
            {
                return FailWith(_pL, error);
            }
            g_pSpeak->Prepare();
            return Ok(_pL);
        }

        int LVoiceSpeakStop(lua_State* _pL)
        {
            const std::string id = luaL_optstring(_pL, 1, "");
            if (g_pSpeak)
            {
                g_pSpeak->StopSpeech(id);
            }
            return 0;
        }

        void PushDevices(lua_State* _pL, bool _bCapture)
        {
            lua_newtable(_pL);
            lua_Integer ii = 1;
            for (const platform::AudioDevice& device : platform::ListAudioDevices(_bCapture))
            {
                lua_newtable(_pL);
                SetField(_pL, "id", device.m_Id);
                SetField(_pL, "name", device.m_Name);
                SetField(_pL, "default", device.m_bDefault);
                lua_rawseti(_pL, -2, ii++);
            }
        }

        int LAudioDevices(lua_State* _pL)
        {
            lua_newtable(_pL);
            PushDevices(_pL, true);
            lua_setfield(_pL, -2, "inputs");
            PushDevices(_pL, false);
            lua_setfield(_pL, -2, "outputs");
            return 1;
        }

        int LSetAudioDevices(lua_State* _pL)
        {
            std::string capture;
            std::string render;
            platform::ChosenAudioDevices(capture, render);
            const std::string newRender = luaL_optstring(_pL, 2, "");
            platform::SetAudioDevices(luaL_optstring(_pL, 1, ""), newRender);
            // The speak channel keeps its speaker open: close it, so the next
            // reply plays where the echo canceller now listens.
            if (newRender != render)
            {
                g_pSpeak.reset();
                g_pSpeakBus = nullptr;
            }
            return 0;
        }

        int LMicTest(lua_State* _pL)
        {
            const bool bon = lua_toboolean(_pL, 1) != 0;
            if (g_pMicTest)
            {
                g_pMicTest->Stop();
                g_pMicTest.reset();
            }
            if (!bon)
            {
                return Ok(_pL);
            }
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return FailWith(_pL, "no event bus");
            }
            auto pcapture = g_MakeCapture ? g_MakeCapture() : platform::MakePlainCapture();
            // Runs on the capture thread: a level every 100 ms.
            auto pending = std::make_shared<std::vector<int16_t>>();
            auto onSamples = [pbus, pending](const int16_t* _pSamples, std::size_t _nCount)
            {
                pending->insert(pending->end(), _pSamples, _pSamples + _nCount);
                constexpr std::size_t kTenth = voice::kListenRate / 10;
                while (pending->size() >= kTenth)
                {
                    char aLevel[16];
                    std::snprintf(aLevel, sizeof(aLevel), "%.3f",
                        voice::Level(pending->data(), kTenth));
                    pending->erase(pending->begin(), pending->begin() + kTenth);
                    pbus->Publish({"audio.level", aLevel});
                }
            };
            std::string error;
            if (!pcapture->Start(voice::kListenRate, onSamples, error))
            {
                return FailWith(_pL, error.empty() ? "The microphone could not start" : error);
            }
            g_pMicTest = std::move(pcapture);
            return Ok(_pL);
        }

        int LVoiceEngine(lua_State* _pL)
        {
            ChooseLink();
            lua_newtable(_pL);
            const std::string test = TestVoice();
            if (!test.empty())
            {
                SetField(_pL, "installed", true);
                SetField(_pL, "configured", true);
                SetField(_pL, "loaded", false);
                SetField(_pL, "faulted", false);
                SetField(_pL, "test", test);
                return 1;
            }
            speech::LocalEngine& engine = speech::LocalEngine::Instance();
            const speech::EngineState state = engine.State();
            SetField(_pL, "installed", state.m_bInstalled);
            SetField(_pL, "configured", state.m_bConfigured);
            SetField(_pL, "loaded", state.m_bLoaded);
            SetField(_pL, "faulted", state.m_bFaulted);
            SetField(_pL, "gpu", speech::SherpaOnGpu());
            SetField(_pL, "runtimeDir", speech::SherpaDir());
            SetField(_pL, "turboDevice", state.m_TurboDevice);
            if (!state.m_GpuError.empty())
            {
                SetField(_pL, "gpuError", state.m_GpuError);
            }
            SetField(_pL, "turbo", engine.TurboConfigured());
            if (state.m_bFaulted)
            {
                SetField(_pL, "faultCode", state.m_FaultCode);
                SetField(_pL, "fault", state.m_FaultDetail);
            }
            const speech::LastCrash crash = state.m_bInstalled ? engine.TakeLastCrash() : speech::LastCrash{};
            if (!crash.m_Call.empty())
            {
                lua_newtable(_pL);
                SetField(_pL, "call", crash.m_Call);
                SetField(_pL, "log", crash.m_LogTail);
                lua_setfield(_pL, -2, "lastCrash");
            }
            return 1;
        }

        int LVoiceEngineSetup(lua_State* _pL)
        {
            luaL_checktype(_pL, 1, LUA_TTABLE);
            Json settings;
            std::string error;
            if (!OptionalJson(_pL, 1, settings, error))
            {
                return FailWith(_pL, error);
            }
            if (!TestVoice().empty())
            {
                return Ok(_pL);
            }
            if (!speech::LocalEngine::Instance().Configure(settings, error))
            {
                return FailWith(_pL, error);
            }
            return Ok(_pL);
        }

        int LVoiceSelfTest(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            const std::string wav = luaL_optstring(_pL, 2, "");
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return FailWith(_pL, "no event bus");
            }
            if (!TestVoice().empty())
            {
                pbus->Publish({task + ".done", Json::Object()
                                                   .Set("ok", true)
                                                   .Set("loadMs", 1)
                                                   .Set("decodeMs", 1)
                                                   .Set("text", "")
                                                   .Set("keywords", true)
                                                   .Set("speaker", true)
                                                   .Dump()});
                return Ok(_pL);
            }
            speech::LocalEngine& engine = speech::LocalEngine::Instance();
            if (!engine.Installed())
            {
                return FailWith(_pL, "the voice libraries aren't installed");
            }
            engine.SelfTest(wav, [pbus, task](const Json& _Result) { pbus->Publish({task + ".done", _Result.Dump()}); });
            return Ok(_pL);
        }

        int LVoiceVoices(lua_State* _pL)
        {
            std::string error;
            const std::vector<speech::VoiceInfo> voices = speech::LocalEngine::Instance().Voices(error);
            if (voices.empty() && !error.empty())
            {
                return FailWith(_pL, error);
            }
            lua_createtable(_pL, static_cast<int>(voices.size()), 0);
            lua_Integer i = 0;
            for (const speech::VoiceInfo& info : voices)
            {
                lua_newtable(_pL);
                SetField(_pL, "id", info.m_Id);
                SetField(_pL, "name", info.m_Name);
                SetField(_pL, "language", info.m_Language);
                lua_rawseti(_pL, -2, ++i);
            }
            return 1;
        }

        // Tests (GITGUD_SCRIPT set): the stand-in engine from now on ("fake"
        // or "fault"), or the app's own (nil).
        int LVoiceTestEngine(lua_State* _pL)
        {
            const char* szscript = std::getenv("GITGUD_SCRIPT");
            if (!szscript || !*szscript)
            {
                return FailWith(_pL, "only under the test harness");
            }
            const std::string mode = luaL_optstring(_pL, 1, "");
            if (!mode.empty() && mode != "fake" && mode != "fault")
            {
                return FailWith(_pL, "fake, fault, or nil");
            }
            StopListen();
            g_pSpeak.reset();
            g_bTestVoiceRead = true;
            g_TestVoice = mode;
            g_bLinkSet = false;
            g_MakeLink = nullptr;
            g_ReadyTimeout = std::chrono::milliseconds(15000);
            ChooseLink();
            return Ok(_pL);
        }

        // gitgud.voiceMakeVoice(task, wav, name) -> true | nil, msg
        int LVoiceMakeVoice(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            const std::string wav = luaL_checkstring(_pL, 2);
            const std::string name = luaL_checkstring(_pL, 3);
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return FailWith(_pL, "no event bus");
            }
            if (!TestVoice().empty())
            {
                pbus->Publish({task + ".done", Json::Object().Set("ok", true).Set("seconds", 10).Dump()});
                return Ok(_pL);
            }
            speech::LocalEngine& engine = speech::LocalEngine::Instance();
            if (!engine.TurboConfigured())
            {
                return FailWith(_pL, "spoken replies in a made voice aren't set up");
            }
            engine.MakeVoice(wav, name, [pbus, task](const Json& _Result) { pbus->Publish({task + ".done", _Result.Dump()}); });
            return Ok(_pL);
        }

        // gitgud.gpuInfo() -> { present, driver, cuda, devices = { {name, memory}, ... }, error? }
        int LGpuInfo(lua_State* _pL)
        {
            const platform::NvidiaInfo info = platform::QueryNvidia();
            lua_newtable(_pL);
            SetField(_pL, "present", info.m_bPresent);
            SetField(_pL, "driver", info.m_Driver);
            SetField(_pL, "cuda", static_cast<lua_Integer>(info.m_iCudaVersion));
            if (!info.m_Error.empty())
            {
                SetField(_pL, "error", info.m_Error);
            }
            lua_createtable(_pL, static_cast<int>(info.m_Devices.size()), 0);
            lua_Integer i = 0;
            for (const platform::GpuDevice& device : info.m_Devices)
            {
                lua_newtable(_pL);
                SetField(_pL, "name", device.m_Name);
                SetField(_pL, "memory", static_cast<lua_Integer>(device.m_uMemoryBytes));
                lua_rawseti(_pL, -2, ++i);
            }
            lua_setfield(_pL, -2, "devices");
            return 1;
        }

        // gitgud.onnxSetAccuracy(in, out, level) -> nodes changed | nil, msg
        // gitgud.onnxSetAccuracy(in, out, level, task) -> true | nil, msg: on
        // a worker; "<task>.progress" ({phase = "patch", done, total}: bytes
        // read and written) and "<task>.done" (nodes changed) or ".error".
        int LOnnxSetAccuracy(lua_State* _pL)
        {
            const std::string in = luaL_checkstring(_pL, 1);
            const std::string out = luaL_checkstring(_pL, 2);
            const int ilevel = static_cast<int>(luaL_checkinteger(_pL, 3));
            if (lua_isnoneornil(_pL, 4))
            {
                int ichanged = 0;
                std::string error;
                if (!speech::SetMatMulNBitsAccuracy(in, out, ilevel, ichanged, error))
                {
                    return FailWith(_pL, error);
                }
                lua_pushinteger(_pL, ichanged);
                return 1;
            }
            const std::string task = luaL_checkstring(_pL, 4);
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                return FailWith(_pL, "no task runner");
            }
            app::EventBus* pbus = Self(_pL)->EventBus();
            ptasks->Run(task,
                [task, in, out, ilevel, pbus]() -> std::string
                {
                    auto last = std::chrono::steady_clock::time_point{};
                    auto report = [&](std::uint64_t _uDone, std::uint64_t _uTotal, bool _bForce)
                    {
                        const auto now = std::chrono::steady_clock::now();
                        if (!pbus || (!_bForce && now - last < std::chrono::milliseconds(200)))
                        {
                            return;
                        }
                        last = now;
                        pbus->Publish({task + ".progress", Json::Object()
                                                               .Set("phase", "patch")
                                                               .Set("done", static_cast<double>(_uDone))
                                                               .Set("total", static_cast<double>(_uTotal))
                                                               .Dump()});
                    };
                    namespace fs = std::filesystem;
                    std::error_code ec;
                    const std::uint64_t usize = fs::file_size(fs::u8path(in), ec);
                    std::ifstream file(fs::u8path(in), std::ios::binary);
                    if (ec || !file)
                    {
                        throw std::runtime_error("cannot read " + in);
                    }
                    // Read, patch in memory, write: progress over both passes.
                    std::string model(static_cast<std::size_t>(usize), '\0');
                    constexpr std::size_t kChunk = 8u << 20;
                    for (std::size_t nat = 0; nat < model.size(); nat += kChunk)
                    {
                        const std::size_t n = std::min(kChunk, model.size() - nat);
                        if (!file.read(model.data() + nat, static_cast<std::streamsize>(n)))
                        {
                            throw std::runtime_error("cannot read " + in);
                        }
                        report(nat + n, 2 * usize, false);
                    }
                    std::string patched;
                    int ichanged = 0;
                    if (!speech::SetMatMulNBitsAccuracyBytes(model, ilevel, patched, ichanged))
                    {
                        throw std::runtime_error(in + " isn't an ONNX model");
                    }
                    model.clear();
                    model.shrink_to_fit();
                    const fs::path part = fs::u8path(out + ".part");
                    {
                        std::ofstream dest(part, std::ios::binary | std::ios::trunc);
                        for (std::size_t nat = 0; dest && nat < patched.size(); nat += kChunk)
                        {
                            const std::size_t n = std::min(kChunk, patched.size() - nat);
                            dest.write(patched.data() + nat, static_cast<std::streamsize>(n));
                            report(usize + (nat + n) * usize / std::max<std::size_t>(1, patched.size()),
                                2 * usize, false);
                        }
                        if (!dest)
                        {
                            fs::remove(part, ec);
                            throw std::runtime_error("cannot write " + out);
                        }
                    }
                    fs::remove(fs::u8path(out), ec);
                    fs::rename(part, fs::u8path(out), ec);
                    if (ec)
                    {
                        throw std::runtime_error("cannot write " + out + ": " + ec.message());
                    }
                    report(2 * usize, 2 * usize, true);
                    return std::to_string(ichanged);
                });
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.voiceEngineForgetCrash(): the user turned voice back on; the
        // last run's crash isn't reported again (voiceEngine().lastCrash).
        int LVoiceEngineForgetCrash(lua_State*)
        {
            if (TestVoice().empty())
            {
                speech::LocalEngine::Instance().ForgetLastCrash();
            }
            return 0;
        }

        int LVoiceEngineRelease(lua_State*)
        {
            if (TestVoice().empty())
            {
                speech::LocalEngine::Instance().ReleaseModels(std::chrono::seconds(10));
            }
            return 0;
        }

        int LVoiceInfo(lua_State* _pL)
        {
            ChooseLink();
            lua_newtable(_pL);
            SetField(_pL, "available", static_cast<bool>(g_MakeLink));
            SetField(_pL, "listening", Listening() != nullptr);
            SetField(_pL, "speaking", g_pSpeak && g_pSpeak->Running());
            SetField(_pL, "playing", g_pSpeak ? g_pSpeak->PlayingId() : std::string());
            return 1;
        }

    } // namespace

    void StopVoice()
    {
        if (g_pMicTest)
        {
            g_pMicTest->Stop();
            g_pMicTest.reset();
        }
        StopListen();
        g_pSpeak.reset();
        g_pSpeakBus = nullptr;
    }

    void SetVoiceAudio(std::function<std::unique_ptr<platform::IAudioCapture>()> _MakeCapture,
        std::function<std::unique_ptr<platform::IAudioPlayback>()> _MakePlayback)
    {
        g_MakeCapture = std::move(_MakeCapture);
        g_MakePlayback = std::move(_MakePlayback);
    }

    void SetVoiceLink(voice::LinkFactory _MakeLink)
    {
        StopVoice(); // its sessions talk over the old links
        g_MakeLink = std::move(_MakeLink);
        g_bLinkSet = true;
        g_ReadyTimeout = std::chrono::milliseconds(15000);
    }

    void AddVoiceBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"voiceListen", LVoiceListen});
        _Out.push_back({"voiceStop", LVoiceStop});
        _Out.push_back({"voiceConfig", LVoiceConfig});
        _Out.push_back({"voiceRecord", LVoiceRecord});
        _Out.push_back({"voiceWake", LListenCommand<&ListenSession::Wake>});
        _Out.push_back({"voiceSend", LVoiceSend});
        _Out.push_back({"voiceCancel", LListenCommand<&ListenSession::Cancel>});
        _Out.push_back({"voiceLookback", LVoiceLookback});
        _Out.push_back({"voiceTrain", LVoiceTrain});
        _Out.push_back({"voiceEnroll", LVoiceEnroll});
        _Out.push_back({"voiceSpeak", LVoiceSpeak});
        _Out.push_back({"voiceSpeakPrepare", LVoiceSpeakPrepare});
        _Out.push_back({"voiceSpeakStop", LVoiceSpeakStop});
        _Out.push_back({"voiceInfo", LVoiceInfo});
        _Out.push_back({"voiceEngine", LVoiceEngine});
        _Out.push_back({"voiceEngineSetup", LVoiceEngineSetup});
        _Out.push_back({"voiceSelfTest", LVoiceSelfTest});
        _Out.push_back({"voiceVoices", LVoiceVoices});
        _Out.push_back({"voiceEngineRelease", LVoiceEngineRelease});
        _Out.push_back({"voiceTestEngine", LVoiceTestEngine});
        _Out.push_back({"voiceMakeVoice", LVoiceMakeVoice});
        _Out.push_back({"gpuInfo", LGpuInfo});
        _Out.push_back({"onnxSetAccuracy", LOnnxSetAccuracy});
        _Out.push_back({"voiceEngineForgetCrash", LVoiceEngineForgetCrash});
        _Out.push_back({"audioDevices", LAudioDevices});
        _Out.push_back({"setAudioDevices", LSetAudioDevices});
        _Out.push_back({"micTest", LMicTest});
    }

} // namespace gitgud::lua::bindings
