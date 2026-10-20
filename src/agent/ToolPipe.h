#pragma once

// -----------------------------------------------------------------------------
// ToolPipe: a local named pipe carrying one request line and one reply line
// per connection, between gitgud-mcp (the MCP server Claude Code starts) and
// the running app, which answers with the open repository.
//
// The server listens on its own thread and answers each connection on a
// worker thread through `Handler`, so a slow tool never holds up the next
// call. Only the current user's processes on this machine can connect.
// Windows only for now (elsewhere Start and Call fail).
// -----------------------------------------------------------------------------

#include <functional>
#include <memory>
#include <string>

namespace gitgud::agent
{

    class ToolPipeServer
    {
      public:
        // One request line in (no line break), the reply line out.
        using Handler = std::function<std::string(const std::string& _Request)>;

        ToolPipeServer();
        ~ToolPipeServer(); // Stop()

        ToolPipeServer(const ToolPipeServer&) = delete;
        ToolPipeServer& operator=(const ToolPipeServer&) = delete;

        // Listen on `_Name` ("\\.\pipe\..."). False with `_Error` when the
        // pipe can't be made (another process has the name).
        bool Start(const std::string& _Name, Handler _Handler, std::string& _Error);

        // Stop listening, cancel waiting connections, and wait for the
        // handlers that are running.
        void Stop();

        bool Running() const;

      private:
        struct Impl;
        std::unique_ptr<Impl> m_pImpl;
    };

    // Send `_Request` (one line) to the server on `_Name` and wait up to
    // `_iTimeoutMs` for its reply line. False with `_Error` when the server
    // isn't there or doesn't answer.
    bool CallToolPipe(const std::string& _Name, const std::string& _Request, int _iTimeoutMs,
        std::string& _Reply, std::string& _Error);

} // namespace gitgud::agent
