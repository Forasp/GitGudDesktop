// Tests for agent/ClaudeSession: stream-json lines in, events out, with a
// writer standing in for the process; then whole sessions against
// tests/fake_claude.cpp (GITGUD_TEST_CLAUDE is its path, Windows only).

#include <catch2/catch_test_macros.hpp>

#include "agent/ClaudeSession.h"

#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

using gitgud::agent::ClaudeSession;
using gitgud::app::Json;

namespace
{

    struct Event
    {
        std::string m_Type;
        Json m_Detail;
    };

    // What a session emits and writes, and a way to wait for it.
    struct Recorder
    {
        std::mutex m_Mutex;
        std::condition_variable m_Changed;
        std::vector<Event> m_Events;
        std::vector<Json> m_Written;

        ClaudeSession::OnEvent Events()
        {
            return [this](const std::string& _Type, const Json& _Detail)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Events.push_back({_Type, _Detail});
                m_Changed.notify_all();
            };
        }

        ClaudeSession::Writer Writer()
        {
            return [this](const std::string& _Line)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Written.push_back(Json::Parse(_Line).value_or(Json(_Line)));
                return true;
            };
        }

        std::vector<Event> Of(const std::string& _Type)
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            std::vector<Event> found;
            for (const Event& event : m_Events)
            {
                if (event.m_Type == _Type)
                {
                    found.push_back(event);
                }
            }
            return found;
        }

        // Wait until `_iCount` events of `_Type` have arrived (10 s at most).
        bool WaitFor(const std::string& _Type, size_t _iCount = 1)
        {
            std::unique_lock<std::mutex> lock(m_Mutex);
            return m_Changed.wait_for(lock, std::chrono::seconds(10),
                [&]
                {
                    size_t icount = 0;
                    for (const Event& event : m_Events)
                    {
                        icount += event.m_Type == _Type ? 1 : 0;
                    }
                    return icount >= _iCount;
                });
        }
    };

} // namespace

TEST_CASE("ClaudeSession: command line", "[agent]")
{
    ClaudeSession::Options options;
    options.m_Model = "opus";
    options.m_PermissionMode = "acceptEdits";
    options.m_Resume = "abc";
    const std::vector<std::string> args = ClaudeSession::Arguments(options);
    const std::vector<std::string> expected{"claude", "-p", "--output-format", "stream-json",
        "--input-format", "stream-json", "--verbose", "--include-partial-messages",
        "--permission-prompt-tool", "stdio", "--model", "opus", "--permission-mode", "acceptEdits",
        "--resume", "abc"};
    CHECK(args == expected);

    options.m_Effort = "high";
    options.m_Settings = R"({"outputStyle":"Explanatory"})";
    const std::vector<std::string> more = ClaudeSession::Arguments(options);
    REQUIRE(more.size() == expected.size() + 4);
    CHECK(more[14] == "--effort");
    CHECK(more[15] == "high");
    CHECK(more[16] == "--settings");
    CHECK(more[17] == R"({"outputStyle":"Explanatory"})");

    // Rewound or forked: only with a session to resume.
    ClaudeSession::Options at;
    at.m_ResumeAt = "u-2";
    at.m_bForkSession = true;
    CHECK(ClaudeSession::Arguments(at).size() == 10);
    at.m_Resume = "abc";
    const std::vector<std::string> fork = ClaudeSession::Arguments(at);
    REQUIRE(fork.size() == 15);
    CHECK(fork[10] == "--resume");
    CHECK(fork[12] == "--resume-session-at");
    CHECK(fork[13] == "u-2");
    CHECK(fork[14] == "--fork-session");

    options.m_bPersist = false;
    const std::vector<std::string> helper = ClaudeSession::Arguments(options);
    REQUIRE(helper.size() == more.size() + 1);
    CHECK(helper.back() == "--no-session-persistence");

    // A lean helper: its own system prompt, no tools, no MCP servers.
    ClaudeSession::Options lean;
    lean.m_Model = "claude-haiku-5-5";
    lean.m_SystemPrompt = "Answer in JSON.";
    lean.m_bPersist = false;
    lean.m_bLean = true;
    const std::vector<std::string> leanArgs = ClaudeSession::Arguments(lean);
    const std::vector<std::string> leanTail{"--model", "claude-haiku-5-5", "--system-prompt",
        "Answer in JSON.", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
        "--disable-slash-commands"};
    REQUIRE(leanArgs.size() == 10 + leanTail.size());
    CHECK(std::vector<std::string>(leanArgs.begin() + 10, leanArgs.end()) == leanTail);

    // A lean helper that may read: only the built-in tools it's given.
    lean.m_Tools = "Read,Grep,Glob";
    const std::vector<std::string> reader = ClaudeSession::Arguments(lean);
    REQUIRE(reader.size() == leanArgs.size());
    CHECK(reader[15] == "--tools");
    CHECK(reader[16] == "Read,Grep,Glob");

    // Not lean: --tools only when some are named.
    ClaudeSession::Options plain;
    plain.m_Tools = "Read";
    const std::vector<std::string> plainArgs = ClaudeSession::Arguments(plain);
    REQUIRE(plainArgs.size() == 12);
    CHECK(plainArgs[10] == "--tools");
    CHECK(plainArgs[11] == "Read");
}

