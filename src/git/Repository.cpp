#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <filesystem>

namespace gitgud::git
{

    using namespace internal;

    // ---- LibGit2 global init/shutdown ---------------------------------------
    LibGit2::LibGit2()
    {
        if (git_libgit2_init() < 0)
        {
            RaiseLastError("git_libgit2_init failed");
        }
        RegisterLfsFilter();
    }

    LibGit2::~LibGit2()
    {
        git_libgit2_shutdown();
    }

    // ---- Repository lifecycle ------------------------------------------------
    Repository::~Repository()
    {
        Close();
    }

    Repository::Repository(Repository&& _Other) noexcept
        : m_pRepo(_Other.m_pRepo), m_Path(std::move(_Other.m_Path)),
          m_CredProvider(std::move(_Other.m_CredProvider)),
          m_HostKeyProvider(std::move(_Other.m_HostKeyProvider))
    {
        _Other.m_pRepo = nullptr;
    }

    Repository& Repository::operator=(Repository&& _Other) noexcept
    {
        if (this != &_Other)
        {
            Close();
            m_pRepo = _Other.m_pRepo;
            m_Path = std::move(_Other.m_Path);
            m_CredProvider = std::move(_Other.m_CredProvider);
            m_HostKeyProvider = std::move(_Other.m_HostKeyProvider);
            _Other.m_pRepo = nullptr;
        }
        return *this;
    }

    void Repository::Close()
    {
        if (m_pRepo)
        {
            git_repository_free(m_pRepo);
            m_pRepo = nullptr;
        }
    }

    Repository Repository::Open(const std::string& _Path)
    {
        Repository r;
        if (git_repository_open(&r.m_pRepo, _Path.c_str()) < 0)
        {
            RaiseLastError("Failed to open repository at '" + _Path + "'");
        }
        r.m_Path = _Path;
        return r;
    }

    Repository Repository::Init(const std::string& _Path)
    {
        Repository r;
        if (git_repository_init(&r.m_pRepo, _Path.c_str(), /*is_bare=*/0) < 0)
        {
            RaiseLastError("Failed to init repository at '" + _Path + "'");
        }
        r.m_Path = _Path;
        return r;
    }

    Repository Repository::InitBare(const std::string& _Path)
    {
        Repository r;
        if (git_repository_init(&r.m_pRepo, _Path.c_str(), /*is_bare=*/1) < 0)
        {
            RaiseLastError("Failed to init bare repository at '" + _Path + "'");
        }
        r.m_Path = _Path;
        return r;
    }

    // ---- Status --------------------------------------------------------------
    std::vector<StatusEntry> Repository::Status() const
    {
        if (!m_pRepo)
        {
            throw GitError("status() called on an unopened repository");
        }

        git_status_options opts = GIT_STATUS_OPTIONS_INIT;
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
        // RECURSE_UNTRACKED_DIRS: without it an untracked directory appears as a
        // single "dir/" entry, which can't be staged ("invalid path") and hides
        // its contents. Recursing lists each file, like GitHub Desktop.
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS |
                     GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX;

        git_status_list* plist = nullptr;
        if (git_status_list_new(&plist, m_pRepo, &opts) < 0)
        {
            RaiseLastError("git_status_list_new failed");
        }

        std::vector<StatusEntry> out;
        const size_t ncount = git_status_list_entrycount(plist);
        out.reserve(ncount);

        for (size_t ni = 0; ni < ncount; ++ni)
        {
            const git_status_entry* ps = git_status_byindex(plist, ni);
            if (!ps)
            {
                continue;
            }

            StatusEntry e;
            const git_status_t st = ps->status;

            e.m_bStaged =
                (st & (GIT_STATUS_INDEX_NEW | GIT_STATUS_INDEX_MODIFIED | GIT_STATUS_INDEX_DELETED |
                          GIT_STATUS_INDEX_RENAMED | GIT_STATUS_INDEX_TYPECHANGE)) != 0;
            e.m_bUnstaged =
                (st & (GIT_STATUS_WT_NEW | GIT_STATUS_WT_MODIFIED | GIT_STATUS_WT_DELETED |
                          GIT_STATUS_WT_TYPECHANGE | GIT_STATUS_WT_RENAMED)) != 0;

            if (st & (GIT_STATUS_INDEX_NEW | GIT_STATUS_WT_NEW))
            {
                e.m_cCode = 'A';
            }
            else if (st & (GIT_STATUS_INDEX_DELETED | GIT_STATUS_WT_DELETED))
            {
                e.m_cCode = 'D';
            }
            else if (st & (GIT_STATUS_INDEX_MODIFIED | GIT_STATUS_WT_MODIFIED))
            {
                e.m_cCode = 'M';
            }
            if ((st & GIT_STATUS_WT_NEW) && !e.m_bStaged)
            {
                e.m_cCode = '?'; // untracked
            }
            if (st & GIT_STATUS_CONFLICTED)
            {
                e.m_cCode = 'U'; // unmerged: resolve before committing
                e.m_bUnstaged = true;
            }

            const git_diff_delta* pd = ps->head_to_index ? ps->head_to_index : ps->index_to_workdir;
            if (pd && pd->new_file.path)
            {
                e.m_Path = pd->new_file.path;
            }

            out.push_back(std::move(e));
        }

        git_status_list_free(plist);
        return out;
    }

