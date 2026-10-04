// -----------------------------------------------------------------------------
// P4Workspace: history: submitted changelists as commits, their diffs, file
// history and annotate (blame), browsing the depot as a tree, comparing
// versions, the file revision graph (from filelog's integration records),
// and conflicts for the 3-pane merge tool.
// -----------------------------------------------------------------------------

#include "p4/P4Workspace.h"

#include "p4/P4Internal.h"

#include <algorithm>
#include <map>
#include <set>

namespace gitgud::p4
{

    using git::GitError;
    using namespace internal;

    namespace
    {

        std::string Trimmed(std::string _Text)
        {
            while (!_Text.empty() &&
                   (_Text.back() == '\n' || _Text.back() == '\r' || _Text.back() == ' '))
            {
                _Text.pop_back();
            }
            return _Text;
        }

        bool IsDeleteAction(const std::string& _Action)
        {
            return _Action == "delete" || _Action == "move/delete" || _Action == "purge" ||
                   _Action == "archive";
        }

        bool IsAddAction(const std::string& _Action)
        {
            return _Action == "add" || _Action == "branch" || _Action == "move/add" ||
                   _Action == "import";
        }

        // Old line index for each new line of a diff (-1 for added lines).
        std::vector<long> NewToOld(const git::FileDiff& _Diff, std::size_t _nNewCount)
        {
            std::vector<long> out(_nNewCount, -1);
            long ioffset = 0; // old - new outside hunks
            std::size_t nnext = 0;
            for (const git::DiffHunk& h : _Diff.m_Hunks)
            {
                const std::size_t nhunkStart =
                    h.m_iNewStart > 0 ? static_cast<std::size_t>(h.m_iNewStart - 1) : 0;
                for (; nnext < nhunkStart && nnext < _nNewCount; ++nnext)
                {
                    out[nnext] = static_cast<long>(nnext) + ioffset;
                }
                for (const git::DiffLine& l : h.m_Lines)
                {
                    if (l.m_cOrigin == ' ' && l.m_iNewLineno > 0 && l.m_iOldLineno > 0)
                    {
                        out[static_cast<std::size_t>(l.m_iNewLineno - 1)] = l.m_iOldLineno - 1;
                    }
                }
                nnext = static_cast<std::size_t>(std::max(0, h.m_iNewStart - 1 + h.m_iNewLines));
                ioffset = (h.m_iOldStart - 1 + h.m_iOldLines) - (h.m_iNewStart - 1 + h.m_iNewLines);
                if (h.m_iOldLines == 0)
                {
                    ++ioffset;
                }
                if (h.m_iNewLines == 0)
                {
                    --ioffset;
                }
            }
            for (; nnext < _nNewCount; ++nnext)
            {
                out[nnext] = static_cast<long>(nnext) + ioffset;
            }
            return out;
        }

    } // namespace

    git::CommitInfo P4Workspace::CommitFromChange(const Record& _Change) const
    {
        git::CommitInfo c;
        c.m_Oid = Field(_Change, "change");
        c.m_ShortOid = c.m_Oid;
        c.m_Message = Trimmed(Field(_Change, "desc"));
        c.m_Summary = c.m_Message.substr(0, c.m_Message.find('\n'));
        c.m_AuthorName = Field(_Change, "user");
        c.m_AuthorEmail = c.m_AuthorName + "@" + Field(_Change, "client");
        c.m_TimeUtc = ToInt64(Field(_Change, "time"));
        return c;
    }

    // ---- log ---------------------------------------------------------------------

