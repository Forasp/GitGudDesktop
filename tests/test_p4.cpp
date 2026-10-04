// Tests for the Perforce backend (src/p4).
//
// The marshal tests always run. The rest drive a real, throwaway p4d in
// "rsh" mode (p4 starts it per command; nothing listens on a port) and skip
// unless GITGUD_TEST_P4D names p4d.exe and p4 is found (GITGUD_P4 or PATH).
// See docs/P4.md, "Testing". Every server, workspace, and ticket lives in a
// temp folder: the user's own P4 settings are cleared for the test process.

#include <catch2/catch_test_macros.hpp>

#include "git/Repository.h"
#include "p4/P4Command.h"
#include "p4/P4Workspace.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fs = std::filesystem;
using namespace gitgud;
using gitgud::p4::Connection;
using gitgud::p4::P4Command;
using gitgud::p4::P4Workspace;
using gitgud::p4::Record;
using gitgud::p4::WorkspaceSetup;

namespace
{

    const char* const g_szPassword = "Secret-123";

    std::string Env(const char* _szName)
    {
        const char* sz = std::getenv(_szName);
        return sz ? std::string(sz) : std::string();
    }

    // Keep the developer's own P4 environment out of the tests.
    void IsolateEnvironment(const fs::path& _Dir)
    {
        static bool s_bDone = false;
        if (s_bDone)
        {
            return;
        }
        s_bDone = true;
        for (const char* szvar :
            {"P4PORT", "P4USER", "P4CLIENT", "P4CONFIG", "P4PASSWD", "P4CHARSET"})
        {
            _putenv_s(szvar, "");
        }
        _putenv_s("P4TICKETS", (_Dir / "p4tickets.txt").string().c_str());
        _putenv_s("P4TRUST", (_Dir / "p4trust.txt").string().c_str());
        _putenv_s("P4ENVIRO", (_Dir / "p4enviro.txt").string().c_str());
    }

    bool HaveServer()
    {
        const std::string p4d = Env("GITGUD_TEST_P4D");
        std::error_code ec;
        return !p4d.empty() && fs::exists(fs::u8path(p4d), ec) && P4Command::Available();
    }

    // A fresh p4d with user "tim" (password set, logged in).
    struct TestServer
    {
        git::LibGit2 m_Lib;
        fs::path m_Dir;
        Connection m_Conn;

        TestServer()
        {
            static std::atomic<unsigned> s_Counter{0};
            m_Dir = fs::temp_directory_path() /
                    ("gitgud_p4_" + std::to_string(s_Counter++) + "_" +
                        std::to_string(reinterpret_cast<std::uintptr_t>(this)));
            std::error_code ec;
            fs::remove_all(m_Dir, ec);
            fs::create_directories(m_Dir / "root");
            fs::create_directories(m_Dir / "tmp");
            IsolateEnvironment(fs::temp_directory_path());
            P4Command::ClearTickets();
            m_Conn.m_Port =
                "rsh:" + Env("GITGUD_TEST_P4D") + " -r " + (m_Dir / "root").string() + " -L log -i";
            m_Conn.m_User = "tim";
            m_Conn.m_Dir = (m_Dir / "tmp").string();
            P4Command::RunText(
                m_Conn, {"passwd"}, std::string(g_szPassword) + "\n" + g_szPassword + "\n");
            std::string error;
            REQUIRE(P4Command::Login(m_Conn, g_szPassword, error));
        }

        ~TestServer()
        {
            std::error_code ec;
            fs::remove_all(m_Dir, ec);
        }

        std::string Folder(const std::string& _Name) const
        {
            return (m_Dir / _Name).string();
        }

        // A new workspace on stream `_Stream` (created when `_bCreate`).
        git::Repository Workspace(
            const std::string& _Name, const std::string& _Stream, bool _bCreate = false)
        {
            WorkspaceSetup setup;
            setup.m_Port = m_Conn.m_Port;
            setup.m_User = m_Conn.m_User;
            setup.m_Client = _Name;
            setup.m_Root = Folder(_Name);
            setup.m_Stream = _Stream;
            setup.m_bCreate = _bCreate;
            P4Workspace::Create(setup);
            return git::Repository::Open(Folder(_Name));
        }
    };

