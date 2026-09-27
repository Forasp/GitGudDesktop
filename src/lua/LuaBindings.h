#pragma once

// -----------------------------------------------------------------------------
// LuaBindings — shared helpers for the `gitgud` binding implementation files
// (LuaRepoBindings.cpp, LuaUiBindings.cpp, LuaFeatureBindings.cpp). Internal to src/lua/.
//
// Every binding is a plain lua_CFunction whose first upvalue is the owning
// LuaEngine (see LuaEngine::InstallBindings), reached through Self().
// -----------------------------------------------------------------------------

#include <string>
#include <vector>

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}

#include "lua/LuaEngine.h"

namespace gitgud::git
{
    struct FileDiff;
}

namespace gitgud::lua::bindings
{

    inline LuaEngine* Self(lua_State* _pL)
    {
        return static_cast<LuaEngine*>(lua_touserdata(_pL, lua_upvalueindex(1)));
    }

    inline void SetField(lua_State* _pL, const char* _szKey, const std::string& _V)
    {
        lua_pushlstring(_pL, _V.data(), _V.size());
        lua_setfield(_pL, -2, _szKey);
    }

    inline void SetField(lua_State* _pL, const char* _szKey, bool _bV)
    {
        lua_pushboolean(_pL, _bV);
        lua_setfield(_pL, -2, _szKey);
    }

    inline void SetField(lua_State* _pL, const char* _szKey, lua_Integer _V)
    {
        lua_pushinteger(_pL, _V);
        lua_setfield(_pL, -2, _szKey);
    }

    inline void SetField(lua_State* _pL, const char* _szKey, const char* _szV)
    {
        lua_pushstring(_pL, _szV);
        lua_setfield(_pL, -2, _szKey);
    }

    // Sync actions share the (nil, message) failure convention.
    inline int FailWith(lua_State* _pL, const std::string& _Message)
    {
        lua_pushnil(_pL);
        lua_pushlstring(_pL, _Message.data(), _Message.size());
        return 2;
    }

    inline int NoRepo(lua_State* _pL)
    {
        return FailWith(_pL, "No repository is open");
    }

    // A string argument or an array of strings, as a vector.
    std::vector<std::string> StringList(lua_State* _pL, int _iArg);

    // Push an array of strings.
    void PushStringArray(lua_State* _pL, const std::vector<std::string>& _Items);

    // Push a FileDiff as a Lua table (hunks -> lines, 1-based like all of Lua).
    void PushFileDiff(lua_State* _pL, const gitgud::git::FileDiff& _Diff);

    // Each file appends its functions to the `gitgud` table's registry.
    void AddRepoBindings(std::vector<luaL_Reg>& _Out);
    void AddUiBindings(std::vector<luaL_Reg>& _Out);
    void AddFeatureBindings(std::vector<luaL_Reg>& _Out);

} // namespace gitgud::lua::bindings
