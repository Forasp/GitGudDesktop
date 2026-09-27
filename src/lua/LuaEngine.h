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
//
// Sync repo actions return true/value on success, or (nil, "message") on
// failure — script code checks and surfaces errors in the UI.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <string>
#include <unordered_map>
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

namespace gitgud::platform
{
    class ICredentialStore;
}

namespace gitgud::lua
{

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

        // Directory `require` searches (`require("views.changes")` loads
        // <dir>/views/changes.lua). Applied now and after every Reset().
        void SetScriptRoot(const std::string& _Directory);
        // Several directories, searched in order (a UI package's scripts, then
        // the default UI's, so packages reuse and override shared modules).
        void SetScriptRoots(const std::vector<std::string>& _Directories);

        // Run a script file. Returns false and logs on error.
        bool RunFile(const std::string& _Path);

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

        // Called by binding trampolines; not for general use.
        void RegisterHandler(const std::string& _EventName, int _iRef);
        int AddTimer(int _iDelayMs, bool _bRepeat, int _iRef);
        void CancelTimer(int _iId);

      private:
        void InstallBindings(); // registers the `gitgud` global table
        void ApplyScriptRoot();

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
        std::vector<std::string> m_ScriptRoots;

        // event name -> registry refs (luaL_ref) of the subscribed functions.
        std::unordered_map<std::string, std::vector<int>> m_Handlers;

        std::vector<Timer> m_Timers;
        int m_iNextTimerId = 1;
    };

} // namespace gitgud::lua
