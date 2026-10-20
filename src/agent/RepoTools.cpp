#include "agent/RepoTools.h"

#include <algorithm>
#include <cctype>
#include <ctime>
#include <exception>

#include "git/Repository.h"
#include "p4/P4Workspace.h"

namespace gitgud::agent
{

    namespace
    {

        using app::Json;

        // Longer output is cut here (with a note), so one call can't flood
        // the model's context.
        constexpr std::size_t kMaxOutput = 100u * 1024u;

        ToolResult Fail(std::string _Text)
        {
            return {std::move(_Text), true};
        }

        // An optional string argument; false (with `_Error`) for another type.
        bool StringArg(
            const Json& _Args, const char* _szKey, std::string& _Out, std::string& _Error)
        {
            const Json& value = _Args[_szKey];
            if (value.IsNull())
            {
                return true;
            }
            if (!value.IsString())
            {
                _Error = std::string("'") + _szKey + "' must be a string";
                return false;
            }
            _Out = value.AsString();
            return true;
        }

        bool BoolArg(const Json& _Args, const char* _szKey, bool& _bOut, std::string& _Error)
        {
            const Json& value = _Args[_szKey];
            if (value.IsNull())
            {
                return true;
            }
            if (!value.IsBool())
            {
                _Error = std::string("'") + _szKey + "' must be true or false";
                return false;
            }
            _bOut = value.AsBool();
            return true;
        }

        bool IntArg(const Json& _Args, const char* _szKey, int64_t _iMin, int64_t _iMax,
            int64_t& _iOut, std::string& _Error)
        {
            const Json& value = _Args[_szKey];
            if (value.IsNull())
            {
                return true;
            }
            if (!value.IsNumber() || value.AsNumber() != static_cast<double>(value.AsInt()) ||
                value.AsInt() < _iMin || value.AsInt() > _iMax)
            {
                _Error = std::string("'") + _szKey + "' must be a whole number from " +
                         std::to_string(_iMin) + " to " + std::to_string(_iMax);
                return false;
            }
            _iOut = value.AsInt();
            return true;
        }

        std::string Date(int64_t _iTimeUtc)
        {
            const std::time_t time = static_cast<std::time_t>(_iTimeUtc);
            std::tm tm = {};
#if defined(_WIN32)
            gmtime_s(&tm, &time);
#else
            gmtime_r(&time, &tm);
#endif
            char szbuffer[32] = {};
            std::strftime(szbuffer, sizeof(szbuffer), "%Y-%m-%d %H:%M", &tm);
            return szbuffer;
        }

        std::string Cap(std::string _Text, const char* _szHint)
        {
            if (_Text.size() <= kMaxOutput)
            {
                return _Text;
            }
            // Cut at a line break, never inside a UTF-8 sequence.
            std::size_t ncut = _Text.rfind('\n', kMaxOutput);
            if (ncut == std::string::npos)
            {
                ncut = kMaxOutput;
                while (ncut > 0 && (static_cast<unsigned char>(_Text[ncut]) & 0xC0u) == 0x80u)
                {
                    --ncut;
                }
            }
            _Text.resize(ncut);
            _Text += "\n[cut at " + std::to_string(kMaxOutput / 1024u) + " KB; " + _szHint + "]\n";
            return _Text;
        }

        std::string AheadBehindText(const git::AheadBehind& _Ab)
        {
            if (!_Ab.m_bHasUpstream)
            {
                return "no upstream";
            }
            return "ahead " + std::to_string(_Ab.m_Ahead) + ", behind " +
                   std::to_string(_Ab.m_Behind) + " of " + _Ab.m_Upstream;
        }

        const char* StateText(git::RepoState _State)
        {
            switch (_State)
            {
            case git::RepoState::Merge:
                return "merge in progress";
            case git::RepoState::Rebase:
                return "rebase in progress";
            case git::RepoState::CherryPick:
                return "cherry-pick in progress";
            case git::RepoState::Revert:
                return "revert in progress";
            case git::RepoState::Other:
                return "an operation is in progress";
            case git::RepoState::None:
                break;
            }
            return "";
        }

