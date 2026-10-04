#pragma once

// -----------------------------------------------------------------------------
// P4Workspace: the Perforce backend behind git::Repository.
//
// A folder is a P4 workspace for GitGud when its root holds a `.p4config`
// naming the server, user and workspace (client). git::Repository::Open finds
// that file and forwards every call here, so the Lua API, worker jobs, and
// both interfaces work unchanged. Docs: docs/P4.md.
//
// How Git ideas map (see docs/P4.md for the full table):
//   * staged       = opened in a changelist (p4 edit/add/delete, via reconcile)
//   * unstaged     = changed on disk but not opened (what p4 status reports)
//   * commit       = submit (there are no local commits; push has nothing to do)
//   * pull         = get latest (p4 sync, then an automatic safe resolve)
//   * commit ids   = changelist numbers ("123"); "head" = what you have synced
//   * branches     = streams; in a classic depot, sibling folders under a
//                    branch root (GITGUD_BRANCHROOT in .p4config)
//   * tags         = labels;  stash = shelved changelists
//   * worktrees    = your other workspaces of the same stream depot
// What has no Perforce counterpart throws GitError with a plain explanation
// (line staging, amend, reflog, interactive rebase, submodules); the UI asks
// Repository::Supports() first and hides those commands.
// -----------------------------------------------------------------------------

