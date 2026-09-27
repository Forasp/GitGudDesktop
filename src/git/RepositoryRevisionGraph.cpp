// -----------------------------------------------------------------------------
// Repository::FileRevisionGraph — one file's history across branches, in the
// shape of P4V's revision graph.
//
// Rows: every branch (the checked-out one first, then the usual default
// branch names, then other local branches and remote branches by recency).
// Each row claims the commits along its first-parent chain until it meets
// history an earlier row already claimed — so a feature branch's row holds
// just the commits made on it. Of those, the ones that changed the file are
// its revisions (nodes).
//
// Edges: from each revision to the nearest earlier revision along each of its
// parents (first parents stay on the row or show where the branch started;
// merge parents are integrations from another row). History that no branch
// reaches along first parents (merged, deleted branches) lands in one extra
// row with an empty name.
// -----------------------------------------------------------------------------

#include "git/Repository.h"

#include "git/LibGit2Internal.h"

#include <algorithm>
#include <deque>
#include <unordered_map>

namespace gitgud::git
{

    using namespace internal;

    namespace
    {

        // What the graph needs to know about one commit.
        struct CommitFacts
        {
            std::string m_Blob; // the file's blob id in this commit ("" = absent)
            std::vector<std::string> m_Parents;
            bool m_bTouches = false; // the file differs from the first parent
            char m_cAction = 'M';
        };

        class FactCache
        {
          public:
            FactCache(git_repository* _pRepo, std::string _Path, std::size_t _nBudget)
                : m_pRepo(_pRepo), m_Path(std::move(_Path)), m_nBudget(_nBudget)
            {
            }

            bool Exhausted() const
            {
                return m_Facts.size() >= m_nBudget;
            }

            // Facts of a commit, or nullptr when it can't be read.
            const CommitFacts* Get(const std::string& _Oid)
            {
                const auto it = m_Facts.find(_Oid);
                if (it != m_Facts.end())
                {
                    return &it->second;
                }
                git_oid oid;
                CommitPtr commit;
                if (git_oid_fromstr(&oid, _Oid.c_str()) < 0 ||
                    git_commit_lookup(&commit.m_pP, m_pRepo, &oid) < 0)
                {
                    return nullptr;
                }

                CommitFacts facts;
                facts.m_Blob = BlobIn(commit.m_pP);
                const unsigned int ucount = git_commit_parentcount(commit.m_pP);
                for (unsigned int i = 0; i < ucount; ++i)
                {
                    facts.m_Parents.push_back(OidToHex(git_commit_parent_id(commit.m_pP, i)));
                }
                std::string parentBlob;
                if (ucount > 0)
                {
                    CommitPtr parent;
                    if (git_commit_parent(&parent.m_pP, commit.m_pP, 0) == 0)
                    {
                        parentBlob = BlobIn(parent.m_pP);
                    }
                }
                facts.m_bTouches = facts.m_Blob != parentBlob;
                if (facts.m_Blob.empty())
                {
                    facts.m_cAction = 'D';
                }
                else if (parentBlob.empty())
                {
                    facts.m_cAction = 'A';
                }
                else if (ucount > 1)
                {
                    facts.m_cAction = 'I';
                }
                return &m_Facts.emplace(_Oid, std::move(facts)).first->second;
            }

          private:
            std::string BlobIn(git_commit* _pCommit) const
            {
                TreePtr tree;
                TreeEntryPtr entry;
                if (git_commit_tree(&tree.m_pP, _pCommit) < 0 ||
                    git_tree_entry_bypath(&entry.m_pP, tree.m_pP, m_Path.c_str()) != 0)
                {
                    return {};
                }
                return OidToHex(git_tree_entry_id(entry.m_pP));
            }

            git_repository* m_pRepo;
            std::string m_Path;
            std::size_t m_nBudget;
            std::unordered_map<std::string, CommitFacts> m_Facts;
        };

        bool IsDefaultName(const std::string& _Name)
        {
            return _Name == "main" || _Name == "master" || _Name == "trunk" || _Name == "develop";
        }

    } // namespace

