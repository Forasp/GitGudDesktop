// -----------------------------------------------------------------------------
// Every function a zone: the compiler's entry/exit hooks, for a build
// configured with GITGUD_PROFILE_INSTRUMENT=ON.
//
// MSVC (/Gh /GH) calls _penter and _pexit (ProfilerPenter.asm saves the
// registers and calls GitgudPenter/GitgudPexit with the hook's return address,
// inside the instrumented function); GCC and Clang (-finstrument-functions)
// call __cyg_profile_func_enter/exit with the function's address. A function
// becomes a zone named by the program's symbols when the report is written.
//
// Hooks only open zones while a capture runs. Exits are matched to entries by
// function, so an exception (which skips the exit hooks) or a capture that
// starts or stops mid-call leaves nothing unbalanced.
//
// This file is part of gitgud_profiler, which is never instrumented itself.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "app/Profiler.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#if defined(_MSC_VER)
#define GITGUD_NO_INSTRUMENT
#else
#define GITGUD_NO_INSTRUMENT __attribute__((no_instrument_function))
#endif

namespace
{
    // Re-entry guard, read before anything else (prof::HooksOff, also set
    // while the profiler's own code runs): the inline and template code the
    // hooks call (the containers, Capturing(), even the thread's state being
    // built) can be the instrumented copy from another file, whose hook
    // would call back in until the stack ran out.

    struct InstrumentThread
    {
        std::vector<std::uintptr_t> m_Open;
        struct Function
        {
            std::uintptr_t m_uiStart;
            gitgud::prof::ZoneId m_Zone;
        };
        std::unordered_map<std::uintptr_t, Function> m_Functions; // by hook site
    };

    GITGUD_NO_INSTRUMENT InstrumentThread& Thread()
    {
        thread_local InstrumentThread s_Thread;
        return s_Thread;
    }

    // The start of the function containing a code address.
    GITGUD_NO_INSTRUMENT std::uintptr_t FunctionStart(std::uintptr_t _Address)
    {
#if defined(_WIN32) && defined(_M_X64)
        DWORD64 imageBase = 0;
        if (PRUNTIME_FUNCTION pentry = RtlLookupFunctionEntry(_Address, &imageBase, nullptr))
        {
            return static_cast<std::uintptr_t>(imageBase + pentry->BeginAddress);
        }
#endif
        return _Address;
    }

    GITGUD_NO_INSTRUMENT const InstrumentThread::Function& Lookup(InstrumentThread& _Thread, std::uintptr_t _Site)
    {
        auto it = _Thread.m_Functions.find(_Site);
        if (it == _Thread.m_Functions.end())
        {
            const std::uintptr_t start = FunctionStart(_Site);
            it = _Thread.m_Functions.emplace(_Site, InstrumentThread::Function{start, gitgud::prof::InternAddress(start)}).first;
        }
        return it->second;
    }

    GITGUD_NO_INSTRUMENT void Enter(std::uintptr_t _Site)
    {
        bool& boff = gitgud::prof::HooksOff();
        if (boff)
        {
            return;
        }
        boff = true;
        if (gitgud::prof::Capturing())
        {
            InstrumentThread& thread = Thread();
            const InstrumentThread::Function& function = Lookup(thread, _Site);
            thread.m_Open.push_back(function.m_uiStart);
            thread.m_Open.push_back(static_cast<std::uintptr_t>(gitgud::prof::Depth()));
            gitgud::prof::Begin(function.m_Zone);
        }
        boff = false;
    }

    GITGUD_NO_INSTRUMENT void Exit(std::uintptr_t _Site)
    {
        bool& boff = gitgud::prof::HooksOff();
        if (boff)
        {
            return;
        }
        boff = true;
        InstrumentThread& thread = Thread();
        if (!thread.m_Open.empty())
        {
            const std::uintptr_t function = Lookup(thread, _Site).m_uiStart;
            for (std::size_t i = thread.m_Open.size(); i >= 2; i -= 2)
            {
                if (thread.m_Open[i - 2] == function)
                {
                    gitgud::prof::EndTo(static_cast<int>(thread.m_Open[i - 1]));
                    thread.m_Open.resize(i - 2);
                    break;
                }
            }
        }
        boff = false;
    }
} // namespace

#if defined(_MSC_VER)
extern "C" void GitgudPenter(std::uintptr_t _Site)
{
    Enter(_Site);
}

extern "C" void GitgudPexit(std::uintptr_t _Site)
{
    Exit(_Site);
}
#else
extern "C" GITGUD_NO_INSTRUMENT void __cyg_profile_func_enter(void* _pFunction, void*)
{
    Enter(reinterpret_cast<std::uintptr_t>(_pFunction));
}

extern "C" GITGUD_NO_INSTRUMENT void __cyg_profile_func_exit(void* _pFunction, void*)
{
    Exit(reinterpret_cast<std::uintptr_t>(_pFunction));
}
#endif
