// -----------------------------------------------------------------------------
// P4Workspace: branches (streams, or folders under a branch root), labels
// as tags, merging between branches (integrate + resolve, submitted as one
// changelist), undo and cherry-pick, shelved changelists as the stash, and
// the user's other workspaces as worktrees.
//
// A merge, revert, or cherry-pick that stops on conflicts leaves its files
// in a numbered changelist recorded as GITGUD_MERGE_CHANGE in .p4config;
// Commit()/ContinueRebase() submit that changelist once everything is
// resolved, and AbortMerge() reverts and deletes it.
// -----------------------------------------------------------------------------

#include "p4/P4Workspace.h"

#include "p4/P4Internal.h"

#include <algorithm>
#include <filesystem>
#include <set>

namespace gitgud::p4
{

    using git::GitError;
    using namespace internal;

    namespace
    {
        namespace fs = std::filesystem;

        bool AllDigits(const std::string& _Text)
        {
            return !_Text.empty() &&
                   std::all_of(_Text.begin(), _Text.end(),
                       [](char _c) { return std::isdigit(static_cast<unsigned char>(_c)) != 0; });
        }

        bool MentionsAlreadyIntegrated(const CommandResult& _Result)
        {
            std::vector<std::string> lines = _Result.m_Warnings;
            lines.insert(lines.end(), _Result.m_Info.begin(), _Result.m_Info.end());
            lines.insert(lines.end(), _Result.m_Errors.begin(), _Result.m_Errors.end());
            for (const std::string& l : lines)
            {
                if (l.find("already integrated") != std::string::npos ||
                    l.find("no such file") != std::string::npos ||
                    l.find("No file(s) to") != std::string::npos ||
                    l.find("no file(s) to") != std::string::npos)
                {
                    return true;
                }
            }
            return false;
        }

    } // namespace

    // ---- names -----------------------------------------------------------------------

    std::string P4Workspace::BranchPath(const std::string& _Name) const
    {
        if (_Name.rfind("//", 0) == 0)
        {
            std::string path = _Name;
            while (!path.empty() && (path.back() == '/' || path.back() == '.'))
            {
                path.pop_back();
            }
            return path;
        }
        if (UsesStreams())
        {
            return m_Stream.substr(0, m_Stream.rfind('/')) + "/" + _Name;
        }
        if (m_BranchRoot.empty())
        {
            throw GitError("This workspace has no branch root: set GITGUD_BRANCHROOT in .p4config");
        }
        return m_BranchRoot + "/" + _Name;
    }

    std::string P4Workspace::BranchNameOf(const std::string& _Path) const
    {
        const std::string parent =
            UsesStreams() ? m_Stream.substr(0, m_Stream.rfind('/')) : m_BranchRoot;
        if (!parent.empty() && StartsWithNoCase(_Path, parent + "/") &&
            _Path.find('/', parent.size() + 1) == std::string::npos)
        {
            return _Path.substr(parent.size() + 1);
        }
        return _Path;
    }

    // ---- branches ----------------------------------------------------------------------

    std::string P4Workspace::CurrentBranch() const
    {
        if (UsesStreams())
        {
            return BranchNameOf(m_Stream);
        }
        for (const auto& [lhs, rhs] : m_View)
        {
            if (!m_BranchRoot.empty() && StartsWithNoCase(lhs, m_BranchRoot + "/"))
            {
                const std::size_t nend = lhs.find('/', m_BranchRoot.size() + 1);
                return lhs.substr(m_BranchRoot.size() + 1,
                    nend == std::string::npos ? std::string::npos : nend - m_BranchRoot.size() - 1);
            }
        }
        return m_Conn.m_Client;
    }