TEST_CASE("ClaudeSession: a turn's events", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());

    REQUIRE(session.Send("hi"));
    CHECK(session.TurnActive());
    REQUIRE(rec.m_Written.size() == 1);
    CHECK(rec.m_Written[0]["type"].AsString() == "user");
    CHECK(rec.m_Written[0]["message"]["content"].AsString() == "hi");

    session.HandleLine(
        R"({"type":"system","subtype":"init","session_id":"s1","model":"opus","permissionMode":"default","cwd":"C:/w","tools":["Bash"],"apiKeySource":"none","claude_code_version":"2.0.0","mcp_servers":[{"name":"gitgud","status":"connected"}],"slash_commands":["review"],"skills":["s"],"plugins":[{"name":"p","path":"x"}]})");
    session.HandleLine(
        R"({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null})");
    session.HandleLine(
        R"({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi "}},"parent_tool_use_id":null})");
    session.HandleLine(
        R"({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}},"parent_tool_use_id":null})");
    // A sub-agent's stream is left out; its whole messages aren't.
    session.HandleLine(
        R"({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sub"}},"parent_tool_use_id":"toolu_a"})");
    session.HandleLine(
        R"({"type":"assistant","message":{"content":[{"type":"text","text":"Hi there"},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"a.txt"}}]},"parent_tool_use_id":null})");
    session.HandleLine(
        R"({"type":"assistant","message":{"content":[{"type":"text","text":"from a sub-agent"}]},"parent_tool_use_id":"toolu_a"})");
    session.HandleLine(
        R"({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"line 1"},{"type":"text","text":"line 2"}],"is_error":false}]},"parent_tool_use_id":null})");
    session.HandleLine(R"({"type":"system","subtype":"compact_boundary"})");
    session.HandleLine("not json");
    session.HandleLine("");
    session.HandleLine(
        R"({"type":"result","subtype":"success","is_error":false,"result":"Hi there","session_id":"s1","total_cost_usd":0.5,"num_turns":2,"duration_ms":900})");

    CHECK_FALSE(session.TurnActive());
    CHECK(session.SessionId() == "s1");

    auto init = rec.Of("init");
    REQUIRE(init.size() == 1);
    CHECK(init[0].m_Detail["model"].AsString() == "opus");
    CHECK(init[0].m_Detail["tools"][0].AsString() == "Bash");
    CHECK(init[0].m_Detail["apiKeySource"].AsString() == "none");
    CHECK(init[0].m_Detail["version"].AsString() == "2.0.0");
    CHECK(init[0].m_Detail["mcpServers"][0]["status"].AsString() == "connected");
    CHECK(init[0].m_Detail["slashCommands"][0].AsString() == "review");
    CHECK(init[0].m_Detail["skills"][0].AsString() == "s");
    CHECK(init[0].m_Detail["plugins"][0]["name"].AsString() == "p");

    auto blocks = rec.Of("block");
    REQUIRE(blocks.size() == 1);
    CHECK(blocks[0].m_Detail["type"].AsString() == "text");

    auto text = rec.Of("text");
    REQUIRE(text.size() == 1);
    CHECK(text[0].m_Detail["text"].AsString() == "Hi ");
    CHECK(rec.Of("thinking").size() == 1);

    auto messages = rec.Of("message");
    REQUIRE(messages.size() == 2);
    CHECK(messages[0].m_Detail["text"].AsString() == "Hi there");
    CHECK(messages[0].m_Detail["parent"].AsString() == "");
    CHECK(messages[1].m_Detail["parent"].AsString() == "toolu_a");

    auto tools = rec.Of("tool");
    REQUIRE(tools.size() == 1);
    CHECK(tools[0].m_Detail["name"].AsString() == "Read");
    CHECK(tools[0].m_Detail["input"]["file_path"].AsString() == "a.txt");

    auto results = rec.Of("toolResult");
    REQUIRE(results.size() == 1);
    CHECK(results[0].m_Detail["id"].AsString() == "toolu_1");
    CHECK(results[0].m_Detail["text"].AsString() == "line 1\nline 2");
    CHECK_FALSE(results[0].m_Detail["isError"].AsBool());

    auto system = rec.Of("system");
    REQUIRE(system.size() == 1);
    CHECK(system[0].m_Detail["subtype"].AsString() == "compact_boundary");

    auto stray = rec.Of("stderr");
    REQUIRE(stray.size() == 1);
    CHECK(stray[0].m_Detail["line"].AsString() == "not json");

    auto result = rec.Of("result");
    REQUIRE(result.size() == 1);
    CHECK(result[0].m_Detail["subtype"].AsString() == "success");
    CHECK(result[0].m_Detail["text"].AsString() == "Hi there");
    CHECK(result[0].m_Detail["costUsd"].AsNumber() == 0.5);
    CHECK(result[0].m_Detail["turns"].AsInt() == 2);
    CHECK_FALSE(result[0].m_Detail["interrupted"].AsBool());
}

