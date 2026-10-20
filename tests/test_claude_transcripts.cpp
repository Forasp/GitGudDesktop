// Tests for agent/ClaudeTranscripts: Claude Code's saved sessions, read
// from a scratch CLAUDE_CONFIG_DIR.

#include <catch2/catch_test_macros.hpp>

#include "agent/ClaudeTranscripts.h"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

using gitgud::agent::ClaudeTranscripts;
namespace fs = std::filesystem;

namespace
{

    void SetEnv(const char* _szName, const std::string& _Value)
    {
#if defined(_WIN32)
        _putenv_s(_szName, _Value.c_str());
#else
        setenv(_szName, _Value.c_str(), 1);
#endif
    }

    // A scratch config folder for the test's lifetime.
    struct ScratchConfig
    {
        fs::path m_Root;

        ScratchConfig()
        {
            m_Root = fs::temp_directory_path() / "gitgud-claude-transcripts";
            fs::remove_all(m_Root);
            fs::create_directories(m_Root);
            SetEnv("CLAUDE_CONFIG_DIR", m_Root.u8string());
        }

        ~ScratchConfig()
        {
            SetEnv("CLAUDE_CONFIG_DIR", "");
            std::error_code ec;
            fs::remove_all(m_Root, ec);
        }

        void Write(const std::string& _Cwd, const std::string& _Id, const std::string& _Lines)
        {
            const fs::path dir = m_Root / "projects" / ClaudeTranscripts::ProjectFolderName(_Cwd);
            fs::create_directories(dir);
            std::ofstream out(dir / (_Id + ".jsonl"), std::ios::binary);
            out << _Lines;
        }
    };

    const char* kCwd = "C:\\work\\my app";

} // namespace

TEST_CASE("Transcript folders are named like Claude Code names them", "[agent][transcripts]")
{
    CHECK(ClaudeTranscripts::ProjectFolderName("C:\\work\\my app") == "C--work-my-app");
    CHECK(ClaudeTranscripts::ProjectFolderName("/home/sam/src/x.y") == "-home-sam-src-x-y");
    ScratchConfig scratch;
    CHECK(ClaudeTranscripts::ConfigDir() == scratch.m_Root.u8string());
}

TEST_CASE("Titles are a first line, cut on a character", "[agent][transcripts]")
{
    CHECK(ClaudeTranscripts::Title("  Fix the parser\nwith details") == "Fix the parser");
    CHECK(ClaudeTranscripts::Title("   ").empty());
    const std::string longer(79, 'a');
    const std::string title = ClaudeTranscripts::Title(longer + "\xC3\xA9xyz"); // é across the cut
    CHECK(title == longer + "...");
}

TEST_CASE("Titles skip what was put in front of the message", "[agent][transcripts]")
{
    CHECK(ClaudeTranscripts::Title("<system-reminder>\nLinked sessions now\n</system-reminder>\n\nFix the list order") ==
          "Fix the list order");
    CHECK(ClaudeTranscripts::Title("<system-reminder>a</system-reminder><task-notification>\n<status>completed"
                                   "</status>\n</task-notification>\nReal ask\nmore") == "Real ask");
    CHECK(ClaudeTranscripts::Title("<pasted_content id=\"x\">a paste</pasted_content> what's this?") == "what's this?");
    // Only injected, or never closed: no title.
    CHECK(ClaudeTranscripts::Title("<task-notification>\n<status>completed</status>\n</task-notification>").empty());
    CHECK(ClaudeTranscripts::Title("<system-reminder>\ncut off").empty());
    // A tag of its own isn't skipped, nor one that only starts the same.
    CHECK(ClaudeTranscripts::Title("<div> is a tag") == "<div> is a tag");
    CHECK(ClaudeTranscripts::Title("<system-reminders> plural") == "<system-reminders> plural");
}

