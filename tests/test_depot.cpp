// Headless tests for the engine behind the Depot UI: browsing a
// revision's tree, diffing arbitrary file versions, listing changed files,
// shelving to a branch and unshelving (clean, merged, conflicting), the file
// revision graph across branches, and its renderer. Also UI package
// discovery. Same throwaway-temp-repo pattern as the other test files.

#include <catch2/catch_test_macros.hpp>

#include "app/UiPackages.h"
#include "git/Repository.h"
#include "imaging/RevisionGraphRenderer.h"

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
                fs::temp_directory_path() / ("gitgud_dp_" + std::to_string(counter++) + "_" +
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

        bool Exists(const std::string& _Name) const
        {
            return fs::exists(m_Dir / _Name);
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
    };

    bool HasBranch(Repository& _Repo, const std::string& _Name)
    {
        const auto branches = _Repo.Branches();
        return std::any_of(branches.begin(), branches.end(),
            [&](const BranchInfo& _B) { return !_B.m_bIsRemote && _B.m_Name == _Name; });
    }

} // namespace

TEST_CASE("ListTree lists a revision's folders first, then files", "[depot]")
{
    TempRepo t;
    t.Write("src/app/main.cpp", "int main() {}\n");
    t.Write("src/util.h", "#pragma once\n");
    t.Write("README.md", "hello\n");
    const std::string first = t.CommitAll("first");
    t.Write("src/new.txt", "later\n");
    t.CommitAll("second");

    const auto root = t.m_Repo.ListTree("HEAD", "");
    REQUIRE(root.size() == 2);
    CHECK(root[0].m_Name == "src");
    CHECK(root[0].m_bIsDir);
    CHECK(root[1].m_Name == "README.md");
    CHECK(root[1].m_Size == 6);

    const auto src = t.m_Repo.ListTree("HEAD", "src/");
    REQUIRE(src.size() == 3);
    CHECK(src[0].m_Path == "src/app");
    CHECK(src[1].m_Path == "src/new.txt");
    CHECK(src[2].m_Path == "src/util.h");

    // An older revision doesn't have the later file.
    CHECK(t.m_Repo.ListTree(first, "src").size() == 2);
    CHECK(t.m_Repo.ListTree("HEAD", "nope").empty());
}

TEST_CASE("DiffVersions compares any two versions, including the working copy", "[depot]")
{
    TempRepo t;
    t.Write("a.txt", "one\ntwo\n");
    const std::string first = t.CommitAll("first");
    t.Write("a.txt", "one\nTWO\n");
    t.CommitAll("second");
    t.Write("a.txt", "one\nTWO\nthree\n");

    const auto history = t.m_Repo.DiffVersions("a.txt", first, "a.txt", "HEAD");
    CHECK(history.m_cStatus == 'M');
    REQUIRE(history.m_Hunks.size() == 1);

    const auto local = t.m_Repo.DiffVersions("a.txt", "HEAD", "a.txt", "workdir");
    REQUIRE(local.m_Hunks.size() == 1);
    const auto& lines = local.m_Hunks[0].m_Lines;
    CHECK(std::any_of(lines.begin(), lines.end(),
        [](const DiffLine& _L) { return _L.m_cOrigin == '+' && _L.m_Content == "three"; }));

    const auto added = t.m_Repo.DiffVersions("missing.txt", "HEAD", "a.txt", "workdir");
    CHECK(added.m_cStatus == 'A');
}

