#include "speech/Listener.h"

#include "speech/Text.h"
#include "speech/TextClassifier.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>

namespace gitgud::speech
{

    using app::Json;

    namespace
    {

        constexpr long long kRate = 16000;
        constexpr int kMaxLookbackTokens = 50000;
        // The app's `vocabulary`: phrases kept, their length, the boost range.
        constexpr std::size_t kMaxVocabulary = 200;
        constexpr std::size_t kMaxPhraseBytes = 64;
        constexpr float kMinBoost = 0.5f;
        constexpr float kMaxBoost = 3.0f;
        // Wake words and closing phrases: short phrases only.
        constexpr std::size_t kMaxWakeBytes = 64;

        // Seconds from the app, kept to 0..3600; anything else keeps `_fCurrent`.
        double AppSeconds(const Json& _Value, double _fCurrent)
        {
            if (!_Value.IsNumber() || !std::isfinite(_Value.AsNumber()))
            {
                return _fCurrent;
            }
            return std::min(3600.0, std::max(0.0, _Value.AsNumber()));
        }

        int AppTokens(const Json& _Value, int _iCurrent, int _iLo, int _iHi)
        {
            if (!_Value.IsNumber() || !std::isfinite(_Value.AsNumber()))
            {
                return _iCurrent;
            }
            return static_cast<int>(std::min(static_cast<double>(_iHi),
                std::max(static_cast<double>(_iLo), std::round(_Value.AsNumber()))));
        }

        double Round(double _fValue, double _fScale)
        {
            return std::round(_fValue * _fScale) / _fScale;
        }

        std::string Format(const char* _szFormat, ...)
        {
            char abuf[512];
            va_list args;
            va_start(args, _szFormat);
            std::vsnprintf(abuf, sizeof(abuf), _szFormat, args);
            va_end(args);
            return abuf;
        }

    } // namespace

    Listener::Listener(
        Recognizer& _Recognizer, std::string _VoiceprintPath, SendFn _Send, LogFn _Log)
        : m_Recognizer(_Recognizer), m_Config(_Recognizer.Config()), m_Send(std::move(_Send)),
          m_Log(std::move(_Log)), m_VoiceprintPath(std::move(_VoiceprintPath))
    {
        m_WakeWord = m_Config.m_WakeWord;
        m_iLookbackTokens = std::min(kMaxLookbackTokens, std::max(1, m_Config.m_iLookbackTokens));
        m_iContextTokens = std::min(m_iLookbackTokens, std::max(0, m_Config.m_iContextTokens));
        m_iMessageContextTokens =
            std::min(m_iLookbackTokens, std::max(0, m_Config.m_iMessageContextTokens));
        m_fWakeThreshold = m_Config.m_fWakeThreshold;
        m_bAppEnds = m_Config.m_EndBy == "app";
    }

    Listener::~Listener()
    {
        if (m_pKws)
        {
            m_Recognizer.DestroyKwsStream(m_pKws);
        }
        if (m_pVad)
        {
            m_Recognizer.DestroyVad(m_pVad);
        }
    }

    void Listener::SendError(const std::string& _Code, const std::string& _Message)
    {
        m_Send(Json::Object().Set("type", "error").Set("code", _Code).Set("message", _Message));
    }

    void Listener::ResetKws()
    {
        if (m_pKws)
        {
            m_Recognizer.DestroyKwsStream(m_pKws);
        }
        m_pKws = nullptr;
        if (!m_Recognizer.KwsReady())
        {
            return;
        }
        const std::string line = m_Recognizer.KeywordLines(m_SpotterPhrases, m_fWakeThreshold);
        if (line.empty())
        {
            m_Log("listen: the spotter can't spell the wake word '" + m_WakeWord + "'");
            return;
        }
        m_pKws = m_Recognizer.CreateKwsStream(line);
        m_Log("listen: spotting '" + m_WakeWord + "' (" + line + ")");
    }

    void Listener::OnHello(const Json& _Json, bool _bHello)
    {
        bool bkwsChanged = _bHello;
        if (_Json["wakeWord"].IsString() && _Json["wakeWord"].AsString() != m_WakeWord)
        {
            const std::string& wake = _Json["wakeWord"].AsString();
            if (wake.size() <= kMaxWakeBytes && !NormalizePhrase(wake).empty())
            {
                m_WakeWord = wake;
                bkwsChanged = true;
            }
            else
            {
                SendError("bad-request", "the wake word must be a short phrase");
            }
        }
        if (_Json["closingPhrase"].IsString())
        {
            m_ClosingPhrase = _Json["closingPhrase"].AsString().substr(0, kMaxWakeBytes);
        }
        m_iLookbackTokens =
            AppTokens(_Json["lookbackTokens"], m_iLookbackTokens, 1, kMaxLookbackTokens);
        m_iContextTokens =
            std::min(AppTokens(_Json["contextTokens"], m_iContextTokens, 0, m_iLookbackTokens),
                m_iLookbackTokens);
        m_iMessageContextTokens = std::min(
            AppTokens(_Json["messageContextTokens"], m_iMessageContextTokens, 0, m_iLookbackTokens),
            m_iLookbackTokens);
        m_fEndWaitSeconds = AppSeconds(_Json["endWaitSeconds"], m_fEndWaitSeconds);
        if (_Json.Has("endBy"))
        {
            const std::string& endBy = _Json["endBy"].AsString();
            if (endBy == "app" || endBy == "engine" || endBy == "server")
            {
                m_bAppEnds = endBy == "app";
            }
            else
            {
                SendError("bad-request", "endBy must be app or engine");
            }
        }
        if (_Json["wakeThreshold"].IsNumber())
        {
            float fthreshold = static_cast<float>(_Json["wakeThreshold"].AsNumber());
            fthreshold = std::isfinite(fthreshold) ? std::min(0.99f, std::max(0.01f, fthreshold))
                                                   : m_fWakeThreshold;
            if (fthreshold != m_fWakeThreshold)
            {
                m_fWakeThreshold = fthreshold;
                bkwsChanged = true;
            }
        }
        if (_Json["mishearings"].IsArray())
        {
            m_AppMishearings.clear();
            for (const Json& item : _Json["mishearings"].Items())
            {
                if (item.IsString() && !item.AsString().empty() &&
                    item.AsString().size() <= kMaxPhraseBytes)
                {
                    m_AppMishearings.push_back(item.AsString());
                }
            }
        }
        // The engine's defaults (spotter spellings, mishearings) belong to its
        // configured wake word; another wake word gets only the app's list.
        const bool bdefaults = NormalizePhrase(m_WakeWord) == NormalizePhrase(m_Config.m_WakeWord);
        m_Mishearings = m_AppMishearings;
        if (bdefaults)
        {
            for (const std::string& item : m_Config.m_Mishearings)
            {
                if (std::find(m_Mishearings.begin(), m_Mishearings.end(), item) ==
                    m_Mishearings.end())
                {
                    m_Mishearings.push_back(item);
                }
            }
        }
        std::vector<std::string> phrases{m_WakeWord};
        if (bdefaults)
        {
            phrases.insert(phrases.end(), m_Config.m_SpotterSpellings.begin(),
                m_Config.m_SpotterSpellings.end());
        }
        if (phrases != m_SpotterPhrases)
        {
            m_SpotterPhrases = phrases;
            bkwsChanged = true;
        }
        bool bvocabChanged = false;
        if (_Json["vocabulary"].IsArray())
        {
            std::vector<std::string> lines;
            std::size_t nskipped = 0;
            for (const Json& item : _Json["vocabulary"].Items())
            {
                const std::string text =
                    item.IsString() ? item.AsString() : item["text"].AsString();
                float fboost = 0;
                if (item.IsObject() && item["boost"].IsNumber())
                {
                    fboost = static_cast<float>(item["boost"].AsNumber());
                    fboost = std::isfinite(fboost)
                                 ? std::min(kMaxBoost, std::max(kMinBoost, fboost))
                                 : 0;
                }
                const std::string line = text.size() <= kMaxPhraseBytes
                                             ? m_Recognizer.HotwordLineFor(text, fboost)
                                             : std::string();
                if (line.empty() || lines.size() >= kMaxVocabulary)
                {
                    ++nskipped;
                    continue;
                }
                if (std::find(lines.begin(), lines.end(), line) == lines.end())
                {
                    lines.push_back(line);
                }
            }
            if (nskipped)
            {
                m_Log(Format("listen: vocabulary: %zu of %zu phrases skipped", nskipped,
                    _Json["vocabulary"].Items().size()));
            }
            bvocabChanged = lines != m_Vocabulary;
            m_Vocabulary = std::move(lines);
        }
        if (bkwsChanged)
        {
            ResetKws();
        }
        if ((bkwsChanged || bvocabChanged) && m_Config.m_bHotwords)
        {
            m_Hotwords = m_Recognizer.HotwordLineFor(m_WakeWord);
            for (const std::string& line : m_Vocabulary)
            {
                m_Hotwords += (m_Hotwords.empty() ? "" : "\n") + line;
            }
        }
    }

