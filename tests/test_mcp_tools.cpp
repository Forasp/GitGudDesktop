// Tests for the Git and P4 tools for Claude Code (and the tools a UI
// declares: the declaration, and the round trip to the "UI"; the Bragi UI's
// settings tools check their own calls, tests/ui/bragi-settingstool.lua):
// the MCP protocol with lines in and out, the tools on a scratch repository,
// the named pipe, and gitgud-mcp end to end against the app's tool server
// (GITGUD_TEST_MCP is its path, Windows only).

#include <catch2/catch_test_macros.hpp>

#include "agent/McpProtocol.h"
#include "agent/RepoTools.h"
#include "agent/ToolPipe.h"
#include "agent/ToolServer.h"
#include "git/Repository.h"
#include "platform/ChildProcess.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace fs = std::filesystem;
using gitgud::agent::McpProtocol;
using gitgud::agent::RunTool;
using gitgud::agent::ToolResult;
using gitgud::agent::ToolServer;
using gitgud::app::Json;

namespace
{

    bool Contains(const std::string& _Text, const std::string& _Part)
    {
        return _Text.find(_Part) != std::string::npos;
    }

    Json ParseLine(const std::string& _Line)
    {
        return Json::Parse(_Line).value_or(Json());
    }

    // A scratch repository in the temp folder, removed afterwards.
    struct ScratchRepo
    {
        gitgud::git::LibGit2 m_Lib;
        fs::path m_Dir;

        ScratchRepo()
        {
            static std::atomic<unsigned> s_uCounter{0};
            m_Dir =
                fs::temp_directory_path() / ("gitgud_mcp_" + std::to_string(s_uCounter++) + "_" +
                                                std::to_string(reinterpret_cast<uintptr_t>(this)));
            fs::create_directories(m_Dir);
            gitgud::git::Repository repo = gitgud::git::Repository::Init(Path());
            Write("readme.txt", "one\ntwo\n");
            repo.Stage("readme.txt");
            repo.Commit("First commit", "Test User", "test@example.com");
            Write("readme.txt", "one\ntwo\nthree\n");
            repo.Stage("readme.txt");
            repo.Commit("Add a third line\n\nWith a body.", "Test User", "test@example.com");
            // Uncommitted: one staged, one changed, one new.
            Write("staged.txt", "staged\n");
            repo.Stage("staged.txt");
            Write("readme.txt", "one\nTWO\nthree\n");
            Write("new.txt", "new\n");
        }

        ~ScratchRepo()
        {
            std::error_code ec;
            fs::remove_all(m_Dir, ec);
        }

        std::string Path() const
        {
            return m_Dir.u8string();
        }

        void Write(const std::string& _Name, const std::string& _Text)
        {
            std::ofstream(m_Dir / _Name, std::ios::binary) << _Text;
        }
    };

    std::string UniquePipe(const char* _szWhat)
    {
        static std::atomic<unsigned> s_uCounter{0};
        return ToolServer::DefaultPipeName() + "-test-" + _szWhat + "-" +
               std::to_string(s_uCounter++);
    }

} // namespace

TEST_CASE("MCP: initialize, ping, and notifications", "[mcp]")
{
    McpProtocol protocol(gitgud::agent::ToolDefinitions(), nullptr, "gitgud-mcp", "1.2.3");

    const Json init = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}})"));
    CHECK(init["jsonrpc"].AsString() == "2.0");
    CHECK(init["id"].AsInt() == 1);
    CHECK(init["result"]["protocolVersion"].AsString() == "2025-03-26");
    CHECK(init["result"]["capabilities"]["tools"].IsObject());
    CHECK(init["result"]["serverInfo"]["name"].AsString() == "gitgud-mcp");
    CHECK(init["result"]["serverInfo"]["version"].AsString() == "1.2.3");

    // A version we don't know: ours.
    const Json future = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}})"));
    CHECK(future["result"]["protocolVersion"].AsString() == McpProtocol::kProtocolVersion);

    CHECK(protocol.HandleLine(R"({"jsonrpc":"2.0","method":"notifications/initialized"})").empty());
    CHECK(protocol.HandleLine("").empty());
    CHECK(protocol.HandleLine("  \r").empty());
    // A response to a request we never sent: ignored.
    CHECK(protocol.HandleLine(R"({"jsonrpc":"2.0","id":9,"result":{}})").empty());

    const Json ping =
        ParseLine(protocol.HandleLine(R"({"jsonrpc":"2.0","id":"p1","method":"ping"})"));
    CHECK(ping["id"].AsString() == "p1");
    CHECK(ping["result"].IsObject());
    CHECK(ping["result"].Size() == 0);
}

