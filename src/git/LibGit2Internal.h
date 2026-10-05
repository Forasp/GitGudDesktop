#pragma once

// -----------------------------------------------------------------------------
// LibGit2Internal — shared RAII holders + error helper for the git/ layer's
// implementation files ONLY. Never include this outside src/git/*.cpp: raw
// libgit2 types must not leak past the Repository API (see Repository.h).
// -----------------------------------------------------------------------------

#include <git2.h>
#include <git2/sys/errors.h>

#include <filesystem>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "git/Repository.h"
#include "p4/P4Workspace.h"

namespace gitgud::git::internal
{

    // Turn the last libgit2 error into a GitError with its message.
    [[noreturn]] inline void RaiseLastError(const std::string& _Context)
    {
        const git_error* pe = git_error_last();
        std::string msg = _Context;
        if (pe && pe->message)
        {
            msg += ": ";
            msg += pe->message;
        }
        throw GitError(msg);
    }

    // RAII holder for libgit2 handles: move-only, frees on destruction. Keeps
    // call sites free of manual git_*_free without a smart-pointer alias zoo.
    template <typename T, void (*FreeFn)(T*)> struct Handle
    {
        T* m_pP = nullptr;
        Handle() = default;

        Handle(Handle&& _O) noexcept : m_pP(_O.m_pP)
        {
            _O.m_pP = nullptr;
        }

        Handle& operator=(Handle&& _O) noexcept
        {
            if (this != &_O)
            {
                Reset();
                m_pP = _O.m_pP;
                _O.m_pP = nullptr;
            }
            return *this;
        }

        Handle(const Handle&) = delete;
        Handle& operator=(const Handle&) = delete;

        ~Handle()
        {
            Reset();
        }

        void Reset()
        {
            if (m_pP)
            {
                FreeFn(m_pP);
                m_pP = nullptr;
            }
        }
    };

    using IndexPtr = Handle<git_index, git_index_free>;
    using TreePtr = Handle<git_tree, git_tree_free>;
    using CommitPtr = Handle<git_commit, git_commit_free>;
    using ObjectPtr = Handle<git_object, git_object_free>;
    using SignaturePtr = Handle<git_signature, git_signature_free>;
    using DiffPtr = Handle<git_diff, git_diff_free>;
    using ReferencePtr = Handle<git_reference, git_reference_free>;
    using BranchIteratorPtr = Handle<git_branch_iterator, git_branch_iterator_free>;
    using ReferenceIteratorPtr = Handle<git_reference_iterator, git_reference_iterator_free>;
    using RevwalkPtr = Handle<git_revwalk, git_revwalk_free>;
    using RemotePtr = Handle<git_remote, git_remote_free>;
    using AnnotatedCommitPtr = Handle<git_annotated_commit, git_annotated_commit_free>;

    using BlobPtr = Handle<git_blob, git_blob_free>;
    using PatchPtr = Handle<git_patch, git_patch_free>;
    using ConfigPtr = Handle<git_config, git_config_free>;
    using RebasePtr = Handle<git_rebase, git_rebase_free>;
    using TagPtr = Handle<git_tag, git_tag_free>;
    using FilterListPtr = Handle<git_filter_list, git_filter_list_free>;
    using TreeEntryPtr = Handle<git_tree_entry, git_tree_entry_free>;
    using ReflogPtr = Handle<git_reflog, git_reflog_free>;
    using BlamePtr = Handle<git_blame, git_blame_free>;
    using SubmodulePtr = Handle<git_submodule, git_submodule_free>;
    using WorktreePtr = Handle<git_worktree, git_worktree_free>;
    using RepositoryPtr = Handle<git_repository, git_repository_free>;

    // Paths that differ between two trees (either may be null: empty).
    inline std::set<std::string> ChangedPaths(
        git_repository* _pRepo, git_tree* _pFrom, git_tree* _pTo)
    {
        std::set<std::string> paths;
        DiffPtr diff;
        if (git_diff_tree_to_tree(&diff.m_pP, _pRepo, _pFrom, _pTo, nullptr) < 0)
        {
            return paths;
        }
        const size_t ncount = git_diff_num_deltas(diff.m_pP);
        for (size_t ni = 0; ni < ncount; ++ni)
        {
            const git_diff_delta* pd = git_diff_get_delta(diff.m_pP, ni);
            paths.insert(pd->old_file.path);
            paths.insert(pd->new_file.path);
        }
        return paths;
    }

