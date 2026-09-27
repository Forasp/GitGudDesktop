#pragma once

// -----------------------------------------------------------------------------
// Repository — a thin RAII wrapper over libgit2's git_repository.
//
// Design rules for the git/ layer:
//   * No raw git_* pointers escape this layer; callers get plain C++ types.
//   * Every libgit2 handle is owned by RAII; no manual git_*_free at call sites.
//   * Errors surface as GitError (thrown), never libgit2 codes.
//   * This layer is UI-agnostic and unit-testable against throwaway repos.
//
// Covers init/open, status, staging, commits, structured diffs, branches,
// history, remotes, stash, merge, and networked ops (fetch/push/pull/clone)
// with a pluggable credential provider.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

struct git_repository; // fwd-decl; avoids leaking <git2.h> into the whole app

namespace gitgud::git
{

    // Thrown for any libgit2 failure, carrying the human-readable message.
    class GitError : public std::runtime_error
    {
      public:
        explicit GitError(const std::string& _What) : std::runtime_error(_What)
        {
        }
    };

    // Call once at startup / shutdown (wraps git_libgit2_init / _shutdown).
    class LibGit2
    {
      public:
        LibGit2();
        ~LibGit2();
        LibGit2(const LibGit2&) = delete;
        LibGit2& operator=(const LibGit2&) = delete;
    };

    // One changed path in the working tree / index.
    struct StatusEntry
    {
        std::string m_Path;
        bool m_bStaged = false;   // change present in the index (vs HEAD)
        bool m_bUnstaged = false; // change present in the working tree (vs index)
        char m_cCode = ' '; // 'M' modified, 'A' added, 'D' deleted, '?' untracked, 'U' conflicted
    };

    // ---- Structured diff (built for later line-level staging) ----------------
    struct DiffLine
    {
        char m_cOrigin = ' ';  // ' ' context, '+' added, '-' removed
        int m_iOldLineno = -1; // -1 when not applicable (added line)
        int m_iNewLineno = -1; // -1 when not applicable (removed line)
        std::string m_Content; // line text (without the origin marker)
    };

    struct DiffHunk
    {
        std::string m_Header; // the "@@ -a,b +c,d @@" line
        int m_iOldStart = 0, m_iOldLines = 0, m_iNewStart = 0, m_iNewLines = 0;
        std::vector<DiffLine> m_Lines;
    };

    struct FileDiff
    {
        std::string m_Path;
        std::string m_OldPath; // differs from m_Path only for renames
        char m_cStatus = 'M';  // 'A' added, 'D' deleted, 'M' modified, 'R' renamed, 'T' type change
        bool m_bIsBinary = false;
        std::vector<DiffHunk> m_Hunks;
    };

    // Knobs shared by every diff producer.
    struct DiffOptions
    {
        bool m_bIgnoreWhitespace = false; // like `git diff -w`
        int m_iContextLines = 3;
        std::vector<std::string> m_Paths; // DiffCommit only: limit to these paths ("" = all)
    };

    // Which side of the index a diff describes.
    enum class DiffTarget
    {
        Unstaged, // index -> working tree  (what `git diff` shows)
        Staged,   // HEAD  -> index         (what `git diff --cached` shows)
        Head,     // HEAD  -> working tree  (what `git diff HEAD` shows: staged
                  //                         and unstaged changes combined)
    };

    // ---- Branches / remotes / history / stash / merge (plain-data models) -----
    struct BranchInfo
    {
        std::string m_Name;         // shorthand, e.g. "main" or "origin/main"
        bool m_bIsHead = false;     // the currently checked-out branch
        bool m_bIsRemote = false;   // a remote-tracking branch (refs/remotes/...)
        std::string m_Upstream;     // shorthand of the upstream branch, or ""
        std::string m_TargetOid;    // tip commit (hex)
        std::int64_t m_TimeUtc = 0; // tip commit time, for "recent branches" sorting
        std::size_t m_Ahead = 0;    // vs upstream (local branches with an upstream only)
        std::size_t m_Behind = 0;
    };

