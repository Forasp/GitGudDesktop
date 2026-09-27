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
// default UI is resources/scripts + resources/layouts, alternatives live in
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
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

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
#include "app/IAppHost.h"
#include "app/TaskRunner.h"
#include "app/UiPackages.h"
#include "git/Repository.h"
#include "imaging/ImageDiff.h"
#include "lua/LuaEngine.h"
#include "platform/CrashHandler.h"
#include "platform/ICredentialStore.h"
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
        std::ifstream in(fs::u8path(gitgud::platform::ConfigDirectory()) / kLastRepoFile,
            std::ios::binary);
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

    // Watches the UI resource files and reports when any of them changed —
    // the trigger for hot-reload (edit the XML/Lua, see it live, no restart).
    // Watches the base resources and the running UI package's folder.
    class ResourceWatcher
    {
      public:
        void SetRoots(std::vector<std::string> _Roots)
        {
            m_Roots = std::move(_Roots);
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
            for (const std::string& root : m_Roots)
            {
                for (const char* szsub : {"/layouts", "/scripts", "/looknfeel", "/schemes"})
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
            }
            return sig;
        }

        std::vector<std::string> m_Roots;
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

    // The application shell scripts talk to (gitgud.openWindow, switchUi, ...):
    // owns the pop-out OS windows and which UI package runs. Requests that
    // would tear down widgets (closing a window, switching UI) can arrive in
    // the middle of that window's own event handler, so they are queued and
    // carried out by ProcessPending() between events.
    class AppShell final : public gitgud::app::IAppHost
    {
      public:
        struct PopOut
        {
            SDL_Window* m_pWindow = nullptr;
            bool m_bRedraw = true;
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
                SDL_RaiseWindow(it->second.m_pWindow);
                return true;
            }
            if (!m_pUi)
            {
                _Error = "No user interface";
                return false;
            }

            SDL_Window* pwindow = SDL_CreateWindow(_Spec.m_Title.c_str(), SDL_WINDOWPOS_CENTERED,
                SDL_WINDOWPOS_CENTERED, _Spec.m_iWidth, _Spec.m_iHeight,
                SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_SHOWN);
            if (!pwindow)
            {
                _Error = SDL_GetError();
                return false;
            }
            SDL_SetWindowMinimumSize(pwindow, _Spec.m_iMinWidth, _Spec.m_iMinHeight);
            SetIcon(pwindow);

            SDL_GL_MakeCurrent(pwindow, m_Gl);
            int iw = 0;
            int ih = 0;
            SDL_GL_GetDrawableSize(pwindow, &iw, &ih);
            const bool bcreated = m_pUi->CreateSurface(_Spec.m_Id, iw, ih, _Spec.m_Layout);
            SDL_GL_MakeCurrent(m_pMain, m_Gl);
            if (!bcreated)
            {
                SDL_DestroyWindow(pwindow);
                _Error = "Could not load layout '" + _Spec.m_Layout + "'";
                return false;
            }

            m_PopOuts[_Spec.m_Id] = PopOut{pwindow, true};
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
            if (SDL_Window* pwindow = WindowOf(_Id))
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
            // A native frame does its own dragging and resizing.
            SDL_SetWindowHitTest(m_pMain, _bBordered ? nullptr : WindowHitTest, m_pUi);
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
                         "' isn't a GitGud UI: it needs scripts/main.lua and layouts/main.xml";
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
                if (m_Current.m_Id != gitgud::app::kUiPickerId)
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
    gitgud::platform::InstallCrashHandler(gitgud::platform::LogDirectory());

    // --- SDL + OpenGL window --------------------------------------------
    // The default UI draws its own title bar, so the OS frame is dropped.
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
    AppShell shell(pwindow, gl, ui.get(), bus, resourceRoot);
    shell.SetIcon(pwindow);
    shell.ChooseStartupUi();

    // The repository to start with: `gitgud <path>` (`gitgud .` for the
    // current folder), else the one opened last. None on first launch, before
    // a UI has been picked. Failing isn't fatal: the UI still comes up and
    // offers Open/Init/clone. Absolute so the UI can show a real name.
    std::string startRepo;
    if (_iArgc > 1)
    {
        std::error_code ec;
        startRepo = fs::absolute(fs::u8path(_aSzArgv[1]), ec).u8string();
    }
    else if (!shell.FirstLaunch())
    {
        startRepo = ReadLastRepo();
    }
    if (!startRepo.empty())
    {
        try
        {
            repo.emplace(gitgud::git::Repository::Open(startRepo));
            WriteLastRepo(repo->WorkDir());
        }
        catch (const gitgud::git::GitError& e)
        {
            std::fprintf(stderr, "[git] no repo at '%s': %s\n", startRepo.c_str(), e.what());
        }
    }

    gitgud::lua::LuaEngine lua;
    lua.Bind(repo ? &*repo : nullptr, &bus, ui.get(), &tasks, credentials.get());
    lua.SetAppHost(&shell);

    if (!lua.Initialize())
    {
        std::fprintf(stderr, "Lua Init failed\n");
        return 1;
    }

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

            WriteLastRepo(repo->WorkDir());
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

    // GITGUD_SCRIPT=<file.lua> runs an extra script after the UI's main.lua -
    // the hook for automated UI tests (see gitgud.simulateClick/screenshot).
    const char* sztestScript = std::getenv("GITGUD_SCRIPT");
    ResourceWatcher watcher;

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
        watcher.SetRoots({resourceRoot, package.m_Root});

        if (ui)
        {
            ui->SetLayoutDirectory(package.LayoutsDir());
            if (!ui->LoadLayout(kMainLayout))
            {
                std::fprintf(stderr, "Failed to load %s\n", kMainLayout);
            }
        }
        lua.RunFile(package.ScriptsDir() + "/main.lua");
        if (sztestScript)
        {
            lua.RunFile(sztestScript);
        }
        bus.Publish({"app.started", _szReason});
    };

    // Apply a package's skin (its looknfeel/ and imagesets/ are optional).
    auto applySkin = [&](const gitgud::app::UiPackage& _Package)
    {
        if (ui)
        {
            ui->ApplySkin(
                _Package.m_Id == gitgud::app::kDefaultUiId ? std::string() : _Package.m_Root);
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

    applySkin(shell.CurrentUi());
    loadUi("");

    std::printf("Gitgud: window + subsystems online. Close the window to exit.\n");

    glClearColor(0.055f, 0.039f, 0.102f, 1.0f); // matches the skin's canvas

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
        case SDL_WINDOWEVENT:
            if (ppopOut)
            {
                ppopOut->m_bRedraw = true;
            }
            else
            {
                bredraw = true;
            }
            if (_Ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED && ui)
            {
                if (bmain)
                {
                    ui->Resize(_Ev.window.data1, _Ev.window.data2);
                    bus.Publish({"window.resized",
                        std::to_string(_Ev.window.data1) + "x" + std::to_string(_Ev.window.data2)});
                }
                else
                {
                    int iw = 0;
                    int ih = 0;
                    SDL_GL_GetDrawableSize(ppopOut->m_pWindow, &iw, &ih);
                    ui->ResizeSurface(target, iw, ih);
                    bus.Publish({"window.popOutResized",
                        target + "|" + std::to_string(iw) + "x" + std::to_string(ih)});
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
            else if (_Ev.window.event == SDL_WINDOWEVENT_FOCUS_GAINED)
            {
                // Coming back from an editor/terminal: refresh.
                // Pop-outs report which window came forward.
                bus.Publish({bmain ? "app.focusGained" : "window.focused", target});
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
            // A pop-out's shortcuts are its own: "window.key" = "id|combo".
            const std::string combo = KeyCombo(_Ev.key.keysym);
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
        lua.Reset();
        loadUi("ui-switch");
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
        SDL_GL_SwapWindow(_pWindow);
        return true;
    };

    // --- Main loop -------------------------------------------------------
    bool brunning = true;
    while (brunning)
    {
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

        // Window closes and UI switches scripts asked for, now that no widget
        // handler is running.
        if (auto package = shell.ProcessPending())
        {
            switchUi(*package);
        }
        bus.Drain();

        // Hot-reload: poll the resource files ~once a second; on any change
        // reload the layout, restart the script VM, and re-run the UI's main.lua.
        const Uint32 afterTick = SDL_GetTicks();
        if (afterTick - lastWatchTick >= kWatchIntervalMs)
        {
            lastWatchTick = afterTick;
            if (watcher.Changed())
            {
                std::printf("[hot-reload] resources changed; reloading UI\n");
                shell.CloseAllWindows();
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
        // A screenshot of a window that no longer exists can't be taken.
        if (!pendingScreenshotWindow.empty() && shell.PopOuts().count(pendingScreenshotWindow) == 0)
        {
            bus.Publish({"debug.screenshotFailed", pendingScreenshot});
            pendingScreenshot.clear();
            pendingScreenshotWindow.clear();
        }
        SDL_GL_MakeCurrent(pwindow, gl);
    }

    // --- Teardown (RAII handles the rest) --------------------------------
    shell.CloseAllWindows();
    if (ui)
    {
        ui->Shutdown();
    }

    SDL_GL_DeleteContext(gl);
    SDL_DestroyWindow(pwindow);
    SDL_Quit();
    return 0;
}
