// -----------------------------------------------------------------------------
// Repository — browsing a revision's files and comparing arbitrary versions:
// ListTree (a depot-style folder tree), DiffVersions (any two versions of a
// file), ChangedFiles (which files differ between two revisions).
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <algorithm>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        // Resolve a commit-ish to its tree ("head" and "HEAD" alike). Empty
        // holder on an unborn branch, and for "" (nothing: diff from empty).
        TreePtr RevisionTree(git_repository* _pRepo, const std::string& _Revision)
        {
            if (_Revision.empty())
            {
                return {};
            }
            const std::string spec = _Revision == "head" ? "HEAD" : _Revision;
            ObjectPtr obj;
            if (git_revparse_single(&obj.m_pP, _pRepo, spec.c_str()) != 0)
            {
                if (spec == "HEAD")
                {
                    return {}; // unborn
                }
                RaiseLastError("Unknown revision '" + _Revision + "'");
            }
            ObjectPtr tree;
            if (git_object_peel(&tree.m_pP, obj.m_pP, GIT_OBJECT_TREE) < 0)
            {
                RaiseLastError("'" + _Revision + "' has no tree");
            }
            TreePtr out;
            out.m_pP = reinterpret_cast<git_tree*>(tree.m_pP);
            tree.m_pP = nullptr;
            return out;
        }

        char StatusLetter(git_delta_t _Status)
        {
            switch (_Status)
            {
            case GIT_DELTA_ADDED:
            case GIT_DELTA_UNTRACKED:
                return 'A';
            case GIT_DELTA_DELETED:
                return 'D';
            case GIT_DELTA_RENAMED:
                return 'R';
            case GIT_DELTA_TYPECHANGE:
                return 'T';
            default:
                return 'M';
            }
        }

    } // namespace

    std::vector<TreeEntry> Repository::ListTree(
        const std::string& _Revision, const std::string& _Dir) const
    {
        if (!m_pRepo)
        {
            throw GitError("listTree() on an unopened repository");
        }
        TreePtr root = RevisionTree(m_pRepo, _Revision);
        if (!root.m_pP)
        {
            return {};
        }

        std::string dir = _Dir;
        while (!dir.empty() && dir.back() == '/')
        {
            dir.pop_back();
        }

        TreePtr sub;
        git_tree* ptree = root.m_pP;
        if (!dir.empty())
        {
            TreeEntryPtr entry;
            if (git_tree_entry_bypath(&entry.m_pP, root.m_pP, dir.c_str()) != 0 ||
                git_tree_entry_type(entry.m_pP) != GIT_OBJECT_TREE)
            {
                return {};
            }
            if (git_tree_lookup(&sub.m_pP, m_pRepo, git_tree_entry_id(entry.m_pP)) < 0)
            {
                RaiseLastError("git_tree_lookup failed");
            }
            ptree = sub.m_pP;
        }

        // Sizes come from object headers: no blob is loaded.
        Handle<git_odb, git_odb_free> odb;
        git_repository_odb(&odb.m_pP, m_pRepo);

        std::vector<TreeEntry> out;
        const std::size_t ncount = git_tree_entrycount(ptree);
        out.reserve(ncount);
        for (std::size_t i = 0; i < ncount; ++i)
        {
            const git_tree_entry* pentry = git_tree_entry_byindex(ptree, i);
            TreeEntry entry;
            entry.m_Name = git_tree_entry_name(pentry);
            entry.m_Path = dir.empty() ? entry.m_Name : dir + "/" + entry.m_Name;
            entry.m_Oid = OidToHex(git_tree_entry_id(pentry));
            const git_object_t type = git_tree_entry_type(pentry);
            entry.m_bIsDir = type == GIT_OBJECT_TREE;
            entry.m_bIsSubmodule = type == GIT_OBJECT_COMMIT;
            if (type == GIT_OBJECT_BLOB && odb.m_pP)
            {
                std::size_t nsize = 0;
                git_object_t headerType = GIT_OBJECT_ANY;
                if (git_odb_read_header(&nsize, &headerType, odb.m_pP, git_tree_entry_id(pentry)) ==
                    0)
                {
                    entry.m_Size = static_cast<std::int64_t>(nsize);
                }
            }
            out.push_back(std::move(entry));
        }
        std::stable_sort(out.begin(), out.end(),
            [](const TreeEntry& _A, const TreeEntry& _B)
            {
                if (_A.m_bIsDir != _B.m_bIsDir)
                {
                    return _A.m_bIsDir;
                }
                return _A.m_Name < _B.m_Name;
            });
        return out;
    }

    FileDiff Repository::DiffVersions(const std::string& _OldPath, const std::string& _OldRevision,
        const std::string& _NewPath, const std::string& _NewRevision,
        const DiffOptions& _Options) const
    {
        if (!m_pRepo)
        {
            throw GitError("diffVersions() on an unopened repository");
        }
        const FileVersion before = ReadVersion(m_pRepo, _OldPath, _OldRevision);
        const FileVersion after = ReadVersion(m_pRepo, _NewPath, _NewRevision);
        return DiffFileVersions(_OldPath, before, _NewPath, after, _Options);
    }

    std::vector<ChangedFile> Repository::ChangedFiles(const std::string& _OldRevision,
        const std::string& _NewRevision, const std::string& _Prefix) const
    {
        if (!m_pRepo)
        {
            throw GitError("changedFiles() on an unopened repository");
        }
        TreePtr before = RevisionTree(m_pRepo, _OldRevision);

        git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
        std::string prefix = _Prefix;
        while (!prefix.empty() && prefix.back() == '/')
        {
            prefix.pop_back();
        }
        char* szspec = prefix.data();
        if (!prefix.empty())
        {
            opts.pathspec.strings = &szspec;
            opts.pathspec.count = 1;
        }

        DiffPtr diff;
        if (_NewRevision == "workdir")
        {
            opts.flags |= GIT_DIFF_INCLUDE_UNTRACKED | GIT_DIFF_RECURSE_UNTRACKED_DIRS;
            if (git_diff_tree_to_workdir_with_index(&diff.m_pP, m_pRepo, before.m_pP, &opts) < 0)
            {
                RaiseLastError("git_diff_tree_to_workdir_with_index failed");
            }
        }
        else
        {
            TreePtr after = RevisionTree(m_pRepo, _NewRevision);
            if (git_diff_tree_to_tree(&diff.m_pP, m_pRepo, before.m_pP, after.m_pP, &opts) < 0)
            {
                RaiseLastError("git_diff_tree_to_tree failed");
            }
        }

        git_diff_find_options findOpts = GIT_DIFF_FIND_OPTIONS_INIT;
        findOpts.flags = GIT_DIFF_FIND_RENAMES | GIT_DIFF_FIND_FOR_UNTRACKED;
        git_diff_find_similar(diff.m_pP, &findOpts);

        std::vector<ChangedFile> out;
        const std::size_t ncount = git_diff_num_deltas(diff.m_pP);
        for (std::size_t i = 0; i < ncount; ++i)
        {
            const git_diff_delta* pdelta = git_diff_get_delta(diff.m_pP, i);
            ChangedFile file;
            file.m_cStatus = StatusLetter(pdelta->status);
            file.m_Path = pdelta->new_file.path ? pdelta->new_file.path : pdelta->old_file.path;
            file.m_OldPath = pdelta->old_file.path ? pdelta->old_file.path : file.m_Path;
            out.push_back(std::move(file));
        }
        return out;
    }

} // namespace gitgud::git