    std::vector<git::BranchInfo> P4Workspace::Branches() const
    {
        std::vector<git::BranchInfo> out;
        std::vector<std::pair<std::string, std::string>> paths; // path, parent path
        if (UsesStreams())
        {
            const std::string depot = m_Stream.substr(0, m_Stream.rfind('/'));
            for (const Record& s : RunOrThrow({"streams", depot + "/*"}).m_Stats)
            {
                if (Field(s, "Type") == "virtual")
                {
                    continue; // nothing is ever submitted to a virtual stream
                }
                paths.emplace_back(Field(s, "Stream"), Field(s, "Parent"));
            }
        }
        else if (!m_BranchRoot.empty())
        {
            for (const Record& d : Run({"dirs", m_BranchRoot + "/*"}).m_Stats)
            {
                paths.emplace_back(Field(d, "dir"), std::string());
            }
        }
        else
        {
            paths.emplace_back("//" + m_Conn.m_Client, std::string());
        }
        const std::string current = CurrentBranch();
        for (const auto& [path, parent] : paths)
        {
            git::BranchInfo b;
            b.m_Name = BranchNameOf(path);
            b.m_bIsHead = b.m_Name == current;
            b.m_Upstream =
                parent.empty() || parent == "none" ? std::string() : BranchNameOf(parent);
            const CommandResult tip = Run({"changes", "-m", "1", "-s", "submitted", path + "/..."});
            if (!tip.m_Stats.empty())
            {
                b.m_TargetOid = Field(tip.m_Stats.front(), "change");
                b.m_TimeUtc = ToInt64(Field(tip.m_Stats.front(), "time"));
            }
            out.push_back(std::move(b));
        }
        return out;
    }

    void P4Workspace::CreateBranch(const std::string& _Name, const std::string& _StartPoint)
    {
        const std::string path = BranchPath(_Name);
        std::string from = UsesStreams() ? m_Stream : BranchPath(CurrentBranch());
        std::string at;
        if (!_StartPoint.empty() && _StartPoint != "HEAD" && _StartPoint != "head")
        {
            if (AllDigits(_StartPoint) ||
                (_StartPoint[0] == '@' && AllDigits(_StartPoint.substr(1))))
            {
                at = "@" + (AllDigits(_StartPoint) ? _StartPoint : _StartPoint.substr(1));
            }
            else
            {
                from = BranchPath(_StartPoint);
            }
        }
        else
        {
            const std::string have = HeadOid();
            if (!have.empty())
            {
                at = "@" + have;
            }
        }

        if (UsesStreams())
        {
            CommandResult tmpl =
                RunOrThrow({"stream", "-o", "-t", "development", "-P", from, path});
            if (tmpl.m_Stats.empty())
            {
                throw GitError("Could not prepare stream " + path);
            }
            if (!Field(tmpl.m_Stats.front(), "Update").empty())
            {
                throw GitError("Branch '" + _Name + "' already exists");
            }
            Record spec = SpecForInput(tmpl.m_Stats.front());
            spec["Description"] = "Created by GitGud.\n";
            RunOrThrow({"stream", "-i"}, spec);
        }
        // Copy the files on the server (no workspace needed).
        const CommandResult pop = Run({"populate", "-d",
            "Branch " + _Name + " from " + BranchNameOf(from), from + "/..." + at, path + "/..."});
        if (!pop.Ok() && !MentionsAlreadyIntegrated(pop))
        {
            throw GitError(pop.Message());
        }
    }

    void P4Workspace::SwitchTo(const std::string& _BranchPath)
    {
        RequireNothingOpen("Switching branches");
        for (const Record& s : Run({"status", AllFiles()}).m_Stats)
        {
            if (Field(s, "action") != "add")
            {
                throw GitError("Switching branches needs your edits opened or discarded first: '" +
                               ToSlashes(Field(s, "localFile")) + "' is changed");
            }
        }
        if (UsesStreams())
        {
            RunOrThrow({"client", "-s", "-S", _BranchPath});
        }
        else
        {
            const std::string current = BranchPath(CurrentBranch());
            CommandResult tmpl = RunOrThrow({"client", "-o", m_Conn.m_Client});
            Record spec = SpecForInput(tmpl.m_Stats.front());
            for (auto& [key, value] : spec)
            {
                if (key.rfind("View", 0) != 0)
                {
                    continue;
                }
                const std::size_t npos = value.find(current + "/");
                if (npos != std::string::npos)
                {
                    value.replace(npos, current.size(), _BranchPath);
                }
            }
            RunOrThrow({"client", "-i"}, spec);
        }
        LoadClient();
        const CommandResult sync = Run({"sync", "-q"});
        if (!sync.Ok())
        {
            throw GitError(sync.Message());
        }
    }