TEST_CASE("A session's title and order come from its messages", "[agent][transcripts]")
{
    ScratchConfig scratch;
    // Begun by injected text only, then a real ask: titled by the ask. Its
    // last message is the newest, but its file is written first.
    scratch.Write(kCwd, "aaaa-0001",
        R"({"type":"user","timestamp":"2026-10-19T10:00:00.000Z","message":{"role":"user","content":"<task-notification>\n<status>completed</status>\n</task-notification>"}})"
        "\n"
        R"({"type":"user","timestamp":"2026-10-19T10:00:05.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nnote\n</system-reminder>\n\nWhy does the list jump?"}]}})"
        "\n"
        R"({"type":"assistant","timestamp":"2026-10-19T12:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Because."}]}})"
        "\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    // Older messages, but opened since: Claude Code added lines without a
    // message (and its title). Written last, listed last.
    scratch.Write(kCwd, "bbbb-0002",
        R"({"type":"user","timestamp":"2026-10-19T09:00:00.000Z","message":{"role":"user","content":"<system-reminder>x</system-reminder>Background from another session"}})"
        "\n"
        R"({"type":"assistant","timestamp":"2026-10-19T09:10:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}})"
        "\n"
        R"({"type":"custom-title","customTitle":"Old title","sessionId":"bbbb-0002"})"
        "\n"
        R"({"type":"last-prompt","leafUuid":"u","sessionId":"bbbb-0002"})"
        "\n"
        R"({"type":"custom-title","customTitle":"Pinned plan under the latest message","sessionId":"bbbb-0002"})"
        "\n");

    const auto sessions = ClaudeTranscripts::List(kCwd);
    REQUIRE(sessions.size() == 2);
    CHECK(sessions[0].m_Id == "aaaa-0001");
    CHECK(sessions[0].m_Title == "Why does the list jump?");
    CHECK(sessions[0].m_Asked == "Why does the list jump?");
    CHECK(sessions[0].m_iActive == 1792413000); // 2026-10-19T12:30:00Z
    CHECK(sessions[1].m_Id == "bbbb-0002");
    CHECK(sessions[1].m_Title == "Pinned plan under the latest message");
    CHECK(sessions[1].m_Asked == "Background from another session"); // what it began with, all the same
    CHECK(sessions[1].m_iActive == 1792401000); // 2026-10-19T09:10:00Z
    CHECK(sessions[1].m_iUpdated >= sessions[0].m_iUpdated); // written last all the same

    const auto projects = ClaudeTranscripts::Projects();
    REQUIRE(projects.size() == 1);
    CHECK(projects[0].m_iUpdated == 1792413000);
    CHECK(projects[0].m_Sessions[0].m_Id == "aaaa-0001");
}

TEST_CASE("Sessions are listed newest first with their titles", "[agent][transcripts]")
{
    ScratchConfig scratch;
    scratch.Write(kCwd, "aaaa-1111",
        R"({"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: meta"}})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":[{"type":"text","text":"Why is the parser test flaky?\nIt fails on CI."}]}})"
        "\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(1100)); // a newer write time
    scratch.Write(kCwd, "bbbb-2222",
        R"({"type":"summary","summary":"Board colours from theme tokens","leafUuid":"x"})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":"make boards"}})"
        "\n");
    scratch.Write(kCwd, "cccc-3333",
        R"({"type":"system","content":"nothing asked"})"
        "\n");
    scratch.Write(kCwd, "not a session", "{}\n");
    scratch.Write("C:\\elsewhere", "dddd-4444",
        R"({"type":"user","message":{"role":"user","content":"other folder"}})"
        "\n");

    const auto sessions = ClaudeTranscripts::List(kCwd);
    REQUIRE(sessions.size() == 2); // not the empty one, not the badly named one
    CHECK(sessions[0].m_Id == "bbbb-2222");
    CHECK(sessions[0].m_Title == "Board colours from theme tokens");
    CHECK(sessions[1].m_Id == "aaaa-1111");
    CHECK(sessions[1].m_Title == "Why is the parser test flaky?");
    CHECK(sessions[0].m_iUpdated >= sessions[1].m_iUpdated);
    CHECK(sessions[1].m_iUpdated > 1700000000);
    CHECK(ClaudeTranscripts::List(kCwd, 1).size() == 1);
    CHECK(ClaudeTranscripts::List("C:\\nowhere").empty());
}

