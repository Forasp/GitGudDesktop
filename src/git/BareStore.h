#pragma once

// -----------------------------------------------------------------------------
// BareStore: files kept in a bare Git repository, each change a commit, so
// every file has its history (the Bragi interface's local wikis: one
// "<project>.wiki.git" per project, the layout a Git host uses, so a wiki
// can later be pushed somewhere as it is).
//
// Paths inside the store use '/' ("guides/Deep-Dive.md"). Revisions are
// anything libgit2 resolves ("HEAD", a commit id); empty means HEAD. A store
// with no commits yet has no files and an empty log. Every call works on
// the repository on disk (open, act, close): nothing is held between calls.
// Errors throw GitError.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace gitgud::git
{

    struct StoreFile
    {
        std::string m_Path;
        std::uint64_t m_uSize = 0;
    };

    struct StoreCommit
    {
        std::string m_Id;
        std::string m_Message;
        std::string m_Author;
        std::int64_t m_iTime = 0; // seconds since 1970, UTC
    };

    // One change of a commit: the file's new content, or removal.
    struct StoreChange
    {
        std::string m_Path;
        std::optional<std::string> m_Content; // nullopt: remove the file
    };

    namespace barestore
    {

        // Make a bare repository at `_Path` (its branch "main") unless one is
        // there already.
        void Init(const std::string& _Path);

        // Whether `_Path` holds a repository.
        bool Exists(const std::string& _Path);

        // Every file at `_Ref`, sorted by path.
        std::vector<StoreFile> Files(const std::string& _Path, const std::string& _Ref = "");

        // A file's content at `_Ref`; nullopt when it isn't there.
        std::optional<std::string> Read(
            const std::string& _Path, const std::string& _File, const std::string& _Ref = "");

        // Apply `_Changes` on top of HEAD as one commit (made if missing) by
        // `_Name` <`_Email`>; the new commit's id. Nothing changes and ""
        // comes back when the changes leave the files as they were.
        std::string Commit(const std::string& _Path, const std::vector<StoreChange>& _Changes,
            const std::string& _Message, const std::string& _Name, const std::string& _Email);

        // Commits from HEAD back, newest first, at most `_nMax`; only those
        // that changed `_File` when it's given.
        std::vector<StoreCommit> Log(
            const std::string& _Path, const std::string& _File = "", std::size_t _nMax = 50);

    } // namespace barestore

} // namespace gitgud::git
