// -----------------------------------------------------------------------------
// Repository — Branches, history, remotes, stash, and merge.
// Same class as Repository.cpp; split by topic so no single file balloons.
// Follows the layer rules from Repository.h: RAII everywhere, plain-data
// returns, GitError on failure.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <git2/sys/errors.h>

#include <utility>

namespace gitgud::git
{

    using namespace internal;

    // ---- Branches --------------------------------------------------------------

    namespace
    {

        // Upstreams for a whole branch listing. git_branch_upstream re-reads the
        // configuration (a stat of every config file) and looks the remote up
        // again for every branch; this reads one config snapshot and each remote
        // once, with the same rules (branch.<name>.remote/.merge, mapped through
        // the remote's first matching fetch refspec).
        class UpstreamResolver
        {
          public:
            explicit UpstreamResolver(git_repository* _pRepo) : m_pRepo(_pRepo)
            {
                if (git_repository_config_snapshot(&m_Config.m_pP, _pRepo) < 0)
                {
                    git_error_clear(); // no config: no upstreams
                }
            }

            // Full ref name of local branch _Branch's upstream, or "".
            std::string RefName(const std::string& _Branch)
            {
                const std::string remote = Get("branch." + _Branch + ".remote");
                const std::string merge = Get("branch." + _Branch + ".merge");
                if (remote.empty() || merge.empty())
                {
                    return {};
                }
                if (remote == ".")
                {
                    return merge; // tracks another local branch
                }

                git_remote* premote = Remote(remote);
                if (!premote)
                {
                    return {};
                }
                const std::size_t nspecs = git_remote_refspec_count(premote);
                for (std::size_t ni = 0; ni < nspecs; ++ni)
                {
                    const git_refspec* pspec = git_remote_get_refspec(premote, ni);
                    if (git_refspec_direction(pspec) != GIT_DIRECTION_FETCH ||
                        git_refspec_src_matches(pspec, merge.c_str()) == 0)
                    {
                        continue;
                    }
                    Buf dst;
                    if (git_refspec_transform(&dst.m_B, pspec, merge.c_str()) == 0)
                    {
                        return dst.Str();
                    }
                    break;
                }
                git_error_clear();
                return {};
            }

          private:
            std::string Get(const std::string& _Key) const
            {
                const char* szvalue = nullptr;
                if (!m_Config.m_pP ||
                    git_config_get_string(&szvalue, m_Config.m_pP, _Key.c_str()) != 0)
                {
                    git_error_clear();
                    return {};
                }
                return szvalue ? szvalue : "";
            }

            git_remote* Remote(const std::string& _Name)
            {
                for (auto& [name, remote] : m_Remotes)
                {
                    if (name == _Name)
                    {
                        return remote.m_pP;
                    }
                }
                RemotePtr remote;
                if (git_remote_lookup(&remote.m_pP, m_pRepo, _Name.c_str()) != 0)
                {
                    git_error_clear();
                }
                m_Remotes.emplace_back(_Name, std::move(remote));
                return m_Remotes.back().second.m_pP;
            }

            git_repository* m_pRepo;
            ConfigPtr m_Config;
            std::vector<std::pair<std::string, RemotePtr>> m_Remotes;
        };

    } // namespace

