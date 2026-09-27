// -----------------------------------------------------------------------------
// CommitGraph — see CommitGraph.h. The walk keeps one "expected commit" per
// lane: the commit that lane's line is heading for. Each row finds its own
// lane among them, ends every line that was heading for it, and starts (or
// continues) one line per parent.
// -----------------------------------------------------------------------------

#include "git/CommitGraph.h"

#include <algorithm>

namespace gitgud::git
{

    namespace
    {

        // First free lane, or a new one at the end.
        int ClaimLane(std::vector<std::string>& _Lanes)
        {
            for (std::size_t i = 0; i < _Lanes.size(); ++i)
            {
                if (_Lanes[i].empty())
                {
                    return static_cast<int>(i);
                }
            }
            _Lanes.emplace_back();
            return static_cast<int>(_Lanes.size() - 1);
        }

        int FindLane(const std::vector<std::string>& _Lanes, const std::string& _Oid)
        {
            for (std::size_t i = 0; i < _Lanes.size(); ++i)
            {
                if (_Lanes[i] == _Oid)
                {
                    return static_cast<int>(i);
                }
            }
            return -1;
        }

    } // namespace

    std::vector<GraphRow> LayoutGraph(const std::vector<GraphNode>& _Nodes)
    {
        std::vector<GraphRow> rows;
        rows.reserve(_Nodes.size());

        std::vector<std::string> lanes; // expected commit per lane ("" = free)
        std::vector<int> laneColours;
        int inextColour = 0;

        const auto colourOf = [&](int _iLane) -> int
        {
            if (static_cast<std::size_t>(_iLane) >= laneColours.size())
            {
                laneColours.resize(static_cast<std::size_t>(_iLane) + 1, 0);
            }
            return laneColours[static_cast<std::size_t>(_iLane)];
        };

        const auto newColour = [&](int _iLane)
        {
            colourOf(_iLane);
            laneColours[static_cast<std::size_t>(_iLane)] = inextColour++;
        };

        for (const GraphNode& node : _Nodes)
        {
            GraphRow row;

            // Lines already heading for this commit (children above it).
            std::vector<int> incoming;
            for (std::size_t i = 0; i < lanes.size(); ++i)
            {
                if (lanes[i] == node.m_Oid)
                {
                    incoming.push_back(static_cast<int>(i));
                }
            }

            // Nothing points here: a branch tip. It gets a fresh lane.
            const bool btip = incoming.empty();
            int ilane = 0;
            if (btip)
            {
                ilane = ClaimLane(lanes);
                newColour(ilane);
            }
            else
            {
                ilane = incoming.front();
            }
            row.m_iLane = ilane;
            row.m_iColour = colourOf(ilane);

            // Top half: every live line either passes straight through or
            // converges on the dot.
            std::vector<bool> liveAtTop(lanes.size(), false);
            for (std::size_t i = 0; i < lanes.size(); ++i)
            {
                if (lanes[i].empty())
                {
                    continue;
                }
                liveAtTop[i] = true;
                const int ik = static_cast<int>(i);
                if (lanes[i] == node.m_Oid)
                {
                    row.m_Edges.push_back({ik, ilane, colourOf(ik), true});
                }
                else
                {
                    row.m_Edges.push_back({ik, ik, colourOf(ik), true});
                }
            }

            // Those lines end here.
            for (const int ik : incoming)
            {
                lanes[static_cast<std::size_t>(ik)].clear();
            }

            // Bottom half: one line per parent. The first parent continues in
            // this lane unless some other lane already heads for it; the rest
            // join an existing lane or start a new one.
            for (std::size_t p = 0; p < node.m_Parents.size(); ++p)
            {
                const std::string& parent = node.m_Parents[p];
                int ito = FindLane(lanes, parent);

                // The first parent keeps this lane even if a lane further
                // right already heads for it: both lines then meet at the
                // parent, which keeps the main line on the left.
                if (p == 0 && ito > ilane && lanes[static_cast<std::size_t>(ilane)].empty())
                {
                    ito = -1;
                }

                if (ito < 0)
                {
                    if (p == 0 && lanes[static_cast<std::size_t>(ilane)].empty())
                    {
                        ito = ilane;
                    }
                    else
                    {
                        ito = ClaimLane(lanes);
                        newColour(ito);
                    }
                    lanes[static_cast<std::size_t>(ito)] = parent;
                }
                row.m_Edges.push_back({ilane, ito, colourOf(ito), false});
            }

            // Lines that passed through the top keep going to the bottom.
            for (std::size_t i = 0; i < liveAtTop.size(); ++i)
            {
                const int ik = static_cast<int>(i);
                const bool bendsHere =
                    std::find(incoming.begin(), incoming.end(), ik) != incoming.end();
                if (liveAtTop[i] && !bendsHere && !lanes[i].empty())
                {
                    row.m_Edges.push_back({ik, ik, colourOf(ik), false});
                }
            }

            // Free columns at the right edge don't need to stay allocated.
            while (!lanes.empty() && lanes.back().empty())
            {
                lanes.pop_back();
            }

            int iwidest = ilane;
            for (const GraphEdge& edge : row.m_Edges)
            {
                iwidest = std::max({iwidest, edge.m_iFrom, edge.m_iTo});
            }
            row.m_iLaneCount = iwidest + 1;
            rows.push_back(std::move(row));
        }
        return rows;
    }

} // namespace gitgud::git
