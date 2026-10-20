#include "git/BareStore.h"

#include "app/Profiler.h"

#include "git/LibGit2Internal.h"

#include <algorithm>

namespace gitgud::git::barestore
{

    using namespace gitgud::git::internal;

    namespace
    {

        using TreeBuilderPtr = Handle<git_treebuilder, git_treebuilder_free>;

        RepositoryPtr OpenBare(const std::string& _Path)
        {
            GITGUD_PROFILE_FUNCTION();
            RepositoryPtr repo;
            if (git_repository_open_bare(&repo.m_pP, _Path.c_str()) < 0)
            {
                RaiseLastError("Could not open " + _Path);
            }
            return repo;
        }

        // The tree at `_Ref` (empty: HEAD); an empty holder when HEAD has no
        // commit yet.
        TreePtr TreeAt(git_repository* _pRepo, const std::string& _Ref)
        {
            TreePtr tree;
            ObjectPtr object;
            const std::string spec = _Ref.empty() ? "HEAD" : _Ref;
            const int ierr = git_revparse_single(&object.m_pP, _pRepo, spec.c_str());
            if ((ierr == GIT_ENOTFOUND || ierr == GIT_EUNBORNBRANCH) && _Ref.empty())
            {
                git_error_clear();
                return tree;
            }
            if (ierr < 0)
            {
                RaiseLastError("No revision '" + spec + "'");
            }
            ObjectPtr peeled;
            if (git_object_peel(&peeled.m_pP, object.m_pP, GIT_OBJECT_TREE) < 0)
            {
                RaiseLastError("No tree at '" + spec + "'");
            }
            tree.m_pP = reinterpret_cast<git_tree*>(peeled.m_pP);
            peeled.m_pP = nullptr;
            return tree;
        }

        // The blob id of `_File` in `_pTree`; nullopt when it isn't there.
        std::optional<git_oid> BlobId(git_tree* _pTree, const std::string& _File)
        {
            if (!_pTree)
            {
                return std::nullopt;
            }
            TreeEntryPtr entry;
            if (git_tree_entry_bypath(&entry.m_pP, _pTree, _File.c_str()) < 0)
            {
                git_error_clear();
                return std::nullopt;
            }
            if (git_tree_entry_type(entry.m_pP) != GIT_OBJECT_BLOB)
            {
                return std::nullopt;
            }
            return *git_tree_entry_id(entry.m_pP);
        }

        struct WalkState
        {
            git_repository* m_pRepo = nullptr;
            std::vector<StoreFile>* m_pFiles = nullptr;
        };

        int CollectBlob(const char* _szRoot, const git_tree_entry* _pEntry, void* _pPayload)
        {
            if (git_tree_entry_type(_pEntry) != GIT_OBJECT_BLOB)
            {
                return 0;
            }
            auto* pstate = static_cast<WalkState*>(_pPayload);
            StoreFile file;
            file.m_Path = std::string(_szRoot) + git_tree_entry_name(_pEntry);
            BlobPtr blob;
            if (git_blob_lookup(&blob.m_pP, pstate->m_pRepo, git_tree_entry_id(_pEntry)) == 0)
            {
                file.m_uSize = static_cast<std::uint64_t>(git_blob_rawsize(blob.m_pP));
            }
            pstate->m_pFiles->push_back(std::move(file));
            return 0;
        }

        std::string Hex(const git_oid& _Oid)
        {
            char abuf[GIT_OID_MAX_HEXSIZE + 1] = {};
            git_oid_tostr(abuf, sizeof(abuf), &_Oid);
            return abuf;
        }

    } // namespace

    bool Exists(const std::string& _Path)
    {
        git_repository* prepo = nullptr;
        const bool bok = git_repository_open_bare(&prepo, _Path.c_str()) == 0;
        if (prepo)
        {
            git_repository_free(prepo);
        }
        git_error_clear();
        return bok;
    }

    void Init(const std::string& _Path)
    {
        if (Exists(_Path))
        {
            return;
        }
        git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
        options.flags = GIT_REPOSITORY_INIT_MKPATH | GIT_REPOSITORY_INIT_BARE;
        options.initial_head = "main";
        RepositoryPtr repo;
        if (git_repository_init_ext(&repo.m_pP, _Path.c_str(), &options) < 0)
        {
            RaiseLastError("Could not make " + _Path);
        }
    }

    std::vector<StoreFile> Files(const std::string& _Path, const std::string& _Ref)
    {
        GITGUD_PROFILE_FUNCTION();
        std::vector<StoreFile> files;
        RepositoryPtr repo = OpenBare(_Path);
        TreePtr tree = TreeAt(repo.m_pP, _Ref);
        if (!tree.m_pP)
        {
            return files;
        }
        WalkState state{repo.m_pP, &files};
        if (git_tree_walk(tree.m_pP, GIT_TREEWALK_PRE, CollectBlob, &state) < 0)
        {
            RaiseLastError("Could not list " + _Path);
        }
        std::sort(files.begin(), files.end(),
            [](const StoreFile& _A, const StoreFile& _B) { return _A.m_Path < _B.m_Path; });
        return files;
    }

    std::optional<std::string> Read(
        const std::string& _Path, const std::string& _File, const std::string& _Ref)
    {
        RepositoryPtr repo = OpenBare(_Path);
        TreePtr tree = TreeAt(repo.m_pP, _Ref);
        const std::optional<git_oid> id = BlobId(tree.m_pP, _File);
        if (!id)
        {
            return std::nullopt;
        }
        BlobPtr blob;
        if (git_blob_lookup(&blob.m_pP, repo.m_pP, &*id) < 0)
        {
            RaiseLastError("Could not read " + _File);
        }
        return std::string(static_cast<const char*>(git_blob_rawcontent(blob.m_pP)),
            static_cast<std::size_t>(git_blob_rawsize(blob.m_pP)));
    }