    RevisionGraph Repository::FileRevisionGraph(
        const std::string& _Path, const RevisionGraphQuery& _Query) const
    {
        if (!m_pRepo)
        {
            throw GitError("fileRevisionGraph() on an unopened repository");
        }

        // Row order: HEAD's branch, default names, other locals, remotes.
        std::vector<BranchInfo> branches = Branches();
        auto rank = [](const BranchInfo& _B)
        {
            if (_B.m_bIsHead)
            {
                return 0;
            }
            if (!_B.m_bIsRemote && IsDefaultName(_B.m_Name))
            {
                return 1;
            }
            return _B.m_bIsRemote ? 3 : 2;
        };
        std::stable_sort(branches.begin(), branches.end(),
            [&](const BranchInfo& _A, const BranchInfo& _B)
            {
                if (rank(_A) != rank(_B))
                {
                    return rank(_A) < rank(_B);
                }
                return _A.m_TimeUtc > _B.m_TimeUtc;
            });

        struct Row
        {
            RevisionRow m_Info;
            std::vector<std::string> m_Nodes; // oids, newest first
        };

        std::vector<Row> rows;
        std::unordered_map<std::string, int> claimedBy; // oid -> row
        std::unordered_map<std::string, int> rowOfNode; // node oid -> row
        FactCache facts(m_pRepo, _Path, _Query.m_MaxWalk);

        // A detached HEAD gets a row of its own.
        const std::string head = HeadOid();
        const bool bdetached = !head.empty() && CurrentBranch().empty();
        if (bdetached)
        {
            BranchInfo detached;
            detached.m_Name = "HEAD";
            detached.m_bIsHead = true;
            detached.m_TargetOid = head;
            branches.insert(branches.begin(), detached);
        }

        for (const BranchInfo& branch : branches)
        {
            if (branch.m_bIsRemote && !_Query.m_bRemotes)
            {
                continue;
            }
            if (std::find(_Query.m_ExcludeBranches.begin(), _Query.m_ExcludeBranches.end(),
                    branch.m_Name) != _Query.m_ExcludeBranches.end())
            {
                continue;
            }
            if (branch.m_bIsRemote && branch.m_Name.size() > 5 &&
                branch.m_Name.compare(branch.m_Name.size() - 5, 5, "/HEAD") == 0)
            {
                continue;
            }
            Row row;
            row.m_Info.m_Name = branch.m_Name;
            row.m_Info.m_bHead = branch.m_bIsHead;
            row.m_Info.m_bRemote = branch.m_bIsRemote;
            const int irow = static_cast<int>(rows.size());

            std::string oid = branch.m_TargetOid;
            while (!oid.empty() && !facts.Exhausted() && claimedBy.count(oid) == 0)
            {
                claimedBy[oid] = irow;
                const CommitFacts* pfacts = facts.Get(oid);
                if (!pfacts)
                {
                    break;
                }
                if (pfacts->m_bTouches && rowOfNode.size() < _Query.m_MaxNodes)
                {
                    row.m_Nodes.push_back(oid);
                    rowOfNode[oid] = irow;
                }
                oid = pfacts->m_Parents.empty() ? std::string() : pfacts->m_Parents[0];
            }
            rows.push_back(std::move(row));
        }

        // Edges, discovering history no row claimed on the way.
        const int iotherRow = static_cast<int>(rows.size());
        bool busedOther = false;

        struct PendingEdge
        {
            std::string m_From;
            std::string m_To;
            bool m_bMerge = false;
        };

        std::vector<PendingEdge> pendingEdges;
        std::deque<std::string> queue;
        for (const Row& row : rows)
        {
            queue.insert(queue.end(), row.m_Nodes.begin(), row.m_Nodes.end());
        }
        while (!queue.empty())
        {
            const std::string node = queue.front();
            queue.pop_front();
            const CommitFacts* pfacts = facts.Get(node);
            if (!pfacts)
            {
                continue;
            }
            const std::vector<std::string> parents = pfacts->m_Parents;
            for (std::size_t p = 0; p < parents.size(); ++p)
            {
                // The nearest revision of the file along this parent's
                // first-parent chain.
                std::string oid = parents[p];
                std::size_t nsteps = 0;
                while (!oid.empty() && nsteps++ < 5000)
                {
                    if (rowOfNode.count(oid) != 0)
                    {
                        break;
                    }
                    const CommitFacts* pancestor = facts.Get(oid);
                    if (!pancestor)
                    {
                        oid.clear();
                        break;
                    }
                    if (pancestor->m_bTouches)
                    {
                        if (rowOfNode.size() >= _Query.m_MaxNodes)
                        {
                            oid.clear();
                            break;
                        }
                        const auto claimed = claimedBy.find(oid);
                        const int irow = claimed != claimedBy.end() ? claimed->second : iotherRow;
                        busedOther = busedOther || irow == iotherRow;
                        rowOfNode[oid] = irow;
                        if (irow == iotherRow)
                        {
                            claimedBy[oid] = irow;
                        }
                        queue.push_back(oid);
                        break;
                    }
                    oid = pancestor->m_Parents.empty() ? std::string() : pancestor->m_Parents[0];
                }
                if (!oid.empty() && rowOfNode.count(oid) != 0)
                {
                    // The first parent of a revision that removed-and-re-added
                    // the same content still counts: it's where it came from.
                    pendingEdges.push_back({oid, node, p > 0});
                }
            }
        }

        // Columns: oldest first, and never left of a revision it came from
        // (commit times can tie or run backwards): a topological order that
        // picks the oldest ready revision each time.
        RevisionGraph graph;
        std::vector<std::string> order;
        std::unordered_map<std::string, CommitInfo> infos;
        std::vector<std::string> candidates;
        for (const auto& [oid, irow] : rowOfNode)
        {
            git_oid id;
            CommitInfo info;
            if (git_oid_fromstr(&id, oid.c_str()) == 0 && ReadCommitInfo(m_pRepo, &id, info))
            {
                infos.emplace(oid, std::move(info));
                candidates.push_back(oid);
            }
        }
        std::unordered_map<std::string, int> indegree;
        std::unordered_map<std::string, std::vector<std::string>> children;
        for (const PendingEdge& edge : pendingEdges)
        {
            if (infos.count(edge.m_From) != 0 && infos.count(edge.m_To) != 0)
            {
                ++indegree[edge.m_To];
                children[edge.m_From].push_back(edge.m_To);
            }
        }
        auto older = [&](const std::string& _A, const std::string& _B)
        {
            const auto ta = infos[_A].m_TimeUtc;
            const auto tb = infos[_B].m_TimeUtc;
            return ta != tb ? ta < tb : _A < _B;
        };
        std::vector<std::string> ready;
        for (const std::string& oid : candidates)
        {
            if (indegree[oid] == 0)
            {
                ready.push_back(oid);
            }
        }
        while (!ready.empty())
        {
            const auto it = std::min_element(ready.begin(), ready.end(), older);
            const std::string oid = *it;
            ready.erase(it);
            order.push_back(oid);
            for (const std::string& child : children[oid])
            {
                if (--indegree[child] == 0)
                {
                    ready.push_back(child);
                }
            }
        }

        // Keep only rows that got revisions, in their original order.
        std::vector<int> rowMap(rows.size() + 1, -1);
        std::vector<bool> rowUsed(rows.size() + 1, false);
        for (const auto& [oid, irow] : rowOfNode)
        {
            rowUsed[static_cast<std::size_t>(irow)] = true;
        }
        for (std::size_t r = 0; r < rows.size(); ++r)
        {
            if (rowUsed[r])
            {
                rowMap[r] = static_cast<int>(graph.m_Rows.size());
                graph.m_Rows.push_back(rows[r].m_Info);
            }
        }
        if (busedOther && rowUsed[rows.size()])
        {
            rowMap[rows.size()] = static_cast<int>(graph.m_Rows.size());
            graph.m_Rows.push_back(RevisionRow{});
        }

        std::unordered_map<std::string, int> index;
        std::vector<int> revisionOfRow(graph.m_Rows.size(), 0);
        for (const std::string& oid : order)
        {
            RevisionNode node;
            node.m_Commit = infos[oid];
            node.m_iRow = rowMap[static_cast<std::size_t>(rowOfNode[oid])];
            node.m_iColumn = static_cast<int>(graph.m_Nodes.size());
            node.m_iRevision = ++revisionOfRow[static_cast<std::size_t>(node.m_iRow)];
            if (const CommitFacts* pfacts = facts.Get(oid))
            {
                node.m_cAction = pfacts->m_cAction;
            }
            index[oid] = node.m_iColumn;
            graph.m_Nodes.push_back(std::move(node));
        }
        for (const PendingEdge& edge : pendingEdges)
        {
            const auto from = index.find(edge.m_From);
            const auto to = index.find(edge.m_To);
            if (from != index.end() && to != index.end())
            {
                graph.m_Edges.push_back({from->second, to->second, edge.m_bMerge});
            }
        }
        return graph;
    }

} // namespace gitgud::git
