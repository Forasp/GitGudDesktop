#pragma once

// -----------------------------------------------------------------------------
// Gpu: what NVIDIA GPU the computer has, for the Bragi interface's voice
// pack. Asks the driver's own management library (nvml.dll, which comes with
// NVIDIA's display driver, from System32) and unloads it again; nothing is
// installed or changed. No NVIDIA driver: `m_bPresent` false.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <string>
#include <vector>

namespace gitgud::platform
{

    struct GpuDevice
    {
        std::string m_Name;
        uint64_t m_uMemoryBytes = 0;
    };

    struct NvidiaInfo
    {
        bool m_bPresent = false; // the driver answered
        std::string m_Driver;    // "610.88"
        int m_iCudaVersion = 0;  // the newest CUDA the driver runs, 13030 for 13.3
        std::vector<GpuDevice> m_Devices;
        std::string m_Error; // why not, when it couldn't tell
    };

    NvidiaInfo QueryNvidia();

} // namespace gitgud::platform