TEST_CASE("MCP: errors for bad input", "[mcp]")
{
    McpProtocol protocol(gitgud::agent::ToolDefinitions(), nullptr, "gitgud-mcp", "1");

    const Json parse = ParseLine(protocol.HandleLine("{not json"));
    CHECK(parse["error"]["code"].AsInt() == -32700);
    CHECK(parse.Has("id"));
    CHECK(parse["id"].IsNull());

    CHECK(ParseLine(protocol.HandleLine("[1,2]"))["error"]["code"].AsInt() == -32600);
    CHECK(ParseLine(protocol.HandleLine(R"({"jsonrpc":"2.0","id":3})"))["error"]["code"].AsInt() ==
          -32600);
    CHECK(ParseLine(
              protocol.HandleLine(R"({"jsonrpc":"2.0","id":{},"method":"ping"})"))["error"]["code"]
              .AsInt() == -32600);

    const Json unknown =
        ParseLine(protocol.HandleLine(R"({"jsonrpc":"2.0","id":4,"method":"resources/list"})"));
    CHECK(unknown["id"].AsInt() == 4);
    CHECK(unknown["error"]["code"].AsInt() == -32601);

    const Json tool = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}})"));
    CHECK(tool["error"]["code"].AsInt() == -32602);

    const Json args = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"status","arguments":[1]}})"));
    CHECK(args["error"]["code"].AsInt() == -32602);
}

TEST_CASE("MCP: tools/list and tools/call", "[mcp]")
{
    std::vector<std::pair<std::string, Json>> calls;
    McpProtocol protocol(
        gitgud::agent::ToolDefinitions(),
        [&calls](const std::string& _Name, const Json& _Arguments)
        {
            calls.push_back({_Name, _Arguments});
            return _Name == "log" ? ToolResult{"boom", true} : ToolResult{"ok: " + _Name, false};
        },
        "gitgud-mcp", "1");

    const Json list =
        ParseLine(protocol.HandleLine(R"({"jsonrpc":"2.0","id":1,"method":"tools/list"})"));
    const Json& tools = list["result"]["tools"];
    REQUIRE(tools.Size() == 6);
    std::vector<std::string> names;
    for (const Json& tool : tools.Items())
    {
        names.push_back(tool["name"].AsString());
        CHECK(!tool["description"].AsString().empty());
        CHECK(tool["inputSchema"]["type"].AsString() == "object");
        CHECK(tool["annotations"]["readOnlyHint"].AsBool());
    }
    CHECK(names ==
          std::vector<std::string>{"status", "diff", "log", "show", "branches", "p4_changes"});

    const Json call = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diff","arguments":{"scope":"staged"}}})"));
    CHECK(call["result"]["isError"].AsBool(true) == false);
    CHECK(call["result"]["content"][0]["type"].AsString() == "text");
    CHECK(call["result"]["content"][0]["text"].AsString() == "ok: diff");
    REQUIRE(calls.size() == 1);
    CHECK(calls[0].second["scope"].AsString() == "staged");

    // No arguments at all: an empty object.
    const Json bare = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status"}})"));
    CHECK(bare["result"]["content"][0]["text"].AsString() == "ok: status");
    CHECK(calls.back().second.IsObject());

    const Json failed = ParseLine(protocol.HandleLine(
        R"({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"log","arguments":{}}})"));
    CHECK(failed["result"]["isError"].AsBool());
    CHECK(failed["result"]["content"][0]["text"].AsString() == "boom");

    // Run: a whole conversation over streams; one reply line per request.
    std::istringstream in(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\r\n"
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");
    std::ostringstream out;
    protocol.Run(in, out);
    std::istringstream replies(out.str());
    std::string line;
    std::vector<Json> lines;
    while (std::getline(replies, line))
    {
        lines.push_back(ParseLine(line));
    }
    REQUIRE(lines.size() == 2);
    CHECK(lines[0]["id"].AsInt() == 1);
    CHECK(lines[1]["id"].AsInt() == 2);
}