    std::vector<git::CommitInfo> P4Workspace::Log(const git::LogQuery& _Query) const
    {
        std::string files = "//" + m_Conn.m_Client + "/...";
        if (!_Query.m_From.empty() && _Query.m_From != "HEAD" && _Query.m_From != "head")
        {
            const std::string suffix = RevisionSuffix(_Query.m_From);
            const bool bchange =
                suffix.size() > 1 && std::isdigit(static_cast<unsigned char>(suffix[1]));
            files = bchange ? files + suffix : BranchPath(_Query.m_From) + "/...";
        }

        std::vector<Record> changes;
        if (!_Query.m_Hide.empty())
        {
            // Changes in From that Hide doesn't have yet: what integrating
            // From into Hide would bring.
            const std::string hide = BranchPath(_Query.m_Hide) + "/...";
            const CommandResult r = Run({"interchanges", "-l", files, hide});
            changes = r.m_Stats;
            std::sort(changes.begin(), changes.end(), [](const Record& _A, const Record& _B)
                { return ToInt64(Field(_A, "change")) > ToInt64(Field(_B, "change")); });
        }
        else
        {
            const std::size_t nwant = _Query.m_MaxCount + _Query.m_Skip + 1;
            changes =
                RunOrThrow({"changes", "-l", "-s", "submitted", "-m", std::to_string(nwant), files})
                    .m_Stats;
        }

        std::vector<git::CommitInfo> out;
        for (std::size_t i = _Query.m_Skip; i < changes.size() && out.size() < _Query.m_MaxCount;
            ++i)
        {
            git::CommitInfo c = CommitFromChange(changes[i]);
            if (i + 1 < changes.size())
            {
                c.m_Parents.push_back(Field(changes[i + 1], "change"));
            }
            out.push_back(std::move(c));
        }
        return out;
    }

    std::vector<git::CommitInfo> P4Workspace::FileLog(
        const std::string& _Path, std::size_t _MaxCount) const
    {
        const CommandResult r = Run({"changes", "-l", "-i", "-s", "submitted", "-m",
            std::to_string(_MaxCount + 1), LocalArg(_Path)});
        std::vector<git::CommitInfo> out;
        for (std::size_t i = 0; i < r.m_Stats.size() && out.size() < _MaxCount; ++i)
        {
            git::CommitInfo c = CommitFromChange(r.m_Stats[i]);
            if (i + 1 < r.m_Stats.size())
            {
                c.m_Parents.push_back(Field(r.m_Stats[i + 1], "change"));
            }
            out.push_back(std::move(c));
        }
        return out;
    }

    std::string P4Workspace::HeadOid() const
    {
        const CommandResult r =
            Run({"changes", "-m", "1", "-s", "submitted", "//" + m_Conn.m_Client + "/...#have"});
        return r.m_Stats.empty() ? std::string() : Field(r.m_Stats.front(), "change");
    }

    std::vector<git::CommitInfo> P4Workspace::GraphLog(const git::GraphQuery& _Query) const
    {
        // Every branch's changes: the whole stream depot, or the branch root.
        std::string scope = "//" + m_Conn.m_Client + "/...";
        if (UsesStreams())
        {
            scope = m_Stream.substr(0, m_Stream.rfind('/')) + "/...";
        }
        else if (!m_BranchRoot.empty())
        {
            scope = m_BranchRoot + "/...";
        }
        const CommandResult r = RunOrThrow(
            {"changes", "-l", "-s", "submitted", "-m", std::to_string(_Query.m_MaxCount), scope});

        // Each change's parent is the previous change on the same branch;
        // a branch's first change hangs off the newest older change of the
        // branch it came from (streams: the parent stream).
        std::map<std::string, std::string> parentOf; // branch path -> parent branch path
        if (UsesStreams())
        {
            for (const Record& s : Run({"streams"}).m_Stats)
            {
                parentOf[Field(s, "Stream")] = Field(s, "Parent");
            }
        }
        const auto branchOfChange = [&](const Record& _Change)
        {
            std::string path = Field(_Change, "path");
            if (path.empty())
            {
                return std::string();
            }
            if (UsesStreams())
            {
                return StreamOf(path);
            }
            if (!m_BranchRoot.empty() && StartsWithNoCase(path, m_BranchRoot + "/"))
            {
                const std::size_t nend = path.find('/', m_BranchRoot.size() + 1);
                return nend == std::string::npos ? path : path.substr(0, nend);
            }
            return std::string();
        };

        std::vector<git::CommitInfo> out;
        std::vector<std::string> branches;
        for (const Record& c : r.m_Stats)
        {
            out.push_back(CommitFromChange(c));
            branches.push_back(branchOfChange(c));
        }
        for (std::size_t i = 0; i < out.size(); ++i)
        {
            std::string parent;
            for (std::size_t j = i + 1; j < out.size() && parent.empty(); ++j)
            {
                if (branches[j] == branches[i])
                {
                    parent = out[j].m_Oid;
                }
            }
            if (parent.empty())
            {
                const auto it = parentOf.find(branches[i]);
                const std::string from = it == parentOf.end() ? std::string() : it->second;
                for (std::size_t j = i + 1; j < out.size() && parent.empty(); ++j)
                {
                    if (!from.empty() && branches[j] == from)
                    {
                        parent = out[j].m_Oid;
                    }
                }
            }
            if (!parent.empty())
            {
                out[i].m_Parents.push_back(parent);
            }
        }
        return out;
    }

