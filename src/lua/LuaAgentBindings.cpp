// -----------------------------------------------------------------------------
// LuaAgentBindings: Claude Code sessions (agent/ClaudeSession.h) for scripts.
// A script names each session; the names stay valid across script reloads,
// and the sessions keep running through them: the reloaded scripts find
// them with agentList and take them up again.
//
//   gitgud.agentStart(name, options?) -> true | nil, msg. options:
//       { cwd, model, permissionMode, resume, systemPrompt (replaces
//         Claude Code's own), appendSystemPrompt, mcpConfig, program }
//         (program defaults to "claude"; mcpConfig to the app's Git and P4
//         tools, agent/ToolServer.h; false for none), persist (false: no
//         transcript is saved, for helper sessions), lean (true: no tools,
//         skills, CLAUDE.md, or auto memory, for helper sessions; without a
//         cwd it runs in an empty folder of its own), tools (the built-in
//         tools it keeps, "Read,Grep,Glob"; with lean, "" or unset is none),
//         uiTools (true: the tools the UI declared, declareTools, as
//         well; for the main agent session only), repository (the folder
//         its Git and P4 tools act on; default its cwd; false: the app's
//         open repository), resumeAt (with resume: only its messages up
//         to and including this transcript entry's uuid; the next turn
//         goes on from there), forkSession (true, with resume: a new
//         session with the history, the resumed one left as it was)
//   gitgud.agentSend(name, text, images?) -> true | nil, msg: images, a list
//                                     of image files, go before the text
//                                     (scaled down to what the model takes)
//   gitgud.agentRespond(name, requestId, allow, message?)
//                                     -> true | nil, msg
//   gitgud.agentAnswer(name, requestId, answers)
//                                     -> true | nil, msg: answer Claude's
//                                     questions (AskUserQuestion); answers
//                                     maps each question's text to the
//                                     chosen label(s) joined with ", ", or
//                                     your own words
//   gitgud.agentInterrupt(name)       -> true | nil, msg
//   gitgud.agentSetMode(name, mode) / gitgud.agentSetModel(name, model)
//                                     -> true | nil, msg
//   gitgud.agentControl(name, subtype, fields?)
//                                     -> requestId | nil, msg: ask Claude
//                                     Code anything its control protocol
//                                     takes (get_usage, apply_flag_settings,
//                                     ...), fields (a table, or JSON text
//                                     for a null) beside the subtype; the
//                                     reply is "agent.control" ({ requestId,
//                                     subtype, ok, response, error, session })
//   gitgud.agentStopTask(name, taskId) -> true | nil, msg: stop one of its
//                                     tasks (a sub-agent or a background
//                                     command; the id is from its
//                                     task_started system event)
//   gitgud.agentStop(name)            ends it (input closed, then killed
//                                     after 1.5 s); its "agent.exit" follows
//   gitgud.agentInfo(name)            -> { name, running, turnActive,
//                                     sessionId, pendingPermission, pid,
//                                     pending = { {requestId, tool, input
//                                     (JSON text)}, ... }, options = what
//                                     agentStart was given } or nil
//   gitgud.agentList()                -> every session started under a
//                                     name (running or not), by name, each
//                                     as agentInfo has it
//
//   gitgud.declareTools(tools)       -> true | nil, msg: the UI's own tools
//                                     for Claude Code (agent/ToolServer.h),
//                                     MCP tools/list entries { name,
//                                     description, inputSchema, annotations? },
//                                     replacing any declared before ({}: none)
//   gitgud.toolReply(id, text, isError?) -> true | false
//                                     answers a call of one of them, the
//                                     event "tools.call" ({ id, tool,
//                                     arguments, session }, unchecked: the
//                                     script checks them); false when it's
//                                     no longer waiting. A declared tool's
//                                     `sessions` (a list of names) keeps it
//                                     to those sessions
//
// Events are "agent.<type>" (init, block, text, thinking, message, tool,
// usage, toolResult, permission, result, rateLimit, system, error, stderr,
// exit; see
// ClaudeSession.h), each with JSON text: the event's fields plus
// "session", the name.
// -----------------------------------------------------------------------------