TEST_CASE("ClaudeSession: a helper's permission request", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());
    REQUIRE(session.Send("go"));

    // A background helper asks: the request says which, and why.
    session.HandleLine(
        R"({"type":"control_request","request_id":"h1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"git diff > x"},"tool_use_id":"toolu_h","agent_id":"agent_7","decision_reason":"It writes a file"}})");
    // And the agent's own.
    session.HandleLine(
        R"({"type":"control_request","request_id":"m1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}})");
    auto asked = rec.Of("permission");
    REQUIRE(asked.size() == 2);
    CHECK(asked[0].m_Detail["agentId"].AsString() == "agent_7");
    CHECK(asked[0].m_Detail["reason"].AsString() == "It writes a file");
    CHECK(asked[1].m_Detail["agentId"].IsNull());

    // The turn ends: the agent's request with it, the helper's still waits.
    session.HandleLine(R"({"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1"})");
    CHECK(session.PendingPermission() == "h1");
    CHECK_FALSE(session.Respond("m1", true));

    SECTION("answered after the turn")
    {
        REQUIRE(session.Respond("h1", true));
        CHECK(rec.m_Written.back()["response"]["request_id"].AsString() == "h1");
        CHECK(rec.m_Written.back()["response"]["response"]["behavior"].AsString() == "allow");
    }

    SECTION("taken back by Claude Code")
    {
        session.HandleLine(R"({"type":"control_cancel_request","request_id":"h1"})");
        auto cancelled = rec.Of("permissionCancelled");
        REQUIRE(cancelled.size() == 1);
        CHECK(cancelled[0].m_Detail["requestId"].AsString() == "h1");
        CHECK(session.PendingPermission() == "");
        CHECK_FALSE(session.Respond("h1", true));
        // One it doesn't know: nothing.
        session.HandleLine(R"({"type":"control_cancel_request","request_id":"zz"})");
        CHECK(rec.Of("permissionCancelled").size() == 1);
    }
}