    struct TagInfo
    {
        std::string m_Name;      // shorthand, e.g. "v1.0"
        std::string m_TargetOid; // the commit the tag points at (hex)
        std::string m_Message;   // annotation; "" for lightweight tags
    };

    // A ref pointing at a commit, for decorating history rows.
    struct RefLabel
    {
        std::string m_Oid;  // commit the ref resolves to (hex)
        std::string m_Name; // shorthand
        char m_cKind = 'b'; // 'b' local branch, 'r' remote branch, 't' tag, 'h' HEAD (detached)
    };

    // What the repository is in the middle of, if anything.
    enum class RepoState
    {
        None,
        Merge,
        Rebase,
        CherryPick,
        Revert,
        Other
    };

    enum class ResetMode
    {
        Soft,  // move HEAD only
        Mixed, // move HEAD + reset index (changes stay in the working tree)
        Hard   // move HEAD + reset index + working tree
    };

    // Which commits Log() walks.
    struct LogQuery
    {
        std::size_t m_MaxCount = 200;
        std::size_t m_Skip = 0; // for paging
        std::string m_From;     // start ref/oid; "" = HEAD
        std::string m_Hide;     // exclude commits reachable from this ref ("" = none)
    };

    struct RebaseResult
    {
        enum class Kind
        {
            UpToDate,
            Done,
            Conflicts
        };
        Kind m_Kind = Kind::UpToDate;
        std::string m_Message;
        std::vector<std::string> m_ConflictedPaths;
    };

    struct RemoteInfo
    {
        std::string m_Name; // e.g. "origin"
        std::string m_Url;
    };

    struct CommitInfo
    {
        std::string m_Oid;      // full hex
        std::string m_ShortOid; // 7-char prefix
        std::string m_Summary;  // first line of the message
        std::string m_Message;  // full message
        std::string m_AuthorName;
        std::string m_AuthorEmail;
        std::int64_t m_TimeUtc = 0;         // seconds since epoch
        std::vector<std::string> m_Parents; // parent OIDs (hex)
    };

    struct StashInfo
    {
        std::size_t m_Index = 0; // stash@{index}
        std::string m_Message;
        std::string m_Oid;
    };

    struct MergeResult
    {
        enum class Kind
        {
            UpToDate,
            FastForward,
            Merged,
            Conflicts
        };
        Kind m_Kind = Kind::UpToDate;
        std::string m_Message;                      // human-readable outcome
        std::vector<std::string> m_ConflictedPaths; // set when kind == Conflicts
    };

    // How many commits the current branch is ahead of / behind its upstream.
    struct AheadBehind
    {
        std::size_t m_Ahead = 0, m_Behind = 0;
        bool m_bHasUpstream = false;
        std::string m_Upstream;       // shorthand, e.g. "origin/main" ("" when none)
        std::string m_UpstreamRemote; // remote the upstream lives on ("" when none)
    };

    // ---- Graph / undo / conflicts / rewriting (the GitKraken-style features) ---

    // Which commits GraphLog() walks: every local branch and HEAD, plus
    // (optionally) remote-tracking branches and tags.
    struct GraphQuery
    {
        std::size_t m_MaxCount = 400;
        bool m_bRemotes = true;
        bool m_bTags = true;
    };

    // One reflog line ("HEAD@{n}"): where the ref moved from and to, and why.
    struct ReflogEntry
    {
        std::string m_OldOid;
        std::string m_NewOid;
        std::string m_Message;
        std::string m_Committer;
        std::int64_t m_TimeUtc = 0;
    };

    // A conflicted file split into the regions both sides agree on and the
    // regions they fight over (what the 3-pane merge tool shows). Lines carry
    // no terminator; a trailing "\r" is kept on CRLF files.
    struct ConflictChunk
    {
        bool m_bConflict = false;
        std::vector<std::string> m_Lines;  // common text (m_bConflict == false)
        std::vector<std::string> m_Ours;   // the checked-out side
        std::vector<std::string> m_Theirs; // the incoming side
        std::vector<std::string> m_Base;   // their common ancestor (may be empty)
    };

