// Headless tests for the core engine surface: line-level
// staging, discarding, amend/undo, revert, cherry-pick, reset, tags, squash
// merge, rebase, conflict resolution, file versions, and the image diff.
// Same throwaway-temp-repo pattern as test_engine_extended.cpp.

#include <catch2/catch_test_macros.hpp>

#include "git/Repository.h"
#include "imaging/ImageDiff.h"

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
                fs::temp_directory_path() / ("gitgud_wf_" + std::to_string(counter++) + "_" +
                                                std::to_string(reinterpret_cast<uintptr_t>(this)));
            fs::create_directories(m_Dir);
            m_Repo = Repository::Init(m_Dir.string());
            m_Repo.SetConfig("user.name", "Test User");
            m_Repo.SetConfig("user.email", "test@example.com");
            // Byte-exact expectations below; the CRLF case has its own test.
            m_Repo.SetConfig("core.autocrlf", "false");
        }

        ~TempRepo()
        {
            m_Repo = Repository();
            std::error_code ec;
            fs::remove_all(m_Dir, ec);
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

        std::string IndexVersion(const std::string& _Path) const
        {
            std::string out;
            m_Repo.ReadFileVersion(_Path, "index", out);
            return out;
        }
    };

    // Flat indices (0-based) of changed lines in the combined diff.
    std::vector<std::size_t> ChangedLines(const FileDiff& _Diff, char _cOrigin)
    {
        std::vector<std::size_t> out;
        std::size_t i = 0;
        for (const auto& h : _Diff.m_Hunks)
        {
            for (const auto& l : h.m_Lines)
            {
                if (l.m_cOrigin == _cOrigin)
                {
                    out.push_back(i);
                }
                ++i;
            }
        }
        return out;
    }

    std::size_t LineCount(const FileDiff& _Diff)
    {
        std::size_t n = 0;
        for (const auto& h : _Diff.m_Hunks)
        {
            n += h.m_Lines.size();
        }
        return n;
    }

    // Twenty numbered lines; line 2 and line 15 can be swapped out (and an
    // extra line inserted after 15). Edits that far apart diff as two hunks.
    std::string Lines(const std::string& _Second = "l2", const std::string& _Fifteenth = "l15",
        const std::string& _AfterFifteenth = "")
    {
        std::string out;
        for (int i = 1; i <= 20; ++i)
        {
            std::string line = "l" + std::to_string(i);
            if (i == 2)
            {
                line = _Second;
            }
            if (i == 15)
            {
                line = _Fifteenth;
            }
            out += line + "\n";
            if (i == 15 && !_AfterFifteenth.empty())
            {
                out += _AfterFifteenth + "\n";
            }
        }
        return out;
    }

} // namespace

TEST_CASE("Batch stage and unstage touch every path", "[staging]")
{
    TempRepo t;
    t.Write("a.txt", "a\n");
    t.Write("b.txt", "b\n");
    t.m_Repo.Stage(std::vector<std::string>{"a.txt", "b.txt"});
    for (const auto& e : t.m_Repo.Status())
    {
        REQUIRE(e.m_bStaged);
    }
    t.m_Repo.Unstage(std::vector<std::string>{"a.txt", "b.txt"});
    for (const auto& e : t.m_Repo.Status())
    {
        REQUIRE_FALSE(e.m_bStaged);
    }
}

TEST_CASE("Line-level staging stages exactly the chosen lines", "[staging]")
{
    TempRepo t;
    t.Write("f.txt", Lines());
    t.CommitAll("base");

    t.Write("f.txt", Lines("L2", "L15"));
    const FileDiff combined = t.m_Repo.DiffFile("f.txt", DiffTarget::Head);
    REQUIRE(combined.m_Hunks.size() == 2);
    REQUIRE(t.m_Repo.StagedLines("f.txt").empty());

    // Stage only the first hunk's '-' and '+' lines.
    const auto minus = ChangedLines(combined, '-');
    const auto plus = ChangedLines(combined, '+');
    REQUIRE(minus.size() == 2);
    REQUIRE(plus.size() == 2);
    t.m_Repo.SetStagedLines("f.txt", {minus[0], plus[0]}, LineCount(combined));

    REQUIRE(t.IndexVersion("f.txt") == Lines("L2"));
    const auto staged = t.m_Repo.StagedLines("f.txt");
    REQUIRE(staged == std::vector<std::size_t>{minus[0], plus[0]});

    // Only the '+' of the second change: the old line stays, the new one is added.
    t.m_Repo.SetStagedLines("f.txt", {plus[1]}, LineCount(combined));
    REQUIRE(t.IndexVersion("f.txt") == Lines("l2", "l15", "L15"));

    // A stale line count is refused instead of staging the wrong lines.
    REQUIRE_THROWS_AS(t.m_Repo.SetStagedLines("f.txt", {plus[0]}, 999), GitError);

    // The whole file staged: every changed line reads as staged.
    t.m_Repo.Stage("f.txt");
    const auto all = t.m_Repo.StagedLines("f.txt");
    REQUIRE(all == std::vector<std::size_t>{minus[0], plus[0], minus[1], plus[1]});
}

