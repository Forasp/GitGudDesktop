#pragma once

// -----------------------------------------------------------------------------
// LuaEngine — owns the Lua VM and the `gitgud` binding table.
//
// The binding table is the ONLY way scripts reach C++: a small, intentional
// public API (full reference: docs/LUA_API.md). Its functions live in
// LuaRepoBindings.cpp (git) and LuaUiBindings.cpp (widgets, events, timers,
// platform); this class is the VM around them:
//
//   * lifecycle — Initialize / Reset (hot-reload throws the VM away)
//   * modules   — `require` resolves against resources/scripts, so main.lua
//                 is an entry point that pulls in any number of modules
//   * events    — gitgud.on(name, fn) handlers, dispatched by Dispatch()
//   * timers    — gitgud.after / gitgud.every, advanced by Tick()
//   * kept text: what scripts keep across a Reset (Keep / TakeKept)
//
// Sync repo actions return true/value on success, or (nil, "message") on
// failure — script code checks and surfaces errors in the UI.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

struct lua_State;

namespace gitgud::git
{
    class Repository;
}

namespace gitgud::app
{
    class EventBus;
    class IAppHost;
    class TaskRunner;
} // namespace gitgud::app

namespace gitgud::ui
{
    class IUiBackend;
}

namespace gitgud::agent
{
    class ToolServer;
}

namespace gitgud::platform
{
    class ICredentialStore;
}

namespace gitgud::lua
{
    class LuaProfiler;

    class LuaEngine
    {
      public:
        LuaEngine();
        ~LuaEngine();
        LuaEngine(const LuaEngine&) = delete;
        LuaEngine& operator=(const LuaEngine&) = delete;

        // Open standard libs and install the `gitgud` binding table.
        bool Initialize();

        // Tear the VM down and bring it back up with fresh bindings — the script
        // half of hot-reload. Handlers and timers are dropped (the re-run script
        // re-registers them).
        bool Reset();

        // Text kept for the next scripts across a Reset: on hot-reload a
        // script keeps what it needs (gitgud.keepForReload, on
        // "app.reloading") and the reloaded one takes it back
        // (gitgud.takeKept), so the UI comes back as it was.
        // Taking removes it; ClearKept drops everything (a UI
        // switch starts the next UI afresh).
        void Keep(const std::string& _Key, const std::string& _Value)
        {
            m_Kept[_Key] = _Value;
        }

        bool TakeKept(const std::string& _Key, std::string& _Value)
        {
            const auto it = m_Kept.find(_Key);
            if (it == m_Kept.end())
            {
                return false;
            }
            _Value = std::move(it->second);
            m_Kept.erase(it);
            return true;
        }

        void ForgetKept(const std::string& _Key)
        {
            m_Kept.erase(_Key);
        }

        void ClearKept()
        {
            m_Kept.clear();
        }

        // Wire the binding surface to the app's collaborators. Any pointer may be
        // nullptr (e.g. repo when cwd isn't a git repo; store on platforms without
        // a secure backend); the bindings degrade gracefully. May be called again
        // (e.g. after the app opens a different repository).
        void Bind(gitgud::git::Repository* _pRepo, gitgud::app::EventBus* _pBus,
            gitgud::ui::IUiBackend* _pUi, gitgud::app::TaskRunner* _pTasks,
            gitgud::platform::ICredentialStore* _pCredentials);

        // The application shell (pop-out windows, UI packages). May be nullptr.
        void SetAppHost(gitgud::app::IAppHost* _pHost)
        {
            m_pHost = _pHost;
        }

        // The Git and P4 tools for Claude Code (agent/ToolServer.h): sessions
        // scripts start get its MCP config. May be nullptr.
        void SetToolServer(gitgud::agent::ToolServer* _pTools)
        {
            m_pTools = _pTools;
        }

        // Directory `require` searches (`require("views.changes")` loads
        // <dir>/views/changes.lua). Applied now and after every Reset().
        void SetScriptRoot(const std::string& _Directory);
        // Several directories, searched in order (a UI package's scripts, then
        // the GitGud UI's, so packages reuse and override shared modules).
        void SetScriptRoots(const std::vector<std::string>& _Directories);

        // The running package's overlay scripts (app/UiPackages.h; "" for
        // none): `require` finds a module there first. One that fails to load
        // or run is reported (OverlayErrors) and the shipped one runs instead.
        void SetScriptOverlay(const std::string& _Directory);

        // Run a script file. Returns false and logs on error.
        bool RunFile(const std::string& _Path);
        // Run `_Overlay` when it exists, else `_Shipped`; an overlay file that
        // fails is reported and `_Shipped` runs instead.
        bool RunFileOrShipped(const std::string& _Overlay, const std::string& _Shipped);

