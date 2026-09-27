// -----------------------------------------------------------------------------
// Repository — history-rewriting and multi-step workflows: amend / undo,
// revert, cherry-pick, reset, detached checkout, tags, squash-merge, rebase,
// conflict resolution, repository state, and git config.
// Same layer rules as Repository.h: RAII, plain data out, GitError on failure.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <git2/sys/errors.h>

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>

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

        IndexPtr OpenIndex(git_repository* _pRepo)
        {
            IndexPtr index;
            if (git_repository_index(&index.m_pP, _pRepo) < 0)
            {
                RaiseLastError("git_repository_index failed");
            }
            return index;
        }

        // Revert/cherry-pick commit the whole index, so refuse when the user has
        // their own staged work that would silently ride along.
        void RequireCleanIndex(git_repository* _pRepo, const char* _szOperation)
        {
            IndexPtr index = OpenIndex(_pRepo);
            TreePtr headTree = HeadTree(_pRepo);
            DiffPtr diff;
            if (git_diff_tree_to_index(&diff.m_pP, _pRepo, headTree.m_pP, index.m_pP, nullptr) < 0)
            {
                RaiseLastError("git_diff_tree_to_index failed");
            }
            if (git_diff_num_deltas(diff.m_pP) > 0)
            {
                throw GitError(
                    std::string("Commit or stash your staged changes before ") + _szOperation);
            }
        }

        bool IndexHasConflicts(git_repository* _pRepo)
        {
            IndexPtr index = OpenIndex(_pRepo);
            return git_index_has_conflicts(index.m_pP) != 0;
        }

        SignaturePtr UserSignature(git_repository* _pRepo)
        {
            SignaturePtr sig;
            if (git_signature_default(&sig.m_pP, _pRepo) < 0)
            {
                RaiseLastError("No commit signature; set user.name and user.email");
            }
            return sig;
        }

        // git_rebase_commit hook: sign rebased commits when commit.gpgsign is
        // on (otherwise let libgit2 write them itself).
        int RebaseCommitCb(git_oid* _pOut, const git_signature* _pAuthor,
            const git_signature* _pCommitter, const char*, const char* _szMessage,
            const git_tree* _pTree, size_t _nParents, const git_commit* _pParents[],
            void* _pPayload)
        {
            auto* prepo = static_cast<git_repository*>(_pPayload);
            if (!ReadSigningConfig(prepo).m_bEnabled)
            {
                return GIT_PASSTHROUGH;
            }
            try
            {
                const std::vector<const git_commit*> parents(_pParents, _pParents + _nParents);
                const std::string oid = CreateCommit(prepo, nullptr, _pAuthor, _pCommitter,
                    _szMessage ? _szMessage : "", _pTree, parents);
                return git_oid_fromstr(_pOut, oid.c_str());
            }
            catch (const GitError& e)
            {
                git_error_set_str(GIT_ERROR_INVALID, e.what());
                return -1;
            }
        }

        // Rebase options shared by starting and continuing a rebase.
        git_rebase_options RebaseOptions(git_repository* _pRepo)
        {
            git_rebase_options ro = GIT_REBASE_OPTIONS_INIT;
            ro.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE;
            ro.commit_create_cb = RebaseCommitCb;
            ro.payload = _pRepo;
            return ro;
        }

        // Replay the rest of an open rebase until it finishes or conflicts.
        RebaseResult RunRebase(Repository& _Self, git_repository* _pRepo, git_rebase* _pRebase)
        {
            SignaturePtr sig = SignatureOrFallback(_pRepo);
            git_rebase_operation* pop = nullptr;
            for (;;)
            {
                const int irc = git_rebase_next(&pop, _pRebase);
                if (irc == GIT_ITEROVER)
                {
                    break;
                }
                if (irc < 0)
                {
                    RaiseLastError("Rebase step failed");
                }

                if (IndexHasConflicts(_pRepo))
                {
                    RebaseResult result;
                    result.m_Kind = RebaseResult::Kind::Conflicts;
                    result.m_ConflictedPaths = _Self.ConflictedPaths();
                    result.m_Message = "Rebase stopped on conflicts; resolve them, then continue.";
                    return result;
                }

                git_oid newOid;
                const int icommit =
                    git_rebase_commit(&newOid, _pRebase, nullptr, sig.m_pP, nullptr, nullptr);
                if (icommit < 0 && icommit != GIT_EAPPLIED)
                {
                    RaiseLastError("Committing a rebased change failed");
                }
            }

            if (git_rebase_finish(_pRebase, sig.m_pP) < 0)
            {
                RaiseLastError("git_rebase_finish failed");
            }
            RebaseResult result;
            result.m_Kind = RebaseResult::Kind::Done;
            result.m_Message = "Rebase complete.";
            return result;
        }

        std::string HomeGitconfigPath()
        {
            Buf found;
            if (git_config_find_global(&found.m_B) == 0)
            {
                return found.Str();
            }
            const char* szhome = std::getenv("USERPROFILE");
            if (!szhome)
            {
                szhome = std::getenv("HOME");
            }
            if (!szhome)
            {
                throw GitError("Cannot locate your home directory for ~/.gitconfig");
            }
            return (fs::u8path(szhome) / ".gitconfig").u8string();
        }

        std::string ReadConfigString(git_config* _pCfg, const std::string& _Key)
        {
            ConfigPtr snapshot;
            if (git_config_snapshot(&snapshot.m_pP, _pCfg) < 0)
            {
                return {};
            }
            Buf value;
            if (git_config_get_string_buf(&value.m_B, snapshot.m_pP, _Key.c_str()) != 0)
            {
                return {};
            }
            return value.Str();
        }

    } // namespace

    // ---- Working tree root -----------------------------------------------------

    std::string Repository::WorkDir() const
    {
        if (!m_pRepo)
        {
            return m_Path;
        }
        const char* szwork = git_repository_workdir(m_pRepo);
        std::string out = szwork ? szwork : m_Path;
        for (char& c : out)
        {
            if (c == '\\')
            {
                c = '/';
            }
        }
        while (out.size() > 1 && out.back() == '/')
        {
            out.pop_back();
        }
        return out;
    }

    // ---- Amend / undo ------------------------------------------------------------

    std::string Repository::AmendCommit(const std::string& _Message)
    {
        RequireOpen(m_pRepo, "amendCommit()");

        CommitPtr head = ResolveCommit(m_pRepo, "HEAD");
        IndexPtr index = OpenIndex(m_pRepo);
        if (git_index_has_conflicts(index.m_pP))
        {
            throw GitError("Cannot amend: the index has unresolved conflicts");
        }

        git_oid treeOid;
        if (git_index_write_tree(&treeOid, index.m_pP) < 0)
        {
            RaiseLastError("git_index_write_tree failed");
        }
        TreePtr tree;
        if (git_tree_lookup(&tree.m_pP, m_pRepo, &treeOid) < 0)
        {
            RaiseLastError("git_tree_lookup failed");
        }

        // Keep the original author and parents; the amender becomes the
        // committer. CreateCommit signs it when the config asks for that.
        SignaturePtr committer = UserSignature(m_pRepo);
        const unsigned uparents = git_commit_parentcount(head.m_pP);
        std::vector<CommitPtr> parents(uparents);
        std::vector<const git_commit*> parentPtrs;
        for (unsigned ui = 0; ui < uparents; ++ui)
        {
            if (git_commit_parent(&parents[ui].m_pP, head.m_pP, ui) < 0)
            {
                RaiseLastError("git_commit_parent failed");
            }
            parentPtrs.push_back(parents[ui].m_pP);
        }
        return CreateCommit(m_pRepo, "HEAD", git_commit_author(head.m_pP), committer.m_pP, _Message,
            tree.m_pP, parentPtrs);
    }

    std::string Repository::UndoLastCommit()
    {
        RequireOpen(m_pRepo, "undoLastCommit()");

        CommitPtr head = ResolveCommit(m_pRepo, "HEAD");
        const char* szmessage = git_commit_message(head.m_pP);
        const std::string message = szmessage ? szmessage : "";

        if (git_commit_parentcount(head.m_pP) > 0)
        {
            CommitPtr parent;
            if (git_commit_parent(&parent.m_pP, head.m_pP, 0) < 0)
            {
                RaiseLastError("git_commit_parent failed");
            }
            if (git_reset(m_pRepo, reinterpret_cast<git_object*>(parent.m_pP), GIT_RESET_SOFT,
                    nullptr) < 0)
            {
                RaiseLastError("git_reset (soft) failed");
            }
            return message;
        }

        // Root commit: delete the branch ref so HEAD is unborn again; the index
        // (and so every change) stays exactly as committed.
        if (git_repository_head_detached(m_pRepo) == 1)
        {
            throw GitError("Cannot undo the root commit on a detached HEAD");
        }
        ReferencePtr branch;
        if (git_repository_head(&branch.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_repository_head failed");
        }
        if (git_reference_delete(branch.m_pP) < 0)
        {
            RaiseLastError("Removing the branch ref failed");
        }
        return message;
    }

    // ---- Branch/commit navigation ------------------------------------------------

    void Repository::CreateBranch(const std::string& _Name, const std::string& _StartPoint)
    {
        RequireOpen(m_pRepo, "createBranch()");

        CommitPtr start = ResolveCommit(m_pRepo, _StartPoint);
        ReferencePtr branch;
        if (git_branch_create(&branch.m_pP, m_pRepo, _Name.c_str(), start.m_pP, /*force=*/0) < 0)
        {
            RaiseLastError("Failed to create branch '" + _Name + "'");
        }
    }

    void Repository::CheckoutCommit(const std::string& _Oid)
    {
        RequireOpen(m_pRepo, "checkoutCommit()");

        CommitPtr commit = ResolveCommit(m_pRepo, _Oid);
        git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
        opts.checkout_strategy = GIT_CHECKOUT_SAFE;
        if (git_checkout_tree(m_pRepo, reinterpret_cast<git_object*>(commit.m_pP), &opts) < 0)
        {
            RaiseLastError("Checkout of " + _Oid.substr(0, 7) + " failed");
        }
        if (git_repository_set_head_detached(m_pRepo, git_commit_id(commit.m_pP)) < 0)
        {
            RaiseLastError("git_repository_set_head_detached failed");
        }
    }

    std::vector<RefLabel> Repository::RefLabels() const
    {
        RequireOpen(m_pRepo, "refLabels()");

        std::vector<RefLabel> out;
        git_reference_iterator* pit = nullptr;
        if (git_reference_iterator_new(&pit, m_pRepo) < 0)
        {
            RaiseLastError("git_reference_iterator_new failed");
        }

        git_reference* pref = nullptr;
        while (git_reference_next(&pref, pit) == 0)
        {
            ReferencePtr holder;
            holder.m_pP = pref;

            const std::string name = git_reference_name(pref);
            RefLabel label;
            if (name.rfind("refs/heads/", 0) == 0)
            {
                label.m_cKind = 'b';
            }
            else if (name.rfind("refs/remotes/", 0) == 0)
            {
                if (name.size() >= 5 && name.compare(name.size() - 5, 5, "/HEAD") == 0)
                {
                    continue;
                }
                label.m_cKind = 'r';
            }
            else if (name.rfind("refs/tags/", 0) == 0)
            {
                label.m_cKind = 't';
            }
            else
            {
                continue; // stash, notes, ...
            }

            ObjectPtr target;
            if (git_reference_peel(&target.m_pP, pref, GIT_OBJECT_COMMIT) != 0)
            {
                continue;
            }
            label.m_Oid = OidToHex(git_object_id(target.m_pP));
            label.m_Name = git_reference_shorthand(pref);
            out.push_back(std::move(label));
        }
        git_reference_iterator_free(pit);

        if (git_repository_head_detached(m_pRepo) == 1)
        {
            git_oid headOid;
            if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") == 0)
            {
                out.push_back({OidToHex(&headOid), "HEAD", 'h'});
            }
        }
        return out;
    }

    AheadBehind Repository::CompareWith(const std::string& _Ref) const
    {
        RequireOpen(m_pRepo, "compareWith()");

        AheadBehind out;
        git_oid headOid;
        if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") != 0)
        {
            return out;
        }
        CommitPtr other = ResolveCommit(m_pRepo, _Ref);
        out.m_bHasUpstream = true;
        git_graph_ahead_behind(
            &out.m_Ahead, &out.m_Behind, m_pRepo, &headOid, git_commit_id(other.m_pP));
        return out;
    }

    // ---- Revert / cherry-pick / reset --------------------------------------------

    std::string Repository::Revert(const std::string& _Oid)
    {
        RequireOpen(m_pRepo, "revert()");
        RequireCleanIndex(m_pRepo, "reverting");

        CommitPtr commit = ResolveCommit(m_pRepo, _Oid);
        git_revert_options opts = GIT_REVERT_OPTIONS_INIT;
        if (git_commit_parentcount(commit.m_pP) > 1)
        {
            opts.mainline = 1; // revert a merge relative to its first parent
        }
        if (git_revert(m_pRepo, commit.m_pP, &opts) < 0)
        {
            RaiseLastError("Revert failed");
        }
        if (IndexHasConflicts(m_pRepo))
        {
            return {}; // stays in the revert state for the user to resolve
        }

        const char* szsummary = git_commit_summary(commit.m_pP);
        const std::string message = std::string("Revert \"") + (szsummary ? szsummary : "") +
                                    "\"\n\nThis reverts commit " +
                                    OidToHex(git_commit_id(commit.m_pP)) + ".\n";
        SignaturePtr sig = SignatureOrFallback(m_pRepo);
        return DoCommit(m_pRepo, message, sig.m_pP, sig.m_pP);
    }

    std::string Repository::CherryPick(const std::string& _Oid)
    {
        RequireOpen(m_pRepo, "cherryPick()");
        RequireCleanIndex(m_pRepo, "cherry-picking");

        CommitPtr commit = ResolveCommit(m_pRepo, _Oid);
        git_cherrypick_options opts = GIT_CHERRYPICK_OPTIONS_INIT;
        if (git_commit_parentcount(commit.m_pP) > 1)
        {
            opts.mainline = 1;
        }
        if (git_cherrypick(m_pRepo, commit.m_pP, &opts) < 0)
        {
            RaiseLastError("Cherry-pick failed");
        }
        if (IndexHasConflicts(m_pRepo))
        {
            return {};
        }

        const char* szmessage = git_commit_message(commit.m_pP);
        SignaturePtr committer = SignatureOrFallback(m_pRepo);
        return DoCommit(
            m_pRepo, szmessage ? szmessage : "", git_commit_author(commit.m_pP), committer.m_pP);
    }

    void Repository::ResetTo(const std::string& _Oid, ResetMode _Mode)
    {
        RequireOpen(m_pRepo, "resetTo()");

        CommitPtr commit = ResolveCommit(m_pRepo, _Oid);
        git_reset_t kind = GIT_RESET_MIXED;
        if (_Mode == ResetMode::Soft)
        {
            kind = GIT_RESET_SOFT;
        }
        else if (_Mode == ResetMode::Hard)
        {
            kind = GIT_RESET_HARD;
        }
        if (git_reset(m_pRepo, reinterpret_cast<git_object*>(commit.m_pP), kind, nullptr) < 0)
        {
            RaiseLastError("Reset failed");
        }
    }

    // ---- Tags --------------------------------------------------------------------

    std::vector<TagInfo> Repository::Tags() const
    {
        RequireOpen(m_pRepo, "tags()");

        // One pass over refs/tags/*: listing the names and then looking each
        // ref up again reads every loose ref file twice.
        ReferenceIteratorPtr it;
        if (git_reference_iterator_glob_new(&it.m_pP, m_pRepo, "refs/tags/*") < 0)
        {
            RaiseLastError("git_reference_iterator_glob_new failed");
        }

        constexpr std::size_t kPrefixLength = sizeof("refs/tags/") - 1;
        std::vector<TagInfo> out;
        git_reference* pref = nullptr;
        while (git_reference_next(&pref, it.m_pP) == 0)
        {
            ReferencePtr ref;
            ref.m_pP = pref;
            const git_oid* pdirect = git_reference_target(pref);
            if (!pdirect)
            {
                continue; // symbolic
            }

            TagInfo info;
            info.m_Name = git_reference_name(pref) + kPrefixLength;
            ObjectPtr object;
            if (git_object_lookup(&object.m_pP, m_pRepo, pdirect, GIT_OBJECT_ANY) == 0)
            {
                // Annotated tags point at a tag object; lightweight ones at the commit.
                if (git_object_type(object.m_pP) == GIT_OBJECT_TAG)
                {
                    const char* szmsg =
                        git_tag_message(reinterpret_cast<const git_tag*>(object.m_pP));
                    info.m_Message = szmsg ? szmsg : "";
                }
                ObjectPtr target;
                if (git_object_peel(&target.m_pP, object.m_pP, GIT_OBJECT_COMMIT) == 0)
                {
                    info.m_TargetOid = OidToHex(git_object_id(target.m_pP));
                }
            }
            git_error_clear();
            out.push_back(std::move(info));
        }
        // git_tag_list's order.
        std::sort(out.begin(), out.end(),
            [](const TagInfo& _A, const TagInfo& _B) { return _A.m_Name < _B.m_Name; });
        return out;
    }

    void Repository::CreateTag(
        const std::string& _Name, const std::string& _Target, const std::string& _Message)
    {
        RequireOpen(m_pRepo, "createTag()");

        CommitPtr target = ResolveCommit(m_pRepo, _Target.empty() ? "HEAD" : _Target);
        git_oid tagOid;
        int irc = 0;
        if (_Message.empty())
        {
            irc = git_tag_create_lightweight(&tagOid, m_pRepo, _Name.c_str(),
                reinterpret_cast<git_object*>(target.m_pP), /*force=*/0);
        }
        else
        {
            SignaturePtr sig = SignatureOrFallback(m_pRepo);
            irc = git_tag_create(&tagOid, m_pRepo, _Name.c_str(),
                reinterpret_cast<git_object*>(target.m_pP), sig.m_pP, _Message.c_str(),
                /*force=*/0);
        }
        if (irc < 0)
        {
            RaiseLastError("Failed to create tag '" + _Name + "'");
        }
    }

    void Repository::DeleteTag(const std::string& _Name)
    {
        RequireOpen(m_pRepo, "deleteTag()");
        if (git_tag_delete(m_pRepo, _Name.c_str()) < 0)
        {
            RaiseLastError("Failed to delete tag '" + _Name + "'");
        }
    }

    // ---- State / conflicts / abort -----------------------------------------------

    RepoState Repository::State() const
    {
        RequireOpen(m_pRepo, "state()");
        switch (git_repository_state(m_pRepo))
        {
        case GIT_REPOSITORY_STATE_NONE:
            return RepoState::None;
        case GIT_REPOSITORY_STATE_MERGE:
            return RepoState::Merge;
        case GIT_REPOSITORY_STATE_REBASE:
        case GIT_REPOSITORY_STATE_REBASE_INTERACTIVE:
        case GIT_REPOSITORY_STATE_REBASE_MERGE:
        case GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE:
            return RepoState::Rebase;
        case GIT_REPOSITORY_STATE_CHERRYPICK:
        case GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE:
            return RepoState::CherryPick;
        case GIT_REPOSITORY_STATE_REVERT:
        case GIT_REPOSITORY_STATE_REVERT_SEQUENCE:
            return RepoState::Revert;
        default:
            return RepoState::Other;
        }
    }

    void Repository::ResolveConflict(const std::string& _Path, bool _bOurs)
    {
        RequireOpen(m_pRepo, "resolveConflict()");

        IndexPtr index = OpenIndex(m_pRepo);
        const git_index_entry* pancestor = nullptr;
        const git_index_entry* pours = nullptr;
        const git_index_entry* ptheirs = nullptr;
        if (git_index_conflict_get(&pancestor, &pours, &ptheirs, index.m_pP, _Path.c_str()) != 0)
        {
            throw GitError("'" + _Path + "' is not conflicted");
        }

        const char* szwork = git_repository_workdir(m_pRepo);
        if (!szwork)
        {
            throw GitError("resolveConflict() needs a working tree");
        }
        const fs::path abs = fs::u8path(szwork) / fs::u8path(_Path);
        const git_index_entry* ppick = _bOurs ? pours : ptheirs;

        if (!ppick)
        {
            // That side deleted the file: resolving to it means deleting.
            std::error_code ec;
            fs::remove(abs, ec);
            git_index_conflict_remove(index.m_pP, _Path.c_str());
            git_index_remove_bypath(index.m_pP, _Path.c_str());
        }
        else
        {
            // Write the chosen side (checkout filters applied) and stage it;
            // add_bypath clears the conflict entries.
            const git_oid pickedId = ppick->id;
            BlobPtr blob;
            if (git_blob_lookup(&blob.m_pP, m_pRepo, &pickedId) < 0)
            {
                RaiseLastError("git_blob_lookup failed");
            }
            Buf filtered;
            git_blob_filter_options fopts = GIT_BLOB_FILTER_OPTIONS_INIT;
            if (git_blob_filter(&filtered.m_B, blob.m_pP, _Path.c_str(), &fopts) < 0)
            {
                RaiseLastError("Filtering '" + _Path + "' failed");
            }

            std::error_code ec;
            fs::create_directories(abs.parent_path(), ec);
            std::ofstream out(abs, std::ios::binary | std::ios::trunc);
            if (!out)
            {
                throw GitError("Could not write '" + _Path + "'");
            }
            const std::string bytes = filtered.Str();
            out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
            out.close();

            if (git_index_add_bypath(index.m_pP, _Path.c_str()) < 0)
            {
                RaiseLastError("Staging the resolution of '" + _Path + "' failed");
            }
        }

        if (git_index_write(index.m_pP) < 0)
        {
            RaiseLastError("git_index_write failed");
        }
    }

    void Repository::AbortOperation()
    {
        RequireOpen(m_pRepo, "abortOperation()");

        if (State() == RepoState::Rebase)
        {
            RebasePtr rebase;
            git_rebase_options ro = GIT_REBASE_OPTIONS_INIT;
            if (git_rebase_open(&rebase.m_pP, m_pRepo, &ro) < 0)
            {
                RaiseLastError("git_rebase_open failed");
            }
            if (git_rebase_abort(rebase.m_pP) < 0)
            {
                RaiseLastError("git_rebase_abort failed");
            }
            return;
        }
        AbortMerge();
    }

    // ---- Squash merge / rebase ---------------------------------------------------

    MergeResult Repository::SquashMerge(const std::string& _BranchName)
    {
        RequireOpen(m_pRepo, "squashMerge()");

        CommitPtr theirs = ResolveCommit(m_pRepo, _BranchName);
        MergeResult result;

        git_oid headOid;
        if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") != 0)
        {
            throw GitError("Cannot squash-merge onto an unborn branch");
        }
        if (git_oid_equal(&headOid, git_commit_id(theirs.m_pP)) ||
            git_graph_descendant_of(m_pRepo, &headOid, git_commit_id(theirs.m_pP)) == 1)
        {
            result.m_Kind = MergeResult::Kind::UpToDate;
            result.m_Message = "Already up to date.";
            return result;
        }

        // The squashed message lists every commit being folded in.
        LogQuery query;
        query.m_MaxCount = 100;
        query.m_From = _BranchName;
        query.m_Hide = "HEAD";
        std::string message = "Squashed commit of '" + _BranchName + "'\n\n";
        for (const CommitInfo& c : Log(query))
        {
            message += "* " + c.m_Summary + "\n";
        }

        AnnotatedCommitPtr annotated;
        if (git_annotated_commit_lookup(&annotated.m_pP, m_pRepo, git_commit_id(theirs.m_pP)) < 0)
        {
            RaiseLastError("git_annotated_commit_lookup failed");
        }
        const git_annotated_commit* pheads[1] = {annotated.m_pP};
        git_merge_options mo = GIT_MERGE_OPTIONS_INIT;
        git_checkout_options co = GIT_CHECKOUT_OPTIONS_INIT;
        co.checkout_strategy = GIT_CHECKOUT_SAFE | GIT_CHECKOUT_ALLOW_CONFLICTS;
        if (git_merge(m_pRepo, pheads, 1, &mo, &co) < 0)
        {
            RaiseLastError("git_merge failed");
        }

        // Forget MERGE_HEAD: the result must be a single-parent commit.
        git_repository_state_cleanup(m_pRepo);

        result.m_ConflictedPaths = ConflictedPaths();
        if (!result.m_ConflictedPaths.empty())
        {
            result.m_Kind = MergeResult::Kind::Conflicts;
            result.m_Message =
                "Squashing " + _BranchName + " hit conflicts; resolve them, then commit.";
            return result;
        }

        SignaturePtr sig = SignatureOrFallback(m_pRepo);
        const std::string oid = DoCommit(m_pRepo, message, sig.m_pP, sig.m_pP);
        result.m_Kind = MergeResult::Kind::Merged;
        result.m_Message =
            "Squashed " + _BranchName + " into one commit (" + oid.substr(0, 7) + ").";
        return result;
    }

    RebaseResult Repository::Rebase(const std::string& _Upstream)
    {
        RequireOpen(m_pRepo, "rebase()");

        ReferencePtr head;
        if (git_repository_head(&head.m_pP, m_pRepo) < 0 ||
            git_repository_head_detached(m_pRepo) == 1)
        {
            throw GitError("Rebase needs a checked-out branch");
        }
        CommitPtr upstream = ResolveCommit(m_pRepo, _Upstream);
        const git_oid* pheadOid = git_reference_target(head.m_pP);

        if (git_oid_equal(pheadOid, git_commit_id(upstream.m_pP)) ||
            git_graph_descendant_of(m_pRepo, pheadOid, git_commit_id(upstream.m_pP)) == 1)
        {
            RebaseResult result;
            result.m_Message = "Already up to date with " + _Upstream + ".";
            return result;
        }

        AnnotatedCommitPtr branch;
        if (git_annotated_commit_from_ref(&branch.m_pP, m_pRepo, head.m_pP) < 0)
        {
            RaiseLastError("git_annotated_commit_from_ref failed");
        }
        AnnotatedCommitPtr onto;
        if (git_annotated_commit_lookup(&onto.m_pP, m_pRepo, git_commit_id(upstream.m_pP)) < 0)
        {
            RaiseLastError("git_annotated_commit_lookup failed");
        }

        git_rebase_options ro = RebaseOptions(m_pRepo);
        RebasePtr rebase;
        if (git_rebase_init(&rebase.m_pP, m_pRepo, branch.m_pP, onto.m_pP, nullptr, &ro) < 0)
        {
            RaiseLastError("Could not start the rebase");
        }
        return RunRebase(*this, m_pRepo, rebase.m_pP);
    }

    RebaseResult Repository::ContinueRebase()
    {
        RequireOpen(m_pRepo, "continueRebase()");

        git_rebase_options ro = RebaseOptions(m_pRepo);
        RebasePtr rebase;
        if (git_rebase_open(&rebase.m_pP, m_pRepo, &ro) < 0)
        {
            RaiseLastError("No rebase in progress");
        }

        if (IndexHasConflicts(m_pRepo))
        {
            RebaseResult result;
            result.m_Kind = RebaseResult::Kind::Conflicts;
            result.m_ConflictedPaths = ConflictedPaths();
            result.m_Message = "Resolve every conflicted file before continuing.";
            return result;
        }

        // Commit the operation the user just resolved, then replay the rest.
        SignaturePtr sig = SignatureOrFallback(m_pRepo);
        git_oid newOid;
        const int irc =
            git_rebase_commit(&newOid, rebase.m_pP, nullptr, sig.m_pP, nullptr, nullptr);
        if (irc < 0 && irc != GIT_EAPPLIED)
        {
            RaiseLastError("Committing the resolved change failed");
        }
        return RunRebase(*this, m_pRepo, rebase.m_pP);
    }

    // ---- Stash contents ----------------------------------------------------------

    std::vector<FileDiff> Repository::StashDiff(std::size_t _Index) const
    {
        RequireOpen(m_pRepo, "stashDiff()");

        const std::vector<StashInfo> stashes = StashList();
        if (_Index >= stashes.size())
        {
            throw GitError("No such stash");
        }
        CommitPtr stash = ResolveCommit(m_pRepo, stashes[_Index].m_Oid);

        // Tracked edits: the stash commit against its first parent (the HEAD it
        // was taken on).
        std::vector<FileDiff> out = DiffCommit(stashes[_Index].m_Oid);

        // Untracked files live in the third parent's tree, as additions.
        if (git_commit_parentcount(stash.m_pP) >= 3)
        {
            CommitPtr untracked;
            TreePtr tree;
            if (git_commit_parent(&untracked.m_pP, stash.m_pP, 2) == 0 &&
                git_commit_tree(&tree.m_pP, untracked.m_pP) == 0)
            {
                git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
                DiffPtr diff;
                if (git_diff_tree_to_tree(&diff.m_pP, m_pRepo, nullptr, tree.m_pP, &opts) == 0)
                {
                    for (FileDiff& f : CollectDiff(diff.m_pP))
                    {
                        out.push_back(std::move(f));
                    }
                }
            }
        }
        return out;
    }

    // ---- Config ------------------------------------------------------------------

    std::string Repository::GetConfig(const std::string& _Key) const
    {
        RequireOpen(m_pRepo, "getConfig()");
        ConfigPtr cfg;
        if (git_repository_config(&cfg.m_pP, m_pRepo) < 0)
        {
            return {};
        }
        return ReadConfigString(cfg.m_pP, _Key);
    }

    void Repository::SetConfig(const std::string& _Key, const std::string& _Value)
    {
        RequireOpen(m_pRepo, "setConfig()");
        ConfigPtr cfg;
        if (git_repository_config(&cfg.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_repository_config failed");
        }
        ConfigPtr local;
        if (git_config_open_level(&local.m_pP, cfg.m_pP, GIT_CONFIG_LEVEL_LOCAL) < 0)
        {
            RaiseLastError("Opening the repository config failed");
        }
        const int irc = _Value.empty()
                            ? git_config_delete_entry(local.m_pP, _Key.c_str())
                            : git_config_set_string(local.m_pP, _Key.c_str(), _Value.c_str());
        if (irc < 0 && irc != GIT_ENOTFOUND)
        {
            RaiseLastError("Setting '" + _Key + "' failed");
        }
    }

    std::string Repository::GetGlobalConfig(const std::string& _Key)
    {
        ConfigPtr cfg;
        if (git_config_open_default(&cfg.m_pP) < 0)
        {
            return {};
        }
        return ReadConfigString(cfg.m_pP, _Key);
    }

    void Repository::SetGlobalConfig(const std::string& _Key, const std::string& _Value)
    {
        ConfigPtr cfg;
        if (git_config_open_ondisk(&cfg.m_pP, HomeGitconfigPath().c_str()) < 0)
        {
            RaiseLastError("Opening ~/.gitconfig failed");
        }
        const int irc = _Value.empty()
                            ? git_config_delete_entry(cfg.m_pP, _Key.c_str())
                            : git_config_set_string(cfg.m_pP, _Key.c_str(), _Value.c_str());
        if (irc < 0 && irc != GIT_ENOTFOUND)
        {
            RaiseLastError("Setting '" + _Key + "' failed");
        }
    }

} // namespace gitgud::git
