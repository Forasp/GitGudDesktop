// Headless tests for the extended engine features: graph layout and
// rendering, the all-branches walk, reflog and branch moves (undo), conflict
// reading (3-pane tool), interactive rebase, file history, blame, worktrees,
// submodule listing, and the process runner. Same throwaway-temp-repo pattern
// as the other test files.

#include <catch2/catch_test_macros.hpp>

#include "git/CommitGraph.h"
#include "git/Repository.h"
#include "imaging/GraphRenderer.h"
#include "platform/Process.h"

#include <git2.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fs = std::filesystem;
using namespace gitgud::git;

namespace
{

    struct TempRepo
    {
        LibGit2 m_Lib;
        fs::path m_Dir;
        Repository m_Repo;

        TempRepo()
        {
            static std::atomic<unsigned> counter{0};
            m_Dir =
                fs::temp_directory_path() / ("gitgud_ft_" + std::to_string(counter++) + "_" +
                                                std::to_string(reinterpret_cast<uintptr_t>(this)));
            fs::remove_all(m_Dir);
            fs::create_directories(m_Dir);
            m_Repo = Repository::Init(m_Dir.string());
            m_Repo.SetConfig("user.name", "Test User");
            m_Repo.SetConfig("user.email", "test@example.com");
            m_Repo.SetConfig("core.autocrlf", "false");
        }

        ~TempRepo()
        {
            m_Repo = Repository();
            std::error_code ec;
            fs::remove_all(m_Dir, ec);
            fs::remove_all(m_Dir.string() + "-wt", ec);
        }

        void Write(const std::string& _Name, const std::string& _Content)
        {
            fs::create_directories((m_Dir / _Name).parent_path());
            std::ofstream(m_Dir / _Name, std::ios::binary) << _Content;
        }

        std::string Read(const std::string& _Name) const
        {
            std::ifstream in(m_Dir / _Name, std::ios::binary);
            std::ostringstream ss;
            ss << in.rdbuf();
            return ss.str();
        }

        std::string CommitAll(const std::string& _Message)
        {
            std::vector<std::string> paths;
            for (const auto& e : m_Repo.Status())
            {
                paths.push_back(e.m_Path);
            }
            m_Repo.Stage(paths);
            return m_Repo.Commit(_Message);
        }

        std::string CommitFile(
            const std::string& _Name, const std::string& _Content, const std::string& _Message)
        {
            Write(_Name, _Content);
            m_Repo.Stage(_Name);
            return m_Repo.Commit(_Message);
        }
    };

} // namespace

// ---------------------------------------------------------------- graph --

TEST_CASE("LayoutGraph keeps a linear history in one lane", "[graph]")
{
    const std::vector<GraphNode> nodes = {{"c", {"b"}}, {"b", {"a"}}, {"a", {}}};
    const auto rows = LayoutGraph(nodes);
    REQUIRE(rows.size() == 3);
    for (const auto& row : rows)
    {
        CHECK(row.m_iLane == 0);
        CHECK(row.m_iLaneCount == 1);
    }
    // The tip has no line coming in from above; the root none going below.
    CHECK(std::none_of(rows[0].m_Edges.begin(), rows[0].m_Edges.end(),
        [](const GraphEdge& _E) { return _E.m_bTop; }));
    CHECK(std::none_of(rows[2].m_Edges.begin(), rows[2].m_Edges.end(),
        [](const GraphEdge& _E) { return !_E.m_bTop; }));
}

TEST_CASE("LayoutGraph forks and merges across lanes", "[graph]")
{
    // m merges f (feature) into b; f and b share parent a.
    const std::vector<GraphNode> nodes = {{"m", {"b", "f"}}, {"f", {"a"}}, {"b", {"a"}}, {"a", {}}};
    const auto rows = LayoutGraph(nodes);
    REQUIRE(rows.size() == 4);
    CHECK(rows[0].m_iLane == 0);
    // The merge's second parent gets its own lane...
    CHECK(rows[1].m_iLane == 1);
    CHECK(rows[2].m_iLane == 0);
    // ...which curves back into lane 0 at their common parent.
    CHECK(rows[3].m_iLane == 0);
    const bool bconverges = std::any_of(rows[3].m_Edges.begin(), rows[3].m_Edges.end(),
        [](const GraphEdge& _E) { return _E.m_bTop && _E.m_iFrom == 1 && _E.m_iTo == 0; });
    CHECK(bconverges);
    CHECK(rows[1].m_iColour != rows[0].m_iColour);
}