    std::vector<git::ReflogEntry> P4Workspace::Reflog(const std::string&, std::size_t) const
    {
        return {}; // the server keeps no per-workspace history of moves
    }

    // ---- one change's diff -----------------------------------------------------------

    std::vector<git::FileDiff> P4Workspace::DiffCommit(
        const std::string& _Oid, const git::DiffOptions& _Options) const
    {
        std::string change = _Oid;
        if (!change.empty() && change[0] == '@')
        {
            change.erase(0, 1);
        }
        const CommandResult r = RunOrThrow({"describe", "-s", change});
        if (r.m_Stats.empty())
        {
            throw GitError("Change " + change + " doesn't exist");
        }
        const Record& d = r.m_Stats.front();
        const bool bshelved = Field(d, "status") == "pending";
        const std::vector<std::string> depotFiles = Indexed(d, "depotFile");
        const std::vector<std::string> actions = Indexed(d, "action");
        const std::vector<std::string> revs = Indexed(d, "rev");
        const std::vector<std::string> types = Indexed(d, "type");
        const std::set<std::string> only(_Options.m_Paths.begin(), _Options.m_Paths.end());

        std::vector<git::FileDiff> out;
        for (std::size_t i = 0; i < depotFiles.size(); ++i)
        {
            const std::string& depotFile = depotFiles[i];
            std::string rel = RelativeFromDepot(depotFile);
            if (rel.empty())
            {
                rel = UnescapePath(depotFile.substr(2));
            }
            if (!only.empty() && only.count(rel) == 0 && only.count("") == 0)
            {
                continue;
            }
            const std::string action = i < actions.size() ? actions[i] : std::string();
            const std::int64_t irev = i < revs.size() ? ToInt64(revs[i]) : 0;
            std::string oldText;
            std::string newText;
            bool bold = false;
            bool bnew = false;
            if (!IsAddAction(action) && irev > 1)
            {
                bold = PrintFile(depotFile + "#" + std::to_string(irev - 1), oldText);
            }
            if (!IsDeleteAction(action))
            {
                bnew = PrintFile(
                    depotFile + (bshelved ? "@=" + change : "#" + std::to_string(irev)), newText);
            }
            git::FileDiff fd = git::internal::DiffFileVersions(
                rel, Version(ToLf(oldText), bold), rel, Version(ToLf(newText), bnew), _Options);
            fd.m_Path = rel;
            fd.m_OldPath = rel;
            const std::string type = i < types.size() ? types[i] : std::string();
            fd.m_bIsBinary = fd.m_bIsBinary || type.find("binary") != std::string::npos;
            out.push_back(std::move(fd));
        }
        return out;
    }

    // ---- comparing versions -------------------------------------------------------------

    git::FileDiff P4Workspace::DiffVersions(const std::string& _OldPath,
        const std::string& _OldRevision, const std::string& _NewPath,
        const std::string& _NewRevision, const git::DiffOptions& _Options) const
    {
        std::string oldText;
        std::string newText;
        const bool bold = !_OldRevision.empty() && ReadFileVersion(_OldPath, _OldRevision, oldText);
        const bool bnew = !_NewRevision.empty() && ReadFileVersion(_NewPath, _NewRevision, newText);
        return git::internal::DiffFileVersions(
            _OldPath, Version(oldText, bold), _NewPath, Version(newText, bnew), _Options);
    }