TEST_CASE("ChangedFiles lists what differs between revisions and the working tree", "[depot]")
{
    TempRepo t;
    t.Write("keep.txt", "k\n");
    t.Write("dir/edit.txt", "e\n");
    t.Write("gone.txt", "g\n");
    const std::string first = t.CommitAll("first");
    t.Write("dir/edit.txt", "e2\n");
    fs::remove(t.m_Dir / "gone.txt");
    t.Write("dir/new.txt", "n\n");
    const std::string second = t.CommitAll("second");

    auto files = t.m_Repo.ChangedFiles(first, second);
    auto status = [&](const std::string& _Path)
    {
        for (const auto& f : files)
        {
            if (f.m_Path == _Path)
            {
                return f.m_cStatus;
            }
        }
        return '?';
    };
    CHECK(status("dir/edit.txt") == 'M');
    CHECK(status("gone.txt") == 'D');
    CHECK(status("dir/new.txt") == 'A');
    CHECK(status("keep.txt") == '?');

    files = t.m_Repo.ChangedFiles(first, second, "dir");
    CHECK(files.size() == 2);

    t.Write("untracked.txt", "u\n");
    files = t.m_Repo.ChangedFiles("HEAD", "workdir");
    CHECK(status("untracked.txt") == 'A');

    // "" = from nothing: every file of the revision is an add.
    files = t.m_Repo.ChangedFiles("", first);
    CHECK(files.size() == 3);
}

TEST_CASE("Shelve snapshots files onto a branch without touching the working tree", "[depot]")
{
    TempRepo t;
    t.Write("a.txt", "a\n");
    t.Write("b.txt", "b\n");
    t.Write("c.txt", "c\n");
    const std::string base = t.CommitAll("base");

    t.Write("a.txt", "a changed\n");
    t.Write("new.txt", "brand new\n");
    fs::remove(t.m_Dir / "c.txt");
    t.Write("b.txt", "b changed but not shelved\n");

    const auto statusBefore = t.m_Repo.Status();
    const std::string shelf =
        t.m_Repo.Shelve("shelves/1", {"a.txt", "new.txt", "c.txt"}, "Shelved CL 1");

    // Nothing local moved.
    CHECK(t.m_Repo.HeadOid() == base);
    CHECK(t.m_Repo.CurrentBranch() != "shelves/1");
    CHECK(t.m_Repo.Status().size() == statusBefore.size());
    CHECK(t.Read("a.txt") == "a changed\n");

    // The shelf holds exactly the shelved files' working versions.
    REQUIRE(HasBranch(t.m_Repo, "shelves/1"));
    std::string content;
    REQUIRE(t.m_Repo.ReadFileVersion("a.txt", shelf, content));
    CHECK(content == "a changed\n");
    REQUIRE(t.m_Repo.ReadFileVersion("new.txt", shelf, content));
    CHECK(content == "brand new\n");
    CHECK_FALSE(t.m_Repo.ReadFileVersion("c.txt", shelf, content));
    REQUIRE(t.m_Repo.ReadFileVersion("b.txt", shelf, content));
    CHECK(content == "b\n");
    const auto log = t.m_Repo.Log(LogQuery{10, 0, shelf, ""});
    REQUIRE(log.size() == 2);
    CHECK(log[0].m_Summary == "Shelved CL 1");
    CHECK(log[0].m_Parents.at(0) == base);

    // Re-shelving replaces the shelf.
    t.Write("a.txt", "a again\n");
    const std::string again = t.m_Repo.Shelve("shelves/1", {"a.txt"}, "Shelved CL 1");
    CHECK(again != shelf);
    REQUIRE(t.m_Repo.ReadFileVersion("a.txt", "shelves/1", content));
    CHECK(content == "a again\n");

    CHECK_THROWS_AS(t.m_Repo.Shelve("bad name..", {"a.txt"}, "x"), GitError);
    CHECK_THROWS_AS(t.m_Repo.Shelve("shelves/2", {}, "x"), GitError);
}