TEST_CASE("RenderGraphRows draws visible pixels at the dot", "[graph]")
{
    const std::vector<GraphNode> nodes = {{"b", {"a"}}, {"a", {}}};
    const auto rows = LayoutGraph(nodes);
    gitgud::imaging::GraphStyle style;
    style.m_iLanes = 1;
    const auto img = gitgud::imaging::RenderGraphRows(rows, {}, 0, rows.size(), style);
    REQUIRE(img.m_iWidth == gitgud::imaging::GraphWidth(style));
    REQUIRE(img.m_iHeight == 2 * style.m_iRowHeight);
    const int ix = style.m_iPadding + style.m_iLaneWidth / 2;
    const int iy = style.m_iRowHeight / 2;
    const std::size_t noffset = (static_cast<std::size_t>(iy) * img.m_iWidth + ix) * 4;
    CHECK(img.m_Rgba[noffset + 3] == 255);
    CHECK(img.m_Rgba[3] == 0); // corner stays transparent
}

TEST_CASE("GraphLog walks every branch", "[graph]")
{
    TempRepo t;
    t.CommitFile("a.txt", "a\n", "A");
    const std::string mainBranch = t.m_Repo.CurrentBranch();
    t.m_Repo.CreateBranch("side");
    t.CommitFile("b.txt", "b\n", "B on main");
    t.m_Repo.Checkout("side");
    t.CommitFile("c.txt", "c\n", "C on side");
    t.m_Repo.Checkout(mainBranch);

    CHECK(t.m_Repo.Log(100).size() == 2);
    const auto all = t.m_Repo.GraphLog({});
    CHECK(all.size() == 3);
}

// ----------------------------------------------------------------- undo --

TEST_CASE("Reflog and SetBranchTarget support undo", "[undo]")
{
    TempRepo t;
    const std::string a = t.CommitFile("f.txt", "1\n", "one");
    const std::string b = t.CommitFile("f.txt", "2\n", "two");
    const std::string mainBranch = t.m_Repo.CurrentBranch();
    CHECK(t.m_Repo.HeadOid() == b);

    const auto log = t.m_Repo.Reflog("HEAD", 10);
    REQUIRE(!log.empty());
    CHECK(log[0].m_NewOid == b);
    CHECK(log[0].m_OldOid == a);

    // Undo the commit: move main back, working tree follows.
    t.m_Repo.SetBranchTarget(mainBranch, a);
    CHECK(t.m_Repo.HeadOid() == a);
    CHECK(t.Read("f.txt") == "1\n");

    // A local edit in the way makes it refuse and change nothing.
    t.Write("f.txt", "local\n");
    CHECK_THROWS_AS(t.m_Repo.SetBranchTarget(mainBranch, b), GitError);
    CHECK(t.m_Repo.HeadOid() == a);
    CHECK(t.Read("f.txt") == "local\n");

    // A branch that isn't checked out just moves (or is recreated).
    t.m_Repo.SetBranchTarget("restored", b);
    bool bfound = false;
    for (const auto& br : t.m_Repo.Branches())
    {
        bfound = bfound || (br.m_Name == "restored" && br.m_TargetOid == b);
    }
    CHECK(bfound);
}

// ------------------------------------------------------------ conflicts --

