#include "agent/ToolServer.h"

#include <cstdio>

#include "agent/RepoTools.h"
#include "app/Json.h"
#include "platform/Shell.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <unistd.h>
#endif

#include <algorithm>
#include <cctype>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <vector>

namespace fs = std::filesystem;

namespace gitgud::agent
{

    namespace
    {

        // The server's name in the MCP config (tools are mcp__repo__<name>).
        constexpr const char* kServerName = "repo";

        // Longest UI tool name taken ("mcp__repo__" goes in front of it).
        constexpr std::size_t kMaxToolName = 50;

        bool IsRepoTool(const std::string& _Name)
        {
            for (const app::Json& tool : ToolDefinitions().Items())
            {
                if (tool["name"].AsString() == _Name)
                {
                    return true;
                }
            }
            return false;
        }

        bool IsToolName(const std::string& _Name)
        {
            if (_Name.empty() || _Name.size() > kMaxToolName)
            {
                return false;
            }
            for (const char c : _Name)
            {
                if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '-')
                {
                    return false;
                }
            }
            return true;
        }

    } // namespace

    ToolServer::ToolServer() = default;

    ToolServer::~ToolServer()
    {
        Stop();
    }

    std::string ToolServer::DefaultPipeName()
    {
#if defined(_WIN32)
        const unsigned long ulpid = GetCurrentProcessId();
#else
        const unsigned long ulpid = static_cast<unsigned long>(getpid());
#endif
        const std::string app = "gitgud";
        return "\\\\.\\pipe\\" + app + "-tools-" + std::to_string(ulpid);
    }

    std::string ToolServer::McpConfig(const std::string& _McpProgram, const std::string& _PipeName,
        bool _bUiTools, const std::string& _Session)
    {
        app::Json args = app::Json::Array().Push("--pipe").Push(_PipeName);
        if (_bUiTools)
        {
            args.Push("--ui-tools");
        }
        if (!_Session.empty())
        {
            args.Push("--session").Push(_Session);
        }
        app::Json server = app::Json::Object();
        server.Set("type", "stdio");
        server.Set("command", _McpProgram);
        server.Set("args", std::move(args));
        app::Json config = app::Json::Object();
        config.Set("mcpServers", app::Json::Object().Set(kServerName, std::move(server)));
        return config.Dump();
    }

    bool ToolServer::Start(const std::string& _PipeName, const std::string& _McpProgram,
        const std::string& _ConfigPath, std::string& _Error)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bStopping = false;
        }
        if (!m_Pipe.Start(
                _PipeName, [this](const std::string& _Request) { return Handle(_Request); },
                _Error))
        {
            return false;
        }
        std::error_code ec;
        if (_McpProgram.empty() || _ConfigPath.empty() || !fs::exists(fs::u8path(_McpProgram), ec))
        {
            return true;
        }
        const fs::path config = fs::u8path(_ConfigPath);
        fs::create_directories(config.parent_path(), ec);
        const fs::path uiConfig =
            config.parent_path() / (config.stem().u8string() + "-ui" + config.extension().u8string());
        for (const bool bui : {false, true})
        {
            const fs::path& path = bui ? uiConfig : config;
            std::ofstream out(path, std::ios::binary | std::ios::trunc);
            out << McpConfig(_McpProgram, _PipeName, bui) << "\n";
            out.close();
            if (out)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                (bui ? m_UiConfigPath : m_ConfigPath) = path.u8string();
                m_McpProgram = _McpProgram;
                m_PipeName = _PipeName;
            }
        }
        return true;
    }

    void ToolServer::Stop()
    {
        {
            // UI tool calls waiting for the UI give up: the UI may be what's
            // stopping us.
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bStopping = true;
        }
        m_Replied.notify_all();
        m_Pipe.Stop();
        std::vector<std::string> configs(2);
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            configs[0].swap(m_ConfigPath);
            configs[1].swap(m_UiConfigPath);
            for (auto& [name, path] : m_SessionConfigs)
            {
                configs.push_back(path);
            }
            m_SessionConfigs.clear();
            m_McpProgram.clear();
        }
        for (const std::string& config : configs)
        {
            if (!config.empty())
            {
                std::error_code ec;
                fs::remove(fs::u8path(config), ec);
            }
        }
    }

    bool ToolServer::SetUiTools(const app::Json& _Tools, std::string& _Error)
    {
        if (!_Tools.IsArray() || _Tools.Size() > kMaxUiTools)
        {
            _Error = "The tools must be a list of at most " + std::to_string(kMaxUiTools);
            return false;
        }
        app::Json tools = app::Json::Array();
        std::vector<std::string> names;
        std::map<std::string, std::vector<std::string>> sessions;
        for (const app::Json& tool : _Tools.Items())
        {
            const std::string name = tool["name"].AsString();
            if (!IsToolName(name))
            {
                _Error = "A tool's name is letters, digits, _ and - ('" + name + "' isn't)";
                return false;
            }
            if (IsRepoTool(name) || std::find(names.begin(), names.end(), name) != names.end())
            {
                _Error = "There's already a tool named '" + name + "'";
                return false;
            }
            if (!tool["description"].IsString() || !tool["inputSchema"].IsObject() ||
                tool["inputSchema"]["type"].AsString() != "object")
            {
                _Error =
                    "Tool '" + name + "' needs a description and an inputSchema of type object";
                return false;
            }
            app::Json entry = app::Json::Object()
                                  .Set("name", name)
                                  .Set("description", tool["description"])
                                  .Set("inputSchema", tool["inputSchema"]);
            if (tool["annotations"].IsObject())
            {
                entry.Set("annotations", tool["annotations"]);
            }
            if (tool.Has("sessions"))
            {
                // {} is how Lua writes an empty list.
                const bool bempty = tool["sessions"].IsObject() && tool["sessions"].Keys().empty();
                if (!tool["sessions"].IsArray() && !bempty)
                {
                    _Error = "Tool '" + name + "': sessions must be a list of session names";
                    return false;
                }
                std::vector<std::string>& only = sessions[name];
                for (const app::Json& session : bempty ? std::vector<app::Json>() : tool["sessions"].Items())
                {
                    if (!session.IsString() || session.AsString().empty())
                    {
                        _Error = "Tool '" + name + "': sessions must be a list of session names";
                        return false;
                    }
                    only.push_back(session.AsString());
                }
            }
            names.push_back(name);
            tools.Push(std::move(entry));
        }
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_UiTools = std::move(tools);
        m_UiToolSessions = std::move(sessions);
        return true;
    }

    app::Json ToolServer::UiTools() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_UiTools;
    }

    app::Json ToolServer::UiToolsFor(const std::string& _Session) const
    {
        app::Json tools = app::Json::Array();
        const app::Json all = UiTools();
        for (const app::Json& tool : all.Items())
        {
            if (SeesUiTool(tool["name"].AsString(), _Session))
            {
                tools.Push(tool);
            }
        }
        return tools;
    }

    bool ToolServer::SeesUiTool(const std::string& _Name, const std::string& _Session) const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        const auto it = m_UiToolSessions.find(_Name);
        return it == m_UiToolSessions.end() ||
               std::find(it->second.begin(), it->second.end(), _Session) != it->second.end();
    }

    bool ToolServer::IsUiTool(const std::string& _Name) const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        for (const app::Json& tool : m_UiTools.Items())
        {
            if (tool["name"].AsString() == _Name)
            {
                return true;
            }
        }
        return false;
    }

    void ToolServer::SetAppHandler(AppHandler _Handler)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_AppHandler = std::move(_Handler);
    }

    bool ToolServer::Reply(const std::string& _Id, const ToolResult& _Result)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            const auto it = m_Pending.find(_Id);
            if (it == m_Pending.end() || it->second->m_bDone)
            {
                return false;
            }
            it->second->m_bDone = true;
            it->second->m_Result = _Result;
        }
        m_Replied.notify_all();
        return true;
    }

    ToolResult ToolServer::CallApp(
        const std::string& _Tool, const app::Json& _Arguments, const std::string& _Session)
    {
        // Only the shape is checked here; what the arguments may be is the
        // script's to check.
        if (!_Arguments.IsNull() && !_Arguments.IsObject())
        {
            return {"The arguments must be an object", true};
        }
        const app::Json arguments = _Arguments.IsNull() ? app::Json::Object() : _Arguments;
        AppHandler handler;
        std::string id;
        auto ppending = std::make_shared<Pending>();
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            handler = m_AppHandler;
            if (!handler || m_bStopping)
            {
                return {"The app can't answer this from here (no interface listens).", true};
            }
            id = "call-" + std::to_string(++m_uNextCall);
            m_Pending[id] = ppending;
        }
        handler(id, _Tool, arguments, _Session);
        std::unique_lock<std::mutex> lock(m_Mutex);
        const bool banswered = m_Replied.wait_for(lock, std::chrono::milliseconds(kAppTimeoutMs),
            [&] { return ppending->m_bDone || m_bStopping; });
        m_Pending.erase(id);
        if (!banswered || !ppending->m_bDone)
        {
            return {"The app didn't answer (it may be busy or closing). Nothing was changed.",
                true};
        }
        return ppending->m_Result;
    }

    void ToolServer::SetRepository(const std::string& _Path)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_Repository = _Path;
    }

    std::string ToolServer::Repository() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_Repository;
    }

    void ToolServer::SetSessionRepository(const std::string& _Session, const std::string& _Path)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (_Path.empty())
        {
            m_SessionRepositories.erase(_Session);
        }
        else
        {
            m_SessionRepositories[_Session] = _Path;
        }
    }

    std::string ToolServer::RepositoryFor(const std::string& _Session) const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        const auto it = m_SessionRepositories.find(_Session);
        return it != m_SessionRepositories.end() ? it->second : m_Repository;
    }

    void ToolServer::StartOnDemand(
        const std::string& _PipeName, const std::string& _McpProgram, const std::string& _ConfigPath)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_bDeferred = true;
        m_DeferredPipe = _PipeName;
        m_DeferredProgram = _McpProgram;
        m_DeferredConfig = _ConfigPath;
    }

    void ToolServer::EnsureStarted()
    {
        std::string pipe;
        std::string program;
        std::string config;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (!m_bDeferred)
            {
                return;
            }
            m_bDeferred = false;
            pipe = m_DeferredPipe;
            program = m_DeferredProgram;
            config = m_DeferredConfig;
        }
        std::string error;
        if (!Start(pipe, program, config, error))
        {
            std::fprintf(stderr, "[agent] no Git tools for Claude Code: %s\n", error.c_str());
        }
    }

    std::string ToolServer::McpConfigPath(bool _bUiTools, const std::string& _Session)
    {
        EnsureStarted();
        std::lock_guard<std::mutex> lock(m_Mutex);
        const std::string& shared = _bUiTools ? m_UiConfigPath : m_ConfigPath;
        if (_Session.empty() || shared.empty() || m_McpProgram.empty())
        {
            return shared;
        }
        // <name>[-ui]-s-<session>.json beside the shared one.
        std::string safe = _Session;
        for (char& c : safe)
        {
            if (!std::isalnum(static_cast<unsigned char>(c)) && c != '-' && c != '_')
            {
                c = '_';
            }
        }
        const fs::path base = fs::u8path(m_ConfigPath.empty() ? shared : m_ConfigPath);
        const std::string file = base.stem().u8string() + (_bUiTools ? "-ui" : "") + "-s-" + safe +
                                 base.extension().u8string();
        const fs::path path = base.parent_path() / fs::u8path(file);
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        out << McpConfig(m_McpProgram, m_PipeName, _bUiTools, _Session) << "\n";
        out.close();
        if (!out)
        {
            return shared;
        }
        m_SessionConfigs[file] = path.u8string();
        return path.u8string();
    }

    std::string ToolServer::Handle(const std::string& _Request)
    {
        ToolResult result;
        std::string error;
        const std::optional<app::Json> request = app::Json::Parse(_Request, &error);
        const std::string session = request ? (*request)["session"].AsString() : std::string();
        if (request && (*request)["list"].AsString() == "ui")
        {
            return app::Json::Object().Set("tools", UiToolsFor(session)).Dump();
        }
        if (!request || !(*request)["tool"].IsString())
        {
            result = {"Bad request from gitgud-mcp: " + (request ? "no tool" : error), true};
        }
        else if (IsUiTool((*request)["tool"].AsString()))
        {
            const std::string tool = (*request)["tool"].AsString();
            result = SeesUiTool(tool, session)
                         ? CallApp(tool, (*request)["arguments"], session)
                         : ToolResult{"The tool '" + tool + "' isn't available in this session", true};
        }
        else
        {
            result = RunTool(
                RepositoryFor(session), (*request)["tool"].AsString(), (*request)["arguments"]);
        }
        return app::Json::Object()
            .Set("text", result.m_Text)
            .Set("isError", result.m_bIsError)
            .Dump();
    }

} // namespace gitgud::agent
