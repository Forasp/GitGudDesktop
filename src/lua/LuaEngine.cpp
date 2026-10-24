#include "lua/LuaEngine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#include "agent/ToolServer.h"
#include "app/EventBus.h"
#include "app/Json.h"
#include "app/Profiler.h"
#include "lua/LuaBindings.h"
#include "lua/LuaProfiler.h"
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

    LuaEngine::LuaEngine() : m_pProfiler(std::make_unique<LuaProfiler>())
    {
    }

    LuaEngine::~LuaEngine()
    {
        bindings::StopVoice();
        bindings::StopAgents();
        if (m_pL)
        {
            m_pProfiler->Detach();
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
        m_pProfiler->Attach(m_pL);
        luaL_openlibs(m_pL);
        InstallBindings();
        ApplyScriptRoot();
        return true;
    }

    bool LuaEngine::Reset()
    {
        GITGUD_PROFILE_SCOPE("LuaEngine::Reset");
        if (m_pL)
        {
            m_pProfiler->Detach();
            lua_close(m_pL);
            m_pL = nullptr;
        }
        // Registry refs died with the VM.
        m_Handlers.clear();
        m_ReleaseLater.clear();
        m_Timers.clear();
        // The tools the old scripts declared went with them; the new ones
        // declare their own.
        if (m_pTools)
        {
            std::string error;
            m_pTools->SetUiTools(app::Json::Array(), error);
        }
        return Initialize();
    }


    namespace
    {
        // The overlay searcher (SetScriptOverlay), installed second in
        // package.searchers: before the path searcher, after preload.
        constexpr const char* kOverlaySearcher = R"lua(
local overlay, report = ...
local searchers = package.searchers
for i = #searchers, 1, -1 do
    if searchers[i] == package.gitgudOverlaySearcher then
        table.remove(searchers, i)
    end
end
package.gitgudOverlaySearcher = nil
if overlay == "" then
    return
end
local function exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end
-- The shipped module, for when the overlay's fails.
local function shipped(name, why)
    local path = package.searchpath(name, package.path)
    if not path then
        error(why, 0)
    end
    local chunk = assert(loadfile(path))
    return chunk(name, path)
end
local function searcher(name)
    local rel = name:gsub("%.", "/")
    local file = overlay .. "/" .. rel .. ".lua"
    if not exists(file) then
        file = overlay .. "/" .. rel .. "/init.lua"
        if not exists(file) then
            return nil
        end
    end
    local chunk, err = loadfile(file)
    if not chunk then
        report(file, err)
        return function(modname)
            return shipped(modname, err)
        end, file
    end
    return function(modname)
        local ok, result = pcall(chunk, modname, file)
        if ok then
            return result
        end
        report(file, tostring(result))
        return shipped(modname, result)
    end, file
end
package.gitgudOverlaySearcher = searcher
table.insert(searchers, 2, searcher)
)lua";

        int LReportOverlay(lua_State* _pL)
        {
            auto* pengine = static_cast<LuaEngine*>(lua_touserdata(_pL, lua_upvalueindex(1)));
            const char* szfile = luaL_checkstring(_pL, 1);
            const char* szerror = luaL_optstring(_pL, 2, "");
            pengine->AddOverlayError(szfile, szerror);
            return 0;
        }
    } // namespace

    void LuaEngine::SetScriptOverlay(const std::string& _Directory)
    {
        m_ScriptOverlay = _Directory;
        ApplyScriptRoot();
    }

    void LuaEngine::AddOverlayError(const std::string& _File, const std::string& _Error)
    {
        std::fprintf(stderr, "[lua] customized file '%s' failed, using the shipped one: %s\n",
            _File.c_str(), _Error.c_str());
        m_OverlayErrors.emplace_back(_File, _Error);
        if (m_pBus)
        {
            m_pBus->Publish({"ui.overlayError",
                app::Json::Object().Set("file", _File).Set("error", _Error).Dump()});
        }
    }

    bool LuaEngine::RunFileOrShipped(const std::string& _Overlay, const std::string& _Shipped)
    {
        std::error_code ec;
        if (_Overlay.empty() || !std::filesystem::is_regular_file(std::filesystem::u8path(_Overlay), ec))
        {
            return RunFile(_Shipped);
        }
        if (luaL_loadfile(m_pL, _Overlay.c_str()) != LUA_OK)
        {
            AddOverlayError(_Overlay, lua_tostring(m_pL, -1));
            lua_pop(m_pL, 1);
            return RunFile(_Shipped);
        }
        if (lua_pcall(m_pL, 0, 0, 0) != LUA_OK)
        {
            AddOverlayError(_Overlay, lua_tostring(m_pL, -1) ? lua_tostring(m_pL, -1) : "error");
            lua_pop(m_pL, 1);
            return RunFile(_Shipped);
        }
        return true;
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

        // The overlay's modules first, falling back to the shipped ones.
        if (luaL_loadstring(m_pL, kOverlaySearcher) == LUA_OK)
        {
            lua_pushlstring(m_pL, m_ScriptOverlay.data(), m_ScriptOverlay.size());
            lua_pushlightuserdata(m_pL, this);
            lua_pushcclosure(m_pL, LReportOverlay, 1);
            ProtectedCall(m_pL, 2, "installing the overlay searcher");
        }
        else
        {
            lua_pop(m_pL, 1);
        }
    }

    void LuaEngine::InstallBindings()
    {
        // One global table `gitgud`; every function shares one upvalue — this
        // LuaEngine — so the free trampolines can reach the collaborators.
        std::vector<luaL_Reg> functions;
        bindings::AddRepoBindings(functions);
        bindings::AddUiBindings(functions);
        bindings::AddStoreBindings(functions);
        bindings::AddFeatureBindings(functions);
        bindings::AddAppBindings(functions);
        bindings::AddUpdateBindings(functions);
        bindings::AddP4Bindings(functions);
        bindings::AddJsonBindings(functions);
        bindings::AddLookupBindings(functions);
        bindings::AddVoiceBindings(functions);
        bindings::AddLocalDataBindings(functions);
        bindings::AddAgentBindings(functions);
        bindings::AddAgentHistoryBindings(functions);
        bindings::AddImageBindings(functions);
        bindings::AddProfilerBindings(functions);
        functions.push_back({nullptr, nullptr});

        lua_newtable(m_pL);
        lua_pushlightuserdata(m_pL, this);
        luaL_setfuncs(m_pL, functions.data(), 1);
        lua_pushliteral(m_pL, GITGUD_VERSION);
        lua_setfield(m_pL, -2, "version");
#if defined(_WIN32)
        lua_pushliteral(m_pL, "windows");
#elif defined(__APPLE__)
        lua_pushliteral(m_pL, "macos");
#else
        lua_pushliteral(m_pL, "linux");
#endif
        lua_setfield(m_pL, -2, "platform");
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
        ++m_iDispatching;
        for (int iref : refs)
        {
            lua_rawgeti(m_pL, LUA_REGISTRYINDEX, iref);
            lua_pushlstring(m_pL, _Value.data(), _Value.size());
            CallTimed(iref, 1, context.c_str(), _Name);
        }
        if (--m_iDispatching == 0 && !m_ReleaseLater.empty())
        {
            for (int iref : m_ReleaseLater)
            {
                luaL_unref(m_pL, LUA_REGISTRYINDEX, iref);
            }
            m_ReleaseLater.clear();
        }
    }

    void LuaEngine::UnregisterHandlers(const std::string& _EventName)
    {
        const auto it = m_Handlers.find(_EventName);
        if (it == m_Handlers.end())
        {
            return;
        }
        for (int iref : it->second)
        {
            if (m_iDispatching > 0)
            {
                m_ReleaseLater.push_back(iref);
            }
            else
            {
                luaL_unref(m_pL, LUA_REGISTRYINDEX, iref);
            }
        }
        m_Handlers.erase(it);
    }

    void LuaEngine::CallTimed(
        int _iRef, int _iArgs, const char* _szContext, const std::string& _What)
    {
        // A zone per handler, named after its event and where it's defined:
        // the stall watchdog and the profiler's reports name it.
        const int idepth = prof::Depth();
        prof::Begin(m_pProfiler->CallbackZone(_What, -(_iArgs + 1)));
        if (m_iSlowCallMs <= 0)
        {
            ProtectedCall(m_pL, _iArgs, _szContext);
            m_pProfiler->Unwind(idepth);
            return;
        }

        const auto started = std::chrono::steady_clock::now();
        ProtectedCall(m_pL, _iArgs, _szContext);
        m_pProfiler->Unwind(idepth);
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
        std::printf("[perf] lua %-28s %7.1f ms  %s\n", _What.empty() ? "(timer)" : _What.c_str(), fms, where.c_str());
    }

    void LuaEngine::SetCallProfiling(bool _bOn)
    {
        m_pProfiler->SetCalls(_bOn);
    }

    double LuaEngine::MemoryKb() const
    {
        return m_pL ? static_cast<double>(lua_gc(m_pL, LUA_GCCOUNT, 0)) + lua_gc(m_pL, LUA_GCCOUNTB, 0) / 1024.0 : 0.0;
    }

    namespace
    {
        // Time the test harness skipped ahead (SkipClock), on top of the
        // steady clock.
        std::atomic<std::uint64_t> s_uiSkippedMs{0};
    } // namespace

    std::uint64_t LuaEngine::NowMs()
    {
        using namespace std::chrono;
        return static_cast<std::uint64_t>(
                   duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count()) +
               s_uiSkippedMs.load();
    }

    void LuaEngine::SkipClock(int _iMs)
    {
        if (_iMs > 0)
        {
            s_uiSkippedMs += static_cast<std::uint64_t>(_iMs);
        }
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
        const bool bpictures = bindings::ShowDecodedImages(m_pUi);
        if (m_Timers.empty())
        {
            return bpictures;
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
            CallTimed(iref, 0, "error in timer", "");
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
        return bpictures || !due.empty();
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