TEST_CASE("ReadConflict splits agreed and contested regions", "[conflict]")
{
    TempRepo t;
    t.CommitFile("f.txt", "top\nmiddle\nbottom\n", "base");
    const std::string mainBranch = t.m_Repo.CurrentBranch();
    t.m_Repo.CreateBranch("other");
    t.CommitFile("f.txt", "top\nOURS\nbottom\n", "ours");
    t.m_Repo.Checkout("other");
    t.CommitFile("f.txt", "top\nTHEIRS\nbottom\n", "theirs");
    t.m_Repo.Checkout(mainBranch);
    const auto merge = t.m_Repo.Merge("other");
    REQUIRE(merge.m_Kind == MergeResult::Kind::Conflicts);

    const auto file = t.m_Repo.ReadConflict("f.txt");
    CHECK_FALSE(file.m_bBinary);
    REQUIRE(file.m_Chunks.size() == 3);
    CHECK_FALSE(file.m_Chunks[0].m_bConflict);
    CHECK(file.m_Chunks[0].m_Lines == std::vector<std::string>{"top"});
    REQUIRE(file.m_Chunks[1].m_bConflict);
    CHECK(file.m_Chunks[1].m_Ours == std::vector<std::string>{"OURS"});
    CHECK(file.m_Chunks[1].m_Theirs == std::vector<std::string>{"THEIRS"});
    CHECK(file.m_Chunks[1].m_Base == std::vector<std::string>{"middle"});
    CHECK(file.m_Chunks[2].m_Lines == std::vector<std::string>{"bottom"});
    CHECK(file.m_bTrailingNewline);

    CHECK_THROWS_AS(t.m_Repo.ReadConflict("nope.txt"), GitError);
}

// --------------------------------------------------- interactive rebase --

namespace
{

    // Three commits on top of a base; returns {base, c1, c2, c3}.
    std::vector<std::string> ThreeCommits(TempRepo& _T)
    {
        const std::string base = _T.CommitFile("base.txt", "base\n", "base");
        const std::string c1 = _T.CommitFile("one.txt", "1\n", "one");
        const std::string c2 = _T.CommitFile("two.txt", "2\n", "two");
        const std::string c3 = _T.CommitFile("three.txt", "3\n", "three");
        return {base, c1, c2, c3};
    }

    std::vector<std::string> Summaries(Repository& _R)
    {
        std::vector<std::string> out;
        for (const auto& c : _R.Log(100))
        {
            out.push_back(c.m_Summary);
        }
        return out;
    }

    RebaseStep Step(RebaseStep::Action _A, const std::string& _Oid, const std::string& _Msg = "")
    {
        RebaseStep s;
        s.m_Action = _A;
        s.m_Oid = _Oid;
        s.m_Message = _Msg;
        return s;
    }

} // namespace

TEST_CASE("RebaseTodo lists the commits after the base, oldest first", "[rebase]")
{
    TempRepo t;
    const auto ids = ThreeCommits(t);
    const auto todo = t.m_Repo.RebaseTodo(ids[0]);
    REQUIRE(todo.size() == 3);
    CHECK(todo[0].m_Oid == ids[1]);
    CHECK(todo[2].m_Oid == ids[3]);
    CHECK(t.m_Repo.RebaseTodo(ids[3]).empty());
}

TEST_CASE("InteractiveRebase reorders, rewords, squashes and drops", "[rebase]")
{
    TempRepo t;
    const auto ids = ThreeCommits(t);
    using A = RebaseStep::Action;

    const auto result = t.m_Repo.InteractiveRebase(ids[0],
        {Step(A::Pick, ids[3]), Step(A::Reword, ids[1], "ONE renamed\n"), Step(A::Squash, ids[2])});
    CHECK(result.m_Kind == RebaseResult::Kind::Done);

    const auto summaries = Summaries(t.m_Repo);
    REQUIRE(summaries.size() == 3);
    CHECK(summaries[0] == "ONE renamed");
    CHECK(summaries[1] == "three");
    CHECK(summaries[2] == "base");
    // The squashed commit carries both changes and both messages.
    const auto head = t.m_Repo.Log(1)[0];
    CHECK(head.m_Message.find("two") != std::string::npos);
    CHECK(t.Read("two.txt") == "2\n");
    CHECK(t.Read("one.txt") == "1\n");

    // Drop removes the commit and its file.
    const auto todo = t.m_Repo.RebaseTodo(ids[0]);
    REQUIRE(todo.size() == 2);
    const auto dropped = t.m_Repo.InteractiveRebase(
        ids[0], {Step(A::Drop, todo[0].m_Oid), Step(A::Pick, todo[1].m_Oid)});
    CHECK(dropped.m_Kind == RebaseResult::Kind::Done);
    CHECK_FALSE(fs::exists(t.m_Dir / "three.txt"));
    CHECK(Summaries(t.m_Repo).size() == 2);
}