    std::vector<BranchInfo> Repository::Branches() const
    {
        if (m_pP4)
        {
            return m_pP4->Branches();
        }

        if (!m_pRepo)
        {
            throw GitError("branches() on an unopened repository");
        }

        BranchIteratorPtr it;
        if (git_branch_iterator_new(&it.m_pP, m_pRepo, GIT_BRANCH_ALL) < 0)
        {
            RaiseLastError("git_branch_iterator_new failed");
        }

        // HEAD is read once, not once per branch (git_branch_is_head).
        std::string headRef;
        {
            ReferencePtr head;
            if (git_repository_head(&head.m_pP, m_pRepo) == 0)
            {
                headRef = git_reference_name(head.m_pP);
            }
            git_error_clear();
        }
        UpstreamResolver upstreams(m_pRepo);

        std::vector<BranchInfo> out;
        git_reference* pref = nullptr;
        git_branch_t type;
        while (git_branch_next(&pref, &type, it.m_pP) == 0)
        {
            ReferencePtr holder;
            holder.m_pP = pref;
            BranchInfo b;
            const char* szname = nullptr;
            if (git_branch_name(&szname, pref) == 0 && szname)
            {
                b.m_Name = szname;
            }
            b.m_bIsRemote = (type == GIT_BRANCH_REMOTE);
            b.m_bIsHead = !b.m_bIsRemote && headRef == git_reference_name(pref);

            // Remote HEAD aliases ("origin/HEAD") duplicate a real branch.
            if (b.m_bIsRemote && b.m_Name.size() >= 5 &&
                b.m_Name.compare(b.m_Name.size() - 5, 5, "/HEAD") == 0)
            {
                continue;
            }

            ObjectPtr tip;
            if (git_reference_peel(&tip.m_pP, pref, GIT_OBJECT_COMMIT) == 0)
            {
                b.m_TargetOid = OidToHex(git_object_id(tip.m_pP));
                b.m_TimeUtc = static_cast<std::int64_t>(
                    git_commit_time(reinterpret_cast<git_commit*>(tip.m_pP)));
            }

            if (!b.m_bIsRemote)
            {
                const std::string upstreamRef = upstreams.RefName(b.m_Name);
                ReferencePtr upstream;
                if (!upstreamRef.empty() &&
                    git_reference_lookup(&upstream.m_pP, m_pRepo, upstreamRef.c_str()) == 0)
                {
                    const char* szupName = nullptr;
                    if (git_branch_name(&szupName, upstream.m_pP) == 0 && szupName)
                    {
                        b.m_Upstream = szupName;
                    }

                    const git_oid* plocal = git_reference_target(pref);
                    const git_oid* premote = git_reference_target(upstream.m_pP);
                    if (plocal && premote)
                    {
                        git_graph_ahead_behind(&b.m_Ahead, &b.m_Behind, m_pRepo, plocal, premote);
                    }
                }
            }
            out.push_back(std::move(b));
        }
        return out;
    }

    std::string Repository::CurrentBranch() const
    {
        if (m_pP4)
        {
            return m_pP4->CurrentBranch();
        }

        if (!m_pRepo)
        {
            throw GitError("currentBranch() on an unopened repository");
        }

        ReferencePtr head;
        const int irc = git_repository_head(&head.m_pP, m_pRepo);
        if (irc == 0)
        {
            if (git_repository_head_detached(m_pRepo) == 1)
            {
                return {};
            }
            const char* szsh = git_reference_shorthand(head.m_pP);
            return szsh ? szsh : "";
        }
        if (irc == GIT_EUNBORNBRANCH || irc == GIT_ENOTFOUND)
        {
            // Unborn: HEAD is a symbolic ref to the branch the first commit will
            // create. Surface that m_Name so the UI can say "Commit to main".
            ReferencePtr symbolic;
            if (git_reference_lookup(&symbolic.m_pP, m_pRepo, "HEAD") == 0)
            {
                const char* sztarget = git_reference_symbolic_target(symbolic.m_pP);
                if (sztarget)
                {
                    const std::string t(sztarget);
                    const std::string prefix = "refs/heads/";
                    if (t.rfind(prefix, 0) == 0)
                    {
                        return t.substr(prefix.size());
                    }
                }
            }
            return {};
        }
        RaiseLastError("git_repository_head failed");
    }

    void Repository::CreateBranch(const std::string& _Name)
    {
        if (m_pP4)
        {
            m_pP4->CreateBranch(_Name, "");
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("createBranch() on an unopened repository");
        }

        git_oid headOid;
        if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") < 0)
        {
            throw GitError("Cannot create a branch before the first commit");
        }
        CommitPtr commit;
        if (git_commit_lookup(&commit.m_pP, m_pRepo, &headOid) < 0)
        {
            RaiseLastError("git_commit_lookup failed");
        }
        ReferencePtr branch;
        if (git_branch_create(&branch.m_pP, m_pRepo, _Name.c_str(), commit.m_pP,
                /*force=*/0) < 0)
        {
            RaiseLastError("Failed to create branch '" + _Name + "'");
        }
    }

