// -----------------------------------------------------------------------------
// Gitgud — entry point.
//
// The C++ side owns the subsystems (SDL windows, Repository, EventBus,
// TaskRunner, credential store, UI backend, Lua VM) and the main loop. ALL
// view logic lives in Lua; the widget tree is XML layouts; the skin is
// resources/schemes + resources/looknfeel. C++ forwards every event (core +
// widget + keyboard) into Lua and otherwise stays out of the way — that split
// is what makes the UI fully moddable without a recompile (docs/MODDING.md).
//
// Which Lua + XML runs is a user-interface package (app/UiPackages.h): the
// GitGud UI is resources/scripts + resources/layouts, alternatives live in
// resources/uis/<id>/ or anywhere on disk. AppShell below starts the chosen
// one (the picker on first launch), switches between them, and opens the
// pop-out windows scripts ask for — extra OS windows sharing the main
// window's GL context, each drawing its own widget tree.
//
// The loop renders on demand: it sleeps in SDL_WaitEventTimeout until input,
// a worker-thread event, a Lua timer, or a UI animation needs a frame, so an
// idle window costs (almost) nothing.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <SDL.h>
#include <SDL_opengl.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN // SDL.h may already have defined it
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <SDL_syswm.h>
#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <sys/stat.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#endif

#include "agent/ToolServer.h"
#include "app/EventBus.h"
#include "app/IAppHost.h"
#include "app/Profiler.h"
#include "app/StallWatchdog.h"
#include "app/TaskRunner.h"
#include "app/UiPackages.h"
#include "speech/LocalEngine.h"
#include "app/Updater.h"
#include "git/Repository.h"
#include "imaging/ImageDiff.h"
#include "lua/LuaBindings.h"
#include "lua/LuaEngine.h"
#include "platform/Attention.h"
#include "platform/CrashHandler.h"
#include "platform/ICredentialStore.h"
#include "platform/MacWindow.h"
#include "platform/Process.h"
#include "platform/Relaunch.h"
#include "platform/Shell.h"
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

    // The most recently opened repository, reopened at the next launch. One
    // UTF-8 path in the config folder, shared by every UI package.
    constexpr const char* kLastRepoFile = "last-repo";

    std::string ReadLastRepo()
    {
        std::ifstream in(
            fs::u8path(gitgud::platform::ConfigDirectory()) / kLastRepoFile, std::ios::binary);
        std::string path;
        std::getline(in, path);
        while (!path.empty() && (path.back() == '\r' || path.back() == ' '))
        {
            path.pop_back();
        }
        return path;
    }

    void WriteLastRepo(const std::string& _Path)
    {
        const fs::path dir = fs::u8path(gitgud::platform::ConfigDirectory());
        std::error_code ec;
        fs::create_directories(dir, ec);
        std::ofstream out(dir / kLastRepoFile, std::ios::binary | std::ios::trunc);
        out << _Path << "\n";
    }

    // The Git and P4 tools for Claude Code: a pipe for gitgud-mcp (next to
    // this exe) and, in the config folder, the MCP config sessions get. Made
    // when the first session asks, never for an interface that starts none
    // (only the Bragi interface sets up anything of its own).
    void StartTools(gitgud::agent::ToolServer& _Tools)
    {
        const std::string pipe = gitgud::agent::ToolServer::DefaultPipeName();
#if defined(_WIN32)
        const char* szprogram = "gitgud-mcp.exe";
#else
        const char* szprogram = "gitgud-mcp";
#endif
        const std::string program =
            (fs::u8path(gitgud::platform::ExecutableDirectory()) / szprogram).u8string();
        const std::string config = (fs::u8path(gitgud::platform::ConfigDirectory()) / "mcp" /
                                    (pipe.substr(pipe.rfind('\\') + 1) + ".json"))
                                       .u8string();
        _Tools.StartOnDemand(pipe, program, config);
    }

    // Watches the UI resource files and reports when they changed: the
    // trigger for hot-reload (edit the XML/Lua, see it live, no restart).
    // Watches the base resources and the running UI package's folder.
    //
    // A copy writes many files over a moment (a running copy is updated by
    // copying its resources folder over), so the reload waits until nothing
    // has changed for kSettleMs: one reload per copy, never one per file or
    // one in the middle of it. The program's own files
    // (the exe and its libraries) are watched the same way, but those can't
    // be reloaded: a change to them is only reported.
    class ResourceWatcher
    {
      public:
        static constexpr Uint32 kSettleMs = 1500;

        void SetRoots(std::vector<std::string> _Roots)
        {
            // The GitGud UI's package root is the base root: scan it once.
            std::sort(_Roots.begin(), _Roots.end());
            _Roots.erase(std::unique(_Roots.begin(), _Roots.end()), _Roots.end());
            m_Roots = std::move(_Roots);
            m_Resources.Reset(ScanResources(false));
            m_uiLoaded = ScanResources(true);
        }

        void SetProgramDirectory(std::string _Directory)
        {
            m_ProgramDir = std::move(_Directory);
            m_Program.Reset(ScanProgram());
        }

        // Scan once (every watch interval). True when the resources changed
        // and have been still for kSettleMs since. The listing's times can
        // lag behind the files' own (NTFS updates them lazily), so a copy
        // made just before the UI loaded can show up as a change seconds
        // later: a settled change is checked against the files' own times
        // as they were at load, and one that isn't real reloads nothing.
        bool ResourcesSettled(Uint32 _uNow)
        {
            if (!m_Resources.Update(ScanResources(false), _uNow))
            {
                return false;
            }
            const std::uint64_t uiexact = ScanResources(true);
            if (uiexact == m_uiLoaded)
            {
                return false;
            }
            m_uiLoaded = uiexact;
            return true;
        }

        // Likewise for the program's files.
        bool ProgramSettled(Uint32 _uNow)
        {
            return !m_ProgramDir.empty() && m_Program.Update(ScanProgram(), _uNow);
        }

        // A change was seen and the files haven't settled yet: scan sooner.
        bool Pending() const
        {
            return m_Resources.m_bPending || m_Program.m_bPending;
        }

      private:
        // One fingerprint's state: the one acted on, the latest seen, and
        // when that last changed.
        struct Settling
        {
            std::uint64_t m_uiActed = 0;
            std::uint64_t m_uiLatest = 0;
            Uint32 m_uChangedAt = 0;
            bool m_bPending = false;

            void Reset(std::uint64_t _uiNow)
            {
                m_uiActed = m_uiLatest = _uiNow;
                m_bPending = false;
            }

            bool Update(std::uint64_t _uiNow, Uint32 _uTick)
            {
                if (_uiNow != m_uiLatest)
                {
                    m_uiLatest = _uiNow;
                    m_uChangedAt = _uTick;
                    m_bPending = _uiNow != m_uiActed; // changed back: nothing to do
                    return false;
                }
                if (m_bPending && _uTick - m_uChangedAt >= kSettleMs)
                {
                    m_bPending = false;
                    m_uiActed = _uiNow;
                    return true;
                }
                return false;
            }
        };

        // FNV-1a over a file's path and modification time. The time comes
        // from the directory listing itself, so there is no extra file
        // system call per file, and nothing is allocated per file; unless
        // `_bExact`, which asks the file.
        static void Mix(std::uint64_t& _uiSig, const fs::directory_entry& _Entry, bool _bExact = false)
        {
            std::error_code tec;
            const auto t = _bExact ? fs::last_write_time(_Entry.path(), tec) : _Entry.last_write_time(tec);
            if (tec)
            {
                return;
            }
            auto mix = [&_uiSig](const void* _pData, std::size_t _uSize)
            {
                const auto* pbytes = static_cast<const unsigned char*>(_pData);
                for (std::size_t ui = 0; ui < _uSize; ++ui)
                {
                    _uiSig = (_uiSig ^ pbytes[ui]) * 1099511628211ull;
                }
            };
            const auto& path = _Entry.path().native();
            mix(path.data(), path.size() * sizeof(path[0]));
            const auto ticks = t.time_since_epoch().count();
            mix(&ticks, sizeof(ticks));
        }

        // A cheap fingerprint: a hash of every watched file's path + mtime,
        // recursively (layouts and scripts live in sub-folders). Prompts and
        // imagesets count: scripts read prompts afresh after a reload, and
        // the skin reloads changed imagesets.
        std::uint64_t ScanResources(bool _bExact) const
        {
            std::uint64_t sig = 14695981039346656037ull;
            for (const std::string& root : m_Roots)
            {
                for (const char* szsub : {"/layouts", "/scripts", "/looknfeel", "/schemes",
                         "/imagesets", "/prompts", "/themes"})
                {
                    std::error_code ec;
                    fs::recursive_directory_iterator it(fs::u8path(root + szsub), ec);
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
                        Mix(sig, *it, _bExact);
                    }
                }
            }
            return sig;
        }

        // The exe and its libraries, beside it (not sub-folders: resources
        // live there).
        std::uint64_t ScanProgram() const
        {
            std::uint64_t sig = 14695981039346656037ull;
            std::error_code ec;
            for (fs::directory_iterator it(fs::u8path(m_ProgramDir), ec), end; !ec && it != end;
                it.increment(ec))
            {
                std::string ext = it->path().extension().u8string();
                std::transform(ext.begin(), ext.end(), ext.begin(),
                    [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
                if (ext == ".exe" || ext == ".dll" || ext == ".so" || ext == ".dylib")
                {
                    Mix(sig, *it);
                }
            }
            return sig;
        }

        std::vector<std::string> m_Roots;
        std::string m_ProgramDir;
        Settling m_Resources;
        Settling m_Program;
        std::uint64_t m_uiLoaded = 0; // the files' own times when the UI loaded
    };

    // GITGUD_PERF=<ms>: log every main-loop pass that takes at least that
    // long, split into its phases, so stalls can be traced to their source.
    // Slow Lua handlers and timers are reported by the Lua engine itself.
    class FrameProfiler
    {
      public:
        explicit FrameProfiler(int _iThresholdMs) : m_iThresholdMs(_iThresholdMs)
        {
        }

        bool Enabled() const
        {
            return m_iThresholdMs > 0;
        }

        void Begin()
        {
            if (Enabled())
            {
                m_Phases.clear();
                m_Start = m_Last = Clock::now();
            }
        }

        // Close the phase that ran since the previous mark.
        void Mark(const char* _szPhase)
        {
            if (Enabled())
            {
                const auto now = Clock::now();
                m_Phases.emplace_back(_szPhase, Ms(m_Last, now));
                m_Last = now;
            }
        }

        void End(const char* _szWhat = "frame")
        {
            if (!Enabled())
            {
                return;
            }
            // Time blocked in the buffer swap (vsync) isn't work: leave it
            // out of the threshold test.
            const double ftotal = Ms(m_Start, Clock::now());
            double fswap = 0.0;
            for (const auto& [szname, fms] : m_Phases)
            {
                fswap += std::strcmp(szname, "swap") == 0 ? fms : 0.0;
            }
            if (ftotal - fswap < m_iThresholdMs)
            {
                return;
            }
            std::string line;
            for (const auto& [szname, fms] : m_Phases)
            {
                if (fms >= 1.0)
                {
                    char buf[64];
                    std::snprintf(buf, sizeof(buf), "  %s %.1f", szname, fms);
                    line += buf;
                }
            }
            std::printf("[perf] %s %.1f ms:%s\n", _szWhat, ftotal, line.c_str());
        }

      private:
        using Clock = std::chrono::steady_clock;

        static double Ms(Clock::time_point _From, Clock::time_point _To)
        {
            return std::chrono::duration<double, std::milli>(_To - _From).count();
        }

        int m_iThresholdMs;
        Clock::time_point m_Start;
        Clock::time_point m_Last;
        std::vector<std::pair<const char*, double>> m_Phases;
    };

    int PerfThresholdFromEnv()
    {
        const char* szvalue = std::getenv("GITGUD_PERF");
        if (!szvalue || !*szvalue)
        {
            return 0;
        }
        const int ims = std::atoi(szvalue);
        return ims > 0 ? ims : 25;
    }

    // A UI test run that stays out of the way (test windows
    // took the screen): its windows open behind the others, never come
    // forward, and never take focus. The runner sets GITGUD_TEST_BACKGROUND
    // (and SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN) alongside GITGUD_SCRIPT.
    bool TestInBackground()
    {
        static const bool bbackground = std::getenv("GITGUD_SCRIPT") && std::getenv("GITGUD_TEST_BACKGROUND");
        return bbackground;
    }

    // Flags for every window: OpenGL, and on macOS a full-resolution drawable
    // on Retina displays (the UI is laid out in points either way).
    constexpr Uint32 kWindowFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_SHOWN
#if defined(__APPLE__)
                                    | SDL_WINDOW_ALLOW_HIGHDPI
#endif
        ;

    // GITGUD_PIXEL_RATIO=2 shows on any display what a Retina one would: the
    // UI is laid out in the drawable's pixels / 2 and drawn at 2 pixels per
    // unit, so it comes out at half size. For checking Retina rendering
    // without a Retina display. 0 when not set.
    float ForcedPixelRatio()
    {
        static const float s_fForced = []
        {
            const char* szforced = std::getenv("GITGUD_PIXEL_RATIO");
            return szforced ? std::max(0.0f, static_cast<float>(std::atof(szforced))) : 0.0f;
        }();
        return s_fForced;
    }

    // Drawable pixels per window point: 2 on a Retina display, else 1.
    float PixelRatio(SDL_Window* _pWindow)
    {
        if (ForcedPixelRatio() > 0.0f)
        {
            return ForcedPixelRatio();
        }
        int iw = 0;
        int ih = 0;
        int idw = 0;
        int idh = 0;
        SDL_GetWindowSize(_pWindow, &iw, &ih);
        SDL_GL_GetDrawableSize(_pWindow, &idw, &idh);
        return iw > 0 && idw > 0 ? static_cast<float>(idw) / static_cast<float>(iw) : 1.0f;
    }

    // The size the UI is laid out at: the window's size in points (with
    // GITGUD_PIXEL_RATIO, its drawable's size over that ratio).
    void LayoutSize(SDL_Window* _pWindow, int& _iWidth, int& _iHeight)
    {
        const float fforced = ForcedPixelRatio();
        if (fforced > 0.0f)
        {
            SDL_GL_GetDrawableSize(_pWindow, &_iWidth, &_iHeight);
            _iWidth = static_cast<int>(std::lround(static_cast<float>(_iWidth) / fforced));
            _iHeight = static_cast<int>(std::lround(static_cast<float>(_iHeight) / fforced));
            return;
        }
        SDL_GetWindowSize(_pWindow, &_iWidth, &_iHeight);
    }

    // Layout units per window point, for mouse positions (1 unless
    // GITGUD_PIXEL_RATIO is set).
    float InputScale(SDL_Window* _pWindow)
    {
        if (ForcedPixelRatio() <= 0.0f || !_pWindow)
        {
            return 1.0f;
        }
        int iw = 0;
        int ih = 0;
        int ilayoutWidth = 0;
        SDL_GetWindowSize(_pWindow, &iw, &ih);
        LayoutSize(_pWindow, ilayoutWidth, ih);
        return iw > 0 ? static_cast<float>(ilayoutWidth) / static_cast<float>(iw) : 1.0f;
    }

    // SDL hit test for the borderless window: it decides, per mouse position,
    // whether the point acts as a Resize border, a title-bar drag area, or plain
    // client area. Edges/corners Resize; anything the UI marks as a drag region
    // (layout widgets carrying the AppDrag user string) moves the window — which
    // also gives us native Aero snap and double-click-to-maximize for free.
    // The mouse is on the borderless window's resize rim (WindowHitTest);
    // reset when it leaves the window.
    bool g_bOnResizeRim = false;

    SDL_HitTestResult WindowHitTest(SDL_Window* _pWin, const SDL_Point* _pP, void* _pData)
    {
        constexpr int ikEdge = 8; // Resize grip thickness, px
        auto* pui = static_cast<gitgud::ui::IUiBackend*>(_pData);

        // On the resize rim Windows shows its own resize arrows; hide the
        // cursor the UI draws so it doesn't linger next to them.
        const auto onRim = [pui](bool _bOn)
        {
            if (pui && _bOn != g_bOnResizeRim)
            {
                pui->SetCursorVisible("", !_bOn);
            }
            g_bOnResizeRim = _bOn;
        };

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
            onRim(ieVal != 0);

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
        else
        {
            onRim(false);
        }

        const float fscale = InputScale(_pWin);
        if (pui && pui->IsDragRegion(static_cast<float>(_pP->x) * fscale,
                       static_cast<float>(_pP->y) * fscale))
        {
            return SDL_HITTEST_DRAGGABLE;
        }

        return SDL_HITTEST_NORMAL;
    }

    // "ctrl+shift+p", "f5", "escape", "ctrl+enter", "down" — the combo string
    // Lua's keymap matches on. Plain typing keys return "" (they belong to
    // whatever editbox has focus); a combo needs Ctrl or Alt, or is a function
    // key, Escape, an arrow, or Page Up/Down. On macOS Command counts as Ctrl,
    // so every binding works with the Mac's usual key (Control still does too).
    std::string KeyCombo(const SDL_Keysym& _Key)
    {
#if defined(__APPLE__)
        const bool bctrl = (_Key.mod & (KMOD_CTRL | KMOD_GUI)) != 0;
#else
        const bool bctrl = (_Key.mod & KMOD_CTRL) != 0;
#endif
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
            _Key.sym == SDLK_RALT || _Key.sym == SDLK_LSHIFT || _Key.sym == SDLK_RSHIFT ||
            _Key.sym == SDLK_LGUI || _Key.sym == SDLK_RGUI)
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

    // The key the UI sees. On macOS Command is passed on as Control, so
    // editboxes copy, paste, cut, undo and select all with Command.
    int UiScancode(SDL_Scancode _Scancode)
    {
#if defined(__APPLE__)
        if (_Scancode == SDL_SCANCODE_LGUI)
        {
            return SDL_SCANCODE_LCTRL;
        }
        if (_Scancode == SDL_SCANCODE_RGUI)
        {
            return SDL_SCANCODE_RCTRL;
        }
#endif
        return _Scancode;
    }

#if defined(__APPLE__)
    // macOS doesn't reliably zoom a window without a title bar, so the
    // borderless main window zooms here: to its display's usable area (below
    // the menu bar, beside the Dock), and back to where it was. Publishes
    // "window.state" like a native maximize would.
    void ToggleZoom(SDL_Window* _pWindow, SDL_Rect& _Restore, gitgud::app::EventBus& _Bus)
    {
        SDL_Rect usable{};
        const int idisplay = SDL_GetWindowDisplayIndex(_pWindow);
        if (idisplay < 0 || SDL_GetDisplayUsableBounds(idisplay, &usable) != 0)
        {
            return;
        }
        SDL_Rect now{};
        SDL_GetWindowPosition(_pWindow, &now.x, &now.y);
        SDL_GetWindowSize(_pWindow, &now.w, &now.h);
        const bool bzoomed = std::abs(now.x - usable.x) <= 1 && std::abs(now.y - usable.y) <= 1 &&
                             std::abs(now.w - usable.w) <= 1 && std::abs(now.h - usable.h) <= 1;
        if (bzoomed && _Restore.w > 0)
        {
            SDL_SetWindowSize(_pWindow, _Restore.w, _Restore.h);
            SDL_SetWindowPosition(_pWindow, _Restore.x, _Restore.y);
            _Bus.Publish({"window.state", "restored"});
        }
        else
        {
            _Restore = now;
            SDL_SetWindowPosition(_pWindow, usable.x, usable.y);
            SDL_SetWindowSize(_pWindow, usable.w, usable.h);
            _Bus.Publish({"window.state", "maximized"});
        }
    }
#endif

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

    // The application shell scripts talk to (gitgud.openWindow, switchUi, ...):
    // owns the pop-out OS windows and which UI package runs. Requests that
    // would tear down widgets (closing a window, switching UI) can arrive in
    // the middle of that window's own event handler, so they are queued and
    // carried out by ProcessPending() between events.
    // The theme a UI package runs in: the remembered one, or GITGUD_THEME
    // (tests, screenshots) when the package has a theme by that name.
    std::string ActiveTheme(const gitgud::app::UiPackage& _Package)
    {
        if (const char* szenv = std::getenv("GITGUD_THEME"); szenv && *szenv)
        {
            const std::vector<std::string> themes = gitgud::app::ListThemes(_Package);
            if (std::find(themes.begin(), themes.end(), szenv) != themes.end())
            {
                return szenv;
            }
        }
        return gitgud::app::ResolveTheme(_Package, gitgud::platform::ConfigDirectory());
    }

    class AppShell final : public gitgud::app::IAppHost
    {
      public:
        struct PopOut
        {
            SDL_Window* m_pWindow = nullptr;
            bool m_bRedraw = true;
            bool m_bResizePending = false;
            int m_iWidth = 0; // the size the UI was last laid out for
            int m_iHeight = 0;
            float m_fRatio = 1.0f; // drawable pixels per point (PixelRatio)
        };

        AppShell(SDL_Window* _pMain, SDL_GLContext _Gl, gitgud::ui::IUiBackend* _pUi,
            gitgud::app::EventBus& _Bus, std::string _ResourceRoot)
            : m_pMain(_pMain), m_Gl(_Gl), m_pUi(_pUi), m_Bus(_Bus),
              m_ResourceRoot(std::move(_ResourceRoot))
        {
        }

        // Pick the UI to start with: GITGUD_UI, else the remembered choice,
        // else (first launch, or the remembered one is gone) the picker.
        void ChooseStartupUi()
        {
            const std::string stored =
                gitgud::app::ReadUiChoice(gitgud::platform::ConfigDirectory());
            m_bFirstLaunch = stored.empty();

            std::string spec = stored;
            if (const char* szenv = std::getenv("GITGUD_UI"))
            {
                spec = szenv;
            }
            std::optional<gitgud::app::UiPackage> package;
            if (!spec.empty())
            {
                package = gitgud::app::ResolveUiPackage(spec, m_ResourceRoot);
                if (!package)
                {
                    std::fprintf(stderr, "[ui] '%s' is not a usable UI package\n", spec.c_str());
                }
            }
            if (!package)
            {
                package = gitgud::app::ResolveUiPackage(gitgud::app::kUiPickerId, m_ResourceRoot);
            }
            if (!package)
            {
                package = gitgud::app::ResolveUiPackage(gitgud::app::kDefaultUiId, m_ResourceRoot);
            }
            m_Current = package.value_or(gitgud::app::UiPackage{});
        }

        // ---- IAppHost: pop-out windows --------------------------------------------

        bool OpenWindow(const gitgud::app::WindowSpec& _Spec, std::string& _Error) override
        {
            if (const auto it = m_PopOuts.find(_Spec.m_Id); it != m_PopOuts.end())
            {
                m_Closing.erase(
                    std::remove(m_Closing.begin(), m_Closing.end(), _Spec.m_Id), m_Closing.end());
                if (!TestInBackground())
                {
                    SDL_RaiseWindow(it->second.m_pWindow);
                }
                return true;
            }
            if (!m_pUi)
            {
                _Error = "No user interface";
                return false;
            }

            SDL_Window* pwindow = SDL_CreateWindow(_Spec.m_Title.c_str(), SDL_WINDOWPOS_CENTERED,
                SDL_WINDOWPOS_CENTERED, _Spec.m_iWidth, _Spec.m_iHeight, kWindowFlags);
            if (!pwindow)
            {
                _Error = SDL_GetError();
                return false;
            }
            SDL_SetWindowMinimumSize(pwindow, _Spec.m_iMinWidth, _Spec.m_iMinHeight);
            SetIcon(pwindow);
            if (TestInBackground())
            {
                gitgud::platform::SendToBack(pwindow);
            }

            SDL_GL_MakeCurrent(pwindow, m_Gl);
            int iw = 0;
            int ih = 0;
            LayoutSize(pwindow, iw, ih);
            const bool bcreated = m_pUi->CreateSurface(_Spec.m_Id, iw, ih, _Spec.m_Layout);
            const float fratio = PixelRatio(pwindow);
            if (bcreated)
            {
                m_pUi->SetPixelRatio(_Spec.m_Id, fratio);
            }
            SDL_GL_MakeCurrent(m_pMain, m_Gl);
            if (!bcreated)
            {
                SDL_DestroyWindow(pwindow);
                _Error = "Could not load layout '" + _Spec.m_Layout + "'";
                return false;
            }

            m_PopOuts[_Spec.m_Id] = PopOut{pwindow, true, false, iw, ih, fratio};
            UpdateSwapInterval();
            return true;
        }

        void CloseWindow(const std::string& _Id) override
        {
            if (m_PopOuts.count(_Id) != 0 &&
                std::find(m_Closing.begin(), m_Closing.end(), _Id) == m_Closing.end())
            {
                m_Closing.push_back(_Id);
            }
        }

        void SetWindowTitle(const std::string& _Id, const std::string& _Title) override
        {
            if (SDL_Window* pwindow = WindowOf(_Id))
            {
                SDL_SetWindowTitle(pwindow, _Title.c_str());
            }
        }

        void FocusWindow(const std::string& _Id) override
        {
            if (SDL_Window* pwindow = WindowOf(_Id); pwindow && !TestInBackground())
            {
                SDL_RestoreWindow(pwindow);
                SDL_RaiseWindow(pwindow);
            }
        }

        std::vector<std::string> OpenWindows() const override
        {
            std::vector<std::string> out;
            for (const auto& [id, popOut] : m_PopOuts)
            {
                if (std::find(m_Closing.begin(), m_Closing.end(), id) == m_Closing.end())
                {
                    out.push_back(id);
                }
            }
            return out;
        }

        void SetMainWindowBordered(bool _bBordered) override
        {
            if (_bBordered == m_bBordered)
            {
                return;
            }
            m_bBordered = _bBordered;
            SDL_SetWindowBordered(m_pMain, _bBordered ? SDL_TRUE : SDL_FALSE);
#if defined(__APPLE__)
            gitgud::platform::AllowMinimize(m_pMain);
#endif
            // A native frame does its own dragging and resizing.
            SDL_SetWindowHitTest(m_pMain, _bBordered ? nullptr : WindowHitTest, m_pUi);
        }

        bool MainWindowBordered() const
        {
            return m_bBordered;
        }

        // A new main window in place of the old one (renewWindow in main):
        // the frame's dragging and resizing, and the icon, go with it.
        void ReplaceMainWindow(SDL_Window* _pWindow)
        {
            m_pMain = _pWindow;
            SetIcon(m_pMain);
#if defined(__APPLE__)
            gitgud::platform::AllowMinimize(m_pMain);
#endif
            SDL_SetWindowHitTest(m_pMain, m_bBordered ? nullptr : WindowHitTest, m_pUi);
        }

        // ---- IAppHost: UI packages --------------------------------------------------

        const gitgud::app::UiPackage& CurrentUi() const override
        {
            return m_Current;
        }

        std::string PreviousUi() const override
        {
            return m_Previous;
        }

        std::vector<gitgud::app::UiPackage> AvailableUis() const override
        {
            auto out = gitgud::app::ListUiPackages(m_ResourceRoot);
            // A custom package that is running (or remembered) is a choice too.
            const std::string stored =
                gitgud::app::ReadUiChoice(gitgud::platform::ConfigDirectory());
            for (const std::string& spec : {m_Current.m_Id, stored})
            {
                if (spec.rfind("path:", 0) != 0)
                {
                    continue;
                }
                const bool bknown = std::any_of(out.begin(), out.end(),
                    [&](const gitgud::app::UiPackage& _P) { return _P.m_Id == spec; });
                if (!bknown)
                {
                    if (auto package = gitgud::app::ResolveUiPackage(spec, m_ResourceRoot))
                    {
                        out.push_back(*package);
                    }
                }
            }
            return out;
        }

        bool RequestUiSwitch(
            const std::string& _Spec, bool _bRemember, std::string& _Error) override
        {
            auto package = gitgud::app::ResolveUiPackage(_Spec, m_ResourceRoot);
            if (!package)
            {
                _Error = "'" + _Spec +
                         "' isn't a UI package: it needs scripts/main.lua and layouts/main.xml";
                return false;
            }
            if (_bRemember && package->m_Id != gitgud::app::kUiPickerId)
            {
                if (!gitgud::app::WriteUiChoice(gitgud::platform::ConfigDirectory(), package->m_Id))
                {
                    _Error = "Could not save the choice";
                    return false;
                }
                m_bFirstLaunch = false;
            }
            m_Pending = *package;
            return true;
        }

        bool FirstLaunch() const override
        {
            return m_bFirstLaunch;
        }

        std::vector<std::string> Themes() const override
        {
            return gitgud::app::ListThemes(m_Current);
        }

        std::string CurrentTheme() const override
        {
            return ActiveTheme(m_Current);
        }

        bool RequestThemeSwitch(const std::string& _Theme, std::string& _Error) override
        {
            const std::vector<std::string> themes = gitgud::app::ListThemes(m_Current);
            if (std::find(themes.begin(), themes.end(), _Theme) == themes.end())
            {
                _Error = "This interface has no theme called '" + _Theme + "'";
                return false;
            }
            if (!gitgud::app::WriteThemeChoice(
                    gitgud::platform::ConfigDirectory(), m_Current.m_Id, _Theme))
            {
                _Error = "Could not save the choice";
                return false;
            }
            m_Pending = m_Current; // rebuilt like a switch, in the new theme
            return true;
        }

        // ---- Used by the main loop -----------------------------------------------------

        // Close queued windows. Returns a UI switch to perform, if one is pending.
        std::optional<gitgud::app::UiPackage> ProcessPending()
        {
            std::vector<std::string> closing;
            closing.swap(m_Closing);
            for (const std::string& id : closing)
            {
                Destroy(id, true);
            }

            std::optional<gitgud::app::UiPackage> pending;
            pending.swap(m_Pending);
            if (pending)
            {
                // A theme change rebuilds the same UI: the previous one stays.
                if (m_Current.m_Id != gitgud::app::kUiPickerId && pending->m_Id != m_Current.m_Id)
                {
                    m_Previous = m_Current.m_Id;
                }
                m_Current = *pending;
            }
            return pending;
        }

        // Every pop-out goes (hot-reload, UI switch). No events: the scripts
        // that owned them are being replaced.
        void CloseAllWindows()
        {
            while (!m_PopOuts.empty())
            {
                Destroy(m_PopOuts.begin()->first, false);
            }
            m_Closing.clear();
        }

        // The pop-out an SDL window id belongs to: its surface id, "" for the
        // main window, or nullopt for none of ours.
        std::optional<std::string> SurfaceOf(Uint32 _uiWindowId) const
        {
            if (SDL_GetWindowID(m_pMain) == _uiWindowId)
            {
                return std::string();
            }
            for (const auto& [id, popOut] : m_PopOuts)
            {
                if (SDL_GetWindowID(popOut.m_pWindow) == _uiWindowId)
                {
                    return id;
                }
            }
            return std::nullopt;
        }

        std::map<std::string, PopOut>& PopOuts()
        {
            return m_PopOuts;
        }

        void SetIcon(SDL_Window* _pWindow) const
        {
            // The Jera-rune mark (taskbar, Alt-Tab). BMP because core SDL loads
            // it dependency free. A missing file is cosmetic, not fatal.
            if (SDL_Surface* picon = SDL_LoadBMP((m_ResourceRoot + "/icon/gitgud.bmp").c_str()))
            {
                SDL_SetWindowIcon(_pWindow, picon);
                SDL_FreeSurface(picon);
            }
        }

      private:
        SDL_Window* WindowOf(const std::string& _Id) const
        {
            if (_Id.empty())
            {
                return m_pMain;
            }
            const auto it = m_PopOuts.find(_Id);
            return it != m_PopOuts.end() ? it->second.m_pWindow : nullptr;
        }

        void Destroy(const std::string& _Id, bool _bNotify)
        {
            const auto it = m_PopOuts.find(_Id);
            if (it == m_PopOuts.end())
            {
                return;
            }
            if (m_pUi)
            {
                m_pUi->DestroySurface(_Id);
            }
            SDL_DestroyWindow(it->second.m_pWindow);
            m_PopOuts.erase(it);
            SDL_GL_MakeCurrent(m_pMain, m_Gl);
            UpdateSwapInterval();
            if (_bNotify)
            {
                m_Bus.Publish({"window.closed", _Id});
            }
        }

        // Vsync on every swap would make N windows wait N frames; with pop-outs
        // open, don't wait (the loop only draws windows that changed anyway).
        void UpdateSwapInterval()
        {
            SDL_GL_MakeCurrent(m_pMain, m_Gl);
            SDL_GL_SetSwapInterval(m_PopOuts.empty() ? 1 : 0);
        }

        SDL_Window* m_pMain;
        SDL_GLContext m_Gl;
        gitgud::ui::IUiBackend* m_pUi;
        gitgud::app::EventBus& m_Bus;
        std::string m_ResourceRoot;

        std::map<std::string, PopOut> m_PopOuts;
        std::vector<std::string> m_Closing;
        bool m_bBordered = false;

        gitgud::app::UiPackage m_Current;
        std::string m_Previous;
        std::optional<gitgud::app::UiPackage> m_Pending;
        bool m_bFirstLaunch = false;
    };

    // Read the drawable of the current GL window into a PNG (test harness).
    bool SaveScreenshot(SDL_Window* _pWindow, const std::string& _Path)
    {
        int iw = 0;
        int ih = 0;
        SDL_GL_GetDrawableSize(_pWindow, &iw, &ih);
        gitgud::imaging::Image shot;
        shot.m_iWidth = iw;
        shot.m_iHeight = ih;
        shot.m_Rgba.resize(static_cast<std::size_t>(iw) * ih * 4);
        glReadPixels(0, 0, iw, ih, GL_RGBA, GL_UNSIGNED_BYTE, shot.m_Rgba.data());

        // GL rows run bottom-up; PNG rows top-down.
        const std::size_t row = static_cast<std::size_t>(iw) * 4;
        for (int y = 0; y < ih / 2; ++y)
        {
            std::swap_ranges(shot.m_Rgba.begin() + y * row, shot.m_Rgba.begin() + (y + 1) * row,
                shot.m_Rgba.begin() + (ih - 1 - y) * row);
        }
        for (std::size_t i = 3; i < shot.m_Rgba.size(); i += 4)
        {
            shot.m_Rgba[i] = 255;
        }
        return gitgud::imaging::WritePng(_Path, shot);
    }

    // SDL event-watch trampoline: _pData is the std::function to call.
    int SDLCALL CallEventWatch(void* _pData, SDL_Event* _pEv)
    {
        (*static_cast<std::function<void(const SDL_Event&)>*>(_pData))(*_pEv);
        return 0;
    }

    // True for a mouse motion that the next queued event supersedes (another
    // motion over the same window): only the latest position matters, so
    // hover and drag handlers run once per frame instead of once per event.
    bool IsSupersededMotion(const SDL_Event& _Ev)
    {
        if (_Ev.type != SDL_MOUSEMOTION)
        {
            return false;
        }
        SDL_Event next;
        return SDL_PeepEvents(&next, 1, SDL_PEEKEVENT, SDL_FIRSTEVENT, SDL_LASTEVENT) == 1 &&
               next.type == SDL_MOUSEMOTION && next.motion.windowID == _Ev.motion.windowID;
    }

#if defined(_WIN32)
    // Windows' display and power messages, which SDL doesn't turn into
    // events (a monitor that comes back on a dock needn't be a new display
    // to SDL): flagged for the main loop (DisplayMessages), never queued.
    // Runs in SDL's window procedure, on the UI thread.
    std::atomic<unsigned> g_uDisplayMessages{0};
    constexpr unsigned kDisplaySettingsChanged = 1;
    constexpr unsigned kResumedFromSleep = 2;

    int SDLCALL DisplayMessageFilter(void*, SDL_Event* _pEv)
    {
        if (_pEv->type != SDL_SYSWMEVENT)
        {
            return 1;
        }
        const SDL_SysWMmsg* pmsg = _pEv->syswm.msg;
        if (pmsg && pmsg->subsystem == SDL_SYSWM_WINDOWS)
        {
            if (pmsg->msg.win.msg == WM_DISPLAYCHANGE)
            {
                g_uDisplayMessages.fetch_or(kDisplaySettingsChanged);
            }
            else if (pmsg->msg.win.msg == WM_POWERBROADCAST && pmsg->msg.win.wParam == PBT_APMRESUMEAUTOMATIC)
            {
                g_uDisplayMessages.fetch_or(kResumedFromSleep);
            }
        }
        return 0;
    }
#endif

    // The SDL window an event concerns (0 when it has none).
    Uint32 EventWindowId(const SDL_Event& _Ev)
    {
        switch (_Ev.type)
        {
        case SDL_WINDOWEVENT:
            return _Ev.window.windowID;
        case SDL_MOUSEMOTION:
            return _Ev.motion.windowID;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP:
            return _Ev.button.windowID;
        case SDL_MOUSEWHEEL:
            return _Ev.wheel.windowID;
        case SDL_KEYDOWN:
        case SDL_KEYUP:
            return _Ev.key.windowID;
        case SDL_TEXTINPUT:
            return _Ev.text.windowID;
        default:
            return 0;
        }
    }

} // namespace