    struct ConflictFile
    {
        std::string m_Path;
        bool m_bBinary = false;        // can't be merged as text: pick a side
        bool m_bOursDeleted = false;   // our side deleted the file
        bool m_bTheirsDeleted = false; // their side deleted the file
        bool m_bTrailingNewline = true;
        std::vector<ConflictChunk> m_Chunks;
    };

    // One step of an interactive rebase plan (oldest commit first).
    struct RebaseStep
    {
        enum class Action
        {
            Pick,   // keep as is
            Reword, // keep the changes, use m_Message
            Squash, // fold into the previous commit, joining the messages
            Fixup,  // fold into the previous commit, dropping this message
            Drop    // leave the commit out
        };
        Action m_Action = Action::Pick;
        std::string m_Oid;
        std::string m_Message; // Reword: the new message; Squash: optional combined message
    };

    // A run of consecutive lines that last changed in the same commit.
    struct BlameHunk
    {
        std::string m_Oid; // all zeros for lines not committed yet
        std::string m_Summary;
        std::string m_Author;
        std::int64_t m_TimeUtc = 0;
        std::size_t m_StartLine = 0; // 1-based line in the blamed version
        std::size_t m_LineCount = 0;
        bool m_bUncommitted = false;
    };

    struct BlameResult
    {
        std::vector<std::string> m_Lines; // the blamed version's text, one entry per line
        std::vector<BlameHunk> m_Hunks;
    };

    struct SubmoduleInfo
    {
        std::string m_Name;
        std::string m_Path; // relative to the parent's working tree
        std::string m_Url;
        std::string m_HeadOid;       // commit the parent's HEAD records
        std::string m_WorkdirOid;    // commit checked out inside the submodule ("" if not)
        bool m_bInitialized = false; // cloned into the working tree
        bool m_bModified = false;    // checked out at a different commit than recorded
        bool m_bDirty = false;       // has uncommitted changes inside
    };

    struct WorktreeInfo
    {
        std::string m_Name;
        std::string m_Path;
        std::string m_Branch; // checked-out branch ("" when detached / unknown)
        bool m_bLocked = false;
        bool m_bValid = true; // its folder still exists
        bool m_bMain = false; // the repository's own working tree
    };

    // ---- Browsing, shelving, revision graphs (the P4V-style UI) ----------------

    // One entry of a directory in a commit's tree.
    struct TreeEntry
    {
        std::string m_Name; // "main.cpp"
        std::string m_Path; // "src/main.cpp", relative to the repository root
        bool m_bIsDir = false;
        bool m_bIsSubmodule = false;
        std::string m_Oid;       // blob / tree / commit id (hex)
        std::int64_t m_Size = 0; // bytes (files only)
    };

    // One file that differs between two versions (name-status only).
    struct ChangedFile
    {
        std::string m_Path;
        std::string m_OldPath; // differs from m_Path only for renames
        char m_cStatus = 'M';  // 'A', 'D', 'M', 'R', 'T'
    };

    // What unshelving did, per file.
    struct UnshelveResult
    {
        std::vector<std::string> m_Applied;    // written cleanly
        std::vector<std::string> m_Conflicted; // written with conflict markers
        std::vector<std::string> m_Skipped;    // binary and changed locally: left alone
    };

    // A file's history across every branch, laid out like P4V's revision
    // graph: one row per branch, one column per commit (oldest left), edges
    // from each revision to the revisions it was built from.
    struct RevisionRow
    {
        std::string m_Name; // branch shorthand ("main", "origin/topic"), or "" for history
                            // no branch reaches along its first parents
        bool m_bHead = false;
        bool m_bRemote = false;
    };

    struct RevisionNode
    {
        CommitInfo m_Commit;
        int m_iRow = 0;
        int m_iColumn = 0;
        int m_iRevision = 0;  // 1-based count along its row (P4V's "#n")
        char m_cAction = 'M'; // 'A' added, 'M' edited, 'D' deleted, 'I' merged in
    };

