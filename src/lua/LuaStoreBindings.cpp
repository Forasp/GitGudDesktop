// -----------------------------------------------------------------------------
// LuaStoreBindings: files kept in bare Git repositories in the config folder,
// each change a commit (git/BareStore.h), for scripts' own stores (the Bragi
// interface's local wikis). `store` is a config name for the repository's
// folder ("bragi/wikis/app.wiki.git"); `ref` is a revision (default HEAD).
//
//   gitgud.bareFiles(store, ref?)    -> { {path, size}, ... } sorted by path
//                                       ({} for a store not made yet)
//   gitgud.bareRead(store, file, ref?) -> text | nil (not there)
//   gitgud.bareCommit(store, changes, message, name?, email?)
//                                    -> commit id ("" when nothing changed)
//                                       | nil, msg. Makes the store when
//                                       missing. changes: { {path, content},
//                                       ... }, content false to remove
//   gitgud.bareLog(store, file?, max?) -> { {id, message, author, time}, ... }
//                                       newest first, only commits that
//                                       changed `file` when given; time is
//                                       seconds since 1970
//
// Failures (a bad name, a missing revision) return nil, msg.
// -----------------------------------------------------------------------------

#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "git/BareStore.h"
#include "git/Repository.h"
#include "lua/LuaBindings.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        namespace barestore = git::barestore;

        // The store's path from argument `_iArg`; raises a Lua error on a bad
        // name (before any C++ object needing cleanup exists).
        std::string StorePath(lua_State* _pL, int _iArg)
        {
            const char* szname = luaL_checkstring(_pL, _iArg);
            luaL_argcheck(_pL, IsConfigName(szname), _iArg, "invalid config name");
            return ConfigFile(szname);
        }

        std::string OptionalString(lua_State* _pL, int _iArg)
        {
            return lua_isnoneornil(_pL, _iArg) ? std::string() : std::string(luaL_checkstring(_pL, _iArg));
        }

        int LBareFiles(lua_State* _pL)
        {
            const std::string store = StorePath(_pL, 1);
            const std::string ref = OptionalString(_pL, 2);
            std::vector<git::StoreFile> files;
            std::string error;
            try
            {
                if (barestore::Exists(store))
                {
                    files = barestore::Files(store, ref);
                }
            }
            catch (const std::exception& e)
            {
                error = e.what();
            }
            if (!error.empty())
            {
                return FailWith(_pL, error);
            }
            lua_createtable(_pL, static_cast<int>(files.size()), 0);
            for (std::size_t i = 0; i < files.size(); ++i)
            {
                lua_createtable(_pL, 0, 2);
                SetField(_pL, "path", files[i].m_Path);
                lua_pushinteger(_pL, static_cast<lua_Integer>(files[i].m_uSize));
                lua_setfield(_pL, -2, "size");
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

        int LBareRead(lua_State* _pL)
        {
            const std::string store = StorePath(_pL, 1);
            const std::string file = luaL_checkstring(_pL, 2);
            const std::string ref = OptionalString(_pL, 3);
            std::optional<std::string> content;
            std::string error;
            try
            {
                if (barestore::Exists(store))
                {
                    content = barestore::Read(store, file, ref);
                }
            }
            catch (const std::exception& e)
            {
                error = e.what();
            }
            if (!error.empty())
            {
                return FailWith(_pL, error);
            }
            if (!content)
            {
                lua_pushnil(_pL);
                return 1;
            }
            lua_pushlstring(_pL, content->data(), content->size());
            return 1;
        }

        int LBareCommit(lua_State* _pL)
        {
            const std::string store = StorePath(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TTABLE);
            const std::string message = luaL_checkstring(_pL, 3);
            const std::string name = lua_isnoneornil(_pL, 4) ? "GitGud" : luaL_checkstring(_pL, 4);
            const std::string email = lua_isnoneornil(_pL, 5) ? "gitgud@localhost" : luaL_checkstring(_pL, 5);

            std::vector<git::StoreChange> changes;
            const lua_Integer icount = static_cast<lua_Integer>(lua_rawlen(_pL, 2));
            for (lua_Integer i = 1; i <= icount; ++i)
            {
                lua_rawgeti(_pL, 2, i);
                if (!lua_istable(_pL, -1))
                {
                    lua_pop(_pL, 1);
                    return FailWith(_pL, "each change is a table {path, content}");
                }
                lua_getfield(_pL, -1, "path");
                lua_getfield(_pL, -2, "content");
                git::StoreChange change;
                if (lua_type(_pL, -2) != LUA_TSTRING || *lua_tostring(_pL, -2) == '\0')
                {
                    lua_pop(_pL, 3);
                    return FailWith(_pL, "a change needs a path");
                }
                change.m_Path = lua_tostring(_pL, -2);
                if (lua_type(_pL, -1) == LUA_TSTRING)
                {
                    std::size_t nlength = 0;
                    const char* sz = lua_tolstring(_pL, -1, &nlength);
                    change.m_Content = std::string(sz, nlength);
                }
                else if (!(lua_isboolean(_pL, -1) && !lua_toboolean(_pL, -1)))
                {
                    lua_pop(_pL, 3);
                    return FailWith(_pL, "content is text, or false to remove the file");
                }
                lua_pop(_pL, 3);
                changes.push_back(std::move(change));
            }

            std::string id;
            std::string error;
            try
            {
                id = barestore::Commit(store, changes, message, name, email);
            }
            catch (const std::exception& e)
            {
                error = e.what();
            }
            if (!error.empty())
            {
                return FailWith(_pL, error);
            }
            lua_pushlstring(_pL, id.data(), id.size());
            return 1;
        }

        int LBareLog(lua_State* _pL)
        {
            const std::string store = StorePath(_pL, 1);
            const std::string file = OptionalString(_pL, 2);
            const lua_Integer imax = luaL_optinteger(_pL, 3, 50);
            std::vector<git::StoreCommit> commits;
            std::string error;
            try
            {
                if (barestore::Exists(store))
                {
                    commits = barestore::Log(store, file, static_cast<std::size_t>(imax > 0 ? imax : 50));
                }
            }
            catch (const std::exception& e)
            {
                error = e.what();
            }
            if (!error.empty())
            {
                return FailWith(_pL, error);
            }
            lua_createtable(_pL, static_cast<int>(commits.size()), 0);
            for (std::size_t i = 0; i < commits.size(); ++i)
            {
                lua_createtable(_pL, 0, 4);
                SetField(_pL, "id", commits[i].m_Id);
                SetField(_pL, "message", commits[i].m_Message);
                SetField(_pL, "author", commits[i].m_Author);
                lua_pushinteger(_pL, static_cast<lua_Integer>(commits[i].m_iTime));
                lua_setfield(_pL, -2, "time");
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

    } // namespace

    void AddStoreBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"bareFiles", LBareFiles});
        _Out.push_back({"bareRead", LBareRead});
        _Out.push_back({"bareCommit", LBareCommit});
        _Out.push_back({"bareLog", LBareLog});
    }

} // namespace gitgud::lua::bindings
