#pragma once

// -----------------------------------------------------------------------------
// ClaudeSession: one Claude Code session the app drives, `claude -p` kept
// open with stream-json both ways (platform/ChildProcess).
//
// User turns go to its stdin as JSON lines; what it does comes back on
// stdout as JSON lines, turned into events here. Permission prompts arrive
// as control requests (`can_use_tool`) and wait for Respond(); Interrupt()
// ends the running turn.
//
// Events (OnEvent's type, and the fields of its JSON detail):
//
//   init        sessionId, model, permissionMode, cwd, tools
//   block       type ("text", "tool_use", "thinking"), name: a streamed
//               content block of the main agent starts
//   text        text: streamed text of the main agent (a delta)
//   thinking    text: streamed thinking of the main agent (a delta)
//   message     text, parent, uuid: a whole text block (sub-agents too;
//               parent is the Agent tool call's id, "" for the main agent;
//               uuid the message's, the same when compaction sends it again).
//               A slash command's output comes as one, from model
//               "<synthetic>"
//   tool        id, name, input, parent: a tool call
//   usage       model, usage, parent, messageId: the token counts of a
//               model call (an assistant message's `usage` as sent:
//               input_tokens, cache_creation_input_tokens,
//               cache_read_input_tokens, output_tokens), once per message
//   toolResult  id, text, content, isError, parent, images: its result
//               (`content` as sent, but with each image block's data
//               stored as a file: { type = "image", path }, agent/
//               ChatImages.h; `text` its text parts joined; `images` the
//               paths)
//   permission  requestId, tool, input, suggestions, toolUseId: answer with
//               Respond(), or Answer() for AskUserQuestion (Claude's
//               multiple-choice questions: input.questions, one to four,
//               each with question, header, options [{label, description}],
//               multiSelect)
//   result      subtype, isError, interrupted, text, sessionId, costUsd,
//               turns, durationMs, usage, modelUsage (per model, as sent:
//               contextWindow among them): the turn ended
//   rateLimit   info: the subscription's usage limits, `rate_limit_info`
//               as sent (status, rateLimitType, utilization, resetsAt, and
//               unifiedWindows: five_hour and seven_day, each utilization
//               as a fraction used and resetsAt in epoch seconds). Sent
//               when the limits move; never for API-key sessions
//   system      subtype, raw: other system messages (compaction, status,
//               and the background tasks: task_started, task_progress,
//               task_updated, task_notification, background_tasks_changed)
//   error       message: the session refused a request of ours
//   stderr      line
//   exit        code: the process ended (no events follow)
//
// OnEvent runs on the process's reader threads (stdout and stderr each have
// one), one event at a time per thread; don't call back into the session
// from it. Everything else is safe from any thread.
// -----------------------------------------------------------------------------

#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "app/Json.h"

namespace gitgud::platform
{
    class ChildProcess;
}

namespace gitgud::agent
{

    class ClaudeSession
    {
      public:
        struct Options
        {
            std::string m_Program = "claude";
            std::string m_WorkingDir;         // "" inherits ours
            std::string m_Model;              // "" for Claude Code's default
            std::string m_PermissionMode;     // "" for the default
            std::string m_Effort;             // low ... max; "" for the default
            std::string m_Settings;           // extra settings: a file or JSON text
            std::string m_Resume;             // a session id to continue
            // With m_Resume: keep only its messages up to and including
            // this transcript entry (its uuid), the rest left behind
            // (--resume-session-at); "" keeps them all.
            std::string m_ResumeAt;
            // With m_Resume: go on as a new session with the history
            // copied, the resumed one left as it was (--fork-session).
            bool m_bForkSession = false;
            std::string m_SystemPrompt;       // replaces Claude Code's own; "" keeps it
            std::string m_AppendSystemPrompt; // added to Claude Code's own
            std::string m_McpConfig;          // a file or JSON text
            bool m_bPersist = true;           // false: no transcript saved (helpers)
            // A lean helper (bragi/voice.lua): no tools, no MCP servers but
            // m_McpConfig's, no skills, no CLAUDE.md, no auto memory.
            bool m_bLean = false;
            // The built-in tools it has ("Read,Grep,Glob"); "" for all, or
            // for none when lean.
            std::string m_Tools;
        };

        using OnEvent = std::function<void(const std::string& _Type, const app::Json& _Detail)>;
        // Where request lines go: true when written.
        using Writer = std::function<bool(const std::string& _Line)>;

        ClaudeSession();
        // A session without a process: lines go to `_Writer`, and HandleLine
        // feeds it output (tests).
        ClaudeSession(Writer _Writer, OnEvent _OnEvent);
        ~ClaudeSession(); // stops the process

        ClaudeSession(const ClaudeSession&) = delete;
        ClaudeSession& operator=(const ClaudeSession&) = delete;

        // The command line Start runs (program first).
        static std::vector<std::string> Arguments(const Options& _Options);

        // Start the process once. False with `_Error` when it can't start.
        bool Start(const Options& _Options, OnEvent _OnEvent, std::string& _Error);

