#include "speech/TurboOnnx.h"

#include "speech/SherpaApi.h"

#include "onnxruntime_c_api.h"

#include <chrono>
#include <cstring>
#include <filesystem>
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

        ONNXTensorElementDataType OrtType(Tensor::Type _eType)
        {
            switch (_eType)
            {
            case Tensor::Type::Half:
                return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16;
            case Tensor::Type::Int64:
                return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
            default:
                return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
            }
        }

        bool TensorType(ONNXTensorElementDataType _eType, Tensor::Type& _Out)
        {
            switch (_eType)
            {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
                _Out = Tensor::Type::Float;
                return true;
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16:
                _Out = Tensor::Type::Half;
                return true;
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
                _Out = Tensor::Type::Int64;
                return true;
            default:
                return false;
            }
        }

        // Values released when they go out of scope.
        struct Values
        {
            const OrtApi* m_pApi;
            std::vector<OrtValue*> m_List;

            explicit Values(const OrtApi* _pApi, std::size_t _nCount = 0)
                : m_pApi(_pApi), m_List(_nCount, nullptr)
            {
            }

            ~Values()
            {
                for (OrtValue* p : m_List)
                {
                    if (p)
                    {
                        m_pApi->ReleaseValue(p);
                    }
                }
            }

            Values(const Values&) = delete;
            Values& operator=(const Values&) = delete;
        };

    } // namespace

    struct TurboOnnx::Impl
    {
        struct Net
        {
            OrtSession* m_pSession = nullptr;
            std::vector<std::string> m_In;
            std::vector<std::string> m_Out;
            std::vector<ONNXTensorElementDataType> m_InTypes;
            std::vector<std::vector<int64_t>> m_InShapes;

            int In(const std::string& _Name) const
            {
                for (std::size_t ni = 0; ni < m_In.size(); ++ni)
                {
                    if (m_In[ni] == _Name)
                    {
                        return static_cast<int>(ni);
                    }
                }
                return -1;
            }
        };

        const OrtApi* m_pApi = nullptr;
        OrtEnv* m_pEnv = nullptr;
        OrtSessionOptions* m_pOptions = nullptr;
        // The embedding always runs on the processor: ONNX Runtime 1.28's
        // CUDA provider fails on its quantized gather, and a table lookup
        // gains nothing from the GPU.
        OrtSessionOptions* m_pCpuOptions = nullptr;
        OrtMemoryInfo* m_pCpu = nullptr;
        OrtAllocator* m_pAllocator = nullptr;
        Net m_Embed;
        Net m_Lm;
        Net m_Decoder;

        // The language model's key/value cache: for each of its past inputs,
        // the output that feeds it next step.
        std::vector<int> m_PastInputs;
        std::vector<int> m_PastOutputs;
        std::vector<OrtValue*> m_Past;
        int64_t m_iPastLength = 0;
        int64_t m_iHeads = 16;
        int64_t m_iHeadDim = 64;

        void ReleasePast()
        {
            for (OrtValue*& p : m_Past)
            {
                if (p)
                {
                    m_pApi->ReleaseValue(p);
                    p = nullptr;
                }
            }
            m_iPastLength = 0;
        }

        Net Open(const fs::path& _Path, bool _bCpu = false)
        {
            Net net;
            Check(m_pApi, m_pApi->CreateSession(m_pEnv, _Path.c_str(),
                              _bCpu ? m_pCpuOptions : m_pOptions, &net.m_pSession));
            std::size_t ncount = 0;
            Check(m_pApi, m_pApi->SessionGetInputCount(net.m_pSession, &ncount));
            for (std::size_t ni = 0; ni < ncount; ++ni)
            {
                char* szname = nullptr;
                Check(
                    m_pApi, m_pApi->SessionGetInputName(net.m_pSession, ni, m_pAllocator, &szname));
                net.m_In.emplace_back(szname);
                Check(m_pApi, m_pApi->AllocatorFree(m_pAllocator, szname));
                OrtTypeInfo* ptype = nullptr;
                Check(m_pApi, m_pApi->SessionGetInputTypeInfo(net.m_pSession, ni, &ptype));
                const OrtTensorTypeAndShapeInfo* pinfo = nullptr;
                ONNXTensorElementDataType etype = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
                std::vector<int64_t> shape;
                OrtStatus* pstatus = m_pApi->CastTypeInfoToTensorInfo(ptype, &pinfo);
                if (!pstatus && pinfo)
                {
                    pstatus = m_pApi->GetTensorElementType(pinfo, &etype);
                    std::size_t ndims = 0;
                    if (!pstatus)
                    {
                        pstatus = m_pApi->GetDimensionsCount(pinfo, &ndims);
                    }
                    if (!pstatus)
                    {
                        shape.resize(ndims);
                        pstatus = m_pApi->GetDimensions(pinfo, shape.data(), ndims);
                    }
                }
                m_pApi->ReleaseTypeInfo(ptype);
                Check(m_pApi, pstatus);
                net.m_InTypes.push_back(etype);
                net.m_InShapes.push_back(shape);
            }
            Check(m_pApi, m_pApi->SessionGetOutputCount(net.m_pSession, &ncount));
            for (std::size_t ni = 0; ni < ncount; ++ni)
            {
                char* szname = nullptr;
                Check(m_pApi,
                    m_pApi->SessionGetOutputName(net.m_pSession, ni, m_pAllocator, &szname));
                net.m_Out.emplace_back(szname);
                Check(m_pApi, m_pApi->AllocatorFree(m_pAllocator, szname));
            }
            return net;
        }

        void Close(Net& _Net)
        {
            if (_Net.m_pSession)
            {
                m_pApi->ReleaseSession(_Net.m_pSession);
                _Net.m_pSession = nullptr;
            }
        }

        // A value over `_Tensor`'s data (which must outlive it).
        OrtValue* View(const Tensor& _Tensor)
        {
            OrtValue* pvalue = nullptr;
            Check(m_pApi, m_pApi->CreateTensorWithDataAsOrtValue(m_pCpu,
                              const_cast<uint8_t*>(_Tensor.m_Data.data()), _Tensor.m_Data.size(),
                              _Tensor.m_Shape.data(), _Tensor.m_Shape.size(),
                              OrtType(_Tensor.m_eType), &pvalue));
            return pvalue;
        }

        Tensor Read(const OrtValue* _pValue)
        {
            OrtTensorTypeAndShapeInfo* pinfo = nullptr;
            Check(m_pApi, m_pApi->GetTensorTypeAndShape(_pValue, &pinfo));
            ONNXTensorElementDataType etype = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
            std::size_t ndims = 0;
            OrtStatus* pstatus = m_pApi->GetTensorElementType(pinfo, &etype);
            if (!pstatus)
            {
                pstatus = m_pApi->GetDimensionsCount(pinfo, &ndims);
            }
            Tensor out;
            out.m_Shape.resize(ndims);
            if (!pstatus)
            {
                pstatus = m_pApi->GetDimensions(pinfo, out.m_Shape.data(), ndims);
            }
            m_pApi->ReleaseTensorTypeAndShapeInfo(pinfo);
            Check(m_pApi, pstatus);
            if (!TensorType(etype, out.m_eType))
            {
                throw std::runtime_error("an output of an unexpected type");
            }
            void* pdata = nullptr;
            Check(m_pApi, m_pApi->GetTensorMutableData(const_cast<OrtValue*>(_pValue), &pdata));
            const std::size_t nbytes = out.Count() * out.ElementSize();
            out.m_Data.resize(nbytes);
            if (nbytes)
            {
                std::memcpy(out.m_Data.data(), pdata, nbytes);
            }
            return out;
        }

        // Run `_Net` with inputs in its own order; every output, in order.
        void Run(Net& _Net, const std::vector<const OrtValue*>& _Inputs, Values& _Outputs)
        {
            std::vector<const char*> in;
            for (const std::string& name : _Net.m_In)
            {
                in.push_back(name.c_str());
            }
            std::vector<const char*> out;
            for (const std::string& name : _Net.m_Out)
            {
                out.push_back(name.c_str());
            }
            _Outputs.m_List.assign(out.size(), nullptr);
            Check(m_pApi, m_pApi->Run(_Net.m_pSession, nullptr, in.data(), _Inputs.data(),
                              in.size(), out.data(), out.size(), _Outputs.m_List.data()));
        }
    };

    TurboOnnx::TurboOnnx(TurboFiles _Files, CallFn _Call)
        : m_Files(std::move(_Files)), m_Call(std::move(_Call)), m_pImpl(std::make_unique<Impl>())
    {
    }

    TurboOnnx::~TurboOnnx()
    {
        if (m_bPoisoned || !m_pImpl->m_pApi)
        {
            (void)m_pImpl.release(); // leaked on purpose: releasing could fault again
            return;
        }
        Impl& impl = *m_pImpl;
        m_Call("release the speech models", 30s,
            [&]()
            {
                impl.ReleasePast();
                impl.Close(impl.m_Embed);
                impl.Close(impl.m_Lm);
                impl.Close(impl.m_Decoder);
                if (impl.m_pCpu)
                {
                    impl.m_pApi->ReleaseMemoryInfo(impl.m_pCpu);
                }
                if (impl.m_pOptions)
                {
                    impl.m_pApi->ReleaseSessionOptions(impl.m_pOptions);
                }
                if (impl.m_pCpuOptions)
                {
                    impl.m_pApi->ReleaseSessionOptions(impl.m_pCpuOptions);
                }
                if (impl.m_pEnv)
                {
                    impl.m_pApi->ReleaseEnv(impl.m_pEnv);
                }
            });
    }

    bool TurboOnnx::Load(std::string& _Error)
    {
        Impl& impl = *m_pImpl;
        impl.m_pApi = static_cast<const OrtApi*>(OrtApiTable(ORT_API_VERSION));
        if (!impl.m_pApi)
        {
            _Error = "ONNX Runtime isn't loaded";
            return false;
        }
        const fs::path dir = fs::u8path(m_Files.m_Dir);
        for (const std::string* pname : {&m_Files.m_Embed, &m_Files.m_Lm, &m_Files.m_Decoder})
        {
            std::error_code ec;
            if (pname->empty() || !fs::is_regular_file(dir / fs::u8path(*pname), ec))
            {
                _Error = "missing " + (dir / fs::u8path(*pname)).u8string();
                return false;
            }
        }
        std::string error;
        const bool bok = m_Call("load the speech models", 300s,
            [&]()
            {
                const OrtApi* api = impl.m_pApi;
                Check(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gitgud-speak", &impl.m_pEnv));
                Check(api, api->CreateSessionOptions(&impl.m_pCpuOptions));
                Check(api, api->SetIntraOpNumThreads(impl.m_pCpuOptions, 1));
                Check(api, api->SetInterOpNumThreads(impl.m_pCpuOptions, 1));
                Check(
                    api, api->SetSessionGraphOptimizationLevel(impl.m_pCpuOptions, ORT_ENABLE_ALL));
                Check(api, api->CreateSessionOptions(&impl.m_pOptions));
                Check(api, api->SetIntraOpNumThreads(impl.m_pOptions, m_Files.m_iThreads));
                Check(api, api->SetInterOpNumThreads(impl.m_pOptions, 1));
                Check(api, api->SetSessionGraphOptimizationLevel(impl.m_pOptions, ORT_ENABLE_ALL));
                Check(api, api->AddSessionConfigEntry(
                               impl.m_pOptions, "session.intra_op.allow_spinning", "0"));
                if (m_Files.m_bCuda)
                {
                    // The provider the engine registered from the GPU pack
                    // (SherpaApi.h: EnableCuda), in the environment it lives in.
                    const auto* pdevice = static_cast<const OrtEpDevice*>(CudaEpDevice());
                    auto* penv = static_cast<OrtEnv*>(CudaEnv());
                    if (!pdevice || !penv)
                    {
                        throw std::runtime_error("the GPU isn't started");
                    }
                    const char* keys[] = {"device_id", "cudnn_conv_algo_search"};
                    const char* values[] = {"0", "DEFAULT"};
                    Check(api, api->SessionOptionsAppendExecutionProvider_V2(
                                   impl.m_pOptions, penv, &pdevice, 1, keys, values, 2));
                }
                Check(api,
                    api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &impl.m_pCpu));
                Check(api, api->GetAllocatorWithDefaultOptions(&impl.m_pAllocator));
                impl.m_Embed = impl.Open(dir / fs::u8path(m_Files.m_Embed), true);
                impl.m_Lm = impl.Open(dir / fs::u8path(m_Files.m_Lm));
                impl.m_Decoder = impl.Open(dir / fs::u8path(m_Files.m_Decoder));

                // The cache: past_key_values.N.key -> present.N.key.
                for (std::size_t ni = 0; ni < impl.m_Lm.m_In.size(); ++ni)
                {
                    const std::string& name = impl.m_Lm.m_In[ni];
                    if (name.rfind("past_key_values", 0) != 0)
                    {
                        continue;
                    }
                    const std::string present =
                        "present" + name.substr(std::strlen("past_key_values"));
                    int iout = -1;
                    for (std::size_t no = 0; no < impl.m_Lm.m_Out.size(); ++no)
                    {
                        if (impl.m_Lm.m_Out[no] == present)
                        {
                            iout = static_cast<int>(no);
                        }
                    }
                    if (iout < 0)
                    {
                        throw std::runtime_error("the language model has no " + present);
                    }
                    impl.m_PastInputs.push_back(static_cast<int>(ni));
                    impl.m_PastOutputs.push_back(iout);
                    const std::vector<int64_t>& shape = impl.m_Lm.m_InShapes[ni];
                    if (shape.size() == 4 && shape[1] > 0 && shape[3] > 0)
                    {
                        impl.m_iHeads = shape[1];
                        impl.m_iHeadDim = shape[3];
                    }
                }
                impl.m_Past.assign(impl.m_PastInputs.size(), nullptr);
                for (const char* szname : {"inputs_embeds", "attention_mask", "position_ids"})
                {
                    if (impl.m_Lm.In(szname) < 0)
                    {
                        throw std::runtime_error(
                            std::string("the language model has no ") + szname);
                    }
                }
                if (impl.m_Embed.In("input_ids") < 0 || impl.m_Decoder.In("speech_tokens") < 0)
                {
                    throw std::runtime_error("these aren't Chatterbox Turbo's graphs");
                }
            });
        if (!bok)
        {
            _Error = "the speech models didn't load";
            return false;
        }
        return true;
    }

    bool TurboOnnx::Encode(const std::vector<float>& _Audio, std::vector<Tensor>& _Out)
    {
        Impl& impl = *m_pImpl;
        const fs::path path = fs::u8path(m_Files.m_Dir) / fs::u8path(m_Files.m_Encoder);
        std::error_code ec;
        if (m_Files.m_Encoder.empty() || !fs::is_regular_file(path, ec) || !impl.m_pEnv)
        {
            return false;
        }
        _Out.clear();
        // Generous limits throughout: on the processor, or on a GPU in a
        // low-power state (the computer busy with a game), every call can be
        // several times slower than usual.
        const auto limit = std::chrono::milliseconds(300000);
        return m_Call("make a voice", limit,
            [&]()
            {
                Impl::Net encoder = impl.Open(path);
                struct CloseLater
                {
                    Impl& m_Impl;
                    Impl::Net& m_Net;
                    ~CloseLater()
                    {
                        m_Impl.Close(m_Net);
                    }
                } closeLater{impl, encoder};
                if (encoder.m_In.size() != 1 || encoder.m_Out.size() != 4)
                {
                    throw std::runtime_error("not Chatterbox Turbo's speech encoder");
                }
                Tensor audio = Tensor::FromFloats(_Audio, {1, static_cast<int64_t>(_Audio.size())});
                Tensor::Type etype = Tensor::Type::Float;
                TensorType(encoder.m_InTypes[0], etype);
                audio = audio.As(etype);
                Values in(impl.m_pApi, 1);
                in.m_List[0] = impl.View(audio);
                Values out(impl.m_pApi);
                impl.Run(encoder, {in.m_List[0]}, out);
                for (OrtValue* pvalue : out.m_List)
                {
                    _Out.push_back(impl.Read(pvalue));
                }
            });
    }

    bool TurboOnnx::Embed(const std::vector<int64_t>& _Ids, Tensor& _Out)
    {
        Impl& impl = *m_pImpl;
        if (!impl.m_Embed.m_pSession || _Ids.empty())
        {
            return false;
        }
        return m_Call("embed text", 30s,
            [&]()
            {
                const Tensor ids = Tensor::FromInts(_Ids, {1, static_cast<int64_t>(_Ids.size())});
                Values in(impl.m_pApi, 1);
                in.m_List[0] = impl.View(ids);
                Values out(impl.m_pApi);
                impl.Run(impl.m_Embed, {in.m_List[0]}, out);
                _Out = impl.Read(out.m_List[0]);
            });
    }

    void TurboOnnx::Reset()
    {
        Impl& impl = *m_pImpl;
        if (impl.m_pApi && !m_bPoisoned)
        {
            m_Call("start a sentence", 5s, [&]() { impl.ReleasePast(); });
        }
    }

    bool TurboOnnx::Step(const Tensor& _Embeds, int64_t _iPosition, std::vector<float>& _Logits)
    {
        Impl& impl = *m_pImpl;
        if (!impl.m_Lm.m_pSession || _Embeds.m_Shape.size() != 3)
        {
            return false;
        }
        return m_Call("generate speech", 60s,
            [&]()
            {
                Impl::Net& lm = impl.m_Lm;
                const int64_t n = _Embeds.m_Shape[1];
                Tensor::Type eembeds = Tensor::Type::Float;
                TensorType(lm.m_InTypes[static_cast<std::size_t>(lm.In("inputs_embeds"))], eembeds);
                const Tensor embeds = _Embeds.As(eembeds);
                const Tensor mask = Tensor::FromInts(
                    std::vector<int64_t>(static_cast<std::size_t>(impl.m_iPastLength + n), 1),
                    {1, impl.m_iPastLength + n});
                std::vector<int64_t> positions(static_cast<std::size_t>(n));
                for (int64_t ni = 0; ni < n; ++ni)
                {
                    positions[static_cast<std::size_t>(ni)] = _iPosition + ni;
                }
                const Tensor position = Tensor::FromInts(positions, {1, n});

                Values views(impl.m_pApi);
                Values empties(impl.m_pApi);
                std::vector<const OrtValue*> inputs(lm.m_In.size(), nullptr);
                auto view = [&](const Tensor& _Tensor)
                {
                    views.m_List.push_back(impl.View(_Tensor));
                    return views.m_List.back();
                };
                inputs[static_cast<std::size_t>(lm.In("inputs_embeds"))] = view(embeds);
                inputs[static_cast<std::size_t>(lm.In("attention_mask"))] = view(mask);
                inputs[static_cast<std::size_t>(lm.In("position_ids"))] = view(position);
                for (std::size_t nk = 0; nk < impl.m_PastInputs.size(); ++nk)
                {
                    const int iin = impl.m_PastInputs[nk];
                    if (impl.m_Past[nk])
                    {
                        inputs[static_cast<std::size_t>(iin)] = impl.m_Past[nk];
                        continue;
                    }
                    const int64_t shape[] = {1, impl.m_iHeads, 0, impl.m_iHeadDim};
                    OrtValue* pempty = nullptr;
                    Check(
                        impl.m_pApi, impl.m_pApi->CreateTensorAsOrtValue(impl.m_pAllocator, shape,
                                         4, lm.m_InTypes[static_cast<std::size_t>(iin)], &pempty));
                    empties.m_List.push_back(pempty);
                    inputs[static_cast<std::size_t>(iin)] = pempty;
                }
                for (std::size_t ni = 0; ni < inputs.size(); ++ni)
                {
                    if (!inputs[ni])
                    {
                        throw std::runtime_error("the language model wants " + lm.m_In[ni]);
                    }
                }
                Values out(impl.m_pApi);
                impl.Run(lm, inputs, out);

                // The last position's logits.
                int ilogits = -1;
                for (std::size_t no = 0; no < lm.m_Out.size(); ++no)
                {
                    if (lm.m_Out[no] == "logits")
                    {
                        ilogits = static_cast<int>(no);
                    }
                }
                if (ilogits < 0)
                {
                    throw std::runtime_error("the language model has no logits");
                }
                const Tensor logits = impl.Read(out.m_List[static_cast<std::size_t>(ilogits)]);
                const std::vector<float> all = logits.Floats();
                const std::size_t nvocab =
                    logits.m_Shape.empty() ? 0 : static_cast<std::size_t>(logits.m_Shape.back());
                if (nvocab == 0 || all.size() < nvocab)
                {
                    throw std::runtime_error("empty logits");
                }
                _Logits.assign(all.end() - static_cast<std::ptrdiff_t>(nvocab), all.end());

                // The new cache replaces the old one (taken out of `out`).
                std::vector<OrtValue*> next(impl.m_PastInputs.size(), nullptr);
                for (std::size_t nk = 0; nk < impl.m_PastOutputs.size(); ++nk)
                {
                    OrtValue*& pslot = out.m_List[static_cast<std::size_t>(impl.m_PastOutputs[nk])];
                    next[nk] = pslot;
                    pslot = nullptr;
                }
                const int64_t ilength = impl.m_iPastLength + n;
                impl.ReleasePast(); // (also zeroes the length)
                impl.m_Past = std::move(next);
                impl.m_iPastLength = ilength;
            });
    }

    bool TurboOnnx::Decode(const std::vector<int64_t>& _SpeechTokens,
        const Tensor& _SpeakerEmbeddings, const Tensor& _SpeakerFeatures,
        std::vector<float>& _Audio)
    {
        Impl& impl = *m_pImpl;
        if (!impl.m_Decoder.m_pSession || _SpeechTokens.empty())
        {
            return false;
        }
        const auto limit = std::chrono::milliseconds(
            std::max<long long>(120000, static_cast<long long>(_SpeechTokens.size()) * 500));
        return m_Call("decode speech", limit,
            [&]()
            {
                Impl::Net& decoder = impl.m_Decoder;
                const Tensor tokens = Tensor::FromInts(
                    _SpeechTokens, {1, static_cast<int64_t>(_SpeechTokens.size())});
                Tensor::Type eemb = Tensor::Type::Float;
                Tensor::Type efeat = Tensor::Type::Float;
                const int iemb = decoder.In("speaker_embeddings");
                const int ifeat = decoder.In("speaker_features");
                if (iemb < 0 || ifeat < 0)
                {
                    throw std::runtime_error("not Chatterbox Turbo's decoder");
                }
                TensorType(decoder.m_InTypes[static_cast<std::size_t>(iemb)], eemb);
                TensorType(decoder.m_InTypes[static_cast<std::size_t>(ifeat)], efeat);
                const Tensor emb = _SpeakerEmbeddings.As(eemb);
                const Tensor feat = _SpeakerFeatures.As(efeat);
                Values views(impl.m_pApi, 3);
                std::vector<const OrtValue*> inputs(decoder.m_In.size(), nullptr);
                views.m_List[0] = impl.View(tokens);
                views.m_List[1] = impl.View(emb);
                views.m_List[2] = impl.View(feat);
                inputs[static_cast<std::size_t>(decoder.In("speech_tokens"))] = views.m_List[0];
                inputs[static_cast<std::size_t>(iemb)] = views.m_List[1];
                inputs[static_cast<std::size_t>(ifeat)] = views.m_List[2];
                for (const OrtValue* p : inputs)
                {
                    if (!p)
                    {
                        throw std::runtime_error("the decoder wants more inputs");
                    }
                }
                Values out(impl.m_pApi);
                impl.Run(decoder, inputs, out);
                _Audio = impl.Read(out.m_List[0]).Floats();
            });
    }

} // namespace gitgud::speech