TEST_CASE("ClaudeSession: permission requests", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());
    REQUIRE(session.Send("go"));

    const char* ask =
        R"({"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"permission_suggestions":[],"tool_use_id":"toolu_9"}})";
    session.HandleLine(ask);
    auto asked = rec.Of("permission");
    REQUIRE(asked.size() == 1);
    CHECK(asked[0].m_Detail["requestId"].AsString() == "r1");
    CHECK(asked[0].m_Detail["tool"].AsString() == "Bash");
    CHECK(asked[0].m_Detail["input"]["command"].AsString() == "ls");
    CHECK(asked[0].m_Detail["toolUseId"].AsString() == "toolu_9");
    CHECK(session.PendingPermission() == "r1");

    SECTION("allowed: the input goes back")
    {
        REQUIRE(session.Respond("r1", true));
        const Json& reply = rec.m_Written.back();
        CHECK(reply["type"].AsString() == "control_response");
        CHECK(reply["response"]["request_id"].AsString() == "r1");
        CHECK(reply["response"]["response"]["behavior"].AsString() == "allow");
        CHECK(reply["response"]["response"]["updatedInput"]["command"].AsString() == "ls");
        CHECK(session.PendingPermission() == "");
        CHECK_FALSE(session.Respond("r1", true)); // answered once
    }

    SECTION("denied, with a message")
    {
        REQUIRE(session.Respond("r1", false, "Not now"));
        const Json& reply = rec.m_Written.back();
        CHECK(reply["response"]["response"]["behavior"].AsString() == "deny");
        CHECK(reply["response"]["response"]["message"].AsString() == "Not now");
    }

    SECTION("an unknown request id")
    {
        CHECK_FALSE(session.Respond("r2", true));
    }

    SECTION("interrupting denies it first")
    {
        REQUIRE(session.Interrupt());
        REQUIRE(rec.m_Written.size() == 3);
        CHECK(rec.m_Written[1]["response"]["response"]["behavior"].AsString() == "deny");
        CHECK(rec.m_Written[2]["type"].AsString() == "control_request");
        CHECK(rec.m_Written[2]["request"]["subtype"].AsString() == "interrupt");

        // Requests that still come in are denied without asking.
        session.HandleLine(
            R"({"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}})");
        CHECK(rec.Of("permission").size() == 1);
        CHECK(rec.m_Written.back()["response"]["request_id"].AsString() == "r3");
        CHECK(rec.m_Written.back()["response"]["response"]["behavior"].AsString() == "deny");

        session.HandleLine(
            R"({"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1"})");
        auto result = rec.Of("result");
        REQUIRE(result.size() == 1);
        CHECK(result[0].m_Detail["interrupted"].AsBool());
        CHECK(result[0].m_Detail["isError"].AsBool());
        CHECK_FALSE(session.Interrupt()); // no turn to end
    }

    SECTION("two at once: each answered, in any order")
    {
        session.HandleLine(
            R"({"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{"file_path":"a.lua"}}})");
        CHECK(rec.Of("permission").size() == 2);
        CHECK(session.PendingPermission() == "r1");
        REQUIRE(session.Respond("r2", false, "No"));
        CHECK(rec.m_Written.back()["response"]["request_id"].AsString() == "r2");
        CHECK(session.PendingPermission() == "r1");
        REQUIRE(session.Respond("r1", true));
        CHECK(rec.m_Written.back()["response"]["request_id"].AsString() == "r1");
        CHECK(rec.m_Written.back()["response"]["response"]["updatedInput"]["command"].AsString() == "ls");
        CHECK(session.PendingPermission() == "");
    }

    SECTION("interrupting denies every one waiting")
    {
        session.HandleLine(
            R"({"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{}}})");
        REQUIRE(session.Interrupt());
        REQUIRE(rec.m_Written.size() == 4);
        CHECK(rec.m_Written[1]["response"]["request_id"].AsString() == "r1");
        CHECK(rec.m_Written[2]["response"]["request_id"].AsString() == "r2");
        CHECK(rec.m_Written[2]["response"]["response"]["behavior"].AsString() == "deny");
        CHECK(session.PendingPermission() == "");
    }
}

