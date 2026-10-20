#pragma once

// -----------------------------------------------------------------------------
// RepoTools: the Git and Perforce tools Claude Code gets from the app, as an
// MCP server (see agent/ToolServer.h for how they're served).
//
// ToolDefinitions() is what the MCP server lists (name, description, JSON
// schema of the arguments); RepoToolDefs.cpp, needing nothing but Json, so
// the small gitgud-mcp program builds it too. RunTool() runs one on a
// repository (RepoTools.cpp, in gitgud_core).
//
// Every tool only reads (each is annotated readOnlyHint). Like any MCP tool,
// each call goes through Claude Code's permission prompt unless the session's
// permission mode or settings allow it.
// -----------------------------------------------------------------------------

#include <string>

#include "app/Json.h"

namespace gitgud::agent
{

    struct ToolResult
    {
        std::string m_Text;
        bool m_bIsError = false;
    };

    // The MCP tools/list entries: { name, description, inputSchema }.
    const app::Json& ToolDefinitions();

    // Whether `_Name` is one of ToolDefinitions().
    bool IsTool(const std::string& _Name);

    // Run tool `_Name` with `_Arguments` (an object) on the repository or
    // workspace at `_RepoPath` ("" = none open). Opens its own handle, so any
    // thread may call it. Failures come back as an error result, never thrown.
    ToolResult RunTool(
        const std::string& _RepoPath, const std::string& _Name, const app::Json& _Arguments);

} // namespace gitgud::agent
