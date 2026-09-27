// -----------------------------------------------------------------------------
// Repository — submodules and worktrees: listing them, updating a submodule
// to the commit its parent records, and adding / removing linked worktrees.
// Same layer rules as Repository.h: RAII, plain data out, GitError on failure.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <filesystem>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        namespace fs = std::filesystem;

        void RequireOpen(git_repository* _pRepo, const char* _szWhat)
        {
            if (!_pRepo)
            {
                throw GitError(std::string(_szWhat) + " on an unopened repository");
            }
        }

        std::string ForwardSlashes(std::string _Path)
        {
            for (char& c : _Path)
            {
                if (c == '\\')
                {
                    c = '/';
                }
            }
            while (_Path.size() > 1 && _Path.back() == '/')
            {
                _Path.pop_back();
            }
            return _Path;
        }

        // Checked-out branch of a repository ("" when detached / unborn).
        std::string BranchOf(git_repository* _pRepo)
        {
            ReferencePtr head;
            if (git_repository_head(&head.m_pP, _pRepo) != 0 ||
                git_repository_head_detached(_pRepo) == 1)
            {
                return {};
            }
            const char* szname = git_reference_shorthand(head.m_pP);
            return szname ? szname : "";
        }

        // Any change (staged, unstaged, or untracked) in this working tree?
        bool HasChanges(git_repository* _pRepo)
        {
            git_status_options opts = GIT_STATUS_OPTIONS_INIT;
            opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED;
            git_status_list* plist = nullptr;
            if (git_status_list_new(&plist, _pRepo, &opts) < 0)
            {
                return true; // can't tell: treat as dirty, i.e. refuse to delete
            }
            const bool bany = git_status_list_entrycount(plist) > 0;
            git_status_list_free(plist);
            return bany;
        }

    } // namespace

    // ---- Submodules --------------------------------------------------------------

    std::vector<SubmoduleInfo> Repository::Submodules() const
    {
        RequireOpen(m_pRepo, "submodules()");

        std::vector<SubmoduleInfo> out;
        git_submodule_foreach(
            m_pRepo,
            [](git_submodule* _pSub, const char* _szName, void* _pPayload) -> int
            {
                auto* pout = static_cast<std::vector<SubmoduleInfo>*>(_pPayload);
                SubmoduleInfo info;
                info.m_Name = _szName ? _szName : "";
                if (const char* szpath = git_submodule_path(_pSub))
                {
                    info.m_Path = szpath;
                }
                if (const char* szurl = git_submodule_url(_pSub))
                {
                    info.m_Url = szurl;
                }
                if (const git_oid* phead = git_submodule_head_id(_pSub))
                {
                    info.m_HeadOid = OidToHex(phead);
                }
                if (const git_oid* pwork = git_submodule_wd_id(_pSub))
                {
                    info.m_WorkdirOid = OidToHex(pwork);
                }

                unsigned int uistatus = 0;
                git_submodule_status(&uistatus, git_submodule_owner(_pSub), info.m_Name.c_str(),
                    GIT_SUBMODULE_IGNORE_NONE);
                info.m_bInitialized = (uistatus & GIT_SUBMODULE_STATUS_WD_UNINITIALIZED) == 0 &&
                                      (uistatus & GIT_SUBMODULE_STATUS_IN_WD) != 0;
                info.m_bModified = (uistatus & GIT_SUBMODULE_STATUS_WD_MODIFIED) != 0;
                info.m_bDirty = (uistatus & (GIT_SUBMODULE_STATUS_WD_INDEX_MODIFIED |
                                                GIT_SUBMODULE_STATUS_WD_WD_MODIFIED |
                                                GIT_SUBMODULE_STATUS_WD_UNTRACKED)) != 0;
                pout->push_back(std::move(info));
                return 0;
            },
            &out);
        return out;
    }

    void Repository::UpdateSubmodule(const std::string& _Name, bool _bInit)
    {
        RequireOpen(m_pRepo, "updateSubmodule()");

        SubmodulePtr sub;
        if (git_submodule_lookup(&sub.m_pP, m_pRepo, _Name.c_str()) < 0)
        {
            RaiseLastError("No such submodule '" + _Name + "'");
        }

        RemoteContext ctx;
        ctx.m_pProvider = &m_CredProvider;
        ctx.m_pHostKeys = &m_HostKeyProvider;
        git_submodule_update_options opts = GIT_SUBMODULE_UPDATE_OPTIONS_INIT;
        opts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE;
        SetupRemoteCallbacks(opts.fetch_opts.callbacks, ctx);
        if (git_submodule_update(sub.m_pP, _bInit ? 1 : 0, &opts) < 0)
        {
            RaiseLastError("Updating submodule '" + _Name + "' failed");
        }
    }

    // ---- Worktrees -----------------------------------------------------------------

    std::vector<WorktreeInfo> Repository::Worktrees() const
    {
        RequireOpen(m_pRepo, "worktrees()");

        std::vector<WorktreeInfo> out;

        // The main working tree (of the repository this one belongs to).
        WorktreeInfo main;
        main.m_bMain = true;
        const char* szcommon = git_repository_commondir(m_pRepo);
        if (szcommon)
        {
            fs::path common = fs::u8path(szcommon);
            std::string commonText = ForwardSlashes(common.u8string());
            // A non-bare repository's common dir is "<worktree>/.git".
            if (commonText.size() > 5 && commonText.compare(commonText.size() - 5, 5, "/.git") == 0)
            {
                main.m_Path = commonText.substr(0, commonText.size() - 5);
                RepositoryPtr mainRepo;
                if (git_repository_open(&mainRepo.m_pP, main.m_Path.c_str()) == 0)
                {
                    main.m_Branch = BranchOf(mainRepo.m_pP);
                }
            }
        }
        main.m_Name = main.m_Path.empty() ? "main" : fs::u8path(main.m_Path).filename().u8string();
        if (!main.m_Path.empty())
        {
            out.push_back(std::move(main));
        }

        StrArray names;
        if (git_worktree_list(&names.m_A, m_pRepo) < 0)
        {
            RaiseLastError("git_worktree_list failed");
        }
        for (std::size_t i = 0; i < names.m_A.count; ++i)
        {
            WorktreePtr wt;
            if (git_worktree_lookup(&wt.m_pP, m_pRepo, names.m_A.strings[i]) < 0)
            {
                continue;
            }
            WorktreeInfo info;
            info.m_Name = names.m_A.strings[i];
            if (const char* szpath = git_worktree_path(wt.m_pP))
            {
                info.m_Path = ForwardSlashes(szpath);
            }
            info.m_bLocked = git_worktree_is_locked(nullptr, wt.m_pP) > 0;
            info.m_bValid = git_worktree_validate(wt.m_pP) == 0;
            if (info.m_bValid)
            {
                RepositoryPtr wtRepo;
                if (git_repository_open_from_worktree(&wtRepo.m_pP, wt.m_pP) == 0)
                {
                    info.m_Branch = BranchOf(wtRepo.m_pP);
                }
            }
            out.push_back(std::move(info));
        }
        return out;
    }

    void Repository::AddWorktree(
        const std::string& _Name, const std::string& _Path, const std::string& _Branch)
    {
        RequireOpen(m_pRepo, "addWorktree()");

        std::error_code ec;
        if (fs::exists(fs::u8path(_Path), ec) && !fs::is_empty(fs::u8path(_Path), ec))
        {
            throw GitError("'" + _Path + "' already exists and isn't empty");
        }

        // The branch to check out there: reuse it, or create it from HEAD.
        const std::string branch = _Branch.empty() ? _Name : _Branch;
        ReferencePtr ref;
        if (git_branch_lookup(&ref.m_pP, m_pRepo, branch.c_str(), GIT_BRANCH_LOCAL) != 0)
        {
            CommitPtr head = ResolveCommit(m_pRepo, "HEAD");
            if (git_branch_create(&ref.m_pP, m_pRepo, branch.c_str(), head.m_pP, 0) < 0)
            {
                RaiseLastError("Creating branch '" + branch + "' failed");
            }
        }
        else if (git_branch_is_checked_out(ref.m_pP) == 1)
        {
            throw GitError("'" + branch + "' is already checked out in another working tree");
        }

        git_worktree_add_options opts = GIT_WORKTREE_ADD_OPTIONS_INIT;
        opts.ref = ref.m_pP;
        WorktreePtr wt;
        if (git_worktree_add(&wt.m_pP, m_pRepo, _Name.c_str(), _Path.c_str(), &opts) < 0)
        {
            RaiseLastError("Adding the worktree failed");
        }
    }

    void Repository::RemoveWorktree(const std::string& _Name)
    {
        RequireOpen(m_pRepo, "removeWorktree()");

        WorktreePtr wt;
        if (git_worktree_lookup(&wt.m_pP, m_pRepo, _Name.c_str()) < 0)
        {
            RaiseLastError("No such worktree '" + _Name + "'");
        }
        if (git_worktree_is_locked(nullptr, wt.m_pP) > 0)
        {
            throw GitError("The worktree '" + _Name + "' is locked");
        }

        if (git_worktree_validate(wt.m_pP) == 0)
        {
            RepositoryPtr wtRepo;
            if (git_repository_open_from_worktree(&wtRepo.m_pP, wt.m_pP) == 0 &&
                HasChanges(wtRepo.m_pP))
            {
                throw GitError("The worktree '" + _Name +
                               "' has uncommitted changes; commit or discard them first");
            }
        }

        git_worktree_prune_options opts = GIT_WORKTREE_PRUNE_OPTIONS_INIT;
        opts.flags = GIT_WORKTREE_PRUNE_VALID | GIT_WORKTREE_PRUNE_WORKING_TREE;
        if (git_worktree_prune(wt.m_pP, &opts) < 0)
        {
            RaiseLastError("Removing the worktree failed");
        }
    }

} // namespace gitgud::git
