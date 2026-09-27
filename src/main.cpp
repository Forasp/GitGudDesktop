// -----------------------------------------------------------------------------
// Gitgud — entry point.
//
// The C++ side owns the subsystems (SDL window, Repository, EventBus,
// TaskRunner, credential store, UI backend, Lua VM) and the main loop. ALL
// view logic lives in resources/scripts (main.lua is the entry point); the
// widget tree is resources/layouts (main.xml imports the rest); the skin is
// resources/schemes + resources/looknfeel. C++ forwards every event (core +
// widget + keyboard) into Lua and otherwise stays out of the way — that split
// is what makes the UI fully moddable without a recompile (docs/MODDING.md).
//
// The loop renders on demand: it sleeps in SDL_WaitEventTimeout until input,
// a worker-thread event, a Lua timer, or a UI animation needs a frame, so an
// idle window costs (almost) nothing.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

#include <SDL.h>
#include <SDL_opengl.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN // SDL.h may already have defined it
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <sys/stat.h>
#endif

#include "app/EventBus.h"
#include "app/TaskRunner.h"
#include "git/Repository.h"
#include "imaging/ImageDiff.h"
#include "lua/LuaEngine.h"
#include "platform/CrashHandler.h"
#include "platform/ICredentialStore.h"
#include "ui/IUiBackend.h"

#if defined(GITGUD_UI_CEGUI)
#include "ui/cegui/CeguiBackend.h"
#endif

namespace
{

    namespace fs = std::filesystem;

    constexpr const char* kMainLayout = "main.xml";

    std::unique_ptr<gitgud::ui::IUiBackend> MakeUiBackend()
    {
#if defined(GITGUD_UI_CEGUI)
        return std::make_unique<gitgud::ui::CeguiBackend>();
#else
        return nullptr; // a future CustomBackend plugs in here
#endif
    }

    // Watches the UI resource files and reports when any of them changed —
    // the trigger for hot-reload (edit the XML/Lua, see it live, no restart).
    class ResourceWatcher
    {
      public:
        explicit ResourceWatcher(std::string _ResourceRoot) : m_Root(std::move(_ResourceRoot))
        {
            m_Snapshot = Scan();
        }

        bool Changed()
        {
            auto now = Scan();
            if (now != m_Snapshot)
            {
                m_Snapshot = std::move(now);
                return true;
            }
            return false;
        }

      private:
        // A cheap fingerprint: every watched file's relative path + mtime,
        // recursively (layouts and scripts live in sub-folders).
        std::string Scan() const
        {
            std::string sig;
            for (const char* szsub : {"/layouts", "/scripts", "/looknfeel", "/schemes"})
            {
                std::error_code ec;
                fs::recursive_directory_iterator it(m_Root + szsub, ec);
                if (ec)
                {
                    continue;
                }
                for (fs::recursive_directory_iterator end; it != end; it.increment(ec))
                {
                    if (ec)
                    {
                        break;
                    }
                    std::error_code tec;
                    const auto t = fs::last_write_time(it->path(), tec);
                    if (tec)
                    {
                        continue;
                    }
                    sig += it->path().u8string();
                    sig += std::to_string(t.time_since_epoch().count());
                }
            }
            return sig;
        }

        std::string m_Root;
        std::string m_Snapshot;
    };

    // SDL hit test for the borderless window: it decides, per mouse position,
    // whether the point acts as a Resize border, a title-bar drag area, or plain
    // client area. Edges/corners Resize; anything the UI marks as a drag region
    // (layout widgets carrying the AppDrag user string) moves the window — which
    // also gives us native Aero snap and double-click-to-maximize for free.
    SDL_HitTestResult WindowHitTest(SDL_Window* _pWin, const SDL_Point* _pP, void* _pData)
    {
        constexpr int ikEdge = 8; // Resize grip thickness, px

        if (!(SDL_GetWindowFlags(_pWin) & SDL_WINDOW_MAXIMIZED))
        {
            int iw = 0;
            int ih = 0;
            SDL_GetWindowSize(_pWin, &iw, &ih);
            const bool bl = _pP->x < ikEdge;
            const bool br = _pP->x >= iw - ikEdge;
            const bool bt = _pP->y < ikEdge;
            const bool bb = _pP->y >= ih - ikEdge;
            const int ieVal = bt + (bl * 2) + (br * 4) + (bb * 8);

            switch (ieVal)
            {
            case 1:
                return SDL_HITTEST_RESIZE_TOP;
            case 2:
                return SDL_HITTEST_RESIZE_LEFT;
            case 3:
                return SDL_HITTEST_RESIZE_TOPLEFT;
            case 4:
                return SDL_HITTEST_RESIZE_RIGHT;
            case 5:
                return SDL_HITTEST_RESIZE_TOPRIGHT;
            case 8:
                return SDL_HITTEST_RESIZE_BOTTOM;
            case 10:
                return SDL_HITTEST_RESIZE_BOTTOMLEFT;
            case 12:
                return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
            }
        }

        auto* pui = static_cast<gitgud::ui::IUiBackend*>(_pData);

        if (pui && pui->IsDragRegion(static_cast<float>(_pP->x), static_cast<float>(_pP->y)))
        {
            return SDL_HITTEST_DRAGGABLE;
        }

        return SDL_HITTEST_NORMAL;
    }

