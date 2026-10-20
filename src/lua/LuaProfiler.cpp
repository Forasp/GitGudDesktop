#include "lua/LuaProfiler.h"

#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}

#include "app/StallWatchdog.h"

namespace gitgud::lua
{
    namespace
    {
        // The VM the watchdog may hook, guarded so it can't close meanwhile.
        std::mutex s_ActiveMutex;
        LuaProfiler* s_pActive = nullptr;

        LuaProfiler* Owner(lua_State* _pL)
        {
            return *static_cast<LuaProfiler**>(lua_getextraspace(_pL));
        }
    } // namespace

    void LuaProfiler::Attach(lua_State* _pL)
    {
        m_pL = _pL;
        *static_cast<LuaProfiler**>(lua_getextraspace(_pL)) = this;
        m_Chain.clear();
        m_Shadows.clear();
        m_FunctionZones.clear();
        m_Unnamed.clear();
        m_CallbackZones.clear();
        {
            std::lock_guard<std::mutex> lock(s_ActiveMutex);
            s_pActive = this;
        }
        prof::SetLuaTraceRequest(&LuaProfiler::RequestTrace);
        RestoreMask(_pL);
    }

    void LuaProfiler::Detach()
    {
        std::lock_guard<std::mutex> lock(s_ActiveMutex);
        if (s_pActive == this)
        {
            s_pActive = nullptr;
        }
        m_pL = nullptr;
        m_Chain.clear();
        m_Shadows.clear();
    }

    void LuaProfiler::SetCalls(bool _bOn)
    {
        if (_bOn == m_bCalls || !m_pL)
        {
            return;
        }
        m_bCalls = _bOn;
        m_Chain.clear();
        m_Shadows.clear();
        m_FunctionZones.clear();
        m_Unnamed.clear();
        RestoreMask(m_pL);
    }

    void LuaProfiler::RestoreMask(lua_State* _pL)
    {
        if (m_bCalls)
        {
            lua_sethook(_pL, &LuaProfiler::Hook, LUA_MASKCALL | LUA_MASKRET, 0);
        }
        else
        {
            lua_sethook(_pL, nullptr, 0, 0);
        }
    }

    void LuaProfiler::RequestTrace()
    {
        std::unique_lock<std::mutex> lock(s_ActiveMutex, std::try_to_lock);
        if (!lock.owns_lock() || !s_pActive || !s_pActive->m_pL)
        {
            return;
        }
        // Asynchronous use is what lua_sethook allows: the hook runs on the
        // UI thread at its next instruction.
        const int imask = s_pActive->m_bCalls ? (LUA_MASKCALL | LUA_MASKRET) : 0;
        lua_sethook(s_pActive->m_pL, &LuaProfiler::Hook, imask | LUA_MASKCOUNT, 1);
    }

    void LuaProfiler::Hook(lua_State* _pL, lua_Debug* _pAr)
    {
        LuaProfiler* pself = Owner(_pL);
        if (!pself)
        {
            return;
        }
        if (_pAr->event == LUA_HOOKCOUNT)
        {
            if (prof::LuaTraceWanted())
            {
                luaL_traceback(_pL, _pL, nullptr, 0);
                const char* sztrace = lua_tostring(_pL, -1);
                prof::DeliverLuaTrace(sztrace ? sztrace : "");
                lua_pop(_pL, 1);
            }
            pself->RestoreMask(_pL);
            if (pself->m_pL && pself->m_pL != _pL)
            {
                pself->RestoreMask(pself->m_pL);
            }
            return;
        }
        if (pself->m_bCalls && prof::Capturing())
        {
            pself->OnCall(_pL, _pAr);
        }
    }

    std::uintptr_t LuaProfiler::FunctionKey(lua_State* _pL, lua_Debug* _pAr, bool& _bC)
    {
        lua_getinfo(_pL, "Sf", _pAr);
        _bC = _pAr->what && _pAr->what[0] == 'C';
        std::uintptr_t key = 0;
        if (_bC)
        {
            key = reinterpret_cast<std::uintptr_t>(lua_tocfunction(_pL, -1)) | 1u;
        }
        else
        {
            key = reinterpret_cast<std::uintptr_t>(_pAr->source) +
                  (static_cast<std::uintptr_t>(static_cast<std::uint32_t>(_pAr->linedefined)) << 48);
        }
        lua_pop(_pL, 1);
        return key;
    }

