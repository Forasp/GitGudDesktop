#include "agent/ClaudeSession.h"

#include <algorithm>
#include <utility>

#include "agent/ChatImages.h"
#include "platform/ChildProcess.h"

namespace gitgud::agent
{

    using app::Json;

    namespace
    {

        // The Agent tool call a message belongs to, or "" for the main agent.
        std::string ParentOf(const Json& _Message)
        {
            return _Message["parent_tool_use_id"].AsString();
        }

        // A tool result's text: a string as is, or the text blocks joined.
        std::string ResultText(const Json& _Content)
        {
            if (_Content.IsString())
            {
                return _Content.AsString();
            }
            std::string text;
            for (const Json& block : _Content.Items())
            {
                if (block["type"].AsString() == "text")
                {
                    if (!text.empty())
                    {
                        text += "\n";
                    }
                    text += block["text"].AsString();
                }
            }
            return text;
        }

        // Claude's multiple-choice questions: allowed only with answers.
        constexpr const char* kAskTool = "AskUserQuestion";

        // What the model hears when a question goes unanswered.
        constexpr const char* kNotAnswered =
            "The user closed the question without choosing. Go on without the answer, or ask in "
            "plain text.";

    } // namespace

    ClaudeSession::ClaudeSession() = default;

    ClaudeSession::ClaudeSession(Writer _Writer, OnEvent _OnEvent)
        : m_Write(std::move(_Writer)), m_OnEvent(std::move(_OnEvent))
    {
    }

    ClaudeSession::~ClaudeSession()
    {
        // The process's callbacks reach into this object: end it first.
        m_pProcess.reset();
    }

    std::vector<std::string> ClaudeSession::Arguments(const Options& _Options)
    {
        std::vector<std::string> args{_Options.m_Program, "-p", "--output-format", "stream-json",
            "--input-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-prompt-tool", "stdio"};
        auto add = [&args](const char* _szFlag, const std::string& _Value)
        {
            if (!_Value.empty())
            {
                args.push_back(_szFlag);
                args.push_back(_Value);
            }
        };
        add("--model", _Options.m_Model);
        add("--permission-mode", _Options.m_PermissionMode);
        add("--effort", _Options.m_Effort);
        add("--settings", _Options.m_Settings);
        add("--resume", _Options.m_Resume);
        if (!_Options.m_Resume.empty())
        {
            add("--resume-session-at", _Options.m_ResumeAt);
            if (_Options.m_bForkSession)
            {
                args.push_back("--fork-session");
            }
        }
        add("--system-prompt", _Options.m_SystemPrompt);
        add("--append-system-prompt", _Options.m_AppendSystemPrompt);
        add("--mcp-config", _Options.m_McpConfig);
        if (!_Options.m_bPersist)
        {
            args.push_back("--no-session-persistence");
        }
        if (_Options.m_bLean)
        {
            // "" turns every built-in tool off.
            args.insert(args.end(),
                {"--tools", _Options.m_Tools, "--strict-mcp-config", "--disable-slash-commands"});
        }
        else
        {
            add("--tools", _Options.m_Tools);
        }
        return args;
    }

    bool ClaudeSession::Start(const Options& _Options, OnEvent _OnEvent, std::string& _Error)
    {
        if (m_pProcess)
        {
            _Error = "The session has already started";
            return false;
        }
        m_OnEvent = std::move(_OnEvent);
        m_Options = _Options;
        m_pProcess = std::make_unique<platform::ChildProcess>();
        m_Write = [this](const std::string& _Line)
        {
            return m_pProcess->WriteLine(_Line);
        };

        platform::ChildProcess::Options options;
        options.m_Args = Arguments(_Options);
        options.m_WorkingDir = _Options.m_WorkingDir;
        // Claude Code marks the programs it runs; a session started from one
        // is still a session of its own.
        options.m_Env.push_back({"CLAUDECODE", ""});
        // Skills synced from the claude.ai account load only when asked for.
        options.m_Env.push_back({"CLAUDE_CODE_SYNC_SKILLS", "1"});
        if (_Options.m_bLean)
        {
            // Nothing a helper doesn't need: it only answers one prompt.
            options.m_Env.push_back({"CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1"});
            options.m_Env.push_back({"CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1"});
            options.m_Env.push_back({"CLAUDE_CODE_DISABLE_BUNDLED_SKILLS", "1"});
            options.m_Env.push_back({"CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS", "1"});
            options.m_Env.push_back({"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"});
        }

        const bool bstarted = m_pProcess->Start(
            options, [this](const std::string& _Line) { HandleLine(_Line); },
            [this](const std::string& _Line) { Emit("stderr", Json::Object().Set("line", _Line)); },
            [this](int _iCode)
            {
                {
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_bTurnActive = false;
                    m_Pending.clear();
                }
                Emit("exit", Json::Object().Set("code", _iCode));
            },
            _Error);
        if (!bstarted)
        {
            m_pProcess.reset();
            m_Write = nullptr;
        }
        return bstarted;
    }