TEST_CASE("Projects are listed with their folders from the transcripts", "[agent][transcripts]")
{
    ScratchConfig scratch;
    // The folder name is lossy ("my app" and "my-app" read the same): the
    // transcripts' own cwd says which folder it was.
    scratch.Write("C:\\work\\my app", "aaaa-0001",
        R"({"type":"file-history-snapshot","messageId":"m"})"
        "\n"
        R"({"type":"user","cwd":"C:\\work\\my app","message":{"role":"user","content":"First in my app"}})"
        "\n");
    scratch.Write("C:\\nothing", "cccc-0003", R"({"type":"system","content":"nothing asked"})" "\n");
    // A transcript without a cwd: the project's folder is unknown.
    scratch.Write("C:\\old", "dddd-0004",
        R"({"type":"user","message":{"role":"user","content":"Older format"}})"
        "\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    scratch.Write("C:\\other", "bbbb-0002",
        R"({"type":"user","cwd":"C:\\other","message":{"role":"user","content":"In the other one"}})"
        "\n");

    auto projects = ClaudeTranscripts::Projects();
    REQUIRE(projects.size() == 3); // not the one with nothing asked
    CHECK(projects[0].m_Cwd == "C:\\other");
    CHECK(projects[0].m_Folder == "C--other");
    REQUIRE(projects[0].m_Sessions.size() == 1);
    CHECK(projects[0].m_Sessions[0].m_Title == "In the other one");
    CHECK(projects[0].m_Sessions[0].m_Cwd == "C:\\other");
    bool bmyApp = false;
    bool bold = false;
    for (const auto& project : projects)
    {
        bmyApp = bmyApp || (project.m_Cwd == "C:\\work\\my app" && project.m_Sessions[0].m_Id == "aaaa-0001");
        bold = bold || (project.m_Folder == "C--old" && project.m_Cwd.empty());
    }
    CHECK(bmyApp);
    CHECK(bold);
    CHECK(ClaudeTranscripts::Projects(30, 1).size() == 1);

    // Listing again reads changed files again.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    scratch.Write("C:\\other", "bbbb-0002",
        R"({"type":"summary","summary":"Renamed"})"
        "\n"
        R"({"type":"user","cwd":"C:\\other","message":{"role":"user","content":"In the other one"}})"
        "\n");
    projects = ClaudeTranscripts::Projects();
    CHECK(projects[0].m_Sessions[0].m_Title == "Renamed");
    CHECK(ClaudeTranscripts::List("C:\\other")[0].m_Cwd == "C:\\other");

    // History by id finds the file whatever folder is given.
    CHECK(ClaudeTranscripts::Read("C:\\somewhere else", "bbbb-0002").size() == 1);
    CHECK(ClaudeTranscripts::Read("", "aaaa-0001").size() == 1);
    CHECK(ClaudeTranscripts::Find("", "zzzz-9999").empty());
    CHECK(ClaudeTranscripts::Read("", "../x").empty());
}

TEST_CASE("A session reads back as the main conversation", "[agent][transcripts]")
{
    ScratchConfig scratch;
    scratch.Write(kCwd, "abcd-1234",
        R"({"type":"user","message":{"role":"user","content":"List the files"}})"
        "\n"
        R"({"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Looking."}]}})"
        "\n"
        R"({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}})"
        "\n"
        R"({"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"sub-agent"}]}})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"a.txt"}],"is_error":false}]}})"
        "\n"
        "not json\n"
        R"({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"denied","is_error":true}]}})"
        "\n"
        R"({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}})"
        "\n");

    const auto entries = ClaudeTranscripts::Read(kCwd, "abcd-1234");
    REQUIRE(entries.size() == 6);
    CHECK(entries[0].m_Kind == "user");
    CHECK(entries[0].m_Text == "List the files");
    CHECK(entries[1].m_Kind == "assistant");
    CHECK(entries[1].m_Text == "Looking.");
    CHECK(entries[2].m_Kind == "tool");
    CHECK(entries[2].m_Name == "Bash");
    CHECK(entries[2].m_Id == "t1");
    CHECK(entries[2].m_Input["command"].AsString() == "ls");
    CHECK(entries[3].m_Kind == "toolResult");
    CHECK(entries[3].m_Id == "t1");
    CHECK(entries[3].m_Text == "a.txt");
    CHECK_FALSE(entries[3].m_bError);
    CHECK(entries[4].m_bError);
    CHECK(entries[4].m_Text == "denied");
    CHECK(entries[5].m_Text == "Done.");

    // The latest entries when there are more than asked for.
    const auto last = ClaudeTranscripts::Read(kCwd, "abcd-1234", 2);
    REQUIRE(last.size() == 2);
    CHECK(last[1].m_Text == "Done.");

    // Ids can't leave the folder.
    CHECK(ClaudeTranscripts::Read(kCwd, "../abcd-1234").empty());
    CHECK(ClaudeTranscripts::Read(kCwd, "missing").empty());
}