TEST_CASE("Line staging of a new file, and unstaging it back to untracked", "[staging]")
{
    TempRepo t;
    t.Write("keep.txt", "x\n");
    t.CommitAll("base");

    t.Write("new.txt", "one\ntwo\n");
    const FileDiff combined = t.m_Repo.DiffFile("new.txt", DiffTarget::Head);
    const auto plus = ChangedLines(combined, '+');
    REQUIRE(plus.size() == 2);

    t.m_Repo.SetStagedLines("new.txt", {plus[1]}, LineCount(combined));
    REQUIRE(t.IndexVersion("new.txt") == "two\n");

    t.m_Repo.SetStagedLines("new.txt", {}, LineCount(combined));
    std::string dummy;
    REQUIRE_FALSE(t.m_Repo.ReadFileVersion("new.txt", "index", dummy));
}

TEST_CASE("DiscardLines reverts only the chosen change", "[staging]")
{
    TempRepo t;
    t.Write("f.txt", Lines());
    t.CommitAll("base");
    t.Write("f.txt", Lines("L2", "L15"));

    const FileDiff combined = t.m_Repo.DiffFile("f.txt", DiffTarget::Head);
    const auto minus = ChangedLines(combined, '-');
    const auto plus = ChangedLines(combined, '+');
    t.m_Repo.DiscardLines("f.txt", {minus[1], plus[1]}, LineCount(combined));

    REQUIRE(t.Read("f.txt") == Lines("L2"));
}

TEST_CASE("Line staging normalizes CRLF working files (core.autocrlf=true)", "[staging]")
{
    TempRepo t;
    t.m_Repo.SetConfig("core.autocrlf", "true");
    t.Write("f.txt", Lines());
    t.CommitAll("base");

    // A Windows-style working copy with one real edit.
    std::string crlf;
    for (char c : Lines("L2"))
    {
        if (c == '\n')
        {
            crlf += '\r';
        }
        crlf += c;
    }
    t.Write("f.txt", crlf);

    const FileDiff combined = t.m_Repo.DiffFile("f.txt", DiffTarget::Head);
    REQUIRE(combined.m_Hunks.size() == 1); // the edit, not every line ending
    const auto minus = ChangedLines(combined, '-');
    const auto plus = ChangedLines(combined, '+');
    t.m_Repo.SetStagedLines("f.txt", {minus[0], plus[0]}, LineCount(combined));

    // The index gets repository-normalized (LF) content.
    REQUIRE(t.IndexVersion("f.txt") == Lines("L2"));
}

TEST_CASE("DiscardChanges restores tracked files and removes new ones", "[staging]")
{
    TempRepo t;
    t.Write("tracked.txt", "original\n");
    t.CommitAll("base");

    t.Write("tracked.txt", "edited\n");
    t.m_Repo.Stage("tracked.txt");
    t.Write("tracked.txt", "edited again\n");
    t.Write("fresh.txt", "brand new\n");

    t.m_Repo.DiscardChanges({"tracked.txt", "fresh.txt"});
    REQUIRE(t.Read("tracked.txt") == "original\n");
    REQUIRE_FALSE(fs::exists(t.m_Dir / "fresh.txt"));
    REQUIRE(t.m_Repo.Status().empty());
}

TEST_CASE("Amend replaces the message; undo restores the changes staged", "[commit]")
{
    TempRepo t;
    t.Write("a.txt", "1\n");
    t.CommitAll("first");
    t.Write("a.txt", "2\n");
    t.CommitAll("second (typo)");

    t.m_Repo.AmendCommit("second");
    auto log = t.m_Repo.Log(10);
    REQUIRE(log.size() == 2);
    REQUIRE(log[0].m_Summary == "second");

    const std::string message = t.m_Repo.UndoLastCommit();
    REQUIRE(message.rfind("second", 0) == 0);
    REQUIRE(t.m_Repo.Log(10).size() == 1);
    const auto status = t.m_Repo.Status();
    REQUIRE(status.size() == 1);
    REQUIRE(status[0].m_bStaged);
    REQUIRE(t.IndexVersion("a.txt") == "2\n");
}

TEST_CASE("Undoing the root commit leaves an unborn branch with everything staged", "[commit]")
{
    TempRepo t;
    t.Write("a.txt", "1\n");
    t.CommitAll("root");
    t.m_Repo.UndoLastCommit();
    REQUIRE(t.m_Repo.Log(10).empty());
    REQUIRE(t.IndexVersion("a.txt") == "1\n");
}