    struct RevisionEdge
    {
        int m_iFrom = 0; // node indices
        int m_iTo = 0;
        bool m_bMerge = false; // the merge parent of a merge commit (an integration)
    };

    struct RevisionGraph
    {
        std::vector<RevisionRow> m_Rows;
        std::vector<RevisionNode> m_Nodes; // in column order
        std::vector<RevisionEdge> m_Edges;
    };

    struct RevisionGraphQuery
    {
        bool m_bRemotes = true;
        std::size_t m_MaxNodes = 300;
        std::size_t m_MaxWalk = 20000;              // commits examined in total
        std::vector<std::string> m_ExcludeBranches; // rows to leave out (branch shorthands)
    };

    // Supplies credentials for networked operations. Return true and fill
    // user/pass to attempt an authentication; return false to give up (the
    // operation fails with the server's auth error). SSH key passphrases are
    // asked for with `_Url` = "ssh-key:<private key path>" (fill _OutPassword).
    using CredentialProvider = std::function<bool(const std::string& _Url,
        const std::string& _UsernameFromUrl, std::string& _OutUsername, std::string& _OutPassword)>;

    // Decides whether to trust an SSH server whose host key isn't in
    // ~/.ssh/known_hosts. `_KnownHostsLine` is what trusting it would append
    // there ("host ssh-ed25519 AAAA..."). Return true to connect anyway.
    using HostKeyProvider = std::function<bool(const std::string& _Host,
        const std::string& _Fingerprint, const std::string& _KnownHostsLine)>;

    class Repository
    {
      public:
        Repository() = default;
        ~Repository();

        Repository(Repository&&) noexcept;
        Repository& operator=(Repository&&) noexcept;
        Repository(const Repository&) = delete;
        Repository& operator=(const Repository&) = delete;

        // Open an existing repository at `path`. Throws GitError on failure.
        static Repository Open(const std::string& _Path);

        // Create a new, non-bare repository at `path` (like `git init`).
        static Repository Init(const std::string& _Path);

        // Create a bare repository (like `git init --bare`). Serves as a local
        // "server" for push/pull/clone — both in tests and for self-hosted use.
        static Repository InitBare(const std::string& _Path);

        // Working-tree + index status, one entry per changed path.
        std::vector<StatusEntry> Status() const;

        // Stage a path (like `git add <path>`). Handles new/modified files and
        // deletions (removes the entry from the index).
        void Stage(const std::string& _Path);

        // Stage many paths with a single index write (the "include all" box).
        void Stage(const std::vector<std::string>& _Paths);

        // Unstage a path (like `git reset HEAD <path>`). On an unborn branch this
        // removes the path from the index.
        void Unstage(const std::string& _Path);

        // Unstage many paths in one reset.
        void Unstage(const std::vector<std::string>& _Paths);

        // ---- Line-level staging -------------------------------------------------
        // All three work on the file's COMBINED diff (DiffFile(path, Head)) and
        // address lines by their 0-based position in the flattened list of every
        // hunk's lines, in order (context and EOF markers included, so indices line
        // up with what the UI rendered). `_ExpectedLineCount` is that list's length
        // as the caller saw it — a mismatch means the file changed underneath and
        // the call throws instead of staging the wrong lines.

        // Indices of the changed lines currently present in the index.
        std::vector<std::size_t> StagedLines(const std::string& _Path) const;

        // Rewrite the file's index entry so EXACTLY `_Lines` are staged.
        void SetStagedLines(const std::string& _Path, const std::vector<std::size_t>& _Lines,
            std::size_t _ExpectedLineCount);

        // Revert `_Lines` in both the working tree and the index. Discarding every
        // line of a file that isn't in HEAD removes the file via `_RemoveFile`.
        void DiscardLines(const std::string& _Path, const std::vector<std::size_t>& _Lines,
            std::size_t _ExpectedLineCount,
            const std::function<bool(const std::string&)>& _RemoveFile = nullptr);