    prof::ZoneId LuaProfiler::FunctionZone(lua_State* _pL, lua_Debug* _pAr, std::uintptr_t _uiKey, bool _bC)
    {
        const auto it = m_FunctionZones.find(_uiKey);
        if (it != m_FunctionZones.end())
        {
            if (!m_Unnamed.empty())
            {
                const auto unnamed = m_Unnamed.find(_uiKey);
                if (unnamed != m_Unnamed.end())
                {
                    lua_getinfo(_pL, "n", _pAr);
                    if (_pAr->name)
                    {
                        prof::RenameZone(it->second, std::string(_pAr->name) + unnamed->second);
                        m_Unnamed.erase(unnamed);
                    }
                }
            }
            return it->second;
        }
        lua_getinfo(_pL, "n", _pAr);
        std::string name;
        if (_bC && !_pAr->name)
        {
            // Called without a name (a loader, a callback): the C++ symbol.
            const prof::ZoneId id = prof::InternAddress(_uiKey & ~static_cast<std::uintptr_t>(1));
            m_FunctionZones.emplace(_uiKey, id);
            return id;
        }
        if (_bC)
        {
            name = std::string("[C] ") + _pAr->name;
        }
        else if (_pAr->what && std::strcmp(_pAr->what, "main") == 0)
        {
            name = std::string("main chunk (") + _pAr->short_src + ")";
        }
        else
        {
            const std::string where = std::string(" (") + _pAr->short_src + ":" + std::to_string(_pAr->linedefined) + ")";
            name = std::string(_pAr->name ? _pAr->name : "function") + where;
            if (!_pAr->name)
            {
                m_Unnamed.emplace(_uiKey, where);
            }
        }
        const prof::ZoneId id = prof::Intern(name);
        m_FunctionZones.emplace(_uiKey, id);
        return id;
    }

    void LuaProfiler::Suspend(lua_State* _pL)
    {
        auto& frames = m_Shadows[_pL];
        if (!frames.empty())
        {
            prof::EndTo(frames.front().m_iDepth);
        }
    }

    void LuaProfiler::SwitchTo(lua_State* _pL)
    {
        if (m_Chain.empty())
        {
            m_Chain.push_back(_pL);
            return;
        }
        if (m_Chain.back() == _pL)
        {
            return;
        }
        for (std::size_t i = m_Chain.size(); i-- > 0;)
        {
            if (m_Chain[i] == _pL)
            {
                // The coroutines above it yielded (or died): close their calls.
                while (m_Chain.size() > i + 1)
                {
                    Suspend(m_Chain.back());
                    m_Chain.pop_back();
                }
                return;
            }
        }
        // A coroutine was resumed: reopen the calls it had open.
        m_Chain.push_back(_pL);
        auto& frames = m_Shadows[_pL];
        lua_Debug ar{};
        if (lua_getstack(_pL, 1, &ar) == 0)
        {
            frames.clear(); // a fresh one (or a recycled address)
        }
        for (Frame& frame : frames)
        {
            frame.m_iDepth = prof::Depth();
            const auto it = m_FunctionZones.find(frame.m_uiKey);
            prof::Begin(it != m_FunctionZones.end() ? it->second : prof::Intern("(lua)"));
        }
    }

    void LuaProfiler::OnCall(lua_State* _pL, lua_Debug* _pAr)
    {
        SwitchTo(_pL);
        bool bc = false;
        const std::uintptr_t key = FunctionKey(_pL, _pAr, bc);
        auto& frames = m_Shadows[_pL];
        if (_pAr->event == LUA_HOOKCALL || _pAr->event == LUA_HOOKTAILCALL)
        {
            const prof::ZoneId id = FunctionZone(_pL, _pAr, key, bc);
            if (_pAr->event == LUA_HOOKTAILCALL && !frames.empty())
            {
                // The caller's frame is gone: this call takes its place.
                prof::EndTo(frames.back().m_iDepth);
                frames.pop_back();
            }
            frames.push_back({key, prof::Depth()});
            prof::Begin(id);
            return;
        }
        // A return: close up to the returning function (and anything an
        // error left open above it).
        for (std::size_t i = frames.size(); i-- > 0;)
        {
            if (frames[i].m_uiKey == key)
            {
                prof::EndTo(frames[i].m_iDepth);
                frames.resize(i);
                return;
            }
        }
    }

