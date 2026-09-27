// Headless tests for the wider engine surface: hunk staging, Branches,
// history, remotes, stash, and merge. Same throwaway-temp-repo pattern as
// test_repository.cpp.

#include <catch2/catch_test_macros.hpp>

#include "git/Repository.h"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;
using namespace gitgud::git;

namespace
{

    struct TempRepo
    {
        LibGit2 lib;
        fs::path dir;

        TempRepo()
        {
            static std::atomic<unsigned> counter{0};
            dir =
                fs::temp_directory_path() / ("gitgud_ext_" + std::to_string(counter++) + "_" +
                                                std::to_string(reinterpret_cast<uintptr_t>(this)));
            fs::create_directories(dir);
        }

        ~TempRepo()
        {
            std::error_code ec;
            fs::remove_all(dir, ec);
        }

        Repository Init()
        {
            return Repository::Init(dir.string());
        }

        void write(const std::string& name, const std::string& content)
        {
            std::ofstream(dir / name, std::ios::binary) << content;
        }

        std::string Commit(Repository& r, const std::string& msg)
        {
            return r.Commit(msg, "Test User", "test@example.com");
        }
    };

    StatusEntry find(const std::vector<StatusEntry>& v, const std::string& m_Path)
    {
        for (const auto& e : v)
        {
            if (e.m_Path == m_Path)
            {
                return e;
            }
        }
        return {};
    }

    // A 20-line file whose line `n` (1-based) says `text`; edits far enough apart
    // produce independent m_Hunks.
    std::string twentyLines(int changedLine = -1, const std::string& text = "")
    {
        std::string out;
        for (int i = 1; i <= 20; ++i)
        {
            if (i == changedLine)
            {
                out += text + "\n";
            }
            else
            {
                out += "line" + std::to_string(i) + "\n";
            }
        }
        return out;
    }

} // namespace

// ---- Hunk staging ----------------------------------------------------------

TEST_CASE("staging one hunk leaves the other unstaged", "[hunks]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("f.txt", twentyLines());
    repo.Stage("f.txt");
    t.Commit(repo, "base");

    // Two edits ~16 lines apart -> two m_Hunks.
    std::string modified = twentyLines(2, "CHANGED-TOP");
    modified.replace(modified.find("line18"), 6, "CHANGED-BOTTOM;line18");
    t.write("f.txt", modified);

    FileDiff unstaged = repo.DiffFile("f.txt", DiffTarget::Unstaged);
    REQUIRE(unstaged.m_Hunks.size() == 2);

    repo.StageHunk("f.txt", 0);

    FileDiff staged = repo.DiffFile("f.txt", DiffTarget::Staged);
    REQUIRE(staged.m_Hunks.size() == 1);
    bool stagedHasTop = false;
    for (const auto& l : staged.m_Hunks[0].m_Lines)
    {
        if (l.m_cOrigin == '+' && l.m_Content.find("CHANGED-TOP") != std::string::npos)
        {
            stagedHasTop = true;
        }
    }
    CHECK(stagedHasTop);

    FileDiff stillUnstaged = repo.DiffFile("f.txt", DiffTarget::Unstaged);
    REQUIRE(stillUnstaged.m_Hunks.size() == 1);
    bool unstagedHasBottom = false;
    for (const auto& l : stillUnstaged.m_Hunks[0].m_Lines)
    {
        if (l.m_cOrigin == '+' && l.m_Content.find("CHANGED-BOTTOM") != std::string::npos)
        {
            unstagedHasBottom = true;
        }
    }
    CHECK(unstagedHasBottom);
}

TEST_CASE("staging a later hunk works when an earlier hunk shifts lines", "[hunks]")
{
    // Regression: libgit2's git_apply positions m_Hunks by their NEW start
    // line, which assumes every earlier hunk applies too. A lone mid-file
    // hunk extracted after an insertion above it "did not apply" until
    // singleHunkPatch started renumbering the new side to the old side.
    TempRepo t;
    auto repo = t.Init();
    t.write("f.txt", twentyLines());
    repo.Stage("f.txt");
    t.Commit(repo, "base");

    // Hunk 1 INSERTS lines near the top (shifting everything below);
    // hunk 2 edits near the bottom.
    std::string modified = twentyLines(2, "line2\nADDED-A\nADDED-B\nADDED-C");
    modified.replace(modified.find("line18"), 6, "CHANGED-BOTTOM;line18");
    t.write("f.txt", modified);

    FileDiff unstaged = repo.DiffFile("f.txt", DiffTarget::Unstaged);
    REQUIRE(unstaged.m_Hunks.size() == 2);

    repo.StageHunk("f.txt", 1); // the bottom hunk only

    FileDiff staged = repo.DiffFile("f.txt", DiffTarget::Staged);
    REQUIRE(staged.m_Hunks.size() == 1);
    bool stagedHasBottom = false;
    for (const auto& l : staged.m_Hunks[0].m_Lines)
    {
        if (l.m_cOrigin == '+' && l.m_Content.find("CHANGED-BOTTOM") != std::string::npos)
        {
            stagedHasBottom = true;
        }
    }
    CHECK(stagedHasBottom);

    // And back out again: the staged diff has one hunk; unstage it.
    repo.UnstageHunk("f.txt", 0);
    CHECK(repo.DiffFile("f.txt", DiffTarget::Staged).m_Hunks.empty());
    CHECK(repo.DiffFile("f.txt", DiffTarget::Unstaged).m_Hunks.size() == 2);
}