        void AppendDiff(const git::FileDiff& _Diff, std::string& _Out)
        {
            const std::string oldPath = _Diff.m_OldPath.empty() ? _Diff.m_Path : _Diff.m_OldPath;
            _Out += "diff --git a/" + oldPath + " b/" + _Diff.m_Path + "\n";
            if (_Diff.m_cStatus == 'R' && oldPath != _Diff.m_Path)
            {
                _Out += "rename from " + oldPath + "\nrename to " + _Diff.m_Path + "\n";
            }
            if (_Diff.m_bIsBinary)
            {
                _Out += "Binary files differ\n";
                return;
            }
            if (_Diff.m_Hunks.empty())
            {
                return;
            }
            _Out +=
                (_Diff.m_cStatus == 'A' ? std::string("--- /dev/null") : "--- a/" + oldPath) + "\n";
            _Out +=
                (_Diff.m_cStatus == 'D' ? std::string("+++ /dev/null") : "+++ b/" + _Diff.m_Path) +
                "\n";
            for (const git::DiffHunk& hunk : _Diff.m_Hunks)
            {
                _Out += hunk.m_Header;
                if (hunk.m_Header.empty() || hunk.m_Header.back() != '\n')
                {
                    _Out += '\n';
                }
                for (const git::DiffLine& line : hunk.m_Lines)
                {
                    if (line.m_cOrigin == ' ' || line.m_cOrigin == '+' || line.m_cOrigin == '-')
                    {
                        _Out += line.m_cOrigin;
                        _Out += line.m_Content;
                        _Out += '\n';
                    }
                    else
                    {
                        // libgit2's end-of-file markers ('=', '>', '<').
                        _Out += "\\ No newline at end of file\n";
                    }
                }
            }
        }

        // The commit a branch, tag, or id names (none, or one).
        std::vector<git::CommitInfo> FindCommit(
            const git::Repository& _Repo, const std::string& _Rev)
        {
            git::LogQuery query;
            query.m_MaxCount = 1;
            query.m_From = _Rev;
            std::vector<git::CommitInfo> found = _Repo.Log(query);
            // Perforce answers "@123" with the latest change up to 123.
            if (_Repo.P4() && !found.empty() && found.front().m_Oid != _Rev &&
                std::all_of(_Rev.begin(), _Rev.end(),
                    [](unsigned char _C) { return std::isdigit(_C) != 0; }))
            {
                found.clear();
            }
            return found;
        }

        std::string ResolveCommit(const git::Repository& _Repo, const std::string& _Rev)
        {
            const std::vector<git::CommitInfo> found = FindCommit(_Repo, _Rev);
            return found.empty() ? std::string() : found.front().m_Oid;
        }

        // ---- the tools ------------------------------------------------------------

        ToolResult Status(const git::Repository& _Repo)
        {
            std::string out = "Repository: " + _Repo.WorkDir() + " (" + _Repo.Backend() + ")\n";
            const std::string branch = _Repo.CurrentBranch();
            out += "Branch: " + (branch.empty() ? std::string("(detached HEAD)") : branch);
            out += " (" + AheadBehindText(_Repo.GetAheadBehind()) + ")\n";
            const std::string state = StateText(_Repo.State());
            if (!state.empty())
            {
                out += "State: " + state + "\n";
            }
            const std::vector<git::StatusEntry> entries = _Repo.Status();
            if (entries.empty())
            {
                out += "No changes.\n";
                return {out};
            }
            out += "Changes (" + std::to_string(entries.size()) + "):\n";
            for (const git::StatusEntry& entry : entries)
            {
                std::string code = "  ";
                if (entry.m_cCode == '?')
                {
                    code = "??";
                }
                else
                {
                    code[0] = entry.m_bStaged ? entry.m_cCode : ' ';
                    code[1] = entry.m_bUnstaged ? entry.m_cCode : ' ';
                }
                out += code + " " + entry.m_Path + "\n";
            }
            return {Cap(out, "too many changes to list")};
        }