    std::vector<git::ChangedFile> P4Workspace::ChangedFiles(const std::string& _OldRevision,
        const std::string& _NewRevision, const std::string& _Prefix) const
    {
        std::map<std::string, git::ChangedFile> byPath;
        const std::string scope = _Prefix.empty() ? AllFiles() : LocalArg(_Prefix) + "\\...";
        const bool bworkdir = _NewRevision == "workdir";
        const std::string newSuffix =
            bworkdir ? std::string("#have") : RevisionSuffix(_NewRevision);

        if (_OldRevision.empty())
        {
            for (const Record& f : Run({"files", "-e", scope + newSuffix}).m_Stats)
            {
                const std::string rel = RelativeFromDepot(Field(f, "depotFile"));
                if (!rel.empty())
                {
                    byPath[rel] = {rel, rel, 'A'};
                }
            }
        }
        else
        {
            const std::string oldSuffix = RevisionSuffix(_OldRevision);
            if (oldSuffix != newSuffix)
            {
                for (const Record& f :
                    Run({"diff2", "-q", scope + oldSuffix, scope + newSuffix}).m_Stats)
                {
                    const std::string status = Field(f, "status");
                    const std::string depot = Field(f, "depotFile2").empty()
                                                  ? Field(f, "depotFile")
                                                  : Field(f, "depotFile2");
                    const std::string rel =
                        RelativeFromDepot(depot.empty() ? Field(f, "depotFile") : depot);
                    if (rel.empty() || status == "identical")
                    {
                        continue;
                    }
                    const char ccode =
                        status == "left only" ? 'D' : (status == "right only" ? 'A' : 'M');
                    byPath[rel] = {rel, rel, ccode};
                }
            }
        }
        if (bworkdir)
        {
            for (const git::StatusEntry& e : Status())
            {
                if (!_Prefix.empty() && e.m_Path.rfind(_Prefix + "/", 0) != 0 &&
                    e.m_Path != _Prefix)
                {
                    continue;
                }
                const char ccode = e.m_cCode == '?' ? 'A' : (e.m_cCode == 'U' ? 'M' : e.m_cCode);
                auto it = byPath.find(e.m_Path);
                if (it == byPath.end())
                {
                    byPath[e.m_Path] = {e.m_Path, e.m_Path, ccode};
                }
                else if (ccode == 'D')
                {
                    it->second.m_cStatus = it->second.m_cStatus == 'A' ? 'X' : 'D';
                }
            }
        }
        std::vector<git::ChangedFile> out;
        for (auto& [path, file] : byPath)
        {
            if (file.m_cStatus != 'X')
            {
                out.push_back(file);
            }
        }
        return out;
    }

    // ---- browsing ---------------------------------------------------------------------

    std::vector<git::TreeEntry> P4Workspace::ListTree(
        const std::string& _Revision, const std::string& _Dir) const
    {
        const std::string suffix =
            _Revision == "workdir" ? std::string("#have") : RevisionSuffix(_Revision);
        std::string base = m_Root + (_Dir.empty() ? std::string() : "/" + _Dir);
        std::replace(base.begin(), base.end(), '/', '\\');
        const std::string pattern = EscapePath(base) + "\\*" + suffix;

        std::vector<git::TreeEntry> out;
        for (const Record& d : Run({"dirs", pattern}).m_Stats)
        {
            const std::string depotDir = Field(d, "dir");
            const std::string name = UnescapePath(depotDir.substr(depotDir.rfind('/') + 1));
            git::TreeEntry e;
            e.m_Name = name;
            e.m_Path = _Dir.empty() ? name : _Dir + "/" + name;
            e.m_bIsDir = true;
            e.m_Oid = depotDir;
            out.push_back(std::move(e));
        }
        std::vector<git::TreeEntry> files;
        for (const Record& f :
            Run({"fstat", "-Ol", "-T", "depotFile,headAction,headRev,fileSize", pattern}).m_Stats)
        {
            if (IsDeleteAction(Field(f, "headAction")))
            {
                continue;
            }
            const std::string depotFile = Field(f, "depotFile");
            const std::string name = UnescapePath(depotFile.substr(depotFile.rfind('/') + 1));
            git::TreeEntry e;
            e.m_Name = name;
            e.m_Path = _Dir.empty() ? name : _Dir + "/" + name;
            e.m_Oid = depotFile + "#" + Field(f, "headRev");
            e.m_Size = ToInt64(Field(f, "fileSize"));
            files.push_back(std::move(e));
        }
        const auto byName = [](const git::TreeEntry& _A, const git::TreeEntry& _B)
        {
            return _A.m_Name < _B.m_Name;
        };
        std::sort(out.begin(), out.end(), byName);
        std::sort(files.begin(), files.end(), byName);
        out.insert(out.end(), files.begin(), files.end());
        return out;
    }

