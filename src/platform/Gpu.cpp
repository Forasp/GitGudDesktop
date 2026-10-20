#include "platform/Gpu.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {

        // NVML's C API, the parts used here (nvml.h, stable since CUDA 10).
        using NvmlDevice = void*;

        struct NvmlMemory
        {
            unsigned long long m_uTotal;
            unsigned long long m_uFree;
            unsigned long long m_uUsed;
        };

        using InitFn = int (*)();
        using ShutdownFn = int (*)();
        using DriverVersionFn = int (*)(char*, unsigned int);
        using CudaVersionFn = int (*)(int*);
        using CountFn = int (*)(unsigned int*);
        using HandleFn = int (*)(unsigned int, NvmlDevice*);
        using NameFn = int (*)(NvmlDevice, char*, unsigned int);
        using MemoryFn = int (*)(NvmlDevice, NvmlMemory*);

        void Query(HMODULE _hNvml, NvidiaInfo& _Info)
        {
            auto proc = [_hNvml](const char* _szName)
            {
                return GetProcAddress(_hNvml, _szName);
            };
            const auto init = reinterpret_cast<InitFn>(proc("nvmlInit_v2"));
            const auto shutdown = reinterpret_cast<ShutdownFn>(proc("nvmlShutdown"));
            const auto driver =
                reinterpret_cast<DriverVersionFn>(proc("nvmlSystemGetDriverVersion"));
            auto cuda = reinterpret_cast<CudaVersionFn>(proc("nvmlSystemGetCudaDriverVersion_v2"));
            if (!cuda)
            {
                cuda = reinterpret_cast<CudaVersionFn>(proc("nvmlSystemGetCudaDriverVersion"));
            }
            const auto count = reinterpret_cast<CountFn>(proc("nvmlDeviceGetCount_v2"));
            const auto handle = reinterpret_cast<HandleFn>(proc("nvmlDeviceGetHandleByIndex_v2"));
            const auto name = reinterpret_cast<NameFn>(proc("nvmlDeviceGetName"));
            const auto memory = reinterpret_cast<MemoryFn>(proc("nvmlDeviceGetMemoryInfo"));
            if (!init || !shutdown || !driver || !cuda || !count || !handle || !name || !memory)
            {
                _Info.m_Error = "the NVIDIA driver's management library is too old";
                return;
            }
            if (init() != 0)
            {
                _Info.m_Error = "the NVIDIA driver didn't answer";
                return;
            }
            char abuf[96] = {};
            if (driver(abuf, sizeof(abuf)) == 0)
            {
                _Info.m_Driver = abuf;
            }
            int icuda = 0;
            if (cuda(&icuda) == 0)
            {
                _Info.m_iCudaVersion = icuda;
            }
            unsigned int udevices = 0;
            if (count(&udevices) == 0)
            {
                for (unsigned int ui = 0; ui < udevices && ui < 16; ++ui)
                {
                    NvmlDevice device = nullptr;
                    if (handle(ui, &device) != 0)
                    {
                        continue;
                    }
                    GpuDevice info;
                    char aname[96] = {};
                    if (name(device, aname, sizeof(aname)) == 0)
                    {
                        info.m_Name = aname;
                    }
                    NvmlMemory mem = {};
                    if (memory(device, &mem) == 0)
                    {
                        info.m_uMemoryBytes = mem.m_uTotal;
                    }
                    _Info.m_Devices.push_back(info);
                }
            }
            _Info.m_bPresent = true;
            shutdown();
        }

        // A driver library that faults must not take the app with it.
        bool QueryShielded(HMODULE _hNvml, NvidiaInfo* _pInfo)
        {
            __try
            {
                Query(_hNvml, *_pInfo);
                return true;
            }
            __except (EXCEPTION_EXECUTE_HANDLER)
            {
                return false;
            }
        }

    } // namespace

    NvidiaInfo QueryNvidia()
    {
        NvidiaInfo info;
        // System32 only: the driver's own copy.
        HMODULE hnvml = LoadLibraryExW(L"nvml.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!hnvml)
        {
            info.m_Error = "no NVIDIA driver";
            return info;
        }
        if (!QueryShielded(hnvml, &info))
        {
            info = NvidiaInfo{};
            info.m_Error = "the NVIDIA driver's management library failed";
        }
        FreeLibrary(hnvml);
        return info;
    }

#else

    NvidiaInfo QueryNvidia()
    {
        NvidiaInfo info;
        info.m_Error = "not checked on this platform";
        return info;
    }

#endif

} // namespace gitgud::platform