TEST_CASE("Repo tools on a scratch repository", "[mcp]")
{
    ScratchRepo scratch;
    const std::string path = scratch.Path();
    const Json none = Json::Object();

    const ToolResult status = RunTool(path, "status", none);
    INFO(status.m_Text);
    CHECK_FALSE(status.m_bIsError);
    CHECK(Contains(status.m_Text, "(git)"));
    CHECK(Contains(status.m_Text, "Branch: "));
    CHECK(Contains(status.m_Text, "A  staged.txt"));
    CHECK(Contains(status.m_Text, " M readme.txt"));
    CHECK(Contains(status.m_Text, "?? new.txt"));

    const ToolResult all = RunTool(path, "diff", none);
    INFO(all.m_Text);
    CHECK_FALSE(all.m_bIsError);
    CHECK(Contains(all.m_Text, "diff --git a/readme.txt b/readme.txt"));
    CHECK(Contains(all.m_Text, "-two\n+TWO\n"));
    CHECK(Contains(all.m_Text, "+staged\n"));

    const ToolResult staged = RunTool(path, "diff", Json::Object().Set("scope", "staged"));
    CHECK(Contains(staged.m_Text, "+staged"));
    CHECK_FALSE(Contains(staged.m_Text, "TWO"));

    const ToolResult one = RunTool(path, "diff", Json::Object().Set("path", "readme.txt"));
    CHECK(Contains(one.m_Text, "+TWO"));
    CHECK_FALSE(Contains(one.m_Text, "staged"));

    const ToolResult log = RunTool(path, "log", none);
    INFO(log.m_Text);
    CHECK_FALSE(log.m_bIsError);
    CHECK(Contains(log.m_Text, "Test User: Add a third line"));
    CHECK(log.m_Text.find("Add a third line") < log.m_Text.find("First commit"));
    const ToolResult last = RunTool(path, "log", Json::Object().Set("max", 1));
    CHECK_FALSE(Contains(last.m_Text, "First commit"));

    const ToolResult show =
        RunTool(path, "show", Json::Object().Set("commit", "HEAD").Set("patch", true));
    INFO(show.m_Text);
    CHECK_FALSE(show.m_bIsError);
    CHECK(Contains(show.m_Text, "With a body."));
    CHECK(Contains(show.m_Text, "M readme.txt"));
    CHECK(Contains(show.m_Text, "+three"));

    const Json headId = Json::Object().Set("commit", "HEAD");
    CHECK(Contains(RunTool(path, "diff", headId).m_Text, "+three"));

    const ToolResult branches = RunTool(path, "branches", none);
    INFO(branches.m_Text);
    CHECK_FALSE(branches.m_bIsError);
    CHECK(Contains(branches.m_Text, "* "));
}

TEST_CASE("Repo tools report errors as results", "[mcp]")
{
    ScratchRepo scratch;
    const std::string path = scratch.Path();

    const ToolResult p4 = RunTool(path, "p4_changes", Json::Object());
    CHECK(p4.m_bIsError);
    CHECK(Contains(p4.m_Text, "Perforce"));

    CHECK(RunTool("", "status", Json::Object()).m_bIsError);
    CHECK(Contains(RunTool("", "status", Json::Object()).m_Text, "No repository is open"));
    CHECK(RunTool(path, "nope", Json::Object()).m_bIsError);
    CHECK(RunTool(path, "log", Json::Object().Set("max", "ten")).m_bIsError);
    CHECK(RunTool(path, "log", Json::Object().Set("max", 0)).m_bIsError);
    CHECK(RunTool(path, "diff", Json::Object().Set("scope", "sideways")).m_bIsError);
    CHECK(RunTool(path, "show", Json::Object()).m_bIsError);
    CHECK(RunTool(path, "show", Json::Object().Set("commit", "no-such-ref")).m_bIsError);
    CHECK(RunTool((scratch.m_Dir / "missing").u8string(), "status", Json::Object()).m_bIsError);
}

TEST_CASE("ToolServer: MCP config", "[mcp]")
{
    const Json config = ParseLine(ToolServer::McpConfig("C:/app/gitgud-mcp.exe", "\\\\.\\pipe\\x"));
    const Json& server = config["mcpServers"]["repo"];
    CHECK(server["type"].AsString() == "stdio");
    CHECK(server["command"].AsString() == "C:/app/gitgud-mcp.exe");
    CHECK(server["args"][0].AsString() == "--pipe");
    CHECK(server["args"][1].AsString() == "\\\\.\\pipe\\x");
    CHECK(server["args"].Size() == 2);
    CHECK(Contains(ToolServer::DefaultPipeName(), "\\\\.\\pipe\\"));

    // The main session's: the UI's tools too.
    const Json main =
        ParseLine(ToolServer::McpConfig("C:/app/gitgud-mcp.exe", "\\\\.\\pipe\\x", true));
    CHECK(main["mcpServers"]["repo"]["args"].Size() == 3);
    CHECK(main["mcpServers"]["repo"]["args"][2].AsString() == "--ui-tools");

    // One session's: it says which.
    const Json named = ParseLine(
        ToolServer::McpConfig("C:/app/gitgud-mcp.exe", "\\\\.\\pipe\\x", false, "bragi-master"));
    CHECK(named["mcpServers"]["repo"]["args"].Size() == 4);
    CHECK(named["mcpServers"]["repo"]["args"][3].AsString() == "bragi-master");
}

