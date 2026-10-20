#include "platform/WinSpawn.h"

#if defined(_WIN32)

#include <algorithm>
#include <vector>

namespace gitgud::platform
{

    bool SpawnWithStdHandles(wchar_t* _szCommandLine, DWORD _dwFlags, void* _pEnvironment,
        const wchar_t* _szWorkingDir, HANDLE _hStdin, HANDLE _hStdout, HANDLE _hStderr,
        PROCESS_INFORMATION& _Info)
    {
        // The list may not name a handle twice (stdout and stderr often share one).
        std::vector<HANDLE> handles;
        for (HANDLE h : {_hStdin, _hStdout, _hStderr})
        {
            if (h && h != INVALID_HANDLE_VALUE &&
                std::find(handles.begin(), handles.end(), h) == handles.end())
            {
                handles.push_back(h);
            }
        }

        STARTUPINFOEXW si = {};
        si.StartupInfo.cb = sizeof(si);
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = _hStdin;
        si.StartupInfo.hStdOutput = _hStdout;
        si.StartupInfo.hStdError = _hStderr;

        std::vector<unsigned char> attributes;
        if (!handles.empty())
        {
            SIZE_T nsize = 0;
            InitializeProcThreadAttributeList(nullptr, 1, 0, &nsize);
            attributes.resize(nsize);
            si.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
            if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &nsize))
            {
                return false;
            }
            if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                    handles.data(), handles.size() * sizeof(HANDLE), nullptr, nullptr))
            {
                const DWORD dwerror = GetLastError();
                DeleteProcThreadAttributeList(si.lpAttributeList);
                SetLastError(dwerror);
                return false;
            }
        }

        const BOOL bcreated = CreateProcessW(nullptr, _szCommandLine, nullptr, nullptr,
            handles.empty() ? FALSE : TRUE, _dwFlags | EXTENDED_STARTUPINFO_PRESENT, _pEnvironment,
            _szWorkingDir, &si.StartupInfo, &_Info);
        const DWORD dwerror = GetLastError();
        if (si.lpAttributeList)
        {
            DeleteProcThreadAttributeList(si.lpAttributeList);
        }
        SetLastError(dwerror);
        return bcreated != FALSE;
    }

} // namespace gitgud::platform

#endif
