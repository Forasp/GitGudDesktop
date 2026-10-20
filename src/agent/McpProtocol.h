#pragma once

// -----------------------------------------------------------------------------
// McpProtocol: the MCP stdio server side of gitgud-mcp. JSON-RPC 2.0, one
// message per line: initialize, notifications/initialized, ping, tools/list,
// tools/call. Unknown methods get a JSON-RPC error; notifications and
// responses get no reply. Tool calls go to `CallTool`, whose result becomes
// `content: [{type: "text", text}]` with `isError`.
// -----------------------------------------------------------------------------

#include <functional>
#include <iosfwd>
#include <string>

#include "agent/RepoTools.h"
#include "app/Json.h"

namespace gitgud::agent
{

    class McpProtocol
    {
      public:
        using CallTool =
            std::function<ToolResult(const std::string& _Name, const app::Json& _Arguments)>;

        // The newest protocol version we speak; an older one the client asks
        // for is used instead when we know it.
        static constexpr const char* kProtocolVersion = "2025-06-18";

        // The tools/list entries, asked for at each tools/list and
        // tools/call (a list that can change, like the UI's tools).
        using ListTools = std::function<app::Json()>;

        McpProtocol(app::Json _Tools, CallTool _CallTool, std::string _ServerName,
            std::string _ServerVersion);
        McpProtocol(ListTools _ListTools, CallTool _CallTool, std::string _ServerName,
            std::string _ServerVersion);

        // One input line; the reply line, or "" when there is none.
        std::string HandleLine(const std::string& _Line);

        // Answer every line of `_In` on `_Out` until end of input.
        void Run(std::istream& _In, std::ostream& _Out);

      private:
        app::Json Initialize(const app::Json& _Params) const;

        ListTools m_ListTools;
        CallTool m_CallTool;
        std::string m_ServerName;
        std::string m_ServerVersion;
    };

} // namespace gitgud::agent