TEST_CASE("Slash commands and compaction read back as shown live", "[agent][transcripts]")
{
    // Lines as Claude Code 2.1 writes them for /context, then /compact.
    ScratchConfig scratch;
    scratch.Write(kCwd, "cmd-1",
        R"({"type":"user","message":{"role":"user","content":"Say hi"}})"
        "\n"
        R"({"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>The command below was run directly.</local-command-caveat>"}})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":"<command-name>/context</command-name>\n            <command-message>context</command-message>\n            <command-args></command-args>"}})"
        "\n"
        R"({"type":"system","subtype":"local_command","content":"<local-command-stdout>## Context Usage\n\n27.4k tokens\n</local-command-stdout>","level":"info"})"
        "\n"
        R"({"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":27452,"postTokens":5495}})"
        "\n"
        R"({"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args>keep it short</command-args>"}})"
        "\n"
        R"({"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}})"
        "\n");

    const auto entries = ClaudeTranscripts::Read(kCwd, "cmd-1");
    REQUIRE(entries.size() == 5);
    CHECK(entries[0].m_Text == "Say hi");
    CHECK(entries[1].m_Kind == "user");
    CHECK(entries[1].m_Text == "/context");
    CHECK(entries[2].m_Kind == "assistant");
    CHECK(entries[2].m_Text == "## Context Usage\n\n27.4k tokens");
    CHECK(entries[3].m_Kind == "compacted");
    CHECK(entries[3].m_Text == "manual");
    CHECK(entries[3].m_Input["postTokens"].AsInt() == 5495);
    CHECK(entries[4].m_Kind == "user");
    CHECK(entries[4].m_Text == "/compact keep it short");

    // Titles still skip the command lines.
    CHECK(ClaudeTranscripts::List(kCwd)[0].m_Title == "Say hi");
}

TEST_CASE("A long session's latest entries are read from its end", "[agent][transcripts]")
{
    // Many blocks' worth of lines, some longer than a block, and no newline
    // after the last line.
    ScratchConfig scratch;
    std::string lines;
    const std::string big(300 * 1024, 'x');
    for (int i = 1; i <= 3000; ++i)
    {
        const std::string text = "message " + std::to_string(i) + (i % 500 == 0 ? " " + big : "");
        lines += R"({"type":"user","message":{"role":"user","content":")" + text + "\"}}";
        if (i < 3000)
        {
            lines += i % 2 == 0 ? "\r\n" : "\n";
        }
    }
    scratch.Write(kCwd, "long-1", lines);

    const auto all = ClaudeTranscripts::Read(kCwd, "long-1", 5000);
    REQUIRE(all.size() == 3000);
    CHECK(all.front().m_Text == "message 1");
    CHECK(all[499].m_Text == "message 500 " + big);
    CHECK(all.back().m_Text == "message 3000 " + big);

    const auto last = ClaudeTranscripts::Read(kCwd, "long-1", 3);
    REQUIRE(last.size() == 3);
    CHECK(last[0].m_Text == "message 2998");
    CHECK(last[1].m_Text == "message 2999");
    CHECK(last[2].m_Text == "message 3000 " + big);
    CHECK(ClaudeTranscripts::Read(kCwd, "long-1", 0).empty());
}

namespace
{

    // A chained transcript line: its uuid, its parent's ("" for none), and
    // what it holds.
    std::string Chained(const std::string& _Uuid, const std::string& _Parent, const std::string& _Rest)
    {
        return R"({"uuid":")" + _Uuid + R"(","parentUuid":)" +
               (_Parent.empty() ? std::string("null") : "\"" + _Parent + "\"") +
               R"(,"sessionId":"tree-1","cwd":"C:\\work\\my app",)" + _Rest + "}\n";
    }

