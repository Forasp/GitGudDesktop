// Repository::Summarize: a folder's repository at a glance, for the Bragi
// UI's session panel (the Changes and Environment cards).

#include "git/LibGit2Internal.h"

#include <algorithm>
#include <string>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        // A path with forward slashes and no slash at the end.
        std::string Tidy(std::string _Path)
        {
            std::replace(_Path.begin(), _Path.end(), '\\', '/');
            while (_Path.size() > 1 && _Path.back() == '/')
            {
                _Path.pop_back();
            }
            return _Path;
        }

        // The branch HEAD names, checked out or unborn; "" when detached.
        std::string HeadBranch(git_repository* _pRepo)
        {
            ReferencePtr head;
            if (git_reference_lookup(&head.m_pP, _pRepo, "HEAD") < 0 ||
                git_reference_type(head.m_pP) != GIT_REFERENCE_SYMBOLIC)
            {
                return {};
            }
            const std::string target = git_reference_symbolic_target(head.m_pP);
            const std::string prefix = "refs/heads/";
            return target.rfind(prefix, 0) == 0 ? target.substr(prefix.size()) : std::string();
        }

    } // namespace

    FolderSummary Repository::Summarize(const std::string& _Folder)
    {
        RepositoryPtr repo;
        if (git_repository_open_ext(&repo.m_pP, _Folder.c_str(), 0, nullptr) < 0)
        {
            RaiseLastError("No Git repository at '" + _Folder + "'");
        }
        const char* szworkdir = git_repository_workdir(repo.m_pP);
        if (!szworkdir)
        {
            throw GitError("'" + _Folder + "' is in a bare repository");
        }

        FolderSummary out;
        out.m_Root = Tidy(szworkdir);
        out.m_CommonDir = Tidy(git_repository_commondir(repo.m_pP));
        out.m_Branch = HeadBranch(repo.m_pP);
        if (git_repository_is_worktree(repo.m_pP) == 1)
        {
            WorktreePtr worktree;
            if (git_worktree_open_from_repository(&worktree.m_pP, repo.m_pP) == 0)
            {
                out.m_Worktree = git_worktree_name(worktree.m_pP);
            }
        }

        // HEAD's tree; none on an unborn branch (everything is added).
        TreePtr tree;
        ObjectPtr head;
        if (git_revparse_single(&head.m_pP, repo.m_pP, "HEAD^{tree}") == 0)
        {
            tree.m_pP = reinterpret_cast<git_tree*>(head.m_pP);
            head.m_pP = nullptr;
            ObjectPtr commit;
            if (git_revparse_single(&commit.m_pP, repo.m_pP, "HEAD") == 0)
            {
                char aszOid[16] = {};
                git_oid_tostr(aszOid, 8, git_object_id(commit.m_pP));
                out.m_Head = aszOid;
            }
        }

        git_strarray names = {};
        if (git_remote_list(&names, repo.m_pP) == 0)
        {
            for (size_t i = 0; i < names.count; ++i)
            {
                RemotePtr remote;
                if (git_remote_lookup(&remote.m_pP, repo.m_pP, names.strings[i]) == 0)
                {
                    const char* szurl = git_remote_url(remote.m_pP);
                    out.m_Remotes.push_back({names.strings[i], szurl ? szurl : ""});
                }
            }
            git_strarray_dispose(&names);
        }

        // HEAD against the working tree through the index: staged, unstaged,
        // and untracked files alike. Big files count as binary (no lines).
        git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
        opts.flags = GIT_DIFF_INCLUDE_UNTRACKED | GIT_DIFF_RECURSE_UNTRACKED_DIRS |
                     GIT_DIFF_SHOW_UNTRACKED_CONTENT;
        opts.max_size = 2 * 1024 * 1024;
        DiffPtr diff;
        if (git_diff_tree_to_workdir_with_index(&diff.m_pP, repo.m_pP, tree.m_pP, &opts) < 0)
        {
            RaiseLastError("Couldn't compare the working tree with HEAD");
        }
        git_diff_stats* pstats = nullptr;
        if (git_diff_get_stats(&pstats, diff.m_pP) == 0)
        {
            out.m_iFiles = static_cast<int>(git_diff_stats_files_changed(pstats));
            out.m_iAdded = static_cast<int>(git_diff_stats_insertions(pstats));
            out.m_iRemoved = static_cast<int>(git_diff_stats_deletions(pstats));
            git_diff_stats_free(pstats);
        }
        return out;
    }

} // namespace gitgud::git