        // Throw away every change (staged and unstaged) to `_Paths`: tracked files
        // are restored from HEAD; files HEAD doesn't have are unstaged and handed to
        // `_RemoveFile` (absolute path; e.g. move to the recycle bin), or deleted
        // when it is null.
        void DiscardChanges(const std::vector<std::string>& _Paths,
            const std::function<bool(const std::string&)>& _RemoveFile = nullptr);

        // Append a pattern to the repository's top-level .gitignore.
        void AddToGitignore(const std::string& _Pattern);

        // Read one version of a file's bytes. `_Revision` is "workdir", "index",
        // "head", a commit oid (that commit's tree), or "<oid>^" (its first
        // parent). Returns false when the file doesn't exist in that version.
        bool ReadFileVersion(
            const std::string& _Path, const std::string& _Revision, std::string& _Out) const;

        // Commit the current index on top of HEAD. Returns the new commit's OID
        // (hex). Throws if there is nothing to commit is NOT enforced here — callers
        // decide. The signature is taken from repo config (user.name/user.email).
        std::string Commit(const std::string& _Message);

        // Commit with an explicit author/committer signature (used by tests and by
        // flows that don't rely on git config).
        std::string Commit(const std::string& _Message, const std::string& _AuthorName,
            const std::string& _AuthorEmail);

        // Replace HEAD with a commit of the current index and `_Message` (like
        // `git commit --amend`). Returns the new OID.
        std::string AmendCommit(const std::string& _Message);

        // Undo the HEAD commit, keeping its changes staged (like `git reset
        // --soft HEAD~1`; on a root commit the branch becomes unborn again).
        // Returns the undone commit's full message so the UI can restore it.
        std::string UndoLastCommit();

        // Structured diff for a single path, on the requested side of the index.
        // Returns an empty FileDiff (empty path) if the file has no such changes.
        FileDiff DiffFile(
            const std::string& _Path, DiffTarget _Target, const DiffOptions& _Options = {}) const;

        // ---- Hunk-level staging --------------------------------------------
        // Apply just one hunk of the file's unstaged diff to the index (like
        // clicking a hunk in GitHub Desktop). `hunkIndex` indexes into the hunks
        // of diffFile(path, Unstaged) captured at the same moment.
        void StageHunk(const std::string& _Path, std::size_t _HunkIndex);
        // Reverse-apply one hunk of the staged diff (partial unstage).
        void UnstageHunk(const std::string& _Path, std::size_t _HunkIndex);

        // ---- Branches --------------------------------------------------------
        std::vector<BranchInfo> Branches() const; // local + remote-tracking
        // Shorthand name of the checked-out branch. Works on an unborn HEAD too
        // (returns the branch the first commit will land on). "" when detached.
        std::string CurrentBranch() const;
        void CreateBranch(const std::string& _Name); // from current HEAD
        // From any commit-ish (branch name, tag, oid).
        void CreateBranch(const std::string& _Name, const std::string& _StartPoint);
        void Checkout(const std::string& _Name); // safe checkout + set HEAD
        // Detach HEAD at a commit (safe checkout).
        void CheckoutCommit(const std::string& _Oid);
        void DeleteBranch(const std::string& _Name);
        void RenameBranch(const std::string& _OldName, const std::string& _NewName);

        // ---- History ---------------------------------------------------------
        // Walk from HEAD, newest first, up to maxCount commits. Empty on an
        // unborn branch.
        std::vector<CommitInfo> Log(std::size_t _MaxCount = 200) const;
        std::vector<CommitInfo> Log(const LogQuery& _Query) const;
        // Full structured diff of a commit against its first parent (all files).
        std::vector<FileDiff> DiffCommit(
            const std::string& _Oid, const DiffOptions& _Options = {}) const;
        // Every branch/tag (and a detached HEAD) with the commit it points at.
        std::vector<RefLabel> RefLabels() const;
        // Commits HEAD has that `_Ref` lacks (ahead) and vice versa (behind).
        AheadBehind CompareWith(const std::string& _Ref) const;