    std::string Ask(const std::string& _Text)
    {
        return R"("type":"user","message":{"role":"user","content":")" + _Text + "\"}";
    }

    std::string Say(const std::string& _Text)
    {
        return R"("type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":")" +
               _Text + "\"}]}";
    }

    std::string Call(const std::string& _Id)
    {
        return R"("type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":")" +
               _Id + R"(","name":"Read","input":{}}]})";
    }

    std::string Result(const std::string& _Id)
    {
        return R"("type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":")" +
               _Id + R"(","content":"ok"}]})";
    }

    // A conversation rewound to before its second question and asked
    // again: the first answer used two tools at once.
    std::string Rewound()
    {
        return Chained("u1", "", Ask("first")) + Chained("a1", "u1", Call("t1")) +
               Chained("a2", "a1", Call("t2")) + Chained("r1", "a1", Result("t1")) +
               Chained("r2", "a2", Result("t2")) + Chained("a3", "r2", Say("one")) +
               R"({"type":"file-history-snapshot","messageId":"x"})" "\n" +
               Chained("u2", "a3", Ask("second")) + Chained("a4", "u2", Say("two")) +
               Chained("u3", "a3", Ask("second, again")) + Chained("a5", "u3", Say("two again"));
    }

} // namespace

TEST_CASE("A rewound session reads back as the branch it goes on from", "[agent][transcripts]")
{
    ScratchConfig scratch;
    scratch.Write(kCwd, "tree-1", Rewound());

    const auto entries = ClaudeTranscripts::Read(kCwd, "tree-1");
    std::vector<std::string> seen;
    for (const auto& entry : entries)
    {
        seen.push_back(entry.m_Uuid + ":" + entry.m_Kind);
    }
    const std::vector<std::string> expected{"u1:user", "a1:tool", "a2:tool", "r1:toolResult",
        "r2:toolResult", "a3:assistant", "u3:user", "a5:assistant"};
    CHECK(seen == expected);
    REQUIRE(entries.size() == expected.size());
    CHECK(entries[6].m_Text == "second, again");
    CHECK(entries[6].m_ParentUuid == "a3");
    CHECK(entries[0].m_ParentUuid.empty());

    // The latest only: the branch is followed all the same.
    const auto last = ClaudeTranscripts::Read(kCwd, "tree-1", 3);
    REQUIRE(last.size() == 3);
    CHECK(last[0].m_Uuid == "a3");
    CHECK(last[2].m_Uuid == "a5");

    // Across a compaction: the summary's logical parent goes on.
    scratch.Write(kCwd, "tree-2",
        Chained("c1", "", Ask("before")) +
        Chained("b1", "", R"("type":"system","subtype":"compact_boundary","logicalParentUuid":"c1")") +
        Chained("c2", "b1", Say("after")));
    const auto compacted = ClaudeTranscripts::Read(kCwd, "tree-2");
    REQUIRE(compacted.size() == 3);
    CHECK(compacted[0].m_Text == "before");
    CHECK(compacted[1].m_Kind == "compacted");
    CHECK(compacted[2].m_Text == "after");
}

TEST_CASE("A session forks into another folder up to an entry", "[agent][transcripts]")
{
    ScratchConfig scratch;
    scratch.Write(kCwd, "tree-1", Rewound());

    const std::string other = "C:\\work\\other";
    const std::string id = ClaudeTranscripts::Fork(kCwd, "tree-1", "a3", other);
    REQUIRE(id.size() == 36);
    CHECK(id[14] == '4');
    CHECK(ClaudeTranscripts::Find(other, id).find(ClaudeTranscripts::ProjectFolderName(other)) !=
          std::string::npos);
    const auto entries = ClaudeTranscripts::Read(other, id);
    REQUIRE(entries.size() == 6); // the first exchange, its parallel results too
    CHECK(entries[0].m_Text == "first");
    CHECK(entries[3].m_Kind == "toolResult");
    CHECK(entries[5].m_Text == "one");
    const auto list = ClaudeTranscripts::List(other);
    REQUIRE(list.size() == 1);
    CHECK(list[0].m_Cwd == other);

    // All of it: the branch it goes on from.
    const std::string whole = ClaudeTranscripts::Fork(kCwd, "tree-1", "", other);
    REQUIRE_FALSE(whole.empty());
    CHECK(whole != id);
    CHECK(ClaudeTranscripts::Read(other, whole).size() == 8);
    std::ifstream in(fs::u8path(ClaudeTranscripts::Find(other, whole)), std::ios::binary);
    const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    CHECK(text.find("\"sessionId\":\"" + whole + "\"") != std::string::npos);
    CHECK(text.find("tree-1") == std::string::npos);
    CHECK(text.find("second\"") == std::string::npos); // the branch left behind

    CHECK(ClaudeTranscripts::Fork(kCwd, "tree-1", "nope", other).empty());
    CHECK(ClaudeTranscripts::Fork(kCwd, "missing", "", other).empty());
}