TEST_CASE("Unshelve restores shelved changes, merging with local edits", "[depot]")
{
    TempRepo t;
    t.Write("a.txt", "1\n2\n3\n4\n5\n");
    t.Write("b.txt", "b\n");
    t.Write("gone.txt", "g\n");
    t.CommitAll("base");

    t.Write("a.txt", "1\nTWO\n3\n4\n5\n");
    t.Write("new.txt", "new\n");
    fs::remove(t.m_Dir / "gone.txt");
    t.Write("b.txt", "b shelved\n");
    const std::string shelf =
        t.m_Repo.Shelve("shelves/7", {"a.txt", "new.txt", "gone.txt", "b.txt"}, "CL 7");

    // Revert everything, then edit a.txt elsewhere and b.txt on the same line.
    t.m_Repo.DiscardChanges({"a.txt", "b.txt", "gone.txt", "new.txt"});
    REQUIRE(t.m_Repo.Status().empty());
    t.Write("a.txt", "1\n2\n3\n4\nFIVE\n");
    t.Write("b.txt", "b local\n");

    const auto result = t.m_Repo.Unshelve(shelf, {});
    CHECK(t.Read("a.txt") == "1\nTWO\n3\n4\nFIVE\n"); // merged cleanly
    CHECK(t.Read("new.txt") == "new\n");
    CHECK_FALSE(t.Exists("gone.txt"));
    CHECK(std::find(result.m_Conflicted.begin(), result.m_Conflicted.end(), "b.txt") !=
          result.m_Conflicted.end());
    CHECK(t.Read("b.txt").find("<<<<<<<") != std::string::npos);
    CHECK(result.m_Applied.size() == 3);

    // Only some paths.
    t.m_Repo.DiscardChanges({"a.txt", "b.txt", "gone.txt", "new.txt"});
    const auto some = t.m_Repo.Unshelve("shelves/7", {"new.txt"});
    CHECK(some.m_Applied == std::vector<std::string>{"new.txt"});
    CHECK(t.Read("a.txt") == "1\n2\n3\n4\n5\n");
}

TEST_CASE("FileRevisionGraph puts each branch's revisions on its own row", "[depot]")
{
    TempRepo t;
    t.Write("f.txt", "v1\n");
    t.Write("other.txt", "x\n");
    t.CommitAll("add f");
    const std::string mainBranch = t.m_Repo.CurrentBranch();
    t.Write("f.txt", "v2\n");
    t.CommitAll("edit f on main");
    t.Write("other.txt", "y\n");
    t.CommitAll("unrelated");

    t.m_Repo.CreateBranch("topic");
    t.m_Repo.Checkout("topic");
    t.Write("f.txt", "v2\ntopic\n");
    t.CommitAll("edit f on topic");
    t.m_Repo.Checkout(mainBranch);
    t.Write("f.txt", "main\nv2\n");
    t.CommitAll("edit f on main again");
    const auto merged = t.m_Repo.Merge("topic");
    REQUIRE(merged.m_Kind == MergeResult::Kind::Merged);

    const RevisionGraph graph = t.m_Repo.FileRevisionGraph("f.txt");
    REQUIRE(graph.m_Rows.size() == 2);
    CHECK(graph.m_Rows[0].m_Name == mainBranch);
    CHECK(graph.m_Rows[0].m_bHead);
    CHECK(graph.m_Rows[1].m_Name == "topic");

    // add, edit, (topic edit), edit, merge — "unrelated" isn't a revision.
    REQUIRE(graph.m_Nodes.size() == 5);
    CHECK(graph.m_Nodes.front().m_cAction == 'A');
    CHECK(graph.m_Nodes.back().m_cAction == 'I');
    int ntopic = 0;
    for (const auto& node : graph.m_Nodes)
    {
        ntopic += node.m_iRow == 1 ? 1 : 0;
        CHECK(node.m_Commit.m_Summary != "unrelated");
    }
    CHECK(ntopic == 1);
    // Revision numbers count along each row.
    CHECK(graph.m_Nodes.back().m_iRevision == 4);

    // The merge has an integration edge from the topic revision, and the topic
    // revision a branch edge from main's second revision.
    bool bmergeEdge = false;
    bool bbranchEdge = false;
    for (const auto& edge : graph.m_Edges)
    {
        const auto& from = graph.m_Nodes[static_cast<std::size_t>(edge.m_iFrom)];
        const auto& to = graph.m_Nodes[static_cast<std::size_t>(edge.m_iTo)];
        bmergeEdge = bmergeEdge || (edge.m_bMerge && from.m_iRow == 1 && to.m_cAction == 'I');
        bbranchEdge = bbranchEdge || (!edge.m_bMerge && from.m_iRow == 0 && to.m_iRow == 1);
    }
    CHECK(bmergeEdge);
    CHECK(bbranchEdge);

    // Rendering: a box per revision inside the picture.
    gitgud::imaging::RevisionGraphStyle style;
    style.m_iSelected = 0;
    const auto picture = gitgud::imaging::RenderRevisionGraph(graph, style);
    REQUIRE(picture.m_Nodes.size() == graph.m_Nodes.size());
    REQUIRE(picture.m_Rows.size() == 2);
    CHECK(picture.m_Image.m_iHeight == 2 * style.m_iRowHeight + 1);
    for (const auto& box : picture.m_Nodes)
    {
        CHECK(box.m_fX + box.m_fWidth <= static_cast<float>(picture.m_Image.m_iWidth));
    }
    // The selected box is painted in the selection colour (0xFFF36B).
    const auto& sel = picture.m_Nodes[0];
    const int ix = static_cast<int>(sel.m_fX + sel.m_fWidth * 0.75f);
    const int iy = static_cast<int>(sel.m_fY + sel.m_fHeight * 0.5f);
    const auto* ppx =
        &picture.m_Image.m_Rgba[(static_cast<std::size_t>(iy) * picture.m_Image.m_iWidth + ix) * 4];
    CHECK(ppx[0] == 0xFF);
    CHECK(ppx[1] == 0xF3);

    CHECK(t.m_Repo.FileRevisionGraph("never-existed.txt").m_Nodes.empty());
}

