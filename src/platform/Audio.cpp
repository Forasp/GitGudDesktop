#include "platform/Audio.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <avrt.h>
#include <dmo.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <propsys.h>
#include <uuids.h>
#include <wmcodecdsp.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <thread>
#include <tuple>
#include <vector>

namespace gitgud::platform
{

    namespace
    {

        // The devices SetAudioDevices picked ("" for the default).
        std::mutex g_DeviceMutex;
        std::string g_CaptureId;
        std::string g_RenderId;
        EchoOptions g_Echo; // guarded by g_DeviceMutex

    } // namespace

    void SetEchoOptions(const EchoOptions& _Options)
    {
        std::lock_guard<std::mutex> lock(g_DeviceMutex);
        g_Echo = _Options;
    }

    EchoOptions CurrentEchoOptions()
    {
        std::lock_guard<std::mutex> lock(g_DeviceMutex);
        return g_Echo;
    }

    void SetAudioDevices(const std::string& _CaptureId, const std::string& _RenderId)
    {
        std::lock_guard<std::mutex> lock(g_DeviceMutex);
        g_CaptureId = _CaptureId;
        g_RenderId = _RenderId;
    }

    void ChosenAudioDevices(std::string& _CaptureId, std::string& _RenderId)
    {
        std::lock_guard<std::mutex> lock(g_DeviceMutex);
        _CaptureId = g_CaptureId;
        _RenderId = g_RenderId;
    }

    std::string PickAudioEndpoint(const std::string& _Chosen, const std::string& _Default,
        const std::vector<std::string>& _Active)
    {
        const auto active = [&](const std::string& _Id)
        {
            return !_Id.empty() && std::find(_Active.begin(), _Active.end(), _Id) != _Active.end();
        };
        if (active(_Chosen))
        {
            return _Chosen;
        }
        return active(_Default) ? _Default : std::string();
    }

    bool EchoDeviceIndexes(const std::string& _CaptureId, const std::vector<std::string>& _Captures,
        const std::string& _RenderId, const std::vector<std::string>& _Renders, int32_t& _iPacked)
    {
        // An index that doesn't fit 15 bits would read as -1 ("the default").
        const auto place = [](const std::string& _Id, const std::vector<std::string>& _List)
        {
            const auto it = std::find(_List.begin(), _List.end(), _Id);
            const std::ptrdiff_t iindex = it - _List.begin();
            return _Id.empty() || it == _List.end() || iindex >= 0x7FFF ? -1L
                                                                        : static_cast<long>(iindex);
        };
        const long imic = place(_CaptureId, _Captures);
        const long ispeaker = place(_RenderId, _Renders);
        if (imic < 0 || ispeaker < 0)
        {
            return false;
        }
        _iPacked = static_cast<int32_t>(
            (static_cast<uint32_t>(ispeaker) << 16) | (static_cast<uint32_t>(imic) & 0xFFFFu));
        return true;
    }

    namespace
    {

        // Captures tried in order: the first that starts runs, and one that
        // stops giving samples for `m_Stall` is swapped for the next (the
        // echo canceller can start and then give nothing, and would
        // otherwise leave the mic on and silent). The last runs unwatched.
        class FallbackCapture final : public IAudioCapture
        {
          public:
            FallbackCapture(
                std::vector<std::unique_ptr<IAudioCapture>> _Stages, std::chrono::milliseconds _Stall)
                : m_Stages(std::move(_Stages)), m_Stall(_Stall)
            {
            }

            ~FallbackCapture() override
            {
                Stop();
            }

            bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) override
            {
                Stop();
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_OnSamples = std::move(_OnSamples);
                m_iRate = _iSampleRate;
                m_Why.clear();
                m_Earlier.clear();
                if (!StartFrom(0, _Error))
                {
                    if (!m_Why.empty())
                    {
                        _Error += " (echo cancellation: " + m_Why + ")";
                    }
                    return false;
                }
                if (!OnLast())
                {
                    m_bWatch = true;
                    m_Watchdog = std::thread([this]() { Watch(); });
                }
                return true;
            }

            void Stop() override
            {
                {
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_bWatch = false;
                }
                m_Wake.notify_all();
                if (m_Watchdog.joinable())
                {
                    m_Watchdog.join();
                }
                std::lock_guard<std::mutex> lock(m_Mutex);
                if (m_iActive >= 0)
                {
                    m_Stages[static_cast<std::size_t>(m_iActive)]->Stop();
                    m_iActive = -1;
                }
            }

            std::string Description() const override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                if (m_iActive < 0)
                {
                    return "Microphone (off)";
                }
                if (OnLast() && !m_Why.empty())
                {
                    // Says why, so Settings can show that echo isn't cancelled.
                    return "Microphone (no echo cancellation: " + m_Why + ")";
                }
                return m_Stages[static_cast<std::size_t>(m_iActive)]->Description();
            }

            std::string Route() const override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                std::string route =
                    m_iActive >= 0 ? m_Stages[static_cast<std::size_t>(m_iActive)]->Route() : "";
                if (!m_Earlier.empty())
                {
                    route += (route.empty() ? "" : "; ") + std::string("tried before: ") + m_Earlier;
                }
                return route;
            }

          private:
            // m_Mutex held.
            bool OnLast() const
            {
                return m_iActive >= 0 && static_cast<std::size_t>(m_iActive) + 1 >= m_Stages.size();
            }

            // Start the first stage from `_iFirst` on that starts (m_Mutex
            // held). `_Error` gets the last one's error if none does.
            bool StartFrom(int _iFirst, std::string& _Error)
            {
                for (std::size_t i = static_cast<std::size_t>(_iFirst); i < m_Stages.size(); ++i)
                {
                    m_nStageSamples = 0;
                    std::string error;
                    if (m_Stages[i]->Start(
                            m_iRate,
                            [this](const int16_t* _pSamples, std::size_t _nCount)
                            {
                                m_nStageSamples += _nCount;
                                m_OnSamples(_pSamples, _nCount);
                            },
                            error))
                    {
                        m_iActive = static_cast<int>(i);
                        return true;
                    }
                    Note(i, error.empty() ? std::string("it didn't start") : error);
                    _Error = error;
                }
                m_iActive = -1;
                return false;
            }

            // Stage `_iStage` failed for `_Why` (m_Mutex held): kept for
            // Route, and for Description while a later stage runs.
            void Note(std::size_t _iStage, const std::string& _Why)
            {
                if (_iStage + 1 < m_Stages.size())
                {
                    m_Why = _Why;
                }
                const std::string route = m_Stages[_iStage]->Route();
                const std::string label =
                    route.empty() ? m_Stages[_iStage]->Description() : "(" + route + ")";
                m_Earlier += (m_Earlier.empty() ? "" : "; ") + label + ": " + _Why;
            }

            void Watch()
            {
                std::size_t nseen = 0;
                auto last = std::chrono::steady_clock::now();
                std::unique_lock<std::mutex> lock(m_Mutex);
                while (m_bWatch)
                {
                    m_Wake.wait_for(lock, std::chrono::milliseconds(50));
                    if (!m_bWatch || m_iActive < 0)
                    {
                        return;
                    }
                    const std::size_t ncount = m_nStageSamples;
                    const auto now = std::chrono::steady_clock::now();
                    if (ncount != nseen)
                    {
                        nseen = ncount;
                        last = now;
                        continue;
                    }
                    if (now - last < m_Stall)
                    {
                        continue;
                    }
                    // Stalled: the next stage. Each capture runs on its own
                    // thread, so stopping it from here is safe.
                    const auto istage = static_cast<std::size_t>(m_iActive);
                    m_Stages[istage]->Stop();
                    const std::string error = m_Stages[istage]->LastError();
                    Note(istage, !error.empty() ? error
                                 : nseen == 0   ? std::string("it gave no audio")
                                                : std::string("it stopped giving audio"));
                    std::string startError;
                    if (!StartFrom(static_cast<int>(istage) + 1, startError))
                    {
                        m_Why += "; " + startError;
                        return;
                    }
                    if (OnLast())
                    {
                        return;
                    }
                    nseen = 0;
                    last = std::chrono::steady_clock::now();
                }
            }

            std::vector<std::unique_ptr<IAudioCapture>> m_Stages;
            std::chrono::milliseconds m_Stall;
            OnSamples m_OnSamples;
            int m_iRate = 0;
            std::atomic<std::size_t> m_nStageSamples{0}; // from the running stage
            mutable std::mutex m_Mutex;
            std::condition_variable m_Wake;
            bool m_bWatch = false;
            std::thread m_Watchdog;
            int m_iActive = -1;    // the running stage, -1 for none
            std::string m_Why;     // why the last echo-cancelling stage failed
            std::string m_Earlier; // each failed stage and why, for Route
        };

    } // namespace

    std::unique_ptr<IAudioCapture> MakeFallbackCapture(
        std::vector<std::unique_ptr<IAudioCapture>> _Stages, std::chrono::milliseconds _Stall)
    {
        return std::make_unique<FallbackCapture>(std::move(_Stages), _Stall);
    }

    std::unique_ptr<IAudioCapture> MakeFallbackCapture(std::unique_ptr<IAudioCapture> _pFirst,
        std::unique_ptr<IAudioCapture> _pSecond, std::chrono::milliseconds _Stall)
    {
        std::vector<std::unique_ptr<IAudioCapture>> stages;
        stages.push_back(std::move(_pFirst));
        stages.push_back(std::move(_pSecond));
        return MakeFallbackCapture(std::move(stages), _Stall);
    }

    void EchoTimeline::Push(const int16_t* _pSamples, std::size_t _nCount, int64_t _iTime)
    {
        if (_nCount == 0)
        {
            return;
        }
        if (_iTime >= 0)
        {
            m_Anchors.push_back({End(), _iTime});
        }
        m_Samples.insert(m_Samples.end(), _pSamples, _pSamples + _nCount);
    }

    int64_t EchoTimeline::TimeOf(int64_t _iIndex) const
    {
        if (m_Anchors.empty())
        {
            return 0;
        }
        // The last anchor at or before the index (the first, before them all).
        auto it = std::upper_bound(m_Anchors.begin(), m_Anchors.end(), _iIndex,
            [](int64_t _iValue, const Anchor& _Anchor) { return _iValue < _Anchor.m_iIndex; });
        const Anchor& anchor = it == m_Anchors.begin() ? *it : *(it - 1);
        return anchor.m_iTime + (_iIndex - anchor.m_iIndex) * 10000000 / m_iRate;
    }

    int64_t EchoTimeline::IndexAt(int64_t _iTime) const
    {
        if (m_Anchors.empty())
        {
            return m_iBegin;
        }
        auto it = std::upper_bound(m_Anchors.begin(), m_Anchors.end(), _iTime,
            [](int64_t _iValue, const Anchor& _Anchor) { return _iValue < _Anchor.m_iTime; });
        const Anchor& anchor = it == m_Anchors.begin() ? *it : *(it - 1);
        const int64_t idelta = _iTime - anchor.m_iTime;
        // Rounded to the nearest sample, either way.
        const int64_t isamples = (idelta * m_iRate + (idelta >= 0 ? 5000000 : -5000000)) / 10000000;
        return anchor.m_iIndex + isamples;
    }

    void EchoTimeline::Copy(int64_t _iFrom, std::size_t _nCount, std::vector<int16_t>& _Out) const
    {
        _Out.assign(_nCount, 0);
        const int64_t iend = End();
        for (std::size_t ni = 0; ni < _nCount; ++ni)
        {
            const int64_t iat = _iFrom + static_cast<int64_t>(ni);
            if (iat >= m_iBegin && iat < iend)
            {
                _Out[ni] = m_Samples[static_cast<std::size_t>(iat - m_iBegin)];
            }
        }
    }

    void EchoTimeline::TrimBefore(int64_t _iIndex)
    {
        if (_iIndex <= m_iBegin)
        {
            return;
        }
        const int64_t icut = (std::min)(_iIndex, End());
        m_Samples.erase(
            m_Samples.begin(), m_Samples.begin() + static_cast<std::ptrdiff_t>(icut - m_iBegin));
        m_iBegin = icut;
        // Anchors before the cut go, but the last of them stays: it still
        // dates the samples after it.
        std::size_t nkeep = 0;
        while (nkeep + 1 < m_Anchors.size() && m_Anchors[nkeep + 1].m_iIndex <= icut)
        {
            ++nkeep;
        }
        m_Anchors.erase(m_Anchors.begin(), m_Anchors.begin() + static_cast<std::ptrdiff_t>(nkeep));
    }

    int EchoLag(const std::vector<int16_t>& _Reference, const std::vector<int16_t>& _Mic,
        int _iMaxLag, double* _pCorrelation)
    {
        if (_pCorrelation)
        {
            *_pCorrelation = 0;
        }
        if (_Reference.empty() || _Mic.empty() || _iMaxLag < 0)
        {
            return 0;
        }
        double fref = 0;
        for (const int16_t sample : _Reference)
        {
            fref += static_cast<double>(sample) * sample;
        }
        if (fref <= 0)
        {
            return 0;
        }
        const auto score = [&](int _iLag)
        {
            double fdot = 0;
            double fmic = 0;
            const std::size_t nlag = static_cast<std::size_t>(_iLag);
            for (std::size_t ni = 0; ni < _Reference.size() && ni + nlag < _Mic.size(); ++ni)
            {
                const double fsample = _Mic[ni + nlag];
                fdot += static_cast<double>(_Reference[ni]) * fsample;
                fmic += fsample * fsample;
            }
            return fmic > 0 ? fdot / std::sqrt(fref * fmic) : 0.0;
        };
        // Every 4th lag, then each one around the best.
        int ibest = 0;
        double fbest = -2;
        for (int ilag = 0; ilag <= _iMaxLag; ilag += 4)
        {
            const double f = score(ilag);
            if (f > fbest)
            {
                fbest = f;
                ibest = ilag;
            }
        }
        const int icoarse = ibest;
        for (int ilag = (std::max)(0, icoarse - 3); ilag <= (std::min)(_iMaxLag, icoarse + 3);
            ++ilag)
        {
            const double f = score(ilag);
            if (f > fbest)
            {
                fbest = f;
                ibest = ilag;
            }
        }
        if (_pCorrelation)
        {
            *_pCorrelation = (std::max)(0.0, fbest);
        }
        return ibest;
    }

    std::vector<int16_t> EchoTestSignal(int _iRate)
    {
        // Chirps of 180 ms from 500 Hz to 3 kHz, softened at both ends, at
        // uneven gaps (no gap repeats, so no chirp lines up with another's
        // echo), after a short quiet start.
        constexpr double kPi = 3.14159265358979323846;
        const double astarts[] = {0.3, 0.95, 1.85, 2.45};
        const double fchirp = 0.18;
        const double flow = 500.0;
        const double fhigh = 3000.0;
        std::vector<int16_t> out(static_cast<std::size_t>(3.0 * _iRate), 0);
        const std::size_t nchirp = static_cast<std::size_t>(fchirp * _iRate);
        for (const double fstart : astarts)
        {
            const std::size_t nat = static_cast<std::size_t>(fstart * _iRate);
            for (std::size_t ni = 0; ni < nchirp && nat + ni < out.size(); ++ni)
            {
                const double ft = static_cast<double>(ni) / _iRate;
                const double fphase =
                    2 * kPi * (flow * ft + (fhigh - flow) * ft * ft / (2 * fchirp));
                const double fwindow =
                    0.5 - 0.5 * std::cos(2 * kPi * static_cast<double>(ni) / nchirp);
                out[nat + ni] = static_cast<int16_t>(9000.0 * fwindow * std::sin(fphase));
            }
        }
        return out;
    }