TEST_CASE(
    "Instruction and memory files are found like Claude Code finds them", "[agent][transcripts]")
{
    ScratchConfig config;
    auto touch = [](const fs::path& _Path)
    {
        fs::create_directories(_Path.parent_path());
        std::ofstream(_Path, std::ios::binary) << "x";
    };
    // The project lives outside the config folder, as it would.
    const fs::path root = fs::temp_directory_path() / "gitgud-claude-context";
    fs::remove_all(root);
    const fs::path project = root / "repo";
    const fs::path inner = project / "src";
    touch(config.m_Root / "CLAUDE.md");
    touch(config.m_Root / "rules" / "b.md");
    touch(config.m_Root / "rules" / "a.md");
    touch(config.m_Root / "rules" / "notes.txt");
    touch(root / "CLAUDE.md");
    touch(project / ".claude" / "CLAUDE.md");
    touch(project / "CLAUDE.local.md");
    touch(project / ".claude" / "rules" / "style.md");
    touch(inner / "CLAUDE.md");
    touch(inner / ".claude" / "settings.local.json");
    touch(config.m_Root / "projects" / ClaudeTranscripts::ProjectFolderName(inner.u8string()) /
          "memory" / "MEMORY.md");

    // Only what's in the scratch folder: the real folders above it may
    // hold instructions of their own.
    std::vector<gitgud::agent::ContextFile> files;
    for (const auto& file : ClaudeTranscripts::ContextFiles(inner.u8string()))
    {
        if (file.m_Path.rfind(config.m_Root.u8string(), 0) == 0 ||
            file.m_Path.rfind(root.u8string(), 0) == 0)
        {
            files.push_back(file);
        }
    }
    std::vector<std::string> kinds;
    std::vector<std::string> names;
    for (const auto& file : files)
    {
        kinds.push_back(file.m_Kind);
        names.push_back(fs::u8path(file.m_Path).filename().u8string());
    }
    CHECK(kinds == std::vector<std::string>{"user", "userRule", "userRule", "project", "project",
                       "local", "projectRule", "project", "memory", "settings"});
    CHECK(names == std::vector<std::string>{"CLAUDE.md", "a.md", "b.md", "CLAUDE.md", "CLAUDE.md",
                       "CLAUDE.local.md", "style.md", "CLAUDE.md", "MEMORY.md",
                       "settings.local.json"});
    CHECK(fs::u8path(files[4].m_Path).parent_path().filename() == ".claude");

    // No folder: only the user's files.
    CHECK(ClaudeTranscripts::ContextFiles("").size() == 3);
    std::error_code ec;
    fs::remove_all(root, ec);
}

TEST_CASE("A transcript read again comes from its last read only while it's unchanged", "[agent][transcripts]")
{
    // Reads are kept (the same long transcripts were read
    // again and again); a file that grew or changed is read afresh.
    ScratchConfig scratch;
    const std::string first = R"({"type":"user","message":{"role":"user","content":"one"}})"
                              "\n";
    const std::string second = R"({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"two"}]}})"
                               "\n";
    scratch.Write(kCwd, "cache-1", first);
    CHECK(ClaudeTranscripts::Read(kCwd, "cache-1").size() == 1);
    CHECK(ClaudeTranscripts::Read(kCwd, "cache-1").size() == 1);
    scratch.Write(kCwd, "cache-1", first + second);
    const auto grown = ClaudeTranscripts::Read(kCwd, "cache-1");
    REQUIRE(grown.size() == 2);
    CHECK(grown[1].m_Text == "two");
    // Same size, other words, a later time.
    std::string changed = first + second;
    changed.replace(changed.find("two"), 3, "TWO");
    scratch.Write(kCwd, "cache-1", changed);
    const fs::path file = ClaudeTranscripts::Find(kCwd, "cache-1");
    fs::last_write_time(file, fs::last_write_time(file) + std::chrono::seconds(5));
    const auto later = ClaudeTranscripts::Read(kCwd, "cache-1");
    REQUIRE(later.size() == 2);
    CHECK(later[1].m_Text == "TWO");
    // Another count is another read.
    CHECK(ClaudeTranscripts::Read(kCwd, "cache-1", 1).size() == 1);
}
