// -----------------------------------------------------------------------------
// Repository — history views beyond the plain log: the all-branches walk the
// commit graph is drawn from, the reflog and branch moves behind Undo/Redo,
// per-file history, and blame.
// Same layer rules as Repository.h: RAII, plain data out, GitError on failure.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <ctime>
#include <unordered_map>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        void RequireOpen(git_repository* _pRepo, const char* _szWhat)
        {
            if (!_pRepo)
            {
                throw GitError(std::string(_szWhat) + " on an unopened repository");
            }
        }

        // The id of `_Path`'s entry in a commit's tree; false when absent.
        bool EntryId(git_commit* _pCommit, const std::string& _Path, git_oid& _Out)
        {
            TreePtr tree;
            if (git_commit_tree(&tree.m_pP, _pCommit) < 0)
            {
                return false;
            }
            TreeEntryPtr entry;
            if (git_tree_entry_bypath(&entry.m_pP, tree.m_pP, _Path.c_str()) != 0)
            {
                return false;
            }
            git_oid_cpy(&_Out, git_tree_entry_id(entry.m_pP));
            return true;
        }

        // Split text into lines (no terminators; a CR before LF is dropped).
        std::vector<std::string> SplitLines(const std::string& _Text)
        {
            std::vector<std::string> out;
            std::size_t nstart = 0;
            while (nstart < _Text.size())
            {
                std::size_t nend = _Text.find('\n', nstart);
                if (nend == std::string::npos)
                {
                    nend = _Text.size();
                }
                std::string line = _Text.substr(nstart, nend - nstart);
                if (!line.empty() && line.back() == '\r')
                {
                    line.pop_back();
                }
                out.push_back(std::move(line));
                nstart = nend + 1;
            }
            return out;
        }

    } // namespace

    // ---- Commit graph ------------------------------------------------------------

    std::vector<CommitInfo> Repository::GraphLog(const GraphQuery& _Query) const
    {
        if (m_pP4)
        {
            return m_pP4->GraphLog(_Query);
        }

        RequireOpen(m_pRepo, "graphLog()");

        RevwalkPtr walk;
        if (git_revwalk_new(&walk.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_revwalk_new failed");
        }
        git_revwalk_sorting(walk.m_pP, GIT_SORT_TOPOLOGICAL | GIT_SORT_TIME);

        // Globs skip refs that don't point at commits, and match nothing
        // harmlessly on an empty repository.
        git_revwalk_push_head(walk.m_pP);
        git_revwalk_push_glob(walk.m_pP, "refs/heads");
        if (_Query.m_bRemotes)
        {
            git_revwalk_push_glob(walk.m_pP, "refs/remotes");
        }
        if (_Query.m_bTags)
        {
            git_revwalk_push_glob(walk.m_pP, "refs/tags");
        }

        std::vector<CommitInfo> out;
        git_oid oid;
        while (out.size() < _Query.m_MaxCount && git_revwalk_next(&oid, walk.m_pP) == 0)
        {
            CommitInfo info;
            if (ReadCommitInfo(m_pRepo, &oid, info))
            {
                out.push_back(std::move(info));
            }
        }
        return out;
    }

    // ---- Undo support --------------------------------------------------------------

    std::string Repository::HeadOid() const
    {
        if (m_pP4)
        {
            return m_pP4->HeadOid();
        }

        RequireOpen(m_pRepo, "headOid()");
        git_oid oid;
        if (git_reference_name_to_id(&oid, m_pRepo, "HEAD") != 0)
        {
            return {};
        }
        return OidToHex(&oid);
    }

    std::vector<ReflogEntry> Repository::Reflog(
        const std::string& _Ref, std::size_t _MaxCount) const
    {
        if (m_pP4)
        {
            return m_pP4->Reflog(_Ref, _MaxCount);
        }

        RequireOpen(m_pRepo, "reflog()");

        ReflogPtr log;
        if (git_reflog_read(&log.m_pP, m_pRepo, _Ref.c_str()) < 0)
        {
            RaiseLastError("Reading the reflog of " + _Ref + " failed");
        }

        std::vector<ReflogEntry> out;
        const std::size_t ncount = git_reflog_entrycount(log.m_pP);
        for (std::size_t i = 0; i < ncount && out.size() < _MaxCount; ++i)
        {
            const git_reflog_entry* pentry = git_reflog_entry_byindex(log.m_pP, i);
            if (!pentry)
            {
                continue;
            }
            ReflogEntry entry;
            entry.m_OldOid = OidToHex(git_reflog_entry_id_old(pentry));
            entry.m_NewOid = OidToHex(git_reflog_entry_id_new(pentry));
            if (const char* szmessage = git_reflog_entry_message(pentry))
            {
                entry.m_Message = szmessage;
            }
            if (const git_signature* psig = git_reflog_entry_committer(pentry))
            {
                entry.m_Committer = psig->name ? psig->name : "";
                entry.m_TimeUtc = static_cast<std::int64_t>(psig->when.time);
            }
            out.push_back(std::move(entry));
        }
        return out;
    }

    void Repository::SetBranchTarget(const std::string& _Name, const std::string& _Oid)
    {
        if (m_pP4)
        {
            m_pP4->SetBranchTarget(_Name, _Oid);
            return;
        }

        RequireOpen(m_pRepo, "setBranchTarget()");

        CommitPtr target = ResolveCommit(m_pRepo, _Oid);
        const std::string refName = "refs/heads/" + _Name;

        ReferencePtr branch;
        const bool bexists =
            git_branch_lookup(&branch.m_pP, m_pRepo, _Name.c_str(), GIT_BRANCH_LOCAL) == 0;
        const bool bisHead = bexists && git_branch_is_head(branch.m_pP) == 1;

        if (bisHead)
        {
            // Move the working tree first: a SAFE checkout refuses (and
            // changes nothing) if it would overwrite uncommitted work.
            git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
            opts.checkout_strategy = GIT_CHECKOUT_SAFE;
            if (git_checkout_tree(m_pRepo, reinterpret_cast<git_object*>(target.m_pP), &opts) < 0)
            {
                RaiseLastError("Your uncommitted changes are in the way");
            }
        }

        const std::string reflog = "gitgud: move " + _Name + " to " + _Oid.substr(0, 7);
        ReferencePtr moved;
        if (git_reference_create(&moved.m_pP, m_pRepo, refName.c_str(), git_commit_id(target.m_pP),
                /*force=*/1, reflog.c_str()) < 0)
        {
            RaiseLastError("Moving " + _Name + " failed");
        }
    }

    // ---- File history / blame ------------------------------------------------------

    std::vector<CommitInfo> Repository::FileLog(
        const std::string& _Path, std::size_t _MaxCount) const
    {
        if (m_pP4)
        {
            return m_pP4->FileLog(_Path, _MaxCount);
        }

        RequireOpen(m_pRepo, "fileLog()");

        RevwalkPtr walk;
        if (git_revwalk_new(&walk.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_revwalk_new failed");
        }
        git_revwalk_sorting(walk.m_pP, GIT_SORT_TOPOLOGICAL | GIT_SORT_TIME);
        if (git_revwalk_push_head(walk.m_pP) < 0)
        {
            return {}; // unborn HEAD
        }

        // Bound the walk so a rarely-touched file in a huge history can't hang
        // the UI thread.
        constexpr std::size_t kMaxWalk = 50000;
        std::size_t nwalked = 0;
        std::vector<CommitInfo> out;
        git_oid oid;
        while (out.size() < _MaxCount && nwalked++ < kMaxWalk &&
               git_revwalk_next(&oid, walk.m_pP) == 0)
        {
            CommitPtr commit;
            if (git_commit_lookup(&commit.m_pP, m_pRepo, &oid) < 0)
            {
                continue;
            }
            git_oid mine;
            const bool bhasMine = EntryId(commit.m_pP, _Path, mine);

            // Changed = differs from every parent (a merge that took one
            // side's version unchanged didn't change the file itself).
            const unsigned uparents = git_commit_parentcount(commit.m_pP);
            bool bchanged = uparents == 0 ? bhasMine : true;
            for (unsigned ui = 0; ui < uparents && bchanged; ++ui)
            {
                CommitPtr parent;
                if (git_commit_parent(&parent.m_pP, commit.m_pP, ui) < 0)
                {
                    continue;
                }
                git_oid theirs;
                const bool bhasTheirs = EntryId(parent.m_pP, _Path, theirs);
                if (bhasMine == bhasTheirs && (!bhasMine || git_oid_equal(&mine, &theirs)))
                {
                    bchanged = false;
                }
            }
            if (!bchanged)
            {
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

    BlameResult Repository::Blame(const std::string& _Path, const std::string& _Revision) const
    {
        if (m_pP4)
        {
            return m_pP4->Blame(_Path, _Revision);
        }

        RequireOpen(m_pRepo, "blame()");

        const bool bworkdir = _Revision.empty() || _Revision == "workdir";
        git_blame_options opts = GIT_BLAME_OPTIONS_INIT;
        std::string content;

        if (bworkdir)
        {
            // The file as Git would store it (line endings normalised etc.),
            // so unchanged lines match their committed versions.
            FilterListPtr filters;
            Buf filtered;
            if (git_filter_list_load(&filters.m_pP, m_pRepo, nullptr, _Path.c_str(),
                    GIT_FILTER_TO_ODB, GIT_FILTER_DEFAULT) == 0 &&
                filters.m_pP)
            {
                if (git_filter_list_apply_to_file(
                        &filtered.m_B, filters.m_pP, m_pRepo, _Path.c_str()) < 0)
                {
                    RaiseLastError("Reading '" + _Path + "' failed");
                }
                content = filtered.Str();
            }
            else if (!ReadFileVersion(_Path, "workdir", content))
            {
                throw GitError("'" + _Path + "' doesn't exist in the working tree");
            }
        }
        else
        {
            CommitPtr commit = ResolveCommit(m_pRepo, _Revision);
            opts.newest_commit = *git_commit_id(commit.m_pP);
            if (!ReadFileVersion(_Path, OidToHex(git_commit_id(commit.m_pP)), content))
            {
                throw GitError("'" + _Path + "' doesn't exist in " + _Revision.substr(0, 7));
            }
        }

        BlameResult result;
        result.m_Lines = SplitLines(content);

        BlamePtr base;
        const bool bhistory = git_blame_file(&base.m_pP, m_pRepo, _Path.c_str(), &opts) == 0;
        BlamePtr blame;
        if (bhistory && bworkdir)
        {
            if (git_blame_buffer(&blame.m_pP, base.m_pP, content.data(), content.size()) < 0)
            {
                RaiseLastError("Blaming the working copy of '" + _Path + "' failed");
            }
        }
        else if (bhistory)
        {
            blame = std::move(base);
        }

        if (!blame.m_pP)
        {
            // Not in any commit yet: every line is new.
            if (!bworkdir)
            {
                RaiseLastError("Blame of '" + _Path + "' failed");
            }
            BlameHunk hunk;
            hunk.m_Oid = std::string(40, '0');
            hunk.m_Summary = "Not committed yet";
            hunk.m_Author = "You";
            hunk.m_TimeUtc = static_cast<std::int64_t>(std::time(nullptr));
            hunk.m_StartLine = 1;
            hunk.m_LineCount = result.m_Lines.size();
            hunk.m_bUncommitted = true;
            if (hunk.m_LineCount > 0)
            {
                result.m_Hunks.push_back(std::move(hunk));
            }
            return result;
        }

        std::unordered_map<std::string, std::string> summaries;
        const std::uint32_t ucount = git_blame_get_hunk_count(blame.m_pP);
        for (std::uint32_t ui = 0; ui < ucount; ++ui)
        {
            const git_blame_hunk* ph = git_blame_get_hunk_byindex(blame.m_pP, ui);
            if (!ph)
            {
                continue;
            }
            BlameHunk hunk;
            hunk.m_Oid = OidToHex(&ph->final_commit_id);
            hunk.m_StartLine = ph->final_start_line_number;
            hunk.m_LineCount = ph->lines_in_hunk;
            hunk.m_bUncommitted = git_oid_is_zero(&ph->final_commit_id) != 0;

            if (hunk.m_bUncommitted)
            {
                hunk.m_Summary = "Not committed yet";
                hunk.m_Author = "You";
                hunk.m_TimeUtc = static_cast<std::int64_t>(std::time(nullptr));
            }
            else
            {
                if (ph->final_signature)
                {
                    hunk.m_Author = ph->final_signature->name ? ph->final_signature->name : "";
                    hunk.m_TimeUtc = static_cast<std::int64_t>(ph->final_signature->when.time);
                }
                auto it = summaries.find(hunk.m_Oid);
                if (it == summaries.end())
                {
                    std::string summary;
                    CommitPtr commit;
                    if (git_commit_lookup(&commit.m_pP, m_pRepo, &ph->final_commit_id) == 0)
                    {
                        const char* szsummary = git_commit_summary(commit.m_pP);
                        summary = szsummary ? szsummary : "";
                        if (hunk.m_Author.empty())
                        {
                            const git_signature* pauthor = git_commit_author(commit.m_pP);
                            hunk.m_Author = pauthor && pauthor->name ? pauthor->name : "";
                            hunk.m_TimeUtc =
                                pauthor ? static_cast<std::int64_t>(pauthor->when.time) : 0;
                        }
                    }
                    it = summaries.emplace(hunk.m_Oid, summary).first;
                }
                hunk.m_Summary = it->second;
            }
            result.m_Hunks.push_back(std::move(hunk));
        }
        return result;
    }

} // namespace gitgud::git
