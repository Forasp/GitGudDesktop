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

        constexpr const wchar_t* kOrtDll = L"onnxruntime.dll";
        constexpr const wchar_t* kSherpaDll = L"sherpa-onnx-c-api.dll";
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

    std::string SherpaDir()
    {
        return g_bLoaded ? g_LoadedDir : std::string();
    }

    const void* OrtApiTable(std::uint32_t _uVersion)
    {
        return g_bLoaded && g_pApiBase ? g_pApiBase->GetApi(_uVersion) : nullptr;
    }

} // namespace gitgud::speech