        // Create a commit undoing `_Oid` on top of HEAD. Returns the new OID, or
        // "" when the revert conflicted (the repo is left in the revert state).
        std::string Revert(const std::string& _Oid);
        // Apply `_Oid` on top of HEAD, keeping its author. Same return contract.
        std::string CherryPick(const std::string& _Oid);
        // Move the current branch to `_Oid`.
        void ResetTo(const std::string& _Oid, ResetMode _Mode);

        // ---- Tags ----------------------------------------------------------------
        std::vector<TagInfo> Tags() const;
        // Lightweight when `_Message` is empty, annotated otherwise.
        void CreateTag(
            const std::string& _Name, const std::string& _Target, const std::string& _Message = "");
        void DeleteTag(const std::string& _Name);

        // ---- In-progress operations ------------------------------------------------
        RepoState State() const;
        // Resolve a conflicted file by taking one side wholesale, then stage it.
        void ResolveConflict(const std::string& _Path, bool _bOurs);
        // Abort whatever is in progress (merge/revert/cherry-pick: hard reset to
        // HEAD; rebase: restore the original branch).
        void AbortOperation();

        // ---- Config ----------------------------------------------------------------
        // Effective value (repo, falling back to global); "" when unset.
        std::string GetConfig(const std::string& _Key) const;
        void SetConfig(const std::string& _Key, const std::string& _Value);
        // The user's global ~/.gitconfig, usable with no repository open.
        static std::string GetGlobalConfig(const std::string& _Key);
        static void SetGlobalConfig(const std::string& _Key, const std::string& _Value);

        // ---- Remotes -----------------------------------------------------------
        std::vector<RemoteInfo> Remotes() const;
        void AddRemote(const std::string& _Name, const std::string& _Url);
        // Removing a remote also drops its remote-tracking branches and any
        // upstream settings that pointed at it (as `git remote remove` does).
        void RemoveRemote(const std::string& _Name);
        // Change a remote's URL, keeping its branches and upstream settings.
        void SetRemoteUrl(const std::string& _Name, const std::string& _Url);
        // Rename a remote; its remote-tracking branches and the upstream
        // settings that pointed at it follow.
        void RenameRemote(const std::string& _Name, const std::string& _NewName);
        // Track `_Upstream` ("remote/branch") from local branch `_Branch`;
        // "" stops tracking.
        void SetUpstream(const std::string& _Branch, const std::string& _Upstream);

        // ---- Stash -------------------------------------------------------------
        std::vector<StashInfo> StashList() const;
        void StashSave(const std::string& _Message); // includes untracked files
        void StashApply(std::size_t _Index);
        void StashPop(std::size_t _Index);
        void StashDrop(std::size_t _Index);
        // What a stash would change: tracked edits plus its untracked files.
        std::vector<FileDiff> StashDiff(std::size_t _Index) const;

        // ---- Merge -------------------------------------------------------------
        // Merge a local branch into HEAD. Fast-forwards when possible; otherwise a
        // 3-way merge that either commits (no conflicts) or leaves the repo in a
        // conflicted merge state (resolve + commit(), or abortMerge()).
        MergeResult Merge(const std::string& _BranchName);
        // Squash `_BranchName`'s changes into ONE new commit on HEAD. Conflicts
        // are left in the index (no merge state) for the user to resolve+commit.
        MergeResult SquashMerge(const std::string& _BranchName);
        std::vector<std::string> ConflictedPaths() const;
        void AbortMerge(); // hard-reset working tree to HEAD and clear merge state

        // ---- Rebase ------------------------------------------------------------
        // Replay the current branch's commits onto `_Upstream` (a branch name).
        // Stops at the first conflicting commit (resolve, then ContinueRebase).
        RebaseResult Rebase(const std::string& _Upstream);
        RebaseResult ContinueRebase();

