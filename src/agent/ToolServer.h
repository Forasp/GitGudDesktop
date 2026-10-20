#pragma once

// -----------------------------------------------------------------------------
// ToolServer: the app's end of the tools for Claude Code: Git and P4
// (agent/RepoTools.h), and the tools the UI's scripts declare
// (SetUiTools; the Bragi UI's settings tools, bragi/settingstool.lua).
//
// Claude Code runs gitgud-mcp (src/mcp/McpMain.cpp, next to the app's exe)
// as an MCP server; it forwards each tool call over a named pipe to this
// server, which runs it (agent/RepoTools.h) on the repository open in the
// app. main.cpp sets it up to start on first use (StartOnDemand) and keeps
// SetRepository() current; sessions the app starts get McpConfigPath() as
// their --mcp-config (the main agent
// session McpConfigPath(true): with the UI's tools too).
//
// Each session gets a config of its own (McpConfigPath with the session's
// name), which runs `gitgud-mcp --session <name>`, so a call says which
// session made it: its Git and P4 tools act on that session's repository
// (SetSessionRepository: its working folder), else on the app's, and a UI
// tool can be kept to some sessions (a declared tool's `sessions`).
//
// Pipe messages, one JSON line each way per connection:
//   request  {"tool": "<name>", "arguments": {...}, "session": "<name>"}
//   reply    {"text": "...", "isError": false}
//   request  {"list": "ui", "session": "<name>"}
//   reply    {"tools": [...]}       the UI's tools that session sees
//
// Each call runs on its own pipe thread with its own Repository handle (the
// TaskRunner rule: never share the UI thread's handle), so nothing here
// touches the UI thread's objects. A UI tool call is handed to the UI
// thread as it came (the script checks it) through the app handler
// (main.cpp: the event "tools.call"), and its pipe thread waits for Reply()
// with the answer.
// -----------------------------------------------------------------------------

#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "agent/RepoTools.h"
#include "agent/ToolPipe.h"

namespace gitgud::agent
{

    class ToolServer
    {
      public:
        // Hands a UI tool call to the UI thread (any thread calls it). The
        // UI answers with Reply(_Id, ...). `_Session`: the calling
        // session's name ("" when it didn't say).
        using AppHandler = std::function<void(const std::string& _Id, const std::string& _Tool,
            const app::Json& _Arguments, const std::string& _Session)>;

        // How long a UI tool call waits for the UI's answer.
        static constexpr int kAppTimeoutMs = 15000;

        // The most tools a UI can declare.
        static constexpr std::size_t kMaxUiTools = 32;

        ToolServer();
        ~ToolServer(); // Stop()

        ToolServer(const ToolServer&) = delete;
        ToolServer& operator=(const ToolServer&) = delete;

        // The pipe name for this process: \\.\pipe\<app>-tools-<process id>.
        static std::string DefaultPipeName();

        // Listen on `_PipeName`. When `_McpProgram` (gitgud-mcp) exists, also
        // write MCP configs for it: `_ConfigPath` (the Git and P4 tools) and
        // beside it "<name>-ui.json" (those and the UI's tools).
        // False with `_Error` when the pipe can't be made; a config that
        // can't be written leaves McpConfigPath() empty.
        bool Start(const std::string& _PipeName, const std::string& _McpProgram,
            const std::string& _ConfigPath, std::string& _Error);

        // Start() on first use instead: the pipe and the MCP configs are made
        // when a session first asks for its config (McpConfigPath), so an
        // interface that never starts Claude Code sets nothing up. A failed
        // start is logged; the sessions then get no tools.
        void StartOnDemand(
            const std::string& _PipeName, const std::string& _McpProgram, const std::string& _ConfigPath);

        // Stop listening (waits for running calls; UI tool calls waiting
        // for the UI give up) and delete the configs.
        void Stop();

        // The repository or workspace the tools act on ("" = none). Any thread.
        void SetRepository(const std::string& _Path);
        std::string Repository() const;

        // The repository one session's tools act on ("" = the app's, above).
        // Any thread.
        void SetSessionRepository(const std::string& _Session, const std::string& _Path);
        std::string RepositoryFor(const std::string& _Session) const;

        // The UI's tools: MCP tools/list entries ({ name, description,
        // inputSchema, annotations?, sessions? }), replacing any declared
        // before (an empty array: none). Names are letters, digits, _ and
        // -, and not a Git or P4 tool's. `sessions`, a list of session
        // names, keeps a tool to those sessions. False with `_Error` when
        // one isn't right; nothing changes then. Any thread.
        bool SetUiTools(const app::Json& _Tools, std::string& _Error);
        // Every UI tool, as tools/list shows it (no `sessions`).
        app::Json UiTools() const;
        // The UI tools a session sees ("": those kept to no session).
        app::Json UiToolsFor(const std::string& _Session) const;

        // Where UI tool calls go ("" handler: they fail, saying so).
        void SetAppHandler(AppHandler _Handler);

        // The UI's answer to tool call `_Id`. False when no call by that id
        // is waiting (it timed out, or never was). Any thread.
        bool Reply(const std::string& _Id, const ToolResult& _Result);

        // The MCP config file for Claude Code, or "" when there is none.
        // `_bUiTools`: the one with the UI's tools (the main session).
        // `_Session`: a config of that session's own (written now, beside
        // the others, deleted by Stop()).
        std::string McpConfigPath(bool _bUiTools = false, const std::string& _Session = "");

        // The MCP config's JSON: one stdio server, "repo", running
        // `_McpProgram --pipe <_PipeName>` (and --ui-tools, and --session
        // <_Session>). Its tools show up in Claude Code as mcp__repo__<name>.
        static std::string McpConfig(const std::string& _McpProgram, const std::string& _PipeName,
            bool _bUiTools = false, const std::string& _Session = "");

        // Answer one pipe request line.
        std::string Handle(const std::string& _Request);

      private:
        struct Pending
        {
            bool m_bDone = false;
            ToolResult m_Result;
        };

        // A UI tool call: handed to the UI, its answer awaited.
        ToolResult CallApp(
            const std::string& _Tool, const app::Json& _Arguments, const std::string& _Session);

        // The start StartOnDemand put off, once.
        void EnsureStarted();

        bool IsUiTool(const std::string& _Name) const;
        bool SeesUiTool(const std::string& _Name, const std::string& _Session) const;

        ToolPipeServer m_Pipe;
        mutable std::mutex m_Mutex;
        std::condition_variable m_Replied;
        std::string m_Repository;
        std::map<std::string, std::string> m_SessionRepositories;
        std::string m_McpProgram; // set once its configs are written
        std::string m_PipeName;
        std::string m_ConfigPath;
        std::string m_UiConfigPath;
        std::map<std::string, std::string> m_SessionConfigs; // file name -> path
        app::Json m_UiTools = app::Json::Array();
        std::map<std::string, std::vector<std::string>> m_UiToolSessions; // tool -> sessions
        AppHandler m_AppHandler;
        std::map<std::string, std::shared_ptr<Pending>> m_Pending;
        unsigned m_uNextCall = 0;
        bool m_bStopping = false;
        bool m_bDeferred = false; // StartOnDemand's start is still to come
        std::string m_DeferredPipe;
        std::string m_DeferredProgram;
        std::string m_DeferredConfig;
    };

} // namespace gitgud::agent
