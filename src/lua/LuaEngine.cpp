#include "lua/LuaEngine.h"

#include <algorithm>
#include <chrono>
#include <cstdio>

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#include "lua/LuaBindings.h"
#include "p4/P4Workspace.h"

namespace gitgud::lua
{

    namespace
    {

        // Error handler for pcall: appends a traceback so script errors point at
        // the offending line (and the call chain) in the console.
        int Traceback(lua_State* _pL)
        {
            const char* szmsg = lua_tostring(_pL, 1);
            luaL_traceback(_pL, _pL, szmsg ? szmsg : "(error object is not a string)", 1);
            return 1;
        }

        // Call the function on top of the stack with `_iArgs` arguments under
        // the traceback handler. Logs and returns false on error.
        bool ProtectedCall(lua_State* _pL, int _iArgs, const char* _szContext)
        {
            const int ibase = lua_gettop(_pL) - _iArgs;
            lua_pushcfunction(_pL, Traceback);
            lua_insert(_pL, ibase);
            const int irc = lua_pcall(_pL, _iArgs, 0, ibase);
            lua_remove(_pL, ibase);
            if (irc != LUA_OK)
            {
                std::fprintf(stderr, "[lua] %s: %s\n", _szContext, lua_tostring(_pL, -1));
                lua_pop(_pL, 1);
                return false;
            }
            return true;
        }

    } // namespace

    LuaEngine::LuaEngine() = default;

    LuaEngine::~LuaEngine()
    {
        if (m_pL)
        {
            lua_close(m_pL);
            m_pL = nullptr;
        }
    }

    void LuaEngine::Bind(gitgud::git::Repository* _pRepo, gitgud::app::EventBus* _pBus,
        gitgud::ui::IUiBackend* _pUi, gitgud::app::TaskRunner* _pTasks,
        gitgud::platform::ICredentialStore* _pCredentials)
    {
        m_pRepo = _pRepo;
        m_pBus = _pBus;
        m_pUi = _pUi;
        m_pTasks = _pTasks;
        m_pCredentials = _pCredentials;
        // Perforce commands on the UI thread's workspace log in with the
        // saved password (or ask for one) like network jobs do.
        gitgud::p4::P4Workspace::SetDefaultPasswordProvider(gitgud::p4::P4Workspace::FromCredentialProvider(
            bindings::MakeCredentialProvider(_pCredentials, _pBus)));
    }

    bool LuaEngine::Initialize()
    {
        m_pL = luaL_newstate();
        if (!m_pL)
        {
            return false;
        }
        luaL_openlibs(m_pL);
        InstallBindings();
        ApplyScriptRoot();
        return true;
    }

    bool LuaEngine::Reset()
    {
        if (m_pL)
        {
            lua_close(m_pL);
            m_pL = nullptr;
        }
        // Registry refs died with the VM.
        m_Handlers.clear();
        m_Timers.clear();
        return Initialize();
    }

    void LuaEngine::SetScriptRoot(const std::string& _Directory)
    {
        SetScriptRoots({_Directory});
    }

    void LuaEngine::SetScriptRoots(const std::vector<std::string>& _Directories)
    {
        m_ScriptRoots = _Directories;
        ApplyScriptRoot();
    }

    void LuaEngine::ApplyScriptRoot()
    {
        if (!m_pL || m_ScriptRoots.empty())
        {
            return;
        }
        // Only our script trees: modules can't accidentally pick up a stray
        // LUA_PATH from the environment.
        std::string path;
        for (const std::string& root : m_ScriptRoots)
        {
            if (!path.empty())
            {
                path += ";";
            }
            path += root + "/?.lua;" + root + "/?/init.lua";
        }
        lua_getglobal(m_pL, "package");
        lua_pushlstring(m_pL, path.data(), path.size());
        lua_setfield(m_pL, -2, "path");
        lua_pushliteral(m_pL, "");
        lua_setfield(m_pL, -2, "cpath");
        lua_pop(m_pL, 1);
    }

    void LuaEngine::InstallBindings()
    {
        // One global table `gitgud`; every function shares one upvalue — this
        // LuaEngine — so the free trampolines can reach the collaborators.
        std::vector<luaL_Reg> functions;
        bindings::AddRepoBindings(functions);
        bindings::AddUiBindings(functions);
        bindings::AddFeatureBindings(functions);
        bindings::AddAppBindings(functions);
        bindings::AddUpdateBindings(functions);
        bindings::AddP4Bindings(functions);
        functions.push_back({nullptr, nullptr});

        lua_newtable(m_pL);
        lua_pushlightuserdata(m_pL, this);
        luaL_setfuncs(m_pL, functions.data(), 1);
        lua_pushliteral(m_pL, GITGUD_VERSION);
        lua_setfield(m_pL, -2, "version");
        lua_setglobal(m_pL, "gitgud");
    }

    bool LuaEngine::RunFile(const std::string& _Path)
    {
        if (luaL_loadfile(m_pL, _Path.c_str()) != LUA_OK)
        {
            std::fprintf(
                stderr, "[lua] error loading '%s': %s\n", _Path.c_str(), lua_tostring(m_pL, -1));
            lua_pop(m_pL, 1);
            return false;
        }
        return ProtectedCall(m_pL, 0, ("error running '" + _Path + "'").c_str());
    }