    void Listener::OnText(const std::string& _Text)
    {
        std::string error;
        const std::optional<Json> parsed = Json::Parse(_Text, &error);
        if (!parsed || !parsed->IsObject())
        {
            SendError("bad-json", error.empty() ? "not a JSON object" : error);
            return;
        }
        const Json& json = *parsed;
        const std::string type = json["type"].AsString();

        if (type == "hello")
        {
            if (m_bHello)
            {
                SendError("bad-request", "hello sent twice");
                return;
            }
            if (json["version"].AsNumber(0) != 0)
            {
                SendError("bad-version", "only version 0");
                return;
            }
            if (json.Has("sampleRate") && json["sampleRate"].AsNumber() != 16000)
            {
                SendError("bad-sample-rate", "only 16000 Hz");
                return;
            }
            m_pVad = m_Recognizer.CreateVad();
            if (!m_pVad)
            {
                SendError("internal", "the voice activity detector didn't start");
                return;
            }
            m_Ring.reserve(
                static_cast<std::size_t>((m_Config.m_fMaxUtteranceSeconds + 10) * kRate));
            OnHello(json, true);
            m_bHello = true;
            Json ready = Json::Object();
            ready.Set("type", "ready").Set("version", 0);
            ready.Set("stt", Json::Object()
                                 .Set("provider", "parakeet")
                                 .Set("model", m_Config.m_AsrName)
                                 .Set("device", "cpu"));
            ready.Set("keywords", m_pKws != nullptr);
            ready.Set("vocabulary", m_Config.m_bHotwords);
            ready.Set("decider", m_Recognizer.Decider() != nullptr);
            if (!m_Recognizer.DeciderError().empty())
            {
                ready.Set("deciderError", m_Recognizer.DeciderError());
                m_Log("listen: no turn-taking model: " + m_Recognizer.DeciderError());
            }
            if (m_Recognizer.SpeakerReady())
            {
                Voiceprint print;
                if (LoadVoiceprint(m_VoiceprintPath, print) &&
                    print.m_Model == m_Recognizer.SpeakerModelName())
                {
                    m_Voiceprint = print;
                }
                ready.Set(
                    "speaker", Json::Object().Set("enrolled", !m_Voiceprint.m_Vector.empty()));
            }
            m_Send(ready);
            m_Log("listen: hello, wake '" + m_WakeWord + "', closing '" + m_ClosingPhrase +
                  "', end by " + (m_bAppEnds ? "app" : "engine"));
            return;
        }
        if (!m_bHello)
        {
            SendError("no-hello", "send hello first");
            return;
        }

        if (type == "config")
        {
            OnHello(json, false);
        }
        else if (type == "wake")
        {
            if (m_Msg.m_bActive || m_bTraining || m_bEnrolling)
            {
                return;
            }
            StartMessage(m_bSpeaking ? std::max(m_iSpeechStart, m_iSendCut) : m_iNow, m_iNow, true);
        }
        else if (type == "send")
        {
            const std::string reason = json.Has("reason") ? json["reason"].AsString() : "button";
            if (reason != "button" && reason != "done")
            {
                SendError("bad-request", "send reason must be button or done");
                return;
            }
            if (!m_Msg.m_bActive)
            {
                SendError("no-message", "no message to send");
                return;
            }
            const long long ifrom = std::max(m_iSpeechStart, m_iSendCut);
            if (m_pGrow && m_bSpeaking)
            {
                // The speech still going is the message's: the last decode
                // hears it, a short one too, and the rest of the utterance
                // is the next message's. Its own text goes in below, as in
                // utterances mode.
                m_pGrow->Accept(ifrom, m_iNow);
                m_iSendCut = m_iNow;
            }
            if (m_bSpeaking && m_iNow - ifrom > kRate * 3 / 10)
            {
                const std::vector<float> audio = RingSlice(ifrom, m_iNow);
                double fms = 0;
                const std::string text =
                    FixText(m_Recognizer.Recognize(audio.data(), audio.size(), m_Hotwords, &fms));
                m_Log(Format("listen: send cut %.2f s, decode %.0f ms",
                    static_cast<double>(audio.size()) / kRate, fms));
                if (!text.empty())
                {
                    Segment segment{Ms(ifrom), Ms(m_iNow), text};
                    double fsms = 0;
                    const float fscore = ScoreSpeaker(audio.data(), audio.size(), &fsms);
                    TagSpeaker(segment, fscore, static_cast<double>(audio.size()) / kRate, fsms);
                    m_Msg.m_Parts.push_back(segment);
                    m_Lookback.push_back(segment);
                }
                m_iSendCut = m_iNow;
            }
            FinishMessage(reason == "done" ? "done" : "send");
        }
        else if (type == "cancel")
        {
            CancelMessage();
        }
        else if (type == "lookback")
        {
            const int itokens = AppTokens(json["tokens"], m_iContextTokens, 0, m_iLookbackTokens);
            PruneLookback();
            Json reply = Json::Object();
            reply.Set("type", "lookback")
                .Set("id", json["id"])
                .Set("segments", NewestSegments(Ms(m_iNow), itokens));
            m_Send(reply);
        }
        else if (type == "playback")
        {
            // Told when a reply plays; speech heard meanwhile is treated like
            // any other (the echo canceller keeps the reply out of the mic),
            // and barge-in is the app's.
            const std::string& state = json["state"].AsString();
            if (state != "started" && state != "stopped")
            {
                SendError("bad-request", "playback state must be started or stopped");
            }
        }
        else if (type == "decide")
        {
            OnDecide(json);
        }
        else if (type == "train")
        {
            OnTrain(json["state"].AsString());
        }
        else if (type == "enroll")
        {
            OnEnroll(json["state"].AsString());
        }
        else
        {
            SendError("unknown-type", "unknown type '" + type + "'");
        }
    }

