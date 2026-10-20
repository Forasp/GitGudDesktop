#include "agent/McpProtocol.h"

#include <istream>
#include <ostream>
#include <utility>

namespace gitgud::agent
{

    namespace
    {

        using app::Json;

        // JSON-RPC 2.0 error codes.
        constexpr int kParseError = -32700;
        constexpr int kInvalidRequest = -32600;
        constexpr int kMethodNotFound = -32601;
        constexpr int kInvalidParams = -32602;

        std::string Reply(const Json& _Id, Json _Result)
        {
            return Json::Object()
                .Set("jsonrpc", "2.0")
                .Set("id", _Id)
                .Set("result", std::move(_Result))
                .Dump();
        }

        std::string Error(const Json& _Id, int _iCode, const std::string& _Message)
        {
            return Json::Object()
                .Set("jsonrpc", "2.0")
                .Set("id", _Id)
                .Set("error", Json::Object().Set("code", _iCode).Set("message", _Message))
                .Dump();
        }

    } // namespace

    McpProtocol::McpProtocol(
        app::Json _Tools, CallTool _CallTool, std::string _ServerName, std::string _ServerVersion)
        : McpProtocol([tools = std::move(_Tools)] { return tools; }, std::move(_CallTool),
              std::move(_ServerName), std::move(_ServerVersion))
    {
    }

    McpProtocol::McpProtocol(
        ListTools _ListTools, CallTool _CallTool, std::string _ServerName, std::string _ServerVersion)
        : m_ListTools(std::move(_ListTools)), m_CallTool(std::move(_CallTool)),
          m_ServerName(std::move(_ServerName)), m_ServerVersion(std::move(_ServerVersion))
    {
    }

    app::Json McpProtocol::Initialize(const app::Json& _Params) const
    {
        std::string version = kProtocolVersion;
        const std::string asked = _Params["protocolVersion"].AsString();
        if (asked == "2024-11-05" || asked == "2025-03-26" || asked == "2025-06-18")
        {
            version = asked;
        }
        return Json::Object()
            .Set("protocolVersion", version)
            .Set("capabilities",
                Json::Object().Set("tools", Json::Object().Set("listChanged", false)))
            .Set("serverInfo",
                Json::Object().Set("name", m_ServerName).Set("version", m_ServerVersion))
            .Set("instructions",
                "Read-only Git and Perforce tools for the repository open in the app: status, "
                "diff, log, show, branches, and p4_changes on Perforce workspaces.");
    }

    std::string McpProtocol::HandleLine(const std::string& _Line)
    {
        if (_Line.find_first_not_of(" \t\r\n") == std::string::npos)
        {
            return {};
        }
        std::string error;
        const std::optional<Json> parsed = Json::Parse(_Line, &error);
        if (!parsed)
        {
            return Error(Json(), kParseError, "Parse error: " + error);
        }
        const Json& message = *parsed;
        if (!message.IsObject())
        {
            return Error(Json(), kInvalidRequest, "Expected one JSON-RPC object per line");
        }
        const bool bhasId = message.Has("id");
        const Json& id = message["id"];
        if (!message["method"].IsString())
        {
            // A response to us (we send no requests), or junk.
            if (bhasId && (message.Has("result") || message.Has("error")))
            {
                return {};
            }
            return Error(bhasId ? id : Json(), kInvalidRequest, "No method");
        }
        const std::string& method = message["method"].AsString();
        if (!bhasId)
        {
            // A notification (notifications/initialized, cancelled, ...).
            return {};
        }
        if (!id.IsString() && !id.IsNumber())
        {
            return Error(Json(), kInvalidRequest, "The id must be a string or a number");
        }
        const Json& params = message["params"];

        if (method == "initialize")
        {
            return Reply(id, Initialize(params));
        }
        if (method == "ping")
        {
            return Reply(id, Json::Object());
        }
        if (method == "tools/list")
        {
            return Reply(id, Json::Object().Set("tools", m_ListTools()));
        }
        if (method == "tools/call")
        {
            const std::string& name = params["name"].AsString();
            bool bknown = false;
            const Json tools = m_ListTools();
            for (const Json& tool : tools.Items())
            {
                bknown = bknown || tool["name"].AsString() == name;
            }
            if (!bknown)
            {
                return Error(id, kInvalidParams, "Unknown tool: " + name);
            }
            const Json& arguments = params["arguments"];
            if (!arguments.IsNull() && !arguments.IsObject())
            {
                return Error(id, kInvalidParams, "The arguments must be an object");
            }
            const ToolResult result =
                m_CallTool ? m_CallTool(name, arguments.IsNull() ? Json::Object() : arguments)
                           : ToolResult{"No tool handler", true};
            Json content =
                Json::Array().Push(Json::Object().Set("type", "text").Set("text", result.m_Text));
            return Reply(id, Json::Object()
                                 .Set("content", std::move(content))
                                 .Set("isError", result.m_bIsError));
        }
        return Error(id, kMethodNotFound, "Method not found: " + method);
    }

    void McpProtocol::Run(std::istream& _In, std::ostream& _Out)
    {
        std::string line;
        while (std::getline(_In, line))
        {
            const std::string reply = HandleLine(line);
            if (!reply.empty())
            {
                _Out << reply << '\n';
                _Out.flush();
            }
        }
    }

} // namespace gitgud::agent
