#include "speech/TextToSpeech.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>
#include <sapi.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstring>

namespace gitgud::speech
{

#if defined(_WIN32)

    namespace
    {

        constexpr int kRate = 24000;
        // Speech is passed on in pieces of this many bytes (0.1 s).
        constexpr std::size_t kPiece = kRate / 10 * 2;

        std::wstring Widen(const std::string& _Utf8)
        {
            if (_Utf8.empty())
            {
                return {};
            }
            const int iwide = MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), nullptr, 0);
            std::wstring out(static_cast<std::size_t>(std::max(iwide, 0)), L'\0');
            MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), out.data(), iwide);
            return out;
        }

        std::string Narrow(const wchar_t* _wszText)
        {
            if (!_wszText || !*_wszText)
            {
                return {};
            }
            const int ibytes =
                WideCharToMultiByte(CP_UTF8, 0, _wszText, -1, nullptr, 0, nullptr, nullptr);
            std::string out(static_cast<std::size_t>(std::max(ibytes, 1)), '\0');
            WideCharToMultiByte(CP_UTF8, 0, _wszText, -1, out.data(), ibytes, nullptr, nullptr);
            out.resize(std::strlen(out.c_str()));
            return out;
        }

        template <typename T> struct Com
        {
            T* m_p = nullptr;
            Com() = default;
            Com(const Com&) = delete;
            Com& operator=(const Com&) = delete;

            ~Com()
            {
                if (m_p)
                {
                    m_p->Release();
                }
            }

            T* operator->() const
            {
                return m_p;
            }
        };

        class SapiTextToSpeech : public ITextToSpeech
        {
          public:
            ~SapiTextToSpeech() override
            {
                if (m_bCom)
                {
                    CoUninitialize();
                }
            }

            bool Init(std::string& _Error)
            {
                const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
                m_bCom = SUCCEEDED(hr);
                if (FAILED(hr) && hr != RPC_E_CHANGED_MODE)
                {
                    _Error = "COM didn't start";
                    return false;
                }
                Com<ISpVoice> voice;
                if (FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice,
                        reinterpret_cast<void**>(&voice.m_p))))
                {
                    _Error = "Windows speech isn't installed";
                    return false;
                }
                return true;
            }

            std::string Provider() const override
            {
                return "windows";
            }

            int SampleRate() const override
            {
                return kRate;
            }

            std::vector<VoiceInfo> Voices() override
            {
                std::vector<VoiceInfo> out;
                Com<ISpObjectTokenCategory> category;
                if (FAILED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_ALL,
                        IID_ISpObjectTokenCategory, reinterpret_cast<void**>(&category.m_p))) ||
                    FAILED(category->SetId(SPCAT_VOICES, FALSE)))
                {
                    return out;
                }
                Com<IEnumSpObjectTokens> tokens;
                if (FAILED(category->EnumTokens(nullptr, nullptr, &tokens.m_p)))
                {
                    return out;
                }
                for (;;)
                {
                    Com<ISpObjectToken> token;
                    if (tokens->Next(1, &token.m_p, nullptr) != S_OK)
                    {
                        break;
                    }
                    VoiceInfo info;
                    wchar_t* wszvalue = nullptr;
                    if (SUCCEEDED(token->GetId(&wszvalue)))
                    {
                        info.m_Id = Narrow(wszvalue);
                        CoTaskMemFree(wszvalue);
                    }
                    wszvalue = nullptr;
                    if (SUCCEEDED(token->GetStringValue(nullptr, &wszvalue)))
                    {
                        info.m_Name = Narrow(wszvalue);
                        CoTaskMemFree(wszvalue);
                    }
                    Com<ISpDataKey> attributes;
                    if (SUCCEEDED(token->OpenKey(L"Attributes", &attributes.m_p)))
                    {
                        wszvalue = nullptr;
                        if (SUCCEEDED(attributes->GetStringValue(L"Language", &wszvalue)))
                        {
                            info.m_Language = Narrow(wszvalue);
                            CoTaskMemFree(wszvalue);
                        }
                    }
                    if (!info.m_Id.empty())
                    {
                        out.push_back(std::move(info));
                    }
                }
                return out;
            }

            bool Synthesize(const std::string& _Text, const std::string& _Voice, double _fSpeed,
                const OnPcm& _OnPcm, std::string& _Error) override
            {
                Com<ISpVoice> voice;
                if (FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice,
                        reinterpret_cast<void**>(&voice.m_p))))
                {
                    _Error = "Windows speech didn't start";
                    return false;
                }
                if (!_Voice.empty())
                {
                    Com<ISpObjectToken> token;
                    if (FAILED(CoCreateInstance(CLSID_SpObjectToken, nullptr, CLSCTX_ALL,
                            IID_ISpObjectToken, reinterpret_cast<void**>(&token.m_p))) ||
                        FAILED(token->SetId(nullptr, Widen(_Voice).c_str(), FALSE)) ||
                        FAILED(voice->SetVoice(token.m_p)))
                    {
                        _Error = "no such voice: " + _Voice;
                        return false;
                    }
                }
                // Speed 3 is SAPI's rate 10, a third is -10.
                const double fspeed = std::isfinite(_fSpeed) && _fSpeed > 0 ? _fSpeed : 1.0;
                const long lrate = static_cast<long>(std::lround(
                    std::min(10.0, std::max(-10.0, 10.0 * std::log(fspeed) / std::log(3.0)))));
                voice->SetRate(lrate);

                Com<IStream> memory;
                if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &memory.m_p)))
                {
                    _Error = "out of memory";
                    return false;
                }
                Com<ISpStream> stream;
                if (FAILED(CoCreateInstance(CLSID_SpStream, nullptr, CLSCTX_ALL, IID_ISpStream,
                        reinterpret_cast<void**>(&stream.m_p))))
                {
                    _Error = "Windows speech didn't start";
                    return false;
                }
                WAVEFORMATEX format = {};
                format.wFormatTag = WAVE_FORMAT_PCM;
                format.nChannels = 1;
                format.nSamplesPerSec = kRate;
                format.wBitsPerSample = 16;
                format.nBlockAlign = 2;
                format.nAvgBytesPerSec = kRate * 2;
                if (FAILED(stream->SetBaseStream(memory.m_p, SPDFID_WaveFormatEx, &format)) ||
                    FAILED(voice->SetOutput(stream.m_p, TRUE)))
                {
                    _Error = "Windows speech can't make 24 kHz audio";
                    return false;
                }
                const std::wstring text = Widen(_Text);
                if (FAILED(voice->Speak(text.c_str(),
                        SPF_DEFAULT | SPF_IS_NOT_XML | SPF_PURGEBEFORESPEAK, nullptr)))
                {
                    _Error = "Windows speech couldn't say it";
                    return false;
                }
                voice->SetOutput(nullptr, FALSE);

                STATSTG stat = {};
                if (FAILED(memory->Stat(&stat, STATFLAG_NONAME)))
                {
                    _Error = "the speech was lost";
                    return false;
                }
                LARGE_INTEGER start = {};
                memory->Seek(start, STREAM_SEEK_SET, nullptr);
                std::string pcm(static_cast<std::size_t>(stat.cbSize.QuadPart), '\0');
                ULONG ulread = 0;
                if (!pcm.empty() &&
                    FAILED(memory->Read(pcm.data(), static_cast<ULONG>(pcm.size()), &ulread)))
                {
                    _Error = "the speech was lost";
                    return false;
                }
                pcm.resize(ulread & ~1u);
                for (std::size_t nat = 0; nat < pcm.size(); nat += kPiece)
                {
                    if (!_OnPcm(pcm.substr(nat, kPiece)))
                    {
                        break;
                    }
                }
                return true;
            }

          private:
            bool m_bCom = false;
        };

    } // namespace

    std::unique_ptr<ITextToSpeech> MakeSystemTextToSpeech(std::string& _Error)
    {
        auto pspeech = std::make_unique<SapiTextToSpeech>();
        if (!pspeech->Init(_Error))
        {
            return nullptr;
        }
        return pspeech;
    }

#else

    std::unique_ptr<ITextToSpeech> MakeSystemTextToSpeech(std::string& _Error)
    {
        _Error = "spoken replies aren't built for this platform yet";
        return nullptr;
    }

#endif

} // namespace gitgud::speech