TEST_CASE("ClaudeSession: Claude's questions (AskUserQuestion)", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());
    REQUIRE(session.Send("go"));

    session.HandleLine(
        R"({"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which colour?","header":"Colour","options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}],"multiSelect":false},{"question":"Which parts?","header":"Parts","options":[{"label":"A","description":""},{"label":"B","description":""}],"multiSelect":true}]},"tool_use_id":"toolu_q","requires_user_interaction":true}})");
    auto asked = rec.Of("permission");
    REQUIRE(asked.size() == 1);
    CHECK(asked[0].m_Detail["tool"].AsString() == "AskUserQuestion");
    CHECK(asked[0].m_Detail["input"]["questions"].Size() == 2);

    SECTION("answered: the questions go back with the answers")
    {
        CHECK_FALSE(session.Answer("q1", Json::Object())); // no answer
        CHECK_FALSE(session.Answer("q1", Json("Red")));    // not an object
        CHECK_FALSE(session.Answer("q9", Json::Object().Set("Which colour?", "Red")));
        CHECK(session.PendingPermission() == "q1");
        REQUIRE(session.Answer(
            "q1", Json::Object().Set("Which colour?", "Blue").Set("Which parts?", "A, B")));
        const Json& reply = rec.m_Written.back();
        CHECK(reply["type"].AsString() == "control_response");
        CHECK(reply["response"]["subtype"].AsString() == "success");
        CHECK(reply["response"]["request_id"].AsString() == "q1");
        const Json& answer = reply["response"]["response"];
        CHECK(answer["behavior"].AsString() == "allow");
        CHECK(answer["updatedInput"]["questions"].Size() == 2);
        CHECK(answer["updatedInput"]["questions"][0]["question"].AsString() == "Which colour?");
        CHECK(answer["updatedInput"]["answers"]["Which colour?"].AsString() == "Blue");
        CHECK(answer["updatedInput"]["answers"]["Which parts?"].AsString() == "A, B");
        CHECK(session.PendingPermission() == "");
        CHECK_FALSE(session.Answer("q1", Json::Object().Set("Which colour?", "Red")));
    }

    SECTION("allowed without answers: told you didn't choose")
    {
        REQUIRE(session.Respond("q1", true));
        const Json& answer = rec.m_Written.back()["response"]["response"];
        CHECK(answer["behavior"].AsString() == "deny");
        CHECK(answer["message"].AsString().find("without choosing") != std::string::npos);
        CHECK(session.PendingPermission() == "");
    }

    SECTION("denied with a message")
    {
        REQUIRE(session.Respond("q1", false, "Not now"));
        const Json& answer = rec.m_Written.back()["response"]["response"];
        CHECK(answer["behavior"].AsString() == "deny");
        CHECK(answer["message"].AsString() == "Not now");
    }

    SECTION("another tool asking meanwhile is allowed as before")
    {
        session.HandleLine(
            R"({"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}})");
        REQUIRE(session.Respond("r2", true));
        CHECK(rec.m_Written.back()["response"]["response"]["behavior"].AsString() == "allow");
        CHECK(session.PendingPermission() == "q1");
    }
}

TEST_CASE("ClaudeSession: control requests", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());

    REQUIRE(session.SetModel("sonnet"));
    REQUIRE(session.SetPermissionMode("plan"));
    REQUIRE(rec.m_Written.size() == 2);
    CHECK(rec.m_Written[0]["request"]["subtype"].AsString() == "set_model");
    CHECK(rec.m_Written[0]["request"]["model"].AsString() == "sonnet");
    CHECK(rec.m_Written[1]["request"]["subtype"].AsString() == "set_permission_mode");
    CHECK(rec.m_Written[1]["request"]["mode"].AsString() == "plan");
    CHECK(rec.m_Written[0]["request_id"].AsString() != rec.m_Written[1]["request_id"].AsString());

    // One we don't know gets an error reply.
    session.HandleLine(
        R"({"type":"control_request","request_id":"x1","request":{"subtype":"mystery"}})");
    REQUIRE(rec.m_Written.size() == 3);
    CHECK(rec.m_Written[2]["response"]["subtype"].AsString() == "error");
    CHECK(rec.m_Written[2]["response"]["request_id"].AsString() == "x1");

    // A refusal of ours becomes an error event.
    session.HandleLine(
        R"({"type":"control_response","response":{"subtype":"error","request_id":"app-1","error":"bad model"}})");
    auto errors = rec.Of("error");
    REQUIRE(errors.size() == 1);
    CHECK(errors[0].m_Detail["message"].AsString() == "bad model");
}