    prof::ZoneId LuaProfiler::CallbackZone(const std::string& _Event, int _iIndex)
    {
        lua_Debug ar{};
        lua_pushvalue(m_pL, _iIndex);
        lua_getinfo(m_pL, ">S", &ar);
        const std::uintptr_t key = reinterpret_cast<std::uintptr_t>(ar.source) +
                                   (static_cast<std::uintptr_t>(static_cast<std::uint32_t>(ar.linedefined)) << 48);
        auto& zones = m_CallbackZones[_Event];
        const auto it = zones.find(key);
        if (it != zones.end())
        {
            return it->second;
        }
        const std::string where = std::string(ar.short_src) + ":" + std::to_string(ar.linedefined);
        const prof::ZoneId id =
            prof::Intern(_Event.empty() ? "timer (" + where + ")" : "on " + _Event + " (" + where + ")");
        zones.emplace(key, id);
        return id;
    }

    void LuaProfiler::Unwind(int _iDepth)
    {
        if (m_bCalls)
        {
            // The main state's calls above it are gone; coroutines it
            // resumed keep theirs as suspended (a dead one is cleared when
            // its address is resumed again).
            if (!m_Chain.empty())
            {
                m_Chain.resize(1);
                auto& frames = m_Shadows[m_Chain.front()];
                while (!frames.empty() && frames.back().m_iDepth >= _iDepth)
                {
                    frames.pop_back();
                }
            }
        }
        prof::EndTo(_iDepth);
    }

} // namespace gitgud::lua

namespace gitgud::lua::bindings
{
    namespace
    {
        // gitgud.profileStart() / profileStop() / profileToggle(): ask for a
        // capture to start or stop (it does between frames; the reports land
        // in logs/profile-<time>, announced as "profiler.saved").
        int ProfileStart(lua_State*)
        {
            prof::RequestCapture(prof::CaptureRequest::Start);
            return 0;
        }

        int ProfileStop(lua_State*)
        {
            prof::RequestCapture(prof::CaptureRequest::Stop);
            return 0;
        }

        int ProfileToggle(lua_State*)
        {
            prof::RequestCapture(prof::CaptureRequest::Toggle);
            return 0;
        }

        // gitgud.profiling() -> running, seconds so far, last report folder
        int Profiling(lua_State* _pL)
        {
            lua_pushboolean(_pL, prof::Capturing());
            lua_pushnumber(_pL, prof::CaptureSeconds());
            const std::string folder = prof::LastCaptureFolder();
            lua_pushlstring(_pL, folder.data(), folder.size());
            return 3;
        }

        // gitgud.stallThreshold([ms]) -> ms: the stall watchdog's threshold
        // (0 turns its reports off).
        int StallThreshold(lua_State* _pL)
        {
            if (lua_isnumber(_pL, 1))
            {
                prof::SetStallThreshold(static_cast<int>(lua_tointeger(_pL, 1)));
            }
            lua_pushinteger(_pL, prof::StallThreshold());
            return 1;
        }

        // gitgud.stallCount() -> stalls reported, the last report's text
        int StallCount(lua_State* _pL)
        {
            lua_pushinteger(_pL, prof::StallCount());
            const std::string report = prof::LastStallReport();
            lua_pushlstring(_pL, report.data(), report.size());
            return 2;
        }
    } // namespace

    void AddProfilerBindings(std::vector<luaL_Reg>& _Functions)
    {
        _Functions.push_back({"profileStart", ProfileStart});
        _Functions.push_back({"profileStop", ProfileStop});
        _Functions.push_back({"profileToggle", ProfileToggle});
        _Functions.push_back({"profiling", Profiling});
        _Functions.push_back({"stallThreshold", StallThreshold});
        _Functions.push_back({"stallCount", StallCount});
    }
} // namespace gitgud::lua::bindings
