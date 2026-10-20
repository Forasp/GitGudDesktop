// -----------------------------------------------------------------------------
// LuaJsonBindings: JSON for scripts (app/Json.h).
//
//   gitgud.jsonDecode(text)        -> value | nil, msg (JSON null is nil; an
//                                     empty table encodes as {})
//   gitgud.jsonEncode(value)       -> text | nil, msg
// -----------------------------------------------------------------------------

#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "app/Json.h"
#include "lua/LuaBindings.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        using app::Json;

        constexpr int kMaxDepth = 64;

        // Room for a few more slots, or an exception: a Lua error here would
        // jump over C++ destructors.
        void Reserve(lua_State* _pL)
        {
            if (!lua_checkstack(_pL, 4))
            {
                throw std::runtime_error("nested too deep");
            }
        }

        void PushJson(lua_State* _pL, const Json& _Value, int _iDepth)
        {
            if (_iDepth > kMaxDepth)
            {
                throw std::runtime_error("nested too deep");
            }
            Reserve(_pL);
            switch (_Value.GetType())
            {
            case Json::Type::Null:
                lua_pushnil(_pL);
                break;
            case Json::Type::Bool:
                lua_pushboolean(_pL, _Value.AsBool());
                break;
            case Json::Type::Number:
                if (static_cast<double>(_Value.AsInt()) == _Value.AsNumber())
                {
                    lua_pushinteger(_pL, static_cast<lua_Integer>(_Value.AsInt()));
                }
                else
                {
                    lua_pushnumber(_pL, _Value.AsNumber());
                }
                break;
            case Json::Type::String:
                lua_pushlstring(_pL, _Value.AsString().data(), _Value.AsString().size());
                break;
            case Json::Type::Array:
            {
                lua_createtable(_pL, static_cast<int>(_Value.Size()), 0);
                lua_Integer i = 1;
                for (const Json& item : _Value.Items())
                {
                    PushJson(_pL, item, _iDepth + 1);
                    lua_rawseti(_pL, -2, i++);
                }
                break;
            }
            case Json::Type::Object:
            {
                lua_createtable(_pL, 0, static_cast<int>(_Value.Size()));
                for (const std::string& key : _Value.Keys())
                {
                    PushJson(_pL, _Value[key], _iDepth + 1);
                    lua_setfield(_pL, -2, key.c_str());
                }
                break;
            }
            }
        }

        // The value at `_iIndex` as JSON; throws on what JSON can't hold.
        Json ToJson(lua_State* _pL, int _iIndex, int _iDepth)
        {
            if (_iDepth > kMaxDepth)
            {
                throw std::runtime_error("nested too deep (or a table contains itself)");
            }
            Reserve(_pL);
            _iIndex = lua_absindex(_pL, _iIndex);
            switch (lua_type(_pL, _iIndex))
            {
            case LUA_TNIL:
                return Json();
            case LUA_TBOOLEAN:
                return Json(lua_toboolean(_pL, _iIndex) != 0);
            case LUA_TNUMBER:
                if (lua_isinteger(_pL, _iIndex))
                {
                    return Json(static_cast<int64_t>(lua_tointeger(_pL, _iIndex)));
                }
                return Json(static_cast<double>(lua_tonumber(_pL, _iIndex)));
            case LUA_TSTRING:
            {
                std::size_t nlength = 0;
                const char* sz = lua_tolstring(_pL, _iIndex, &nlength);
                return Json(std::string(sz, nlength));
            }
            case LUA_TTABLE:
            {
                // An array when the keys are exactly 1..n; else an object with
                // string keys.
                const lua_Integer ilength = static_cast<lua_Integer>(lua_rawlen(_pL, _iIndex));
                lua_Integer icount = 0;
                bool barray = true;
                lua_pushnil(_pL);
                while (lua_next(_pL, _iIndex) != 0)
                {
                    ++icount;
                    if (!lua_isinteger(_pL, -2))
                    {
                        barray = false;
                    }
                    lua_pop(_pL, 1);
                }
                if (icount == 0)
                {
                    return Json::Object();
                }
                if (barray && icount == ilength)
                {
                    Json array = Json::Array();
                    for (lua_Integer i = 1; i <= ilength; ++i)
                    {
                        lua_rawgeti(_pL, _iIndex, i);
                        array.Push(ToJson(_pL, -1, _iDepth + 1));
                        lua_pop(_pL, 1);
                    }
                    return array;
                }
                Json object = Json::Object();
                lua_pushnil(_pL);
                while (lua_next(_pL, _iIndex) != 0)
                {
                    if (lua_type(_pL, -2) != LUA_TSTRING)
                    {
                        lua_pop(_pL, 2);
                        throw std::runtime_error("object keys must be strings");
                    }
                    const std::string key = lua_tostring(_pL, -2);
                    object.Set(key, ToJson(_pL, -1, _iDepth + 1));
                    lua_pop(_pL, 1);
                }
                return object;
            }
            default:
                throw std::runtime_error(
                    std::string("can't encode a ") + luaL_typename(_pL, _iIndex));
            }
        }

        int LJsonDecode(lua_State* _pL)
        {
            std::size_t nlength = 0;
            const char* sz = luaL_checklstring(_pL, 1, &nlength);
            std::string error;
            std::optional<Json> value = Json::Parse(std::string(sz, nlength), &error);
            if (!value)
            {
                return FailWith(_pL, error);
            }
            const int itop = lua_gettop(_pL);
            try
            {
                PushJson(_pL, *value, 0);
            }
            catch (const std::exception& e)
            {
                lua_settop(_pL, itop);
                return FailWith(_pL, e.what());
            }
            return 1;
        }

        int LJsonEncode(lua_State* _pL)
        {
            luaL_checkany(_pL, 1);
            std::string text;
            try
            {
                text = ToJson(_pL, 1, 0).Dump();
            }
            catch (const std::exception& e)
            {
                lua_settop(_pL, 1);
                return FailWith(_pL, e.what());
            }
            lua_pushlstring(_pL, text.data(), text.size());
            return 1;
        }

    } // namespace

    app::Json LuaToJson(lua_State* _pL, int _iIndex)
    {
        return ToJson(_pL, _iIndex, 0);
    }

    void AddJsonBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"jsonDecode", LJsonDecode});
        _Out.push_back({"jsonEncode", LJsonEncode});
    }

} // namespace gitgud::lua::bindings
