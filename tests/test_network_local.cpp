// Networked-operation tests (fetch/push/pull/Clone) against LOCAL bare
// repositories — libgit2's local transport exercises the same remote code
// paths without touching a real server, keeping the suite offline and fast.

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

    // A scratch directory holding a bare "server" repo and working clones.
    struct TempNet
    {
        LibGit2 lib;
        fs::path root;

        TempNet()
        {
            static std::atomic<unsigned> counter{0};
            root =
                fs::temp_directory_path() / ("gitgud_net_" + std::to_string(counter++) + "_" +
                                                std::to_string(reinterpret_cast<uintptr_t>(this)));
            fs::create_directories(root);
        }

        ~TempNet()
        {
            std::error_code ec;
            fs::remove_all(root, ec);
        }

        std::string path(const std::string& name) const
        {
            // libgit2's local transport prefers forward slashes on Windows.
            std::string p = (root / name).string();
            for (auto& c : p)
            {
                if (c == '\\')
                {
                    c = '/';
                }
            }
            return p;
        }

        void write(const std::string& repoName, const std::string& file, const std::string& content)
        {
            std::ofstream(root / repoName / file, std::ios::binary) << content;
        }

        std::string Commit(Repository& r, const std::string& msg)
        {
            return r.Commit(msg, "Test User", "test@example.com");
        }
    };

} // namespace

TEST_CASE("push to a local bare remote, then clone it back", "[network]")
{
    TempNet t;
    Repository::InitBare(t.path("server.git"));

    auto work = Repository::Init(t.path("work"));
    t.write("work", "a.txt", "hello\n");
    work.Stage("a.txt");
    t.Commit(work, "c1");

    work.AddRemote("origin", t.path("server.git"));
    work.Push("origin");

    // The branch adopted origin/<branch> as upstream on first push.
    auto ab = work.GetAheadBehind();
    CHECK(ab.m_bHasUpstream);
    CHECK(ab.m_Ahead == 0);
    CHECK(ab.m_Behind == 0);

    auto Clone = Repository::Clone(t.path("server.git"), t.path("clone"));
    CHECK(Clone.IsOpen());
    CHECK(fs::exists(t.root / "clone" / "a.txt"));
    REQUIRE(Clone.Log().size() == 1);
    CHECK(Clone.Log()[0].m_Summary == "c1");
}

TEST_CASE("ahead/behind reflects unpushed commits", "[network]")
{
    TempNet t;
    Repository::InitBare(t.path("server.git"));

    auto work = Repository::Init(t.path("work"));
    t.write("work", "a.txt", "v1\n");
    work.Stage("a.txt");
    t.Commit(work, "c1");
    work.AddRemote("origin", t.path("server.git"));
    work.Push("origin");

    t.write("work", "a.txt", "v2\n");
    work.Stage("a.txt");
    t.Commit(work, "c2");

    auto ab = work.GetAheadBehind();
    CHECK(ab.m_bHasUpstream);
    CHECK(ab.m_Ahead == 1);
    CHECK(ab.m_Behind == 0);

    // The branch listing maps the upstream through origin's fetch refspec.
    const std::string branch = work.CurrentBranch();
    bool sawBranch = false;
    for (const auto& b : work.Branches())
    {
        if (!b.m_bIsRemote && b.m_Name == branch)
        {
            sawBranch = true;
            CHECK(b.m_bIsHead);
            CHECK(b.m_Upstream == "origin/" + branch);
            CHECK(b.m_Ahead == 1);
            CHECK(b.m_Behind == 0);
        }
    }
    CHECK(sawBranch);

    work.Push("origin");
    ab = work.GetAheadBehind();
    CHECK(ab.m_Ahead == 0);
}

TEST_CASE("pull fast-forwards a clone after upstream moves", "[network]")
{
    TempNet t;
    Repository::InitBare(t.path("server.git"));

    auto alice = Repository::Init(t.path("alice"));
    t.write("alice", "a.txt", "v1\n");
    alice.Stage("a.txt");
    t.Commit(alice, "c1");
    alice.AddRemote("origin", t.path("server.git"));
    alice.Push("origin");

    auto bob = Repository::Clone(t.path("server.git"), t.path("bob"));
    REQUIRE(bob.Log().size() == 1);

    t.write("alice", "b.txt", "new work\n");
    alice.Stage("b.txt");
    t.Commit(alice, "c2");
    alice.Push("origin");

    auto result = bob.Pull("origin");
    CHECK(result.m_Kind == MergeResult::Kind::FastForward);
    CHECK(fs::exists(t.root / "bob" / "b.txt"));
    CHECK(bob.Log().size() == 2);
}

TEST_CASE("fetch updates remote-tracking refs without touching the worktree", "[network]")
{
    TempNet t;
    Repository::InitBare(t.path("server.git"));

    auto alice = Repository::Init(t.path("alice"));
    t.write("alice", "a.txt", "v1\n");
    alice.Stage("a.txt");
    t.Commit(alice, "c1");
    alice.AddRemote("origin", t.path("server.git"));
    alice.Push("origin");

    auto bob = Repository::Clone(t.path("server.git"), t.path("bob"));

    t.write("alice", "a.txt", "v2\n");
    alice.Stage("a.txt");
    t.Commit(alice, "c2");
    alice.Push("origin");

    bob.Fetch("origin");
    auto ab = bob.GetAheadBehind();
    CHECK(ab.m_bHasUpstream);
    CHECK(ab.m_Behind == 1); // fetched but not merged
    CHECK(bob.Log().size() == 1);
}

// ---- Several remotes ----------------------------------------------------------