    double Listener::SilenceSeconds() const
    {
        if (m_bSpeaking || m_iLastSpeechEnd < 0)
        {
            return 0;
        }
        return static_cast<double>(std::max(0LL, m_iNow - m_iLastSpeechEnd)) / kRate;
    }

    void Listener::OnDecide(const Json& _Json)
    {
        Json reply = Json::Object();
        reply.Set("type", "decision").Set("id", _Json["id"]);
        TextClassifier* pdecider = m_Recognizer.Decider();
        if (!pdecider)
        {
            reply.Set("error", m_Recognizer.DeciderError().empty() ? "no turn-taking model"
                                                                   : m_Recognizer.DeciderError());
            m_Send(reply);
            return;
        }
        const double fpause = SilenceSeconds();
        std::string second = _Json["second"].AsString();
        const std::string pause = Format("%.1f", fpause);
        for (std::size_t nat = second.find("{pause}"); nat != std::string::npos;
             nat = second.find("{pause}", nat + pause.size()))
        {
            second.replace(nat, 7, pause);
        }
        const int imax = AppTokens(_Json["maxLength"], 256, 8, 512);
        const int ifirst = AppTokens(_Json["firstMax"], 40, 0, 512);
        const std::vector<int64_t> ids =
            pdecider->Encode(_Json["first"].AsString(), second, imax, ifirst);
        TextClassifier::Outputs outputs;
        double fms = 0;
        if (!pdecider->Classify(ids, outputs, &fms))
        {
            reply.Set("error", "the turn-taking model failed");
            m_Send(reply);
            return;
        }
        Json out = Json::Object();
        for (const auto& [name, values] : outputs)
        {
            Json list = Json::Array();
            for (const float fvalue : values)
            {
                list.Push(static_cast<double>(fvalue));
            }
            out.Set(name, list);
        }
        reply.Set("outputs", out)
            .Set("pause", fpause)
            .Set("speaking", m_bSpeaking)
            .Set("tokens", static_cast<double>(ids.size()))
            .Set("ms", fms)
            .Set("t", Ms(m_iNow));
        m_Send(reply);
    }

    void Listener::OnTrain(const std::string& _State)
    {
        if (_State == "start")
        {
            if (m_bEnrolling)
            {
                SendError("busy", "voice enrollment is running");
                return;
            }
            if (m_Msg.m_bActive)
            {
                CancelMessage();
            }
            m_bTraining = true;
            m_iTrainCount = 0;
            m_TrainTexts.clear();
            m_TrainScores.clear();
            m_Log("listen: wake word training started");
        }
        else if (_State == "stop")
        {
            m_bTraining = false;
            Json result = Json::Object();
            result.Set("type", "trainResult").Set("samples", m_iTrainCount);
            Json mishearings = Json::Array();
            std::vector<std::string> seen;
            const std::string wake = NormalizePhrase(m_WakeWord);
            for (const std::string& text : m_TrainTexts)
            {
                const std::string norm = NormalizePhrase(text);
                if (norm.empty() || norm == wake ||
                    std::find(seen.begin(), seen.end(), norm) != seen.end())
                {
                    continue;
                }
                seen.push_back(norm);
                mishearings.Push(norm);
            }
            result.Set("mishearings", std::move(mishearings));
            float fmin = 1;
            for (float fscore : m_TrainScores)
            {
                if (fscore > 0)
                {
                    fmin = std::min(fmin, fscore);
                }
            }
            const float fthreshold = fmin < 1 ? std::max(0.05f, fmin - 0.05f) : m_fWakeThreshold;
            result.Set("threshold", Round(fthreshold, 100));
            m_Log(Format("listen: wake word training stopped: %d samples, threshold %.2f",
                m_iTrainCount, fthreshold));
            m_Send(result);
        }
        else
        {
            SendError("bad-request", "train state must be start or stop");
        }
    }

    // Voice enrollment: while on, every utterance is the user's and adds to
    // their voiceprint; `stop` saves it once there is enough speech, `clear`
    // deletes it.
    void Listener::OnEnroll(const std::string& _State)
    {
        if (_State != "start" && _State != "stop" && _State != "clear")
        {
            SendError("bad-request", "enroll state must be start, stop or clear");
            return;
        }
        if (!m_Recognizer.SpeakerReady())
        {
            SendError("no-speaker-model", "speaker identification is off");
            return;
        }
        if (m_VoiceprintPath.empty())
        {
            SendError("bad-user", "no voiceprint file");
            return;
        }
        auto result = [&](bool _bEnrolled, const char* _szReason)
        {
            Json reply = Json::Object();
            reply.Set("type", "enrollResult")
                .Set("samples", m_iEnrollCount)
                .Set("seconds", Round(m_fEnrollSeconds, 10))
                .Set("enrolled", _bEnrolled);
            if (_szReason)
            {
                reply.Set("reason", _szReason);
            }
            m_Send(reply);
        };
        if (_State == "start")
        {
            if (m_bTraining)
            {
                SendError("busy", "wake word training is running");
                return;
            }
            if (m_Msg.m_bActive)
            {
                CancelMessage();
            }
            m_bEnrolling = true;
            m_iEnrollCount = 0;
            m_fEnrollSeconds = 0;
            m_EnrollSum.clear();
        }
        else if (_State == "clear")
        {
            m_bEnrolling = false;
            m_iEnrollCount = 0;
            m_fEnrollSeconds = 0;
            RemoveVoiceprint(m_VoiceprintPath);
            m_Voiceprint = Voiceprint{};
            m_Log("listen: voiceprint cleared");
            result(false, nullptr);
        }
        else if (m_bEnrolling)
        {
            m_bEnrolling = false;
            if (m_fEnrollSeconds < m_Config.m_fEnrollMinSeconds)
            {
                result(!m_Voiceprint.m_Vector.empty(), "too-short");
                return;
            }
            Voiceprint print;
            print.m_Model = m_Recognizer.SpeakerModelName();
            print.m_fSeconds = m_fEnrollSeconds;
            print.m_iSamples = m_iEnrollCount;
            double flength = 0;
            for (double x : m_EnrollSum)
            {
                flength += x * x;
            }
            flength = std::sqrt(flength);
            for (double x : m_EnrollSum)
            {
                print.m_Vector.push_back(static_cast<float>(flength > 0 ? x / flength : 0));
            }
            std::string error;
            if (!SaveVoiceprint(m_VoiceprintPath, print, error))
            {
                m_Log("listen: " + error);
                result(!m_Voiceprint.m_Vector.empty(), "not-saved");
                return;
            }
            m_Voiceprint = print;
            m_Log(Format("listen: voiceprint saved (%d utterances, %.1f s)", m_iEnrollCount,
                m_fEnrollSeconds));
            result(true, nullptr);
        }
        else
        {
            SendError("bad-request", "enrollment is not running");
        }
    }