#include <atomic>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "agent/ChatImages.h"
#include "agent/ClaudeSession.h"
#include "agent/ToolServer.h"
#include "app/EventBus.h"
#include "app/Json.h"
#include "lua/LuaBindings.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        using agent::ClaudeSession;
        using app::Json;

        // name -> session. Only the UI thread touches the map. Shared: a
        // session being stopped stays alive on its stopper thread.
        std::map<std::string, std::shared_ptr<ClaudeSession>> g_Sessions;

        // Sessions ending on threads of their own (agentStop), joined at exit.
        struct Stopper
        {
            std::thread m_Thread;
            std::shared_ptr<std::atomic<bool>> m_Done;
        };
        std::mutex g_StoppersMutex;
        std::vector<Stopper> g_Stoppers;

        ClaudeSession* Find(const std::string& _Name)
        {
            const auto it = g_Sessions.find(_Name);
            return it != g_Sessions.end() ? it->second.get() : nullptr;
        }

        std::string OptionField(lua_State* _pL, int _iTable, const char* _szKey)
        {
            if (!lua_istable(_pL, _iTable))
            {
                return {};
            }
            lua_getfield(_pL, _iTable, _szKey);
            std::string value;
            if (lua_type(_pL, -1) == LUA_TSTRING)
            {
                value = lua_tostring(_pL, -1);
            }
            lua_pop(_pL, 1);
            return value;
        }

        int Done(lua_State* _pL, bool _bOk, const char* _szError)
        {
            if (!_bOk)
            {
                return FailWith(_pL, _szError);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LAgentStart(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            auto* pbus = Self(_pL)->EventBus();
            if (!pbus)
            {
                return FailWith(_pL, "no event bus");
            }
            ClaudeSession* pexisting = Find(name);
            if (pexisting && pexisting->Running())
            {
                return FailWith(_pL, "The session '" + name + "' is already running");
            }

            ClaudeSession::Options options;
            const std::string program = OptionField(_pL, 2, "program");
            if (!program.empty())
            {
                options.m_Program = program;
            }
            options.m_WorkingDir = OptionField(_pL, 2, "cwd");
            options.m_Model = OptionField(_pL, 2, "model");
            options.m_PermissionMode = OptionField(_pL, 2, "permissionMode");
            options.m_Effort = OptionField(_pL, 2, "effort");
            options.m_Settings = OptionField(_pL, 2, "settings");
            options.m_Resume = OptionField(_pL, 2, "resume");
            options.m_ResumeAt = OptionField(_pL, 2, "resumeAt");
            options.m_SystemPrompt = OptionField(_pL, 2, "systemPrompt");
            options.m_AppendSystemPrompt = OptionField(_pL, 2, "appendSystemPrompt");
            options.m_McpConfig = OptionField(_pL, 2, "mcpConfig");
            options.m_Tools = OptionField(_pL, 2, "tools");
            // The folder its Git and P4 tools act on: `repository`, else its
            // cwd; repository = false: the app's open repository.
            std::string repository = OptionField(_pL, 2, "repository");
            bool bappRepository = false;
            if (lua_istable(_pL, 2))
            {
                lua_getfield(_pL, 2, "repository");
                bappRepository = lua_type(_pL, -1) == LUA_TBOOLEAN && !lua_toboolean(_pL, -1);
                lua_pop(_pL, 1);
            }
            if (repository.empty() && !bappRepository)
            {
                repository = options.m_WorkingDir;
            }
            // No mcpConfig: the app's Git and P4 tools (mcpConfig = false: none).
            bool bnoTools = false;
            if (lua_istable(_pL, 2))
            {
                lua_getfield(_pL, 2, "mcpConfig");
                bnoTools = lua_type(_pL, -1) == LUA_TBOOLEAN && !lua_toboolean(_pL, -1);
                lua_pop(_pL, 1);
                // persist = false: Claude Code keeps no transcript (helper sessions).
                lua_getfield(_pL, 2, "persist");
                options.m_bPersist = !(lua_type(_pL, -1) == LUA_TBOOLEAN && !lua_toboolean(_pL, -1));
                lua_pop(_pL, 1);
                lua_getfield(_pL, 2, "lean");
                options.m_bLean = lua_toboolean(_pL, -1) != 0;
                lua_pop(_pL, 1);
                lua_getfield(_pL, 2, "forkSession");
                options.m_bForkSession = lua_toboolean(_pL, -1) != 0;
                lua_pop(_pL, 1);
            }
            if (options.m_bLean && options.m_WorkingDir.empty())
            {
                // Nothing in it to load: no project, no CLAUDE.md.
                std::error_code ec;
                const std::filesystem::path dir =
                    std::filesystem::temp_directory_path(ec) / "gitgud-helper";
                if (!ec)
                {
                    std::filesystem::create_directories(dir, ec);
                }
                if (!ec)
                {
                    options.m_WorkingDir = dir.u8string();
                }
            }
            if (options.m_McpConfig.empty() && !bnoTools && Self(_pL)->ToolServer())
            {
                // uiTools = true: the UI's declared tools too (the main
                // agent session only).
                bool buiTools = false;
                if (lua_istable(_pL, 2))
                {
                    lua_getfield(_pL, 2, "uiTools");
                    buiTools = lua_toboolean(_pL, -1) != 0;
                    lua_pop(_pL, 1);
                }
                // A config of its own, so its calls say which session made them.
                options.m_McpConfig = Self(_pL)->ToolServer()->McpConfigPath(buiTools, name);
            }
            if (Self(_pL)->ToolServer())
            {
                Self(_pL)->ToolServer()->SetSessionRepository(name, repository);
            }

            // A finished session under this name goes; its events are delivered.
            g_Sessions.erase(name);
            auto psession = std::make_shared<ClaudeSession>();
            std::string error;
            const bool bstarted = psession->Start(
                options,
                [pbus, name](const std::string& _Type, const Json& _Detail)
                {
                    Json detail = _Detail;
                    detail.Set("session", name);
                    pbus->Publish({"agent." + _Type, detail.Dump()});
                },
                error);
            if (!bstarted)
            {
                return FailWith(_pL, error);
            }
            g_Sessions[name] = std::move(psession);
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // The running session named by argument 1, or nullptr.
        ClaudeSession* Running(lua_State* _pL)
        {
            ClaudeSession* psession = Find(luaL_checkstring(_pL, 1));
            return psession && psession->Running() ? psession : nullptr;
        }

        int LAgentSend(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const std::string text = luaL_checkstring(_pL, 2);
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            std::vector<Json> images;
            if (lua_istable(_pL, 3))
            {
                const lua_Integer ncount = static_cast<lua_Integer>(lua_rawlen(_pL, 3));
                for (lua_Integer i = 1; i <= ncount; ++i)
                {
                    lua_rawgeti(_pL, 3, i);
                    const std::string path = lua_isstring(_pL, -1) ? lua_tostring(_pL, -1) : "";
                    lua_pop(_pL, 1);
                    std::string error;
                    Json block = agent::ImageBlockFromFile(path, error);
                    if (block.IsNull())
                    {
                        return FailWith(_pL, "Couldn't attach an image: " + error);
                    }
                    images.push_back(std::move(block));
                }
            }
            return Done(_pL, psession->Send(text, images), "Couldn't write to the session");
        }

        int LAgentRespond(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const char* szrequest = luaL_checkstring(_pL, 2);
            const char* szmessage = luaL_optstring(_pL, 4, "");
            const bool ballow = lua_toboolean(_pL, 3) != 0;
            const std::string requestId = szrequest;
            const std::string message = szmessage;
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            return Done(_pL, psession->Respond(requestId, ballow, message),
                "No such permission request is waiting");
        }

        int LAgentAnswer(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const std::string requestId = luaL_checkstring(_pL, 2);
            luaL_checktype(_pL, 3, LUA_TTABLE);
            Json answers;
            try
            {
                answers = LuaToJson(_pL, 3);
            }
            catch (const std::exception& _Error)
            {
                return FailWith(_pL, std::string("Bad answers: ") + _Error.what());
            }
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            return Done(_pL, psession->Answer(requestId, answers),
                "No such question is waiting, or there's no answer");
        }

        int LAgentInterrupt(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            return Done(_pL, psession->Interrupt(), "No turn is running");
        }

        int LAgentSetMode(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const std::string mode = luaL_checkstring(_pL, 2);
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            return Done(_pL, psession->SetPermissionMode(mode), "Couldn't write to the session");
        }

        int LAgentSetModel(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const std::string model = luaL_checkstring(_pL, 2);
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            return Done(_pL, psession->SetModel(model), "Couldn't write to the session");
        }

        int LAgentControl(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const std::string subtype = luaL_checkstring(_pL, 2);
            Json fields = Json::Object();
            if (lua_type(_pL, 3) == LUA_TSTRING)
            {
                // JSON text, for what a table can't say (null).
                std::optional<Json> parsed = Json::Parse(lua_tostring(_pL, 3));
                if (!parsed || !parsed->IsObject())
                {
                    return FailWith(_pL, "Bad fields: not a JSON object");
                }
                fields = std::move(*parsed);
            }
            else if (!lua_isnoneornil(_pL, 3))
            {
                luaL_checktype(_pL, 3, LUA_TTABLE);
                try
                {
                    fields = LuaToJson(_pL, 3);
                }
                catch (const std::exception& _Error)
                {
                    return FailWith(_pL, std::string("Bad fields: ") + _Error.what());
                }
            }
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            const std::string requestId = psession->Control(subtype, fields);
            if (requestId.empty())
            {
                return FailWith(_pL, "Couldn't write to the session");
            }
            lua_pushlstring(_pL, requestId.data(), requestId.size());
            return 1;
        }

        int LAgentStopTask(lua_State* _pL)
        {
            ClaudeSession* psession = Running(_pL);
            const std::string taskId = luaL_checkstring(_pL, 2);
            if (!psession)
            {
                return FailWith(_pL, "The session isn't running");
            }
            return Done(_pL, psession->StopTask(taskId), "Couldn't write to the session");
        }

        int LAgentStop(lua_State* _pL)
        {
            const auto it = g_Sessions.find(luaL_checkstring(_pL, 1));
            if (it == g_Sessions.end())
            {
                return 0;
            }
            // Its input closes, then it gets a moment to exit before it's
            // killed: waited for off the UI thread (a session takes about
            // 200 ms to end, and switching away from an idle conversation,
            // or stopping voice's helpers one after another, froze the app
            // that long each time). It reads as running until it has ended.
            std::shared_ptr<ClaudeSession> psession = it->second;
            auto done = std::make_shared<std::atomic<bool>>(false);
            std::lock_guard<std::mutex> lock(g_StoppersMutex);
            for (auto stopper = g_Stoppers.begin(); stopper != g_Stoppers.end();)
            {
                if (stopper->m_Done->load())
                {
                    stopper->m_Thread.join();
                    stopper = g_Stoppers.erase(stopper);
                }
                else
                {
                    ++stopper;
                }
            }
            g_Stoppers.push_back({std::thread(
                                      [psession, done]
                                      {
                                          psession->Stop();
                                          done->store(true);
                                      }),
                done});
            return 0;
        }

        int LDeclareTools(lua_State* _pL)
        {
            luaL_checktype(_pL, 1, LUA_TTABLE);
            agent::ToolServer* ptools = Self(_pL)->ToolServer();
            if (!ptools)
            {
                return FailWith(_pL, "No tool server");
            }
            Json tools;
            try
            {
                tools = LuaToJson(_pL, 1);
            }
            catch (const std::exception& e)
            {
                return FailWith(_pL, std::string("The tools can't be sent: ") + e.what());
            }
            if (tools.IsObject() && tools.Keys().empty())
            {
                tools = Json::Array(); // {} is how Lua writes an empty list
            }
            std::string error;
            const bool bok = ptools->SetUiTools(tools, error);
            return Done(_pL, bok, error.c_str());
        }

        int LToolReply(lua_State* _pL)
        {
            const std::string id = luaL_checkstring(_pL, 1);
            const std::string reply = luaL_checkstring(_pL, 2);
            const bool berror = lua_toboolean(_pL, 3) != 0;
            agent::ToolServer* ptools = Self(_pL)->ToolServer();
            lua_pushboolean(_pL, ptools && ptools->Reply(id, {reply, berror}) ? 1 : 0);
            return 1;
        }

        // A session as agentInfo and agentList give it.
        void PushInfo(lua_State* _pL, const std::string& _Name, const ClaudeSession& _Session)
        {
            lua_newtable(_pL);
            SetField(_pL, "name", _Name);
            SetField(_pL, "running", _Session.Running());
            SetField(_pL, "turnActive", _Session.TurnActive());
            SetField(_pL, "sessionId", _Session.SessionId());
            SetField(_pL, "pendingPermission", _Session.PendingPermission());
            SetField(_pL, "pid", static_cast<lua_Integer>(_Session.ProcessId()));

            const std::vector<ClaudeSession::Request> pending = _Session.PendingRequests();
            lua_createtable(_pL, static_cast<int>(pending.size()), 0);
            for (std::size_t i = 0; i < pending.size(); ++i)
            {
                lua_createtable(_pL, 0, 3);
                SetField(_pL, "requestId", pending[i].m_RequestId);
                SetField(_pL, "tool", pending[i].m_Tool);
                SetField(_pL, "input",
                    pending[i].m_Input.IsNull() ? std::string("{}") : pending[i].m_Input.Dump());
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            lua_setfield(_pL, -2, "pending");

            // What it was started with, so a reloaded script can tell
            // whether it's still the session it wants.
            const ClaudeSession::Options& options = _Session.StartOptions();
            lua_newtable(_pL);
            SetField(_pL, "program", options.m_Program);
            SetField(_pL, "cwd", options.m_WorkingDir);
            SetField(_pL, "model", options.m_Model);
            SetField(_pL, "permissionMode", options.m_PermissionMode);
            SetField(_pL, "effort", options.m_Effort);
            SetField(_pL, "settings", options.m_Settings);
            SetField(_pL, "resume", options.m_Resume);
            SetField(_pL, "resumeAt", options.m_ResumeAt);
            SetField(_pL, "forkSession", options.m_bForkSession);
            SetField(_pL, "systemPrompt", options.m_SystemPrompt);
            SetField(_pL, "appendSystemPrompt", options.m_AppendSystemPrompt);
            SetField(_pL, "mcpConfig", options.m_McpConfig);
            SetField(_pL, "tools", options.m_Tools);
            SetField(_pL, "persist", options.m_bPersist);
            SetField(_pL, "lean", options.m_bLean);
            lua_setfield(_pL, -2, "options");
        }

        int LAgentInfo(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            ClaudeSession* psession = Find(name);
            if (!psession)
            {
                lua_pushnil(_pL);
                return 1;
            }
            PushInfo(_pL, name, *psession);
            return 1;
        }

        int LAgentList(lua_State* _pL)
        {
            lua_createtable(_pL, static_cast<int>(g_Sessions.size()), 0);
            lua_Integer i = 1;
            for (const auto& [name, psession] : g_Sessions)
            {
                PushInfo(_pL, name, *psession);
                lua_rawseti(_pL, -2, i++);
            }
            return 1;
        }

    } // namespace

    void StopAgents()
    {
        std::vector<Stopper> stoppers;
        {
            std::lock_guard<std::mutex> lock(g_StoppersMutex);
            stoppers.swap(g_Stoppers);
        }
        for (Stopper& stopper : stoppers)
        {
            stopper.m_Thread.join();
        }
        g_Sessions.clear();
    }

    void AddAgentBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"agentStart", LAgentStart});
        _Out.push_back({"agentSend", LAgentSend});
        _Out.push_back({"agentRespond", LAgentRespond});
        _Out.push_back({"agentAnswer", LAgentAnswer});
        _Out.push_back({"agentInterrupt", LAgentInterrupt});
        _Out.push_back({"agentSetMode", LAgentSetMode});
        _Out.push_back({"agentSetModel", LAgentSetModel});
        _Out.push_back({"agentControl", LAgentControl});
        _Out.push_back({"agentStopTask", LAgentStopTask});
        _Out.push_back({"agentStop", LAgentStop});
        _Out.push_back({"agentInfo", LAgentInfo});
        _Out.push_back({"agentList", LAgentList});
        _Out.push_back({"declareTools", LDeclareTools});
        _Out.push_back({"toolReply", LToolReply});
    }

} // namespace gitgud::lua::bindings