    // A SAFE checkout or a merge failed with _iErr. When it refused
    // because of uncommitted changes (GIT_ECONFLICT), raise a
    // LocalChangesError naming them: paths with local changes (staged,
    // unstaged, or untracked) that the update would write, i.e. that
    // differ between the two trees _Trees() returns (from, to). Anything
    // else is raised as the libgit2 error it is.
    template <typename TreesFn>
    [[noreturn]] void RaiseUpdateFailure(
        int _iErr, const std::string& _Context, git_repository* _pRepo, TreesFn&& _Trees)
    {
        if (_iErr != GIT_ECONFLICT)
        {
            RaiseLastError(_Context);
        }
        const git_error* pe = git_error_last();
        const std::string original =
            _Context + (pe && pe->message ? std::string(": ") + pe->message : "");

        const std::pair<TreePtr, TreePtr> trees = _Trees();
        const std::set<std::string> touched =
            ChangedPaths(_pRepo, trees.first.m_pP, trees.second.m_pP);
        std::vector<std::string> blocking;

        git_status_options opts = GIT_STATUS_OPTIONS_INIT;
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
        git_status_list* plist = nullptr;
        if (git_status_list_new(&plist, _pRepo, &opts) == 0)
        {
            const size_t ncount = git_status_list_entrycount(plist);
            for (size_t ni = 0; ni < ncount; ++ni)
            {
                const git_status_entry* ps = git_status_byindex(plist, ni);
                const git_diff_delta* pd =
                    ps->index_to_workdir ? ps->index_to_workdir : ps->head_to_index;
                if (!pd || (ps->status & GIT_STATUS_IGNORED))
                {
                    continue;
                }
                const char* szpath = pd->new_file.path ? pd->new_file.path : pd->old_file.path;
                if (szpath && touched.count(szpath))
                {
                    blocking.emplace_back(szpath);
                }
            }
            git_status_list_free(plist);
        }
        git_error_clear();

        if (blocking.empty())
        {
            throw GitError(original);
        }
        const std::size_t n = blocking.size();
        throw LocalChangesError("Uncommitted changes to " + std::to_string(n) +
                                    (n == 1 ? " file" : " files") + " would be overwritten",
            std::move(blocking));
    }

    // The tree of commit _pOid, or an empty holder when it can't be read.
    inline TreePtr CommitTree(git_repository* _pRepo, const git_oid* _pOid)
    {
        TreePtr tree;
        CommitPtr commit;
        if (git_commit_lookup(&commit.m_pP, _pRepo, _pOid) < 0 ||
            git_commit_tree(&tree.m_pP, commit.m_pP) < 0)
        {
            git_error_clear();
        }
        return tree;
    }

    // The trees a merge of _pTheirs into HEAD writes between: the merge
    // base's (empty when there's none) and theirs.
    inline std::pair<TreePtr, TreePtr> MergeTrees(git_repository* _pRepo, const git_oid* _pTheirs)
    {
        git_oid headOid;
        git_oid baseOid;
        const bool bbase = git_reference_name_to_id(&headOid, _pRepo, "HEAD") == 0 &&
                           git_merge_base(&baseOid, _pRepo, &headOid, _pTheirs) == 0;
        git_error_clear();
        return std::make_pair(
            bbase ? CommitTree(_pRepo, &baseOid) : TreePtr(), CommitTree(_pRepo, _pTheirs));
    }

    // A second handle on _pTree.
    inline TreePtr DupTree(git_tree* _pTree)
    {
        TreePtr tree;
        git_tree_dup(&tree.m_pP, _pTree);
        return tree;
    }

    struct StrArray
    {
        git_strarray m_A = {nullptr, 0};
        StrArray() = default;
        StrArray(const StrArray&) = delete;
        StrArray& operator=(const StrArray&) = delete;

        ~StrArray()
        {
            git_strarray_dispose(&m_A);
        }
    };

    // Owns a git_buf.
    struct Buf
    {
        git_buf m_B = GIT_BUF_INIT;
        Buf() = default;
        Buf(const Buf&) = delete;
        Buf& operator=(const Buf&) = delete;

        ~Buf()
        {
            git_buf_dispose(&m_B);
        }

        std::string Str() const
        {
            return m_B.ptr ? std::string(m_B.ptr, m_B.size) : std::string();
        }
    };

    // A pathspec of borrowed C strings (valid while the vector lives).
    struct PathSpec
    {
        std::vector<char*> m_Ptrs;
        git_strarray m_A = {nullptr, 0};

        explicit PathSpec(const std::vector<std::string>& _Paths)
        {
            m_Ptrs.reserve(_Paths.size());
            for (const auto& p : _Paths)
            {
                m_Ptrs.push_back(const_cast<char*>(p.c_str()));
            }
            m_A.strings = m_Ptrs.data();
            m_A.count = m_Ptrs.size();
        }
    };