TEST_CASE("Revert and cherry-pick create the expected commits", "[history]")
{
    TempRepo t;
    t.Write("a.txt", "base\n");
    t.CommitAll("base");
    const std::string main = t.m_Repo.CurrentBranch();

    t.m_Repo.CreateBranch("feature");
    t.m_Repo.Checkout("feature");
    t.Write("b.txt", "feature work\n");
    const std::string featureCommit = t.CommitAll("add b");
    t.m_Repo.Checkout(main);
    REQUIRE_FALSE(fs::exists(t.m_Dir / "b.txt"));

    const std::string picked = t.m_Repo.CherryPick(featureCommit);
    REQUIRE_FALSE(picked.empty());
    REQUIRE(t.Read("b.txt") == "feature work\n");
    REQUIRE(t.m_Repo.Log(1)[0].m_Summary == "add b");

    const std::string reverted = t.m_Repo.Revert(picked);
    REQUIRE_FALSE(reverted.empty());
    REQUIRE_FALSE(fs::exists(t.m_Dir / "b.txt"));
    REQUIRE(t.m_Repo.Log(1)[0].m_Summary == "Revert \"add b\"");
    REQUIRE(t.m_Repo.State() == RepoState::None);
}

TEST_CASE("Reset, detached checkout, and branch-from-commit", "[history]")
{
    TempRepo t;
    t.Write("a.txt", "1\n");
    const std::string first = t.CommitAll("first");
    t.Write("a.txt", "2\n");
    t.CommitAll("second");

    t.m_Repo.CreateBranch("from-first", first);
    REQUIRE(t.m_Repo.CompareWith("from-first").m_Ahead == 1);

    t.m_Repo.ResetTo(first, ResetMode::Mixed);
    REQUIRE(t.m_Repo.Log(10).size() == 1);
    REQUIRE(t.Read("a.txt") == "2\n"); // mixed keeps the working tree
    t.m_Repo.DiscardChanges({"a.txt"});

    t.m_Repo.CheckoutCommit(first);
    REQUIRE(t.m_Repo.CurrentBranch().empty()); // detached
}

TEST_CASE("Tags: lightweight and annotated, listed and deleted", "[tags]")
{
    TempRepo t;
    t.Write("a.txt", "1\n");
    const std::string oid = t.CommitAll("first");

    t.m_Repo.CreateTag("v1", "HEAD");
    t.m_Repo.CreateTag("v1-annotated", oid, "Release one");
    auto tags = t.m_Repo.Tags();
    REQUIRE(tags.size() == 2);
    for (const auto& tag : tags)
    {
        REQUIRE(tag.m_TargetOid == oid);
        if (tag.m_Name == "v1-annotated")
        {
            REQUIRE(tag.m_Message.rfind("Release one", 0) == 0);
        }
    }

    const auto labels = t.m_Repo.RefLabels();
    REQUIRE(std::any_of(labels.begin(), labels.end(),
        [](const RefLabel& _L) { return _L.m_cKind == 't' && _L.m_Name == "v1"; }));

    t.m_Repo.DeleteTag("v1");
    REQUIRE(t.m_Repo.Tags().size() == 1);
}

TEST_CASE("Squash merge folds a branch into one single-parent commit", "[merge]")
{
    TempRepo t;
    t.Write("a.txt", "base\n");
    t.CommitAll("base");
    const std::string main = t.m_Repo.CurrentBranch();

    t.m_Repo.CreateBranch("topic");
    t.m_Repo.Checkout("topic");
    t.Write("b.txt", "1\n");
    t.CommitAll("topic 1");
    t.Write("c.txt", "2\n");
    t.CommitAll("topic 2");
    t.m_Repo.Checkout(main);

    const MergeResult result = t.m_Repo.SquashMerge("topic");
    REQUIRE(result.m_Kind == MergeResult::Kind::Merged);
    const auto head = t.m_Repo.Log(1)[0];
    REQUIRE(head.m_Parents.size() == 1);
    REQUIRE(head.m_Message.find("* topic 1") != std::string::npos);
    REQUIRE(fs::exists(t.m_Dir / "b.txt"));
    REQUIRE(fs::exists(t.m_Dir / "c.txt"));
}

