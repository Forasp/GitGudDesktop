// A stand-in for `claude -p` with stream-json both ways, for the
// ClaudeSession tests. Each user message picks a scenario by its text:
//
//   hello   streams "Hel" "lo", then the whole text, then a result
//   tool    a Bash call that asks permission; allowed, it "runs" and echoes
//           the input it got back; denied, the result is an error
//   tools   two tools that ask at once (Bash `git log`, Edit src/voice.lua);
//           answers "Bash <behavior>, Edit <behavior>" once both are answered
//   wait    a tool call that never finishes: only an interrupt ends the turn
//   work    a turn that takes about 6 s, streamed the way the real one is
//           (its thinking empty): thinking, a Read, 1.5 s, a Grep, 5 s,
//           then "Worked through it." (for the narrator)
//   work on <topic>
//           the same, reading src/<topic>.lua and searching for "callers of <topic> in the module tests"
//   slow    empty thinking, 10 s of nothing, then a streamed answer
//   told long
//           a long answer streamed over about 4 s: four paragraphs of about
//           75 words ("Part N begins here." then "This is sentence K of
//           part N."), a piece every 250 ms; the last ends "Should I go on?"
//   told story
//           the same, its paragraphs "Once upon a time, part N." ...
//   think   three thinking blocks with no words (empty, a signature only,
//           redacted), then one that has none for 2 s, then "Weighing the
//           parser. Then the tests.", then "Thought it through." streamed
//   late    a result with no turns and no text at once (what Claude Code
//           2.1 sends for a notification it only writes to the transcript,
//           such as a resumed session's word on a background command it
//           lost, before the message queued behind it), then 2.5 s later
//           "Merged, and the tests pass." streamed, the whole text, and
//           its result
//   args    answers with its command line, one argument per line
//   env     answers with CLAUDECODE ("<unset>" when it isn't set)
//   skills  answers with CLAUDE_CODE_SYNC_SKILLS ("<unset>" likewise)
//   warn    prints a line on stderr, then a result
//   ask     sends a control request the app doesn't know, then answers
//           with the reply it got
//   choose  asks one question with AskUserQuestion ("Which colour do you
//           prefer?": Red, Blue); answered, it says "You chose: " and the
//           answer; refused, "No answer: " and the message
//   choose two
//           asks two at once: the colour, and "Which sections should the
//           README have?" (multi-select: Install, Usage, License); answered,
//           "You chose: " and each answer, "; " between them
//   crash   exits with 3
//   /context
//           a slash command run as the real one runs it headless: its
//           output ("## Context Usage" ...) as an assistant message from
//           model "<synthetic>" with no tokens and a uuid, then a result
//           with no turns and local_command "context". Saved as Claude Code
//           saves it: a <command-name> user line, a local_command system line
//   /compact [instructions]
//           compaction: status "compacting", status null, compact_boundary
//           (manual, 45,000 tokens to 5,000), the summary as a user message
//           (isSynthetic), the last /context output sent again with the same
//           uuid, "<local-command-stdout>Compacted" as a user replay, then a
//           result with no text. Saved: compact_boundary, the summary
//           (isCompactSummary), the command line, its stdout
//   (any other "/..." is answered like any message: "You said: ...")
//   picture a Read of shot.png whose result is an image block (a small
//           PNG), then "Here is the screenshot."
//   links   a Read of the working folder's README.md (by its full path,
//           forward slashes), then a reply with links to click: a Markdown link to
//           https://github.com/mem0ai/mem0 ("Mem0"), a bare
//           https://example.com/docs/page followed by a full stop, the
//           working folder's full path, the full path of its README.md
//           followed by a full stop, `README.md` in backticks, and the full
//           path of missing.txt there (which doesn't exist)
//   (any message with image blocks before its text: the default answer
//           ends with " (1 image)" / " (n images)"; the transcript keeps
//           the blocks)
//   panel   the session panel's data (bragi/sidepanel.lua): a text with
//           usage (45,000 tokens in context), a Write of notes/plan.md (3
//           lines, written to disk), an Edit of README.md (a line added on
//           disk), a Write outside the working folder (../panel-outside.txt),
//           a sub-agent that runs and finishes ("Survey the parser"), a
//           background command ("Watch the build", task bash_1) and a
//           background sub-agent ("Review the long log in the background",
//           task task_a2) that keep running after the turn, with
//           task_started system messages; the result carries usage and
//           modelUsage (contextWindow 200000)
//   limits <five> <week>
//           the subscription's usage limits as Claude Code reports them
//           (2.1.x): a rate_limit_event whose rate_limit_info has status
//           "allowed" and unifiedWindows five_hour and seven_day, each
//           { utilization (the percent given / 100), resetsAt (epoch
//           seconds: in 2 h 15 min, and in 3 days 4 h) }, the top-level
//           rateLimitType, utilization, resetsAt the five-hour window's;
//           "-" leaves a window out (neither: no unifiedWindows). Then
//           "Limits."
//   tasks <n>
//           n background commands ("Background job 1" ...), tasks bash_j1 ...
//   finish  every background task still running completes
//           (task_notification), then "All done."
//   suites <n> <ms>
//           n background test runs ("Suite 1" ..., tasks bash_s1 ...), then
//           "Running the suites." Every <ms> after, one ends and gets a turn
//           nobody sent a message for (as Claude Code answers a background
//           task's report): "suite-<i> passes, <10 i> of <10 i>.", the last
//           one's with " All <n> suites pass."
//   plan <json>
//           the agent's plan: <json> is a list of calls, [{"name", "input"}],
//           made in turn without asking (TodoWrite, TaskCreate, TaskUpdate,
//           ...), each answered as Claude Code answers it: TaskCreate with
//           "Task #<n> created successfully: <subject>" (n counts from 1 in
//           each run), TaskUpdate with "Updated task #<id> status", others
//           with "Todos have been modified successfully."; then "Planned."
//   call <tool> <json>
//           calls the app's UI tool mcp__repo__<tool> with the JSON input
//           over the tool pipe (as gitgud-mcp would, naming the session
//           from its --mcp-config's --session), and answers with the reply
//           ("Refused: " and it when it's an error). It asks permission
//           first unless the folder's .claude/settings.local.json, or the
//           JSON given with --settings, allows it (permissions.allow has
//           mcp__repo__<tool>)
//   settings get [<setting>] / settings set <setting> <value>
//           the app's settings tools, as mcp__repo__bragi_settings_get/set:
//           asks permission (unless allowed, as `call` says, or by the
//           --settings it was given), then calls the app over the tool pipe
//           named in its --mcp-config (the way gitgud-mcp would), and answers with
//           the reply ("Refused: " and it when it's an error). Without
//           --ui-tools in that config the tool doesn't exist ("No such
//           tool"); a value of true or false is sent as a boolean, a number
//           as a number, anything else as text
//   {"message": ...}
//           the heard-text pre-pass (resources/uis/bragi/prompts/heard-text.md):
//           answers with its JSON, "lure" repaired to "Lua"; "that thing"
//           or "all that" without context asks for some (context comes
//           back as `context`, unchanged); "maybe" gives low confidence;
//           ending with "and" isn't complete; starting with "hmm" is a
//           remark; route recap when it has "catch me up" or "how are
//           my", command (with `command`) when it starts with "compact"
//           or "frobnicate" and has " this" (/compact, /frobnicate),
//           quick when it has "what
//           time", "which branch", "readme", "todo", "why does", or "never
//           mind", else main
//           (always main, why "Bragi's settings", for "faster", "slower",
//           "narration", or "dark mode").
//           Each of `corrections` found is replaced by what it meant; "cloud
//           desktop" becomes the first name ending in "Desktop" from
//           `conversation.names`, then `vocabulary`; "I said X, not Y" is
//           `learned` {Y, X}; "zorp" is kept, `unclear`, with low confidence;
//           "My input and change the" is left out without a word (the
//           2026-10-14 bug, for the app's check); `read_aloud` when it has
//           "story" or "read me"
//   {"message": ..., "recent": ...}
//           the router (prompts/route.md): route recap, quick or main, the
//           same way
//   {"question": ..., "conversations": ...}
//           the recap (prompts/recap.md): "Recap: " and each conversation's
//           "<title> is <state>", "; " between them ("nothing to follow"
//           when there are none), then "."
//   {"news": ...}
//           the recap's news: "Update: " and each conversation's "<title>
//           <what>", with ": " and its `reply` when it has one, "; "
//           between them
//   {"question": ..., "digest": ...}
//           the quick answerer (prompts/quick-answer.md): "why does" hands
//           back; "todo" asks to Write TODO.md and, refused, hands back;
//           "which branch" asks to use mcp__repo__branches and, allowed,
//           says `main`; "readme" Reads README.md (without asking) and
//           quotes its title; "what time" answers with the digest's time and
//           branch; "never mind" gets a short reply; anything else hands back
//   {"reply": ...}
//           the spoken summary (prompts/spoken-reply.md): "Summary: " and the
//           first sentence; " More." added when `length` is "medium". With
//           `part`: "Part <part>: " and the first sentence, " (again)" with
//           `replacing`, and for the last part of a reply that ends with a
//           question, " Should I go on?". A
//           reply with "word for word" in it comes back as it is (an echo),
//           unless `strict` is given ("Retold: " and its first three words);
//           with "always" too, it comes back as it is even then
//   {"steps": ...}
//           the narrator (prompts/narration.md), as {"say": ...} or
//           {"skip": true}: "Now: " and the last step's summary, name, or
//           text; with no steps, "Looking into: " and the request when
//           nothing was said yet (`said` empty, or `first` or `opening`
//           given: the app's guard drops a repeat), "Still on: " and the request when `quiet`
//           is given, else a skip. With `others` (other conversations'
//           steps), each one's "<title> on <what>" (its last step, or all
//           its `reply` steps' text, ", " between them) follows,
//           "; " between them ("Now: " and only those without steps of its
//           own). A request with "quietly" talks about skipping instead: as
//           prose for the opening line, as a `say` after a step
//   {"request": ..., "permission": ...}
//           the narrator's permission question, as a `say`: "Can I use
//           <tool>: <summary>?"
//   {"asked": ..., "options": ..., "multiSelect": ..., "answer": ...}
//           the choice classifier (prompts/choice.md): "first", "second",
//           "third" (else "one", "two", "three"), or an option's label in the
//           answer picks it (all of them on a multi-select question,
//           else the first found); "lunch" is no answer; anything else is
//           the answer as `other`; "maybe" makes it unsure
//   {"asked": ..., "answer": ...}
//           the approval classifier (prompts/approval.md): "maybe" or "not
//           sure" is unclear; an answer starting "no", or with "don't",
//           "wait", or "hold on", is deny; "yes", "go ahead", "yeah", or
//           "sure" allow, with what follows " but " as its `note`; anything
//           else unclear
//   {"said": ...}
//           the barge-in classifier (prompts/barge-in.md): "stop" in what
//           was said is stop, "instead" is steer, "keep going" or "go on"
//           resume, anything else a note
//
// Control requests from the app (set_model, set_permission_mode,
// interrupt) get a success reply; stop_task stops a background task (a
// task_notification with status "stopped" follows), or is refused when
// there's no such task. get_usage answers with the JSON in a file
// `fake-usage.json` in CLAUDE_CONFIG_DIR, and is refused without one (as
// where usage isn't available). The first message starts with a system
// init. End of input exits with 0.
//
// With a file `fake-transcripts` in CLAUDE_CONFIG_DIR, each session gets
// an id of its own (the resumed one with --resume) and its messages are
// written as Claude Code writes them: projects/<folder>/<id>.jsonl, each
// line naming the cwd (not with --no-session-persistence, as the app's
// helpers run). Lines chain as Claude Code's do: each has a `uuid` and the
// `parentUuid` of the line before it. A resumed session goes on from its
// last line, or with --resume-session-at <uuid> from that one (a rewind:
// the lines after it stay in the file, on a branch left behind). With
// --fork-session it goes on as a new id, its file starting with a copy of
// the resumed one's branch. Without the file the id is always
// "fake-session" and nothing is written.
//
// `--version` prints "0.0.0-fake (Claude Code)"; `--help` prints the
// permission mode choices as the real one words them. `auth status` prints the
// sign-in as JSON: the claude.ai subscription, unless CLAUDE_CONFIG_DIR
// holds a file `fake-auth` reading "out" (signed out) or "api" (an API key).

