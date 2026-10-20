// -----------------------------------------------------------------------------
// LuaAppBindings — the application shell: pop-out windows and user-interface
// packages (see app/IAppHost.h and app/UiPackages.h), the text scripts
// keep across a hot-reload (LuaEngine::Keep), and restarting the app
// (platform/Relaunch.h).
// -----------------------------------------------------------------------------

#include <cctype>
#include <ctime>
#include <filesystem>
#include <iterator>
#include <string>

#include "app/EventBus.h"
#include "app/IAppHost.h"
#include "platform/Relaunch.h"
#include "ui/IUiBackend.h"
#include "lua/LuaBindings.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        gitgud::app::IAppHost* Host(lua_State* _pL)
        {
            return Self(_pL)->AppHost();
        }

        int NoHost(lua_State* _pL)
        {
            return FailWith(_pL, "Not available in this build");
        }

        int IntField(lua_State* _pL, int _iTable, const char* _szKey, int _iDefault)
        {
            lua_getfield(_pL, _iTable, _szKey);
            const int ivalue =
                lua_isnumber(_pL, -1) ? static_cast<int>(lua_tointeger(_pL, -1)) : _iDefault;
            lua_pop(_pL, 1);
            return ivalue;
        }

        std::string StringField(lua_State* _pL, int _iTable, const char* _szKey)
        {
            lua_getfield(_pL, _iTable, _szKey);
            std::string value = lua_isstring(_pL, -1) ? lua_tostring(_pL, -1) : "";
            lua_pop(_pL, 1);
            return value;
        }

        void PushPackage(lua_State* _pL, const gitgud::app::UiPackage& _Package)
        {
            lua_newtable(_pL);
            SetField(_pL, "id", _Package.m_Id);
            SetField(_pL, "name", _Package.m_Name);
            SetField(_pL, "description", _Package.m_Description);
            SetField(_pL, "root", _Package.m_Root);
            SetField(_pL, "overlay", _Package.m_OverlayRoot);
            SetField(_pL, "builtIn", _Package.m_bBuiltIn);
        }

        // gitgud.uiOverlay(create?) -> { root, shipped, files = { relative,
        // ... }, errors = { {file, error}, ... } } for the running package
        // (app/UiPackages.h); root is "" when it can't have one. With
        // `create`, the folder is made if it isn't there.
        int LUiOverlay(lua_State* _pL)
        {
            const bool bcreate = lua_toboolean(_pL, 1) != 0;
            lua_newtable(_pL);
            auto* phost = Host(_pL);
            if (!phost)
            {
                return 1;
            }
            const gitgud::app::UiPackage& package = phost->CurrentUi();
            if (bcreate && !package.m_OverlayRoot.empty())
            {
                std::error_code ec;
                std::filesystem::create_directories(std::filesystem::u8path(package.m_OverlayRoot), ec);
            }
            SetField(_pL, "root", package.m_OverlayRoot);
            SetField(_pL, "shipped", package.m_Root);
            lua_newtable(_pL);
            lua_Integer ii = 1;
            for (const std::string& file : gitgud::app::OverlayFiles(package))
            {
                lua_pushstring(_pL, file.c_str());
                lua_rawseti(_pL, -2, ii++);
            }
            lua_setfield(_pL, -2, "files");
            // What the UI backend set aside since (a layout a script loaded).
            if (auto* pui = Self(_pL)->UiBackend())
            {
                for (const auto& [file, error] : pui->TakeOverlayErrors())
                {
                    Self(_pL)->AddOverlayError(file, error);
                }
            }
            lua_newtable(_pL);
            ii = 1;
            for (const auto& [file, error] : Self(_pL)->OverlayErrors())
            {
                lua_newtable(_pL);
                SetField(_pL, "file", file);
                SetField(_pL, "error", error);
                lua_rawseti(_pL, -2, ii++);
            }
            lua_setfield(_pL, -2, "errors");
            return 1;
        }

        // gitgud.uiFile(relative) -> the running package's file, the
        // overlay's when it has one (it may not exist).
        int LUiFile(lua_State* _pL)
        {
            const char* szrelative = luaL_checkstring(_pL, 1);
            auto* phost = Host(_pL);
            if (!phost)
            {
                return NoHost(_pL);
            }
            const std::string relative(szrelative);
            if (relative.find("..") != std::string::npos || relative.empty() || relative[0] == '/' ||
                relative.find(':') != std::string::npos)
            {
                return FailWith(_pL, "a path inside the interface's folder");
            }
            const std::string path = gitgud::app::PackageFile(phost->CurrentUi(), relative);
            lua_pushlstring(_pL, path.data(), path.size());
            return 1;
        }

        // gitgud.uiOverlayReset() -> backup folder | nil, msg: moves the
        // overlay aside (<overlay>.backup-<yyyymmdd-hhmmss>), then reloads.
        int LUiOverlayReset(lua_State* _pL)
        {
            namespace fs = std::filesystem;
            auto* phost = Host(_pL);
            if (!phost)
            {
                return NoHost(_pL);
            }
            const std::string root = phost->CurrentUi().m_OverlayRoot;
            std::error_code ec;
            if (root.empty() || !fs::exists(fs::u8path(root), ec))
            {
                return FailWith(_pL, "no customizations");
            }
            const std::time_t now = std::time(nullptr);
            std::tm local{};
#if defined(_WIN32)
            localtime_s(&local, &now);
#else
            localtime_r(&now, &local);
#endif
            char szstamp[32] = {};
            std::strftime(szstamp, sizeof(szstamp), "%Y%m%d-%H%M%S", &local);
            const std::string backup = root + ".backup-" + szstamp;
            fs::rename(fs::u8path(root), fs::u8path(backup), ec);
            if (ec)
            {
                return FailWith(_pL, "could not move " + root + ": " + ec.message());
            }
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"app.reload", "overlay reset"});
            }
            lua_pushlstring(_pL, backup.data(), backup.size());
            return 1;
        }

        // gitgud.openWindow{id, title, layout, width, height, minWidth, minHeight}
        int LOpenWindow(lua_State* _pL)
        {
            luaL_checktype(_pL, 1, LUA_TTABLE);
            auto* phost = Host(_pL);
            if (!phost)
            {
                return NoHost(_pL);
            }
            gitgud::app::WindowSpec spec;
            spec.m_Id = StringField(_pL, 1, "id");
            spec.m_Title = StringField(_pL, 1, "title");
            spec.m_Layout = StringField(_pL, 1, "layout");
            spec.m_iWidth = IntField(_pL, 1, "width", spec.m_iWidth);
            spec.m_iHeight = IntField(_pL, 1, "height", spec.m_iHeight);
            spec.m_iMinWidth = IntField(_pL, 1, "minWidth", spec.m_iMinWidth);
            spec.m_iMinHeight = IntField(_pL, 1, "minHeight", spec.m_iMinHeight);
            for (const char c : spec.m_Id)
            {
                const bool bok =
                    std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_';
                if (!bok)
                {
                    return FailWith(_pL, "Window ids use letters, digits, '-' and '_' only");
                }
            }
            if (spec.m_Id.empty() || spec.m_Layout.empty())
            {
                return FailWith(_pL, "openWindow needs an id and a layout");
            }
            std::string error;
            if (!phost->OpenWindow(spec, error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LCloseWindow(lua_State* _pL)
        {
            if (auto* phost = Host(_pL))
            {
                phost->CloseWindow(luaL_checkstring(_pL, 1));
            }
            return 0;
        }

        int LSetWindowTitle(lua_State* _pL)
        {
            if (auto* phost = Host(_pL))
            {
                phost->SetWindowTitle(luaL_checkstring(_pL, 1), luaL_checkstring(_pL, 2));
            }
            return 0;
        }

        int LFocusWindow(lua_State* _pL)
        {
            if (auto* phost = Host(_pL))
            {
                phost->FocusWindow(luaL_checkstring(_pL, 1));
            }
            return 0;
        }

        int LWindows(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            PushStringArray(_pL, phost ? phost->OpenWindows() : std::vector<std::string>{});
            return 1;
        }

        int LSetWindowBordered(lua_State* _pL)
        {
            if (auto* phost = Host(_pL))
            {
                phost->SetMainWindowBordered(lua_toboolean(_pL, 1) != 0);
            }
            return 0;
        }

        int LCurrentUi(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            if (!phost)
            {
                lua_pushnil(_pL);
                return 1;
            }
            PushPackage(_pL, phost->CurrentUi());
            return 1;
        }

        int LPreviousUi(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            const std::string previous = phost ? phost->PreviousUi() : std::string();
            lua_pushlstring(_pL, previous.data(), previous.size());
            return 1;
        }

        // gitgud.uiList() -> the packages a user can choose (the picker is hidden)
        int LUiList(lua_State* _pL)
        {
            lua_newtable(_pL);
            auto* phost = Host(_pL);
            if (!phost)
            {
                return 1;
            }
            int ii = 1;
            for (const auto& package : phost->AvailableUis())
            {
                if (package.m_bHidden)
                {
                    continue;
                }
                PushPackage(_pL, package);
                lua_rawseti(_pL, -2, ii++);
            }
            return 1;
        }

        // gitgud.switchUi(spec, remember = true): "default", a built-in id, or
        // "path:<folder>". Takes effect once the current handler returns.
        int LSwitchUi(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            if (!phost)
            {
                return NoHost(_pL);
            }
            const std::string spec = luaL_checkstring(_pL, 1);
            const bool bremember = lua_isnoneornil(_pL, 2) || lua_toboolean(_pL, 2) != 0;
            std::string error;
            if (!phost->RequestUiSwitch(spec, bremember, error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.showUiPicker() — the chooser, without remembering it.
        int LShowUiPicker(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            if (!phost)
            {
                return NoHost(_pL);
            }
            std::string error;
            if (!phost->RequestUiSwitch(gitgud::app::kUiPickerId, false, error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LFirstLaunch(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            lua_pushboolean(_pL, phost && phost->FirstLaunch());
            return 1;
        }

        // gitgud.themes() -> { "dark", "light" }: the running UI's colour themes.
        // gitgud.keepForReload(key, text): kept for the reloaded scripts
        // (nil forgets it).
        int LKeepForReload(lua_State* _pL)
        {
            const std::string key = luaL_checkstring(_pL, 1);
            if (lua_isnoneornil(_pL, 2))
            {
                Self(_pL)->ForgetKept(key);
                return 0;
            }
            std::size_t ulen = 0;
            const char* sztext = luaL_checklstring(_pL, 2, &ulen);
            Self(_pL)->Keep(key, std::string(sztext, ulen));
            return 0;
        }

        // gitgud.takeKept(key) -> text | nil: what was kept, once.
        int LTakeKept(lua_State* _pL)
        {
            std::string value;
            if (!Self(_pL)->TakeKept(luaL_checkstring(_pL, 1), value))
            {
                lua_pushnil(_pL);
                return 1;
            }
            lua_pushlstring(_pL, value.data(), value.size());
            return 1;
        }

        int LThemes(lua_State* _pL)
        {
            lua_newtable(_pL);
            if (auto* phost = Host(_pL))
            {
                lua_Integer ii = 1;
                for (const std::string& name : phost->Themes())
                {
                    lua_pushstring(_pL, name.c_str());
                    lua_rawseti(_pL, -2, ii++);
                }
            }
            return 1;
        }

        // gitgud.theme() -> the theme in use ("" when the UI has none).
        int LTheme(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            lua_pushstring(_pL, phost ? phost->CurrentTheme().c_str() : "");
            return 1;
        }

        // gitgud.setTheme(name): remember it and rebuild the UI in it once the
        // current handler returns. true, or nil and a message.
        int LSetTheme(lua_State* _pL)
        {
            auto* phost = Host(_pL);
            if (!phost)
            {
                return NoHost(_pL);
            }
            std::string error;
            if (!phost->RequestThemeSwitch(luaL_checkstring(_pL, 1), error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.restartApp(): start this program again (the same executable,
        // arguments, folder and environment) once this copy has exited, and
        // close this copy the way closing its window does. true, or nil and a
        // message (nothing closes then).
        int LRestartApp(lua_State* _pL)
        {
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return NoHost(_pL);
            }
            std::string error;
            if (!gitgud::platform::StartRelaunch(error))
            {
                return FailWith(_pL, error);
            }
            pbus->Publish({"window.close", "restart"});
            lua_pushboolean(_pL, 1);
            return 1;
        }

    } // namespace

    void AddAppBindings(std::vector<luaL_Reg>& _Out)
    {
        const luaL_Reg kFunctions[] = {
            {"openWindow", LOpenWindow},
            {"closeWindow", LCloseWindow},
            {"setWindowTitle", LSetWindowTitle},
            {"focusWindow", LFocusWindow},
            {"windows", LWindows},
            {"setWindowBordered", LSetWindowBordered},
            {"currentUi", LCurrentUi},
            {"uiOverlay", LUiOverlay},
            {"uiFile", LUiFile},
            {"uiOverlayReset", LUiOverlayReset},
            {"previousUi", LPreviousUi},
            {"uiList", LUiList},
            {"switchUi", LSwitchUi},
            {"showUiPicker", LShowUiPicker},
            {"firstLaunch", LFirstLaunch},
            {"themes", LThemes},
            {"theme", LTheme},
            {"setTheme", LSetTheme},
            {"keepForReload", LKeepForReload},
            {"takeKept", LTakeKept},
            {"restartApp", LRestartApp},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