    float Listener::ScoreSpeaker(const float* _pSamples, std::size_t _nCount, double* _pMs)
    {
        if (m_Voiceprint.m_Vector.empty() ||
            static_cast<double>(_nCount) / kRate < m_Config.m_fSpeakerMinSeconds)
        {
            return -2;
        }
        const std::vector<float> embedding = m_Recognizer.Embed(_pSamples, _nCount, _pMs);
        if (embedding.empty())
        {
            return -2;
        }
        const float fscore = Similarity(embedding, m_Voiceprint.m_Vector);
        return fscore < -0.5f ? -2 : fscore; // below -0.5: the sizes differ
    }

    void Listener::TagSpeaker(Segment& _Segment, float _fScore, double _fSeconds, double _fMs)
    {
        if (_fScore < -1)
        {
            return;
        }
        _Segment.m_fSpeakerScore = static_cast<float>(Round(_fScore, 100));
        _Segment.m_bScored = true;
        const bool bunsure = _fScore < m_Config.m_fSpeakerThreshold &&
                             _fScore >= m_Config.m_fSpeakerUnsureBelow &&
                             _fSeconds < m_Config.m_fSpeakerUnsureSeconds;
        _Segment.m_Speaker = bunsure                                   ? ""
                             : _fScore >= m_Config.m_fSpeakerThreshold ? "user"
                                                                       : "other";
        m_Log(Format("listen: speaker %s (%.2f, %.1f s), embedding %.0f ms",
            bunsure ? "unsure" : _Segment.m_Speaker.c_str(), _fScore, _fSeconds, _fMs));
    }

    Json Listener::SegmentJson(const Segment& _Segment)
    {
        Json out = Json::Object();
        out.Set("t0", _Segment.m_iT0).Set("t1", _Segment.m_iT1).Set("text", _Segment.m_Text);
        if (!_Segment.m_Speaker.empty())
        {
            out.Set("speaker", _Segment.m_Speaker);
        }
        if (_Segment.m_bScored)
        {
            out.Set("speakerScore", static_cast<double>(_Segment.m_fSpeakerScore));
        }
        return out;
    }

    std::vector<float> Listener::RingSlice(long long _iFrom, long long _iTo) const
    {
        _iFrom = std::max(_iFrom, m_iRingStart);
        _iTo = std::min(_iTo, m_iRingStart + static_cast<long long>(m_Ring.size()));
        if (_iTo <= _iFrom)
        {
            return {};
        }
        return std::vector<float>(
            m_Ring.begin() + (_iFrom - m_iRingStart), m_Ring.begin() + (_iTo - m_iRingStart));
    }

    void Listener::OnAudio(const std::string& _Pcm)
    {
        if (!m_bHello)
        {
            SendError("no-hello", "send hello before audio");
            return;
        }
        const std::size_t ncount = _Pcm.size() / 2;
        if (ncount == 0)
        {
            return;
        }
        std::vector<float> samples(ncount);
        const unsigned char* pbytes = reinterpret_cast<const unsigned char*>(_Pcm.data());
        for (std::size_t ni = 0; ni < ncount; ++ni)
        {
            samples[ni] = static_cast<float>(
                              static_cast<int16_t>(pbytes[2 * ni] | (pbytes[2 * ni + 1] << 8))) /
                          32768.0f;
        }

        m_Ring.insert(m_Ring.end(), samples.begin(), samples.end());
        if (m_pGrow)
        {
            if (m_pGrow->End() == m_iNow)
            {
                m_pGrow->Append(samples.data(), ncount);
            }
            else
            {
                // Out of step (never expected): catch up from the ring.
                const std::vector<float> missing =
                    RingSlice(m_pGrow->End(), m_iNow + static_cast<long long>(ncount));
                m_pGrow->Append(missing.data(), missing.size());
            }
        }
        const std::size_t ncap =
            static_cast<std::size_t>((m_Config.m_fMaxUtteranceSeconds + 10) * kRate);
        if (m_Ring.size() > ncap + kRate)
        {
            const std::size_t ndrop = m_Ring.size() - ncap;
            m_Ring.erase(m_Ring.begin(), m_Ring.begin() + static_cast<std::ptrdiff_t>(ndrop));
            m_iRingStart += static_cast<long long>(ndrop);
        }

        const long long ichunkEnd = m_iNow + static_cast<long long>(ncount);
        if (m_pKws && m_Recognizer.KwsFeed(m_pKws, samples.data(), ncount))
        {
            OnKeyword(ichunkEnd);
        }

        bool bdetected = false;
        std::vector<SpeechSegment> segments;
        m_Recognizer.VadFeed(m_pVad, samples.data(), ncount, bdetected, segments);
        m_iNow = ichunkEnd;

        if (bdetected && !m_bVoiced)
        {
            m_bVoiced = true;
            m_bSpeaking = true;
            const long long iback =
                static_cast<long long>(
                    (m_Config.m_fMinSpeechSeconds + m_Config.m_fPrerollSeconds) * kRate) +
                1024 + static_cast<long long>(ncount);
            m_iSpeechStart = std::max(std::max(0LL, m_iNow - iback), m_iLastS1);
            m_iLastPartial = m_iNow;
            m_Msg.m_iPauseDeadline = -1;
            m_Msg.m_iClosingDeadline = -1;
            SendVad(true, m_iSpeechStart);
        }
        if (!bdetected && m_bVoiced)
        {
            m_bVoiced = false;
            if (m_bSpeaking)
            {
                m_bSpeaking = false;
                SendVad(false, segments.empty()
                                   ? m_iNow
                                   : segments.back().m_iStart +
                                         static_cast<long long>(segments.back().m_Samples.size()));
            }
        }
        for (SpeechSegment& segment : segments)
        {
            long long is0 = segment.m_iStart;
            const long long is1 = is0 + static_cast<long long>(segment.m_Samples.size());
            // Pre-roll, never into the previous utterance.
            const long long ifrom =
                std::max({is0 - static_cast<long long>(m_Config.m_fPrerollSeconds * kRate),
                    m_iLastS1, m_iRingStart, 0LL});
            if (ifrom < is0)
            {
                const std::vector<float> pre = RingSlice(ifrom, is0);
                segment.m_Samples.insert(segment.m_Samples.begin(), pre.begin(), pre.end());
                is0 -= static_cast<long long>(pre.size());
            }
            OnUtterance(segment.m_Samples.data(), segment.m_Samples.size(), is0, is1);
            if (m_bVoiced)
            {
                m_iSpeechStart = std::max(m_iSpeechStart, is1); // split by the longest utterance
            }
        }

        double fevery = m_Config.m_fPartialSeconds;
        if (m_pGrow)
        {
            const bool blong = static_cast<double>(m_pGrow->End() - m_pGrow->LiveStart()) / kRate >
                               m_Config.m_fGrowLongAfterSeconds;
            fevery = blong ? m_Config.m_fGrowEveryLongSeconds : m_Config.m_fGrowEverySeconds;
        }
        const long long ievery = std::max(static_cast<long long>(fevery * kRate), m_iPartialCost);
        if (m_Msg.m_bActive && m_bSpeaking && m_iNow - m_iLastPartial >= ievery)
        {
            SendPartial(false);
        }
        CheckTimers();
    }