    void P4Workspace::Checkout(const std::string& _Name)
    {
        SwitchTo(BranchPath(_Name));
    }

    void P4Workspace::CheckoutCommit(const std::string& _Oid)
    {
        const CommandResult r =
            Run({"sync", "//" + m_Conn.m_Client + "/..." + RevisionSuffix(_Oid)});
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        for (const std::string& w : r.m_Warnings)
        {
            if (w.find("can't update modified file") != std::string::npos)
            {
                throw GitError("Some files you changed were left as they are:\n" + w);
            }
        }
    }

    void P4Workspace::DeleteBranch(const std::string& _Name)
    {
        if (_Name == CurrentBranch())
        {
            throw GitError("Switch to another branch before deleting '" + _Name + "'");
        }
        if (!UsesStreams())
        {
            Unsupported(
                "Deleting a branch folder (delete its files from a workspace that maps it)");
        }
        RunOrThrow({"stream", "-d", BranchPath(_Name)});
    }

    void P4Workspace::RenameBranch(const std::string&, const std::string&)
    {
        Unsupported("Renaming a stream");
    }

    std::vector<git::RefLabel> P4Workspace::RefLabels() const
    {
        std::vector<git::RefLabel> out;
        for (const git::BranchInfo& b : Branches())
        {
            if (!b.m_TargetOid.empty())
            {
                out.push_back({b.m_TargetOid, b.m_Name, 'b'});
            }
        }
        for (const git::TagInfo& t : Tags())
        {
            if (!t.m_TargetOid.empty())
            {
                out.push_back({t.m_TargetOid, t.m_Name, 't'});
            }
        }
        return out;
    }

    git::AheadBehind P4Workspace::CompareWith(const std::string& _Ref) const
    {
        git::AheadBehind ab;
        const std::string ours = (UsesStreams() ? m_Stream : BranchPath(CurrentBranch())) + "/...";
        const std::string theirs = BranchPath(_Ref) + "/...";
        ab.m_bHasUpstream = true;
        ab.m_Upstream = _Ref;
        ab.m_Ahead = Run({"interchanges", ours, theirs}).m_Stats.size();
        ab.m_Behind = Run({"interchanges", theirs, ours}).m_Stats.size();
        return ab;
    }

    // ---- merging -------------------------------------------------------------------------

    git::MergeResult P4Workspace::IntegrateFrom(
        const std::string& _FromPath, const std::string& _Label, bool _bSubmit)
    {
        git::MergeResult result;
        if (!m_Config["GITGUD_MERGE_CHANGE"].empty())
        {
            throw GitError("A merge is already in progress: resolve and commit it, or abort it");
        }
        const std::string change = NewChange(_Label, {});
        const std::string target = "//" + m_Conn.m_Client + "/...";
        // Streams: merge against the usual flow too (-F), since git merges
        // in any direction. Classic depots: integrate the folder into ours.
        CommandResult r = UsesStreams()
                              ? Run({"merge", "-F", "-c", change, "--from", _FromPath})
                              : Run({"integrate", "-c", change, _FromPath + "/...", target});
        if (UsesStreams() && !r.Ok() && !MentionsAlreadyIntegrated(r))
        {
            r = Run({"integrate", "-c", change, _FromPath + "/...", target});
        }
        if (Opened(change).empty())
        {
            Run({"change", "-d", change});
            if (!r.Ok() && !MentionsAlreadyIntegrated(r))
            {
                throw GitError(r.Message());
            }
            result.m_Kind = git::MergeResult::Kind::UpToDate;
            result.m_Message = "Already up to date";
            return result;
        }
        m_Config["GITGUD_MERGE_CHANGE"] = change;
        SaveConfig();
        result.m_ConflictedPaths = AutoResolve();
        if (!result.m_ConflictedPaths.empty())
        {
            result.m_Kind = git::MergeResult::Kind::Conflicts;
            result.m_Message =
                std::to_string(result.m_ConflictedPaths.size()) + " file(s) need resolving";
            return result;
        }
        if (_bSubmit)
        {
            const std::string submitted = SubmitChange(change);
            m_Config.erase("GITGUD_MERGE_CHANGE");
            SaveConfig();
            result.m_Message = "Merged in change " + submitted;
        }
        result.m_Kind = git::MergeResult::Kind::Merged;
        return result;
    }

