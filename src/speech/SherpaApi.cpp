#include "speech/SherpaApi.h"

#include "onnxruntime_c_api.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <vector>

namespace gitgud::speech
{

    namespace fs = std::filesystem;

    namespace
    {

        SherpaApi g_Api;
        std::once_flag g_Once;
        bool g_bLoaded = false;
        std::string g_LoadError;
        std::string g_LoadedDir;
        const OrtApiBase* g_pApiBase = nullptr;

        std::mutex g_CudaMutex;
        bool g_bCuda = false;
        OrtEnv* g_pCudaEnv = nullptr; // kept for the process: the provider lives in it
        const OrtEpDevice* g_pCudaDevice = nullptr;

        constexpr const wchar_t* kOrtDll = L"onnxruntime.dll";
        constexpr const wchar_t* kSherpaDll = L"sherpa-onnx-c-api.dll";
        constexpr const wchar_t* kCudaProvider = L"onnxruntime_providers_cuda.dll";
        constexpr const wchar_t* kSharedProvider = L"onnxruntime_providers_shared.dll";

#if defined(_WIN32)
        using GetApiBaseFn = const OrtApiBase*(ORT_API_CALL*)();

        std::string Narrow(const std::wstring& _Wide)
        {
            return fs::path(_Wide).u8string();
        }

        // A damaged library makes Windows show a dialog ("Bad Image") that
        // waits for a click: while this lives, the load fails with an error
        // instead.
        class QuietLoader
        {
        public:
            QuietLoader()
            {
                SetThreadErrorMode(SEM_FAILCRITICALERRORS, &m_dwOld);
            }
            ~QuietLoader()
            {
                SetThreadErrorMode(m_dwOld, nullptr);
            }
            QuietLoader(const QuietLoader&) = delete;
            QuietLoader& operator=(const QuietLoader&) = delete;

        private:
            DWORD m_dwOld = 0;
        };

        // Whether a file is a Windows library at all (its "MZ" header): one
        // that isn't is never given to the loader.
        bool IsLibrary(const fs::path& _Path)
        {
            std::ifstream in(_Path, std::ios::binary);
            char amagic[2] = {};
            return in.read(amagic, 2) && amagic[0] == 'M' && amagic[1] == 'Z';
        }

