#pragma once

// -----------------------------------------------------------------------------
// LuaProfiler: Lua's half of the profiler (app/Profiler.h).
//
//   * every event handler and timer callback runs in a zone named after the
//     event and where the function is defined, so the stall watchdog and the
//     reports say which handler was running;
//   * during a capture, a call hook makes every Lua function (and every C
//     function Lua calls) a zone of its own. Coroutines keep their own open
//     calls: a coroutine's calls close when it yields and reopen when it is
//     resumed. Calls an error unwound are closed when the call that caught
//     it returns;
//   * when the stall watchdog asks, a count hook takes a Lua traceback on the
//     UI thread at the next instruction.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "app/Profiler.h"

struct lua_State;
struct lua_Debug;
struct luaL_Reg;

namespace gitgud::lua
{
    class LuaProfiler
    {
      public:
        // A new VM (call right after it's made) / one about to close.
        void Attach(lua_State* _pL);
        void Detach();

        // Profile every Lua call (the call hook). Call between frames, when
        // no Lua runs.
        void SetCalls(bool _bOn);
        bool Calls() const
        {
            return m_bCalls;
        }

        // The zone for a handler of _Event (or a timer, when _Event is
        // empty), the function at stack index _iIndex.
        prof::ZoneId CallbackZone(const std::string& _Event, int _iIndex);

        // After a protected call returned: close the Lua calls an error left
        // open above _iDepth.
        void Unwind(int _iDepth);

        static void Hook(lua_State* _pL, lua_Debug* _pAr);
        static void RequestTrace();

      private:
        struct Frame
        {
            std::uintptr_t m_uiKey;
            int m_iDepth; // profiler depth before the call's zone opened
        };

        void OnCall(lua_State* _pL, lua_Debug* _pAr);
        void SwitchTo(lua_State* _pL);
        void Suspend(lua_State* _pL);
        void RestoreMask(lua_State* _pL);
        std::uintptr_t FunctionKey(lua_State* _pL, lua_Debug* _pAr, bool& _bC);
        prof::ZoneId FunctionZone(lua_State* _pL, lua_Debug* _pAr, std::uintptr_t _uiKey, bool _bC);

        lua_State* m_pL = nullptr;
        bool m_bCalls = false;
        std::vector<lua_State*> m_Chain; // the main state, then the coroutines it resumed
        std::unordered_map<lua_State*, std::vector<Frame>> m_Shadows;
        std::unordered_map<std::uintptr_t, prof::ZoneId> m_FunctionZones;
        // Functions first seen called without a name (by pcall, say): named
        // once a call shows their name.
        std::unordered_map<std::uintptr_t, std::string> m_Unnamed;
        std::unordered_map<std::string, std::unordered_map<std::uintptr_t, prof::ZoneId>> m_CallbackZones;
    };

} // namespace gitgud::lua

namespace gitgud::lua::bindings
{
    // gitgud.profileStart/profileStop/profileToggle/profiling,
    // stallThreshold/stallCount.
    void AddProfilerBindings(std::vector<luaL_Reg>& _Functions);
}