    git::MergeResult P4Workspace::Merge(const std::string& _BranchName)
    {
        return IntegrateFrom(
            BranchPath(_BranchName), "Merge " + _BranchName + " into " + CurrentBranch(), true);
    }

    git::MergeResult P4Workspace::SquashMerge(const std::string& _BranchName)
    {
        // A Perforce merge is always one changelist.
        return Merge(_BranchName);
    }

    git::RebaseResult P4Workspace::Rebase(const std::string& _Upstream)
    {
        // The nearest Perforce idea: merge the upstream's changes down into
        // this branch, so it is up to date with it.
        const git::MergeResult m = IntegrateFrom(
            BranchPath(_Upstream), "Merge " + _Upstream + " into " + CurrentBranch(), true);
        git::RebaseResult r;
        r.m_Message = m.m_Message;
        r.m_ConflictedPaths = m.m_ConflictedPaths;
        r.m_Kind = m.m_Kind == git::MergeResult::Kind::UpToDate ? git::RebaseResult::Kind::UpToDate
                   : m.m_Kind == git::MergeResult::Kind::Conflicts
                       ? git::RebaseResult::Kind::Conflicts
                       : git::RebaseResult::Kind::Done;
        return r;
    }

    git::RebaseResult P4Workspace::ContinueRebase()
    {
        git::RebaseResult r;
        r.m_ConflictedPaths = ConflictedPaths();
        if (!r.m_ConflictedPaths.empty())
        {
            r.m_Kind = git::RebaseResult::Kind::Conflicts;
            r.m_Message = "Resolve the remaining files first";
            return r;
        }
        const std::string change = m_Config["GITGUD_MERGE_CHANGE"];
        if (change.empty())
        {
            r.m_Kind = git::RebaseResult::Kind::UpToDate;
            return r;
        }
        const std::string submitted = SubmitChange(change);
        m_Config.erase("GITGUD_MERGE_CHANGE");
        SaveConfig();
        r.m_Kind = git::RebaseResult::Kind::Done;
        r.m_Message = "Submitted change " + submitted;
        return r;
    }

    git::RepoState P4Workspace::State() const
    {
        const auto it = m_Config.find("GITGUD_MERGE_CHANGE");
        if (it != m_Config.end() && !it->second.empty())
        {
            return git::RepoState::Merge;
        }
        return PendingResolves().empty() ? git::RepoState::None : git::RepoState::Merge;
    }

    void P4Workspace::ResolveConflict(const std::string& _Path, bool _bOurs)
    {
        RunOrThrow({"resolve", _bOurs ? "-ay" : "-at", LocalArg(_Path)});
    }

    void P4Workspace::AbortMerge()
    {
        const std::string change = m_Config["GITGUD_MERGE_CHANGE"];
        if (change.empty())
        {
            return;
        }
        Run({"revert", "-w", "-c", change, "//" + m_Conn.m_Client + "/..."});
        Run({"change", "-d", change});
        m_Config.erase("GITGUD_MERGE_CHANGE");
        SaveConfig();
    }