    void Repository::Checkout(const std::string& _Name)
    {
        if (m_pP4)
        {
            m_pP4->Checkout(_Name);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("checkout() on an unopened repository");
        }

        std::string localRefName = "refs/heads/" + _Name;
        ReferencePtr ref;
        if (git_reference_lookup(&ref.m_pP, m_pRepo, localRefName.c_str()) != 0)
        {
            // Not a local branch. If it names a remote-tracking branch (e.g.
            // "origin/feature"), create a local branch from it and
            // check that out instead.
            const std::string remoteRefName = "refs/remotes/" + _Name;
            ReferencePtr remoteRef;
            if (git_reference_lookup(&remoteRef.m_pP, m_pRepo, remoteRefName.c_str()) != 0)
            {
                throw GitError("No such branch '" + _Name + "'");
            }
            const auto slash = _Name.find_last_of('/');
            const std::string localName =
                (slash == std::string::npos) ? _Name : _Name.substr(slash + 1);

            ObjectPtr target;
            if (git_reference_peel(&target.m_pP, remoteRef.m_pP, GIT_OBJECT_COMMIT) < 0)
            {
                RaiseLastError("Failed to peel '" + _Name + "' to a commit");
            }
            ReferencePtr created;
            if (git_branch_create(&created.m_pP, m_pRepo, localName.c_str(),
                    reinterpret_cast<git_commit*>(target.m_pP),
                    /*force=*/0) < 0)
            {
                RaiseLastError("Failed to create local branch '" + localName + "'");
            }
            git_branch_set_upstream(created.m_pP, _Name.c_str()); // best effort
            Checkout(localName);
            return;
        }

        ObjectPtr treeish;
        if (git_reference_peel(&treeish.m_pP, ref.m_pP, GIT_OBJECT_TREE) < 0)
        {
            RaiseLastError("Failed to peel '" + _Name + "' to a tree");
        }

        git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
        opts.checkout_strategy = GIT_CHECKOUT_SAFE;
        if (const int ierr = git_checkout_tree(m_pRepo, treeish.m_pP, &opts); ierr < 0)
        {
            RaiseUpdateFailure(ierr, "Checkout of '" + _Name + "' failed", m_pRepo,
                [&]
                {
                    return std::make_pair(HeadTree(m_pRepo),
                        DupTree(reinterpret_cast<git_tree*>(treeish.m_pP)));
                });
        }
        if (git_repository_set_head(m_pRepo, localRefName.c_str()) < 0)
        {
            RaiseLastError("git_repository_set_head failed");
        }
    }

    void Repository::DeleteBranch(const std::string& _Name)
    {
        if (m_pP4)
        {
            m_pP4->DeleteBranch(_Name);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("deleteBranch() on an unopened repository");
        }

        ReferencePtr ref;
        if (git_branch_lookup(&ref.m_pP, m_pRepo, _Name.c_str(), GIT_BRANCH_LOCAL) < 0)
        {
            RaiseLastError("No such local branch '" + _Name + "'");
        }
        if (git_branch_delete(ref.m_pP) < 0)
        {
            RaiseLastError("Failed to delete branch '" + _Name + "'");
        }
    }

    void Repository::RenameBranch(const std::string& _OldName, const std::string& _NewName)
    {
        if (m_pP4)
        {
            m_pP4->RenameBranch(_OldName, _NewName);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("renameBranch() on an unopened repository");
        }

        ReferencePtr ref;
        if (git_branch_lookup(&ref.m_pP, m_pRepo, _OldName.c_str(), GIT_BRANCH_LOCAL) < 0)
        {
            RaiseLastError("No such local branch '" + _OldName + "'");
        }
        ReferencePtr renamed;
        if (git_branch_move(&renamed.m_pP, ref.m_pP, _NewName.c_str(), /*force=*/0) < 0)
        {
            RaiseLastError("Failed to rename branch '" + _OldName + "' to '" + _NewName + "'");
        }
    }

    // ---- History ---------------------------------------------------------------

    std::vector<CommitInfo> Repository::Log(std::size_t _MaxCount) const
    {
        LogQuery query;
        query.m_MaxCount = _MaxCount;
        return Log(query);
    }