    std::string Commit(const std::string& _Path, const std::vector<StoreChange>& _Changes,
        const std::string& _Message, const std::string& _Name, const std::string& _Email)
    {
        Init(_Path);
        RepositoryPtr repo = OpenBare(_Path);

        CommitPtr parent;
        git_oid headOid;
        if (git_reference_name_to_id(&headOid, repo.m_pP, "HEAD") == 0)
        {
            if (git_commit_lookup(&parent.m_pP, repo.m_pP, &headOid) < 0)
            {
                RaiseLastError("Could not read HEAD");
            }
        }
        git_error_clear();

        TreePtr base;
        if (parent.m_pP)
        {
            if (git_commit_tree(&base.m_pP, parent.m_pP) < 0)
            {
                RaiseLastError("Could not read HEAD's tree");
            }
        }
        else
        {
            TreeBuilderPtr builder;
            git_oid emptyOid;
            if (git_treebuilder_new(&builder.m_pP, repo.m_pP, nullptr) < 0 ||
                git_treebuilder_write(&emptyOid, builder.m_pP) < 0 ||
                git_tree_lookup(&base.m_pP, repo.m_pP, &emptyOid) < 0)
            {
                RaiseLastError("Could not start a tree");
            }
        }

        std::vector<git_tree_update> updates;
        updates.reserve(_Changes.size());
        for (const StoreChange& change : _Changes)
        {
            git_tree_update update = {};
            update.path = change.m_Path.c_str();
            update.filemode = GIT_FILEMODE_BLOB;
            if (change.m_Content)
            {
                update.action = GIT_TREE_UPDATE_UPSERT;
                if (git_blob_create_from_buffer(
                        &update.id, repo.m_pP, change.m_Content->data(), change.m_Content->size()) < 0)
                {
                    RaiseLastError("Could not store " + change.m_Path);
                }
            }
            else
            {
                if (!BlobId(base.m_pP, change.m_Path))
                {
                    continue; // already gone
                }
                update.action = GIT_TREE_UPDATE_REMOVE;
            }
            updates.push_back(update);
        }

        git_oid treeOid;
        if (git_tree_create_updated(&treeOid, repo.m_pP, base.m_pP, updates.size(), updates.data()) < 0)
        {
            RaiseLastError("Could not write the tree");
        }
        if (parent.m_pP && git_oid_equal(&treeOid, git_tree_id(base.m_pP)))
        {
            return {};
        }
        TreePtr tree;
        if (git_tree_lookup(&tree.m_pP, repo.m_pP, &treeOid) < 0)
        {
            RaiseLastError("Could not read the new tree");
        }
        SignaturePtr signature;
        if (git_signature_now(&signature.m_pP, _Name.c_str(), _Email.c_str()) < 0)
        {
            RaiseLastError("Could not sign the commit");
        }
        const git_commit* aparents[1] = {parent.m_pP};
        git_oid commitOid;
        if (git_commit_create(&commitOid, repo.m_pP, "HEAD", signature.m_pP, signature.m_pP, "UTF-8",
                _Message.c_str(), tree.m_pP, parent.m_pP ? 1 : 0, aparents) < 0)
        {
            RaiseLastError("Could not commit");
        }
        return Hex(commitOid);
    }

    std::vector<StoreCommit> Log(const std::string& _Path, const std::string& _File, std::size_t _nMax)
    {
        GITGUD_PROFILE_FUNCTION();
        std::vector<StoreCommit> commits;
        RepositoryPtr repo = OpenBare(_Path);
        RevwalkPtr walk;
        if (git_revwalk_new(&walk.m_pP, repo.m_pP) < 0)
        {
            RaiseLastError("Could not walk " + _Path);
        }
        git_revwalk_sorting(walk.m_pP, GIT_SORT_TIME);
        if (git_revwalk_push_head(walk.m_pP) < 0)
        {
            git_error_clear();
            return commits; // no commits yet
        }
        git_oid oid;
        while (commits.size() < _nMax && git_revwalk_next(&oid, walk.m_pP) == 0)
        {
            CommitPtr commit;
            if (git_commit_lookup(&commit.m_pP, repo.m_pP, &oid) < 0)
            {
                continue;
            }
            if (!_File.empty())
            {
                TreePtr tree;
                git_commit_tree(&tree.m_pP, commit.m_pP);
                const std::optional<git_oid> now = BlobId(tree.m_pP, _File);
                std::optional<git_oid> before;
                CommitPtr parent;
                if (git_commit_parentcount(commit.m_pP) > 0 &&
                    git_commit_parent(&parent.m_pP, commit.m_pP, 0) == 0)
                {
                    TreePtr parentTree;
                    git_commit_tree(&parentTree.m_pP, parent.m_pP);
                    before = BlobId(parentTree.m_pP, _File);
                }
                git_error_clear();
                const bool bsame = now.has_value() == before.has_value() &&
                                   (!now || git_oid_equal(&*now, &*before));
                if (bsame)
                {
                    continue;
                }
            }
            StoreCommit entry;
            entry.m_Id = Hex(oid);
            entry.m_Message = git_commit_message(commit.m_pP) ? git_commit_message(commit.m_pP) : "";
            const git_signature* pauthor = git_commit_author(commit.m_pP);
            entry.m_Author = pauthor && pauthor->name ? pauthor->name : "";
            entry.m_iTime = static_cast<std::int64_t>(git_commit_time(commit.m_pP));
            commits.push_back(std::move(entry));
        }
        return commits;
    }

} // namespace gitgud::git::barestore