int main(int _iArgc, char* _aSzArgv[])
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

    // A restart (gitgud.restartApp): this copy starts once the one that
    // asked for it has closed (its voice engine, conversations and files).
    gitgud::platform::RememberLaunch(_iArgc, _aSzArgv);
    if (!gitgud::platform::WaitForEarlierCopy(60000))
    {
        std::fprintf(stderr, "[restart] the earlier copy is still running; starting anyway\n");
    }

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
        // One open file behind both streams, so their lines interleave
        // instead of overwriting each other. If it can't be opened, output
        // stays on the terminal.
        const int ifd = open(szlogPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (ifd >= 0)
        {
            std::fflush(stdout);
            std::fflush(stderr);
            dup2(ifd, STDOUT_FILENO);
            dup2(ifd, STDERR_FILENO);
            close(ifd);
        }
        else
        {
            std::fprintf(stderr, "GITGUD_LOG: can't write %s: %s\n", szlogPath, std::strerror(errno));
        }
#endif
        std::setvbuf(stdout, nullptr, _IONBF, 0);
        std::setvbuf(stderr, nullptr, _IONBF, 0);
    }

    // Symbolized stack trace + minidump if we ever crash.
    gitgud::platform::InstallCrashHandler(gitgud::platform::LogDirectory());

