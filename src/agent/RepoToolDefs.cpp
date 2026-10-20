// The tool definitions (agent/RepoTools.h). Only Json here: gitgud-mcp
// builds this file too.

#include "agent/RepoTools.h"

namespace gitgud::agent
{

    namespace
    {

        using app::Json;

        Json Property(const char* _szType, const char* _szDescription)
        {
            return Json::Object().Set("type", _szType).Set("description", _szDescription);
        }

        Json Schema(Json _Properties, Json _Required = Json::Array())
        {
            Json schema = Json::Object();
            schema.Set("type", "object");
            schema.Set("properties", std::move(_Properties));
            if (_Required.Size() > 0)
            {
                schema.Set("required", std::move(_Required));
            }
            schema.Set("additionalProperties", false);
            return schema;
        }

        Json Tool(const char* _szName, const char* _szDescription, Json _Schema)
        {
            return Json::Object()
                .Set("name", _szName)
                .Set("description", _szDescription)
                .Set("inputSchema", std::move(_Schema))
                .Set("annotations", Json::Object().Set("readOnlyHint", true));
        }

        Json Definitions()
        {
            Json tools = Json::Array();

            tools.Push(Tool("status",
                "The repository open in the app: its folder, backend (git or p4), current "
                "branch or stream, ahead/behind its upstream, any merge or rebase in "
                "progress, and every changed file (short status codes: first column "
                "staged, second unstaged, ?? untracked; on Perforce staged means opened).",
                Schema(Json::Object())));

            Json diff = Json::Object();
            diff.Set("scope",
                Property("string", "Uncommitted changes to show: all (default, HEAD to the "
                                   "working tree), staged, or unstaged.")
                    .Set("enum", Json::Array().Push("all").Push("staged").Push("unstaged")));
            diff.Set(
                "path", Property("string", "Only this file (relative to the repository root)."));
            diff.Set("commit", Property("string", "Show what this commit (or changelist) changed "
                                                  "instead of uncommitted changes."));
            diff.Set(
                "context", Property("integer", "Context lines around each change (default 3)."));
            tools.Push(Tool("diff",
                "A unified diff of uncommitted changes, or of one commit against its first "
                "parent, from the repository open in the app.",
                Schema(std::move(diff))));

            Json log = Json::Object();
            log.Set("max", Property("integer", "How many commits (default 30, at most 500)."));
            log.Set("ref",
                Property("string", "Start from this branch, tag, or commit instead of HEAD."));
            log.Set("path", Property("string", "Only commits that changed this file."));
            tools.Push(Tool("log",
                "Commit history, newest first: short id, date (UTC), author, summary. On "
                "Perforce the ids are changelist numbers.",
                Schema(std::move(log))));

            Json show = Json::Object();
            show.Set("commit", Property("string", "A commit id, branch, or tag (Perforce: a "
                                                  "changelist number)."));
            show.Set(
                "patch", Property("boolean", "Include the full diff (default false: files only)."));
            tools.Push(Tool("show",
                "One commit: id, author, date, parents, full message, and the files it "
                "changed.",
                Schema(std::move(show), Json::Array().Push("commit"))));

            Json branches = Json::Object();
            branches.Set(
                "remotes", Property("boolean", "Include remote-tracking branches (default true)."));
            tools.Push(Tool("branches",
                "Branches (Perforce: streams), the current one marked with *, each with its "
                "upstream and how far ahead or behind it is.",
                Schema(std::move(branches))));

            tools.Push(Tool("p4_changes",
                "Perforce only: the default changelist and this workspace's numbered pending "
                "changelists, each with its description, opened files (action, depot path, "
                "revision, unresolved or locked) and shelved files.",
                Schema(Json::Object())));

            return tools;
        }

    } // namespace

    const Json& ToolDefinitions()
    {
        static const Json tools = Definitions();
        return tools;
    }

    bool IsTool(const std::string& _Name)
    {
        for (const Json& tool : ToolDefinitions().Items())
        {
            if (tool["name"].AsString() == _Name)
            {
                return true;
            }
        }
        return false;
    }

} // namespace gitgud::agent