    bool LuaEngine::Eval(const std::string& _Source)
    {
        if (luaL_loadstring(m_pL, _Source.c_str()) != LUA_OK)
        {
            std::fprintf(stderr, "[lua] error: %s\n", lua_tostring(m_pL, -1));
            lua_pop(m_pL, 1);
            return false;
        }
        return ProtectedCall(m_pL, 0, "eval");
    }

    void LuaEngine::RegisterHandler(const std::string& _EventName, int _iRef)
    {
        m_Handlers[_EventName].push_back(_iRef);
    }

    void LuaEngine::Dispatch(const std::string& _Name, const std::string& _Value)
    {
        const auto it = m_Handlers.find(_Name);
        if (it == m_Handlers.end())
        {
            return;
        }
        // Copy: a handler may register more handlers for the same event.
        const std::vector<int> refs = it->second;
        const std::string context = "error in handler for '" + _Name + "'";
        for (int iref : refs)
        {
            lua_rawgeti(m_pL, LUA_REGISTRYINDEX, iref);
            lua_pushlstring(m_pL, _Value.data(), _Value.size());
            CallTimed(iref, 1, context.c_str(), _Name);
        }
    }

    void LuaEngine::CallTimed(
        int _iRef, int _iArgs, const char* _szContext, const std::string& _What)
    {
        if (m_iSlowCallMs <= 0)
        {
            ProtectedCall(m_pL, _iArgs, _szContext);
            return;
        }

        const auto started = std::chrono::steady_clock::now();
        ProtectedCall(m_pL, _iArgs, _szContext);
        const double fms =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started)
                .count();
        if (fms < m_iSlowCallMs)
        {
            return;
        }

        // Where the function was defined, so the report names the handler.
        lua_rawgeti(m_pL, LUA_REGISTRYINDEX, _iRef);
        lua_Debug info{};
        std::string where = "?";
        if (lua_getinfo(m_pL, ">S", &info) != 0)
        {
            where = std::string(info.short_src) + ":" + std::to_string(info.linedefined);
        }
        std::printf("[perf] lua %-28s %7.1f ms  %s\n", _What.c_str(), fms, where.c_str());
    }

    std::uint64_t LuaEngine::NowMs()
    {
        using namespace std::chrono;
        return static_cast<std::uint64_t>(
            duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
    }

    int LuaEngine::AddTimer(int _iDelayMs, bool _bRepeat, int _iRef)
    {
        Timer timer;
        timer.m_iId = m_iNextTimerId++;
        timer.m_uiDueMs = NowMs() + static_cast<std::uint64_t>(std::max(0, _iDelayMs));
        timer.m_iIntervalMs = _bRepeat ? std::max(1, _iDelayMs) : 0;
        timer.m_iRef = _iRef;
        m_Timers.push_back(timer);
        return timer.m_iId;
    }

    void LuaEngine::CancelTimer(int _iId)
    {
        for (Timer& timer : m_Timers)
        {
            if (timer.m_iId == _iId)
            {
                timer.m_bCancelled = true;
            }
        }
    }

    bool LuaEngine::Tick()
    {
        if (m_Timers.empty())
        {
            return false;
        }

        const std::uint64_t now = NowMs();
        std::vector<int> due;
        for (const Timer& timer : m_Timers)
        {
            if (!timer.m_bCancelled && timer.m_uiDueMs <= now)
            {
                due.push_back(timer.m_iId);
            }
        }

        // Callbacks may add or cancel timers, so look each one up afresh.
        for (int iid : due)
        {
            auto it = std::find_if(m_Timers.begin(), m_Timers.end(),
                [iid](const Timer& _T) { return _T.m_iId == iid; });
            if (it == m_Timers.end() || it->m_bCancelled)
            {
                continue;
            }
            const int iref = it->m_iRef;
            if (it->m_iIntervalMs > 0)
            {
                it->m_uiDueMs = now + static_cast<std::uint64_t>(it->m_iIntervalMs);
            }
            else
            {
                it->m_bCancelled = true;
            }
            lua_rawgeti(m_pL, LUA_REGISTRYINDEX, iref);
            CallTimed(iref, 0, "error in timer", "(timer)");
        }

        // Drop finished timers and release their callbacks.
        for (auto it = m_Timers.begin(); it != m_Timers.end();)
        {
            if (it->m_bCancelled)
            {
                luaL_unref(m_pL, LUA_REGISTRYINDEX, it->m_iRef);
                it = m_Timers.erase(it);
            }
            else
            {
                ++it;
            }
        }
        return !due.empty();
    }

    int LuaEngine::MillisecondsUntilNextTimer() const
    {
        const std::uint64_t now = NowMs();
        int best = -1;
        for (const Timer& timer : m_Timers)
        {
            if (timer.m_bCancelled)
            {
                continue;
            }
            const int iwait = timer.m_uiDueMs <= now ? 0 : static_cast<int>(timer.m_uiDueMs - now);
            if (best < 0 || iwait < best)
            {
                best = iwait;
            }
        }
        return best;
    }

} // namespace gitgud::lua
