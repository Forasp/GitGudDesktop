#include "speech/TextClassifier.h"

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

    } // namespace

    struct TextClassifier::Impl
    {
        const OrtApi* m_pApi = nullptr;
        OrtEnv* m_pEnv = nullptr;
        OrtSessionOptions* m_pOptions = nullptr;
        OrtMemoryInfo* m_pCpu = nullptr;
        OrtSession* m_pSession = nullptr;
        std::vector<std::string> m_In;
        std::vector<std::string> m_Out;

        void Release()
        {
            if (m_pSession)
            {
                m_pApi->ReleaseSession(m_pSession);
                m_pSession = nullptr;
            }
            if (m_pCpu)
            {
                m_pApi->ReleaseMemoryInfo(m_pCpu);
                m_pCpu = nullptr;
            }
            if (m_pOptions)
            {
                m_pApi->ReleaseSessionOptions(m_pOptions);
                m_pOptions = nullptr;
            }
            if (m_pEnv)
            {
                m_pApi->ReleaseEnv(m_pEnv);
                m_pEnv = nullptr;
            }
        }

        // Run on `_Ids`; each output's first row.
        void Run(const std::vector<int64_t>& _Ids, Outputs& _Out)
        {
            std::vector<int64_t> ids = _Ids;
            std::vector<int64_t> mask(ids.size(), 1);
            const int64_t shape[2] = {1, static_cast<int64_t>(ids.size())};
            OrtValue* pids = nullptr;
            OrtValue* pmask = nullptr;
            std::vector<OrtValue*> outputs(m_Out.size(), nullptr);
            auto release = [&]()
            {
                for (OrtValue* p : {pids, pmask})
                {
                    if (p)
                    {
                        m_pApi->ReleaseValue(p);
                    }
                }
                for (OrtValue*& p : outputs)
                {
                    if (p)
                    {
                        m_pApi->ReleaseValue(p);
                        p = nullptr;
                    }
                }
            };
            try
            {
                Check(m_pApi, m_pApi->CreateTensorWithDataAsOrtValue(m_pCpu, ids.data(),
                                  ids.size() * sizeof(int64_t), shape, 2,
                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &pids));
                Check(m_pApi, m_pApi->CreateTensorWithDataAsOrtValue(m_pCpu, mask.data(),
                                  mask.size() * sizeof(int64_t), shape, 2,
                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &pmask));
                std::vector<const char*> in;
                std::vector<const OrtValue*> values;
                for (const std::string& name : m_In)
                {
                    in.push_back(name.c_str());
                    values.push_back(name == "attention_mask" ? pmask : pids);
                }
                std::vector<const char*> out;
                for (const std::string& name : m_Out)
                {
                    out.push_back(name.c_str());
                }
                Check(m_pApi, m_pApi->Run(m_pSession, nullptr, in.data(), values.data(), in.size(),
                                  out.data(), out.size(), outputs.data()));
                _Out.clear();
                for (std::size_t ni = 0; ni < outputs.size(); ++ni)
                {
                    OrtTensorTypeAndShapeInfo* pinfo = nullptr;
                    Check(m_pApi, m_pApi->GetTensorTypeAndShape(outputs[ni], &pinfo));
                    ONNXTensorElementDataType etype = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
                    std::size_t ndims = 0;
                    OrtStatus* pstatus = m_pApi->GetTensorElementType(pinfo, &etype);
                    if (!pstatus)
                    {
                        pstatus = m_pApi->GetDimensionsCount(pinfo, &ndims);
                    }
                    std::vector<int64_t> dims(ndims);
                    if (!pstatus)
                    {
                        pstatus = m_pApi->GetDimensions(pinfo, dims.data(), ndims);
                    }
                    m_pApi->ReleaseTensorTypeAndShapeInfo(pinfo);
                    Check(m_pApi, pstatus);
                    if (etype != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || dims.empty())
                    {
                        throw std::runtime_error("output " + m_Out[ni] + " isn't a float tensor");
                    }
                    const std::size_t nrow = dims.size() == 1
                                                 ? static_cast<std::size_t>(dims[0])
                                                 : static_cast<std::size_t>(dims.back());
                    float* pdata = nullptr;
                    Check(m_pApi, m_pApi->GetTensorMutableData(
                                      outputs[ni], reinterpret_cast<void**>(&pdata)));
                    _Out.emplace_back(m_Out[ni], std::vector<float>(pdata, pdata + nrow));
                }
            }
            catch (...)
            {
                release();
                throw;
            }
            release();
        }
    };

    TextClassifier::TextClassifier(
        std::string _ModelPath, std::string _VocabPath, int _iThreads, CallFn _Call)
        : m_ModelPath(std::move(_ModelPath)), m_VocabPath(std::move(_VocabPath)),
          m_iThreads(_iThreads), m_Call(std::move(_Call)), m_pImpl(std::make_unique<Impl>())
    {
    }

    TextClassifier::~TextClassifier()
    {
        if (m_bPoisoned)
        {
            (void)m_pImpl.release(); // leaked on purpose: releasing could fault again
            return;
        }
        if (!m_pImpl->m_pApi)
        {
            return; // nothing of ONNX Runtime's to release
        }
        Impl& impl = *m_pImpl;
        m_Call("release the turn-taking model", 10s, [&]() { impl.Release(); });
    }

    bool TextClassifier::Load(std::string& _Error)
    {
        std::ifstream in(fs::u8path(m_VocabPath), std::ios::binary);
        if (!in)
        {
            _Error = "missing " + m_VocabPath;
            return false;
        }
        std::ostringstream text;
        text << in.rdbuf();
        if (!m_Tokenizer.Load(text.str(), _Error))
        {
            _Error = m_VocabPath + ": " + _Error;
            return false;
        }
        std::error_code ec;
        if (!fs::is_regular_file(fs::u8path(m_ModelPath), ec))
        {
            _Error = "missing " + m_ModelPath;
            return false;
        }
        Impl& impl = *m_pImpl;
        impl.m_pApi = static_cast<const OrtApi*>(OrtApiTable(ORT_API_VERSION));
        if (!impl.m_pApi)
        {
            _Error = "ONNX Runtime isn't loaded";
            return false;
        }
        std::string error;
        const bool bok = m_Call("load the turn-taking model", 60s,
            [&]()
            {
                try
                {
                    const OrtApi* api = impl.m_pApi;
                    Check(api,
                        api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gitgud-decide", &impl.m_pEnv));
                    Check(api, api->CreateSessionOptions(&impl.m_pOptions));
                    Check(api, api->SetIntraOpNumThreads(impl.m_pOptions, m_iThreads));
                    Check(api, api->SetInterOpNumThreads(impl.m_pOptions, 1));
                    Check(api,
                        api->SetSessionGraphOptimizationLevel(impl.m_pOptions, ORT_ENABLE_ALL));
                    Check(api, api->AddSessionConfigEntry(
                                   impl.m_pOptions, "session.intra_op.allow_spinning", "0"));
                    Check(api, api->CreateCpuMemoryInfo(
                                   OrtArenaAllocator, OrtMemTypeDefault, &impl.m_pCpu));
                    const fs::path path = fs::u8path(m_ModelPath);
                    Check(api, api->CreateSession(
                                   impl.m_pEnv, path.c_str(), impl.m_pOptions, &impl.m_pSession));
                    OrtAllocator* pallocator = nullptr;
                    Check(api, api->GetAllocatorWithDefaultOptions(&pallocator));
                    std::size_t ncount = 0;
                    Check(api, api->SessionGetInputCount(impl.m_pSession, &ncount));
                    for (std::size_t ni = 0; ni < ncount; ++ni)
                    {
                        char* szname = nullptr;
                        Check(api,
                            api->SessionGetInputName(impl.m_pSession, ni, pallocator, &szname));
                        impl.m_In.emplace_back(szname);
                        Check(api, api->AllocatorFree(pallocator, szname));
                    }
                    Check(api, api->SessionGetOutputCount(impl.m_pSession, &ncount));
                    for (std::size_t ni = 0; ni < ncount; ++ni)
                    {
                        char* szname = nullptr;
                        Check(api,
                            api->SessionGetOutputName(impl.m_pSession, ni, pallocator, &szname));
                        impl.m_Out.emplace_back(szname);
                        Check(api, api->AllocatorFree(pallocator, szname));
                    }
                    for (const std::string& name : impl.m_In)
                    {
                        if (name != "input_ids" && name != "attention_mask")
                        {
                            throw std::runtime_error("unexpected input " + name);
                        }
                    }
                    // Once, so the first real call isn't the slow one.
                    Outputs warm;
                    impl.Run({m_Tokenizer.Cls(), m_Tokenizer.Sep(), m_Tokenizer.Sep()}, warm);
                }
                catch (const std::exception& e)
                {
                    error = e.what();
                }
            });
        if (!bok || !error.empty())
        {
            _Error = "the turn-taking model didn't load (" + m_ModelPath + ")" +
                     (error.empty() ? "" : ": " + error);
            return false;
        }
        return true;
    }

    std::vector<int64_t> TextClassifier::Encode(const std::string& _First,
        const std::string& _Second, int _iMaxLength, int _iFirstMax) const
    {
        // Room for both texts beside [CLS] and two [SEP]s; `_First` fits too.
        const long long iall = std::max(0LL, static_cast<long long>(_iMaxLength) - 3);
        std::vector<int64_t> first = m_Tokenizer.Encode(_First);
        long long ifirst = std::min(static_cast<long long>(first.size()), iall);
        if (_iFirstMax >= 0)
        {
            ifirst = std::min(ifirst, static_cast<long long>(_iFirstMax));
        }
        first.resize(static_cast<std::size_t>(ifirst));
        std::vector<int64_t> second = m_Tokenizer.Encode(_Second);
        const long long iroom = iall - ifirst;
        if (static_cast<long long>(second.size()) > iroom)
        {
            second.erase(second.begin(), second.end() - iroom);
        }
        std::vector<int64_t> ids;
        ids.reserve(first.size() + second.size() + 3);
        ids.push_back(m_Tokenizer.Cls());
        ids.insert(ids.end(), first.begin(), first.end());
        ids.push_back(m_Tokenizer.Sep());
        ids.insert(ids.end(), second.begin(), second.end());
        ids.push_back(m_Tokenizer.Sep());
        return ids;
    }

    bool TextClassifier::Classify(const std::vector<int64_t>& _Ids, Outputs& _Out, double* _pMs)
    {
        Impl& impl = *m_pImpl;
        if (!impl.m_pSession)
        {
            return false;
        }
        const auto t0 = std::chrono::steady_clock::now();
        bool bthrew = false;
        const bool bok = m_Call("decide", 5s,
            [&]()
            {
                try
                {
                    impl.Run(_Ids, _Out);
                }
                catch (const std::exception&)
                {
                    bthrew = true;
                }
            });
        if (_pMs)
        {
            *_pMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0)
                        .count();
        }
        return bok && !bthrew;
    }

} // namespace gitgud::speech