#if defined(_WIN32)

    namespace
    {

        // Releases a COM pointer.
        template <class T> struct ComRef
        {
            T* m_pPointer = nullptr;

            ComRef() = default;
            ComRef(const ComRef&) = delete;
            ComRef& operator=(const ComRef&) = delete;

            ~ComRef()
            {
                if (m_pPointer)
                {
                    m_pPointer->Release();
                }
            }

            T* operator->() const
            {
                return m_pPointer;
            }

            void** Out()
            {
                return reinterpret_cast<void**>(&m_pPointer);
            }
        };

        // COM for one thread (audio threads use the multithreaded apartment).
        struct ComScope
        {
            HRESULT m_hResult;

            ComScope() : m_hResult(CoInitializeEx(nullptr, COINIT_MULTITHREADED))
            {
            }

            ComScope(const ComScope&) = delete;
            ComScope& operator=(const ComScope&) = delete;

            ~ComScope()
            {
                if (SUCCEEDED(m_hResult))
                {
                    CoUninitialize();
                }
            }
        };

        std::string Failed(const char* _szWhat, HRESULT _hResult)
        {
            char aBuffer[128];
            std::snprintf(aBuffer, sizeof(aBuffer), "%s failed (0x%08lx)", _szWhat,
                static_cast<unsigned long>(_hResult));
            return aBuffer;
        }

        WAVEFORMATEX MonoFormat(int _iSampleRate)
        {
            WAVEFORMATEX format = {};
            format.wFormatTag = WAVE_FORMAT_PCM;
            format.nChannels = 1;
            format.nSamplesPerSec = static_cast<DWORD>(_iSampleRate);
            format.wBitsPerSample = 16;
            format.nBlockAlign = 2;
            format.nAvgBytesPerSec = static_cast<DWORD>(_iSampleRate) * 2;
            return format;
        }

        std::string Utf8(const wchar_t* _szText)
        {
            if (!_szText || !*_szText)
            {
                return {};
            }
            const int ilength =
                WideCharToMultiByte(CP_UTF8, 0, _szText, -1, nullptr, 0, nullptr, nullptr);
            if (ilength <= 1)
            {
                return {};
            }
            std::string out(static_cast<std::size_t>(ilength), '\0');
            WideCharToMultiByte(CP_UTF8, 0, _szText, -1, out.data(), ilength, nullptr, nullptr);
            out.resize(static_cast<std::size_t>(ilength - 1));
            return out;
        }

        std::wstring Wide(const std::string& _Text)
        {
            const int ilength = MultiByteToWideChar(CP_UTF8, 0, _Text.c_str(), -1, nullptr, 0);
            if (ilength <= 1)
            {
                return {};
            }
            std::wstring out(static_cast<std::size_t>(ilength), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, _Text.c_str(), -1, out.data(), ilength);
            out.resize(static_cast<std::size_t>(ilength - 1));
            return out;
        }

        // PKEY_Device_FriendlyName, here so no GUID library is needed.
        const PROPERTYKEY kFriendlyName = {
            {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

        bool MakeEnumerator(ComRef<IMMDeviceEnumerator>& _Enumerator, std::string& _Error)
        {
            const HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), _Enumerator.Out());
            if (FAILED(hr))
            {
                _Error = Failed("Listing audio devices", hr);
                return false;
            }
            return true;
        }

        // The endpoint id of a device.
        std::string DeviceId(IMMDevice* _pDevice)
        {
            LPWSTR szid = nullptr;
            if (FAILED(_pDevice->GetId(&szid)))
            {
                return {};
            }
            std::string id = Utf8(szid);
            CoTaskMemFree(szid);
            return id;
        }

        // The id SetAudioDevices chose for `_eFlow` ("" for the default).
        std::string ChosenId(EDataFlow _eFlow)
        {
            std::string capture;
            std::string render;
            ChosenAudioDevices(capture, render);
            return _eFlow == eCapture ? capture : render;
        }

        // The ids of the active endpoints of `_eFlow`, in the system's order
        // (the collection the echo canceller's device indexes count in).
        std::vector<std::string> ActiveIds(IMMDeviceEnumerator* _pEnumerator, EDataFlow _eFlow)
        {
            std::vector<std::string> out;
            ComRef<IMMDeviceCollection> devices;
            UINT ucount = 0;
            if (FAILED(_pEnumerator->EnumAudioEndpoints(_eFlow, DEVICE_STATE_ACTIVE,
                    reinterpret_cast<IMMDeviceCollection**>(devices.Out()))) ||
                FAILED(devices->GetCount(&ucount)))
            {
                return out;
            }
            for (UINT i = 0; i < ucount; ++i)
            {
                ComRef<IMMDevice> item;
                out.push_back(SUCCEEDED(devices->Item(i, reinterpret_cast<IMMDevice**>(item.Out())))
                                  ? DeviceId(item.m_pPointer)
                                  : std::string());
            }
            return out;
        }

        // The system's default endpoint of `_eFlow` for voice, "" if none.
        // The console role, not communications: it is the "default device"
        // in Sound settings, where other apps play and record, and the role
        // Windows names for voice commands. The communications default is
        // for calls, and Windows treats a stream on it as one, turning
        // other apps down. Bragi isn't a call. Where one microphone holds
        // both roles (a lone webcam), both give the same device and the
        // ducking opt-out below is what keeps other audio up.
        std::string DefaultId(IMMDeviceEnumerator* _pEnumerator, EDataFlow _eFlow)
        {
            ComRef<IMMDevice> device;
            if (FAILED(_pEnumerator->GetDefaultAudioEndpoint(
                    _eFlow, eConsole, reinterpret_cast<IMMDevice**>(device.Out()))))
            {
                return {};
            }
            return DeviceId(device.m_pPointer);
        }

        // The endpoint voice uses for `_eFlow`: the chosen one while it's
        // plugged in, else the default (PickAudioEndpoint). `_Active` gets
        // the active endpoints it was picked from; `_bDefault` whether it's
        // the default.
        bool ResolveEndpoint(IMMDeviceEnumerator* _pEnumerator, EDataFlow _eFlow,
            ComRef<IMMDevice>& _Device, std::vector<std::string>& _Active, bool& _bDefault,
            std::string& _Error)
        {
            _Active = ActiveIds(_pEnumerator, _eFlow);
            const std::string defaultId = DefaultId(_pEnumerator, _eFlow);
            const std::string id = PickAudioEndpoint(ChosenId(_eFlow), defaultId, _Active);
            const std::wstring wide = Wide(id);
            if (id.empty() || FAILED(_pEnumerator->GetDevice(
                                  wide.c_str(), reinterpret_cast<IMMDevice**>(_Device.Out()))))
            {
                _Error = _eFlow == eCapture ? "No microphone found" : "No speaker found";
                return false;
            }
            _bDefault = id == defaultId;
            return true;
        }

        // A device's name for the log ("HD Pro Webcam C920 (default)").
        std::string EndpointName(IMMDevice* _pDevice, bool _bDefault)
        {
            std::string name;
            ComRef<IPropertyStore> store;
            if (SUCCEEDED(_pDevice->OpenPropertyStore(
                    STGM_READ, reinterpret_cast<IPropertyStore**>(store.Out()))))
            {
                PROPVARIANT value;
                PropVariantInit(&value);
                if (SUCCEEDED(store->GetValue(kFriendlyName, &value)) && value.vt == VT_LPWSTR)
                {
                    name = Utf8(value.pwszVal);
                }
                PropVariantClear(&value);
            }
            if (name.empty())
            {
                name = "unnamed device";
            }
            return _bDefault ? name + " (default)" : name;
        }

        // Keeps Bragi from turning other apps' audio down.
        //
        // Windows "ducks" (by default lowers by 80%, or mutes) every other
        // app's audio while a communication stream is open on the default
        // communications device ("communications activity" in Sound
        // settings). The echo canceller opens its streams as a call would,
        // and a lone microphone is often that device too, so music in other
        // apps went quiet whenever the mic was on. Voice takes commands; it
        // isn't a call.
        //
        // Microsoft's documented opt-out ("Disabling the Default Ducking
        // Experience"): activate IAudioSessionManager2 on the endpoint, take
        // the process's default session (GetAudioSessionControl with no
        // GUID, flags 0; the session every stream we or the DSP open joins),
        // and SetDuckingPreference(TRUE) on its IAudioSessionControl2 before
        // the streams start (it takes effect on the next start). The control
        // is held while the streams run so the session, and its preference,
        // can't go away in between.
        class DuckingOptOut
        {
          public:
            // "ok", or why not.
            std::string Apply(IMMDevice* _pDevice)
            {
                ComRef<IAudioSessionManager2> manager;
                HRESULT hr = _pDevice->Activate(
                    __uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, manager.Out());
                if (FAILED(hr))
                {
                    return Failed("session manager", hr);
                }
                ComRef<IAudioSessionControl> control;
                hr = manager->GetAudioSessionControl(
                    nullptr, 0, reinterpret_cast<IAudioSessionControl**>(control.Out()));
                if (FAILED(hr))
                {
                    return Failed("session", hr);
                }
                hr = control->QueryInterface(__uuidof(IAudioSessionControl2), m_Control.Out());
                if (FAILED(hr))
                {
                    return Failed("session control", hr);
                }
                hr = m_Control->SetDuckingPreference(TRUE);
                return SUCCEEDED(hr) ? std::string("ok") : Failed("SetDuckingPreference", hr);
            }

          private:
            ComRef<IAudioSessionControl2> m_Control;
        };

        // The same for one stream of our own: IAudioClientDuckingControl
        // asks that this stream not duck others, whatever the system takes
        // it for. After Initialize, before Start. "ok", or why not (Windows
        // 10 doesn't have it; the session's opt-out still holds there).
        std::string NoDuckingFromStream(IAudioClient* _pClient)
        {
            ComRef<IAudioClientDuckingControl> control;
            HRESULT hr = _pClient->GetService(__uuidof(IAudioClientDuckingControl), control.Out());
            if (FAILED(hr))
            {
                return Failed("stream ducking control", hr);
            }
            hr = control->SetDuckingOptionsForCurrentStream(
                AUDIO_DUCKING_OPTIONS_DO_NOT_DUCK_OTHER_STREAMS);
            return SUCCEEDED(hr) ? std::string("ok")
                                 : Failed("SetDuckingOptionsForCurrentStream", hr);
        }

        // The log's word on an opt-out: "ok", or what failed.
        std::string OptOutResult(const std::string& _First, const char* _szFirst,
            const std::string& _Second, const char* _szSecond)
        {
            if (_First == "ok" && _Second == "ok")
            {
                return "ok";
            }
            return std::string(_szFirst) + " " + _First + ", " + _szSecond + " " + _Second;
        }

        // The chosen (or default) endpoint of `_eFlow` as a shared-mode,
        // event-driven client at our format; the engine converts
        // (AUTOCONVERTPCM). Never the communications role (DefaultId), and
        // its session and stream are opted out of ducking other apps
        // (`_Ducking` holds the session's opt-out while it runs). `_Name`
        // and `_OptOut` say which device and how the opt-out went, for the
        // log.
        bool OpenClient(EDataFlow _eFlow, int _iSampleRate, HANDLE _hEvent,
            ComRef<IAudioClient>& _Client, DuckingOptOut& _Ducking, std::string& _Name,
            std::string& _OptOut, std::string& _Error)
        {
            ComRef<IMMDeviceEnumerator> enumerator;
            if (!MakeEnumerator(enumerator, _Error))
            {
                return false;
            }
            ComRef<IMMDevice> device;
            std::vector<std::string> active;
            bool bdefault = false;
            if (!ResolveEndpoint(enumerator.m_pPointer, _eFlow, device, active, bdefault, _Error))
            {
                return false;
            }
            // The session preference is a speaker's: on a microphone Windows
            // refuses it (AUDCLNT_E_WRONG_ENDPOINT_TYPE), so only the
            // stream's opt-out applies there.
            const std::string session =
                _eFlow == eRender ? _Ducking.Apply(device.m_pPointer) : std::string("ok");
            HRESULT hr =
                device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, _Client.Out());
            if (FAILED(hr))
            {
                _Error = Failed("Opening the audio device", hr);
                return false;
            }
            const WAVEFORMATEX format = MonoFormat(_iSampleRate);
            const DWORD dwflags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                  AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                  AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
            // A 40 ms buffer (in 100 ns units).
            hr =
                _Client->Initialize(AUDCLNT_SHAREMODE_SHARED, dwflags, 400000, 0, &format, nullptr);
            if (FAILED(hr))
            {
                _Error = Failed("Starting the audio device", hr);
                return false;
            }
            const std::string stream = NoDuckingFromStream(_Client.m_pPointer);
            hr = _Client->SetEventHandle(_hEvent);
            if (FAILED(hr))
            {
                _Error = Failed("Starting the audio device", hr);
                return false;
            }
            _Name = EndpointName(device.m_pPointer, bdefault);
            _OptOut = OptOutResult(session, "session", stream, "stream");
            return true;
        }

        // Runs `_Loop(ready)` on a thread and waits until it has opened its
        // device (or failed): the shape of every device below.
        class DeviceThread
        {
          public:
            using Loop = std::function<void(const std::function<void(bool, const std::string&)>&)>;

            ~DeviceThread()
            {
                Stop();
            }

            bool Start(Loop _Loop, std::string& _Error)
            {
                Stop();
                m_bRunning = true;
                std::mutex mutex;
                std::condition_variable ready;
                bool bdone = false;
                bool bok = false;
                std::string error;
                m_Thread = std::thread(
                    [&, loop = std::move(_Loop)]()
                    {
                        loop(
                            [&](bool _bOk, const std::string& _Error)
                            {
                                std::lock_guard<std::mutex> lock(mutex);
                                bok = _bOk;
                                error = _Error;
                                bdone = true;
                                ready.notify_all();
                            });
                    });
                std::unique_lock<std::mutex> lock(mutex);
                ready.wait(lock, [&]() { return bdone; });
                lock.unlock();
                if (!bok)
                {
                    Stop();
                    _Error = error;
                }
                return bok;
            }

            void Stop()
            {
                m_bRunning = false;
                if (m_Thread.joinable())
                {
                    m_Thread.join();
                }
            }

            bool Running() const
            {
                return m_bRunning;
            }

          private:
            std::atomic<bool> m_bRunning{false};
            std::thread m_Thread;
        };

        // ---- plain capture --------------------------------------------------

        class WasapiCapture final : public IAudioCapture
        {
          public:
            ~WasapiCapture() override
            {
                Stop();
            }

            bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) override
            {
                m_OnSamples = std::move(_OnSamples);
                return m_Thread.Start([this, _iSampleRate](const auto& _Ready)
                    { Loop(_iSampleRate, _Ready); }, _Error);
            }

            void Stop() override
            {
                m_Thread.Stop();
            }

            std::string Description() const override
            {
                return "Microphone";
            }

            std::string Route() const override
            {
                std::lock_guard<std::mutex> lock(m_RouteMutex);
                return m_Route;
            }

          private:
            void Loop(int _iSampleRate, const std::function<void(bool, const std::string&)>& _Ready)
            {
                ComScope com;
                HANDLE hevent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
                ComRef<IAudioClient> client;
                ComRef<IAudioCaptureClient> capture;
                DuckingOptOut ducking;
                std::string name;
                std::string optOut;
                std::string error;
                {
                    std::lock_guard<std::mutex> lock(m_RouteMutex);
                    m_Route.clear();
                }
                if (!OpenClient(
                        eCapture, _iSampleRate, hevent, client, ducking, name, optOut, error) ||
                    FAILED(client->GetService(__uuidof(IAudioCaptureClient), capture.Out())) ||
                    FAILED(client->Start()))
                {
                    CloseHandle(hevent);
                    _Ready(false, error.empty() ? "The microphone could not start" : error);
                    return;
                }
                {
                    // No echo reference: plain capture cancels nothing.
                    std::lock_guard<std::mutex> lock(m_RouteMutex);
                    m_Route = "mic: " + name + "; echo reference: none; ducking opt-out: " + optOut;
                }
                _Ready(true, {});
                DWORD dwtask = 0;
                HANDLE htask = AvSetMmThreadCharacteristicsW(L"Audio", &dwtask);
                std::vector<int16_t> silence;
                while (m_Thread.Running())
                {
                    if (WaitForSingleObject(hevent, 200) != WAIT_OBJECT_0)
                    {
                        continue;
                    }
                    UINT32 upacket = 0;
                    while (m_Thread.Running() && SUCCEEDED(capture->GetNextPacketSize(&upacket)) &&
                           upacket > 0)
                    {
                        BYTE* pdata = nullptr;
                        UINT32 uframes = 0;
                        DWORD dwflags = 0;
                        if (FAILED(
                                capture->GetBuffer(&pdata, &uframes, &dwflags, nullptr, nullptr)))
                        {
                            break;
                        }
                        if (dwflags & AUDCLNT_BUFFERFLAGS_SILENT)
                        {
                            silence.assign(uframes, 0);
                            m_OnSamples(silence.data(), uframes);
                        }
                        else
                        {
                            m_OnSamples(reinterpret_cast<const int16_t*>(pdata), uframes);
                        }
                        capture->ReleaseBuffer(uframes);
                    }
                }
                client->Stop();
                if (htask)
                {
                    AvRevertMmThreadCharacteristics(htask);
                }
                CloseHandle(hevent);
            }

            OnSamples m_OnSamples;
            DeviceThread m_Thread;
            mutable std::mutex m_RouteMutex;
            std::string m_Route; // what Route() says
        };

        // ---- echo-cancelled capture ----------------------------------------

        // The smallest IMediaBuffer: the DSP writes its output into it.
        class MediaBuffer final : public IMediaBuffer
        {
          public:
            explicit MediaBuffer(DWORD _dwMax) : m_Data(_dwMax)
            {
            }

            STDMETHODIMP QueryInterface(REFIID _Iid, void** _ppOut) override
            {
                if (_Iid == IID_IUnknown || _Iid == IID_IMediaBuffer)
                {
                    *_ppOut = static_cast<IMediaBuffer*>(this);
                    AddRef();
                    return S_OK;
                }
                *_ppOut = nullptr;
                return E_NOINTERFACE;
            }

            STDMETHODIMP_(ULONG) AddRef() override
            {
                return ++m_uRefs;
            }

            STDMETHODIMP_(ULONG) Release() override
            {
                const ULONG urefs = --m_uRefs;
                if (urefs == 0)
                {
                    delete this;
                }
                return urefs;
            }

            STDMETHODIMP SetLength(DWORD _dwLength) override
            {
                if (_dwLength > m_Data.size())
                {
                    return E_INVALIDARG;
                }
                m_dwLength = _dwLength;
                return S_OK;
            }

            STDMETHODIMP GetMaxLength(DWORD* _pdwMax) override
            {
                *_pdwMax = static_cast<DWORD>(m_Data.size());
                return S_OK;
            }

            STDMETHODIMP GetBufferAndLength(BYTE** _ppBuffer, DWORD* _pdwLength) override
            {
                if (_ppBuffer)
                {
                    *_ppBuffer = m_Data.data();
                }
                if (_pdwLength)
                {
                    *_pdwLength = m_dwLength;
                }
                return S_OK;
            }

          private:
            std::vector<BYTE> m_Data;
            DWORD m_dwLength = 0;
            std::atomic<ULONG> m_uRefs{1};
        };

        bool SetProperty(IPropertyStore* _pStore, const PROPERTYKEY& _Key, LONG _iValue)
        {
            PROPVARIANT value;
            PropVariantInit(&value);
            value.vt = VT_I4;
            value.lVal = _iValue;
            return SUCCEEDED(_pStore->SetValue(_Key, value));
        }

        bool SetProperty(IPropertyStore* _pStore, const PROPERTYKEY& _Key, bool _bValue)
        {
            PROPVARIANT value;
            PropVariantInit(&value);
            value.vt = VT_BOOL;
            value.boolVal = _bValue ? VARIANT_TRUE : VARIANT_FALSE;
            return SUCCEEDED(_pStore->SetValue(_Key, value));
        }

        // The DSP's media type for 16 kHz mono 16-bit, for SetInputType or
        // SetOutputType (`_bInput`) on `_iStream`.
        HRESULT SetMonoType(IMediaObject* _pDsp, bool _bInput, DWORD _iStream)
        {
            DMO_MEDIA_TYPE type = {};
            HRESULT hr = MoInitMediaType(&type, sizeof(WAVEFORMATEX));
            if (FAILED(hr))
            {
                return hr;
            }
            type.majortype = MEDIATYPE_Audio;
            type.subtype = MEDIASUBTYPE_PCM;
            type.bFixedSizeSamples = TRUE;
            type.lSampleSize = 2;
            type.formattype = FORMAT_WaveFormatEx;
            *reinterpret_cast<WAVEFORMATEX*>(type.pbFormat) = MonoFormat(16000);
            hr = _bInput ? _pDsp->SetInputType(_iStream, &type, 0)
                         : _pDsp->SetOutputType(_iStream, &type, 0);
            MoFreeMediaType(&type);
            return hr;
        }

        // A silent stream of our own on a speaker, running while the echo
        // canceller does. The DSP takes its echo reference from that
        // speaker, and per Microsoft's documentation of
        // MFPKEY_WMAAECMA_DEVICE_INDEXES, "If the selected rendering device
        // does not have an active stream, the DSP cannot process any
        // output": with nothing else playing it gave no audio at all, and
        // voice fell back to plain capture. Silence changes nothing anyone
        // hears.
        class SilentStream
        {
          public:
            SilentStream() = default;
            SilentStream(const SilentStream&) = delete;
            SilentStream& operator=(const SilentStream&) = delete;

            ~SilentStream()
            {
                if (m_bStarted)
                {
                    m_Client->Stop();
                }
            }

            // "ok", or why not. `_bNoDucking`: the stream's ducking opt-out
            // too (NoDuckingFromStream).
            std::string Start(IMMDevice* _pDevice, bool _bNoDucking)
            {
                HRESULT hr =
                    _pDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, m_Client.Out());
                if (FAILED(hr))
                {
                    return Failed("opening it", hr);
                }
                const WAVEFORMATEX format = MonoFormat(16000);
                const DWORD dwflags =
                    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
                // A 200 ms buffer (in 100 ns units), topped up each pass of
                // the DSP's loop.
                hr = m_Client->Initialize(
                    AUDCLNT_SHAREMODE_SHARED, dwflags, 2000000, 0, &format, nullptr);
                if (FAILED(hr))
                {
                    return Failed("setting it up", hr);
                }
                if (_bNoDucking)
                {
                    NoDuckingFromStream(m_Client.m_pPointer);
                }
                hr = m_Client->GetBufferSize(&m_uFrames);
                if (SUCCEEDED(hr))
                {
                    hr = m_Client->GetService(__uuidof(IAudioRenderClient), m_Render.Out());
                }
                if (FAILED(hr))
                {
                    return Failed("setting it up", hr);
                }
                TopUp();
                hr = m_Client->Start();
                if (FAILED(hr))
                {
                    return Failed("starting it", hr);
                }
                m_bStarted = true;
                return "ok";
            }

            // Fill what has played with silence.
            void TopUp()
            {
                UINT32 upadding = 0;
                if (!m_Render.m_pPointer || FAILED(m_Client->GetCurrentPadding(&upadding)) ||
                    upadding >= m_uFrames)
                {
                    return;
                }
                const UINT32 ufree = m_uFrames - upadding;
                BYTE* pdata = nullptr;
                if (SUCCEEDED(m_Render->GetBuffer(ufree, &pdata)))
                {
                    m_Render->ReleaseBuffer(ufree, AUDCLNT_BUFFERFLAGS_SILENT);
                }
            }

          private:
            ComRef<IAudioClient> m_Client;
            ComRef<IAudioRenderClient> m_Render;
            UINT32 m_uFrames = 0;
            bool m_bStarted = false;
        };

        // The microphone and the speaker voice uses (the ones playback
        // opens), resolved once by id, and the DSP's indexes for them.
        struct EchoDevices
        {
            ComRef<IMMDevice> m_Mic;
            ComRef<IMMDevice> m_Speaker;
            bool m_bMicDefault = false;
            bool m_bSpeakerDefault = false;
            int32_t m_iIndexes = -1;
        };

        bool FindEchoDevices(EchoDevices& _Devices, std::string& _Error)
        {
            ComRef<IMMDeviceEnumerator> enumerator;
            std::vector<std::string> mics;
            std::vector<std::string> speakers;
            std::string error;
            if (!MakeEnumerator(enumerator, error) ||
                !ResolveEndpoint(enumerator.m_pPointer, eCapture, _Devices.m_Mic, mics,
                    _Devices.m_bMicDefault, error) ||
                !ResolveEndpoint(enumerator.m_pPointer, eRender, _Devices.m_Speaker, speakers,
                    _Devices.m_bSpeakerDefault, error))
            {
                _Error = error.empty() ? std::string("it can't find the devices") : error;
                return false;
            }
            // A device the DSP can't be pointed at fails here, so plain
            // capture opens it instead of the DSP quietly using another.
            if (!EchoDeviceIndexes(DeviceId(_Devices.m_Mic.m_pPointer), mics,
                    DeviceId(_Devices.m_Speaker.m_pPointer), speakers, _Devices.m_iIndexes))
            {
                _Error = "it can't use the chosen device";
                return false;
            }
            return true;
        }

        // How the echo canceller is pointed at its devices. MakeVoiceCapture
        // tries them in this order, each until it gives no audio for 2 s,
        // and the log's route says which ran: if the first never does, the
        // next show whether the explicit device indexes or the ducking
        // opt-out is what silences it.
        enum class EchoSetup
        {
            kByIndex,         // the mic and speaker voice uses, by index; other apps kept up
            kByIndexNoOptOut, // the same without the ducking opt-out
            kSystemDefaults,  // (-1, -1): the DSP opens the defaults itself; no opt-out
        };

        // The Voice Capture DSP in source mode: it opens the microphone and
        // a loopback of the speaker itself, and hands back echo-cancelled
        // 16 kHz mono. By index (kByIndex*), its echo reference is the
        // speaker playback opens: left at -1 the DSP picks "the default
        // device" itself, which for a voice canceller can be the
        // communications one, not where Bragi (and other apps) play, and
        // then it cancels the wrong output and Bragi hears itself. Indexes
        // count in the active endpoints (EchoDeviceIndexes), as Microsoft's
        // documentation and the chosen-device setup that worked before both
        // have it.
        class EchoCancelledCapture final : public IAudioCapture
        {
          public:
            explicit EchoCancelledCapture(EchoSetup _eSetup) : m_eSetup(_eSetup)
            {
            }

            ~EchoCancelledCapture() override
            {
                Stop();
            }

            bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) override
            {
                if (_iSampleRate != 16000)
                {
                    _Error = "Echo cancellation gives 16 kHz only";
                    return false;
                }
                m_OnSamples = std::move(_OnSamples);
                {
                    std::lock_guard<std::mutex> lock(m_ErrorMutex);
                    m_Error.clear();
                }
                return m_Thread.Start([this](const auto& _Ready) { Loop(_Ready); }, _Error);
            }

            void Stop() override
            {
                m_Thread.Stop();
            }

            std::string Description() const override
            {
                return "Microphone (echo cancelled)";
            }

            std::string LastError() const override
            {
                std::lock_guard<std::mutex> lock(m_ErrorMutex);
                return m_Error;
            }

            std::string Route() const override
            {
                std::lock_guard<std::mutex> lock(m_ErrorMutex);
                return m_Route;
            }

          private:
            static bool Configure(IMediaObject* _pDsp, LONG _iDevices, std::string& _Error)
            {
                ComRef<IPropertyStore> store;
                if (FAILED(_pDsp->QueryInterface(
                        IID_PPV_ARGS(reinterpret_cast<IPropertyStore**>(store.Out())))))
                {
                    _Error = "The echo canceller has no settings";
                    return false;
                }
                if (!SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_SYSTEM_MODE,
                        static_cast<LONG>(SINGLE_CHANNEL_AEC)) ||
                    !SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_DMO_SOURCE_MODE, true) ||
                    !SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_DEVICE_INDEXES, _iDevices) ||
                    !SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATURE_MODE, true))
                {
                    _Error = "The echo canceller refused its settings";
                    return false;
                }
                // Best effort: some Windows builds refuse some of these.
                const EchoOptions options = CurrentEchoOptions();
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_ECHO_LENGTH,
                    LONG(options.m_iEchoLengthMs));
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_NS,
                    LONG(options.m_bNoiseSuppression ? 1 : 0));
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_AGC, false);
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_AES,
                    LONG((std::max)(0, (std::min)(2, options.m_iSuppression))));
                // Center clipping mutes what's quiet after the echo is taken
                // out, and with it soft words and sentence ends
                // (words and sentences went missing): off by default.
                SetProperty(
                    store.m_pPointer, MFPKEY_WMAAECMA_FEATR_CENTER_CLIP, options.m_bCenterClip);
                return true;
            }

            static bool SetOutput(IMediaObject* _pDsp, std::string& _Error)
            {
                DMO_MEDIA_TYPE type = {};
                if (FAILED(MoInitMediaType(&type, sizeof(WAVEFORMATEX))))
                {
                    _Error = "The echo canceller could not be set up";
                    return false;
                }
                type.majortype = MEDIATYPE_Audio;
                type.subtype = MEDIASUBTYPE_PCM;
                type.bFixedSizeSamples = TRUE;
                type.formattype = FORMAT_WaveFormatEx;
                *reinterpret_cast<WAVEFORMATEX*>(type.pbFormat) = MonoFormat(16000);
                HRESULT hr = _pDsp->SetOutputType(0, &type, 0);
                MoFreeMediaType(&type);
                if (FAILED(hr))
                {
                    _Error = Failed("Setting the echo canceller's format", hr);
                    return false;
                }
                hr = _pDsp->AllocateStreamingResources();
                if (FAILED(hr))
                {
                    _Error = Failed("Starting the echo canceller", hr);
                    return false;
                }
                return true;
            }

            void SetRoute(const std::string& _Route)
            {
                std::lock_guard<std::mutex> lock(m_ErrorMutex);
                m_Route = _Route;
            }

            void Loop(const std::function<void(bool, const std::string&)>& _Ready)
            {
                ComScope com;
                const bool boptOut = m_eSetup == EchoSetup::kByIndex;
                std::string route = m_eSetup == EchoSetup::kByIndex ? "echo canceller by index"
                                    : m_eSetup == EchoSetup::kByIndexNoOptOut
                                        ? "echo canceller by index, no ducking opt-out"
                                        : "echo canceller on the system's default devices";
                SetRoute(route);

                // Before the DSP opens its streams (AllocateStreamingResources
                // in SetOutput): the opt-out counts from a stream's start, and
                // the DSP needs its speaker running from the start.
                DuckingOptOut speakerDucking;
                std::vector<std::unique_ptr<SilentStream>> keepAlive;
                std::string kept;
                const auto keep = [&](IMMDevice* _pDevice, bool _bDefault)
                {
                    auto pstream = std::make_unique<SilentStream>();
                    const std::string result = pstream->Start(_pDevice, boptOut);
                    kept += (kept.empty() ? "" : ", ") + EndpointName(_pDevice, _bDefault) +
                            (result == "ok" ? std::string() : " (failed: " + result + ")");
                    if (result == "ok")
                    {
                        keepAlive.push_back(std::move(pstream));
                    }
                };
                EchoDevices devices;
                std::string error;
                if (m_eSetup != EchoSetup::kSystemDefaults)
                {
                    if (!FindEchoDevices(devices, error))
                    {
                        _Ready(false, error);
                        return;
                    }
                    char aIndexes[16];
                    std::snprintf(aIndexes, sizeof(aIndexes), "0x%08lx",
                        static_cast<unsigned long>(static_cast<uint32_t>(devices.m_iIndexes)));
                    route += std::string(" (") + aIndexes + "); mic: " +
                             EndpointName(devices.m_Mic.m_pPointer, devices.m_bMicDefault) +
                             "; echo reference: " +
                             EndpointName(devices.m_Speaker.m_pPointer, devices.m_bSpeakerDefault);
                    const std::string optOut =
                        boptOut ? speakerDucking.Apply(devices.m_Speaker.m_pPointer) : "";
                    keep(devices.m_Speaker.m_pPointer, devices.m_bSpeakerDefault);
                    route += "; kept running: " + kept;
                    route += boptOut ? "; ducking opt-out: " + optOut : "";
                }
                else
                {
                    // The DSP's "default" may be either role's: keep both
                    // running.
                    ComRef<IMMDeviceEnumerator> enumerator;
                    if (!MakeEnumerator(enumerator, error))
                    {
                        _Ready(false, error);
                        return;
                    }
                    std::string first;
                    for (const ERole erole : {eConsole, eCommunications})
                    {
                        ComRef<IMMDevice> device;
                        if (FAILED(enumerator->GetDefaultAudioEndpoint(
                                eRender, erole, reinterpret_cast<IMMDevice**>(device.Out()))))
                        {
                            continue;
                        }
                        const std::string id = DeviceId(device.m_pPointer);
                        if (id != first)
                        {
                            first = first.empty() ? id : first;
                            keep(device.m_pPointer, true);
                        }
                    }
                    route += "; kept running: " + (kept.empty() ? std::string("none") : kept);
                }
                SetRoute(route);

                ComRef<IMediaObject> dsp;
                const HRESULT hr = CoCreateInstance(
                    CLSID_CWMAudioAEC, nullptr, CLSCTX_INPROC_SERVER, IID_IMediaObject, dsp.Out());
                if (FAILED(hr))
                {
                    _Ready(false, Failed("Opening the echo canceller", hr));
                    return;
                }
                const LONG iindexes = m_eSetup == EchoSetup::kSystemDefaults
                                          ? static_cast<LONG>(0xFFFFFFFFu)
                                          : static_cast<LONG>(devices.m_iIndexes);
                if (!Configure(dsp.m_pPointer, iindexes, error) ||
                    !SetOutput(dsp.m_pPointer, error))
                {
                    _Ready(false, error);
                    return;
                }
                _Ready(true, {});

                // How it went, for the route of a run that gave nothing.
                std::size_t nreads = 0;
                std::size_t nbytes = 0;
                HRESULT hrlast = S_OK;
                auto* pbuffer = new MediaBuffer(16000 * 2); // one second
                while (m_Thread.Running())
                {
                    for (const auto& pstream : keepAlive)
                    {
                        pstream->TopUp();
                    }
                    pbuffer->SetLength(0);
                    DMO_OUTPUT_DATA_BUFFER output = {};
                    output.pBuffer = pbuffer;
                    DWORD dwstatus = 0;
                    const HRESULT hrout = dsp->ProcessOutput(0, 1, &output, &dwstatus);
                    ++nreads;
                    hrlast = hrout;
                    if (FAILED(hrout))
                    {
                        std::lock_guard<std::mutex> lock(m_ErrorMutex);
                        m_Error = Failed("The echo canceller", hrout);
                        break;
                    }
                    BYTE* pdata = nullptr;
                    DWORD dwlength = 0;
                    pbuffer->GetBufferAndLength(&pdata, &dwlength);
                    if (dwlength >= 2)
                    {
                        nbytes += dwlength;
                        m_OnSamples(reinterpret_cast<const int16_t*>(pdata), dwlength / 2);
                    }
                    if (!(output.dwStatus & DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE))
                    {
                        Sleep(10);
                    }
                }
                pbuffer->Release();
                dsp->FreeStreamingResources();
                if (nbytes == 0)
                {
                    char aStatus[96];
                    std::snprintf(aStatus, sizeof(aStatus),
                        "; nothing in %zu reads (last 0x%08lx)", nreads,
                        static_cast<unsigned long>(hrlast));
                    SetRoute(route + aStatus);
                }
            }

            const EchoSetup m_eSetup;
            OnSamples m_OnSamples;
            DeviceThread m_Thread;
            mutable std::mutex m_ErrorMutex; // guards m_Error and m_Route
            std::string m_Error;             // why the loop stopped early
            std::string m_Route;             // what Route() says
        };

        // The Voice Capture DSP in filter mode: 10 ms of the microphone and
        // 10 ms of the speaker in (lined up by the caller), the cancelled
        // microphone out.
        class FilterDsp
        {
          public:
            static constexpr std::size_t kFrame = 160;

            FilterDsp() = default;
            FilterDsp(const FilterDsp&) = delete;
            FilterDsp& operator=(const FilterDsp&) = delete;

            ~FilterDsp()
            {
                if (m_pOut)
                {
                    m_pOut->Release();
                }
                if (m_bStarted)
                {
                    m_Dsp->FreeStreamingResources();
                }
            }

            bool Open(const EchoOptions& _Options, std::string& _Error)
            {
                HRESULT hr = CoCreateInstance(CLSID_CWMAudioAEC, nullptr, CLSCTX_INPROC_SERVER,
                    IID_IMediaObject, m_Dsp.Out());
                if (FAILED(hr))
                {
                    _Error = Failed("Opening the echo canceller", hr);
                    return false;
                }
                ComRef<IPropertyStore> store;
                if (FAILED(m_Dsp->QueryInterface(
                        IID_PPV_ARGS(reinterpret_cast<IPropertyStore**>(store.Out())))) ||
                    !SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_SYSTEM_MODE,
                        static_cast<LONG>(SINGLE_CHANNEL_AEC)) ||
                    !SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_DMO_SOURCE_MODE, false) ||
                    !SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATURE_MODE, true))
                {
                    _Error = "The echo canceller refused its settings";
                    return false;
                }
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_ECHO_LENGTH,
                    LONG(_Options.m_iEchoLengthMs));
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_NS,
                    LONG(_Options.m_bNoiseSuppression ? 1 : 0));
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_AGC, false);
                SetProperty(store.m_pPointer, MFPKEY_WMAAECMA_FEATR_AES,
                    LONG((std::max)(0, (std::min)(2, _Options.m_iSuppression))));
                SetProperty(
                    store.m_pPointer, MFPKEY_WMAAECMA_FEATR_CENTER_CLIP, _Options.m_bCenterClip);
                for (const auto& [bInput, iStream, szWhat] :
                    {std::tuple{true, DWORD(0), "microphone"},
                        std::tuple{true, DWORD(1), "speaker"},
                        std::tuple{false, DWORD(0), "output"}})
                {
                    hr = SetMonoType(m_Dsp.m_pPointer, bInput, iStream);
                    if (FAILED(hr))
                    {
                        _Error = Failed(
                            (std::string("Setting the echo canceller's ") + szWhat + " format")
                                .c_str(),
                            hr);
                        return false;
                    }
                }
                hr = m_Dsp->AllocateStreamingResources();
                if (FAILED(hr))
                {
                    _Error = Failed("Starting the echo canceller", hr);
                    return false;
                }
                m_bStarted = true;
                m_pOut = new MediaBuffer(16000 * 2);
                return true;
            }

            // One frame of each in (stamped in 100 ns units), all the
            // output it has appended to `_Out`.
            bool Process(const int16_t* _pMic, const int16_t* _pReference,
                std::vector<int16_t>& _Out, std::string& _Error)
            {
                constexpr REFERENCE_TIME kFrameTime = 100000;
                for (DWORD istream = 0; istream < 2; ++istream)
                {
                    auto* pin = new MediaBuffer(kFrame * 2);
                    BYTE* pdata = nullptr;
                    pin->GetBufferAndLength(&pdata, nullptr);
                    std::memcpy(pdata, istream == 0 ? _pMic : _pReference, kFrame * 2);
                    pin->SetLength(kFrame * 2);
                    const HRESULT hr = m_Dsp->ProcessInput(istream, pin,
                        DMO_INPUT_DATA_BUFFERF_TIME | DMO_INPUT_DATA_BUFFERF_TIMELENGTH, m_rtNext,
                        kFrameTime);
                    pin->Release();
                    if (FAILED(hr))
                    {
                        _Error = Failed("The echo canceller's input", hr);
                        return false;
                    }
                }
                m_rtNext += kFrameTime;
                DWORD dwflags = DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE;
                while (dwflags & DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE)
                {
                    m_pOut->SetLength(0);
                    DMO_OUTPUT_DATA_BUFFER output = {};
                    output.pBuffer = m_pOut;
                    DWORD dwstatus = 0;
                    const HRESULT hr = m_Dsp->ProcessOutput(0, 1, &output, &dwstatus);
                    if (FAILED(hr))
                    {
                        _Error = Failed("The echo canceller", hr);
                        return false;
                    }
                    BYTE* pdata = nullptr;
                    DWORD dwlength = 0;
                    m_pOut->GetBufferAndLength(&pdata, &dwlength);
                    const auto* psamples = reinterpret_cast<const int16_t*>(pdata);
                    _Out.insert(_Out.end(), psamples, psamples + dwlength / 2);
                    dwflags = output.dwStatus;
                    if (hr == S_FALSE || dwlength == 0)
                    {
                        break;
                    }
                }
                return true;
            }

          private:
            ComRef<IMediaObject> m_Dsp;
            MediaBuffer* m_pOut = nullptr;
            bool m_bStarted = false;
            REFERENCE_TIME m_rtNext = 0;
        };

        // A capture stream read by polling, 16 kHz mono, each packet stamped
        // with the system clock: a microphone, or a speaker's loopback (what
        // it plays, everyone's sound, as it plays it).
        class TimedStream
        {
          public:
            TimedStream() = default;
            TimedStream(const TimedStream&) = delete;
            TimedStream& operator=(const TimedStream&) = delete;

            ~TimedStream()
            {
                if (m_bStarted)
                {
                    m_Client->Stop();
                }
            }

            bool Start(IMMDevice* _pDevice, bool _bLoopback, std::string& _Error)
            {
                const char* szwhat = _bLoopback ? "the speaker's loopback" : "the microphone";
                HRESULT hr =
                    _pDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, m_Client.Out());
                if (SUCCEEDED(hr))
                {
                    const WAVEFORMATEX format = MonoFormat(16000);
                    const DWORD dwflags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                          AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY |
                                          (_bLoopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0);
                    // A second of buffer (in 100 ns units): it's read every few ms.
                    hr = m_Client->Initialize(
                        AUDCLNT_SHAREMODE_SHARED, dwflags, 10000000, 0, &format, nullptr);
                }
                if (SUCCEEDED(hr) && !_bLoopback)
                {
                    NoDuckingFromStream(m_Client.m_pPointer);
                }
                if (SUCCEEDED(hr))
                {
                    hr = m_Client->GetService(__uuidof(IAudioCaptureClient), m_Capture.Out());
                }
                if (SUCCEEDED(hr))
                {
                    hr = m_Client->Start();
                }
                if (FAILED(hr))
                {
                    _Error = Failed((std::string("Opening ") + szwhat).c_str(), hr);
                    return false;
                }
                m_bStarted = true;
                return true;
            }

            // Everything it has into `_Timeline`. False when it failed.
            bool Drain(EchoTimeline& _Timeline)
            {
                UINT32 upacket = 0;
                HRESULT hr = S_OK;
                while (SUCCEEDED(hr = m_Capture->GetNextPacketSize(&upacket)) && upacket > 0)
                {
                    BYTE* pdata = nullptr;
                    UINT32 uframes = 0;
                    DWORD dwflags = 0;
                    UINT64 uposition = 0;
                    UINT64 utime = 0;
                    hr = m_Capture->GetBuffer(&pdata, &uframes, &dwflags, &uposition, &utime);
                    if (FAILED(hr))
                    {
                        return false;
                    }
                    const int64_t itime = (dwflags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)
                                              ? -1
                                              : static_cast<int64_t>(utime);
                    if (dwflags & AUDCLNT_BUFFERFLAGS_SILENT)
                    {
                        m_Silence.assign(uframes, 0);
                        _Timeline.Push(m_Silence.data(), uframes, itime);
                    }
                    else
                    {
                        _Timeline.Push(reinterpret_cast<const int16_t*>(pdata), uframes, itime);
                    }
                    m_Capture->ReleaseBuffer(uframes);
                }
                return SUCCEEDED(hr);
            }

          private:
            ComRef<IAudioClient> m_Client;
            ComRef<IAudioCaptureClient> m_Capture;
            bool m_bStarted = false;
            std::vector<int16_t> m_Silence;
        };

        // The echo canceller lined up by voice itself, for a speaker whose
        // sound reaches the microphone later than the system knows
        // (EchoOptions::m_iDelayMs): the microphone and a loopback of the
        // speaker, both stamped with the system clock, and the DSP in filter
        // mode given each 10 ms of the microphone with the speaker's sound
        // from that much earlier (less kMarginMs, so it comes just before its
        // echo), center clipping on (lined up, it measured best that way).
        class AlignedEchoCapture final : public IAudioCapture
        {
          public:
            ~AlignedEchoCapture() override
            {
                Stop();
            }

            bool Start(int _iSampleRate, OnSamples _OnSamples, std::string& _Error) override
            {
                if (_iSampleRate != 16000)
                {
                    _Error = "Echo cancellation gives 16 kHz only";
                    return false;
                }
                m_OnSamples = std::move(_OnSamples);
                {
                    std::lock_guard<std::mutex> lock(m_ErrorMutex);
                    m_Error.clear();
                }
                return m_Thread.Start([this](const auto& _Ready) { Loop(_Ready); }, _Error);
            }

            void Stop() override
            {
                m_Thread.Stop();
            }

            std::string Description() const override
            {
                return "Microphone (echo cancelled, lined up)";
            }

            std::string LastError() const override
            {
                std::lock_guard<std::mutex> lock(m_ErrorMutex);
                return m_Error;
            }

            std::string Route() const override
            {
                std::lock_guard<std::mutex> lock(m_ErrorMutex);
                return m_Route;
            }

          private:
            static constexpr int kMarginMs = 20;
            // The speaker's place follows the clocks only past this many
            // samples off (their stamps jitter by a fraction of a
            // millisecond), a sample per frame: a reference that jumps
            // every frame spoils the canceller's filter.
            static constexpr int64_t kDriftSamples = 16;
            // The speaker's sound waited for at most this long (100 ns
            // units) before a frame goes without it.
            static constexpr int64_t kWait = 2000000;

            void Fail(const std::string& _Error)
            {
                std::lock_guard<std::mutex> lock(m_ErrorMutex);
                m_Error = _Error;
            }

            void Loop(const std::function<void(bool, const std::string&)>& _Ready)
            {
                ComScope com;
                const EchoOptions options = CurrentEchoOptions();
                EchoDevices devices;
                std::string error;
                if (!FindEchoDevices(devices, error))
                {
                    _Ready(false, error);
                    return;
                }
                DuckingOptOut ducking;
                const std::string optOut = ducking.Apply(devices.m_Speaker.m_pPointer);
                // The loopback gives nothing while the speaker is idle.
                SilentStream keepAlive;
                const std::string kept = keepAlive.Start(devices.m_Speaker.m_pPointer, true);
                TimedStream mic;
                TimedStream speaker;
                EchoOptions lined = options;
                lined.m_bCenterClip = true;
                FilterDsp dsp;
                if (!mic.Start(devices.m_Mic.m_pPointer, false, error) ||
                    !speaker.Start(devices.m_Speaker.m_pPointer, true, error) ||
                    !dsp.Open(lined, error))
                {
                    _Ready(false, error);
                    return;
                }
                {
                    std::lock_guard<std::mutex> lock(m_ErrorMutex);
                    m_Route =
                        "echo canceller lined up, " + std::to_string(options.m_iDelayMs) +
                        " ms; mic: " +
                        EndpointName(devices.m_Mic.m_pPointer, devices.m_bMicDefault) +
                        "; echo reference: loopback of " +
                        EndpointName(devices.m_Speaker.m_pPointer, devices.m_bSpeakerDefault) +
                        "; kept running: " + (kept == "ok" ? "yes" : kept) +
                        "; ducking opt-out: " + optOut;
                }
                _Ready(true, {});

                DWORD dwtask = 0;
                HANDLE htask = AvSetMmThreadCharacteristicsW(L"Audio", &dwtask);
                const int64_t ishift = static_cast<int64_t>(options.m_iDelayMs - kMarginMs) * 10000;
                EchoTimeline micLine;
                EchoTimeline speakerLine;
                int64_t icursor = -1; // the next microphone sample to cancel
                int64_t ispeaker = -1; // the speaker sample that goes with it
                // Troubleshooting: GITGUD_ECHO_DEBUG names a folder for what
                // the canceller got (mic.raw, speaker.raw: 16 kHz s16le).
                const char* szdebug = std::getenv("GITGUD_ECHO_DEBUG");
                std::FILE* pdebugMic = nullptr;
                std::FILE* pdebugSpeaker = nullptr;
                if (szdebug && *szdebug)
                {
                    pdebugMic = std::fopen((std::string(szdebug) + "/mic.raw").c_str(), "wb");
                    pdebugSpeaker =
                        std::fopen((std::string(szdebug) + "/speaker.raw").c_str(), "wb");
                }
                std::vector<int16_t> micFrame;
                std::vector<int16_t> speakerFrame;
                std::vector<int16_t> out;
                while (m_Thread.Running())
                {
                    keepAlive.TopUp();
                    if (!mic.Drain(micLine) || !speaker.Drain(speakerLine))
                    {
                        Fail("The microphone or the speaker's loopback stopped");
                        break;
                    }
                    if (icursor < 0 && micLine.Stamped())
                    {
                        icursor = micLine.Begin();
                    }
                    while (icursor >= 0 &&
                           micLine.End() - icursor >= static_cast<int64_t>(FilterDsp::kFrame))
                    {
                        const int64_t iwant = micLine.TimeOf(icursor) - ishift;
                        const int64_t itarget = speakerLine.IndexAt(iwant);
                        if (ispeaker < 0 || std::llabs(itarget - ispeaker) > 4 * kDriftSamples)
                        {
                            ispeaker = itarget; // the first frame, or far off: line up
                        }
                        else if (itarget - ispeaker > kDriftSamples)
                        {
                            ++ispeaker;
                        }
                        else if (ispeaker - itarget > kDriftSamples)
                        {
                            --ispeaker;
                        }
                        const int64_t ifrom = ispeaker;
                        const bool bhave =
                            speakerLine.Stamped() &&
                            speakerLine.End() >= ifrom + static_cast<int64_t>(FilterDsp::kFrame);
                        // Its sound not in yet (a delay shorter than the
                        // loopback's own): wait for it, a little.
                        if (!bhave &&
                            micLine.TimeOf(micLine.End()) - micLine.TimeOf(icursor) < kWait)
                        {
                            break;
                        }
                        micLine.Copy(icursor, FilterDsp::kFrame, micFrame);
                        speakerLine.Copy(ifrom, FilterDsp::kFrame, speakerFrame);
                        if (pdebugMic && pdebugSpeaker)
                        {
                            std::fwrite(micFrame.data(), 2, micFrame.size(), pdebugMic);
                            std::fwrite(speakerFrame.data(), 2, speakerFrame.size(), pdebugSpeaker);
                        }
                        out.clear();
                        if (!dsp.Process(micFrame.data(), speakerFrame.data(), out, error))
                        {
                            Fail(error);
                            icursor = -2;
                            break;
                        }
                        if (!out.empty())
                        {
                            m_OnSamples(out.data(), out.size());
                        }
                        icursor += static_cast<int64_t>(FilterDsp::kFrame);
                        ispeaker += static_cast<int64_t>(FilterDsp::kFrame);
                        micLine.TrimBefore(icursor);
                        // A second of the speaker kept behind what's wanted.
                        speakerLine.TrimBefore(ifrom - 16000);
                    }
                    if (icursor == -2)
                    {
                        break;
                    }
                    Sleep(5);
                }
                if (htask)
                {
                    AvRevertMmThreadCharacteristics(htask);
                }
                for (std::FILE* pfile : {pdebugMic, pdebugSpeaker})
                {
                    if (pfile)
                    {
                        std::fclose(pfile);
                    }
                }
            }

            OnSamples m_OnSamples;
            DeviceThread m_Thread;
            mutable std::mutex m_ErrorMutex; // guards m_Error and m_Route
            std::string m_Error;
            std::string m_Route;
        };

    } // namespace

    bool CancelEcho(const std::vector<int16_t>& _Mic, const std::vector<int16_t>& _Reference,
        const EchoOptions& _Options, std::vector<int16_t>& _Out, std::string& _Error)
    {
        ComScope com;
        _Out.clear();
        FilterDsp dsp;
        if (!dsp.Open(_Options, _Error))
        {
            return false;
        }
        const std::size_t ncount = (std::min)(_Mic.size(), _Reference.size());
        for (std::size_t nat = 0; nat + FilterDsp::kFrame <= ncount; nat += FilterDsp::kFrame)
        {
            if (!dsp.Process(_Mic.data() + nat, _Reference.data() + nat, _Out, _Error))
            {
                return false;
            }
        }
        return true;
    }

    namespace
    {

        // ---- playback -------------------------------------------------------

        class WasapiPlayback final : public IAudioPlayback
        {
          public:
            ~WasapiPlayback() override
            {
                Stop();
            }

            bool Start(int _iSampleRate, std::string& _Error) override
            {
                m_iRate = _iSampleRate;
                return m_Thread.Start([this](const auto& _Ready) { Loop(_Ready); }, _Error);
            }

            void Stop() override
            {
                m_Thread.Stop();
                Flush();
            }

            int SampleRate() const override
            {
                return m_iRate;
            }

            void Enqueue(const int16_t* _pSamples, std::size_t _nCount) override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Queue.insert(m_Queue.end(), _pSamples, _pSamples + _nCount);
            }

            void Flush() override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Queue.clear();
            }

            std::size_t Queued() const override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                return m_Queue.size();
            }

            std::string Description() const override
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                return m_Name;
            }

          private:
            std::string m_Name;

            void Loop(const std::function<void(bool, const std::string&)>& _Ready)
            {
                ComScope com;
                HANDLE hevent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
                ComRef<IAudioClient> client;
                ComRef<IAudioRenderClient> render;
                UINT32 ubufferFrames = 0;
                // The speaker the echo canceller takes as its reference
                // (ResolveEndpoint, both), so what it subtracts is this.
                DuckingOptOut ducking;
                std::string name;
                std::string optOut;
                std::string error;
                if (!OpenClient(eRender, m_iRate, hevent, client, ducking, name, optOut, error) ||
                    FAILED(client->GetBufferSize(&ubufferFrames)) ||
                    FAILED(client->GetService(__uuidof(IAudioRenderClient), render.Out())))
                {
                    CloseHandle(hevent);
                    _Ready(false, error.empty() ? "The speaker could not start" : error);
                    return;
                }
                BYTE* pdata = nullptr;
                if (SUCCEEDED(render->GetBuffer(ubufferFrames, &pdata)))
                {
                    render->ReleaseBuffer(ubufferFrames, AUDCLNT_BUFFERFLAGS_SILENT);
                }
                if (FAILED(client->Start()))
                {
                    CloseHandle(hevent);
                    _Ready(false, "The speaker could not start");
                    return;
                }
                {
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_Name = name + (optOut.empty() ? std::string() : " (" + optOut + ")");
                }
                _Ready(true, {});
                DWORD dwtask = 0;
                HANDLE htask = AvSetMmThreadCharacteristicsW(L"Audio", &dwtask);
                while (m_Thread.Running())
                {
                    if (WaitForSingleObject(hevent, 200) != WAIT_OBJECT_0)
                    {
                        continue;
                    }
                    UINT32 upadding = 0;
                    if (FAILED(client->GetCurrentPadding(&upadding)))
                    {
                        continue;
                    }
                    const UINT32 uframes = ubufferFrames - upadding;
                    if (uframes == 0 || FAILED(render->GetBuffer(uframes, &pdata)))
                    {
                        continue;
                    }
                    auto* pout = reinterpret_cast<int16_t*>(pdata);
                    std::size_t nfilled = 0;
                    {
                        std::lock_guard<std::mutex> lock(m_Mutex);
                        while (nfilled < uframes && !m_Queue.empty())
                        {
                            pout[nfilled++] = m_Queue.front();
                            m_Queue.pop_front();
                        }
                    }
                    std::fill(pout + nfilled, pout + uframes, int16_t(0));
                    render->ReleaseBuffer(uframes, 0);
                }
                client->Stop();
                if (htask)
                {
                    AvRevertMmThreadCharacteristics(htask);
                }
                CloseHandle(hevent);
            }

            int m_iRate = 24000;
            mutable std::mutex m_Mutex;
            std::deque<int16_t> m_Queue;
            DeviceThread m_Thread;
        };

    } // namespace

    std::unique_ptr<IAudioCapture> MakeVoiceCapture()
    {
        std::vector<std::unique_ptr<IAudioCapture>> stages;
        if (CurrentEchoOptions().m_iDelayMs > 0)
        {
            stages.push_back(std::make_unique<AlignedEchoCapture>());
        }
        stages.push_back(std::make_unique<EchoCancelledCapture>(EchoSetup::kByIndex));
        stages.push_back(std::make_unique<EchoCancelledCapture>(EchoSetup::kByIndexNoOptOut));
        stages.push_back(std::make_unique<EchoCancelledCapture>(EchoSetup::kSystemDefaults));
        stages.push_back(std::make_unique<WasapiCapture>());
        return MakeFallbackCapture(std::move(stages), std::chrono::milliseconds(2000));
    }

    std::unique_ptr<IAudioPlayback> MakePlayback()
    {
        return std::make_unique<WasapiPlayback>();
    }

    namespace
    {

        // 20 ms frames' levels (dBFS) of `_Samples` from `_nFrom`.
        std::vector<double> FrameLevels(const std::vector<int16_t>& _Samples, std::size_t _nFrom)
        {
            constexpr std::size_t kFrame = 320;
            std::vector<double> levels;
            for (std::size_t nat = _nFrom; nat + kFrame <= _Samples.size(); nat += kFrame)
            {
                double fsum = 0;
                for (std::size_t ni = nat; ni < nat + kFrame; ++ni)
                {
                    const double fsample = _Samples[ni] / 32768.0;
                    fsum += fsample * fsample;
                }
                levels.push_back(10 * std::log10(fsum / kFrame + 1e-12));
            }
            return levels;
        }

    } // namespace

    EchoMeasurement MeasureEcho(const std::vector<int16_t>& _Signal)
    {
        EchoMeasurement result;
        ComScope com;
        EchoDevices devices;
        std::string error;
        if (!FindEchoDevices(devices, error))
        {
            result.m_Error = error;
            return result;
        }
        SilentStream keepAlive;
        keepAlive.Start(devices.m_Speaker.m_pPointer, true);
        TimedStream mic;
        TimedStream speaker;
        WasapiPlayback playback;
        if (!mic.Start(devices.m_Mic.m_pPointer, false, error) ||
            !speaker.Start(devices.m_Speaker.m_pPointer, true, error) ||
            !playback.Start(16000, error))
        {
            result.m_Error = error;
            return result;
        }
        result.m_Route =
            "mic: " + EndpointName(devices.m_Mic.m_pPointer, devices.m_bMicDefault) +
            "; speaker: " + EndpointName(devices.m_Speaker.m_pPointer, devices.m_bSpeakerDefault);

        EchoTimeline micLine;
        EchoTimeline speakerLine;
        const auto listen = [&](std::chrono::milliseconds _For, const std::function<bool()>& _Until)
        {
            const auto deadline = std::chrono::steady_clock::now() + _For;
            while (std::chrono::steady_clock::now() < deadline && !(_Until && _Until()))
            {
                keepAlive.TopUp();
                if (!mic.Drain(micLine) || !speaker.Drain(speakerLine))
                {
                    return false;
                }
                Sleep(5);
            }
            return true;
        };
        // The room first, then the chirps, then a second for their echo.
        const std::vector<int16_t> signal = _Signal.empty() ? EchoTestSignal(16000) : _Signal;
        bool bok = listen(std::chrono::milliseconds(400), nullptr);
        playback.Enqueue(signal.data(), signal.size());
        bok = bok && listen(std::chrono::milliseconds(signal.size() / 16 + 3000),
                         [&]() { return playback.Queued() == 0; });
        bok = bok && listen(std::chrono::milliseconds(1200), nullptr);
        playback.Stop();
        if (!bok || !micLine.Stamped() || !speakerLine.Stamped())
        {
            result.m_Error = "the microphone or the speaker's loopback gave nothing";
            return result;
        }

        // Both on one clock: the speaker's recording, and the microphone from
        // the same moment with a second more for the delay.
        std::vector<int16_t> heard;
        speakerLine.Copy(speakerLine.Begin(),
            static_cast<std::size_t>(speakerLine.End() - speakerLine.Begin()), heard);
        const int64_t imicFrom = micLine.IndexAt(speakerLine.TimeOf(speakerLine.Begin()));
        std::vector<int16_t> recorded;
        micLine.Copy(imicFrom, heard.size() + 16000, recorded);
        const int ilag = EchoLag(heard, recorded, 16000, &result.m_fCorrelation);
        result.m_fDelayMs = ilag / 16.0;
        // The two recordings on the clock, for the log.
        char aClocks[160];
        std::snprintf(aClocks, sizeof(aClocks),
            "; recorded: mic %lld samples from %lld, speaker %lld from %lld (100 ns), mic offset "
            "%lld",
            static_cast<long long>(micLine.End() - micLine.Begin()),
            static_cast<long long>(micLine.TimeOf(micLine.Begin())),
            static_cast<long long>(speakerLine.End() - speakerLine.Begin()),
            static_cast<long long>(speakerLine.TimeOf(speakerLine.Begin())),
            static_cast<long long>(imicFrom - micLine.Begin()));
        result.m_Route += aClocks;

        // The room: the microphone before the speaker's first loud frame.
        // The echo: the microphone, lag later, where the speaker was loud.
        const std::vector<double> played = FrameLevels(heard, 0);
        const std::vector<double> mics = FrameLevels(recorded, static_cast<std::size_t>(ilag));
        std::vector<double> quiet;
        double fecho = 0;
        std::size_t nloud = 0;
        bool bstarted = false;
        for (std::size_t ni = 0; ni < played.size() && ni < mics.size(); ++ni)
        {
            if (played[ni] > -45)
            {
                bstarted = true;
                fecho += std::pow(10.0, mics[ni] / 10);
                ++nloud;
            }
            else if (!bstarted)
            {
                quiet.push_back(mics[ni]);
            }
        }
        if (nloud == 0)
        {
            result.m_Error = "the chirps didn't play on the speaker";
            return result;
        }
        result.m_fEchoDb = 10 * std::log10(fecho / static_cast<double>(nloud) + 1e-12);
        if (!quiet.empty())
        {
            std::nth_element(quiet.begin(), quiet.begin() + quiet.size() / 2, quiet.end());
            result.m_fFloorDb = quiet[quiet.size() / 2];
        }
        else
        {
            result.m_fFloorDb = -120;
        }
        result.m_bHeard =
            result.m_fCorrelation >= 0.2 && result.m_fEchoDb - result.m_fFloorDb >= 10;
        result.m_bOk = true;
        return result;
    }

    std::unique_ptr<IAudioCapture> MakePlainCapture()
    {
        return std::make_unique<WasapiCapture>();
    }

    std::vector<AudioDevice> ListAudioDevices(bool _bCapture)
    {
        ComScope com; // a thread that already has an apartment keeps it
        std::vector<AudioDevice> out;
        const EDataFlow eflow = _bCapture ? eCapture : eRender;
        ComRef<IMMDeviceEnumerator> enumerator;
        std::string error;
        if (!MakeEnumerator(enumerator, error))
        {
            return out;
        }
        const std::string defaultId = DefaultId(enumerator.m_pPointer, eflow);
        ComRef<IMMDeviceCollection> devices;
        UINT ucount = 0;
        if (FAILED(enumerator->EnumAudioEndpoints(eflow, DEVICE_STATE_ACTIVE,
                reinterpret_cast<IMMDeviceCollection**>(devices.Out()))) ||
            FAILED(devices->GetCount(&ucount)))
        {
            return out;
        }
        for (UINT i = 0; i < ucount; ++i)
        {
            ComRef<IMMDevice> device;
            if (FAILED(devices->Item(i, reinterpret_cast<IMMDevice**>(device.Out()))))
            {
                continue;
            }
            AudioDevice entry;
            entry.m_Id = DeviceId(device.m_pPointer);
            ComRef<IPropertyStore> store;
            if (SUCCEEDED(device->OpenPropertyStore(
                    STGM_READ, reinterpret_cast<IPropertyStore**>(store.Out()))))
            {
                PROPVARIANT name;
                PropVariantInit(&name);
                if (SUCCEEDED(store->GetValue(kFriendlyName, &name)) &&
                    name.vt == VT_LPWSTR)
                {
                    entry.m_Name = Utf8(name.pwszVal);
                }
                PropVariantClear(&name);
            }
            if (entry.m_Name.empty())
            {
                entry.m_Name = _bCapture ? "Microphone" : "Speaker";
            }
            entry.m_bDefault = entry.m_Id == defaultId;
            out.push_back(std::move(entry));
        }
        return out;
    }