TEST_CASE("InteractiveRebase keeps unchanged commits and refuses bad plans", "[rebase]")
{
    TempRepo t;
    const auto ids = ThreeCommits(t);
    using A = RebaseStep::Action;

    // An all-pick plan in the same order changes nothing.
    const auto same = t.m_Repo.InteractiveRebase(
        ids[0], {Step(A::Pick, ids[1]), Step(A::Pick, ids[2]), Step(A::Pick, ids[3])});
    CHECK(same.m_Kind == RebaseResult::Kind::UpToDate);
    CHECK(t.m_Repo.HeadOid() == ids[3]);

    CHECK_THROWS_AS(t.m_Repo.InteractiveRebase(ids[0], {Step(A::Pick, ids[1])}), GitError);
    CHECK_THROWS_AS(t.m_Repo.InteractiveRebase(ids[0],
                        {Step(A::Fixup, ids[1]), Step(A::Pick, ids[2]), Step(A::Pick, ids[3])}),
        GitError);
}

TEST_CASE("InteractiveRebase stops on a conflict without changing anything", "[rebase]")
{
    TempRepo t;
    const std::string base = t.CommitFile("f.txt", "a\n", "base");
    const std::string c1 = t.CommitFile("f.txt", "b\n", "to b");
    const std::string c2 = t.CommitFile("f.txt", "c\n", "to c");
    using A = RebaseStep::Action;

    // c2 depends on c1: putting it first can't apply.
    const auto result = t.m_Repo.InteractiveRebase(base, {Step(A::Pick, c2), Step(A::Pick, c1)});
    CHECK(result.m_Kind == RebaseResult::Kind::Conflicts);
    CHECK(t.m_Repo.HeadOid() == c2);
    CHECK(t.Read("f.txt") == "c\n");
    CHECK(t.m_Repo.State() == RepoState::None);
}

// --------------------------------------------------- file history, blame --

TEST_CASE("FileLog lists only commits that touched the file", "[history]")
{
    TempRepo t;
    const std::string a = t.CommitFile("f.txt", "1\n", "f one");
    t.CommitFile("g.txt", "x\n", "g only");
    const std::string c = t.CommitFile("f.txt", "2\n", "f two");

    const auto log = t.m_Repo.FileLog("f.txt", 50);
    REQUIRE(log.size() == 2);
    CHECK(log[0].m_Oid == c);
    CHECK(log[1].m_Oid == a);

    DiffOptions only;
    only.m_Paths = {"f.txt"};
    const auto files = t.m_Repo.DiffCommit(c, only);
    REQUIRE(files.size() == 1);
    CHECK(files[0].m_Path == "f.txt");
}

TEST_CASE("Blame attributes lines to commits and marks local edits", "[history]")
{
    TempRepo t;
    const std::string a = t.CommitFile("f.txt", "one\ntwo\n", "first");
    const std::string b = t.CommitFile("f.txt", "one\nTWO\nthree\n", "second");

    const auto committed = t.m_Repo.Blame("f.txt", b);
    REQUIRE(committed.m_Lines.size() == 3);
    REQUIRE(!committed.m_Hunks.empty());
    CHECK(committed.m_Hunks[0].m_Oid == a);
    CHECK(committed.m_Hunks[0].m_StartLine == 1);
    CHECK(committed.m_Hunks[0].m_Summary == "first");

    t.Write("f.txt", "one\nTWO\nthree\nfour\n");
    const auto working = t.m_Repo.Blame("f.txt", "workdir");
    REQUIRE(working.m_Lines.size() == 4);
    CHECK(working.m_Hunks.back().m_bUncommitted);

    t.Write("new.txt", "fresh\n");
    const auto fresh = t.m_Repo.Blame("new.txt", "workdir");
    REQUIRE(fresh.m_Hunks.size() == 1);
    CHECK(fresh.m_Hunks[0].m_bUncommitted);
}

// ------------------------------------------------- worktrees, submodules --

