// -----------------------------------------------------------------------------
// Repository — reading conflicts for the 3-pane merge tool, and interactive
// rebase (reorder / reword / squash / fixup / drop).
//
// The interactive rebase never touches the working tree until the whole new
// history exists: every step is cherry-picked in memory onto the previous
// one, so a conflict anywhere just reports and leaves the repository exactly
// as it was. Only the final step moves the branch (and checks out its tree).
// Same layer rules as Repository.h: RAII, plain data out, GitError on failure.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <algorithm>
#include <set>

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

        bool IsBinaryBlob(git_repository* _pRepo, const git_index_entry* _pEntry)
        {
            if (!_pEntry)
            {
                return false;
            }
            BlobPtr blob;
            if (git_blob_lookup(&blob.m_pP, _pRepo, &_pEntry->id) < 0)
            {
                return false;
            }
            return git_blob_is_binary(blob.m_pP) != 0;
        }

        // Does `_Line` start a conflict marker of exactly this kind?
        bool IsMarker(const std::string& _Line, char _cKind)
        {
            if (_Line.size() < 7)
            {
                return false;
            }
            for (int i = 0; i < 7; ++i)
            {
                if (_Line[static_cast<std::size_t>(i)] != _cKind)
                {
                    return false;
                }
            }
            return _Line.size() == 7 || _Line[7] == ' ' || _Line[7] == '\r';
        }

        std::string ShortSummary(git_commit* _pCommit)
        {
            const char* szsummary = git_commit_summary(_pCommit);
            return OidToHex(git_commit_id(_pCommit)).substr(0, 7) + " \"" +
                   (szsummary ? szsummary : "") + "\"";
        }

        // Every conflicted path of an in-memory index.
        std::vector<std::string> ConflictsOf(git_index* _pIndex)
        {
            std::vector<std::string> out;
            git_index_conflict_iterator* pit = nullptr;
            if (git_index_conflict_iterator_new(&pit, _pIndex) < 0)
            {
                return out;
            }
            const git_index_entry* pancestor = nullptr;
            const git_index_entry* pours = nullptr;
            const git_index_entry* ptheirs = nullptr;
            while (git_index_conflict_next(&pancestor, &pours, &ptheirs, pit) == 0)
            {
                const git_index_entry* pany = pours ? pours : (ptheirs ? ptheirs : pancestor);
                if (pany && pany->path)
                {
                    out.emplace_back(pany->path);
                }
            }
            git_index_conflict_iterator_free(pit);
            return out;
        }

        // Apply `_pPick`'s change on top of `_pOnto` in memory. Returns the
        // resulting tree, or an empty holder with `_Conflicts` filled.
        TreePtr PickOnto(git_repository* _pRepo, git_commit* _pPick, git_commit* _pOnto,
            std::vector<std::string>& _Conflicts)
        {
            IndexPtr index;
            git_merge_options mo = GIT_MERGE_OPTIONS_INIT;
            if (git_cherrypick_commit(&index.m_pP, _pRepo, _pPick, _pOnto, 0, &mo) < 0)
            {
                RaiseLastError("Applying " + ShortSummary(_pPick) + " failed");
            }
            if (git_index_has_conflicts(index.m_pP))
            {
                _Conflicts = ConflictsOf(index.m_pP);
                return {};
            }
            git_oid treeOid;
            if (git_index_write_tree_to(&treeOid, index.m_pP, _pRepo) < 0)
            {
                RaiseLastError("git_index_write_tree_to failed");
            }
            TreePtr tree;
            if (git_tree_lookup(&tree.m_pP, _pRepo, &treeOid) < 0)
            {
                RaiseLastError("git_tree_lookup failed");
            }
            return tree;
        }

        CommitPtr LookupCommit(git_repository* _pRepo, const std::string& _Hex)
        {
            git_oid oid;
            if (git_oid_fromstr(&oid, _Hex.c_str()) < 0)
            {
                throw GitError("Invalid commit id '" + _Hex + "'");
            }
            CommitPtr commit;
            if (git_commit_lookup(&commit.m_pP, _pRepo, &oid) < 0)
            {
                RaiseLastError("No such commit '" + _Hex + "'");
            }
            return commit;
        }

        // The message with trailing blank lines trimmed (for joining squashes).
        std::string TrimmedMessage(const char* _szMessage)
        {
            std::string message = _szMessage ? _szMessage : "";
            while (!message.empty() &&
                   (message.back() == '\n' || message.back() == '\r' || message.back() == ' '))
            {
                message.pop_back();
            }
            return message;
        }

    } // namespace

    // ---- Conflicts ---------------------------------------------------------------

    ConflictFile Repository::ReadConflict(const std::string& _Path) const
    {
        if (m_pP4)
        {
            return m_pP4->ReadConflict(_Path);
        }

        RequireOpen(m_pRepo, "readConflict()");

        IndexPtr index;
        if (git_repository_index(&index.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("git_repository_index failed");
        }
        const git_index_entry* pancestor = nullptr;
        const git_index_entry* pours = nullptr;
        const git_index_entry* ptheirs = nullptr;
        if (git_index_conflict_get(&pancestor, &pours, &ptheirs, index.m_pP, _Path.c_str()) != 0)
        {
            throw GitError("'" + _Path + "' is not conflicted");
        }

        ConflictFile out;
        out.m_Path = _Path;
        out.m_bOursDeleted = pours == nullptr;
        out.m_bTheirsDeleted = ptheirs == nullptr;
        if (!pours || !ptheirs)
        {
            return out; // modify/delete: the tool offers keep or delete
        }
        if (IsBinaryBlob(m_pRepo, pancestor) || IsBinaryBlob(m_pRepo, pours) ||
            IsBinaryBlob(m_pRepo, ptheirs))
        {
            out.m_bBinary = true;
            return out;
        }

        git_merge_file_options mo = GIT_MERGE_FILE_OPTIONS_INIT;
        mo.flags = GIT_MERGE_FILE_STYLE_DIFF3;
        mo.ancestor_label = "base";
        mo.our_label = "ours";
        mo.their_label = "theirs";
        git_merge_file_result merged = {};
        if (git_merge_file_from_index(&merged, m_pRepo, pancestor, pours, ptheirs, &mo) < 0)
        {
            RaiseLastError("Merging '" + _Path + "' failed");
        }
        const std::string text = merged.ptr ? std::string(merged.ptr, merged.len) : std::string();
        git_merge_file_result_free(&merged);

        ChunkMergedText(text, out);
        return out;
    }

    namespace internal
    {

        ConflictFile ConflictFromBuffers(const std::string& _Path, const std::string* _pBase,
            const std::string* _pOurs, const std::string* _pTheirs)
        {
            ConflictFile out;
            out.m_Path = _Path;
            out.m_bOursDeleted = _pOurs == nullptr;
            out.m_bTheirsDeleted = _pTheirs == nullptr;
            if (!_pOurs || !_pTheirs)
            {
                return out;
            }
            const auto isBinary = [](const std::string* _pText)
            {
                return _pText && _pText->find('\0') != std::string::npos;
            };
            if (isBinary(_pBase) || isBinary(_pOurs) || isBinary(_pTheirs))
            {
                out.m_bBinary = true;
                return out;
            }
            const auto input = [](const std::string* _pText, const char* _szPath)
            {
                git_merge_file_input in = GIT_MERGE_FILE_INPUT_INIT;
                if (_pText)
                {
                    in.ptr = _pText->data();
                    in.size = _pText->size();
                    in.path = _szPath;
                    in.mode = GIT_FILEMODE_BLOB;
                }
                return in;
            };
            const git_merge_file_input base = input(_pBase, _Path.c_str());
            const git_merge_file_input ours = input(_pOurs, _Path.c_str());
            const git_merge_file_input theirs = input(_pTheirs, _Path.c_str());
            git_merge_file_options mo = GIT_MERGE_FILE_OPTIONS_INIT;
            mo.flags = GIT_MERGE_FILE_STYLE_DIFF3;
            mo.ancestor_label = "base";
            mo.our_label = "ours";
            mo.their_label = "theirs";
            git_merge_file_result merged = {};
            if (git_merge_file(&merged, _pBase ? &base : nullptr, &ours, &theirs, &mo) < 0)
            {
                RaiseLastError("Merging '" + _Path + "' failed");
            }
            const std::string text =
                merged.ptr ? std::string(merged.ptr, merged.len) : std::string();
            git_merge_file_result_free(&merged);
            ChunkMergedText(text, out);
            return out;
        }

        bool MergeBuffers(const std::string& _Path, const std::string* _pBase,
            const std::string& _Ours, const std::string& _Theirs, std::string& _OutMerged)
        {
            git_merge_file_input base = GIT_MERGE_FILE_INPUT_INIT;
            if (_pBase)
            {
                base.ptr = _pBase->data();
                base.size = _pBase->size();
                base.path = _Path.c_str();
                base.mode = GIT_FILEMODE_BLOB;
            }
            git_merge_file_input ours = GIT_MERGE_FILE_INPUT_INIT;
            ours.ptr = _Ours.data();
            ours.size = _Ours.size();
            ours.path = _Path.c_str();
            ours.mode = GIT_FILEMODE_BLOB;
            git_merge_file_input theirs = GIT_MERGE_FILE_INPUT_INIT;
            theirs.ptr = _Theirs.data();
            theirs.size = _Theirs.size();
            theirs.path = _Path.c_str();
            theirs.mode = GIT_FILEMODE_BLOB;
            git_merge_file_options mo = GIT_MERGE_FILE_OPTIONS_INIT;
            mo.ancestor_label = "base";
            mo.our_label = "local";
            mo.their_label = "shelved";
            git_merge_file_result merged = {};
            if (git_merge_file(&merged, _pBase ? &base : nullptr, &ours, &theirs, &mo) < 0)
            {
                RaiseLastError("Merging '" + _Path + "' failed");
            }
            _OutMerged = merged.ptr ? std::string(merged.ptr, merged.len) : std::string();
            const bool bclean = merged.automergeable != 0;
            git_merge_file_result_free(&merged);
            return bclean;
        }

        void ChunkMergedText(const std::string& _Text, ConflictFile& _Out)
        {
            const std::string& text = _Text;
            ConflictFile& out = _Out;
            out.m_bTrailingNewline = !text.empty() && text.back() == '\n';

            enum class Section
            {
                Common,
                Ours,
                Base,
                Theirs
            };
            Section section = Section::Common;
            ConflictChunk chunk;

            const auto flush = [&]()
            {
                if (chunk.m_bConflict || !chunk.m_Lines.empty())
                {
                    out.m_Chunks.push_back(std::move(chunk));
                }
                chunk = ConflictChunk();
            };

            std::size_t nstart = 0;
            while (nstart < text.size())
            {
                std::size_t nend = text.find('\n', nstart);
                if (nend == std::string::npos)
                {
                    nend = text.size();
                }
                const std::string line = text.substr(nstart, nend - nstart);
                nstart = nend + 1;

                if (section == Section::Common && IsMarker(line, '<'))
                {
                    flush();
                    chunk.m_bConflict = true;
                    section = Section::Ours;
                    continue;
                }
                if (section == Section::Ours && IsMarker(line, '|'))
                {
                    section = Section::Base;
                    continue;
                }
                if ((section == Section::Ours || section == Section::Base) && IsMarker(line, '='))
                {
                    section = Section::Theirs;
                    continue;
                }
                if (section == Section::Theirs && IsMarker(line, '>'))
                {
                    flush();
                    section = Section::Common;
                    continue;
                }

                switch (section)
                {
                case Section::Common:
                    chunk.m_Lines.push_back(line);
                    break;
                case Section::Ours:
                    chunk.m_Ours.push_back(line);
                    break;
                case Section::Base:
                    chunk.m_Base.push_back(line);
                    break;
                case Section::Theirs:
                    chunk.m_Theirs.push_back(line);
                    break;
                }
            }
            flush();
        }

    } // namespace internal

    // ---- Interactive rebase ------------------------------------------------------

    std::vector<CommitInfo> Repository::RebaseTodo(const std::string& _Base) const
    {
        if (m_pP4)
        {
            return m_pP4->RebaseTodo(_Base);
        }

        RequireOpen(m_pRepo, "rebaseTodo()");

        CommitPtr base = ResolveCommit(m_pRepo, _Base);
        git_oid headOid;
        if (git_reference_name_to_id(&headOid, m_pRepo, "HEAD") != 0)
        {
            throw GitError("There are no commits yet");
        }
        const git_oid* pbaseOid = git_commit_id(base.m_pP);
        if (git_oid_equal(&headOid, pbaseOid))
        {
            return {};
        }
        if (git_graph_descendant_of(m_pRepo, &headOid, pbaseOid) != 1)
        {
            throw GitError("That commit isn't in the current branch's history");
        }

        // Walk the first-parent chain down to the base.
        constexpr std::size_t kMaxCommits = 1000;
        std::vector<CommitInfo> newestFirst;
        git_oid cursor = headOid;
        while (!git_oid_equal(&cursor, pbaseOid))
        {
            if (newestFirst.size() >= kMaxCommits)
            {
                throw GitError("Too many commits to rewrite at once (limit 1000)");
            }
            CommitPtr commit;
            if (git_commit_lookup(&commit.m_pP, m_pRepo, &cursor) < 0)
            {
                RaiseLastError("git_commit_lookup failed");
            }
            const unsigned uparents = git_commit_parentcount(commit.m_pP);
            if (uparents > 1)
            {
                throw GitError("Interactive rebase can't rewrite merge commits (" +
                               ShortSummary(commit.m_pP) +
                               " is one). Pick a newer starting point.");
            }
            if (uparents == 0)
            {
                throw GitError("That commit isn't on the current branch's first-parent line");
            }
            CommitInfo info;
            ReadCommitInfo(m_pRepo, &cursor, info);
            newestFirst.push_back(std::move(info));
            git_oid_cpy(&cursor, git_commit_parent_id(commit.m_pP, 0));
        }

        std::reverse(newestFirst.begin(), newestFirst.end());
        return newestFirst;
    }

    RebaseResult Repository::InteractiveRebase(
        const std::string& _Base, const std::vector<RebaseStep>& _Steps)
    {
        if (m_pP4)
        {
            return m_pP4->InteractiveRebase(_Base, _Steps);
        }

        RequireOpen(m_pRepo, "interactiveRebase()");
        using Action = RebaseStep::Action;

        if (git_repository_state(m_pRepo) != GIT_REPOSITORY_STATE_NONE)
        {
            throw GitError("Finish or abort the operation in progress first");
        }
        ReferencePtr head;
        if (git_repository_head(&head.m_pP, m_pRepo) < 0 ||
            git_repository_head_detached(m_pRepo) == 1)
        {
            throw GitError("Interactive rebase needs a checked-out branch");
        }
        const std::string branchRef = git_reference_name(head.m_pP);
        const git_oid oldHead = *git_reference_target(head.m_pP);

        // The plan must be a reordering of exactly the commits being rewritten.
        const std::vector<CommitInfo> todo = RebaseTodo(_Base);
        std::multiset<std::string> expected;
        std::multiset<std::string> planned;
        for (const CommitInfo& c : todo)
        {
            expected.insert(c.m_Oid);
        }
        for (const RebaseStep& step : _Steps)
        {
            planned.insert(step.m_Oid);
        }
        if (expected != planned)
        {
            throw GitError("The rebase plan doesn't match the branch anymore; reopen it");
        }

        CommitPtr base = ResolveCommit(m_pRepo, _Base);
        const std::string baseHex = OidToHex(git_commit_id(base.m_pP));
        SignaturePtr committer = SignatureOrFallback(m_pRepo);

        CommitPtr current = LookupCommit(m_pRepo, baseHex);
        bool bbuiltAny = false; // has `current` moved past the base yet?
        std::size_t nrewritten = 0;

        for (const RebaseStep& step : _Steps)
        {
            if (step.m_Action == Action::Drop)
            {
                ++nrewritten;
                continue;
            }
            CommitPtr pick = LookupCommit(m_pRepo, step.m_Oid);
            const bool bfold = step.m_Action == Action::Squash || step.m_Action == Action::Fixup;

            if (bfold && !bbuiltAny)
            {
                throw GitError("The first commit can't be squashed: there's nothing before it "
                               "in the rebase to squash it into");
            }

            // An untouched commit already sitting on `current` stays as is,
            // so the unchanged start of a branch keeps its ids.
            if (step.m_Action == Action::Pick && git_commit_parentcount(pick.m_pP) == 1 &&
                git_oid_equal(git_commit_parent_id(pick.m_pP, 0), git_commit_id(current.m_pP)))
            {
                current = std::move(pick);
                bbuiltAny = true;
                continue;
            }

            std::vector<std::string> conflicts;
            TreePtr tree = PickOnto(m_pRepo, pick.m_pP, current.m_pP, conflicts);
            if (!tree.m_pP)
            {
                RebaseResult result;
                result.m_Kind = RebaseResult::Kind::Conflicts;
                result.m_ConflictedPaths = conflicts;
                result.m_Message = "Couldn't apply " + ShortSummary(pick.m_pP) +
                                   ": it conflicts with the commits before it in the new order. "
                                   "Nothing was changed.";
                return result;
            }

            std::string newOid;
            if (bfold)
            {
                // Replace `current` with one commit holding both changes.
                std::string message = TrimmedMessage(git_commit_message(current.m_pP));
                if (step.m_Action == Action::Squash)
                {
                    message = step.m_Message.empty()
                                  ? message + "\n\n" + TrimmedMessage(git_commit_message(pick.m_pP))
                                  : step.m_Message;
                }
                const unsigned uparents = git_commit_parentcount(current.m_pP);
                std::vector<CommitPtr> parents(uparents);
                std::vector<const git_commit*> parentPtrs;
                for (unsigned ui = 0; ui < uparents; ++ui)
                {
                    git_commit_parent(&parents[ui].m_pP, current.m_pP, ui);
                    parentPtrs.push_back(parents[ui].m_pP);
                }
                newOid = CreateCommit(m_pRepo, nullptr, git_commit_author(current.m_pP),
                    committer.m_pP, message + "\n", tree.m_pP, parentPtrs);
            }
            else
            {
                const bool breword = step.m_Action == Action::Reword && !step.m_Message.empty();
                const std::string message =
                    breword ? step.m_Message : std::string(git_commit_message(pick.m_pP));
                newOid = CreateCommit(m_pRepo, nullptr, git_commit_author(pick.m_pP),
                    committer.m_pP, message, tree.m_pP, {current.m_pP});
            }
            current = LookupCommit(m_pRepo, newOid);
            bbuiltAny = true;
            ++nrewritten;
        }

        const git_oid* pnewHead = git_commit_id(current.m_pP);
        RebaseResult result;
        if (git_oid_equal(pnewHead, &oldHead))
        {
            result.m_Kind = RebaseResult::Kind::UpToDate;
            result.m_Message = "Nothing to change.";
            return result;
        }

        // Move the working tree, then the branch. A SAFE checkout refuses
        // (leaving everything as it was) if local edits are in the way.
        git_checkout_options co = GIT_CHECKOUT_OPTIONS_INIT;
        co.checkout_strategy = GIT_CHECKOUT_SAFE;
        if (git_checkout_tree(m_pRepo, reinterpret_cast<git_object*>(current.m_pP), &co) < 0)
        {
            RaiseLastError("Your uncommitted changes are in the way; commit or stash them first");
        }
        ReferencePtr origHead;
        git_reference_create(&origHead.m_pP, m_pRepo, "ORIG_HEAD", &oldHead, /*force=*/1, nullptr);
        ReferencePtr moved;
        if (git_reference_create(&moved.m_pP, m_pRepo, branchRef.c_str(), pnewHead, /*force=*/1,
                "rebase -i (gitgud): finish") < 0)
        {
            RaiseLastError("Moving the branch failed");
        }

        result.m_Kind = RebaseResult::Kind::Done;
        result.m_Message =
            "Rewrote " + std::to_string(nrewritten) + (nrewritten == 1 ? " commit." : " commits.");
        return result;
    }

} // namespace gitgud::git