#if defined(__APPLE__)
    // Started from Finder, PATH lacks what the shell profile adds (gpg,
    // git-lfs, p4, editors): take the login shell's.
    gitgud::platform::AdoptLoginShellPath();
#endif

    // Updates (app/Updater.h). While gitgud-patcher.exe is replacing files,
    // wait for it instead of loading half-replaced ones. A downloaded update
    // is installed now, before anything loads, but only when no other copy of
    // GitGud is running from this folder: otherwise this copy just opens
    // (several copies are always allowed) and the update waits for a start
    // with none open.
    {
        namespace updater = gitgud::app::updater;
        for (int i = 0; i < 1200 && updater::PatcherRunning(); ++i)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!std::getenv("GITGUD_NO_UPDATE") && updater::IsPackagedBuild() &&
            !updater::StagedVersion().empty() && updater::OtherCopies() == 0)
        {
            std::string error;
            if (updater::StartPatcher(error))
            {
                return 0;
            }
            std::fprintf(stderr, "[update] %s\n", error.c_str());
        }
    }

    // --- SDL + OpenGL window --------------------------------------------
    // The GitGud UI draws its own title bar, so the OS frame is dropped.
    // These hints keep Windows treating the borderless window as a normal app
    // window: real resize borders, working Aero snap, and a maximize that
    // respects the taskbar. (Hint names spelled out: this vcpkg SDL2's
    // headers predate the macros.) A UI can ask for the native frame back
    // (gitgud.setWindowBordered).
    SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "1");
    SDL_SetHint("SDL_BORDERLESS_RESIZABLE_STYLE", "1");
    // Clicking into a pop-out while another window is active should click,
    // not just focus.
    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");

    // The stall watchdog reports any main-loop pass (startup included) that
    // keeps the UI thread past GITGUD_STALL_MS (default 200; 0 turns it off)
    // into logs/perf.log, with what was running.
    gitgud::prof::SetThreadName("UI");
    {
        std::error_code ec;
        const fs::path logs = fs::u8path(gitgud::platform::ConfigDirectory()) / "logs";
        fs::create_directories(logs, ec);
        gitgud::prof::WatchdogOptions watch;
        const char* szstall = std::getenv("GITGUD_STALL_MS");
        watch.m_iThresholdMs = szstall && *szstall ? std::max(0, std::atoi(szstall)) : 200;
        watch.m_LogPath = (logs / "perf.log").u8string();
        gitgud::prof::StartWatchdog(watch);
        gitgud::prof::UiBusy();
    }
    gitgud::prof::Begin(gitgud::prof::Intern("Startup")); // ends as the main loop begins
    // GITGUD_PROFILE=1 captures from the start (=zones: without the Lua call
    // hook); GITGUD_PROFILE_SECONDS=<n> stops it after n seconds.
    if (const char* szprofile = std::getenv("GITGUD_PROFILE");
        szprofile && *szprofile && std::strcmp(szprofile, "0") != 0)
    {
        gitgud::prof::CaptureOptions options;
        options.m_bLuaCalls = std::strcmp(szprofile, "zones") != 0;
        gitgud::prof::StartCapture(options);
    }

    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