TEST_CASE("ClaudeSession: usage and background tasks", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());
    REQUIRE(session.Send("go"));

    // One model call comes as a message per content block: its usage once.
    const char* first =
        R"({"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"a"}],"usage":{"input_tokens":10,"cache_read_input_tokens":500,"output_tokens":7}},"parent_tool_use_id":null})";
    session.HandleLine(first);
    session.HandleLine(first);
    session.HandleLine(
        R"({"type":"assistant","message":{"id":"m2","model":"claude-haiku","content":[{"type":"text","text":"b"}],"usage":{"input_tokens":3}},"parent_tool_use_id":"toolu_a"})");
    session.HandleLine(
        R"({"type":"system","subtype":"task_started","task_id":"t1","tool_use_id":"toolu_a","description":"Look","task_type":"local_agent"})");
    session.HandleLine(
        R"({"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1","usage":{"input_tokens":10},"modelUsage":{"claude-opus-5-5":{"contextWindow":200000}}})");

    auto usage = rec.Of("usage");
    REQUIRE(usage.size() == 2);
    CHECK(usage[0].m_Detail["model"].AsString() == "claude-opus-5-5");
    CHECK(usage[0].m_Detail["usage"]["cache_read_input_tokens"].AsInt() == 500);
    CHECK(usage[0].m_Detail["parent"].AsString() == "");
    CHECK(usage[1].m_Detail["parent"].AsString() == "toolu_a");

    auto system = rec.Of("system");
    REQUIRE(system.size() == 1);
    CHECK(system[0].m_Detail["subtype"].AsString() == "task_started");
    CHECK(system[0].m_Detail["raw"]["task_id"].AsString() == "t1");

    auto result = rec.Of("result");
    REQUIRE(result.size() == 1);
    CHECK(result[0].m_Detail["modelUsage"]["claude-opus-5-5"]["contextWindow"].AsInt() == 200000);
    CHECK(result[0].m_Detail["usage"]["input_tokens"].AsInt() == 10);

    // Stopping a task is a control request; no id, nothing sent.
    const size_t iwritten = rec.m_Written.size();
    REQUIRE(session.StopTask("t1"));
    REQUIRE(rec.m_Written.size() == iwritten + 1);
    CHECK(rec.m_Written.back()["request"]["subtype"].AsString() == "stop_task");
    CHECK(rec.m_Written.back()["request"]["task_id"].AsString() == "t1");
    CHECK_FALSE(session.StopTask(""));
    CHECK(rec.m_Written.size() == iwritten + 1);
}

TEST_CASE("ClaudeSession: usage limits", "[agent]")
{
    Recorder rec;
    ClaudeSession session(rec.Writer(), rec.Events());

    // Claude Code's rate_limit_event, as it prints it.
    session.HandleLine(
        R"({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1760720400,"rateLimitType":"five_hour","utilization":0.42,"unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1760720400},"seven_day":{"utilization":0.17,"resetsAt":1761152400}}},"uuid":"u1","session_id":"s1"})");
    // Without the windows (older versions): the rest still comes through.
    session.HandleLine(
        R"({"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"seven_day","utilization":0.8},"uuid":"u2","session_id":"s1"})");

    auto limits = rec.Of("rateLimit");
    REQUIRE(limits.size() == 2);
    const Json& info = limits[0].m_Detail["info"];
    CHECK(info["status"].AsString() == "allowed");
    CHECK(info["unifiedWindows"]["five_hour"]["utilization"].AsNumber() == 0.42);
    CHECK(info["unifiedWindows"]["seven_day"]["resetsAt"].AsInt() == 1761152400);
    CHECK(limits[1].m_Detail["info"]["rateLimitType"].AsString() == "seven_day");
    CHECK(limits[1].m_Detail["info"]["unifiedWindows"].IsNull());
}

#if defined(_WIN32) && defined(GITGUD_TEST_CLAUDE)

namespace
{

    ClaudeSession::Options FakeOptions()
    {
        ClaudeSession::Options options;
        options.m_Program = GITGUD_TEST_CLAUDE;
        return options;
    }

    std::string LastMessage(Recorder& _Rec)
    {
        auto messages = _Rec.Of("message");
        return messages.empty() ? std::string() : messages.back().m_Detail["text"].AsString();
    }

} // namespace