TEST_CASE("pushing to a second remote leaves the upstream alone unless asked", "[network][remotes]")
{
    TempNet t;
    Repository::InitBare(t.path("home.git"));
    Repository::InitBare(t.path("hub.git"));

    auto work = Repository::Init(t.path("work"));
    t.write("work", "a.txt", "v1\n");
    work.Stage("a.txt");
    t.Commit(work, "c1");
    work.AddRemote("origin", t.path("home.git"));
    work.AddRemote("mirror", t.path("hub.git"));

    work.Push("origin");
    auto ab = work.GetAheadBehind();
    CHECK(ab.m_UpstreamRemote == "origin");
    CHECK(ab.m_Upstream == "origin/" + work.CurrentBranch());

    // A plain push elsewhere publishes the branch there but keeps tracking origin.
    work.Push("mirror");
    CHECK(work.GetAheadBehind().m_UpstreamRemote == "origin");
    auto hubClone = Repository::Clone(t.path("hub.git"), t.path("hubclone"));
    REQUIRE(hubClone.Log().size() == 1);

    // "Push to… and track it" switches the upstream.
    work.Push("mirror", false, true);
    ab = work.GetAheadBehind();
    CHECK(ab.m_UpstreamRemote == "mirror");
    CHECK(ab.m_Upstream == "mirror/" + work.CurrentBranch());
}

TEST_CASE("push and pull follow an upstream with a different branch name", "[network][remotes]")
{
    TempNet t;
    Repository::InitBare(t.path("server.git"));

    auto alice = Repository::Init(t.path("alice"));
    t.write("alice", "a.txt", "v1\n");
    alice.Stage("a.txt");
    t.Commit(alice, "c1");
    alice.AddRemote("origin", t.path("server.git"));
    alice.Push("origin");
    const std::string mainBranch = alice.CurrentBranch();

    // Bob works on "feature" locally, tracking the server's main branch.
    auto bob = Repository::Clone(t.path("server.git"), t.path("bob"));
    bob.CreateBranch("feature");
    bob.Checkout("feature");
    bob.SetUpstream("feature", "origin/" + mainBranch);

    t.write("bob", "b.txt", "bob\n");
    bob.Stage("b.txt");
    t.Commit(bob, "from bob");
    bob.Push("origin");

    // It landed on main, not on a new "feature" branch.
    bob.Fetch("origin");
    bool bfeatureOnServer = false;
    for (const auto& b : bob.Branches())
    {
        bfeatureOnServer = bfeatureOnServer || b.m_Name == "origin/feature";
    }
    CHECK_FALSE(bfeatureOnServer);
    CHECK(bob.GetAheadBehind().m_Ahead == 0);

    // And Pull merges main back.
    t.write("alice", "c.txt", "alice\n");
    alice.Pull("origin");
    alice.Stage("c.txt");
    t.Commit(alice, "from alice");
    alice.Push("origin");

    auto result = bob.Pull("origin");
    CHECK(result.m_Kind == MergeResult::Kind::FastForward);
    CHECK(fs::exists(t.root / "bob" / "c.txt"));
}

TEST_CASE("fetchAll fetches every remote and reports the ones that fail", "[network][remotes]")
{
    TempNet t;
    Repository::InitBare(t.path("one.git"));
    Repository::InitBare(t.path("two.git"));

    auto seed = Repository::Init(t.path("seed"));
    t.write("seed", "a.txt", "v1\n");
    seed.Stage("a.txt");
    t.Commit(seed, "c1");
    seed.AddRemote("one", t.path("one.git"));
    seed.AddRemote("two", t.path("two.git"));
    seed.Push("one");
    seed.Push("two");
    const std::string branch = seed.CurrentBranch();

    auto work = Repository::Init(t.path("work"));
    work.AddRemote("one", t.path("one.git"));
    work.AddRemote("two", t.path("two.git"));
    const auto fetched = work.FetchAll();
    CHECK(fetched.size() == 2);

    int itracking = 0;
    for (const auto& b : work.Branches())
    {
        itracking += (b.m_Name == "one/" + branch || b.m_Name == "two/" + branch) ? 1 : 0;
    }
    CHECK(itracking == 2);

    // A broken remote fails the call, but the good one is still fetched.
    work.AddRemote("broken", t.path("missing.git"));
    CHECK_THROWS_AS(work.FetchAll(), GitError);
}

TEST_CASE("changing or renaming a remote keeps upstream tracking", "[network][remotes]")
{
    TempNet t;
    Repository::InitBare(t.path("server.git"));
    Repository::InitBare(t.path("moved.git"));

    auto work = Repository::Init(t.path("work"));
    t.write("work", "a.txt", "v1\n");
    work.Stage("a.txt");
    t.Commit(work, "c1");
    work.AddRemote("origin", t.path("server.git"));
    work.Push("origin");
    const std::string branch = work.CurrentBranch();

    work.SetRemoteUrl("origin", t.path("moved.git"));
    REQUIRE(work.Remotes().size() == 1);
    CHECK(work.Remotes()[0].m_Url == t.path("moved.git"));
    CHECK(work.GetAheadBehind().m_UpstreamRemote == "origin");

    work.RenameRemote("origin", "home");
    REQUIRE(work.Remotes().size() == 1);
    CHECK(work.Remotes()[0].m_Name == "home");
    auto ab = work.GetAheadBehind();
    CHECK(ab.m_bHasUpstream);
    CHECK(ab.m_UpstreamRemote == "home");
    CHECK(ab.m_Upstream == "home/" + branch);

    work.SetUpstream(branch, "");
    CHECK_FALSE(work.GetAheadBehind().m_bHasUpstream);
}