#include <cctype>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "agent/ToolPipe.h"
#include "app/Json.h"

using gitgud::app::Json;

namespace
{

    std::vector<std::string> g_Args;
    std::string g_SessionId = "fake-session";
    std::filesystem::path g_Transcript; // empty: none is written
    std::string g_Model = "fake-model";
    std::string g_Mode = "default";
    int g_iRequests = 0;
    int g_nImages = 0; // image blocks in the message being answered

    // An 8x6 PNG (a blue-tinted gradient), the `picture` scenario's screenshot.
    constexpr const char* kPicture =
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAAcklEQVR4nBXKMREAIQwAwUihRAYSIgEZKZESKZQnAyf381tvROAIXIE78AR24A18gRE"
        "Tx8Q1cU88E3vinfjmHxJH4krciSexE2/iyz8UjsJVuAtPYRfewld/aByNq3E3nsZuvI2v/wAOcIEbPGCDF3zgB98SfRE4KRJlAAAAAElFTkSuQmCC";

    // The transcript's lines chain: each names the one before it.
    std::string g_LastUuid;  // the entry the next line follows ("" for none)
    int g_nUuids = 0;
    // --fork-session: the resumed session's file, copied (its branch up to
    // g_LastUuid) into the new one before the first line is written.
    std::filesystem::path g_ForkFrom;

    std::string NewUuid()
    {
        const auto ticks = std::chrono::steady_clock::now().time_since_epoch().count();
        return "fake-uuid-" + std::to_string(ticks) + "-" + std::to_string(++g_nUuids);
    }

    // A transcript's lines, parsed.
    std::vector<Json> TranscriptLines(const std::filesystem::path& _Path)
    {
        std::vector<Json> lines;
        std::ifstream in(_Path, std::ios::binary);
        std::string line;
        while (std::getline(in, line))
        {
            if (std::optional<Json> parsed = Json::Parse(line))
            {
                lines.push_back(std::move(*parsed));
            }
        }
        return lines;
    }

    // The branch ending at `_Uuid` of a transcript's lines, oldest first.
    std::vector<Json> BranchTo(const std::vector<Json>& _Lines, const std::string& _Uuid)
    {
        std::vector<Json> branch;
        std::string wanted = _Uuid;
        for (auto it = _Lines.rbegin(); it != _Lines.rend() && !wanted.empty(); ++it)
        {
            if ((*it)["uuid"].AsString() == wanted)
            {
                branch.insert(branch.begin(), *it);
                wanted = (*it)["parentUuid"].AsString();
            }
        }
        return branch;
    }

    // Now in UTC, as Claude Code stamps its lines ("2026-10-19T18:17:43.000Z").
    std::string UtcNow()
    {
        const std::time_t now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
        std::tm utc{};
#if defined(_WIN32)
        gmtime_s(&utc, &now);
#else
        gmtime_r(&now, &utc);
#endif
        char sz[32];
        std::strftime(sz, sizeof(sz), "%Y-%m-%dT%H:%M:%S.000Z", &utc);
        return sz;
    }

    // A user or assistant message, as Claude Code saves it.
    void Record(const std::string& _Type, const Json& _Message)
    {
        if (g_Transcript.empty())
        {
            return;
        }
        std::ofstream out(g_Transcript, std::ios::binary | std::ios::app);
        if (!g_ForkFrom.empty())
        {
            for (Json line : BranchTo(TranscriptLines(g_ForkFrom), g_LastUuid))
            {
                out << line.Set("sessionId", g_SessionId).Dump() << "\n";
            }
            g_ForkFrom.clear();
        }
        const std::string uuid = NewUuid();
        out << Json::Object()
                   .Set("parentUuid", g_LastUuid.empty() ? Json() : Json(g_LastUuid))
                   .Set("uuid", uuid)
                   .Set("type", _Type)
                   .Set("timestamp", UtcNow())
                   .Set("cwd", std::filesystem::current_path().u8string())
                   .Set("sessionId", g_SessionId)
                   .Set("message", _Message)
                   .Dump()
            << "\n";
        g_LastUuid = uuid;
    }

    // Another line of the transcript, as given (a slash command's lines).
    void RecordLine(Json _Line)
    {
        if (g_Transcript.empty())
        {
            return;
        }
        std::ofstream out(g_Transcript, std::ios::binary | std::ios::app);
        out << _Line.Set("cwd", std::filesystem::current_path().u8string())
                   .Set("sessionId", g_SessionId)
                   .Dump()
            << "\n";
    }

    // A line sent but not saved as it is.
    void Print(const Json& _Message)
    {
        std::cout << _Message.Dump() << "\n";
        std::cout.flush();
    }

    void Out(const Json& _Message)
    {
        Print(_Message);
        const std::string type = _Message["type"].AsString();
        if (type == "assistant" || type == "user")
        {
            Record(type, _Message["message"]);
        }
    }