    // "ctrl+shift+p", "f5", "escape", "ctrl+enter", "down" — the combo string
    // Lua's keymap matches on. Plain typing keys return "" (they belong to
    // whatever editbox has focus); a combo needs Ctrl or Alt, or is a function
    // key, Escape, an arrow, or Page Up/Down.
    std::string KeyCombo(const SDL_Keysym& _Key)
    {
        const bool bctrl = (_Key.mod & KMOD_CTRL) != 0;
        const bool balt = (_Key.mod & KMOD_ALT) != 0;
        const bool bshift = (_Key.mod & KMOD_SHIFT) != 0;
        const bool bfunction = _Key.sym >= SDLK_F1 && _Key.sym <= SDLK_F12;
        const bool bescape = _Key.sym == SDLK_ESCAPE;
        // Arrows and paging keys too: lists and the command palette move
        // their selection with them (editboxes still get them as well).
        const bool bnavigation = _Key.sym == SDLK_UP || _Key.sym == SDLK_DOWN ||
                                 _Key.sym == SDLK_PAGEUP || _Key.sym == SDLK_PAGEDOWN;
        if (!bctrl && !balt && !bfunction && !bescape && !bnavigation)
        {
            return {};
        }
        if (_Key.sym == SDLK_LCTRL || _Key.sym == SDLK_RCTRL || _Key.sym == SDLK_LALT ||
            _Key.sym == SDLK_RALT || _Key.sym == SDLK_LSHIFT || _Key.sym == SDLK_RSHIFT)
        {
            return {};
        }

        std::string name = SDL_GetKeyName(_Key.sym);
        std::transform(name.begin(), name.end(), name.begin(),
            [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
        if (name == "return")
        {
            name = "enter";
        }

        std::string combo;
        if (bctrl)
        {
            combo += "ctrl+";
        }
        if (balt)
        {
            combo += "alt+";
        }
        if (bshift)
        {
            combo += "shift+";
        }
        return combo + name;
    }

    // Decode SDL's UTF-8 text input into codepoints.
    template <typename Fn> void ForEachCodepoint(const char* _szText, Fn&& _Fn)
    {
        const unsigned char* pucs = reinterpret_cast<const unsigned char*>(_szText);
        while (*pucs)
        {
            unsigned int uicp = 0;
            int iextra = 0;

            if ((*pucs & 0x80) == 0x00)
            {
                uicp = *pucs;
            }
            else if ((*pucs & 0xE0) == 0xC0)
            {
                uicp = *pucs & 0x1F;
                iextra = 1;
            }
            else if ((*pucs & 0xF0) == 0xE0)
            {
                uicp = *pucs & 0x0F;
                iextra = 2;
            }
            else if ((*pucs & 0xF8) == 0xF0)
            {
                uicp = *pucs & 0x07;
                iextra = 3;
            }

            ++pucs;
            for (int ii = 0; ii < iextra && *pucs; ++ii, ++pucs)
            {
                uicp = (uicp << 6) | (*pucs & 0x3F);
            }
            _Fn(uicp);
        }
    }

} // namespace

int main(int /*argc*/, char* /*argv*/[])
{
    constexpr int ikWidth = 1360;
    constexpr int ikHeight = 860;

#if defined(_WIN32)
    // Built as a GUI-subsystem app (no console window). Reconnect stdio for
    // development: inherit the parent shell's console when launched from a
    // terminal, or force a dedicated one with GITGUD_CONSOLE=1.
    bool bhaveConsole = AttachConsole(ATTACH_PARENT_PROCESS) != 0;

    if (!bhaveConsole && std::getenv("GITGUD_CONSOLE"))
    {
        bhaveConsole = AllocConsole() != 0;
    }

    if (bhaveConsole)
    {
        FILE* punused;
        freopen_s(&punused, "CONOUT$", "w", stdout);
        freopen_s(&punused, "CONOUT$", "w", stderr);
    }
#endif

    // GITGUD_LOG=<file> sends all output (Lua errors, hot-reload notices) to
    // a file instead — useful when there's no console to watch.
    if (const char* szlogPath = std::getenv("GITGUD_LOG"))
    {
#if defined(_WIN32)
        // Opened share-friendly so the log can be read while the app runs.
        int ifd = -1;
        if (_sopen_s(&ifd, szlogPath, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_TEXT, _SH_DENYNO,
                _S_IREAD | _S_IWRITE) == 0)
        {
            _dup2(ifd, _fileno(stdout));
            _dup2(ifd, _fileno(stderr));
            _close(ifd);
        }
#else
        std::freopen(szlogPath, "w", stdout);
        std::freopen(szlogPath, "a", stderr);
#endif
        std::setvbuf(stdout, nullptr, _IONBF, 0);
        std::setvbuf(stderr, nullptr, _IONBF, 0);
    }

    // Symbolized stack trace + minidump if we ever crash.
    if (char* szexeDir = SDL_GetBasePath())
    {
        gitgud::platform::InstallCrashHandler(szexeDir);
        SDL_free(szexeDir);
    }

    // --- SDL + OpenGL window --------------------------------------------
    // The app draws its own title bar, so the OS frame is dropped. These hints
    // keep Windows treating the borderless window as a normal app window: real
    // resize borders, working Aero snap, and a maximize that respects the
    // taskbar. (Hint names spelled out: this vcpkg SDL2's headers predate the
    // macros.)
    SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "1");
    SDL_SetHint("SDL_BORDERLESS_RESIZABLE_STYLE", "1");

    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    SDL_Window* pwindow = SDL_CreateWindow("Gitgud", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        ikWidth, ikHeight,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_SHOWN | SDL_WINDOW_BORDERLESS);
    if (!pwindow)
    {
        std::fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    SDL_SetWindowMinimumSize(pwindow, 1140, 600);

    SDL_GLContext gl = SDL_GL_CreateContext(pwindow);
    if (!gl)
    {
        std::fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(pwindow);
        SDL_Quit();
        return 1;
    }

    SDL_GL_SetSwapInterval(1); // vsync: only paid when we actually draw
    SDL_StartTextInput();
    SDL_ShowCursor(SDL_DISABLE); // CEGUI draws its own cursor
    SDL_EventState(SDL_DROPFILE, SDL_ENABLE);

    // --- Subsystems ------------------------------------------------------
    gitgud::git::LibGit2 libgit2; // RAII global Init/Shutdown
    gitgud::app::EventBus bus;
    gitgud::app::TaskRunner tasks(bus);
    auto credentials = gitgud::platform::MakeCredentialStore();

    // Worker threads publish into the bus; wake the (possibly sleeping) main
    // loop so their results show up immediately.
    const Uint32 wakeEventType = SDL_RegisterEvents(1);
    bus.SetWakeCallback(
        [wakeEventType]()
        {
            SDL_Event wake{};
            wake.type = wakeEventType;
            SDL_PushEvent(&wake);
        });

    // Open the repo we're running against. Not being inside one isn't fatal:
    // the UI still comes up and offers Open/Init/clone. Absolute path so the
    // UI can show a real repository name instead of ".".
    std::optional<gitgud::git::Repository> repo;
    const std::string cwd = fs::current_path().string();
    try
    {
        repo.emplace(gitgud::git::Repository::Open(cwd));
    }
    catch (const gitgud::git::GitError& e)
    {
        std::fprintf(stderr, "[git] no repo at '%s': %s\n", cwd.c_str(), e.what());
    }

    // Resources live next to the exe (CMake copies them there); the cwd is
    // reserved for the repo the user opened, so resolve from the exe path.
    std::string resourceRoot = "resources";
    if (char* szbasePath = SDL_GetBasePath())
    {
        resourceRoot = std::string(szbasePath) + "resources";
        SDL_free(szbasePath);
    }

    // Window icon (taskbar, Alt-Tab) — the Jera-rune mark. The exe's own
    // icon resource (resources/icon/gitgud.rc) covers Explorer and pins;
    // this covers the live window. BMP because core SDL loads it dependency
    // free. Missing file is cosmetic, not fatal.
    if (SDL_Surface* piconSurface = SDL_LoadBMP((resourceRoot + "/icon/gitgud.bmp").c_str()))
    {
        SDL_SetWindowIcon(pwindow, piconSurface);
        SDL_FreeSurface(piconSurface);
    }

    auto ui = MakeUiBackend();

    gitgud::lua::LuaEngine lua;
    lua.Bind(repo ? &*repo : nullptr, &bus, ui.get(), &tasks, credentials.get());

    if (!lua.Initialize())
    {
        std::fprintf(stderr, "Lua Init failed\n");
        return 1;
    }
    lua.SetScriptRoot(resourceRoot + "/scripts");

    if (ui && !ui->Initialize(ikWidth, ikHeight, resourceRoot))
    {
        std::fprintf(stderr, "UI backend Init failed\n");
        return 1;
    }

    // Custom window chrome: the layout's title bar moves the window, the 8px
    // rim resizes it (see WindowHitTest above).
    SDL_SetWindowHitTest(pwindow, WindowHitTest, ui.get());

    // Every event — core ("status.changed", "fetch.done", ...) and widget
    // ("CommitButton.clicked", ...) — flows into Lua through one channel.
    bus.Subscribe(
        "*", [&](const gitgud::app::AppEvent& _Ev) { lua.Dispatch(_Ev.m_Type, _Ev.m_Detail); });

    if (ui)
    {
        ui->OnEvent([&](const gitgud::ui::WidgetEvent& _Ev)
            { lua.Dispatch(_Ev.m_WidgetId + "." + _Ev.m_Action, _Ev.m_Value); });
    }

    // Repo lifecycle requests raised from Lua (gitgud.openRepo/initRepo/
    // closeRepo). main owns the Repository, so the swap happens here, then
    // Lua is rebound and told to repaint.
    auto openRepoAt = [&](const std::string& _Path, bool _bInit)
    {
        try
        {
            if (_bInit)
            {
                repo.emplace(gitgud::git::Repository::Init(_Path));
            }
            else
            {
                repo.emplace(gitgud::git::Repository::Open(_Path));
            }

            lua.Bind(&*repo, &bus, ui.get(), &tasks, credentials.get());
            bus.Publish({"repo.changed", repo->WorkDir()});
        }
        catch (const gitgud::git::GitError& e)
        {
            bus.Publish({"repo.error", e.what()});
        }
    };

    bus.Subscribe("repo.openRequested",
        [&](const gitgud::app::AppEvent& _Ev) { openRepoAt(_Ev.m_Detail, false); });
    bus.Subscribe("repo.initRequested",
        [&](const gitgud::app::AppEvent& _Ev) { openRepoAt(_Ev.m_Detail, true); });
    bus.Subscribe("repo.closeRequested",
        [&](const gitgud::app::AppEvent&)
        {
            repo.reset();
            lua.Bind(nullptr, &bus, ui.get(), &tasks, credentials.get());
            bus.Publish({"repo.changed", ""});
        });

    // Window commands raised from Lua (the custom title bar's buttons emit
    // these). Close goes through SDL_QUIT so it exits the same path as the OS
    // close would. Maximize/restore state flows back to Lua via the
    // "window.state" events published from the SDL event loop below.
    bus.Subscribe(
        "window.minimize", [&](const gitgud::app::AppEvent&) { SDL_MinimizeWindow(pwindow); });
    bus.Subscribe("window.toggleMaximize",
        [&](const gitgud::app::AppEvent&)
        {
            if (SDL_GetWindowFlags(pwindow) & SDL_WINDOW_MAXIMIZED)
            {
                SDL_RestoreWindow(pwindow);
            }
            else
            {
                SDL_MaximizeWindow(pwindow);
            }
        });

    bus.Subscribe("window.close",
        [&](const gitgud::app::AppEvent&)
        {
            SDL_Event quit{};
            quit.type = SDL_QUIT;
            SDL_PushEvent(&quit);
        });

    const std::string mainScript = resourceRoot + "/scripts/main.lua";
    // GITGUD_SCRIPT=<file.lua> runs an extra script after main.lua - the
    // hook for automated UI tests (see gitgud.simulateClick/screenshot).
    const char* sztestScript = std::getenv("GITGUD_SCRIPT");
    auto loadUi = [&](const char* _szReason)
    {
        if (ui && !ui->LoadLayout(kMainLayout))
        {
            std::fprintf(stderr, "Failed to load %s\n", kMainLayout);
        }
        lua.RunFile(mainScript);
        if (sztestScript)
        {
            lua.RunFile(sztestScript);
        }
        bus.Publish({"app.started", _szReason});
    };

    // gitgud.screenshot(path): capture the next frame we draw.
    std::string pendingScreenshot;
    bus.Subscribe("debug.screenshot",
        [&](const gitgud::app::AppEvent& _Ev) { pendingScreenshot = _Ev.m_Detail; });
    loadUi("");

    std::printf("Gitgud: window + subsystems online. Close the window to exit.\n");

    glClearColor(0.055f, 0.039f, 0.102f, 1.0f); // matches the skin's canvas

    ResourceWatcher watcher(resourceRoot);
    Uint32 lastWatchTick = SDL_GetTicks();
    Uint32 lastInputTick = SDL_GetTicks();
    Uint32 lastPulseTick = SDL_GetTicks();
    bool bredraw = true;

    // After input, keep ticking at display rate for a moment so hover states,
    // tooltips, and caret blinks animate; then fall back to a slow idle tick.
    constexpr Uint32 kActiveWindowMs = 1500;
    constexpr int ikActiveTickMs = 16;
    constexpr int ikIdleTickMs = 250;
    constexpr Uint32 kWatchIntervalMs = 1000;

    auto handleEvent = [&](const SDL_Event& _Ev, bool& _bRunning)
    {
        switch (_Ev.type)
        {
        case SDL_QUIT:
            _bRunning = false;
            break;

        case SDL_WINDOWEVENT:
            bredraw = true;
            if (_Ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED && ui)
            {
                ui->Resize(_Ev.window.data1, _Ev.window.data2);
                bus.Publish({"window.resized",
                    std::to_string(_Ev.window.data1) + "x" + std::to_string(_Ev.window.data2)});
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_MAXIMIZED)
            {
                bus.Publish({"window.state", "maximized"});
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_RESTORED)
            {
                bus.Publish({"window.state", "restored"});
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_FOCUS_GAINED)
            {
                // Coming back from an editor/terminal: refresh, like GitHub
                // Desktop does.
                bus.Publish({"app.focusGained", ""});
            }
            break;

        case SDL_MOUSEMOTION:
            if (ui)
            {
                ui->InjectMousePosition(
                    static_cast<float>(_Ev.motion.x), static_cast<float>(_Ev.motion.y));
            }
            break;

        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP:
            if (ui)
            {
                ui->InjectMouseButton(_Ev.button.button, _Ev.type == SDL_MOUSEBUTTONDOWN);
            }
            break;

        case SDL_MOUSEWHEEL:
            if (ui)
            {
                // One wheel notch is +/-1 in SDL; pass it through unscaled
                // (CEGUI widgets already multiply by their own step size).
                float fdelta = static_cast<float>(_Ev.wheel.y);
                if (_Ev.wheel.direction == SDL_MOUSEWHEEL_FLIPPED)
                {
                    fdelta = -fdelta;
                }
                ui->InjectMouseScroll(fdelta);
            }
            break;

        case SDL_KEYDOWN:
        {
            // Shortcuts go to Lua's keymap (resources/scripts/core/keys.lua)
            // AND to the UI, so editboxes keep their own Ctrl+C/V/A handling.
            const std::string combo = KeyCombo(_Ev.key.keysym);
            if (!combo.empty())
            {
                bus.Publish({"key", combo});
            }
            if (ui)
            {
                ui->InjectKey(_Ev.key.keysym.scancode, true);
            }
            break;
        }

        case SDL_KEYUP:
            if (ui)
            {
                ui->InjectKey(_Ev.key.keysym.scancode, false);
            }
            break;

        case SDL_TEXTINPUT:
            if (ui)
            {
                ForEachCodepoint(_Ev.text.text, [&](unsigned int _Cp) { ui->InjectChar(_Cp); });
            }
            break;

        case SDL_DROPFILE:
            // Dropping a folder on the window adds it as a repository.
            if (_Ev.drop.file)
            {
                bus.Publish({"app.fileDropped", _Ev.drop.file});
                SDL_free(_Ev.drop.file);
            }
            break;

        default:
            break;
        }

        const bool binput = _Ev.type == SDL_MOUSEMOTION || _Ev.type == SDL_MOUSEBUTTONDOWN ||
                            _Ev.type == SDL_MOUSEBUTTONUP || _Ev.type == SDL_MOUSEWHEEL ||
                            _Ev.type == SDL_KEYDOWN || _Ev.type == SDL_KEYUP ||
                            _Ev.type == SDL_TEXTINPUT;
        if (binput)
        {
            lastInputTick = SDL_GetTicks();
            bredraw = true;
        }
    };

    // --- Main loop -------------------------------------------------------
    bool brunning = true;
    while (brunning)
    {
        // How long may we sleep before something needs attention?
        const Uint32 nowTick = SDL_GetTicks();
        int itimeout = (nowTick - lastInputTick < kActiveWindowMs) ? ikActiveTickMs : ikIdleTickMs;
        if (bredraw || (ui && ui->NeedsRedraw()))
        {
            itimeout = 0;
        }
        const int itimerWait = lua.MillisecondsUntilNextTimer();
        if (itimerWait >= 0)
        {
            itimeout = std::min(itimeout, itimerWait);
        }
        const Uint32 sinceWatch = nowTick - lastWatchTick;
        itimeout = std::min(itimeout,
            sinceWatch >= kWatchIntervalMs ? 0 : static_cast<int>(kWatchIntervalMs - sinceWatch));

        SDL_Event ev;
        if (SDL_WaitEventTimeout(&ev, itimeout))
        {
            handleEvent(ev, brunning);
            while (SDL_PollEvent(&ev))
            {
                handleEvent(ev, brunning);
            }
        }

        // Deliver queued events (worker completions, Lua-raised intents, ...)
        // and due timers on this — the UI — thread.
        if (bus.Drain() > 0)
        {
            bredraw = true;
        }
        if (lua.Tick())
        {
            bus.Drain();
            bredraw = true;
        }

        // Hot-reload: poll the resource files ~once a second; on any change
        // reload the layout, restart the script VM, and re-run main.lua.
        const Uint32 afterTick = SDL_GetTicks();
        if (afterTick - lastWatchTick >= kWatchIntervalMs)
        {
            lastWatchTick = afterTick;
            if (watcher.Changed())
            {
                std::printf("[hot-reload] resources changed; reloading UI\n");
                lua.Reset();
                loadUi("hot-reload");
                bus.Drain();
                bredraw = true;
            }
        }

        if (!ui)
        {
            continue;
        }

        // Advance CEGUI's clock (caret blink, tooltips, animations); it marks
        // itself dirty when that changes anything visible.
        ui->Update(static_cast<float>(afterTick - lastPulseTick) / 1000.0f);
        lastPulseTick = afterTick;

        if (bredraw || ui->NeedsRedraw() || !pendingScreenshot.empty())
        {
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            ui->Render();

            if (!pendingScreenshot.empty())
            {
                int iw = 0;
                int ih = 0;
                SDL_GL_GetDrawableSize(pwindow, &iw, &ih);
                gitgud::imaging::Image shot;
                shot.m_iWidth = iw;
                shot.m_iHeight = ih;
                shot.m_Rgba.resize(static_cast<std::size_t>(iw) * ih * 4);
                glReadPixels(0, 0, iw, ih, GL_RGBA, GL_UNSIGNED_BYTE, shot.m_Rgba.data());

                // GL rows run bottom-up; PNG rows top-down.
                const std::size_t row = static_cast<std::size_t>(iw) * 4;
                for (int y = 0; y < ih / 2; ++y)
                {
                    std::swap_ranges(shot.m_Rgba.begin() + y * row,
                        shot.m_Rgba.begin() + (y + 1) * row,
                        shot.m_Rgba.begin() + (ih - 1 - y) * row);
                }
                for (std::size_t i = 3; i < shot.m_Rgba.size(); i += 4)
                {
                    shot.m_Rgba[i] = 255;
                }

                const bool bsaved = gitgud::imaging::WritePng(pendingScreenshot, shot);
                bus.Publish({bsaved ? "debug.screenshotSaved" : "debug.screenshotFailed",
                    pendingScreenshot});
                pendingScreenshot.clear();
            }

            SDL_GL_SwapWindow(pwindow);
            bredraw = false;
        }
    }

    // --- Teardown (RAII handles the rest) --------------------------------
    if (ui)
    {
        ui->Shutdown();
    }

    SDL_GL_DeleteContext(gl);
    SDL_DestroyWindow(pwindow);
    SDL_Quit();
    return 0;
}