    // ---- blame ------------------------------------------------------------------------------

    git::BlameResult P4Workspace::Blame(
        const std::string& _Path, const std::string& _Revision) const
    {
        const bool bworkdir = _Revision == "workdir";
        const std::string spec =
            LocalArg(_Path) + (bworkdir ? std::string("#have") : RevisionSuffix(_Revision));
        const CommandResult r = Run({"annotate", "-c", "-I", "-q", spec});

        std::vector<std::string> depotLines;
        std::vector<std::string> lineChange;
        for (const Record& rec : r.m_Stats)
        {
            if (rec.count("lower") == 0)
            {
                continue; // the file header record
            }
            std::string line = Field(rec, "data");
            while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
            {
                line.pop_back();
            }
            depotLines.push_back(line);
            lineChange.push_back(Field(rec, "lower"));
        }

        // Summaries, authors and times of every change that appears.
        std::map<std::string, git::CommitInfo> info;
        {
            std::vector<std::string> args = {"describe", "-s"};
            std::set<std::string> seen;
            for (const std::string& c : lineChange)
            {
                if (seen.insert(c).second)
                {
                    args.push_back(c);
                }
            }
            if (args.size() > 2)
            {
                for (const Record& d : Run(args).m_Stats)
                {
                    info[Field(d, "change")] = CommitFromChange(d);
                }
            }
        }

        git::BlameResult out;
        std::vector<std::string> owners; // change per output line ("" = uncommitted)
        if (bworkdir)
        {
            bool bexists = false;
            const std::string work = ReadWorkFile(_Path, bexists);
            out.m_Lines = SplitLines(work);
            std::string depotText;
            for (const std::string& l : depotLines)
            {
                depotText += l + "\n";
            }
            const git::FileDiff d = git::internal::DiffFileVersions(
                _Path, Version(depotText, true), _Path, Version(work, bexists), git::DiffOptions());
            const std::vector<long> map = NewToOld(d, out.m_Lines.size());
            for (std::size_t i = 0; i < out.m_Lines.size(); ++i)
            {
                const long iold = map[i];
                owners.push_back(iold >= 0 && static_cast<std::size_t>(iold) < lineChange.size()
                                     ? lineChange[static_cast<std::size_t>(iold)]
                                     : std::string());
            }
        }
        else
        {
            out.m_Lines = depotLines;
            owners = lineChange;
        }

        for (std::size_t i = 0; i < owners.size();)
        {
            std::size_t nend = i + 1;
            while (nend < owners.size() && owners[nend] == owners[i])
            {
                ++nend;
            }
            git::BlameHunk h;
            h.m_StartLine = i + 1;
            h.m_LineCount = nend - i;
            if (owners[i].empty())
            {
                h.m_bUncommitted = true;
                h.m_Oid = "0";
                h.m_Summary = "Not submitted yet";
                h.m_Author = m_Conn.m_User;
            }
            else
            {
                const auto it = info.find(owners[i]);
                h.m_Oid = owners[i];
                if (it != info.end())
                {
                    h.m_Summary = it->second.m_Summary;
                    h.m_Author = it->second.m_AuthorName;
                    h.m_TimeUtc = it->second.m_TimeUtc;
                }
            }
            out.m_Hunks.push_back(std::move(h));
            i = nend;
        }
        return out;
    }

    // ---- file revision graph -------------------------------------------------------------