        ToolResult Diff(const git::Repository& _Repo, const Json& _Args)
        {
            std::string error;
            std::string scope = "all";
            std::string path;
            std::string commit;
            int64_t icontext = 3;
            if (!StringArg(_Args, "scope", scope, error) ||
                !StringArg(_Args, "path", path, error) ||
                !StringArg(_Args, "commit", commit, error) ||
                !IntArg(_Args, "context", 0, 100, icontext, error))
            {
                return Fail(error);
            }
            git::DiffOptions options;
            options.m_iContextLines = static_cast<int>(icontext);

            std::string out;
            if (!commit.empty())
            {
                if (!path.empty())
                {
                    options.m_Paths.push_back(path);
                }
                const std::string oid = ResolveCommit(_Repo, commit);
                if (oid.empty())
                {
                    return Fail("No commit '" + commit + "'");
                }
                for (const git::FileDiff& diff : _Repo.DiffCommit(oid, options))
                {
                    AppendDiff(diff, out);
                }
                return {out.empty() ? "No changes in " + commit + ".\n"
                                    : Cap(out, "pass path for one file")};
            }

            git::DiffTarget target = git::DiffTarget::Head;
            if (scope == "staged")
            {
                target = git::DiffTarget::Staged;
            }
            else if (scope == "unstaged")
            {
                target = git::DiffTarget::Unstaged;
            }
            else if (scope != "all")
            {
                return Fail("'scope' must be all, staged, or unstaged");
            }

            std::vector<std::string> paths;
            if (!path.empty())
            {
                paths.push_back(path);
            }
            else
            {
                for (const git::StatusEntry& entry : _Repo.Status())
                {
                    paths.push_back(entry.m_Path);
                }
            }
            for (const std::string& file : paths)
            {
                if (out.size() > kMaxOutput)
                {
                    break;
                }
                const git::FileDiff diff = _Repo.DiffFile(file, target, options);
                if (!diff.m_Path.empty())
                {
                    AppendDiff(diff, out);
                }
            }
            return {
                out.empty() ? std::string("No changes.\n") : Cap(out, "pass path for one file")};
        }

        std::string CommitLine(const git::CommitInfo& _Commit)
        {
            const std::string id = _Commit.m_ShortOid.empty() ? _Commit.m_Oid : _Commit.m_ShortOid;
            return id + " " + Date(_Commit.m_TimeUtc) + " " + _Commit.m_AuthorName + ": " +
                   _Commit.m_Summary + "\n";
        }

        ToolResult Log(const git::Repository& _Repo, const Json& _Args)
        {
            std::string error;
            int64_t imax = 30;
            std::string ref;
            std::string path;
            if (!IntArg(_Args, "max", 1, 500, imax, error) ||
                !StringArg(_Args, "ref", ref, error) || !StringArg(_Args, "path", path, error))
            {
                return Fail(error);
            }
            if (!path.empty() && !ref.empty())
            {
                return Fail("Pass either 'ref' or 'path', not both");
            }
            std::vector<git::CommitInfo> commits;
            if (!path.empty())
            {
                commits = _Repo.FileLog(path, static_cast<std::size_t>(imax));
            }
            else
            {
                git::LogQuery query;
                query.m_MaxCount = static_cast<std::size_t>(imax);
                query.m_From = ref;
                commits = _Repo.Log(query);
            }
            if (commits.empty())
            {
                return {"No commits.\n"};
            }
            std::string out;
            for (const git::CommitInfo& commit : commits)
            {
                out += CommitLine(commit);
            }
            return {Cap(out, "ask for fewer")};
        }

        ToolResult Show(const git::Repository& _Repo, const Json& _Args)
        {
            std::string error;
            std::string commit;
            bool bpatch = false;
            if (!StringArg(_Args, "commit", commit, error) ||
                !BoolArg(_Args, "patch", bpatch, error))
            {
                return Fail(error);
            }
            if (commit.empty())
            {
                return Fail("'commit' is required");
            }
            const std::vector<git::CommitInfo> found = FindCommit(_Repo, commit);
            if (found.empty())
            {
                return Fail("No commit '" + commit + "'");
            }
            const git::CommitInfo& info = found.front();
            std::string out = "commit " + info.m_Oid + "\n";
            out += "Author: " + info.m_AuthorName;
            if (!info.m_AuthorEmail.empty())
            {
                out += " <" + info.m_AuthorEmail + ">";
            }
            out += "\nDate:   " + Date(info.m_TimeUtc) + " UTC\n";
            if (!info.m_Parents.empty())
            {
                out += "Parents:";
                for (const std::string& parent : info.m_Parents)
                {
                    out += " " + parent;
                }
                out += "\n";
            }
            out += "\n" + info.m_Message;
            if (out.back() != '\n')
            {
                out += '\n';
            }
            const std::vector<git::FileDiff> diffs = _Repo.DiffCommit(info.m_Oid);
            out += "\nFiles (" + std::to_string(diffs.size()) + "):\n";
            for (const git::FileDiff& diff : diffs)
            {
                out += std::string(1, diff.m_cStatus) + " " + diff.m_Path;
                if (!diff.m_OldPath.empty() && diff.m_OldPath != diff.m_Path)
                {
                    out += " (from " + diff.m_OldPath + ")";
                }
                out += "\n";
            }
            if (bpatch)
            {
                out += "\n";
                for (const git::FileDiff& diff : diffs)
                {
                    if (out.size() > kMaxOutput)
                    {
                        break;
                    }
                    AppendDiff(diff, out);
                }
            }
            return {Cap(out, "use diff with commit and path for one file")};
        }

