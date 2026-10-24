// -----------------------------------------------------------------------------
// LuaLookupBindings: values from large sorted "key<TAB>value" files
// (app/SortedTable.h), for word lists too big to hold as Lua tables.
//
//   gitgud.lookup(path, key)       -> value | nil (no entry) | nil, msg (the
//                                     file couldn't be used). `path` must be
//                                     a .tsv file; each file is read once and
//                                     kept for the rest of the run.
// -----------------------------------------------------------------------------

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "app/SortedTable.h"
#include "lua/LuaBindings.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        struct Opened
        {
            std::unique_ptr<app::SortedTable> m_pTable; // null: it failed
            std::string m_Error;
        };

        // Scripts run on the UI thread only, so no lock.
        std::map<std::string, Opened>& Tables()
        {
            static std::map<std::string, Opened> s_Tables;
            return s_Tables;
        }

        bool EndsWith(const std::string& _Text, const char* _szEnd)
        {
            const std::string end(_szEnd);
            return _Text.size() >= end.size() &&
                   _Text.compare(_Text.size() - end.size(), end.size(), end) == 0;
        }

        int LLookup(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            std::size_t nlength = 0;
            const char* szkey = luaL_checklstring(_pL, 2, &nlength);
            if (!EndsWith(path, ".tsv"))
            {
                return FailWith(_pL, "lookup files are .tsv files");
            }
            auto it = Tables().find(path);
            if (it == Tables().end())
            {
                Opened opened;
                auto ptable = std::make_unique<app::SortedTable>();
                if (ptable->Load(path, opened.m_Error))
                {
                    opened.m_pTable = std::move(ptable);
                }
                it = Tables().emplace(path, std::move(opened)).first;
            }
            if (!it->second.m_pTable)
            {
                return FailWith(_pL, it->second.m_Error);
            }
            const auto value = it->second.m_pTable->Find(std::string_view(szkey, nlength));
            if (!value)
            {
                lua_pushnil(_pL);
                return 1;
            }
            lua_pushlstring(_pL, value->data(), value->size());
            return 1;
        }

    } // namespace

    void AddLookupBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"lookup", LLookup});
    }

} // namespace gitgud::lua::bindings