TEST_CASE("unstageHunk rolls a staged hunk back", "[hunks]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("f.txt", twentyLines());
    repo.Stage("f.txt");
    t.Commit(repo, "base");

    t.write("f.txt", twentyLines(2, "EDITED"));
    repo.Stage("f.txt");
    REQUIRE(repo.DiffFile("f.txt", DiffTarget::Staged).m_Hunks.size() == 1);

    repo.UnstageHunk("f.txt", 0);
    CHECK(repo.DiffFile("f.txt", DiffTarget::Staged).m_Hunks.empty());
    CHECK_FALSE(repo.DiffFile("f.txt", DiffTarget::Unstaged).m_Hunks.empty());
}

TEST_CASE("untracked directories list their files, which can be staged", "[status]")
{
    TempRepo t;
    auto repo = t.Init();
    fs::create_directories(t.dir / "docs");
    t.write("docs/guide.md", "# guide\n");
    t.write("docs/api.md", "# api\n");

    // The directory itself must NOT appear as a bare "docs/" entry (it can't
    // be staged); its files must each be listed and stageable.
    auto st = repo.Status();
    CHECK(find(st, "docs/").m_Path.empty());
    CHECK_FALSE(find(st, "docs/guide.md").m_Path.empty());
    CHECK_FALSE(find(st, "docs/api.md").m_Path.empty());

    REQUIRE_NOTHROW(repo.Stage("docs/guide.md"));
    REQUIRE_NOTHROW(repo.Stage("docs/api.md"));
    CHECK(find(repo.Status(), "docs/guide.md").m_bStaged);
    CHECK(find(repo.Status(), "docs/api.md").m_bStaged);
}

// ---- Branches ----------------------------------------------------------------

TEST_CASE("branch create/list/checkout/rename/delete", "[branches]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "hello\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    const std::string original = repo.CurrentBranch();
    REQUIRE_FALSE(original.empty());

    repo.CreateBranch("feature");
    auto all = repo.Branches();
    bool sawFeature = false, sawOriginalAsHead = false;
    for (const auto& b : all)
    {
        if (b.m_Name == "feature")
        {
            sawFeature = true;
        }
        if (b.m_Name == original && b.m_bIsHead)
        {
            sawOriginalAsHead = true;
        }
    }
    CHECK(sawFeature);
    CHECK(sawOriginalAsHead);

    repo.Checkout("feature");
    CHECK(repo.CurrentBranch() == "feature");

    repo.Checkout(original);
    repo.RenameBranch("feature", "feature-renamed");
    repo.DeleteBranch("feature-renamed");
    for (const auto& b : repo.Branches())
    {
        CHECK(b.m_Name != "feature");
        CHECK(b.m_Name != "feature-renamed");
    }
}

TEST_CASE("currentBranch works on an unborn HEAD", "[branches]")
{
    TempRepo t;
    auto repo = t.Init();
    CHECK_FALSE(repo.CurrentBranch().empty()); // e.g. "master"/"main"
}

// ---- History -------------------------------------------------------------------

TEST_CASE("log walks commits newest-first with parent links", "[history]")
{
    TempRepo t;
    auto repo = t.Init();
    CHECK(repo.Log().empty()); // unborn

    t.write("a.txt", "v1\n");
    repo.Stage("a.txt");
    const std::string c1 = t.Commit(repo, "first");

    t.write("a.txt", "v2\n");
    repo.Stage("a.txt");
    const std::string c2 = t.Commit(repo, "second\n\nwith body");

    auto history = repo.Log();
    REQUIRE(history.size() == 2);
    CHECK(history[0].m_Oid == c2);
    CHECK(history[0].m_Summary == "second");
    CHECK(history[0].m_Message.find("with body") != std::string::npos);
    CHECK(history[0].m_AuthorName == "Test User");
    REQUIRE(history[0].m_Parents.size() == 1);
    CHECK(history[0].m_Parents[0] == c1);
    CHECK(history[1].m_Oid == c1);
    CHECK(history[1].m_Parents.empty());
    CHECK(history[0].m_TimeUtc >= history[1].m_TimeUtc);
}