namespace
{

    // A tool as a UI declares it.
    Json UiTool(const std::string& _Name)
    {
        return Json::Object()
            .Set("name", _Name)
            .Set("description", "A tool the UI answers.")
            .Set("inputSchema", Json::Object()
                                    .Set("type", "object")
                                    .Set("properties", Json::Object())
                                    .Set("additionalProperties", false))
            .Set("annotations", Json::Object().Set("readOnlyHint", true));
    }

    // The Bragi UI's settings tools (bragi/settingstool.lua), as far as the
    // engine looks at them.
    Json SettingsTools()
    {
        return Json::Array().Push(UiTool("bragi_settings_get")).Push(UiTool("bragi_settings_set"));
    }

} // namespace

TEST_CASE("ToolServer: the UI declares its tools", "[mcp][uitools]")
{
    ToolServer tools;
    std::string error;
    CHECK(tools.UiTools().Size() == 0);
    REQUIRE(tools.SetUiTools(SettingsTools(), error));
    const Json declared = tools.UiTools();
    REQUIRE(declared.Size() == 2);
    CHECK(declared[0]["name"].AsString() == "bragi_settings_get");
    CHECK(declared[0]["annotations"]["readOnlyHint"].AsBool());
    CHECK(declared[1]["inputSchema"]["type"].AsString() == "object");

    // Only what tools/list needs is kept.
    Json extra = UiTool("extra");
    extra.Set("handler", "anything");
    REQUIRE(tools.SetUiTools(Json::Array().Push(extra), error));
    CHECK_FALSE(tools.UiTools()[0].Has("handler"));

    // Refused, and nothing changes: not a list, a Git tool's name, the same
    // name twice, a bad name, no object schema, too many.
    CHECK_FALSE(tools.SetUiTools(Json::Object(), error));
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(UiTool("status")), error));
    CHECK(Contains(error, "already"));
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(UiTool("a")).Push(UiTool("a")), error));
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(UiTool("two words")), error));
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(UiTool("")), error));
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(UiTool(std::string(60, 'x'))), error));
    Json noSchema = UiTool("noschema");
    noSchema.Set("inputSchema", Json::Object().Set("type", "string"));
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(noSchema), error));
    Json many = Json::Array();
    for (std::size_t i = 0; i <= ToolServer::kMaxUiTools; ++i)
    {
        many.Push(UiTool("t" + std::to_string(i)));
    }
    CHECK_FALSE(tools.SetUiTools(many, error));
    REQUIRE(tools.UiTools().Size() == 1);
    CHECK(tools.UiTools()[0]["name"].AsString() == "extra");

    // An empty list: none.
    REQUIRE(tools.SetUiTools(Json::Array(), error));
    CHECK(tools.UiTools().Size() == 0);
}

TEST_CASE("MCP: a tool list that changes", "[mcp][uitools]")
{
    Json list = Json::Array().Push(UiTool("first"));
    McpProtocol protocol([&list] { return list; },
        [](const std::string& _Name, const Json&) { return ToolResult{"ran " + _Name, false}; },
        "test", "1");
    const std::string listLine = R"({"jsonrpc":"2.0","id":1,"method":"tools/list"})";
    const std::string callLine =
        R"({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"second","arguments":{}}})";
    CHECK(ParseLine(protocol.HandleLine(listLine))["result"]["tools"].Size() == 1);
    CHECK(ParseLine(protocol.HandleLine(callLine))["error"]["code"].AsInt() == -32602);
    list.Push(UiTool("second"));
    CHECK(ParseLine(protocol.HandleLine(listLine))["result"]["tools"].Size() == 2);
    CHECK(ParseLine(protocol.HandleLine(callLine))["result"]["content"][0]["text"].AsString() ==
          "ran second");
}

#if defined(_WIN32)