    git::RevisionGraph P4Workspace::FileRevisionGraph(
        const std::string& _Path, const git::RevisionGraphQuery& _Query) const
    {
        // The file in every branch: //depot/*/path for streams, the branch
        // root's folders for classic depots, else just this file.
        std::string pattern = DepotFromRelative(_Path);
        if (pattern.empty())
        {
            throw GitError("'" + _Path + "' is not in this workspace's view");
        }
        if (UsesStreams())
        {
            const std::string stream = StreamOf(pattern);
            pattern = stream.substr(0, stream.rfind('/')) + "/*" + pattern.substr(stream.size());
        }
        else if (!m_BranchRoot.empty() && StartsWithNoCase(pattern, m_BranchRoot + "/"))
        {
            const std::size_t nend = pattern.find('/', m_BranchRoot.size() + 1);
            if (nend != std::string::npos)
            {
                pattern = m_BranchRoot + "/*" + pattern.substr(nend);
            }
        }
        const CommandResult r =
            Run({"filelog", "-l", "-m", std::to_string(_Query.m_MaxNodes), pattern});

        git::RevisionGraph g;

        struct Rev
        {
            std::string m_File;
            int m_iRev = 0;
            git::CommitInfo m_Commit;
            std::string m_Action;
        };

        std::vector<Rev> revs;

        struct Link
        {
            std::string m_FromFile;
            int m_iFromRev = 0;
            std::string m_ToFile;
            int m_iToRev = 0;
            bool m_bMerge = false;
        };

        std::vector<Link> links;
        const std::set<std::string> excluded(
            _Query.m_ExcludeBranches.begin(), _Query.m_ExcludeBranches.end());
        std::map<std::string, int> rowOf;

        for (const Record& f : r.m_Stats)
        {
            const std::string file = Field(f, "depotFile");
            const std::string branchPath =
                UsesStreams() ? StreamOf(file) : file.substr(0, file.rfind('/'));
            const std::string branch = BranchNameOf(branchPath);
            if (excluded.count(branch) != 0)
            {
                continue;
            }
            if (rowOf.count(file) == 0)
            {
                rowOf[file] = static_cast<int>(g.m_Rows.size());
                git::RevisionRow row;
                row.m_Name = branch;
                row.m_bHead = UsesStreams() ? StartsWithNoCase(branchPath, m_Stream) &&
                                                  branchPath.size() == m_Stream.size()
                                            : !DepotFromRelative(_Path).empty() &&
                                                  DepotFromRelative(_Path) == file;
                g.m_Rows.push_back(row);
            }
            for (int i = 0; f.count("rev" + std::to_string(i)) != 0; ++i)
            {
                const std::string n = std::to_string(i);
                Rev rev;
                rev.m_File = file;
                rev.m_iRev = static_cast<int>(ToInt64(Field(f, "rev" + n)));
                rev.m_Action = Field(f, "action" + n);
                rev.m_Commit.m_Oid = Field(f, "change" + n);
                rev.m_Commit.m_ShortOid = rev.m_Commit.m_Oid;
                rev.m_Commit.m_Message = Trimmed(Field(f, "desc" + n));
                rev.m_Commit.m_Summary =
                    rev.m_Commit.m_Message.substr(0, rev.m_Commit.m_Message.find('\n'));
                rev.m_Commit.m_AuthorName = Field(f, "user" + n);
                rev.m_Commit.m_TimeUtc = ToInt64(Field(f, "time" + n));
                revs.push_back(rev);
                // "how" records: where this revision's content came from.
                for (int j = 0; f.count("how" + n + "," + std::to_string(j)) != 0; ++j)
                {
                    const std::string m = n + "," + std::to_string(j);
                    const std::string how = Field(f, "how" + m);
                    if (how.size() < 5 || how.compare(how.size() - 5, 5, " from") != 0)
                    {
                        continue; // "... into" is the same edge seen from the source
                    }
                    std::string erev = Field(f, "erev" + m);
                    if (!erev.empty() && erev[0] == '#')
                    {
                        erev.erase(0, 1);
                    }
                    links.push_back({Field(f, "file" + m), static_cast<int>(ToInt64(erev)), file,
                        rev.m_iRev, how != "branch from" && how != "add from"});
                }
            }
        }

        // Columns: oldest change first.
        std::sort(revs.begin(), revs.end(),
            [](const Rev& _A, const Rev& _B)
            {
                return ToInt64(_A.m_Commit.m_Oid) != ToInt64(_B.m_Commit.m_Oid)
                           ? ToInt64(_A.m_Commit.m_Oid) < ToInt64(_B.m_Commit.m_Oid)
                           : _A.m_iRev < _B.m_iRev;
            });
        std::map<std::pair<std::string, int>, int> nodeOf;
        for (const Rev& rev : revs)
        {
            git::RevisionNode node;
            node.m_Commit = rev.m_Commit;
            node.m_iRow = rowOf[rev.m_File];
            node.m_iColumn = static_cast<int>(g.m_Nodes.size());
            node.m_iRevision = rev.m_iRev;
            node.m_cAction = IsAddAction(rev.m_Action)      ? 'A'
                             : IsDeleteAction(rev.m_Action) ? 'D'
                             : rev.m_Action == "integrate"  ? 'I'
                                                            : 'M';
            nodeOf[{rev.m_File, rev.m_iRev}] = static_cast<int>(g.m_Nodes.size());
            g.m_Nodes.push_back(node);
        }
        // Edges along each row, then the integrations between rows.
        std::map<std::string, int> lastInRow;
        for (std::size_t i = 0; i < revs.size(); ++i)
        {
            const auto it = lastInRow.find(revs[i].m_File);
            if (it != lastInRow.end())
            {
                g.m_Edges.push_back({it->second, static_cast<int>(i), false});
            }
            lastInRow[revs[i].m_File] = static_cast<int>(i);
        }
        for (const Link& l : links)
        {
            const auto from = nodeOf.find({l.m_FromFile, l.m_iFromRev});
            const auto to = nodeOf.find({l.m_ToFile, l.m_iToRev});
            if (from != nodeOf.end() && to != nodeOf.end())
            {
                g.m_Edges.push_back({from->second, to->second, l.m_bMerge});
            }
        }
        return g;
    }