    void P4Workspace::AbortOperation()
    {
        AbortMerge();
    }

    std::string P4Workspace::Revert(const std::string& _Oid)
    {
        if (!m_Config["GITGUD_MERGE_CHANGE"].empty())
        {
            throw GitError("Finish or abort the merge in progress first");
        }
        const std::string change = NewChange("Undo change " + _Oid, {});
        const CommandResult r =
            Run({"undo", "-c", change, "//" + m_Conn.m_Client + "/...@=" + _Oid});
        if (Opened(change).empty())
        {
            Run({"change", "-d", change});
            throw GitError(
                r.Ok() ? "Change " + _Oid + " changed nothing in this workspace" : r.Message());
        }
        if (!AutoResolve().empty())
        {
            m_Config["GITGUD_MERGE_CHANGE"] = change;
            SaveConfig();
            return {};
        }
        return SubmitChange(change);
    }

    std::string P4Workspace::CherryPick(const std::string& _Oid)
    {
        if (!m_Config["GITGUD_MERGE_CHANGE"].empty())
        {
            throw GitError("Finish or abort the merge in progress first");
        }
        const CommandResult d = RunOrThrow({"describe", "-s", _Oid});
        if (d.m_Stats.empty())
        {
            throw GitError("Change " + _Oid + " doesn't exist");
        }
        const std::string first = Field(d.m_Stats.front(), "depotFile0");
        std::string source = UsesStreams() ? StreamOf(first) : std::string();
        if (!UsesStreams() && !m_BranchRoot.empty() && StartsWithNoCase(first, m_BranchRoot + "/"))
        {
            source = first.substr(0, first.find('/', m_BranchRoot.size() + 1));
        }
        if (source.empty())
        {
            throw GitError("Can't tell which branch change " + _Oid + " belongs to");
        }
        const std::string ours = UsesStreams() ? m_Stream : BranchPath(CurrentBranch());
        if (StartsWithNoCase(source, ours) && source.size() == ours.size())
        {
            throw GitError("Change " + _Oid + " is already on this branch");
        }
        const std::string change = NewChange(Field(d.m_Stats.front(), "desc"), {});
        const CommandResult r =
            Run({"integrate", "-c", change, source + "/...@=" + _Oid, ours + "/..."});
        if (Opened(change).empty())
        {
            Run({"change", "-d", change});
            throw GitError(r.Ok() ? "Change " + _Oid + " is already integrated here" : r.Message());
        }
        if (!AutoResolve().empty())
        {
            m_Config["GITGUD_MERGE_CHANGE"] = change;
            SaveConfig();
            return {};
        }
        return SubmitChange(change);
    }

    void P4Workspace::ResetTo(const std::string&, git::ResetMode)
    {
        Unsupported("Moving a branch back (submitted changes are permanent; use Revert, or get an "
                    "older revision)");
    }

    void P4Workspace::SetBranchTarget(const std::string&, const std::string&)
    {
        Unsupported("Moving a branch to another changelist");
    }

    std::vector<git::CommitInfo> P4Workspace::RebaseTodo(const std::string&) const
    {
        Unsupported("Interactive rebase (submitted changes can't be rewritten)");
        return {};
    }

    git::RebaseResult P4Workspace::InteractiveRebase(
        const std::string&, const std::vector<git::RebaseStep>&)
    {
        Unsupported("Interactive rebase (submitted changes can't be rewritten)");
        return {};
    }

    // ---- labels --------------------------------------------------------------------------