TEST_CASE("ClaudeSession: a session with the fake claude", "[agent]")
{
    Recorder rec;
    ClaudeSession session;
    ClaudeSession::Options options = FakeOptions();
    options.m_Model = "fake-opus";
    options.m_WorkingDir = std::filesystem::temp_directory_path().string();
    std::string error;
    REQUIRE(session.Start(options, rec.Events(), error));
    CHECK(session.Running());

    REQUIRE(session.Send("hello"));
    REQUIRE(rec.WaitFor("result"));
    auto init = rec.Of("init");
    REQUIRE(init.size() == 1);
    CHECK(init[0].m_Detail["model"].AsString() == "fake-opus");
    CHECK(std::filesystem::equivalent(init[0].m_Detail["cwd"].AsString(), options.m_WorkingDir));
    CHECK(session.SessionId() == "fake-session");
    auto text = rec.Of("text");
    REQUIRE(text.size() == 2);
    CHECK(text[0].m_Detail["text"].AsString() + text[1].m_Detail["text"].AsString() == "Hello");
    CHECK(LastMessage(rec) == "Hello");

    SECTION("permission allowed")
    {
        REQUIRE(session.Send("tool"));
        REQUIRE(rec.WaitFor("permission"));
        const std::string id = rec.Of("permission")[0].m_Detail["requestId"].AsString();
        REQUIRE(session.Respond(id, true));
        REQUIRE(rec.WaitFor("result", 2));
        auto results = rec.Of("toolResult");
        REQUIRE(results.size() == 1);
        CHECK(results[0].m_Detail["text"].AsString() == "ran echo hi");
        CHECK(LastMessage(rec) == "Done");
    }

    SECTION("permission denied")
    {
        REQUIRE(session.Send("tool"));
        REQUIRE(rec.WaitFor("permission"));
        const std::string id = rec.Of("permission")[0].m_Detail["requestId"].AsString();
        REQUIRE(session.Respond(id, false, "No"));
        REQUIRE(rec.WaitFor("result", 2));
        auto results = rec.Of("toolResult");
        REQUIRE(results.size() == 1);
        CHECK(results[0].m_Detail["isError"].AsBool());
        CHECK(results[0].m_Detail["text"].AsString() == "No");
    }

    SECTION("a question answered")
    {
        REQUIRE(session.Send("choose"));
        REQUIRE(rec.WaitFor("permission"));
        const Event asked = rec.Of("permission")[0];
        CHECK(asked.m_Detail["tool"].AsString() == "AskUserQuestion");
        const std::string question =
            asked.m_Detail["input"]["questions"][0]["question"].AsString();
        CHECK(question == "Which colour do you prefer?");
        REQUIRE(session.Answer(
            asked.m_Detail["requestId"].AsString(), Json::Object().Set(question, "Blue")));
        REQUIRE(rec.WaitFor("result", 2));
        CHECK(LastMessage(rec) == "You chose: Blue");
        CHECK(rec.Of("toolResult")[0].m_Detail["text"].AsString().find(
                  "\"Which colour do you prefer?\"=\"Blue\"") != std::string::npos);
    }

    SECTION("two questions, one multi-select, one in your own words")
    {
        REQUIRE(session.Send("choose two"));
        REQUIRE(rec.WaitFor("permission"));
        const Event asked = rec.Of("permission")[0];
        const Json& questions = asked.m_Detail["input"]["questions"];
        REQUIRE(questions.Size() == 2);
        CHECK(questions[1]["multiSelect"].AsBool());
        REQUIRE(session.Answer(asked.m_Detail["requestId"].AsString(),
            Json::Object()
                .Set(questions[0]["question"].AsString(), "Green, actually")
                .Set(questions[1]["question"].AsString(), "Install, License")));
        REQUIRE(rec.WaitFor("result", 2));
        CHECK(LastMessage(rec) == "You chose: Green, actually; Install, License");
    }

    SECTION("a question closed unanswered")
    {
        REQUIRE(session.Send("choose"));
        REQUIRE(rec.WaitFor("permission"));
        REQUIRE(session.Respond(rec.Of("permission")[0].m_Detail["requestId"].AsString(), true));
        REQUIRE(rec.WaitFor("result", 2));
        CHECK(LastMessage(rec).rfind("No answer: The user closed the question", 0) == 0);
    }

    SECTION("interrupt")
    {
        REQUIRE(session.Send("wait"));
        REQUIRE(rec.WaitFor("tool"));
        CHECK(session.TurnActive());
        REQUIRE(session.Interrupt());
        REQUIRE(rec.WaitFor("result", 2));
        CHECK(rec.Of("result").back().m_Detail["interrupted"].AsBool());
        CHECK_FALSE(session.TurnActive());

        // The session goes on after it.
        REQUIRE(session.Send("hello"));
        REQUIRE(rec.WaitFor("result", 3));
        CHECK_FALSE(rec.Of("result").back().m_Detail["interrupted"].AsBool());
    }

    SECTION("arguments, environment, stderr, unknown requests")
    {
        REQUIRE(session.Send("args"));
        REQUIRE(rec.WaitFor("result", 2));
        const std::string args = LastMessage(rec);
        CHECK(args.find("--input-format\nstream-json\n") != std::string::npos);
        CHECK(args.find("--model\nfake-opus\n") != std::string::npos);

        REQUIRE(session.Send("env"));
        REQUIRE(rec.WaitFor("result", 3));
        CHECK(LastMessage(rec) == "<unset>");

        REQUIRE(session.Send("skills"));
        REQUIRE(rec.WaitFor("result", 4));
        CHECK(LastMessage(rec) == "1");

        REQUIRE(session.Send("warn"));
        REQUIRE(rec.WaitFor("stderr"));
        CHECK(rec.Of("stderr")[0].m_Detail["line"].AsString() == "a warning");

        REQUIRE(session.Send("ask"));
        REQUIRE(rec.WaitFor("result", 6));
        CHECK(LastMessage(rec).find("Unsupported request: mystery") != std::string::npos);
    }

    SECTION("stop")
    {
        session.Stop();
        REQUIRE(rec.WaitFor("exit"));
        CHECK(rec.Of("exit")[0].m_Detail["code"].AsInt() == 0);
        CHECK_FALSE(session.Running());
        CHECK_FALSE(session.Send("hello"));
    }
}