TEST_CASE("Worktrees can be added, listed, and removed", "[worktree]")
{
    TempRepo t;
    t.CommitFile("f.txt", "1\n", "one");
    const std::string wtPath = t.m_Dir.string() + "-wt";
    fs::remove_all(wtPath);

    t.m_Repo.AddWorktree("feature", wtPath, "feature");
    auto trees = t.m_Repo.Worktrees();
    REQUIRE(trees.size() == 2);
    CHECK(trees[0].m_bMain);
    CHECK(trees[0].m_Branch == t.m_Repo.CurrentBranch());
    CHECK(trees[1].m_Name == "feature");
    CHECK(trees[1].m_Branch == "feature");
    CHECK(fs::exists(fs::u8path(wtPath) / "f.txt"));

    // Uncommitted work in it blocks removal.
    std::ofstream(fs::u8path(wtPath) / "f.txt", std::ios::binary) << "dirty\n";
    CHECK_THROWS_AS(t.m_Repo.RemoveWorktree("feature"), GitError);
    fs::remove(fs::u8path(wtPath) / "f.txt");
    {
        Repository wt = Repository::Open(wtPath);
        wt.DiscardChanges({"f.txt"});
    }
    t.m_Repo.RemoveWorktree("feature");
    CHECK(t.m_Repo.Worktrees().size() == 1);
    CHECK_FALSE(fs::exists(wtPath));
}

TEST_CASE("Checking out a branch held by another worktree changes nothing", "[worktree]")
{
    TempRepo t;
    t.CommitFile("f.txt", "1\n", "one");
    const std::string start = t.m_Repo.CurrentBranch();
    const std::string wtPath = t.m_Dir.string() + "-wt";
    fs::remove_all(wtPath);

    // "held" differs from the current branch in f.txt.
    t.m_Repo.CreateBranch("held");
    t.m_Repo.Checkout("held");
    t.CommitFile("f.txt", "2\n", "two");
    t.m_Repo.Checkout(start);
    t.m_Repo.AddWorktree("held", wtPath, "held");

    try
    {
        t.m_Repo.Checkout("held");
        FAIL("the checkout should have been refused");
    }
    catch (const GitError& e)
    {
        CHECK(std::string(e.what()).find("another worktree") != std::string::npos);
    }
    CHECK(t.m_Repo.CurrentBranch() == start);
    CHECK(t.m_Repo.Status().empty());

    t.m_Repo.RemoveWorktree("held");
}

TEST_CASE("Submodules lists nothing for a plain repository", "[submodule]")
{
    TempRepo t;
    t.CommitFile("f.txt", "1\n", "one");
    CHECK(t.m_Repo.Submodules().empty());
}

// ------------------------------------------------ SSH, signing, Git LFS --

TEST_CASE("libgit2 is built with SSH support", "[ssh]")
{
    LibGit2 lib;
    CHECK((git_libgit2_features() & GIT_FEATURE_SSH) != 0);
}

namespace
{

    // The raw header field of HEAD's commit ("" when absent).
    std::string HeadHeader(const fs::path& _Dir, const char* _szField)
    {
        git_repository* prepo = nullptr;
        if (git_repository_open(&prepo, _Dir.string().c_str()) < 0)
        {
            return {};
        }
        std::string out;
        git_oid oid;
        git_commit* pcommit = nullptr;
        if (git_reference_name_to_id(&oid, prepo, "HEAD") == 0 &&
            git_commit_lookup(&pcommit, prepo, &oid) == 0)
        {
            git_buf buf = GIT_BUF_INIT;
            if (git_commit_header_field(&buf, pcommit, _szField) == 0)
            {
                out.assign(buf.ptr, buf.size);
            }
            git_buf_dispose(&buf);
            git_commit_free(pcommit);
        }
        git_repository_free(prepo);
        return out;
    }

} // namespace