TEST_CASE("Rebase replays the current branch onto another", "[rebase]")
{
    TempRepo t;
    t.Write("a.txt", "base\n");
    t.CommitAll("base");
    const std::string main = t.m_Repo.CurrentBranch();

    t.m_Repo.CreateBranch("topic");
    t.Write("main.txt", "main side\n");
    t.CommitAll("main work");

    t.m_Repo.Checkout("topic");
    t.Write("topic.txt", "topic side\n");
    t.CommitAll("topic work");

    const RebaseResult result = t.m_Repo.Rebase(main);
    REQUIRE(result.m_Kind == RebaseResult::Kind::Done);
    const auto log = t.m_Repo.Log(10);
    REQUIRE(log.size() == 3);
    REQUIRE(log[0].m_Summary == "topic work");
    REQUIRE(log[1].m_Summary == "main work");
    REQUIRE(t.m_Repo.CurrentBranch() == "topic");
    REQUIRE(t.m_Repo.State() == RepoState::None);
}

TEST_CASE("Conflicts resolve to either side", "[merge]")
{
    TempRepo t;
    t.Write("c.txt", "base\n");
    t.CommitAll("base");
    const std::string main = t.m_Repo.CurrentBranch();

    t.m_Repo.CreateBranch("other");
    t.Write("c.txt", "ours\n");
    t.CommitAll("ours");
    t.m_Repo.Checkout("other");
    t.Write("c.txt", "theirs\n");
    t.CommitAll("theirs");
    t.m_Repo.Checkout(main);

    const MergeResult merge = t.m_Repo.Merge("other");
    REQUIRE(merge.m_Kind == MergeResult::Kind::Conflicts);
    REQUIRE(t.m_Repo.State() == RepoState::Merge);

    t.m_Repo.ResolveConflict("c.txt", /*ours=*/false);
    REQUIRE(t.Read("c.txt") == "theirs\n");
    REQUIRE(t.m_Repo.ConflictedPaths().empty());
    t.m_Repo.Commit("Merge other");
    REQUIRE(t.m_Repo.State() == RepoState::None);
    REQUIRE(t.m_Repo.Log(1)[0].m_Parents.size() == 2);
}

TEST_CASE("File versions and paged, filtered history", "[history]")
{
    TempRepo t;
    t.Write("a.txt", "v1\n");
    const std::string first = t.CommitAll("one");
    t.Write("a.txt", "v2\n");
    t.CommitAll("two");
    t.Write("a.txt", "v3\n");

    std::string content;
    REQUIRE(t.m_Repo.ReadFileVersion("a.txt", "head", content));
    REQUIRE(content == "v2\n");
    REQUIRE(t.m_Repo.ReadFileVersion("a.txt", "workdir", content));
    REQUIRE(content == "v3\n");
    REQUIRE(t.m_Repo.ReadFileVersion("a.txt", first, content));
    REQUIRE(content == "v1\n");
    REQUIRE_FALSE(t.m_Repo.ReadFileVersion("a.txt", first + "^", content)); // no parent

    LogQuery page;
    page.m_MaxCount = 1;
    page.m_Skip = 1;
    const auto second = t.m_Repo.Log(page);
    REQUIRE(second.size() == 1);
    REQUIRE(second[0].m_Summary == "one");

    LogQuery hidden;
    hidden.m_Hide = first;
    REQUIRE(t.m_Repo.Log(hidden).size() == 1);
}

TEST_CASE("Repository config round-trips", "[config]")
{
    TempRepo t;
    t.m_Repo.SetConfig("gitgud.test", "hello");
    REQUIRE(t.m_Repo.GetConfig("gitgud.test") == "hello");
    t.m_Repo.SetConfig("gitgud.test", "");
    REQUIRE(t.m_Repo.GetConfig("gitgud.test").empty());
}

TEST_CASE("Image comparison counts and highlights changed pixels", "[imaging]")
{
    using namespace gitgud::imaging;

    Image before;
    before.m_iWidth = 2;
    before.m_iHeight = 2;
    before.m_Rgba.assign(16, 255); // white, opaque

    Image after = before;
    after.m_Rgba[0] = 0; // top-left pixel: red channel changes

    Comparison cmp = Compare(before, after, 0xFF00FF);
    REQUIRE(cmp.m_TotalPixels == 4);
    REQUIRE(cmp.m_ChangedPixels == 1);
    REQUIRE(cmp.m_Difference.m_iWidth == 2);
    // The changed pixel is painted in the highlight hue (red + blue, no green).
    REQUIRE(cmp.m_Difference.m_Rgba[0] > 100);
    REQUIRE(cmp.m_Difference.m_Rgba[1] == 0);

    // A size change counts the uncovered area as changed.
    Image wider;
    wider.m_iWidth = 3;
    wider.m_iHeight = 2;
    wider.m_Rgba.assign(24, 255);
    cmp = Compare(before, wider, 0xFF00FF);
    REQUIRE(cmp.m_TotalPixels == 6);
    REQUIRE(cmp.m_ChangedPixels == 2);

    REQUIRE(IsImagePath("art/Logo.PNG"));
    REQUIRE_FALSE(IsImagePath("main.lua"));
}
