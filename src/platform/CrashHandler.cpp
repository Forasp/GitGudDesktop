#include "platform/CrashHandler.h"

#include <cstdio>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <dbghelp.h>
#endif

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {

        std::wstring g_DumpPath;

        // Print one frame as "module!function+0xoffset (file:line)".
        void PrintFrame(HANDLE _hProcess, DWORD64 _Address)
        {
            char buffer[sizeof(SYMBOL_INFO) + MAX_SYM_NAME] = {};
            auto* psymbol = reinterpret_cast<SYMBOL_INFO*>(buffer);
            psymbol->SizeOfStruct = sizeof(SYMBOL_INFO);
            psymbol->MaxNameLen = MAX_SYM_NAME;

            DWORD64 displacement = 0;
            const bool bhaveSymbol = SymFromAddr(_hProcess, _Address, &displacement, psymbol) != 0;

            IMAGEHLP_LINE64 line = {};
            line.SizeOfStruct = sizeof(line);
            DWORD lineDisplacement = 0;
            const bool bhaveLine =
                SymGetLineFromAddr64(_hProcess, _Address, &lineDisplacement, &line) != 0;

            if (bhaveSymbol && bhaveLine)
            {
                std::fprintf(stderr, "    %s+0x%llx  (%s:%lu)\n", psymbol->Name,
                    static_cast<unsigned long long>(displacement), line.FileName, line.LineNumber);
            }
            else if (bhaveSymbol)
            {
                std::fprintf(stderr, "    %s+0x%llx\n", psymbol->Name,
                    static_cast<unsigned long long>(displacement));
            }
            else
            {
                std::fprintf(stderr, "    0x%llx\n", static_cast<unsigned long long>(_Address));
            }
        }

        LONG WINAPI OnUnhandledException(EXCEPTION_POINTERS* _pInfo)
        {
            HANDLE hprocess = GetCurrentProcess();
            std::fprintf(stderr, "\n[crash] unhandled exception 0x%08lx at %p\n",
                _pInfo->ExceptionRecord->ExceptionCode, _pInfo->ExceptionRecord->ExceptionAddress);

            // Walk the faulting thread's stack from the exception context.
            SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
            SymInitialize(hprocess, nullptr, TRUE);

            CONTEXT context = *_pInfo->ContextRecord;
            STACKFRAME64 frame = {};
            frame.AddrPC.Offset = context.Rip;
            frame.AddrPC.Mode = AddrModeFlat;
            frame.AddrFrame.Offset = context.Rbp;
            frame.AddrFrame.Mode = AddrModeFlat;
            frame.AddrStack.Offset = context.Rsp;
            frame.AddrStack.Mode = AddrModeFlat;

            for (int i = 0; i < 48; ++i)
            {
                if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, hprocess, GetCurrentThread(), &frame,
                        &context, nullptr, SymFunctionTableAccess64, SymGetModuleBase64, nullptr) ||
                    frame.AddrPC.Offset == 0)
                {
                    break;
                }
                PrintFrame(hprocess, frame.AddrPC.Offset);
            }
            std::fflush(stderr);

            HANDLE hfile = CreateFileW(g_DumpPath.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL, nullptr);
            if (hfile != INVALID_HANDLE_VALUE)
            {
                MINIDUMP_EXCEPTION_INFORMATION exception = {};
                exception.ThreadId = GetCurrentThreadId();
                exception.ExceptionPointers = _pInfo;
                exception.ClientPointers = FALSE;
                MiniDumpWriteDump(hprocess, GetCurrentProcessId(), hfile, MiniDumpNormal,
                    &exception, nullptr, nullptr);
                CloseHandle(hfile);
                std::fprintf(stderr, "[crash] minidump written next to the executable\n");
            }

            return EXCEPTION_EXECUTE_HANDLER;
        }

    } // namespace

    void InstallCrashHandler(const std::string& _DumpDirectory)
    {
        const std::string path = _DumpDirectory + "/gitgud-crash.dmp";
        const int iwide = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
        g_DumpPath.assign(static_cast<std::size_t>(iwide > 0 ? iwide : 1), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, g_DumpPath.data(), iwide);
        SetUnhandledExceptionFilter(OnUnhandledException);
    }

#else

    void InstallCrashHandler(const std::string&)
    {
    }

#endif

} // namespace gitgud::platform
