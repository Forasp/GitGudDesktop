// -----------------------------------------------------------------------------
// LuaAgentHistoryBindings: Claude Code's saved sessions, for the sessions
// list and for showing a session before resuming it (agent/ClaudeTranscripts).
//
//   gitgud.agentSessions(cwd)      -> { {id, title, asked, updated, active, cwd}, ... }
//                                     the most recently active first
//   gitgud.agentProjects(perProject?, maxProjects?)
//                                  -> { {cwd, folder, updated, sessions}, ... }
//                                     every project, most recently active
//                                     first (`updated`: its newest `active`);
//                                     sessions as agentSessions'
//   gitgud.agentHistory(cwd, id, max?) -> { {kind, text, id, name, input, isError,
//                                     images, uuid, parentUuid}, ... }; images:
//                                     the paths of the pictures in a user
//                                     message or tool result (agent/
//                                     ChatImages.h); uuid: its transcript
//                                     entry, parentUuid the one before it
//                                     ("" when none); only the branch the
//                                     session goes on from (a rewound one's)
//   gitgud.agentForkTranscript(cwd, id, upTo, toDir) -> id | nil, msg: a
//                                     copy of a session up to and including
//                                     entry `upTo` ("" or nil: all of it) as
//                                     a new session of the folder `toDir`
//                                     (Claude Code resumes a session only in
//                                     its own folder); its new id
//   gitgud.agentSessionProcesses(id) -> how many other processes have the
//                                     session id in their command line (a
//                                     Claude Code running it elsewhere)
//   gitgud.agentTitle(text)        -> a conversation's title from a user
//                                     message: its first line, without what
//                                     Claude Code or apps put in front of it
//                                     ("" when that's all it is)
//
// `title` is Claude Code's title for it, else the first thing asked
// (`asked`); `updated` is when the transcript was last written, `active` when its
// last message (asked or answered) was, both seconds since 1970; `cwd` is the working folder the
// transcript names ("" when none); `kind` is user, assistant, tool, or
// toolResult; a tool's `input` is JSON text (jsonDecode it); `max` keeps
// the latest that many (default 2000), and only they are read. A session
// is looked for in `cwd`'s folder, then in every project's. Resume a
// session with agentStart's `resume` option.
// -----------------------------------------------------------------------------

#include <algorithm>