        ToolResult Branches(const git::Repository& _Repo, const Json& _Args)
        {
            std::string error;
            bool bremotes = true;
            if (!BoolArg(_Args, "remotes", bremotes, error))
            {
                return Fail(error);
            }
            std::string out;
            for (const git::BranchInfo& branch : _Repo.Branches())
            {
                if (branch.m_bIsRemote && !bremotes)
                {
                    continue;
                }
                out += (branch.m_bIsHead ? "* " : "  ") + branch.m_Name;
                if (branch.m_bIsRemote)
                {
                    out += " (remote)";
                }
                if (!branch.m_Upstream.empty())
                {
                    out += " -> " + branch.m_Upstream + " [ahead " +
                           std::to_string(branch.m_Ahead) + ", behind " +
                           std::to_string(branch.m_Behind) + "]";
                }
                out += "\n";
            }
            if (out.empty())
            {
                out = "No branches yet.\n";
            }
            return {Cap(out, "pass remotes = false")};
        }

        ToolResult P4Changes(const git::Repository& _Repo)
        {
            const p4::P4Workspace* pws = _Repo.P4();
            if (!pws)
            {
                return Fail("The open repository uses Git; p4_changes is for Perforce workspaces");
            }
            std::string out;
            for (const p4::PendingChange& change : pws->PendingChanges())
            {
                out += "Change " + change.m_Change;
                if (change.m_TimeUtc > 0)
                {
                    out += " (" + Date(change.m_TimeUtc) + ")";
                }
                out += ": " + (change.m_Description.empty() ? std::string("(no description)")
                                                            : change.m_Description);
                if (out.back() != '\n')
                {
                    out += '\n';
                }
                for (const p4::OpenedFile& file : change.m_Files)
                {
                    out += "  " + file.m_Action + " " + file.m_Path + " (" + file.m_DepotFile;
                    if (file.m_iRev > 0)
                    {
                        out += "#" + std::to_string(file.m_iRev);
                    }
                    out += ", " + file.m_Type + ")";
                    if (file.m_bUnresolved)
                    {
                        out += " unresolved";
                    }
                    if (file.m_bLocked)
                    {
                        out += " locked";
                    }
                    out += "\n";
                }
                if (change.m_Files.empty())
                {
                    out += "  no open files\n";
                }
                for (const p4::ShelvedFile& file : change.m_Shelved)
                {
                    out += "  shelved " + file.m_Action + " " + file.m_Path + " (" +
                           file.m_DepotFile + ")\n";
                }
            }
            return {Cap(out, "too many files to list")};
        }

    } // namespace

    ToolResult RunTool(
        const std::string& _RepoPath, const std::string& _Name, const app::Json& _Arguments)
    {
        if (!IsTool(_Name))
        {
            return Fail("No tool named '" + _Name + "'");
        }
        if (!_Arguments.IsNull() && !_Arguments.IsObject())
        {
            return Fail("The arguments must be an object");
        }
        if (_RepoPath.empty())
        {
            return Fail("No repository is open in the app");
        }
        try
        {
            // Our own handle: this runs off the UI thread (TaskRunner's rule).
            const git::Repository repo = git::Repository::Open(_RepoPath);
            if (_Name == "status")
            {
                return Status(repo);
            }
            if (_Name == "diff")
            {
                return Diff(repo, _Arguments);
            }
            if (_Name == "log")
            {
                return Log(repo, _Arguments);
            }
            if (_Name == "show")
            {
                return Show(repo, _Arguments);
            }
            if (_Name == "branches")
            {
                return Branches(repo, _Arguments);
            }
            if (_Name == "p4_changes")
            {
                return P4Changes(repo);
            }
            return Fail("The tool '" + _Name + "' isn't implemented");
        }
        catch (const std::exception& e)
        {
            return Fail(e.what());
        }
    }

} // namespace gitgud::agent