    void Listener::SendVad(bool _bSpeaking, long long _iT)
    {
        if (!_bSpeaking)
        {
            m_iLastSpeechEnd = _iT;
        }
        Json out = Json::Object();
        out.Set("type", "vad").Set("speaking", _bSpeaking).Set("t", Ms(_iT));
        m_Send(out);
    }

    void Listener::OnKeyword(long long _iAt)
    {
        m_WakeHits.push_back(_iAt);
        m_Log(Format("listen: keyword at %.2f s", static_cast<double>(_iAt) / kRate));
        if (m_bTraining || m_bEnrolling || m_Msg.m_bActive)
        {
            return;
        }
        if (m_bSpeaking)
        {
            StartMessage(m_iSpeechStart, _iAt, false);
        }
        else if (m_iLastS1 >= 0 && _iAt - m_iLastS1 < kRate && !m_LastText.empty())
        {
            // The utterance already ended (and went out as ambient): pull it in.
            StartMessage(m_iLastS0, _iAt, false);
            Segment segment{Ms(m_iLastS0), Ms(m_iLastS1), FixText(m_LastText)};
            if (!m_Lookback.empty() && m_Lookback.back().m_iT0 == segment.m_iT0)
            {
                m_Lookback.back().m_Text = segment.m_Text;
                segment.m_Speaker = m_Lookback.back().m_Speaker;
                segment.m_fSpeakerScore = m_Lookback.back().m_fSpeakerScore;
                segment.m_bScored = m_Lookback.back().m_bScored;
            }
            m_Msg.m_Parts.push_back(segment);
            if (m_pGrow)
            {
                m_pGrow->Accept(m_iLastS0, m_iLastS1);
            }
            m_Msg.m_bPauseMode = PauseModeFor(segment.m_Text, {_iAt}, m_iLastS0, m_iLastS1);
            if (m_Msg.m_bPauseMode)
            {
                m_Msg.m_iPauseDeadline =
                    m_iLastS1 + static_cast<long long>(m_fEndWaitSeconds * kRate);
            }
            SendPartial(true);
            SendPause(m_iLastS1);
        }
        else
        {
            StartMessage(std::max(0LL, _iAt - kRate), _iAt, false);
        }
    }

    std::string Listener::FixText(const std::string& _Text) const
    {
        return m_Mishearings.empty() ? _Text : RewriteMishearings(_Text, m_Mishearings, m_WakeWord);
    }

