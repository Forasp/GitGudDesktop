// -----------------------------------------------------------------------------
// gitgud-mcp: the MCP server Claude Code starts for the app's Git and P4
// tools (agent/ToolServer.h). It speaks MCP on stdin and stdout and forwards
// each tool call over the pipe named on its command line to the running app:
//
//   gitgud-mcp --pipe \\.\pipe\<app>-tools-<process id> [--ui-tools]
//              [--session <name>]
//
// --ui-tools adds the tools the app's interface declares (the Bragi UI's
// settings tools; ToolServer::SetUiTools), for the main agent session only.
// It asks the app for them at each tools/list and tools/call. --session
// names the session it serves: each request carries it, so the tools act
// on that session's repository and it sees the UI tools meant for it.
//
// The app writes the MCP config that runs it; nothing else is needed. When
// the app isn't there, tool calls come back as errors that say so.
// -----------------------------------------------------------------------------

#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#endif

#include "agent/McpProtocol.h"
#include "agent/RepoTools.h"
#include "agent/ToolPipe.h"
#include "app/Json.h"

#if !defined(GITGUD_VERSION)
#define GITGUD_VERSION "0"
#endif

namespace
{

    using gitgud::agent::ToolResult;
    using gitgud::app::Json;

    // Long enough for a Perforce server that's slow to answer.
    constexpr int kCallTimeoutMs = 120000;

    // The UI's tools come from the app's memory: quick, or not at all.
    constexpr int kListTimeoutMs = 5000;

    // The Git and P4 tools, then the UI's (none when the app isn't there).
    Json ListTools(const std::string& _Pipe, const std::string& _Session)
    {
        Json tools = gitgud::agent::ToolDefinitions();
        std::string reply;
        std::string error;
        const std::string request = Json::Object().Set("list", "ui").Set("session", _Session).Dump();
        if (_Pipe.empty() ||
            !gitgud::agent::CallToolPipe(_Pipe, request, kListTimeoutMs, reply, error))
        {
            return tools;
        }
        const std::optional<Json> parsed = Json::Parse(reply);
        if (parsed)
        {
            for (const Json& tool : (*parsed)["tools"].Items())
            {
                tools.Push(tool);
            }
        }
        return tools;
    }

    ToolResult Forward(const std::string& _Pipe, const std::string& _Session, const std::string& _Name,
        const Json& _Arguments)
    {
        if (_Pipe.empty())
        {
            return {"gitgud-mcp was started without --pipe, so it can't reach the app", true};
        }
        Json message = Json::Object().Set("tool", _Name).Set("arguments", _Arguments);
        if (!_Session.empty())
        {
            message.Set("session", _Session);
        }
        const std::string request = message.Dump();
        std::string reply;
        std::string error;
        if (!gitgud::agent::CallToolPipe(_Pipe, request, kCallTimeoutMs, reply, error))
        {
            return {"The app isn't reachable (is it still running?): " + error, true};
        }
        const std::optional<Json> parsed = Json::Parse(reply);
        if (!parsed || !(*parsed)["text"].IsString())
        {
            return {"The app sent a reply that isn't understood", true};
        }
        return {(*parsed)["text"].AsString(), (*parsed)["isError"].AsBool()};
    }

} // namespace

int main(int _iArgc, char** _aSzArgv)
{
    std::string pipe;
    std::string session;
    bool buiTools = false;
    for (int i = 1; i < _iArgc; ++i)
    {
        if (std::strcmp(_aSzArgv[i], "--pipe") == 0 && i + 1 < _iArgc)
        {
            pipe = _aSzArgv[++i];
        }
        else if (std::strcmp(_aSzArgv[i], "--ui-tools") == 0)
        {
            buiTools = true;
        }
        else if (std::strcmp(_aSzArgv[i], "--session") == 0 && i + 1 < _iArgc)
        {
            session = _aSzArgv[++i];
        }
        else if (std::strcmp(_aSzArgv[i], "--version") == 0)
        {
            std::printf("gitgud-mcp %s\n", GITGUD_VERSION);
            return 0;
        }
    }

#if defined(_WIN32)
    // JSON lines exactly as written: no "\r\n" translation.
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    std::ios::sync_with_stdio(false);

    gitgud::agent::McpProtocol protocol(
        [&pipe, &session, buiTools]
        { return buiTools ? ListTools(pipe, session) : gitgud::agent::ToolDefinitions(); },
        [&pipe, &session](const std::string& _Name, const Json& _Arguments)
        { return Forward(pipe, session, _Name, _Arguments); }, "gitgud-mcp", GITGUD_VERSION);
    protocol.Run(std::cin, std::cout);
    return 0;
}