#if defined(__APPLE__)
    // macOS only gives a 3.2 core context when it's forward compatible. The
    // pop-out windows share this context.
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
#endif

    SDL_Window* pwindow = SDL_CreateWindow("Gitgud", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        ikWidth, ikHeight, kWindowFlags | SDL_WINDOW_BORDERLESS);
    if (!pwindow)
    {
        std::fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    SDL_SetWindowMinimumSize(pwindow, 1140, 600);
    if (TestInBackground())
    {
        gitgud::platform::SendToBack(pwindow);
    }
#if defined(__APPLE__)
    gitgud::platform::AllowMinimize(pwindow);
    gitgud::platform::ReleaseCloseShortcut();
#endif

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
#if defined(_WIN32)
    SDL_EventState(SDL_SYSWMEVENT, SDL_ENABLE); // only for DisplayMessageFilter
    SDL_SetEventFilter(DisplayMessageFilter, nullptr);
#endif

    // --- Subsystems ------------------------------------------------------
    gitgud::git::LibGit2 libgit2; // RAII global Init/Shutdown
    gitgud::app::EventBus bus;
    gitgud::app::TaskRunner tasks(bus);
    auto credentials = gitgud::platform::MakeCredentialStore();
    gitgud::agent::ToolServer tools; // before lua: its sessions use it
    StartTools(tools);

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

    std::optional<gitgud::git::Repository> repo;

    // Resources live next to the exe (CMake copies them there), so resolve
    // them from the exe path, not the working directory.
    std::string resourceRoot = "resources";
    if (char* szbasePath = SDL_GetBasePath())
    {
        resourceRoot = std::string(szbasePath) + "resources";
        SDL_free(szbasePath);
    }

    auto ui = MakeUiBackend();

    // Window icon (taskbar, Alt-Tab). The exe's own icon resource
    // (resources/icon/gitgud.rc) covers Explorer and pins; this covers the
    // live windows.
    // The built-in UIs' customizations live in the config folder
    // (<config>/<id>/ui/, app/UiPackages.h): an update never touches them.
    gitgud::app::SetUiOverlayBase(gitgud::platform::ConfigDirectory());
    AppShell shell(pwindow, gl, ui.get(), bus, resourceRoot);
    shell.SetIcon(pwindow);
    shell.ChooseStartupUi();

    // The repository to start with: `gitgud <path>` (`gitgud .` for the
    // current folder), else the one opened last. None on first launch, before
    // a UI has been picked. Failing isn't fatal: the UI still comes up and
    // offers Open/Init/clone. Absolute so the UI can show a real name.
    std::string startRepo;
    // Older macOS hands an app opened from Finder a "-psn_..." process serial
    // number; that's not a path.
    if (_iArgc > 1 && std::strncmp(_aSzArgv[1], "-psn_", 5) != 0)
    {
        std::error_code ec;
        startRepo = fs::absolute(fs::u8path(_aSzArgv[1]), ec).u8string();
    }
    else if (!shell.FirstLaunch())
    {
        startRepo = ReadLastRepo();
        // One that's gone (moved, deleted) is quietly not reopened.
        std::error_code ec;
        if (!startRepo.empty() && !fs::exists(fs::u8path(startRepo), ec))
        {
            startRepo.clear();
        }
    }
    if (!startRepo.empty())
    {
        try
        {
            repo.emplace(gitgud::git::Repository::Open(startRepo));
            WriteLastRepo(repo->WorkDir());
            tools.SetRepository(repo->WorkDir());
        }
        catch (const gitgud::git::GitError& e)
        {
            std::fprintf(stderr, "[git] no repo at '%s': %s\n", startRepo.c_str(), e.what());
        }
    }

    FrameProfiler profiler(PerfThresholdFromEnv());
    gitgud::lua::LuaEngine lua;
    lua.SetSlowCallThreshold(PerfThresholdFromEnv());
    lua.Bind(repo ? &*repo : nullptr, &bus, ui.get(), &tasks, credentials.get());
    lua.SetAppHost(&shell);
    lua.SetToolServer(&tools);
    // Calls of the tools the UI declared (gitgud.declareTools) go to the UI
    // thread as "tools.call"; the script answers with gitgud.toolReply.
    tools.SetAppHandler(
        [&bus](const std::string& _Id, const std::string& _Tool, const gitgud::app::Json& _Arguments,
            const std::string& _Session)
        {
            bus.Publish({"tools.call", gitgud::app::Json::Object()
                                           .Set("id", _Id)
                                           .Set("tool", _Tool)
                                           .Set("arguments", _Arguments)
                                           .Set("session", _Session)
                                           .Dump()});
        });

    if (!lua.Initialize())
    {
        std::fprintf(stderr, "Lua Init failed\n");
        return 1;
    }
    lua.SetCallProfiling(gitgud::prof::LuaCallsWanted()); // GITGUD_PROFILE: from the first script

    if (ui && !ui->Initialize(ikWidth, ikHeight, resourceRoot))
    {
        std::fprintf(stderr, "UI backend Init failed\n");
        return 1;
    }
    float fmainRatio = PixelRatio(pwindow);
    if (ui)
    {
        ui->SetPixelRatio("", fmainRatio);
    }
#if defined(__APPLE__)
    std::printf("[display] %g drawable pixels per point\n", fmainRatio);
#endif

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

            WriteLastRepo(repo->WorkDir());
            tools.SetRepository(repo->WorkDir());
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
            tools.SetRepository("");
            lua.Bind(nullptr, &bus, ui.get(), &tasks, credentials.get());
            bus.Publish({"repo.changed", ""});
        });

    // Window commands raised from Lua (the custom title bar's buttons emit
    // these). Close goes through SDL_QUIT so it exits the same path as the OS
    // close would. Maximize/restore state flows back to Lua via the
    // "window.state" events published from the SDL event loop below.
    bus.Subscribe(
        "window.minimize", [&](const gitgud::app::AppEvent&) { SDL_MinimizeWindow(pwindow); });
