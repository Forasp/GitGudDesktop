// Tests for git/BareStore (files in a bare repository, each change a
// commit) and platform::WriteFileAtomically.

#include <catch2/catch_test_macros.hpp>

#include "git/BareStore.h"
#include "git/Repository.h"
#include "platform/Shell.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fs = std::filesystem;
namespace barestore = gitgud::git::barestore;
using gitgud::git::StoreChange;

namespace
{

    struct ScratchDir
    {
        fs::path m_Path;

        ScratchDir()
        {
            m_Path = fs::temp_directory_path() /
                     ("gitgud-barestore-" +
                         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
            fs::create_directories(m_Path);
        }

        ~ScratchDir()
        {
            std::error_code ec;
            fs::remove_all(m_Path, ec);
        }
    };

    std::string Slurp(const fs::path& _Path)
    {
        std::ifstream in(_Path, std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        return ss.str();
    }

} // namespace

TEST_CASE("BareStore: pages committed, read back, and their history", "[barestore]")
{
    gitgud::git::LibGit2 lib;
    ScratchDir dir;
    const std::string store = (dir.m_Path / "app.wiki.git").u8string();

    CHECK_FALSE(barestore::Exists(store));
    barestore::Init(store);
    REQUIRE(barestore::Exists(store));
    CHECK(fs::exists(fs::u8path(store) / "HEAD"));
    CHECK(Slurp(fs::u8path(store) / "HEAD").find("refs/heads/main") != std::string::npos);
    CHECK(barestore::Files(store).empty());
    CHECK(barestore::Log(store).empty());
    CHECK_FALSE(barestore::Read(store, "Home.md").has_value());

    const std::string first = barestore::Commit(store,
        {StoreChange{"Home.md", std::string("# Home\n")}, StoreChange{"guides/Deep-Dive.md", std::string("Deep")},
            StoreChange{"images/logo.png", std::string("\x89PNG\0\1", 6)}},
        "Add pages", "Sam", "sam@localhost");
    REQUIRE(first.size() == 40);

    const auto files = barestore::Files(store);
    REQUIRE(files.size() == 3);
    CHECK(files[0].m_Path == "Home.md");
    CHECK(files[1].m_Path == "guides/Deep-Dive.md");
    CHECK(files[2].m_Path == "images/logo.png");
    CHECK(files[2].m_uSize == 6);
    CHECK(barestore::Read(store, "images/logo.png") == std::string("\x89PNG\0\1", 6));

    SECTION("an edit is a commit, and the old text stays reachable")
    {
        const std::string second = barestore::Commit(
            store, {StoreChange{"Home.md", std::string("# Home\n\nMore.\n")}}, "Update Home", "Sam", "sam@localhost");
        REQUIRE_FALSE(second.empty());
        CHECK(barestore::Read(store, "Home.md") == std::string("# Home\n\nMore.\n"));
        CHECK(barestore::Read(store, "Home.md", first) == std::string("# Home\n"));

        const auto home = barestore::Log(store, "Home.md");
        REQUIRE(home.size() == 2);
        CHECK(home[0].m_Id == second);
        CHECK(home[0].m_Message.find("Update Home") == 0);
        CHECK(home[0].m_Author == "Sam");
        CHECK(home[1].m_Id == first);
        CHECK(barestore::Log(store, "guides/Deep-Dive.md").size() == 1);
        CHECK(barestore::Log(store).size() == 2);
        CHECK(barestore::Log(store, "", 1).size() == 1);
    }

    SECTION("the same content again commits nothing")
    {
        CHECK(barestore::Commit(store, {StoreChange{"Home.md", std::string("# Home\n")}}, "Again", "Sam", "s@l")
                  .empty());
        CHECK(barestore::Log(store).size() == 1);
    }

    SECTION("a removed file is gone; removing a missing one is fine")
    {
        REQUIRE_FALSE(barestore::Commit(store,
            {StoreChange{"guides/Deep-Dive.md", std::nullopt}, StoreChange{"nowhere.md", std::nullopt}}, "Remove",
            "Sam", "s@l")
                          .empty());
        CHECK_FALSE(barestore::Read(store, "guides/Deep-Dive.md").has_value());
        CHECK(barestore::Files(store).size() == 2);
        CHECK(barestore::Log(store, "guides/Deep-Dive.md").size() == 2);
    }

    SECTION("a bad revision is an error")
    {
        CHECK_THROWS_AS(barestore::Read(store, "Home.md", "nope"), gitgud::git::GitError);
    }
}

TEST_CASE("BareStore: committing makes the store when it's missing", "[barestore]")
{
    gitgud::git::LibGit2 lib;
    ScratchDir dir;
    const std::string store = (dir.m_Path / "deep" / "shared.wiki.git").u8string();
    REQUIRE_FALSE(barestore::Commit(store, {StoreChange{"Home.md", std::string("Hi")}}, "First", "A", "a@b").empty());
    CHECK(barestore::Read(store, "Home.md") == std::string("Hi"));
}

TEST_CASE("WriteFileAtomically replaces a file in one step", "[barestore]")
{
    ScratchDir dir;
    const fs::path file = dir.m_Path / "sub" / "tasks.json";
    std::string error;
    REQUIRE(gitgud::platform::WriteFileAtomically(file.u8string(), "{\"a\":1}", error));
    CHECK(Slurp(file) == "{\"a\":1}");
    REQUIRE(gitgud::platform::WriteFileAtomically(file.u8string(), "{\"a\":2}", error));
    CHECK(Slurp(file) == "{\"a\":2}");
    fs::path temp = file;
    temp += ".tmp";
    CHECK_FALSE(fs::exists(temp));

    // A folder in the way: it fails, and the old file is untouched.
    const fs::path blocked = dir.m_Path / "blocked";
    fs::create_directories(blocked / "inside");
    CHECK_FALSE(gitgud::platform::WriteFileAtomically(blocked.u8string(), "x", error));
    CHECK_FALSE(error.empty());
    CHECK(fs::is_directory(blocked));
}