TEST_CASE("Tool pipe: one request, one reply", "[mcp]")
{
    const std::string name = UniquePipe("echo");
    gitgud::agent::ToolPipeServer server;
    std::string error;
    REQUIRE(
        server.Start(name, [](const std::string& _Request) { return "echo " + _Request; }, error));

    // A second server can't take the same name.
    gitgud::agent::ToolPipeServer squatter;
    CHECK_FALSE(squatter.Start(name, [](const std::string&) { return std::string(); }, error));

    for (int i = 0; i < 3; ++i)
    {
        std::string reply;
        REQUIRE(
            gitgud::agent::CallToolPipe(name, "hello " + std::to_string(i), 5000, reply, error));
        CHECK(reply == "echo hello " + std::to_string(i));
    }

    // A big reply arrives whole.
    std::string big(300000, 'x');
    std::string reply;
    REQUIRE(gitgud::agent::CallToolPipe(name, big, 5000, reply, error));
    CHECK(reply.size() == big.size() + 5);

    // A client that connects and says nothing doesn't hold up Stop().
    const std::wstring wide(name.begin(), name.end());
    HANDLE hidle = CreateFileW(
        wide.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    CHECK(hidle != INVALID_HANDLE_VALUE);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const auto start = std::chrono::steady_clock::now();
    server.Stop();
    CHECK(std::chrono::steady_clock::now() - start < std::chrono::seconds(5));
    CHECK_FALSE(server.Running());
    if (hidle != INVALID_HANDLE_VALUE)
    {
        CloseHandle(hidle);
    }

    CHECK_FALSE(gitgud::agent::CallToolPipe(name, "anyone?", 1000, reply, error));
    CHECK(Contains(error, "Nothing is listening"));
}

TEST_CASE("ToolServer answers over the pipe with the open repository", "[mcp]")
{
    ScratchRepo scratch;
    const std::string name = UniquePipe("server");
    const fs::path config = scratch.m_Dir / "cfg" / "tools.json";
    ToolServer tools;
    std::string error;
    // No program: no config written.
    REQUIRE(
        tools.Start(name, (scratch.m_Dir / "no-such.exe").u8string(), config.u8string(), error));
    CHECK(tools.McpConfigPath().empty());

    std::string reply;
    const std::string status = R"({"tool":"status","arguments":{}})";
    REQUIRE(gitgud::agent::CallToolPipe(name, status, 10000, reply, error));
    Json answer = ParseLine(reply);
    CHECK(answer["isError"].AsBool());
    CHECK(Contains(answer["text"].AsString(), "No repository is open"));

    tools.SetRepository(scratch.Path());
    REQUIRE(gitgud::agent::CallToolPipe(name, status, 10000, reply, error));
    answer = ParseLine(reply);
    CHECK_FALSE(answer["isError"].AsBool(true));
    CHECK(Contains(answer["text"].AsString(), "?? new.txt"));

    REQUIRE(gitgud::agent::CallToolPipe(name, "garbage", 10000, reply, error));
    CHECK(ParseLine(reply)["isError"].AsBool());
    tools.Stop();
}

TEST_CASE("ToolServer: UI tool calls go to the app and back", "[mcp][uitools]")
{
    const std::string name = UniquePipe("settings");
    ToolServer tools;
    std::string error;
    REQUIRE(tools.Start(name, "", "", error));
    std::string reply;
    const std::string faster =
        R"({"tool":"bragi_settings_set","arguments":{"setting":"speechSpeed","value":1.383}})";

    // Not declared yet: not the UI's, so it's an unknown tool.
    REQUIRE(gitgud::agent::CallToolPipe(name, faster, 10000, reply, error));
    CHECK(ParseLine(reply)["isError"].AsBool());
    REQUIRE(tools.SetUiTools(SettingsTools(), error));

    // The list gitgud-mcp asks for.
    REQUIRE(gitgud::agent::CallToolPipe(name, R"({"list":"ui"})", 10000, reply, error));
    CHECK(ParseLine(reply)["tools"].Size() == 2);
    CHECK(ParseLine(reply)["tools"][1]["name"].AsString() == "bragi_settings_set");

    // No interface listens: refused, nothing waits.
    REQUIRE(gitgud::agent::CallToolPipe(name, faster, 10000, reply, error));
    CHECK(ParseLine(reply)["isError"].AsBool());
    CHECK(Contains(ParseLine(reply)["text"].AsString(), "no interface"));

    // The "UI": answers each call from another thread, as the UI thread would.
    std::mutex mutex;
    std::vector<Json> calls;
    std::vector<std::thread> answering;
    std::atomic<int> iwrongReplies{0};
    tools.SetAppHandler(
        [&](const std::string& _Id, const std::string& _Tool, const Json& _Arguments,
            const std::string&)
        {
            std::lock_guard<std::mutex> lock(mutex);
            calls.push_back(Json::Object().Set("tool", _Tool).Set("arguments", _Arguments));
            answering.emplace_back(
                [&tools, &iwrongReplies, _Id]
                {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    iwrongReplies += tools.Reply(_Id, {"Speaking speed 1.15x -> 1.38x", false}) ? 0 : 1;
                    // Only once.
                    iwrongReplies += tools.Reply(_Id, {"again", true}) ? 1 : 0;
                });
        });

    REQUIRE(gitgud::agent::CallToolPipe(name, faster, 10000, reply, error));
    Json answer = ParseLine(reply);
    CHECK_FALSE(answer["isError"].AsBool(true));
    CHECK(answer["text"].AsString() == "Speaking speed 1.15x -> 1.38x");
    {
        std::lock_guard<std::mutex> lock(mutex);
        REQUIRE(calls.size() == 1);
        CHECK(calls[0]["tool"].AsString() == "bragi_settings_set");
        // As the agent sent them: the script checks them.
        CHECK(calls[0]["arguments"]["setting"].AsString() == "speechSpeed");
        CHECK(calls[0]["arguments"]["value"].AsNumber() == 1.383);
    }

    // Arguments that aren't an object, and tools the UI didn't declare,
    // never reach the app.
    REQUIRE(gitgud::agent::CallToolPipe(
        name, R"({"tool":"bragi_settings_set","arguments":[1]})", 10000, reply, error));
    answer = ParseLine(reply);
    CHECK(answer["isError"].AsBool());
    CHECK(Contains(answer["text"].AsString(), "must be an object"));
    REQUIRE(gitgud::agent::CallToolPipe(name,
        R"({"tool":"bragi_settings_delete","arguments":{"setting":"theme"}})", 10000, reply, error));
    CHECK(ParseLine(reply)["isError"].AsBool());
    {
        std::lock_guard<std::mutex> lock(mutex);
        CHECK(calls.size() == 1);
    }

    // get goes through too.
    REQUIRE(gitgud::agent::CallToolPipe(
        name, R"({"tool":"bragi_settings_get","arguments":{}})", 10000, reply, error));
    CHECK_FALSE(ParseLine(reply)["isError"].AsBool(true));
    {
        std::lock_guard<std::mutex> lock(mutex);
        REQUIRE(calls.size() == 2);
        CHECK(calls[1]["tool"].AsString() == "bragi_settings_get");
    }
    CHECK_FALSE(tools.Reply("call-999", {"late", false}));

    // An app that never answers: Stop() doesn't wait the whole timeout.
    tools.SetAppHandler([](const std::string&, const std::string&, const Json&, const std::string&) {});
    std::atomic<bool> bdone{false};
    std::string silentReply;
    std::thread caller(
        [&]
        {
            std::string callError;
            gitgud::agent::CallToolPipe(name, faster, 20000, silentReply, callError);
            bdone = true;
        });
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    CHECK_FALSE(bdone);
    const auto start = std::chrono::steady_clock::now();
    tools.Stop();
    caller.join();
    CHECK(std::chrono::steady_clock::now() - start < std::chrono::seconds(5));
    if (!silentReply.empty())
    {
        CHECK(ParseLine(silentReply)["isError"].AsBool());
    }
    for (std::thread& thread : answering)
    {
        thread.join();
    }
    CHECK(iwrongReplies == 0);
}

TEST_CASE("ToolServer: tools per session", "[mcp][uitools]")
{
    ScratchRepo first;
    ScratchRepo second;
    const std::string name = UniquePipe("sessions");
    ToolServer tools;
    std::string error;
    REQUIRE(tools.Start(name, "", "", error));
    tools.SetRepository(first.Path());
    tools.SetSessionRepository("other", second.Path());
    CHECK(tools.RepositoryFor("other") == second.Path());
    CHECK(tools.RepositoryFor("anyone") == first.Path());

    // A tool kept to one session; another for everyone.
    Json only = UiTool("only_master");
    only.Set("sessions", Json::Array().Push("master"));
    REQUIRE(tools.SetUiTools(Json::Array().Push(only).Push(UiTool("everyone")), error));
    CHECK_FALSE(tools.UiTools()[0].Has("sessions"));
    CHECK(tools.UiToolsFor("master").Size() == 2);
    CHECK(tools.UiToolsFor("other").Size() == 1);
    CHECK(tools.UiToolsFor("").Size() == 1);
    Json bad = UiTool("bad");
    bad.Set("sessions", "master");
    CHECK_FALSE(tools.SetUiTools(Json::Array().Push(bad), error));

    std::mutex mutex;
    std::vector<std::string> sessions;
    tools.SetAppHandler(
        [&](const std::string& _Id, const std::string&, const Json&, const std::string& _Session)
        {
            {
                std::lock_guard<std::mutex> lock(mutex);
                sessions.push_back(_Session);
            }
            const std::string id = _Id;
            std::thread([&tools, id] { tools.Reply(id, {"ok", false}); }).detach();
        });
    std::string reply;
    REQUIRE(gitgud::agent::CallToolPipe(
        name, R"({"list":"ui","session":"other"})", 10000, reply, error));
    CHECK(ParseLine(reply)["tools"].Size() == 1);
    REQUIRE(gitgud::agent::CallToolPipe(
        name, R"({"list":"ui","session":"master"})", 10000, reply, error));
    CHECK(ParseLine(reply)["tools"].Size() == 2);

    // Another session can't call it, and the app never hears of it.
    REQUIRE(gitgud::agent::CallToolPipe(name,
        R"({"tool":"only_master","arguments":{},"session":"other"})", 10000, reply, error));
    CHECK(ParseLine(reply)["isError"].AsBool());
    CHECK(Contains(ParseLine(reply)["text"].AsString(), "isn't available in this session"));
    REQUIRE(gitgud::agent::CallToolPipe(name,
        R"({"tool":"only_master","arguments":{},"session":"master"})", 10000, reply, error));
    CHECK_FALSE(ParseLine(reply)["isError"].AsBool(true));
    {
        std::lock_guard<std::mutex> lock(mutex);
        REQUIRE(sessions.size() == 1);
        CHECK(sessions[0] == "master");
    }

    // The Git tools act on the calling session's repository.
    second.Write("only-in-second.txt", "x\n");
    REQUIRE(gitgud::agent::CallToolPipe(
        name, R"({"tool":"status","arguments":{},"session":"other"})", 10000, reply, error));
    CHECK(Contains(ParseLine(reply)["text"].AsString(), "only-in-second.txt"));
    REQUIRE(gitgud::agent::CallToolPipe(
        name, R"({"tool":"status","arguments":{},"session":"master"})", 10000, reply, error));
    CHECK_FALSE(Contains(ParseLine(reply)["text"].AsString(), "only-in-second.txt"));
    REQUIRE(gitgud::agent::CallToolPipe(name, R"({"tool":"status","arguments":{}})", 10000, reply, error));
    CHECK_FALSE(Contains(ParseLine(reply)["text"].AsString(), "only-in-second.txt"));
    tools.SetSessionRepository("other", "");
    CHECK(tools.RepositoryFor("other") == first.Path());
    tools.Stop();
}

#if defined(GITGUD_TEST_MCP)

namespace
{

    // gitgud-mcp as Claude Code runs it: lines in, reply lines out.
    struct McpChild
    {
        gitgud::platform::ChildProcess m_Process;
        std::mutex m_Mutex;
        std::condition_variable m_Changed;
        std::vector<std::string> m_Lines;

        bool Start(const std::string& _Pipe, bool _bUiTools = false)
        {
            gitgud::platform::ChildProcess::Options options;
            options.m_Args = {GITGUD_TEST_MCP, "--pipe", _Pipe};
            if (_bUiTools)
            {
                options.m_Args.push_back("--ui-tools");
            }
            std::string error;
            return m_Process.Start(
                options,
                [this](const std::string& _Line)
                {
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_Lines.push_back(_Line);
                    m_Changed.notify_all();
                },
                nullptr, nullptr, error);
        }

        // Send a request and wait for its reply (the replies come in order).
        Json Ask(const std::string& _Line)
        {
            std::unique_lock<std::mutex> lock(m_Mutex);
            const std::size_t nbefore = m_Lines.size();
            lock.unlock();
            m_Process.WriteLine(_Line);
            lock.lock();
            m_Changed.wait_for(
                lock, std::chrono::seconds(20), [&] { return m_Lines.size() > nbefore; });
            return m_Lines.size() > nbefore ? ParseLine(m_Lines[nbefore]) : Json();
        }
    };

} // namespace

TEST_CASE("gitgud-mcp end to end", "[mcp]")
{
    ScratchRepo scratch;
    const std::string name = UniquePipe("e2e");
    ToolServer tools;
    std::string error;
    const fs::path config = scratch.m_Dir / "cfg" / "tools.json";
    REQUIRE(tools.Start(name, GITGUD_TEST_MCP, config.u8string(), error));
    tools.SetRepository(scratch.Path());
    REQUIRE(tools.SetUiTools(SettingsTools(), error));

    // The config Claude Code gets runs this program on this pipe.
    REQUIRE(tools.McpConfigPath() == config.u8string());
    std::ifstream in(config, std::ios::binary);
    const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    in.close();
    const Json written = ParseLine(text);
    CHECK(written["mcpServers"]["repo"]["args"][1].AsString() == name);

    McpChild child;
    REQUIRE(child.Start(name));
    const Json init = child.Ask(
        R"({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}})");
    CHECK(init["result"]["serverInfo"]["name"].AsString() == "gitgud-mcp");
    child.m_Process.WriteLine(R"({"jsonrpc":"2.0","method":"notifications/initialized"})");
    CHECK(
        child.Ask(R"({"jsonrpc":"2.0","id":2,"method":"tools/list"})")["result"]["tools"].Size() ==
        6);

    const Json status = child.Ask(
        R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}})");
    INFO(status.Dump());
    CHECK_FALSE(status["result"]["isError"].AsBool(true));
    CHECK(Contains(status["result"]["content"][0]["text"].AsString(), "A  staged.txt"));

    const Json diff = child.Ask(
        R"({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"diff","arguments":{"path":"readme.txt"}}})");
    CHECK(Contains(diff["result"]["content"][0]["text"].AsString(), "+TWO"));

    // Without --ui-tools (the helpers' server) the UI's tools don't exist.
    const Json hidden = child.Ask(
        R"({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"bragi_settings_set","arguments":{"setting":"theme","value":"dark"}}})");
    CHECK(hidden["error"]["code"].AsInt() == -32602);

    // A session's own config names it; Stop() deletes it.
    const std::string sessionConfig = tools.McpConfigPath(true, "bragi 1");
    CHECK(Contains(sessionConfig, "tools-ui-s-bragi_1.json"));
    std::ifstream sessionIn(fs::u8path(sessionConfig), std::ios::binary);
    const Json sessionArgs = ParseLine(std::string(
        (std::istreambuf_iterator<char>(sessionIn)), std::istreambuf_iterator<char>()))["mcpServers"]["repo"]["args"];
    sessionIn.close();
    CHECK(sessionArgs.Size() == 5);
    CHECK(sessionArgs[3].AsString() == "--session");
    CHECK(sessionArgs[4].AsString() == "bragi 1");

    // The main session's config runs it with --ui-tools: they're listed and
    // reach the app.
    const std::string settingsConfig = tools.McpConfigPath(true);
    CHECK(Contains(settingsConfig, "tools-ui.json"));
    std::ifstream settingsIn(fs::u8path(settingsConfig), std::ios::binary);
    const std::string settingsText(
        (std::istreambuf_iterator<char>(settingsIn)), std::istreambuf_iterator<char>());
    settingsIn.close();
    CHECK(ParseLine(settingsText)["mcpServers"]["repo"]["args"][2].AsString() == "--ui-tools");
    tools.SetAppHandler(
        [&tools](const std::string& _Id, const std::string& _Tool, const Json& _Arguments,
            const std::string&)
        {
            const std::string id = _Id;
            const std::string text = _Tool + " " + _Arguments.Dump();
            std::thread([&tools, id, text] { tools.Reply(id, {text, false}); }).detach();
        });
    McpChild main;
    REQUIRE(main.Start(name, true));
    main.Ask(R"({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})");
    CHECK(main.Ask(R"({"jsonrpc":"2.0","id":2,"method":"tools/list"})")["result"]["tools"].Size() ==
          8);
    const Json theme = main.Ask(
        R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"bragi_settings_set","arguments":{"setting":"theme","value":"Dark"}}})");
    INFO(theme.Dump());
    CHECK_FALSE(theme["result"]["isError"].AsBool(true));
    CHECK(theme["result"]["content"][0]["text"].AsString() ==
          R"(bragi_settings_set {"setting":"theme","value":"Dark"})");

    // The UI takes them back (another UI, or a reload): gone at once.
    REQUIRE(tools.SetUiTools(Json::Array(), error));
    CHECK(main.Ask(R"({"jsonrpc":"2.0","id":4,"method":"tools/list"})")["result"]["tools"].Size() ==
          6);
    const Json withdrawn = main.Ask(
        R"({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"bragi_settings_set","arguments":{"setting":"theme","value":"dark"}}})");
    CHECK(withdrawn["error"]["code"].AsInt() == -32602);
    main.m_Process.CloseStdin();
    CHECK(main.m_Process.Wait(5000) == 0);

    // The app goes away: tools say so instead of hanging.
    tools.Stop();
    CHECK_FALSE(fs::exists(config));
    CHECK_FALSE(fs::exists(fs::u8path(sessionConfig)));
    const Json gone = child.Ask(
        R"({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"status","arguments":{}}})");
    CHECK(gone["result"]["isError"].AsBool());
    CHECK(Contains(gone["result"]["content"][0]["text"].AsString(), "isn't reachable"));

    child.m_Process.CloseStdin();
    CHECK(child.m_Process.Wait(5000) == 0);
}

#endif // GITGUD_TEST_MCP

#endif // _WIN32