    std::vector<git::TagInfo> P4Workspace::Tags() const
    {
        std::vector<git::TagInfo> out;
        for (const Record& l : Run({"labels"}).m_Stats)
        {
            git::TagInfo t;
            t.m_Name = Field(l, "label");
            t.m_Message = Field(l, "Description");
            while (!t.m_Message.empty() && t.m_Message.back() == '\n')
            {
                t.m_Message.pop_back();
            }
            std::string rev = Field(l, "Revision");
            if (!rev.empty() && rev[0] == '@')
            {
                rev.erase(0, 1);
            }
            if (AllDigits(rev))
            {
                t.m_TargetOid = rev;
            }
            out.push_back(std::move(t));
        }
        return out;
    }

    void P4Workspace::CreateTag(
        const std::string& _Name, const std::string& _Target, const std::string& _Message)
    {
        std::string change = _Target;
        if (change.empty() || change == "HEAD" || change == "head")
        {
            change = HeadOid();
        }
        if (!change.empty() && change[0] == '@')
        {
            change.erase(0, 1);
        }
        if (!AllDigits(change))
        {
            throw GitError("A label needs a changelist number to point at");
        }
        CommandResult tmpl = RunOrThrow({"label", "-o", _Name});
        if (tmpl.m_Stats.empty() || !Field(tmpl.m_Stats.front(), "Update").empty())
        {
            throw GitError("Label '" + _Name + "' already exists");
        }
        Record spec = SpecForInput(tmpl.m_Stats.front());
        spec["Description"] =
            _Message.empty() ? std::string("Created by GitGud.\n") : _Message + "\n";
        spec["Revision"] = "@" + change;
        for (auto it = spec.begin(); it != spec.end();)
        {
            it = it->first.rfind("View", 0) == 0 ? spec.erase(it) : std::next(it);
        }
        // The label covers what this workspace maps (an automatic label: the
        // Revision field pins it, no labelsync needed).
        int i = 0;
        for (const auto& [lhs, rhs] : m_View)
        {
            if (!lhs.empty() && lhs[0] != '-')
            {
                spec["View" + std::to_string(i++)] = lhs[0] == '+' ? lhs.substr(1) : lhs;
            }
        }
        if (UsesStreams() && i == 0)
        {
            spec["View0"] = m_Stream + "/...";
        }
        RunOrThrow({"label", "-i"}, spec);
    }

    void P4Workspace::DeleteTag(const std::string& _Name)
    {
        RunOrThrow({"label", "-d", _Name});
    }

    // ---- shelves as the stash ---------------------------------------------------------------

    std::vector<Record> P4Workspace::ShelvedChanges() const
    {
        return Run({"changes", "-l", "-s", "shelved", "-c", m_Conn.m_Client}).m_Stats;
    }

    std::string P4Workspace::ShelfAt(std::size_t _Index) const
    {
        const std::vector<Record> shelves = ShelvedChanges();
        if (_Index >= shelves.size())
        {
            throw GitError("No stash at index " + std::to_string(_Index));
        }
        return Field(shelves[_Index], "change");
    }

    std::vector<git::StashInfo> P4Workspace::StashList() const
    {
        std::vector<git::StashInfo> out;
        const std::vector<Record> shelves = ShelvedChanges();
        for (std::size_t i = 0; i < shelves.size(); ++i)
        {
            std::string desc = Field(shelves[i], "desc");
            while (!desc.empty() && desc.back() == '\n')
            {
                desc.pop_back();
            }
            out.push_back({i, desc, Field(shelves[i], "change")});
        }
        return out;
    }

    void P4Workspace::StashSave(const std::string& _Message)
    {
        // Open every change (new files too, like git stash -u), shelve the
        // lot in a changelist of its own, then clear them from the workspace.
        Run({"reconcile", AllFiles()});
        std::vector<std::string> files;
        for (const Record& o : Opened("default"))
        {
            if (RelativeFromClientOrLocal(Field(o, "clientFile")) == ".p4config")
            {
                Run({"revert", "-k", LocalArg(".p4config")});
                continue;
            }
            files.push_back(Field(o, "depotFile"));
        }
        if (files.empty())
        {
            throw GitError("No local changes to stash");
        }
        const std::string change =
            NewChange(_Message.empty() ? std::string("Stashed by GitGud") : _Message, files);
        RunOrThrow({"shelve", "-c", change});
        RunOrThrow({"revert", "-w", "-c", change, "//" + m_Conn.m_Client + "/..."});
    }