        // Overlay files that failed to load since ClearOverlayErrors, as
        // {file, error} (scripts here; the UI backend adds its own). Each one
        // is also published as "ui.overlayError" ({file, error}).
        void AddOverlayError(const std::string& _File, const std::string& _Error);
        void ClearOverlayErrors()
        {
            m_OverlayErrors.clear();
        }
        const std::vector<std::pair<std::string, std::string>>& OverlayErrors() const
        {
            return m_OverlayErrors;
        }

        // Evaluate a chunk of Lua source. Handy for REPL/testing.
        bool Eval(const std::string& _Source);

        // Invoke every handler registered via gitgud.on(name, ...) for `name`,
        // passing `value` as the sole argument. main.cpp forwards both EventBus
        // events and UI widget events through here.
        void Dispatch(const std::string& _Name, const std::string& _Value);

        // Run due timers. Returns true if any fired.
        bool Tick();

        // Milliseconds until the next timer is due (0 if overdue), or -1 when no
        // timer is pending — the main loop sleeps at most this long.
        int MillisecondsUntilNextTimer() const;

        // Monotonic clock shared by timers and gitgud.now().
        static std::uint64_t NowMs();

        // Move that clock ahead (the test harness, GITGUD_SCRIPT: a step
        // that is ready goes on as if its wait had passed; timers fall due).
        static void SkipClock(int _iMs);

        // Log every handler or timer callback that takes at least this many
        // milliseconds, with the function's source location (GITGUD_PERF).
        // 0 (the default) turns the report off.
        void SetSlowCallThreshold(int _iMs)
        {
            m_iSlowCallMs = _iMs;
        }

        // Profile every Lua call while a capture runs (app/Profiler.h).
        // Call between frames, when no script runs.
        void SetCallProfiling(bool _bOn);

        // The Lua heap's size in kB.
        double MemoryKb() const;

        // Event handlers registered (gitgud.on), all events together.
        std::size_t HandlerCount() const
        {
            std::size_t ncount = 0;
            for (const auto& [name, refs] : m_Handlers)
            {
                ncount += refs.size();
            }
            return ncount;
        }

        lua_State* State()
        {
            return m_pL;
        }

        gitgud::git::Repository* Repository()
        {
            return m_pRepo;
        }

        gitgud::app::EventBus* EventBus()
        {
            return m_pBus;
        }

        gitgud::ui::IUiBackend* UiBackend()
        {
            return m_pUi;
        }

        gitgud::app::TaskRunner* TaskRunner()
        {
            return m_pTasks;
        }

        gitgud::platform::ICredentialStore* CredentialStore()
        {
            return m_pCredentials;
        }

        gitgud::app::IAppHost* AppHost()
        {
            return m_pHost;
        }

        gitgud::agent::ToolServer* ToolServer()
        {
            return m_pTools;
        }

        // Called by binding trampolines; not for general use.
        void RegisterHandler(const std::string& _EventName, int _iRef);
        // Drop every handler of an event (gitgud.off). Their functions are
        // released once no dispatch is running.
        void UnregisterHandlers(const std::string& _EventName);
        int AddTimer(int _iDelayMs, bool _bRepeat, int _iRef);
        void CancelTimer(int _iId);

      private:
        void InstallBindings(); // registers the `gitgud` global table
        void ApplyScriptRoot();
        // Call the function under _iArgs arguments on the stack, protected,
        // and report it if it was slow (see SetSlowCallThreshold).
        void CallTimed(int _iRef, int _iArgs, const char* _szContext, const std::string& _What);

        struct Timer
        {
            int m_iId = 0;
            std::uint64_t m_uiDueMs = 0;
            int m_iIntervalMs = 0; // 0 = one-shot
            int m_iRef = 0;        // registry ref of the callback
            bool m_bCancelled = false;
        };

        lua_State* m_pL = nullptr;
        gitgud::git::Repository* m_pRepo = nullptr;
        gitgud::app::EventBus* m_pBus = nullptr;
        gitgud::ui::IUiBackend* m_pUi = nullptr;
        gitgud::app::TaskRunner* m_pTasks = nullptr;
        gitgud::platform::ICredentialStore* m_pCredentials = nullptr;
        gitgud::app::IAppHost* m_pHost = nullptr;
        gitgud::agent::ToolServer* m_pTools = nullptr;
        std::vector<std::string> m_ScriptRoots;
        std::string m_ScriptOverlay;
        std::vector<std::pair<std::string, std::string>> m_OverlayErrors;

        // event name -> registry refs (luaL_ref) of the subscribed functions.
        std::unordered_map<std::string, std::vector<int>> m_Handlers;

        std::vector<Timer> m_Timers;
        std::unordered_map<std::string, std::string> m_Kept; // survives Reset
        int m_iNextTimerId = 1;
        int m_iSlowCallMs = 0;
        std::unique_ptr<LuaProfiler> m_pProfiler;
        int m_iDispatching = 0;           // nested Dispatch calls running
        std::vector<int> m_ReleaseLater;  // refs of handlers dropped meanwhile
    };

} // namespace gitgud::lua