    void Listener::OnUtterance(
        const float* _pSamples, std::size_t _nCount, long long _iS0, long long _iS1)
    {
        if (m_iSendCut > _iS0)
        {
            const long long iskip =
                std::min<long long>(m_iSendCut - _iS0, static_cast<long long>(_nCount));
            m_iSendCut = -1;
            if (static_cast<long long>(_nCount) - iskip < kRate * 3 / 10)
            {
                return;
            }
            _pSamples += iskip;
            _nCount -= static_cast<std::size_t>(iskip);
            _iS0 += iskip;
        }
        // Who it sounds like, for the message's `speaker` (never a reason to
        // drop or hold anything).
        double fsms = 0;
        const float fscore =
            m_bEnrolling || m_bTraining ? -2 : ScoreSpeaker(_pSamples, _nCount, &fsms);
        double fms = 0;
        bool bok = true;
        std::string text = m_Recognizer.Recognize(_pSamples, _nCount, m_Hotwords, &fms, &bok);
        m_Log(Format("listen: utterance %.2f-%.2f s (%.2f s), decode %.0f ms%s",
            static_cast<double>(_iS0) / kRate, static_cast<double>(_iS1) / kRate,
            static_cast<double>(_nCount) / kRate, fms, bok ? "" : ", failed"));

        // Spotter hits that belong to this utterance (it lags a little).
        std::vector<long long> hits;
        for (auto it = m_WakeHits.begin(); it != m_WakeHits.end();)
        {
            if (*it <= _iS1 + kRate)
            {
                if (*it >= _iS0 - kRate * 3 / 10)
                {
                    hits.push_back(*it);
                }
                it = m_WakeHits.erase(it);
            }
            else
            {
                ++it;
            }
        }
        bool bwake = !hits.empty();
        // The name in the transcript, mishearings included.
        if (!bwake && m_Config.m_bTextWake && !text.empty() &&
            ContainsPhrase(FixText(text), m_WakeWord))
        {
            bwake = true;
        }
        if (bwake)
        {
            text = FixText(text);
        }

        if (m_bEnrolling)
        {
            // The user's own speech (words or not): into the voiceprint, not
            // the lookback.
            const double fseconds = static_cast<double>(_nCount) / kRate;
            if (fseconds < m_Config.m_fSpeakerMinSeconds)
            {
                return;
            }
            const std::vector<float> embedding = m_Recognizer.Embed(_pSamples, _nCount, nullptr);
            if (embedding.empty())
            {
                return;
            }
            if (m_EnrollSum.empty())
            {
                m_EnrollSum.assign(embedding.size(), 0.0);
            }
            if (m_EnrollSum.size() != embedding.size())
            {
                return;
            }
            for (std::size_t ni = 0; ni < embedding.size(); ++ni)
            {
                m_EnrollSum[ni] += embedding[ni] * fseconds;
            }
            ++m_iEnrollCount;
            m_fEnrollSeconds += fseconds;
            m_Send(Json::Object()
                    .Set("type", "enrollSample")
                    .Set("n", m_iEnrollCount)
                    .Set("text", text)
                    .Set("seconds", Round(m_fEnrollSeconds, 10))
                    .Set("t0", Ms(_iS0))
                    .Set("t1", Ms(_iS1)));
            return;
        }

        if (m_bTraining)
        {
            // Every utterance is a sample, words or not: a lone short name
            // often transcribes to nothing. A live spotter hit in it counts as
            // woken at the current threshold, whatever the rerun scores.
            float fwake = m_Recognizer.KwsScore(m_SpotterPhrases, _pSamples, _nCount);
            if (!hits.empty())
            {
                fwake = std::max(fwake, m_fWakeThreshold);
            }
            ++m_iTrainCount;
            m_TrainTexts.push_back(text);
            m_TrainScores.push_back(fwake);
            m_Send(Json::Object()
                    .Set("type", "trainSample")
                    .Set("n", m_iTrainCount)
                    .Set("text", text)
                    .Set("score", Round(fwake, 100))
                    .Set("detected", fwake > 0 && fwake >= m_fWakeThreshold)
                    .Set("t0", Ms(_iS0))
                    .Set("t1", Ms(_iS1)));
            return;
        }

        m_iLastS0 = _iS0;
        m_iLastS1 = _iS1;
        m_LastText = text;
        if (text.empty())
        {
            // The spotter started a message in this utterance, but there were
            // no words in it: most likely a false detection.
            if (m_Msg.m_bActive && !m_Msg.m_bFromApp && m_Msg.m_Parts.empty() &&
                m_Msg.m_iT0 <= _iS1)
            {
                m_Log("listen: nothing recognized in the wake utterance; message dropped");
                CancelMessage();
            }
            else if (m_pGrow && m_Msg.m_bActive && _iS1 > m_Msg.m_iT0)
            {
                // Too quiet or short to decode alone: with the message's
                // context the growing transcript may still hear it.
                m_pGrow->Accept(_iS0, _iS1);
            }
            return;
        }

        Segment segment{Ms(_iS0), Ms(_iS1), text};
        TagSpeaker(segment, fscore, static_cast<double>(_nCount) / kRate, fsms);

        m_Lookback.push_back(segment);
        PruneLookback();

        bool bstarted = false;
        if (!m_Msg.m_bActive && bwake)
        {
            StartMessage(_iS0, hits.empty() ? _iS0 : hits.front(), false);
            bstarted = true;
        }
        if (m_Msg.m_bActive && _iS1 > m_Msg.m_iT0)
        {
            const bool bfirst = m_Msg.m_Parts.empty() || bstarted;
            m_Msg.m_Parts.push_back(segment);
            if (m_pGrow)
            {
                m_pGrow->Accept(_iS0, _iS1);
            }
            if (bwake && !m_Msg.m_bFromApp)
            {
                // A later utterance ending with the name switches dictation to
                // pause mode.
                if (bfirst)
                {
                    m_Msg.m_bPauseMode = PauseModeFor(text, hits, _iS0, _iS1);
                }
                else if (NameAtEnd(text, hits, _iS1))
                {
                    m_Msg.m_bPauseMode = true;
                }
            }
            if (!m_ClosingPhrase.empty() && EndsWithPhrase(MessageText(), m_ClosingPhrase))
            {
                m_Msg.m_iClosingDeadline = std::max(m_iNow,
                    _iS1 + static_cast<long long>(m_Config.m_fClosingSilenceSeconds * kRate));
            }
            else if (m_Msg.m_bPauseMode)
            {
                m_Msg.m_iPauseDeadline =
                    std::max(m_iNow, _iS1 + static_cast<long long>(m_fEndWaitSeconds * kRate));
            }
            SendPartial(true);
            SendPause(_iS1);
        }
        else
        {
            Json ambient = SegmentJson(segment);
            ambient.Set("type", "ambient");
            m_Send(ambient);
        }
    }

    // Pause mode (a pause after it ends the message, with endBy "engine")
    // when the name ends the utterance, isn't first, or opens a short remark
    // after other speech ("Bragi, did you get that?": at most remarkMaxWords
    // words after the name, or remarkQuestionMaxWords for a question, with
    // speech within remarkContextSeconds before). Any other name-first
    // utterance is dictation: only the closing phrase or `send` ends it.
    bool Listener::PauseModeFor(const std::string& _Text, const std::vector<long long>& _Hits,
        long long _iS0, long long _iS1) const
    {
        if (NameAtEnd(_Text, _Hits, _iS1))
        {
            return true;
        }
        // Name first: the transcript starts with it or, if the transcript
        // lost it, the spotter fired near the start.
        const bool bintext = ContainsPhrase(_Text, m_WakeWord);
        const bool bfirst =
            bintext ? StartsWithPhrase(_Text, m_WakeWord)
                    : !_Hits.empty() &&
                          _Hits.front() - _iS0 <
                              static_cast<long long>(m_Config.m_fWakeStartSeconds * kRate);
        if (!bfirst)
        {
            return true;
        }
        const long long iwords =
            static_cast<long long>(SplitWords(_Text).size()) -
            (bintext ? static_cast<long long>(SplitWords(m_WakeWord).size()) : 0);
        const std::size_t nlast = _Text.find_last_not_of(" \t\r\n");
        const bool bquestion = nlast != std::string::npos && _Text[nlast] == '?';
        const long long ilimit =
            bquestion ? std::max(m_Config.m_iRemarkMaxWords, m_Config.m_iRemarkQuestionMaxWords)
                      : m_Config.m_iRemarkMaxWords;
        return iwords <= ilimit && SpeechBefore(_iS0);
    }

    bool Listener::NameAtEnd(
        const std::string& _Text, const std::vector<long long>& _Hits, long long _iS1) const
    {
        if (EndsWithPhrase(_Text, m_WakeWord))
        {
            return true;
        }
        // The spotter fired close to the end, and the transcript doesn't put
        // the name first.
        return !_Hits.empty() &&
               _iS1 - _Hits.back() < static_cast<long long>(m_Config.m_fWakeEndSeconds * kRate) &&
               !StartsWithPhrase(_Text, m_WakeWord);
    }