    void WriteFile(const git::Repository& _Repo, const std::string& _Name, const std::string& _Text)
    {
        const fs::path p = fs::u8path(_Repo.WorkDir()) / fs::u8path(_Name);
        fs::create_directories(p.parent_path());
        std::ofstream(p, std::ios::binary | std::ios::trunc) << _Text;
    }

    std::string ReadFile(const git::Repository& _Repo, const std::string& _Name)
    {
        std::ifstream in(fs::u8path(_Repo.WorkDir()) / fs::u8path(_Name), std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        // Workspaces use the client's line endings (CRLF on Windows).
        std::string text = ss.str();
        text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
        return text;
    }

    const git::StatusEntry* Find(
        const std::vector<git::StatusEntry>& _Status, const std::string& _Path)
    {
        for (const auto& e : _Status)
        {
            if (e.m_Path == _Path)
            {
                return &e;
            }
        }
        return nullptr;
    }

    // A stream repository with one submitted file.
    std::string CommitFile(git::Repository& _Repo, const std::string& _Name,
        const std::string& _Text, const std::string& _Message)
    {
        WriteFile(_Repo, _Name, _Text);
        _Repo.Stage(_Name);
        return _Repo.Commit(_Message);
    }

} // namespace

TEST_CASE("p4 marshal round-trips dictionaries", "[p4]")
{
    Record rec;
    rec["code"] = "stat";
    rec["desc"] = std::string("multi\nline\0binary", 17);
    rec["empty"] = "";
    const std::string wire = p4::MarshalRecord(rec) + p4::MarshalRecord({{"a", "b"}});
    const auto back = p4::UnmarshalRecords(wire);
    REQUIRE(back.size() == 2);
    CHECK(back[0] == rec);
    CHECK(back[1].at("a") == "b");
    // Ints (p4 sends some fields as 'i') decode as text.
    const std::string withInt =
        std::string("{s\x04\0\0\0codes\x04\0\0\0stats\x05\0\0\0leveli\x07\0\0\0"
                    "0",
            41);
    const auto ints = p4::UnmarshalRecords(withInt);
    REQUIRE(ints.size() == 1);
    CHECK(ints[0].at("level") == "7");
    // Truncated input yields what was complete.
    CHECK(p4::UnmarshalRecords(wire.substr(0, wire.size() - 3)).size() == 1);
}

TEST_CASE("p4 path escaping", "[p4]")
{
    CHECK(p4::EscapePath("a@b#c%d*e") == "a%40b%23c%25d%2Ae");
    CHECK(p4::UnescapePath("a%40b%23c%25d%2Ae") == "a@b#c%d*e");
}

TEST_CASE("p4 config file round trip", "[p4]")
{
    const fs::path dir = fs::temp_directory_path() / "gitgud_p4_config_test";
    fs::create_directories(dir);
    P4Workspace::WriteConfigFile(
        dir.string(), {{"P4PORT", "ssl:x:1666"}, {"P4CLIENT", "ws"}, {"GITGUD_X", "1"}});
    CHECK(P4Workspace::IsWorkspace(dir.string()));
    const auto cfg = P4Workspace::ReadConfigFile(dir.string());
    CHECK(cfg.at("P4PORT") == "ssl:x:1666");
    CHECK(cfg.at("GITGUD_X") == "1");
    std::error_code ec;
    fs::remove_all(dir, ec);
}

TEST_CASE("p4 new repository: add, submit, history", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    git::Repository repo = server.Workspace("ws1", "//proj/main", true);
    REQUIRE(repo.IsOpen());
    CHECK(repo.Backend() == "p4");
    CHECK(repo.CurrentBranch() == "main");
    CHECK(repo.Status().empty());
    CHECK(repo.HeadOid().empty());

    WriteFile(repo, "a.txt", "one\ntwo\nthree\n");
    WriteFile(repo, "src/b.txt", "bee\n");
    auto st = repo.Status();
    REQUIRE(Find(st, "a.txt"));
    CHECK(Find(st, "a.txt")->m_cCode == '?');
    CHECK_FALSE(Find(st, "a.txt")->m_bStaged);
    CHECK_FALSE(Find(st, ".p4config"));

    repo.Stage(std::vector<std::string>{"a.txt", "src/b.txt"});
    st = repo.Status();
    REQUIRE(Find(st, "a.txt"));
    CHECK(Find(st, "a.txt")->m_bStaged);
    CHECK(Find(st, "a.txt")->m_cCode == 'A');

    const std::string first = repo.Commit("First change\n\nWith a body");
    CHECK_FALSE(first.empty());
    CHECK(repo.Status().empty());
    CHECK(repo.HeadOid() == first);

    const auto log = repo.Log(10);
    REQUIRE(log.size() == 1);
    CHECK(log[0].m_Oid == first);
    CHECK(log[0].m_Summary == "First change");
    CHECK(log[0].m_Message == "First change\n\nWith a body");
    CHECK(log[0].m_AuthorName == "tim");

    // Edit -> unstaged; stage -> staged; unstage; discard.
    WriteFile(repo, "a.txt", "one\nTWO\nthree\n");
    st = repo.Status();
    REQUIRE(Find(st, "a.txt"));
    CHECK(Find(st, "a.txt")->m_cCode == 'M');
    CHECK(Find(st, "a.txt")->m_bUnstaged);
    const git::FileDiff d = repo.DiffFile("a.txt", git::DiffTarget::Unstaged);
    REQUIRE(d.m_Hunks.size() == 1);
    CHECK(repo.DiffFile("a.txt", git::DiffTarget::Staged).m_Path.empty());
    repo.Stage("a.txt");
    CHECK(Find(repo.Status(), "a.txt")->m_bStaged);
    CHECK(repo.DiffFile("a.txt", git::DiffTarget::Unstaged).m_Path.empty());
    CHECK(repo.DiffFile("a.txt", git::DiffTarget::Staged).m_Hunks.size() == 1);
    CHECK_FALSE(repo.StagedLines("a.txt").empty());
    repo.Unstage("a.txt");
    CHECK_FALSE(Find(repo.Status(), "a.txt")->m_bStaged);
    repo.DiscardChanges({"a.txt"});
    CHECK(ReadFile(repo, "a.txt") == "one\ntwo\nthree\n");
    CHECK(repo.Status().empty());

    // Versions, describe, browse.
    std::string text;
    CHECK(repo.ReadFileVersion("a.txt", "head", text));
    CHECK(text == "one\ntwo\nthree\n");
    CHECK(repo.ReadFileVersion("a.txt", first, text));
    CHECK_FALSE(repo.ReadFileVersion("a.txt", first + "^", text));
    const auto diffs = repo.DiffCommit(first);
    REQUIRE(diffs.size() == 2);
    CHECK(diffs[0].m_cStatus == 'A');
    const auto tree = repo.ListTree("head", "");
    REQUIRE(tree.size() == 2);
    CHECK(tree[0].m_bIsDir);
    CHECK(tree[0].m_Name == "src");
    CHECK(tree[1].m_Name == "a.txt");

    // Delete a file, submit, check status code and history.
    fs::remove(fs::u8path(repo.WorkDir()) / "src" / "b.txt");
    st = repo.Status();
    REQUIRE(Find(st, "src/b.txt"));
    CHECK(Find(st, "src/b.txt")->m_cCode == 'D');
    repo.Stage("src/b.txt");
    const std::string second = repo.Commit("Remove b");
    CHECK(repo.FileLog("src/b.txt", 10).size() == 2);
    const auto changed = repo.ChangedFiles(first, second);
    REQUIRE(changed.size() == 1);
    CHECK(changed[0].m_cStatus == 'D');

    // Nothing staged: commit refuses.
    CHECK_THROWS_AS(repo.Commit("empty"), git::GitError);
    CHECK_FALSE(repo.Supports("lineStaging"));
    CHECK(repo.Supports("changelists"));
    CHECK_THROWS_AS(repo.AmendCommit("x"), git::GitError);
}

TEST_CASE("p4 get latest, refusing to overwrite, and conflicts", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    git::Repository one = server.Workspace("ws1", "//proj/main", true);
    CommitFile(one, "a.txt", "one\ntwo\nthree\n", "first");
    git::Repository two = server.Workspace("ws2", "//proj/main");
    CHECK(ReadFile(two, "a.txt") == "one\ntwo\nthree\n");

    CHECK(one.Pull("server").m_Kind == git::MergeResult::Kind::UpToDate);

    // ws2 submits; ws1 sees one change to get, then gets it.
    WriteFile(two, "a.txt", "ONE\ntwo\nthree\n");
    two.Stage("a.txt");
    two.Commit("second");
    CHECK(one.GetAheadBehind().m_Behind == 1);
    CHECK(one.GetAheadBehind().m_Ahead == 0);
    const auto pulled = one.Pull("server");
    CHECK(pulled.m_Kind == git::MergeResult::Kind::FastForward);
    CHECK(ReadFile(one, "a.txt") == "ONE\ntwo\nthree\n");
    CHECK(one.GetAheadBehind().m_Behind == 0);

    // A local edit that isn't opened blocks getting latest.
    WriteFile(two, "a.txt", "Uno\ntwo\nthree\n");
    two.Stage("a.txt");
    two.Commit("third");
    WriteFile(one, "a.txt", "ONE\ntwo\nthree\nfour\n");
    CHECK_THROWS_AS(one.Pull("server"), git::GitError);
    CHECK(ReadFile(one, "a.txt") == "ONE\ntwo\nthree\nfour\n");

    // Opened, it merges automatically (different lines).
    one.Stage("a.txt");
    const auto merged = one.Pull("server");
    CHECK(merged.m_Kind == git::MergeResult::Kind::FastForward);
    CHECK(ReadFile(one, "a.txt") == "Uno\ntwo\nthree\nfour\n");
    one.Commit("four");

    // Same line on both sides: a conflict for the 3-pane tool.
    two.Pull("server");
    WriteFile(two, "a.txt", "Uno\ntwo\nthree\nFOUR from two\n");
    two.Stage("a.txt");
    two.Commit("two's four");
    WriteFile(one, "a.txt", "Uno\ntwo\nthree\nfour from one\n");
    one.Stage("a.txt");
    const auto conflicted = one.Pull("server");
    REQUIRE(conflicted.m_Kind == git::MergeResult::Kind::Conflicts);
    REQUIRE(conflicted.m_ConflictedPaths == std::vector<std::string>{"a.txt"});
    CHECK(one.State() == git::RepoState::Merge);
    CHECK(Find(one.Status(), "a.txt")->m_cCode == 'U');
    const git::ConflictFile cf = one.ReadConflict("a.txt");
    bool bsawConflict = false;
    for (const auto& c : cf.m_Chunks)
    {
        if (c.m_bConflict)
        {
            bsawConflict = true;
            CHECK(c.m_Ours == std::vector<std::string>{"four from one"});
            CHECK(c.m_Theirs == std::vector<std::string>{"FOUR from two"});
        }
    }
    CHECK(bsawConflict);
    CHECK_THROWS_AS(one.Commit("too early"), git::GitError);
    WriteFile(one, "a.txt", "Uno\ntwo\nthree\nfour from both\n");
    one.Stage("a.txt");
    CHECK(one.State() == git::RepoState::None);
    one.Commit("resolved");
    CHECK(one.Status().empty());
}

TEST_CASE("p4 streams as branches: create, switch, merge", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    git::Repository repo = server.Workspace("ws1", "//proj/main", true);
    CommitFile(repo, "a.txt", "one\ntwo\nthree\n", "first");

    repo.CreateBranch("dev");
    auto branches = repo.Branches();
    REQUIRE(branches.size() == 2);
    const auto dev = std::find_if(
        branches.begin(), branches.end(), [](const auto& _B) { return _B.m_Name == "dev"; });
    REQUIRE(dev != branches.end());
    CHECK(dev->m_Upstream == "main");
    CHECK_FALSE(dev->m_bIsHead);

    // Switching refuses with open files.
    WriteFile(repo, "a.txt", "edited\n");
    repo.Stage("a.txt");
    CHECK_THROWS_AS(repo.Checkout("dev"), git::GitError);
    repo.DiscardChanges({"a.txt"});

    repo.Checkout("dev");
    CHECK(repo.CurrentBranch() == "dev");
    CommitFile(repo, "a.txt", "one\ntwo\nthree dev\n", "dev change");
    CommitFile(repo, "dev.txt", "only on dev\n", "dev file");
    CHECK(repo.CompareWith("main").m_Ahead == 2);

    repo.Checkout("main");
    CHECK(repo.CurrentBranch() == "main");
    CHECK(ReadFile(repo, "a.txt") == "one\ntwo\nthree\n");
    CHECK_FALSE(fs::exists(fs::u8path(repo.WorkDir()) / "dev.txt"));

    const auto m = repo.Merge("dev");
    CHECK(m.m_Kind == git::MergeResult::Kind::Merged);
    CHECK(ReadFile(repo, "a.txt") == "one\ntwo\nthree dev\n");
    CHECK(fs::exists(fs::u8path(repo.WorkDir()) / "dev.txt"));
    CHECK(repo.Merge("dev").m_Kind == git::MergeResult::Kind::UpToDate);

    // Conflicting merge: stop, abort, nothing left behind.
    repo.Checkout("dev");
    CommitFile(repo, "a.txt", "one\ntwo\nthree DEV2\n", "dev again");
    repo.Checkout("main");
    CommitFile(repo, "a.txt", "one\ntwo\nthree MAIN\n", "main again");
    const auto c = repo.Merge("dev");
    REQUIRE(c.m_Kind == git::MergeResult::Kind::Conflicts);
    CHECK(repo.State() == git::RepoState::Merge);
    repo.AbortMerge();
    CHECK(repo.State() == git::RepoState::None);
    CHECK(repo.Status().empty());
    CHECK(ReadFile(repo, "a.txt") == "one\ntwo\nthree MAIN\n");

    // Resolve one side and commit the merge.
    REQUIRE(repo.Merge("dev").m_Kind == git::MergeResult::Kind::Conflicts);
    repo.ResolveConflict("a.txt", false);
    const std::string merged = repo.Commit("Merge dev, theirs");
    CHECK_FALSE(merged.empty());
    CHECK(ReadFile(repo, "a.txt") == "one\ntwo\nthree DEV2\n");
    CHECK(repo.State() == git::RepoState::None);

    // The file's revision graph spans both streams.
    const git::RevisionGraph g = repo.FileRevisionGraph("a.txt");
    CHECK(g.m_Rows.size() == 2);
    CHECK(g.m_Nodes.size() >= 6);
    CHECK(std::any_of(
        g.m_Edges.begin(), g.m_Edges.end(), [](const auto& _E) { return _E.m_bMerge; }));

    // The graph log chains each branch.
    const auto graph = repo.GraphLog(git::GraphQuery());
    CHECK(graph.size() >= 6);
}

TEST_CASE("p4 shelves as stash, labels as tags, undo, blame", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    git::Repository repo = server.Workspace("ws1", "//proj/main", true);
    const std::string first = CommitFile(repo, "a.txt", "one\ntwo\n", "first");
    const std::string second = CommitFile(repo, "a.txt", "one\ntwo\nthree\n", "second");

    // Stash: edits and new files go to a shelf and leave the workspace.
    WriteFile(repo, "a.txt", "one\nTWO\nthree\n");
    WriteFile(repo, "new.txt", "new\n");
    repo.StashSave("work in progress");
    CHECK(repo.Status().empty());
    CHECK_FALSE(fs::exists(fs::u8path(repo.WorkDir()) / "new.txt"));
    auto stashes = repo.StashList();
    REQUIRE(stashes.size() == 1);
    CHECK(stashes[0].m_Message == "work in progress");
    CHECK(repo.StashDiff(0).size() == 2);
    repo.StashPop(0);
    CHECK(repo.StashList().empty());
    CHECK(ReadFile(repo, "a.txt") == "one\nTWO\nthree\n");
    CHECK(ReadFile(repo, "new.txt") == "new\n");
    repo.DiscardChanges({"a.txt", "new.txt"});
    CHECK(repo.Status().empty());

    // Labels.
    repo.CreateTag("v1", first, "release one");
    auto tags = repo.Tags();
    REQUIRE(tags.size() == 1);
    CHECK(tags[0].m_Name == "v1");
    CHECK(tags[0].m_TargetOid == first);
    CHECK(tags[0].m_Message == "release one");
    std::string text;
    CHECK(repo.ReadFileVersion("a.txt", "v1", text));
    CHECK(text == "one\ntwo\n");
    repo.DeleteTag("v1");
    CHECK(repo.Tags().empty());

    // Blame: committed lines, and an uncommitted one in the workdir.
    WriteFile(repo, "a.txt", "one\ntwo\nthree\nfour\n");
    const git::BlameResult b = repo.Blame("a.txt", "workdir");
    REQUIRE(b.m_Lines.size() == 4);
    REQUIRE(b.m_Hunks.size() == 3);
    CHECK(b.m_Hunks[0].m_Oid == first);
    CHECK(b.m_Hunks[0].m_LineCount == 2);
    CHECK(b.m_Hunks[1].m_Oid == second);
    CHECK(b.m_Hunks[2].m_bUncommitted);
    repo.DiscardChanges({"a.txt"});

    // Revert submits the opposite change.
    const std::string undone = repo.Revert(second);
    CHECK_FALSE(undone.empty());
    CHECK(ReadFile(repo, "a.txt") == "one\ntwo\n");
}

TEST_CASE("p4 classic depot: folders as branches", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    WorkspaceSetup setup;
    setup.m_Port = server.m_Conn.m_Port;
    setup.m_User = "tim";
    setup.m_Client = "classic";
    setup.m_Root = server.Folder("classic");
    setup.m_DepotPath = "//depot/proj/main";
    P4Workspace::Create(setup);
    git::Repository repo = git::Repository::Open(server.Folder("classic"));
    REQUIRE(repo.Backend() == "p4");
    CHECK_FALSE(repo.P4()->UsesStreams());
    CommitFile(repo, "a.txt", "main\n", "first");
    CHECK(repo.CurrentBranch() == "main");

    repo.CreateBranch("feature");
    const auto branches = repo.Branches();
    CHECK(branches.size() == 2);
    repo.Checkout("feature");
    CHECK(repo.CurrentBranch() == "feature");
    CHECK(ReadFile(repo, "a.txt") == "main\n");
    CommitFile(repo, "a.txt", "feature\n", "on feature");
    repo.Checkout("main");
    CHECK(ReadFile(repo, "a.txt") == "main\n");
    CHECK(repo.Merge("feature").m_Kind == git::MergeResult::Kind::Merged);
    CHECK(ReadFile(repo, "a.txt") == "feature\n");
}

TEST_CASE("p4 connects to an existing workspace that has no .p4config", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    {
        git::Repository first = server.Workspace("made-elsewhere", "//proj/main", true);
        CommitFile(first, "a.txt", "a\n", "first");
    }
    // Another client made it: no .p4config in the folder.
    fs::remove(fs::u8path(server.Folder("made-elsewhere")) / ".p4config");
    CHECK_FALSE(P4Workspace::IsWorkspace(server.Folder("made-elsewhere")));

    WorkspaceSetup setup;
    setup.m_Port = server.m_Conn.m_Port;
    setup.m_User = "tim";
    setup.m_Root = server.Folder("made-elsewhere");
    auto ws = P4Workspace::Create(setup);
    CHECK(ws->Conn().m_Client == "made-elsewhere");
    CHECK(P4Workspace::IsWorkspace(server.Folder("made-elsewhere")));
    git::Repository repo = git::Repository::Open(server.Folder("made-elsewhere"));
    CHECK(repo.Log(5).size() == 1);

    // A folder no workspace uses: a clear error, not a new workspace.
    setup.m_Root = server.Folder("unknown");
    CHECK_THROWS_AS(P4Workspace::Create(setup), git::GitError);
}

TEST_CASE("p4 asks for a password when the ticket is missing", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    git::Repository repo = server.Workspace("ws1", "//proj/main", true);
    P4Command::ClearTickets();

    // Without a provider the server's message comes through.
    CHECK_THROWS_AS(repo.Status(), git::GitError);

    // A wrong saved password is reported back as rejected, then given up on
    // (the app's provider erases it and asks the user).
    bool bsawRejected = false;
    repo.SetCredentialProvider(
        [&](const std::string& _Url, const std::string& _User, bool _bRejected, std::string&,
            std::string& _OutPass)
        {
            CHECK(_Url.rfind("p4:", 0) == 0);
            CHECK(_User == "tim");
            bsawRejected = bsawRejected || _bRejected;
            _OutPass = "wrong";
            return !_bRejected;
        });
    CHECK_THROWS_AS(repo.Status(), git::GitError);
    CHECK(bsawRejected);

    int iasked = 0;
    repo.SetCredentialProvider(
        [&](const std::string&, const std::string&, bool, std::string&, std::string& _OutPass)
        {
            ++iasked;
            _OutPass = g_szPassword;
            return true;
        });
    CHECK(repo.Status().empty());
    CHECK(iasked == 1);
    // The ticket is cached: no second question.
    CHECK(repo.Status().empty());
    CHECK(iasked == 1);
}

TEST_CASE("p4 changelists: check out, reopen, shelve, submit a selection", "[p4][server]")
{
    if (!HaveServer())
    {
        SKIP("set GITGUD_TEST_P4D (and GITGUD_P4) to run Perforce server tests");
    }
    TestServer server;
    git::Repository repo = server.Workspace("ws1", "//proj/main", true);
    CommitFile(repo, "a.txt", "a\n", "first");
    CommitFile(repo, "b.txt", "b\n", "second");
    p4::P4Workspace& ws = *repo.P4();

    // Check out an unchanged file; it shows in the default changelist.
    ws.Edit({"a.txt"}, "default");
    auto changes = ws.PendingChanges();
    REQUIRE(changes.size() == 1);
    REQUIRE(changes[0].m_Files.size() == 1);
    CHECK(changes[0].m_Files[0].m_Path == "a.txt");
    CHECK(changes[0].m_Files[0].m_Action == "edit");
    CHECK(ws.RevertUnchanged("") == std::vector<std::string>{"a.txt"});

    // A numbered changelist with two files.
    WriteFile(repo, "a.txt", "a2\n");
    WriteFile(repo, "c.txt", "c\n");
    ws.Edit({"a.txt"}, "default");
    ws.Add({"c.txt"}, "default");
    const std::string cl = ws.CreateChange("Feature work", {"a.txt", "c.txt"});
    changes = ws.PendingChanges();
    REQUIRE(changes.size() == 2);
    CHECK(changes[0].m_Files.empty());
    CHECK(changes[1].m_Change == cl);
    CHECK(changes[1].m_Description == "Feature work");
    CHECK(changes[1].m_Files.size() == 2);
    ws.SetChangeDescription(cl, "Feature work, take two");
    CHECK(ws.PendingChanges()[1].m_Description == "Feature work, take two");

    // Shelve and revert, unshelve back, delete the shelf.
    ws.ShelveChange(cl, {}, true);
    changes = ws.PendingChanges();
    CHECK(changes[1].m_Files.empty());
    CHECK(changes[1].m_Shelved.size() == 2);
    CHECK(ReadFile(repo, "a.txt") == "a\n");
    const git::UnshelveResult u = ws.UnshelveChange(cl, cl, {});
    CHECK(u.m_Applied.size() == 2);
    CHECK(ReadFile(repo, "a.txt") == "a2\n");
    ws.DeleteShelf(cl, {});
    CHECK(ws.PendingChanges()[1].m_Shelved.empty());

    // Submit only a.txt: c.txt moves to the default changelist.
    const std::string submitted = ws.SubmitPending(cl, "Just a", {"a.txt"});
    CHECK_FALSE(submitted.empty());
    changes = ws.PendingChanges();
    REQUIRE(changes.size() == 1);
    REQUIRE(changes[0].m_Files.size() == 1);
    CHECK(changes[0].m_Files[0].m_Path == "c.txt");
    CHECK(repo.Log(1)[0].m_Summary == "Just a");

    // Move, lock, submit from the default changelist; delete and revert.
    ws.Move("b.txt", "sub/b2.txt", "default");
    CHECK(fs::exists(fs::u8path(repo.WorkDir()) / "sub" / "b2.txt"));
    ws.Lock({"c.txt"}, true);
    CHECK(ws.PendingChanges()[0].m_Files.size() == 3);
    ws.SubmitPending("default", "Move and add", {});
    CHECK(ws.PendingChanges()[0].m_Files.empty());
    ws.Delete({"a.txt"}, "default");
    CHECK_FALSE(fs::exists(fs::u8path(repo.WorkDir()) / "a.txt"));
    ws.RevertFiles({"a.txt"}, false);
    CHECK(fs::exists(fs::u8path(repo.WorkDir()) / "a.txt"));

    // Get revision: back to the first change, then latest.
    const std::string first = repo.Log(10).back().m_Oid;
    ws.SyncPaths({}, first);
    CHECK_FALSE(fs::exists(fs::u8path(repo.WorkDir()) / "c.txt"));
    const auto states = ws.FileStates("", false);
    CHECK(std::any_of(states.begin(), states.end(),
        [](const p4::FileState& _S) { return _S.m_iHaveRev < _S.m_iHeadRev; }));
    ws.SyncPaths({}, "");
    CHECK(fs::exists(fs::u8path(repo.WorkDir()) / "c.txt"));
    CHECK(p4::Field(ws.Info(), "userName") == "tim");
}