    bool ReadMessage(Json& _Out)
    {
        std::string line;
        while (std::getline(std::cin, line))
        {
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }
            if (auto parsed = Json::Parse(line))
            {
                _Out = *parsed;
                return true;
            }
        }
        return false;
    }

    // A request about Bragi's own settings: only the main session has the
    // settings tools.
    bool IsSettings(const std::string& _Text)
    {
        for (const char* szword : {"faster", "slower", "narration", "dark mode"})
        {
            if (_Text.find(szword) != std::string::npos)
            {
                return true;
            }
        }
        return false;
    }

    // Words that ask how the conversations Bragi follows are doing.
    bool IsRecap(const std::string& _Text)
    {
        return _Text.find("catch me up") != std::string::npos || _Text.find("how are my") != std::string::npos;
    }

    // Words that make a message quick, for the filter and the router.
    bool IsQuick(const std::string& _Text)
    {
        if (IsSettings(_Text))
        {
            return false;
        }
        for (const char* szword : {"what time", "which branch", "readme", "todo", "why does", "never mind"})
        {
            if (_Text.find(szword) != std::string::npos)
            {
                return true;
            }
        }
        return false;
    }

    // The slash command a message asks to run in its own words ("compact
    // this conversation" is /compact; "frobnicate this" is /frobnicate, a
    // command that doesn't exist), or "".
    std::string CommandOf(const std::string& _Text)
    {
        for (const char* szword : {"compact", "frobnicate"})
        {
            if (_Text.rfind(szword, 0) == 0 && _Text.find(" this") != std::string::npos)
            {
                return std::string("/") + szword;
            }
        }
        return std::string();
    }

    // The route the filter and the router give.
    const char* RouteOf(const std::string& _Text)
    {
        return IsRecap(_Text) ? "recap" : !CommandOf(_Text).empty() ? "command" : IsQuick(_Text) ? "quick" : "main";
    }

    // The recap (prompts/recap.md): "Recap: " and each conversation's title
    // and state.
    std::string Recap(const Json& _Request)
    {
        const Json& list = _Request["conversations"];
        std::string out;
        for (std::size_t i = 0; i < list.Size(); ++i)
        {
            out += (out.empty() ? "" : "; ") + list[i]["title"].AsString() + " is " + list[i]["state"].AsString();
        }
        return "Recap: " + (out.empty() ? std::string("nothing to follow") : out) + ".";
    }

    std::string Lower(std::string _Text)
    {
        for (char& c : _Text)
        {
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        return _Text;
    }

    // Replace the first _From in _Text (any case) with _To. True if found.
    bool ReplaceWord(std::string& _Text, const std::string& _From, const std::string& _To)
    {
        const std::size_t ipos = Lower(_Text).find(Lower(_From));
        if (_From.empty() || ipos == std::string::npos)
        {
            return false;
        }
        _Text.replace(ipos, _From.size(), _To);
        return true;
    }

    // The first entry of a string array ending in _Suffix, or "".
    std::string EndingIn(const Json& _List, const std::string& _Suffix)
    {
        for (std::size_t i = 0; i < _List.Size(); ++i)
        {
            const std::string entry = _List[i].AsString();
            if (entry.size() > _Suffix.size() && entry.substr(entry.size() - _Suffix.size()) == _Suffix)
            {
                return entry;
            }
        }
        return "";
    }

    // The pre-pass filter's answer to a heard message.
    Json HeardText(const Json& _Request)
    {
        const std::string heard = _Request["message"].AsString();
        std::string repaired = heard;
        Json changes = Json::Array();
        Json unclear = Json::Array();
        Json learned = Json::Array();
        std::string confidence = heard.find("maybe") != std::string::npos ? "low" : "high";
        const Json& corrections = _Request["corrections"];
        for (std::size_t i = 0; i < corrections.Size(); ++i)
        {
            const std::string from = corrections[i]["heard"].AsString();
            const std::string to = corrections[i]["meant"].AsString();
            if (ReplaceWord(repaired, from, to))
            {
                changes.Push(Json::Object().Set("heard", from).Set("text", to).Set("why", "learned"));
            }
        }
        if (Lower(repaired).find("cloud desktop") != std::string::npos)
        {
            std::string name = EndingIn(_Request["conversation"]["names"], " Desktop");
            const char* szwhy = name.empty() ? "in the vocabulary" : "said in the conversation";
            name = name.empty() ? EndingIn(_Request["vocabulary"], " Desktop") : name;
            if (!name.empty() && ReplaceWord(repaired, "cloud desktop", name))
            {
                changes.Push(Json::Object().Set("heard", "cloud desktop").Set("text", name).Set("why", szwhy));
            }
        }
        if (const std::size_t isaid = heard.find("I said "); isaid != std::string::npos)
        {
            const std::size_t inot = heard.find(", not ", isaid);
            if (inot != std::string::npos)
            {
                std::string wrong = heard.substr(inot + 6);
                while (!wrong.empty() && (wrong.back() == '.' || wrong.back() == ' '))
                {
                    wrong.pop_back();
                }
                learned.Push(Json::Object()
                        .Set("heard", wrong)
                        .Set("meant", heard.substr(isaid + 7, inot - isaid - 7)));
            }
        }
        if (heard.find("zorp") != std::string::npos)
        {
            unclear.Push(Json::Object().Set("heard", "zorp").Set("why", "can't place it"));
            confidence = "low";
        }
        // The old bug: a fragment it couldn't place, quietly left out.
        ReplaceWord(repaired, "My input and change the ", "");
        if (const std::size_t ipos = repaired.find("lure"); ipos != std::string::npos)
        {
            repaired.replace(ipos, 4, "Lua");
            changes.Push(Json::Object()
                    .Set("heard", "lure")
                    .Set("text", "Lua")
                    .Set("why", "the scripting language"));
        }
        const std::string context = _Request["context"].AsString();
        const bool bneeds = (heard.find("that thing") != std::string::npos ||
                                heard.find("all that") != std::string::npos) &&
                            context.empty();
        // A model's slips: the context as a list of lines, and a phrase in
        // it that can't be placed.
        Json contextOut = Json(context);
        if (context.find("deer hair") != std::string::npos)
        {
            contextOut = Json::Array();
            std::size_t istart = 0;
            while (istart <= context.size())
            {
                const std::size_t iend = std::min(context.find('\n', istart), context.size());
                contextOut.Push(Json(context.substr(istart, iend - istart)));
                istart = iend + 1;
            }
            unclear.Push(Json::Object().Set("heard", "deer hair").Set("why", "doesn't fit the discussion"));
        }
        return Json::Object()
            .Set("text", repaired)
            .Set("heard", heard)
            .Set("context", contextOut)
            .Set("needs_context", bneeds ? "some" : "none")
            .Set("changes", changes)
            .Set("unclear", unclear)
            .Set("learned", learned)
            .Set("confidence", confidence)
            .Set("kind", heard.rfind("hmm", 0) == 0 ? "remark" : "request")
            .Set("complete", heard.size() < 4 || heard.substr(heard.size() - 4) != " and")
            .Set("route", RouteOf(heard))
            .Set("read_aloud", heard.find("story") != std::string::npos ||
                                   heard.find("read me") != std::string::npos)
            .Set("command", CommandOf(heard))
            .Set("route_why", IsSettings(heard) ? "Bragi's settings" : "fake");
    }

    // Background tasks still running: task id -> tool use id.
    std::vector<std::pair<std::string, std::string>> g_Background;

    Json System(const std::string& _Subtype)
    {
        return Json::Object().Set("type", "system").Set("subtype", _Subtype).Set("session_id", g_SessionId);
    }

    void TaskEnded(const std::string& _TaskId, const std::string& _ToolUseId, const std::string& _Status)
    {
        Out(System("task_notification")
                .Set("task_id", _TaskId)
                .Set("tool_use_id", _ToolUseId)
                .Set("status", _Status)
                .Set("output_file", "")
                .Set("summary", _Status == "stopped" ? "Stopped" : "Finished"));
    }

    void Reply(const Json& _Request)
    {
        if (_Request["request"]["subtype"].AsString() == "get_usage")
        {
            std::optional<Json> usage;
            if (const char* szdir = std::getenv("CLAUDE_CONFIG_DIR"))
            {
                std::ifstream in(std::filesystem::path(szdir) / "fake-usage.json", std::ios::binary);
                const std::string body((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
                usage = Json::Parse(body);
            }
            Json response = Json::Object().Set("request_id", _Request["request_id"]);
            if (usage)
            {
                response.Set("subtype", "success").Set("response", *usage);
            }
            else
            {
                response.Set("subtype", "error").Set("error", "get_usage is not supported in this context");
            }
            Out(Json::Object().Set("type", "control_response").Set("response", response));
            return;
        }
        if (_Request["request"]["subtype"].AsString() == "stop_task")
        {
            const std::string taskId = _Request["request"]["task_id"].AsString();
            const auto it = std::find_if(g_Background.begin(), g_Background.end(),
                [&taskId](const auto& _Task) { return _Task.first == taskId; });
            if (it == g_Background.end())
            {
                Out(Json::Object()
                        .Set("type", "control_response")
                        .Set("response", Json::Object()
                                             .Set("subtype", "error")
                                             .Set("request_id", _Request["request_id"])
                                             .Set("error", "No such task: " + taskId)));
                return;
            }
            const auto task = *it;
            g_Background.erase(it);
            Out(Json::Object()
                    .Set("type", "control_response")
                    .Set("response", Json::Object()
                                         .Set("subtype", "success")
                                         .Set("request_id", _Request["request_id"])
                                         .Set("response", Json::Object())));
            TaskEnded(task.first, task.second, "stopped");
            return;
        }
        Out(Json::Object()
                .Set("type", "control_response")
                .Set("response", Json::Object()
                                     .Set("subtype", "success")
                                     .Set("request_id", _Request["request_id"])
                                     .Set("response", Json::Object())));
    }

    Json Assistant(Json _Content, const std::string& _Parent = "")
    {
        return Json::Object()
            .Set("type", "assistant")
            .Set("message",
                Json::Object().Set("role", "assistant").Set("content", std::move(_Content)))
            .Set("parent_tool_use_id", _Parent.empty() ? Json() : Json(_Parent))
            .Set("session_id", g_SessionId);
    }

    Json TextBlock(const std::string& _Text)
    {
        return Json::Object().Set("type", "text").Set("text", _Text);
    }

    Json Delta(const std::string& _Text)
    {
        return Json::Object()
            .Set("type", "stream_event")
            .Set("event",
                Json::Object()
                    .Set("type", "content_block_delta")
                    .Set("index", 0)
                    .Set("delta", Json::Object().Set("type", "text_delta").Set("text", _Text)))
            .Set("parent_tool_use_id", nullptr);
    }

    Json ToolResult(const std::string& _Id, Json _Content, bool _bError)
    {
        return Json::Object()
            .Set("type", "user")
            .Set("message", Json::Object()
                                .Set("role", "user")
                                .Set("content", Json::Array().Push(Json::Object()
                                                        .Set("type", "tool_result")
                                                        .Set("tool_use_id", _Id)
                                                        .Set("content", std::move(_Content))
                                                        .Set("is_error", _bError))))
            .Set("parent_tool_use_id", nullptr);
    }

    void Result(const std::string& _Text, const std::string& _Subtype = "success")
    {
        Out(Json::Object()
                .Set("type", "result")
                .Set("subtype", _Subtype)
                .Set("is_error", _Subtype != "success")
                .Set("result", _Text)
                .Set("session_id", g_SessionId)
                .Set("total_cost_usd", 0.25)
                .Set("num_turns", 1)
                .Set("duration_ms", 1200));
    }

    void Say(const std::string& _Text)
    {
        Out(Assistant(Json::Array().Push(TextBlock(_Text))));
        Result(_Text);
    }

    // Wait for the app's answer to request `_Id`, replying to its own
    // control requests meanwhile. False at end of input.
    bool AwaitAnswer(const std::string& _Id, Json& _Answer)
    {
        Json message;
        while (ReadMessage(message))
        {
            const std::string type = message["type"].AsString();
            if (type == "control_response" && message["response"]["request_id"].AsString() == _Id)
            {
                _Answer = message["response"];
                return true;
            }
            if (type == "control_request")
            {
                Reply(message);
            }
        }
        return false;
    }

    // Call a tool that asks first: the call, then the permission request.
    // `_Decision` is the app's answer (behavior, updatedInput or message).
    // False at end of input.
    bool AskToUse(const std::string& _ToolUseId, const std::string& _Tool, const Json& _Input,
        Json& _Decision)
    {
        Out(Assistant(Json::Array().Push(Json::Object()
                .Set("type", "tool_use")
                .Set("id", _ToolUseId)
                .Set("name", _Tool)
                .Set("input", _Input))));
        const std::string id = "perm-" + std::to_string(++g_iRequests);
        Out(Json::Object()
                .Set("type", "control_request")
                .Set("request_id", id)
                .Set("request", Json::Object()
                                    .Set("subtype", "can_use_tool")
                                    .Set("tool_name", _Tool)
                                    .Set("input", _Input)
                                    .Set("permission_suggestions", Json::Array())
                                    .Set("tool_use_id", _ToolUseId)));
        Json answer;
        if (!AwaitAnswer(id, answer))
        {
            return false;
        }
        _Decision = answer["response"];
        return true;
    }

    // The choice classifier's answer (prompts/choice.md).
    Json Choice(const Json& _Request)
    {
        std::string answer = _Request["answer"].AsString();
        for (char& c : answer)
        {
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        auto has = [&answer](const std::string& _Word) { return answer.find(_Word) != std::string::npos; };
        const Json& options = _Request["options"];
        const bool bmulti = _Request["multiSelect"].AsBool();
        Json choice = Json::Array();
        // "first" before "one", so "the second one" is the second.
        const char* aszOrdinals[] = {"first", "second", "third"};
        const char* aszNumbers[] = {"one", "two", "three"};
        const bool bordinals = has("first") || has("second") || has("third");
        for (size_t i = 0; i < options.Size(); ++i)
        {
            std::string label = options[i]["label"].AsString();
            for (char& c : label)
            {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            const bool bnumber = i < 3 && (bordinals ? has(aszOrdinals[i]) : has(aszNumbers[i]));
            if ((bnumber || has(label)) && (bmulti || choice.Size() == 0))
            {
                choice.Push(options[i]["label"]);
            }
        }
        std::string other;
        if (choice.Size() == 0 && !has("lunch"))
        {
            other = _Request["answer"].AsString();
        }
        return Json::Object()
            .Set("choice", std::move(choice))
            .Set("other", other)
            .Set("sure", !has("maybe"))
            .Set("why", "fake");
    }

    // The quick answerer (prompts/quick-answer.md).
    void QuickAnswer(const Json& _Request)
    {
        const std::string question = _Request["question"].AsString();
        auto has = [&question](const char* _szWord)
        { return question.find(_szWord) != std::string::npos; };
        Json decision;
        if (has("why does"))
        {
            Say("HANDOFF: that needs judgment");
        }
        else if (has("todo"))
        {
            // Tries to change a file: refused, so it hands back.
            const Json input =
                Json::Object().Set("file_path", "TODO.md").Set("content", "- [x] first\n");
            if (!AskToUse("toolu_q1", "Write", input, decision))
            {
                return;
            }
            if (decision["behavior"].AsString() == "allow")
            {
                Out(ToolResult("toolu_q1", "written", false));
                Say("Ticked it off.");
                return;
            }
            Out(ToolResult("toolu_q1", decision["message"].AsString(), true));
            Say("HANDOFF: that needs an edit");
        }
        else if (has("which branch"))
        {
            // The app's repo tool asks first, like any MCP tool.
            if (!AskToUse("toolu_q2", "mcp__repo__branches", Json::Object(), decision))
            {
                return;
            }
            const bool ballowed = decision["behavior"].AsString() == "allow";
            Out(ToolResult("toolu_q2", ballowed ? "* main" : decision["message"].AsString(), !ballowed));
            Say(ballowed ? "You're on `main`." : "HANDOFF: the branches tool was refused");
        }
        else if (has("readme"))
        {
            // Reading in the folder doesn't ask.
            Out(Assistant(Json::Array().Push(Json::Object()
                    .Set("type", "tool_use")
                    .Set("id", "toolu_q3")
                    .Set("name", "Read")
                    .Set("input", Json::Object().Set("file_path", "README.md")))));
            Out(ToolResult("toolu_q3", "# Test repository", false));
            Say("The README is titled \"Test repository\".");
        }
        else if (has("what time"))
        {
            Say("It's " + _Request["digest"]["time"].AsString() + " on `" +
                _Request["digest"]["repository"]["branch"].AsString() + "`.");
        }
        else if (has("never mind"))
        {
            // Nothing to answer: a short reply, never handed back.
            Say("Good, glad you found it.");
        }
        else
        {
            Say("HANDOFF: not a quick question");
        }
    }

    // The app's MCP server in --mcp-config: its pipe, and whether it has the
    // UI's tools (--ui-tools). False when there's none.
    bool AppServer(std::string& _Pipe, bool& _bSettings, std::string* _pSession = nullptr)
    {
        std::string config;
        for (std::size_t i = 0; i + 1 < g_Args.size(); ++i)
        {
            if (g_Args[i] == "--mcp-config")
            {
                config = g_Args[i + 1];
            }
        }
        if (!config.empty() && config[0] != '{')
        {
            std::ifstream in(std::filesystem::u8path(config), std::ios::binary);
            config.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        }
        const Json parsed = Json::Parse(config).value_or(Json());
        const Json& args = parsed["mcpServers"]["repo"]["args"];
        _bSettings = false;
        _Pipe.clear();
        for (std::size_t i = 0; i < args.Size(); ++i)
        {
            if (args[i].AsString() == "--pipe" && i + 1 < args.Size())
            {
                _Pipe = args[i + 1].AsString();
            }
            _bSettings = _bSettings || args[i].AsString() == "--ui-tools";
            if (_pSession && args[i].AsString() == "--session" && i + 1 < args.Size())
            {
                *_pSession = args[i + 1].AsString();
            }
        }
        return !_Pipe.empty();
    }

    // Whether the folder's .claude/settings.local.json, or the settings
    // given with --settings, allow a tool.
    bool Allowed(const std::string& _Tool)
    {
        std::ifstream in(std::filesystem::current_path() / ".claude" / "settings.local.json",
            std::ios::binary);
        const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        std::vector<Json> sources{Json::Parse(text).value_or(Json())};
        for (std::size_t i = 0; i + 1 < g_Args.size(); ++i)
        {
            if (g_Args[i] == "--settings")
            {
                sources.push_back(Json::Parse(g_Args[i + 1]).value_or(Json()));
            }
        }
        for (const Json& settings : sources)
        {
            for (const Json& rule : settings["permissions"]["allow"].Items())
            {
                if (rule.AsString() == _Tool)
                {
                    return true;
                }
            }
        }
        return false;
    }

    // "call <tool> <json>": one of the app's UI tools.
    void CallTool(const std::string& _Text)
    {
        std::istringstream words(_Text);
        std::string word;
        std::string tool;
        words >> word >> tool;
        std::string rest;
        std::getline(words, rest);
        Json input = Json::Parse(rest).value_or(Json::Object());
        const std::string name = "mcp__repo__" + tool;
        const std::string toolId = "toolu_c" + std::to_string(++g_iRequests);
        std::string pipe;
        std::string session;
        bool bui = false;
        if (!AppServer(pipe, bui, &session) || !bui)
        {
            Say("No such tool: " + name);
            return;
        }
        if (Allowed(name))
        {
            Out(Assistant(Json::Array().Push(Json::Object()
                    .Set("type", "tool_use")
                    .Set("id", toolId)
                    .Set("name", name)
                    .Set("input", input))));
        }
        else
        {
            Json decision;
            if (!AskToUse(toolId, name, input, decision))
            {
                return;
            }
            if (decision["behavior"].AsString() != "allow")
            {
                Out(ToolResult(toolId, decision["message"].AsString(), true));
                Say("Denied");
                return;
            }
        }
        Json request = Json::Object().Set("tool", tool).Set("arguments", input);
        if (!session.empty())
        {
            request.Set("session", session);
        }
        std::string reply;
        std::string error;
        if (!gitgud::agent::CallToolPipe(pipe, request.Dump(), 30000, reply, error))
        {
            Out(ToolResult(toolId, error, true));
            Say("Refused: " + error);
            return;
        }
        const Json answer = Json::Parse(reply).value_or(Json());
        const bool berror = answer["isError"].AsBool(true);
        const std::string text = answer["text"].AsString();
        Out(ToolResult(toolId, Json::Array().Push(TextBlock(text)), berror));
        Say(berror ? "Refused: " + text : text);
    }

    // "settings get [<setting>]" or "settings set <setting> <value>".
    void SettingsTool(const std::string& _Text)
    {
        std::istringstream words(_Text);
        std::string word;
        std::string verb;
        std::string setting;
        words >> word >> verb >> setting;
        std::string value;
        std::getline(words, value);
        value.erase(0, value.find_first_not_of(' '));
        Json input = Json::Object();
        if (!setting.empty())
        {
            input.Set("setting", setting);
        }
        if (verb == "set")
        {
            char* pend = nullptr;
            const double fnumber = std::strtod(value.c_str(), &pend);
            if (value == "true" || value == "false")
            {
                input.Set("value", value == "true");
            }
            else if (!value.empty() && pend && *pend == '\0')
            {
                input.Set("value", fnumber);
            }
            else
            {
                input.Set("value", value);
            }
        }
        const std::string tool = "bragi_settings_" + verb;
        const std::string toolId = "toolu_s" + std::to_string(++g_iRequests);
        std::string pipe;
        std::string session;
        bool bsettings = false;
        if (!AppServer(pipe, bsettings, &session) || !bsettings)
        {
            // Claude Code has no such tool: the model never gets to call it.
            Say("No such tool: mcp__repo__" + tool);
            return;
        }
        Json decision = Json::Object().Set("behavior", "allow").Set("updatedInput", input);
        if (Allowed("mcp__repo__" + tool))
        {
            // On the allow list: called without asking.
            Out(Assistant(Json::Array().Push(Json::Object()
                    .Set("type", "tool_use")
                    .Set("id", toolId)
                    .Set("name", "mcp__repo__" + tool)
                    .Set("input", input))));
        }
        else if (!AskToUse(toolId, "mcp__repo__" + tool, input, decision))
        {
            return;
        }
        if (decision["behavior"].AsString() != "allow")
        {
            Out(ToolResult(toolId, decision["message"].AsString(), true));
            Say("Denied");
            return;
        }
        std::string reply;
        std::string error;
        Json message = Json::Object().Set("tool", tool).Set("arguments",
            decision["updatedInput"].IsObject() ? decision["updatedInput"] : input);
        if (!session.empty())
        {
            message.Set("session", session); // as gitgud-mcp --session does
        }
        const std::string request = message.Dump();
        if (!gitgud::agent::CallToolPipe(pipe, request, 30000, reply, error))
        {
            Out(ToolResult(toolId, error, true));
            Say("Refused: " + error);
            return;
        }
        const Json answer = Json::Parse(reply).value_or(Json());
        const bool berror = answer["isError"].AsBool(true);
        const std::string text = answer["text"].AsString();
        Out(ToolResult(toolId, Json::Array().Push(TextBlock(text)), berror));
        Say(berror ? "Refused: " + text : text);
    }

    // A tool call of the main agent.
    void ToolCall(const std::string& _Id, const std::string& _Name, Json _Input)
    {
        Out(Assistant(Json::Array().Push(
            Json::Object().Set("type", "tool_use").Set("id", _Id).Set("name", _Name).Set("input", std::move(_Input)))));
    }

    void TaskStarted(const std::string& _TaskId, const std::string& _ToolUseId, const std::string& _Description,
        const std::string& _Type, bool _bBackground)
    {
        Out(System("task_started")
                .Set("task_id", _TaskId)
                .Set("tool_use_id", _ToolUseId)
                .Set("description", _Description)
                .Set("task_type", _Type)
                .Set("is_backgrounded", _bBackground));
        if (_bBackground)
        {
            g_Background.push_back({_TaskId, _ToolUseId});
        }
    }

    // "helper asks": the open permission request of a background helper
    // (agent_h1), answered after the turn that started it ended.
    std::string g_HelperRequest;

    // Ask for the helper agent_h1, as Claude Code does for a sub-agent:
    // the request names the agent and why it asks. Returns its id.
    std::string HelperAsks(const std::string& _ToolUseId, const Json& _Input)
    {
        Out(Assistant(Json::Array().Push(Json::Object()
                                             .Set("type", "tool_use")
                                             .Set("id", _ToolUseId)
                                             .Set("name", "Bash")
                                             .Set("input", _Input)),
            "toolu_h1"));
        const std::string id = "perm-" + std::to_string(++g_iRequests);
        Out(Json::Object()
                .Set("type", "control_request")
                .Set("request_id", id)
                .Set("request", Json::Object()
                                    .Set("subtype", "can_use_tool")
                                    .Set("tool_name", "Bash")
                                    .Set("input", _Input)
                                    .Set("permission_suggestions", Json::Array())
                                    .Set("decision_reason", "It writes a file outside the project")
                                    .Set("tool_use_id", _ToolUseId)
                                    .Set("agent_id", "agent_h1")));
        return id;
    }

    // The helper's request answered: its command's result, and it ends.
    void HelperAnswered(const Json& _Response)
    {
        g_HelperRequest.clear();
        const Json& decision = _Response["response"];
        const bool ballow = decision["behavior"].AsString() == "allow";
        Json result = ToolResult("toolu_h2", ballow ? Json(std::string("diff saved")) : decision["message"], !ballow);
        result.Set("parent_tool_use_id", "toolu_h1");
        Out(result);
        g_Background.erase(std::remove_if(g_Background.begin(), g_Background.end(),
                               [](const auto& _Task) { return _Task.first == "agent_h1"; }),
            g_Background.end());
        TaskEnded("agent_h1", "toolu_h1", "completed");
    }

    // "suites <n> <ms>": a turn that ends with n background test runs
    // going ("Suite 1" ..., tasks bash_s1 ...). Every <ms> one ends
    // (task_notification) and gets a short turn of its own with nobody
    // sending a message, as Claude Code answers a background task's
    // report: "suite-<i> passes, <10 i> of <10 i>."; the last one's ends
    // "All <n> suites pass."
    void Suites(const std::string& _Text)
    {
        int icount = 0;
        int ims = 0;
        std::istringstream(_Text.substr(7)) >> icount >> ims;
        for (int i = 1; i <= icount; ++i)
        {
            const std::string n = std::to_string(i);
            ToolCall("toolu_s" + n, "Bash",
                Json::Object()
                    .Set("command", "run suite " + n)
                    .Set("description", "Suite " + n)
                    .Set("run_in_background", true));
            Out(ToolResult("toolu_s" + n, "Command running in background with ID: bash_s" + n, false));
            TaskStarted("bash_s" + n, "toolu_s" + n, "Suite " + n, "local_bash", true);
        }
        Say("Running the suites.");
        for (int i = 1; i <= icount; ++i)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(ims));
            const std::string n = std::to_string(i);
            const std::string checks = std::to_string(10 * i);
            g_Background.erase(std::remove_if(g_Background.begin(), g_Background.end(),
                                   [&n](const auto& _Task) { return _Task.first == "bash_s" + n; }),
                g_Background.end());
            TaskEnded("bash_s" + n, "toolu_s" + n, "completed");
            Say("suite-" + n + " passes, " + checks + " of " + checks + "." +
                (i == icount ? " All " + std::to_string(icount) + " suites pass." : ""));
        }
    }

    // Add `_Text` to the end of a file (made, with its folders, if needed).
    void Append(const std::filesystem::path& _Path, const std::string& _Text)
    {
        std::error_code ec;
        std::filesystem::create_directories(_Path.parent_path(), ec);
        std::ofstream out(_Path, std::ios::binary | std::ios::app);
        out << _Text;
    }

    // The session panel's scenario ("panel" in the header).
    void Panel()
    {
        const std::filesystem::path cwd = std::filesystem::current_path();
        const Json usage = Json::Object()
                               .Set("input_tokens", 1200)
                               .Set("cache_creation_input_tokens", 3000)
                               .Set("cache_read_input_tokens", 40000)
                               .Set("output_tokens", 800);
        Json message = Json::Object()
                           .Set("id", "msg_p1")
                           .Set("role", "assistant")
                           .Set("model", "claude-opus-5-5")
                           .Set("content", Json::Array().Push(TextBlock("Working on it.")))
                           .Set("usage", usage);
        Out(Json::Object()
                .Set("type", "assistant")
                .Set("message", std::move(message))
                .Set("parent_tool_use_id", Json())
                .Set("session_id", g_SessionId));

        const std::filesystem::path plan = cwd / "notes" / "plan.md";
        ToolCall("toolu_p1", "Write",
            Json::Object().Set("file_path", plan.generic_u8string()).Set("content", "one\ntwo\nthree\n"));
        std::error_code ec;
        std::filesystem::remove(plan, ec);
        Append(plan, "one\ntwo\nthree\n");
        Out(ToolResult("toolu_p1", "File created", false));

        const std::filesystem::path readme = cwd / "README.md";
        ToolCall("toolu_p2", "Edit",
            Json::Object()
                .Set("file_path", readme.generic_u8string())
                .Set("old_string", "")
                .Set("new_string", "panel line\n"));
        Append(readme, "panel line\n");
        Out(ToolResult("toolu_p2", "The file has been updated", false));

        const std::filesystem::path outside = cwd.parent_path() / "panel-outside.txt";
        ToolCall("toolu_p6", "Write",
            Json::Object().Set("file_path", outside.generic_u8string()).Set("content", "outside\n"));
        Append(outside, "outside\n");
        Out(ToolResult("toolu_p6", "File created", false));

        // A sub-agent that runs to the end within the turn.
        ToolCall("toolu_p3", "Agent",
            Json::Object()
                .Set("description", "Survey the parser")
                .Set("prompt", "Look at the parser.")
                .Set("subagent_type", "general-purpose"));
        TaskStarted("task_a1", "toolu_p3", "Survey the parser", "local_agent", false);
        Out(Assistant(Json::Array().Push(TextBlock("The parser is fine.")), "toolu_p3"));
        TaskEnded("task_a1", "toolu_p3", "completed");
        Out(ToolResult("toolu_p3", "The parser is fine.", false));

        // Background work that outlives the turn.
        ToolCall("toolu_p4", "Bash",
            Json::Object()
                .Set("command", "npm run watch")
                .Set("description", "Watch the build")
                .Set("run_in_background", true));
        Out(ToolResult("toolu_p4", "Command running in background with ID: bash_1", false));
        TaskStarted("bash_1", "toolu_p4", "Watch the build", "local_bash", true);
        ToolCall("toolu_p5", "Agent",
            Json::Object()
                .Set("description", "Review the long log in the background")
                .Set("prompt", "Read the log.")
                .Set("run_in_background", true));
        TaskStarted("task_a2", "toolu_p5", "Review the long log in the background", "local_agent", true);
        Out(ToolResult("toolu_p5", "Async agent launched successfully.", false));

        Out(Assistant(Json::Array().Push(TextBlock("Made the plan."))));
        Out(Json::Object()
                .Set("type", "result")
                .Set("subtype", "success")
                .Set("is_error", false)
                .Set("result", "Made the plan.")
                .Set("session_id", g_SessionId)
                .Set("total_cost_usd", 0.5)
                .Set("num_turns", 6)
                .Set("duration_ms", 2400)
                .Set("usage", usage)
                .Set("modelUsage", Json::Object().Set("claude-opus-5-5",
                                       Json::Object().Set("contextWindow", 200000).Set("maxOutputTokens", 32000))));
    }

    // Claude Code's own commands the fake runs as it does headless.
    std::string LocalCommandName(const std::string& _Text)
    {
        if (_Text.empty() || _Text[0] != '/')
        {
            return {};
        }
        const std::string name = _Text.substr(1, _Text.find(' ') - 1); // npos - 1: to the end
        return name == "context" || name == "compact" ? name : std::string();
    }

    // The last command output sent: compaction keeps it and sends it again.
    std::string g_KeptText;
    std::string g_KeptUuid;
    int g_nSynthetic = 0;

    // A command's output as Claude Code sends it: an assistant message from
    // model "<synthetic>" with no tokens.
    Json Synthetic(const std::string& _Text, const std::string& _Uuid)
    {
        ++g_nSynthetic;
        return Json::Object()
            .Set("type", "assistant")
            .Set("message", Json::Object()
                                .Set("id", "synthetic-" + std::to_string(g_nSynthetic))
                                .Set("model", "<synthetic>")
                                .Set("role", "assistant")
                                .Set("content", Json::Array().Push(TextBlock(_Text)))
                                .Set("usage", Json::Object()
                                                  .Set("input_tokens", 0)
                                                  .Set("cache_creation_input_tokens", 0)
                                                  .Set("cache_read_input_tokens", 0)
                                                  .Set("output_tokens", 0)))
            .Set("parent_tool_use_id", nullptr)
            .Set("session_id", g_SessionId)
            .Set("uuid", _Uuid);
    }

    // /context and /compact [instructions], printed and saved the way
    // Claude Code 2.1 does (seen from the real one, 2026-10-17).
    void LocalCommand(const std::string& _Name, const std::string& _Text)
    {
        const std::size_t nspace = _Text.find(' ');
        const std::string args = nspace == std::string::npos ? "" : _Text.substr(nspace + 1);
        const auto recordCommand = [&]
        {
            RecordLine(Json::Object().Set("type", "user").Set("message",
                Json::Object().Set("role", "user").Set("content",
                    "<command-name>/" + _Name + "</command-name>\n            <command-message>" + _Name +
                        "</command-message>\n            <command-args>" + args + "</command-args>")));
        };
        const auto result = [&](const std::string& _Result)
        {
            Print(Json::Object()
                    .Set("type", "result")
                    .Set("subtype", "success")
                    .Set("is_error", false)
                    .Set("result", _Result)
                    .Set("session_id", g_SessionId)
                    .Set("total_cost_usd", 0.25)
                    .Set("num_turns", 0)
                    .Set("duration_ms", 5)
                    .Set("local_command", _Name));
        };
        auto systemLine = [](const char* _szSubtype)
        {
            return Json::Object().Set("type", "system").Set("subtype", _szSubtype).Set("session_id", g_SessionId);
        };
        if (_Name == "context")
        {
            recordCommand();
            g_KeptText = "## Context Usage\n\n**Tokens:** 45k / 200k (22%)";
            g_KeptUuid = "fake-output-" + std::to_string(g_nSynthetic + 1);
            Print(Synthetic(g_KeptText, g_KeptUuid));
            RecordLine(Json::Object()
                    .Set("type", "system")
                    .Set("subtype", "local_command")
                    .Set("content", "<local-command-stdout>" + g_KeptText + "</local-command-stdout>")
                    .Set("level", "info"));
            result(g_KeptText);
            return;
        }
        const std::string summary = "This session is being continued from a previous conversation that ran "
                                    "out of context. The summary below covers the earlier portion of the "
                                    "conversation.";
        Print(systemLine("status").Set("status", "compacting"));
        Print(systemLine("status").Set("status", nullptr).Set("compact_result", "success"));
        Print(systemLine("compact_boundary").Set("compact_metadata", Json::Object()
                    .Set("trigger", "manual")
                    .Set("pre_tokens", 45000)
                    .Set("post_tokens", 5000)));
        Print(Json::Object()
                .Set("type", "user")
                .Set("message", Json::Object().Set("role", "user").Set("content", summary))
                .Set("session_id", g_SessionId)
                .Set("parent_tool_use_id", nullptr)
                .Set("isSynthetic", true));
        if (!g_KeptUuid.empty())
        {
            Print(Synthetic(g_KeptText, g_KeptUuid)); // kept, so sent again
        }
        Print(Json::Object()
                .Set("type", "user")
                .Set("message", Json::Object().Set("role", "user").Set(
                    "content", "<local-command-stdout>Compacted </local-command-stdout>"))
                .Set("session_id", g_SessionId)
                .Set("parent_tool_use_id", nullptr)
                .Set("isReplay", true));
        RecordLine(Json::Object()
                .Set("type", "system")
                .Set("subtype", "compact_boundary")
                .Set("content", "Conversation compacted")
                .Set("compactMetadata", Json::Object()
                        .Set("trigger", "manual")
                        .Set("preTokens", 45000)
                        .Set("postTokens", 5000)));
        RecordLine(Json::Object()
                .Set("type", "user")
                .Set("isCompactSummary", true)
                .Set("isVisibleInTranscriptOnly", true)
                .Set("message", Json::Object().Set("role", "user").Set("content", summary)));
        recordCommand();
        RecordLine(Json::Object().Set("type", "user").Set("message", Json::Object().Set("role", "user").Set(
            "content", "<local-command-stdout>Compacted </local-command-stdout>")));
        result("");
    }

    // The usage limits' scenario ("limits" in the header).
    void Limits(const std::string& _Text)
    {
        std::istringstream in(_Text.substr(6));
        std::string five, week;
        in >> five >> week;
        const long long inow = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        const long long ifiveResets = inow + 2 * 3600 + 15 * 60;
        const long long iweekResets = inow + 3 * 86400 + 4 * 3600;
        Json windows = Json::Object();
        Json info = Json::Object().Set("status", "allowed");
        if (!five.empty() && five != "-")
        {
            const double share = std::atof(five.c_str()) / 100.0;
            windows.Set("five_hour", Json::Object().Set("utilization", share).Set("resetsAt", ifiveResets));
            info.Set("rateLimitType", "five_hour").Set("utilization", share).Set("resetsAt", ifiveResets);
        }
        if (!week.empty() && week != "-")
        {
            windows.Set("seven_day", Json::Object()
                    .Set("utilization", std::atof(week.c_str()) / 100.0)
                    .Set("resetsAt", iweekResets));
        }
        if (windows.Size() > 0)
        {
            info.Set("unifiedWindows", std::move(windows));
        }
        Out(Json::Object()
                .Set("type", "rate_limit_event")
                .Set("rate_limit_info", std::move(info))
                .Set("uuid", "rl-" + std::to_string(++g_iRequests))
                .Set("session_id", g_SessionId));
        Say("Limits.");
    }

    // Steps TaskCreate made so far (their ids count from 1).
    int g_iTasks = 0;

    // "plan <json>": the agent's plan tools, called in turn.
    void PlanCalls(const std::string& _Text)
    {
        const Json calls = Json::Parse(_Text.substr(5)).value_or(Json::Array());
        for (std::size_t i = 0; i < calls.Size(); ++i)
        {
            const std::string name = calls[i]["name"].AsString();
            const Json input = calls[i]["input"];
            const std::string id = "toolu_plan_" + NewUuid();
            ToolCall(id, name, input);
            std::string result = "Todos have been modified successfully.";
            if (name == "TaskCreate")
            {
                result = "Task #" + std::to_string(++g_iTasks) + " created successfully: " + input["subject"].AsString();
            }
            else if (name == "TaskUpdate")
            {
                result = "Updated task #" + input["taskId"].AsString() + " status";
            }
            Out(ToolResult(id, Json::Array().Push(TextBlock(result)), false));
        }
        Say("Planned.");
    }

    void Turn(const std::string& _Text)
    {
        if (const std::string name = LocalCommandName(_Text); !name.empty())
        {
            LocalCommand(name, _Text);
            return;
        }
        if (_Text.rfind("settings ", 0) == 0)
        {
            SettingsTool(_Text);
            return;
        }
        if (_Text.rfind("call ", 0) == 0)
        {
            CallTool(_Text);
            return;
        }
        if (_Text.rfind("plan ", 0) == 0)
        {
            PlanCalls(_Text);
            return;
        }
        if (_Text == "picture")
        {
            Out(Assistant(Json::Array().Push(Json::Object()
                    .Set("type", "tool_use")
                    .Set("id", "toolu_p1")
                    .Set("name", "Read")
                    .Set("input", Json::Object().Set("file_path", "shot.png")))));
            Out(ToolResult("toolu_p1",
                Json::Array().Push(Json::Object()
                        .Set("type", "image")
                        .Set("source", Json::Object()
                                .Set("type", "base64")
                                .Set("media_type", "image/png")
                                .Set("data", kPicture))),
                false));
            Say("Here is the screenshot.");
            return;
        }
        if (_Text == "links")
        {
            const std::filesystem::path cwd = std::filesystem::current_path();
            ToolCall("toolu_l1", "Read", Json::Object().Set("file_path", (cwd / "README.md").generic_u8string()));
            Out(ToolResult("toolu_l1", "1\t# Test project", false));
            Say("See [Mem0](https://github.com/mem0ai/mem0) and https://example.com/docs/page.\n\n"
                "The folder is " + cwd.u8string() + "\n\n"
                "The file is " + (cwd / "README.md").u8string() + ".\n\n"
                "In backticks: `README.md`. Not there: " + (cwd / "missing.txt").u8string());
            return;
        }
        if (_Text == "hello")
        {
            Out(Json::Object()
                    .Set("type", "stream_event")
                    .Set("event", Json::Object()
                                      .Set("type", "content_block_start")
                                      .Set("index", 0)
                                      .Set("content_block",
                                          Json::Object().Set("type", "text").Set("text", "")))
                    .Set("parent_tool_use_id", nullptr));
            Out(Delta("Hel"));
            Out(Delta("lo"));
            Say("Hello");
        }
        else if (_Text == "helper asks")
        {
            // A background helper asks to run a command while the agent
            // goes on and ends its turn; the request stays open after it.
            ToolCall("toolu_h1", "Agent",
                Json::Object()
                    .Set("description", "Empty Thinking blocks")
                    .Set("prompt", "Find out why.")
                    .Set("run_in_background", true));
            TaskStarted("agent_h1", "toolu_h1", "Empty Thinking blocks", "local_agent", true);
            Out(ToolResult("toolu_h1", "Async agent launched successfully.", false));
            g_HelperRequest = HelperAsks("toolu_h2",
                Json::Object()
                    .Set("command", "cd ../other && git diff > ../stash.patch")
                    .Set("description", "Save the diff"));
            ToolCall("toolu_h3", "Bash", Json::Object().Set("command", "sleep 10").Set("description", "Wait"));
            Out(ToolResult("toolu_h3", "", false));
            Say("Waiting on the helper.");
        }
        else if (_Text == "helper withdraws")
        {
            // The helper asks again, then Claude Code takes it back (as when
            // the helper is stopped).
            const std::string id = HelperAsks("toolu_h4",
                Json::Object().Set("command", "git -C ../other log").Set("description", "Recent commits"));
            Out(Json::Object().Set("type", "control_cancel_request").Set("request_id", id));
            Say("Withdrawn.");
        }
        else if (_Text == "tool")
        {
            const Json input =
                Json::Object().Set("command", "echo hi").Set("description", "Say hi");
            Json decision;
            if (!AskToUse("toolu_1", "Bash", input, decision))
            {
                return;
            }
            if (decision["behavior"].AsString() == "allow")
            {
                Out(ToolResult("toolu_1",
                    Json::Array().Push(
                        TextBlock("ran " + decision["updatedInput"]["command"].AsString())),
                    false));
                Say("Done");
            }
            else
            {
                Out(ToolResult("toolu_1", decision["message"].AsString(), true));
                Say("Denied");
            }
        }
        else if (_Text == "tools")
        {
            // Two tools that ask at once; the answers can come in any order.
            const Json first = Json::Object().Set("command", "git log").Set("description", "Recent commits");
            const Json second = Json::Object().Set("file_path", "src/voice.lua");
            std::vector<std::string> ids;
            int i = 0;
            for (const auto& [tool, input] : {std::pair<std::string, Json>{"Bash", first}, {"Edit", second}})
            {
                const std::string toolId = "toolu_t" + std::to_string(++i);
                Out(Assistant(Json::Array().Push(
                    Json::Object().Set("type", "tool_use").Set("id", toolId).Set("name", tool).Set("input", input))));
                ids.push_back("perm-" + std::to_string(++g_iRequests));
                Out(Json::Object()
                        .Set("type", "control_request")
                        .Set("request_id", ids.back())
                        .Set("request", Json::Object()
                                            .Set("subtype", "can_use_tool")
                                            .Set("tool_name", tool)
                                            .Set("input", input)
                                            .Set("permission_suggestions", Json::Array())
                                            .Set("tool_use_id", toolId)));
            }
            std::string answers[2];
            Json message;
            while ((answers[0].empty() || answers[1].empty()) && ReadMessage(message))
            {
                const std::string type = message["type"].AsString();
                if (type == "control_request")
                {
                    Reply(message);
                    continue;
                }
                for (int j = 0; j < 2; ++j)
                {
                    if (type == "control_response" && message["response"]["request_id"].AsString() == ids[j])
                    {
                        answers[j] = message["response"]["response"]["behavior"].AsString();
                    }
                }
            }
            Say("Bash " + answers[0] + ", Edit " + answers[1]);
        }
        else if (_Text.rfind("long", 0) == 0)
        {
            // A long Markdown reply streamed in small pieces, as a real long
            // answer comes (for tests/ui/perf-bragi.lua).
            int iparagraphs = 40;
            int idelayMs = 15;
            std::sscanf(_Text.c_str(), "long %d %d", &iparagraphs, &idelayMs);
            std::string whole;
            const char* aszWords[] = {"the", "profiler", "shows", "where", "time", "goes", "in", "each", "frame,",
                "and", "`ClaudeTranscripts::Read`", "reads", "docs/BUILDING.md", "while", "**layout**",
                "runs", "again."};
            for (int ip = 0; ip < iparagraphs; ++ip)
            {
                std::string paragraph = ip % 7 == 3   ? "## Section " + std::to_string(ip) + "\n\n"
                                        : ip % 7 == 5 ? "```cpp\nint main() { return " + std::to_string(ip) + "; }\n```\n\n"
                                                      : "";
                if (ip % 7 == 6)
                {
                    paragraph += "- first item\n- second item with `code`\n- third item\n\n";
                }
                for (int iw = 0; iw < 60; ++iw)
                {
                    paragraph += aszWords[(ip * 7 + iw) % (sizeof(aszWords) / sizeof(aszWords[0]))];
                    paragraph += ' ';
                }
                paragraph += "\n\n";
                for (std::size_t i = 0; i < paragraph.size(); i += 24)
                {
                    Out(Delta(paragraph.substr(i, 24)));
                    std::this_thread::sleep_for(std::chrono::milliseconds(idelayMs));
                }
                whole += paragraph;
            }
            Out(Assistant(Json::Array().Push(TextBlock(whole))));
            Result(whole);
        }
        else if (_Text == "work" || _Text == "work quietly" || _Text == "slow" || _Text.rfind("work on ", 0) == 0)
        {
            const std::string topic = _Text.rfind("work on ", 0) == 0 ? _Text.substr(8) : "";
            auto stream = [](const Json& _Event)
            {
                Out(Json::Object()
                        .Set("type", "stream_event")
                        .Set("event", _Event)
                        .Set("parent_tool_use_id", nullptr));
            };
            auto block = [&](const Json& _Block)
            {
                stream(Json::Object().Set("type", "content_block_start").Set("index", 0).Set(
                    "content_block", _Block));
            };
            // The real one streams its thinking empty: no text to narrate.
            block(Json::Object().Set("type", "thinking").Set("thinking", ""));
            stream(Json::Object()
                    .Set("type", "content_block_delta")
                    .Set("index", 0)
                    .Set("delta", Json::Object().Set("type", "thinking_delta").Set("thinking", "")));
            if (_Text == "slow")
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(10000));
                block(Json::Object().Set("type", "text").Set("text", ""));
                Out(Delta("Took a while. "));
                Out(Delta("Here it is."));
                Say("Took a while. Here it is.");
                return;
            }
            // A tool's block opens as it starts; its whole message follows.
            auto tool = [&](const std::string& _Id, const std::string& _Name, Json _Input)
            {
                block(Json::Object().Set("type", "tool_use").Set("id", _Id).Set("name", _Name).Set(
                    "input", Json::Object()));
                std::this_thread::sleep_for(std::chrono::milliseconds(300));
                Out(Assistant(Json::Array().Push(Json::Object()
                        .Set("type", "tool_use")
                        .Set("id", _Id)
                        .Set("name", _Name)
                        .Set("input", std::move(_Input)))));
            };
            tool("toolu_w1", "Read", Json::Object().Set("file_path", "src/" + (topic.empty() ? "parser" : topic) + ".lua"));
            std::this_thread::sleep_for(std::chrono::milliseconds(1500));
            Out(ToolResult("toolu_w1", "local parser = {}", false));
            tool("toolu_w2", "Grep", Json::Object().Set("pattern", topic.empty() ? "parse" : "callers of " + topic + " in the module tests"));
            std::this_thread::sleep_for(std::chrono::milliseconds(5000));
            Out(ToolResult("toolu_w2", "src/parser.lua:1", false));
            Say("Worked through it.");
        }
        else if (_Text == "think")
        {
            auto stream = [](const Json& _Event)
            {
                Out(Json::Object()
                        .Set("type", "stream_event")
                        .Set("event", _Event)
                        .Set("parent_tool_use_id", nullptr));
            };
            auto block = [&](const Json& _Block)
            {
                stream(Json::Object().Set("type", "content_block_start").Set("index", 0).Set(
                    "content_block", _Block));
            };
            auto delta = [&](const Json& _Delta)
            {
                stream(Json::Object().Set("type", "content_block_delta").Set("index", 0).Set("delta", _Delta));
            };
            auto thought = [&](const std::string& _Text)
            {
                delta(Json::Object().Set("type", "thinking_delta").Set("thinking", _Text));
            };
            // An empty block, one with only a signature, a redacted one.
            block(Json::Object().Set("type", "thinking").Set("thinking", ""));
            thought("");
            block(Json::Object().Set("type", "thinking").Set("thinking", ""));
            delta(Json::Object().Set("type", "signature_delta").Set("signature", "c2lnbmF0dXJl"));
            block(Json::Object().Set("type", "redacted_thinking").Set("data", "cmVkYWN0ZWQ="));
            // One that has no words for 2 s, then some.
            block(Json::Object().Set("type", "thinking").Set("thinking", ""));
            thought(" ");
            std::this_thread::sleep_for(std::chrono::milliseconds(2000));
            thought("Weighing the parser.");
            thought(" Then the tests.");
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
            block(Json::Object().Set("type", "text").Set("text", ""));
            Out(Delta("Thought it through."));
            Say("Thought it through.");
        }
        else if (_Text == "told long" || _Text == "told story")
        {
            Out(Json::Object()
                    .Set("type", "stream_event")
                    .Set("event", Json::Object()
                                      .Set("type", "content_block_start")
                                      .Set("index", 0)
                                      .Set("content_block", Json::Object().Set("type", "text").Set("text", "")))
                    .Set("parent_tool_use_id", nullptr));
            const bool bstory = _Text == "told story";
            std::string whole;
            for (int ipart = 1; ipart <= 4; ++ipart)
            {
                const std::string n = std::to_string(ipart);
                std::string paragraph = bstory ? "Once upon a time, part " + n + "." : "Part " + n + " begins here.";
                for (int k = 1; k <= 12; ++k)
                {
                    paragraph += " This is sentence " + std::to_string(k) + " of part " + n + ".";
                }
                if (ipart == 4)
                {
                    paragraph += " Should I go on?";
                }
                const std::string piece = (ipart > 1 ? "\n\n" : "") + paragraph;
                // Each paragraph in four pieces, 250 ms apart.
                const std::size_t nquarter = piece.size() / 4;
                for (int iq = 0; iq < 4; ++iq)
                {
                    Out(Delta(piece.substr(iq * nquarter, iq == 3 ? std::string::npos : nquarter)));
                    std::this_thread::sleep_for(std::chrono::milliseconds(250));
                }
                whole += piece;
            }
            Say(whole);
        }
        else if (_Text == "late")
        {
            // A result that ran no turn, as Claude Code 2.1 sends for a
            // notification it only writes to the transcript; then the
            // message's own answer.
            Print(Json::Object()
                    .Set("type", "result")
                    .Set("subtype", "success")
                    .Set("is_error", false)
                    .Set("result", "")
                    .Set("session_id", g_SessionId)
                    .Set("total_cost_usd", 0)
                    .Set("num_turns", 0)
                    .Set("duration_ms", 0));
            std::this_thread::sleep_for(std::chrono::milliseconds(2500));
            Out(Json::Object()
                    .Set("type", "stream_event")
                    .Set("event", Json::Object()
                                      .Set("type", "content_block_start")
                                      .Set("index", 0)
                                      .Set("content_block", Json::Object().Set("type", "text").Set("text", "")))
                    .Set("parent_tool_use_id", nullptr));
            Out(Delta("Merged, and "));
            Out(Delta("the tests pass."));
            Say("Merged, and the tests pass.");
        }
        else if (_Text == "wait")
        {
            Out(Assistant(Json::Array().Push(Json::Object()
                    .Set("type", "tool_use")
                    .Set("id", "toolu_2")
                    .Set("name", "Bash")
                    .Set("input", Json::Object().Set("command", "sleep 1000")))));
            Json message;
            while (ReadMessage(message))
            {
                if (message["type"].AsString() != "control_request")
                {
                    continue;
                }
                Reply(message);
                if (message["request"]["subtype"].AsString() == "interrupt")
                {
                    Result("", "error_during_execution");
                    return;
                }
            }
        }
        else if (_Text == "args")
        {
            std::string text;
            for (const std::string& arg : g_Args)
            {
                text += arg + "\n";
            }
            Say(text);
        }
        else if (_Text == "env")
        {
            const char* szvalue = std::getenv("CLAUDECODE");
            Say(szvalue ? szvalue : "<unset>");
        }
        else if (_Text == "skills")
        {
            const char* szvalue = std::getenv("CLAUDE_CODE_SYNC_SKILLS");
            Say(szvalue ? szvalue : "<unset>");
        }
        else if (_Text == "warn")
        {
            std::cerr << "a warning" << std::endl;
            Say("warned");
        }
        else if (_Text == "ask")
        {
            Out(Json::Object()
                    .Set("type", "control_request")
                    .Set("request_id", "mystery-1")
                    .Set("request", Json::Object().Set("subtype", "mystery")));
            Json answer;
            if (AwaitAnswer("mystery-1", answer))
            {
                Say(answer.Dump());
            }
        }
        else if (_Text == "choose" || _Text == "choose two")
        {
            auto option = [](const char* _szLabel, const char* _szDescription)
            { return Json::Object().Set("label", _szLabel).Set("description", _szDescription); };
            Json questions = Json::Array().Push(Json::Object()
                    .Set("question", "Which colour do you prefer?")
                    .Set("header", "Colour")
                    .Set("options", Json::Array()
                                        .Push(option("Red", "Warm and bold."))
                                        .Push(option("Blue", "Calm and cool.")))
                    .Set("multiSelect", false));
            if (_Text == "choose two")
            {
                questions.Push(Json::Object()
                        .Set("question", "Which sections should the README have?")
                        .Set("header", "Sections")
                        .Set("options", Json::Array()
                                            .Push(option("Install", "How to set it up."))
                                            .Push(option("Usage", "How to use it."))
                                            .Push(option("License", "The terms.")))
                        .Set("multiSelect", true));
            }
            Json decision;
            if (!AskToUse("toolu_c1", "AskUserQuestion", Json::Object().Set("questions", questions),
                    decision))
            {
                return;
            }
            if (decision["behavior"].AsString() != "allow")
            {
                Out(ToolResult("toolu_c1", decision["message"].AsString(), true));
                Say("No answer: " + decision["message"].AsString());
                return;
            }
            // The tool's result, worded as the real one words it.
            const Json& answers = decision["updatedInput"]["answers"];
            std::string pairs;
            std::string chosen;
            for (const Json& question : questions.Items())
            {
                const std::string asked = question["question"].AsString();
                const std::string answer = answers[asked].AsString();
                pairs += (pairs.empty() ? "" : ", ") + Json(asked).Dump() + "=" + Json(answer).Dump();
                chosen += (chosen.empty() ? "" : "; ") + answer;
            }
            Out(ToolResult("toolu_c1",
                "Your questions have been answered: " + pairs +
                    ". You can now continue with these answers in mind.",
                false));
            Say("You chose: " + chosen);
        }
        else if (_Text == "crash")
        {
            std::exit(3);
        }
        else if (_Text == "panel")
        {
            Panel();
        }
        else if (_Text.rfind("limits", 0) == 0)
        {
            Limits(_Text);
        }
        else if (_Text.rfind("tasks ", 0) == 0)
        {
            const int icount = std::atoi(_Text.c_str() + 6);
            for (int i = 1; i <= icount; ++i)
            {
                const std::string n = std::to_string(i);
                ToolCall("toolu_j" + n, "Bash",
                    Json::Object()
                        .Set("command", "job " + n)
                        .Set("description", "Background job " + n)
                        .Set("run_in_background", true));
                Out(ToolResult("toolu_j" + n, "Command running in background with ID: bash_j" + n, false));
                TaskStarted("bash_j" + n, "toolu_j" + n, "Background job " + n, "local_bash", true);
            }
            Say("Started " + std::to_string(icount) + " jobs.");
        }
        else if (_Text.rfind("suites ", 0) == 0)
        {
            Suites(_Text);
        }
        else if (_Text == "finish")
        {
            for (const auto& task : g_Background)
            {
                TaskEnded(task.first, task.second, "completed");
            }
            g_Background.clear();
            Say("All done.");
        }
        else if (auto request = Json::Parse(_Text); request && request->Has("recent"))
        {
            Say(Json::Object()
                    .Set("route", RouteOf((*request)["message"].AsString()))
                    .Set("command", CommandOf((*request)["message"].AsString()))
                    .Set("why", IsSettings((*request)["message"].AsString()) ? "Bragi's settings" : "fake")
                    .Dump());
        }
        else if (request && request->Has("conversations"))
        {
            Say(Recap(*request));
        }
        else if (request && request->Has("news"))
        {
            // The news (prompts/recap.md): each conversation's title, what
            // happened, and its last reply.
            const Json& news = (*request)["news"];
            std::string out;
            for (std::size_t i = 0; i < news.Size(); ++i)
            {
                const Json& c = news[i]["conversation"];
                const std::string reply = c["reply"].AsString();
                out += (out.empty() ? "" : "; ") + c["title"].AsString() + " " + news[i]["what"].AsString() +
                       (reply.empty() ? "" : ": " + reply);
            }
            Say("Update: " + out);
        }
        else if (request && request->Has("options"))
        {
            Say(Choice(*request).Dump());
        }
        else if (request && request->Has("question"))
        {
            QuickAnswer(*request);
        }
        else if (request && request->Has("message"))
        {
            Say(HeardText(*request).Dump());
        }
        else if (request && request->Has("reply"))
        {
            const std::string reply = (*request)["reply"].AsString();
            const bool bstrict = (*request)["strict"].AsBool();
            if (request->Has("part"))
            {
                const std::string part = (*request)["part"].AsString();
                const std::size_t idot = reply.find('.');
                std::string said = "Part " + part + ": " +
                                   (idot == std::string::npos ? reply : reply.substr(0, idot + 1));
                if (request->Has("replacing"))
                {
                    said += " (again)";
                }
                if (part == "last" && !reply.empty() && reply.back() == '?')
                {
                    said += " Should I go on?";
                }
                Say(said);
                return;
            }
            if (reply.find("word for word") != std::string::npos &&
                (!bstrict || reply.find("always") != std::string::npos))
            {
                Say(reply);
                return;
            }
            if (bstrict)
            {
                std::size_t iend = 0;
                for (int i = 0; i < 3 && iend != std::string::npos; ++i)
                {
                    iend = reply.find(' ', iend + 1);
                }
                Say("Retold: " + reply.substr(0, iend));
                return;
            }
            const std::size_t idot = reply.find('.');
            Say("Summary: " + (idot == std::string::npos ? reply : reply.substr(0, idot + 1)) +
                ((*request)["length"].AsString() == "medium" ? " More." : ""));
        }
        else if (request && request->Has("permission"))
        {
            const Json& asked = (*request)["permission"];
            Say(Json::Object()
                    .Set("say", "Can I use " + asked["tool"].AsString() + ": " + asked["summary"].AsString() + "?")
                    .Dump());
        }
        else if (request && request->Has("asked"))
        {
            const std::string said = (*request)["answer"].AsString();
            std::string answer = said;
            for (char& c : answer)
            {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            auto has = [&answer](const char* _szWord) { return answer.find(_szWord) != std::string::npos; };
            const std::string verdict = has("maybe") || has("not sure") ? "unclear"
                                        : answer.rfind("no", 0) == 0 || has("don't") || has("wait") || has("hold on")
                                            ? "deny"
                                        : answer.rfind("yes", 0) == 0 || has(" yes") || has("go ahead") || has("yeah")
                                                || has("sure")
                                            ? "allow"
                                            : "unclear";
            Json reply = Json::Object().Set("answer", verdict).Set("why", "fake");
            const std::size_t ibut = answer.find(" but ");
            if (verdict == "allow" && ibut != std::string::npos)
            {
                reply.Set("note", said.substr(ibut + 5));
            }
            Say(reply.Dump());
        }
        else if (request && request->Has("steps"))
        {
            const Json& steps = (*request)["steps"];
            const std::string asked = (*request)["request"].AsString();
            auto line = [](const std::string& _Line)
            {
                Say(_Line.empty() ? Json::Object().Set("skip", true).Dump()
                                  : Json::Object().Set("say", _Line).Dump());
            };
            if (asked.find("quietly") != std::string::npos)
            {
                if (steps.Size() == 0)
                {
                    Say("There's nothing new, so I'll stay quiet.");
                }
                else
                {
                    line("Nothing new yet, so I'm staying quiet.");
                }
                return;
            }
            auto whatOf = [](const Json& _Step)
            {
                std::string what = _Step["summary"].AsString();
                what = what.empty() ? _Step["name"].AsString() : what;
                return what.empty() ? _Step["text"].AsString().substr(0, 40) : what;
            };
            // Other conversations' steps: "<title> on <what>" each, after Bragi's own.
            std::string others;
            if (request->Has("others"))
            {
                const Json& list = (*request)["others"];
                for (std::size_t i = 0; i < list.Size(); ++i)
                {
                    const Json& osteps = list[i]["steps"];
                    // Its small news (replies to its background tasks'
                    // reports) all go in, ", " between them.
                    std::string replies;
                    for (std::size_t j = 0; j < osteps.Size(); ++j)
                    {
                        if (osteps[j]["kind"].AsString() == "reply")
                        {
                            replies += (replies.empty() ? "" : ", ") + osteps[j]["text"].AsString();
                        }
                    }
                    if (!replies.empty())
                    {
                        others += "; " + list[i]["title"].AsString() + " on " + replies;
                    }
                    else if (osteps.Size() > 0)
                    {
                        others += "; " + list[i]["title"].AsString() + " on " + whatOf(osteps[osteps.Size() - 1]);
                    }
                }
            }
            if (steps.Size() == 0 && !others.empty())
            {
                line("Now: " + others.substr(2));
                return;
            }
            if (steps.Size() == 0)
            {
                if (request->Has("quiet"))
                {
                    line("Still on: " + asked);
                }
                else
                {
                    const bool bfirst = (*request)["said"].Size() == 0 || request->Has("first") ||
                                        request->Has("opening");
                    line(bfirst && !asked.empty() ? "Looking into: " + asked : "");
                }
                return;
            }
            line("Now: " + whatOf(steps[steps.Size() - 1]) + others);
        }
        else if (request && request->Has("said"))
        {
            const std::string said = (*request)["said"].AsString();
            const char* szaction = said.find("stop") != std::string::npos ? "stop"
                                   : said.find("instead") != std::string::npos ? "steer"
                                   : (said.find("keep going") != std::string::npos ||
                                         said.find("go on") != std::string::npos)
                                       ? "resume"
                                       : "note";
            Say(Json::Object().Set("action", szaction).Set("why", "fake").Dump());
        }
        else if (g_nImages > 0)
        {
            Say("You said: " + _Text + " (" + std::to_string(g_nImages) +
                (g_nImages == 1 ? " image)" : " images)"));
        }
        else
        {
            Say("You said: " + _Text);
        }
    }

} // namespace

namespace
{

    int AuthStatus()
    {
        std::string state;
        if (const char* szdir = std::getenv("CLAUDE_CONFIG_DIR"))
        {
            std::ifstream file(std::filesystem::path(szdir) / "fake-auth");
            std::getline(file, state);
        }
        Json status = Json::Object();
        if (state == "out")
        {
            status.Set("loggedIn", false).Set("authMethod", "none");
        }
        else if (state == "api")
        {
            status.Set("loggedIn", true).Set("authMethod", "apiKey");
        }
        else
        {
            status.Set("loggedIn", true)
                .Set("authMethod", "claude.ai")
                .Set("subscriptionType", "max");
        }
        std::cout << status.Dump() << "\n";
        return state == "out" ? 1 : 0;
    }

} // namespace

int main(int _iArgc, char** _aszArgv)
{
    if (_iArgc == 2 && std::string(_aszArgv[1]) == "--version")
    {
        std::cout << "0.0.0-fake (Claude Code)\n";
        return 0;
    }
    if (_iArgc == 2 && std::string(_aszArgv[1]) == "--help")
    {
        std::cout << "Options:\n"
                     "  --permission-mode <mode>              Permission mode to use for the session\n"
                     "                                        (choices: \"acceptEdits\", \"auto\",\n"
                     "                                        \"bypassPermissions\", \"manual\",\n"
                     "                                        \"dontAsk\", \"plan\")\n"
                     "  --model <model>                       Model for the current session\n";
        return 0;
    }
    if (_iArgc == 3 && std::string(_aszArgv[1]) == "auth" && std::string(_aszArgv[2]) == "status")
    {
        return AuthStatus();
    }
    for (int i = 1; i < _iArgc; ++i)
    {
        g_Args.push_back(_aszArgv[i]);
        const std::string arg = _aszArgv[i];
        if (arg == "--model" && i + 1 < _iArgc)
        {
            g_Model = _aszArgv[i + 1];
        }
        else if (arg == "--permission-mode" && i + 1 < _iArgc)
        {
            g_Mode = _aszArgv[i + 1];
        }
    }
    if (const char* szdir = std::getenv("CLAUDE_CONFIG_DIR"))
    {
        const std::filesystem::path config = std::filesystem::u8path(szdir);
        std::error_code ec;
        const bool bpersist =
            std::find(g_Args.begin(), g_Args.end(), "--no-session-persistence") == g_Args.end();
        if (*szdir && bpersist && std::filesystem::exists(config / "fake-transcripts", ec))
        {
            std::string resume;
            std::string resumeAt;
            for (std::size_t i = 0; i + 1 < g_Args.size(); ++i)
            {
                if (g_Args[i] == "--resume")
                {
                    resume = g_Args[i + 1];
                }
                else if (g_Args[i] == "--resume-session-at")
                {
                    resumeAt = g_Args[i + 1];
                }
            }
            const bool bfork =
                !resume.empty() && std::find(g_Args.begin(), g_Args.end(), "--fork-session") != g_Args.end();
            const auto ticks = std::chrono::steady_clock::now().time_since_epoch().count();
            g_SessionId = !resume.empty() && !bfork ? resume : "fake-" + std::to_string(ticks);
            std::string folder = std::filesystem::current_path().u8string();
            for (char& c : folder)
            {
                if (!std::isalnum(static_cast<unsigned char>(c)))
                {
                    c = '-';
                }
            }
            const std::filesystem::path dir = config / "projects" / std::filesystem::u8path(folder);
            std::filesystem::create_directories(dir, ec);
            g_Transcript = dir / std::filesystem::u8path(g_SessionId + ".jsonl");
            if (!resume.empty())
            {
                // Go on from the resumed session's last line, or the one asked for.
                const std::filesystem::path resumed = dir / std::filesystem::u8path(resume + ".jsonl");
                const std::vector<Json> lines = TranscriptLines(resumed);
                for (auto it = lines.rbegin(); it != lines.rend() && g_LastUuid.empty(); ++it)
                {
                    g_LastUuid = (*it)["uuid"].AsString();
                }
                g_LastUuid = !resumeAt.empty() ? resumeAt : g_LastUuid;
                g_ForkFrom = bfork ? resumed : std::filesystem::path();
            }
        }
    }

    bool bstarted = false;
    Json message;
    while (ReadMessage(message))
    {
        const std::string type = message["type"].AsString();
        if (type == "control_request")
        {
            Reply(message);
            continue;
        }
        if (type == "control_response" && !g_HelperRequest.empty()
            && message["response"]["request_id"].AsString() == g_HelperRequest)
        {
            HelperAnswered(message["response"]);
            continue;
        }
        if (type != "user")
        {
            continue;
        }
        if (!bstarted)
        {
            bstarted = true;
            Out(Json::Object()
                    .Set("type", "system")
                    .Set("subtype", "init")
                    .Set("session_id", g_SessionId)
                    .Set("model", g_Model)
                    .Set("permissionMode", g_Mode)
                    .Set("cwd", std::filesystem::current_path().string())
                    .Set("tools", Json::Array().Push("Bash").Push("Read"))
                    .Set("apiKeySource", "none")
                    .Set("claude_code_version", "0.0.0-fake")
                    .Set("output_style", "default")
                    .Set("mcp_servers", Json::Array().Push(Json::Object()
                            .Set("name", "gitgud")
                            .Set("status", "connected")))
                    .Set("slash_commands", Json::Array().Push("compact").Push("context").Push("review").Push("fake-skill").Push("color"))
                    .Set("skills", Json::Array().Push("fake-skill"))
                    .Set("plugins", Json::Array().Push(Json::Object()
                            .Set("name", "fake-plugin")
                            .Set("path", "plugins/fake-plugin")))
                    .Set("agents", Json::Array().Push("general-purpose")));
        }
        // A message with pictures: image blocks, then its text.
        const Json& content = message["message"]["content"];
        std::string text = content.AsString();
        g_nImages = 0;
        if (content.IsArray())
        {
            for (const Json& block : content.Items())
            {
                if (block["type"].AsString() == "image")
                {
                    ++g_nImages;
                }
                else if (block["type"].AsString() == "text")
                {
                    text += block["text"].AsString();
                }
            }
        }
        if (LocalCommandName(text).empty())
        {
            Record("user", Json::Object().Set("role", "user").Set("content", content));
        }
        Turn(text);
    }
    return 0;
}