    // ---- conflicts ---------------------------------------------------------------------------

    std::vector<std::string> P4Workspace::ConflictedPaths() const
    {
        std::vector<std::string> out;
        for (const Record& r : PendingResolves())
        {
            const std::string rel = RelativeFromClientOrLocal(Field(r, "clientFile"));
            if (!rel.empty())
            {
                out.push_back(rel);
            }
        }
        return out;
    }

    git::ConflictFile P4Workspace::ReadConflict(const std::string& _Path) const
    {
        const CommandResult r = Run({"resolve", "-n", LocalArg(_Path)});
        if (r.m_Stats.empty())
        {
            throw GitError("'" + _Path + "' is not conflicted");
        }
        const Record& rec = r.m_Stats.front();
        const std::string from = Field(rec, "fromFile");
        const std::string endFromRev = Field(rec, "endFromRev");
        // Resolving against newer revisions of the same file (after a sync)
        // names no baseFile: the base is the revision you started from.
        std::string baseFile = Field(rec, "baseFile");
        std::string baseRev = Field(rec, "baseRev");
        if (baseFile.empty())
        {
            baseFile = from;
            baseRev = Field(rec, "startFromRev");
            if (baseRev == "none" || baseRev == "0")
            {
                baseFile.clear();
            }
        }

        std::string theirs;
        std::string base;
        bool bbinary = false;
        const bool btheirs = PrintFile(from + "#" + endFromRev, theirs, &bbinary);
        const bool bbase = !baseFile.empty() && PrintFile(baseFile + "#" + baseRev, base);
        bool bours = false;
        const std::string ours = ReadWorkFile(_Path, bours);
        theirs = ToLf(theirs);
        base = ToLf(base);
        git::ConflictFile out = git::internal::ConflictFromBuffers(
            _Path, bbase ? &base : nullptr, bours ? &ours : nullptr, btheirs ? &theirs : nullptr);
        out.m_bBinary = out.m_bBinary || bbinary;
        return out;
    }

} // namespace gitgud::p4