    std::vector<CommitInfo> Repository::Log(const LogQuery& _Query) const
    {
        if (m_pP4)
        {
            return m_pP4->Log(_Query);
        }

        if (!m_pRepo)
        {
            throw GitError("log() on an unopened repository");
        }

        RevwalkPtr walk;
        if (git_revwalk_new(&walk.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_revwalk_new failed");
        }
        git_revwalk_sorting(walk.m_pP, GIT_SORT_TOPOLOGICAL | GIT_SORT_TIME);

        if (_Query.m_From.empty())
        {
            if (git_revwalk_push_head(walk.m_pP) < 0)
            {
                return {}; // unborn HEAD: no history yet
            }
        }
        else
        {
            CommitPtr from = ResolveCommit(m_pRepo, _Query.m_From);
            if (git_revwalk_push(walk.m_pP, git_commit_id(from.m_pP)) < 0)
            {
                RaiseLastError("git_revwalk_push failed");
            }
        }

        if (!_Query.m_Hide.empty())
        {
            ObjectPtr hide;
            if (git_revparse_single(&hide.m_pP, m_pRepo, _Query.m_Hide.c_str()) == 0)
            {
                ObjectPtr hideCommit;
                if (git_object_peel(&hideCommit.m_pP, hide.m_pP, GIT_OBJECT_COMMIT) == 0)
                {
                    git_revwalk_hide(walk.m_pP, git_object_id(hideCommit.m_pP));
                }
            }
        }

        std::vector<CommitInfo> out;
        std::size_t skipped = 0;
        git_oid oid;
        while (out.size() < _Query.m_MaxCount && git_revwalk_next(&oid, walk.m_pP) == 0)
        {
            if (skipped < _Query.m_Skip)
            {
                ++skipped;
                continue;
            }

            CommitInfo info;
            if (ReadCommitInfo(m_pRepo, &oid, info))
            {
                out.push_back(std::move(info));
            }
        }
        return out;
    }

    namespace internal
    {

        bool ReadCommitInfo(git_repository* _pRepo, const git_oid* _pOid, CommitInfo& _Out)
        {
            CommitPtr c;
            if (git_commit_lookup(&c.m_pP, _pRepo, _pOid) < 0)
            {
                return false;
            }

            CommitInfo& info = _Out;
            info.m_Oid = OidToHex(_pOid);
            info.m_ShortOid = info.m_Oid.substr(0, 7);
            if (const char* szs = git_commit_summary(c.m_pP))
            {
                info.m_Summary = szs;
            }
            if (const char* szm = git_commit_message(c.m_pP))
            {
                info.m_Message = szm;
            }
            if (const git_signature* pa = git_commit_author(c.m_pP))
            {
                if (pa->name)
                {
                    info.m_AuthorName = pa->name;
                }
                if (pa->email)
                {
                    info.m_AuthorEmail = pa->email;
                }
                info.m_TimeUtc = static_cast<std::int64_t>(pa->when.time);
            }
            const unsigned uparents = git_commit_parentcount(c.m_pP);
            for (unsigned ui = 0; ui < uparents; ++ui)
            {
                info.m_Parents.push_back(OidToHex(git_commit_parent_id(c.m_pP, ui)));
            }
            return true;
        }

    } // namespace internal

    namespace
    {

        char DeltaStatusChar(git_delta_t _Status)
        {
            switch (_Status)
            {
            case GIT_DELTA_ADDED:
            case GIT_DELTA_UNTRACKED:
            case GIT_DELTA_COPIED:
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

        int CollectFileCb(const git_diff_delta* _pDelta, float, void* _pPayload)
        {
            auto* pfiles = static_cast<std::vector<FileDiff>*>(_pPayload);
            FileDiff f;
            if (_pDelta->new_file.path)
            {
                f.m_Path = _pDelta->new_file.path;
            }
            f.m_OldPath = _pDelta->old_file.path ? _pDelta->old_file.path : f.m_Path;
            f.m_cStatus = DeltaStatusChar(_pDelta->status);
            f.m_bIsBinary = (_pDelta->flags & GIT_DIFF_FLAG_BINARY) != 0;
            pfiles->push_back(std::move(f));
            return 0;
        }

        int CollectHunkCb(const git_diff_delta*, const git_diff_hunk* _pHunk, void* _pPayload)
        {
            auto* pfiles = static_cast<std::vector<FileDiff>*>(_pPayload);
            if (pfiles->empty())
            {
                return 0;
            }
            DiffHunk h;
            h.m_Header = std::string(_pHunk->header, _pHunk->header_len);
            if (!h.m_Header.empty() && h.m_Header.back() == '\n')
            {
                h.m_Header.pop_back();
            }
            h.m_iOldStart = _pHunk->old_start;
            h.m_iOldLines = _pHunk->old_lines;
            h.m_iNewStart = _pHunk->new_start;
            h.m_iNewLines = _pHunk->new_lines;
            pfiles->back().m_Hunks.push_back(std::move(h));
            return 0;
        }

        int CollectLineCb(const git_diff_delta*, const git_diff_hunk*, const git_diff_line* _pLine,
            void* _pPayload)
        {
            auto* pfiles = static_cast<std::vector<FileDiff>*>(_pPayload);
            if (pfiles->empty() || pfiles->back().m_Hunks.empty())
            {
                return 0;
            }
            DiffLine l;
            l.m_cOrigin = _pLine->origin;
            l.m_iOldLineno = _pLine->old_lineno;
            l.m_iNewLineno = _pLine->new_lineno;
            l.m_Content.assign(_pLine->content, _pLine->content_len);
            if (!l.m_Content.empty() && l.m_Content.back() == '\n')
            {
                l.m_Content.pop_back();
            }
            pfiles->back().m_Hunks.back().m_Lines.push_back(std::move(l));
            return 0;
        }

    } // namespace

    namespace internal
    {

        std::vector<FileDiff> CollectDiff(git_diff* _pDiff)
        {
            std::vector<FileDiff> files;
            if (git_diff_foreach(
                    _pDiff, CollectFileCb, nullptr, CollectHunkCb, CollectLineCb, &files) < 0)
            {
                RaiseLastError("git_diff_foreach failed");
            }
            return files;
        }

    } // namespace internal

    std::vector<FileDiff> Repository::DiffCommit(
        const std::string& _Oid, const DiffOptions& _Options) const
    {
        if (m_pP4)
        {
            return m_pP4->DiffCommit(_Oid, _Options);
        }

        if (!m_pRepo)
        {
            throw GitError("diffCommit() on an unopened repository");
        }

        git_oid id;
        if (git_oid_fromstr(&id, _Oid.c_str()) < 0)
        {
            throw GitError("Invalid commit id '" + _Oid + "'");
        }
        CommitPtr commit;
        if (git_commit_lookup(&commit.m_pP, m_pRepo, &id) < 0)
        {
            RaiseLastError("No such commit '" + _Oid + "'");
        }
        TreePtr tree;
        if (git_commit_tree(&tree.m_pP, commit.m_pP) < 0)
        {
            RaiseLastError("git_commit_tree failed");
        }
        TreePtr parentTree; // stays null for a root commit → all-added diff
        if (git_commit_parentcount(commit.m_pP) > 0)
        {
            CommitPtr parent;
            if (git_commit_parent(&parent.m_pP, commit.m_pP, 0) == 0)
            {
                git_commit_tree(&parentTree.m_pP, parent.m_pP);
            }
        }

        git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
        ApplyDiffOptions(opts, _Options);
        PathSpec paths(_Options.m_Paths);
        if (!_Options.m_Paths.empty())
        {
            opts.pathspec = paths.m_A;
            opts.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH; // exact paths, no globbing
        }
        DiffPtr diff;
        if (git_diff_tree_to_tree(&diff.m_pP, m_pRepo, parentTree.m_pP, tree.m_pP, &opts) < 0)
        {
            RaiseLastError("git_diff_tree_to_tree failed");
        }

        // Pair deletes with adds into renames, like `git show -M`.
        git_diff_find_similar(diff.m_pP, nullptr);
        return CollectDiff(diff.m_pP);
    }

    // ---- Remotes ----------------------------------------------------------------

    std::vector<RemoteInfo> Repository::Remotes() const
    {
        if (m_pP4)
        {
            return m_pP4->Remotes();
        }

        if (!m_pRepo)
        {
            throw GitError("remotes() on an unopened repository");
        }

        StrArray names;
        if (git_remote_list(&names.m_A, m_pRepo) < 0)
        {
            RaiseLastError("git_remote_list failed");
        }
        std::vector<RemoteInfo> out;
        for (std::size_t i = 0; i < names.m_A.count; ++i)
        {
            RemoteInfo r;
            r.m_Name = names.m_A.strings[i];
            RemotePtr remote;
            if (git_remote_lookup(&remote.m_pP, m_pRepo, names.m_A.strings[i]) == 0)
            {
                if (const char* szurl = git_remote_url(remote.m_pP))
                {
                    r.m_Url = szurl;
                }
            }
            out.push_back(std::move(r));
        }
        return out;
    }

    void Repository::AddRemote(const std::string& _Name, const std::string& _Url)
    {
        if (m_pP4)
        {
            m_pP4->AddRemote(_Name, _Url);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("addRemote() on an unopened repository");
        }
        RemotePtr remote;
        if (git_remote_create(&remote.m_pP, m_pRepo, _Name.c_str(), _Url.c_str()) < 0)
        {
            RaiseLastError("Failed to add remote '" + _Name + "'");
        }
    }

    void Repository::RemoveRemote(const std::string& _Name)
    {
        if (m_pP4)
        {
            m_pP4->RemoveRemote(_Name);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("removeRemote() on an unopened repository");
        }
        if (git_remote_delete(m_pRepo, _Name.c_str()) < 0)
        {
            RaiseLastError("Failed to remove remote '" + _Name + "'");
        }
    }

    void Repository::SetRemoteUrl(const std::string& _Name, const std::string& _Url)
    {
        if (m_pP4)
        {
            m_pP4->SetRemoteUrl(_Name, _Url);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("setRemoteUrl() on an unopened repository");
        }
        RemotePtr remote;
        if (git_remote_lookup(&remote.m_pP, m_pRepo, _Name.c_str()) < 0)
        {
            RaiseLastError("No such remote '" + _Name + "'");
        }
        if (git_remote_set_url(m_pRepo, _Name.c_str(), _Url.c_str()) < 0)
        {
            RaiseLastError("Failed to change the URL of '" + _Name + "'");
        }
    }

    void Repository::RenameRemote(const std::string& _Name, const std::string& _NewName)
    {
        if (m_pP4)
        {
            m_pP4->RenameRemote(_Name, _NewName);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("renameRemote() on an unopened repository");
        }
        // `problems` lists custom fetch refspecs libgit2 couldn't rewrite;
        // the rename itself still succeeded, so they're not an error.
        StrArray problems;
        if (git_remote_rename(&problems.m_A, m_pRepo, _Name.c_str(), _NewName.c_str()) < 0)
        {
            RaiseLastError("Failed to rename remote '" + _Name + "'");
        }
    }

    void Repository::SetUpstream(const std::string& _Branch, const std::string& _Upstream)
    {
        if (m_pP4)
        {
            m_pP4->SetUpstream(_Branch, _Upstream);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("setUpstream() on an unopened repository");
        }
        ReferencePtr branch;
        if (git_branch_lookup(&branch.m_pP, m_pRepo, _Branch.c_str(), GIT_BRANCH_LOCAL) < 0)
        {
            RaiseLastError("No such branch '" + _Branch + "'");
        }
        if (git_branch_set_upstream(branch.m_pP, _Upstream.empty() ? nullptr : _Upstream.c_str()) <
            0)
        {
            RaiseLastError("Failed to set the upstream of '" + _Branch + "'");
        }
    }

    // ---- Stash -------------------------------------------------------------------

    std::vector<StashInfo> Repository::StashList() const
    {
        if (m_pP4)
        {
            return m_pP4->StashList();
        }

        if (!m_pRepo)
        {
            throw GitError("stashList() on an unopened repository");
        }

        std::vector<StashInfo> out;
        git_stash_foreach(
            m_pRepo,
            [](std::size_t _Index, const char* _szMessage, const git_oid* _pOid,
                void* _pPayload) -> int
            {
                auto* pv = static_cast<std::vector<StashInfo>*>(_pPayload);
                StashInfo s;
                s.m_Index = _Index;
                if (_szMessage)
                {
                    s.m_Message = _szMessage;
                }
                s.m_Oid = OidToHex(_pOid);
                pv->push_back(std::move(s));
                return 0;
            },
            &out);
        return out;
    }

    void Repository::StashSave(const std::string& _Message)
    {
        if (m_pP4)
        {
            m_pP4->StashSave(_Message);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("stashSave() on an unopened repository");
        }

        SignaturePtr sig = SignatureOrFallback(m_pRepo);
        git_oid m_Oid;
        if (git_stash_save(&m_Oid, m_pRepo, sig.m_pP,
                _Message.empty() ? "gitgud stash" : _Message.c_str(),
                GIT_STASH_INCLUDE_UNTRACKED) < 0)
        {
            RaiseLastError("git_stash_save failed");
        }
    }

    void Repository::StashApply(std::size_t _Index)
    {
        if (m_pP4)
        {
            m_pP4->StashApply(_Index);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("stashApply() on an unopened repository");
        }
        git_stash_apply_options opts = GIT_STASH_APPLY_OPTIONS_INIT;
        if (git_stash_apply(m_pRepo, _Index, &opts) < 0)
        {
            RaiseLastError("git_stash_apply failed");
        }
    }

    void Repository::StashPop(std::size_t _Index)
    {
        if (m_pP4)
        {
            m_pP4->StashPop(_Index);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("stashPop() on an unopened repository");
        }
        git_stash_apply_options opts = GIT_STASH_APPLY_OPTIONS_INIT;
        if (git_stash_pop(m_pRepo, _Index, &opts) < 0)
        {
            RaiseLastError("git_stash_pop failed");
        }
    }

    void Repository::StashDrop(std::size_t _Index)
    {
        if (m_pP4)
        {
            m_pP4->StashDrop(_Index);
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("stashDrop() on an unopened repository");
        }
        if (git_stash_drop(m_pRepo, _Index) < 0)
        {
            RaiseLastError("git_stash_drop failed");
        }
    }

    // ---- Merge --------------------------------------------------------------------

    std::vector<std::string> Repository::ConflictedPaths() const
    {
        if (m_pP4)
        {
            return m_pP4->ConflictedPaths();
        }

        if (!m_pRepo)
        {
            throw GitError("conflictedPaths() on an unopened repository");
        }

        IndexPtr index;
        if (git_repository_index(&index.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_repository_index failed");
        }
        std::vector<std::string> out;
        if (!git_index_has_conflicts(index.m_pP))
        {
            return out;
        }

        git_index_conflict_iterator* pit = nullptr;
        if (git_index_conflict_iterator_new(&pit, index.m_pP) < 0)
        {
            RaiseLastError("git_index_conflict_iterator_new failed");
        }
        const git_index_entry *pancestor, *pours, *ptheirs;
        while (git_index_conflict_next(&pancestor, &pours, &ptheirs, pit) == 0)
        {
            const git_index_entry* pany = pours ? pours : (ptheirs ? ptheirs : pancestor);
            if (pany && pany->path)
            {
                out.emplace_back(pany->path);
            }
        }
        git_index_conflict_iterator_free(pit);
        return out;
    }

    MergeResult Repository::Merge(const std::string& _BranchName)
    {
        if (m_pP4)
        {
            return m_pP4->Merge(_BranchName);
        }

        if (!m_pRepo)
        {
            throw GitError("merge() on an unopened repository");
        }
        return MergeRef("refs/heads/" + _BranchName, _BranchName);
    }

    MergeResult Repository::MergeRef(const std::string& _RefName, const std::string& _Label)
    {
        ReferencePtr ref;
        if (git_reference_lookup(&ref.m_pP, m_pRepo, _RefName.c_str()) < 0)
        {
            RaiseLastError("No such ref '" + _RefName + "'");
        }
        AnnotatedCommitPtr theirs;
        if (git_annotated_commit_from_ref(&theirs.m_pP, m_pRepo, ref.m_pP) < 0)
        {
            RaiseLastError("git_annotated_commit_from_ref failed");
        }

        git_merge_analysis_t analysis;
        git_merge_preference_t preference;
        const git_annotated_commit* paheads[1] = {theirs.m_pP};
        if (git_merge_analysis(&analysis, &preference, m_pRepo, paheads, 1) < 0)
        {
            RaiseLastError("git_merge_analysis failed");
        }

        MergeResult result;

        if (analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE)
        {
            result.m_Kind = MergeResult::Kind::UpToDate;
            result.m_Message = "Already up to date.";
            return result;
        }

        const git_oid* ptargetOid = git_annotated_commit_id(theirs.m_pP);

        if ((analysis & GIT_MERGE_ANALYSIS_UNBORN) ||
            ((analysis & GIT_MERGE_ANALYSIS_FASTFORWARD) &&
                !(preference & GIT_MERGE_PREFERENCE_NO_FASTFORWARD)))
        {
            // Fast-forward (or first commit onto an unborn branch): move the
            // branch ref to the target and check out its tree.
            CommitPtr target;
            if (git_commit_lookup(&target.m_pP, m_pRepo, ptargetOid) < 0)
            {
                RaiseLastError("git_commit_lookup (merge target) failed");
            }
            TreePtr tree;
            if (git_commit_tree(&tree.m_pP, target.m_pP) < 0)
            {
                RaiseLastError("git_commit_tree failed");
            }
            git_checkout_options co = GIT_CHECKOUT_OPTIONS_INIT;
            co.checkout_strategy = GIT_CHECKOUT_SAFE;
            if (const int ierr =
                    git_checkout_tree(m_pRepo, reinterpret_cast<git_object*>(tree.m_pP), &co);
                ierr < 0)
            {
                RaiseUpdateFailure(ierr, "Checkout during fast-forward failed", m_pRepo,
                    [&] { return std::make_pair(HeadTree(m_pRepo), DupTree(tree.m_pP)); });
            }

            if (analysis & GIT_MERGE_ANALYSIS_UNBORN)
            {
                // Point the unborn HEAD's branch at the target commit.
                ReferencePtr symbolic;
                std::string branchRef = "refs/heads/master";
                if (git_reference_lookup(&symbolic.m_pP, m_pRepo, "HEAD") == 0)
                {
                    if (const char* szt = git_reference_symbolic_target(symbolic.m_pP))
                    {
                        branchRef = szt;
                    }
                }
                ReferencePtr created;
                if (git_reference_create(&created.m_pP, m_pRepo, branchRef.c_str(), ptargetOid,
                        /*force=*/1, "fast-forward (unborn)") < 0)
                {
                    RaiseLastError("git_reference_create failed");
                }
            }
            else
            {
                ReferencePtr head;
                if (git_repository_head(&head.m_pP, m_pRepo) < 0)
                {
                    RaiseLastError("git_repository_head failed");
                }
                ReferencePtr moved;
                if (git_reference_set_target(&moved.m_pP, head.m_pP, ptargetOid, "fast-forward") <
                    0)
                {
                    RaiseLastError("git_reference_set_target failed");
                }
            }
            result.m_Kind = MergeResult::Kind::FastForward;
            result.m_Message = "Fast-forwarded to " + _Label + ".";
            return result;
        }

        // True 3-way merge into the working tree + index.
        git_merge_options mo = GIT_MERGE_OPTIONS_INIT;
        git_checkout_options co = GIT_CHECKOUT_OPTIONS_INIT;
        co.checkout_strategy = GIT_CHECKOUT_SAFE | GIT_CHECKOUT_ALLOW_CONFLICTS;
        if (const int ierr = git_merge(m_pRepo, paheads, 1, &mo, &co); ierr < 0)
        {
            RaiseUpdateFailure(ierr, "git_merge failed", m_pRepo,
                [&] { return MergeTrees(m_pRepo, ptargetOid); });
        }

        result.m_ConflictedPaths = ConflictedPaths();
        if (!result.m_ConflictedPaths.empty())
        {
            result.m_Kind = MergeResult::Kind::Conflicts;
            result.m_Message = "Merge of " + _Label + " has conflicts; resolve and commit.";
            return result; // repo stays in the merge state
        }

        // Clean automerge: commit it (doCommit picks up MERGE_HEAD as a parent
        // and clears the merge state — see Repository.cpp).
        SignaturePtr sig = SignatureOrFallback(m_pRepo);
        const std::string m_Oid = [&]
        {
            // commit() would re-resolve the signature from config and throw when
            // unset, so route through the explicit-signature overload.
            return Commit("Merge " + _Label, sig.m_pP->name, sig.m_pP->email);
        }();
        result.m_Kind = MergeResult::Kind::Merged;
        result.m_Message = "Merged " + _Label + " (" + m_Oid.substr(0, 7) + ").";
        return result;
    }

    void Repository::AbortMerge()
    {
        if (m_pP4)
        {
            m_pP4->AbortMerge();
            return;
        }

        if (!m_pRepo)
        {
            throw GitError("abortMerge() on an unopened repository");
        }

        git_oid headOid;
        if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") < 0)
        {
            RaiseLastError("git_reference_name_to_id (HEAD) failed");
        }
        ObjectPtr headObj;
        if (git_object_lookup(&headObj.m_pP, m_pRepo, &headOid, GIT_OBJECT_COMMIT) < 0)
        {
            RaiseLastError("git_object_lookup (HEAD) failed");
        }
        if (git_reset(m_pRepo, headObj.m_pP, GIT_RESET_HARD, nullptr) < 0)
        {
            RaiseLastError("git_reset (hard) failed");
        }
        git_repository_state_cleanup(m_pRepo);
    }

    // ---- Ahead/behind ------------------------------------------------------------

    AheadBehind Repository::GetAheadBehind() const
    {
        if (m_pP4)
        {
            return m_pP4->GetAheadBehind();
        }

        if (!m_pRepo)
        {
            throw GitError("aheadBehind() on an unopened repository");
        }

        AheadBehind out;
        ReferencePtr head;
        if (git_repository_head(&head.m_pP, m_pRepo) != 0)
        {
            return out; // unborn/detached
        }

        ReferencePtr upstream;
        if (git_branch_upstream(&upstream.m_pP, head.m_pP) != 0)
        {
            return out;
        }
        out.m_bHasUpstream = true;
        out.m_UpstreamRemote = UpstreamRemoteOf(m_pRepo, git_reference_name(head.m_pP));
        const char* szupName = nullptr;
        if (git_branch_name(&szupName, upstream.m_pP) == 0 && szupName)
        {
            out.m_Upstream = szupName;
        }

        const git_oid* plocal = git_reference_target(head.m_pP);
        const git_oid* premote = git_reference_target(upstream.m_pP);
        if (!plocal || !premote)
        {
            return out;
        }

        std::size_t ahead = 0, behind = 0;
        if (git_graph_ahead_behind(&ahead, &behind, m_pRepo, plocal, premote) == 0)
        {
            out.m_Ahead = ahead;
            out.m_Behind = behind;
        }
        return out;
    }

} // namespace gitgud::git