        // Send a user turn, with image blocks before the text (agent/
        // ChatImages.h, ImageBlockFromFile) when there are any. While a turn
        // runs, Claude Code takes it at the next step. False when the
        // session has ended.
        bool Send(const std::string& _Text, const std::vector<app::Json>& _Images = {});

        // Answer a permission request: allow, or deny with a message for the
        // model. AskUserQuestion is never allowed this way (it would run
        // without answers): allowing it tells the model you didn't choose.
        bool Respond(const std::string& _RequestId, bool _bAllow, const std::string& _Message = "");

        // Answer AskUserQuestion's request: `_Answers` maps each question's
        // text to the chosen option's label, labels joined with ", " for a
        // multi-select one, or your own words. It goes back as the tool's
        // input with `answers` added (the documented way: the Agent SDK's
        // "Handle approvals and user input"). False when no such request
        // waits or `_Answers` isn't an object with at least one answer.
        bool Answer(const std::string& _RequestId, const app::Json& _Answers);

        // End the running turn: a pending permission request is denied, then
        // Claude Code is told to stop. The turn's `result` reports it
        // interrupted. Nothing happens between turns.
        bool Interrupt();

        // Change the permission mode or the model for the next steps.
        bool SetPermissionMode(const std::string& _Mode);
        bool SetModel(const std::string& _Model);

        // Stop one of its tasks (a sub-agent or a background command), by
        // the task id its task_started system message gave. Claude Code
        // answers with an error event when it can't.
        bool StopTask(const std::string& _TaskId);

        // Ask Claude Code anything its control protocol takes (`_Subtype`,
        // with `_Fields` beside it in the request): get_usage,
        // apply_flag_settings, and so on. Returns the request id ("" when it
        // couldn't be written); the reply comes as a "control" event
        // ({ requestId, subtype, ok, response, error }), never as "error".
        std::string Control(const std::string& _Subtype, const app::Json& _Fields);

        // End input and give it `_iGraceMs` to exit, then end it.
        void Stop(int _iGraceMs = 1500);

        bool Running() const;
        bool TurnActive() const;
        std::string SessionId() const;
        // The oldest permission request waiting for an answer, or "".
        std::string PendingPermission() const;

        // A permission request waiting for an answer.
        struct Request
        {
            std::string m_RequestId;
            std::string m_Tool;
            app::Json m_Input;
        };
        // Every one waiting, oldest first (a reloaded UI shows them again).
        std::vector<Request> PendingRequests() const;

        // What Start was given (empty before it).
        const Options& StartOptions() const
        {
            return m_Options;
        }

        // The process's id, or 0 when it isn't running.
        unsigned long ProcessId() const;

        // One line of the process's stdout.
        void HandleLine(const std::string& _Line);

      private:
        struct Event
        {
            std::string m_Type;
            app::Json m_Detail;
        };

        bool WriteJson(const app::Json& _Message);
        bool ControlRequest(const std::string& _Subtype, app::Json _Request);
        struct Pending
        {
            std::string m_RequestId;
            std::string m_Tool;
            app::Json m_Input;
            // The helper (sub-agent) that asked, or "" for the conversation's
            // own agent. A helper's request can outlive the turn.
            std::string m_AgentId;
        };

        // The pending request `_RequestId`, taken out of m_Pending, or false.
        bool TakePending(const std::string& _RequestId, Pending& _Out);
        static app::Json PermissionAnswer(const std::string& _RequestId, bool _bAllow,
            const std::string& _Message, const app::Json& _Input);

        // Each turns one stdout message into events; called with m_Mutex held.
        void OnAssistant(const app::Json& _Message, std::vector<Event>& _Out);
        void OnUser(const app::Json& _Message, std::vector<Event>& _Out);
        void OnStreamEvent(const app::Json& _Message, std::vector<Event>& _Out);
        void OnControlRequest(
            const app::Json& _Message, std::vector<Event>& _Out, std::vector<app::Json>& _Replies);
        void OnControlCancel(const app::Json& _Message, std::vector<Event>& _Out);
        void OnResult(const app::Json& _Message, std::vector<Event>& _Out);

        void Emit(const std::string& _Type, const app::Json& _Detail);

        std::unique_ptr<platform::ChildProcess> m_pProcess;
        Options m_Options;
        Writer m_Write;
        OnEvent m_OnEvent;

        mutable std::mutex m_Mutex;
        std::string m_SessionId;
        bool m_bTurnActive = false;
        bool m_bInterrupted = false;
        // Permission requests waiting for an answer, oldest first: the
        // request id, the tool, and the input it asks about. Tools that run
        // in parallel can ask at once.
        std::vector<Pending> m_Pending;
        int m_iRequests = 0;
        // Control requests asked through Control, by request id: their
        // subtype. Their replies go out as "control" events.
        std::map<std::string, std::string> m_Asked;
        // The last assistant message whose usage was passed on (one call
        // comes as several messages, a content block each).
        std::string m_UsageMessageId;
    };

} // namespace gitgud::agent
