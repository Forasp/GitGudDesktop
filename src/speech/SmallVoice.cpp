#include "speech/SmallVoice.h"

#include "speech/SherpaApi.h"

#include "onnxruntime_c_api.h"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace gitgud::speech
{

    namespace fs = std::filesystem;
    using namespace std::chrono_literals;

    namespace
    {

        void Check(const OrtApi* _pApi, OrtStatus* _pStatus)
        {
            if (_pStatus)
            {
                const std::string message = _pApi->GetErrorMessage(_pStatus);
                _pApi->ReleaseStatus(_pStatus);
                throw std::runtime_error(message);
            }
        }

        // The length of the UTF-8 sequence starting with `_C` (1 for a stray byte).
        std::size_t Utf8Length(unsigned char _C)
        {
            if (_C >= 0xF0)
            {
                return 4;
            }
            if (_C >= 0xE0)
            {
                return 3;
            }
            if (_C >= 0xC0)
            {
                return 2;
            }
            return 1;
        }

    } // namespace

    bool ParsePhonemeTable(
        const std::string& _Text, std::map<std::string, int64_t>& _Out, std::string& _Error)
    {
        _Out.clear();
        std::istringstream in(_Text);
        std::string line;
        int iline = 0;
        while (std::getline(in, line))
        {
            ++iline;
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }
            if (line.empty())
            {
                continue;
            }
            const std::size_t ntab = line.find('\t');
            if (ntab == 0 || ntab == std::string::npos || ntab + 1 == line.size())
            {
                _Error = "phoneme table line " + std::to_string(iline) + " isn't symbol<TAB>id";
                return false;
            }
            try
            {
                _Out[line.substr(0, ntab)] = std::stoll(line.substr(ntab + 1));
            }
            catch (const std::exception&)
            {
                _Error = "phoneme table line " + std::to_string(iline) + " has no number";
                return false;
            }
        }
        if (_Out.empty())
        {
            _Error = "the phoneme table is empty";
            return false;
        }
        return true;
    }

    std::vector<int64_t> PhonemeIds(
        const std::string& _Phonemes, const std::map<std::string, int64_t>& _Table)
    {
        std::vector<int64_t> ids{0};
        for (std::size_t ni = 0; ni < _Phonemes.size();)
        {
            const std::size_t nlength = std::min(
                Utf8Length(static_cast<unsigned char>(_Phonemes[ni])), _Phonemes.size() - ni);
            const auto it = _Table.find(_Phonemes.substr(ni, nlength));
            if (it != _Table.end())
            {
                ids.push_back(it->second);
            }
            ni += nlength;
        }
        ids.push_back(0);
        return ids;
    }

    struct SmallVoice::Impl
    {
        const OrtApi* m_pApi = nullptr;
        OrtEnv* m_pEnv = nullptr;
        OrtSessionOptions* m_pOptions = nullptr;
        OrtMemoryInfo* m_pCpu = nullptr;
        OrtSession* m_pSession = nullptr;
        bool m_bWobble = false; // the graph takes a wobble input
        std::string m_Output;
    };

    SmallVoice::SmallVoice(std::string _Dir, int _iThreads, CallFn _Call)
        : m_Dir(std::move(_Dir)), m_iThreads(_iThreads), m_Call(std::move(_Call)),
          m_pImpl(std::make_unique<Impl>())
    {
    }

    SmallVoice::~SmallVoice()
    {
        if (m_bPoisoned || !m_pImpl->m_pApi)
        {
            (void)m_pImpl.release(); // leaked on purpose: releasing could fault again
            return;
        }
        Impl& impl = *m_pImpl;
        m_Call("release the small voice", 30s,
            [&]()
            {
                if (impl.m_pSession)
                {
                    impl.m_pApi->ReleaseSession(impl.m_pSession);
                }
                if (impl.m_pCpu)
                {
                    impl.m_pApi->ReleaseMemoryInfo(impl.m_pCpu);
                }
                if (impl.m_pOptions)
                {
                    impl.m_pApi->ReleaseSessionOptions(impl.m_pOptions);
                }
                if (impl.m_pEnv)
                {
                    impl.m_pApi->ReleaseEnv(impl.m_pEnv);
                }
            });
    }

    bool SmallVoice::Load(std::string& _Error)
    {
        const fs::path dir = fs::u8path(m_Dir);
        {
            std::ifstream in(dir / "phonemes.tsv", std::ios::binary);
            if (!in)
            {
                _Error = "missing " + (dir / "phonemes.tsv").u8string();
                return false;
            }
            std::stringstream ss;
            ss << in.rdbuf();
            if (!ParsePhonemeTable(ss.str(), m_Table, _Error))
            {
                return false;
            }
        }
        const fs::path model = dir / "model.onnx";
        std::error_code ec;
        if (!fs::is_regular_file(model, ec))
        {
            _Error = "missing " + model.u8string();
            return false;
        }
        Impl& impl = *m_pImpl;
        impl.m_pApi = static_cast<const OrtApi*>(OrtApiTable(ORT_API_VERSION));
        if (!impl.m_pApi)
        {
            _Error = "ONNX Runtime isn't loaded";
            return false;
        }
        const bool bok = m_Call("load the small voice", 60s,
            [&]()
            {
                const OrtApi* api = impl.m_pApi;
                Check(api,
                    api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gitgud-small-voice", &impl.m_pEnv));
                Check(api, api->CreateSessionOptions(&impl.m_pOptions));
                Check(api, api->SetIntraOpNumThreads(impl.m_pOptions, m_iThreads));
                Check(api, api->SetInterOpNumThreads(impl.m_pOptions, 1));
                Check(api, api->SetSessionGraphOptimizationLevel(impl.m_pOptions, ORT_ENABLE_ALL));
                Check(api, api->AddSessionConfigEntry(
                               impl.m_pOptions, "session.intra_op.allow_spinning", "0"));
                Check(api,
                    api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &impl.m_pCpu));
                Check(api, api->CreateSession(
                               impl.m_pEnv, model.c_str(), impl.m_pOptions, &impl.m_pSession));
                OrtAllocator* pallocator = nullptr;
                Check(api, api->GetAllocatorWithDefaultOptions(&pallocator));
                std::size_t ncount = 0;
                Check(api, api->SessionGetInputCount(impl.m_pSession, &ncount));
                bool bids = false;
                bool bspeed = false;
                for (std::size_t ni = 0; ni < ncount; ++ni)
                {
                    char* szname = nullptr;
                    Check(api, api->SessionGetInputName(impl.m_pSession, ni, pallocator, &szname));
                    const std::string name = szname;
                    Check(api, api->AllocatorFree(pallocator, szname));
                    bids = bids || name == "input_ids";
                    bspeed = bspeed || name == "speed";
                    impl.m_bWobble = impl.m_bWobble || name == "wobble";
                }
                Check(api, api->SessionGetOutputCount(impl.m_pSession, &ncount));
                if (!bids || !bspeed || ncount < 1)
                {
                    throw std::runtime_error("this isn't a small voice model (input_ids, speed)");
                }
                char* szout = nullptr;
                Check(api, api->SessionGetOutputName(impl.m_pSession, 0, pallocator, &szout));
                impl.m_Output = szout;
                Check(api, api->AllocatorFree(pallocator, szout));
            });
        if (!bok)
        {
            _Error = "the small voice didn't load";
            return false;
        }
        return true;
    }

    bool SmallVoice::Say(const std::string& _Phonemes, double _fSpeed, double _fWobble,
        std::vector<float>& _Audio, std::string& _Error)
    {
        _Audio.clear();
        Impl& impl = *m_pImpl;
        if (!impl.m_pSession)
        {
            _Error = "the small voice isn't loaded";
            return false;
        }
        std::vector<int64_t> ids = PhonemeIds(_Phonemes, m_Table);
        m_nLastIds = ids.size() - 2;
        if (m_nLastIds == 0)
        {
            return true; // nothing it can say
        }
        if (m_nLastIds > kSmallVoiceMaxIds)
        {
            ids.resize(kSmallVoiceMaxIds + 1);
            ids.push_back(0);
            m_nLastIds = kSmallVoiceMaxIds;
        }
        float fspeed = static_cast<float>(_fSpeed > 0.0 ? _fSpeed : 1.0);
        float fwobble = static_cast<float>(_fWobble);
        const int64_t idsShape[] = {1, static_cast<int64_t>(ids.size())};
        const int64_t oneShape[] = {1};
        const bool bok = m_Call("say with the small voice", 30s,
            [&]()
            {
                const OrtApi* api = impl.m_pApi;
                std::vector<OrtValue*> inputs;
                std::vector<const char*> names;
                OrtValue* poutput = nullptr;
                auto release = [&]()
                {
                    for (OrtValue* p : inputs)
                    {
                        api->ReleaseValue(p);
                    }
                    if (poutput)
                    {
                        api->ReleaseValue(poutput);
                    }
                };
                try
                {
                    OrtValue* pvalue = nullptr;
                    Check(api, api->CreateTensorWithDataAsOrtValue(impl.m_pCpu, ids.data(),
                                   ids.size() * sizeof(int64_t), idsShape, 2,
                                   ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &pvalue));
                    inputs.push_back(pvalue);
                    names.push_back("input_ids");
                    Check(api,
                        api->CreateTensorWithDataAsOrtValue(impl.m_pCpu, &fspeed, sizeof(float),
                            oneShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &pvalue));
                    inputs.push_back(pvalue);
                    names.push_back("speed");
                    if (impl.m_bWobble)
                    {
                        Check(api, api->CreateTensorWithDataAsOrtValue(impl.m_pCpu, &fwobble,
                                       sizeof(float), oneShape, 1,
                                       ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &pvalue));
                        inputs.push_back(pvalue);
                        names.push_back("wobble");
                    }
                    const char* outName = impl.m_Output.c_str();
                    Check(api, api->Run(impl.m_pSession, nullptr, names.data(), inputs.data(),
                                   inputs.size(), &outName, 1, &poutput));
                    OrtTensorTypeAndShapeInfo* pinfo = nullptr;
                    Check(api, api->GetTensorTypeAndShape(poutput, &pinfo));
                    std::size_t ncount = 0;
                    OrtStatus* pstatus = api->GetTensorShapeElementCount(pinfo, &ncount);
                    api->ReleaseTensorTypeAndShapeInfo(pinfo);
                    Check(api, pstatus);
                    float* pdata = nullptr;
                    Check(
                        api, api->GetTensorMutableData(poutput, reinterpret_cast<void**>(&pdata)));
                    _Audio.assign(pdata, pdata + ncount);
                }
                catch (...)
                {
                    release();
                    throw;
                }
                release();
            });
        if (!bok)
        {
            _Error = "the small voice failed to speak";
        }
        return bok;
    }

} // namespace gitgud::speech