#include "agent/ClaudeTranscripts.h"
#include "lua/LuaBindings.h"
#include "platform/Process.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        using agent::ClaudeTranscripts;

        void PushSessions(lua_State* _pL, const std::vector<agent::TranscriptSummary>& _Sessions)
        {
            lua_createtable(_pL, static_cast<int>(_Sessions.size()), 0);
            for (std::size_t i = 0; i < _Sessions.size(); ++i)
            {
                lua_createtable(_pL, 0, 6);
                SetField(_pL, "id", _Sessions[i].m_Id);
                SetField(_pL, "title", _Sessions[i].m_Title);
                SetField(_pL, "asked", _Sessions[i].m_Asked);
                SetField(_pL, "updated", static_cast<lua_Integer>(_Sessions[i].m_iUpdated));
                SetField(_pL, "active", static_cast<lua_Integer>(_Sessions[i].m_iActive));
                SetField(_pL, "cwd", _Sessions[i].m_Cwd);
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
        }

        int LAgentSessions(lua_State* _pL)
        {
            const std::string cwd = luaL_checkstring(_pL, 1);
            PushSessions(_pL, ClaudeTranscripts::List(cwd));
            return 1;
        }

        int LAgentProjects(lua_State* _pL)
        {
            const lua_Integer iper = luaL_optinteger(_pL, 1, 30);
            const lua_Integer imax = luaL_optinteger(_pL, 2, 100);
            const auto projects = ClaudeTranscripts::Projects(
                static_cast<std::size_t>(iper > 0 ? iper : 1), static_cast<std::size_t>(imax > 0 ? imax : 1));
            lua_createtable(_pL, static_cast<int>(projects.size()), 0);
            for (std::size_t i = 0; i < projects.size(); ++i)
            {
                lua_createtable(_pL, 0, 4);
                SetField(_pL, "cwd", projects[i].m_Cwd);
                SetField(_pL, "folder", projects[i].m_Folder);
                SetField(_pL, "updated", static_cast<lua_Integer>(projects[i].m_iUpdated));
                PushSessions(_pL, projects[i].m_Sessions);
                lua_setfield(_pL, -2, "sessions");
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

        int LAgentContextFiles(lua_State* _pL)
        {
            const std::string cwd = luaL_optstring(_pL, 1, "");
            const auto files = ClaudeTranscripts::ContextFiles(cwd);
            lua_createtable(_pL, static_cast<int>(files.size()), 0);
            for (std::size_t i = 0; i < files.size(); ++i)
            {
                lua_createtable(_pL, 0, 2);
                SetField(_pL, "kind", files[i].m_Kind);
                SetField(_pL, "path", files[i].m_Path);
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

        int LAgentConfigDir(lua_State* _pL)
        {
            const std::string dir = ClaudeTranscripts::ConfigDir();
            lua_pushlstring(_pL, dir.data(), dir.size());
            return 1;
        }

        int LAgentHistory(lua_State* _pL)
        {
            const std::string cwd = luaL_checkstring(_pL, 1);
            const std::string id = luaL_checkstring(_pL, 2);
            const lua_Integer imax = luaL_optinteger(_pL, 3, 2000);
            const auto entries =
                ClaudeTranscripts::Read(cwd, id, static_cast<std::size_t>(std::max<lua_Integer>(imax, 0)));
            lua_createtable(_pL, static_cast<int>(entries.size()), 0);
            for (std::size_t i = 0; i < entries.size(); ++i)
            {
                const agent::TranscriptEntry& entry = entries[i];
                lua_createtable(_pL, 0, 6);
                SetField(_pL, "kind", entry.m_Kind);
                SetField(_pL, "text", entry.m_Text);
                SetField(_pL, "id", entry.m_Id);
                SetField(_pL, "name", entry.m_Name);
                SetField(
                    _pL, "input", entry.m_Input.IsNull() ? std::string() : entry.m_Input.Dump());
                SetField(_pL, "isError", entry.m_bError);
                lua_createtable(_pL, static_cast<int>(entry.m_Images.size()), 0);
                for (std::size_t j = 0; j < entry.m_Images.size(); ++j)
                {
                    lua_pushstring(_pL, entry.m_Images[j].c_str());
                    lua_rawseti(_pL, -2, static_cast<lua_Integer>(j + 1));
                }
                lua_setfield(_pL, -2, "images");
                SetField(_pL, "uuid", entry.m_Uuid);
                SetField(_pL, "parentUuid", entry.m_ParentUuid);
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

        int LAgentForkTranscript(lua_State* _pL)
        {
            const std::string cwd = luaL_checkstring(_pL, 1);
            const std::string id = luaL_checkstring(_pL, 2);
            const std::string upTo = luaL_optstring(_pL, 3, "");
            const std::string toDir = luaL_checkstring(_pL, 4);
            const std::string forked = ClaudeTranscripts::Fork(cwd, id, upTo, toDir);
            if (forked.empty())
            {
                return FailWith(_pL, "No such conversation or message to copy");
            }
            lua_pushlstring(_pL, forked.data(), forked.size());
            return 1;
        }

        int LAgentSessionProcesses(lua_State* _pL)
        {
            const std::string id = luaL_checkstring(_pL, 1);
            // A real id only: a short needle would match everything.
            lua_pushinteger(_pL, id.size() < 16 ? 0
                                                : static_cast<lua_Integer>(
                                                      platform::ProcessesWithArgument(id).size()));
            return 1;
        }

        int LAgentTitle(lua_State* _pL)
        {
            const std::string title = ClaudeTranscripts::Title(luaL_checkstring(_pL, 1));
            lua_pushlstring(_pL, title.data(), title.size());
            return 1;
        }

    } // namespace

    void AddAgentHistoryBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"agentSessions", LAgentSessions});
        _Out.push_back({"agentProjects", LAgentProjects});
        _Out.push_back({"agentHistory", LAgentHistory});
        _Out.push_back({"agentForkTranscript", LAgentForkTranscript});
        _Out.push_back({"agentSessionProcesses", LAgentSessionProcesses});
        _Out.push_back({"agentTitle", LAgentTitle});
        _Out.push_back({"agentContextFiles", LAgentContextFiles});
        _Out.push_back({"agentConfigDir", LAgentConfigDir});
    }

} // namespace gitgud::lua::bindings