    void P4Workspace::StashApply(std::size_t _Index)
    {
        const std::string change = ShelfAt(_Index);
        const CommandResult r = Run({"unshelve", "-s", change, "-c", "default"});
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        AutoResolve();
    }

    void P4Workspace::StashDrop(std::size_t _Index)
    {
        const std::string change = ShelfAt(_Index);
        RunOrThrow({"shelve", "-d", "-c", change});
        Run({"revert", "-c", change, "//" + m_Conn.m_Client + "/..."});
        RunOrThrow({"change", "-d", change});
    }

    void P4Workspace::StashPop(std::size_t _Index)
    {
        StashApply(_Index);
        StashDrop(_Index);
    }

    std::vector<git::FileDiff> P4Workspace::StashDiff(std::size_t _Index) const
    {
        const std::string change = ShelfAt(_Index);
        const CommandResult r = RunOrThrow({"describe", "-S", "-s", change});
        std::vector<git::FileDiff> out;
        if (r.m_Stats.empty())
        {
            return out;
        }
        const Record& d = r.m_Stats.front();
        const std::vector<std::string> files = Indexed(d, "depotFile");
        const std::vector<std::string> actions = Indexed(d, "action");
        const std::vector<std::string> revs = Indexed(d, "rev");
        for (std::size_t i = 0; i < files.size(); ++i)
        {
            const std::string action = i < actions.size() ? actions[i] : std::string();
            std::string rel = RelativeFromDepot(files[i]);
            if (rel.empty())
            {
                rel = UnescapePath(files[i].substr(2));
            }
            std::string oldText;
            std::string newText;
            const std::int64_t irev = i < revs.size() ? ToInt64(revs[i]) : 0;
            const bool badd = action == "add" || action == "move/add" || action == "branch";
            const bool bold =
                !badd && irev > 0 && PrintFile(files[i] + "#" + std::to_string(irev), oldText);
            const bool bnew = action != "delete" && action != "move/delete" &&
                              PrintFile(files[i] + "@=" + change, newText);
            out.push_back(git::internal::DiffFileVersions(rel, Version(ToLf(oldText), bold), rel,
                Version(ToLf(newText), bnew), git::DiffOptions()));
        }
        return out;
    }

    std::string P4Workspace::Shelve(
        const std::string&, const std::vector<std::string>& _Paths, const std::string& _Message)
    {
        // A real Perforce shelf: open the files, move them into a new
        // changelist, shelve it. The files stay open, as after `p4 shelve`.
        std::vector<std::string> args = {"reconcile"};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        Run(args);
        std::vector<std::string> depotFiles;
        for (const std::string& p : _Paths)
        {
            const std::string d = DepotFromRelative(p);
            if (!d.empty())
            {
                depotFiles.push_back(d);
            }
        }
        const std::string change = NewChange(_Message, depotFiles);
        RunOrThrow({"shelve", "-c", change});
        return change;
    }

    git::UnshelveResult P4Workspace::Unshelve(const std::string& _Revision,
        const std::vector<std::string>& _Paths, const std::function<bool(const std::string&)>&)
    {
        std::vector<std::string> args = {"unshelve", "-s", _Revision, "-c", "default"};
        for (const std::string& p : _Paths)
        {
            if (!p.empty())
            {
                args.push_back(LocalArg(p));
            }
        }
        const CommandResult r = Run(args);
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        git::UnshelveResult out;
        const std::vector<std::string> conflicted = AutoResolve();
        const std::set<std::string> conflictSet(conflicted.begin(), conflicted.end());
        for (const Record& s : r.m_Stats)
        {
            std::string rel = RelativeFromDepot(Field(s, "depotFile"));
            if (rel.empty())
            {
                continue;
            }
            (conflictSet.count(rel) ? out.m_Conflicted : out.m_Applied).push_back(rel);
        }
        return out;
    }