    inline std::string OidToHex(const git_oid* _pOid)
    {
        char szbuf[64] = {0};
        git_oid_tostr(szbuf, sizeof(szbuf), _pOid);
        return std::string(szbuf);
    }

    // Signature for machine-generated commits (merges, stashes, reverts): prefer
    // the user's config identity, fall back to a neutral one so the operation
    // still succeeds in unconfigured environments (tests, fresh machines).
    inline SignaturePtr SignatureOrFallback(git_repository* _pRepo)
    {
        SignaturePtr sig;
        if (git_signature_default(&sig.m_pP, _pRepo) == 0)
        {
            return sig;
        }
        if (git_signature_now(&sig.m_pP, "Gitgud", "gitgud@localhost") < 0)
        {
            RaiseLastError("git_signature_now failed");
        }
        return sig;
    }

    // Resolve any commit-ish ("main", "v1.0", an oid, "HEAD~2") to a commit.
    inline CommitPtr ResolveCommit(git_repository* _pRepo, const std::string& _Spec)
    {
        ObjectPtr obj;
        if (git_revparse_single(&obj.m_pP, _pRepo, _Spec.c_str()) < 0)
        {
            RaiseLastError("Unknown revision '" + _Spec + "'");
        }
        ObjectPtr peeled;
        if (git_object_peel(&peeled.m_pP, obj.m_pP, GIT_OBJECT_COMMIT) < 0)
        {
            RaiseLastError("'" + _Spec + "' is not a commit");
        }
        CommitPtr c;
        c.m_pP = reinterpret_cast<git_commit*>(peeled.m_pP);
        peeled.m_pP = nullptr;
        return c;
    }

    // HEAD's tree, or an empty holder on an unborn branch.
    inline TreePtr HeadTree(git_repository* _pRepo)
    {
        TreePtr tree;
        git_oid oid;
        if (git_reference_name_to_id(&oid, _pRepo, "HEAD") == 0)
        {
            CommitPtr c;
            if (git_commit_lookup(&c.m_pP, _pRepo, &oid) == 0)
            {
                git_commit_tree(&tree.m_pP, c.m_pP);
            }
        }
        return tree;
    }

    // The remote a local branch's upstream lives on (branch.<name>.remote), or
    // "" when it has none. Reads config, so it works before the first fetch.
    inline std::string UpstreamRemoteOf(git_repository* _pRepo, const char* _szRefName)
    {
        Buf buf;
        if (git_branch_upstream_remote(&buf.m_B, _pRepo, _szRefName) != 0)
        {
            return {};
        }
        return buf.Str();
    }

    // The branch name a local branch's upstream has on its remote
    // (branch.<name>.merge without "refs/heads/"), or "" when it has none.
    inline std::string UpstreamBranchOf(git_repository* _pRepo, const char* _szRefName)
    {
        Buf buf;
        if (git_branch_upstream_merge(&buf.m_B, _pRepo, _szRefName) != 0)
        {
            return {};
        }
        std::string merge = buf.Str();
        const std::string prefix = "refs/heads/";
        if (merge.compare(0, prefix.size(), prefix) == 0)
        {
            merge.erase(0, prefix.size());
        }
        return merge;
    }

    // Commit the current index on top of HEAD (+ MERGE_HEADs) as `_pAuthor` /
    // `_pCommitter`; clears any in-progress operation state. Defined in
    // Repository.cpp.
    std::string DoCommit(git_repository* _pRepo, const std::string& _Message,
        const git_signature* _pAuthor, const git_signature* _pCommitter);

    // Write a commit object — signed when the repository's config asks for it
    // (commit.gpgsign) — and, when `_szUpdateRef` is set ("HEAD" or a full ref
    // name), move that ref to it. Every commit the app creates goes through
    // here. Returns the new commit's id (hex). Defined in Repository.cpp.
    std::string CreateCommit(git_repository* _pRepo, const char* _szUpdateRef,
        const git_signature* _pAuthor, const git_signature* _pCommitter,
        const std::string& _Message, const git_tree* _pTree,
        const std::vector<const git_commit*>& _Parents);

    // Fill `_Out` from the commit `_pOid`; false when it can't be read.
    // Defined in RepositoryRefs.cpp.
    bool ReadCommitInfo(git_repository* _pRepo, const git_oid* _pOid, CommitInfo& _Out);

    // ---- Commit signing (CommitSigning.cpp) ---------------------------------
    // What commit.gpgsign / gpg.format / user.signingkey / gpg.program say.
    struct SigningConfig
    {
        bool m_bEnabled = false;
        std::string m_Format = "openpgp"; // "openpgp" (gpg) or "ssh" (ssh-keygen)
        std::string m_Key;                // user.signingkey ("" = the tool's default)
        std::string m_Program;            // gpg.program / gpg.ssh.program override
    };

