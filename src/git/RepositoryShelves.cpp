// -----------------------------------------------------------------------------
// Repository — shelving. A shelf is an ordinary commit on its own branch:
// Shelve() snapshots some working-tree files on top of HEAD without touching
// HEAD, the index, or the files; Unshelve() brings such a commit's changes
// back into the working tree, merging with local edits.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <algorithm>
#include <filesystem>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        namespace fs = std::filesystem;

        bool LooksBinary(const FileVersion& _Version)
        {
            return _Version.m_bExists && _Version.m_Text.find('\0') != std::string::npos;
        }

        bool SameContent(const FileVersion& _A, const FileVersion& _B)
        {
            return _A.m_bExists == _B.m_bExists && (!_A.m_bExists || _A.m_Text == _B.m_Text);
        }

        void RemoveWorkingFile(git_repository* _pRepo, const std::string& _Path,
            const std::function<bool(const std::string&)>& _RemoveFile)
        {
            const fs::path abs = WorkingPath(_pRepo, _Path);
            std::error_code ec;
            if (!fs::exists(abs, ec))
            {
                return;
            }
            if (_RemoveFile)
            {
                if (!_RemoveFile(abs.u8string()))
                {
                    throw GitError("Could not remove '" + _Path + "'");
                }
                return;
            }
            fs::remove(abs, ec);
            if (ec)
            {
                throw GitError("Could not remove '" + _Path + "': " + ec.message());
            }
        }

    } // namespace

    std::string Repository::Shelve(const std::string& _Branch,
        const std::vector<std::string>& _Paths, const std::string& _Message)
    {
        if (!m_pRepo)
        {
            throw GitError("shelve() on an unopened repository");
        }
        if (_Paths.empty())
        {
            throw GitError("Nothing to shelve");
        }
        const std::string refName = "refs/heads/" + _Branch;
        if (!git_reference_is_valid_name(refName.c_str()))
        {
            throw GitError("'" + _Branch + "' is not a valid branch name");
        }
        if (CurrentBranch() == _Branch)
        {
            throw GitError("Can't shelve onto the checked-out branch '" + _Branch + "'");
        }
        if (HeadOid().empty())
        {
            throw GitError("Shelving needs at least one commit to shelve on top of");
        }

        CommitPtr head = ResolveCommit(m_pRepo, "HEAD");
        TreePtr headTree;
        if (git_commit_tree(&headTree.m_pP, head.m_pP) < 0)
        {
            RaiseLastError("git_commit_tree failed");
        }

        // An in-memory index seeded with HEAD's tree, the shelved files laid
        // over it: the user's real index never changes.
        IndexPtr index;
        if (git_index_new(&index.m_pP) < 0 || git_index_read_tree(index.m_pP, headTree.m_pP) < 0)
        {
            RaiseLastError("Preparing the shelf failed");
        }
        for (const std::string& path : _Paths)
        {
            const FileVersion work = ReadVersion(m_pRepo, path, "workdir");
            if (!work.m_bExists)
            {
                git_index_remove_bypath(index.m_pP, path.c_str());
                continue;
            }
            git_oid blobOid;
            if (git_blob_create_from_buffer(
                    &blobOid, m_pRepo, work.m_Text.data(), work.m_Text.size()) < 0)
            {
                RaiseLastError("Storing '" + path + "' failed");
            }
            git_index_entry entry = {};
            entry.path = path.c_str();
            entry.id = blobOid;
            const git_index_entry* pexisting = git_index_get_bypath(index.m_pP, path.c_str(), 0);
            entry.mode = pexisting ? pexisting->mode : GIT_FILEMODE_BLOB;
            std::error_code ec;
            const auto status = fs::status(WorkingPath(m_pRepo, path), ec);
            if (!ec && (status.permissions() & fs::perms::owner_exec) != fs::perms::none &&
                !pexisting)
            {
                entry.mode = GIT_FILEMODE_BLOB_EXECUTABLE;
            }
            if (git_index_add(index.m_pP, &entry) < 0)
            {
                RaiseLastError("Shelving '" + path + "' failed");
            }
        }

        git_oid treeOid;
        if (git_index_write_tree_to(&treeOid, index.m_pP, m_pRepo) < 0)
        {
            RaiseLastError("Writing the shelf's tree failed");
        }
        TreePtr tree;
        if (git_tree_lookup(&tree.m_pP, m_pRepo, &treeOid) < 0)
        {
            RaiseLastError("git_tree_lookup failed");
        }

        SignaturePtr signature = SignatureOrFallback(m_pRepo);
        return CreateCommit(m_pRepo, refName.c_str(), signature.m_pP, signature.m_pP, _Message,
            tree.m_pP, {head.m_pP});
    }

    UnshelveResult Repository::Unshelve(const std::string& _Revision,
        const std::vector<std::string>& _Paths,
        const std::function<bool(const std::string&)>& _RemoveFile)
    {
        if (!m_pRepo)
        {
            throw GitError("unshelve() on an unopened repository");
        }
        CommitPtr shelf = ResolveCommit(m_pRepo, _Revision);
        const std::string shelfOid = OidToHex(git_commit_id(shelf.m_pP));
        const std::string baseRev = shelfOid + "^";

        // Every file the shelf changed; a rename is a delete plus an add.
        std::vector<std::string> files;
        const std::string parent = git_commit_parentcount(shelf.m_pP) > 0 ? baseRev : "";
        for (const ChangedFile& file : ChangedFiles(parent, shelfOid))
        {
            files.push_back(file.m_Path);
            if (file.m_OldPath != file.m_Path)
            {
                files.push_back(file.m_OldPath);
            }
        }
        if (!_Paths.empty())
        {
            files.erase(
                std::remove_if(files.begin(), files.end(), [&](const std::string& _File)
                    { return std::find(_Paths.begin(), _Paths.end(), _File) == _Paths.end(); }),
                files.end());
        }

        UnshelveResult result;
        for (const std::string& path : files)
        {
            const FileVersion base = ReadVersion(m_pRepo, path, baseRev);
            const FileVersion theirs = ReadVersion(m_pRepo, path, shelfOid);
            const FileVersion ours = ReadVersion(m_pRepo, path, "workdir");

            if (SameContent(ours, theirs))
            {
                result.m_Applied.push_back(path);
                continue;
            }
            if (SameContent(ours, base))
            {
                if (theirs.m_bExists)
                {
                    WriteWorkingFile(m_pRepo, path, theirs.m_Text);
                }
                else
                {
                    RemoveWorkingFile(m_pRepo, path, _RemoveFile);
                }
                result.m_Applied.push_back(path);
                continue;
            }

            // Both sides changed it. A deletion against an edit, or binary
            // content, can't be merged: leave the local file alone.
            if (!theirs.m_bExists || !ours.m_bExists || LooksBinary(base) || LooksBinary(ours) ||
                LooksBinary(theirs))
            {
                result.m_Skipped.push_back(path);
                continue;
            }

            git_merge_file_input ancestor = GIT_MERGE_FILE_INPUT_INIT;
            ancestor.ptr = base.m_Text.data();
            ancestor.size = base.m_Text.size();
            ancestor.path = path.c_str();
            git_merge_file_input mine = GIT_MERGE_FILE_INPUT_INIT;
            mine.ptr = ours.m_Text.data();
            mine.size = ours.m_Text.size();
            mine.path = path.c_str();
            git_merge_file_input shelved = GIT_MERGE_FILE_INPUT_INIT;
            shelved.ptr = theirs.m_Text.data();
            shelved.size = theirs.m_Text.size();
            shelved.path = path.c_str();

            git_merge_file_options options = GIT_MERGE_FILE_OPTIONS_INIT;
            options.our_label = "local";
            options.their_label = "shelved";
            git_merge_file_result merged = {};
            if (git_merge_file(&merged, &ancestor, &mine, &shelved, &options) < 0)
            {
                RaiseLastError("Merging '" + path + "' failed");
            }
            const std::string text =
                merged.ptr ? std::string(merged.ptr, merged.len) : std::string();
            const bool bclean = merged.automergeable != 0;
            git_merge_file_result_free(&merged);

            WriteWorkingFile(m_pRepo, path, text);
            (bclean ? result.m_Applied : result.m_Conflicted).push_back(path);
        }
        return result;
    }

} // namespace gitgud::git
