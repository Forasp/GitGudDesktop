#include "speech/Recognizer.h"

#include "speech/SherpaApi.h"
#include "speech/TextClassifier.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
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

        bool FileExists(const std::string& _Path)
        {
            std::error_code ec;
            return !_Path.empty() && fs::is_regular_file(fs::u8path(_Path), ec);
        }

        // ---- SentencePiece model (protobuf) ----

        bool ReadVarint(const std::string& _Bytes, std::size_t& _nAt, std::uint64_t& _uValue)
        {
            _uValue = 0;
            for (int ishift = 0; _nAt < _Bytes.size() && ishift < 64; ishift += 7)
            {
                const std::uint8_t c = static_cast<std::uint8_t>(_Bytes[_nAt++]);
                _uValue |= static_cast<std::uint64_t>(c & 0x7F) << ishift;
                if (!(c & 0x80))
                {
                    return true;
                }
            }
            return false;
        }

        bool SkipField(const std::string& _Bytes, std::size_t& _nAt, int _iWireType)
        {
            std::uint64_t uvalue = 0;
            switch (_iWireType)
            {
            case 0:
                return ReadVarint(_Bytes, _nAt, uvalue);
            case 1:
                _nAt += 8;
                return _nAt <= _Bytes.size();
            case 2:
                if (!ReadVarint(_Bytes, _nAt, uvalue))
                {
                    return false;
                }
                _nAt += static_cast<std::size_t>(uvalue);
                return _nAt <= _Bytes.size();
            case 5:
                _nAt += 4;
                return _nAt <= _Bytes.size();
            default:
                return false;
            }
        }

        std::vector<std::string> Utf8Chars(const std::string& _Text)
        {
            std::vector<std::string> out;
            for (std::size_t ni = 0; ni < _Text.size();)
            {
                const unsigned char c = static_cast<unsigned char>(_Text[ni]);
                const std::size_t nlength = c < 0x80         ? 1
                                            : (c >> 5) == 6  ? 2
                                            : (c >> 4) == 14 ? 3
                                                             : 4;
                out.push_back(_Text.substr(ni, nlength));
                ni += nlength;
            }
            return out;
        }

        // Numbers from Lua: kept to [lo, hi]; a non-number is an error.
        bool ReadNumber(const Json& _Json, const char* _szKey, double _fLo, double _fHi,
            double& _fOut, std::string& _Error)
        {
            if (!_Json.Has(_szKey))
            {
                return true;
            }
            const Json& value = _Json[_szKey];
            if (!value.IsNumber() || !std::isfinite(value.AsNumber()))
            {
                _Error = std::string(_szKey) + " must be a number";
                return false;
            }
            _fOut = std::min(_fHi, std::max(_fLo, value.AsNumber()));
            return true;
        }

    } // namespace

    // ---- EngineConfig ----------------------------------------------------------

    bool EngineConfig::FromJson(const Json& _Json, EngineConfig& _Out, std::string& _Error)
    {
        if (!_Json.IsObject())
        {
            _Error = "the engine's settings must be a table";
            return false;
        }
        auto text = [&](const char* _szKey, std::string& _Field)
        {
            if (!_Json.Has(_szKey))
            {
                return true;
            }
            if (!_Json[_szKey].IsString())
            {
                _Error = std::string(_szKey) + " must be text";
                return false;
            }
            _Field = _Json[_szKey].AsString();
            return true;
        };
        auto list = [&](const char* _szKey, std::vector<std::string>& _Field)
        {
            if (!_Json.Has(_szKey))
            {
                return true;
            }
            if (!_Json[_szKey].IsArray() &&
                !(_Json[_szKey].IsObject() && _Json[_szKey].Size() == 0))
            {
                _Error = std::string(_szKey) + " must be a list";
                return false;
            }
            _Field.clear();
            for (const Json& item : _Json[_szKey].Items())
            {
                if (item.IsString() && !item.AsString().empty())
                {
                    _Field.push_back(item.AsString());
                }
            }
            return true;
        };
        auto number = [&](const char* _szKey, double _fLo, double _fHi, auto& _Field)
        {
            double fvalue = static_cast<double>(_Field);
            if (!ReadNumber(_Json, _szKey, _fLo, _fHi, fvalue, _Error))
            {
                return false;
            }
            using T = std::decay_t<decltype(_Field)>;
            _Field = std::is_integral_v<T> ? static_cast<T>(std::lround(fvalue))
                                           : static_cast<T>(fvalue);
            return true;
        };
        auto flag = [&](const char* _szKey, bool& _Field)
        {
            if (_Json.Has(_szKey))
            {
                if (!_Json[_szKey].IsBool())
                {
                    _Error = std::string(_szKey) + " must be true or false";
                    return false;
                }
                _Field = _Json[_szKey].AsBool();
            }
            return true;
        };

        EngineConfig c = _Out;
        const bool bok =
            text("vadModel", c.m_VadModel) && text("asrDir", c.m_AsrDir) &&
            text("asrName", c.m_AsrName) && text("kwsDir", c.m_KwsDir) &&
            text("speakerModel", c.m_SpeakerModel) && text("voiceprintsDir", c.m_VoiceprintsDir) &&
            text("workDir", c.m_WorkDir) && text("endBy", c.m_EndBy) &&
            text("deciderModel", c.m_DeciderModel) && text("deciderVocab", c.m_DeciderVocab) &&
            number("deciderThreads", 1, 8, c.m_iDeciderThreads) &&
            text("asrProvider", c.m_AsrProvider) && text("speakerProvider", c.m_SpeakerProvider) &&
            text("wakeWord", c.m_WakeWord) && list("spotterSpellings", c.m_SpotterSpellings) &&
            list("mishearings", c.m_Mishearings) && number("asrThreads", 1, 16, c.m_iAsrThreads) &&
            number("kwsThreads", 1, 4, c.m_iKwsThreads) &&
            number("speakerThreads", 1, 16, c.m_iSpeakerThreads) &&
            flag("hotwords", c.m_bHotwords) &&
            number("hotwordsScore", 0.1, 10, c.m_fHotwordsScore) &&
            number("asrMaxSeconds", 2, 60, c.m_fAsrMaxSeconds) && flag("spinning", c.m_bSpinning) &&
            number("speakerThreshold", -1, 1, c.m_fSpeakerThreshold) &&
            number("speakerMinSeconds", 0.1, 30, c.m_fSpeakerMinSeconds) &&
            number("speakerUnsureBelow", -1, 1, c.m_fSpeakerUnsureBelow) &&
            number("speakerUnsureSeconds", 0, 60, c.m_fSpeakerUnsureSeconds) &&
            flag("speakerGate", c.m_bSpeakerGate) &&
            number("speakerGateBelow", -1, 1, c.m_fSpeakerGateBelow) &&
            number("speakerGateWindowSeconds", 0.2, 10, c.m_fSpeakerGateWindowSeconds) &&
            number("speakerGateEverySeconds", 0, 10, c.m_fSpeakerGateEverySeconds) &&
            number("speakerGateWindows", 1, 20, c.m_iSpeakerGateWindows) &&
            number("enrollMinSeconds", 1, 600, c.m_fEnrollMinSeconds) &&
            number("vadThreshold", 0.05, 0.95, c.m_fVadThreshold) &&
            number("silenceSeconds", 0.1, 5, c.m_fSilenceSeconds) &&
            number("minSpeechSeconds", 0.05, 5, c.m_fMinSpeechSeconds) &&
            number("prerollSeconds", 0, 2, c.m_fPrerollSeconds) &&
            number("maxUtteranceSeconds", 2, 60, c.m_fMaxUtteranceSeconds) &&
            number("partialSeconds", 0.2, 10, c.m_fPartialSeconds) &&
            text("transcribe", c.m_Transcribe) &&
            number("growEverySeconds", 0.2, 10, c.m_fGrowEverySeconds) &&
            number("growEveryLongSeconds", 0.2, 30, c.m_fGrowEveryLongSeconds) &&
            number("growLongAfterSeconds", 0, 120, c.m_fGrowLongAfterSeconds) &&
            number("growCostFactor", 1, 10, c.m_fGrowCostFactor) &&
            flag("growHotwords", c.m_bGrowHotwords) &&
            number("bufferSeconds", 4, 120, c.m_fBufferSeconds) &&
            number("bufferSnapSeconds", 0, 60, c.m_fBufferSnapSeconds) &&
            number("keepBeforeSeconds", 0, 5, c.m_fKeepBeforeSeconds) &&
            number("keepAfterSeconds", 0, 5, c.m_fKeepAfterSeconds) &&
            number("gapMaxSeconds", 0.1, 60, c.m_fGapMaxSeconds) &&
            number("gapKeepSeconds", 0, 10, c.m_fGapKeepSeconds) &&
            number("fadeSeconds", 0, 0.5, c.m_fFadeSeconds) &&
            number("fillLevel", 0, 0.05, c.m_fFillLevel) &&
            number("closingSilenceSeconds", 0, 10, c.m_fClosingSilenceSeconds) &&
            number("wakeThreshold", 0.01, 0.99, c.m_fWakeThreshold) &&
            number("wakeBoost", 0.1, 10, c.m_fWakeBoost) && flag("textWake", c.m_bTextWake) &&
            number("wakeEndSeconds", 0, 10, c.m_fWakeEndSeconds) &&
            number("wakeStartSeconds", 0, 10, c.m_fWakeStartSeconds) &&
            number("remarkMaxWords", 0, 100, c.m_iRemarkMaxWords) &&
            number("remarkQuestionMaxWords", 0, 200, c.m_iRemarkQuestionMaxWords) &&
            number("remarkContextSeconds", 0, 600, c.m_fRemarkContextSeconds) &&
            number("contextTokens", 0, 50000, c.m_iContextTokens) &&
            number("messageContextTokens", 0, 50000, c.m_iMessageContextTokens) &&
            number("lookbackTokens", 1, 50000, c.m_iLookbackTokens) &&
            number("playbackTailSeconds", 0, 10, c.m_fPlaybackTailSeconds);
        if (!bok)
        {
            return false;
        }
        if (c.m_EndBy != "app" && c.m_EndBy != "engine")
        {
            _Error = "endBy must be app or engine";
            return false;
        }
        if (c.m_Transcribe != "utterances" && c.m_Transcribe != "growing")
        {
            _Error = "transcribe must be utterances or growing";
            return false;
        }
        for (const std::string* pprovider : {&c.m_AsrProvider, &c.m_SpeakerProvider})
        {
            if (*pprovider != "cpu" && *pprovider != "cuda")
            {
                _Error = "a provider is cpu or cuda";
                return false;
            }
        }
        _Out = std::move(c);
        return true;
    }

    // ---- BpeTokenizer, tokens, lines ------------------------------------------

    bool BpeTokenizer::Load(const std::string& _Path, std::string& _Error)
    {
        std::ifstream file(fs::u8path(_Path), std::ios::binary);
        if (!file)
        {
            _Error = "cannot open " + _Path;
            return false;
        }
        std::stringstream ss;
        ss << file.rdbuf();
        const std::string bytes = ss.str();
        std::map<std::string, float> scores;
        std::size_t nat = 0;
        while (nat < bytes.size())
        {
            std::uint64_t ukey = 0;
            if (!ReadVarint(bytes, nat, ukey))
            {
                break;
            }
            const int ifield = static_cast<int>(ukey >> 3);
            const int iwire = static_cast<int>(ukey & 7);
            if (ifield == 1 && iwire == 2)
            {
                std::uint64_t ulength = 0;
                if (!ReadVarint(bytes, nat, ulength) || nat + ulength > bytes.size())
                {
                    break;
                }
                const std::string sub = bytes.substr(nat, static_cast<std::size_t>(ulength));
                nat += static_cast<std::size_t>(ulength);
                std::string piece;
                float fscore = 0;
                int itype = 1;
                std::size_t nj = 0;
                while (nj < sub.size())
                {
                    std::uint64_t ukey2 = 0;
                    if (!ReadVarint(sub, nj, ukey2))
                    {
                        break;
                    }
                    const int ifield2 = static_cast<int>(ukey2 >> 3);
                    const int iwire2 = static_cast<int>(ukey2 & 7);
                    if (ifield2 == 1 && iwire2 == 2)
                    {
                        std::uint64_t upiece = 0;
                        if (!ReadVarint(sub, nj, upiece) || nj + upiece > sub.size())
                        {
                            break;
                        }
                        piece = sub.substr(nj, static_cast<std::size_t>(upiece));
                        nj += static_cast<std::size_t>(upiece);
                    }
                    else if (ifield2 == 2 && iwire2 == 5 && nj + 4 <= sub.size())
                    {
                        std::memcpy(&fscore, sub.data() + nj, 4);
                        nj += 4;
                    }
                    else if (ifield2 == 3 && iwire2 == 0)
                    {
                        std::uint64_t utype = 0;
                        ReadVarint(sub, nj, utype);
                        itype = static_cast<int>(utype);
                    }
                    else if (!SkipField(sub, nj, iwire2))
                    {
                        break;
                    }
                }
                if (itype == 1 || itype == 4) // NORMAL or USER_DEFINED
                {
                    scores[piece] = fscore;
                }
            }
            else if (!SkipField(bytes, nat, iwire))
            {
                break;
            }
        }
        if (scores.empty())
        {
            _Error = "no pieces in " + _Path;
            return false;
        }
        m_Scores = std::move(scores);
        return true;
    }

    std::vector<std::string> BpeTokenizer::Encode(const std::string& _Text) const
    {
        std::string norm;
        bool bspace = true;
        for (char c : _Text)
        {
            if (c == ' ' || c == '\t' || c == ',' || c == '.' || c == '!' || c == '?')
            {
                bspace = true;
                continue;
            }
            if (bspace)
            {
                norm += "\xE2\x96\x81"; // U+2581, SentencePiece's word start
            }
            bspace = false;
            norm += (c >= 'a' && c <= 'z') ? static_cast<char>(c - 32) : c;
        }
        // Unigram Viterbi: the segmentation with the highest total score.
        // Unknown characters become single pieces with a heavy penalty (and
        // then fail the token check).
        const std::vector<std::string> chars = Utf8Chars(norm);
        const std::size_t ncount = chars.size();
        std::vector<double> best(ncount + 1, -1e300);
        std::vector<std::size_t> from(ncount + 1, 0);
        best[0] = 0;
        for (std::size_t ni = 0; ni < ncount; ++ni)
        {
            if (best[ni] <= -1e299)
            {
                continue;
            }
            std::string piece;
            for (std::size_t nj = ni; nj < ncount && nj - ni < 16; ++nj)
            {
                piece += chars[nj];
                const auto it = m_Scores.find(piece);
                const double fscore =
                    it != m_Scores.end() ? it->second : (nj == ni ? -100.0 : -1e300);
                if (fscore <= -1e299)
                {
                    continue;
                }
                if (best[ni] + fscore > best[nj + 1])
                {
                    best[nj + 1] = best[ni] + fscore;
                    from[nj + 1] = ni;
                }
            }
        }
        std::vector<std::string> pieces;
        for (std::size_t nk = ncount; nk > 0; nk = from[nk])
        {
            std::string piece;
            for (std::size_t nc = from[nk]; nc < nk; ++nc)
            {
                piece += chars[nc];
            }
            pieces.insert(pieces.begin(), piece);
        }
        return pieces;
    }

    std::map<std::string, int> LoadTokens(const std::string& _Path)
    {
        std::map<std::string, int> out;
        std::ifstream file(fs::u8path(_Path), std::ios::binary);
        std::string line;
        while (std::getline(file, line))
        {
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }
            const std::size_t nspace = line.rfind(' ');
            if (nspace == std::string::npos || nspace == 0)
            {
                continue;
            }
            out[line.substr(0, nspace)] = std::atoi(line.c_str() + nspace + 1);
        }
        return out;
    }

    std::string KeywordLine(const BpeTokenizer& _Bpe, const std::map<std::string, int>& _Tokens,
        const std::string& _Phrase, float _fBoost, float _fThreshold)
    {
        if (!_Bpe.Loaded() || _Tokens.empty())
        {
            return {};
        }
        const std::vector<std::string> pieces = _Bpe.Encode(_Phrase);
        if (pieces.empty())
        {
            return {};
        }
        std::string line;
        for (const std::string& piece : pieces)
        {
            if (!_Tokens.count(piece))
            {
                return {}; // would make a stream that crashes when fed
            }
            line += piece + " ";
        }
        char abuf[64];
        std::snprintf(abuf, sizeof(abuf), ":%.2f #%.2f @", _fBoost, _fThreshold);
        std::string label;
        for (char c : _Phrase)
        {
            if (c == '/' || c == '@' || c == ':' || c == '#')
            {
                return {}; // the line format's own characters
            }
            label += c == ' ' ? '_' : c;
        }
        return line + abuf + label;
    }

    std::string HotwordLine(
        const std::map<std::string, int>& _Tokens, const std::string& _Phrase, float _fBoost)
    {
        // Words of characters the model has; '/' (a line break) and ':' (the
        // boost) are the format's own.
        std::string line;
        std::istringstream words(_Phrase);
        std::string word;
        while (words >> word)
        {
            for (char c : word)
            {
                if (c == '/' || c == ':' || !_Tokens.count(std::string(1, c)))
                {
                    return {};
                }
            }
            if (!line.empty())
            {
                line += ' ';
            }
            line += word;
        }
        if (line.empty())
        {
            return {};
        }
        if (_fBoost > 0)
        {
            char abuf[32];
            std::snprintf(abuf, sizeof(abuf), " :%.2f", static_cast<double>(_fBoost));
            line += abuf;
        }
        return line;
    }

    // ---- Recognizer ------------------------------------------------------------

    Recognizer::Recognizer(EngineConfig _Config, CallFn _Call)
        : m_Config(std::move(_Config)), m_Call(std::move(_Call))
    {
    }

    void Recognizer::SetPoisoned()
    {
        m_bPoisoned = true;
        if (m_pDecider)
        {
            m_pDecider->SetPoisoned();
        }
    }

    Recognizer::~Recognizer()
    {
        m_pDecider.reset();
        if (m_bPoisoned || !SherpaLoaded())
        {
            return; // leaked on purpose: releasing could fault again
        }
        const SherpaApi& so = Sherpa();
        if (m_pAsr)
        {
            m_Call("release the recognizer", 10s,
                [&]() { so.SherpaOnnxDestroyOfflineRecognizer(m_pAsr); });
        }
        if (m_pKws)
        {
            m_Call(
                "release the spotter", 10s, [&]() { so.SherpaOnnxDestroyKeywordSpotter(m_pKws); });
        }
        if (m_pSpeaker)
        {
            m_Call("release the speaker model", 10s,
                [&]() { so.SherpaOnnxDestroySpeakerEmbeddingExtractor(m_pSpeaker); });
        }
    }

    std::string Recognizer::ProviderFor(const std::string&)
    {
        // Listening stays on the processor: sherpa-onnx's own CUDA path
        // loads the provider from beside onnxruntime.dll, and the GPU pack
        // keeps it in its own folder (speech/SherpaApi.h). Only spoken
        // replies use the GPU.
        return Provider();
    }

    std::string Recognizer::Provider()
    {
        if (!m_ProviderString.empty())
        {
            return m_ProviderString;
        }
        m_ProviderString = "cpu";
        if (!m_Config.m_bSpinning && !m_Config.m_WorkDir.empty())
        {
            const fs::path file = fs::u8path(m_Config.m_WorkDir) / "ort-session.cfg";
            std::error_code ec;
            fs::create_directories(file.parent_path(), ec);
            {
                std::ofstream out(file, std::ios::binary | std::ios::trunc);
                out << "SessionConfig.session.intra_op.allow_spinning=0\n"
                    << "SessionConfig.session.inter_op.allow_spinning=0\n";
            }
            // A config file it can't read ends the process: only one that's there.
            if (FileExists(file.u8string()) && fs::file_size(file, ec) > 0)
            {
                m_ProviderString = "cpu:" + file.u8string();
            }
        }
        return m_ProviderString;
    }

    bool Recognizer::Load(std::string& _Error, bool& _bDamaged)
    {
        _bDamaged = false;
        const SherpaApi& so = Sherpa();
        if (!FileExists(m_Config.m_VadModel))
        {
            _Error = "missing " + m_Config.m_VadModel;
            return false;
        }

        // Parakeet: encoder, decoder, joiner (int8 or plain) and tokens.
        auto pick = [&](const char* _szName)
        {
            for (const char* szsuffix : {".int8.onnx", ".fp16.onnx", ".onnx"})
            {
                const std::string path = m_Config.m_AsrDir + "/" + _szName + szsuffix;
                if (FileExists(path))
                {
                    return path;
                }
            }
            return m_Config.m_AsrDir + "/" + _szName + ".onnx";
        };
        const std::string encoder = pick("encoder");
        const std::string decoder = pick("decoder");
        const std::string joiner = pick("joiner");
        const std::string tokens = m_Config.m_AsrDir + "/tokens.txt";
        for (const std::string* ppath : {&encoder, &decoder, &joiner, &tokens})
        {
            if (!FileExists(*ppath))
            {
                _Error = "missing " + *ppath;
                return false;
            }
        }
        m_AsrTokens = LoadTokens(tokens);
        if (!m_AsrTokens.count("<blk>") && !m_AsrTokens.count("<blank>"))
        {
            // sherpa-onnx ends the process on a tokens file without a blank.
            _Error = tokens + " isn't a recognizer's tokens file";
            _bDamaged = true;
            return false;
        }

        const std::string provider = ProviderFor(m_Config.m_AsrProvider);
        const std::string speakerProvider = ProviderFor(m_Config.m_SpeakerProvider);
        SherpaOnnxOfflineRecognizerConfig rc;
        std::memset(&rc, 0, sizeof(rc));
        rc.feat_config.sample_rate = kRate;
        rc.feat_config.feature_dim = 80;
        rc.model_config.transducer.encoder = encoder.c_str();
        rc.model_config.transducer.decoder = decoder.c_str();
        rc.model_config.transducer.joiner = joiner.c_str();
        rc.model_config.tokens = tokens.c_str();
        rc.model_config.model_type = "nemo_transducer";
        rc.model_config.provider = provider.c_str();
        rc.model_config.num_threads = m_Config.m_iAsrThreads;
        rc.decoding_method = m_Config.m_bHotwords ? "modified_beam_search" : "greedy_search";
        rc.max_active_paths = 4;
        rc.hotwords_score = m_Config.m_fHotwordsScore;
        // Hotwords are plain phrases split by sherpa-onnx with a SentencePiece
        // vocabulary; the model has only tokens.txt, whose order is the merge
        // order, so the vocabulary scores by it.
        if (m_Config.m_bHotwords)
        {
            m_VocabPath =
                (fs::u8path(m_Config.m_WorkDir.empty() ? m_Config.m_AsrDir : m_Config.m_WorkDir) /
                    (m_Config.m_AsrName + ".vocab"))
                    .u8string();
            {
                std::ofstream out(fs::u8path(m_VocabPath), std::ios::binary | std::ios::trunc);
                for (const auto& [token, iid] : m_AsrTokens)
                {
                    if (!token.empty() && token[0] != '<')
                    {
                        out << token << '\t' << -iid << '\n';
                    }
                }
            }
            if (!FileExists(m_VocabPath))
            {
                _Error = "cannot write " + m_VocabPath;
                return false;
            }
            rc.model_config.modeling_unit = "bpe";
            rc.model_config.bpe_vocab = m_VocabPath.c_str();
        }
        const bool bcalled = m_Call("load the recognizer", 120s,
            [&]() { m_pAsr = so.SherpaOnnxCreateOfflineRecognizer(&rc); });
        if (!bcalled || !m_pAsr)
        {
            _Error = "the recognizer didn't load (" + m_Config.m_AsrDir + ")";
            _bDamaged = true;
            return false;
        }
        // Warm up: the first decode is slower.
        std::vector<float> warm(kRate, 0.0f);
        for (std::size_t ni = 0; ni < warm.size(); ++ni)
        {
            warm[ni] =
                0.01f * static_cast<float>(static_cast<int>((ni * 7919) % 200) - 100) / 100.0f;
        }
        bool bok = true;
        Recognize(warm.data(), warm.size(), {}, nullptr, &bok);
        if (!bok)
        {
            _Error = "the recognizer failed its first decode";
            _bDamaged = true;
            return false;
        }

        // The keyword spotter.
        const std::string kenc =
            m_Config.m_KwsDir + "/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx";
        const std::string kdec =
            m_Config.m_KwsDir + "/decoder-epoch-12-avg-2-chunk-16-left-64.onnx";
        const std::string kjoi =
            m_Config.m_KwsDir + "/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx";
        const std::string ktok = m_Config.m_KwsDir + "/tokens.txt";
        const std::string kbpe = m_Config.m_KwsDir + "/bpe.model";
        for (const std::string* ppath : {&kenc, &kdec, &kjoi, &ktok, &kbpe})
        {
            if (!FileExists(*ppath))
            {
                _Error = "missing " + *ppath;
                return false;
            }
        }
        std::string bpeError;
        if (!m_KwsBpe.Load(kbpe, bpeError))
        {
            _Error = bpeError;
            _bDamaged = true;
            return false;
        }
        m_KwsTokens = LoadTokens(ktok);
        // The spotter needs one keyword at creation; streams bring their own.
        const std::string placeholder = KeywordLine(
            m_KwsBpe, m_KwsTokens, "hey there", m_Config.m_fWakeBoost, m_Config.m_fWakeThreshold);
        if (placeholder.empty())
        {
            _Error = "the keyword spotter's tokens don't match its model";
            _bDamaged = true;
            return false;
        }
        SherpaOnnxKeywordSpotterConfig kc;
        std::memset(&kc, 0, sizeof(kc));
        kc.feat_config.sample_rate = kRate;
        kc.feat_config.feature_dim = 80;
        kc.model_config.transducer.encoder = kenc.c_str();
        kc.model_config.transducer.decoder = kdec.c_str();
        kc.model_config.transducer.joiner = kjoi.c_str();
        kc.model_config.tokens = ktok.c_str();
        kc.model_config.provider = "cpu";
        kc.model_config.num_threads = m_Config.m_iKwsThreads;
        kc.max_active_paths = 4;
        kc.num_trailing_blanks = 1;
        kc.keywords_score = m_Config.m_fWakeBoost;
        kc.keywords_threshold = m_Config.m_fWakeThreshold;
        kc.keywords_buf = placeholder.c_str();
        kc.keywords_buf_size = static_cast<int32_t>(placeholder.size());
        if (!m_Call("load the keyword spotter", 60s,
                [&]() { m_pKws = so.SherpaOnnxCreateKeywordSpotter(&kc); }) ||
            !m_pKws)
        {
            _Error = "the keyword spotter didn't load (" + m_Config.m_KwsDir + ")";
            _bDamaged = true;
            return false;
        }

        // Speaker identification (optional: no model, no speakers).
        if (!m_Config.m_SpeakerModel.empty())
        {
            if (!FileExists(m_Config.m_SpeakerModel))
            {
                _Error = "missing " + m_Config.m_SpeakerModel;
                return false;
            }
            SherpaOnnxSpeakerEmbeddingExtractorConfig sc;
            std::memset(&sc, 0, sizeof(sc));
            sc.model = m_Config.m_SpeakerModel.c_str();
            sc.num_threads = m_Config.m_iSpeakerThreads;
            sc.provider = speakerProvider.c_str();
            if (!m_Call("load the speaker model", 60s,
                    [&]() { m_pSpeaker = so.SherpaOnnxCreateSpeakerEmbeddingExtractor(&sc); }) ||
                !m_pSpeaker)
            {
                _Error = "the speaker model didn't load (" + m_Config.m_SpeakerModel + ")";
                _bDamaged = true;
                return false;
            }
        }

        // The voice activity detector: made once here to check the model.
        const SherpaOnnxVoiceActivityDetector* pvad = CreateVad();
        if (!pvad)
        {
            _Error = "the voice activity model didn't load (" + m_Config.m_VadModel + ")";
            _bDamaged = true;
            return false;
        }
        DestroyVad(pvad);

        // The turn-taking classifier (optional: listening works without it,
        // and so does the app, which then decides without it).
        m_pDecider.reset();
        m_DeciderError.clear();
        if (!m_Config.m_DeciderModel.empty())
        {
            auto pdecider = std::make_unique<TextClassifier>(m_Config.m_DeciderModel,
                m_Config.m_DeciderVocab, m_Config.m_iDeciderThreads, m_Call);
            if (pdecider->Load(m_DeciderError))
            {
                m_pDecider = std::move(pdecider);
            }
        }
        return true;
    }

    std::string Recognizer::SpeakerModelName() const
    {
        std::string name = fs::u8path(m_Config.m_SpeakerModel).filename().u8string();
        if (name.size() > 5 && name.compare(name.size() - 5, 5, ".onnx") == 0)
        {
            name.resize(name.size() - 5);
        }
        return name;
    }

    std::vector<float> Recognizer::Embed(const float* _pSamples, std::size_t _nCount, double* _pMs)
    {
        std::vector<float> out;
        if (!m_pSpeaker || _nCount == 0)
        {
            return out;
        }
        const SherpaApi& so = Sherpa();
        const auto t0 = std::chrono::steady_clock::now();
        const auto limit = std::chrono::milliseconds(
            std::max<long long>(5000, static_cast<long long>(_nCount / 16) * 2));
        m_Call("identify the speaker", limit,
            [&]()
            {
                const SherpaOnnxOnlineStream* pstream =
                    so.SherpaOnnxSpeakerEmbeddingExtractorCreateStream(m_pSpeaker);
                if (!pstream)
                {
                    return;
                }
                so.SherpaOnnxOnlineStreamAcceptWaveform(
                    pstream, kRate, _pSamples, static_cast<int32_t>(_nCount));
                so.SherpaOnnxOnlineStreamInputFinished(pstream);
                if (so.SherpaOnnxSpeakerEmbeddingExtractorIsReady(m_pSpeaker, pstream))
                {
                    const float* pvector =
                        so.SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(m_pSpeaker, pstream);
                    if (pvector)
                    {
                        out.assign(pvector,
                            pvector + so.SherpaOnnxSpeakerEmbeddingExtractorDim(m_pSpeaker));
                        so.SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(pvector);
                    }
                }
                so.SherpaOnnxDestroyOnlineStream(pstream);
            });
        double flength = 0;
        for (float x : out)
        {
            flength += static_cast<double>(x) * x;
        }
        flength = std::sqrt(flength);
        if (flength > 0)
        {
            for (float& x : out)
            {
                x = static_cast<float>(x / flength);
            }
        }
        else
        {
            out.clear();
        }
        if (_pMs)
        {
            *_pMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                        .count();
        }
        return out;
    }

    std::string Recognizer::Recognize(const float* _pSamples, std::size_t _nCount,
        const std::string& _Hotwords, double* _pMs, bool* _pOk)
    {
        const auto t0 = std::chrono::steady_clock::now();
        const std::size_t nmost = m_Config.m_fAsrMaxSeconds > 0
                                      ? static_cast<std::size_t>(m_Config.m_fAsrMaxSeconds * kRate)
                                      : 0;
        const std::size_t npieces = nmost && _nCount > nmost ? (_nCount + nmost - 1) / nmost : 1;
        const std::size_t neach = (_nCount + npieces - 1) / npieces;
        std::string text;
        bool ball = true;
        for (std::size_t nat = 0; nat < _nCount && neach > 0; nat += neach)
        {
            bool bok = true;
            const std::string piece =
                DecodeOne(_pSamples + nat, std::min(neach, _nCount - nat), _Hotwords, bok);
            ball = ball && bok;
            if (piece.empty())
            {
                continue;
            }
            if (!text.empty())
            {
                text += ' ';
            }
            text += piece;
        }
        if (_pMs)
        {
            *_pMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                        .count();
        }
        if (_pOk)
        {
            *_pOk = ball;
        }
        return text;
    }

    std::string Recognizer::RecognizeWhole(const float* _pSamples, std::size_t _nCount,
        const std::string& _Hotwords, double* _pMs, bool* _pOk)
    {
        const auto t0 = std::chrono::steady_clock::now();
        bool bok = true;
        std::string text = DecodeOne(_pSamples, _nCount, _Hotwords, bok);
        if (_pMs)
        {
            *_pMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                        .count();
        }
        if (_pOk)
        {
            *_pOk = bok;
        }
        return text;
    }

    std::string Recognizer::DecodeOne(
        const float* _pSamples, std::size_t _nCount, const std::string& _Hotwords, bool& _bOk)
    {
        _bOk = false;
        if (!m_pAsr || _nCount == 0)
        {
            _bOk = m_pAsr != nullptr;
            return {};
        }
        const SherpaApi& so = Sherpa();
        std::string text;
        const auto limit = std::chrono::milliseconds(
            std::max<long long>(5000, static_cast<long long>(_nCount / 16) * 2));
        _bOk = m_Call("transcribe", limit,
            [&]()
            {
                const SherpaOnnxOfflineStream* pstream =
                    _Hotwords.empty() || !m_Config.m_bHotwords
                        ? so.SherpaOnnxCreateOfflineStream(m_pAsr)
                        : so.SherpaOnnxCreateOfflineStreamWithHotwords(m_pAsr, _Hotwords.c_str());
                if (!pstream)
                {
                    return;
                }
                so.SherpaOnnxAcceptWaveformOffline(
                    pstream, kRate, _pSamples, static_cast<int32_t>(_nCount));
                so.SherpaOnnxDecodeOfflineStream(m_pAsr, pstream);
                const SherpaOnnxOfflineRecognizerResult* presult =
                    so.SherpaOnnxGetOfflineStreamResult(pstream);
                if (presult && presult->text)
                {
                    text = presult->text;
                }
                if (presult)
                {
                    so.SherpaOnnxDestroyOfflineRecognizerResult(presult);
                }
                so.SherpaOnnxDestroyOfflineStream(pstream);
            });
        const std::size_t nfirst = text.find_first_not_of(' ');
        return nfirst == std::string::npos ? std::string() : text.substr(nfirst);
    }

    std::string Recognizer::KeywordLines(
        const std::vector<std::string>& _Phrases, float _fThreshold) const
    {
        std::string out;
        for (const std::string& phrase : _Phrases)
        {
            const std::string line =
                KeywordLine(m_KwsBpe, m_KwsTokens, phrase, m_Config.m_fWakeBoost, _fThreshold);
            if (line.empty())
            {
                continue;
            }
            if (!out.empty())
            {
                out += '/';
            }
            out += line;
        }
        return out;
    }

    const SherpaOnnxOnlineStream* Recognizer::CreateKwsStream(const std::string& _Keywords)
    {
        if (!m_pKws || _Keywords.empty())
        {
            return nullptr;
        }
        const SherpaOnnxOnlineStream* pstream = nullptr;
        const SherpaApi& so = Sherpa();
        m_Call("start spotting", 10s, [&]()
            { pstream = so.SherpaOnnxCreateKeywordStreamWithKeywords(m_pKws, _Keywords.c_str()); });
        return pstream;
    }

    bool Recognizer::KwsFeed(
        const SherpaOnnxOnlineStream* _pStream, const float* _pSamples, std::size_t _nCount)
    {
        if (!_pStream || !m_pKws)
        {
            return false;
        }
        const SherpaApi& so = Sherpa();
        bool bhit = false;
        m_Call("spot the wake word", 5s,
            [&]()
            {
                if (_nCount)
                {
                    so.SherpaOnnxOnlineStreamAcceptWaveform(
                        _pStream, kRate, _pSamples, static_cast<int32_t>(_nCount));
                }
                while (so.SherpaOnnxIsKeywordStreamReady(m_pKws, _pStream))
                {
                    so.SherpaOnnxDecodeKeywordStream(m_pKws, _pStream);
                    const SherpaOnnxKeywordResult* presult =
                        so.SherpaOnnxGetKeywordResult(m_pKws, _pStream);
                    if (presult && presult->keyword && presult->keyword[0])
                    {
                        bhit = true;
                        so.SherpaOnnxResetKeywordStream(m_pKws, _pStream);
                    }
                    if (presult)
                    {
                        so.SherpaOnnxDestroyKeywordResult(presult);
                    }
                }
            });
        return bhit;
    }

    void Recognizer::KwsFinish(const SherpaOnnxOnlineStream* _pStream)
    {
        if (_pStream)
        {
            const SherpaApi& so = Sherpa();
            m_Call(
                "finish spotting", 5s, [&]() { so.SherpaOnnxOnlineStreamInputFinished(_pStream); });
        }
    }

    void Recognizer::DestroyKwsStream(const SherpaOnnxOnlineStream* _pStream)
    {
        if (_pStream && !m_bPoisoned)
        {
            const SherpaApi& so = Sherpa();
            m_Call("stop spotting", 5s, [&]() { so.SherpaOnnxDestroyOnlineStream(_pStream); });
        }
    }

    float Recognizer::KwsScore(
        const std::vector<std::string>& _Phrases, const float* _pSamples, std::size_t _nCount)
    {
        if (!m_pKws)
        {
            return 0;
        }
        std::vector<float> padded(8000, 0.0f);
        padded.insert(padded.end(), _pSamples, _pSamples + _nCount);
        padded.insert(padded.end(), 8000, 0.0f);
        auto detects = [&](int _iStep)
        {
            const std::string line = KeywordLines(_Phrases, static_cast<float>(_iStep) * 0.05f);
            const SherpaOnnxOnlineStream* pstream = CreateKwsStream(line);
            if (!pstream)
            {
                return false;
            }
            bool bhit = KwsFeed(pstream, padded.data(), padded.size());
            KwsFinish(pstream);
            bhit = KwsFeed(pstream, nullptr, 0) || bhit;
            DestroyKwsStream(pstream);
            return bhit;
        };
        // Steps 1..19 are thresholds 0.05..0.95; detection falls with the threshold.
        if (!detects(1))
        {
            return 0;
        }
        int ilo = 1;
        int ihi = 20;
        while (ihi - ilo > 1)
        {
            const int imid = (ilo + ihi) / 2;
            if (detects(imid))
            {
                ilo = imid;
            }
            else
            {
                ihi = imid;
            }
        }
        return static_cast<float>(ilo) * 0.05f;
    }

    const SherpaOnnxVoiceActivityDetector* Recognizer::CreateVad()
    {
        SherpaOnnxVadModelConfig vc;
        std::memset(&vc, 0, sizeof(vc));
        vc.silero_vad.model = m_Config.m_VadModel.c_str();
        vc.silero_vad.threshold = m_Config.m_fVadThreshold;
        vc.silero_vad.min_silence_duration = m_Config.m_fSilenceSeconds;
        vc.silero_vad.min_speech_duration = m_Config.m_fMinSpeechSeconds;
        vc.silero_vad.window_size = 512; // Silero at 16 kHz; anything else ends the process
        vc.silero_vad.max_speech_duration = m_Config.m_fMaxUtteranceSeconds;
        vc.sample_rate = kRate;
        vc.num_threads = 1;
        vc.provider = "cpu";
        const SherpaOnnxVoiceActivityDetector* pvad = nullptr;
        const SherpaApi& so = Sherpa();
        m_Call("load the voice activity model", 30s,
            [&]()
            {
                pvad = so.SherpaOnnxCreateVoiceActivityDetector(
                    &vc, m_Config.m_fMaxUtteranceSeconds + 10.0f);
            });
        return pvad;
    }

    void Recognizer::DestroyVad(const SherpaOnnxVoiceActivityDetector* _pVad)
    {
        if (_pVad && !m_bPoisoned)
        {
            const SherpaApi& so = Sherpa();
            m_Call("release the voice activity model", 5s,
                [&]() { so.SherpaOnnxDestroyVoiceActivityDetector(_pVad); });
        }
    }

    bool Recognizer::VadFeed(const SherpaOnnxVoiceActivityDetector* _pVad, const float* _pSamples,
        std::size_t _nCount, bool& _bSpeech, std::vector<SpeechSegment>& _Segments)
    {
        if (!_pVad)
        {
            return false;
        }
        const SherpaApi& so = Sherpa();
        return m_Call("detect speech", 5s,
            [&]()
            {
                so.SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                    _pVad, _pSamples, static_cast<int32_t>(_nCount));
                _bSpeech = so.SherpaOnnxVoiceActivityDetectorDetected(_pVad) != 0;
                while (!so.SherpaOnnxVoiceActivityDetectorEmpty(_pVad))
                {
                    const SherpaOnnxSpeechSegment* psegment =
                        so.SherpaOnnxVoiceActivityDetectorFront(_pVad);
                    if (psegment)
                    {
                        SpeechSegment segment;
                        segment.m_iStart = psegment->start;
                        segment.m_Samples.assign(
                            psegment->samples, psegment->samples + psegment->n);
                        _Segments.push_back(std::move(segment));
                        so.SherpaOnnxDestroySpeechSegment(psegment);
                    }
                    so.SherpaOnnxVoiceActivityDetectorPop(_pVad);
                }
            });
    }

    std::string Recognizer::HotwordLineFor(const std::string& _Phrase, float _fBoost) const
    {
        return HotwordLine(m_AsrTokens, _Phrase, _fBoost);
    }

} // namespace gitgud::speech