TEST_CASE("UI packages: built-ins, custom folders, and the remembered choice", "[ui]")
{
    const fs::path root = fs::temp_directory_path() / "gitgud_uipkg_test";
    std::error_code ec;
    fs::remove_all(root, ec);
    auto touch = [](const fs::path& _File, const std::string& _Text)
    {
        fs::create_directories(_File.parent_path());
        std::ofstream(_File, std::ios::binary) << _Text;
    };
    // resources/ (the default UI) plus two built-ins, one hidden, one broken.
    touch(root / "res/scripts/main.lua", "");
    touch(root / "res/layouts/main.xml", "");
    touch(root / "res/ui.ini", "name=GitGud\n");
    touch(root / "res/uis/depot/scripts/main.lua", "");
    touch(root / "res/uis/depot/layouts/main.xml", "");
    touch(root / "res/uis/depot/ui.ini", "# comment\nname = Depot style\ndescription=Like Depot\n");
    touch(root / "res/uis/picker/scripts/main.lua", "");
    touch(root / "res/uis/picker/layouts/main.xml", "");
    touch(root / "res/uis/picker/ui.ini", "hidden=true\n");
    touch(root / "res/uis/broken/scripts/main.lua", "");
    // A custom package elsewhere, without ui.ini.
    touch(root / "mine/scripts/main.lua", "");
    touch(root / "mine/layouts/main.xml", "");

    const std::string res = (root / "res").u8string();
    const auto list = gitgud::app::ListUiPackages(res);
    REQUIRE(list.size() == 3);
    CHECK(list[0].m_Id == "default");
    CHECK(list[0].m_Name == "GitGud");
    CHECK(list[1].m_Id == "depot");
    CHECK(list[1].m_Name == "Depot style");
    CHECK(list[1].m_Description == "Like Depot");
    CHECK(list[2].m_Id == "picker");
    CHECK(list[2].m_bHidden);

    const std::string custom = "path:" + (root / "mine").u8string();
    const auto mine = gitgud::app::ResolveUiPackage(custom, res);
    REQUIRE(mine.has_value());
    CHECK(mine->m_Name == "mine");
    CHECK_FALSE(mine->m_bBuiltIn);
    CHECK(mine->ScriptsDir().find("/mine/scripts") != std::string::npos);
    CHECK_FALSE(gitgud::app::ResolveUiPackage("broken", res).has_value());
    CHECK_FALSE(gitgud::app::ResolveUiPackage("path:" + (root / "nope").u8string(), res));

    const std::string config = (root / "config").u8string();
    CHECK(gitgud::app::ReadUiChoice(config).empty());
    REQUIRE(gitgud::app::WriteUiChoice(config, custom));
    CHECK(gitgud::app::ReadUiChoice(config) == custom);

    fs::remove_all(root, ec);
}