    // ---- Stage / unstage -----------------------------------------------------
    void Repository::Stage(const std::string& _Path)
    {
        if (!m_pRepo)
        {
            throw GitError("stage() on an unopened repository");
        }

        IndexPtr index;
        if (git_repository_index(&index.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_repository_index failed");
        }

        // If the working-tree file is gone, this is a deletion to be staged;
        // otherwise add/update the entry from the working tree.
        const std::filesystem::path abs =
            std::filesystem::path(git_repository_workdir(m_pRepo)) / _Path;
        const bool bexistsOnDisk = std::filesystem::exists(abs);

        int irc = bexistsOnDisk ? git_index_add_bypath(index.m_pP, _Path.c_str())
                                : git_index_remove_bypath(index.m_pP, _Path.c_str());
        if (irc < 0)
        {
            RaiseLastError("Failed to stage '" + _Path + "'");
        }

        if (git_index_write(index.m_pP) < 0)
        {
            RaiseLastError("git_index_write failed");
        }
    }

    void Repository::Unstage(const std::string& _Path)
    {
        if (!m_pRepo)
        {
            throw GitError("unstage() on an unopened repository");
        }

        // Resolve HEAD's commit. If the branch is unborn (no commits yet), there is
        // nothing to reset to, so unstaging means removing the path from the index.
        git_reference* phead = nullptr;
        int irc = git_repository_head(&phead, m_pRepo);
        if (irc == GIT_EUNBORNBRANCH || irc == GIT_ENOTFOUND)
        {
            if (phead)
            {
                git_reference_free(phead);
            }
            IndexPtr index;
            if (git_repository_index(&index.m_pP, m_pRepo) < 0)
            {
                RaiseLastError("git_repository_index failed");
            }
            if (git_index_remove_bypath(index.m_pP, _Path.c_str()) < 0)
            {
                RaiseLastError("Failed to unstage '" + _Path + "' (unborn HEAD)");
            }
            if (git_index_write(index.m_pP) < 0)
            {
                RaiseLastError("git_index_write failed");
            }
            return;
        }
        if (irc < 0)
        {
            RaiseLastError("git_repository_head failed");
        }

        ObjectPtr headCommit;
        irc = git_reference_peel(&headCommit.m_pP, phead, GIT_OBJECT_COMMIT);
        git_reference_free(phead);
        if (irc < 0)
        {
            RaiseLastError("Failed to peel HEAD to a commit");
        }

        // git_reset_default with a pathspec == `git reset HEAD -- <path>`.
        char* pszpaths[] = {const_cast<char*>(_Path.c_str())};
        git_strarray pathspec = {pszpaths, 1};
        if (git_reset_default(m_pRepo, headCommit.m_pP, &pathspec) < 0)
        {
            RaiseLastError("Failed to unstage '" + _Path + "'");
        }
    }

    // ---- Commit --------------------------------------------------------------
    namespace internal
    {

        // Shared commit path once a signature is resolved. In a merge state (after a
        // conflicted 3-way merge was resolved), MERGE_HEAD contributes extra parents
        // and the merge state is cleaned up after the commit lands.
        std::string DoCommit(git_repository* _pRepo, const std::string& _Message,
            const git_signature* _pAuthor, const git_signature* _pCommitter)
        {
            IndexPtr index;
            if (git_repository_index(&index.m_pP, _pRepo) < 0)
            {
                RaiseLastError("git_repository_index failed");
            }
            if (git_index_has_conflicts(index.m_pP))
            {
                throw GitError("Cannot commit: the index has unresolved conflicts");
            }

            git_oid treeOid;
            if (git_index_write_tree(&treeOid, index.m_pP) < 0)
            {
                RaiseLastError("git_index_write_tree failed");
            }

            TreePtr tree;
            if (git_tree_lookup(&tree.m_pP, _pRepo, &treeOid) < 0)
            {
                RaiseLastError("git_tree_lookup failed");
            }

            // Collect the parent commits: HEAD (if born), plus any MERGE_HEADs.
            std::vector<git_oid> parentOids;
            git_reference* phead = nullptr;
            int irc = git_repository_head(&phead, _pRepo);
            if (irc == 0)
            {
                git_oid parentOid;
                if (git_reference_name_to_id(&parentOid, _pRepo, "HEAD") == 0)
                {
                    parentOids.push_back(parentOid);
                }
                git_reference_free(phead);
            }
            else if (irc != GIT_EUNBORNBRANCH && irc != GIT_ENOTFOUND)
            {
                if (phead)
                {
                    git_reference_free(phead);
                }
                RaiseLastError("git_repository_head failed");
            }
            if (git_repository_state(_pRepo) == GIT_REPOSITORY_STATE_MERGE)
            {
                git_repository_mergehead_foreach(
                    _pRepo,
                    [](const git_oid* _pOid, void* _pPayload) -> int
                    {
                        static_cast<std::vector<git_oid>*>(_pPayload)->push_back(*_pOid);
                        return 0;
                    },
                    &parentOids);
            }

            std::vector<CommitPtr> parents(parentOids.size());
            std::vector<const git_commit*> parentPtrs;
            for (std::size_t i = 0; i < parentOids.size(); ++i)
            {
                if (git_commit_lookup(&parents[i].m_pP, _pRepo, &parentOids[i]) < 0)
                {
                    RaiseLastError("git_commit_lookup (parent) failed");
                }
                parentPtrs.push_back(parents[i].m_pP);
            }

            const std::string oid = CreateCommit(
                _pRepo, "HEAD", _pAuthor, _pCommitter, _Message, tree.m_pP, parentPtrs);

            if (git_repository_state(_pRepo) != GIT_REPOSITORY_STATE_NONE)
            {
                git_repository_state_cleanup(_pRepo);
            }

            return oid;
        }

        std::string CreateCommit(git_repository* _pRepo, const char* _szUpdateRef,
            const git_signature* _pAuthor, const git_signature* _pCommitter,
            const std::string& _Message, const git_tree* _pTree,
            const std::vector<const git_commit*>& _Parents)
        {
            const SigningConfig signing = ReadSigningConfig(_pRepo);
            const auto** pparents =
                _Parents.empty() ? nullptr : const_cast<const git_commit**>(_Parents.data());
            git_oid commitOid;

            if (!signing.m_bEnabled)
            {
                if (git_commit_create(&commitOid, _pRepo, /*update_ref=*/nullptr, _pAuthor,
                        _pCommitter, /*message_encoding=*/nullptr, _Message.c_str(), _pTree,
                        _Parents.size(), pparents) < 0)
                {
                    RaiseLastError("git_commit_create failed");
                }
            }
            else
            {
                // Build the raw commit, have gpg / ssh-keygen sign it, and
                // write it with the signature header.
                Buf raw;
                if (git_commit_create_buffer(&raw.m_B, _pRepo, _pAuthor, _pCommitter,
                        /*message_encoding=*/nullptr, _Message.c_str(), _pTree, _Parents.size(),
                        pparents) < 0)
                {
                    RaiseLastError("git_commit_create_buffer failed");
                }
                const std::string content = raw.Str();
                const char* szworkdir = git_repository_workdir(_pRepo);
                const std::string signature = SignBuffer(
                    signing, content, szworkdir ? szworkdir : git_repository_path(_pRepo));
                if (git_commit_create_with_signature(
                        &commitOid, _pRepo, content.c_str(), signature.c_str(), "gpgsig") < 0)
                {
                    RaiseLastError("Writing the signed commit failed");
                }
            }

            // Move the ref ourselves (git_commit_create would insist the ref
            // currently points at the first parent, which amend breaks). HEAD
            // means the branch it names, or HEAD itself when detached/unborn.
            if (_szUpdateRef)
            {
                const std::string summary = _Message.substr(0, _Message.find('\n'));
                const std::string reflog = "commit: " + summary;
                std::string target = _szUpdateRef;
                ReferencePtr head;
                if (target == "HEAD" && git_reference_lookup(&head.m_pP, _pRepo, "HEAD") == 0 &&
                    git_reference_type(head.m_pP) == GIT_REFERENCE_SYMBOLIC)
                {
                    target = git_reference_symbolic_target(head.m_pP);
                }
                ReferencePtr moved;
                if (git_reference_create(&moved.m_pP, _pRepo, target.c_str(), &commitOid,
                        /*force=*/1, reflog.c_str()) < 0)
                {
                    RaiseLastError("Updating " + target + " failed");
                }
            }
            return OidToHex(&commitOid);
        }

    } // namespace internal

    std::string Repository::Commit(const std::string& _Message)
    {
        if (!m_pRepo)
        {
            throw GitError("commit() on an unopened repository");
        }
        SignaturePtr sig;
        if (git_signature_default(&sig.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("No commit signature; set user.name and user.email");
        }
        return DoCommit(m_pRepo, _Message, sig.m_pP, sig.m_pP);
    }

    std::string Repository::Commit(const std::string& _Message, const std::string& _AuthorName,
        const std::string& _AuthorEmail)
    {
        if (!m_pRepo)
        {
            throw GitError("commit() on an unopened repository");
        }
        SignaturePtr sig;
        if (git_signature_now(&sig.m_pP, _AuthorName.c_str(), _AuthorEmail.c_str()) < 0)
        {
            RaiseLastError("git_signature_now failed");
        }
        return DoCommit(m_pRepo, _Message, sig.m_pP, sig.m_pP);
    }

    // ---- Diff ----------------------------------------------------------------
    FileDiff Repository::DiffFile(
        const std::string& _Path, DiffTarget _Target, const DiffOptions& _Options) const
    {
        if (!m_pRepo)
        {
            throw GitError("diffFile() on an unopened repository");
        }

        // The combined view is built from explicit HEAD/working-tree buffers so
        // the line-staging calls (RepositoryStaging.cpp) see byte-identical hunks
        // and can address lines by position.
        if (_Target == DiffTarget::Head)
        {
            return CombinedFileDiff(m_pRepo, _Path, _Options);
        }

        IndexPtr index;
        if (git_repository_index(&index.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_repository_index failed");
        }

        git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
        ApplyDiffOptions(opts, _Options);
        char* pszpaths[] = {const_cast<char*>(_Path.c_str())};
        opts.pathspec = git_strarray{pszpaths, 1};
        opts.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH | GIT_DIFF_INCLUDE_UNTRACKED |
                      GIT_DIFF_SHOW_UNTRACKED_CONTENT;

        DiffPtr diff;
        if (_Target == DiffTarget::Unstaged)
        {
            if (git_diff_index_to_workdir(&diff.m_pP, m_pRepo, index.m_pP, &opts) < 0)
            {
                RaiseLastError("git_diff_index_to_workdir failed");
            }
        }
        else
        {
            // On an unborn branch there is no HEAD tree; a null "old" tree yields
            // an all-added diff, which is what we want.
            TreePtr headTree = HeadTree(m_pRepo);
            if (git_diff_tree_to_index(&diff.m_pP, m_pRepo, headTree.m_pP, index.m_pP, &opts) < 0)
            {
                RaiseLastError("git_diff_tree_to_index failed");
            }
        }

        std::vector<FileDiff> files = CollectDiff(diff.m_pP);
        if (files.empty())
        {
            return {}; // empty path: no such change
        }
        return std::move(files.front());
    }

    // ---- Hunk-level staging ----------------------------------------------------
    namespace
    {

        // Extract one hunk from full patch text: keep the file header (everything
        // before the first "@@") plus only the hunkIndex-th "@@ ..." section. Using
        // libgit2's own patch printer means EOFNL markers etc. come out right.
        std::string SingleHunkPatch(const std::string& _FullPatch, std::size_t _HunkIndex)
        {
            std::string header;
            std::vector<std::string> hunks;
            std::size_t pos = 0;
            // Find hunk starts: lines beginning with "@@".
            std::vector<std::size_t> starts;
            while (pos < _FullPatch.size())
            {
                if (_FullPatch.compare(pos, 2, "@@") == 0 &&
                    (pos == 0 || _FullPatch[pos - 1] == '\n'))
                {
                    starts.push_back(pos);
                }
                pos = _FullPatch.find('\n', pos);
                if (pos == std::string::npos)
                {
                    break;
                }
                ++pos;
            }
            if (starts.empty() || _HunkIndex >= starts.size())
            {
                return {};
            }
            header = _FullPatch.substr(0, starts[0]);
            const std::size_t begin = starts[_HunkIndex];
            const std::size_t end =
                (_HunkIndex + 1 < starts.size()) ? starts[_HunkIndex + 1] : _FullPatch.size();
            std::string hunk = _FullPatch.substr(begin, end - begin);

            // The "@@ -old,n +new,m @@" header carries the NEW line number the hunk
            // lands on when every preceding hunk is applied too. libgit2's git_apply
            // positions hunks by that new number (git CLI searches by the old side),
            // so a lone mid-file hunk whose earlier siblings shifted lines "does not
            // apply". Renumber the new side to match the old side — correct for a
            // single-hunk patch, where nothing above it has moved.
            const std::size_t headerEnd = hunk.find('\n');
            if (headerEnd != std::string::npos)
            {
                long loldStart = 0, loldCount = 1;
                if (std::sscanf(hunk.c_str(), "@@ -%ld,%ld", &loldStart, &loldCount) >= 1)
                {
                    std::string rest;
                    const std::size_t plus = hunk.find(" +");
                    const std::size_t comma = hunk.find(',', plus);
                    const std::size_t space = hunk.find(' ', plus + 2);
                    const std::size_t newNumEnd =
                        (comma != std::string::npos && comma < space) ? comma : space;
                    if (plus != std::string::npos && newNumEnd != std::string::npos)
                    {
                        // Pure insertions ("-N,0") land AFTER line N: new side is N+1.
                        const long lnewStart = loldStart + (loldCount == 0 ? 1 : 0);
                        hunk = hunk.substr(0, plus + 2) + std::to_string(lnewStart) +
                               hunk.substr(newNumEnd);
                    }
                }
            }
            return header + hunk;
        }

        // Produce the full patch text for `path` in the given direction and apply just
        // hunk `hunkIndex` of it to the index.
        void ApplyOneHunkToIndex(git_repository* _pRepo, const std::string& _Path,
            std::size_t _HunkIndex, bool _bStagedSide)
        {
            IndexPtr index;
            if (git_repository_index(&index.m_pP, _pRepo) < 0)
            {
                RaiseLastError("git_repository_index failed");
            }

            git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
            char* pszpaths[] = {const_cast<char*>(_Path.c_str())};
            opts.pathspec = git_strarray{pszpaths, 1};

            DiffPtr diff;
            if (!_bStagedSide)
            {
                // Stage: old side = index, new side = working tree.
                if (git_diff_index_to_workdir(&diff.m_pP, _pRepo, index.m_pP, &opts) < 0)
                {
                    RaiseLastError("git_diff_index_to_workdir failed");
                }
            }
            else
            {
                // Unstage: the staged diff (HEAD -> index) printed REVERSED, so
                // applying it to the index rolls the hunk back.
                opts.flags |= GIT_DIFF_REVERSE;
                TreePtr headTree;
                git_oid oid;
                if (git_reference_name_to_id(&oid, _pRepo, "HEAD") == 0)
                {
                    CommitPtr c;
                    if (git_commit_lookup(&c.m_pP, _pRepo, &oid) == 0)
                    {
                        git_commit_tree(&headTree.m_pP, c.m_pP);
                    }
                }
                if (git_diff_tree_to_index(&diff.m_pP, _pRepo, headTree.m_pP, index.m_pP, &opts) <
                    0)
                {
                    RaiseLastError("git_diff_tree_to_index failed");
                }
            }

            git_buf buf = GIT_BUF_INIT;
            if (git_diff_to_buf(&buf, diff.m_pP, GIT_DIFF_FORMAT_PATCH) < 0)
            {
                RaiseLastError("git_diff_to_buf failed");
            }
            std::string fullPatch(buf.ptr, buf.size);
            git_buf_dispose(&buf);

            const std::string one = SingleHunkPatch(fullPatch, _HunkIndex);
            if (one.empty())
            {
                throw GitError(
                    "No such hunk #" + std::to_string(_HunkIndex) + " in '" + _Path + "'");
            }

            DiffPtr hunkDiff;
            if (git_diff_from_buffer(&hunkDiff.m_pP, one.data(), one.size()) < 0)
            {
                RaiseLastError("git_diff_from_buffer failed");
            }
            if (git_apply(_pRepo, hunkDiff.m_pP, GIT_APPLY_LOCATION_INDEX, nullptr) < 0)
            {
                RaiseLastError("git_apply (index) failed for '" + _Path + "'");
            }
        }

    } // namespace

    void Repository::StageHunk(const std::string& _Path, std::size_t _HunkIndex)
    {
        if (!m_pRepo)
        {
            throw GitError("stageHunk() on an unopened repository");
        }
        ApplyOneHunkToIndex(m_pRepo, _Path, _HunkIndex, /*stagedSide=*/false);
    }

    void Repository::UnstageHunk(const std::string& _Path, std::size_t _HunkIndex)
    {
        if (!m_pRepo)
        {
            throw GitError("unstageHunk() on an unopened repository");
        }
        ApplyOneHunkToIndex(m_pRepo, _Path, _HunkIndex, /*stagedSide=*/true);
    }

} // namespace gitgud::git
