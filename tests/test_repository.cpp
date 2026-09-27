// Headless unit tests for the Git engine (gitgud::git::Repository).
//
// Each test builds a throwaway repository in a unique temp directory, exercises
// the API, and cleans up. No GUI, no network — this is the fast feedback loop
// the whole project rests on.

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

    // A temp repo that owns libgit2 Init and cleans its directory on destruction.
    struct TempRepo
    {
        LibGit2 lib; // refcounted global Init/shutdown
        fs::path dir;

        TempRepo()
        {
            static std::atomic<unsigned> counter{0};
            dir =
                fs::temp_directory_path() / ("gitgud_test_" + std::to_string(counter++) + "_" +
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

        void erase(const std::string& name)
        {
            std::error_code ec;
            fs::remove(dir / name, ec);
        }

        // Commit with a fixed test identity (no reliance on git config).
        std::string Commit(Repository& r, const std::string& msg)
        {
            return r.Commit(msg, "Test User", "test@example.com");
        }
    };

    // Find a Status entry by m_Path, or return a default-constructed one.
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

} // namespace

TEST_CASE("fresh repo has empty status", "[status]")
{
    TempRepo t;
    auto repo = t.Init();
    CHECK(repo.Status().empty());
}

TEST_CASE("new file shows as untracked, then staged", "[status][stage]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "hello\n");

    auto before = find(repo.Status(), "a.txt");
    CHECK(before.m_cCode == '?');
    CHECK(before.m_bUnstaged);
    CHECK_FALSE(before.m_bStaged);

    repo.Stage("a.txt");
    auto after = find(repo.Status(), "a.txt");
    CHECK(after.m_bStaged);
    CHECK(after.m_cCode == 'A');
}

TEST_CASE("commit clears status and creates history", "[commit]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "hello\n");
    repo.Stage("a.txt");

    std::string oid = t.Commit(repo, "initial commit");
    CHECK(oid.size() == 40);      // full SHA-1 hex
    CHECK(repo.Status().empty()); // nothing left to Commit
}

TEST_CASE("second commit records a modification", "[commit][diff]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "line1\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    t.write("a.txt", "line1\nline2\n"); // modify tracked file
    auto st = find(repo.Status(), "a.txt");
    CHECK(st.m_bUnstaged);
    CHECK(st.m_cCode == 'M');

    // Unstaged diff should contain the added line.
    FileDiff d = repo.DiffFile("a.txt", DiffTarget::Unstaged);
    REQUIRE_FALSE(d.m_Hunks.empty());
    bool sawAddedLine2 = false;
    for (const auto& h : d.m_Hunks)
    {
        for (const auto& l : h.m_Lines)
        {
            if (l.m_cOrigin == '+' && l.m_Content == "line2")
            {
                sawAddedLine2 = true;
            }
        }
    }
    CHECK(sawAddedLine2);
}

TEST_CASE("stage then unstage round-trips", "[stage][unstage]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "v1\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    t.write("a.txt", "v2\n");
    repo.Stage("a.txt");
    CHECK(find(repo.Status(), "a.txt").m_bStaged);

    // Staged diff shows the change...
    FileDiff staged = repo.DiffFile("a.txt", DiffTarget::Staged);
    CHECK_FALSE(staged.m_Hunks.empty());

    repo.Unstage("a.txt");
    auto st = find(repo.Status(), "a.txt");
    CHECK(st.m_bUnstaged);
    CHECK_FALSE(st.m_bStaged);
}

TEST_CASE("staging a deletion is recorded", "[stage][delete]")
{
    TempRepo t;
    auto repo = t.Init();
    t.write("a.txt", "content\n");
    repo.Stage("a.txt");
    t.Commit(repo, "c1");

    t.erase("a.txt");
    repo.Stage("a.txt"); // Stage the deletion
    auto st = find(repo.Status(), "a.txt");
    CHECK(st.m_bStaged);
    CHECK(st.m_cCode == 'D');
}