TEST_CASE("diffCommit shows a commit's changes vs its parent", "[history]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "v1\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    t.write("a.txt", "v1\nv2\n");
    repo.Stage("a.txt");
    const std::string c2 = t.Commit(repo, "c2");

    auto files = repo.DiffCommit(c2);
    REQUIRE(files.size() == 1);
    CHECK(files[0].m_Path == "a.txt");
    bool sawAdd = false;
    for (const auto& h : files[0].m_Hunks)
    {
        for (const auto& l : h.m_Lines)
        {
            if (l.m_cOrigin == '+' && l.m_Content == "v2")
            {
                sawAdd = true;
            }
        }
    }
    CHECK(sawAdd);
}

// ---- Remotes ---------------------------------------------------------------------

TEST_CASE("remote add/list/remove", "[remotes]")
{
    TempRepo t;
    auto repo = t.Init();
    CHECK(repo.Remotes().empty());

    repo.AddRemote("origin", "https://example.com/repo.git");
    auto Remotes = repo.Remotes();
    REQUIRE(Remotes.size() == 1);
    CHECK(Remotes[0].m_Name == "origin");
    CHECK(Remotes[0].m_Url == "https://example.com/repo.git");

    repo.RemoveRemote("origin");
    CHECK(repo.Remotes().empty());
}

// ---- Stash ------------------------------------------------------------------------

TEST_CASE("stash save/list/pop round-trips", "[stash]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "v1\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    t.write("a.txt", "dirty\n");
    REQUIRE_FALSE(repo.Status().empty());

    repo.StashSave("wip");
    CHECK(repo.Status().empty());
    auto stashes = repo.StashList();
    REQUIRE(stashes.size() == 1);
    CHECK(stashes[0].m_Message.find("wip") != std::string::npos);

    repo.StashPop(0);
    CHECK(find(repo.Status(), "a.txt").m_bUnstaged);
    CHECK(repo.StashList().empty());
}

TEST_CASE("stash drop discards without applying", "[stash]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "v1\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    t.write("a.txt", "dirty\n");
    repo.StashSave("doomed");
    repo.StashDrop(0);
    CHECK(repo.StashList().empty());
    CHECK(repo.Status().empty()); // change is gone
}

// ---- Merge -------------------------------------------------------------------------

TEST_CASE("merge fast-forwards when possible", "[merge]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "base\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");
    const std::string mainBranch = repo.CurrentBranch();

    repo.CreateBranch("feature");
    repo.Checkout("feature");
    t.write("b.txt", "feature work\n");
    repo.Stage("b.txt");
    t.Commit(repo, "c2");

    repo.Checkout(mainBranch);
    auto result = repo.Merge("feature");
    CHECK(result.m_Kind == MergeResult::Kind::FastForward);
    CHECK(fs::exists(t.dir / "b.txt"));
    CHECK(repo.Log().size() == 2);
}

TEST_CASE("divergent branches produce a merge commit", "[merge]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "base\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");
    const std::string mainBranch = repo.CurrentBranch();

    repo.CreateBranch("feature");
    repo.Checkout("feature");
    t.write("feature.txt", "feature\n");
    repo.Stage("feature.txt");
    t.Commit(repo, "feature commit");

    repo.Checkout(mainBranch);
    t.write("main.txt", "main\n");
    repo.Stage("main.txt");
    t.Commit(repo, "main commit");

    auto result = repo.Merge("feature");
    CHECK(result.m_Kind == MergeResult::Kind::Merged);
    CHECK(fs::exists(t.dir / "feature.txt"));
    CHECK(fs::exists(t.dir / "main.txt"));
    REQUIRE_FALSE(repo.Log().empty());
    CHECK(repo.Log()[0].m_Parents.size() == 2); // a true merge Commit
}

TEST_CASE("conflicting merge reports conflicts and can be aborted", "[merge]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "base\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");
    const std::string mainBranch = repo.CurrentBranch();

    repo.CreateBranch("feature");
    repo.Checkout("feature");
    t.write("a.txt", "feature version\n");
    repo.Stage("a.txt");
    t.Commit(repo, "feature edit");

    repo.Checkout(mainBranch);
    t.write("a.txt", "main version\n");
    repo.Stage("a.txt");
    t.Commit(repo, "main edit");

    auto result = repo.Merge("feature");
    REQUIRE(result.m_Kind == MergeResult::Kind::Conflicts);
    REQUIRE(result.m_ConflictedPaths.size() == 1);
    CHECK(result.m_ConflictedPaths[0] == "a.txt");
    CHECK(repo.ConflictedPaths() == result.m_ConflictedPaths);

    repo.AbortMerge();
    CHECK(repo.ConflictedPaths().empty());
    CHECK(repo.Status().empty());

    // Resolve-and-Commit m_Path: merge again, resolve, Stage, Commit.
    result = repo.Merge("feature");
    REQUIRE(result.m_Kind == MergeResult::Kind::Conflicts);
    t.write("a.txt", "resolved\n");
    repo.Stage("a.txt");
    const std::string mergeOid = t.Commit(repo, "merge feature (resolved)");
    CHECK(mergeOid.size() == 40);
    CHECK(repo.ConflictedPaths().empty());
    CHECK(repo.Log()[0].m_Parents.size() == 2);
}