    // ---- submodules / workspaces -------------------------------------------------------------

    std::vector<git::SubmoduleInfo> P4Workspace::Submodules() const
    {
        return {};
    }

    void P4Workspace::UpdateSubmodule(const std::string&, bool)
    {
        Unsupported("Submodules");
    }

    std::vector<git::WorktreeInfo> P4Workspace::Worktrees() const
    {
        std::vector<git::WorktreeInfo> out;
        git::WorktreeInfo self;
        self.m_Name = m_Conn.m_Client;
        self.m_Path = m_Root;
        self.m_Branch = CurrentBranch();
        self.m_bMain = true;
        out.push_back(self);
        const std::string depot =
            UsesStreams() ? m_Stream.substr(0, m_Stream.rfind('/')) + "/" : std::string();
        for (const Record& c : Run({"clients", "-u", m_Conn.m_User}).m_Stats)
        {
            const std::string name = Field(c, "client");
            const std::string stream = Field(c, "Stream");
            if (name == m_Conn.m_Client || (!depot.empty() && !StartsWithNoCase(stream, depot)))
            {
                continue;
            }
            git::WorktreeInfo w;
            w.m_Name = name;
            w.m_Path = ToSlashes(Field(c, "Root"));
            w.m_Branch = stream.empty() ? std::string() : BranchNameOf(stream);
            w.m_bLocked = Field(c, "Options").find(" locked") != std::string::npos;
            std::error_code ec;
            w.m_bValid = fs::exists(fs::u8path(w.m_Path), ec);
            out.push_back(std::move(w));
        }
        return out;
    }

    void P4Workspace::AddWorktree(
        const std::string& _Name, const std::string& _Path, const std::string& _Branch)
    {
        bool bexists = false;
        for (const git::BranchInfo& b : Branches())
        {
            bexists = bexists || b.m_Name == _Branch;
        }
        if (!bexists)
        {
            CreateBranch(_Branch, "");
        }
        WorkspaceSetup setup;
        setup.m_Port = m_Conn.m_Port;
        setup.m_User = m_Conn.m_User;
        setup.m_Charset = m_Conn.m_Charset;
        setup.m_Client = _Name;
        setup.m_Root = _Path;
        if (UsesStreams())
        {
            setup.m_Stream = BranchPath(_Branch);
        }
        else
        {
            setup.m_DepotPath = BranchPath(_Branch);
            setup.m_BranchRoot = m_BranchRoot;
        }
        Create(setup, m_Passwords);
    }

    void P4Workspace::RemoveWorktree(const std::string& _Name)
    {
        if (_Name == m_Conn.m_Client)
        {
            throw GitError("Can't remove the workspace you're in");
        }
        Connection other = m_Conn;
        other.m_Client = _Name;
        const CommandResult spec =
            P4Command::RunOrThrow(other, {"client", "-o", _Name}, {}, m_Passwords);
        const std::string root =
            spec.m_Stats.empty() ? std::string() : Field(spec.m_Stats.front(), "Root");
        const CommandResult opened =
            P4Command::Run(other, {"opened", "-C", _Name}, {}, m_Passwords);
        if (!opened.m_Stats.empty())
        {
            throw GitError("Workspace '" + _Name + "' has open files; submit or revert them first");
        }
        P4Command::RunOrThrow(m_Conn, {"client", "-d", _Name}, {}, m_Passwords);
        // Remove the folder only when it is plainly that workspace's.
        if (!root.empty())
        {
            const auto config = ReadConfigFile(root);
            const auto it = config.find("P4CLIENT");
            if (it != config.end() && it->second == _Name)
            {
                std::error_code ec;
                fs::remove_all(fs::u8path(root), ec);
            }
        }
    }

} // namespace gitgud::p4