    bool Listener::SpeechBefore(long long _iS0) const
    {
        // A lookback segment that ended within remarkContextSeconds before
        // _iS0 (the utterance at _iS0 is already in the lookback).
        const long long it0 = Ms(_iS0);
        const long long ifrom =
            it0 - static_cast<long long>(m_Config.m_fRemarkContextSeconds * 1000);
        for (const Segment& segment : m_Lookback)
        {
            if (segment.m_iT0 < it0 && segment.m_iT1 >= ifrom)
            {
                return true;
            }
        }
        return false;
    }

    const char* Listener::MessageSpeaker() const
    {
        long long iuser = 0;
        long long iother = 0;
        for (const Segment& part : m_Msg.m_Parts)
        {
            if (part.m_Speaker == "user")
            {
                iuser += part.m_iT1 - part.m_iT0;
            }
            else if (part.m_Speaker == "other")
            {
                iother += part.m_iT1 - part.m_iT0;
            }
        }
        if (iuser + iother == 0)
        {
            return "";
        }
        return iuser >= iother ? "user" : "other";
    }

    void Listener::CheckTimers()
    {
        if (!m_Msg.m_bActive || m_bSpeaking)
        {
            return;
        }
        if (m_Msg.m_iClosingDeadline >= 0 && m_iNow >= m_Msg.m_iClosingDeadline)
        {
            FinishMessage("closing");
        }
        else if (!m_bAppEnds && m_Msg.m_bPauseMode && m_Msg.m_iPauseDeadline >= 0 &&
                 m_iNow >= m_Msg.m_iPauseDeadline)
        {
            FinishMessage("pause");
        }
    }

    std::string Listener::MessageText() const
    {
        std::string text;
        for (const Segment& part : m_Msg.m_Parts)
        {
            if (part.m_Text.empty())
            {
                continue;
            }
            if (!text.empty())
            {
                text += ' ';
            }
            text += part.m_Text;
        }
        return text;
    }

    GrowingTranscript::Settings Listener::GrowSettings() const
    {
        GrowingTranscript::Settings settings;
        settings.m_iRate = kRate;
        settings.m_fKeepBefore = m_Config.m_fKeepBeforeSeconds;
        settings.m_fKeepAfter = m_Config.m_fKeepAfterSeconds;
        settings.m_fGapMax = m_Config.m_fGapMaxSeconds;
        settings.m_fGapKeep = m_Config.m_fGapKeepSeconds;
        settings.m_fFadeSeconds = m_Config.m_fFadeSeconds;
        settings.m_fFillLevel = m_Config.m_fFillLevel;
        settings.m_fBufferSeconds = m_Config.m_fBufferSeconds;
        settings.m_fSnapSeconds = m_Config.m_fBufferSnapSeconds;
        settings.m_fAsrMaxSeconds = m_Config.m_fAsrMaxSeconds;
        return settings;
    }

    GrowingTranscript::DecodeFn Listener::GrowDecode(double& _fMs)
    {
        return [this, &_fMs](const float* _pSamples, std::size_t _nCount, bool& _bOk)
        {
            double fms = 0;
            const std::string text = m_Recognizer.RecognizeWhole(_pSamples, _nCount,
                m_Config.m_bGrowHotwords ? m_Hotwords : std::string(), &fms, &_bOk);
            _fMs += fms;
            return text;
        };
    }

    void Listener::SetGrowOpen()
    {
        // The utterance being spoken, after the last one judged (and after a
        // `send` cut).
        m_pGrow->SetOpen(
            m_bSpeaking ? std::max({m_iSpeechStart, m_iSendCut, m_iLastS1}) : -1);
    }

    std::string Listener::CurrentText() const
    {
        return m_pGrow && !m_GrowText.empty() ? m_GrowText : MessageText();
    }

    void Listener::SendPartial(bool _bForce)
    {
        if (!m_Msg.m_bActive)
        {
            return;
        }
        if (m_pGrow)
        {
            // One pass over the live buffer, with the speech still going on.
            if (!_bForce && !m_bSpeaking)
            {
                return;
            }
            SetGrowOpen();
            double fms = 0;
            bool bok = true;
            const std::string text = FixText(m_pGrow->Live(GrowDecode(fms), bok));
            // Leave time for the rest of the audio work.
            m_iPartialCost =
                static_cast<long long>(fms * m_Config.m_fGrowCostFactor * kRate / 1000);
            if (bok || !text.empty())
            {
                m_GrowText = text;
            }
            m_Log(Format("listen: growing pass %.2f-%.2f s, %d buffer(s) closed, decode %.0f ms%s "
                         "(%s): %d words",
                static_cast<double>(m_pGrow->LiveStart()) / kRate,
                static_cast<double>(m_pGrow->End()) / kRate,
                static_cast<int>(m_pGrow->ClosedCount()), fms, bok ? "" : ", failed",
                m_pGrow->Describe(true).c_str(), static_cast<int>(SplitWords(text).size())));
            m_iLastPartial = m_iNow;
            Json partial = Json::Object();
            // The utterances' own texts beside it: a pass over the whole
            // recording sometimes hears less than they did.
            partial.Set("type", "partial")
                .Set("id", m_Msg.m_Id)
                .Set("text", CurrentText())
                .Set("utterances", MessageText())
                .Set("t", Ms(m_iNow));
            if (m_iLastSpeechEnd >= 0)
            {
                partial.Set("speechEnd", Ms(m_iLastSpeechEnd));
            }
            const char* szspeaker = MessageSpeaker();
            if (*szspeaker)
            {
                partial.Set("speaker", szspeaker);
            }
            m_Send(partial);
            return;
        }
        std::string text = MessageText();
        const long long ifrom = std::max(m_iSpeechStart, m_iSendCut);
        if (m_bSpeaking && m_iNow - ifrom >= kRate * 3 / 10)
        {
            const std::vector<float> audio = RingSlice(ifrom, m_iNow);
            double fms = 0;
            const std::string open =
                FixText(m_Recognizer.Recognize(audio.data(), audio.size(), m_Hotwords, &fms));
            // Leave time for the rest of the audio work.
            m_iPartialCost = static_cast<long long>(fms * 1.5 * kRate / 1000);
            if (!open.empty())
            {
                text += (text.empty() ? "" : " ") + open;
            }
        }
        else if (!_bForce)
        {
            return;
        }
        m_iLastPartial = m_iNow;
        Json partial = Json::Object();
        partial.Set("type", "partial").Set("id", m_Msg.m_Id).Set("text", text).Set("t", Ms(m_iNow));
        if (m_iLastSpeechEnd >= 0)
        {
            partial.Set("speechEnd", Ms(m_iLastSpeechEnd));
        }
        // Who is speaking, once some of it is scored: the app needs it to
        // tell its own voice from the user's while a reply plays.
        const char* szspeaker = MessageSpeaker();
        if (*szspeaker)
        {
            partial.Set("speaker", szspeaker);
        }
        m_Send(partial);
    }