        // ---- Commit graph ------------------------------------------------------
        // Commits reachable from every branch (see GraphQuery), newest first in
        // topological order — the input for LayoutGraph (git/CommitGraph.h).
        std::vector<CommitInfo> GraphLog(const GraphQuery& _Query) const;

        // ---- Undo support ------------------------------------------------------
        // The commit HEAD points at ("" on an unborn branch).
        std::string HeadOid() const;
        // Newest-first reflog of `_Ref` ("HEAD", "refs/heads/main", ...).
        std::vector<ReflogEntry> Reflog(const std::string& _Ref, std::size_t _MaxCount) const;
        // Point local branch `_Name` at `_Oid`, creating it if needed. If it's
        // the checked-out branch the working tree follows with a SAFE checkout
        // (it refuses rather than overwrite uncommitted changes).
        void SetBranchTarget(const std::string& _Name, const std::string& _Oid);

        // ---- 3-pane conflict resolution ----------------------------------------
        // Split a conflicted file into agreed and contested regions. Resolve by
        // writing the chosen text to the file and staging it.
        ConflictFile ReadConflict(const std::string& _Path) const;

        // ---- Interactive rebase --------------------------------------------------
        // The commits an interactive rebase onto `_Base` would rewrite: those on
        // HEAD's first-parent chain after `_Base`, oldest first. Throws when the
        // range holds a merge commit (not supported) or `_Base` isn't an ancestor.
        std::vector<CommitInfo> RebaseTodo(const std::string& _Base) const;
        // Rewrite those commits per `_Steps` (which must name exactly the todo
        // commits, in the new order). Runs entirely in memory: on a conflict it
        // stops with Kind::Conflicts and leaves the repository untouched.
        // ORIG_HEAD records the old tip.
        RebaseResult InteractiveRebase(
            const std::string& _Base, const std::vector<RebaseStep>& _Steps);

        // ---- File history / blame ------------------------------------------------
        // Commits (from HEAD, newest first) whose change touched `_Path`.
        std::vector<CommitInfo> FileLog(const std::string& _Path, std::size_t _MaxCount) const;
        // Who last changed each line. `_Revision` is "workdir" (the file on disk,
        // uncommitted lines included) or any commit-ish.
        BlameResult Blame(const std::string& _Path, const std::string& _Revision) const;

        // ---- Submodules ------------------------------------------------------------
        std::vector<SubmoduleInfo> Submodules() const;
        // Clone (if `_bInit`) and check out the recorded commit. BLOCKS on the
        // network; run it on a worker thread.
        void UpdateSubmodule(const std::string& _Name, bool _bInit);

        // ---- Worktrees ---------------------------------------------------------------
        // Every working tree of this repository, the main one first.
        std::vector<WorktreeInfo> Worktrees() const;
        // Check `_Branch` out into a new working tree at `_Path` (the branch is
        // created from HEAD when it doesn't exist yet).
        void AddWorktree(
            const std::string& _Name, const std::string& _Path, const std::string& _Branch);
        // Delete a linked worktree's folder and bookkeeping. Refuses when the
        // worktree has uncommitted changes (they would be lost).
        void RemoveWorktree(const std::string& _Name);

        // ---- Browsing, shelving, revision graphs ----------------------------------------
        // The entries of directory `_Dir` ("" = root) in `_Revision`'s tree,
        // directories first, then by name. Empty on an unborn branch.
        std::vector<TreeEntry> ListTree(
            const std::string& _Revision, const std::string& _Dir) const;

        // Diff any two versions of a file. Revisions as for ReadFileVersion
        // ("workdir", "index", "head", any commit-ish, "<oid>^"); a missing
        // side diffs as empty (an add or a delete).
        FileDiff DiffVersions(const std::string& _OldPath, const std::string& _OldRevision,
            const std::string& _NewPath, const std::string& _NewRevision,
            const DiffOptions& _Options = {}) const;

        // Which files differ between two revisions (`_NewRevision` may be
        // "workdir": the working tree, untracked files included; `_OldRevision`
        // may be "" for nothing), limited to paths under `_Prefix` ("" = all).
        // Renames detected.
        std::vector<ChangedFile> ChangedFiles(const std::string& _OldRevision,
            const std::string& _NewRevision, const std::string& _Prefix = "") const;