        void Load(const std::string& _Dir)
        {
            QuietLoader quiet;
            const fs::path dir = fs::u8path(_Dir);
            const fs::path ort = dir / kOrtDll;
            const fs::path sherpa = dir / kSherpaDll;
            std::error_code ec;
            if (!fs::is_regular_file(ort, ec) || !fs::is_regular_file(sherpa, ec))
            {
                g_LoadError = "the speech engine's files aren't in " + _Dir;
                return;
            }
            // Another onnxruntime.dll already in the process (a system
            // component loaded it) would be the one sherpa-onnx binds to.
            if (HMODULE hother = GetModuleHandleW(kOrtDll))
            {
                wchar_t apath[MAX_PATH] = {};
                GetModuleFileNameW(hother, apath, MAX_PATH);
                if (!fs::equivalent(fs::path(apath), ort, ec))
                {
                    g_LoadError = "another ONNX Runtime is already loaded: " + Narrow(apath);
                    return;
                }
            }
            const DWORD flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32;
            HMODULE hort = LoadLibraryExW(ort.c_str(), nullptr, flags);
            if (!hort)
            {
                g_LoadError = "could not load " + ort.u8string() + " (error " +
                              std::to_string(GetLastError()) + ")";
                return;
            }
            auto pbase = reinterpret_cast<GetApiBaseFn>(
                reinterpret_cast<void*>(GetProcAddress(hort, "OrtGetApiBase")));
            const OrtApiBase* papi = pbase ? pbase() : nullptr;
            const char* szversion =
                papi && papi->GetVersionString ? papi->GetVersionString() : nullptr;
            if (!szversion || std::string(szversion) != kOrtVersion)
            {
                g_LoadError = std::string("ONNX Runtime ") +
                              (szversion ? szversion : "of an unknown version") + " in " + _Dir +
                              "; the speech engine needs " + kOrtVersion;
                return;
            }
            HMODULE hsherpa = LoadLibraryExW(sherpa.c_str(), nullptr, flags);
            if (!hsherpa)
            {
                g_LoadError = "could not load " + sherpa.u8string() + " (error " +
                              std::to_string(GetLastError()) + ")";
                return;
            }
            SherpaApi api;
#define GITGUD_SHERPA_RESOLVE(name)                                                                \
    api.name = reinterpret_cast<decltype(api.name)>(                                               \
        reinterpret_cast<void*>(GetProcAddress(hsherpa, #name)));                                  \
    if (!api.name)                                                                                 \
    {                                                                                              \
        g_LoadError = "the speech engine has no " #name;                                           \
        return;                                                                                    \
    }
            GITGUD_SHERPA_FUNCS(GITGUD_SHERPA_RESOLVE)
#undef GITGUD_SHERPA_RESOLVE
            g_Api = api;
            g_pApiBase = papi;
            g_LoadedDir = _Dir;
            g_bLoaded = true;
        }
#else
        void Load(const std::string&)
        {
            g_LoadError = "the speech engine isn't available on this system yet";
        }
#endif

    } // namespace

    const SherpaApi& Sherpa()
    {
        return g_Api;
    }

    bool SherpaLoaded()
    {
        return g_bLoaded;
    }

    bool SherpaFilesPresent(const std::string& _Dir)
    {
        std::error_code ec;
        const fs::path dir = fs::u8path(_Dir);
        return fs::is_regular_file(dir / kOrtDll, ec) && fs::is_regular_file(dir / kSherpaDll, ec);
    }

    bool LoadSherpa(const std::string& _Dir, std::string& _Error)
    {
        std::call_once(g_Once, [&_Dir]() { Load(_Dir); });
        if (!g_bLoaded)
        {
            _Error = g_LoadError;
            return false;
        }
        std::error_code ec;
        if (!fs::equivalent(fs::u8path(_Dir), fs::u8path(g_LoadedDir), ec))
        {
            _Error = "the speech engine was loaded from " + g_LoadedDir +
                     "; restart GitGud to use " + _Dir;
            return false;
        }
        return true;
    }

#if defined(_WIN32)
    bool EnableCuda(const std::string& _GpuDir, std::string& _Error)
    {
        std::lock_guard<std::mutex> lock(g_CudaMutex);
        if (g_bCuda)
        {
            return true;
        }
        if (!g_bLoaded)
        {
            _Error = "the speech engine isn't loaded";
            return false;
        }
        const fs::path dir = fs::u8path(_GpuDir);
        const fs::path provider = dir / kCudaProvider;
        std::error_code ec;
        if (!fs::is_regular_file(provider, ec))
        {
            _Error = "the GPU libraries aren't in " + _GpuDir;
            return false;
        }
        const DWORD flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32;
        // The provider bridge beside onnxruntime.dll, then NVIDIA's libraries
        // by full path: the provider and cuDNN load them by name later, and a
        // library already loaded answers to its name. An older pack's own
        // ONNX Runtime and sherpa-onnx files in the folder are left alone.
        std::vector<fs::path> libraries{fs::u8path(g_LoadedDir) / kSharedProvider};
        for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec))
        {
            const std::wstring name = it->path().filename().wstring();
            if (it->path().extension() == L".dll" && name.rfind(L"onnxruntime", 0) != 0 &&
                name.rfind(L"sherpa", 0) != 0)
            {
                libraries.push_back(it->path());
            }
        }
        // A pack's file that isn't a library at all is never loaded (the
        // provider too, which ONNX Runtime loads below).
        std::vector<fs::path> checked = libraries;
        checked.push_back(provider);
        for (const fs::path& library : checked)
        {
            if (!IsLibrary(library))
            {
                _Error =
                    library.filename().u8string() + " isn't a library: the GPU pack is damaged";
                return false;
            }
        }
        QuietLoader quiet;
        for (const fs::path& library : libraries)
        {
            if (!LoadLibraryExW(library.c_str(), nullptr, flags))
            {
                _Error = "could not load " + library.filename().u8string() + " (error " +
                         std::to_string(GetLastError()) + "; is the NVIDIA driver new enough?)";
                return false;
            }
        }
        const OrtApi* api = g_pApiBase->GetApi(ORT_API_VERSION);
        if (!api)
        {
            _Error = "ONNX Runtime has no API version " + std::to_string(ORT_API_VERSION);
            return false;
        }
        auto take = [api](OrtStatus* _pStatus, std::string& _Message)
        {
            if (!_pStatus)
            {
                return true;
            }
            _Message = api->GetErrorMessage(_pStatus);
            api->ReleaseStatus(_pStatus);
            return false;
        };
        OrtEnv* penv = nullptr;
        if (!take(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gitgud", &penv), _Error))
        {
            return false;
        }
        if (!take(api->RegisterExecutionProviderLibrary(penv, "gitgud-cuda", provider.c_str()),
                _Error))
        {
            api->ReleaseEnv(penv);
            return false;
        }
        const OrtEpDevice* const* pdevices = nullptr;
        std::size_t ncount = 0;
        const OrtEpDevice* pcuda = nullptr;
        if (take(api->GetEpDevices(penv, &pdevices, &ncount), _Error))
        {
            for (std::size_t ni = 0; ni < ncount && !pcuda; ++ni)
            {
                const char* szname = api->EpDevice_EpName(pdevices[ni]);
                if (szname && std::string(szname) == "CUDAExecutionProvider")
                {
                    pcuda = pdevices[ni];
                }
            }
            if (!pcuda)
            {
                _Error = "the GPU libraries found no CUDA device";
            }
        }
        if (!pcuda)
        {
            std::string ignored;
            take(api->UnregisterExecutionProviderLibrary(penv, "gitgud-cuda"), ignored);
            api->ReleaseEnv(penv);
            return false;
        }
        g_pCudaEnv = penv;
        g_pCudaDevice = pcuda;
        g_bCuda = true;
        return true;
    }
#else
    bool EnableCuda(const std::string&, std::string& _Error)
    {
        _Error = "the GPU isn't supported on this system yet";
        return false;
    }
#endif

    bool SherpaOnGpu()
    {
        std::lock_guard<std::mutex> lock(g_CudaMutex);
        return g_bCuda;
    }

    const void* CudaEpDevice()
    {
        std::lock_guard<std::mutex> lock(g_CudaMutex);
        return g_pCudaDevice;
    }

    void* CudaEnv()
    {
        std::lock_guard<std::mutex> lock(g_CudaMutex);
        return g_pCudaEnv;
    }

    std::string SherpaDir()
    {
        return g_bLoaded ? g_LoadedDir : std::string();
    }

    const void* OrtApiTable(std::uint32_t _uVersion)
    {
        return g_bLoaded && g_pApiBase ? g_pApiBase->GetApi(_uVersion) : nullptr;
    }

    bool GpuRuntimePresent(const std::string& _Dir)
    {
        std::error_code ec;
        return !_Dir.empty() && fs::is_regular_file(fs::u8path(_Dir) / kCudaProvider, ec);
    }

} // namespace gitgud::speech