#include "git/Repository.h"
#include "p4/P4Command.h"

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace gitgud::p4
{

    // What a new workspace connects to and maps. Used for both "clone"
    // (an existing stream or depot path) and "new repository" (a stream that
    // doesn't exist yet: m_bCreate).
    struct WorkspaceSetup
    {
        std::string m_Port;
        std::string m_User;
        std::string m_Password; // optional: logs in first when set
        std::string m_Charset;  // "" = auto (utf8 for unicode servers)
        std::string m_Client;   // workspace name; "" = <user>-<host>-<folder>
        std::string m_Root;     // local folder

        // Streams: the stream to work in ("//proj/main"). Classic depots:
        // leave empty and set m_DepotPath ("//depot/proj/main").
        std::string m_Stream;
        std::string m_DepotPath;
        // Classic depots: the folder whose subfolders are branches
        // ("//depot/proj"); "" = the parent of m_DepotPath.
        std::string m_BranchRoot;

        // Create the stream (and its stream depot, which needs admin rights)
        // when it doesn't exist yet: a brand-new repository.
        bool m_bCreate = false;
        bool m_bSync = true; // get the files after creating the workspace
    };

    // One stream, depot, or workspace as the setup dialogs list them.
    struct StreamInfo
    {
        std::string m_Stream; // "//proj/main"
        std::string m_Name;   // "main"
        std::string m_Parent; // "//proj/main" or "none"
        std::string m_Type;   // mainline, development, release, task, virtual
    };

    struct DepotInfo
    {
        std::string m_Name; // "proj"
        std::string m_Type; // local, stream, ...
    };

    struct WorkspaceInfo
    {
        std::string m_Name;
        std::string m_Root;
        std::string m_Stream; // "" for classic views
        std::string m_Host;
    };

    // ---- Changelists (the Depot interface on a Perforce workspace) -------------

    struct OpenedFile
    {
        std::string m_Path;      // workspace-relative
        std::string m_DepotFile; // //depot/...
        std::string m_Action;    // edit, add, delete, branch, integrate, move/add, move/delete
        std::string m_Type;      // text, binary+l, ...
        int m_iRev = 0;          // revision it was opened at (0 for adds)
        bool m_bUnresolved = false;
        bool m_bLocked = false;
    };

    struct ShelvedFile
    {
        std::string m_Path;
        std::string m_DepotFile;
        std::string m_Action;
    };

    struct PendingChange
    {
        std::string m_Change; // "default" or the number
        std::string m_Description;
        std::string m_User;
        std::int64_t m_TimeUtc = 0;
        std::vector<OpenedFile> m_Files;
        std::vector<ShelvedFile> m_Shelved;
    };

    // Per-file server state for the depot/workspace trees (fstat).
    struct FileState
    {
        std::string m_Path;
        std::string m_DepotFile;
        int m_iHaveRev = 0; // 0 = not synced
        int m_iHeadRev = 0;
        std::string m_HeadAction;
        std::string m_HeadType;
        std::string m_OpenAction;             // ours ("" = not opened)
        std::string m_OpenChange;             // ours
        std::vector<std::string> m_OtherOpen; // "user@client" of others who opened it
        bool m_bOtherLock = false;
    };

    class P4Workspace
    {
      public:
        // ---- finding / creating workspaces ------------------------------------
        // Does `_Path` hold a GitGud P4 workspace (.p4config with P4CLIENT)?
        static bool IsWorkspace(const std::string& _Path);
        static std::unique_ptr<P4Workspace> Open(const std::string& _Path);
        // Create the client spec (and the stream with m_bCreate), write
        // .p4config, and sync. BLOCKS on the server.
        static std::unique_ptr<P4Workspace> Create(
            const WorkspaceSetup& _Setup, const PasswordProvider& _Passwords = nullptr);

        // Server queries for the setup dialogs (no workspace needed).
        static std::vector<StreamInfo> ListStreams(
            const Connection& _Conn, const PasswordProvider& _Passwords = nullptr);
        static std::vector<DepotInfo> ListDepots(
            const Connection& _Conn, const PasswordProvider& _Passwords = nullptr);
        static std::vector<WorkspaceInfo> ListWorkspaces(
            const Connection& _Conn, const PasswordProvider& _Passwords = nullptr);

        // Used when no credential provider is set on a workspace (the UI
        // thread's repository). The app sets it once at startup.
        static void SetDefaultPasswordProvider(PasswordProvider _Provider);
        // A Git-style credential provider answering for Perforce: it is
        // asked for the URL "p4:<P4PORT>" (also the credential-store key).
        static PasswordProvider FromCredentialProvider(const git::CredentialProvider& _Provider);

        // ---- the Repository API, one-to-one ---------------------------------------
        std::vector<git::StatusEntry> Status() const;
        void Stage(const std::vector<std::string>& _Paths);
        void Unstage(const std::vector<std::string>& _Paths);
        std::vector<std::size_t> StagedLines(const std::string& _Path) const;
        void SetStagedLines(const std::string& _Path, const std::vector<std::size_t>& _Lines,
            std::size_t _ExpectedLineCount);
        void DiscardLines(const std::string& _Path, const std::vector<std::size_t>& _Lines,
            std::size_t _ExpectedLineCount,
            const std::function<bool(const std::string&)>& _RemoveFile);
        void DiscardChanges(const std::vector<std::string>& _Paths,
            const std::function<bool(const std::string&)>& _RemoveFile);
        void AddToGitignore(const std::string& _Pattern);
        bool ReadFileVersion(
            const std::string& _Path, const std::string& _Revision, std::string& _Out) const;
        std::string Commit(const std::string& _Message);
        std::string AmendCommit(const std::string& _Message);
        std::string UndoLastCommit();
        git::FileDiff DiffFile(const std::string& _Path, git::DiffTarget _Target,
            const git::DiffOptions& _Options) const;
        void StageHunk(const std::string& _Path, std::size_t _HunkIndex);
        void UnstageHunk(const std::string& _Path, std::size_t _HunkIndex);

        std::vector<git::BranchInfo> Branches() const;
        std::string CurrentBranch() const;
        void CreateBranch(const std::string& _Name, const std::string& _StartPoint);
        void Checkout(const std::string& _Name);
        void CheckoutCommit(const std::string& _Oid);
        void DeleteBranch(const std::string& _Name);
        void RenameBranch(const std::string& _OldName, const std::string& _NewName);

        std::vector<git::CommitInfo> Log(const git::LogQuery& _Query) const;
        std::vector<git::FileDiff> DiffCommit(
            const std::string& _Oid, const git::DiffOptions& _Options) const;
        std::vector<git::RefLabel> RefLabels() const;
        git::AheadBehind CompareWith(const std::string& _Ref) const;
        std::string Revert(const std::string& _Oid);
        std::string CherryPick(const std::string& _Oid);
        void ResetTo(const std::string& _Oid, git::ResetMode _Mode);

        std::vector<git::TagInfo> Tags() const;
        void CreateTag(
            const std::string& _Name, const std::string& _Target, const std::string& _Message);
        void DeleteTag(const std::string& _Name);

        git::RepoState State() const;
        void ResolveConflict(const std::string& _Path, bool _bOurs);
        void AbortOperation();

        std::string GetConfig(const std::string& _Key) const;
        void SetConfig(const std::string& _Key, const std::string& _Value);

        std::vector<git::RemoteInfo> Remotes() const;
        void AddRemote(const std::string& _Name, const std::string& _Url);
        void RemoveRemote(const std::string& _Name);
        void SetRemoteUrl(const std::string& _Name, const std::string& _Url);
        void RenameRemote(const std::string& _Name, const std::string& _NewName);
        void SetUpstream(const std::string& _Branch, const std::string& _Upstream);

        std::vector<git::StashInfo> StashList() const;
        void StashSave(const std::string& _Message);
        void StashApply(std::size_t _Index);
        void StashPop(std::size_t _Index);
        void StashDrop(std::size_t _Index);
        std::vector<git::FileDiff> StashDiff(std::size_t _Index) const;

        git::MergeResult Merge(const std::string& _BranchName);
        git::MergeResult SquashMerge(const std::string& _BranchName);
        std::vector<std::string> ConflictedPaths() const;
        void AbortMerge();
        git::RebaseResult Rebase(const std::string& _Upstream);
        git::RebaseResult ContinueRebase();

        std::vector<git::CommitInfo> GraphLog(const git::GraphQuery& _Query) const;
        std::string HeadOid() const;
        std::vector<git::ReflogEntry> Reflog(const std::string& _Ref, std::size_t _MaxCount) const;
        void SetBranchTarget(const std::string& _Name, const std::string& _Oid);
        git::ConflictFile ReadConflict(const std::string& _Path) const;
        std::vector<git::CommitInfo> RebaseTodo(const std::string& _Base) const;
        git::RebaseResult InteractiveRebase(
            const std::string& _Base, const std::vector<git::RebaseStep>& _Steps);
        std::vector<git::CommitInfo> FileLog(const std::string& _Path, std::size_t _MaxCount) const;
        git::BlameResult Blame(const std::string& _Path, const std::string& _Revision) const;

        std::vector<git::SubmoduleInfo> Submodules() const;
        void UpdateSubmodule(const std::string& _Name, bool _bInit);
        std::vector<git::WorktreeInfo> Worktrees() const;
        void AddWorktree(
            const std::string& _Name, const std::string& _Path, const std::string& _Branch);
        void RemoveWorktree(const std::string& _Name);

        std::vector<git::TreeEntry> ListTree(
            const std::string& _Revision, const std::string& _Dir) const;
        git::FileDiff DiffVersions(const std::string& _OldPath, const std::string& _OldRevision,
            const std::string& _NewPath, const std::string& _NewRevision,
            const git::DiffOptions& _Options) const;
        std::vector<git::ChangedFile> ChangedFiles(const std::string& _OldRevision,
            const std::string& _NewRevision, const std::string& _Prefix) const;
        std::string Shelve(const std::string& _Branch, const std::vector<std::string>& _Paths,
            const std::string& _Message);
        git::UnshelveResult Unshelve(const std::string& _Revision,
            const std::vector<std::string>& _Paths,
            const std::function<bool(const std::string&)>& _RemoveFile);
        git::RevisionGraph FileRevisionGraph(
            const std::string& _Path, const git::RevisionGraphQuery& _Query) const;

        void SetPasswordProvider(PasswordProvider _Provider);
        void Fetch(const std::string& _RemoteName);
        std::vector<std::string> FetchAll();
        void Push(const std::string& _RemoteName, bool _bForce, bool _bSetUpstream);
        void PushTags(const std::string& _RemoteName);
        void PushBranch(const std::string& _RemoteName, const std::string& _Branch,
            const std::string& _RemoteBranch, bool _bForce);
        void DeleteRemoteBranch(const std::string& _RemoteName, const std::string& _Branch);
        git::MergeResult Pull(const std::string& _RemoteName);
        git::AheadBehind GetAheadBehind() const;

        // ---- changelists (P4WorkspaceChanges.cpp) ------------------------------
        // The default changelist first, then this workspace's numbered
        // pending changelists (oldest first), each with its open and shelved files.
        std::vector<PendingChange> PendingChanges() const;
        // A new numbered changelist; `_Paths` (open files) move into it.
        std::string CreateChange(
            const std::string& _Description, const std::vector<std::string>& _Paths);
        void SetChangeDescription(const std::string& _Change, const std::string& _Description);
        // Deletes an empty changelist (its shelf must be deleted first).
        void DeleteChange(const std::string& _Change);
        void Reopen(const std::vector<std::string>& _Paths, const std::string& _Change);
        // Check out: open for edit (unchanged files too).
        void Edit(const std::vector<std::string>& _Paths, const std::string& _Change);
        // Mark for add / delete (delete removes the local file).
        void Add(const std::vector<std::string>& _Paths, const std::string& _Change);
        void Delete(const std::vector<std::string>& _Paths, const std::string& _Change);
        // Rename/move: opens the file for edit if needed, then p4 move.
        void Move(const std::string& _From, const std::string& _To, const std::string& _Change);
        // Revert open files; `_bKeepLocal` keeps the workspace files as they are.
        void RevertFiles(const std::vector<std::string>& _Paths, bool _bKeepLocal);
        // Revert open files that are unchanged ("" = every changelist). Returns them.
        std::vector<std::string> RevertUnchanged(const std::string& _Change);
        // Submit `_Change` with `_Description`. When `_Paths` is not empty,
        // only those files go; the rest move to a new pending changelist (or
        // stay in the default one). Returns the submitted change number.
        std::string SubmitPending(const std::string& _Change, const std::string& _Description,
            const std::vector<std::string>& _Paths);
        // Shelve `_Change` (default: into a new numbered changelist). Returns the
        // changelist that holds the shelf. `_bRevert` reverts the files afterwards.
        std::string ShelveChange(
            const std::string& _Change, const std::vector<std::string>& _Paths, bool _bRevert);
        // Unshelve `_From`'s shelved files into `_To` ("default" or a number).
        git::UnshelveResult UnshelveChange(const std::string& _From, const std::string& _To,
            const std::vector<std::string>& _Paths);
        void DeleteShelf(const std::string& _Change, const std::vector<std::string>& _Paths);
        // Shelved changelists on the server: this workspace's, or everyone's
        // (`_bAllUsers`), newest first. m_Files is left empty; see ShelvedFiles.
        std::vector<PendingChange> ListShelves(bool _bAllUsers) const;
        std::vector<ShelvedFile> ShelvedFiles(const std::string& _Change) const;
        // Get revision: sync `_Paths` ("" = everything) to `_Revision`
        // ("" = latest, a change number, "#n", or "none" to remove).
        std::vector<std::string> SyncPaths(
            const std::vector<std::string>& _Paths, const std::string& _Revision);
        // Server state of the files directly in `_Dir` ("" = root), or of
        // every file below it with `_bRecursive`.
        std::vector<FileState> FileStates(const std::string& _Dir, bool _bRecursive) const;
        // Lock / unlock open files.
        void Lock(const std::vector<std::string>& _Paths, bool _bLock);
        // The user's info line and the server version (`p4 info`).
        Record Info() const;

        std::string WorkDir() const
        {
            return m_Root;
        }

        const Connection& Conn() const
        {
            return m_Conn;
        }

        // Streams vs. folder branches.
        bool UsesStreams() const
        {
            return !m_Stream.empty();
        }

        // Exposed for tests and the setup flow.
        static void WriteConfigFile(
            const std::string& _Root, const std::map<std::string, std::string>& _Values);
        static std::map<std::string, std::string> ReadConfigFile(const std::string& _Root);

      private:
        Connection m_Conn;
        std::string m_Root;                          // forward slashes, no trailing slash
        std::string m_Stream;                        // "//proj/main" ("" in a classic workspace)
        std::string m_BranchRoot;                    // classic: "//depot/proj"
        std::map<std::string, std::string> m_Config; // .p4config contents
        PasswordProvider m_Passwords;
        // Client view lines "<depot> <client>" (with -/+ prefixes kept).
        std::vector<std::pair<std::string, std::string>> m_View;

        // ---- plumbing (P4Workspace.cpp) ----
        CommandResult Run(const std::vector<std::string>& _Args, const Record& _Input = {}) const;
        CommandResult RunOrThrow(
            const std::vector<std::string>& _Args, const Record& _Input = {}) const;
        void LoadClient(); // reads the client spec: stream, view
        void SaveConfig();
        // Workspace-relative "src/a.txt" -> escaped absolute local path.
        std::string LocalArg(const std::string& _Path) const;
        // Everything in the workspace ("<root>/...").
        std::string AllFiles() const;
        // "//client/src/a.txt" or "C:\...\src\a.txt" -> "src/a.txt" ("" when outside).
        std::string RelativeFromClientOrLocal(const std::string& _Path) const;
        // Depot path -> workspace-relative path through the client view
        // (and, for streams, any stream of the same depot). "" when unmapped.
        std::string RelativeFromDepot(const std::string& _DepotPath) const;
        // Workspace-relative path -> depot path in the current view.
        std::string DepotFromRelative(const std::string& _Path) const;
        // A depot path's "//depot/stream" prefix in a stream depot ("" otherwise).
        std::string StreamOf(const std::string& _DepotPath) const;
        // Revision spec ("head", "123", "123^", a branch) -> p4 suffix ("#have", "@123", ...).
        std::string RevisionSuffix(const std::string& _Revision) const;
        // A branch name or stream path -> "//proj/name" (streams) or the folder path.
        std::string BranchPath(const std::string& _Name) const;
        std::string BranchNameOf(const std::string& _Path) const;
        // Content of a depot file revision ("//a/b.txt@12"); false when missing.
        bool PrintFile(
            const std::string& _FileSpec, std::string& _Out, bool* _pBinary = nullptr) const;
        std::string ReadWorkFile(const std::string& _Path, bool& _bExists) const;
        git::CommitInfo CommitFromChange(const Record& _Change) const;
        // Submit the default changelist (or `_Change`) with `_Message`.
        std::string SubmitDefault(const std::string& _Message);
        std::string SubmitChange(const std::string& _Change);
        // Create a numbered pending changelist holding `_DepotOrLocalFiles`.
        std::string NewChange(
            const std::string& _Description, const std::vector<std::string>& _Files);
        std::vector<Record> Opened(const std::string& _Change = "") const;
        std::vector<Record> PendingResolves() const;
        std::string UserEmail() const;
        // Throws when files are open: stream and folder switches need a clean workspace.
        void RequireNothingOpen(const std::string& _What) const;
        void SwitchTo(const std::string& _BranchPath);
        // Runs `p4 resolve -am` and returns the files still needing a resolve.
        std::vector<std::string> AutoResolve();
        git::MergeResult IntegrateFrom(
            const std::string& _FromPath, const std::string& _Label, bool _bSubmit);
        std::vector<Record> ShelvedChanges() const;
        std::string ShelfAt(std::size_t _Index) const;
        void Unsupported(const std::string& _What) const;

        friend class P4WorkspaceAccess;
    };

} // namespace gitgud::p4