        // Shelve: commit the working-tree versions of `_Paths` (deleted files
        // stay deleted) on top of HEAD, WITHOUT touching HEAD, the index, or the
        // working tree, and point local branch `_Branch` at that commit
        // (created, or moved if it exists). Returns the commit id.
        std::string Shelve(const std::string& _Branch, const std::vector<std::string>& _Paths,
            const std::string& _Message);

        // Unshelve: bring `_Revision`'s changes (vs its first parent) to
        // `_Paths` ("" / empty = every file it changed) into the working tree.
        // Files without local edits take the shelved version; edited ones get a
        // three-way merge (conflict markers where both changed the same lines).
        // Deleted files go through `_RemoveFile` (e.g. the recycle bin).
        UnshelveResult Unshelve(const std::string& _Revision,
            const std::vector<std::string>& _Paths,
            const std::function<bool(const std::string&)>& _RemoveFile = nullptr);

        // The history of `_Path` across branches (see RevisionGraph).
        RevisionGraph FileRevisionGraph(
            const std::string& _Path, const RevisionGraphQuery& _Query = {}) const;

        // ---- Git LFS -------------------------------------------------------------------
        // True when git-lfs was found at startup: files marked `filter=lfs` in
        // .gitattributes are then cleaned/smudged through it like the git CLI does.
        static bool LfsAvailable();

        // ---- Network — these BLOCK; call from a worker thread ------------------
        void SetCredentialProvider(CredentialProvider _Provider);
        void SetHostKeyProvider(HostKeyProvider _Provider);
        void Fetch(const std::string& _RemoteName);
        // Fetch every remote. Tries them all; throws afterwards naming the
        // ones that failed. Returns the names fetched.
        std::vector<std::string> FetchAll();
        // Push the current branch. It goes to its upstream branch when that
        // lives on `_RemoteName`, else to a branch of the same name. Upstream is
        // set on the first push, or always with `_bSetUpstream`. `_bForce`
        // overwrites the remote branch (after amend/rebase).
        void Push(const std::string& _RemoteName, bool _bForce = false, bool _bSetUpstream = false);
        // Push every local tag.
        void PushTags(const std::string& _RemoteName);
        // Push local branch `_Branch` (checked out or not) to `_RemoteBranch`
        // on the remote ("" = the same name). No upstream is set: this is for
        // publishing branches you don't work on, like shelves. `_bForce`
        // replaces the remote branch (a re-shelved changelist).
        void PushBranch(const std::string& _RemoteName, const std::string& _Branch,
            const std::string& _RemoteBranch = "", bool _bForce = false);
        // Delete `_Branch` on the remote.
        void DeleteRemoteBranch(const std::string& _RemoteName, const std::string& _Branch);
        // Fetch `_RemoteName` and merge the current branch's upstream when it
        // lives there, else <remote>/<branch>.
        MergeResult Pull(const std::string& _RemoteName);
        static Repository Clone(const std::string& _Url, const std::string& _Path,
            CredentialProvider _Provider = nullptr, HostKeyProvider _HostKeys = nullptr);

        // Ahead/behind counts of the current branch vs its upstream.
        AheadBehind GetAheadBehind() const;

        bool IsOpen() const
        {
            return m_pRepo != nullptr;
        }

        const std::string& Path() const
        {
            return m_Path;
        }

        // Canonical working-tree root (forward slashes, no trailing slash);
        // falls back to Path() for bare repositories.
        std::string WorkDir() const;

      private:
        git_repository* m_pRepo = nullptr;
        std::string m_Path;
        CredentialProvider m_CredProvider;
        HostKeyProvider m_HostKeyProvider;

        // Shared merge machinery: merge the commit `refName` points at into HEAD.
        MergeResult MergeRef(const std::string& _RefName, const std::string& _Label);

        void Close();
    };

} // namespace gitgud::git
