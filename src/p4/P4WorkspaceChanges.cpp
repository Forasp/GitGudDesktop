// -----------------------------------------------------------------------------
// P4Workspace: server-side changelists, for the Depot interface on a
// Perforce workspace. Everything here is a direct p4 command: the default
// and numbered pending changelists, check out / add / delete / move,
// reopen, revert (and revert unchanged), submit with a file selection,
// shelve / unshelve / delete shelf, get revision, locks, and per-file server
// state (have/head revisions, files others have open) for the tree icons.
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
            while (!_Text.empty() && (_Text.back() == '\n' || _Text.back() == '\r'))
            {
                _Text.pop_back();
            }
            return _Text;
        }

        // `p4 <cmd> -c <change>` takes "default" as well as a number.
        std::string ChangeArg(const std::string& _Change)
        {
            return _Change.empty() ? std::string("default") : _Change;
        }

    } // namespace

    std::vector<PendingChange> P4Workspace::PendingChanges() const
    {
        std::vector<PendingChange> out;
        PendingChange def;
        def.m_Change = "default";
        def.m_User = m_Conn.m_User;
        out.push_back(def);

        std::map<std::string, std::size_t> index;
        index["default"] = 0;
        const std::vector<Record> pending =
            RunOrThrow({"changes", "-l", "-s", "pending", "-c", m_Conn.m_Client}).m_Stats;
        // `p4 changes` lists newest first; show them in the order they were made.
        for (auto it = pending.rbegin(); it != pending.rend(); ++it)
        {
            PendingChange c;
            c.m_Change = Field(*it, "change");
            c.m_Description = Trimmed(Field(*it, "desc"));
            c.m_User = Field(*it, "user");
            c.m_TimeUtc = ToInt64(Field(*it, "time"));
            index[c.m_Change] = out.size();
            out.push_back(std::move(c));
        }

        std::set<std::string> unresolved;
        for (const Record& r : PendingResolves())
        {
            unresolved.insert(RelativeFromClientOrLocal(Field(r, "clientFile")));
        }
        for (const Record& o : Opened())
        {
            OpenedFile f;
            f.m_Path = RelativeFromClientOrLocal(Field(o, "clientFile"));
            f.m_DepotFile = Field(o, "depotFile");
            f.m_Action = Field(o, "action");
            f.m_Type = Field(o, "type");
            f.m_iRev = static_cast<int>(ToInt64(Field(o, "rev")));
            f.m_bUnresolved = unresolved.count(f.m_Path) != 0;
            f.m_bLocked = o.count("ourLock") != 0;
            const auto it = index.find(Field(o, "change"));
            if (it != index.end())
            {
                out[it->second].m_Files.push_back(std::move(f));
            }
        }

        for (const Record& s : Run({"changes", "-s", "shelved", "-c", m_Conn.m_Client}).m_Stats)
        {
            const auto it = index.find(Field(s, "change"));
            if (it == index.end())
            {
                continue;
            }
            const CommandResult d = Run({"describe", "-S", "-s", Field(s, "change")});
            if (d.m_Stats.empty())
            {
                continue;
            }
            const std::vector<std::string> files = Indexed(d.m_Stats.front(), "depotFile");
            const std::vector<std::string> actions = Indexed(d.m_Stats.front(), "action");
            for (std::size_t i = 0; i < files.size(); ++i)
            {
                ShelvedFile f;
                f.m_DepotFile = files[i];
                f.m_Path = RelativeFromDepot(files[i]);
                f.m_Action = i < actions.size() ? actions[i] : std::string();
                out[it->second].m_Shelved.push_back(std::move(f));
            }
        }
        return out;
    }

    std::string P4Workspace::CreateChange(
        const std::string& _Description, const std::vector<std::string>& _Paths)
    {
        const std::string change = NewChange(_Description, {});
        if (!_Paths.empty())
        {
            Reopen(_Paths, change);
        }
        return change;
    }

    void P4Workspace::SetChangeDescription(
        const std::string& _Change, const std::string& _Description)
    {
        CommandResult spec = RunOrThrow({"change", "-o", _Change});
        if (spec.m_Stats.empty())
        {
            throw GitError("Change " + _Change + " doesn't exist");
        }
        Record in = SpecForInput(spec.m_Stats.front());
        in["Description"] = _Description.empty() ? std::string("(no description)") : _Description;
        RunOrThrow({"change", "-i"}, in);
    }

    void P4Workspace::DeleteChange(const std::string& _Change)
    {
        if (_Change == "default" || _Change.empty())
        {
            throw GitError("The default changelist can't be deleted");
        }
        RunOrThrow({"change", "-d", _Change});
    }

    void P4Workspace::Reopen(const std::vector<std::string>& _Paths, const std::string& _Change)
    {
        std::vector<std::string> args = {"reopen", "-c", ChangeArg(_Change)};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    void P4Workspace::Edit(const std::vector<std::string>& _Paths, const std::string& _Change)
    {
        std::vector<std::string> args = {"edit", "-c", ChangeArg(_Change)};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    void P4Workspace::Add(const std::vector<std::string>& _Paths, const std::string& _Change)
    {
        std::vector<std::string> args = {"add", "-c", ChangeArg(_Change)};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    void P4Workspace::Delete(const std::vector<std::string>& _Paths, const std::string& _Change)
    {
        std::vector<std::string> args = {"delete", "-c", ChangeArg(_Change)};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    void P4Workspace::Move(
        const std::string& _From, const std::string& _To, const std::string& _Change)
    {
        bool bopened = false;
        for (const Record& o : Opened())
        {
            bopened = bopened || RelativeFromClientOrLocal(Field(o, "clientFile")) == _From;
        }
        if (!bopened)
        {
            RunOrThrow({"edit", "-c", ChangeArg(_Change), LocalArg(_From)});
        }
        RunOrThrow({"move", "-c", ChangeArg(_Change), LocalArg(_From), LocalArg(_To)});
    }

    void P4Workspace::RevertFiles(const std::vector<std::string>& _Paths, bool _bKeepLocal)
    {
        if (_Paths.empty())
        {
            return;
        }
        std::vector<std::string> args = {"revert"};
        if (_bKeepLocal)
        {
            args.emplace_back("-k");
        }
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    std::vector<std::string> P4Workspace::RevertUnchanged(const std::string& _Change)
    {
        std::vector<std::string> args = {"revert", "-a"};
        if (!_Change.empty())
        {
            args.emplace_back("-c");
            args.push_back(_Change);
        }
        args.push_back("//" + m_Conn.m_Client + "/...");
        const CommandResult r = Run(args);
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        std::vector<std::string> out;
        for (const Record& s : r.m_Stats)
        {
            const std::string rel = RelativeFromClientOrLocal(Field(s, "clientFile"));
            if (!rel.empty())
            {
                out.push_back(rel);
            }
        }
        return out;
    }

    std::string P4Workspace::SubmitPending(const std::string& _Change,
        const std::string& _Description, const std::vector<std::string>& _Paths)
    {
        if (!PendingResolves().empty())
        {
            for (const Record& r : PendingResolves())
            {
                const std::string rel = RelativeFromClientOrLocal(Field(r, "clientFile"));
                if (_Paths.empty() || std::find(_Paths.begin(), _Paths.end(), rel) != _Paths.end())
                {
                    throw GitError("Resolve '" + rel + "' before submitting.");
                }
            }
        }
        const std::string from = ChangeArg(_Change);
        const std::vector<Record> files = Opened(from);
        if (files.empty())
        {
            throw GitError("Changelist " + from + " has no open files to submit.");
        }
        const std::set<std::string> chosen(_Paths.begin(), _Paths.end());

        if (from == "default")
        {
            std::vector<std::string> depotFiles;
            for (const Record& o : files)
            {
                if (chosen.empty() ||
                    chosen.count(RelativeFromClientOrLocal(Field(o, "clientFile"))))
                {
                    depotFiles.push_back(Field(o, "depotFile"));
                }
            }
            if (depotFiles.empty())
            {
                throw GitError("Choose at least one file to submit.");
            }
            // On failure the new changelist keeps its files, ready to submit
            // again once the problem is fixed, as a failed `p4 submit` does.
            return SubmitChange(NewChange(_Description, depotFiles));
        }

        SetChangeDescription(from, _Description);
        if (!chosen.empty())
        {
            // Files left unchecked move to the default changelist.
            std::vector<std::string> rest;
            for (const Record& o : files)
            {
                const std::string rel = RelativeFromClientOrLocal(Field(o, "clientFile"));
                if (!chosen.count(rel))
                {
                    rest.push_back(rel);
                }
            }
            if (rest.size() == files.size())
            {
                throw GitError("Choose at least one file to submit.");
            }
            if (!rest.empty())
            {
                Reopen(rest, "default");
            }
        }
        return SubmitChange(from);
    }

    std::string P4Workspace::ShelveChange(
        const std::string& _Change, const std::vector<std::string>& _Paths, bool _bRevert)
    {
        if (_Change.empty() || _Change == "default")
        {
            throw GitError("Shelve a numbered changelist (create one for the default changelist's "
                           "files first)");
        }
        // -f replaces earlier shelved copies of the same files.
        std::vector<std::string> args = {"shelve", "-f", "-c", _Change};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
        if (_bRevert)
        {
            std::vector<std::string> revert = {"revert", "-c", _Change};
            if (_Paths.empty())
            {
                revert.push_back("//" + m_Conn.m_Client + "/...");
            }
            for (const std::string& p : _Paths)
            {
                revert.push_back(LocalArg(p));
            }
            RunOrThrow(revert);
        }
        return _Change;
    }

    git::UnshelveResult P4Workspace::UnshelveChange(
        const std::string& _From, const std::string& _To, const std::vector<std::string>& _Paths)
    {
        std::vector<std::string> args = {"unshelve", "-s", _From, "-c", ChangeArg(_To)};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
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
            const std::string rel = RelativeFromDepot(Field(s, "depotFile"));
            if (!rel.empty())
            {
                (conflictSet.count(rel) ? out.m_Conflicted : out.m_Applied).push_back(rel);
            }
        }
        return out;
    }

    void P4Workspace::DeleteShelf(
        const std::string& _Change, const std::vector<std::string>& _Paths)
    {
        std::vector<std::string> args = {"shelve", "-d", "-c", _Change};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    std::vector<PendingChange> P4Workspace::ListShelves(bool _bAllUsers) const
    {
        std::vector<std::string> args = {"changes", "-l", "-s", "shelved", "-m", "200"};
        if (!_bAllUsers)
        {
            args.emplace_back("-c");
            args.push_back(m_Conn.m_Client);
        }
        std::vector<PendingChange> out;
        for (const Record& s : RunOrThrow(args).m_Stats)
        {
            PendingChange c;
            c.m_Change = Field(s, "change");
            c.m_Description = Trimmed(Field(s, "desc"));
            c.m_User = Field(s, "user") + "@" + Field(s, "client");
            c.m_TimeUtc = ToInt64(Field(s, "time"));
            out.push_back(std::move(c));
        }
        return out;
    }

    std::vector<ShelvedFile> P4Workspace::ShelvedFiles(const std::string& _Change) const
    {
        std::vector<ShelvedFile> out;
        const CommandResult d = Run({"describe", "-S", "-s", _Change});
        if (d.m_Stats.empty())
        {
            return out;
        }
        const std::vector<std::string> files = Indexed(d.m_Stats.front(), "depotFile");
        const std::vector<std::string> actions = Indexed(d.m_Stats.front(), "action");
        for (std::size_t i = 0; i < files.size(); ++i)
        {
            ShelvedFile f;
            f.m_DepotFile = files[i];
            f.m_Path = RelativeFromDepot(files[i]);
            f.m_Action = i < actions.size() ? actions[i] : std::string();
            out.push_back(std::move(f));
        }
        return out;
    }

    std::vector<std::string> P4Workspace::SyncPaths(
        const std::vector<std::string>& _Paths, const std::string& _Revision)
    {
        std::string suffix = "#head";
        if (_Revision == "none")
        {
            suffix = "#none";
        }
        else if (!_Revision.empty() && _Revision[0] == '#')
        {
            suffix = _Revision;
        }
        else if (!_Revision.empty() && _Revision != "head" && _Revision != "latest")
        {
            suffix = RevisionSuffix(_Revision);
        }
        std::vector<std::string> args = {"sync"};
        if (_Paths.empty())
        {
            args.push_back("//" + m_Conn.m_Client + "/..." + suffix);
        }
        for (const std::string& p : _Paths)
        {
            // "src/..." or "src/" is a folder.
            std::string path = p;
            bool bdir = false;
            if (path.size() >= 3 && path.compare(path.size() - 3, 3, "...") == 0)
            {
                path.erase(path.size() - 3);
                bdir = true;
            }
            while (!path.empty() && path.back() == '/')
            {
                path.pop_back();
                bdir = true;
            }
            if (path.empty())
            {
                args.push_back("//" + m_Conn.m_Client + "/..." + suffix);
            }
            else
            {
                args.push_back(LocalArg(path) + (bdir ? "\\..." : "") + suffix);
            }
        }
        const CommandResult r = Run(args);
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        std::vector<std::string> skipped;
        for (const std::string& w : r.m_Warnings)
        {
            if (w.find("can't update modified file") != std::string::npos ||
                w.find("Can't clobber") != std::string::npos)
            {
                skipped.push_back(w);
            }
        }
        AutoResolve();
        return skipped;
    }

    std::vector<FileState> P4Workspace::FileStates(const std::string& _Dir, bool _bRecursive) const
    {
        std::string base = m_Root + (_Dir.empty() ? std::string() : "/" + _Dir);
        std::replace(base.begin(), base.end(), '/', '\\');
        const CommandResult r = Run({"fstat", EscapePath(base) + (_bRecursive ? "\\..." : "\\*")});
        std::vector<FileState> out;
        for (const Record& f : r.m_Stats)
        {
            FileState s;
            s.m_DepotFile = Field(f, "depotFile");
            s.m_Path = RelativeFromClientOrLocal(Field(f, "clientFile"));
            if (s.m_Path.empty())
            {
                s.m_Path = RelativeFromDepot(s.m_DepotFile);
            }
            s.m_iHaveRev = static_cast<int>(ToInt64(Field(f, "haveRev")));
            s.m_iHeadRev = static_cast<int>(ToInt64(Field(f, "headRev")));
            s.m_HeadAction = Field(f, "headAction");
            s.m_HeadType = Field(f, "headType");
            s.m_OpenAction = Field(f, "action");
            s.m_OpenChange = Field(f, "change");
            s.m_OtherOpen = Indexed(f, "otherOpen");
            s.m_bOtherLock = f.count("otherLock") != 0;
            out.push_back(std::move(s));
        }
        return out;
    }

    void P4Workspace::Lock(const std::vector<std::string>& _Paths, bool _bLock)
    {
        std::vector<std::string> args = {_bLock ? "lock" : "unlock"};
        for (const std::string& p : _Paths)
        {
            args.push_back(LocalArg(p));
        }
        RunOrThrow(args);
    }

    Record P4Workspace::Info() const
    {
        const CommandResult r = RunOrThrow({"info"});
        return r.m_Stats.empty() ? Record() : r.m_Stats.front();
    }

} // namespace gitgud::p4