#else

    bool CancelEcho(const std::vector<int16_t>&, const std::vector<int16_t>&, const EchoOptions&,
        std::vector<int16_t>& _Out, std::string& _Error)
    {
        _Out.clear();
        _Error = "Echo cancellation is Windows only";
        return false;
    }

    EchoMeasurement MeasureEcho(const std::vector<int16_t>&)
    {
        EchoMeasurement result;
        result.m_Error = "The echo test is Windows only";
        return result;
    }

    namespace
    {

        class NoCapture final : public IAudioCapture
        {
          public:
            bool Start(int, OnSamples, std::string& _Error) override
            {
                _Error = "Audio capture is not implemented on this platform yet";
                return false;
            }

            void Stop() override
            {
            }

            std::string Description() const override
            {
                return "No microphone";
            }
        };

        class NoPlayback final : public IAudioPlayback
        {
          public:
            bool Start(int, std::string& _Error) override
            {
                _Error = "Audio playback is not implemented on this platform yet";
                return false;
            }

            void Stop() override
            {
            }

            int SampleRate() const override
            {
                return 0;
            }

            void Enqueue(const int16_t*, std::size_t) override
            {
            }

            void Flush() override
            {
            }

            std::size_t Queued() const override
            {
                return 0;
            }
        };

    } // namespace

    std::unique_ptr<IAudioCapture> MakeVoiceCapture()
    {
        return std::make_unique<NoCapture>();
    }

    std::unique_ptr<IAudioPlayback> MakePlayback()
    {
        return std::make_unique<NoPlayback>();
    }

    std::unique_ptr<IAudioCapture> MakePlainCapture()
    {
        return std::make_unique<NoCapture>();
    }

    std::vector<AudioDevice> ListAudioDevices(bool)
    {
        return {};
    }

#endif

} // namespace gitgud::platform
