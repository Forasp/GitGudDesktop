// -----------------------------------------------------------------------------
// LuaAppBindings — the application shell: pop-out windows and user-interface
// packages (see app/IAppHost.h and app/UiPackages.h).
// -----------------------------------------------------------------------------

#include <cctype>
#include <iterator>
#include <string>

#include "app/IAppHost.h"
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
            SetField(_pL, "builtIn", _Package.m_bBuiltIn);
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
            {"previousUi", LPreviousUi},
            {"uiList", LUiList},
            {"switchUi", LSwitchUi},
            {"showUiPicker", LShowUiPicker},
            {"firstLaunch", LFirstLaunch},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