    SigningConfig ReadSigningConfig(git_repository* _pRepo);

    // A detached, armored signature over `_Content`, made by the configured
    // tool. Throws GitError carrying the tool's own message on failure.
    std::string SignBuffer(
        const SigningConfig& _Config, const std::string& _Content, const std::string& _WorkDir);

    // ---- Git LFS (LfsFilter.cpp) --------------------------------------------
    // Register the "lfs" filter (clean/smudge through git-lfs) with libgit2 if
    // git-lfs is installed. Safe to call after every git_libgit2_init.
    void RegisterLfsFilter();
    bool LfsFilterRegistered();

    // ---- Remote callbacks (RepositoryNetwork.cpp) -----------------------------
    // Credentials (HTTPS user/token, SSH agent or key files) and SSH host-key
    // checks for every network operation, including submodule updates.
    struct RemoteContext
    {
        const CredentialProvider* m_pProvider = nullptr;
        const HostKeyProvider* m_pHostKeys = nullptr;
        int m_iAttempts = 0;
        int m_iSshStage = 0; // 0 agent, 1.. key files in turn
        std::string m_SshKeyTried;
    };

    void SetupRemoteCallbacks(git_remote_callbacks& _Callbacks, RemoteContext& _Context);

    // Every file of a diff as plain data (hunks + lines + status). Defined in
    // RepositoryRefs.cpp.
    std::vector<FileDiff> CollectDiff(git_diff* _pDiff);

    // The HEAD -> working tree diff of one file, built from explicit buffers
    // (see RepositoryStaging.cpp). DiffFile(path, Head) returns exactly this.
    FileDiff CombinedFileDiff(
        git_repository* _pRepo, const std::string& _Path, const DiffOptions& _Options);

    // One version of a file, repository-normalized (what a blob would hold).
    struct FileVersion
    {
        std::string m_Text;
        bool m_bExists = false;
        uint32_t m_uiMode = GIT_FILEMODE_BLOB;
    };

    // Read `_Path` as of `_Revision`: "workdir" (filtered to ODB form, so it
    // compares with blobs), "index", "head", or any commit-ish. Defined in
    // RepositoryStaging.cpp.
    FileVersion ReadVersion(
        git_repository* _pRepo, const std::string& _Path, const std::string& _Revision);

    // Write repository-normalized text to the working tree (to-worktree
    // filters applied), creating folders as needed. RepositoryStaging.cpp.
    void WriteWorkingFile(
        git_repository* _pRepo, const std::string& _Path, const std::string& _Text);

    // Absolute path of a working-tree file. RepositoryStaging.cpp.
    std::filesystem::path WorkingPath(git_repository* _pRepo, const std::string& _Path);

    // Diff two file versions as a FileDiff. RepositoryStaging.cpp.
    FileDiff DiffFileVersions(const std::string& _OldPath, const FileVersion& _Old,
        const std::string& _NewPath, const FileVersion& _New, const DiffOptions& _Options);

    // Split a diff3-style merged text (conflict markers) into the chunks the
    // 3-pane merge tool shows. RepositoryRewrite.cpp.
    void ChunkMergedText(const std::string& _Text, ConflictFile& _Out);

    // A conflict built from plain buffers (no repository): the base may be
    // missing (both sides added), and a missing side means it was deleted.
    // Used by the Perforce backend. RepositoryRewrite.cpp.
    ConflictFile ConflictFromBuffers(const std::string& _Path, const std::string* _pBase,
        const std::string* _pOurs, const std::string* _pTheirs);

    // Three-way merge of plain buffers. Returns true when it merged cleanly;
    // `_OutMerged` holds the result, with conflict markers when it didn't.
    bool MergeBuffers(const std::string& _Path, const std::string* _pBase, const std::string& _Ours,
        const std::string& _Theirs, std::string& _OutMerged);

    // A Repository credential provider asked for Perforce passwords: the
    // credential key is "p4:<P4PORT>". Repository.cpp.
    p4::PasswordProvider P4Passwords(const CredentialProvider& _Provider);

    // Translate DiffOptions onto libgit2's struct.
    inline void ApplyDiffOptions(git_diff_options& _Opts, const DiffOptions& _Options)
    {
        _Opts.context_lines = static_cast<uint32_t>(_Options.m_iContextLines);
        if (_Options.m_bIgnoreWhitespace)
        {
            _Opts.flags |= GIT_DIFF_IGNORE_WHITESPACE;
        }
    }

} // namespace gitgud::git::internal