TEST_CASE("ClaudeSession: the fake's background tasks stop on request", "[agent]")
{
    // The panel scenario writes files in its folder and the one above it.
    const std::filesystem::path dir = std::filesystem::temp_directory_path() / "gitgud-fake-panel" / "work";
    std::error_code ec;
    std::filesystem::remove_all(dir.parent_path(), ec);
    std::filesystem::create_directories(dir);

    Recorder rec;
    ClaudeSession session;
    ClaudeSession::Options options = FakeOptions();
    options.m_WorkingDir = dir.string();
    std::string error;
    REQUIRE(session.Start(options, rec.Events(), error));
    REQUIRE(session.Send("panel"));
    REQUIRE(rec.WaitFor("result"));
    CHECK(std::filesystem::exists(dir / "notes" / "plan.md"));
    CHECK(std::filesystem::exists(dir.parent_path() / "panel-outside.txt"));
    REQUIRE(rec.Of("usage").size() >= 1);

    auto started = [&rec]
    {
        int icount = 0;
        for (const auto& event : rec.Of("system"))
        {
            icount += event.m_Detail["subtype"].AsString() == "task_started" ? 1 : 0;
        }
        return icount;
    };
    CHECK(started() == 3);

    REQUIRE(session.StopTask("bash_1"));
    REQUIRE(rec.WaitFor("system", 5));
    const auto system = rec.Of("system");
    CHECK(system.back().m_Detail["raw"]["subtype"].AsString() == "task_notification");
    CHECK(system.back().m_Detail["raw"]["task_id"].AsString() == "bash_1");
    CHECK(system.back().m_Detail["raw"]["status"].AsString() == "stopped");

    // One that isn't running is refused.
    REQUIRE(session.StopTask("bash_1"));
    REQUIRE(rec.WaitFor("error"));
    CHECK(rec.Of("error")[0].m_Detail["message"].AsString() == "No such task: bash_1");

    session.Stop();
    REQUIRE(rec.WaitFor("exit"));
    std::filesystem::remove_all(dir.parent_path(), ec);
}

TEST_CASE("ClaudeSession: the process ends on its own", "[agent]")
{
    Recorder rec;
    ClaudeSession session;
    std::string error;
    REQUIRE(session.Start(FakeOptions(), rec.Events(), error));
    REQUIRE(session.Send("crash"));
    REQUIRE(rec.WaitFor("exit"));
    CHECK(rec.Of("exit")[0].m_Detail["code"].AsInt() == 3);
    CHECK_FALSE(session.TurnActive());
}

TEST_CASE("ClaudeSession: a program that isn't there", "[agent]")
{
    Recorder rec;
    ClaudeSession session;
    ClaudeSession::Options options;
    options.m_Program = "gitgud-no-such-claude";
    std::string error;
    CHECK_FALSE(session.Start(options, rec.Events(), error));
    CHECK_FALSE(error.empty());
    CHECK_FALSE(session.Running());
    CHECK_FALSE(session.Send("hello"));
}

#endif