    bool ClaudeSession::WriteJson(const Json& _Message)
    {
        return m_Write && m_Write(_Message.Dump());
    }

    bool ClaudeSession::ControlRequest(const std::string& _Subtype, Json _Request)
    {
        int irequest = 0;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            irequest = ++m_iRequests;
        }
        _Request.Set("subtype", _Subtype);
        return WriteJson(Json::Object()
                .Set("type", "control_request")
                .Set("request_id", "app-" + std::to_string(irequest))
                .Set("request", std::move(_Request)));
    }

    Json ClaudeSession::PermissionAnswer(const std::string& _RequestId, bool _bAllow,
        const std::string& _Message, const Json& _Input)
    {
        Json answer = Json::Object();
        if (_bAllow)
        {
            // Claude Code runs the tool with the input it gets back.
            answer.Set("behavior", "allow")
                .Set("updatedInput", _Input.IsNull() ? Json::Object() : _Input);
        }
        else
        {
            answer.Set("behavior", "deny")
                .Set("message", _Message.empty() ? "Denied by the user." : _Message);
        }
        return Json::Object()
            .Set("type", "control_response")
            .Set("response", Json::Object()
                                 .Set("subtype", "success")
                                 .Set("request_id", _RequestId)
                                 .Set("response", std::move(answer)));
    }

    bool ClaudeSession::Send(const std::string& _Text, const std::vector<Json>& _Images)
    {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (!m_bTurnActive)
            {
                m_bInterrupted = false;
            }
            m_bTurnActive = true;
        }
        Json content = Json(_Text);
        if (!_Images.empty())
        {
            content = Json::Array();
            for (const Json& image : _Images)
            {
                content.Push(image);
            }
            if (!_Text.empty())
            {
                content.Push(Json::Object().Set("type", "text").Set("text", _Text));
            }
        }
        const bool bok = WriteJson(Json::Object()
                .Set("type", "user")
                .Set("message", Json::Object().Set("role", "user").Set("content", std::move(content)))
                .Set("parent_tool_use_id", nullptr)
                .Set("session_id", SessionId()));
        if (!bok)
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_bTurnActive = false;
        }
        return bok;
    }

    bool ClaudeSession::TakePending(const std::string& _RequestId, Pending& _Out)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        const auto it = std::find_if(m_Pending.begin(), m_Pending.end(),
            [&_RequestId](const Pending& _Pending) { return _Pending.m_RequestId == _RequestId; });
        if (_RequestId.empty() || it == m_Pending.end())
        {
            return false;
        }
        _Out = std::move(*it);
        m_Pending.erase(it);
        return true;
    }

    bool ClaudeSession::Respond(
        const std::string& _RequestId, bool _bAllow, const std::string& _Message)
    {
        Pending pending;
        if (!TakePending(_RequestId, pending))
        {
            return false;
        }
        if (_bAllow && pending.m_Tool == kAskTool)
        {
            // Allowed as is, it would run with no answers.
            return WriteJson(PermissionAnswer(_RequestId, false, kNotAnswered, Json()));
        }
        return WriteJson(PermissionAnswer(_RequestId, _bAllow, _Message, pending.m_Input));
    }

    bool ClaudeSession::Answer(const std::string& _RequestId, const Json& _Answers)
    {
        if (!_Answers.IsObject() || _Answers.Size() == 0)
        {
            return false;
        }
        Pending pending;
        if (!TakePending(_RequestId, pending))
        {
            return false;
        }
        Json input = pending.m_Input.IsObject() ? pending.m_Input : Json::Object();
        input.Set("answers", _Answers);
        return WriteJson(PermissionAnswer(_RequestId, true, "", input));
    }

    bool ClaudeSession::Interrupt()
    {
        std::vector<Pending> pending;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (!m_bTurnActive)
            {
                return false;
            }
            m_bInterrupted = true;
            pending = std::exchange(m_Pending, {});
        }
        for (const auto& request : pending)
        {
            WriteJson(
                PermissionAnswer(request.m_RequestId, false, "Interrupted by the user.", Json()));
        }
        return ControlRequest("interrupt", Json::Object());
    }

    bool ClaudeSession::SetPermissionMode(const std::string& _Mode)
    {
        return ControlRequest("set_permission_mode", Json::Object().Set("mode", _Mode));
    }

    bool ClaudeSession::SetModel(const std::string& _Model)
    {
        return ControlRequest("set_model", Json::Object().Set("model", _Model));
    }

    bool ClaudeSession::StopTask(const std::string& _TaskId)
    {
        return !_TaskId.empty() && ControlRequest("stop_task", Json::Object().Set("task_id", _TaskId));
    }

    std::string ClaudeSession::Control(const std::string& _Subtype, const Json& _Fields)
    {
        Json request = _Fields.IsObject() ? _Fields : Json::Object();
        request.Set("subtype", _Subtype);
        std::string requestId;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            requestId = "app-" + std::to_string(++m_iRequests);
            m_Asked[requestId] = _Subtype;
        }
        const bool bwritten = WriteJson(Json::Object()
                .Set("type", "control_request")
                .Set("request_id", requestId)
                .Set("request", std::move(request)));
        if (!bwritten)
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Asked.erase(requestId);
            return {};
        }
        return requestId;
    }

    void ClaudeSession::Stop(int _iGraceMs)
    {
        if (!m_pProcess)
        {
            return;
        }
        m_pProcess->CloseStdin();
        if (m_pProcess->Wait(_iGraceMs) < 0)
        {
            m_pProcess->Kill();
            m_pProcess->Wait(-1);
        }
    }

    bool ClaudeSession::Running() const
    {
        return m_pProcess && m_pProcess->Running();
    }

    bool ClaudeSession::TurnActive() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_bTurnActive;
    }

    std::string ClaudeSession::SessionId() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_SessionId;
    }

    std::string ClaudeSession::PendingPermission() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        return m_Pending.empty() ? std::string() : m_Pending.front().m_RequestId;
    }

    std::vector<ClaudeSession::Request> ClaudeSession::PendingRequests() const
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        std::vector<Request> out;
        out.reserve(m_Pending.size());
        for (const Pending& pending : m_Pending)
        {
            out.push_back({pending.m_RequestId, pending.m_Tool, pending.m_Input});
        }
        return out;
    }

    unsigned long ClaudeSession::ProcessId() const
    {
        return Running() ? m_pProcess->Id() : 0;
    }

    void ClaudeSession::Emit(const std::string& _Type, const Json& _Detail)
    {
        if (m_OnEvent)
        {
            m_OnEvent(_Type, _Detail);
        }
    }

    void ClaudeSession::HandleLine(const std::string& _Line)
    {
        if (_Line.find_first_not_of(" \t\r") == std::string::npos)
        {
            return;
        }
        const std::optional<Json> parsed = Json::Parse(_Line);
        if (!parsed || !parsed->IsObject())
        {
            // Not ours to read (a stray print): pass it on like stderr.
            Emit("stderr", Json::Object().Set("line", _Line));
            return;
        }
        const Json& message = *parsed;
        const std::string type = message["type"].AsString();

        std::vector<Event> events;
        std::vector<Json> replies;
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            if (type == "system")
            {
                const std::string subtype = message["subtype"].AsString();
                if (subtype == "init")
                {
                    m_SessionId = message["session_id"].AsString();
                    events.push_back({"init", Json::Object()
                                                  .Set("sessionId", m_SessionId)
                                                  .Set("model", message["model"])
                                                  .Set("permissionMode", message["permissionMode"])
                                                  .Set("cwd", message["cwd"])
                                                  .Set("tools", message["tools"])
                                                  .Set("apiKeySource", message["apiKeySource"])
                                                  .Set("version", message["claude_code_version"])
                                                  .Set("outputStyle", message["output_style"])
                                                  .Set("mcpServers", message["mcp_servers"])
                                                  .Set("slashCommands", message["slash_commands"])
                                                  .Set("skills", message["skills"])
                                                  .Set("plugins", message["plugins"])
                                                  .Set("agents", message["agents"])});
                }
                else
                {
                    events.push_back(
                        {"system", Json::Object().Set("subtype", subtype).Set("raw", message)});
                }
            }
            else if (type == "assistant")
            {
                OnAssistant(message, events);
            }
            else if (type == "user")
            {
                OnUser(message, events);
            }
            else if (type == "stream_event")
            {
                OnStreamEvent(message, events);
            }
            else if (type == "control_request")
            {
                OnControlRequest(message, events, replies);
            }
            else if (type == "control_cancel_request")
            {
                OnControlCancel(message, events);
            }
            else if (type == "control_response")
            {
                const Json& response = message["response"];
                const std::string requestId = response["request_id"].AsString();
                const auto asked = m_Asked.find(requestId);
                if (asked != m_Asked.end())
                {
                    // Asked through Control: the reply is the asker's.
                    const bool bok = response["subtype"].AsString() != "error";
                    events.push_back({"control", Json::Object()
                                                     .Set("requestId", requestId)
                                                     .Set("subtype", asked->second)
                                                     .Set("ok", bok)
                                                     .Set("response", response["response"])
                                                     .Set("error", response["error"])});
                    m_Asked.erase(asked);
                }
                else if (response["subtype"].AsString() == "error")
                {
                    events.push_back({"error", Json::Object().Set("message", response["error"])});
                }
            }
            else if (type == "result")
            {
                OnResult(message, events);
            }
            else if (type == "rate_limit_event")
            {
                events.push_back({"rateLimit", Json::Object().Set("info", message["rate_limit_info"])});
            }
        }

        for (const Json& reply : replies)
        {
            WriteJson(reply);
        }
        for (const Event& event : events)
        {
            Emit(event.m_Type, event.m_Detail);
        }
    }

    void ClaudeSession::OnAssistant(const Json& _Message, std::vector<Event>& _Out)
    {
        const std::string parent = ParentOf(_Message);
        const Json& usage = _Message["message"]["usage"];
        const std::string messageId = _Message["message"]["id"].AsString();
        if (usage.IsObject() && (messageId.empty() || messageId != m_UsageMessageId))
        {
            m_UsageMessageId = messageId;
            _Out.push_back({"usage", Json::Object()
                                         .Set("model", _Message["message"]["model"])
                                         .Set("usage", usage)
                                         .Set("parent", parent)
                                         .Set("messageId", messageId)});
        }
        for (const Json& block : _Message["message"]["content"].Items())
        {
            const std::string type = block["type"].AsString();
            if (type == "text")
            {
                // The uuid names the message: compaction sends the ones it
                // keeps again.
                _Out.push_back({"message", Json::Object()
                                               .Set("text", block["text"])
                                               .Set("parent", parent)
                                               .Set("uuid", _Message["uuid"])});
            }
            else if (type == "tool_use")
            {
                _Out.push_back({"tool",
                    Json::Object()
                        .Set("id", block["id"])
                        .Set("name", block["name"])
                        .Set("input", block["input"].IsNull() ? Json::Object() : block["input"])
                        .Set("parent", parent)});
            }
        }
    }

    void ClaudeSession::OnUser(const Json& _Message, std::vector<Event>& _Out)
    {
        const std::string parent = ParentOf(_Message);
        for (const Json& block : _Message["message"]["content"].Items())
        {
            if (block["type"].AsString() != "tool_result")
            {
                continue;
            }
            Json content = block["content"];
            Json images = Json::Array();
            for (const std::string& path : TakeChatImages(content))
            {
                images.Push(path);
            }
            _Out.push_back({"toolResult", Json::Object()
                                              .Set("id", block["tool_use_id"])
                                              .Set("text", ResultText(content))
                                              .Set("content", std::move(content))
                                              .Set("isError", block["is_error"].AsBool())
                                              .Set("parent", parent)
                                              .Set("images", std::move(images))});
        }
    }

    void ClaudeSession::OnStreamEvent(const Json& _Message, std::vector<Event>& _Out)
    {
        // Sub-agents stream too; their whole messages are enough.
        if (!ParentOf(_Message).empty())
        {
            return;
        }
        const Json& event = _Message["event"];
        const std::string type = event["type"].AsString();
        if (type == "content_block_start")
        {
            const Json& block = event["content_block"];
            _Out.push_back(
                {"block", Json::Object().Set("type", block["type"]).Set("name", block["name"])});
        }
        else if (type == "content_block_delta")
        {
            const Json& delta = event["delta"];
            const std::string kind = delta["type"].AsString();
            if (kind == "text_delta")
            {
                _Out.push_back({"text", Json::Object().Set("text", delta["text"])});
            }
            else if (kind == "thinking_delta")
            {
                _Out.push_back({"thinking", Json::Object().Set("text", delta["thinking"])});
            }
        }
    }

    void ClaudeSession::OnControlRequest(
        const Json& _Message, std::vector<Event>& _Out, std::vector<Json>& _Replies)
    {
        const std::string requestId = _Message["request_id"].AsString();
        const Json& request = _Message["request"];
        const std::string subtype = request["subtype"].AsString();
        if (subtype != "can_use_tool")
        {
            // Unknown requests get an error, so Claude Code doesn't wait on us.
            _Replies.push_back(Json::Object()
                    .Set("type", "control_response")
                    .Set("response", Json::Object()
                                         .Set("subtype", "error")
                                         .Set("request_id", requestId)
                                         .Set("error", "Unsupported request: " + subtype)));
            return;
        }
        if (m_bInterrupted && m_bTurnActive)
        {
            _Replies.push_back(
                PermissionAnswer(requestId, false, "Interrupted by the user.", Json()));
            return;
        }
        const std::string agentId = request["agent_id"].AsString();
        m_Pending.push_back({requestId, request["tool_name"].AsString(), request["input"], agentId});
        _Out.push_back({"permission",
            Json::Object()
                .Set("requestId", requestId)
                .Set("tool", request["tool_name"])
                .Set("input", request["input"].IsNull() ? Json::Object() : request["input"])
                .Set("suggestions", request["permission_suggestions"].IsNull()
                                        ? Json::Array()
                                        : request["permission_suggestions"])
                .Set("toolUseId", request["tool_use_id"])
                .Set("agentId", agentId.empty() ? Json() : Json(agentId))
                .Set("reason", request["decision_reason"].IsString() ? request["decision_reason"] : Json())});
    }

    void ClaudeSession::OnControlCancel(const Json& _Message, std::vector<Event>& _Out)
    {
        // Claude Code took a request back (its asker stopped, or no longer
        // needs the answer): the card closes.
        const std::string requestId = _Message["request_id"].AsString();
        const auto it = std::find_if(m_Pending.begin(), m_Pending.end(),
            [&requestId](const Pending& _Pending) { return _Pending.m_RequestId == requestId; });
        if (requestId.empty() || it == m_Pending.end())
        {
            return;
        }
        m_Pending.erase(it);
        _Out.push_back({"permissionCancelled", Json::Object().Set("requestId", requestId)});
    }

    void ClaudeSession::OnResult(const Json& _Message, std::vector<Event>& _Out)
    {
        if (_Message["session_id"].IsString())
        {
            m_SessionId = _Message["session_id"].AsString();
        }
        const bool binterrupted = m_bInterrupted;
        m_bTurnActive = false;
        m_bInterrupted = false;
        // The turn's own requests end with it; a helper's (a background
        // agent's) still waits for its answer.
        m_Pending.erase(std::remove_if(m_Pending.begin(), m_Pending.end(),
                            [](const Pending& _Pending) { return _Pending.m_AgentId.empty(); }),
            m_Pending.end());
        _Out.push_back({"result", Json::Object()
                                      .Set("subtype", _Message["subtype"])
                                      .Set("isError", _Message["is_error"].AsBool())
                                      .Set("interrupted", binterrupted)
                                      .Set("text", _Message["result"].AsString())
                                      .Set("sessionId", m_SessionId)
                                      .Set("costUsd", _Message["total_cost_usd"].AsNumber())
                                      .Set("turns", _Message["num_turns"].AsInt())
                                      .Set("durationMs", _Message["duration_ms"].AsInt())
                                      .Set("usage", _Message["usage"])
                                      .Set("modelUsage", _Message["modelUsage"])});
    }

} // namespace gitgud::agent