    void Listener::SendPause(long long _iS1)
    {
        if (!m_Msg.m_bActive)
        {
            return;
        }
        Json pause = Json::Object();
        pause.Set("type", "pause")
            .Set("id", m_Msg.m_Id)
            .Set("t", Ms(_iS1))
            .Set("text", CurrentText());
        if (m_pGrow)
        {
            pause.Set("utterances", MessageText());
        }
        m_Send(pause);
    }

    void Listener::StartMessage(long long _iT0, long long _iWakeAt, bool _bFromApp)
    {
        m_Msg = Message{};
        m_Msg.m_bActive = true;
        m_Msg.m_bFromApp = _bFromApp;
        m_Msg.m_iT0 = _iT0;
        m_Msg.m_iWakeAt = _iWakeAt;
        m_Msg.m_Id = "m" + std::to_string(++m_iMsgCount);
        m_pGrow.reset();
        m_GrowText.clear();
        if (Growing())
        {
            // From the message's start (as far back as the ring goes) to the
            // ring's end: the spotter starts one before m_iNow takes in the
            // chunk it has, which the ring already holds.
            const long long istart = std::max(_iT0, m_iRingStart);
            m_pGrow = std::make_unique<GrowingTranscript>(GrowSettings(), istart);
            const std::vector<float> audio =
                RingSlice(istart, m_iRingStart + static_cast<long long>(m_Ring.size()));
            m_pGrow->Append(audio.data(), audio.size());
        }
        m_Send(Json::Object()
                .Set("type", "wake")
                .Set("id", m_Msg.m_Id)
                .Set("t", Ms(_iWakeAt))
                .Set("t0", Ms(_iT0)));
        m_Log(Format("listen: message started at %.2f s (wake at %.2f s%s)",
            static_cast<double>(_iT0) / kRate, static_cast<double>(_iWakeAt) / kRate,
            _bFromApp ? ", from the app" : ""));
    }

    void Listener::FinishMessage(const char* _szEndedBy)
    {
        const bool bclosing = std::string(_szEndedBy) == "closing";
        std::string text = MessageText();
        std::string live;
        bool bfinalOk = true;
        if (m_pGrow)
        {
            // One last pass over the live buffer; the last partial's text
            // stays beside it for the app to fall back to.
            SetGrowOpen();
            double fms = 0;
            text = FixText(m_pGrow->Final(GrowDecode(fms), m_bSpeaking, bfinalOk));
            live = m_GrowText;
            m_Log(Format("listen: growing final %.2f-%.2f s, %d buffer(s) closed, %d decodes, last "
                         "%.0f ms%s (%s): %d words, live %d",
                static_cast<double>(m_pGrow->Start()) / kRate,
                static_cast<double>(m_pGrow->End()) / kRate,
                static_cast<int>(m_pGrow->ClosedCount()), m_pGrow->Decodes(), fms,
                bfinalOk ? "" : ", failed", m_pGrow->Describe(m_bSpeaking).c_str(),
                static_cast<int>(SplitWords(text).size()),
                static_cast<int>(SplitWords(live).size())));
            if (bclosing)
            {
                StripTrailingPhrase(live, m_ClosingPhrase);
            }
        }
        if (bclosing)
        {
            StripTrailingPhrase(text, m_ClosingPhrase);
        }
        // The last decode of a growing message heard the speech still going.
        const bool bnow = m_Msg.m_Parts.empty() || (m_pGrow && m_bSpeaking);
        Json out = Json::Object();
        out.Set("type", "message")
            .Set("id", m_Msg.m_Id)
            .Set("text", text)
            .Set("endedBy", _szEndedBy)
            .Set("t0", Ms(m_Msg.m_iT0))
            .Set("t1", bnow ? Ms(m_iNow) : m_Msg.m_Parts.back().m_iT1)
            .Set("wakeAt", Ms(m_Msg.m_iWakeAt));
        PruneLookback();
        out.Set("context", NewestSegments(Ms(m_Msg.m_iT0), m_iMessageContextTokens));
        // Who said it: the speaker of most of its tagged speech; the score is
        // the scored speech's, weighted by length.
        long long iscored = 0;
        double fsum = 0;
        for (const Segment& part : m_Msg.m_Parts)
        {
            if (part.m_bScored)
            {
                iscored += part.m_iT1 - part.m_iT0;
                fsum += static_cast<double>(part.m_fSpeakerScore) *
                        static_cast<double>(part.m_iT1 - part.m_iT0);
            }
        }
        const char* szspeaker = MessageSpeaker();
        if (*szspeaker)
        {
            out.Set("speaker", szspeaker);
        }
        if (iscored > 0)
        {
            out.Set("speakerScore", Round(fsum / static_cast<double>(iscored), 100));
        }
        if (m_pGrow)
        {
            std::string utterances = MessageText();
            if (bclosing)
            {
                StripTrailingPhrase(utterances, m_ClosingPhrase);
            }
            out.Set("live", live).Set("utterances", utterances).Set("finalOk", bfinalOk);
        }
        m_Send(out);
        m_Log(std::string("listen: message (") + _szEndedBy + ")");
        m_Msg = Message{};
        m_pGrow.reset();
        m_GrowText.clear();
    }

    void Listener::CancelMessage()
    {
        if (!m_Msg.m_bActive)
        {
            return;
        }
        const std::string id = m_Msg.m_Id;
        m_Msg = Message{};
        m_pGrow.reset();
        m_GrowText.clear();
        m_Send(Json::Object().Set("type", "cancelled").Set("id", id));
    }

    void Listener::PruneLookback()
    {
        long long itotal = 0;
        for (const Segment& segment : m_Lookback)
        {
            itotal += EstimateTokens(segment.m_Text);
        }
        const long long ikeep =
            Ms(m_iNow) - static_cast<long long>(m_Config.m_fRemarkContextSeconds * 1000);
        while (
            itotal > m_iLookbackTokens && !m_Lookback.empty() && m_Lookback.front().m_iT1 < ikeep)
        {
            itotal -= EstimateTokens(m_Lookback.front().m_Text);
            m_Lookback.pop_front();
        }
    }

    Json Listener::NewestSegments(long long _iBeforeMs, int _iTokens) const
    {
        std::vector<const Segment*> picked; // newest first
        long long iused = 0;
        for (auto it = m_Lookback.rbegin(); it != m_Lookback.rend(); ++it)
        {
            if (it->m_iT1 > _iBeforeMs)
            {
                continue;
            }
            const long long itokens = EstimateTokens(it->m_Text);
            if (iused + itokens > _iTokens)
            {
                break;
            }
            iused += itokens;
            picked.push_back(&*it);
        }
        Json segments = Json::Array();
        for (auto it = picked.rbegin(); it != picked.rend(); ++it)
        {
            segments.Push(SegmentJson(**it));
        }
        return segments;
    }

} // namespace gitgud::speech