#if defined(__APPLE__)
    SDL_Rect zoomRestore{};
#endif
    bus.Subscribe("window.toggleMaximize",
        [&](const gitgud::app::AppEvent&)
        {
#if defined(__APPLE__)
            if (SDL_GetWindowFlags(pwindow) & SDL_WINDOW_BORDERLESS)
            {
                ToggleZoom(pwindow, zoomRestore, bus);
                return;
            }
#endif
            if (SDL_GetWindowFlags(pwindow) & SDL_WINDOW_MAXIMIZED)
            {
                SDL_RestoreWindow(pwindow);
            }
            else
            {
                SDL_MaximizeWindow(pwindow);
            }
        });

    // "Title\nbody": ask for the user while the window is in the background
    // (an agent session finished or needs a permission); nothing while it has
    // the focus, or under the test harness (GITGUD_SCRIPT).
    bus.Subscribe("window.notify",
        [&](const gitgud::app::AppEvent& _Ev)
        {
            if (std::getenv("GITGUD_SCRIPT"))
            {
                return;
            }
            const size_t nbreak = _Ev.m_Detail.find('\n');
            gitgud::platform::RequestAttention(pwindow, _Ev.m_Detail.substr(0, nbreak),
                nbreak == std::string::npos ? std::string() : _Ev.m_Detail.substr(nbreak + 1));
        });

    bus.Subscribe("window.close",
        [&](const gitgud::app::AppEvent&)
        {
            SDL_Event quit{};
            quit.type = SDL_QUIT;
            SDL_PushEvent(&quit);
        });

    // A script may ask for the hot-reload itself (emit("app.reload")): the
    // main loop does it once the handler is done.
    bool breloadAsked = false;
    bus.Subscribe("app.reload", [&](const gitgud::app::AppEvent&) { breloadAsked = true; });

    // The main window renewed (renewWindow, below), asked for by a script
    // (emit("window.renew", why): core/display.lua, after the displays
    // change) or by hand (Ctrl+Alt+Shift+R); the main loop does it between
    // handlers.
    bool brenewAsked = false;
    std::string renewWhy;
    bus.Subscribe("window.renew",
        [&](const gitgud::app::AppEvent& _Ev)
        {
            brenewAsked = true;
            renewWhy = _Ev.m_Detail;
        });

    // A change of the displays, told to the scripts ("display.changed") and
    // the log.
    auto displayChanged = [&](const std::string& _What)
    {
        std::printf("[display] %s\n", _What.c_str());
        bus.Publish({"display.changed", _What});
    };

    // GITGUD_SCRIPT=<file.lua> runs an extra script after the UI's main.lua -
    // the hook for automated UI tests (see gitgud.simulateClick/screenshot).
    // It runs again after each hot-reload, like main.lua.
    const char* sztestScript = std::getenv("GITGUD_SCRIPT");
    ResourceWatcher watcher;
    watcher.SetProgramDirectory(gitgud::platform::ExecutableDirectory());

    // Point the backend and the VM at the current UI package and run it.
    auto loadUi = [&](const char* _szReason)
    {
        const gitgud::app::UiPackage& package = shell.CurrentUi();
        const std::string baseScripts = resourceRoot + "/scripts";
        std::vector<std::string> scriptRoots{package.ScriptsDir()};
        if (package.ScriptsDir() != baseScripts)
        {
            scriptRoots.push_back(baseScripts);
        }
        lua.SetScriptRoots(scriptRoots);
        // The user's customizations first (app/UiPackages.h); each file that
        // fails falls back to the shipped one, with a note.
        const std::string overlay = package.m_OverlayRoot;
        lua.ClearOverlayErrors();
        lua.SetScriptOverlay(overlay.empty() ? std::string() : overlay + "/scripts");
        std::vector<std::string> watched{resourceRoot, package.m_Root};
        if (!overlay.empty())
        {
            watched.push_back(overlay);
        }
        watcher.SetRoots(watched);

        if (ui)
        {
            ui->SetOverlayRoot(overlay);
            ui->SetLayoutDirectory(package.LayoutsDir());
            if (!ui->LoadLayout(kMainLayout))
            {
                std::fprintf(stderr, "Failed to load %s\n", kMainLayout);
            }
            for (const auto& [file, error] : ui->TakeOverlayErrors())
            {
                lua.AddOverlayError(file, error);
            }
        }
        lua.RunFileOrShipped(overlay.empty() ? std::string() : overlay + "/scripts/main.lua",
            package.ScriptsDir() + "/main.lua");
        if (sztestScript)
        {
            lua.RunFile(sztestScript);
        }
        bus.Publish({"app.started", _szReason});
    };

    // Apply a package's skin (its looknfeel/ and imagesets/ are optional) in
    // its theme (app/UiPackages.h).
    auto applySkin = [&](const gitgud::app::UiPackage& _Package)
    {
        if (ui)
        {
            const bool bbase = _Package.m_Id == gitgud::app::kDefaultUiId;
            ui->SetOverlayRoot(_Package.m_OverlayRoot);
            ui->ApplySkin(bbase ? std::string() : _Package.m_Root,
                bbase ? std::string()
                      : gitgud::app::ThemeFile(_Package, ActiveTheme(_Package)));
        }
    };

    // gitgud.screenshot(path[, window]): capture the next frame we draw.
    std::string pendingScreenshot;
    std::string pendingScreenshotWindow;
    bus.Subscribe("debug.screenshot",
        [&](const gitgud::app::AppEvent& _Ev)
        {
            const auto nbreak = _Ev.m_Detail.find('\n');
            pendingScreenshotWindow =
                nbreak == std::string::npos ? std::string() : _Ev.m_Detail.substr(0, nbreak);
            pendingScreenshot =
                nbreak == std::string::npos ? _Ev.m_Detail : _Ev.m_Detail.substr(nbreak + 1);
            if (auto it = shell.PopOuts().find(pendingScreenshotWindow);
                it != shell.PopOuts().end())
            {
                it->second.m_bRedraw = true;
            }
        });

    // The canvas behind the UI: the default skin's, until a script sets its
    // theme's ("window.canvas", "AARRGGBB"; the alpha is ignored).
    glClearColor(0.055f, 0.039f, 0.102f, 1.0f);
    bus.Subscribe("window.canvas",
        [](const gitgud::app::AppEvent& _Ev)
        {
            const std::string& argb = _Ev.m_Detail;
            if (argb.size() != 8 || argb.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos)
            {
                return;
            }
            const unsigned long ulcolour = std::strtoul(argb.c_str(), nullptr, 16);
            glClearColor(static_cast<float>((ulcolour >> 16) & 0xFF) / 255.0f,
                static_cast<float>((ulcolour >> 8) & 0xFF) / 255.0f,
                static_cast<float>(ulcolour & 0xFF) / 255.0f, 1.0f);
        });

    applySkin(shell.CurrentUi());
    loadUi("");

    std::printf("Gitgud: window + subsystems online. Close the window to exit.\n");

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
    constexpr Uint32 kSettleWatchMs = 250; // while a change settles
    // A focus loss and gain this close together is focus moving between
    // our own windows.
    constexpr Uint32 kOwnFocusSwitchMs = 250;
    Uint32 lastFocusLostTick = 0;

    // Lay the UI out at each window's current size, if that changed. Size
    // events only flag the window: a border drag queues one per mouse move,
    // and only the last size counts.
    // (With GITGUD_PIXEL_RATIO the first layout size differs from the one the
    // UI started with.)
    bool bmainResizePending = ForcedPixelRatio() > 0.0f;
    int imainWidth = -1;
    int imainHeight = -1;
    auto applyResizes = [&]()
    {
        if (!ui)
        {
            return;
        }
        if (bmainResizePending)
        {
            bmainResizePending = false;
            int iw = 0;
            int ih = 0;
            LayoutSize(pwindow, iw, ih);
            // Moved to a display of another density (Retina and not).
            if (const float fratio = PixelRatio(pwindow); fratio != fmainRatio)
            {
                fmainRatio = fratio;
                ui->SetPixelRatio("", fratio);
                bredraw = true;
            }
            if (iw != imainWidth || ih != imainHeight)
            {
                imainWidth = iw;
                imainHeight = ih;
                ui->Resize(iw, ih);
                bus.Publish({"window.resized", std::to_string(iw) + "x" + std::to_string(ih)});
                bredraw = true;
            }
        }
        for (auto& [id, popOut] : shell.PopOuts())
        {
            if (!popOut.m_bResizePending)
            {
                continue;
            }
            popOut.m_bResizePending = false;
            int iw = 0;
            int ih = 0;
            LayoutSize(popOut.m_pWindow, iw, ih);
            if (const float fratio = PixelRatio(popOut.m_pWindow); fratio != popOut.m_fRatio)
            {
                popOut.m_fRatio = fratio;
                ui->SetPixelRatio(id, fratio);
                popOut.m_bRedraw = true;
            }
            if (iw == popOut.m_iWidth && ih == popOut.m_iHeight)
            {
                continue;
            }
            popOut.m_iWidth = iw;
            popOut.m_iHeight = ih;
            ui->ResizeSurface(id, iw, ih);
            bus.Publish(
                {"window.popOutResized", id + "|" + std::to_string(iw) + "x" + std::to_string(ih)});
            popOut.m_bRedraw = true;
        }
    };

    auto handleEvent = [&](const SDL_Event& _Ev, bool& _bRunning)
    {
        if (_Ev.type == SDL_QUIT)
        {
            _bRunning = false;
            return;
        }

        // Which of our windows the event is for: "" = the main window.
        const Uint32 uiwindowId = EventWindowId(_Ev);
        std::optional<std::string> surface;
        if (uiwindowId != 0)
        {
            surface = shell.SurfaceOf(uiwindowId);
            if (!surface)
            {
                return; // a window we already closed
            }
        }
        const std::string target = surface.value_or(std::string());
        const bool bmain = target.empty();
        AppShell::PopOut* ppopOut = nullptr;
        if (!bmain)
        {
            ppopOut = &shell.PopOuts()[target];
        }
        if (ui)
        {
            ui->SetInputSurface(target);
        }

        switch (_Ev.type)
        {
        case SDL_DISPLAYEVENT:
            if (_Ev.display.event == SDL_DISPLAYEVENT_CONNECTED)
            {
                displayChanged("a display was connected");
            }
            else if (_Ev.display.event == SDL_DISPLAYEVENT_DISCONNECTED)
            {
                displayChanged("a display was disconnected");
            }
            else if (_Ev.display.event == SDL_DISPLAYEVENT_MOVED)
            {
                displayChanged("a display moved");
            }
            break;

        case SDL_WINDOWEVENT:
            if (ppopOut)
            {
                ppopOut->m_bRedraw = true;
            }
            else
            {
                bredraw = true;
            }
            if (_Ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED ||
                _Ev.window.event == SDL_WINDOWEVENT_DISPLAY_CHANGED)
            {
                // Laid out once for the whole batch (applyResizes).
                if (ppopOut)
                {
                    ppopOut->m_bResizePending = true;
                }
                else
                {
                    bmainResizePending = true;
                }
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_CLOSE)
            {
                if (bmain)
                {
                    _bRunning = false; // the native frame's close button
                }
                else
                {
                    shell.CloseWindow(target);
                }
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_ENTER && ui)
            {
                ui->SetCursorVisible(target, true);
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_LEAVE && ui)
            {
                if (bmain)
                {
                    g_bOnResizeRim = false;
                }
                ui->SetCursorVisible(target, false);
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_MAXIMIZED && bmain)
            {
                bus.Publish({"window.state", "maximized"});
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_RESTORED && bmain)
            {
                bus.Publish({"window.state", "restored"});
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_FOCUS_LOST)
            {
                lastFocusLostTick = SDL_GetTicks();
            }
            else if (_Ev.window.event == SDL_WINDOWEVENT_FOCUS_GAINED)
            {
                // Coming back from an editor/terminal: refresh. Focus moving
                // straight from one of our own windows (a pop-out) doesn't
                // mean anything changed on disk, and a refresh isn't free.
                // Pop-outs report which window came forward.
                const bool bfromOwnWindow = SDL_GetTicks() - lastFocusLostTick < kOwnFocusSwitchMs;
                if (bmain)
                {
                    gitgud::platform::ClearAttention();
                }
                if (!bmain)
                {
                    bus.Publish({"window.focused", target});
                }
                else if (!bfromOwnWindow)
                {
                    bus.Publish({"app.focusGained", target});
                }
            }
            break;

        case SDL_MOUSEMOTION:
            if (ui)
            {
                const float fscale = InputScale(SDL_GetWindowFromID(_Ev.motion.windowID));
                ui->InjectMousePosition(static_cast<float>(_Ev.motion.x) * fscale,
                    static_cast<float>(_Ev.motion.y) * fscale);
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
                // A Mac trackpad scrolls in fractions of a notch: whole
                // notches would make two-finger scrolling jump.
#if defined(__APPLE__)
                float fdelta = _Ev.wheel.preciseY;
#else
                float fdelta = static_cast<float>(_Ev.wheel.y);
#endif
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
            // A pop-out's shortcuts are its own: "window.key" = "id|combo".
            const std::string combo = KeyCombo(_Ev.key.keysym);
            // Ctrl+Alt+Shift+P starts or stops a performance capture, in any
            // interface (handled here, so it works whatever the scripts do).
            if (combo == "ctrl+alt+shift+p")
            {
                gitgud::prof::RequestCapture(gitgud::prof::CaptureRequest::Toggle);
            }
            // Ctrl+Alt+Shift+R renews the main window, for when it stops
            // showing what's drawn (also here, so it works whatever the
            // scripts do).
            if (combo == "ctrl+alt+shift+r")
            {
                brenewAsked = true;
                renewWhy = "Ctrl+Alt+Shift+R";
            }
            if (!combo.empty())
            {
                if (bmain)
                {
                    bus.Publish({"key", combo});
                }
                else
                {
                    bus.Publish({"window.key", target + "|" + combo});
                }
            }
            if (ui)
            {
                ui->InjectKey(UiScancode(_Ev.key.keysym.scancode), true);
            }
            break;
        }

        case SDL_KEYUP:
            if (ui)
            {
                ui->InjectKey(UiScancode(_Ev.key.keysym.scancode), false);
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

        if (ui)
        {
            ui->SetInputSurface("");
        }

        const bool binput = _Ev.type == SDL_MOUSEMOTION || _Ev.type == SDL_MOUSEBUTTONDOWN ||
                            _Ev.type == SDL_MOUSEBUTTONUP || _Ev.type == SDL_MOUSEWHEEL ||
                            _Ev.type == SDL_KEYDOWN || _Ev.type == SDL_KEYUP ||
                            _Ev.type == SDL_TEXTINPUT;
        if (binput)
        {
            lastInputTick = SDL_GetTicks();
            if (ppopOut)
            {
                ppopOut->m_bRedraw = true;
            }
            else
            {
                bredraw = true;
            }
        }
    };

    // Swap in another UI package: everything the old one built goes.
    auto switchUi = [&](const gitgud::app::UiPackage& _Package)
    {
        std::printf("[ui] switching to '%s'\n", _Package.m_Id.c_str());
        shell.CloseAllWindows();
        shell.SetMainWindowBordered(false);
        SDL_SetWindowTitle(pwindow, "Gitgud");
        if (ui)
        {
            ui->UnloadAll();
        }
        applySkin(_Package);
        lua.ClearKept(); // the next UI starts afresh
        lua.Reset();
        loadUi("ui-switch");
        bus.Drain();
        bredraw = true;
        if (TestInBackground())
        {
            gitgud::platform::SendToBack(pwindow); // a rebuilt window stays behind
        }
    };

    // Hot-reload: the scripts keep what they need ("app.reloading", then
    // gitgud.keepForReload), then the windows, the skin, and the script VM
    // go and the UI loads afresh. Claude Code sessions and voice live
    // in C++ and carry on through it; the reloaded scripts
    // take them up again, so a change to Lua, XML, or prompts needs no
    // restart. The program itself can't be reloaded.
    auto hotReload = [&]()
    {
        bus.Drain(); // the old scripts see everything that came before
        lua.Dispatch("app.reloading", "hot-reload");
        shell.CloseAllWindows();
        if (ui)
        {
            ui->UnloadAll();
        }
        applySkin(shell.CurrentUi());
        lua.Reset();
        loadUi("hot-reload");
        bus.Drain();
        bredraw = true;
    };

    // Draw one window if it needs it (and take a pending screenshot of it).
    auto drawWindow = [&](SDL_Window* _pWindow, const std::string& _Surface, bool _bForce)
    {
        const bool bshot = !pendingScreenshot.empty() && pendingScreenshotWindow == _Surface;
        const bool bdirty = _Surface.empty() ? ui->NeedsRedraw() : ui->SurfaceNeedsRedraw(_Surface);
        if (!_bForce && !bdirty && !bshot)
        {
            return false;
        }
        profiler.Mark("pre-draw");
        SDL_GL_MakeCurrent(_pWindow, gl);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        if (_Surface.empty())
        {
            ui->Render();
        }
        else
        {
            ui->RenderSurface(_Surface);
        }
        if (bshot)
        {
            const bool bsaved = SaveScreenshot(_pWindow, pendingScreenshot);
            bus.Publish(
                {bsaved ? "debug.screenshotSaved" : "debug.screenshotFailed", pendingScreenshot});
            pendingScreenshot.clear();
            pendingScreenshotWindow.clear();
        }
        profiler.Mark("draw");
        static gitgud::prof::Site s_SwapSite{"Swap (vsync wait)", __FILE__, __LINE__};
        const gitgud::prof::Scope swapZone(s_SwapSite);
        // A swap that fails leaves SDL's error (SDL 2 doesn't return it).
        SDL_ClearError();
        SDL_GL_SwapWindow(_pWindow);
        const std::string swapError = SDL_GetError();
        if (_Surface.empty())
        {
            gitgud::prof::CountFrame(!swapError.empty());
            // Said once when presenting starts failing, and once when it works again.
            static bool s_bFailing = false;
            if (swapError.empty() == s_bFailing)
            {
                s_bFailing = !swapError.empty();
                std::printf(s_bFailing ? "[display] presenting the window failed: %s\n"
                                       : "[display] presenting the window works again%s\n",
                    swapError.c_str());
            }
        }
        profiler.Mark("swap");
        return true;
    };

    // Draw every window that needs it.
    auto drawAll = [&]()
    {
        for (auto& [id, popOut] : shell.PopOuts())
        {
            if (drawWindow(popOut.m_pWindow, id, popOut.m_bRedraw))
            {
                popOut.m_bRedraw = false;
            }
        }
        if (drawWindow(pwindow, "", bredraw))
        {
            bredraw = false;
        }
        SDL_GL_MakeCurrent(pwindow, gl);
    };

    // Renew the main window: a new one in the old one's place (position,
    // size, frame, maximized or not), the same GL context made current on
    // it, the old one closed. All the UI drew stays (its textures, shaders
    // and buffers belong to the context, which pop-outs share the same way);
    // only the path from the window to the screen is new. For when frames
    // stop reaching the screen though they're still drawn
    // (the dock's monitor came back and the window kept its last frame while
    // input, layout and drawing all went on).
    auto renewWindow = [&](const std::string& _Why)
    {
        int ix = 0;
        int iy = 0;
        int iw = 0;
        int ih = 0;
        int iminW = 0;
        int iminH = 0;
        SDL_GetWindowPosition(pwindow, &ix, &iy);
        SDL_GetWindowSize(pwindow, &iw, &ih);
        SDL_GetWindowMinimumSize(pwindow, &iminW, &iminH);
        const Uint32 uflags = SDL_GetWindowFlags(pwindow);
        Uint32 ucreate = (kWindowFlags & ~SDL_WINDOW_SHOWN) | SDL_WINDOW_HIDDEN;
        if (!shell.MainWindowBordered())
        {
            ucreate |= SDL_WINDOW_BORDERLESS;
        }
        SDL_Window* pnew = SDL_CreateWindow(SDL_GetWindowTitle(pwindow), ix, iy, iw, ih, ucreate);
        if (!pnew)
        {
            std::printf("[display] couldn't renew the window (%s): %s\n", _Why.c_str(), SDL_GetError());
            return;
        }
        if (SDL_GL_MakeCurrent(pnew, gl) != 0)
        {
            std::printf("[display] couldn't renew the window (%s): %s\n", _Why.c_str(), SDL_GetError());
            SDL_DestroyWindow(pnew);
            SDL_GL_MakeCurrent(pwindow, gl);
            return;
        }
        SDL_SetWindowMinimumSize(pnew, iminW, iminH);
        SDL_Window* pold = pwindow;
        pwindow = pnew;
        shell.ReplaceMainWindow(pnew);
        if (uflags & SDL_WINDOW_MAXIMIZED)
        {
            SDL_MaximizeWindow(pnew);
        }
        SDL_ShowWindow(pnew); // tests keep it from taking focus (SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN)
        if (TestInBackground())
        {
            gitgud::platform::SendToBack(pnew);
        }
        else
        {
            if (uflags & SDL_WINDOW_MINIMIZED)
            {
                SDL_MinimizeWindow(pnew);
            }
            else if (uflags & SDL_WINDOW_INPUT_FOCUS)
            {
                SDL_RaiseWindow(pnew);
            }
        }
        SDL_DestroyWindow(pold);
        SDL_GL_MakeCurrent(pwindow, gl);
        SDL_StartTextInput(); // text input goes with the focused window
        bmainResizePending = true;
        bredraw = true;
        std::printf("[display] window renewed (%s)\n", _Why.c_str());
        bus.Publish({"window.renewed", _Why});
    };

    // --- Live resize -----------------------------------------------------
    // Dragging a window border on Windows runs a modal loop inside the OS:
    // SDL_WaitEventTimeout doesn't return until the button is released, so
    // the window would show stale, stretched content for the whole drag. SDL
    // still hands every new size to event watchers as it happens; this one
    // lays the window out and draws it right away. It only acts while the
    // loop is parked in SDL's event functions (bpumping), never in the middle
    // of a handler (a native file dialog pumps window messages too).
    const SDL_threadID mainThread = SDL_ThreadID();
    bool bpumping = false;
    std::function<void(const SDL_Event&)> liveResize = [&](const SDL_Event& _Ev)
    {
        // Worker threads push events too: check the type before any state.
        if (_Ev.type != SDL_WINDOWEVENT || _Ev.window.event != SDL_WINDOWEVENT_SIZE_CHANGED ||
            SDL_ThreadID() != mainThread || !bpumping || !ui)
        {
            return;
        }
        bpumping = false; // no re-entry while Lua and the renderer run
        profiler.Begin();
        if (_Ev.window.windowID == SDL_GetWindowID(pwindow))
        {
            bmainResizePending = true;
        }
        else if (auto surface = shell.SurfaceOf(_Ev.window.windowID))
        {
            shell.PopOuts()[*surface].m_bResizePending = true;
        }
        applyResizes();
        profiler.Mark("resize");
        bus.Drain(); // scripts lay themselves out for the new size
        profiler.Mark("events");
        ui->Update(0.0f);
        drawAll();
        profiler.End("live resize");
        bpumping = true;
    };
    SDL_AddEventWatch(CallEventWatch, &liveResize);

    // SDL's event functions, flagged so the live-resize watcher may act.
    auto waitEvent = [&](SDL_Event& _Ev, int _iTimeoutMs)
    {
        bpumping = true;
        const bool bgot = SDL_WaitEventTimeout(&_Ev, _iTimeoutMs) != 0;
        bpumping = false;
        return bgot;
    };
    auto pollEvent = [&](SDL_Event& _Ev)
    {
        bpumping = true;
        const bool bgot = SDL_PollEvent(&_Ev) != 0;
        bpumping = false;
        return bgot;
    };

    gitgud::prof::EndTo(0); // Startup

    // --- Profiler ---------------------------------------------------------
    // Captures start and stop between frames (no script runs then, so the
    // Lua call hook can come and go). The reports are written on a worker
    // thread, then announced as "profiler.saved" (the folder).
    const std::string profileDir = (fs::u8path(gitgud::platform::ConfigDirectory()) / "logs").u8string();
    const char* szprofileSeconds = std::getenv("GITGUD_PROFILE_SECONDS");
    const double fprofileSeconds = szprofileSeconds ? std::atof(szprofileSeconds) : 0.0;
    std::vector<std::thread> profileWriters;
    auto stopCapture = [&](bool _bWait)
    {
        lua.SetCallProfiling(false);
        auto write = [&bus, profileDir]
        {
            gitgud::prof::SetThreadName("profile writer");
            const std::string folder = gitgud::prof::StopCapture(profileDir);
            gitgud::prof::SetLastCaptureFolder(folder);
            std::printf("[perf] capture written to %s\n", folder.c_str());
            std::fflush(stdout);
            bus.Publish({folder.empty() ? "profiler.failed" : "profiler.saved", folder});
        };
        if (_bWait)
        {
            write();
        }
        else
        {
            profileWriters.emplace_back(write);
        }
    };
    auto pollCapture = [&]()
    {
        using gitgud::prof::CaptureRequest;
        CaptureRequest request = gitgud::prof::TakeCaptureRequest();
        if (request == CaptureRequest::None && fprofileSeconds > 0.0 && gitgud::prof::Capturing() &&
            gitgud::prof::CaptureSeconds() >= fprofileSeconds)
        {
            request = CaptureRequest::Stop;
        }
        if (request == CaptureRequest::Toggle)
        {
            request = gitgud::prof::Capturing() ? CaptureRequest::Stop : CaptureRequest::Start;
        }
        if (request == CaptureRequest::Start && !gitgud::prof::Capturing())
        {
            gitgud::prof::StartCapture();
            std::printf("[perf] capture started (Ctrl+Alt+Shift+P again to stop)\n");
            std::fflush(stdout);
            bus.Publish({"profiler.started", ""});
        }
        else if (request == CaptureRequest::Stop && gitgud::prof::Capturing())
        {
            stopCapture(false);
        }
        lua.SetCallProfiling(gitgud::prof::LuaCallsWanted());
    };
    // The main loop's phases, one zone each.
    struct Phase
    {
        bool m_bOpen = false;
        void Next(gitgud::prof::Site& _Site)
        {
            Close();
            gitgud::prof::Begin(_Site.Id());
            m_bOpen = true;
        }
        void Close()
        {
            if (m_bOpen)
            {
                gitgud::prof::End();
                m_bOpen = false;
            }
        }
    } phase;
    static gitgud::prof::Site s_FrameSite{"Frame", __FILE__, __LINE__};
    static gitgud::prof::Site s_InputSite{"Input", __FILE__, __LINE__};
    static gitgud::prof::Site s_EventsSite{"Events (bus.Drain)", __FILE__, __LINE__};
    static gitgud::prof::Site s_TimersSite{"Timers (lua.Tick)", __FILE__, __LINE__};
    static gitgud::prof::Site s_SwitchSite{"Pending UI switches", __FILE__, __LINE__};
    static gitgud::prof::Site s_WatchSite{"Hot-reload watch", __FILE__, __LINE__};
    static gitgud::prof::Site s_UpdateSite{"ui->Update", __FILE__, __LINE__};
    static gitgud::prof::Site s_RenderSite{"Render", __FILE__, __LINE__};

    // --- Main loop -------------------------------------------------------
    bool brunning = true;
    while (brunning)
    {
        pollCapture();
        gitgud::prof::SetLuaMemoryKb(lua.MemoryKb());
        // During a capture, the UI's size once a second: windows, and the
        // ones drawn (every drawn window's text goes to the renderer).
        static Uint32 s_uLastCount = 0;
        if (gitgud::prof::Capturing() && ui && SDL_GetTicks() - s_uLastCount >= 1000)
        {
            s_uLastCount = SDL_GetTicks();
            int itotal = 0;
            int idrawn = 0;
            ui->CountWindows(itotal, idrawn);
            gitgud::prof::Counter("ui: windows", itotal);
            gitgud::prof::Counter("ui: windows drawn", idrawn);
            gitgud::prof::Counter("lua: handlers", static_cast<double>(lua.HandlerCount()));
        }
        // How long may we sleep before something needs attention?
        const Uint32 nowTick = SDL_GetTicks();
        int itimeout = (nowTick - lastInputTick < kActiveWindowMs) ? ikActiveTickMs : ikIdleTickMs;
        bool banyDirty = bredraw || (ui && ui->NeedsRedraw());
        for (const auto& [id, popOut] : shell.PopOuts())
        {
            banyDirty = banyDirty || popOut.m_bRedraw || (ui && ui->SurfaceNeedsRedraw(id));
        }
        if (banyDirty)
        {
            itimeout = 0;
        }
        const int itimerWait = lua.MillisecondsUntilNextTimer();
        if (itimerWait >= 0)
        {
            itimeout = std::min(itimeout, itimerWait);
        }
        const Uint32 watchEvery = watcher.Pending() ? kSettleWatchMs : kWatchIntervalMs;
        const Uint32 sinceWatch = nowTick - lastWatchTick;
        itimeout = std::min(itimeout,
            sinceWatch >= watchEvery ? 0 : static_cast<int>(watchEvery - sinceWatch));

        SDL_Event ev;
        gitgud::prof::UiIdle();
        const bool bgotEvent = waitEvent(ev, itimeout);
        gitgud::prof::UiBusy();
        gitgud::prof::Scope frameZone(s_FrameSite);
        phase.Next(s_InputSite);
        profiler.Begin();
        if (bgotEvent)
        {
            do
            {
                if (!IsSupersededMotion(ev))
                {
                    handleEvent(ev, brunning);
                }
            } while (pollEvent(ev));
        }
        applyResizes();
#if defined(_WIN32)
        // Windows' display and power messages (DisplayMessageFilter).
        if (const unsigned umessages = g_uDisplayMessages.exchange(0))
        {
            if (umessages & kDisplaySettingsChanged)
            {
                displayChanged("the display settings changed");
            }
            if (umessages & kResumedFromSleep)
            {
                displayChanged("the computer woke up");
            }
        }
#endif
        profiler.Mark("input");
        phase.Next(s_EventsSite);

        // Deliver queued events (worker completions, Lua-raised intents, ...)
        // and due timers on this — the UI — thread.
        if (bus.Drain() > 0)
        {
            bredraw = true;
        }
        profiler.Mark("events");
        phase.Next(s_TimersSite);
        if (lua.Tick())
        {
            bus.Drain();
            bredraw = true;
        }
        profiler.Mark("timers");
        phase.Next(s_SwitchSite);

        // Window closes and UI switches scripts asked for, now that no widget
        // handler is running.
        if (auto package = shell.ProcessPending())
        {
            switchUi(*package);
        }
        bus.Drain();

        // Hot-reload: poll the resource files about once a second (faster
        // while a change settles); once they've settled, or a script asked,
        // reload the skin and layout, restart the script VM, and re-run the
        // UI's main.lua.
        const Uint32 afterTick = SDL_GetTicks();
        if (breloadAsked || afterTick - lastWatchTick >=
                                (watcher.Pending() ? kSettleWatchMs : kWatchIntervalMs))
        {
            lastWatchTick = afterTick;
            phase.Next(s_WatchSite);
            const bool bsettled = watcher.ResourcesSettled(afterTick);
            if (watcher.ProgramSettled(afterTick))
            {
                std::printf("[hot-reload] the program's files changed; only resources reload "
                            "live: restart GitGud to run the new program\n");
            }
            profiler.Mark("watch");
            if (bsettled || breloadAsked)
            {
                std::printf(bsettled ? "[hot-reload] resources changed; reloading UI\n"
                                     : "[hot-reload] asked for; reloading UI\n");
                breloadAsked = false;
                hotReload();
            }
        }

        if (!ui)
        {
            phase.Close();
            profiler.End();
            continue;
        }
        if (brenewAsked)
        {
            brenewAsked = false;
            renewWindow(renewWhy);
        }
        profiler.Mark("other");
        phase.Next(s_UpdateSite);

        // Advance CEGUI's clock (caret blink, tooltips, animations); it marks
        // itself dirty when that changes anything visible.
        ui->Update(static_cast<float>(afterTick - lastPulseTick) / 1000.0f);
        lastPulseTick = afterTick;
        profiler.Mark("update");
        phase.Next(s_RenderSite);

        drawAll();
        // A screenshot of a window that no longer exists can't be taken.
        if (!pendingScreenshotWindow.empty() && shell.PopOuts().count(pendingScreenshotWindow) == 0)
        {
            bus.Publish({"debug.screenshotFailed", pendingScreenshot});
            pendingScreenshot.clear();
            pendingScreenshotWindow.clear();
        }
        profiler.Mark("render");
        profiler.End();
        phase.Close();
    }
    gitgud::prof::UiIdle();
    if (gitgud::prof::Capturing())
    {
        stopCapture(true);
    }
    for (std::thread& writer : profileWriters)
    {
        writer.join();
    }
    gitgud::prof::StopWatchdog();

    // --- Teardown (RAII handles the rest) --------------------------------
    // Voice first, while every library it uses is still loaded: the
    // sessions stop, then the speech engine releases its models (a
    // release at static-destruction time could hang in the GPU's
    // libraries and leave a crash marker behind).
    gitgud::lua::bindings::StopVoice();
    gitgud::speech::LocalEngine::PrepareForExit(std::chrono::seconds(20));
    SDL_DelEventWatch(CallEventWatch, &liveResize);
    shell.CloseAllWindows();
    if (ui)
    {
        ui->Shutdown();
    }

    gitgud::platform::ClearAttention();
    SDL_GL_DeleteContext(gl);
    SDL_DestroyWindow(pwindow);
    SDL_Quit();
    return 0;
}