TEST_CASE("Commits are signed with an SSH key when configured", "[signing]")
{
    if (gitgud::platform::FindProgram("ssh-keygen").empty())
    {
        SKIP("ssh-keygen isn't installed");
    }
    TempRepo t;
    const fs::path key = t.m_Dir.parent_path() / (t.m_Dir.filename().string() + "-signkey");
    fs::remove(key);
    fs::remove(fs::path(key.string() + ".pub"));
    const auto keygen = gitgud::platform::RunProcess(
        {"ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", key.string()}, "");
    REQUIRE(keygen.m_bStarted);
    REQUIRE(keygen.m_iExitCode == 0);

    t.m_Repo.SetConfig("gpg.format", "ssh");
    t.m_Repo.SetConfig("user.signingkey", key.string());
    t.m_Repo.SetConfig("commit.gpgsign", "true");

    t.CommitFile("a.txt", "a\n", "signed one");
    CHECK(HeadHeader(t.m_Dir, "gpgsig").find("BEGIN SSH SIGNATURE") != std::string::npos);
    CHECK(t.m_Repo.Log(1)[0].m_Summary == "signed one");

    // Amend and the interactive rebase sign too.
    t.Write("a.txt", "b\n");
    t.m_Repo.Stage("a.txt");
    t.m_Repo.AmendCommit("signed amend");
    CHECK(HeadHeader(t.m_Dir, "gpgsig").find("BEGIN SSH SIGNATURE") != std::string::npos);

    const std::string base = t.m_Repo.HeadOid();
    const std::string c1 = t.CommitFile("b.txt", "1\n", "one");
    const std::string c2 = t.CommitFile("c.txt", "2\n", "two");
    RebaseStep s1;
    s1.m_Oid = c2;
    RebaseStep s2;
    s2.m_Oid = c1;
    REQUIRE(t.m_Repo.InteractiveRebase(base, {s1, s2}).m_Kind == RebaseResult::Kind::Done);
    CHECK(HeadHeader(t.m_Dir, "gpgsig").find("BEGIN SSH SIGNATURE") != std::string::npos);

    // A broken key fails the commit loudly instead of committing unsigned.
    t.m_Repo.SetConfig("user.signingkey", key.string() + "-missing");
    t.Write("d.txt", "d\n");
    t.m_Repo.Stage("d.txt");
    CHECK_THROWS_AS(t.m_Repo.Commit("should fail"), GitError);
    CHECK(t.m_Repo.Log(1)[0].m_Summary == "one");

    fs::remove(key);
    fs::remove(fs::path(key.string() + ".pub"));
}

TEST_CASE("Git LFS files are stored as pointers and restored on checkout", "[lfs]")
{
    TempRepo t;
    if (!Repository::LfsAvailable())
    {
        SKIP("git-lfs isn't installed");
    }
    t.CommitFile(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n", "track bins");

    std::string big(200000, 'x');
    for (std::size_t i = 0; i < big.size(); i += 97)
    {
        big[i] = static_cast<char>('a' + (i % 26));
    }
    t.Write("data.bin", big);
    t.m_Repo.Stage("data.bin");

    std::string staged;
    REQUIRE(t.m_Repo.ReadFileVersion("data.bin", "index", staged));
    CHECK(staged.rfind("version https://git-lfs.github.com/spec/v1", 0) == 0);
    CHECK(staged.size() < 300);
    t.m_Repo.Commit("add data");

    // Throw the working copy away; checkout brings the real bytes back.
    t.Write("data.bin", "scribbled over\n");
    t.m_Repo.DiscardChanges({"data.bin"});
    CHECK(t.Read("data.bin") == big);
}

// ---------------------------------------------------------------- process --

TEST_CASE("RunProcess captures output and feeds stdin", "[process]")
{
#if defined(_WIN32)
    const auto echo = gitgud::platform::RunProcess({"cmd.exe", "/c", "echo hello"}, "");
#else
    const auto echo = gitgud::platform::RunProcess({"sh", "-c", "echo hello"}, "");
#endif
    REQUIRE(echo.m_bStarted);
    CHECK(echo.m_iExitCode == 0);
    CHECK(echo.m_Output.find("hello") != std::string::npos);

#if defined(_WIN32)
    const auto sorted = gitgud::platform::RunProcess({"sort.exe"}, "", "b\r\na\r\n");
#else
    const auto sorted = gitgud::platform::RunProcess({"sort"}, "", "b\na\n");
#endif
    REQUIRE(sorted.m_bStarted);
    CHECK(sorted.m_Output.find("a") < sorted.m_Output.find("b"));

    const auto missing = gitgud::platform::RunProcess({"definitely-not-a-program-xyz"}, "");
    CHECK_FALSE(missing.m_bStarted);

    std::string streamed;
    const int icode = gitgud::platform::RunShellStreaming(
        "echo one && echo two", "", [&](const std::string& _S) { streamed += _S; }, nullptr);
    CHECK(icode == 0);
    CHECK(streamed.find("one") != std::string::npos);
    CHECK(streamed.find("two") != std::string::npos);

    CHECK(gitgud::platform::QuoteArgument("a b") == "\"a b\"");
    CHECK(gitgud::platform::QuoteArgument("plain") == "plain");
}
